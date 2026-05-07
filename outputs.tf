output "environments" {
  description = "Map of all Composer environments with their key details"
  value = {
    for key, env in module.composer : key => {
      environment_id        = env.environment_id
      environment_name      = env.environment_name
      airflow_uri           = env.airflow_uri
      dag_gcs_prefix        = env.dag_gcs_prefix
      gcs_bucket            = env.gcs_bucket
      service_account_email = env.service_account_email
      network_self_link     = env.network_self_link
      subnetwork_self_link  = env.subnetwork_self_link
    }
  }
}
