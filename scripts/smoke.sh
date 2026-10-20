#!/usr/bin/env bash
# End-to-end smoke test against a deployed overlay: submits real recordings
# through the API Service from the loadtest namespace (so the NetworkPolicies
# are exercised too) and requires every job to succeed with a correct result.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
JOBS=${JOBS:-30}

start_loadgen smoke -jobs "$JOBS" -concurrency 6 -duration-ms 5000 -timeout 2m -label smoke
report=$(wait_loadgen smoke 300)
echo "$report"
succeeded=$(jq -r .succeeded <<<"$report")
integrity=$(jq -r .integrity_failed <<<"$report")
if [[ $succeeded != "$JOBS" || $integrity != 0 ]]; then
  echo "smoke test FAILED: $succeeded/$JOBS succeeded, $integrity integrity failures" >&2
  kubectl -n "$APP_NS" get pods -o wide >&2
  exit 1
fi
echo "smoke test passed: $succeeded/$JOBS jobs succeeded"
