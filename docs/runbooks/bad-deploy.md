# Bad deploy

**Alert:** `AudioJobsRolloutStuck` (ticket). A Deployment reported
`ProgressDeadlineExceeded`: its new pods did not become ready within
`progressDeadlineSeconds` (120s base, 60s local).

**Impact:** usually none for users. Rollouts use `maxUnavailable: 0`, so the
old pods keep serving until new ones are ready, and a release whose pods
never pass readiness never takes traffic.

`scripts/deploy.sh` runs every rollout through `scripts/rollout-guard.sh`,
which waits for the rollout and runs `kubectl rollout undo` when the
deadline is exceeded. If this alert fires, either the deploy did not go
through the guard, or the rollback itself failed.

## First five minutes

```bash
kubectl -n audio-jobs rollout status deploy/<name> --timeout=5s
kubectl -n audio-jobs rollout history deploy/<name>
kubectl -n audio-jobs get rs -l app=<name>
kubectl -n audio-jobs describe pod <new-pod> | grep -A5 -E 'Readiness|Startup|Last State'
```

## Mitigation

```bash
kubectl -n audio-jobs rollout undo deploy/<name>
kubectl -n audio-jobs rollout status deploy/<name>
```

Then find out why the release failed before trying again: probe path or port
changed, a required environment variable missing, the image not pullable, a
migration not applied.

## Verify

`kubectl -n audio-jobs rollout status` succeeds and the alert resolves on the
next kube-state-metrics scrape.

## Measured

Drill 06 ships a release that listens on the wrong port and lets the guard
roll it back under load; see the [drill results](../../README.md#failure-drills).
