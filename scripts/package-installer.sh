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
readonly NOTARIZATION_RESULT="$BUILD_ROOT/notarization-result.json"
readonly PACKAGE_IDENTIFIER="com.maroffo.JidokaCode.pkg"
readonly INSTALL_LOCATION="/Applications"
readonly SIGN_IDENTITY="${SIGN_IDENTITY:-}"
readonly INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
readonly SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"
readonly NOTARIZE_PACKAGE="${NOTARIZE_PACKAGE:-0}"
readonly NOTARY_KEY="${NOTARY_KEY:-}"
readonly NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
readonly NOTARY_ISSUER="${NOTARY_ISSUER:-}"
PRODUCTBUILD_KEYCHAIN_ARGUMENTS=()
SECURITY_KEYCHAIN_ARGUMENTS=()
TEMP_ROOT=""

fail() {
    printf 'installer packaging failed: %s\n' "$1" >&2
    exit 1
}

configure_signing_keychain() {
    local canonical_parent
    if [[ -z "$SIGNING_KEYCHAIN" ]]; then
        return
    fi
    [[ "$SIGNING_KEYCHAIN" == /* && -f "$SIGNING_KEYCHAIN" && ! -L "$SIGNING_KEYCHAIN" ]] || \
        fail "SIGNING_KEYCHAIN must be an absolute regular keychain file"
    canonical_parent="$(cd "$(/usr/bin/dirname "$SIGNING_KEYCHAIN")" && pwd -P)"
    [[ "$canonical_parent/$(/usr/bin/basename "$SIGNING_KEYCHAIN")" == "$SIGNING_KEYCHAIN" ]] || \
        fail "SIGNING_KEYCHAIN must be canonical"
    PRODUCTBUILD_KEYCHAIN_ARGUMENTS=(--keychain "$SIGNING_KEYCHAIN")
    SECURITY_KEYCHAIN_ARGUMENTS=("$SIGNING_KEYCHAIN")
}

verify_identity() {
    local identity="$1"
    local policy="$2"
    local name="$3"
    local identities
    identities="$(
        /usr/bin/security find-identity -v -p "$policy" \
            "${SECURITY_KEYCHAIN_ARGUMENTS[@]}" 2>/dev/null
    )"
    printf '%s\n' "$identities" | /usr/bin/awk -v expected="$identity" '
        toupper($2) == toupper(expected) { found = 1 }
        END { exit(found ? 0 : 1) }
    ' || fail "$name is not a valid local identity"
}

certificate_sha256_for_identity() {
    local identity="$1"
    local certificates
    certificates="$(
        /usr/bin/security find-certificate -a -Z \
            "${SECURITY_KEYCHAIN_ARGUMENTS[@]}" 2>/dev/null
    )"
    /usr/bin/awk -v expected="$identity" '
        /^SHA-256 hash:/ { current = toupper($3) }
        /^SHA-1 hash:/ && toupper($3) == toupper(expected) && !found {
            print current
            found = 1
        }
        END { if (!found) exit 1 }
    ' <<<"$certificates"
}

validate_notarization_configuration() {
    local canonical_parent
    local key_mode
    local key_owner
    local key_links
    [[ "$NOTARIZE_PACKAGE" == "0" || "$NOTARIZE_PACKAGE" == "1" ]] || \
        fail "NOTARIZE_PACKAGE must be 0 or 1"
    if [[ "$NOTARIZE_PACKAGE" == "0" ]]; then
        [[ -z "$NOTARY_KEY" && -z "$NOTARY_KEY_ID" && -z "$NOTARY_ISSUER" ]] || \
            fail "notary credentials require NOTARIZE_PACKAGE=1"
        return
    fi
    [[ "$NOTARY_KEY" == /* && -f "$NOTARY_KEY" && ! -L "$NOTARY_KEY" ]] || \
        fail "NOTARY_KEY must be an absolute regular private-key file"
    canonical_parent="$(cd "$(/usr/bin/dirname "$NOTARY_KEY")" && pwd -P)"
    [[ "$canonical_parent/$(/usr/bin/basename "$NOTARY_KEY")" == "$NOTARY_KEY" ]] || \
        fail "NOTARY_KEY must be canonical"
    key_mode="$(/usr/bin/stat -f '%OLp' "$NOTARY_KEY")"
    key_owner="$(/usr/bin/stat -f '%u' "$NOTARY_KEY")"
    key_links="$(/usr/bin/stat -f '%l' "$NOTARY_KEY")"
    [[ "$key_mode" == "400" || "$key_mode" == "600" ]] || \
        fail "NOTARY_KEY permissions must be 0400 or 0600"
    [[ "$key_owner" == "$(/usr/bin/id -u)" && "$key_links" == "1" ]] || \
        fail "NOTARY_KEY ownership or link count is unsafe"
    /usr/bin/openssl pkey -in "$NOTARY_KEY" -noout >/dev/null 2>&1 || \
        fail "NOTARY_KEY is not a valid private key"
    [[ "$NOTARY_KEY_ID" =~ ^[A-Z0-9]{10,}$ ]] || fail "NOTARY_KEY_ID is invalid"
    [[ "$NOTARY_ISSUER" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || \
        fail "NOTARY_ISSUER is invalid"
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
[[ "$INSTALLER_SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || \
    fail "INSTALLER_SIGN_IDENTITY must name one explicit installer identity"
validate_notarization_configuration
configure_signing_keychain
readonly -a PRODUCTBUILD_KEYCHAIN_ARGUMENTS SECURITY_KEYCHAIN_ARGUMENTS
verify_identity "$SIGN_IDENTITY" codesigning SIGN_IDENTITY
verify_identity "$INSTALLER_SIGN_IDENTITY" basic INSTALLER_SIGN_IDENTITY
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
readonly NOTARY_RESPONSE="$TEMP_ROOT/notarization-result.json"
readonly SPCTL_OUTPUT="$TEMP_ROOT/spctl-package.txt"

if ! /usr/bin/env \
    SIGN_IDENTITY="$SIGN_IDENTITY" \
    SIGNING_KEYCHAIN="$SIGNING_KEYCHAIN" \
    ALLOW_ADHOC_SIGNING=0 \
    "$ROOT/scripts/package-app.sh"
then
    fail "application packaging failed"
fi
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
/usr/bin/productbuild \
    --package "$COMPONENT_PACKAGE" \
    --sign "$INSTALLER_SIGN_IDENTITY" \
    "${PRODUCTBUILD_KEYCHAIN_ARGUMENTS[@]}" \
    "$PRODUCT_PACKAGE"
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
package_notarized=false
notarization_submission_id=""
notarization_result_sha256=""
if [[ "$NOTARIZE_PACKAGE" == "1" ]]; then
    if ! /usr/bin/xcrun notarytool submit "$PRODUCT_PACKAGE" \
        --key "$NOTARY_KEY" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER" \
        --wait \
        --output-format json \
        >"$NOTARY_RESPONSE"
    then
        fail "Apple notarization submission failed"
    fi
    /usr/bin/plutil -convert xml1 -o /dev/null "$NOTARY_RESPONSE"
    [[ "$(/usr/bin/plutil -extract status raw "$NOTARY_RESPONSE")" == "Accepted" ]] || \
        fail "Apple notarization did not accept the package"
    notarization_submission_id="$(/usr/bin/plutil -extract id raw "$NOTARY_RESPONSE")"
    [[ "$notarization_submission_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || \
        fail "Apple notarization response has an invalid submission ID"
    /usr/bin/xcrun stapler staple "$PRODUCT_PACKAGE"
    /usr/bin/xcrun stapler validate "$PRODUCT_PACKAGE"
    if ! /usr/sbin/spctl -a -vv -t install "$PRODUCT_PACKAGE" >"$SPCTL_OUTPUT" 2>&1; then
        fail "Gatekeeper rejected the notarized installer"
    fi
    /usr/bin/grep -Fq 'source=Notarized Developer ID' "$SPCTL_OUTPUT" || \
        fail "Gatekeeper did not report a notarized Developer ID package"
    package_notarized=true
    notarization_result_sha256="$(
        /usr/bin/shasum -a 256 "$NOTARY_RESPONSE" | /usr/bin/awk '{print $1}'
    )"
fi
if ! package_signature="$(LC_ALL=C /usr/sbin/pkgutil --check-signature "$PRODUCT_PACKAGE" 2>&1)"; then
    fail "installer signature verification failed"
fi
[[ "$package_signature" == \
    *"Status: signed by a developer certificate issued by Apple for distribution"* ]] || \
    fail "installer is not signed for Developer ID distribution"
[[ "$package_signature" == *"Signed with a trusted timestamp on:"* ]] || \
    fail "installer signature lacks a trusted timestamp"
if [[ "$package_notarized" == "true" ]]; then
    [[ "$package_signature" == \
        *"Notarization: trusted by the Apple notary service"* ]] || \
        fail "installer lacks trusted Apple notarization evidence"
fi
package_signer="$(
    /usr/bin/awk '
        /^    1\. Developer ID Installer:/ && !found {
            sub(/^    1\. /, "")
            print
            found = 1
        }
    ' <<<"$package_signature"
)"
[[ -n "$package_signer" ]] || fail "installer signer is missing"
package_certificate_sha256="$(
    /usr/bin/awk '
        /SHA256 Fingerprint:/ && !seen { capture = 1; seen = 1; next }
        capture && /^       -/ { capture = 0 }
        capture {
            for (field = 1; field <= NF; field += 1) {
                if ($field ~ /^[0-9A-F][0-9A-F]$/) fingerprint = fingerprint $field
            }
        }
        END { print fingerprint }
    ' <<<"$package_signature"
)"
[[ "$package_certificate_sha256" =~ ^[0-9A-F]{64}$ ]] || \
    fail "installer certificate fingerprint is invalid"

if [[ -e "$PACKAGE" || -L "$PACKAGE" ]]; then
    [[ -f "$PACKAGE" && ! -L "$PACKAGE" ]] || fail "refusing unsafe package output"
    /bin/rm -f -- "$PACKAGE"
fi
/usr/bin/install -m 0644 "$PRODUCT_PACKAGE" "$PACKAGE"
if [[ "$package_notarized" == "true" ]]; then
    /usr/bin/install -m 0644 "$NOTARY_RESPONSE" "$NOTARIZATION_RESULT"
elif [[ -e "$NOTARIZATION_RESULT" || -L "$NOTARIZATION_RESULT" ]]; then
    [[ -f "$NOTARIZATION_RESULT" && ! -L "$NOTARIZATION_RESULT" ]] || \
        fail "refusing unsafe notarization-result output"
    /bin/rm -f -- "$NOTARIZATION_RESULT"
fi
package_sha256="$(/usr/bin/shasum -a 256 "$PACKAGE" | /usr/bin/awk '{print $1}')"
host_sha256="$(/usr/bin/shasum -a 256 "$APP/Contents/Helpers/JidokaCodeHerdrHost" | /usr/bin/awk '{print $1}')"
inventory_sha256="$(/usr/bin/shasum -a 256 "$ROOT/Packaging/app-inventory.txt" | /usr/bin/awk '{print $1}')"
herdr_policy_sha256="$(/usr/bin/shasum -a 256 "$APP/Contents/Resources/Herdr/runtime-builds.json" | /usr/bin/awk '{print $1}')"
herdr_schema_sha256="$(/usr/bin/shasum -a 256 "$APP/Contents/Resources/Herdr/api-schema-0.8.0.json" | /usr/bin/awk '{print $1}')"
minimum_os_version="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")"
app_signature="$(/usr/bin/codesign -d --verbose=4 "$APP" 2>&1)"
app_team="$(
    /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2}' <<<"$app_signature"
)"
host_team="$(/usr/bin/codesign -dvvv "$APP/Contents/Helpers/JidokaCodeHerdrHost" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
[[ "$app_signature" == *"Authority=Developer ID Application:"* ]] || \
    fail "application is not signed with Developer ID Application"
[[ "$app_signature" == *"Timestamp="* ]] || \
    fail "application signature lacks a trusted timestamp"
[[ -n "$app_team" && "$app_team" != "not set" && "$app_team" == "$host_team" ]] || \
    fail "application and Herdr host signing teams differ"
if ! installer_certificate_sha256="$(
    certificate_sha256_for_identity "$INSTALLER_SIGN_IDENTITY"
)"; then
    fail "installer signing certificate is unavailable"
fi
[[ "$package_certificate_sha256" == "$installer_certificate_sha256" ]] || \
    fail "installer package certificate differs from the selected identity"
[[ "$package_signer" == Developer\ ID\ Installer:*"($app_team)" ]] || \
    fail "application and installer signing teams differ"
[[ "$herdr_policy_sha256" == \
    "3fdd7b5d6f273ab264c6c2f502e8c8902819cc353052191769c4ec22213d4673" ]] || \
    fail "installer Herdr policy digest differs"
[[ "$herdr_schema_sha256" == \
    "88ff414aa996e390c2db05a37b95d28dbe4e81b98329f6ed7f7a2cc5c6ebf51a" ]] || \
    fail "installer Herdr schema digest differs"
[[ "$minimum_os_version" == "14.0" ]] || fail "installer minimum OS differs"

if [[ "$package_notarized" == "true" ]]; then
    printf '%s\n' \
        "{\"appBundleIdentifier\":\"$app_bundle_identifier\",\"applicationSigningIdentitySHA1\":\"$SIGN_IDENTITY\",\"appInventorySHA256\":\"$inventory_sha256\",\"appVersion\":\"$app_version\",\"herdrBundled\":false,\"herdrHostSHA256\":\"$host_sha256\",\"herdrPolicySHA256\":\"$herdr_policy_sha256\",\"herdrSchemaSHA256\":\"$herdr_schema_sha256\",\"installLocation\":\"/Applications/Jidoka Code.app\",\"installerScripts\":false,\"installerSigningCertificateSHA256\":\"$installer_certificate_sha256\",\"installerSigningIdentitySHA1\":\"$INSTALLER_SIGN_IDENTITY\",\"minimumOSVersion\":\"$minimum_os_version\",\"notarizationResultSHA256\":\"$notarization_result_sha256\",\"notarizationSubmissionID\":\"$notarization_submission_id\",\"packageIdentifier\":\"$PACKAGE_IDENTIFIER\",\"packageNotarized\":true,\"packageSHA256\":\"$package_sha256\",\"packageSigned\":true,\"schemaVersion\":3,\"signingTeamIdentifier\":\"$app_team\",\"trustedTimestamp\":true}" \
        >"$PACKAGE_MANIFEST"
else
    printf '%s\n' \
        "{\"appBundleIdentifier\":\"$app_bundle_identifier\",\"applicationSigningIdentitySHA1\":\"$SIGN_IDENTITY\",\"appInventorySHA256\":\"$inventory_sha256\",\"appVersion\":\"$app_version\",\"herdrBundled\":false,\"herdrHostSHA256\":\"$host_sha256\",\"herdrPolicySHA256\":\"$herdr_policy_sha256\",\"herdrSchemaSHA256\":\"$herdr_schema_sha256\",\"installLocation\":\"/Applications/Jidoka Code.app\",\"installerScripts\":false,\"installerSigningCertificateSHA256\":\"$installer_certificate_sha256\",\"installerSigningIdentitySHA1\":\"$INSTALLER_SIGN_IDENTITY\",\"minimumOSVersion\":\"$minimum_os_version\",\"packageIdentifier\":\"$PACKAGE_IDENTIFIER\",\"packageNotarized\":false,\"packageSHA256\":\"$package_sha256\",\"packageSigned\":true,\"schemaVersion\":2,\"signingTeamIdentifier\":\"$app_team\",\"trustedTimestamp\":true}" \
        >"$PACKAGE_MANIFEST"
fi
/usr/bin/plutil -convert xml1 -o /dev/null "$PACKAGE_MANIFEST"

printf 'package=%s\n' "$PACKAGE"
printf 'package_sha256=%s\n' "$package_sha256"
printf 'package_identifier=%s\n' "$PACKAGE_IDENTIFIER"
printf 'install_location=/Applications/Jidoka Code.app\n'
printf 'nested_signing=developer-id\n'
printf 'package_signing=developer-id-installer\n'
printf 'package_notarized=%s\n' "$package_notarized"
if [[ "$package_notarized" == "true" ]]; then
    printf 'notarization_submission_id=%s\n' "$notarization_submission_id"
fi
