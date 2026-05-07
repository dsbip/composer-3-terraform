resource "google_composer_environment" "this" {
  provider = google-beta

  project = local.project_id
  name    = local.environment_name
  region  = local.region
  labels  = local.labels

  config {
    environment_size = local.environment_size
    resilience_mode  = local.resilience_mode

    node_config {
      network         = local.network_self_link
      subnetwork      = local.subnetwork_self_link
      service_account = local.composer_sa_email
      tags            = local.network.tags

      ip_allocation_policy {
        cluster_secondary_range_name  = local.network.pods_range_name
        services_secondary_range_name = local.network.services_range_name
      }
    }

    software_config {
      image_version            = local.software_config.image_version
      airflow_config_overrides = local.software_config.airflow_config_overrides
      env_variables            = local.software_config.env_variables
      pypi_packages            = local.software_config.pypi_packages
    }

    workloads_config {
      scheduler {
        cpu        = local.workloads.scheduler.cpu
        memory_gb  = local.workloads.scheduler.memory_gb
        storage_gb = local.workloads.scheduler.storage_gb
        count      = local.workloads.scheduler.count
      }

      web_server {
        cpu        = local.workloads.web_server.cpu
        memory_gb  = local.workloads.web_server.memory_gb
        storage_gb = local.workloads.web_server.storage_gb
      }

      worker {
        cpu        = local.workloads.worker.cpu
        memory_gb  = local.workloads.worker.memory_gb
        storage_gb = local.workloads.worker.storage_gb
        min_count  = local.workloads.worker.min_count
        max_count  = local.workloads.worker.max_count
      }

      dynamic "triggerer" {
        for_each = local.workloads.triggerer != null ? [local.workloads.triggerer] : []
        content {
          cpu       = triggerer.value.cpu
          memory_gb = triggerer.value.memory_gb
          count     = triggerer.value.count
        }
      }

      dynamic "dag_processor" {
        for_each = local.workloads.dag_processor != null ? [local.workloads.dag_processor] : []
        content {
          cpu        = dag_processor.value.cpu
          memory_gb  = dag_processor.value.memory_gb
          storage_gb = dag_processor.value.storage_gb
          count      = dag_processor.value.count
        }
      }
    }

    dynamic "private_environment_config" {
      for_each = local.private_environment != null ? [local.private_environment] : []
      content {
        enable_private_endpoint                = private_environment_config.value.enable_private_endpoint
        cloud_sql_ipv4_cidr_block              = private_environment_config.value.cloud_sql_ipv4_cidr_block
        web_server_ipv4_cidr_block             = private_environment_config.value.web_server_ipv4_cidr_block
        master_ipv4_cidr_block                 = private_environment_config.value.master_ipv4_cidr_block
        cloud_composer_network_ipv4_cidr_block = private_environment_config.value.cloud_composer_network_ipv4_cidr_block
        enable_privately_used_public_ips       = private_environment_config.value.enable_privately_used_public_ips
        connection_type                        = private_environment_config.value.connection_type
      }
    }

    dynamic "master_authorized_networks_config" {
      for_each = local.master_authorized_networks != null ? [local.master_authorized_networks] : []
      content {
        enabled = try(master_authorized_networks_config.value.enabled, true)

        dynamic "cidr_blocks" {
          for_each = try(master_authorized_networks_config.value.cidr_blocks, [])
          content {
            display_name = cidr_blocks.value.display_name
            cidr_block   = cidr_blocks.value.cidr_block
          }
        }
      }
    }

    dynamic "maintenance_window" {
      for_each = local.maintenance_window != null ? [local.maintenance_window] : []
      content {
        start_time = maintenance_window.value.start_time
        end_time   = maintenance_window.value.end_time
        recurrence = maintenance_window.value.recurrence
      }
    }

    dynamic "encryption_config" {
      for_each = local.kms_key_id != null ? [local.kms_key_id] : []
      content {
        kms_key_name = encryption_config.value
      }
    }

    dynamic "recovery_config" {
      for_each = local.recovery != null ? [local.recovery] : []
      content {
        scheduled_snapshots_config {
          enabled                    = try(recovery_config.value.enable_scheduled_snapshots, true)
          snapshot_location          = try(recovery_config.value.snapshot_location, local.region)
          snapshot_creation_schedule = try(recovery_config.value.snapshot_creation_schedule, "0 3 * * *")
          time_zone                  = try(recovery_config.value.time_zone, "UTC")
        }
      }
    }

    dynamic "data_retention_config" {
      for_each = local.data_retention != null ? [local.data_retention] : []
      content {
        dynamic "airflow_metadata_retention_config" {
          for_each = try(data_retention_config.value.airflow_metadata_retention_config, null) != null ? [data_retention_config.value.airflow_metadata_retention_config] : []
          content {
            retention_mode = try(airflow_metadata_retention_config.value.retention_mode, "RETENTION_MODE_ENABLED")
            retention_days = try(airflow_metadata_retention_config.value.retention_days, 30)
          }
        }

        dynamic "task_logs_retention_config" {
          for_each = try(data_retention_config.value.task_logs_retention_config, null) != null ? [data_retention_config.value.task_logs_retention_config] : []
          content {
            storage_mode = try(task_logs_retention_config.value.storage_mode, "CLOUD_LOGGING_AND_CLOUD_STORAGE")
          }
        }
      }
    }
  }

  dynamic "storage_config" {
    for_each = local.custom_bucket != null ? [local.custom_bucket] : []
    content {
      bucket = storage_config.value
    }
  }

  depends_on = [
    google_project_service.required,
    google_project_iam_member.composer_sa_roles,
    google_project_iam_member.composer_agent_v2ext,
    google_service_account_iam_member.composer_agent_sa_user,
    google_kms_crypto_key_iam_member.composer_agent_kms,
    google_kms_crypto_key_iam_member.artifact_registry_kms,
    google_kms_crypto_key_iam_member.gcs_kms,
    google_compute_subnetwork.composer,
    google_compute_router_nat.composer,
  ]
}
