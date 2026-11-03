#!/usr/bin/env bash
# Step 3 evidence: run failure scenarios against the live pipeline and record
# what happened to the data. Writes evidence/<timestamp>.md.
#
#   ./scripts/evidence.sh                 # baseline, restarts, scaling (~8 min)
#   ./scripts/evidence.sh --with-alarm    # + stop producer until the freshness alarm fires (~+6 min)
#
# Loss check: Binance trade ids are consecutive per symbol, so within a window
#   missing = max(trade_id) - min(trade_id) + 1 - count(*)
# counts trades that never reached PostgreSQL. Duplicates are checked over the
# whole table. SQL runs inside a consumer pod (it already has DB access).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS=pipeline
REGION=us-east-2
WITH_ALARM=false
[[ "${1:-}" == "--with-alarm" ]] && WITH_ALARM=true
export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION

mkdir -p "$ROOT/evidence"
OUT="$ROOT/evidence/$(date -u +%Y%m%d-%H%M).md"
exec > >(tee "$OUT") 2>&1

sql() {
  kubectl -n "$NS" exec deploy/consumer -- python -c '
import sys, psycopg
with psycopg.connect() as c:
    cur = c.execute(sys.argv[1])
    print(" | ".join(d.name for d in cur.description))
    for r in cur.fetchall(): print(" | ".join(str(x) for x in r))' "$1"
}
db_now() { sql "SELECT now()" | tail -1; }
health() {
  aws cloudwatch describe-alarms --alarm-name-prefix vladimir-faile-pipeline- \
    --alarm-types CompositeAlarm MetricAlarm \
    --query '[CompositeAlarms[].[AlarmName,StateValue], MetricAlarms[].[AlarmName,StateValue]][]' --output text
}
health_state() {
  aws cloudwatch describe-alarms --alarm-names vladimir-faile-pipeline-health --alarm-types CompositeAlarm \
    --query 'CompositeAlarms[0].StateValue' --output text
}
lag() {
  for p in $(kubectl -n "$NS" get pods -l app=consumer -o name); do
    kubectl -n "$NS" exec "$p" -- python -c "import urllib.request as u;print(u.urlopen('http://localhost:8000/metrics').read().decode())" \
      | awk '/^consumer_lag_messages/ {s+=$2} END {print s+0}'
  done | awk '{s+=$1} END {print s+0}'
}
# Per-symbol trades, lost trades and largest gap between consecutive trades in [from, to].
window_report() {
  sql "SELECT symbol, count(*) AS trades,
              max(trade_id) - min(trade_id) + 1 - count(*) AS missing_trades,
              max(gap) AS max_gap_between_trades
       FROM (SELECT symbol, trade_id,
                    trade_time - lag(trade_time) OVER (PARTITION BY symbol ORDER BY trade_id) AS gap
             FROM trades WHERE trade_time BETWEEN '$1' AND '$2') t
       GROUP BY symbol ORDER BY trades DESC"
}
section() { printf '\n## %s\n\n' "$*"; }
code() { echo '```'; "$@"; echo '```'; }
run() { echo "\$ $*"; "$@"; }

# Runs an action, waits, then reports the window around it.
scenario() {
  local title="$1" settle="$2"; shift 2
  section "$title"
  local start; start="$(db_now)"
  sleep 20                                    # some undisturbed data before the event
  code run "$@"
  sleep "$settle"
  local end; end="$(db_now)"
  sleep 10                                    # let the tail of the window land
  echo "Window: $start → $end"
  echo
  code window_report "$start" "$end"
  echo "Consumer lag after: $(lag) messages · health: $(health_state)"
}

echo "# Evidence run $(date -u '+%Y-%m-%d %H:%M UTC')"
section "Setup"
code kubectl -n "$NS" get deploy,pods -o wide
code health

scenario "1. Baseline (no disruption — validates the loss check)" 60 true

scenario "2. Producer rolling restart (deploy-style: new pod first)" 30 \
  bash -c "kubectl -n $NS rollout restart deploy/producer && kubectl -n $NS rollout status deploy/producer --timeout=180s"

scenario "3. Producer pod killed (no graceful shutdown)" 30 \
  bash -c "kubectl -n $NS delete pod -l app=producer --grace-period=0 --force && kubectl -n $NS rollout status deploy/producer --timeout=180s"

scenario "4. Consumer rolling restart" 30 \
  bash -c "kubectl -n $NS rollout restart deploy/consumer && kubectl -n $NS rollout status deploy/consumer --timeout=180s"

scenario "5. Consumer scale 2 → 4 → 2 (partition rebalances)" 30 \
  bash -c "kubectl -n $NS scale deploy/consumer --replicas=4 && kubectl -n $NS rollout status deploy/consumer --timeout=180s && sleep 30 && kubectl -n $NS scale deploy/consumer --replicas=2 && kubectl -n $NS rollout status deploy/consumer --timeout=180s"

scenario "6. One consumer pod killed" 30 \
  bash -c "kubectl -n $NS delete pod \$(kubectl -n $NS get pods -l app=consumer -o name | head -1 | cut -d/ -f2) --grace-period=0 --force && kubectl -n $NS rollout status deploy/consumer --timeout=180s"

if $WITH_ALARM; then
  section "7. Freshness alarm: producer stopped, then restored"
  echo "Producer scaled to 0 at $(date -u +%H:%M:%S)"
  kubectl -n "$NS" scale deploy/producer --replicas=0 >/dev/null
  t0=$(date +%s)
  until [[ "$(health_state)" == "ALARM" ]]; do sleep 15; (( $(date +%s) - t0 > 600 )) && break; done
  echo "Health = $(health_state) after $(( $(date +%s) - t0 ))s (target: alarm within ~2-3 min)"
  code health
  kubectl -n "$NS" scale deploy/producer --replicas=1 >/dev/null
  echo "Producer scaled back to 1 at $(date -u +%H:%M:%S)"
  t1=$(date +%s)
  until [[ "$(health_state)" == "OK" ]]; do sleep 15; (( $(date +%s) - t1 > 600 )) && break; done
  echo "Health = $(health_state) after $(( $(date +%s) - t1 ))s"
  code health
fi

section "Whole table"
echo "Duplicates (must be 0 rows):"
code sql "SELECT symbol, trade_id, count(*) FROM trades GROUP BY 1, 2 HAVING count(*) > 1"
code sql "SELECT count(*) AS total_trades, min(trade_time) AS since, max(trade_time) AS latest FROM trades"
echo "End-to-end latency (Binance trade time → row in PostgreSQL), last 10 minutes:"
code sql "SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY ingested_at - trade_time) AS p50,
                 percentile_cont(0.95) WITHIN GROUP (ORDER BY ingested_at - trade_time) AS p95,
                 percentile_cont(0.99) WITHIN GROUP (ORDER BY ingested_at - trade_time) AS p99,
                 max(ingested_at - trade_time) AS max
          FROM trades WHERE ingested_at > now() - interval '10 minutes'"
section "Final health"
code health
echo
echo "Report: $OUT" >&2
