# ── VPC Network ────────────────────────────────────────────────────────
resource "google_compute_network" "composer" {
  count = local.network.create ? 1 : 0

  project                 = local.project_id
  name                    = local.network.name
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

# ── Subnetwork with secondary ranges for pods/services ─────────────────
resource "google_compute_subnetwork" "composer" {
  count = local.network.create ? 1 : 0

  project       = local.project_id
  name          = local.network.subnetwork_name
  region        = local.region
  network       = google_compute_network.composer[0].id
  ip_cidr_range = local.network.subnetwork_cidr

  secondary_ip_range {
    range_name    = local.network.pods_range_name
    ip_cidr_range = local.network.pods_cidr
  }

  secondary_ip_range {
    range_name    = local.network.services_range_name
    ip_cidr_range = local.network.services_cidr
  }

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

# ── Cloud NAT (outbound internet for private environments) ─────────────
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

# ── Firewall: allow internal traffic between Composer components ───────
resource "google_compute_firewall" "composer_internal" {
  count = local.network.create ? 1 : 0

  project = local.project_id
  name    = "${local.environment_name}-allow-internal"
  network = google_compute_network.composer[0].id

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [
    local.network.subnetwork_cidr,
    local.network.pods_cidr,
    local.network.services_cidr,
  ]

  target_tags = local.network.tags
}

# ── Firewall: allow health checks from GCP load balancer ranges ───────
resource "google_compute_firewall" "composer_health_checks" {
  count = local.network.create ? 1 : 0

  project = local.project_id
  name    = "${local.environment_name}-allow-health-checks"
  network = google_compute_network.composer[0].id

  allow {
    protocol = "tcp"
  }

  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]

  target_tags = local.network.tags
}
