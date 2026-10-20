output "emails" {
  description = "Service account email per identity; annotate the Kubernetes service accounts with these (iam.gke.io/gcp-service-account)."
  value       = { for name, sa in google_service_account.this : name => sa.email }
}
