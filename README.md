# Jidoka Code

Jidoka Code is a single-user Rust web service for reviewing GitHub pull requests. Each report opens with **Where to focus**, a short guide to the lines worth reading, what the reviewer already checked, and which decisions need a maintainer.

The engine reviews text changes across languages and frameworks. It proposes findings, then checks the code for evidence that could disprove each one. The second pass also looks for problems the first pass missed, including disagreements between documentation, configuration and behavior. A newly proposed concern needs a separate check before it can become a finding. When evidence is missing, the model can ask for a file and a search term. Jidoka reads matching lines at the reviewed commit for one targeted recheck. The report gives the reviewer a concrete manual test when a behavior needs to be observed at runtime.

Jidoka collects changed lines before spending its budget on surrounding files. It verifies source references and lists the files supplied with patches and any gaps in coverage. Semgrep supplies additional leads when a bundled rule applies. The pilot includes one Python rule. Pull requests in other languages and changes that span multiple stacks go through the same review.

When you repeat a review with the same provider and both Git revisions still match, Jidoka rechecks up to two previous findings against the current evidence.

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

Running `docker compose stop` stops the service from accepting HTTP requests and lets the active review finish. Queued reviews resume on the next startup. Each model call can take up to five minutes. The engine can request one targeted recheck for an unresolved assessment. Compose allows up to seventeen minutes for shutdown so the worker can finish the active review.

## Reviewing and publishing

Open **View diff** on a report to browse the stored changes at the reviewed revisions. Select a line reference in the manual guide to jump into the patch. For older reports, **Load reviewed diff from GitHub** retrieves the patch when both revisions still match.

For a single-user installation, set `JIDOKA_REVIEWER_TOKEN` to your own GitHub token with **Pull requests: write** for the repositories you review. Open **Submit review**, select findings and a decision, then preview the summary and inline comments. The final button submits one GitHub review. Findings outside the patch appear in the summary. Jidoka checks the current PR revision before submission.

Under **Repositories**, choose **Manual**, **Automatic summary**, or **Automatic summary and inline comments** per repository. Manual is the default. Set `JIDOKA_BOT_TOKEN` to a personal access token for a dedicated bot account with **Pull requests: write** on the selected repositories. Keep the read token configured for private source. Jidoka polls GitHub from the container and sends eligible changes to the configured provider. The bot posts comments. Approvals and change requests come from the operator.

## Development

Use English for documentation, code comments, interface text, and review guidance. Keep quoted source code and file paths exactly as they appear in the repository under review.

The pilot has been tested with Rust 1.100. Export the environment variables above and run `cargo run --locked` to build and start the service. To run the scanner locally, install Semgrep CE on your PATH. The Docker image includes it. Jidoka uses the GitHub API and limits the number of files, bytes, requests, and time spent collecting source. The report lists gaps in coverage.

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

With Semgrep installed, run `cargo test --locked -- --include-ignored` to exercise the bundled rule against positive and negative fixtures.

[Product specifications](docs/specifications.md) · [Implementation plan](docs/implementation-plan.md)
