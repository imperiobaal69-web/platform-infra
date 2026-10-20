#!/usr/bin/env bash
# Shared helpers for scripts/smoke.sh and drills/*.sh. Source it; do not run.
# shellcheck disable=SC2034 # variables are used by the scripts that source this

APP_NS=audio-jobs
DATA_NS=audio-jobs-data
LOAD_NS=loadtest
API_URL=http://api.audio-jobs.svc.cluster.local
IMAGE=${IMAGE:-audio-jobs:local}
BUSYBOX=busybox:1.37.0
PROM=/api/v1/namespaces/monitoring/services/http:prometheus-operated:9090/proxy

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Milliseconds since the epoch (portable: macOS date has no %N).
now_ms() { perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)'; }

# secs_between <start_ms> <end_ms> -> seconds with one decimal
secs_between() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }
secs_since() { secs_between "$1" "$(now_ms)"; }

# wait_for <timeout_s> <command...>: polls every 0.5s until the command
# succeeds. Returns 1 on timeout.
wait_for() {
  local timeout=$1
  shift
  local deadline=$(($(date +%s) + timeout))
  until "$@" >/dev/null 2>&1; do
    if (($(date +%s) >= deadline)); then
      return 1
    fi
    sleep 0.5
  done
}

# start_loadgen <name> <pods> <loadgen flags...>: runs cmd/loadgen from the
# workload image as a Job in the loadtest namespace, <pods> copies in
# parallel. Each copy seeds its recordings from its start time, so they never
# share a result-cache entry.
start_loadgen() {
  local name=$1 pods=$2
  shift 2
  local args="" a
  for a in "$@"; do args+="            - \"$a\""$'\n'; done
  kubectl -n "$LOAD_NS" delete job "$name" --ignore-not-found --wait=true >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: $LOAD_NS
  labels: {app: loadgen}
spec:
  completions: $pods
  parallelism: $pods
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: {app: loadgen}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: {type: RuntimeDefault}
      # A new pod's first connections can be rejected until the network
      # policy controller has added its IP to the allowed sets (about 1s on
      # k3s). Wait until the API answers so the measurement starts clean.
      initContainers:
        - name: wait-for-api
          image: $BUSYBOX
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "until wget -q -T 2 -O /dev/null $API_URL/readyz; do sleep 0.5; done"]
          resources:
            requests: {cpu: 10m, memory: 8Mi}
            limits: {cpu: 100m, memory: 32Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
      containers:
        - name: loadgen
          image: $IMAGE
          imagePullPolicy: IfNotPresent
          command: ["/usr/local/bin/loadgen"]
          args:
            - "-api"
            - "$API_URL"
$args          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits: {cpu: "2", memory: 1Gi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
EOF
}

# loadgen_running <name>: true once every loadgen container has started
# (the init container has seen the API answer).
loadgen_running() {
  local want got
  want=$(kubectl -n "$LOAD_NS" get job "$1" -o jsonpath='{.spec.parallelism}')
  got=$(kubectl -n "$LOAD_NS" get pods -l "job-name=$1" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.running.startedAt}{.status.containerStatuses[0].state.terminated.startedAt}{"\n"}{end}' | grep -c . || true)
  [[ $got -ge $want ]]
}

loadgen_finished() {
  local want finished
  want=$(kubectl -n "$LOAD_NS" get job "$1" -o jsonpath='{.spec.completions}')
  finished=$(kubectl -n "$LOAD_NS" get job "$1" -o jsonpath='{.status.succeeded} {.status.failed}' | awk '{print $1 + $2}')
  [[ $finished -ge $want ]]
}

# wait_loadgen <name> <timeout_s>: waits for every loadgen pod and prints one
# combined JSON report. Counts are summed; latency percentiles are the worst
# pod's (percentiles cannot be merged exactly). The loadgen exits non-zero
# when any job did not succeed, so the Job status itself is not checked.
wait_loadgen() {
  local name=$1 timeout=${2:-900}
  wait_for "$timeout" loadgen_finished "$name" || {
    log "loadgen $name did not finish in ${timeout}s"
    return 1
  }
  kubectl -n "$LOAD_NS" logs -l "job-name=$name" -c loadgen --tail=-1 --max-log-requests=10 |
    sed -n '/^{/,/^}/p' |
    jq -s '{
      pods: length,
      jobs: (map(.jobs) | add),
      succeeded: (map(.succeeded) | add),
      dead: (map(.dead) | add),
      submit_errors: (map(.submit_errors) | add),
      timed_out: (map(.timed_out) | add),
      integrity_failed: (map(.integrity_failed) | add),
      retried: (map(.retried) | add),
      wall_seconds: (map(.wall_seconds) | max),
      throughput_jobs_per_sec: (map(.throughput_jobs_per_sec) | add),
      submit_p99_ms: (map(.submit_p99_ms) | max),
      e2e_p50_ms: (map(.e2e_p50_ms) | max),
      e2e_p95_ms: (map(.e2e_p95_ms) | max),
      e2e_p99_ms: (map(.e2e_p99_ms) | max)
    } | . + {accepted: (.jobs - .submit_errors), lost: (.jobs - .submit_errors - .succeeded)}'
}

# psql_data <sql>: runs SQL as the superuser inside the Postgres pod.
psql_data() {
  kubectl -n "$DATA_NS" exec postgres-0 -c postgres -- psql -U postgres -d audiojobs -qAt -c "$1"
}

# prom_query <promql>: instant query through the API server proxy; prints the
# first sample value (empty if none).
prom_query() {
  kubectl get --raw "$PROM/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" |
    jq -r '.data.result[0].value[1] // empty'
}

# watch_alerts <outfile> <t0_ms>: run in the background. Every 5s appends
# "<seconds since t0> <alertname> <state>" for workload alerts that are
# pending or firing.
watch_alerts() {
  local out=$1 t0=$2
  while true; do
    kubectl get --raw "$PROM/api/v1/alerts" 2>/dev/null |
      jq -r '.data.alerts[] | select(.labels.alertname | startswith("AudioJobs")) | "\(.labels.alertname) \(.state)"' |
      while read -r name state; do echo "$(secs_since "$t0") $name $state"; done >>"$out" || true
    sleep 5
  done
}

# alerts_summary <file>: JSON list of {alert, first_pending_s, first_firing_s}.
alerts_summary() {
  [[ -s $1 ]] || { echo '[]'; return; }
  awk '{ k = $2; if ($3 == "pending" && !(k in p)) p[k] = $1; if ($3 == "firing" && !(k in f)) f[k] = $1; seen[k] = 1 }
       END { for (k in seen) printf "%s %s %s\n", k, (k in p ? p[k] : "null"), (k in f ? f[k] : "null") }' "$1" |
    jq -R -s 'split("\n") | map(select(length > 0) | split(" ") | {alert: .[0], first_pending_s: (.[1] | fromjson), first_firing_s: (.[2] | fromjson)})'
}

ready_replicas() {
  kubectl -n "$1" get "$2" -o jsonpath='{.status.readyReplicas}'
}

# api_endpoints_ready: number of ready API endpoints behind the Service.
api_endpoints_ready() {
  kubectl -n "$APP_NS" get endpointslices -l kubernetes.io/service-name=api \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' | grep -c true || true
}

deployment_settled() {
  local d=$1 spec ready updated
  read -r spec ready updated < <(kubectl -n "$APP_NS" get deploy "$d" \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas} {.status.updatedReplicas}')
  [[ $spec == "$ready" && $spec == "$updated" ]] && [[ $(kubectl -n "$APP_NS" get pods -l "app=$d" --no-headers | wc -l) -eq $spec ]]
}

no_unfinished_jobs() {
  [[ $(psql_data "select count(*) from jobs where status in ('queued','running','failed')") == 0 ]]
}

# wait_steady: every component ready, no rollout in progress, no unfinished
# jobs left over from a previous run.
wait_steady() {
  log "waiting for steady state"
  kubectl -n "$DATA_NS" rollout status statefulset/postgres --timeout=300s >/dev/null
  kubectl -n "$DATA_NS" rollout status statefulset/redis --timeout=300s >/dev/null
  wait_for 600 deployment_settled api || { log "api not settled"; return 1; }
  wait_for 600 deployment_settled worker || { log "worker not settled"; return 1; }
  wait_for 600 no_unfinished_jobs || { log "unfinished jobs remain"; return 1; }
}

# write_result <file> <json>: pretty-prints a drill result.
write_result() {
  jq . <<<"$2" >"$1"
  log "wrote $1"
}
