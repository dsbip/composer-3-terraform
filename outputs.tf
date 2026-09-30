output "environments" {
  description = "Map of all Composer environments with their key details"
  value = {
    for key, env in module.composer : key => {
      environment_id        = env.environment_id
      environment_name      = env.environment_name
      image_version         = env.image_version
      airflow_uri           = env.airflow_uri
      dag_gcs_prefix        = env.dag_gcs_prefix
      gcs_bucket            = env.gcs_bucket
      service_account_email = env.service_account_email
      network_self_link     = env.network_self_link
      subnetwork_self_link  = env.subnetwork_self_link
      kms_key_id            = env.kms_key_id
    }
  }

  precondition {
    condition     = length(local.duplicate_resource_ids) == 0
    error_message = "Two environments in ${var.config_file} would create the same resource: ${join(", ", local.duplicate_resource_ids)}. Give them distinct environment_name, service_account.name, network.name or encryption.kms_key_ring_name values."
  }
}
