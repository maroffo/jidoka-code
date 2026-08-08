# W5 Pi runner and app-versioned workflow evidence report

Status: **implemented, independently remediated, and locally verified; source-control promotion remains unauthorized**

Date: 2026-08-07

This report covers only W5. It does not claim production job coordinators, live model quality, GitHub or Keychain access, UI integration, installer behavior, publication, or merge. Verification used isolated private roots, empty authentication, `PI_OFFLINE=1`, deterministic transcripts, and local repositories. No provider request, real credential access, GitHub request, remote mutation, commit, push, or Apple Development signing was performed.

## Baseline and scope

W5 was created in a dedicated worktree from fetched `origin/main@23037624be0c7546d4c5d43da5846d2466ff7023`. That SHA remains the exact merge-base. The index remains empty.

Implemented surfaces:

- exact Pi `0.84.0` package identity plus complete package-tree inventory and digest, not a critical-file subset alone;
- exact Node `26.6.0` executable plus the ordered non-system Mach-O dependency closure, including missing, extra, changed, symlinked, and earlier `@rpath` shadow rejection;
- a bounded full-duplex `posix_spawn` RPC runner with `F_SETNOSIGPIPE`, explicit `EPIPE`, monotonic deadlines, output bounds, abort acknowledgement, final exit-status validation, and process-group plus observed-descendant cleanup;
- an exact Pi `0.84.0` RPC lifecycle requiring prompt acceptance, `agent_start`, initial `turn_start`, paired user and assistant messages, causal tool start/update/end and tool-result messages on every turn, then terminal `turn_end`, `agent_end` with explicit `willRetry: false`, and exactly one `agent_settled`;
- a canonical workflow executor that resolves the attested runtime, re-inspects packaged resources, reconstructs exact argv and environment, validates session mode, role tools, command provenance, private runtime configuration, workspace, nonce, and artifact identity, and rejects arbitrary Node scripts or non-bundled provenance before the runner;
- app-owned `jidoka_code_read`, `jidoka_code_write`, and `jidoka_code_edit` tools with exact paths, no aliases, no-follow final open, component symlink rejection, multiply linked regular-file rejection, bounded UTF-8, unique edit matching, and atomic replacement;
- fixed workspace status, diff, log, show, literal search, and bounded list operations; Git queries require a canonical internal `.git` directory, recursively contained metadata, no metadata hard links/symlinks, `commondir`, alternates, includes, `core.worktree`, or bare/worktree indirection, an exact benign local-config allowlist, then explicit `--git-dir` and `--work-tree`; executable filter/diff/alias and every unknown config key are rejected before Git; no Pi built-in read/find/grep/write/edit, no tool auto-download, no shell, no remote operation, and case-insensitive pruning of `.git`, `.pi`, and `.agents` at every depth;
- app-versioned extension, pure contract module, exact resource manifest, primary workflow skills, independent reviewer skills, and synthesizer; Swift reads every manifest/resource path component with descriptor-relative no-follow opens and both Swift and JavaScript reject symbolic ancestors and multiply linked resource files;
- strict PR review, issue triage, planning, and orchestration schemas and deterministic fake-provider replay;
- exact PR base/head and complete commit-set agreement from REST and fetched Git, followed by connected oldest-first topological commit-narrative binding, including fork-and-merge histories, with deterministic preservation of every independent veto and Critical/Major finding;
- deterministic complexity classification with a digest covering classification, reasons, reporters, facts, evidence, disagreement, and downgrade rejection;
- candidate-plan review followed by a final frozen-plan identity that covers artifact, exact plan bytes, classifier version, ordered command definitions and source digests, complete complexity decision, and exact role-result approval records;
- orchestration that requires the complete frozen command order, executes no command after a writer veto, stops at the first failed command, and requires all reviewer verdicts, findings, and fresh command evidence to pass.

## Independent-review remediation

Fresh read-only reviews over the dirty W5 tree reproduced blockers that the earlier green gates did not cover. W5 was treated as blocked until each finding received a local falsifier and the complete matrix was rerun.

Closed blocker classes:

1. stdin close could terminate the engine with SIGPIPE;
2. Pi built-in filename aliases could read through an alternate symlink outside the workspace;
3. planning reviewers did not receive or approve the exact textual plan and canonical command definitions;
4. Pi built-in find/grep could bootstrap unattested executables;
5. PR synthesis could omit or downgrade independent Major findings;
6. orchestration could execute a command subset, ignore reviewer or writer vetoes, or continue after failure;
7. terminal events could precede prompt acceptance, omit explicit retry state, arrive after settlement, or hide a non-zero exit;
8. Node and Pi runtime attestation covered only a subset of executed bytes;
9. case variants of `.git`, `.pi`, and `.agents` could bypass file or command paths;
10. PR commit narrative could end before the fetched head;
11. replay could ignore fresh/resume identity;
12. dyld could choose an earlier unpinned `@rpath` library;
13. a late child in the dedicated process group could survive after the leader exited;
14. the workflow preparer could supply an arbitrary executable, argv, provenance, environment, or runtime configuration;
15. the parser rejected Pi's real mandatory tool-result message and turn suffix after `jidoka_code_result`;
16. status/diff/search/list could expose reserved metadata, including mixed-case nested paths;
17. truncated transcripts could omit the mandatory agent, turn, initial user, assistant, or nonterminal tool-result lifecycle;
18. an opaque caller-supplied 64-hex planning decision could reach orchestration without complete role approvals;
19. short process-fixture deadlines could expire before the intended falsifier became ready under suite load;
20. a hard link inside the workspace could expose an external inode through read/search;
21. S8 preflight output mislabeled four offline command-profile checks plus a static 15-role matrix and 15 historical ledger settlements as 15 current role executions;
22. a structurally consistent `humanOwned` decision could be frozen and accepted by orchestration/command execution despite the hard rail;
23. direct-parent adjacency rejected valid connected non-linear PR histories;
24. a lexical bundled skill path could traverse a symlinked ancestor to exact bytes outside the resource root;
25. Git diff could expose external bytes through a tracked workspace hard link even though direct read/search rejected it;
26. Git-backed queries and command gates could discover an external repository through a `.git` file, `core.worktree`, common directory, or object alternates;
27. a topologically valid narrative subset ending at the exact head could omit fetched or REST-visible PR commits;
28. equal complete-looking commit sets could still describe a graph unrelated to the declared base;
29. the runner could observe a clean child exit between its first nonblocking drain and `waitpid`, then reject settlement bytes already queued in the pipe;
30. a repository-configured clean filter could execute a native command during the supposedly read-only Git diff query;
31. Git read/stage commands could execute `post-index-change` through default or caller-approved hook paths.

The exact Pi suffix is derived from and tested against the attested Pi `0.84.0` agent-loop contract. A live provider-backed W5 result-tool turn was not rerun because the authorized provider ledger is exhausted.

## Executed falsifiers

Permanent Swift and JavaScript tests cover:

- SIGPIPE/EPIPE, a non-reading child with a 2 MiB prompt, timeout plus acknowledged abort, malformed stdout, non-empty stderr, non-zero exit after settlement, SIGABRT, SIGTERM-handler exit 7, late event, late same-PGID child, and descendant cleanup; the eight process tests also passed ten consecutive stress runs;
- prompt/result causality, response correlation, mandatory agent/turn/user/assistant phases, complete nonterminal tool-result turns, tool allowlist and start/update/end correlation, sole terminal tool call, explicit `willRetry: false`, settlement cardinality, and post-settlement rejection;
- arbitrary executable/argv, missing canonical flags, non-bundled command provenance, wrong session mode, fixture policy in production, wrong role tools, changed runtime configuration, and result identity;
- exact-path `@` names, straight versus curly apostrophe, final symlink, ancestor symlink, traversal, absolute escape, case-insensitive reserved components, read-only writes, unapproved prefixes, and changed file identity;
- root and nested mixed-case metadata in status, diff, search, and list; a workspace hard link to an external sentinel is rejected by direct read, search, and diff before Git; `.git` file indirection, `core.worktree`, common metadata, object alternates, and a marker-writing clean filter fail before model-visible Git output or native execution; hostile option-like path `-delete` remains data and survives;
- whole Pi package-tree byte mutation, inventory change, permissions/type framing, escaping symlink, workflow-resource final symlink, symbolic ancestor, and external hard link;
- Node executable and dynamic-library mutation, missing/extra closure, duplicate build digest, and earlier unpinned `@rpath` shadow in both Swift and JavaScript fixtures;
- plan text, artifact, command order, command definition, complexity facts/evidence/reporter, complete ordered planning role results, approval digest, candidate-plan rejection at orchestration, structural rejection of every `humanOwned` decision, command subset, command evidence, writer/reviewer veto, and stop-after-failure; Git read/stage force hooks off, read also disables optional locks, while commit executes hooks only when its exact configured path is explicitly approved;
- PR base/head/narrative mismatch, REST/fetched/narrative set mismatch, truncated/disconnected/reordered/base-unreachable narrative, accepted connected fork-and-merge topology, synthesis downgrade, hard-risk downgrade, planning disagreement, round exhaustion, and replay fresh/resume success and mismatch.

## Final local verification

These commands were rerun after the last code and test changes:

```text
make check
make test-e2e
make jidoka-code-test-s4-preflight
make jidoka-code-test-s8-preflight
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --sanitize=address
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --sanitize=thread
git diff --check
```

Observed results:

- `make check`: strict toolchain verification, shellcheck, Node syntax and contract suites, strict Swift format, debug build, release build, XCTest 1 of 1, and Swift Testing **232 of 232 in 38 suites** passed;
- package E2E: copied ad-hoc app execution from `/`, exact resource inventory and hashes, strict nested signatures, offline W5 extension RPC preflight, and mutated extension, runner, attestation, policy, and workflow-resource rejection passed;
- S4 packaged offline preflight: `providerCalls=0`, exact provenance, bounded timeout/abort and ledger checks passed; evidence: `build/evidence/jidoka-code-s4.a6aiGw/`;
- S8 packaged offline preflight: four offline command-profile checks, the fixed 15-role matrix, 15 historical settled S8 ledger records, and `providerCalls=0` passed; it does not claim 15 fresh role prompts; evidence: `build/evidence/jidoka-code-s8.aWuiG1/`;
- AddressSanitizer and ThreadSanitizer each passed XCTest 1 of 1 and Swift Testing **232 of 232 in 38 suites**;
- `git diff --check` passed;
- independent reviewers reproduced scheduling-sensitive process fixtures at 0.2 and 0.3 seconds. Fixture readiness is now emitted before the blocking phase and each relevant deadline is three seconds without weakening timeout, abort, EPIPE, PID, or cleanup assertions. One intermediate ASan matrix first exposed asynchronous fixture writes, then a later run exposed the real exit-observation race: the child could exit after a nonblocking drain while settlement bytes entered the pipe. Fixture events now use synchronous bounded writes, and the runner drains stdout/stderr once more after observing exit before classifying it. The eight-test process suite passed ten consecutive standard and ten consecutive ASan stress runs; fresh full standard, ASan, and TSan matrices then passed;
- one attempted concurrent S4/S8 invocation interfered through their shared package output and cannot support a claim. The reported S4 and S8 evidence paths come from later sequential passing runs.

The canonical provider ledger remained byte-identical at SHA-256 `9bb94a32fac85a75a5365ed4578f205eaf7d4a55eeddf114b16c7cf4f3f79bc5`: schema 1, 19 attempts, all 19 settled, and its adjacent `provider-call-ledger.json.lock` did not exist. Unrelated Pi loop lock files are outside this claim. No twentieth reservation or provider call was made.

## Current identities

- workflow resource manifest: `20362f6bb3e1a961cc15f560513ed25d240c6e1b77b4ce7db0f8258b2c0016be`;
- `jidoka-code.ts`: `3312c65c0cb607f14012a75aad31062eebf817724e807cab4ed4379c31752c0b`;
- extension contract: `1a2a90b0b53bf68ead774b34b3b90045bd1ca8ffacf3f3a462b520a86d6498f8`;
- Pi runtime policy: `eeea3f11e4e352f2b772424dea1dd85273d7af559c6e9e69ff280abac9681f27`;
- admitted Pi package tree: 20,520 entries, `bdc3c69f9ba451d7ea85e1c47868e69c2fedfb9c001f25bc7eecd912792dda1a`;
- Node runtime policy: `fd707070911b53f3930864c3ec6dcfabc7b4440bcf44c3012882751fb99bf906`;
- admitted Node executable: `1ef99ea25fe70c9b67e7efe768ef8ee22148d3cabc703db6131b57aeb617d040`;
- admitted Node non-system dynamic libraries: 25 exact canonical paths and digests;
- runtime attestation module: `a2187f46e1a5e97cf8f87be230382f4bbd235d7c47d31eb933c821d799bd5e9e`;
- packaged S4 profile runner: `a972045017dac2a0ee32478fd4f63ac0c51da7f738acd8994de58df5dfe92f2f`;
- packaged S8 workflow runner: `bba864cfe69d5f5f8ebac05fce1e86da3ff5276577246e612a5003f6bbf7a9cb`;
- issue-triage skill: `c4200a92833135446a61f374467aeb8f35e4a25826fe7b34baa016c206c46f0f`;
- orchestration skill: `4a6f1b39c86b21b820144c5dbb7fea5ea4f8ee4f8c5ea41a0f01a5ab9850ca07`;
- planning skill: `251874083bfba1dd5ed9334200efced1bdab18518fb16e9dd3f43c270456564c`;
- PR-review skill: `7e3af39ff6e211aa9c3d85c935eb7ff991ec88c9f0df9b152df2ef3977fa409b`.

The manifest digest is compiled into the Swift catalog and independently pinned by package and RPC preflights. Every listed extension, policy, and skill byte must match before workflow configuration is accepted.

## Remaining risks and exclusions

- W6 still owns durable job preparation, canonical prompt content, model-profile selection, allowed writer paths, provider authentication, command dispatch integration, mutation intents, and GitHub read-back. For PR review it must supply the complete REST commit set and the independently traversed base-to-head fetched Git set required by W5. W5 now validates the dangerous launch capabilities, but it does not claim an end-to-end production job.
- Live Pi `0.84.0` provider-response fidelity for the remediated W5 result-tool lifecycle was not rerun. The exact installed agent-loop ordering is pinned and replayed offline, but provider authorization remains exhausted at 19 of 19.
- Package verification used ad-hoc signing. No W5 Apple Development same-team rerun was authorized.
- App-owned file operations are bounded and verify canonical identity, but they are not a sandbox against a hostile concurrent same-user process racing filesystem ancestors.
- Process cleanup always terminates the dedicated process group and observed descendants. An unobserved child that performs an immediate `setsid()` remains outside the stated same-user attacker model; the closed W5 tool surface exposes no launcher for it.
- Repository scripts, approved hooks, and writer edits remain same-user native execution boundaries inherited from W4.
- The most likely integration failure is W6 constructing a preparation that does not exactly match the resolver, catalog, runtime configuration, prompt/session directive, and frozen command identity now required by `PiRPCWorkflowExecutor`.
