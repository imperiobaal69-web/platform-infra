# Validation on Google Cloud

On 21 October 2026 I applied the Terraform and the `gke` overlay to a real GCP
project, deployed audio-jobs, ran the checks and drills below, and destroyed
everything. This folder holds the scripts and the recorded results.

The environment used the production modules, sized down to keep it cheap: one
`e2-standard-2` node per zone (regional cluster, three zones), Cloud SQL
`db-custom-1-3840` in a single zone without HA, Memorystore BASIC 1 GB, and a
1 TiB Filestore basic HDD instance. It ran for about three hours.

```sh
PROJECT_ID=<project> gcp-validation/up.sh      # budget alert, state bucket, apply, build, deploy
PROJECT_ID=<project> gcp-validation/checks.sh  # results/checks.json
PROJECT_ID=<project> gcp-validation/drills.sh  # results/drill-*.json
PROJECT_ID=<project> gcp-validation/down.sh    # destroy, then list anything left
```

## What the first apply got wrong

Static checks (fmt, validate, tflint, trivy, kubeconform) passed on all of
these. Each failed on the real platform, the last one only at teardown, and
each fix is in this repository.

| Problem on GCP | Cause | Fix |
| --- | --- | --- |
| `Identity Pool does not exist` when binding Kubernetes service accounts | The `PROJECT.svc.id.goog` pool only exists after a cluster with Workload Identity is created; the bindings ran in parallel with the cluster | `depends_on = [module.gke]` on the workload identity module |
| Every DNS lookup from the app timed out; the Cloud SQL proxy could not resolve `sqladmin.googleapis.com` | The cluster enables NodeLocal DNSCache, so queries are answered by `node-local-dns` pods; the egress policy only allowed `kube-dns` | The DNS policy allows both |
| Migrations failed with `permission denied for schema public` | PostgreSQL 15+ does not let every role create in `public`, and a new IAM database user has no grants | `database_roles` on the IAM users, declared in Terraform |
| The upload volume provisioned but every mount timed out | The built-in `standard-rwx` class creates Filestore on the `default` network, which the private cluster cannot reach | A `filestore-private` StorageClass on the cluster's VPC through private services access |
| Image builds were denied access to their own source | New projects run Cloud Build as the Compute Engine default account, which no longer gets storage or registry access | Builds run as a dedicated account with only log, read-source and push rights |
| `terraform destroy` could not drop the app's database user | The migrations make that IAM user the owner of the tables, and PostgreSQL will not drop a role that owns objects; Terraform deleted the users before the database | The database depends on the users, so destroy removes the database first |

The exporter looked healthy throughout the DNS problem: it resolved the Cloud
SQL API in the first seconds, before the network policies took effect, and kept
the cached result. A check that only looked at pod status would have passed.

## Checks

Each claim has a check that the allowed path works and, where one exists, a
check that the forbidden path fails. 11 of 11 passed
([results/checks.json](results/checks.json)).

| Check | Result | Evidence |
| --- | --- | --- |
| Nodes have no public IP | pass | 0 external addresses on the node VMs |
| Control plane reachable only from the allow-list | pass | private nodes, one authorised /32 |
| Cloud SQL has no public IP | pass | `ipv4Enabled=false`, only PRIVATE addresses |
| Database users are IAM identities | pass | both application users are `CLOUD_IAM_SERVICE_ACCOUNT` |
| App pods cannot go around the Auth Proxy | pass | direct connection to the instance on 5432 times out under the app's network policy |
| Cloud SQL refuses logins without an IAM token | pass | from a namespace without policies: `Cloud SQL IAM service account authentication failed` for the app user, `password authentication failed` for `postgres` |
| The api pod runs as its Google service account | pass | the metadata server returns `audio-jobs-app@...` |
| External Secrets can read its secret | pass | read through Workload Identity, no key file |
| The app cannot read that secret | pass | `PERMISSION_DENIED` |
| GitHub OIDC trusts only this repository's main branch | pass | provider condition `assertion.repository == ".../platform-infra" && assertion.ref in ["refs/heads/main"]` |
| Jobs go through the API and are processed | pass | 30 of 30 recordings |

## Drills

Load runs at a fixed 5 submissions per second and the fault lands inside the
load window; each result records both, and the script rejects a run where they
do not overlap. (The first attempt sent its jobs unthrottled: they finished in
5 s, 40 s before the fault, so its "0 lost" proved nothing and was discarded.)

| Drill | Fault | Load | Accepted | Completed | Lost | Recovery |
| --- | --- | --- | --- | --- | --- | --- |
| [Node loss](results/drill-gcp-node-loss.json) | the VM running a worker deleted at second 47 | 360 s | 1,800 | 1,800 | 0 | workers back at full count after 173 s; node recreated after 185 s |
| [Cloud SQL restart](results/drill-gcp-cloudsql-restart.json) | instance restarted at second 46 | 180 s | 848 | 848 | 0 | restart operation 36 s; 52 of 900 submissions (5.8 %) were refused during it |

The 52 refused submissions got an error from the API; none was accepted and
then lost. With `db_high_availability = true`, the production setting, a
restart becomes a failover to the standby; that was not tested here.

## What this does not show

- High availability. Cloud SQL and Memorystore ran without HA, so failover is untested.
- Scale. Three small nodes and a single-zone database; the numbers are not a capacity plan.
- Least privilege for migrations. The app identity holds `cloudsqlsuperuser` because it also runs the migrations; a separate migration identity would let api and worker run with data access only.
- Alert routing to a pager, External Secrets Operator and the monitoring stack were not installed on GKE.

Recorded addresses and the project ID are redacted from the results.
