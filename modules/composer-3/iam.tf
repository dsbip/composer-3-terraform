resource "google_service_account" "composer" {
  count = local.service_account.create ? 1 : 0

  project      = local.project_id
  account_id   = local.service_account.name
  display_name = "Cloud Composer 3 SA for ${local.environment_name}"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "composer_sa_roles" {
  for_each = toset(local.service_account.roles)

  project = local.project_id
  role    = each.value
  member  = "serviceAccount:${local.composer_sa_email}"
}

data "google_project" "this" {
  project_id = local.project_id
}

resource "google_project_iam_member" "composer_agent_v2ext" {
  project = local.project_id
  role    = "roles/composer.ServiceAgentV2Ext"
  member  = "serviceAccount:service-${data.google_project.this.number}@cloudcomposer-accounts.iam.gserviceaccount.com"
}

resource "google_service_account_iam_member" "composer_agent_sa_user" {
  service_account_id = (
    local.service_account.create
    ? google_service_account.composer[0].name
    : "projects/${local.project_id}/serviceAccounts/${local.service_account.existing_email}"
  )
  role   = "roles/iam.serviceAccountUser"
  member = "serviceAccount:service-${data.google_project.this.number}@cloudcomposer-accounts.iam.gserviceaccount.com"
}
