output "cluster_name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "cluster_location" {
  description = "Cluster location (region)."
  value       = google_container_cluster.this.location
}

output "endpoint" {
  description = "Control plane endpoint."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "workload_pool" {
  description = "Workload Identity pool (PROJECT.svc.id.goog)."
  value       = "${var.project_id}.svc.id.goog"
}

output "node_service_account" {
  description = "Email of the node service account."
  value       = google_service_account.nodes.email
}
