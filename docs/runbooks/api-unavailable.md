# API unavailable

**Alert:** `AudioJobsAPIDown` (page). Every synthetic probe of
`http://api.audio-jobs.svc.cluster.local/readyz` failed for two minutes.

**Impact:** clients cannot submit jobs. Jobs already accepted are safe in
Postgres and are processed once workers can reach their dependencies.

`/readyz` fails when the API cannot reach Postgres or Redis, and an API pod
that fails it is removed from the Service. So "no ready endpoints" almost
always means a dependency is down, not that the API process is broken.
Liveness deliberately does not check dependencies, so the API pods are not
restarted during a dependency outage.

## First five minutes

```bash
kubectl -n audio-jobs get pods -l app=api -o wide
kubectl -n audio-jobs get endpointslices -l kubernetes.io/service-name=api
kubectl -n audio-jobs logs deploy/api --since=10m | grep -v '"level":"INFO"' | tail
```

1. Pods running but not ready: read the readiness failure.
   `kubectl -n audio-jobs describe pod <api-pod> | grep -A3 Readiness`
   - `postgres: ...` → [postgres-down.md](postgres-down.md)
   - `redis: ...` → [redis-down.md](redis-down.md)
2. Pods not running (CrashLoopBackOff, Pending, ImagePullBackOff): check
   whether a rollout is in progress → [bad-deploy.md](bad-deploy.md).
   `kubectl -n audio-jobs rollout history deploy/api`
3. Pods ready but the probe still fails: check the blackbox exporter and the
   NetworkPolicy `api-ingress` (the probe comes from the `monitoring`
   namespace).

## Mitigation

- Dependency down: follow its runbook. Nothing to do on the API itself.
- Bad release: `kubectl -n audio-jobs rollout undo deploy/api`.
- Capacity (pods OOMKilled or CPU-throttled under load): raise the HPA
  ceiling or the requests → [capacity.md](capacity.md).

## Verify

The probe success rate in the "Availability probe" panel returns to 1, and
`kubectl -n audio-jobs get endpointslices -l kubernetes.io/service-name=api`
lists every API pod as ready.

## Measured

Drills 03 and 04 take this path (dependency down, API pods leave the Service).
See the [drill results](../../README.md#failure-drills) for detection and recovery
times.
