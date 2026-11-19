output "environment_id" {
  description = "Full resource ID of the Composer environment"
  value       = google_composer_environment.this.id
}

output "environment_name" {
  description = "Name of the Composer environment"
  value       = google_composer_environment.this.name
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
  description = "GCS bucket used by the Composer environment (custom storage.bucket, else the bucket GCP auto-created, derived from dag_gcs_prefix)"
  value = try(
    google_composer_environment.this.storage_config[0].bucket,
    regex("^gs://([^/]+)", google_composer_environment.this.config[0].dag_gcs_prefix)[0],
    null
  )
}

output "service_account_email" {
  description = "Email of the service account used by Composer"
  value       = local.composer_sa_email
}

output "network_self_link" {
  description = "Self link of the VPC network"
  value       = local.network_self_link
}

output "subnetwork_self_link" {
  description = "Self link of the subnetwork"
  value       = local.subnetwork_self_link
}

output "kms_key_id" {
  description = "KMS key ID used for CMEK encryption (null if CMEK disabled)"
  value       = local.kms_key_id
}

output "hibernation" {
  description = "Resolved hibernation settings (enabled flag, snapshot bucket/location, retention, load options)"
  value       = local.hibernation
}

output "image_version" {
  description = "Image version the environment runs (as reported by the provider)"
  value       = try(google_composer_environment.this.config[0].software_config[0].image_version, null)
}

output "composer_environment_config" {
  description = "Full Composer environment config block"
  value       = google_composer_environment.this.config
}
