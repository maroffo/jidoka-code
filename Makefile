SHELL := /bin/bash
override DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: check test-e2e jidoka-code-check jidoka-code-test jidoka-code-test-herdr jidoka-code-test-herdr-readiness jidoka-code-test-ui jidoka-code-test-s11-herdr jidoka-code-test-s12-pi-tui jidoka-code-w7-acceptance jidoka-code-app jidoka-code-package jidoka-code-test-s2-preflight jidoka-code-test-s3-preflight jidoka-code-test-s4-preflight jidoka-code-test-s5-s7-preflight jidoka-code-test-s8-preflight jidoka-code-test-s9-preflight

check: jidoka-code-check

test-e2e:
	./scripts/spikes/test-s1-package.sh
	./scripts/spikes/test-s10-ui.sh
	./scripts/spikes/test-s11-herdr.sh
	./scripts/spikes/test-s12-pi-tui.sh

jidoka-code-check:
	./scripts/verify-toolchain.sh
	@if DEVELOPER_DIR=/tmp ./scripts/verify-toolchain.sh >/dev/null 2>&1; then echo "toolchain verifier accepted an invalid path" >&2; exit 1; fi
	shellcheck scripts/verify-toolchain.sh scripts/package-app.sh scripts/package-installer.sh scripts/spikes/test-s1-package.sh scripts/spikes/test-s2-lifecycle.sh scripts/spikes/test-s3-keychain.sh scripts/spikes/test-s4-pi.sh scripts/spikes/test-s5-s7-local.sh scripts/spikes/test-s8-workflows.sh scripts/spikes/test-s9-topology.sh scripts/spikes/test-s10-ui.sh scripts/spikes/test-s11-herdr.sh scripts/spikes/test-s12-pi-tui.sh
	/usr/bin/perl -c scripts/run-bounded-command.pl
	/usr/bin/plutil -lint Packaging/app-component.plist
	/usr/bin/plutil -convert xml1 -o /dev/null Resources/Herdr/runtime-builds.json
	test "$$(/usr/bin/plutil -extract protocol raw Resources/Herdr/api-schema-0.8.0.json)" = "19"
	test "$$(/usr/bin/shasum -a 256 Resources/Herdr/api-schema-0.8.0.json | /usr/bin/awk '{print $$1}')" = "88ff414aa996e390c2db05a37b95d28dbe4e81b98329f6ed7f7a2cc5c6ebf51a"
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/herdr-s11-fixture.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/herdr-s12-fixture.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/pi-tui-fixture-provider.ts
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/jidoka-local-spikes.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/pi-keychain-denial-probe.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/pi-provider-gate-probe.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/pi-runtime-attestation.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/tests/test-pi-runtime-attestation.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node scripts/tests/test-pi-runtime-attestation.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/tests/test-jidoka-extension-contract.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node scripts/tests/test-jidoka-extension-contract.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/tests/test-jidoka-extension-rpc.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node scripts/tests/test-jidoka-extension-rpc.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/tests/test-jidoka-tui-contract.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node scripts/tests/test-jidoka-tui-contract.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/pi-rpc-profile-probe.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/pi-rpc-workflow-probe.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/extensions/jidoka-code.ts
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/extensions/jidoka-deny-user-bash.js
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/extensions/jidoka-runtime.ts
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/extensions/jidoka-tui-runtime.ts
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/runtime/jidoka-extension-contract.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/runtime/jidoka-tui-contract.mjs
	xcrun swift-format lint --recursive --strict Sources Tests
	xcrun swift build --configuration debug
	xcrun swift build --configuration release
	xcrun swift test

jidoka-code-test:
	./scripts/verify-toolchain.sh
	xcrun swift test

jidoka-code-test-herdr:
	./scripts/verify-toolchain.sh
	xcrun swift test --filter Herdr

jidoka-code-test-herdr-readiness:
	./scripts/verify-toolchain.sh
	xcrun swift test --filter HerdrRuntimeReadinessTests

jidoka-code-test-ui:
	./scripts/spikes/test-s10-ui.sh

jidoka-code-test-s11-herdr:
	./scripts/spikes/test-s11-herdr.sh

jidoka-code-test-s12-pi-tui:
	./scripts/spikes/test-s12-pi-tui.sh

jidoka-code-w7-acceptance: jidoka-code-check jidoka-code-test-ui

jidoka-code-app:
	./scripts/verify-toolchain.sh
	xcrun swift build --configuration release --product JidokaCodeApp

jidoka-code-package:
	./scripts/package-installer.sh

jidoka-code-test-s2-preflight:
	./scripts/spikes/test-s2-lifecycle.sh --preflight-only

jidoka-code-test-s3-preflight:
	./scripts/spikes/test-s3-keychain.sh --preflight-only

jidoka-code-test-s4-preflight:
	./scripts/spikes/test-s4-pi.sh --preflight-only

jidoka-code-test-s5-s7-preflight:
	./scripts/spikes/test-s5-s7-local.sh --preflight-only

jidoka-code-test-s8-preflight:
	./scripts/spikes/test-s8-workflows.sh --preflight-only

jidoka-code-test-s9-preflight:
	./scripts/spikes/test-s9-topology.sh --preflight-only
