mock_provider "google" {}
mock_provider "google-beta" {}

run "rejects_non_yaml_config_file" {
  command = plan

  variables {
    config_file = "configs/basic.json"
  }

  expect_failures = [var.config_file]
}

run "development_config_plans_successfully" {
  command = plan

  variables {
    config_file = "configs/development.yaml"
  }

  assert {
    condition     = module.composer["composer-dev"].environment_name == "composer-dev"
    error_message = "Environment name should be 'composer-dev'."
  }
}

run "private_ip_config_plans_successfully" {
  command = plan

  variables {
    config_file = "configs/private-ip.yaml"
  }

  assert {
    condition     = module.composer["composer-private"].environment_name == "composer-private"
    error_message = "Environment name should be 'composer-private'."
  }
}

run "multi_environment_creates_three_envs" {
  command = plan

  variables {
    config_file = "configs/multi-environment.yaml"
  }

  assert {
    condition     = length(module.composer) == 3
    error_message = "Multi-environment config should create exactly 3 environments."
  }
}

run "environment_without_value_uses_defaults" {
  command = plan

  variables {
    config_file = "tests/fixtures/null-environment.yaml"
  }

  assert {
    condition     = module.composer["composer-null"].image_version == "composer-3-airflow-2"
    error_message = "An environment key with no value (null) should behave like {}."
  }
}

run "empty_environments_map_plans_nothing" {
  command = plan

  variables {
    config_file = "tests/fixtures/no-environments.yaml"
  }

  assert {
    condition     = length(module.composer) == 0
    error_message = "environments: with no entries should plan zero environments (used to tear everything down)."
  }
}

run "rejects_resource_name_collisions" {
  command = plan

  variables {
    config_file = "tests/fixtures/duplicate-names.yaml"
  }

  expect_failures = [output.environments]
}
