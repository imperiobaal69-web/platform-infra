# Observability

## Components

`scripts/monitoring-up.sh` installs these with pinned chart versions:

- kube-prometheus-stack 92.11.0: Prometheus Operator, Prometheus, Alertmanager, Grafana, kube-state-metrics and node-exporter. The values in `monitoring/values-kube-prometheus-stack.yaml` are sized for a laptop: 2 days or 1 GB of retention, no persistence.
- prometheus-blackbox-exporter 11.20.0, for the synthetic availability probe.
- The workload objects from `monitoring/` (kustomize):
  - PodMonitors for api, worker and postgres-exporter (15 s interval)
  - a Probe against `http://api.audio-jobs.svc/readyz` (10 s interval)
  - the PrometheusRule, generated from the promtool-tested rule file
  - the Grafana dashboard ConfigMap, which the Grafana sidecar loads

The API and worker pods accept scrapes only from the `monitoring` namespace (NetworkPolicy `metrics-ingress-from-monitoring`).

## Signals

| Source | Examples |
|---|---|
| api `/metrics` | `aj_jobs_submitted_total{outcome}` (queued, cached, duplicate), `aj_cache_hits_total` |
| worker `/metrics` | `aj_jobs_finished_total{status}`, `aj_job_end_to_end_seconds`, `aj_worker_in_flight`, `aj_retries_total`, `aj_reclaimed_total`, `aj_swept_total` (jobs re-enqueued from Postgres by the sweeper), `aj_queue_depth{state}` |
| postgres-exporter | `pg_up`, jobs by status, `aj_queue_oldest_unfinished_age_seconds` (custom query, `k8s/base/postgres-exporter-queries.yaml`) |
| kube-state-metrics | ready replicas, HPA desired and current, Deployment conditions, restarts |
| blackbox | `probe_success`, `probe_duration_seconds` |

## Dashboard

`monitoring/dashboards/audio-jobs.json`, in rows:

- Service level objectives: the four SLIs against their targets, and the burn rate
- Traffic and latency: submissions, finished jobs by status, end-to-end percentiles
- Queue: depth by state, oldest unfinished job, recovery mechanisms (sweeper and retries)
- Capacity: replicas against HPA bounds, CPU per pod, jobs in flight and restarts
- Dependencies: datastore up, jobs by status in Postgres

To open it:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

## Alert routing

Locally, Alertmanager routes everything to a null receiver. Alerts are inspected in the Prometheus UI, and the drills record them by polling `/api/v1/alerts`.

On GKE, the same chart would run with persistent volumes for Prometheus and Alertmanager. It would route `severity=page` to PagerDuty, using the routing key from Secret Manager through External Secrets, and `severity=ticket` to a ticket queue. Google Cloud Managed Service for Prometheus is the alternative to running Prometheus in the cluster; the rules and dashboard would carry over unchanged. Neither has been deployed (see the README).
