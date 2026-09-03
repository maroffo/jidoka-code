# ABOUTME: One-line tech-debt register; each entry points back to the plan that discovered it.
# ABOUTME: Items here were consciously deferred, not forgotten.

- Herdr socket path literal `.config/herdr/herdr.sock` duplicated in three targets (HerdrReadinessProbeCLI.swift:26, ApplicationEngineClient.swift:586, JidokaCodeEngineMain.swift:530); hoist to one JidokaCodeCore constant. Deferred from architecture review (Minor) during source-freeze of 2026-08-27_production-readiness-fast-path.md.
- Append-only/resume-denial SQL sweep in PiRunStoreTests.swift:2053-2072 asserts only SQLiteStoreError, not which trigger fired; match trigger RAISE messages to close the tautology risk. Deferred from test review (Minor) of 2026-08-27_production-readiness-fast-path.md; mitigated by trigger-name pinning in SQLiteStoreTests.swift:445-481.
- Preflight exit 69 (DB byte-guard trip) has no test seam; accepted as untestable without a write hook. Documented in test review of 2026-08-27_production-readiness-fast-path.md.
