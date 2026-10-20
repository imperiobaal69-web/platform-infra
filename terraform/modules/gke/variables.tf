variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Region of the (regional) cluster."
  type        = string
}

variable "name" {
  description = "Cluster name; also prefixes the node service account."
  type        = string
}

variable "network_name" {
  description = "VPC name (network module output)."
  type        = string
}

variable "subnetwork_name" {
  description = "Node subnet name (network module output)."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pods."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for services."
  type        = string
}

variable "master_cidr" {
  description = "/28 range for the control plane's private endpoint."
  type        = string
  default     = "172.16.0.0/28"
}

variable "private_endpoint" {
  description = "If true the control plane has no public endpoint; kubectl then needs to run inside the VPC (bastion or Connect Gateway)."
  type        = bool
  default     = false
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the control plane endpoint."
  type = list(object({
    name = string
    cidr = string
  }))
  default = []
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"
}

variable "machine_type" {
  description = "Node machine type."
  type        = string
  default     = "e2-standard-4"
}

variable "node_min_count" {
  description = "Minimum nodes per zone."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum nodes per zone."
  type        = number
  default     = 4
}

variable "etcd_kms_key" {
  description = "Cloud KMS key for application-layer Secret encryption, or null to use Google-managed encryption."
  type        = string
  default     = null
}

variable "binary_authorization" {
  description = "Enforce the project's Binary Authorization policy on deployed images."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to the cluster and nodes."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Refuse terraform destroy of the cluster."
  type        = bool
  default     = true
}
