"""Freshness prober: PostgreSQL -> CloudWatch.

Independent of the producer and consumer on purpose: a component that has
stalled can't be trusted to report its own staleness. This measures what
users of the data actually see, at the system of record.

Every INTERVAL seconds it publishes (namespace METRIC_NAMESPACE, dimension
Pipeline=trades):
  StalenessSeconds   now() - newest ingested_at   (whole pipeline alive?)
  LatencyP99Seconds  p99 of ingested_at - trade_time over the last minute
  RowsPerMinute      rows landed in the last minute

If the DB can't be queried nothing is published, and the CloudWatch alarm
treats the missing data as breaching: a dead prober is also an alarm.
"""

import logging
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
import psycopg

log = logging.getLogger("monitor")

NAMESPACE = os.environ.get("METRIC_NAMESPACE", "Pipeline/Trades")
INTERVAL_S = float(os.environ.get("INTERVAL_SECONDS", "15"))
PORT = int(os.environ.get("HEALTH_PORT", "8000"))
DIMENSIONS = [{"Name": "Pipeline", "Value": "trades"}]

QUERY = """
SELECT
  extract(epoch FROM now() - (SELECT max(ingested_at) FROM trades))        AS staleness,
  extract(epoch FROM percentile_cont(0.99) WITHIN GROUP (ORDER BY ingested_at - trade_time)) AS p99,
  count(*)                                                                  AS rows_1m
FROM trades
WHERE ingested_at > now() - interval '1 minute'
"""

_state = {"heartbeat": time.monotonic()}


class _Health(BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == "/healthz" and time.monotonic() - _state["heartbeat"] < 4 * INTERVAL_S
        self.send_response(200 if ok else 503)
        self.end_headers()
        self.wfile.write(b"ok" if ok else b"stalled")

    def log_message(self, *args):
        pass


def collect(conn):
    with conn.cursor() as cur:
        cur.execute(QUERY)
        staleness, p99, rows = cur.fetchone()
    data = []
    if staleness is not None:  # NULL only if the table is empty
        data.append({"MetricName": "StalenessSeconds", "Value": float(staleness), "Unit": "Seconds"})
    if p99 is not None:  # NULL when nothing landed in the last minute
        data.append({"MetricName": "LatencyP99Seconds", "Value": float(p99), "Unit": "Seconds"})
    data.append({"MetricName": "RowsPerMinute", "Value": float(rows), "Unit": "Count"})
    return data


def main():
    threading.Thread(target=ThreadingHTTPServer(("0.0.0.0", PORT), _Health).serve_forever, daemon=True).start()
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    cw = boto3.client("cloudwatch")  # region + credentials: env / EKS Pod Identity
    conn = None
    while not stop.is_set():
        _state["heartbeat"] = time.monotonic()
        try:
            if conn is None or conn.closed:
                # Read-only, short timeouts: the prober must never load the DB.
                conn = psycopg.connect(autocommit=True, connect_timeout=5,
                                       options="-c statement_timeout=5000 -c default_transaction_read_only=on",
                                       application_name="freshness-monitor")
            data = collect(conn)
            for d in data:
                d["Dimensions"] = DIMENSIONS
            cw.put_metric_data(Namespace=NAMESPACE, MetricData=data)
            log.info("published %s", {d["MetricName"]: round(d["Value"], 3) for d in data})
        except psycopg.Error as e:
            log.warning("DB query failed (%r); not publishing -> alarm treats as breaching", e)
            try:
                if conn is not None:
                    conn.close()
            except Exception:
                pass
            conn = None
        except Exception as e:  # CloudWatch/credentials errors
            log.warning("publish failed: %r", e)
        stop.wait(INTERVAL_S)


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    main()
