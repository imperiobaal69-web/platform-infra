#!/usr/bin/env bash
# Drill 02: every worker pod is killed while jobs are in flight. Each job is
# slowed to 5s with the workload's CHAOS_PROCESS_DELAY test hook so that the
# kill lands mid-job (real jobs take milliseconds). Pass: the jobs that were
# in flight are reclaimed by the replacement pods and succeed; nothing lost.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
out=drills/results/02-worker-kill
DELAY=5s

cleanup() {
  kubectl -n "$APP_NS" set env deployment/worker CHAOS_PROCESS_DELAY- >/dev/null 2>&1 || true
  [[ -n ${watcher:-} ]] && kill "$watcher" 2>/dev/null || true
}
trap cleanup EXIT

wait_steady
log "slowing every job to $DELAY"
kubectl -n "$APP_NS" set env deployment/worker CHAOS_PROCESS_DELAY="$DELAY" >/dev/null
kubectl -n "$APP_NS" rollout status deployment/worker --timeout=300s >/dev/null
wait_for 300 deployment_settled worker

start_loadgen worker-kill 1 -jobs 150 -rate 1.5 -concurrency 16 -duration-ms 2000 -timeout 6m -label worker-kill
wait_for 180 loadgen_running worker-kill
sleep 30

victims=$(kubectl -n "$APP_NS" get pods -l app=worker -o jsonpath='{.items[*].metadata.name}')
inflight_ids=$(psql_data "select string_agg(quote_literal(id::text), ',') from jobs where status = 'running'")
inflight=$(psql_data "select count(*) from jobs where status = 'running'")
[[ $inflight -gt 0 ]] || { log "no job in flight at kill time; drill invalid"; exit 1; }
log "killing workers [$victims] with $inflight jobs in flight"

alerts_file=$(mktemp)
t0=$(now_ms)
started_at=$(date -u +%FT%TZ)
watch_alerts "$alerts_file" "$t0" &
watcher=$!
# shellcheck disable=SC2086 # victims is a list of pod names
kubectl -n "$APP_NS" delete pod $victims --grace-period=0 --force --wait=false >/dev/null 2>&1

replacement_ready() {
  local p
  for p in $(kubectl -n "$APP_NS" get pods -l app=worker \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].ready}{"\n"}{end}' | grep '=true$' | cut -d= -f1); do
    [[ " $victims " != *" $p "* ]] && return 0
  done
  return 1
}
reclaimed() { [[ $(psql_data "select count(*) from jobs where id in ($inflight_ids) and attempts > 1") -gt 0 ]]; }
inflight_done() { [[ $(psql_data "select count(*) from jobs where id in ($inflight_ids) and status = 'succeeded'") == "$inflight" ]]; }

wait_for 300 replacement_ready
detect=$(secs_since "$t0")
log "first replacement worker ready after ${detect}s"
wait_for 300 reclaimed
reclaim=$(secs_since "$t0")
log "first orphaned job restarted after ${reclaim}s"
recovery=null
if wait_for 600 inflight_done; then recovery=$(secs_since "$t0"); fi
log "all $inflight interrupted jobs succeeded after ${recovery}s"

report=$(wait_loadgen worker-kill 600)
kill "$watcher" 2>/dev/null || true
retried=$(psql_data "select count(*) from jobs where id in ($inflight_ids) and attempts > 1")
write_result "$out.json" "$(jq -n \
  --argjson report "$report" --argjson detect "$detect" --argjson recovery "$recovery" \
  --argjson reclaim "$reclaim" --argjson inflight "$inflight" --argjson retried "$retried" \
  --argjson killed "$(wc -w <<<"$victims")" --argjson alerts "$(alerts_summary "$alerts_file")" \
  --arg started "$started_at" --arg delay "$DELAY" '{
    drill: "02-worker-kill",
    title: "Kill all worker pods mid-job",
    started_at: $started,
    fault: "\($killed) worker pods force-deleted with \($inflight) jobs in flight",
    detection_signal: "replacement worker pod ready",
    detection_s: $detect,
    recovery_criterion: "every job in flight at the kill has succeeded",
    recovery_s: $recovery,
    jobs_accepted: $report.accepted,
    jobs_lost: $report.lost,
    client_errors: $report.submit_errors,
    alerts: $alerts,
    runbook: "docs/runbooks/workers-unavailable.md",
    details: {
      jobs_in_flight_at_kill: $inflight,
      interrupted_jobs_retried: $retried,
      first_orphan_restarted_s: $reclaim,
      job_processing_delay: $delay
    },
    loadgen: $report
  }')"
