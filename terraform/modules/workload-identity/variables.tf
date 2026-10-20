variable "project_id" {
  description = "GCP project ID (also names the Workload Identity pool PROJECT.svc.id.goog)."
  type        = string
}

variable "identities" {
  description = <<-EOT
    Map of service account ID to its configuration:
    kubernetes_service_accounts: "namespace/name" entries allowed to impersonate it;
    project_roles: project-level roles it receives (keep to the minimum).
  EOT
  type = map(object({
    description                 = string
    kubernetes_service_accounts = list(string)
    project_roles               = list(string)
  }))
}
