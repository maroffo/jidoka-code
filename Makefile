SHELL := /bin/bash
override DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
JIDOKA_RELEASE_RUNTIME_ROOT ?= $(CURDIR)/build/runtime-input/qualified-runtime
override NODE := $(abspath $(JIDOKA_RELEASE_RUNTIME_ROOT))/node/bin/node
export JIDOKA_RELEASE_RUNTIME_ROOT

.PHONY: check test-e2e jidoka-code-check jidoka-code-test jidoka-code-test-herdr jidoka-code-test-herdr-readiness jidoka-code-test-ui jidoka-code-test-s11-herdr jidoka-code-test-s12-pi-tui jidoka-code-w7-acceptance jidoka-code-app jidoka-code-package jidoka-code-test-s2-preflight jidoka-code-test-s3-preflight jidoka-code-test-s4-preflight jidoka-code-test-s5-s7-preflight jidoka-code-test-s8-preflight jidoka-code-test-s9-preflight jidoka-code-test-w5-preflight jidoka-code-test-location-probe-packaging

jidoka-code-test-w5-preflight:
	./scripts/tests/test-production-readiness-preflight.sh

jidoka-code-test-location-probe-packaging:
	./scripts/tests/test-location-probe-packaging.sh

check: jidoka-code-check

test-e2e:
	./scripts/spikes/test-s1-package.sh
	./scripts/spikes/test-s10-ui.sh
	./scripts/spikes/test-s11-herdr.sh
	./scripts/spikes/test-s12-pi-tui.sh

jidoka-code-check:
	test "$$(PATH=/nonexistent /bin/bash ./scripts/qualified-runtime-node.sh)" = "$(NODE)"
	./scripts/verify-toolchain.sh
	@if DEVELOPER_DIR=/tmp ./scripts/verify-toolchain.sh >/dev/null 2>&1; then echo "toolchain verifier accepted an invalid path" >&2; exit 1; fi
	shellcheck scripts/verify-toolchain.sh scripts/qualified-runtime-node.sh scripts/tests/fixtures/pi-rpc-process.sh scripts/package-app.sh scripts/package-installer.sh scripts/production-readiness-preflight.sh scripts/build-location-probe-packages.sh scripts/audit-location-probe-packages.sh scripts/tests/test-production-readiness-preflight.sh scripts/tests/test-location-probe-packaging.sh scripts/spikes/test-s1-package.sh scripts/spikes/test-s2-lifecycle.sh scripts/spikes/test-s3-keychain.sh scripts/spikes/test-s4-pi.sh scripts/spikes/test-s5-s7-local.sh scripts/spikes/test-s8-workflows.sh scripts/spikes/test-s9-topology.sh scripts/spikes/test-s10-ui.sh scripts/spikes/test-s11-herdr.sh scripts/spikes/test-s12-pi-tui.sh
	./scripts/tests/test-production-readiness-preflight.sh
	./scripts/tests/test-location-probe-packaging.sh
	/usr/bin/perl -c scripts/run-bounded-command.pl
	/usr/bin/plutil -lint Packaging/app-component.plist
	/usr/bin/plutil -convert xml1 -o /dev/null Resources/Herdr/runtime-builds.json
	test "$$(/usr/bin/plutil -extract protocol raw Resources/Herdr/api-schema-0.8.2.json)" = "20"
	test "$$(/usr/bin/shasum -a 256 Resources/Herdr/api-schema-0.8.2.json | /usr/bin/awk '{print $$1}')" = "c48f1f54ee0150ca27e11fd44455fe94aeadb20fdf4e4a62393ed822a4e5b150"
	$(NODE) --check scripts/tests/test-herdr-schema-compatibility.mjs
	$(NODE) scripts/tests/test-herdr-schema-compatibility.mjs
	$(NODE) --check scripts/spikes/herdr-s11-fixture.mjs
	$(NODE) --check scripts/spikes/herdr-s12-fixture.mjs
	$(NODE) --check scripts/spikes/pi-tui-fixture-provider.ts
	$(NODE) --check scripts/spikes/jidoka-local-spikes.mjs
	$(NODE) --check scripts/tests/test-local-spike-runtime-attestation.mjs
	$(NODE) scripts/tests/test-local-spike-runtime-attestation.mjs
	$(NODE) --check scripts/spikes/pi-keychain-denial-probe.mjs
	$(NODE) --check scripts/spikes/pi-provider-gate-probe.mjs
	$(NODE) --check scripts/spikes/pi-runtime-attestation.mjs
	$(NODE) --check scripts/tests/test-pi-runtime-attestation.mjs
	$(NODE) scripts/tests/test-pi-runtime-attestation.mjs
	$(NODE) --check scripts/tests/test-jidoka-extension-contract.mjs
	$(NODE) scripts/tests/test-jidoka-extension-contract.mjs
	$(NODE) --check scripts/tests/test-jidoka-extension-rpc.mjs
	$(NODE) scripts/tests/test-jidoka-extension-rpc.mjs
	$(NODE) --check scripts/tests/test-jidoka-tui-contract.mjs
	$(NODE) scripts/tests/test-jidoka-tui-contract.mjs
	$(NODE) --check scripts/spikes/pi-rpc-profile-probe.mjs
	$(NODE) --check scripts/spikes/pi-rpc-workflow-probe.mjs
	$(NODE) --check Resources/Pi/extensions/jidoka-code.ts
	$(NODE) --check Resources/Pi/extensions/jidoka-deny-user-bash.js
	$(NODE) --check Resources/Pi/extensions/jidoka-runtime.ts
	$(NODE) --check Resources/Pi/extensions/jidoka-tui-runtime.ts
	$(NODE) --check Resources/Pi/runtime/jidoka-extension-contract.mjs
	$(NODE) --check Resources/Pi/runtime/jidoka-model-catalog.mjs
	$(NODE) --check Resources/Pi/runtime/jidoka-tui-contract.mjs
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

jidoka-code-w7-acceptance: jidoka-code-check jidoka-code-test-ui jidoka-code-test-s4-preflight jidoka-code-test-s8-preflight

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
