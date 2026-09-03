#!/usr/bin/env bash
# ABOUTME: Builds and re-audits an ad-hoc W0 location-probe package pair without installation.
# ABOUTME: Pins unique authority, two exact payload roots, hash tamper denial and no admin tools.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly BUILDER="$ROOT/scripts/build-location-probe-packages.sh"
readonly AUDITOR="$ROOT/scripts/audit-location-probe-packages.sh"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-location-probe-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
readonly TEST_ROOT
readonly ARTIFACT_DIR="$TEST_ROOT/artifacts"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'test-location-probe-packaging failed: %s\n' "$1" >&2
    exit 1
}

for script in "$BUILDER" "$AUDITOR"; do
    [[ -x "$script" && ! -L "$script" ]] || fail "probe script is unavailable: $script"
    if /usr/bin/grep -Eq '(/usr/sbin/installer|/usr/bin/sudo|notarytool|stapler)' "$script"; then
        fail "unprivileged probe tooling references an admin or notarization command"
    fi
done
/usr/bin/grep -Fq 'proc_pidpath(getpid()' \
    "$ROOT/Sources/JidokaCodeLocationProbeEngine/main.swift" || \
    fail "probe helper does not resolve its kernel-reported executable path"
if /usr/bin/grep -Fq 'CommandLine.arguments[0]' \
    "$ROOT/Sources/JidokaCodeLocationProbeEngine/main.swift"; then
    fail "probe helper trusts launchd-controlled argv[0]"
fi
for required in EXPECTED_APPLICATION_IDENTITY EXPECTED_INSTALLER_IDENTITY \
    extract-certificates X509Certificate; do
    /usr/bin/grep -Fq "$required" "$AUDITOR" || \
        fail "auditor omits exact certificate check: $required"
done
for blocked_sha in \
    c68ae65fce00645deedf94fa0f084f3787a4d826f58b74ec07ba3b61d187ec3e \
    e5cd855e3059bb5ff250f04efce0cb0466f5f75fca3c3c695bc4397b3af54a32; do
    rc=0
    /usr/bin/env -i /bin/bash "$AUDITOR" --check-package-sha "$blocked_sha" \
        >"$TEST_ROOT/blocked-sha.stdout" 2>"$TEST_ROOT/blocked-sha.stderr" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "auditor accepted a permanently blocked package SHA-256"
    /usr/bin/grep -Fq 'package SHA-256 is permanently blocked' \
        "$TEST_ROOT/blocked-sha.stderr" || fail "blocked package failed opaquely"
done
/usr/bin/env -i /bin/bash "$AUDITOR" --check-package-sha \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null

readonly PAYLOAD_POLICY_ROOT="$TEST_ROOT/payload-policy/Payload"
mkdir -p "$PAYLOAD_POLICY_ROOT/JidokaCode-LocationProbe/Applications/Probe.app"
printf 'payload\n' >"$PAYLOAD_POLICY_ROOT/JidokaCode-LocationProbe/Applications/Probe.app/file"
/usr/bin/env -i /bin/bash "$AUDITOR" --check-payload-tree "$PAYLOAD_POLICY_ROOT" >/dev/null
/bin/chmod +a "everyone allow read" "$PAYLOAD_POLICY_ROOT/JidokaCode-LocationProbe"
rc=0
/usr/bin/env -i /bin/bash "$AUDITOR" --check-payload-tree "$PAYLOAD_POLICY_ROOT" \
    >"$TEST_ROOT/payload-acl.stdout" 2>"$TEST_ROOT/payload-acl.stderr" || rc=$?
[[ "$rc" -ne 0 ]] || fail "payload policy accepted an authority-directory ACL"
/usr/bin/grep -Fq 'payload tree contains an ACL' "$TEST_ROOT/payload-acl.stderr" || \
    fail "authority-directory ACL failed for an unexpected reason"
/bin/chmod -a "everyone allow read" "$PAYLOAD_POLICY_ROOT/JidokaCode-LocationProbe"

rc=0
(
    cd /
    /usr/bin/env -i \
        HOME="$HOME" \
        TMPDIR="${TMPDIR:-/tmp}" \
        SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        INSTALLER_SIGN_IDENTITY=1111111111111111111111111111111111111111 \
        /bin/bash "$BUILDER" \
        --output-dir "$TEST_ROOT/invalid-developer-id" \
        --signing-mode developer-id
) >"$TEST_ROOT/invalid-id.stdout" 2>"$TEST_ROOT/invalid-id.stderr" || rc=$?
[[ "$rc" -ne 0 ]] || fail "builder accepted unavailable Developer ID identities"
/usr/bin/grep -Fq 'SIGN_IDENTITY must be the approved Application identity' \
    "$TEST_ROOT/invalid-id.stderr" || \
    fail "Developer ID preflight failed before exact identity validation"
[[ ! -e "$TEST_ROOT/invalid-developer-id" ]] || \
    fail "invalid Developer ID preflight created an artifact directory"

if ! (
    cd /
    /usr/bin/env -i \
        HOME="$HOME" \
        TMPDIR="${TMPDIR:-/tmp}" \
        /bin/bash "$BUILDER" --output-dir "$ARTIFACT_DIR" --signing-mode adhoc
) >"$TEST_ROOT/build.stdout" 2>"$TEST_ROOT/build.stderr"; then
    /bin/cat "$TEST_ROOT/build.stdout" >&2
    /bin/cat "$TEST_ROOT/build.stderr" >&2
    fail "ad-hoc builder failed"
fi
if ! (
    cd /
    /usr/bin/env -i TMPDIR="${TMPDIR:-/tmp}" /bin/bash "$AUDITOR" --artifact-dir "$ARTIFACT_DIR"
) >"$TEST_ROOT/audit.stdout" 2>"$TEST_ROOT/audit.stderr"; then
    /bin/cat "$TEST_ROOT/audit.stdout" >&2
    /bin/cat "$TEST_ROOT/audit.stderr" >&2
    fail "ad-hoc audit failed"
fi
[[ ! -s "$TEST_ROOT/audit.stderr" ]] || fail "successful ad-hoc audit wrote stderr"
/usr/bin/grep -Fq 'location-probe audit: PASS' "$TEST_ROOT/audit.stdout" || \
    fail "audit pass line is absent"
[[ -s "$ARTIFACT_DIR/static-audit.log" && \
    "$(/usr/bin/stat -f '%p' "$ARTIFACT_DIR/static-audit.log")" == "100600" ]] || \
    fail "builder did not retain a private nonempty static audit"
for field in artifact_set_sha256 artifact_manifest_sha256 static_audit_sha256; do
    /usr/bin/grep -Eq "^${field}=[0-9a-f]{64}$" "$TEST_ROOT/build.stdout" || \
        fail "builder output omitted $field"
done

readonly MANIFEST="$ARTIFACT_DIR/location-probe-artifacts.json"
[[ "$(/usr/bin/plutil -extract applicationIdentifier raw "$MANIFEST")" == \
    "com.maroffo.JidokaCode.LocationProbe" ]] || fail "probe application identifier differs"
[[ "$(/usr/bin/plutil -extract helperIdentifier raw "$MANIFEST")" == \
    "com.maroffo.JidokaCode.LocationProbe.Engine" ]] || fail "probe helper identifier differs"
[[ "$(/usr/bin/plutil -extract packageIdentifier raw "$MANIFEST")" == \
    "com.maroffo.JidokaCode.LocationProbe.pkg" ]] || fail "probe package identifier differs"
[[ "$(/usr/bin/plutil -extract legacy.installedAppPath raw "$MANIFEST")" == \
    "/Applications/Jidoka Code Location Probe.app" ]] || fail "legacy probe path differs"
[[ "$(/usr/bin/plutil -extract successor.installedAppPath raw "$MANIFEST")" == \
    "/Library/Application Support/JidokaCode-LocationProbe/Applications/Jidoka Code Location Probe.app" ]] || \
    fail "successor probe path differs"

SUCCESSOR="$(/usr/bin/plutil -extract successor.packagePath raw "$MANIFEST")"
readonly SUCCESSOR
/bin/cp "$MANIFEST" "$TEST_ROOT/manifest.backup"
/usr/bin/plutil -replace successor.installRoot -string "/Library/Application Support/JidokaCode" \
    "$MANIFEST"
rc=0
(
    cd /
    /usr/bin/env -i TMPDIR="${TMPDIR:-/tmp}" /bin/bash "$AUDITOR" --artifact-dir "$ARTIFACT_DIR"
) >"$TEST_ROOT/root-drift.stdout" 2>"$TEST_ROOT/root-drift.stderr" || rc=$?
[[ "$rc" -ne 0 ]] || fail "audit accepted a self-reported production install root"
/usr/bin/grep -Fq 'successor manifest authority differs' "$TEST_ROOT/root-drift.stderr" || \
    fail "production-root manifest drift failed for an unexpected reason"
/bin/cp "$TEST_ROOT/manifest.backup" "$MANIFEST"

/bin/ln "$SUCCESSOR" "$TEST_ROOT/successor.hardlink"
rc=0
(
    cd /
    /usr/bin/env -i TMPDIR="${TMPDIR:-/tmp}" /bin/bash "$AUDITOR" --artifact-dir "$ARTIFACT_DIR"
) >"$TEST_ROOT/hardlink.stdout" 2>"$TEST_ROOT/hardlink.stderr" || rc=$?
[[ "$rc" -ne 0 ]] || fail "audit accepted a hard-linked package artifact"
/usr/bin/grep -Fq 'has multiple hard links' "$TEST_ROOT/hardlink.stderr" || \
    fail "hard-linked package failed for an unexpected reason"
/bin/rm "$TEST_ROOT/successor.hardlink"

/bin/chmod +a "everyone allow read" "$SUCCESSOR"
rc=0
(
    cd /
    /usr/bin/env -i TMPDIR="${TMPDIR:-/tmp}" /bin/bash "$AUDITOR" --artifact-dir "$ARTIFACT_DIR"
) >"$TEST_ROOT/acl.stdout" 2>"$TEST_ROOT/acl.stderr" || rc=$?
[[ "$rc" -ne 0 ]] || fail "audit accepted a package artifact with an allow ACL"
/usr/bin/grep -Fq 'has an ACL' "$TEST_ROOT/acl.stderr" || \
    fail "package ACL failed for an unexpected reason"
/bin/chmod -a "everyone allow read" "$SUCCESSOR"

readonly EXPANDED="$TEST_ROOT/expanded-successor"
/usr/sbin/pkgutil --expand-full "$SUCCESSOR" "$EXPANDED" 2>"$TEST_ROOT/expand.stderr"
/usr/bin/awk '$0 != "write: Permission denied" {exit 1}' "$TEST_ROOT/expand.stderr" || \
    fail "successor expansion produced an unexpected diagnostic"
EXPANDED_APP="$(/usr/bin/find "$EXPANDED" -type d -name 'Jidoka Code Location Probe.app' -print)"
readonly EXPANDED_APP
[[ -n "$EXPANDED_APP" ]] || fail "expanded successor app is absent"
(
    cd /
    /usr/bin/env -i HOME="$HOME" \
        "$EXPANDED_APP/Contents/MacOS/Jidoka Code" self-check
) >"$TEST_ROOT/self-check.json"
[[ "$(/usr/bin/plutil -extract bundleIdentifier raw "$TEST_ROOT/self-check.json")" == \
    "com.maroffo.JidokaCode.LocationProbe" ]] || fail "expanded probe self-check differs"

/bin/cp "$SUCCESSOR" "$TEST_ROOT/successor.backup"
printf 'tamper\n' >>"$SUCCESSOR"
rc=0
(
    cd /
    /usr/bin/env -i TMPDIR="${TMPDIR:-/tmp}" /bin/bash "$AUDITOR" --artifact-dir "$ARTIFACT_DIR"
) >"$TEST_ROOT/tamper.stdout" 2>"$TEST_ROOT/tamper.stderr" || rc=$?
[[ "$rc" -ne 0 ]] || fail "audit accepted a tampered successor package"
/usr/bin/grep -Fq 'successor package hash differs' "$TEST_ROOT/tamper.stderr" || \
    fail "tampered package failed for an unexpected reason"
/bin/cp "$TEST_ROOT/successor.backup" "$SUCCESSOR"

printf 'test-location-probe-packaging passed\n'
