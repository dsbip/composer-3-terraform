resource "google_project_service" "required" {
  for_each = toset(local.all_apis)

  project            = local.project_id
  service            = each.value
  disable_on_destroy = false
}
