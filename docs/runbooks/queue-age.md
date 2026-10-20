# Queue age

**Alert:** `AudioJobsQueueAgeHigh` (page). Some job accepted by the API has
not finished for more than 120 seconds, for 2 minutes.

The signal comes from Postgres (postgres-exporter's
`aj_queue_oldest_unfinished_age_seconds`), not from Redis, so it catches the
case where Redis lost the queue and nobody is looking for the job.

## First five minutes

```bash
kubectl -n audio-jobs-data exec postgres-0 -- psql -U postgres -d audiojobs -c \
  "select status, count(*), min(created_at), max(attempts) from jobs
   where status in ('queued','running','failed') group by 1"
kubectl -n audio-jobs get pods -l app=worker
```

| Oldest jobs are | Likely cause | Go to |
|---|---|---|
| `queued`, attempts 0 | no worker is fetching, or the queue lost them | [workers-unavailable.md](workers-unavailable.md), [redis-down.md](redis-down.md) |
| `running` | a worker died holding the lease; reclaim takes `VISIBILITY_TIMEOUT` | [workers-unavailable.md](workers-unavailable.md) |
| `failed` (waiting to retry) | repeated failures, backoff growing | [job-failures.md](job-failures.md) |

## Mitigation

The system heals the common cases without help: workers reclaim deliveries
idle for longer than `VISIBILITY_TIMEOUT`, and the sweeper re-enqueues queued
jobs untouched for `SWEEP_IDLE`. If the age keeps growing past
`SWEEP_IDLE + SWEEP_EVERY` with healthy workers, check the worker logs for
`sweep` errors (usually Postgres).

## Verify

`max(aj_queue_oldest_unfinished_age_seconds)` back near zero.
