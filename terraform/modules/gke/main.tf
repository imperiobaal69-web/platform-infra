# Private, regional GKE Standard cluster with one autoscaled node pool.
#
# Standard rather than Autopilot so that node sizing, surge upgrades and the
# node service account are explicit and reviewable here. Nodes have no
# external IPs; the control plane is reachable only from
# master_authorized_networks. Dataplane V2 enforces the NetworkPolicies in
# k8s/. Workload Identity replaces node credentials for pods.

resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${var.name}-nodes"
  display_name = "GKE nodes (${var.name})"
}

# The minimum a node needs: write logs and metrics, read images. Pods do not
# inherit these; they use their own identities through Workload Identity.
resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/autoscaling.metricsWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.name
  location = var.region

  network         = var.network_name
  subnetwork      = var.subnetwork_name
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # The default pool cannot be configured; replace it with the managed one.
  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = var.release_channel
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = var.private_endpoint
    master_ipv4_cidr_block  = var.master_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr
        display_name = cidr_blocks.value.name
      }
    }
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  datapath_provider           = "ADVANCED_DATAPATH"
  enable_intranode_visibility = true
  enable_shielded_nodes       = true

  # Encrypt Secrets in etcd with a customer-managed key when one is given.
  dynamic "database_encryption" {
    for_each = var.etcd_kms_key == null ? [] : [var.etcd_kms_key]
    content {
      state    = "ENCRYPTED"
      key_name = database_encryption.value
    }
  }

  binary_authorization {
    evaluation_mode = var.binary_authorization ? "PROJECT_SINGLETON_POLICY_ENFORCE" : "DISABLED"
  }

  addons_config {
    # ReadWriteMany volume for uploaded recordings (StorageClass standard-rwx).
    gcp_filestore_csi_driver_config {
      enabled = true
    }
    http_load_balancing {
      disabled = false
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  maintenance_policy {
    recurring_window {
      start_time = "2026-01-03T02:00:00Z"
      end_time   = "2026-01-03T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  resource_labels = var.labels

  deletion_protection = var.deletion_protection
}

resource "google_container_node_pool" "general" {
  project  = var.project_id
  name     = "general"
  cluster  = google_container_cluster.this.id
  location = var.region

  # Per zone; a regional cluster has three zones.
  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # One extra node at a time and never fewer than before: combined with the
  # PodDisruptionBudgets this keeps the workload serving during upgrades.
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.machine_type
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = var.labels

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}
