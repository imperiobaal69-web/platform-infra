output "network_id" {
  description = "Self link ID of the VPC."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "Name of the VPC."
  value       = google_compute_network.this.name
}

output "subnetwork_name" {
  description = "Name of the node subnet."
  value       = google_compute_subnetwork.nodes.name
}

output "pods_range_name" {
  description = "Name of the secondary range for pods."
  value       = "pods"
}

output "services_range_name" {
  description = "Name of the secondary range for services."
  value       = "services"
}

output "private_services_cidr" {
  description = "CIDR used by Cloud SQL and Memorystore private IPs."
  value       = var.private_services_cidr
}

output "private_services_range_name" {
  description = "Name of the reserved private services access range."
  value       = google_compute_global_address.private_services.name
}

output "private_services_connection" {
  description = "The service networking connection; datastores depend on it."
  value       = google_service_networking_connection.private_services.id
}
