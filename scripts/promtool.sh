#!/usr/bin/env bash
# Runs promtool from PATH if installed, otherwise from the Prometheus image
# (the same version kube-prometheus-stack deploys) through docker.
set -euo pipefail
cd "$(dirname "$0")/.."
PROMETHEUS_IMAGE=quay.io/prometheus/prometheus:v3.15.0-distroless
if command -v promtool >/dev/null; then
  exec promtool "$@"
fi
exec docker run --rm -v "$PWD:/work" -w /work --entrypoint /bin/promtool "$PROMETHEUS_IMAGE" "$@"
