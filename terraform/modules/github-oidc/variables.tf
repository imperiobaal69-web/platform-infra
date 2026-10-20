variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "repository" {
  description = "GitHub repository (owner/name) allowed to authenticate."
  type        = string
}

variable "allowed_refs" {
  description = "Git refs whose workflows may impersonate the deployer."
  type        = list(string)
  default     = ["refs/heads/main"]
}

variable "pool_id" {
  description = "Workload Identity pool ID."
  type        = string
  default     = "github"
}

variable "deployer_account_id" {
  description = "Account ID of the CI deployer service account."
  type        = string
  default     = "ci-deployer"
}
