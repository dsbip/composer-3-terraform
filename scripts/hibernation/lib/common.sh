#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034  # OPT_* / HIB_* globals are consumed by the sourcing scripts
# ============================================================================
# Shared library for composer-shutdown.sh and composer-startup.sh.
#
#   * logging / GitLab collapsible sections
#   * option parsing shared by both scripts
#   * offline YAML resolution (scripts/hibernation/resolver)
#   * Terraform helpers (init, targeted plan, plan guard, apply)
#   * gcloud helpers (Composer describe / snapshot save+load / operations,
#     Cloud Storage objects + buckets) with not-found detection and retries
#   * the hibernation state file ("manifest") kept next to the snapshots
#
# Every function that talks to GCP goes through `gcloud`, every function that
# changes infrastructure goes through `terraform`, so the test-suite can swap
# both binaries for simulators via PATH.
# ============================================================================

# ── Constants ───────────────────────────────────────────────────────────────
HIB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIB_SCRIPTS_DIR="$(cd "${HIB_LIB_DIR}/.." && pwd)"
HIB_REPO_ROOT="$(cd "${HIB_SCRIPTS_DIR}/../.." && pwd)"
HIB_RESOLVER_DIR="${HIB_SCRIPTS_DIR}/resolver"

HIB_MANIFEST_SCHEMA_VERSION=1
HIB_HISTORY_MAX=50

# Exit codes
HIB_EXIT_OK=0
HIB_EXIT_FAILED=1   # at least one environment failed
HIB_EXIT_USAGE=2    # bad arguments / configuration / prerequisites

# Return code used by describe/read helpers for "does not exist".
HIB_RC_NOT_FOUND=3

# ── Defaults (overridable through the environment) ─────────────────────────
: "${TF_ROOT:=${HIB_REPO_ROOT}}"
: "${TF_MODULE_ADDRESS:=module.composer}"
: "${TF_LOCK_TIMEOUT:=20m}"
: "${HIBERNATE_OPERATION_TIMEOUT_MINUTES:=90}" # snapshot save / load
: "${HIBERNATE_WAIT_TIMEOUT_MINUTES:=60}"      # waiting for RUNNING etc.
: "${HIBERNATE_POLL_SECONDS:=30}"
: "${HIBERNATE_MAX_PARALLEL:=4}"
: "${HIBERNATE_GCLOUD_RETRIES:=3}"
: "${HIBERNATE_RETRY_SLEEP_SECONDS:=10}"
: "${HIBERNATE_LOAD_ATTEMPTS:=2}"              # a retried load resumes a partial one
: "${HIBERNATE_SKIP_IMAGE_CHECK:=false}"       # skip the "can it be recreated?" check
: "${HIBERNATE_COMPOSER_API:=https://composer.googleapis.com}"

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# ── Logging ─────────────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() { printf '%s %-5s %s\n' "$(_ts)" "$1" "${*:2}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() { log ERROR "$@"; }
die() {
  error "$@"
  exit "${HIB_EXIT_USAGE}"
}

# GitLab collapsible log sections (plain markers elsewhere).
section_start() {
  local id="$1" title="$2"
  if [[ -n "${GITLAB_CI:-}" ]]; then
    printf '\e[0Ksection_start:%s:%s[collapsed=false]\r\e[0K%s\n' "$(date +%s)" "${id}" "${title}" >&2
  else
    printf '\n==== %s ====\n' "${title}" >&2
  fi
}

section_end() {
  local id="$1"
  if [[ -n "${GITLAB_CI:-}" ]]; then
    printf '\e[0Ksection_end:%s:%s\r\e[0K\n' "$(date +%s)" "${id}" >&2
  fi
}

# ── Generic helpers ─────────────────────────────────────────────────────────
require_cmds() {
  local missing=() c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  if ((${#missing[@]})); then
    die "required command(s) not found on PATH: ${missing[*]}"
  fi
}

is_true() {
  case "${1,,}" in
  1 | true | yes | y | on) return 0 ;;
  *) return 1 ;;
  esac
}

# Seconds since epoch.
now_epoch() { date -u +%s; }

# Runs "$@" up to HIBERNATE_GCLOUD_RETRIES times; stdout of the last attempt
# is passed through. Not-found (rc 3 from our wrappers) is never retried.
retry() {
  local attempt=1 rc=0 out
  out="$(mktemp)"
  while :; do
    "$@" >"${out}" && rc=0 || rc=$?
    if ((rc == 0 || rc == HIB_RC_NOT_FOUND || attempt >= HIBERNATE_GCLOUD_RETRIES)); then
      cat "${out}"
      rm -f "${out}"
      return "${rc}"
    fi
    warn "attempt ${attempt}/${HIBERNATE_GCLOUD_RETRIES} failed (rc=${rc}): $*; retrying in ${HIBERNATE_RETRY_SLEEP_SECONDS}s"
    sleep "${HIBERNATE_RETRY_SLEEP_SECONDS}"
    attempt=$((attempt + 1))
  done
}

# True when a gcloud error text means "the resource does not exist".
is_not_found_error() {
  grep -Eqi 'not found: 404|NOT_FOUND|matched no objects|HTTPError 404|was not found|does not exist' <<<"$1"
}

# Splits comma/space separated words into one-per-line.
split_words() { tr ',[:space:]' '\n' <<<"$*" | sed '/^$/d'; }

# "composer-3-airflow-2.10.5-build.17" -> "composer-3-airflow-2.10.5"
# The build suffix is dropped because individual builds are retired over time;
# the X.Y.Z alias keeps the same Airflow version on the newest available build.
image_version_pin() {
  local v="$1"
  if [[ "${v}" =~ ^(composer-3-airflow-[0-9]+\.[0-9]+\.[0-9]+)(-build\.[0-9]+)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# "composer-3-airflow-2.10.5-build.17" -> "2.10.5"
airflow_version_of() {
  local v="$1"
  if [[ "${v}" =~ -airflow-([0-9]+(\.[0-9]+)*) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

# version_ge A B: dotted numeric comparison, true when A >= B.
version_ge() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# airflow_version_satisfies TARGET SNAPSHOT
# True when an environment on Airflow TARGET (possibly an alias such as "2" or
# "2.10") can load a snapshot taken on Airflow SNAPSHOT: same major version
# and same-or-later version, compared at the precision TARGET specifies.
airflow_version_satisfies() {
  local target="$1" snap="$2" n
  [[ -n "${target}" && -n "${snap}" ]] || return 1
  [[ "${target%%.*}" == "${snap%%.*}" ]] || return 1
  n="$(awk -F. '{print NF}' <<<"${target}")"
  snap="$(cut -d. -f1-"${n}" <<<"${snap}")"
  version_ge "${target}" "${snap}"
}

# Extracts the bucket name from "gs://bucket/dags".
bucket_from_gcs_uri() {
  local uri="$1"
  if [[ "${uri}" =~ ^gs://([^/]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

# Only buckets that look like Composer-created environment buckets
# ("<region>-<env-name...>-<hash>-bucket") may be deleted automatically.
is_safe_orphan_bucket() {
  local bucket="$1" region="$2" env_name="$3" snapshot_bucket="$4" custom_bucket="$5" re name_part
  [[ -n "${bucket}" && -n "${region}" && -n "${env_name}" ]] || return 1
  [[ "${bucket}" != "${snapshot_bucket}" ]] || return 1
  [[ -z "${custom_bucket}" || "${bucket}" != "${custom_bucket}" ]] || return 1
  re="^${region}-(.+)-[a-z0-9]+-bucket\$"
  [[ "${bucket}" =~ ${re} ]] || return 1
  name_part="${BASH_REMATCH[1]}"
  # Composer truncates long names: the name part must be this environment's
  # full name, or a prefix of it at least 10 characters long.
  [[ "${name_part}" == "${env_name}" ]] && return 0
  ((${#name_part} >= 10)) && [[ "${env_name}" == "${name_part}"* ]]
}

# ── Option parsing (shared) ─────────────────────────────────────────────────
# Populates: OPT_CONFIG OPT_ENVS[] OPT_DRY_RUN OPT_SKIP_INIT OPT_WORK_DIR
#            OPT_VAR_FILES[] OPT_FORCE_NO_SNAPSHOT OPT_ALLOW_INITIAL_CREATE
#            OPT_SKIP_LOAD
OPT_CONFIG="${HIBERNATE_CONFIG_FILE:-}"
OPT_ENVS=()
OPT_DRY_RUN=false
OPT_SKIP_INIT=false
OPT_WORK_DIR="${HIBERNATE_WORK_DIR:-}"
OPT_VAR_FILES=()
OPT_FORCE_NO_SNAPSHOT=false
OPT_ALLOW_INITIAL_CREATE=false
OPT_SKIP_LOAD=false

parse_common_args() {
  local mode="$1"
  shift
  if [[ -n "${HIBERNATE_ENVIRONMENTS:-}" ]]; then
    mapfile -t OPT_ENVS < <(split_words "${HIBERNATE_ENVIRONMENTS}")
  fi
  is_true "${HIBERNATE_DRY_RUN:-false}" && OPT_DRY_RUN=true
  is_true "${HIBERNATE_SKIP_INIT:-false}" && OPT_SKIP_INIT=true
  if [[ -n "${HIBERNATE_TF_VAR_FILES:-}" ]]; then
    mapfile -t OPT_VAR_FILES < <(split_words "${HIBERNATE_TF_VAR_FILES}")
  fi

  while (($#)); do
    case "$1" in
    -c | --config)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      OPT_CONFIG="$2"
      shift 2
      ;;
    --config=*)
      OPT_CONFIG="${1#*=}"
      shift
      ;;
    -e | --env)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      mapfile -t -O "${#OPT_ENVS[@]}" OPT_ENVS < <(split_words "$2")
      shift 2
      ;;
    --env=*)
      mapfile -t -O "${#OPT_ENVS[@]}" OPT_ENVS < <(split_words "${1#*=}")
      shift
      ;;
    --var-file)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      OPT_VAR_FILES+=("$2")
      shift 2
      ;;
    --var-file=*)
      OPT_VAR_FILES+=("${1#*=}")
      shift
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      OPT_WORK_DIR="$2"
      shift 2
      ;;
    --work-dir=*)
      OPT_WORK_DIR="${1#*=}"
      shift
      ;;
    -n | --dry-run)
      OPT_DRY_RUN=true
      shift
      ;;
    --skip-init)
      OPT_SKIP_INIT=true
      shift
      ;;
    --force-delete-without-snapshot)
      [[ "${mode}" == shutdown ]] || die "$1 is only valid for composer-shutdown.sh"
      OPT_FORCE_NO_SNAPSHOT=true
      shift
      ;;
    --allow-initial-create)
      [[ "${mode}" == startup ]] || die "$1 is only valid for composer-startup.sh"
      OPT_ALLOW_INITIAL_CREATE=true
      shift
      ;;
    --skip-load)
      [[ "${mode}" == startup ]] || die "$1 is only valid for composer-startup.sh"
      OPT_SKIP_LOAD=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
    esac
  done

  [[ -n "${OPT_CONFIG}" ]] || die "--config (or HIBERNATE_CONFIG_FILE) is required"
}

# ── Work directory (logs, plans, manifests, summary — kept as CI artifacts) ─
init_work_dir() {
  local mode="$1"
  if [[ -z "${OPT_WORK_DIR}" ]]; then
    OPT_WORK_DIR="${TF_ROOT}/.hibernation/${mode}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  mkdir -p "${OPT_WORK_DIR}/logs" "${OPT_WORK_DIR}/plans" "${OPT_WORK_DIR}/state" "${OPT_WORK_DIR}/results"
  OPT_WORK_DIR="$(cd "${OPT_WORK_DIR}" && pwd)"
  info "work dir: ${OPT_WORK_DIR}"
}

# ── Configuration resolution ────────────────────────────────────────────────
# Sets CONFIG_ABS (absolute path), CONFIG_REL (relative to TF_ROOT, which is
# what the root module's config_file variable expects) and writes the
# resolved settings for every environment to ${OPT_WORK_DIR}/resolved.json.
RESOLVED_JSON=""
CONFIG_ABS=""
CONFIG_REL=""

resolve_config() {
  local cfg="${OPT_CONFIG}"
  if [[ "${cfg}" != /* ]]; then
    # Relative paths are relative to TF_ROOT (like the root module's
    # config_file variable), falling back to the current directory.
    if [[ -f "${TF_ROOT}/${cfg}" ]]; then
      cfg="${TF_ROOT}/${cfg}"
    else
      cfg="${PWD}/${cfg}"
    fi
  fi
  [[ -f "${cfg}" ]] || die "config file not found: ${OPT_CONFIG}"
  CONFIG_ABS="$(cd "$(dirname "${cfg}")" && pwd)/$(basename "${cfg}")"
  CONFIG_REL="$(realpath --relative-to="${TF_ROOT}" "${CONFIG_ABS}")"

  local data_dir="${OPT_WORK_DIR}/resolver/data" state="${OPT_WORK_DIR}/resolver/resolver.tfstate"
  local log="${OPT_WORK_DIR}/logs/resolver.log"
  mkdir -p "${data_dir}"
  RESOLVED_JSON="${OPT_WORK_DIR}/resolved.json"

  if ! TF_DATA_DIR="${data_dir}" terraform -chdir="${HIB_RESOLVER_DIR}" init -input=false -no-color \
    -backend-config="path=${state}" >"${log}" 2>&1; then
    cat "${log}" >&2
    die "could not initialise the settings resolver"
  fi
  if ! TF_DATA_DIR="${data_dir}" terraform -chdir="${HIB_RESOLVER_DIR}" apply -auto-approve -input=false \
    -lock=false -no-color -var "config_file=${CONFIG_ABS}" >>"${log}" 2>&1; then
    cat "${log}" >&2
    die "could not resolve ${CONFIG_REL} (is it valid YAML with an 'environments' map?)"
  fi
  if ! TF_DATA_DIR="${data_dir}" terraform -chdir="${HIB_RESOLVER_DIR}" output -no-color -json environments \
    >"${RESOLVED_JSON}" 2>>"${log}"; then
    cat "${log}" >&2
    die "could not read resolved settings"
  fi
  jq -e 'type == "object"' "${RESOLVED_JSON}" >/dev/null || die "resolver produced invalid JSON"
  info "resolved $(jq 'length' "${RESOLVED_JSON}") environment(s) from ${CONFIG_REL}"
}

# setting KEY JQ_PATH  -> raw value ("" for null)
# (false is printed as "false"; objects/arrays as compact JSON)
setting() {
  jq -r --arg k "$1" ".[\$k]${2} | if . == null then empty elif type == \"object\" or type == \"array\" then tojson else tostring end" "${RESOLVED_JSON}"
}

# Prints the environment keys to process, one per line. Explicitly requested
# keys must exist and have hibernation enabled; without --env every key with
# hibernation.enabled == true is selected.
select_environments() {
  local key
  if ((${#OPT_ENVS[@]})); then
    # Validate first (die must not run inside a pipeline sub-shell).
    for key in "${OPT_ENVS[@]}"; do
      jq -e --arg k "${key}" 'has($k)' "${RESOLVED_JSON}" >/dev/null ||
        die "environment '${key}' is not defined in ${CONFIG_REL} (known: $(jq -r 'keys | join(", ")' "${RESOLVED_JSON}"))"
    done
    printf '%s\n' "${OPT_ENVS[@]}" | awk '!seen[$0]++'
  else
    jq -r 'to_entries[] | select(.value.hibernation.enabled == true) | .key' "${RESOLVED_JSON}"
  fi
}

# Guard-rails shared by both scripts. Returns non-zero with a message when the
# environment must not be touched.
check_environment_eligible() {
  local key="$1" errors enabled prod
  errors="$(jq -r --arg k "${key}" '.[$k].validation_errors | join("; ")' "${RESOLVED_JSON}")"
  if [[ -n "${errors}" ]]; then
    error "[${key}] invalid configuration: ${errors}"
    return 1
  fi
  enabled="$(setting "${key}" .hibernation.enabled)"
  if [[ "${enabled}" != true ]]; then
    error "[${key}] hibernation is not enabled for this environment (set hibernation.enabled: true in ${CONFIG_REL})"
    return 1
  fi
  prod="$(setting "${key}" .is_production)"
  if [[ "${prod}" == true ]]; then
    error "[${key}] refusing to hibernate a production environment"
    return 1
  fi
  return 0
}

# ── Results bookkeeping (works across background sub-shells) ────────────────
# result_set KEY STATUS MESSAGE   (STATUS: ok | skipped | failed)
result_set() {
  local key="$1" status="$2" msg="$3"
  jq -n --arg k "${key}" --arg s "${status}" --arg m "${msg}" --arg t "$(_ts)" \
    '{environment: $k, status: $s, message: $m, at: $t}' >"${OPT_WORK_DIR}/results/${key}.json"
  case "${status}" in
  ok) info "[${key}] ✔ ${msg}" ;;
  skipped) info "[${key}] ⏭ ${msg}" ;;
  *) error "[${key}] ✘ ${msg}" ;;
  esac
}

result_status() {
  local f="${OPT_WORK_DIR}/results/$1.json"
  [[ -f "${f}" ]] && jq -r .status "${f}" || printf 'pending\n'
}

# Prints a summary table, writes summary.json and returns the exit code.
finish_summary() {
  local mode="$1"
  shift
  local key status msg rc=${HIB_EXIT_OK}
  local summary="${OPT_WORK_DIR}/summary.json"
  section_start summary "Summary (${mode})"
  printf '%-32s %-8s %s\n' ENVIRONMENT STATUS DETAIL >&2
  for key in "$@"; do
    if [[ ! -f "${OPT_WORK_DIR}/results/${key}.json" ]]; then
      result_set "${key}" failed "no result recorded (aborted?)" 2>/dev/null
    fi
    status="$(jq -r .status "${OPT_WORK_DIR}/results/${key}.json")"
    msg="$(jq -r .message "${OPT_WORK_DIR}/results/${key}.json")"
    printf '%-32s %-8s %s\n' "${key}" "${status}" "${msg}" >&2
    [[ "${status}" == failed ]] && rc=${HIB_EXIT_FAILED}
  done
  if (($#)); then
    jq -s --arg mode "${mode}" --argjson dry "${OPT_DRY_RUN}" \
      '{mode: $mode, dry_run: $dry, environments: .}' "${OPT_WORK_DIR}"/results/*.json >"${summary}"
  else
    jq -n --arg mode "${mode}" --argjson dry "${OPT_DRY_RUN}" \
      '{mode: $mode, dry_run: $dry, environments: []}' >"${summary}"
  fi
  section_end summary
  return "${rc}"
}

# Phase markers: an environment that completed a phase successfully but has
# more work to do (so no final result yet) drops a marker file.
phase_marker() { printf '%s/state/%s.%s.ok\n' "${OPT_WORK_DIR}" "$1" "$2"; }
phase_ok() { : >"$(phase_marker "$1" "$2")"; }
phase_done() { [[ -f "$(phase_marker "$1" "$2")" ]]; }
has_result() { [[ -f "${OPT_WORK_DIR}/results/$1.json" ]]; }

# Runs FUNC KEY for each key, at most HIBERNATE_MAX_PARALLEL at a time, each
# in a background sub-shell whose output goes to logs/<key>-<label>.log and is
# echoed (as a collapsible section) once the batch has finished.
run_parallel() {
  local label="$1" func="$2"
  shift 2
  local keys=("$@") batch=() pids=() key i j
  local max="${HIBERNATE_MAX_PARALLEL}"
  ((max >= 1)) || max=1
  for ((i = 0; i < ${#keys[@]}; i += max)); do
    batch=("${keys[@]:i:max}")
    pids=()
    for key in "${batch[@]}"; do
      (
        set +e
        "${func}" "${key}"
      ) >"${OPT_WORK_DIR}/logs/${key}-${label}.log" 2>&1 &
      pids+=("$!")
    done
    for ((j = 0; j < ${#pids[@]}; j++)); do
      wait "${pids[j]}" || true
      key="${batch[j]}"
      section_start "${label}_${key//[^a-zA-Z0-9_]/_}" "${label}: ${key}"
      cat "${OPT_WORK_DIR}/logs/${key}-${label}.log" >&2
      section_end "${label}_${key//[^a-zA-Z0-9_]/_}"
      # A sub-shell must either record a final result or drop a phase marker
      # (phase_ok); one that did neither died unexpectedly.
      if [[ ! -f "${OPT_WORK_DIR}/results/${key}.json" && ! -f "$(phase_marker "${key}" "${label}")" ]]; then
        result_set "${key}" failed "${label} step aborted unexpectedly (see logs/${key}-${label}.log)"
      fi
    done
  done
}

# ── gcloud: Composer ────────────────────────────────────────────────────────
# composer_describe NAME REGION PROJECT  -> JSON on stdout
#   rc 0 found, rc 3 not found, other rc = error
composer_describe() {
  local name="$1" region="$2" project="$3" out err rc
  err="$(mktemp)"
  out="$(gcloud composer environments describe "${name}" --location="${region}" \
    --project="${project}" --format=json 2>"${err}")" && rc=0 || rc=$?
  if ((rc != 0)); then
    if is_not_found_error "$(cat "${err}")"; then
      rm -f "${err}"
      return "${HIB_RC_NOT_FOUND}"
    fi
    cat "${err}" >&2
    rm -f "${err}"
    return "${rc}"
  fi
  rm -f "${err}"
  printf '%s\n' "${out}"
}

# composer_state NAME REGION PROJECT -> RUNNING | CREATING | ... | NOT_FOUND
composer_state() {
  local json rc
  json="$(retry composer_describe "$@")" && rc=0 || rc=$?
  if ((rc == HIB_RC_NOT_FOUND)); then
    printf 'NOT_FOUND\n'
    return 0
  fi
  ((rc == 0)) || return "${rc}"
  jq -r '.state // "STATE_UNSPECIFIED"' <<<"${json}"
}

# Polls until the state is one of the comma-separated TARGETS, printing the
# final state. Returns 1 on timeout.
wait_for_composer_state() {
  local name="$1" region="$2" project="$3" targets="$4" timeout_min="${5:-${HIBERNATE_WAIT_TIMEOUT_MINUTES}}"
  local deadline state
  deadline=$(($(now_epoch) + timeout_min * 60))
  while :; do
    state="$(composer_state "${name}" "${region}" "${project}")" || return 1
    if [[ ",${targets}," == *",${state},"* ]]; then
      printf '%s\n' "${state}"
      return 0
    fi
    if (($(now_epoch) >= deadline)); then
      error "timed out after ${timeout_min}m waiting for ${name} to reach ${targets} (still ${state})"
      printf '%s\n' "${state}"
      return 1
    fi
    info "${name} is ${state}; waiting for ${targets} (poll ${HIBERNATE_POLL_SECONDS}s)"
    sleep "${HIBERNATE_POLL_SECONDS}"
  done
}

# Waits for a Composer long-running operation; prints the final operation
# JSON. Returns 1 on operation error or timeout.
wait_for_operation() {
  local op_name="$1" region="$2" project="$3" what="$4"
  local op_id="${op_name##*/}" deadline op done_flag
  deadline=$(($(now_epoch) + HIBERNATE_OPERATION_TIMEOUT_MINUTES * 60))
  while :; do
    op="$(retry gcloud composer operations describe "${op_id}" --location="${region}" \
      --project="${project}" --format=json)" || {
      error "could not poll operation ${op_name}"
      return 1
    }
    done_flag="$(jq -r '.done // false' <<<"${op}")"
    if [[ "${done_flag}" == true ]]; then
      if jq -e '.error' <<<"${op}" >/dev/null; then
        error "${what} failed: $(jq -c '.error' <<<"${op}")"
        printf '%s\n' "${op}"
        return 1
      fi
      printf '%s\n' "${op}"
      return 0
    fi
    if (($(now_epoch) >= deadline)); then
      error "${what} did not finish within ${HIBERNATE_OPERATION_TIMEOUT_MINUTES}m (operation ${op_name} is still running server-side)"
      return 1
    fi
    info "${what} in progress (operation ${op_id}); next check in ${HIBERNATE_POLL_SECONDS}s"
    sleep "${HIBERNATE_POLL_SECONDS}"
  done
}

# composer_snapshot_save NAME REGION PROJECT LOCATION -> snapshot path
# The path is taken from the operation response (SaveSnapshotResponse
# .snapshotPath) — never guessed from folder names. A request rejected because
# another operation is running is retried once after the environment settles.
composer_snapshot_save() {
  local name="$1" region="$2" project="$3" location="$4" op op_name result path err attempt
  err="$(mktemp)"
  for attempt in 1 2; do
    op="$(gcloud composer environments snapshots save "${name}" --location="${region}" \
      --project="${project}" --snapshot-location="${location}" --async --format=json 2>"${err}")" && break
    cat "${err}" >&2
    if ((attempt == 1)) && grep -Eqi 'FAILED_PRECONDITION|in progress|another operation' "${err}"; then
      warn "snapshot request for ${name} rejected while another operation runs; waiting for RUNNING and retrying"
      wait_for_composer_state "${name}" "${region}" "${project}" RUNNING >/dev/null || break
      continue
    fi
    rm -f "${err}"
    error "snapshots save request for ${name} was rejected"
    return 1
  done
  rm -f "${err}"
  op_name="$(jq -r '.name // empty' <<<"${op:-}" 2>/dev/null)"
  [[ -n "${op_name}" ]] || {
    error "snapshots save returned no operation name: ${op:-<empty>}"
    return 1
  }
  info "snapshot of ${name} started (operation ${op_name})"
  result="$(wait_for_operation "${op_name}" "${region}" "${project}" "snapshot save of ${name}")" || return 1
  path="$(jq -r '.response.snapshotPath // empty' <<<"${result}")"
  path="${path%/}"
  if [[ "${path}" != gs://* ]]; then
    error "snapshot of ${name} finished without a snapshotPath in the operation response"
    return 1
  fi
  printf '%s\n' "${path}"
}

# A snapshot is complete when its folder holds the Airflow database dump
# (*.sql.gz at the top level, per the Composer documentation).
snapshot_is_complete() {
  local out
  out="$(gcloud storage ls "${1%/}/*.sql.gz" 2>/dev/null)" || return 1
  grep -q '\.sql\.gz$' <<<"${out}"
}

# composer_snapshot_load NAME REGION PROJECT SNAPSHOT_PATH LOAD_OPTIONS_JSON
composer_snapshot_load() {
  local name="$1" region="$2" project="$3" path="$4" opts="$5" op op_name
  local args=(--location="${region}" --project="${project}" --snapshot-path="${path}" --async --format=json)
  [[ "$(jq -r '.skip_pypi_packages_installation' <<<"${opts}")" == true ]] && args+=(--skip-pypi-packages-installation)
  [[ "$(jq -r '.skip_environment_variables_setting' <<<"${opts}")" == true ]] && args+=(--skip-environment-variables-setting)
  [[ "$(jq -r '.skip_airflow_overrides_setting' <<<"${opts}")" == true ]] && args+=(--skip-airflow-overrides-setting)
  [[ "$(jq -r '.skip_gcs_data_copying' <<<"${opts}")" == true ]] && args+=(--skip-gcs-data-copying)
  info "loading ${path} into ${name} (${args[*]:3})"
  local attempt
  for ((attempt = 1; attempt <= HIBERNATE_LOAD_ATTEMPTS; attempt++)); do
    if op="$(gcloud composer environments snapshots load "${name}" "${args[@]}")" &&
      op_name="$(jq -r '.name // empty' <<<"${op}")" && [[ -n "${op_name}" ]] &&
      wait_for_operation "${op_name}" "${region}" "${project}" "snapshot load into ${name}" >/dev/null; then
      return 0
    fi
    if ((attempt < HIBERNATE_LOAD_ATTEMPTS)); then
      # Composer skips the steps a partially completed load already did.
      warn "snapshot load into ${name} failed (attempt ${attempt}/${HIBERNATE_LOAD_ATTEMPTS}); retrying"
      wait_for_composer_state "${name}" "${region}" "${project}" RUNNING,ERROR >/dev/null || true
    fi
  done
  error "snapshot load into ${name} failed after ${HIBERNATE_LOAD_ATTEMPTS} attempt(s)"
  return 1
}

# ── Image versions ──────────────────────────────────────────────────────────
# Prints the image versions that can currently be used to CREATE environments
# in a location (Composer REST API; GA gcloud has no listing command). The
# access token is handed to curl on stdin, never on the command line.
list_creatable_image_versions() {
  local project="$1" region="$2" token page="" url out
  token="$(gcloud auth print-access-token 2>/dev/null)" || {
    error "could not obtain an access token from gcloud"
    return 1
  }
  while :; do
    url="${HIBERNATE_COMPOSER_API}/v1/projects/${project}/locations/${region}/imageVersions?pageSize=500&includePastReleases=false${page:+&pageToken=${page}}"
    out="$(printf 'header = "Authorization: Bearer %s"\n' "${token}" |
      curl -fsS --retry 3 --retry-delay 2 -K - "${url}")" || {
      error "could not list image versions for ${project}/${region}"
      return 1
    }
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"${out}" || {
      error "unexpected (non-JSON) image version listing for ${project}/${region}"
      return 1
    }
    jq -r '.imageVersions[]? | select(.creationDisabled != true) | .imageVersionId' <<<"${out}"
    page="$(jq -r '.nextPageToken // empty' <<<"${out}")"
    [[ -n "${page}" ]] || break
  done
}

# image_version_creatable VERSION < list
# VERSION may be an exact build or an alias (composer-3-airflow-2.10.5,
# composer-3-airflow-2.10, composer-3-airflow-2).
image_version_creatable() {
  local v="$1" id
  while IFS= read -r id; do
    [[ "${id}" == "${v}" || "${id}" == "${v}-build."* || "${id}" == "${v}."* ]] && return 0
  done
  return 1
}

# The image version a restore will create: the YAML's, else (pin enabled) the
# Airflow version the environment runs now, else empty (= GCP default).
restore_image_version() {
  local key="$1" current="$2" yaml
  yaml="$(setting "${key}" .image_version)"
  if [[ -n "${yaml}" ]]; then
    printf '%s\n' "${yaml}"
  elif [[ "$(setting "${key}" .hibernation.pin_image_version)" == true ]]; then
    image_version_pin "${current}" || true
  fi
}

# check_restorable KEY CURRENT_IMAGE — run BEFORE deleting an environment:
# the environment must be re-creatable tomorrow on a version that can load
# today's snapshot. Returns 1 otherwise, with the reason in RESTORE_REASON.
# Call it directly (not in $(...)) so the image-version cache is kept.
declare -gA _CREATABLE_CACHE=()
RESTORE_REASON=""
check_restorable() {
  local key="$1" current="$2" restore project region cache_key list
  RESTORE_REASON=""
  restore="$(restore_image_version "${key}" "${current}")"
  if [[ -z "${restore}" ]]; then
    warn "[${key}] restore will use GCP's default image (no image_version in YAML, pin_image_version: false); snapshot compatibility cannot be checked in advance"
    return 0
  fi
  if [[ -n "${current}" ]] && ! airflow_version_satisfies "$(airflow_version_of "${restore}")" "$(airflow_version_of "${current}")"; then
    RESTORE_REASON="restore image ${restore} (Airflow $(airflow_version_of "${restore}")) could not load a snapshot of the running ${current} — update software_config.image_version in the YAML first"
    return 1
  fi
  if is_true "${HIBERNATE_SKIP_IMAGE_CHECK}"; then
    warn "[${key}] HIBERNATE_SKIP_IMAGE_CHECK set: not checking that ${restore} is still creatable"
    return 0
  fi
  project="$(setting "${key}" .project_id)"
  region="$(setting "${key}" .region)"
  cache_key="${project}/${region}"
  if [[ -z "${_CREATABLE_CACHE[${cache_key}]:-}" ]]; then
    list="$(list_creatable_image_versions "${project}" "${region}")" || {
      RESTORE_REASON="could not verify that ${restore} is still creatable (set HIBERNATE_SKIP_IMAGE_CHECK=true to bypass)"
      return 1
    }
    _CREATABLE_CACHE[${cache_key}]="${list:-<none>}"
  fi
  if ! image_version_creatable "${restore}" <<<"${_CREATABLE_CACHE[${cache_key}]}"; then
    RESTORE_REASON="image version ${restore} can no longer be used to create environments in ${region}; the environment could not be restored — set software_config.image_version to a supported version (same or later Airflow) first"
    return 1
  fi
  info "[${key}] restore image ${restore} is creatable"
}

# ── gcloud: Cloud Storage ───────────────────────────────────────────────────
# gcs_read URL -> object content; rc 3 when the object does not exist.
gcs_read() {
  local url="$1" out err rc
  err="$(mktemp)"
  out="$(gcloud storage cat "${url}" 2>"${err}")" && rc=0 || rc=$?
  if ((rc != 0)); then
    if is_not_found_error "$(cat "${err}")"; then
      rm -f "${err}"
      return "${HIB_RC_NOT_FOUND}"
    fi
    cat "${err}" >&2
    rm -f "${err}"
    return "${rc}"
  fi
  rm -f "${err}"
  printf '%s\n' "${out}"
}

gcs_write_file() {
  local file="$1" url="$2"
  gcloud storage cp "${file}" "${url}" --content-type=application/json --quiet >/dev/null
}

# Lists the immediate sub-folders ("gs://.../name/") of a prefix.
gcs_list_prefixes() {
  local url="$1" out err rc
  err="$(mktemp)"
  out="$(gcloud storage ls "${url}" 2>"${err}")" && rc=0 || rc=$?
  if ((rc != 0)); then
    if is_not_found_error "$(cat "${err}")"; then
      rm -f "${err}"
      return 0
    fi
    cat "${err}" >&2
    rm -f "${err}"
    return "${rc}"
  fi
  rm -f "${err}"
  grep '/$' <<<"${out}" || true
}

gcs_delete_prefix() {
  gcloud storage rm --recursive "${1%/}/" --quiet >/dev/null
}

# bucket_exists NAME -> 0 exists, 3 missing, other = error
bucket_exists() {
  local bucket="$1" err rc
  err="$(mktemp)"
  gcloud storage buckets describe "gs://${bucket}" --format=json >/dev/null 2>"${err}" && rc=0 || rc=$?
  if ((rc != 0)); then
    if is_not_found_error "$(cat "${err}")"; then
      rm -f "${err}"
      return "${HIB_RC_NOT_FOUND}"
    fi
    cat "${err}" >&2
    rm -f "${err}"
    return "${rc}"
  fi
  rm -f "${err}"
  return 0
}

# ensure_snapshot_bucket KEY SERVICE_ACCOUNT [create|no-create]
# Creates the snapshot bucket if needed (when allowed by both the caller and
# hibernation.create_snapshot_bucket) and grants the environment's service
# account object admin on it, because Composer runs the snapshot save/load as
# the environment's service account.
ensure_snapshot_bucket() {
  local key="$1" sa="$2" allow="${3:-create}"
  local bucket project location create rc
  bucket="$(setting "${key}" .hibernation.snapshot_bucket)"
  project="$(setting "${key}" .project_id)"
  location="$(setting "${key}" .hibernation.snapshot_bucket_location)"
  create="$(setting "${key}" .hibernation.create_snapshot_bucket)"

  retry bucket_exists "${bucket}" && rc=0 || rc=$?
  if ((rc == HIB_RC_NOT_FOUND)); then
    if [[ "${allow}" != create ]]; then
      error "[${key}] snapshot bucket gs://${bucket} does not exist"
      return 1
    fi
    if [[ "${create}" != true ]]; then
      error "[${key}] snapshot bucket gs://${bucket} does not exist and create_snapshot_bucket is false"
      return 1
    fi
    info "[${key}] creating snapshot bucket gs://${bucket} in ${location}"
    gcloud storage buckets create "gs://${bucket}" --project="${project}" --location="${location}" \
      --uniform-bucket-level-access --public-access-prevention --quiet >/dev/null || {
      # Another job may have created it in the meantime.
      bucket_exists "${bucket}" || {
        error "[${key}] could not create gs://${bucket}"
        return 1
      }
    }
  elif ((rc != 0)); then
    error "[${key}] could not check snapshot bucket gs://${bucket}"
    return 1
  fi

  if [[ -n "${sa}" ]]; then
    info "[${key}] granting roles/storage.objectAdmin on gs://${bucket} to ${sa}"
    retry gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
      --member="serviceAccount:${sa}" --role=roles/storage.objectAdmin --quiet >/dev/null || {
      error "[${key}] could not grant ${sa} access to gs://${bucket}"
      return 1
    }
  fi
}

# ── Hibernation state file (manifest) ──────────────────────────────────────
# Lives at <snapshot_location>/hibernation-state.json. Status values:
#   SNAPSHOT_SAVED  snapshot taken, environment deletion not confirmed yet
#   HIBERNATED      environment deleted; latest_snapshot must be restored
#   RESTORING       startup in progress (environment created and/or loading)
#   ACTIVE          environment running with the snapshot restored
manifest_local_path() { printf '%s/state/%s.json\n' "${OPT_WORK_DIR}" "$1"; }

# Downloads the manifest to the local copy. rc 3 when none exists yet (an
# empty manifest skeleton is written locally in that case).
manifest_fetch() {
  local key="$1" url local_path rc content
  url="$(setting "${key}" .hibernation.state_object)"
  local_path="$(manifest_local_path "${key}")"
  content="$(retry gcs_read "${url}")" && rc=0 || rc=$?
  if ((rc == HIB_RC_NOT_FOUND)); then
    manifest_new "${key}" >"${local_path}"
    return "${HIB_RC_NOT_FOUND}"
  fi
  ((rc == 0)) || return "${rc}"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${content}"; then
    error "[${key}] ${url} is not valid JSON"
    return 1
  fi
  printf '%s\n' "${content}" >"${local_path}"
}

manifest_new() {
  local key="$1"
  jq -n \
    --argjson v "${HIB_MANIFEST_SCHEMA_VERSION}" \
    --arg k "${key}" \
    --arg n "$(setting "${key}" .environment_name)" \
    --arg p "$(setting "${key}" .project_id)" \
    --arg r "$(setting "${key}" .region)" \
    '{schema_version: $v, environment_key: $k, environment_name: $n, project_id: $p,
      region: $r, status: "NONE", latest_snapshot: null, snapshots: [], history: []}'
}

manifest_get() {
  jq -r "$2 | if . == null then empty elif type == \"object\" or type == \"array\" then tojson else tostring end" \
    "$(manifest_local_path "$1")"
}

# manifest_update KEY JQ_FILTER [jq args...] — edits the local copy.
manifest_update() {
  local key="$1" filter="$2"
  shift 2
  local f tmp
  f="$(manifest_local_path "${key}")"
  tmp="$(mktemp)"
  jq "$@" "${filter}" "${f}" >"${tmp}" && mv "${tmp}" "${f}"
}

# Sets status and appends a history entry (bounded), then uploads.
manifest_transition() {
  local key="$1" status="$2" detail="$3"
  manifest_update "${key}" '
    .status = $s
    | .updated_at = $t
    | .history = ([{at: $t, status: $s, detail: $d, pipeline: $ci}] + (.history // []))[:$max]' \
    --arg s "${status}" --arg t "$(_ts)" --arg d "${detail}" \
    --argjson max "${HIB_HISTORY_MAX}" --argjson ci "$(ci_context_json)"
  manifest_push "${key}"
}

manifest_push() {
  local key="$1" url
  url="$(setting "${key}" .hibernation.state_object)"
  if [[ "${OPT_DRY_RUN}" == true ]]; then
    info "[${key}] (dry-run) would write ${url}: status=$(manifest_get "${key}" .status)"
    return 0
  fi
  retry gcs_write_file "$(manifest_local_path "${key}")" "${url}" || {
    error "[${key}] could not write ${url}"
    return 1
  }
}

ci_context_json() {
  jq -n \
    --arg pipeline_id "${CI_PIPELINE_ID:-}" \
    --arg job_url "${CI_JOB_URL:-}" \
    --arg source "${CI_PIPELINE_SOURCE:-manual}" \
    --arg user "${GITLAB_USER_LOGIN:-${USER:-unknown}}" \
    --arg commit "${CI_COMMIT_SHORT_SHA:-}" \
    '{pipeline_id: $pipeline_id, job_url: $job_url, source: $source, user: $user, commit: $commit}'
}

# ── Terraform ───────────────────────────────────────────────────────────────
tf() { terraform -chdir="${TF_ROOT}" "$@"; }

# Generic -var/-var-file arguments for every plan.
TF_COMMON_ARGS=()
build_tf_common_args() {
  local vf
  TF_COMMON_ARGS=(-input=false -no-color -lock-timeout="${TF_LOCK_TIMEOUT}" -var "config_file=${CONFIG_REL}")
  for vf in "${OPT_VAR_FILES[@]}"; do
    TF_COMMON_ARGS+=(-var-file="${vf}")
  done
}

tf_address() { printf '%s["%s"].google_composer_environment.this\n' "${TF_MODULE_ADDRESS}" "$1"; }
tf_module_prefix() { printf '%s["%s"]\n' "${TF_MODULE_ADDRESS}" "$1"; }

# Initialises TF_ROOT. When TF_BACKEND_BUCKET is set the GCS backend is used
# (a backend_override.tf is generated if the root declares no backend).
tf_init() {
  if [[ "${OPT_SKIP_INIT}" == true ]]; then
    info "skipping terraform init (--skip-init)"
    return 0
  fi
  local args=(-input=false -no-color -reconfigure)
  if [[ -n "${TF_BACKEND_BUCKET:-}" ]]; then
    if ! grep -Eqs '^[[:space:]]*backend[[:space:]]+"' "${TF_ROOT}"/*.tf; then
      info "root module declares no backend; generating backend_override.tf (gcs)"
      printf '# Generated by scripts/hibernation — do not commit.\nterraform {\n  backend "gcs" {}\n}\n' \
        >"${TF_ROOT}/backend_override.tf"
    fi
    args+=(-backend-config="bucket=${TF_BACKEND_BUCKET}")
    [[ -n "${TF_BACKEND_PREFIX:-}" ]] && args+=(-backend-config="prefix=${TF_BACKEND_PREFIX}")
  fi
  section_start tf_init "terraform init"
  tf init "${args[@]}" >&2 || {
    section_end tf_init
    die "terraform init failed"
  }
  section_end tf_init
  # -backend-config without a backend block only WARNS and silently falls back
  # to local state — which would make every environment look "not deployed".
  if [[ -n "${TF_BACKEND_BUCKET:-}" ]]; then
    local data_dir="${TF_DATA_DIR:-.terraform}" backend
    [[ "${data_dir}" == /* ]] || data_dir="${TF_ROOT}/${data_dir}"
    backend="$(jq -r '.backend.type // "local"' "${data_dir}/terraform.tfstate" 2>/dev/null || echo unknown)"
    [[ "${backend}" == gcs ]] || die "terraform initialised the '${backend}' backend, expected gcs (TF_BACKEND_BUCKET is set)"
  fi
}

# Addresses in the Terraform state, loaded once per run by tf_state_load.
# NOTE: never write `producer | grep -q` under `set -o pipefail`: grep -q exits
# at the first match, the producer gets SIGPIPE and the pipeline "fails" —
# with a large state that turns every lookup into a false "not in state".
TF_STATE_LIST=""
TF_STATE_LOADED=false
tf_state_load() {
  TF_STATE_LIST="$(tf state list 2>"${OPT_WORK_DIR}/logs/state-list.log")" || {
    cat "${OPT_WORK_DIR}/logs/state-list.log" >&2
    die "terraform state list failed"
  }
  TF_STATE_LOADED=true
  info "terraform state holds $(grep -c . <<<"${TF_STATE_LIST}" || true) resource(s)"
}

tf_module_in_state() {
  [[ "${TF_STATE_LOADED}" == true ]] || die "internal: tf_state_load not called"
  grep -Fq "$(tf_module_prefix "$1")." <<<"${TF_STATE_LIST}"
}

tf_resource_in_state() {
  [[ "${TF_STATE_LOADED}" == true ]] || die "internal: tf_state_load not called"
  grep -Fxq "$(tf_address "$1")" <<<"${TF_STATE_LIST}"
}

# tf_plan NAME [extra terraform plan args...] -> writes plans/NAME.{tfplan,txt,json}
tf_plan() {
  local name="$1"
  shift
  local planfile="${OPT_WORK_DIR}/plans/${name}.tfplan"
  section_start "plan_${name}" "terraform plan (${name})"
  if ! tf plan "${TF_COMMON_ARGS[@]}" -out="${planfile}" "$@" >&2; then
    section_end "plan_${name}"
    error "terraform plan (${name}) failed"
    return 1
  fi
  tf show -no-color "${planfile}" >"${OPT_WORK_DIR}/plans/${name}.txt" || true
  if ! tf show -json "${planfile}" >"${OPT_WORK_DIR}/plans/${name}.json"; then
    section_end "plan_${name}"
    error "terraform show -json (${name}) failed"
    return 1
  fi
  section_end "plan_${name}"
}

# Prints "address<TAB>actions" for every resource change that is not a no-op
# or a data-source read.
plan_changes() {
  jq -r '.resource_changes[]?
    | select((.change.actions | join(",")) as $a | ($a != "no-op" and $a != "read"))
    | "\(.address)\t\(.change.actions | join(","))"' "$1"
}

# guard_destroy_plan PLAN_JSON ALLOWED_ADDRESS...
# The plan may only delete the given Composer environments — nothing else.
guard_destroy_plan() {
  local plan="$1"
  shift
  local allowed=("$@") addr actions ok=0 a found
  while IFS=$'\t' read -r addr actions; do
    [[ -n "${addr}" ]] || continue
    found=false
    for a in "${allowed[@]}"; do
      [[ "${addr}" == "${a}" ]] && found=true
    done
    if [[ "${found}" != true || "${actions}" != delete ]]; then
      error "plan guard: unexpected change '${actions}' on ${addr} — refusing to apply"
      ok=1
    fi
  done < <(plan_changes "${plan}")
  return "${ok}"
}

# guard_create_plan PLAN_JSON REPLACEABLE_ADDRESSES(space separated) MODULE_PREFIX...
# Allowed: create / update anywhere inside the selected module instances,
# delete+create only for explicitly replaceable Composer environments.
guard_create_plan() {
  local plan="$1" replaceable="$2"
  shift 2
  local prefixes=("$@") addr actions ok=0 p inside
  while IFS=$'\t' read -r addr actions; do
    [[ -n "${addr}" ]] || continue
    inside=false
    for p in "${prefixes[@]}"; do
      [[ "${addr}" == "${p}."* ]] && inside=true
    done
    if [[ "${inside}" != true ]]; then
      error "plan guard: change '${actions}' on ${addr} is outside the selected environments — refusing to apply"
      ok=1
      continue
    fi
    case "${actions}" in
    create | update) ;;
    delete,create | create,delete)
      if [[ " ${replaceable} " != *" ${addr} "* ]]; then
        error "plan guard: unexpected replacement of ${addr} — refusing to apply"
        ok=1
      fi
      ;;
    *)
      error "plan guard: unexpected change '${actions}' on ${addr} — refusing to apply"
      ok=1
      ;;
    esac
  done < <(plan_changes "${plan}")
  return "${ok}"
}

# plan_must_contain PLAN_JSON ADDRESS ACTIONS — guards against a target that
# silently matched nothing (Terraform treats an unknown target as "no
# changes"). ACTIONS lists the accepted alternatives separated by "|", each as
# Terraform's comma-joined action list, e.g. "delete" or "delete,create|create,delete".
plan_must_contain() {
  local plan="$1" addr="$2" want="$3" got
  got="$(jq -r --arg a "${addr}" '.resource_changes[]? | select(.address == $a) | .change.actions | join(",")' "${plan}")"
  if [[ -z "${got}" || "|${want}|" != *"|${got}|"* ]]; then
    error "plan guard: expected ${addr} to be planned as '${want//|/ or }', got '${got:-absent}' — refusing to apply"
    return 1
  fi
}

tf_apply_plan() {
  local name="$1" planfile="${OPT_WORK_DIR}/plans/$1.tfplan"
  section_start "apply_${name}" "terraform apply (${name})"
  if ! tf apply -input=false -no-color -lock-timeout="${TF_LOCK_TIMEOUT}" "${planfile}" >&2; then
    section_end "apply_${name}"
    error "terraform apply (${name}) failed"
    return 1
  fi
  section_end "apply_${name}"
}

# ── Decision tables (pure functions; unit-tested) ──────────────────────────
# decide_shutdown_action STATE MANIFEST_STATUS HAS_SNAPSHOT FORCE
#   STATE: Composer state from describe (NOT_FOUND when absent)
#   prints one of:
#     snapshot_and_delete  normal path
#     delete_only          ERROR state + --force-delete-without-snapshot
#     mark_hibernated      already gone; a snapshot exists to restore later
#     noop_hibernated      already hibernated
#     noop_missing         nothing exists and there is nothing to restore
#     error:<reason>
decide_shutdown_action() {
  local state="$1" status="$2" has_snapshot="$3" force="$4"
  case "${state}" in
  RUNNING) echo snapshot_and_delete ;;
  NOT_FOUND)
    if [[ "${status}" == HIBERNATED ]]; then
      echo noop_hibernated
    elif [[ "${has_snapshot}" == true ]]; then
      echo mark_hibernated
    else
      echo noop_missing
    fi
    ;;
  ERROR)
    if [[ "${force}" == true ]]; then
      echo delete_only
    else
      echo "error:environment is in ERROR state and cannot be snapshotted; re-run with --force-delete-without-snapshot to delete it anyway (startup would then restore the previous snapshot)"
    fi
    ;;
  *) echo "error:environment is in unexpected state ${state}" ;;
  esac
}

# decide_startup_action STATE MANIFEST_STATUS HAS_SNAPSHOT
#   prints one of:
#     create_and_load   environment absent, snapshot available
#     create_fresh      environment absent, no snapshot (new environment)
#     replace_and_load  environment broken (ERROR) mid-restore → recreate
#     load              environment exists but the snapshot was never loaded
#     mark_active       environment kept running (shutdown never deleted it)
#     noop              nothing to do
#     error:<reason>
decide_startup_action() {
  local state="$1" status="$2" has_snapshot="$3"
  case "${state}" in
  NOT_FOUND)
    if [[ "${has_snapshot}" == true ]]; then echo create_and_load; else echo create_fresh; fi
    ;;
  RUNNING)
    case "${status}" in
    HIBERNATED | RESTORING)
      if [[ "${has_snapshot}" == true ]]; then echo load; else echo mark_active; fi
      ;;
    SNAPSHOT_SAVED) echo mark_active ;;
    *) echo noop ;;
    esac
    ;;
  ERROR)
    case "${status}" in
    HIBERNATED | RESTORING | SNAPSHOT_SAVED)
      if [[ "${has_snapshot}" == true ]]; then
        echo replace_and_load
      else
        echo "error:environment is in ERROR state and there is no snapshot to restore"
      fi
      ;;
    *) echo "error:environment is in ERROR state outside a hibernation cycle; fix or recreate it manually" ;;
    esac
    ;;
  *) echo "error:environment is in unexpected state ${state}" ;;
  esac
}

# Describes the environment once (writing state/<key>-describe.json), waiting
# out transitional states. Prints the settled state (NOT_FOUND when absent).
settle_environment_state() {
  local key="$1" name region project json rc state
  name="$(setting "${key}" .environment_name)"
  region="$(setting "${key}" .region)"
  project="$(setting "${key}" .project_id)"
  json="$(retry composer_describe "${name}" "${region}" "${project}")" && rc=0 || rc=$?
  if ((rc == HIB_RC_NOT_FOUND)); then
    printf 'NOT_FOUND\n'
    return 0
  fi
  ((rc == 0)) || return "${rc}"
  state="$(jq -r '.state // "STATE_UNSPECIFIED"' <<<"${json}")"
  case "${state}" in
  CREATING | UPDATING)
    info "[${key}] environment is ${state}; waiting for it to settle"
    state="$(wait_for_composer_state "${name}" "${region}" "${project}" RUNNING,ERROR,NOT_FOUND)" || return 1
    ;;
  DELETING)
    info "[${key}] environment is DELETING; waiting for the deletion to finish"
    state="$(wait_for_composer_state "${name}" "${region}" "${project}" NOT_FOUND,ERROR)" || return 1
    ;;
  esac
  if [[ "${state}" != NOT_FOUND ]]; then
    retry composer_describe "${name}" "${region}" "${project}" >"${OPT_WORK_DIR}/state/${key}-describe.json" || return 1
  fi
  printf '%s\n' "${state}"
}

describe_get() {
  local f="${OPT_WORK_DIR}/state/$1-describe.json"
  [[ -f "${f}" ]] || return 0
  jq -r "$2 | if . == null then empty else tostring end" "${f}"
}

# ── Usage text shared by --help ─────────────────────────────────────────────
common_usage_options() {
  cat <<'EOF'
Common options:
  -c, --config FILE        YAML config consumed by the Terraform module (required;
                           or HIBERNATE_CONFIG_FILE). Relative paths are resolved
                           against TF_ROOT, then the current directory.
  -e, --env KEY[,KEY]      Environment key(s) to process (repeatable; or
                           HIBERNATE_ENVIRONMENTS). Default: every environment
                           with hibernation.enabled: true.
  -n, --dry-run            Resolve, inspect and plan only; change nothing.
      --var-file FILE      Extra -var-file for terraform plan (repeatable; or
                           HIBERNATE_TF_VAR_FILES).
      --skip-init          Do not run terraform init (already initialised).
      --work-dir DIR       Where logs/plans/state copies/summary are written
                           (default: $TF_ROOT/.hibernation/<mode>-<timestamp>).
  -h, --help               Show this help.

Environment:
  TF_ROOT                  Terraform root module directory (default: repo root)
  TF_MODULE_ADDRESS        Address of the composer module (default: module.composer)
  TF_BACKEND_BUCKET        GCS bucket for remote state (enables the gcs backend)
  TF_BACKEND_PREFIX        GCS prefix for remote state
  TF_LOCK_TIMEOUT          Terraform state lock timeout (default: 20m)
  HIBERNATE_OPERATION_TIMEOUT_MINUTES  snapshot save/load timeout (default: 90)
  HIBERNATE_WAIT_TIMEOUT_MINUTES       wait for transitional states (default: 60)
  HIBERNATE_POLL_SECONDS               polling interval (default: 30)
  HIBERNATE_MAX_PARALLEL               concurrent snapshot/load operations (default: 4)
  HIBERNATE_LOAD_ATTEMPTS              snapshot load attempts (default: 2)
  HIBERNATE_SKIP_IMAGE_CHECK           true = do not verify the restore image is
                                       still creatable before deleting (default: false)

Exit codes: 0 success (or nothing to do), 1 one or more environments failed,
            2 usage/configuration/prerequisite error.
EOF
}
