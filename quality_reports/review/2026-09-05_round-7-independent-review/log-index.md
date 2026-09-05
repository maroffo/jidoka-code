# ABOUTME: Round-7 log index: purpose, exit status and SHA-256 of every diagnostic and final gate log
# ABOUTME: Only 07-14 are the required final gates; 01-06 are diagnostic and mutation evidence

# Round-7 log index

All 15 raw logs are preserved, including the two red runs. Only 07-14 are the required final gates, bound in order by 15. Exit zero without test execution is never treated as test evidence. The four reviewer reports are in [reviews/](reviews/).

| Raw log | Exit | Purpose and disposition | SHA-256 |
|---|---:|---|---|
| [01-build-tests-red.log](logs/01-build-tests-red.log) | 1 | RED build: three compile errors in the first draft of the new tests (optional `Int64?`, `Comment` argument); no tests executed. | `dc182519718f815396858a8dd4466102c6f117095ba1ce3498aeb4d460e882f2` |
| [02-build-tests.log](logs/02-build-tests.log) | 0 | Green test build after the compile fixes. | `856ecfb9d926d1aa2181c15935f5bfc987deed612d552cb77bd9dec4f57b9952` |
| [03-targeted-tests-red.log](logs/03-targeted-tests-red.log) | 1 | RED: 106 tests / 7 suites, one issue: the seed-branch strategy that lifted the seed trigger was refused by activation's own ledger read (`decode("rollout usage ledger")`); five other new tests green. | `e720eaced3bb8372934bf1368cd24821e740452db3a5b6561455bb3a004de561` |
| [04-build-tests.log](logs/04-build-tests.log) | 0 | Green test build with the trigger-replacement seed strategy. | `fe595b5e73745478f46faa198d591440629e178e794b0c24a0bbe6d649d59ec0` |
| [05-store-tests.log](logs/05-store-tests.log) | 0 | `RolloutAuthorityStoreTests`: 49 tests / 2 suites PASS, including all four new tests. | `c7d9f4267ef7da90f20ebdc02ec12d352ceccac7f67ae1b78251770575fa2c59` |
| [06-m2-mutant-sweep-summary.txt](logs/06-m2-mutant-sweep-summary.txt) | 0 | Mutation sweep in an isolated export: baseline 49 PASS; M1-M7, M9-M11 KILLED; M8 SURVIVED (equivalent mutant); schema restored, SHA-256 match. | `0c1d50da746fd2812dff5718ae12e9f98a6d2d4abf266b00b2d2eb0b997d34c1` |
| [07-make-check.log](logs/07-make-check.log) | 0 | FINAL make check: 776 tests / 88 suites PASS, no known issues or cleanupFailed. | `17654fdf6efca6888deff4fce9242e2e863bd0e53704389bc9acc8d224f40e01` |
| [08-test-e2e.log](logs/08-test-e2e.log) | 0 | FINAL E2E: S1/S10/S11/S12 PASS, synthetic provider network zero. | `413951bec7979172b8d2ffe9da72d0ab541e4f57e8391921fe083bc2a90829c5` |
| [09-acceptance.log](logs/09-acceptance.log) | 0 | FINAL acceptance: 776 tests / 88 suites PASS, 21 required suites. | `f14cfb9668ad1a73f64cdbdaff153afa88320b64dcc3cfaea81648d0a75ac8d2` |
| [10-format-lint.log](logs/10-format-lint.log) | 0 | FINAL recursive strict Swift format lint PASS (empty output). | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| [11-release-app.log](logs/11-release-app.log) | 0 | FINAL release JidokaCodeApp build complete, cached after make check's release build. | `21267760d1ec8a84bfb1feddd4929667e0579e1635956f99a3be9c47631b1b1b` |
| [12-release-engine.log](logs/12-release-engine.log) | 0 | FINAL release JidokaCodeEngineProbe build complete, cached. | `604a467395a0d1ff92977f906764b3c2af271f134930c49bf3a64e21e4fd674a` |
| [13-release-herdr-host.log](logs/13-release-herdr-host.log) | 0 | FINAL release JidokaCodeHerdrHost build complete, cached. | `fa1e9f9f29a6376e04045081f48cc91fecd4cfb4589cd1ee79abf1206ca5fdea` |
| [14-diff-check.log](logs/14-diff-check.log) | 0 | FINAL required diff whitespace check PASS (empty output). | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| [15-gate-status.txt](logs/15-gate-status.txt) | 0 | Start/exit timestamps and exit codes of gates 07-14 in execution order. | `3cebc03b9a33640fd4ae1f9f246e538bacd7cd9d251560af78ca1ce85406dc57` |
