# Round-5 accuracy corrections

Max released the exhausted four-round budget with "usa tutti i round che ti servono".
Plan decisions E14 and E15 record that authority and the correction scope.
The starting commit is `786a3b6bf528cf393ab29eed8290a59220357697`, on
`feat/progressive-production-automation` in the existing worktree
`/private/tmp/jidoka-code-progressive-production-automation`.

## Finding dispositions

| Finding from PR comment 5550129542 | Change and evidence |
| --- | --- |
| Major: the binding subquery supposedly subsumes lease identity equality | Removed that explanation. The subquery binds NEW values and cannot establish equality to OLD. `transferToBoundJobDuringDrainRemainsAdmission` starts with an ordinary live lease, opens a lane binding another job, then tries to transfer the lease to that job in both `draining` and `recoveryRequired`. It requires rejection and preservation of the original lease owner. |
| Minor: the label-switch test only exercises the PR-review whitelist | The test now first revalidates a valid `implementationExecute` / `publishPlan` preview, then requires the builder to reject `implementationExecute` / `replan` with `invalidObjectSelector`. The comment describes this specific case rather than claiming the PR path reaches issue-label validation. |
| Minor: the trigger comparison only covers marker-to-end | Retained the common-tail comparison and separately pinned `WHEN NEW.active = 1` in each trigger. The test description explicitly identifies these two surfaces; the update-only continuation clause remains covered by behavioral tests. |
| Minor: acquisition is described only as a generation bump | Schema comments, runbook and E11 now distinguish an initial INSERT from a generation-changing reacquisition. Both remain gated. The acquisition sites in `DurableJobStore.swift` and both `JobCanary.swift` upserts confirm the distinction. |
| Additional local accuracy finding: the continuation comment claims a finite-expiry bound | Corrected the comment: the exemption checks open-lane state, not expiry. The existing `heartbeatSurvivesPauseAndDrain` test already exercises a heartbeat past authorization expiry. No SQL condition changed. |

`DatabaseSchema.swift` is byte-identical to the starting version after removing
full-line SQL comments. This comparison was performed directly on the working file
and `git show 786a3b6:Sources/JidokaCodeCore/State/DatabaseSchema.swift`.
No production heartbeat caller was found in `Sources`; E11's production conclusion
is retained. Fresh-effect authority, historical canary denial, and atomic
`markSendStarted` code are unchanged.

The schema-10 **test digest pin** changed from
`818156e514db70ace3e9b2127bb7217a2f09a0af429bb23754f9195f0d467c3b` to
`b54582b347dd86372c8c0a5119061e7568ef47845df8b71b95ada4eacf73772e`.
The separate runtime `statementsSHA256` content guard remains enabled. Comment edits
also change that runtime digest, so an earlier development schema-10 database must
still fail closed. No existing database was edited to update its recorded digest.

## Verification

Every command uses `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and
`JIDOKA_RELEASE_RUNTIME_ROOT=/private/tmp/jidoka-code-progressive-production-automation/build/runtime-input/qualified-runtime`.
One Swift build is run at a time. Raw logs are append-only additions under `logs/`.

- `focused-before-digest-repin.log`: 30 tests in 2 suites passed. The combined filter
  selected the lease and preview suites only; it did not select the schema test.
- `schema-before-digest-repin.log`: the populated migration test and all 90
  statement-cut cases ran and failed on the expected stale digest pin. This is the
  preserved repin diagnostic, not successful final evidence.
- `final-make-check.log`: `make check` passed with 762 tests in 85 suites.
- `final-test-e2e.log`: `make test-e2e` passed S1, UI, S11 and S12. The UI
  stderr was empty; its report records zero Keychain/network/provider/service-management
  effects. S12 reports two local synthetic provider calls and `provider_network=0`.
- `final-production-automation-acceptance.log`:
  `make jidoka-code-production-automation-acceptance` passed 762 tests in 85 suites
  and explicitly confirmed `PASS suites=18`.
- `final-swift-format-lint.log`:
  `xcrun swift-format lint --recursive --strict Sources Tests` passed.
- `final-release-app.log`:
  `xcrun swift build --configuration release --product JidokaCodeApp` passed.
- `final-release-engine-probe.log`:
  `xcrun swift build --configuration release --product JidokaCodeEngineProbe` passed.
- `final-release-herdr-host.log`:
  `xcrun swift build --configuration release --product JidokaCodeHerdrHost` passed.
- `final-git-diff-check.log`: `git diff --check` passed.

All eight final commands exited 0 between 08:12:54 and 08:28:45 UTC on 2026-09-05.
Neither full run nor E2E recorded `.cleanupFailed`. No source/test file changed
during those commands. `.gitattributes` extends the existing raw-log whitespace
exemption only to this round's log directory; source lint and diff checks remain enabled.

Source file SHA-256 values after the final source/test edit:

```text
1f5eb27bc31cc52e2a8ab05c05e831c2450d856bfae2806d4489a525bcba274a  Sources/JidokaCodeCore/State/DatabaseSchema.swift
02c0e38427d710f9bd1b8e950069a2c5ba25459174f55018ceb3b0a424697e31  Tests/JidokaCodeCoreTests/RolloutLeaseAuthorityTests.swift
a3258d604d7b025086c0e7430148e352b3185c2fa2877184b4978c26ccad3abd  Tests/JidokaCodeCoreTests/RolloutRemotePreviewRevalidatorTests.swift
f5f12713fb837579d622e341d687f289c4f8b7ba59d5ca8aa5e3befc978854c8  Tests/JidokaCodeCoreTests/SQLiteStoreTests.swift
```

## Preservation and remaining gates

All committed logs and the historical `tracked-changes.diff` remain untouched.
Before the UI harness recreates its fixture directory, the preceding `build/w7-ui-flow`
was copied to `build/round5/preserved-ui-786a3b6`; `diff -qr` confirmed an identical
copy. Prior `build/evidence` directories were not changed. The E2E harness's local
fixture cleanup is not a cleanup of historical or production evidence.

Source completion is not claimed. This session exposes neither the protected-child
carrier nor the four `pi-forge.*-reviewer` tools required by the plan. No substitute
model/provider route is authorized or invoked. A writer's local review and mutation
checks cannot substitute for those independent reviews.

Merge and W7 remain Max's separate gates. No production rollout, live provider call,
live workflow GitHub/Git effect, Developer ID signing, notarization, installation,
deployment, tag, release, rollback or historical-state cleanup is authorized here.
