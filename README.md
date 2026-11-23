# Jidoka Code

Jidoka Code is a single-user Rust web service for reviewing GitHub pull requests. Each report opens with **Where to focus**, a short guide to the lines worth reading, what the reviewer already checked, and which decisions need a maintainer.

The engine reviews text changes across languages and frameworks. It first uses the supplied diff and context to identify concrete questions. For verification, the model receives the open questions, their relevant source excerpts and the evidence gathered for them. It can search the pinned repository or open other files to check callers, safeguards and tests. It follows up on those questions while retaining the answers already verified. The verifier can raise additional concerns in the evidence it examines. When discovery proposes no questions, the verifier looks at the full batch for missed issues. A newly proposed concern needs a separate check before it can become a finding. The report gives the reviewer a concrete manual test when a behavior needs to be observed at runtime.

Jidoka collects the pinned diff with Git. Reviews that exceed the model context window continue in smaller pieces. It verifies source references and lists the files supplied with patches and any gaps in coverage. Semgrep supplies additional leads when a bundled rule applies. The pilot includes one Python rule. Pull requests in other languages and changes that span multiple stacks go through the same review.

On a new push, Jidoka prioritizes files changed since the last review by the same provider. Earlier findings are leads for a fresh check against the current code. A superseded automatic review links to its replacement. GitHub comments summarize coverage and highlight specific decisions or tests for a human reviewer. The full list of coverage limits stays in Jidoka.

## Getting started

Create a local `.env` file with the provider authorized to receive their code. Use the full URL of a Chat Completions endpoint that supports JSON output. Jidoka connects directly to that endpoint even when a proxy is configured in the shell.

```dotenv
JIDOKA_PROVIDER_URL=https://provider.example/v1/chat/completions
JIDOKA_MODEL=your-model
JIDOKA_API_KEY=
JIDOKA_GITHUB_TOKEN=
```

```sh
docker compose up --build
```

Open [Repositories](http://localhost:8080/repositories), enter `owner/repository` or its GitHub URL, and choose **Authorize repository**. The repository is available immediately in manual mode. Jidoka saves the authorization in the `reviews` volume. You can also preconfigure repositories with the optional comma-separated `JIDOKA_REPOS` variable.

For private repositories, set `JIDOKA_GITHUB_TOKEN` to a GitHub token with read access to contents and pull requests. If the PR comes from a private fork, authorize that fork under **Repositories** too. Public repositories can be reviewed without a token.

Open [Jidoka](http://localhost:8080), enter a pull request URL, and confirm the provider before submitting. The service listens on the loopback interface for one trusted user. The `reviews` volume stores the SQLite history and supports reports from the Python pilot. Existing reports retain their original text.

On shutdown, Jidoka waits for the in-flight model call, saves its response and requeues the active review. The same provider can resume eligible work on restart. Each generation request has a ten-minute timeout. A review can use up to 500 generation requests in total, including retries and restarts. The review page shows model calls, reported token usage, time spent waiting for the model, and which changed files completed review.

With `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions` and `gemini-4-carbon`, Carbon reviews the diff and decides the findings. Gemini 3.8 Flash selects evidence to read from the pinned repository. Carbon can request one more lookup when the evidence leaves a specific question open. The review page identifies both models. Switching an existing installation to this pair uses Jidoka's usual provider-change handling. Re-enable automatic review in **Repositories** when ready.

Each review using this pair has a default allowance of US$1. Set `JIDOKA_REVIEW_BUDGET_CENTS` to a positive whole number of US cents to change the allowance for new reviews. Jidoka holds half of the allowance and one generation slot for a closing assessment. Jidoka reserves input and output before each generation, counts retries, and keeps the debit for an interrupted call whose usage is unknown. A restart keeps the same allowance. The budget uses conservative standard text rates and includes thinking tokens. When funds run low, Carbon uses the remaining allowance to close the review with the evidence collected. If the closing request cannot fit, the report keeps verified findings and identifies gaps in coverage. [Google API pricing](https://aistudio.google.com/docs/pricing)

When the model provider returns HTTP 429, Jidoka keeps the review in the queue with its completed work. Reviews for that provider resume after the wait shown on the review page. The wait survives a service restart.

## Reviewing and publishing

Open **View diff** on a report to browse the stored changes at the reviewed revisions. Select a line reference in the manual guide to jump into the patch. For older reports, **Load reviewed diff from GitHub** retrieves the patch when both revisions still match.

For a single-user installation, set `JIDOKA_REVIEWER_TOKEN` to your own GitHub token with **Pull requests: write** for the repositories you review. Open **Submit review**, select findings and a decision, then preview the summary and inline comments. The final button submits one GitHub review. Findings outside the patch appear in the summary. Jidoka checks the current PR revision before submission.

Under **Repositories**, choose **Manual**, **Automatic summary**, or **Automatic summary and inline comments** per repository. Manual is the default. Set `JIDOKA_BOT_TOKEN` to a personal access token for a dedicated bot account with **Pull requests: write** on the selected repositories. Keep the read token configured for private source. Jidoka polls GitHub from the container and sends eligible changes to the configured provider. The bot posts comments. Approvals and change requests come from the operator.

To queue a manual replay of a saved review at the original revisions, run `docker exec jidoka-code jidoka-code --replay-review ID`. The replay gets a new review ID and uses the currently authorized repository and provider.

## Development

Use English for documentation, code comments, interface text, and review guidance. Keep quoted source code and file paths exactly as they appear in the repository under review.

The pilot has been tested with Rust 1.100. Export the environment variables above and run `cargo run --locked` to build and start the service. Local runs require Git. To run the scanner locally, install Semgrep CE on your PATH. The Docker image includes both tools.

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

With Semgrep installed, run `cargo test --locked -- --include-ignored` to exercise the bundled rule against positive and negative fixtures.

[Product specifications](docs/specifications.md) · [Implementation plan](docs/implementation-plan.md)
