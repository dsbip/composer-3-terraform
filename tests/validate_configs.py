"""YAML structure/constraint validation for the Composer 3 config files.

Usage:
    python tests/validate_configs.py                 # every configs/*.yaml + fixtures
    python tests/validate_configs.py FILE [FILE ...] # only the given files

Exits 1 when any file fails. The hibernation checks mirror
modules/composer-3-settings/main.tf (the Terraform precondition), but are
stricter about types: booleans must be YAML booleans and counts YAML integers
(Terraform also accepts e.g. the quoted string "true").
"""

import glob
import os
import re
import sys

import yaml

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# Validated in addition to configs/*.yaml when no files are given.
EXTRA_CONFIGS = ["tests/hibernation/fixtures/hibernation.yaml"]

valid_sizes = [
    "ENVIRONMENT_SIZE_SMALL",
    "ENVIRONMENT_SIZE_MEDIUM",
    "ENVIRONMENT_SIZE_LARGE",
]
valid_resilience = ["STANDARD_RESILIENCE", "HIGH_RESILIENCE"]

# ── Hibernation schema (keep in sync with modules/composer-3-settings) ──────
HIBERNATION_BOOL_KEYS = (
    "enabled",
    "create_snapshot_bucket",
    "pin_image_version",
    "delete_orphaned_bucket",
)
HIBERNATION_STRING_KEYS = ("snapshot_bucket", "snapshot_bucket_location", "snapshot_prefix")
HIBERNATION_KEYS = set(HIBERNATION_BOOL_KEYS) | set(HIBERNATION_STRING_KEYS) | {
    "snapshot_retention_count",
    "orphaned_bucket_retention_days",
    "load_options",
}
DEFAULT_LOAD_OPTIONS = {
    "skip_pypi_packages_installation": True,
    "skip_environment_variables_setting": True,
    "skip_airflow_overrides_setting": True,
    "skip_gcs_data_copying": False,
}
HIBERNATION_DEFAULTS = {
    "enabled": False,
    "create_snapshot_bucket": True,
    "snapshot_prefix": "composer-hibernation",
    "snapshot_retention_count": 7,
    "pin_image_version": True,
    "delete_orphaned_bucket": True,
    "orphaned_bucket_retention_days": 7,
}

PRODUCTION_LABEL_KEYS = ("env", "environment", "tier", "stage")
PRODUCTION_LABEL_VALUES = ("prod", "production", "prd")
PRODUCTION_NAME_RE = re.compile(r"(^|-)(prod|production|prd)(-|$)")
BUCKET_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$")
PREFIX_RE = re.compile(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$")


def is_bool(value):
    return isinstance(value, bool)


def is_int(value):
    # bool is a subclass of int in Python; `true` is not a count.
    return isinstance(value, int) and not isinstance(value, bool)


def as_mapping(value):
    """None -> {}, mappings as-is, anything else -> {} (reported elsewhere)."""
    return value if isinstance(value, dict) else {}


def without_nulls(mapping):
    """Explicit YAML nulls fall through to the next level, like in Terraform."""
    return {k: v for k, v in as_mapping(mapping).items() if v is not None}


def first_not_none(*values):
    for value in values:
        if value is not None:
            return value
    return None


# ── Resolution helpers (same semantics as modules/composer-3-settings) ──────
def environment_name(env_key, env_cfg):
    return first_not_none(as_mapping(env_cfg).get("environment_name"), env_key)


def merged_labels(cfg, env_cfg):
    labels = dict(as_mapping(as_mapping(cfg).get("labels")))
    labels.update(as_mapping(as_mapping(env_cfg).get("labels")))
    return labels


def _label_text(value):
    if is_bool(value):
        return "true" if value else "false"
    if isinstance(value, (dict, list)):
        return ""
    return str(value).lower()


def is_production(env_key, env_cfg, cfg):
    """Explicit env/environment/tier/stage labels win; otherwise the name decides."""
    labels = merged_labels(cfg, env_cfg)
    values = [_label_text(labels[k]) for k in PRODUCTION_LABEL_KEYS if labels.get(k) is not None]
    if values:
        return any(v in PRODUCTION_LABEL_VALUES for v in values)
    name = environment_name(env_key, env_cfg)
    return bool(PRODUCTION_NAME_RE.search(str(name).lower()))


def effective_hibernation(env_key, env_cfg, cfg):
    """Global -> per-env merge, field by field, with defaults applied."""
    cfg = as_mapping(cfg)
    env_cfg = as_mapping(env_cfg)
    global_block = as_mapping(cfg.get("hibernation"))
    env_block = as_mapping(env_cfg.get("hibernation"))

    merged = dict(HIBERNATION_DEFAULTS)
    merged.update(without_nulls(global_block))
    merged.update(without_nulls(env_block))

    load_options = dict(DEFAULT_LOAD_OPTIONS)
    load_options.update(without_nulls(global_block.get("load_options")))
    load_options.update(without_nulls(env_block.get("load_options")))
    merged["load_options"] = load_options

    project_id = first_not_none(env_cfg.get("project_id"), cfg.get("project_id"))
    region = first_not_none(env_cfg.get("region"), cfg.get("region"), "europe-west2")
    if merged.get("snapshot_bucket") is None:
        merged["snapshot_bucket"] = None if project_id is None else str(project_id) + "-composer-snapshots"
    if merged.get("snapshot_bucket_location") is None:
        merged["snapshot_bucket_location"] = region
    merged["snapshot_prefix"] = str(merged["snapshot_prefix"]).strip("/")
    return merged


# ── Hibernation checks ──────────────────────────────────────────────────────
def check_hibernation_block(block, where):
    """Type/schema checks for one hibernation block (global or per-env)."""
    errors = []
    if block is None:
        return errors
    if not isinstance(block, dict):
        return [where + " must be a mapping of settings"]

    for key in sorted(set(block) - HIBERNATION_KEYS):
        errors.append(where + "." + str(key) + " is not a supported setting (allowed: " + ", ".join(sorted(HIBERNATION_KEYS)) + ")")

    for key in HIBERNATION_BOOL_KEYS:
        value = block.get(key)
        if value is not None and not is_bool(value):
            errors.append(where + "." + key + " must be true or false, got " + repr(value))

    for key in HIBERNATION_STRING_KEYS:
        value = block.get(key)
        if value is not None and not isinstance(value, str):
            errors.append(where + "." + key + " must be a string, got " + repr(value))

    count = block.get("snapshot_retention_count")
    if count is not None and not (is_int(count) and count >= 1):
        errors.append(where + ".snapshot_retention_count must be a whole number >= 1, got " + repr(count))

    days = block.get("orphaned_bucket_retention_days")
    if days is not None and not (is_int(days) and days >= 0):
        errors.append(where + ".orphaned_bucket_retention_days must be a whole number >= 0, got " + repr(days))

    load_options = block.get("load_options")
    if load_options is not None:
        if not isinstance(load_options, dict):
            errors.append(where + ".load_options must be a mapping")
        else:
            for key, value in load_options.items():
                if key not in DEFAULT_LOAD_OPTIONS:
                    errors.append(where + ".load_options." + str(key) + " is not a supported option (allowed: " + ", ".join(sorted(DEFAULT_LOAD_OPTIONS)) + ")")
                elif value is not None and not is_bool(value):
                    errors.append(where + ".load_options." + key + " must be true or false, got " + repr(value))
    return errors


def check_effective_hibernation(env_key, env_cfg, cfg):
    """Checks on the merged settings; only relevant when hibernation is enabled."""
    errors = []
    hib = effective_hibernation(env_key, env_cfg, cfg)
    enabled = hib.get("enabled")
    # Terraform's tobool() also accepts the string "true": never let a quoted
    # value switch off the production guard.
    if not (enabled is True or enabled == "true"):
        return errors

    name = environment_name(env_key, env_cfg)
    if is_production(env_key, env_cfg, cfg):
        errors.append(
            "hibernation must not be enabled for production environment '" + str(name) + "' "
            "(detected from its env/environment/tier/stage label or its name)"
        )
    if first_not_none(as_mapping(env_cfg).get("project_id"), as_mapping(cfg).get("project_id")) is None:
        errors.append("hibernation requires project_id (global or per-environment)")

    bucket = hib.get("snapshot_bucket")
    if bucket is not None and not (isinstance(bucket, str) and BUCKET_RE.match(bucket)):
        errors.append(
            "hibernation.snapshot_bucket '" + str(bucket) + "' is not a valid bucket name "
            "(3-63 chars: lowercase letters, digits, '-' or '_'; no dots)"
        )
    prefix = hib.get("snapshot_prefix")
    if not PREFIX_RE.match(prefix):
        errors.append("hibernation.snapshot_prefix '" + prefix + "' must be a non-empty path of [A-Za-z0-9._-] segments")

    custom_bucket = as_mapping(as_mapping(env_cfg).get("storage")).get("bucket")
    if custom_bucket is not None and custom_bucket == bucket:
        errors.append("hibernation.snapshot_bucket must differ from storage.bucket (the environment's own bucket)")
    return errors


# ── Per-file validation ─────────────────────────────────────────────────────
def validate_config(cfg):
    errors = []
    if not isinstance(cfg, dict):
        return ["  config must be a YAML mapping"], {}

    if "project_id" not in cfg:
        errors.append("  missing global project_id")

    envs = cfg.get("environments") or {}
    if not isinstance(envs, dict):
        errors.append("  environments must be a mapping")
        envs = {}
    if not envs:
        errors.append("  no environments defined")

    for e in check_hibernation_block(cfg.get("hibernation"), "hibernation"):
        errors.append("  [global] " + e)

    for env_key, env_cfg in envs.items():
        prefix = "  [" + str(env_key) + "] "
        if env_cfg is None:
            env_cfg = {}
        if not isinstance(env_cfg, dict):
            errors.append(prefix + "environment settings must be a mapping")
            continue

        size = env_cfg.get("environment_size", "ENVIRONMENT_SIZE_SMALL")
        if size not in valid_sizes:
            errors.append(prefix + "invalid environment_size: " + str(size))

        resilience = env_cfg.get("resilience_mode", "STANDARD_RESILIENCE")
        if resilience not in valid_resilience:
            errors.append(prefix + "invalid resilience_mode: " + str(resilience))

        sw = env_cfg.get("software_config") or {}
        img = sw.get("image_version")
        if img is not None and not str(img).startswith("composer-3"):
            errors.append(prefix + "image_version must start with composer-3: " + str(img))

        for e in check_hibernation_block(env_cfg.get("hibernation"), "hibernation"):
            errors.append(prefix + e)
        # Like Terraform, the merged checks (production guard first) run even
        # when the block itself has errors.
        for e in check_effective_hibernation(env_key, env_cfg, cfg):
            errors.append(prefix + e)

    return errors, envs


def discover_configs(paths=None):
    """[(display name, path)] — configs/*.yaml by file stem, plus fixtures."""
    if paths:
        return [(os.path.splitext(os.path.basename(p))[0], p) for p in paths]
    found = sorted(glob.glob(os.path.join("configs", "*.yaml")) + glob.glob(os.path.join("configs", "*.yml")))
    configs = [(os.path.splitext(os.path.basename(p))[0], p) for p in found]
    configs += [(os.path.splitext(p)[0], p) for p in EXTRA_CONFIGS if os.path.exists(p)]
    return configs


def main(argv):
    # Explicit paths are relative to the caller's directory; discovery is
    # relative to the repository root.
    paths = [os.path.abspath(p) for p in argv]
    os.chdir(REPO_ROOT)
    configs = discover_configs(paths)
    if not configs:
        print("no config files found")
        return 1

    all_passed = True
    for name, path in configs:
        try:
            with open(path) as f:
                cfg = yaml.safe_load(f)
        except (OSError, yaml.YAMLError) as exc:
            print(name + ": FAILED")
            print("  could not read " + path + ": " + str(exc).replace("\n", " "))
            all_passed = False
            continue

        errors, envs = validate_config(cfg)
        if errors:
            print(name + ": FAILED")
            for e in errors:
                print(e)
            all_passed = False
        else:
            env_list = ", ".join(str(k) for k in envs.keys())
            print(name + ": PASSED (" + str(len(envs)) + " env: " + env_list + ")")

    if not all_passed:
        return 1
    print("\nAll config files validated successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
