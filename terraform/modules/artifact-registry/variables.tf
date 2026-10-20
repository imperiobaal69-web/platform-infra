variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Repository location."
  type        = string
}

variable "name" {
  description = "Repository ID."
  type        = string
}

variable "readers" {
  description = "IAM members allowed to pull (for example the GKE node service account)."
  type        = list(string)
  default     = []
}

variable "writers" {
  description = "IAM members allowed to push (for example the CI service account)."
  type        = list(string)
  default     = []
}

variable "keep_versions" {
  description = "Most recent image versions always kept by the cleanup policy."
  type        = number
  default     = 20
}

variable "labels" {
  description = "Labels for the repository."
  type        = map(string)
  default     = {}
}
