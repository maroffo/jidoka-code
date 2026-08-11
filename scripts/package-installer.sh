#!/usr/bin/env bash
set -euo pipefail

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly ROOT
readonly BUILD_ROOT="$ROOT/build"
readonly APP="$BUILD_ROOT/Jidoka Code.app"
readonly PACKAGE="$BUILD_ROOT/Jidoka Code.pkg"
readonly PACKAGE_MANIFEST="$BUILD_ROOT/package-manifest.json"
readonly PACKAGE_IDENTIFIER="com.maroffo.JidokaCode.pkg"
readonly INSTALL_LOCATION="/Applications"
readonly SIGN_IDENTITY="${SIGN_IDENTITY:-}"
TEMP_ROOT=""

fail() {
    printf 'installer packaging failed: %s\n' "$1" >&2
    exit 1
}

cleanup_owned_path() {
    local path="$1"
    local name
    [[ -n "$path" && -d "$path" && ! -L "$path" ]] || return 1
    name="$(/usr/bin/basename "$path")"
    case "$name" in
        jidoka-code-package.*) /bin/rm -rf -- "$path" ;;
        *) return 1 ;;
    esac
}

cleanup() {
    if [[ -n "$TEMP_ROOT" && -e "$TEMP_ROOT" ]]; then
        cleanup_owned_path "$TEMP_ROOT" || \
            printf 'refusing unexpected cleanup path: %s\n' "$TEMP_ROOT" >&2
    fi
}

[[ "$SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || \
    fail "SIGN_IDENTITY must name one explicit Apple code-signing identity"
[[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] || /bin/mkdir -p "$BUILD_ROOT"
[[ "$(cd "$BUILD_ROOT" && pwd -P)" == "$ROOT/build" ]] || \
    fail "build root escapes repository"

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-package.XXXXXX")"
readonly TEMP_ROOT
trap cleanup EXIT
readonly COMPONENT_PACKAGE="$TEMP_ROOT/JidokaCode-component.pkg"
readonly PRODUCT_PACKAGE="$TEMP_ROOT/Jidoka Code.pkg"
readonly EXPANDED_PACKAGE="$TEMP_ROOT/expanded"
readonly RAW_PAYLOAD_LIST="$TEMP_ROOT/payload-raw.txt"
readonly PAYLOAD_LIST="$TEMP_ROOT/payload.txt"
readonly METADATA_PAYLOAD_LIST="$TEMP_ROOT/payload-metadata.txt"
readonly EXPECTED_PAYLOAD_LIST="$TEMP_ROOT/expected-payload.txt"

ALLOW_ADHOC_SIGNING=0 "$ROOT/scripts/package-app.sh"
[[ -d "$APP" && ! -L "$APP" ]] || fail "signed application bundle is missing"
/usr/bin/codesign --verify --strict --deep "$APP"

app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
app_bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
[[ "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid application version"
[[ "$app_bundle_identifier" == "com.maroffo.JidokaCode.Probe" ]] || \
    fail "unexpected application bundle identifier"
if LC_ALL=C /usr/bin/grep -R -F -l "$ROOT" "$APP" >/dev/null 2>&1; then
    fail "signed application contains its checkout path"
elif [[ "$?" -ne 1 ]]; then
    fail "could not audit the signed application for checkout paths"
fi

/usr/bin/pkgbuild \
    --component "$APP" \
    --install-location "$INSTALL_LOCATION" \
    --identifier "$PACKAGE_IDENTIFIER" \
    --version "$app_version" \
    "$COMPONENT_PACKAGE"
/usr/bin/productbuild --package "$COMPONENT_PACKAGE" "$PRODUCT_PACKAGE"
[[ -f "$PRODUCT_PACKAGE" && ! -L "$PRODUCT_PACKAGE" ]] || fail "product package is missing"

/usr/sbin/pkgutil --payload-files "$PRODUCT_PACKAGE" >"$RAW_PAYLOAD_LIST"
while IFS= read -r path; do
    [[ "$path" == "." ]] && continue
    path="${path#./}"
    base="${path##*/}"
    if [[ "$base" == ._* ]]; then
        parent="${path%/*}"
        original="${base#._}"
        if [[ "$parent" == "$path" ]]; then
            printf '%s\n' "$original" >>"$METADATA_PAYLOAD_LIST"
        else
            printf '%s/%s\n' "$parent" "$original" >>"$METADATA_PAYLOAD_LIST"
        fi
    else
        printf '%s\n' "$path" >>"$PAYLOAD_LIST"
    fi
done <"$RAW_PAYLOAD_LIST"
/usr/bin/awk '
    $0 == "." { print "Jidoka Code.app"; next }
    /^\.\// { print "Jidoka Code.app/" substr($0, 3); next }
    { exit 2 }
' "$ROOT/Packaging/app-inventory.txt" >"$EXPECTED_PAYLOAD_LIST" || \
    fail "invalid application inventory"
LC_ALL=C /usr/bin/sort -o "$EXPECTED_PAYLOAD_LIST" "$EXPECTED_PAYLOAD_LIST"
LC_ALL=C /usr/bin/sort -o "$PAYLOAD_LIST" "$PAYLOAD_LIST"
LC_ALL=C /usr/bin/sort -o "$METADATA_PAYLOAD_LIST" "$METADATA_PAYLOAD_LIST"
/usr/bin/cmp -s "$PAYLOAD_LIST" "$EXPECTED_PAYLOAD_LIST" || \
    fail "installer payload differs from the signed application inventory"
/usr/bin/cmp -s "$METADATA_PAYLOAD_LIST" "$EXPECTED_PAYLOAD_LIST" || \
    fail "installer extended-attribute inventory differs from the application inventory"

/usr/sbin/pkgutil --expand "$PRODUCT_PACKAGE" "$EXPANDED_PACKAGE"
[[ -z "$(/usr/bin/find "$EXPANDED_PACKAGE" -type d -name Scripts -print)" ]] || \
    fail "installer unexpectedly contains scripts"
[[ -z "$(/usr/bin/find "$EXPANDED_PACKAGE" -type f \( -name preinstall -o -name postinstall \) -print)" ]] || \
    fail "installer unexpectedly contains lifecycle scripts"
package_info="$(/usr/bin/find "$EXPANDED_PACKAGE" -type f -name PackageInfo -print)"
[[ "$(printf '%s\n' "$package_info" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] || \
    fail "installer PackageInfo is ambiguous"
/usr/bin/grep -Fq "identifier=\"$PACKAGE_IDENTIFIER\"" "$package_info" || \
    fail "installer identifier differs"
/usr/bin/grep -Fq "version=\"$app_version\"" "$package_info" || \
    fail "installer version differs"
/usr/bin/grep -Fq "install-location=\"$INSTALL_LOCATION\"" "$package_info" || \
    fail "installer location differs"
/usr/bin/grep -Fq 'relocatable="false"' "$package_info" || \
    fail "installer payload must not be relocatable"
/usr/bin/grep -Fq 'postinstall-action="none"' "$package_info" || \
    fail "installer postinstall action differs"
readonly DISTRIBUTION="$EXPANDED_PACKAGE/Distribution"
[[ -f "$DISTRIBUTION" && ! -L "$DISTRIBUTION" ]] || fail "installer distribution is missing"
/usr/bin/grep -Fq 'require-scripts="false"' "$DISTRIBUTION" || \
    fail "installer distribution unexpectedly allows scripts"
/usr/bin/grep -Fq 'onConclusion="none"' "$DISTRIBUTION" || \
    fail "installer conclusion action differs"
/usr/bin/grep -Fq "id=\"$app_bundle_identifier\" path=\"Jidoka Code.app\"" "$DISTRIBUTION" || \
    fail "installer bundle identity differs"
set +e
package_signature="$(/usr/sbin/pkgutil --check-signature "$PRODUCT_PACKAGE" 2>&1)"
package_signature_status=$?
set -e
[[ "$package_signature_status" == "1" && \
    "$package_signature" == *"Status: no signature"* ]] || \
    fail "local installer has an unexpected package signature"

if [[ -e "$PACKAGE" || -L "$PACKAGE" ]]; then
    [[ -f "$PACKAGE" && ! -L "$PACKAGE" ]] || fail "refusing unsafe package output"
    /bin/rm -f -- "$PACKAGE"
fi
/usr/bin/install -m 0644 "$PRODUCT_PACKAGE" "$PACKAGE"
package_sha256="$(/usr/bin/shasum -a 256 "$PACKAGE" | /usr/bin/awk '{print $1}')"
host_sha256="$(/usr/bin/shasum -a 256 "$APP/Contents/Helpers/JidokaCodeHerdrHost" | /usr/bin/awk '{print $1}')"
inventory_sha256="$(/usr/bin/shasum -a 256 "$ROOT/Packaging/app-inventory.txt" | /usr/bin/awk '{print $1}')"
herdr_policy_sha256="$(/usr/bin/shasum -a 256 "$APP/Contents/Resources/Herdr/runtime-builds.json" | /usr/bin/awk '{print $1}')"
herdr_schema_sha256="$(/usr/bin/shasum -a 256 "$APP/Contents/Resources/Herdr/api-schema-0.8.0.json" | /usr/bin/awk '{print $1}')"
minimum_os_version="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")"
app_team="$(/usr/bin/codesign -dvvv "$APP" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
host_team="$(/usr/bin/codesign -dvvv "$APP/Contents/Helpers/JidokaCodeHerdrHost" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
[[ -n "$app_team" && "$app_team" != "not set" && "$app_team" == "$host_team" ]] || \
    fail "application and Herdr host signing teams differ"
[[ "$herdr_policy_sha256" == \
    "3fdd7b5d6f273ab264c6c2f502e8c8902819cc353052191769c4ec22213d4673" ]] || \
    fail "installer Herdr policy digest differs"
[[ "$herdr_schema_sha256" == \
    "88ff414aa996e390c2db05a37b95d28dbe4e81b98329f6ed7f7a2cc5c6ebf51a" ]] || \
    fail "installer Herdr schema digest differs"
[[ "$minimum_os_version" == "14.0" ]] || fail "installer minimum OS differs"

printf '%s\n' \
    "{\"appBundleIdentifier\":\"$app_bundle_identifier\",\"appInventorySHA256\":\"$inventory_sha256\",\"appVersion\":\"$app_version\",\"herdrBundled\":false,\"herdrHostSHA256\":\"$host_sha256\",\"herdrPolicySHA256\":\"$herdr_policy_sha256\",\"herdrSchemaSHA256\":\"$herdr_schema_sha256\",\"installLocation\":\"/Applications/Jidoka Code.app\",\"installerScripts\":false,\"minimumOSVersion\":\"$minimum_os_version\",\"packageIdentifier\":\"$PACKAGE_IDENTIFIER\",\"packageSHA256\":\"$package_sha256\",\"packageSigned\":false,\"schemaVersion\":1,\"signingTeamIdentifier\":\"$app_team\"}" \
    >"$PACKAGE_MANIFEST"
/usr/bin/plutil -convert xml1 -o /dev/null "$PACKAGE_MANIFEST"

printf 'package=%s\n' "$PACKAGE"
printf 'package_sha256=%s\n' "$package_sha256"
printf 'package_identifier=%s\n' "$PACKAGE_IDENTIFIER"
printf 'install_location=/Applications/Jidoka Code.app\n'
printf 'nested_signing=identity\n'
printf 'package_signing=unsigned-local\n'
