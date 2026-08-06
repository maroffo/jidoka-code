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
readonly SIGN_IDENTITY="${SIGN_IDENTITY:--}"

fail() {
    printf 'packaging failed: %s\n' "$1" >&2
    exit 1
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
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --options runtime \
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
    identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)"
    printf '%s\n' "$identities" | /usr/bin/awk -v expected="$SIGN_IDENTITY" '
        toupper($2) == toupper(expected) { found = 1 }
        END { exit(found ? 0 : 1) }
    ' || fail "SIGN_IDENTITY is not a valid local identity"
}

verify_signed_team() {
    local app_team
    local helper_team
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        return 0
    fi
    app_team="$(/usr/bin/codesign -dvvv "$APP" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    helper_team="$(/usr/bin/codesign -dvvv "$ENGINE_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    [[ -n "$app_team" && "$app_team" != "not set" && "$app_team" == "$helper_team" ]] || \
        fail "signed app and helper do not share a concrete TeamIdentifier"
}

verify_signing_identity
"$ROOT/scripts/verify-toolchain.sh"

for input in \
    "$ROOT/Packaging/Info.plist" \
    "$ROOT/Packaging/com.maroffo.JidokaCode.EngineProbe.plist" \
    "$ROOT/Resources/Pi/manifest.json" \
    "$ROOT/Resources/Pi/extensions/jidoka-deny-user-bash.js" \
    "$ROOT/Resources/Pi/extensions/jidoka-runtime.ts" \
    "$ROOT/Resources/Pi/skills/jidoka-code-issue-triage/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-orchestrate/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-plan/SKILL.md" \
    "$ROOT/Resources/Pi/skills/jidoka-code-pr-review/SKILL.md" \
    "$ROOT/Resources/Pi/workflow-skills/jidoka-code-orchestration-fidelity/SKILL.md" \
    "$ROOT/Resources/Pi/workflow-skills/jidoka-code-planning-fidelity/SKILL.md" \
    "$ROOT/Resources/Pi/workflow-skills/jidoka-code-pr-fidelity/SKILL.md" \
    "$ROOT/Resources/Pi/workflow-skills/jidoka-code-triage-fidelity/SKILL.md" \
    "$ROOT/scripts/spikes/jidoka-local-spikes.mjs" \
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
BIN_DIR="$(/usr/bin/xcrun swift build --configuration release --show-bin-path)"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
readonly BIN_DIR
case "$BIN_DIR" in
    "$ROOT/.build/"*) ;;
    *) fail "SwiftPM binary directory escapes .build: $BIN_DIR" ;;
esac

for executable in "$BIN_DIR/JidokaCodeApp" "$BIN_DIR/JidokaCodeEngineProbe"; do
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
    "$LAUNCH_AGENTS" \
    "$RESOURCES/Spikes" \
    "$RESOURCES/Pi/extensions" \
    "$RESOURCES/Pi/runtime" \
    "$RESOURCES/Pi/skills/jidoka-code-issue-triage" \
    "$RESOURCES/Pi/skills/jidoka-code-orchestrate" \
    "$RESOURCES/Pi/skills/jidoka-code-plan" \
    "$RESOURCES/Pi/skills/jidoka-code-pr-review" \
    "$RESOURCES/Pi/workflow-skills/jidoka-code-orchestration-fidelity" \
    "$RESOURCES/Pi/workflow-skills/jidoka-code-planning-fidelity" \
    "$RESOURCES/Pi/workflow-skills/jidoka-code-pr-fidelity" \
    "$RESOURCES/Pi/workflow-skills/jidoka-code-triage-fidelity"

/usr/bin/install -m 0755 "$BIN_DIR/JidokaCodeApp" "$APP_EXECUTABLE"
/usr/bin/install -m 0755 "$BIN_DIR/JidokaCodeEngineProbe" "$ENGINE_EXECUTABLE"
/usr/bin/install -m 0644 "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
/usr/bin/install -m 0644 \
    "$ROOT/Packaging/com.maroffo.JidokaCode.EngineProbe.plist" \
    "$LAUNCH_AGENTS/com.maroffo.JidokaCode.EngineProbe.plist"
/usr/bin/install -m 0644 "$ROOT/Resources/Pi/manifest.json" "$RESOURCES/Pi/manifest.json"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/extensions/jidoka-deny-user-bash.js" \
    "$RESOURCES/Pi/extensions/jidoka-deny-user-bash.js"
/usr/bin/install -m 0644 \
    "$ROOT/Resources/Pi/extensions/jidoka-runtime.ts" \
    "$RESOURCES/Pi/extensions/jidoka-runtime.ts"
for skill in \
    jidoka-code-issue-triage \
    jidoka-code-orchestrate \
    jidoka-code-plan \
    jidoka-code-pr-review
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
    "$ROOT/scripts/spikes/pi-rpc-profile-probe.mjs" \
    "$RESOURCES/Pi/runtime/pi-rpc-profile-probe.mjs"
/usr/bin/install -m 0644 \
    "$ROOT/scripts/spikes/pi-rpc-workflow-probe.mjs" \
    "$RESOURCES/Pi/runtime/pi-rpc-workflow-probe.mjs"
/usr/bin/install -m 0644 \
    "$ROOT/scripts/spikes/jidoka-local-spikes.mjs" \
    "$RESOURCES/Spikes/jidoka-local-spikes.mjs"

/usr/bin/strip -S "$APP_EXECUTABLE" "$ENGINE_EXECUTABLE"
remove_developer_rpaths "$APP_EXECUTABLE"
remove_developer_rpaths "$ENGINE_EXECUTABLE"
assert_portable_macho "$APP_EXECUTABLE"
assert_portable_macho "$ENGINE_EXECUTABLE"

/usr/bin/plutil -lint "$CONTENTS/Info.plist"
/usr/bin/plutil -lint "$LAUNCH_AGENTS/com.maroffo.JidokaCode.EngineProbe.plist"
sign_path "$ENGINE_EXECUTABLE" com.maroffo.JidokaCode.EngineProbe
sign_path "$APP" com.maroffo.JidokaCode.Probe
/usr/bin/codesign --verify --strict "$ENGINE_EXECUTABLE"
/usr/bin/codesign --verify --strict --deep "$APP"
verify_signed_team

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf 'signing=adhoc\n'
else
    printf 'signing=identity\n'
fi
printf 'packaged=%s\n' "$APP"
