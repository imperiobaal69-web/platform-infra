#!/usr/bin/env bash
# Checks each claim the README makes about the GCP design against the running
# validation environment. Every claim gets a positive check (the allowed path
# works) and, where one exists, a negative check (the forbidden path fails).
# Results go to gcp-validation/results/checks.json.
#
#   PROJECT_ID=my-project gcp-validation/checks.sh
# shellcheck source=gcp-validation/lib.sh
source "$(dirname "$0")/lib.sh"

cluster=$(out cluster_name)
conn=$(out cloudsql_connection_name)
instance=${conn##*:}
app_sa=$(tf output -json workload_identity_service_accounts | jq -r '."audio-jobs-app"')
results=()

record() { # name, ok(true|false), detail
  results+=("$(jq -cn --arg n "$1" --argjson ok "$2" --arg d "$3" '{check:$n, passed:$ok, detail:$d}')")
  printf '%-45s %s  %s\n' "$1" "$([ "$2" = true ] && echo PASS || echo FAIL)" "$3"
}

# Runs a throwaway pod as a given Kubernetes service account. In audio-jobs it
# carries the api's label, so the api's NetworkPolicies apply to it too.
probe() { # namespace, serviceaccount, image, command...
  local ns=$1 sa=$2 image=$3 name="probe-$RANDOM"; shift 3
  # Run to completion, then read the logs: attaching with `kubectl run -i`
  # loses output when the container exits quickly. The pod is compliant with
  # the "restricted" Pod Security level the namespace enforces.
  jq -n --arg ns "$ns" --arg sa "$sa" --arg name "$name" --arg image "$image" --arg cmd "$*" '{
    apiVersion: "v1", kind: "Pod",
    metadata: {name: $name, namespace: $ns, labels: {app: "api"}},
    spec: {
      serviceAccountName: $sa, restartPolicy: "Never",
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "probe", image: $image, command: ["sh", "-c", $cmd],
        env: [{name: "HOME", value: "/tmp"}, {name: "CLOUDSDK_CONFIG", value: "/tmp/gcloud"}],
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}]}}' |
    kubectl apply -f - >/dev/null
  kubectl -n "$ns" wait "pod/$name" --timeout=180s \
    --for=jsonpath='{.status.phase}'=Succeeded >/dev/null 2>&1 ||
    kubectl -n "$ns" wait "pod/$name" --timeout=5s --for=jsonpath='{.status.phase}'=Failed >/dev/null 2>&1 || true
  kubectl -n "$ns" logs "$name" 2>&1 || true
  kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null 2>&1 || true
}
GCLOUD_IMAGE=gcr.io/google.com/cloudsdktool/google-cloud-cli:slim
PSQL_IMAGE=postgres:17-alpine

# External Secrets Operator is not installed for the validation; its service
# account is created so the Workload Identity binding can be exercised.
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n external-secrets create serviceaccount external-secrets --dry-run=client -o yaml |
  kubectl apply -f - >/dev/null
kubectl -n external-secrets annotate serviceaccount external-secrets --overwrite \
  "iam.gke.io/gcp-service-account=external-secrets@$PROJECT_ID.iam.gserviceaccount.com" >/dev/null

log "network: private nodes and restricted control plane"
ext=$(gcloud compute instances list --filter="labels.goog-k8s-cluster-name=$cluster" \
  --format=json | jq '[.[].networkInterfaces[].accessConfigs[]?.natIP] | map(select(.)) | length')
record nodes_have_no_public_ip "$([ "$ext" = 0 ] && echo true || echo false)" "public IPs on nodes: $ext"

desc=$(gcloud container clusters describe "$cluster" --region "$REGION" --format=json)
priv=$(jq -r '.privateClusterConfig.enablePrivateNodes // false' <<<"$desc")
mans=$(jq -r '[.masterAuthorizedNetworksConfig.cidrBlocks[]?.cidrBlock] | join(",")' <<<"$desc")
record control_plane_allowlist_only "$([ "$priv" = true ] && [ -n "$mans" ] && echo true || echo false)" \
  "private nodes: $priv; authorized networks: $mans"

log "Cloud SQL: private IP only, IAM authentication"
sql=$(gcloud sql instances describe "$instance" --format=json)
pub=$(jq -r '.settings.ipConfiguration.ipv4Enabled' <<<"$sql")
types=$(jq -r '[.ipAddresses[].type] | unique | join(",")' <<<"$sql")
record cloudsql_has_no_public_ip "$([ "$pub" = false ] && [ "$types" = PRIVATE ] && echo true || echo false)" \
  "ipv4Enabled=$pub, address types=$types"

users=$(gcloud sql users list --instance "$instance" --format='value(name,type)' | tr '\t' ':' | tr '\n' ' ')
record cloudsql_iam_users_exist "$(grep -q 'CLOUD_IAM_SERVICE_ACCOUNT' <<<"$users" && echo true || echo false)" "$users"

private_ip=$(jq -r '.ipAddresses[] | select(.type=="PRIVATE") | .ipAddress' <<<"$sql")
bypass=$(probe audio-jobs api "$PSQL_IMAGE" "PGCONNECT_TIMEOUT=8 psql 'host=$private_ip dbname=audiojobs user=x sslmode=require' -c 'select 1' 2>&1")
record app_pods_cannot_bypass_the_proxy "$(grep -q 'timeout expired' <<<"$bypass" && echo true || echo false)" \
  "direct to $private_ip:5432 from audio-jobs: $(grep -m1 psql <<<"$bypass")"

# From a namespace without NetworkPolicies, so only Cloud SQL itself decides.
kubectl create namespace cloudsql-check --dry-run=client -o yaml | kubectl apply -f - >/dev/null
login=$(probe cloudsql-check default "$PSQL_IMAGE" "export PGCONNECT_TIMEOUT=8 PGPASSWORD=guess; \
  psql 'host=$private_ip dbname=audiojobs user=${app_sa%.gserviceaccount.com} sslmode=require' -c 'select 1' 2>&1; \
  psql 'host=$private_ip dbname=audiojobs user=postgres sslmode=require' -c 'select 1' 2>&1")
kubectl delete namespace cloudsql-check --wait=false >/dev/null
record cloudsql_rejects_logins_without_iam_token \
  "$(grep -q 'IAM service account authentication failed' <<<"$login" && grep -q 'password authentication failed for user \"postgres\"' <<<"$login" && echo true || echo false)" \
  "$(grep -o 'FATAL: .*' <<<"$login" | tr '\n' ' ')"

log "Workload Identity"
who=$(probe audio-jobs api "$GCLOUD_IMAGE" "curl -fsS -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email")
record wi_api_pod_is_app_service_account "$(grep -qx "$app_sa" <<<"$who" && echo true || echo false)" "identity seen by api pod: $(grep -m1 '@' <<<"$who")"

gcloud secrets versions add grafana-admin-password --data-file=<(head -c 24 /dev/urandom | base64) >/dev/null
allowed=$(probe external-secrets external-secrets "$GCLOUD_IMAGE" "gcloud secrets versions access latest --secret=grafana-admin-password --project=$PROJECT_ID >/dev/null && echo READ_OK")
record wi_external_secrets_can_read_its_secret "$(grep -q READ_OK <<<"$allowed" && echo true || echo false)" "$(tail -1 <<<"$allowed")"
denied=$(probe audio-jobs api "$GCLOUD_IMAGE" "gcloud secrets versions access latest --secret=grafana-admin-password --project=$PROJECT_ID")
record wi_app_cannot_read_platform_secret "$(grep -q PERMISSION_DENIED <<<"$denied" && echo true || echo false)" "$(grep -o 'PERMISSION_DENIED[^.]*' <<<"$denied" | head -1)"

log "GitHub OIDC trust is limited to this repository"
cond=$(gcloud iam workload-identity-pools providers list --location=global \
  --workload-identity-pool="$(basename "$(dirname "$(dirname "$(out ci_workload_identity_provider)")")")" \
  --format='value(attributeCondition)' 2>/dev/null | head -1)
record oidc_condition_pins_repository "$(grep -q 'paulovillalobos/platform-infra' <<<"$cond" && echo true || echo false)" "$cond"

log "end to end: jobs through the API on GKE"
# The load generator's namespace ships with the local overlay only.
kubectl create namespace loadtest --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if (cd "$ROOT" && IMAGE="$(cat "$WORK/image")" JOBS=30 scripts/smoke.sh >"$WORK/smoke.log" 2>&1); then
  record smoke_jobs_processed true "$(tail -1 "$WORK/smoke.log")"
else
  record smoke_jobs_processed false "$(tail -3 "$WORK/smoke.log" | tr '\n' ' ')"
fi

printf '%s\n' "${results[@]}" | jq -s --arg p "$PROJECT_ID" --arg at "$(date -u +%FT%TZ)" \
  '{project:$p, ran_at:$at, region:"'"$REGION"'", checks:., passed:(map(select(.passed))|length), total:length}' \
  >"$RESULTS/checks.json"
jq -r '"\(.passed)/\(.total) checks passed"' "$RESULTS/checks.json"
