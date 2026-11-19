# ============================================================================
# composer-3-settings — provider-less settings resolver
#
# Single source of truth for how one YAML environment entry resolves against
# the global YAML defaults. Used by:
#   * modules/composer-3            (identity, labels, hibernation guard-rails)
#   * scripts/hibernation/resolver  (the shutdown/startup scripts read the
#                                    exact same resolved values, so scripts and
#                                    Terraform can never disagree on names,
#                                    regions, buckets or defaults)
#
# This module declares no providers and no resources, so it can be evaluated
# offline (no credentials, no network) by `terraform apply` on an empty state.
# ============================================================================

locals {
  # ── Identity ─────────────────────────────────────────────────────────
  environment_name = try(var.config.environment_name, var.environment_key)
  project_id       = try(var.config.project_id, var.global_config.project_id)
  region           = try(var.config.region, try(var.global_config.region, "europe-west2"))

  # ── Labels (global merged with per-env; per-env wins) ───────────────
  global_labels = try(var.global_config.labels, {})
  env_labels    = try(var.config.labels, {})
  labels        = merge(local.global_labels, local.env_labels)

  # ── Production detection ────────────────────────────────────────────
  # Explicit labels win: if any of the well-known environment label keys is
  # set, the environment is production only when one of them carries a
  # production value. Without such a label, fall back to the environment
  # name containing a "prod"/"production"/"prd" token (hyphen-delimited, so
  # "preprod" or "product-x" do not match).
  production_label_keys   = ["env", "environment", "tier", "stage"]
  production_label_values = ["prod", "production", "prd"]

  environment_label_values = [
    for k in local.production_label_keys : try(lower(tostring(local.labels[k])), "")
    if try(local.labels[k], null) != null
  ]

  is_production = (
    length(local.environment_label_values) > 0
    ? anytrue([for v in local.environment_label_values : contains(local.production_label_values, v)])
    : can(regex("(^|-)(prod|production|prd)(-|$)", lower(local.environment_name)))
  )

  # ── Values the hibernation scripts need from the rest of the config ─
  image_version = try(var.config.software_config.image_version, null)
  custom_bucket = try(var.config.storage.bucket, null)

  service_account_create = try(var.config.service_account.create, true)
  service_account_name   = try(var.config.service_account.name, "${local.environment_name}-sa")
  service_account_email = (
    local.service_account_create
    ? try("${local.service_account_name}@${local.project_id}.iam.gserviceaccount.com", null)
    : try(var.config.service_account.existing_email, null)
  )

  # ── Hibernation (global → per-env merge, field by field) ────────────
  # Explicit YAML nulls are dropped so they fall through to the next level.
  global_hibernation_raw = try(var.global_config.hibernation, null)
  env_hibernation_raw    = try(var.config.hibernation, null)

  global_hibernation_is_map = local.global_hibernation_raw == null || can(keys(local.global_hibernation_raw))
  env_hibernation_is_map    = local.env_hibernation_raw == null || can(keys(local.env_hibernation_raw))

  global_hibernation = try({ for k, v in local.global_hibernation_raw : k => v if v != null }, {})
  env_hibernation    = try({ for k, v in local.env_hibernation_raw : k => v if v != null }, {})
  hibernation_merged = merge(local.global_hibernation, local.env_hibernation)

  # Raw (unvalidated) values — validated below, normalised in `hibernation`.
  raw_enabled                = try(local.hibernation_merged.enabled, false)
  raw_create_snapshot_bucket = try(local.hibernation_merged.create_snapshot_bucket, true)
  raw_pin_image_version      = try(local.hibernation_merged.pin_image_version, true)
  raw_delete_orphaned_bucket = try(local.hibernation_merged.delete_orphaned_bucket, true)
  raw_retention_count        = try(local.hibernation_merged.snapshot_retention_count, 7)
  raw_orphan_retention_days  = try(local.hibernation_merged.orphaned_bucket_retention_days, 7)

  snapshot_bucket = try(
    local.hibernation_merged.snapshot_bucket,
    "${local.project_id}-composer-snapshots",
    null
  )
  snapshot_bucket_location = try(local.hibernation_merged.snapshot_bucket_location, local.region)
  snapshot_prefix          = trim(try(tostring(local.hibernation_merged.snapshot_prefix), "composer-hibernation"), "/")

  # Default load options: Terraform has already applied PyPI packages, env
  # variables and Airflow overrides from the YAML when the environment is
  # recreated, so by default only the Airflow database and the dags/,
  # plugins/ and data/ folders are restored from the snapshot. This avoids
  # Terraform drift and skips the slow PyPI re-installation.
  default_load_options = {
    skip_pypi_packages_installation    = true
    skip_environment_variables_setting = true
    skip_airflow_overrides_setting     = true
    skip_gcs_data_copying              = false
  }

  raw_load_options = merge(
    local.default_load_options,
    try({ for k, v in local.global_hibernation_raw.load_options : k => v if v != null }, {}),
    try({ for k, v in local.env_hibernation_raw.load_options : k => v if v != null }, {}),
  )

  load_options = {
    for k, v in local.default_load_options :
    k => can(tobool(local.raw_load_options[k])) ? tobool(local.raw_load_options[k]) : v
  }

  enabled = can(tobool(local.raw_enabled)) ? tobool(local.raw_enabled) : false

  # Composer writes each snapshot into its own sub-folder of this location.
  # project/region are part of the path so a shared bucket never mixes up
  # same-named environments from different projects or regions.
  snapshot_location = try(
    "gs://${local.snapshot_bucket}/${local.snapshot_prefix}/${local.project_id}/${local.region}/${local.environment_name}",
    null
  )

  hibernation = {
    enabled                  = local.enabled
    snapshot_bucket          = local.snapshot_bucket
    snapshot_bucket_location = local.snapshot_bucket_location
    create_snapshot_bucket   = can(tobool(local.raw_create_snapshot_bucket)) ? tobool(local.raw_create_snapshot_bucket) : true
    snapshot_prefix          = local.snapshot_prefix
    snapshot_location        = local.snapshot_location
    state_object             = local.snapshot_location == null ? null : "${local.snapshot_location}/hibernation-state.json"
    snapshot_retention_count = can(tonumber(local.raw_retention_count)) ? floor(tonumber(local.raw_retention_count)) : 7
    pin_image_version        = can(tobool(local.raw_pin_image_version)) ? tobool(local.raw_pin_image_version) : true
    delete_orphaned_bucket   = can(tobool(local.raw_delete_orphaned_bucket)) ? tobool(local.raw_delete_orphaned_bucket) : true
    # Days an orphaned environment bucket (and its task logs) is kept before
    # a later shutdown deletes it. 0 = delete right after the shutdown.
    orphaned_bucket_retention_days = can(tonumber(local.raw_orphan_retention_days)) ? floor(tonumber(local.raw_orphan_retention_days)) : 7
    load_options                   = local.load_options
  }

  # ── Validation (surfaced as a precondition in modules/composer-3 and as
  #    a hard stop in the hibernation scripts) ─────────────────────────
  validation_errors = compact(concat(
    [
      local.global_hibernation_is_map ? "" : "global 'hibernation' must be a map of settings",
      local.env_hibernation_is_map ? "" : "environments.${var.environment_key}.hibernation must be a map of settings",
      can(tobool(local.raw_enabled)) ? "" : "hibernation.enabled must be true or false",
      can(tobool(local.raw_create_snapshot_bucket)) ? "" : "hibernation.create_snapshot_bucket must be true or false",
      can(tobool(local.raw_pin_image_version)) ? "" : "hibernation.pin_image_version must be true or false",
      can(tobool(local.raw_delete_orphaned_bucket)) ? "" : "hibernation.delete_orphaned_bucket must be true or false",
      (
        can(tonumber(local.raw_retention_count)) && try(tonumber(local.raw_retention_count) >= 1 && floor(tonumber(local.raw_retention_count)) == tonumber(local.raw_retention_count), false)
        ? "" : "hibernation.snapshot_retention_count must be a whole number >= 1"
      ),
      (
        can(tonumber(local.raw_orphan_retention_days)) && try(tonumber(local.raw_orphan_retention_days) >= 0 && floor(tonumber(local.raw_orphan_retention_days)) == tonumber(local.raw_orphan_retention_days), false)
        ? "" : "hibernation.orphaned_bucket_retention_days must be a whole number >= 0"
      ),
    ],
    [
      for k in keys(local.raw_load_options) :
      contains(keys(local.default_load_options), k)
      ? (can(tobool(local.raw_load_options[k])) ? "" : "hibernation.load_options.${k} must be true or false")
      : "hibernation.load_options.${k} is not a supported option (allowed: ${join(", ", keys(local.default_load_options))})"
    ],
    local.enabled ? [
      local.is_production ? "hibernation must not be enabled for production environment '${local.environment_name}' (detected from its env/environment/tier/stage label or its name). Hibernation is for non-production environments only." : "",
      local.project_id == null ? "hibernation requires project_id (global or per-environment)" : "",
      can(regex("^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$", local.snapshot_bucket)) ? "" : "hibernation.snapshot_bucket '${coalesce(local.snapshot_bucket, "<null>")}' is not a valid bucket name (3-63 chars: lowercase letters, digits, '-' or '_'; no dots)",
      can(regex("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$", local.snapshot_prefix)) ? "" : "hibernation.snapshot_prefix '${local.snapshot_prefix}' must be a non-empty path of [A-Za-z0-9._-] segments",
      local.custom_bucket != null && local.custom_bucket == local.snapshot_bucket ? "hibernation.snapshot_bucket must differ from storage.bucket (the environment's own bucket)" : "",
    ] : [],
  ))
}
