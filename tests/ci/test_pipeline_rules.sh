#!/usr/bin/env bash
# ============================================================================
# Asserts which GitLab CI jobs are created for each kind of pipeline, by
# evaluating .gitlab-ci.yml (+ includes, extends, !reference, rules) with
# gitlab-ci-local (https://github.com/firecow/gitlab-ci-local) — offline.
#
# The working tree is committed into a throw-away git repository because
# gitlab-ci-local reads includes from git and needs an origin/HEAD.
#
# Usage: tests/ci/test_pipeline_rules.sh   (GITLAB_CI_LOCAL=/path/to/binary)
# Exit 0 = all expectations met; 77 = gitlab-ci-local not available (skip).
# ============================================================================
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gcl="${GITLAB_CI_LOCAL:-$(command -v gitlab-ci-local || true)}"
if [[ -z "${gcl}" ]]; then
  echo "SKIP: gitlab-ci-local not found (npm i -g gitlab-ci-local, or set GITLAB_CI_LOCAL)"
  exit 77
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/repo"
tar -C "${repo}" --exclude=./.git --exclude='*/.terraform' --exclude=./.terraform --exclude=./.hibernation \
  --exclude=./tests/hibernation/.results -cf - . | tar -C "${work}/repo" -xf -
cd "${work}/repo"
git init -q -b main
git -c user.email=ci@example.com -c user.name=ci add -A
git -c user.email=ci@example.com -c user.name=ci commit -qm snapshot
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git remote add origin https://gitlab.example.com/group/composer-3-terraform.git

# jobs SOURCE ACTION -> sorted "job:when" lines
jobs() {
  local src="$1" act="$2"
  local args=(--variable "CI_PIPELINE_SOURCE=${src}" --variable CI_DEFAULT_BRANCH=main --variable CI_COMMIT_BRANCH=main)
  [[ -n "${act}" ]] && args+=(--variable "HIBERNATE_ACTION=${act}")
  if [[ "${src}" == merge_request_event ]]; then
    args+=(--variable CI_MERGE_REQUEST_IID=7 --variable CI_COMMIT_BRANCH=)
  fi
  GCL_IGNORE_PREDEFINED_VARS=CI_PIPELINE_SOURCE,CI_DEFAULT_BRANCH,CI_COMMIT_BRANCH \
    "${gcl}" --list-json "${args[@]}" 2>/dev/null |
    jq -r '.[] | select(.when != "never") | "\(.name):\(.when)"' | sort | paste -sd' ' -
}

fail=0
expect() {
  local src="$1" act="$2" want="$3" got
  got="$(jobs "${src}" "${act}")"
  if [[ "${got}" == "${want}" ]]; then
    echo "ok   source=${src} action=${act:-<none>}: ${got}"
  else
    echo "FAIL source=${src} action=${act:-<none>}"
    echo "     want: ${want}"
    echo "     got:  ${got}"
    fail=1
  fi
}

checks="hibernation-tests:on_success terraform-test:on_success terraform-validate:on_success"

# Scheduled pipelines run ONLY the matching hibernation job.
expect schedule shutdown "dev-composer-shutdown:on_success"
expect schedule startup "dev-composer-startup:on_success"
# A schedule without (or with an unknown) action runs nothing at all.
expect schedule "" ""
expect schedule bogus ""
# Manual pipeline with an action: just that job, immediately.
expect web shutdown "dev-composer-shutdown:on_success"
expect web startup "dev-composer-startup:on_success"
expect web dry-run "dev-composer-hibernation-dry-run:on_success"
# Manual pipeline without an action: normal checks/plan/apply + manual buttons.
expect web "" "dev-apply:manual dev-composer-hibernation-dry-run:manual dev-composer-shutdown:manual dev-composer-startup:manual dev-plan:on_success ${checks}"
# Push to the default branch: checks, plan, manual apply — no hibernation.
expect push "" "dev-apply:manual dev-composer-hibernation-dry-run:manual dev-plan:on_success ${checks}"
# Merge request: checks + plan only.
expect merge_request_event "" "dev-plan:on_success ${checks}"

exit "${fail}"
