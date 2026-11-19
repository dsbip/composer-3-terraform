#!/usr/bin/env bash
# ============================================================================
# composer-startup.sh — restore hibernated Cloud Composer 3 environments
#
# For every selected environment of the YAML config (the same file the
# Terraform module consumes):
#   1. guard-rails  : hibernation.enabled, not production, valid settings
#   2. decide       : from the live environment state + hibernation-state.json
#                     (create+load / load / replace+load / nothing to do)
#   3. recreate     : ONE targeted `terraform apply` of the environments'
#                     google_composer_environment resources — built from the
#                     YAML exactly like a normal deployment. When the YAML
#                     leaves image_version unset, the Airflow version recorded
#                     at shutdown is pinned so the snapshot is compatible.
#                     A plan guard refuses anything but create/update inside
#                     the selected environments.
#   4. load         : gcloud composer environments snapshots load (Airflow
#                     database + dags/plugins/data). PyPI packages, env vars
#                     and Airflow overrides are skipped by default because
#                     Terraform already applied them from the YAML.
#   5. state file   : ACTIVE
#
# Re-running is safe: an interrupted restore stays RESTORING and is resumed.
# ============================================================================
set -Eeuo pipefail

# shellcheck source=SCRIPTDIR/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: composer-startup.sh --config configs/<file>.yaml [options]

Recreates (terraform, from the YAML) the hibernated Composer 3 environments
that have `hibernation.enabled: true` (or those given with --env) and loads
the snapshot saved by composer-shutdown.sh.

Startup-only options:
      --allow-initial-create
                           Allow creating an environment whose module has no
                           resources in the Terraform state yet (first ever
                           deployment). Without it such environments fail,
                           which protects against a misconfigured backend.
      --skip-load          Do not load snapshots: recreated environments start
                           empty, running ones are kept as they are; all are
                           marked ACTIVE (the next shutdown's snapshot then
                           becomes the restore point).
      --force-load         Load the snapshot even into an environment that has
                           been running for more than HIBERNATE_FRESH_ENV_HOURS
                           while the state file says it is hibernated
                           (overwrites its Airflow database).
EOF
  echo
  common_usage_options
}

ACTION_DIR=""
FALLBACK_JSON='{}'

# ── Phase 1: preflight (sequential, read-only) ──────────────────────────────
preflight() {
  local key="$1" state status has_snapshot action rc snapshot image pin
  info "[${key}] preflight"
  rm -f "${ACTION_DIR}/${key}" # only this run's decision drives it
  check_environment_eligible "${key}" || {
    result_set "${key}" failed "not eligible for hibernation (see log)"
    return 0
  }

  manifest_fetch "${key}" && rc=0 || rc=$?
  if ((rc != 0 && rc != HIB_RC_NOT_FOUND)); then
    result_set "${key}" failed "could not read the hibernation state file"
    return 0
  fi
  local manifest_found=true
  ((rc == 0)) || manifest_found=false
  status="$(manifest_get "${key}" .status)"
  snapshot="$(manifest_get "${key}" .latest_snapshot.path)"
  has_snapshot=false
  [[ -n "${snapshot}" ]] && has_snapshot=true

  state="$(settle_environment_state "${key}")" || {
    result_set "${key}" failed "could not determine the environment state"
    return 0
  }
  # For a running environment: is it the one that was snapshotted, how long
  # has it been running, and did an earlier load into it already finish?
  local recreated=false fresh=true done=false
  if [[ "${state}" == RUNNING ]]; then
    env_recreated_since_snapshot "${key}" && recreated=true
    env_is_fresh "${key}" || fresh=false
    [[ "${status}" == RESTORING && "$(restore_attempt_state "${key}")" == SUCCEEDED ]] && done=true
  fi
  # --skip-load / --force-load settle the "running for long" ambiguity.
  [[ "${OPT_SKIP_LOAD}" == true || "${OPT_FORCE_LOAD}" == true ]] && fresh=true
  action="$(decide_startup_action "${state}" "${status:-NONE}" "${has_snapshot}" "${recreated}" "${fresh}" "${done}")"
  if [[ "${OPT_SKIP_LOAD}" == true ]]; then
    case "${action}" in
    create_and_load) action=create_fresh ;;
    replace_and_load) action=replace_fresh ;;
    load) action=mark_active ;;
    esac
  fi
  info "[${key}] environment=${state} state-file=${status:-NONE} snapshot=${snapshot:-none} → ${action}"

  case "${action}" in
  create_and_load | create_fresh | replace_and_load | replace_fresh)
    if ! tf_module_in_state "${key}" && [[ "${OPT_ALLOW_INITIAL_CREATE}" != true ]]; then
      result_set "${key}" failed "no resources of $(tf_module_prefix "${key}") in the Terraform state — wrong backend? (use --allow-initial-create for a first deployment)"
      return 0
    fi
    # Deployed before, Composer resource gone (= hibernated) but no state
    # file: the restore point is elsewhere — most likely
    # hibernation.snapshot_bucket/snapshot_prefix changed while hibernated.
    if [[ "${action}" == create_fresh && "${manifest_found}" != true && "${OPT_ALLOW_INITIAL_CREATE}" != true ]] &&
      tf_module_in_state "${key}" && ! tf_resource_in_state "${key}"; then
      result_set "${key}" failed "no hibernation state file at $(setting "${key}" .hibernation.state_object) although $(tf_module_prefix "${key}") is deployed and its Composer environment is gone — was hibernation.snapshot_bucket/snapshot_prefix changed while hibernated? Move the old folder (state file + snapshots) there, or re-run with --allow-initial-create to create an empty environment"
      return 0
    fi
    if [[ "${action}" == replace_* ]] && ! check_state_identity "${key}"; then
      result_set "${key}" failed "the Terraform state and the YAML disagree on which environment this is (see log) — not replacing it"
      return 0
    fi
    [[ "${action}" == create_fresh && -z "${snapshot}" ]] &&
      warn "[${key}] no snapshot available: a fresh, empty environment will be created"
    if [[ "${action}" == create_and_load && "${status}" != HIBERNATED && "${status}" != RESTORING ]]; then
      warn "[${key}] the environment disappeared outside the hibernation cycle (state file: ${status:-NONE}); it is recreated from the last snapshot, taken $(manifest_get "${key}" .latest_snapshot.saved_at)"
    fi
    # Recreate on the snapshot's Airflow version when the YAML does not pin one.
    image="$(manifest_get "${key}" .latest_snapshot.image_version)"
    if [[ -z "$(setting "${key}" .image_version)" && "$(setting "${key}" .hibernation.pin_image_version)" == true && -n "${image}" && "${action}" == *_and_load ]]; then
      if pin="$(image_version_pin "${image}")"; then
        info "[${key}] pinning image version ${pin} (snapshot taken on ${image})"
        FALLBACK_JSON="$(jq -c --arg k "${key}" --arg v "${pin}" '.[$k] = $v' <<<"${FALLBACK_JSON}")"
      else
        warn "[${key}] unrecognised image version '${image}'; letting GCP pick the default"
      fi
    fi
    ;;
  load) ;;
  mark_active)
    if [[ "${OPT_DRY_RUN}" != true ]]; then
      manifest_transition "${key}" ACTIVE "environment running; no restore needed (${status:-NONE})" || true
    fi
    result_set "${key}" ok "environment is running; no restore needed"
    return 0
    ;;
  mark_restored)
    if [[ "${OPT_DRY_RUN}" != true ]]; then
      manifest_update "${key}" '.last_restore = {snapshot: $s, at: $t, image_version: $i, operation: $op}' \
        --arg s "${snapshot}" --arg t "$(_ts)" --arg i "$(describe_get "${key}" .config.softwareConfig.imageVersion)" \
        --arg op "$(manifest_get "${key}" .restore_attempt.operation)"
      manifest_transition "${key}" ACTIVE "snapshot load had already completed: ${snapshot}" || {
        result_set "${key}" failed "could not update the state file"
        return 0
      }
    fi
    result_set "${key}" ok "the earlier load of ${snapshot} had completed; marked ACTIVE (not loaded again)"
    return 0
    ;;
  refuse_stale)
    result_set "${key}" failed "environment has been running since $(describe_get "${key}" .createTime) (over ${HIBERNATE_FRESH_ENV_HOURS}h) although the state file says ${status}; loading ${snapshot} would overwrite its Airflow database — re-run with --skip-load to keep it as it is, or with --force-load to replace it with the snapshot"
    return 0
    ;;
  noop)
    result_set "${key}" skipped "already running"
    return 0
    ;;
  error:*)
    result_set "${key}" failed "${action#error:}"
    return 0
    ;;
  esac
  printf '%s\n' "${action}" >"${ACTION_DIR}/${key}"
}

# ── Phase 3: load snapshots (parallel, one sub-shell per environment) ───────
restore_env() {
  local key="$1" action name region project state snapshot sa opts image
  action="$(cat "${ACTION_DIR}/${key}")"
  name="$(setting "${key}" .environment_name)"
  region="$(setting "${key}" .region)"
  project="$(setting "${key}" .project_id)"
  snapshot="$(manifest_get "${key}" .latest_snapshot.path)"

  if [[ "${OPT_DRY_RUN}" == true ]]; then
    case "${action}" in
    *_and_load | load) result_set "${key}" ok "dry-run: would ${action//_/ } from ${snapshot}" ;;
    *) result_set "${key}" ok "dry-run: would ${action//_/ }" ;;
    esac
    return 0
  fi

  state="$(settle_environment_state "${key}")" || state=UNKNOWN
  if [[ "${state}" != RUNNING ]]; then
    result_set "${key}" failed "environment is ${state} (expected RUNNING); snapshot not loaded — re-run startup to retry"
    return 0
  fi

  sa="$(describe_get "${key}" .config.nodeConfig.serviceAccount)"
  [[ -n "${sa}" ]] || sa="$(setting "${key}" .service_account_email)"
  image="$(describe_get "${key}" .config.softwareConfig.imageVersion)"

  case "${action}" in
  create_fresh | replace_fresh)
    if ensure_snapshot_bucket "${key}" "${sa}" create && manifest_transition "${key}" ACTIVE "environment created without loading a snapshot"; then
      result_set "${key}" ok "environment created (${image}); no snapshot loaded"
    else
      result_set "${key}" ok "environment created (${image}); WARNING: hibernation state file not updated"
    fi
    return 0
    ;;
  esac

  # Snapshots load only into the same or a later Airflow version (same major).
  local snap_image
  snap_image="$(manifest_get "${key}" .latest_snapshot.image_version)"
  if [[ -n "${snap_image}" ]] && ! airflow_version_satisfies "$(airflow_version_of "${image}")" "$(airflow_version_of "${snap_image}")"; then
    # A re-run alone does not help: startup does not touch a running
    # environment's image. Upgrade it (deploy) or delete it first.
    result_set "${key}" failed "environment runs ${image:-an unknown image} but the snapshot was taken on ${snap_image}; snapshots only load into the same or a later Airflow version — set software_config.image_version to a compatible version, apply it with the normal deploy (in-place upgrade) or delete the environment, then re-run startup"
    return 0
  fi

  # Load: the snapshot bucket must already exist; never create it here.
  ensure_snapshot_bucket "${key}" "${sa}" no-create || {
    result_set "${key}" failed "snapshot bucket unusable; snapshot not loaded"
    return 0
  }
  if ! retry snapshot_is_complete "${snapshot}"; then
    result_set "${key}" failed "snapshot ${snapshot} is missing or has no Airflow database dump; snapshot not loaded"
    return 0
  fi
  if [[ "$(manifest_get "${key}" .status)" != RESTORING ]]; then
    manifest_transition "${key}" RESTORING "loading snapshot ${snapshot}" || {
      result_set "${key}" failed "could not update the state file; snapshot not loaded"
      return 0
    }
  fi
  opts="$(setting "${key}" .hibernation.load_options)"
  # A load an earlier run started (and gave up waiting for) may still be
  # running: wait for it instead of starting a second one.
  local loaded=false attempt_op
  if [[ "$(restore_attempt_state "${key}")" == RUNNING ]]; then
    attempt_op="$(manifest_get "${key}" .restore_attempt.operation)"
    info "[${key}] the snapshot load started earlier (${attempt_op##*/}) is still running; waiting for it"
    wait_for_operation "${attempt_op}" "${region}" "${project}" "snapshot load into ${name}" >/dev/null && loaded=true
    [[ "${loaded}" == true ]] || wait_for_composer_state "${name}" "${region}" "${project}" RUNNING,ERROR >/dev/null || true
  fi
  if [[ "${loaded}" != true ]] &&
    ! composer_snapshot_load "${name}" "${region}" "${project}" "${snapshot}" "${opts}" record_restore_attempt "${key}" "${snapshot}"; then
    result_set "${key}" failed "snapshot load failed (state stays RESTORING; re-run startup to retry — a load that still finishes server-side is recognised)"
    return 0
  fi
  manifest_update "${key}" '.last_restore = {snapshot: $s, at: $t, image_version: $i, load_options: $o}' \
    --arg s "${snapshot}" --arg t "$(_ts)" --arg i "${image}" --argjson o "${opts}"
  if ! manifest_transition "${key}" ACTIVE "snapshot loaded: ${snapshot}"; then
    result_set "${key}" failed "snapshot loaded but the state file could not be updated; re-run startup (it recognises the completed load and only marks the environment ACTIVE)"
    return 0
  fi
  result_set "${key}" ok "restored from ${snapshot} (${image})"
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
  parse_common_args startup "$@"
  require_cmds terraform gcloud jq realpath comm awk
  init_work_dir startup
  ACTION_DIR="${OPT_WORK_DIR}/actions"
  [[ "${OPT_DRY_RUN}" == true ]] && warn "DRY RUN — nothing will be changed"

  resolve_config
  local keys=() key selection
  selection="$(select_environments)" || exit "${HIB_EXIT_USAGE}"
  [[ -z "${selection}" ]] || mapfile -t keys <<<"${selection}"
  if ((${#keys[@]} == 0)); then
    info "no environment in ${CONFIG_REL} has hibernation enabled; nothing to do"
    finish_summary startup
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

  local tf_keys=() work_keys=() plan_args=() prefixes=() replaceable=""
  for key in "${keys[@]}"; do
    [[ -f "${ACTION_DIR}/${key}" ]] || continue
    work_keys+=("${key}")
    case "$(cat "${ACTION_DIR}/${key}")" in
    # The whole module instance is targeted (not just the Composer resource):
    # resource-level targets pull in the same-named dependencies of EVERY
    # environment, so pending changes elsewhere (even production) would leak
    # into this plan. Module-instance targets keep it to this environment.
    create_and_load | create_fresh)
      tf_keys+=("${key}")
      plan_args+=(-target="$(tf_module_prefix "${key}")")
      ;;
    replace_and_load | replace_fresh)
      tf_keys+=("${key}")
      plan_args+=(-target="$(tf_module_prefix "${key}")" -replace="$(tf_address "${key}")")
      replaceable+=" $(tf_address "${key}")"
      ;;
    esac
  done

  if ((${#tf_keys[@]})); then
    section_start recreate "Recreate environments (terraform)"
    if [[ "${OPT_DRY_RUN}" != true ]]; then
      for key in "${tf_keys[@]}"; do
        # An interrupted restore is resumed by the next run (RESTORING).
        if [[ -n "$(manifest_get "${key}" .latest_snapshot.path)" && "$(cat "${ACTION_DIR}/${key}")" == *_and_load ]]; then
          manifest_transition "${key}" RESTORING "recreating environment with terraform" ||
            warn "[${key}] could not mark the state file RESTORING"
        fi
      done
    fi
    local tfvars="${OPT_WORK_DIR}/fallback-image-versions.tfvars.json"
    jq -n --argjson m "${FALLBACK_JSON}" '{fallback_image_versions: $m}' >"${tfvars}"
    plan_args+=(-var-file="${tfvars}")
    for key in "${tf_keys[@]}"; do
      prefixes+=("$(tf_module_prefix "${key}")")
    done

    local tf_ok=true
    if ! tf_plan recreate "${plan_args[@]}"; then
      tf_ok=false
    elif ! guard_create_plan "${OPT_WORK_DIR}/plans/recreate.json" "${replaceable}" "${prefixes[@]}"; then
      tf_ok=false
    else
      for key in "${tf_keys[@]}"; do
        case "$(cat "${ACTION_DIR}/${key}")" in
        replace_*)
          plan_must_contain "${OPT_WORK_DIR}/plans/recreate.json" "$(tf_address "${key}")" "delete,create|create,delete" || tf_ok=false
          plan_deletes_identity "${OPT_WORK_DIR}/plans/recreate.json" "$(tf_address "${key}")" "$(settings_identity "${key}")" ||
            tf_ok=false
          ;;
        *) plan_must_contain "${OPT_WORK_DIR}/plans/recreate.json" "$(tf_address "${key}")" create || tf_ok=false ;;
        esac
      done
    fi
    if [[ "${tf_ok}" != true ]]; then
      :
    elif [[ "${OPT_DRY_RUN}" == true ]]; then
      info "(dry-run) plan: $(plan_changes "${OPT_WORK_DIR}/plans/recreate.json" | tr '\t\n' ' ;')"
    elif ! tf_apply_plan recreate; then
      tf_ok=false # environments that did come up are still loaded below
    fi
    section_end recreate
    if [[ "${tf_ok}" != true && "${OPT_DRY_RUN}" == true ]]; then
      for key in "${tf_keys[@]}"; do
        result_set "${key}" failed "dry-run: terraform plan or plan guard failed"
      done
    fi
    if [[ "${tf_ok}" != true ]]; then
      warn "terraform did not complete; environments that are not RUNNING will be reported as failed"
    fi
  fi

  local load_keys=()
  for key in "${work_keys[@]}"; do
    has_result "${key}" || load_keys+=("${key}")
  done
  if ((${#load_keys[@]})); then
    run_parallel restore restore_env "${load_keys[@]}"
  fi

  finish_summary startup "${keys[@]}"
}

main "$@"
