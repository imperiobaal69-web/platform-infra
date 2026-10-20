# Everything k8s/overlays/gke needs, plus what CI needs to authenticate.

output "cluster_name" {
  description = "GKE cluster name (gcloud container clusters get-credentials)."
  value       = module.gke.cluster_name
}

output "image_repository" {
  description = "Prefix for the workload image (kustomize images newName)."
  value       = "${module.artifact_registry.repository_url}/audio-jobs"
}

output "cloudsql_connection_name" {
  description = "Cloud SQL Auth Proxy instance connection name."
  value       = module.cloudsql.connection_name
}

output "database_users" {
  description = "IAM database user names (DATABASE_URL user part)."
  value       = module.cloudsql.iam_user_names
}

output "redis_address" {
  description = "REDIS_ADDR for the ConfigMap."
  value       = module.memorystore.address
}

output "private_services_cidr" {
  description = "Egress CIDR for the datastore NetworkPolicies."
  value       = module.network.private_services_cidr
}

output "workload_identity_service_accounts" {
  description = "Google service account per identity, for the iam.gke.io/gcp-service-account annotations."
  value       = module.workload_identity.emails
}

output "ci_workload_identity_provider" {
  description = "workload_identity_provider input of google-github-actions/auth."
  value       = module.github_oidc.workload_identity_provider
}

output "ci_service_account" {
  description = "service_account input of google-github-actions/auth."
  value       = module.github_oidc.deployer_email
}
