# ABOUTME: Database review of commit 4dc9cbc, focused on SQLite migration 11 (rollout scope repin to schema 11 / engine protocol 13)
# ABOUTME: Findings evidenced by SQL probes against a read-only copy of the production database

# Database Review — migration 11 (`rollout-scope-engine-protocol-13`), commit 4dc9cbc

Scope reviewed: the diff `88f8658..4dc9cbc`, concentrated on
`Sources/JidokaCodeCore/State/DatabaseSchema.swift:3644-3672` (migration 11), the runner in
`Sources/JidokaCodeCore/State/SQLiteStore.swift`, and every consumer of
`rollout_authorization_scopes`.

## Environment note (affects reproducibility, not the findings)

The isolated worktree I was given (`/Users/maroffo/Development/public/jidoka-code/.claude/worktrees/agent-a17c15f06260b088e`)
belongs to a **different repository** than the one under review. `88f8658` and `4dc9cbc` do not
resolve there, and the two repos share no object store:

```
$ git rev-parse --git-common-dir          # in my worktree
/Users/maroffo/Development/public/jidoka-code/.git
$ git -C /Users/maroffo/jidoka-code-w9 rev-parse --git-common-dir
.git
```

I therefore read the reviewed tree read-only from `/Users/maroffo/jidoka-code-w9` (whose `HEAD` is
exactly `4dc9cbc`, so working tree == commit) and did all probing in scratch. I wrote nothing to
that tree except this report.

Consequence for evidence: I did **not** run `xcrun swift test --filter SQLiteStore`, because doing
so inside `/Users/maroffo/jidoka-code-w9` would write `.build/` into the main checkout. Every claim
below is instead settled by SQL executed against a copy of the real production database, which for
the migration-semantics questions is stronger evidence than the Swift suite anyway. Where I rely on
source reading or grep instead of execution, I say so.

All probes ran against a read-only `.backup` copy of
`~/Library/Application Support/JidokaCode/jidoka-code.sqlite3` (sqlite 3.54.0). The production file
was never opened writable.

Baseline of the copy:

```
PRAGMA user_version -> 0 ; PRAGMA schema_version -> 1
rollout_authorizations       0 rows
rollout_authorization_scopes 0 rows
schema_migrations: v10 = progressive-production-rollout-authority, digest 5c91b3094799c6e3...
CHECK (schema_version = 10), CHECK (engine_protocol_version = 12)   -- ordinals 31, 32 of 58
```

---

## Claim-by-claim verification

### Claim 1 — "no trigger, index, view or foreign key reads either column". **CONFIRMED.**

Not inferred from a clean run. Checked exhaustively against the whole live schema:

```sql
SELECT type,name,tbl_name FROM sqlite_master
 WHERE sql LIKE '%engine_protocol_version%' OR sql LIKE '%schema_version%';
-- table|rollout_authorization_scopes|rollout_authorization_scopes
```

One row: the table itself. No trigger, index, view or FK anywhere in the database mentions either
column. The ten triggers that name the table were dumped in full (305 lines) and scanned for
positional access; the whole schema contains no star-projection at all:

```sql
SELECT type,name FROM sqlite_master WHERE sql LIKE '%SELECT *%';   -- (empty)
```

The table-level `CHECK` at the end of the DDL (the exactObject/finiteWindow disjunction) references
neither column, which is what makes `DROP COLUMN` legal at all — SQLite refuses to drop a column
named in a table constraint.

Post-migration DDL placement is also correct: SQLite splices the re-added columns *before* the
trailing table-level CHECK, so the disjunction is preserved.

### Claim 2 — "column reordering is safe". **CONFIRMED.**

- Reads are name-keyed, never positional: `SQLiteStore.swift:650` builds each row dict from
  `sqlite3_column_name`. No `table_info`-driven SQL over this table.
- No star-projection in `Sources/` or in the schema (above).
- Convergence holds. A fresh database creates the table from `DatabaseSchema.swift:1774` (which
  still pins `= 10` / `= 12` at ordinals 31/32) and then runs migration 11, landing the columns at
  ordinals 56/57 — the same place production lands. Production's pre-migration DDL *is* the
  create-table state, so both paths demonstrably converge.
- No digest or snapshot depends on column order. `statementsSHA256`
  (`SQLiteStore.swift:69-79`) hashes version, name, `requiresBackup` and the statement texts —
  never the resulting DDL. No hardcoded digest appears in the docs.

### Claim 3 — "the `DEFAULT 11` / `DEFAULT 13` is inert because the CHECK still fixes the value".
**TRUE FOR INSERTS, FALSE FOR THE MIGRATION ITSELF.** See MAJOR-1.

For inserts the claim holds. There is exactly one insert path in the entire repository:

```
$ grep -rn "INSERT INTO rollout_authorization_scopes" Sources Tests scripts
Sources/JidokaCodeCore/State/RolloutAuthorityStore.swift:1666
```

It lists all 58 columns explicitly, including both pins (`RolloutAuthorityStore.swift:1677`). No
insert path can take the default. Nothing regressed here.

### Claim 4 — "clean rollback after every one of the four statements". **CONFIRMED.**

Executed each prefix of the four statements inside `BEGIN IMMEDIATE` on a fresh copy of the real
production database, then `ROLLBACK`, comparing the stored DDL text, the column count, the schema
cookie and integrity:

```
stmts=1..1 ddl_restored=YES cols=58 cookie=1->1 integrity=ok
stmts=1..2 ddl_restored=YES cols=58 cookie=1->1 integrity=ok
stmts=1..3 ddl_restored=YES cols=58 cookie=1->1 integrity=ok
stmts=1..4 ddl_restored=YES cols=58 cookie=1->1 integrity=ok
```

DDL restored byte-identical (md5 of the stored `sqlite_master.sql` unchanged) in all four cases, and
the schema cookie does not advance. DDL rollback for `ALTER TABLE DROP/ADD COLUMN` is complete in
3.54.0. No finding.

### Claim 5 — backup ordering and digest. **CONFIRMED, with one caveat (MINOR-1).**

`SQLiteStore.swift:522-533`: within the per-migration loop, the backup is taken *before* the
`BEGIN IMMEDIATE` and therefore before any statement, once per migration, into a fresh file
(`prepareBackupDestination` refuses to overwrite). `requiresBackup: true` is honoured for
production because `databaseExistedBeforeOpen` is true.

The digest is computed, not transcribed, and `verifyAppliedMigrationContent`
(`SQLiteStore.swift:457-493`) skips version 11 on the current production database because no row
exists yet, then stamps it. Nothing to get wrong. Migration 10's recorded digest is present
(`5c91b309...`) so the `verifiesContent` gate on 10 will be evaluated, not skipped.

---

## MAJOR

### MAJOR-1 — `Sources/JidokaCodeCore/State/DatabaseSchema.swift:3657-3667`

**Claim.** On a non-empty `rollout_authorization_scopes`, migration 11 does not repin the schema:
it **silently rewrites the data**. Each pre-existing row's `schema_version`/`engine_protocol_version`
is discarded by `DROP COLUMN` and refilled from `DEFAULT 11`/`DEFAULT 13`. The row then asserts it
was minted by a release it was not minted by, and the CHECK validates the forged value as legal.
This bypasses the two triggers that exist precisely to forbid it — `ALTER TABLE` does not fire
`BEFORE UPDATE`/`BEFORE DELETE` triggers.

The source comment ("the CHECK is still what fixes the value") and the same sentence in
`docs/operations/progressive-production-rollout.md` are accurate only for inserts. For rows that
already exist, the DEFAULT is the *only* thing that sets the value.

**Evidence.** On a scratch copy of production, seeded with one scope row pinned 10/12 (FK and the
`_exact_insert` trigger removed only to seed; the append-only triggers left live):

```
seeded pins|10|12
UPDATE rollout_authorization_scopes SET schema_version = 11;
  -> Error: rollout_authorization_scopes is append-only        <-- guard works for UPDATE

BEGIN IMMEDIATE;  <the four migration-11 statements>  COMMIT;
BEFORE|auth-1|10|12
AFTER |auth-1|11|13                                            <-- guard bypassed, rc=0
PRAGMA integrity_check -> ok
```

Reduced to a minimal STRICT table with the same trigger shape, to isolate the SQLite semantics from
this schema's specifics:

```
rows before|1
rows after|1
value after|11        -- pre-existing row silently took DEFAULT 11; no trigger fired
```

**Why this is not Critical today, and why it is not Minor either.** Production is empty — I
re-verified 0 rows in `rollout_authorizations` and `rollout_authorization_scopes` on the copy — so
the migration is a pure repin on the one database that matters right now. But nothing in the
migration *checks* that. The emptiness is an assumption held in a plan document, not an invariant
enforced by the code, and the plan itself already names the scenario as the thing to revisit
(`quality_reports/plans/active/2026-09-03_progressive-production-automation.md:544`, E28 "Revisit
if": *"A future protocol bump lands while a lane row exists, which makes the column rewrite a data
migration rather than an empty-table repin"*). The failure mode when that happens is silent forged
provenance in an append-only attestation table, not an error. Production is paused but installable
at any time: if a lane is minted before the W9 build is installed, this fires.

The existing test does not cover it. `SQLiteStoreTests.swift:400-402` asserts `COUNT(*) == 0` after
the migration with the comment *"no row may be manufactured on the way through"*, but the fixture
has zero scope rows before the migration too, so the assertion is vacuous with respect to this risk.
No test exercises migration 11 against a populated scopes table.

**Fix.** Make the precondition an enforced guard rather than a documented assumption: prepend a
fail-closed statement so the migration aborts (and rolls back, per Claim 4) on any non-empty table.
`RAISE()` is trigger-only, so use a CHECK-violating scratch table, which also runs *inside* the
migration transaction and therefore closes MINOR-1's window as well:

```sql
CREATE TABLE rollout_scope_repin_guard (n INTEGER NOT NULL CHECK (n = 0));
INSERT INTO rollout_scope_repin_guard(n) SELECT count(*) FROM rollout_authorization_scopes;
DROP TABLE rollout_scope_repin_guard;
```

Verified both directions on real copies:

```
non-empty copy: Error: CHECK constraint failed: n = 0   (rc=1, transaction refused)
empty  copy:    proceeds, guard table dropped, count in sqlite_master = 0   (rc=0)
```

Add the red test alongside: migration 11 against a fixture carrying one scope row must throw, and
must leave the database at schema 10 with `engine_protocol_version = 12`.

Note this changes `statementsSHA256`, which is correct and safe: migration 11 has not shipped, and
`verifiesContent: true` is exactly the mechanism that makes an already-stamped pre-release database
fail closed instead of silently diverging.

### MAJOR-2 — `Sources/JidokaCodeCore/State/DatabaseSchema.swift:3660,3665-3666`

**Claim.** The pins `11` and `13` are bare literals with no link to the constants they mirror.
`DatabaseSchema.swift` never references `EngineProtocolVersion`, and `schema_version = 11` is not
derived from the migration's own `version: 11`. A future `EngineProtocolVersion.current` bump that
forgets migration 12 compiles, passes the SQLite suite, opens the database cleanly, and then fails
at the first attempt to mint an authorization with an opaque `CHECK constraint failed:
engine_protocol_version = 14` — at the one operation the whole progressive rollout exists to
perform. This is the same defect class the commit is currently remediating for 12 -> 13, and it is
left unguarded for the next bump.

**Evidence.**

```
$ grep -rn "EngineProtocolVersion" Sources Tests
Sources/JidokaCodeCore/Application/EngineProtocol.swift:3,815,825,842
Sources/JidokaCodeCore/Application/RolloutReleaseIdentityAttestor.swift:128
Tests/JidokaCodeCoreTests/EngineProtocolTests.swift:27,749,777
```

No hit in `State/DatabaseSchema.swift`; no test asserts the coupling. The nearest test,
`SQLiteStoreTests.swift:389-390`, hardcodes the strings `"engine_protocol_version = 13"` and
`"schema_version = 11"`, so it moves in lockstep with the bug rather than catching it.

**Fix.** One assertion that cannot drift, e.g. in `SQLiteStoreTests`:

```swift
let ddl = try await scopeTableDDL(in: upgraded)
#expect(ddl.contains("engine_protocol_version = \(EngineProtocolVersion.current)"))
#expect(ddl.contains("schema_version = \(DatabaseSchema.migrations.last!.version)"))
```

Bumping `current` without adding a migration then fails at test time, loudly, instead of at mint
time, opaquely.

---

## MINOR

### MINOR-1 — `Sources/JidokaCodeCore/State/SQLiteStore.swift:523-533`

**Claim.** The backup is taken outside any write lock. Between `backup(connection:destinationURL:)`
returning and `BEGIN IMMEDIATE` acquiring the lock, another connection (the helper, in WAL) can
commit a write. That write is absent from the "before-v11" backup, and for migration 11 it can also
be the very row MAJOR-1 then silently repins. Pre-existing ordering, not introduced by this commit,
but migration 11 is the first migration whose correctness depends on the table's contents at
`BEGIN` time rather than only on its shape.

**Fix.** The MAJOR-1 guard resolves this for migration 11 at no extra cost, because it evaluates
`count(*)` inside the transaction. Generally: acquire the write lock before taking the backup.

**Evidence.** Source ordering at `SQLiteStore.swift:523` (backup) then `:533` (`BEGIN IMMEDIATE`),
with no intervening lock acquisition. Not empirically reproduced — I did not race the helper against
the migration, and with the app quiesced per the W8 quit order this window is narrow.

### MINOR-2 — `Sources/JidokaCodeCore/State/DatabaseSchema.swift:3638-3641`

**Claim.** Migration 10's comment reads *"Schema 10 has never shipped"*. It has. Adjacent to the
diff rather than in it, but it governs the same `verifiesContent` fail-closed mechanism migration 11
now copies, and the stale premise invites someone to edit migration 10's body — which would brick
the installed production database on next open.

**Evidence.** The production ledger:

```
10|progressive-production-rollout-authority|5c91b3094799c6e3
```

and the shipped table carrying `CHECK (schema_version = 10)`.

**Fix.** Replace with the fact that now justifies keeping `verifiesContent`: migration 10 has
shipped and is digest-stamped in production, so its body is frozen.

---

## Not findings (checked, clean)

- `DROP COLUMN` legality against table constraints, indexes, FKs, views — verified exhaustively.
- Column reordering vs. any consumer — no positional access, no star-projection, name-keyed rows.
- Fresh-database vs. upgraded-database layout convergence.
- DDL rollback completeness including the schema cookie, per statement prefix.
- Backup taken before any statement, per migration, non-overwriting, mode 0600.
- Digest computed rather than transcribed; migration 10's digest present and comparable.
- `PRAGMA integrity_check` and `foreign_key_check` clean after the migration on a real copy.
- Insert paths: exactly one, fully explicit, unaffected by the new DEFAULTs.
- Statement count and transaction shape: four statements, one `BEGIN IMMEDIATE`, one ledger row.

## Summary

Deployment risk: **MEDIUM** for the production database as it stands today (empty scopes table
verified read-only, so migration 11 is a pure repin and every mechanical claim about it holds);
**HIGH** for any database that carries a scope row, where the migration silently forges the release
pins it is supposed to attest.

Recommendation: **FIX BEFORE MERGE.** MAJOR-1 is a three-statement guard plus a red test, both
verified above, and it converts an assumption documented in a plan into an invariant the migration
enforces. MAJOR-2 is a two-line test. Neither changes the migration's behaviour on the current
production database.
