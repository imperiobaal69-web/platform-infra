#!/usr/bin/env bash
# Usage: scripts/rollout-guard.sh <namespace> <deployment> [timeout]
#
# Waits for a Deployment rollout. If it fails (the Deployment reports
# ProgressDeadlineExceeded because new pods never become ready, or the timeout
# expires first) it rolls back to the previous revision and exits 2. Exit 0
# means the rollout completed.
set -euo pipefail
ns=$1
deploy=$2
timeout=${3:-300s}

if kubectl -n "$ns" rollout status "deployment/$deploy" --timeout="$timeout"; then
  exit 0
fi

echo "rollout of $ns/$deploy failed; rolling back" >&2
kubectl -n "$ns" get pods -l "app=$deploy" -o wide >&2 || true
kubectl -n "$ns" rollout undo "deployment/$deploy"
kubectl -n "$ns" rollout status "deployment/$deploy" --timeout="$timeout"
echo "rolled back $ns/$deploy to the previous revision" >&2
exit 2
