#!/usr/bin/env bash
set -euo pipefail
umask 022

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly ROOT
readonly BUILD_ROOT="$ROOT/build"
readonly APP="$BUILD_ROOT/Jidoka Code.app"
readonly CONTENTS="$APP/Contents"
readonly MACOS="$CONTENTS/MacOS"
readonly HELPERS="$CONTENTS/Helpers"
readonly LAUNCH_AGENTS="$CONTENTS/Library/LaunchAgents"
readonly RESOURCES="$CONTENTS/Resources"
readonly APP_EXECUTABLE="$MACOS/Jidoka Code"
readonly ENGINE_EXECUTABLE="$HELPERS/JidokaCodeEngineProbe"
readonly ASKPASS_EXECUTABLE="$HELPERS/JidokaCodeAskPass"
readonly GIT_HOOKS="$HELPERS/GitHooks"
readonly PUSH_GUARD_EXECUTABLE="$GIT_HOOKS/pre-push"
readonly HERDR_HOST_EXECUTABLE="$HELPERS/JidokaCodeHerdrHost"
readonly HERDR_RESOURCES="$RESOURCES/Herdr"
readonly RELEASE_RUNTIME="$RESOURCES/PiRuntime"
readonly RELEASE_IDENTITY_MANIFEST="$RESOURCES/progressive-production-release.json"
readonly RELEASE_IDENTITY_GENERATOR="$ROOT/scripts/generate-progressive-production-release.mjs"
readonly RUNTIME_INVENTORY="$BUILD_ROOT/runtime-inventory.txt"
readonly RUNTIME_ENTITLEMENTS="$ROOT/Packaging/runtime-node-entitlements.plist"
readonly RUNTIME_INPUT="${JIDOKA_RELEASE_RUNTIME_ROOT:-}"
readonly RUNTIME_NODE_INPUT="$RUNTIME_INPUT/node/bin/node"
readonly RUNTIME_NODE_IDENTIFIER="works.earendil.jidoka.runtime.node"
readonly RUNTIME_ADHOC_CODEDIRECTORY_SHA256="da0ef1cc83b51b610819c85f6275a043ec2af3e14ad02b0e715578694efd0b5c"
readonly RUNTIME_PRODUCTION_CODEDIRECTORY_SHA256="5bc21eacac48789dfa7e0c259516144a70a57362715cc8f241c658fc12fe25df"
readonly RUNTIME_MANIFEST_SHA256="fe15573a58a4604a3695b092ba8b07ae2432da7b7f07743a8d54a4421ab3aa83"
readonly RUNTIME_ID="node-26.7.0-pi-0.84.2-darwin-arm64-v1"
readonly RUNTIME_NATIVE_CODE_TEAM_IDENTIFIER="X3Q42VNZDC"
readonly -a RUNTIME_NATIVE_CODE_RELATIVE_PATHS=(
    "node_modules/@earendil-works/pi-tui/native/darwin/prebuilds/darwin-arm64/darwin-modifiers.node"
    "node_modules/@earendil-works/pi-tui/native/darwin/prebuilds/darwin-x64/darwin-modifiers.node"
    "node_modules/@mariozechner/clipboard-darwin-arm64/clipboard.darwin-arm64.node"
    "node_modules/@mariozechner/clipboard-darwin-universal/clipboard.darwin-universal.node"
    "node_modules/@mariozechner/clipboard-darwin-x64/clipboard.darwin-x64.node"
)
readonly -a RUNTIME_NATIVE_CODE_IDENTIFIERS=(
    "works.earendil.jidoka.runtime.pi.darwin-modifiers"
    "works.earendil.jidoka.runtime.pi.darwin-modifiers"
    "works.earendil.jidoka.runtime.pi.clipboard"
    "works.earendil.jidoka.runtime.pi.clipboard"
    "works.earendil.jidoka.runtime.pi.clipboard"
)
readonly -a RUNTIME_NATIVE_CODE_ARCHITECTURES=(
    "arm64"
    "x86_64"
    "arm64"
    "x86_64 arm64"
    "x86_64"
)
readonly -a RUNTIME_NATIVE_CODE_DIRECTORIES=(
    "11c0d82cbd543d9f57121f5d0dea0227abe298119453dfa4eae4405377e04cf9"
    "cdd6dc96274b28cfafb36f74c8dd8b956c25b28aef47d66ed26d6ce9b82abd06"
    "8f1d72ae2f9738b69e02adc2bdb946a9c4f33d0b148eab01d67f447bb1cb0bf7"
    "fbb117bd8461e6a9038c2edc3a0bf63ae914c238974525aabe51cff7641f287d 8f1d72ae2f9738b69e02adc2bdb946a9c4f33d0b148eab01d67f447bb1cb0bf7"
    "fbb117bd8461e6a9038c2edc3a0bf63ae914c238974525aabe51cff7641f287d"
)
readonly -a RUNTIME_NATIVE_CODE_MODES=(755 755 644 644 644)
BOUNDED_COMMAND_RUNNER=""
# The process-level bound remains ten minutes. The staged 14,543-entry Pi tree
# has a separate 60-second performance gate below.
readonly RELEASE_RUNTIME_PROBE_TIMEOUT_SECONDS=600
readonly RELEASE_RUNTIME_PROBE_STDOUT_LIMIT_BYTES=65536
readonly RELEASE_RUNTIME_PROBE_STDERR_LIMIT_BYTES=262144
readonly STAGED_RUNTIME_PERFORMANCE_BOUND_SECONDS=60
readonly SIGN_IDENTITY="${SIGN_IDENTITY:--}"
readonly SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"
readonly ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"
RUNTIME_INVENTORY_TEMP=""
RELEASE_IDENTITY_TEMP=""
SOURCE_COMMIT=""
SOURCE_TREE=""
STAGED_RUNTIME_IDENTITY_SHA256=""
PACKAGED_RUNTIME_IDENTITY_SHA256=""

fail() {
    printf 'packaging failed: %s\n' "$1" >&2
    exit 1
}

path_has_allow_acl() {
    /bin/ls -lde "$1" | /usr/bin/awk '
        NR > 1 && $0 ~ / allow / { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

cleanup() {
    if [[ -n "$RUNTIME_INVENTORY_TEMP" && -f "$RUNTIME_INVENTORY_TEMP" && \
        ! -L "$RUNTIME_INVENTORY_TEMP" ]]; then
        case "$RUNTIME_INVENTORY_TEMP" in
            "$BUILD_ROOT"/.runtime-inventory.*) /bin/rm -f -- "$RUNTIME_INVENTORY_TEMP" ;;
        esac
    fi
    if [[ -n "$RELEASE_IDENTITY_TEMP" && -f "$RELEASE_IDENTITY_TEMP" && \
        ! -L "$RELEASE_IDENTITY_TEMP" ]]; then
        case "$RELEASE_IDENTITY_TEMP" in
            "$RESOURCES"/.progressive-production-release.*)
                /bin/rm -f -- "$RELEASE_IDENTITY_TEMP"
                ;;
        esac
    fi
}
trap cleanup EXIT

validate_runtime_inventory_destination() {
    if [[ -L "$RUNTIME_INVENTORY" ]]; then
        fail "generated release runtime inventory must not be a symbolic link"
    fi
    if [[ -e "$RUNTIME_INVENTORY" ]]; then
        [[ -f "$RUNTIME_INVENTORY" && \
            "$(/usr/bin/stat -f '%u' "$RUNTIME_INVENTORY")" == "$(/usr/bin/id -u)" && \
            "$(/usr/bin/stat -f '%l' "$RUNTIME_INVENTORY")" == "1" && \
            "$(( 8#$(/usr/bin/stat -f '%OLp' "$RUNTIME_INVENTORY") & 8#022 ))" == "0" ]] || \
            fail "pre-existing release runtime inventory is unsafe"
        if path_has_allow_acl "$RUNTIME_INVENTORY"; then
            fail "pre-existing release runtime inventory ACL is unsafe"
        fi
    fi
}

run_release_runtime_probe() {
    local executable="$1"
    local status=0
    shift
    (
        cd /
        JIDOKA_BOUNDED_STDOUT_LIMIT_BYTES="$RELEASE_RUNTIME_PROBE_STDOUT_LIMIT_BYTES" \
            JIDOKA_BOUNDED_STDERR_LIMIT_BYTES="$RELEASE_RUNTIME_PROBE_STDERR_LIMIT_BYTES" \
            "$BOUNDED_COMMAND_RUNNER" \
            "$RELEASE_RUNTIME_PROBE_TIMEOUT_SECONDS" \
            "$executable" "$@"
    ) </dev/null || status=$?
    case "$status" in
        0) return 0 ;;
        124)
            fail "release runtime probe timed out after ${RELEASE_RUNTIME_PROBE_TIMEOUT_SECONDS}s"
            ;;
        125) fail "release runtime probe identity cleanup failed" ;;
        126) fail "release runtime probe output exceeded its bounded capture" ;;
        *) return "$status" ;;
    esac
}

monotonic_seconds() {
    /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
        -e 'printf "%.9f\n", clock_gettime(CLOCK_MONOTONIC)'
}

elapsed_seconds_since() {
    /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
        -e 'printf "%.3f\n", clock_gettime(CLOCK_MONOTONIC) - $ARGV[0]' "$1"
}

verify_staged_runtime_performance() {
    local elapsed
    local executable="$1"
    local expected_report
    local identity
    local report
    local started

    started="$(monotonic_seconds)"
    if ! report="$(
        run_release_runtime_probe \
            "$executable" \
            --release-runtime-verify-input "$RUNTIME_INPUT"
    )"; then
        fail "flagged release verifier rejected the staged runtime input"
    fi
    elapsed="$(elapsed_seconds_since "$started")"
    /usr/bin/awk \
        -v elapsed="$elapsed" \
        -v bound="$STAGED_RUNTIME_PERFORMANCE_BOUND_SECONDS" \
        'BEGIN { exit !(elapsed < bound) }' || \
        fail "staged release runtime verifier exceeded ${STAGED_RUNTIME_PERFORMANCE_BOUND_SECONDS}s"

    identity="$(
        printf '%s\n' "$report" | \
            /usr/bin/plutil -extract runtimeIdentitySHA256 raw -o - -
    )"
    [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || \
        fail "staged release runtime verifier reported an invalid identity"
    expected_report="$(printf \
        '{"manifestSHA256":"%s","runtimeID":"%s","runtimeIdentitySHA256":"%s","schemaVersion":1}' \
        "$RUNTIME_MANIFEST_SHA256" "$RUNTIME_ID" "$identity")"
    [[ "$report" == "$expected_report" ]] || \
        fail "staged release runtime verifier reported unexpected identity fields"
    STAGED_RUNTIME_IDENTITY_SHA256="$identity"
    printf \
        'staged_runtime_verifier_seconds=%s runtime_id=%s manifest_sha256=%s runtime_identity_sha256=%s\n' \
        "$elapsed" "$RUNTIME_ID" "$RUNTIME_MANIFEST_SHA256" "$identity"
}

capture_source_identity() {
    local worktree_status

    SOURCE_COMMIT="$(/usr/bin/git -C "$ROOT" rev-parse --verify HEAD)" || \
        fail "source commit is unavailable"
    SOURCE_TREE="$(/usr/bin/git -C "$ROOT" rev-parse --verify 'HEAD^{tree}')" || \
        fail "source tree is unavailable"
    [[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ && "$SOURCE_TREE" =~ ^[0-9a-f]{40}$ ]] || \
        fail "source commit or tree identity is malformed"

    if [[ "$SIGN_IDENTITY" != "-" ]]; then
        worktree_status="$(
            /usr/bin/git -C "$ROOT" status --porcelain=v1 --untracked-files=normal
        )"
        [[ -z "$worktree_status" ]] || \
            fail "identity-signed packaging requires a clean source worktree"
    fi
}

generate_release_identity_manifest() {
    local bundle_build
    local bundle_version
    local helper_sha256
    local herdr_host_sha256
    local runtime_identity_sha256="$1"
    local runtime_manifest_sha256
    local workflow_resources_sha256

    [[ "$runtime_identity_sha256" =~ ^[0-9a-f]{64}$ ]] || \
        fail "release runtime identity is unavailable"
    if [[ -e "$RELEASE_IDENTITY_MANIFEST" || -L "$RELEASE_IDENTITY_MANIFEST" ]]; then
        [[ -f "$RELEASE_IDENTITY_MANIFEST" && ! -L "$RELEASE_IDENTITY_MANIFEST" && \
            "$(/usr/bin/stat -f '%OLp' "$RELEASE_IDENTITY_MANIFEST")" == "644" && \
            "$(/usr/bin/stat -f '%l' "$RELEASE_IDENTITY_MANIFEST")" == "1" ]] || \
            fail "existing release identity manifest is unsafe"
    fi

    bundle_version="$(
        /usr/bin/plutil -extract CFBundleShortVersionString raw "$CONTENTS/Info.plist"
    )"
    bundle_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$CONTENTS/Info.plist")"
    helper_sha256="$(
        /usr/bin/shasum -a 256 "$ENGINE_EXECUTABLE" | /usr/bin/awk '{print $1}'
    )"
    herdr_host_sha256="$(
        /usr/bin/shasum -a 256 "$HERDR_HOST_EXECUTABLE" | /usr/bin/awk '{print $1}'
    )"
    runtime_manifest_sha256="$(
        /usr/bin/shasum -a 256 "$RELEASE_RUNTIME/runtime-manifest.json" | \
            /usr/bin/awk '{print $1}'
    )"
    workflow_resources_sha256="$(
        /usr/bin/shasum -a 256 "$RESOURCES/Pi/workflow-resources.json" | \
            /usr/bin/awk '{print $1}'
    )"
    [[ "$runtime_manifest_sha256" == "$RUNTIME_MANIFEST_SHA256" ]] || \
        fail "packaged runtime manifest identity differs before release manifest generation"

    RELEASE_IDENTITY_TEMP="$(
        /usr/bin/mktemp "$RESOURCES/.progressive-production-release.XXXXXX"
    )"
    [[ -f "$RELEASE_IDENTITY_TEMP" && ! -L "$RELEASE_IDENTITY_TEMP" && \
        "$(/usr/bin/stat -f '%OLp' "$RELEASE_IDENTITY_TEMP")" == "600" && \
        "$(/usr/bin/stat -f '%l' "$RELEASE_IDENTITY_TEMP")" == "1" ]] || \
        fail "private release identity manifest could not be created"
    "$RUNTIME_NODE_INPUT" "$RELEASE_IDENTITY_GENERATOR" \
        "$SOURCE_COMMIT" \
        "$SOURCE_TREE" \
        "$bundle_version" \
        "$bundle_build" \
        "$helper_sha256" \
        "$herdr_host_sha256" \
        "10" \
        "12" \
        "$runtime_manifest_sha256" \
        "$runtime_identity_sha256" \
        "$workflow_resources_sha256" \
        >"$RELEASE_IDENTITY_TEMP"
    [[ "$(/usr/bin/stat -f '%z' "$RELEASE_IDENTITY_TEMP")" -gt 0 && \
        "$(/usr/bin/stat -f '%z' "$RELEASE_IDENTITY_TEMP")" -le 65536 ]] || \
        fail "release identity manifest size is invalid"
    /usr/bin/plutil -convert xml1 -o /dev/null "$RELEASE_IDENTITY_TEMP"
    /bin/chmod 0644 "$RELEASE_IDENTITY_TEMP"
    /bin/mv -- "$RELEASE_IDENTITY_TEMP" "$RELEASE_IDENTITY_MANIFEST"
    RELEASE_IDENTITY_TEMP=""
}

capture_packaged_runtime_identity() {
    local expected_report
    local identity
    local report

    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        report="$(
            run_release_runtime_probe \
                "$APP_EXECUTABLE" \
                --release-runtime-verify-adhoc
        )" || fail "assembled ad hoc bundle runtime validation failed"
    else
        report="$(
            run_release_runtime_probe \
                "$STAGED_RUNTIME_VERIFIER" \
                --release-runtime-verify-developer-id \
                "$APP"
        )" || fail "assembled Developer ID bundle runtime validation failed"
    fi
    identity="$(
        printf '%s\n' "$report" | \
            /usr/bin/plutil -extract runtimeIdentitySHA256 raw -o - -
    )"
    [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || \
        fail "packaged release runtime verifier reported an invalid identity"
    expected_report="$(printf \
        '{"manifestSHA256":"%s","runtimeID":"%s","runtimeIdentitySHA256":"%s","schemaVersion":1}' \
        "$RUNTIME_MANIFEST_SHA256" "$RUNTIME_ID" "$identity")"
    [[ "$report" == "$expected_report" ]] || \
        fail "packaged release runtime verifier reported unexpected identity fields"
    PACKAGED_RUNTIME_IDENTITY_SHA256="$identity"
}

verify_packaged_runtime_identity() {
    local expected_identity="$PACKAGED_RUNTIME_IDENTITY_SHA256"

    capture_packaged_runtime_identity
    [[ "$PACKAGED_RUNTIME_IDENTITY_SHA256" == "$expected_identity" ]] || \
        fail "outer signing changed the packaged release runtime identity"
}

assert_safe_runtime_input_chain() {
    local current="$1"
    local mode
    local owner
    while true; do
        [[ -d "$current" && ! -L "$current" ]] || \
            fail "release runtime input ancestor is redirected"
        mode="$(/usr/bin/stat -f '%p' "$current")"
        owner="$(/usr/bin/stat -f '%u' "$current")"
        if path_has_allow_acl "$current"; then
            fail "release runtime input ancestor ACL is unsafe"
        fi
        [[ "$owner" == "0" || "$owner" == "$(/usr/bin/id -u)" ]] || \
            fail "release runtime input ancestor owner is unsafe"
        if (( (8#$mode & 8#22) != 0 && (8#$mode & 8#1000) == 0 )); then
            fail "release runtime input ancestor mode is unsafe"
        fi
        [[ "$current" != "/" ]] || return 0
        current="$(/usr/bin/dirname "$current")"
    done
}

validate_runtime_input() {
    local canonical
    local entitlement_digest
    local links
    local mode
    local node_entitlements
    local node_signature
    local owner

    [[ -n "$RUNTIME_INPUT" && "$RUNTIME_INPUT" == /* && -d "$RUNTIME_INPUT" && \
        ! -L "$RUNTIME_INPUT" ]] || \
        fail "JIDOKA_RELEASE_RUNTIME_ROOT must name one absolute staged runtime directory"
    canonical="$(cd "$RUNTIME_INPUT" && pwd -P)"
    [[ "$canonical" == "$RUNTIME_INPUT" ]] || fail "release runtime input must be canonical"
    case "$canonical" in
        "$ROOT"/*)
            case "$canonical" in
                "$ROOT/build/"*) ;;
                *) fail "release runtime input inside the checkout must be beneath ignored build/" ;;
            esac
            ;;
    esac
    assert_safe_runtime_input_chain "$canonical"
    mode="$(/usr/bin/stat -f '%OLp' "$canonical")"
    owner="$(/usr/bin/stat -f '%u' "$canonical")"
    links="$(/usr/bin/stat -f '%l' "$canonical")"
    [[ "$mode" == "755" && ( "$owner" == "0" || "$owner" == "$(/usr/bin/id -u)" ) && \
        "$links" -ge 2 ]] || fail "release runtime input metadata is unsafe"
    [[ -f "$canonical/runtime-manifest.json" && ! -L "$canonical/runtime-manifest.json" ]] || \
        fail "release runtime manifest is unavailable"
    /usr/bin/cmp -s \
        "$canonical/runtime-manifest.json" \
        "$ROOT/Resources/Pi/runtime/release-runtime.json" || \
        fail "release runtime manifest differs from the compiled source anchor"
    [[ -f "$RUNTIME_NODE_INPUT" && ! -L "$RUNTIME_NODE_INPUT" && \
        "$(/usr/bin/stat -f '%OLp' "$RUNTIME_NODE_INPUT")" == "555" && \
        ( "$(/usr/bin/stat -f '%u' "$RUNTIME_NODE_INPUT")" == "0" || \
            "$(/usr/bin/stat -f '%u' "$RUNTIME_NODE_INPUT")" == "$(/usr/bin/id -u)" ) && \
        "$(/usr/bin/stat -f '%l' "$RUNTIME_NODE_INPUT")" == "1" ]] || \
        fail "staged runtime Node metadata is invalid"
    if path_has_allow_acl "$RUNTIME_NODE_INPUT"; then
        fail "staged runtime Node ACL is unsafe"
    fi
    /usr/bin/codesign --verify --strict "$RUNTIME_NODE_INPUT" || \
        fail "staged runtime Node signature is invalid"
    node_signature="$(/usr/bin/codesign -dvvv "$RUNTIME_NODE_INPUT" 2>&1)"
    [[ "$(printf '%s\n' "$node_signature" | \
        /usr/bin/awk -F= '$1 == "Identifier" {print $2; exit}')" == \
            "$RUNTIME_NODE_IDENTIFIER" && \
        "$(printf '%s\n' "$node_signature" | \
            /usr/bin/awk -F= '$1 == "Signature" {print $2; exit}')" == "adhoc" && \
        "$(printf '%s\n' "$node_signature" | \
            /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')" == "not set" && \
        "$(runtime_code_directory_sha256 "$RUNTIME_NODE_INPUT")" == \
            "$RUNTIME_ADHOC_CODEDIRECTORY_SHA256" ]] || \
        fail "staged runtime Node ad hoc identity differs"
    [[ "$(/usr/bin/lipo -archs "$RUNTIME_NODE_INPUT")" == "arm64" ]] || \
        fail "staged runtime Node architecture differs"
    assert_portable_macho "$RUNTIME_NODE_INPUT"
    [[ -f "$RUNTIME_ENTITLEMENTS" && ! -L "$RUNTIME_ENTITLEMENTS" ]] || \
        fail "runtime Node entitlement policy is unavailable"
    /usr/bin/plutil -lint "$RUNTIME_ENTITLEMENTS" >/dev/null || \
        fail "runtime Node entitlement policy is malformed"
    node_entitlements="$(
        /usr/bin/codesign -d --entitlements :- "$RUNTIME_NODE_INPUT" 2>/dev/null
    )"
    [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.cs\.allow-jit' raw \
        "$RUNTIME_ENTITLEMENTS")" == "true" && \
        "$(/usr/bin/plutil -extract \
            'com\.apple\.security\.cs\.allow-unsigned-executable-memory' raw \
            "$RUNTIME_ENTITLEMENTS")" == "true" && \
        "$(/usr/bin/plutil -p "$RUNTIME_ENTITLEMENTS" | /usr/bin/grep -c '=>')" == "2" && \
        "$(printf '%s' "$node_entitlements" | /usr/bin/plutil -extract \
            'com\.apple\.security\.cs\.allow-jit' raw -o - -)" == "true" && \
        "$(printf '%s' "$node_entitlements" | /usr/bin/plutil -extract \
            'com\.apple\.security\.cs\.allow-unsigned-executable-memory' raw -o - -)" == \
            "true" && \
        "$(printf '%s' "$node_entitlements" | /usr/bin/plutil -p - | \
            /usr/bin/grep -c '=>')" == "2" ]] || \
        fail "staged runtime Node entitlement policy differs"
    entitlement_digest="$(
        printf '%s' \
            '{"com.apple.security.cs.allow-jit":true,"com.apple.security.cs.allow-unsigned-executable-memory":true}' \
            | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
    )"
    [[ "$entitlement_digest" == \
        "7faab808f2696c84032a67166b79e0d9b49128fcf990cdcf696383ac62558a08" ]] || \
        fail "runtime Node canonical entitlement digest differs"
    validate_runtime_native_code "$RUNTIME_INPUT/pi"
}

runtime_code_directory_sha256() {
    /usr/bin/codesign -d --verbose=6 "$1" 2>&1 \
        | /usr/bin/awk -F= '$1 == "CandidateCDHashFull sha256" {print $2; exit}'
}

runtime_code_directory_sha256_for_arch() {
    local executable="$1"
    local architecture="$2"
    /usr/bin/codesign -d --arch "$architecture" --verbose=6 "$executable" 2>&1 \
        | /usr/bin/awk -F= '$1 == "CandidateCDHashFull sha256" {print $2; exit}'
}

validate_runtime_native_code() {
    local root="$1"
    local actual_inventory
    local expected_inventory
    local index
    local module
    local relative_path
    local info
    local architecture_index
    local entitlement_bytes
    local -a architectures
    local -a code_directories

    [[ -d "$root" && ! -L "$root" ]] || fail "release Pi native-code root is unsafe"
    [[ "${#RUNTIME_NATIVE_CODE_RELATIVE_PATHS[@]}" == \
        "${#RUNTIME_NATIVE_CODE_IDENTIFIERS[@]}" && \
        "${#RUNTIME_NATIVE_CODE_RELATIVE_PATHS[@]}" == \
        "${#RUNTIME_NATIVE_CODE_ARCHITECTURES[@]}" && \
        "${#RUNTIME_NATIVE_CODE_RELATIVE_PATHS[@]}" == \
        "${#RUNTIME_NATIVE_CODE_DIRECTORIES[@]}" && \
        "${#RUNTIME_NATIVE_CODE_RELATIVE_PATHS[@]}" == \
        "${#RUNTIME_NATIVE_CODE_MODES[@]}" ]] || \
        fail "release Pi native-code policy is inconsistent"
    expected_inventory="$(
        printf '%s\n' "${RUNTIME_NATIVE_CODE_RELATIVE_PATHS[@]}" | LC_ALL=C /usr/bin/sort
    )"
    actual_inventory="$(
        while IFS= read -r -d '' module; do
            if /usr/bin/file "$module" | /usr/bin/grep -Fq 'Mach-O'; then
                printf '%s\n' "${module#"$root"/}"
            fi
        done < <(/usr/bin/find "$root" -type f -name '*.node' -print0)
    )"
    actual_inventory="$(printf '%s\n' "$actual_inventory" | LC_ALL=C /usr/bin/sort)"
    [[ "$actual_inventory" == "$expected_inventory" ]] || \
        fail "release Pi Mach-O inventory differs"

    for index in "${!RUNTIME_NATIVE_CODE_RELATIVE_PATHS[@]}"; do
        relative_path="${RUNTIME_NATIVE_CODE_RELATIVE_PATHS[$index]}"
        module="$root/$relative_path"
        [[ -f "$module" && ! -L "$module" && \
            "$(/usr/bin/stat -f '%OLp' "$module")" == \
                "${RUNTIME_NATIVE_CODE_MODES[$index]}" && \
            ( "$(/usr/bin/stat -f '%u' "$module")" == "0" || \
                "$(/usr/bin/stat -f '%u' "$module")" == "$(/usr/bin/id -u)" ) && \
            "$(/usr/bin/stat -f '%l' "$module")" == "1" ]] || \
            fail "release Pi native-code metadata differs: $relative_path"
        if path_has_allow_acl "$module"; then
            fail "release Pi native-code ACL differs: $relative_path"
        fi
        [[ "$(/usr/bin/lipo -archs "$module")" == \
            "${RUNTIME_NATIVE_CODE_ARCHITECTURES[$index]}" ]] || \
            fail "release Pi native-code architecture differs: $relative_path"
        /usr/bin/codesign --verify --strict --all-architectures "$module" || \
            fail "release Pi native-code signature is invalid: $relative_path"
        read -r -a architectures <<<"${RUNTIME_NATIVE_CODE_ARCHITECTURES[$index]}"
        read -r -a code_directories <<<"${RUNTIME_NATIVE_CODE_DIRECTORIES[$index]}"
        [[ "${#architectures[@]}" == "${#code_directories[@]}" ]] || \
            fail "release Pi native-code architecture policy differs: $relative_path"
        for architecture_index in "${!architectures[@]}"; do
            info="$(
                /usr/bin/codesign -d --arch "${architectures[$architecture_index]}" \
                    --verbose=6 "$module" 2>&1
            )"
            [[ "$info" == *"Identifier=${RUNTIME_NATIVE_CODE_IDENTIFIERS[$index]}"* && \
                "$info" == *"flags=0x10000(runtime)"* && \
                "$info" == *"Authority=Developer ID Application:"* && \
                "$info" == *"TeamIdentifier=$RUNTIME_NATIVE_CODE_TEAM_IDENTIFIER"* && \
                "$info" == *"Timestamp="* && \
                "$(runtime_code_directory_sha256_for_arch \
                    "$module" "${architectures[$architecture_index]}")" == \
                    "${code_directories[$architecture_index]}" ]] || \
                fail "release Pi native-code identity differs: $relative_path"
            entitlement_bytes="$(
                /usr/bin/codesign -d --arch "${architectures[$architecture_index]}" \
                    --entitlements :- "$module" 2>/dev/null || true
            )"
            [[ -z "$entitlement_bytes" ]] || \
                fail "release Pi native code has entitlements: $relative_path"
        done
    done
}

expected_runtime_code_directory_sha256() {
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        printf '%s\n' "$RUNTIME_ADHOC_CODEDIRECTORY_SHA256"
    else
        printf '%s\n' "$RUNTIME_PRODUCTION_CODEDIRECTORY_SHA256"
    fi
}

sign_runtime_node() {
    local node="$1"
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        /usr/bin/codesign --force --sign - --identifier "$RUNTIME_NODE_IDENTIFIER" \
            --options runtime --entitlements "$RUNTIME_ENTITLEMENTS" "$node"
    elif [[ -n "$SIGNING_KEYCHAIN" ]]; then
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
            --keychain "$SIGNING_KEYCHAIN" --identifier "$RUNTIME_NODE_IDENTIFIER" \
            --entitlements "$RUNTIME_ENTITLEMENTS" "$node"
    else
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
            --identifier "$RUNTIME_NODE_IDENTIFIER" \
            --entitlements "$RUNTIME_ENTITLEMENTS" "$node"
    fi
    [[ "$(runtime_code_directory_sha256 "$node")" == \
        "$(expected_runtime_code_directory_sha256)" ]] || \
        fail "runtime Node CodeDirectory differs from the release signing policy"
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
}

list_rpaths() {
    /usr/bin/otool -l "$1" | /usr/bin/awk '
        $1 == "cmd" && $2 == "LC_RPATH" {
            getline
            getline
            print $2
        }
    '
}

remove_developer_rpaths() {
    local executable="$1"
    local rpath
    while IFS= read -r rpath; do
        case "$rpath" in
            "$DEVELOPER_DIR"/*|"$ROOT"/*)
                /usr/bin/install_name_tool -delete_rpath "$rpath" "$executable"
                ;;
        esac
    done < <(list_rpaths "$executable")
}

assert_portable_macho() {
    local executable="$1"
    local dependency
    local rpath

    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*) ;;
            *) fail "non-system dependency in $executable: $dependency" ;;
        esac
    done < <(/usr/bin/otool -L "$executable" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')

    while IFS= read -r rpath; do
        case "$rpath" in
            /usr/lib/swift|@loader_path) ;;
            *) fail "non-portable rpath in $executable: $rpath" ;;
        esac
    done < <(list_rpaths "$executable")
}

verify_bundle_modes() {
    local mode
    local path
    while IFS= read -r -d '' path; do
        case "$path" in
            "$RELEASE_RUNTIME"|"$RELEASE_RUNTIME"/*) continue ;;
        esac
        mode="$(/usr/bin/stat -f '%OLp' "$path")"
        [[ "$mode" == "755" ]] || fail "bundle directory mode differs: $path"
    done < <(/usr/bin/find "$APP" -type d -print0)

    for path in \
        "$APP_EXECUTABLE" "$ENGINE_EXECUTABLE" "$ASKPASS_EXECUTABLE" \
        "$PUSH_GUARD_EXECUTABLE" "$HERDR_HOST_EXECUTABLE"
    do
        mode="$(/usr/bin/stat -f '%OLp' "$path")"
        [[ "$mode" == "755" ]] || fail "bundle executable mode differs: $path"
    done

    while IFS= read -r -d '' path; do
        case "$path" in
            "$APP_EXECUTABLE"|"$ENGINE_EXECUTABLE"|"$ASKPASS_EXECUTABLE"|\
            "$PUSH_GUARD_EXECUTABLE"|"$HERDR_HOST_EXECUTABLE"|\
            "$RELEASE_RUNTIME"/*) continue ;;
        esac
        mode="$(/usr/bin/stat -f '%OLp' "$path")"
        [[ "$mode" == "644" ]] || fail "bundle resource mode differs: $path"
    done < <(/usr/bin/find "$APP" -type f -print0)
}

sign_path() {
    local path="$1"
    local identifier="$2"
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        /usr/bin/codesign --force --sign - --identifier "$identifier" "$path"
    elif [[ -n "$SIGNING_KEYCHAIN" ]]; then
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
            --keychain "$SIGNING_KEYCHAIN" --identifier "$identifier" "$path"
    else
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
            --identifier "$identifier" "$path"
    fi
}

verify_signing_identity() {
    local identities
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        return
    fi
    [[ "$SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || \
        fail "SIGN_IDENTITY must be a 40-character SHA-1 identity"
    if [[ -n "$SIGNING_KEYCHAIN" ]]; then
        identities="$(
            /usr/bin/security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null
        )"
    else
        identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)"
    fi
    printf '%s\n' "$identities" | /usr/bin/awk -v expected="$SIGN_IDENTITY" '
        toupper($2) == toupper(expected) { found = 1 }
        END { exit(found ? 0 : 1) }
    ' || fail "SIGN_IDENTITY is not a valid local identity"
}

verify_signed_team() {
    local app_team
    local helper_team
    local askpass_team
    local push_guard_team
    local herdr_host_team
    local runtime_node_team
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        return 0
    fi
    app_team="$(/usr/bin/codesign -dvvv "$APP" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    helper_team="$(/usr/bin/codesign -dvvv "$ENGINE_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    askpass_team="$(/usr/bin/codesign -dvvv "$ASKPASS_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    push_guard_team="$(/usr/bin/codesign -dvvv "$PUSH_GUARD_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    herdr_host_team="$(/usr/bin/codesign -dvvv "$HERDR_HOST_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    runtime_node_team="$(/usr/bin/codesign -dvvv "$RELEASE_RUNTIME/node/bin/node" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    [[ -n "$app_team" && "$app_team" != "not set" && \
        "$app_team" == "$helper_team" && "$app_team" == "$askpass_team" && \
        "$app_team" == "$push_guard_team" && "$app_team" == "$herdr_host_team" && \
        "$app_team" == "$runtime_node_team" ]] || \
        fail "signed app and helpers do not share a concrete TeamIdentifier"
}

[[ "$ALLOW_ADHOC_SIGNING" == "0" || "$ALLOW_ADHOC_SIGNING" == "1" ]] || \
    fail "ALLOW_ADHOC_SIGNING must be 0 or 1"
if [[ "$SIGN_IDENTITY" == "-" && "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    fail "release packaging requires an explicit SIGN_IDENTITY"
fi
configure_signing_keychain
verify_signing_identity
capture_source_identity
validate_runtime_input
"$ROOT/scripts/verify-toolchain.sh"

for input in \
    "$ROOT/Packaging/Info.plist" \
    "$ROOT/Packaging/app-inventory.txt" \
    "$ROOT/Packaging/runtime-node-entitlements.plist" \
    "$ROOT/Packaging/com.maroffo.JidokaCode.Engine.plist" \
    "$RELEASE_IDENTITY_GENERATOR" \
    "$ROOT/Resources/Herdr/api-schema-0.8.2.json" \
    "$ROOT/Resources/Herdr/runtime-builds.json" \
    "$ROOT/Resources/Pi/manifest.json" \
    "$ROOT/Resources/Pi/workflow-resources.json" \
    "$ROOT/Resources/Pi/tui-resources.json" \
    "$ROOT/Resources/Pi/extensions/jidoka-code.ts" \
    "$ROOT/Resources/Pi/extensions/jidoka-deny-user-bash.js" \
    "$ROOT/Resources/Pi/extensions/jidoka-runtime.ts" \
    "$ROOT/Resources/Pi/extensions/jidoka-tui-runtime.ts" \
    "$ROOT/Resources/Pi/runtime/jidoka-extension-contract.mjs" \
    "$ROOT/Resources/Pi/runtime/jidoka-model-catalog.mjs" \
    "$ROOT/Resources/Pi/runtime/jidoka-tui-contract.mjs" \
    "$ROOT/Resources/Pi/runtime/node-runtime-builds.json" \
    "$ROOT/Resources/Pi/runtime/pi-runtime-builds.json" \
    "$ROOT/Resources/Pi/runtime/release-runtime.json" \
    "$ROOT/Resources/Pi/skills/jidoka-code-issue-triage/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-orchestrate/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-plan/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-pr-review/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-review-architecture/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-review-security/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-review-test/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-synthesize/SKILL.md" \
    "$ROOT/Resources/Pi/workflow-skills/jidoka-code-orchestration-fidelity/SKILL.md" \
    "$ROOT/Resources/Pi/workflow-skills/jidoka-code-planning-fidelity/SKILL.md" \
    "$ROOT/Resources/Pi/workflow-skills/jidoka-code-pr-fidelity/SKILL.md" \
    "$ROOT/Resources/Pi/workflow-skills/jidoka-code-triage-fidelity/SKILL.md" \
    "$ROOT/scripts/spikes/jidoka-local-spikes.mjs" \
    "$ROOT/scripts/spikes/pi-runtime-attestation.mjs" \
    "$ROOT/scripts/spikes/pi-rpc-profile-probe.mjs" \
    "$ROOT/scripts/spikes/pi-rpc-workflow-probe.mjs"
do
    [[ -f "$input" && ! -L "$input" ]] || fail "input must be a regular non-symbolic file: $input"
done

if [[ -e "$BUILD_ROOT" || -L "$BUILD_ROOT" ]]; then
    [[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] || fail "build root is not a regular directory"
else
    /bin/mkdir -p "$BUILD_ROOT"
fi
[[ "$(cd "$BUILD_ROOT" && pwd -P)" == "$ROOT/build" ]] || fail "build root escapes repository"
validate_runtime_inventory_destination

cd "$ROOT"
verifier_build_arguments=(
    --configuration release
    --scratch-path "$ROOT/.build/adhoc-runtime-testing"
    -Xswiftc -DJIDOKA_ADHOC_RUNTIME_TESTING
)
readonly -a verifier_build_arguments
/usr/bin/xcrun swift build "${verifier_build_arguments[@]}" --product JidokaCodeApp
/usr/bin/xcrun swift build \
    "${verifier_build_arguments[@]}" --product JidokaCodeBoundedCommand
VERIFIER_BIN_DIR="$(
    /usr/bin/xcrun swift build "${verifier_build_arguments[@]}" --show-bin-path
)"
VERIFIER_BIN_DIR="$(cd "$VERIFIER_BIN_DIR" && pwd -P)"
readonly VERIFIER_BIN_DIR
case "$VERIFIER_BIN_DIR" in
    "$ROOT/.build/"*) ;;
    *) fail "staged verifier binary directory escapes .build" ;;
esac
readonly STAGED_RUNTIME_VERIFIER="$VERIFIER_BIN_DIR/JidokaCodeApp"
BOUNDED_COMMAND_RUNNER="$VERIFIER_BIN_DIR/JidokaCodeBoundedCommand"
readonly BOUNDED_COMMAND_RUNNER
[[ -f "$STAGED_RUNTIME_VERIFIER" && -x "$STAGED_RUNTIME_VERIFIER" && \
    ! -L "$STAGED_RUNTIME_VERIFIER" ]] || fail "staged runtime verifier is unavailable"
[[ -f "$BOUNDED_COMMAND_RUNNER" && -x "$BOUNDED_COMMAND_RUNNER" && \
    ! -L "$BOUNDED_COMMAND_RUNNER" ]] || fail "native bounded command runner is unavailable"
verify_staged_runtime_performance "$STAGED_RUNTIME_VERIFIER"

swift_build_arguments=(--configuration release)
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    swift_build_arguments=("${verifier_build_arguments[@]}")
fi
readonly -a swift_build_arguments
/usr/bin/xcrun swift build "${swift_build_arguments[@]}" --product JidokaCodeApp
/usr/bin/xcrun swift build "${swift_build_arguments[@]}" --product JidokaCodeEngineProbe
/usr/bin/xcrun swift build "${swift_build_arguments[@]}" --product JidokaCodeAskPass
/usr/bin/xcrun swift build "${swift_build_arguments[@]}" --product JidokaCodePushGuard
/usr/bin/xcrun swift build "${swift_build_arguments[@]}" --product JidokaCodeHerdrHost
BIN_DIR="$(/usr/bin/xcrun swift build "${swift_build_arguments[@]}" --show-bin-path)"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
readonly BIN_DIR
case "$BIN_DIR" in
    "$ROOT/.build/"*) ;;
    *) fail "SwiftPM binary directory escapes .build: $BIN_DIR" ;;
esac

for executable in \
    "$BIN_DIR/JidokaCodeApp" \
    "$BIN_DIR/JidokaCodeEngineProbe" \
    "$BIN_DIR/JidokaCodeAskPass" \
    "$BIN_DIR/JidokaCodePushGuard" \
    "$BIN_DIR/JidokaCodeHerdrHost"
do
    [[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] || \
        fail "missing regular SwiftPM product: $executable"
done
if [[ -e "$APP" || -L "$APP" ]]; then
    [[ ! -L "$APP" ]] || fail "refusing symbolic app output"
    /bin/rm -rf -- "$APP"
fi
/bin/mkdir -p \
    "$MACOS" \
    "$HELPERS" \
    "$GIT_HOOKS" \
    "$LAUNCH_AGENTS" \
    "$HERDR_RESOURCES" \
    "$RELEASE_RUNTIME/licenses" \
    "$RELEASE_RUNTIME/node/bin" \
    "$RESOURCES/Spikes" \
    "$RESOURCES/Pi/extensions" \
    "$RESOURCES/Pi/runtime" \
    "$RESOURCES/Pi/skills/jidoka-code-issue-triage" \
    "$RESOURCES/Pi/skills/jidoka-code-orchestrate" \
    "$RESOURCES/Pi/skills/jidoka-code-plan" \
    "$RESOURCES/Pi/skills/jidoka-code-pr-review" \
    "$RESOURCES/Pi/skills/jidoka-code-review-architecture" \
    "$RESOURCES/Pi/skills/jidoka-code-review-security" \
    "$RESOURCES/Pi/skills/jidoka-code-review-test" \
    "$RESOURCES/Pi/skills/jidoka-code-synthesize" \
    "$RESOURCES/Pi/workflow-skills/jidoka-code-orchestration-fidelity" \
    "$RESOURCES/Pi/workflow-skills/jidoka-code-planning-fidelity" \
    "$RESOURCES/Pi/workflow-skills/jidoka-code-pr-fidelity" \
    "$RESOURCES/Pi/workflow-skills/jidoka-code-triage-fidelity"

/usr/bin/install -m 0755 "$BIN_DIR/JidokaCodeApp" "$APP_EXECUTABLE"
/usr/bin/install -m 0755 "$BIN_DIR/JidokaCodeEngineProbe" "$ENGINE_EXECUTABLE"
/usr/bin/install -m 0755 "$BIN_DIR/JidokaCodeAskPass" "$ASKPASS_EXECUTABLE"
/usr/bin/install -m 0755 "$BIN_DIR/JidokaCodePushGuard" "$PUSH_GUARD_EXECUTABLE"
/usr/bin/install -m 0755 "$BIN_DIR/JidokaCodeHerdrHost" "$HERDR_HOST_EXECUTABLE"
/usr/bin/install -m 0644 "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
/usr/bin/install -m 0644 \
    "$ROOT/Packaging/com.maroffo.JidokaCode.Engine.plist" \
    "$LAUNCH_AGENTS/com.maroffo.JidokaCode.Engine.plist"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Herdr/api-schema-0.8.2.json" \
    "$HERDR_RESOURCES/api-schema-0.8.2.json"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Herdr/runtime-builds.json" \
    "$HERDR_RESOURCES/runtime-builds.json"
/usr/bin/install -m 0644 "$ROOT/Resources/Pi/manifest.json" "$RESOURCES/Pi/manifest.json"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/workflow-resources.json" \
    "$RESOURCES/Pi/workflow-resources.json"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/tui-resources.json" \
    "$RESOURCES/Pi/tui-resources.json"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/extensions/jidoka-code.ts" \
    "$RESOURCES/Pi/extensions/jidoka-code.ts"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/extensions/jidoka-deny-user-bash.js" \
    "$RESOURCES/Pi/extensions/jidoka-deny-user-bash.js"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/extensions/jidoka-runtime.ts" \
    "$RESOURCES/Pi/extensions/jidoka-runtime.ts"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/extensions/jidoka-tui-runtime.ts" \
    "$RESOURCES/Pi/extensions/jidoka-tui-runtime.ts"
for skill in \
    jidoka-code-issue-triage \
    jidoka-code-orchestrate \
    jidoka-code-plan \
    jidoka-code-pr-review \
    jidoka-code-review-architecture \
    jidoka-code-review-security \
    jidoka-code-review-test \
    jidoka-code-synthesize
do
    /usr/bin/install -m 0644 \
        "$ROOT/Resources/Pi/skills/$skill/SKILL.md" \
        "$RESOURCES/Pi/skills/$skill/SKILL.md"
done
for skill in \
    jidoka-code-orchestration-fidelity \
    jidoka-code-planning-fidelity \
    jidoka-code-pr-fidelity \
    jidoka-code-triage-fidelity
do
    /usr/bin/install -m 0644 \
        "$ROOT/Resources/Pi/workflow-skills/$skill/SKILL.md" \
        "$RESOURCES/Pi/workflow-skills/$skill/SKILL.md"
done
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/runtime/jidoka-extension-contract.mjs" \
    "$RESOURCES/Pi/runtime/jidoka-extension-contract.mjs"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/runtime/jidoka-model-catalog.mjs" \
    "$RESOURCES/Pi/runtime/jidoka-model-catalog.mjs"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/runtime/jidoka-tui-contract.mjs" \
    "$RESOURCES/Pi/runtime/jidoka-tui-contract.mjs"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/runtime/node-runtime-builds.json" \
    "$RESOURCES/Pi/runtime/node-runtime-builds.json"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/runtime/pi-runtime-builds.json" \
    "$RESOURCES/Pi/runtime/pi-runtime-builds.json"
/usr/bin/install -m 0644 \
    "$ROOT/scripts/spikes/pi-runtime-attestation.mjs" \
    "$RESOURCES/Pi/runtime/pi-runtime-attestation.mjs"
/usr/bin/install -m 0644 \
    "$ROOT/scripts/spikes/pi-rpc-profile-probe.mjs" \
    "$RESOURCES/Pi/runtime/pi-rpc-profile-probe.mjs"
/usr/bin/install -m 0644 \
    "$ROOT/scripts/spikes/pi-rpc-workflow-probe.mjs" \
    "$RESOURCES/Pi/runtime/pi-rpc-workflow-probe.mjs"
/usr/bin/install -m 0644 \
    "$ROOT/scripts/spikes/jidoka-local-spikes.mjs" \
    "$RESOURCES/Spikes/jidoka-local-spikes.mjs"

/usr/bin/install -m 0444 \
    "$RUNTIME_INPUT/runtime-manifest.json" \
    "$RELEASE_RUNTIME/runtime-manifest.json"
/usr/bin/install -m 0444 \
    "$RUNTIME_INPUT/licenses/node-LICENSE" \
    "$RELEASE_RUNTIME/licenses/node-LICENSE"
/usr/bin/ditto --norsrc --noextattr --noqtn \
    "$RUNTIME_INPUT/pi" \
    "$RELEASE_RUNTIME/pi"
validate_runtime_native_code "$RELEASE_RUNTIME/pi"
/usr/bin/install -m 0555 "$RUNTIME_NODE_INPUT" "$RELEASE_RUNTIME/node/bin/node"
/usr/bin/codesign --remove-signature "$RELEASE_RUNTIME/node/bin/node"
sign_runtime_node "$RELEASE_RUNTIME/node/bin/node"

/usr/bin/strip -S \
    "$APP_EXECUTABLE" "$ENGINE_EXECUTABLE" "$ASKPASS_EXECUTABLE" \
    "$PUSH_GUARD_EXECUTABLE" "$HERDR_HOST_EXECUTABLE"
remove_developer_rpaths "$APP_EXECUTABLE"
remove_developer_rpaths "$ENGINE_EXECUTABLE"
remove_developer_rpaths "$ASKPASS_EXECUTABLE"
remove_developer_rpaths "$PUSH_GUARD_EXECUTABLE"
remove_developer_rpaths "$HERDR_HOST_EXECUTABLE"
assert_portable_macho "$APP_EXECUTABLE"
assert_portable_macho "$ENGINE_EXECUTABLE"
assert_portable_macho "$ASKPASS_EXECUTABLE"
assert_portable_macho "$PUSH_GUARD_EXECUTABLE"
assert_portable_macho "$HERDR_HOST_EXECUTABLE"

[[ "$(/usr/bin/shasum -a 256 "$HERDR_RESOURCES/api-schema-0.8.2.json" | /usr/bin/awk '{print $1}')" == \
    "c48f1f54ee0150ca27e11fd44455fe94aeadb20fdf4e4a62393ed822a4e5b150" ]] || \
    fail "packaged Herdr API schema digest differs"
[[ "$(/usr/bin/shasum -a 256 "$HERDR_RESOURCES/runtime-builds.json" | /usr/bin/awk '{print $1}')" == \
    "45674e216b931f7c736c1c8348e899221c2aef080dfa6a92392144b244cd5867" ]] || \
    fail "packaged Herdr runtime policy digest differs"
/usr/bin/plutil -convert xml1 -o /dev/null "$HERDR_RESOURCES/runtime-builds.json"
/usr/bin/plutil -lint "$CONTENTS/Info.plist"
/usr/bin/plutil -lint "$LAUNCH_AGENTS/com.maroffo.JidokaCode.Engine.plist"
sign_path "$ENGINE_EXECUTABLE" com.maroffo.JidokaCode.Engine
sign_path "$ASKPASS_EXECUTABLE" com.maroffo.JidokaCode.AskPass
sign_path "$PUSH_GUARD_EXECUTABLE" com.maroffo.JidokaCode.PushGuard
sign_path "$HERDR_HOST_EXECUTABLE" com.maroffo.JidokaCode.HerdrHost
generate_release_identity_manifest "$STAGED_RUNTIME_IDENTITY_SHA256"
sign_path "$APP" com.maroffo.JidokaCode
capture_packaged_runtime_identity
generate_release_identity_manifest "$PACKAGED_RUNTIME_IDENTITY_SHA256"
sign_path "$APP" com.maroffo.JidokaCode
verify_bundle_modes
/usr/bin/codesign --verify --strict "$ENGINE_EXECUTABLE"
/usr/bin/codesign --verify --strict "$ASKPASS_EXECUTABLE"
/usr/bin/codesign --verify --strict "$PUSH_GUARD_EXECUTABLE"
/usr/bin/codesign --verify --strict "$HERDR_HOST_EXECUTABLE"
/usr/bin/codesign --verify --strict "$RELEASE_RUNTIME/node/bin/node"
/usr/bin/codesign --verify --strict --deep "$APP"
[[ "$(runtime_code_directory_sha256 "$RELEASE_RUNTIME/node/bin/node")" == \
    "$(expected_runtime_code_directory_sha256)" ]] || \
    fail "outer signing changed the runtime Node CodeDirectory"
verify_signed_team
validate_runtime_native_code "$RELEASE_RUNTIME/pi"
verify_packaged_runtime_identity

validate_runtime_inventory_destination
RUNTIME_INVENTORY_TEMP="$(/usr/bin/mktemp "$BUILD_ROOT/.runtime-inventory.XXXXXX")"
[[ -f "$RUNTIME_INVENTORY_TEMP" && ! -L "$RUNTIME_INVENTORY_TEMP" && \
    "$(/usr/bin/stat -f '%OLp' "$RUNTIME_INVENTORY_TEMP")" == "600" && \
    "$(/usr/bin/stat -f '%l' "$RUNTIME_INVENTORY_TEMP")" == "1" ]] || \
    fail "private release runtime inventory could not be created"
(
    cd "$APP"
    /usr/bin/find ./Contents/Resources/PiRuntime -print | LC_ALL=C /usr/bin/sort \
        >"$RUNTIME_INVENTORY_TEMP"
)
/bin/mv -f -- "$RUNTIME_INVENTORY_TEMP" "$RUNTIME_INVENTORY"
RUNTIME_INVENTORY_TEMP=""
actual_inventory="$(cd "$APP" && /usr/bin/find . -print | LC_ALL=C /usr/bin/sort)"
expected_inventory="$({
    /bin/cat "$ROOT/Packaging/app-inventory.txt"
    /bin/cat "$RUNTIME_INVENTORY"
} | LC_ALL=C /usr/bin/sort)"
[[ "$actual_inventory" == "$expected_inventory" ]] || fail "bundle inventory differs from allowlist"
[[ -z "$(/usr/bin/find "$APP" -type l ! -path "$RELEASE_RUNTIME/pi/*" -print)" ]] || \
    fail "bundle contains a non-runtime symbolic link"
[[ -z "$(/usr/bin/find "$APP" -type f -name herdr -print)" ]] || \
    fail "external Herdr runtime must not be bundled"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf 'signing=adhoc\n'
else
    printf 'signing=identity\n'
fi
printf 'packaged=%s\n' "$APP"
