#!/usr/bin/env bash
# Stand up the validation environment in a real GCP project, deploy
# audio-jobs to it and run a smoke test. Sized down from production (one
# small node per zone, no HA database, basic Redis) but the same modules.
#
#   PROJECT_ID=my-project gcp-validation/up.sh
# shellcheck source=gcp-validation/lib.sh
source "$(dirname "$0")/lib.sh"

log "preflight"
gcloud config set project "$PROJECT_ID" >/dev/null
billing=$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingAccountName)')
[ -n "$billing" ] || { echo "billing is not enabled on $PROJECT_ID"; exit 1; }
my_ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')

log "budget alert at 10 (account currency), 50/90/100%"
gcloud services enable billingbudgets.googleapis.com cloudbuild.googleapis.com >/dev/null
if ! gcloud billing budgets list --billing-account="${billing#billingAccounts/}" \
     --format='value(displayName)' | grep -qx "platform-infra-validation"; then
  gcloud billing budgets create --billing-account="${billing#billingAccounts/}" \
    --display-name="platform-infra-validation" --budget-amount=10 \
    --filter-projects="projects/$PROJECT_ID" \
    --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 >/dev/null
fi

log "state bucket (terraform/bootstrap)"
terraform -chdir="$ROOT/terraform/bootstrap" init -input=false >/dev/null
terraform -chdir="$ROOT/terraform/bootstrap" apply -input=false -auto-approve -var "project_id=$PROJECT_ID"
printf 'bucket = "%s-tfstate"\n' "$PROJECT_ID" >"$WORK/backend.hcl"

cat >"$WORK/validation.tfvars" <<TFVARS
project_id           = "$PROJECT_ID"
region               = "$REGION"
environment          = "$ENVIRONMENT"
master_authorized_networks = [{ name = "validation-operator", cidr = "$my_ip/32" }]
node_machine_type    = "e2-standard-2"
node_min_count       = 1
node_max_count       = 2
db_tier              = "db-custom-1-3840"
db_high_availability = false
redis_tier           = "BASIC"
redis_memory_gb      = 1
deletion_protection  = false
TFVARS

log "terraform apply"
tf init -input=false -reconfigure -backend-config="$WORK/backend.hcl" >/dev/null
tf apply -input=false -auto-approve -var-file="$WORK/validation.tfvars"

log "build and push the audio-jobs image (Cloud Build, own service account)"
# New projects run Cloud Build as the default Compute Engine service account,
# which no longer gets storage or registry access. Builds get a dedicated
# account with only what a build needs instead of widening that default.
builder="image-builder@$PROJECT_ID.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$builder" >/dev/null 2>&1 ||
  gcloud iam service-accounts create image-builder --display-name="Cloud Build: audio-jobs image" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$builder" \
  --role=roles/logging.logWriter --condition=None >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${PROJECT_ID}_cloudbuild" \
  --member="serviceAccount:$builder" --role=roles/storage.objectViewer >/dev/null 2>&1 ||
  gcloud storage buckets create "gs://${PROJECT_ID}_cloudbuild" --location="$REGION" >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${PROJECT_ID}_cloudbuild" \
  --member="serviceAccount:$builder" --role=roles/storage.objectViewer >/dev/null
gcloud artifacts repositories add-iam-policy-binding audio-jobs --location="$REGION" \
  --member="serviceAccount:$builder" --role=roles/artifactregistry.writer >/dev/null
image="$(out image_repository):$(git -C "$AUDIO_JOBS_SRC" rev-parse --short HEAD)"
cat >"$WORK/cloudbuild.yaml" <<YAML
steps:
  - name: gcr.io/cloud-builders/docker
    args: [build, -t, "$image", .]
images: ["$image"]
serviceAccount: projects/$PROJECT_ID/serviceAccounts/$builder
options:
  logging: CLOUD_LOGGING_ONLY
YAML
# IAM changes take a moment to propagate; retry the submit a few times.
for attempt in 1 2 3 4; do
  gcloud builds submit "$AUDIO_JOBS_SRC" --config "$WORK/cloudbuild.yaml" --quiet && break
  [ "$attempt" = 4 ] && exit 1
  sleep 30
done
echo "$image" >"$WORK/image"

log "render the gke overlay with this project's values"
rm -rf "$WORK/k8s" && cp -R "$ROOT/k8s" "$WORK/k8s"
redis=$(out redis_address)
psa=$(out private_services_cidr)
conn=$(out cloudsql_connection_name)
find "$WORK/k8s/overlays/gke" -type f -exec sed -i.bak \
  -e "s#my-gcp-project:europe-west1:audio-jobs-prod#$conn#g" \
  -e "s#my-gcp-project#$PROJECT_ID#g" \
  -e "s#network: audio-jobs-prod#network: audio-jobs-$ENVIRONMENT#g" \
  -e "s#10.100.0.3:6379#$redis#g" \
  -e "s#10.100.0.0/16#$psa#g" \
  -e "s#europe-west1-docker.pkg.dev/$PROJECT_ID/audio-jobs/audio-jobs#${image%:*}#g" \
  -e "s#newTag: latest#newTag: ${image##*:}#g" {} +
find "$WORK/k8s" -name '*.bak' -delete

log "deploy"
gcloud container clusters get-credentials "$(out cluster_name)" --region "$REGION" >/dev/null
kubectl apply -k "$WORK/k8s/overlays/gke"
kubectl -n audio-jobs wait --for=condition=complete job/audio-jobs-migrate --timeout=600s
kubectl -n audio-jobs rollout status deploy/api --timeout=600s
kubectl -n audio-jobs rollout status deploy/worker --timeout=600s

log "up. next: gcp-validation/checks.sh, then gcp-validation/down.sh"
