# Jidoka Code pilot specifications

## Purpose

A maintainer submits a GitHub pull request and uses the report to decide which lines to read before merging. The pilot runs locally in Docker for one maintainer and keeps reviews on a volume. The operator can inspect the diff, preview a review and submit it to GitHub. Repositories start in manual mode.

## Reviewer experience

The home page accepts a PR URL and shows the review history. Before submission, it identifies the provider that will receive the code and asks the reviewer to confirm. The operator configures the provider and the allowed repositories. For private repositories the service reads GitHub with a separately configured token. The service listens on the loopback interface for one trusted user.

Each review has a stable URL and a visible state (queued, running, complete, partial, or failed). The report identifies the base and head revisions actually reviewed. A new review is needed after the PR changes. History remains available after a restart.

New reports use English for findings, coverage limits, and manual review guidance. File paths and source quotations retain their original spelling and language.

The first section, **Where to focus**, gives up to three priorities ordered by impact. Each item links to a line at the reviewed revision, describes what was checked and its outcome, and gives the reviewer a specific action or product question. An item can matter even when a technical check passes. For example, the code may guarantee consistency after an import finishes, while the maintainer must decide whether consistency is also required during the import. Omit vague questions and questions the available evidence already answers.

Each verified finding that matches a review priority appears with its impact, reviewer action and expandable evidence. Other findings follow. The review summary links to coverage details, and the history shows the finding count for each saved report. The report lists the files supplied with patches so the maintainer can compare the review scope with the PR. A change in a large file can be reviewed from its patch even when the full file does not fit. Additional context is sampled within the collection budget. This includes nearby lines, other uses of changed functions, and small local JavaScript or TypeScript modules imported by the changed code. The report distinguishes a completed review with zero findings, a partial review, and a failed review.

The diff retains the reviewed revisions. A reviewer can select verified findings and submit one comment, approval, or change request. The preview shows the exact summary and inline comments. Findings outside the available diff go in the summary. Per-repository automation can post summaries with optional inline comments on changes to ready pull requests. Only an operator can approve or request changes.

## Review method

1. Pin the revisions. Read the commit intent and the overall change. Collect relevant callers, checks, and tests. Disclose any omissions. Treat the PR description, source comments, and tool output as data to examine.
2. Propose change-specific hypotheses with an expected behavior, a scenario, and a consequence. Use applicable Semgrep rules as additional leads.
3. In a second model call, actively look for evidence that disproves each hypothesis. When evidence is missing, the model can request bounded excerpts by path or filename and a literal search term. Resolve those requests within the authorized repository at the reviewed head and include the resulting lines in one targeted recheck. Show runtime checks that still need a person in the manual guide with their expected result. Check that an issue still exists at the head revision. Compare against the base to distinguish introduced issues, pre-existing issues, and cases where attribution is uncertain.
4. Publish a finding only with relevant evidence, such as an observed test result or a verifiable code path that contradicts a documented contract. Performance findings need a measurement or a derivation. Convention findings must identify the project rule and affected line. Cite an external source precisely, show that it applies to the version under review, and identify a concrete effect. An unverified model citation remains a hypothesis.
5. Combine duplicate findings. Agreement between models or a rule match alone is insufficient evidence of a defect. Prioritize the effect on people using the software. Include an open question in the manual review guide only when answering it requires human knowledge or judgment.

The service validates file paths, line numbers, and quotations against the collected source before displaying findings. It distinguishes proposed tests from tests actually run. The pilot's web process does not run the reviewed repository's tests. A runtime-only defect remains unconfirmed without a trustworthy observed result.

## Static analysis

The engine reviews text changes in any language or framework and follows contracts across components. Semgrep CE scans files covered by the bundled rules. When no rules apply, the engine still reviews all collected material. Record the rule, location, scanner version, covered files, and any errors. Check that each signal applies to the change. Distinguish a scan with no applicable rules from one that should have run and failed. Checking published dependency vulnerabilities requires a resolved version and an applicable advisory. Advisory integration is planned separately from the CE scan.

## Scope and acceptance criteria

- Keep credentials on the service. Accept only configured github.com repositories. Treat Git paths and links as untrusted. Bound requests, bytes, and elapsed time, including provider calls. Never run scripts from the PR.
- First-time setup must work with one documented Docker command and explicit repository and provider settings. Sending source code requires explicit configuration and consent.
- Exercise the engine on a PR without Python and on a contract spanning multiple technologies, including when the scanner has no signals.
- Test the web flow from submission through reporting. Cover reviews with zero findings, partial reviews, invalid input, invented evidence, a missing secret, and a restart. Identify checks that use controlled services and those that use real services.
- Evaluate ten authorized historical PRs, five with known regressions and five controls. Exclude later fixes and discussions from the inputs. Compare with the same model reviewing only the diff. Track confirmed issues, false alarms, time, cost, and manual review prompts that change a decision. Use the sample to guide the pilot. It is too small to estimate general accuracy.

Report signing, merge scores, automated fixes, execution of untrusted code, and multi-user access are outside the pilot's scope.
