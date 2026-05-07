# Cloud Composer 3 Terraform Module

## Project Purpose

Terraform module for deploying one or more Google Cloud Composer 3 environments with all dependencies, driven by a single YAML configuration file with global defaults and per-environment overrides.

## Architecture Decisions

### Multi-environment via for_each
- Root module parses the YAML and iterates `environments` map with `for_each`
- Each environment key becomes the module instance key and default environment name
- The child module receives three inputs: `environment_key` (string), `config` (per-env map), `global_config` (shared defaults)
- Adding/removing environments is a YAML edit — no Terraform code changes needed

### Global → per-environment config merging
- `project_id`, `region`, `enable_apis`, `apis` resolve as: per-env > global > hardcoded default
- `labels` are merged (global + per-env, per-env wins on conflicts)
- This keeps the YAML DRY — define once at top, override only where needed

### Aggressive defaults
- **Region**: `europe-west2` (hardcoded fallback)
- **Environment size**: `ENVIRONMENT_SIZE_SMALL`
- **Network**: auto-created as `{env-name}-network` / `{env-name}-subnet` with standard CIDRs
- **Service account**: auto-created as `{env-name}-sa` with minimal roles
- **Image version**: `null` → GCP picks the latest stable Composer 3 image
- **Workloads**: scheduler (0.5 cpu/2GB), web_server (1 cpu/2GB), worker (1 cpu/2GB, 1-3 autoscale)
- A completely empty environment config (`composer-basic: {}`) produces a working Composer instance

### Optional components
- **Triggerer**: only created when `workloads.triggerer` block is present in YAML (dynamic block)
- **DAG Processor**: only created when `workloads.dag_processor` block is present
- **Private environment**, **maintenance window**, **encryption**, **recovery**, **data retention**: all omitted unless configured

### Provider choice: google-beta
- `google_composer_environment` uses `google-beta` for full Composer 3 feature support
- Other resources (network, IAM, KMS) use `google` provider
- Both pinned to `>= 6.0.0`

### IAM bindings
Three critical bindings beyond the SA's own roles:
1. `roles/composer.ServiceAgentV2Ext` → Composer service agent on the project
2. `roles/iam.serviceAccountUser` → Composer service agent on the environment's SA
3. KMS encrypter/decrypter → Composer, Artifact Registry, and GCS agents (when CMEK enabled)

### API enablement idempotency
- Each module instance enables APIs independently via `google_project_service`
- `disable_on_destroy = false` makes this safe for multi-environment in the same project
- Duplicate enablement requests are idempotent

## Key Files

| File | Purpose |
|---|---|
| `main.tf` (root) | YAML parsing, global config extraction, `for_each` module invocation |
| `modules/composer-3/locals.tf` | Global merging, all defaults, derived values |
| `modules/composer-3/main.tf` | `google_composer_environment` with all dynamic blocks |
| `modules/composer-3/variables.tf` | `environment_key`, `config`, `global_config` inputs |
| `modules/composer-3/iam.tf` | Service account + Composer agent IAM |
| `modules/composer-3/network.tf` | VPC, subnet, Cloud NAT, firewall |
| `modules/composer-3/kms.tf` | CMEK key ring, key, IAM grants |

## YAML Config Structure

```yaml
project_id: "..."       # Global (required)
region: "europe-west2"  # Global default
labels: {}              # Global labels (merged with per-env)

environments:
  env-name:             # Key = default environment name & SA name prefix
    # All fields optional — override globals or module defaults here
```

## Composer 3 vs Composer 2

- Image versions: `composer-3-airflow-*` format
- `dag_processor`: new workload component (optional, dynamic block)
- `data_retention_config`: metadata + task log retention
- `resilience_mode`: multi-zone HA
- `connection_type: PRIVATE_SERVICE_CONNECT`: alternative to VPC peering
- Infrastructure fully managed by Google (no user-visible GKE cluster)

## Testing Strategy

- `terraform fmt -check -recursive` — formatting
- `terraform validate` — syntax and configuration (root + test modules)
- `python tests/validate_configs.py` — YAML structure/constraint validation for all 5 configs
- `tests/*.tftest.hcl` — native tests with mock providers (Terraform >= 1.6)
- `terraform plan` — requires GCP credentials (validates provider interaction)

## Common Gotchas

- KMS keys have `prevent_destroy = true` — remove lifecycle or state-rm before full destroy
- Composer service agent SA only exists after Composer API is enabled — may need two applies
- CIDR ranges: each env creates its own VPC so defaults don't conflict; customise if sharing VPCs
- `airflow_config_overrides` keys use `section-key` format (hyphen, not dot)
- Empty env value (`my-env: {}`) is valid — all settings default
- `image_version: null` (default) lets GCP pick the latest stable version
