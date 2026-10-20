# Workers unavailable or crash-looping

**Alerts:** `AudioJobsWorkersUnavailable` (page), `AudioJobsPodCrashLooping`
(ticket).

**Impact:** the API keeps accepting jobs, but nothing processes them; queue
age grows. Jobs a dying worker held are not lost: each pod is its own Redis
Streams consumer, and its pending deliveries are claimed by another worker
once idle for `VISIBILITY_TIMEOUT`. A job's lease token in Postgres stops a
slow, presumed-dead worker from overwriting the result of the one that took
over.

## First five minutes

```bash
kubectl -n audio-jobs get pods -l app=worker -o wide
kubectl -n audio-jobs describe pod <worker-pod> | grep -A10 'Last State'
kubectl -n audio-jobs logs <worker-pod> --previous --tail=50
kubectl -n audio-jobs get events --sort-by=.lastTimestamp | grep -i worker | tail
```

| Symptom | Likely cause |
|---|---|
| `OOMKilled` | memory limit too low for the input sizes; the analyzer streams, so look for a regression |
| exits right after start, `postgres` or `redis` in the log | dependency unreachable at startup (NetworkPolicy, DNS, credentials) |
| `Pending` | no capacity: node pool at its maximum, or requests too large |
| restarts during a rollout only | new release is broken → [bad-deploy.md](bad-deploy.md) |

## Mitigation

- Bad release: `kubectl -n audio-jobs rollout undo deploy/worker`.
- OOM: raise `limits.memory` in the overlay; `GOMEMLIMIT` follows it.
- Pending: see [capacity.md](capacity.md).

## Planned disruptions

Node drains and upgrades evict pods through the Eviction API. The worker PDB
(`maxUnavailable: 25%`) and the API PDB (`maxUnavailable: 1`) pace them. On
SIGTERM a worker stops fetching and finishes in-flight jobs for up to
`SHUTDOWN_GRACE` (25s, below the 40s grace period).

## Verify

`kube_deployment_status_replicas_available{deployment="worker"}` back at the
HPA's desired count, `aj_queue_depth{state="pending"}` falls.

## Measured

Drill 02 kills every worker mid-job and drill 05 evicts every pod under load;
see the [drill results](../../README.md#failure-drills).
