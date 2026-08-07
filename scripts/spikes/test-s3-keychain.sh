#!/usr/bin/env bash
set -euo pipefail

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly SOURCE_APP="$ROOT/build/Jidoka Code.app"
readonly SOURCE_BIN="$SOURCE_APP/Contents/MacOS/Jidoka Code"
readonly SOURCE_BASH_GATE="$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-deny-user-bash.js"
readonly TARGET_APP="$HOME/Applications/Jidoka Code Probe.app"
readonly TARGET_BIN="$TARGET_APP/Contents/MacOS/Jidoka Code"
readonly TARGET_HELPER="$TARGET_APP/Contents/Helpers/JidokaCodeEngineProbe"
readonly TARGET_BASH_GATE="$TARGET_APP/Contents/Resources/Pi/extensions/jidoka-deny-user-bash.js"
readonly SERVICE_LABEL="com.maroffo.JidokaCode.EngineProbe"
readonly KEYCHAIN_SERVICE="com.maroffo.JidokaCode.test.github"
readonly KEYCHAIN_ACCOUNT="eabf21b6-02df-4854-b9a8-c8a21eafdbca"
readonly SPIKE_PARENT="$HOME/Library/Application Support/JidokaCode/Spike"
readonly EVENT_DIR="$SPIKE_PARENT/S2"
readonly S2_LOCK="$SPIKE_PARENT/S2.lock"
readonly LOCK_DIR="$SPIKE_PARENT/S3.lock"
readonly NODE_BIN="/opt/homebrew/Cellar/node/26.6.0/bin/node"
readonly PI_CLI="/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
readonly EXPECTED_PI_VERSION="0.84.0"
USER_DOMAIN="gui/$(/usr/bin/id -u)"
readonly USER_DOMAIN
MODE="live"
TEMP_ROOT=""
EVIDENCE_DIR=""
OWN_TARGET=0
OWN_EVENT_DIR=0
OWN_LOCK=0
CLEANUP_DONE=0
DIGEST_ONE=""
DIGEST_TWO=""

fail() {
    printf 'S3 Keychain failed: %s\n' "$1" >&2
    exit 1
}

if [[ $# -gt 1 ]]; then
    fail "usage: test-s3-keychain.sh [--preflight-only]"
fi
if [[ $# -eq 1 ]]; then
    [[ "$1" == "--preflight-only" ]] || fail "unknown option"
    MODE="preflight"
fi
readonly MODE

json_value() {
    /usr/bin/plutil -extract "$2" raw "$1"
}

assert_digest() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA-256 evidence"
}

run_app() {
    local output="$1"
    local stderr="$output.stderr"
    local pid
    local deadline
    local state
    local status
    shift
    (
        cd /
        exec "$TARGET_BIN" "$@"
    ) >"$output" 2>"$stderr" &
    pid=$!
    deadline=$((SECONDS + 90))
    while (( SECONDS < deadline )); do
        if state="$(/bin/ps -p "$pid" -o state= 2>/dev/null)"; then
            case "$state" in
                *Z*) break ;;
            esac
        else
            break
        fi
        /bin/sleep 1
    done
    if (( SECONDS >= deadline )); then
        if /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | \
            /usr/bin/grep -Fxq "n$TARGET_BIN"
        then
            /bin/kill -TERM "$pid"
            /bin/sleep 1
            if /bin/kill -0 "$pid" 2>/dev/null; then
                /bin/kill -KILL "$pid"
            fi
        fi
        wait "$pid" 2>/dev/null || status=$?
        printf 'probe command timed out after 90 seconds\n' >>"$stderr"
        return 124
    fi
    if wait "$pid" 2>/dev/null; then
        return 0
    else
        status=$?
        return "$status"
    fi
}

run_app_success() {
    local output="$1"
    shift
    run_app "$output" "$@"
    [[ ! -s "$output.stderr" ]] || fail "successful probe wrote stderr"
    /usr/bin/plutil -convert xml1 -o /dev/null "$output"
    [[ "$(/usr/bin/wc -l < "$output" | /usr/bin/tr -d ' ')" == "1" ]] || \
        fail "probe output is not one JSON line"
}

keychain_status() {
    local output="$TEMP_ROOT/keychain-status.json"
    run_app_success "$output" --keychain status
    json_value "$output" exists
}

service_status() {
    local output="$TEMP_ROOT/agent-status.json"
    run_app_success "$output" --lifecycle agent status
    json_value "$output" status
}

status_is_inert() {
    case "$1" in
        notRegistered|notFound) return 0 ;;
        *) return 1 ;;
    esac
}

launchctl_job_exists() {
    /bin/launchctl print "$USER_DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1
}

launchctl_pid() {
    local output
    if output="$(/bin/launchctl print "$USER_DOMAIN/$SERVICE_LABEL" 2>/dev/null)"; then
        printf '%s\n' "$output" | \
            /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }'
    fi
}

binary_pids() {
    local output
    if output="$(/usr/sbin/lsof -t -- "$1" 2>/dev/null)"; then
        printf '%s\n' "$output" | /usr/bin/sort -nu
    fi
}

wait_for_exact_helper() {
    local deadline=$((SECONDS + 10))
    local pid
    local pids
    while (( SECONDS < deadline )); do
        pid="$(launchctl_pid)"
        pids="$(binary_pids "$TARGET_HELPER")"
        if [[ -n "$pid" && "$pids" == "$pid" ]]; then
            printf '%s\n' "$pid"
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

wait_for_agent_absence() {
    local deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
        if ! launchctl_job_exists && [[ -z "$(binary_pids "$TARGET_HELPER")" ]]; then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

wait_for_inert_status() {
    local deadline=$((SECONDS + 10))
    local status
    while (( SECONDS < deadline )); do
        if status="$(service_status 2>/dev/null)" && status_is_inert "$status"; then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

system_keychain_item_absent() {
    local status
    set +e
    /usr/bin/security find-generic-password \
        -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1
    status=$?
    set -e
    [[ "$status" == "44" ]]
}

seed_keychain_item() {
    local output="$1"
    local stdin_file="$TEMP_ROOT/keychain-seed.stdin"
    local stdout_file="$TEMP_ROOT/keychain-seed.stdout"
    local stderr_file="$TEMP_ROOT/keychain-seed.stderr"
    local sentinel
    local digest
    local pid
    local deadline
    local state
    local status=0

    sentinel="$(/usr/bin/openssl rand -hex 32 | /usr/bin/cut -c 1-32)"
    [[ "$sentinel" =~ ^[0-9a-f]{32}$ ]] || fail "invalid synthetic seed"
    digest="$(printf '%s' "$sentinel" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
    assert_digest "$digest"
    printf '%s\n%s\n' "$sentinel" "$sentinel" >"$stdin_file"
    /bin/chmod 0600 "$stdin_file"

    /usr/bin/security add-generic-password \
        -a "$KEYCHAIN_ACCOUNT" \
        -s "$KEYCHAIN_SERVICE" \
        -l "Jidoka Code synthetic S3 sentinel" \
        -T "" \
        -T "$TARGET_APP" \
        -T "$TARGET_HELPER" \
        -w <"$stdin_file" >"$stdout_file" 2>"$stderr_file" &
    pid=$!
    deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        if state="$(/bin/ps -p "$pid" -o state= 2>/dev/null)"; then
            case "$state" in
                *Z*) break ;;
            esac
        else
            break
        fi
        /bin/sleep 1
    done
    if (( SECONDS >= deadline )); then
        /bin/kill -TERM "$pid" 2>/dev/null || true
        /bin/sleep 1
        /bin/kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        /bin/rm -f -- "$stdin_file"
        unset sentinel
        fail "Keychain seed timed out"
    fi
    if wait "$pid" 2>/dev/null; then
        status=0
    else
        status=$?
    fi
    /bin/rm -f -- "$stdin_file"
    if /usr/bin/grep -Fq -- "$sentinel" "$stdout_file" "$stderr_file"; then
        unset sentinel
        fail "Keychain seed command exposed the synthetic value"
    fi
    unset sentinel
    [[ "$status" == "0" ]] || fail "Keychain seed command failed"
    if /usr/bin/grep -Fq "passwords don't match" "$stderr_file"; then
        fail "Keychain seed confirmation did not match"
    fi
    [[ ! -s "$stdout_file" ]] || fail "Keychain seed command wrote unexpected stdout"
    printf '{"action":"keychain.seed","exists":true,"sentinelSHA256":"%s"}\n' \
        "$digest" >"$output"
}

prepare_lock() {
    local current="$HOME"
    local component
    for component in "Library" "Application Support" "JidokaCode" "Spike"; do
        current="$current/$component"
        if [[ -e "$current" || -L "$current" ]]; then
            [[ -d "$current" && ! -L "$current" ]] || fail "unsafe parent $current"
        else
            /bin/mkdir "$current"
            /bin/chmod 0700 "$current"
        fi
    done
    [[ ! -e "$S2_LOCK" && ! -L "$S2_LOCK" ]] || fail "S2 lock already exists"
    /bin/mkdir "$LOCK_DIR" || fail "another S3 run owns the lock"
    /bin/chmod 0700 "$LOCK_DIR"
    OWN_LOCK=1
}

archive_evidence() {
    local run_passed="$1"
    local cleanup_verified="$2"
    local file
    /bin/mkdir -p "$EVIDENCE_DIR/commands"
    for file in "$TEMP_ROOT"/*.json "$TEMP_ROOT"/*.stdout "$TEMP_ROOT"/*.stderr; do
        if [[ -f "$file" && ! -L "$file" ]]; then
            /usr/bin/install -m 0600 "$file" "$EVIDENCE_DIR/commands/$(/usr/bin/basename "$file")"
        fi
    done
    printf '{"cleanupVerified":%s,"helperAccess":%s,"piDenied":%s,"replaceVerified":%s,"runPassed":%s}\n' \
        "$cleanup_verified" "${HELPER_ACCESS:-false}" "${PI_DENIED:-false}" \
        "${REPLACE_VERIFIED:-false}" "$run_passed" >"$EVIDENCE_DIR/summary.json"
    /bin/chmod 0600 "$EVIDENCE_DIR/summary.json"
}

cleanup_owned_state() {
    local failed=0
    local exists
    local status

    if [[ "$OWN_TARGET" == "1" ]]; then
        if [[ ! -x "$TARGET_BIN" || -L "$TARGET_BIN" ]]; then
            failed=1
        else
            if exists="$(keychain_status 2>/dev/null)"; then
                if [[ "$exists" == "true" ]]; then
                    run_app "$TEMP_ROOT/cleanup-keychain-delete.json" --keychain delete
                elif [[ "$exists" != "false" ]]; then
                    failed=1
                fi
            else
                failed=1
            fi
            if [[ "$(keychain_status 2>/dev/null)" != "false" ]]; then
                failed=1
            fi
            system_keychain_item_absent || failed=1

            if status="$(service_status 2>/dev/null)"; then
                if ! status_is_inert "$status"; then
                    run_app "$TEMP_ROOT/cleanup-agent-unregister.json" --lifecycle agent unregister
                fi
            else
                failed=1
            fi
            wait_for_inert_status || failed=1
            wait_for_agent_absence || failed=1
            [[ -z "$(binary_pids "$TARGET_BIN")" ]] || failed=1
        fi
    fi

    [[ "$failed" == "0" ]] || return 1
    if [[ "$OWN_TARGET" == "1" ]]; then
        [[ -d "$TARGET_APP" && ! -L "$TARGET_APP" ]] || return 1
        /bin/rm -rf -- "$TARGET_APP"
        OWN_TARGET=0
    fi
    if [[ "$OWN_EVENT_DIR" == "1" && -e "$EVENT_DIR" ]]; then
        [[ -d "$EVENT_DIR" && ! -L "$EVENT_DIR" ]] || return 1
        /bin/rm -rf -- "$EVENT_DIR"
        OWN_EVENT_DIR=0
    fi
    if [[ "$OWN_LOCK" == "1" && -e "$LOCK_DIR" ]]; then
        [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] || return 1
        /bin/rmdir "$LOCK_DIR" || return 1
        OWN_LOCK=0
    fi
}

cleanup_on_exit() {
    local original_status=$?
    local cleanup_status
    trap - EXIT
    [[ "$CLEANUP_DONE" == "0" ]] || exit "$original_status"
    set +e
    if [[ -n "$EVIDENCE_DIR" ]]; then
        archive_evidence false false
    fi
    cleanup_owned_state
    cleanup_status=$?
    if [[ "$cleanup_status" == "0" && -n "$EVIDENCE_DIR" ]]; then
        archive_evidence false true
    fi
    if [[ "$cleanup_status" != "0" ]]; then
        printf 'S3 cleanup ambiguous; preserving target=%s evidence=%s temp=%s\n' \
            "$TARGET_APP" "$EVIDENCE_DIR" "$TEMP_ROOT" >&2
        exit 1
    fi
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        case "$(/usr/bin/basename "$TEMP_ROOT")" in
            jidoka-code-s3.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
        esac
    fi
    exit "$original_status"
}

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-s3.XXXXXX")"
readonly TEMP_ROOT
EVIDENCE_DIR="$ROOT/build/evidence/$(/usr/bin/basename "$TEMP_ROOT")"
readonly EVIDENCE_DIR
trap cleanup_on_exit EXIT

"$ROOT/scripts/package-app.sh"
/usr/bin/codesign --verify --strict --deep "$SOURCE_APP"
[[ -x "$NODE_BIN" && -f "$PI_CLI" && ! -L "$NODE_BIN" && ! -L "$PI_CLI" ]]
[[ "$($NODE_BIN --version)" == "v26.6.0" ]]
[[ "$($NODE_BIN "$PI_CLI" --version)" == "$EXPECTED_PI_VERSION" ]]
"$NODE_BIN" --check "$ROOT/scripts/spikes/pi-keychain-denial-probe.mjs"
"$NODE_BIN" --check "$ROOT/Resources/Pi/extensions/jidoka-deny-user-bash.js"
[[ -f "$SOURCE_BASH_GATE" && ! -L "$SOURCE_BASH_GATE" ]]
[[ "$(/usr/bin/shasum -a 256 "$SOURCE_BASH_GATE" | /usr/bin/awk '{print $1}')" == \
    "ba18988ad739c592920555515ee246e07d325f0e90df345a61de4e7f41a24995" ]]
pi_preflight="$TEMP_ROOT/pi-gate-preflight.json"
pi_preflight_stderr="$TEMP_ROOT/pi-gate-preflight.stderr"
"$NODE_BIN" "$ROOT/scripts/spikes/pi-keychain-denial-probe.mjs" "$SOURCE_BASH_GATE" \
    >"$pi_preflight" 2>"$pi_preflight_stderr"
[[ ! -s "$pi_preflight_stderr" ]]
[[ "$(json_value "$pi_preflight" outcome)" == "blocked" ]]
[[ "$(json_value "$pi_preflight" childCleanup)" == "true" ]]
[[ "$(json_value "$pi_preflight" modelPrompts)" == "0" ]]
invalid_stdout="$TEMP_ROOT/invalid.stdout"
invalid_stderr="$TEMP_ROOT/invalid.stderr"
if (cd / && "$SOURCE_BIN" --keychain export >"$invalid_stdout" 2>"$invalid_stderr"); then
    fail "arbitrary Keychain command unexpectedly succeeded"
fi
[[ ! -s "$invalid_stdout" ]]
/usr/bin/grep -Fq 'invalidArguments' "$invalid_stderr"

if [[ "$MODE" == "preflight" ]]; then
    CLEANUP_DONE=1
    /bin/rm -rf -- "$TEMP_ROOT"
    trap - EXIT
    printf 'S3 Keychain preflight: PASS\n'
    exit 0
fi

[[ ! -e "$TARGET_APP" && ! -L "$TARGET_APP" ]] || fail "target already exists"
[[ ! -e "$EVENT_DIR" && ! -L "$EVENT_DIR" ]] || fail "event directory already exists"
system_keychain_item_absent || fail "exact Keychain item is present or status is ambiguous"
prepare_lock
OWN_EVENT_DIR=1
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
OWN_TARGET=1
/usr/bin/codesign --verify --strict --deep "$TARGET_APP"
[[ "$(keychain_status)" == "false" ]]

seed_output="$TEMP_ROOT/keychain-seed.json"
seed_keychain_item "$seed_output"
DIGEST_ONE="$(json_value "$seed_output" sentinelSHA256)"
assert_digest "$DIGEST_ONE"
[[ "$(json_value "$seed_output" exists)" == "true" ]]
read_one="$TEMP_ROOT/keychain-read-one.json"
run_app_success "$read_one" --keychain read
[[ "$(json_value "$read_one" sentinelSHA256)" == "$DIGEST_ONE" ]]

agent_register="$TEMP_ROOT/agent-register.json"
run_app_success "$agent_register" --lifecycle agent register
[[ "$(json_value "$agent_register" status)" == "enabled" ]]
helper_pid="$(wait_for_exact_helper)" || fail "helper did not become exact within 10 seconds"
[[ -n "$helper_pid" && -z "$(binary_pids "$TARGET_BIN")" ]]
helper_one="$TEMP_ROOT/helper-keychain-one.json"
run_app_success "$helper_one" --lifecycle helper keychain-digest
[[ "$(json_value "$helper_one" keychainSHA256)" == "$DIGEST_ONE" ]]
HELPER_ACCESS=true

replace_output="$TEMP_ROOT/keychain-replace.json"
run_app_success "$replace_output" --keychain replace
DIGEST_TWO="$(json_value "$replace_output" sentinelSHA256)"
assert_digest "$DIGEST_TWO"
[[ "$DIGEST_TWO" != "$DIGEST_ONE" ]]
read_two="$TEMP_ROOT/keychain-read-two.json"
run_app_success "$read_two" --keychain read
[[ "$(json_value "$read_two" sentinelSHA256)" == "$DIGEST_TWO" ]]
helper_two="$TEMP_ROOT/helper-keychain-two.json"
run_app_success "$helper_two" --lifecycle helper keychain-digest
[[ "$(json_value "$helper_two" keychainSHA256)" == "$DIGEST_TWO" ]]
REPLACE_VERIFIED=true

pi_output="$TEMP_ROOT/pi-denial.json"
pi_stderr="$TEMP_ROOT/pi-denial.stderr"
set +e
(
    cd /
    "$NODE_BIN" "$ROOT/scripts/spikes/pi-keychain-denial-probe.mjs" "$TARGET_BASH_GATE"
) >"$pi_output" 2>"$pi_stderr"
pi_status=$?
set -e
/usr/bin/plutil -convert xml1 -o /dev/null "$pi_output" || fail "Pi denial output is not JSON"
outcome="$(json_value "$pi_output" outcome)"
case "$outcome" in
    blocked) ;;
    read) fail "Pi child read the synthetic sentinel" ;;
    executed-denied) fail "Pi direct Bash executed instead of being blocked" ;;
    *) fail "Pi Bash-gate outcome is ambiguous: $outcome" ;;
esac
[[ "$pi_status" == "0" ]]
[[ ! -s "$pi_stderr" ]] || fail "Pi denial wrapper wrote stderr"
[[ "$(json_value "$pi_output" childCleanup)" == "true" ]]
[[ "$(json_value "$pi_output" extensionSHA256)" == \
    "ba18988ad739c592920555515ee246e07d325f0e90df345a61de4e7f41a24995" ]]
[[ "$(json_value "$pi_output" modelPrompts)" == "0" ]]
if /usr/bin/grep -Fq "$DIGEST_TWO" "$pi_output" "$pi_stderr"; then
    fail "denial evidence contains the sentinel digest"
fi
PI_DENIED=true

run_app_success "$TEMP_ROOT/keychain-delete.json" --keychain delete
[[ "$(keychain_status)" == "false" ]]
system_keychain_item_absent || fail "system lookup still finds the exact item"
run_app_success "$TEMP_ROOT/agent-unregister.json" --lifecycle agent unregister
wait_for_inert_status || fail "agent unregister did not converge"
wait_for_agent_absence || fail "agent job or process remains"
[[ -z "$(binary_pids "$TARGET_BIN")" ]]

archive_evidence true false
cleanup_owned_state || fail "final cleanup did not converge"
archive_evidence true true
CLEANUP_DONE=1
/bin/rm -rf -- "$TEMP_ROOT"
trap - EXIT
printf 'S3 Keychain live: PASS\n'
printf 'helper=read replace=verified pi=denied cleanup=verified evidence=%s\n' "$EVIDENCE_DIR"
