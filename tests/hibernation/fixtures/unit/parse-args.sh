#!/usr/bin/env bash
# Helper for tests/hibernation/unit.bats: runs parse_common_args MODE ARGS...
# in a shell configured like the hibernation scripts (set -Eeuo pipefail, lib
# sourced at top level, a usage() function defined) and prints the parsed
# options, one per line. die() exits this process, so callers see its status.
set -Eeuo pipefail

# shellcheck source=SCRIPTDIR/../../../../scripts/hibernation/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../../scripts/hibernation/lib/common.sh"

usage() { echo "usage: dummy usage text"; }

join_by_pipe() {
  local IFS='|'
  printf '%s' "$*"
}

parse_common_args "$@"

printf 'config=%s\n' "${OPT_CONFIG}"
printf 'envs=%s\n' "$(join_by_pipe "${OPT_ENVS[@]}")"
printf 'env_count=%s\n' "${#OPT_ENVS[@]}"
printf 'dry_run=%s\n' "${OPT_DRY_RUN}"
printf 'skip_init=%s\n' "${OPT_SKIP_INIT}"
printf 'work_dir=%s\n' "${OPT_WORK_DIR}"
printf 'var_files=%s\n' "$(join_by_pipe "${OPT_VAR_FILES[@]}")"
printf 'force_no_snapshot=%s\n' "${OPT_FORCE_NO_SNAPSHOT}"
printf 'allow_initial_create=%s\n' "${OPT_ALLOW_INITIAL_CREATE}"
printf 'skip_load=%s\n' "${OPT_SKIP_LOAD}"
printf 'force_load=%s\n' "${OPT_FORCE_LOAD}"
