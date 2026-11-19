terraform {
  required_version = ">= 1.2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0.0"
    }
  }
}

variable "config_file" {
  description = "Path to the YAML configuration file"
  type        = string
}

variable "fallback_image_versions" {
  description = "Mirrors the root module input of the same name"
  type        = map(string)
  default     = {}
}

locals {
  raw_config = yamldecode(file("${path.root}/${var.config_file}"))

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

module "composer" {
  source   = "../../modules/composer-3"
  for_each = local.environments

  environment_key        = each.key
  config                 = each.value
  global_config          = local.global_config
  fallback_image_version = lookup(var.fallback_image_versions, each.key, null)
}

output "environment_names" {
  value = { for k, v in module.composer : k => v.environment_name }
}

output "service_account_emails" {
  value = { for k, v in module.composer : k => v.service_account_email }
}

output "hibernation" {
  value = { for k, v in module.composer : k => v.hibernation }
}
