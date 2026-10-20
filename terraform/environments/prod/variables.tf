variable "project_id" {
  description = "GCP project that hosts the environment."
  type        = string
}

variable "region" {
  description = "Region for every regional resource."
  type        = string
  default     = "europe-west1"
}

variable "environment" {
  description = "Environment name, used in resource names and labels."
  type        = string
  default     = "prod"
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the GKE control plane (office, VPN, CI runners)."
  type = list(object({
    name = string
    cidr = string
  }))
  default = []
}

variable "node_machine_type" {
  description = "GKE node machine type."
  type        = string
  default     = "e2-standard-4"
}

variable "node_min_count" {
  description = "Minimum GKE nodes per zone."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum GKE nodes per zone."
  type        = number
  default     = 4
}

variable "etcd_kms_key" {
  description = "Cloud KMS key for GKE Secret encryption, or null."
  type        = string
  default     = null
}

variable "db_tier" {
  description = "Cloud SQL machine tier."
  type        = string
  default     = "db-custom-2-7680"
}

variable "db_high_availability" {
  description = "Regional Cloud SQL with automatic failover."
  type        = bool
  default     = true
}

variable "redis_tier" {
  description = "Memorystore tier (BASIC or STANDARD_HA)."
  type        = string
  default     = "STANDARD_HA"
}

variable "redis_memory_gb" {
  description = "Memorystore capacity in GiB."
  type        = number
  default     = 1
}

variable "github_repository" {
  description = "Repository whose main-branch workflows may deploy (owner/name)."
  type        = string
  default     = "imperiobaal69-web/platform-infra"
}
