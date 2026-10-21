#!/usr/bin/env bash
# Tear the validation environment down and prove nothing billable is left.
#
#   PROJECT_ID=my-project gcp-validation/down.sh
# shellcheck source=gcp-validation/lib.sh
source "$(dirname "$0")/lib.sh"

log "delete the workload first (releases the Filestore volume and load balancers)"
if gcloud container clusters describe "$(out cluster_name 2>/dev/null || echo none)" --region "$REGION" >/dev/null 2>&1; then
  kubectl delete -k "$WORK/k8s/overlays/gke" --ignore-not-found --wait=true --timeout=10m || true
  kubectl delete pvc --all -n audio-jobs --wait=true --timeout=10m || true
fi

log "terraform destroy"
if ! tf destroy -input=false -auto-approve -var-file="$WORK/validation.tfvars"; then
  # After Cloud SQL is deleted, Google keeps reporting the private services
  # connection as in use for a while, and deleting it fails. Removing the VPC
  # peering directly releases it; then the rest can be destroyed.
  log "private services connection still marked in use: removing the peering"
  gcloud compute networks peerings delete servicenetworking-googleapis-com \
    --network "audio-jobs-$ENVIRONMENT" --quiet || true
  tf state rm module.network.google_service_networking_connection.private_services || true
  tf destroy -input=false -auto-approve -var-file="$WORK/validation.tfvars"
fi

log "state bucket and the build account/bucket created by up.sh"
gcloud storage rm --recursive "gs://$PROJECT_ID-tfstate" --quiet || true
gcloud storage rm --recursive "gs://${PROJECT_ID}_cloudbuild" --quiet || true
gcloud iam service-accounts delete "image-builder@$PROJECT_ID.iam.gserviceaccount.com" --quiet || true

log "anything left that costs money?"
left=$(
  {
    gcloud container clusters list --format='value(name)'
    gcloud compute instances list --format='value(name)'
    gcloud compute disks list --format='value(name)'
    gcloud compute addresses list --format='value(name)'
    gcloud compute routers list --format='value(name)'
    gcloud sql instances list --format='value(name)'
    gcloud redis instances list --region "$REGION" --format='value(name)'
    gcloud filestore instances list --format='value(name)'
  } 2>/dev/null | sed '/^$/d'
)
if [ -z "$left" ]; then
  echo "nothing left running in $PROJECT_ID"
  jq -n --arg at "$(date -u +%FT%TZ)" '{torn_down_at:$at, leftovers:[]}' >"$RESULTS/teardown.json"
else
  echo "LEFT OVER:"; echo "$left"
  jq -n --arg at "$(date -u +%FT%TZ)" --arg l "$left" '{torn_down_at:$at, leftovers:($l|split("\n"))}' >"$RESULTS/teardown.json"
  exit 1
fi
