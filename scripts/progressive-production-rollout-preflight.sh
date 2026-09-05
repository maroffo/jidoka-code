#!/usr/bin/env bash
# ABOUTME: Read-only source and installed-state qualification for progressive rollout authority.
# ABOUTME: It never opens credentials, starts the engine/provider, or performs Git/GitHub I/O.
set -euo pipefail
umask 077

readonly TOOL_GREP="/usr/bin/grep"
readonly TOOL_PLUTIL="/usr/bin/plutil"
readonly TOOL_SHASUM="/usr/bin/shasum"
readonly TOOL_SQLITE="/usr/bin/sqlite3"
readonly TOOL_STAT="/usr/bin/stat"

STAGE=""
SOURCE_ROOT=""
EXPECTED=""
APPLICATION=""
DATABASE=""

fail() {
    local code="$1"
    shift
    printf 'progressive-production-rollout-preflight: FAIL exit=%s %s\n' "$code" "$*" >&2
    exit "$code"
}

usage() {
    fail 64 "usage: $0 --stage static|installed --source-root <absolute-path> --expected <absolute-json> [--application <absolute-app> --database <absolute-db>]"
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --stage)
            [[ "$#" -ge 2 ]] || usage
            STAGE="$2"
            shift 2
            ;;
        --source-root)
            [[ "$#" -ge 2 ]] || usage
            SOURCE_ROOT="$2"
            shift 2
            ;;
        --expected)
            [[ "$#" -ge 2 ]] || usage
            EXPECTED="$2"
            shift 2
            ;;
        --application)
            [[ "$#" -ge 2 ]] || usage
            APPLICATION="$2"
            shift 2
            ;;
        --database)
            [[ "$#" -ge 2 ]] || usage
            DATABASE="$2"
            shift 2
            ;;
        *) usage ;;
    esac
done

[[ "$STAGE" == "static" || "$STAGE" == "installed" ]] || usage
[[ "$SOURCE_ROOT" == /* && -d "$SOURCE_ROOT" && ! -L "$SOURCE_ROOT" ]] || \
    fail 65 "source root is not an absolute regular directory"
CANONICAL_SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)"
readonly CANONICAL_SOURCE_ROOT
[[ "$CANONICAL_SOURCE_ROOT" == "$SOURCE_ROOT" ]] || fail 65 "source root is not canonical"
[[ "$EXPECTED" == /* && -f "$EXPECTED" && ! -L "$EXPECTED" ]] || \
    fail 65 "expected-values file is unavailable"
[[ "$EXPECTED" != *$'\n'* && "$EXPECTED" != *$'\r'* ]] || \
    fail 65 "expected-values path contains a line break"
EXPECTED_PARENT="$(cd "$(/usr/bin/dirname "$EXPECTED")" && pwd -P)"
readonly EXPECTED_PARENT
[[ "$EXPECTED_PARENT/$(/usr/bin/basename "$EXPECTED")" == "$EXPECTED" ]] || \
    fail 65 "expected-values path is not canonical"
[[ "$($TOOL_STAT -f '%z' "$EXPECTED")" -le 65536 && \
    "$(( 8#$($TOOL_STAT -f '%OLp' "$EXPECTED") & 8#022 ))" == "0" ]] || \
    fail 65 "expected-values metadata is unsafe"

readonly EXPECTED_SCHEMA="$SOURCE_ROOT/docs/operations/progressive-production-rollout-expected.schema.json"
readonly VALIDATOR="$SOURCE_ROOT/scripts/tests/validate-progressive-rollout-expected.mjs"
[[ -f "$EXPECTED_SCHEMA" && ! -L "$EXPECTED_SCHEMA" && \
    -f "$VALIDATOR" && ! -L "$VALIDATOR" ]] || \
    fail 65 "expected-values schema or validator is unavailable"

readonly RUNTIME_ROOT="${JIDOKA_RELEASE_RUNTIME_ROOT:-}"
[[ "$RUNTIME_ROOT" == /* && -d "$RUNTIME_ROOT" && ! -L "$RUNTIME_ROOT" ]] || \
    fail 65 "JIDOKA_RELEASE_RUNTIME_ROOT must name the qualified runtime"
CANONICAL_RUNTIME_ROOT="$(cd "$RUNTIME_ROOT" && pwd -P)"
readonly CANONICAL_RUNTIME_ROOT
[[ "$CANONICAL_RUNTIME_ROOT" == "$RUNTIME_ROOT" ]] || \
    fail 65 "qualified runtime root is not canonical"
readonly NODE="$RUNTIME_ROOT/node/bin/node"
[[ -f "$NODE" && -x "$NODE" && ! -L "$NODE" ]] || \
    fail 65 "qualified runtime Node is unavailable"
"$NODE" "$VALIDATOR" "$EXPECTED" "$EXPECTED_SCHEMA" >/dev/null || exit $?

expected_raw() {
    "$TOOL_PLUTIL" -extract "$1" raw -o - "$EXPECTED"
}

EXPECTED_BUNDLE_VERSION="$(expected_raw release.bundleVersion)"
readonly EXPECTED_BUNDLE_VERSION
EXPECTED_BUNDLE_BUILD="$(expected_raw release.bundleBuild)"
readonly EXPECTED_BUNDLE_BUILD
EXPECTED_DATABASE_SCHEMA="$(expected_raw release.databaseSchemaVersion)"
readonly EXPECTED_DATABASE_SCHEMA
EXPECTED_ENGINE_PROTOCOL="$(expected_raw release.engineProtocolVersion)"
readonly EXPECTED_ENGINE_PROTOCOL
EXPECTED_MAX_CONCURRENCY="$(expected_raw release.maximumConcurrency)"
readonly EXPECTED_MAX_CONCURRENCY
EXPECTED_POLICY_VERSION="$(expected_raw release.rolloutPolicyVersion)"
readonly EXPECTED_POLICY_VERSION

REQUIRED_SOURCE_PATHS="$(
    "$NODE" "$VALIDATOR" "$EXPECTED" "$EXPECTED_SCHEMA" --paths
)" || fail 65 "expected-release path validation failed"
readonly REQUIRED_SOURCE_PATHS
while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || fail 65 "required source path is empty"
    candidate="$SOURCE_ROOT/$relative_path"
    [[ -f "$candidate" && ! -L "$candidate" ]] || \
        fail 66 "required source file is unavailable: $relative_path"
done <<<"$REQUIRED_SOURCE_PATHS"

readonly SOURCE_INFO="$SOURCE_ROOT/Packaging/Info.plist"
[[ "$("$TOOL_PLUTIL" -extract CFBundleShortVersionString raw "$SOURCE_INFO")" == \
    "$EXPECTED_BUNDLE_VERSION" ]] || fail 66 "source bundle version differs"
[[ "$("$TOOL_PLUTIL" -extract CFBundleVersion raw "$SOURCE_INFO")" == \
    "$EXPECTED_BUNDLE_BUILD" ]] || fail 66 "source bundle build differs"
"$TOOL_GREP" -Fq "public static let current = $EXPECTED_ENGINE_PROTOCOL" \
    "$SOURCE_ROOT/Sources/JidokaCodeCore/Application/EngineProtocol.swift" || \
    fail 66 "engine protocol differs"
"$TOOL_GREP" -Fq "version: $EXPECTED_DATABASE_SCHEMA," \
    "$SOURCE_ROOT/Sources/JidokaCodeCore/State/DatabaseSchema.swift" || \
    fail 66 "database schema migration differs"
"$TOOL_GREP" -Fq "case v$EXPECTED_POLICY_VERSION = $EXPECTED_POLICY_VERSION" \
    "$SOURCE_ROOT/Sources/JidokaCodeCore/State/RolloutAuthority.swift" || \
    fail 66 "rollout policy differs"
"$TOOL_GREP" -Fq "public var newRepositoryReviewEnabled = false" \
    "$SOURCE_ROOT/Sources/JidokaCodeAppSupport/SettingsViewModel.swift" || \
    fail 66 "new repository review default is not closed"
"$TOOL_GREP" -Fq "public var newRepositoryTriageEnabled = false" \
    "$SOURCE_ROOT/Sources/JidokaCodeAppSupport/SettingsViewModel.swift" || \
    fail 66 "new repository triage default is not closed"
"$TOOL_GREP" -Fq "public var newRepositoryImplementationEnabled = false" \
    "$SOURCE_ROOT/Sources/JidokaCodeAppSupport/SettingsViewModel.swift" || \
    fail 66 "new repository implementation default is not closed"
[[ "$EXPECTED_MAX_CONCURRENCY" == "1" ]] || fail 66 "rollout concurrency is not one"

for counter in credentialReads gitRemoteReads githubMutations providerCalls; do
    [[ "$(expected_raw "qualificationCounters.$counter")" == "0" ]] || \
        fail 65 "qualification counter expectation is not zero: $counter"
done

if [[ "$STAGE" == "static" ]]; then
    [[ -z "$APPLICATION" && -z "$DATABASE" ]] || usage
    printf '%s\n' \
        'progressive-production-rollout-preflight: PASS stage=static credentialReads=0 providerCalls=0 githubMutations=0 gitRemoteReads=0'
    exit 0
fi

[[ "$APPLICATION" == /* && -d "$APPLICATION" && ! -L "$APPLICATION" ]] || \
    fail 67 "installed application is unavailable"
CANONICAL_APPLICATION="$(cd "$APPLICATION" && pwd -P)"
readonly CANONICAL_APPLICATION
[[ "$CANONICAL_APPLICATION" == "$APPLICATION" ]] || fail 67 "application path is not canonical"
readonly INSTALLED_INFO="$APPLICATION/Contents/Info.plist"
[[ -f "$INSTALLED_INFO" && ! -L "$INSTALLED_INFO" ]] || \
    fail 67 "installed application Info.plist is unavailable"
[[ "$("$TOOL_PLUTIL" -extract CFBundleShortVersionString raw "$INSTALLED_INFO")" == \
    "$EXPECTED_BUNDLE_VERSION" ]] || fail 67 "installed bundle version differs"
[[ "$("$TOOL_PLUTIL" -extract CFBundleVersion raw "$INSTALLED_INFO")" == \
    "$EXPECTED_BUNDLE_BUILD" ]] || fail 67 "installed bundle build differs"

[[ "$DATABASE" == /* && -f "$DATABASE" && ! -L "$DATABASE" && \
    "$DATABASE" != *$'\n'* && "$DATABASE" != *$'\r'* ]] || \
    fail 67 "installed database is unavailable"
DATABASE_PARENT="$(cd "$(/usr/bin/dirname "$DATABASE")" && pwd -P)"
readonly DATABASE_PARENT
[[ "$DATABASE_PARENT/$(/usr/bin/basename "$DATABASE")" == "$DATABASE" ]] || \
    fail 67 "database path is not canonical"
[[ "$($TOOL_STAT -f '%l' "$DATABASE")" == "1" && \
    "$($TOOL_STAT -f '%OLp' "$DATABASE")" == "600" ]] || \
    fail 67 "database metadata is unsafe"
[[ ! -e "$DATABASE-wal" && ! -e "$DATABASE-shm" ]] || \
    fail 67 "database must be quiesced and checkpointed"

query_integer() {
    local sql="$1"
    local value
    value="$($TOOL_SQLITE -batch -noheader -readonly "file:$DATABASE?immutable=1" \
        "PRAGMA query_only=ON; $sql")" || fail 67 "database query failed"
    [[ "$value" =~ ^[0-9]+$ ]] || fail 67 "database query returned a non-integer"
    printf '%s' "$value"
}

database_fingerprint() {
    printf '%s:%s:%s' \
        "$($TOOL_SHASUM -a 256 "$DATABASE" | /usr/bin/awk '{print $1}')" \
        "$($TOOL_STAT -f '%z' "$DATABASE")" \
        "$($TOOL_STAT -f '%m' "$DATABASE")"
}

DATABASE_BEFORE="$(database_fingerprint)"
readonly DATABASE_BEFORE
PROVIDER_BEFORE="$(query_integer 'SELECT COUNT(*) FROM pi_runs;')"
readonly PROVIDER_BEFORE
MUTATION_BEFORE="$(query_integer 'SELECT COUNT(*) FROM mutation_intents;')"
readonly MUTATION_BEFORE
GIT_READ_BEFORE="$(query_integer "SELECT COUNT(*) FROM rollout_effect_reservations WHERE kind = 'gitRemoteRead';")"
readonly GIT_READ_BEFORE
OBSERVED_SCHEMA="$(query_integer 'SELECT COALESCE(MAX(version), 0) FROM schema_migrations;')"
readonly OBSERVED_SCHEMA
PAUSED="$(query_integer 'SELECT paused FROM app_settings WHERE singleton = 1;')"
readonly PAUSED
OPEN_LANES="$(query_integer "SELECT COUNT(*) FROM rollout_authorizations WHERE state IN ('active','draining','recoveryRequired');")"
readonly OPEN_LANES
ACTIVE_BINDINGS="$(query_integer "SELECT COUNT(*) FROM app_settings WHERE singleton = 1 AND active_rollout_authorization_id IS NOT NULL;")"
readonly ACTIVE_BINDINGS
[[ "$OBSERVED_SCHEMA" == "$EXPECTED_DATABASE_SCHEMA" ]] || fail 67 "installed schema differs"
[[ "$PAUSED" == "1" && "$OPEN_LANES" == "0" && "$ACTIVE_BINDINGS" == "0" ]] || \
    fail 67 "installed rollout state is not paused and closed"

PROVIDER_AFTER="$(query_integer 'SELECT COUNT(*) FROM pi_runs;')"
readonly PROVIDER_AFTER
MUTATION_AFTER="$(query_integer 'SELECT COUNT(*) FROM mutation_intents;')"
readonly MUTATION_AFTER
GIT_READ_AFTER="$(query_integer "SELECT COUNT(*) FROM rollout_effect_reservations WHERE kind = 'gitRemoteRead';")"
readonly GIT_READ_AFTER
DATABASE_AFTER="$(database_fingerprint)"
readonly DATABASE_AFTER
[[ "$PROVIDER_AFTER" == "$PROVIDER_BEFORE" && \
    "$MUTATION_AFTER" == "$MUTATION_BEFORE" && \
    "$GIT_READ_AFTER" == "$GIT_READ_BEFORE" && \
    "$DATABASE_AFTER" == "$DATABASE_BEFORE" ]] || \
    fail 67 "qualification changed durable state"

printf '%s\n' \
    'progressive-production-rollout-preflight: PASS stage=installed credentialReads=0 providerCalls=0 githubMutations=0 gitRemoteReads=0'
