#!/usr/bin/env bash
# ABOUTME: Deterministic tests for the read-only progressive rollout preflight.
# ABOUTME: Uses only source and temporary local fixtures, with no credential or network access.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly PREFLIGHT="$ROOT/scripts/progressive-production-rollout-preflight.sh"
readonly RELEASE_MANIFEST_GENERATOR="$ROOT/scripts/generate-progressive-production-release.mjs"
readonly EXPECTED="$ROOT/docs/operations/progressive-production-rollout-expected.json"
readonly RUNTIME_ROOT="${JIDOKA_RELEASE_RUNTIME_ROOT:-}"
readonly NODE="$RUNTIME_ROOT/node/bin/node"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jidoka-rollout-preflight.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
readonly TEST_ROOT
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'test-progressive-production-rollout-preflight failed: %s\n' "$1" >&2
    exit 1
}

[[ "$RUNTIME_ROOT" == /* && -x "$NODE" ]] || \
    fail "JIDOKA_RELEASE_RUNTIME_ROOT must name the qualified runtime"
[[ -x "$PREFLIGHT" && -f "$RELEASE_MANIFEST_GENERATOR" && -f "$EXPECTED" ]] || \
    fail "preflight inputs are unavailable"

if /usr/bin/grep -Eq \
    '(/usr/bin/security|/usr/bin/git|/usr/bin/curl|/usr/bin/ssh|/usr/bin/osascript|/usr/bin/launchctl|/bin/kill|/usr/bin/pkill)' \
    "$PREFLIGHT"
then
    fail "preflight references a credential, network, or process mutation tool"
fi
if /usr/bin/grep -Eiq \
    '(^|[[:space:];])(INSERT|UPDATE|DELETE|REPLACE|VACUUM|ATTACH|DETACH|REINDEX)([[:space:];]|$)' \
    "$PREFLIGHT"
then
    fail "preflight contains mutating SQL"
fi

run_preflight() {
    local rc=0
    (
        cd /
        /usr/bin/env -i \
            JIDOKA_RELEASE_RUNTIME_ROOT="$RUNTIME_ROOT" \
            /bin/bash "$PREFLIGHT" "$@"
    ) >"$TEST_ROOT/last-stdout" 2>"$TEST_ROOT/last-stderr" || rc=$?
    printf '%s' "$rc"
}

expect_rc() {
    local expected="$1"
    local observed="$2"
    local label="$3"
    if [[ "$observed" != "$expected" ]]; then
        /bin/cat "$TEST_ROOT/last-stderr" >&2 || true
        fail "$label: expected exit $expected, observed $observed"
    fi
}

source_before="$({
    /usr/bin/shasum -a 256 "$EXPECTED" "$PREFLIGHT" "$RELEASE_MANIFEST_GENERATOR"
    /usr/bin/shasum -a 256 "$ROOT/Packaging/Info.plist"
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
readonly source_before
rc="$(run_preflight \
    --stage static \
    --source-root "$ROOT" \
    --expected "$EXPECTED")"
expect_rc 0 "$rc" "static preflight"
/usr/bin/grep -Fq \
    'PASS stage=static credentialReads=0 providerCalls=0 githubMutations=0 gitRemoteReads=0' \
    "$TEST_ROOT/last-stdout" || fail "static preflight did not report closed counters"
source_after="$({
    /usr/bin/shasum -a 256 "$EXPECTED" "$PREFLIGHT" "$RELEASE_MANIFEST_GENERATOR"
    /usr/bin/shasum -a 256 "$ROOT/Packaging/Info.plist"
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
readonly source_after
[[ "$source_after" == "$source_before" ]] || fail "static preflight changed source inputs"

readonly PATH_FAILURE_RUNTIME="$TEST_ROOT/path-failure-runtime"
/bin/mkdir -p "$PATH_FAILURE_RUNTIME/node/bin"
{
    printf '%s\n' '#!/bin/bash'
    # Expansion belongs to the generated validator.
    # shellcheck disable=SC2016
    printf '%s\n' 'if [[ "${!#}" == "--paths" ]]; then exit 91; fi'
    printf 'exec %q "$@"\n' "$NODE"
} >"$PATH_FAILURE_RUNTIME/node/bin/node"
/bin/chmod 0755 "$PATH_FAILURE_RUNTIME/node/bin/node"
rc=0
(
    cd /
    /usr/bin/env -i \
        JIDOKA_RELEASE_RUNTIME_ROOT="$PATH_FAILURE_RUNTIME" \
        /bin/bash "$PREFLIGHT" \
        --stage static \
        --source-root "$ROOT" \
        --expected "$EXPECTED"
) >"$TEST_ROOT/path-failure-stdout" 2>"$TEST_ROOT/path-failure-stderr" || rc=$?
expect_rc 65 "$rc" "required-path validator failure"
/usr/bin/grep -Fq 'expected-release path validation failed' \
    "$TEST_ROOT/path-failure-stderr" || fail "required-path failure was not preserved"

manifest="$("$NODE" "$RELEASE_MANIFEST_GENERATOR" \
    "$(printf '1%.0s' {1..40})" \
    "$(printf '2%.0s' {1..40})" \
    "0.2.0" \
    "4" \
    "$(printf 'b%.0s' {1..64})" \
    "$(printf 'c%.0s' {1..64})" \
    "$(printf 'd%.0s' {1..64})" \
    "$(printf 'e%.0s' {1..64})" \
    "10" \
    "12" \
    "$(printf 'f%.0s' {1..64})" \
    "$(printf '6%.0s' {1..64})" \
    "$(printf '7%.0s' {1..64})")"
readonly manifest
expected_manifest="{\"askPassSHA256\":\"$(printf 'c%.0s' {1..64})\",\"bundleBuild\":4,\"bundleVersion\":\"0.2.0\",\"databaseSchemaVersion\":10,\"engineProtocolVersion\":12,\"helperSHA256\":\"$(printf 'b%.0s' {1..64})\",\"herdrHostSHA256\":\"$(printf 'e%.0s' {1..64})\",\"manifestSchemaVersion\":2,\"pushGuardSHA256\":\"$(printf 'd%.0s' {1..64})\",\"runtimeManifestSHA256\":\"$(printf 'f%.0s' {1..64})\",\"runtimeTreeSHA256\":\"$(printf '6%.0s' {1..64})\",\"sourceCommit\":\"$(printf '1%.0s' {1..40})\",\"sourceTree\":\"$(printf '2%.0s' {1..40})\",\"workflowResourcesSHA256\":\"$(printf '7%.0s' {1..64})\"}"
readonly expected_manifest
[[ "$manifest" == "$expected_manifest" ]] || fail "release manifest is not canonical"
if "$NODE" "$RELEASE_MANIFEST_GENERATOR" \
    malformed malformed 0.2.0 4 x x x x 10 12 x x x >/dev/null 2>&1
then
    fail "release manifest generator accepted malformed identities"
fi

readonly APP="$TEST_ROOT/Jidoka Code.app"
readonly DATABASE="$TEST_ROOT/jidoka-code.sqlite3"
/bin/mkdir -p "$APP/Contents"
/bin/cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/sqlite3 "$DATABASE" <<'SQL'
CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY);
INSERT INTO schema_migrations(version) VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10);
CREATE TABLE app_settings(
  singleton INTEGER PRIMARY KEY,
  paused INTEGER NOT NULL,
  active_rollout_authorization_id TEXT
);
INSERT INTO app_settings VALUES (1, 1, NULL);
CREATE TABLE pi_runs(id TEXT PRIMARY KEY);
INSERT INTO pi_runs VALUES ('historical-run');
CREATE TABLE mutation_intents(id TEXT PRIMARY KEY);
INSERT INTO mutation_intents VALUES ('historical-intent');
CREATE TABLE rollout_authorizations(id TEXT PRIMARY KEY, state TEXT NOT NULL);
INSERT INTO rollout_authorizations VALUES ('historical-settled', 'settled');
CREATE TABLE rollout_effect_reservations(
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL
);
INSERT INTO rollout_effect_reservations VALUES ('historical-read', 'githubRead');
SQL
/bin/chmod 0600 "$DATABASE"

fixture_before="$({
    /usr/bin/shasum -a 256 "$DATABASE" "$APP/Contents/Info.plist"
    /usr/bin/stat -f '%N:%z:%m:%OLp:%l' "$DATABASE" "$APP/Contents/Info.plist"
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
readonly fixture_before
rc="$(run_preflight \
    --stage installed \
    --source-root "$ROOT" \
    --expected "$EXPECTED" \
    --application "$APP" \
    --database "$DATABASE")"
expect_rc 0 "$rc" "installed preflight"
/usr/bin/grep -Fq \
    'PASS stage=installed credentialReads=0 providerCalls=0 githubMutations=0 gitRemoteReads=0' \
    "$TEST_ROOT/last-stdout" || fail "installed preflight did not report closed counters"
fixture_after="$({
    /usr/bin/shasum -a 256 "$DATABASE" "$APP/Contents/Info.plist"
    /usr/bin/stat -f '%N:%z:%m:%OLp:%l' "$DATABASE" "$APP/Contents/Info.plist"
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
readonly fixture_after
[[ "$fixture_after" == "$fixture_before" ]] || fail "installed preflight changed fixture bytes"
[[ ! -e "$DATABASE-wal" && ! -e "$DATABASE-shm" ]] || \
    fail "installed preflight created SQLite sidecars"

readonly DRIFTED_EXPECTED="$TEST_ROOT/drifted-expected.json"
/usr/bin/sed 's/"bundleVersion": "0.2.0"/"bundleVersion": "9.9.9"/' \
    "$EXPECTED" >"$DRIFTED_EXPECTED"
/bin/chmod 0600 "$DRIFTED_EXPECTED"
rc="$(run_preflight \
    --stage static \
    --source-root "$ROOT" \
    --expected "$DRIFTED_EXPECTED")"
expect_rc 65 "$rc" "drifted expected values"

/usr/bin/sqlite3 "$DATABASE" \
    "INSERT INTO rollout_authorizations VALUES ('unexpected-active', 'active');"
rc="$(run_preflight \
    --stage installed \
    --source-root "$ROOT" \
    --expected "$EXPECTED" \
    --application "$APP" \
    --database "$DATABASE")"
expect_rc 67 "$rc" "active rollout lane"

printf '%s\n' \
    'progressive-production-rollout-preflight tests: PASS credentialReads=0 providerCalls=0 githubMutations=0 gitRemoteReads=0'
