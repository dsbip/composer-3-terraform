#!/usr/bin/env bats
# ============================================================================
# End-to-end tests for scripts/hibernation against REAL Terraform plans.
#
# Terraform (init/plan/show/state) is the real binary working on a converged
# state of tests/hibernation/fixtures/hibernation.yaml; only `apply` and
# Google Cloud are simulated (fakes/terraform, fakes/gcloud, fakes/curl).
# See helpers/world.bash.
#
# Fixture: composer-dev (defaults), composer-test (custom bucket + pinned
# image composer-3-airflow-2.9.3), composer-prod (production, never touched).
# ============================================================================

load helpers/world

setup_file() { setup_world_file; }
teardown_file() { teardown_world_file; }
setup() { setup_world; }

DEV_ADDR='module.composer["composer-dev"].google_composer_environment.this'
TEST_ADDR='module.composer["composer-test"].google_composer_environment.this'

yaml_edit() {
  # yaml_edit '<python statement on dict c>'
  python3 - "${TF_ROOT}/configs/hibernation.yaml" "$1" <<'EOF'
import sys, yaml
path, stmt = sys.argv[1], sys.argv[2]
c = yaml.safe_load(open(path))
exec(stmt)
yaml.safe_dump(c, open(path, "w"), sort_keys=False)
EOF
}

# ── Happy path ───────────────────────────────────────────────────────────────

@test "shutdown snapshots, verifies and deletes only the hibernating environments" {
  local dev_bucket
  dev_bucket="$(env_field composer-dev .storageConfig.bucket)"
  shutdown_run
  show_output
  [ "$status" -eq 0 ]

  # Environments gone, production untouched.
  [ "$(env_state composer-dev)" = NOT_FOUND ]
  [ "$(env_state composer-test)" = NOT_FOUND ]
  [ "$(env_state composer-prod)" = RUNNING ]

  # Only the Composer resources left the Terraform state.
  ! tf_state_has "${DEV_ADDR}"
  ! tf_state_has "${TEST_ADDR}"
  tf_state_has 'module.composer["composer-prod"].google_composer_environment.this'
  tf_state_has 'module.composer["composer-dev"].google_service_account.composer[0]'
  tf_state_has 'module.composer["composer-dev"].google_compute_network.composer[0]'

  # The destroy plan deleted exactly the two environments.
  run jq -r '[.resource_changes[] | select(.change.actions != ["no-op"]) | "\(.address)=\(.change.actions|join(","))"] | sort | join(" ")' "${LAST_RUN}/plans/destroy.json"
  [ "$output" = "${DEV_ADDR}=delete ${TEST_ADDR}=delete" ]

  # State file + snapshot contents.
  [ "$(manifest_field composer-dev .status)" = HIBERNATED ]
  [ "$(manifest_field composer-test .status)" = HIBERNATED ]
  local snap
  snap="$(manifest_field composer-dev .latest_snapshot.path)"
  [[ "${snap}" == "$(snapshot_root composer-dev)/"* ]]
  [ -f "$(gcs_path "${snap}")/airflow-database.sql.gz" ]
  [ "$(cat "$(gcs_path "${snap}")/airflow-database.sql.gz")" = "airflow-db-of-composer-dev" ]
  [ -f "$(gcs_path "${snap}")/gcs/dags/composer-dev_dag.py" ]
  [ "$(manifest_field composer-dev .latest_snapshot.image_version)" = composer-3-airflow-2.10.5-build.20 ]
  [ "$(manifest_field composer-dev .latest_snapshot.airflow_version)" = 2.10.5 ]
  [ "$(manifest_field composer-dev '.history | length')" -ge 2 ]

  # Snapshot bucket created hardened; both environment SAs may write to it.
  bucket_exists "${PROJECT}-composer-snapshots"
  run jq -r '.create_flags | join(" ")' "${FAKE_GCP_DIR}/gcs/${PROJECT}-composer-snapshots/.bucket.json"
  [[ "$output" == *--uniform-bucket-level-access* && "$output" == *--public-access-prevention* ]]
  run jq -r '.iam[] | "\(.member) \(.role)"' "${FAKE_GCP_DIR}/gcs/${PROJECT}-composer-snapshots/.bucket.json"
  [[ "$output" == *"serviceAccount:composer-dev-sa@${PROJECT}.iam.gserviceaccount.com roles/storage.objectAdmin"* ]]
  [[ "$output" == *"serviceAccount:composer-test-sa@${PROJECT}.iam.gserviceaccount.com roles/storage.objectAdmin"* ]]

  # Orphaned auto-created bucket is scheduled (7-day grace), custom bucket kept.
  [ "$(manifest_field composer-dev '.orphaned_buckets[0].bucket')" = "${dev_bucket}" ]
  bucket_exists "${dev_bucket}"
  [ "$(manifest_field composer-test '.orphaned_buckets // [] | length')" = 0 ]
  bucket_exists hib-test-project-composer-test-data

  # Production was never even described for snapshotting.
  ! gcloud_calls | grep -q 'snapshots", "save", "composer-prod'
  [ "$(summary_status composer-dev)" = ok ]
  [ "$(summary_status composer-test)" = ok ]
}

@test "startup recreates from the YAML, pins the snapshot's Airflow version and restores data" {
  shutdown_run
  [ "$status" -eq 0 ]
  startup_run
  show_output
  [ "$status" -eq 0 ]

  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(env_state composer-test)" = RUNNING ]
  tf_state_has "${DEV_ADDR}"
  tf_state_has "${TEST_ADDR}"

  # composer-dev: YAML has no image_version → pinned to the snapshot's X.Y.Z.
  [ "$(env_field composer-dev .config.softwareConfig.imageVersion)" = composer-3-airflow-2.10.5 ]
  run jq -c .fallback_image_versions "${LAST_RUN}/fallback-image-versions.tfvars.json"
  [ "$output" = '{"composer-dev":"composer-3-airflow-2.10.5"}' ]
  # composer-test: the YAML's explicit image_version always wins.
  [ "$(env_field composer-test .config.softwareConfig.imageVersion)" = composer-3-airflow-2.9.3 ]
  [ "$(env_field composer-test .storageConfig.bucket)" = hib-test-project-composer-test-data ]

  # Airflow DB and DAGs restored; Terraform-owned settings not overwritten.
  [ "$(env_field composer-dev ._db)" = airflow-db-of-composer-dev ]
  [ "$(env_field composer-test ._db)" = airflow-db-of-composer-test ]
  local new_bucket
  new_bucket="$(env_field composer-dev .storageConfig.bucket)"
  [ -f "${FAKE_GCP_DIR}/gcs/${new_bucket}/dags/composer-dev_dag.py" ]
  run env_field composer-dev '._loads[0].skips | join(" ")'
  [ "$output" = "--skip-airflow-overrides-setting --skip-environment-variables-setting --skip-pypi-packages-installation" ]

  # Plan touched only the two environments (module-instance targets).
  run jq -r '[.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | "\(.address)=\(.change.actions|join(","))"] | sort | join(" ")' "${LAST_RUN}/plans/recreate.json"
  [ "$output" = "${DEV_ADDR}=create ${TEST_ADDR}=create" ]
  grep -F -- '-target=module.composer[\"composer-dev\"]"' "${FAKE_GCP_DIR}/terraform-calls.log"

  [ "$(manifest_field composer-dev .status)" = ACTIVE ]
  [ "$(manifest_field composer-dev .last_restore.snapshot)" = "$(manifest_field composer-dev .latest_snapshot.path)" ]
  [ "$(env_state composer-prod)" = RUNNING ]
}

@test "a regular (non-targeted) plan after the cycle shows no drift" {
  shutdown_run
  [ "$status" -eq 0 ]
  startup_run
  [ "$status" -eq 0 ]
  run terraform -chdir="${TF_ROOT}" plan -input=false -no-color -var config_file=configs/hibernation.yaml -out="${W}/after.tfplan"
  [ "$status" -eq 0 ]
  terraform -chdir="${TF_ROOT}" show -json "${W}/after.tfplan" >"${W}/after.json"
  run jq '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length' "${W}/after.json"
  [ "$output" = 0 ]
}

@test "both scripts are idempotent" {
  shutdown_run
  [ "$status" -eq 0 ]
  local saves
  saves="$(gcloud_calls | grep -c '"snapshots", "save"')"
  shutdown_run
  show_output
  [ "$status" -eq 0 ]
  [ "$(summary_status composer-dev)" = skipped ]
  [ "$(summary_status composer-test)" = skipped ]
  [ "$(gcloud_calls | grep -c '"snapshots", "save"')" = "${saves}" ]
  [ ! -f "${LAST_RUN}/plans/destroy.tfplan" ]

  startup_run
  [ "$status" -eq 0 ]
  startup_run
  show_output
  [ "$status" -eq 0 ]
  [ "$(summary_status composer-dev)" = skipped ]
  [ "$(gcloud_calls | grep -c '"snapshots", "load"')" = 2 ]
  [ ! -f "${LAST_RUN}/plans/recreate.tfplan" ]
}

@test "snapshot retention keeps the newest N and never the restore point" {
  # retention 2 (fixture): three cycles leave two snapshots.
  local i
  for i in 1 2 3; do
    shutdown_run --env composer-dev
    [ "$status" -eq 0 ]
    startup_run --env composer-dev
    [ "$status" -eq 0 ]
  done
  [ "$(manifest_field composer-dev '.snapshots | length')" = 2 ]
  local latest
  latest="$(manifest_field composer-dev .latest_snapshot.path)"
  [ "$(manifest_field composer-dev '.snapshots[0].path')" = "${latest}" ]
  run find "$(gcs_path "$(snapshot_root composer-dev)")" -mindepth 1 -maxdepth 1 -type d
  [ "${#lines[@]}" -eq 2 ]
}

@test "orphaned environment buckets are deleted after the grace period" {
  yaml_edit 'c["hibernation"]["orphaned_bucket_retention_days"] = 0'
  local b1
  b1="$(env_field composer-dev .storageConfig.bucket)"
  shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  ! bucket_exists "${b1}"
  [ "$(manifest_field composer-dev '.orphaned_buckets | length')" = 0 ]
}

@test "an orphaned bucket past its grace period is deleted by a later shutdown, even while hibernated" {
  local b1
  b1="$(env_field composer-dev .storageConfig.bucket)"
  shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  bucket_exists "${b1}"
  # Age the record by 8 days; the next (no-op) shutdown cleans it up.
  set_manifest_field composer-dev '.orphaned_buckets[0].orphaned_epoch -= 8*86400'
  shutdown_run --env composer-dev
  show_output
  [ "$status" -eq 0 ]
  [ "$(summary_status composer-dev)" = skipped ]
  ! bucket_exists "${b1}"
  [ "$(manifest_field composer-dev '.orphaned_buckets | length')" = 0 ]
}

# ── Failure handling: nothing is deleted without a verified snapshot ────────

@test "failed snapshot operation: environment is NOT deleted, others proceed" {
  add_op_fault 'snapshots save composer-dev' 'snapshot failed: database too large'
  shutdown_run
  show_output
  [ "$status" -eq 1 ]
  [ "$(env_state composer-dev)" = RUNNING ]
  tf_state_has "${DEV_ADDR}"
  [ "$(summary_status composer-dev)" = failed ]
  [ "$(manifest_field composer-dev .status)" != HIBERNATED ]
  [ "$(env_state composer-test)" = NOT_FOUND ]
  [ "$(summary_status composer-test)" = ok ]
  run jq -r '[.resource_changes[] | select(.change.actions != ["no-op"]) | .address] | join(" ")' "${LAST_RUN}/plans/destroy.json"
  [ "$output" = "${TEST_ADDR}" ]
}

@test "snapshot request rejected while another operation runs is retried once" {
  add_fault 'snapshots save composer-dev' 1 'ERROR: (gcloud.composer.environments.snapshots.save) FAILED_PRECONDITION: Cannot update Environment with an operation in progress'
  shutdown_run --env composer-dev
  show_output
  [ "$status" -eq 0 ]
  [ "$(env_state composer-dev)" = NOT_FOUND ]
  [ "$(gcloud_calls | grep -c '"snapshots", "save", "composer-dev"')" = 2 ]
}

@test "snapshot request rejected for another reason: no retry, not deleted" {
  add_fault 'snapshots save composer-dev' 1 'ERROR: (gcloud.composer.environments.snapshots.save) PERMISSION_DENIED: nope' 5
  shutdown_run --env composer-dev
  [ "$status" -eq 1 ]
  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(gcloud_calls | grep -c '"snapshots", "save", "composer-dev"')" = 1 ]
}

@test "terraform apply failure: snapshot kept, environment running, re-run completes" {
  FAKE_TF_FAIL_APPLY=before shutdown_run
  show_output
  [ "$status" -eq 1 ]
  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(manifest_field composer-dev .status)" = SNAPSHOT_SAVED ]
  local first
  first="$(manifest_field composer-dev .latest_snapshot.path)"
  [ -n "${first}" ]

  shutdown_run
  show_output
  [ "$status" -eq 0 ]
  [ "$(env_state composer-dev)" = NOT_FOUND ]
  [ "$(manifest_field composer-dev .status)" = HIBERNATED ]
  # A fresh snapshot was taken (the environment kept running meanwhile).
  [ "$(manifest_field composer-dev .latest_snapshot.path)" != "${first}" ]
}

@test "terraform apply reporting failure after deleting: environments are still finalized" {
  FAKE_TF_FAIL_APPLY=after shutdown_run
  show_output
  [ "$(env_state composer-dev)" = NOT_FOUND ]
  [ "$(manifest_field composer-dev .status)" = HIBERNATED ]
  [ "$(summary_status composer-dev)" = ok ]
}

@test "plan guard refuses a destroy plan that touches anything else" {
  export FAKE_TF_SHOW_JQ='if has("resource_changes") then .resource_changes += [{"address":"module.composer[\"composer-dev\"].google_service_account.composer[0]","mode":"managed","change":{"actions":["delete"]}}] else . end'
  shutdown_run
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"plan guard: unexpected change 'delete' on module.composer[\"composer-dev\"].google_service_account.composer[0]"* ]]
  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(env_state composer-test)" = RUNNING ]
  [ "$(tf_apply_count)" = 0 ]
}

@test "environment missing from the Terraform state is never touched" {
  terraform -chdir="${TF_ROOT}" state rm "${DEV_ADDR}" >/dev/null
  shutdown_run
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the Terraform state"* ]]
  [ "$(env_state composer-dev)" = RUNNING ]
  ! gcloud_calls | grep -q '"snapshots", "save", "composer-dev"'
  [ "$(env_state composer-test)" = NOT_FOUND ]
}

@test "ERROR environment: refused without --force-delete-without-snapshot" {
  set_env_field composer-dev '.state = "ERROR"'
  shutdown_run --env composer-dev
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR state"* ]]
  [ "$(env_state composer-dev)" = ERROR ]

  shutdown_run --env composer-dev --force-delete-without-snapshot
  show_output
  [ "$status" -eq 0 ]
  [ "$(env_state composer-dev)" = NOT_FOUND ]
  [ "$(manifest_field composer-dev .status)" = HIBERNATED ]
  [ "$(manifest_field composer-dev .latest_snapshot)" = null ]

  # Nothing to restore → startup creates a fresh environment.
  startup_run --env composer-dev
  show_output
  [ "$status" -eq 0 ]
  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(env_field composer-dev ._db)" = "" ]
  [ "$(manifest_field composer-dev .status)" = ACTIVE ]
}

@test "transitional UPDATING state is waited out before snapshotting" {
  set_env_field composer-dev '.state = "UPDATING" | ._transitions = [{"state": "UPDATING", "polls": 2}]'
  shutdown_run --env composer-dev
  show_output
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting for it to settle"* ]]
  [ "$(env_state composer-dev)" = NOT_FOUND ]
}

# ── Restore-ability checks before deleting ───────────────────────────────────

@test "refuses to delete when the restore image can no longer be created" {
  jq 'map(if (.imageVersionId | startswith("composer-3-airflow-2.10.5")) then .creationDisabled = true else . end)' \
    "${FAKE_GCP_DIR}/image-versions.json" >"${W}/iv.json" && mv "${W}/iv.json" "${FAKE_GCP_DIR}/image-versions.json"
  shutdown_run
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"composer-3-airflow-2.10.5 can no longer be used to create environments"* ]]
  [ "$(env_state composer-dev)" = RUNNING ]
  ! gcloud_calls | grep -q '"snapshots", "save", "composer-dev"'
  # composer-test pins 2.9.3, which is still creatable.
  [ "$(env_state composer-test)" = NOT_FOUND ]

  HIBERNATE_SKIP_IMAGE_CHECK=true shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  [ "$(env_state composer-dev)" = NOT_FOUND ]
}

@test "fails closed when the image-version API is unreachable" {
  touch "${FAKE_GCP_DIR}/curl-fail"
  shutdown_run
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not verify"* ]]
  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(env_state composer-test)" = RUNNING ]
}

@test "refuses to delete when the YAML would restore an older Airflow version" {
  set_env_field composer-test '.config.softwareConfig.imageVersion = "composer-3-airflow-2.10.5-build.20"'
  shutdown_run --env composer-test
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not load a snapshot"* ]]
  [ "$(env_state composer-test)" = RUNNING ]
}

# ── Startup failure handling ─────────────────────────────────────────────────

@test "a load that fails once is retried within the same run" {
  shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  add_op_fault 'snapshots load composer-dev' 'partially completed' 1
  startup_run --env composer-dev
  show_output
  [ "$status" -eq 0 ]
  [ "$(gcloud_calls | grep -c '"snapshots", "load", "composer-dev"')" = 2 ]
  [ "$(manifest_field composer-dev .status)" = ACTIVE ]
}

@test "a load that keeps failing leaves RESTORING; the next run loads without recreating" {
  shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  add_op_fault 'snapshots load composer-dev' 'load failed' 2
  startup_run --env composer-dev
  show_output
  [ "$status" -eq 1 ]
  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(manifest_field composer-dev .status)" = RESTORING ]
  local creates
  creates="$(tf_apply_count)"

  startup_run --env composer-dev
  show_output
  [ "$status" -eq 0 ]
  [ "$(tf_apply_count)" = "${creates}" ]
  [ "$(manifest_field composer-dev .status)" = ACTIVE ]
  [ "$(env_field composer-dev ._db)" = airflow-db-of-composer-dev ]
}

@test "environment created in ERROR is replaced and restored on the next run" {
  shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  FAKE_CREATE_STATE=ERROR startup_run --env composer-dev
  show_output
  [ "$status" -eq 1 ]
  [ "$(env_state composer-dev)" = ERROR ]
  [ "$(manifest_field composer-dev .status)" = RESTORING ]

  startup_run --env composer-dev
  show_output
  [ "$status" -eq 0 ]
  run jq -r '.resource_changes[] | select(.address == "'"${DEV_ADDR//\"/\\\"}"'") | .change.actions | join(",")' "${LAST_RUN}/plans/recreate.json"
  [ "$output" = "delete,create" ]
  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(manifest_field composer-dev .status)" = ACTIVE ]
  [ "$(env_field composer-dev ._db)" = airflow-db-of-composer-dev ]
}

@test "startup refuses to load into an older Airflow version" {
  shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  yaml_edit 'c["environments"]["composer-dev"]["software_config"] = {"image_version": "composer-3-airflow-2.9.3"}'
  startup_run --env composer-dev
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"only load into the same or a later Airflow version"* ]]
  ! gcloud_calls | grep -q '"snapshots", "load", "composer-dev"'
  [ "$(manifest_field composer-dev .status)" = RESTORING ]
}

@test "a shutdown during an incomplete restore keeps the good snapshot as restore point" {
  shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  local good
  good="$(manifest_field composer-dev .latest_snapshot.path)"
  add_op_fault 'snapshots load composer-dev' 'load failed' 2
  startup_run --env composer-dev
  [ "$status" -eq 1 ]
  # The (empty) environment is shut down again that evening.
  shutdown_run --env composer-dev
  show_output
  [ "$status" -eq 0 ]
  [ "$(manifest_field composer-dev .latest_snapshot.path)" = "${good}" ]
  [ "$(manifest_field composer-dev '.snapshots[0].restore_incomplete')" = true ]
  startup_run --env composer-dev
  [ "$status" -eq 0 ]
  [ "$(env_field composer-dev ._db)" = airflow-db-of-composer-dev ]
}

@test "startup refuses to create an environment Terraform has never deployed (wrong backend guard)" {
  shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  terraform -chdir="${TF_ROOT}" state list | grep -F 'module.composer["composer-dev"]' |
    xargs -d '\n' terraform -chdir="${TF_ROOT}" state rm >/dev/null
  startup_run --env composer-dev
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"--allow-initial-create"* ]]
  [ "$(env_state composer-dev)" = NOT_FOUND ]
}

@test "a manual deploy during the night is detected and the snapshot still loaded" {
  shutdown_run --env composer-dev
  [ "$status" -eq 0 ]
  # Someone runs the normal deploy pipeline while hibernated → fresh, empty env.
  terraform -chdir="${TF_ROOT}" plan -input=false -no-color -var config_file=configs/hibernation.yaml -out="${W}/manual.tfplan" >/dev/null
  terraform -chdir="${TF_ROOT}" apply "${W}/manual.tfplan" >/dev/null
  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(env_field composer-dev ._db)" = "" ]
  startup_run --env composer-dev
  show_output
  [ "$status" -eq 0 ]
  [ "$(env_field composer-dev ._db)" = airflow-db-of-composer-dev ]
  [ ! -f "${LAST_RUN}/plans/recreate.tfplan" ]
}

# ── Guard-rails and options ──────────────────────────────────────────────────

@test "production environments are refused even when named explicitly" {
  shutdown_run --env composer-prod
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"hibernation is not enabled"* ]]
  [ "$(env_state composer-prod)" = RUNNING ]
}

@test "enabling hibernation on production is a configuration error" {
  yaml_edit 'c["environments"]["composer-prod"]["hibernation"]["enabled"] = True'
  shutdown_run --env composer-prod
  show_output
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not be enabled for production"* ]]
  [ "$(env_state composer-prod)" = RUNNING ]
  ! gcloud_calls | grep -q 'composer-prod'
}

@test "unknown environment key is a usage error" {
  shutdown_run --env composer-typo
  [ "$status" -eq 2 ]
  [[ "$output" == *"not defined"* ]]
}

@test "dry-run shutdown changes nothing but runs the guarded plan" {
  shutdown_run --dry-run
  show_output
  [ "$status" -eq 0 ]
  [ "$(env_state composer-dev)" = RUNNING ]
  ! gcloud_calls | grep -Eq '"snapshots"|"cp"|"rm"|"create"|add-iam-policy-binding'
  [ "$(tf_apply_count)" = 0 ]
  [ -f "${LAST_RUN}/plans/destroy.json" ]
  [ "$(jq -r .dry_run "${LAST_RUN}/summary.json")" = true ]
  ! bucket_exists "${PROJECT}-composer-snapshots"
}

@test "dry-run startup changes nothing" {
  shutdown_run
  [ "$status" -eq 0 ]
  local applies
  applies="$(tf_apply_count)"
  startup_run --dry-run
  show_output
  [ "$status" -eq 0 ]
  [ "$(env_state composer-dev)" = NOT_FOUND ]
  [ "$(tf_apply_count)" = "${applies}" ]
  [ "$(manifest_field composer-dev .status)" = HIBERNATED ]
  run jq -r '[.resource_changes[] | select(.change.actions == ["create"]) | .address] | sort | join(" ")' "${LAST_RUN}/plans/recreate.json"
  [ "$output" = "${DEV_ADDR} ${TEST_ADDR}" ]
}

@test "HIBERNATE_ENVIRONMENTS, sequential mode and GitLab sections work" {
  HIBERNATE_ENVIRONMENTS=composer-test HIBERNATE_MAX_PARALLEL=1 GITLAB_CI=true CI_PIPELINE_ID=4242 shutdown_run
  show_output
  [ "$status" -eq 0 ]
  [ "$(env_state composer-dev)" = RUNNING ]
  [ "$(env_state composer-test)" = NOT_FOUND ]
  [[ "$output" == *"section_start:"*"snapshot: composer-test"* ]]
  [ "$(manifest_field composer-test '.history[0].pipeline.pipeline_id')" = 4242 ]
}

@test "config with no hibernating environments is a no-op" {
  yaml_edit 'c["hibernation"]["enabled"] = False'
  shutdown_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
  ! gcloud_calls | grep -q composer
}
