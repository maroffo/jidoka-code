import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";

const MAX_RECORD_BYTES = 4 * 1_024 * 1_024;
const SHA256 = /^[0-9a-f]{64}$/;

function fail(message) {
  throw new Error(`herdr s12 fixture failed: ${message}`);
}

function absolute(value, name) {
  if (typeof value !== "string" || !path.isAbsolute(value) || value.includes("\0")
      || path.normalize(value) !== value) fail(`invalid ${name}`);
  return value;
}

function exactKeys(value, expected) {
  return value && typeof value === "object" && !Array.isArray(value)
    && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function canonical(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function privateDirectory(value, name) {
  const directory = absolute(value, name);
  const status = fs.lstatSync(directory);
  if (!status.isDirectory() || status.isSymbolicLink() || status.uid !== process.getuid()
      || (status.mode & 0o077) !== 0 || fs.realpathSync(directory) !== directory) {
    fail(`unsafe ${name}`);
  }
  return directory;
}

function regularFile(value, name) {
  const file = absolute(value, name);
  const status = fs.lstatSync(file);
  if (!status.isFile() || status.isSymbolicLink() || fs.realpathSync(file) !== file) {
    fail(`unsafe ${name}`);
  }
  return file;
}

function privateFile(value, name) {
  const file = absolute(value, name);
  const status = fs.lstatSync(file);
  if (!status.isFile() || status.isSymbolicLink() || status.nlink !== 1
      || status.uid !== process.getuid() || (status.mode & 0o077) !== 0) fail(`unsafe ${name}`);
  return file;
}

async function request(socketPath, method, params) {
  absolute(socketPath, "socket path");
  const id = `s12-${crypto.randomUUID()}`;
  const payload = `${JSON.stringify({ id, method, params })}\n`;
  const record = await new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let buffer = Buffer.alloc(0);
    const timer = setTimeout(() => { socket.destroy(); reject(new Error("timeout")); }, 5_000);
    socket.on("connect", () => socket.write(payload));
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > MAX_RECORD_BYTES) {
        clearTimeout(timer); socket.destroy(); reject(new Error("oversized response")); return;
      }
      const newline = buffer.indexOf(0x0a);
      if (newline >= 0) {
        clearTimeout(timer); socket.destroy(); resolve(buffer.subarray(0, newline).toString("utf8"));
      }
    });
    socket.on("error", (error) => { clearTimeout(timer); reject(error); });
  });
  const response = JSON.parse(record);
  if (response.id !== id || response.error || !response.result) fail(`remote ${method}`);
  return response.result;
}

function pane(host, runRoot, cwd, runID) {
  return {
    command: [absolute(host, "host"), "--launch-attempt-id", runID],
    cwd: privateDirectory(cwd, "pane cwd"),
    env: { JIDOKA_CODE_HERDR_RUN_ROOT: privateDirectory(runRoot, "run root") },
    label: "triage",
    type: "pane",
  };
}

function loadTUIConfiguration(value) {
  const file = privateFile(value, "TUI configuration");
  const configuration = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!exactKeys(configuration, [
    "acknowledgementTimeoutMilliseconds", "channelDirectory", "expectedCommands",
    "expectedSessionID", "launchMode", "modelID", "modelProvider", "promptPath",
    "promptSHA256", "resumeBoundarySHA256", "role", "runID", "runNonce", "schemaVersion",
    "sessionDirectory", "sessionName", "thinkingLevel", "workflow", "workspaceRoot",
  ]) || configuration.schemaVersion !== 3 || !SHA256.test(configuration.runNonce)
      || configuration.workflow !== "issue-triage" || configuration.role !== "triage") {
    fail("TUI configuration");
  }
  privateDirectory(configuration.channelDirectory, "TUI channel");
  return configuration;
}

function loadResult(configuration) {
  const file = privateFile(path.join(configuration.channelDirectory, "result.json"), "result");
  const bytes = fs.readFileSync(file);
  const result = JSON.parse(bytes);
  if (!exactKeys(result, [
    "approvedCommandIDs", "artifactSHA256", "nonce", "payload", "role", "runID", "runNonce",
    "schemaVersion", "sessionBoundarySHA256", "workflow",
  ]) || result.schemaVersion !== 1 || result.runID !== configuration.runID
      || result.runNonce !== configuration.runNonce
      || !SHA256.test(result.sessionBoundarySHA256)) fail("result identity");
  return { bytes, result, resultSHA256: crypto.createHash("sha256").update(bytes).digest("hex") };
}

function assertObserver(fileValue) {
  const records = fs.readFileSync(privateFile(fileValue, "observer"), "utf8").split("\n").filter(Boolean);
  if (!records.some((record) => {
    const value = JSON.parse(record);
    return typeof value.bytes === "string" && Buffer.from(value.bytes, "base64").length > 0;
  })) fail("observer frames");
}

function assertScreen(fileValue) {
  const value = fs.readFileSync(privateFile(fileValue, "screen"), "utf8");
  for (const required of [
    "pi v0.84.1", "jidoka-tui-runtime.ts", "fixture", "interactive input is locked",
  ]) {
    if (!value.includes(required)) fail(`screen missing ${required}`);
  }
}

function assertResumeScreen(fileValue) {
  const value = fs.readFileSync(privateFile(fileValue, "resume screen"), "utf8");
  for (const required of ["pi v0.84.1", "fixture"]) {
    if (!value.includes(required)) fail(`resume screen missing ${required}`);
  }
}

function assertRecordedResult(configurationPath, manualSentinel) {
  const configuration = loadTUIConfiguration(configurationPath);
  const identity = JSON.parse(fs.readFileSync(
    privateFile(path.join(configuration.channelDirectory, "session.json"), "session identity"),
    "utf8",
  ));
  const sessionFile = privateFile(identity.sessionFile, "Pi session");
  const prompt = fs.readFileSync(privateFile(configuration.promptPath, "prompt"), "utf8");
  const records = fs.readFileSync(sessionFile, "utf8").split("\n").filter(Boolean).map(JSON.parse);
  const messages = records.filter((record) => record.type === "message").map((record) => record.message);
  const users = messages.filter((message) => message?.role === "user");
  const userText = (message) => Array.isArray(message.content)
    ? message.content.filter((part) => part?.type === "text").map((part) => part.text).join("")
    : message.content;
  const calls = messages.filter((message) => message?.role === "assistant")
    .flatMap((message) => Array.isArray(message.content) ? message.content : [])
    .filter((part) => part?.type === "toolCall");
  const preflightCalls = calls.filter((part) => part.name === "jidoka_code_preflight");
  const resultCalls = calls.filter((part) => part.name === "jidoka_code_result");
  const preflightResults = messages.filter((message) => message?.role === "toolResult"
    && message.toolName === "jidoka_code_preflight" && message.isError === false);
  const resultMessages = messages.filter((message) => message?.role === "toolResult"
    && message.toolName === "jidoka_code_result" && message.isError === false
    && message.details?.resultSequence === 1);
  if (users.length !== 1 || userText(users[0]) !== prompt || preflightCalls.length !== 1
      || preflightResults.length !== 1 || resultCalls.length !== 1 || resultMessages.length !== 1
      || fs.existsSync(path.join(configuration.channelDirectory, "result.json"))
      || fs.readFileSync(sessionFile, "utf8").includes(manualSentinel)) {
    fail("recorded terminal result");
  }
  return {
    preflightCalls: 1,
    resultCalls: 1,
    sessionFile,
    sessionID: identity.sessionID,
    toolResults: 2,
    userPrompts: 1,
  };
}

function assertSession(configurationPath, manualSentinel) {
  const configuration = loadTUIConfiguration(configurationPath);
  const identity = JSON.parse(fs.readFileSync(
    privateFile(path.join(configuration.channelDirectory, "session.json"), "session identity"),
    "utf8",
  ));
  if (identity.schemaVersion !== 2 || identity.originLaunchMode !== "fresh"
      || identity.originResumeBoundarySHA256 !== null
      || identity.runID !== configuration.runID || identity.runNonce !== configuration.runNonce
      || identity.sessionID.length < 1) fail("session identity");
  const sessionFile = privateFile(identity.sessionFile, "Pi session");
  if (path.dirname(sessionFile) !== configuration.sessionDirectory) fail("session directory");
  const prompt = fs.readFileSync(privateFile(configuration.promptPath, "prompt"), "utf8");
  const records = fs.readFileSync(sessionFile, "utf8").split("\n").filter(Boolean).map(JSON.parse);
  const messages = records.filter((record) => record.type === "message").map((record) => record.message);
  const users = messages.filter((message) => message?.role === "user");
  const userText = (message) => Array.isArray(message.content)
    ? message.content.filter((part) => part?.type === "text").map((part) => part.text).join("")
    : message.content;
  if (users.length !== 1 || userText(users[0]) !== prompt) fail("prompt count");
  const assistants = messages.filter((message) => message?.role === "assistant");
  const resultCalls = assistants.flatMap((message) => Array.isArray(message.content) ? message.content : [])
    .filter((part) => part?.type === "toolCall" && part.name === "jidoka_code_result");
  const toolResults = messages.filter((message) => message?.role === "toolResult"
    && message.toolName === "jidoka_code_result" && message.isError === false);
  const prepared = loadResult(configuration).result;
  const argumentsValue = resultCalls[0]?.arguments;
  const sameTerminalResult = argumentsValue
    && ["workflow", "role", "nonce", "artifactSHA256"].every(
      (key) => argumentsValue[key] === prepared[key],
    )
    && canonical(argumentsValue.approvedCommandIDs) === canonical(prepared.approvedCommandIDs)
    && canonical(argumentsValue.payload) === canonical(prepared.payload);
  if (resultCalls.length !== 1 || toolResults.length > 1 || !sameTerminalResult
      || fs.readFileSync(sessionFile, "utf8").includes(manualSentinel)) fail("terminal transcript");
  return {
    resultCalls: 1,
    sessionFile,
    sessionID: identity.sessionID,
    toolResults: toolResults.length,
    userPrompts: 1,
  };
}

async function main() {
  const [command, ...values] = process.argv.slice(2);
  switch (command) {
  case "ping": return request(values[0], "ping", {});
  case "snapshot": return request(values[0], "session.snapshot", {});
  case "create-workspace":
    return request(values[0], "workspace.create", {
      cwd: privateDirectory(values[2], "workspace cwd"), env: {}, focus: false, label: values[1],
    });
  case "apply-layout":
    if (values.length !== 7) fail("apply-layout arguments");
    return request(values[0], "layout.apply", {
      focus: false,
      root: pane(values[3], values[4], values[5], values[6]),
      tab_label: values[2],
      workspace_id: values[1],
    });
  case "assert-observer": assertObserver(values[0]); return { valid: true };
  case "assert-screen": assertScreen(values[0]); return { valid: true };
  case "assert-resume-screen": assertResumeScreen(values[0]); return { valid: true };
  case "assert-recorded-result": return assertRecordedResult(values[0], values[1]);
  case "assert-session": return assertSession(values[0], values[1]);
  default: fail("closed command required");
  }
}

try {
  const result = await main();
  process.stdout.write(`${JSON.stringify(result ?? { ok: true })}\n`);
} catch (error) {
  fail(error instanceof Error ? error.message : "unknown");
}
