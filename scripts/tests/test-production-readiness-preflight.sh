#!/usr/bin/env bash
# ABOUTME: Fixture-based tests for scripts/production-readiness-preflight.sh (plan W5).
# ABOUTME: Proves the preflight is read-only, cwd/PATH independent, bounded, closed-coded and
# rejects missing or drifted values, without touching any production state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly PREFLIGHT="$ROOT/scripts/production-readiness-preflight.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jidoka-preflight-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
readonly TEST_ROOT
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'test-production-readiness-preflight failed: %s\n' "$1" >&2
    exit 1
}

# Runs the preflight the way the runbook mandates: empty environment, cwd /.
run_preflight() {
    local rc=0
    (cd / && env -i /bin/bash "$PREFLIGHT" "$@") >"$TEST_ROOT/last-stdout" 2>"$TEST_ROOT/last-stderr" || rc=$?
    printf '%s' "$rc"
}

expect_rc() {
    local expected="$1" observed="$2" label="$3"
    if [[ "$observed" != "$expected" ]]; then
        printf '%s\n' '--- stderr ---' >&2
        cat "$TEST_ROOT/last-stderr" >&2 || true
        fail "$label: expected exit $expected, got $observed"
    fi
}

# --- Static command-inventory review ----------------------------------------

# The preflight must never invoke process-mutating, deleting or network-capable tools.
if grep -Eq '(curl|wget|osascript|launchctl|networksetup|scutil|/usr/bin/nc|/bin/rm|pkill|/bin/kill|/usr/bin/security)' "$PREFLIGHT"; then
    fail "preflight references a forbidden tool"
fi
# Every tool constant must be an absolute path.
while IFS= read -r line; do
    value="${line#readonly TOOL_*=}"
    [[ "$value" == /* ]] || fail "tool constant is not absolute: $line"
done < <(grep '^readonly TOOL_' "$PREFLIGHT")

# --- Bounded-runner mechanism -----------------------------------------------

# The signal-death notification belongs to the child shell, whose stderr is discarded.
rc=0
/bin/bash -c '/usr/bin/perl -e "my \$t = shift @ARGV; alarm \$t; exec { \$ARGV[0] } @ARGV; exit 127;" 1 /bin/sleep 5; exit $?' \
    2>/dev/null || rc=$?
[[ "$rc" -eq 142 ]] || fail "alarm-bounded exec did not terminate on timeout (rc=$rc)"

# --- Fixture construction ---------------------------------------------------

readonly FIXTURE="$TEST_ROOT/fixture"
readonly EVIDENCE_ROOT="$TEST_ROOT/evidence"
mkdir -p "$FIXTURE"
mkdir -m 0700 "$EVIDENCE_ROOT"

readonly PROBE_PACKAGE_ID="com.example.jidoka-preflight-probe.pkg"
readonly PROBE_BUNDLE_ID="com.example.jidoka-preflight-probe"
readonly PROBE_HELPER_ID="com.example.jidoka-preflight-probe.engine"
readonly PROBE_MAIN_EXECUTABLE="Probe Main"
readonly PROBE_HELPER_EXECUTABLE="ProbeEngine"
readonly PROBE_LAUNCH_PLIST="com.example.jidoka-preflight-probe.engine.plist"
OWNER="$(/usr/bin/id -u):$(/usr/bin/id -g)"
readonly OWNER
OS_VERSION="$(/usr/bin/sw_vers -productVersion)"
readonly OS_VERSION

# Receipt volume with a fabricated flat PackageKit receipt.
mkdir -p "$FIXTURE/vol/var/db/receipts"
write_receipt() {
    local version="$1" prefix="$2"
    cat > "$FIXTURE/vol/var/db/receipts/$PROBE_PACKAGE_ID.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>InstallDate</key><date>2026-08-27T10:00:00Z</date>
  <key>InstallPrefixPath</key><string>$prefix</string>
  <key>InstallProcessName</key><string>installer</string>
  <key>PackageFileName</key><string>Probe.pkg</string>
  <key>PackageIdentifier</key><string>$PROBE_PACKAGE_ID</string>
  <key>PackageVersion</key><string>$version</string>
</dict>
</plist>
EOF
}
write_receipt "0.1.0" "Applications"

# Parent directories with pinned owner/mode and no ACLs.
mkdir -p "$FIXTURE/parents/Library/Application Support"
chmod 755 "$FIXTURE/parents/Library" "$FIXTURE/parents/Library/Application Support"

# Legacy app bundle and legacy package evidence.
mkdir -p "$FIXTURE/Applications/Probe.app/Contents/MacOS"
printf 'legacy-package-bytes\n' > "$FIXTURE/legacy.pkg"
LEGACY_PACKAGE_SHA="$(/usr/bin/shasum -a 256 "$FIXTURE/legacy.pkg" | /usr/bin/awk '{print $1}')"
readonly LEGACY_PACKAGE_SHA

# Herdr executable behind a symlink chain.
mkdir -p "$FIXTURE/herdr-cellar/0.8.2/bin" "$FIXTURE/herdr-bin"
printf '#!/bin/sh\nexit 0\n' > "$FIXTURE/herdr-cellar/0.8.2/bin/herdr"
chmod 755 "$FIXTURE/herdr-cellar/0.8.2/bin/herdr"
ln -s "../herdr-cellar/0.8.2/bin/herdr" "$FIXTURE/herdr-bin/herdr"
HERDR_RESOLVED="$(/usr/bin/readlink -f "$FIXTURE/herdr-bin/herdr")"
readonly HERDR_RESOLVED
HERDR_SHA="$(/usr/bin/shasum -a 256 "$HERDR_RESOLVED" | /usr/bin/awk '{print $1}')"
readonly HERDR_SHA

# Git shim and backend stand-ins.
printf 'git-bytes\n' > "$FIXTURE/git"
printf 'git-http-backend-bytes\n' > "$FIXTURE/git-http-backend"
GIT_SHA="$(/usr/bin/shasum -a 256 "$FIXTURE/git" | /usr/bin/awk '{print $1}')"
readonly GIT_SHA
GIT_BACKEND_SHA="$(/usr/bin/shasum -a 256 "$FIXTURE/git-http-backend" | /usr/bin/awk '{print $1}')"
readonly GIT_BACKEND_SHA

# Database shaped like the production audit surface (default journal mode: a
# read-only connection creates no side files, so the mutation snapshot stays exact).
readonly DB="$FIXTURE/jidoka-code.sqlite3"
/usr/bin/sqlite3 "$DB" <<'EOF'
CREATE TABLE schema_migrations (version INTEGER NOT NULL);
INSERT INTO schema_migrations (version) VALUES (1),(2),(3),(4),(5),(6),(7),(8);
CREATE TABLE app_settings (singleton INTEGER PRIMARY KEY, paused INTEGER NOT NULL);
INSERT INTO app_settings (singleton, paused) VALUES (1, 1);
CREATE TABLE jobs (state TEXT NOT NULL);
INSERT INTO jobs (state) VALUES
  ('queued'),('queued'),('queued'),('blocked'),('blocked'),('runningPi');
EOF

write_expected() {
    local output="$1" mode="$2" secure_root="$3"
    cat > "$output" <<EOF
{
  "schemaVersion": 1,
  "mode": "$mode",
  "osProductVersion": "$OS_VERSION",
  "toolTimeoutSeconds": 30,
  "overallDeadlineSeconds": 600,
  "package": {
    "identifier": "$PROBE_PACKAGE_ID",
    "receiptVolume": "$FIXTURE/vol",
    "staticReceiptState": "legacy",
    "legacyReceiptVersion": "0.1.0",
    "legacyReceiptLocation": "Applications",
    "successorReceiptVersion": "0.1.1",
    "successorReceiptLocation": "Library/Application Support",
    "legacyPackagePath": "$FIXTURE/legacy.pkg",
    "legacyPackageSHA256": "$LEGACY_PACKAGE_SHA"
  },
  "bundle": {
    "identifier": "$PROBE_BUNDLE_ID",
    "helperIdentifier": "$PROBE_HELPER_ID",
    "teamIdentifier": "not set",
    "applicationSigningIdentitySHA1": "",
    "mainExecutableName": "$PROBE_MAIN_EXECUTABLE",
    "helperExecutableName": "$PROBE_HELPER_EXECUTABLE",
    "launchAgentPlistName": "$PROBE_LAUNCH_PLIST",
    "successorVersion": "0.1.1",
    "successorBuildVersion": "2",
    "legacyAppPath": "$FIXTURE/Applications/Probe.app",
    "securePath": "$secure_root/Applications/Probe.app",
    "secureRoot": "$secure_root",
    "legacyAppPostInstallState": "absent"
  },
  "preInstallParents": [
    { "path": "$FIXTURE/parents/Library", "owner": "$OWNER", "mode": "40755" },
    { "path": "$FIXTURE/parents/Library/Application Support", "owner": "$OWNER", "mode": "40755" }
  ],
  "postInstallParents": [
    { "path": "$FIXTURE/parents/Library", "owner": "$OWNER", "mode": "40755" },
    { "path": "$FIXTURE/parents/Library/Application Support", "owner": "$OWNER", "mode": "40755" },
    { "path": "$secure_root", "owner": "$OWNER", "mode": "40755" },
    { "path": "$secure_root/Applications", "owner": "$OWNER", "mode": "40755" }
  ],
  "database": {
    "path": "$DB",
    "schemaVersion": 8,
    "paused": 1,
    "queuedJobs": 3,
    "blockedJobs": 2,
    "runningPiJobs": 1,
    "totalJobs": 6
  },
  "herdr": {
    "linkPath": "$FIXTURE/herdr-bin/herdr",
    "resolvedPath": "$HERDR_RESOLVED",
    "executableSHA256": "$HERDR_SHA",
    "version": "0.8.2",
    "protocolVersion": 20
  },
  "git": {
    "path": "$FIXTURE/git",
    "sha256": "$GIT_SHA",
    "backendPath": "$FIXTURE/git-http-backend",
    "backendSHA256": "$GIT_BACKEND_SHA"
  }
}
EOF
}

readonly SECURE_ROOT="$FIXTURE/parents/Library/Application Support/JidokaProbe"
readonly EXPECTED_JSON="$TEST_ROOT/expected.json"
write_expected "$EXPECTED_JSON" "production" "$SECURE_ROOT"

# Snapshots the whole test tree, not just the fixture: the preflight must also leave
# its own inputs (expected.json, cutover values, frozen package) untouched. Excluded:
# the evidence root (the only authorized write target), the harness's own capture
# files, and transient SQLite -shm coordination files (their bytes may change on a
# read-only WAL open; the preflight's byte guard excludes them for the same reason).
snapshot_fixture() {
    (
        cd "$TEST_ROOT"
        /usr/bin/find . -mindepth 1 \( -path ./evidence \) -prune -o \
            \( ! -name "last-stdout" ! -name "last-stderr" ! -name "*-shm" \) -print0 \
            | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/stat -f '%N %Lp %z'
        /usr/bin/find . -mindepth 1 \( -path ./evidence \) -prune -o \
            -type f \( ! -name "last-stdout" ! -name "last-stderr" ! -name "*-shm" \) -print0 \
            | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256
    )
}

# Copies the baseline expected-values artifact and applies plutil replacements given
# as (keypath, type, value) triplets.
make_variant() {
    local out="$1"
    shift
    /bin/cp "$EXPECTED_JSON" "$out"
    while [[ $# -gt 0 ]]; do
        /usr/bin/plutil -replace "$1" "-$2" "$3" "$out"
        shift 3
    done
}

# --- Static stage: pass, read-only, private evidence ------------------------

BEFORE="$(snapshot_fixture)"
rc="$(run_preflight --stage static --expected "$EXPECTED_JSON" --evidence-dir "$EVIDENCE_ROOT/static")"
expect_rc 0 "$rc" "static pass"
AFTER="$(snapshot_fixture)"
[[ "$BEFORE" == "$AFTER" ]] || fail "static preflight mutated the fixture tree"
[[ "$(/usr/bin/stat -f '%p' "$EVIDENCE_ROOT/static")" == "40700" ]] || fail "evidence dir is not 0700"
EVIDENCE_LOG="$(/bin/ls "$EVIDENCE_ROOT/static"/preflight-static-*.log)"
[[ "$(/usr/bin/stat -f '%p' "$EVIDENCE_LOG")" == "100600" ]] || fail "evidence log is not 0600"
grep -q "RESULT PASS stage=static" "$EVIDENCE_LOG" || fail "evidence log misses the pass line"
grep -q "CHECK database.queuedJobs PASS value=3" "$EVIDENCE_LOG" || fail "evidence log misses the queue check"

# --- Quiesced gate on an idle fixture ---------------------------------------

rc="$(run_preflight --stage cutover-pre --expected "$EXPECTED_JSON" --evidence-dir "$EVIDENCE_ROOT/quiesced" --require-quiesced)"
expect_rc 0 "$rc" "cutover-pre quiesced pass"

# --- Closed error codes -----------------------------------------------------

rc="$(run_preflight)"
expect_rc 64 "$rc" "no arguments"
rc="$(run_preflight --stage bogus --expected "$EXPECTED_JSON" --evidence-dir "$EVIDENCE_ROOT/x1")"
expect_rc 64 "$rc" "unknown stage"
rc="$(run_preflight --stage static --expected relative.json --evidence-dir "$EVIDENCE_ROOT/x2")"
expect_rc 64 "$rc" "relative expected path"
rc="$(run_preflight --stage cutover-post-install --expected "$EXPECTED_JSON" --evidence-dir "$EVIDENCE_ROOT/x3")"
expect_rc 64 "$rc" "post-install without cutover values"
rc="$(run_preflight --stage static --expected "$EXPECTED_JSON" --evidence-dir "/Library/Application Support/JidokaCode/evidence")"
expect_rc 64 "$rc" "evidence dir inside production secure root"

/bin/ln -s "$FIXTURE" "$TEST_ROOT/evidence-link"
rc="$(run_preflight --stage static --expected "$EXPECTED_JSON" \
    --evidence-dir "$TEST_ROOT/evidence-link/escaped-leaf")"
expect_rc 64 "$rc" "symlinked evidence parent"
[[ ! -e "$FIXTURE/escaped-leaf" && ! -L "$FIXTURE/escaped-leaf" ]] || \
    fail "preflight created evidence through a symlink before containment validation"
/bin/rm "$TEST_ROOT/evidence-link"

rc="$(run_preflight --stage static --expected "$TEST_ROOT/missing.json" --evidence-dir "$EVIDENCE_ROOT/x4")"
expect_rc 65 "$rc" "missing expected artifact"

readonly TRUNCATED_JSON="$TEST_ROOT/truncated.json"
/usr/bin/plutil -remove database.queuedJobs -o "$TRUNCATED_JSON" "$EXPECTED_JSON"
rc="$(run_preflight --stage static --expected "$TRUNCATED_JSON" --evidence-dir "$EVIDENCE_ROOT/x5")"
expect_rc 65 "$rc" "missing expected key"

readonly DRIFTED_JSON="$TEST_ROOT/drifted.json"
/usr/bin/plutil -replace database.queuedJobs -integer 99 -o "$DRIFTED_JSON" "$EXPECTED_JSON"
rc="$(run_preflight --stage static --expected "$DRIFTED_JSON" --evidence-dir "$EVIDENCE_ROOT/x6")"
expect_rc 67 "$rc" "queue-count drift"
grep -q "CHECK database.queuedJobs FAIL expected=99 observed=3" \
    "$EVIDENCE_ROOT/x6"/preflight-static-*.log || fail "drift evidence line missing"

# --- UAT probe containment --------------------------------------------------

readonly UAT_BAD_JSON="$TEST_ROOT/uat-bad.json"
write_expected "$UAT_BAD_JSON" "uat-probe" "$SECURE_ROOT"
/usr/bin/plutil -replace package.identifier -string "com.maroffo.JidokaCode.pkg" "$UAT_BAD_JSON"
rc="$(run_preflight --stage static --expected "$UAT_BAD_JSON" --evidence-dir "$EVIDENCE_ROOT/x7")"
expect_rc 65 "$rc" "uat-probe artifact naming production package identifier"

readonly UAT_JSON="$TEST_ROOT/uat.json"
write_expected "$UAT_JSON" "uat-probe" "$SECURE_ROOT"
/usr/bin/plutil -remove database "$UAT_JSON"
rc="$(run_preflight --stage static --expected "$UAT_JSON" --evidence-dir "$EVIDENCE_ROOT/x8")"
expect_rc 0 "$rc" "uat-probe static pass without database section"

readonly UAT_NEAR_PREFIX_JSON="$TEST_ROOT/uat-near-prefix.json"
/bin/cp "$UAT_JSON" "$UAT_NEAR_PREFIX_JSON"
readonly UAT_NEAR_PREFIX_ROOT="/Library/Application Support/JidokaCode-location-probe-test-$$"
/usr/bin/plutil -replace bundle.secureRoot -string "$UAT_NEAR_PREFIX_ROOT" "$UAT_NEAR_PREFIX_JSON"
/usr/bin/plutil -replace bundle.securePath -string \
    "$UAT_NEAR_PREFIX_ROOT/Applications/Probe.app" "$UAT_NEAR_PREFIX_JSON"
rc="$(run_preflight --stage static --expected "$UAT_NEAR_PREFIX_JSON" --evidence-dir "$EVIDENCE_ROOT/x8-near")"
expect_rc 0 "$rc" "uat-probe accepts a sibling whose name shares only a lexical prefix"

readonly UAT_PRODUCTION_CHILD_JSON="$TEST_ROOT/uat-production-child.json"
/bin/cp "$UAT_JSON" "$UAT_PRODUCTION_CHILD_JSON"
/usr/bin/plutil -replace bundle.secureRoot -string \
    "/Library/Application Support/JidokaCode/LocationProbe" "$UAT_PRODUCTION_CHILD_JSON"
/usr/bin/plutil -replace bundle.securePath -string \
    "/Library/Application Support/JidokaCode/LocationProbe/Applications/Probe.app" \
    "$UAT_PRODUCTION_CHILD_JSON"
rc="$(run_preflight --stage static --expected "$UAT_PRODUCTION_CHILD_JSON" --evidence-dir "$EVIDENCE_ROOT/x8-child")"
expect_rc 65 "$rc" "uat-probe rejects a production secure-root descendant"

readonly UAT_CLEAN_JSON="$TEST_ROOT/uat-clean.json"
/bin/cp "$UAT_JSON" "$UAT_CLEAN_JSON"
/usr/bin/plutil -replace package.staticReceiptState -string absent "$UAT_CLEAN_JSON"
/usr/bin/plutil -replace bundle.legacyAppPostInstallState -string absent "$UAT_CLEAN_JSON"
/bin/mv "$FIXTURE/vol/var/db/receipts/$PROBE_PACKAGE_ID.plist" "$TEST_ROOT/held-receipt.plist"
/bin/mv "$FIXTURE/Applications/Probe.app" "$TEST_ROOT/held-legacy-app"
rc="$(run_preflight --stage static --expected "$UAT_CLEAN_JSON" --evidence-dir "$EVIDENCE_ROOT/x8-clean")"
expect_rc 0 "$rc" "uat-probe clean-install static pass without receipt or legacy app"
printf 'malformed-receipt\n' >"$FIXTURE/vol/var/db/receipts/$PROBE_PACKAGE_ID.plist"
rc="$(run_preflight --stage static --expected "$UAT_CLEAN_JSON" --evidence-dir "$EVIDENCE_ROOT/x8-stale-receipt")"
expect_rc 67 "$rc" "uat-probe clean-install rejects a malformed stale receipt"
/bin/rm "$FIXTURE/vol/var/db/receipts/$PROBE_PACKAGE_ID.plist"
/bin/ln -s /dev/null "$FIXTURE/vol/var/db/receipts/$PROBE_PACKAGE_ID.plist"
rc="$(run_preflight --stage static --expected "$UAT_CLEAN_JSON" --evidence-dir "$EVIDENCE_ROOT/x8-symlink-receipt")"
expect_rc 67 "$rc" "uat-probe clean-install rejects a symlinked stale receipt"
/bin/rm "$FIXTURE/vol/var/db/receipts/$PROBE_PACKAGE_ID.plist"
/bin/mv "$TEST_ROOT/held-receipt.plist" "$FIXTURE/vol/var/db/receipts/$PROBE_PACKAGE_ID.plist"
/bin/mv "$TEST_ROOT/held-legacy-app" "$FIXTURE/Applications/Probe.app"

readonly UAT_BAD_STATE_JSON="$TEST_ROOT/uat-bad-state.json"
make_variant "$UAT_BAD_STATE_JSON" package.staticReceiptState string unexpected
rc="$(run_preflight --stage static --expected "$UAT_BAD_STATE_JSON" --evidence-dir "$EVIDENCE_ROOT/x8-state")"
expect_rc 65 "$rc" "invalid static receipt state"

# --- Exit 66: one negative per prerequisite family --------------------------

readonly V66_HERDR="$TEST_ROOT/v66-herdr.json"
make_variant "$V66_HERDR" herdr.linkPath string "$FIXTURE/no-such-herdr"
rc="$(run_preflight --stage static --expected "$V66_HERDR" --evidence-dir "$EVIDENCE_ROOT/x66a")"
expect_rc 66 "$rc" "missing herdr link"

readonly V66_GIT="$TEST_ROOT/v66-git.json"
make_variant "$V66_GIT" git.path string "$FIXTURE/no-such-git"
rc="$(run_preflight --stage static --expected "$V66_GIT" --evidence-dir "$EVIDENCE_ROOT/x66b")"
expect_rc 66 "$rc" "missing git"

readonly V66_DB="$TEST_ROOT/v66-db.json"
make_variant "$V66_DB" database.path string "$FIXTURE/no-such-db.sqlite3"
rc="$(run_preflight --stage static --expected "$V66_DB" --evidence-dir "$EVIDENCE_ROOT/x66c")"
expect_rc 66 "$rc" "missing database"

readonly V66_PKG="$TEST_ROOT/v66-pkg.json"
make_variant "$V66_PKG" package.legacyPackagePath string "$FIXTURE/no-such.pkg"
rc="$(run_preflight --stage static --expected "$V66_PKG" --evidence-dir "$EVIDENCE_ROOT/x66d")"
expect_rc 66 "$rc" "missing legacy package"

# --- Quiesce gate: failing direction ----------------------------------------

/usr/bin/tail -f "$DB" >/dev/null 2>&1 &
TAIL_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    /usr/sbin/lsof -Fp "$DB" 2>/dev/null | grep -q "^p" && break
    /bin/sleep 0.2
done
rc="$(run_preflight --stage cutover-pre --expected "$EXPECTED_JSON" --evidence-dir "$EVIDENCE_ROOT/xq" --require-quiesced)"
kill "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true
expect_rc 67 "$rc" "quiesce gate with a live database opener"
grep -q "CHECK quiesced.databaseOpeners FAIL" "$EVIDENCE_ROOT/xq"/preflight-cutover-pre-*.log \
    || fail "quiesce drift evidence line missing"

# --- Parent-authority and destination negatives ------------------------------

mkdir -p "$FIXTURE/parents-alt"
ln -s "$FIXTURE/parents/Library" "$FIXTURE/parents-alt/Library-link"
readonly V67_SYMLINK="$TEST_ROOT/v67-symlink.json"
make_variant "$V67_SYMLINK" preInstallParents.0.path string "$FIXTURE/parents-alt/Library-link"
rc="$(run_preflight --stage static --expected "$V67_SYMLINK" --evidence-dir "$EVIDENCE_ROOT/x67a")"
expect_rc 67 "$rc" "symlinked parent directory"

mkdir -p "$FIXTURE/parents-mode"
chmod 775 "$FIXTURE/parents-mode"
readonly V67_MODE="$TEST_ROOT/v67-mode.json"
make_variant "$V67_MODE" preInstallParents.0.path string "$FIXTURE/parents-mode"
rc="$(run_preflight --stage static --expected "$V67_MODE" --evidence-dir "$EVIDENCE_ROOT/x67b")"
expect_rc 67 "$rc" "parent mode drift"

mkdir -p "$FIXTURE/parents-acl"
chmod 755 "$FIXTURE/parents-acl"
/bin/chmod +a "everyone deny delete" "$FIXTURE/parents-acl"
readonly V67_ACL="$TEST_ROOT/v67-acl.json"
make_variant "$V67_ACL" preInstallParents.0.path string "$FIXTURE/parents-acl"
rc="$(run_preflight --stage static --expected "$V67_ACL" --evidence-dir "$EVIDENCE_ROOT/x67c")"
expect_rc 67 "$rc" "parent carrying an ACL entry"
/bin/chmod -a "everyone deny delete" "$FIXTURE/parents-acl"

readonly V67_ROOT="$TEST_ROOT/v67-secure-root.json"
make_variant "$V67_ROOT" bundle.secureRoot string "$FIXTURE/parents/Library"
rc="$(run_preflight --stage static --expected "$V67_ROOT" --evidence-dir "$EVIDENCE_ROOT/x67d")"
expect_rc 67 "$rc" "secure root already present"

# --- Exit 68: timeout through the script ------------------------------------

/usr/bin/mkfifo "$FIXTURE/fifo-herdr"
readonly V68_FIFO="$TEST_ROOT/v68-fifo.json"
make_variant "$V68_FIFO" \
    herdr.linkPath string "$FIXTURE/fifo-herdr" \
    herdr.resolvedPath string "$FIXTURE/fifo-herdr" \
    toolTimeoutSeconds integer 1
rc="$(run_preflight --stage static --expected "$V68_FIFO" --evidence-dir "$EVIDENCE_ROOT/x68")"
expect_rc 68 "$rc" "tool timeout on an unreadable herdr executable"

# --- WAL-mode database: read-only audit leaves bytes untouched ---------------

mkdir -p "$FIXTURE/wal"
/usr/bin/sqlite3 "$FIXTURE/wal/jidoka-code.sqlite3" >/dev/null <<'EOF'
PRAGMA journal_mode=WAL;
CREATE TABLE schema_migrations (version INTEGER NOT NULL);
INSERT INTO schema_migrations (version) VALUES (1),(2),(3),(4),(5),(6),(7),(8);
CREATE TABLE app_settings (singleton INTEGER PRIMARY KEY, paused INTEGER NOT NULL);
INSERT INTO app_settings (singleton, paused) VALUES (1, 1);
CREATE TABLE jobs (state TEXT NOT NULL);
INSERT INTO jobs (state) VALUES
  ('queued'),('queued'),('queued'),('blocked'),('blocked'),('runningPi');
EOF
readonly V_WAL="$TEST_ROOT/v-wal.json"
make_variant "$V_WAL" database.path string "$FIXTURE/wal/jidoka-code.sqlite3"
BEFORE="$(snapshot_fixture)"
rc="$(run_preflight --stage static --expected "$V_WAL" --evidence-dir "$EVIDENCE_ROOT/xwal")"
expect_rc 0 "$rc" "static pass against a WAL-mode database"
AFTER="$(snapshot_fixture)"
[[ "$BEFORE" == "$AFTER" ]] || fail "WAL-mode audit mutated the tree (outside -shm)"

# --- uat-probe mode rejects --require-quiesced -------------------------------

rc="$(run_preflight --stage static --expected "$UAT_JSON" --evidence-dir "$EVIDENCE_ROOT/xuq" --require-quiesced)"
expect_rc 64 "$rc" "require-quiesced combined with uat-probe mode"

# --- Post-install stage -----------------------------------------------------

# The rehearsed cutover removes the quiesced, archived legacy app before installing
# the successor. Post-install acceptance therefore requires a single bundle path.
readonly POSTINSTALL_LEGACY_APP="$TEST_ROOT/postinstall-legacy-app"
/bin/mv "$FIXTURE/Applications/Probe.app" "$POSTINSTALL_LEGACY_APP"
write_receipt "0.1.1" "Library/Application Support"
readonly INSTALLED_APP="$SECURE_ROOT/Applications/Probe.app"
readonly INSTALLED_MAIN="$INSTALLED_APP/Contents/MacOS/$PROBE_MAIN_EXECUTABLE"
readonly INSTALLED_HELPER="$INSTALLED_APP/Contents/Helpers/$PROBE_HELPER_EXECUTABLE"
readonly INSTALLED_AGENT="$INSTALLED_APP/Contents/Library/LaunchAgents/$PROBE_LAUNCH_PLIST"
mkdir -p "$INSTALLED_APP/Contents/MacOS" "$INSTALLED_APP/Contents/Helpers" \
    "$INSTALLED_APP/Contents/Library/LaunchAgents"
chmod 755 "$SECURE_ROOT" "$SECURE_ROOT/Applications" "$INSTALLED_APP" \
    "$INSTALLED_APP/Contents" "$INSTALLED_APP/Contents/MacOS" \
    "$INSTALLED_APP/Contents/Helpers" "$INSTALLED_APP/Contents/Library" \
    "$INSTALLED_APP/Contents/Library/LaunchAgents"
/bin/cp /usr/bin/true "$INSTALLED_MAIN"
/bin/cp /usr/bin/true "$INSTALLED_HELPER"
chmod 755 "$INSTALLED_MAIN" "$INSTALLED_HELPER"
cat > "$INSTALLED_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$PROBE_MAIN_EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>$PROBE_BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundleVersion</key><string>2</string>
</dict>
</plist>
EOF
cat >"$INSTALLED_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$PROBE_HELPER_ID</string>
  <key>BundleProgram</key><string>Contents/Helpers/$PROBE_HELPER_EXECUTABLE</string>
  <key>ProgramArguments</key><array><string>$PROBE_HELPER_EXECUTABLE</string><string>--service</string></array>
  <key>MachServices</key><dict><key>$PROBE_HELPER_ID</key><true/></dict>
</dict></plist>
EOF
chmod 644 "$INSTALLED_APP/Contents/Info.plist" "$INSTALLED_AGENT"
/usr/bin/codesign --force --sign - --identifier "$PROBE_HELPER_ID" "$INSTALLED_HELPER"
/usr/bin/codesign --force --sign - --identifier "$PROBE_BUNDLE_ID" "$INSTALLED_MAIN"
/usr/bin/codesign --force --sign - --identifier "$PROBE_BUNDLE_ID" "$INSTALLED_APP"

printf 'frozen-package-bytes\n' > "$TEST_ROOT/frozen.pkg"
FROZEN_SHA="$(/usr/bin/shasum -a 256 "$TEST_ROOT/frozen.pkg" | /usr/bin/awk '{print $1}')"
readonly FROZEN_SHA
cat > "$TEST_ROOT/package-manifest.json" <<EOF
{
  "packageIdentifier": "$PROBE_PACKAGE_ID",
  "installLocation": "$SECURE_ROOT/Applications/Probe.app",
  "appVersion": "0.1.1"
}
EOF
MANIFEST_SHA="$(/usr/bin/shasum -a 256 "$TEST_ROOT/package-manifest.json" | /usr/bin/awk '{print $1}')"
readonly MANIFEST_SHA
readonly CUTOVER_VALUES="$TEST_ROOT/cutover-values.env"
cat > "$CUTOVER_VALUES" <<EOF
# generated at W6; consumed read-only by the preflight
package_path=$TEST_ROOT/frozen.pkg
package_sha256=$FROZEN_SHA
package_manifest_path=$TEST_ROOT/package-manifest.json
package_manifest_sha256=$MANIFEST_SHA
EOF
chmod 600 "$CUTOVER_VALUES"

BEFORE="$(snapshot_fixture)"
rc="$(run_preflight --stage cutover-post-install --expected "$EXPECTED_JSON" \
    --evidence-dir "$EVIDENCE_ROOT/post" --cutover-values "$CUTOVER_VALUES")"
expect_rc 0 "$rc" "post-install pass"
AFTER="$(snapshot_fixture)"
[[ "$BEFORE" == "$AFTER" ]] || fail "post-install preflight mutated the fixture tree"

/bin/mv "$POSTINSTALL_LEGACY_APP" "$FIXTURE/Applications/Probe.app"
rc="$(run_preflight --stage cutover-post-install --expected "$EXPECTED_JSON" \
    --evidence-dir "$EVIDENCE_ROOT/post-legacy-duplicate" --cutover-values "$CUTOVER_VALUES")"
expect_rc 67 "$rc" "post-install rejects a remaining legacy duplicate"
/bin/mv "$FIXTURE/Applications/Probe.app" "$POSTINSTALL_LEGACY_APP"

readonly UAT_POST_JSON="$TEST_ROOT/uat-post.json"
/bin/cp "$UAT_JSON" "$UAT_POST_JSON"
rc="$(run_preflight --stage cutover-post-install --expected "$UAT_POST_JSON" \
    --evidence-dir "$EVIDENCE_ROOT/uat-post" --cutover-values "$CUTOVER_VALUES")"
expect_rc 0 "$rc" "uat-probe post-install signature and payload pass"

/bin/cp "$INSTALLED_HELPER" "$TEST_ROOT/helper.backup"
printf 'tamper\n' >>"$INSTALLED_HELPER"
rc="$(run_preflight --stage cutover-post-install --expected "$UAT_POST_JSON" \
    --evidence-dir "$EVIDENCE_ROOT/uat-signature-drift" --cutover-values "$CUTOVER_VALUES")"
expect_rc 67 "$rc" "uat-probe rejects an installed helper signature drift"
/bin/cp "$TEST_ROOT/helper.backup" "$INSTALLED_HELPER"
/usr/bin/codesign --force --sign - --identifier "$PROBE_HELPER_ID" "$INSTALLED_HELPER"
/usr/bin/codesign --force --sign - --identifier "$PROBE_BUNDLE_ID" "$INSTALLED_APP"

/bin/ln "$INSTALLED_APP/Contents/Info.plist" "$TEST_ROOT/info-hardlink"
rc="$(run_preflight --stage cutover-post-install --expected "$UAT_POST_JSON" \
    --evidence-dir "$EVIDENCE_ROOT/uat-hardlink-drift" --cutover-values "$CUTOVER_VALUES")"
expect_rc 67 "$rc" "uat-probe rejects an installed hard-linked payload file"
/bin/rm "$TEST_ROOT/info-hardlink"

/bin/chmod +a "everyone allow read" "$INSTALLED_APP/Contents/Info.plist"
rc="$(run_preflight --stage cutover-post-install --expected "$UAT_POST_JSON" \
    --evidence-dir "$EVIDENCE_ROOT/uat-acl-drift" --cutover-values "$CUTOVER_VALUES")"
expect_rc 67 "$rc" "uat-probe rejects an installed payload allow ACL"
/bin/chmod -a "everyone allow read" "$INSTALLED_APP/Contents/Info.plist"

printf 'tampered\n' >> "$TEST_ROOT/frozen.pkg"
rc="$(run_preflight --stage cutover-post-install --expected "$EXPECTED_JSON" \
    --evidence-dir "$EVIDENCE_ROOT/post-drift" --cutover-values "$CUTOVER_VALUES")"
expect_rc 67 "$rc" "tampered frozen package"
printf 'frozen-package-bytes\n' > "$TEST_ROOT/frozen.pkg"

readonly PLACEHOLDER_VALUES="$TEST_ROOT/cutover-placeholder.env"
cat > "$PLACEHOLDER_VALUES" <<EOF
package_path=$TEST_ROOT/frozen.pkg
package_sha256=PLACEHOLDER
package_manifest_path=$TEST_ROOT/package-manifest.json
package_manifest_sha256=$MANIFEST_SHA
EOF
chmod 600 "$PLACEHOLDER_VALUES"
rc="$(run_preflight --stage cutover-post-install --expected "$EXPECTED_JSON" \
    --evidence-dir "$EVIDENCE_ROOT/post-ph" --cutover-values "$PLACEHOLDER_VALUES")"
expect_rc 65 "$rc" "placeholder cutover value"

chmod 644 "$CUTOVER_VALUES"
rc="$(run_preflight --stage cutover-post-install --expected "$EXPECTED_JSON" \
    --evidence-dir "$EVIDENCE_ROOT/post-mode" --cutover-values "$CUTOVER_VALUES")"
expect_rc 67 "$rc" "cutover values file mode not 0600"
chmod 600 "$CUTOVER_VALUES"

printf 'test-production-readiness-preflight passed\n'
