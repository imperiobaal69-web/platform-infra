variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Region for the subnet, router and NAT."
  type        = string
}

variable "name" {
  description = "Name of the VPC; used as a prefix for the other resources."
  type        = string
}

variable "nodes_cidr" {
  description = "Primary range of the node subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for pod IPs (VPC-native cluster)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for ClusterIP services."
  type        = string
  default     = "10.30.0.0/20"
}

variable "private_services_cidr" {
  description = "Range reserved for private services access (Cloud SQL, Memorystore). NetworkPolicies allow egress to it."
  type        = string
  default     = "10.100.0.0/16"
}
