import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmdirSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { Type } from "typebox";

const authorizedModel = "openai-codex/gpt-5.6-sol:max";
const authorizedCallCap = 19;
let providerRequestCount = 0;
let ownedProviderLockPath: string | undefined;

function releaseProviderLock(): void {
  if (ownedProviderLockPath === undefined) return;
  try {
    if (existsSync(ownedProviderLockPath)) rmdirSync(ownedProviderLockPath);
  } catch {
    // A retained lock fails closed for every future provider attempt.
  }
  ownedProviderLockPath = undefined;
}

function exitBeforeProviderRequest(reason: string): never {
  releaseProviderLock();
  process.stderr.write(`JIDOKA_PROVIDER_GATE_BLOCKED:${reason}\n`);
  process.exit(86);
}

function transitionReservedAttemptToIssued(): void {
  if (process.env.JIDOKA_PROVIDER_GATE !== "1") {
    exitBeforeProviderRequest("gate-disabled");
  }
  const attemptId = process.env.JIDOKA_PROVIDER_ATTEMPT_ID;
  const requestedLedgerPath = process.env.JIDOKA_PROVIDER_LEDGER;
  if (
    typeof attemptId !== "string" ||
    !/^s[48]-[a-z0-9][a-z0-9-]{0,63}$/.test(attemptId) ||
    typeof requestedLedgerPath !== "string"
  ) {
    exitBeforeProviderRequest("invalid-gate-environment");
  }

  providerRequestCount += 1;
  if (providerRequestCount !== 1) {
    exitBeforeProviderRequest("multiple-provider-requests");
  }

  const absoluteLedgerPath = resolve(requestedLedgerPath);
  const home = process.env.HOME;
  const canonicalLedgerPath =
    typeof home === "string"
      ? resolve(home, "Library/Application Support/JidokaCode/Consent/provider-call-ledger.json")
      : undefined;
  if (
    basename(absoluteLedgerPath) !== "provider-call-ledger.json" ||
    absoluteLedgerPath !== canonicalLedgerPath
  ) {
    exitBeforeProviderRequest("invalid-ledger-name");
  }
  const parent = dirname(absoluteLedgerPath);
  let parentStat;
  try {
    parentStat = lstatSync(parent);
  } catch {
    exitBeforeProviderRequest("missing-ledger-parent");
  }
  if (!parentStat.isDirectory() || parentStat.isSymbolicLink()) {
    exitBeforeProviderRequest("unsafe-ledger-parent");
  }
  const realParent = realpathSync(parent);
  if (realParent !== parent) exitBeforeProviderRequest("redirected-ledger-parent");
  const ledgerPath = `${realParent}/provider-call-ledger.json`;
  const lockPath = `${ledgerPath}.lock`;
  try {
    mkdirSync(lockPath, { mode: 0o700 });
    ownedProviderLockPath = lockPath;
  } catch {
    exitBeforeProviderRequest("ledger-locked");
  }

  try {
    const ledgerStat = lstatSync(ledgerPath);
    if (
      !ledgerStat.isFile() ||
      ledgerStat.isSymbolicLink() ||
      (ledgerStat.mode & 0o077) !== 0 ||
      (typeof process.getuid === "function" && ledgerStat.uid !== process.getuid())
    ) {
      exitBeforeProviderRequest("unsafe-ledger");
    }
    const ledger = JSON.parse(readFileSync(ledgerPath, "utf8"));
    const attemptIds = new Set<string>();
    const fixtureIds = new Set<string>();
    const attemptsValid =
      Array.isArray(ledger?.attempts) &&
      ledger.attempts.every(
        (candidate: {
          attemptId?: unknown;
          fixtureId?: unknown;
          state?: unknown;
          profile?: unknown;
          workflow?: unknown;
        }) => {
          if (
            typeof candidate?.attemptId !== "string" ||
            !/^s[48]-[a-z0-9][a-z0-9-]{0,63}$/.test(candidate.attemptId) ||
            typeof candidate.fixtureId !== "string" ||
            !/^[a-z0-9][a-z0-9-]{0,63}$/.test(candidate.fixtureId) ||
            !["reserved", "issued", "settled", "failed"].includes(
              String(candidate.state),
            ) ||
            !["review", "triage", "planning", "orchestration"].includes(
              String(candidate.profile),
            ) ||
            !["S4", "S8"].includes(String(candidate.workflow)) ||
            attemptIds.has(candidate.attemptId) ||
            fixtureIds.has(candidate.fixtureId)
          ) {
            return false;
          }
          attemptIds.add(candidate.attemptId);
          fixtureIds.add(candidate.fixtureId);
          return true;
        },
      );
    if (
      ledger?.schemaVersion !== 1 ||
      ledger?.authorizedCallCap !== authorizedCallCap ||
      ledger?.model !== authorizedModel ||
      ledger?.retry !== false ||
      !attemptsValid ||
      ledger.attempts.length > authorizedCallCap
    ) {
      exitBeforeProviderRequest("invalid-ledger-contract");
    }
    const attempt = ledger.attempts.find(
      (candidate: { attemptId?: string }) => candidate?.attemptId === attemptId,
    );
    if (attempt === undefined || attempt.state !== "reserved") {
      exitBeforeProviderRequest("attempt-not-reserved");
    }
    attempt.state = "issued";
    attempt.issuedAt = new Date().toISOString();
    attempt.providerRequestCount = 1;

    const temporary = `${parent}/.provider-call-ledger.${process.pid}.${randomUUID()}`;
    let descriptor: number | undefined;
    try {
      descriptor = openSync(temporary, "wx", 0o600);
      writeFileSync(descriptor, `${JSON.stringify(ledger)}\n`, "utf8");
      fsyncSync(descriptor);
      closeSync(descriptor);
      descriptor = undefined;
      renameSync(temporary, ledgerPath);
      const directoryDescriptor = openSync(parent, "r");
      fsyncSync(directoryDescriptor);
      closeSync(directoryDescriptor);
    } finally {
      if (descriptor !== undefined) closeSync(descriptor);
      if (existsSync(temporary)) unlinkSync(temporary);
    }
  } catch {
    exitBeforeProviderRequest("ledger-transition-failed");
  } finally {
    releaseProviderLock();
  }
}

const Profile = Type.Union([
  Type.Literal("review"),
  Type.Literal("triage"),
  Type.Literal("planning"),
  Type.Literal("orchestration"),
]);

const Verdict = Type.Union([
  Type.Literal("pass"),
  Type.Literal("escalate"),
  Type.Literal("block"),
]);

const ResultParameters = Type.Object(
  {
    schemaVersion: Type.Literal(1),
    profile: Profile,
    role: Type.String({ minLength: 1, maxLength: 64 }),
    fixtureId: Type.String({ pattern: "^[a-z0-9][a-z0-9-]{0,63}$" }),
    verdict: Verdict,
    summary: Type.String({ minLength: 1, maxLength: 280 }),
    invariants: Type.Array(Type.String({ minLength: 1, maxLength: 80 }), {
      minItems: 1,
      maxItems: 8,
      uniqueItems: true,
    }),
  },
  { additionalProperties: false },
);

export default function jidokaRuntime(pi: ExtensionAPI) {
  let resultCount = 0;

  pi.on("before_provider_request", () => {
    transitionReservedAttemptToIssued();
  });

  pi.registerCommand("jidoka-provenance", {
    description: "Report that the packaged Jidoka Code runtime extension loaded",
    handler: async (_args, ctx) => {
      ctx.ui.notify("JIDOKA_RUNTIME_LOADED", "info");
    },
  });

  // W5/S8 exercise this terminating tool. S4 deliberately disables all tools and
  // validates one strict JSON assistant response so one reservation equals one request.
  pi.registerTool({
    name: "jidoka_result",
    label: "Jidoka Result",
    description:
      "Return the single final machine-readable result for the active Jidoka Code fixture.",
    promptSnippet: "Emit exactly one terminating Jidoka Code result",
    promptGuidelines: [
      "Call jidoka_result exactly once as the final action for a Jidoka Code fixture.",
      "Do not emit a second result or continue after the tool call.",
    ],
    parameters: ResultParameters,
    async execute(_toolCallId, params) {
      resultCount += 1;
      if (resultCount !== 1) {
        return {
          content: [{ type: "text", text: "Multiple results are forbidden" }],
          details: { rejected: true },
          isError: true,
          terminate: true,
        };
      }
      return {
        content: [{ type: "text", text: `Recorded ${params.profile}:${params.fixtureId}` }],
        details: { ...params, resultSequence: resultCount },
        terminate: true,
      };
    },
  });
}
