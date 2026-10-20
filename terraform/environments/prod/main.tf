# Production environment for audio-jobs on GKE. Written to be applied, but in
# this repository it is only validated (fmt, validate, tflint, trivy in CI):
# there is no GCP project behind it. See the README.

locals {
  labels = {
    app         = "audio-jobs"
    environment = var.environment
    managed-by  = "terraform"
  }

  app_namespace = "audio-jobs"
}

resource "google_project_service" "apis" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "file.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "redis.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "sts.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "network" {
  source     = "../../modules/network"
  project_id = var.project_id
  region     = var.region
  name       = "audio-jobs-${var.environment}"

  depends_on = [google_project_service.apis]
}

module "gke" {
  source              = "../../modules/gke"
  project_id          = var.project_id
  region              = var.region
  name                = "audio-jobs-${var.environment}"
  network_name        = module.network.network_name
  subnetwork_name     = module.network.subnetwork_name
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name

  master_authorized_networks = var.master_authorized_networks
  machine_type               = var.node_machine_type
  node_min_count             = var.node_min_count
  node_max_count             = var.node_max_count
  etcd_kms_key               = var.etcd_kms_key
  labels                     = local.labels
}

# Identities for the workload (Workload Identity). api, worker and the
# migration Job share one database identity because they run the same code
# against the same schema; the exporter has its own read-only one; External
# Secrets reads only the secrets it is granted below.
module "workload_identity" {
  source     = "../../modules/workload-identity"
  project_id = var.project_id
  identities = {
    "audio-jobs-app" = {
      description = "audio-jobs api, worker and migrations"
      kubernetes_service_accounts = [
        "${local.app_namespace}/api",
        "${local.app_namespace}/worker",
        "${local.app_namespace}/migrate",
      ]
      project_roles = ["roles/cloudsql.client", "roles/cloudsql.instanceUser"]
    }
    "audio-jobs-exporter" = {
      description                 = "postgres-exporter (read-only database role)"
      kubernetes_service_accounts = ["${local.app_namespace}/postgres-exporter"]
      project_roles               = ["roles/cloudsql.client", "roles/cloudsql.instanceUser"]
    }
    "external-secrets" = {
      description                 = "External Secrets Operator"
      kubernetes_service_accounts = ["external-secrets/external-secrets"]
      project_roles               = []
    }
  }
}

module "artifact_registry" {
  source     = "../../modules/artifact-registry"
  project_id = var.project_id
  region     = var.region
  name       = "audio-jobs"
  readers    = ["serviceAccount:${module.gke.node_service_account}"]
  writers    = ["serviceAccount:${module.github_oidc.deployer_email}"]
  labels     = local.labels

  depends_on = [google_project_service.apis]
}

module "cloudsql" {
  source                      = "../../modules/cloudsql"
  project_id                  = var.project_id
  region                      = var.region
  name                        = "audio-jobs-${var.environment}"
  tier                        = var.db_tier
  high_availability           = var.db_high_availability
  network_id                  = module.network.network_id
  private_services_connection = module.network.private_services_connection
  iam_users = [
    module.workload_identity.emails["audio-jobs-app"],
    module.workload_identity.emails["audio-jobs-exporter"],
  ]
  labels = local.labels
}

module "memorystore" {
  source                      = "../../modules/memorystore"
  project_id                  = var.project_id
  region                      = var.region
  name                        = "audio-jobs-${var.environment}"
  tier                        = var.redis_tier
  memory_size_gb              = var.redis_memory_gb
  network_id                  = module.network.network_id
  reserved_ip_range           = module.network.private_services_range_name
  private_services_connection = module.network.private_services_connection
  labels                      = local.labels
}

module "github_oidc" {
  source     = "../../modules/github-oidc"
  project_id = var.project_id
  repository = var.github_repository

  depends_on = [google_project_service.apis]
}

# Secrets that do exist (the application has none: it authenticates to the
# database with IAM). Terraform creates the containers only; values are added
# out of band, so they never appear in state.
resource "google_secret_manager_secret" "platform" {
  for_each  = toset(["alertmanager-pagerduty-routing-key", "grafana-admin-password"])
  project   = var.project_id
  secret_id = each.value
  labels    = local.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_iam_member" "external_secrets" {
  for_each  = google_secret_manager_secret.platform
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.workload_identity.emails["external-secrets"]}"
}
