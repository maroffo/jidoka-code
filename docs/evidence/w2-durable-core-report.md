# W2 durable core evidence report

Status: **implemented and locally verified, ready for PR review**

Date: 2026-08-06

This report covers only W2. It does not claim GitHub, Git transport, Pi production workflow, UI, installer, or canary completion. No provider call, credential access, or GitHub runtime mutation was performed while implementing W2.

## Scope implemented

- system SQLite 3 linkage without a third-party Swift dependency;
- `SQLiteStore` actor as the single writer;
- WAL, foreign keys, 5-second busy timeout, strict schema, migration ledger, transactional migrations, pre-migration backup, explicit backup, and typed bindings/rows/transactions;
- durable jobs, append-only steps/transitions/reconciliation events, event-key idempotency, persisted deadlines and attempts;
- total runtime and startup recovery state machines over every declared state/event pair;
- contract-independent logical identity and object dispositions for in-flight, attributed, ambiguous, human-authorized retry, and superseded work;
- claim generations with distinct ready/approved labels and attribution-before-replan stale approval ordering;
- repository lease generations and global semaphore backed by SQLite;
- locked priority queue plus observation-only starvation metrics;
- scheduler timing with an injected clock, monotonic system-clock projection, interruptible sleeping loop, 600-second tick, immediate debounce bounded under 30 seconds, overlap coalescing, pause/resume, wake/network triggers, and durable per-repository backoff from 60 through 1,800 seconds;
- startup recovery before the first scheduler trigger;
- persistent repository toggles, four model profiles, pause state, and bounded max concurrency with no credential field;
- generated-path artifact storage with SHA-256 verification, containment checks, exclusive writes, 0700 directories, 0600 files, and a secret-forbidden classification.

## Executed falsifiers

- invalid, duplicate, interrupted, and newer-than-supported migrations;
- foreign-key violations and update/delete attempts against append-only tables;
- transaction rollback and embedded-NUL text round trip;
- every unlisted runtime state/event pair;
- retry before the persisted deadline and success without exact acceptance evidence;
- restart from every persisted job state, including stale lease cleanup and late-read scheduling;
- duplicate and cross-job transition event keys, mismatched step kinds, contract/app/skill version bumps, ambiguous rediscovery, and human retry generation;
- stale approval attempting to replan before mutation attribution;
- repository collision and global concurrency saturation across a deterministic 200-operation property test;
- priority starvation without priority promotion;
- periodic, startup, pause/resume, overlap, sleeping-loop interruption, wake, network regain, rate-reset, and backoff timing using a virtual clock;
- invalid repository/branch/model configuration and token-shaped model values;
- artifact traversal, symlink substitution, digest mutation, collision overwrite, missing job, database failure cleanup, oversized content, and secret classification.

## Verification

Executed after the final W2 source edit:

```text
make check
make test-e2e
xcrun swift test --sanitize=address
xcrun swift test --sanitize=thread
```

Results:

- strict Swift format, debug build, release build, XCTest, and all 75 Swift Testing cases passed;
- AddressSanitizer passed all 75 cases;
- ThreadSanitizer passed all 75 cases;
- copied ad-hoc packaged application execution from `/`, signature verification, resource mutation falsifiers, and cleanup passed;
- no provider request was issued.

## Remaining risks and exclusions

- W2 types are not yet wired into the selected LaunchAgent engine; that integration belongs to later workstreams.
- W3 must provide real GitHub request and mutation reconciliation implementations using these durable contracts.
- W4-W6 must connect repository, command, Pi, and job coordinators without weakening the state or disposition invariants.
- W7-W9 must provide UI, lifecycle integration, installation, final review, and an explicitly authorized canary.
- The provider ledger remains exhausted at 19 of 19. No W2 verification requires a provider request.
- Review was parent-owned and local. No independent model reviewer was launched because further provider calls are not authorized.
