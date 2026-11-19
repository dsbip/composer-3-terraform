#!/usr/bin/env bats
# ============================================================================
# Unit tests for scripts/hibernation/lib/common.sh
#
# Pure / near-pure functions only: gcloud, curl and terraform are replaced by
# the scripted doubles in fixtures/unit/bin (first on PATH for every test), the
# resolved settings come from fixtures/unit/resolved.json (the real resolver
# output for fixtures/unit/hibernation-unit.yaml; a test below checks they do
# not drift apart), and the plan guards run against the REAL Terraform plan
# fixtures in fixtures/plans.
#
# The library is sourced in setup() and the tests run with pipefail, like the
# scripts that use it (set -Eeuo pipefail). Nothing sleeps: poll and retry
# intervals are 0.
#
#   bats tests/hibernation/unit.bats
# ============================================================================
# Every @test runs in its own process (shellcheck models it as a subshell), so
# per-test variable changes are intentionally local:
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LIB="${REPO}/scripts/hibernation/lib/common.sh"
  UNIT="${BATS_TEST_DIRNAME}/fixtures/unit"
  PLANS="${BATS_TEST_DIRNAME}/fixtures/plans"
  REAL_TERRAFORM="$(command -v terraform || true)"

  # Nothing from the caller's environment may leak into the library defaults.
  unset HIBERNATE_CONFIG_FILE HIBERNATE_ENVIRONMENTS HIBERNATE_DRY_RUN HIBERNATE_SKIP_INIT \
    HIBERNATE_TF_VAR_FILES HIBERNATE_WORK_DIR HIBERNATE_SKIP_IMAGE_CHECK HIBERNATE_COMPOSER_API \
    HIBERNATE_LOAD_ATTEMPTS HIBERNATE_GCLOUD_RETRIES HIBERNATE_WAIT_TIMEOUT_MINUTES \
    HIBERNATE_OPERATION_TIMEOUT_MINUTES HIBERNATE_MAX_PARALLEL HIBERNATE_FRESH_ENV_HOURS \
    HIBERNATE_LOCK_TIMEOUT_SECONDS \
    TF_ROOT TF_MODULE_ADDRESS TF_BACKEND_BUCKET TF_BACKEND_PREFIX TF_DATA_DIR TF_LOCK_TIMEOUT \
    GITLAB_CI CI_PIPELINE_ID CI_JOB_URL CI_PIPELINE_SOURCE GITLAB_USER_LOGIN CI_COMMIT_SHORT_SHA \
    STUB_TF_BACKEND STUB_TF_INIT_RC STUB_TF_STATE_RC
  export HIBERNATE_POLL_SECONDS=0 HIBERNATE_RETRY_SLEEP_SECONDS=0 HIBERNATE_POLL_FAILURE_GRACE_SECONDS=0
  export HIBERNATE_COMPOSER_API="https://composer.unit.test"

  # shellcheck source=SCRIPTDIR/../../scripts/hibernation/lib/common.sh
  source "${LIB}"
  stderr="" # set by `run --separate-stderr`
  # Sourced inside a function, the library's top-level `declare -A` is local
  # to setup(); re-declare the cache globally so check_restorable can use it.
  declare -gA _CREATABLE_CACHE=()
  set -o pipefail

  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  export STUB_DIR
  mkdir -p "${STUB_DIR}/replies" "${STUB_DIR}/gcs" "${STUB_DIR}/pages"
  : >"${STUB_DIR}/gcloud.calls"
  : >"${STUB_DIR}/terraform.calls"
  PATH="${UNIT}/bin:${PATH}"

  TF_ROOT="${BATS_TEST_TMPDIR}/tfroot"
  mkdir -p "${TF_ROOT}"
  OPT_WORK_DIR="${BATS_TEST_TMPDIR}/work"
  mkdir -p "${OPT_WORK_DIR}/logs" "${OPT_WORK_DIR}/plans" "${OPT_WORK_DIR}/state" "${OPT_WORK_DIR}/results"
  RESOLVED_JSON="${BATS_TEST_TMPDIR}/resolved.json"
  cp "${UNIT}/resolved.json" "${RESOLVED_JSON}"
  CONFIG_REL="configs/hibernation-unit.yaml"

  DEV_ENV='module.composer["composer-dev"].google_composer_environment.this'
  TEST_ENV='module.composer["composer-test"].google_composer_environment.this'
  DEV_PREFIX='module.composer["composer-dev"]'
  TEST_PREFIX='module.composer["composer-test"]'
  STATE_URL_DEV="gs://hib-test-project-composer-snapshots/composer-hibernation/hib-test-project/europe-west2/composer-dev/hibernation-state.json"

  NF_DESCRIBE="ERROR: (gcloud.composer.environments.describe) NOT_FOUND: Resource 'projects/hib-test-project/locations/europe-west2/environments/composer-dev' was not found"
  DENIED_DESCRIBE="ERROR: (gcloud.composer.environments.describe) PERMISSION_DENIED: Permission 'composer.environments.get' denied on resource 'projects/hib-test-project/locations/europe-west2/environments/composer-dev' (or it may not exist)."
  DENIED_GCS="ERROR: (gcloud.storage.cat) HTTPError 403: sa@hib-test-project.iam.gserviceaccount.com does not have storage.objects.get access to the Google Cloud Storage object. Permission 'storage.objects.get' denied on resource (or it may not exist)."
}

# ── Helpers ─────────────────────────────────────────────────────────────────
assert_eq() { # assert_eq ACTUAL EXPECTED [LABEL]
  [[ "$1" == "$2" ]] && return 0
  printf '%s\n  expected: %q\n  actual:   %q\n' "${3:-values differ}" "$2" "$1" >&2
  return 1
}

assert_contains() { # assert_contains HAYSTACK NEEDLE [LABEL]
  [[ "$1" == *"$2"* ]] && return 0
  printf '%s\n  expected to contain: %q\n  actual: %q\n' "${3:-substring missing}" "$2" "$1" >&2
  return 1
}

assert_not_contains() { # assert_not_contains HAYSTACK NEEDLE [LABEL]
  [[ "$1" != *"$2"* ]] && return 0
  printf '%s\n  expected NOT to contain: %q\n  actual: %q\n' "${3:-unexpected substring}" "$2" "$1" >&2
  return 1
}

assert_status() { # assert_status EXPECTED  (after `run`)
  assert_eq "${status}" "$1" "exit status (output: ${output})"
}

# t_reply KEY[.N] RC [STDOUT [STDERR]] — scripts the stub gcloud's answer.
t_reply() {
  local dir="${STUB_DIR}/replies/$1"
  mkdir -p "${dir}"
  printf '%s\n' "$2" >"${dir}/rc"
  if (($# >= 3)); then printf '%s\n' "$3" >"${dir}/stdout"; fi
  if (($# >= 4)); then printf '%s\n' "$4" >"${dir}/stderr"; fi
}

# t_describe KEY[.N] STATE — a successful `environments describe` reply.
t_describe() {
  t_reply "$1" 0 "{\"name\": \"projects/hib-test-project/locations/europe-west2/environments/composer-dev\", \"state\": \"$2\", \"config\": {\"softwareConfig\": {\"imageVersion\": \"composer-3-airflow-2.10.5-build.17\"}}}"
}

# Number of calls the stub gcloud served for KEY.
t_count() { cat "${STUB_DIR}/$1.count" 2>/dev/null || echo 0; }

# Number of gcloud invocations whose argument line contains TEXT.
t_calls() { grep -cF -- "$1" "${STUB_DIR}/gcloud.calls" || true; }

# t_gcs_put URL CONTENT — creates an object in the emulated Cloud Storage.
t_gcs_put() {
  local path="${STUB_DIR}/gcs/${1#gs://}"
  mkdir -p "$(dirname "${path}")"
  printf '%s' "$2" >"${path}"
}

t_gcs_path() { printf '%s/gcs/%s\n' "${STUB_DIR}" "${1#gs://}"; }

# t_pages FILE... — serve these image-version pages (first one = first page).
t_pages() {
  cp "${UNIT}/image-versions/$1" "${STUB_DIR}/pages/first.json"
  shift
  local f
  for f in "$@"; do cp "${UNIT}/image-versions/${f}" "${STUB_DIR}/pages/${f}"; done
  t_reply token 0 "ya29.unit-test-token"
}

# t_mkplan NAME ADDRESS=ACTIONS... — minimal plan JSON, prints its path.
t_mkplan() {
  local f="${BATS_TEST_TMPDIR}/$1.json" spec
  shift
  for spec in "$@"; do
    jq -n --arg a "${spec%=*}" --arg c "${spec##*=}" '{address: $a, change: {actions: ($c | split(","))}}'
  done | jq -s '{format_version: "1.2", resource_changes: .}' >"${f}"
  printf '%s\n' "${f}"
}

# Local copy of the manifest for KEY, as manifest_* functions use it.
t_manifest() { cat "$(manifest_local_path "$1")"; }

# check_decision GOT WANT — WANT is an exact action or "error:<substring>".
check_decision() {
  if [[ "$2" == error:* ]]; then
    [[ "$1" == error:* && "$1" == *"${2#error:}"* ]]
  else
    [[ "$1" == "$2" ]]
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# Generic helpers
# ════════════════════════════════════════════════════════════════════════════

# check_restorable reports its reason in RESTORE_REASON (it must run in the
# caller's shell to keep the image-version cache); print it for `run`.
check_restorable_out() {
  local rc=0
  check_restorable "$@" || rc=$?
  printf '%s' "${RESTORE_REASON}"
  return "${rc}"
}

@test "is_true: accepts the documented truthy spellings in any case" {
  local v
  for v in 1 true TRUE True yes YES y Y on ON On; do
    is_true "${v}" || {
      echo "is_true rejected '${v}'" >&2
      return 1
    }
  done
}

@test "is_true: rejects everything else" {
  local v
  for v in 0 false FALSE no n off "" truex 2 enabled " true"; do
    if is_true "${v}"; then
      echo "is_true accepted '${v}'" >&2
      return 1
    fi
  done
}

@test "split_words: commas, spaces, tabs and newlines; empty input prints nothing" {
  assert_eq "$(split_words "a,b")" $'a\nb'
  assert_eq "$(split_words "a, b ,,c")" $'a\nb\nc'
  assert_eq "$(split_words $'a\nb\tc  d')" $'a\nb\nc\nd'
  assert_eq "$(split_words " ,a, ")" "a"
  assert_eq "$(split_words "composer-dev" "composer-test,composer-qa")" $'composer-dev\ncomposer-test\ncomposer-qa'
  run split_words ""
  assert_status 0
  assert_eq "${output}" ""
  run split_words " , ,"
  assert_eq "${output}" ""
}

@test "image_version_pin: drops the -build.N suffix, keeps X.Y.Z" {
  assert_eq "$(image_version_pin composer-3-airflow-2.10.5-build.17)" "composer-3-airflow-2.10.5"
  assert_eq "$(image_version_pin composer-3-airflow-2.10.5)" "composer-3-airflow-2.10.5"
  assert_eq "$(image_version_pin composer-3-airflow-3.0.1-build.3)" "composer-3-airflow-3.0.1"
  assert_eq "$(image_version_pin composer-3-airflow-2.9.3-build.123)" "composer-3-airflow-2.9.3"
}

@test "image_version_pin: invalid inputs return 1 and print nothing" {
  local v
  for v in "" "composer-3-airflow-2.10" "composer-3-airflow-2" "composer-2.9.1-airflow-2.9.3" \
    "composer-3-airflow-2.10.5-build." "composer-3-airflow-2.10.5-build.x" "xcomposer-3-airflow-2.10.5" \
    "composer-3-airflow-2.10.5-build.17-extra" "latest"; do
    run image_version_pin "${v}"
    assert_eq "${status}" 1 "image_version_pin '${v}' status"
    assert_eq "${output}" "" "image_version_pin '${v}' output"
  done
}

@test "airflow_version_of: extracts the Airflow version at whatever precision is given" {
  assert_eq "$(airflow_version_of composer-3-airflow-2.10.5-build.17)" "2.10.5"
  assert_eq "$(airflow_version_of composer-3-airflow-2.10.5)" "2.10.5"
  assert_eq "$(airflow_version_of composer-3-airflow-2.10)" "2.10"
  assert_eq "$(airflow_version_of composer-3-airflow-2)" "2"
  assert_eq "$(airflow_version_of composer-3-airflow-3.0.1-build.3)" "3.0.1"
  assert_eq "$(airflow_version_of "")" ""
  assert_eq "$(airflow_version_of latest)" ""
}

@test "version_ge: dotted numeric comparison (not lexical)" {
  version_ge 2.10.5 2.9.3
  version_ge 2.10.5 2.10.5
  version_ge 2.10.10 2.10.9
  version_ge 10.0 9.9
  version_ge 3 2.10.5
  run version_ge 2.9.3 2.10.5
  assert_status 1
  run version_ge 2.10.4 2.10.5
  assert_status 1
  run version_ge 2.10.9 2.10.10
  assert_status 1
}

@test "airflow_version_satisfies: same/later/earlier, alias precision, cross-major, empty" {
  local target snap want got failures=()
  while read -r target snap want; do
    [[ -n "${target}" && "${target}" != \#* ]] || continue
    [[ "${target}" == - ]] && target=""
    [[ "${snap}" == - ]] && snap=""
    airflow_version_satisfies "${target}" "${snap}" && got=yes || got=no
    [[ "${got}" == "${want}" ]] || failures+=("satisfies('${target}', '${snap}') = ${got}, want ${want}")
  done <<'EOF'
# target snapshot expected
2.10.5   2.10.5   yes
2.10.5   2.9.3    yes
2.11.0   2.10.5   yes
2.10.6   2.10.5   yes
2.9.3    2.10.5   no
2.10.4   2.10.5   no
2        2.10.5   yes
2        2.0.0    yes
2.10     2.10.5   yes
2.10     2.10.0   yes
2.10     2.9.3    yes
2.10     2.11.0   no
2.9      2.10.5   no
2.1      2.10.5   no
2.10.5   2.10     yes
3.0.1    2.10.5   no
3        2.10.5   no
2.10.5   3.0.1    no
2        3.0.1    no
-        2.10.5   no
2.10.5   -        no
-        -        no
EOF
  if ((${#failures[@]})); then
    printf '%s\n' "${failures[@]}" >&2
    return 1
  fi
}

@test "bucket_from_gcs_uri: bucket of a gs:// URI, empty otherwise" {
  assert_eq "$(bucket_from_gcs_uri gs://europe-west2-composer-dev-1a2b3c4d-bucket/dags)" "europe-west2-composer-dev-1a2b3c4d-bucket"
  assert_eq "$(bucket_from_gcs_uri gs://my-bucket)" "my-bucket"
  assert_eq "$(bucket_from_gcs_uri gs://my-bucket/)" "my-bucket"
  assert_eq "$(bucket_from_gcs_uri gs://my-bucket/a/b/c)" "my-bucket"
  assert_eq "$(bucket_from_gcs_uri s3://my-bucket/dags)" ""
  assert_eq "$(bucket_from_gcs_uri my-bucket/dags)" ""
  assert_eq "$(bucket_from_gcs_uri "")" ""
}

@test "is_not_found_error: recognises real gcloud not-found texts" {
  local t
  local texts=(
    "ERROR: (gcloud.storage.cat) gs://b not found: 404."
    "gs://b not found: 404."
    "ERROR: (gcloud.storage.buckets.describe) gs://hib-test-project-composer-snapshots not found: 404."
    "${NF_DESCRIBE}"
    "NOT_FOUND: Resource 'projects/p/locations/r/environments/e' was not found"
    "ERROR: (gcloud.composer.operations.describe) NOT_FOUND: Requested entity was not found."
    "ERROR: (gcloud.storage.ls) One or more URLs matched no objects."
    $'ERROR: (gcloud.storage.cat) The following URLs matched no objects or files:\n-gs://b/state.json'
    "ERROR: (gcloud.storage.buckets.describe) HTTPError 404: The specified bucket does not exist."
  )
  for t in "${texts[@]}"; do
    is_not_found_error "${t}" || {
      echo "not recognised as not-found: ${t}" >&2
      return 1
    }
  done
}

@test "is_not_found_error: permission, conflict and transient errors are NOT not-found" {
  local t
  local texts=(
    "PERMISSION_DENIED"
    "${DENIED_DESCRIBE}"
    "${DENIED_GCS}"
    "ERROR: (gcloud.storage.buckets.describe) HTTPError 403: caller does not have storage.buckets.get access"
    "403 Forbidden"
    "ERROR: (gcloud.storage.buckets.create) HTTPError 409: Your previous request to create the named bucket succeeded and you already own it."
    "HTTPError 409"
    "ERROR: (gcloud.composer.environments.snapshots.save) FAILED_PRECONDITION: an operation is already in progress"
    "ERROR: (gcloud.composer.environments.describe) UNAVAILABLE: The service is currently unavailable."
    "ERROR: (gcloud.storage.cat) HTTPError 429: rate limit exceeded"
    "ERROR: (gcloud.storage.cat) HTTPError 503: Backend Error"
    ""
  )
  for t in "${texts[@]}"; do
    if is_not_found_error "${t}"; then
      echo "wrongly treated as not-found: ${t}" >&2
      return 1
    fi
  done
}

@test "is_safe_orphan_bucket: accepts this environment's auto-created bucket (also truncated names)" {
  local snap=hib-test-project-composer-snapshots
  is_safe_orphan_bucket europe-west2-composer-dev-1a2b3c4d-bucket europe-west2 composer-dev "${snap}" ""
  is_safe_orphan_bucket us-central1-composer-nopin-0f9e8d7c-bucket us-central1 composer-nopin other-project-composer-snapshots ""
  is_safe_orphan_bucket europe-west2-composer-development-e-1a2b3c4d-bucket europe-west2 \
    composer-development-environment-for-team-x "${snap}" ""
}

@test "is_safe_orphan_bucket: rejects snapshot bucket, custom bucket, other region, other env, empty" {
  local snap=hib-test-project-composer-snapshots b=europe-west2-composer-dev-1a2b3c4d-bucket
  run is_safe_orphan_bucket "${b}" europe-west2 composer-dev "${b}" ""
  assert_eq "${status}" 1 "snapshot bucket"
  run is_safe_orphan_bucket "${b}" europe-west2 composer-dev "${snap}" "${b}"
  assert_eq "${status}" 1 "custom bucket"
  run is_safe_orphan_bucket us-central1-composer-dev-1a2b3c4d-bucket europe-west2 composer-dev "${snap}" ""
  assert_eq "${status}" 1 "other region"
  run is_safe_orphan_bucket europe-west20-composer-dev-1a2b3c4d-bucket europe-west2 composer-dev "${snap}" ""
  assert_eq "${status}" 1 "region prefix lookalike"
  run is_safe_orphan_bucket europe-west2-composer-test-9f8e7d6c-bucket europe-west2 composer-dev "${snap}" ""
  assert_eq "${status}" 1 "other environment"
  run is_safe_orphan_bucket "" europe-west2 composer-dev "${snap}" ""
  assert_eq "${status}" 1 "empty bucket"
  run is_safe_orphan_bucket hib-test-project-composer-test-data europe-west2 composer-test "${snap}" ""
  assert_eq "${status}" 1 "user bucket"
  run is_safe_orphan_bucket europe-west2-composer-dev-data europe-west2 composer-dev "${snap}" ""
  assert_eq "${status}" 1 "no -bucket suffix"
  run is_safe_orphan_bucket europe-west2-composer-1a2b3c4d-bucket europe-west2 composer-dev "${snap}" ""
  assert_eq "${status}" 1 "bucket of a shorter environment name ('composer')"
}

@test "is_safe_orphan_bucket: rejects buckets of other environments that share a name prefix" {
  # Composer names the bucket <region>-<env name, possibly truncated>-<hash>-bucket:
  # the name part must be a prefix of THIS environment's name, not merely
  # share its first 10 characters.
  local snap=hib-test-project-composer-snapshots
  run is_safe_orphan_bucket europe-west2-devops-1a2b3c4d-bucket europe-west2 dev "${snap}" ""
  assert_eq "${status}" 1 "env 'dev' must not claim the bucket of env 'devops'"
  run is_safe_orphan_bucket europe-west2-composer-dev2-1a2b3c4d-bucket europe-west2 composer-dev "${snap}" ""
  assert_eq "${status}" 1 "env 'composer-dev' must not claim the bucket of env 'composer-dev2'"
  run is_safe_orphan_bucket europe-west2-composer-data-pipeline-1a2b3c4d-bucket europe-west2 composer-dev "${snap}" ""
  assert_eq "${status}" 1 "env 'composer-dev' must not claim the bucket of env 'composer-data-pipeline'"
}

@test "require_cmds: dies (exit 2) listing every missing command" {
  run require_cmds bash jq
  assert_status 0
  run require_cmds bash no-such-cmd-1 jq no-such-cmd-2
  assert_status 2
  assert_contains "${output}" "no-such-cmd-1 no-such-cmd-2"
}

@test "retry: retries failures, never retries not-found, keeps the last rc" {
  local counter="${BATS_TEST_TMPDIR}/attempts"
  flaky() {
    local n
    n=$(($(cat "${counter}" 2>/dev/null || echo 0) + 1))
    echo "${n}" >"${counter}"
    ((n >= $1)) && return 0
    return "$2"
  }
  run retry flaky 3 1
  assert_status 0
  assert_eq "$(cat "${counter}")" 3 "attempts until success"

  rm -f "${counter}"
  run retry flaky 99 5
  assert_status 5
  assert_eq "$(cat "${counter}")" "${HIBERNATE_GCLOUD_RETRIES}" "attempts when always failing"

  rm -f "${counter}"
  run retry flaky 99 3
  assert_status 3
  assert_eq "$(cat "${counter}")" 1 "not-found (rc 3) is never retried"

  rm -f "${counter}"
  HIBERNATE_GCLOUD_RETRIES=1
  run retry flaky 99 1
  assert_status 1
  assert_eq "$(cat "${counter}")" 1 "HIBERNATE_GCLOUD_RETRIES=1"
}

@test "retry: passes through the stdout of the last attempt only" {
  # Documented contract: "stdout of the last attempt is passed through".
  local counter="${BATS_TEST_TMPDIR}/attempts"
  half_json() {
    local n
    n=$(($(cat "${counter}" 2>/dev/null || echo 0) + 1))
    echo "${n}" >"${counter}"
    if ((n == 1)); then
      printf '{"done": '
      return 1
    fi
    printf '{"done": true}\n'
  }
  run --separate-stderr retry half_json
  assert_status 0
  assert_eq "${output}" '{"done": true}' "a failed attempt's partial stdout must not leak into the result"
}

@test "tf_address / tf_module_prefix: match the addresses Terraform uses (and TF_MODULE_ADDRESS)" {
  assert_eq "$(tf_address composer-dev)" "${DEV_ENV}"
  assert_eq "$(tf_module_prefix composer-test)" "${TEST_PREFIX}"
  # The plan fixtures contain exactly these addresses.
  assert_eq "$(jq -r '.resource_changes[0].address' "${PLANS}/destroy-targeted-one.json")" "$(tf_address composer-dev)"
  TF_MODULE_ADDRESS='module.platform.module.composer'
  assert_eq "$(tf_address composer-dev)" 'module.platform.module.composer["composer-dev"].google_composer_environment.this'
  assert_eq "$(tf_module_prefix composer-dev)" 'module.platform.module.composer["composer-dev"]'
}

@test "build_tf_common_args: config_file relative to TF_ROOT plus every var file in order" {
  OPT_VAR_FILES=(a.tfvars "dir with space/b.tfvars")
  build_tf_common_args
  assert_eq "${#TF_COMMON_ARGS[@]}" 7
  assert_eq "${TF_COMMON_ARGS[0]}" "-input=false"
  assert_eq "${TF_COMMON_ARGS[2]}" "-lock-timeout=20m"
  assert_eq "${TF_COMMON_ARGS[3]}" "-var"
  assert_eq "${TF_COMMON_ARGS[4]}" "config_file=configs/hibernation-unit.yaml"
  assert_eq "${TF_COMMON_ARGS[5]}" "-var-file=a.tfvars"
  assert_eq "${TF_COMMON_ARGS[6]}" "-var-file=dir with space/b.tfvars"
}

@test "init_work_dir: creates the sub-directories and makes the path absolute" {
  cd "${BATS_TEST_TMPDIR}"
  OPT_WORK_DIR="rel/work"
  init_work_dir shutdown 2>/dev/null
  assert_eq "${OPT_WORK_DIR}" "${BATS_TEST_TMPDIR}/rel/work"
  [[ -d "${OPT_WORK_DIR}/logs" && -d "${OPT_WORK_DIR}/plans" && -d "${OPT_WORK_DIR}/state" && -d "${OPT_WORK_DIR}/results" ]]
}

# ════════════════════════════════════════════════════════════════════════════
# Decision tables
# ════════════════════════════════════════════════════════════════════════════

@test "decide_shutdown_action: full truth table (6 states x 5 statuses x snapshot x force)" {
  local state st snap force want got failures=() n=0
  local -A seen=()
  while read -r state st snap force want; do
    [[ -n "${state}" && "${state}" != \#* ]] || continue
    [[ " RUNNING NOT_FOUND ERROR CREATING UPDATING STATE_UNSPECIFIED " == *" ${state} "* ]] || failures+=("bad state ${state}")
    [[ " NONE SNAPSHOT_SAVED HIBERNATED RESTORING ACTIVE " == *" ${st} "* ]] || failures+=("bad status ${st}")
    [[ "${snap}" == true || "${snap}" == false ]] || failures+=("bad has_snapshot ${snap}")
    [[ "${force}" == true || "${force}" == false ]] || failures+=("bad force ${force}")
    seen["${state}/${st}/${snap}/${force}"]=1
    n=$((n + 1))
    got="$(decide_shutdown_action "${state}" "${st}" "${snap}" "${force}")"
    check_decision "${got}" "${want}" ||
      failures+=("decide_shutdown_action ${state} ${st} has_snapshot=${snap} force=${force}: got '${got}', want '${want}'")
  done <<'EOF'
# STATE           STATUS         SNAP  FORCE EXPECTED
  RUNNING           NONE           true  true  snapshot_and_delete
  RUNNING           NONE           true  false snapshot_and_delete
  RUNNING           NONE           false true  snapshot_and_delete
  RUNNING           NONE           false false snapshot_and_delete
  RUNNING           SNAPSHOT_SAVED true  true  snapshot_and_delete
  RUNNING           SNAPSHOT_SAVED true  false snapshot_and_delete
  RUNNING           SNAPSHOT_SAVED false true  snapshot_and_delete
  RUNNING           SNAPSHOT_SAVED false false snapshot_and_delete
  RUNNING           HIBERNATED     true  true  snapshot_and_delete
  RUNNING           HIBERNATED     true  false snapshot_and_delete
  RUNNING           HIBERNATED     false true  snapshot_and_delete
  RUNNING           HIBERNATED     false false snapshot_and_delete
  RUNNING           RESTORING      true  true  snapshot_and_delete
  RUNNING           RESTORING      true  false snapshot_and_delete
  RUNNING           RESTORING      false true  snapshot_and_delete
  RUNNING           RESTORING      false false snapshot_and_delete
  RUNNING           ACTIVE         true  true  snapshot_and_delete
  RUNNING           ACTIVE         true  false snapshot_and_delete
  RUNNING           ACTIVE         false true  snapshot_and_delete
  RUNNING           ACTIVE         false false snapshot_and_delete
  NOT_FOUND         NONE           true  true  mark_hibernated
  NOT_FOUND         NONE           true  false mark_hibernated
  NOT_FOUND         NONE           false true  noop_missing
  NOT_FOUND         NONE           false false noop_missing
  NOT_FOUND         SNAPSHOT_SAVED true  true  mark_hibernated
  NOT_FOUND         SNAPSHOT_SAVED true  false mark_hibernated
  NOT_FOUND         SNAPSHOT_SAVED false true  noop_missing
  NOT_FOUND         SNAPSHOT_SAVED false false noop_missing
  NOT_FOUND         HIBERNATED     true  true  noop_hibernated
  NOT_FOUND         HIBERNATED     true  false noop_hibernated
  NOT_FOUND         HIBERNATED     false true  noop_hibernated
  NOT_FOUND         HIBERNATED     false false noop_hibernated
  NOT_FOUND         RESTORING      true  true  mark_hibernated
  NOT_FOUND         RESTORING      true  false mark_hibernated
  NOT_FOUND         RESTORING      false true  noop_missing
  NOT_FOUND         RESTORING      false false noop_missing
  NOT_FOUND         ACTIVE         true  true  mark_hibernated
  NOT_FOUND         ACTIVE         true  false mark_hibernated
  NOT_FOUND         ACTIVE         false true  noop_missing
  NOT_FOUND         ACTIVE         false false noop_missing
  ERROR             NONE           true  true  delete_only
  ERROR             NONE           true  false error:--force-delete-without-snapshot
  ERROR             NONE           false true  delete_only
  ERROR             NONE           false false error:--force-delete-without-snapshot
  ERROR             SNAPSHOT_SAVED true  true  delete_only
  ERROR             SNAPSHOT_SAVED true  false error:--force-delete-without-snapshot
  ERROR             SNAPSHOT_SAVED false true  delete_only
  ERROR             SNAPSHOT_SAVED false false error:--force-delete-without-snapshot
  ERROR             HIBERNATED     true  true  delete_only
  ERROR             HIBERNATED     true  false error:--force-delete-without-snapshot
  ERROR             HIBERNATED     false true  delete_only
  ERROR             HIBERNATED     false false error:--force-delete-without-snapshot
  ERROR             RESTORING      true  true  delete_only
  ERROR             RESTORING      true  false error:--force-delete-without-snapshot
  ERROR             RESTORING      false true  delete_only
  ERROR             RESTORING      false false error:--force-delete-without-snapshot
  ERROR             ACTIVE         true  true  delete_only
  ERROR             ACTIVE         true  false error:--force-delete-without-snapshot
  ERROR             ACTIVE         false true  delete_only
  ERROR             ACTIVE         false false error:--force-delete-without-snapshot
  CREATING          NONE           true  true  error:unexpected state CREATING
  CREATING          NONE           true  false error:unexpected state CREATING
  CREATING          NONE           false true  error:unexpected state CREATING
  CREATING          NONE           false false error:unexpected state CREATING
  CREATING          SNAPSHOT_SAVED true  true  error:unexpected state CREATING
  CREATING          SNAPSHOT_SAVED true  false error:unexpected state CREATING
  CREATING          SNAPSHOT_SAVED false true  error:unexpected state CREATING
  CREATING          SNAPSHOT_SAVED false false error:unexpected state CREATING
  CREATING          HIBERNATED     true  true  error:unexpected state CREATING
  CREATING          HIBERNATED     true  false error:unexpected state CREATING
  CREATING          HIBERNATED     false true  error:unexpected state CREATING
  CREATING          HIBERNATED     false false error:unexpected state CREATING
  CREATING          RESTORING      true  true  error:unexpected state CREATING
  CREATING          RESTORING      true  false error:unexpected state CREATING
  CREATING          RESTORING      false true  error:unexpected state CREATING
  CREATING          RESTORING      false false error:unexpected state CREATING
  CREATING          ACTIVE         true  true  error:unexpected state CREATING
  CREATING          ACTIVE         true  false error:unexpected state CREATING
  CREATING          ACTIVE         false true  error:unexpected state CREATING
  CREATING          ACTIVE         false false error:unexpected state CREATING
  UPDATING          NONE           true  true  error:unexpected state UPDATING
  UPDATING          NONE           true  false error:unexpected state UPDATING
  UPDATING          NONE           false true  error:unexpected state UPDATING
  UPDATING          NONE           false false error:unexpected state UPDATING
  UPDATING          SNAPSHOT_SAVED true  true  error:unexpected state UPDATING
  UPDATING          SNAPSHOT_SAVED true  false error:unexpected state UPDATING
  UPDATING          SNAPSHOT_SAVED false true  error:unexpected state UPDATING
  UPDATING          SNAPSHOT_SAVED false false error:unexpected state UPDATING
  UPDATING          HIBERNATED     true  true  error:unexpected state UPDATING
  UPDATING          HIBERNATED     true  false error:unexpected state UPDATING
  UPDATING          HIBERNATED     false true  error:unexpected state UPDATING
  UPDATING          HIBERNATED     false false error:unexpected state UPDATING
  UPDATING          RESTORING      true  true  error:unexpected state UPDATING
  UPDATING          RESTORING      true  false error:unexpected state UPDATING
  UPDATING          RESTORING      false true  error:unexpected state UPDATING
  UPDATING          RESTORING      false false error:unexpected state UPDATING
  UPDATING          ACTIVE         true  true  error:unexpected state UPDATING
  UPDATING          ACTIVE         true  false error:unexpected state UPDATING
  UPDATING          ACTIVE         false true  error:unexpected state UPDATING
  UPDATING          ACTIVE         false false error:unexpected state UPDATING
  STATE_UNSPECIFIED NONE           true  true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED NONE           true  false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED NONE           false true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED NONE           false false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED SNAPSHOT_SAVED true  true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED SNAPSHOT_SAVED true  false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED SNAPSHOT_SAVED false true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED SNAPSHOT_SAVED false false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED HIBERNATED     true  true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED HIBERNATED     true  false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED HIBERNATED     false true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED HIBERNATED     false false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED RESTORING      true  true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED RESTORING      true  false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED RESTORING      false true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED RESTORING      false false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED ACTIVE         true  true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED ACTIVE         true  false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED ACTIVE         false true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED ACTIVE         false false error:unexpected state STATE_UNSPECIFIED
EOF
  # Every one of the 6*5*2*2 cells is listed exactly once.
  assert_eq "${n}" 120 "rows"
  assert_eq "${#seen[@]}" 120 "distinct cells"
  if ((${#failures[@]})); then
    printf '%s\n' "${failures[@]}" >&2
    return 1
  fi
}

@test "decide_startup_action: full truth table (6 states x 5 statuses x snapshot)" {
  local state st snap want got failures=() n=0
  local -A seen=()
  while read -r state st snap want; do
    [[ -n "${state}" && "${state}" != \#* ]] || continue
    [[ " RUNNING NOT_FOUND ERROR CREATING UPDATING STATE_UNSPECIFIED " == *" ${state} "* ]] || failures+=("bad state ${state}")
    [[ " NONE SNAPSHOT_SAVED HIBERNATED RESTORING ACTIVE " == *" ${st} "* ]] || failures+=("bad status ${st}")
    [[ "${snap}" == true || "${snap}" == false ]] || failures+=("bad has_snapshot ${snap}")
    seen["${state}/${st}/${snap}"]=1
    n=$((n + 1))
    got="$(decide_startup_action "${state}" "${st}" "${snap}")"
    check_decision "${got}" "${want}" ||
      failures+=("decide_startup_action ${state} ${st} has_snapshot=${snap}: got '${got}', want '${want}'")
  done <<'EOF'
# STATE           STATUS         SNAP  EXPECTED
  RUNNING           NONE           true  noop
  RUNNING           NONE           false noop
  RUNNING           SNAPSHOT_SAVED true  mark_active
  RUNNING           SNAPSHOT_SAVED false mark_active
  RUNNING           HIBERNATED     true  load
  RUNNING           HIBERNATED     false mark_active
  RUNNING           RESTORING      true  load
  RUNNING           RESTORING      false mark_active
  RUNNING           ACTIVE         true  noop
  RUNNING           ACTIVE         false noop
  NOT_FOUND         NONE           true  create_and_load
  NOT_FOUND         NONE           false create_fresh
  NOT_FOUND         SNAPSHOT_SAVED true  create_and_load
  NOT_FOUND         SNAPSHOT_SAVED false create_fresh
  NOT_FOUND         HIBERNATED     true  create_and_load
  NOT_FOUND         HIBERNATED     false create_fresh
  NOT_FOUND         RESTORING      true  create_and_load
  NOT_FOUND         RESTORING      false create_fresh
  NOT_FOUND         ACTIVE         true  create_and_load
  NOT_FOUND         ACTIVE         false create_fresh
  ERROR             NONE           true  error:outside a hibernation cycle
  ERROR             NONE           false error:outside a hibernation cycle
  ERROR             SNAPSHOT_SAVED true  replace_and_load
  ERROR             SNAPSHOT_SAVED false error:no snapshot to restore
  ERROR             HIBERNATED     true  replace_and_load
  ERROR             HIBERNATED     false error:no snapshot to restore
  ERROR             RESTORING      true  replace_and_load
  ERROR             RESTORING      false error:no snapshot to restore
  ERROR             ACTIVE         true  error:outside a hibernation cycle
  ERROR             ACTIVE         false error:outside a hibernation cycle
  CREATING          NONE           true  error:unexpected state CREATING
  CREATING          NONE           false error:unexpected state CREATING
  CREATING          SNAPSHOT_SAVED true  error:unexpected state CREATING
  CREATING          SNAPSHOT_SAVED false error:unexpected state CREATING
  CREATING          HIBERNATED     true  error:unexpected state CREATING
  CREATING          HIBERNATED     false error:unexpected state CREATING
  CREATING          RESTORING      true  error:unexpected state CREATING
  CREATING          RESTORING      false error:unexpected state CREATING
  CREATING          ACTIVE         true  error:unexpected state CREATING
  CREATING          ACTIVE         false error:unexpected state CREATING
  UPDATING          NONE           true  error:unexpected state UPDATING
  UPDATING          NONE           false error:unexpected state UPDATING
  UPDATING          SNAPSHOT_SAVED true  error:unexpected state UPDATING
  UPDATING          SNAPSHOT_SAVED false error:unexpected state UPDATING
  UPDATING          HIBERNATED     true  error:unexpected state UPDATING
  UPDATING          HIBERNATED     false error:unexpected state UPDATING
  UPDATING          RESTORING      true  error:unexpected state UPDATING
  UPDATING          RESTORING      false error:unexpected state UPDATING
  UPDATING          ACTIVE         true  error:unexpected state UPDATING
  UPDATING          ACTIVE         false error:unexpected state UPDATING
  STATE_UNSPECIFIED NONE           true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED NONE           false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED SNAPSHOT_SAVED true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED SNAPSHOT_SAVED false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED HIBERNATED     true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED HIBERNATED     false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED RESTORING      true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED RESTORING      false error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED ACTIVE         true  error:unexpected state STATE_UNSPECIFIED
  STATE_UNSPECIFIED ACTIVE         false error:unexpected state STATE_UNSPECIFIED
EOF
  assert_eq "${n}" 60 "rows"
  assert_eq "${#seen[@]}" 60 "distinct cells"
  if ((${#failures[@]})); then
    printf '%s\n' "${failures[@]}" >&2
    return 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# Plan guards (real Terraform 1.17.2 plan JSON in fixtures/plans)
# ════════════════════════════════════════════════════════════════════════════

@test "plan_changes: only real changes, as address<TAB>actions" {
  run plan_changes "${PLANS}/destroy-targeted-two.json"
  assert_status 0
  assert_eq "${output}" "${DEV_ENV}"$'\t'"delete"$'\n'"${TEST_ENV}"$'\t'"delete"
  run plan_changes "${PLANS}/create-module-target.json"
  assert_eq "${output}" "${TEST_ENV}"$'\t'"create" "no-op entries are filtered"
  run plan_changes "${PLANS}/replace-module-target.json"
  assert_eq "${output}" "${DEV_ENV}"$'\t'"delete,create"
  run plan_changes "${PLANS}/create-resource-target-leak.json"
  assert_eq "${#lines[@]}" 2
  assert_eq "$(plan_changes "${PLANS}/destroy-untargeted-module.json" | wc -l)" 16
}

@test "plan_changes: a plan without resource_changes (typo target) yields nothing" {
  run jq -e 'has("resource_changes")' "${PLANS}/destroy-typo-target.json"
  assert_status 1
  run plan_changes "${PLANS}/destroy-typo-target.json"
  assert_status 0
  assert_eq "${output}" ""
}

@test "plan_changes: data-source reads and no-ops are ignored" {
  local plan
  plan="$(t_mkplan synthetic \
    "${DEV_PREFIX}.data.google_project.this=read" \
    "${DEV_PREFIX}.google_compute_network.composer[0]=no-op" \
    "${DEV_PREFIX}.google_service_account.composer[0]=update")"
  run plan_changes "${plan}"
  assert_eq "${output}" "${DEV_PREFIX}.google_service_account.composer[0]"$'\t'"update"
}

@test "guard_destroy_plan: destroy-targeted-one passes for its target only" {
  run guard_destroy_plan "${PLANS}/destroy-targeted-one.json" "${DEV_ENV}"
  assert_status 0
  run guard_destroy_plan "${PLANS}/destroy-targeted-one.json" "${DEV_ENV}" "${TEST_ENV}"
  assert_status 0
  run guard_destroy_plan "${PLANS}/destroy-targeted-one.json" "${TEST_ENV}"
  assert_status 1
  assert_contains "${output}" "unexpected change 'delete' on ${DEV_ENV}"
}

@test "guard_destroy_plan: destroy-targeted-two needs both environments allowed" {
  run guard_destroy_plan "${PLANS}/destroy-targeted-two.json" "${DEV_ENV}" "${TEST_ENV}"
  assert_status 0
  run guard_destroy_plan "${PLANS}/destroy-targeted-two.json" "${DEV_ENV}"
  assert_status 1
  assert_contains "${output}" "${TEST_ENV}"
}

@test "guard_destroy_plan: destroy-untargeted-module (whole module) fails and names the extras" {
  run guard_destroy_plan "${PLANS}/destroy-untargeted-module.json" "${DEV_ENV}"
  assert_status 1
  assert_contains "${output}" "${DEV_PREFIX}.google_compute_network.composer[0]"
  assert_contains "${output}" "${DEV_PREFIX}.google_service_account.composer[0]"
  assert_not_contains "${output}" "on ${DEV_ENV} " "the allowed address itself is fine"
  # 15 of the 16 deletions are refused, each reported.
  assert_eq "$(grep -c 'plan guard: unexpected change' <<<"${output}")" 15
}

@test "guard_destroy_plan: rejects anything but delete, even on an allowed address" {
  local plan
  plan="$(t_mkplan replace "${DEV_ENV}=delete,create")"
  run guard_destroy_plan "${plan}" "${DEV_ENV}"
  assert_status 1
  run guard_destroy_plan "${PLANS}/create-module-target.json" "${TEST_ENV}"
  assert_status 1
  assert_contains "${output}" "unexpected change 'create'"
}

@test "destroy-typo-target: guard passes (no changes) BUT plan_must_contain catches the miss" {
  run guard_destroy_plan "${PLANS}/destroy-typo-target.json" "${DEV_ENV}"
  assert_status 0
  run plan_must_contain "${PLANS}/destroy-typo-target.json" "${DEV_ENV}" delete
  assert_status 1
  assert_contains "${output}" "got 'absent'"
}

@test "plan_must_contain: exact address and exact action list" {
  run plan_must_contain "${PLANS}/destroy-targeted-one.json" "${DEV_ENV}" delete
  assert_status 0
  run plan_must_contain "${PLANS}/destroy-targeted-one.json" "${TEST_ENV}" delete
  assert_status 1
  run plan_must_contain "${PLANS}/destroy-targeted-one.json" "${DEV_ENV}" create
  assert_status 1
  assert_contains "${output}" "expected ${DEV_ENV} to be planned as 'create', got 'delete'"
  run plan_must_contain "${PLANS}/destroy-targeted-one.json" "${DEV_PREFIX}" delete
  assert_status 1
}

@test "guard_create_plan + plan_must_contain: create-module-target passes" {
  run guard_create_plan "${PLANS}/create-module-target.json" "" "${TEST_PREFIX}"
  assert_status 0
  run plan_must_contain "${PLANS}/create-module-target.json" "${TEST_ENV}" create
  assert_status 0
  run guard_create_plan "${PLANS}/create-module-target-pending-change.json" "" "${TEST_PREFIX}"
  assert_status 0
}

@test "guard_create_plan: create-resource-target-leak fails (change outside the prefix)" {
  run guard_create_plan "${PLANS}/create-resource-target-leak.json" "" "${TEST_PREFIX}"
  assert_status 1
  assert_contains "${output}" "change 'create' on ${DEV_PREFIX}.google_project_iam_member.composer_sa_roles[\"roles/bigquery.jobUser\"] is outside the selected environments"
  # ... although the intended environment is in the plan.
  run plan_must_contain "${PLANS}/create-resource-target-leak.json" "${TEST_ENV}" create
  assert_status 0
  # Selecting both environments makes the same plan acceptable.
  run guard_create_plan "${PLANS}/create-resource-target-leak.json" "" "${TEST_PREFIX}" "${DEV_PREFIX}"
  assert_status 0
}

@test "guard_create_plan: wrong module prefix refuses the create" {
  run guard_create_plan "${PLANS}/create-module-target.json" "" "${DEV_PREFIX}"
  assert_status 1
  assert_contains "${output}" "${TEST_ENV} is outside the selected environments"
}

@test "guard_create_plan: replace-module-target passes only when the address is replaceable" {
  run guard_create_plan "${PLANS}/replace-module-target.json" "${DEV_ENV}" "${DEV_PREFIX}"
  assert_status 0
  run guard_create_plan "${PLANS}/replace-module-target.json" "${TEST_ENV} ${DEV_ENV}" "${DEV_PREFIX}"
  assert_status 0
  run guard_create_plan "${PLANS}/replace-module-target.json" "" "${DEV_PREFIX}"
  assert_status 1
  assert_contains "${output}" "unexpected replacement of ${DEV_ENV}"
  run guard_create_plan "${PLANS}/replace-module-target.json" "${TEST_ENV}" "${DEV_PREFIX}"
  assert_status 1
  run guard_create_plan "${PLANS}/replace-module-target.json" "${DEV_ENV}" "${TEST_PREFIX}"
  assert_status 1
  # A partial address in the replaceable list must not match.
  run guard_create_plan "${PLANS}/replace-module-target.json" "${DEV_PREFIX}" "${DEV_PREFIX}"
  assert_status 1
}

@test "plan_must_contain: alternatives 'delete,create|create,delete'" {
  run plan_must_contain "${PLANS}/replace-module-target.json" "${DEV_ENV}" "delete,create|create,delete"
  assert_status 0
  run plan_must_contain "${PLANS}/replace-module-target.json" "${DEV_ENV}" "create,delete|delete,create"
  assert_status 0
  run plan_must_contain "${PLANS}/replace-module-target.json" "${DEV_ENV}" "delete"
  assert_status 1
  run plan_must_contain "${PLANS}/replace-module-target.json" "${DEV_ENV}" "create"
  assert_status 1
  run plan_must_contain "${PLANS}/replace-module-target.json" "${DEV_ENV}" "create|delete"
  assert_status 1
  assert_contains "${output}" "'create or delete', got 'delete,create'"
  local cbd
  cbd="$(t_mkplan cbd "${DEV_ENV}=create,delete")"
  run plan_must_contain "${cbd}" "${DEV_ENV}" "delete,create|create,delete"
  assert_status 0
  run guard_create_plan "${cbd}" "${DEV_ENV}" "${DEV_PREFIX}"
  assert_status 0
}

@test "guard_create_plan: lookalike module keys are outside the prefix" {
  local plan
  plan="$(t_mkplan lookalike \
    "${DEV_PREFIX}.data.google_project.this=read" \
    "${DEV_PREFIX}.google_service_account.composer[0]=update" \
    'module.composer["composer-dev2"].google_composer_environment.this=create')"
  run guard_create_plan "${plan}" "" "${DEV_PREFIX}"
  assert_status 1
  assert_contains "${output}" 'module.composer["composer-dev2"].google_composer_environment.this is outside'
  run guard_create_plan "${plan}" "" "${DEV_PREFIX}" 'module.composer["composer-dev2"]'
  assert_status 0
}

@test "guard_create_plan: delete / forget inside the prefix are refused, every violation reported" {
  local plan
  plan="$(t_mkplan unsafe \
    "${DEV_PREFIX}.google_compute_network.composer[0]=delete" \
    "${DEV_PREFIX}.google_service_account.composer[0]=forget" \
    "${DEV_ENV}=create")"
  run guard_create_plan "${plan}" "${DEV_ENV}" "${DEV_PREFIX}"
  assert_status 1
  assert_contains "${output}" "unexpected change 'delete' on ${DEV_PREFIX}.google_compute_network.composer[0]"
  assert_contains "${output}" "unexpected change 'forget' on ${DEV_PREFIX}.google_service_account.composer[0]"
}

# ════════════════════════════════════════════════════════════════════════════
# Image versions
# ════════════════════════════════════════════════════════════════════════════

@test "image_version_creatable: exact build and X.Y.Z / X.Y / X aliases" {
  local list=$'composer-3-airflow-2.10.5-build.17\ncomposer-3-airflow-2.9.3-build.31\ncomposer-3-airflow-3.0.1-build.3'
  local v
  for v in composer-3-airflow-2.10.5-build.17 composer-3-airflow-2.10.5 composer-3-airflow-2.10 \
    composer-3-airflow-2.9 composer-3-airflow-2.9.3 composer-3-airflow-2 composer-3-airflow-3 composer-3-airflow-3.0.1; do
    run image_version_creatable "${v}" <<<"${list}"
    assert_eq "${status}" 0 "${v} should be creatable"
  done
}

@test "image_version_creatable: no prefix confusion between versions or builds" {
  local list=$'composer-3-airflow-2.10.5-build.17\ncomposer-3-airflow-2.10.50-build.1'
  local v
  for v in composer-3-airflow-2.1 composer-3-airflow-2.10.4 composer-3-airflow-2.10.5-build.1 \
    composer-3-airflow-2.10.5-build.16 composer-3-airflow-3 composer-3-airflow-2.9 composer-3-airflow-2.10.50-build.17; do
    run image_version_creatable "${v}" <<<"${list}"
    assert_eq "${status}" 1 "${v} must not be creatable"
  done
  # 2.1 must not match 2.10.x, but 2.10.5 must not match 2.10.50 either.
  run image_version_creatable composer-3-airflow-2.10.5 <<<"composer-3-airflow-2.10.50-build.1"
  assert_status 1
  run image_version_creatable composer-3-airflow-2.10.5 <<<""
  assert_status 1
  run image_version_creatable composer-3-airflow-2.10.5 <<<"<none>"
  assert_status 1
}

@test "list_creatable_image_versions: follows nextPageToken, drops creationDisabled" {
  t_pages first.json tok-page-2.json
  run --separate-stderr list_creatable_image_versions hib-test-project europe-west2
  assert_status 0
  assert_eq "${output}" $'composer-3-airflow-2.10.5-build.17\ncomposer-3-airflow-2.9.3-build.31\ncomposer-3-airflow-3.0.1-build.3'
  assert_eq "$(cat "${STUB_DIR}/curl.count")" 2 "one request per page"
  assert_eq "$(sed -n 1p "${STUB_DIR}/curl.urls")" \
    "https://composer.unit.test/v1/projects/hib-test-project/locations/europe-west2/imageVersions?pageSize=500&includePastReleases=false"
  assert_eq "$(sed -n 2p "${STUB_DIR}/curl.urls")" \
    "https://composer.unit.test/v1/projects/hib-test-project/locations/europe-west2/imageVersions?pageSize=500&includePastReleases=false&pageToken=tok-page-2"
}

@test "list_creatable_image_versions: the token goes through stdin (-K -), never argv" {
  t_pages first.json tok-page-2.json
  run --separate-stderr list_creatable_image_versions hib-test-project europe-west2
  assert_status 0
  local n
  for n in 1 2; do
    run grep -F "ya29.unit-test-token" "${STUB_DIR}/curl.${n}.argv"
    assert_eq "${status}" 1 "token must not appear in curl argv (call ${n})"
    assert_eq "$(cat "${STUB_DIR}/curl.${n}.stdin")" 'header = "Authorization: Bearer ya29.unit-test-token"'
    grep -qxF -- "-K" "${STUB_DIR}/curl.${n}.argv"
    assert_eq "$(grep -A1 -xF -- "-K" "${STUB_DIR}/curl.${n}.argv" | tail -n 1)" "-" "-K reads the config from stdin"
    grep -qx -- "-fsS" "${STUB_DIR}/curl.${n}.argv"
  done
  assert_eq "$(t_calls "auth print-access-token")" 1 "one token for all pages"
}

@test "list_creatable_image_versions: any failed request returns 1" {
  t_pages first.json tok-page-2.json
  touch "${STUB_DIR}/curl-fail"
  run --separate-stderr list_creatable_image_versions hib-test-project europe-west2
  assert_status 1
  assert_contains "${stderr}" "could not list image versions for hib-test-project/europe-west2"

  # Second page missing (404) after a successful first page.
  rm -f "${STUB_DIR}/curl-fail" "${STUB_DIR}/pages/tok-page-2.json"
  run --separate-stderr list_creatable_image_versions hib-test-project europe-west2
  assert_status 1
}

@test "list_creatable_image_versions: a non-JSON response is a failure, not an empty list" {
  # e.g. an HTTP 200 HTML page from an intercepting proxy
  t_pages first.json
  printf '<html><body>Sign in to continue</body></html>\n' >"${STUB_DIR}/pages/first.json"
  run --separate-stderr list_creatable_image_versions hib-test-project europe-west2
  assert_eq "${status}" 1 "unparseable listing must not look like 'no creatable versions'"
  # ... so check_restorable reports that it could not verify, instead of
  # telling the user to change software_config.image_version.
  run --separate-stderr check_restorable_out composer-dev composer-3-airflow-2.10.5-build.17
  assert_status 1
  assert_contains "${output}" "could not verify"
}

@test "list_creatable_image_versions: no access token returns 1 without calling the API" {
  t_pages first.json
  t_reply token 1 "" "ERROR: (gcloud.auth.print-access-token) You do not currently have an active account selected."
  run --separate-stderr list_creatable_image_versions hib-test-project europe-west2
  assert_status 1
  assert_contains "${stderr}" "could not obtain an access token"
  [[ ! -f "${STUB_DIR}/curl.count" ]]
}

@test "restore_image_version: YAML image wins, pin derives X.Y.Z, else empty" {
  assert_eq "$(restore_image_version composer-test composer-3-airflow-2.10.5-build.17)" "composer-3-airflow-2.9.3" "YAML wins over the running version"
  assert_eq "$(restore_image_version composer-dev composer-3-airflow-2.10.5-build.17)" "composer-3-airflow-2.10.5" "pin"
  run restore_image_version composer-nopin composer-3-airflow-2.10.5-build.17
  assert_status 0
  assert_eq "${output}" "" "pin_image_version: false and no YAML image"
  run restore_image_version composer-dev ""
  assert_status 0
  assert_eq "${output}" "" "nothing to pin"
  run restore_image_version composer-dev composer-3-airflow-2.10
  assert_status 0
  assert_eq "${output}" "" "unparseable running version"
}

@test "check_restorable: creatable alias passes; the listing is cached per project/region" {
  t_pages first.json tok-page-2.json
  check_restorable composer-dev composer-3-airflow-2.10.5-build.17 2>/dev/null
  check_restorable composer-dev composer-3-airflow-2.10.5-build.17 2>/dev/null
  # composer-test (YAML 2.9.3) shares project and region: no new listing.
  check_restorable composer-test composer-3-airflow-2.9.3-build.31 2>/dev/null
  assert_eq "$(cat "${STUB_DIR}/curl.count")" 2 "one listing (2 pages) for three checks"
  assert_contains "$(sed -n 1p "${STUB_DIR}/curl.urls")" "/projects/hib-test-project/locations/europe-west2/"
  run --separate-stderr check_restorable_out composer-dev composer-3-airflow-2.10.5-build.17
  assert_status 0
  assert_eq "${output}" "" "no failure reason on stdout"
  assert_contains "${stderr}" "restore image composer-3-airflow-2.10.5 is creatable"
}

@test "check_restorable: pin_image_version false and no YAML image -> GCP's default image must load the snapshot" {
  t_pages first.json tok-page-2.json
  # Default (isDefault) is composer-3-airflow-2.10.5-build.17.
  run --separate-stderr check_restorable_out composer-nopin composer-3-airflow-2.10.5-build.17
  assert_status 0
  assert_eq "${output}" ""
  assert_contains "${stderr}" "restore will use GCP's default image composer-3-airflow-2.10.5-build.17"
  run --separate-stderr check_restorable_out composer-nopin composer-3-airflow-2.11.0-build.2
  assert_status 1
  assert_contains "${output}" "GCP's default image composer-3-airflow-2.10.5-build.17, which cannot load a snapshot of the running composer-3-airflow-2.11.0-build.2"
}

@test "check_restorable: GCP default image unknown or not Composer 3 -> fail closed (unless skipped)" {
  t_pages first.json tok-page-2.json
  touch "${STUB_DIR}/curl-fail"
  run --separate-stderr check_restorable_out composer-nopin composer-3-airflow-2.10.5-build.17
  assert_status 1
  assert_contains "${output}" "could not determine GCP's default image"
  rm -f "${STUB_DIR}/curl-fail"
  jq '.imageVersions[0].isDefault = false' "${UNIT}/image-versions/first.json" >"${STUB_DIR}/pages/first.json"
  run --separate-stderr check_restorable_out composer-nopin composer-3-airflow-2.10.5-build.17
  assert_status 1
  assert_contains "${stderr}" "names no default image"
  jq '.imageVersions[0].imageVersionId = "composer-2.9.7-airflow-2.9.3"' "${UNIT}/image-versions/first.json" >"${STUB_DIR}/pages/first.json"
  run --separate-stderr check_restorable_out composer-nopin composer-3-airflow-2.10.5-build.17
  assert_status 1
  assert_contains "${output}" "not a Composer 3 image"
  local calls
  calls="$(cat "${STUB_DIR}/curl.count")"
  HIBERNATE_SKIP_IMAGE_CHECK=true
  run --separate-stderr check_restorable_out composer-nopin composer-3-airflow-2.10.5-build.17
  assert_status 0
  assert_eq "$(cat "${STUB_DIR}/curl.count")" "${calls}" "no API call when skipped"
}

@test "check_restorable: YAML downgrade (2.9.3 vs running 2.10.5) fails before any API call" {
  t_pages first.json tok-page-2.json
  run --separate-stderr check_restorable_out composer-test composer-3-airflow-2.10.5-build.17
  assert_status 1
  assert_contains "${output}" "restore image composer-3-airflow-2.9.3 (Airflow 2.9.3) could not load a snapshot of the running composer-3-airflow-2.10.5-build.17"
  [[ ! -f "${STUB_DIR}/curl.count" ]]
  # HIBERNATE_SKIP_IMAGE_CHECK only skips the creatability check, not this one.
  HIBERNATE_SKIP_IMAGE_CHECK=true
  run --separate-stderr check_restorable_out composer-test composer-3-airflow-2.10.5-build.17
  assert_status 1
}

@test "check_restorable: cross-major YAML image fails" {
  t_pages first.json tok-page-2.json
  jq '."composer-test".image_version = "composer-3-airflow-3.0.1"' "${UNIT}/resolved.json" >"${RESOLVED_JSON}"
  run --separate-stderr check_restorable_out composer-test composer-3-airflow-2.10.5-build.17
  assert_status 1
  assert_contains "${output}" "could not load a snapshot"
  jq '."composer-test".image_version = "composer-3-airflow-2.10.5"' "${UNIT}/resolved.json" >"${RESOLVED_JSON}"
  run --separate-stderr check_restorable_out composer-test composer-3-airflow-3.0.1-build.3
  assert_status 1
}

@test "check_restorable: a version that is no longer creatable fails" {
  t_pages first.json tok-page-2.json
  run --separate-stderr check_restorable_out composer-dev composer-3-airflow-2.8.1-build.5
  assert_status 1
  assert_contains "${output}" "image version composer-3-airflow-2.8.1 can no longer be used to create environments in europe-west2"
}

@test "check_restorable: creationDisabled builds do not count as creatable" {
  t_pages disabled-only.json
  run --separate-stderr check_restorable_out composer-dev composer-3-airflow-2.10.5-build.17
  assert_status 1
  assert_contains "${output}" "can no longer be used"
}

@test "check_restorable: HIBERNATE_SKIP_IMAGE_CHECK=true skips the creatability check" {
  t_pages first.json
  HIBERNATE_SKIP_IMAGE_CHECK=true
  run --separate-stderr check_restorable_out composer-dev composer-3-airflow-2.8.1-build.5
  assert_status 0
  assert_contains "${stderr}" "HIBERNATE_SKIP_IMAGE_CHECK set"
  [[ ! -f "${STUB_DIR}/curl.count" ]]
  assert_eq "$(t_calls "auth print-access-token")" 0
}

@test "check_restorable: API failures fail closed" {
  t_pages first.json
  touch "${STUB_DIR}/curl-fail"
  run --separate-stderr check_restorable_out composer-dev composer-3-airflow-2.10.5-build.17
  assert_status 1
  assert_contains "${output}" "could not verify that composer-3-airflow-2.10.5 is still creatable"
  rm -f "${STUB_DIR}/curl-fail"
  t_reply token 1 "" "ERROR: (gcloud.auth.print-access-token) Reauthentication required."
  run --separate-stderr check_restorable_out composer-dev composer-3-airflow-2.10.5-build.17
  assert_status 1
  assert_contains "${output}" "could not verify"
}

@test "check_restorable: unknown running version skips only the compatibility check" {
  t_pages first.json tok-page-2.json
  run --separate-stderr check_restorable_out composer-test ""
  assert_status 0
  assert_eq "$(cat "${STUB_DIR}/curl.count")" 2 "creatability still checked"
}

# ════════════════════════════════════════════════════════════════════════════
# Resolved settings
# ════════════════════════════════════════════════════════════════════════════

@test "fixtures: resolved.json is the real resolver output for hibernation-unit.yaml" {
  [[ -n "${REAL_TERRAFORM}" ]] || skip "terraform is not installed"
  local tmp="${BATS_TEST_TMPDIR}/resolver"
  mkdir -p "${tmp}"
  TF_DATA_DIR="${tmp}/data" "${REAL_TERRAFORM}" -chdir="${REPO}/scripts/hibernation/resolver" init \
    -input=false -no-color -backend-config="path=${tmp}/r.tfstate" >"${tmp}/log" 2>&1
  TF_DATA_DIR="${tmp}/data" "${REAL_TERRAFORM}" -chdir="${REPO}/scripts/hibernation/resolver" apply \
    -auto-approve -input=false -lock=false -no-color \
    -var "config_file=${UNIT}/hibernation-unit.yaml" >>"${tmp}/log" 2>&1
  TF_DATA_DIR="${tmp}/data" "${REAL_TERRAFORM}" -chdir="${REPO}/scripts/hibernation/resolver" output \
    -no-color -json environments | jq -S . >"${tmp}/got.json"
  run diff -u "${UNIT}/resolved.json" "${tmp}/got.json"
  assert_status 0
}

@test "setting: false booleans are printed as 'false' (not swallowed)" {
  assert_eq "$(setting composer-nopin .hibernation.create_snapshot_bucket)" "false"
  assert_eq "$(setting composer-nopin .hibernation.pin_image_version)" "false"
  assert_eq "$(setting composer-prod .hibernation.enabled)" "false"
  assert_eq "$(setting composer-dev .hibernation.load_options.skip_gcs_data_copying)" "false"
  assert_eq "$(setting composer-dev .is_production)" "false"
  assert_eq "$(setting composer-dev .hibernation.enabled)" "true"
  assert_eq "$(setting composer-prod .is_production)" "true"
}

@test "setting: objects/arrays as compact JSON, scalars as text, null/missing as empty" {
  assert_eq "$(setting composer-dev .labels)" '{"env":"dev","managed_by":"terraform"}'
  assert_eq "$(setting composer-dev .validation_errors)" '[]'
  assert_eq "$(setting composer-dev .hibernation.load_options)" \
    '{"skip_airflow_overrides_setting":true,"skip_environment_variables_setting":true,"skip_gcs_data_copying":false,"skip_pypi_packages_installation":true}'
  assert_eq "$(setting composer-bad .validation_errors | jq 'length')" 2
  assert_eq "$(setting composer-dev .hibernation.snapshot_retention_count)" "2"
  assert_eq "$(setting composer-test .image_version)" "composer-3-airflow-2.9.3"
  assert_eq "$(setting composer-test .custom_bucket)" "hib-test-project-composer-test-data"
  assert_eq "$(setting composer-nopin .region)" "us-central1"
  assert_eq "$(setting composer-dev .hibernation.state_object)" "${STATE_URL_DEV}"
  run setting composer-dev .image_version
  assert_status 0
  assert_eq "${output}" "" "null"
  run setting composer-dev .custom_bucket
  assert_eq "${output}" "" "null"
  run setting composer-dev .no_such_field
  assert_eq "${output}" "" "missing field"
  run setting composer-nope .project_id
  assert_status 0
  assert_eq "${output}" "" "missing environment"
}

# ════════════════════════════════════════════════════════════════════════════
# Option parsing (parse-args.sh sources the lib in its own process: die exits)
# ════════════════════════════════════════════════════════════════════════════

@test "parse_common_args: --config / -c / --config=" {
  run bash "${UNIT}/parse-args.sh" shutdown --config a.yaml
  assert_status 0
  assert_contains "${output}" $'config=a.yaml\n'
  run bash "${UNIT}/parse-args.sh" shutdown -c "dir with space/b.yaml"
  assert_contains "${output}" $'config=dir with space/b.yaml\n'
  run bash "${UNIT}/parse-args.sh" startup --config=c.yaml
  assert_contains "${output}" $'config=c.yaml\n'
  # Defaults when only --config is given.
  run bash "${UNIT}/parse-args.sh" startup --config=c.yaml
  assert_contains "${output}" $'envs=\nenv_count=0\ndry_run=false\nskip_init=false\nwork_dir=\nvar_files=\nforce_no_snapshot=false\nallow_initial_create=false\nskip_load=false'
}

@test "parse_common_args: HIBERNATE_CONFIG_FILE satisfies --config; the flag wins" {
  HIBERNATE_CONFIG_FILE=env.yaml run bash "${UNIT}/parse-args.sh" shutdown
  assert_status 0
  assert_contains "${output}" "config=env.yaml"
  HIBERNATE_CONFIG_FILE=env.yaml run bash "${UNIT}/parse-args.sh" shutdown --config flag.yaml
  assert_contains "${output}" "config=flag.yaml"
}

@test "parse_common_args: --env repeated, comma/space lists, --env= and -e" {
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --env composer-dev --env composer-test,composer-qa \
    -e "composer-a composer-b" --env=composer-c,composer-d
  assert_status 0
  assert_contains "${output}" "envs=composer-dev|composer-test|composer-qa|composer-a|composer-b|composer-c|composer-d"
  assert_contains "${output}" "env_count=7"
}

@test "parse_common_args: HIBERNATE_ENVIRONMENTS selects environments" {
  HIBERNATE_ENVIRONMENTS="composer-dev, composer-test" run bash "${UNIT}/parse-args.sh" startup -c x.yaml
  assert_status 0
  assert_contains "${output}" "envs=composer-dev|composer-test"
  assert_contains "${output}" "env_count=2"
}

@test "parse_common_args: --dry-run / -n / HIBERNATE_DRY_RUN and --skip-init / HIBERNATE_SKIP_INIT" {
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --dry-run
  assert_contains "${output}" "dry_run=true"
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml -n
  assert_contains "${output}" "dry_run=true"
  HIBERNATE_DRY_RUN=yes run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml
  assert_contains "${output}" "dry_run=true"
  HIBERNATE_DRY_RUN=false run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml
  assert_contains "${output}" "dry_run=false"
  run bash "${UNIT}/parse-args.sh" startup -c x.yaml --skip-init
  assert_contains "${output}" "skip_init=true"
  HIBERNATE_SKIP_INIT=1 run bash "${UNIT}/parse-args.sh" startup -c x.yaml
  assert_contains "${output}" "skip_init=true"
}

@test "parse_common_args: --var-file (both forms) in order; replaces HIBERNATE_TF_VAR_FILES" {
  HIBERNATE_TF_VAR_FILES="env1.tfvars,env2.tfvars" run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml
  assert_status 0
  assert_contains "${output}" "var_files=env1.tfvars|env2.tfvars"
  HIBERNATE_TF_VAR_FILES="env1.tfvars,env2.tfvars" run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml \
    --var-file a.tfvars --var-file=b.tfvars
  assert_status 0
  assert_contains "${output}" "var_files=a.tfvars|b.tfvars"
}

@test "parse_common_args: --env replaces HIBERNATE_ENVIRONMENTS" {
  HIBERNATE_ENVIRONMENTS=composer-qa run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --env composer-dev
  assert_status 0
  assert_contains "${output}" "envs=composer-dev"
  assert_contains "${output}" "env_count=1"
}

@test "parse_common_args: a selection naming no environment is refused (never 'all')" {
  local v
  for v in "" " " "," " , "; do
    run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --env "${v}"
    assert_status 2
    assert_contains "${output}" "names no environment"
    run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml "--env=${v}"
    assert_status 2
    HIBERNATE_ENVIRONMENTS="${v}" run bash "${UNIT}/parse-args.sh" startup -c x.yaml
    assert_status 2
    assert_contains "${output}" "HIBERNATE_ENVIRONMENTS is set but names no environment"
  done
  # Unset = every enabled environment (documented default).
  run bash "${UNIT}/parse-args.sh" startup -c x.yaml
  assert_status 0
  assert_contains "${output}" "env_count=0"
}

@test "parse_common_args: --force-load (startup only) excludes --skip-load" {
  run bash "${UNIT}/parse-args.sh" startup -c x.yaml --force-load
  assert_status 0
  assert_contains "${output}" "force_load=true"
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --force-load
  assert_status 2
  run bash "${UNIT}/parse-args.sh" startup -c x.yaml --force-load --skip-load
  assert_status 2
  assert_contains "${output}" "mutually exclusive"
}

@test "parse_common_args: --work-dir (both forms) and HIBERNATE_WORK_DIR" {
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --work-dir /tmp/w1
  assert_contains "${output}" "work_dir=/tmp/w1"
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --work-dir=/tmp/w2
  assert_contains "${output}" "work_dir=/tmp/w2"
  HIBERNATE_WORK_DIR=/tmp/w3 run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml
  assert_contains "${output}" "work_dir=/tmp/w3"
}

@test "parse_common_args: mode-specific flags are accepted in their own mode" {
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --force-delete-without-snapshot
  assert_status 0
  assert_contains "${output}" "force_no_snapshot=true"
  run bash "${UNIT}/parse-args.sh" startup -c x.yaml --allow-initial-create --skip-load
  assert_status 0
  assert_contains "${output}" "allow_initial_create=true"
  assert_contains "${output}" "skip_load=true"
}

@test "parse_common_args: mode-specific flags in the wrong mode exit 2" {
  run bash "${UNIT}/parse-args.sh" startup -c x.yaml --force-delete-without-snapshot
  assert_status 2
  assert_contains "${output}" "--force-delete-without-snapshot is only valid for composer-shutdown.sh"
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --allow-initial-create
  assert_status 2
  assert_contains "${output}" "--allow-initial-create is only valid for composer-startup.sh"
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --skip-load
  assert_status 2
  assert_contains "${output}" "--skip-load is only valid for composer-startup.sh"
}

@test "parse_common_args: unknown flag exits 2 and prints usage" {
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml --bogus
  assert_status 2
  assert_contains "${output}" "usage: dummy usage text"
  assert_contains "${output}" "unknown argument: --bogus"
  run bash "${UNIT}/parse-args.sh" shutdown -c x.yaml extra-positional
  assert_status 2
}

@test "parse_common_args: missing --config, or a flag without its value, exits 2" {
  run bash "${UNIT}/parse-args.sh" shutdown
  assert_status 2
  assert_contains "${output}" "--config (or HIBERNATE_CONFIG_FILE) is required"
  run bash "${UNIT}/parse-args.sh" shutdown --config=
  assert_status 2
  local flag
  for flag in --config -c --env -e --var-file --work-dir; do
    run bash "${UNIT}/parse-args.sh" shutdown "${flag}"
    assert_eq "${status}" 2 "${flag} without a value"
    assert_contains "${output}" "${flag} needs a value"
  done
}

@test "parse_common_args: -h / --help prints usage and exits 0" {
  run bash "${UNIT}/parse-args.sh" shutdown --help
  assert_status 0
  assert_eq "${output}" "usage: dummy usage text"
  run bash "${UNIT}/parse-args.sh" startup -h
  assert_status 0
}

# ════════════════════════════════════════════════════════════════════════════
# Environment selection and eligibility
# ════════════════════════════════════════════════════════════════════════════

@test "select_environments: default selects only hibernation.enabled environments" {
  OPT_ENVS=()
  run --separate-stderr select_environments
  assert_status 0
  assert_eq "${output}" $'composer-bad\ncomposer-dev\ncomposer-nopin\ncomposer-test'
}

@test "select_environments: explicit keys keep their order and are de-duplicated" {
  OPT_ENVS=(composer-test composer-dev composer-test composer-nopin composer-dev)
  run --separate-stderr select_environments
  assert_status 0
  assert_eq "${output}" $'composer-test\ncomposer-dev\ncomposer-nopin'
}

@test "select_environments: an explicit unknown key exits 2 and lists the known keys" {
  OPT_ENVS=(composer-dev composer-nope)
  run --separate-stderr select_environments
  assert_status 2
  assert_contains "${stderr}" "environment 'composer-nope' is not defined in configs/hibernation-unit.yaml"
  assert_contains "${stderr}" "known: composer-bad, composer-dev, composer-nopin, composer-off, composer-prod, composer-test"
}

@test "select_environments: an explicit disabled key is selected (eligibility rejects it later)" {
  OPT_ENVS=(composer-off)
  run --separate-stderr select_environments
  assert_status 0
  assert_eq "${output}" "composer-off"
  run check_environment_eligible composer-off
  assert_status 1
}

@test "check_environment_eligible: valid, enabled, non-production environments pass" {
  check_environment_eligible composer-dev
  check_environment_eligible composer-test
  check_environment_eligible composer-nopin
}

@test "check_environment_eligible: validation errors -> 1" {
  run check_environment_eligible composer-bad
  assert_status 1
  assert_contains "${output}" "[composer-bad] invalid configuration: hibernation.snapshot_retention_count must be a whole number >= 1; hibernation.load_options.skip_everything is not a supported option"
}

@test "check_environment_eligible: disabled -> 1" {
  run check_environment_eligible composer-off
  assert_status 1
  assert_contains "${output}" "hibernation is not enabled for this environment"
  assert_contains "${output}" "configs/hibernation-unit.yaml"
  run check_environment_eligible composer-prod
  assert_status 1
}

@test "check_environment_eligible: production -> 1 even if enabled without validation errors" {
  jq '."composer-prod".hibernation.enabled = true | ."composer-prod".validation_errors = []' \
    "${UNIT}/resolved.json" >"${RESOLVED_JSON}"
  run check_environment_eligible composer-prod
  assert_status 1
  assert_contains "${output}" "refusing to hibernate a production environment"
}

@test "check_environment_eligible: unknown key -> 1" {
  run check_environment_eligible composer-nope
  assert_status 1
}

# ════════════════════════════════════════════════════════════════════════════
# Manifest (hibernation-state.json) helpers
# ════════════════════════════════════════════════════════════════════════════

@test "manifest_new: skeleton with the resolved identity" {
  run --separate-stderr manifest_new composer-nopin
  assert_status 0
  assert_eq "$(jq -c . <<<"${output}")" \
    '{"schema_version":1,"environment_key":"composer-nopin","environment_name":"composer-nopin","project_id":"other-project","region":"us-central1","status":"NONE","latest_snapshot":null,"snapshots":[],"history":[]}'
}

@test "manifest_fetch: existing object -> rc 0 and local copy" {
  t_gcs_put "${STATE_URL_DEV}" '{"schema_version":1,"status":"HIBERNATED","latest_snapshot":{"path":"gs://s/p/snap-1"}}'
  run manifest_fetch composer-dev
  assert_status 0
  assert_eq "$(manifest_get composer-dev .status)" "HIBERNATED"
  assert_eq "$(manifest_get composer-dev .latest_snapshot.path)" "gs://s/p/snap-1"
  assert_eq "$(t_calls "storage cat ${STATE_URL_DEV}")" 1
}

@test "manifest_fetch: missing object -> rc 3 + skeleton written, not retried" {
  run manifest_fetch composer-dev
  assert_status 3
  assert_eq "$(jq -r .status "$(manifest_local_path composer-dev)")" "NONE"
  assert_eq "$(jq -r .environment_key "$(manifest_local_path composer-dev)")" "composer-dev"
  assert_eq "$(jq -c .latest_snapshot "$(manifest_local_path composer-dev)")" "null"
  assert_eq "$(t_calls "storage cat")" 1 "not-found is not retried"
}

@test "manifest_fetch: invalid JSON or a non-object -> rc 1" {
  t_gcs_put "${STATE_URL_DEV}" 'this is {not json'
  run manifest_fetch composer-dev
  assert_status 1
  assert_contains "${output}" "is not valid JSON"
  t_gcs_put "${STATE_URL_DEV}" '[1, 2]'
  run manifest_fetch composer-dev
  assert_status 1
  t_gcs_put "${STATE_URL_DEV}" ''
  run manifest_fetch composer-dev
  assert_status 1
}

@test "manifest_fetch: permission denied is an error (not 'missing') and is retried" {
  t_reply storage-cat 1 "" "${DENIED_GCS}"
  run manifest_fetch composer-dev
  assert_status 1
  assert_eq "$(t_count storage-cat)" "${HIBERNATE_GCLOUD_RETRIES}"
  [[ ! -f "$(manifest_local_path composer-dev)" ]]
}

@test "manifest_get: false, objects, nulls" {
  printf '%s\n' '{"status":"ACTIVE","latest_snapshot":{"path":"gs://x","restore_incomplete":false},"orphaned_buckets":[]}' \
    >"$(manifest_local_path composer-dev)"
  assert_eq "$(manifest_get composer-dev .latest_snapshot.restore_incomplete)" "false"
  assert_eq "$(manifest_get composer-dev .latest_snapshot)" '{"path":"gs://x","restore_incomplete":false}'
  assert_eq "$(manifest_get composer-dev '.orphaned_buckets | length')" "0"
  assert_eq "$(manifest_get composer-dev .nothing)" ""
}

@test "manifest_transition: sets status, prepends bounded history, records CI context, pushes" {
  HIB_HISTORY_MAX=3
  export CI_PIPELINE_ID=4242 CI_JOB_URL=https://gitlab.example/job/1 CI_PIPELINE_SOURCE=schedule \
    GITLAB_USER_LOGIN=alice CI_COMMIT_SHORT_SHA=abc1234
  jq -n '{schema_version: 1, status: "SNAPSHOT_SAVED",
          history: [range(5) | {at: "2026-01-0\(. + 1)T00:00:00Z", status: "OLD\(.)", detail: "old", pipeline: {}}]}' \
    >"$(manifest_local_path composer-dev)"
  run manifest_transition composer-dev HIBERNATED "environment deleted"
  assert_status 0
  local m
  m="$(t_manifest composer-dev)"
  assert_eq "$(jq -r .status <<<"${m}")" "HIBERNATED"
  assert_eq "$(jq '.history | length' <<<"${m}")" 3 "bounded by HIB_HISTORY_MAX"
  assert_eq "$(jq -r '.history[0].status' <<<"${m}")" "HIBERNATED" "newest first"
  assert_eq "$(jq -r '.history[0].detail' <<<"${m}")" "environment deleted"
  assert_eq "$(jq -r '.history[1].status' <<<"${m}")" "OLD0"
  assert_eq "$(jq -r '.history[2].status' <<<"${m}")" "OLD1" "oldest entries dropped"
  assert_eq "$(jq -c '.history[0].pipeline' <<<"${m}")" \
    '{"pipeline_id":"4242","job_url":"https://gitlab.example/job/1","source":"schedule","user":"alice","commit":"abc1234"}'
  [[ "$(jq -r .updated_at <<<"${m}")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  assert_eq "$(jq -r .updated_at <<<"${m}")" "$(jq -r '.history[0].at' <<<"${m}")"
  # Pushed: the remote object is the local copy, uploaded as JSON.
  cmp "$(manifest_local_path composer-dev)" "$(t_gcs_path "${STATE_URL_DEV}")"
  assert_contains "$(cat "${STUB_DIR}/gcloud.calls")" "storage cp $(manifest_local_path composer-dev) ${STATE_URL_DEV} --content-type=application/json"
}

@test "manifest_transition: default HIB_HISTORY_MAX (50) keeps the newest 50 entries" {
  jq -n '{status: "ACTIVE", history: [range(50) | {status: "E\(.)"}]}' >"$(manifest_local_path composer-dev)"
  manifest_transition composer-dev SNAPSHOT_SAVED "snap" 2>/dev/null
  assert_eq "$(manifest_get composer-dev '.history | length')" 50
  assert_eq "$(manifest_get composer-dev '.history[0].status')" "SNAPSHOT_SAVED"
  assert_eq "$(manifest_get composer-dev '.history[49].status')" "E48"
  # Starting from a skeleton without history works too.
  manifest_new composer-test >"$(manifest_local_path composer-test)"
  manifest_transition composer-test RESTORING "start" 2>/dev/null
  assert_eq "$(manifest_get composer-test '.history | length')" 1
  assert_eq "$(manifest_get composer-test '.history[0].pipeline.source')" "manual"
}

@test "manifest_transition: dry-run updates the local copy but pushes nothing" {
  OPT_DRY_RUN=true
  manifest_new composer-dev >"$(manifest_local_path composer-dev)"
  run manifest_transition composer-dev HIBERNATED "dry"
  assert_status 0
  assert_contains "${output}" "(dry-run) would write ${STATE_URL_DEV}: status=HIBERNATED"
  assert_eq "$(manifest_get composer-dev .status)" "HIBERNATED"
  assert_eq "$(t_calls "storage cp")" 0
  [[ ! -e "$(t_gcs_path "${STATE_URL_DEV}")" ]]
}

@test "manifest_push: upload failure -> 1 after retries" {
  manifest_new composer-dev >"$(manifest_local_path composer-dev)"
  t_reply storage-cp 1 "" "ERROR: (gcloud.storage.cp) HTTPError 403: caller does not have storage.objects.create access"
  run manifest_transition composer-dev HIBERNATED "x"
  assert_status 1
  assert_contains "${output}" "could not write ${STATE_URL_DEV}"
  assert_eq "$(t_count storage-cp)" "${HIBERNATE_GCLOUD_RETRIES}"
}

# ════════════════════════════════════════════════════════════════════════════
# Snapshots
# ════════════════════════════════════════════════════════════════════════════

@test "snapshot_is_complete: true when the snapshot folder holds a *.sql.gz dump" {
  local snap="gs://snaps/composer-hibernation/p/r/composer-dev/composer-dev_2026-11-19T00-00-00"
  t_gcs_put "${snap}/airflow-database.postgres.sql.gz" "dump"
  t_gcs_put "${snap}/dags/dag.py" "x"
  snapshot_is_complete "${snap}"
  snapshot_is_complete "${snap}/"
  assert_contains "$(cat "${STUB_DIR}/gcloud.calls")" "storage ls ${snap}/*.sql.gz"
}

@test "snapshot_is_complete: false without a top-level dump or on listing errors" {
  local snap="gs://snaps/composer-hibernation/p/r/composer-dev/composer-dev_2026-11-19T00-00-00"
  t_gcs_put "${snap}/dags/dag.py" "x"
  t_gcs_put "${snap}/nested/airflow-database.sql.gz" "dump in the wrong place"
  run snapshot_is_complete "${snap}"
  assert_status 1
  run snapshot_is_complete "gs://snaps/does-not-exist"
  assert_status 1
  t_gcs_put "${snap}/airflow-database.sql.gz" "dump"
  t_reply storage-ls 1 "" "ERROR: (gcloud.storage.ls) HTTPError 403: denied"
  run snapshot_is_complete "${snap}"
  assert_status 1
}

SAVE_OP='{"name": "projects/hib-test-project/locations/europe-west2/operations/op-save-1", "done": false}'
SAVE_DONE='{"name": "projects/hib-test-project/locations/europe-west2/operations/op-save-1", "done": true, "response": {"@type": "type.googleapis.com/google.cloud.orchestration.airflow.service.v1.SaveSnapshotResponse", "snapshotPath": "gs://snaps/prefix/composer-dev/composer-dev_2026-11-19T01-02-03/"}}'

@test "composer_snapshot_save: snapshot path comes from the operation response" {
  t_reply save 0 "${SAVE_OP}"
  t_reply operation 0 "${SAVE_DONE}"
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 0
  assert_eq "${output}" "gs://snaps/prefix/composer-dev/composer-dev_2026-11-19T01-02-03" "trailing slash stripped"
  assert_eq "$(t_calls "composer environments snapshots save composer-dev --location=europe-west2 --project=hib-test-project --snapshot-location=gs://snaps/prefix/composer-dev --async --format=json")" 1
  assert_eq "$(t_calls "composer operations describe op-save-1 --location=europe-west2 --project=hib-test-project --format=json")" 1
}

@test "composer_snapshot_save: polls the operation until done" {
  t_reply save 0 "${SAVE_OP}"
  t_reply operation.1 0 "${SAVE_OP}"
  t_reply operation.2 0 "${SAVE_OP}"
  t_reply operation 0 "${SAVE_DONE}"
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 0
  assert_eq "$(t_count operation)" 3
}

@test "composer_snapshot_save: no snapshotPath in the response -> failure, never guessed" {
  t_reply save 0 "${SAVE_OP}"
  t_reply operation 0 '{"name": "op-save-1", "done": true, "response": {"@type": "type.googleapis.com/google.cloud.orchestration.airflow.service.v1.SaveSnapshotResponse"}}'
  t_gcs_put "gs://snaps/prefix/composer-dev/composer-dev_2026-11-19T01-02-03/airflow-database.sql.gz" "dump"
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 1
  assert_eq "${output}" "" "no path printed"
  assert_contains "${stderr}" "finished without a snapshotPath"
  assert_eq "$(t_calls "storage")" 0 "the snapshot location is not listed to guess a folder"
  # A non-gs:// value is not accepted either.
  t_reply operation 0 '{"name": "op-save-1", "done": true, "response": {"snapshotPath": "composer-dev_2026"}}'
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 1
  assert_eq "${output}" ""
}

@test "composer_snapshot_save: FAILED_PRECONDITION on the first request waits for RUNNING and retries once" {
  t_reply save.1 1 "" "ERROR: (gcloud.composer.environments.snapshots.save) FAILED_PRECONDITION: Cannot perform the operation: another operation is in progress."
  t_reply save 0 "${SAVE_OP}"
  t_describe describe.1 UPDATING
  t_describe describe RUNNING
  t_reply operation 0 "${SAVE_DONE}"
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 0
  assert_eq "${output}" "gs://snaps/prefix/composer-dev/composer-dev_2026-11-19T01-02-03"
  assert_eq "$(t_count save)" 2
  assert_eq "$(t_count describe)" 2 "waited until RUNNING"
}

@test "composer_snapshot_save: a second FAILED_PRECONDITION fails (only one retry)" {
  t_reply save 1 "" "ERROR: (gcloud.composer.environments.snapshots.save) FAILED_PRECONDITION: Environment is in state UPDATING."
  t_describe describe RUNNING
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 1
  assert_eq "$(t_count save)" 2
  assert_eq "$(t_count operation)" 0
}

@test "composer_snapshot_save: no retry when the environment never settles" {
  t_reply save 1 "" "ERROR: (gcloud.composer.environments.snapshots.save) FAILED_PRECONDITION: Environment is in state UPDATING."
  t_describe describe ERROR
  HIBERNATE_WAIT_TIMEOUT_MINUTES=0
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 1
  assert_eq "$(t_count save)" 1
}

@test "composer_snapshot_save: other rejections fail immediately" {
  t_reply save 1 "" "ERROR: (gcloud.composer.environments.snapshots.save) PERMISSION_DENIED: Permission 'composer.environments.executeAirflowCommand' denied"
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 1
  assert_contains "${stderr}" "snapshots save request for composer-dev was rejected"
  assert_eq "$(t_count save)" 1
  assert_eq "$(t_count describe)" 0
}

@test "composer_snapshot_save: an operation error fails" {
  t_reply save 0 "${SAVE_OP}"
  t_reply operation 0 '{"name": "op-save-1", "done": true, "error": {"code": 13, "message": "Snapshot creation failed: internal error"}}'
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 1
  assert_eq "${output}" ""
  assert_contains "${stderr}" "Snapshot creation failed: internal error"
}

@test "composer_snapshot_save: a response without an operation name fails" {
  t_reply save 0 '{}'
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/prefix/composer-dev
  assert_status 1
  assert_contains "${stderr}" "returned no operation name"
  assert_eq "$(t_count operation)" 0
}

LOAD_OP='{"name": "projects/hib-test-project/locations/europe-west2/operations/op-load-1", "done": false}'
LOAD_DONE='{"name": "projects/hib-test-project/locations/europe-west2/operations/op-load-1", "done": true, "response": {}}'

@test "composer_snapshot_load: default load options map to the skip flags" {
  t_reply load 0 "${LOAD_OP}"
  t_reply operation 0 "${LOAD_DONE}"
  run --separate-stderr composer_snapshot_load composer-dev europe-west2 hib-test-project gs://snaps/p/snap-1 \
    "$(setting composer-dev .hibernation.load_options)"
  assert_status 0
  local call
  call="$(grep 'snapshots load' "${STUB_DIR}/gcloud.calls")"
  assert_contains "${call}" "composer environments snapshots load composer-dev --location=europe-west2 --project=hib-test-project --snapshot-path=gs://snaps/p/snap-1 --async --format=json"
  assert_contains "${call}" "--skip-pypi-packages-installation"
  assert_contains "${call}" "--skip-environment-variables-setting"
  assert_contains "${call}" "--skip-airflow-overrides-setting"
  assert_not_contains "${call}" "--skip-gcs-data-copying"
  assert_eq "$(t_calls "composer operations describe op-load-1")" 1
}

@test "composer_snapshot_load: per-environment and all-false load options" {
  t_reply load 0 "${LOAD_OP}"
  t_reply operation 0 "${LOAD_DONE}"
  composer_snapshot_load composer-nopin us-central1 other-project gs://snaps/p/snap-1 \
    "$(setting composer-nopin .hibernation.load_options)" 2>/dev/null
  local call
  call="$(grep 'snapshots load' "${STUB_DIR}/gcloud.calls")"
  assert_not_contains "${call}" "--skip-pypi-packages-installation"
  assert_contains "${call}" "--skip-environment-variables-setting"
  assert_contains "${call}" "--skip-airflow-overrides-setting"
  assert_contains "${call}" "--skip-gcs-data-copying"

  : >"${STUB_DIR}/gcloud.calls"
  composer_snapshot_load composer-dev europe-west2 hib-test-project gs://snaps/p/snap-1 \
    '{"skip_pypi_packages_installation":false,"skip_environment_variables_setting":false,"skip_airflow_overrides_setting":false,"skip_gcs_data_copying":false}' 2>/dev/null
  assert_not_contains "$(grep 'snapshots load' "${STUB_DIR}/gcloud.calls")" "--skip-"
}

@test "composer_snapshot_load: retries HIBERNATE_LOAD_ATTEMPTS times, waiting in between" {
  HIBERNATE_LOAD_ATTEMPTS=3
  t_reply load 1 "" "ERROR: (gcloud.composer.environments.snapshots.load) INTERNAL: load failed"
  t_describe describe RUNNING
  run --separate-stderr composer_snapshot_load composer-dev europe-west2 hib-test-project gs://snaps/p/snap-1 \
    "$(setting composer-dev .hibernation.load_options)"
  assert_status 1
  assert_eq "$(t_count load)" 3
  assert_eq "$(t_count describe)" 2 "waits between attempts, not after the last"
  assert_contains "${stderr}" "failed after 3 attempt(s)"
}

@test "composer_snapshot_load: a later attempt can succeed (request or operation failure)" {
  t_reply load.1 1 "" "ERROR: (gcloud.composer.environments.snapshots.load) UNAVAILABLE"
  t_reply load 0 "${LOAD_OP}"
  t_describe describe RUNNING
  t_reply operation 0 "${LOAD_DONE}"
  run --separate-stderr composer_snapshot_load composer-dev europe-west2 hib-test-project gs://snaps/p/snap-1 '{}'
  assert_status 0
  assert_eq "$(t_count load)" 2

  rm -rf "${STUB_DIR}/replies" "${STUB_DIR}"/*.count
  t_reply load 0 "${LOAD_OP}"
  t_reply operation.1 0 '{"name": "op-load-1", "done": true, "error": {"code": 9, "message": "partial load"}}'
  t_reply operation 0 "${LOAD_DONE}"
  t_describe describe RUNNING
  run --separate-stderr composer_snapshot_load composer-dev europe-west2 hib-test-project gs://snaps/p/snap-1 '{}'
  assert_status 0
  assert_eq "$(t_count load)" 2
}

@test "composer_snapshot_load: HIBERNATE_LOAD_ATTEMPTS=1 means a single attempt" {
  HIBERNATE_LOAD_ATTEMPTS=1
  t_reply load 1 "" "ERROR: (gcloud.composer.environments.snapshots.load) INTERNAL"
  run --separate-stderr composer_snapshot_load composer-dev europe-west2 hib-test-project gs://snaps/p/snap-1 '{}'
  assert_status 1
  assert_eq "$(t_count load)" 1
  assert_eq "$(t_count describe)" 0
}

# ════════════════════════════════════════════════════════════════════════════
# gcloud wrappers: not-found vs. errors
# ════════════════════════════════════════════════════════════════════════════

@test "composer_describe / composer_state: NOT_FOUND, state, STATE_UNSPECIFIED" {
  t_reply describe 1 "" "${NF_DESCRIBE}"
  run composer_describe composer-dev europe-west2 hib-test-project
  assert_status 3
  run --separate-stderr composer_state composer-dev europe-west2 hib-test-project
  assert_status 0
  assert_eq "${output}" "NOT_FOUND"
  assert_eq "$(t_count describe)" 2 "not-found is not retried"
  t_describe describe RUNNING
  assert_eq "$(composer_state composer-dev europe-west2 hib-test-project)" "RUNNING"
  t_reply describe 0 '{"name": "projects/p/locations/r/environments/composer-dev"}'
  assert_eq "$(composer_state composer-dev europe-west2 hib-test-project)" "STATE_UNSPECIFIED"
}

@test "composer_state: PERMISSION_DENIED is an error, never NOT_FOUND, and is retried" {
  t_reply describe 1 "" "${DENIED_DESCRIBE}"
  run --separate-stderr composer_state composer-dev europe-west2 hib-test-project
  [[ "${status}" -ne 0 && "${status}" -ne 3 ]]
  assert_eq "${output}" ""
  assert_contains "${stderr}" "PERMISSION_DENIED"
  assert_eq "$(t_count describe)" "${HIBERNATE_GCLOUD_RETRIES}"
}

@test "wait_for_composer_state: polls until a target state, times out with 1" {
  t_describe describe.1 CREATING
  t_describe describe.2 UPDATING
  t_describe describe RUNNING
  run --separate-stderr wait_for_composer_state composer-dev europe-west2 hib-test-project RUNNING,ERROR
  assert_status 0
  assert_eq "${output}" "RUNNING"
  assert_eq "$(t_count describe)" 3

  t_reply describe 1 "" "${NF_DESCRIBE}"
  run --separate-stderr wait_for_composer_state composer-dev europe-west2 hib-test-project NOT_FOUND,ERROR
  assert_status 0
  assert_eq "${output}" "NOT_FOUND"

  t_describe describe CREATING
  run --separate-stderr wait_for_composer_state composer-dev europe-west2 hib-test-project RUNNING 0
  assert_status 1
  assert_eq "${output}" "CREATING"
  assert_contains "${stderr}" "timed out after 0m waiting for composer-dev to reach RUNNING (still CREATING)"

  t_reply describe 1 "" "${DENIED_DESCRIBE}"
  run --separate-stderr wait_for_composer_state composer-dev europe-west2 hib-test-project RUNNING
  assert_status 1
}

@test "wait_for_operation: times out with 1 while the operation is still running" {
  HIBERNATE_OPERATION_TIMEOUT_MINUTES=0
  t_reply operation 0 "${SAVE_OP}"
  run --separate-stderr wait_for_operation projects/p/locations/r/operations/op-9 europe-west2 hib-test-project "unit op"
  assert_status 1
  assert_contains "${stderr}" "unit op did not finish within 0m"
  assert_eq "$(t_calls "composer operations describe op-9 --location=europe-west2")" 1
}

@test "settle_environment_state: waits out CREATING/DELETING, records describe output" {
  t_describe describe.1 CREATING
  t_describe describe.2 RUNNING
  t_describe describe RUNNING
  run --separate-stderr settle_environment_state composer-dev
  assert_status 0
  assert_eq "${output}" "RUNNING"
  assert_eq "$(describe_get composer-dev .config.softwareConfig.imageVersion)" "composer-3-airflow-2.10.5-build.17"
  assert_eq "$(describe_get composer-dev .state)" "RUNNING"

  rm -rf "${STUB_DIR}/replies" "${STUB_DIR}"/*.count "${OPT_WORK_DIR}/state/composer-dev-describe.json"
  t_describe describe.1 DELETING
  t_reply describe 1 "" "${NF_DESCRIBE}"
  run --separate-stderr settle_environment_state composer-dev
  assert_status 0
  assert_eq "${output}" "NOT_FOUND"
  [[ ! -f "${OPT_WORK_DIR}/state/composer-dev-describe.json" ]]
  run describe_get composer-dev .state
  assert_status 0
  assert_eq "${output}" ""
}

@test "gcs_read / bucket_exists / gcs_list_prefixes: not-found vs. permission errors" {
  t_gcs_put gs://b/p/state.json '{"a":1}'
  t_gcs_put gs://b/p/snap-1/x.sql.gz 'x'
  t_gcs_put gs://b/p/snap-2/x.sql.gz 'x'
  assert_eq "$(gcs_read gs://b/p/state.json)" '{"a":1}'
  run gcs_read gs://b/p/missing.json
  assert_status 3
  assert_eq "$(gcs_list_prefixes gs://b/p/)" $'gs://b/p/snap-1/\ngs://b/p/snap-2/' "folders only"
  run gcs_list_prefixes gs://b/nothing-here/
  assert_status 0
  assert_eq "${output}" ""
  bucket_exists b
  run bucket_exists no-such-bucket
  assert_status 3

  t_reply storage-cat 1 "" "${DENIED_GCS}"
  run --separate-stderr gcs_read gs://b/p/state.json
  assert_status 1
  assert_contains "${stderr}" "HTTPError 403"
  t_reply storage-describe 1 "" "ERROR: (gcloud.storage.buckets.describe) HTTPError 403: caller does not have storage.buckets.get access"
  run bucket_exists b
  assert_status 1
  t_reply storage-ls 1 "" "ERROR: (gcloud.storage.ls) HTTPError 403: caller does not have storage.objects.list access"
  run gcs_list_prefixes gs://b/p/
  assert_status 1
}

@test "ensure_snapshot_bucket: creates only when allowed, then grants the service account" {
  local sa=composer-dev-sa@hib-test-project.iam.gserviceaccount.com
  t_reply iam 0 ""
  run ensure_snapshot_bucket composer-dev "${sa}" no-create
  assert_status 1
  assert_contains "${output}" "snapshot bucket gs://hib-test-project-composer-snapshots does not exist"
  run ensure_snapshot_bucket composer-nopin composer-nopin-sa@other-project.iam.gserviceaccount.com
  assert_status 1
  assert_contains "${output}" "create_snapshot_bucket is false"
  assert_eq "$(t_calls "storage buckets create")" 0

  run ensure_snapshot_bucket composer-dev "${sa}"
  assert_status 0
  assert_eq "$(t_calls "storage buckets create gs://hib-test-project-composer-snapshots --project=hib-test-project --location=europe-west2 --uniform-bucket-level-access --public-access-prevention")" 1
  assert_eq "$(t_calls "storage buckets add-iam-policy-binding gs://hib-test-project-composer-snapshots --member=serviceAccount:${sa} --role=roles/storage.objectAdmin")" 1

  # Existing bucket: no create, grant again; no service account: no grant.
  run ensure_snapshot_bucket composer-dev "${sa}"
  assert_status 0
  assert_eq "$(t_calls "storage buckets create")" 1
  assert_eq "$(t_calls "add-iam-policy-binding")" 2
  run ensure_snapshot_bucket composer-dev ""
  assert_status 0
  assert_eq "$(t_calls "add-iam-policy-binding")" 2
}

# ════════════════════════════════════════════════════════════════════════════
# Terraform helpers
# ════════════════════════════════════════════════════════════════════════════

@test "tf_init: --skip-init does not run terraform" {
  OPT_SKIP_INIT=true
  run tf_init
  assert_status 0
  assert_eq "$(cat "${STUB_DIR}/terraform.calls")" ""
}

@test "tf_init: without TF_BACKEND_BUCKET no backend config, no override, no backend assertion" {
  printf 'terraform {\n  required_version = ">= 1.6"\n}\n' >"${TF_ROOT}/main.tf"
  export STUB_TF_BACKEND=none
  run tf_init
  assert_status 0
  assert_eq "$(cat "${STUB_DIR}/terraform.calls")" "-chdir=${TF_ROOT} init -input=false -no-color -reconfigure"
  [[ ! -e "${TF_ROOT}/backend_override.tf" ]]
}

@test "tf_init: TF_BACKEND_BUCKET with a gcs backend passes; override generated when no backend block" {
  printf 'terraform {\n  required_version = ">= 1.6"\n}\n' >"${TF_ROOT}/main.tf"
  export TF_BACKEND_BUCKET=my-tf-state TF_BACKEND_PREFIX=composer/state STUB_TF_BACKEND=gcs
  run tf_init
  assert_status 0
  assert_eq "$(cat "${STUB_DIR}/terraform.calls")" \
    "-chdir=${TF_ROOT} init -input=false -no-color -reconfigure -backend-config=bucket=my-tf-state -backend-config=prefix=composer/state"
  assert_contains "$(cat "${TF_ROOT}/backend_override.tf")" 'backend "gcs" {}'
}

@test "tf_init: no backend_override.tf when the root declares a backend" {
  printf 'terraform {\n  required_version = ">= 1.6"\n\n  backend "gcs" {}\n}\n' >"${TF_ROOT}/versions.tf"
  printf '# backend "local" (comment only)\n' >"${TF_ROOT}/main.tf"
  export TF_BACKEND_BUCKET=my-tf-state STUB_TF_BACKEND=gcs
  run tf_init
  assert_status 0
  [[ ! -e "${TF_ROOT}/backend_override.tf" ]]
  assert_not_contains "$(cat "${STUB_DIR}/terraform.calls")" "prefix="
}

@test "tf_init: TF_BACKEND_BUCKET but terraform initialised the local backend -> die (exit 2)" {
  printf 'terraform {\n  backend "local" {}\n}\n' >"${TF_ROOT}/main.tf"
  export TF_BACKEND_BUCKET=my-tf-state STUB_TF_BACKEND=local
  run tf_init
  assert_status 2
  assert_contains "${output}" "terraform initialised the 'local' backend, expected gcs (TF_BACKEND_BUCKET is set)"
}

@test "tf_init: TF_BACKEND_BUCKET but no backend recorded at all -> die (exit 2)" {
  printf 'terraform {}\n' >"${TF_ROOT}/main.tf"
  export TF_BACKEND_BUCKET=my-tf-state STUB_TF_BACKEND=none
  run tf_init
  assert_status 2
  assert_contains "${output}" "expected gcs"
}

@test "tf_init: honours an absolute or relative TF_DATA_DIR" {
  printf 'terraform {}\n' >"${TF_ROOT}/main.tf"
  export TF_BACKEND_BUCKET=my-tf-state STUB_TF_BACKEND=gcs TF_DATA_DIR="${BATS_TEST_TMPDIR}/tfdata"
  run tf_init
  assert_status 0
  [[ -f "${BATS_TEST_TMPDIR}/tfdata/terraform.tfstate" && ! -e "${TF_ROOT}/.terraform" ]]
  # A gcs record elsewhere does not satisfy a local backend in TF_DATA_DIR.
  export STUB_TF_BACKEND=local
  run tf_init
  assert_status 2
  export TF_DATA_DIR=reldata STUB_TF_BACKEND=gcs
  run tf_init
  assert_status 0
  [[ -f "${TF_ROOT}/reldata/terraform.tfstate" ]]
}

@test "tf_init: a failing terraform init dies (exit 2)" {
  printf 'terraform {}\n' >"${TF_ROOT}/main.tf"
  export STUB_TF_INIT_RC=1
  run tf_init
  assert_status 2
  assert_contains "${output}" "terraform init failed"
}

@test "tf_resource_in_state / tf_module_in_state: exact addresses, no lookalikes" {
  printf '%s\n' \
    'module.composer["composer-dev2"].google_composer_environment.this' \
    'module.composer["composer-test"].google_compute_network.composer[0]' \
    'module.composer["composer-test"].google_composer_environment.this_old' >"${STUB_DIR}/state-list"
  tf_state_load 2>/dev/null
  run tf_resource_in_state composer-dev
  assert_status 1
  run tf_module_in_state composer-dev
  assert_status 1
  run tf_module_in_state composer-test
  assert_status 0
  run tf_resource_in_state composer-test
  assert_status 1
  printf '%s\n' "${DEV_ENV}" >>"${STUB_DIR}/state-list"
  tf_state_load 2>/dev/null
  run tf_resource_in_state composer-dev
  assert_status 0
  run tf_module_in_state composer-dev
  assert_status 0
  assert_eq "$(grep -c 'state list' "${STUB_DIR}/terraform.calls")" 2 "one state list per load, none per lookup"
}

@test "tf_state_load: an empty state is loaded (nothing is in state)" {
  : >"${STUB_DIR}/state-list"
  run tf_state_load
  assert_status 0
  assert_contains "${output}" "terraform state holds 0 resource(s)"
  tf_state_load 2>/dev/null
  run tf_resource_in_state composer-dev
  assert_status 1
  run tf_module_in_state composer-dev
  assert_status 1
}

@test "tf_state_load: a failing state list dies (exit 2); lookups refuse to run before a load" {
  export STUB_TF_STATE_RC=1
  printf '%s\n' "${DEV_ENV}" >"${STUB_DIR}/state-list"
  run tf_state_load
  assert_status 2
  assert_contains "${output}" "Error acquiring the state lock"
  assert_contains "${output}" "terraform state list failed"
  run tf_resource_in_state composer-dev
  assert_status 2
  assert_contains "${output}" "internal: tf_state_load not called"
  run tf_module_in_state composer-dev
  assert_status 2
}

@test "tf_resource_in_state / tf_module_in_state: large state (>64 KiB) under pipefail" {
  # 200 environments x 16 resources (~300 KiB), the environment checked comes
  # first, as in `terraform state list` output (sorted).
  local res=(
    google_composer_environment.this
    'google_compute_firewall.composer_health_checks[0]'
    'google_compute_firewall.composer_internal[0]'
    'google_compute_network.composer[0]'
    'google_compute_subnetwork.composer[0]'
    google_project_iam_member.composer_agent_v2ext
    'google_project_iam_member.composer_sa_roles["roles/composer.worker"]'
    'google_project_iam_member.composer_sa_roles["roles/logging.logWriter"]'
    'google_project_iam_member.composer_sa_roles["roles/monitoring.metricWriter"]'
    'google_project_service.required["cloudresourcemanager.googleapis.com"]'
    'google_project_service.required["composer.googleapis.com"]'
    'google_project_service.required["compute.googleapis.com"]'
    'google_project_service.required["iam.googleapis.com"]'
    'google_project_service.required["serviceusage.googleapis.com"]'
    'google_service_account.composer[0]'
    google_service_account_iam_member.composer_agent_sa_user
  )
  local i r
  {
    for r in "${res[@]}"; do printf 'module.composer["composer-dev"].%s\n' "${r}"; done
    for ((i = 1; i <= 200; i++)); do
      for r in "${res[@]}"; do printf 'module.composer["composer-env-%03d"].%s\n' "${i}" "${r}"; done
    done
  } >"${STUB_DIR}/state-list"
  (($(wc -c <"${STUB_DIR}/state-list") > 131072))
  [[ -o pipefail ]] # like the scripts (set -Eeuo pipefail)
  tf_state_load 2>/dev/null
  assert_eq "$(grep -c . <<<"${TF_STATE_LIST}")" 3216
  run tf_resource_in_state composer-dev
  assert_eq "${status}" 0 "tf_resource_in_state must find ${DEV_ENV} (grep -q exits early; the writer gets SIGPIPE)"
  run tf_module_in_state composer-dev
  assert_eq "${status}" 0 "tf_module_in_state must find ${DEV_PREFIX}"
}

# ════════════════════════════════════════════════════════════════════════════
# Results bookkeeping
# ════════════════════════════════════════════════════════════════════════════

@test "result_set / result_status / finish_summary: summary and exit code" {
  result_set composer-dev ok "hibernated" 2>/dev/null
  assert_eq "$(result_status composer-dev)" "ok"
  assert_eq "$(result_status composer-test)" "pending"
  result_set composer-test skipped "already hibernated" 2>/dev/null
  run finish_summary shutdown composer-dev composer-test
  assert_status 0
  assert_eq "$(jq -c '[.mode, .dry_run, (.environments | length)]' "${OPT_WORK_DIR}/summary.json")" '["shutdown",false,2]'

  OPT_DRY_RUN=true
  run finish_summary shutdown composer-dev composer-test composer-nopin
  assert_status 1
  assert_eq "$(result_status composer-nopin)" "failed"
  assert_contains "$(jq -r .message "${OPT_WORK_DIR}/results/composer-nopin.json")" "no result recorded"
  assert_eq "$(jq -c '[.dry_run, (.environments | map(.status))]' "${OPT_WORK_DIR}/summary.json")" '[true,["ok","failed","skipped"]]'

  rm -f "${OPT_WORK_DIR}"/results/*.json
  run finish_summary startup
  assert_status 0
  assert_eq "$(jq -c .environments "${OPT_WORK_DIR}/summary.json")" '[]'
}

@test "run_parallel: a sub-shell that neither records a result nor a phase marker is failed" {
  worker() {
    case "$1" in
    composer-dev) result_set composer-dev ok "done" ;;
    composer-test)
      echo "composer-test log line"
      phase_ok composer-test snapshot
      ;;
    *)
      echo "about to die"
      exit 1
      ;;
    esac
  }
  HIBERNATE_MAX_PARALLEL=2
  run run_parallel snapshot worker composer-dev composer-test composer-nopin
  assert_status 0
  assert_eq "$(result_status composer-dev)" "ok"
  assert_eq "$(result_status composer-test)" "pending"
  phase_done composer-test snapshot
  assert_eq "$(result_status composer-nopin)" "failed"
  assert_contains "$(jq -r .message "${OPT_WORK_DIR}/results/composer-nopin.json")" "snapshot step aborted unexpectedly"
  assert_contains "$(cat "${OPT_WORK_DIR}/logs/composer-test-snapshot.log")" "composer-test log line"
  assert_contains "${output}" "==== snapshot: composer-nopin ===="
  assert_contains "${output}" "about to die"
}

# ════════════════════════════════════════════════════════════════════════════
# Review hardening: restore-point decisions, identity, work dir, GCS/IAM
# ════════════════════════════════════════════════════════════════════════════

@test "decide_startup_action: RUNNING with re-created / stale / already-restored environments" {
  local st snap rec fresh done want got failures=() n=0
  while read -r st snap rec fresh done want; do
    [[ -n "${st}" && "${st}" != \#* ]] || continue
    n=$((n + 1))
    got="$(decide_startup_action RUNNING "${st}" "${snap}" "${rec}" "${fresh}" "${done}")"
    [[ "${got}" == "${want}" ]] || failures+=("RUNNING ${st} snap=${snap} recreated=${rec} fresh=${fresh} done=${done}: got '${got}', want '${want}'")
  done <<'TABLE'
# STATUS        SNAP  RECREATED FRESH DONE  EXPECTED
  HIBERNATED     true  false     true  false load
  HIBERNATED     true  false     false false refuse_stale
  HIBERNATED     true  true      false false refuse_stale
  HIBERNATED     false false     false false mark_active
  HIBERNATED     true  false     true  true  load
  RESTORING      true  false     true  false load
  RESTORING      true  false     false false refuse_stale
  RESTORING      true  false     true  true  mark_restored
  RESTORING      true  false     false true  mark_restored
  RESTORING      false false     true  true  mark_active
  SNAPSHOT_SAVED true  false     true  false mark_active
  SNAPSHOT_SAVED true  false     false false mark_active
  SNAPSHOT_SAVED true  true      true  false load
  SNAPSHOT_SAVED true  true      false false refuse_stale
  SNAPSHOT_SAVED false true      true  false mark_active
  ACTIVE         true  true      false false noop
  NONE           true  true      true  false noop
TABLE
  assert_eq "${n}" 17 "rows"
  if ((${#failures[@]})); then
    printf '%s\n' "${failures[@]}" >&2
    return 1
  fi
  # The 3-argument form keeps the original behaviour.
  assert_eq "$(decide_startup_action RUNNING SNAPSHOT_SAVED true)" mark_active
  assert_eq "$(decide_startup_action RUNNING HIBERNATED true)" load
}

@test "decide_restore_point: full table" {
  local st rec fresh done latest want got failures=() n=0
  while read -r st rec fresh done latest want; do
    [[ -n "${st}" && "${st}" != \#* ]] || continue
    n=$((n + 1))
    got="$(decide_restore_point "${st}" "${rec}" "${fresh}" "${done}" "${latest}")"
    [[ "${got}" == "${want}" ]] || failures+=("${st} recreated=${rec} fresh=${fresh} done=${done} latest=${latest}: got '${got}', want '${want}'")
  done <<'TABLE'
# STATUS        RECREATED FRESH DONE  LATEST EXPECTED
  NONE           false     true  false false  replace
  NONE           true      true  false true   replace
  ACTIVE         false     true  false true   replace
  ACTIVE         true      false false true   replace
  SNAPSHOT_SAVED false     true  false true   replace
  SNAPSHOT_SAVED true      true  false true   keep
  SNAPSHOT_SAVED true      false false true   replace_stale
  HIBERNATED     false     true  false true   keep
  HIBERNATED     false     false false true   replace_stale
  HIBERNATED     false     true  false false  replace
  RESTORING      false     true  false true   keep
  RESTORING      false     false false true   replace_stale
  RESTORING      false     true  true  true   replace
  RESTORING      false     false true  true   replace
TABLE
  assert_eq "${n}" 14 "rows"
  if ((${#failures[@]})); then
    printf '%s\n' "${failures[@]}" >&2
    return 1
  fi
}

@test "env_is_fresh / env_recreated_since_snapshot read the describe output and the newest snapshot" {
  local f="${OPT_WORK_DIR}/state/composer-dev-describe.json"
  manifest_new composer-dev >"$(manifest_local_path composer-dev)"
  jq -n --arg t "$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%S.123456Z)" '{uuid: "u-2", createTime: $t}' >"${f}"
  env_is_fresh composer-dev
  HIBERNATE_FRESH_ENV_HOURS=1
  ! env_is_fresh composer-dev
  jq '.createTime = "not-a-date"' "${f}" >"${f}.t" && mv "${f}.t" "${f}"
  env_is_fresh composer-dev # unknown creation time counts as fresh

  ! env_recreated_since_snapshot composer-dev # no snapshot uuid recorded
  manifest_update composer-dev '.snapshots = [{path: "gs://b/s1", environment_uuid: "u-1"}]'
  env_recreated_since_snapshot composer-dev
  manifest_update composer-dev '.snapshots[0].environment_uuid = "u-2"'
  ! env_recreated_since_snapshot composer-dev
}

@test "restore_attempt_state: SUCCEEDED / FAILED / RUNNING only for the described environment and restore point" {
  manifest_new composer-dev >"$(manifest_local_path composer-dev)"
  echo '{"uuid": "u-1"}' >"${OPT_WORK_DIR}/state/composer-dev-describe.json"
  assert_eq "$(restore_attempt_state composer-dev)" NONE "nothing recorded"
  manifest_update composer-dev '.latest_snapshot = {path: "gs://b/s1"}
    | .restore_attempt = {operation: "projects/p/locations/r/operations/op-load-1", snapshot: "gs://b/s1", environment_uuid: "u-1"}'
  t_reply operation.1 0 '{"name": "op-load-1", "done": true, "response": {}}'
  t_reply operation.2 0 '{"name": "op-load-1", "done": true, "error": {"code": 13, "message": "boom"}}'
  t_reply operation.3 0 '{"name": "op-load-1", "done": false}'
  assert_eq "$(restore_attempt_state composer-dev)" SUCCEEDED
  assert_eq "$(restore_attempt_state composer-dev)" FAILED
  assert_eq "$(restore_attempt_state composer-dev)" RUNNING
  assert_eq "$(t_calls "composer operations describe op-load-1 --location=europe-west2 --project=hib-test-project")" 3
  echo '{"uuid": "u-other"}' >"${OPT_WORK_DIR}/state/composer-dev-describe.json"
  assert_eq "$(restore_attempt_state composer-dev)" NONE "re-created environment"
  echo '{"uuid": "u-1"}' >"${OPT_WORK_DIR}/state/composer-dev-describe.json"
  manifest_update composer-dev '.latest_snapshot.path = "gs://b/s2"'
  assert_eq "$(restore_attempt_state composer-dev)" NONE "a newer restore point"
  assert_eq "$(t_count operation)" 3 "no API call when it cannot apply"
}

@test "init_work_dir: refuses a directory holding an earlier run's bookkeeping" {
  local d="${BATS_TEST_TMPDIR}/reused" sub
  mkdir -p "${d}/logs"
  echo old >"${d}/logs/x.log"
  OPT_WORK_DIR="${d}"
  init_work_dir shutdown 2>/dev/null # logs only: fine
  for sub in actions state results plans; do
    rm -rf "${d}"
    mkdir -p "${d}/${sub}"
    touch "${d}/${sub}/composer-dev.marker"
    OPT_WORK_DIR="${d}"
    run init_work_dir shutdown
    assert_status 2
    assert_contains "${output}" "already holds the files of an earlier run (${sub}/)"
  done
}

@test "check_environment_eligible: two keys resolving to the same environment both fail" {
  jq '."composer-test".environment_name = "composer-dev" | ."composer-test".project_id = "hib-test-project"
      | ."composer-test".region = "europe-west2"' "${UNIT}/resolved.json" >"${RESOLVED_JSON}"
  run check_environment_eligible composer-dev
  assert_status 1
  assert_contains "${output}" "environment composer-dev in hib-test-project/europe-west2 is also defined by: composer-test"
  run check_environment_eligible composer-test
  assert_status 1
  assert_contains "${output}" "also defined by: composer-dev"
}

@test "plan_deletes_identity: the deleted object must be the expected environment" {
  local plan="${BATS_TEST_TMPDIR}/identity.json"
  jq -n --arg a "${DEV_ENV}" '{resource_changes: [{address: $a, change: {actions: ["delete"],
    before: {project: "hib-test-project", region: "europe-west2", name: "composer-dev"}}}]}' >"${plan}"
  run plan_deletes_identity "${plan}" "${DEV_ENV}" hib-test-project/europe-west2/composer-dev
  assert_status 0
  run plan_deletes_identity "${plan}" "${DEV_ENV}" hib-test-project/europe-west2/composer-qa
  assert_status 1
  assert_contains "${output}" "would remove hib-test-project/europe-west2/composer-dev, expected hib-test-project/europe-west2/composer-qa"
  run plan_deletes_identity "${plan}" "${TEST_ENV}" hib-test-project/europe-west2/composer-test
  assert_status 1
  assert_contains "${output}" "would remove <nothing>"
}

@test "gcs_delete_prefix: 0 deleted, 3 already gone, other failures pass stderr through" {
  t_reply storage-rm.1 0 ""
  run gcs_delete_prefix gs://b/snap/
  assert_status 0
  assert_eq "$(t_calls "storage rm --recursive gs://b/snap/ --quiet")" 1
  t_reply storage-rm.2 1 "" "ERROR: (gcloud.storage.rm) The following URLs matched no objects or files:
-gs://b/snap/"
  run --separate-stderr gcs_delete_prefix gs://b/snap
  assert_status 3
  assert_eq "${stderr}" ""
  t_reply storage-rm.3 1 "" "ERROR: (gcloud.storage.rm) HTTPError 403: denied"
  run --separate-stderr gcs_delete_prefix gs://b/snap
  assert_status 1
  assert_contains "${stderr}" "HTTPError 403"
}

@test "ensure_snapshot_bucket: an existing unconditional binding is not granted again" {
  local sa=composer-dev-sa@hib-test-project.iam.gserviceaccount.com
  mkdir -p "${STUB_DIR}/gcs/hib-test-project-composer-snapshots"
  t_reply iam 0 ""
  t_reply iam-get.1 0 "{\"bindings\": [{\"role\": \"roles/storage.objectAdmin\", \"members\": [\"serviceAccount:${sa}\"]}]}"
  run ensure_snapshot_bucket composer-dev "${sa}"
  assert_status 0
  assert_contains "${output}" "already has roles/storage.objectAdmin"
  assert_eq "$(t_calls add-iam-policy-binding)" 0
  # A conditional binding does not count; neither does another role.
  t_reply iam-get.2 0 "{\"bindings\": [{\"role\": \"roles/storage.objectAdmin\", \"members\": [\"serviceAccount:${sa}\"], \"condition\": {\"title\": \"t\"}}, {\"role\": \"roles/storage.objectViewer\", \"members\": [\"serviceAccount:${sa}\"]}]}"
  run ensure_snapshot_bucket composer-dev "${sa}"
  assert_status 0
  assert_eq "$(t_calls add-iam-policy-binding)" 1
  # Unreadable policy: fall back to granting.
  t_reply iam-get.3 1 "" "ERROR: denied"
  run ensure_snapshot_bucket composer-dev "${sa}"
  assert_status 0
  assert_eq "$(t_calls add-iam-policy-binding)" 2
  [[ ! -d "${OPT_WORK_DIR}/locks/bucket-iam-hib-test-project-composer-snapshots.lock" ]]
}

@test "with_lock: serialises, releases on failure, times out" {
  run with_lock demo false
  assert_status 1
  [[ ! -d "${OPT_WORK_DIR}/locks/demo.lock" ]]
  mkdir -p "${OPT_WORK_DIR}/locks/demo.lock"
  HIBERNATE_LOCK_TIMEOUT_SECONDS=0
  run with_lock demo true
  assert_status 1
  assert_contains "${output}" "timed out after 0s waiting for lock"
}

@test "wait_for_operation: failed polls are retried within the grace period, then given up" {
  t_reply operation.1 1 "" "ERROR: UNAVAILABLE"
  t_reply operation.2 1 "" "ERROR: UNAVAILABLE"
  t_reply operation.3 1 "" "ERROR: UNAVAILABLE"
  t_reply operation.4 1 "" "ERROR: UNAVAILABLE"
  t_reply operation 0 "${SAVE_DONE}"
  HIBERNATE_POLL_FAILURE_GRACE_SECONDS=60
  run --separate-stderr wait_for_operation projects/p/locations/r/operations/op-save-1 europe-west2 hib-test-project "unit op"
  assert_status 0
  assert_contains "${stderr}" "could not poll operation projects/p/locations/r/operations/op-save-1; trying again"
  assert_eq "$(t_count operation)" 5

  rm -rf "${STUB_DIR}/replies" "${STUB_DIR}/operation.count"
  mkdir -p "${STUB_DIR}/replies"
  t_reply operation 1 "" "ERROR: UNAVAILABLE"
  HIBERNATE_POLL_FAILURE_GRACE_SECONDS=0
  run --separate-stderr wait_for_operation projects/p/locations/r/operations/op-save-1 europe-west2 hib-test-project "unit op"
  assert_status 1
  assert_contains "${stderr}" "it may still be running server-side"
}

@test "composer_snapshot_save: records the accepted operation for the caller" {
  t_reply save 0 "${SAVE_OP}"
  t_reply operation 1 "" "ERROR: UNAVAILABLE"
  run --separate-stderr composer_snapshot_save composer-dev europe-west2 hib-test-project gs://snaps/p "${BATS_TEST_TMPDIR}/op"
  assert_status 1
  assert_eq "$(cat "${BATS_TEST_TMPDIR}/op")" "projects/hib-test-project/locations/europe-west2/operations/op-save-1"
}

@test "composer_snapshot_load: ON_STARTED gets every accepted operation" {
  t_reply load 0 '{"name": "projects/p/locations/r/operations/op-load-7", "done": false}'
  t_reply operation 0 '{"name": "op-load-7", "done": true, "response": {}}'
  record() { printf '%s %s\n' "$1" "$2" >>"${BATS_TEST_TMPDIR}/started"; }
  run --separate-stderr composer_snapshot_load composer-dev europe-west2 hib-test-project gs://b/s \
    '{"skip_pypi_packages_installation": true}' record composer-dev
  assert_status 0
  assert_eq "$(cat "${BATS_TEST_TMPDIR}/started")" "composer-dev projects/p/locations/r/operations/op-load-7"
}
