#!/usr/bin/env bash
# Usage: scripts/deploy.sh [overlay]   (default: local)
#
# Applies an overlay in order: manifests, datastores ready, schema migration,
# then the api and worker rollouts. A rollout that fails is rolled back
# automatically by scripts/rollout-guard.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
overlay=${1:-local}
dir=k8s/overlays/$overlay
[[ -d $dir ]] || { echo "no overlay $dir" >&2; exit 1; }

if [[ $overlay == local ]]; then
  scripts/gen-local-secrets.sh
fi

# Job specs are immutable; the previous migration Job is replaced each time.
kubectl -n audio-jobs delete job audio-jobs-migrate --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl apply -k "$dir"

if [[ $overlay == local ]]; then
  kubectl -n audio-jobs-data rollout status statefulset/postgres --timeout=300s
  kubectl -n audio-jobs-data rollout status statefulset/redis --timeout=180s
fi

echo "waiting for schema migration"
kubectl -n audio-jobs wait --for=condition=complete job/audio-jobs-migrate --timeout=300s

scripts/rollout-guard.sh audio-jobs api 300s
scripts/rollout-guard.sh audio-jobs worker 300s
kubectl -n audio-jobs rollout status deployment/postgres-exporter --timeout=180s
kubectl -n audio-jobs get pods -o wide
