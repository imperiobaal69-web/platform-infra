# Memorystore for Redis, reached over private services access.
#
# Same major version as the local stand-in (7.2). Persistence is disabled on
# purpose: Redis carries only the queue and a cache, Postgres is the source of
# truth and the workers' sweeper rebuilds the queue after data loss.
# noeviction keeps Redis from silently dropping queue entries.
#
# AUTH and in-transit encryption are off because the application's Redis
# client is configured with an address only. Turning them on needs a small
# change in audio-jobs (password from Secret Manager, TLS config); it is
# listed under known gaps in the README.

resource "google_redis_instance" "this" {
  project        = var.project_id
  name           = var.name
  region         = var.region
  tier           = var.tier
  memory_size_gb = var.memory_size_gb
  redis_version  = "REDIS_7_2"
  labels         = var.labels

  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  authorized_network = var.network_id
  reserved_ip_range  = var.reserved_ip_range

  redis_configs = {
    maxmemory-policy = "noeviction"
  }

  persistence_config {
    persistence_mode = "DISABLED"
  }

  #trivy:ignore:AVD-GCP-0001 application client has no AUTH support yet (README, known gaps)
  auth_enabled = false
  #trivy:ignore:AVD-GCP-0002 application client has no TLS support yet (README, known gaps)
  transit_encryption_mode = "DISABLED"

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 3
        minutes = 0
      }
    }
  }

  depends_on = [var.private_services_connection]
}
