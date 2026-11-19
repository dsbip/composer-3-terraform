#!/usr/bin/env bats
# ============================================================================
# Offline settings resolver (scripts/hibernation/resolver), run for real —
# exactly the way scripts/hibernation/lib/common.sh runs it:
#
#   TF_DATA_DIR=<tmp> terraform -chdir=scripts/hibernation/resolver init \
#       -input=false -backend-config=path=<tmp>/r.tfstate
#   ... apply -auto-approve -input=false -lock=false -var config_file=<ABS>
#   ... output -json environments
#
# against every configs/*.yaml and the fixtures in fixtures/resolver/.
# Each file gets its own TF_DATA_DIR and state, so a failed apply can never
# surface a previous file's outputs. Also cross-checks tests/validate_configs.py
# (same production/merge semantics) and that the global_config block cannot
# drift between main.tf, the resolver and tests/setup/main.tf.
#
# Run: bats tests/hibernation/resolver.bats
# ============================================================================

REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
RESOLVER_DIR="${REPO}/scripts/hibernation/resolver"
FIXTURES="${BATS_TEST_DIRNAME}/fixtures/resolver"
export CHECKPOINT_DISABLE=1

# resolve_into CONFIG DIR — runs the resolver; writes DIR/out.json and DIR/rc.
resolve_into() {
  local cfg="$1" dir="$2"
  mkdir -p "${dir}"
  : >"${dir}/log"
  if TF_DATA_DIR="${dir}/data" terraform -chdir="${RESOLVER_DIR}" init -input=false -no-color \
    -backend-config="path=${dir}/r.tfstate" >>"${dir}/log" 2>&1 &&
    TF_DATA_DIR="${dir}/data" terraform -chdir="${RESOLVER_DIR}" apply -auto-approve -input=false \
      -lock=false -no-color -var "config_file=${cfg}" >>"${dir}/log" 2>&1 &&
    TF_DATA_DIR="${dir}/data" terraform -chdir="${RESOLVER_DIR}" output -no-color -json environments \
      >"${dir}/out.json" 2>>"${dir}/log"; then
    echo 0 >"${dir}/rc"
  else
    echo 1 >"${dir}/rc"
    rm -f "${dir}/out.json"
  fi
}

# Result directory of a config: configs/basic.yaml -> config-basic,
# fixtures/resolver/merge.yaml -> merge.
result_dir() {
  local name
  name="$(basename "$1" .yaml)"
  [[ "$1" == "${REPO}/configs/"* ]] && name="config-${name}"
  printf '%s/%s\n' "${BATS_FILE_TMPDIR}/resolved" "${name}"
}

setup_file() {
  command -v terraform >/dev/null || skip "terraform not installed"
  local cfg
  for cfg in "${REPO}"/configs/*.yaml "${FIXTURES}"/*.yaml; do
    resolve_into "${cfg}" "$(result_dir "${cfg}")"
  done
}

# use NAME — selects a resolution for expect_*; fails with the log if the
# resolver failed for it.
use() {
  local dir="${BATS_FILE_TMPDIR}/resolved/$1"
  [[ -f "${dir}/rc" ]] || {
    echo "no resolution for $1" >&2
    return 1
  }
  if [[ "$(cat "${dir}/rc")" != 0 ]]; then
    echo "resolver failed for $1:" >&2
    cat "${dir}/log" >&2
    return 1
  fi
  RESOLVED="${dir}/out.json"
}

# expect_json FILTER EXPECTED — jq FILTER over the selected resolution must
# equal the JSON value EXPECTED (key order does not matter).
expect_json() {
  local actual expected
  actual="$(jq -cS "$1" "${RESOLVED}")" || return 1
  expected="$(jq -cnS "$2")" || {
    echo "invalid expected JSON: $2" >&2
    return 1
  }
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'jq %s\n  expected: %s\n  actual:   %s\n' "$1" "${expected}" "${actual}" >&2
    return 1
  fi
}

# expect_error_mentions ENV TEXT — some validation error of ENV contains TEXT.
expect_error_mentions() {
  if ! jq -e --arg k "$1" --arg t "$2" 'any(.[$k].validation_errors[]; contains($t))' "${RESOLVED}" >/dev/null; then
    printf 'no validation error of %s mentions "%s"; errors: %s\n' "$1" "$2" \
      "$(jq -c --arg k "$1" '.[$k].validation_errors' "${RESOLVED}")" >&2
    return 1
  fi
}

# YAML keys of environments (via PyYAML, independent of Terraform).
yaml_env_keys() {
  python3 -c 'import json, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
print(json.dumps(sorted((cfg.get("environments") or {}).keys())))' "$1"
}

# The same resolution computed by tests/validate_configs.py, for parity checks.
py_resolve() {
  python3 - "${REPO}/tests" "$1" <<'EOF'
import json, sys, yaml
sys.path.insert(0, sys.argv[1])
import validate_configs as v
cfg = yaml.safe_load(open(sys.argv[2]))
keys = ["enabled", "snapshot_bucket", "snapshot_bucket_location", "create_snapshot_bucket",
        "snapshot_prefix", "snapshot_retention_count", "pin_image_version",
        "delete_orphaned_bucket", "orphaned_bucket_retention_days", "load_options"]
out = {}
for k, e in (cfg.get("environments") or {}).items():
    hib = v.effective_hibernation(k, e, cfg)
    out[k] = {"is_production": v.is_production(k, e, cfg),
              "hibernation": {x: hib[x] for x in keys}}
print(json.dumps(out, sort_keys=True))
EOF
}

# Environments tests/validate_configs.py reports errors for (JSON array).
py_flagged_envs() {
  python3 - "${REPO}/tests" "$1" <<'EOF'
import json, re, sys, yaml
sys.path.insert(0, sys.argv[1])
import validate_configs as v
errors, _ = v.validate_config(yaml.safe_load(open(sys.argv[2])))
flagged = {m.group(1) for m in (re.match(r"  \[([^\]]+)\] ", e) for e in errors) if m and m.group(1) != "global"}
print(json.dumps(sorted(flagged)))
EOF
}

# global_config block of a root-like main.tf.
extract_global_config() {
  awk '/^  global_config = \{$/ { p = 1 } p { print } p && /^  \}$/ { exit }' "$1"
}

# ── Drift guard ─────────────────────────────────────────────────────────────

@test "global_config block is identical in main.tf, the resolver and tests/setup/main.tf" {
  local ref f
  ref="$(extract_global_config "${REPO}/main.tf")"
  # Sanity: the extraction found the whole block, including hibernation.
  [[ "$(wc -l <<<"${ref}")" -ge 8 ]]
  grep -q 'hibernation = try(local.raw_config.hibernation, null)' <<<"${ref}"
  for f in scripts/hibernation/resolver/main.tf tests/setup/main.tf; do
    diff -u --label main.tf --label "${f}" <(printf '%s\n' "${ref}") <(extract_global_config "${REPO}/${f}")
  done
}

@test "environments local and module inputs match between main.tf and the resolver" {
  local f line
  for f in main.tf scripts/hibernation/resolver/main.tf tests/setup/main.tf; do
    grep -qxF '  environments = try(local.raw_config.environments, {})' "${REPO}/${f}"
    grep -qxF '  for_each = local.environments' "${REPO}/${f}"
    for line in 'environment_key' 'config' 'global_config'; do
      grep -qE "^  ${line} +=( each\.key| each\.value| local\.global_config)$" "${REPO}/${f}"
    done
  done
  # Both resolve through the same settings module.
  grep -qF 'source   = "../../../modules/composer-3-settings"' "${RESOLVER_DIR}/main.tf"
  grep -qF 'source = "../composer-3-settings"' "${REPO}/modules/composer-3/settings.tf"
}

@test "resolver writes nothing into the repository" {
  # Everything Terraform could create: data dir, lock file, (backup) state.
  run find "${RESOLVER_DIR}" "${REPO}/modules/composer-3-settings" -mindepth 1 \
    \( -name '.terraform*' -o -name '*.tfstate*' -o -name 'terraform.tfstate.d' -o -name '*.tfplan' \)
  [ "${status}" -eq 0 ]
  [ -z "${output}" ] || {
    echo "resolver left files behind: ${output}" >&2
    false
  }
}

# ── configs/*.yaml ──────────────────────────────────────────────────────────

@test "every configs/*.yaml resolves with the YAML's environment keys and no validation errors" {
  local cfg name
  for cfg in "${REPO}"/configs/*.yaml; do
    name="$(basename "$(result_dir "${cfg}")")"
    use "${name}"
    expect_json 'keys' "$(yaml_env_keys "${cfg}")"
    expect_json '[.[].validation_errors[]]' '[]'
    expect_json '[.[] | select(.environment_name != .environment_key)]' '[]'
  done
}

@test "configs: hibernation is enabled exactly where the YAML enables it" {
  use config-basic
  expect_json 'map_values(.hibernation.enabled)' '{"composer-basic": false}'
  use config-development
  expect_json 'map_values(.hibernation.enabled)' '{"composer-dev": true}'
  use config-multi-environment
  expect_json 'map_values(.hibernation.enabled)' '{"composer-dev": true, "composer-staging": true, "composer-prod": false}'
  use config-production
  expect_json 'map_values(.hibernation.enabled)' '{"composer-prod": false}'
  use config-private-ip
  expect_json 'map_values(.hibernation.enabled)' '{"composer-private": false}'
  use config-hibernation
  expect_json 'map_values(.hibernation.enabled)' '{"composer-dev": true, "composer-qa": true, "composer-prod": false}'
}

@test "configs: production environments are detected and never hibernate" {
  local name
  for name in config-basic config-development config-multi-environment config-production config-private-ip config-hibernation; do
    use "${name}"
    expect_json '[.[] | select(.is_production and .hibernation.enabled)]' '[]'
  done
  use config-production
  expect_json '.["composer-prod"].is_production' 'true'
  use config-multi-environment
  expect_json 'map_values(.is_production)' '{"composer-dev": false, "composer-staging": false, "composer-prod": true}'
}

@test "configs/hibernation.yaml: dev pins the image, qa keeps its bucket, every default spelled out" {
  use config-hibernation
  expect_json '.["composer-dev"].image_version' '"composer-3-airflow-2.10.5"'
  expect_json '.["composer-dev"].custom_bucket' 'null'
  expect_json '.["composer-qa"].image_version' 'null'
  expect_json '.["composer-qa"].custom_bucket' '"my-gcp-project-composer-qa"'
  expect_json '.["composer-qa"].hibernation.snapshot_retention_count' '3'
  expect_json '.["composer-qa"].hibernation.snapshot_location' \
    '"gs://my-gcp-project-composer-snapshots/composer-hibernation/my-gcp-project/europe-west2/composer-qa"'
  # The global block lists every default: composer-dev resolves to them all.
  expect_json '.["composer-dev"].hibernation | del(.enabled, .snapshot_location, .state_object)' '{
    "snapshot_bucket": "my-gcp-project-composer-snapshots",
    "snapshot_bucket_location": "europe-west2",
    "create_snapshot_bucket": true,
    "snapshot_prefix": "composer-hibernation",
    "snapshot_retention_count": 7,
    "pin_image_version": true,
    "delete_orphaned_bucket": true,
    "orphaned_bucket_retention_days": 7,
    "load_options": {
      "skip_pypi_packages_installation": true,
      "skip_environment_variables_setting": true,
      "skip_airflow_overrides_setting": true,
      "skip_gcs_data_copying": false
    }
  }'
}

@test "configs/hibernation.yaml global block names every supported setting" {
  run python3 - "${REPO}/tests" "${REPO}/configs/hibernation.yaml" <<'EOF'
import sys, yaml
sys.path.insert(0, sys.argv[1])
import validate_configs as v
block = yaml.safe_load(open(sys.argv[2]))["hibernation"]
missing = sorted(v.HIBERNATION_KEYS - set(block)) + sorted(set(v.DEFAULT_LOAD_OPTIONS) - set(block["load_options"]))
print(" ".join(missing))
sys.exit(1 if missing else 0)
EOF
  [ "${status}" -eq 0 ] || {
    echo "missing settings: ${output}" >&2
    false
  }
}

# ── Merge semantics ─────────────────────────────────────────────────────────

@test "merge: an environment without overrides inherits every global setting" {
  use merge
  expect_json '.["composer-inherit"] | del(.hibernation)' '{
    "environment_key": "composer-inherit",
    "environment_name": "composer-inherit",
    "project_id": "global-project",
    "region": "europe-west1",
    "labels": {"managed_by": "terraform", "team": "platform", "env": "dev"},
    "is_production": false,
    "image_version": null,
    "custom_bucket": null,
    "service_account_email": "composer-inherit-sa@global-project.iam.gserviceaccount.com",
    "validation_errors": []
  }'
  expect_json '.["composer-inherit"].hibernation' '{
    "enabled": true,
    "snapshot_bucket": "global-snapshots",
    "snapshot_bucket_location": "europe-west1",
    "create_snapshot_bucket": true,
    "snapshot_prefix": "global/prefix",
    "snapshot_location": "gs://global-snapshots/global/prefix/global-project/europe-west1/composer-inherit",
    "state_object": "gs://global-snapshots/global/prefix/global-project/europe-west1/composer-inherit/hibernation-state.json",
    "snapshot_retention_count": 4,
    "pin_image_version": false,
    "delete_orphaned_bucket": true,
    "orphaned_bucket_retention_days": 3,
    "load_options": {
      "skip_pypi_packages_installation": false,
      "skip_environment_variables_setting": true,
      "skip_airflow_overrides_setting": true,
      "skip_gcs_data_copying": true
    }
  }'
}

@test "merge: per-env values win field by field, explicit nulls fall through" {
  use merge
  expect_json '.["composer-override"] | del(.hibernation)' '{
    "environment_key": "composer-override",
    "environment_name": "composer-renamed",
    "project_id": "other-project",
    "region": "us-central1",
    "labels": {"managed_by": "terraform", "team": "data", "env": "test"},
    "is_production": false,
    "image_version": "composer-3-airflow-2.9.3",
    "custom_bucket": "other-project-composer-data",
    "service_account_email": "custom-sa@other-project.iam.gserviceaccount.com",
    "validation_errors": []
  }'
  expect_json '.["composer-override"].hibernation' '{
    "enabled": true,
    "snapshot_bucket": "global-snapshots",
    "snapshot_bucket_location": "US",
    "create_snapshot_bucket": false,
    "snapshot_prefix": "team-a",
    "snapshot_location": "gs://global-snapshots/team-a/other-project/us-central1/composer-renamed",
    "state_object": "gs://global-snapshots/team-a/other-project/us-central1/composer-renamed/hibernation-state.json",
    "snapshot_retention_count": 1,
    "pin_image_version": false,
    "delete_orphaned_bucket": false,
    "orphaned_bucket_retention_days": 0,
    "load_options": {
      "skip_pypi_packages_installation": false,
      "skip_environment_variables_setting": true,
      "skip_airflow_overrides_setting": false,
      "skip_gcs_data_copying": true
    }
  }'
}

@test "merge: per-env enabled: false overrides the global enabled: true" {
  use merge
  expect_json '.["composer-existing-sa"].hibernation.enabled' 'false'
  expect_json '.["composer-existing-sa"].hibernation.snapshot_retention_count' '4'
}

@test "service_account_email: created (default and custom name) vs existing vs none" {
  use merge
  expect_json 'map_values(.service_account_email)' '{
    "composer-inherit": "composer-inherit-sa@global-project.iam.gserviceaccount.com",
    "composer-override": "custom-sa@other-project.iam.gserviceaccount.com",
    "composer-existing-sa": "shared-composer@global-project.iam.gserviceaccount.com"
  }'
  use defaults
  expect_json '.["composer-key"].service_account_email' '"composer-display-name-sa@defaults-project.iam.gserviceaccount.com"'
  expect_json '.["composer-no-sa"].service_account_email' 'null'
}

@test "defaults: region europe-west2, bucket <project>-composer-snapshots, location = region" {
  use defaults
  expect_json '.["composer-plain"] | {region, project_id, labels, image_version, custom_bucket, validation_errors}' '{
    "region": "europe-west2", "project_id": "defaults-project", "labels": {},
    "image_version": null, "custom_bucket": null, "validation_errors": []
  }'
  expect_json '.["composer-plain"].hibernation | {enabled, snapshot_bucket, snapshot_bucket_location, snapshot_prefix, snapshot_retention_count, orphaned_bucket_retention_days}' '{
    "enabled": false, "snapshot_bucket": "defaults-project-composer-snapshots",
    "snapshot_bucket_location": "europe-west2", "snapshot_prefix": "composer-hibernation",
    "snapshot_retention_count": 7, "orphaned_bucket_retention_days": 7
  }'
}

@test "defaults: per-env project/region drive the bucket, its location and the snapshot path" {
  use defaults
  expect_json '.["composer-elsewhere"] | {project_id, region}' '{"project_id": "elsewhere-project", "region": "us-east1"}'
  expect_json '.["composer-elsewhere"].hibernation | {snapshot_bucket, snapshot_bucket_location, snapshot_location, state_object}' '{
    "snapshot_bucket": "elsewhere-project-composer-snapshots",
    "snapshot_bucket_location": "us-east1",
    "snapshot_location": "gs://elsewhere-project-composer-snapshots/composer-hibernation/elsewhere-project/us-east1/composer-elsewhere",
    "state_object": "gs://elsewhere-project-composer-snapshots/composer-hibernation/elsewhere-project/us-east1/composer-elsewhere/hibernation-state.json"
  }'
}

@test "defaults: environment_name override drives the snapshot path, the key stays the key" {
  use defaults
  expect_json '.["composer-key"] | {environment_key, environment_name}' '{"environment_key": "composer-key", "environment_name": "composer-display-name"}'
  expect_json '.["composer-key"].hibernation.snapshot_location' \
    '"gs://defaults-project-composer-snapshots/composer-hibernation/defaults-project/europe-west2/composer-display-name"'
}

@test "labels: global labels merged with per-env labels, per-env wins" {
  use merge
  expect_json 'map_values(.labels)' '{
    "composer-inherit": {"managed_by": "terraform", "team": "platform", "env": "dev"},
    "composer-override": {"managed_by": "terraform", "team": "data", "env": "test"},
    "composer-existing-sa": {"managed_by": "terraform", "team": "platform", "env": "qa"}
  }'
}

# ── Production detection ────────────────────────────────────────────────────

@test "is_production: by env/environment/tier/stage label, explicit labels win over the name" {
  use production
  expect_json 'with_entries(select(.key | startswith("label-") or . == "composer-prod-replica" or . == "composer-team-label")) | map_values(.is_production)' '{
    "label-env-prod": true,
    "label-env-production": true,
    "label-env-prd": true,
    "label-environment": true,
    "label-tier": true,
    "label-stage-uppercase": true,
    "label-any-of-several": true,
    "label-env-dev": false,
    "label-env-preprod": false,
    "composer-prod-replica": false,
    "composer-team-label": false
  }'
}

@test "is_production: by name token when no environment label is set" {
  use production
  expect_json '{
    "composer-prod", "prod", "prod-composer", "composer-production", "composer-prd-2",
    "composer-preprod", "composer-product", "composer-prodx", "reproduction",
    "composer-renamed-to-prod", "composer-prod-key"
  } | map_values(.is_production)' '{
    "composer-prod": true,
    "prod": true,
    "prod-composer": true,
    "composer-production": true,
    "composer-prd-2": true,
    "composer-preprod": false,
    "composer-product": false,
    "composer-prodx": false,
    "reproduction": false,
    "composer-renamed-to-prod": true,
    "composer-prod-key": false
  }'
}

@test "is_production: production label inherited from global labels, overridable per env" {
  use global-labels
  expect_json 'map_values(.is_production)' '{"composer-analytics": true, "composer-sandbox": false}'
}

# ── Validation errors ───────────────────────────────────────────────────────

@test "validation_errors: one precise message per invalid setting" {
  use invalid
  expect_json 'map_values(.validation_errors)' '{
    "bad-enabled": ["hibernation.enabled must be true or false"],
    "bad-create-bucket": ["hibernation.create_snapshot_bucket must be true or false"],
    "bad-pin-image": ["hibernation.pin_image_version must be true or false"],
    "bad-delete-bucket": ["hibernation.delete_orphaned_bucket must be true or false"],
    "bad-retention-zero": ["hibernation.snapshot_retention_count must be a whole number >= 1"],
    "bad-retention-fraction": ["hibernation.snapshot_retention_count must be a whole number >= 1"],
    "bad-orphan-days": ["hibernation.orphaned_bucket_retention_days must be a whole number >= 0"],
    "bad-load-option-key": ["hibernation.load_options.skip_everything is not a supported option (allowed: skip_airflow_overrides_setting, skip_environment_variables_setting, skip_gcs_data_copying, skip_pypi_packages_installation)"],
    "bad-load-option-value": ["hibernation.load_options.skip_gcs_data_copying must be true or false"],
    "bad-bucket-name": ["hibernation.snapshot_bucket '"'"'Bad_Bucket!'"'"' is not a valid bucket name (3-63 chars: lowercase letters, digits, '"'"'-'"'"' or '"'"'_'"'"'; no dots)"],
    "bad-bucket-dots": ["hibernation.snapshot_bucket '"'"'my.dotted.bucket'"'"' is not a valid bucket name (3-63 chars: lowercase letters, digits, '"'"'-'"'"' or '"'"'_'"'"'; no dots)"],
    "bad-prefix": ["hibernation.snapshot_prefix '"'"'two words'"'"' must be a non-empty path of [A-Za-z0-9._-] segments"],
    "bucket-equals-storage": ["hibernation.snapshot_bucket must differ from storage.bucket (the environment'"'"'s own bucket)"],
    "not-a-map": ["environments.not-a-map.hibernation must be a map of settings"],
    "prod-by-label": ["hibernation must not be enabled for production environment '"'"'prod-by-label'"'"' (detected from its env/environment/tier/stage label or its name). Hibernation is for non-production environments only."],
    "composer-prod": ["hibernation must not be enabled for production environment '"'"'composer-prod'"'"' (detected from its env/environment/tier/stage label or its name). Hibernation is for non-production environments only."],
    "two-errors": [
      "hibernation.snapshot_retention_count must be a whole number >= 1",
      "hibernation.orphaned_bucket_retention_days must be a whole number >= 0"
    ],
    "disabled-bad-bucket": []
  }'
}

@test "validation_errors: an invalid value never enables hibernation" {
  use invalid
  expect_json '.["bad-enabled"].hibernation.enabled' 'false'
  expect_json '.["not-a-map"].hibernation.enabled' 'false'
}

@test "validation_errors: global hibernation that is not a map" {
  use global-not-a-map
  expect_json '.["composer-dev"].validation_errors' '["global '"'"'hibernation'"'"' must be a map of settings"]'
}

@test "validation_errors: hibernation without any project_id" {
  use no-project
  expect_json '.["composer-dev"].validation_errors' '[
    "hibernation requires project_id (global or per-environment)",
    "hibernation.snapshot_bucket '"'"'<null>'"'"' is not a valid bucket name (3-63 chars: lowercase letters, digits, '"'"'-'"'"' or '"'"'_'"'"'; no dots)"
  ]'
  expect_json '.["composer-dev"].hibernation | {snapshot_bucket, snapshot_location, state_object}' \
    '{"snapshot_bucket": null, "snapshot_location": null, "state_object": null}'
  # Disabled hibernation without a project is not an error for the resolver.
  expect_json '.["composer-off"].validation_errors' '[]'
}

@test "validation_errors: unknown hibernation settings are reported, not silently ignored" {
  # docs/hibernation.md: "Invalid values (wrong types, unknown keys, ...) fail
  # terraform plan". A typo such as snapshot_retension_count would otherwise
  # silently fall back to the default retention.
  use unknown-keys
  expect_error_mentions composer-typo snapshot_retension_count
  expect_error_mentions composer-typo snapshot_retention
}

@test "validation_errors: load_options that is not a map is reported" {
  use unknown-keys
  expect_error_mentions composer-load-options-not-a-map load_options
}

# ── YAML quirks and empty values ────────────────────────────────────────────

@test "YAML 1.1 booleans and quoted booleans resolve via tobool" {
  use yaml-quirks
  expect_json 'with_entries(select(.key | test("quoted|capitalised"))) | map_values(.hibernation.enabled)' '{
    "yes-unquoted": true,
    "on-unquoted": true,
    "true-capitalised": true,
    "true-quoted": true,
    "false-quoted": false,
    "no-unquoted": false,
    "yes-quoted": false,
    "count-quoted": true
  }'
  expect_json '.["yes-quoted"].validation_errors' '["hibernation.enabled must be true or false"]'
  expect_json '[to_entries[] | select(.key != "yes-quoted") | .value.validation_errors[]]' '[]'
  expect_json '.["count-quoted"].hibernation.snapshot_retention_count' '3'
}

@test "value-less (null) environment, {} and null hibernation all resolve to defaults" {
  use yaml-quirks
  expect_json '{"null-env", "empty-env", "null-hibernation"} | map_values({environment_name, labels, service_account_email, enabled: .hibernation.enabled, retention: .hibernation.snapshot_retention_count, errors: .validation_errors})' '{
    "null-env": {"environment_name": "null-env", "labels": {"env": "dev"}, "service_account_email": "null-env-sa@quirks-project.iam.gserviceaccount.com", "enabled": false, "retention": 7, "errors": []},
    "empty-env": {"environment_name": "empty-env", "labels": {"env": "dev"}, "service_account_email": "empty-env-sa@quirks-project.iam.gserviceaccount.com", "enabled": false, "retention": 7, "errors": []},
    "null-hibernation": {"environment_name": "null-hibernation", "labels": {"env": "dev"}, "service_account_email": "null-hibernation-sa@quirks-project.iam.gserviceaccount.com", "enabled": false, "retention": 7, "errors": []}
  }'
}

@test "empty environments map and missing environments key resolve to {}" {
  use empty-environments
  expect_json '.' '{}'
  use no-environments-key
  expect_json '.' '{}'
}

@test "environments: without a value is refused (like terraform plan of the root module)" {
  local dir="${BATS_FILE_TMPDIR}/resolved/null-environments"
  [ "$(cat "${dir}/rc")" = 1 ]
  [ ! -e "${dir}/out.json" ]
  grep -q 'local.environments is null' "${dir}/log"
}

@test "explicit null region/project_id per environment fall through to the global values" {
  # Same precedence as every other setting: per-env > global > default.
  use null-identity
  expect_json '.["composer-null-region"] | {project_id, region}' '{"project_id": "identity-project", "region": "europe-west3"}'
  expect_json '.["composer-null-project"] | {project_id, region}' '{"project_id": "identity-project", "region": "europe-west3"}'
  expect_json '.["composer-null-project"].validation_errors' '[]'
}

@test "explicit null environment_name falls back to the environment key" {
  use null-environment-name
  expect_json '.["composer-null-name"].environment_name' '"composer-null-name"'
}

# ── Parity with tests/validate_configs.py ───────────────────────────────────

@test "validate_configs.py resolves production + merged hibernation exactly like the resolver" {
  local name cfg
  for name in merge defaults production global-labels config-basic config-development \
    config-multi-environment config-production config-private-ip config-hibernation; do
    use "${name}"
    cfg="${FIXTURES}/${name}.yaml"
    [[ "${name}" == config-* ]] && cfg="${REPO}/configs/${name#config-}.yaml"
    diff -u --label resolver --label validate_configs.py \
      <(jq -S 'map_values({is_production, hibernation: (.hibernation | del(.snapshot_location, .state_object))})' "${RESOLVED}") \
      <(py_resolve "${cfg}" | jq -S .)
  done
}

@test "validate_configs.py flags the same invalid environments as the resolver" {
  use invalid
  diff -u --label resolver --label validate_configs.py \
    <(jq -c '[to_entries[] | select(.value.validation_errors != []) | .key] | sort' "${RESOLVED}") \
    <(py_flagged_envs "${FIXTURES}/invalid.yaml" | jq -c .)
}

@test "validate_configs.py is stricter on types: quoted booleans/counts are rejected" {
  run py_flagged_envs "${FIXTURES}/yaml-quirks.yaml"
  [ "${status}" -eq 0 ]
  [ "${output}" = '["count-quoted", "false-quoted", "true-quoted", "yes-quoted"]' ]
}

@test "validate_configs.py rejects unknown hibernation keys and non-map load_options" {
  run python3 "${REPO}/tests/validate_configs.py" "${FIXTURES}/unknown-keys.yaml"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"[global] hibernation.snapshot_retention is not a supported setting"* ]]
  [[ "${output}" == *"[composer-typo] hibernation.snapshot_retension_count is not a supported setting"* ]]
  [[ "${output}" == *"[composer-load-options-not-a-map] hibernation.load_options must be a mapping"* ]]
}

@test "validate_configs.py passes every config plus the hibernation fixture" {
  run python3 "${REPO}/tests/validate_configs.py"
  [ "${status}" -eq 0 ]
  local cfg
  for cfg in "${REPO}"/configs/*.yaml; do
    [[ "${output}" == *"$(basename "${cfg}" .yaml): PASSED"* ]]
  done
  [[ "${output}" == *"tests/hibernation/fixtures/hibernation: PASSED (3 env: composer-dev, composer-test, composer-prod)"* ]]
  [[ "${output}" == *"All config files validated successfully."* ]]
}
