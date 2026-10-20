# Availability error budget burn

**Alerts:** `AudioJobsAvailabilityBudgetBurn` (page),
`AudioJobsAvailabilityBudgetBurnSlow` (ticket).

**SLO:** 99.5% of availability probes succeed over 30 days, a budget of about
3.6 hours of failed probes per month.

| Alert | Condition | Meaning |
|---|---|---|
| fast, page | error ratio > 14.4x budget over 1h and 5m | 2% of the monthly budget gone in an hour |
| fast, page | > 6x over 6h and 30m | 5% gone in six hours |
| slow, ticket | > 1x over 3d and 6h | on track to miss the SLO this month |

The short window in each pair makes the alert stop soon after the problem
stops; the long window keeps a brief blip from paging.

## First five minutes

1. Is the API failing right now? Open the dashboard's "Availability probe"
   panel or run the query below. If it is at 0, go to
   [api-unavailable.md](api-unavailable.md).

   ```promql
   avg_over_time(probe_success{job="audio-jobs-api-probe"}[5m])
   ```
2. If it is intermittent (between 0 and 1), look for flapping readiness:

   ```bash
   kubectl -n audio-jobs get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail
   ```

   Usual causes: Postgres or Redis latency above the 3s readiness timeout,
   API pods CPU-throttled at their limit, a rollout cycling pods.

## Mitigation

- Readiness timeouts from slow Postgres: see the Postgres panels; reduce load
  or scale Cloud SQL.
- Throttling: scale out (`kubectl -n audio-jobs scale` is overridden by the
  HPA; raise `minReplicas` instead) and open a capacity ticket.
- Slow-burn ticket: decide whether to freeze releases until the window
  recovers. Record the decision in the ticket.

## Verify

`sli:probe_error:ratio_rate1h` falls below 0.005 and the page resolves on its
own once the 5m window is clean.
