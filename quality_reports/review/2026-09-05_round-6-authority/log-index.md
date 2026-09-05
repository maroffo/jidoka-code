# Round-6 log index

All 25 raw logs are preserved, including red and failed-build attempts. Only 16-23 are the required final gates; 24-25 bind the resulting source commit and read-only checks. Exit zero without test execution is never treated as test evidence.

| Raw log | Exit | Purpose and disposition | SHA-256 |
|---|---:|---|---|
| [01-m1-m3-red.log](logs/01-m1-m3-red.log) | 1 | RED: supplied M1/M3 reproductions, 2 tests / 2 issues. | `17d570bc985ffeaa490355d85d621b73c5b0a878537345709a6fc04343b6a5f0` |
| [02-m2-red.log](logs/02-m2-red.log) | 1 | RED: two forged usage rows accepted; also a readback-context fixture error, 4 issues. | `f0a7bb3934fd8d1c65832d1b4dea09379f587b6c87ea385b5bd9eb06716fac21` |
| [03-m1-m2-focused.log](logs/03-m1-m2-focused.log) | 1 | M1/M2 focused: 38 tests; one stale pause expectation remains. | `d3de0e9ad9bbfc00df85854e080c94aab04e97ce2c6a48581761ae365b95845f` |
| [04-canary-coverage-and-digest.log](logs/04-canary-coverage-and-digest.log) | 1 | Canary double alignment: 46 tests, 164 issues; the schema filter did not select schema tests. | `f0f5a73562ab61de07e2aa41cab42019acd0729b23ead57944246400f92782df` |
| [05-m1-m2-schema.log](logs/05-m1-m2-schema.log) | 1 | Schema digest discovery: 41 tests, 92 old-pin mismatches; not a green schema gate. | `19e9915a37f08eb05273f90f5a646a9f6e6414524be00c664a06cc8176990f21` |
| [06-operator-parser-and-schema.log](logs/06-operator-parser-and-schema.log) | 1 | Build failure: invalid public local declarations in the moved fixture; no tests executed. | `cfc3212cf8134cb624752f71fa0614a30a0a0cb68d1c1725d78aa9feeb7c655d` |
| [07-operator-runtime.log](logs/07-operator-runtime.log) | 1 | 29 targeted tests: status double-transition bug and fixture timestamp failure exposed. | `05319069cbffd31d31ff60c6ee3be724e6e5ace814b1c3b5c0156da12107378e` |
| [08-runtime-and-historical-core.log](logs/08-runtime-and-historical-core.log) | 1 | Build failure: missing test evidence variable; no tests executed. | `45fffbc644c9215d3c6ead88cec25899601e48ccf98c40cacc886f55d98bdefb` |
| [09-runtime-historical-alignment.log](logs/09-runtime-historical-alignment.log) | 1 | 42 targeted tests: recovery expiry and historical reload fixture fail. | `b5aadaa40e7e7d2eb1def188ce218c3346d700fe60f8cda4021153bdef3b39fe` |
| [10-operator-historical-parity.log](logs/10-operator-historical-parity.log) | 1 | 42 targeted tests: only historical reload fixture remains red. | `69aa4eb8cfe40a8247a6a359a9ce02583bdb00e5caac956c9c53a76ae67f99a1` |
| [11-historical-reload-diagnostic.log](logs/11-historical-reload-diagnostic.log) | 1 | One-test reload diagnostic: first reload fails. | `3600913711ad8b2c30f06bacea41a6f30a01649a655c8eef7ea77c943fd31990` |
| [12-historical-reload-phase.log](logs/12-historical-reload-phase.log) | 1 | One-test reload diagnostic: localizes failure to the fake generic coordinator-recovery path. | `7971ff9bb9a9cb87ccc7060bc46bdbfc40339ee07ee551541840a5a69aa5dc85` |
| [13-round6-functional.log](logs/13-round6-functional.log) | 1 | Build failure: incorrect disposition API argument labels; no tests executed. | `266092746f29aa62f05008237089e961ba3c77c932d130cd5fbddd4fb3a4b830` |
| [14-round6-functional.log](logs/14-round6-functional.log) | 1 | 33 targeted tests: functional cases green, 94 old digest-pin mismatches. | `30796e62daab025b7073f8b2a630512f37d7f04eb6a75c9c3a4c69a9958e5f73` |
| [15-make-check.log](logs/15-make-check.log) | 2 | First full aggregate: 770 tests / 88 suites, three issues; superseded by 16. | `1b2db9eaf19cb81c27be90f7fcc5a2daa00078204e4c9458dcb60fa1a44a2034` |
| [16-make-check.log](logs/16-make-check.log) | 0 | FINAL make check: 770 tests / 88 suites PASS, no known issues or cleanupFailed. | `87d25790de88cde81fb4ebace0ed93a02d465f03df7e87232203f099c9e378e7` |
| [17-test-e2e.log](logs/17-test-e2e.log) | 0 | FINAL E2E: S1/S10/S11/S12 PASS, synthetic provider network zero. | `23ac06934036f6539a30e15f5cffd4e9d613142a228bd347586bfd37d914502f` |
| [18-acceptance.log](logs/18-acceptance.log) | 0 | FINAL acceptance: 770 tests / 88 suites PASS, 21 required suites. | `155e0c902e8f5684417c7873d64acf6d742fba5adc9b1ec3ca797847b7481a27` |
| [19-format-lint.log](logs/19-format-lint.log) | 0 | FINAL recursive strict Swift format lint PASS. | `4023a525ecd2ace085cfc9cf131ab9ce41a0bb96a08766d3549ab95d6ab9f632` |
| [20-release-app.log](logs/20-release-app.log) | 0 | FINAL release JidokaCodeApp build complete, cached. | `03f1054c36891db9c9e2e827b87d74a1253dd0e020a5d4ade805bc9e3dce1cfd` |
| [21-release-engine.log](logs/21-release-engine.log) | 0 | FINAL release JidokaCodeEngineProbe build complete, cached. | `c593cea88869e6df2df4e5f61bde9d716dd85945f58876a7dd97697e092f94a0` |
| [22-release-herdr-host.log](logs/22-release-herdr-host.log) | 0 | FINAL release JidokaCodeHerdrHost build complete, cached. | `1f4e9cf71a28b3ed9e0fdf19414440617095842e6b0ecb24cfe1089aa52f801b` |
| [23-diff-check.log](logs/23-diff-check.log) | 0 | FINAL required diff whitespace check PASS. | `d79dfcbb163a2f763538d2cc3a6d2fd8dd59c02bda822af3eb638cad72538d0d` |
| [24-source-commit.log](logs/24-source-commit.log) | 0 | Normal source commit d123a41, no hook bypass. | `14d682d18f77b72a3660f4ef3a37c9ed16dd068926b9937376388c18e2597a25` |
| [25-post-commit-audit.log](logs/25-post-commit-audit.log) | 0 | Post-commit identity/whitespace/source-unchanged/historical-evidence-preserved checks PASS; not independent review. | `89303aa9620259cb6b79b182172b4bc6e52781802f6dd2ae5097b52308e0fe4f` |
