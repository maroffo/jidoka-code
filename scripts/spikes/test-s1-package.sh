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
TEMP_ROOT=""

fail() {
    printf 'S1 package E2E failed: %s\n' "$1" >&2
    exit 1
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
    local argument="$2"
    local stdout_path="$3"
    local stderr_path="$4"
    /bin/mkdir -p "$TEMP_ROOT/home" "$TEMP_ROOT/runtime-tmp"
    (
        cd /
        /usr/bin/env -i \
            HOME="$TEMP_ROOT/home" \
            PATH="/usr/bin:/bin" \
            TMPDIR="$TEMP_ROOT/runtime-tmp" \
            "$executable" "$argument"
    ) >"$stdout_path" 2>"$stderr_path"
}

assert_failure() {
    local executable="$1"
    local expected_error="$2"
    local stdout_path="$TEMP_ROOT/failure.stdout"
    local stderr_path="$TEMP_ROOT/failure.stderr"
    if run_packaged_command "$executable" --preflight "$stdout_path" "$stderr_path"; then
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
    if (
        cd /
        /usr/bin/env -i \
            HOME="$TEMP_ROOT/home" \
            PATH="/opt/homebrew/bin:/usr/bin:/bin" \
            TMPDIR="$TEMP_ROOT/runtime-tmp" \
            "$app/Contents/MacOS/Jidoka Code" --pi-probe preflight
    ) >"$stdout_path" 2>"$stderr_path"; then
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
    if (
        cd /
        /usr/bin/env -i \
            HOME="$TEMP_ROOT/home" \
            PATH="/opt/homebrew/bin:/usr/bin:/bin" \
            TMPDIR="$TEMP_ROOT/runtime-tmp" \
            "$app/Contents/MacOS/Jidoka Code" --pi-probe preflight
    ) >"$stdout_path" 2>"$stderr_path"; then
        fail "mutated packaged Pi policy unexpectedly executed"
    fi
    [[ ! -s "$stdout_path" ]] || fail "mutated packaged Pi policy wrote stdout"
    /usr/bin/grep -Fq 'runnerFailed(1)' "$stderr_path" || \
        fail "mutated packaged Pi policy did not fail runtime attestation"
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

assert_bounded_command_runner() {
    local block_line
    local child_command
    local child_pid
    local distinctive_status=0
    local elapsed
    local false_status=0
    local fork_line
    local handler_line
    local runner="$ROOT/scripts/run-bounded-command.pl"
    local signal_child_command
    local signal_child_pid
    local signal_elapsed
    local signal_start
    local signal_status=0
    local start
    local status=0
    local unblock_line

    [[ -f "$runner" && -x "$runner" && ! -L "$runner" ]] || \
        fail "bounded command runner is unavailable"
    /usr/bin/perl -c "$runner" >/dev/null 2>&1 || fail "bounded command runner is invalid"
    "$runner" 2 /usr/bin/true || fail "bounded command runner changed a successful status"
    "$runner" 2 /usr/bin/false >/dev/null 2>&1 || false_status=$?
    [[ "$false_status" == "1" ]] || fail "bounded command runner changed a failed status"
    /bin/cat >"$TEMP_ROOT/bounded-exit-37.sh" <<'SCRIPT'
#!/bin/sh
exit 37
SCRIPT
    /bin/chmod 0700 "$TEMP_ROOT/bounded-exit-37.sh"
    "$runner" 2 "$TEMP_ROOT/bounded-exit-37.sh" >/dev/null 2>&1 || distinctive_status=$?
    [[ "$distinctive_status" == "37" ]] || \
        fail "bounded command runner changed a distinctive failed status"

    block_line="$(
        /usr/bin/grep -n -m 1 -F 'sigprocmask(SIG_BLOCK' "$runner" | /usr/bin/cut -d: -f1
    )"
    fork_line="$(
        /usr/bin/grep -n -m 1 -F "my \$pid = fork();" "$runner" | /usr/bin/cut -d: -f1
    )"
    handler_line="$(
        /usr/bin/grep -n -m 1 -F "\$SIG{HUP} = sub" "$runner" | /usr/bin/cut -d: -f1
    )"
    unblock_line="$(
        /usr/bin/grep -n -F "defined sigprocmask(SIG_SETMASK, \$previous_signals)" \
            "$runner" | /usr/bin/tail -n 1 | /usr/bin/cut -d: -f1
    )"
    [[ "$block_line" =~ ^[0-9]+$ && "$fork_line" =~ ^[0-9]+$ && \
        "$handler_line" =~ ^[0-9]+$ && "$unblock_line" =~ ^[0-9]+$ && \
        "$block_line" -lt "$fork_line" && "$fork_line" -lt "$handler_line" && \
        "$handler_line" -lt "$unblock_line" ]] || \
        fail "bounded command signal mask and handler ordering differs"

    /bin/cat >"$TEMP_ROOT/bounded-resistant.sh" <<'SCRIPT'
#!/bin/sh
trap 'exit 0' TERM
/bin/sh -c 'trap "" TERM; exec /bin/sleep 30' &
echo $! >"$1"
wait
SCRIPT
    /bin/chmod 0700 "$TEMP_ROOT/bounded-resistant.sh"
    start="$(/bin/date +%s)"
    "$runner" 1 "$TEMP_ROOT/bounded-resistant.sh" "$TEMP_ROOT/bounded-child.pid" \
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
echo $$ >"$1"
/bin/kill -TERM "$PPID"
exec /bin/sleep 30
SCRIPT
    /bin/chmod 0700 "$TEMP_ROOT/bounded-immediate-signal.sh"
    signal_start="$(/bin/date +%s)"
    "$runner" 30 "$TEMP_ROOT/bounded-immediate-signal.sh" \
        "$TEMP_ROOT/bounded-signal-child.pid" \
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
    if /bin/kill -0 "$signal_child_pid" 2>/dev/null; then
        signal_child_command="$(
            /bin/ps -p "$signal_child_pid" -o command= 2>/dev/null || true
        )"
        [[ "$signal_child_command" != "/bin/sleep 30" ]] || \
            fail "bounded command runner leaked an immediate-signal child"
    fi
    if "$runner" 1 relative-command >/dev/null 2>&1; then
        fail "bounded command runner accepted a relative executable"
    fi
}

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-s1.XXXXXX")"
readonly TEMP_ROOT
trap cleanup EXIT
assert_cleanup_guard
assert_bounded_command_runner
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
/usr/bin/grep -Fxq 'readonly INSTALL_LOCATION="/Applications"' \
    "$ROOT/scripts/package-installer.sh" || fail "installer destination differs"
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

ALLOW_ADHOC_SIGNING=1 "$ROOT/scripts/package-app.sh"
JIDOKA_PI_RESOURCE_ROOT="$SOURCE_APP/Contents/Resources/Pi" \
    /opt/homebrew/Cellar/node/26.6.0/bin/node \
    "$ROOT/scripts/tests/test-jidoka-extension-rpc.mjs"

/usr/bin/plutil -lint "$SOURCE_APP/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$SOURCE_APP/Contents/Info.plist")" == \
    "com.maroffo.JidokaCode" ]] || fail "application bundle identifier is not production"
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$SOURCE_APP/Contents/Info.plist")" == "14.0" ]]

expected_inventory="$(<"$ROOT/Packaging/app-inventory.txt")"
actual_inventory="$(cd "$SOURCE_APP" && /usr/bin/find . -print | LC_ALL=C /usr/bin/sort)"
[[ "$actual_inventory" == "$expected_inventory" ]] || fail "bundle inventory differs from allowlist"
[[ -z "$(/usr/bin/find "$SOURCE_APP" -type l -print)" ]] || fail "bundle contains symbolic links"

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

herdr_schema="$SOURCE_APP/Contents/Resources/Herdr/api-schema-0.8.0.json"
herdr_policy="$SOURCE_APP/Contents/Resources/Herdr/runtime-builds.json"
[[ "$(/usr/bin/shasum -a 256 "$herdr_schema" | /usr/bin/awk '{print $1}')" == \
    "88ff414aa996e390c2db05a37b95d28dbe4e81b98329f6ed7f7a2cc5c6ebf51a" ]] || \
    fail "packaged Herdr schema differs from approved bytes"
[[ "$(/usr/bin/shasum -a 256 "$herdr_policy" | /usr/bin/awk '{print $1}')" == \
    "3fdd7b5d6f273ab264c6c2f502e8c8902819cc353052191769c4ec22213d4673" ]] || \
    fail "packaged Herdr policy differs from approved bytes"
[[ "$(/usr/bin/plutil -extract schemaVersion raw "$herdr_policy")" == "1" ]]
[[ "$(/usr/bin/plutil -extract builds.0.version raw "$herdr_policy")" == "0.8.0" ]]
[[ "$(/usr/bin/plutil -extract builds.0.protocolVersion raw "$herdr_policy")" == "19" ]]
[[ "$(/usr/bin/plutil -extract builds.0.executableSHA256 raw "$herdr_policy")" == \
    "97bdb194a731262d2b70062621a5673b1cd409b9e6870df361bd65799217eaf3" ]]
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
    4d7be2b7ed582f2195bf19953dc74420be12c9066c2a9565b64f09afc204d566
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
    runtime/jidoka-tui-contract.mjs \
    3019e69f4e92356b55b8c149a420d2ab9816014a6be670ccd4db6887553d64ac
assert_resource_digest \
    runtime/node-runtime-builds.json \
    fd707070911b53f3930864c3ec6dcfabc7b4440bcf44c3012882751fb99bf906
assert_resource_digest \
    runtime/pi-rpc-profile-probe.mjs \
    83d081f9337bc1531e8c516e4248c324de26e325a4f8ef3895eb3df3417d45e9
assert_resource_digest \
    runtime/pi-rpc-workflow-probe.mjs \
    731267cc54cf7018258afc4393ca3357166c10c43b23601c420c597eb196f772
assert_resource_digest \
    runtime/pi-runtime-attestation.mjs \
    a2187f46e1a5e97cf8f87be230382f4bbd235d7c47d31eb933c821d799bd5e9e
assert_resource_digest \
    runtime/pi-runtime-builds.json \
    324d6a1738c08fd7dfbc1ca8fb324ed64d8fc3ac5bd1e2c293062cf4d4238248
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
    "59a4b657195d443c49f9211d25978dcdb29e64da0baea7e172c59ff5605b32e7" ]] || \
    fail "packaged local spike runner digest differs"

for path in \
    "$SOURCE_APP/Contents/Info.plist" \
    "$launch_agent_plist" \
    "$SOURCE_APP/Contents/Resources/Herdr/api-schema-0.8.0.json" \
    "$SOURCE_APP/Contents/Resources/Herdr/runtime-builds.json" \
    "$SOURCE_APP/Contents/Resources/Pi/manifest.json" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-resources.json" \
    "$SOURCE_APP/Contents/Resources/Pi/tui-resources.json" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-code.ts" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-deny-user-bash.js" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-runtime.ts" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-tui-runtime.ts" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/jidoka-extension-contract.mjs" \
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
    "$SOURCE_APP/Contents/_CodeSignature/CodeResources"
do
    [[ -f "$path" && ! -L "$path" ]] || fail "expected regular bundle file: $path"
done
for path in \
    "$SOURCE_EXECUTABLE" "$SOURCE_ENGINE" "$SOURCE_ASKPASS" \
    "$SOURCE_PUSH_GUARD" "$SOURCE_HERDR_HOST"
do
    [[ -f "$path" && -x "$path" && ! -L "$path" ]] || fail "expected executable: $path"
    assert_portable_macho "$path"
done

/usr/bin/codesign --verify --strict "$SOURCE_ENGINE"
/usr/bin/codesign --verify --strict "$SOURCE_ASKPASS"
/usr/bin/codesign --verify --strict "$SOURCE_PUSH_GUARD"
/usr/bin/codesign --verify --strict "$SOURCE_HERDR_HOST"
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

app_minos="$(/usr/bin/otool -l "$SOURCE_EXECUTABLE" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
engine_minos="$(/usr/bin/otool -l "$SOURCE_ENGINE" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
askpass_minos="$(/usr/bin/otool -l "$SOURCE_ASKPASS" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
push_guard_minos="$(/usr/bin/otool -l "$SOURCE_PUSH_GUARD" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
herdr_host_minos="$(/usr/bin/otool -l "$SOURCE_HERDR_HOST" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
[[ "$app_minos" == "14.0" && "$engine_minos" == "14.0" && \
    "$askpass_minos" == "14.0" && "$push_guard_minos" == "14.0" && \
    "$herdr_host_minos" == "14.0" ]] || \
    fail "unexpected minimum OS"

BIN_DIR="$(/usr/bin/xcrun swift build --configuration release --show-bin-path)"
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
run_packaged_command "$COPIED_APP/Contents/MacOS/Jidoka Code" --preflight "$preflight_stdout" "$preflight_stderr"
run_packaged_command "$COPIED_APP/Contents/Helpers/JidokaCodeEngineProbe" --probe "$engine_stdout" "$engine_stderr"
[[ ! -s "$preflight_stderr" && ! -s "$engine_stderr" ]] || fail "successful probe wrote stderr"
askpass_stdout="$TEMP_ROOT/askpass.stdout"
askpass_stderr="$TEMP_ROOT/askpass.stderr"
if run_packaged_command \
    "$COPIED_APP/Contents/Helpers/JidokaCodeAskPass" \
    "Password for https://github.com" \
    "$askpass_stdout" \
    "$askpass_stderr"
then
    fail "packaged askpass succeeded without a one-shot capability"
fi
[[ ! -s "$askpass_stdout" ]] || fail "failed packaged askpass wrote stdout"
[[ "$(<"$askpass_stderr")" == "JIDOKA_ASKPASS_FAILED" ]] || \
    fail "failed packaged askpass disclosed unexpected diagnostics"
push_guard_stdout="$TEMP_ROOT/push-guard.stdout"
push_guard_stderr="$TEMP_ROOT/push-guard.stderr"
if run_packaged_command \
    "$COPIED_APP/Contents/Helpers/GitHooks/pre-push" \
    "origin" \
    "$push_guard_stdout" \
    "$push_guard_stderr"
then
    fail "packaged push guard succeeded without an old-zero capability"
fi
[[ ! -s "$push_guard_stdout" ]] || fail "failed packaged push guard wrote stdout"
[[ "$(<"$push_guard_stderr")" == "JIDOKA_PUSH_GUARD_FAILED" ]] || \
    fail "failed packaged push guard disclosed unexpected diagnostics"

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

/usr/bin/ditto "$COPIED_APP" "$MUTATED_APP"
mutated_manifest="$MUTATED_APP/Contents/Resources/Pi/manifest.json"
printf '%s\n' '{"name":"jidoka-code","purpose":"mutated-e2e","schemaVersion":1}' >"$mutated_manifest"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode "$MUTATED_APP"
mutated_stdout="$TEMP_ROOT/mutated.json"
mutated_stderr="$TEMP_ROOT/mutated.stderr"
run_packaged_command "$MUTATED_APP/Contents/MacOS/Jidoka Code" --preflight "$mutated_stdout" "$mutated_stderr"
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
    /opt/homebrew/Cellar/node/26.6.0/bin/node \
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
