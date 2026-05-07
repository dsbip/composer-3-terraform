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
}
