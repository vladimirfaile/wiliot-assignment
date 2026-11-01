"""Kafka "trades" -> PostgreSQL, each trade stored exactly once.

Delivery: at-least-once from Kafka + idempotent insert.
  1. Read a batch from Kafka (auto-commit off).
  2. Insert it in ONE transaction with ON CONFLICT DO NOTHING.
  3. Only after the DB commit, commit the Kafka offsets.
A crash between 2 and 3, a rebalance, a redeploy or the producer resending
around a reconnect all lead to re-processing, which the primary key absorbs.

Primary key is (symbol, trade_id): Binance trade ids are unique per symbol,
not globally, so trade_id alone could drop real trades of another symbol.
"""

import json
import logging
import os
import signal
import threading
import time
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
from confluent_kafka import Consumer, KafkaException
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

log = logging.getLogger("consumer")

# --- config (env) -----------------------------------------------------------
KAFKA_BOOTSTRAP = os.environ["KAFKA_BOOTSTRAP"]
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "trades")
KAFKA_GROUP_ID = os.environ.get("KAFKA_GROUP_ID", "trades-to-postgres")
KAFKA_SECURITY_PROTOCOL = os.environ.get("KAFKA_SECURITY_PROTOCOL", "SSL")
BATCH_MAX_MESSAGES = int(os.environ.get("BATCH_MAX_MESSAGES", "500"))
BATCH_MAX_WAIT_S = float(os.environ.get("BATCH_MAX_WAIT_SECONDS", "0.5"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8000"))
# PostgreSQL connection comes from the standard PG* env vars (PGHOST, PGPASSWORD, ...).

DDL = """
CREATE TABLE IF NOT EXISTS trades (
    symbol      TEXT        NOT NULL,
    trade_id    BIGINT      NOT NULL,
    price       NUMERIC     NOT NULL,
    quantity    NUMERIC     NOT NULL,
    -- Derived in the DB so it can never disagree with price/quantity.
    notional    NUMERIC     GENERATED ALWAYS AS (price * quantity) STORED,
    trade_time  TIMESTAMPTZ NOT NULL,
    -- When the row landed; trade_time -> ingested_at is end-to-end latency.
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (symbol, trade_id)
);
CREATE INDEX IF NOT EXISTS trades_trade_time_idx ON trades (trade_time);
CREATE INDEX IF NOT EXISTS trades_ingested_at_idx ON trades (ingested_at);
"""

# One statement per batch; duplicates (within the batch or already stored) are skipped.
INSERT = """
INSERT INTO trades (symbol, trade_id, price, quantity, trade_time)
SELECT * FROM unnest(%s::text[], %s::bigint[], %s::numeric[], %s::numeric[], %s::timestamptz[])
ON CONFLICT (symbol, trade_id) DO NOTHING
"""

# --- metrics ----------------------------------------------------------------
CONSUMED = Counter("consumer_messages_consumed_total", "Kafka messages read")
INSERTED = Counter("consumer_rows_inserted_total", "New rows written to PostgreSQL")
DUPLICATES = Counter("consumer_duplicates_skipped_total", "Trades already stored (idempotent skip)")
INVALID = Counter("consumer_invalid_messages_total", "Messages that could not be parsed")
DB_ERRORS = Counter("consumer_db_errors_total", "Failed DB writes (retried)")
DB_WRITE_SECONDS = Histogram("consumer_db_write_seconds", "Batch insert + commit duration")
E2E_LATENCY = Histogram(
    "consumer_end_to_end_latency_seconds", "Binance trade time -> row committed",
    buckets=(0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 300),
)
LAST_TRADE_TS = Gauge("consumer_last_trade_timestamp_seconds", "Trade time of the newest committed trade")
LAG = Gauge("consumer_lag_messages", "Messages not yet consumed", ["partition"])

# --- health (same model as the producer) -------------------------------------
_state = {"heartbeat": time.monotonic(), "ready": False}
HEARTBEAT_STALE_S = 60


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            body, code, ctype = generate_latest(), 200, CONTENT_TYPE_LATEST
        elif self.path == "/healthz":
            ok = time.monotonic() - _state["heartbeat"] < HEARTBEAT_STALE_S
            body, code, ctype = (b"ok" if ok else b"main loop stalled"), (200 if ok else 503), "text/plain"
        elif self.path == "/readyz":
            ok = _state["ready"]
            body, code, ctype = (b"ok" if ok else b"starting"), (200 if ok else 503), "text/plain"
        else:
            body, code, ctype = b"not found", 404, "text/plain"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def start_http(port: int) -> None:
    server = ThreadingHTTPServer(("0.0.0.0", port), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


# --- database ---------------------------------------------------------------
def connect_db() -> psycopg.Connection:
    return psycopg.connect(autocommit=False, connect_timeout=10, application_name="trades-consumer")


def ensure_schema(conn: psycopg.Connection) -> None:
    with conn.transaction():
        # Replicas start together; serialize DDL so CREATE ... IF NOT EXISTS can't race.
        conn.execute("SELECT pg_advisory_xact_lock(hashtext('trades_schema'))")
        conn.execute(DDL)


def parse(value: bytes):
    """Binance trade JSON -> row tuple. Prices/quantities stay exact (Decimal)."""
    d = json.loads(value)
    price, qty = Decimal(d["p"]), Decimal(d["q"])
    if price <= 0 or qty <= 0:
        raise ValueError("non-positive price/quantity")
    return (d["s"], int(d["t"]), price, qty, datetime.fromtimestamp(int(d["T"]) / 1000, tz=timezone.utc))


def write_batch(conn_holder: dict, rows: list, stop: threading.Event) -> bool:
    """Insert rows in one transaction; retry until it succeeds or we're stopping."""
    cols = list(zip(*rows))
    backoff = 1.0
    while not stop.is_set():
        _state["heartbeat"] = time.monotonic()
        try:
            if conn_holder["conn"] is None or conn_holder["conn"].closed:
                conn_holder["conn"] = connect_db()
            conn = conn_holder["conn"]
            start = time.monotonic()
            with conn.transaction():
                cur = conn.execute(INSERT, [list(c) for c in cols])
                inserted = cur.rowcount
            DB_WRITE_SECONDS.observe(time.monotonic() - start)
            INSERTED.inc(inserted)
            DUPLICATES.inc(len(rows) - inserted)
            return True
        except psycopg.Error as e:
            DB_ERRORS.inc()
            log.warning("DB write failed (%r), retrying in %.0fs", e, backoff)
            try:
                if conn_holder["conn"] is not None:
                    conn_holder["conn"].close()
            except Exception:
                pass
            conn_holder["conn"] = None
            stop.wait(backoff)
            backoff = min(backoff * 2, 30)
    return False


def update_lag(consumer: Consumer) -> None:
    try:
        for tp in consumer.position(consumer.assignment()):
            _, high = consumer.get_watermark_offsets(tp, timeout=2, cached=False)
            if tp.offset >= 0:
                LAG.labels(str(tp.partition)).set(max(high - tp.offset, 0))
    except KafkaException as e:
        log.debug("lag update failed: %r", e)


def main() -> None:
    start_http(METRICS_PORT)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    db = {"conn": None}
    while not stop.is_set():  # wait for the DB on startup (e.g. RDS still booting)
        try:
            db["conn"] = connect_db()
            ensure_schema(db["conn"])
            break
        except psycopg.Error as e:
            log.warning("DB not ready (%r), retrying", e)
            stop.wait(5)

    consumer = Consumer({
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "security.protocol": KAFKA_SECURITY_PROTOCOL,
        "group.id": KAFKA_GROUP_ID,
        # Offsets are committed by us, after the DB commit.
        "enable.auto.commit": False,
        # First start of the group: take everything still retained.
        "auto.offset.reset": "earliest",
        # Incremental rebalancing: scaling moves only the partitions that must move.
        "partition.assignment.strategy": "cooperative-sticky",
    })
    assigned = lambda c, parts: log.info("assigned %s", [p.partition for p in parts])  # noqa: E731
    revoked = lambda c, parts: log.info("revoked %s", [p.partition for p in parts])  # noqa: E731
    consumer.subscribe([KAFKA_TOPIC], on_assign=assigned, on_revoke=revoked)
    _state["ready"] = True
    log.info("consuming %s as group %s", KAFKA_TOPIC, KAFKA_GROUP_ID)

    last_lag = 0.0
    try:
        while not stop.is_set():
            _state["heartbeat"] = time.monotonic()
            msgs = consumer.consume(num_messages=BATCH_MAX_MESSAGES, timeout=BATCH_MAX_WAIT_S)

            rows, newest_ms = [], 0
            for m in msgs:
                if m.error():
                    log.warning("kafka error: %s", m.error())
                    continue
                CONSUMED.inc()
                try:
                    row = parse(m.value())
                except (ValueError, KeyError, TypeError, InvalidOperation) as e:
                    INVALID.inc()  # poison message: skip it, never block the partition
                    log.error("invalid message at %s[%d]@%d: %r", m.topic(), m.partition(), m.offset(), e)
                    continue
                rows.append(row)
                newest_ms = max(newest_ms, int(row[4].timestamp() * 1000))

            if rows and not write_batch(db, rows, stop):
                break  # stopping mid-retry: don't commit; the batch is replayed later

            if msgs:
                try:
                    consumer.commit(asynchronous=False)
                except KafkaException as e:
                    # e.g. partitions moved in a rebalance; the new owner re-reads, PK dedupes.
                    log.warning("offset commit failed: %r", e)
                if rows:
                    now = time.time()
                    LAST_TRADE_TS.set(newest_ms / 1000)
                    for r in rows:
                        E2E_LATENCY.observe(now - r[4].timestamp())

            if time.monotonic() - last_lag > 15:
                update_lag(consumer)
                last_lag = time.monotonic()
    finally:
        log.info("shutting down")
        _state["ready"] = False
        consumer.close()  # leave the group now -> fast rebalance for the other replicas
        if db["conn"] is not None:
            db["conn"].close()


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    main()
