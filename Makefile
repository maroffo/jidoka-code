SHELL := /bin/bash
override DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: check test-e2e jidoka-code-check jidoka-code-test jidoka-code-app jidoka-code-package jidoka-code-test-s2-preflight jidoka-code-test-s3-preflight jidoka-code-test-s4-preflight jidoka-code-test-s5-s7-preflight jidoka-code-test-s8-preflight jidoka-code-test-s9-preflight

check: jidoka-code-check

test-e2e:
	./scripts/spikes/test-s1-package.sh

jidoka-code-check:
	./scripts/verify-toolchain.sh
	@if DEVELOPER_DIR=/tmp ./scripts/verify-toolchain.sh >/dev/null 2>&1; then echo "toolchain verifier accepted an invalid path" >&2; exit 1; fi
	shellcheck scripts/verify-toolchain.sh scripts/package-app.sh scripts/spikes/test-s1-package.sh scripts/spikes/test-s2-lifecycle.sh scripts/spikes/test-s3-keychain.sh scripts/spikes/test-s4-pi.sh scripts/spikes/test-s5-s7-local.sh scripts/spikes/test-s8-workflows.sh scripts/spikes/test-s9-topology.sh
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
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/pi-rpc-profile-probe.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check scripts/spikes/pi-rpc-workflow-probe.mjs
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/extensions/jidoka-code.ts
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/extensions/jidoka-deny-user-bash.js
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/extensions/jidoka-runtime.ts
	/opt/homebrew/Cellar/node/26.6.0/bin/node --check Resources/Pi/runtime/jidoka-extension-contract.mjs
	xcrun swift-format lint --recursive --strict Sources Tests
	xcrun swift build --configuration debug
	xcrun swift build --configuration release
	xcrun swift test

jidoka-code-test:
	./scripts/verify-toolchain.sh
	xcrun swift test

jidoka-code-app:
	./scripts/verify-toolchain.sh
	xcrun swift build --configuration release --product JidokaCodeApp

jidoka-code-package:
	./scripts/package-app.sh

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
