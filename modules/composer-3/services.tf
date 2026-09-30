resource "google_project_service" "required" {
  for_each = toset(local.all_apis)

  project            = local.project_id
  service            = each.value
  disable_on_destroy = false
}

# Creates the Composer service agent (service-<number>@cloudcomposer-accounts...) if the
# project has never used Composer, so the IAM bindings that reference it succeed on the
# first apply. Idempotent; destroying it is a no-op.
resource "google_project_service_identity" "composer" {
  provider = google-beta

  project = local.project_id
  service = "composer.googleapis.com"

  depends_on = [google_project_service.required]
}
