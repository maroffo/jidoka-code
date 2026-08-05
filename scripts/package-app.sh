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
readonly RESOURCES="$CONTENTS/Resources"
readonly APP_EXECUTABLE="$MACOS/Jidoka Code"
readonly ENGINE_EXECUTABLE="$HELPERS/JidokaCodeEngineProbe"

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

"$ROOT/scripts/verify-toolchain.sh"

for input in \
    "$ROOT/Packaging/Info.plist" \
    "$ROOT/Resources/Pi/manifest.json"
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
/bin/mkdir -p "$MACOS" "$HELPERS" "$RESOURCES/Pi"

/usr/bin/install -m 0755 "$BIN_DIR/JidokaCodeApp" "$APP_EXECUTABLE"
/usr/bin/install -m 0755 "$BIN_DIR/JidokaCodeEngineProbe" "$ENGINE_EXECUTABLE"
/usr/bin/install -m 0644 "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
/usr/bin/install -m 0644 "$ROOT/Resources/Pi/manifest.json" "$RESOURCES/Pi/manifest.json"

/usr/bin/strip -S "$APP_EXECUTABLE" "$ENGINE_EXECUTABLE"
remove_developer_rpaths "$APP_EXECUTABLE"
remove_developer_rpaths "$ENGINE_EXECUTABLE"
assert_portable_macho "$APP_EXECUTABLE"
assert_portable_macho "$ENGINE_EXECUTABLE"

/usr/bin/plutil -lint "$CONTENTS/Info.plist"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode.EngineProbe "$ENGINE_EXECUTABLE"
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode.Probe "$APP"
/usr/bin/codesign --verify --strict "$ENGINE_EXECUTABLE"
/usr/bin/codesign --verify --strict --deep "$APP"

printf 'packaged=%s\n' "$APP"
