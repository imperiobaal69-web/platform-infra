#!/usr/bin/env bash
# Drill 04: Redis is SIGKILLed under load, kept down for HOLD_S seconds, and
# restarts empty (no persistence),
# so the whole queue and result cache are gone. Postgres still has every job;
# the workers' sweeper re-enqueues the ones that were waiting. Pass: every
# job accepted before or during the outage succeeds.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
out=drills/results/04-redis-restart
HOLD_S=${HOLD_S:-30}

cleanup() { [[ -n ${watcher:-} ]] && kill "$watcher" 2>/dev/null || true; }
trap cleanup EXIT

wait_steady
api_replicas=$(kubectl -n "$APP_NS" get deploy api -o jsonpath='{.spec.replicas}')
swept_before=$(prom_query 'sum(aj_swept_total)')

start_loadgen redis-restart 1 -jobs 2400 -rate 20 -concurrency 32 -duration-ms 2000 -timeout 6m -label redis-restart
wait_for 180 loadgen_running redis-restart
sleep 30

cutoff=$(psql_data "select now()")
log "killing redis-0"
alerts_file=$(mktemp)
t0_file=$(mktemp -u)
method=$(kill_method redis)
started_at=$(date -u +%FT%TZ)
kill_and_hold redis "$HOLD_S" "$t0_file" &
killer=$!
wait_for 30 test -s "$t0_file"
t0=$(<"$t0_file")
watch_alerts "$alerts_file" "$t0" &
watcher=$!

api_degraded() { [[ $(api_endpoints_ready) -lt $api_replicas ]]; }
redis_ready() { [[ $(ready_replicas "$DATA_NS" statefulset/redis) == 1 ]]; }
api_back() { [[ $(api_endpoints_ready) -ge $api_replicas ]]; }
backlog_drained() {
  [[ $(psql_data "select count(*) from jobs where created_at < '$cutoff'::timestamptz + interval '1 minute' and status in ('queued','running','failed')") == 0 ]]
}

wait_for 120 api_degraded
detect=$(secs_since "$t0")
log "first API endpoint removed after ${detect}s"
wait "$killer"
wait_for 300 redis_ready
redis_back=$(secs_since "$t0")
wait_for 300 api_back
api_back_s=$(secs_since "$t0")
log "redis ready after ${redis_back}s, API back after ${api_back_s}s"
recovery=null
if wait_for 600 backlog_drained; then recovery=$(secs_since "$t0"); fi
log "every job accepted up to the outage finished after ${recovery}s"

report=$(wait_loadgen redis-restart 600)
sleep 20
kill "$watcher" 2>/dev/null || true
swept_after=$(prom_query 'sum(aj_swept_total)')
unfinished=$(psql_data "select count(*) from jobs where status in ('queued','running','failed')")

write_result "$out.json" "$(jq -n \
  --argjson report "$report" --argjson detect "$detect" --argjson recovery "$recovery" \
  --argjson redisback "$redis_back" --argjson apiback "$api_back_s" --argjson hold "$HOLD_S" --arg method "$method" \
  --argjson swept "$(awk -v a="${swept_before:-0}" -v b="${swept_after:-0}" 'BEGIN { print b - a }')" \
  --argjson unfinished "$unfinished" \
  --argjson alerts "$(alerts_summary "$alerts_file")" --arg started "$started_at" '{
    drill: "04-redis-restart",
    title: "Restart Redis without persistence (queue lost)",
    started_at: $started,
    fault: "redis-0 killed (\($method)), kept down \($hold)s, restarts with an empty dataset",
    detection_signal: "first API pod fails readiness and leaves the Service",
    detection_s: $detect,
    recovery_criterion: "every job accepted before and during the outage has finished",
    recovery_s: $recovery,
    jobs_accepted: $report.accepted,
    jobs_lost: $report.lost,
    client_errors: $report.submit_errors,
    alerts: $alerts,
    runbook: "docs/runbooks/redis-down.md",
    details: {
      kill_method: $method,
      held_down_s: $hold,
      redis_ready_s: $redisback,
      api_back_in_service_s: $apiback,
      jobs_reenqueued_by_sweeper: $swept,
      unfinished_jobs_after_drain: $unfinished
    },
    loadgen: $report
  }')"
