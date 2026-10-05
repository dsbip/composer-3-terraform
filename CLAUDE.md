# Cloud Composer 3 Terraform Module

## Project Purpose

Terraform module for deploying one or more Google Cloud Composer 3 environments with all dependencies, driven by a single YAML configuration file with global defaults and per-environment overrides.

## Architecture Decisions

### Multi-environment via for_each
- Root module parses the YAML and iterates `environments` map with `for_each`
- Each environment key becomes the module instance key and default environment name
- The child module receives three inputs: `environment_key` (string), `config` (per-env map, `nullable = false` so `my-env:` with no value becomes `{}`), `global_config` (shared defaults)
- Adding/removing environments is a YAML edit — no Terraform code changes needed; `environments:` with no entries plans zero environments (do not make that an error — it is how everything is torn down)
- The root `environments` output has a precondition rejecting two environments that would create the same named resource (built from each module's `managed_resource_ids` output)

### Global → per-environment config merging
- `project_id`, `region`, `enable_apis`, `apis`, `create_composer_environment` resolve as: per-env > global > hardcoded default
- `labels` are merged (global + per-env, per-env wins on conflicts) and stringified
- Values are read with `coalesce(try(var.config.x, null), default)` so an explicit YAML null (`region:`) behaves like an omitted key
- This keeps the YAML DRY — define once at top, override only where needed

### Aggressive defaults
- **Region**: `europe-west2` (hardcoded fallback)
- **Image version**: `composer-3-airflow-2` (latest build of Airflow 2). Always sent explicitly: the Composer API defaults to a **Composer 2** image, and the provider rejects Composer 3-only fields unless `image_version` contains `composer-3`
- **Environment size**: `ENVIRONMENT_SIZE_SMALL`
- **Networking type**: Public IP (`enable_private_environment` unset)
- **Network**: auto-created as `{env-name}-network` / `{env-name}-subnet` (primary range only, Private Google Access). Composer 3 attaches through a PSC network attachment in that subnet — no GKE secondary ranges, no firewall rules
- **Service account**: auto-created as `{env-name}-sa` with minimal roles
- **Workloads**: scheduler (0.5 cpu/2GB), web_server (1 cpu/2GB), worker (1 cpu/2GB, 1-3 autoscale). With `HIGH_RESILIENCE` the defaults become 2 schedulers and min 2 workers, and triggerer/dag_processor blocks default to count 2
- "Existing X" settings flip the matching create flag: `existing_network*` → `network.create = false`, `existing_email` → `service_account.create = false`, `existing_kms_key` → `enable_cmek = true`
- A completely empty environment config (`composer-basic: {}`) produces a working Composer 3 instance

### Optional components
- **Triggerer**: configured only when `workloads.triggerer` is present (dynamic block); otherwise GCP's default applies. `triggerer: {}` = module defaults, `count: 0` = explicitly off
- **DAG Processor**: configured only when `workloads.dag_processor` is present; otherwise GCP sizes it (Composer 3 always runs one)
- **Private IP** (`enable_private_environment`, `enable_private_builds_only`), **Airflow UI allow-list** (`web_server_network_access_control`), **maintenance window**, **encryption**, **recovery**, **data retention**, **data lineage**, **network attachment / internal /20**: all omitted unless configured

### Composer environment on/off (`create_composer_environment`)
- `count` on `google_composer_environment.this` only — no supporting resource (network, NAT, SA, IAM, KMS, APIs, service identity) may depend on the flag or reference the environment resource
- Resolved per-env > global > `true` with `coalesce`, then `try(tobool(...), true)`: an invalid value counts as `true` so the resource exists and its precondition reports it
- Outputs read the environment with `one(google_composer_environment.this[*].x)` (null while off), never `this[0]`
- While off, the `composer_environment_created` output's precondition runs the same validation (the resource and its precondition don't exist) — keep both
- The environment name stays in `managed_resource_ids` while off, so re-enabling can't collide
- `moved { this → this[0] }` in `main.tf` keeps environments created before `count` existed (Terraform also does this implicitly)

### Validation layer (`modules/composer-3/validation.tf`)
- The provider skips validation of everything nested under `config` while any value there is unknown at plan time — always true here (network/SA created in the same run). So invalid nested values would only fail at apply, after other resources exist
- `validation.tf` builds `validation_checks` (`{ ok, message }` list) and `workload_checks`; one precondition on `google_composer_environment.this` (or, while it is switched off, on the `composer_environment_created` output) reports every failure, naming the environment
- Preconditions test `local.configuration_valid`, which is derived from `local.validation_error_message`: Terraform 1.2/1.3 order an output after what its precondition's *condition* references but not its `error_message`, so a message local referenced only in `error_message` may be unevaluated (1.2.7 printed "Failed to evaluate condition error message."). Resource preconditions don't have this problem
- **Expressions must be null-safe on Terraform 1.2**: it does not short-circuit `||`/`&&`, so `x == null || contains(list, x)` still errors. Wrap the right side in `try()`/`can()`, use `jsonencode()` in messages. Terraform 1.16 short-circuits, so tests alone won't catch this — evaluate with 1.2 (`terraform console -var-file=...` in a copy of the module)
- Rejects Composer 2 keys (`private_environment`, `master_authorized_networks`, `network.pods_*`/`services_*`, `data_retention.task_logs_retention_config`) with the replacement named
- `workload_limits` encodes Composer 3's per-component limits (Scale environments docs): counts, vCPU range/step, memory range (higher minimum on Airflow 3 images), 1–8 GB per vCPU, storage 0–100
- Resources that could crash on invalid input before the precondition runs must be gated (e.g. SA IAM bindings use `local.service_account_configured`)
- `tests/validate_configs.py` mirrors these rules — keep the two in sync

### Provider choice: google-beta
- `google_composer_environment` uses `google-beta` for full Composer 3 feature support
- `google_project_service_identity` is beta-only as well
- Other resources (network, IAM, KMS) use `google` provider
- Both pinned to `>= 6.0.0` (lock file: 7.31.0)

### IAM bindings
- The Composer service agent is generated up front (`google_project_service_identity.composer`) so bindings to it work on the first apply in a fresh project
- `roles/iam.serviceAccountUser` → Composer service agent on the environment's SA (addressed in the SA's own project when it is an existing SA)
- KMS encrypter/decrypter → Composer service agent and Cloud Storage service agent only (the two Composer 3 requires; GCS agent comes from `data.google_storage_project_service_account`, which creates it)
- `roles/composer.ServiceAgentV2Ext` is deliberately **not** granted — Composer 2 only; project-wide it is over-broad and was shared across environments

### API enablement idempotency
- Each module instance enables APIs independently via `google_project_service`
- `disable_on_destroy = false` makes this safe for multi-environment in the same project
- Feature APIs are added automatically: `cloudkms` with CMEK, `datalineage` with data lineage
- Duplicate enablement requests are idempotent

## Key Files

| File | Purpose |
|---|---|
| `main.tf` (root) | YAML parsing, global config extraction, `for_each` module invocation, collision detection |
| `outputs.tf` (root) | `environments` map + collision precondition |
| `modules/composer-3/locals.tf` | Global merging, all defaults, derived values |
| `modules/composer-3/validation.tf` | Plan-time configuration checks |
| `modules/composer-3/main.tf` | `google_composer_environment` with all dynamic blocks + validation precondition |
| `modules/composer-3/variables.tf` | `environment_key`, `config`, `global_config` inputs |
| `modules/composer-3/iam.tf` | Service account + Composer agent IAM |
| `modules/composer-3/services.tf` | API enablement + Composer service identity |
| `modules/composer-3/network.tf` | VPC, subnet, Cloud Router + NAT |
| `modules/composer-3/kms.tf` | CMEK key ring, key, IAM grants |
| `CHANGELOG.md` | Review findings, migration notes, sources |

## YAML Config Structure

```yaml
project_id: "..."       # Global (required)
region: "europe-west2"  # Global default
labels: {}              # Global labels (merged with per-env)

environments:
  env-name:             # Key = default environment name & SA name prefix
    # All fields optional — override globals or module defaults here
```

Full field reference: `usage.md` → "Complete YAML Input Definition". It is generated in an aligned tree style (tag at column 45, text at column 56); keep that layout when editing.

## Composer 3 vs Composer 2

- Image versions: `composer-3-airflow-X[.Y[.Z]][-build.N]`; aliases resolve to the latest matching build. In-place upgrade from a Composer 2 image is impossible (provider: "upgrade to composer 3 is not yet supported")
- Provider-enforced Composer 3 policy (`versionValidationCustomizeDiffFunc`):
  - Only in Composer 3: `dag_processor`, `enable_private_environment`, `enable_private_builds_only`, `composer_network_attachment`, `composer_internal_ipv4_cidr_block` (must be /20), `web_server_plugins_mode`
  - Not in Composer 3: `private_environment_config`, `master_authorized_networks_config`, `max_pods_per_node`, `enable_ip_masq_agent`; `ip_allocation_policy` is also Composer 2 only (the provider's check for it has a typo'd key, so it isn't caught at plan)
- Not supported in Composer 3: `data_retention_config.task_logs_retention_config`; `airflow_metadata_retention_config.retention_days` is 30–730
- `resilience_mode: HIGH_RESILIENCE`: exactly 2 schedulers, ≥ 2 workers, ≥ 2 DAG processors, 0 or ≥ 2 triggerers
- Workload limits: schedulers 1–3 × 0.5–2 vCPU; triggerers 0–10 × 0.5–1 vCPU (≥ 1 GB, 2 GB on Airflow 3); web server 1–4 vCPU; workers 1–100; DAG processors 1–3; 1–8 GB memory per vCPU everywhere
- Networking: Public IP / Private IP (`enable_private_environment`); optional VPC attachment via network+subnetwork or a network attachment; no user-visible GKE cluster, no firewall rules needed
- Airflow UI access restriction: `web_server_network_access_control` (IPv4/IPv6 allow-list)

## Testing Strategy

- `terraform fmt -check -recursive` — formatting
- `terraform validate` — syntax and configuration (root + `tests/setup`); runs on the minimum version 1.2.7 too
- `python tests/validate_configs.py [files]` — YAML validation (all `configs/*.yaml` by default); mirrors `validation.tf`, adds maintenance-window maths, collision and unknown-key warnings
- `terraform test` (Terraform >= 1.7 for `mock_provider`):
  - `basic`, `production`, `validation` — root module with mocks; `validation` also covers `tests/fixtures/*.yaml`
  - `module.tftest.hcl` — child module via `module { source = "./modules/composer-3" }`; one `expect_failures` run per validation rule
  - `create_composer_environment.tftest.hcl` — child module; plan runs for the flag plus `command = apply` runs (on → off → on) sharing state. Apply with mocks needs realistic `defaults` for values the provider format-checks (SA name/email/member, GCS agent member) and a fixed `google_project.number` (a random one per run makes IAM members look changed). Mocks never force replacements, so unchanged IDs only rule out Terraform-level recreation
  - `provider_plan.tftest.hcl` — **real** providers, offline (fake `access_token`, `override_data` for `data.google_project.this`); the only tests that exercise the provider's CustomizeDiff rules
  - On Windows, `-filter` takes backslash paths (`-filter=tests\module.tftest.hcl`); a failed run skips the rest of its file
- `terraform plan` — requires GCP credentials (validates provider interaction)

## Common Gotchas

- KMS keys have `prevent_destroy = true` — remove lifecycle or state-rm before full destroy
- `terraform test` `expect_failures` only proves *some* check failed — when adding a validation rule, confirm the run fails with the intended message
- CIDR ranges: each env creates its own VPC so defaults don't conflict; customise `subnetwork_cidr` / `composer_internal_ipv4_cidr_block` when sharing VPCs or connecting to other networks
- `airflow_config_overrides` keys use `section-key` format (hyphen, not dot)
- `recovery.snapshot_location` is a `gs://` folder and `recovery.time_zone` a UTC offset (`UTC+01`), not a region / IANA name
- Maintenance windows need ≥ 12 h per week and ≥ 4 h per slot (e.g. 4 h on `FR,SA,SU`)
- Empty env value (`my-env: {}` or `my-env:`) is valid — all settings default
- `create_composer_environment: false` deletes the Airflow database with the environment (snapshots and the bucket are kept); a recreated environment gets a new bucket unless `storage.bucket` is set — set it only while the environment is off (`bucket` is ForceNew)
- Removing `roles/composer.ServiceAgentV2Ext` is intentional; Composer 2 environments in the same project must get it from elsewhere
