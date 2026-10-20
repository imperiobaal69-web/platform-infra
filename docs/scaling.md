# Scaling

## What scales

| Component | Mechanism | Local overlay | Base (GKE) |
|---|---|---|---|
| api | HPA on CPU, 70% of request | 2 to 4 replicas | 3 to 10 replicas |
| worker | HPA on CPU, 70% of request | 2 to 8 replicas | 2 to 20 replicas |
| GKE nodes | cluster autoscaler on the node pool | n/a (one VM) | `node_min_count` to `node_max_count` per zone |
| Postgres | vertical (Cloud SQL tier) | single StatefulSet pod | `db_tier`, regional HA |
| Redis | vertical (Memorystore size) | single StatefulSet pod | `redis_memory_gb` |

Scale-up is immediate: there is no stabilisation window, and replicas may double every 15 s. Scale-down waits 300 s in the base and 60 s locally, so the drill does not take ten minutes to settle. This avoids flapping when load comes in bursts.

Local CPU requests follow usage measured on the Colima VM, about 60m CPU per worker pod at 100 jobs/s. Without that, the HPA would not react at laptop-scale load. Base requests are sized for real nodes.

Drill 01 (`drills/01-hpa-scale-out.sh`) shows the result: 3 load generators submit 36,000 jobs in about 125 s. The worker HPA goes from 2 to 5 replicas and the API HPA from 2 to 4, and both return to the minimum after the load stops. The per-second timeline is in `drills/results/01-hpa-scale-out.timeline.csv`.

## Why CPU and not queue lag

CPU is the signal that works with only metrics-server installed, and it is what the drill measures. For a job system, queue lag is the better signal: it rises before CPU does when jobs are I/O-bound, and it says how far behind the system is. The replacement is KEDA with its `redis-streams` scaler on the pending entries of the `workers` consumer group of `aj:stream`:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: worker, namespace: audio-jobs}
spec:
  scaleTargetRef: {name: worker}
  minReplicaCount: 2
  maxReplicaCount: 20
  triggers:
    - type: redis-streams
      metadata:
        address: redis.audio-jobs-data.svc.cluster.local:6379
        stream: "aj:stream"
        consumerGroup: workers
        pendingEntriesCount: "50"
```

KEDA would replace the worker HPA, since it creates its own. It is not installed here, to keep the local footprint small, so this config is not tested.

## Limits seen locally

The single-node VM has 4 CPUs, shared by Postgres, Redis, the monitoring stack and the load generators. In drill 01, throughput is bounded by that VM, not by the replica limits. The HPA never reached `maxReplicas`. The numbers show that the autoscaling loop works end to end. They are not a capacity figure for a real cluster.
