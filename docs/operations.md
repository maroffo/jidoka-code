# Jidoka Code operations

## Runtime prerequisites

Jidoka Code requires macOS 14 or later and an external Herdr runtime. The initial compatibility policy accepts only Herdr `0.8.0`, socket protocol `19`, the approved arm64 executable digest, and the approved bundled API schema digest.

Herdr remains user-managed. Jidoka Code does not install, update, configure, start, stop, or bundle Herdr. Production always uses the current user's global socket at `~/.config/herdr/herdr.sock`. Repository, workflow, model, UI, and environment values cannot select another production endpoint.

Before enabling automation, onboarding verifies:

- the external executable resolves from the fixed Homebrew link and matches the signed compatibility policy;
- `herdr --version` and `herdr api schema --json` produce exact bounded output under a credentialless environment;
- the schema bytes, schema version, and protocol match the packaged policy;
- the global socket is a current-user Unix socket with mode `0600`;
- the live handshake reports Herdr `0.8.0`, protocol `19`, `live_handoff`, and `detached_server_daemon`.

Any mismatch keeps discovery, topology creation, Pi launch, and approved-command admission closed. There is no direct-RPC or private-session fallback.

## Shared-session disclosure

Jidoka Code uses the same global Herdr session as user-owned terminals. Each Jidoka role appears as a top-level pane. Agent prompts, model output, tool activity, and terminal presentation are visible to anyone who can observe that user session.

Jidoka Code does not copy the Herdr transcript into its application logs. This does not erase content from Herdr, Pi session files, provider retention, terminal scrollback, backups, or other same-user tools.

Manual interaction remains possible, with these consequences:

- rename: display-only; durable ownership is unchanged;
- move: followed only while terminal and process identity still match;
- close during active work: an unknown interruption, never automatic success or blind rerun;
- terminal input or takeover: cannot create structured acceptance, but may make ownership unprovable;
- metadata edits: never authorize completion, cleanup, or mutation.

Canonical result, acknowledgement, release, and approved-command records in SQLite remain the only completion authority.

## Readiness and focus controls

Onboarding and Settings expose `Run Herdr Preflight`. State is `unchecked`, `ready`, or `blocked`, with a closed diagnostic code and recovery text.

A wake or network-regain event rechecks readiness before requesting work. The production dispatch gate also rechecks readiness before reopening launch admission. If Herdr is unavailable at login, the engine remains available for status and recovery while new dispatch stays closed.

`Open in Herdr` and `Open Most Recent Jidoka Pane in Herdr` are explicit user actions. Jidoka Code never changes Herdr focus during startup, polling, readiness checks, topology creation, or recovery. Before focus, it re-proves durable workspace, tab, pane, terminal, host PID/start identity, executable, and role-host argv. A foreign or reused pane is left untouched.

## Pause, quit, and recovery

Pause closes topology, Pi-launch, and approved-command admission before persisting pause. Operations already admitted may settle; later operations are rejected.

Quit waits for admitted work, records any bounded interruption, closes only newly revalidated Jidoka-owned panes, checkpoints SQLite, and leaves the global Herdr server and foreign terminals running.

Startup recovery closes dispatch, attests Herdr, imports exact result evidence, reconstructs topology, recovers approved-command authority, then recovers generic jobs. A started approved command without exact accepted evidence becomes irreversible `unknown` and is not rerun.

If a pane was closed or taken over:

1. do not recreate it manually as proof of completion;
2. run Herdr preflight;
3. inspect the blocked job and durable diagnostic;
4. resolve or explicitly abandon unknown external effects;
5. retry only through the application after ownership and command authority are restored.

## Automation boundaries

The GitHub credential is imported into Keychain after validation and is never passed to Pi. Pi/provider authentication remains separate from the GitHub mutation capability. Repository toggles control discovery only for the selected workflows; disabling a toggle does not erase durable work or unknown effects.

Jidoka Code does not merge pull requests, bypass Git hooks, force-push, or treat model output as publication approval. Pause closes new mutation admission but preserves reconciliation already due. Redacted application logs are under `~/Library/Application Support/JidokaCode/Logs`; Herdr and Pi retain their own separately governed session data.

## Build and package audit

A release package requires separate explicit 40-character SHA-1 identities for application code and the installer:

```sh
SIGN_IDENTITY=<developer-id-application-sha1> \
INSTALLER_SIGN_IDENTITY=<developer-id-installer-sha1> \
make jidoka-code-package
```

`SIGNING_KEYCHAIN=<canonical-keychain-path>` may select a dedicated signing keychain. When supplied, that keychain must also be on the user's keychain search list while `codesign` runs.

Notarization is an explicit network mode. The App Store Connect private key must be a canonical, single-link, current-user file with permissions `0400` or `0600`:

```sh
SIGN_IDENTITY=<developer-id-application-sha1> \
INSTALLER_SIGN_IDENTITY=<developer-id-installer-sha1> \
NOTARIZE_PACKAGE=1 \
NOTARY_KEY=<canonical-p8-path> \
NOTARY_KEY_ID=<app-store-connect-key-id> \
NOTARY_ISSUER=<app-store-connect-issuer-uuid> \
make jidoka-code-package
```

The build produces:

- `build/Jidoka Code.app`;
- `build/Jidoka Code.pkg`;
- `build/package-manifest.json`;
- `build/notarization-result.json` only after Apple returns `Accepted`.

The script signs nested executables before the outer app with Developer ID Application, verifies one Team ID and trusted timestamps, enforces the closed `Packaging/app-inventory.txt`, rejects symlinks and a bundled Herdr executable, and compares the installer payload with the signed app inventory. `productbuild` signs the product with Developer ID Installer and the selected certificate fingerprint. The installer has identifier `com.maroffo.JidokaCode.pkg`, version `0.1.0`, and destination `/Applications/Jidoka Code.app`. It has no lifecycle scripts.

With `NOTARIZE_PACKAGE=1`, the product is published only after Apple Notary Service returns `Accepted`, `stapler` succeeds, `stapler validate` passes, and Gatekeeper reports `Notarized Developer ID`. The manifest SHA-256 binds the post-staple package bytes and records the submission ID. Without that flag, the package remains Developer ID signed but unnotarized.

Package construction and notarization never invoke `installer`, ServiceManagement, application credentials, providers, or the default Herdr session. Installation and the production canary remain separate approval checkpoints.

After separate installation approval, validate the package before invoking `installer`:

```sh
pkgutil --payload-files "build/Jidoka Code.pkg"
pkgutil --check-signature "build/Jidoka Code.pkg"
xcrun stapler validate "build/Jidoka Code.pkg"
spctl -a -vv -t install "build/Jidoka Code.pkg"
codesign --verify --strict --deep "build/Jidoka Code.app"
```

A notarized build must report an Apple Developer ID Installer signature, trusted timestamp, trusted Apple notarization, and `source=Notarized Developer ID`. Compare `shasum -a 256 "build/Jidoka Code.pkg"` with `package-manifest.json`.

## Uninstall boundary

Uninstall is manual and separately authorized. Stop or quit Jidoka Code first. Remove only the installed application and its exact receipt after confirming those targets. Do not remove `~/.config/herdr`, the Herdr socket, Herdr workspaces, Pi sessions, repositories, credentials, or provider data. User database and evidence removal is a separate data-retention decision, not part of application uninstall.

## Compatibility changes

A Herdr upgrade fails closed until a reviewed policy update records the new executable, version output, full JSON schema digest, protocol, architecture, and platform. Never relax a digest or accept arbitrary CLI output to restore readiness. Build and verify a new package, rerun the full test and sanitizer gates, and perform any live canary only after separate authorization.
