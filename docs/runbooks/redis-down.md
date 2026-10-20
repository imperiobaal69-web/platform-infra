# Redis down or emptied

**Alert:** `AudioJobsRedisDown` (page, local overlay). On GKE, Memorystore
health comes from Cloud Monitoring; in both environments `AudioJobsAPIDown`
fires if the outage lasts, because API readiness pings Redis.

**Impact:** Redis holds only derived state: the job queue (a stream with a
consumer group) and a result cache. Every job is also a row in Postgres. If
Redis restarts empty, queued work is not lost: the workers' sweeper finds
queued jobs untouched for `SWEEP_IDLE` and enqueues them again. Expect a
latency bump of up to `SWEEP_IDLE + SWEEP_EVERY` (2m30s in the base config,
40s locally) for jobs that were waiting, and cache misses afterwards.

Redis runs without persistence on purpose; this is the designed recovery
path, not a fallback.

## First five minutes

```bash
kubectl -n audio-jobs-data get pods -l app=redis
kubectl -n audio-jobs-data logs redis-0 --previous --tail=30
kubectl -n audio-jobs logs -l app=worker --since=10m --tail=-1 | grep -E 'read queue|re-enqueued' | tail
```

- `OOM command not allowed`: Redis hit `maxmemory` with `noeviction`. The
  queue is backed up (workers down?) or the cache is too large. Check the
  queue depth before raising memory.
- Pod restarting: read the previous logs; on Memorystore check for a
  maintenance event.

## Mitigation

- Redis back but jobs stuck: confirm the sweeper is running
  (`aj_swept_total` increases). It needs Postgres.
- Persistent `maxmemory`: raise the limit (local) or the Memorystore size
  (Terraform `memory_size_gb`); lower `CACHE_TTL` if the cache dominates.

## Verify

`aj_queue_depth{state="lag"}` drains, `aj_queue_oldest_unfinished_age_seconds`
returns to near zero, no job created before the incident is still
unfinished.

## Measured

Drill 04 kills Redis under load; see the [drill results](../../README.md#failure-drills)
for the time until every waiting job finished and how many the sweeper
re-enqueued.
