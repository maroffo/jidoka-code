#!/usr/bin/env bash
set -euo pipefail

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly NODE="/opt/homebrew/Cellar/node/26.6.0/bin/node"
readonly FIXTURE="$SCRIPT_DIR/herdr-s11-fixture.mjs"

fail() {
    printf 'S11 Herdr failed: %s\n' "$1" >&2
    exit 1
}

json_value() {
    local file="$1"
    local expression="$2"
    "$NODE" -e '
      const fs = require("node:fs");
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const parts = process.argv[2].split(".");
      let current = value;
      for (const part of parts) current = current?.[part];
      if (current === undefined || current === null) process.exit(2);
      process.stdout.write(String(current));
    ' "$file" "$expression"
}

"$ROOT/scripts/verify-toolchain.sh"
"$NODE" --check "$FIXTURE"
command -v herdr >/dev/null 2>&1 || fail "Herdr is unavailable"
[[ "$(herdr --version | /usr/bin/awk '{print $2}')" == "0.8.0" ]] || \
    fail "Herdr 0.8.0 is required"

cd "$ROOT"
/usr/bin/xcrun swift build --configuration release --product JidokaCodeHerdrHost
/usr/bin/xcrun swift build --configuration release --product JidokaCodeHerdrFixture
BIN_DIR="$(/usr/bin/xcrun swift build --configuration release --show-bin-path)"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
readonly BIN_DIR
readonly HOST="$BIN_DIR/JidokaCodeHerdrHost"
readonly CHILD="$BIN_DIR/JidokaCodeHerdrFixture"
[[ -f "$HOST" && -x "$HOST" && ! -L "$HOST" ]] || fail "missing host product"
[[ -f "$CHILD" && -x "$CHILD" && ! -L "$CHILD" ]] || fail "missing fixture product"

/bin/mkdir -p "$ROOT/build/evidence"
TMP="$(/usr/bin/mktemp -d "$ROOT/build/evidence/jidoka-herdr-s11.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
readonly TMP
readonly RUN_ROOT="$TMP/runs"
readonly WORK_ROOT="$TMP/work"
SESSION_SUFFIX="$(/usr/bin/basename "$TMP" | /usr/bin/awk -F. '{print tolower($NF)}')"
readonly SESSION_SUFFIX
readonly SESSION_NAME="jidoka-s11-$SESSION_SUFFIX"
readonly SESSION_DIR="$HOME/.config/herdr/sessions/$SESSION_NAME"
readonly SOCKET="$SESSION_DIR/herdr.sock"
readonly DEFAULT_SOCKET="$HOME/.config/herdr/herdr.sock"
server_pid=""
observer_plan_pid=""
observer_review_pid=""
wait_plan_pid=""
wait_review_pid=""
cleanup_verified=0

stop_observers() {
    if [[ -n "$observer_plan_pid" ]]; then
        /bin/kill "$observer_plan_pid" >/dev/null 2>&1 || true
        wait "$observer_plan_pid" 2>/dev/null || true
        observer_plan_pid=""
    fi
    if [[ -n "$observer_review_pid" ]]; then
        /bin/kill "$observer_review_pid" >/dev/null 2>&1 || true
        wait "$observer_review_pid" 2>/dev/null || true
        observer_review_pid=""
    fi
}

stop_local_processes() {
    stop_observers
    if [[ -n "$wait_plan_pid" ]]; then
        /bin/kill "$wait_plan_pid" >/dev/null 2>&1 || true
        wait "$wait_plan_pid" 2>/dev/null || true
        wait_plan_pid=""
    fi
    if [[ -n "$wait_review_pid" ]]; then
        /bin/kill "$wait_review_pid" >/dev/null 2>&1 || true
        wait "$wait_review_pid" 2>/dev/null || true
        wait_review_pid=""
    fi
    if [[ -n "$server_pid" ]]; then
        /bin/kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=""
    fi
}

session_is_absent() {
    [[ ! -e "$SESSION_DIR" && ! -S "$SOCKET" ]] || return 1
    herdr session list --json | "$NODE" -e '
      const fs = require("node:fs");
      const value = JSON.parse(fs.readFileSync(0, "utf8"));
      const name = process.argv[1];
      process.exit(value.sessions?.some((session) => session.name === name) ? 1 : 0);
    ' "$SESSION_NAME"
}

verify_cleanup() {
    stop_local_processes
    herdr session stop "$SESSION_NAME" --json >"$TMP/session-stop.json" 2>"$TMP/session-stop.err" || true
    herdr session delete "$SESSION_NAME" --json >"$TMP/session-delete.json" 2>"$TMP/session-delete.err" || true
    session_is_absent || return 1
    cleanup_verified=1
}

cleanup() {
    if [[ "$cleanup_verified" != "1" ]]; then
        stop_local_processes
        herdr session stop "$SESSION_NAME" --json >/dev/null 2>&1 || true
        herdr session delete "$SESSION_NAME" --json >/dev/null 2>&1 || true
    fi
    if [[ "${KEEP_S11_ARTIFACTS:-0}" == "1" ]]; then
        printf 'S11 artifacts retained at %s\n' "$TMP" >&2
    else
        /bin/rm -rf -- "$TMP"
    fi
}
trap cleanup EXIT

/bin/mkdir -m 0700 "$RUN_ROOT" "$WORK_ROOT"
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
    SESSION_NAME="$SESSION_NAME" \
    TERM=xterm-256color \
    /usr/bin/expect -c \
    'log_user 0; set timeout -1; set stty_init "rows 40 columns 120"; spawn -noecho herdr --session $env(SESSION_NAME); expect eof' \
    >"$TMP/server.out" 2>"$TMP/server.err" &
server_pid=$!
for _ in $(/usr/bin/seq 1 100); do
    [[ -S "$SOCKET" ]] && break
    /bin/sleep 0.05
done
[[ -S "$SOCKET" ]] || fail "named session socket did not start"
[[ "$(/usr/bin/stat -f '%Sp' "$SOCKET")" == "srw-------" ]] || fail "unsafe named socket mode"
"$NODE" "$FIXTURE" ping "$SOCKET" >"$TMP/ping.json"
[[ "$(json_value "$TMP/ping.json" 'version')" == "0.8.0" ]] || fail "version mismatch"
[[ "$(json_value "$TMP/ping.json" 'protocol')" == "19" ]] || fail "protocol mismatch"
[[ "$(json_value "$TMP/ping.json" 'capabilities.live_handoff')" == "true" ]] || \
    fail "live handoff unavailable"
[[ "$(json_value "$TMP/ping.json" 'capabilities.detached_server_daemon')" == "true" ]] || \
    fail "detached daemon unavailable"

"$NODE" "$FIXTURE" snapshot "$SOCKET" >"$TMP/before.json"
"$NODE" "$FIXTURE" create-workspace \
    "$SOCKET" "jidoka-s11-$SESSION_SUFFIX" "$WORK_ROOT" >"$TMP/workspace.json"
workspace_id="$(json_value "$TMP/workspace.json" 'workspace.workspace_id')"
readonly workspace_id
[[ -n "$workspace_id" ]] || fail "created workspace id missing"

"$NODE" "$FIXTURE" prepare-descriptor \
    "$RUN_ROOT" "$workspace_id" "$CHILD" "$WORK_ROOT" \
    "run-s11-plan" "jc-s11-g1-plan" "plan" >"$TMP/descriptor-plan.json"
"$NODE" "$FIXTURE" prepare-descriptor \
    "$RUN_ROOT" "$workspace_id" "$CHILD" "$WORK_ROOT" \
    "run-s11-review" "jc-s11-g1-review" "review" >"$TMP/descriptor-review.json"
"$NODE" "$FIXTURE" apply-layout \
    "$SOCKET" "$workspace_id" "j/s11/g1" "$HOST" "$RUN_ROOT" \
    "$WORK_ROOT" "run-s11-plan" "run-s11-review" >"$TMP/layout.json"
plan_pane_id="$(json_value "$TMP/layout.json" 'layout.root.first.pane_id')"
review_pane_id="$(json_value "$TMP/layout.json" 'layout.root.second.pane_id')"
tab_id="$(json_value "$TMP/layout.json" 'layout.tab_id')"
readonly plan_pane_id review_pane_id tab_id
[[ -n "$plan_pane_id" && -n "$review_pane_id" && -n "$tab_id" ]] || \
    fail "split layout identity missing"
[[ "$plan_pane_id" != "$review_pane_id" ]] || fail "role panes are not distinct"
for _ in $(/usr/bin/seq 1 40); do
    if "$NODE" "$FIXTURE" export-layout "$SOCKET" "$tab_id" \
        >"$TMP/export.json" 2>"$TMP/export.err"; then
        break
    fi
    /bin/sleep 0.05
done
[[ -s "$TMP/export.json" ]] || fail "split layout export unavailable"
"$NODE" - "$TMP/export.json" "$tab_id" "$HOST" <<'NODE'
const fs = require("node:fs");
const exported = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const root = exported.layout?.root;
const command = (runID) => [process.argv[4], "--launch-attempt-id", runID];
if (exported.layout?.tab_id !== process.argv[3]) process.exit(20);
if (root?.type !== "split" || root.direction !== "right" || root.ratio !== 0.5) process.exit(21);
if (root.first?.type !== "pane" || root.first.label !== "plan") process.exit(22);
if (root.second?.type !== "pane" || root.second.label !== "review") process.exit(23);
if (JSON.stringify(root.first.command) !== JSON.stringify(command("run-s11-plan"))) process.exit(24);
if (JSON.stringify(root.second.command) !== JSON.stringify(command("run-s11-review"))) process.exit(25);
NODE

HERDR_SOCKET_PATH="$SOCKET" herdr terminal session observe \
    "$plan_pane_id" --cols 100 --rows 30 \
    >"$TMP/observer-plan.out" 2>"$TMP/observer-plan.err" &
observer_plan_pid=$!
HERDR_SOCKET_PATH="$SOCKET" herdr terminal session observe \
    "$review_pane_id" --cols 100 --rows 30 \
    >"$TMP/observer-review.out" 2>"$TMP/observer-review.err" &
observer_review_pid=$!
for _ in $(/usr/bin/seq 1 60); do
    HERDR_SOCKET_PATH="$SOCKET" herdr pane read \
        "$plan_pane_id" --source visible --lines 30 >"$TMP/screen-plan.txt" 2>/dev/null || true
    HERDR_SOCKET_PATH="$SOCKET" herdr pane read \
        "$review_pane_id" --source visible --lines 30 >"$TMP/screen-review.txt" 2>/dev/null || true
    if "$NODE" "$FIXTURE" assert-observer "$TMP/observer-plan.out" 2>/dev/null && \
        "$NODE" "$FIXTURE" assert-observer "$TMP/observer-review.out" 2>/dev/null && \
        "$NODE" "$FIXTURE" assert-screen "$TMP/screen-plan.txt" "run-s11-plan" 2>/dev/null && \
        "$NODE" "$FIXTURE" assert-screen "$TMP/screen-review.txt" "run-s11-review" 2>/dev/null; then
        break
    fi
    /bin/sleep 0.05
done
"$NODE" "$FIXTURE" assert-observer "$TMP/observer-plan.out" || \
    fail "plan observer emitted no valid frame"
"$NODE" "$FIXTURE" assert-observer "$TMP/observer-review.out" || \
    fail "review observer emitted no valid frame"
"$NODE" "$FIXTURE" assert-screen "$TMP/screen-plan.txt" "run-s11-plan" || \
    fail "plan screen missed fixture output"
"$NODE" "$FIXTURE" assert-screen "$TMP/screen-review.txt" "run-s11-review" || \
    fail "review screen missed fixture output"
stop_observers

HERDR_SOCKET_PATH="$SOCKET" herdr agent wait \
    "$plan_pane_id" --until "done" --timeout 15000 >"$TMP/wait-plan.json" &
wait_plan_pid=$!
HERDR_SOCKET_PATH="$SOCKET" herdr agent wait \
    "$review_pane_id" --until "done" --timeout 15000 >"$TMP/wait-review.json" &
wait_review_pid=$!
wait "$wait_plan_pid"
wait_plan_pid=""
wait "$wait_review_pid"
wait_review_pid=""

"$NODE" "$FIXTURE" snapshot "$SOCKET" >"$TMP/after.json"
"$NODE" - \
    "$TMP/before.json" "$TMP/after.json" \
    "$TMP/wait-plan.json" "$TMP/wait-review.json" \
    "$plan_pane_id" "$review_pane_id" <<'NODE'
const fs = require("node:fs");
const before = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).snapshot;
const after = JSON.parse(fs.readFileSync(process.argv[3], "utf8")).snapshot;
const planWait = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const reviewWait = JSON.parse(fs.readFileSync(process.argv[5], "utf8"));
const planPaneID = process.argv[6];
const reviewPaneID = process.argv[7];
const beforeFocus = [before.focused_workspace_id, before.focused_tab_id, before.focused_pane_id];
const afterFocus = [after.focused_workspace_id, after.focused_tab_id, after.focused_pane_id];
if (JSON.stringify(beforeFocus) !== JSON.stringify(afterFocus)) process.exit(10);
const checkAgent = (wait, paneID, name, runID, role) => {
  const agent = wait.result?.agent;
  if (!agent || agent.pane_id !== paneID || agent.name !== name || agent.agent_status !== "done") {
    process.exit(11);
  }
  if (agent.agent_session !== undefined && agent.agent_session !== null) process.exit(12);
  if (
    agent.tokens?.managed_by !== "jidoka" ||
    agent.tokens?.run_id !== runID ||
    agent.tokens?.role !== role
  ) {
    process.exit(13);
  }
};
checkAgent(planWait, planPaneID, "jc-s11-g1-plan", "run-s11-plan", "plan");
checkAgent(reviewWait, reviewPaneID, "jc-s11-g1-review", "run-s11-review", "review");
if (after.panes.some((value) => value.pane_id === planPaneID || value.pane_id === reviewPaneID)) {
  process.exit(14);
}
NODE

verify_cleanup || fail "named session cleanup was not observable"
printf 'S11 Herdr isolated E2E: PASS\n'
printf 'session=%s workspace=%s panes=%s,%s default_socket_contacts=0\n' \
    "$SESSION_NAME" "$workspace_id" "$plan_pane_id" "$review_pane_id"
printf 'roles=plan,review launch=exact-argv lifecycle=custom-no-session-ref child_herdr_env=0 focus_changes=0 terminal_close=after-done\n'
