# Keyless CI: GitHub Actions exchanges its OIDC token for a short-lived token
# of the deployer service account. Only workflows from var.repository can do
# so, and only on the branches in var.allowed_refs.

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }
  attribute_condition = "assertion.repository == \"${var.repository}\" && assertion.ref in [${join(", ", [for r in var.allowed_refs : "\"${r}\""])}]"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "deployer" {
  project      = var.project_id
  account_id   = var.deployer_account_id
  display_name = "CI deployer (${var.repository})"
}

resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.repository}"
}

# Deploys to the cluster through the Kubernetes API (RBAC inside the cluster
# narrows it further); pushing images is granted on the repository only, by
# the artifact-registry module.
resource "google_project_iam_member" "deployer" {
  for_each = toset(["roles/container.developer"])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.deployer.email}"
}
