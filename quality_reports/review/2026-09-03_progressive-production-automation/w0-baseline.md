# W0 merged baseline and authority-gap evidence

Captured on 2026-09-03 before any production source edit. No production database,
credential, provider, GitHub object, Git ref, installation, or historical evidence was
read or mutated.

## Source authority

- Repository: `maroffo/jidoka-code`
- Implementation branch: `feat/progressive-production-automation`
- Base and initial HEAD: `09e52bc47289205d17bc1bae99ff89cd33a0643b`
- Base tree: `cfeab7e8ec58e1dac091547615a3815dbb6977f9`
- Required ancestor: `b6cb62ba7d53d5de740d6e2983656f911db7bd1c`
- Approved plan source: `c728eb55af4a2af5c5c27d354ba635c9180821f5`
- The merged plan at `09e52bc4` is byte-identical to the approved plan source.
- The worktree was clean, non-primary, and exactly equal to `origin/main` before W0 edits.

## Frozen source inventory

- Database schema: 9, backed by migrations 1 through 9.
- Engine protocol: 11.
- Package identity: version `0.1.1`, build `2`.
- Herdr API protocol: 20; schema digest
  `c48f1f54ee0150ca27e11fd44455fe94aeadb20fdf4e4a62393ed822a4e5b150`.
- Release runtime manifest digest:
  `fe15573a58a4604a3695b092ba8b07ae2432da7b7f07743a8d54a4421ab3aa83`.
- Workflow resources digest:
  `230c9a45b9dd53443837166c6e8b60adac67d3bfeb32249de8ca5228f1e1357d`.
- Qualified runtime: Node 26.7.0 and Pi 0.84.2, resolved only through
  `JIDOKA_RELEASE_RUNTIME_ROOT` and `scripts/qualified-runtime-node.sh`.
- Toolchain: Xcode 26.6 build 17F113, Apple Swift 6.3.3, swift-format 6.3.0.
- Tracked source inventory: 310 paths.
- Deterministic provider fixtures remain the four existing JSONL files under
  `Tests/JidokaCodeCoreTests/Fixtures/Pi`; no live provider was invoked.
- Historical evidence remains at the paths named by the approved ExecPlan, including
  `/Users/maroffo/JidokaCode-live-canary-evidence/20260902-pr1-ninth-terminal-theme`.
  W0 did not open or change those bundles.

## Pre-fix control run

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter JobCoordinatorTests
```

Result before the fail-closed assertions were added: exit 0, 13 Swift Testing tests
passed. In particular, the old expectations confirmed all three unsafe coordinator
behaviors: serial queue walking, flag-drift dispatch, and paused recovery dispatch.

The unchanged `EngineServiceTests` control passed 21 tests. The unchanged
`IssueImplementationJobWorkflowTests` control passed 16 tests. These controls prove
the red results below are introduced by the new safety assertions, not by a stale or
malformed test invocation.

## Preserved pre-fix failures

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter JobCoordinatorTests
```

Result: exit 1, 14 tests executed, three W0 tests failed with six issues:

```text
W0: an unscoped pass cannot dispatch two serial queued jobs
  Expectation failed: await fixture.workflows.order().isEmpty
  Expectation failed: jobs.allSatisfy { $0.state == .queued }
W0: repository flag drift leaves an already queued job inert
  Expectation failed: (await fixture.workflows.order()).isEmpty
  Expectation failed: job.state == .queued
W0: pause suppresses unbound recovery as well as discovery
  Expectation failed: job.state == .reconciliationQueued (observed .blocked)
  Expectation failed: recovery workflow was not invoked
```

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter EngineServiceTests
```

Result: exit 1, 21 tests executed, the W0 onboarding test failed with three issues:

```text
W0: onboarding completion remains paused without rollout authority
  observed EngineUIState.paused == false
  observed persisted app_settings.paused == false
  observed dispatch admission == true after repository addition
```

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter IssueImplementationJobWorkflowTests.endToEndImplementation
```

Result: exit 1, one test executed:

```text
Expectation failed: an error was expected but none was thrown
```

The unexpected success was the direct lease of the implementation-created PR-review
job without separate generated-review authorization.

## Pagination boundary

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter GitHubHTTPTests.paginationAndCredentialBoundary
```

Result: exit 0, one test passed. The broker fetched pages 1 and 2 and returned all 101
pull requests. This confirms the approved plan's statement that existing broker
pagination is complete; W1-W6 must preserve it and must not introduce a page-one
preview shortcut.
