# Docker repository for the workload image. Tags are immutable, so a tag
# always names the same image (deploys and rollbacks are reproducible), and
# a cleanup policy keeps storage bounded.

resource "google_artifact_registry_repository" "this" {
  project       = var.project_id
  location      = var.region
  repository_id = var.name
  description   = "Container images for ${var.name}"
  format        = "DOCKER"
  labels        = var.labels

  docker_config {
    immutable_tags = true
  }

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.keep_versions
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "1209600s" # 14 days
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each   = toset(var.readers)
  project    = var.project_id
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each   = toset(var.writers)
  project    = var.project_id
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}
