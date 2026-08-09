import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import { appendFileSync, readFileSync } from "node:fs";

const configuration = JSON.parse(readFileSync(process.env.JIDOKA_CODE_CONFIG!, "utf8"));
const fixtureMode = process.env.JIDOKA_TUI_FIXTURE_MODE ?? "multi-turn";
const providerCallPath = process.env.JIDOKA_TUI_FIXTURE_PROVIDER_CALL!;
let requestSequence = 0;

const result = {
  schemaVersion: 1,
  workflow: configuration.workflow,
  role: configuration.role,
  nonce: configuration.nonce,
  artifactSHA256: configuration.artifactSHA256,
  approvedCommandIDs: [],
  payload: {
    verdict: "human",
    severity: "major",
    summary: "Synthetic H3 TUI settlement result.",
    rubric: { specified: "yes", testable: "yes", bounded: "yes", safe: "human" },
    hardRiskFlags: ["security-or-secret-core"],
    rationale: "Local deterministic fixture provider, no provider network request.",
    questions: [],
    complexityGuess: "humanOwned",
  },
};

function recordProviderCall(model: any) {
  requestSequence += 1;
  appendFileSync(
    providerCallPath,
    `${JSON.stringify({
      modelID: model.id,
      provider: model.provider,
      requestSequence,
      schemaVersion: 1,
    })}\n`,
    { mode: 0o600 },
  );
}

function streamFixture(model: any) {
  recordProviderCall(model);
  const stream = createAssistantMessageEventStream();
  setTimeout(() => {
    const output: any = {
      role: "assistant",
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: {
        input: 1,
        output: 1,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 2,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "pending",
      timestamp: Date.now(),
    };
    stream.push({ type: "start", partial: output });
    const toolCall = requestSequence === 1
      ? {
          type: "toolCall",
          id: "jidoka-h3-preflight-call",
          name: "jidoka_code_preflight",
          arguments: {},
        }
      : {
          type: "toolCall",
          id: "jidoka-h3-result-call",
          name: "jidoka_code_result",
          arguments: result,
        };
    output.content.push(toolCall);
    stream.push({ type: "toolcall_start", contentIndex: 0, partial: output });
    stream.push({ type: "toolcall_end", contentIndex: 0, toolCall, partial: output });
    output.stopReason = "toolUse";
    stream.push({ type: "done", reason: "toolUse", message: output });
    stream.end();
  }, 4_000);
  return stream;
}

export default function jidokaTUIFixtureProvider(pi: ExtensionAPI) {
  if (fixtureMode === "command-provenance-mismatch") {
    pi.registerCommand("fixture-command-drift", {
      description: "Intentional S12 command provenance mismatch",
      handler: async () => {},
    });
  }
  pi.registerProvider("jidoka-fixture", {
    baseUrl: "http://127.0.0.1:43871",
    apiKey: "fixture",
    api: "jidoka-fixture",
    models: [{
      id: "fixture",
      name: "Jidoka H3 Fixture",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4_096,
      maxTokens: 1_024,
    }],
    streamSimple: streamFixture,
    stream: streamFixture,
  });
}
