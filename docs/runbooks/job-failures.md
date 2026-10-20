# Job failures and dead letters

**Alerts:** `AudioJobsJobSuccessBudgetBurn` (page), `...Slow` (ticket),
`AudioJobsDeadLetters` (ticket).

**SLO:** 99.9% of jobs that finish end `succeeded`. A job becomes `dead` after
`MAX_ATTEMPTS` (5) failed attempts with exponential backoff, or at once on a
permanent error such as a corrupt WAV file.

**Impact:** the client polling the job sees `status: dead` and a
`last_error`. Nothing is retried automatically after that.

## First five minutes

```bash
# What is failing, and is it one tenant or everyone?
kubectl -n audio-jobs-data exec postgres-0 -- psql -U postgres -d audiojobs -c \
  "select tenant_id, left(last_error, 80) as error, count(*) from jobs
   where status = 'dead' and finished_at > now() - interval '1 hour'
   group by 1, 2 order by 3 desc limit 20"
kubectl -n audio-jobs logs -l app=worker --since=15m --tail=-1 | grep -i error | tail -20
```

- One tenant, "not a supported WAV file" or similar: bad input. Permanent
  errors are the client's problem; reply to the tenant, no paging needed. If
  this is what fired the page, the SLO is counting client errors and should
  exclude them (follow-up ticket).
- Every tenant, timeouts or "connection refused": a dependency is failing
  for long enough to exhaust retries → [postgres-down.md](postgres-down.md),
  [redis-down.md](redis-down.md).
- Every tenant, a new error message right after a release: roll back
  (`kubectl -n audio-jobs rollout undo deploy/worker`).

## Mitigation

Dead jobs can be retried once the cause is fixed. The store has no "retry
dead job" endpoint yet; re-queue them by setting status back to `queued`, and
the sweeper enqueues them within `SWEEP_IDLE`:

```sql
update jobs set status = 'queued', attempts = 0, last_error = null, updated_at = now() - interval '1 hour'
where status = 'dead' and finished_at > now() - interval '1 hour' and last_error like '%<pattern>%';
```

## Verify

`aj_jobs_finished_total{status="dead"}` stops increasing and the re-queued
jobs reach `succeeded`.
