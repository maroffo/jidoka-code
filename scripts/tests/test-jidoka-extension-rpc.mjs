#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const root = realpathSync(fileURLToPath(new URL("../..", import.meta.url)));
const resourceRoot = realpathSync(
  process.env.JIDOKA_PI_RESOURCE_ROOT ?? resolve(root, "Resources/Pi"),
);
const releaseRuntimeRoot = realpathSync(process.env.JIDOKA_RELEASE_RUNTIME_ROOT ?? "");
const nodePath = realpathSync(process.execPath);
const piPath = resolve(releaseRuntimeRoot, "pi/dist/cli.js");
assert.equal(nodePath, resolve(releaseRuntimeRoot, "node/bin/node"));
const temporaryRaw = mkdtempSync(`${tmpdir()}/jidoka-extension-rpc-`);
const temporary = realpathSync(temporaryRaw);
chmodSync(temporary, 0o700);
const home = resolve(temporary, "home");
const agent = resolve(temporary, "agent");
const workspace = resolve(temporary, "workspace");
for (const directory of [home, agent, workspace]) {
  mkdirSync(directory, { mode: 0o700 });
}
const authPath = resolve(agent, "auth.json");
const settingsPath = resolve(agent, "settings.json");
writeFileSync(authPath, "{}\n", { mode: 0o600 });
writeFileSync(
  settingsPath,
  `${JSON.stringify({
    compaction: { enabled: false },
    defaultProjectTrust: "never",
    enableInstallTelemetry: false,
    retry: { enabled: false, provider: { maxRetries: 0 } },
    transport: "sse",
  })}\n`,
  { mode: 0o600 },
);
chmodSync(authPath, 0o600);
chmodSync(settingsPath, 0o600);
const manifestPath = resolve(resourceRoot, "workflow-resources.json");
const manifestSHA256 = createHash("sha256").update(readFileSync(manifestPath)).digest("hex");
assert.equal(
  manifestSHA256,
  "230c9a45b9dd53443837166c6e8b60adac67d3bfeb32249de8ca5228f1e1357d",
);
const configurationPath = resolve(temporary, "workflow.json");
writeFileSync(
  configurationPath,
  `${JSON.stringify({
    allowedCommandIDs: [],
    allowedWritePaths: [],
    artifactSHA256: "a".repeat(64),
    contractVersion: "1",
    nonce: "nonce-12345678",
    resourceManifestPath: manifestPath,
    resourceManifestSHA256: manifestSHA256,
    resourceRoot,
    role: "security",
    schemaVersion: 1,
    toolPolicy: "read-only",
    workflow: "pr-review",
    workspaceRoot: workspace,
  })}\n`,
  { mode: 0o600 },
);
chmodSync(configurationPath, 0o600);

const expectedTools = [
  "jidoka_code_preflight",
  "jidoka_code_read",
  "jidoka_code_result",
  "jidoka_code_workspace_query",
];
const child = spawn(
  nodePath,
  [
    piPath,
    "--mode",
    "rpc",
    "--no-session",
    "--no-approve",
    "--no-context-files",
    "--no-themes",
    "--no-prompt-templates",
    "--model",
    "openai-codex/gpt-5.6-sol:max",
    "--no-extensions",
    "--extension",
    resolve(resourceRoot, "extensions/jidoka-deny-user-bash.js"),
    "--extension",
    resolve(resourceRoot, "extensions/jidoka-code.ts"),
    "--no-skills",
    "--skill",
    resolve(resourceRoot, "skills/jidoka-code-pr-review/SKILL.md"),
    "--skill",
    resolve(resourceRoot, "skills/jidoka-code-review-security/SKILL.md"),
    "--tools",
    expectedTools.join(","),
  ],
  {
    cwd: workspace,
    detached: false,
    env: {
      GIT_ASKPASS: "/usr/bin/false",
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_SSH_COMMAND: "/usr/bin/false",
      GIT_TERMINAL_PROMPT: "0",
      HOME: home,
      JIDOKA_CODE_CONFIG: configurationPath,
      JIDOKA_RELEASE_RUNTIME_ROOT: releaseRuntimeRoot,
      LANG: "en_US.UTF-8",
      LC_ALL: "en_US.UTF-8",
      PATH: "/usr/bin:/bin",
      PI_CODING_AGENT_DIR: agent,
      PI_OFFLINE: "1",
      PI_SKIP_VERSION_CHECK: "1",
      TMPDIR: temporary,
    },
    stdio: ["pipe", "pipe", "pipe"],
  },
);

let stdoutBuffer = Buffer.alloc(0);
let stderr = Buffer.alloc(0);
let closed = false;
let fatalError;
const pending = new Map();
const events = [];
child.stderr.on("data", (chunk) => {
  stderr = Buffer.concat([stderr, chunk]);
  if (stderr.length > 1_048_576) fatalError = new Error("Pi stderr exceeded bound");
});
child.stdout.on("data", (chunk) => {
  stdoutBuffer = Buffer.concat([stdoutBuffer, chunk]);
  if (stdoutBuffer.length > 1_048_576) {
    fatalError = new Error("Pi stdout record exceeded bound");
    return;
  }
  while (true) {
    const newline = stdoutBuffer.indexOf(0x0a);
    if (newline < 0) break;
    let line = stdoutBuffer.subarray(0, newline);
    stdoutBuffer = stdoutBuffer.subarray(newline + 1);
    if (line.at(-1) === 0x0d) line = line.subarray(0, -1);
    if (line.length === 0) {
      fatalError = new Error("Pi emitted an empty JSONL record");
      continue;
    }
    let value;
    try {
      value = JSON.parse(line.toString("utf8"));
    } catch (error) {
      fatalError = error;
      continue;
    }
    if (value.type === "response" && typeof value.id === "string") {
      const callback = pending.get(value.id);
      if (callback === undefined) {
        fatalError = new Error("uncorrelated Pi response");
      } else {
        pending.delete(value.id);
        callback(value);
      }
    } else {
      events.push(value);
    }
  }
});
child.on("error", (error) => {
  fatalError = error;
});
child.on("close", () => {
  closed = true;
});

let sequence = 0;
async function send(command) {
  if (fatalError !== undefined) throw fatalError;
  const id = `rpc-${++sequence}`;
  const response = new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      rejectPromise(new Error(`RPC timeout: ${command.type}`));
    }, 10_000);
    pending.set(id, (value) => {
      clearTimeout(timer);
      resolvePromise(value);
    });
  });
  child.stdin.write(`${JSON.stringify({ ...command, id })}\n`);
  const value = await response;
  assert.equal(value.command, command.type);
  assert.equal(value.success, true);
  return value;
}

function waitFor(predicate, timeoutMilliseconds = 5_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  return new Promise((resolvePromise, rejectPromise) => {
    const check = () => {
      if (fatalError !== undefined) {
        rejectPromise(fatalError);
      } else if (predicate()) {
        resolvePromise();
      } else if (Date.now() >= deadline || closed) {
        rejectPromise(new Error("event timeout"));
      } else {
        setTimeout(check, 10);
      }
    };
    check();
  });
}

try {
  const commands = await send({ type: "get_commands" });
  const observedCommands = commands.data.commands.map((command) => ({
    name: command.name,
    origin: command.sourceInfo.origin,
    path: command.sourceInfo.path,
    scope: command.sourceInfo.scope,
    source: command.source,
  }));
  assert.deepEqual(observedCommands, [
    {
      name: "jidoka-code-preflight",
      origin: "top-level",
      path: resolve(resourceRoot, "extensions/jidoka-code.ts"),
      scope: "temporary",
      source: "extension",
    },
    {
      name: "llama",
      origin: "top-level",
      path: "<inline:llama.cpp>",
      scope: "temporary",
      source: "extension",
    },
    {
      name: "skill:jidoka-code-pr-review",
      origin: "top-level",
      path: resolve(resourceRoot, "skills/jidoka-code-pr-review/SKILL.md"),
      scope: "temporary",
      source: "skill",
    },
    {
      name: "skill:jidoka-code-review-security",
      origin: "top-level",
      path: resolve(resourceRoot, "skills/jidoka-code-review-security/SKILL.md"),
      scope: "temporary",
      source: "skill",
    },
  ]);

  await send({ type: "prompt", message: "/jidoka-code-preflight" });
  await waitFor(() =>
    events.some(
      (event) =>
        event.type === "extension_ui_request" &&
        event.method === "notify" &&
        event.message?.startsWith("JIDOKA_PREFLIGHT:"),
    ),
  );
  const notification = events.find((event) => event.message?.startsWith("JIDOKA_PREFLIGHT:"));
  const preflight = JSON.parse(notification.message.slice("JIDOKA_PREFLIGHT:".length));
  assert.deepEqual(preflight.activeTools, expectedTools);
  assert.equal(preflight.genericBashActive, false);
  assert.equal(preflight.manifestSHA256, manifestSHA256);
  assert.deepEqual(preflight.workspaceOperations, [
    "status",
    "diff",
    "log",
    "show",
    "search",
    "list",
  ]);

  const bash = await send({ type: "bash", command: "printf forbidden" });
  assert.deepEqual(bash.data, {
    cancelled: false,
    exitCode: 126,
    output: "JIDOKA_USER_BASH_DENIED",
    truncated: false,
  });
  assert.equal(events.some((event) => event.type === "extension_error"), false);
  assert.equal(events.some((event) => event.type === "agent_start"), false);
  assert.equal(events.some((event) => event.type === "agent_end"), false);
  assert.equal(stderr.length, 0);
  assert.equal(existsSync(resolve(home, ".pi")), false);
  assert.deepEqual(readdirSync(agent).sort(), [
    "auth.json",
    "models-store.json",
    "settings.json",
  ]);
  const modelStorePath = resolve(agent, "models-store.json");
  const modelStoreStat = lstatSync(modelStorePath);
  assert.equal(modelStoreStat.isFile(), true);
  assert.equal(modelStoreStat.isSymbolicLink(), false);
  assert.equal(modelStoreStat.mode & 0o077, 0);
  assert.equal(modelStoreStat.size <= 1_048_576, true);
  const modelStore = readFileSync(modelStorePath, "utf8");
  assert.doesNotMatch(modelStore, /GH_TOKEN|GITHUB_TOKEN|OPENAI_API_KEY|SSH_AUTH_SOCK/);

  child.stdin.end();
  await waitFor(() => closed, 5_000);
  assert.equal(stdoutBuffer.length, 0);
  process.stdout.write("Jidoka extension RPC preflight: PASS, providerCalls=0\n");
} finally {
  if (!closed) {
    try {
      process.kill(child.pid, "SIGKILL");
    } catch (error) {
      if (error?.code !== "ESRCH") throw error;
    }
  }
  rmSync(temporaryRaw, { recursive: true, force: true });
}
