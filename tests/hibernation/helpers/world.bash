# shellcheck shell=bash
# ============================================================================
# Shared bats helpers for the hibernation end-to-end suites.
#
# setup_world_file (call from setup_file):
#   * copies the Terraform root module (main.tf, modules/, ...) and a fixture
#     YAML into a temp "tfroot"
#   * starts tools/stub_google_api.py and points the providers at it, so REAL
#     Terraform can plan offline (data.google_project is the only API read)
#   * initialises Terraform and "deploys" the fixture: real plans + simulated
#     applies until the plan has no resource changes, mirroring every Composer
#     environment into the fake GCP world
#   * seeds each environment with a DAG file and Airflow DB content so tests
#     can prove the data survives a shutdown → startup cycle
#
# setup_world (call from setup): gives every test its own copy of the
# converged baseline and puts the fakes first on PATH.
# ============================================================================

HIB_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIB_REPO="$(cd "${HIB_TEST_DIR}/../.." && pwd)"
SHUTDOWN="${HIB_REPO}/scripts/hibernation/composer-shutdown.sh"
STARTUP="${HIB_REPO}/scripts/hibernation/composer-startup.sh"
PROJECT="hib-test-project"
REGION="europe-west2"

_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

setup_world_file() {
  local fixture="${1:-hibernation.yaml}"
  REAL_TERRAFORM="$(command -v terraform)"
  export REAL_TERRAFORM
  export BASE="${BATS_FILE_TMPDIR}/base"
  export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${HOME}/.terraform.d/plugin-cache}"
  mkdir -p "${TF_PLUGIN_CACHE_DIR}" "${BASE}/tfroot/configs" "${BASE}/world/envs" "${BASE}/world/gcs" "${BASE}/world/ops"

  cp "${HIB_REPO}"/{main.tf,variables.tf,outputs.tf,versions.tf,.terraform.lock.hcl} "${BASE}/tfroot/"
  cp -r "${HIB_REPO}/modules" "${BASE}/tfroot/"
  cp "${HIB_TEST_DIR}/fixtures/${fixture}" "${BASE}/tfroot/configs/hibernation.yaml"

  STUB_PORT="$(_free_port)"
  export STUB_PORT
  python3 "${HIB_TEST_DIR}/tools/stub_google_api.py" "${STUB_PORT}" &
  echo $! >"${BATS_FILE_TMPDIR}/stub.pid"
  cat >"${BASE}/tfroot/provider_override.tf" <<EOF
provider "google" {
  resource_manager_custom_endpoint = "http://127.0.0.1:${STUB_PORT}/v1/"
  cloud_billing_custom_endpoint    = "http://127.0.0.1:${STUB_PORT}/v1/"
}
provider "google-beta" {
  resource_manager_custom_endpoint = "http://127.0.0.1:${STUB_PORT}/v1/"
  cloud_billing_custom_endpoint    = "http://127.0.0.1:${STUB_PORT}/v1/"
}
EOF
  export GOOGLE_OAUTH_ACCESS_TOKEN=fake-token
  export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,${NO_PROXY}}" no_proxy="127.0.0.1,localhost${no_proxy:+,${no_proxy}}"

  "${REAL_TERRAFORM}" -chdir="${BASE}/tfroot" init -input=false -no-color >"${BASE}/init.log" 2>&1 ||
    {
      cat "${BASE}/init.log" >&2
      return 1
    }
  "${REAL_TERRAFORM}" -chdir="${BASE}/tfroot" providers schema -json >"${BASE}/schema.json"
  export FAKE_TF_SCHEMA="${BASE}/schema.json"

  # "Deploy": real plan + simulated apply until there are no resource changes.
  local i n
  for i in 1 2 3 4 5 6; do
    "${REAL_TERRAFORM}" -chdir="${BASE}/tfroot" plan -input=false -no-color -refresh=false \
      -var config_file=configs/hibernation.yaml -out=deploy.tfplan >"${BASE}/deploy.log" 2>&1 ||
      {
        cat "${BASE}/deploy.log" >&2
        return 1
      }
    "${REAL_TERRAFORM}" -chdir="${BASE}/tfroot" show -json deploy.tfplan >"${BASE}/deploy.json"
    n="$(jq '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length' "${BASE}/deploy.json")"
    ((n == 0)) && break
    FAKE_GCP_DIR="${BASE}/world" python3 "${HIB_TEST_DIR}/tools/tfstate_apply.py" "${BASE}/deploy.json" \
      "${BASE}/tfroot/terraform.tfstate" --schema "${FAKE_TF_SCHEMA}" --composer-out "${BASE}/events.json"
    FAKE_GCP_DIR="${BASE}/world" python3 "${HIB_TEST_DIR}/fakes/fakegcp.py" apply-events "${BASE}/events.json"
  done
  ((n == 0)) || {
    echo "baseline did not converge" >&2
    return 1
  }
  rm -f "${BASE}/tfroot/deploy.tfplan"

  # Image versions the (fake) Composer API reports as creatable.
  cat >"${BASE}/world/image-versions.json" <<'EOF2'
[
  {"imageVersionId": "composer-3-airflow-2.11.1-build.25", "isDefault": true, "creationDisabled": false},
  {"imageVersionId": "composer-3-airflow-2.10.5-build.20", "isDefault": false, "creationDisabled": false},
  {"imageVersionId": "composer-3-airflow-2.10.5-build.9", "isDefault": false, "creationDisabled": true},
  {"imageVersionId": "composer-3-airflow-2.10.2-build.13", "isDefault": false, "creationDisabled": true},
  {"imageVersionId": "composer-3-airflow-2.9.3-build.30", "isDefault": false, "creationDisabled": false},
  {"imageVersionId": "composer-3-airflow-3.1.7-build.4", "isDefault": false, "creationDisabled": false}
]
EOF2

  # Seed data that must survive hibernation.
  local f bucket name
  for f in "${BASE}"/world/envs/*.json; do
    name="$(jq -r '.name | split("/") | last' "${f}")"
    bucket="$(jq -r .storageConfig.bucket "${f}")"
    echo "with DAG() as ${name}: pass" >"${BASE}/world/gcs/${bucket}/dags/${name}_dag.py"
    jq --arg db "airflow-db-of-${name}" '._db = $db' "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
  done
}

teardown_world_file() {
  if [[ -f "${BATS_FILE_TMPDIR}/stub.pid" ]]; then
    kill "$(cat "${BATS_FILE_TMPDIR}/stub.pid")" 2>/dev/null || true
  fi
}

setup_world() {
  W="${BATS_TEST_TMPDIR}/w"
  cp -a "${BASE}" "${W}"
  export TF_ROOT="${W}/tfroot"
  export FAKE_GCP_DIR="${W}/world"
  export FAKE_TF_SCHEMA="${W}/schema.json"
  export PATH="${HIB_TEST_DIR}/fakes:${PATH}"
  export HIBERNATE_POLL_SECONDS=0
  export HIBERNATE_RETRY_SLEEP_SECONDS=0
  export HIBERNATE_CONFIG_FILE=configs/hibernation.yaml
  export FAKE_OP_POLLS=1
  unset HIBERNATE_ENVIRONMENTS HIBERNATE_DRY_RUN GITLAB_CI CI_PIPELINE_ID TF_BACKEND_BUCKET TF_BACKEND_PREFIX
  unset FAKE_TF_FAIL_PLAN FAKE_TF_FAIL_APPLY FAKE_TF_SHOW_JQ FAKE_CREATE_STATE
  RUN="${W}/run"
}

# ── Running the scripts ──────────────────────────────────────────────────────
# Each run gets its own work dir so tests can inspect plans/logs/summary.
_run_n=0
shutdown_run() {
  _run_n=$((_run_n + 1))
  run "${SHUTDOWN}" --work-dir "${RUN}-${_run_n}" "$@"
  LAST_RUN="${RUN}-${_run_n}"
}

startup_run() {
  _run_n=$((_run_n + 1))
  run "${STARTUP}" --work-dir "${RUN}-${_run_n}" "$@"
  LAST_RUN="${RUN}-${_run_n}"
}

# ── World inspection ─────────────────────────────────────────────────────────
env_file() { printf '%s/envs/%s__%s__%s.json\n' "${FAKE_GCP_DIR}" "${PROJECT}" "${REGION}" "$1"; }

env_state() {
  local f
  f="$(env_file "$1")"
  if [[ -f "${f}" ]]; then jq -r .state "${f}"; else echo NOT_FOUND; fi
}

env_field() { jq -r "$2" "$(env_file "$1")"; }

set_env_field() {
  local f
  f="$(env_file "$1")"
  jq "$2" "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
}

snapshot_root() { printf 'gs://%s-composer-snapshots/composer-hibernation/%s/%s/%s\n' "${PROJECT}" "${PROJECT}" "${REGION}" "$1"; }

gcs_path() {
  local url="${1#gs://}"
  printf '%s/gcs/%s\n' "${FAKE_GCP_DIR}" "${url}"
}

manifest() { cat "$(gcs_path "$(snapshot_root "$1")/hibernation-state.json")"; }

manifest_field() { manifest "$1" | jq -r "$2"; }

set_manifest_field() {
  local f
  f="$(gcs_path "$(snapshot_root "$1")/hibernation-state.json")"
  jq "$2" "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
}

bucket_exists() { [[ -f "${FAKE_GCP_DIR}/gcs/$1/.bucket.json" ]]; }

tf_state_has() { grep -Fxq "$1" <<<"$("${REAL_TERRAFORM}" -chdir="${TF_ROOT}" state list)"; }

composer_addr() { printf 'module.composer["%s"].google_composer_environment.this\n' "$1"; }

gcloud_calls() { cat "${FAKE_GCP_DIR}/calls.log" 2>/dev/null || true; }

# terraform apply calls made against the root module (the offline settings
# resolver's own `apply` is excluded).
tf_apply_count() {
  local n
  n="$(grep '"apply"' "${FAKE_GCP_DIR}/terraform-calls.log" 2>/dev/null | grep -vc 'hibernation/resolver')" || true
  printf '%s\n' "${n:-0}"
}

# add_fault REGEX RC STDERR [TIMES]
add_fault() {
  local f="${FAKE_GCP_DIR}/faults.json"
  [[ -f "${f}" ]] || echo '[]' >"${f}"
  jq --arg m "$1" --argjson rc "$2" --arg e "$3" --argjson t "${4:-1}" \
    '. + [{match: $m, rc: $rc, stderr: $e, times: $t}]' "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
}

# add_op_fault REGEX MESSAGE [TIMES]
add_op_fault() {
  local f="${FAKE_GCP_DIR}/faults.json"
  [[ -f "${f}" ]] || echo '[]' >"${f}"
  jq --arg m "$1" --arg e "$2" --argjson t "${3:-1}" \
    '. + [{match: $m, op_error: {code: 13, message: $e}, times: $t}]' "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
}

summary_status() { jq -r --arg k "$1" '.environments[] | select(.environment == $k) | .status' "${LAST_RUN}/summary.json"; }

# Prints the script output when an assertion fails (bats shows it).
show_output() { printf '%s\n' "${output}"; }
