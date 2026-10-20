# Service level objectives

Four SLOs over a rolling 30 days. The rules live in `monitoring/rules/audio-jobs.rules.yml` and are unit-tested with promtool (`monitoring/tests/audio-jobs.test.yml`, run by `scripts/check.sh monitoring` and in CI).

| SLO | Target | SLI (recording rule) | Source |
|---|---|---|---|
| Availability | 99.5% | share of synthetic `GET /readyz` probes through the API Service that succeed (`sli:probe_error:ratio_rate*`) | blackbox exporter, every 10 s |
| Job success | 99.9% | share of finished jobs that end `succeeded`, not `dead` (`sli:job_error:ratio_rate*`) | `aj_jobs_finished_total` from the workers |
| Latency | 95% of jobs within 5.12 s end to end | `sli:job_e2e_within_slo:ratio_rate10m`, `sli:job_e2e_seconds:p95_rate10m` | `aj_job_end_to_end_seconds` histogram |
| Queue age | no accepted job unfinished for more than 120 s | `sli:queue_oldest_unfinished_age_seconds:max` | postgres-exporter custom query on `jobs` |

5.12 s is a bucket boundary of the latency histogram, so the latency SLI is exact rather than interpolated.

Availability is measured from inside the cluster, through the Service. That is the path every client uses here, and readiness-based endpoint removal shows up in it. The probe cannot see failures outside the cluster, such as a load balancer or DNS problem.

## Error budget alerts

Burn-rate alerts use the multiwindow, multi-burn-rate pattern from the Google SRE workbook. A long window confirms that the burn is significant, and a short window confirms that it is still happening:

| Severity | Burn rate | Long window | Short window | Budget consumed when it fires |
|---|---|---|---|---|
| page | 14.4x | 1h | 5m | 2% of 30 days |
| page | 6x | 6h | 30m | 5% of 30 days |
| ticket | 1x | 3d | 6h | 10% of 30 days |

Availability and job success each have their own pair of alerts (`*BudgetBurn`, `*BudgetBurnSlow`). Latency and queue age are threshold alerts (`for: 10m` and `for: 2m`). They catch slowness that does not show up as failures.

## Symptom and cause alerts

Burn-rate alerts need minutes of failure before they fire. Faster alerts cover hard outages, and each one links to a runbook in `docs/runbooks/`: `AudioJobsAPIDown`, `AudioJobsPostgresDown`, `AudioJobsRedisDown`, `AudioJobsWorkersUnavailable`, `AudioJobsRolloutStuck`, `AudioJobsPodCrashLooping`, `AudioJobsDeadLetters`, `AudioJobsHPAAtMaximum`. The drill result files record which of these alerts went pending or firing during each fault, and when.
