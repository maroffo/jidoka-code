# Herdr H3 Pi TUI and structured settlement evidence

Date: 2026-08-09

Base: `origin/main@282e849bdb4fdf573a1cf4f9bddb35c6fffebeed`

Branch: `feat/jidoka-code-herdr-runtime`

## Result

H3 is complete. Jidoka Code now has an exact visible Pi TUI runtime inside a Herdr pane while structured local state remains the only completion authority. The host launches only a private, reverified snapshot of the admitted Node executable, Pi package, fixed `dist/cli.js` entrypoint and complete non-system dynamic-library closure. Pi receives the same workflow model, resources, skills, tools, command provenance, prompt digest and isolated environment as W5, except for the intentional TUI-versus-RPC mode difference.

The packaged TUI extension locks interactive input, verifies the runtime inventory and injects one private digest-bound prompt. It accepts only one causally executed `jidoka_code_result`. Canonical `result.json`, `acknowledgement.json` and `release.json` records are private, create-only, run-bound and independently validated by Swift. Terminal output, Herdr lifecycle, child exit and pane state remain telemetry and cannot settle a run.

Same-run crash recovery and later logical rounds are separate protocols. A boundaryless retry requires an existing schema-2 session identity created by the original fresh launch with the exact run, nonce, session and file. A run created by non-null cross-run resume permanently retains that origin and boundary, so it cannot downgrade to boundaryless recovery. Later planning or orchestration rounds must present the exact prior `sessionBoundarySHA256`, slice history after that settled tool result and send the new pinned prompt. Wrong, missing, ambiguous or downgraded boundaries fail before result recovery or another provider request.

Production workflow composition remains unchanged until H4. H3 exposes the validated terminal boundary and TUI invocation/result-channel seams needed for durable H4 ownership without introducing an invisible fallback.

## Changed surfaces

Primary H3 surfaces:

- `Resources/Pi/extensions/jidoka-tui-runtime.ts`
- `Resources/Pi/runtime/jidoka-tui-contract.mjs`
- `Resources/Pi/tui-resources.json`
- `Sources/JidokaCodeCore/Pi/PiRPCProtocol.swift`
- `Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift`
- `Sources/JidokaCodeCore/Pi/PiTUIRuntime.swift`
- `Sources/JidokaCodeCore/Pi/PiWorkflowResources.swift`
- `Sources/JidokaCodeCore/Herdr/HerdrHostRuntime.swift`
- `Sources/JidokaCodeHerdrFixture/main.swift`
- `Sources/JidokaCodeHerdrHost/main.swift`
- `Tests/JidokaCodeCoreTests/PiRuntimeResolverTests.swift`
- `Tests/JidokaCodeCoreTests/PiTUIRuntimeTests.swift`
- `Tests/JidokaCodeCoreTests/PiWorkflowResourceTests.swift`
- `Tests/JidokaCodeCoreTests/HerdrHostRuntimeTests.swift`
- `scripts/spikes/herdr-s12-fixture.mjs`
- `scripts/spikes/pi-tui-fixture-provider.ts`
- `scripts/spikes/test-s12-pi-tui.sh`
- `scripts/tests/test-jidoka-tui-contract.mjs`

These 18 files contain 11,312 lines. Hashing each listed filename, a NUL separator and its bytes in the order above produces aggregate SHA-256 `1b99d76df0a01e70be2741fbeaebaf8a8ed1078da7cc1a6b759ba37495be5e38`. Applying the same filename-plus-bytes method to every sorted regular file under `Sources` and `Tests` produces `958f7a030a73ec492f2dd3410551774e4f26f8ab8a3c899794742d4b36483088`.

Exact H3 resource anchors:

- TUI extension: `d7c46bf43840613d932c19db36196f741f783d99f666f3b6e89629feb887a031`
- TUI contract: `3019e69f4e92356b55b8c149a420d2ab9816014a6be670ccd4db6887553d64ac`
- TUI resource manifest: `5392fec5eb544dbe0c721692440e8445604d3c05509a39b450f2bb964245f07f`
- S12 harness: `30f064b5c0d1c97240d958b8c19dd6434107d6e0f41aed4dae2ed8075d1cfede`

## Runtime and settlement evidence

- The resolver attests Node `26.6.0`, Pi `0.84.1`, `dist/cli.js` and all declared non-system libraries, then materializes them below one mode-`0700` private snapshot. Reopen verifies marker identity, UID, modes, link counts, ACL authority, ancestors, copied bytes, aliases and the exact entrypoint before execution.
- The child environment is reconstructed, not inherited. Its Node executable, Pi CLI argument and `DYLD_LIBRARY_PATH` all resolve inside the private snapshot. Every `HERDR_*`, secret-shaped and unrelated ambient capability is absent.
- Schema-3 host descriptors distinguish durable logical `runID` from process `launchAttemptID` and reconstruct the complete executable, argv, environment, cwd, timeouts, settlement and nested TUI digest. Matching-digest mutations in every derived family are rejected by the real descriptor-store load path.
- The host owns one exact process group, foreground PTY transfer, timeout, cancellation, descendant termination and terminal restoration. Accepted result state outranks child or telemetry failure; release alone authorizes pane teardown.
- The TUI result includes a digest of the exact canonical successful terminal details. Swift reconstructs those details independently and rejects a mismatched `sessionBoundarySHA256` before acknowledgement.
- W5 parity covers all 15 valid workflow-role pairs with complete ordered argv, exact environment values and independent literal expectations for model, prompt digest, skills, tools and every command-provenance field.

## S12 isolated end-to-end evidence

The final complete E2E run retained the exact S12 artifact at:

`build/evidence/jidoka-herdr-s12.cRex3P`

The corresponding session is `jidoka-s12-crex3p`. The final E2E log prints both values from the same run. `evidence.sha256` inventories 19,182 regular files and has SHA-256 `9a7bccf9a4dac998382de74f0f804f9f0b2fabe9d38bb0de5a478e9b47019f56`; a full `shasum -a 256 -c` verification passed.

S12 proves on real Herdr `0.8.0` / protocol `19` and Pi `0.84.1`:

- an exact visible Pi TUI with locked observer input;
- one fresh pinned prompt and one causally required tool-result continuation;
- exactly two deterministic fixture-provider requests and zero measured network contacts;
- a crash after the terminal tool result is recorded in the Pi session but before side-channel persistence;
- same-run resume from the exact fresh-origin session proof, with no second prompt or provider call;
- one canonical result, acknowledgement and release;
- a real-session later-round boundary that yields an empty current-run suffix and permits the next pinned prompt;
- rejection of both a null boundary under a new run identity and the former non-null-to-null origin downgrade;
- typed runtime-failure relay, exact process-group cleanup and blocked lifecycle;
- unchanged focus, no default-socket contact, no child Herdr capability and pane retention until release.

The final S12 assertion line is:

```text
fresh_prompt=1 causal_tool_loop=1 recorded_before_crash=1 side_channel_before_crash=0 causal_resume=1 resume_prompt=0 cross_run_resume_boundary=1 cross_run_null_downgrade_blocked=1 result=1 acknowledgement=1 typed_runtime_failure=1 manual_input_context=0 pre_result_input_blocked=1 built_in_input_blocked=1 builder_parity=1 exact_process_group=1 old_pane_removed=1 pane_retained_until_release=1 focus_changes=0 provider_network_measured=1 provider_network=0
```

## Verification after the final source edit

- `make check`: 396 tests in 64 suites passed, including toolchain verification, ShellCheck, Node syntax and contract tests, strict Swift format, debug/release builds and the full Swift suite.
- `KEEP_S12_ARTIFACTS=1 make test-e2e`: S1 package, S10 UI, S11 Herdr and S12 Pi TUI all passed. S10 remained `keychain:0,network:0,provider:0,service_management:0`.
- AddressSanitizer focused H3 gate: 83 tests in 7 suites passed.
- ThreadSanitizer focused H3 gate: 83 tests in 7 suites passed.
- Retained S12 evidence manifest: all 19,182 entries passed `shasum -a 256 -c`.
- Final `git diff --check`: passed; the index remained empty.

Evidence logs and SHA-256:

- `/tmp/jidoka-h3-make-check-acceptance.log`: `f4536ff95289623f39dbf7191ed0e0a851b55625b1ce4a33c16fa774b36c0c8f`
- `/tmp/jidoka-h3-test-e2e-acceptance.log`: `cf2dc9d0534d657f8ad879f29899acaa3418ef6787c1e456f30396dfea4ddc3c`
- `/tmp/jidoka-h3-asan-acceptance.log`: `4d0c37f226644e81886fb101722ea0253f667eca0b01f10258e77b5d6b61e3a3`
- `/tmp/jidoka-h3-tsan-acceptance.log`: `feea678f53caf922b2df8ee47b46b075c69cbf3c1251574fdb94953f76269977`
- `/tmp/jidoka-h3-s12-evidence-manifest-verify.log`: `78eac4c41803750ad7aebda3bce524b058b1f30e9d5245819a408aa06e8bcaae`

## Independent review

Fresh read-only architecture, security and test reviewers inspected the implementation, adversarial tests, logs and retained evidence without network access or source edits.

- Architecture: PASS, 98/100, no Critical, Major or Minor findings. It verified visible TUI parity, structured completion authority, origin-bound resume, H4 boundary seam, version-locked settings, host lifecycle ownership, W5 parity and private runtime execution provenance.
- Security: PASS, 97/100, no Critical, Major or Minor findings. It rechecked private runtime and dylib closure, fixed entrypoint identity, ACL/UID/mode/link/ancestor controls, schema-3 reconstruction, capability isolation, settlement causality and schema-2 origin proof.
- Test: PASS, 98/100 with one evidence-lineage Minor. The harness was then changed to retain and print the exact final S12 path plus a digest manifest; all final gates were rerun. The closure review returned PASS, 100/100, with no findings.
- A final security delta review of the evidence-only manifest block returned PASS, 97/100, with no findings and confirmed that it runs only after process/session cleanup and has no runtime-authority or external-destination effect.

Review artifacts:

- `/tmp/h3-arch-review-acceptance-final.txt`: `726649cc5ced4c1e1d2e0529e24d82408c12beb6d2c5cddf060884114e6e118b`
- `/tmp/h3-sec-review-acceptance-final.txt`: `eead920b93502ad2a7bf46858e1e2e574b577635ef839b012744850975828902`
- `/tmp/h3-sec-review-evidence-delta-final.txt`: `7e225c5596cd6c2330e1cf165fc1b1a40796fc3d90cd84c692eb3a4ee358de7a`
- `/tmp/h3-test-review-acceptance-final.txt`: `a2fff6c46d77c7e0484daa07c4169ecec8b4bd37f741f47d7d176997f715a569`
- `/tmp/h3-test-review-lineage-final.txt`: `fc513da6c92b7684194fb2fe3335cc9421cef43ec83d004c1e6da764b5c1be3d`

## Side-effect boundary and residual risk

Automatic tests used named temporary Herdr sessions and explicit named sockets only. They did not contact the real default Herdr socket, change global Herdr configuration, invoke a live provider, access real Keychain credentials, mutate GitHub, register ServiceManagement or install/update software. Every temporary named session was stopped and deleted before PASS. No Pi harness lock remains in the worktree.

Not verified in H3:

- durable database ownership, recovery-first ordering and production injection across the four workflows;
- pause/quit integration and removal of the current direct-RPC production composition;
- host packaging/signing, readiness UI, Herdr binary/schema attestation and operations documentation;
- an explicitly authorized default-session canary or live provider request;
- protection against a malicious process running as the same user.

These are explicit H4-H5 gates. H3 supplies the validated runtime and settlement boundary they must consume; it does not infer their completion.
