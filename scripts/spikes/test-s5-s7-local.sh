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
readonly SOURCE_RUNNER="$ROOT/scripts/spikes/jidoka-local-spikes.mjs"
readonly PACKAGED_RUNNER="$APP/Contents/Resources/Spikes/jidoka-local-spikes.mjs"
JIDOKA_RELEASE_RUNTIME_ROOT="${JIDOKA_RELEASE_RUNTIME_ROOT:-$ROOT/build/runtime-input/qualified-runtime}"
readonly JIDOKA_RELEASE_RUNTIME_ROOT
export JIDOKA_RELEASE_RUNTIME_ROOT
NODE_BIN="$("$ROOT/scripts/qualified-runtime-node.sh")"
readonly NODE_BIN
readonly EXPECTED_RUNNER_SHA256="c903de7f2a78d9172941774baa24cb016b1758834d9a1d9d828794b5cdf3b853"
readonly EXPECTED_RELEASE_MANIFEST_SHA256="fe15573a58a4604a3695b092ba8b07ae2432da7b7f07743a8d54a4421ab3aa83"
readonly EXPECTED_PI_MINIMUM_VERSION="0.84.2"
readonly EXPECTED_PI_MAXIMUM_VERSION_EXCLUSIVE="0.84.3"
readonly EXPECTED_PI_CLI_SHA256="840d1e8e689ed9e4937bcb00b9a810e02a8567d9afb10a47097f11ca93ea1521"
readonly EXPECTED_PI_SDK_SHA256="225053853f1a0bee80419001e24cb6676b43cb5cc8f111d60770641bff4370be"
readonly EXPECTED_CODEX_RUNTIME_SHA256="cf537f03ee3da7a7edbe28e447642a50d34e6a32a4f8aef599b5a496394e3999"
readonly EXPECTED_PI_PACKAGE_SHA256="820f4adc6d61f2cefbc29ce17e9dfd9aa482248d54be5d0dfa2a868ca000c7b0"
readonly EXPECTED_PI_PACKAGE_TREE_SHA256="534e4aa6ca73afbf31c48fc0c666978e3ab0114e7c1952f08ddae5139a9e9e37"
EXPECTED_PI_VERSION="$("$NODE_BIN" -p \
    'require(process.env.JIDOKA_RELEASE_RUNTIME_ROOT + "/pi/package.json").version')"
readonly EXPECTED_PI_VERSION
readonly SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MODE="live"
TEMP_ROOT=""
EVIDENCE_DIR=""

fail() {
    printf 'S5-S7 local spikes failed: %s\n' "$1" >&2
    exit 1
}

if [[ $# -gt 1 ]]; then
    fail "usage: test-s5-s7-local.sh [--preflight-only]"
fi
if [[ $# -eq 1 ]]; then
    [[ "$1" == "--preflight-only" ]] || fail "unknown option"
    MODE="preflight"
fi
readonly MODE

json_value() {
    /usr/bin/plutil -extract "$2" raw "$1"
}

validate_release_runtime_report() {
    # The JavaScript template literals are intentionally protected from Bash expansion.
    # shellcheck disable=SC2016
    "$NODE_BIN" -e '
      const fs = require("node:fs");
      const report = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const root = process.argv[2];
      const expected = {
        [`${root}/runtime-manifest.json`]: process.argv[3],
        [`${root}/pi/dist/cli.js`]: process.argv[4],
        [`${root}/pi/dist/core/sdk.js`]: process.argv[5],
        [`${root}/pi/node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js`]:
          process.argv[6],
        [`${root}/pi/package.json`]: process.argv[7],
        [`${root}/pi/#package-tree-v1`]: process.argv[8],
      };
      const observed = report.systemRuntimeSHA256;
      if (
        observed === null || typeof observed !== "object" || Array.isArray(observed) ||
        JSON.stringify(Object.keys(observed).sort()) !==
          JSON.stringify(Object.keys(expected).sort()) ||
        Object.entries(expected).some(([path, digest]) => observed[path] !== digest)
      ) process.exit(2);
    ' \
        "$1" "$APP/Contents/Resources/PiRuntime" \
        "$EXPECTED_RELEASE_MANIFEST_SHA256" "$EXPECTED_PI_CLI_SHA256" \
        "$EXPECTED_PI_SDK_SHA256" "$EXPECTED_CODEX_RUNTIME_SHA256" \
        "$EXPECTED_PI_PACKAGE_SHA256" "$EXPECTED_PI_PACKAGE_TREE_SHA256"
}

workspace_inventory() {
    /usr/bin/find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'jidoka-code-local-workspace-*' -print | \
        LC_ALL=C /usr/bin/sort
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        case "$(/usr/bin/basename "$TEMP_ROOT")" in
            jidoka-code-s5-s7.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
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
            DEVELOPER_DIR="$DEVELOPER_DIR" \
            HOME="${PROBE_HOME:-$HOME}" \
            PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin" \
            TMPDIR="${TMPDIR:-/tmp}" \
            "$APP_EXECUTABLE" "$@"
    ) >"$output" 2>"$stderr"; then
        [[ ! -f "$output" ]] || /usr/bin/install -m 0600 "$output" "$EVIDENCE_DIR/failed-$(/usr/bin/basename "$output")"
        [[ ! -f "$stderr" ]] || /usr/bin/install -m 0600 "$stderr" "$EVIDENCE_DIR/failed-$(/usr/bin/basename "$stderr")"
        /bin/cat "$stderr" >&2
        fail "packaged app command failed: $*"
    fi
    [[ ! -s "$stderr" ]] || fail "successful packaged app command wrote stderr: $*"
    /usr/bin/plutil -convert xml1 -o /dev/null "$output"
}

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-s5-s7.XXXXXX")"
readonly TEMP_ROOT
readonly PREFLIGHT_HOME="$TEMP_ROOT/preflight-home"
/bin/mkdir -m 0700 "$PREFLIGHT_HOME"
EVIDENCE_DIR="$ROOT/build/evidence/$(/usr/bin/basename "$TEMP_ROOT")"
readonly EVIDENCE_DIR
trap cleanup EXIT

if [[ "$MODE" == "preflight" ]]; then
    ALLOW_ADHOC_SIGNING=1 "$ROOT/scripts/package-app.sh"
else
    "$ROOT/scripts/package-app.sh"
fi
/usr/bin/codesign --verify --strict --deep "$APP"
[[ -f "$PACKAGED_RUNNER" && ! -L "$PACKAGED_RUNNER" ]] || fail "packaged runner is absent"
"$NODE_BIN" --check "$SOURCE_RUNNER"
source_sha="$(/usr/bin/shasum -a 256 "$SOURCE_RUNNER" | /usr/bin/awk '{print $1}')"
packaged_sha="$(/usr/bin/shasum -a 256 "$PACKAGED_RUNNER" | /usr/bin/awk '{print $1}')"
[[ "$source_sha" == "$EXPECTED_RUNNER_SHA256" ]] || fail "source runner digest drift"
[[ "$packaged_sha" == "$EXPECTED_RUNNER_SHA256" ]] || fail "packaged runner digest drift"

/bin/mkdir -p "$EVIDENCE_DIR"
/bin/chmod 0700 "$EVIDENCE_DIR"
workspace_baseline="$(workspace_inventory)"
readonly workspace_baseline

closed_stdout="$TEMP_ROOT/closed.stdout"
closed_stderr="$TEMP_ROOT/closed.stderr"
if (
    cd /
    /usr/bin/env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
        "$APP_EXECUTABLE" --local-spike security extra
) >"$closed_stdout" 2>"$closed_stderr"; then
    fail "packaged app accepted an open local-spike command"
fi
[[ ! -s "$closed_stdout" ]] || fail "rejected local-spike command wrote stdout"
/usr/bin/grep -Fq 'invalidArguments' "$closed_stderr" || fail "local-spike rejection was ambiguous"

pi_preflight="$TEMP_ROOT/pi-preflight.json"
PROBE_HOME="$PREFLIGHT_HOME" run_app \
    "$pi_preflight" "$TEMP_ROOT/pi-preflight.stderr" --pi-probe preflight
[[ "$(json_value "$pi_preflight" bashBlocked)" == "true" ]]
[[ "$(json_value "$pi_preflight" providerCalls)" == "0" ]]
[[ "$(json_value "$pi_preflight" childCleanup)" == "true" ]]
[[ "$(json_value "$pi_preflight" credentialAccess)" == "false" ]]
[[ "$(json_value "$pi_preflight" piVersion)" == "$EXPECTED_PI_VERSION" ]]
[[ "$(json_value "$pi_preflight" piCompatibility.minimumVersion)" == \
    "$EXPECTED_PI_MINIMUM_VERSION" ]]
[[ "$(json_value "$pi_preflight" piCompatibility.maximumVersionExclusive)" == \
    "$EXPECTED_PI_MAXIMUM_VERSION_EXCLUSIVE" ]]
[[ "$(json_value "$pi_preflight" piCompatibility.policySHA256)" == \
    "$EXPECTED_RELEASE_MANIFEST_SHA256" ]]
validate_release_runtime_report "$pi_preflight"
[[ ! -e "$PREFLIGHT_HOME/.pi" && ! -L "$PREFLIGHT_HOME/.pi" ]] || \
    fail "credential-free Pi preflight touched isolated HOME"
/usr/bin/install -m 0600 "$pi_preflight" "$EVIDENCE_DIR/pi-preflight.json"

security="$TEMP_ROOT/security.json"
run_app "$security" "$TEMP_ROOT/security.stderr" --local-spike security
[[ "$(json_value "$security" mode)" == "security-composition" ]]
[[ "$(json_value "$security" credentialHelperDetected)" == "true" ]]
[[ "$(json_value "$security" credentialHelperInvocations)" == "0" ]]
[[ "$(json_value "$security" directRemoteExecutionAllowed)" == "false" ]]
[[ "$(json_value "$security" hookBlockedCommit)" == "true" ]]
[[ "$(json_value "$security" hookBypassArgumentPresent)" == "false" ]]
[[ "$(json_value "$security" hookTracked)" == "true" ]]
[[ "$(json_value "$security" insteadOfDetected)" == "true" ]]
[[ "$(json_value "$security" localSubmoduleClassified)" == "true" ]]
[[ "$(json_value "$security" networkSubmoduleEscalated)" == "true" ]]
[[ "$(json_value "$security" remoteReceiveCount)" == "0" ]]
[[ "$(json_value "$security" sshInvocations)" == "0" ]]
[[ "$(json_value "$security" syntheticCredentialAbsent)" == "true" ]]
/usr/bin/install -m 0600 "$security" "$EVIDENCE_DIR/s5-security.json"

git_transport="$TEMP_ROOT/git-transport.json"
run_app "$git_transport" "$TEMP_ROOT/git-transport.stderr" --local-spike git-transport
zero_sha="0000000000000000000000000000000000000000"
[[ "$(json_value "$git_transport" mode)" == "git-transport" ]]
[[ "$(json_value "$git_transport" askpassInvocations)" == "5" ]]
[[ "$(json_value "$git_transport" askpassOneShot)" == "true" ]]
[[ "$(json_value "$git_transport" createExpectedOld)" == "$zero_sha" ]]
[[ "$(json_value "$git_transport" createPacketExpectedOldObserved)" == "true" ]]
[[ "$(json_value "$git_transport" createReadBackSHA)" == \
    "$(json_value "$git_transport" exactSHA)" ]]
[[ "$(json_value "$git_transport" divergentSHAOutcome)" == "escalation" ]]
[[ "$(json_value "$git_transport" forceClassArguments)" == "false" ]]
[[ "$(json_value "$git_transport" raceActorInjectionPoint)" == \
    "after-advertisement-before-receive" ]]
[[ "$(json_value "$git_transport" raceExpectedOld)" == "$zero_sha" ]]
[[ "$(json_value "$git_transport" racePacketExpectedOldObserved)" == "true" ]]
[[ "$(json_value "$git_transport" raceReadBackSHA)" == \
    "$(json_value "$git_transport" baseSHA)" ]]
[[ "$(json_value "$git_transport" raceRejected)" == "true" ]]
[[ "$(json_value "$git_transport" receiveRequests)" == "2" ]]
[[ "$(json_value "$git_transport" sameSHAOutcome)" == "attributable effect" ]]
[[ "$(json_value "$git_transport" syntheticTokenAbsentFromArtifactsAndArgv)" == "true" ]]
/usr/bin/install -m 0600 "$git_transport" "$EVIDENCE_DIR/s6-git-transport.json"

mutation="$TEMP_ROOT/mutation.json"
run_app "$mutation" "$TEMP_ROOT/mutation.stderr" --local-spike mutation-recovery
[[ "$(json_value "$mutation" mode)" == "mutation-recovery" ]]
[[ "$(json_value "$mutation" cases)" == "120" ]]
[[ "$(json_value "$mutation" crashWindows)" == "6" ]]
[[ "$(json_value "$mutation" delayedVisibilitySeconds)" == "31" ]]
[[ "$(json_value "$mutation" dispositionSuppressesRediscovery)" == "true" ]]
[[ "$(json_value "$mutation" operations)" == "10" ]]
[[ "$(json_value "$mutation" secondCreateAttempts)" == "0" ]]
[[ "$(json_value "$mutation" succeededWithoutAttribution)" == "0" ]]
[[ "$(json_value "$mutation" unknownCommentAbsent)" == "escalation" ]]
[[ "$(json_value "$mutation" unknownPRAbsent)" == "escalation" ]]
/usr/bin/install -m 0600 "$mutation" "$EVIDENCE_DIR/s7-mutation-recovery.json"

instead_count="$({ /Applications/Xcode.app/Contents/Developer/usr/bin/git config --global \
    --get-regexp '^url\..*\.insteadof$' 2>/dev/null || true; } | \
    /usr/bin/wc -l | /usr/bin/tr -d ' ')"
ssh_agent_present=false
[[ -z "${SSH_AUTH_SOCK:-}" ]] || ssh_agent_present=true
printf '{"globalInsteadOfEntryCount":%s,"sshAgentPresent":%s,"valuesRedacted":true}\n' \
    "$instead_count" "$ssh_agent_present" >"$EVIDENCE_DIR/host-context-redacted.json"
/bin/chmod 0600 "$EVIDENCE_DIR/host-context-redacted.json"

[[ "$(workspace_inventory)" == "$workspace_baseline" ]] || fail "app-owned local workspace survived"
if [[ "$MODE" == "live" ]]; then
    [[ "$SIGN_IDENTITY" != "-" ]] || fail "live S5-S7 requires an explicit signing identity"
    app_details="$(/usr/bin/codesign -dvvv "$APP" 2>&1)"
    [[ "$app_details" == *"Authority=Apple Development:"* ]] || \
        fail "live S5-S7 package is not Apple Development signed"
fi
printf '{"cleanupVerified":true,"providerCalls":0,"runPassed":true,"spikes":["S5","S6","S7"]}\n' \
    >"$EVIDENCE_DIR/summary.json"
/bin/chmod 0600 "$EVIDENCE_DIR/summary.json"
printf 'S5-S7 local spikes: PASS\n'
printf 'providerCalls=0 receiveRequests=2 mutationCases=120 cleanup=verified evidence=%s\n' \
    "$EVIDENCE_DIR"
