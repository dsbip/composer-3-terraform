output "environment_id" {
  description = "Full resource ID of the Composer environment"
  value       = google_composer_environment.this.id
}

output "environment_name" {
  description = "Name of the Composer environment"
  value       = google_composer_environment.this.name
}

output "image_version" {
  description = "Composer image version (the configured alias at plan time, the resolved build after apply)"
  value       = google_composer_environment.this.config[0].software_config[0].image_version
}

output "airflow_uri" {
  description = "URI of the Airflow web UI"
  value       = google_composer_environment.this.config[0].airflow_uri
}

output "dag_gcs_prefix" {
  description = "GCS prefix for DAG storage"
  value       = google_composer_environment.this.config[0].dag_gcs_prefix
}

output "gcs_bucket" {
  description = "GCS bucket used by the Composer environment"
  # storage_config is only populated once the environment exists (or when a custom bucket is set).
  value = try(
    google_composer_environment.this.storage_config[0].bucket,
    regex("^gs://([^/]+)", google_composer_environment.this.config[0].dag_gcs_prefix)[0],
    null,
  )
}

output "service_account_email" {
  description = "Email of the service account used by Composer"
  value       = local.composer_sa_email
}

output "network_self_link" {
  description = "Self link of the VPC network (null when the environment is not attached to a VPC or uses a network attachment)"
  value       = local.network_self_link
}

output "subnetwork_self_link" {
  description = "Self link of the subnetwork (null when the environment is not attached to a VPC or uses a network attachment)"
  value       = local.subnetwork_self_link
}

output "kms_key_id" {
  description = "KMS key ID used for CMEK encryption (null if CMEK disabled)"
  value       = local.kms_key_id
}

output "composer_environment_config" {
  description = "Full Composer environment config block"
  value       = google_composer_environment.this.config
}

output "managed_resource_ids" {
  description = "Project-scoped IDs of the named resources this environment creates; the root module uses them to reject name collisions between environments"
  value = concat(
    ["composer environment ${coalesce(local.project_id, "?")}/${local.region}/${local.environment_name}"],
    local.service_account.create ? ["service account ${coalesce(local.project_id, "?")}/${local.service_account.name}"] : [],
    local.network.create ? [
      "network ${coalesce(local.project_id, "?")}/${local.network.name}",
      "subnetwork ${coalesce(local.project_id, "?")}/${local.region}/${local.network.subnetwork_name}",
    ] : [],
    local.network.create && local.network.enable_cloud_nat ? ["router ${coalesce(local.project_id, "?")}/${local.region}/${local.environment_name}-router"] : [],
    local.create_kms_key ? ["key ring ${coalesce(local.project_id, "?")}/${local.region}/${local.encryption.kms_key_ring_name}"] : [],
  )
}
