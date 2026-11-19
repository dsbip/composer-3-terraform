output "environment_name" {
  description = "Resolved Composer environment name (environment_name override or the YAML key)"
  value       = local.environment_name
}

output "project_id" {
  description = "Resolved GCP project (per-env > global)"
  value       = local.project_id
}

output "region" {
  description = "Resolved GCP region (per-env > global > europe-west2)"
  value       = local.region
}

output "labels" {
  description = "Global labels merged with per-env labels (per-env wins)"
  value       = local.labels
}

output "is_production" {
  description = "True when the environment is classed as production (env/environment/tier/stage label, else its name)"
  value       = local.is_production
}

output "hibernation" {
  description = "Resolved hibernation settings with all defaults applied"
  value       = local.hibernation
}

output "validation_errors" {
  description = "Human-readable configuration errors; empty when the configuration is valid"
  value       = local.validation_errors
}

output "settings" {
  description = "Everything above plus the extra fields the hibernation scripts need, as one object"
  value = {
    environment_key       = var.environment_key
    environment_name      = local.environment_name
    project_id            = local.project_id
    region                = local.region
    labels                = local.labels
    is_production         = local.is_production
    image_version         = local.image_version
    custom_bucket         = local.custom_bucket
    service_account_email = local.service_account_email
    hibernation           = local.hibernation
    validation_errors     = local.validation_errors
  }
}
