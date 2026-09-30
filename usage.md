# Cloud Composer 3 Terraform Module — Usage Guide

## Overview

This Terraform module deploys one or more **Google Cloud Composer 3** environments from a single YAML configuration file. (Newer Google Cloud documentation calls Composer 3 *Managed Service for Apache Airflow, Gen 3*; the Terraform resource is still `google_composer_environment`.) It creates all required dependencies automatically:

| Resource | Description |
|---|---|
| **Composer Environment(s)** | Cloud Composer 3 (`composer-3-airflow-*` images) with configurable workloads, software, and networking |
| **VPC Network + Subnet** | Dedicated network per environment; Composer 3 attaches to it through a Private Service Connect network attachment |
| **Service Account + IAM** | Auto-named SA (`{env-name}-sa`) with Composer roles, plus the binding the Composer service agent needs |
| **Composer Service Agent** | Generated up front, so a project that has never used Composer works on the first apply |
| **Cloud NAT + Router** | Optional outbound internet access for Private IP environments |
| **KMS Key Ring + Key** | Customer-managed encryption key (CMEK) — optional |
| **GCP API Enablement** | Automatically enables required APIs |

Almost every setting has a sensible default. A minimal config needs only `project_id` and an environment key. Configuration mistakes are reported at `terraform plan` time, naming the environment and the setting (see [Validation](#validation)).

> **Upgrading from an earlier version of this module?** Read [CHANGELOG.md](CHANGELOG.md) first: several Composer 2 settings were replaced, and the default image changed.

---

## Prerequisites

- **Terraform** >= 1.2.0 (>= 1.7 to run the native tests in `tests/`)
- **google / google-beta providers** >= 6.0.0 (`.terraform.lock.hcl` pins 7.31.0)
- A GCP project with billing enabled
- Authenticated `gcloud` CLI or a service account key
- Required roles on the deploying identity:
  - `roles/composer.admin`
  - `roles/compute.networkAdmin`
  - `roles/iam.serviceAccountAdmin`
  - `roles/iam.serviceAccountUser`
  - `roles/resourcemanager.projectIamAdmin`
  - `roles/serviceusage.serviceUsageAdmin` (enables APIs and generates the Composer service agent)
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

That's it. Everything else uses defaults: Composer 3 image `composer-3-airflow-2` (the latest build of Airflow 2), region `europe-west2`, size `SMALL`, Public IP networking, and an auto-created network and service account.

### 2. Check the config (optional, takes a second)

```bash
python tests/validate_configs.py configs/my-env.yaml
```

### 3. Deploy

```bash
terraform init
terraform plan  -var 'config_file=configs/my-env.yaml'
terraform apply -var 'config_file=configs/my-env.yaml'
```

`config_file` is resolved relative to the root module; absolute paths also work.

### 4. Verify

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

Per-environment values override global values. For labels, global and per-env labels are merged (per-env wins on conflicts). A key that is present but empty (for example `region:` with no value) counts as omitted and falls back to the default.

---

## Composer 3 Networking at a Glance

Composer 3 runs its Airflow infrastructure in a Google-managed tenant project. Your project has no GKE cluster, no pods/services secondary ranges and no Composer-specific firewall rules. The environment optionally *attaches* to a VPC in your project through a Private Service Connect network attachment.

| Goal | YAML |
|---|---|
| Public IP, attached to a new dedicated VPC (default) | *(nothing)* |
| Public IP, not attached to any VPC | `network: { create: false }` |
| Private IP with internet egress through Cloud NAT | `enable_private_environment: true` + `network: { enable_cloud_nat: true }` |
| Private IP that installs packages from public PyPI | add `enable_private_builds_only: false` |
| Attach to an existing VPC | `network: { existing_network: ..., existing_subnetwork: ... }` |
| Use a pre-created (possibly shared) network attachment | `network: { existing_network_attachment: ... }` |
| Restrict who can open the Airflow UI | `web_server_network_access_control: { allowed_ip_ranges: [...] }` |

With **Public IP** networking, Airflow components can reach the internet directly. With **Private IP** they cannot. When the environment is attached to a VPC, its traffic is routed into that VPC, so the VPC decides what it can reach (Cloud NAT, VPN, and so on). Google APIs stay reachable through Private Google Access.

---

## Complete YAML Input Definition

This section documents **every input** the YAML config file accepts. Each field shows whether it is `[Required]` or `[Optional]`, its default value, and a description.

```
composer_environments:
  ──────────────────────────────────────────────────────────────────────────────────────────────────

  GLOBAL-LEVEL FIELDS (root of YAML file, apply to all environments unless overridden)
  ──────────────────────────────────────────────────────────────────────────────────────────────────

  project_id:                                [Required] The GCP project ID where all resources are
                                                        created. Can be overridden per-environment;
                                                        the global value may only be omitted when
                                                        every environment sets its own.

  region:                                    [Optional] GCP region for all environments. Can be
                                                        overridden per-environment.
                                                        Default: "europe-west2"

  enable_apis:                               [Optional] Whether to auto-enable required GCP APIs
                                                        (composer, compute, iam,
                                                        cloudresourcemanager, serviceusage, plus
                                                        cloudkms with CMEK and datalineage with data
                                                        lineage). Set false if APIs are managed
                                                        externally.
                                                        Default: true

  apis:                                      [Optional] Additional GCP API service names to enable
                                                        beyond the defaults (e.g.
                                                        "bigquery.googleapis.com").
                                                        Default: []

  labels:                                    [Optional] Key/value labels applied to all environments.
                                                        Merged with per-env labels (per-env wins on
                                                        key conflicts). Keys and values must be
                                                        lowercase letters, digits, '_' or '-' (max 63
                                                        chars; keys start with a letter).
                                                        Default: {}

  environments:                              [Required] Map of Composer environments to create. Each
                                                        key becomes the default environment name. An
                                                        empty value {} (or no value at all) is valid
                                                        and uses all defaults. An empty map plans
                                                        zero environments, which is how every
                                                        environment is removed.

  ──────────────────────────────────────────────────────────────────────────────────────────────────

  PER-ENVIRONMENT FIELDS (under environments.<env-key>:, ALL fields are optional)
  ──────────────────────────────────────────────────────────────────────────────────────────────────

      [ENVIRONMENT_KEY]:                     [Required] The map key. Used as the default environment
                                                        name, service account name prefix ({key}-sa),
                                                        network name prefix ({key}-network) and
                                                        subnet name prefix ({key}-subnet). Must start
                                                        with a lowercase letter and contain only
                                                        lowercase letters, digits and hyphens.

      ── Identity & Sizing ────────────────────────────────────────────────────────────────────────

          environment_name:                  [Optional] Override the Composer environment name. If
                                                        omitted, the map key is used as the name.
                                                        Must be unique per project and region.
                                                        Default: ENVIRONMENT_KEY

          project_id:                        [Optional] Override the GCP project for this specific
                                                        environment.
                                                        Default: inherits global project_id

          region:                            [Optional] Override the GCP region for this environment.
                                                        Default: inherits global region ->
                                                        "europe-west2"

          environment_size:                  [Optional] Composer environment size tier. Sizes the
                                                        Google-managed infrastructure, including the
                                                        Airflow database. Allowed:
                                                        "ENVIRONMENT_SIZE_SMALL",
                                                        "ENVIRONMENT_SIZE_MEDIUM",
                                                        "ENVIRONMENT_SIZE_LARGE",
                                                        "ENVIRONMENT_SIZE_EXTRA_LARGE"
                                                        Default: "ENVIRONMENT_SIZE_SMALL"

          resilience_mode:                   [Optional] Set to "HIGH_RESILIENCE" for a multi-zone,
                                                        highly resilient environment. Composer then
                                                        requires exactly 2 schedulers, at least 2
                                                        workers, at least 2 DAG processors and 0 or
                                                        at least 2 triggerers; the module's workload
                                                        defaults follow these rules automatically and
                                                        the plan fails if an explicit value breaks
                                                        them. Allowed: "STANDARD_RESILIENCE",
                                                        "HIGH_RESILIENCE"
                                                        Default: not set (standard resilience)

          labels:                            [Optional] Key/value labels for this environment. Merged
                                                        with global labels; per-env wins on
                                                        conflicts.
                                                        Default: {}

          enable_apis:                       [Optional] Override API enablement for this environment.
                                                        Default: inherits global enable_apis -> true

          apis:                              [Optional] Override additional APIs for this
                                                        environment.
                                                        Default: inherits global apis -> []

      ── Networking Type (Composer 3) ─────────────────────────────────────────────────────────────
      (both optional; omit them for a Public IP environment. They replace the Composer 2
      private_environment block)

          enable_private_environment:        [Optional] true = Private IP networking: Airflow
                                                        components have no direct internet access.
                                                        When the environment is attached to a VPC,
                                                        its traffic is routed into that VPC, so
                                                        internet access is whatever the VPC provides
                                                        (see network.enable_cloud_nat). Google APIs
                                                        stay reachable through Private Google Access.
                                                        Default: not set (Public IP)

          enable_private_builds_only:        [Optional] true = the builds that install PyPI packages
                                                        only get private connectivity to Google
                                                        services, so packages must come from private
                                                        repositories (e.g. Artifact Registry). false
                                                        = builds can also reach the internet (public
                                                        PyPI). Set false explicitly for a Private IP
                                                        environment that installs packages from PyPI.
                                                        Default: not set (GCP default)

      ── Network ──────────────────────────────────────────────────────────────────────────────────
      (entire block optional; when omitted, a dedicated VPC and subnet are created and the
      environment is attached to them)

          network:
              create:                        [Optional] Whether to create a new VPC network and
                                                        subnet. Defaults to false as soon as
                                                        existing_network, existing_subnetwork or
                                                        existing_network_attachment is set; combining
                                                        create: true with them is an error. create:
                                                        false with no existing networking leaves the
                                                        environment attached to no VPC (valid in
                                                        Composer 3).
                                                        Default: true (false when existing networking
                                                        is given)

              name:                          [Optional] Name of the VPC network to create. Only used
                                                        when create: true.
                                                        Default: "{env-name}-network"

              subnetwork_name:               [Optional] Name of the subnet to create. Only used when
                                                        create: true.
                                                        Default: "{env-name}-subnet"

              subnetwork_cidr:               [Optional] Primary CIDR range of the created subnet.
                                                        Composer places its Private Service Connect
                                                        network attachment here and takes its IP
                                                        addresses from this range; no secondary
                                                        ranges are needed.
                                                        Default: "10.0.0.0/24"

              existing_network:              [Optional] Self-link or ID of an existing VPC network.
                                                        Must be set together with
                                                        existing_subnetwork. Format:
                                                        projects/{project}/global/networks/{name}
                                                        Default: null

              existing_subnetwork:           [Optional] Self-link or ID of an existing subnet in the
                                                        environment's region. Must be set together
                                                        with existing_network. Format:
                                                        projects/{p}/regions/{r}/subnetworks/{n}
                                                        Default: null

              existing_network_attachment:   [Optional] A pre-created PSC network attachment to
                                                        connect through, instead of network +
                                                        subnetwork. One attachment can be shared by
                                                        several environments if it has enough IP
                                                        addresses. Format:
                                                        projects/{p}/regions/{r}/networkAttachments/{n}
                                                        Default: null

              composer_internal_ipv4_cidr_block:
                                             [Optional] IPv4 range for Composer's internal
                                                        components. Must be exactly a /20 and must
                                                        not overlap ranges the environment needs to
                                                        reach. Cannot be changed after creation.
                                                        Default: null (GCP default)

              enable_cloud_nat:              [Optional] Create a Cloud Router and Cloud NAT in the
                                                        module's VPC. Gives a Private IP environment
                                                        controlled internet egress (e.g. APIs outside
                                                        Google). Only valid with create: true; for an
                                                        existing VPC configure NAT there.
                                                        Default: false

              tags:                          [Optional] Network tags passed to the environment's
                  - "composer"                          node_config. Cannot be changed after
                                                        creation.
                                                        Default: ["composer"]

          When create: true, the module creates:
            - A custom-mode VPC and a subnet with Private Google Access
            - (If enable_cloud_nat: true) Cloud Router + Cloud NAT with auto-allocated IPs
          No firewall rules are created: Composer 3 components run in a Google-managed tenant
          project, so the Composer 2 GKE node / health-check rules no longer apply.

      ── Service Account ──────────────────────────────────────────────────────────────────────────
      (entire block optional; when omitted, the SA is auto-created as {env-name}-sa)

          service_account:
              create:                        [Optional] Whether to create a new service account.
                                                        Defaults to false when existing_email is set;
                                                        combining create: true with existing_email is
                                                        an error.
                                                        Default: true (false when existing_email is
                                                        set)

              name:                          [Optional] The account_id for the new SA (6-30 chars,
                                                        lowercase letters, digits and hyphens). Only
                                                        used when create: true.
                                                        Default: "{env-name}-sa"

              existing_email:                [Optional] Email of an existing SA to run the
                                                        environment as. It may live in another
                                                        project (the project is read from the email).
                                                        Format: name@project.iam.gserviceaccount.com
                                                        Default: null

              roles:                         [Optional] IAM roles granted to the SA on the project.
                  - "roles/composer.worker"             Must include roles/composer.worker when the
                  - "roles/logging.logWriter"           module creates the SA (the plan fails
                  - "roles/monitoring.metricWriter"     otherwise). With an existing SA, roles: []
                                                        grants nothing, for IAM managed elsewhere.
                                                        Default: [roles/composer.worker,
                                                                  roles/logging.logWriter,
                                                                  roles/monitoring.metricWriter]

          Automatic IAM (always, not configurable):
            - The Composer service agent (service-<number>@cloudcomposer-accounts...) is generated
              up front with google_project_service_identity, so the first apply works in a project
              that has never used Composer
            - roles/iam.serviceAccountUser -> Composer service agent on the environment's SA
            - roles/composer.ServiceAgentV2Ext is NOT granted: it is a Composer 2 requirement; the
              Composer 3 service agent only needs the role Google grants it automatically

      ── Software Configuration ───────────────────────────────────────────────────────────────────
      (entire block optional)

          software_config:
              image_version:                 [Optional] Composer 3 image. Must start with
                                                        composer-3-airflow-. Accepts the aliases
                                                        composer-3-airflow-2 (latest build of the
                                                        latest Airflow 2), composer-3-airflow-X.Y and
                                                        composer-3-airflow-X.Y.Z (latest build of
                                                        that Airflow version), or a full build such
                                                        as composer-3-airflow-2.11.1-build.19 for
                                                        exact reproducibility. List the available
                                                        ones: gcloud composer environments
                                                        list-image-versions --location=REGION. An
                                                        image is always sent: without one the
                                                        Composer API would create a Composer 2
                                                        environment.
                                                        Default: "composer-3-airflow-2"

              airflow_config_overrides:      [Optional] Airflow configuration property overrides.
                                                        Keys use section-key format with a HYPHEN
                                                        separator (not dot):
                                                        core-dags_are_paused_at_creation maps to
                                                        [core] dags_are_paused_at_creation in
                                                        airflow.cfg. Values are sent as strings.
                                                        Default: {}

              env_variables:                 [Optional] Environment variables injected into all
                                                        Airflow components. Names must match
                                                        [a-zA-Z_][a-zA-Z0-9_]*, must not be
                                                        AIRFLOW__SECTION__KEY (use
                                                        airflow_config_overrides) and must not be
                                                        reserved (AIRFLOW_HOME, GCS_BUCKET,
                                                        GCP_PROJECT, SQL_* ...). Do not use for
                                                        secrets.
                                                        Default: {}

              pypi_packages:                 [Optional] Additional PyPI packages. Keys are lowercase
                                                        package names, values are extras / version
                                                        specifiers (e.g. ">=10.0.0", "==2.1.0",
                                                        "[gcp]"). An empty string or no value
                                                        installs the package unpinned.
                                                        Default: {}

              web_server_plugins_mode:       [Optional] "ENABLED" or "DISABLED": whether the Airflow
                                                        web server loads plugins (Composer 3 only).
                                                        Default: not set (GCP default: ENABLED)

              cloud_data_lineage_integration:
                  enabled:                   [Optional] Report lineage to the Data Lineage API. When
                                                        true the module also enables
                                                        datalineage.googleapis.com.
                                                        Default: block omitted

      ── Workloads ────────────────────────────────────────────────────────────────────────────────
      (entire block optional; scheduler, web_server and worker are always configured with the
      defaults below. triggerer and dag_processor are only configured when their block is present;
      otherwise GCP's defaults apply. Composer 3 always runs at least one DAG processor. Composer 3
      limits, checked at plan time: every component needs 1-8 GB of memory per vCPU, memory goes in
      0.25 GB steps and storage is a whole number of GB from 0 to 100)

          workloads:
              scheduler:                     [Optional] Schedules DAG runs and tasks. Always
                                                        configured.

                  cpu:                       [Optional] vCPUs per scheduler: 0.5-2 in steps of 0.5.
                                                        Default: 0.5

                  memory_gb:                 [Optional] Memory in GB per scheduler: 1-8 (2-8 with
                                                        Airflow 3).
                                                        Default: 2

                  storage_gb:                [Optional] Storage in GB per scheduler.
                                                        Default: 1

                  count:                     [Optional] Number of schedulers: 1-3. HIGH_RESILIENCE
                                                        requires exactly 2.
                                                        Default: 1 (2 with HIGH_RESILIENCE)

              web_server:                    [Optional] Serves the Airflow UI. Always configured
                                                        (single instance).

                  cpu:                       [Optional] vCPUs for the web server: 1, 2 or 4.
                                                        Default: 1

                  memory_gb:                 [Optional] Memory in GB for the web server: 2-32.
                                                        Default: 2

                  storage_gb:                [Optional] Storage in GB for the web server.
                                                        Default: 1

              worker:                        [Optional] Executes Airflow tasks, autoscaling between
                                                        min_count and max_count.

                  cpu:                       [Optional] vCPUs per worker: 0.5, 1 or a multiple of 2,
                                                        up to 32.
                                                        Default: 1

                  memory_gb:                 [Optional] Memory in GB per worker: 1-256 (2-256 with
                                                        Airflow 3).
                                                        Default: 2

                  storage_gb:                [Optional] Storage in GB per worker.
                                                        Default: 1

                  min_count:                 [Optional] Minimum number of workers, at least 1.
                                                        HIGH_RESILIENCE requires at least 2.
                                                        Default: 1 (2 with HIGH_RESILIENCE)

                  max_count:                 [Optional] Maximum number of workers (autoscale
                                                        ceiling), at most 100. Must be >= min_count.
                                                        Default: 3, or min_count if higher

              triggerer:                     [Optional] Runs deferred tasks (deferrable operators /
                                                        async sensors). ** Only configured when this
                                                        block is present. ** Use triggerer: {} for
                                                        the defaults, or count: 0 to disable
                                                        explicitly.

                  cpu:                       [Optional] vCPUs per triggerer: 0.5 or 1.
                                                        Default: 0.5 (when block present)

                  memory_gb:                 [Optional] Memory in GB per triggerer: 1-8 (2-8 with
                                                        Airflow 3).
                                                        Default: 1, or 2 with an Airflow 3 image
                                                        (when block present)

                  count:                     [Optional] Number of triggerers: 0-10. HIGH_RESILIENCE
                                                        requires 0 or at least 2.
                                                        Default: 1 (2 with HIGH_RESILIENCE)

              dag_processor:                 [Optional] Parses DAG files (a separate component in
                                                        Composer 3). ** Only configured when this
                                                        block is present; otherwise GCP sizes it. **

                  cpu:                       [Optional] vCPUs per DAG processor: 0.5, 1 or a multiple
                                                        of 2, up to 32.
                                                        Default: 1 (when block present)

                  memory_gb:                 [Optional] Memory in GB per DAG processor: 1-256 (2-256
                                                        with Airflow 3).
                                                        Default: 2 (when block present)

                  storage_gb:                [Optional] Storage in GB per DAG processor.
                                                        Default: 1 (when block present)

                  count:                     [Optional] Number of DAG processors: 1-3.
                                                        HIGH_RESILIENCE requires at least 2.
                                                        Default: 1 (2 with HIGH_RESILIENCE)

      ── Airflow UI Network Access Control ────────────────────────────────────────────────────────
      (entire block optional; omit it to allow access to the Airflow UI from any IP address. For
      restricting UI access this replaces the Composer 2 master_authorized_networks block)

          web_server_network_access_control:
              allowed_ip_ranges:             [Required] At least one range when the block is present.
                                                        The Airflow UI sees the public egress address
                                                        of your network, so list public ranges.

                  - value:                   [Required] IPv4 or IPv6 address or CIDR range (e.g.
                                                        "203.0.113.0/24").

                    description:             [Optional] Human-readable name (e.g. "office-vpn").

      ── Maintenance Window ───────────────────────────────────────────────────────────────────────
      (entire block optional; omit it to keep GCP's default maintenance windows)

          maintenance_window:
              start_time:                    [Required] Start of the first window, RFC 3339. Only the
                                                        time of day and weekday pattern matter after
                                                        that. Example: "2024-01-01T02:00:00Z"

              end_time:                      [Required] End of the first window, RFC 3339; only used
                                                        to compute the duration (end - start). Each
                                                        window must last at least 4 hours. Example:
                                                        "2024-01-01T06:00:00Z"

              recurrence:                    [Required] RFC 5545 RRULE subset: "FREQ=DAILY" or
                                                        "FREQ=WEEKLY;BYDAY=<days>" with days from
                                                        SU,MO,TU,WE,TH,FR,SA. Composer needs at least
                                                        12 hours of maintenance per week in total,
                                                        e.g. 4 hours on "FREQ=WEEKLY;BYDAY=FR,SA,SU".
                                                        The plan fails if the window is too short.

      ── Encryption (CMEK) ────────────────────────────────────────────────────────────────────────
      (entire block optional; omit it for Google-managed encryption)

          encryption:
              enable_cmek:                   [Optional] Whether to use a customer-managed encryption
                                                        key. Creates a new key unless
                                                        existing_kms_key is given.
                                                        Default: false (true when existing_kms_key is
                                                        set)

              kms_key_ring_name:             [Optional] Name of the key ring to create, in the
                                                        environment's region. Only used when no
                                                        existing_kms_key is given.
                                                        Default: "{env-name}-keyring"

              kms_key_name:                  [Optional] Name of the crypto key to create. Only used
                                                        when no existing_kms_key is given.
                                                        Default: "{env-name}-key"

              kms_key_rotation_period:       [Optional] Automatic rotation period for a newly created
                                                        key.
                                                        Default: "7776000s" (90 days)

              existing_kms_key:              [Optional] Full resource ID of an existing key; implies
                                                        enable_cmek. Must be in the environment's
                                                        region (Composer rejects multi-regional and
                                                        global keys). Format:
                                                        projects/{p}/locations/{region}/
                                                        keyRings/{kr}/cryptoKeys/{k}
                                                        Default: null

          Automatic IAM bindings (when CMEK is enabled):
            - roles/cloudkms.cryptoKeyEncrypterDecrypter -> Composer service agent and Cloud Storage
              service agent, the two agents Composer 3 requires (the GCS agent is created if missing)

          Note: KMS keys created by the module have prevent_destroy = true. To destroy, remove the
          lifecycle block from modules/composer-3/kms.tf or use terraform state rm first.

      ── Recovery (scheduled snapshots) ───────────────────────────────────────────────────────────
      (entire block optional; omit it for no scheduled snapshots)

          recovery:
              enable_scheduled_snapshots:    [Optional] Whether scheduled snapshots are enabled.
                                                        Default: true (when block present)

              snapshot_location:             [Required] Required when snapshots are enabled. Cloud
                                                        Storage folder URI where snapshots are saved,
                                                        e.g. "gs://my-bucket/composer-snapshots" (not
                                                        a region). The bucket must exist and be
                                                        writable by the environment's service
                                                        account.

              snapshot_creation_schedule:    [Optional] Unix-cron expression (5 fields) for snapshot
                                                        creation.
                                                        Default: "0 3 * * *" (03:00 daily)

              time_zone:                     [Optional] Fixed UTC offset for the schedule, from
                                                        UTC-12 to UTC+12: "UTC", "UTC-06", "UTC+01".
                                                        IANA names such as "Europe/London" are
                                                        rejected, and daylight saving time is not
                                                        applied.
                                                        Default: "UTC"

      ── Data Retention ───────────────────────────────────────────────────────────────────────────
      (entire block optional; omit it for GCP's default retention behaviour)

          data_retention:
              airflow_metadata_retention_config:
                  retention_mode:            [Optional] Whether the Airflow metadata database
                                                        retention policy is active. Allowed:
                                                        "RETENTION_MODE_ENABLED",
                                                        "RETENTION_MODE_DISABLED"
                                                        Default: "RETENTION_MODE_ENABLED"

                  retention_days:            [Optional] Days to keep Airflow metadata (DAG runs, task
                                                        instances, ...) before cleanup, 30-730.
                                                        Ignored when retention is disabled.
                                                        Default: 30

          task_logs_retention_config is not supported in Composer 3 and is rejected by the module.

      ── Custom Storage ───────────────────────────────────────────────────────────────────────────
      (optional; omit it to let GCP create the environment bucket)

          storage:
              bucket:                        [Optional] Name of a pre-existing Cloud Storage bucket
                                                        for the environment's data (DAGs, plugins,
                                                        logs). A gs:// prefix is stripped. Cannot be
                                                        changed after creation.
                                                        Default: null (GCP auto-creates)

      ── Composer 2 Settings (rejected) ───────────────────────────────────────────────────────────
      The plan fails with a message naming the replacement if any of these are present:
      private_environment (-> enable_private_environment / enable_private_builds_only),
      master_authorized_networks (-> web_server_network_access_control), network.pods_range_name /
      pods_cidr / services_range_name / services_cidr (-> remove; not used by Composer 3),
      data_retention.task_logs_retention_config (-> remove).
```

---

## Sample Configurations

| Config File | Environments | Highlights |
|---|---|---|
| `configs/basic.yaml` | 1 (`composer-basic`) | Absolute minimum — just project_id + empty env |
| `configs/development.yaml` | 1 (`composer-dev`) | PyPI packages, 30-day metadata retention, 12 h/week maintenance window |
| `configs/production.yaml` | 1 (`composer-prod`) | Private IP, HA, CMEK, Cloud NAT, DAG processor, snapshots, Airflow UI allow-list, pinned Airflow version |
| `configs/private-ip.yaml` | 1 (`composer-private`) | Private IP + Cloud NAT, custom internal /20 range, Airflow UI allow-list, HA |
| `configs/multi-environment.yaml` | 3 (`dev`, `staging`, `prod`) | Public IP dev, Private IP staging, HA + CMEK prod, shared globals |

The bucket names in `snapshot_location` and the IP ranges in `web_server_network_access_control` are placeholders; replace them with your own before applying.

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

Each environment gets its own VPC, service account, and Composer instance. The module uses `for_each` internally, so adding or removing an environment is just editing the YAML. The plan fails if two environments would create a resource with the same name (for example two keys with the same `environment_name`). `environments:` with no entries plans zero environments, which is how you remove them all.

---

## Validation

Configuration errors are caught at plan time, before anything is created, in two layers:

**1. Module checks (`modules/composer-3/validation.tf`).** All problems for an environment are reported together in one error:

```
Error: Resource precondition failed
  ...
Invalid configuration for Composer environment "composer-dev":
  - maintenance_window is too short: Composer needs at least 12 hours of maintenance per week and at
    least 4 hours per slot. With 1 slot(s) per week each slot must last at least 12 hours (...)
  - data_retention.airflow_metadata_retention_config.retention_days must be between 30 and 730; got 14.
```

The checks exist because the provider skips its own validation of everything nested under `config` while any value there is still unknown at plan time, which is always the case when the network or service account is created in the same run. Without these checks, such mistakes would only fail during `apply`, after the network, IAM and KMS resources already exist. The root module also rejects resource-name collisions between environments.

**2. Python validator (`tests/validate_configs.py`).** Applies the same rules without running Terraform. It also does exact maintenance-window arithmetic and warns about unknown keys (usually typos, which the module silently ignores):

```bash
python tests/validate_configs.py                       # all configs/*.yaml
python tests/validate_configs.py configs/my-env.yaml   # specific files
```

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
| `image_version` | Composer image (the configured alias at plan time, the resolved build after apply) |
| `airflow_uri` | Airflow web UI URL |
| `dag_gcs_prefix` | GCS path for uploading DAGs |
| `gcs_bucket` | Environment's GCS bucket |
| `service_account_email` | SA email |
| `network_self_link` | VPC network self-link (null when not attached or when using a network attachment) |
| `subnetwork_self_link` | Subnet self-link (null when not attached or when using a network attachment) |
| `kms_key_id` | CMEK key ID (null when CMEK is off) |

---

## Project Structure

```
.
├── main.tf                          # Reads YAML, iterates environments via for_each, collision check
├── variables.tf                     # config_file variable
├── outputs.tf                       # Map of all environment outputs
├── versions.tf                      # Provider configuration
├── CHANGELOG.md                     # What changed and how to migrate
├── configs/
│   ├── basic.yaml                   # Minimal single-env
│   ├── development.yaml             # Dev single-env
│   ├── production.yaml              # Full prod single-env
│   ├── private-ip.yaml              # Private IP networking
│   └── multi-environment.yaml       # 3 environments in one file
├── modules/
│   └── composer-3/
│       ├── main.tf                  # google_composer_environment resource
│       ├── variables.tf             # environment_key, config, global_config
│       ├── locals.tf                # YAML merging + defaults
│       ├── validation.tf            # Plan-time configuration checks
│       ├── outputs.tf               # Module outputs
│       ├── versions.tf              # Provider requirements
│       ├── iam.tf                   # Service account + IAM bindings
│       ├── network.tf               # VPC, subnet, Cloud Router + NAT
│       ├── kms.tf                   # CMEK encryption resources
│       └── services.tf              # GCP API enablement + Composer service agent
└── tests/
    ├── setup/main.tf                # Standalone copy of the root wiring (for terraform validate)
    ├── fixtures/                    # YAML edge cases used by validation.tftest.hcl
    ├── basic.tftest.hcl             # Basic config test
    ├── production.tftest.hcl        # Production config test
    ├── validation.tftest.hcl        # All configs + YAML edge cases
    ├── module.tftest.hcl            # Child-module unit tests incl. one test per validation rule
    ├── provider_plan.tftest.hcl     # Plans every config against the real providers (offline)
    └── validate_configs.py          # Python YAML validation script
```

---

## Testing

```bash
# Formatting
terraform fmt -check -recursive

# Syntax + configuration validity
terraform validate

# YAML config validation (Python, needs PyYAML)
python tests/validate_configs.py

# Native Terraform tests (requires Terraform >= 1.7 for mock providers)
terraform init
terraform test
```

| Test file | Providers | Covers |
|---|---|---|
| `basic.tftest.hcl` | mock | Basic config, default Composer 3 image |
| `production.tftest.hcl` | mock | Production config |
| `validation.tftest.hcl` | mock | Every sample config, environment with no value, empty `environments`, name collisions, non-YAML file |
| `module.tftest.hcl` | mock | Child module: defaults, HA defaults, networking options, IAM, CMEK, rendering of every optional block, plus one failing run per validation rule |
| `provider_plan.tftest.hcl` | **real**, offline | Plans every sample config with the real google/google-beta providers, so the provider's Composer 3 rules (which mocks skip) are exercised. Uses a fake access token and overrides the one data source read at plan time, so it needs no credentials or network access |

No test needs GCP credentials. `terraform plan` against a real project does.

---

## Destroying

```bash
terraform destroy -var 'config_file=configs/my-env.yaml'
```

To remove one environment, delete its key from the YAML and apply. Removing every key (`environments:` with no entries) removes them all.

> **Note**: CMEK keys have `prevent_destroy = true`. Remove the lifecycle block or use `terraform state rm` before full destroy.

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Invalid configuration for Composer environment "..."` | Fix each listed setting; every message names the field and the accepted values |
| `Two environments in ... would create the same resource` | Give the environments distinct `environment_name`, `service_account.name`, `network.name` or `encryption.kms_key_ring_name` values |
| `... should only be used in Composer 3` | The provider could not tell the image is Composer 3. Set `software_config.image_version` to a literal `composer-3-airflow-*` value |
| `upgrade to composer 3 is not yet supported` | An existing Composer 2 environment cannot be moved to a Composer 3 image in place. Create a new environment under a new key, migrate, then remove the old one |
| `Error enabling API` | Ensure the deploying identity has `roles/serviceusage.serviceUsageAdmin` |
| `Service account ... does not exist` | The module generates the Composer service agent before binding it; if the error persists, wait a few minutes for IAM propagation and re-run `terraform apply` |
| Permission errors right after the first apply | IAM changes can take a few minutes to propagate; re-run `terraform apply` |
| `IP range overlap` | Each env creates its own VPC, so default CIDRs don't conflict. When sharing a VPC or connecting to other networks, customise `subnetwork_cidr` and `composer_internal_ipv4_cidr_block` |
| `Image version not found` / not supported | Run `gcloud composer environments list-image-versions --location=REGION`. Pinned builds are retired over time; use an alias such as `composer-3-airflow-2.11` or a newer build |
| Private IP environment cannot install PyPI packages | Set `enable_private_builds_only: false`, or serve the packages from a private repository |
| DAGs in a Private IP environment cannot reach the internet | Attach it to a VPC with Cloud NAT (`network.enable_cloud_nat: true`) |
| Empty `{}` env value | Valid — all settings use module defaults |
