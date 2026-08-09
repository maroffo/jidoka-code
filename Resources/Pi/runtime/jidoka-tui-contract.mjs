import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  constants,
  existsSync,
  fsyncSync,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import { performance } from "node:perf_hooks";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";

const ERROR_PREFIX = "JIDOKA_TUI_CONTRACT";
const FILES = Object.freeze({
  result: "result.json",
  resultPrepared: ".result.json.prepared",
  acknowledgement: "acknowledgement.json",
  release: "release.json",
  runtimeFailure: "runtime-failure.json",
  runtimeFailurePrepared: ".runtime-failure.json.prepared",
  session: "session.json",
  sessionPrepared: ".session.json.prepared",
});
const SHA256 = /^[0-9a-f]{64}$/;
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);
const MAXIMUM_FILE_BYTES = 4 * 1_024 * 1_024;

function fail(reason) {
  throw new Error(`${ERROR_PREFIX}:${reason}`);
}

function exactKeys(value, keys) {
  return value && typeof value === "object" && !Array.isArray(value)
    && Object.keys(value).sort().join("\0") === [...keys].sort().join("\0");
}

function safeAncestorChain(path, kind) {
  let current = path;
  for (;;) {
    let value;
    try {
      value = lstatSync(current);
    } catch {
      fail(`${kind}-ancestor-unavailable`);
    }
    const writable = (value.mode & 0o022) !== 0;
    const sticky = (value.mode & 0o1000) !== 0;
    if (!value.isDirectory() || value.isSymbolicLink()
        || ![0, process.getuid()].includes(value.uid) || (writable && !sticky)) {
      fail(`unsafe-${kind}-ancestor`);
    }
    if (current === "/") return;
    const parent = dirname(current);
    if (parent === current) fail(`unsafe-${kind}-ancestor`);
    current = parent;
  }
}

function privateStat(path, kind) {
  let value;
  try {
    value = lstatSync(path);
  } catch {
    fail(`${kind}-unavailable`);
  }
  if (value.isSymbolicLink() || value.uid !== process.getuid() || (value.mode & 0o077) !== 0) {
    fail(`unsafe-${kind}`);
  }
  if (["channel-directory", "session-directory", "workspace-root"].includes(kind)
      && !value.isDirectory()) {
    fail(`unsafe-${kind}`);
  }
  if (kind.endsWith("file") && (!value.isFile() || value.nlink !== 1)) {
    fail(`unsafe-${kind}`);
  }
  return value;
}

function canonicalPath(path, kind, mustExist = true) {
  if (typeof path !== "string" || !isAbsolute(path) || resolve(path) !== path) {
    fail(`invalid-${kind}`);
  }
  if (mustExist) {
    privateStat(path, kind);
    safeAncestorChain(dirname(path), kind);
    if (realpathSync(path) !== path) fail(`noncanonical-${kind}`);
  }
  return path;
}

function childPath(path, parent, kind, mustExist = true) {
  canonicalPath(path, kind, mustExist);
  const suffix = relative(parent, path);
  if (!suffix || suffix.startsWith("..") || isAbsolute(suffix)) fail(`${kind}-outside-parent`);
  if (!mustExist) {
    canonicalPath(dirname(path), "session-directory");
    if (existsSync(path)) canonicalPath(path, kind);
  }
  return path;
}

function readBoundedPrivateFile(path, kind) {
  canonicalPath(path, kind);
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const before = fstatSync(descriptor);
    if (!before.isFile() || before.uid !== process.getuid() || (before.mode & 0o077) !== 0
        || before.nlink !== 1 || before.size < 1 || before.size > MAXIMUM_FILE_BYTES) {
      fail(`${kind}-size`);
    }
    const bytes = readFileSync(descriptor);
    const after = fstatSync(descriptor);
    if (before.dev !== after.dev || before.ino !== after.ino || before.mode !== after.mode
        || before.nlink !== after.nlink || before.size !== after.size || bytes.length !== before.size) {
      fail(`${kind}-changed`);
    }
    return bytes;
  } finally {
    closeSync(descriptor);
  }
}

function parseStrictJSON(bytes, kind) {
  if (bytes.at(-1) !== 0x0a) fail(`${kind}-newline`);
  let value;
  try {
    value = JSON.parse(bytes.subarray(0, bytes.length - 1).toString("utf8"));
  } catch {
    fail(`${kind}-json`);
  }
  return value;
}

function stringField(value, key, maximum = 1_024) {
  if (typeof value[key] !== "string" || value[key].length < 1 || value[key].length > maximum) {
    fail(`invalid-${key}`);
  }
  return value[key];
}

export function canonicalJSON(value) {
  if (value === null) return "null";
  if (typeof value === "boolean" || typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) fail("nonfinite-json-number");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  fail("unsupported-json-value");
}

export function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function executedTerminalHistory(messages) {
  if (!Array.isArray(messages)) fail("invalid-terminal-transcript");
  const intents = new Map();
  const consumedIntents = new Set();
  const successfulResults = [];
  for (const [messageIndex, message] of messages.entries()) {
    if (message?.role === "assistant") {
      const calls = Array.isArray(message.content)
        ? message.content.filter((part) => part?.type === "toolCall")
        : [];
      const results = calls.filter((call) => call.name === "jidoka_code_result");
      if (results.length > 0) {
        const result = results[0];
        if (calls.length !== 1 || results.length !== 1 || typeof result.id !== "string"
            || intents.has(result.id) || !result.arguments || typeof result.arguments !== "object") {
          fail("nonexclusive-terminal-result");
        }
        intents.set(result.id, result.arguments);
      }
    }
    if (message?.role === "toolResult" && message.toolName === "jidoka_code_result") {
      if (message.isError !== false || typeof message.toolCallId !== "string"
          || !message.details || message.details.resultSequence !== 1
          || consumedIntents.has(message.toolCallId)) {
        fail("invalid-recorded-terminal-result");
      }
      const intent = intents.get(message.toolCallId);
      if (!intent || canonicalJSON({ ...intent, resultSequence: 1 }) !== canonicalJSON(message.details)) {
        fail("unpaired-recorded-terminal-result");
      }
      consumedIntents.add(message.toolCallId);
      successfulResults.push({ details: message.details, messageIndex });
    }
  }
  if ([...intents.keys()].some((identifier) => !consumedIntents.has(identifier))) {
    fail("terminal-result-execution-unknown");
  }
  return successfulResults;
}

export function recoverExecutedTerminalDetails(messages) {
  const successfulResults = executedTerminalHistory(messages);
  if (successfulResults.length > 1) fail("multiple-recorded-terminal-results");
  return successfulResults.length === 1 ? successfulResults[0].details : null;
}

export function currentRunMessages(configuration, messages) {
  const successfulResults = executedTerminalHistory(messages);
  if (configuration.launchMode === "fresh") {
    if (successfulResults.length > 0) fail("fresh-session-terminal-history");
    return messages;
  }
  if (configuration.launchMode !== "resume") fail("launch-mode");
  if (configuration.resumeBoundarySHA256 === null) {
    if (successfulResults.length > 1) fail("resume-boundary-required");
    return messages;
  }
  const boundaries = successfulResults.filter(({ details }) =>
    sha256(Buffer.from(canonicalJSON(details), "utf8")) === configuration.resumeBoundarySHA256);
  if (boundaries.length !== 1) fail("resume-boundary-mismatch");
  const boundary = boundaries[0];
  const currentMessages = messages.slice(boundary.messageIndex + 1);
  if (executedTerminalHistory(currentMessages).length > 1) {
    fail("multiple-current-run-terminal-results");
  }
  return currentMessages;
}

function expectedBytes(value) {
  return Buffer.from(`${canonicalJSON(value)}\n`, "utf8");
}

function sameBytes(path, bytes, kind) {
  return readBoundedPrivateFile(path, kind).equals(bytes);
}

function fsyncDirectory(path) {
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try {
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}

export function createPrivateJSONFile(directory, finalName, preparedName, value) {
  canonicalPath(directory, "channel-directory");
  const finalPath = join(directory, finalName);
  const preparedPath = join(directory, preparedName);
  const stagingPath = join(directory, `.${preparedName}.${randomUUID()}.staging`);
  const bytes = expectedBytes(value);

  if (existsSync(finalPath)) {
    if (!sameBytes(finalPath, bytes, "channel-file")) fail(`${finalName}-divergent`);
    if (existsSync(preparedPath)) {
      if (!sameBytes(preparedPath, bytes, "channel-file")) fail(`${finalName}-ambiguous`);
      unlinkSync(preparedPath);
      fsyncDirectory(directory);
    }
    return finalPath;
  }

  if (!existsSync(preparedPath)) {
    let descriptor;
    try {
      descriptor = openSync(
        stagingPath,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
        0o600,
      );
      let offset = 0;
      while (offset < bytes.length) {
        const count = writeSync(descriptor, bytes, offset);
        if (count <= 0) fail(`${finalName}-staging-write`);
        offset += count;
      }
      fsyncSync(descriptor);
      closeSync(descriptor);
      descriptor = undefined;
      if (existsSync(preparedPath)) {
        if (!sameBytes(preparedPath, bytes, "channel-file")) {
          fail(`${finalName}-prepared-divergent`);
        }
      } else {
        renameSync(stagingPath, preparedPath);
      }
      fsyncDirectory(directory);
    } finally {
      if (descriptor !== undefined) closeSync(descriptor);
      if (existsSync(stagingPath)) unlinkSync(stagingPath);
    }
  }
  if (!sameBytes(preparedPath, bytes, "channel-file")) fail(`${finalName}-prepared-divergent`);
  if (existsSync(finalPath)) {
    if (!sameBytes(finalPath, bytes, "channel-file")) fail(`${finalName}-divergent`);
    unlinkSync(preparedPath);
  } else {
    // The channel is private to this UID. Same-UID process injection is outside the threat model.
    renameSync(preparedPath, finalPath);
  }
  fsyncDirectory(directory);
  return finalPath;
}

export function loadTUIRuntimeConfiguration(path = process.env.JIDOKA_CODE_TUI_CONFIG) {
  if (!path) fail("configuration-required");
  canonicalPath(path, "configuration-file");
  const value = parseStrictJSON(readBoundedPrivateFile(path, "configuration-file"), "configuration");
  const keys = [
    "acknowledgementTimeoutMilliseconds", "channelDirectory", "expectedCommands",
    "expectedSessionID", "launchMode", "modelID", "modelProvider", "promptPath",
    "promptSHA256", "resumeBoundarySHA256", "role", "runID", "runNonce", "schemaVersion", "sessionDirectory",
    "sessionName", "thinkingLevel", "workflow", "workspaceRoot",
  ];
  if (!exactKeys(value, keys) || value.schemaVersion !== 3) fail("configuration-schema");
  if (!IDENTIFIER.test(stringField(value, "runID", 128)) || !SHA256.test(value.runNonce)) fail("run-identity");
  if (!IDENTIFIER.test(stringField(value, "workflow", 64))
      || !IDENTIFIER.test(stringField(value, "role", 32))) fail("workflow-role");
  canonicalPath(value.channelDirectory, "channel-directory");
  canonicalPath(value.sessionDirectory, "session-directory");
  canonicalPath(value.workspaceRoot, "workspace-root");
  const roots = [value.channelDirectory, value.sessionDirectory, value.workspaceRoot];
  if (new Set(roots).size !== roots.length || roots.some((left, index) => roots.some(
    (right, other) => index !== other && relative(left, right) !== ""
      && !relative(left, right).startsWith("..") && !isAbsolute(relative(left, right)),
  ))) fail("overlapping-capability-roots");
  childPath(value.promptPath, value.channelDirectory, "prompt-file");
  if (!SHA256.test(value.promptSHA256)) fail("prompt-digest");
  if (!IDENTIFIER.test(stringField(value, "sessionName", 128))) fail("session-name");
  if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(value.modelProvider)
      || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value.modelID)) fail("model");
  if (!THINKING_LEVELS.has(value.thinkingLevel)) fail("thinking-level");
  if (!Array.isArray(value.expectedCommands) || value.expectedCommands.length < 1
      || value.expectedCommands.length > 8) fail("expected-commands");
  const commandNames = new Set();
  for (const command of value.expectedCommands) {
    if (!exactKeys(command, ["name", "origin", "path", "scope", "source"])
        || !/^[A-Za-z0-9][A-Za-z0-9:_-]{0,127}$/.test(command.name)
        || !["extension", "skill"].includes(command.source)
        || typeof command.path !== "string" || command.path.length < 1 || command.path.length > 4096
        || command.scope !== "temporary" || command.origin !== "top-level"
        || commandNames.has(command.name)) fail("expected-commands");
    commandNames.add(command.name);
  }
  if (!Number.isInteger(value.acknowledgementTimeoutMilliseconds)
      || value.acknowledgementTimeoutMilliseconds < 1_000
      || value.acknowledgementTimeoutMilliseconds > 600_000) fail("acknowledgement-timeout");
  if (value.launchMode === "fresh") {
    if (value.expectedSessionID !== null || value.resumeBoundarySHA256 !== null) {
      fail("fresh-session-id");
    }
  } else if (value.launchMode === "resume") {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      .test(value.expectedSessionID ?? "")
        || (value.resumeBoundarySHA256 !== null
          && !SHA256.test(value.resumeBoundarySHA256 ?? ""))) fail("resume-session-id");
  } else {
    fail("launch-mode");
  }
  return Object.freeze(value);
}

export function readPinnedPrompt(configuration) {
  const bytes = readBoundedPrivateFile(configuration.promptPath, "prompt-file");
  if (sha256(bytes) !== configuration.promptSHA256) fail("prompt-digest-mismatch");
  const prompt = bytes.toString("utf8");
  if (Buffer.from(prompt, "utf8").length !== bytes.length || prompt.trim().length === 0) {
    fail("prompt-content");
  }
  return prompt;
}

export function pinnedPromptAction(configuration, prompt, userMessages) {
  if (!Array.isArray(userMessages)) fail("prompt-history-mismatch");
  if (userMessages.length === 0 && (configuration.launchMode === "fresh"
      || (configuration.launchMode === "resume" && configuration.resumeBoundarySHA256 !== null))) {
    return "send";
  }
  if (userMessages.length !== 1 || userMessages[0] !== prompt) fail("prompt-history-mismatch");
  fail("pre-result-recovery-required");
}

export function recordSessionIdentity(configuration, sessionID, sessionFile) {
  if (!IDENTIFIER.test(sessionID ?? "")) fail("session-id");
  if (configuration.launchMode === "resume" && sessionID !== configuration.expectedSessionID) {
    fail("resumed-session-mismatch");
  }
  childPath(sessionFile, configuration.sessionDirectory, "session-file", false);
  const identity = {
    runID: configuration.runID,
    runNonce: configuration.runNonce,
    schemaVersion: 2,
    sessionFile,
    sessionID,
  };
  const path = join(configuration.channelDirectory, FILES.session);
  if (configuration.launchMode === "resume" && configuration.resumeBoundarySHA256 === null) {
    if (!existsSync(path)) fail("same-run-session-proof-required");
    const observed = parseStrictJSON(
      readBoundedPrivateFile(path, "channel-file"),
      "session-identity",
    );
    if (!exactKeys(observed, [
      "originLaunchMode", "originResumeBoundarySHA256", "runID", "runNonce",
      "schemaVersion", "sessionFile", "sessionID",
    ]) || canonicalJSON({
      runID: observed.runID,
      runNonce: observed.runNonce,
      schemaVersion: observed.schemaVersion,
      sessionFile: observed.sessionFile,
      sessionID: observed.sessionID,
    }) !== canonicalJSON(identity)) {
      fail("same-run-session-proof-mismatch");
    }
    if (observed.originLaunchMode !== "fresh"
        || observed.originResumeBoundarySHA256 !== null) {
      fail("same-run-session-proof-origin");
    }
    return observed;
  }
  const value = {
    originLaunchMode: configuration.launchMode,
    originResumeBoundarySHA256: configuration.resumeBoundarySHA256,
    ...identity,
  };
  createPrivateJSONFile(configuration.channelDirectory, FILES.session, FILES.sessionPrepared, value);
  return value;
}

function resultEnvelope(configuration, details) {
  const keys = [
    "approvedCommandIDs", "artifactSHA256", "nonce", "payload", "resultSequence", "role",
    "schemaVersion", "workflow",
  ];
  if (!exactKeys(details, keys) || details.schemaVersion !== 1 || details.resultSequence !== 1) {
    fail("terminal-result-schema");
  }
  return {
    approvedCommandIDs: details.approvedCommandIDs,
    artifactSHA256: details.artifactSHA256,
    nonce: details.nonce,
    payload: details.payload,
    role: details.role,
    runID: configuration.runID,
    sessionBoundarySHA256: sha256(Buffer.from(canonicalJSON(details), "utf8")),
    runNonce: configuration.runNonce,
    schemaVersion: 1,
    workflow: details.workflow,
  };
}

export function persistTerminalResult(configuration, details) {
  const envelope = resultEnvelope(configuration, details);
  const path = createPrivateJSONFile(
    configuration.channelDirectory,
    FILES.result,
    FILES.resultPrepared,
    envelope,
  );
  return { envelope, path, resultSHA256: sha256(readBoundedPrivateFile(path, "channel-file")) };
}

export function persistRuntimeFailure(configuration, code) {
  if (typeof code !== "string" || !/^[A-Z][A-Z0-9_]{2,63}$/.test(code)) {
    fail("runtime-failure-code");
  }
  return createPrivateJSONFile(
    configuration.channelDirectory,
    FILES.runtimeFailure,
    FILES.runtimeFailurePrepared,
    {
      code,
      runID: configuration.runID,
      runNonce: configuration.runNonce,
      schemaVersion: 1,
      status: "failed",
    },
  );
}

export function readPreparedTerminalResult(configuration) {
  const path = join(configuration.channelDirectory, FILES.result);
  if (!existsSync(path)) return null;
  const bytes = readBoundedPrivateFile(path, "channel-file");
  const envelope = parseStrictJSON(bytes, "terminal-result");
  if (!exactKeys(envelope, [
    "approvedCommandIDs", "artifactSHA256", "nonce", "payload", "role", "runID", "runNonce",
    "schemaVersion", "sessionBoundarySHA256", "workflow",
  ]) || envelope.schemaVersion !== 1 || envelope.runID !== configuration.runID
      || envelope.runNonce !== configuration.runNonce || envelope.workflow !== configuration.workflow
      || envelope.role !== configuration.role || !SHA256.test(envelope.sessionBoundarySHA256)) {
    fail("terminal-result-identity");
  }
  return { envelope, path, resultSHA256: sha256(bytes) };
}

function readSignal(configuration, name, status, resultSHA256) {
  const path = join(configuration.channelDirectory, name);
  if (!existsSync(path)) return false;
  const value = parseStrictJSON(readBoundedPrivateFile(path, "channel-file"), status);
  if (!exactKeys(value, ["resultSHA256", "runID", "runNonce", "schemaVersion", "status"])
      || value.schemaVersion !== 1 || value.status !== status
      || value.runID !== configuration.runID || value.runNonce !== configuration.runNonce
      || value.resultSHA256 !== resultSHA256) fail(`${status}-identity`);
  return true;
}

export async function waitForResultAcknowledgement(configuration, resultSHA256, signal) {
  const deadline = performance.now() + configuration.acknowledgementTimeoutMilliseconds;
  while (performance.now() <= deadline) {
    if (readSignal(configuration, FILES.acknowledgement, "accepted", resultSHA256)) return;
    if (signal?.aborted) fail("acknowledgement-aborted");
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
  }
  fail("acknowledgement-timeout");
}

export const jidokaTUIContract = Object.freeze({
  errorPrefix: ERROR_PREFIX,
  files: FILES,
  maximumFileBytes: MAXIMUM_FILE_BYTES,
});
