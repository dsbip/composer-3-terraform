# ============================================================================
# Root-module tests for hibernation: resolved settings per environment, the
# fallback_image_versions input and the root `environments` output, for the
# hibernation test fixture and every config that uses hibernation.
#
# The guard-rails (precondition failures) live in composer_3_module.tftest.hcl:
# expect_failures cannot reference resources inside child modules from here.
# ============================================================================

mock_provider "google" {}

# image_version is Optional+Computed. The mocked default below only fills it
# when the configuration leaves it null, so at plan time:
#   configured (YAML or fallback)  -> that exact value
#   null (GCP chooses)             -> "provider-chosen-image"
mock_provider "google-beta" {
  override_during = plan

  mock_resource "google_composer_environment" {
    defaults = {
      config = {
        software_config = {
          image_version = "provider-chosen-image"
        }
      }
    }
  }
}

variables {
  config_file = "tests/hibernation/fixtures/hibernation.yaml"
}

# ── tests/hibernation/fixtures/hibernation.yaml ─────────────────────────────

run "fixture_resolves_hibernation_settings" {
  command = plan

  assert {
    condition     = length(module.composer) == 3
    error_message = "The fixture defines exactly 3 environments."
  }

  assert {
    condition = module.composer["composer-dev"].hibernation == {
      enabled                        = true
      snapshot_bucket                = "hib-test-project-composer-snapshots"
      snapshot_bucket_location       = "europe-west2"
      create_snapshot_bucket         = true
      snapshot_prefix                = "composer-hibernation"
      snapshot_location              = "gs://hib-test-project-composer-snapshots/composer-hibernation/hib-test-project/europe-west2/composer-dev"
      state_object                   = "gs://hib-test-project-composer-snapshots/composer-hibernation/hib-test-project/europe-west2/composer-dev/hibernation-state.json"
      snapshot_retention_count       = 2
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
    error_message = "composer-dev resolved hibernation settings are wrong: ${jsonencode(module.composer["composer-dev"].hibernation)}"
  }

  # composer-test: custom storage.bucket does not change the snapshot bucket.
  assert {
    condition     = module.composer["composer-test"].hibernation.enabled == true
    error_message = "composer-test inherits enabled: true from the global block."
  }

  assert {
    condition     = module.composer["composer-test"].hibernation.snapshot_retention_count == 2
    error_message = "composer-test inherits the global snapshot_retention_count of 2."
  }

  assert {
    condition     = module.composer["composer-test"].hibernation.snapshot_bucket == "hib-test-project-composer-snapshots"
    error_message = "Default snapshot bucket must be '<project>-composer-snapshots', independent of storage.bucket."
  }

  assert {
    condition     = module.composer["composer-test"].hibernation.snapshot_location == "gs://hib-test-project-composer-snapshots/composer-hibernation/hib-test-project/europe-west2/composer-test"
    error_message = "snapshot_location must be gs://<bucket>/composer-hibernation/<project>/<region>/<env-name>."
  }

  assert {
    condition     = module.composer["composer-test"].hibernation.state_object == "gs://hib-test-project-composer-snapshots/composer-hibernation/hib-test-project/europe-west2/composer-test/hibernation-state.json"
    error_message = "state_object must be <snapshot_location>/hibernation-state.json."
  }

  assert {
    condition     = module.composer["composer-test"].gcs_bucket == "hib-test-project-composer-test-data"
    error_message = "composer-test must use its custom storage.bucket."
  }

  # composer-prod: per-env enabled: false wins over the global enabled: true;
  # every other global value is still merged in.
  assert {
    condition     = module.composer["composer-prod"].hibernation.enabled == false
    error_message = "composer-prod must not hibernate."
  }

  assert {
    condition     = module.composer["composer-prod"].hibernation.snapshot_retention_count == 2
    error_message = "Global snapshot_retention_count is merged even when hibernation is disabled."
  }

  assert {
    condition     = module.composer["composer-prod"].hibernation.orphaned_bucket_retention_days == 7
    error_message = "orphaned_bucket_retention_days defaults to 7."
  }
}

run "fixture_without_fallback_lets_gcp_choose_image" {
  command = plan

  assert {
    condition     = module.composer["composer-dev"].image_version == "provider-chosen-image"
    error_message = "Without a fallback, composer-dev must send image_version = null (GCP chooses)."
  }

  assert {
    condition     = module.composer["composer-test"].image_version == "composer-3-airflow-2.9.3"
    error_message = "composer-test must use its YAML image_version."
  }
}

run "fallback_image_versions_fill_only_unset_image_versions" {
  command = plan

  variables {
    fallback_image_versions = {
      composer-dev = "composer-3-airflow-2.10.5"
    }
  }

  assert {
    condition     = module.composer["composer-dev"].image_version == "composer-3-airflow-2.10.5"
    error_message = "The fallback must reach composer-dev's Composer resource (its YAML has no image_version)."
  }

  assert {
    condition     = module.composer["composer-test"].image_version == "composer-3-airflow-2.9.3"
    error_message = "composer-test keeps its YAML image_version."
  }

  assert {
    condition     = module.composer["composer-prod"].image_version == "provider-chosen-image"
    error_message = "composer-prod has no fallback entry, so GCP chooses its image."
  }

  assert {
    condition     = output.environments["composer-dev"].image_version == "composer-3-airflow-2.10.5"
    error_message = "The root environments output must report the fallback image version."
  }
}

run "fallback_image_versions_never_override_yaml_image_version" {
  command = plan

  variables {
    fallback_image_versions = {
      composer-dev  = "composer-3-airflow-2.10.5"
      composer-test = "composer-3-airflow-2.10.5"
      composer-prod = "composer-3-airflow-2.10.5"
    }
  }

  assert {
    condition     = module.composer["composer-test"].image_version == "composer-3-airflow-2.9.3"
    error_message = "An explicit YAML image_version must win over fallback_image_versions."
  }

  assert {
    condition     = module.composer["composer-dev"].image_version == "composer-3-airflow-2.10.5"
    error_message = "composer-dev must take its fallback."
  }

  assert {
    condition     = module.composer["composer-prod"].image_version == "composer-3-airflow-2.10.5"
    error_message = "The fallback applies to any key in the map whose YAML has no image_version."
  }
}

run "root_output_environments_exposes_hibernation" {
  command = plan

  assert {
    condition     = output.environments["composer-dev"].hibernation_enabled == true
    error_message = "environments output must include hibernation_enabled."
  }

  assert {
    condition     = output.environments["composer-dev"].snapshot_location == "gs://hib-test-project-composer-snapshots/composer-hibernation/hib-test-project/europe-west2/composer-dev"
    error_message = "environments output must include snapshot_location."
  }

  assert {
    condition     = output.environments["composer-test"].snapshot_location == "gs://hib-test-project-composer-snapshots/composer-hibernation/hib-test-project/europe-west2/composer-test"
    error_message = "environments output must include composer-test's snapshot_location."
  }

  assert {
    condition     = output.environments["composer-prod"].hibernation_enabled == false
    error_message = "composer-prod must report hibernation_enabled = false."
  }

  assert {
    condition     = output.environments["composer-prod"].snapshot_location == null
    error_message = "snapshot_location must be null when hibernation is disabled."
  }

  assert {
    condition     = output.environments["composer-dev"].environment_name == "composer-dev"
    error_message = "environment_name is still part of the output."
  }
}

# ── configs/*.yaml ──────────────────────────────────────────────────────────

run "hibernation_example_config_plans_successfully" {
  command = plan

  variables {
    config_file = "configs/hibernation.yaml"
  }

  assert {
    condition     = length(module.composer) == 3
    error_message = "configs/hibernation.yaml defines 3 environments."
  }

  assert {
    condition = module.composer["composer-dev"].hibernation == {
      enabled                        = true
      snapshot_bucket                = "my-gcp-project-composer-snapshots"
      snapshot_bucket_location       = "europe-west2"
      create_snapshot_bucket         = true
      snapshot_prefix                = "composer-hibernation"
      snapshot_location              = "gs://my-gcp-project-composer-snapshots/composer-hibernation/my-gcp-project/europe-west2/composer-dev"
      state_object                   = "gs://my-gcp-project-composer-snapshots/composer-hibernation/my-gcp-project/europe-west2/composer-dev/hibernation-state.json"
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
    error_message = "configs/hibernation.yaml must spell out exactly the defaults (explicit nulls fall through): ${jsonencode(module.composer["composer-dev"].hibernation)}"
  }

  assert {
    condition     = module.composer["composer-dev"].image_version == "composer-3-airflow-2.10.5"
    error_message = "composer-dev pins image_version composer-3-airflow-2.10.5."
  }

  assert {
    condition     = module.composer["composer-qa"].hibernation.enabled && module.composer["composer-qa"].hibernation.snapshot_retention_count == 3
    error_message = "composer-qa hibernates and overrides snapshot_retention_count to 3."
  }

  assert {
    condition     = module.composer["composer-qa"].gcs_bucket == "my-gcp-project-composer-qa"
    error_message = "composer-qa uses its persistent custom bucket."
  }

  assert {
    condition     = module.composer["composer-qa"].image_version == "provider-chosen-image"
    error_message = "composer-qa leaves image_version to GCP (pin_image_version handles restores)."
  }

  assert {
    condition     = module.composer["composer-prod"].hibernation.enabled == false
    error_message = "composer-prod must never hibernate."
  }

  assert {
    condition     = output.environments["composer-qa"].snapshot_location == "gs://my-gcp-project-composer-snapshots/composer-hibernation/my-gcp-project/europe-west2/composer-qa"
    error_message = "composer-qa snapshot_location is wrong."
  }
}

run "development_config_enables_hibernation" {
  command = plan

  variables {
    config_file = "configs/development.yaml"
  }

  assert {
    condition     = module.composer["composer-dev"].hibernation.enabled == true
    error_message = "configs/development.yaml enables hibernation for composer-dev."
  }

  assert {
    condition     = module.composer["composer-dev"].hibernation.snapshot_location == "gs://my-dev-project-composer-snapshots/composer-hibernation/my-dev-project/europe-west2/composer-dev"
    error_message = "composer-dev snapshot_location is wrong."
  }

  assert {
    condition     = module.composer["composer-dev"].hibernation.snapshot_retention_count == 7
    error_message = "composer-dev keeps the default retention."
  }
}

run "multi_environment_config_hibernates_only_non_prod" {
  command = plan

  variables {
    config_file = "configs/multi-environment.yaml"
  }

  assert {
    condition     = module.composer["composer-dev"].hibernation.enabled && module.composer["composer-staging"].hibernation.enabled
    error_message = "composer-dev and composer-staging opt in to hibernation."
  }

  assert {
    condition     = module.composer["composer-prod"].hibernation.enabled == false
    error_message = "composer-prod inherits the global enabled: false."
  }

  assert {
    condition     = output.environments["composer-staging"].snapshot_location == "gs://my-gcp-project-composer-snapshots/composer-hibernation/my-gcp-project/europe-west2/composer-staging"
    error_message = "composer-staging snapshot_location is wrong."
  }
}

run "configs_without_hibernation_keep_it_disabled" {
  command = plan

  variables {
    config_file = "configs/production.yaml"
  }

  assert {
    condition     = module.composer["composer-prod"].hibernation.enabled == false
    error_message = "Hibernation is disabled by default."
  }

  assert {
    condition     = output.environments["composer-prod"].snapshot_location == null
    error_message = "No snapshot_location without hibernation."
  }

  assert {
    condition     = module.composer["composer-prod"].image_version == "composer-3-airflow-2.10.2"
    error_message = "production.yaml image_version must reach the resource."
  }
}
