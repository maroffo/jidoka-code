#!/bin/bash
# ABOUTME: Derives Tests/JidokaCodeCoreTests/Fixtures/Schema/shipped-schema9.sql from the immutable evidence database
# ABOUTME: Emits the shipped DDL verbatim plus ledger and non-identifying seed rows; never reads DatabaseSchema.migrations
set -euo pipefail

readonly EXPECTED_SOURCE_SHA256=c612a3ed9e084032595127262db6ed4dd7b245798206511c348903403e0889dd
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
-- ABOUTME: Shipped Jidoka Code schema 9 exactly as the signed 0.1.0 helper created it (source 944f4f4)
-- ABOUTME: Static fixture derived from evidence, never from DatabaseSchema.migrations; see provenance below
--
-- Provenance
--   historical source commit: 944f4f489e732f871e749cfd61c6b2d7e3324343
--   historical source tree:   e7369aa9eb2e5d3e92dcb49da5057f0fe894480b
--   historical package:       Jidoka Code-0.1.0-schema9.pkg
--                             SHA-256 7102326303e2fe1f1394c42b4f919351f14ec3c37f5ac26dd962ac23c83ab0cb
--                             Apple submission 9ed36ebb-a727-451c-90fe-8124041387e2
--   schema-8 input:           schema8-source.sqlite3 (synthetic)
--                             SHA-256 e2c1a073c5ae3638466fa9fe4a63bf79035e3bbe1130b46ea7ad02cf18543f41
--   evidence database:        w7/build4/schema-compatibility/final-audit/shipped-schema9-pristine.sqlite3
--                             SHA-256 c612a3ed9e084032595127262db6ed4dd7b245798206511c348903403e0889dd
--                             sqlite3 .sha3sum --schema 3b5bc9236a9bdba8667e36698b85c76b7deab3a80562717f9314e07dceddb753
--                             produced by running the signed schema-9 helper against the schema-8 input
--   derivation:               scripts/tests/fixtures/derive-shipped-schema9-fixture.sh, 2026-09-06
--
-- Content
--   1. Every sqlite_schema.sql entry of the evidence database, verbatim, in creation (rowid) order.
--   2. The nine schema_migrations rows verbatim (the shipped ledger has no statements_sha256 column).
--   3. The four model_profiles seed rows verbatim.
--   4. The app_settings singleton with every GitHub account column set to NULL.
--   No other application rows: the evidence database holds non-public repository and job data.
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
