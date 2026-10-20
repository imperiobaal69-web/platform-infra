#!/usr/bin/env bash
# Drill 01: sustained load drives the HPAs to scale out, and they scale back
# in after the load stops. Records a 5-second timeline of replicas and CPU
# utilisation next to the summary.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
out=drills/results/01-hpa-scale-out
PODS=${PODS:-3}            # parallel load generators
RATE=${RATE:-100}          # submissions per second, per generator
LOAD_SECONDS=${LOAD_SECONDS:-120}
jobs=$((RATE * LOAD_SECONDS))

hpa() { kubectl -n "$APP_NS" get hpa "$1" -o jsonpath="$2"; }
at_min() {
  [[ $(hpa worker '{.status.currentReplicas}') == "$(hpa worker '{.spec.minReplicas}')" &&
    $(hpa api '{.status.currentReplicas}') == "$(hpa api '{.spec.minReplicas}')" ]]
}
sample() {
  local phase=$1
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(secs_since "$t0")" "$phase" \
    "$(hpa worker '{.status.currentReplicas}')" "$(hpa worker '{.status.desiredReplicas}')" \
    "$(hpa worker '{.status.currentMetrics[0].resource.current.averageUtilization}')" \
    "$(hpa api '{.status.currentReplicas}')" "$(hpa api '{.status.desiredReplicas}')" \
    "$(hpa api '{.status.currentMetrics[0].resource.current.averageUtilization}')" >>"$out.timeline.csv"
}

wait_steady
log "waiting for both HPAs to be at their minimum"
wait_for 600 at_min || { log "HPAs did not return to minimum"; exit 1; }
min_worker=$(hpa worker '{.spec.minReplicas}')
max_worker=$(hpa worker '{.spec.maxReplicas}')
min_api=$(hpa api '{.spec.minReplicas}')

echo "t_s,phase,worker_current,worker_desired,worker_cpu_pct,api_current,api_desired,api_cpu_pct" >"$out.timeline.csv"
log "starting $PODS load generators x $RATE jobs/s for ${LOAD_SECONDS}s"
start_loadgen hpa-load "$PODS" -jobs "$jobs" -rate "$RATE" -concurrency 32 -duration-ms 500 -timeout 5m -label hpa
wait_for 180 loadgen_running hpa-load
t0=$(now_ms)
started_at=$(date -u +%FT%TZ)

first_scale_out=null peak_worker=$min_worker peak_api=$min_api peak_worker_at=null
while ! loadgen_finished hpa-load; do
  sample load
  cur=$(hpa worker '{.status.currentReplicas}')
  api_cur=$(hpa api '{.status.currentReplicas}')
  if [[ $first_scale_out == null && $(hpa worker '{.status.desiredReplicas}') -gt $min_worker ]]; then
    first_scale_out=$(secs_since "$t0")
    log "worker HPA scaling out after ${first_scale_out}s"
  fi
  if ((cur > peak_worker)); then peak_worker=$cur peak_worker_at=$(secs_since "$t0"); fi
  if ((api_cur > peak_api)); then peak_api=$api_cur; fi
  sleep 5
done
load_end_ms=$(now_ms)
load_seconds=$(secs_between "$t0" "$load_end_ms")
log "load finished after ${load_seconds}s; peak workers $peak_worker, peak api $peak_api"

until at_min; do
  sample cooldown
  if (($(now_ms) - load_end_ms > 900000)); then
    log "HPAs did not scale back in within 15 minutes"
    break
  fi
  sleep 5
done
sample idle
scale_in=null
at_min && scale_in=$(secs_since "$load_end_ms")
log "back at minimum ${scale_in}s after the load stopped"

report=$(wait_loadgen hpa-load 120)
write_result "$out.json" "$(jq -n \
  --argjson report "$report" --argjson first "$first_scale_out" --argjson scalein "$scale_in" \
  --argjson peakw "$peak_worker" --argjson peakwat "$peak_worker_at" --argjson peaka "$peak_api" \
  --argjson minw "$min_worker" --argjson maxw "$max_worker" --argjson mina "$min_api" \
  --argjson loads "$load_seconds" --arg started "$started_at" '{
    drill: "01-hpa-scale-out",
    title: "Load test: HPA scale-out and scale-in",
    started_at: $started,
    fault: "\($report.pods) load generators submitting \($report.jobs) jobs over \($loads)s",
    detection_signal: "worker HPA desired replicas above minimum",
    detection_s: $first,
    recovery_criterion: "both HPAs back at minimum after the load stops",
    recovery_s: $scalein,
    jobs_accepted: $report.accepted,
    jobs_lost: $report.lost,
    client_errors: $report.submit_errors,
    runbook: "docs/runbooks/capacity.md",
    details: {
      worker_replicas: {min: $minw, peak: $peakw, max: $maxw, peak_reached_s: $peakwat},
      api_replicas: {min: $mina, peak: $peaka},
      throughput_jobs_per_sec: $report.throughput_jobs_per_sec,
      e2e_p95_ms_worst_generator: $report.e2e_p95_ms,
      timeline: "drills/results/01-hpa-scale-out.timeline.csv"
    },
    loadgen: $report
  }')"
