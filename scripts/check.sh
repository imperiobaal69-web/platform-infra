#!/usr/bin/env bash
# Static checks, the same ones CI runs. Usage: scripts/check.sh [k8s|monitoring|terraform|shell]...
# (no argument: all of them). Needs kubectl, kubeconform, shellcheck, jq,
# terraform, tflint and trivy; promtool comes from PATH or the Prometheus image.
set -euo pipefail
cd "$(dirname "$0")/.."
# Same minor version as the local cluster (Colima k3s) and the kind node in CI.
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.35.0}
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

step() { printf '\n== %s\n' "$*"; }

check_shell() {
  step "shellcheck"
  shellcheck -x scripts/*.sh drills/*.sh k8s/overlays/local/postgres-init.sh
}

check_k8s() {
  local overlay rendered
  rendered=$(mktemp -d)
  # The local overlay reads gitignored secret files; placeholders are enough
  # to render it.
  if [[ ! -d k8s/overlays/local/secrets ]]; then
    mkdir -p k8s/overlays/local/secrets
    for f in app exporter postgres; do echo "PLACEHOLDER=1" >"k8s/overlays/local/secrets/$f.env"; done
  fi
  for overlay in local gke; do
    step "kubeconform k8s/overlays/$overlay (Kubernetes $KUBERNETES_VERSION)"
    kubectl kustomize "k8s/overlays/$overlay" >"$rendered/$overlay.yaml"
    kubeconform -strict -summary -kubernetes-version "$KUBERNETES_VERSION" "$rendered/$overlay.yaml"
  done
  step "kubeconform monitoring (with CRD schemas)"
  kubectl kustomize monitoring >"$rendered/monitoring.yaml"
  kubeconform -strict -summary -kubernetes-version "$KUBERNETES_VERSION" \
    -schema-location default -schema-location "$CRD_SCHEMAS" "$rendered/monitoring.yaml"
  rm -rf "$rendered"
}

check_monitoring() {
  step "alert rules: syntax, unit tests, generated PrometheusRule up to date"
  scripts/promtool.sh check rules monitoring/rules/audio-jobs.rules.yml
  scripts/promtool.sh test rules monitoring/tests/audio-jobs.test.yml
  scripts/render-rules.sh --check
  step "Grafana dashboard is valid JSON"
  jq -e '.panels | length > 0' monitoring/dashboards/audio-jobs.json >/dev/null
  echo ok
}

check_terraform() {
  local dir
  step "terraform fmt"
  terraform -chdir=terraform fmt -recursive -check -diff
  for dir in terraform/bootstrap terraform/environments/prod; do
    step "terraform validate $dir"
    terraform -chdir="$dir" init -backend=false -input=false >/dev/null
    terraform -chdir="$dir" validate
  done
  step "tflint"
  (cd terraform && tflint --init >/dev/null && tflint --recursive --config "$PWD/.tflint.hcl")
  step "trivy config (HIGH, CRITICAL, MEDIUM)"
  trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL,MEDIUM \
    --tf-exclude-downloaded-modules terraform
}

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(shell k8s monitoring terraform)
for t in "${targets[@]}"; do
  "check_$t"
done
printf '\nall checks passed: %s\n' "${targets[*]}"
