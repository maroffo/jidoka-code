# Progressive production rollout

This runbook covers source qualification and operation of schema-10 rollout authority for
Jidoka Code `0.2.0` build `3`, engine protocol `12`, policy version `1`. It does not authorize
signing, notarization, installation, a provider session, a GitHub or Git remote operation,
activation, promotion, merge, deployment, rollback, or deletion of historical evidence.

## Safety boundary

Production has one durable rollout lane and one source writer. Repository flags are only
defense in depth. They never grant work authority. An active authorization binds all of the
following:

- one release and configuration identity;
- one repository and workflow stage;
- one exact object revision, or one finite and expiring candidate predicate;
- one durable job binding per admitted job;
- exact provider, command, Git, GitHub, label, marker, and publication caps;
- an expiry, event history, non-replenishing reservations, and a stop owner.

The closed stages are `prReview`, `issueTriage`, `implementationPlan`,
`implementationExecute`, and `generatedPRReview`. Exact planning ends at the durable simple
plan boundary. Execution needs a separate `implementationExecute` authorization. A generated
review job remains queued and inert until a separate `generatedPRReview` authorization binds
the append-only parent-child record.

There is no Resume operation and no production allow-all authority. New repositories start
disabled with all workflow flags off. `Poll now` is valid only for an active finite window.
Schema 10 treats every historical `JobCanaryScope` as retained evidence only. It cannot admit
a fresh provider, command, Git, GitHub, lease, Pi launch, or generated-review effect.

## Schema-10 migration identity

Schema 10 has never shipped. While this branch was in review its migration body was edited more
than once, and the migrator only applies migrations whose version exceeds the recorded maximum:
a database already stamped at version 10 by an earlier body would otherwise skip every later
change silently and run on a schema this binary never wrote.

`schema_migrations` therefore records `statements_sha256`, the digest of an applied migration's
version, name, backup requirement and exact ordered statements. Recomputing it from the statement
bodies alone gives a different value, so use `SQLiteMigration.statementsSHA256` rather than
hashing the SQL by hand. Opening a database verifies the digest for every migration that declares
`verifiesContent`. A mismatch, or a verified row with no digest at all, fails closed before any
migration statement runs:

```
migrationContentMismatch(version: 10, recorded: <digest or nil>, expected: <digest>)
```

Only version 10 declares it today. The flag is a per-migration opt-in rather than a version
floor on purpose: the fact that justifies it, "this migration has never shipped, so any other
recorded body is a pre-release database", belongs to migration 10 and is false for migration 11.
A floor would silently extend the operator action below to a future migration where deleting the
database would be exactly the wrong advice. Versions 1 through 9 shipped in binaries that predate
the column, so their blank rows are expected and are not verified.

Before that guard the connection is configured (`PRAGMA journal_mode = WAL`, `PRAGMA
foreign_keys = ON`) and the ledger table is created if absent. Both are no-ops on any database
that can be refused, since a database stamped at version 10 already has a ledger, so the refusal
adds no schema and no rows. What the guard promises is that no migration statement and no digest
column is written to a database this binary is about to reject; it does not promise the file is
opened read-only.

**Operator action when this fires.** It means the database was created by a pre-release build of
this branch, so it is a development or CI database, never a production one: production has never
been migrated past schema 9. Delete that development database and let the binary recreate it, or
restore the schema-9 backup taken before the bad migration and re-migrate. Do not edit
`schema_migrations` with `sqlite3` to silence the error, and never delete a user's database
automatically — the message names the mismatch so a person can decide.

No source-controlled check persists such a database. There is no CI workflow in this repository,
and every check that creates one (`swift test`, `scripts/tests/test-progressive-production-rollout-preflight.sh`,
`scripts/tests/test-production-readiness-preflight.sh`) builds it under a fresh `mktemp -d`
removed by an `EXIT` trap.

## Preserved state

Migration and rollout operation preserve every historical job, run, result, mutation intent,
session, descriptor, backup, canary record, and evidence artifact. Never edit the database
with `sqlite3`, delete an uncertain mutation, reset a job, or rewrite rollout tables. Schema 10
is append-only where evidence is involved and migration requires the repository backup path.

Already-started uncertain GitHub and Git effects may be reconciled read-only after stop,
expiry, or revocation. Each readback is bound to the original mutation intent, repository,
object, target, and the operation-specific lookup class. Every fresh read outside that exact
readback, provider launch, command, send, ref creation, or child launch is denied.

The database independently enforces active repository leases. The gate arms when the leased job
is `rollout_generation = 1`, or when the repository has an open authorization (`active`,
`draining`, or `recoveryRequired`). Once armed, an inserted or reactivated lease must name the
generation-1 job bound to the current unpaused authorization, stage, enabled workflow, and
nonterminal phase. Application-only checks are not sufficient authority.

Both halves are needed. Arming on lane state alone would leave a promoted job ungated for ever
once its lane settled; arming on generation alone would let ordinary generation-0 work join a
rollout already in flight. Neither half may become a bare existence check over
`rollout_authorizations`: the table is append-only, so that would make the first authorization
ever created a permanent bar on every repository, including repositories a rollout never
touched. Closing a lane (`settled`, `revoked`, `expired`, `failed`) disarms the lane half again,
and the closed row stays as evidence.

A heartbeat on a lease the repository already holds is a continuation, not admission: same row,
same job, same fencing generation, already active. The schema exempts it, so pausing and draining
cannot abort it: pausing is the mandatory first step of closing a lane, and a drain that could not
heartbeat would abort itself. The exemption applies only while an open lane on that repository
actually binds the leased job. Reactivating a released lease, bumping the fencing generation,
moving a lease to another job, and taking a fresh lease all remain admission and stay gated.

Note what that exemption is and is not. No production code emits a continuation heartbeat today:
`DurableJobStore.heartbeat` is public API with no caller in `Sources`, every production write to
`repository_leases` is either acquisition (a generation bump, which is gated) or release, and
nothing expires a lease by heartbeat age. The exemption keeps the store's public contract coherent
and bounds a future heartbeat writer. It is not a mechanism that reclaims a live lease.

Activating a lane deliberately does not require the repository to be lease-free. A rollout binds
a job that is already in flight (an `implementationExecute` lane is only previewable once that
job has produced its plan artifacts), so the bound job legitimately holds the lease at activation
time.

**What happens to an ordinary job holding the lease when a lane opens.** Nothing evicts it. It
keeps the lease, runs to completion and releases normally, and it acquires no rollout authority
while it does: every effect is bound through `rollout_job_bindings`, where it has no row. Because
`max_concurrency` is one, the lane's own bound job cannot take the lease until that release, which
is why the documented sequence is to pause and let in-flight work finish before activating. If you
need the lane to start immediately, wait for the release rather than editing the lease.

## Generated-review quarantine

A successful implementation creates its PR-review child job with `rollout_generation = 0`. That
is deliberate quarantine, not an oversight: the parent's implementation authority must not
silently buy four more provider sessions and another published comment. The child stays durable
and queued and cannot be leased while a lane is open on its repository, until a separate
`generatedPRReview` preview and authorization bind it and promote it to generation 1.

The consequence to plan for: if no further authorization is ever issued, that child job stays
queued forever. It is inert, not lost. Close it by authorizing the generated review, or leave it
queued; never hand it authority by editing `rollout_generation` directly.

## Usage-ledger retention

`rollout_authorization_usage` is an append-only running total, one row per reserved effect, read
only at its latest sequence. It is never pruned, including for closed authorizations: the chain
is the audit trail that shows how each budget was spent, and deleting rows would both destroy
that evidence and break the running-total invariant that makes cap enforcement constant-time.
Growth is bounded by the budgets themselves, whose schema ceiling is 10,000 reservations per
authorization, so the table cannot grow without a corresponding authorized effect.

## Source-only qualification

Use only the repository-supported qualified runtime input. The preflight reads source and
expected values, does not open Keychain, does not start Jidoka Code or a provider, and does not
perform Git or GitHub I/O.

```sh
JIDOKA_RELEASE_RUNTIME_ROOT=/absolute/path/to/qualified-runtime \
  ./scripts/progressive-production-rollout-preflight.sh \
  --stage static \
  --source-root "$PWD" \
  --expected "$PWD/docs/operations/progressive-production-rollout-expected.json"
```

Success reports all qualification deltas as zero:

```text
credentialReads=0 providerCalls=0 githubMutations=0 gitRemoteReads=0
```

The fixed contract is
`docs/operations/progressive-production-rollout-expected.schema.json`. Unknown expected-value
fields, a version mismatch, a missing gate source, an unsafe path, or a nonzero counter
expectation fails closed.

For W0 through W6 source acceptance, run after the final source edit:

```sh
JIDOKA_RELEASE_RUNTIME_ROOT=/absolute/path/to/qualified-runtime make check
JIDOKA_RELEASE_RUNTIME_ROOT=/absolute/path/to/qualified-runtime make test-e2e
JIDOKA_RELEASE_RUNTIME_ROOT=/absolute/path/to/qualified-runtime \
  make jidoka-code-production-automation-acceptance
xcrun swift-format lint --recursive --strict Sources Tests
xcrun swift build --configuration release --product JidokaCodeApp
xcrun swift build --configuration release --product JidokaCodeEngineProbe
xcrun swift build --configuration release --product JidokaCodeHerdrHost
git diff --check
```

A timeout, stale log, partial run, malformed command, or zero-test run is a failure. If
`.cleanupFailed` occurs, retain that log and investigate the process identity and cleanup race.
A later quiet run does not replace the failure evidence.

The package source embeds manifest schema 2 at
`Contents/Resources/progressive-production-release.json` immediately before the outer
application signature. It contains the exact source commit/tree, package, helper, askpass,
push-guard, Herdr host, schema, protocol, runtime, and workflow-resource identities. Nested
executable digests cover their final signed bytes. The final application digest is deliberately
not stored inside its own sealed resource manifest because that would be circular: changing the
manifest changes the application signature and therefore the executable bytes. Instead, W7
freezes the final signed application digest as external package evidence, the activation binds
that digest, and the runtime rehashes the installed final executable before accepting it. The
runtime boundary also strictly validates the final app, nested code, and resource seal.

An identity-signed package requires a clean worktree and records its exact `HEAD` commit and
tree. The ad hoc S1 package is deterministic source testing only: it records the checked-out
`HEAD`, may be built from a dirty test checkout, and is never eligible as an activation or W7
artifact. W7 must regenerate the package from the clean, separately accepted merged commit.

## Installed but stopped qualification

This step is for a separately authorized future installation gate. It is documented here but
must not be run against production during source delivery. The application must be quiesced,
the database checkpointed with no `-wal` or `-shm` sidecar, schema 10, paused, and have no open
rollout lane.

```sh
JIDOKA_RELEASE_RUNTIME_ROOT=/absolute/path/to/qualified-runtime \
  ./scripts/progressive-production-rollout-preflight.sh \
  --stage installed \
  --source-root /absolute/path/to/exact-merged-source \
  --expected /absolute/path/to/exact-merged-source/docs/operations/progressive-production-rollout-expected.json \
  --application "/Library/Application Support/JidokaCode/Applications/Jidoka Code.app" \
  --database "/Users/USER/Library/Application Support/JidokaCode/jidoka-code.sqlite3"
```

The installed preflight uses an immutable read-only SQLite connection. It verifies version,
schema, pause, no active lane, and byte-for-byte database stability while comparing provider,
mutation-intent, and Git-read reservation counts before and after. Its source inventory proves
that it has no credential-opening or network-capable command.

## Preview contract

Preview is read-only but may disclose repository content to the local application. Remote
preview itself therefore requires explicit read authority with exact repository identity,
request/page/byte caps, and, for PR review, exactly bounded Git fetch permits. It performs no
provider call and no mutation.

An exact preview must include:

- repository UUID, GitHub node ID, owner, name, default branch, and all enable flags;
- object node ID, number, durable revision key, current job step, and canonical input digest;
- the relevant head, base, plan, narrative, and label-state digests;
- the exact existing job, except that an initial PR review, triage, or planning job may be
  created atomically at activation with its canonical first step;
- complete queue, recovery, mutation, and outside-scope inventory digests;
- release executable and resource identities, configured GitHub account and author ID;
- every missing workflow label definition and ordered approved-command binding;
- finite budgets and an absolute expiry.

Authenticated GitHub validation checks identity, repository node, complete pagination,
object state, labels and definitions, branch base, title/body/comments, and deterministic
candidate order. PR validation also compares the complete REST commit order with two narrow
Git fetches: the exact default-branch base and `refs/pull/N/head`. A redirect, truncation,
identity mismatch, conflicting label, changed candidate, or changed byte invalidates preview.

The CLI transports canonical JSON as strict base64. The UI is preferred because it renders the
target and predicted effects. Equivalent CLI shapes are:

```sh
"/path/to/Jidoka Code.app/Contents/MacOS/Jidoka Code" \
  --rollout preview-exact BASE64_CANONICAL_INPUT

"/path/to/Jidoka Code.app/Contents/MacOS/Jidoka Code" \
  --rollout activate-exact lowercase-authorization-uuid \
  BASE64_EXACT_PREVIEW_JSON exact-preview-sha256
```

Activation accepts only the exact canonical preview bytes and the displayed SHA-256. It
revalidates release identity, local state, remote state, job phase, command plan, and all
bindings immediately before one atomic activation transaction. Do not transcribe or rebuild
the preview between inspection and activation.

## Stage ceilings

| Stage | Provider sessions per job | Required phase boundary | Remote mutations |
| --- | ---: | --- | --- |
| `prReview` | 4 | exact open PR and commit narrative | one bounded review marker batch |
| `issueTriage` | 1 | unlabelled exact issue and base | previewed labels, marker, one verdict |
| `implementationPlan` | 15 | `claimReady` or authorized replan | claim and planning outcome only |
| `implementationExecute` | 15 | durable frozen plan at `orchestrate` or `claimApprovedPlan` | approved commands, create-only branch, PR, link, QA |
| `generatedPRReview` | 4 | append-only generated child link | one bounded review marker batch |

These are ceilings, not defaults and not transferable pools. Every effect kind also has its own
count. The canonical envelope records both its entry stage and current durable step. A missing
label or approved-command list that exceeds its corresponding budget is invalid. GitHub and
Git send authority is reserved atomically with `markSendStarted`. Commands bind order, command
definition, frozen plan, workspace head, and round. Provider permits bind workflow, role,
round, nonce, artifact, plan, narrative, resource, profile, and session directive.

Budget consumption is append-only. Every reservation appends one cumulative usage-ledger row
inside the same transaction; admission and status read only the latest row. The database budget
triggers use the same latest-row rule, so authorization cost does not grow with reservation
history. Reservation identity and creation time are immutable, and an update timestamp may
advance only together with a valid state transition.

## Planning and execution handoff

For a simple or moderate plan, planning persists the frozen plan, records the planning step,
releases the repository lease, and leaves the same job queued at `orchestrate`. No source
command, provider orchestration, branch publication, or PR creation can continue under the
planning authorization.

For a complex plan, Jidoka Code publishes the exact plan, releases claim and workspace, and
waits for a human-owned `plan:approved` label. Approval alone cannot resume work. A fresh
execution preview binds plan digest, issue revision, base, approval label state, and durable
`publishPlan` waiting boundary. Activation revalidates those bytes before the job advances to
`claimApprovedPlan`. If any bound input is stale, only the stale approval is consumed and the
job returns to separately authorized planning.

## Stop, drain, and recovery

`Stop and drain` first closes in-memory admission, then records draining. New provider,
command, read, Git, GitHub, discovery, lease, and child-job reservations fail immediately.
Admitted work may settle, and only already-started uncertain effects retain exact readback.

```sh
"/path/to/Jidoka Code.app/Contents/MacOS/Jidoka Code" \
  --rollout stop authorization-uuid activation-preview-sha256 600000
```

If all permits settle before the deadline, the application pauses and records a terminal
scope. A timeout or uncertain effect records `recoveryRequired`; it never reports a false stop.
On startup, any interrupted nonterminal lane also becomes recovery-required before scheduler
recovery.

Recovery preview is read-only and names the same authorization, job, outstanding reservations,
remaining budgets, and checkpoint. Execution requires confirmation of those exact canonical
bytes:

```sh
"/path/to/Jidoka Code.app/Contents/MacOS/Jidoka Code" \
  --rollout preview-recovery authorization-uuid prior-preview-sha256

"/path/to/Jidoka Code.app/Contents/MacOS/Jidoka Code" \
  --rollout execute-recovery BASE64_RECOVERY_PREVIEW exact-recovery-sha256
```

Never resolve recovery by deleting evidence, replenishing a budget, changing a binding, or
running the old binary against schema 10.

## Finite promotion

Finite windows are outside source qualification and require separate live authorization. A
window is allowed only after an accepted exact receipt for the same repository and stage, with
zero unresolved effects. It fixes deterministic candidates, future-object bounds, job cap,
effect caps, expiry, repository configuration, release identity, and concurrency one. It
cannot cover execution or generated review and cannot borrow unused authority.

Stop before promotion if any candidate set, repository flag, release/resource/profile digest,
pagination result, or durable inventory changes. Stop before merge, deployment, generated-PR
merge, rollback, or historical cleanup. Each is a new decision with its own evidence.

## Review and delivery gate

After the protected-child permit carrier works and provider use is separately authorized,
route fresh artifact-only reviews to `pi-forge.architecture-reviewer`,
`pi-forge.security-reviewer`, `pi-forge.database-reviewer`, and
`pi-forge.test-reviewer`. Verify findings against current source and fix every supported
Critical or Major before rerunning all final gates.

If any reviewer is unavailable, source can remain implemented and locally verified, but it is
not review-complete. Do not commit, push, open the source PR, merge, sign, or begin W7 while the
required review gate remains incomplete.
