#!/usr/bin/env bash
# Drill 03: the Postgres pod is SIGKILLed under load, kept down for HOLD_S
# seconds, and comes back on the same persistent volume (crash recovery from
# the WAL). Pass: API pods leave the
# Service while Postgres is unreachable instead of serving errors, nothing
# that was committed before the crash is missing afterwards, and every
# accepted job succeeds.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
out=drills/results/03-postgres-restart
HOLD_S=${HOLD_S:-30}

cleanup() { [[ -n ${watcher:-} ]] && kill "$watcher" 2>/dev/null || true; }
trap cleanup EXIT

wait_steady
api_replicas=$(kubectl -n "$APP_NS" get deploy api -o jsonpath='{.spec.replicas}')
restarts() {
  kubectl -n "$APP_NS" get pods -l 'app in (api,worker)' \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s += $1} END {print s + 0}'
}
restarts_before=$(restarts)

start_loadgen pg-restart 1 -jobs 2400 -rate 20 -concurrency 32 -duration-ms 2000 -timeout 6m -label postgres-restart
wait_for 180 loadgen_running pg-restart
sleep 30

# Fingerprint of everything committed so far, to compare after recovery.
cutoff=$(psql_data "select now()")
before=$(psql_data "select count(*) || ' ' || md5(string_agg(id::text || status::text, ',' order by id)) from jobs where status = 'succeeded' and finished_at < '$cutoff'")
log "killing postgres-0 ($(cut -d' ' -f1 <<<"$before") succeeded jobs committed)"

alerts_file=$(mktemp)
t0_file=$(mktemp -u)
method=$(kill_method postgres)
started_at=$(date -u +%FT%TZ)
kill_and_hold postgres "$HOLD_S" "$t0_file" &
killer=$!
wait_for 30 test -s "$t0_file"
t0=$(<"$t0_file")
watch_alerts "$alerts_file" "$t0" &
watcher=$!

api_degraded() { [[ $(api_endpoints_ready) -lt $api_replicas ]]; }
api_out() { [[ $(api_endpoints_ready) -eq 0 ]]; }
pg_ready() { [[ $(ready_replicas "$DATA_NS" statefulset/postgres) == 1 ]] && psql_data "select 1"; }
api_back() { [[ $(api_endpoints_ready) -ge $api_replicas ]]; }

wait_for 120 api_degraded
detect=$(secs_since "$t0")
log "first API endpoint removed after ${detect}s"
all_out=null
wait_for 60 api_out && all_out=$(secs_since "$t0")
wait "$killer"
wait_for 300 pg_ready
pg_back=$(secs_since "$t0")
log "postgres ready after ${pg_back}s"
wait_for 300 api_back
recovery=$(secs_since "$t0")
log "all API endpoints ready after ${recovery}s"

crash_recovery=false
kubectl -n "$DATA_NS" logs postgres-0 -c postgres | grep -q 'automatic recovery in progress' && crash_recovery=true
after=$(psql_data "select count(*) || ' ' || md5(string_agg(id::text || status::text, ',' order by id)) from jobs where status = 'succeeded' and finished_at < '$cutoff'")
report=$(wait_loadgen pg-restart 600)
sleep 20 # let the alert watcher see the tail of the incident
kill "$watcher" 2>/dev/null || true
restarts_after=$(restarts)
unfinished=$(psql_data "select count(*) from jobs where status in ('queued','running','failed')")

write_result "$out.json" "$(jq -n \
  --argjson report "$report" --argjson detect "$detect" --argjson recovery "$recovery" \
  --argjson pgback "$pg_back" --argjson hold "$HOLD_S" --arg method "$method" --argjson crashrec "$crash_recovery" --argjson allout "$all_out" \
  --arg before "$before" --arg after "$after" --argjson unfinished "$unfinished" \
  --argjson restarts "$((restarts_after - restarts_before))" \
  --argjson alerts "$(alerts_summary "$alerts_file")" --arg started "$started_at" '{
    drill: "03-postgres-restart",
    title: "Kill and restart Postgres under load",
    started_at: $started,
    fault: "postgres-0 killed (\($method)), kept down \($hold)s, restarted on the same volume",
    detection_signal: "first API pod fails readiness and leaves the Service",
    detection_s: $detect,
    recovery_criterion: "Postgres ready and every API pod back in the Service",
    recovery_s: $recovery,
    jobs_accepted: $report.accepted,
    jobs_lost: $report.lost,
    client_errors: $report.submit_errors,
    alerts: $alerts,
    runbook: "docs/runbooks/postgres-down.md",
    details: {
      all_api_endpoints_removed_s: $allout,
      postgres_ready_s: $pgback,
      kill_method: $method,
      held_down_s: $hold,
      wal_crash_recovery_ran: $crashrec,
      committed_before_crash: ($before | split(" ")[0] | tonumber),
      committed_data_identical_after: ($before == $after),
      unfinished_jobs_after_drain: $unfinished,
      api_and_worker_container_restarts: $restarts
    },
    loadgen: $report
  }')"
