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

## Preserved state

Migration and rollout operation preserve every historical job, run, result, mutation intent,
session, descriptor, backup, canary record, and evidence artifact. Never edit the database
with `sqlite3`, delete an uncertain mutation, reset a job, or rewrite rollout tables. Schema 10
is append-only where evidence is involved and migration requires the repository backup path.

Already-started uncertain GitHub and Git effects may be reconciled read-only after stop,
expiry, or revocation. Each readback is bound to the original mutation intent, repository,
object, target, and the operation-specific lookup class. Every fresh read outside that exact
readback, provider launch, command, send, ref creation, or child launch is denied.

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

The package source embeds `Contents/Resources/progressive-production-release.json` immediately
before the outer application signature. It contains the exact source commit/tree, package,
helper, Herdr host, schema, protocol, runtime, and workflow-resource identities. Helper and
Herdr host digests cover their final signed bytes. The final application digest is deliberately
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
