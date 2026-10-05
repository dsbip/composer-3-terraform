# ── Configuration checks ───────────────────────────────────────────────
# The provider skips its own validation of everything nested under `config` while any value
# in that block is still unknown at plan time (always the case here: the network and service
# account are created in the same run). Without these checks, mistakes such as an invalid
# retention period or a too-short maintenance window only fail at apply time, after the
# network, IAM and KMS resources already exist.
#
# Every failed check is reported in one precondition error on google_composer_environment.this
# (see main.tf). With create_composer_environment: false that resource does not exist, so the
# composer_environment_created output (outputs.tf) reports the same error instead: the whole
# configuration is still checked, so that switching the environment back on cannot fail at
# apply time. Expressions must not error: older Terraform releases, including 1.2 (the minimum
# this module supports), do not short-circuit || and &&, so the right side is evaluated even when
# the left side already decides the result. Anything that can fail on a missing value is
# therefore wrapped in try() or can().

locals {
  allowed_environment_sizes = [
    "ENVIRONMENT_SIZE_SMALL",
    "ENVIRONMENT_SIZE_MEDIUM",
    "ENVIRONMENT_SIZE_LARGE",
    "ENVIRONMENT_SIZE_EXTRA_LARGE",
  ]

  reserved_env_variables = [
    "AIRFLOW_HOME", "C_FORCE_ROOT", "CONTAINER_NAME", "DAGS_FOLDER", "GCP_PROJECT", "GCS_BUCKET",
    "GKE_CLUSTER_NAME", "SQL_DATABASE", "SQL_INSTANCE", "SQL_PASSWORD", "SQL_PROJECT", "SQL_REGION", "SQL_USER",
  ]

  # Maintenance window: Composer needs >= 12 hours per week and >= 4 hours per slot.
  mw_recurrence = try(local.maintenance_window.recurrence, "")
  mw_slots_per_week = (
    can(regex("^FREQ=DAILY$", local.mw_recurrence)) ? 7 :
    try(length(distinct(split(",", regex("^FREQ=WEEKLY;BYDAY=((?:SU|MO|TU|WE|TH|FR|SA)(?:,(?:SU|MO|TU|WE|TH|FR|SA))*)$", local.mw_recurrence)[0]))), 0)
  )
  mw_required_minutes = local.mw_slots_per_week > 0 ? max(240, ceil(720 / local.mw_slots_per_week)) : 240
  mw_times_valid = (
    can(formatdate("YYYYMMDDhhmm", local.maintenance_window.start_time)) &&
    can(formatdate("YYYYMMDDhhmm", local.maintenance_window.end_time))
  )
  # formatdate keeps each timestamp's own offset, so durations are only compared when both
  # timestamps use the same offset (the API still validates the rest).
  mw_same_offset = try(
    regex("(Z|[+-][0-9]{2}:[0-9]{2})$", local.maintenance_window.start_time)[0] == regex("(Z|[+-][0-9]{2}:[0-9]{2})$", local.maintenance_window.end_time)[0],
    false,
  )
  mw_long_enough = try(
    tonumber(formatdate("YYYYMMDDhhmm", timeadd(local.maintenance_window.start_time, "${local.mw_required_minutes}m"))) <=
    tonumber(formatdate("YYYYMMDDhhmm", timeadd(local.maintenance_window.end_time, "0m"))),
    false,
  )

  triggerer_count     = try(local.workloads.triggerer.count, 0)
  dag_processor_count = try(local.workloads.dag_processor.count, null)

  validation_checks = [
    # ── Composer environment on/off ───────────────────────────────────
    {
      ok      = try(var.config.create_composer_environment, null) == null || can(tobool(var.config.create_composer_environment))
      message = "create_composer_environment must be true or false; got ${jsonencode(try(var.config.create_composer_environment, null))}."
    },
    {
      ok      = try(var.global_config.create_composer_environment, null) == null || can(tobool(var.global_config.create_composer_environment))
      message = "The global create_composer_environment must be true or false; got ${jsonencode(try(var.global_config.create_composer_environment, null))}."
    },

    # ── Composer 2 settings that Composer 3 rejects or ignores ─────────
    {
      ok      = try(var.config.private_environment, null) == null
      message = "private_environment is Composer 2 configuration; the provider rejects private_environment_config for Composer 3. Use enable_private_environment: true (and optionally enable_private_builds_only) instead."
    },
    {
      ok      = try(var.config.master_authorized_networks, null) == null
      message = "master_authorized_networks is Composer 2 configuration; the provider rejects it for Composer 3. To restrict who can reach the Airflow UI use web_server_network_access_control."
    },
    {
      ok      = length(setintersection(try(keys(var.config.network), []), ["pods_range_name", "pods_cidr", "services_range_name", "services_cidr"])) == 0
      message = "network.pods_* and network.services_* are Composer 2 GKE secondary ranges and are not used by Composer 3. Remove them; the subnet only needs its primary range."
    },
    {
      ok      = try(var.config.data_retention.task_logs_retention_config, null) == null
      message = "data_retention.task_logs_retention_config is not supported for Composer 3 environments. Remove it."
    },

    # ── Identity & sizing ─────────────────────────────────────────────
    {
      ok      = local.project_id != null
      message = "No project_id: set project_id at the top of the YAML file or in this environment."
    },
    {
      ok      = contains(local.allowed_environment_sizes, local.environment_size)
      message = "environment_size must be one of ${join(", ", local.allowed_environment_sizes)}; got ${jsonencode(local.environment_size)}."
    },
    {
      ok      = local.resilience_mode == null || try(contains(["STANDARD_RESILIENCE", "HIGH_RESILIENCE"], local.resilience_mode), false)
      message = "resilience_mode must be STANDARD_RESILIENCE or HIGH_RESILIENCE; got ${jsonencode(local.resilience_mode)}."
    },
    {
      ok      = can(regex("^composer-3-airflow-[0-9]+(\\.[0-9]+(\\.[0-9]+)?)?(-build\\.[0-9]+)?$", local.software_config.image_version))
      message = "software_config.image_version must be a Composer 3 image such as composer-3-airflow-2, composer-3-airflow-2.11.1 or composer-3-airflow-2.11.1-build.19; got ${jsonencode(local.software_config.image_version)}. Existing Composer 2 environments cannot be upgraded to Composer 3 in place."
    },
    {
      ok = alltrue([
        for k, v in local.labels : can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) && can(regex("^[a-z0-9_-]{0,63}$", v))
      ])
      message = "labels must use lowercase keys and values (letters, digits, '_' and '-', max 63 characters; keys start with a letter)."
    },

    # ── Networking ────────────────────────────────────────────────────
    {
      ok      = !(try(var.config.network.create, null) == true && local.network_uses_existing)
      message = "network.create: true cannot be combined with existing_network, existing_subnetwork or existing_network_attachment. Remove create (or set it to false) to use existing networking."
    },
    {
      ok      = (local.network.existing_network == null) == (local.network.existing_subnetwork == null)
      message = "network.existing_network and network.existing_subnetwork must be set together."
    },
    {
      ok      = local.network.existing_network_attachment == null || local.network.existing_network == null
      message = "network.existing_network_attachment cannot be combined with existing_network / existing_subnetwork: Composer 3 connects either through a network attachment or through a network + subnetwork."
    },
    {
      ok      = try(!local.network.enable_cloud_nat || local.network.create, false)
      message = "network.enable_cloud_nat only applies to a VPC created by this module (network.create: true). Configure Cloud NAT on the existing network instead."
    },
    {
      ok      = !local.network.create || can(cidrhost(local.network.subnetwork_cidr, 0))
      message = "network.subnetwork_cidr must be a valid IPv4 CIDR block; got ${jsonencode(local.network.subnetwork_cidr)}."
    },
    {
      ok      = local.network.composer_internal_ipv4_cidr_block == null || try(can(cidrhost(local.network.composer_internal_ipv4_cidr_block, 0)) && split("/", local.network.composer_internal_ipv4_cidr_block)[1] == "20", false)
      message = "network.composer_internal_ipv4_cidr_block must be an IPv4 CIDR block of size /20; got ${jsonencode(local.network.composer_internal_ipv4_cidr_block)}."
    },
    {
      ok      = !local.web_server_access_control_enabled || length(local.web_server_allowed_ip_ranges) > 0
      message = "web_server_network_access_control needs at least one entry in allowed_ip_ranges. Omit the whole block to allow access from all IP addresses."
    },
    {
      ok      = alltrue([for r in local.web_server_allowed_ip_ranges : can(regex("^[0-9a-fA-F:.]+(/[0-9]{1,3})?$", r.value))])
      message = "Each web_server_network_access_control.allowed_ip_ranges entry needs a value that is an IP address or CIDR range, e.g. 203.0.113.0/24."
    },

    # ── Service account ───────────────────────────────────────────────
    {
      ok      = local.service_account.create || local.service_account.existing_email != null
      message = "service_account.create is false but service_account.existing_email is not set."
    },
    {
      ok      = !(try(var.config.service_account.create, null) == true && local.service_account.existing_email != null)
      message = "service_account.create: true cannot be combined with service_account.existing_email."
    },
    {
      ok      = !local.service_account.create || try(contains(local.service_account.roles, "roles/composer.worker"), false)
      message = "service_account.roles must include roles/composer.worker when the module creates the service account; Composer requires it on the environment's service account."
    },

    # ── Software ──────────────────────────────────────────────────────
    {
      ok      = local.software_config.web_server_plugins_mode == null || try(contains(["ENABLED", "DISABLED"], local.software_config.web_server_plugins_mode), false)
      message = "software_config.web_server_plugins_mode must be ENABLED or DISABLED; got ${jsonencode(local.software_config.web_server_plugins_mode)}."
    },
    {
      ok      = try(var.config.software_config.cloud_data_lineage_integration, null) == null || can(tobool(var.config.software_config.cloud_data_lineage_integration.enabled))
      message = "software_config.cloud_data_lineage_integration must be a block with enabled: true or false."
    },
    {
      ok      = alltrue([for k in keys(local.software_config.pypi_packages) : lower(k) == k])
      message = "software_config.pypi_packages keys must be lowercase package names."
    },
    {
      ok = alltrue([
        for k in keys(local.software_config.env_variables) :
        can(regex("^[a-zA-Z_][a-zA-Z0-9_]*$", k)) && !contains(local.reserved_env_variables, k) && !can(regex("^AIRFLOW__[A-Z0-9_]+__[A-Z0-9_]+$", k))
      ])
      message = "software_config.env_variables names must match [a-zA-Z_][a-zA-Z0-9_]*, must not be AIRFLOW__SECTION__KEY overrides (use airflow_config_overrides) and must not be reserved: ${join(", ", local.reserved_env_variables)}."
    },
    {
      ok      = alltrue([for k in keys(local.software_config.airflow_config_overrides) : can(regex("^[^-\\[\\].]+-[^=;.]+$", k))])
      message = "software_config.airflow_config_overrides keys use the section-key format with a hyphen (e.g. core-dags_are_paused_at_creation), not section.key."
    },

    # ── Workloads (counts; per-component resources are in workload_checks) ──
    {
      ok      = try(local.workloads.worker.min_count <= local.workloads.worker.max_count, false)
      message = "workloads.worker.min_count (${jsonencode(local.workloads.worker.min_count)}) must not exceed max_count (${jsonencode(local.workloads.worker.max_count)})."
    },
    {
      ok      = try(local.workloads.worker.min_count >= 1 && local.workloads.worker.max_count <= 100, false)
      message = "Workers autoscale between 1 and 100: workloads.worker.min_count must be >= 1 and max_count <= 100."
    },
    {
      ok      = try(local.workloads.scheduler.count >= 1 && local.workloads.scheduler.count <= 3, false)
      message = "workloads.scheduler.count must be between 1 and 3; got ${jsonencode(local.workloads.scheduler.count)}."
    },
    {
      ok      = try(local.triggerer_count >= 0 && local.triggerer_count <= 10, false)
      message = "workloads.triggerer.count must be between 0 and 10; got ${jsonencode(local.triggerer_count)}."
    },
    {
      ok      = local.dag_processor_count == null || try(local.dag_processor_count >= 1 && local.dag_processor_count <= 3, false)
      message = "workloads.dag_processor.count must be between 1 and 3; got ${jsonencode(local.dag_processor_count)}."
    },
    {
      ok      = !local.high_resilience || try(tonumber(local.workloads.scheduler.count) == 2, false)
      message = "HIGH_RESILIENCE environments run exactly 2 schedulers; workloads.scheduler.count is ${jsonencode(local.workloads.scheduler.count)}."
    },
    {
      ok      = !local.high_resilience || try(local.workloads.worker.min_count >= 2, false)
      message = "HIGH_RESILIENCE environments need workloads.worker.min_count >= 2; got ${jsonencode(local.workloads.worker.min_count)}."
    },
    {
      ok      = !local.high_resilience || try(tonumber(local.triggerer_count) == 0 || local.triggerer_count >= 2, false)
      message = "HIGH_RESILIENCE environments need 0 or at least 2 triggerers; workloads.triggerer.count is ${jsonencode(local.triggerer_count)}."
    },
    {
      ok      = !local.high_resilience || local.dag_processor_count == null || try(local.dag_processor_count >= 2, false)
      message = "HIGH_RESILIENCE environments need at least 2 DAG processors; workloads.dag_processor.count is ${jsonencode(local.dag_processor_count)}."
    },

    # ── Maintenance window ────────────────────────────────────────────
    {
      ok      = local.maintenance_window == null || (try(local.maintenance_window.start_time, null) != null && try(local.maintenance_window.end_time, null) != null && try(local.maintenance_window.recurrence, null) != null)
      message = "maintenance_window needs start_time, end_time and recurrence."
    },
    {
      ok      = local.maintenance_window == null || local.mw_slots_per_week > 0
      message = "maintenance_window.recurrence must be FREQ=DAILY or FREQ=WEEKLY;BYDAY=<days> using SU,MO,TU,WE,TH,FR,SA; got ${jsonencode(local.mw_recurrence)}."
    },
    {
      ok      = local.maintenance_window == null || local.mw_times_valid
      message = "maintenance_window.start_time and end_time must be RFC 3339 timestamps such as 2024-01-01T02:00:00Z."
    },
    {
      ok      = local.maintenance_window == null || local.mw_slots_per_week == 0 || !local.mw_times_valid || !local.mw_same_offset || local.mw_long_enough
      message = "maintenance_window is too short: Composer needs at least 12 hours of maintenance per week and at least 4 hours per slot. With ${local.mw_slots_per_week} slot(s) per week each slot must last at least ${local.mw_required_minutes / 60} hours (e.g. 4 hours on FR,SA,SU)."
    },

    # ── Encryption ────────────────────────────────────────────────────
    {
      ok      = local.encryption.existing_kms_key == null || can(regex("^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$", local.encryption.existing_kms_key))
      message = "encryption.existing_kms_key must be a full key ID: projects/<project>/locations/<region>/keyRings/<ring>/cryptoKeys/<key>."
    },
    {
      ok      = local.encryption.existing_kms_key == null || try(regex("/locations/([^/]+)/", local.encryption.existing_kms_key)[0] == local.region, false)
      message = "encryption.existing_kms_key must be in the environment's region (${local.region}); Composer does not accept multi-regional or global keys."
    },

    # ── Recovery (scheduled snapshots) ───────────────────────────────
    {
      ok      = try(local.recovery.enabled, false) != true || can(regex("^gs://[^/]+", local.recovery.snapshot_location))
      message = "recovery.snapshot_location must be a Cloud Storage folder such as gs://my-bucket/snapshots when scheduled snapshots are enabled (it is a bucket URI, not a region); got ${jsonencode(try(local.recovery.snapshot_location, null))}."
    },
    {
      ok      = try(local.recovery.enabled, false) != true || can(regex("^UTC([+-](0?[0-9]|1[0-2]))?$", local.recovery.time_zone))
      message = "recovery.time_zone must be a UTC offset from UTC-12 to UTC+12 (e.g. UTC, UTC-06, UTC+01); IANA names such as Europe/London are not accepted. Got ${jsonencode(try(local.recovery.time_zone, null))}."
    },
    {
      ok      = try(local.recovery.enabled, false) != true || try(length(regexall("\\S+", local.recovery.snapshot_creation_schedule)) == 5, false)
      message = "recovery.snapshot_creation_schedule must be a 5-field unix-cron expression such as \"0 3 * * *\"."
    },

    # ── Data retention ────────────────────────────────────────────────
    {
      ok      = local.metadata_retention == null || contains(["RETENTION_MODE_ENABLED", "RETENTION_MODE_DISABLED"], local.metadata_retention_mode)
      message = "data_retention.airflow_metadata_retention_config.retention_mode must be RETENTION_MODE_ENABLED or RETENTION_MODE_DISABLED; got ${jsonencode(local.metadata_retention_mode)}."
    },
    {
      ok      = try(local.metadata_retention.retention_days, null) == null || try(local.metadata_retention.retention_days >= 30 && local.metadata_retention.retention_days <= 730, false)
      message = "data_retention.airflow_metadata_retention_config.retention_days must be between 30 and 730; got ${jsonencode(try(local.metadata_retention.retention_days, null))}."
    },
  ]

  # ── Per-component resource limits (Composer 3 "Scale environments") ─
  # cpu_step "half": multiples of 0.5. "even": 0.5, 1 or a multiple of 2.
  workload_limits = {
    scheduler     = { cpu = [0.5, 2], cpu_step = "half", memory = [local.airflow_major >= 3 ? 2 : 1, 8] }
    triggerer     = { cpu = [0.5, 1], cpu_step = "half", memory = [local.airflow_major >= 3 ? 2 : 1, 8] }
    web_server    = { cpu = [1, 4], cpu_step = "even", memory = [2, 32] }
    worker        = { cpu = [0.5, 32], cpu_step = "even", memory = [local.airflow_major >= 3 ? 2 : 1, 256] }
    dag_processor = { cpu = [0.5, 32], cpu_step = "even", memory = [local.airflow_major >= 3 ? 2 : 1, 256] }
  }

  workload_checks = flatten([
    for name, w in local.workloads : [
      {
        ok = try(
          w.cpu >= local.workload_limits[name].cpu[0] && w.cpu <= local.workload_limits[name].cpu[1] &&
          (local.workload_limits[name].cpu_step == "half" ? floor(w.cpu * 2) == w.cpu * 2 : (contains([0.5, 1], w.cpu) || w.cpu % 2 == 0)),
          false,
        )
        message = "workloads.${name}.cpu must be ${local.workload_limits[name].cpu[0]}-${local.workload_limits[name].cpu[1]} vCPU in steps of ${local.workload_limits[name].cpu_step == "half" ? "0.5" : "0.5, 1 or a multiple of 2"}; got ${jsonencode(w.cpu)}."
      },
      {
        ok      = try(w.memory_gb >= local.workload_limits[name].memory[0] && w.memory_gb <= local.workload_limits[name].memory[1] && floor(w.memory_gb * 4) == w.memory_gb * 4, false)
        message = "workloads.${name}.memory_gb must be ${local.workload_limits[name].memory[0]}-${local.workload_limits[name].memory[1]} GB in steps of 0.25; got ${jsonencode(w.memory_gb)}."
      },
      {
        ok      = try(w.memory_gb / w.cpu >= 1 && w.memory_gb / w.cpu <= 8, false)
        message = "workloads.${name} needs 1-8 GB of memory per vCPU; got ${jsonencode(w.memory_gb)} GB for ${jsonencode(w.cpu)} vCPU."
      },
      {
        ok      = try(w.storage_gb, null) == null || try(w.storage_gb >= 0 && w.storage_gb <= 100 && floor(w.storage_gb) == w.storage_gb, false)
        message = "workloads.${name}.storage_gb must be a whole number from 0 to 100; got ${jsonencode(try(w.storage_gb, null))}."
      },
    ] if w != null
  ])

  validation_errors = [for c in concat(local.validation_checks, local.workload_checks) : c.message if !c.ok]

  validation_error_message = length(local.validation_errors) == 0 ? "" : join("", [
    "Invalid configuration for Composer environment \"${var.environment_key}\"",
    local.create_composer_environment ? "" : " (checked although create_composer_environment is false, so that switching it back on cannot fail)",
    ":\n  - ${join("\n  - ", local.validation_errors)}",
  ])

  # The preconditions test this rather than validation_errors. Terraform 1.2 and 1.3 evaluate
  # what an output precondition's condition references before the output, but not what its
  # error_message references; deriving this from the message makes the message ready in time.
  configuration_valid = local.validation_error_message == ""
}
