locals {
  # Values are resolved with coalesce() so that an explicit YAML null (e.g. `region:` with
  # no value) behaves like an omitted key and falls back to the default.

  # ── Identity ─────────────────────────────────────────────────────────
  environment_name = coalesce(try(var.config.environment_name, null), var.environment_key)
  project_id       = try(coalesce(try(var.config.project_id, null), try(var.global_config.project_id, null)), null)
  region           = coalesce(try(var.config.region, null), try(var.global_config.region, null), "europe-west2")

  # ── Labels (global merged with per-env; per-env wins) ───────────────
  labels = {
    for k, v in merge(
      try(coalesce(var.global_config.labels, {}), {}),
      try(coalesce(var.config.labels, {}), {}),
    ) : k => tostring(v)
  }

  # ── Environment sizing ──────────────────────────────────────────────
  environment_size = coalesce(try(var.config.environment_size, null), "ENVIRONMENT_SIZE_SMALL")
  resilience_mode  = try(var.config.resilience_mode, null)
  high_resilience  = local.resilience_mode == "HIGH_RESILIENCE"

  # ── Networking type (Composer 3: Public IP by default) ──────────────
  enable_private_environment = try(var.config.enable_private_environment, null)
  enable_private_builds_only = try(var.config.enable_private_builds_only, null)

  # ── API enablement ──────────────────────────────────────────────────
  enable_apis = try(coalesce(try(var.config.enable_apis, null), try(var.global_config.enable_apis, null)), true)
  default_apis = [
    "composer.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
  ]
  feature_apis = concat(
    local.encryption.enable_cmek ? ["cloudkms.googleapis.com"] : [],
    local.software_config.cloud_data_lineage == true ? ["datalineage.googleapis.com"] : [],
  )
  extra_apis = compact(flatten([try(var.config.apis, var.global_config.apis, [])]))
  all_apis   = local.enable_apis ? distinct(concat(local.default_apis, local.feature_apis, local.extra_apis)) : []

  # ── Network ─────────────────────────────────────────────────────────
  # Composer 3 attaches to a VPC through a Private Service Connect network attachment that
  # takes IPs from the subnet's primary range; no GKE secondary ranges are involved.
  network_uses_existing = (
    try(var.config.network.existing_network, null) != null ||
    try(var.config.network.existing_subnetwork, null) != null ||
    try(var.config.network.existing_network_attachment, null) != null
  )

  network = {
    # Defaults to creating a VPC unless existing networking was supplied.
    create                            = coalesce(try(var.config.network.create, null), !local.network_uses_existing)
    name                              = coalesce(try(var.config.network.name, null), "${local.environment_name}-network")
    subnetwork_name                   = coalesce(try(var.config.network.subnetwork_name, null), "${local.environment_name}-subnet")
    subnetwork_cidr                   = coalesce(try(var.config.network.subnetwork_cidr, null), "10.0.0.0/24")
    existing_network                  = try(var.config.network.existing_network, null)
    existing_subnetwork               = try(var.config.network.existing_subnetwork, null)
    existing_network_attachment       = try(var.config.network.existing_network_attachment, null)
    composer_internal_ipv4_cidr_block = try(var.config.network.composer_internal_ipv4_cidr_block, null)
    enable_cloud_nat                  = coalesce(try(var.config.network.enable_cloud_nat, null), false)
    tags                              = try(var.config.network.tags, ["composer"])
  }

  # null (with no attachment either) = environment not attached to any VPC.
  network_self_link    = local.network.create ? google_compute_network.composer[0].self_link : local.network.existing_network
  subnetwork_self_link = local.network.create ? google_compute_subnetwork.composer[0].self_link : local.network.existing_subnetwork

  # ── Service account (auto-named: {environment_name}-sa) ─────────────
  default_sa_roles = [
    "roles/composer.worker",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]

  service_account = {
    # Defaults to creating an SA unless an existing one was supplied.
    create         = coalesce(try(var.config.service_account.create, null), try(var.config.service_account.existing_email, null) == null)
    name           = coalesce(try(var.config.service_account.name, null), "${local.environment_name}-sa")
    existing_email = try(var.config.service_account.existing_email, null)
    roles          = try(var.config.service_account.roles, null) == null ? local.default_sa_roles : var.config.service_account.roles
  }

  # false only for an invalid config (create: false without existing_email); keeps the IAM
  # resources from failing on a null email before validation.tf can report the problem.
  service_account_configured = local.service_account.create || local.service_account.existing_email != null

  composer_sa_email = (
    local.service_account.create
    ? google_service_account.composer[0].email
    : local.service_account.existing_email
  )

  # Project that owns an existing SA (parsed from its email) so it can be addressed for IAM.
  existing_sa_project = try(
    regex("@([a-z][-a-z0-9]*[a-z0-9])\\.iam\\.gserviceaccount\\.com$", local.service_account.existing_email)[0],
    local.project_id,
  )

  # Google-managed Composer service agent (created by google_project_service_identity.composer).
  composer_service_agent = "service-${data.google_project.this.number}@cloudcomposer-accounts.iam.gserviceaccount.com"

  # ── Software ────────────────────────────────────────────────────────
  # The Composer API defaults to a Composer 2 image when none is given, so an explicit
  # Composer 3 alias is always sent. composer-3-airflow-2 = latest build of Airflow 2.
  default_image_version = "composer-3-airflow-2"

  software_config = {
    image_version            = coalesce(try(var.config.software_config.image_version, null), local.default_image_version)
    airflow_config_overrides = { for k, v in try(coalesce(var.config.software_config.airflow_config_overrides, {}), {}) : k => tostring(v) }
    env_variables            = { for k, v in try(coalesce(var.config.software_config.env_variables, {}), {}) : k => tostring(v) }
    # A package with no version (`pandas:`) is installed unpinned.
    pypi_packages           = { for k, v in try(coalesce(var.config.software_config.pypi_packages, {}), {}) : k => v == null ? "" : tostring(v) }
    web_server_plugins_mode = try(var.config.software_config.web_server_plugins_mode, null)
    cloud_data_lineage      = try(var.config.software_config.cloud_data_lineage_integration.enabled, null)
  }

  # Airflow 3 raises several per-component memory minimums from 1 GB to 2 GB.
  airflow_major = try(tonumber(regex("^composer-3-airflow-([0-9]+)", local.software_config.image_version)[0]), 2)

  # ── Workloads ───────────────────────────────────────────────────────
  # scheduler, web_server, worker: always configured with defaults.
  # triggerer, dag_processor: configured only when their block is present in YAML;
  # otherwise GCP's defaults apply (Composer 3 always runs a DAG processor).
  # HIGH_RESILIENCE needs 2 schedulers, >= 2 workers and >= 2 DAG processors / triggerers,
  # so the defaults follow the resilience mode.
  worker_min_count = coalesce(try(var.config.workloads.worker.min_count, null), local.high_resilience ? 2 : 1)

  workloads = {
    scheduler = {
      cpu        = coalesce(try(var.config.workloads.scheduler.cpu, null), 0.5)
      memory_gb  = coalesce(try(var.config.workloads.scheduler.memory_gb, null), 2)
      storage_gb = coalesce(try(var.config.workloads.scheduler.storage_gb, null), 1)
      count      = coalesce(try(var.config.workloads.scheduler.count, null), local.high_resilience ? 2 : 1)
    }
    web_server = {
      cpu        = coalesce(try(var.config.workloads.web_server.cpu, null), 1)
      memory_gb  = coalesce(try(var.config.workloads.web_server.memory_gb, null), 2)
      storage_gb = coalesce(try(var.config.workloads.web_server.storage_gb, null), 1)
    }
    worker = {
      cpu        = coalesce(try(var.config.workloads.worker.cpu, null), 1)
      memory_gb  = coalesce(try(var.config.workloads.worker.memory_gb, null), 2)
      storage_gb = coalesce(try(var.config.workloads.worker.storage_gb, null), 1)
      min_count  = local.worker_min_count
      max_count  = coalesce(try(var.config.workloads.worker.max_count, null), max(3, local.worker_min_count))
    }
    triggerer = try(var.config.workloads.triggerer, null) == null ? null : {
      cpu       = coalesce(try(var.config.workloads.triggerer.cpu, null), 0.5)
      memory_gb = coalesce(try(var.config.workloads.triggerer.memory_gb, null), local.airflow_major >= 3 ? 2 : 1)
      count     = coalesce(try(var.config.workloads.triggerer.count, null), local.high_resilience ? 2 : 1)
    }
    dag_processor = try(var.config.workloads.dag_processor, null) == null ? null : {
      cpu        = coalesce(try(var.config.workloads.dag_processor.cpu, null), 1)
      memory_gb  = coalesce(try(var.config.workloads.dag_processor.memory_gb, null), 2)
      storage_gb = coalesce(try(var.config.workloads.dag_processor.storage_gb, null), 1)
      count      = coalesce(try(var.config.workloads.dag_processor.count, null), local.high_resilience ? 2 : 1)
    }
  }

  # ── Airflow UI network access control ───────────────────────────────
  web_server_access_control_enabled = try(var.config.web_server_network_access_control, null) != null
  web_server_allowed_ip_ranges = try([
    for r in var.config.web_server_network_access_control.allowed_ip_ranges : {
      value       = try(r.value, null)
      description = try(r.description, null)
    }
  ], [])

  # ── Maintenance window ──────────────────────────────────────────────
  maintenance_window = try(var.config.maintenance_window, null) == null ? null : {
    start_time = try(var.config.maintenance_window.start_time, null)
    end_time   = try(var.config.maintenance_window.end_time, null)
    recurrence = try(var.config.maintenance_window.recurrence, null)
  }

  # ── Encryption (CMEK) ──────────────────────────────────────────────
  encryption = {
    # Supplying existing_kms_key implies enable_cmek.
    enable_cmek             = coalesce(try(var.config.encryption.enable_cmek, null), try(var.config.encryption.existing_kms_key, null) != null)
    kms_key_ring_name       = coalesce(try(var.config.encryption.kms_key_ring_name, null), "${local.environment_name}-keyring")
    kms_key_name            = coalesce(try(var.config.encryption.kms_key_name, null), "${local.environment_name}-key")
    kms_key_rotation_period = coalesce(try(var.config.encryption.kms_key_rotation_period, null), "7776000s")
    existing_kms_key        = try(var.config.encryption.existing_kms_key, null)
  }

  create_kms_key = local.encryption.enable_cmek && local.encryption.existing_kms_key == null

  kms_key_id = local.encryption.enable_cmek ? (
    local.encryption.existing_kms_key != null
    ? local.encryption.existing_kms_key
    : google_kms_crypto_key.composer[0].id
  ) : null

  # ── Recovery (scheduled snapshots) ──────────────────────────────────
  recovery = try(var.config.recovery, null) == null ? null : {
    enabled = try(tobool(coalesce(try(var.config.recovery.enable_scheduled_snapshots, null), true)), false)
    # A gs:// bucket folder, not a region.
    snapshot_location          = try(var.config.recovery.snapshot_location, null)
    snapshot_creation_schedule = coalesce(try(var.config.recovery.snapshot_creation_schedule, null), "0 3 * * *")
    # A fixed UTC offset (UTC, UTC+01, UTC-06); IANA zone names are not accepted.
    time_zone = coalesce(try(var.config.recovery.time_zone, null), "UTC")
  }

  # ── Data retention (Airflow metadata database) ──────────────────────
  metadata_retention_mode = coalesce(try(var.config.data_retention.airflow_metadata_retention_config.retention_mode, null), "RETENTION_MODE_ENABLED")

  metadata_retention = try(var.config.data_retention.airflow_metadata_retention_config, null) == null ? null : {
    retention_mode = local.metadata_retention_mode
    retention_days = (
      local.metadata_retention_mode == "RETENTION_MODE_ENABLED"
      ? coalesce(try(var.config.data_retention.airflow_metadata_retention_config.retention_days, null), 30)
      : null
    )
  }

  # ── Storage ─────────────────────────────────────────────────────────
  custom_bucket = try(trimprefix(var.config.storage.bucket, "gs://"), null)
}
