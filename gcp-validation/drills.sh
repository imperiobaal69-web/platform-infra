#!/usr/bin/env bash
# Failure drills that only exist on GCP, run under load against the
# validation environment. Each writes gcp-validation/results/drill-*.json.
#
#   PROJECT_ID=my-project gcp-validation/drills.sh
# shellcheck source=gcp-validation/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
IMAGE=$(cat "$WORK/image")
instance=$(out cloudsql_connection_name); instance=${instance##*:}
RATE=${RATE:-5}

now() { date +%s; }

# A steady rate for a fixed time, so the load is still running when the fault
# lands. (A first version sent 400 jobs unthrottled: they finished in 5 s, 40 s
# before the fault, and "0 jobs lost" meant nothing. finish() now checks.
# Recordings are 5 s: with 30 s ones the load generator, which holds what it
# sends, was OOM-killed at its 1 GiB limit six minutes in.)
load() { # name, seconds of load
  LOAD_START=$(now)
  start_loadgen "$1" 1 -jobs $(( RATE * $2 )) -rate "$RATE" -concurrency 16 \
    -duration-ms 5000 -timeout 15m -label "$1"
}

finish() { # name, fault time (epoch s), extra json -> writes the result file
  local name=$1 fault_at=$2 extra=$3 report
  report=$(wait_loadgen "$name" 1800)
  jq -n --arg d "$name" --arg at "$(date -u +%FT%TZ)" --argjson r "$report" --argjson x "$extra" \
    --argjson f $(( fault_at - LOAD_START )) '
    {drill:$d, finished_at:$at, fault_at_s:$f, load_wall_s:$r.wall_seconds,
     fault_inside_load_window:($f > 0 and $f < $r.wall_seconds),
     jobs_accepted:$r.accepted, jobs_succeeded:$r.succeeded, submit_errors:$r.submit_errors,
     retried:$r.retried, integrity_failed:$r.integrity_failed, jobs_lost:$r.lost,
     e2e_p95_ms:$r.e2e_p95_ms, e2e_p99_ms:$r.e2e_p99_ms, loadgen:$r} + $x' \
    | tee "$RESULTS/drill-$name.json"
  jq -e '.fault_inside_load_window' "$RESULTS/drill-$name.json" >/dev/null ||
    { echo "INVALID: the fault did not happen during the load"; exit 1; }
}

log "drill: lose a node that runs a worker, under load"
load gcp-node-loss 360
sleep 45
# A worker's node, but not the one running the load generator.
lg_node=$(kubectl -n "$LOAD_NS" get pods -l job-name=gcp-node-loss -o jsonpath='{.items[0].spec.nodeName}')
read -r pod node < <(kubectl -n "$APP_NS" get pods -l app=worker \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | awk -v n="$lg_node" '$2 != n' | head -1)
[ -n "$node" ] || { echo "every worker shares the load generator's node"; exit 1; }
zone=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
t0=$(now)
gcloud compute instances delete "$node" --zone "$zone" --quiet
kubectl -n "$APP_NS" wait pod "$pod" --for=delete --timeout=600s >/dev/null 2>&1 || true
until [ "$(kubectl -n "$APP_NS" get deploy worker -o jsonpath='{.status.availableReplicas}')" -ge 2 ] 2>/dev/null; do sleep 5; done
t_workers=$(( $(now) - t0 ))
until kubectl get node "$node" >/dev/null 2>&1 &&
  [ "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; do sleep 10; done
t_node=$(( $(now) - t0 ))
finish gcp-node-loss "$t0" "$(jq -n --arg n "$node" --arg z "$zone" --argjson w "$t_workers" --argjson v "$t_node" \
  '{fault:"VM \($n) in \($z) deleted while running a worker", workers_back_after_s:$w, node_recreated_after_s:$v}')"

log "drill: restart Cloud SQL under load"
load gcp-cloudsql-restart 180
sleep 45
t0=$(now)
gcloud sql instances restart "$instance" --quiet
t_sql=$(( $(now) - t0 ))
finish gcp-cloudsql-restart "$t0" "$(jq -n --arg i "$instance" --argjson s "$t_sql" \
  '{fault:"Cloud SQL instance \($i) restarted (single zone, no HA)", restart_operation_s:$s}')"
