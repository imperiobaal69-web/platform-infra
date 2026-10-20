#!/usr/bin/env bash
# Drill 06: a broken API release under load. The new revision listens on the
# wrong port, so its pods never pass readiness. With maxUnavailable 0 the old
# pods keep serving; the Deployment hits its progress deadline and
# scripts/rollout-guard.sh rolls back. Pass: rollback happens without a
# human, no client errors, no lost jobs.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
out=drills/results/06-bad-deploy

cleanup() {
  [[ -n ${watcher:-} ]] && kill "$watcher" 2>/dev/null || true
  [[ -n ${sampler:-} ]] && kill "$sampler" 2>/dev/null || true
}
trap cleanup EXIT

wait_steady
api_replicas=$(kubectl -n "$APP_NS" get deploy api -o jsonpath='{.spec.replicas}')
deadline=$(kubectl -n "$APP_NS" get deploy api -o jsonpath='{.spec.progressDeadlineSeconds}')
image_before=$(kubectl -n "$APP_NS" get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}')

start_loadgen bad-deploy 1 -jobs 3000 -rate 20 -concurrency 32 -duration-ms 2000 -timeout 6m -label bad-deploy
wait_for 180 loadgen_running bad-deploy
sleep 15

alerts_file=$(mktemp)
endpoints_file=$(mktemp)
guard_log=$(mktemp)
t0=$(now_ms)
started_at=$(date -u +%FT%TZ)
watch_alerts "$alerts_file" "$t0" &
watcher=$!
(while true; do api_endpoints_ready >>"$endpoints_file"; sleep 1; done) &
sampler=$!

log "releasing a broken API revision (HTTP_ADDR=:8081, probes and Service expect 8080)"
kubectl -n "$APP_NS" set env deployment/api HTTP_ADDR=:8081 >/dev/null
set +e
scripts/rollout-guard.sh "$APP_NS" api 600s 2>&1 | while IFS= read -r line; do
  printf '%s %s\n' "$(now_ms)" "$line"
done >"$guard_log"
guard_exit=${PIPESTATUS[0]}
set -e
done_ms=$(now_ms)
failed_ms=$(awk '/failed; rolling back/ {print $1; exit}' "$guard_log")
[[ $guard_exit == 2 && -n $failed_ms ]] || { cat "$guard_log" >&2; log "expected a rollback (exit 2), got $guard_exit"; exit 1; }
detect=$(secs_between "$t0" "$failed_ms")
rollback=$(secs_between "$failed_ms" "$done_ms")
recovery=$(secs_between "$t0" "$done_ms")
log "rollout declared failed after ${detect}s, rolled back in ${rollback}s"

report=$(wait_loadgen bad-deploy 600)
sleep 10
kill "$watcher" "$sampler" 2>/dev/null || true
min_endpoints=$(sort -n "$endpoints_file" | head -1)
addr_after=$(kubectl -n "$APP_NS" get deploy api -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HTTP_ADDR")].value}')
image_after=$(kubectl -n "$APP_NS" get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}')

write_result "$out.json" "$(jq -n \
  --argjson report "$report" --argjson detect "$detect" --argjson recovery "$recovery" \
  --argjson rollback "$rollback" --argjson deadline "$deadline" \
  --argjson minep "$min_endpoints" --argjson replicas "$api_replicas" \
  --arg addr "$addr_after" --argjson sameimage "$([[ $image_before == "$image_after" ]] && echo true || echo false)" \
  --argjson alerts "$(alerts_summary "$alerts_file")" --arg started "$started_at" '{
    drill: "06-bad-deploy",
    title: "Bad deploy (failing readiness) rolled back automatically",
    started_at: $started,
    fault: "API revision listening on the wrong port; readiness never passes",
    detection_signal: "Deployment exceeds progressDeadlineSeconds (\($deadline)s); rollout-guard sees it",
    detection_s: $detect,
    recovery_criterion: "previous revision fully rolled out again",
    recovery_s: $recovery,
    jobs_accepted: $report.accepted,
    jobs_lost: $report.lost,
    client_errors: $report.submit_errors,
    alerts: $alerts,
    runbook: "docs/runbooks/bad-deploy.md",
    details: {
      rollback_duration_s: $rollback,
      min_ready_api_endpoints_during_rollout: $minep,
      api_replicas: $replicas,
      http_addr_after_rollback: $addr,
      image_unchanged: $sameimage
    },
    loadgen: $report
  }')"
