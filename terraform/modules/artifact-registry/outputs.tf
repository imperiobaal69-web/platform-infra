output "repository_url" {
  description = "Image prefix, for example europe-west1-docker.pkg.dev/PROJECT/audio-jobs."
  value       = "${google_artifact_registry_repository.this.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.this.repository_id}"
}

output "repository_id" {
  description = "Repository resource ID."
  value       = google_artifact_registry_repository.this.id
}
