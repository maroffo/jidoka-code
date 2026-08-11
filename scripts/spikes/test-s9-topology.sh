#!/usr/bin/env bash
set -euo pipefail

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly APP="$ROOT/build/Jidoka Code.app"
readonly APP_EXECUTABLE="$APP/Contents/MacOS/Jidoka Code"
readonly HELPER="$APP/Contents/Helpers/JidokaCodeEngineProbe"
readonly DECISION="$ROOT/docs/evidence/topology-decision.json"
readonly SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MODE="live"
TEMP_ROOT=""
EVIDENCE_DIR=""
APP_LAUNCH_PID=""
APP_LAUNCH_START=""
OWN_APP=0

fail() {
    printf 'S9 topology failed: %s\n' "$1" >&2
    exit 1
}

if [[ $# -gt 1 ]]; then
    fail "usage: test-s9-topology.sh [--preflight-only]"
fi
if [[ $# -eq 1 ]]; then
    [[ "$1" == "--preflight-only" ]] || fail "unknown option"
    MODE="preflight"
fi
readonly MODE

exact_app_pids() {
    /bin/ps -axo pid=,command= | /usr/bin/awk -v target="$APP_EXECUTABLE" '
        {
            pid = $1
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
            if ($0 == target) print pid
        }
    '
}

process_start_identity() {
    /bin/ps -p "$1" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}

process_command() {
    /bin/ps -p "$1" -o command= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}

owned_app_is_exact() {
    [[ "$OWN_APP" == "1" && "$APP_LAUNCH_PID" =~ ^[0-9]+$ && \
        -n "$APP_LAUNCH_START" ]] || return 1
    [[ "$(process_start_identity "$APP_LAUNCH_PID")" == "$APP_LAUNCH_START" && \
        "$(process_command "$APP_LAUNCH_PID")" == "$APP_EXECUTABLE" ]]
}

stop_owned_app_process() {
    [[ "$OWN_APP" == "1" ]] || return 0
    if ! /bin/kill -0 "$APP_LAUNCH_PID" 2>/dev/null; then
        return 0
    fi
    owned_app_is_exact || return 1
    /bin/kill -TERM "$APP_LAUNCH_PID" 2>/dev/null || true
    for _ in {1..50}; do
        owned_app_is_exact || return 0
        /bin/sleep 0.1
    done
    owned_app_is_exact || return 0
    /bin/kill -KILL "$APP_LAUNCH_PID" 2>/dev/null || true
    /bin/sleep 0.2
    ! owned_app_is_exact
}

cleanup() {
    local status=$?
    trap - EXIT
    stop_owned_app_process || status=1
    if [[ "$OWN_APP" == "1" && -n "$APP_LAUNCH_PID" ]]; then
        wait "$APP_LAUNCH_PID" 2>/dev/null || true
    fi
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        case "$(/usr/bin/basename "$TEMP_ROOT")" in
            jidoka-code-s9.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
        esac
    fi
    exit "$status"
}

[[ ! -e "$ROOT/Sources/JidokaCodeApp/MonolithLifecycleProbe.swift" ]] || \
    fail "non-selected monolith probe source remains"
[[ -f "$DECISION" && ! -L "$DECISION" ]] || fail "topology decision is absent"
/usr/bin/plutil -convert xml1 -o /dev/null "$DECISION"
[[ "$(/usr/bin/plutil -extract decision raw "$DECISION")" == "53" ]]
[[ "$(/usr/bin/plutil -extract supersedes raw "$DECISION")" == "35" ]]
[[ "$(/usr/bin/plutil -extract status raw "$DECISION")" == "locked" ]]
[[ "$(/usr/bin/plutil -extract selectedTopology raw "$DECISION")" == "launch-agent-helper" ]]
[[ "$(/usr/bin/plutil -extract bundleDisposition.monolithProbeSourceRemoved raw "$DECISION")" == "true" ]]

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-s9.XXXXXX")"
readonly TEMP_ROOT
EVIDENCE_DIR="$ROOT/build/evidence/$(/usr/bin/basename "$TEMP_ROOT")"
readonly EVIDENCE_DIR
trap cleanup EXIT
/bin/mkdir -p "$TEMP_ROOT/home" "$TEMP_ROOT/runtime" "$EVIDENCE_DIR"
/bin/chmod 0700 "$TEMP_ROOT/home" "$TEMP_ROOT/runtime" "$EVIDENCE_DIR"

if [[ "$MODE" == "preflight" ]]; then
    ALLOW_ADHOC_SIGNING=1 "$ROOT/scripts/package-app.sh"
else
    "$ROOT/scripts/package-app.sh"
fi
/usr/bin/codesign --verify --strict --deep "$APP"
[[ -x "$HELPER" && ! -L "$HELPER" ]] || fail "selected helper is absent"
[[ -f "$APP/Contents/Library/LaunchAgents/com.maroffo.JidokaCode.Engine.plist" ]] || \
    fail "selected helper service declaration is absent"
if /usr/bin/strings -a "$APP_EXECUTABLE" | /usr/bin/grep -Eq \
    'MonolithLifecycleProbe|monolith-events|monolith lifecycle probe failed'; then
    fail "non-selected monolith probe remains in executable"
fi

[[ -z "$(exact_app_pids)" ]] || fail "an exact probe app process already exists"
if [[ "$MODE" == "preflight" ]]; then
    /usr/bin/install -m 0600 "$DECISION" "$EVIDENCE_DIR/topology-decision.json"
    printf '{"normalAppLaunch":"not-run-preflight","selectedTopology":"launch-agent-helper","signed":false}\n' \
        >"$EVIDENCE_DIR/summary.json"
    /bin/chmod 0600 "$EVIDENCE_DIR/summary.json"
    printf 'S9 topology preflight: PASS\n'
    printf 'selected=launch-agent-helper normal_app_launch=not-run default_socket_contacts=0\n'
    exit 0
fi
(
    cd /
    exec /usr/bin/env -i \
        HOME="$TEMP_ROOT/home" \
        PATH="/usr/bin:/bin" \
        TMPDIR="$TEMP_ROOT/runtime" \
        "$APP_EXECUTABLE"
) >"$TEMP_ROOT/app.stdout" 2>"$TEMP_ROOT/app.stderr" &
APP_LAUNCH_PID=$!
OWN_APP=1
for _ in {1..50}; do
    APP_LAUNCH_START="$(process_start_identity "$APP_LAUNCH_PID")"
    [[ -n "$APP_LAUNCH_START" ]] && break
    /bin/sleep 0.1
done
[[ -n "$APP_LAUNCH_START" ]] || fail "selected-topology app start identity is unavailable"
for _ in {1..50}; do
    owned_app_is_exact && break
    /bin/sleep 0.1
done
owned_app_is_exact || fail "selected-topology app did not become exact"
[[ "$(exact_app_pids)" == "$APP_LAUNCH_PID" ]] || \
    fail "selected-topology app process inventory is ambiguous"
/bin/sleep 2
[[ ! -e "$TEMP_ROOT/home/Library/Application Support/JidokaCode/Spike/S2" ]] || \
    fail "normal app launch executed the removed monolith probe"
[[ ! -s "$TEMP_ROOT/app.stdout" && ! -s "$TEMP_ROOT/app.stderr" ]] || \
    fail "normal selected-topology launch wrote output"
if ! (
    cd /
    /usr/bin/env -i \
        HOME="$TEMP_ROOT/home" \
        PATH="/usr/bin:/bin" \
        TMPDIR="$TEMP_ROOT/runtime" \
        "$APP_EXECUTABLE" --lifecycle main graceful-quit
) >"$TEMP_ROOT/graceful.json" 2>"$TEMP_ROOT/graceful.stderr"; then
    fail "selected-topology graceful quit command failed"
fi
[[ ! -s "$TEMP_ROOT/graceful.stderr" ]] || fail "graceful quit command wrote stderr"
[[ "$(/usr/bin/plutil -extract action raw "$TEMP_ROOT/graceful.json")" == \
    "main.graceful-quit" ]] || fail "graceful quit acknowledgement differs"
for _ in {1..50}; do
    owned_app_is_exact || break
    /bin/sleep 0.1
done
owned_app_is_exact && fail "owned probe app process survived graceful quit"
wait "$APP_LAUNCH_PID" 2>/dev/null || true
OWN_APP=0
APP_LAUNCH_PID=""
APP_LAUNCH_START=""
[[ -z "$(exact_app_pids)" ]] || fail "an unowned exact app process appeared during S9"

if [[ "$MODE" == "live" ]]; then
    [[ "$SIGN_IDENTITY" != "-" ]] || fail "live S9 requires an explicit signing identity"
    app_details="$(/usr/bin/codesign -dvvv "$APP" 2>&1)"
    helper_details="$(/usr/bin/codesign -dvvv "$HELPER" 2>&1)"
    [[ "$app_details" == *"Authority=Apple Development:"* ]] || \
        fail "live S9 app is not Apple Development signed"
    app_team="$(printf '%s\n' "$app_details" | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    helper_team="$(printf '%s\n' "$helper_details" | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    [[ -n "$app_team" && "$app_team" == "$helper_team" ]] || fail "app/helper team mismatch"
fi

/usr/bin/install -m 0600 "$DECISION" "$EVIDENCE_DIR/topology-decision.json"
/usr/bin/install -m 0600 "$TEMP_ROOT/graceful.json" "$EVIDENCE_DIR/graceful-quit.json"
printf '{"appStayedRunning":true,"cleanupVerified":true,"exactProcessCleanup":true,"monolithAbsent":true,"selectedTopology":"launch-agent-helper","signed":%s}\n' \
    "$([[ "$SIGN_IDENTITY" == "-" ]] && printf false || printf true)" \
    >"$EVIDENCE_DIR/summary.json"
/bin/chmod 0600 "$EVIDENCE_DIR/summary.json"
printf 'S9 topology: PASS\n'
printf 'selected=launch-agent-helper monolith=removed cleanup=verified evidence=%s\n' \
    "$EVIDENCE_DIR"
