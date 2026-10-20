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

variable "database_version" {
  description = "Cloud SQL Postgres version."
  type        = string
  default     = "POSTGRES_17"
}

variable "tier" {
  description = "Machine tier."
  type        = string
  default     = "db-custom-2-7680"
}

variable "disk_size_gb" {
  description = "Initial disk size; grows automatically."
  type        = number
  default     = 20
}

variable "high_availability" {
  description = "Regional (primary plus standby in another zone, automatic failover) instead of zonal."
  type        = bool
  default     = true
}

variable "network_id" {
  description = "VPC with private services access configured."
  type        = string
}

variable "private_services_connection" {
  description = "ID of the service networking connection; the instance is created after it."
  type        = string
}

variable "database_name" {
  description = "Application database."
  type        = string
  default     = "audiojobs"
}

variable "iam_users" {
  description = "Service account emails that become IAM database users."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  description = "Refuse terraform destroy of the instance."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels for the instance."
  type        = map(string)
  default     = {}
}
