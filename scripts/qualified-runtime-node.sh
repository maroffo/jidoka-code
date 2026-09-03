#!/bin/bash
set -euo pipefail

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly ROOT
BOUNDED_COMMAND_RUNNER=""
readonly REQUESTED_RUNTIME_ROOT="${JIDOKA_RELEASE_RUNTIME_ROOT:-$ROOT/build/runtime-input/qualified-runtime}"
readonly EXPECTED_RUNTIME_ID="node-26.7.0-pi-0.84.2-darwin-arm64-v1"
readonly EXPECTED_MANIFEST_SHA256="fe15573a58a4604a3695b092ba8b07ae2432da7b7f07743a8d54a4421ab3aa83"
TEMP_ROOT=""

fail() {
    printf 'qualified runtime unavailable: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" && \
        "$(/usr/bin/basename "$TEMP_ROOT")" == jidoka-qualified-runtime.* ]]; then
        /bin/rm -rf -- "$TEMP_ROOT"
    fi
}
trap cleanup EXIT

[[ "$REQUESTED_RUNTIME_ROOT" == /* && -d "$REQUESTED_RUNTIME_ROOT" && \
    ! -L "$REQUESTED_RUNTIME_ROOT" ]] || \
    fail "JIDOKA_RELEASE_RUNTIME_ROOT must name the qualified absolute runtime root"
RUNTIME_ROOT="$(cd "$REQUESTED_RUNTIME_ROOT" && pwd -P)"
readonly RUNTIME_ROOT
[[ "$RUNTIME_ROOT" == "$REQUESTED_RUNTIME_ROOT" ]] || fail "runtime root must be canonical"
case "$RUNTIME_ROOT" in
    "$ROOT"/*)
        case "$RUNTIME_ROOT" in
            "$ROOT/build/"*) ;;
            *) fail "checkout-local runtime root must be beneath ignored build/" ;;
        esac
        ;;
esac
TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-qualified-runtime.XXXXXX")"
TEMP_ROOT="$(cd "$TEMP_ROOT" && pwd -P)"
readonly TEMP_ROOT
/bin/mkdir -m 0700 "$TEMP_ROOT/home" "$TEMP_ROOT/tmp"
readonly SCRATCH_ROOT="$ROOT/.build/qualified-runtime-verifier"
/usr/bin/xcrun swift build \
    --scratch-path "$SCRATCH_ROOT" \
    --configuration release \
    -Xswiftc -DJIDOKA_ADHOC_RUNTIME_TESTING \
    --product JidokaCodeApp >&2
/usr/bin/xcrun swift build \
    --scratch-path "$SCRATCH_ROOT" \
    --configuration release \
    -Xswiftc -DJIDOKA_ADHOC_RUNTIME_TESTING \
    --product JidokaCodeBoundedCommand >&2
BIN_DIR="$(
    /usr/bin/xcrun swift build \
        --scratch-path "$SCRATCH_ROOT" \
        --configuration release \
        -Xswiftc -DJIDOKA_ADHOC_RUNTIME_TESTING \
        --show-bin-path
)"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
readonly BIN_DIR
readonly VERIFIER="$BIN_DIR/JidokaCodeApp"
BOUNDED_COMMAND_RUNNER="$BIN_DIR/JidokaCodeBoundedCommand"
readonly BOUNDED_COMMAND_RUNNER
[[ -x "$VERIFIER" && -f "$VERIFIER" && ! -L "$VERIFIER" ]] || \
    fail "release-built staged verifier is unavailable"
[[ -x "$BOUNDED_COMMAND_RUNNER" && -f "$BOUNDED_COMMAND_RUNNER" && \
    ! -L "$BOUNDED_COMMAND_RUNNER" ]] || fail "native bounded verifier runner is unavailable"

status=0
report="$(
    cd /
    /usr/bin/env -i \
        HOME="$TEMP_ROOT/home" \
        PATH="/usr/bin:/bin" \
        TMPDIR="$TEMP_ROOT/tmp" \
        "$BOUNDED_COMMAND_RUNNER" 600 \
        "$VERIFIER" --release-runtime-verify-input "$RUNTIME_ROOT" </dev/null
)" || status=$?
case "$status" in
    0) ;;
    124) fail "release-built staged verifier timed out" ;;
    125) fail "release-built staged verifier cleanup failed" ;;
    *) fail "release-built staged verifier rejected the qualified input" ;;
esac
runtime_id="$(printf '%s\n' "$report" | /usr/bin/plutil -extract runtimeID raw -o - -)"
manifest_sha256="$(
    printf '%s\n' "$report" | /usr/bin/plutil -extract manifestSHA256 raw -o - -
)"
identity_sha256="$(
    printf '%s\n' "$report" | /usr/bin/plutil -extract runtimeIdentitySHA256 raw -o - -
)"
schema_version="$(
    printf '%s\n' "$report" | /usr/bin/plutil -extract schemaVersion raw -o - -
)"
[[ "$runtime_id" == "$EXPECTED_RUNTIME_ID" && \
    "$manifest_sha256" == "$EXPECTED_MANIFEST_SHA256" && \
    "$identity_sha256" =~ ^[0-9a-f]{64}$ && "$schema_version" == "1" ]] || \
    fail "release-built staged verifier returned unexpected identity"

NODE_BIN="$RUNTIME_ROOT/node/bin/node"
readonly NODE_BIN
[[ -x "$NODE_BIN" && -f "$NODE_BIN" && ! -L "$NODE_BIN" && \
    "$(/bin/realpath "$NODE_BIN")" == "$NODE_BIN" ]] || \
    fail "attested Node path is unavailable"
printf '%s\n' "$NODE_BIN"
