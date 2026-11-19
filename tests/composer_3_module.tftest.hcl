# ============================================================================
# Direct tests of modules/composer-3 (module { source = ... } in every run).
#
# Root-level runs cannot put resources inside child modules into
# expect_failures, so the hibernation guard-rail — the precondition on
# google_composer_environment.this, fed by modules/composer-3-settings — and
# the fallback_image_version validation are exercised here, one environment at
# a time, with the same three inputs the root module passes.
# ============================================================================

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  environment_key = "composer-dev"
  config          = {}
  global_config = {
    project_id  = "hib-test-project"
    region      = "europe-west2"
    labels      = { managed_by = "terraform" }
    enable_apis = true
    apis        = []
    hibernation = null
  }
}

# ── Production guard: plan must fail ────────────────────────────────────────

run "rejects_hibernation_with_env_production_label" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels      = { env = "production" }
      hibernation = { enabled = true }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_hibernation_with_environment_prod_label" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels      = { environment = "prod" }
      hibernation = { enabled = true }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_hibernation_on_prod_name_without_env_label" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    environment_key = "composer-prod"
    config = {
      hibernation = { enabled = true }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_hibernation_on_prod_environment_name_override" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    environment_key = "composer-main"
    config = {
      environment_name = "prd-composer"
      hibernation      = { enabled = true }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_hibernation_when_any_env_label_is_production" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels      = { env = "dev", stage = "PRD" }
      hibernation = { enabled = true }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_global_hibernation_on_global_production_label" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    environment_key = "composer-analytics"
    config          = {}
    global_config = {
      project_id  = "hib-test-project"
      region      = "europe-west2"
      labels      = { tier = "production" }
      enable_apis = true
      apis        = []
      hibernation = { enabled = true }
    }
  }

  expect_failures = [google_composer_environment.this]
}

# ── Invalid settings: plan must fail ────────────────────────────────────────

run "rejects_invalid_enabled_value" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels      = { env = "dev" }
      hibernation = { enabled = "maybe" }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_zero_snapshot_retention_count" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels      = { env = "dev" }
      hibernation = { enabled = true, snapshot_retention_count = 0 }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_negative_orphaned_bucket_retention_days" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels      = { env = "dev" }
      hibernation = { enabled = true, orphaned_bucket_retention_days = -1 }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_unknown_load_option" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels = { env = "dev" }
      hibernation = {
        enabled      = true
        load_options = { skip_everything = true }
      }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_snapshot_bucket_equal_to_storage_bucket" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels  = { env = "dev" }
      storage = { bucket = "hib-test-project-composer-dev-data" }
      hibernation = {
        enabled         = true
        snapshot_bucket = "hib-test-project-composer-dev-data"
      }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_invalid_snapshot_bucket_name" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels      = { env = "dev" }
      hibernation = { enabled = true, snapshot_bucket = "Bad_Bucket!" }
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_hibernation_that_is_not_a_map" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels      = { env = "dev" }
      hibernation = "yes"
    }
  }

  expect_failures = [google_composer_environment.this]
}

run "rejects_invalid_global_setting_even_when_disabled" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = { labels = { env = "dev" } }
    global_config = {
      project_id  = "hib-test-project"
      region      = "europe-west2"
      labels      = {}
      enable_apis = true
      apis        = []
      hibernation = { enabled = false, snapshot_retention_count = 0 }
    }
  }

  expect_failures = [google_composer_environment.this]
}

# ── Allowed: plan must succeed ──────────────────────────────────────────────

run "allows_hibernation_with_dev_label" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels      = { env = "dev" }
      hibernation = { enabled = true }
    }
  }

  assert {
    condition     = output.hibernation.enabled == true
    error_message = "hibernation should be enabled for a dev environment."
  }

  assert {
    condition = output.hibernation == {
      enabled                        = true
      snapshot_bucket                = "hib-test-project-composer-snapshots"
      snapshot_bucket_location       = "europe-west2"
      create_snapshot_bucket         = true
      snapshot_prefix                = "composer-hibernation"
      snapshot_location              = "gs://hib-test-project-composer-snapshots/composer-hibernation/hib-test-project/europe-west2/composer-dev"
      state_object                   = "gs://hib-test-project-composer-snapshots/composer-hibernation/hib-test-project/europe-west2/composer-dev/hibernation-state.json"
      snapshot_retention_count       = 7
      pin_image_version              = true
      delete_orphaned_bucket         = true
      orphaned_bucket_retention_days = 7
      load_options = {
        skip_pypi_packages_installation    = true
        skip_environment_variables_setting = true
        skip_airflow_overrides_setting     = true
        skip_gcs_data_copying              = false
      }
    }
    error_message = "Unexpected resolved hibernation settings: ${jsonencode(output.hibernation)}"
  }
}

run "allows_dev_label_even_when_name_contains_prod" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    environment_key = "composer-prod-replica"
    config = {
      labels      = { env = "test" }
      hibernation = { enabled = true }
    }
  }

  assert {
    condition     = output.hibernation.enabled == true
    error_message = "Explicit env: test label must win over the 'prod' token in the name."
  }

  assert {
    condition     = output.environment_name == "composer-prod-replica"
    error_message = "Environment name should default to the key."
  }
}

run "allows_per_env_dev_label_over_global_production_label" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      labels = { env = "dev" }
    }
    global_config = {
      project_id  = "hib-test-project"
      region      = "europe-west2"
      labels      = { env = "production" }
      enable_apis = true
      apis        = []
      hibernation = { enabled = true }
    }
  }

  assert {
    condition     = output.hibernation.enabled == true
    error_message = "Per-env env: dev must override the global env: production label."
  }
}

run "allows_preprod_name_without_label" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    environment_key = "composer-preprod"
    config = {
      hibernation = { enabled = true }
    }
  }

  assert {
    condition     = output.hibernation.enabled == true
    error_message = "'preprod' is not a production token."
  }
}

run "allows_disabled_hibernation_on_production" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    environment_key = "composer-prod"
    config = {
      labels      = { env = "production" }
      hibernation = { enabled = false }
    }
    global_config = {
      project_id  = "hib-test-project"
      region      = "europe-west2"
      labels      = {}
      enable_apis = true
      apis        = []
      hibernation = { enabled = true }
    }
  }

  assert {
    condition     = output.hibernation.enabled == false
    error_message = "Per-env enabled: false must override the global enabled: true."
  }
}

# ── fallback_image_version ──────────────────────────────────────────────────

run "rejects_composer_2_fallback_image_version" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    fallback_image_version = "composer-2-airflow-2.5.0"
  }

  expect_failures = [var.fallback_image_version]
}

run "fallback_image_version_used_when_yaml_has_none" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    fallback_image_version = "composer-3-airflow-2.10.5-build.3"
  }

  assert {
    condition     = output.image_version == "composer-3-airflow-2.10.5-build.3"
    error_message = "The fallback image version should reach the Composer resource."
  }
}

run "fallback_image_version_used_for_explicit_null_image_version" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      software_config = { image_version = null }
    }
    fallback_image_version = "composer-3-airflow-2.10.5"
  }

  assert {
    condition     = output.image_version == "composer-3-airflow-2.10.5"
    error_message = "image_version: null must fall back to fallback_image_version."
  }
}

run "yaml_image_version_wins_over_fallback" {
  command = plan
  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      software_config = { image_version = "composer-3-airflow-2.9.3" }
    }
    fallback_image_version = "composer-3-airflow-2.10.5"
  }

  assert {
    condition     = output.image_version == "composer-3-airflow-2.9.3"
    error_message = "An explicit YAML image_version must never be overridden by the fallback."
  }
}
