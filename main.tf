locals {
  # Relative paths resolve against the root module; absolute paths are used as-is.
  config_path = can(regex("^([A-Za-z]:)?[\\\\/]", var.config_file)) ? var.config_file : "${path.root}/${var.config_file}"
  raw_config  = yamldecode(file(local.config_path))

  global_config = {
    project_id  = try(local.raw_config.project_id, null)
    region      = coalesce(try(local.raw_config.region, null), "europe-west2")
    labels      = try(local.raw_config.labels, {})
    enable_apis = try(local.raw_config.enable_apis, true)
    apis        = try(local.raw_config.apis, [])
  }

  # `environments:` with no entries decodes to null.
  environments = try({ for k, v in local.raw_config.environments : k => v }, {})

  # Named resources that two environments in the same file must not both create.
  managed_resource_ids = flatten([for env in module.composer : env.managed_resource_ids])
  duplicate_resource_ids = distinct([
    for id in local.managed_resource_ids : id
    if length([for other in local.managed_resource_ids : other if other == id]) > 1
  ])
}

module "composer" {
  source   = "./modules/composer-3"
  for_each = local.environments

  environment_key = each.key
  config          = each.value
  global_config   = local.global_config
}
