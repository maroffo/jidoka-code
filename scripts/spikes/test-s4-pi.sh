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
readonly RESOURCE_ROOT="$APP/Contents/Resources/Pi"
readonly SOURCE_RUNNER="$ROOT/scripts/spikes/pi-rpc-profile-probe.mjs"
readonly PACKAGED_RUNNER="$RESOURCE_ROOT/runtime/pi-rpc-profile-probe.mjs"
readonly NODE_BIN="/opt/homebrew/Cellar/node/26.6.0/bin/node"
readonly PI_CLI="/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
readonly PI_SDK="/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/sdk.js"
readonly CODEX_RUNTIME="/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js"
readonly MODEL="openai-codex/gpt-5.6-sol:max"
readonly SIGN_IDENTITY="${SIGN_IDENTITY:--}"
readonly SHARED_LEDGER="$HOME/Library/Application Support/JidokaCode/Consent/provider-call-ledger.json"
readonly EXPECTED_RUNNER_SHA256="83d081f9337bc1531e8c516e4248c324de26e325a4f8ef3895eb3df3417d45e9"
readonly EXPECTED_SETTINGS_SHA256="e7ec0ba10fa91967345d69c328a9fefbc65a7a89a7aa98a522cd1a9697e96da4"
readonly EXPECTED_PI_VERSION="0.84.1"
readonly EXPECTED_PI_POLICY_SHA256="324d6a1738c08fd7dfbc1ca8fb324ed64d8fc3ac5bd1e2c293062cf4d4238248"
readonly EXPECTED_PI_SDK_SHA256="f6e72f33f44c708249c8d74931d816c36fe27175f7fa1639cba0a3d988592821"
readonly EXPECTED_CODEX_RUNTIME_SHA256="f0699749b06045244fd6ced26aee4f2627e7218199fd2955b0003fe08592aead"
MODE="live"
TEMP_ROOT=""
EVIDENCE_DIR=""

fail() {
    printf 'S4 Pi failed: %s\n' "$1" >&2
    exit 1
}

if [[ $# -gt 1 ]]; then
    fail "usage: test-s4-pi.sh [--preflight-only]"
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
    /usr/bin/find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'jidoka-code-pi-workspace-*' -print | \
        LC_ALL=C /usr/bin/sort
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        case "$(/usr/bin/basename "$TEMP_ROOT")" in
            jidoka-code-s4.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
        esac
    fi
    exit "$status"
}

run_probe() {
    local output="$1"
    local stderr="$2"
    shift 2
    if ! (
        cd /
        /usr/bin/env -i \
            HOME="${PROBE_HOME:-$HOME}" \
            PATH="/opt/homebrew/bin:/usr/bin:/bin" \
            TMPDIR="${TMPDIR:-/tmp}" \
            "$APP_EXECUTABLE" --pi-probe "$@"
    ) >"$output" 2>"$stderr"; then
        [[ ! -f "$output" ]] || /usr/bin/install -m 0600 "$output" "$EVIDENCE_DIR/failed-$(/usr/bin/basename "$output")"
        [[ ! -f "$stderr" ]] || /usr/bin/install -m 0600 "$stderr" "$EVIDENCE_DIR/failed-$(/usr/bin/basename "$stderr")"
        /bin/cat "$stderr" >&2
        fail "packaged app probe failed: $1"
    fi
    [[ ! -s "$stderr" ]] || {
        /bin/cat "$stderr" >&2
        fail "packaged app probe wrote stderr: $1"
    }
    /usr/bin/plutil -convert xml1 -o /dev/null "$output"
}

assert_closed_app_command() {
    local stdout_path="$TEMP_ROOT/closed-command.stdout"
    local stderr_path="$TEMP_ROOT/closed-command.stderr"
    if (
        cd /
        /usr/bin/env -i \
            HOME="$HOME" \
            PATH="/opt/homebrew/bin:/usr/bin:/bin" \
            TMPDIR="${TMPDIR:-/tmp}" \
            "$APP_EXECUTABLE" --pi-probe profile review extra
    ) >"$stdout_path" 2>"$stderr_path"; then
        fail "packaged app accepted an open Pi command"
    fi
    [[ ! -s "$stdout_path" ]] || fail "rejected Pi command wrote stdout"
    /usr/bin/grep -Fq 'invalidArguments' "$stderr_path" || \
        fail "packaged app rejected Pi command ambiguously"
}

validate_live_ledger() {
    "$NODE_BIN" -e '
      const fs = require("node:fs");
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (
        value.schemaVersion !== 1 ||
        value.authorizedCallCap !== 19 ||
        value.model !== "openai-codex/gpt-5.6-sol:max" ||
        value.retry !== false ||
        !Array.isArray(value.attempts) ||
        value.attempts.length !== 4 ||
        new Set(value.attempts.map((attempt) => attempt.attemptId)).size !== 4 ||
        new Set(value.attempts.map((attempt) => attempt.fixtureId)).size !== 4 ||
        value.attempts.some((attempt) =>
          attempt.state !== "settled" ||
          attempt.workflow !== "S4" ||
          attempt.providerRequestCount !== 1 ||
          attempt.provider !== "openai-codex" ||
          attempt.responseModel !== "gpt-5.6-sol" ||
          attempt.stopReason !== "stop")
      ) process.exit(2);
      process.stdout.write(String(value.attempts.length));
    ' "$1"
}

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-s4.XXXXXX")"
readonly TEMP_ROOT
readonly PREFLIGHT_HOME="$TEMP_ROOT/preflight-home"
/bin/mkdir -m 0700 "$PREFLIGHT_HOME"
EVIDENCE_DIR="$ROOT/build/evidence/$(/usr/bin/basename "$TEMP_ROOT")"
readonly EVIDENCE_DIR
trap cleanup EXIT

"$ROOT/scripts/package-app.sh"
/usr/bin/codesign --verify --strict --deep "$APP"
[[ -x "$NODE_BIN" && -f "$PI_CLI" && ! -L "$NODE_BIN" && ! -L "$PI_CLI" ]] || \
    fail "exact Node/Pi runtime is unavailable"
for runtime_file in "$PI_SDK" "$CODEX_RUNTIME"; do
    [[ -f "$runtime_file" && ! -L "$runtime_file" ]] || fail "reviewed Pi runtime file is unavailable"
done
[[ "$(/usr/bin/shasum -a 256 "$PI_SDK" | /usr/bin/awk '{print $1}')" == \
    "$EXPECTED_PI_SDK_SHA256" ]] || fail "Pi SDK implementation drift"
[[ "$(/usr/bin/shasum -a 256 "$CODEX_RUNTIME" | /usr/bin/awk '{print $1}')" == \
    "$EXPECTED_CODEX_RUNTIME_SHA256" ]] || fail "Codex transport implementation drift"
[[ "$($NODE_BIN --version)" == "v26.6.0" ]] || fail "Node version drift"
[[ "$($NODE_BIN "$PI_CLI" --version)" == "$EXPECTED_PI_VERSION" ]] || fail "Pi version drift"
"$NODE_BIN" --check "$SOURCE_RUNNER"
"$NODE_BIN" --check "$ROOT/scripts/spikes/pi-provider-gate-probe.mjs"
"$NODE_BIN" --check "$ROOT/Resources/Pi/extensions/jidoka-runtime.ts"
[[ -f "$PACKAGED_RUNNER" && ! -L "$PACKAGED_RUNNER" ]] || fail "packaged runner is absent"
source_runner_sha="$(/usr/bin/shasum -a 256 "$SOURCE_RUNNER" | /usr/bin/awk '{print $1}')"
packaged_runner_sha="$(/usr/bin/shasum -a 256 "$PACKAGED_RUNNER" | /usr/bin/awk '{print $1}')"
[[ "$source_runner_sha" == "$EXPECTED_RUNNER_SHA256" ]] || fail "source runner digest drift"
[[ "$packaged_runner_sha" == "$EXPECTED_RUNNER_SHA256" ]] || fail "packaged runner digest drift"

/bin/mkdir -p "$EVIDENCE_DIR"
/bin/chmod 0700 "$EVIDENCE_DIR"
workspace_baseline="$(workspace_inventory)"
readonly workspace_baseline
assert_closed_app_command
[[ "$(workspace_inventory)" == "$workspace_baseline" ]] || \
    fail "rejected app command created a Pi workspace"

gate_preflight="$TEMP_ROOT/provider-gate-preflight.json"
"$NODE_BIN" "$ROOT/scripts/spikes/pi-provider-gate-probe.mjs" \
    "$ROOT/Resources/Pi/extensions/jidoka-runtime.ts" >"$gate_preflight"
[[ "$(json_value "$gate_preflight" firstRequestIssued)" == "true" ]]
[[ "$(json_value "$gate_preflight" lockCleanup)" == "true" ]]
[[ "$(json_value "$gate_preflight" networkProviderCalls)" == "0" ]]
[[ "$(json_value "$gate_preflight" secondRequestBlocked)" == "true" ]]
[[ "$(json_value "$gate_preflight" simulatedProviderRequestsReached)" == "1" ]]
[[ "$(json_value "$gate_preflight" terminationStatus)" == "86" ]]
/usr/bin/install -m 0600 "$gate_preflight" "$EVIDENCE_DIR/provider-gate-preflight.json"

preflight="$TEMP_ROOT/preflight.json"
PROBE_HOME="$PREFLIGHT_HOME" run_probe "$preflight" "$TEMP_ROOT/preflight.stderr" preflight
[[ "$(json_value "$preflight" mode)" == "preflight" ]]
[[ "$(json_value "$preflight" credentialAccess)" == "false" ]]
[[ "$(json_value "$preflight" abortAcknowledged)" == "true" ]]
[[ "$(json_value "$preflight" bashBlocked)" == "true" ]]
[[ "$(json_value "$preflight" childCleanup)" == "true" ]]
[[ "$(json_value "$preflight" packagedCommandCount)" == "5" ]]
[[ "$(json_value "$preflight" inlineCommandCount)" == "1" ]]
[[ "$(json_value "$preflight" observedCommandCount)" == "6" ]]
[[ "$(json_value "$preflight" providerCalls)" == "0" ]]
[[ "$(json_value "$preflight" isolatedSettingsSHA256)" == "$EXPECTED_SETTINGS_SHA256" ]]
[[ "$(json_value "$preflight" piVersion)" == "$EXPECTED_PI_VERSION" ]]
[[ "$(json_value "$preflight" piCompatibility.minimumVersion)" == "0.84.0" ]]
[[ "$(json_value "$preflight" piCompatibility.maximumVersionExclusive)" == "0.90.0" ]]
[[ "$(json_value "$preflight" piCompatibility.policySHA256)" == \
    "$EXPECTED_PI_POLICY_SHA256" ]]
[[ "$(json_value "$preflight" providerTransport)" == "sse" ]]
/usr/bin/install -m 0600 "$preflight" "$EVIDENCE_DIR/preflight.json"

timeout_output="$TEMP_ROOT/timeout.json"
PROBE_HOME="$PREFLIGHT_HOME" run_probe "$timeout_output" "$TEMP_ROOT/timeout.stderr" timeout
[[ "$(json_value "$timeout_output" mode)" == "timeout" ]]
[[ "$(json_value "$timeout_output" credentialAccess)" == "false" ]]
[[ "$(json_value "$timeout_output" abortAcknowledged)" == "true" ]]
[[ "$(json_value "$timeout_output" activeCommandCancelled)" == "true" ]]
[[ "$(json_value "$timeout_output" childCleanup)" == "true" ]]
[[ "$(json_value "$timeout_output" providerCalls)" == "0" ]]
[[ "$(json_value "$timeout_output" isolatedSettingsSHA256)" == "$EXPECTED_SETTINGS_SHA256" ]]
[[ "$(json_value "$timeout_output" providerTransport)" == "sse" ]]
/usr/bin/install -m 0600 "$timeout_output" "$EVIDENCE_DIR/timeout.json"

ledger_preflight="$TEMP_ROOT/ledger-preflight.json"
PROBE_HOME="$PREFLIGHT_HOME" run_probe \
    "$ledger_preflight" "$TEMP_ROOT/ledger-preflight.stderr" ledger-preflight
[[ "$(json_value "$ledger_preflight" mode)" == "ledger-preflight" ]]
[[ "$(json_value "$ledger_preflight" attemptsAtCap)" == "19" ]]
[[ "$(json_value "$ledger_preflight" attemptReplayBlocked)" == "true" ]]
[[ "$(json_value "$ledger_preflight" capBlocked)" == "true" ]]
[[ "$(json_value "$ledger_preflight" fixtureReplayBlocked)" == "true" ]]
[[ "$(json_value "$ledger_preflight" lockBlocked)" == "true" ]]
[[ "$(json_value "$ledger_preflight" providerCalls)" == "0" ]]
[[ ! -e "$PREFLIGHT_HOME/.pi" && ! -L "$PREFLIGHT_HOME/.pi" ]] || \
    fail "credential-free preflight touched isolated HOME"
/usr/bin/install -m 0600 "$ledger_preflight" "$EVIDENCE_DIR/ledger-preflight.json"

printf '{"authorizedCallCap":19,"codexRuntimeSHA256":"%s","launcher":"packaged-app-closed-command","model":"%s","payload":"synthetic-only","piSDKRuntimeSHA256":"%s","providerRetry":false,"runnerSHA256":"%s","transport":"sse","workflowRetry":false}\n' \
    "$EXPECTED_CODEX_RUNTIME_SHA256" "$MODEL" "$EXPECTED_PI_SDK_SHA256" \
    "$EXPECTED_RUNNER_SHA256" >"$EVIDENCE_DIR/consent.json"
/bin/chmod 0600 "$EVIDENCE_DIR/consent.json"

if [[ "$MODE" == "preflight" ]]; then
    [[ "$(workspace_inventory)" == "$workspace_baseline" ]] || \
        fail "app-owned Pi workspace survived preflight"
    printf 'S4 Pi preflight: PASS\n'
    printf 'provenance=exact timeout=aborted ledger=bounded providerCalls=0 evidence=%s\n' \
        "$EVIDENCE_DIR"
    exit 0
fi

[[ "$SIGN_IDENTITY" != "-" ]] || fail "live S4 requires an explicit signing identity"
[[ "$SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || fail "live S4 signing identity is malformed"
app_details="$(/usr/bin/codesign -dvvv "$APP" 2>&1)"
[[ "$app_details" == *"Authority=Apple Development:"* ]] || \
    fail "live S4 package is not Apple Development signed"
app_team="$(printf '%s\n' "$app_details" | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
[[ -n "$app_team" && "$app_team" != "not set" ]] || fail "live S4 package has no team"
if [[ -e "$SHARED_LEDGER" || -L "$SHARED_LEDGER" ]]; then
    [[ -f "$SHARED_LEDGER" && ! -L "$SHARED_LEDGER" ]] || fail "shared ledger is unsafe"
fi

profiles=(review triage planning orchestration)
profile_index=0
for profile in "${profiles[@]}"; do
    ((profile_index += 1))
    output="$TEMP_ROOT/$profile.json"
    run_probe "$output" "$TEMP_ROOT/$profile.stderr" profile "$profile"
    [[ "$(json_value "$output" mode)" == "profile" ]]
    [[ "$(json_value "$output" authenticationProviders.0)" == "openai-codex" ]]
    [[ "$(json_value "$output" profile)" == "$profile" ]]
    [[ "$(json_value "$output" agentSettled)" == "true" ]]
    [[ "$(json_value "$output" bashBlocked)" == "true" ]]
    [[ "$(json_value "$output" childCleanup)" == "true" ]]
    [[ "$(json_value "$output" providerCalls)" == "1" ]]
    [[ "$(json_value "$output" callsConsumed)" == "$profile_index" ]]
    [[ "$(json_value "$output" isolatedSettingsSHA256)" == "$EXPECTED_SETTINGS_SHA256" ]]
    [[ "$(json_value "$output" providerTransport)" == "sse" ]]
    [[ "$(json_value "$output" packagedCommandCount)" == "2" ]]
    [[ "$(json_value "$output" inlineCommandCount)" == "1" ]]
    [[ "$(json_value "$output" observedCommandCount)" == "3" ]]
    case "$profile" in
        review|orchestration) expected_verdict=block ;;
        triage|planning) expected_verdict=escalate ;;
        *) fail "unexpected profile" ;;
    esac
    [[ "$(json_value "$output" result.verdict)" == "$expected_verdict" ]]
    /usr/bin/install -m 0600 "$output" "$EVIDENCE_DIR/$profile.json"
done

[[ -f "$SHARED_LEDGER" && ! -L "$SHARED_LEDGER" ]] || fail "shared ledger is absent"
calls_consumed="$(validate_live_ledger "$SHARED_LEDGER")"
[[ "$calls_consumed" == "4" ]] || fail "shared ledger call count differs from four"
[[ "$(workspace_inventory)" == "$workspace_baseline" ]] || \
    fail "app-owned Pi workspace survived live profiles"
/usr/bin/install -m 0600 "$SHARED_LEDGER" "$EVIDENCE_DIR/provider-call-ledger.json"
printf '{"agentSettled":true,"callsConsumed":%s,"cleanupVerified":true,"profiles":4,"runPassed":true}\n' \
    "$calls_consumed" >"$EVIDENCE_DIR/summary.json"
/bin/chmod 0600 "$EVIDENCE_DIR/summary.json"
printf 'S4 Pi live: PASS\n'
printf 'profiles=4 calls=%s retry=disabled compaction=disabled cleanup=verified evidence=%s\n' \
    "$calls_consumed" "$EVIDENCE_DIR"
