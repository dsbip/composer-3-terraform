# Plans the sample configs against the REAL google / google-beta providers instead of mocks,
# so the provider's own plan-time rules run, including its Composer 3 field policy (e.g.
# "dag_processor should only be used in Composer 3", "private_environment_config should not
# be used in Composer 3"). Mock providers skip those rules.
#
# Runs offline without GCP credentials: the access token is fake, only `plan` is used, and the
# one data source read at plan time (google_project) is overridden. Needs `terraform init`.

provider "google" {
  project      = "offline-test-project"
  region       = "europe-west2"
  access_token = "offline-fake-token"
}

provider "google-beta" {
  project      = "offline-test-project"
  region       = "europe-west2"
  access_token = "offline-fake-token"
}

run "basic_config" {
  command = plan

  variables {
    config_file = "configs/basic.yaml"
  }

  override_data {
    target = module.composer["composer-basic"].data.google_project.this
    values = { number = "123456789012" }
  }
}

run "development_config" {
  command = plan

  variables {
    config_file = "configs/development.yaml"
  }

  override_data {
    target = module.composer["composer-dev"].data.google_project.this
    values = { number = "123456789012" }
  }
}

run "production_config" {
  command = plan

  variables {
    config_file = "configs/production.yaml"
  }

  override_data {
    target = module.composer["composer-prod"].data.google_project.this
    values = { number = "123456789012" }
  }
}

run "private_ip_config" {
  command = plan

  variables {
    config_file = "configs/private-ip.yaml"
  }

  override_data {
    target = module.composer["composer-private"].data.google_project.this
    values = { number = "123456789012" }
  }
}

run "multi_environment_config" {
  command = plan

  variables {
    config_file = "configs/multi-environment.yaml"
  }

  override_data {
    target = module.composer["composer-dev"].data.google_project.this
    values = { number = "123456789012" }
  }

  override_data {
    target = module.composer["composer-staging"].data.google_project.this
    values = { number = "123456789012" }
  }

  override_data {
    target = module.composer["composer-prod"].data.google_project.this
    values = { number = "123456789012" }
  }
}

# One environment switched off (only its supporting infrastructure is planned), one on.
run "composer_environment_switched_off" {
  command = plan

  variables {
    config_file = "tests/fixtures/composer-switched-off.yaml"
  }

  override_data {
    target = module.composer["composer-off"].data.google_project.this
    values = { number = "123456789012" }
  }

  override_data {
    target = module.composer["composer-on"].data.google_project.this
    values = { number = "123456789012" }
  }

  assert {
    condition     = output.environments["composer-off"].composer_environment_created == false && output.environments["composer-on"].composer_environment_created == true
    error_message = "Only composer-on should get a Composer environment."
  }
}

# Composer 3-only fields not used by the sample configs.
run "composer_3_only_fields" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    environment_key = "provider-check"
    global_config   = { project_id = "offline-test-project", region = "europe-west2" }
    config = {
      enable_private_environment = true
      enable_private_builds_only = true
      network = {
        existing_network_attachment       = "projects/offline-test-project/regions/europe-west2/networkAttachments/composer"
        composer_internal_ipv4_cidr_block = "100.64.128.0/20"
      }
      software_config = {
        web_server_plugins_mode        = "DISABLED"
        cloud_data_lineage_integration = { enabled = true }
      }
      workloads = {
        dag_processor = { count = 1 }
      }
    }
  }

  override_data {
    target = data.google_project.this
    values = { number = "123456789012" }
  }
}
