mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  config_file = "configs/production.yaml"
}

run "production_config_plans_successfully" {
  command = plan

  assert {
    condition     = length(module.composer) == 1
    error_message = "Production config should create exactly 1 environment."
  }

  assert {
    condition     = module.composer["composer-prod"].environment_name == "composer-prod"
    error_message = "Environment name should be 'composer-prod'."
  }

  assert {
    condition     = module.composer["composer-prod"].image_version == "composer-3-airflow-2.11.1"
    error_message = "Production should use the image_version pinned in configs/production.yaml."
  }
}
