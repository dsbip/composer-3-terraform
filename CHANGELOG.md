# Changelog

## 2026-10-01 — Composer 3 correctness review

The module was checked against the google-beta provider it is locked to (v7.31.0), including the provider's source code for `google_composer_environment`, and against Google's current Cloud Composer 3 documentation (see [Sources](#sources)).

**Before this change the module did not deploy a working Composer 3 environment:**

- 3 of the 5 sample configs failed `terraform plan` against the real provider.
- The other 2 would have created **Composer 2** environments.
- The test suite failed: 1 passed, 3 failed, 2 skipped.

**After it:** all 5 configs plan cleanly against the real provider, and all 68 test runs pass.

### Fixed

| # | Problem | Effect | Fix |
|---|---|---|---|
| 1 | `software_config.image_version` defaulted to `null` | The Composer API creates a **Composer 2** environment when no image is given. The provider also rejects `dag_processor` without a Composer 3 image (*"dag_processor should only be used in Composer 3"*), so `multi-environment.yaml` failed plan | Default is now `composer-3-airflow-2`; any image must match `composer-3-airflow-*` |
| 2 | `node_config.ip_allocation_policy` with pods/services secondary ranges was always set | Composer 2 GKE setting with no meaning in Composer 3 | Removed, together with the subnet's secondary ranges and the `network.pods_*` / `network.services_*` keys |
| 3 | `private_environment` rendered `private_environment_config` | Provider error *"private_environment_config should not be used in Composer 3"*. `production.yaml` failed plan | Replaced by the Composer 3 fields `enable_private_environment` and `enable_private_builds_only` |
| 4 | `master_authorized_networks` | Rejected by the provider for Composer 3 (there is no user-visible GKE control plane) | Replaced by `web_server_network_access_control`, an IP allow-list for the Airflow UI |
| 5 | `data_retention.task_logs_retention_config` | Not supported for Composer 3 | Removed from the module and configs |
| 6 | `retention_days: 14` in `development.yaml` | Provider range is 30–730; would fail at apply | Set to 30 |
| 7 | `recovery.snapshot_location` defaulted to the region; configs used region names | The field is a Cloud Storage folder URI (`gs://bucket/folder`) | Required (as `gs://...`) when snapshots are enabled |
| 8 | `recovery.time_zone` used IANA names (`America/Chicago`, `Europe/London`) | Only fixed offsets `UTC-12`..`UTC+12` are accepted | Configs use `UTC-06` / `UTC` |
| 9 | Every maintenance window was 4 hours on a single day | Composer requires at least 12 hours per week and at least 4 hours per slot | Configs use 4 hours × 3 days |
| 10 | `HIGH_RESILIENCE` used the module defaults (1 scheduler, 1 worker); `private-ip.yaml` had 1 triggerer and 1 DAG processor | Composer 3 HA requires exactly 2 schedulers, ≥ 2 workers, ≥ 2 DAG processors and 0 or ≥ 2 triggerers | Defaults now follow the resilience mode, and `private-ip.yaml` is fixed |
| 11 | CMEK granted the key to the Artifact Registry service agent | Not required for Composer 3, and the grant fails in projects where that agent does not exist | Only the Composer and Cloud Storage service agents are granted (the two Composer 3 requires); the Cloud Storage agent is created if missing |
| 12 | The Composer service agent could be missing on the first apply ("may need two applies") | IAM bindings to it failed in projects that had never used Composer | The agent is generated up front with `google_project_service_identity` |
| 13 | The `gcs_bucket` output indexed `storage_config[0]` | *"Invalid index"* whenever no custom bucket is set, which made every mock test fail | Falls back to the bucket in `dag_gcs_prefix`, then null |
| 14 | `workloads.scheduler.cpu: 4` in `production.yaml` and the `multi-environment.yaml` prod environment | Composer 3 schedulers take 0.5–2 vCPU | Set to 2 (memory stays 8 GB, within the 1–8 GB per vCPU range) |
| 15 | Triggerer default memory was 0.5 GB, as was the staging triggerer in `multi-environment.yaml` | Below Composer 3's minimum of 1 GB per triggerer (2 GB with Airflow 3), so any `triggerer: {}` block failed | Default is 1 GB, or 2 GB with an Airflow 3 image; staging fixed |
| 16 | `tests/validate_configs.py` rejected `ENVIRONMENT_SIZE_EXTRA_LARGE` and missed all of the above | — | Rewritten to mirror the module's checks |

### Changed

- **IAM:** `roles/composer.ServiceAgentV2Ext` is no longer granted project-wide. It is a Composer 2 requirement; Google's Composer 3 documentation says the service agent needs only the role it gets automatically. The project-wide grant also allowed the agent to change IAM on every service account in the project. Because it was a single binding shared by all environments, deleting any one environment would have removed it for all of them.
- **Firewall rules removed** (`{env}-allow-internal`, `{env}-allow-health-checks`). They targeted Composer 2 GKE nodes; Composer 3 has no VMs in your VPC and needs no firewall configuration.
- **Silently ignored settings now take effect:** `network.create` defaults to false when existing networking is given, `service_account.create` defaults to false when `existing_email` is set, and `encryption.enable_cmek` defaults to true when `existing_kms_key` is set. Previously these values were ignored unless the flag was also set. Setting both conflicting values is now an error.
- `network.create: false` with no existing network now means "not attached to any VPC" (valid for Composer 3).
- An existing service account in another project is now addressed in its own project for IAM.
- **YAML handling:**
  - Empty values (`region:`) fall back to the defaults.
  - An environment key with no value is treated as `{}`.
  - `environments:` with no entries plans zero environments.
  - `config_file` accepts absolute paths.
- Label values are converted to strings, and created KMS keys get the environment's labels.
- `configs/production.yaml`:
  - Pins Airflow `composer-3-airflow-2.11.1` (previously `composer-3-airflow-2.10.2`).
  - Uses Private IP.
  - Restricts Airflow UI access to the ranges previously listed as master authorized networks.

### Added

- **YAML fields:**
  - `enable_private_environment`
  - `enable_private_builds_only`
  - `network.existing_network_attachment`
  - `network.composer_internal_ipv4_cidr_block`
  - `web_server_network_access_control`
  - `software_config.web_server_plugins_mode`
  - `software_config.cloud_data_lineage_integration` (also enables `datalineage.googleapis.com`)
- **Plan-time validation** (`modules/composer-3/validation.tf`), including Composer 3's per-component limits: counts, vCPU range and step, memory range, 1–8 GB of memory per vCPU, and storage. All problems in an environment are reported in one error that names the environment. This is necessary because the provider skips validation of the nested `config` block while any value in it is unknown at plan time, so errors such as #6 would otherwise surface only during apply, after the network, IAM and KMS resources exist.
- **Name-collision check** in the root module, for two environments that would create the same Composer environment, service account, network, subnet, router or key ring.
- **Outputs:** `image_version` and `kms_key_id` in the root `environments` map; `managed_resource_ids` in the module.
- **Tests:**
  - `tests/module.tftest.hcl`: child-module tests, with one failing run per validation rule.
  - `tests/provider_plan.tftest.hcl`: every sample config planned against the real providers, offline, with no credentials.
  - YAML edge-case fixtures in `tests/fixtures/`.

### Migration notes

1. **Replace Composer 2 keys in your YAML.** The plan now fails with a message naming the replacement:

   | Old key | Replacement |
   |---|---|
   | `private_environment` | `enable_private_environment: true` (plus `enable_private_builds_only` if needed) |
   | `master_authorized_networks` | `web_server_network_access_control.allowed_ip_ranges` (`value` / `description`) |
   | `network.pods_range_name`, `pods_cidr`, `services_range_name`, `services_cidr` | remove |
   | `data_retention.task_logs_retention_config` | remove |

2. **Fix values the API rejects:** `recovery.snapshot_location` (a `gs://` folder), `recovery.time_zone` (a UTC offset), maintenance windows (≥ 12 h per week, ≥ 4 h per slot) and `retention_days` (30–730). Run `python tests/validate_configs.py <your.yaml>` to list every problem.
3. **Environments created by the previous defaults are Composer 2.** An environment applied without `image_version` runs a Composer 2 image. The provider cannot move it to Composer 3 in place (*"upgrade to composer 3 is not yet supported"*). Create a new Composer 3 environment under a new key, migrate your DAGs and data, then remove the old key.
4. **On the first apply after upgrading**, expect Terraform to:
   - remove the two firewall rules
   - remove the project-level `roles/composer.ServiceAgentV2Ext` binding, and the Artifact Registry KMS binding if CMEK was used
   - remove the subnet's secondary ranges
   - add the Composer service identity

   If Composer 2 environments in the same project relied on that ServiceAgentV2Ext binding, grant it to them separately. The move of `google_service_account_iam_member.composer_agent_sa_user` to `[0]` is handled by a `moved` block and needs no action.

### Verification performed

- `terraform fmt -check -recursive` and `terraform validate` pass on Terraform 1.2.7 (the minimum supported version) and 1.16.4.
- `terraform test` on 1.16.4: 68 runs, all pass. Each of the 39 negative runs was also run without `expect_failures`, to confirm it fails with exactly its intended message.
- All 5 sample configs `plan` against the real google/google-beta 7.31.0 providers without credentials. Before the fixes, 3 of them failed.
- The module's locals were evaluated on Terraform 1.2.7 for every sample environment (no validation errors) and for 44 invalid configs (each produced its intended message). This caught two checks that only passed on newer Terraform, because Terraform 1.2 does not short-circuit `||`.
- `tests/validate_configs.py` passes all new configs and reports the problems above when run against the previous configs.

**Not verified:** no `terraform apply` was run against a real GCP project, because no credentials were available. API-side behaviour such as quotas, organisation policies and the availability of a specific image in a region is only proven by a real apply.

### Sources

- Provider source, v7.31.0: [resource_composer_environment.go](https://github.com/hashicorp/terraform-provider-google-beta/blob/v7.31.0/google-beta/services/composer/resource_composer_environment.go) (Composer 3 field policy, image-version handling, `retention_days` range, `/20` internal range)
- [Create environments (Composer 3)](https://docs.cloud.google.com/composer/docs/composer-3/create-environments) — an image version must be specified; the API default is a Composer 2 image
- [Composer versioning overview](https://docs.cloud.google.com/composer/docs/composer-versioning-overview) — Composer 3 image format and aliases
- [Specify maintenance windows (Composer 3)](https://docs.cloud.google.com/composer/docs/composer-3/specify-maintenance-windows) — 12 hours per week, 4 hours per slot
- [Scale environments (Composer 3)](https://docs.cloud.google.com/composer/docs/composer-3/scale-environments) — per-component count, vCPU, memory and storage limits
- [Highly resilient environments (Composer 3)](https://docs.cloud.google.com/composer/docs/composer-3/set-up-highly-resilient-environments) — scheduler, worker, triggerer and DAG processor counts
- [Configure CMEK encryption (Composer 3)](https://docs.cloud.google.com/composer/docs/composer-3/configure-cmek-encryption) — required service agents and key region
- [Access control (Composer 3)](https://docs.cloud.google.com/composer/docs/composer-3/access-control) — service agent and environment service account roles
- [Change networking type (Composer 3)](https://docs.cloud.google.com/composer/docs/composer-3/change-networking-type) — Public IP / Private IP behaviour; no firewall configuration needed
- [Access the Airflow web interface (Composer 3)](https://docs.cloud.google.com/composer/docs/composer-3/access-airflow-web-interface) — web server network access control
