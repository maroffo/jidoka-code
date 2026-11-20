# Jidoka Code

Jidoka Code is a single-user Rust web service for reviewing GitHub pull requests. Each report opens with **Where to focus**, a short guide to the lines worth reading, what the reviewer already checked, and which decisions need a maintainer.

The engine reviews text changes across languages and frameworks. It makes two passes. The first proposes findings. The second looks for evidence in the code that could disprove them. Jidoka checks file paths, line numbers, and quotations against the revisions under review. Semgrep supplies additional leads when a bundled rule applies. The pilot includes one Python rule. Pull requests in other languages and changes that span multiple stacks go through the same review.

## Getting started

Create a local `.env` file listing the repositories to review and the provider authorized to receive their code. Use the full URL of a Chat Completions endpoint that supports JSON output. Jidoka connects directly to that endpoint even when a proxy is configured in the shell.

```dotenv
JIDOKA_REPOS=organization/project
JIDOKA_PROVIDER_URL=https://provider.example/v1/chat/completions
JIDOKA_MODEL=your-model
JIDOKA_API_KEY=
JIDOKA_GITHUB_TOKEN=
```

```sh
docker compose up --build
```

For private repositories, set `JIDOKA_GITHUB_TOKEN` to a GitHub token with read access to contents and pull requests. If the PR comes from a private fork, include that fork in `JIDOKA_REPOS` too. Public repositories can be reviewed without a token.

Open [Jidoka](http://localhost:8080), enter a pull request URL, and confirm the provider before submitting. The service listens on the loopback interface for one trusted user. The `reviews` volume stores the SQLite history and supports reports from the Python pilot. Existing reports retain their original text.

Running `docker compose stop` stops the service from accepting HTTP requests and lets the active review finish. Queued reviews resume on the next startup. Each of the two model calls can take up to five minutes. Compose allows up to eleven minutes for shutdown so the worker can finish the active review.

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
