"""Binance trade stream -> Kafka.

One long-lived WebSocket to Binance's combined trade stream. Each trade is
published to Kafka unchanged (prices/quantities stay strings, no float loss),
keyed by symbol so a symbol's trades stay ordered within one partition.

Duplicates are acceptable by design: around a reconnect Binance may resend,
and the consumer upserts on trade_id. Losing trades is what we avoid.
"""

import asyncio
import json
import logging
import os
import random
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import websockets
from confluent_kafka import Producer
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest

log = logging.getLogger("producer")

# --- config (env) -----------------------------------------------------------
SYMBOLS = os.environ.get(
    "SYMBOLS",
    "btcusdt,ethusdt,solusdt,bnbusdt,xrpusdt,adausdt,dogeusdt,avaxusdt,linkusdt,maticusdt",
).split(",")
# stream.binance.com returns HTTP 451 from US regions; binance.vision is
# Binance's market-data-only endpoint with the same streams and payload.
WS_BASE = os.environ.get("BINANCE_WS_BASE", "wss://data-stream.binance.vision")
WS_URL = f"{WS_BASE}/stream?streams=" + "/".join(f"{s.strip().lower()}@trade" for s in SYMBOLS)

KAFKA_BOOTSTRAP = os.environ["KAFKA_BOOTSTRAP"]
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "trades")
KAFKA_SECURITY_PROTOCOL = os.environ.get("KAFKA_SECURITY_PROTOCOL", "SSL")

# No message at all for this long => assume a half-open connection, reconnect.
STALE_AFTER_S = float(os.environ.get("STALE_AFTER_SECONDS", "30"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8000"))

# --- metrics ----------------------------------------------------------------
TRADES_IN = Counter("producer_trades_received_total", "Trades received from Binance", ["symbol"])
TRADES_OUT = Counter("producer_trades_delivered_total", "Trades acknowledged by Kafka")
DELIVERY_ERRORS = Counter("producer_delivery_errors_total", "Trades Kafka failed to accept")
RECONNECTS = Counter("producer_ws_reconnects_total", "WebSocket (re)connect attempts")
CONNECTED = Gauge("producer_ws_connected", "1 while the Binance WebSocket is open")
LAST_TRADE_TS = Gauge("producer_last_trade_timestamp_seconds", "Binance trade time (T) of last trade received")
LAST_MSG_TS = Gauge("producer_last_message_timestamp_seconds", "Wall-clock time of last message received")

# --- health -----------------------------------------------------------------
# /healthz (liveness): the asyncio loop is still running (heartbeat is fresh).
#   A Binance outage is NOT a liveness failure: the reconnect loop handles it,
#   and restarting the pod wouldn't help.
# /readyz (readiness): the WebSocket is open. Lets a rolling update keep the
#   old pod until the new one is actually streaming (no ingest gap).
_state = {"heartbeat": time.monotonic(), "connected": False}
HEARTBEAT_STALE_S = 30


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            body, code, ctype = generate_latest(), 200, CONTENT_TYPE_LATEST
        elif self.path == "/healthz":
            ok = time.monotonic() - _state["heartbeat"] < HEARTBEAT_STALE_S
            body, code, ctype = (b"ok" if ok else b"event loop stalled"), (200 if ok else 503), "text/plain"
        elif self.path == "/readyz":
            ok = _state["connected"]
            body, code, ctype = (b"ok" if ok else b"not connected"), (200 if ok else 503), "text/plain"
        else:
            body, code, ctype = b"not found", 404, "text/plain"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # keep probe noise out of the logs
        pass


def start_http(port: int) -> None:
    server = ThreadingHTTPServer(("0.0.0.0", port), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


async def heartbeat() -> None:
    while True:
        _state["heartbeat"] = time.monotonic()
        await asyncio.sleep(5)


def make_producer() -> Producer:
    return Producer({
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "security.protocol": KAFKA_SECURITY_PROTOCOL,
        # Idempotence: broker de-duplicates producer retries, keeps per-partition order.
        "enable.idempotence": True,
        "acks": "all",
        # Small batching window: throughput without hurting freshness much.
        "linger.ms": 20,
        "compression.type": "lz4",
        # Keep retrying through a broker failover rather than dropping trades.
        "delivery.timeout.ms": 120000,
    })


def on_delivery(err, msg):
    if err is not None:
        DELIVERY_ERRORS.inc()
        log.error("delivery failed key=%s err=%s", msg.key(), err)
    else:
        TRADES_OUT.inc()


async def stream_once(producer: Producer, stop: asyncio.Event) -> None:
    """One connection lifetime. Returns/raises when it ends; caller reconnects."""
    RECONNECTS.inc()
    log.info("connecting %s", WS_URL)
    # websockets answers Binance's server pings automatically.
    async with websockets.connect(WS_URL, max_queue=10000, open_timeout=10) as ws:
        CONNECTED.set(1)
        _state["connected"] = True
        log.info("connected")
        try:
            while not stop.is_set():
                raw = await asyncio.wait_for(ws.recv(), timeout=STALE_AFTER_S)
                LAST_MSG_TS.set(time.time())
                trade = json.loads(raw).get("data")
                if not trade or trade.get("e") != "trade":
                    continue
                symbol = trade["s"]
                TRADES_IN.labels(symbol).inc()
                LAST_TRADE_TS.set(trade["T"] / 1000)
                while True:
                    try:
                        producer.produce(
                            KAFKA_TOPIC,
                            key=symbol,
                            value=json.dumps(trade, separators=(",", ":")),
                            on_delivery=on_delivery,
                        )
                        break
                    except BufferError:
                        # Local queue full (Kafka slow/unavailable): wait, don't drop.
                        producer.poll(0.5)
                producer.poll(0)  # serve delivery callbacks
        finally:
            CONNECTED.set(0)
            _state["connected"] = False


async def run() -> None:
    start_http(METRICS_PORT)
    asyncio.get_running_loop().create_task(heartbeat())
    producer = make_producer()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    backoff = 1.0
    while not stop.is_set():
        started = time.monotonic()
        try:
            await stream_once(producer, stop)
        except asyncio.TimeoutError:
            log.warning("no message for %ss, reconnecting", STALE_AFTER_S)
        except Exception as e:  # network errors, 24h server disconnect, etc.
            log.warning("stream ended: %r", e)
        if stop.is_set():
            break
        # Reset backoff after a healthy connection; otherwise grow it (max 60s) + jitter.
        backoff = 1.0 if time.monotonic() - started > 60 else min(backoff * 2, 60)
        delay = backoff * random.uniform(0.5, 1.0)
        log.info("reconnecting in %.1fs", delay)
        try:
            await asyncio.wait_for(stop.wait(), timeout=delay)
        except asyncio.TimeoutError:
            pass

    log.info("shutting down, flushing")
    remaining = producer.flush(30)
    if remaining:
        log.error("%d messages not delivered at shutdown", remaining)


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    asyncio.run(run())
