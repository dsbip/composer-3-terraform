locals {
  raw_config = yamldecode(file("${path.root}/${var.config_file}"))

  global_config = {
    project_id  = try(local.raw_config.project_id, null)
    region      = try(local.raw_config.region, "europe-west2")
    labels      = try(local.raw_config.labels, {})
    enable_apis = try(local.raw_config.enable_apis, true)
    apis        = try(local.raw_config.apis, [])
  }

  environments = try(local.raw_config.environments, {})
}

module "composer" {
  source   = "./modules/composer-3"
  for_each = local.environments

  environment_key = each.key
  config          = each.value
  global_config   = local.global_config
}
