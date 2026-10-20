output "workload_identity_provider" {
  description = "Value for google-github-actions/auth workload_identity_provider."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_email" {
  description = "Service account the CI workflow impersonates."
  value       = google_service_account.deployer.email
}
