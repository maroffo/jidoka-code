#!/usr/bin/env bash
set -euo pipefail

readonly DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
readonly BUILD_ROOT="$ROOT/build/w7-ui-flow"
readonly APP="$BUILD_ROOT/Jidoka Code UI Fixture.app"
readonly CONTENTS="$APP/Contents"
readonly EXECUTABLE="$CONTENTS/MacOS/Jidoka Code UI Fixture"
readonly EVIDENCE="$BUILD_ROOT/evidence"
readonly FIXTURE_HOME="$BUILD_ROOT/home"
readonly FIXTURE_TMP="$BUILD_ROOT/tmp"
readonly STDOUT_LOG="$BUILD_ROOT/ui-flow.stdout.log"
readonly STDERR_LOG="$BUILD_ROOT/ui-flow.stderr.log"
readonly REPORT="$EVIDENCE/ui-flow-report.json"
readonly SANDBOX_PROFILE="$BUILD_ROOT/ui-fixture.sb"
JIDOKA_RELEASE_RUNTIME_ROOT="${JIDOKA_RELEASE_RUNTIME_ROOT:-$ROOT/build/runtime-input/qualified-runtime}"
readonly JIDOKA_RELEASE_RUNTIME_ROOT
export JIDOKA_RELEASE_RUNTIME_ROOT
NODE="$("$ROOT/scripts/qualified-runtime-node.sh")"
readonly NODE

fail() {
    printf 'S10 UI fixture failed: %s\n' "$1" >&2
    exit 1
}

[[ -x "$NODE" && ! -L "$NODE" ]] || fail "exact Node verifier is unavailable"
"$ROOT/scripts/verify-toolchain.sh"

case "$BUILD_ROOT" in
    "$ROOT/build/"*) ;;
    *) fail "build root escapes repository" ;;
esac
if [[ -e "$BUILD_ROOT" || -L "$BUILD_ROOT" ]]; then
    [[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] || fail "unsafe prior build root"
    /bin/rm -rf -- "$BUILD_ROOT"
fi
/bin/mkdir -p "$CONTENTS/MacOS" "$EVIDENCE" "$FIXTURE_HOME" "$FIXTURE_TMP"
/bin/chmod 0700 "$BUILD_ROOT" "$EVIDENCE" "$FIXTURE_HOME" "$FIXTURE_TMP"

cd "$ROOT"
/usr/bin/xcrun swift build --configuration release --product JidokaCodeUIFixture
BIN_DIR="$(/usr/bin/xcrun swift build --configuration release --show-bin-path)"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
readonly BIN_DIR
case "$BIN_DIR" in
    "$ROOT/.build/"*) ;;
    *) fail "SwiftPM binary directory escapes .build" ;;
esac
readonly SOURCE_EXECUTABLE="$BIN_DIR/JidokaCodeUIFixture"
[[ -f "$SOURCE_EXECUTABLE" && -x "$SOURCE_EXECUTABLE" && ! -L "$SOURCE_EXECUTABLE" ]] || \
    fail "UI fixture product is missing"
/usr/bin/install -m 0755 "$SOURCE_EXECUTABLE" "$EXECUTABLE"

/bin/cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Jidoka Code UI Fixture</string>
    <key>CFBundleIdentifier</key>
    <string>com.maroffo.JidokaCode.UIFixture</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Jidoka Code UI Fixture</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
/bin/chmod 0644 "$CONTENTS/Info.plist"
/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - --identifier com.maroffo.JidokaCode.UIFixture "$APP"
/usr/bin/codesign --verify --strict --deep "$APP"

/bin/cat > "$SANDBOX_PROFILE" <<'SANDBOX'
(version 1)
(allow default)
(deny network*)
SANDBOX
/bin/chmod 0600 "$SANDBOX_PROFILE"

(
    cd /
    /usr/bin/sandbox-exec -f "$SANDBOX_PROFILE" /usr/bin/env -i \
        HOME="$FIXTURE_HOME" \
        TMPDIR="$FIXTURE_TMP" \
        PATH="/usr/bin:/bin" \
        LANG="en_US.UTF-8" \
        "$EXECUTABLE" --output "$EVIDENCE"
) >"$STDOUT_LOG" 2>"$STDERR_LOG"

[[ -f "$REPORT" && ! -L "$REPORT" ]] || fail "UI flow report is missing"
[[ ! -s "$STDOUT_LOG" ]] || fail "UI fixture wrote unexpected stdout"
[[ ! -s "$STDERR_LOG" ]] || fail "UI fixture wrote unexpected stderr"
for screenshot in \
    onboarding-first-run.png \
    settings-accessibility-type.png \
    settings-catalog-unavailable.png \
    menu-warning.png
do
    path="$EVIDENCE/$screenshot"
    [[ -f "$path" && ! -L "$path" && -s "$path" ]] || fail "missing screenshot: $screenshot"
    /usr/bin/sips -g pixelWidth -g pixelHeight "$path" >/dev/null
    mode="$(/usr/bin/stat -f '%Lp' "$path")"
    [[ "$mode" == "600" ]] || fail "screenshot permissions are not 0600: $screenshot"
done

"$NODE" - "$REPORT" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const reportPath = process.argv[2];
const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
assert(report.schemaVersion === 1, 'unexpected report schema');
for (const name of [
  'invalidCredentialRejected',
  'invalidRepositoryRejected',
  'tokenFieldCleared',
  'catalogFailureInline',
  'catalogFailureModalSuppressed',
  'pausePreservedInFlight',
  'quitCheckpointed',
]) assert(report[name] === true, `${name} was not proved`);
assert(report.catalogFailureRefreshCount === 1, 'automatic catalog refresh count differs');
assert(report.ambiguousLateRecheckCount === 1, 'late recheck count differs');
assert(report.ambiguousAuthorizationCount === 1, 'authorization count differs');
for (const name of ['keychainCalls', 'networkCalls', 'piProviderCalls', 'serviceManagementCalls']) {
  assert(report[name] === 0, `${name} was nonzero`);
}
for (const command of [
  'refreshModelCatalog',
  'replaceCredential',
  'addRepository',
  'setLoginEnabled',
  'completeOnboarding',
  'setPaused',
  'recheckAmbiguousMutation',
  'authorizeRetry',
  'prepareForQuit',
]) assert(report.commandKinds.includes(command), `missing command ${command}`);
assert(report.screenshots.length === 4, 'unexpected screenshot count');
for (const screenshot of report.screenshots) {
  assert(/^[0-9a-f]{64}$/.test(screenshot.sha256), 'invalid screenshot digest');
  const png = fs.readFileSync(path.join(path.dirname(reportPath), screenshot.filename));
  assert(png.subarray(1, 4).toString('ascii') === 'PNG', 'invalid screenshot format');
  assert(png.length > 10000, 'screenshot is unexpectedly blank or truncated');
  assert(png.readUInt32BE(16) === screenshot.width, 'reported screenshot width differs');
  assert(png.readUInt32BE(20) === screenshot.height, 'reported screenshot height differs');
  assert(
    crypto.createHash('sha256').update(png).digest('hex') === screenshot.sha256,
    'reported screenshot digest differs'
  );
  assert(screenshot.width >= 500 && screenshot.height >= 600, 'screenshot is undersized');
  assert(
    screenshot.declaredAccessibilityIdentifiers.length > 0,
    'declared accessibility identifiers are absent'
  );
  assert(
    screenshot.declaredAccessibilityLabels.length > 0,
    'declared accessibility labels are absent'
  );
}
const identifiers = new Set(
  report.screenshots.flatMap((screenshot) => screenshot.declaredAccessibilityIdentifiers)
);
for (const identifier of [
  'jidoka.onboarding.window',
  'jidoka.onboarding.token',
  'jidoka.onboarding.complete',
  'jidoka.settings.window',
  'jidoka.settings.repository-reference',
  'jidoka.settings.repository-add',
  'jidoka.rollout.input',
  'jidoka.rollout.preview',
  'jidoka.settings.model-catalog-refresh',
  'jidoka.settings.model-catalog-notice',
  'jidoka.settings.model-selector.review',
  'jidoka.settings.custom-model.review',
  'jidoka.settings.credential-connect',
  'jidoka.settings.credential-deletion',
  'jidoka.menu.status',
  'jidoka.menu.poll-now',
  'jidoka.menu.rollout-stop',
  'jidoka.menu.rollout-recovery',
  'jidoka.menu.quit',
  'jidoka.ambiguous.recheck',
  'jidoka.ambiguous.authorize',
]) assert(identifiers.has(identifier), `missing accessibility contract ${identifier}`);
assert(
  !identifiers.has('jidoka.menu.pause-resume'),
  'legacy unscoped Resume accessibility contract remains exposed'
);
const serialized = JSON.stringify(report);
assert(!serialized.includes('/Users/'), 'report contains a user path');
assert(!serialized.includes('Authorization:'), 'report contains an authorization header');
NODE

if /usr/bin/grep -R -a -q 'github_pat_ui_fixture_secret' \
    "$EVIDENCE" "$FIXTURE_HOME" "$FIXTURE_TMP" "$STDOUT_LOG" "$STDERR_LOG"
then
    fail "secret sentinel reached a rendered or persisted sink"
fi
if /usr/bin/grep -R -a -q -E 'Authorization:|Bearer [A-Za-z0-9._-]{10,}' \
    "$EVIDENCE" "$FIXTURE_HOME" "$FIXTURE_TMP" "$STDOUT_LOG" "$STDERR_LOG"
then
    fail "credential-shaped output reached a rendered or persisted sink"
fi

printf 'ui_fixture_bundle=%s\n' "$APP"
printf 'ui_flow_report=%s\n' "$REPORT"
for screenshot in \
    onboarding-first-run.png \
    settings-accessibility-type.png \
    settings-catalog-unavailable.png \
    menu-warning.png
do
    printf 'ui_screenshot_sha256=%s %s\n' \
        "$(/usr/bin/shasum -a 256 "$EVIDENCE/$screenshot" | /usr/bin/awk '{print $1}')" \
        "$screenshot"
done
printf 'accessibility_evidence=declared-production-contract-plus-rendered-screenshots\n'
printf 'runtime_ax_identifiers=unavailable-in-offscreen-hosting-fixture\n'
printf 'network_boundary=sandbox-deny-network\n'
printf 'side_effects=keychain:0,network:0,provider:0,service_management:0\n'
