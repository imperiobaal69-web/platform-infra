#!/usr/bin/env bash
# Installs the monitoring stack (pinned chart versions) and the workload's
# PodMonitors, Probe, alert rules and Grafana dashboard.
set -euo pipefail
cd "$(dirname "$0")/.."
KPS_VERSION=92.11.0
BLACKBOX_VERSION=11.20.0

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$KPS_VERSION" --namespace monitoring --create-namespace \
  --values monitoring/values-kube-prometheus-stack.yaml --wait --timeout 10m

helm upgrade --install blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
  --version "$BLACKBOX_VERSION" --namespace monitoring \
  --values monitoring/values-blackbox-exporter.yaml --wait --timeout 5m

scripts/render-rules.sh
kubectl apply -k monitoring
echo "Grafana: kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "  user admin, password: kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
