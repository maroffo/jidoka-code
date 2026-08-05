SHELL := /bin/bash
override DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: check test-e2e jidoka-code-check jidoka-code-test jidoka-code-app jidoka-code-package

check: jidoka-code-check

test-e2e:
	./scripts/spikes/test-s1-package.sh

jidoka-code-check:
	./scripts/verify-toolchain.sh
	@if DEVELOPER_DIR=/tmp ./scripts/verify-toolchain.sh >/dev/null 2>&1; then echo "toolchain verifier accepted an invalid path" >&2; exit 1; fi
	shellcheck scripts/verify-toolchain.sh scripts/package-app.sh scripts/spikes/test-s1-package.sh
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
