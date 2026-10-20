# Runbooks

One page per alert family. Each alert's `runbook_url` points here. Every page
has the same shape: what fired and what it means for users, the first five
minutes, how to find the cause, how to mitigate, how to confirm recovery.

Commands assume `kubectl` is pointed at the cluster and the default namespaces
of this repository: `audio-jobs` (api, worker, postgres-exporter),
`audio-jobs-data` (local Postgres and Redis), `monitoring`.

| Runbook | Alerts | Drill that exercises it |
|---|---|---|
| [api-unavailable.md](api-unavailable.md) | AudioJobsAPIDown | 03, 04 |
| [error-budget-burn.md](error-budget-burn.md) | AudioJobsAvailabilityBudgetBurn, ...Slow | 03, 04 |
| [job-failures.md](job-failures.md) | AudioJobsJobSuccessBudgetBurn, ...Slow, AudioJobsDeadLetters | - |
| [job-latency.md](job-latency.md) | AudioJobsLatencyP95High | 01 |
| [queue-age.md](queue-age.md) | AudioJobsQueueAgeHigh | 02, 04 |
| [postgres-down.md](postgres-down.md) | AudioJobsPostgresDown | 03 |
| [redis-down.md](redis-down.md) | AudioJobsRedisDown | 04 |
| [workers-unavailable.md](workers-unavailable.md) | AudioJobsWorkersUnavailable, AudioJobsPodCrashLooping | 02, 05 |
| [bad-deploy.md](bad-deploy.md) | AudioJobsRolloutStuck | 06 |
| [capacity.md](capacity.md) | AudioJobsHPAAtMaximum | 01 |

Severity: `page` wakes someone up (user-visible now, or the error budget will
be gone within hours); `ticket` is handled in working hours.

Useful everywhere:

```bash
kubectl -n audio-jobs get pods,hpa,pdb -o wide
kubectl -n audio-jobs get events --sort-by=.lastTimestamp | tail -30
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80   # dashboard "audio-jobs"
kubectl -n monitoring port-forward svc/prometheus-operated 9090                # alerts, queries
```
