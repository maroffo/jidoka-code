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
readonly RUNTIME_INVENTORY="$BUILD_ROOT/runtime-inventory.txt"
readonly RELEASE_RUNTIME_INPUT="${JIDOKA_RELEASE_RUNTIME_ROOT:-}"
readonly PACKAGE="$BUILD_ROOT/Jidoka Code.pkg"
readonly PACKAGE_MANIFEST="$BUILD_ROOT/package-manifest.json"
readonly NOTARIZATION_RESULT="$BUILD_ROOT/notarization-result.json"
BOUNDED_COMMAND=""
readonly PACKAGE_TOOL_TIMEOUT_SECONDS=300
readonly APPLICATION_IDENTIFIER="com.maroffo.JidokaCode"
readonly PACKAGE_IDENTIFIER="com.maroffo.JidokaCode.pkg"
readonly INSTALL_LOCATION="/Library/Application Support"
readonly COMPONENT_APP_RELATIVE_PATH="JidokaCode/Applications/Jidoka Code.app"
readonly INSTALL_APP_PATH="$INSTALL_LOCATION/$COMPONENT_APP_RELATIVE_PATH"
readonly COMPONENT_POLICY="$ROOT/Packaging/app-component.plist"
readonly SIGN_IDENTITY="${SIGN_IDENTITY:-}"
readonly INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
readonly SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"
readonly APPLICATION_SIGNING_KEYCHAIN="${APPLICATION_SIGNING_KEYCHAIN:-$SIGNING_KEYCHAIN}"
readonly INSTALLER_SIGNING_KEYCHAIN="${INSTALLER_SIGNING_KEYCHAIN:-$SIGNING_KEYCHAIN}"
readonly NOTARIZE_PACKAGE="${NOTARIZE_PACKAGE:-0}"
readonly NOTARY_KEY="${NOTARY_KEY:-}"
readonly NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
readonly NOTARY_ISSUER="${NOTARY_ISSUER:-}"
TEMP_ROOT=""

fail() {
    printf 'installer packaging failed: %s\n' "$1" >&2
    exit 1
}

path_has_allow_acl() {
    /bin/ls -lde "$1" | /usr/bin/awk '
        NR > 1 && $0 ~ / allow / { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

run_package_tool() {
    local name="$1"
    local status=0
    shift
    (
        cd /
        "$BOUNDED_COMMAND" "$PACKAGE_TOOL_TIMEOUT_SECONDS" "$@"
    ) || status=$?
    if [[ "$status" == "124" ]]; then
        fail "$name exceeded ${PACKAGE_TOOL_TIMEOUT_SECONDS}s"
    elif [[ "$status" != "0" ]]; then
        fail "$name failed"
    fi
}

validate_signing_keychain() {
    local keychain="$1"
    local name="$2"
    local canonical_parent
    if [[ -z "$keychain" ]]; then
        return
    fi
    [[ "$keychain" == /* && -f "$keychain" && ! -L "$keychain" ]] || \
        fail "$name must be an absolute regular keychain file"
    canonical_parent="$(cd "$(/usr/bin/dirname "$keychain")" && pwd -P)"
    [[ "$canonical_parent/$(/usr/bin/basename "$keychain")" == "$keychain" ]] || \
        fail "$name must be canonical"
}

verify_identity() {
    local identity="$1"
    local policy="$2"
    local name="$3"
    local keychain="$4"
    local identities
    if [[ -n "$keychain" ]]; then
        identities="$(/usr/bin/security find-identity -v -p "$policy" "$keychain" 2>/dev/null)"
    else
        identities="$(/usr/bin/security find-identity -v -p "$policy" 2>/dev/null)"
    fi
    printf '%s\n' "$identities" | /usr/bin/awk -v expected="$identity" '
        toupper($2) == toupper(expected) { found = 1 }
        END { exit(found ? 0 : 1) }
    ' || fail "$name is not a valid local identity"
}

certificate_sha256_for_identity() {
    local identity="$1"
    local keychain="$2"
    local certificates
    if [[ -n "$keychain" ]]; then
        certificates="$(/usr/bin/security find-certificate -a -Z "$keychain" 2>/dev/null)"
    else
        certificates="$(/usr/bin/security find-certificate -a -Z 2>/dev/null)"
    fi
    /usr/bin/awk -v expected="$identity" '
        /^SHA-256 hash:/ { current = toupper($3) }
        /^SHA-1 hash:/ && toupper($3) == toupper(expected) && !found {
            print current
            found = 1
        }
        END { if (!found) exit 1 }
    ' <<<"$certificates"
}

validate_component_policy() {
    /usr/bin/plutil -lint "$COMPONENT_POLICY" >/dev/null || \
        fail "application component policy is invalid"
    [[ "$(/usr/bin/xmllint --xpath 'count(/plist/array/dict)' "$COMPONENT_POLICY")" == "1" && \
        "$(/usr/bin/xmllint --xpath 'count(/plist/array/dict/key)' "$COMPONENT_POLICY")" == "5" ]] || \
        fail "application component policy shape differs"
    for key in \
        RootRelativeBundlePath BundleIsRelocatable BundleIsVersionChecked \
        BundleHasStrictIdentifier BundleOverwriteAction
    do
        [[ "$(/usr/bin/xmllint --xpath "count(/plist/array/dict/key[text()='$key'])" "$COMPONENT_POLICY")" == "1" ]] || \
            fail "application component policy keys differ"
    done
    [[ "$(/usr/bin/plutil -extract 0.RootRelativeBundlePath raw "$COMPONENT_POLICY")" == \
        "$COMPONENT_APP_RELATIVE_PATH" && \
        "$(/usr/bin/plutil -extract 0.BundleIsRelocatable raw "$COMPONENT_POLICY")" == "false" && \
        "$(/usr/bin/plutil -extract 0.BundleIsVersionChecked raw "$COMPONENT_POLICY")" == "true" && \
        "$(/usr/bin/plutil -extract 0.BundleHasStrictIdentifier raw "$COMPONENT_POLICY")" == "true" && \
        "$(/usr/bin/plutil -extract 0.BundleOverwriteAction raw "$COMPONENT_POLICY")" == "upgrade" ]] || \
        fail "application component policy values differ"
}

write_application_tree_inventory() {
    local root="$1"
    local output="$2"
    local mode
    local path
    local target
    [[ -d "$root" && ! -L "$root" ]] || fail "application inventory root is unsafe"
    (
        cd "$root"
        while IFS= read -r -d '' path; do
            case "$path" in
                *$'\t'*|*$'\n'*|*$'\r'*)
                    fail "application inventory path contains a control character"
                    ;;
            esac
            mode="$(/usr/bin/stat -f '%OLp' "$path")"
            if [[ -L "$path" ]]; then
                if ! target="$(
                    /usr/bin/perl -e '
                      my $value = readlink($ARGV[0]);
                      exit 2 unless defined $value;
                      exit 3 if $value =~ /[\x09\x0a\x0d]/;
                      print $value;
                    ' "$path"
                )"; then
                    fail "application inventory symbolic-link target is unsafe"
                fi
                printf 'symbolicLink\t%s\t%s\t%s\n' "$path" "$mode" "$target"
            elif [[ -d "$path" ]]; then
                printf 'directory\t%s\t%s\n' "$path" "$mode"
            elif [[ -f "$path" ]]; then
                printf 'regularFile\t%s\t%s\t%s\t%s\n' \
                    "$path" "$mode" "$(/usr/bin/stat -f '%z' "$path")" \
                    "$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
            else
                fail "application inventory contains an unsupported entry"
            fi
        done < <(/usr/bin/find . -print0)
    ) | LC_ALL=C /usr/bin/sort >"$output"
}

verify_installer_bom_modes() {
    local bom="$1"
    local output="$2"
    local component_root="$3"
    local expected="$TEMP_ROOT/expected-bom-modes.txt"
    /usr/bin/lsbom -p fmug "$bom" >"$output" || fail "installer BOM is unreadable"
    (
        cd "$component_root"
        while IFS= read -r -d '' path; do
            printf '%s\t%s\t0\t0\n' "$path" "$(/usr/bin/stat -f '%p' "$path")"
        done < <(/usr/bin/find . -print0)
    ) | LC_ALL=C /usr/bin/sort >"$expected"
    /usr/bin/awk -F '\t' '
        function normalized_path(path) {
            gsub(/\/\._/, "/", path)
            return path
        }
        NR == FNR {
            expected[$1] = $2 FS $3 FS $4
            expected_count += 1
            next
        }
        {
            path = normalized_path($1)
            if (!(path in expected) || $2 FS $3 FS $4 != expected[path]) exit 1
            if (!(path in seen)) seen_count += 1
            seen[path] = 1
        }
        END {
            if (seen_count != expected_count) exit 1
        }
    ' "$expected" "$output" || fail "installer BOM mode or root ownership differs"
}

write_parent_tree_inventory() {
    local bom_modes="$1"
    local output="$2"
    /usr/bin/awk -F '\t' '
        $1 == "./JidokaCode" {
            print "directory\tJidokaCode\t" $2 "\t" $3 "\t" $4
            found_root = 1
        }
        $1 == "./JidokaCode/Applications" {
            print "directory\tJidokaCode/Applications\t" $2 "\t" $3 "\t" $4
            found_apps = 1
        }
        END { exit(found_root && found_apps ? 0 : 1) }
    ' "$bom_modes" >"$output" || fail "installer parent tree is absent from the BOM"
    [[ "$(/usr/bin/wc -l <"$output" | /usr/bin/tr -d ' ')" == "2" ]] || \
        fail "installer parent tree inventory is ambiguous"
    /usr/bin/grep -Fxq $'directory\tJidokaCode\t40755\t0\t0' "$output" || \
        fail "installer authority root metadata differs"
    /usr/bin/grep -Fxq $'directory\tJidokaCode/Applications\t40755\t0\t0' "$output" || \
        fail "installer applications authority metadata differs"
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

[[ -n "$RELEASE_RUNTIME_INPUT" ]] || \
    fail "JIDOKA_RELEASE_RUNTIME_ROOT must name the staged release runtime"
[[ "$SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || \
    fail "SIGN_IDENTITY must name one explicit Apple code-signing identity"
[[ "$INSTALLER_SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || \
    fail "INSTALLER_SIGN_IDENTITY must name one explicit installer identity"
validate_notarization_configuration
validate_signing_keychain "$APPLICATION_SIGNING_KEYCHAIN" APPLICATION_SIGNING_KEYCHAIN
validate_signing_keychain "$INSTALLER_SIGNING_KEYCHAIN" INSTALLER_SIGNING_KEYCHAIN
verify_identity "$SIGN_IDENTITY" codesigning SIGN_IDENTITY "$APPLICATION_SIGNING_KEYCHAIN"
verify_identity \
    "$INSTALLER_SIGN_IDENTITY" basic INSTALLER_SIGN_IDENTITY "$INSTALLER_SIGNING_KEYCHAIN"
[[ -f "$COMPONENT_POLICY" && ! -L "$COMPONENT_POLICY" ]] || \
    fail "application component policy is unavailable"
validate_component_policy
[[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] || /bin/mkdir -p "$BUILD_ROOT"
[[ "$(cd "$BUILD_ROOT" && pwd -P)" == "$ROOT/build" ]] || \
    fail "build root escapes repository"

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-package.XXXXXX")"
readonly TEMP_ROOT
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
readonly COMPONENT_ROOT="$TEMP_ROOT/component-root"
readonly COMPONENT_AUTHORITY_ROOT="$COMPONENT_ROOT/JidokaCode"
readonly COMPONENT_APPLICATIONS_ROOT="$COMPONENT_AUTHORITY_ROOT/Applications"
readonly COMPONENT_APP="$COMPONENT_ROOT/$COMPONENT_APP_RELATIVE_PATH"
readonly COMPONENT_PACKAGE="$TEMP_ROOT/JidokaCode-component.pkg"
readonly UNSIGNED_PRODUCT_PACKAGE="$TEMP_ROOT/Jidoka Code-unsigned.pkg"
readonly PRODUCT_PACKAGE="$TEMP_ROOT/Jidoka Code.pkg"
readonly EXPANDED_PACKAGE="$TEMP_ROOT/expanded"
readonly FULL_EXPANDED_PACKAGE="$TEMP_ROOT/expanded-full"
readonly PAYLOAD_ROOT="$FULL_EXPANDED_PACKAGE/JidokaCode-component.pkg/Payload"
readonly PAYLOAD_APP="$PAYLOAD_ROOT/$COMPONENT_APP_RELATIVE_PATH"
readonly COMPONENT_TREE_INVENTORY="$TEMP_ROOT/component-tree.txt"
readonly PAYLOAD_TREE_INVENTORY="$TEMP_ROOT/payload-tree.txt"
readonly PARENT_TREE_INVENTORY="$TEMP_ROOT/parent-tree.txt"
readonly RAW_PAYLOAD_LIST="$TEMP_ROOT/payload-raw.txt"
readonly PAYLOAD_LIST="$TEMP_ROOT/payload.txt"
readonly METADATA_PAYLOAD_LIST="$TEMP_ROOT/payload-metadata.txt"
readonly EXPECTED_PAYLOAD_LIST="$TEMP_ROOT/expected-payload.txt"
readonly BOM_MODE_LIST="$TEMP_ROOT/bom-modes.txt"
readonly NOTARY_RESPONSE="$TEMP_ROOT/notarization-result.json"
readonly SPCTL_OUTPUT="$TEMP_ROOT/spctl-package.txt"

if ! /usr/bin/env \
    SIGN_IDENTITY="$SIGN_IDENTITY" \
    SIGNING_KEYCHAIN="$APPLICATION_SIGNING_KEYCHAIN" \
    ALLOW_ADHOC_SIGNING=0 \
    JIDOKA_RELEASE_RUNTIME_ROOT="$RELEASE_RUNTIME_INPUT" \
    "$ROOT/scripts/package-app.sh"
then
    fail "application packaging failed"
fi
verifier_build_arguments=(
    --scratch-path "$ROOT/.build/adhoc-runtime-testing"
    --configuration release
    -Xswiftc -DJIDOKA_ADHOC_RUNTIME_TESTING
)
readonly -a verifier_build_arguments
/usr/bin/xcrun swift build \
    "${verifier_build_arguments[@]}" --product JidokaCodeApp
/usr/bin/xcrun swift build \
    "${verifier_build_arguments[@]}" --product JidokaCodeBoundedCommand
BOUNDED_COMMAND_BIN_DIR="$(
    /usr/bin/xcrun swift build "${verifier_build_arguments[@]}" --show-bin-path
)"
BOUNDED_COMMAND_BIN_DIR="$(cd "$BOUNDED_COMMAND_BIN_DIR" && pwd -P)"
readonly BOUNDED_COMMAND_BIN_DIR
case "$BOUNDED_COMMAND_BIN_DIR" in
    "$ROOT/.build/"*) ;;
    *) fail "native bounded command directory escapes .build" ;;
esac
BOUNDED_COMMAND="$BOUNDED_COMMAND_BIN_DIR/JidokaCodeBoundedCommand"
readonly BOUNDED_COMMAND
readonly DEVELOPER_ID_BUNDLE_VERIFIER="$BOUNDED_COMMAND_BIN_DIR/JidokaCodeApp"
[[ -f "$BOUNDED_COMMAND" && -x "$BOUNDED_COMMAND" && ! -L "$BOUNDED_COMMAND" ]] || \
    fail "native bounded command runner is unavailable"
[[ -f "$DEVELOPER_ID_BUNDLE_VERIFIER" && -x "$DEVELOPER_ID_BUNDLE_VERIFIER" && \
    ! -L "$DEVELOPER_ID_BUNDLE_VERIFIER" ]] || \
    fail "Developer ID bundle verifier is unavailable"
[[ -d "$APP" && ! -L "$APP" ]] || fail "signed application bundle is missing"
[[ -f "$RUNTIME_INVENTORY" && ! -L "$RUNTIME_INVENTORY" ]] || \
    fail "generated release runtime inventory is missing"
/usr/bin/codesign --verify --strict --deep "$APP"

/bin/mkdir -m 0755 "$COMPONENT_ROOT"
/bin/mkdir -m 0755 "$COMPONENT_AUTHORITY_ROOT"
/bin/mkdir -m 0755 "$COMPONENT_APPLICATIONS_ROOT"
for parent in "$COMPONENT_AUTHORITY_ROOT" "$COMPONENT_APPLICATIONS_ROOT"; do
    [[ -d "$parent" && ! -L "$parent" && \
        "$(/usr/bin/stat -f '%OLp' "$parent")" == "755" ]] || \
        fail "component authority parent metadata differs"
    if path_has_allow_acl "$parent"; then
        fail "component authority parent ACL is unsafe"
    fi
done
/usr/bin/ditto "$APP" "$COMPONENT_APP"
[[ -d "$COMPONENT_APP" && ! -L "$COMPONENT_APP" ]] || \
    fail "component application copy is missing"
/usr/bin/codesign --verify --strict --deep "$COMPONENT_APP" || \
    fail "component application signature is invalid"
run_package_tool \
    component-runtime \
    "$DEVELOPER_ID_BUNDLE_VERIFIER" \
    --release-runtime-verify-developer-id \
    "$COMPONENT_APP" >/dev/null
app_version="$(
    /usr/bin/plutil -extract CFBundleShortVersionString raw \
        "$COMPONENT_APP/Contents/Info.plist"
)"
app_build_version="$(
    /usr/bin/plutil -extract CFBundleVersion raw "$COMPONENT_APP/Contents/Info.plist"
)"
app_bundle_identifier="$(
    /usr/bin/plutil -extract CFBundleIdentifier raw "$COMPONENT_APP/Contents/Info.plist"
)"
[[ "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid application version"
[[ "$app_build_version" =~ ^[1-9][0-9]*$ ]] || fail "invalid application build version"
[[ "$app_bundle_identifier" == "$APPLICATION_IDENTIFIER" ]] || \
    fail "unexpected application bundle identifier"
if LC_ALL=C /usr/bin/grep -R -F -l "$ROOT" "$COMPONENT_APP" >/dev/null 2>&1; then
    fail "component application contains its checkout path"
elif [[ "$?" -ne 1 ]]; then
    fail "could not audit the component application for checkout paths"
fi
write_application_tree_inventory "$COMPONENT_ROOT" "$COMPONENT_TREE_INVENTORY"
pkgbuild_arguments=(
    --root "$COMPONENT_ROOT"
    --component-plist "$COMPONENT_POLICY"
    --ownership recommended
    --install-location "$INSTALL_LOCATION"
    --identifier "$PACKAGE_IDENTIFIER"
    --version "$app_version"
    "$COMPONENT_PACKAGE"
)
readonly -a pkgbuild_arguments
/usr/bin/pkgbuild "${pkgbuild_arguments[@]}"
productbuild_arguments=(--package "$COMPONENT_PACKAGE" "$UNSIGNED_PRODUCT_PACKAGE")
readonly -a productbuild_arguments
run_package_tool productbuild /usr/bin/productbuild "${productbuild_arguments[@]}"
[[ -f "$UNSIGNED_PRODUCT_PACKAGE" && ! -L "$UNSIGNED_PRODUCT_PACKAGE" ]] || \
    fail "unsigned product package is missing"
productsign_arguments=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
if [[ -n "$INSTALLER_SIGNING_KEYCHAIN" ]]; then
    productsign_arguments+=(--keychain "$INSTALLER_SIGNING_KEYCHAIN")
fi
productsign_arguments+=("$UNSIGNED_PRODUCT_PACKAGE" "$PRODUCT_PACKAGE")
readonly -a productsign_arguments
run_package_tool productsign /usr/bin/productsign "${productsign_arguments[@]}"
[[ -f "$PRODUCT_PACKAGE" && ! -L "$PRODUCT_PACKAGE" ]] || fail "product package is missing"

/usr/sbin/pkgutil --expand-full "$PRODUCT_PACKAGE" "$FULL_EXPANDED_PACKAGE"
[[ -d "$PAYLOAD_APP" && ! -L "$PAYLOAD_APP" ]] || \
    fail "expanded product payload application is missing"
for relative_parent in JidokaCode JidokaCode/Applications; do
    payload_parent="$PAYLOAD_ROOT/$relative_parent"
    [[ -d "$payload_parent" && ! -L "$payload_parent" && \
        "$(/usr/bin/stat -f '%OLp' "$payload_parent")" == "755" ]] || \
        fail "expanded product payload parent metadata differs"
    if path_has_allow_acl "$payload_parent"; then
        fail "expanded product payload parent ACL is unsafe"
    fi
done
[[ "$(/usr/bin/find "$FULL_EXPANDED_PACKAGE" -type d -name 'Jidoka Code.app' -print)" == \
    "$PAYLOAD_APP" ]] || fail "expanded product payload application is ambiguous"
/usr/bin/codesign --verify --strict --deep "$PAYLOAD_APP" || \
    fail "expanded product payload signature is invalid"
run_package_tool \
    payload-runtime \
    "$DEVELOPER_ID_BUNDLE_VERIFIER" \
    --release-runtime-verify-developer-id \
    "$PAYLOAD_APP" >/dev/null
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
    "$PAYLOAD_APP/Contents/Info.plist")" == "$app_version" && \
    "$(/usr/bin/plutil -extract CFBundleVersion raw \
    "$PAYLOAD_APP/Contents/Info.plist")" == "$app_build_version" && \
    "$(/usr/bin/plutil -extract CFBundleIdentifier raw \
    "$PAYLOAD_APP/Contents/Info.plist")" == "$app_bundle_identifier" ]] || \
    fail "expanded product payload application identity differs"
write_application_tree_inventory "$PAYLOAD_ROOT" "$PAYLOAD_TREE_INVENTORY"
/usr/bin/cmp -s "$COMPONENT_TREE_INVENTORY" "$PAYLOAD_TREE_INVENTORY" || \
    fail "expanded product payload bytes differ from the validated component"
payload_tree_sha256="$(
    /usr/bin/shasum -a 256 "$PAYLOAD_TREE_INVENTORY" | /usr/bin/awk '{print $1}'
)"

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
{
    printf 'JidokaCode\nJidokaCode/Applications\n'
    {
        /bin/cat "$ROOT/Packaging/app-inventory.txt"
        /bin/cat "$RUNTIME_INVENTORY"
    } | /usr/bin/awk -v app="$COMPONENT_APP_RELATIVE_PATH" '
        $0 == "." { print app; next }
        /^\.\// { print app "/" substr($0, 3); next }
        { exit 2 }
    '
} >"$EXPECTED_PAYLOAD_LIST" || fail "invalid application or parent inventory"
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
bom_file="$(/usr/bin/find "$EXPANDED_PACKAGE" -type f -name Bom -print)"
[[ "$(printf '%s\n' "$bom_file" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] || \
    fail "installer BOM is ambiguous"
verify_installer_bom_modes "$bom_file" "$BOM_MODE_LIST" "$COMPONENT_ROOT"
write_parent_tree_inventory "$BOM_MODE_LIST" "$PARENT_TREE_INVENTORY"
parent_tree_sha256="$(
    /usr/bin/shasum -a 256 "$PARENT_TREE_INVENTORY" | /usr/bin/awk '{print $1}'
)"
[[ "$(/usr/bin/xmllint --xpath \
    "count(/pkg-info[@identifier='$PACKAGE_IDENTIFIER' and @version='$app_version' and @install-location='$INSTALL_LOCATION' and @postinstall-action='none' and @auth='root' and @relocatable='false'])" \
    "$package_info")" == "1" ]] || fail "installer package identity or policy differs"
[[ "$(/usr/bin/xmllint --xpath 'count(/pkg-info/bundle)' "$package_info")" == "1" && \
    "$(/usr/bin/xmllint --xpath \
        "count(/pkg-info/bundle[@id='$app_bundle_identifier' and @path='./$COMPONENT_APP_RELATIVE_PATH'])" \
        "$package_info")" == "1" && \
    "$(/usr/bin/xmllint --xpath 'count(/pkg-info/bundle-version/bundle)' "$package_info")" == "1" && \
    "$(/usr/bin/xmllint --xpath \
        "count(/pkg-info/bundle-version/bundle[@id='$app_bundle_identifier'])" \
        "$package_info")" == "1" ]] || fail "installer application bundle identity differs"
[[ "$(/usr/bin/xmllint --xpath 'count(/pkg-info/relocate/bundle)' "$package_info")" == "0" ]] || \
    fail "installer application bundle is relocatable"
[[ "$(/usr/bin/xmllint --xpath 'count(/pkg-info/strict-identifier/bundle)' "$package_info")" == "1" && \
    "$(/usr/bin/xmllint --xpath \
        "count(/pkg-info/strict-identifier/bundle[@id='$app_bundle_identifier'])" \
        "$package_info")" == "1" ]] || fail "installer application strict identifier differs"
[[ "$(/usr/bin/xmllint --xpath 'count(/pkg-info/upgrade-bundle/bundle)' "$package_info")" == "1" && \
    "$(/usr/bin/xmllint --xpath \
        "count(/pkg-info/upgrade-bundle/bundle[@id='$app_bundle_identifier'])" \
        "$package_info")" == "1" && \
    "$(/usr/bin/xmllint --xpath 'count(/pkg-info/update-bundle/bundle)' "$package_info")" == "0" && \
    "$(/usr/bin/xmllint --xpath 'count(/pkg-info/atomic-update-bundle/bundle)' "$package_info")" == "0" ]] || \
    fail "installer application overwrite policy differs"
readonly DISTRIBUTION="$EXPANDED_PACKAGE/Distribution"
[[ -f "$DISTRIBUTION" && ! -L "$DISTRIBUTION" ]] || fail "installer distribution is missing"
/usr/bin/grep -Fq 'require-scripts="false"' "$DISTRIBUTION" || \
    fail "installer distribution unexpectedly allows scripts"
/usr/bin/grep -Fq 'onConclusion="none"' "$DISTRIBUTION" || \
    fail "installer conclusion action differs"
/usr/bin/grep -Fq \
    "id=\"$app_bundle_identifier\" path=\"$COMPONENT_APP_RELATIVE_PATH\"" \
    "$DISTRIBUTION" || \
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
        --timeout 30m \
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
host_sha256="$(
    /usr/bin/shasum -a 256 "$PAYLOAD_APP/Contents/Helpers/JidokaCodeHerdrHost" | \
        /usr/bin/awk '{print $1}'
)"
inventory_sha256="$({
    /bin/cat "$ROOT/Packaging/app-inventory.txt"
    /bin/cat "$RUNTIME_INVENTORY"
} | LC_ALL=C /usr/bin/sort | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
herdr_policy_sha256="$(
    /usr/bin/shasum -a 256 "$PAYLOAD_APP/Contents/Resources/Herdr/runtime-builds.json" | \
        /usr/bin/awk '{print $1}'
)"
herdr_schema_sha256="$(
    /usr/bin/shasum -a 256 "$PAYLOAD_APP/Contents/Resources/Herdr/api-schema-0.8.2.json" | \
        /usr/bin/awk '{print $1}'
)"
minimum_os_version="$(
    /usr/bin/plutil -extract LSMinimumSystemVersion raw "$PAYLOAD_APP/Contents/Info.plist"
)"
app_signature="$(/usr/bin/codesign -d --verbose=4 "$PAYLOAD_APP" 2>&1)"
app_team="$(
    /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2}' <<<"$app_signature"
)"
host_team="$(
    /usr/bin/codesign -dvvv "$PAYLOAD_APP/Contents/Helpers/JidokaCodeHerdrHost" 2>&1 | \
        /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}'
)"
[[ "$app_signature" == *"Authority=Developer ID Application:"* ]] || \
    fail "application is not signed with Developer ID Application"
[[ "$app_signature" == *"Timestamp="* ]] || \
    fail "application signature lacks a trusted timestamp"
[[ -n "$app_team" && "$app_team" != "not set" && "$app_team" == "$host_team" ]] || \
    fail "application and Herdr host signing teams differ"
if ! installer_certificate_sha256="$(
    certificate_sha256_for_identity "$INSTALLER_SIGN_IDENTITY" "$INSTALLER_SIGNING_KEYCHAIN"
)"; then
    fail "installer signing certificate is unavailable"
fi
[[ "$package_certificate_sha256" == "$installer_certificate_sha256" ]] || \
    fail "installer package certificate differs from the selected identity"
[[ "$package_signer" == Developer\ ID\ Installer:*"($app_team)" ]] || \
    fail "application and installer signing teams differ"
[[ "$herdr_policy_sha256" == \
    "45674e216b931f7c736c1c8348e899221c2aef080dfa6a92392144b244cd5867" ]] || \
    fail "installer Herdr policy digest differs"
[[ "$herdr_schema_sha256" == \
    "c48f1f54ee0150ca27e11fd44455fe94aeadb20fdf4e4a62393ed822a4e5b150" ]] || \
    fail "installer Herdr schema digest differs"
[[ "$minimum_os_version" == "14.0" ]] || fail "installer minimum OS differs"

if [[ "$package_notarized" == "true" ]]; then
    printf '%s\n' \
        "{\"appBuildVersion\":\"$app_build_version\",\"appBundleIdentifier\":\"$app_bundle_identifier\",\"applicationSigningIdentitySHA1\":\"$SIGN_IDENTITY\",\"appInventorySHA256\":\"$inventory_sha256\",\"appVersion\":\"$app_version\",\"herdrBundled\":false,\"herdrHostSHA256\":\"$host_sha256\",\"herdrPolicySHA256\":\"$herdr_policy_sha256\",\"herdrSchemaSHA256\":\"$herdr_schema_sha256\",\"installLocation\":\"$INSTALL_APP_PATH\",\"installerScripts\":false,\"installerSigningCertificateSHA256\":\"$installer_certificate_sha256\",\"installerSigningIdentitySHA1\":\"$INSTALLER_SIGN_IDENTITY\",\"installRoot\":\"$INSTALL_LOCATION\",\"minimumOSVersion\":\"$minimum_os_version\",\"notarizationResultSHA256\":\"$notarization_result_sha256\",\"notarizationSubmissionID\":\"$notarization_submission_id\",\"packageIdentifier\":\"$PACKAGE_IDENTIFIER\",\"packageNotarized\":true,\"packageSHA256\":\"$package_sha256\",\"packageSigned\":true,\"parentTreeSHA256\":\"$parent_tree_sha256\",\"payloadRootRelativeAppPath\":\"$COMPONENT_APP_RELATIVE_PATH\",\"payloadTreeSHA256\":\"$payload_tree_sha256\",\"schemaVersion\":6,\"signingTeamIdentifier\":\"$app_team\",\"trustedTimestamp\":true}" \
        >"$PACKAGE_MANIFEST"
else
    printf '%s\n' \
        "{\"appBuildVersion\":\"$app_build_version\",\"appBundleIdentifier\":\"$app_bundle_identifier\",\"applicationSigningIdentitySHA1\":\"$SIGN_IDENTITY\",\"appInventorySHA256\":\"$inventory_sha256\",\"appVersion\":\"$app_version\",\"herdrBundled\":false,\"herdrHostSHA256\":\"$host_sha256\",\"herdrPolicySHA256\":\"$herdr_policy_sha256\",\"herdrSchemaSHA256\":\"$herdr_schema_sha256\",\"installLocation\":\"$INSTALL_APP_PATH\",\"installerScripts\":false,\"installerSigningCertificateSHA256\":\"$installer_certificate_sha256\",\"installerSigningIdentitySHA1\":\"$INSTALLER_SIGN_IDENTITY\",\"installRoot\":\"$INSTALL_LOCATION\",\"minimumOSVersion\":\"$minimum_os_version\",\"packageIdentifier\":\"$PACKAGE_IDENTIFIER\",\"packageNotarized\":false,\"packageSHA256\":\"$package_sha256\",\"packageSigned\":true,\"parentTreeSHA256\":\"$parent_tree_sha256\",\"payloadRootRelativeAppPath\":\"$COMPONENT_APP_RELATIVE_PATH\",\"payloadTreeSHA256\":\"$payload_tree_sha256\",\"schemaVersion\":5,\"signingTeamIdentifier\":\"$app_team\",\"trustedTimestamp\":true}" \
        >"$PACKAGE_MANIFEST"
fi
/usr/bin/plutil -convert xml1 -o /dev/null "$PACKAGE_MANIFEST"

printf 'package=%s\n' "$PACKAGE"
printf 'package_sha256=%s\n' "$package_sha256"
printf 'package_identifier=%s\n' "$PACKAGE_IDENTIFIER"
printf 'install_location=%s\n' "$INSTALL_APP_PATH"
printf 'parent_tree_sha256=%s\n' "$parent_tree_sha256"
printf 'nested_signing=developer-id\n'
printf 'package_signing=developer-id-installer\n'
printf 'package_notarized=%s\n' "$package_notarized"
if [[ "$package_notarized" == "true" ]]; then
    printf 'notarization_submission_id=%s\n' "$notarization_submission_id"
fi
