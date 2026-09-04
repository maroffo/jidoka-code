#!/usr/bin/env bash
# ABOUTME: Source-controlled deterministic Swift acceptance for rollout authority W0 through W6.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly ROOT
TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/jidoka-rollout-acceptance.XXXXXX")"
readonly TEST_LOG
trap 'rm -f "$TEST_LOG"' EXIT

readonly -a REQUIRED_SUITES=(
    RolloutAuthorityStoreTests
    RolloutRemotePreviewRevalidatorTests
    RolloutReleaseIdentityAttestorTests
    GitRolloutPreviewTests
    EngineProtocolTests
    EngineServiceTests
    DurableSchedulerTests
    JobCoordinatorTests
    DurableJobStoreTests
    GitHubHTTPTests
    GitPublicationTests
    MutationReconcilerTests
    DurableApprovedCommandExecutorTests
    PullRequestReviewJobWorkflowTests
    IssueTriageJobWorkflowTests
    IssueImplementationJobWorkflowTests
)

cd "$ROOT"
test_list="$(/usr/bin/xcrun swift test list)"
readonly test_list
for suite in "${REQUIRED_SUITES[@]}"; do
    if [[ "$test_list" != *".$suite/"* ]]; then
        printf 'progressive production acceptance: missing test suite %s\n' "$suite" >&2
        exit 1
    fi
done

filter="$(IFS='|'; printf '%s' "${REQUIRED_SUITES[*]}")"
readonly filter
/usr/bin/xcrun swift test --filter "$filter" 2>&1 | /usr/bin/tee "$TEST_LOG"
/usr/bin/grep -Eq 'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' \
    "$TEST_LOG" || {
    printf 'progressive production acceptance: missing positive nonzero test summary\n' >&2
    exit 1
}
if /usr/bin/grep -Fq '.cleanupFailed' "$TEST_LOG"; then
    printf 'progressive production acceptance: cleanupFailed requires investigation\n' >&2
    exit 1
fi

printf 'progressive production automation acceptance: PASS suites=%s\n' \
    "${#REQUIRED_SUITES[@]}"
