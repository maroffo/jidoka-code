# W3 GitHub broker and reconciliation evidence report

Status: **implemented and locally verified**

Date: 2026-08-06

This report covers only W3. It does not claim Git object transport, Pi production workflows, end-to-end coordinators, UI, installer, live Keychain access, or GitHub canary completion. No provider request, real credential access, or GitHub network mutation was performed.

## Scope implemented

- production GitHub token store with fixed service, canonical account validation, atomic update/add-race handling, device-local accessibility, and no payload logging;
- broker-only token-read surface: external targets receive read APIs and a prepared-before-send mutation executor, not raw Keychain data or raw write methods;
- closed 16-operation REST inventory with exact OpenAPI operation ids, methods, paths, query allowlists, API headers, 30-second request timeout, and an exact `api.github.com` host;
- automatic redirect denial plus one explicit same-host canonical repository redirect that requires expected node identity;
- production `URLSession` transport exercised through an offline `URLProtocol` fixture;
- full pagination with 100-item pages, explicit 100,000-item ceiling, and no timestamp window;
- operation-specific status classification for authentication/configuration, permission, primary/secondary rate limits, `Retry-After`, absent/stale targets, validation, reconciliation, retryable reads, and unlisted-status escalation;
- typed GitHub identity, repository, PR, issue, comment, label, and ref decoding;
- deterministic marker canonicalization, 55,000-byte multipart splitting, strict first-line parser, exact part/document digests, author/target/key/revision attribution, and 10 MiB document bound;
- deterministic issue revision using a documented integer/string-only JCS subset, domain-label filtering, numeric comment ordering, linked-input digests, attributed-marker exclusion, and exact base branch/SHA binding;
- durable mutation intents with idempotency collision detection, `prepared` before credential preflight, `sendStarted` immediately before transport, send epochs, reconciliation evidence, and terminal transition guards;
- read-only reconciliation at absolute offsets 1, 2, 5, 10, and 30 seconds with operation-specific safe-retry, attributable-effect, and escalation outcomes;
- exact read-back observation builders for labels, marker comments, PR list plus exact GET, branch refs, and composite claim/plan state;
- PR and issue discovery with full pagination, draft/PR-entry/workflow-label filtering, reviewed revision evidence, durable dispositions, and new-head identity.

## Executed falsifiers

- arbitrary owner, repository, branch, number, page, label, title, body, color, and host-shaped input;
- inventory scan for merge, auto-merge, close, comment/repository deletion, release, and tag operations;
- cross-host, credential-bearing, query-bearing, write, and malformed repository redirects;
- wrong success status, unlisted `404/406/409/410/422`, all documented status classes, numeric and HTTP-date `Retry-After`, timeout, connection loss, oversized response, and cross-host response URL;
- token create/replace race, malformed account, short/non-UTF-8/control/whitespace-bearing token, and missing token;
- LF/CRLF/CR, composed/decomposed Unicode, trailing whitespace, hostile HTML, marker spoof, 55,000/55,001 boundaries, UTF-8 long lines, oversized documents, missing/duplicate/reordered/mutated parts, wrong author, and deterministic fuzz;
- marker without persisted expectation, duplicate comment IDs, malformed timestamps, oversized issue content, workflow-label churn, human edits/comments, domain-label changes, and linked digest changes;
- idempotency collision, invalid target, repeated send, credential failure before send, timeout after send, definitive denial, delayed visibility, exact attribution, and unknown create absence;
- all 10 mutation operations across six crash windows and visible/absent outcomes, with no second create after unknown send and no attribution without exact evidence;
- PR draft/closed/reviewed/durable/new-head cases and issue PR-entry/workflow/domain/closed/durable cases.

## Verification

Executed after the final W3 source edit:

```text
make check
make test-e2e
xcrun swift test --sanitize=address
xcrun swift test --sanitize=thread
```

Results:

- strict Swift format, debug build, release build, XCTest, and all 117 Swift Testing cases passed;
- AddressSanitizer passed all 117 cases;
- ThreadSanitizer passed all 117 cases;
- copied ad-hoc packaged application execution from `/`, signature verification, resource mutation falsifiers, and cleanup passed;
- no provider request, live GitHub request, or real Keychain mutation was issued.

## Remaining risks and exclusions

- The system Security backend compiled but was not executed with a real credential. Real token import/read/replace remains authorization-gated and later onboarding work must use the selected signed helper topology.
- No real GitHub request or write was made. Fine-grained capability proof and canary mutation remain gated by Checkpoint D.
- W4 must implement Git object transport and branch CAS publication; the W3 branch observation defaults to escalation unless that CAS proof is explicitly supplied.
- W6 must connect broker observations, mutation intents, job transitions, and object dispositions into complete workflows.
- W4-W9 still own Git/Pi orchestration, UI, lifecycle integration, installer, final review, and canary evidence.
- The provider ledger remains exhausted at 19 of 19. W3 used zero provider calls.
- Review was parent-owned and local. No independent model reviewer was launched because further provider calls are not authorized.
