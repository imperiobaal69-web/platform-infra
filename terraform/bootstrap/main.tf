# One-time bootstrap: the GCS bucket that holds Terraform state for every
# environment. Applied once with local state by a project owner; everything
# else uses this bucket as its backend.

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

variable "project_id" {
  description = "GCP project that holds the state bucket."
  type        = string
}

variable "location" {
  description = "Bucket location."
  type        = string
  default     = "EU"
}

#trivy:ignore:AVD-GCP-0066 Google-managed encryption is acceptable for state; a CMEK can be added with the kms block
resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-tfstate"
  location                    = var.location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # Every state write is a new object version: a bad apply can be undone by
  # restoring the previous version.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 50
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }
}

output "state_bucket" {
  description = "Bucket name for backend.hcl."
  value       = google_storage_bucket.tfstate.name
}
