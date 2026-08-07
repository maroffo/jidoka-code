#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmdirSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { homedir, tmpdir } from "node:os";
import { attestSystemRuntime } from "./pi-runtime-attestation.mjs";

const nodePath = "/opt/homebrew/Cellar/node/26.6.0/bin/node";
const piPath = "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js";
const modelPattern = "openai-codex/gpt-5.6-sol:max";
const modelProvider = "openai-codex";
const modelID = "gpt-5.6-sol";
const authorizedCallCap = 19;
const maximumBufferBytes = 8 * 1024 * 1024;
const piRuntimeAttestationRelativePath = "runtime/pi-runtime-attestation.mjs";
const expectedPiRuntimeAttestationSHA256 =
  "b11b3015c528ca7b18148ee45a29f02bb9920f92f73c1d13dae82b5d7f8082de";
const piRuntimePolicyRelativePath = "runtime/pi-runtime-builds.json";
const expectedPiRuntimePolicySHA256 =
  "c4e08dd03294cf3dcd0806f5331817dc836c3cf7d7cca5d0f7e970fe36362484";
const expectedFiles = Object.freeze({
  [piRuntimeAttestationRelativePath]: expectedPiRuntimeAttestationSHA256,
  [piRuntimePolicyRelativePath]: expectedPiRuntimePolicySHA256,
  "extensions/jidoka-deny-user-bash.js":
    "ba18988ad739c592920555515ee246e07d325f0e90df345a61de4e7f41a24995",
  "extensions/jidoka-runtime.ts":
    "b6bae1cb282d95b3c1a3e6e4f37c5b967aa5bd3885ec3050c5d7bddb72b4a19b",
  "skills/jidoka-code-issue-triage/SKILL.md":
    "04b3b248a86dffbde0a543ddf1276f7515454fa7311347f317ff980d5ad9c5f6",
  "skills/jidoka-code-orchestrate/SKILL.md":
    "7a7339c25f27134c443d389472c404a0e9ae161ddb826ee3b13921ee76522a22",
  "skills/jidoka-code-plan/SKILL.md":
    "71fc244807117d61d2f335d7120c19e1d08bb04eab095013a86a3eaeb9bdfad9",
  "skills/jidoka-code-pr-review/SKILL.md":
    "3ec091bfc47124074ccf01496078460be9b1b42c01d5636d10ac6288930e832d",
});
const profileContracts = Object.freeze({
  review: {
    skill: "jidoka-code-pr-review",
    fixtureId: "s4-review",
    verdict: "block",
    invariant: "head-sha-mismatch-blocks",
    facts:
      "The recorded REST head SHA is 1111111. The synthetic fetched pull-request head SHA is 2222222. The patch itself changes one README typo.",
  },
  triage: {
    skill: "jidoka-code-issue-triage",
    fixtureId: "s4-triage",
    verdict: "escalate",
    invariant: "hard-risk-human-owned",
    facts:
      "The synthetic issue asks for a credential-storage migration with unresolved security and data-loss risk. Existing domain labels must remain untouched.",
  },
  planning: {
    skill: "jidoka-code-plan",
    fixtureId: "s4-planning",
    verdict: "escalate",
    invariant: "unknown-disagreement-complex",
    facts:
      "The synthetic writer calls the change simple, while the security reviewer calls it complex. No evidence resolves the disagreement.",
  },
  orchestration: {
    skill: "jidoka-code-orchestrate",
    fixtureId: "s4-orchestration",
    verdict: "block",
    invariant: "failed-gate-never-lowered",
    facts:
      "The frozen verification command failed and an independent review still has one unresolved Major finding. No fix round remains.",
  },
});

function fail(message) {
  throw new Error(message);
}

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function sleep(milliseconds) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}

function createIsolatedAgentDirectory(requiresAuthentication) {
  const requestedWorkspace = process.env.JIDOKA_PI_WORKSPACE;
  if (
    typeof requestedWorkspace !== "string" ||
    !/^jidoka-code-pi-workspace-[0-9a-f-]{36}$/.test(basename(requestedWorkspace))
  ) {
    fail("app-owned Pi workspace is absent");
  }
  const workspaceStat = lstatSync(requestedWorkspace);
  const workspace = realpathSync(requestedWorkspace);
  const temporaryRoot = realpathSync(tmpdir());
  if (
    !workspaceStat.isDirectory() ||
    workspaceStat.isSymbolicLink() ||
    (workspaceStat.mode & 0o077) !== 0 ||
    (typeof process.getuid === "function" && workspaceStat.uid !== process.getuid()) ||
    !workspace.startsWith(`${temporaryRoot}/`)
  ) {
    fail("app-owned Pi workspace is unsafe");
  }

  const directory = mkdtempSync(`${workspace}/jidoka-pi-agent-`);
  chmodSync(directory, 0o700);
  try {
    let authentication = {};
    let authenticationProviders = [];
    if (requiresAuthentication) {
      const authSource = `${homedir()}/.pi/agent/auth.json`;
      const authStat = lstatSync(authSource);
      if (
        !authStat.isFile() ||
        authStat.isSymbolicLink() ||
        (authStat.mode & 0o077) !== 0 ||
        authStat.size > 1_048_576
      ) {
        fail("Pi authentication source is not a bounded private regular file");
      }
      const sourceAuthentication = JSON.parse(readFileSync(authSource, "utf8"));
      const codexAuthentication = sourceAuthentication?.[modelProvider];
      if (codexAuthentication === null || typeof codexAuthentication !== "object") {
        fail("authorized model authentication is absent");
      }
      authentication = { [modelProvider]: codexAuthentication };
      authenticationProviders = [modelProvider];
    }
    const authPath = `${directory}/auth.json`;
    writeFileSync(authPath, `${JSON.stringify(authentication)}\n`, { mode: 0o600 });
    chmodSync(authPath, 0o600);
    const settings = {
      compaction: { enabled: false },
      retry: {
        enabled: false,
        maxRetries: 0,
        provider: { maxRetries: 0, maxRetryDelayMs: 60_000 },
      },
      transport: "sse",
    };
    const settingsPath = `${directory}/settings.json`;
    writeFileSync(settingsPath, `${JSON.stringify(settings)}\n`, { mode: 0o600 });
    chmodSync(settingsPath, 0o600);
    return {
      authenticationProviders,
      directory,
      settingsSHA256: sha256(readFileSync(settingsPath)),
    };
  } catch (error) {
    rmSync(directory, { recursive: true, force: true });
    throw error;
  }
}

function attestResources(requestedRoot) {
  const rootStat = lstatSync(requestedRoot);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    fail("resource root must be a non-symbolic directory");
  }
  const root = realpathSync(requestedRoot);
  if (!root.endsWith("/Contents/Resources/Pi")) {
    fail("resource root is not inside the packaged application");
  }
  const files = {};
  for (const [relativePath, expectedSHA256] of Object.entries(expectedFiles)) {
    const requestedPath = `${root}/${relativePath}`;
    const stat = lstatSync(requestedPath);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      fail(`resource is not a regular file: ${relativePath}`);
    }
    const path = realpathSync(requestedPath);
    if (!path.startsWith(`${root}/`)) fail(`resource escapes package: ${relativePath}`);
    const digest = sha256(readFileSync(path));
    if (digest !== expectedSHA256) fail(`resource digest mismatch: ${relativePath}`);
    files[relativePath] = { path, sha256: digest };
  }
  return { root, files };
}

class ProviderLedger {
  constructor(requestedPath) {
    const absolutePath = resolve(requestedPath);
    if (basename(absolutePath) !== "provider-call-ledger.json") {
      fail("provider ledger has an unexpected filename");
    }
    const parent = dirname(absolutePath);
    const parentStat = lstatSync(parent);
    if (!parentStat.isDirectory() || parentStat.isSymbolicLink()) {
      fail("provider ledger parent must be a non-symbolic directory");
    }
    this.parent = realpathSync(parent);
    this.path = `${this.parent}/provider-call-ledger.json`;
    this.lockPath = `${this.path}.lock`;
    if (existsSync(this.path)) {
      const stat = lstatSync(this.path);
      if (!stat.isFile() || stat.isSymbolicLink()) fail("provider ledger is not a regular file");
    }
  }

  withLock(operation) {
    try {
      mkdirSync(this.lockPath, { mode: 0o700 });
    } catch (error) {
      if (error?.code === "EEXIST") fail("provider ledger is locked; refusing concurrent calls");
      throw error;
    }
    try {
      return operation();
    } finally {
      rmdirSync(this.lockPath);
    }
  }

  validate(ledger) {
    if (
      ledger === null ||
      typeof ledger !== "object" ||
      ledger.schemaVersion !== 1 ||
      ledger.authorizedCallCap !== authorizedCallCap ||
      ledger.model !== modelPattern ||
      ledger.retry !== false ||
      !Array.isArray(ledger.attempts) ||
      ledger.attempts.length > authorizedCallCap
    ) {
      fail("provider ledger contract is invalid");
    }
    const ids = new Set();
    const fixtureIds = new Set();
    for (const attempt of ledger.attempts) {
      if (
        attempt === null ||
        typeof attempt !== "object" ||
        typeof attempt.attemptId !== "string" ||
        typeof attempt.fixtureId !== "string" ||
        !["reserved", "issued", "settled", "failed"].includes(attempt.state) ||
        ids.has(attempt.attemptId) ||
        fixtureIds.has(attempt.fixtureId)
      ) {
        fail("provider ledger attempt is invalid");
      }
      ids.add(attempt.attemptId);
      fixtureIds.add(attempt.fixtureId);
    }
    return ledger;
  }

  read() {
    if (!existsSync(this.path)) {
      return {
        schemaVersion: 1,
        authorizedCallCap,
        model: modelPattern,
        retry: false,
        attempts: [],
      };
    }
    return this.validate(JSON.parse(readFileSync(this.path, "utf8")));
  }

  write(ledger) {
    this.validate(ledger);
    const temporary = `${this.parent}/.provider-call-ledger.${process.pid}.${randomUUID()}`;
    let descriptor;
    try {
      descriptor = openSync(temporary, "wx", 0o600);
      writeFileSync(descriptor, `${JSON.stringify(ledger)}\n`, "utf8");
      fsyncSync(descriptor);
      closeSync(descriptor);
      descriptor = undefined;
      renameSync(temporary, this.path);
      const directoryDescriptor = openSync(this.parent, "r");
      fsyncSync(directoryDescriptor);
      closeSync(directoryDescriptor);
    } finally {
      if (descriptor !== undefined) closeSync(descriptor);
      if (existsSync(temporary)) unlinkSync(temporary);
    }
  }

  reserve({ attemptId, fixtureId, profile, workflow }) {
    return this.withLock(() => {
      const ledger = this.read();
      if (ledger.attempts.some((attempt) => attempt.attemptId === attemptId)) {
        fail(`provider attempt replay refused: ${attemptId}`);
      }
      if (ledger.attempts.some((attempt) => attempt.fixtureId === fixtureId)) {
        fail(`provider fixture replay refused: ${fixtureId}`);
      }
      if (ledger.attempts.length >= ledger.authorizedCallCap) {
        fail("provider call cap exhausted");
      }
      ledger.attempts.push({
        attemptId,
        fixtureId,
        profile,
        workflow,
        model: modelPattern,
        state: "reserved",
        reservedAt: new Date().toISOString(),
      });
      this.write(ledger);
      return ledger.attempts.length;
    });
  }

  transition(attemptId, expectedState, state, details = {}) {
    return this.withLock(() => {
      const ledger = this.read();
      const attempt = ledger.attempts.find((candidate) => candidate.attemptId === attemptId);
      if (attempt === undefined || attempt.state !== expectedState) {
        fail(`invalid provider attempt transition: ${attemptId}`);
      }
      attempt.state = state;
      attempt.updatedAt = new Date().toISOString();
      Object.assign(attempt, details);
      this.write(ledger);
      return ledger.attempts.length;
    });
  }
}

class RPCClient {
  constructor(
    attestation,
    { selectedSkill = undefined, timeoutFixture = false, providerGate = undefined } = {},
  ) {
    this.attestation = attestation;
    const isolatedAgent = createIsolatedAgentDirectory(
      providerGate !== undefined,
    );
    this.agentDirectory = isolatedAgent.directory;
    this.authenticationProviders = isolatedAgent.authenticationProviders;
    this.settingsSHA256 = isolatedAgent.settingsSHA256;
    this.transport = "sse";
    this.environment = {
      HOME: homedir(),
      PATH: "/opt/homebrew/bin:/usr/bin:/bin",
      PI_CODING_AGENT_DIR: this.agentDirectory,
      PI_SKIP_VERSION_CHECK: "1",
      TMPDIR: tmpdir(),
    };
    if (providerGate === undefined) this.environment.PI_OFFLINE = "1";
    if (providerGate !== undefined) {
      this.environment.JIDOKA_PROVIDER_ATTEMPT_ID = providerGate.attemptId;
      this.environment.JIDOKA_PROVIDER_GATE = "1";
      this.environment.JIDOKA_PROVIDER_LEDGER = providerGate.ledgerPath;
    }
    const baseArguments = [
      piPath,
      "--mode",
      "rpc",
      "--no-session",
      "--no-approve",
      "--no-context-files",
      "--no-themes",
      "--no-prompt-templates",
      "--model",
      modelPattern,
    ];
    if (timeoutFixture) {
      this.argv = [
        ...baseArguments,
        "--no-extensions",
        "--no-skills",
        "--no-tools",
      ];
    } else {
      const blocker = attestation.files["extensions/jidoka-deny-user-bash.js"].path;
      const runtime = attestation.files["extensions/jidoka-runtime.ts"].path;
      const skillRelativePaths = Object.keys(expectedFiles)
        .filter((path) => path.startsWith("skills/"))
        .sort()
        .filter(
          (path) => selectedSkill === undefined || path.split("/")[1] === selectedSkill,
        );
      this.argv = [
        ...baseArguments,
        "--no-extensions",
        "--extension",
        blocker,
        "--extension",
        runtime,
        "--no-skills",
        ...skillRelativePaths.flatMap((path) => ["--skill", attestation.files[path].path]),
        "--no-tools",
      ];
    }
    this.child = spawn(nodePath, this.argv, {
      cwd: "/",
      detached: true,
      env: this.environment,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.processGroupID = this.child.pid;
    this.nextID = 1;
    this.pending = new Map();
    this.stdoutBuffer = "";
    this.stderrBuffer = "";
    this.closed = false;
    this.fatalError = undefined;
    this.stopPromise = undefined;
    this.events = {
      agentEndCount: 0,
      agentEndWillRetry: [],
      agentSettled: 0,
      assistantMessages: [],
      autoRetry: 0,
      compaction: 0,
      extensionErrors: 0,
      resultStarts: 0,
      resultEnds: 0,
      resultDetails: undefined,
      resultIsError: undefined,
      summarizationRetry: 0,
    };

    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk) => this.consumeStdout(chunk));
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk) => {
      this.stderrBuffer += chunk;
      if (Buffer.byteLength(this.stderrBuffer) > maximumBufferBytes) {
        this.setFatal(new Error("Pi stderr exceeded the bound"));
      }
    });
    this.child.on("error", (error) => this.setFatal(error));
    this.child.on("close", () => {
      this.closed = true;
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error("Pi exited before the RPC response"));
      }
      this.pending.clear();
    });
  }

  setFatal(error) {
    if (this.fatalError === undefined) this.fatalError = error;
  }

  consumeStdout(chunk) {
    this.stdoutBuffer += chunk;
    if (Buffer.byteLength(this.stdoutBuffer) > maximumBufferBytes) {
      this.setFatal(new Error("Pi stdout exceeded the bound"));
      return;
    }
    let newline;
    while ((newline = this.stdoutBuffer.indexOf("\n")) >= 0) {
      let line = this.stdoutBuffer.slice(0, newline);
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      if (line.length === 0) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.setFatal(new Error("Pi emitted non-JSONL output"));
        continue;
      }
      this.consumeMessage(message);
    }
  }

  consumeMessage(message) {
    if (message.type === "response" && message.id !== undefined) {
      const pending = this.pending.get(message.id);
      if (pending !== undefined) {
        this.pending.delete(message.id);
        clearTimeout(pending.timer);
        pending.resolve(message);
      }
      return;
    }
    switch (message.type) {
      case "agent_end": {
        this.events.agentEndCount += 1;
        this.events.agentEndWillRetry.push(message.willRetry === true);
        const assistantMessages = Array.isArray(message.messages)
          ? message.messages.filter((candidate) => candidate?.role === "assistant")
          : [];
        for (const assistant of assistantMessages) {
          this.events.assistantMessages.push({
            content: assistant.content,
            provider: assistant.provider,
            model: assistant.model,
            stopReason: assistant.stopReason,
            usage: assistant.usage,
          });
        }
        break;
      }
      case "agent_settled":
        this.events.agentSettled += 1;
        break;
      case "auto_retry_start":
      case "auto_retry_end":
        this.events.autoRetry += 1;
        break;
      case "compaction_start":
      case "compaction_end":
        this.events.compaction += 1;
        break;
      case "summarization_retry_scheduled":
      case "summarization_retry_attempt_start":
      case "summarization_retry_finished":
        this.events.summarizationRetry += 1;
        break;
      case "extension_error":
        this.events.extensionErrors += 1;
        break;
      case "tool_execution_start":
        this.events.resultStarts += 1;
        break;
      case "tool_execution_end":
        this.events.resultEnds += 1;
        this.events.resultDetails = message.result?.details;
        this.events.resultIsError = message.isError === true;
        break;
      default:
        break;
    }
  }

  async send(command, timeoutMs = 10_000) {
    if (this.fatalError !== undefined) throw this.fatalError;
    if (this.closed) fail("Pi is already closed");
    const id = `jidoka-rpc-${this.nextID++}`;
    const payload = { id, ...command };
    return await new Promise((resolveResponse, rejectResponse) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectResponse(new Error(`RPC response timed out: ${command.type}`));
      }, timeoutMs);
      this.pending.set(id, { resolve: resolveResponse, reject: rejectResponse, timer });
      this.child.stdin.write(`${JSON.stringify(payload)}\n`, (error) => {
        if (error !== null && error !== undefined) {
          clearTimeout(timer);
          this.pending.delete(id);
          rejectResponse(error);
        }
      });
    });
  }

  async waitFor(predicate, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (!predicate()) {
      if (this.fatalError !== undefined) throw this.fatalError;
      if (this.closed) fail("Pi closed before the expected event");
      if (Date.now() >= deadline) throw new Error("event wait timed out");
      await sleep(50);
    }
  }

  groupExists() {
    if (this.processGroupID === undefined) return false;
    try {
      process.kill(-this.processGroupID, 0);
      return true;
    } catch (error) {
      if (error?.code === "ESRCH") return false;
      if (error?.code === "EPERM") return true;
      throw error;
    }
  }

  signalGroup(signal) {
    if (this.processGroupID === undefined) return;
    try {
      process.kill(-this.processGroupID, signal);
    } catch (error) {
      if (error?.code !== "ESRCH") throw error;
    }
  }

  async waitForCleanup(timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.closed && !this.groupExists()) return true;
      await sleep(50);
    }
    return this.closed && !this.groupExists();
  }

  removeAgentDirectory() {
    if (!existsSync(this.agentDirectory)) return;
    const stat = lstatSync(this.agentDirectory);
    if (
      !stat.isDirectory() ||
      stat.isSymbolicLink() ||
      !basename(this.agentDirectory).startsWith("jidoka-pi-agent-")
    ) {
      fail("refusing to remove unexpected isolated Pi directory");
    }
    rmSync(this.agentDirectory, { recursive: true });
  }

  async stop() {
    if (this.stopPromise !== undefined) return await this.stopPromise;
    this.stopPromise = (async () => {
      let cleaned = false;
      try {
        if (!this.child.stdin.destroyed) this.child.stdin.end();
        if (this.groupExists()) this.signalGroup("SIGTERM");
        cleaned = await this.waitForCleanup(2_000);
        if (!cleaned && this.groupExists()) this.signalGroup("SIGKILL");
        if (!cleaned) cleaned = await this.waitForCleanup(3_000);
        return cleaned;
      } finally {
        this.removeAgentDirectory();
      }
    })();
    return await this.stopPromise;
  }
}

function canonicalCommand(command) {
  return {
    name: command?.name,
    source: command?.source,
    path: command?.sourceInfo?.path,
    sourceKind: command?.sourceInfo?.source,
    scope: command?.sourceInfo?.scope,
    origin: command?.sourceInfo?.origin,
  };
}

function verifyCommands(response, attestation, selectedSkill) {
  if (response.success !== true || response.command !== "get_commands") {
    fail("get_commands failed");
  }
  const commands = response.data?.commands;
  if (!Array.isArray(commands)) fail("get_commands returned no command array");
  const expectedPackaged = [
    {
      name: "jidoka-provenance",
      source: "extension",
      path: attestation.files["extensions/jidoka-runtime.ts"].path,
      sourceKind: "cli",
      scope: "temporary",
      origin: "top-level",
    },
    ...Object.keys(expectedFiles)
      .filter((path) => path.startsWith("skills/"))
      .sort()
      .filter((path) => selectedSkill === undefined || path.split("/")[1] === selectedSkill)
      .map((relativePath) => ({
        name: `skill:${relativePath.split("/")[1]}`,
        source: "skill",
        path: attestation.files[relativePath].path,
        sourceKind: "local",
        scope: "temporary",
        origin: "top-level",
      })),
  ];
  const expectedInline = {
    name: "llama",
    source: "extension",
    path: "<inline:llama.cpp>",
    sourceKind: "inline",
    scope: "temporary",
    origin: "top-level",
  };
  const actual = commands.map(canonicalCommand);
  const expected = [...expectedPackaged, expectedInline];
  const sortKey = (entry) => `${entry.source}:${entry.name}:${entry.path}`;
  actual.sort((left, right) => sortKey(left).localeCompare(sortKey(right)));
  expected.sort((left, right) => sortKey(left).localeCompare(sortKey(right)));
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail("command inventory differs from the exact allowlist");
  }
  return {
    packagedCommandCount: expectedPackaged.length,
    inlineCommandCount: 1,
    observedCommandCount: actual.length,
  };
}

function verifyBashBlocked(response) {
  if (
    response.success !== true ||
    response.command !== "bash" ||
    response.data?.exitCode !== 126 ||
    response.data?.cancelled !== false ||
    response.data?.truncated !== false ||
    String(response.data?.output ?? "").trim() !== "JIDOKA_USER_BASH_DENIED"
  ) {
    fail("direct RPC Bash was not blocked before spawn");
  }
}

function verifyModelState(response) {
  if (
    response.success !== true ||
    response.command !== "get_state" ||
    response.data?.model?.provider !== modelProvider ||
    response.data?.model?.id !== modelID ||
    response.data?.thinkingLevel !== "max" ||
    response.data?.isStreaming !== false ||
    response.data?.autoCompactionEnabled !== false
  ) {
    fail("model state differs from the authorized closed profile");
  }
}

function verifyAssistantMessage(events) {
  if (events.agentEndCount !== 1 || events.assistantMessages.length !== 1) {
    fail("provider-call cardinality differs from one assistant response");
  }
  const assistant = events.assistantMessages[0];
  const usage = assistant.usage;
  const content = Array.isArray(assistant.content) ? assistant.content : [];
  const textBlocks = content.filter((block) => block?.type === "text");
  const forbiddenBlocks = content.filter(
    (block) => !["text", "thinking", "redactedThinking"].includes(block?.type),
  );
  if (
    assistant.provider !== modelProvider ||
    assistant.model !== modelID ||
    assistant.stopReason !== "stop" ||
    usage === null ||
    typeof usage !== "object" ||
    !Number.isFinite(usage.input) ||
    !Number.isFinite(usage.output) ||
    usage.input <= 0 ||
    usage.output <= 0 ||
    textBlocks.length !== 1 ||
    forbiddenBlocks.length !== 0
  ) {
    fail("assistant response provenance, content, or usage is invalid");
  }
  const text = textBlocks[0].text;
  if (typeof text !== "string" || text.trim() !== text || text.includes("```")) {
    fail("assistant result is not bare JSON text");
  }
  let result;
  try {
    result = JSON.parse(text);
  } catch {
    fail("assistant result is not valid JSON");
  }
  return { assistant, result };
}

function verifyResult(details, contract) {
  if (details === null || typeof details !== "object" || Array.isArray(details)) {
    fail("structured result details are absent");
  }
  const keys = Object.keys(details).sort();
  const expectedKeys = [
    "fixtureId",
    "invariants",
    "profile",
    "role",
    "schemaVersion",
    "summary",
    "verdict",
  ];
  if (
    JSON.stringify(keys) !== JSON.stringify(expectedKeys) ||
    details.schemaVersion !== 1 ||
    details.profile !== contract.profile ||
    details.role !== "s4-profile" ||
    details.fixtureId !== contract.fixtureId ||
    details.verdict !== contract.verdict ||
    !Array.isArray(details.invariants) ||
    details.invariants.length !== 1 ||
    details.invariants[0] !== contract.invariant ||
    typeof details.summary !== "string" ||
    details.summary.length < 1 ||
    details.summary.length > 280
  ) {
    fail("structured result differs from the discriminating S4 contract");
  }
}

async function configureClosedSession(client) {
  const retry = await client.send({ type: "set_auto_retry", enabled: false });
  if (retry.success !== true || retry.command !== "set_auto_retry") fail("could not disable retry");
  const compaction = await client.send({ type: "set_auto_compaction", enabled: false });
  if (compaction.success !== true || compaction.command !== "set_auto_compaction") {
    fail("could not disable auto compaction");
  }
  const state = await client.send({ type: "get_state" });
  verifyModelState(state);
}

async function runWithCleanup(client, operation) {
  let result;
  let primaryError;
  activeClient = client;
  try {
    result = await operation();
  } catch (error) {
    primaryError = error;
  }
  const cleanup = await client.stop();
  if (activeClient === client) activeClient = undefined;
  if (!cleanup) {
    const cleanupError = new Error("Pi process group did not reach ESRCH");
    if (primaryError !== undefined) {
      throw new AggregateError([primaryError, cleanupError], "operation and cleanup failed");
    }
    throw cleanupError;
  }
  if (primaryError !== undefined) throw primaryError;
  return { result, cleanup };
}

async function runPreflight(attestation) {
  const client = new RPCClient(attestation);
  const { result } = await runWithCleanup(client, async () => {
    await configureClosedSession(client);
    const commandEvidence = verifyCommands(
      await client.send({ type: "get_commands" }),
      attestation,
      undefined,
    );
    verifyBashBlocked(
      await client.send({ type: "bash", command: "printf JIDOKA_BASH_EXECUTED" }),
    );
    const abort = await client.send({ type: "abort" });
    if (abort.success !== true || abort.command !== "abort") fail("abort was not acknowledged");
    return {
      schemaVersion: 1,
      mode: "preflight",
      abortAcknowledged: true,
      agentSettled: false,
      bashBlocked: true,
      ...commandEvidence,
      providerCalls: 0,
    };
  });
  return finalizeReport(result, client, attestation);
}

async function runTimeoutFixture(attestation) {
  const client = new RPCClient(attestation, { timeoutFixture: true });
  const { result } = await runWithCleanup(client, async () => {
    await configureClosedSession(client);
    const bashPromise = client.send({ type: "bash", command: "/bin/sleep 30" }, 10_000);
    await sleep(250);
    const abort = await client.send({ type: "abort_bash" }, 5_000);
    if (abort.success !== true || abort.command !== "abort_bash") {
      fail("active abort_bash was not acknowledged");
    }
    const bash = await bashPromise;
    if (
      bash.success !== true ||
      bash.command !== "bash" ||
      bash.data?.cancelled !== true ||
      bash.data?.truncated !== false
    ) {
      fail("active timeout fixture was not cancelled");
    }
    return {
      schemaVersion: 1,
      mode: "timeout",
      abortAcknowledged: true,
      activeCommandCancelled: true,
      fixedCommand: "/bin/sleep 30",
      providerCalls: 0,
    };
  });
  return finalizeReport(result, client, attestation);
}

function runLedgerPreflight(attestation, ledgerPath) {
  const root = dirname(resolve(ledgerPath));
  const makeLedger = (name) => {
    const directory = `${root}/${name}`;
    mkdirSync(directory, { mode: 0o700 });
    return new ProviderLedger(`${directory}/provider-call-ledger.json`);
  };
  const reserve = (ledger, attemptId, fixtureId) =>
    ledger.reserve({ attemptId, fixtureId, profile: "review", workflow: "ledger-preflight" });
  const expectFailure = (operation, expectedMessage) => {
    try {
      operation();
    } catch (error) {
      if (error?.message === expectedMessage) return true;
      throw error;
    }
    return false;
  };

  const attemptLedger = makeLedger("attempt-replay");
  reserve(attemptLedger, "preflight-attempt", "preflight-fixture-a");
  const attemptReplayBlocked = expectFailure(
    () => reserve(attemptLedger, "preflight-attempt", "preflight-fixture-b"),
    "provider attempt replay refused: preflight-attempt",
  );
  if (attemptLedger.read().attempts.length !== 1) fail("attempt replay changed cardinality");

  const fixtureLedger = makeLedger("fixture-replay");
  reserve(fixtureLedger, "preflight-attempt-a", "preflight-fixture");
  const fixtureReplayBlocked = expectFailure(
    () => reserve(fixtureLedger, "preflight-attempt-b", "preflight-fixture"),
    "provider fixture replay refused: preflight-fixture",
  );
  if (fixtureLedger.read().attempts.length !== 1) fail("fixture replay changed cardinality");

  const lockLedger = makeLedger("concurrent-lock");
  reserve(lockLedger, "preflight-lock-a", "preflight-lock-fixture-a");
  mkdirSync(lockLedger.lockPath, { mode: 0o700 });
  const lockBlocked = expectFailure(
    () => reserve(lockLedger, "preflight-lock-b", "preflight-lock-fixture-b"),
    "provider ledger is locked; refusing concurrent calls",
  );
  rmdirSync(lockLedger.lockPath);
  if (lockLedger.read().attempts.length !== 1) fail("lock rejection changed cardinality");

  const capLedger = makeLedger("call-cap");
  for (let index = 0; index < authorizedCallCap; index += 1) {
    reserve(capLedger, `preflight-cap-${index}`, `preflight-cap-fixture-${index}`);
  }
  const capBlocked = expectFailure(
    () => reserve(capLedger, "preflight-over-cap", "preflight-over-cap"),
    "provider call cap exhausted",
  );
  if (capLedger.read().attempts.length !== authorizedCallCap) {
    fail("cap rejection changed cardinality");
  }

  if (!attemptReplayBlocked || !fixtureReplayBlocked || !lockBlocked || !capBlocked) {
    fail("provider ledger preflight failed");
  }
  return {
    schemaVersion: 1,
    mode: "ledger-preflight",
    attemptReplayBlocked,
    attemptsAtCap: authorizedCallCap,
    capBlocked,
    fixtureReplayBlocked,
    lockBlocked,
    providerCalls: 0,
    piCompatibility: attestation.piCompatibility,
    piVersion: attestation.piVersion,
    resourceSHA256: resourceDigests(attestation),
    systemRuntimeSHA256: attestation.systemRuntimeSHA256,
  };
}

async function runProfile(attestation, profile, ledgerPath) {
  const canonicalLedgerPath = resolve(
    homedir(),
    "Library/Application Support/JidokaCode/Consent/provider-call-ledger.json",
  );
  if (resolve(ledgerPath) !== canonicalLedgerPath) {
    fail("profile provider ledger is not the canonical Application Support ledger");
  }
  const contract = { profile, ...profileContracts[profile] };
  const attemptId = `s4-${contract.fixtureId}`;
  const ledger = new ProviderLedger(ledgerPath);
  const callsConsumed = ledger.reserve({
    attemptId,
    fixtureId: contract.fixtureId,
    profile,
    workflow: "S4",
  });
  let client;
  try {
    client = new RPCClient(attestation, {
      selectedSkill: contract.skill,
      providerGate: { attemptId, ledgerPath: ledger.path },
    });
    const { result } = await runWithCleanup(client, async () => {
      await configureClosedSession(client);
      const commandEvidence = verifyCommands(
        await client.send({ type: "get_commands" }),
        attestation,
        contract.skill,
      );
      verifyBashBlocked(
        await client.send({ type: "bash", command: "printf JIDOKA_BASH_EXECUTED" }),
      );
      const prompt = [
        `/skill:${contract.skill}`,
        `Synthetic fixture ${contract.fixtureId}.`,
        contract.facts,
        "No tools are available. Return exactly one bare JSON object and no other text.",
        "The object must contain exactly schemaVersion, profile, role, fixtureId, verdict, summary, invariants.",
        `Use schemaVersion 1, profile ${profile}, role s4-profile, fixtureId ${contract.fixtureId}.`,
        "Determine verdict and the sole invariant from the packaged skill.",
      ].join(" ");
      const promptAccepted = await client.send({ type: "prompt", message: prompt }, 10_000);
      if (promptAccepted.success !== true || promptAccepted.command !== "prompt") {
        fail("profile prompt was rejected");
      }
      try {
        await client.waitFor(() => client.events.agentSettled === 1, 120_000);
      } catch (error) {
        const abort = await client.send({ type: "abort" }, 5_000).catch(() => undefined);
        if (abort?.success !== true) throw error;
        throw new Error(`profile timeout after acknowledged abort: ${error.message}`);
      }
      if (
        client.events.agentSettled !== 1 ||
        client.events.agentEndWillRetry.length !== 1 ||
        client.events.agentEndWillRetry[0] !== false ||
        client.events.autoRetry !== 0 ||
        client.events.compaction !== 0 ||
        client.events.summarizationRetry !== 0 ||
        client.events.extensionErrors !== 0 ||
        client.events.resultStarts !== 0 ||
        client.events.resultEnds !== 0 ||
        client.events.resultDetails !== undefined ||
        client.events.resultIsError !== undefined
      ) {
        fail("profile event cardinality is invalid");
      }
      const { assistant, result: structuredResult } = verifyAssistantMessage(client.events);
      verifyResult(structuredResult, contract);
      verifyModelState(await client.send({ type: "get_state" }));
      const stats = await client.send({ type: "get_session_stats" });
      if (
        stats.success !== true ||
        stats.command !== "get_session_stats" ||
        !Number.isFinite(stats.data?.tokens?.total) ||
        stats.data.tokens.total <= 0 ||
        !Number.isFinite(stats.data?.cost)
      ) {
        fail("session usage is unavailable");
      }
      return {
        schemaVersion: 1,
        mode: "profile",
        profile,
        fixtureId: contract.fixtureId,
        agentSettled: true,
        bashBlocked: true,
        callsConsumed,
        ...commandEvidence,
        providerCalls: client.events.assistantMessages.length,
        result: structuredResult,
        usage: {
          assistant: assistant.usage,
          sessionCost: stats.data.cost,
          sessionTokens: stats.data.tokens,
        },
      };
    });
    const issuedAttempt = ledger.read().attempts.find(
      (attempt) => attempt.attemptId === attemptId,
    );
    if (issuedAttempt?.state !== "issued" || issuedAttempt.providerRequestCount !== 1) {
      fail("provider boundary did not issue exactly one request");
    }
    ledger.transition(attemptId, "issued", "settled", {
      provider: client.events.assistantMessages[0].provider,
      responseModel: client.events.assistantMessages[0].model,
      stopReason: client.events.assistantMessages[0].stopReason,
      usage: result.usage.assistant,
    });
    return finalizeReport(result, client, attestation);
  } catch (error) {
    try {
      const attempt = ledger.read().attempts.find((candidate) => candidate.attemptId === attemptId);
      if (attempt?.state === "reserved" || attempt?.state === "issued") {
        ledger.transition(attemptId, attempt.state, "failed", {
          failure: error.name ?? "Error",
        });
      }
    } catch (ledgerError) {
      throw new AggregateError([error, ledgerError], "profile and ledger failure");
    }
    throw error;
  }
}

function resourceDigests(attestation) {
  return Object.fromEntries(
    Object.entries(attestation.files).map(([path, value]) => [path, value.sha256]),
  );
}

function finalizeReport(report, client, attestation) {
  if (existsSync(client.agentDirectory)) fail("isolated Pi directory survived cleanup");
  return {
    ...report,
    authenticationProviders: client.authenticationProviders,
    childCleanup: true,
    credentialAccess: client.authenticationProviders.length > 0,
    environmentKeys: Object.keys(client.environment).sort(),
    isolatedSettingsSHA256: client.settingsSHA256,
    piCompatibility: attestation.piCompatibility,
    piVersion: attestation.piVersion,
    providerTransport: client.transport,
    resourceSHA256: resourceDigests(attestation),
    stderrSHA256: sha256(client.stderrBuffer),
    systemRuntimeSHA256: attestation.systemRuntimeSHA256,
  };
}

let activeClient;
let signalHandling = false;
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, async () => {
    if (signalHandling) return;
    signalHandling = true;
    if (activeClient !== undefined) await activeClient.stop().catch(() => false);
    process.exit(signal === "SIGINT" ? 130 : 143);
  });
}

async function main() {
  const mode = process.argv[2];
  const requestedRoot = process.argv[3];
  if (!["preflight", "timeout", "ledger-preflight", "profile"].includes(mode)) {
    fail("unknown probe mode");
  }
  if (typeof requestedRoot !== "string") fail("packaged resource root is required");
  const attestation = attestResources(requestedRoot);
  const systemRuntime = attestSystemRuntime({
    attestation,
    expectedPolicySHA256: expectedPiRuntimePolicySHA256,
    policyRelativePath: piRuntimePolicyRelativePath,
  });
  attestation.piCompatibility = systemRuntime.compatibility;
  attestation.piVersion = systemRuntime.version;
  attestation.systemRuntimeSHA256 = systemRuntime.digests;
  let report;
  if (mode === "preflight") {
    if (process.argv.length !== 4) fail("preflight accepts only a resource root");
    report = await runPreflight(attestation);
  } else if (mode === "timeout") {
    if (process.argv.length !== 4) fail("timeout accepts only a resource root");
    report = await runTimeoutFixture(attestation);
  } else if (mode === "ledger-preflight") {
    if (process.argv.length !== 5) fail("ledger-preflight requires a ledger path");
    report = runLedgerPreflight(attestation, process.argv[4]);
  } else {
    if (process.argv.length !== 6) fail("profile requires profile and ledger path");
    const profile = process.argv[4];
    if (!(profile in profileContracts)) fail("unknown profile");
    report = await runProfile(attestation, profile, process.argv[5]);
  }
  process.stdout.write(`${JSON.stringify(report)}\n`);
}

main().catch((error) => {
  const message = error instanceof AggregateError ? error.errors.map((item) => item.message).join("; ") : error.message;
  process.stderr.write(`S4 Pi probe failed: ${message}\n`);
  process.exitCode = 1;
});
