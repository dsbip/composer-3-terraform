# Shared, provider-less resolution of identity, labels and hibernation
# settings. scripts/hibernation evaluates the very same module offline, so the
# shutdown/startup scripts and Terraform always agree on resolved values.
module "settings" {
  source = "../composer-3-settings"

  environment_key = var.environment_key
  config          = var.config
  global_config   = var.global_config
}
