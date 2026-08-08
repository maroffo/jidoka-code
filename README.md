# Jidoka Code

**Autonomous coding with built-in quality.**

Jidoka Code is a planned personal macOS menu-bar application for bounded software-engineering automation. It will monitor configured GitHub repositories, review pull requests, triage issues, plan and implement eligible work, and open pull requests without ever merging them.

The project is designed around four principles:

- automate routine engineering work, not final ownership;
- stop and request human judgment when risk or evidence requires it;
- keep GitHub credentials outside model processes;
- make every remote mutation attributable and recoverable.

The name refers to *jidoka*, the practice of building quality into automation by detecting abnormal conditions, stopping, and involving a person rather than propagating defects. This is an independent open-source project and is not affiliated with or endorsed by Toyota.

## Runtime dependency

Jidoka Code is designed to use the system-installed [Pi coding agent](https://github.com/earendil-works/pi), distributed as [`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent). Pi is not bundled.

Canonical setup begins with:

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0.84.0
pi
# Run /login inside Pi and select a provider.
```

W0 and W1 originally verified Pi `0.83.0`. The current compatibility policy accepts semantic versions `>=0.84.0 <0.90.0`, but still requires an exact attestation entry for each installed build. Only `0.84.0` is currently admitted; its complete package-tree inventory and digest must match. Later versions fail closed until they pass the offline contract and are added explicitly. W5 also binds Pi's shebang to the exact Node `26.6.0` executable and attests the ordered, non-system Mach-O dynamic-library closure, including `@rpath` search order.

## Development toolchain

Development requires full Xcode. Project-owned commands use the per-process setting:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Jidoka Code does not change the machine-wide `xcode-select` configuration. W0 must verify the bundle, Xcode version, SDK, XCTest and Swift Testing through that exact developer directory.

Canonical scaffold commands:

```sh
make check  # format, shell, debug/release builds and unit tests
make test-e2e  # copied, signed application preflight from cwd /
make jidoka-code-package  # assemble build/Jidoka Code.app
make jidoka-code-test-s2-preflight  # offline-only lifecycle contract check
make jidoka-code-test-s3-preflight  # offline-only Keychain isolation contract check
make jidoka-code-test-s4-preflight  # packaged Pi, retry, ledger and cleanup checks, zero provider calls
make jidoka-code-test-s5-s7-preflight  # temporary local Git/security/recovery fixtures
make jidoka-code-test-s8-preflight  # workflow matrix and command provenance, zero provider calls
make jidoka-code-test-s9-preflight  # locked helper topology and monolith-removal check
```

These commands do not install the app, register a login item, access a real credential, call a model provider, or mutate GitHub. The S5-S7 preflight creates only temporary repositories and a loopback smart-HTTP fixture, then removes them.

Offline packaging defaults to an ad-hoc signature. Any lifecycle or distribution probe must pass an exact local identity SHA-1 explicitly:

```sh
SIGN_IDENTITY=<40-character-codesigning-identity> make jidoka-code-package
```

Identity signing uses hardened runtime, signs nested code before the app, and fails unless app and helpers have the same concrete TeamIdentifier. The ad-hoc output is not accepted as lifecycle evidence.

## Status

W1 packaged-context spikes S1-S9 are complete and Checkpoint B is accepted. W2 provides the durable SQLite core and scheduler. W3 adds the closed GitHub REST broker, Keychain token boundary, byte-exact markers and revisions, prepared-before-send mutation reconciliation, and evidence-based discovery. W4 adds app-managed Git mirrors and workspaces, packaged one-shot askpass and old-zero push guard, frozen verification commands, validated workspace import, and durable create-only branch publication. W5 adds the bounded Pi RPC runner, app-versioned and digest-attested workflow resources, app-owned exact-path file tools, a closed credentialless query surface, deterministic complexity authority, fresh reviewer routing, same-session writer revision, complexity- and approval-bound frozen plans, exact command execution, and fake-provider replay. No application release or supported installation exists yet.

The active implementation plan is:

- [`docs/plans/active/2026-08-05_jidoka-code-macos-app.md`](docs/plans/active/2026-08-05_jidoka-code-macos-app.md)

The evidence reports record executable verification, provider-call accounting, cleanup, and residual risks:

- [`docs/evidence/spike-report.md`](docs/evidence/spike-report.md)
- [`docs/evidence/w4-git-transport-report.md`](docs/evidence/w4-git-transport-report.md)
- [`docs/evidence/w5-pi-workflows-report.md`](docs/evidence/w5-pi-workflows-report.md)

The selected W1 topology is the signed LaunchAgent helper. The in-process monolith probe was removed after it failed the crash-restart threshold. W6-W9 remain unimplemented; the broker, Git transport, and W5 workflow engine have no live credential or GitHub canary evidence and are not yet connected through production job coordinators or the menu-bar UI.

## Scope boundary

The first version is a single-user macOS application. It excludes automatic merge, hosted services, dashboards, multi-user operation, bundled model runtimes, containers, and an updater.

## License

MIT. See [`LICENSE`](LICENSE).
