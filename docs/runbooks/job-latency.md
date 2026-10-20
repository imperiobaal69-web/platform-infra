# Job latency

**Alert:** `AudioJobsLatencyP95High` (page). The 95th percentile of end-to-end
job time (submission to success, `aj_job_end_to_end_seconds`) has been above
5.12 s for 10 minutes.

**Impact:** results arrive late. End-to-end time includes queue wait, so this
fires both when processing is slow and when work is piling up.

## First five minutes

Open the dashboard and compare three panels:

1. Queue depth by state. `lag` growing means workers are not keeping up
   → capacity. `delayed` growing means jobs are failing and being retried
   with backoff → [job-failures.md](job-failures.md).
2. CPU per pod. Workers at their CPU limit, HPA at maximum →
   [capacity.md](capacity.md).
3. Recovery mechanisms. `reclaimed` or `re-enqueued by sweeper` rising
   means jobs were orphaned by crashed workers or a lost queue; those wait
   for `VISIBILITY_TIMEOUT` or `SWEEP_IDLE` before running again, which
   shows up as latency → [workers-unavailable.md](workers-unavailable.md),
   [redis-down.md](redis-down.md).

```bash
kubectl -n audio-jobs get hpa
kubectl -n audio-jobs top pods
```

## Mitigation

- Backlog with spare cluster capacity: raise the worker HPA `minReplicas`
  temporarily to drain it faster.
- Slow Postgres (every query slower): check Cloud SQL CPU and connections;
  the API and workers share the instance.

## Verify

`sli:job_e2e_seconds:p95_rate10m` back under 5.12 and `aj_queue_depth{state="lag"}`
near zero.
