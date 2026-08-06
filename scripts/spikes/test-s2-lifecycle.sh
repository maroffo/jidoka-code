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
readonly APP_PARENT="$HOME/Applications"
readonly TARGET_APP="$APP_PARENT/Jidoka Code Probe.app"
readonly TARGET_BIN="$TARGET_APP/Contents/MacOS/Jidoka Code"
readonly TARGET_HELPER="$TARGET_APP/Contents/Helpers/JidokaCodeEngineProbe"
readonly TARGET_PLIST="$TARGET_APP/Contents/Library/LaunchAgents/com.maroffo.JidokaCode.EngineProbe.plist"
readonly SERVICE_LABEL="com.maroffo.JidokaCode.EngineProbe"
readonly SPIKE_PARENT="$HOME/Library/Application Support/JidokaCode/Spike"
readonly LOCK_DIR="$SPIKE_PARENT/S2.lock"
readonly EVENT_DIR="$SPIKE_PARENT/S2"
readonly HELPER_EVENT_LOG="$EVENT_DIR/helper-events.jsonl"
readonly MONOLITH_EVENT_LOG="$EVENT_DIR/monolith-events.jsonl"
readonly SIGN_IDENTITY="${SIGN_IDENTITY:--}"
USER_DOMAIN="gui/$(/usr/bin/id -u)"
readonly USER_DOMAIN
MODE="live"
TEMP_ROOT=""
RUN_ID=""
EVIDENCE_DIR=""
OWN_TARGET=0
OWN_EVENT_DIR=0
OWN_LOCK=0
MAIN_PID=""
MAIN_EXIT_STATUS=""
CLEANUP_DONE=0
DIRECT_RESULT="not-run"
HELPER_RESULT="not-run"
FIRST_HELPER_PID=""
RESTARTED_HELPER_PID=""
UPDATED_HELPER_PID=""

fail() {
    printf 'S2 lifecycle failed: %s\n' "$1" >&2
    exit 1
}

if [[ $# -gt 1 ]]; then
    fail "usage: test-s2-lifecycle.sh [--preflight-only]"
fi
if [[ $# -eq 1 ]]; then
    [[ "$1" == "--preflight-only" ]] || fail "unknown option"
    MODE="preflight"
fi
readonly MODE

json_value() {
    local path="$1"
    local key="$2"
    /usr/bin/plutil -extract "$key" raw "$path"
}

set_launch_agent_generation_two() {
    local plist="$1"
    /usr/bin/plutil -remove ProgramArguments.3 "$plist"
    /usr/bin/plutil -insert ProgramArguments.3 -string 2 "$plist"
    [[ "$(json_value "$plist" ProgramArguments.3)" == "2" ]] || \
        fail "generation-two plist has the wrong argument"
    if /usr/bin/plutil -extract ProgramArguments.4 raw "$plist" >/dev/null 2>&1; then
        fail "generation-two plist contains an extra argument"
    fi
}

sign_outer_app() {
    local app="$1"
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        /usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode.Probe "$app"
    else
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --options runtime \
            --identifier com.maroffo.JidokaCode.Probe "$app"
    fi
}

run_cli() {
    local executable="$1"
    local stdout_path="$2"
    local stderr_path="$3"
    shift 3
    (
        cd /
        "$executable" --lifecycle "$@"
    ) >"$stdout_path" 2>"$stderr_path"
}

run_cli_success() {
    local executable="$1"
    local output="$2"
    local error_output="$output.stderr"
    shift 2
    run_cli "$executable" "$output" "$error_output" "$@"
    [[ ! -s "$error_output" ]] || fail "successful lifecycle command wrote stderr"
    /usr/bin/plutil -convert xml1 -o /dev/null "$output"
    [[ "$(/usr/bin/wc -l < "$output" | /usr/bin/tr -d ' ')" == "1" ]] || \
        fail "lifecycle command did not emit one JSON line"
}

service_status() {
    local executable="$1"
    local service="$2"
    local output="$TEMP_ROOT/status-$service.json"
    run_cli_success "$executable" "$output" "$service" status
    json_value "$output" status
}

require_status() {
    local executable="$1"
    local service="$2"
    local expected="$3"
    local actual
    actual="$(service_status "$executable" "$service")"
    [[ "$actual" == "$expected" ]] || fail "$service status is $actual, expected $expected"
}

status_is_inert() {
    case "$1" in
        notRegistered|notFound) return 0 ;;
        *) return 1 ;;
    esac
}

require_inert_status() {
    local executable="$1"
    local service="$2"
    local actual
    actual="$(service_status "$executable" "$service")"
    status_is_inert "$actual" || fail "$service status is $actual, expected inactive"
}

require_initial_service_absence() {
    require_inert_status "$1" "$2"
}

wait_for_status() {
    local executable="$1"
    local service="$2"
    local expected="$3"
    local timeout="$4"
    local deadline=$((SECONDS + timeout))
    local actual
    while (( SECONDS < deadline )); do
        if actual="$(service_status "$executable" "$service" 2>/dev/null)" && \
            [[ "$actual" == "$expected" ]]
        then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

wait_for_inert_status() {
    local executable="$1"
    local service="$2"
    local timeout="$3"
    local deadline=$((SECONDS + timeout))
    local actual
    while (( SECONDS < deadline )); do
        if actual="$(service_status "$executable" "$service" 2>/dev/null)" && \
            status_is_inert "$actual"
        then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

binary_pids() {
    local executable="$1"
    local output
    if output="$(/usr/sbin/lsof -t -- "$executable" 2>/dev/null)"; then
        printf '%s\n' "$output" | /usr/bin/sort -nu
    fi
}

pid_count() {
    local pids="$1"
    if [[ -z "$pids" ]]; then
        printf '0\n'
    else
        printf '%s\n' "$pids" | /usr/bin/awk 'NF { count++ } END { print count + 0 }'
    fi
}

pid_uses_binary() {
    local pid="$1"
    local executable="$2"
    /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | \
        /usr/bin/grep -Fxq "n$executable"
}

assert_only_binary_pid() {
    local executable="$1"
    local expected_pid="$2"
    local pids
    pids="$(binary_pids "$executable")"
    [[ "$(pid_count "$pids")" == "1" && "$pids" == "$expected_pid" ]] || \
        fail "expected only PID $expected_pid for $executable, found ${pids:-none}"
    pid_uses_binary "$expected_pid" "$executable" || \
        fail "PID $expected_pid does not map to $executable"
}

require_no_binary() {
    local executable="$1"
    local pids
    pids="$(binary_pids "$executable")"
    [[ -z "$pids" ]] || fail "unexpected process for $executable: $pids"
}

wait_for_no_binary() {
    local executable="$1"
    local timeout="$2"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if [[ -z "$(binary_pids "$executable")" ]]; then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

assert_continuous_no_binary() {
    local executable="$1"
    local seconds="$2"
    local deadline=$((SECONDS + seconds))
    while (( SECONDS < deadline )); do
        [[ -z "$(binary_pids "$executable")" ]] || \
            fail "$executable restarted during the graceful-exit observation window"
        /bin/sleep 1
    done
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

wait_for_helper_pid_change() {
    local previous="$1"
    local timeout="$2"
    local deadline=$((SECONDS + timeout))
    local current
    local pids
    while (( SECONDS < deadline )); do
        current="$(launchctl_pid)"
        pids="$(binary_pids "$TARGET_HELPER")"
        if [[ -n "$current" && "$current" != "$previous" && \
            "$(pid_count "$pids")" == "1" && "$pids" == "$current" ]]
        then
            printf '%s\n' "$current"
            return 0
        fi
        if (( $(pid_count "$pids") > 1 )); then
            return 2
        fi
        /bin/sleep 1
    done
    return 1
}

wait_for_no_helper() {
    local timeout="$1"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if [[ -z "$(launchctl_pid)" && -z "$(binary_pids "$TARGET_HELPER")" ]]; then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

wait_for_agent_absence() {
    local timeout="$1"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if ! launchctl_job_exists && [[ -z "$(binary_pids "$TARGET_HELPER")" ]]; then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

assert_continuous_no_helper() {
    local seconds="$1"
    local deadline=$((SECONDS + seconds))
    while (( SECONDS < deadline )); do
        [[ -z "$(launchctl_pid)" && -z "$(binary_pids "$TARGET_HELPER")" ]] || \
            fail "helper restarted during the graceful-exit observation window"
        /bin/sleep 1
    done
}

assert_exact_helper_process() {
    local expected_pid="$1"
    [[ "$(launchctl_pid)" == "$expected_pid" ]] || \
        fail "launchctl does not attribute helper PID $expected_pid"
    assert_only_binary_pid "$TARGET_HELPER" "$expected_pid"
    require_no_binary "$TARGET_BIN"
}

wait_for_file() {
    local path="$1"
    local timeout="$2"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if [[ -f "$path" && ! -L "$path" ]]; then
            return 0
        fi
        /bin/sleep 1
    done
    return 1
}

assert_reconciliation_before_dispatch() {
    local event_log="$1"
    local launch_id="$2"
    local matches="$TEMP_ROOT/events-$launch_id.jsonl"
    local first="$TEMP_ROOT/events-$launch_id-first.json"
    local second="$TEMP_ROOT/events-$launch_id-second.json"

    [[ -f "$event_log" && ! -L "$event_log" ]] || fail "missing regular event log"
    /usr/bin/grep -F "\"launchID\":\"$launch_id\"" "$event_log" >"$matches" || \
        fail "missing events for launch $launch_id"
    [[ "$(/usr/bin/wc -l < "$matches" | /usr/bin/tr -d ' ')" -ge 2 ]] || \
        fail "launch $launch_id lacks reconciliation and dispatch evidence"
    /usr/bin/sed -n '1p' "$matches" >"$first"
    /usr/bin/sed -n '2p' "$matches" >"$second"
    /usr/bin/plutil -convert xml1 -o /dev/null "$first"
    /usr/bin/plutil -convert xml1 -o /dev/null "$second"
    [[ "$(json_value "$first" event)" == "reconciliation" && \
        "$(json_value "$first" sequence)" == "0" ]] || \
        fail "first event for $launch_id is not reconciliation sequence 0"
    [[ "$(json_value "$second" event)" == "dispatch" && \
        "$(json_value "$second" sequence)" == "1" ]] || \
        fail "dispatch does not immediately follow reconciliation for $launch_id"
}

assert_monolith_report() {
    local pid="$1"
    local report="$EVENT_DIR/monolith-$pid.json"
    local launch_id
    wait_for_file "$report" 10 || fail "persistent monolith did not write its report"
    /usr/bin/plutil -convert xml1 -o /dev/null "$report"
    [[ "$(json_value "$report" count)" == "100" ]]
    [[ "$(json_value "$report" duplicateCount)" == "0" ]]
    [[ "$(json_value "$report" ordered)" == "true" ]]
    [[ "$(json_value "$report" snapshot.pid)" == "$pid" ]]
    [[ "$(json_value "$report" snapshot.topology)" == "direct" ]]
    [[ "$(json_value "$report" snapshot.reconciled)" == "true" ]]
    launch_id="$(json_value "$report" snapshot.launchID)"
    assert_reconciliation_before_dispatch "$MONOLITH_EVENT_LOG" "$launch_id"
}

launch_main_child() {
    local phase="$1"
    (
        cd /
        exec "$TARGET_BIN" >"$TEMP_ROOT/main-$phase.stdout" 2>"$TEMP_ROOT/main-$phase.stderr"
    ) &
    MAIN_PID=$!
    assert_monolith_report "$MAIN_PID"
    assert_only_binary_pid "$TARGET_BIN" "$MAIN_PID"
    require_no_binary "$TARGET_HELPER"
}

wait_for_main_child() {
    local timeout="$1"
    local deadline=$((SECONDS + timeout))
    local state
    while (( SECONDS < deadline )); do
        if state="$(/bin/ps -p "$MAIN_PID" -o state= 2>/dev/null)"; then
            case "$state" in
                *Z*) break ;;
            esac
        else
            break
        fi
        /bin/sleep 1
    done
    if (( SECONDS >= deadline )); then
        return 1
    fi
    set +e
    wait "$MAIN_PID"
    MAIN_EXIT_STATUS=$?
    set -e
    return 0
}

wait_for_new_binary_pid() {
    local executable="$1"
    local previous="$2"
    local timeout="$3"
    local deadline=$((SECONDS + timeout))
    local pids
    while (( SECONDS < deadline )); do
        pids="$(binary_pids "$executable")"
        case "$(pid_count "$pids")" in
            0) ;;
            1)
                if [[ "$pids" != "$previous" ]]; then
                    printf '%s\n' "$pids"
                    return 0
                fi
                ;;
            *) return 2 ;;
        esac
        /bin/sleep 1
    done
    return 1
}

prepare_spike_lock() {
    local current="$HOME"
    local component
    for component in "Library" "Application Support" "JidokaCode" "Spike"; do
        current="$current/$component"
        if [[ -e "$current" || -L "$current" ]]; then
            [[ -d "$current" && ! -L "$current" ]] || fail "unsafe lifecycle parent: $current"
        else
            /bin/mkdir "$current"
            /bin/chmod 0700 "$current"
        fi
    done
    /bin/mkdir "$LOCK_DIR" || fail "another S2 run owns the lifecycle lock"
    /bin/chmod 0700 "$LOCK_DIR"
    OWN_LOCK=1
}

guarded_remove_target() {
    [[ "$OWN_TARGET" == "1" && -d "$APP_PARENT" && ! -L "$APP_PARENT" ]] || return 1
    [[ -d "$TARGET_APP" && ! -L "$TARGET_APP" ]] || return 1
    [[ -z "$(binary_pids "$TARGET_BIN")" && -z "$(binary_pids "$TARGET_HELPER")" ]] || return 1
    /bin/rm -rf -- "$TARGET_APP"
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
    if [[ -d "$EVENT_DIR" && ! -L "$EVENT_DIR" ]]; then
        /bin/mkdir -p "$EVIDENCE_DIR/events"
        /usr/bin/find "$EVENT_DIR" -maxdepth 1 -type f -print | while IFS= read -r file; do
            /usr/bin/install -m 0600 "$file" "$EVIDENCE_DIR/events/$(/usr/bin/basename "$file")"
        done
    fi
    printf '{"cleanupVerified":%s,"direct":"%s","firstHelperPID":"%s","helper":"%s","restartHelperPID":"%s","runPassed":%s,"updatedHelperPID":"%s"}\n' \
        "$cleanup_verified" "$DIRECT_RESULT" "$FIRST_HELPER_PID" "$HELPER_RESULT" \
        "$RESTARTED_HELPER_PID" "$run_passed" "$UPDATED_HELPER_PID" \
        >"$EVIDENCE_DIR/summary.json"
    /bin/chmod 0600 "$EVIDENCE_DIR/summary.json"
}

cleanup_services_and_paths() {
    local failed=0
    local status
    local pid
    local pids

    if [[ "$OWN_TARGET" == "1" ]]; then
        if [[ ! -x "$TARGET_BIN" || -L "$TARGET_BIN" ]]; then
            failed=1
        else
            if status="$(service_status "$TARGET_BIN" agent 2>/dev/null)"; then
                if ! status_is_inert "$status"; then
                    run_cli "$TARGET_BIN" "$TEMP_ROOT/cleanup-agent.json" \
                        "$TEMP_ROOT/cleanup-agent.stderr" agent unregister
                fi
            else
                failed=1
            fi
            wait_for_inert_status "$TARGET_BIN" agent 10 || failed=1

            if status="$(service_status "$TARGET_BIN" main 2>/dev/null)"; then
                if ! status_is_inert "$status"; then
                    run_cli "$TARGET_BIN" "$TEMP_ROOT/cleanup-main.json" \
                        "$TEMP_ROOT/cleanup-main.stderr" main unregister
                fi
            else
                failed=1
            fi
            wait_for_inert_status "$TARGET_BIN" main 10 || failed=1

            if ! wait_for_agent_absence 10; then
                pid="$(launchctl_pid)"
                if [[ -n "$pid" ]] && pid_uses_binary "$pid" "$TARGET_HELPER"; then
                    /bin/kill -KILL "$pid"
                fi
                wait_for_agent_absence 10 || failed=1
            fi

            pids="$(binary_pids "$TARGET_BIN")"
            if [[ -n "$pids" ]]; then
                run_cli "$TARGET_BIN" "$TEMP_ROOT/cleanup-quit.json" \
                    "$TEMP_ROOT/cleanup-quit.stderr" main graceful-quit
                wait_for_no_binary "$TARGET_BIN" 10
                pids="$(binary_pids "$TARGET_BIN")"
                if [[ "$(pid_count "$pids")" == "1" ]]; then
                    pid="$pids"
                    if pid_uses_binary "$pid" "$TARGET_BIN"; then
                        /bin/kill -TERM "$pid"
                    fi
                    wait_for_no_binary "$TARGET_BIN" 10 || failed=1
                elif [[ -n "$pids" ]]; then
                    failed=1
                fi
            fi
        fi
    fi

    if [[ "$failed" != "0" ]]; then
        return 1
    fi
    if [[ "$OWN_TARGET" == "1" ]]; then
        guarded_remove_target || return 1
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
    return 0
}

cleanup_on_exit() {
    local original_status=$?
    local cleanup_status=0
    local archive_status=0
    trap - EXIT
    if [[ "$CLEANUP_DONE" == "1" ]]; then
        exit "$original_status"
    fi
    set +e
    if [[ -n "$EVIDENCE_DIR" ]]; then
        archive_evidence false false
        archive_status=$?
    fi
    cleanup_services_and_paths
    cleanup_status=$?
    if [[ "$cleanup_status" == "0" && -n "$EVIDENCE_DIR" ]]; then
        archive_evidence false true
    fi
    if [[ "$cleanup_status" != "0" ]]; then
        printf 'S2 cleanup ambiguous; preserving target=%s events=%s temp=%s\n' \
            "$TARGET_APP" "$EVENT_DIR" "$TEMP_ROOT" >&2
        exit 1
    fi
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        case "$RUN_ID" in
            jidoka-code-s2.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
        esac
    fi
    if [[ "$archive_status" != "0" ]]; then
        exit 1
    fi
    exit "$original_status"
}

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-s2.XXXXXX")"
readonly TEMP_ROOT
RUN_ID="$(/usr/bin/basename "$TEMP_ROOT")"
readonly RUN_ID
EVIDENCE_DIR="$ROOT/build/evidence/$RUN_ID"
readonly EVIDENCE_DIR
trap cleanup_on_exit EXIT

"$ROOT/scripts/package-app.sh"
readonly SOURCE_PLIST="$SOURCE_APP/Contents/Library/LaunchAgents/com.maroffo.JidokaCode.EngineProbe.plist"
/usr/bin/plutil -lint "$SOURCE_PLIST"
[[ "$(json_value "$SOURCE_PLIST" Label)" == "$SERVICE_LABEL" ]]
[[ "$(json_value "$SOURCE_PLIST" BundleProgram)" == "Contents/Helpers/JidokaCodeEngineProbe" ]]
[[ "$(json_value "$SOURCE_PLIST" ProgramArguments.3)" == "1" ]]
[[ "$(json_value "$SOURCE_PLIST" RunAtLoad)" == "true" ]]
[[ "$(json_value "$SOURCE_PLIST" KeepAlive.SuccessfulExit)" == "false" ]]
[[ "$(json_value "$SOURCE_PLIST" 'MachServices.com\.maroffo\.JidokaCode\.EngineProbe')" == "true" ]]
generation_two_preflight="$TEMP_ROOT/generation-two.plist"
/bin/cp "$SOURCE_PLIST" "$generation_two_preflight"
set_launch_agent_generation_two "$generation_two_preflight"
/usr/bin/plutil -lint "$generation_two_preflight"
/usr/bin/codesign --verify --strict --deep "$SOURCE_APP"

direct_output="$TEMP_ROOT/direct.json"
run_cli_success "$SOURCE_BIN" "$direct_output" direct round-trips 100
[[ "$(json_value "$direct_output" action)" == "direct.round-trips" ]]
[[ "$(json_value "$direct_output" roundTrips.count)" == "100" ]]
[[ "$(json_value "$direct_output" roundTrips.duplicateCount)" == "0" ]]
[[ "$(json_value "$direct_output" roundTrips.ordered)" == "true" ]]
[[ "$(json_value "$direct_output" snapshot.topology)" == "direct" ]]

invalid_stdout="$TEMP_ROOT/invalid.stdout"
invalid_stderr="$TEMP_ROOT/invalid.stderr"
if run_cli "$SOURCE_BIN" "$invalid_stdout" "$invalid_stderr" helper run /tmp/arbitrary; then
    fail "arbitrary lifecycle command unexpectedly succeeded"
fi
[[ ! -s "$invalid_stdout" ]] || fail "invalid lifecycle command wrote stdout"
/usr/bin/grep -Fq 'invalidArguments' "$invalid_stderr" || fail "invalid lifecycle command lacked evidence"

if [[ "$MODE" == "preflight" ]]; then
    direct_json="$(<"$direct_output")"
    CLEANUP_DONE=1
    /bin/rm -rf -- "$TEMP_ROOT"
    trap - EXIT
    printf 'S2 lifecycle preflight: PASS\n'
    printf 'direct=%s\n' "$direct_json"
    exit 0
fi

[[ ! -e "$TARGET_APP" && ! -L "$TARGET_APP" ]] || fail "live target already exists"
[[ ! -e "$EVENT_DIR" && ! -L "$EVENT_DIR" ]] || fail "lifecycle event directory already exists"
[[ -d "$APP_PARENT" && ! -L "$APP_PARENT" ]] || fail "$APP_PARENT must be a regular directory"
require_initial_service_absence "$SOURCE_BIN" main
require_initial_service_absence "$SOURCE_BIN" agent
[[ -z "$(launchctl_pid)" ]] || fail "helper launchd job already exists"
require_no_binary "$SOURCE_BIN"
prepare_spike_lock
OWN_EVENT_DIR=1
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
OWN_TARGET=1
/usr/bin/codesign --verify --strict --deep "$TARGET_APP"

main_register="$TEMP_ROOT/main-register.json"
run_cli_success "$TARGET_BIN" "$main_register" main register
require_status "$TARGET_BIN" main enabled
require_inert_status "$TARGET_BIN" agent
launch_main_child initial
run_cli_success "$TARGET_BIN" "$TEMP_ROOT/main-graceful.json" main graceful-quit
wait_for_main_child 10 || fail "main app did not finish graceful exit"
[[ "$MAIN_EXIT_STATUS" == "0" ]] || fail "main graceful exit status was $MAIN_EXIT_STATUS"
MAIN_PID=""
assert_continuous_no_binary "$TARGET_BIN" 31
launch_main_child reopen
reopened_pid="$MAIN_PID"
/bin/kill -KILL "$reopened_pid"
wait_for_main_child 10 || fail "main app did not terminate after SIGKILL"
[[ "$MAIN_EXIT_STATUS" != "0" ]] || fail "main crash probe exited successfully"
MAIN_PID=""
set +e
auto_restarted_pid="$(wait_for_new_binary_pid "$TARGET_BIN" "$reopened_pid" 30)"
auto_restart_status=$?
set -e
case "$auto_restart_status" in
    0)
        assert_only_binary_pid "$TARGET_BIN" "$auto_restarted_pid"
        assert_monolith_report "$auto_restarted_pid"
        run_cli_success "$TARGET_BIN" "$TEMP_ROOT/main-post-crash-graceful.json" main graceful-quit
        wait_for_no_binary "$TARGET_BIN" 10 || fail "auto-restarted main did not exit gracefully"
        assert_continuous_no_binary "$TARGET_BIN" 31
        DIRECT_RESULT="passed"
        ;;
    1)
        DIRECT_RESULT="discarded:no-crash-restart"
        ;;
    *) fail "multiple monolith processes appeared after crash" ;;
esac
require_no_binary "$TARGET_BIN"
run_cli_success "$TARGET_BIN" "$TEMP_ROOT/main-unregister.json" main unregister
wait_for_inert_status "$TARGET_BIN" main 10 || fail "main unregister did not converge"
require_inert_status "$TARGET_BIN" agent

agent_register="$TEMP_ROOT/agent-register.json"
run_cli_success "$TARGET_BIN" "$agent_register" agent register
require_status "$TARGET_BIN" agent enabled
set +e
FIRST_HELPER_PID="$(wait_for_helper_pid_change "" 10)"
helper_launch_status=$?
set -e
[[ "$helper_launch_status" == "0" ]] || fail "helper did not become exactly-one within 10 seconds"
assert_exact_helper_process "$FIRST_HELPER_PID"
helper_round_trips="$TEMP_ROOT/helper-round-trips.json"
run_cli_success "$TARGET_BIN" "$helper_round_trips" helper round-trips 100
[[ "$(json_value "$helper_round_trips" roundTrips.count)" == "100" ]]
[[ "$(json_value "$helper_round_trips" roundTrips.duplicateCount)" == "0" ]]
[[ "$(json_value "$helper_round_trips" roundTrips.ordered)" == "true" ]]
[[ "$(json_value "$helper_round_trips" snapshot.pid)" == "$FIRST_HELPER_PID" ]]
[[ "$(json_value "$helper_round_trips" snapshot.generation)" == "1" ]]
first_launch="$(json_value "$helper_round_trips" snapshot.launchID)"
assert_reconciliation_before_dispatch "$HELPER_EVENT_LOG" "$first_launch"

run_cli_success "$TARGET_BIN" "$TEMP_ROOT/helper-crash.json" helper crash
set +e
RESTARTED_HELPER_PID="$(wait_for_helper_pid_change "$FIRST_HELPER_PID" 30)"
helper_restart_status=$?
set -e
[[ "$helper_restart_status" == "0" ]] || fail "helper did not restart exactly-once within 30 seconds"
assert_exact_helper_process "$RESTARTED_HELPER_PID"
restarted_snapshot="$TEMP_ROOT/restarted-snapshot.json"
run_cli_success "$TARGET_BIN" "$restarted_snapshot" helper snapshot
[[ "$(json_value "$restarted_snapshot" snapshot.pid)" == "$RESTARTED_HELPER_PID" ]]
restarted_launch="$(json_value "$restarted_snapshot" snapshot.launchID)"
[[ "$restarted_launch" != "$first_launch" ]] || fail "crash restart reused launch identity"
assert_reconciliation_before_dispatch "$HELPER_EVENT_LOG" "$restarted_launch"

run_cli_success "$TARGET_BIN" "$TEMP_ROOT/helper-graceful.json" helper graceful-quit
wait_for_no_helper 10 || fail "helper did not exit gracefully"
assert_continuous_no_helper 31
reopen_snapshot="$TEMP_ROOT/reopen-snapshot.json"
run_cli_success "$TARGET_BIN" "$reopen_snapshot" helper snapshot
reopen_pid="$(json_value "$reopen_snapshot" snapshot.pid)"
[[ "$reopen_pid" != "$RESTARTED_HELPER_PID" ]] || fail "on-demand reopen reused helper PID"
assert_exact_helper_process "$reopen_pid"
assert_reconciliation_before_dispatch \
    "$HELPER_EVENT_LOG" "$(json_value "$reopen_snapshot" snapshot.launchID)"

run_cli_success "$TARGET_BIN" "$TEMP_ROOT/agent-unregister.json" agent unregister
wait_for_inert_status "$TARGET_BIN" agent 10 || fail "agent unregister did not converge"
wait_for_agent_absence 10 || fail "helper job remained after unregister"
require_inert_status "$TARGET_BIN" main
require_no_binary "$TARGET_BIN"

staging_app="$TEMP_ROOT/Jidoka Code Probe v2.app"
/usr/bin/ditto "$TARGET_APP" "$staging_app"
staging_plist="$staging_app/Contents/Library/LaunchAgents/com.maroffo.JidokaCode.EngineProbe.plist"
set_launch_agent_generation_two "$staging_plist"
sign_outer_app "$staging_app"
/usr/bin/codesign --verify --strict --deep "$staging_app"
generation_one_digest="$(/usr/bin/shasum -a 256 "$TARGET_PLIST" | /usr/bin/awk '{print $1}')"
generation_two_digest="$(/usr/bin/shasum -a 256 "$staging_plist" | /usr/bin/awk '{print $1}')"
[[ "$generation_one_digest" != "$generation_two_digest" ]] || fail "generation update did not change plist bytes"
guarded_remove_target || fail "could not replace inert generation-one target"
/usr/bin/ditto "$staging_app" "$TARGET_APP"
/usr/bin/codesign --verify --strict --deep "$TARGET_APP"
[[ "$(json_value "$TARGET_PLIST" ProgramArguments.3)" == "2" ]]
require_inert_status "$TARGET_BIN" main
require_inert_status "$TARGET_BIN" agent

run_cli_success "$TARGET_BIN" "$TEMP_ROOT/agent-reregister.json" agent register
require_status "$TARGET_BIN" agent enabled
set +e
UPDATED_HELPER_PID="$(wait_for_helper_pid_change "" 10)"
updated_launch_status=$?
set -e
[[ "$updated_launch_status" == "0" ]] || fail "generation-two helper did not become exactly-one"
[[ "$UPDATED_HELPER_PID" != "$FIRST_HELPER_PID" && \
    "$UPDATED_HELPER_PID" != "$RESTARTED_HELPER_PID" ]] || \
    fail "generation-two helper reused an earlier PID"
assert_exact_helper_process "$UPDATED_HELPER_PID"
updated_round_trips="$TEMP_ROOT/updated-round-trips.json"
run_cli_success "$TARGET_BIN" "$updated_round_trips" helper round-trips 100
[[ "$(json_value "$updated_round_trips" snapshot.pid)" == "$UPDATED_HELPER_PID" ]]
[[ "$(json_value "$updated_round_trips" snapshot.generation)" == "2" ]]
[[ "$(json_value "$updated_round_trips" roundTrips.count)" == "100" ]]
[[ "$(json_value "$updated_round_trips" roundTrips.duplicateCount)" == "0" ]]
assert_reconciliation_before_dispatch \
    "$HELPER_EVENT_LOG" "$(json_value "$updated_round_trips" snapshot.launchID)"
HELPER_RESULT="passed"

run_cli_success "$TARGET_BIN" "$TEMP_ROOT/final-agent-unregister.json" agent unregister
wait_for_inert_status "$TARGET_BIN" agent 10 || fail "final agent unregister did not converge"
wait_for_agent_absence 10 || fail "helper job remained after final unregister"
require_inert_status "$TARGET_BIN" main
require_no_binary "$TARGET_BIN"

[[ "$HELPER_RESULT" == "passed" ]] || fail "no helper topology passed"
archive_evidence true false
cleanup_services_and_paths || fail "final cleanup did not converge; owned artifacts preserved"
archive_evidence true true
CLEANUP_DONE=1
if [[ -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
    /bin/rm -rf -- "$TEMP_ROOT"
fi
trap - EXIT

printf 'S2 lifecycle live: PASS\n'
printf 'direct=%s helper=%s pids=%s->%s->%s cleanup=verified\n' \
    "$DIRECT_RESULT" "$HELPER_RESULT" "$FIRST_HELPER_PID" \
    "$RESTARTED_HELPER_PID" "$UPDATED_HELPER_PID"
printf 'evidence=%s\n' "$EVIDENCE_DIR"
