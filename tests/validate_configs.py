"""Validate Composer 3 YAML configs before running Terraform.

Mirrors the checks in modules/composer-3/validation.tf and adds a few that are easier in Python:
exact maintenance-window arithmetic, resource-name collisions between environments, and
warnings for unknown (typically misspelled) keys, which the module would silently ignore.

Usage:
    python tests/validate_configs.py                  # every configs/*.yaml
    python tests/validate_configs.py path/to/env.yaml # specific files

Exit code 1 if any file has errors. Warnings never fail the run. Requires PyYAML.
"""

import glob
import ipaddress
import os
import re
import sys
from datetime import datetime, timedelta

import yaml

REPO_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

ENVIRONMENT_SIZES = [
    "ENVIRONMENT_SIZE_SMALL",
    "ENVIRONMENT_SIZE_MEDIUM",
    "ENVIRONMENT_SIZE_LARGE",
    "ENVIRONMENT_SIZE_EXTRA_LARGE",
]
RESILIENCE_MODES = ["STANDARD_RESILIENCE", "HIGH_RESILIENCE"]
RETENTION_MODES = ["RETENTION_MODE_ENABLED", "RETENTION_MODE_DISABLED"]
RESERVED_ENV_VARIABLES = {
    "AIRFLOW_HOME", "C_FORCE_ROOT", "CONTAINER_NAME", "DAGS_FOLDER", "GCP_PROJECT", "GCS_BUCKET",
    "GKE_CLUSTER_NAME", "SQL_DATABASE", "SQL_INSTANCE", "SQL_PASSWORD", "SQL_PROJECT", "SQL_REGION", "SQL_USER",
}
DEFAULT_SA_ROLES = ["roles/composer.worker", "roles/logging.logWriter", "roles/monitoring.metricWriter"]
DEFAULT_REGION = "europe-west2"

# Composer 3 per-component limits ("Scale environments" docs). cpu_step "half" = multiples of
# 0.5, "even" = 0.5, 1 or a multiple of 2. min memory is 2 GB instead of 1 GB with Airflow 3.
WORKLOAD_LIMITS = {
    "scheduler": {"cpu": (0.5, 2), "cpu_step": "half", "memory": (1, 8), "af3_min_memory": 2},
    "triggerer": {"cpu": (0.5, 1), "cpu_step": "half", "memory": (1, 8), "af3_min_memory": 2},
    "web_server": {"cpu": (1, 4), "cpu_step": "even", "memory": (2, 32), "af3_min_memory": 2},
    "worker": {"cpu": (0.5, 32), "cpu_step": "even", "memory": (1, 256), "af3_min_memory": 2},
    "dag_processor": {"cpu": (0.5, 32), "cpu_step": "even", "memory": (1, 256), "af3_min_memory": 2},
}
# Module defaults per component: (cpu, memory_gb, storage_gb); triggerer memory is 2 on Airflow 3.
WORKLOAD_DEFAULTS = {
    "scheduler": (0.5, 2, 1), "triggerer": (0.5, 1, None), "web_server": (1, 2, 1),
    "worker": (1, 2, 1), "dag_processor": (1, 2, 1),
}

IMAGE_VERSION_RE = re.compile(r"^composer-3-airflow-[0-9]+(\.[0-9]+(\.[0-9]+)?)?(-build\.[0-9]+)?$")
ENV_KEY_RE = re.compile(r"^[a-z][a-z0-9-]*$")
GCE_NAME_RE = re.compile(r"^[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?$")
SA_ID_RE = re.compile(r"^[a-z](?:[-a-z0-9]{4,28}[a-z0-9])$")
KMS_NAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,63}$")
KMS_KEY_ID_RE = re.compile(r"^projects/[^/]+/locations/([^/]+)/keyRings/[^/]+/cryptoKeys/[^/]+$")
LABEL_KEY_RE = re.compile(r"^[a-z][a-z0-9_-]{0,62}$")
LABEL_VALUE_RE = re.compile(r"^[a-z0-9_-]{0,63}$")
ENV_VAR_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")
AIRFLOW_ENV_OVERRIDE_RE = re.compile(r"^AIRFLOW__[A-Z0-9_]+__[A-Z0-9_]+$")
AIRFLOW_OVERRIDE_KEY_RE = re.compile(r"^[^-\[\].]+-[^=;.]+$")
TIME_ZONE_RE = re.compile(r"^UTC([+-](0?[0-9]|1[0-2]))?$")
WEEKLY_RE = re.compile(r"^FREQ=WEEKLY;BYDAY=((?:SU|MO|TU|WE|TH|FR|SA)(?:,(?:SU|MO|TU|WE|TH|FR|SA))*)$")

# Known keys, used to warn about typos. Nested dicts describe nested blocks.
WORKLOAD_KEYS = {
    "scheduler": {"cpu", "memory_gb", "storage_gb", "count"},
    "web_server": {"cpu", "memory_gb", "storage_gb"},
    "worker": {"cpu", "memory_gb", "storage_gb", "min_count", "max_count"},
    "triggerer": {"cpu", "memory_gb", "count"},
    "dag_processor": {"cpu", "memory_gb", "storage_gb", "count"},
}
ENV_SCHEMA = {
    "environment_name": None, "project_id": None, "region": None, "environment_size": None,
    "resilience_mode": None, "labels": "any", "enable_apis": None, "apis": None,
    "enable_private_environment": None, "enable_private_builds_only": None,
    "network": {"create", "name", "subnetwork_name", "subnetwork_cidr", "existing_network",
                "existing_subnetwork", "existing_network_attachment",
                "composer_internal_ipv4_cidr_block", "enable_cloud_nat", "tags"},
    "service_account": {"create", "name", "existing_email", "roles"},
    "software_config": {"image_version", "airflow_config_overrides", "env_variables", "pypi_packages",
                        "web_server_plugins_mode", "cloud_data_lineage_integration"},
    "workloads": WORKLOAD_KEYS,
    "web_server_network_access_control": {"allowed_ip_ranges"},
    "maintenance_window": {"start_time", "end_time", "recurrence"},
    "encryption": {"enable_cmek", "kms_key_ring_name", "kms_key_name", "kms_key_rotation_period", "existing_kms_key"},
    "recovery": {"enable_scheduled_snapshots", "snapshot_location", "snapshot_creation_schedule", "time_zone"},
    "data_retention": {"airflow_metadata_retention_config"},
    "storage": {"bucket"},
}
TOP_LEVEL_KEYS = {"project_id", "region", "labels", "enable_apis", "apis", "environments"}


def mapping(value):
    """Return value if it is a dict, {} for None/anything else (mirrors try(..., {}) in HCL)."""
    return value if isinstance(value, dict) else {}


def first(*values):
    """First value that is not None or "" (mirrors Terraform's coalesce)."""
    for v in values:
        if v is not None and v != "":
            return v
    return None


def tf_string(value):
    """String form Terraform's tostring() would produce."""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def parse_rfc3339(text):
    if not isinstance(text, str):
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def warn_unknown_keys(env_key, env, warnings):
    for key, value in env.items():
        if key in ("private_environment", "master_authorized_networks"):
            continue  # reported as errors
        if key not in ENV_SCHEMA:
            warnings.append(f"[{env_key}] unknown key '{key}' is ignored by the module")
            continue
        known = ENV_SCHEMA[key]
        if isinstance(known, set) and isinstance(value, dict):
            legacy = {"pods_range_name", "pods_cidr", "services_range_name", "services_cidr", "task_logs_retention_config"}
            for sub in value:
                if sub not in known and sub not in legacy:
                    warnings.append(f"[{env_key}] unknown key '{key}.{sub}' is ignored by the module")
        elif isinstance(known, dict) and isinstance(value, dict):
            for sub, subvalue in value.items():
                if sub not in known:
                    warnings.append(f"[{env_key}] unknown key '{key}.{sub}' is ignored by the module")
                    continue
                for leaf in mapping(subvalue):
                    if leaf not in known[sub]:
                        warnings.append(f"[{env_key}] unknown key '{key}.{sub}.{leaf}' is ignored by the module")


def check_environment(env_key, env, glob_cfg, errors, warnings):
    """Validate one environment; returns the IDs of named resources it would create."""
    e = lambda msg: errors.append(f"[{env_key}] {msg}")  # noqa: E731

    if not ENV_KEY_RE.match(env_key):
        e("environment key must start with a lowercase letter and contain only lowercase letters, digits and hyphens")

    warn_unknown_keys(env_key, env, warnings)

    name = first(env.get("environment_name"), env_key)
    project = first(env.get("project_id"), glob_cfg.get("project_id"))
    region = first(env.get("region"), glob_cfg.get("region"), DEFAULT_REGION)
    if project is None:
        e("no project_id: set it at the top of the file or in this environment")
    if not GCE_NAME_RE.match(str(name)):
        e(f"environment name '{name}' must be 1-63 lowercase letters, digits or hyphens, start with a letter and not end with a hyphen")

    # ── Composer 2 settings ──
    if env.get("private_environment") is not None:
        e("private_environment is Composer 2 configuration; use enable_private_environment / enable_private_builds_only")
    if env.get("master_authorized_networks") is not None:
        e("master_authorized_networks is Composer 2 configuration; use web_server_network_access_control")
    network = mapping(env.get("network"))
    legacy_ranges = sorted(set(network) & {"pods_range_name", "pods_cidr", "services_range_name", "services_cidr"})
    if legacy_ranges:
        e(f"network.{', network.'.join(legacy_ranges)}: GKE secondary ranges are not used by Composer 3; remove them")
    data_retention = mapping(env.get("data_retention"))
    if data_retention.get("task_logs_retention_config") is not None:
        e("data_retention.task_logs_retention_config is not supported for Composer 3; remove it")

    # ── Sizing & labels ──
    size = first(env.get("environment_size"), "ENVIRONMENT_SIZE_SMALL")
    if size not in ENVIRONMENT_SIZES:
        e(f"environment_size must be one of {', '.join(ENVIRONMENT_SIZES)}; got {size!r}")
    resilience = env.get("resilience_mode")
    if resilience is not None and resilience not in RESILIENCE_MODES:
        e(f"resilience_mode must be STANDARD_RESILIENCE or HIGH_RESILIENCE; got {resilience!r}")
    high_resilience = resilience == "HIGH_RESILIENCE"

    labels = dict(mapping(glob_cfg.get("labels")))
    labels.update(mapping(env.get("labels")))
    for k, v in labels.items():
        if not LABEL_KEY_RE.match(str(k)) or not LABEL_VALUE_RE.match(tf_string(v)):
            e(f"label {k}={tf_string(v)!r} must be lowercase (letters, digits, '_' and '-', max 63 characters)")

    # ── Software ──
    software = mapping(env.get("software_config"))
    image = first(software.get("image_version"), "composer-3-airflow-2")
    if not IMAGE_VERSION_RE.match(str(image)):
        e(f"image_version must be a Composer 3 image such as composer-3-airflow-2 or composer-3-airflow-2.11.1-build.19; got {image!r}")
    plugins = software.get("web_server_plugins_mode")
    if plugins is not None and plugins not in ("ENABLED", "DISABLED"):
        e(f"software_config.web_server_plugins_mode must be ENABLED or DISABLED; got {plugins!r}")
    lineage = software.get("cloud_data_lineage_integration")
    if lineage is not None and not isinstance(mapping(lineage).get("enabled"), bool):
        e("software_config.cloud_data_lineage_integration must be a block with enabled: true or false")
    for pkg in mapping(software.get("pypi_packages")):
        if pkg != pkg.lower():
            e(f"pypi package name {pkg!r} must be lowercase")
    for var in mapping(software.get("env_variables")):
        if not ENV_VAR_RE.match(var) or var in RESERVED_ENV_VARIABLES or AIRFLOW_ENV_OVERRIDE_RE.match(var):
            e(f"env_variables name {var!r} is invalid, reserved, or an AIRFLOW__SECTION__KEY override (use airflow_config_overrides)")
    for key in mapping(software.get("airflow_config_overrides")):
        if not AIRFLOW_OVERRIDE_KEY_RE.match(str(key)):
            e(f"airflow_config_overrides key {key!r} must use section-key format with a hyphen, e.g. core-dags_are_paused_at_creation")

    # ── Networking ──
    uses_existing = any(network.get(k) is not None for k in ("existing_network", "existing_subnetwork", "existing_network_attachment"))
    create_network = network.get("create") if network.get("create") is not None else not uses_existing
    if network.get("create") is True and uses_existing:
        e("network.create: true cannot be combined with existing_network / existing_subnetwork / existing_network_attachment")
    if (network.get("existing_network") is None) != (network.get("existing_subnetwork") is None):
        e("network.existing_network and network.existing_subnetwork must be set together")
    if network.get("existing_network_attachment") is not None and network.get("existing_network") is not None:
        e("network.existing_network_attachment cannot be combined with existing_network / existing_subnetwork")
    if network.get("enable_cloud_nat") and not create_network:
        e("network.enable_cloud_nat only applies to a VPC created by the module (network.create: true)")
    subnet_cidr = first(network.get("subnetwork_cidr"), "10.0.0.0/24")
    if create_network:
        try:
            ipaddress.IPv4Network(str(subnet_cidr), strict=False)
        except ValueError:
            e(f"network.subnetwork_cidr {subnet_cidr!r} is not a valid IPv4 CIDR block")
    internal = network.get("composer_internal_ipv4_cidr_block")
    if internal is not None:
        try:
            if ipaddress.IPv4Network(str(internal), strict=False).prefixlen != 20:
                raise ValueError
        except ValueError:
            e(f"network.composer_internal_ipv4_cidr_block must be an IPv4 /20 block; got {internal!r}")
    if env.get("enable_private_environment") and not create_network and not uses_existing:
        warnings.append(f"[{env_key}] Private IP environment without a VPC attachment has no internet access at all")
    if env.get("enable_private_environment") and software.get("pypi_packages") and env.get("enable_private_builds_only") is not False:
        warnings.append(f"[{env_key}] Private IP with pypi_packages: set enable_private_builds_only: false if packages come from public PyPI")

    web_acl = env.get("web_server_network_access_control")
    if web_acl is not None:
        ranges = mapping(web_acl).get("allowed_ip_ranges") or []
        if not ranges:
            e("web_server_network_access_control needs at least one allowed_ip_ranges entry (omit the block to allow all)")
        for r in ranges:
            try:
                ipaddress.ip_network(str(mapping(r).get("value")), strict=False)
            except ValueError:
                e(f"web_server_network_access_control entry {r!r} needs a value that is an IP address or CIDR range")

    # ── Service account ──
    sa = mapping(env.get("service_account"))
    create_sa = sa.get("create") if sa.get("create") is not None else sa.get("existing_email") is None
    sa_name = first(sa.get("name"), f"{name}-sa")
    if not create_sa and sa.get("existing_email") is None:
        e("service_account.create is false but existing_email is not set")
    if sa.get("create") is True and sa.get("existing_email") is not None:
        e("service_account.create: true cannot be combined with existing_email")
    roles = sa.get("roles") if sa.get("roles") is not None else DEFAULT_SA_ROLES
    if create_sa and "roles/composer.worker" not in roles:
        e("service_account.roles must include roles/composer.worker when the module creates the SA")
    if create_sa and not SA_ID_RE.match(str(sa_name)):
        e(f"service account id '{sa_name}' must be 6-30 lowercase letters, digits or hyphens; set service_account.name")

    # ── Workloads ──
    workloads = mapping(env.get("workloads"))
    for component, fields in WORKLOAD_KEYS.items():
        for field in fields:
            value = mapping(workloads.get(component)).get(field)
            if value is not None and (not is_number(value) or value < 0):
                e(f"workloads.{component}.{field} must be a non-negative number; got {value!r}")
    scheduler_count = first(mapping(workloads.get("scheduler")).get("count"), 2 if high_resilience else 1)
    worker = mapping(workloads.get("worker"))
    worker_min = first(worker.get("min_count"), 2 if high_resilience else 1)
    worker_max = first(worker.get("max_count"), max(3, worker_min) if is_number(worker_min) else 3)
    if is_number(worker_min) and is_number(worker_max) and worker_min > worker_max:
        e(f"workloads.worker.min_count ({worker_min}) must not exceed max_count ({worker_max})")
    triggerer = workloads.get("triggerer")
    dag_processor = workloads.get("dag_processor")
    triggerer_count = first(mapping(triggerer).get("count"), 2 if high_resilience else 1) if triggerer is not None else 0
    dag_count = first(mapping(dag_processor).get("count"), 2 if high_resilience else 1) if dag_processor is not None else None
    if is_number(worker_min) and is_number(worker_max) and (worker_min < 1 or worker_max > 100):
        e("workers autoscale between 1 and 100: min_count must be >= 1 and max_count <= 100")
    if is_number(scheduler_count) and not 1 <= scheduler_count <= 3:
        e(f"workloads.scheduler.count must be between 1 and 3; got {scheduler_count}")
    if is_number(triggerer_count) and not 0 <= triggerer_count <= 10:
        e(f"workloads.triggerer.count must be between 0 and 10; got {triggerer_count}")
    if is_number(dag_count) and not 1 <= dag_count <= 3:
        e(f"workloads.dag_processor.count must be between 1 and 3; got {dag_count}")

    airflow3 = str(image).startswith("composer-3-airflow-3")
    for component, limits in WORKLOAD_LIMITS.items():
        if component in ("triggerer", "dag_processor") and workloads.get(component) is None:
            continue  # not configured by the module; GCP applies its own sizing
        spec = mapping(workloads.get(component))
        d_cpu, d_mem, d_storage = WORKLOAD_DEFAULTS[component]
        if component == "triggerer" and airflow3:
            d_mem = 2
        cpu, mem = first(spec.get("cpu"), d_cpu), first(spec.get("memory_gb"), d_mem)
        storage = first(spec.get("storage_gb"), d_storage)
        if not (is_number(cpu) and is_number(mem)):
            continue  # reported above as non-numeric
        lo, hi = limits["cpu"]
        step_ok = float(cpu * 2).is_integer() if limits["cpu_step"] == "half" else (cpu in (0.5, 1) or cpu % 2 == 0)
        if not (lo <= cpu <= hi and step_ok):
            steps = "0.5" if limits["cpu_step"] == "half" else "0.5, 1 or a multiple of 2"
            e(f"workloads.{component}.cpu must be {lo}-{hi} vCPU in steps of {steps}; got {cpu}")
        mem_lo = limits["af3_min_memory"] if airflow3 else limits["memory"][0]
        if not (mem_lo <= mem <= limits["memory"][1] and float(mem * 4).is_integer()):
            e(f"workloads.{component}.memory_gb must be {mem_lo}-{limits['memory'][1]} GB in steps of 0.25; got {mem}")
        if cpu > 0 and not 1 <= mem / cpu <= 8:
            e(f"workloads.{component} needs 1-8 GB of memory per vCPU; got {mem} GB for {cpu} vCPU")
        if is_number(storage) and not (0 <= storage <= 100 and float(storage).is_integer()):
            e(f"workloads.{component}.storage_gb must be a whole number from 0 to 100; got {storage}")
    if high_resilience:
        if scheduler_count != 2:
            e(f"HIGH_RESILIENCE needs exactly 2 schedulers; got {scheduler_count}")
        if is_number(worker_min) and worker_min < 2:
            e(f"HIGH_RESILIENCE needs workloads.worker.min_count >= 2; got {worker_min}")
        if is_number(triggerer_count) and 0 < triggerer_count < 2:
            e(f"HIGH_RESILIENCE needs 0 or at least 2 triggerers; got {triggerer_count}")
        if is_number(dag_count) and dag_count < 2:
            e(f"HIGH_RESILIENCE needs at least 2 DAG processors; got {dag_count}")

    # ── Maintenance window: >= 4 h per slot and >= 12 h per week ──
    mw = env.get("maintenance_window")
    if mw is not None:
        mw = mapping(mw)
        start, end = parse_rfc3339(mw.get("start_time")), parse_rfc3339(mw.get("end_time"))
        recurrence = str(mw.get("recurrence") or "")
        slots = 7 if recurrence == "FREQ=DAILY" else (
            len(set(WEEKLY_RE.match(recurrence).group(1).split(","))) if WEEKLY_RE.match(recurrence) else 0)
        if start is None or end is None:
            e("maintenance_window.start_time and end_time must be RFC 3339 timestamps, e.g. 2024-01-01T02:00:00Z")
        if slots == 0:
            e(f"maintenance_window.recurrence must be FREQ=DAILY or FREQ=WEEKLY;BYDAY=<SU..SA>; got {recurrence!r}")
        if start is not None and end is not None and slots:
            duration = end - start
            if duration < timedelta(hours=4) or duration * slots < timedelta(hours=12):
                e(f"maintenance_window gives {duration} x {slots} slot(s)/week; Composer needs >= 4 h per slot and >= 12 h per week")

    # ── Encryption ──
    enc = mapping(env.get("encryption"))
    existing_key = enc.get("existing_kms_key")
    enable_cmek = enc.get("enable_cmek") if enc.get("enable_cmek") is not None else existing_key is not None
    if existing_key is not None:
        m = KMS_KEY_ID_RE.match(str(existing_key))
        if not m:
            e("encryption.existing_kms_key must be projects/<p>/locations/<region>/keyRings/<ring>/cryptoKeys/<key>")
        elif m.group(1) != region:
            e(f"encryption.existing_kms_key is in {m.group(1)!r}; Composer needs a key in the environment's region {region!r}")
    key_ring = first(enc.get("kms_key_ring_name"), f"{name}-keyring")
    create_key = enable_cmek and existing_key is None
    if create_key:
        for label, value in (("kms_key_ring_name", key_ring), ("kms_key_name", first(enc.get("kms_key_name"), f"{name}-key"))):
            if not KMS_NAME_RE.match(str(value)):
                e(f"encryption.{label} '{value}' must be 1-63 letters, digits, '_' or '-'")

    # ── Recovery ──
    recovery = env.get("recovery")
    if recovery is not None:
        recovery = mapping(recovery)
        if recovery.get("enable_scheduled_snapshots", True):
            location = recovery.get("snapshot_location")
            if not (isinstance(location, str) and re.match(r"^gs://[^/]+", location)):
                e(f"recovery.snapshot_location must be a gs:// bucket folder (not a region); got {location!r}")
            tz = first(recovery.get("time_zone"), "UTC")
            if not TIME_ZONE_RE.match(str(tz)):
                e(f"recovery.time_zone must be a UTC offset (UTC, UTC-06, UTC+01), not an IANA name; got {tz!r}")
            schedule = first(recovery.get("snapshot_creation_schedule"), "0 3 * * *")
            if len(str(schedule).split()) != 5:
                e(f"recovery.snapshot_creation_schedule must be a 5-field cron expression; got {schedule!r}")

    # ── Data retention ──
    metadata = data_retention.get("airflow_metadata_retention_config")
    if metadata is not None:
        metadata = mapping(metadata)
        mode = first(metadata.get("retention_mode"), "RETENTION_MODE_ENABLED")
        if mode not in RETENTION_MODES:
            e(f"retention_mode must be one of {', '.join(RETENTION_MODES)}; got {mode!r}")
        days = metadata.get("retention_days")
        if days is not None and (not is_number(days) or not 30 <= days <= 730):
            e(f"retention_days must be between 30 and 730; got {days!r}")

    # Named resources this environment creates (checked for collisions across the file).
    ids = [f"composer environment {project}/{region}/{name}"]
    if create_sa:
        ids.append(f"service account {project}/{sa_name}")
    if create_network:
        ids.append(f"network {project}/{first(network.get('name'), f'{name}-network')}")
        ids.append(f"subnetwork {project}/{region}/{first(network.get('subnetwork_name'), f'{name}-subnet')}")
    if create_key:
        ids.append(f"key ring {project}/{region}/{key_ring}")
    return ids


def validate_file(path):
    errors, warnings = [], []
    with open(path, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    if not isinstance(cfg, dict):
        return ["file must contain a YAML mapping"], warnings, []

    for key in cfg:
        if key not in TOP_LEVEL_KEYS:
            warnings.append(f"unknown top-level key '{key}' is ignored by the module")
    if cfg.get("project_id") is None:
        warnings.append("no global project_id; every environment must set its own")

    glob_cfg = {k: cfg.get(k) for k in ("project_id", "region", "labels")}
    envs = cfg.get("environments")
    if envs is None or envs == {}:
        warnings.append("no environments defined; terraform would plan (or destroy down to) zero environments")
        envs = {}
    elif not isinstance(envs, dict):
        return ["environments must be a mapping of environment keys"], warnings, []

    seen = {}
    for env_key, env in envs.items():
        for rid in check_environment(str(env_key), mapping(env), glob_cfg, errors, warnings):
            seen.setdefault(rid, []).append(str(env_key))
    for rid, keys in seen.items():
        if len(keys) > 1:
            errors.append(f"[{', '.join(keys)}] would all create {rid}")
    return errors, warnings, list(envs.keys())


def main(argv):
    paths = argv or sorted(glob.glob(os.path.join(REPO_ROOT, "configs", "*.yaml")))
    all_passed = True
    for path in paths:
        name = os.path.relpath(path, REPO_ROOT) if not argv else path
        errors, warnings, envs = validate_file(path)
        status = "FAILED" if errors else "PASSED"
        print(f"{name}: {status} ({len(envs)} env: {', '.join(map(str, envs))})")
        for msg in errors:
            print(f"  ERROR   {msg}")
        for msg in warnings:
            print(f"  WARNING {msg}")
        all_passed = all_passed and not errors
    if not all_passed:
        return 1
    print("\nAll config files validated successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
