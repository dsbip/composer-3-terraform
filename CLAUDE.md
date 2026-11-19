# Cloud Composer 3 Terraform Module

## Project Purpose

Terraform module for deploying one or more Google Cloud Composer 3 environments with all dependencies, driven by a single YAML configuration file with global defaults and per-environment overrides.

## Architecture Decisions

### Multi-environment via for_each
- Root module parses the YAML and iterates `environments` map with `for_each`
- Each environment key becomes the module instance key and default environment name
- The child module receives `environment_key` (string), `config` (per-env map), `global_config` (shared defaults) and `fallback_image_version` (only fills a null YAML `image_version`; set by the hibernation startup)
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
- **Image version**: `null` → GCP picks its default image (may still be Composer 2 during Google's rollout — pin one, see gotchas)
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

### Hibernation (scheduled snapshot + delete / recreate + load)
- Opt-in per env via the `hibernation` block (global → per-env merge); refused for production (labels `env|environment|tier|stage` = `prod|production|prd`, else a prod token in the name) by the scripts and by a precondition on `google_composer_environment.this` (create/update plans only — Terraform skips preconditions in destroy plans, so shutdown relies on the scripts' check)
- `modules/composer-3-settings` is provider-less and the single source of truth for identity/labels/hibernation resolution; `modules/composer-3` uses it, and `scripts/hibernation/resolver` evaluates it offline so the bash scripts never re-implement YAML defaults
- Shutdown deletes ONLY `google_composer_environment` (resource-level `-target` in destroy mode is instance-precise); network/SA/IAM/KMS stay
- Startup targets the whole module instance `module.composer["<key>"]` — resource-level create targets pull in same-named dependencies of ALL instances (verified), leaking other envs' pending changes
- Plans are guarded (`guard_destroy_plan`, `guard_create_plan`, `plan_must_contain`) — a typo'd `-target` silently plans nothing
- `var.fallback_image_versions` (root) / `fallback_image_version` (module) only fill a null YAML `image_version`; startup sets it to the snapshot's `composer-3-airflow-X.Y.Z` (snapshots load only into same-or-later Airflow)
- Per-env state file `<snapshot_location>/hibernation-state.json` (NONE → SNAPSHOT_SAVED → HIBERNATED → RESTORING → ACTIVE) makes both scripts idempotent; see `decide_*_action` in `scripts/hibernation/lib/common.sh`
- Shutdown checks the state's project/region/name equals the YAML's before snapshotting (`check_state_identity`) and the destroy plan's `change.before` again (`plan_deletes_identity`); two keys resolving to one environment are refused
- Restore point: `decide_restore_point` keeps the old one when the env never received it (RESTORING without a completed `restore_attempt`, or re-created while HIBERNATED/SNAPSHOT_SAVED — uuid differs); envs older than `HIBERNATE_FRESH_ENV_HOURS` (96) hold real work, so startup refuses to load over them (`refuse_stale`; `--skip-load`/`--force-load`)
- The work dir's `actions/`, `state/`, `results/` drive a run, so `init_work_dir` refuses a non-empty one (CI uses `.hibernation/<job>-<job id>`)

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
| `modules/composer-3/variables.tf` | `environment_key`, `config`, `global_config`, `fallback_image_version` inputs |
| `modules/composer-3/iam.tf` | Service account + Composer agent IAM |
| `modules/composer-3/network.tf` | VPC, subnet, Cloud NAT, firewall |
| `modules/composer-3/kms.tf` | CMEK key ring, key, IAM grants |
| `modules/composer-3-settings/main.tf` | Provider-less resolution: identity, labels, prod detection, hibernation defaults + `validation_errors` |
| `scripts/hibernation/composer-shutdown.sh` | Snapshot → verify → guarded targeted destroy → state file |
| `scripts/hibernation/composer-startup.sh` | Guarded targeted apply from the YAML → version check → snapshot load |
| `scripts/hibernation/lib/common.sh` | Shared bash library (resolver, gcloud/terraform helpers, plan guards, decision tables, state file) |
| `pipelines/composer-hibernation.yml` | Scheduled GitLab jobs (`HIBERNATE_ACTION=shutdown|startup`) |
| `docs/hibernation.md` | Operator guide for hibernation |

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
- `tests/hibernation/run.sh` — shellcheck, GitLab CI schema + rule evaluation, bats unit/resolver/schedule tests and the e2e suite (real Terraform plans offline via `tests/hibernation/tools/stub_google_api.py`; only `apply` and GCP are simulated by `tests/hibernation/fakes/`)
- `python tests/validate_configs.py` — YAML structure/constraint validation for every file in `configs/`
- `tests/*.tftest.hcl` — native tests with mock providers (Terraform >= 1.7); `expect_failures` cannot reference resources inside child modules, so module preconditions are tested with `module { source = "./modules/composer-3" }` runs
- `terraform plan` — requires GCP credentials (validates provider interaction)

## Common Gotchas

- KMS keys have `prevent_destroy = true` — remove lifecycle or state-rm before full destroy
- Composer service agent SA only exists after Composer API is enabled — may need two applies
- CIDR ranges: each env creates its own VPC so defaults don't conflict; customise if sharing VPCs
- `airflow_config_overrides` keys use `section-key` format (hyphen, not dot)
- Empty env value (`my-env: {}`) is valid — all settings default
- `image_version: null` (default) lets GCP pick its default image — Google is still rolling out the switch of that default from Composer 2 to 3, so pin an alias like `composer-3-airflow-2.10.5` (required in practice for hibernating envs; builds are only creatable for 12-18 months)
- GA gcloud has no `list-image-versions`; use the Composer REST `imageVersions` endpoint (`creationDisabled`)
- Hibernation scripts need the gcs backend: `TF_BACKEND_BUCKET`/`TF_BACKEND_PREFIX` (a git-ignored `backend_override.tf` is generated; `-backend-config` without a backend block silently falls back to local state, so init is verified)
- While an env is hibernated, a normal full apply recreates it empty; the next startup loads the snapshot into it
