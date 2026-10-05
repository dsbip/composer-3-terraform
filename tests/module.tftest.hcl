# Unit tests for modules/composer-3, called directly with inline config (mock providers).
# Negative runs each contain a single mistake and expect the configuration precondition on
# google_composer_environment.this (validation.tf) to fail.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  environment_key = "unit"
  global_config = {
    project_id  = "unit-project"
    region      = "europe-west2"
    labels      = { managed_by = "terraform" }
    enable_apis = true
    apis        = []
  }
  config = {}
}

# ── Defaults and rendering ─────────────────────────────────────────────

run "empty_config_uses_composer_3_defaults" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].software_config[0].image_version == "composer-3-airflow-2"
    error_message = "Default image must be the composer-3-airflow-2 alias."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].environment_size == "ENVIRONMENT_SIZE_SMALL"
    error_message = "Default size should be ENVIRONMENT_SIZE_SMALL."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].workloads_config[0].scheduler[0].count == 1
    error_message = "Standard resilience should default to 1 scheduler."
  }

  assert {
    condition = (
      google_composer_environment.this[0].config[0].workloads_config[0].worker[0].min_count == 1 &&
      google_composer_environment.this[0].config[0].workloads_config[0].worker[0].max_count == 3
    )
    error_message = "Workers should default to autoscaling between 1 and 3."
  }

  assert {
    condition     = length(google_composer_environment.this[0].config[0].workloads_config[0].triggerer) == 0 && length(google_composer_environment.this[0].config[0].workloads_config[0].dag_processor) == 0
    error_message = "triggerer and dag_processor should only be configured when present in YAML."
  }

  assert {
    condition     = length(google_compute_network.composer) == 1 && length(google_compute_subnetwork.composer) == 1
    error_message = "A dedicated VPC and subnet should be created by default."
  }

  assert {
    condition     = length(google_compute_router_nat.composer) == 0
    error_message = "Cloud NAT should be off by default."
  }

  assert {
    condition     = length(google_kms_crypto_key.composer) == 0 && length(google_kms_crypto_key_iam_member.composer_agent_kms) == 0
    error_message = "No CMEK resources should exist by default."
  }

  assert {
    condition     = length(google_project_service.required) == 5
    error_message = "Only the 5 default APIs should be enabled by default."
  }

  assert {
    condition     = length(google_project_iam_member.composer_sa_roles) == 3 && contains(keys(google_project_iam_member.composer_sa_roles), "roles/composer.worker")
    error_message = "The created SA should get the 3 default roles, including roles/composer.worker."
  }

  assert {
    condition     = google_composer_environment.this[0].labels == tomap({ managed_by = "terraform" })
    error_message = "Global labels should be applied."
  }

  assert {
    condition     = google_composer_environment.this[0].region == "europe-west2" && google_composer_environment.this[0].project == "unit-project"
    error_message = "Region and project should come from global_config."
  }
}

run "high_resilience_adjusts_workload_defaults" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      resilience_mode = "HIGH_RESILIENCE"
      workloads = {
        triggerer     = {}
        dag_processor = {}
      }
    }
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].workloads_config[0].scheduler[0].count == 2
    error_message = "HIGH_RESILIENCE should default to exactly 2 schedulers."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].workloads_config[0].worker[0].min_count == 2
    error_message = "HIGH_RESILIENCE should default to at least 2 workers."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].workloads_config[0].triggerer[0].count == 2
    error_message = "HIGH_RESILIENCE should default the triggerer count to 2."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].workloads_config[0].dag_processor[0].count == 2
    error_message = "HIGH_RESILIENCE should default the DAG processor count to 2."
  }
}

run "private_ip_environment_with_cloud_nat" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      enable_private_environment = true
      enable_private_builds_only = false
      network = {
        enable_cloud_nat = true
      }
    }
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].enable_private_environment == true
    error_message = "enable_private_environment should be passed through."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].enable_private_builds_only == false
    error_message = "enable_private_builds_only should be passed through."
  }

  assert {
    condition     = length(google_compute_router.composer) == 1 && length(google_compute_router_nat.composer) == 1
    error_message = "enable_cloud_nat should create a Cloud Router and Cloud NAT."
  }
}

run "existing_network_attachment_skips_vpc_creation" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      network = {
        existing_network_attachment       = "projects/unit-project/regions/europe-west2/networkAttachments/composer"
        composer_internal_ipv4_cidr_block = "100.64.128.0/20"
      }
    }
  }

  assert {
    condition     = length(google_compute_network.composer) == 0
    error_message = "Supplying a network attachment should default network.create to false."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].node_config[0].composer_network_attachment == "projects/unit-project/regions/europe-west2/networkAttachments/composer"
    error_message = "The network attachment should be passed to node_config."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].node_config[0].composer_internal_ipv4_cidr_block == "100.64.128.0/20"
    error_message = "composer_internal_ipv4_cidr_block should be passed to node_config."
  }
}

run "network_create_false_leaves_environment_unattached" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      network = { create = false }
    }
  }

  assert {
    condition     = length(google_compute_network.composer) == 0 && length(google_compute_subnetwork.composer) == 0
    error_message = "network.create: false without existing networking should create no VPC."
  }
}

run "existing_service_account_from_another_project" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      service_account = {
        existing_email = "shared-composer@other-project.iam.gserviceaccount.com"
        roles          = []
      }
    }
  }

  assert {
    condition     = length(google_service_account.composer) == 0
    error_message = "Supplying existing_email should default service_account.create to false."
  }

  assert {
    condition     = length(google_project_iam_member.composer_sa_roles) == 0
    error_message = "roles: [] should grant no project roles (IAM managed elsewhere)."
  }

  assert {
    condition     = google_service_account_iam_member.composer_agent_sa_user[0].service_account_id == "projects/other-project/serviceAccounts/shared-composer@other-project.iam.gserviceaccount.com"
    error_message = "An existing SA should be addressed in the project named in its email."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].node_config[0].service_account == "shared-composer@other-project.iam.gserviceaccount.com"
    error_message = "The environment should run as the existing SA."
  }
}

run "cmek_creates_key_and_grants_required_agents" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      encryption = { enable_cmek = true }
    }
  }

  assert {
    condition     = length(google_kms_key_ring.composer) == 1 && length(google_kms_crypto_key.composer) == 1
    error_message = "CMEK should create a key ring and key."
  }

  assert {
    condition     = google_kms_key_ring.composer[0].location == "europe-west2"
    error_message = "The key ring must be in the environment's region."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.composer_agent_kms) == 1 && length(google_kms_crypto_key_iam_member.gcs_agent_kms) == 1
    error_message = "The Composer and Cloud Storage service agents need encrypter/decrypter on the key."
  }

  assert {
    condition     = contains(keys(google_project_service.required), "cloudkms.googleapis.com")
    error_message = "CMEK should enable the Cloud KMS API."
  }
}

run "existing_kms_key_implies_cmek" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      encryption = { existing_kms_key = "projects/unit-project/locations/europe-west2/keyRings/ring/cryptoKeys/key" }
    }
  }

  assert {
    condition     = length(google_kms_key_ring.composer) == 0
    error_message = "An existing key should not create a key ring."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].encryption_config[0].kms_key_name == "projects/unit-project/locations/europe-west2/keyRings/ring/cryptoKeys/key"
    error_message = "The existing key should be used without setting enable_cmek."
  }
}

run "web_server_access_control_is_rendered" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      web_server_network_access_control = {
        allowed_ip_ranges = [
          { value = "203.0.113.0/24", description = "office" },
          { value = "2001:db8::/32" },
        ]
      }
    }
  }

  assert {
    condition     = length(google_composer_environment.this[0].config[0].web_server_network_access_control[0].allowed_ip_range) == 2
    error_message = "Both allowed IP ranges should be rendered."
  }
}

run "recovery_and_retention_are_rendered" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      recovery = {
        snapshot_location = "gs://unit-bucket/snapshots"
        time_zone         = "UTC+01"
      }
      data_retention = {
        airflow_metadata_retention_config = {}
      }
    }
  }

  assert {
    condition = (
      google_composer_environment.this[0].config[0].recovery_config[0].scheduled_snapshots_config[0].enabled == true &&
      google_composer_environment.this[0].config[0].recovery_config[0].scheduled_snapshots_config[0].snapshot_location == "gs://unit-bucket/snapshots" &&
      google_composer_environment.this[0].config[0].recovery_config[0].scheduled_snapshots_config[0].snapshot_creation_schedule == "0 3 * * *" &&
      google_composer_environment.this[0].config[0].recovery_config[0].scheduled_snapshots_config[0].time_zone == "UTC+01"
    )
    error_message = "Scheduled snapshots should be enabled with the given location/time zone and the default schedule."
  }

  assert {
    condition = (
      google_composer_environment.this[0].config[0].data_retention_config[0].airflow_metadata_retention_config[0].retention_mode == "RETENTION_MODE_ENABLED" &&
      google_composer_environment.this[0].config[0].data_retention_config[0].airflow_metadata_retention_config[0].retention_days == 30
    )
    error_message = "Metadata retention should default to enabled with 30 days."
  }
}

run "data_lineage_enables_its_api" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      software_config = {
        cloud_data_lineage_integration = { enabled = true }
        web_server_plugins_mode        = "DISABLED"
      }
    }
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].software_config[0].cloud_data_lineage_integration[0].enabled == true
    error_message = "cloud_data_lineage_integration should be rendered."
  }

  assert {
    condition     = contains(keys(google_project_service.required), "datalineage.googleapis.com")
    error_message = "Data lineage should enable the Data Lineage API."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].software_config[0].web_server_plugins_mode == "DISABLED"
    error_message = "web_server_plugins_mode should be passed through."
  }
}

run "labels_merge_and_null_values_fall_back" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      region = null
      labels = { managed_by = "yaml", cost = 1234 }
      software_config = {
        pypi_packages = { pandas = null }
      }
    }
  }

  assert {
    condition     = google_composer_environment.this[0].labels == tomap({ managed_by = "yaml", cost = "1234" })
    error_message = "Per-env labels should win over global labels and be stringified."
  }

  assert {
    condition     = google_composer_environment.this[0].region == "europe-west2"
    error_message = "An explicit null region should fall back to the global region."
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].software_config[0].pypi_packages["pandas"] == ""
    error_message = "A PyPI package without a version should be installed unpinned."
  }
}

run "enable_apis_false_manages_no_apis" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = { enable_apis = false }
  }

  assert {
    condition     = length(google_project_service.required) == 0
    error_message = "enable_apis: false should not manage any APIs."
  }
}

run "airflow_3_raises_triggerer_default_memory" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      software_config = { image_version = "composer-3-airflow-3" }
      workloads       = { triggerer = {} }
    }
  }

  assert {
    condition     = google_composer_environment.this[0].config[0].workloads_config[0].triggerer[0].memory_gb == 2
    error_message = "Airflow 3 needs at least 2 GB per triggerer, so the default should follow the image."
  }
}

# ── Rejected configuration ─────────────────────────────────────────────

run "rejects_composer_2_private_environment_block" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { private_environment = { enable_private_endpoint = true } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_master_authorized_networks" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { master_authorized_networks = { enabled = true } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_gke_secondary_ranges" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { network = { pods_cidr = "10.1.0.0/16" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_task_logs_retention_config" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { data_retention = { task_logs_retention_config = { storage_mode = "CLOUD_LOGGING_ONLY" } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_composer_2_image" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { software_config = { image_version = "composer-2.9.7-airflow-2.9.3" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_unknown_environment_size" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { environment_size = "ENVIRONMENT_SIZE_HUGE" }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_uppercase_labels" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { labels = { Env = "Prod" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_high_resilience_with_one_scheduler" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { resilience_mode = "HIGH_RESILIENCE", workloads = { scheduler = { count = 1 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_high_resilience_with_one_worker" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { resilience_mode = "HIGH_RESILIENCE", workloads = { worker = { min_count = 1 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_high_resilience_with_one_triggerer" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { resilience_mode = "HIGH_RESILIENCE", workloads = { triggerer = { count = 1 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_high_resilience_with_one_dag_processor" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { resilience_mode = "HIGH_RESILIENCE", workloads = { dag_processor = { count = 1 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_worker_min_above_max" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { workloads = { worker = { min_count = 5, max_count = 2 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_too_many_dag_processors" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { workloads = { dag_processor = { count = 4 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_maintenance_window_under_12_hours_per_week" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = {
      maintenance_window = {
        start_time = "2024-01-01T02:00:00Z"
        end_time   = "2024-01-01T06:00:00Z"
        recurrence = "FREQ=WEEKLY;BYDAY=SU"
      }
    }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_maintenance_slot_under_4_hours" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = {
      maintenance_window = {
        start_time = "2024-01-01T02:00:00Z"
        end_time   = "2024-01-01T05:00:00Z"
        recurrence = "FREQ=DAILY"
      }
    }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_unsupported_maintenance_recurrence" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = {
      maintenance_window = {
        start_time = "2024-01-01T00:00:00Z"
        end_time   = "2024-01-01T12:00:00Z"
        recurrence = "FREQ=MONTHLY"
      }
    }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_region_as_snapshot_location" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { recovery = { snapshot_location = "europe-west2" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_iana_snapshot_time_zone" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { recovery = { snapshot_location = "gs://unit-bucket/snapshots", time_zone = "Europe/London" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_retention_below_30_days" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { data_retention = { airflow_metadata_retention_config = { retention_days = 14 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_internal_cidr_that_is_not_slash_20" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { network = { composer_internal_ipv4_cidr_block = "100.64.128.0/24" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_create_true_with_existing_attachment" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { network = { create = true, existing_network_attachment = "projects/p/regions/r/networkAttachments/a" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_existing_network_without_subnetwork" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { network = { existing_network = "projects/unit-project/global/networks/shared" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_cloud_nat_on_existing_network" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = {
      network = {
        existing_network    = "projects/unit-project/global/networks/shared"
        existing_subnetwork = "projects/unit-project/regions/europe-west2/subnetworks/shared"
        enable_cloud_nat    = true
      }
    }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_empty_web_server_allow_list" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { web_server_network_access_control = { allowed_ip_ranges = [] } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_service_account_create_false_without_email" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { service_account = { create = false } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_created_service_account_without_composer_worker" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { service_account = { roles = ["roles/logging.logWriter"] } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_kms_key_in_another_region" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { encryption = { existing_kms_key = "projects/unit-project/locations/us-central1/keyRings/ring/cryptoKeys/key" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_reserved_env_variable" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { software_config = { env_variables = { GCS_BUCKET = "x" } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_uppercase_pypi_package" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { software_config = { pypi_packages = { Pandas = "" } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_dotted_airflow_override" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { software_config = { airflow_config_overrides = { "core.dags_are_paused_at_creation" = "True" } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_invalid_web_server_plugins_mode" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { software_config = { web_server_plugins_mode = "ON" } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_scheduler_above_2_vcpu" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { workloads = { scheduler = { cpu = 4, memory_gb = 8 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_triggerer_below_1_gb" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { workloads = { triggerer = { cpu = 0.5, memory_gb = 0.5 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_worker_cpu_off_step" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { workloads = { worker = { cpu = 3, memory_gb = 6 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_memory_per_vcpu_below_1_gb" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { workloads = { worker = { cpu = 4, memory_gb = 2 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_four_schedulers" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { workloads = { scheduler = { count = 4 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_more_than_100_workers" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { workloads = { worker = { max_count = 101 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_zero_dag_processors" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { workloads = { dag_processor = { count = 0 } } }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_airflow_3_triggerer_with_1_gb" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = {
      software_config = { image_version = "composer-3-airflow-3" }
      workloads       = { triggerer = { memory_gb = 1 } }
    }
  }
  expect_failures = [google_composer_environment.this]
}
