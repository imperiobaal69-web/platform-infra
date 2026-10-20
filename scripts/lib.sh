#!/usr/bin/env bash
# Shared helpers for scripts/smoke.sh and drills/*.sh. Source it; do not run.
# shellcheck disable=SC2034 # variables are used by the scripts that source this

APP_NS=audio-jobs
DATA_NS=audio-jobs-data
LOAD_NS=loadtest
API_URL=http://api.audio-jobs.svc.cluster.local
IMAGE=${IMAGE:-audio-jobs:local}
BUSYBOX=busybox:1.37.0

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Milliseconds since the epoch (portable: macOS date has no %N).
now_ms() { perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)'; }

# secs_since <start_ms> -> seconds with one decimal
secs_since() { awk -v a="$1" -v b="$(now_ms)" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }

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

# start_loadgen <name> <loadgen flags...>: runs cmd/loadgen from the workload
# image as a Job in the loadtest namespace.
start_loadgen() {
  local name=$1
  shift
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
            limits: {cpu: "1", memory: 768Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
EOF
}

loadgen_finished() {
  local s
  s=$(kubectl -n "$LOAD_NS" get job "$1" -o jsonpath='{.status.succeeded}{.status.failed}')
  [[ -n $s ]]
}

# wait_loadgen <name> <timeout_s>: waits for the Job and prints its JSON
# report (the loadgen exits non-zero when any job did not succeed, so the
# Job outcome itself is not checked here).
wait_loadgen() {
  local name=$1 timeout=${2:-900}
  wait_for "$timeout" loadgen_finished "$name" || {
    log "loadgen $name did not finish in ${timeout}s"
    return 1
  }
  kubectl -n "$LOAD_NS" logs "job/$name" | sed -n '/^{/,/^}/p'
}

# psql_data <sql>: runs SQL as the superuser inside the Postgres pod.
psql_data() {
  kubectl -n "$DATA_NS" exec postgres-0 -c postgres -- psql -U postgres -d audiojobs -qAt -c "$1"
}

# prom_query <promql>: instant query through the API server proxy, prints the
# first sample value (empty if none).
prom_query() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/http:prometheus-operated:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" |
    jq -r '.data.result[0].value[1] // empty'
}

# firing_alerts: names of alerts currently firing for the workload.
firing_alerts() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/http:prometheus-operated:9090/proxy/api/v1/alerts" |
    jq -r '[.data.alerts[] | select(.state == "firing") | .labels.alertname] | unique | join(",")'
}

ready_replicas() {
  kubectl -n "$1" get "$2" -o jsonpath='{.status.readyReplicas}'
}

# api_endpoints_ready: number of ready API endpoints behind the Service.
api_endpoints_ready() {
  kubectl -n "$APP_NS" get endpointslices -l kubernetes.io/service-name=api \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' | grep -c true || true
}
