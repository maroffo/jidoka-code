import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import {
  buildWorkspaceQuery,
  editWorkspaceFile,
  expectedActiveTools,
  jidokaExtensionContract,
  loadRuntimeConfiguration,
  readWorkspaceFile,
  runWorkspaceQuery,
  validateBuiltInToolCall,
  validateTerminalResult,
  writeWorkspaceFile,
} from "../runtime/jidoka-extension-contract.mjs";

const configuration = loadRuntimeConfiguration();

const Severity = StringEnum(["none", "info", "minor", "major", "critical"] as const);
const Complexity = StringEnum([
  "simple",
  "moderate",
  "complex",
  "humanOwned",
  "unknown",
] as const);
const Finding = Type.Object(
  {
    severity: StringEnum(["critical", "major", "minor", "info"] as const),
    path: Type.String({ maxLength: 1_024 }),
    line: Type.Integer({ minimum: 0 }),
    evidence: Type.String({ minLength: 1, maxLength: 4_096 }),
    recommendation: Type.String({ minLength: 1, maxLength: 4_096 }),
  },
  { additionalProperties: false },
);
const ClassifierFacts = Type.Object(
  {
    workstreamCount: Type.Integer({ minimum: 1, maximum: 100 }),
    publicAPI: Type.Boolean(),
    nonDestructiveSchema: Type.Boolean(),
    crossModuleConcurrency: Type.Boolean(),
    crossRepositoryCoordination: Type.Boolean(),
    operationalRollback: Type.Boolean(),
    designAlternatives: Type.Boolean(),
    humanDecisionGap: Type.Boolean(),
    securityOrSecretCore: Type.Boolean(),
    dataLossMigration: Type.Boolean(),
    releaseOrTag: Type.Boolean(),
    infrastructureBlastRadius: Type.Boolean(),
    unresolvedDesignDebate: Type.Boolean(),
    unverifiable: Type.Boolean(),
  },
  { additionalProperties: false },
);
const CommandDefinition = Type.Object(
  {
    id: Type.String({ pattern: "^[a-z0-9][a-z0-9-]{0,63}$" }),
    registryKind: StringEnum([
      "makeTargets",
      "swiftBuildTest",
      "xcodebuildBuildTest",
      "repositoryScript",
      "gitRead",
      "gitStage",
      "gitCommit",
    ] as const),
    executableOrRepositoryScript: Type.String({ minLength: 1, maxLength: 1_024 }),
    arguments: Type.Array(Type.String({ maxLength: 4_096 }), { maxItems: 256 }),
    workingDirectory: Type.String({ minLength: 1, maxLength: 1_024 }),
    environmentOverrides: Type.Record(Type.String(), Type.String({ maxLength: 4_096 })),
    timeoutSeconds: Type.Integer({ minimum: 1, maximum: 3_600 }),
    rationale: Type.String({ minLength: 1, maxLength: 2_000 }),
    sourceDigest: Type.Union([
      Type.Null(),
      Type.String({ pattern: "^[0-9a-f]{64}$" }),
    ]),
    approvedHookPath: Type.Union([
      Type.Null(),
      Type.String({ minLength: 1, maxLength: 1_024 }),
    ]),
  },
  { additionalProperties: false },
);
const Evidence = Type.Array(Type.String({ minLength: 1, maxLength: 4_096 }), {
  maxItems: 128,
  uniqueItems: true,
});
const Findings = Type.Array(Finding, { maxItems: 100 });

function payloadSchema() {
  switch (configuration.workflow) {
    case "pr-review":
      return Type.Object(
        {
          verdict: StringEnum(["pass", "block"] as const),
          severity: Severity,
          summary: Type.String({ minLength: 1, maxLength: 2_000 }),
          domain: StringEnum(["architecture", "security", "test", "synthesis"] as const),
          commitNarrativeSHA256: Type.String({ pattern: "^[0-9a-f]{64}$" }),
          evidence: Evidence,
          findings: Findings,
        },
        { additionalProperties: false },
      );
    case "issue-triage":
      return Type.Object(
        {
          verdict: StringEnum(["ready", "needs-spec", "human"] as const),
          severity: Severity,
          summary: Type.String({ minLength: 1, maxLength: 2_000 }),
          rubric: Type.Object(
            {
              specified: Type.String({ minLength: 1, maxLength: 2_000 }),
              testable: Type.String({ minLength: 1, maxLength: 2_000 }),
              bounded: Type.String({ minLength: 1, maxLength: 2_000 }),
              safe: Type.String({ minLength: 1, maxLength: 2_000 }),
            },
            { additionalProperties: false },
          ),
          hardRiskFlags: Type.Array(
            StringEnum(
              jidokaExtensionContract.hardRiskFlags as readonly [
                "security-or-secret-core",
                "data-loss-migration",
                "release-or-tag",
                "infrastructure-blast-radius",
                "cross-repository-coordination",
                "unresolved-design-debate",
                "unverifiable",
              ],
            ),
            { maxItems: 7, uniqueItems: true },
          ),
          rationale: Type.String({ minLength: 1, maxLength: 8_000 }),
          questions: Type.Array(Type.String({ minLength: 1, maxLength: 1_000 }), {
            maxItems: 20,
            uniqueItems: true,
          }),
          complexityGuess: Complexity,
        },
        { additionalProperties: false },
      );
    case "planning":
      return Type.Object(
        {
          verdict: StringEnum(["pass", "revise", "escalate"] as const),
          severity: Severity,
          summary: Type.String({ minLength: 1, maxLength: 2_000 }),
          proposedComplexity: Complexity,
          classifierFacts: ClassifierFacts,
          evidence: Evidence,
          findings: Findings,
          commandDefinitions: Type.Array(CommandDefinition, { maxItems: 64 }),
          approvedCommandDigests: Type.Array(
            Type.String({ pattern: "^[0-9a-f]{64}$" }),
            { maxItems: 64, uniqueItems: true },
          ),
          approvedPlanDigest: Type.Union([
            Type.Null(),
            Type.String({ pattern: "^[0-9a-f]{64}$" }),
          ]),
          planMarkdown: Type.String({ maxLength: 262_144 }),
        },
        { additionalProperties: false },
      );
    case "orchestration":
      return Type.Object(
        {
          verdict: StringEnum(["pass", "revise", "block"] as const),
          severity: Severity,
          summary: Type.String({ minLength: 1, maxLength: 2_000 }),
          evidence: Evidence,
          findings: Findings,
          changedPaths: Type.Array(Type.String({ minLength: 1, maxLength: 1_024 }), {
            maxItems: 256,
            uniqueItems: true,
          }),
          requestedCommandIDs: Type.Array(
            Type.String({ pattern: "^[a-z0-9][a-z0-9-]{0,63}$" }),
            { maxItems: 64, uniqueItems: true },
          ),
        },
        { additionalProperties: false },
      );
    default:
      throw new Error("JIDOKA_EXTENSION_CONTRACT:unsupported-workflow");
  }
}

const ResultParameters = Type.Object(
  {
    schemaVersion: Type.Literal(1),
    workflow: Type.Literal(configuration.workflow),
    role: Type.Literal(configuration.role),
    nonce: Type.Literal(configuration.nonce),
    artifactSHA256: Type.Literal(configuration.artifactSHA256),
    approvedCommandIDs: Type.Array(
      Type.String({ pattern: "^[a-z0-9][a-z0-9-]{0,63}$" }),
      { maxItems: 64, uniqueItems: true },
    ),
    payload: payloadSchema(),
  },
  { additionalProperties: false },
);

const WorkspacePath = Type.String({ minLength: 1, maxLength: 1_024 });
const WorkspaceReadParameters = Type.Object(
  {
    path: WorkspacePath,
    offset: Type.Optional(Type.Integer({ minimum: 1, maximum: 1_000_000 })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 2_000 })),
  },
  { additionalProperties: false },
);
const WorkspaceWriteParameters = Type.Object(
  {
    path: WorkspacePath,
    content: Type.String({ maxLength: 524_288 }),
  },
  { additionalProperties: false },
);
const WorkspaceEditParameters = Type.Object(
  {
    path: WorkspacePath,
    oldText: Type.String({ minLength: 1, maxLength: 524_288 }),
    newText: Type.String({ maxLength: 524_288 }),
  },
  { additionalProperties: false },
);
const WorkspaceQueryParameters = Type.Object(
  {
    operation: StringEnum(
      jidokaExtensionContract.workspaceOperations as readonly [
        "status",
        "diff",
        "log",
        "show",
        "search",
        "list",
      ],
    ),
    path: Type.Optional(WorkspacePath),
    query: Type.Optional(Type.String({ minLength: 1, maxLength: 256 })),
    revision: Type.Optional(Type.String({ pattern: "^[0-9a-f]{40}$" })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 })),
  },
  { additionalProperties: false },
);

function preflightDetails(pi: ExtensionAPI) {
  const activeTools = [...pi.getActiveTools()].sort();
  const expectedTools = expectedActiveTools(configuration);
  if (JSON.stringify(activeTools) !== JSON.stringify(expectedTools)) {
    throw new Error("JIDOKA_EXTENSION_CONTRACT:active-tool-drift");
  }
  return {
    activeTools,
    contractVersion: jidokaExtensionContract.contractVersion,
    genericBashActive: activeTools.includes("bash"),
    manifestSHA256: configuration.resourceManifestSHA256,
    role: configuration.role,
    schemaVersion: 1,
    toolPolicy: configuration.toolPolicy,
    workflow: configuration.workflow,
    workspaceOperations: [...jidokaExtensionContract.workspaceOperations],
  };
}

export default function jidokaCode(pi: ExtensionAPI) {
  let resultCount = 0;

  pi.registerTool({
    name: "jidoka_code_preflight",
    label: "Jidoka Code Preflight",
    description: "Return the exact packaged Jidoka Code tool and resource contract.",
    parameters: Type.Object({}, { additionalProperties: false }),
    async execute() {
      const details = preflightDetails(pi);
      if (details.genericBashActive) {
        throw new Error("JIDOKA_EXTENSION_CONTRACT:generic-bash-active");
      }
      return {
        content: [{ type: "text", text: "Jidoka Code runtime contract is active." }],
        details,
      };
    },
  });

  pi.registerTool({
    name: "jidoka_code_read",
    label: "Jidoka Code Read",
    description:
      "Read exact UTF-8 lines from one non-symlink file inside the managed workspace.",
    parameters: WorkspaceReadParameters,
    async execute(_toolCallId, parameters) {
      const result = readWorkspaceFile(configuration, parameters);
      return {
        content: [{ type: "text", text: result.content || "The selected file range is empty." }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "jidoka_code_write",
    label: "Jidoka Code Write",
    description: "Atomically write exact UTF-8 content to one approved workspace path.",
    parameters: WorkspaceWriteParameters,
    async execute(_toolCallId, parameters) {
      const result = writeWorkspaceFile(configuration, parameters);
      return {
        content: [{ type: "text", text: `Wrote ${result.relativePath}.` }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "jidoka_code_edit",
    label: "Jidoka Code Edit",
    description:
      "Atomically replace one unique exact UTF-8 fragment in one approved workspace file.",
    parameters: WorkspaceEditParameters,
    async execute(_toolCallId, parameters) {
      const result = editWorkspaceFile(configuration, parameters);
      return {
        content: [{ type: "text", text: `Edited ${result.relativePath}.` }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "jidoka_code_workspace_query",
    label: "Jidoka Code Workspace Query",
    description:
      "Run one fixed credentialless read-only workspace query: status, diff, log, show, search, or list.",
    parameters: WorkspaceQueryParameters,
    async execute(_toolCallId, parameters, signal) {
      buildWorkspaceQuery(configuration, parameters);
      const result = await runWorkspaceQuery(configuration, parameters, signal);
      return {
        content: [{ type: "text", text: result.content || "No matching workspace output." }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "jidoka_code_result",
    label: "Jidoka Code Result",
    description:
      "Return the single schema-valid terminal result for this Jidoka Code workflow role.",
    promptSnippet: "Emit exactly one terminal Jidoka Code workflow result",
    promptGuidelines: [
      "Call jidoka_code_result exactly once as the final action for the active Jidoka Code role.",
      "jidoka_code_result may request only approved command IDs and never argv or remote actions.",
    ],
    parameters: ResultParameters,
    async execute(_toolCallId, parameters) {
      resultCount += 1;
      if (resultCount !== 1) {
        throw new Error("JIDOKA_EXTENSION_CONTRACT:multiple-terminal-results");
      }
      const result = validateTerminalResult(configuration, parameters);
      return {
        content: [{ type: "text", text: "Jidoka Code terminal result recorded." }],
        details: { ...result, resultSequence: resultCount },
        terminate: true,
      };
    },
  });

  pi.registerCommand("jidoka-code-preflight", {
    description: "Report the packaged Jidoka Code runtime contract without a model call",
    handler: async (_arguments, context) => {
      context.ui.notify(`JIDOKA_PREFLIGHT:${JSON.stringify(preflightDetails(pi))}`, "info");
    },
  });

  pi.on("session_start", () => {
    const expectedTools = expectedActiveTools(configuration);
    const available = new Set(pi.getAllTools().map((tool) => tool.name));
    if (!expectedTools.every((name) => available.has(name)) || available.has("gh")) {
      throw new Error("JIDOKA_EXTENSION_CONTRACT:tool-inventory-unavailable");
    }
    pi.setActiveTools(expectedTools);
  });

  pi.on("tool_call", (event) => {
    try {
      validateBuiltInToolCall(configuration, event);
    } catch {
      return { block: true, reason: "JIDOKA_TOOL_CALL_BLOCKED" };
    }
  });

  pi.on("user_bash", () => ({
    result: {
      output: "JIDOKA_USER_BASH_DENIED",
      exitCode: 126,
      cancelled: false,
      truncated: false,
    },
  }));
}
