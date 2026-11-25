# Jidoka Code

Jidoka is a single-user Rust web service for reviewing GitHub pull requests with the Google Antigravity CLI. Each run sends one pinned PR to AGY. The reviewer reads its diff, source tree, earlier findings and Semgrep leads. It returns findings with evidence, changed files it reviewed, and a short guide for manual review. Jidoka checks line references against the pinned diff before accepting the report.

## Getting started

Docker Compose runs the web service and an isolated AGY runner. Set these values in a local `.env`:

```dotenv
GOOGLE_CLOUD_QUOTA_PROJECT=your-review-project
JIDOKA_AGY_ADC_FILE=/absolute/path/to/dedicated-reviewer-adc.json
JIDOKA_MODEL="Gemini 4 Carbon (High)"
JIDOKA_GITHUB_TOKEN=
```

Enable model access on the billing project. Supply Application Default Credentials (ADC) for an identity dedicated to invoking the model on that project. A credential helper gives AGY a short-lived access token for that identity. Keep personal credentials, GitHub tokens and unrelated project permissions out of the runner. Only the runner supervisor can read the mounted ADC file. [Antigravity Cloud authentication](https://antigravity.google/docs/enterprise#adc-headless)

```sh
docker compose up --build -d
```

Open [Repositories](http://localhost:8080/repositories), authorize the GitHub repository, then submit a PR from the dashboard. Private repositories need a GitHub token with read access to contents and pull requests. Authorize private forks separately. The optional comma-separated `JIDOKA_REPOS` setting preauthorizes repositories.

### Migrating from direct API reviews

Keep the existing reviews volume for the web service. AGY has a distinct provider identity, so existing automatic repositories require re-enabling under **Repositories**. Use the AGY model label above in place of the direct API model ID. Remove the old `JIDOKA_REVIEW_BUDGET_CENTS` setting before starting: the service rejects it because the CLI cannot enforce a per-review dollar cap. Cloud charges and limits follow the configured account. Previously saved reports and costs remain accessible.

### Review execution

The runner invokes `agy -p <prompt> --dangerously-skip-permissions` once for each review. Jidoka retains the database and all GitHub access. The runner sees the pinned checkout and diff through a read-only volume, runs AGY as a non-root user with a fresh temporary home, and exits after each job. Compose restarts it for the next job. The CLI has 30 minutes to produce a structured verdict. Revoking repository access, superseding a review or stopping Jidoka interrupts the session. After an interrupted paid invocation, use an explicit replay to start another one.

The dashboard records reported token usage. Missing coverage, an invalid citation, a failed CLI run or an empty verdict produces a partial report. Partial reports stay in Jidoka. Only completed reports can be submitted to GitHub.

## Reviewing and publishing

Open **View diff** on a report to browse the stored changes at the reviewed revisions. Select a line reference in the manual guide to jump into the patch. For older reports, **Load reviewed diff from GitHub** retrieves the patch when both revisions still match.

For a single-user installation, set `JIDOKA_REVIEWER_TOKEN` to your own GitHub token with **Pull requests: write** for the repositories you review. Open **Submit review**, select findings and a decision, then preview the summary and inline comments. The final button submits one GitHub review. Findings outside the patch appear in the summary. Jidoka checks the current PR revision before submission.

Under **Repositories**, choose **Manual**, **Automatic summary**, or **Automatic summary and inline comments** per repository. Manual is the default. Set `JIDOKA_BOT_TOKEN` to a personal access token for a dedicated bot account with **Pull requests: write** on the selected repositories. Keep the read token configured for private source. Jidoka polls GitHub from the container and sends eligible changes to the configured provider. The bot posts comments. Approvals and change requests come from the operator.

To queue a manual replay of a saved review at the original revisions, run `docker exec jidoka-code jidoka-code --replay-review ID`. The replay gets a new review ID and uses the currently authorized repository and provider.

## Development

Use English for documentation, code comments, interface text, and review guidance. Keep quoted source code and file paths exactly as they appear in the repository under review.

The pilot has been tested with Rust 1.100. Use Compose to run the complete service with Git, Semgrep and AGY.

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

With Semgrep installed, run `cargo test --locked -- --include-ignored` to exercise the bundled rule against positive and negative fixtures.

[Product specifications](docs/specifications.md) · [Implementation plan](docs/implementation-plan.md)
