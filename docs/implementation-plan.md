# Rust migration plan

The Python pilot at commit `75700b6` is the behavioral reference. The migration preserves the consent flow, report URLs, SQLite history, and Docker settings. A single Rust executable runs the worker and serves HTML.

## Work sequence

| Phase | Owner | Deliverable | Verification |
| --- | --- | --- | --- |
| 1 | Coordinator | Shared snapshot, check, and report types, plus the provider's JSON contract | All three units compile against the same types |
| 2A | Source agent (Sol) | Collect source from pinned GitHub revisions, select context across languages, and run Semgrep where applicable | Test collection limits, safe file paths, and changes across multiple stacks |
| 2B | Engine agent (Sol) | Run two adversarial review passes, check citations, compare findings with the base revision, and guide the human reviewer | Cover confirmed and refuted hypotheses, invented references, and reviews without Semgrep signals |
| 2C | Web agent (Sol) | Serve HTML with Axum and queue reviews in SQLite, binding consent to the selected provider | Verify loopback access, form protection, restart behavior, historical reports, and distinct review states |
| 3 | Coordinator | Integrate the provider, worker, and Docker image | Compare Rust and Python results with identical model replies, test the HTTP flow, exercise the real Semgrep rule, and start the container |

Units 2A, 2B, and 2C run in parallel. The coordinator integrates the work on the PR branch after shared checks pass. Automated tests use synthetic repositories and model replies. Evaluating model quality on ten authorized historical PRs is a separate experiment.
