#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
readonly EXPECTED_XCODE_VERSION="Xcode 26.6"
readonly EXPECTED_XCODE_BUILD="Build version 17F113"
readonly EXPECTED_SDK_NAME="MacOSX26.5.sdk"
readonly EXPECTED_SWIFT_VERSION="Apple Swift version 6.3.3"
readonly EXPECTED_SWIFT_FORMAT_VERSION="6.3.0"

fail() {
    printf 'toolchain verification failed: %s\n' "$1" >&2
    exit 1
}

[[ "${DEVELOPER_DIR:-}" == "$EXPECTED_DEVELOPER_DIR" ]] || \
    fail "DEVELOPER_DIR must be $EXPECTED_DEVELOPER_DIR"
[[ -d "$DEVELOPER_DIR" && ! -L "$DEVELOPER_DIR" ]] || \
    fail "developer directory is missing or symbolic"

xcode_output="$(/usr/bin/xcodebuild -version)"
xcode_version="$(printf '%s\n' "$xcode_output" | /usr/bin/sed -n '1p')"
xcode_build="$(printf '%s\n' "$xcode_output" | /usr/bin/sed -n '2p')"
[[ "$xcode_version" == "$EXPECTED_XCODE_VERSION" ]] || \
    fail "expected $EXPECTED_XCODE_VERSION, found $xcode_version"
[[ "$xcode_build" == "$EXPECTED_XCODE_BUILD" ]] || \
    fail "expected $EXPECTED_XCODE_BUILD, found $xcode_build"
/usr/bin/xcodebuild -checkFirstLaunchStatus

sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
[[ "$(/usr/bin/basename "$sdk_path")" == "$EXPECTED_SDK_NAME" ]] || \
    fail "expected SDK $EXPECTED_SDK_NAME, found $sdk_path"

swift_output="$(/usr/bin/xcrun swift --version 2>&1)"
/usr/bin/grep -Fq "$EXPECTED_SWIFT_VERSION" <<<"$swift_output" || \
    fail "expected $EXPECTED_SWIFT_VERSION"

swift_format_version="$(/usr/bin/xcrun swift-format --version)"
[[ "$swift_format_version" == "$EXPECTED_SWIFT_FORMAT_VERSION" ]] || \
    fail "expected swift-format $EXPECTED_SWIFT_FORMAT_VERSION, found $swift_format_version"

printf 'toolchain=ok xcode=26.6 build=17F113 sdk=26.5 swift=6.3.3 swift-format=6.3.0\n'
