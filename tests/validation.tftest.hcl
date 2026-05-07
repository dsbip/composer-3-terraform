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
