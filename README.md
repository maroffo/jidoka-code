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
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi
# Run /login inside Pi and select a provider.
```

The implementation plan currently gates on Pi `0.83.0`; W0 must revalidate compatibility against the installed public package and documentation before source work.

## Status

Planning only. No application release or supported installation exists yet.

The active implementation plan is:

- [`docs/plans/active/2026-08-05_jidoka-code-macos-app.md`](docs/plans/active/2026-08-05_jidoka-code-macos-app.md)

The plan is spike-first. Implementation must first prove the macOS lifecycle, system Pi integration, credential isolation, workflow fidelity, and exact Git publication behavior in the packaged context.

## Scope boundary

The first version is a single-user macOS application. It excludes automatic merge, hosted services, dashboards, multi-user operation, bundled model runtimes, containers, and an updater.

## License

MIT. See [`LICENSE`](LICENSE).
