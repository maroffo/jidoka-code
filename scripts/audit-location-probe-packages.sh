#!/usr/bin/env bash
# ABOUTME: Re-audits the signed or ad-hoc W0 location-probe package pair before any admin install.
# ABOUTME: Verifies immutable hashes, unique identifiers, PackageInfo, BOM, payload and signatures.
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C

readonly PRODUCTION_PACKAGE_ID="com.maroffo.JidokaCode.pkg"
readonly PRODUCTION_BUNDLE_ID="com.maroffo.JidokaCode"
readonly PRODUCTION_HELPER_ID="com.maroffo.JidokaCode.Engine"
readonly PRODUCTION_SECURE_ROOT="/Library/Application Support/JidokaCode"
readonly PROBE_PACKAGE_ID="com.maroffo.JidokaCode.LocationProbe.pkg"
readonly PROBE_BUNDLE_ID="com.maroffo.JidokaCode.LocationProbe"
readonly PROBE_HELPER_ID="com.maroffo.JidokaCode.LocationProbe.Engine"
readonly PROBE_APP_NAME="Jidoka Code Location Probe.app"
readonly PROBE_MAIN_EXECUTABLE="Jidoka Code"
readonly PROBE_HELPER_EXECUTABLE="JidokaCodeLocationProbeEngine"
readonly PROBE_LAUNCH_PLIST="com.maroffo.JidokaCode.LocationProbe.Engine.plist"
readonly EXPECTED_TEAM="X3Q42VNZDC"
readonly EXPECTED_APPLICATION_IDENTITY="42168752E0FB74059B87BCCF4870356745AAAFA0"
readonly EXPECTED_INSTALLER_IDENTITY="44A3B34F4CCDE0AD66D2024CCB2F6E93483B9F2B"
readonly BLOCKED_LEGACY_PACKAGE_SHA256="c68ae65fce00645deedf94fa0f084f3787a4d826f58b74ec07ba3b61d187ec3e"
readonly BLOCKED_SUCCESSOR_PACKAGE_SHA256="e5cd855e3059bb5ff250f04efce0cb0466f5f75fca3c3c695bc4397b3af54a32"
readonly TOOL_TIMEOUT_SECONDS=60

ARTIFACT_DIR=""
TEMP_ROOT=""
BOOTSTRAP_AUDIT="${JIDOKA_LOCATION_PROBE_BOOTSTRAP_AUDIT:-0}"
readonly BOOTSTRAP_AUDIT

fail() {
    printf 'location-probe audit failed: %s\n' "$1" >&2
    exit 1
}

usage() {
    fail "usage: audit-location-probe-packages.sh --artifact-dir <absolute-directory> | --check-package-sha <sha256> | --check-payload-tree <absolute-directory>"
}

bounded() {
    local status=0
    # The Perl source is intentionally protected from shell expansion.
    # shellcheck disable=SC2016
    /usr/bin/perl -e 'my $t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV; exit 127;' \
        "$TOOL_TIMEOUT_SECONDS" "$@" || status=$?
    [[ "$status" != "142" ]] || fail "command timed out: $1"
    return "$status"
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        case "$(/usr/bin/basename "$TEMP_ROOT")" in
            jidoka-location-probe-audit.*) /bin/rm -rf -- "$TEMP_ROOT" ;;
        esac
    fi
    exit "$status"
}

json_raw() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || \
        fail "artifact manifest is missing key: $2"
}

sha256_of() {
    bounded /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

sha1_of() {
    bounded /usr/bin/shasum -a 1 "$1" | /usr/bin/awk '{print toupper($1)}'
}

path_has_acl() {
    /bin/ls -lde "$1" | /usr/bin/awk 'NR > 1 {found=1} END {exit(found ? 0 : 1)}'
}

uppercased() {
    printf '%s' "$1" | /usr/bin/tr '[:lower:]' '[:upper:]'
}

require_regular() {
    [[ -f "$1" && ! -L "$1" ]] || fail "$2 is not a regular file: $1"
    [[ "$(/usr/bin/stat -f '%u' "$1")" == "$EUID" ]] || fail "$2 owner differs: $1"
    [[ "$(/usr/bin/stat -f '%l' "$1")" == "1" ]] || fail "$2 has multiple hard links: $1"
    ! path_has_acl "$1" || fail "$2 has an ACL: $1"
}

require_artifact_path() {
    local path="$1" label="$2" parent canonical
    parent="$(cd "$(/usr/bin/dirname "$path")" 2>/dev/null && pwd -P)" || \
        fail "$label parent is unavailable"
    canonical="$parent/$(/usr/bin/basename "$path")"
    [[ "$canonical" == "$path" && "$path" == "$ARTIFACT_DIR/"* ]] || \
        fail "$label escapes artifact directory"
    require_regular "$path" "$label"
}

package_sha_is_blocked() {
    case "$1" in
        "$BLOCKED_LEGACY_PACKAGE_SHA256"|"$BLOCKED_SUCCESSOR_PACKAGE_SHA256") return 0 ;;
        *) return 1 ;;
    esac
}

verify_payload_filesystem_safety() {
    local root="$1" label="$2" path
    [[ -d "$root" && ! -L "$root" ]] || fail "$label root is unavailable"
    [[ -z "$(/usr/bin/find "$root" -type l -print)" ]] || fail "$label contains a symlink"
    while IFS= read -r path; do
        ! path_has_acl "$path" || fail "$label contains an ACL: $path"
        if [[ -f "$path" ]]; then
            require_regular "$path" "$label file"
        fi
    done < <(/usr/bin/find "$root" -print)
}

codesign_value() {
    bounded /usr/bin/codesign -d --verbose=4 "$1" 2>&1 | \
        /usr/bin/awk -F= -v key="$2" '
            $1 == key && !found { value = $2; found = 1 }
            END { if (found) print value; else exit 1 }
        '
}

application_certificate_sha1() {
    local path="$1" prefix="$2"
    bounded /usr/bin/codesign -d "--extract-certificates=$prefix" "$path" \
        >/dev/null 2>&1 || fail "cannot extract application signing certificate"
    require_regular "${prefix}0" "application signing certificate"
    sha1_of "${prefix}0"
}

installer_certificate_sha1() {
    local package="$1" prefix="$2" certificate
    bounded /usr/bin/xar -f "$package" "--dump-toc=$prefix.xml" >/dev/null 2>&1 || \
        fail "cannot inspect installer signing certificate"
    certificate="$({
        /usr/bin/xmllint --xpath \
            'string(/*[local-name()="xar"]/*[local-name()="toc"]/*[local-name()="signature"]/*[local-name()="KeyInfo"]/*[local-name()="X509Data"]/*[local-name()="X509Certificate"][1])' \
            "$prefix.xml"
    } | /usr/bin/tr -d '[:space:]')"
    [[ -n "$certificate" ]] || fail "installer signing certificate is absent"
    printf '%s' "$certificate" | /usr/bin/base64 -D >"$prefix.der" || \
        fail "installer signing certificate is invalid"
    require_regular "$prefix.der" "installer signing certificate"
    sha1_of "$prefix.der"
}

[[ $# -eq 2 ]] || usage
case "$1" in
    --check-package-sha)
        [[ "$2" =~ ^[0-9a-f]{64}$ ]] || fail "package SHA-256 is invalid"
        ! package_sha_is_blocked "$2" || fail "package SHA-256 is permanently blocked"
        printf 'location-probe package SHA-256 policy: PASS\n'
        exit 0
        ;;
    --check-payload-tree)
        [[ "$2" == /* ]] || fail "payload tree must be an absolute path"
        verify_payload_filesystem_safety "$2" "payload tree"
        printf 'location-probe payload tree policy: PASS\n'
        exit 0
        ;;
    --artifact-dir) ;;
    *) usage ;;
esac
ARTIFACT_DIR="$2"
[[ "$ARTIFACT_DIR" == /* ]] || usage
[[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] || fail "artifact directory is unavailable"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd -P)"
readonly ARTIFACT_DIR
[[ "$(/usr/bin/stat -f '%u' "$ARTIFACT_DIR")" == "$EUID" ]] || \
    fail "artifact directory owner differs"
! path_has_acl "$ARTIFACT_DIR" || fail "artifact directory has an ACL"
readonly MANIFEST="$ARTIFACT_DIR/location-probe-artifacts.json"
readonly MARKER="$ARTIFACT_DIR/.location-probe-artifact-root"
require_regular "$MARKER" "artifact marker"
require_regular "$MANIFEST" "artifact manifest"
if [[ "$BOOTSTRAP_AUDIT" == "0" ]]; then
    STATIC_AUDIT="$ARTIFACT_DIR/static-audit.log"
    require_artifact_path "$STATIC_AUDIT" "static audit evidence"
    [[ -s "$STATIC_AUDIT" && "$(/usr/bin/stat -f '%p' "$STATIC_AUDIT")" == "100600" ]] || \
        fail "static audit evidence is empty or has an unsafe mode"
elif [[ "$BOOTSTRAP_AUDIT" != "1" ]]; then
    fail "invalid bootstrap-audit mode"
fi
[[ "$(/usr/bin/stat -f '%p' "$MARKER")" == "100600" && \
    "$(/usr/bin/stat -f '%p' "$MANIFEST")" == "100600" ]] || \
    fail "private artifact metadata mode differs"
[[ "$(json_raw "$MANIFEST" schemaVersion)" == "1" ]] || fail "manifest schema differs"
[[ "$(json_raw "$MANIFEST" applicationIdentifier)" == "$PROBE_BUNDLE_ID" ]] || \
    fail "probe bundle identifier differs"
[[ "$(json_raw "$MANIFEST" helperIdentifier)" == "$PROBE_HELPER_ID" ]] || \
    fail "probe helper identifier differs"
[[ "$(json_raw "$MANIFEST" packageIdentifier)" == "$PROBE_PACKAGE_ID" ]] || \
    fail "probe package identifier differs"
[[ "$PROBE_BUNDLE_ID" != "$PRODUCTION_BUNDLE_ID" && \
    "$PROBE_HELPER_ID" != "$PRODUCTION_HELPER_ID" && \
    "$PROBE_PACKAGE_ID" != "$PRODUCTION_PACKAGE_ID" ]] || \
    fail "probe identifiers overlap production"
SIGNING_MODE="$(json_raw "$MANIFEST" signingMode)"
case "$SIGNING_MODE" in
    adhoc|developer-id) ;;
    *) fail "unsupported signing mode: $SIGNING_MODE" ;;
esac
readonly SIGNING_MODE
MANIFEST_TEAM="$(json_raw "$MANIFEST" teamIdentifier)"
MANIFEST_APPLICATION_IDENTITY="$(json_raw "$MANIFEST" applicationSigningIdentitySHA1)"
MANIFEST_INSTALLER_IDENTITY="$(json_raw "$MANIFEST" installerSigningIdentitySHA1)"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    [[ "$MANIFEST_TEAM" == "$EXPECTED_TEAM" ]] || fail "Developer ID Team differs"
    [[ "$(uppercased "$MANIFEST_APPLICATION_IDENTITY")" == \
        "$EXPECTED_APPLICATION_IDENTITY" ]] || fail "Developer ID Application identity differs"
    [[ "$(uppercased "$MANIFEST_INSTALLER_IDENTITY")" == \
        "$EXPECTED_INSTALLER_IDENTITY" ]] || fail "Developer ID Installer identity differs"
else
    [[ "$MANIFEST_TEAM" == "not-set" ]] || fail "ad-hoc Team marker differs"
    [[ -z "$MANIFEST_APPLICATION_IDENTITY" && -z "$MANIFEST_INSTALLER_IDENTITY" ]] || \
        fail "ad-hoc manifest contains signing identities"
fi
readonly MANIFEST_TEAM MANIFEST_APPLICATION_IDENTITY MANIFEST_INSTALLER_IDENTITY

EXPECTED_VALUES="$(json_raw "$MANIFEST" expectedValuesPath)"
EXPECTED_VALUES_SHA="$(json_raw "$MANIFEST" expectedValuesSHA256)"
CUTOVER_VALUES="$(json_raw "$MANIFEST" cutoverValuesPath)"
CUTOVER_VALUES_SHA="$(json_raw "$MANIFEST" cutoverValuesSHA256)"
SUCCESSOR_PACKAGE_MANIFEST="$ARTIFACT_DIR/successor-package-manifest.json"
[[ "$EXPECTED_VALUES" == "$ARTIFACT_DIR/uat-probe-expected.json" && \
    "$CUTOVER_VALUES" == "$ARTIFACT_DIR/uat-cutover-values.env" ]] || \
    fail "UAT value artifact paths differ"
require_artifact_path "$EXPECTED_VALUES" "UAT expected-values artifact"
require_artifact_path "$CUTOVER_VALUES" "UAT cutover-values artifact"
require_artifact_path "$SUCCESSOR_PACKAGE_MANIFEST" "successor package manifest"
[[ "$(sha256_of "$EXPECTED_VALUES")" == "$EXPECTED_VALUES_SHA" ]] || \
    fail "UAT expected-values hash differs"
[[ "$(sha256_of "$CUTOVER_VALUES")" == "$CUTOVER_VALUES_SHA" ]] || \
    fail "UAT cutover-values hash differs"
[[ "$(/usr/bin/stat -f '%p' "$EXPECTED_VALUES")" == "100600" && \
    "$(/usr/bin/stat -f '%p' "$CUTOVER_VALUES")" == "100600" && \
    "$(/usr/bin/stat -f '%p' "$SUCCESSOR_PACKAGE_MANIFEST")" == "100600" ]] || \
    fail "UAT private-values mode differs"
[[ "$(json_raw "$EXPECTED_VALUES" mode)" == "uat-probe" ]] || \
    fail "UAT expected-values mode differs"
[[ "$(json_raw "$EXPECTED_VALUES" package.identifier)" == "$PROBE_PACKAGE_ID" ]] || \
    fail "UAT expected package identifier differs"
[[ "$(json_raw "$EXPECTED_VALUES" package.staticReceiptState)" == "absent" ]] || \
    fail "UAT clean-install receipt expectation differs"
[[ "$(json_raw "$EXPECTED_VALUES" bundle.identifier)" == "$PROBE_BUNDLE_ID" ]] || \
    fail "UAT expected bundle identifier differs"
[[ "$(json_raw "$EXPECTED_VALUES" bundle.helperIdentifier)" == "$PROBE_HELPER_ID" ]] || \
    fail "UAT expected helper identifier differs"
[[ "$(json_raw "$EXPECTED_VALUES" bundle.mainExecutableName)" == \
    "$PROBE_MAIN_EXECUTABLE" && \
    "$(json_raw "$EXPECTED_VALUES" bundle.helperExecutableName)" == \
    "$PROBE_HELPER_EXECUTABLE" && \
    "$(json_raw "$EXPECTED_VALUES" bundle.launchAgentPlistName)" == \
    "$PROBE_LAUNCH_PLIST" ]] || fail "UAT expected payload identity differs"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    [[ "$(json_raw "$EXPECTED_VALUES" bundle.teamIdentifier)" == "$EXPECTED_TEAM" && \
        "$(uppercased "$MANIFEST_APPLICATION_IDENTITY")" == \
        "$(uppercased "$(json_raw "$EXPECTED_VALUES" bundle.applicationSigningIdentitySHA1)")" ]] || \
        fail "UAT expected signing identity differs"
else
    [[ "$(json_raw "$EXPECTED_VALUES" bundle.teamIdentifier)" == "not set" && \
        -z "$(json_raw "$EXPECTED_VALUES" bundle.applicationSigningIdentitySHA1)" ]] || \
        fail "UAT ad-hoc signing expectation differs"
fi
[[ "$(json_raw "$EXPECTED_VALUES" bundle.secureRoot)" == \
    "/Library/Application Support/JidokaCode-LocationProbe" ]] || \
    fail "UAT secure root differs"
if /usr/bin/plutil -extract database raw -o - "$EXPECTED_VALUES" >/dev/null 2>&1; then
    fail "UAT expected-values artifact contains a database section"
fi
if /usr/bin/grep -Fq "\"$PRODUCTION_PACKAGE_ID\"" "$EXPECTED_VALUES" || \
    /usr/bin/grep -Fq "\"$PRODUCTION_BUNDLE_ID\"" "$EXPECTED_VALUES" || \
    /usr/bin/grep -Fq "\"$PRODUCTION_SECURE_ROOT\"" "$EXPECTED_VALUES"; then
    fail "UAT expected-values artifact names production authority"
fi

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-location-probe-audit.XXXXXX")"
readonly TEMP_ROOT
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

verify_variant() {
    local key="$1"
    local version build install_root relative_app installed_app package_path package_sha observed_package_sha
    local expected_version expected_build expected_install_root expected_relative_app expected_installed_app
    local expanded full package_info bom payload_root app info helper launch_plist app_identifier helper_identifier
    local app_team helper_team signature app_certificate helper_certificate installer_certificate
    local expand_stderr expand_warning_count payload_raw payload_normalized payload_expected path base parent
    version="$(json_raw "$MANIFEST" "$key.version")"
    build="$(json_raw "$MANIFEST" "$key.buildVersion")"
    install_root="$(json_raw "$MANIFEST" "$key.installRoot")"
    relative_app="$(json_raw "$MANIFEST" "$key.payloadRelativeAppPath")"
    installed_app="$(json_raw "$MANIFEST" "$key.installedAppPath")"
    package_path="$(json_raw "$MANIFEST" "$key.packagePath")"
    package_sha="$(json_raw "$MANIFEST" "$key.packageSHA256")"
    case "$key" in
        legacy)
            expected_version="0.1.0"
            expected_build="1"
            expected_install_root="/Applications"
            expected_relative_app="$PROBE_APP_NAME"
            expected_installed_app="/Applications/$PROBE_APP_NAME"
            [[ "$package_path" == "$ARTIFACT_DIR/Jidoka-Code-Location-Probe-0.1.0.pkg" ]] || \
                fail "legacy package path differs"
            ;;
        successor)
            expected_version="0.1.1"
            expected_build="2"
            expected_install_root="/Library/Application Support"
            expected_relative_app="JidokaCode-LocationProbe/Applications/$PROBE_APP_NAME"
            expected_installed_app="/Library/Application Support/$expected_relative_app"
            [[ "$package_path" == "$ARTIFACT_DIR/Jidoka-Code-Location-Probe-0.1.1.pkg" ]] || \
                fail "successor package path differs"
            ;;
        *) fail "unknown package variant: $key" ;;
    esac
    [[ "$version" == "$expected_version" && "$build" == "$expected_build" && \
        "$install_root" == "$expected_install_root" && \
        "$relative_app" == "$expected_relative_app" && \
        "$installed_app" == "$expected_installed_app" ]] || \
        fail "$key manifest authority differs"
    case "$installed_app" in
        "$PRODUCTION_SECURE_ROOT"|"$PRODUCTION_SECURE_ROOT/"*)
            fail "$key package targets the production secure root" ;;
    esac
    require_artifact_path "$package_path" "$key package"
    [[ "$(/usr/bin/stat -f '%p' "$package_path")" == "100644" ]] || \
        fail "$key package mode differs"
    observed_package_sha="$(sha256_of "$package_path")"
    ! package_sha_is_blocked "$observed_package_sha" || \
        fail "$key package SHA-256 is permanently blocked"
    [[ "$package_sha" =~ ^[0-9a-f]{64}$ && \
        "$observed_package_sha" == "$package_sha" ]] || fail "$key package hash differs"

    expanded="$TEMP_ROOT/$key-expanded"
    full="$TEMP_ROOT/$key-full"
    bounded /usr/sbin/pkgutil --expand "$package_path" "$expanded" || \
        fail "$key package expansion failed"
    expand_stderr="$TEMP_ROOT/$key-expand-full.stderr"
    bounded /usr/sbin/pkgutil --expand-full "$package_path" "$full" 2>"$expand_stderr" || \
        fail "$key full expansion failed"
    expand_warning_count=0
    if [[ -s "$expand_stderr" ]]; then
        /usr/bin/awk '$0 != "write: Permission denied" {exit 1}' "$expand_stderr" || \
            fail "$key full expansion produced an unexpected diagnostic"
        expand_warning_count="$(/usr/bin/wc -l <"$expand_stderr" | /usr/bin/tr -d ' ')"
    fi
    package_info="$(/usr/bin/find "$expanded" -type f -name PackageInfo -print)"
    [[ -n "$package_info" && "$(printf '%s\n' "$package_info" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] || \
        fail "$key PackageInfo is ambiguous"
    bom="$(/usr/bin/find "$expanded" -type f -name Bom -print)"
    [[ -n "$bom" && "$(printf '%s\n' "$bom" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] || \
        fail "$key BOM is ambiguous"
    [[ -z "$(/usr/bin/find "$expanded" -type d -name Scripts -print)" ]] || \
        fail "$key package contains scripts"
    [[ "$(/usr/bin/xmllint --xpath \
        "count(/pkg-info[@identifier='$PROBE_PACKAGE_ID' and @version='$version' and @install-location='$install_root' and @postinstall-action='none' and @auth='root' and @relocatable='false'])" \
        "$package_info")" == "1" ]] || fail "$key PackageInfo authority differs"
    [[ "$(/usr/bin/xmllint --xpath 'count(/pkg-info/relocate/bundle)' "$package_info")" == "0" ]] || \
        fail "$key PackageInfo contains relocation authority"
    [[ "$(/usr/bin/xmllint --xpath \
        "count(/pkg-info/bundle[@id='$PROBE_BUNDLE_ID' and @path='./$relative_app'])" \
        "$package_info")" == "1" ]] || fail "$key bundle path differs"
    [[ "$(/usr/bin/xmllint --xpath \
        "count(/pkg-info/strict-identifier/bundle[@id='$PROBE_BUNDLE_ID'])" \
        "$package_info")" == "1" ]] || fail "$key strict identifier differs"
    [[ "$(/usr/bin/xmllint --xpath \
        "count(/pkg-info/upgrade-bundle/bundle[@id='$PROBE_BUNDLE_ID'])" \
        "$package_info")" == "1" ]] || fail "$key upgrade authority differs"

    payload_raw="$TEMP_ROOT/$key-payload-raw.txt"
    payload_normalized="$TEMP_ROOT/$key-payload-normalized.txt"
    payload_expected="$TEMP_ROOT/$key-payload-expected.txt"
    bounded /usr/sbin/pkgutil --payload-files "$package_path" >"$payload_raw" || \
        fail "$key payload inventory is unavailable"
    : >"$payload_normalized"
    while IFS= read -r path; do
        [[ "$path" == "." ]] && continue
        path="${path#./}"
        base="${path##*/}"
        if [[ "$base" == ._* ]]; then
            parent="${path%/*}"
            if [[ "$parent" == "$path" ]]; then
                path="${base#._}"
            else
                path="$parent/${base#._}"
            fi
        fi
        printf '%s\n' "$path" >>"$payload_normalized"
    done <"$payload_raw"
    {
        if [[ "$key" == "successor" ]]; then
            printf '%s\n' "JidokaCode-LocationProbe" "JidokaCode-LocationProbe/Applications"
        fi
        printf '%s\n' \
            "$relative_app" \
            "$relative_app/Contents" \
            "$relative_app/Contents/Helpers" \
            "$relative_app/Contents/Helpers/$PROBE_HELPER_EXECUTABLE" \
            "$relative_app/Contents/Info.plist" \
            "$relative_app/Contents/Library" \
            "$relative_app/Contents/Library/LaunchAgents" \
            "$relative_app/Contents/Library/LaunchAgents/$PROBE_LAUNCH_PLIST" \
            "$relative_app/Contents/MacOS" \
            "$relative_app/Contents/MacOS/$PROBE_MAIN_EXECUTABLE" \
            "$relative_app/Contents/_CodeSignature" \
            "$relative_app/Contents/_CodeSignature/CodeResources"
    } | /usr/bin/sort -u >"$payload_expected"
    /usr/bin/sort -u -o "$payload_normalized" "$payload_normalized"
    /usr/bin/cmp -s "$payload_expected" "$payload_normalized" || \
        fail "$key package payload inventory differs"

    payload_root="$(/usr/bin/find "$full" -type d -name Payload -print)"
    [[ -n "$payload_root" && \
        "$(printf '%s\n' "$payload_root" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] || \
        fail "$key expanded payload root is ambiguous"
    verify_payload_filesystem_safety "$payload_root" "$key payload"
    app="$(/usr/bin/find "$payload_root" -type d -name "$PROBE_APP_NAME" -print)"
    [[ -n "$app" && "$(printf '%s\n' "$app" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] || \
        fail "$key expanded app is ambiguous"
    [[ "$app" == */Payload/"$relative_app" ]] || fail "$key expanded app path differs"
    info="$app/Contents/Info.plist"
    helper="$app/Contents/Helpers/$PROBE_HELPER_EXECUTABLE"
    launch_plist="$app/Contents/Library/LaunchAgents/$PROBE_LAUNCH_PLIST"
    require_regular "$info" "$key Info.plist"
    require_regular "$helper" "$key helper"
    require_regular "$launch_plist" "$key launch agent"
    require_regular "$app/Contents/MacOS/$PROBE_MAIN_EXECUTABLE" "$key main executable"
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info")" == "$PROBE_BUNDLE_ID" && \
        "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$info")" == "$version" && \
        "$(/usr/bin/plutil -extract CFBundleVersion raw "$info")" == "$build" ]] || \
        fail "$key application identity differs"
    [[ "$(/usr/bin/plutil -extract Label raw "$launch_plist")" == "$PROBE_HELPER_ID" && \
        "$(/usr/bin/xmllint --xpath \
            "count(/plist/dict/key[text()='MachServices']/following-sibling::dict[1]/key[text()='$PROBE_HELPER_ID']/following-sibling::*[1][self::true])" \
            "$launch_plist")" == "1" && \
        "$(/usr/bin/plutil -extract BundleProgram raw "$launch_plist")" == \
        "Contents/Helpers/$PROBE_HELPER_EXECUTABLE" ]] || fail "$key launch agent differs"
    bounded /usr/bin/codesign --verify --strict --deep "$app" || \
        fail "$key app signature is invalid"
    app_identifier="$(codesign_value "$app" Identifier)"
    helper_identifier="$(codesign_value "$helper" Identifier)"
    [[ "$app_identifier" == "$PROBE_BUNDLE_ID" && "$helper_identifier" == "$PROBE_HELPER_ID" ]] || \
        fail "$key code identifiers differ"

    bounded /usr/bin/lsbom -p fmug "$bom" >"$TEMP_ROOT/$key-bom.txt" || \
        fail "$key BOM is unreadable"
    /usr/bin/awk -F '\t' '
      $2 ~ /^40/ && $2 != "40755" { exit 1 }
      $2 ~ /^100/ && $1 ~ /\/MacOS\/|\/Helpers\// && $2 != "100755" { exit 1 }
      $2 ~ /^100/ && $1 !~ /\/MacOS\/|\/Helpers\// && $2 != "100644" { exit 1 }
      $3 != 0 || $4 != 0 { exit 1 }
    ' "$TEMP_ROOT/$key-bom.txt" || fail "$key BOM owner or mode differs"
    if [[ "$key" == "successor" ]]; then
        /usr/bin/grep -Fq $'./JidokaCode-LocationProbe\t40755\t0\t0' "$TEMP_ROOT/$key-bom.txt" || \
            fail "successor authority root BOM entry differs"
        /usr/bin/grep -Fq $'./JidokaCode-LocationProbe/Applications\t40755\t0\t0' \
            "$TEMP_ROOT/$key-bom.txt" || fail "successor Applications BOM entry differs"
    fi

    if [[ "$SIGNING_MODE" == "developer-id" ]]; then
        app_team="$(codesign_value "$app" TeamIdentifier)"
        helper_team="$(codesign_value "$helper" TeamIdentifier)"
        [[ "$app_team" == "$MANIFEST_TEAM" && "$helper_team" == "$MANIFEST_TEAM" ]] || \
            fail "$key Developer ID Team differs"
        signature="$(bounded /usr/bin/codesign -d --verbose=4 "$app" 2>&1)"
        [[ "$signature" == *"Authority=Developer ID Application:"* && \
            "$signature" == *"Timestamp="* ]] || fail "$key app lacks Developer ID timestamp"
        signature="$(bounded /usr/bin/codesign -d --verbose=4 "$helper" 2>&1)"
        [[ "$signature" == *"Authority=Developer ID Application:"* && \
            "$signature" == *"Timestamp="* ]] || fail "$key helper lacks Developer ID timestamp"
        app_certificate="$(application_certificate_sha1 "$app" "$TEMP_ROOT/$key-app-cert")"
        helper_certificate="$(application_certificate_sha1 \
            "$helper" "$TEMP_ROOT/$key-helper-cert")"
        [[ "$app_certificate" == "$(uppercased "$MANIFEST_APPLICATION_IDENTITY")" && \
            "$helper_certificate" == "$(uppercased "$MANIFEST_APPLICATION_IDENTITY")" ]] || \
            fail "$key Application certificate fingerprint differs"
        signature="$(bounded /usr/sbin/pkgutil --check-signature "$package_path" 2>&1)" || \
            fail "$key installer signature is invalid"
        [[ "$signature" == *"Developer ID Installer:"* && \
            "$signature" == *"Signed with a trusted timestamp on:"* && \
            "$signature" == *"($MANIFEST_TEAM)"* ]] || \
            fail "$key installer lacks the selected Developer ID timestamp"
        installer_certificate="$(installer_certificate_sha1 \
            "$package_path" "$TEMP_ROOT/$key-installer-cert")"
        [[ "$installer_certificate" == "$(uppercased "$MANIFEST_INSTALLER_IDENTITY")" ]] || \
            fail "$key Installer certificate fingerprint differs"
    else
        [[ "$(codesign_value "$app" TeamIdentifier)" == "not set" ]] || \
            fail "$key ad-hoc app unexpectedly has a Team"
    fi
    printf 'variant=%s version=%s package_sha256=%s install_root=%s payload=%s expand_warnings=%s\n' \
        "$key" "$version" "$package_sha" "$install_root" "$relative_app" \
        "$expand_warning_count"
}

verify_variant legacy
verify_variant successor

ARTIFACT_SET="$ARTIFACT_DIR/artifact-set.txt"
ARTIFACT_SET_SHA="$(json_raw "$MANIFEST" artifactSetSHA256)"
require_artifact_path "$ARTIFACT_SET" "artifact-set inventory"
[[ "$(/usr/bin/stat -f '%p' "$ARTIFACT_SET")" == "100600" ]] || \
    fail "artifact-set inventory mode differs"
[[ "$(sha256_of "$ARTIFACT_SET")" == "$ARTIFACT_SET_SHA" ]] || \
    fail "artifact-set inventory hash differs"
bounded /usr/bin/shasum -a 256 -c "$ARTIFACT_SET" >/dev/null || \
    fail "artifact-set member hash differs"
ARTIFACT_MANIFEST_SHA="$(sha256_of "$MANIFEST")"
if [[ "$BOOTSTRAP_AUDIT" == "0" ]]; then
    STATIC_AUDIT_SHA="$(sha256_of "$STATIC_AUDIT")"
else
    STATIC_AUDIT_SHA="pending"
fi
readonly ARTIFACT_MANIFEST_SHA STATIC_AUDIT_SHA

printf 'location-probe audit: PASS artifact_dir=%s artifact_set_sha256=%s artifact_manifest_sha256=%s static_audit_sha256=%s signing=%s\n' \
    "$ARTIFACT_DIR" "$ARTIFACT_SET_SHA" "$ARTIFACT_MANIFEST_SHA" \
    "$STATIC_AUDIT_SHA" "$SIGNING_MODE"
