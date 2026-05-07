# Cloud Composer 3 Terraform Module — Usage Guide

## Overview

This Terraform module deploys one or more **Google Cloud Composer 3** environments from a single YAML configuration file. It creates all required dependencies automatically:

| Resource | Description |
|---|---|
| **Composer Environment(s)** | Cloud Composer 3 with configurable workloads, software, and networking |
| **VPC Network + Subnet** | Dedicated network per environment with secondary IP ranges |
| **Service Account + IAM** | Auto-named SA (`{env-name}-sa`) with Composer agent bindings |
| **Cloud NAT + Router** | Outbound internet access for private environments |
| **Firewall Rules** | Internal communication + GCP health-check ranges |
| **KMS Key Ring + Key** | Customer-managed encryption key (CMEK) — optional |
| **GCP API Enablement** | Automatically enables required APIs |

Almost every setting has a sensible default. A minimal config needs only `project_id` and an environment key.

---

## Prerequisites

- **Terraform** >= 1.2.0
- **Google Cloud Provider** >= 6.0.0
- A GCP project with billing enabled
- Authenticated `gcloud` CLI or a service account key
- Required roles on the deploying identity:
  - `roles/composer.admin`
  - `roles/compute.networkAdmin`
  - `roles/iam.serviceAccountAdmin`
  - `roles/iam.serviceAccountUser`
  - `roles/resourcemanager.projectIamAdmin`
  - `roles/cloudkms.admin` (only if using CMEK)

---

## Quick Start

### 1. Create a minimal config

```yaml
# configs/my-env.yaml
project_id: "my-gcp-project"

environments:
  my-composer: {}
```

That's it. Everything else uses defaults: region `europe-west2`, size `SMALL`, auto-created network and service account, latest Composer 3 image.

### 2. Deploy

```bash
terraform init
terraform plan  -var 'config_file=configs/my-env.yaml'
terraform apply -var 'config_file=configs/my-env.yaml'
```

### 3. Verify

```bash
terraform output environments
```

---

## YAML Configuration Structure

The YAML file has two levels: **global defaults** and **per-environment overrides**.

```yaml
# ── Global defaults (apply to all environments) ──────────────
project_id: "my-gcp-project"          # REQUIRED
region: "europe-west2"                  # Default: europe-west2
labels:
  managed_by: terraform

# ── Environments (one or more) ───────────────────────────────
environments:
  composer-dev:                         # Key = environment name
    # ... per-env config (all optional)

  composer-prod:
    # ... per-env config (all optional)
```

### Resolution order

Per-environment values override global values. For labels, global and per-env labels are merged (per-env wins on conflicts).

---

## Complete YAML Input Definition

This section documents **every input** the YAML config file accepts. Each field shows whether it is `[Required]` or `[Optional]`, its default value, and a description.

```
composer_environments:
  ──────────────────────────────────────────────────────────────────────────────────────────────────

  GLOBAL-LEVEL FIELDS (root of YAML file, apply to all environments unless overridden)
  ──────────────────────────────────────────────────────────────────────────────────────────────────

  project_id:                                [Required] The GCP project ID where all resources are
                                                        created. Can be overridden per-environment.

  region:                                    [Optional] GCP region for all environments. Can be
                                                        overridden per-environment.
                                                        Default: "europe-west2"

  enable_apis:                               [Optional] Whether to auto-enable required GCP APIs
                                                        (composer, compute, iam, cloudresourcemanager,
                                                        serviceusage). Set false if managed externally.
                                                        Default: true

  apis:                                      [Optional] Additional GCP API service names to enable
                                                        beyond the defaults (e.g. "bigquery.googleapis.com").
                                                        Default: []

  labels:                                    [Optional] Key/value labels applied to all environments.
      key: value                                        Merged with per-env labels (per-env wins on
                                                        key conflicts).
                                                        Default: {}

  environments:                              [Required] Map of Composer environments to create.
                                                        Each key becomes the default environment name.
                                                        An empty value {} is valid and uses all defaults.
                                                        At least one environment must be defined.

  ──────────────────────────────────────────────────────────────────────────────────────────────────

  PER-ENVIRONMENT FIELDS (under environments.<env-key>:, ALL fields are optional)
  ──────────────────────────────────────────────────────────────────────────────────────────────────

      [ENVIRONMENT_KEY]:                     [Required] The map key. Used as the default environment
                                                        name, service account name prefix ({key}-sa),
                                                        network name prefix ({key}-network), and subnet
                                                        name prefix ({key}-subnet). Must be lowercase
                                                        alphanumeric with hyphens.

      ── Identity & Sizing ────────────────────────────────────────────────────────────────────────

          environment_name:                  [Optional] Override the Composer environment name. If
                                                        omitted, the map key is used as the name.
                                                        Default: ENVIRONMENT_KEY

          project_id:                        [Optional] Override the GCP project for this specific
                                                        environment.
                                                        Default: inherits global project_id

          region:                            [Optional] Override the GCP region for this environment.
                                                        Default: inherits global region -> "europe-west2"

          environment_size:                  [Optional] Composer environment size tier. Controls
                                                        baseline resource allocation managed by GCP.
                                                        Allowed: "ENVIRONMENT_SIZE_SMALL",
                                                                 "ENVIRONMENT_SIZE_MEDIUM",
                                                                 "ENVIRONMENT_SIZE_LARGE"
                                                        Default: "ENVIRONMENT_SIZE_SMALL"

          resilience_mode:                   [Optional] Set to "HIGH_RESILIENCE" to enable multi-zone
                                                        redundancy for the scheduler, database, and
                                                        web server.
                                                        Allowed: "STANDARD_RESILIENCE", "HIGH_RESILIENCE"
                                                        Default: not set (standard resilience)

          labels:                            [Optional] Key/value labels for this environment. Merged
              key: value                                with global labels; per-env wins on conflicts.
                                                        Default: {}

          enable_apis:                       [Optional] Override API enablement for this environment.
                                                        Default: inherits global enable_apis -> true

          apis:                              [Optional] Override additional APIs for this environment.
                                                        Default: inherits global apis -> []

      ── Network ──────────────────────────────────────────────────────────────────────────────────
      (entire block optional; when omitted, a dedicated VPC is created per environment)

          network:
              create:                        [Optional] Whether to create a new VPC network and subnet.
                                                        Set false to use an existing network (provide
                                                        existing_network and existing_subnetwork).
                                                        Default: true

              name:                          [Optional] Name of the VPC network to create. Only used
                                                        when create: true.
                                                        Default: "{env-name}-network"

              subnetwork_name:               [Optional] Name of the subnet to create. Only used when
                                                        create: true.
                                                        Default: "{env-name}-subnet"

              subnetwork_cidr:               [Optional] Primary CIDR range for the subnet. Used for
                                                        Composer infrastructure nodes.
                                                        Default: "10.0.0.0/24"

              existing_network:              [Optional] Full self-link of an existing VPC network.
                                                        Required when create: false. Format:
                                                        projects/{project}/global/networks/{name}
                                                        Default: null

              existing_subnetwork:           [Optional] Full self-link of an existing subnet. Required
                                                        when create: false. Must have secondary ranges
                                                        matching pods_range_name and services_range_name.
                                                        Format: projects/{p}/regions/{r}/subnetworks/{n}
                                                        Default: null

              pods_range_name:               [Optional] Name of the secondary IP range for GKE pods.
                                                        When using an existing subnet, must match an
                                                        existing secondary range name.
                                                        Default: "pods"

              pods_cidr:                     [Optional] CIDR range for the pods secondary range. Only
                                                        used when create: true. A /16 provides ~65k IPs.
                                                        Default: "10.1.0.0/16"

              services_range_name:           [Optional] Name of the secondary IP range for GKE services.
                                                        When using an existing subnet, must match an
                                                        existing secondary range name.
                                                        Default: "services"

              services_cidr:                 [Optional] CIDR range for the services secondary range.
                                                        Only used when create: true. A /20 provides ~4k.
                                                        Default: "10.2.0.0/20"

              enable_cloud_nat:              [Optional] Whether to create a Cloud Router and Cloud NAT
                                                        for outbound internet access. Set true when using
                                                        private environments so workers can reach PyPI.
                                                        Default: false

              tags:                          [Optional] Network tags applied to Composer nodes. Used as
                  - "composer"                          targets for the auto-created firewall rules.
                                                        Default: ["composer"]

          When create: true, the module also creates:
            - Firewall rule allowing internal TCP/UDP/ICMP between all CIDR ranges
            - Firewall rule allowing GCP health check source ranges (35.191.0.0/16, 130.211.0.0/22)
            - (If enable_cloud_nat: true) Cloud Router + Cloud NAT with auto-allocated IPs

      ── Service Account ──────────────────────────────────────────────────────────────────────────
      (entire block optional; when omitted, SA auto-created as {env-name}-sa)

          service_account:
              create:                        [Optional] Whether to create a new service account. Set
                                                        false to use an existing one.
                                                        Default: true

              name:                          [Optional] The account_id for the new SA (max 30 chars,
                                                        lowercase alphanumeric + hyphens). Only used
                                                        when create: true.
                                                        Default: "{env-name}-sa"

              existing_email:                [Optional] Email of an existing SA. Required when
                                                        create: false. Format: name@project.iam...
                                                        Default: null

              roles:                         [Optional] IAM roles granted to the SA on the project.
                  - "roles/composer.worker"             roles/composer.worker is required for Composer
                  - "roles/logging.logWriter"           to function — always include it.
                  - "roles/monitoring.metricWriter"     Default: [roles/composer.worker,
                                                                  roles/logging.logWriter,
                                                                  roles/monitoring.metricWriter]

          Automatic IAM bindings (always created, not configurable):
            - roles/composer.ServiceAgentV2Ext -> Composer service agent on the project
            - roles/iam.serviceAccountUser     -> Composer service agent on the env SA

      ── Software Configuration ───────────────────────────────────────────────────────────────────
      (entire block optional; when omitted, GCP selects the latest stable Composer 3 image)

          software_config:
              image_version:                 [Optional] Composer image version string. When omitted,
                                                        GCP selects the latest stable Composer 3 version.
                                                        Must start with "composer-3" if provided. Check
                                                        available: gcloud composer environments
                                                        list-image-versions --location=REGION
                                                        Default: null (GCP picks latest)

              airflow_config_overrides:      [Optional] Airflow configuration property overrides.
                  section-key: "value"                  Keys use section-key format with a HYPHEN
                                                        separator (not dot). Example: core-dags_are_
                                                        paused_at_creation maps to [core] dags_are_
                                                        paused_at_creation in airflow.cfg. Values
                                                        must be strings.
                                                        Default: {}

              env_variables:                 [Optional] Environment variables injected into all
                  key: "value"                          Airflow components. Available in DAGs via
                                                        os.environ. Do not use for secrets.
                                                        Default: {}

              pypi_packages:                 [Optional] Additional PyPI packages to install. Keys
                  package_name: ">=1.0.0"               are package names, values are version specifiers
                                                        (e.g. ">=10.0.0", "==2.1.0", ""). To install
                                                        without pinning, use empty string as value.
                                                        Default: {}

      ── Workloads ────────────────────────────────────────────────────────────────────────────────
      (entire block optional; scheduler, web_server, worker always created with defaults;
       triggerer and dag_processor ONLY created when their block is explicitly present)

          workloads:

              scheduler:                     [Optional] Parses DAGs and schedules task execution.
                                                        Always created.
                  cpu:                       [Optional] vCPUs allocated to each scheduler instance.
                                                        Default: 0.5
                  memory_gb:                 [Optional] Memory in GB per scheduler instance.
                                                        Default: 2
                  storage_gb:                [Optional] Storage in GB per scheduler instance.
                                                        Default: 1
                  count:                     [Optional] Number of scheduler instances. Set to 2
                                                        for high availability.
                                                        Default: 1

              web_server:                    [Optional] Serves the Airflow UI. Always created
                                                        (single instance).
                  cpu:                       [Optional] vCPUs allocated to the web server.
                                                        Default: 1
                  memory_gb:                 [Optional] Memory in GB for the web server.
                                                        Default: 2
                  storage_gb:                [Optional] Storage in GB for the web server.
                                                        Default: 1

              worker:                        [Optional] Executes Airflow tasks. Always created with
                                                        autoscaling between min_count and max_count.
                  cpu:                       [Optional] vCPUs allocated to each worker instance.
                                                        Default: 1
                  memory_gb:                 [Optional] Memory in GB per worker instance.
                                                        Default: 2
                  storage_gb:                [Optional] Storage in GB per worker instance.
                                                        Default: 1
                  min_count:                 [Optional] Minimum number of workers (always running).
                                                        Default: 1
                  max_count:                 [Optional] Maximum number of workers (autoscale ceiling).
                                                        Default: 3

              triggerer:                     [Optional] Monitors deferred tasks and resumes them when
                                                        conditions are met (e.g. sensor completion).
                                                        ** ONLY created when this block is present. **
                                                        Omit the entire triggerer: key to skip creation.
                  cpu:                       [Optional] vCPUs per triggerer instance.
                                                        Default: 0.5 (when block present)
                  memory_gb:                 [Optional] Memory in GB per triggerer instance.
                                                        Default: 0.5 (when block present)
                  count:                     [Optional] Number of triggerer instances.
                                                        Default: 1 (when block present)

              dag_processor:                 [Optional] Separate process for parsing DAG files
                                                        (Composer 3 feature).
                                                        ** ONLY created when this block is present. **
                                                        Omit the entire dag_processor: key to skip.
                  cpu:                       [Optional] vCPUs per DAG processor instance.
                                                        Default: 1 (when block present)
                  memory_gb:                 [Optional] Memory in GB per DAG processor instance.
                                                        Default: 2 (when block present)
                  storage_gb:                [Optional] Storage in GB per DAG processor instance.
                                                        Default: 1 (when block present)
                  count:                     [Optional] Number of DAG processor instances.
                                                        Default: 1 (when block present)

      ── Private Environment ──────────────────────────────────────────────────────────────────────
      (entire block optional; omit for public IP networking)

          private_environment:
              enable_private_endpoint:       [Optional] When true, the Airflow web server has no
                                                        public IP. Requires VPN, bastion, or IAP.
                                                        When true, also set network.enable_cloud_nat
                                                        to true for outbound connectivity.
                                                        Default: false

              cloud_sql_ipv4_cidr_block:     [Optional] CIDR block for the Cloud SQL instance. Must
                                                        not overlap with other ranges.
                                                        Default: null (GCP auto-assigns)

              web_server_ipv4_cidr_block:    [Optional] CIDR block for the Airflow web server.
                                                        Default: null (GCP auto-assigns)

              master_ipv4_cidr_block:        [Optional] CIDR block for the GKE control plane. Must
                                                        be a /28 range.
                                                        Default: null (GCP auto-assigns)

              cloud_composer_network_ipv4_cidr_block:
                                             [Optional] CIDR block for the Cloud Composer networking
                                                        infrastructure.
                                                        Default: null (GCP auto-assigns)

              enable_privately_used_public_ips:
                                             [Optional] When true, allows using publicly-routable IP
                                                        ranges for private GKE endpoints.
                                                        Default: false

              connection_type:               [Optional] Network connection type.
                                                        "VPC_PEERING" creates a VPC peering connection.
                                                        "PRIVATE_SERVICE_CONNECT" uses PSC (recommended
                                                        for Composer 3).
                                                        Default: "VPC_PEERING"

      ── Master Authorized Networks ───────────────────────────────────────────────────────────────
      (entire block optional; omit for no restrictions on control plane access)

          master_authorized_networks:
              enabled:                       [Optional] Whether master authorized networks are enforced.
                                                        Default: true (when block present)

              cidr_blocks:                   [Optional] List of CIDR blocks allowed to access the
                                                        GKE control plane.
                                                        Default: []
                  - display_name:            [Required] Human-readable name (e.g. "office-vpn").
                    cidr_block:              [Required] IP range in CIDR notation (e.g. "10.0.0.0/8").

      ── Maintenance Window ───────────────────────────────────────────────────────────────────────
      (entire block optional; omit to let GCP schedule maintenance at any time)

          maintenance_window:
              start_time:                    [Required] Start time in RFC 3339 format. Only the
                                                        time-of-day matters; the date is an anchor.
                                                        Example: "2024-01-01T02:00:00Z"

              end_time:                      [Required] End time in RFC 3339 format. Must be same
                                                        day as start_time. Window must be >= 4 hours.
                                                        Example: "2024-01-01T06:00:00Z"

              recurrence:                    [Required] Recurrence rule in RFC 5545 RRULE format.
                                                        Example: "FREQ=WEEKLY;BYDAY=SU" (every Sunday)

      ── Encryption (CMEK) ────────────────────────────────────────────────────────────────────────
      (entire block optional; omit for GCP-managed encryption)

          encryption:
              enable_cmek:                   [Optional] Whether to enable customer-managed encryption
                                                        keys. When true, creates a new KMS key or uses
                                                        an existing one.
                                                        Default: false

              kms_key_ring_name:             [Optional] Name of the KMS key ring to create. Only used
                                                        when enable_cmek: true and existing_kms_key is
                                                        not set. Created in the same region.
                                                        Default: "{env-name}-keyring"

              kms_key_name:                  [Optional] Name of the KMS crypto key to create. Only
                                                        used when enable_cmek: true and existing_kms_key
                                                        is not set.
                                                        Default: "{env-name}-key"

              kms_key_rotation_period:       [Optional] Automatic key rotation period in seconds.
                                                        Only used for newly created keys.
                                                        Default: "7776000s" (90 days)

              existing_kms_key:              [Optional] Full resource ID of an existing KMS key. When
                                                        provided, no new key is created. Format:
                                                        projects/{p}/locations/{r}/keyRings/{kr}/
                                                        cryptoKeys/{k}
                                                        Default: null

          Automatic IAM bindings (created when CMEK enabled):
            - roles/cloudkms.cryptoKeyEncrypterDecrypter -> Composer agent, AR agent, GCS agent

          Note: KMS keys created by the module have prevent_destroy = true. To destroy, remove the
          lifecycle block from modules/composer-3/kms.tf or use terraform state rm first.

      ── Recovery ─────────────────────────────────────────────────────────────────────────────────
      (entire block optional; omit for no scheduled snapshots)

          recovery:
              enable_scheduled_snapshots:    [Optional] Whether scheduled snapshots are enabled.
                                                        Default: true (when block present)

              snapshot_location:             [Optional] GCP region where snapshots are stored.
                                                        Default: same as environment region

              snapshot_creation_schedule:    [Optional] Cron expression for snapshot creation.
                                                        Standard 5-field cron format.
                                                        Default: "0 3 * * *" (3 AM daily)

              time_zone:                     [Optional] Time zone for the cron schedule. Uses IANA
                                                        names (e.g. "America/Chicago", "Europe/London").
                                                        Default: "UTC"

      ── Data Retention ───────────────────────────────────────────────────────────────────────────
      (entire block optional; omit for GCP default retention behaviour)

          data_retention:
              airflow_metadata_retention_config:
                  retention_mode:            [Optional] Whether metadata retention is active.
                                                        Allowed: "RETENTION_MODE_ENABLED",
                                                                 "RETENTION_MODE_DISABLED"
                                                        Default: "RETENTION_MODE_ENABLED"

                  retention_days:            [Optional] Number of days to retain Airflow metadata
                                                        (DAG runs, task instances) before cleanup.
                                                        Default: 30

              task_logs_retention_config:
                  storage_mode:              [Optional] Where task logs are stored.
                                                        "CLOUD_LOGGING_AND_CLOUD_STORAGE" writes to
                                                        both (recommended).
                                                        "CLOUD_LOGGING_ONLY" writes only to Logging.
                                                        Default: "CLOUD_LOGGING_AND_CLOUD_STORAGE"

      ── Custom Storage ───────────────────────────────────────────────────────────────────────────
      (optional; omit for GCP auto-created bucket)

          storage:
              bucket:                        [Optional] Name of a pre-existing GCS bucket to use for
                                                        the environment's data (DAGs, plugins, logs).
                                                        Must exist and be in the same region.
                                                        Default: null (GCP auto-creates)
```

---

## Sample Configurations

| Config File | Environments | Highlights |
|---|---|---|
| `configs/basic.yaml` | 1 (`composer-basic`) | Absolute minimum — just project_id + empty env |
| `configs/development.yaml` | 1 (`composer-dev`) | PyPI packages, short retention, relaxed settings |
| `configs/production.yaml` | 1 (`composer-prod`) | CMEK, HA, Cloud NAT, DAG processor, snapshots |
| `configs/private-ip.yaml` | 1 (`composer-private`) | Private endpoint, PSC, master auth networks |
| `configs/multi-environment.yaml` | 3 (`dev`, `staging`, `prod`) | All tiers in one file with shared globals |

---

## Multiple Environments

Define all environments in one YAML file:

```yaml
project_id: "my-project"
region: "europe-west2"
labels:
  managed_by: terraform

environments:
  composer-dev:
    labels:
      env: dev

  composer-staging:
    environment_size: "ENVIRONMENT_SIZE_MEDIUM"
    labels:
      env: staging

  composer-prod:
    environment_size: "ENVIRONMENT_SIZE_LARGE"
    resilience_mode: "HIGH_RESILIENCE"
    labels:
      env: production
```

Each environment gets its own VPC, service account, and Composer instance. The module uses `for_each` internally, so adding or removing an environment is just editing the YAML.

---

## Outputs

After `terraform apply`:

```bash
# All environments
terraform output environments

# Specific environment
terraform output -json environments | jq '.["composer-prod"]'
```

Output structure per environment:

| Field | Description |
|---|---|
| `environment_id` | Full resource ID |
| `environment_name` | Environment name |
| `airflow_uri` | Airflow web UI URL |
| `dag_gcs_prefix` | GCS path for uploading DAGs |
| `gcs_bucket` | Environment's GCS bucket |
| `service_account_email` | SA email |
| `network_self_link` | VPC network self-link |
| `subnetwork_self_link` | Subnet self-link |

---

## Project Structure

```
.
├── main.tf                          # Reads YAML, iterates environments via for_each
├── variables.tf                     # config_file variable
├── outputs.tf                       # Map of all environment outputs
├── versions.tf                      # Provider configuration
├── configs/
│   ├── basic.yaml                   # Minimal single-env
│   ├── development.yaml             # Dev single-env
│   ├── production.yaml              # Full prod single-env
│   ├── private-ip.yaml              # Private networking
│   └── multi-environment.yaml       # 3 environments in one file
├── modules/
│   └── composer-3/
│       ├── main.tf                  # google_composer_environment resource
│       ├── variables.tf             # environment_key, config, global_config
│       ├── locals.tf                # YAML merging + defaults
│       ├── outputs.tf               # Module outputs
│       ├── versions.tf              # Provider requirements
│       ├── iam.tf                   # Service account + IAM bindings
│       ├── network.tf               # VPC, subnet, NAT, firewall
│       ├── kms.tf                   # CMEK encryption resources
│       └── services.tf              # GCP API enablement
└── tests/
    ├── setup/main.tf                # Test helper module
    ├── basic.tftest.hcl             # Basic config test
    ├── production.tftest.hcl        # Production config test
    ├── validation.tftest.hcl        # Multi-config + validation tests
    └── validate_configs.py          # Python YAML validation script
```

---

## Testing

```bash
# Syntax + configuration validity
terraform validate

# Formatting
terraform fmt -check -recursive

# YAML config validation (Python)
python tests/validate_configs.py

# Native Terraform tests (requires >= 1.6)
terraform test
```

---

## Destroying

```bash
terraform destroy -var 'config_file=configs/my-env.yaml'
```

> **Note**: CMEK keys have `prevent_destroy = true`. Remove the lifecycle block or use `terraform state rm` before full destroy.

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Error enabling API` | Ensure deploying identity has `roles/serviceusage.serviceUsageAdmin` |
| `Service account not found` | Composer agent SA is created when API is enabled — re-run `terraform apply` |
| `IP range overlap` | Each env creates its own VPC, so default CIDRs don't conflict. If sharing a VPC, customise CIDRs per env. |
| `Image version not found` | Run `gcloud composer environments list-image-versions --location=REGION` |
| Empty `{}` env value | Valid — all settings use module defaults |
