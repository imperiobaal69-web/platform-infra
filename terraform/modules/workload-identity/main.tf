# One Google service account per workload identity, bound to the Kubernetes
# service accounts that may act as it, with only the project roles listed for
# it. Pods get short-lived tokens from the GKE metadata server; no key files.

resource "google_service_account" "this" {
  for_each     = var.identities
  project      = var.project_id
  account_id   = each.key
  display_name = each.value.description
}

locals {
  ksa_bindings = merge([
    for name, identity in var.identities : {
      for ksa in identity.kubernetes_service_accounts : "${name}/${ksa}" => {
        identity = name
        member   = "serviceAccount:${var.project_id}.svc.id.goog[${ksa}]"
      }
    }
  ]...)

  role_bindings = merge([
    for name, identity in var.identities : {
      for role in identity.project_roles : "${name}/${role}" => {
        identity = name
        role     = role
      }
    }
  ]...)
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each           = local.ksa_bindings
  service_account_id = google_service_account.this[each.value.identity].name
  role               = "roles/iam.workloadIdentityUser"
  member             = each.value.member
}

resource "google_project_iam_member" "roles" {
  for_each = local.role_bindings
  project  = var.project_id
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.this[each.value.identity].email}"
}
