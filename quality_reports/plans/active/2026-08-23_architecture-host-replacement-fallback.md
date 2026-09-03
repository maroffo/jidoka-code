# Architecture Role-Host Replacement Fallback

**Status:** in-progress
**Origin:** in-session authorization from Max on 2026-08-23 after terminal schema-8 reset ambiguity
**Base:** `feat/settings-guided-configuration` at `7ba8eae88f029df360af01ffa7b5af669d1cfa01`, preserving the existing dirty worktree
**Goal:** Without replaying the unknown pane reset, retire only architecture host `54262` and pane `wM:p2`, create one fresh architecture execution host in the same job tab, and admit exactly q4 for the existing run while `paused=1`, the other three role hosts, and all 155 unrelated queued jobs remain unchanged.

## Analysis (verified 2026-08-23, do not re-derive without new evidence)

### Current behavior
- Production is schema 8 and `paused=1`. The exact canary remains `runningPi`; q1 is `RUNTIME_TIMEOUT`, q2/q3 are `HERDR_TRANSACTION_FAILED`, q4/q5 are absent, and the fourth retry authorization is append-only.
- The exact schema-8 preview succeeded once. Report SHA is `6d6a65499cc7871e88c93fabc95b09b479999f460f4534b7764106c288ff7cf8`; retry evidence is `ab13e5502f867557f077535aeb227555ccf8f0210db7f7e1d3c837675d6bfea9`.
- The sole reset execution produced intent `reset-deeb91d0-c788-4301-b5f5-cff2a9032198` in terminal `unknown`. Herdr logged one successful `pane.clear_agent_authority`, then an `agent.rename` error. The client exited 0 with recovery-required semantics, but no q4 row was inserted.
- Read-only post-incident Herdr evidence still reports pane `wM:p2`, terminal `term_65952db62a40982`, revision `3`, stale token SHA `9a0952938abe3db94e9d949cb36c66a891ba7777a009edb1f443b3f465c6cc01`, and no registered agent. Audit SHA is `f855da9097441503472e85c912f881f157475381fdf6666057927f0651c5e1d7`.
- `HerdrRoleHostDescriptorStore.recordStart` is deliberately write-once and `HerdrRoleHostRuntime` begins at command sequence 1 (`Sources/JidokaCodeCore/Herdr/HerdrRoleHostRuntime.swift:212-442, 546-610`). Reusing the same host ID would collide with `host-start.json` and risk replaying q1-q3.
- `herdr_role_hosts` has `UNIQUE(job_id, generation, role)` and `pi_run_launches.role_host_id` references it (`Sources/JidokaCodeCore/State/DatabaseSchema.swift:543-621`). A second architecture row cannot be inserted without changing that table or adding an explicit execution-host model.
- Schema-8 q4 authority accepts only attributed prime/reset intents and the current role-host identity (`Sources/JidokaCodeCore/State/DatabaseSchema.swift:2136-2324, 2460-2524`). Both existing authority intents are immutable `unknown` and cannot authorize another mutation.
- Runtime q4 preparation currently combines credential projection, remote authority mutation, local attribution/q4 insertion, and role-host enqueue (`Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift:2870-3120`). A new fallback must be a distinct protocol, not replay of `execute-pi-retry`.

### Root cause or design gap
Schema 8 can recover one stale pane only by resetting authority on the same physical role host. Once that compound remote operation passes `pane.clear_agent_authority` but fails later, the immutable `unknown` intent correctly prevents replay, yet the durable model has no first-class way to replace one physical role host while preserving the old host row and q1-q3 lineage. Reusing the old ID, creating a new run, or recreating the full topology would either blur physical identity, replay historical commands, or violate the preservation boundary.

### Scope
- In: schema-9 replacement authority; explicit physical execution-host identity; preview/execute/recovery CLI; architecture-only host/pane retirement and recreation; q4 authority; startup/crash handling; package migration and rollback evidence.
- Out: replaying clear/report/metadata/rename on `wM:p2`; changing q1-q3 or either unknown intent; replacing security/test/synthesis hosts; Resume; generic terminal input; direct-RPC fallback; scheduler/discovery changes; q5; unrelated job effects; commit/push/promotion.
- Recover excluded context from: `quality_reports/plans/active/2026-08-17_single-job-canary.md`, `live-preview-evidence`, and `live-reset-q4-evidence/audit.json` in the v11 UAT artifact directory.

### Candidate approaches
| Approach | Decision | Evidence and trade-off |
|---|---|---|
| Replay reset/rename on `wM:p2` | rejected | Clear is non-idempotent, intent is terminal `unknown`, and replay violates the incident boundary. |
| Reuse the same role-host ID and descriptor directory | rejected | Start record is write-once and runtime sequence restarts at 1, risking q1-q3 replay. |
| Recreate the entire topology/new generation | rejected | Requires retiring or replacing the three preserved hosts. |
| Create a new Pi run | rejected | Loses the exact q1-q3/four-authorizations causal chain and conflicts with one logical architecture role. |
| Rebuild `herdr_role_hosts` to relax its unique constraint | rejected for now | Highest migration risk because existing launch foreign keys reference the table. |
| First-class replacement host plus explicit `execution_role_host_id` on q4 | chosen | Preserves old host row/FKs and q1-q3, gives q4 an unambiguous new physical owner, and avoids rewriting the existing host table. |

### Independent opinion
- Three broad filesystem reviewers timed out and are not approval evidence.
- A completed forked-context oracle endorsed architecture-only retirement/recreation, rejected hiding the replacement behind the old `role_host_id`, and required a first-class replacement identity or explicit execution-host reference. This plan adopts the explicit execution-host model.

## Locked decisions

| # | Decision | Choice | Evidence/rationale | Revisit if |
|---|---|---|---|---|
| 1 | Replay | Never replay reset, clear, report, metadata, rename, or existing `execute-pi-retry` | Both the durable intent and wrapper claim are terminal unknown/do-not-retry. | Never for this incident. |
| 2 | Physical identity | Add a first-class replacement architecture host with a new host ID and descriptor directory | Preserves old PID/pane/row and q1-q3 physical attribution. | Migration proves a safer table-rebuild design. |
| 3 | Launch identity | Add nullable `execution_role_host_id` to launches; only q4 may set it to the replacement host | Avoids silently changing the meaning of legacy `role_host_id`. | A future schema removes the legacy column comprehensively. |
| 4 | Descriptor protocol | Replacement bootstrap descriptor schema 3 binds predecessor ID, incident evidence, and initial command sequence 4 | New runtime cannot read or replay commands 1-3. | Herdr adds a native host handoff primitive. |
| 5 | Remote creation | After creating the one fresh replacement pane, use only a private typed, attested/socket-pinned `pane.split` → `pane.send_text` (exact app-constructed POSIX-shell-escaped role-host argv prefixed with `exec`) → `pane.send_keys` (exact `enter`) sequence. No caller controls command, text, or keys; no public generic Engine/CLI surface exists. | Herdr protocol 19 has no native spawn/run RPC, while `layout.apply` would touch the preserved hosts. Every dynamic identifier/path is strictly validated and quoted, credentials are absent, and any ambiguity after durable `sendStarted` is terminal unknown. | Herdr adds an atomic split-and-exec API. |
| 6 | Point of no return | Persist replacement intent `sendStarted` before old-host shutdown, pane close, split, run, or prime | Any ambiguity is durable `unknown` and never replayed. | Herdr provides idempotency/CAS for the whole operation. |
| 7 | Local cutover | One SQLite transaction attributes replacement, records old host stopped, inserts first-class replacement host, appends exact event, and inserts q4 with its planned ID | Local state either exposes the complete replacement/q4 authority or none of it. | None. |
| 8 | Enqueue recovery | A crash after prepared q4 may recover only by publishing/enqueuing that exact durable q4; it never reruns replacement effects | Existing prepared/enqueued recovery can be specialized safely. | Canonical q4 result already exists. |
| 9 | Preserved hosts | PIDs `54263`, `54264`, `54265`, argv, text vnode, descriptors, pane/terminal IDs, and DB rows remain exact | User authorized only architecture replacement. | Max separately broadens scope. |
| 10 | Scheduler | `paused=1` at preview, send, cutover, enqueue, settlement, install, and restart boundaries | Prevents unrelated dispatch. | Never during this fallback. |
| 11 | Failure | Any uncertain shutdown/close/split/run/prime/cutover becomes terminal unknown; no replacement attempt is auto-created | Remote operations lack transactional atomicity. | A separately designed broader fallback is authorized. |
| 12 | Rollback | Schema 9 requires an exact schema-8 backup and a schema-9-compatible package rollback decision; old binaries must fail closed on schema 9 | v11 cannot safely operate on a newer schema. | Before production installation. |

## Acceptance criteria
- [ ] A read-only replacement preview binds the exact incident audit SHA, v11 preview/retry evidence, q1-q3, four authorizations, both unknown intents, old host/pane/process/socket, preserved hosts, anchor pane, planned replacement host ID, and planned q4 ID.
- [ ] Execute rejects any changed field before preparing an intent or credential.
- [ ] Exactly one replacement intent can reach `sendStarted`; every ambiguous remote failure becomes `unknown` and disables replay.
- [ ] Only PID `54262` and terminal/pane `wM:p2` are retired. PIDs `54263-54265` and all their durable/process evidence remain unchanged.
- [ ] Replacement runtime has a new ID/directory/start record, exact legacy executable bytes, same workspace/tab, a fresh pane/terminal, and initial command sequence 4. Commands 1-3 are structurally impossible.
- [ ] Fresh-pane agent prime/readback binds exact alias, tokens, no agent session, socket identity, and replacement process before local cutover.
- [ ] One transaction attributes replacement, stops predecessor locally, inserts the replacement host, writes exact replacement event, and inserts only planned q4 with `execution_role_host_id` set.
- [ ] q4 enqueue/recovery targets only the replacement host. q5 remains denied in Swift and SQL.
- [ ] Credentials are provider-scoped, `0600`, symlink-safe, absent from argv/environment/logs, and removed on every pre-child failure; cleanup failure is `CREDENTIAL_CLEANUP_FAILED`.
- [ ] No unrelated job row, lease, Pi run/launch, command, mutation, job step, provider call, or GitHub effect changes.
- [ ] Schema 8 to 9 migration succeeds on an exact production copy, preserves all old rows/FKs/triggers, creates a `0600` schema-8 backup, and fails atomically under injected faults.
- [ ] Startup handles prepared/enqueued q4 without replaying replacement and never dispatches another job.
- [ ] Fresh full verification and independent architecture/security/database/test review contain no unresolved Critical or Major finding.

## Workstreams

### W0: Reproduce
- [ ] Add a failure test matching `clear ok, report/metadata accepted, rename error`, proving reset becomes unknown, q4 remains absent, and replay is denied.
- [ ] Add tests proving same-ID restart collides/restarts at sequence 1 and therefore cannot be used.

### W1: Schema-9 authority
- Scope: `DatabaseSchema.swift`, `PiRunStore.swift`, `JobCanary.swift`, store tests.
- [ ] Add replacement intent kind/authority, first-class replacement-host table, nullable launch `execution_role_host_id`, exact candidate views/triggers, identity immutability, state transitions, q4-only authority, and q5 denial.
- [ ] Preserve schema-8 data and foreign keys on exact-copy migration.

### W2: Descriptor and Herdr protocol
- Scope: `HerdrRoleHostRuntime.swift`, topology protocol/socket client, protocol tests.
- [ ] Add descriptor schema 3 with initial sequence 4 and predecessor/evidence binding.
- [ ] Add the private typed split/send-text/send-enter operation with per-request socket re-attestation, strict response validation, and tests proving arbitrary terminal input is unrepresentable.
- [ ] Prove normal schema-2 hosts remain byte/behavior compatible.

### W3: Replacement workflow
- Scope: `HerdrPiWorkflowExecutor.swift`, `ProductionEngineJobRuntime.swift`, engine protocol/service.
- [ ] Add read-only candidate, execute, terminal unknown handling, exact process/pane verification, atomic local cutover/q4, and prepared-q4 recovery.
- [ ] Keep credential lifetime and cleanup closed.

### W4: CLI and operational evidence
- Scope: `JobCanaryCLI.swift`, app entry point/tests, package inventory if needed.
- [ ] Add closed preview/execute commands with bounded timeout and exact planned IDs/incident evidence.
- [ ] Return structured reports that distinguish replacement-only, q4 prepared/enqueued/settled, and terminal unknown.

### W5: Verification and delivery
- [ ] Focused schema/store/protocol/runtime/service/CLI tests.
- [ ] Strict recursive swift-format, `git diff --check`, release app/helper/host build, and complete serialized Swift suite after the final edit.
- [ ] Independent architecture, security, database, and test review; fix every verified Critical/Major within budget.
- [ ] Build/notarize/audit a v12 UAT package, exact-copy migrate schema 8 to 9, and prepare a separately reviewed production wrapper before any live mutation.

## Verification matrix

| # | Surface/path | Scenario | Expected evidence | Depth |
|---|---|---|---|---|
| 1 | Candidate | exact incident and every one-field drift | only exact evidence previews | behavior+edge+error |
| 2 | Migration | schema8 copy, every statement fault, reopen backup | atomic schema9 or unchanged schema8 | behavior+error |
| 3 | Descriptor | normal schema2, replacement schema3, lower/higher sequence | replacement starts only at 4 | behavior+edge |
| 4 | Remote retirement | shutdown/close success, timeout, response loss | exact proof or terminal unknown | behavior+error |
| 5 | Split/run | changed anchor, extra pane, wrong PID/argv/text/socket | no cutover/q4 | behavior+error |
| 6 | Prime | report/metadata/rename/readback faults | attributed only after exact readback | behavior+error |
| 7 | Cutover | transaction faults at each statement | replacement+q4 all-or-none | behavior+error |
| 8 | Enqueue/restart | crash before/after DB enqueue/file/start/result | exact q4 recovery, no remote replay | behavior+error |
| 9 | Credentials | every pre-child and cleanup fault | no residual credential or explicit cleanup failure | behavior+error |
| 10 | Isolation | preserved hosts and 155 jobs under fast q4 success/failure | byte/logical equality outside canary | behavior+error |
| 11 | q5/Resume | direct Swift and raw SQL attempts | denied before effect | behavior+error |
| 12 | Regression | ordinary role hosts/workflows/schema8 migration chain | unchanged behavior | regression |

**Coverage:** 12/12 identified authority and failure families. Gap: live production replacement remains excluded until a notarized package and reviewed wrapper exist.

**Exhaustiveness rationale:** The matrix spans candidate evidence, migration, descriptor sequencing, each irreversible remote step, local transaction, enqueue/restart, credentials, isolation, and denial boundaries. Fault injection is parameterized by step rather than duplicated per call.

## Review plan
- Routed agents: `pi-forge.architecture-reviewer`, `pi-forge.security-reviewer`, `pi-forge.database-reviewer`, `pi-forge.test-reviewer`.
- Review artifact: sanitized goal, complete changed-file roster and relevant source, migration SQL, state machine, fault matrix, and fresh verification output.
- Critical/Major evidence gate: parent verifies each against actual source and focused executable evidence before fixing or rejecting it.

## Budget
- Fix rounds: 3.
- Delegated launches: one implementation writer, then four independent reviewers.
- Writer concurrency: 1.
- Final evidence: focused tests, strict format, diff check, release builds, full serialized suite, exact-copy migration audit.

## Risks and rollback
- Risk: replacement fails after predecessor retirement. Mitigation: durable per-operation intent, no replay, explicit terminal unknown evidence, other hosts and global pause preserved.
- Risk: explicit execution-host support misses a runtime/recovery lookup. Mitigation: structural search of every `roleHostID` consumer plus crash/restart tests.
- Risk: pane split changes preserved layout geometry. Mitigation: bind exact anchor/tab, verify preserved pane IDs/processes, and accept only the one new pane plus removal of `wM:p2`.
- Risk: schema9 blocks v11 rollback. Mitigation: immutable schema8 backup and fail-closed old binary; rollback remains a separate destructive operation.
- Rollback: before live replacement, reinstalling v11 plus restoring the exact schema8 backup may be prepared but not executed without a separate checkpoint.

## External side effects
- Source edits, tests, builds, migration copies, notarization, and audited package preparation are authorized by the fallback workflow.
- Live retirement/recreation is authorized only after exact digest-bound preview and wrapper review. Resume, unrelated dispatch, commit, push, PR, promotion, and rollback remain unauthorized.

## Progress
- [x] Analysis and approved fallback direction
- [x] ExecPlan written
- [ ] Reproduction tests
- [ ] Implementation
- [ ] Final verification and review
- [ ] Package and exact-copy migration audit
- [ ] Digest-bound live preview and replacement/q4

## Surprises and discoveries
- The client success response represented a valid recovery-required command, not q4 settlement. The wrapper correctly stopped because q4 count was zero.
- Herdr accepted `pane.clear_agent_authority` and then rejected `agent.rename`; current observable pane metadata still matches the stale preview.
- A same-ID process restart is structurally unsafe because the descriptor start record is write-once and command iteration begins at 1.
- The existing host-table uniqueness can remain untouched by making physical q4 ownership explicit in a new launch column and replacement-host table.

## Execution decisions
| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Reviewer timeouts | Treat all three broad timeouts as review gaps | No report is positive evidence. |
| 2 | Identity correction | Follow completed oracle advice: q4 explicitly references the new physical execution host | Avoids semantic overlay behind the predecessor ID. |

## Outcomes and retrospective
Pending.
