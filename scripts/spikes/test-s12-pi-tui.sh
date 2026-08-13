#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly NODE="/opt/homebrew/Cellar/node/26.6.0/bin/node"
readonly PI_CLI="/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
readonly FIXTURE="$SCRIPT_DIR/herdr-s12-fixture.mjs"
readonly PROVIDER_FIXTURE="$SCRIPT_DIR/pi-tui-fixture-provider.ts"
readonly MANIFEST="$ROOT/Resources/Pi/workflow-resources.json"
readonly TUI_MANIFEST="$ROOT/Resources/Pi/tui-resources.json"
readonly EXPECTED_MANIFEST_SHA256="4d7be2b7ed582f2195bf19953dc74420be12c9066c2a9565b64f09afc204d566"
readonly EXPECTED_TUI_MANIFEST_SHA256="5392fec5eb544dbe0c721692440e8445604d3c05509a39b450f2bb964245f07f"
readonly RUN_ID="run-s12-triage"
readonly RUN_NONCE="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
readonly FRESH_LAUNCH_ATTEMPT_ID="attempt-s12-triage-0001"
readonly RESUME_LAUNCH_ATTEMPT_ID="attempt-s12-triage-0002"
readonly FAILURE_LAUNCH_ATTEMPT_ID="attempt-s12-failure-0001"
readonly FAILURE_RUN_ID="run-s12-failure"
readonly FAILURE_RUN_NONCE="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
readonly WORKFLOW_NONCE="workflow-nonce"
readonly ARTIFACT_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
readonly SESSION_TITLE="jidoka-run-s12-triage"
readonly MANUAL_SENTINEL="JIDOKA_MANUAL_INPUT_MUST_NOT_ENTER_CONTEXT"

fail() {
    printf 'S12 exact Pi TUI failed: %s\n' "$1" >&2
    exit 1
}

json_value() {
    local file="$1"
    local expression="$2"
    "$NODE" -e '
      const fs = require("node:fs");
      let value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      for (const part of process.argv[2].split(".")) value = value?.[part];
      if (value === undefined || value === null) process.exit(2);
      process.stdout.write(String(value));
    ' "$file" "$expression"
}

"$ROOT/scripts/verify-toolchain.sh"
"$NODE" --check "$FIXTURE"
"$NODE" --check "$PROVIDER_FIXTURE"
"$NODE" "$ROOT/scripts/tests/test-pi-runtime-attestation.mjs"
command -v herdr >/dev/null 2>&1 || fail "Herdr is unavailable"
[[ "$(herdr --version | /usr/bin/awk '{print $2}')" == "0.8.0" ]] || \
    fail "Herdr 0.8.0 is required"
[[ "$(${NODE} -p 'require("/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/package.json").version')" == "0.84.1" ]] || \
    fail "Pi 0.84.1 is required"
[[ "$(/usr/bin/shasum -a 256 "$MANIFEST" | /usr/bin/awk '{print $1}')" == \
    "$EXPECTED_MANIFEST_SHA256" ]] || fail "workflow resource manifest drifted"
[[ "$(/usr/bin/shasum -a 256 "$TUI_MANIFEST" | /usr/bin/awk '{print $1}')" == \
    "$EXPECTED_TUI_MANIFEST_SHA256" ]] || fail "TUI resource manifest drifted"

cd "$ROOT"
/usr/bin/xcrun swift build --product JidokaCodeHerdrHost
/usr/bin/xcrun swift build --product JidokaCodeHerdrFixture
BIN_DIR="$(/usr/bin/xcrun swift build --show-bin-path)"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
readonly BIN_DIR
readonly HOST="$BIN_DIR/JidokaCodeHerdrHost"
readonly PREPARER="$BIN_DIR/JidokaCodeHerdrFixture"
[[ -f "$HOST" && -x "$HOST" && ! -L "$HOST" ]] || fail "missing host product"
[[ -f "$PREPARER" && -x "$PREPARER" && ! -L "$PREPARER" ]] || fail "missing H3 preparer"
[[ -f "$NODE" && -x "$NODE" && ! -L "$NODE" ]] || fail "missing exact Node runtime"
[[ -f "$PI_CLI" && ! -L "$PI_CLI" ]] || fail "missing exact Pi CLI"

/bin/mkdir -p "$ROOT/build/evidence"
TMP="$(/usr/bin/mktemp -d "$ROOT/build/evidence/jidoka-herdr-s12.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
readonly TMP
readonly RUN_ROOT="$TMP/runs"
readonly WORK_ROOT="$TMP/work"
readonly HOME_ROOT="$TMP/home"
readonly AGENT_ROOT="$TMP/agent"
readonly SESSION_ROOT="$TMP/sessions"
readonly CHANNEL_ROOT="$TMP/channel"
readonly TEMP_ROOT="$TMP/tmp"
readonly WORKFLOW_CONFIGURATION="$CHANNEL_ROOT/workflow.json"
readonly TUI_CONFIGURATION="$CHANNEL_ROOT/tui-fresh.json"
readonly PROMPT_FILE="$CHANNEL_ROOT/prompt.txt"
readonly PROVIDER_CALL="$CHANNEL_ROOT/causal-provider-call.json"
readonly PROVIDER_OUTPUT_STARTED="$PROVIDER_CALL.output-started"
readonly CHILD_PROCESS_RECORD="$CHANNEL_ROOT/child-process-$FRESH_LAUNCH_ATTEMPT_ID.json"
readonly FAILURE_CHANNEL_ROOT="$TMP/failure-channel"
readonly FAILURE_SESSION_ROOT="$TMP/failure-sessions"
readonly FAILURE_WORKFLOW_CONFIGURATION="$FAILURE_CHANNEL_ROOT/workflow.json"
readonly FAILURE_TUI_CONFIGURATION="$FAILURE_CHANNEL_ROOT/tui.json"
readonly FAILURE_PROMPT_FILE="$FAILURE_CHANNEL_ROOT/prompt.txt"
readonly FAILURE_PROVIDER_CALL="$FAILURE_CHANNEL_ROOT/failure-provider-call.json"
readonly NETWORK_TRAP_LOG="$TMP/provider-network.jsonl"
readonly NETWORK_TRAP_READY="$TMP/provider-network.ready"
readonly MANUAL_BYPASS="$WORK_ROOT/manual-bypass.jsonl"
SESSION_SUFFIX="$(/usr/bin/basename "$TMP" | /usr/bin/awk -F. '{print tolower($NF)}')"
readonly SESSION_SUFFIX
readonly HERDR_SESSION_NAME="jidoka-s12-$SESSION_SUFFIX"
readonly HERDR_SESSION_DIR="$HOME/.config/herdr/sessions/$HERDR_SESSION_NAME"
readonly SOCKET="$HERDR_SESSION_DIR/herdr.sock"
readonly DEFAULT_SOCKET="$HOME/.config/herdr/herdr.sock"
server_pid=""
observer_pid=""
network_trap_pid=""
cleanup_verified=0

stop_observer() {
    if [[ -n "$observer_pid" ]]; then
        /bin/kill "$observer_pid" >/dev/null 2>&1 || true
        wait "$observer_pid" 2>/dev/null || true
        observer_pid=""
    fi
}

stop_local_processes() {
    stop_observer
    if [[ -n "$network_trap_pid" ]]; then
        /bin/kill "$network_trap_pid" >/dev/null 2>&1 || true
        wait "$network_trap_pid" 2>/dev/null || true
        network_trap_pid=""
    fi
    if [[ -n "$server_pid" ]]; then
        /bin/kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=""
    fi
}

session_is_absent() {
    [[ ! -e "$HERDR_SESSION_DIR" && ! -S "$SOCKET" ]] || return 1
    herdr session list --json | "$NODE" -e '
      const fs = require("node:fs");
      const value = JSON.parse(fs.readFileSync(0, "utf8"));
      process.exit(value.sessions?.some((session) => session.name === process.argv[1]) ? 1 : 0);
    ' "$HERDR_SESSION_NAME"
}

verify_cleanup() {
    stop_local_processes
    herdr session stop "$HERDR_SESSION_NAME" --json >"$TMP/session-stop.json" 2>"$TMP/session-stop.err" || true
    herdr session delete "$HERDR_SESSION_NAME" --json >"$TMP/session-delete.json" 2>"$TMP/session-delete.err" || true
    session_is_absent || return 1
    cleanup_verified=1
}

cleanup() {
    if [[ "$cleanup_verified" != "1" ]]; then
        stop_local_processes
        herdr session stop "$HERDR_SESSION_NAME" --json >/dev/null 2>&1 || true
        herdr session delete "$HERDR_SESSION_NAME" --json >/dev/null 2>&1 || true
    fi
    if [[ "${KEEP_S12_ARTIFACTS:-0}" == "1" ]]; then
        printf 'S12 artifacts retained at %s\n' "$TMP" >&2
    else
        /bin/rm -rf -- "$TMP"
    fi
}
trap cleanup EXIT

/bin/mkdir -m 0700 \
    "$RUN_ROOT" "$WORK_ROOT" "$HOME_ROOT" "$AGENT_ROOT" \
    "$SESSION_ROOT" "$CHANNEL_ROOT" "$TEMP_ROOT" \
    "$FAILURE_CHANNEL_ROOT" "$FAILURE_SESSION_ROOT"
printf '{}\n' >"$AGENT_ROOT/auth.json"
printf 'Perform the pinned synthetic issue triage and emit the one terminal structured result.\n' \
    >"$PROMPT_FILE"
printf 'Trigger the pinned typed runtime failure fixture.\n' >"$FAILURE_PROMPT_FILE"

"$NODE" - "$NETWORK_TRAP_LOG" "$NETWORK_TRAP_READY" <<'NODE' &
const fs = require("node:fs"), net = require("node:net");
const [log, ready] = process.argv.slice(2);
const server = net.createServer((socket) => {
  fs.appendFileSync(log, `${JSON.stringify({ acceptedAt: Date.now() })}\n`, { mode: 0o600 });
  socket.destroy();
});
server.on("error", (error) => {
  process.stderr.write(`${error.stack ?? error}\n`);
  process.exit(1);
});
server.listen({ host: "127.0.0.1", port: 43871, exclusive: true }, () => {
  fs.writeFileSync(ready, "ready\n", { flag: "wx", mode: 0o600 });
});
process.on("SIGTERM", () => server.close(() => process.exit(0)));
NODE
network_trap_pid=$!
for _ in $(/usr/bin/seq 1 100); do
    [[ -f "$NETWORK_TRAP_READY" ]] && break
    /bin/sleep 0.02
done
[[ -f "$NETWORK_TRAP_READY" ]] || fail "provider network trap did not start"

[[ "$SOCKET" != "$DEFAULT_SOCKET" ]] || fail "isolated socket resolved to default"
# The single-quoted program is evaluated by Expect and reads its own environment.
# shellcheck disable=SC2016
env \
    -u HERDR_ENV \
    -u HERDR_SOCKET_PATH \
    -u HERDR_WORKSPACE_ID \
    -u HERDR_TAB_ID \
    -u HERDR_PANE_ID \
    -u HERDR_BIN_PATH \
    SESSION_NAME="$HERDR_SESSION_NAME" \
    TERM=xterm-256color \
    /usr/bin/expect -c \
    'log_user 0; set timeout -1; set stty_init "rows 48 columns 140"; spawn -noecho herdr --session $env(SESSION_NAME); expect eof' \
    >"$TMP/server.out" 2>"$TMP/server.err" &
server_pid=$!
for _ in $(/usr/bin/seq 1 100); do
    [[ -S "$SOCKET" ]] && break
    /bin/sleep 0.05
done
[[ -S "$SOCKET" ]] || fail "named session socket did not start"
[[ "$(/usr/bin/stat -f '%Sp' "$SOCKET")" == "srw-------" ]] || fail "unsafe socket mode"
"$NODE" "$FIXTURE" ping "$SOCKET" >"$TMP/ping.json"
[[ "$(json_value "$TMP/ping.json" 'version')" == "0.8.0" ]] || fail "Herdr version mismatch"
[[ "$(json_value "$TMP/ping.json" 'protocol')" == "19" ]] || fail "Herdr protocol mismatch"

"$NODE" "$FIXTURE" snapshot "$SOCKET" >"$TMP/before.json"
"$NODE" "$FIXTURE" create-workspace \
    "$SOCKET" "jidoka-s12-$SESSION_SUFFIX" "$WORK_ROOT" >"$TMP/workspace.json"
workspace_id="$(json_value "$TMP/workspace.json" 'workspace.workspace_id')"
readonly workspace_id
[[ -n "$workspace_id" ]] || fail "workspace identity missing"

"$NODE" - \
    "$TMP/fresh-spec.json" "$FRESH_LAUNCH_ATTEMPT_ID" "$RUN_ID" "$RUN_NONCE" \
    "$WORKFLOW_NONCE" "$ARTIFACT_SHA256" "$RUN_ROOT" "$ROOT/Resources/Pi" \
    "$WORK_ROOT" "$HOME_ROOT" "$AGENT_ROOT" "$TEMP_ROOT" "$SESSION_ROOT" \
    "$CHANNEL_ROOT" "$WORKFLOW_CONFIGURATION" "$TUI_CONFIGURATION" "$PROMPT_FILE" \
    "$SESSION_TITLE" "$PROVIDER_FIXTURE" "$PROVIDER_CALL" "$workspace_id" <<'NODE'
const fs = require("node:fs");
const [destination, launchAttemptID, runID, runNonce, workflowNonce, artifactSHA256,
  runRoot, resourceRoot, workspaceRoot, homeDirectory, agentDirectory, temporaryDirectory,
  sessionDirectory, channelDirectory, workflowConfiguration, tuiConfiguration, promptPath,
  sessionName, fixtureProviderExtension, fixtureProviderCall, workspaceID] = process.argv.slice(2);
const specification = {
  agentAlias: "jc-s12-g1-triage", agentDirectory, artifactSHA256, channelDirectory,
  expectedSessionID: null, fixtureProviderCall, fixtureProviderExtension, homeDirectory,
  launchAttemptID, promptPath, resourceRoot, runID, runNonce, runRoot, sessionDirectory,
  sessionName, temporaryDirectory, title: "Exact Pi TUI issue triage", tuiConfiguration,
  workflowConfiguration, workflowNonce, workspaceID, workspaceRoot,
};
fs.writeFileSync(destination, `${JSON.stringify(specification)}\n`, { flag: "wx", mode: 0o600 });
NODE
"$PREPARER" --prepare-h3 "$TMP/fresh-spec.json" >"$TMP/descriptor.json"
"$NODE" - "$TMP/descriptor.json" "$ROOT" "$PROMPT_FILE" <<'NODE'
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const root = process.argv[3], prompt = process.argv[4], args = value.argumentValues;
const extensions = args.flatMap((value, index) => value === "--extension" ? [args[index + 1]] : []);
const expectedExtensions = [
  `${root}/Resources/Pi/extensions/jidoka-deny-user-bash.js`,
  `${root}/Resources/Pi/extensions/jidoka-code.ts`,
  `${root}/Resources/Pi/extensions/jidoka-tui-runtime.ts`,
  `${root}/scripts/spikes/pi-tui-fixture-provider.ts`,
];
if (value.schemaVersion !== 3 || value.launchAttemptID !== "attempt-s12-triage-0001"
    || value.runID !== "run-s12-triage" || args.includes("--mode") || args.includes(prompt)
    || JSON.stringify(extensions) !== JSON.stringify(expectedExtensions)
    || args.includes("--session")) process.exit(1);
NODE
"$NODE" - "$RUN_ROOT/$FRESH_LAUNCH_ATTEMPT_ID/launch.json" "$TEMP_ROOT" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const launch = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const temporaryRoot = fs.realpathSync(process.argv[3]);
const executable = fs.realpathSync(launch.childExecutable);
const snapshotRoot = path.dirname(executable);
const cli = fs.realpathSync(launch.childArguments[0]);
const libraryDirectory = fs.realpathSync(launch.childEnvironment.DYLD_LIBRARY_PATH ?? "");
const marker = JSON.parse(fs.readFileSync(path.join(snapshotRoot, "snapshot.json"), "utf8"));
const node = fs.lstatSync(executable), root = fs.lstatSync(snapshotRoot);
if (!snapshotRoot.startsWith(`${temporaryRoot}/runtime-snapshot-`)
    || executable !== path.join(snapshotRoot, "node")
    || cli !== path.join(snapshotRoot, "pi/dist/cli.js")
    || libraryDirectory !== path.join(snapshotRoot, "lib")
    || marker.piCLIRelativePath !== "dist/cli.js"
    || node.uid !== process.getuid() || node.nlink !== 1 || (node.mode & 0o022) !== 0
    || root.uid !== process.getuid() || (root.mode & 0o077) !== 0) process.exit(1);
NODE
"$NODE" "$FIXTURE" apply-layout \
    "$SOCKET" "$workspace_id" "j/s12/g1" "$HOST" "$RUN_ROOT" "$WORK_ROOT" \
    "$FRESH_LAUNCH_ATTEMPT_ID" \
    >"$TMP/layout.json"
pane_id="$(json_value "$TMP/layout.json" 'layout.root.pane_id')"
tab_id="$(json_value "$TMP/layout.json" 'layout.tab_id')"
readonly pane_id tab_id
[[ -n "$pane_id" && -n "$tab_id" ]] || fail "pane identity missing"

HERDR_SOCKET_PATH="$SOCKET" herdr terminal session observe \
    "$pane_id" --cols 120 --rows 40 >"$TMP/observer.out" 2>"$TMP/observer.err" &
observer_pid=$!
# Runtime snapshot attestation precedes spawn and may traverse tens of thousands of files.
# Start the UI visibility deadline only after the host has atomically recorded the child.
for _ in $(/usr/bin/seq 1 2400); do
    [[ -f "$CHILD_PROCESS_RECORD" ]] && break
    [[ ! -f "$RUN_ROOT/$FRESH_LAUNCH_ATTEMPT_ID/failure.json" ]] || \
        fail "host failed before Pi child launch"
    [[ ! -f "$CHANNEL_ROOT/result.json" ]] || fail "result raced Pi child launch"
    [[ ! -f "$PROVIDER_OUTPUT_STARTED" ]] || fail "provider output preceded Pi child launch"
    /bin/sleep 0.05
done
[[ -f "$CHILD_PROCESS_RECORD" ]] || fail "Pi child did not start before bounded deadline"
if ! "$NODE" - "$CHILD_PROCESS_RECORD" "$FRESH_LAUNCH_ATTEMPT_ID" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2], launchAttemptID = process.argv[3];
const stat = fs.lstatSync(file);
const value = JSON.parse(fs.readFileSync(file, "utf8"));
if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid()
    || stat.nlink !== 1 || (stat.mode & 0o077) !== 0
    || value.schemaVersion !== 1 || value.launchAttemptID !== launchAttemptID
    || !Number.isSafeInteger(value.processID) || value.processID <= 0
    || value.processGroupID !== value.processID
    || !Number.isSafeInteger(value.startSeconds) || value.startSeconds <= 0
    || !Number.isSafeInteger(value.startMicroseconds)
    || value.startMicroseconds < 0 || value.startMicroseconds >= 1_000_000) process.exit(1);
NODE
then
    fail "Pi child process record is invalid"
fi
for _ in $(/usr/bin/seq 1 1000); do
    HERDR_SOCKET_PATH="$SOCKET" herdr pane read \
        "$pane_id" --source recent --lines 80 --format text \
        >"$TMP/pre-result-screen.txt" 2>/dev/null || true
    if /usr/bin/grep -Fq "interactive input is locked" "$TMP/pre-result-screen.txt"; then
        [[ ! -f "$PROVIDER_OUTPUT_STARTED" ]] || \
            fail "provider output preceded locked observer visibility"
        break
    fi
    [[ ! -f "$CHANNEL_ROOT/result.json" ]] || fail "result raced pre-result input probe"
    [[ ! -f "$PROVIDER_OUTPUT_STARTED" ]] || \
        fail "provider output preceded locked observer visibility"
    /bin/sleep 0.02
done
/usr/bin/grep -Fq "interactive input is locked" "$TMP/pre-result-screen.txt" || \
    fail "locked observer editor was not visible before provider output"
HERDR_SOCKET_PATH="$SOCKET" herdr pane send-text "$pane_id" "$MANUAL_SENTINEL" >/dev/null
HERDR_SOCKET_PATH="$SOCKET" herdr pane send-keys "$pane_id" enter >/dev/null
HERDR_SOCKET_PATH="$SOCKET" herdr pane send-text \
    "$pane_id" "/export $MANUAL_BYPASS" >/dev/null
HERDR_SOCKET_PATH="$SOCKET" herdr pane send-keys "$pane_id" enter >/dev/null
/bin/sleep 0.1
[[ ! -e "$MANUAL_BYPASS" ]] || fail "locked observer accepted built-in export command"
for _ in $(/usr/bin/seq 1 100); do
    HERDR_SOCKET_PATH="$SOCKET" herdr pane read \
        "$pane_id" --source recent --lines 200 --format text >"$TMP/screen.txt" 2>/dev/null || true
    if "$NODE" "$FIXTURE" assert-observer "$TMP/observer.out" >/dev/null 2>&1 && \
        "$NODE" "$FIXTURE" assert-screen "$TMP/screen.txt" >/dev/null 2>&1; then
        break
    fi
    /bin/sleep 0.05
done
"$NODE" "$FIXTURE" assert-observer "$TMP/observer.out" >/dev/null || \
    fail "observer emitted no authenticated terminal frame"
"$NODE" "$FIXTURE" assert-screen "$TMP/screen.txt" >/dev/null || \
    fail "observer screen omitted exact Pi TUI evidence"

HERDR_SOCKET_PATH="$SOCKET" herdr pane process-info \
    --pane "$pane_id" >"$TMP/first-process.json"
pi_process_group="$(json_value "$TMP/first-process.json" 'result.process_info.foreground_process_group_id')"
readonly pi_process_group
[[ "$pi_process_group" =~ ^[1-9][0-9]*$ ]] || fail "foreground Pi process group missing"
"$NODE" - "$TMP/first-process.json" "$pi_process_group" "$WORK_ROOT" <<'NODE'
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).result.process_info;
const processGroup = Number(process.argv[3]), work = process.argv[4];
if (value.foreground_process_group_id !== processGroup
    || value.foreground_processes?.length !== 1
    || value.foreground_processes[0].pid !== processGroup
    || value.foreground_processes[0].name !== "node"
    || value.foreground_processes[0].cwd !== work) process.exit(1);
NODE

# The fixture kills Pi after the successful terminal tool result reaches session history,
# but before the TUI side channel is written.
for _ in $(/usr/bin/seq 1 800); do
    "$NODE" "$FIXTURE" snapshot "$SOCKET" >"$TMP/after-crash.json"
    provider_calls="0"
    if [[ -f "$PROVIDER_CALL" ]]; then
        provider_calls="$(/usr/bin/wc -l <"$PROVIDER_CALL" | /usr/bin/tr -d ' ')"
    fi
    pane_present="$("$NODE" - "$TMP/after-crash.json" "$pane_id" <<'NODE'
const fs = require("node:fs");
const snapshot = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).snapshot;
process.stdout.write(snapshot.panes.some((pane) => pane.pane_id === process.argv[3]) ? "1" : "0");
NODE
)"
    fresh_failure="$RUN_ROOT/$FRESH_LAUNCH_ATTEMPT_ID/failure.json"
    if [[ "$provider_calls" == "2" && "$pane_present" == "0" \
        && -f "$CHANNEL_ROOT/session.json" && -f "$fresh_failure" ]]; then
        break
    fi
    /bin/sleep 0.05
done
stop_observer
[[ -f "$PROVIDER_CALL" ]] || fail "fixture provider call evidence is missing"
[[ "$(/usr/bin/wc -l <"$PROVIDER_CALL" | /usr/bin/tr -d ' ')" == "2" ]] || \
    fail "causal tool loop did not make exactly two provider requests"
[[ -f "$CHANNEL_ROOT/session.json" ]] || fail "Pi session identity was not recorded"
[[ ! -f "$CHANNEL_ROOT/result.json" ]] || fail "fault point ran after side-channel result"
[[ ! -f "$CHANNEL_ROOT/acknowledgement.json" ]] || fail "crashed Pi was acknowledged early"
[[ ! -f "$CHANNEL_ROOT/runtime-failure.json" ]] || fail "causal crash became a runtime failure"
"$NODE" - "$PROVIDER_CALL" <<'NODE'
const fs = require("node:fs");
const values = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").map(JSON.parse);
if (values.length !== 2 || values.some((value, index) => value.schemaVersion !== 1
    || value.provider !== "jidoka-fixture" || value.modelID !== "fixture"
    || value.requestSequence !== index + 1)) process.exit(1);
NODE
"$NODE" "$FIXTURE" assert-recorded-result \
    "$TUI_CONFIGURATION" "$MANUAL_SENTINEL" >"$TMP/recorded-result.json"
fresh_failure="$RUN_ROOT/$FRESH_LAUNCH_ATTEMPT_ID/failure.json"
readonly fresh_failure
[[ -f "$fresh_failure" ]] || fail "crashed launch omitted typed host failure"
[[ "$(json_value "$fresh_failure" 'code')" == "CHILD_FAILED" ]] || \
    fail "crashed launch failure was not classified"
"$NODE" - "$TMP/after-crash.json" "$pane_id" <<'NODE'
const fs = require("node:fs");
const snapshot = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).snapshot;
if (snapshot.panes.some((pane) => pane.pane_id === process.argv[3])) process.exit(1);
NODE
provider_call_sha256="$(/usr/bin/shasum -a 256 "$PROVIDER_CALL" | /usr/bin/awk '{print $1}')"
readonly provider_call_sha256

# Resume the exact Pi session. Causal session recovery suppresses another prompt and provider call.
session_id="$(json_value "$CHANNEL_ROOT/session.json" 'sessionID')"
readonly session_id
readonly RESUME_TUI_CONFIGURATION="$CHANNEL_ROOT/tui-resume.json"
"$NODE" - \
    "$TMP/fresh-spec.json" "$TMP/resume-spec.json" "$RESUME_TUI_CONFIGURATION" \
    "$RESUME_LAUNCH_ATTEMPT_ID" "$session_id" <<'NODE'
const fs = require("node:fs");
const [source, destination, tuiConfiguration, launchAttemptID, expectedSessionID]
  = process.argv.slice(2);
const specification = JSON.parse(fs.readFileSync(source, "utf8"));
specification.agentAlias = "jc-s12-g1-resume";
specification.expectedSessionID = expectedSessionID;
specification.launchAttemptID = launchAttemptID;
specification.title = "Exact Pi TUI issue triage resume";
specification.tuiConfiguration = tuiConfiguration;
fs.writeFileSync(destination, `${JSON.stringify(specification)}\n`, { flag: "wx", mode: 0o600 });
NODE
"$PREPARER" --prepare-h3 "$TMP/resume-spec.json" >"$TMP/resume-descriptor.json"
"$NODE" - "$TMP/resume-descriptor.json" "$session_id" <<'NODE'
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const index = value.argumentValues.indexOf("--session");
if (value.schemaVersion !== 3 || value.runID !== "run-s12-triage"
    || value.launchAttemptID !== "attempt-s12-triage-0002"
    || index < 0 || value.argumentValues[index + 1] !== process.argv[3]) process.exit(1);
NODE
"$NODE" "$FIXTURE" apply-layout \
    "$SOCKET" "$workspace_id" "j/s12/g1-resume" "$HOST" "$RUN_ROOT" "$WORK_ROOT" \
    "$RESUME_LAUNCH_ATTEMPT_ID" >"$TMP/resume-layout.json"
resume_pane_id="$(json_value "$TMP/resume-layout.json" 'layout.root.pane_id')"
readonly resume_pane_id
HERDR_SOCKET_PATH="$SOCKET" herdr terminal session observe \
    "$resume_pane_id" --cols 120 --rows 40 \
    >"$TMP/resume-observer.out" 2>"$TMP/resume-observer.err" &
observer_pid=$!
for _ in $(/usr/bin/seq 1 600); do
    HERDR_SOCKET_PATH="$SOCKET" herdr pane read \
        "$resume_pane_id" --source recent --lines 200 --format text \
        >"$TMP/resume-screen.txt" 2>/dev/null || true
    if "$NODE" "$FIXTURE" assert-observer "$TMP/resume-observer.out" >/dev/null 2>&1 && \
        "$NODE" "$FIXTURE" assert-resume-screen "$TMP/resume-screen.txt" >/dev/null 2>&1; then
        break
    fi
    /bin/sleep 0.05
done
"$NODE" "$FIXTURE" assert-observer "$TMP/resume-observer.out" >/dev/null || \
    fail "resume observer emitted no authenticated frame"
"$NODE" "$FIXTURE" assert-resume-screen "$TMP/resume-screen.txt" >/dev/null || \
    fail "resume screen omitted exact Pi TUI evidence"
[[ "$(/usr/bin/shasum -a 256 "$PROVIDER_CALL" | /usr/bin/awk '{print $1}')" == \
    "$provider_call_sha256" ]] || fail "resume invoked the fixture provider again"
[[ ! -e "$MANUAL_BYPASS" ]] || fail "resume exposed built-in export mutation"
HERDR_SOCKET_PATH="$SOCKET" herdr agent wait \
    "$resume_pane_id" --until "done" --timeout 60000 \
    >"$TMP/wait.json" 2>"$TMP/wait.err" &
agent_wait_pid=$!
/bin/sleep 0.1
"$PREPARER" --acknowledge-h3 \
    "$RESUME_TUI_CONFIGURATION" "$WORKFLOW_CONFIGURATION" >"$TMP/acknowledged.json"
if ! wait "$agent_wait_pid"; then
    /bin/cat "$TMP/wait.err" >&2
    fail "Herdr did not observe the accepted result lifecycle transition"
fi
"$NODE" "$FIXTURE" snapshot "$SOCKET" >"$TMP/settled.json"
"$NODE" "$FIXTURE" assert-session \
    "$RESUME_TUI_CONFIGURATION" "$MANUAL_SENTINEL" >"$TMP/session-evidence.json"
"$NODE" - \
    "$TMP/before.json" "$TMP/settled.json" "$TMP/wait.json" \
    "$resume_pane_id" "$RUN_ID" "$RESUME_LAUNCH_ATTEMPT_ID" <<'NODE'
const fs = require("node:fs");
const before = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).snapshot;
const settled = JSON.parse(fs.readFileSync(process.argv[3], "utf8")).snapshot;
const wait = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const paneID = process.argv[5], runID = process.argv[6], launchAttemptID = process.argv[7];
if (JSON.stringify([before.focused_workspace_id, before.focused_tab_id, before.focused_pane_id])
    !== JSON.stringify([settled.focused_workspace_id, settled.focused_tab_id, settled.focused_pane_id])) process.exit(10);
const agent = wait.result?.agent;
if (!agent || agent.pane_id !== paneID || agent.name !== "jc-s12-g1-resume"
    || agent.agent_status !== "done") process.exit(11);
if (agent.agent_session !== undefined && agent.agent_session !== null) process.exit(12);
if (agent.tokens?.managed_by !== "jidoka" || agent.tokens?.run_id !== runID
    || agent.tokens?.launch_attempt_id !== launchAttemptID
    || agent.tokens?.role !== "triage") process.exit(13);
if (!settled.panes.some((pane) => pane.pane_id === paneID)) process.exit(14);
NODE
"$NODE" - \
    "$CHANNEL_ROOT/child-process-$FRESH_LAUNCH_ATTEMPT_ID.json" \
    "$CHANNEL_ROOT/child-process-$RESUME_LAUNCH_ATTEMPT_ID.json" <<'NODE'
const fs = require("node:fs");
for (const path of process.argv.slice(2)) {
  const record = JSON.parse(fs.readFileSync(path, "utf8"));
  if (record.schemaVersion !== 1 || !Number.isInteger(record.processID)
      || record.processID <= 0 || record.processGroupID !== record.processID
      || !Number.isInteger(record.startSeconds)
      || !Number.isInteger(record.startMicroseconds)) process.exit(15);
}
NODE
"$NODE" --input-type=module - \
    "$ROOT/Resources/Pi/runtime/jidoka-tui-contract.mjs" \
    "$CHANNEL_ROOT/session.json" "$CHANNEL_ROOT/result.json" \
    "$TMP/cross-run-resume.json" <<'NODE'
import fs, { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";
const [contractPath, sessionIdentityPath, resultPath, evidencePath] = process.argv.slice(2);
const {
  currentRunMessages, pinnedPromptAction, recordSessionIdentity,
} = await import(pathToFileURL(contractPath));
const sessionIdentity = JSON.parse(fs.readFileSync(sessionIdentityPath, "utf8"));
const result = JSON.parse(fs.readFileSync(resultPath, "utf8"));
const messages = fs.readFileSync(sessionIdentity.sessionFile, "utf8").trim().split("\n")
  .map(JSON.parse).filter((entry) => entry.type === "message").map((entry) => entry.message);
const nextPrompt = "Pinned next logical writer round.\n";
const configuration = {
  launchMode: "resume",
  resumeBoundarySHA256: result.sessionBoundarySHA256,
  runID: "run-s12-next-round",
  runNonce: "f".repeat(64),
};
const suffix = currentRunMessages(configuration, messages);
const action = pinnedPromptAction(configuration, nextPrompt, []);
let nullBoundaryBlocked = false;
try {
  recordSessionIdentity({
    ...configuration,
    channelDirectory: dirname(sessionIdentityPath),
    expectedSessionID: sessionIdentity.sessionID,
    resumeBoundarySHA256: null,
    sessionDirectory: dirname(sessionIdentity.sessionFile),
  }, sessionIdentity.sessionID, sessionIdentity.sessionFile);
} catch {
  nullBoundaryBlocked = true;
}
const crossRunChannel = `${dirname(evidencePath)}/cross-run-channel`;
mkdirSync(crossRunChannel, { mode: 0o700 });
const crossRunIdentityConfiguration = {
  ...configuration,
  channelDirectory: crossRunChannel,
  expectedSessionID: sessionIdentity.sessionID,
  sessionDirectory: dirname(sessionIdentity.sessionFile),
};
recordSessionIdentity(
  crossRunIdentityConfiguration,
  sessionIdentity.sessionID,
  sessionIdentity.sessionFile,
);
let crossRunDowngradeBlocked = false;
try {
  recordSessionIdentity(
    { ...crossRunIdentityConfiguration, resumeBoundarySHA256: null },
    sessionIdentity.sessionID,
    sessionIdentity.sessionFile,
  );
} catch {
  crossRunDowngradeBlocked = true;
}
if (suffix.length !== 0 || action !== "send" || !nullBoundaryBlocked
    || !crossRunDowngradeBlocked) process.exit(1);
fs.writeFileSync(evidencePath, `${JSON.stringify({
  action, crossRunDowngradeBlocked, nullBoundaryBlocked,
  priorSessionID: sessionIdentity.sessionID,
  resumeBoundarySHA256: result.sessionBoundarySHA256,
  runID: configuration.runID, runNonce: configuration.runNonce, suffixMessages: suffix.length,
})}\n`, { flag: "wx", mode: 0o600 });
NODE

"$PREPARER" --release-h3 \
    "$RESUME_TUI_CONFIGURATION" "$WORKFLOW_CONFIGURATION" >"$TMP/released.json"
for _ in $(/usr/bin/seq 1 100); do
    "$NODE" "$FIXTURE" snapshot "$SOCKET" >"$TMP/after-release.json"
    if ! "$NODE" - "$TMP/after-release.json" "$resume_pane_id" <<'NODE'
const fs = require("node:fs");
const snapshot = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).snapshot;
process.exit(snapshot.panes.some((pane) => pane.pane_id === process.argv[3]) ? 0 : 1);
NODE
    then
        break
    fi
    /bin/sleep 0.05
done
"$NODE" - "$TMP/after-release.json" "$resume_pane_id" <<'NODE'
const fs = require("node:fs");
const snapshot = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).snapshot;
if (snapshot.panes.some((pane) => pane.pane_id === process.argv[3])) process.exit(1);
NODE

# Exercise the real extension-to-host typed runtime-failure path with a command drift
# introduced only by the DEBUG fixture provider.
"$NODE" - \
    "$TMP/failure-spec.json" "$FAILURE_LAUNCH_ATTEMPT_ID" "$FAILURE_RUN_ID" \
    "$FAILURE_RUN_NONCE" "$ARTIFACT_SHA256" "$RUN_ROOT" "$ROOT/Resources/Pi" \
    "$WORK_ROOT" "$HOME_ROOT" "$AGENT_ROOT" "$TEMP_ROOT" "$FAILURE_SESSION_ROOT" \
    "$FAILURE_CHANNEL_ROOT" "$FAILURE_WORKFLOW_CONFIGURATION" \
    "$FAILURE_TUI_CONFIGURATION" "$FAILURE_PROMPT_FILE" "$PROVIDER_FIXTURE" \
    "$FAILURE_PROVIDER_CALL" "$workspace_id" <<'NODE'
const fs = require("node:fs");
const [destination, launchAttemptID, runID, runNonce, artifactSHA256, runRoot,
  resourceRoot, workspaceRoot, homeDirectory, agentDirectory, temporaryDirectory,
  sessionDirectory, channelDirectory, workflowConfiguration, tuiConfiguration,
  promptPath, fixtureProviderExtension, fixtureProviderCall, workspaceID] = process.argv.slice(2);
const specification = {
  agentAlias: "jc-s12-g1-failure", agentDirectory, artifactSHA256, channelDirectory,
  expectedSessionID: null, fixtureProviderCall, fixtureProviderExtension, homeDirectory,
  launchAttemptID, promptPath, resourceRoot, runID, runNonce, runRoot, sessionDirectory,
  sessionName: "jidoka-run-s12-failure", temporaryDirectory,
  title: "Exact Pi TUI typed failure", tuiConfiguration, workflowConfiguration,
  workflowNonce: "failure-nonce", workspaceID, workspaceRoot,
};
fs.writeFileSync(destination, `${JSON.stringify(specification)}\n`, { flag: "wx", mode: 0o600 });
NODE
"$PREPARER" --prepare-h3 "$TMP/failure-spec.json" >"$TMP/failure-descriptor.json"
"$NODE" "$FIXTURE" apply-layout \
    "$SOCKET" "$workspace_id" "j/s12/failure" "$HOST" "$RUN_ROOT" "$WORK_ROOT" \
    "$FAILURE_LAUNCH_ATTEMPT_ID" >"$TMP/failure-layout.json"
failure_pane_id="$(json_value "$TMP/failure-layout.json" 'layout.root.pane_id')"
readonly failure_pane_id
runtime_failure="$FAILURE_CHANNEL_ROOT/runtime-failure.json"
host_failure="$RUN_ROOT/$FAILURE_LAUNCH_ATTEMPT_ID/failure.json"
readonly runtime_failure host_failure
for _ in $(/usr/bin/seq 1 1200); do
    [[ -f "$runtime_failure" && -f "$host_failure" ]] && break
    /bin/sleep 0.05
done
[[ -f "$runtime_failure" ]] || fail "extension omitted typed runtime failure"
[[ -f "$host_failure" ]] || fail "host omitted typed runtime failure relay"
[[ "$(json_value "$runtime_failure" 'code')" == "COMMAND_PROVENANCE_MISMATCH" ]] || \
    fail "extension runtime failure detail drifted"
[[ "$(json_value "$host_failure" 'code')" == "TUI_RUNTIME_FAILED" ]] || \
    fail "host runtime failure classification drifted"
[[ "$(json_value "$host_failure" 'detailCode')" == "COMMAND_PROVENANCE_MISMATCH" ]] || \
    fail "host runtime failure detail drifted"
[[ ! -f "$FAILURE_CHANNEL_ROOT/result.json" \
    && ! -f "$FAILURE_CHANNEL_ROOT/acknowledgement.json" \
    && ! -f "$FAILURE_PROVIDER_CALL" ]] || fail "typed runtime failure gained result authority"

"$NODE" "$FIXTURE" snapshot "$SOCKET" >"$TMP/final-snapshot.json"
"$NODE" - "$TMP/before.json" "$TMP/final-snapshot.json" <<'NODE'
const fs = require("node:fs");
const before = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).snapshot;
const after = JSON.parse(fs.readFileSync(process.argv[3], "utf8")).snapshot;
const focus = (value) => [value.focused_workspace_id, value.focused_tab_id, value.focused_pane_id];
if (JSON.stringify(focus(before)) !== JSON.stringify(focus(after))) process.exit(1);
NODE
/bin/sleep 0.25
[[ ! -s "$NETWORK_TRAP_LOG" ]] || fail "fixture provider contacted its network endpoint"

stop_local_processes
verify_cleanup || fail "named session cleanup was not observable"
if [[ "${KEEP_S12_ARTIFACTS:-0}" == "1" ]]; then
    manifest_list="$(/usr/bin/mktemp "$ROOT/build/evidence/.s12-manifest-list.XXXXXX")"
    (
        cd "$TMP"
        /usr/bin/find . -type f ! -name evidence.sha256 -print
    ) >"$manifest_list"
    (
        cd "$TMP"
        LC_ALL=C /usr/bin/sort "$manifest_list" \
            | while IFS= read -r file; do
                /usr/bin/shasum -a 256 "$file"
            done >evidence.sha256
    )
    /bin/rm -f -- "$manifest_list"
    evidence_manifest_sha256="$(
        /usr/bin/shasum -a 256 "$TMP/evidence.sha256" | /usr/bin/awk '{print $1}'
    )"
    printf 'evidence=%s evidence_manifest_sha256=%s\n' \
        "$TMP" "$evidence_manifest_sha256"
fi
printf 'S12 exact Pi TUI isolated E2E: PASS\n'
printf 'session=%s workspace=%s panes=%s,%s,%s model=jidoka-fixture/fixture:off provider_calls=2\n' \
    "$HERDR_SESSION_NAME" "$workspace_id" "$pane_id" "$resume_pane_id" "$failure_pane_id"
printf 'fresh_prompt=1 causal_tool_loop=1 recorded_before_crash=1 side_channel_before_crash=0 causal_resume=1 resume_prompt=0 cross_run_resume_boundary=1 cross_run_null_downgrade_blocked=1 result=1 acknowledgement=1 typed_runtime_failure=1 manual_input_context=0 pre_result_input_blocked=1 built_in_input_blocked=1 builder_parity=1 exact_process_group=1 child_process_identity=1 old_pane_removed=1 pane_retained_until_release=1 focus_changes=0 provider_network_measured=1 provider_network=0\n'
