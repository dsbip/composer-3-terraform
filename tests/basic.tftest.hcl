mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  config_file = "configs/basic.yaml"
}

run "basic_single_env_plans_successfully" {
  command = plan

  assert {
    condition     = length(module.composer) == 1
    error_message = "Basic config should create exactly 1 environment."
  }

  assert {
    condition     = module.composer["composer-basic"].environment_name == "composer-basic"
    error_message = "Environment name should default to the YAML key 'composer-basic'."
  }

  assert {
    condition     = module.composer["composer-basic"].image_version == "composer-3-airflow-2"
    error_message = "An empty environment must default to a Composer 3 image; without one the API creates a Composer 2 environment."
  }
}
