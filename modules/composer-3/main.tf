resource "google_composer_environment" "this" {
  provider = google-beta

  project = local.project_id
  name    = local.environment_name
  region  = local.region
  labels  = local.labels

  config {
    environment_size = local.environment_size
    resilience_mode  = local.resilience_mode

    # Composer 3 networking type: Public IP (default) or Private IP.
    enable_private_environment = local.enable_private_environment
    enable_private_builds_only = local.enable_private_builds_only

    node_config {
      # Either network + subnetwork (Composer creates the PSC network attachment) or a
      # pre-created composer_network_attachment; all null = not attached to any VPC.
      network                           = local.network_self_link
      subnetwork                        = local.subnetwork_self_link
      composer_network_attachment       = local.network.existing_network_attachment
      composer_internal_ipv4_cidr_block = local.network.composer_internal_ipv4_cidr_block
      service_account                   = local.composer_sa_email
      tags                              = local.network.tags
    }

    software_config {
      image_version            = local.software_config.image_version
      airflow_config_overrides = local.software_config.airflow_config_overrides
      env_variables            = local.software_config.env_variables
      pypi_packages            = local.software_config.pypi_packages
      web_server_plugins_mode  = local.software_config.web_server_plugins_mode

      dynamic "cloud_data_lineage_integration" {
        for_each = local.software_config.cloud_data_lineage != null ? [local.software_config.cloud_data_lineage] : []
        content {
          enabled = cloud_data_lineage_integration.value
        }
      }
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

    dynamic "web_server_network_access_control" {
      for_each = local.web_server_access_control_enabled ? [local.web_server_allowed_ip_ranges] : []
      content {
        dynamic "allowed_ip_range" {
          for_each = web_server_network_access_control.value
          content {
            value       = allowed_ip_range.value.value
            description = allowed_ip_range.value.description
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
          enabled                    = recovery_config.value.enabled
          snapshot_location          = recovery_config.value.enabled ? recovery_config.value.snapshot_location : null
          snapshot_creation_schedule = recovery_config.value.enabled ? recovery_config.value.snapshot_creation_schedule : null
          time_zone                  = recovery_config.value.enabled ? recovery_config.value.time_zone : null
        }
      }
    }

    dynamic "data_retention_config" {
      for_each = local.metadata_retention != null ? [local.metadata_retention] : []
      content {
        airflow_metadata_retention_config {
          retention_mode = data_retention_config.value.retention_mode
          retention_days = data_retention_config.value.retention_days
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

  lifecycle {
    # All configuration checks from validation.tf, reported together.
    precondition {
      condition     = length(local.validation_errors) == 0
      error_message = "Invalid configuration for Composer environment \"${var.environment_key}\":\n  - ${join("\n  - ", local.validation_errors)}"
    }
  }

  depends_on = [
    google_project_service.required,
    google_project_iam_member.composer_sa_roles,
    google_service_account_iam_member.composer_agent_sa_user,
    google_kms_crypto_key_iam_member.composer_agent_kms,
    google_kms_crypto_key_iam_member.gcs_agent_kms,
    google_compute_subnetwork.composer,
    google_compute_router_nat.composer,
  ]
}
