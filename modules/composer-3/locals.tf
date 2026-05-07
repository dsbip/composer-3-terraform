locals {
  # ── Identity ─────────────────────────────────────────────────────────
  environment_name = try(var.config.environment_name, var.environment_key)
  project_id       = try(var.config.project_id, var.global_config.project_id)
  region           = try(var.config.region, try(var.global_config.region, "europe-west2"))

  # ── Labels (global merged with per-env; per-env wins) ───────────────
  global_labels = try(var.global_config.labels, {})
  env_labels    = try(var.config.labels, {})
  labels        = merge(local.global_labels, local.env_labels)

  # ── Environment sizing ──────────────────────────────────────────────
  environment_size = try(var.config.environment_size, "ENVIRONMENT_SIZE_SMALL")
  resilience_mode  = try(var.config.resilience_mode, null)

  # ── API enablement ──────────────────────────────────────────────────
  enable_apis = try(var.config.enable_apis, try(var.global_config.enable_apis, true))
  default_apis = [
    "composer.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
  ]
  cmek_apis  = local.encryption.enable_cmek ? ["cloudkms.googleapis.com"] : []
  extra_apis = try(var.config.apis, try(var.global_config.apis, []))
  all_apis   = local.enable_apis ? distinct(concat(local.default_apis, local.cmek_apis, local.extra_apis)) : []

  # ── Network (all defaulted from environment name) ───────────────────
  network = {
    create              = try(var.config.network.create, true)
    name                = try(var.config.network.name, "${local.environment_name}-network")
    subnetwork_name     = try(var.config.network.subnetwork_name, "${local.environment_name}-subnet")
    subnetwork_cidr     = try(var.config.network.subnetwork_cidr, "10.0.0.0/24")
    existing_network    = try(var.config.network.existing_network, null)
    existing_subnetwork = try(var.config.network.existing_subnetwork, null)
    pods_range_name     = try(var.config.network.pods_range_name, "pods")
    pods_cidr           = try(var.config.network.pods_cidr, "10.1.0.0/16")
    services_range_name = try(var.config.network.services_range_name, "services")
    services_cidr       = try(var.config.network.services_cidr, "10.2.0.0/20")
    enable_cloud_nat    = try(var.config.network.enable_cloud_nat, false)
    tags                = try(var.config.network.tags, ["composer"])
  }

  network_self_link    = local.network.create ? google_compute_network.composer[0].self_link : local.network.existing_network
  subnetwork_self_link = local.network.create ? google_compute_subnetwork.composer[0].self_link : local.network.existing_subnetwork

  # ── Service account (auto-named: {environment_name}-sa) ─────────────
  service_account = {
    create         = try(var.config.service_account.create, true)
    name           = try(var.config.service_account.name, "${local.environment_name}-sa")
    existing_email = try(var.config.service_account.existing_email, null)
    roles = try(var.config.service_account.roles, [
      "roles/composer.worker",
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ])
  }

  composer_sa_email = (
    local.service_account.create
    ? google_service_account.composer[0].email
    : local.service_account.existing_email
  )

  # ── Software (image_version null = GCP picks latest) ────────────────
  software_config = {
    image_version            = try(var.config.software_config.image_version, null)
    airflow_config_overrides = try(var.config.software_config.airflow_config_overrides, {})
    env_variables            = try(var.config.software_config.env_variables, {})
    pypi_packages            = try(var.config.software_config.pypi_packages, {})
  }

  # ── Workloads ───────────────────────────────────────────────────────
  # scheduler, web_server, worker: always created with defaults
  # triggerer, dag_processor: only when explicitly provided in YAML
  workloads = {
    scheduler = {
      cpu        = try(var.config.workloads.scheduler.cpu, 0.5)
      memory_gb  = try(var.config.workloads.scheduler.memory_gb, 2)
      storage_gb = try(var.config.workloads.scheduler.storage_gb, 1)
      count      = try(var.config.workloads.scheduler.count, 1)
    }
    web_server = {
      cpu        = try(var.config.workloads.web_server.cpu, 1)
      memory_gb  = try(var.config.workloads.web_server.memory_gb, 2)
      storage_gb = try(var.config.workloads.web_server.storage_gb, 1)
    }
    worker = {
      cpu        = try(var.config.workloads.worker.cpu, 1)
      memory_gb  = try(var.config.workloads.worker.memory_gb, 2)
      storage_gb = try(var.config.workloads.worker.storage_gb, 1)
      min_count  = try(var.config.workloads.worker.min_count, 1)
      max_count  = try(var.config.workloads.worker.max_count, 3)
    }
    triggerer = try(var.config.workloads.triggerer, null) != null ? {
      cpu       = try(var.config.workloads.triggerer.cpu, 0.5)
      memory_gb = try(var.config.workloads.triggerer.memory_gb, 0.5)
      count     = try(var.config.workloads.triggerer.count, 1)
    } : null
    dag_processor = try(var.config.workloads.dag_processor, null) != null ? {
      cpu        = try(var.config.workloads.dag_processor.cpu, 1)
      memory_gb  = try(var.config.workloads.dag_processor.memory_gb, 2)
      storage_gb = try(var.config.workloads.dag_processor.storage_gb, 1)
      count      = try(var.config.workloads.dag_processor.count, 1)
    } : null
  }

  # ── Private environment ─────────────────────────────────────────────
  private_environment = try(var.config.private_environment, null) != null ? {
    enable_private_endpoint                = try(var.config.private_environment.enable_private_endpoint, false)
    cloud_sql_ipv4_cidr_block              = try(var.config.private_environment.cloud_sql_ipv4_cidr_block, null)
    web_server_ipv4_cidr_block             = try(var.config.private_environment.web_server_ipv4_cidr_block, null)
    master_ipv4_cidr_block                 = try(var.config.private_environment.master_ipv4_cidr_block, null)
    cloud_composer_network_ipv4_cidr_block = try(var.config.private_environment.cloud_composer_network_ipv4_cidr_block, null)
    enable_privately_used_public_ips       = try(var.config.private_environment.enable_privately_used_public_ips, false)
    connection_type                        = try(var.config.private_environment.connection_type, "VPC_PEERING")
  } : null

  # ── Master authorized networks ──────────────────────────────────────
  master_authorized_networks = try(var.config.master_authorized_networks, null)

  # ── Maintenance window ──────────────────────────────────────────────
  maintenance_window = try(var.config.maintenance_window, null)

  # ── Encryption (CMEK) ──────────────────────────────────────────────
  encryption = {
    enable_cmek             = try(var.config.encryption.enable_cmek, false)
    kms_key_ring_name       = try(var.config.encryption.kms_key_ring_name, "${local.environment_name}-keyring")
    kms_key_name            = try(var.config.encryption.kms_key_name, "${local.environment_name}-key")
    kms_key_rotation_period = try(var.config.encryption.kms_key_rotation_period, "7776000s")
    existing_kms_key        = try(var.config.encryption.existing_kms_key, null)
  }

  kms_key_id = local.encryption.enable_cmek ? (
    local.encryption.existing_kms_key != null
    ? local.encryption.existing_kms_key
    : google_kms_crypto_key.composer[0].id
  ) : null

  # ── Recovery ────────────────────────────────────────────────────────
  recovery = try(var.config.recovery, null)

  # ── Data retention ──────────────────────────────────────────────────
  data_retention = try(var.config.data_retention, null)

  # ── Storage ─────────────────────────────────────────────────────────
  custom_bucket = try(var.config.storage.bucket, null)
}
