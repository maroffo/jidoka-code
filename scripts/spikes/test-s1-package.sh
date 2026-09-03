#!/usr/bin/env bash
set -euo pipefail

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly SOURCE_APP="$ROOT/build/Jidoka Code.app"
readonly SOURCE_EXECUTABLE="$SOURCE_APP/Contents/MacOS/Jidoka Code"
readonly SOURCE_ENGINE="$SOURCE_APP/Contents/Helpers/JidokaCodeEngineProbe"
readonly SOURCE_ASKPASS="$SOURCE_APP/Contents/Helpers/JidokaCodeAskPass"
readonly SOURCE_PUSH_GUARD="$SOURCE_APP/Contents/Helpers/GitHooks/pre-push"
readonly SOURCE_HERDR_HOST="$SOURCE_APP/Contents/Helpers/JidokaCodeHerdrHost"
SOURCE_RELEASE_RUNTIME_ROOT="${JIDOKA_RELEASE_RUNTIME_ROOT:-$ROOT/build/runtime-input/qualified-runtime}"
readonly SOURCE_RELEASE_RUNTIME_ROOT
BOUNDED_COMMAND_RUNNER=""
# Ten minutes permits full strict validation of the 14,551-entry runtime while
# turning a pathological verifier into a bounded, process-group-scoped failure.
readonly PACKAGED_EXECUTABLE_TIMEOUT_SECONDS=600
readonly PUSH_GUARD_EOF_BOUND_SECONDS=10
JIDOKA_RELEASE_RUNTIME_ROOT=""
NODE_BIN=""
NORMAL_RELEASE_EXECUTABLE=""
TEMP_ROOT=""

fail() {
    printf 'S1 package E2E failed: %s\n' "$1" >&2
    exit 1
}

build_bounded_command_runner() {
    local bin_dir
    local runner
    local scratch="$ROOT/.build/s1-bounded-command"
    /usr/bin/xcrun swift build \
        --scratch-path "$scratch" \
        --configuration release \
        --product JidokaCodeBoundedCommand >&2
    bin_dir="$(
        /usr/bin/xcrun swift build \
            --scratch-path "$scratch" \
            --configuration release \
            --show-bin-path
    )"
    bin_dir="$(cd "$bin_dir" && pwd -P)"
    case "$bin_dir" in
        "$ROOT/.build/"*) ;;
        *) fail "native bounded command directory escapes .build" ;;
    esac
    runner="$bin_dir/JidokaCodeBoundedCommand"
    [[ -f "$runner" && -x "$runner" && ! -L "$runner" ]] || \
        fail "native bounded command runner is unavailable"
    printf '%s\n' "$runner"
}

cleanup_owned_path() {
    local path="$1"
    local name
    [[ -n "$path" && -d "$path" && ! -L "$path" ]] || return 1
    name="$(/usr/bin/basename "$path")"
    case "$name" in
        jidoka-code-s1.*) /bin/rm -rf -- "$path" ;;
        *) return 1 ;;
    esac
}

cleanup() {
    if [[ -n "${runtime_inventory:-}" && -L "$runtime_inventory" && \
        "$(/usr/bin/readlink "$runtime_inventory")" == "${runtime_inventory_sentinel:-}" ]]; then
        /bin/rm -f -- "$runtime_inventory"
        if [[ -f "${runtime_inventory_backup:-}" ]]; then
            /bin/mv "$runtime_inventory_backup" "$runtime_inventory"
        fi
    fi
    if [[ -n "$TEMP_ROOT" && -e "$TEMP_ROOT" ]]; then
        cleanup_owned_path "$TEMP_ROOT" || printf 'refusing unexpected cleanup path: %s\n' "$TEMP_ROOT" >&2
    fi
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

codesign_identifier() {
    /usr/bin/codesign -d --verbose=4 "$1" 2>&1 | \
        /usr/bin/awk -F= '$1 == "Identifier" { print $2; exit }'
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

assert_exact_json_keys() {
    local json_path="$1"
    shift
    local scratch="$TEMP_ROOT/remaining-$RANDOM.plist"
    local key
    /bin/cp "$json_path" "$scratch"
    /usr/bin/plutil -convert xml1 -o /dev/null "$json_path"
    [[ "$(/usr/bin/wc -l < "$json_path" | /usr/bin/tr -d ' ')" == "1" ]] || \
        fail "structured output must contain exactly one line"
    for key in "$@"; do
        /usr/bin/plutil -extract "$key" raw "$json_path" >/dev/null
        /usr/bin/plutil -remove "$key" "$scratch"
    done
    [[ "$(/usr/bin/plutil -convert json -o - "$scratch")" == "{}" ]] || \
        fail "structured output contains unexpected keys"
    /bin/rm -f -- "$scratch"
}

run_packaged_command() {
    local executable="$1"
    local stdout_path="$2"
    local stderr_path="$3"
    local status=0
    shift 3
    /bin/mkdir -p "$TEMP_ROOT/home" "$TEMP_ROOT/runtime-tmp"
    (
        cd /
        /usr/bin/env -i \
            HOME="$TEMP_ROOT/home" \
            PATH="/usr/bin:/bin" \
            TMPDIR="$TEMP_ROOT/runtime-tmp" \
            "$BOUNDED_COMMAND_RUNNER" \
            "$PACKAGED_EXECUTABLE_TIMEOUT_SECONDS" \
            "$executable" "$@"
    ) </dev/null >"$stdout_path" 2>"$stderr_path" || status=$?
    case "$status" in
        0) return 0 ;;
        124)
            fail "packaged executable timed out after ${PACKAGED_EXECUTABLE_TIMEOUT_SECONDS}s: $executable"
            ;;
        125) fail "packaged executable identity cleanup failed: $executable" ;;
        126) fail "packaged executable output exceeded its bounded capture: $executable" ;;
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

assert_failure() {
    local executable="$1"
    local expected_error="$2"
    local stdout_path="$TEMP_ROOT/failure.stdout"
    local stderr_path="$TEMP_ROOT/failure.stderr"
    if run_packaged_command \
        "$executable" "$stdout_path" "$stderr_path" --preflight
    then
        fail "preflight unexpectedly succeeded: $expected_error"
    fi
    [[ ! -s "$stdout_path" ]] || fail "failed preflight wrote stdout"
    /usr/bin/grep -Fq "$expected_error" "$stderr_path" || \
        fail "missing expected failure: $expected_error"
}

assert_pi_runner_failure() {
    local app="$1"
    local stdout_path="$TEMP_ROOT/pi-runner-failure.stdout"
    local stderr_path="$TEMP_ROOT/pi-runner-failure.stderr"
    if run_packaged_command \
        "$app/Contents/MacOS/Jidoka Code" \
        "$stdout_path" \
        "$stderr_path" \
        --pi-probe preflight
    then
        fail "mutated packaged Pi runner unexpectedly executed"
    fi
    [[ ! -s "$stdout_path" ]] || fail "mutated packaged Pi runner wrote stdout"
    /usr/bin/grep -Fq 'invalidPackagedRunner' "$stderr_path" || \
        fail "mutated packaged Pi runner did not fail digest attestation"
}

assert_pi_policy_failure() {
    local app="$1"
    local stdout_path="$TEMP_ROOT/pi-policy-failure.stdout"
    local stderr_path="$TEMP_ROOT/pi-policy-failure.stderr"
    if run_packaged_command \
        "$app/Contents/MacOS/Jidoka Code" \
        "$stdout_path" \
        "$stderr_path" \
        --pi-probe preflight
    then
        fail "mutated packaged Pi policy unexpectedly executed"
    fi
    [[ ! -s "$stdout_path" ]] || fail "mutated packaged Pi policy wrote stdout"
    /usr/bin/grep -Fq 'runnerFailed(1)' "$stderr_path" || \
        fail "mutated packaged Pi policy did not fail runtime attestation"
}

assert_release_runtime_valid() {
    local app="$1"
    local stdout_path="$TEMP_ROOT/release-runtime-valid.stdout"
    local stderr_path="$TEMP_ROOT/release-runtime-valid.stderr"
    run_packaged_command \
        "$app/Contents/MacOS/Jidoka Code" \
        "$stdout_path" \
        "$stderr_path" \
        --release-runtime-verify-adhoc || \
        fail "fresh release runtime clone failed before mutation"
    [[ -s "$stdout_path" && ! -s "$stderr_path" ]] || \
        fail "fresh release runtime clone emitted invalid verification output"
    assert_exact_json_keys \
        "$stdout_path" schemaVersion runtimeID manifestSHA256 runtimeIdentitySHA256
}

assert_release_runtime_failure() {
    local app="$1"
    local expected_code="$2"
    local expected_detail="$3"
    local stdout_path="$TEMP_ROOT/release-runtime-failure.stdout"
    local stderr_path="$TEMP_ROOT/release-runtime-failure.stderr"
    if run_packaged_command \
        "$app/Contents/MacOS/Jidoka Code" \
        "$stdout_path" \
        "$stderr_path" \
        --release-runtime-verify-adhoc
    then
        fail "mutated release runtime unexpectedly passed"
    fi
    [[ ! -s "$stdout_path" ]] || fail "mutated release runtime wrote stdout"
    /usr/bin/grep -Fxq \
        "release runtime bundle failed validation: ${expected_code}: ${expected_detail}" \
        "$stderr_path" || \
        fail "mutated release runtime did not report ${expected_code}: ${expected_detail}"
}

assert_fresh_release_runtime_mutation() {
    local mutation="$1"
    local app="$MUTATED_RELEASE_RUNTIME_APP"
    local runtime="$app/Contents/Resources/PiRuntime"
    local sdk="$runtime/pi/dist/core/sdk.js"
    local manifest="$runtime/runtime-manifest.json"
    local expected_code
    local expected_detail

    /bin/rm -rf -- "$app"
    /bin/cp -cR "$COPIED_APP" "$app"
    assert_release_runtime_valid "$app"
    case "$mutation" in
        pi-bytes)
            expected_code="releaseRuntimeDrift"
            expected_detail="release Pi critical file differs"
            printf '\n' >>"$sdk"
            ;;
        manifest-bytes)
            expected_code="releaseManifestDrift"
            expected_detail="release runtime manifest digest differs"
            /bin/chmod 0644 "$manifest"
            printf '\n' >>"$manifest"
            /bin/chmod 0444 "$manifest"
            ;;
        writable-mode)
            expected_code="unsafeReleaseRuntime"
            expected_detail="release runtime file metadata is unsafe"
            /bin/chmod 0666 "$sdk"
            ;;
        extra-entry)
            expected_code="releaseRuntimeDrift"
            expected_detail="release Pi package tree differs"
            printf 'extra\n' >"$runtime/pi/extra-runtime-entry"
            ;;
        hard-link)
            expected_code="unsafeReleaseRuntime"
            expected_detail="release runtime file metadata is unsafe"
            /bin/ln "$sdk" "$runtime/pi/dist/core/sdk-hard-link.js"
            ;;
        acl)
            expected_code="unsafeReleaseRuntime"
            expected_detail="release runtime file metadata is unsafe"
            /bin/chmod +a 'everyone allow write' "$sdk"
            ;;
        escaping-symlink)
            expected_code="releaseRuntimeDrift"
            expected_detail="release Pi package symbolic link escapes its root"
            /bin/ln -s ../runtime-manifest.json "$runtime/pi/escaping-runtime-link"
            ;;
        unsigned-node)
            expected_code="releaseSignatureInvalid"
            expected_detail="release application or Node signature differs"
            /usr/bin/codesign --remove-signature "$runtime/node/bin/node"
            ;;
        *) fail "unknown release runtime mutation: $mutation" ;;
    esac
    /usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode "$app"
    assert_release_runtime_failure "$app" "$expected_code" "$expected_detail"
    /bin/rm -rf -- "$app"
}

build_normal_release_oracles() {
    local normal_stderr="$TEMP_ROOT/normal-release-adhoc.stderr"
    local normal_stdout="$TEMP_ROOT/normal-release-adhoc.stdout"
    local scratch="$TEMP_ROOT/normal-release-build"
    local strings_path="$TEMP_ROOT/normal-release.strings"

    /usr/bin/xcrun swift build \
        --scratch-path "$scratch" \
        --configuration release \
        --product JidokaCodeApp
    NORMAL_RELEASE_EXECUTABLE="$(
        /usr/bin/xcrun swift build \
            --scratch-path "$scratch" \
            --configuration release \
            --show-bin-path
    )/JidokaCodeApp"
    [[ -f "$NORMAL_RELEASE_EXECUTABLE" && -x "$NORMAL_RELEASE_EXECUTABLE" && \
        ! -L "$NORMAL_RELEASE_EXECUTABLE" ]] || fail "normal release app product is unavailable"
    if run_packaged_command \
        "$NORMAL_RELEASE_EXECUTABLE" \
        "$normal_stdout" \
        "$normal_stderr" \
        --release-runtime-verify-adhoc
    then
        fail "normal release binary exposed ad hoc runtime verification"
    fi
    [[ ! -s "$normal_stdout" ]] || fail "normal release ad hoc rejection wrote stdout"
    /usr/bin/grep -Fxq 'unsupported release runtime verification command' \
        "$normal_stderr" || fail "normal release binary recognized the ad hoc verifier"
    /usr/bin/strings "$NORMAL_RELEASE_EXECUTABLE" >"$strings_path"
    for forbidden in \
        '--release-runtime-verify-adhoc' \
        '--release-runtime-verify-developer-id' \
        '/opt/homebrew/bin/pi' \
        '/opt/homebrew/bin/node' \
        '/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js' \
        '/usr/local/bin/pi' \
        '/usr/local/bin/node' \
        '/usr/bin/node'
    do
        if /usr/bin/grep -Fq -- "$forbidden" "$strings_path"; then
            fail "normal release binary contains forbidden runtime authority: $forbidden"
        fi
    done
}

assert_production_authority_failure() {
    local app="$1"
    local stderr_path="$TEMP_ROOT/production-authority-failure.stderr"
    local stdout_path="$TEMP_ROOT/production-authority-failure.stdout"
    if run_packaged_command \
        "$app/Contents/MacOS/Jidoka Code" \
        "$stdout_path" \
        "$stderr_path" \
        --release-runtime-verify-production
    then
        fail "ad hoc re-sign obtained production runtime authority"
    fi
    [[ ! -s "$stdout_path" ]] || fail "production authority rejection wrote stdout"
    /usr/bin/grep -Fq 'unsafeReleaseRuntime' "$stderr_path" || \
        fail "user-renamable production runtime did not fail the installed-path policy"
}

assert_cleanup_guard() {
    local parent
    local owned
    local refused
    parent="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-cleanup-test.XXXXXX")"
    owned="$parent/jidoka-code-s1.owned"
    refused="$parent/not-owned"
    /bin/mkdir -p "$owned" "$refused"
    /usr/bin/touch "$parent/sibling-sentinel"
    cleanup_owned_path "$owned"
    [[ ! -e "$owned" && -d "$refused" && -f "$parent/sibling-sentinel" ]] || \
        fail "owned cleanup removed the wrong path"
    if cleanup_owned_path "$refused"; then
        fail "cleanup accepted a non-owned path"
    fi
    /bin/rm -rf -- "$parent"
}

assert_component_relocation_policy() {
    local app="$1"
    local component_root="$TEMP_ROOT/component-policy-root"
    local expected_bom_modes="$TEMP_ROOT/component-policy-expected-bom-modes.txt"
    local locked_bom_modes="$TEMP_ROOT/component-policy-locked-bom-modes.txt"
    local locked_expanded="$TEMP_ROOT/component-policy-locked-expanded"
    local locked_package="$TEMP_ROOT/component-policy-locked.pkg"
    local locked_package_info
    local policy="$ROOT/Packaging/app-component.plist"

    [[ -f "$policy" && ! -L "$policy" ]] || fail "component policy is unavailable"
    /usr/bin/plutil -lint "$policy" >/dev/null || fail "component policy is invalid"
    [[ "$(/usr/bin/xmllint --xpath 'count(/plist/array/dict)' "$policy")" == "1" && \
        "$(/usr/bin/xmllint --xpath 'count(/plist/array/dict/key)' "$policy")" == "5" && \
        "$(/usr/bin/plutil -extract 0.RootRelativeBundlePath raw "$policy")" == \
            "JidokaCode/Applications/Jidoka Code.app" && \
        "$(/usr/bin/plutil -extract 0.BundleIsRelocatable raw "$policy")" == "false" && \
        "$(/usr/bin/plutil -extract 0.BundleIsVersionChecked raw "$policy")" == "true" && \
        "$(/usr/bin/plutil -extract 0.BundleHasStrictIdentifier raw "$policy")" == "true" && \
        "$(/usr/bin/plutil -extract 0.BundleOverwriteAction raw "$policy")" == "upgrade" ]] || \
        fail "component policy values differ"

    /bin/mkdir -m 0755 "$component_root"
    /bin/mkdir -m 0755 "$component_root/JidokaCode"
    /bin/mkdir -m 0755 "$component_root/JidokaCode/Applications"
    /usr/bin/ditto "$app" "$component_root/JidokaCode/Applications/Jidoka Code.app"

    /usr/bin/pkgbuild \
        --root "$component_root" \
        --component-plist "$policy" \
        --ownership recommended \
        --install-location "/Library/Application Support" \
        --identifier com.maroffo.JidokaCode.pkg \
        --version 0.1.1 \
        "$locked_package" >/dev/null
    /usr/sbin/pkgutil --expand "$locked_package" "$locked_expanded"
    locked_package_info="$locked_expanded/PackageInfo"
    [[ "$(/usr/bin/xmllint --xpath \
        "count(/pkg-info[@identifier='com.maroffo.JidokaCode.pkg' and @version='0.1.1' and @install-location='/Library/Application Support' and @postinstall-action='none' and @auth='root' and @relocatable='false'])" \
        "$locked_package_info")" == "1" ]] || fail "locked component package policy differs"
    [[ "$(/usr/bin/xmllint --xpath 'count(/pkg-info/bundle)' \
        "$locked_package_info")" == "1" && \
        "$(/usr/bin/xmllint --xpath \
            "count(/pkg-info/bundle[@id='com.maroffo.JidokaCode' and @path='./JidokaCode/Applications/Jidoka Code.app'])" \
            "$locked_package_info")" == "1" && \
        "$(/usr/bin/xmllint --xpath 'count(/pkg-info/bundle-version/bundle)' \
            "$locked_package_info")" == "1" && \
        "$(/usr/bin/xmllint --xpath \
            "count(/pkg-info/bundle-version/bundle[@id='com.maroffo.JidokaCode'])" \
            "$locked_package_info")" == "1" ]] || fail "locked component bundle identity differs"
    [[ "$(/usr/bin/xmllint --xpath 'count(/pkg-info/relocate/bundle)' \
        "$locked_package_info")" == "0" ]] || \
        fail "locked component policy still permits bundle relocation"
    [[ "$(/usr/bin/xmllint --xpath 'count(/pkg-info/strict-identifier/bundle)' \
        "$locked_package_info")" == "1" && \
        "$(/usr/bin/xmllint --xpath \
            "count(/pkg-info/strict-identifier/bundle[@id='com.maroffo.JidokaCode'])" \
            "$locked_package_info")" == "1" ]] || \
        fail "locked component policy lost the strict identifier"
    [[ "$(/usr/bin/xmllint --xpath 'count(/pkg-info/upgrade-bundle/bundle)' \
        "$locked_package_info")" == "1" && \
        "$(/usr/bin/xmllint --xpath \
            "count(/pkg-info/upgrade-bundle/bundle[@id='com.maroffo.JidokaCode'])" \
            "$locked_package_info")" == "1" && \
        "$(/usr/bin/xmllint --xpath 'count(/pkg-info/update-bundle/bundle)' \
            "$locked_package_info")" == "0" && \
        "$(/usr/bin/xmllint --xpath 'count(/pkg-info/atomic-update-bundle/bundle)' \
            "$locked_package_info")" == "0" ]] || \
        fail "locked component overwrite policy differs"
    /usr/bin/lsbom -p fmug "$locked_expanded/Bom" >"$locked_bom_modes"
    (
        cd "$component_root"
        while IFS= read -r -d '' path; do
            printf '%s\t%s\t0\t0\n' "$path" "$(/usr/bin/stat -f '%p' "$path")"
        done < <(/usr/bin/find . -print0)
    ) | LC_ALL=C /usr/bin/sort >"$expected_bom_modes"
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
            if (!(path in expected) || ($2 FS $3 FS $4) != expected[path]) exit 1
            if (!(path in seen)) seen_count += 1
            seen[path] = 1
        }
        END { if (seen_count != expected_count) exit 1 }
    ' "$expected_bom_modes" "$locked_bom_modes" || \
        fail "locked component package BOM mode or ownership differs"
    /usr/bin/grep -Fxq $'./JidokaCode\t40755\t0\t0' "$locked_bom_modes" || \
        fail "locked authority root BOM metadata differs"
    /usr/bin/grep -Fxq $'./JidokaCode/Applications\t40755\t0\t0' \
        "$locked_bom_modes" || fail "locked applications root BOM metadata differs"
}

assert_recorded_process_identity_absent() {
    local identity_file="$1"
    local label="$2"
    local current_identity
    local pid
    local recorded_microseconds
    local recorded_seconds
    IFS='|' read -r pid recorded_seconds recorded_microseconds <"$identity_file"
    [[ "$pid" =~ ^[0-9]+$ && "$recorded_seconds" =~ ^[0-9]+$ && \
        "$recorded_microseconds" =~ ^[0-9]+$ ]] || \
        fail "$label identity evidence is invalid"
    current_identity="$(
        "$BOUNDED_COMMAND_RUNNER" --process-identity "$pid" 2>/dev/null || true
    )"
    if [[ "$current_identity" == \
        "$pid|$recorded_seconds|$recorded_microseconds" ]]; then
        /bin/kill -KILL "$pid" 2>/dev/null || true
        fail "$label retained the matching PID/microsecond-start identity"
    fi
}

assert_bounded_command_runner() {
    local child_command
    local child_pid
    local distinctive_status=0
    local early_pid_file
    local escaped_identity_file
    local escaped_status
    local elapsed
    local expected_status
    local false_status=0
    local flood_elapsed
    local flood_start
    local flood_status=0
    local runner="$BOUNDED_COMMAND_RUNNER"
    local signal_child_pid
    local signal_elapsed
    local signal_start
    local signal_status=0
    local start
    local stderr_overflow_status=0
    local stdout_overflow_status=0
    local status=0

    [[ -f "$runner" && -x "$runner" && ! -L "$runner" ]] || \
        fail "bounded command runner is unavailable"
    "$runner" 2 /usr/bin/true || fail "bounded command runner changed a successful status"
    "$runner" 2 /usr/bin/false >/dev/null 2>&1 || false_status=$?
    [[ "$false_status" == "1" ]] || fail "bounded command runner changed a failed status"
    "$runner" 2 /bin/sh -c 'exit 37' >/dev/null 2>&1 || distinctive_status=$?
    [[ "$distinctive_status" == "37" ]] || \
        fail "bounded command runner changed a distinctive failed status"
    for expected_status in 0 37; do
        escaped_identity_file="$TEMP_ROOT/bounded-escaped-$expected_status.identity"
        early_pid_file="$TEMP_ROOT/bounded-escaped-$expected_status.pid"
        escaped_status=0
        # shellcheck disable=SC2016
        "$runner" 5 /bin/sh -c \
            '/usr/bin/python3 -c '\''import os,sys,time; os.setsid(); open(sys.argv[1], "w").write(str(os.getpid())); os.close(0); os.close(1); os.close(2); time.sleep(30)'\'' "$1" & child=$!; attempt=0; while [ ! -s "$1" ] && [ "$attempt" -lt 100 ]; do /bin/sleep 0.01; attempt=$((attempt + 1)); done; "$4" --process-identity "$child" >"$2"; /bin/sleep 0.2; exit "$3"' \
            bounded-escaped "$early_pid_file" "$escaped_identity_file" "$expected_status" \
            "$runner" \
            >/dev/null 2>&1 || escaped_status=$?
        [[ "$escaped_status" == "$expected_status" ]] || \
            fail "bounded command runner changed an escaped-child leader status"
        assert_recorded_process_identity_absent \
            "$escaped_identity_file" "bounded escaped-child status $expected_status"
    done

    escaped_identity_file="$TEMP_ROOT/bounded-escaped-timeout.identity"
    early_pid_file="$TEMP_ROOT/bounded-escaped-timeout.pid"
    status=0
    # shellcheck disable=SC2016
    "$runner" 1 /bin/sh -c \
        '/usr/bin/python3 -c '\''import os,sys,time; os.setsid(); open(sys.argv[1], "w").write(str(os.getpid())); os.close(0); os.close(1); os.close(2); time.sleep(30)'\'' "$1" & child=$!; attempt=0; while [ ! -s "$1" ] && [ "$attempt" -lt 100 ]; do /bin/sleep 0.01; attempt=$((attempt + 1)); done; "$3" --process-identity "$child" >"$2"; /bin/sleep 30' \
        bounded-escaped-timeout "$early_pid_file" "$escaped_identity_file" "$runner" \
        >/dev/null 2>"$TEMP_ROOT/bounded-escaped-timeout.stderr" || status=$?
    [[ "$status" == "124" && \
        "$(<"$TEMP_ROOT/bounded-escaped-timeout.stderr")" == \
            "bounded command timed out after 1s" ]] || \
        fail "bounded command runner did not type an escaped-child timeout"
    assert_recorded_process_identity_absent \
        "$escaped_identity_file" "bounded escaped-child timeout"

    JIDOKA_BOUNDED_STDOUT_LIMIT_BYTES=16 \
        "$runner" 2 /bin/sh -c 'printf 12345678901234567' \
        >"$TEMP_ROOT/bounded-overflow.stdout" \
        2>"$TEMP_ROOT/bounded-overflow.stderr" || stdout_overflow_status=$?
    [[ "$stdout_overflow_status" == "126" && \
        "$(<"$TEMP_ROOT/bounded-overflow.stdout")" == "1234567890123456" && \
        "$(<"$TEMP_ROOT/bounded-overflow.stderr")" == \
            "bounded command stdout exceeded 16 bytes" ]] || \
        fail "bounded command runner stdout overflow oracle differs"
    JIDOKA_BOUNDED_STDERR_LIMIT_BYTES=16 \
        "$runner" 2 /bin/sh -c 'printf 12345678901234567 >&2' \
        >"$TEMP_ROOT/bounded-stderr-overflow.stdout" \
        2>"$TEMP_ROOT/bounded-stderr-overflow.stderr" || stderr_overflow_status=$?
    [[ "$stderr_overflow_status" == "126" && \
        ! -s "$TEMP_ROOT/bounded-stderr-overflow.stdout" && \
        "$(<"$TEMP_ROOT/bounded-stderr-overflow.stderr")" == \
            $'1234567890123456bounded command stderr exceeded 16 bytes' ]] || \
        fail "bounded command runner stderr overflow oracle differs"

    flood_start="$(monotonic_seconds)"
    JIDOKA_BOUNDED_STDOUT_LIMIT_BYTES=4096 \
        "$runner" 5 /bin/sh -c \
            '/usr/bin/yes flood-a & /usr/bin/yes flood-b & /usr/bin/yes flood-c & /usr/bin/yes flood-d & wait' \
        >"$TEMP_ROOT/bounded-flood.stdout" \
        2>"$TEMP_ROOT/bounded-flood.stderr" || flood_status=$?
    flood_elapsed="$(elapsed_seconds_since "$flood_start")"
    [[ "$flood_status" == "126" && \
        "$(/usr/bin/stat -f '%z' "$TEMP_ROOT/bounded-flood.stdout")" == "4096" && \
        "$(<"$TEMP_ROOT/bounded-flood.stderr")" == \
            "bounded command stdout exceeded 4096 bytes" ]] || \
        fail "persistent multi-writer flood did not produce exact overflow"
    /usr/bin/awk -v elapsed="$flood_elapsed" 'BEGIN { exit !(elapsed < 2.0) }' || \
        fail "persistent multi-writer flood postponed overflow cleanup"

    /bin/cat >"$TEMP_ROOT/bounded-resistant.sh" <<'SCRIPT'
#!/bin/sh
trap 'exit 0' TERM
/bin/sh -c 'trap "" TERM; exec /bin/sleep 30' &
echo $! >"$1"
wait
SCRIPT
    /bin/chmod 0700 "$TEMP_ROOT/bounded-resistant.sh"
    start="$(/bin/date +%s)"
    "$runner" 1 /bin/sh "$TEMP_ROOT/bounded-resistant.sh" \
        "$TEMP_ROOT/bounded-child.pid" \
        >"$TEMP_ROOT/bounded.stdout" 2>"$TEMP_ROOT/bounded.stderr" || status=$?
    elapsed=$(( $(/bin/date +%s) - start ))
    [[ "$status" == "124" && "$elapsed" -lt 6 ]] || \
        fail "bounded command runner did not enforce its deadline"
    [[ "$(<"$TEMP_ROOT/bounded.stderr")" == "bounded command timed out after 1s" ]] || \
        fail "bounded command runner emitted unexpected diagnostics"
    child_pid="$(<"$TEMP_ROOT/bounded-child.pid")"
    [[ "$child_pid" =~ ^[0-9]+$ ]] || fail "bounded command child PID is invalid"
    if /bin/kill -0 "$child_pid" 2>/dev/null; then
        child_command="$(/bin/ps -p "$child_pid" -o command= 2>/dev/null || true)"
        [[ "$child_command" != "/bin/sleep 30" ]] || \
            fail "bounded command runner left a descendant alive"
    fi

    /bin/cat >"$TEMP_ROOT/bounded-immediate-signal.sh" <<'SCRIPT'
#!/bin/sh
/usr/bin/python3 -c 'import os,sys,time; os.setsid(); open(sys.argv[1], "w").write(str(os.getpid())); os.close(0); os.close(1); os.close(2); time.sleep(30)' "$1" &
child=$!
attempt=0
while [ ! -s "$1" ] && [ "$attempt" -lt 100 ]; do
    /bin/sleep 0.01
    attempt=$((attempt + 1))
done
"$3" --process-identity "$child" >"$2"
/bin/kill -TERM "$PPID"
wait
SCRIPT
    /bin/chmod 0700 "$TEMP_ROOT/bounded-immediate-signal.sh"
    signal_start="$(/bin/date +%s)"
    "$runner" 30 /bin/sh "$TEMP_ROOT/bounded-immediate-signal.sh" \
        "$TEMP_ROOT/bounded-signal-child.pid" \
        "$TEMP_ROOT/bounded-signal-child.identity" \
        "$runner" \
        >"$TEMP_ROOT/bounded-signal.stdout" 2>"$TEMP_ROOT/bounded-signal.stderr" || \
        signal_status=$?
    signal_elapsed=$(( $(/bin/date +%s) - signal_start ))
    [[ "$signal_status" == "143" && "$signal_elapsed" -lt 3 ]] || \
        fail "bounded command runner did not forward an immediate TERM exactly"
    [[ ! -s "$TEMP_ROOT/bounded-signal.stdout" && \
        ! -s "$TEMP_ROOT/bounded-signal.stderr" ]] || \
        fail "bounded command runner emitted output for an immediate TERM"
    signal_child_pid="$(<"$TEMP_ROOT/bounded-signal-child.pid")"
    [[ "$signal_child_pid" =~ ^[0-9]+$ ]] || \
        fail "bounded command signal child PID is invalid"
    assert_recorded_process_identity_absent \
        "$TEMP_ROOT/bounded-signal-child.identity" \
        "bounded escaped-child immediate signal"
    if "$runner" 1 relative-command >/dev/null 2>&1; then
        fail "bounded command runner accepted a relative executable"
    fi
}

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-s1.XXXXXX")"
TEMP_ROOT="$(cd "$TEMP_ROOT" && pwd -P)"
readonly TEMP_ROOT
trap cleanup EXIT
/bin/mkdir -p "$TEMP_ROOT/home" "$TEMP_ROOT/runtime-tmp"
[[ "$SOURCE_RELEASE_RUNTIME_ROOT" == /* && -d "$SOURCE_RELEASE_RUNTIME_ROOT" && \
    ! -L "$SOURCE_RELEASE_RUNTIME_ROOT" ]] || fail "documented runtime input root is unavailable"
canonical_source_runtime="$(cd "$SOURCE_RELEASE_RUNTIME_ROOT" && pwd -P)"
[[ "$canonical_source_runtime" == "$SOURCE_RELEASE_RUNTIME_ROOT" ]] || \
    fail "documented runtime input root must be canonical"
relocated_runtime="$TEMP_ROOT/relocated-release-runtime"
/usr/bin/ditto --norsrc --noextattr --noqtn \
    "$SOURCE_RELEASE_RUNTIME_ROOT" \
    "$relocated_runtime"
JIDOKA_RELEASE_RUNTIME_ROOT="$(cd "$relocated_runtime" && pwd -P)"
readonly JIDOKA_RELEASE_RUNTIME_ROOT
export JIDOKA_RELEASE_RUNTIME_ROOT
NODE_BIN="$JIDOKA_RELEASE_RUNTIME_ROOT/node/bin/node"
readonly NODE_BIN
RELOCATED_NODE_SHA256="$(/usr/bin/shasum -a 256 "$NODE_BIN" | /usr/bin/awk '{print $1}')"
readonly RELOCATED_NODE_SHA256
[[ -f "$NODE_BIN" && ! -L "$NODE_BIN" && ! -e "$TEMP_ROOT/staging" ]] || \
    fail "relocated runtime input is not one self-contained root"
[[ "$(/usr/bin/find "$TEMP_ROOT" -path '*/node/bin/node' -print)" == "$NODE_BIN" ]] || \
    fail "runtime relocation copied an undocumented sibling Node"
BOUNDED_COMMAND_RUNNER="$(build_bounded_command_runner)"
readonly BOUNDED_COMMAND_RUNNER
assert_cleanup_guard
assert_bounded_command_runner
build_normal_release_oracles
if missing_identity_error="$(
    /usr/bin/env -u SIGN_IDENTITY -u INSTALLER_SIGN_IDENTITY \
        "$ROOT/scripts/package-installer.sh" 2>&1 >/dev/null
)"; then
    fail "installer package accepted a missing application signing identity"
fi
[[ "$missing_identity_error" == \
    *"SIGN_IDENTITY must name one explicit Apple code-signing identity"* ]] || \
    fail "installer package did not fail closed on application signing identity"
if missing_installer_identity_error="$(
    SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        /usr/bin/env -u INSTALLER_SIGN_IDENTITY \
        "$ROOT/scripts/package-installer.sh" 2>&1 >/dev/null
)"; then
    fail "installer package accepted a missing installer signing identity"
fi
[[ "$missing_installer_identity_error" == \
    *"INSTALLER_SIGN_IDENTITY must name one explicit installer identity"* ]] || \
    fail "installer package did not fail closed on installer signing identity"
if implicit_keychain_app_error="$(
    SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        SIGNING_KEYCHAIN='' \
        ALLOW_ADHOC_SIGNING=0 \
        "$ROOT/scripts/package-app.sh" 2>&1 >/dev/null
)"; then
    fail "application package accepted an unknown login-Keychain identity"
fi
[[ "$implicit_keychain_app_error" == *"SIGN_IDENTITY is not a valid local identity"* && \
    "$implicit_keychain_app_error" != *"unbound variable"* ]] || \
    fail "application package did not handle an implicit login Keychain"
if implicit_keychain_installer_error="$(
    SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        INSTALLER_SIGN_IDENTITY=1111111111111111111111111111111111111111 \
        SIGNING_KEYCHAIN='' \
        "$ROOT/scripts/package-installer.sh" 2>&1 >/dev/null
)"; then
    fail "installer package accepted an unknown login-Keychain identity"
fi
[[ "$implicit_keychain_installer_error" == *"SIGN_IDENTITY is not a valid local identity"* && \
    "$implicit_keychain_installer_error" != *"unbound variable"* ]] || \
    fail "installer package did not handle an implicit login Keychain"
readonly MISSING_COMMON_KEYCHAIN="/tmp/jidoka-code-missing-common.keychain-db"
readonly MISSING_APPLICATION_KEYCHAIN="/tmp/jidoka-code-missing-application.keychain-db"
readonly MISSING_INSTALLER_KEYCHAIN="/tmp/jidoka-code-missing-installer.keychain-db"
VALID_APPLICATION_KEYCHAIN="$(cd "$TEMP_ROOT" && pwd -P)/application.keychain-db"
readonly VALID_APPLICATION_KEYCHAIN
/usr/bin/touch "$VALID_APPLICATION_KEYCHAIN"
/bin/chmod 0600 "$VALID_APPLICATION_KEYCHAIN"
[[ ! -e "$MISSING_COMMON_KEYCHAIN" && ! -L "$MISSING_COMMON_KEYCHAIN" ]]
[[ ! -e "$MISSING_APPLICATION_KEYCHAIN" && ! -L "$MISSING_APPLICATION_KEYCHAIN" ]]
[[ ! -e "$MISSING_INSTALLER_KEYCHAIN" && ! -L "$MISSING_INSTALLER_KEYCHAIN" ]]
if invalid_common_keychain_error="$(
    SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        INSTALLER_SIGN_IDENTITY=1111111111111111111111111111111111111111 \
        SIGNING_KEYCHAIN="$MISSING_COMMON_KEYCHAIN" \
        "$ROOT/scripts/package-installer.sh" 2>&1 >/dev/null
)"; then
    fail "installer package accepted a missing common Keychain"
fi
[[ "$invalid_common_keychain_error" == \
    *"APPLICATION_SIGNING_KEYCHAIN must be an absolute regular keychain file"* ]] || \
    fail "common Keychain did not route to the application signing path"
if invalid_common_installer_keychain_error="$(
    SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        INSTALLER_SIGN_IDENTITY=1111111111111111111111111111111111111111 \
        SIGNING_KEYCHAIN="$MISSING_COMMON_KEYCHAIN" \
        APPLICATION_SIGNING_KEYCHAIN="$VALID_APPLICATION_KEYCHAIN" \
        "$ROOT/scripts/package-installer.sh" 2>&1 >/dev/null
)"; then
    fail "installer package accepted a missing common Installer Keychain"
fi
[[ "$invalid_common_installer_keychain_error" == \
    *"INSTALLER_SIGNING_KEYCHAIN must be an absolute regular keychain file"* ]] || \
    fail "common Keychain did not route to the installer signing path"
if invalid_application_keychain_error="$(
    SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        INSTALLER_SIGN_IDENTITY=1111111111111111111111111111111111111111 \
        APPLICATION_SIGNING_KEYCHAIN="$MISSING_APPLICATION_KEYCHAIN" \
        "$ROOT/scripts/package-installer.sh" 2>&1 >/dev/null
)"; then
    fail "installer package accepted a missing application Keychain"
fi
[[ "$invalid_application_keychain_error" == \
    *"APPLICATION_SIGNING_KEYCHAIN must be an absolute regular keychain file"* ]] || \
    fail "installer package did not validate its application Keychain"
if invalid_installer_keychain_error="$(
    SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        INSTALLER_SIGN_IDENTITY=1111111111111111111111111111111111111111 \
        INSTALLER_SIGNING_KEYCHAIN="$MISSING_INSTALLER_KEYCHAIN" \
        "$ROOT/scripts/package-installer.sh" 2>&1 >/dev/null
)"; then
    fail "installer package accepted a missing installer Keychain"
fi
[[ "$invalid_installer_keychain_error" == \
    *"INSTALLER_SIGNING_KEYCHAIN must be an absolute regular keychain file"* ]] || \
    fail "installer package did not validate its installer Keychain"
if invalid_notarize_error="$(
    SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        INSTALLER_SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        NOTARIZE_PACKAGE=2 \
        "$ROOT/scripts/package-installer.sh" 2>&1 >/dev/null
)"; then
    fail "installer package accepted an invalid notarization mode"
fi
[[ "$invalid_notarize_error" == *"NOTARIZE_PACKAGE must be 0 or 1"* ]] || \
    fail "installer package did not fail closed on notarization mode"
if ignored_notary_error="$(
    SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        INSTALLER_SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        NOTARY_KEY=/tmp/ignored-notary-key \
        "$ROOT/scripts/package-installer.sh" 2>&1 >/dev/null
)"; then
    fail "installer package silently ignored notary credentials"
fi
[[ "$ignored_notary_error" == *"notary credentials require NOTARIZE_PACKAGE=1"* ]] || \
    fail "installer package did not reject inactive notary credentials"
[[ "$(/usr/bin/grep -Fc '/usr/bin/pkgbuild' "$ROOT/scripts/package-installer.sh")" == "1" ]] || \
    fail "installer package must use one pkgbuild step"
[[ "$(/usr/bin/grep -Fc '/usr/bin/productbuild' "$ROOT/scripts/package-installer.sh")" == "1" ]] || \
    fail "installer package must use one productbuild step"
[[ "$(/usr/bin/grep -Fc '/usr/bin/productsign' "$ROOT/scripts/package-installer.sh")" == "1" ]] || \
    fail "installer package must use one productsign step"
[[ "$(/usr/bin/grep -Fc '/usr/bin/xcrun notarytool submit' "$ROOT/scripts/package-installer.sh")" == "1" ]] || \
    fail "installer package must use one explicit notary submission step"
/usr/bin/grep -Fq -- "--sign \"\$INSTALLER_SIGN_IDENTITY\"" \
    "$ROOT/scripts/package-installer.sh" || \
    fail "product package must use the explicit installer identity"
/usr/bin/grep -Fq -- "--timeout 30m" "$ROOT/scripts/package-installer.sh" || \
    fail "notarization wait must have an explicit timeout"
[[ "$(/usr/bin/grep -Ec '(^|/)installer([[:space:]]|$)' "$ROOT/scripts/package-installer.sh")" == "0" ]] || \
    fail "package builder must not install its output"
pkgbuild_plan="$(
    /usr/bin/awk \
        '/^pkgbuild_arguments=\(/{capture=1} capture{print} /^readonly -a pkgbuild_arguments$/{exit}' \
        "$ROOT/scripts/package-installer.sh"
)"
# shellcheck disable=SC2016
readonly expected_pkgbuild_plan='pkgbuild_arguments=(
    --root "$COMPONENT_ROOT"
    --component-plist "$COMPONENT_POLICY"
    --ownership recommended
    --install-location "$INSTALL_LOCATION"
    --identifier "$PACKAGE_IDENTIFIER"
    --version "$app_version"
    "$COMPONENT_PACKAGE"
)
readonly -a pkgbuild_arguments'
[[ "$pkgbuild_plan" == "$expected_pkgbuild_plan" ]] || \
    fail "non-relocatable pkgbuild argv differs"
productbuild_plan="$(
    /usr/bin/awk \
        '/^productbuild_arguments=/{capture=1} capture{print} /^readonly -a productbuild_arguments$/{exit}' \
        "$ROOT/scripts/package-installer.sh"
)"
# shellcheck disable=SC2016
readonly expected_productbuild_plan='productbuild_arguments=(--package "$COMPONENT_PACKAGE" "$UNSIGNED_PRODUCT_PACKAGE")
readonly -a productbuild_arguments'
[[ "$productbuild_plan" == "$expected_productbuild_plan" ]] || \
    fail "unsigned productbuild argv differs"
productsign_plan="$(
    /usr/bin/awk \
        '/^productsign_arguments=/{capture=1} capture{print} /^readonly -a productsign_arguments$/{exit}' \
        "$ROOT/scripts/package-installer.sh"
)"
# shellcheck disable=SC2016
readonly expected_productsign_plan='productsign_arguments=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
if [[ -n "$INSTALLER_SIGNING_KEYCHAIN" ]]; then
    productsign_arguments+=(--keychain "$INSTALLER_SIGNING_KEYCHAIN")
fi
productsign_arguments+=("$UNSIGNED_PRODUCT_PACKAGE" "$PRODUCT_PACKAGE")
readonly -a productsign_arguments'
[[ "$productsign_plan" == "$expected_productsign_plan" ]] || \
    fail "timestamped productsign argv differs"
/usr/bin/grep -Fxq 'readonly PACKAGE_IDENTIFIER="com.maroffo.JidokaCode.pkg"' \
    "$ROOT/scripts/package-installer.sh" || fail "installer receipt identifier differs"
/usr/bin/grep -Fxq 'readonly INSTALL_LOCATION="/Library/Application Support"' \
    "$ROOT/scripts/package-installer.sh" || fail "installer root differs"
/usr/bin/grep -Fxq \
    'readonly COMPONENT_APP_RELATIVE_PATH="JidokaCode/Applications/Jidoka Code.app"' \
    "$ROOT/scripts/package-installer.sh" || fail "installer relative application path differs"
# shellcheck disable=SC2016
/usr/bin/grep -Fxq \
    'readonly INSTALL_APP_PATH="$INSTALL_LOCATION/$COMPONENT_APP_RELATIVE_PATH"' \
    "$ROOT/scripts/package-installer.sh" || fail "installer application destination differs"
/usr/bin/perl -0ne '
    $found = 1 if /startMainQuitObserver \{ \[weak self\] in\n\s+self\?\.prepareForRequestedTermination\(\)\n\s+\}/;
    END { exit($found ? 0 : 1) }
' "$ROOT/Sources/JidokaCodeApp/ApplicationComposition.swift" || \
    fail "main quit notification bypasses durable preparation"
if /usr/bin/grep -Fq 'NSApplication.shared.terminate' \
    "$ROOT/Sources/JidokaCodeApp/LifecycleCLI.swift"; then
    fail "lifecycle notification terminates before durable preparation"
fi
/usr/bin/grep -Fq \
    "macOS release verification is unavailable on \$HOST_OS; release remains unverified" \
    "$ROOT/scripts/verify-toolchain.sh" || \
    fail "non-macOS release gate is not explicit"
readonly COPIED_APP="$TEMP_ROOT/Jidoka Code.app"
readonly MUTATED_APP="$TEMP_ROOT/Jidoka Code Mutated.app"
readonly MUTATED_RUNNER_APP="$TEMP_ROOT/Jidoka Code Runner Mutated.app"
readonly MUTATED_ATTESTATION_APP="$TEMP_ROOT/Jidoka Code Attestation Mutated.app"
readonly MUTATED_POLICY_APP="$TEMP_ROOT/Jidoka Code Policy Mutated.app"
readonly MUTATED_WORKFLOW_APP="$TEMP_ROOT/Jidoka Code Workflow Mutated.app"
readonly MUTATED_RELEASE_RUNTIME_APP="$TEMP_ROOT/Jidoka Code Release Runtime Mutated.app"
readonly MUTATED_APP_EXECUTABLE_APP="$TEMP_ROOT/Jidoka Code Executable Mutated.app"

native_code_mutated_runtime="$TEMP_ROOT/native-code-mutated-runtime"
/bin/cp -cR "$JIDOKA_RELEASE_RUNTIME_ROOT" "$native_code_mutated_runtime"
native_code_mutation="$native_code_mutated_runtime/pi/node_modules/@earendil-works/pi-tui/native/darwin/prebuilds/darwin-arm64/darwin-modifiers.node"
/usr/bin/codesign --remove-signature "$native_code_mutation"
if /usr/bin/env \
    JIDOKA_RELEASE_RUNTIME_ROOT="$native_code_mutated_runtime" \
    ALLOW_ADHOC_SIGNING=1 \
    "$ROOT/scripts/package-app.sh" \
    >"$TEMP_ROOT/native-code-mutation.stdout" \
    2>"$TEMP_ROOT/native-code-mutation.stderr"
then
    fail "packaging accepted an unsigned release Pi native module"
fi
/usr/bin/grep -Fq 'release Pi native-code signature is invalid' \
    "$TEMP_ROOT/native-code-mutation.stderr" || \
    fail "unsigned release Pi native module failed opaquely"
/bin/rm -rf -- "$native_code_mutated_runtime"

native_code_extra_runtime="$TEMP_ROOT/native-code-extra-runtime"
/bin/cp -cR "$JIDOKA_RELEASE_RUNTIME_ROOT" "$native_code_extra_runtime"
/bin/cp \
    "$native_code_extra_runtime/pi/node_modules/@earendil-works/pi-tui/native/darwin/prebuilds/darwin-arm64/darwin-modifiers.node" \
    "$native_code_extra_runtime/pi/unexpected-native.node"
if /usr/bin/env \
    JIDOKA_RELEASE_RUNTIME_ROOT="$native_code_extra_runtime" \
    ALLOW_ADHOC_SIGNING=1 \
    "$ROOT/scripts/package-app.sh" \
    >"$TEMP_ROOT/native-code-extra.stdout" \
    2>"$TEMP_ROOT/native-code-extra.stderr"
then
    fail "packaging accepted an extra release Pi native module"
fi
/usr/bin/grep -Fq 'release Pi Mach-O inventory differs' \
    "$TEMP_ROOT/native-code-extra.stderr" || \
    fail "extra release Pi native module failed opaquely"
/bin/rm -rf -- "$native_code_extra_runtime"

native_code_identity_runtime="$TEMP_ROOT/native-code-identity-runtime"
/bin/cp -cR "$JIDOKA_RELEASE_RUNTIME_ROOT" "$native_code_identity_runtime"
native_code_identity_mutation="$native_code_identity_runtime/pi/node_modules/@mariozechner/clipboard-darwin-universal/clipboard.darwin-universal.node"
/usr/bin/codesign --force --sign - --options runtime \
    --identifier works.earendil.jidoka.runtime.pi.clipboard \
    "$native_code_identity_mutation"
if /usr/bin/env \
    JIDOKA_RELEASE_RUNTIME_ROOT="$native_code_identity_runtime" \
    ALLOW_ADHOC_SIGNING=1 \
    "$ROOT/scripts/package-app.sh" \
    >"$TEMP_ROOT/native-code-identity.stdout" \
    2>"$TEMP_ROOT/native-code-identity.stderr"
then
    fail "packaging accepted an ad hoc release Pi native module"
fi
/usr/bin/grep -Fq 'release Pi native-code identity differs' \
    "$TEMP_ROOT/native-code-identity.stderr" || \
    fail "ad hoc release Pi native module failed opaquely"
/bin/rm -rf -- "$native_code_identity_runtime"

runtime_inventory="$ROOT/build/runtime-inventory.txt"
runtime_inventory_backup="$TEMP_ROOT/runtime-inventory.backup"
runtime_inventory_sentinel="$TEMP_ROOT/runtime-inventory-sentinel"
if [[ -L "$runtime_inventory" ]]; then
    fail "pre-existing runtime inventory is already redirected"
fi
if [[ -e "$runtime_inventory" ]]; then
    [[ -f "$runtime_inventory" ]] || fail "pre-existing runtime inventory is unsafe"
    /bin/mv "$runtime_inventory" "$runtime_inventory_backup"
fi
printf 'sentinel\n' >"$runtime_inventory_sentinel"
/bin/ln -s "$runtime_inventory_sentinel" "$runtime_inventory"
if (
    umask 077
    ALLOW_ADHOC_SIGNING=1 "$ROOT/scripts/package-app.sh"
) >"$TEMP_ROOT/inventory-symlink.stdout" 2>"$TEMP_ROOT/inventory-symlink.stderr"; then
    fail "packaging accepted a redirected runtime inventory"
fi
/usr/bin/grep -Fq 'generated release runtime inventory must not be a symbolic link' \
    "$TEMP_ROOT/inventory-symlink.stderr" || fail "runtime inventory symlink failed opaquely"
[[ "$(<"$runtime_inventory_sentinel")" == "sentinel" ]] || \
    fail "runtime inventory symlink target was modified"
/bin/rm -f -- "$runtime_inventory"
if [[ -f "$runtime_inventory_backup" ]]; then
    /bin/mv "$runtime_inventory_backup" "$runtime_inventory"
fi

(
    umask 077
    ALLOW_ADHOC_SIGNING=1 "$ROOT/scripts/package-app.sh"
)
[[ "$(/usr/bin/shasum -a 256 "$NODE_BIN" | /usr/bin/awk '{print $1}')" == \
    "$RELOCATED_NODE_SHA256" ]] || fail "packaging mutated the staged runtime Node input"
/usr/bin/codesign --verify --strict "$NODE_BIN" || \
    fail "packaging invalidated the staged runtime Node input"
[[ -z "$(/usr/bin/find "$SOURCE_APP" -type d ! -perm 0755 -print)" ]] || \
    fail "packaged bundle inherited a restrictive directory mode"
for path in \
    "$SOURCE_EXECUTABLE" "$SOURCE_ENGINE" "$SOURCE_ASKPASS" \
    "$SOURCE_PUSH_GUARD" "$SOURCE_HERDR_HOST"
do
    [[ "$(/usr/bin/stat -f '%OLp' "$path")" == "755" ]] || \
        fail "packaged executable inherited a restrictive mode"
done
[[ -z "$(/usr/bin/find "$SOURCE_APP" -type f \
    ! -path "$SOURCE_APP/Contents/Resources/PiRuntime/*" \
    ! -perm -0100 ! -perm 0644 -print)" ]] || fail "packaged resource mode differs"
assert_component_relocation_policy "$SOURCE_APP"
JIDOKA_PI_RESOURCE_ROOT="$SOURCE_APP/Contents/Resources/Pi" \
    "$NODE_BIN" \
    "$ROOT/scripts/tests/test-jidoka-extension-rpc.mjs"

/usr/bin/plutil -lint "$SOURCE_APP/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$SOURCE_APP/Contents/Info.plist")" == \
    "com.maroffo.JidokaCode" ]] || fail "application bundle identifier is not production"
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$SOURCE_APP/Contents/Info.plist")" == "14.0" ]]

expected_inventory="$({
    /bin/cat "$ROOT/Packaging/app-inventory.txt"
    /bin/cat "$ROOT/build/runtime-inventory.txt"
} | LC_ALL=C /usr/bin/sort)"
actual_inventory="$(cd "$SOURCE_APP" && /usr/bin/find . -print | LC_ALL=C /usr/bin/sort)"
[[ "$actual_inventory" == "$expected_inventory" ]] || fail "bundle inventory differs from allowlist"
[[ -z "$(/usr/bin/find "$SOURCE_APP" -type l \
    ! -path "$SOURCE_APP/Contents/Resources/PiRuntime/pi/*" -print)" ]] || \
    fail "bundle contains a non-runtime symbolic link"
run_packaged_command \
    "$SOURCE_EXECUTABLE" \
    /dev/null \
    /dev/stderr \
    --release-runtime-verify-adhoc || fail "packaged release runtime verifier failed"

launch_agent_plist="$SOURCE_APP/Contents/Library/LaunchAgents/com.maroffo.JidokaCode.Engine.plist"
/usr/bin/plutil -lint "$launch_agent_plist"
[[ "$(/usr/bin/plutil -extract Label raw "$launch_agent_plist")" == \
    "com.maroffo.JidokaCode.Engine" ]] || fail "launch agent identifier is not production"
[[ "$(/usr/bin/plutil -extract BundleProgram raw "$launch_agent_plist")" == \
    "Contents/Helpers/JidokaCodeEngineProbe" ]]
[[ "$(/usr/bin/plutil -extract ProgramArguments.3 raw "$launch_agent_plist")" == "1" ]]
[[ "$(/usr/bin/plutil -extract RunAtLoad raw "$launch_agent_plist")" == "true" ]]
[[ "$(/usr/bin/plutil -extract KeepAlive.SuccessfulExit raw "$launch_agent_plist")" == "false" ]]
[[ "$(/usr/bin/plutil -extract 'MachServices.com\.maroffo\.JidokaCode\.Engine' raw "$launch_agent_plist")" == "true" ]] || \
    fail "launch agent Mach service differs from allowlist"

herdr_schema="$SOURCE_APP/Contents/Resources/Herdr/api-schema-0.8.2.json"
herdr_policy="$SOURCE_APP/Contents/Resources/Herdr/runtime-builds.json"
[[ "$(/usr/bin/shasum -a 256 "$herdr_schema" | /usr/bin/awk '{print $1}')" == \
    "c48f1f54ee0150ca27e11fd44455fe94aeadb20fdf4e4a62393ed822a4e5b150" ]] || \
    fail "packaged Herdr schema differs from approved bytes"
[[ "$(/usr/bin/shasum -a 256 "$herdr_policy" | /usr/bin/awk '{print $1}')" == \
    "45674e216b931f7c736c1c8348e899221c2aef080dfa6a92392144b244cd5867" ]] || \
    fail "packaged Herdr policy differs from approved bytes"
[[ "$(/usr/bin/plutil -extract schemaVersion raw "$herdr_policy")" == "1" ]]
[[ "$(/usr/bin/plutil -extract builds.0.version raw "$herdr_policy")" == "0.8.2" ]]
[[ "$(/usr/bin/plutil -extract builds.0.protocolVersion raw "$herdr_policy")" == "20" ]]
[[ "$(/usr/bin/plutil -extract builds.0.executableSHA256 raw "$herdr_policy")" == \
    "3e0f0c2d5edc41f592963ef90f5d872db801cc7dbd0e01731023897ee428904a" ]]
[[ ! -e "$SOURCE_APP/Contents/Helpers/herdr" ]] || fail "external Herdr binary was bundled"

assert_resource_digest() {
    local relative_path="$1"
    local expected_digest="$2"
    local resource="$SOURCE_APP/Contents/Resources/Pi/$relative_path"
    [[ -f "$resource" && ! -L "$resource" ]] || fail "missing regular Pi resource: $relative_path"
    [[ "$(/usr/bin/shasum -a 256 "$resource" | /usr/bin/awk '{print $1}')" == \
        "$expected_digest" ]] || fail "packaged Pi resource digest differs: $relative_path"
}
assert_resource_digest \
    workflow-resources.json \
    230c9a45b9dd53443837166c6e8b60adac67d3bfeb32249de8ca5228f1e1357d
assert_resource_digest \
    tui-resources.json \
    5392fec5eb544dbe0c721692440e8445604d3c05509a39b450f2bb964245f07f
assert_resource_digest \
    extensions/jidoka-code.ts \
    3312c65c0cb607f14012a75aad31062eebf817724e807cab4ed4379c31752c0b
assert_resource_digest \
    extensions/jidoka-deny-user-bash.js \
    ba18988ad739c592920555515ee246e07d325f0e90df345a61de4e7f41a24995
assert_resource_digest \
    extensions/jidoka-runtime.ts \
    b6bae1cb282d95b3c1a3e6e4f37c5b967aa5bd3885ec3050c5d7bddb72b4a19b
assert_resource_digest \
    extensions/jidoka-tui-runtime.ts \
    d7c46bf43840613d932c19db36196f741f783d99f666f3b6e89629feb887a031
assert_resource_digest \
    runtime/jidoka-extension-contract.mjs \
    1a2a90b0b53bf68ead774b34b3b90045bd1ca8ffacf3f3a462b520a86d6498f8
assert_resource_digest \
    runtime/jidoka-model-catalog.mjs \
    6057a1a9be5bef7fc029504b1599fcdae4079c3b3eb5829bfa1580c319fb95ba
assert_resource_digest \
    runtime/jidoka-tui-contract.mjs \
    3019e69f4e92356b55b8c149a420d2ab9816014a6be670ccd4db6887553d64ac
assert_resource_digest \
    runtime/node-runtime-builds.json \
    cfe0b91f93c46d1c912085ac48a2bac31f8529bc2834c36f6e715ae7f272939d
assert_resource_digest \
    runtime/pi-rpc-profile-probe.mjs \
    085fc4f44e77e051c05e2e68c4f755748ebfca227eb3b6782c1e0e3cce727b9d
assert_resource_digest \
    runtime/pi-rpc-workflow-probe.mjs \
    1c04d87ddb1f235c144001cd1d59fb3d80a9ad788ac1a8a33a79d12e1ce8f80b
assert_resource_digest \
    runtime/pi-runtime-attestation.mjs \
    d062dad354b15d8bc0dc377e8aa6835d0eaf884cf68925dad4b8aace5d0cd413
assert_resource_digest \
    runtime/pi-runtime-builds.json \
    a9fd4478272c9d368ce3b1f253cb63a4a936a9354f876c4c30eba64dc694a7f4
assert_resource_digest \
    skills/jidoka-code-issue-triage/SKILL.md \
    c4200a92833135446a61f374467aeb8f35e4a25826fe7b34baa016c206c46f0f
assert_resource_digest \
    skills/jidoka-code-orchestrate/SKILL.md \
    4a6f1b39c86b21b820144c5dbb7fea5ea4f8ee4f8c5ea41a0f01a5ab9850ca07
assert_resource_digest \
    skills/jidoka-code-plan/SKILL.md \
    251874083bfba1dd5ed9334200efced1bdab18518fb16e9dd3f43c270456564c
assert_resource_digest \
    skills/jidoka-code-pr-review/SKILL.md \
    7e3af39ff6e211aa9c3d85c935eb7ff991ec88c9f0df9b152df2ef3977fa409b
assert_resource_digest \
    skills/jidoka-code-review-architecture/SKILL.md \
    0ce9a9b66333f01714c5998624de5417f07590938c5ea0a9a1f9784941cc9213
assert_resource_digest \
    skills/jidoka-code-review-security/SKILL.md \
    017c72a2f853096296aacca334bcb692feb4347f43be6f0ccdb3e1a36b7cb9da
assert_resource_digest \
    skills/jidoka-code-review-test/SKILL.md \
    f67f49f3d2c668da2342457e76902448355bdaf84eab1e5a66bf9fc79e217fc1
assert_resource_digest \
    skills/jidoka-code-synthesize/SKILL.md \
    abc9d42fcf495e7700feb02ae1362c7c382d029dd5d435de390bd864e669786d
assert_resource_digest \
    workflow-skills/jidoka-code-orchestration-fidelity/SKILL.md \
    b836936c3b9f4b262669e51191f207b87d406f3a9add4e6bc091c182e18be79c
assert_resource_digest \
    workflow-skills/jidoka-code-planning-fidelity/SKILL.md \
    307702956b6aa2a119310854a739c0c1afedf8f4d8eddc94f5daedd1ccabf56e
assert_resource_digest \
    workflow-skills/jidoka-code-pr-fidelity/SKILL.md \
    cb5e4d24107503158eeecd569a968baed35c4e487e546d8049f77080bbdf3508
assert_resource_digest \
    workflow-skills/jidoka-code-triage-fidelity/SKILL.md \
    9d75a49c6b45136189b002574e193ce5e82a6606c26979199ed7c4ee5264f843
[[ "$(/usr/bin/shasum -a 256 "$SOURCE_APP/Contents/Resources/Spikes/jidoka-local-spikes.mjs" | \
    /usr/bin/awk '{print $1}')" == \
    "c903de7f2a78d9172941774baa24cb016b1758834d9a1d9d828794b5cdf3b853" ]] || \
    fail "packaged local spike runner digest differs"

for path in \
    "$SOURCE_APP/Contents/Info.plist" \
    "$launch_agent_plist" \
    "$SOURCE_APP/Contents/Resources/Herdr/api-schema-0.8.2.json" \
    "$SOURCE_APP/Contents/Resources/Herdr/runtime-builds.json" \
    "$SOURCE_APP/Contents/Resources/Pi/manifest.json" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-resources.json" \
    "$SOURCE_APP/Contents/Resources/Pi/tui-resources.json" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-code.ts" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-deny-user-bash.js" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-runtime.ts" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-tui-runtime.ts" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/jidoka-extension-contract.mjs" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/jidoka-model-catalog.mjs" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/jidoka-tui-contract.mjs" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/node-runtime-builds.json" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/pi-rpc-profile-probe.mjs" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/pi-rpc-workflow-probe.mjs" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/pi-runtime-attestation.mjs" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/pi-runtime-builds.json" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-issue-triage/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-orchestrate/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-plan/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-pr-review/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-review-architecture/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-review-security/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-review-test/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-synthesize/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-skills/jidoka-code-orchestration-fidelity/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-skills/jidoka-code-planning-fidelity/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-skills/jidoka-code-pr-fidelity/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-skills/jidoka-code-triage-fidelity/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Spikes/jidoka-local-spikes.mjs" \
    "$SOURCE_APP/Contents/Resources/PiRuntime/runtime-manifest.json" \
    "$SOURCE_APP/Contents/Resources/PiRuntime/licenses/node-LICENSE" \
    "$SOURCE_APP/Contents/_CodeSignature/CodeResources"
do
    [[ -f "$path" && ! -L "$path" ]] || fail "expected regular bundle file: $path"
done
for path in \
    "$SOURCE_EXECUTABLE" "$SOURCE_ENGINE" "$SOURCE_ASKPASS" \
    "$SOURCE_PUSH_GUARD" "$SOURCE_HERDR_HOST" \
    "$SOURCE_APP/Contents/Resources/PiRuntime/node/bin/node"
do
    [[ -f "$path" && -x "$path" && ! -L "$path" ]] || fail "expected executable: $path"
    assert_portable_macho "$path"
done

/usr/bin/codesign --verify --strict "$SOURCE_ENGINE"
/usr/bin/codesign --verify --strict "$SOURCE_ASKPASS"
/usr/bin/codesign --verify --strict "$SOURCE_PUSH_GUARD"
/usr/bin/codesign --verify --strict "$SOURCE_HERDR_HOST"
/usr/bin/codesign --verify --strict "$SOURCE_APP/Contents/Resources/PiRuntime/node/bin/node"
/usr/bin/codesign --verify --strict --deep "$SOURCE_APP"
[[ "$(codesign_identifier "$SOURCE_APP")" == "com.maroffo.JidokaCode" ]] || \
    fail "application code-signing identifier differs"
[[ "$(codesign_identifier "$SOURCE_ENGINE")" == "com.maroffo.JidokaCode.Engine" ]] || \
    fail "engine code-signing identifier differs"
[[ "$(codesign_identifier "$SOURCE_ASKPASS")" == "com.maroffo.JidokaCode.AskPass" ]] || \
    fail "askpass code-signing identifier differs"
[[ "$(codesign_identifier "$SOURCE_PUSH_GUARD")" == "com.maroffo.JidokaCode.PushGuard" ]] || \
    fail "push-guard code-signing identifier differs"
[[ "$(codesign_identifier "$SOURCE_HERDR_HOST")" == "com.maroffo.JidokaCode.HerdrHost" ]] || \
    fail "Herdr host code-signing identifier differs"
[[ "$(codesign_identifier "$SOURCE_APP/Contents/Resources/PiRuntime/node/bin/node")" == \
    "works.earendil.jidoka.runtime.node" ]] || fail "runtime Node identifier differs"

app_minos="$(/usr/bin/otool -l "$SOURCE_EXECUTABLE" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
engine_minos="$(/usr/bin/otool -l "$SOURCE_ENGINE" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
askpass_minos="$(/usr/bin/otool -l "$SOURCE_ASKPASS" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
push_guard_minos="$(/usr/bin/otool -l "$SOURCE_PUSH_GUARD" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
herdr_host_minos="$(/usr/bin/otool -l "$SOURCE_HERDR_HOST" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
[[ "$app_minos" == "14.0" && "$engine_minos" == "14.0" && \
    "$askpass_minos" == "14.0" && "$push_guard_minos" == "14.0" && \
    "$herdr_host_minos" == "14.0" ]] || \
    fail "unexpected minimum OS"

BIN_DIR="$(
    /usr/bin/xcrun swift build \
        --scratch-path "$ROOT/.build/adhoc-runtime-testing" \
        -Xswiftc -DJIDOKA_ADHOC_RUNTIME_TESTING \
        --configuration release \
        --show-bin-path
)"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
normalize_unsigned_product() {
    local source="$1"
    local destination="$2"
    /usr/bin/install -m 0755 "$source" "$destination"
    /usr/bin/codesign --remove-signature "$destination"
    /usr/bin/strip -S "$destination"
    remove_developer_rpaths "$destination"
}
normalize_unsigned_product "$BIN_DIR/JidokaCodeApp" "$TEMP_ROOT/expected-app"
normalize_unsigned_product "$SOURCE_EXECUTABLE" "$TEMP_ROOT/actual-app"
normalize_unsigned_product "$BIN_DIR/JidokaCodeEngineProbe" "$TEMP_ROOT/expected-engine"
normalize_unsigned_product "$SOURCE_ENGINE" "$TEMP_ROOT/actual-engine"
normalize_unsigned_product "$BIN_DIR/JidokaCodeAskPass" "$TEMP_ROOT/expected-askpass"
normalize_unsigned_product "$SOURCE_ASKPASS" "$TEMP_ROOT/actual-askpass"
normalize_unsigned_product "$BIN_DIR/JidokaCodePushGuard" "$TEMP_ROOT/expected-push-guard"
normalize_unsigned_product "$SOURCE_PUSH_GUARD" "$TEMP_ROOT/actual-push-guard"
normalize_unsigned_product "$BIN_DIR/JidokaCodeHerdrHost" "$TEMP_ROOT/expected-herdr-host"
normalize_unsigned_product "$SOURCE_HERDR_HOST" "$TEMP_ROOT/actual-herdr-host"
/usr/bin/cmp -s "$TEMP_ROOT/expected-app" "$TEMP_ROOT/actual-app" || \
    fail "packaged app lacks build-product provenance"
/usr/bin/cmp -s "$TEMP_ROOT/expected-engine" "$TEMP_ROOT/actual-engine" || \
    fail "packaged engine helper lacks build-product provenance"
/usr/bin/cmp -s "$TEMP_ROOT/expected-askpass" "$TEMP_ROOT/actual-askpass" || \
    fail "packaged askpass helper lacks build-product provenance"
/usr/bin/cmp -s "$TEMP_ROOT/expected-push-guard" "$TEMP_ROOT/actual-push-guard" || \
    fail "packaged push guard lacks build-product provenance"
/usr/bin/cmp -s "$TEMP_ROOT/expected-herdr-host" "$TEMP_ROOT/actual-herdr-host" || \
    fail "packaged Herdr host lacks build-product provenance"

/usr/bin/ditto "$SOURCE_APP" "$COPIED_APP"
[[ "$COPIED_APP" != "$ROOT"/* ]]
/usr/bin/codesign --verify --strict --deep "$COPIED_APP"

/usr/bin/ditto "$COPIED_APP" "$MUTATED_APP_EXECUTABLE_APP"
original_app_executable_sha256="$(
    /usr/bin/shasum -a 256 "$MUTATED_APP_EXECUTABLE_APP/Contents/MacOS/Jidoka Code" | \
        /usr/bin/awk '{print $1}'
)"
/usr/bin/install -m 0755 \
    "$NORMAL_RELEASE_EXECUTABLE" \
    "$MUTATED_APP_EXECUTABLE_APP/Contents/MacOS/Jidoka Code"
/usr/bin/strip -S "$MUTATED_APP_EXECUTABLE_APP/Contents/MacOS/Jidoka Code"
remove_developer_rpaths "$MUTATED_APP_EXECUTABLE_APP/Contents/MacOS/Jidoka Code"
[[ "$(/usr/bin/shasum -a 256 \
    "$MUTATED_APP_EXECUTABLE_APP/Contents/MacOS/Jidoka Code" | /usr/bin/awk '{print $1}')" != \
    "$original_app_executable_sha256" ]] || fail "normal release app mutation changed no bytes"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode \
    "$MUTATED_APP_EXECUTABLE_APP"
/usr/bin/codesign --verify --strict --deep "$MUTATED_APP_EXECUTABLE_APP"
production_authority_start="$(monotonic_seconds)"
assert_production_authority_failure "$MUTATED_APP_EXECUTABLE_APP"
production_authority_rejection_seconds="$(elapsed_seconds_since "$production_authority_start")"
printf 'production_authority_rejection_seconds=%s\n' \
    "$production_authority_rejection_seconds"
if run_packaged_command \
    "$MUTATED_APP_EXECUTABLE_APP/Contents/MacOS/Jidoka Code" \
    "$TEMP_ROOT/mutated-app-adhoc.stdout" \
    "$TEMP_ROOT/mutated-app-adhoc.stderr" \
    --release-runtime-verify-adhoc
then
    fail "mutated normal release app exposed ad hoc runtime verification"
fi
[[ ! -s "$TEMP_ROOT/mutated-app-adhoc.stdout" ]] || \
    fail "mutated normal release ad hoc rejection wrote stdout"
/usr/bin/grep -Fxq 'unsupported release runtime verification command' \
    "$TEMP_ROOT/mutated-app-adhoc.stderr" || \
    fail "mutated normal release app recognized ad hoc runtime verification"
if /usr/bin/grep -R -a -F "$ROOT" "$COPIED_APP" >/dev/null; then
    fail "packaged bundle leaks checkout path"
fi
if /usr/bin/grep -R -a -F "$DEVELOPER_DIR" "$COPIED_APP" >/dev/null; then
    fail "packaged bundle leaks Xcode developer path"
fi

preflight_stdout="$TEMP_ROOT/preflight.json"
preflight_stderr="$TEMP_ROOT/preflight.stderr"
engine_stdout="$TEMP_ROOT/engine.json"
engine_stderr="$TEMP_ROOT/engine.stderr"
run_packaged_command \
    "$COPIED_APP/Contents/MacOS/Jidoka Code" \
    "$preflight_stdout" \
    "$preflight_stderr" \
    --preflight
run_packaged_command \
    "$COPIED_APP/Contents/Helpers/JidokaCodeEngineProbe" \
    "$engine_stdout" \
    "$engine_stderr" \
    --probe
[[ ! -s "$preflight_stderr" && ! -s "$engine_stderr" ]] || fail "successful probe wrote stderr"
askpass_stdout="$TEMP_ROOT/askpass.stdout"
askpass_stderr="$TEMP_ROOT/askpass.stderr"
if run_packaged_command \
    "$COPIED_APP/Contents/Helpers/JidokaCodeAskPass" \
    "$askpass_stdout" \
    "$askpass_stderr" \
    "Password for https://github.com"
then
    fail "packaged askpass succeeded without a one-shot capability"
fi
[[ ! -s "$askpass_stdout" ]] || fail "failed packaged askpass wrote stdout"
[[ "$(<"$askpass_stderr")" == "JIDOKA_ASKPASS_FAILED" ]] || \
    fail "failed packaged askpass disclosed unexpected diagnostics"
push_guard_stdout="$TEMP_ROOT/push-guard.stdout"
push_guard_stderr="$TEMP_ROOT/push-guard.stderr"
push_guard_open_stdin="$TEMP_ROOT/push-guard-open-stdin"
/usr/bin/mkfifo "$push_guard_open_stdin"
exec 9<>"$push_guard_open_stdin"
push_guard_start="$(monotonic_seconds)"
push_guard_status=0
run_packaged_command \
    "$COPIED_APP/Contents/Helpers/GitHooks/pre-push" \
    "$push_guard_stdout" \
    "$push_guard_stderr" \
    "origin" <&9 || push_guard_status=$?
push_guard_seconds="$(elapsed_seconds_since "$push_guard_start")"
exec 9>&-
/bin/rm -f -- "$push_guard_open_stdin"
[[ "$push_guard_status" -ne 0 ]] || \
    fail "packaged push guard succeeded without an old-zero capability"
[[ ! -s "$push_guard_stdout" ]] || fail "failed packaged push guard wrote stdout"
[[ "$(<"$push_guard_stderr")" == "JIDOKA_PUSH_GUARD_FAILED" ]] || \
    fail "failed packaged push guard disclosed unexpected diagnostics"
/usr/bin/awk \
    -v elapsed="$push_guard_seconds" \
    -v bound="$PUSH_GUARD_EOF_BOUND_SECONDS" \
    'BEGIN { exit !(elapsed < bound) }' || \
    fail "packaged push guard did not receive EOF within ${PUSH_GUARD_EOF_BOUND_SECONDS}s"
printf 'push_guard_open_stdin_seconds=%s\n' "$push_guard_seconds"

assert_exact_json_keys "$preflight_stdout" bundleIdentifier manifestSHA256 resourceName schemaVersion status workingDirectory
assert_exact_json_keys "$engine_stdout" identifier status workingDirectory
[[ "$(/usr/bin/plutil -extract bundleIdentifier raw "$preflight_stdout")" == "com.maroffo.JidokaCode" ]]
[[ "$(/usr/bin/plutil -extract resourceName raw "$preflight_stdout")" == "jidoka-code" ]]
[[ "$(/usr/bin/plutil -extract schemaVersion raw "$preflight_stdout")" == "1" ]]
[[ "$(/usr/bin/plutil -extract status raw "$preflight_stdout")" == "ok" ]]
[[ "$(/usr/bin/plutil -extract workingDirectory raw "$preflight_stdout")" == "/" ]]
[[ "$(/usr/bin/plutil -extract identifier raw "$engine_stdout")" == "com.maroffo.JidokaCode.Engine" ]]
[[ "$(/usr/bin/plutil -extract status raw "$engine_stdout")" == "ok" ]]
[[ "$(/usr/bin/plutil -extract workingDirectory raw "$engine_stdout")" == "/" ]]
manifest_digest="$(/usr/bin/shasum -a 256 "$COPIED_APP/Contents/Resources/Pi/manifest.json" | /usr/bin/awk '{print $1}')"
[[ "$(/usr/bin/plutil -extract manifestSHA256 raw "$preflight_stdout")" == "$manifest_digest" ]] || \
    fail "reported manifest digest differs from packaged bytes"

for release_runtime_mutation in \
    pi-bytes \
    manifest-bytes \
    writable-mode \
    extra-entry \
    hard-link \
    acl \
    escaping-symlink \
    unsigned-node
do
    assert_fresh_release_runtime_mutation "$release_runtime_mutation"
done

/usr/bin/ditto "$COPIED_APP" "$MUTATED_APP"
mutated_manifest="$MUTATED_APP/Contents/Resources/Pi/manifest.json"
printf '%s\n' '{"name":"jidoka-code","purpose":"mutated-e2e","schemaVersion":1}' >"$mutated_manifest"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode "$MUTATED_APP"
mutated_stdout="$TEMP_ROOT/mutated.json"
mutated_stderr="$TEMP_ROOT/mutated.stderr"
run_packaged_command \
    "$MUTATED_APP/Contents/MacOS/Jidoka Code" \
    "$mutated_stdout" \
    "$mutated_stderr" \
    --preflight
[[ ! -s "$mutated_stderr" ]] || fail "valid mutated manifest wrote stderr"
assert_exact_json_keys "$mutated_stdout" bundleIdentifier manifestSHA256 resourceName schemaVersion status workingDirectory
mutated_digest="$(/usr/bin/shasum -a 256 "$mutated_manifest" | /usr/bin/awk '{print $1}')"
reported_mutated_digest="$(/usr/bin/plutil -extract manifestSHA256 raw "$mutated_stdout")"
[[ "$reported_mutated_digest" == "$mutated_digest" && "$mutated_digest" != "$manifest_digest" ]] || \
    fail "preflight did not consume mutated packaged bytes"

printf '%s\n' '{"name":"jidoka-code","schemaVersion":2}' >"$mutated_manifest"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode "$MUTATED_APP"
assert_failure "$MUTATED_APP/Contents/MacOS/Jidoka Code" 'unsupportedSchema(2)'
/bin/rm -f -- "$mutated_manifest"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode "$MUTATED_APP"
assert_failure "$MUTATED_APP/Contents/MacOS/Jidoka Code" 'manifestMissing'

/usr/bin/ditto "$COPIED_APP" "$MUTATED_RUNNER_APP"
printf '\n' >>"$MUTATED_RUNNER_APP/Contents/Resources/Pi/runtime/pi-rpc-profile-probe.mjs"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode "$MUTATED_RUNNER_APP"
assert_pi_runner_failure "$MUTATED_RUNNER_APP"

/usr/bin/ditto "$COPIED_APP" "$MUTATED_ATTESTATION_APP"
printf '\n' \
    >>"$MUTATED_ATTESTATION_APP/Contents/Resources/Pi/runtime/pi-runtime-attestation.mjs"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode \
    "$MUTATED_ATTESTATION_APP"
assert_pi_runner_failure "$MUTATED_ATTESTATION_APP"

/usr/bin/ditto "$COPIED_APP" "$MUTATED_POLICY_APP"
printf '\n' >>"$MUTATED_POLICY_APP/Contents/Resources/Pi/runtime/pi-runtime-builds.json"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode \
    "$MUTATED_POLICY_APP"
assert_pi_policy_failure "$MUTATED_POLICY_APP"

/usr/bin/ditto "$COPIED_APP" "$MUTATED_WORKFLOW_APP"
printf '\n' \
    >>"$MUTATED_WORKFLOW_APP/Contents/Resources/Pi/skills/jidoka-code-plan/SKILL.md"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode \
    "$MUTATED_WORKFLOW_APP"
if JIDOKA_PI_RESOURCE_ROOT="$MUTATED_WORKFLOW_APP/Contents/Resources/Pi" \
    "$NODE_BIN" \
    "$ROOT/scripts/tests/test-jidoka-extension-rpc.mjs" \
    >"$TEMP_ROOT/mutated-workflow.stdout" 2>"$TEMP_ROOT/mutated-workflow.stderr"
then
    fail "mutated packaged workflow resource passed extension attestation"
fi

printf 'S1 package E2E: PASS\n'
printf 'app_minos=%s engine_minos=%s askpass_minos=%s push_guard_minos=%s herdr_host_minos=%s\n' \
    "$app_minos" "$engine_minos" "$askpass_minos" "$push_guard_minos" "$herdr_host_minos"
printf 'manifest_sha256=%s mutated_sha256=%s\n' "$manifest_digest" "$mutated_digest"
printf 'preflight=%s\n' "$(<"$preflight_stdout")"
printf 'engine=%s\n' "$(<"$engine_stdout")"
