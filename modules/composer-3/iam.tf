resource "google_service_account" "composer" {
  count = local.service_account.create ? 1 : 0

  project      = local.project_id
  account_id   = local.service_account.name
  display_name = "Cloud Composer 3 SA for ${local.environment_name}"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "composer_sa_roles" {
  for_each = local.service_account_configured ? toset(local.service_account.roles) : toset([])

  project = local.project_id
  role    = each.value
  member  = "serviceAccount:${local.composer_sa_email}"
}

data "google_project" "this" {
  project_id = local.project_id

  lifecycle {
    precondition {
      condition     = local.project_id != null
      error_message = "No project_id for Composer environment \"${var.environment_key}\": set project_id at the top of the YAML file or in the environment."
    }
  }
}

# Composer 3's service agent only needs its default roles/composer.serviceAgent, which Google
# grants automatically. roles/composer.ServiceAgentV2Ext is a Composer 2 requirement and is
# deliberately not granted.

# Lets the Composer service agent act as the environment's service account (also covers an
# existing SA that lives in another project).
resource "google_service_account_iam_member" "composer_agent_sa_user" {
  count = local.service_account_configured ? 1 : 0

  service_account_id = (
    local.service_account.create
    ? google_service_account.composer[0].name
    : "projects/${local.existing_sa_project}/serviceAccounts/${local.service_account.existing_email}"
  )
  role   = "roles/iam.serviceAccountUser"
  member = "serviceAccount:${local.composer_service_agent}"

  # The service agent must exist before it can be referenced in an IAM binding.
  depends_on = [google_project_service_identity.composer]
}

moved {
  from = google_service_account_iam_member.composer_agent_sa_user
  to   = google_service_account_iam_member.composer_agent_sa_user[0]
}
