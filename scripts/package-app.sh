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
readonly SIGN_IDENTITY="${SIGN_IDENTITY:--}"
readonly SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"
readonly ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"
CODESIGN_KEYCHAIN_ARGUMENTS=()
SECURITY_KEYCHAIN_ARGUMENTS=()

fail() {
    printf 'packaging failed: %s\n' "$1" >&2
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
    CODESIGN_KEYCHAIN_ARGUMENTS=(--keychain "$SIGNING_KEYCHAIN")
    SECURITY_KEYCHAIN_ARGUMENTS=("$SIGNING_KEYCHAIN")
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

sign_path() {
    local path="$1"
    local identifier="$2"
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        /usr/bin/codesign --force --sign - --identifier "$identifier" "$path"
    else
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
            "${CODESIGN_KEYCHAIN_ARGUMENTS[@]}" --identifier "$identifier" "$path"
    fi
}

verify_signing_identity() {
    local identities
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        return
    fi
    [[ "$SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || \
        fail "SIGN_IDENTITY must be a 40-character SHA-1 identity"
    identities="$(
        /usr/bin/security find-identity -v -p codesigning \
            "${SECURITY_KEYCHAIN_ARGUMENTS[@]}" 2>/dev/null
    )"
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
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        return 0
    fi
    app_team="$(/usr/bin/codesign -dvvv "$APP" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    helper_team="$(/usr/bin/codesign -dvvv "$ENGINE_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    askpass_team="$(/usr/bin/codesign -dvvv "$ASKPASS_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    push_guard_team="$(/usr/bin/codesign -dvvv "$PUSH_GUARD_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    herdr_host_team="$(/usr/bin/codesign -dvvv "$HERDR_HOST_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    [[ -n "$app_team" && "$app_team" != "not set" && \
        "$app_team" == "$helper_team" && "$app_team" == "$askpass_team" && \
        "$app_team" == "$push_guard_team" && "$app_team" == "$herdr_host_team" ]] || \
        fail "signed app and helpers do not share a concrete TeamIdentifier"
}

[[ "$ALLOW_ADHOC_SIGNING" == "0" || "$ALLOW_ADHOC_SIGNING" == "1" ]] || \
    fail "ALLOW_ADHOC_SIGNING must be 0 or 1"
if [[ "$SIGN_IDENTITY" == "-" && "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    fail "release packaging requires an explicit SIGN_IDENTITY"
fi
configure_signing_keychain
readonly -a CODESIGN_KEYCHAIN_ARGUMENTS SECURITY_KEYCHAIN_ARGUMENTS
verify_signing_identity
"$ROOT/scripts/verify-toolchain.sh"

for input in \
    "$ROOT/Packaging/Info.plist" \
    "$ROOT/Packaging/app-inventory.txt" \
    "$ROOT/Packaging/com.maroffo.JidokaCode.EngineProbe.plist" \
    "$ROOT/Resources/Herdr/api-schema-0.8.0.json" \
    "$ROOT/Resources/Herdr/runtime-builds.json" \
    "$ROOT/Resources/Pi/manifest.json" \
    "$ROOT/Resources/Pi/workflow-resources.json" \
    "$ROOT/Resources/Pi/tui-resources.json" \
    "$ROOT/Resources/Pi/extensions/jidoka-code.ts" \
    "$ROOT/Resources/Pi/extensions/jidoka-deny-user-bash.js" \
    "$ROOT/Resources/Pi/extensions/jidoka-runtime.ts" \
    "$ROOT/Resources/Pi/extensions/jidoka-tui-runtime.ts" \
    "$ROOT/Resources/Pi/runtime/jidoka-extension-contract.mjs" \
    "$ROOT/Resources/Pi/runtime/jidoka-tui-contract.mjs" \
    "$ROOT/Resources/Pi/runtime/node-runtime-builds.json" \
    "$ROOT/Resources/Pi/runtime/pi-runtime-builds.json" \
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

cd "$ROOT"
/usr/bin/xcrun swift build --configuration release --product JidokaCodeApp
/usr/bin/xcrun swift build --configuration release --product JidokaCodeEngineProbe
/usr/bin/xcrun swift build --configuration release --product JidokaCodeAskPass
/usr/bin/xcrun swift build --configuration release --product JidokaCodePushGuard
/usr/bin/xcrun swift build --configuration release --product JidokaCodeHerdrHost
BIN_DIR="$(/usr/bin/xcrun swift build --configuration release --show-bin-path)"
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
    "$ROOT/Packaging/com.maroffo.JidokaCode.EngineProbe.plist" \
    "$LAUNCH_AGENTS/com.maroffo.JidokaCode.EngineProbe.plist"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Herdr/api-schema-0.8.0.json" \
    "$HERDR_RESOURCES/api-schema-0.8.0.json"
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

[[ "$(/usr/bin/shasum -a 256 "$HERDR_RESOURCES/api-schema-0.8.0.json" | /usr/bin/awk '{print $1}')" == \
    "88ff414aa996e390c2db05a37b95d28dbe4e81b98329f6ed7f7a2cc5c6ebf51a" ]] || \
    fail "packaged Herdr API schema digest differs"
[[ "$(/usr/bin/shasum -a 256 "$HERDR_RESOURCES/runtime-builds.json" | /usr/bin/awk '{print $1}')" == \
    "3fdd7b5d6f273ab264c6c2f502e8c8902819cc353052191769c4ec22213d4673" ]] || \
    fail "packaged Herdr runtime policy digest differs"
/usr/bin/plutil -convert xml1 -o /dev/null "$HERDR_RESOURCES/runtime-builds.json"
/usr/bin/plutil -lint "$CONTENTS/Info.plist"
/usr/bin/plutil -lint "$LAUNCH_AGENTS/com.maroffo.JidokaCode.EngineProbe.plist"
sign_path "$ENGINE_EXECUTABLE" com.maroffo.JidokaCode.EngineProbe
sign_path "$ASKPASS_EXECUTABLE" com.maroffo.JidokaCode.AskPass
sign_path "$PUSH_GUARD_EXECUTABLE" com.maroffo.JidokaCode.PushGuard
sign_path "$HERDR_HOST_EXECUTABLE" com.maroffo.JidokaCode.HerdrHost
sign_path "$APP" com.maroffo.JidokaCode.Probe
/usr/bin/codesign --verify --strict "$ENGINE_EXECUTABLE"
/usr/bin/codesign --verify --strict "$ASKPASS_EXECUTABLE"
/usr/bin/codesign --verify --strict "$PUSH_GUARD_EXECUTABLE"
/usr/bin/codesign --verify --strict "$HERDR_HOST_EXECUTABLE"
/usr/bin/codesign --verify --strict --deep "$APP"
verify_signed_team

actual_inventory="$(cd "$APP" && /usr/bin/find . -print | LC_ALL=C /usr/bin/sort)"
expected_inventory="$(<"$ROOT/Packaging/app-inventory.txt")"
[[ "$actual_inventory" == "$expected_inventory" ]] || fail "bundle inventory differs from allowlist"
[[ -z "$(/usr/bin/find "$APP" -type l -print)" ]] || fail "bundle contains symbolic links"
[[ -z "$(/usr/bin/find "$APP" -type f -name herdr -print)" ]] || \
    fail "external Herdr runtime must not be bundled"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf 'signing=adhoc\n'
else
    printf 'signing=identity\n'
fi
printf 'packaged=%s\n' "$APP"
