#!/bin/bash
# ABOUTME: Read-only production-readiness preflight for the 0.1.1 cutover (plan W5, decision 21).
# ABOUTME: Audits package, receipt, bundle destination, database, Herdr and Git facts against a
# source-controlled expected-values artifact and writes evidence only into a private directory.
#
# Side-effect contract:
#   - Never mutates the production database, receipts, Keychain, sockets, processes or filesystem.
#   - SQLite is opened with -readonly plus PRAGMA query_only=ON; main-db and WAL bytes are hashed
#     before and after the query batch, and any change aborts with the guard exit code. SQLite may
#     touch the transient -shm coordination file even for read-only connections; the -shm file
#     carries no database content and is excluded from the guard.
#   - Never opens, connects to, or writes any socket. The Herdr production socket is out of scope;
#     live socket probing belongs exclusively to the separately authorized checkpoint D/F
#     `--herdr-readiness-probe` step in docs/operations/production-cutover-0.1.1.md.
#   - Never contacts the network and never invokes network-capable tools.
#   - Writes only beneath the explicit --evidence-dir (created 0700, files 0600).
#   - Every tool is invoked by absolute path; PATH is replaced with a fixed system value and no
#     inherited environment value is trusted. cwd is irrelevant: all paths are absolute.
#
# Closed exit codes:
#   0   pass
#   64  usage error
#   65  expected-values or cutover-values artifact missing/invalid
#   66  prerequisite missing (tool or required file/dir unavailable)
#   67  drift (observed value differs from expected value)
#   68  timeout (per-tool bound or overall deadline)
#   69  read-only guard tripped (database bytes changed while auditing)

set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C

readonly EXIT_USAGE=64
readonly EXIT_EXPECTED=65
readonly EXIT_PREREQ=66
readonly EXIT_DRIFT=67
readonly EXIT_TIMEOUT=68
readonly EXIT_GUARD=69

readonly TOOL_SQLITE3=/usr/bin/sqlite3
readonly TOOL_SHASUM=/usr/bin/shasum
readonly TOOL_PLUTIL=/usr/bin/plutil
readonly TOOL_STAT=/usr/bin/stat
readonly TOOL_LS=/bin/ls
readonly TOOL_READLINK=/usr/bin/readlink
readonly TOOL_PERL=/usr/bin/perl
readonly TOOL_DATE=/bin/date
readonly TOOL_MKDIR=/bin/mkdir
readonly TOOL_CHMOD=/bin/chmod
readonly TOOL_SW_VERS=/usr/bin/sw_vers
readonly TOOL_PGREP=/usr/bin/pgrep
readonly TOOL_LSOF=/usr/sbin/lsof
readonly TOOL_WC=/usr/bin/wc
readonly TOOL_TR=/usr/bin/tr
readonly TOOL_FIND=/usr/bin/find
readonly TOOL_SORT=/usr/bin/sort
readonly TOOL_CMP=/usr/bin/cmp
readonly TOOL_CODESIGN=/usr/bin/codesign

readonly PRODUCTION_PACKAGE_IDENTIFIER="com.maroffo.JidokaCode.pkg"
readonly PRODUCTION_BUNDLE_IDENTIFIER="com.maroffo.JidokaCode"
readonly PRODUCTION_HELPER_IDENTIFIER="com.maroffo.JidokaCode.Engine"
readonly PRODUCTION_SECURE_ROOT="/Library/Application Support/JidokaCode"

STAGE=""
EXPECTED=""
EVIDENCE_DIR=""
CUTOVER_VALUES=""
REQUIRE_QUIESCED=0
EVIDENCE_LOG=""
TOOL_TIMEOUT=30
OVERALL_DEADLINE=600
CHECK_COUNT=0

usage_fail() {
    printf 'production-readiness-preflight: %s\n' "$1" >&2
    printf 'usage: production-readiness-preflight.sh --stage static|cutover-pre|cutover-post-install --expected <abs-json> --evidence-dir <abs-dir> [--cutover-values <abs-env>] [--require-quiesced]\n' >&2
    exit "$EXIT_USAGE"
}

fail() {
    local code="$1" message="$2"
    if [[ -n "$EVIDENCE_LOG" && -w "$EVIDENCE_LOG" ]]; then
        printf 'RESULT FAIL exit=%s reason=%s\n' "$code" "$message" >> "$EVIDENCE_LOG"
    fi
    printf 'production-readiness-preflight: FAIL exit=%s %s\n' "$code" "$message" >&2
    exit "$code"
}

log() {
    printf '%s\n' "$1" >> "$EVIDENCE_LOG"
}

deadline_guard() {
    if (( SECONDS > OVERALL_DEADLINE )); then
        fail "$EXIT_TIMEOUT" "overall deadline exceeded (${OVERALL_DEADLINE}s)"
    fi
}

# Runs one tool under a hard alarm. SIGALRM terminates the exec'd tool, surfacing exit 142.
bounded() {
    local rc=0
    # The perl program below must not undergo shell expansion.
    # shellcheck disable=SC2016
    "$TOOL_PERL" -e 'my $t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV; exit 127;' \
        "$TOOL_TIMEOUT" "$@" || rc=$?
    if (( rc == 142 )); then
        fail "$EXIT_TIMEOUT" "tool timeout (${TOOL_TIMEOUT}s): $1"
    fi
    return "$rc"
}

check() {
    local name="$1" expected="$2" observed="$3"
    CHECK_COUNT=$((CHECK_COUNT + 1))
    deadline_guard
    if [[ "$observed" == "$expected" ]]; then
        log "CHECK $name PASS value=$observed"
    else
        log "CHECK $name FAIL expected=$expected observed=$observed"
        fail "$EXIT_DRIFT" "$name drift: expected=$expected observed=$observed"
    fi
}

record() {
    local name="$1" value="$2"
    log "RECORD $name $value"
}

expected_raw() {
    local keypath="$1" value rc=0
    value="$(bounded "$TOOL_PLUTIL" -extract "$keypath" raw -o - "$EXPECTED" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        fail "$EXIT_EXPECTED" "expected-values artifact is missing key: $keypath"
    fi
    printf '%s' "$value"
}

expected_raw_optional() {
    bounded "$TOOL_PLUTIL" -extract "$1" raw -o - "$EXPECTED" 2>/dev/null || printf ''
}

sha256_of() {
    local path="$1" out rc=0
    out="$(bounded "$TOOL_SHASUM" -a 256 "$path")" || rc=$?
    if (( rc >= 64 && rc <= 69 )); then
        # bounded already reported a closed code (e.g. timeout) from its subshell;
        # propagate it instead of remapping to a prerequisite failure.
        exit "$rc"
    fi
    if (( rc != 0 )); then
        fail "$EXIT_PREREQ" "cannot hash $path"
    fi
    printf '%s' "${out%% *}"
}

stat_owner() {
    bounded "$TOOL_STAT" -f '%u:%g' "$1"
}

stat_mode() {
    bounded "$TOOL_STAT" -f '%p' "$1"
}

acl_line_count() {
    local lines
    lines="$(bounded "$TOOL_LS" -lde "$1" | "$TOOL_WC" -l)"
    printf '%s' "$((lines))"
}

codesign_value() {
    bounded "$TOOL_CODESIGN" -d --verbose=4 "$1" 2>&1 | \
        /usr/bin/awk -F= -v key="$2" '
            $1 == key && !found { value = $2; found = 1 }
            END { if (found) print value; else exit 1 }
        '
}

lowercased() {
    printf '%s' "$1" | "$TOOL_TR" '[:upper:]' '[:lower:]'
}

path_is_at_or_below() {
    local candidate root
    candidate="$(lowercased "$1")"
    root="$(lowercased "$2")"
    [[ "$candidate" == "$root" || "$candidate" == "$root/"* ]]
}

# Rejects path forms that name the same object as another literal on a
# case-insensitive filesystem (CWE-41/CWE-178): duplicate slashes, dot and
# dot-dot segments, trailing slashes.
assert_canonical_path() {
    local value="$1" label="$2"
    case "$value" in
        *//*|*/./*|*/../*|*/.|*/..|*/)
            fail "$EXIT_EXPECTED" "$label is not a canonical path: $value" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage)
            [[ $# -ge 2 ]] || usage_fail "--stage requires a value"
            STAGE="$2"; shift 2 ;;
        --expected)
            [[ $# -ge 2 ]] || usage_fail "--expected requires a value"
            EXPECTED="$2"; shift 2 ;;
        --evidence-dir)
            [[ $# -ge 2 ]] || usage_fail "--evidence-dir requires a value"
            EVIDENCE_DIR="$2"; shift 2 ;;
        --cutover-values)
            [[ $# -ge 2 ]] || usage_fail "--cutover-values requires a value"
            CUTOVER_VALUES="$2"; shift 2 ;;
        --require-quiesced)
            REQUIRE_QUIESCED=1; shift ;;
        *)
            usage_fail "unknown argument: $1" ;;
    esac
done

case "$STAGE" in
    static|cutover-pre|cutover-post-install) ;;
    "") usage_fail "--stage is required" ;;
    *) usage_fail "unknown stage: $STAGE" ;;
esac
[[ -n "$EXPECTED" ]] || usage_fail "--expected is required"
[[ "$EXPECTED" == /* ]] || usage_fail "--expected must be an absolute path"
[[ -n "$EVIDENCE_DIR" ]] || usage_fail "--evidence-dir is required"
[[ "$EVIDENCE_DIR" == /* ]] || usage_fail "--evidence-dir must be an absolute path"
if [[ -n "$CUTOVER_VALUES" && "$CUTOVER_VALUES" != /* ]]; then
    usage_fail "--cutover-values must be an absolute path"
fi
if [[ "$STAGE" == "cutover-post-install" && -z "$CUTOVER_VALUES" ]]; then
    usage_fail "stage cutover-post-install requires --cutover-values"
fi
case "$EVIDENCE_DIR" in
    *//*|*/./*|*/../*|*/.|*/..|/)
        usage_fail "--evidence-dir must be one canonical non-root path" ;;
esac

for tool in "$TOOL_SQLITE3" "$TOOL_SHASUM" "$TOOL_PLUTIL" "$TOOL_STAT" \
    "$TOOL_LS" "$TOOL_READLINK" "$TOOL_PERL" "$TOOL_DATE" "$TOOL_MKDIR" "$TOOL_CHMOD" \
    "$TOOL_SW_VERS" "$TOOL_PGREP" "$TOOL_LSOF" "$TOOL_WC" "$TOOL_TR" \
    "$TOOL_FIND" "$TOOL_SORT" "$TOOL_CMP" "$TOOL_CODESIGN"; do
    if [[ ! -x "$tool" ]]; then
        printf 'production-readiness-preflight: missing tool %s\n' "$tool" >&2
        exit "$EXIT_PREREQ"
    fi
done

if [[ ! -f "$EXPECTED" ]]; then
    printf 'production-readiness-preflight: expected-values artifact not found: %s\n' "$EXPECTED" >&2
    exit "$EXIT_EXPECTED"
fi

# Validate one existing parent before creating exactly one evidence leaf. This
# refuses symlink traversal and protected-root writes before any mkdir effect.
PRE_DB_PATH="$(bounded "$TOOL_PLUTIL" -extract database.path raw -o - "$EXPECTED" 2>/dev/null)" || PRE_DB_PATH=""
EVIDENCE_PARENT="${EVIDENCE_DIR%/*}"
EVIDENCE_LEAF="${EVIDENCE_DIR##*/}"
[[ -n "$EVIDENCE_PARENT" && -n "$EVIDENCE_LEAF" && -d "$EVIDENCE_PARENT" && \
    ! -L "$EVIDENCE_PARENT" ]] || usage_fail "--evidence-dir parent must be an existing directory"
RESOLVED_EVIDENCE_PARENT="$(bounded "$TOOL_READLINK" -f "$EVIDENCE_PARENT")" || \
    exit "$EXIT_PREREQ"
[[ "$RESOLVED_EVIDENCE_PARENT" == "$EVIDENCE_PARENT" ]] || \
    usage_fail "--evidence-dir parent must contain no symbolic-link component"
if path_is_at_or_below "$RESOLVED_EVIDENCE_PARENT" "$PRODUCTION_SECURE_ROOT"; then
    usage_fail "--evidence-dir must not be inside the production secure root"
fi
if [[ -n "$PRE_DB_PATH" ]] && \
    path_is_at_or_below "$RESOLVED_EVIDENCE_PARENT" "${PRE_DB_PATH%/*}"; then
    usage_fail "--evidence-dir must not be inside the production database directory"
fi
EVIDENCE_PARENT_OWNER="$(bounded "$TOOL_STAT" -f '%u' "$EVIDENCE_PARENT")" || \
    exit "$EXIT_PREREQ"
EVIDENCE_PARENT_MODE="$(bounded "$TOOL_STAT" -f '%Lp' "$EVIDENCE_PARENT")" || \
    exit "$EXIT_PREREQ"
[[ "$EVIDENCE_PARENT_OWNER" == "$EUID" ]] || \
    usage_fail "--evidence-dir parent is not owned by the invoking user"
(( (8#$EVIDENCE_PARENT_MODE & 8#22) == 0 )) || \
    usage_fail "--evidence-dir parent is group- or world-writable"
[[ "$(acl_line_count "$EVIDENCE_PARENT")" == "1" ]] || \
    usage_fail "--evidence-dir parent carries an ACL"
if [[ -e "$EVIDENCE_DIR" || -L "$EVIDENCE_DIR" ]]; then
    [[ -d "$EVIDENCE_DIR" && ! -L "$EVIDENCE_DIR" ]] || \
        usage_fail "--evidence-dir must be a directory, not a symbolic link"
else
    "$TOOL_MKDIR" "$EVIDENCE_DIR" || exit "$EXIT_PREREQ"
fi
RESOLVED_EVIDENCE_DIR="$(bounded "$TOOL_READLINK" -f "$EVIDENCE_DIR")" || exit "$EXIT_PREREQ"
[[ "$RESOLVED_EVIDENCE_DIR" == "$EVIDENCE_DIR" ]] || \
    usage_fail "--evidence-dir must contain no symbolic-link component"
if path_is_at_or_below "$RESOLVED_EVIDENCE_DIR" "$PRODUCTION_SECURE_ROOT"; then
    usage_fail "--evidence-dir resolves into the production secure root"
fi
if [[ -n "$PRE_DB_PATH" ]] && \
    path_is_at_or_below "$RESOLVED_EVIDENCE_DIR" "${PRE_DB_PATH%/*}"; then
    usage_fail "--evidence-dir resolves into the production database directory"
fi
EVIDENCE_OWNER="$(bounded "$TOOL_STAT" -f '%u' "$EVIDENCE_DIR")" || exit "$EXIT_PREREQ"
[[ "$EVIDENCE_OWNER" == "$EUID" ]] || \
    usage_fail "--evidence-dir is not owned by the invoking user"
"$TOOL_CHMOD" 700 "$EVIDENCE_DIR" || exit "$EXIT_PREREQ"
RUN_STAMP="$("$TOOL_DATE" -u '+%Y%m%dT%H%M%SZ')"
EVIDENCE_LOG="$EVIDENCE_DIR/preflight-$STAGE-$RUN_STAMP.log"
: > "$EVIDENCE_LOG"
"$TOOL_CHMOD" 600 "$EVIDENCE_LOG"

log "PREFLIGHT stage=$STAGE expected=$EXPECTED started=$RUN_STAMP"
log "CONTRACT read-only: no database/receipt/keychain/socket/process/filesystem mutation; evidence only"

MODE="$(expected_raw mode)"
case "$MODE" in
    production|uat-probe) ;;
    *) fail "$EXIT_EXPECTED" "expected-values mode must be production or uat-probe, got: $MODE" ;;
esac
log "MODE $MODE"

TOOL_TIMEOUT="$(expected_raw toolTimeoutSeconds)"
if ! [[ "$TOOL_TIMEOUT" =~ ^[0-9]+$ && "$TOOL_TIMEOUT" -ge 1 ]]; then
    fail "$EXIT_EXPECTED" "toolTimeoutSeconds must be a positive integer"
fi
OVERALL_DEADLINE="$(expected_raw overallDeadlineSeconds)"
if ! [[ "$OVERALL_DEADLINE" =~ ^[0-9]+$ && "$OVERALL_DEADLINE" -ge 1 ]]; then
    fail "$EXIT_EXPECTED" "overallDeadlineSeconds must be a positive integer"
fi

PACKAGE_IDENTIFIER="$(expected_raw package.identifier)"
RECEIPT_VOLUME="$(expected_raw package.receiptVolume)"
STATIC_RECEIPT_STATE="$(expected_raw package.staticReceiptState)"
case "$STATIC_RECEIPT_STATE" in
    legacy|absent) ;;
    *) fail "$EXIT_EXPECTED" "package.staticReceiptState must be legacy or absent" ;;
esac
if [[ "$MODE" == "production" && "$STATIC_RECEIPT_STATE" != "legacy" ]]; then
    fail "$EXIT_EXPECTED" "production mode requires package.staticReceiptState=legacy"
fi
BUNDLE_IDENTIFIER="$(expected_raw bundle.identifier)"
SECURE_PATH="$(expected_raw bundle.securePath)"
SECURE_ROOT="$(expected_raw bundle.secureRoot)"
LEGACY_APP_PATH="$(expected_raw bundle.legacyAppPath)"

if [[ "$MODE" == "uat-probe" ]]; then
    if (( REQUIRE_QUIESCED )); then
        fail "$EXIT_USAGE" "--require-quiesced applies only to production mode"
    fi
    # Containment: a UAT probe artifact must never name production authority.
    # Comparisons are case-folded and paths canonicality-checked, because APFS is
    # case-insensitive and path equivalence would otherwise defeat the guard.
    assert_canonical_path "$SECURE_ROOT" "bundle.secureRoot"
    assert_canonical_path "$SECURE_PATH" "bundle.securePath"
    if [[ "$(lowercased "$PACKAGE_IDENTIFIER")" == "$(lowercased "$PRODUCTION_PACKAGE_IDENTIFIER")" ]]; then
        fail "$EXIT_EXPECTED" "uat-probe artifact names the production package identifier"
    fi
    if [[ "$(lowercased "$BUNDLE_IDENTIFIER")" == "$(lowercased "$PRODUCTION_BUNDLE_IDENTIFIER")" ]]; then
        fail "$EXIT_EXPECTED" "uat-probe artifact names the production bundle identifier"
    fi
    UAT_HELPER_IDENTIFIER="$(expected_raw bundle.helperIdentifier)"
    UAT_TEAM_IDENTIFIER="$(expected_raw bundle.teamIdentifier)"
    UAT_APPLICATION_IDENTITY="$(expected_raw bundle.applicationSigningIdentitySHA1)"
    UAT_MAIN_EXECUTABLE="$(expected_raw bundle.mainExecutableName)"
    UAT_HELPER_EXECUTABLE="$(expected_raw bundle.helperExecutableName)"
    UAT_LAUNCH_AGENT_PLIST="$(expected_raw bundle.launchAgentPlistName)"
    if [[ "$(lowercased "$UAT_HELPER_IDENTIFIER")" == \
        "$(lowercased "$PRODUCTION_HELPER_IDENTIFIER")" ]]; then
        fail "$EXIT_EXPECTED" "uat-probe artifact names the production helper identifier"
    fi
    [[ -n "$UAT_HELPER_IDENTIFIER" && "$UAT_MAIN_EXECUTABLE" != */* && \
        "$UAT_HELPER_EXECUTABLE" != */* && "$UAT_LAUNCH_AGENT_PLIST" != */* ]] || \
        fail "$EXIT_EXPECTED" "uat-probe payload identity is invalid"
    if [[ "$UAT_TEAM_IDENTIFIER" == "not set" ]]; then
        [[ -z "$UAT_APPLICATION_IDENTITY" ]] || \
            fail "$EXIT_EXPECTED" "ad-hoc uat-probe cannot name an Application identity"
    else
        [[ "$UAT_TEAM_IDENTIFIER" =~ ^[A-Z0-9]{10}$ && \
            "$UAT_APPLICATION_IDENTITY" =~ ^[0-9A-F]{40}$ ]] || \
            fail "$EXIT_EXPECTED" "uat-probe signing identity is invalid"
    fi
    LOWER_SECURE_ROOT="$(lowercased "$SECURE_ROOT")"
    LOWER_SECURE_PATH="$(lowercased "$SECURE_PATH")"
    LOWER_PRODUCTION_ROOT="$(lowercased "$PRODUCTION_SECURE_ROOT")"
    if [[ "$LOWER_SECURE_ROOT" == "$LOWER_PRODUCTION_ROOT" || \
        "$LOWER_SECURE_ROOT" == "$LOWER_PRODUCTION_ROOT/"* || \
        "$LOWER_SECURE_PATH" == "$LOWER_PRODUCTION_ROOT" || \
        "$LOWER_SECURE_PATH" == "$LOWER_PRODUCTION_ROOT/"* ]]
    then
        fail "$EXIT_EXPECTED" "uat-probe artifact targets the production secure root"
    fi
    UAT_DATABASE_PATH="$(expected_raw_optional database.path)"
    if [[ -n "$UAT_DATABASE_PATH" ]]; then
        fail "$EXIT_EXPECTED" "uat-probe artifact must not declare a database section"
    fi
fi

# --- Host prerequisites -----------------------------------------------------

OS_EXPECTED="$(expected_raw osProductVersion)"
OS_OBSERVED="$(bounded "$TOOL_SW_VERS" -productVersion)"
check "os.productVersion" "$OS_EXPECTED" "$OS_OBSERVED"

# --- Runtime: Herdr ---------------------------------------------------------

HERDR_LINK="$(expected_raw herdr.linkPath)"
HERDR_RESOLVED_EXPECTED="$(expected_raw herdr.resolvedPath)"
HERDR_SHA_EXPECTED="$(expected_raw herdr.executableSHA256)"
if [[ ! -e "$HERDR_LINK" ]]; then
    fail "$EXIT_PREREQ" "herdr link path missing: $HERDR_LINK"
fi
HERDR_RESOLVED="$(bounded "$TOOL_READLINK" -f "$HERDR_LINK")"
check "herdr.resolvedPath" "$HERDR_RESOLVED_EXPECTED" "$HERDR_RESOLVED"
HERDR_SHA_OBSERVED="$(sha256_of "$HERDR_RESOLVED")"
check "herdr.executableSHA256" "$HERDR_SHA_EXPECTED" "$HERDR_SHA_OBSERVED"
HERDR_VERSION_EXPECTED="$(expected_raw herdr.version)"
record "herdr.version.expected" "$HERDR_VERSION_EXPECTED"
HERDR_PROTOCOL_EXPECTED="$(expected_raw herdr.protocolVersion)"
record "herdr.protocolVersion.expected" "$HERDR_PROTOCOL_EXPECTED"

# --- Runtime: Git -----------------------------------------------------------

GIT_PATH="$(expected_raw git.path)"
GIT_SHA_EXPECTED="$(expected_raw git.sha256)"
GIT_BACKEND_PATH="$(expected_raw git.backendPath)"
GIT_BACKEND_SHA_EXPECTED="$(expected_raw git.backendSHA256)"
if [[ ! -f "$GIT_PATH" ]]; then
    fail "$EXIT_PREREQ" "git path missing: $GIT_PATH"
fi
GIT_SHA_OBSERVED="$(sha256_of "$GIT_PATH")"
check "git.sha256" "$GIT_SHA_EXPECTED" "$GIT_SHA_OBSERVED"
if [[ ! -f "$GIT_BACKEND_PATH" ]]; then
    fail "$EXIT_PREREQ" "git backend missing: $GIT_BACKEND_PATH"
fi
GIT_BACKEND_SHA_OBSERVED="$(sha256_of "$GIT_BACKEND_PATH")"
check "git.backendSHA256" "$GIT_BACKEND_SHA_EXPECTED" "$GIT_BACKEND_SHA_OBSERVED"

# --- Package and receipt ----------------------------------------------------

receipt_plist_path() {
    local volume_prefix="$RECEIPT_VOLUME"
    [[ "$volume_prefix" == "/" ]] && volume_prefix=""
    printf '%s' "$volume_prefix/var/db/receipts/$PACKAGE_IDENTIFIER.plist"
}

read_receipt() {
    # Prints "version<TAB>install-location" for the identifier, or fails when absent.
    # Reads the flat PackageKit receipt plist directly: the store location and key names
    # (PackageVersion, InstallPrefixPath) match what `pkgutil --pkg-info` reports for the
    # production receipt, and a direct read stays deterministic on fixture volumes, where
    # `pkgutil --volume` does not resolve fabricated receipts. The runbook keeps pkgutil
    # confirmation commands as independent checkpoint evidence.
    local receipt_plist version location
    receipt_plist="$(receipt_plist_path)"
    [[ -f "$receipt_plist" && ! -L "$receipt_plist" ]] || return 1
    version="$(bounded "$TOOL_PLUTIL" -extract PackageVersion raw -o - "$receipt_plist")" || return 1
    location="$(bounded "$TOOL_PLUTIL" -extract InstallPrefixPath raw -o - "$receipt_plist")" || return 1
    printf '%s\t%s' "$version" "$location"
}

if [[ "$STAGE" == "static" && "$STATIC_RECEIPT_STATE" == "absent" ]]; then
    RECEIPT_PLIST="$(receipt_plist_path)"
    if [[ -e "$RECEIPT_PLIST" || -L "$RECEIPT_PLIST" ]]; then
        fail "$EXIT_DRIFT" "PackageKit receipt unexpectedly exists for $PACKAGE_IDENTIFIER on volume $RECEIPT_VOLUME"
    fi
    CHECK_COUNT=$((CHECK_COUNT + 1))
    log "CHECK receipt.absent PASS value=$PACKAGE_IDENTIFIER"
else
    RECEIPT_INFO="$(read_receipt)" || fail "$EXIT_PREREQ" "no PackageKit receipt for $PACKAGE_IDENTIFIER on volume $RECEIPT_VOLUME"
    RECEIPT_VERSION="${RECEIPT_INFO%%$'\t'*}"
    RECEIPT_LOCATION="${RECEIPT_INFO#*$'\t'}"

    if [[ "$STAGE" == "cutover-post-install" ]]; then
        RECEIPT_VERSION_EXPECTED="$(expected_raw package.successorReceiptVersion)"
        RECEIPT_LOCATION_EXPECTED="$(expected_raw package.successorReceiptLocation)"
    else
        RECEIPT_VERSION_EXPECTED="$(expected_raw package.legacyReceiptVersion)"
        RECEIPT_LOCATION_EXPECTED="$(expected_raw package.legacyReceiptLocation)"
    fi
    check "receipt.version" "$RECEIPT_VERSION_EXPECTED" "$RECEIPT_VERSION"
    check "receipt.installLocation" "$RECEIPT_LOCATION_EXPECTED" "$RECEIPT_LOCATION"
fi

if [[ "$STAGE" != "cutover-post-install" ]]; then
    LEGACY_PACKAGE_PATH="$(expected_raw package.legacyPackagePath)"
    LEGACY_PACKAGE_SHA="$(expected_raw package.legacyPackageSHA256)"
    if [[ ! -f "$LEGACY_PACKAGE_PATH" ]]; then
        fail "$EXIT_PREREQ" "legacy package evidence missing: $LEGACY_PACKAGE_PATH"
    fi
    LEGACY_PACKAGE_SHA_OBSERVED="$(sha256_of "$LEGACY_PACKAGE_PATH")"
    check "package.legacySHA256" "$LEGACY_PACKAGE_SHA" "$LEGACY_PACKAGE_SHA_OBSERVED"
fi

# --- Bundle destination -----------------------------------------------------

check_parent() {
    local keypath="$1" path owner mode acl observed_owner observed_mode
    path="$(expected_raw "$keypath.path")"
    owner="$(expected_raw "$keypath.owner")"
    mode="$(expected_raw "$keypath.mode")"
    if [[ ! -d "$path" ]]; then
        fail "$EXIT_DRIFT" "expected directory missing: $path"
    fi
    [[ -L "$path" ]] && fail "$EXIT_DRIFT" "expected directory is a symlink: $path"
    observed_owner="$(stat_owner "$path")"
    check "parent.owner:$path" "$owner" "$observed_owner"
    observed_mode="$(stat_mode "$path")"
    check "parent.mode:$path" "$mode" "$observed_mode"
    acl="$(acl_line_count "$path")"
    check "parent.aclEntries:$path" "1" "$acl"
}

check_parent_list() {
    local listkey="$1" count index
    count="$(expected_raw "$listkey")"
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        fail "$EXIT_EXPECTED" "$listkey must be an array"
    fi
    for (( index = 0; index < count; index++ )); do
        check_parent "$listkey.$index"
    done
}

verify_uat_installed_bundle() {
    local expected_inventory observed_inventory path relative expected_mode payload_owner
    local main helper launch_plist unexpected signature app_team helper_team cert_prefix cert_sha
    expected_inventory="$EVIDENCE_DIR/uat-installed-inventory-expected-$RUN_STAMP.txt"
    observed_inventory="$EVIDENCE_DIR/uat-installed-inventory-observed-$RUN_STAMP.txt"
    {
        printf '%s\n' \
            "." \
            "./Contents" \
            "./Contents/Helpers" \
            "./Contents/Helpers/$UAT_HELPER_EXECUTABLE" \
            "./Contents/Info.plist" \
            "./Contents/Library" \
            "./Contents/Library/LaunchAgents" \
            "./Contents/Library/LaunchAgents/$UAT_LAUNCH_AGENT_PLIST" \
            "./Contents/MacOS" \
            "./Contents/MacOS/$UAT_MAIN_EXECUTABLE" \
            "./Contents/_CodeSignature" \
            "./Contents/_CodeSignature/CodeResources"
    } | "$TOOL_SORT" >"$expected_inventory"
    : >"$observed_inventory"
    while IFS= read -r path; do
        if [[ "$path" == "$SECURE_PATH" ]]; then
            relative="."
        else
            relative=".${path#"$SECURE_PATH"}"
        fi
        printf '%s\n' "$relative" >>"$observed_inventory"
    done < <("$TOOL_FIND" "$SECURE_PATH" -print)
    "$TOOL_SORT" -o "$observed_inventory" "$observed_inventory"
    "$TOOL_CHMOD" 600 "$expected_inventory" "$observed_inventory"
    bounded "$TOOL_CMP" -s "$expected_inventory" "$observed_inventory" || \
        fail "$EXIT_DRIFT" "installed UAT payload inventory differs"
    CHECK_COUNT=$((CHECK_COUNT + 1))
    log "CHECK uatPayload.inventory PASS value=exact"

    unexpected="$("$TOOL_FIND" "$SECURE_PATH" \( -type l -o \( ! -type d ! -type f \) \) -print)"
    [[ -z "$unexpected" ]] || fail "$EXIT_DRIFT" "installed UAT payload contains an unsafe entry"
    payload_owner="$(stat_owner "$SECURE_ROOT")"
    while IFS= read -r path; do
        check "uatPayload.owner:$path" "$payload_owner" "$(stat_owner "$path")"
        check "uatPayload.mode:$path" "40755" "$(stat_mode "$path")"
        check "uatPayload.aclEntries:$path" "1" "$(acl_line_count "$path")"
    done < <("$TOOL_FIND" "$SECURE_PATH" -type d -print)
    while IFS= read -r path; do
        relative=".${path#"$SECURE_PATH"}"
        case "$relative" in
            "./Contents/MacOS/$UAT_MAIN_EXECUTABLE"|\
            "./Contents/Helpers/$UAT_HELPER_EXECUTABLE") expected_mode="100755" ;;
            *) expected_mode="100644" ;;
        esac
        check "uatPayload.owner:$path" "$payload_owner" "$(stat_owner "$path")"
        check "uatPayload.mode:$path" "$expected_mode" "$(stat_mode "$path")"
        check "uatPayload.linkCount:$path" "1" "$(bounded "$TOOL_STAT" -f '%l' "$path")"
        check "uatPayload.aclEntries:$path" "1" "$(acl_line_count "$path")"
    done < <("$TOOL_FIND" "$SECURE_PATH" -type f -print)

    main="$SECURE_PATH/Contents/MacOS/$UAT_MAIN_EXECUTABLE"
    helper="$SECURE_PATH/Contents/Helpers/$UAT_HELPER_EXECUTABLE"
    launch_plist="$SECURE_PATH/Contents/Library/LaunchAgents/$UAT_LAUNCH_AGENT_PLIST"
    bounded "$TOOL_CODESIGN" --verify --strict --deep "$SECURE_PATH" || \
        fail "$EXIT_DRIFT" "installed UAT application signature is invalid"
    check "uatSignature.appIdentifier" "$BUNDLE_IDENTIFIER" \
        "$(codesign_value "$SECURE_PATH" Identifier)"
    check "uatSignature.mainIdentifier" "$BUNDLE_IDENTIFIER" \
        "$(codesign_value "$main" Identifier)"
    check "uatSignature.helperIdentifier" "$UAT_HELPER_IDENTIFIER" \
        "$(codesign_value "$helper" Identifier)"
    app_team="$(codesign_value "$SECURE_PATH" TeamIdentifier)"
    helper_team="$(codesign_value "$helper" TeamIdentifier)"
    check "uatSignature.appTeam" "$UAT_TEAM_IDENTIFIER" "$app_team"
    check "uatSignature.helperTeam" "$UAT_TEAM_IDENTIFIER" "$helper_team"
    check "uatLaunchAgent.label" "$UAT_HELPER_IDENTIFIER" \
        "$(bounded "$TOOL_PLUTIL" -extract Label raw -o - "$launch_plist")"
    check "uatLaunchAgent.bundleProgram" "Contents/Helpers/$UAT_HELPER_EXECUTABLE" \
        "$(bounded "$TOOL_PLUTIL" -extract BundleProgram raw -o - "$launch_plist")"
    if [[ "$UAT_TEAM_IDENTIFIER" != "not set" ]]; then
        signature="$(bounded "$TOOL_CODESIGN" -d --verbose=4 "$SECURE_PATH" 2>&1)"
        [[ "$signature" == *"Authority=Developer ID Application:"* && \
            "$signature" == *"Timestamp="* ]] || \
            fail "$EXIT_DRIFT" "installed UAT application lacks a Developer ID timestamp"
        signature="$(bounded "$TOOL_CODESIGN" -d --verbose=4 "$helper" 2>&1)"
        [[ "$signature" == *"Authority=Developer ID Application:"* && \
            "$signature" == *"Timestamp="* ]] || \
            fail "$EXIT_DRIFT" "installed UAT helper lacks a Developer ID timestamp"
        for path in "$SECURE_PATH" "$helper"; do
            if [[ "$path" == "$SECURE_PATH" ]]; then
                cert_prefix="$EVIDENCE_DIR/uat-app-cert-$RUN_STAMP-"
            else
                cert_prefix="$EVIDENCE_DIR/uat-helper-cert-$RUN_STAMP-"
            fi
            bounded "$TOOL_CODESIGN" -d "--extract-certificates=$cert_prefix" "$path" \
                >/dev/null 2>&1 || fail "$EXIT_DRIFT" "installed UAT certificate is unavailable"
            [[ -f "${cert_prefix}0" && ! -L "${cert_prefix}0" ]] || \
                fail "$EXIT_DRIFT" "installed UAT leaf certificate is invalid"
            "$TOOL_CHMOD" 600 "$cert_prefix"* || exit "$EXIT_PREREQ"
            cert_sha="$(bounded "$TOOL_SHASUM" -a 1 "${cert_prefix}0" | \
                /usr/bin/awk '{print toupper($1)}')"
            check "uatSignature.applicationCertificateSHA1:$path" \
                "$UAT_APPLICATION_IDENTITY" "$cert_sha"
        done
    fi
}

if [[ "$STAGE" == "cutover-post-install" ]]; then
    check_parent_list postInstallParents
    if [[ ! -d "$SECURE_PATH" ]]; then
        fail "$EXIT_DRIFT" "secure app path absent after install: $SECURE_PATH"
    fi
    [[ -L "$SECURE_PATH" ]] && fail "$EXIT_DRIFT" "secure app path is a symlink: $SECURE_PATH"
    APP_INFO_PLIST="$SECURE_PATH/Contents/Info.plist"
    if [[ ! -f "$APP_INFO_PLIST" ]]; then
        fail "$EXIT_DRIFT" "installed app Info.plist missing"
    fi
    APP_ID_OBSERVED="$(bounded "$TOOL_PLUTIL" -extract CFBundleIdentifier raw -o - "$APP_INFO_PLIST")"
    check "app.bundleIdentifier" "$BUNDLE_IDENTIFIER" "$APP_ID_OBSERVED"
    APP_VERSION_EXPECTED="$(expected_raw bundle.successorVersion)"
    APP_VERSION_OBSERVED="$(bounded "$TOOL_PLUTIL" -extract CFBundleShortVersionString raw -o - "$APP_INFO_PLIST")"
    check "app.shortVersion" "$APP_VERSION_EXPECTED" "$APP_VERSION_OBSERVED"
    APP_BUILD_EXPECTED="$(expected_raw bundle.successorBuildVersion)"
    APP_BUILD_OBSERVED="$(bounded "$TOOL_PLUTIL" -extract CFBundleVersion raw -o - "$APP_INFO_PLIST")"
    check "app.buildVersion" "$APP_BUILD_EXPECTED" "$APP_BUILD_OBSERVED"
    if [[ "$MODE" == "uat-probe" ]]; then
        verify_uat_installed_bundle
    fi
    LEGACY_APP_POST_INSTALL_STATE="$(expected_raw bundle.legacyAppPostInstallState)"
    case "$LEGACY_APP_POST_INSTALL_STATE" in
        present)
            [[ -d "$LEGACY_APP_PATH" && ! -L "$LEGACY_APP_PATH" ]] || \
                fail "$EXIT_DRIFT" "legacy app must remain after install: $LEGACY_APP_PATH"
            ;;
        absent)
            [[ ! -e "$LEGACY_APP_PATH" && ! -L "$LEGACY_APP_PATH" ]] || \
                fail "$EXIT_DRIFT" "legacy app unexpectedly remains after install: $LEGACY_APP_PATH"
            ;;
        *) fail "$EXIT_EXPECTED" "bundle.legacyAppPostInstallState must be present or absent" ;;
    esac
    CHECK_COUNT=$((CHECK_COUNT + 1))
    log "CHECK legacyApp.postInstallState PASS value=$LEGACY_APP_POST_INSTALL_STATE"
else
    check_parent_list preInstallParents
    if [[ -e "$SECURE_ROOT" || -L "$SECURE_ROOT" ]]; then
        fail "$EXIT_DRIFT" "secure root already exists before install: $SECURE_ROOT"
    fi
    CHECK_COUNT=$((CHECK_COUNT + 1))
    log "CHECK secureRoot.absent PASS value=$SECURE_ROOT"
    if [[ "$MODE" == "production" || "$STAGE" == "cutover-pre" || "$STATIC_RECEIPT_STATE" == "legacy" ]]; then
        if [[ ! -d "$LEGACY_APP_PATH" || -L "$LEGACY_APP_PATH" ]]; then
            fail "$EXIT_DRIFT" "legacy app missing: $LEGACY_APP_PATH"
        fi
        LEGACY_APP_OWNER="$(stat_owner "$LEGACY_APP_PATH")"
        record "legacyApp.owner" "$LEGACY_APP_OWNER"
        LEGACY_APP_MODE="$(stat_mode "$LEGACY_APP_PATH")"
        record "legacyApp.mode" "$LEGACY_APP_MODE"
    elif [[ -e "$LEGACY_APP_PATH" || -L "$LEGACY_APP_PATH" ]]; then
        fail "$EXIT_DRIFT" "uat-probe legacy app unexpectedly exists before clean install: $LEGACY_APP_PATH"
    else
        CHECK_COUNT=$((CHECK_COUNT + 1))
        log "CHECK legacyApp.absent PASS value=$LEGACY_APP_PATH"
    fi
fi

# --- Cutover values (generated at W6, never a source edit) ------------------

if [[ "$STAGE" == "cutover-post-install" ]]; then
    if [[ ! -f "$CUTOVER_VALUES" ]]; then
        fail "$EXIT_EXPECTED" "cutover-values evidence file missing: $CUTOVER_VALUES"
    fi
    CUTOVER_FILE_MODE="$(stat_mode "$CUTOVER_VALUES")"
    check "cutoverValues.fileMode" "100600" "$CUTOVER_FILE_MODE"
    cv_package_path=""
    cv_package_sha256=""
    cv_package_manifest_path=""
    cv_package_manifest_sha256=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        if ! [[ "$key" =~ ^[a-z0-9_]+$ ]]; then
            fail "$EXIT_EXPECTED" "cutover-values has an invalid key: $key"
        fi
        if [[ -z "$value" || "$value" == "$line" ]]; then
            fail "$EXIT_EXPECTED" "cutover-values key has no value: $key"
        fi
        case "$value" in
            *PLACEHOLDER*|*TBD*|*FILL-ME*)
                fail "$EXIT_EXPECTED" "cutover-values key holds a placeholder: $key" ;;
        esac
        case "$key" in
            package_path) cv_package_path="$value" ;;
            package_sha256) cv_package_sha256="$value" ;;
            package_manifest_path) cv_package_manifest_path="$value" ;;
            package_manifest_sha256) cv_package_manifest_sha256="$value" ;;
            *) record "cutoverValues.extraKey" "$key" ;;
        esac
    done < "$CUTOVER_VALUES"
    for pair in "package_path:$cv_package_path" "package_sha256:$cv_package_sha256" \
        "package_manifest_path:$cv_package_manifest_path" \
        "package_manifest_sha256:$cv_package_manifest_sha256"; do
        if [[ -z "${pair#*:}" ]]; then
            fail "$EXIT_EXPECTED" "cutover-values misses required key: ${pair%%:*}"
        fi
    done
    if [[ "$cv_package_path" != /* ]]; then
        fail "$EXIT_EXPECTED" "package_path must be absolute"
    fi
    if [[ ! -f "$cv_package_path" ]]; then
        fail "$EXIT_PREREQ" "frozen package missing: $cv_package_path"
    fi
    PACKAGE_SHA_OBSERVED="$(sha256_of "$cv_package_path")"
    check "package.sha256" "$cv_package_sha256" "$PACKAGE_SHA_OBSERVED"
    if [[ "$cv_package_manifest_path" != /* ]]; then
        fail "$EXIT_EXPECTED" "package_manifest_path must be absolute"
    fi
    if [[ ! -f "$cv_package_manifest_path" ]]; then
        fail "$EXIT_PREREQ" "package manifest missing: $cv_package_manifest_path"
    fi
    MANIFEST_SHA_OBSERVED="$(sha256_of "$cv_package_manifest_path")"
    check "packageManifest.sha256" "$cv_package_manifest_sha256" "$MANIFEST_SHA_OBSERVED"
    MANIFEST_ID_OBSERVED="$(bounded "$TOOL_PLUTIL" -extract packageIdentifier raw -o - "$cv_package_manifest_path")"
    check "packageManifest.identifier" "$PACKAGE_IDENTIFIER" "$MANIFEST_ID_OBSERVED"
    MANIFEST_LOCATION_OBSERVED="$(bounded "$TOOL_PLUTIL" -extract installLocation raw -o - "$cv_package_manifest_path")"
    check "packageManifest.installLocation" "$SECURE_PATH" "$MANIFEST_LOCATION_OBSERVED"
    MANIFEST_VERSION_EXPECTED="$(expected_raw bundle.successorVersion)"
    MANIFEST_VERSION_OBSERVED="$(bounded "$TOOL_PLUTIL" -extract appVersion raw -o - "$cv_package_manifest_path")"
    check "packageManifest.appVersion" "$MANIFEST_VERSION_EXPECTED" "$MANIFEST_VERSION_OBSERVED"
fi

# --- Database (production mode only; read-only with byte guard) -------------

if [[ "$MODE" == "production" ]]; then
    DB_PATH="$(expected_raw database.path)"
    DB_WAL="$DB_PATH-wal"
    if [[ ! -f "$DB_PATH" ]]; then
        fail "$EXIT_PREREQ" "database missing: $DB_PATH"
    fi
    DB_PARENT="${DB_PATH%/*}"
    if [[ "$EVIDENCE_DIR" == "$DB_PARENT"* ]]; then
        fail "$EXIT_USAGE" "--evidence-dir must not be inside the production database directory"
    fi

    db_guard_hash() {
        local wal_hash="absent" main_hash
        main_hash="$(sha256_of "$DB_PATH")"
        [[ -f "$DB_WAL" ]] && wal_hash="$(sha256_of "$DB_WAL")"
        printf '%s+%s' "$main_hash" "$wal_hash"
    }

    db_query() {
        bounded "$TOOL_SQLITE3" -readonly -batch -noheader "$DB_PATH" \
            "PRAGMA query_only=ON; $1"
    }

    GUARD_BEFORE="$(db_guard_hash)"
    record "database.guard.before" "$GUARD_BEFORE"

    DB_SCHEMA_EXPECTED="$(expected_raw database.schemaVersion)"
    DB_SCHEMA_OBSERVED="$(db_query 'SELECT MAX(version) FROM schema_migrations;')"
    check "database.schemaVersion" "$DB_SCHEMA_EXPECTED" "$DB_SCHEMA_OBSERVED"
    DB_INTEGRITY_OBSERVED="$(db_query 'PRAGMA integrity_check;')"
    check "database.integrity" "ok" "$DB_INTEGRITY_OBSERVED"
    DB_FK_OBSERVED="$(db_query 'PRAGMA foreign_key_check;')"
    check "database.foreignKeyViolations" "" "$DB_FK_OBSERVED"
    DB_PAUSED_EXPECTED="$(expected_raw database.paused)"
    DB_PAUSED_OBSERVED="$(db_query 'SELECT paused FROM app_settings WHERE singleton = 1;')"
    check "database.paused" "$DB_PAUSED_EXPECTED" "$DB_PAUSED_OBSERVED"
    DB_QUEUED_EXPECTED="$(expected_raw database.queuedJobs)"
    DB_QUEUED_OBSERVED="$(db_query "SELECT COUNT(*) FROM jobs WHERE state = 'queued';")"
    check "database.queuedJobs" "$DB_QUEUED_EXPECTED" "$DB_QUEUED_OBSERVED"
    DB_BLOCKED_EXPECTED="$(expected_raw database.blockedJobs)"
    DB_BLOCKED_OBSERVED="$(db_query "SELECT COUNT(*) FROM jobs WHERE state = 'blocked';")"
    check "database.blockedJobs" "$DB_BLOCKED_EXPECTED" "$DB_BLOCKED_OBSERVED"
    DB_RUNNING_EXPECTED="$(expected_raw database.runningPiJobs)"
    DB_RUNNING_OBSERVED="$(db_query "SELECT COUNT(*) FROM jobs WHERE state = 'runningPi';")"
    check "database.runningPiJobs" "$DB_RUNNING_EXPECTED" "$DB_RUNNING_OBSERVED"
    DB_TOTAL_EXPECTED="$(expected_raw database.totalJobs)"
    DB_TOTAL_OBSERVED="$(db_query 'SELECT COUNT(*) FROM jobs;')"
    check "database.totalJobs" "$DB_TOTAL_EXPECTED" "$DB_TOTAL_OBSERVED"

    GUARD_AFTER="$(db_guard_hash)"
    record "database.guard.after" "$GUARD_AFTER"
    if [[ "$GUARD_BEFORE" != "$GUARD_AFTER" ]]; then
        fail "$EXIT_GUARD" "database bytes changed while auditing; aborting"
    fi

    # Process observations are evidence, never mutation. pgrep/lsof are read-only.
    # Tool failure must stay distinguishable from "no match": pgrep exits 1 for no
    # match and >=2 for errors; lsof errors are detected through captured stderr.
    PGREP_RC=0
    PROCESS_MATCHES="$(bounded "$TOOL_PGREP" -f "$LEGACY_APP_PATH/Contents/MacOS/" 2>/dev/null)" || PGREP_RC=$?
    if (( PGREP_RC >= 2 )); then
        fail "$EXIT_PREREQ" "pgrep failed (rc=$PGREP_RC); quiesce evidence unavailable"
    fi
    record "process.legacyAppPids" "${PROCESS_MATCHES:-none}"
    LSOF_STDERR_FILE="$EVIDENCE_DIR/lsof-stderr-$RUN_STAMP.txt"
    DB_OPENERS="$(bounded "$TOOL_LSOF" -Fp "$DB_PATH" 2>"$LSOF_STDERR_FILE")" || DB_OPENERS=""
    if [[ -s "$LSOF_STDERR_FILE" ]]; then
        fail "$EXIT_PREREQ" "lsof reported an error (see $LSOF_STDERR_FILE); quiesce evidence unavailable"
    fi
    record "database.openers" "${DB_OPENERS:-none}"
    if (( REQUIRE_QUIESCED )); then
        check "quiesced.legacyAppPids" "" "$PROCESS_MATCHES"
        check "quiesced.databaseOpeners" "" "$DB_OPENERS"
    fi
fi

log "RESULT PASS stage=$STAGE mode=$MODE checks=$CHECK_COUNT"
printf 'production-readiness-preflight: PASS stage=%s mode=%s checks=%s evidence=%s\n' \
    "$STAGE" "$MODE" "$CHECK_COUNT" "$EVIDENCE_LOG"
