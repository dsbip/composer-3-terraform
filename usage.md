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

This section documents **every input** the YAML config file accepts, organised by section. Each field lists its type, whether it is required or optional, its default value, and a description.

> **Legend**: `[R]` = Required, `[O]` = Optional. Default column shows the value used when the field is omitted entirely.

---

### Global-Level Fields

These sit at the root of the YAML file. They apply to all environments unless overridden per-environment.

```yaml
project_id: "my-gcp-project"
region: "europe-west2"
enable_apis: true
apis:
  - "bigquery.googleapis.com"
labels:
  managed_by: terraform
environments:
  # ... (see per-environment section below)
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `project_id` | `string` | **[R]** | — | GCP project ID where all resources are created. Can be overridden per-environment. |
| `region` | `string` | [O] | `"europe-west2"` | GCP region for all environments. Can be overridden per-environment. |
| `labels` | `map(string)` | [O] | `{}` | Labels applied to all environments. Merged with per-env labels (per-env wins on key conflicts). |
| `enable_apis` | `bool` | [O] | `true` | Whether to auto-enable required GCP APIs (`composer`, `compute`, `iam`, `cloudresourcemanager`, `serviceusage`). Set `false` if APIs are managed externally. Can be overridden per-environment. |
| `apis` | `list(string)` | [O] | `[]` | Additional GCP API service names to enable beyond the defaults (e.g. `bigquery.googleapis.com`). Can be overridden per-environment. |
| `environments` | `map(object)` | **[R]** | — | Map of Composer environments to create. Each key is the default environment name; each value is the per-environment config (see below). An empty value `{}` is valid and uses all defaults. |

---

### Per-Environment Fields

All fields below go under `environments.<env-key>:`. **Every field is optional** — an empty `{}` value creates a working environment using all module defaults.

---

#### Identity & Sizing

```yaml
environments:
  composer-prod:
    environment_name: "custom-name"
    project_id: "override-project"
    region: "us-central1"
    environment_size: "ENVIRONMENT_SIZE_LARGE"
    resilience_mode: "HIGH_RESILIENCE"
    labels:
      env: production
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `environment_name` | `string` | [O] | The YAML key (e.g. `composer-prod`) | Override the Composer environment name. If omitted, the map key is used as the name. |
| `project_id` | `string` | [O] | Inherits global `project_id` | Override the GCP project for this specific environment. |
| `region` | `string` | [O] | Inherits global `region` → `"europe-west2"` | Override the GCP region for this environment. |
| `environment_size` | `string` | [O] | `"ENVIRONMENT_SIZE_SMALL"` | Composer environment size tier. Controls baseline resource allocation managed by GCP. Allowed values: `ENVIRONMENT_SIZE_SMALL`, `ENVIRONMENT_SIZE_MEDIUM`, `ENVIRONMENT_SIZE_LARGE`. |
| `resilience_mode` | `string` | [O] | Not set (standard resilience) | Set to `"HIGH_RESILIENCE"` to enable multi-zone redundancy for the scheduler, database, and web server. Allowed values: `STANDARD_RESILIENCE`, `HIGH_RESILIENCE`. |
| `labels` | `map(string)` | [O] | `{}` | Labels for this environment. Merged with global labels — per-env labels win on key conflicts. |
| `enable_apis` | `bool` | [O] | Inherits global `enable_apis` → `true` | Override API enablement for this environment. |
| `apis` | `list(string)` | [O] | Inherits global `apis` → `[]` | Override additional APIs for this environment. |

---

#### Network

The entire `network` block is optional. When omitted, a dedicated VPC is created per environment with default CIDR ranges.

```yaml
    network:
      create: true
      name: "my-network"
      subnetwork_name: "my-subnet"
      subnetwork_cidr: "10.0.0.0/24"
      pods_range_name: "pods"
      pods_cidr: "10.1.0.0/16"
      services_range_name: "services"
      services_cidr: "10.2.0.0/20"
      enable_cloud_nat: false
      tags:
        - "composer"
      existing_network: null
      existing_subnetwork: null
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `network.create` | `bool` | [O] | `true` | Whether to create a new VPC network and subnet. Set `false` to use an existing network (provide `existing_network` and `existing_subnetwork`). |
| `network.name` | `string` | [O] | `"{env-name}-network"` | Name of the VPC network to create. Only used when `create: true`. Auto-derived from the environment key. |
| `network.subnetwork_name` | `string` | [O] | `"{env-name}-subnet"` | Name of the subnet to create. Only used when `create: true`. Auto-derived from the environment key. |
| `network.subnetwork_cidr` | `string` | [O] | `"10.0.0.0/24"` | Primary CIDR range for the subnet. Used for Composer infrastructure nodes. |
| `network.existing_network` | `string` | [O] | `null` | Full self-link of an existing VPC network. Required when `create: false`. Format: `projects/{project}/global/networks/{name}`. |
| `network.existing_subnetwork` | `string` | [O] | `null` | Full self-link of an existing subnet. Required when `create: false`. Format: `projects/{project}/regions/{region}/subnetworks/{name}`. Must have secondary ranges matching `pods_range_name` and `services_range_name`. |
| `network.pods_range_name` | `string` | [O] | `"pods"` | Name of the secondary IP range used for GKE pods. When using an existing subnet, this must match an existing secondary range name. |
| `network.pods_cidr` | `string` | [O] | `"10.1.0.0/16"` | CIDR range for the pods secondary range. Only used when `create: true`. A `/16` provides ~65k pod IPs. |
| `network.services_range_name` | `string` | [O] | `"services"` | Name of the secondary IP range used for GKE services. When using an existing subnet, this must match an existing secondary range name. |
| `network.services_cidr` | `string` | [O] | `"10.2.0.0/20"` | CIDR range for the services secondary range. Only used when `create: true`. A `/20` provides ~4k service IPs. |
| `network.enable_cloud_nat` | `bool` | [O] | `false` | Whether to create a Cloud Router and Cloud NAT gateway for outbound internet access. **Set to `true` when using private environments** so workers can reach PyPI and external services. |
| `network.tags` | `list(string)` | [O] | `["composer"]` | Network tags applied to Composer nodes. Used as targets for the auto-created firewall rules. |

**When `create: true`** (default), the module creates:
- A VPC network with `auto_create_subnetworks = false`
- A subnet with the specified primary and secondary ranges with `private_ip_google_access = true`
- A firewall rule allowing internal TCP/UDP/ICMP between all CIDR ranges
- A firewall rule allowing GCP health check source ranges (`35.191.0.0/16`, `130.211.0.0/22`)
- (If `enable_cloud_nat: true`) A Cloud Router and Cloud NAT with auto-allocated IPs

---

#### Service Account

The entire `service_account` block is optional. When omitted, a service account is auto-created as `{env-name}-sa`.

```yaml
    service_account:
      create: true
      name: "my-custom-sa"
      existing_email: null
      roles:
        - "roles/composer.worker"
        - "roles/logging.logWriter"
        - "roles/monitoring.metricWriter"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `service_account.create` | `bool` | [O] | `true` | Whether to create a new service account. Set `false` to use an existing one (provide `existing_email`). |
| `service_account.name` | `string` | [O] | `"{env-name}-sa"` | The `account_id` for the new service account (max 30 characters, lowercase alphanumeric + hyphens). Auto-derived from the environment key. Only used when `create: true`. |
| `service_account.existing_email` | `string` | [O] | `null` | Email address of an existing service account to use. Required when `create: false`. Format: `name@project.iam.gserviceaccount.com`. |
| `service_account.roles` | `list(string)` | [O] | `["roles/composer.worker", "roles/logging.logWriter", "roles/monitoring.metricWriter"]` | IAM roles to grant to the service account on the project. `roles/composer.worker` is **required** for Composer to function — always include it. |

**Automatic IAM bindings** (always created, not configurable):
- `roles/composer.ServiceAgentV2Ext` → Composer service agent on the project
- `roles/iam.serviceAccountUser` → Composer service agent on the environment's SA

---

#### Software Configuration

The entire `software_config` block is optional. When omitted, GCP selects the latest stable Composer 3 image.

```yaml
    software_config:
      image_version: "composer-3-airflow-2.10.2"
      airflow_config_overrides:
        core-dags_are_paused_at_creation: "True"
        webserver-expose_config: "False"
      env_variables:
        ENVIRONMENT: "production"
      pypi_packages:
        apache-airflow-providers-google: ">=10.0.0"
        pandas: ">=2.0.0"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `software_config.image_version` | `string` | [O] | `null` (GCP picks latest) | Composer image version string. When omitted, GCP automatically selects the latest stable Composer 3 version. Must start with `composer-3` if provided. Run `gcloud composer environments list-image-versions --location=REGION` to list available versions. Example: `"composer-3-airflow-2.10.2"`. |
| `software_config.airflow_config_overrides` | `map(string)` | [O] | `{}` | Airflow configuration property overrides. Keys use `section-key` format with a **hyphen** separator (not dot). Example: `core-dags_are_paused_at_creation: "True"` maps to `[core] dags_are_paused_at_creation = True` in `airflow.cfg`. All values must be strings. |
| `software_config.env_variables` | `map(string)` | [O] | `{}` | Environment variables injected into all Airflow components (scheduler, worker, web server). Available in DAGs via `os.environ`. Do not use for secrets — use Secret Manager instead. |
| `software_config.pypi_packages` | `map(string)` | [O] | `{}` | Additional PyPI packages to install. Keys are package names, values are version specifiers (e.g. `">=10.0.0"`, `"==2.1.0"`, `""`). Packages are installed during environment creation and updates. |

---

#### Workloads

The `workloads` block configures compute resources for each Composer component. The entire block is optional — all sub-components have defaults.

**Important**: `scheduler`, `web_server`, and `worker` are always created (with defaults if not specified). `triggerer` and `dag_processor` are **only created when their block is explicitly present** in the YAML.

```yaml
    workloads:
      scheduler:
        cpu: 0.5
        memory_gb: 2
        storage_gb: 1
        count: 1
      web_server:
        cpu: 1
        memory_gb: 2
        storage_gb: 1
      worker:
        cpu: 1
        memory_gb: 2
        storage_gb: 1
        min_count: 1
        max_count: 3
      triggerer:        # OPTIONAL — omit to not create
        cpu: 0.5
        memory_gb: 0.5
        count: 1
      dag_processor:    # OPTIONAL — omit to not create
        cpu: 1
        memory_gb: 2
        storage_gb: 1
        count: 1
```

##### workloads.scheduler

Parses DAGs and schedules task execution. Always created.

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `workloads.scheduler.cpu` | `number` | [O] | `0.5` | vCPUs allocated to each scheduler instance. |
| `workloads.scheduler.memory_gb` | `number` | [O] | `2` | Memory in GB allocated to each scheduler instance. |
| `workloads.scheduler.storage_gb` | `number` | [O] | `1` | Storage in GB allocated to each scheduler instance. |
| `workloads.scheduler.count` | `number` | [O] | `1` | Number of scheduler instances. Set to `2` for high availability. |

##### workloads.web_server

Serves the Airflow UI. Always created (single instance).

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `workloads.web_server.cpu` | `number` | [O] | `1` | vCPUs allocated to the web server. |
| `workloads.web_server.memory_gb` | `number` | [O] | `2` | Memory in GB allocated to the web server. |
| `workloads.web_server.storage_gb` | `number` | [O] | `1` | Storage in GB allocated to the web server. |

##### workloads.worker

Executes Airflow tasks. Always created with autoscaling between `min_count` and `max_count`.

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `workloads.worker.cpu` | `number` | [O] | `1` | vCPUs allocated to each worker instance. |
| `workloads.worker.memory_gb` | `number` | [O] | `2` | Memory in GB allocated to each worker instance. |
| `workloads.worker.storage_gb` | `number` | [O] | `1` | Storage in GB allocated to each worker instance. |
| `workloads.worker.min_count` | `number` | [O] | `1` | Minimum number of worker instances (always running). |
| `workloads.worker.max_count` | `number` | [O] | `3` | Maximum number of worker instances (autoscale ceiling). |

##### workloads.triggerer

Monitors deferred tasks and resumes them when conditions are met (e.g. external sensor completion). **Only created when this block is present in the YAML.** Omit the entire `triggerer:` key to skip creation.

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `workloads.triggerer.cpu` | `number` | [O] | `0.5` | vCPUs allocated to each triggerer instance. |
| `workloads.triggerer.memory_gb` | `number` | [O] | `0.5` | Memory in GB allocated to each triggerer instance. |
| `workloads.triggerer.count` | `number` | [O] | `1` | Number of triggerer instances. |

##### workloads.dag_processor

Separate process for parsing DAG files (Composer 3 feature). **Only created when this block is present in the YAML.** Omit the entire `dag_processor:` key to skip creation.

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `workloads.dag_processor.cpu` | `number` | [O] | `1` | vCPUs allocated to each DAG processor instance. |
| `workloads.dag_processor.memory_gb` | `number` | [O] | `2` | Memory in GB allocated to each DAG processor instance. |
| `workloads.dag_processor.storage_gb` | `number` | [O] | `1` | Storage in GB allocated to each DAG processor instance. |
| `workloads.dag_processor.count` | `number` | [O] | `1` | Number of DAG processor instances. |

---

#### Private Environment

The entire `private_environment` block is optional. When omitted, the Composer environment uses public IP networking. When present, it configures private networking for the environment.

```yaml
    private_environment:
      enable_private_endpoint: false
      cloud_sql_ipv4_cidr_block: "10.10.0.0/24"
      web_server_ipv4_cidr_block: "10.10.1.0/24"
      master_ipv4_cidr_block: "10.10.2.0/28"
      cloud_composer_network_ipv4_cidr_block: "10.10.3.0/24"
      enable_privately_used_public_ips: false
      connection_type: "VPC_PEERING"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `private_environment.enable_private_endpoint` | `bool` | [O] | `false` | When `true`, the Airflow web server has no public IP and is only accessible via private network. Requires VPN, bastion, or IAP for access. |
| `private_environment.cloud_sql_ipv4_cidr_block` | `string` | [O] | `null` (GCP auto-assigns) | CIDR block for the Cloud SQL instance used by the Composer environment. Must not overlap with other ranges. |
| `private_environment.web_server_ipv4_cidr_block` | `string` | [O] | `null` (GCP auto-assigns) | CIDR block for the Airflow web server. |
| `private_environment.master_ipv4_cidr_block` | `string` | [O] | `null` (GCP auto-assigns) | CIDR block for the GKE control plane. Must be a `/28` range. |
| `private_environment.cloud_composer_network_ipv4_cidr_block` | `string` | [O] | `null` (GCP auto-assigns) | CIDR block for the Cloud Composer networking infrastructure. |
| `private_environment.enable_privately_used_public_ips` | `bool` | [O] | `false` | When `true`, allows using publicly-routable IP ranges for private GKE endpoints. Useful in organisations with large private IP allocations. |
| `private_environment.connection_type` | `string` | [O] | `"VPC_PEERING"` | Network connection type. `VPC_PEERING` creates a VPC peering connection. `PRIVATE_SERVICE_CONNECT` uses PSC (recommended for Composer 3). |

> **Tip**: When `enable_private_endpoint: true`, set `network.enable_cloud_nat: true` so workers can reach PyPI and external services.

---

#### Master Authorized Networks

The entire `master_authorized_networks` block is optional. When omitted, no master authorized network restrictions are applied. When present, it restricts which IP ranges can access the GKE control plane.

```yaml
    master_authorized_networks:
      enabled: true
      cidr_blocks:
        - display_name: "office-vpn"
          cidr_block: "203.0.113.0/24"
        - display_name: "cicd-runners"
          cidr_block: "198.51.100.0/24"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `master_authorized_networks.enabled` | `bool` | [O] | `true` (when block is present) | Whether master authorized networks are enforced. |
| `master_authorized_networks.cidr_blocks` | `list(object)` | [O] | `[]` | List of CIDR blocks allowed to access the GKE control plane. |
| `master_authorized_networks.cidr_blocks[].display_name` | `string` | **[R]** (per entry) | — | Human-readable name for the CIDR block (e.g. `"office-vpn"`). |
| `master_authorized_networks.cidr_blocks[].cidr_block` | `string` | **[R]** (per entry) | — | IP range in CIDR notation (e.g. `"10.0.0.0/8"`). |

---

#### Maintenance Window

The entire `maintenance_window` block is optional. When omitted, GCP schedules maintenance at any time. When present, it restricts Composer maintenance operations (upgrades, patches) to the specified recurring window.

```yaml
    maintenance_window:
      start_time: "2024-01-01T02:00:00Z"
      end_time: "2024-01-01T06:00:00Z"
      recurrence: "FREQ=WEEKLY;BYDAY=SU"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `maintenance_window.start_time` | `string` | **[R]** (when block present) | — | Start time in RFC 3339 format. Only the time-of-day portion matters; the date is used as an anchor. Example: `"2024-01-01T02:00:00Z"`. |
| `maintenance_window.end_time` | `string` | **[R]** (when block present) | — | End time in RFC 3339 format. Must be on the same day as `start_time`. The window duration must be at least 4 hours. Example: `"2024-01-01T06:00:00Z"`. |
| `maintenance_window.recurrence` | `string` | **[R]** (when block present) | — | Recurrence rule in RFC 5545 `RRULE` format. Examples: `"FREQ=WEEKLY;BYDAY=SU"` (every Sunday), `"FREQ=WEEKLY;BYDAY=SA,SU"` (weekends). |

---

#### Encryption (CMEK)

The entire `encryption` block is optional. When omitted (or `enable_cmek: false`), GCP-managed encryption is used. When enabled, the module creates a KMS key ring and crypto key (or uses an existing key) to encrypt the Composer environment data.

```yaml
    encryption:
      enable_cmek: true
      kms_key_ring_name: "my-keyring"
      kms_key_name: "my-key"
      kms_key_rotation_period: "7776000s"
      existing_kms_key: null
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `encryption.enable_cmek` | `bool` | [O] | `false` | Whether to enable customer-managed encryption keys. When `true`, either creates a new KMS key or uses an existing one. |
| `encryption.kms_key_ring_name` | `string` | [O] | `"{env-name}-keyring"` | Name of the KMS key ring to create. Only used when `enable_cmek: true` and `existing_kms_key` is not set. Created in the same region as the environment. |
| `encryption.kms_key_name` | `string` | [O] | `"{env-name}-key"` | Name of the KMS crypto key to create. Only used when `enable_cmek: true` and `existing_kms_key` is not set. |
| `encryption.kms_key_rotation_period` | `string` | [O] | `"7776000s"` (90 days) | Automatic key rotation period in seconds. Only used for newly created keys. |
| `encryption.existing_kms_key` | `string` | [O] | `null` | Full resource ID of an existing KMS crypto key. When provided, no new key is created. Format: `projects/{p}/locations/{r}/keyRings/{kr}/cryptoKeys/{k}`. |

**Automatic IAM bindings** (created when CMEK is enabled):
- `roles/cloudkms.cryptoKeyEncrypterDecrypter` → Composer service agent, Artifact Registry agent, and GCS agent

> **Note**: KMS crypto keys created by the module have `prevent_destroy = true`. To fully destroy the stack, remove the lifecycle block from `modules/composer-3/kms.tf` or use `terraform state rm` first.

---

#### Recovery

The entire `recovery` block is optional. When omitted, no scheduled snapshots are configured. When present, it enables periodic environment snapshots for disaster recovery.

```yaml
    recovery:
      enable_scheduled_snapshots: true
      snapshot_location: "europe-west2"
      snapshot_creation_schedule: "0 3 * * *"
      time_zone: "UTC"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `recovery.enable_scheduled_snapshots` | `bool` | [O] | `true` (when block present) | Whether scheduled snapshots are enabled. |
| `recovery.snapshot_location` | `string` | [O] | Same as environment `region` | GCP region where snapshots are stored. |
| `recovery.snapshot_creation_schedule` | `string` | [O] | `"0 3 * * *"` (3 AM daily) | Cron expression defining when snapshots are created. Standard 5-field cron format. |
| `recovery.time_zone` | `string` | [O] | `"UTC"` | Time zone for the cron schedule. Uses IANA time zone names (e.g. `"America/Chicago"`, `"Europe/London"`). |

---

#### Data Retention

The entire `data_retention` block is optional. When omitted, GCP uses default retention behaviour. When present, it configures how long Airflow metadata and task logs are retained.

```yaml
    data_retention:
      airflow_metadata_retention_config:
        retention_mode: "RETENTION_MODE_ENABLED"
        retention_days: 30
      task_logs_retention_config:
        storage_mode: "CLOUD_LOGGING_AND_CLOUD_STORAGE"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `data_retention.airflow_metadata_retention_config.retention_mode` | `string` | [O] | `"RETENTION_MODE_ENABLED"` | Whether metadata retention is active. Allowed values: `RETENTION_MODE_ENABLED`, `RETENTION_MODE_DISABLED`. |
| `data_retention.airflow_metadata_retention_config.retention_days` | `number` | [O] | `30` | Number of days to retain Airflow metadata (DAG runs, task instances, etc.) before automatic cleanup. |
| `data_retention.task_logs_retention_config.storage_mode` | `string` | [O] | `"CLOUD_LOGGING_AND_CLOUD_STORAGE"` | Where task logs are stored. `CLOUD_LOGGING_AND_CLOUD_STORAGE` writes to both (recommended). `CLOUD_LOGGING_ONLY` writes only to Cloud Logging. |

---

#### Custom Storage

Optional. When omitted, GCP auto-creates a GCS bucket for the environment.

```yaml
    storage:
      bucket: "my-custom-bucket"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `storage.bucket` | `string` | [O] | `null` (GCP auto-creates) | Name of a pre-existing GCS bucket to use for the Composer environment's data (DAGs, plugins, logs). The bucket must already exist and be in the same region as the environment. |

---

### Full YAML Skeleton (all fields)

Below is a complete YAML skeleton showing every field with its default value. Copy this and remove anything you do not need — every field is optional except `project_id` and `environments`.

```yaml
# ── Global Defaults ──────────────────────────────────────────────────
project_id: "my-gcp-project"                         # REQUIRED
region: "europe-west2"                                 # Default
enable_apis: true                                      # Default
apis: []                                               # Default
labels: {}                                             # Default

# ── Environments ─────────────────────────────────────────────────────
environments:                                          # REQUIRED (at least one)
  my-environment:                                      # Key = default env name

    # Identity & Sizing
    environment_name: "my-environment"                 # Default: YAML key
    project_id: "my-gcp-project"                       # Default: inherits global
    region: "europe-west2"                             # Default: inherits global
    environment_size: "ENVIRONMENT_SIZE_SMALL"          # Default
    resilience_mode: null                              # Default: standard
    enable_apis: true                                  # Default: inherits global
    apis: []                                           # Default: inherits global
    labels: {}                                         # Default: merged with global

    # Network
    network:
      create: true                                     # Default
      name: "my-environment-network"                   # Default: {env}-network
      subnetwork_name: "my-environment-subnet"         # Default: {env}-subnet
      subnetwork_cidr: "10.0.0.0/24"                   # Default
      existing_network: null                           # Default
      existing_subnetwork: null                        # Default
      pods_range_name: "pods"                          # Default
      pods_cidr: "10.1.0.0/16"                         # Default
      services_range_name: "services"                  # Default
      services_cidr: "10.2.0.0/20"                     # Default
      enable_cloud_nat: false                          # Default
      tags: ["composer"]                               # Default

    # Service Account
    service_account:
      create: true                                     # Default
      name: "my-environment-sa"                        # Default: {env}-sa
      existing_email: null                             # Default
      roles:                                           # Default
        - "roles/composer.worker"
        - "roles/logging.logWriter"
        - "roles/monitoring.metricWriter"

    # Software
    software_config:
      image_version: null                              # Default: GCP latest
      airflow_config_overrides: {}                     # Default
      env_variables: {}                                # Default
      pypi_packages: {}                                # Default

    # Workloads
    workloads:
      scheduler:
        cpu: 0.5                                       # Default
        memory_gb: 2                                   # Default
        storage_gb: 1                                  # Default
        count: 1                                       # Default
      web_server:
        cpu: 1                                         # Default
        memory_gb: 2                                   # Default
        storage_gb: 1                                  # Default
      worker:
        cpu: 1                                         # Default
        memory_gb: 2                                   # Default
        storage_gb: 1                                  # Default
        min_count: 1                                   # Default
        max_count: 3                                   # Default
      # triggerer:                                     # OMIT to skip creation
      #   cpu: 0.5                                     # Default when present
      #   memory_gb: 0.5                               # Default when present
      #   count: 1                                     # Default when present
      # dag_processor:                                 # OMIT to skip creation
      #   cpu: 1                                       # Default when present
      #   memory_gb: 2                                 # Default when present
      #   storage_gb: 1                                # Default when present
      #   count: 1                                     # Default when present

    # Private Environment (omit entire block for public networking)
    # private_environment:
    #   enable_private_endpoint: false                  # Default
    #   cloud_sql_ipv4_cidr_block: null                 # Default: GCP assigns
    #   web_server_ipv4_cidr_block: null                # Default: GCP assigns
    #   master_ipv4_cidr_block: null                    # Default: GCP assigns
    #   cloud_composer_network_ipv4_cidr_block: null    # Default: GCP assigns
    #   enable_privately_used_public_ips: false          # Default
    #   connection_type: "VPC_PEERING"                  # Default

    # Master Authorized Networks (omit for no restrictions)
    # master_authorized_networks:
    #   enabled: true                                   # Default when present
    #   cidr_blocks:
    #     - display_name: "name"                        # REQUIRED per entry
    #       cidr_block: "0.0.0.0/0"                    # REQUIRED per entry

    # Maintenance Window (omit for GCP-scheduled)
    # maintenance_window:
    #   start_time: "2024-01-01T02:00:00Z"             # REQUIRED when present
    #   end_time: "2024-01-01T06:00:00Z"               # REQUIRED when present
    #   recurrence: "FREQ=WEEKLY;BYDAY=SU"             # REQUIRED when present

    # Encryption (omit for GCP-managed encryption)
    # encryption:
    #   enable_cmek: false                              # Default
    #   kms_key_ring_name: "my-environment-keyring"    # Default: {env}-keyring
    #   kms_key_name: "my-environment-key"             # Default: {env}-key
    #   kms_key_rotation_period: "7776000s"            # Default: 90 days
    #   existing_kms_key: null                          # Default

    # Recovery (omit for no snapshots)
    # recovery:
    #   enable_scheduled_snapshots: true                # Default when present
    #   snapshot_location: "europe-west2"               # Default: env region
    #   snapshot_creation_schedule: "0 3 * * *"        # Default: 3 AM daily
    #   time_zone: "UTC"                               # Default

    # Data Retention (omit for GCP defaults)
    # data_retention:
    #   airflow_metadata_retention_config:
    #     retention_mode: "RETENTION_MODE_ENABLED"      # Default when present
    #     retention_days: 30                            # Default when present
    #   task_logs_retention_config:
    #     storage_mode: "CLOUD_LOGGING_AND_CLOUD_STORAGE"  # Default when present

    # Custom Storage (omit for GCP auto-created bucket)
    # storage:
    #   bucket: null                                    # Default: GCP creates
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
