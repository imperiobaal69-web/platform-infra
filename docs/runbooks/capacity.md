# Capacity: HPA at its ceiling

**Alert:** `AudioJobsHPAAtMaximum` (ticket). An HPA has been at
`maxReplicas` for 15 minutes.

**Impact:** none yet, but there is no headroom: more load turns into queue
age and latency (`AudioJobsQueueAgeHigh`, `AudioJobsLatencyP95High`).

## First five minutes

```bash
kubectl -n audio-jobs get hpa
kubectl -n audio-jobs top pods
kubectl top nodes
```

Decide whether the load is legitimate (traffic growth, a tenant backfill) or a
loop (one tenant resubmitting the same failing input; check
`aj_jobs_submitted_total` by outcome and the per-tenant counts in Postgres).

## Mitigation

- Legitimate and the nodes have room: raise `maxReplicas` in the overlay.
- Nodes full: on GKE the node pool autoscaler adds nodes up to
  `node_max_count` (Terraform); raise that if it is the limit.
- Postgres is the bottleneck (CPU high on Cloud SQL, workers waiting): more
  workers will not help. Scale the instance tier.

## Scaling signal

The HPAs scale on CPU. For a queue consumer, queue lag is the better signal;
KEDA's `redis-streams` scaler on the `workers` consumer group is the planned
replacement (see the comment in `k8s/base/worker.yaml`).

## Measured

Drill 01 drives both HPAs out and back in; the replica timeline is in
`drills/results/01-hpa-scale-out.timeline.csv`.
