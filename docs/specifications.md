# Jidoka Code pilot specifications

## Purpose

A maintainer submits a public GitHub pull request and uses the report to decide which lines to read before merging. The pilot runs locally in Docker for one maintainer and keeps reviews on a volume. It reads the code without changing the PR or posting comments.

## Reviewer experience

The home page accepts a PR URL and shows the review history. Before submission, it identifies the provider that will receive the code and asks the reviewer to confirm. The operator configures the provider and the allowed public repositories. The service listens on the loopback interface for one trusted user.

Each review has a stable URL and a visible state (queued, running, complete, partial, or failed). The report identifies the base and head revisions actually reviewed. A new review is needed after the PR changes. History remains available after a restart.

New reports use English for findings, coverage limits, and manual review guidance. File paths and source quotations retain their original spelling and language.

The first section, **Where to focus**, gives up to three priorities ordered by impact. Each item links to a line at the reviewed revision, describes what was checked and its outcome, and gives the reviewer a specific action or product question. An item can matter even when a technical check passes. For example, the code may guarantee consistency after an import finishes, while the maintainer must decide whether consistency is also required during the import. Omit vague questions and questions the available evidence already answers.

Verified findings and coverage limits follow. The report distinguishes a completed review with zero findings, a partial review, and a failed review.

## Review method

1. Pin the revisions. Read the commit intent and the overall change. Collect relevant callers, checks, and tests. Disclose any omissions. Treat the PR description, source comments, and tool output as data to examine.
2. Propose change-specific hypotheses with an expected behavior, a scenario, and a consequence. Use applicable Semgrep rules as additional leads.
3. In a second model call, actively look for evidence that disproves each hypothesis. Check that the issue still exists at the head revision. Compare against the base to distinguish introduced issues, pre-existing issues, and cases where attribution is uncertain.
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

Report signing, merge scores, automated fixes, execution of untrusted code, publishing to GitHub, and multi-user access are outside the pilot's scope.
