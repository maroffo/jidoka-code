#!/usr/bin/env bash
# ABOUTME: Builds the unique-ID W0 PackageKit location-upgrade probe pair for static review.
# ABOUTME: Supports an ad-hoc local layout rehearsal and an explicitly authorized Developer ID build.
set -euo pipefail
# Package payload modes must not inherit the invoking shell's private umask.
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly ROOT
readonly AUDITOR="$ROOT/scripts/audit-location-probe-packages.sh"
readonly PROBE_PACKAGE_ID="com.maroffo.JidokaCode.LocationProbe.pkg"
readonly PROBE_BUNDLE_ID="com.maroffo.JidokaCode.LocationProbe"
readonly PROBE_HELPER_ID="com.maroffo.JidokaCode.LocationProbe.Engine"
readonly PROBE_APP_NAME="Jidoka Code Location Probe.app"
readonly PROBE_MAIN_EXECUTABLE="Jidoka Code"
readonly PROBE_HELPER_EXECUTABLE="JidokaCodeLocationProbeEngine"
readonly PROBE_LAUNCH_PLIST="com.maroffo.JidokaCode.LocationProbe.Engine.plist"
readonly PROBE_SECURE_ROOT="/Library/Application Support/JidokaCode-LocationProbe"
readonly PROBE_SECURE_APP="$PROBE_SECURE_ROOT/Applications/$PROBE_APP_NAME"
readonly EXPECTED_TEAM="X3Q42VNZDC"
readonly EXPECTED_APPLICATION_IDENTITY="42168752E0FB74059B87BCCF4870356745AAAFA0"
readonly EXPECTED_INSTALLER_IDENTITY="44A3B34F4CCDE0AD66D2024CCB2F6E93483B9F2B"
readonly TOOL_TIMEOUT_SECONDS=300

OUTPUT_DIR=""
SIGNING_MODE=""
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"
APPLICATION_SIGNING_KEYCHAIN="${APPLICATION_SIGNING_KEYCHAIN:-$SIGNING_KEYCHAIN}"
INSTALLER_SIGNING_KEYCHAIN="${INSTALLER_SIGNING_KEYCHAIN:-$SIGNING_KEYCHAIN}"
TEMP_ROOT=""

fail() {
    printf 'location-probe packaging failed: %s\n' "$1" >&2
    exit 1
}

usage() {
    fail "usage: build-location-probe-packages.sh --output-dir <absolute-new-directory> --signing-mode adhoc|developer-id"
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        case "$(/usr/bin/basename "$TEMP_ROOT")" in
            jidoka-location-probe-build.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
        esac
    fi
    exit "$status"
}

bounded() {
    local status=0
    # The Perl source is intentionally protected from shell expansion.
    # shellcheck disable=SC2016
    /usr/bin/perl -e 'my $t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV; exit 127;' \
        "$TOOL_TIMEOUT_SECONDS" "$@" || status=$?
    [[ "$status" != "142" ]] || fail "command timed out: $1"
    [[ "$status" == "0" ]] || fail "command failed ($status): $1"
}

validate_keychain() {
    local path="$1" label="$2" parent
    [[ -n "$path" ]] || return 0
    [[ "$path" == /* && -f "$path" && ! -L "$path" ]] || \
        fail "$label must be an absolute regular keychain"
    parent="$(cd "$(dirname "$path")" && pwd -P)"
    [[ "$parent/$(basename "$path")" == "$path" ]] || fail "$label must be canonical"
}

identity_line() {
    local identity="$1" policy="$2" keychain="$3"
    if [[ -n "$keychain" ]]; then
        /usr/bin/security find-identity -v -p "$policy" "$keychain" 2>/dev/null | \
            /usr/bin/awk -v expected="$identity" 'toupper($2) == toupper(expected) {print; found=1} END {exit(found ? 0 : 1)}'
    else
        /usr/bin/security find-identity -v -p "$policy" 2>/dev/null | \
            /usr/bin/awk -v expected="$identity" 'toupper($2) == toupper(expected) {print; found=1} END {exit(found ? 0 : 1)}'
    fi
}

sha256_of() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

path_has_allow_acl() {
    /bin/ls -lde "$1" | /usr/bin/awk 'NR > 1 && $0 ~ / allow / {found=1} END {exit(found ? 0 : 1)}'
}

uppercased() {
    printf '%s' "$1" | /usr/bin/tr '[:lower:]' '[:upper:]'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            [[ $# -ge 2 ]] || usage
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --signing-mode)
            [[ $# -ge 2 ]] || usage
            SIGNING_MODE="$2"
            shift 2
            ;;
        *) usage ;;
    esac
done
[[ "$OUTPUT_DIR" == /* ]] || usage
case "$SIGNING_MODE" in
    adhoc|developer-id) ;;
    *) usage ;;
esac
[[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || fail "output directory already exists"
OUTPUT_PARENT="$(dirname "$OUTPUT_DIR")"
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] || fail "output parent is unavailable"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
OUTPUT_DIR="$OUTPUT_PARENT/$(basename "$OUTPUT_DIR")"
[[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || fail "canonical output directory exists"
readonly OUTPUT_DIR SIGNING_MODE

[[ -x "$AUDITOR" && ! -L "$AUDITOR" ]] || fail "location-probe auditor is unavailable"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    [[ "$(uppercased "$SIGN_IDENTITY")" == "$EXPECTED_APPLICATION_IDENTITY" ]] || \
        fail "SIGN_IDENTITY must be the approved Application identity"
    [[ "$(uppercased "$INSTALLER_SIGN_IDENTITY")" == "$EXPECTED_INSTALLER_IDENTITY" ]] || \
        fail "INSTALLER_SIGN_IDENTITY must be the approved Installer identity"
    validate_keychain "$APPLICATION_SIGNING_KEYCHAIN" APPLICATION_SIGNING_KEYCHAIN
    validate_keychain "$INSTALLER_SIGNING_KEYCHAIN" INSTALLER_SIGNING_KEYCHAIN
    APP_IDENTITY_LINE="$(identity_line "$SIGN_IDENTITY" codesigning "$APPLICATION_SIGNING_KEYCHAIN")" || \
        fail "SIGN_IDENTITY is not a valid local identity"
    INSTALLER_IDENTITY_LINE="$(identity_line "$INSTALLER_SIGN_IDENTITY" basic "$INSTALLER_SIGNING_KEYCHAIN")" || \
        fail "INSTALLER_SIGN_IDENTITY is not a valid local identity"
    [[ "$APP_IDENTITY_LINE" == *"Developer ID Application:"*"($EXPECTED_TEAM)"* ]] || \
        fail "application identity is not the approved Developer ID Team"
    [[ "$INSTALLER_IDENTITY_LINE" == *"Developer ID Installer:"*"($EXPECTED_TEAM)"* ]] || \
        fail "installer identity is not the approved Developer ID Team"
else
    [[ -z "$SIGN_IDENTITY" && -z "$INSTALLER_SIGN_IDENTITY" && \
        -z "$APPLICATION_SIGNING_KEYCHAIN" && -z "$INSTALLER_SIGNING_KEYCHAIN" ]] || \
        fail "ad-hoc mode refuses signing identities or keychains"
fi
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    EXPECTED_VALUES_TEAM="$EXPECTED_TEAM"
    EXPECTED_VALUES_APPLICATION_IDENTITY="$EXPECTED_APPLICATION_IDENTITY"
else
    EXPECTED_VALUES_TEAM="not set"
    EXPECTED_VALUES_APPLICATION_IDENTITY=""
fi
readonly EXPECTED_VALUES_TEAM EXPECTED_VALUES_APPLICATION_IDENTITY

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-location-probe-build.XXXXXX")"
readonly TEMP_ROOT
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
readonly FINAL_ROOT="$TEMP_ROOT/final"
/bin/mkdir -m 0700 "$FINAL_ROOT"
printf 'jidoka-location-probe-artifact-v1\n' >"$FINAL_ROOT/.location-probe-artifact-root"

readonly SCRATCH="$ROOT/.build/location-probe-uat"
bounded /usr/bin/xcrun swift build --package-path "$ROOT" --scratch-path "$SCRATCH" \
    --configuration release --product JidokaCodeLocationProbeApp
bounded /usr/bin/xcrun swift build --package-path "$ROOT" --scratch-path "$SCRATCH" \
    --configuration release --product JidokaCodeLocationProbeEngine
BIN_DIR="$(bounded /usr/bin/xcrun swift build --package-path "$ROOT" --scratch-path "$SCRATCH" \
    --configuration release --show-bin-path)"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
case "$BIN_DIR" in
    "$SCRATCH"/*) ;;
    *) fail "Swift build output escapes the dedicated scratch path" ;;
esac
readonly BIN_DIR
readonly BUILT_APP="$BIN_DIR/JidokaCodeLocationProbeApp"
readonly BUILT_HELPER="$BIN_DIR/JidokaCodeLocationProbeEngine"
[[ -f "$BUILT_APP" && -x "$BUILT_APP" && ! -L "$BUILT_APP" ]] || fail "probe app binary missing"
[[ -f "$BUILT_HELPER" && -x "$BUILT_HELPER" && ! -L "$BUILT_HELPER" ]] || \
    fail "probe helper binary missing"

sign_binary() {
    local path="$1" identifier="$2"
    if [[ "$SIGNING_MODE" == "developer-id" ]]; then
        local -a arguments=(--force --sign "$SIGN_IDENTITY" --timestamp --options runtime --identifier "$identifier")
        if [[ -n "$APPLICATION_SIGNING_KEYCHAIN" ]]; then
            arguments+=(--keychain "$APPLICATION_SIGNING_KEYCHAIN")
        fi
        arguments+=("$path")
        bounded /usr/bin/codesign "${arguments[@]}"
    else
        bounded /usr/bin/codesign --force --sign - --identifier "$identifier" "$path"
    fi
}

create_app() {
    local version="$1" build="$2" output="$3"
    local contents="$output/Contents"
    /bin/mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Library/LaunchAgents"
    /bin/chmod 0755 "$output" "$contents" "$contents/MacOS" "$contents/Helpers" \
        "$contents/Library" "$contents/Library/LaunchAgents"
    /usr/bin/install -m 0755 "$BUILT_APP" "$contents/MacOS/$PROBE_MAIN_EXECUTABLE"
    /usr/bin/install -m 0755 "$BUILT_HELPER" "$contents/Helpers/$PROBE_HELPER_EXECUTABLE"
    /bin/cat >"$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>Jidoka Code Location Probe</string>
  <key>CFBundleExecutable</key><string>$PROBE_MAIN_EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>$PROBE_BUNDLE_ID</string>
  <key>CFBundleName</key><string>Jidoka Code Location Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
    /bin/cat >"$contents/Library/LaunchAgents/$PROBE_LAUNCH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$PROBE_HELPER_ID</string>
  <key>BundleProgram</key><string>Contents/Helpers/$PROBE_HELPER_EXECUTABLE</string>
  <key>ProgramArguments</key><array><string>$PROBE_HELPER_EXECUTABLE</string><string>--service</string></array>
  <key>RunAtLoad</key><true/>
  <key>MachServices</key><dict><key>$PROBE_HELPER_ID</key><true/></dict>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Background</string>
  <key>ThrottleInterval</key><integer>1</integer>
</dict></plist>
EOF
    /bin/chmod 0644 "$contents/Info.plist" "$contents/Library/LaunchAgents/$PROBE_LAUNCH_PLIST"
    /usr/bin/plutil -lint "$contents/Info.plist" "$contents/Library/LaunchAgents/$PROBE_LAUNCH_PLIST" >/dev/null
    /usr/bin/xattr -cr "$output"
    sign_binary "$contents/Helpers/$PROBE_HELPER_EXECUTABLE" "$PROBE_HELPER_ID"
    sign_binary "$output" "$PROBE_BUNDLE_ID"
    /usr/bin/codesign --verify --strict --deep "$output" || fail "new probe app signature is invalid"
}

create_component_policy() {
    local relative_app="$1" output="$2"
    /bin/cat >"$output" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>RootRelativeBundlePath</key><string>$relative_app</string>
  <key>BundleIsRelocatable</key><false/>
  <key>BundleIsVersionChecked</key><true/>
  <key>BundleHasStrictIdentifier</key><true/>
  <key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
EOF
    /usr/bin/plutil -lint "$output" >/dev/null
}

package_variant() {
    local key="$1" version="$2" build="$3" install_root="$4" relative_app="$5" package_name="$6"
    local variant="$TEMP_ROOT/$key"
    local app="$variant/$PROBE_APP_NAME" component="$variant/component"
    local component_pkg="$variant/component.pkg" unsigned_pkg="$variant/unsigned.pkg"
    local product_pkg="$variant/product.pkg" policy="$variant/component.plist"
    /bin/mkdir -m 0700 "$variant"
    create_app "$version" "$build" "$app"
    /bin/mkdir -p "$component/$(dirname "$relative_app")"
    /usr/bin/find "$component" -type d -exec /bin/chmod 0755 {} +
    COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
        "$app" "$component/$relative_app"
    create_component_policy "$relative_app" "$policy"
    bounded /usr/bin/pkgbuild --root "$component" --component-plist "$policy" \
        --ownership recommended --install-location "$install_root" \
        --identifier "$PROBE_PACKAGE_ID" --version "$version" "$component_pkg"
    bounded /usr/bin/productbuild --package "$component_pkg" "$unsigned_pkg"
    if [[ "$SIGNING_MODE" == "developer-id" ]]; then
        local -a arguments=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
        if [[ -n "$INSTALLER_SIGNING_KEYCHAIN" ]]; then
            arguments+=(--keychain "$INSTALLER_SIGNING_KEYCHAIN")
        fi
        arguments+=("$unsigned_pkg" "$product_pkg")
        bounded /usr/bin/productsign "${arguments[@]}"
    else
        /bin/cp "$unsigned_pkg" "$product_pkg"
    fi
    /usr/bin/install -m 0644 "$product_pkg" "$FINAL_ROOT/$package_name"
}

package_variant legacy 0.1.0 1 /Applications "$PROBE_APP_NAME" \
    Jidoka-Code-Location-Probe-0.1.0.pkg
package_variant successor 0.1.1 2 "/Library/Application Support" \
    "JidokaCode-LocationProbe/Applications/$PROBE_APP_NAME" \
    Jidoka-Code-Location-Probe-0.1.1.pkg

readonly LEGACY_PACKAGE_FINAL="$OUTPUT_DIR/Jidoka-Code-Location-Probe-0.1.0.pkg"
readonly SUCCESSOR_PACKAGE_FINAL="$OUTPUT_DIR/Jidoka-Code-Location-Probe-0.1.1.pkg"
LEGACY_SHA="$(sha256_of "$FINAL_ROOT/Jidoka-Code-Location-Probe-0.1.0.pkg")"
SUCCESSOR_SHA="$(sha256_of "$FINAL_ROOT/Jidoka-Code-Location-Probe-0.1.1.pkg")"
readonly LEGACY_SHA SUCCESSOR_SHA
readonly SUCCESSOR_MANIFEST_FINAL="$OUTPUT_DIR/successor-package-manifest.json"
/bin/cat >"$FINAL_ROOT/successor-package-manifest.json" <<EOF
{
  "schemaVersion": 1,
  "packageIdentifier": "$PROBE_PACKAGE_ID",
  "installLocation": "$PROBE_SECURE_APP",
  "appVersion": "0.1.1",
  "appBuildVersion": "2",
  "packagePath": "$SUCCESSOR_PACKAGE_FINAL",
  "packageSHA256": "$SUCCESSOR_SHA",
  "packageNotarized": false,
  "signingMode": "$SIGNING_MODE"
}
EOF
/usr/bin/plutil -convert xml1 -o /dev/null "$FINAL_ROOT/successor-package-manifest.json"
SUCCESSOR_MANIFEST_SHA="$(sha256_of "$FINAL_ROOT/successor-package-manifest.json")"
readonly SUCCESSOR_MANIFEST_SHA

readonly CUTOVER_VALUES_FINAL="$OUTPUT_DIR/uat-cutover-values.env"
/bin/cat >"$FINAL_ROOT/uat-cutover-values.env" <<EOF
package_path=$SUCCESSOR_PACKAGE_FINAL
package_sha256=$SUCCESSOR_SHA
package_manifest_path=$SUCCESSOR_MANIFEST_FINAL
package_manifest_sha256=$SUCCESSOR_MANIFEST_SHA
EOF
/bin/chmod 0600 "$FINAL_ROOT/uat-cutover-values.env"
CUTOVER_VALUES_SHA="$(sha256_of "$FINAL_ROOT/uat-cutover-values.env")"
readonly CUTOVER_VALUES_SHA

readonly EXPECTED_VALUES_FINAL="$OUTPUT_DIR/uat-probe-expected.json"
/bin/cat >"$FINAL_ROOT/uat-probe-expected.json" <<EOF
{
  "schemaVersion": 1,
  "mode": "uat-probe",
  "osProductVersion": "27.0",
  "toolTimeoutSeconds": 30,
  "overallDeadlineSeconds": 600,
  "package": {
    "identifier": "$PROBE_PACKAGE_ID",
    "receiptVolume": "/",
    "staticReceiptState": "absent",
    "legacyReceiptVersion": "0.1.0",
    "legacyReceiptLocation": "Applications",
    "successorReceiptVersion": "0.1.1",
    "successorReceiptLocation": "Library/Application Support",
    "legacyPackagePath": "$LEGACY_PACKAGE_FINAL",
    "legacyPackageSHA256": "$LEGACY_SHA"
  },
  "bundle": {
    "identifier": "$PROBE_BUNDLE_ID",
    "helperIdentifier": "$PROBE_HELPER_ID",
    "teamIdentifier": "$EXPECTED_VALUES_TEAM",
    "applicationSigningIdentitySHA1": "$EXPECTED_VALUES_APPLICATION_IDENTITY",
    "mainExecutableName": "$PROBE_MAIN_EXECUTABLE",
    "helperExecutableName": "$PROBE_HELPER_EXECUTABLE",
    "launchAgentPlistName": "$PROBE_LAUNCH_PLIST",
    "successorVersion": "0.1.1",
    "successorBuildVersion": "2",
    "legacyAppPath": "/Applications/$PROBE_APP_NAME",
    "securePath": "$PROBE_SECURE_APP",
    "secureRoot": "$PROBE_SECURE_ROOT",
    "legacyAppPostInstallState": "absent"
  },
  "preInstallParents": [
    { "path": "/Applications", "owner": "0:80", "mode": "40775" },
    { "path": "/Library", "owner": "0:0", "mode": "40755" },
    { "path": "/Library/Application Support", "owner": "0:80", "mode": "40755" }
  ],
  "postInstallParents": [
    { "path": "/Library", "owner": "0:0", "mode": "40755" },
    { "path": "/Library/Application Support", "owner": "0:80", "mode": "40755" },
    { "path": "$PROBE_SECURE_ROOT", "owner": "0:0", "mode": "40755" },
    { "path": "$PROBE_SECURE_ROOT/Applications", "owner": "0:0", "mode": "40755" }
  ],
  "herdr": {
    "linkPath": "/opt/homebrew/bin/herdr",
    "resolvedPath": "/opt/homebrew/Cellar/herdr/0.8.2/bin/herdr",
    "executableSHA256": "3e0f0c2d5edc41f592963ef90f5d872db801cc7dbd0e01731023897ee428904a",
    "version": "0.8.2",
    "protocolVersion": 20
  },
  "git": {
    "path": "/usr/bin/git",
    "sha256": "1685f2c90307faa05ef5ae8f707d3a18a519c9dad75882768f66abb475f1b3d7",
    "backendPath": "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-http-backend",
    "backendSHA256": "4026051f87a437197a913d4ca5d3196f1d749bf6060f84c74cc374263988110a"
  }
}
EOF
/usr/bin/plutil -convert xml1 -o /dev/null "$FINAL_ROOT/uat-probe-expected.json"
EXPECTED_VALUES_SHA="$(sha256_of "$FINAL_ROOT/uat-probe-expected.json")"
readonly EXPECTED_VALUES_SHA

/bin/cat >"$FINAL_ROOT/artifact-set.txt" <<EOF
$LEGACY_SHA  $LEGACY_PACKAGE_FINAL
$SUCCESSOR_SHA  $SUCCESSOR_PACKAGE_FINAL
$SUCCESSOR_MANIFEST_SHA  $SUCCESSOR_MANIFEST_FINAL
$EXPECTED_VALUES_SHA  $EXPECTED_VALUES_FINAL
$CUTOVER_VALUES_SHA  $CUTOVER_VALUES_FINAL
EOF
ARTIFACT_SET_SHA="$(sha256_of "$FINAL_ROOT/artifact-set.txt")"
readonly ARTIFACT_SET_SHA
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    TEAM_MARKER="$EXPECTED_TEAM"
else
    TEAM_MARKER="not-set"
    SIGN_IDENTITY=""
    INSTALLER_SIGN_IDENTITY=""
fi
readonly TEAM_MARKER

/bin/cat >"$FINAL_ROOT/location-probe-artifacts.json" <<EOF
{
  "schemaVersion": 1,
  "signingMode": "$SIGNING_MODE",
  "teamIdentifier": "$TEAM_MARKER",
  "applicationSigningIdentitySHA1": "$SIGN_IDENTITY",
  "installerSigningIdentitySHA1": "$INSTALLER_SIGN_IDENTITY",
  "applicationIdentifier": "$PROBE_BUNDLE_ID",
  "helperIdentifier": "$PROBE_HELPER_ID",
  "packageIdentifier": "$PROBE_PACKAGE_ID",
  "legacy": {
    "version": "0.1.0",
    "buildVersion": "1",
    "installRoot": "/Applications",
    "payloadRelativeAppPath": "$PROBE_APP_NAME",
    "installedAppPath": "/Applications/$PROBE_APP_NAME",
    "packagePath": "$LEGACY_PACKAGE_FINAL",
    "packageSHA256": "$LEGACY_SHA"
  },
  "successor": {
    "version": "0.1.1",
    "buildVersion": "2",
    "installRoot": "/Library/Application Support",
    "payloadRelativeAppPath": "JidokaCode-LocationProbe/Applications/$PROBE_APP_NAME",
    "installedAppPath": "$PROBE_SECURE_APP",
    "packagePath": "$SUCCESSOR_PACKAGE_FINAL",
    "packageSHA256": "$SUCCESSOR_SHA"
  },
  "expectedValuesPath": "$EXPECTED_VALUES_FINAL",
  "expectedValuesSHA256": "$EXPECTED_VALUES_SHA",
  "cutoverValuesPath": "$CUTOVER_VALUES_FINAL",
  "cutoverValuesSHA256": "$CUTOVER_VALUES_SHA",
  "artifactSetSHA256": "$ARTIFACT_SET_SHA"
}
EOF
/usr/bin/plutil -convert xml1 -o /dev/null "$FINAL_ROOT/location-probe-artifacts.json"
/bin/chmod 0600 "$FINAL_ROOT"/*.json "$FINAL_ROOT/artifact-set.txt"
/bin/chmod 0600 "$FINAL_ROOT/uat-cutover-values.env" "$FINAL_ROOT/.location-probe-artifact-root"
/bin/mv "$FINAL_ROOT" "$OUTPUT_DIR"
AUDIT_OUTPUT="$TEMP_ROOT/static-audit.log"
JIDOKA_LOCATION_PROBE_BOOTSTRAP_AUDIT=1 \
    bounded "$AUDITOR" --artifact-dir "$OUTPUT_DIR" >"$AUDIT_OUTPUT"
[[ -s "$AUDIT_OUTPUT" ]] || fail "static audit produced no evidence"
/usr/bin/install -m 0600 "$AUDIT_OUTPUT" "$OUTPUT_DIR/static-audit.log"
/bin/cat "$AUDIT_OUTPUT"
STATIC_AUDIT_SHA="$(sha256_of "$OUTPUT_DIR/static-audit.log")"
ARTIFACT_MANIFEST_SHA="$(sha256_of "$OUTPUT_DIR/location-probe-artifacts.json")"
readonly STATIC_AUDIT_SHA ARTIFACT_MANIFEST_SHA

printf 'location_probe_artifact_dir=%s\n' "$OUTPUT_DIR"
printf 'artifact_set_sha256=%s\n' "$ARTIFACT_SET_SHA"
printf 'artifact_manifest_sha256=%s\n' "$ARTIFACT_MANIFEST_SHA"
printf 'static_audit_sha256=%s\n' "$STATIC_AUDIT_SHA"
printf 'legacy_package=%s\nlegacy_package_sha256=%s\n' "$LEGACY_PACKAGE_FINAL" "$LEGACY_SHA"
printf 'successor_package=%s\nsuccessor_package_sha256=%s\n' \
    "$SUCCESSOR_PACKAGE_FINAL" "$SUCCESSOR_SHA"
printf 'signing_mode=%s\nnotarized=false\n' "$SIGNING_MODE"
