# Tests for create_composer_environment: false removes only the Composer environment and keeps
# the supporting infrastructure (network, subnet, Cloud NAT, service account, IAM, KMS, APIs).
# Calls modules/composer-3 directly with mock providers. The lifecycle_* runs apply in order
# and share state, so they check what happens when the flag is switched off and back on.

# Mock providers fill computed attributes with random strings. Where one feeds another
# resource, the provider's format checks reject it on apply, so those get realistic values.
mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name   = "projects/unit-project/serviceAccounts/unit-sa@unit-project.iam.gserviceaccount.com"
      email  = "unit-sa@unit-project.iam.gserviceaccount.com"
      member = "serviceAccount:unit-sa@unit-project.iam.gserviceaccount.com"
    }
  }

  # A real project number never changes; a random one per run would make the Composer service
  # agent's IAM bindings look modified on every apply.
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }

  mock_data "google_storage_project_service_account" {
    defaults = {
      email_address = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
      member        = "serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    }
  }
}

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
  # Every supporting resource the module can create: VPC + Cloud NAT, CMEK, data lineage API.
  config = {
    network         = { enable_cloud_nat = true }
    encryption      = { enable_cmek = true }
    software_config = { cloud_data_lineage_integration = { enabled = true } }
  }
}

# ── Plan: what is and is not created ───────────────────────────────────

run "default_creates_environment" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  assert {
    condition     = length(google_composer_environment.this) == 1 && output.composer_environment_created == true
    error_message = "Without create_composer_environment the environment should be created."
  }
}

run "switched_off_keeps_supporting_infrastructure" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      create_composer_environment = false
      network                     = { enable_cloud_nat = true }
      encryption                  = { enable_cmek = true }
      software_config             = { cloud_data_lineage_integration = { enabled = true } }
    }
  }

  assert {
    condition     = length(google_composer_environment.this) == 0
    error_message = "create_composer_environment: false should not plan a Composer environment."
  }

  assert {
    condition = (
      length(google_compute_network.composer) == 1 &&
      length(google_compute_subnetwork.composer) == 1 &&
      length(google_compute_router.composer) == 1 &&
      length(google_compute_router_nat.composer) == 1
    )
    error_message = "The VPC, subnet, Cloud Router and Cloud NAT should still be created."
  }

  assert {
    condition = (
      length(google_service_account.composer) == 1 &&
      length(google_project_iam_member.composer_sa_roles) == 3 &&
      length(google_service_account_iam_member.composer_agent_sa_user) == 1
    )
    error_message = "The service account, its roles and the service agent binding should still be created."
  }

  assert {
    condition = (
      length(google_kms_key_ring.composer) == 1 &&
      length(google_kms_crypto_key.composer) == 1 &&
      length(google_kms_crypto_key_iam_member.composer_agent_kms) == 1 &&
      length(google_kms_crypto_key_iam_member.gcs_agent_kms) == 1
    )
    error_message = "The CMEK key ring, key and both key grants should still be created."
  }

  assert {
    # 5 default APIs + cloudkms (CMEK) + datalineage (data lineage).
    condition     = length(google_project_service.required) == 7 && google_project_service_identity.composer.service == "composer.googleapis.com"
    error_message = "API enablement and the Composer service identity should not depend on the flag."
  }

  assert {
    condition = (
      output.composer_environment_created == false &&
      output.environment_id == null &&
      output.image_version == null &&
      output.airflow_uri == null &&
      output.dag_gcs_prefix == null &&
      output.gcs_bucket == null &&
      output.composer_environment_config == null
    )
    error_message = "Outputs that describe the environment should be null while it is switched off."
  }

  assert {
    condition     = output.environment_name == "unit"
    error_message = "environment_name should still report the configured name."
  }

  assert {
    condition     = contains(output.managed_resource_ids, "composer environment unit-project/europe-west2/unit")
    error_message = "The environment name should stay reserved for the collision check while switched off."
  }
}

run "explicit_true_creates_environment" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = { create_composer_environment = true }
  }

  assert {
    condition     = length(google_composer_environment.this) == 1
    error_message = "create_composer_environment: true should create the environment."
  }
}

run "global_false_switches_environment_off" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    global_config = { project_id = "unit-project", create_composer_environment = false }
    config        = {}
  }

  assert {
    condition     = length(google_composer_environment.this) == 0 && length(google_compute_network.composer) == 1
    error_message = "The global value should apply when the environment does not set one."
  }
}

run "environment_true_overrides_global_false" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    global_config = { project_id = "unit-project", create_composer_environment = false }
    config        = { create_composer_environment = true }
  }

  assert {
    condition     = length(google_composer_environment.this) == 1
    error_message = "The per-environment value should override the global one."
  }
}

run "environment_false_overrides_global_true" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    global_config = { project_id = "unit-project", create_composer_environment = true }
    config        = { create_composer_environment = false }
  }

  assert {
    condition     = length(google_composer_environment.this) == 0
    error_message = "The per-environment false should override a global true."
  }
}

run "empty_value_falls_back_to_global" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    # `create_composer_environment:` with no value arrives as null.
    global_config = { project_id = "unit-project", create_composer_environment = false }
    config        = { create_composer_environment = null }
  }

  assert {
    condition     = length(google_composer_environment.this) == 0
    error_message = "An empty per-environment value should fall back to the global value."
  }
}

run "quoted_boolean_is_accepted" {
  command = plan

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = { create_composer_environment = "false" }
  }

  assert {
    condition     = length(google_composer_environment.this) == 0
    error_message = "A quoted \"false\" should be read as false (Terraform's tobool rules)."
  }
}

# ── Rejected configuration ─────────────────────────────────────────────

run "rejects_non_boolean_value" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { create_composer_environment = "maybe" }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_numeric_value" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = { create_composer_environment = 0 }
  }
  expect_failures = [google_composer_environment.this]
}

run "rejects_non_boolean_global_value" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    global_config = { project_id = "unit-project", create_composer_environment = "maybe" }
    config        = {}
  }
  expect_failures = [google_composer_environment.this]
}

# The configuration is still checked while the environment is switched off; the error then
# comes from the composer_environment_created output instead of the (absent) environment.
run "rejects_invalid_environment_setting_while_switched_off" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = {
      create_composer_environment = false
      data_retention              = { airflow_metadata_retention_config = { retention_days = 14 } }
    }
  }
  expect_failures = [output.composer_environment_created]
}

run "rejects_invalid_network_setting_while_switched_off" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = {
      create_composer_environment = false
      network = {
        existing_network    = "projects/unit-project/global/networks/shared"
        existing_subnetwork = "projects/unit-project/regions/europe-west2/subnetworks/shared"
        enable_cloud_nat    = true
      }
    }
  }
  expect_failures = [output.composer_environment_created]
}

run "rejects_service_account_without_email_while_switched_off" {
  command = plan
  module {
    source = "./modules/composer-3"
  }
  variables {
    config = {
      create_composer_environment = false
      service_account             = { create = false }
    }
  }
  expect_failures = [output.composer_environment_created]
}

# ── Lifecycle: apply on → off → on (state is shared between these runs) ─

run "lifecycle_1_create_everything" {
  command = apply

  module {
    source = "./modules/composer-3"
  }

  assert {
    condition     = length(google_composer_environment.this) == 1 && output.environment_id != null
    error_message = "The first apply should create the environment."
  }
}

run "lifecycle_2_switch_off" {
  command = apply

  module {
    source = "./modules/composer-3"
  }

  variables {
    config = {
      create_composer_environment = false
      network                     = { enable_cloud_nat = true }
      encryption                  = { enable_cmek = true }
      software_config             = { cloud_data_lineage_integration = { enabled = true } }
    }
  }

  assert {
    condition     = length(google_composer_environment.this) == 0 && output.environment_id == null && output.airflow_uri == null
    error_message = "Switching the flag off should destroy the environment."
  }

  # Mock providers give every newly created resource a new random ID, so unchanged IDs show
  # that Terraform kept these resources instead of destroying and recreating them. (Mocks
  # never force a replacement the way a real provider can when an argument changes; the flag
  # changes no argument of these resources. The service account's email is fixed by the mock
  # above, so it cannot show this.)
  assert {
    condition = (
      output.network_self_link == run.lifecycle_1_create_everything.network_self_link &&
      output.subnetwork_self_link == run.lifecycle_1_create_everything.subnetwork_self_link &&
      output.kms_key_id == run.lifecycle_1_create_everything.kms_key_id
    )
    error_message = "The network, subnet and KMS key must not be replaced when the environment is switched off."
  }

  assert {
    condition     = length(google_compute_router_nat.composer) == 1 && length(google_project_service.required) == 7
    error_message = "Cloud NAT and the APIs should remain."
  }
}

run "lifecycle_3_switch_back_on" {
  command = apply

  module {
    source = "./modules/composer-3"
  }

  assert {
    condition     = length(google_composer_environment.this) == 1 && output.environment_id != null
    error_message = "Switching the flag back on should recreate the environment."
  }

  assert {
    condition = (
      output.network_self_link == run.lifecycle_1_create_everything.network_self_link &&
      output.subnetwork_self_link == run.lifecycle_1_create_everything.subnetwork_self_link &&
      output.kms_key_id == run.lifecycle_1_create_everything.kms_key_id
    )
    error_message = "The recreated environment should reuse the original network, subnet and KMS key."
  }
}
