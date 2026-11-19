#!/usr/bin/env bats
# Regression tests for bugs found while testing scripts/hibernation.

LIB="${BATS_TEST_DIRNAME}/../../scripts/hibernation/lib/common.sh"

# Bug: `tf_state_list | grep -q ADDR` under `set -o pipefail` reported
# resources as missing whenever grep exited before the producer finished
# writing (SIGPIPE → 141). With a large state this happened every time, so
# shutdown refused every environment as "not in the Terraform state".
@test "state lookups are reliable with a very large state under pipefail" {
  run bash -c '
    set -Eeuo pipefail
    source "$1"
    OPT_WORK_DIR="$(mktemp -d)"
    TF_STATE_LIST="$(for i in $(seq 1 5000); do
      printf "module.composer[\"composer-dev\"].google_project_iam_member.r[\"roles/r%s\"]\n" "$i"
    done; printf "%s\n" "module.composer[\"composer-dev\"].google_composer_environment.this")"
    TF_STATE_LOADED=true
    ok=0
    for i in $(seq 1 50); do
      tf_module_in_state composer-dev && tf_resource_in_state composer-dev && ok=$((ok + 1))
    done
    echo "${ok}"
    tf_module_in_state composer-test && echo "false positive"
    tf_resource_in_state composer-test && echo "false positive"
    true
  ' _ "${LIB}"
  [ "$status" -eq 0 ]
  [ "$output" = 50 ]
}

@test "state lookups refuse to run before the state was loaded" {
  run bash -c 'source "$1"; OPT_WORK_DIR=/tmp; tf_resource_in_state composer-dev' _ "${LIB}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"tf_state_load not called"* ]]
}
