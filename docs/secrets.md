# Secrets

No credential is committed to this repository, and none is stored in Terraform state.

## Local overlay (Colima, kind)

`scripts/gen-local-secrets.sh` writes random passwords (`openssl rand -hex 24`) into `k8s/overlays/local/secrets/*.env`. That directory is gitignored. The script keeps existing files, so running it again does not change the password of a Postgres that is already running.

Kustomize's `secretGenerator` turns the files into three Secrets:

| Secret | Namespace | Contents | Read by |
|---|---|---|---|
| `postgres` | audio-jobs-data | superuser, application and exporter passwords | Postgres init script (creates the `audiojobs` and `exporter` roles) |
| `audio-jobs-db` | audio-jobs | `DATABASE_URL` for the `audiojobs` role | api, worker, migrate |
| `audio-jobs-exporter-db` | audio-jobs | `DATA_SOURCE_NAME` for the read-only `exporter` role | postgres-exporter |

The generator adds a content hash to each Secret name. A changed password therefore produces a new name, and the Deployments that reference it roll out on the next apply.

Each component reads only its own Secret. The exporter connects as a read-only role (`pg_monitor` plus SELECT on the application's tables) that cannot write. No pod mounts a Kubernetes API token (`automountServiceAccountToken: false`), so a compromised pod cannot read other Secrets through the API.

## GKE overlay

The application has no database password on GKE:

- Cloud SQL has IAM database authentication enabled (`cloudsql.iam_authentication`). Terraform creates a database user for each Google service account, `audio-jobs-app` and `audio-jobs-exporter`.
- Each pod runs the Cloud SQL Auth Proxy as a native sidecar with `--auto-iam-authn`. The proxy gets a short-lived token for the pod's Google service account through Workload Identity, and connects to the instance's private IP over TLS.
- `DATABASE_URL` points at the proxy on `127.0.0.1:5432` and contains only a user name. The base still reads it from a Secret, but nothing in that Secret is sensitive.

Platform secrets that do exist, such as the Alertmanager PagerDuty routing key and the Grafana admin password, are Secret Manager secrets. Terraform creates only the empty secret containers, and the values are added out of band (`gcloud secrets versions add`), so they never appear in state. External Secrets Operator syncs them into the cluster under its own Workload Identity, which can access only those two secrets.

Etcd encryption of Kubernetes Secrets with a customer-managed key is available through the `etcd_kms_key` variable of the GKE module.

## Not covered

- Memorystore AUTH and in-transit encryption are off, because the application's Redis client takes an address only. Enabling them needs a change in audio-jobs: a password from Secret Manager and a TLS config. The trivy findings for this are suppressed inline with that reason.
- Rotation of the local passwords is manual: delete the files, rerun the script, then restart Postgres.
