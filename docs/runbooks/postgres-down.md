# Postgres down

**Alert:** `AudioJobsPostgresDown` (page). `pg_up` is 0 (the exporter cannot
connect) or the exporter itself is gone. Usually `AudioJobsAPIDown` follows.

**Impact:** Postgres is the source of truth. While it is down the API is not
ready (new submissions fail fast at the Service), workers cannot start or
finish jobs, and in-flight jobs are retried after it returns. Nothing that was
committed is lost as long as the volume (local) or the instance (Cloud SQL)
survives.

## First five minutes

Local cluster:

```bash
kubectl -n audio-jobs-data get pods -l app=postgres
kubectl -n audio-jobs-data describe pod postgres-0 | tail -20
kubectl -n audio-jobs-data logs postgres-0 --previous --tail=50
kubectl -n audio-jobs-data get pvc
```

GKE / Cloud SQL:

```bash
gcloud sql instances describe <instance> --format='value(state)'
gcloud sql operations list --instance <instance> --limit 5
```

Common causes: the pod was rescheduled and is replaying WAL (wait), the volume
is full (`df` inside the pod, or Cloud SQL disk metrics), a maintenance or
failover on Cloud SQL (HA failover completes in about a minute), credentials
rotated without updating the Secret (exporter shows authentication errors).

## Mitigation

- Pod crash-looping on a full disk: expand the PVC (or the Cloud SQL disk;
  automatic storage increase is on in Terraform) before anything else.
- Credentials: update the secret in Secret Manager; External Secrets syncs it
  within its refresh interval, then restart api and worker.
- Do not delete the PVC or the instance.

## Verify

`pg_up` is 1, `kubectl -n audio-jobs get endpointslices -l kubernetes.io/service-name=api`
shows every API pod ready, `aj_queue_oldest_unfinished_age_seconds` falls back.

## Measured

Drill 03 kills the Postgres pod under load. Results, including whether
committed data was identical afterwards, are in
[docs/results/drills.md](../results/drills.md).
