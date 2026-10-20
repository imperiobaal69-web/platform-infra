#!/usr/bin/env bash
# Prints the drill results table for the README from drills/results/*.json.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "| Drill | Fault | Detection | Recovery | Accepted | Lost | Rejected at submit | Runbook |"
echo "|---|---|---|---|---|---|---|---|"
for f in drills/results/0*.json; do
  jq -r '
    (if .detection_s == null then .detection_signal else "\(.detection_s) s (\(.detection_signal))" end) as $detect |
    "| [\(.drill)](\(input_filename)) | \(.fault) | \($detect) | \(.recovery_s) s (\(.recovery_criterion)) | \(.jobs_accepted) | \(.jobs_lost) | \(.client_errors) | [\(.runbook | split("/")[-1] | rtrimstr(".md"))](\(.runbook)) |"
  ' "$f"
done
