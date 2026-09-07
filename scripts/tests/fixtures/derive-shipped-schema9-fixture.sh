#!/bin/bash
# ABOUTME: Derives Tests/JidokaCodeCoreTests/Fixtures/Schema/shipped-schema9.sql from the installed-helper evidence database
# ABOUTME: Emits the shipped DDL verbatim plus ledger and non-identifying seed rows; never reads DatabaseSchema.migrations
set -euo pipefail

readonly EXPECTED_SOURCE_SHA256=68647463322c65da2476507fb6aae276dbc4f3c74c0b69ffdd5c421a35f587d8
readonly SQLITE=/usr/bin/sqlite3

usage() {
  printf 'usage: %s SOURCE_SQLITE OUTPUT_SQL\n' "$0" >&2
  exit 64
}

fail() {
  printf 'derive-shipped-schema9-fixture: %s\n' "$1" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
readonly SOURCE="$1"
readonly OUTPUT="$2"
[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || fail "source database is not a regular file"
[[ ! -e "$OUTPUT" ]] || fail "output already exists: $OUTPUT"

observed_sha256="$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}')"
[[ "$observed_sha256" == "$EXPECTED_SOURCE_SHA256" ]] \
  || fail "source digest $observed_sha256 is not the shipped schema-9 evidence database"

readonly URI="file:$SOURCE?mode=ro&immutable=1"

query() {
  "$SQLITE" -batch "$URI" "$1"
}

[[ "$(query 'SELECT COALESCE(MAX(version), 0) FROM schema_migrations;')" == 9 ]] \
  || fail "source is not at schema 9"
[[ "$(query "SELECT COUNT(*) FROM pragma_table_info('schema_migrations') WHERE name = 'statements_sha256';")" == 0 ]] \
  || fail "source ledger already carries a digest column"
[[ "$(query "SELECT COUNT(*) FROM schema_migrations WHERE CAST(quote(applied_at) AS REAL) != applied_at;")" == 0 ]] \
  || fail "ledger timestamps do not round-trip through quote()"
readonly EXPECTED_APP_SETTINGS_COLUMNS='singleton, max_concurrency, paused, updated_at, onboarding_complete, external_automation_acknowledged, provider_disclosure_acknowledged, github_account, github_author_id, pending_github_account, pending_github_author_id, pending_replacement_sha256, previous_github_account, credential_deletion_pending, login_item_selected, login_item_status'
[[ "$(query "SELECT group_concat(name, ', ') FROM pragma_table_info('app_settings');")" == "$EXPECTED_APP_SETTINGS_COLUMNS" ]] \
  || fail "app_settings columns differ from the shipped schema"

{
  cat <<'HEADER'
-- ABOUTME: Shipped Jidoka Code schema 9 exactly as the installed 0.1.1 build 2 helper creates it
-- ABOUTME: Static fixture derived from evidence, never from DatabaseSchema.migrations; see provenance below
--
-- Provenance
--   installed application:    /Library/Application Support/JidokaCode/Applications/Jidoka Code.app, 0.1.1 build 2
--   installed helper:         Contents/Helpers/JidokaCodeEngineProbe
--                             SHA-256 3aeb9f172d8c0dbffd0a70552008c6c2d5994b74fbc34a8258ce9b19378f7779
--                             CDHash 3f9eb34eaeca3b2ce82d33619c111af5cc301a72, team X3Q42VNZDC
--   migration-9 source text:  identical in e22c32a191892425fefaae9549e4d14207ae1062 and
--                             c67943130e535da65274b77601e36241ce781454 (the 0.1.1 worktree head)
--   production ledger row 9:  authorized-architecture-role-host-replacement-and-generation-rollover
--   production DDL sha3-256:  9fe91dab565079947cdf85bb7c93571809e83475954b08cb0a5cf458c3e71ad6
--                             (sha3_query over type, name, tbl_name, sql ordered by type, name; equal to the
--                             evidence database below, which the same helper created from nothing)
--   evidence database:        w7/build5/production-schema-body/02-installed-helper-schema9-pristine.sqlite3
--                             SHA-256 68647463322c65da2476507fb6aae276dbc4f3c74c0b69ffdd5c421a35f587d8
--                             sqlite3 .sha3sum --schema 8abfd0b9620f1df741dfc26f89a3f740887f5e14d9e46c31db5592b3
--                             produced by a ditto copy of the installed helper in a sandbox home
--   derivation:               scripts/tests/fixtures/derive-shipped-schema9-fixture.sh, 2026-09-07
--
-- Content
--   1. Every sqlite_schema.sql entry of the evidence database, verbatim, in creation (rowid) order.
--   2. The nine schema_migrations rows verbatim (the shipped ledger has no statements_sha256 column).
--   3. The four model_profiles seed rows verbatim.
--   4. The app_settings singleton with every GitHub account column set to NULL.
--   The evidence database was created empty, so it holds no repository or job rows.
--   Row preservation across the schema-10 migration is proven with synthetic rows in the tests.
HEADER
  query "SELECT sql || ';' FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY rowid;"
  query "SELECT 'INSERT INTO schema_migrations(version, name, applied_at) VALUES (' || version || ', ' || quote(name) || ', ' || quote(applied_at) || ');' FROM schema_migrations ORDER BY version;"
  query "SELECT 'INSERT INTO model_profiles(role, provider, model, thinking, updated_at) VALUES (' || quote(role) || ', ' || quote(provider) || ', ' || quote(model) || ', ' || quote(thinking) || ', ' || quote(updated_at) || ');' FROM model_profiles ORDER BY rowid;"
  query "SELECT 'INSERT INTO app_settings(${EXPECTED_APP_SETTINGS_COLUMNS}) VALUES (' || quote(singleton) || ', ' || quote(max_concurrency) || ', ' || quote(paused) || ', ' || quote(updated_at) || ', ' || quote(onboarding_complete) || ', ' || quote(external_automation_acknowledged) || ', ' || quote(provider_disclosure_acknowledged) || ', NULL, NULL, NULL, NULL, NULL, NULL, ' || quote(credential_deletion_pending) || ', ' || quote(login_item_selected) || ', ' || quote(login_item_status) || ');' FROM app_settings WHERE singleton = 1;"
} > "$OUTPUT"

if /usr/bin/grep -Eiq 'maroffo|hikma|wishew|/Users/|R_kgDO|PR_kwDO|I_kwDO|ghp_|github_pat' "$OUTPUT"; then
  /bin/rm -f "$OUTPUT"
  fail "derived fixture contains non-public strings"
fi
[[ "$(/usr/bin/grep -c '^CREATE ' "$OUTPUT")" == "$(query "SELECT COUNT(*) FROM sqlite_schema WHERE sql IS NOT NULL;")" ]] \
  || fail "derived fixture statement count differs from the evidence schema"
printf 'derived %s sha256=%s\n' "$OUTPUT" "$(/usr/bin/shasum -a 256 "$OUTPUT" | /usr/bin/awk '{print $1}')"
