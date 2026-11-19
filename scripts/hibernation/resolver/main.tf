# ============================================================================
# Offline settings resolver for scripts/hibernation.
#
# Reads the same YAML the root module reads and resolves every environment
# through modules/composer-3-settings — the module modules/composer-3 uses —
# so the scripts see exactly the values Terraform will use. No providers, no
# backend, no network: `terraform init -backend=false` + `terraform apply`
# on a throw-away local state, then `terraform output -json environments`.
# The scripts point the local backend at a temp file with
#   terraform init -backend-config="path=<tmp>/resolver.tfstate"
# and set TF_DATA_DIR to a temp dir, so nothing is written into the repo.
#
# The global_config block below MUST stay identical to the one in /main.tf.
# ============================================================================

terraform {
  required_version = ">= 1.2.0"

  backend "local" {}
}

variable "config_file" {
  description = "Absolute path to the YAML configuration file"
  type        = string
}

locals {
  raw_config = yamldecode(file(var.config_file))

  global_config = {
    project_id  = try(local.raw_config.project_id, null)
    region      = try(local.raw_config.region, "europe-west2")
    labels      = try(local.raw_config.labels, {})
    enable_apis = try(local.raw_config.enable_apis, true)
    apis        = try(local.raw_config.apis, [])
    hibernation = try(local.raw_config.hibernation, null)
  }

  environments = try(local.raw_config.environments, {})
}

module "settings" {
  source   = "../../../modules/composer-3-settings"
  for_each = local.environments

  environment_key = each.key
  config          = each.value
  global_config   = local.global_config
}

output "environments" {
  description = "Resolved settings per environment key"
  value       = { for k, m in module.settings : k => m.settings }
}
