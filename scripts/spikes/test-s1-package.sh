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

assert_cleanup_guard
TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jidoka-code-s1.XXXXXX")"
readonly TEMP_ROOT
trap cleanup EXIT
readonly COPIED_APP="$TEMP_ROOT/Jidoka Code.app"
readonly MUTATED_APP="$TEMP_ROOT/Jidoka Code Mutated.app"
readonly MUTATED_RUNNER_APP="$TEMP_ROOT/Jidoka Code Runner Mutated.app"

"$ROOT/scripts/package-app.sh"

/usr/bin/plutil -lint "$SOURCE_APP/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$SOURCE_APP/Contents/Info.plist")" == \
    "com.maroffo.JidokaCode.Probe" ]]
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$SOURCE_APP/Contents/Info.plist")" == "14.0" ]]

expected_inventory="$(cat <<'EOF'
.
./Contents
./Contents/Helpers
./Contents/Helpers/JidokaCodeEngineProbe
./Contents/Info.plist
./Contents/Library
./Contents/Library/LaunchAgents
./Contents/Library/LaunchAgents/com.maroffo.JidokaCode.EngineProbe.plist
./Contents/MacOS
./Contents/MacOS/Jidoka Code
./Contents/Resources
./Contents/Resources/Pi
./Contents/Resources/Pi/extensions
./Contents/Resources/Pi/extensions/jidoka-deny-user-bash.js
./Contents/Resources/Pi/extensions/jidoka-runtime.ts
./Contents/Resources/Pi/manifest.json
./Contents/Resources/Pi/runtime
./Contents/Resources/Pi/runtime/pi-rpc-profile-probe.mjs
./Contents/Resources/Pi/runtime/pi-rpc-workflow-probe.mjs
./Contents/Resources/Pi/skills
./Contents/Resources/Pi/skills/jidoka-code-issue-triage
./Contents/Resources/Pi/skills/jidoka-code-issue-triage/SKILL.md
./Contents/Resources/Pi/skills/jidoka-code-orchestrate
./Contents/Resources/Pi/skills/jidoka-code-orchestrate/SKILL.md
./Contents/Resources/Pi/skills/jidoka-code-plan
./Contents/Resources/Pi/skills/jidoka-code-plan/SKILL.md
./Contents/Resources/Pi/skills/jidoka-code-pr-review
./Contents/Resources/Pi/skills/jidoka-code-pr-review/SKILL.md
./Contents/Resources/Pi/workflow-skills
./Contents/Resources/Pi/workflow-skills/jidoka-code-orchestration-fidelity
./Contents/Resources/Pi/workflow-skills/jidoka-code-orchestration-fidelity/SKILL.md
./Contents/Resources/Pi/workflow-skills/jidoka-code-planning-fidelity
./Contents/Resources/Pi/workflow-skills/jidoka-code-planning-fidelity/SKILL.md
./Contents/Resources/Pi/workflow-skills/jidoka-code-pr-fidelity
./Contents/Resources/Pi/workflow-skills/jidoka-code-pr-fidelity/SKILL.md
./Contents/Resources/Pi/workflow-skills/jidoka-code-triage-fidelity
./Contents/Resources/Pi/workflow-skills/jidoka-code-triage-fidelity/SKILL.md
./Contents/Resources/Spikes
./Contents/Resources/Spikes/jidoka-local-spikes.mjs
./Contents/_CodeSignature
./Contents/_CodeSignature/CodeResources
EOF
)"
actual_inventory="$(cd "$SOURCE_APP" && /usr/bin/find . -print | LC_ALL=C /usr/bin/sort)"
[[ "$actual_inventory" == "$expected_inventory" ]] || fail "bundle inventory differs from allowlist"
[[ -z "$(/usr/bin/find "$SOURCE_APP" -type l -print)" ]] || fail "bundle contains symbolic links"

launch_agent_plist="$SOURCE_APP/Contents/Library/LaunchAgents/com.maroffo.JidokaCode.EngineProbe.plist"
/usr/bin/plutil -lint "$launch_agent_plist"
[[ "$(/usr/bin/plutil -extract Label raw "$launch_agent_plist")" == \
    "com.maroffo.JidokaCode.EngineProbe" ]]
[[ "$(/usr/bin/plutil -extract BundleProgram raw "$launch_agent_plist")" == \
    "Contents/Helpers/JidokaCodeEngineProbe" ]]
[[ "$(/usr/bin/plutil -extract ProgramArguments.3 raw "$launch_agent_plist")" == "1" ]]
[[ "$(/usr/bin/plutil -extract RunAtLoad raw "$launch_agent_plist")" == "true" ]]
[[ "$(/usr/bin/plutil -extract KeepAlive.SuccessfulExit raw "$launch_agent_plist")" == "false" ]]
[[ "$(/usr/bin/plutil -extract 'MachServices.com\.maroffo\.JidokaCode\.EngineProbe' raw "$launch_agent_plist")" == "true" ]] || \
    fail "launch agent Mach service differs from allowlist"

assert_resource_digest() {
    local relative_path="$1"
    local expected_digest="$2"
    local resource="$SOURCE_APP/Contents/Resources/Pi/$relative_path"
    [[ -f "$resource" && ! -L "$resource" ]] || fail "missing regular Pi resource: $relative_path"
    [[ "$(/usr/bin/shasum -a 256 "$resource" | /usr/bin/awk '{print $1}')" == \
        "$expected_digest" ]] || fail "packaged Pi resource digest differs: $relative_path"
}
assert_resource_digest \
    extensions/jidoka-deny-user-bash.js \
    ba18988ad739c592920555515ee246e07d325f0e90df345a61de4e7f41a24995
assert_resource_digest \
    extensions/jidoka-runtime.ts \
    b6bae1cb282d95b3c1a3e6e4f37c5b967aa5bd3885ec3050c5d7bddb72b4a19b
assert_resource_digest \
    runtime/pi-rpc-profile-probe.mjs \
    748a14b739a910fa5318819ed5a9391ef0b0f0a13fb028f942477bc373976679
assert_resource_digest \
    runtime/pi-rpc-workflow-probe.mjs \
    37ebfc816041f9242b5da4298e064dbb9bcde794ab192926fca6f73ca156c1dd
assert_resource_digest \
    skills/jidoka-code-issue-triage/SKILL.md \
    04b3b248a86dffbde0a543ddf1276f7515454fa7311347f317ff980d5ad9c5f6
assert_resource_digest \
    skills/jidoka-code-orchestrate/SKILL.md \
    7a7339c25f27134c443d389472c404a0e9ae161ddb826ee3b13921ee76522a22
assert_resource_digest \
    skills/jidoka-code-plan/SKILL.md \
    71fc244807117d61d2f335d7120c19e1d08bb04eab095013a86a3eaeb9bdfad9
assert_resource_digest \
    skills/jidoka-code-pr-review/SKILL.md \
    3ec091bfc47124074ccf01496078460be9b1b42c01d5636d10ac6288930e832d
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
    "$SOURCE_APP/Contents/Resources/Pi/manifest.json" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-deny-user-bash.js" \
    "$SOURCE_APP/Contents/Resources/Pi/extensions/jidoka-runtime.ts" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/pi-rpc-profile-probe.mjs" \
    "$SOURCE_APP/Contents/Resources/Pi/runtime/pi-rpc-workflow-probe.mjs" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-issue-triage/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-orchestrate/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-plan/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/skills/jidoka-code-pr-review/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-skills/jidoka-code-orchestration-fidelity/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-skills/jidoka-code-planning-fidelity/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-skills/jidoka-code-pr-fidelity/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Pi/workflow-skills/jidoka-code-triage-fidelity/SKILL.md" \
    "$SOURCE_APP/Contents/Resources/Spikes/jidoka-local-spikes.mjs" \
    "$SOURCE_APP/Contents/_CodeSignature/CodeResources"
do
    [[ -f "$path" && ! -L "$path" ]] || fail "expected regular bundle file: $path"
done
for path in "$SOURCE_EXECUTABLE" "$SOURCE_ENGINE"; do
    [[ -f "$path" && -x "$path" && ! -L "$path" ]] || fail "expected executable: $path"
    assert_portable_macho "$path"
done

/usr/bin/codesign --verify --strict "$SOURCE_ENGINE"
/usr/bin/codesign --verify --strict --deep "$SOURCE_APP"

app_minos="$(/usr/bin/otool -l "$SOURCE_EXECUTABLE" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
engine_minos="$(/usr/bin/otool -l "$SOURCE_ENGINE" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
[[ "$app_minos" == "14.0" && "$engine_minos" == "14.0" ]] || fail "unexpected minimum OS"

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
/usr/bin/cmp -s "$TEMP_ROOT/expected-app" "$TEMP_ROOT/actual-app" || \
    fail "packaged app lacks build-product provenance"
/usr/bin/cmp -s "$TEMP_ROOT/expected-engine" "$TEMP_ROOT/actual-engine" || \
    fail "packaged helper lacks build-product provenance"

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

assert_exact_json_keys "$preflight_stdout" bundleIdentifier manifestSHA256 resourceName schemaVersion status workingDirectory
assert_exact_json_keys "$engine_stdout" identifier status workingDirectory
[[ "$(/usr/bin/plutil -extract bundleIdentifier raw "$preflight_stdout")" == "com.maroffo.JidokaCode.Probe" ]]
[[ "$(/usr/bin/plutil -extract resourceName raw "$preflight_stdout")" == "jidoka-code" ]]
[[ "$(/usr/bin/plutil -extract schemaVersion raw "$preflight_stdout")" == "1" ]]
[[ "$(/usr/bin/plutil -extract status raw "$preflight_stdout")" == "ok" ]]
[[ "$(/usr/bin/plutil -extract workingDirectory raw "$preflight_stdout")" == "/" ]]
[[ "$(/usr/bin/plutil -extract identifier raw "$engine_stdout")" == "com.maroffo.JidokaCode.EngineProbe" ]]
[[ "$(/usr/bin/plutil -extract status raw "$engine_stdout")" == "ok" ]]
[[ "$(/usr/bin/plutil -extract workingDirectory raw "$engine_stdout")" == "/" ]]
manifest_digest="$(/usr/bin/shasum -a 256 "$COPIED_APP/Contents/Resources/Pi/manifest.json" | /usr/bin/awk '{print $1}')"
[[ "$(/usr/bin/plutil -extract manifestSHA256 raw "$preflight_stdout")" == "$manifest_digest" ]] || \
    fail "reported manifest digest differs from packaged bytes"

/usr/bin/ditto "$COPIED_APP" "$MUTATED_APP"
mutated_manifest="$MUTATED_APP/Contents/Resources/Pi/manifest.json"
printf '%s\n' '{"name":"jidoka-code","purpose":"mutated-e2e","schemaVersion":1}' >"$mutated_manifest"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode.Probe "$MUTATED_APP"
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
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode.Probe "$MUTATED_APP"
assert_failure "$MUTATED_APP/Contents/MacOS/Jidoka Code" 'unsupportedSchema(2)'
/bin/rm -f -- "$mutated_manifest"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode.Probe "$MUTATED_APP"
assert_failure "$MUTATED_APP/Contents/MacOS/Jidoka Code" 'manifestMissing'

/usr/bin/ditto "$COPIED_APP" "$MUTATED_RUNNER_APP"
printf '\n' >>"$MUTATED_RUNNER_APP/Contents/Resources/Pi/runtime/pi-rpc-profile-probe.mjs"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode.Probe "$MUTATED_RUNNER_APP"
assert_pi_runner_failure "$MUTATED_RUNNER_APP"

printf 'S1 package E2E: PASS\n'
printf 'app_minos=%s engine_minos=%s\n' "$app_minos" "$engine_minos"
printf 'manifest_sha256=%s mutated_sha256=%s\n' "$manifest_digest" "$mutated_digest"
printf 'preflight=%s\n' "$(<"$preflight_stdout")"
printf 'engine=%s\n' "$(<"$engine_stdout")"
