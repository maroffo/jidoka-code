import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, type EditorComponent } from "@earendil-works/pi-tui";
import {
  expectedActiveTools,
  loadRuntimeConfiguration,
  validateTerminalResult,
} from "../runtime/jidoka-extension-contract.mjs";
import {
  canonicalJSON,
  currentRunMessages,
  loadTUIRuntimeConfiguration,
  persistRuntimeFailure,
  persistTerminalResult,
  pinnedPromptAction,
  readPinnedPrompt,
  readPreparedTerminalResult,
  recordSessionIdentity,
  recoverExecutedTerminalDetails,
  waitForResultAcknowledgement,
} from "../runtime/jidoka-tui-contract.mjs";

const runtimeConfiguration = loadRuntimeConfiguration();
const tuiConfiguration = loadTUIRuntimeConfiguration();

function fail(reason: string): never {
  throw new Error(`JIDOKA_TUI_RUNTIME:${reason}`);
}

function toolCalls(message: any): any[] {
  if (!message || message.role !== "assistant" || !Array.isArray(message.content)) return [];
  return message.content.filter((part: any) => part?.type === "toolCall");
}

function userText(message: any): string | null {
  if (!message || message.role !== "user") return null;
  if (typeof message.content === "string") return message.content;
  if (!Array.isArray(message.content)) return null;
  const parts = message.content.filter((part: any) => part?.type === "text");
  if (parts.length !== message.content.length) return null;
  return parts.map((part: any) => part.text).join("");
}

function normalizedDetails(parameters: any, resultSequence = 1) {
  const validated = validateTerminalResult(runtimeConfiguration, parameters);
  return { ...validated, resultSequence };
}

function branchMessages(context: ExtensionContext): any[] {
  return context.sessionManager.getBranch()
    .filter((entry: any) => entry.type === "message")
    .map((entry: any) => entry.message);
}

function currentMessages(context: ExtensionContext): any[] {
  return currentRunMessages(tuiConfiguration, branchMessages(context));
}

function terminalDetailsFromBranch(context: ExtensionContext): any | null {
  const recovered = recoverExecutedTerminalDetails(currentMessages(context));
  if (!recovered) return null;
  const { resultSequence, ...parameters } = recovered;
  return normalizedDetails(parameters, resultSequence);
}

function causalContinuationToolCallID(
  context: ExtensionContext,
  activeTools: Set<string>,
): string | null {
  const messages = currentMessages(context);
  const result = messages.at(-1);
  if (result?.role !== "toolResult" || typeof result.toolCallId !== "string"
      || !activeTools.has(result.toolName)) return null;
  for (let index = messages.length - 2; index >= 0; index -= 1) {
    const message = messages[index];
    if (message?.role !== "assistant") continue;
    const call = toolCalls(message).find((candidate) =>
      candidate.id === result.toolCallId && candidate.name === result.toolName);
    return call ? result.toolCallId : null;
  }
  return null;
}

class LockedObserverEditor implements EditorComponent {
  onSubmit?: (text: string) => void;
  onChange?: (text: string) => void;

  getText(): string { return ""; }
  setText(_text: string): void {}
  handleInput(_data: string): void {}
  invalidate(): void {}

  render(width: number): string[] {
    return [truncateToWidth(" Jidoka observer: interactive input is locked", width)];
  }
}

function commandProvenance(pi: ExtensionAPI) {
  return pi.getCommands().map((command) => ({
    name: command.name,
    origin: command.sourceInfo.origin,
    path: command.sourceInfo.path,
    scope: command.sourceInfo.scope,
    source: command.source,
  })).sort((left, right) => left.name.localeCompare(right.name));
}

function validateRuntimeContext(pi: ExtensionAPI, context: ExtensionContext) {
  if (context.mode !== "tui" || context.cwd !== tuiConfiguration.workspaceRoot
      || runtimeConfiguration.workspaceRoot !== tuiConfiguration.workspaceRoot
      || context.isProjectTrusted()) fail("context-mismatch");
  if (context.model?.provider !== tuiConfiguration.modelProvider
      || context.model?.id !== tuiConfiguration.modelID
      || context.thinkingLevel !== tuiConfiguration.thinkingLevel) fail("model-mismatch");
  if (context.sessionManager.getSessionDir() !== tuiConfiguration.sessionDirectory
      || context.sessionManager.getSessionName() !== tuiConfiguration.sessionName) {
    fail("session-directory-or-name-mismatch");
  }
  if (runtimeConfiguration.workflow !== tuiConfiguration.workflow
      || runtimeConfiguration.role !== tuiConfiguration.role) fail("workflow-role-mismatch");
  const expected = expectedActiveTools(runtimeConfiguration);
  const active = pi.getActiveTools();
  if (canonicalJSON(active) !== canonicalJSON(expected) || active.includes("gh")) {
    fail("active-tool-mismatch");
  }
  const observedCommands = commandProvenance(pi);
  const expectedCommands = [...tuiConfiguration.expectedCommands]
    .sort((left, right) => left.name.localeCompare(right.name));
  if (canonicalJSON(observedCommands) !== canonicalJSON(expectedCommands)) {
    fail("command-provenance-mismatch");
  }
}

async function settlePreparedResult(context: ExtensionContext): Promise<boolean> {
  const prepared = readPreparedTerminalResult(tuiConfiguration);
  if (!prepared) return false;
  const {
    runID: _runID,
    runNonce: _runNonce,
    sessionBoundarySHA256: _sessionBoundarySHA256,
    ...parameters
  } = prepared.envelope;
  normalizedDetails(parameters);
  await waitForResultAcknowledgement(tuiConfiguration, prepared.resultSHA256, context.signal);
  context.shutdown();
  return true;
}

function failAndShutdown(context: ExtensionContext, error: unknown): never {
  const message = error instanceof Error ? error.message : "JIDOKA_TUI_RUNTIME:unknown";
  const reason = message.match(/^[A-Z_]+:([a-z0-9-]{1,64})$/)?.[1] ?? "unknown";
  const code = reason.toUpperCase().replaceAll("-", "_");
  try {
    persistRuntimeFailure(tuiConfiguration, code);
  } catch {
    // A divergent failure record remains fail-closed; never replace it.
  }
  context.ui.notify(message, "error");
  context.abort();
  context.shutdown();
  throw error;
}

export default function jidokaTUIRuntime(pi: ExtensionAPI) {
  const fixtureMode = process.env.JIDOKA_TUI_FIXTURE_MODE;
  const crashAfterRecordedResult = fixtureMode === "crash-after-recorded-result";
  const consumedContinuations = new Set<string>();
  let terminalToolCallID: string | null = null;
  let invalidTerminalTurn = false;
  let agentStartCount = 0;
  let providerRequestCount = 0;

  pi.on("session_start", async (_event, context) => {
    context.ui.setEditorComponent(() => new LockedObserverEditor());
    try {
      validateRuntimeContext(pi, context);
      const sessionID = context.sessionManager.getSessionId();
      const sessionFile = context.sessionManager.getSessionFile();
      if (!sessionFile) fail("session-file-unavailable");
      recordSessionIdentity(tuiConfiguration, sessionID, sessionFile);

      if (await settlePreparedResult(context)) return;
      const recovered = terminalDetailsFromBranch(context);
      if (recovered) {
        const persisted = persistTerminalResult(tuiConfiguration, recovered);
        await waitForResultAcknowledgement(tuiConfiguration, persisted.resultSHA256, context.signal);
        context.shutdown();
        return;
      }

      const prompt = readPinnedPrompt(tuiConfiguration);
      const userMessages = currentMessages(context)
        .filter((message: any) => message?.role === "user")
        .map((message: any) => userText(message));
      if (pinnedPromptAction(tuiConfiguration, prompt, userMessages) === "send") {
        pi.sendUserMessage(prompt);
      }
    } catch (error) {
      failAndShutdown(context, error);
    }
  });

  pi.on("message_end", (event) => {
    const message = event.message as any;
    if (message?.role === "toolResult") {
      if (crashAfterRecordedResult && message.toolName === "jidoka_code_result"
          && message.toolCallId === terminalToolCallID && message.isError === false) {
        setImmediate(() => process.kill(process.pid, "SIGKILL"));
      }
      return;
    }
    if (message?.role !== "assistant") return;
    const calls = toolCalls(message);
    const results = calls.filter((call) => call.name === "jidoka_code_result");
    invalidTerminalTurn = results.length > 0 && (calls.length !== 1 || results.length !== 1);
    terminalToolCallID = results.length === 1 && !invalidTerminalTurn ? results[0].id : null;
  });

  pi.on("tool_call", (event) => {
    if (readPreparedTerminalResult(tuiConfiguration)) {
      return { block: true, reason: "JIDOKA_TUI_RESULT_ALREADY_PREPARED" };
    }
    if (invalidTerminalTurn) {
      return { block: true, reason: "JIDOKA_TUI_TERMINAL_TURN_NOT_EXCLUSIVE" };
    }
    if (event.toolName === "jidoka_code_result" && terminalToolCallID !== event.toolCallId) {
      return { block: true, reason: "JIDOKA_TUI_TERMINAL_RESULT_NOT_EXCLUSIVE" };
    }
  });

  pi.on("tool_result", async (event, context) => {
    if (event.toolName !== "jidoka_code_result") return;
    try {
      if (event.isError || !event.details || event.toolCallId !== terminalToolCallID) {
        fail("terminal-result-tool-failed");
      }
      if (crashAfterRecordedResult) return;
      const persisted = persistTerminalResult(tuiConfiguration, event.details);
      await waitForResultAcknowledgement(tuiConfiguration, persisted.resultSHA256, context.signal);
      context.shutdown();
    } catch (error) {
      failAndShutdown(context, error);
    }
  });

  pi.on("before_agent_start", (event, context) => {
    try {
      validateRuntimeContext(pi, context);
      agentStartCount += 1;
      if (agentStartCount !== 1) fail("agent-start-repeated");
      if (event.prompt !== readPinnedPrompt(tuiConfiguration)) fail("unpinned-provider-prompt");
    } catch (error) {
      failAndShutdown(context, error);
    }
  });

  pi.on("before_provider_request", (_event, context) => {
    try {
      validateRuntimeContext(pi, context);
      providerRequestCount += 1;
      if (providerRequestCount > 128) fail("provider-request-limit");
      const prompt = readPinnedPrompt(tuiConfiguration);
      const users = currentMessages(context)
        .filter((message) => message?.role === "user")
        .map(userText);
      if (users.length !== 1 || users[0] !== prompt) fail("provider-prompt-history");
      if (providerRequestCount > 1) {
        const continuation = causalContinuationToolCallID(
          context,
          new Set(pi.getActiveTools()),
        );
        if (!continuation || consumedContinuations.has(continuation)) {
          fail("provider-request-not-causal");
        }
        consumedContinuations.add(continuation);
      }
    } catch (error) {
      failAndShutdown(context, error);
    }
  });

  pi.on("agent_end", (_event, context) => {
    if (crashAfterRecordedResult) return;
    if (!readPreparedTerminalResult(tuiConfiguration)) {
      failAndShutdown(context, new Error("JIDOKA_TUI_RUNTIME:terminal-result-missing"));
    }
  });

  pi.on("input", (event) => {
    if (event.source === "interactive") return { action: "handled" };
  });

  pi.on("session_before_switch", () => ({ cancel: true }));
  pi.on("session_before_fork", () => ({ cancel: true }));
}
