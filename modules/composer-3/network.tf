# Composer 3 runs its infrastructure in a Google-managed tenant project. Attaching it to a
# VPC makes Composer create a Private Service Connect network attachment in the subnet, which
# uses IPs from the subnet's primary range. No GKE secondary ranges or Composer-specific
# firewall rules are needed (those were Composer 2 requirements).

# ── VPC Network ────────────────────────────────────────────────────────
resource "google_compute_network" "composer" {
  count = local.network.create ? 1 : 0

  project                 = local.project_id
  name                    = local.network.name
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

# ── Subnetwork (hosts the Composer network attachment) ─────────────────
resource "google_compute_subnetwork" "composer" {
  count = local.network.create ? 1 : 0

  project       = local.project_id
  name          = local.network.subnetwork_name
  region        = local.region
  network       = google_compute_network.composer[0].id
  ip_cidr_range = local.network.subnetwork_cidr

  private_ip_google_access = true
}

# ── Cloud Router (required for Cloud NAT) ──────────────────────────────
resource "google_compute_router" "composer" {
  count = local.network.create && local.network.enable_cloud_nat ? 1 : 0

  project = local.project_id
  name    = "${local.environment_name}-router"
  region  = local.region
  network = google_compute_network.composer[0].id
}

# ── Cloud NAT (outbound internet for traffic routed through the VPC) ───
# A Private IP environment attached to this VPC sends its traffic into the VPC, so NAT
# is what gives its Airflow components internet access.
resource "google_compute_router_nat" "composer" {
  count = local.network.create && local.network.enable_cloud_nat ? 1 : 0

  project                            = local.project_id
  name                               = "${local.environment_name}-nat"
  router                             = google_compute_router.composer[0].name
  region                             = local.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
