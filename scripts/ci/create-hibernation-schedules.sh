#!/usr/bin/env bash
# ============================================================================
# Creates or updates the two GitLab pipeline schedules that drive Composer
# hibernation (pipelines/composer-hibernation.yml) through the REST API v4:
#
#   "<prefix>: shutdown"  SHUTDOWN_CRON  HIBERNATE_ACTION=shutdown
#   "<prefix>: startup"   STARTUP_CRON   HIBERNATE_ACTION=startup
#   (+ HIBERNATE_ENVIRONMENTS=<ENVIRONMENTS> on both when ENVIRONMENTS is set)
#
# Idempotent: schedules are matched by description, created when missing and
# updated only when they differ; a second run makes no changes. The token is
# handed to curl on stdin (-K -), never on a command line.
#
# Run with --help for the options.
# ============================================================================
set -euo pipefail

PROG="$(basename "$0")"

usage() {
  cat <<EOF
Usage: ${PROG} [options]

Creates/updates the GitLab pipeline schedules "<prefix>: shutdown" and
"<prefix>: startup" (with HIBERNATE_ACTION=shutdown|startup) used by
pipelines/composer-hibernation.yml. Safe to re-run.

Options (each also settable through the environment variable shown):
  --api-url URL            GITLAB_API_URL      GitLab API v4 base URL
                                               (default: \$CI_API_V4_URL)
  --token-file FILE        GITLAB_TOKEN        read the API token from FILE
                                               ('-' = stdin). GITLAB_TOKEN is
                                               required; there is deliberately
                                               no --token flag (command lines
                                               are visible to other users).
                                               Needs scope 'api' and the
                                               Maintainer role. Schedules are
                                               owned by (run as) its user.
  --project ID|PATH        PROJECT_ID          numeric id or 'group/project'
                                               (default: \$CI_PROJECT_ID)
  --ref REF                REF                 branch the schedules run on
                                               (default: main)
  --timezone TZ            TIMEZONE            cron timezone
                                               (default: Europe/London)
  --shutdown-cron CRON     SHUTDOWN_CRON       default: '0 19 * * 1-5'
  --startup-cron CRON      STARTUP_CRON        default: '0 7 * * 1-5'
  --environments LIST      ENVIRONMENTS        sets the schedule variable
                                               HIBERNATE_ENVIRONMENTS=LIST on
                                               both schedules; when empty an
                                               existing one is deleted
  --description-prefix P   DESCRIPTION_PREFIX  default: 'Composer hibernation'
  --resource-group KEY     RESOURCE_GROUP      default: composer-hibernation-dev
  --set-resource-group-mode                    also set the resource group's
                                               process_mode to oldest_first
                                               (it exists only after the jobs
                                               have run once)
  --dry-run                                    only read; print what would
                                               change
  -h, --help                                   show this help

Exit status: 0 success, 1 API/HTTP error, 2 usage/validation error.

Example:
  GITLAB_API_URL=https://gitlab.example.com/api/v4 GITLAB_TOKEN=<token> \\
  PROJECT_ID=group/composer-3-terraform ${PROG} --set-resource-group-mode
EOF
}

# ── Logging ─────────────────────────────────────────────────────────────────
log() { printf '%s: %s\n' "$1" "${*:2}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() { log ERROR "$@"; }
usage_error() {
  error "$@"
  echo "Run '${PROG} --help' for usage." >&2
  exit 2
}

# ── Inputs ──────────────────────────────────────────────────────────────────
GITLAB_API_URL="${GITLAB_API_URL:-${CI_API_V4_URL:-}}"
PROJECT_ID="${PROJECT_ID:-${CI_PROJECT_ID:-}}"
REF="${REF:-main}"
TIMEZONE="${TIMEZONE:-Europe/London}"
SHUTDOWN_CRON="${SHUTDOWN_CRON:-0 19 * * 1-5}"
STARTUP_CRON="${STARTUP_CRON:-0 7 * * 1-5}"
ENVIRONMENTS="${ENVIRONMENTS:-}"
DESCRIPTION_PREFIX="${DESCRIPTION_PREFIX:-Composer hibernation}"
RESOURCE_GROUP="${RESOURCE_GROUP:-composer-hibernation-dev}"
DRY_RUN=false
SET_RG_MODE=false
TOKEN_FILE=""

# Keep the token in a non-exported variable only, so neither curl nor jq
# inherit it through their environment either.
TOKEN="${GITLAB_TOKEN:-}"
unset GITLAB_TOKEN

opt_var() {
  case "$1" in
  --api-url) echo GITLAB_API_URL ;;
  --token-file) echo TOKEN_FILE ;;
  --project) echo PROJECT_ID ;;
  --ref) echo REF ;;
  --timezone) echo TIMEZONE ;;
  --shutdown-cron) echo SHUTDOWN_CRON ;;
  --startup-cron) echo STARTUP_CRON ;;
  --environments) echo ENVIRONMENTS ;;
  --description-prefix) echo DESCRIPTION_PREFIX ;;
  --resource-group) echo RESOURCE_GROUP ;;
  *) return 1 ;;
  esac
}

while (($#)); do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --dry-run) DRY_RUN=true ;;
  --set-resource-group-mode) SET_RG_MODE=true ;;
  --token | --token=*)
    usage_error "--token is not supported (it would expose the token in the process list); use GITLAB_TOKEN or --token-file"
    ;;
  --*=*)
    var="$(opt_var "${1%%=*}")" || usage_error "unknown option: ${1%%=*}"
    printf -v "${var}" '%s' "${1#*=}"
    ;;
  --*)
    var="$(opt_var "$1")" || usage_error "unknown option: $1"
    (($# >= 2)) || usage_error "option $1 needs a value"
    printf -v "${var}" '%s' "$2"
    shift
    ;;
  *) usage_error "unexpected argument: $1" ;;
  esac
  shift
done

for c in curl jq; do
  command -v "${c}" >/dev/null 2>&1 || usage_error "required command not found on PATH: ${c}"
done

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

if [[ -n "${TOKEN_FILE}" ]]; then
  if [[ "${TOKEN_FILE}" == - ]]; then
    TOKEN="$(cat)"
  else
    [[ -r "${TOKEN_FILE}" ]] || usage_error "cannot read token file: ${TOKEN_FILE}"
    TOKEN="$(<"${TOKEN_FILE}")"
  fi
  TOKEN="$(trim "${TOKEN}")"
fi
[[ -n "${TOKEN}" ]] || usage_error "GITLAB_TOKEN is required (or --token-file)"
# A control character would let the token inject extra curl config/headers.
if [[ "${TOKEN}" =~ [[:cntrl:][:space:]] ]]; then
  usage_error "GITLAB_TOKEN contains whitespace or control characters"
fi

GITLAB_API_URL="$(trim "${GITLAB_API_URL}")"
GITLAB_API_URL="${GITLAB_API_URL%/}"
[[ -n "${GITLAB_API_URL}" ]] || usage_error "GITLAB_API_URL is required (default \$CI_API_V4_URL is not set)"
[[ "${GITLAB_API_URL}" =~ ^https?://[^[:space:]]+$ ]] || usage_error "GITLAB_API_URL must be an http(s) URL: ${GITLAB_API_URL}"
if [[ "${GITLAB_API_URL}" != */api/v4 ]]; then
  warn "GITLAB_API_URL normally ends in /api/v4 (got ${GITLAB_API_URL})"
fi
if [[ "${GITLAB_API_URL}" == http://* && ! "${GITLAB_API_URL}" =~ ^http://(127\.0\.0\.1|localhost|\[::1\])(:|/) ]]; then
  warn "GITLAB_API_URL is not https: the token is sent unencrypted"
fi

PROJECT_ID="$(trim "${PROJECT_ID}")"
[[ -n "${PROJECT_ID}" ]] || usage_error "PROJECT_ID is required (default \$CI_PROJECT_ID is not set)"
REF="$(trim "${REF}")"
[[ -n "${REF}" ]] || usage_error "REF must not be empty"
TIMEZONE="$(trim "${TIMEZONE}")"
[[ -n "${TIMEZONE}" ]] || usage_error "TIMEZONE must not be empty"
DESCRIPTION_PREFIX="$(trim "${DESCRIPTION_PREFIX}")"
[[ -n "${DESCRIPTION_PREFIX}" ]] || usage_error "DESCRIPTION_PREFIX must not be empty"
RESOURCE_GROUP="$(trim "${RESOURCE_GROUP}")"
[[ -n "${RESOURCE_GROUP}" ]] || usage_error "RESOURCE_GROUP must not be empty"
ENVIRONMENTS="$(trim "${ENVIRONMENTS}")"
for v in REF TIMEZONE DESCRIPTION_PREFIX ENVIRONMENTS RESOURCE_GROUP; do
  [[ ! "${!v}" =~ [[:cntrl:]] ]] || usage_error "${v} contains control characters"
done

# normalise_cron CRON: one space between fields; fails unless it is a
# 5-field expression (minute hour day-of-month month day-of-week).
normalise_cron() {
  local -a f
  read -r -a f <<<"$1"
  ((${#f[@]} == 5)) || return 1
  local x
  for x in "${f[@]}"; do
    [[ "${x}" =~ ^[0-9A-Za-z*/,?#-]+$ ]] || return 1
  done
  printf '%s' "${f[*]}"
}

for v in SHUTDOWN_CRON STARTUP_CRON; do
  [[ "${!v}" != *$'\n'* ]] || usage_error "${v} must be a single line"
  norm="$(normalise_cron "${!v}")" ||
    usage_error "${v} is not a 5-field cron expression (minute hour day-of-month month day-of-week): '${!v}'"
  printf -v "${v}" '%s' "${norm}"
done

uri_encode() { jq -rn --arg v "$1" '$v | @uri'; }

if [[ "${PROJECT_ID}" =~ ^[0-9]+$ ]]; then
  PROJECT_ENC="${PROJECT_ID}"
else
  PROJECT_ENC="$(uri_encode "${PROJECT_ID}")"
fi
P="/projects/${PROJECT_ENC}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PER_PAGE=100
MAX_PAGES=1000

# ── HTTP ────────────────────────────────────────────────────────────────────
# The curl config carrying the token. printf is a shell builtin, so the token
# never appears in any process's argv; curl reads the config from stdin.
curl_config() {
  local t="${TOKEN//\\/\\\\}"
  t="${t//\"/\\\"}"
  printf 'header = "PRIVATE-TOKEN: %s"\n' "${t}"
}

# api METHOD PATH [curl data args...]
#   Sets HTTP_STATUS; the response body is in ${WORK}/body and the headers in
#   ${WORK}/headers. Exits 1 when the request cannot be made at all.
HTTP_STATUS=""
LAST_REQUEST=""
api() {
  local method="$1" path="$2"
  shift 2
  LAST_REQUEST="${method} ${path}"
  # -q (first!) ignores ~/.curlrc: it could add --location (the token header
  # would follow redirects to other hosts) or --fail (no error bodies).
  local -a args=(-q --silent --show-error --globoff --connect-timeout 20 --max-time 120
    -K - -o "${WORK}/body" -D "${WORK}/headers" -w '%{http_code}')
  if [[ "${method}" == GET ]]; then
    args+=(--retry 3)
  else
    args+=(-X "${method}")
  fi
  : >"${WORK}/body"
  : >"${WORK}/headers"
  if ! HTTP_STATUS="$(curl_config | curl "${args[@]}" "$@" --url "${GITLAB_API_URL}${path}")"; then
    error "${LAST_REQUEST}: request to ${GITLAB_API_URL} failed (see curl's message above)"
    exit 1
  fi
}

http_fail() {
  error "${LAST_REQUEST} failed: HTTP ${HTTP_STATUS}"
  case "${HTTP_STATUS}" in
  401) error "the token was rejected: check GITLAB_TOKEN (scope 'api', not expired)" ;;
  403) error "permission denied: the token's user needs the Maintainer role (and may use pipeline variables)" ;;
  404) error "not found: check GITLAB_API_URL and PROJECT_ID (${PROJECT_ID}) and that the token can see the project" ;;
  esac
  if [[ -s "${WORK}/body" ]]; then
    printf 'Response body:\n%s\n' "$(head -c 4000 "${WORK}/body")" >&2
  fi
  exit 1
}

is_2xx() { [[ "${HTTP_STATUS}" =~ ^2[0-9][0-9]$ ]]; }

# api_ok: api + exit on any non-2xx status; the body must be JSON.
api_ok() {
  api "$@"
  is_2xx || http_fail
  if [[ -s "${WORK}/body" ]] && ! jq -e . "${WORK}/body" >/dev/null 2>&1; then
    error "${LAST_REQUEST}: response is not JSON (is GITLAB_API_URL the /api/v4 URL?)"
    printf 'Response body:\n%s\n' "$(head -c 2000 "${WORK}/body")" >&2
    exit 1
  fi
}

# header_value NAME: value of the last NAME response header; fails if absent.
header_value() {
  local want="${1,,}" line value="" found=1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    if [[ "${line,,}" == "${want}:"* ]]; then
      value="$(trim "${line#*:}")"
      found=0
    fi
  done <"${WORK}/headers"
  printf '%s' "${value}"
  return "${found}"
}

# ── Bookkeeping ─────────────────────────────────────────────────────────────
SUMMARY=()
CHANGES=0
note() { SUMMARY+=("$*"); }
changed() {
  CHANGES=$((CHANGES + 1))
  note "$@"
}
# would VERB PAST: "would VERB" in a dry run, else PAST.
would() {
  if ${DRY_RUN}; then
    printf 'would %s' "$1"
  else
    printf '%s' "$2"
  fi
}

# ── Schedules ───────────────────────────────────────────────────────────────
SCHEDULES="${WORK}/schedules.json"

list_schedules() {
  local page=1 next count
  echo '[]' >"${SCHEDULES}"
  while :; do
    api_ok GET "${P}/pipeline_schedules?per_page=${PER_PAGE}&page=${page}"
    jq -e 'type == "array"' "${WORK}/body" >/dev/null || {
      error "${LAST_REQUEST}: expected a JSON array"
      exit 1
    }
    jq -s '.[0] + .[1]' "${SCHEDULES}" "${WORK}/body" >"${WORK}/merged.json"
    mv "${WORK}/merged.json" "${SCHEDULES}"
    count="$(jq length "${WORK}/body")"
    if next="$(header_value X-Next-Page)"; then
      [[ -n "${next}" ]] || break
      if [[ ! "${next}" =~ ^[0-9]+$ ]] || ((next <= page)); then
        error "${LAST_REQUEST}: unexpected X-Next-Page '${next}'"
        exit 1
      fi
      page="${next}"
    else
      # No pagination headers: a short page is the last one.
      ((count >= PER_PAGE)) || break
      page=$((page + 1))
    fi
    if ((page > MAX_PAGES)); then
      error "more than ${MAX_PAGES} pages of pipeline schedules; giving up"
      exit 1
    fi
  done
  info "found $(jq length "${SCHEDULES}") pipeline schedule(s) in ${PROJECT_ID}"
}

# ensure_variable SID KEY VALUE CURRENT_VARS_JSON
ensure_variable() {
  local sid="$1" key="$2" value="$3" vars="$4" cur key_enc
  key_enc="$(uri_encode "${key}")"
  cur="$(jq -c --arg k "${key}" 'first(.[] | select(.key == $k)) // empty' <<<"${vars}")"
  if [[ -z "${cur}" ]]; then
    ${DRY_RUN} || api_ok POST "${P}/pipeline_schedules/${sid}/variables" \
      --data-urlencode "key=${key}" --data-urlencode "value=${value}" --data-urlencode "variable_type=env_var"
    changed "  variable ${key}=${value}: $(would create created)"
  elif [[ "$(jq -r '.value' <<<"${cur}")" != "${value}" || "$(jq -r '.variable_type // "env_var"' <<<"${cur}")" != env_var ]]; then
    ${DRY_RUN} || api_ok PUT "${P}/pipeline_schedules/${sid}/variables/${key_enc}" \
      --data-urlencode "value=${value}" --data-urlencode "variable_type=env_var"
    changed "  variable ${key}=${value}: $(would update updated) (was '$(jq -r '.value' <<<"${cur}")')"
  else
    note "  variable ${key}=${value}: unchanged"
  fi
}

# remove_variable SID KEY CURRENT_VARS_JSON
remove_variable() {
  local sid="$1" key="$2" vars="$3" key_enc
  key_enc="$(uri_encode "${key}")"
  jq -e --arg k "${key}" 'any(.[]; .key == $k)' <<<"${vars}" >/dev/null || return 0
  if ! ${DRY_RUN}; then
    api DELETE "${P}/pipeline_schedules/${sid}/variables/${key_enc}"
    # 404: already gone (deleted concurrently) is the desired end state.
    is_2xx || [[ "${HTTP_STATUS}" == 404 ]] || http_fail
  fi
  changed "  variable ${key}: $(would delete deleted) (ENVIRONMENTS is empty)"
}

# ensure_schedule ACTION CRON
ensure_schedule() {
  local action="$1" cron="$2" desc matches n sid cur vars
  desc="${DESCRIPTION_PREFIX}: ${action}"
  matches="$(jq -c --arg d "${desc}" '[.[] | select(.description == $d)] | sort_by(.id)' "${SCHEDULES}")"
  n="$(jq length <<<"${matches}")"
  if ((n > 1)); then
    error "${n} pipeline schedules are named '${desc}' (ids $(jq -r 'map(.id) | join(", ")' <<<"${matches}")); delete the duplicates and re-run"
    exit 1
  fi

  if ((n == 0)); then
    sid="(new)"
    if ! ${DRY_RUN}; then
      api_ok POST "${P}/pipeline_schedules" \
        --data-urlencode "description=${desc}" --data-urlencode "ref=${REF}" \
        --data-urlencode "cron=${cron}" --data-urlencode "cron_timezone=${TIMEZONE}" \
        --data-urlencode "active=true"
      sid="$(jq -r '.id' "${WORK}/body")"
      [[ "${sid}" =~ ^[0-9]+$ ]] || {
        error "${LAST_REQUEST}: no schedule id in the response"
        exit 1
      }
    fi
    changed "schedule '${desc}' #${sid}: $(would create created) (cron '${cron}' ${TIMEZONE}, ref ${REF})"
    vars='[]'
  else
    cur="$(jq -c '.[0]' <<<"${matches}")"
    sid="$(jq -r '.id' <<<"${cur}")"
    local -a data=() diffs=()
    local cur_ref cur_cron cur_tz cur_active
    cur_ref="$(jq -r '.ref // ""' <<<"${cur}")"
    cur_cron="$(jq -r '.cron // ""' <<<"${cur}")"
    cur_cron="$(normalise_cron "${cur_cron}" || printf '%s' "${cur_cron}")"
    cur_tz="$(jq -r '.cron_timezone // ""' <<<"${cur}")"
    cur_active="$(jq -r '.active' <<<"${cur}")"
    # Schedules created in the UI may store the full ref name.
    if [[ "${cur_ref}" != "${REF}" && "${cur_ref}" != "refs/heads/${REF}" ]]; then
      data+=(--data-urlencode "ref=${REF}")
      diffs+=("ref '${cur_ref}' -> '${REF}'")
    fi
    if [[ "${cur_cron}" != "${cron}" ]]; then
      data+=(--data-urlencode "cron=${cron}")
      diffs+=("cron '${cur_cron}' -> '${cron}'")
    fi
    if [[ "${cur_tz}" != "${TIMEZONE}" ]]; then
      data+=(--data-urlencode "cron_timezone=${TIMEZONE}")
      diffs+=("timezone '${cur_tz}' -> '${TIMEZONE}'")
    fi
    if [[ "${cur_active}" != true ]]; then
      data+=(--data-urlencode "active=true")
      diffs+=("inactive -> active")
    fi
    if ((${#diffs[@]})); then
      ${DRY_RUN} || api_ok PUT "${P}/pipeline_schedules/${sid}" "${data[@]}"
      local joined
      printf -v joined '%s; ' "${diffs[@]}"
      changed "schedule '${desc}' #${sid}: $(would update updated) (${joined%; })"
    else
      note "schedule '${desc}' #${sid}: unchanged"
    fi
    api_ok GET "${P}/pipeline_schedules/${sid}"
    vars="$(jq -c '.variables // []' "${WORK}/body")"
  fi

  ensure_variable "${sid}" HIBERNATE_ACTION "${action}" "${vars}"
  if [[ -n "${ENVIRONMENTS}" ]]; then
    ensure_variable "${sid}" HIBERNATE_ENVIRONMENTS "${ENVIRONMENTS}" "${vars}"
  else
    remove_variable "${sid}" HIBERNATE_ENVIRONMENTS "${vars}"
  fi
}

# ── Resource group ──────────────────────────────────────────────────────────
RG_HINT="run the jobs once first (GitLab creates the resource group on first use), then re-run with --set-resource-group-mode"

rg_missing() {
  warn "resource group ${RESOURCE_GROUP} does not exist yet: ${RG_HINT}"
  note "resource group ${RESOURCE_GROUP}: not found yet (run the jobs once first)"
}

# Idempotent: reads the current mode first and only PUTs when it differs.
set_resource_group_mode() {
  local key_enc mode
  key_enc="$(uri_encode "${RESOURCE_GROUP}")"
  api GET "${P}/resource_groups/${key_enc}"
  if [[ "${HTTP_STATUS}" == 404 ]]; then
    rg_missing
    return 0
  fi
  is_2xx || http_fail
  mode="$(jq -r '.process_mode // ""' "${WORK}/body")"
  if [[ "${mode}" == oldest_first ]]; then
    note "resource group ${RESOURCE_GROUP}: process_mode oldest_first (unchanged)"
    return 0
  fi
  if ! ${DRY_RUN}; then
    api PUT "${P}/resource_groups/${key_enc}?process_mode=oldest_first"
    if [[ "${HTTP_STATUS}" == 404 ]]; then
      rg_missing
      return 0
    fi
    is_2xx || http_fail
  fi
  changed "resource group ${RESOURCE_GROUP}: process_mode $(would set set) to oldest_first (was ${mode:-unknown})"
}

# ── Main ────────────────────────────────────────────────────────────────────
${DRY_RUN} && info "dry run: no changes will be made"
list_schedules
ensure_schedule shutdown "${SHUTDOWN_CRON}"
ensure_schedule startup "${STARTUP_CRON}"
if ${SET_RG_MODE}; then
  set_resource_group_mode
fi

echo "Summary (project ${PROJECT_ID}, ref ${REF}, timezone ${TIMEZONE}):"
printf '%s\n' "${SUMMARY[@]}"
if ${DRY_RUN}; then
  echo "Dry run: ${CHANGES} change(s) would be made."
elif ((CHANGES)); then
  echo "${CHANGES} change(s) made."
else
  echo "No changes: everything is up to date."
fi
if ! ${SET_RG_MODE}; then
  cat <<EOF

Reminder: once dev-composer-shutdown and dev-composer-startup have run, set
the resource group ${RESOURCE_GROUP} to process_mode=oldest_first so a delayed
shutdown can never be overtaken by the next startup. Re-run with
--set-resource-group-mode, or (token on stdin, not on the command line):
  printf 'header = "PRIVATE-TOKEN: %s"\n' "\${GITLAB_TOKEN}" | curl -X PUT -K - \\
    "${GITLAB_API_URL}${P}/resource_groups/$(uri_encode "${RESOURCE_GROUP}")?process_mode=oldest_first"
EOF
fi
