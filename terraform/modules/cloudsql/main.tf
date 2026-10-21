# Cloud SQL for PostgreSQL with a private IP only (no public address), TLS
# required, regional HA, backups with point-in-time recovery.
#
# Applications authenticate with IAM database authentication: each Google
# service account in var.iam_users becomes a database user, and pods reach
# the instance through the Cloud SQL Auth Proxy sidecar with Workload
# Identity. No application database password exists, so none is stored in
# Terraform state or in Kubernetes.

resource "google_sql_database_instance" "this" {
  project             = var.project_id
  name                = var.name
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    edition           = "ENTERPRISE"
    availability_type = var.high_availability ? "REGIONAL" : "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = var.disk_size_gb
    disk_autoresize   = true
    user_labels       = var.labels

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.network_id
      ssl_mode                                      = "ENCRYPTED_ONLY"
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 14
      }
    }

    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = false
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_temp_files"
      value = "0"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "-1"
    }
    database_flags {
      name  = "log_min_messages"
      value = "error"
    }
  }

  depends_on = [var.private_services_connection]
}

resource "google_sql_database" "app" {
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  name     = var.database_name

  # The migrations make the app's IAM user the owner of the tables, and
  # PostgreSQL will not drop a role that owns objects. Depending on the users
  # makes destroy drop the database (and the tables in it) before them. Found
  # when the validation environment was torn down.
  depends_on = [google_sql_user.iam]
}

# IAM database users: the user name is the service account email without
# the ".gserviceaccount.com" suffix.
resource "google_sql_user" "iam" {
  for_each = toset(var.iam_users)
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  name     = trimsuffix(each.value, ".gserviceaccount.com")
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  # PostgreSQL 15+ no longer lets every role create objects in the public
  # schema, and a new IAM user has no grants at all, so without this the
  # migration fails with "permission denied for schema public".
  database_roles = lookup(var.iam_user_roles, each.value, [])
}
