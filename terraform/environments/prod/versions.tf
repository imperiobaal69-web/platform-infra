terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # Remote state in a versioned GCS bucket created by terraform/bootstrap.
  # The bucket name is supplied at init time so it is not hard-coded:
  #   terraform init -backend-config=backend.hcl
  # CI validates with: terraform init -backend=false
  backend "gcs" {
    prefix = "audio-jobs/prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
