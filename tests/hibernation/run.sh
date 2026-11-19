#!/usr/bin/env bash
# ============================================================================
# Runs every test for the hibernation feature (used by the `hibernation-tests`
# CI job). Optional tools are skipped with a notice when unavailable:
#   gitlab-ci-local   (pipeline rule evaluation)   GITLAB_CI_LOCAL=/path
#   python jsonschema (GitLab CI schema validation)
# Results (TAP) are written to tests/hibernation/.results/.
# ============================================================================
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo}" || exit 1
results="tests/hibernation/.results"
mkdir -p "${results}"
jobs="${BATS_JOBS:-$(command -v parallel >/dev/null && echo 4 || echo 1)}"
failed=()

step() {
  local name="$1"
  shift
  printf '\n==== %s ====\n' "${name}"
  "$@"
  local rc=$?
  if ((rc == 77)); then
    echo "---- ${name}: SKIPPED"
  elif ((rc != 0)); then
    echo "---- ${name}: FAILED (rc=${rc})"
    failed+=("${name}")
  else
    echo "---- ${name}: passed"
  fi
}

bats_suite() {
  local file="$1" name
  name="$(basename "${file}" .bats)"
  local args=(--timing)
  ((jobs > 1)) && args+=(--jobs "${jobs}")
  bats "${args[@]}" "${file}" | tee "${results}/${name}.tap"
  return "${PIPESTATUS[0]}"
}

step shellcheck shellcheck -x scripts/hibernation/*.sh scripts/hibernation/lib/common.sh scripts/ci/*.sh \
  tests/hibernation/fakes/gcloud tests/hibernation/fakes/terraform tests/hibernation/run.sh tests/ci/*.sh
step "gitlab-ci schema" python3 tests/ci/validate_gitlab_ci.py .gitlab-ci.yml pipelines/*.yml
step "gitlab-ci rules" tests/ci/test_pipeline_rules.sh
for suite in tests/hibernation/regression.bats tests/hibernation/unit.bats tests/hibernation/resolver.bats tests/ci/schedules.bats tests/hibernation/e2e.bats; do
  [[ -f "${suite}" ]] && step "bats $(basename "${suite}")" bats_suite "${suite}"
done

echo
if ((${#failed[@]})); then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "All hibernation tests passed."
