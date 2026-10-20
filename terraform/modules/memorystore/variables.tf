variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Instance region."
  type        = string
}

variable "name" {
  description = "Instance name."
  type        = string
}

variable "tier" {
  description = "BASIC (single node) or STANDARD_HA (replica with automatic failover)."
  type        = string
  default     = "STANDARD_HA"
}

variable "memory_size_gb" {
  description = "Capacity in GiB."
  type        = number
  default     = 1
}

variable "network_id" {
  description = "VPC with private services access configured."
  type        = string
}

variable "reserved_ip_range" {
  description = "Name of the private services access range to allocate from."
  type        = string
}

variable "private_services_connection" {
  description = "ID of the service networking connection; the instance is created after it."
  type        = string
}

variable "labels" {
  description = "Labels for the instance."
  type        = map(string)
  default     = {}
}
