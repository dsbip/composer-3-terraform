#!/usr/bin/env bash
# ============================================================================
# composer-shutdown.sh — hibernate non-production Cloud Composer 3 environments
#
# For every selected environment of the YAML config (the same file the
# Terraform module consumes):
#   1. guard-rails  : hibernation.enabled, not production, valid settings,
#                     environment managed by this Terraform state
#   2. snapshot     : gcloud composer environments snapshots save  →
#                     <snapshot_location>/<generated folder>  (verified)
#   3. state file   : <snapshot_location>/hibernation-state.json = SNAPSHOT_SAVED
#   4. delete       : ONE targeted `terraform destroy` of only the
#                     google_composer_environment resources (network, service
#                     account, IAM, KMS stay), protected by a plan guard
#   5. state file   : HIBERNATED
#   6. housekeeping : delete the orphaned auto-created environment bucket
#                     (optional) and prune snapshots beyond the retention count
#
# An environment is never deleted unless its snapshot was saved and verified.
# Re-running is safe: every step is idempotent and driven by the state file.
#
# Restore with composer-startup.sh.
# ============================================================================
set -Eeuo pipefail

# shellcheck source=SCRIPTDIR/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: composer-shutdown.sh --config configs/<file>.yaml [options]

Snapshots and then deletes the Composer 3 environments that have
`hibernation.enabled: true` in the YAML config (or those given with --env).

Shutdown-only options:
      --force-delete-without-snapshot
                           Delete environments in ERROR state even though they
                           cannot be snapshotted (startup restores the previous
                           snapshot, if any).
EOF
  echo
  common_usage_options
}

ACTION_DIR=""

# ── Phase 1: preflight (sequential, read-only) ──────────────────────────────
preflight() {
  local key="$1" state status has_snapshot action rc
  info "[${key}] preflight"
  check_environment_eligible "${key}" || {
    result_set "${key}" failed "not eligible for hibernation (see log)"
    return 0
  }

  manifest_fetch "${key}" && rc=0 || rc=$?
  if ((rc != 0 && rc != HIB_RC_NOT_FOUND)); then
    result_set "${key}" failed "could not read the hibernation state file"
    return 0
  fi
  status="$(manifest_get "${key}" .status)"
  has_snapshot=false
  [[ -n "$(manifest_get "${key}" .latest_snapshot.path)" ]] && has_snapshot=true

  state="$(settle_environment_state "${key}")" || {
    result_set "${key}" failed "could not determine the environment state"
    return 0
  }
  action="$(decide_shutdown_action "${state}" "${status:-NONE}" "${has_snapshot}" "${OPT_FORCE_NO_SNAPSHOT}")"
  info "[${key}] environment=${state} state-file=${status:-NONE} snapshot-available=${has_snapshot} → ${action}"

  case "${action}" in
  snapshot_and_delete | delete_only)
    if ! tf_resource_in_state "${key}"; then
      result_set "${key}" failed "environment exists but $(tf_address "${key}") is not in the Terraform state (wrong backend/state?) — not touching it"
      return 0
    fi
    # Never delete what cannot be brought back tomorrow: the restore image
    # must still be creatable and able to load the snapshot.
    local current reason
    current="$(describe_get "${key}" .config.softwareConfig.imageVersion)"
    [[ "${action}" == delete_only ]] && current="$(manifest_get "${key}" .latest_snapshot.image_version)"
    if ! reason="$(check_restorable "${key}" "${current}")"; then
      result_set "${key}" failed "not deleting: ${reason}"
      return 0
    fi
    ;;
  mark_hibernated)
    if [[ "${OPT_DRY_RUN}" != true ]]; then
      handle_orphaned_buckets "${key}" false
      manifest_transition "${key}" HIBERNATED "environment already absent; latest snapshot kept for restore" ||
        {
          result_set "${key}" failed "could not update the state file"
          return 0
        }
    fi
    result_set "${key}" ok "environment already absent; marked HIBERNATED (restore: $(manifest_get "${key}" .latest_snapshot.path))"
    return 0
    ;;
  noop_hibernated)
    if [[ "${OPT_DRY_RUN}" != true ]] && [[ "$(manifest_get "${key}" '.orphaned_buckets | length')" != 0 ]]; then
      handle_orphaned_buckets "${key}" false
      manifest_push "${key}" || true
    fi
    result_set "${key}" skipped "already hibernated"
    return 0
    ;;
  noop_missing)
    result_set "${key}" skipped "environment does not exist and has no snapshot; nothing to hibernate"
    return 0
    ;;
  error:*)
    result_set "${key}" failed "${action#error:}"
    return 0
    ;;
  esac
  printf '%s\n' "${action}" >"${ACTION_DIR}/${key}"
}

# ── Phase 2: snapshot (parallel, one sub-shell per environment) ─────────────
snapshot_env() {
  local key="$1"
  local name region project location sa image bucket dag_prefix path status restore_incomplete entry
  name="$(setting "${key}" .environment_name)"
  region="$(setting "${key}" .region)"
  project="$(setting "${key}" .project_id)"
  location="$(setting "${key}" .hibernation.snapshot_location)"
  sa="$(describe_get "${key}" .config.nodeConfig.serviceAccount)"
  [[ -n "${sa}" ]] || sa="$(setting "${key}" .service_account_email)"
  image="$(describe_get "${key}" .config.softwareConfig.imageVersion)"
  dag_prefix="$(describe_get "${key}" .config.dagGcsPrefix)"
  bucket="$(describe_get "${key}" .storageConfig.bucket)"
  [[ -n "${bucket}" ]] || bucket="$(bucket_from_gcs_uri "${dag_prefix}")"

  if [[ "${OPT_DRY_RUN}" == true ]]; then
    info "[${key}] (dry-run) would save a snapshot of ${name} (${image:-unknown image}) to ${location}/"
    phase_ok "${key}" snapshot
    return 0
  fi

  ensure_snapshot_bucket "${key}" "${sa}" || {
    result_set "${key}" failed "snapshot bucket not usable; environment NOT deleted"
    return 0
  }

  info "[${key}] saving snapshot of ${name} to ${location}/"
  path="$(composer_snapshot_save "${name}" "${region}" "${project}" "${location}")" || {
    result_set "${key}" failed "snapshot save failed; environment NOT deleted"
    return 0
  }
  if ! retry snapshot_is_complete "${path}"; then
    result_set "${key}" failed "snapshot ${path} has no Airflow database dump (*.sql.gz); environment NOT deleted"
    return 0
  fi
  info "[${key}] snapshot verified: ${path}"

  # A snapshot taken while a restore is still incomplete (state RESTORING)
  # must not replace the last good snapshot as the restore point.
  status="$(manifest_get "${key}" .status)"
  restore_incomplete=false
  if [[ "${status}" == RESTORING && -n "$(manifest_get "${key}" .latest_snapshot.path)" ]]; then
    restore_incomplete=true
    warn "[${key}] the previous restore never completed; keeping $(manifest_get "${key}" .latest_snapshot.path) as the restore point and recording ${path} as a secondary snapshot"
  fi

  entry="$(jq -n --arg path "${path}" --arg at "$(_ts)" --arg image "${image}" \
    --arg airflow "$(airflow_version_of "${image}")" --arg bucket "${bucket}" \
    --arg dags "${dag_prefix}" --arg sa "${sa}" --argjson incomplete "${restore_incomplete}" \
    '{path: $path, saved_at: $at, image_version: $image, airflow_version: $airflow,
      environment_bucket: $bucket, dag_gcs_prefix: $dags, service_account: $sa,
      restore_incomplete: $incomplete}')"
  if [[ "${restore_incomplete}" == true ]]; then
    manifest_update "${key}" '.snapshots = ([$e] + (.snapshots // []))' --argjson e "${entry}"
  else
    manifest_update "${key}" '.latest_snapshot = $e | .snapshots = ([$e] + (.snapshots // []))' --argjson e "${entry}"
  fi
  manifest_transition "${key}" SNAPSHOT_SAVED "snapshot saved: ${path}" || {
    result_set "${key}" failed "could not record the snapshot in the state file; environment NOT deleted"
    return 0
  }
  phase_ok "${key}" snapshot
}

# ── Phase 4 helpers ─────────────────────────────────────────────────────────
# handle_orphaned_buckets KEY RECORD
# Deleting a Composer environment leaves its auto-created bucket behind (and a
# restore creates a new one). With RECORD=true the bucket of the environment
# just deleted is recorded; recorded buckets older than
# hibernation.orphaned_bucket_retention_days are deleted (their dags/, plugins/
# and data/ are in the snapshot; the grace period keeps task logs around).
handle_orphaned_buckets() {
  local key="$1" record="$2" bucket region name snap_bucket custom days now orphaned_epoch err
  [[ "$(setting "${key}" .hibernation.delete_orphaned_bucket)" == true ]] || return 0
  custom="$(setting "${key}" .custom_bucket)"
  if [[ "${record}" == true ]]; then
    if [[ -n "${custom}" ]]; then
      info "[${key}] environment uses storage.bucket ${custom}; it is reused on restore and kept"
    else
      bucket="$(describe_get "${key}" .storageConfig.bucket)"
      [[ -n "${bucket}" ]] || bucket="$(bucket_from_gcs_uri "$(describe_get "${key}" .config.dagGcsPrefix)")"
      region="$(setting "${key}" .region)"
      name="$(setting "${key}" .environment_name)"
      snap_bucket="$(setting "${key}" .hibernation.snapshot_bucket)"
      if is_safe_orphan_bucket "${bucket}" "${region}" "${name}" "${snap_bucket}" "${custom}"; then
        manifest_update "${key}" '.orphaned_buckets = ((.orphaned_buckets // []) | map(select(.bucket != $b)))
            + [{bucket: $b, orphaned_at: $t, orphaned_epoch: $e}]' \
          --arg b "${bucket}" --arg t "$(_ts)" --argjson e "$(now_epoch)"
      else
        warn "[${key}] not scheduling bucket '${bucket:-<unknown>}' for deletion: it does not look like this environment's auto-created bucket"
      fi
    fi
  fi

  days="$(setting "${key}" .hibernation.orphaned_bucket_retention_days)"
  now="$(now_epoch)"
  err="${OPT_WORK_DIR}/logs/${key}-bucket-delete.log"
  while IFS=$'\t' read -r bucket orphaned_epoch; do
    [[ -n "${bucket}" ]] || continue
    if ((now - orphaned_epoch < days * 86400)); then
      info "[${key}] keeping orphaned bucket gs://${bucket} for $(((days * 86400 - (now - orphaned_epoch) + 86399) / 86400)) more day(s)"
      continue
    fi
    info "[${key}] deleting orphaned environment bucket gs://${bucket}"
    if gcloud storage rm --recursive "gs://${bucket}" --quiet >/dev/null 2>"${err}" || is_not_found_error "$(cat "${err}")"; then
      manifest_update "${key}" '.orphaned_buckets = [.orphaned_buckets[] | select(.bucket != $b)]' --arg b "${bucket}"
    else
      warn "[${key}] could not delete gs://${bucket} (see logs/${key}-bucket-delete.log); will retry next time"
    fi
  done < <(jq -r '.orphaned_buckets[]? | "\(.bucket)\t\(.orphaned_epoch)"' "$(manifest_local_path "${key}")")
}

prune_snapshots() {
  local key="$1" keep latest path
  keep="$(setting "${key}" .hibernation.snapshot_retention_count)"
  latest="$(manifest_get "${key}" .latest_snapshot.path)"
  # Never prune the restore point, whatever its position in the list.
  while IFS= read -r path; do
    [[ -n "${path}" && "${path}" != "${latest}" ]] || continue
    info "[${key}] pruning snapshot ${path} (retention: ${keep})"
    if retry gcs_delete_prefix "${path}"; then
      manifest_update "${key}" '.snapshots = [.snapshots[] | select(.path != $p)]' --arg p "${path}"
    else
      warn "[${key}] could not delete ${path}; will retry next time"
    fi
  done < <(jq -r --argjson keep "${keep}" --arg latest "${latest}" \
    '[.snapshots[]? | select(.path != $latest)] | .[($keep - 1 | if . < 0 then 0 else . end):][] | .path' \
    "$(manifest_local_path "${key}")")
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
  parse_common_args shutdown "$@"
  require_cmds terraform gcloud jq realpath comm awk
  init_work_dir shutdown
  ACTION_DIR="${OPT_WORK_DIR}/actions"
  mkdir -p "${ACTION_DIR}"
  [[ "${OPT_DRY_RUN}" == true ]] && warn "DRY RUN — nothing will be changed"

  resolve_config
  local keys=() key selection
  selection="$(select_environments)" || exit "${HIB_EXIT_USAGE}"
  [[ -z "${selection}" ]] || mapfile -t keys <<<"${selection}"
  if ((${#keys[@]} == 0)); then
    info "no environment in ${CONFIG_REL} has hibernation enabled; nothing to do"
    finish_summary shutdown
    return
  fi
  info "environments: ${keys[*]}"

  build_tf_common_args
  tf_init
  tf_state_load

  section_start preflight "Preflight"
  for key in "${keys[@]}"; do
    preflight "${key}"
  done
  section_end preflight

  local snap_keys=() delete_keys=() targets=()
  for key in "${keys[@]}"; do
    [[ -f "${ACTION_DIR}/${key}" ]] || continue
    case "$(cat "${ACTION_DIR}/${key}")" in
    snapshot_and_delete) snap_keys+=("${key}") ;;
    delete_only)
      warn "[${key}] deleting WITHOUT a snapshot (--force-delete-without-snapshot)"
      delete_keys+=("${key}")
      ;;
    esac
  done

  if ((${#snap_keys[@]})); then
    run_parallel snapshot snapshot_env "${snap_keys[@]}"
    for key in "${snap_keys[@]}"; do
      phase_done "${key}" snapshot && delete_keys+=("${key}")
    done
  fi

  if ((${#delete_keys[@]})); then
    section_start delete "Delete environments (terraform)"
    local plan_args=(-destroy)
    for key in "${delete_keys[@]}"; do
      targets+=("$(tf_address "${key}")")
      plan_args+=(-target="$(tf_address "${key}")")
    done
    local tf_ok=true
    if ! tf_plan destroy "${plan_args[@]}"; then
      tf_ok=false
    elif ! guard_destroy_plan "${OPT_WORK_DIR}/plans/destroy.json" "${targets[@]}"; then
      tf_ok=false
    else
      for key in "${delete_keys[@]}"; do
        plan_must_contain "${OPT_WORK_DIR}/plans/destroy.json" "$(tf_address "${key}")" delete || tf_ok=false
      done
    fi
    if [[ "${tf_ok}" != true ]]; then
      :
    elif [[ "${OPT_DRY_RUN}" == true ]]; then
      info "(dry-run) plan: $(plan_changes "${OPT_WORK_DIR}/plans/destroy.json" | tr '\t\n' ' ;')"
    elif ! tf_apply_plan destroy; then
      # Some environments may have been deleted before the failure; phase 4
      # checks each one individually.
      tf_ok=false
    fi
    section_end delete

    section_start finalize "Finalize"
    local name region project state
    for key in "${delete_keys[@]}"; do
      if [[ "${OPT_DRY_RUN}" == true ]]; then
        if [[ "${tf_ok}" == true ]]; then
          result_set "${key}" ok "dry-run: would snapshot to $(setting "${key}" .hibernation.snapshot_location)/ and delete $(tf_address "${key}")"
        else
          result_set "${key}" failed "dry-run: terraform plan or plan guard failed"
        fi
        continue
      fi
      name="$(setting "${key}" .environment_name)"
      region="$(setting "${key}" .region)"
      project="$(setting "${key}" .project_id)"
      state="$(composer_state "${name}" "${region}" "${project}")" || state=UNKNOWN
      if [[ "${state}" == DELETING ]]; then
        state="$(wait_for_composer_state "${name}" "${region}" "${project}" NOT_FOUND,ERROR)" || true
      fi
      if [[ "${state}" != NOT_FOUND ]]; then
        local why="terraform destroy did not remove it"
        [[ "${tf_ok}" == true ]] || why="terraform plan/guard/apply failed — see the delete section"
        result_set "${key}" failed "environment still exists (${state}): ${why}; snapshot is safe at $(manifest_get "${key}" .latest_snapshot.path)"
        continue
      fi
      if [[ -n "$(manifest_get "${key}" .latest_snapshot.path)" ]]; then
        # After a forced delete the bucket holds newer DAGs than the (older)
        # restore point, so it is kept for manual recovery.
        if [[ "$(cat "${ACTION_DIR}/${key}")" == delete_only ]]; then
          warn "[${key}] forced delete: keeping the environment bucket for manual recovery"
          handle_orphaned_buckets "${key}" false
        else
          handle_orphaned_buckets "${key}" true
        fi
        prune_snapshots "${key}"
        if ! manifest_transition "${key}" HIBERNATED "environment deleted"; then
          result_set "${key}" failed "environment deleted but the state file could not be updated (status stays SNAPSHOT_SAVED; startup still restores it)"
          continue
        fi
        result_set "${key}" ok "hibernated; restore point $(manifest_get "${key}" .latest_snapshot.path)"
      else
        # No snapshot was ever taken, so the bucket holding the state file may
        # not exist yet; the record is informative only (startup creates a
        # fresh environment either way).
        local sa
        sa="$(describe_get "${key}" .config.nodeConfig.serviceAccount)"
        if ensure_snapshot_bucket "${key}" "${sa}" create &&
          manifest_transition "${key}" HIBERNATED "environment deleted without a snapshot (forced)"; then
          result_set "${key}" ok "deleted without snapshot (forced); startup will create a fresh environment"
        else
          result_set "${key}" ok "deleted without snapshot (forced); WARNING: hibernation state file not written"
        fi
      fi
    done
    section_end finalize
  fi

  finish_summary shutdown "${keys[@]}"
}

main "$@"
