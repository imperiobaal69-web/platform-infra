# Shared settings for the GCP validation scripts. Sourced, not executed.
# shellcheck shell=bash
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID to the GCP project used for validation}"
REGION="${REGION:-europe-west1}"
ENVIRONMENT="${ENVIRONMENT:-val}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform/environments/prod"
WORK="$ROOT/gcp-validation/.work"
RESULTS="$ROOT/gcp-validation/results"
AUDIO_JOBS_SRC="${AUDIO_JOBS_SRC:-$ROOT/../audio-jobs}"
mkdir -p "$WORK" "$RESULTS"

# gcloud's storage commands crash on Python 3.14 (ssl.PROTOCOL_TLSv1 was
# removed); run gcloud on a 3.12 interpreter when one is available.
if [ -z "${CLOUDSDK_PYTHON:-}" ] && command -v uv >/dev/null; then
  CLOUDSDK_PYTHON=$(uv python find 3.12 2>/dev/null || true)
  export CLOUDSDK_PYTHON
fi

log() { printf '\n== %s\n' "$*"; }
tf() { terraform -chdir="$TF_DIR" "$@"; }
out() { tf output -raw "$1"; }
