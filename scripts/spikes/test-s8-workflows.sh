#!/usr/bin/env bash
set -euo pipefail

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly APP="$ROOT/build/Jidoka Code.app"
readonly APP_EXECUTABLE="$APP/Contents/MacOS/Jidoka Code"
readonly SOURCE_RUNNER="$ROOT/scripts/spikes/pi-rpc-workflow-probe.mjs"
readonly PACKAGED_RUNNER="$APP/Contents/Resources/Pi/runtime/pi-rpc-workflow-probe.mjs"
readonly NODE_BIN="/opt/homebrew/Cellar/node/26.6.0/bin/node"
readonly SHARED_LEDGER="$HOME/Library/Application Support/JidokaCode/Consent/provider-call-ledger.json"
readonly EXPECTED_RUNNER_SHA256="bba864cfe69d5f5f8ebac05fce1e86da3ff5276577246e612a5003f6bbf7a9cb"
readonly EXPECTED_PI_POLICY_SHA256="eeea3f11e4e352f2b772424dea1dd85273d7af559c6e9e69ff280abac9681f27"
readonly SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MODE="live"
TEMP_ROOT=""
EVIDENCE_DIR=""

fail() {
    printf 'S8 workflow fidelity failed: %s\n' "$1" >&2
    exit 1
}

if [[ $# -gt 1 ]]; then
    fail "usage: test-s8-workflows.sh [--preflight-only]"
fi
if [[ $# -eq 1 ]]; then
    [[ "$1" == "--preflight-only" ]] || fail "unknown option"
    MODE="preflight"
fi
readonly MODE

json_value() {
    /usr/bin/plutil -extract "$2" raw "$1"
}

workspace_inventory() {
    /usr/bin/find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'jidoka-code-workflow-workspace-*' -print | \
        LC_ALL=C /usr/bin/sort
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        case "$(/usr/bin/basename "$TEMP_ROOT")" in
            jidoka-code-s8.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
        esac
    fi
    exit "$status"
}

run_app() {
    local output="$1"
    local stderr="$2"
    shift 2
    if ! (
        cd /
        /usr/bin/env -i \
            HOME="${PROBE_HOME:-$HOME}" \
            PATH="/opt/homebrew/bin:/usr/bin:/bin" \
            TMPDIR="${TMPDIR:-/tmp}" \
            "$APP_EXECUTABLE" "$@"
    ) >"$output" 2>"$stderr"; then
        [[ ! -f "$output" ]] || /usr/bin/install -m 0600 "$output" "$EVIDENCE_DIR/failed-$(/usr/bin/basename "$output")"
        [[ ! -f "$stderr" ]] || /usr/bin/install -m 0600 "$stderr" "$EVIDENCE_DIR/failed-$(/usr/bin/basename "$stderr")"
        /bin/cat "$stderr" >&2
        fail "packaged workflow command failed: $*"
    fi
    [[ ! -s "$stderr" ]] || fail "successful workflow command wrote stderr: $*"
    /usr/bin/plutil -convert xml1 -o /dev/null "$output"
}

validate_live_report() {
    # The JavaScript template literal is intentionally protected from Bash expansion.
    # shellcheck disable=SC2016
    "$NODE_BIN" -e '
      const fs = require("node:fs");
      const report = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const expectedCounts = {"pr-review": 4, "issue-triage": 1, planning: 5, orchestration: 5};
      if (
        report.schemaVersion !== 1 || report.mode !== "live" ||
        report.callsConsumed !== 19 || report.providerCalls !== 15 ||
        report.cleanupVerified !== true || !Array.isArray(report.roles) ||
        report.roles.length !== 15 || !Array.isArray(report.invariantEvidence) ||
        report.invariantEvidence.length !== 29
      ) process.exit(2);
      const counts = {};
      for (let index = 0; index < report.roles.length; index += 1) {
        const role = report.roles[index];
        counts[role.workflow] = (counts[role.workflow] ?? 0) + 1;
        if (
          role.agentSettled !== true || role.bashBlocked !== true ||
          role.callsConsumed !== index + 5 || role.commandCount !== 3 ||
          role.providerCalls !== 1 || role.childCleanup !== true ||
          role.providerTransport !== "sse" || role.toolExecutions !== 0 ||
          role.stderrSHA256 !== "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ||
          role.result?.schemaVersion !== 1 || role.result?.fixtureId !== role.fixtureId ||
          role.result?.role !== role.role || role.result?.workflow !== role.workflow ||
          !Array.isArray(role.result?.invariants) ||
          role.result.invariants.length !== role.result.preconditions?.length ||
          role.result.invariants.length !== role.result.actions?.length ||
          role.result.invariants.length !== role.result.postconditions?.length ||
          !Number.isFinite(role.usage?.assistant?.input) || role.usage.assistant.input <= 0 ||
          !Number.isFinite(role.usage?.assistant?.output) || role.usage.assistant.output <= 0
        ) process.exit(3);
      }
      if (JSON.stringify(counts) !== JSON.stringify(expectedCounts)) process.exit(4);
      const mappingKeys = new Set(report.invariantEvidence.map((entry) =>
        `${entry.fixtureId ?? entry.evidence?.fixtureId}:${entry.invariant}`));
      if (mappingKeys.size !== 29) process.exit(5);
      process.stdout.write("15");
    ' "$1"
}

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-s8.XXXXXX")"
readonly TEMP_ROOT
readonly PREFLIGHT_HOME="$TEMP_ROOT/preflight-home"
/bin/mkdir -m 0700 "$PREFLIGHT_HOME"
EVIDENCE_DIR="$ROOT/build/evidence/$(/usr/bin/basename "$TEMP_ROOT")"
readonly EVIDENCE_DIR
trap cleanup EXIT

"$ROOT/scripts/package-app.sh"
/usr/bin/codesign --verify --strict --deep "$APP"
[[ -f "$PACKAGED_RUNNER" && ! -L "$PACKAGED_RUNNER" ]] || fail "packaged workflow runner is absent"
"$NODE_BIN" --check "$SOURCE_RUNNER"
source_sha="$(/usr/bin/shasum -a 256 "$SOURCE_RUNNER" | /usr/bin/awk '{print $1}')"
packaged_sha="$(/usr/bin/shasum -a 256 "$PACKAGED_RUNNER" | /usr/bin/awk '{print $1}')"
[[ "$source_sha" == "$EXPECTED_RUNNER_SHA256" ]] || fail "source workflow runner digest drift"
[[ "$packaged_sha" == "$EXPECTED_RUNNER_SHA256" ]] || fail "packaged workflow runner digest drift"
[[ -f "$SHARED_LEDGER" && ! -L "$SHARED_LEDGER" ]] || fail "shared provider ledger is absent"

/bin/mkdir -p "$EVIDENCE_DIR"
/bin/chmod 0700 "$EVIDENCE_DIR"
workspace_baseline="$(workspace_inventory)"
readonly workspace_baseline

closed_stdout="$TEMP_ROOT/closed.stdout"
closed_stderr="$TEMP_ROOT/closed.stderr"
if (
    cd /
    /usr/bin/env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
        "$APP_EXECUTABLE" --workflow-probe live extra
) >"$closed_stdout" 2>"$closed_stderr"; then
    fail "packaged app accepted an open workflow command"
fi
[[ ! -s "$closed_stdout" ]] || fail "rejected workflow command wrote stdout"
/usr/bin/grep -Fq 'invalidArguments' "$closed_stderr" || fail "workflow rejection was ambiguous"

preflight="$TEMP_ROOT/preflight.json"
PROBE_HOME="$PREFLIGHT_HOME" run_app \
    "$preflight" "$TEMP_ROOT/preflight.stderr" --workflow-probe preflight
[[ "$(json_value "$preflight" mode)" == "preflight" ]]
[[ "$(json_value "$preflight" credentialAccess)" == "false" ]]
[[ "$(json_value "$preflight" goldenInvariantCount)" == "18" ]]
[[ "$(json_value "$preflight" ledger.s4Settled)" == "4" ]]
[[ "$(json_value "$preflight" providerCalls)" == "0" ]]
[[ "$(json_value "$preflight" piVersion)" == "0.84.0" ]]
[[ "$(json_value "$preflight" piCompatibility.minimumVersion)" == "0.84.0" ]]
[[ "$(json_value "$preflight" piCompatibility.maximumVersionExclusive)" == "0.90.0" ]]
[[ "$(json_value "$preflight" piCompatibility.policySHA256)" == \
    "$EXPECTED_PI_POLICY_SHA256" ]]
[[ "$(json_value "$preflight" roleMatrix.prReview)" == "4" ]]
[[ "$(json_value "$preflight" roleMatrix.triage)" == "1" ]]
[[ "$(json_value "$preflight" roleMatrix.planning)" == "5" ]]
[[ "$(json_value "$preflight" roleMatrix.orchestration)" == "5" ]]
[[ ! -e "$PREFLIGHT_HOME/.pi" && ! -L "$PREFLIGHT_HOME/.pi" ]] || \
    fail "credential-free workflow preflight touched isolated HOME"
/usr/bin/install -m 0600 "$preflight" "$EVIDENCE_DIR/preflight.json"

s8_settled="$(json_value "$preflight" ledger.s8Settled)"
remaining="$(json_value "$preflight" ledger.remaining)"
if [[ "$MODE" == "preflight" ]]; then
    if [[ "$s8_settled" == "0" ]]; then
        [[ "$remaining" == "15" ]] || fail "preflight ledger remaining count differs from fifteen"
    else
        [[ "$s8_settled" == "15" && "$remaining" == "0" ]] || \
            fail "preflight ledger is at a partial S8 boundary"
    fi
    [[ "$(workspace_inventory)" == "$workspace_baseline" ]] || \
        fail "workflow workspace survived preflight"
    printf 'S8 workflow preflight: PASS\n'
    printf 'providerCalls=0 commandProfiles=4 roleMatrix=15 historicalS8Settled=%s evidence=%s\n' \
        "$s8_settled" "$EVIDENCE_DIR"
    exit 0
fi

[[ "$s8_settled" == "0" && "$remaining" == "15" ]] || \
    fail "live S8 requires fifteen unconsumed authorized calls"
[[ "$SIGN_IDENTITY" != "-" ]] || fail "live S8 requires an explicit signing identity"
app_details="$(/usr/bin/codesign -dvvv "$APP" 2>&1)"
[[ "$app_details" == *"Authority=Apple Development:"* ]] || \
    fail "live S8 package is not Apple Development signed"

printf '{"authorizedTotal":19,"priorS4Calls":4,"requestedS8Calls":15,"model":"openai-codex/gpt-5.6-sol:max","payload":"synthetic-only","retry":false,"transport":"sse"}\n' \
    >"$EVIDENCE_DIR/consent.json"
/bin/chmod 0600 "$EVIDENCE_DIR/consent.json"

live="$TEMP_ROOT/live.json"
run_app "$live" "$TEMP_ROOT/live.stderr" --workflow-probe live
validated_roles="$(validate_live_report "$live")"
[[ "$validated_roles" == "15" ]] || fail "live role validation count differs from fifteen"
[[ "$(workspace_inventory)" == "$workspace_baseline" ]] || \
    fail "workflow workspace survived live run"
[[ -f "$SHARED_LEDGER" && ! -L "$SHARED_LEDGER" ]] || fail "shared ledger disappeared"
/usr/bin/install -m 0600 "$live" "$EVIDENCE_DIR/s8-workflows.json"
/usr/bin/install -m 0600 "$SHARED_LEDGER" "$EVIDENCE_DIR/provider-call-ledger.json"
printf '{"callsConsumed":19,"cleanupVerified":true,"providerCalls":15,"roles":15,"runPassed":true}\n' \
    >"$EVIDENCE_DIR/summary.json"
/bin/chmod 0600 "$EVIDENCE_DIR/summary.json"
printf 'S8 workflow fidelity: PASS\n'
printf 'roles=15 s8Calls=15 totalCalls=19 cleanup=verified evidence=%s\n' "$EVIDENCE_DIR"
