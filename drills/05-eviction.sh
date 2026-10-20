#!/usr/bin/env bash
# Drill 05: what a node drain or node-pool upgrade does to the workload.
# Every api and worker pod is evicted through the Eviction API, retrying the
# ones a PodDisruptionBudget refuses, the way `kubectl drain` does. The node
# itself is not cordoned: this cluster has one node, so cordoning it would
# leave the replacements nowhere to run. Pass: no client errors, no lost jobs.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
out=drills/results/05-eviction

cleanup() { [[ -n ${watcher:-} ]] && kill "$watcher" 2>/dev/null || true; }
trap cleanup EXIT

wait_steady
start_loadgen eviction 1 -jobs 2400 -rate 20 -concurrency 32 -duration-ms 2000 -timeout 6m -label eviction
wait_for 180 loadgen_running eviction
sleep 20

victims=$(kubectl -n "$APP_NS" get pods -l 'app in (api,worker)' -o jsonpath='{.items[*].metadata.name}')
log "evicting: $victims"
alerts_file=$(mktemp)
t0=$(now_ms)
started_at=$(date -u +%FT%TZ)
watch_alerts "$alerts_file" "$t0" &
watcher=$!

evicted=0 refused=0 remaining=$victims
while [[ -n $remaining ]]; do
  next=""
  for p in $remaining; do
    if ! kubectl -n "$APP_NS" get pod "$p" >/dev/null 2>&1; then
      continue
    fi
    if msg=$(kubectl create --raw "/api/v1/namespaces/$APP_NS/pods/$p/eviction" -f - 2>&1 <<EOF
{"apiVersion": "policy/v1", "kind": "Eviction", "metadata": {"name": "$p", "namespace": "$APP_NS"}}
EOF
    ); then
      evicted=$((evicted + 1))
      log "evicted $p"
    elif grep -q 'disruption budget' <<<"$msg"; then
      refused=$((refused + 1))
      next+="$p "
    else
      log "eviction of $p failed: $msg"
      next+="$p "
    fi
  done
  remaining=${next% }
  [[ -n $remaining ]] && sleep 2
  if (($(now_ms) - t0 > 900000)); then
    log "eviction did not complete in 15 minutes"
    exit 1
  fi
done
evict_done=$(secs_since "$t0")
log "all $evicted pods evicted after ${evict_done}s ($refused refusals by PDBs)"

victims_gone() {
  local p
  for p in $victims; do
    kubectl -n "$APP_NS" get pod "$p" >/dev/null 2>&1 && return 1
  done
  return 0
}
wait_for 300 victims_gone
wait_for 300 deployment_settled api
wait_for 300 deployment_settled worker
recovery=$(secs_since "$t0")
log "deployments settled with all-new pods after ${recovery}s"

report=$(wait_loadgen eviction 600)
kill "$watcher" 2>/dev/null || true
write_result "$out.json" "$(jq -n \
  --argjson report "$report" --argjson recovery "$recovery" --argjson evictdone "$evict_done" \
  --argjson evicted "$evicted" --argjson refused "$refused" \
  --argjson alerts "$(alerts_summary "$alerts_file")" --arg started "$started_at" '{
    drill: "05-eviction",
    title: "Evict every api and worker pod (drain), PDBs enforced",
    started_at: $started,
    fault: "\($evicted) pods evicted through the Eviction API under load",
    detection_signal: "n/a (planned disruption; PDBs pace it)",
    detection_s: null,
    recovery_criterion: "all evicted pods replaced and ready",
    recovery_s: $recovery,
    jobs_accepted: $report.accepted,
    jobs_lost: $report.lost,
    client_errors: $report.submit_errors,
    alerts: $alerts,
    runbook: "docs/runbooks/workers-unavailable.md",
    details: {
      evictions_refused_by_pdb: $refused,
      all_evictions_accepted_s: $evictdone
    },
    loadgen: $report
  }')"
