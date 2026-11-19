#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# Tests for scripts/ci/create-hibernation-schedules.sh, run against
# tests/ci/fake_gitlab_api.py (a stateful in-memory fake of the GitLab REST
# API v4 pipeline-schedule and resource-group endpoints).
#
# Every test starts its own fake on a free port with its own state and request
# log (JSON lines), so the suite is parallel-safe. No sleeps: the fake reports
# its port through a FIFO once it is listening.
# ============================================================================

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # SCHEDULES_SCRIPT: run the suite against another copy (mutation testing).
  SCRIPT="${SCHEDULES_SCRIPT:-${REPO}/scripts/ci/create-hibernation-schedules.sh}"
  FAKE="${BATS_TEST_DIRNAME}/fake_gitlab_api.py"
  REQ_LOG="${BATS_TEST_TMPDIR}/requests.jsonl"
  TOKEN="glpat-Secr3t-${BATS_TEST_NUMBER}-xYz"
  SHUTDOWN="Composer hibernation: shutdown"
  STARTUP="Composer hibernation: startup"
  # The fake listens on loopback; never send it through the agent proxy.
  export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,${NO_PROXY}}"
  export no_proxy="127.0.0.1,localhost${no_proxy:+,${no_proxy}}"
  unset CI_API_V4_URL CI_PROJECT_ID GITLAB_API_URL GITLAB_TOKEN PROJECT_ID REF TIMEZONE \
    SHUTDOWN_CRON STARTUP_CRON ENVIRONMENTS DESCRIPTION_PREFIX RESOURCE_GROUP
  start_fake
}

teardown() {
  stop_fake
}

# ── Fake server ─────────────────────────────────────────────────────────────
# start_fake [TOKEN]: the token the fake accepts (default ${TOKEN}).
start_fake() {
  local fifo="${BATS_TEST_TMPDIR}/ready.fifo" token="${1:-${TOKEN}}"
  rm -f "${fifo}"
  mkfifo "${fifo}"
  # Open read-write so neither side blocks in open(); read -t bounds the wait.
  exec 8<>"${fifo}"
  python3 "${FAKE}" --token "${token}" --log "${REQ_LOG}" --ready-fifo "${fifo}" \
    >"${BATS_TEST_TMPDIR}/fake.out" 2>&1 3>&- 8>&- &
  FAKE_PID=$!
  if ! read -r -t 10 FAKE_PORT <&8; then
    exec 8>&-
    cat "${BATS_TEST_TMPDIR}/fake.out" >&2
    return 1
  fi
  exec 8>&-
  FAKE_URL="http://127.0.0.1:${FAKE_PORT}"
  export GITLAB_API_URL="${FAKE_URL}/api/v4" GITLAB_TOKEN="${token}" PROJECT_ID=42
}

stop_fake() {
  if [[ -n "${FAKE_PID:-}" ]]; then
    kill "${FAKE_PID}" 2>/dev/null || true
    wait "${FAKE_PID}" 2>/dev/null || true
    FAKE_PID=""
  fi
}

# seed JSON: replace the fake's state (see fake_gitlab_api.py for the shape).
seed() {
  curl -sf --noproxy '*' -X POST -H 'Content-Type: application/json' \
    --data-binary "$1" "${FAKE_URL}/__control/state"
}

state() { curl -sf --noproxy '*' "${FAKE_URL}/__control/state"; }

# schedule DESCRIPTION: the stored schedule (incl. variables) as JSON.
schedule() { state | jq -c --arg d "$1" 'first(.schedules[] | select(.description == $d)) // null'; }

# var DESCRIPTION KEY: value of a schedule variable ("<none>" when absent).
var() { schedule "$1" | jq -r --arg k "$2" 'first(.variables[] | select(.key == $k) | .value) // "<none>"'; }

reset_log() { : >"${REQ_LOG}"; }
requests() { jq -s -c "${1:-.}" "${REQ_LOG}"; }
count() { jq -s "[.[] | select($1)] | length" "${REQ_LOG}"; }
mutations() { count '.method != "GET"'; }

# A schedule seed entry: sched ID DESCRIPTION CRON [jq-object-merged-in]
sched() {
  jq -nc --argjson id "$1" --arg d "$2" --arg c "$3" --argjson extra "${4:-{\}}" \
    '{id: $id, description: $d, ref: "main", cron: $c, cron_timezone: "Europe/London"} + $extra'
}

# ── Usage ───────────────────────────────────────────────────────────────────
@test "--help documents every input and makes no requests" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  for word in GITLAB_API_URL GITLAB_TOKEN PROJECT_ID REF TIMEZONE SHUTDOWN_CRON STARTUP_CRON \
    ENVIRONMENTS DESCRIPTION_PREFIX --dry-run --set-resource-group-mode --token-file \
    "0 19 \* \* 1-5" "0 7 \* \* 1-5" Europe/London; do
    [[ "${output}" == *${word}* ]] || {
      echo "help does not mention ${word}"
      return 1
    }
  done
  [ "$(requests 'length')" -eq 0 ]
}

@test "unknown options and --token are rejected with exit 2" {
  run "${SCRIPT}" --bogus
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown option: --bogus"* ]]
  run "${SCRIPT}" --token "${TOKEN}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--token is not supported"* ]]
  run "${SCRIPT}" --ref
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"needs a value"* ]]
  [ "$(requests 'length')" -eq 0 ]
}

@test "missing token, API URL or project is a usage error before any request" {
  run env -u GITLAB_TOKEN "${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GITLAB_TOKEN is required"* ]]
  run env -u GITLAB_API_URL "${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GITLAB_API_URL is required"* ]]
  run env -u PROJECT_ID "${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"PROJECT_ID is required"* ]]
  [ "$(requests 'length')" -eq 0 ]
}

# ── Create / idempotency / update ───────────────────────────────────────────
@test "creates both schedules from scratch with cron, timezone, ref and variables" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]

  [ "$(state | jq '.schedules | length')" -eq 2 ]
  run schedule "${SHUTDOWN}"
  [ "$(jq -r '.cron' <<<"${output}")" = "0 19 * * 1-5" ]
  [ "$(jq -r '.cron_timezone' <<<"${output}")" = "Europe/London" ]
  [ "$(jq -r '.ref' <<<"${output}")" = "main" ]
  [ "$(jq -r '.active' <<<"${output}")" = "true" ]
  [ "$(jq -c '.variables' <<<"${output}")" = '[{"key":"HIBERNATE_ACTION","value":"shutdown","variable_type":"env_var"}]' ]
  run schedule "${STARTUP}"
  [ "$(jq -r '.cron' <<<"${output}")" = "0 7 * * 1-5" ]
  [ "$(jq -r '.cron_timezone' <<<"${output}")" = "Europe/London" ]
  [ "$(jq -r '.ref' <<<"${output}")" = "main" ]
  [ "$(jq -r '.active' <<<"${output}")" = "true" ]
  [ "$(jq -c '.variables' <<<"${output}")" = '[{"key":"HIBERNATE_ACTION","value":"startup","variable_type":"env_var"}]' ]

  # 2 schedule POSTs + 2 variable POSTs, all authenticated; no HIBERNATE_ENVIRONMENTS.
  [ "$(count '.method == "POST" and (.path | endswith("/pipeline_schedules"))')" -eq 2 ]
  [ "$(count '.method == "POST" and (.path | endswith("/variables"))')" -eq 2 ]
  [ "$(count '.method == "PUT" or .method == "DELETE"')" -eq 0 ]
  [ "$(count '.auth != true')" -eq 0 ]
  [ "$(count '.form.key == "HIBERNATE_ENVIRONMENTS"')" -eq 0 ]
  [ "$(count '.form.active == "true"')" -eq 2 ]
}

@test "prints a summary and the resource-group reminder" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Summary (project 42, ref main, timezone Europe/London)"* ]]
  [[ "${output}" == *"schedule '${SHUTDOWN}' #1: created"* ]]
  [[ "${output}" == *"schedule '${STARTUP}' #2: created"* ]]
  [[ "${output}" == *"variable HIBERNATE_ACTION=shutdown: created"* ]]
  [[ "${output}" == *"4 change(s) made."* ]]
  [[ "${output}" == *"composer-hibernation-dev"*"process_mode=oldest_first"* ]]
  [[ "${output}" == *"--set-resource-group-mode"* ]]
  [[ "${output}" == *"/projects/42/resource_groups/composer-hibernation-dev?process_mode=oldest_first"* ]]
  # Without the flag the resource group is not touched at all.
  [ "$(count '.path | contains("resource_groups")')" -eq 0 ]
}

@test "re-running is idempotent: no POST/PUT/DELETE on the second run" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  local before
  before="$(state)"
  reset_log
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
  [ "$(count '.method == "GET"')" -ge 3 ] # list + one GET per schedule
  [[ "${output}" == *"schedule '${SHUTDOWN}' #1: unchanged"* ]]
  [[ "${output}" == *"schedule '${STARTUP}' #2: unchanged"* ]]
  [[ "${output}" == *"No changes"* ]]
  [ "$(state)" = "${before}" ]
}

@test "a changed cron updates the existing schedule with PUT (same id, no new schedule)" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  reset_log
  SHUTDOWN_CRON="30 18 * * 1-5" run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(count '.method == "POST"')" -eq 0 ]
  [ "$(count '.method == "PUT"')" -eq 1 ]
  [ "$(requests '[.[] | select(.method == "PUT")][0] | [.path, .form]')" = \
    '["/api/v4/projects/42/pipeline_schedules/1",{"cron":"30 18 * * 1-5"}]' ]
  [ "$(schedule "${SHUTDOWN}" | jq -r '"\(.id) \(.cron)"')" = "1 30 18 * * 1-5" ]
  [ "$(schedule "${STARTUP}" | jq -r .cron)" = "0 7 * * 1-5" ]
  [ "$(state | jq '.schedules | length')" -eq 2 ]
  [[ "${output}" == *"updated (cron '0 19 * * 1-5' -> '30 18 * * 1-5')"* ]]
}

@test "timezone and ref changes are applied with PUT" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  reset_log
  TIMEZONE=UTC REF=develop run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(count '.method == "PUT" and .form.cron_timezone == "UTC" and .form.ref == "develop"')" -eq 2 ]
  [ "$(count '.method == "POST"')" -eq 0 ]
  [ "$(state | jq -r '[.schedules[] | "\(.ref) \(.cron_timezone)"] | unique | join(",")')" = "develop UTC" ]
}

@test "cron whitespace is normalised and not reported as a change" {
  seed "{\"schedules\": [$(sched 5 "${SHUTDOWN}" "0  19 * *  1-5" '{"variables":[{"key":"HIBERNATE_ACTION","value":"shutdown"}]}')]}"
  STARTUP_CRON=" 0   7 * * 1-5 " run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(count '.method == "PUT"')" -eq 0 ]
  [ "$(requests '[.[] | select(.method == "POST" and (.path | endswith("/pipeline_schedules")))][0].form.cron')" = '"0 7 * * 1-5"' ]
}

@test "an inactive schedule is re-activated; a UI-style refs/heads/<ref> counts as the same ref" {
  seed "{\"schedules\": [
    $(sched 10 "${SHUTDOWN}" "0 19 * * 1-5" '{"ref":"refs/heads/main","active":false,"variables":[{"key":"HIBERNATE_ACTION","value":"shutdown"}]}'),
    $(sched 11 "${STARTUP}" "0 7 * * 1-5" '{"ref":"develop","variables":[{"key":"HIBERNATE_ACTION","value":"startup"}]}')]}"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(requests '[.[] | select(.method == "PUT") | [.path, .form]]')" = \
    '[["/api/v4/projects/42/pipeline_schedules/10",{"active":"true"}],["/api/v4/projects/42/pipeline_schedules/11",{"ref":"main"}]]' ]
  [ "$(count '.method == "POST"')" -eq 0 ]
  [ "$(schedule "${SHUTDOWN}" | jq -r .active)" = true ]
}

@test "variable drift is repaired with PUT; unrelated schedule variables are left alone" {
  seed "{\"schedules\": [$(sched 3 "${SHUTDOWN}" "0 19 * * 1-5" \
    '{"variables":[{"key":"HIBERNATE_ACTION","value":"startup"},{"key":"OTHER","value":"keep-me"}]}')]}"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(requests '[.[] | select(.method == "PUT") | [.path, .form.value]]')" = \
    '[["/api/v4/projects/42/pipeline_schedules/3/variables/HIBERNATE_ACTION","shutdown"]]' ]
  [ "$(var "${SHUTDOWN}" HIBERNATE_ACTION)" = shutdown ]
  [ "$(var "${SHUTDOWN}" OTHER)" = keep-me ]
  [[ "${output}" == *"variable HIBERNATE_ACTION=shutdown: updated (was 'startup')"* ]]
}

@test "a file-type HIBERNATE_ACTION variable is converted to env_var" {
  seed "{\"schedules\": [$(sched 3 "${SHUTDOWN}" "0 19 * * 1-5" \
    '{"variables":[{"key":"HIBERNATE_ACTION","value":"shutdown","variable_type":"file"}]}')]}"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(count '.method == "PUT" and .form.variable_type == "env_var"')" -eq 1 ]
  [ "$(schedule "${SHUTDOWN}" | jq -r '.variables[0].variable_type')" = env_var ]
}

# ── ENVIRONMENTS ────────────────────────────────────────────────────────────
@test "ENVIRONMENTS naming no environment (e.g. ',') is a usage error and makes no requests" {
  local v
  for v in "," " , " ",,"; do
    ENVIRONMENTS="${v}" run "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"names no environment"* ]]
  done
  [ "$(requests 'length')" -eq 0 ]
}

@test "ENVIRONMENTS adds HIBERNATE_ENVIRONMENTS, updates it, and deletes it once unset" {
  ENVIRONMENTS="composer-dev,composer-qa" run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(var "${SHUTDOWN}" HIBERNATE_ENVIRONMENTS)" = "composer-dev,composer-qa" ]
  [ "$(var "${STARTUP}" HIBERNATE_ENVIRONMENTS)" = "composer-dev,composer-qa" ]
  [ "$(count '.method == "POST" and .form.key == "HIBERNATE_ENVIRONMENTS"')" -eq 2 ]

  # Changed value -> PUT .../variables/HIBERNATE_ENVIRONMENTS, no POST.
  reset_log
  ENVIRONMENTS="composer-dev" run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(count '.method == "POST"')" -eq 0 ]
  [ "$(count '.method == "PUT" and (.path | endswith("/variables/HIBERNATE_ENVIRONMENTS")) and .form.value == "composer-dev"')" -eq 2 ]
  [ "$(var "${STARTUP}" HIBERNATE_ENVIRONMENTS)" = "composer-dev" ]

  # Unset -> DELETE on both schedules; HIBERNATE_ACTION stays.
  reset_log
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(count '.method == "DELETE" and (.path | endswith("/variables/HIBERNATE_ENVIRONMENTS"))')" -eq 2 ]
  [ "$(count '.method == "POST" or .method == "PUT"')" -eq 0 ]
  [ "$(var "${SHUTDOWN}" HIBERNATE_ENVIRONMENTS)" = "<none>" ]
  [ "$(var "${STARTUP}" HIBERNATE_ENVIRONMENTS)" = "<none>" ]
  [ "$(var "${SHUTDOWN}" HIBERNATE_ACTION)" = shutdown ]
  [[ "${output}" == *"variable HIBERNATE_ENVIRONMENTS: deleted"* ]]

  # And it stays converged.
  reset_log
  ENVIRONMENTS="" run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
}

@test "values with URL/form metacharacters round-trip exactly (no -F, no @file reads)" {
  local envs='composer-dev&x=1,@/etc/passwd;+"q" <b>'
  ENVIRONMENTS="${envs}" DESCRIPTION_PREFIX='Team A&B=+@x' run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(var 'Team A&B=+@x: shutdown' HIBERNATE_ENVIRONMENTS)" = "${envs}" ]
  [ "$(var 'Team A&B=+@x: startup' HIBERNATE_ACTION)" = startup ]
  reset_log
  ENVIRONMENTS="${envs}" DESCRIPTION_PREFIX='Team A&B=+@x' run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
}

# ── Errors ──────────────────────────────────────────────────────────────────
@test "a wrong token fails non-zero with the HTTP status and response body" {
  GITLAB_TOKEN="glpat-wrong-token" run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"HTTP 401"* ]]
  [[ "${output}" == *'{"message": "401 Unauthorized"}'* ]]
  [[ "${output}" == *"token was rejected"* ]]
  [[ "${output}" != *"glpat-wrong-token"* ]]
  [ "$(mutations)" -eq 0 ]
  [ "$(count '.auth == true')" -eq 0 ]
}

@test "an API validation error (HTTP 400) stops the run and shows the body" {
  TIMEZONE="Mars/Olympus_Mons" run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"POST /projects/42/pipeline_schedules failed: HTTP 400"* ]]
  [[ "${output}" == *"cron_timezone"* ]]
  [ "$(state | jq '.schedules | length')" -eq 0 ]
  [ "$(count '.method == "POST"')" -eq 1 ] # stopped at the first error
}

@test "an unknown project fails with 404 and a hint" {
  PROJECT_ID=999 run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"HTTP 404"* ]]
  [[ "${output}" == *"check GITLAB_API_URL and PROJECT_ID"* ]]
  [[ "${output}" == *"404 Project Not Found"* ]]
}

@test "an unreachable API fails non-zero" {
  stop_fake
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"request to ${GITLAB_API_URL} failed"* ]]
}

@test "duplicate schedules with the same description are refused" {
  seed "{\"schedules\": [$(sched 4 "${SHUTDOWN}" "0 19 * * 1-5"), $(sched 9 "${SHUTDOWN}" "0 19 * * 1-5")]}"
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"2 pipeline schedules are named '${SHUTDOWN}' (ids 4, 9)"* ]]
  [ "$(mutations)" -eq 0 ]
}

@test "invalid cron expressions are rejected before any request" {
  local bad
  for bad in "0 19 * *" "0 19 * * 1-5 2026" "0 19 * * 1-5;" "0 19 * * \$(id)" $'0 19 * *\n1-5' "" "   "; do
    run "${SCRIPT}" --shutdown-cron "${bad}"
    [ "${status}" -eq 2 ] || {
      echo "accepted shutdown cron '${bad}' (status ${status})"
      return 1
    }
    [[ "${output}" == *"SHUTDOWN_CRON"*"5-field cron"* || "${output}" == *"SHUTDOWN_CRON must be a single line"* ]]
  done
  STARTUP_CRON="* * * *" run "${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"STARTUP_CRON is not a 5-field cron expression"* ]]
  [ "$(requests 'length')" -eq 0 ]
}

# ── Token handling ──────────────────────────────────────────────────────────
@test "the script hands the token to curl via a config on stdin, never as an argument" {
  # Static: curl gets '-K -'; the only PRIVATE-TOKEN strings are the config
  # line and the documentation placeholder '<token>'.
  grep -Eq -- "-K -" "${SCRIPT}"
  run grep -n 'PRIVATE-TOKEN' "${SCRIPT}"
  [ "${status}" -eq 0 ]
  local line
  while IFS= read -r line; do
    [[ "${line}" == *'header = "PRIVATE-TOKEN: %s"'* || "${line}" == *'<token>'* ]] || {
      echo "unexpected PRIVATE-TOKEN use: ${line}"
      return 1
    }
  done <<<"${output}"
  # No multipart -F/--form (it interprets @file and <file in values).
  run ! grep -Eq -- '(^|[[:space:]])(-F|--form)[[:space:]]' "${SCRIPT}"

  # Dynamic: a curl wrapper records every argv (and which env vars, if any,
  # contain the token) and then runs the real curl.
  local bin="${BATS_TEST_TMPDIR}/bin" real_curl
  real_curl="$(command -v curl)"
  mkdir -p "${bin}"
  cat >"${bin}/curl" <<EOF
#!/usr/bin/env bash
printf '%s\0' "\$@" >>"${BATS_TEST_TMPDIR}/curl-argv.log"
printf '\n' >>"${BATS_TEST_TMPDIR}/curl-calls.log"
for name in \$(compgen -e); do
  [[ "\${!name}" != *'${TOKEN}'* ]] || echo "\${name}" >>"${BATS_TEST_TMPDIR}/curl-env-leak.log"
done
exec "${real_curl}" "\$@"
EOF
  chmod +x "${bin}/curl"

  ENVIRONMENTS=composer-dev PATH="${bin}:${PATH}" run "${SCRIPT}" --set-resource-group-mode
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"${TOKEN}"* ]]
  local calls
  calls="$(wc -l <"${BATS_TEST_TMPDIR}/curl-calls.log")"
  [ "${calls}" -eq "$(requests 'length')" ] # every request went through the wrapper
  [ "${calls}" -ge 8 ]
  run ! grep -qaF -- "${TOKEN}" "${BATS_TEST_TMPDIR}/curl-argv.log"
  run ! grep -qaF -- "PRIVATE-TOKEN" "${BATS_TEST_TMPDIR}/curl-argv.log"
  grep -qaF -- $'-K\0-\0' "${BATS_TEST_TMPDIR}/curl-argv.log"
  [ ! -e "${BATS_TEST_TMPDIR}/curl-env-leak.log" ]
  # ...and yet every request carried the right token.
  [ "$(count '.auth != true')" -eq 0 ]
}

@test "--token-file (file and stdin) works; tokens with quotes/backslashes are escaped" {
  printf '%s\n' "${TOKEN}" >"${BATS_TEST_TMPDIR}/token"
  run env -u GITLAB_TOKEN "${SCRIPT}" --token-file "${BATS_TEST_TMPDIR}/token"
  [ "${status}" -eq 0 ]
  [ "$(state | jq '.schedules | length')" -eq 2 ]

  local odd='glpat-a"b\c'
  stop_fake
  start_fake "${odd}"
  reset_log
  run env -u GITLAB_TOKEN "${SCRIPT}" --token-file - <<<"${odd}"
  [ "${status}" -eq 0 ]
  [ "$(count '.auth != true')" -eq 0 ]
  [ "$(state | jq '.schedules | length')" -eq 2 ]

  GITLAB_TOKEN="has space" run "${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"whitespace or control characters"* ]]
}

# ── Pagination ──────────────────────────────────────────────────────────────
pagination_seed() {
  # 120 unrelated schedules, then the existing startup schedule on page 2.
  jq -nc --argjson headers "$1" '{pagination_headers: $headers, schedules:
    ([range(1; 121) | {id: ., description: "Nightly job \(.)", ref: "main", cron: "0 3 * * *"}]
     + [{id: 121, description: "Composer hibernation: startup", ref: "main", cron: "0 7 * * 1-5",
         cron_timezone: "Europe/London", variables: [{key: "HIBERNATE_ACTION", value: "startup"}]}])}'
}

@test "pagination: finds a schedule on page 2 among 120 unrelated ones (X-Next-Page)" {
  seed "$(pagination_seed true)"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(requests '[.[] | select(.method == "GET" and (.path | endswith("/pipeline_schedules"))) | .query.page + "/" + .query.per_page]')" = '["1/100","2/100"]' ]
  # Only the shutdown schedule is new; the startup one on page 2 is reused.
  [ "$(count '.method == "POST" and (.path | endswith("/pipeline_schedules"))')" -eq 1 ]
  [ "$(count '.method == "PUT"')" -eq 0 ]
  [ "$(state | jq '.schedules | length')" -eq 122 ]
  [ "$(state | jq --arg d "${STARTUP}" '[.schedules[] | select(.description == $d)] | length')" -eq 1 ]
  [[ "${output}" == *"found 121 pipeline schedule(s)"* ]]
  [[ "${output}" == *"schedule '${STARTUP}' #121: unchanged"* ]]
  # The unrelated schedules are untouched.
  [ "$(count '.method != "GET" and (.path | test("/pipeline_schedules/([0-9]|[1-9][0-9]|1[01][0-9]|120)(/|$)"))')" -eq 0 ]
}

@test "pagination: without pagination headers a full page means 'fetch the next one'" {
  seed "$(pagination_seed false)"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(count '.method == "GET" and (.path | endswith("/pipeline_schedules"))')" -eq 2 ]
  [ "$(count '.method == "POST" and (.path | endswith("/pipeline_schedules"))')" -eq 1 ]
  [ "$(state | jq '.schedules | length')" -eq 122 ]
}

# ── Dry run ─────────────────────────────────────────────────────────────────
@test "--dry-run from scratch only reads and reports what it would create" {
  run "${SCRIPT}" --dry-run --set-resource-group-mode
  [ "${status}" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
  [ "$(requests 'length')" -ge 1 ]
  [ "$(state | jq '.schedules | length')" -eq 0 ]
  [[ "${output}" == *"schedule '${SHUTDOWN}' #(new): would create"* ]]
  [[ "${output}" == *"variable HIBERNATE_ACTION=startup: would create"* ]]
  [[ "${output}" == *"Dry run: 4 change(s) would be made."* ]]
}

@test "--dry-run on drifted schedules reports updates/deletes without making them" {
  seed "{\"resource_groups\": [{\"key\": \"composer-hibernation-dev\", \"process_mode\": \"unordered\"}]}"
  ENVIRONMENTS=composer-dev run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  local before
  before="$(state)"
  reset_log
  SHUTDOWN_CRON="0 21 * * 1-5" run "${SCRIPT}" --dry-run --set-resource-group-mode
  [ "${status}" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
  [ "$(state)" = "${before}" ]
  [[ "${output}" == *"would update (cron '0 19 * * 1-5' -> '0 21 * * 1-5')"* ]]
  [[ "${output}" == *"variable HIBERNATE_ENVIRONMENTS: would delete"* ]]
  [[ "${output}" == *"process_mode would set to oldest_first (was unordered)"* ]]
  [[ "${output}" == *"Dry run: 4 change(s) would be made."* ]]
}

# ── Resource group ──────────────────────────────────────────────────────────
@test "--set-resource-group-mode warns (exit 0) when the resource group does not exist yet" {
  run "${SCRIPT}" --set-resource-group-mode
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"WARN"*"composer-hibernation-dev does not exist yet"*"run the jobs once first"* ]]
  [ "$(count '.status == 404 and (.path | endswith("/resource_groups/composer-hibernation-dev"))')" -ge 1 ]
  [ "$(count '.method == "PUT" and (.path | contains("resource_groups"))')" -eq 0 ]
  # The schedules were still created.
  [ "$(state | jq '.schedules | length')" -eq 2 ]
}

@test "--set-resource-group-mode sets oldest_first once and is idempotent" {
  seed "{\"resource_groups\": [{\"key\": \"composer-hibernation-dev\", \"process_mode\": \"unordered\"}]}"
  run "${SCRIPT}" --set-resource-group-mode
  [ "${status}" -eq 0 ]
  [ "$(requests '[.[] | select(.method == "PUT" and (.path | contains("resource_groups"))) | [.path, .query.process_mode]]')" = \
    '[["/api/v4/projects/42/resource_groups/composer-hibernation-dev","oldest_first"]]' ]
  [ "$(state | jq -r '.resource_groups[0].process_mode')" = oldest_first ]
  [[ "${output}" == *"process_mode set to oldest_first (was unordered)"* ]]
  [[ "${output}" != *"Reminder:"* ]]
  reset_log
  run "${SCRIPT}" --set-resource-group-mode
  [ "${status}" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
  [[ "${output}" == *"oldest_first (unchanged)"* ]]
}

# ── Inputs: flags, defaults, project paths ──────────────────────────────────
@test "every input has a --flag equivalent (also --flag=value) that overrides the environment" {
  printf '%s' "${TOKEN}" >"${BATS_TEST_TMPDIR}/token"
  seed '{"project": {"id": 7, "path": "team/composer"}}'
  REF=ignored TIMEZONE=ignored run env -u GITLAB_TOKEN -u GITLAB_API_URL -u PROJECT_ID "${SCRIPT}" \
    --api-url "${FAKE_URL}/api/v4/" --token-file "${BATS_TEST_TMPDIR}/token" --project team/composer \
    --ref=develop --timezone America/New_York --shutdown-cron '15 18 * * 1-4' --startup-cron='45 6 * * 1-4' \
    --environments composer-qa --description-prefix "QA hibernation"
  [ "${status}" -eq 0 ]
  run schedule "QA hibernation: shutdown"
  [ "$(jq -r '"\(.ref)|\(.cron_timezone)|\(.cron)"' <<<"${output}")" = "develop|America/New_York|15 18 * * 1-4" ]
  run schedule "QA hibernation: startup"
  [ "$(jq -r '"\(.ref)|\(.cron_timezone)|\(.cron)"' <<<"${output}")" = "develop|America/New_York|45 6 * * 1-4" ]
  [ "$(var "QA hibernation: startup" HIBERNATE_ENVIRONMENTS)" = composer-qa ]
  [ "$(var "QA hibernation: startup" HIBERNATE_ACTION)" = startup ]
  # Project paths are URL-encoded (the fake 404s on an unencoded slash).
  [ "$(count '(.path | startswith("/api/v4/projects/team%2Fcomposer/")) | not')" -eq 0 ]
}

@test "defaults come from CI_API_V4_URL / CI_PROJECT_ID" {
  seed '{"project": {"id": 42, "path": "group/composer-3-terraform"}}'
  CI_API_V4_URL="${GITLAB_API_URL}" CI_PROJECT_ID=group/composer-3-terraform \
    run env -u GITLAB_API_URL -u PROJECT_ID "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(state | jq '.schedules | length')" -eq 2 ]
  [ "$(count '.path | startswith("/api/v4/projects/group%2Fcomposer-3-terraform/pipeline_schedules")')" -eq "$(requests 'length')" ]
}

@test "a custom DESCRIPTION_PREFIX manages its own pair and leaves the default pair alone" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  reset_log
  DESCRIPTION_PREFIX="Team B hibernation" STARTUP_CRON="0 6 * * 1-5" run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(state | jq '.schedules | length')" -eq 4 ]
  [ "$(count '.method != "GET" and (.path | test("/pipeline_schedules/[12](/|$)"))')" -eq 0 ]
  [ "$(schedule "${STARTUP}" | jq -r .cron)" = "0 7 * * 1-5" ]
  [ "$(schedule "Team B hibernation: startup" | jq -r .cron)" = "0 6 * * 1-5" ]
}
