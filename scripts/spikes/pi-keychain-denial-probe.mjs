#!/usr/bin/env node

import { createHash } from "node:crypto";
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { spawn } from "node:child_process";

const releaseRuntimeRoot = realpathSync(process.env.JIDOKA_RELEASE_RUNTIME_ROOT ?? "");
const nodePath = realpathSync(process.execPath);
const piPath = `${releaseRuntimeRoot}/pi/dist/cli.js`;
if (nodePath !== `${releaseRuntimeRoot}/node/bin/node`) {
  throw new Error("Node is outside the attested release runtime");
}
const service = "com.maroffo.JidokaCode.test.github";
const account = "eabf21b6-02df-4854-b9a8-c8a21eafdbca";
const requestID = "jidoka-s3-keychain-denial";
const expectedExtensionSHA256 = "ba18988ad739c592920555515ee246e07d325f0e90df345a61de4e7f41a24995";
if (process.argv.length !== 3) {
  process.stderr.write("usage: pi-keychain-denial-probe.mjs <packaged-extension>\n");
  process.exit(7);
}
const requestedExtensionPath = process.argv[2];
const requestedExtensionStat = lstatSync(requestedExtensionPath);
if (!requestedExtensionStat.isFile() || requestedExtensionStat.isSymbolicLink()) {
  process.stderr.write("packaged extension must be a regular non-symbolic file\n");
  process.exit(7);
}
const extensionPath = realpathSync(requestedExtensionPath);
if (!extensionPath.endsWith("/Contents/Resources/Pi/extensions/jidoka-deny-user-bash.js")) {
  process.stderr.write("packaged extension path differs from the closed resource\n");
  process.exit(7);
}
const extensionSHA256 = createHash("sha256").update(readFileSync(extensionPath)).digest("hex");
if (extensionSHA256 !== expectedExtensionSHA256) {
  process.stderr.write("packaged extension digest differs from the reviewed resource\n");
  process.exit(7);
}
const command = [
  "if value=$(/usr/bin/security find-generic-password",
  `-s '${service}' -a '${account}' -w 2>/dev/null); then`,
  "digest=$(printf '%s' \"$value\" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}');",
  "unset value; printf 'READ:%s\\n' \"$digest\";",
  "else printf 'DENIED\\n'; fi",
].join(" ");
const argv = [
  piPath,
  "--mode", "rpc",
  "--no-session",
  "--no-extensions",
  "--extension", extensionPath,
  "--no-skills",
  "--no-prompt-templates",
  "--no-tools",
  "--model", "openai-codex/gpt-5.6-sol:max",
];
const environment = {
  HOME: homedir(),
  PATH: "/usr/bin:/bin",
  TMPDIR: tmpdir(),
};

const child = spawn(nodePath, argv, {
  cwd: "/",
  detached: true,
  env: environment,
  stdio: ["pipe", "pipe", "pipe"],
});
let stdoutBuffer = "";
let stderrBuffer = "";
let settled = false;
let emitted = false;
let pendingReport;
let forceTimer;
let cleanupTimer;
let operationTimer;

function signalGroup(signal) {
  if (child.pid === undefined) return;
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if (error?.code !== "ESRCH") throw error;
  }
}

function emitReport(childCleanup) {
  if (emitted || pendingReport === undefined) return;
  emitted = true;
  clearTimeout(forceTimer);
  clearTimeout(cleanupTimer);
  const report = {
    argv: [
      nodePath,
      ...argv.map((value) => value === extensionPath ? "<packaged-extension>" : value),
    ],
    childCleanup,
    environmentKeys: Object.keys(environment).sort(),
    extensionSHA256,
    modelPrompts: 0,
    outcome: childCleanup ? pendingReport.outcome : "cleanup-failed",
    stderrSHA256: createHash("sha256").update(stderrBuffer).digest("hex"),
  };
  if (pendingReport.sha256 !== undefined) report.sha256 = pendingReport.sha256;
  process.stdout.write(`${JSON.stringify(report)}\n`);
  process.exitCode = childCleanup ? pendingReport.exitCode : 6;
}

function finish(outcome, exitCode, sha256 = undefined) {
  if (settled) return;
  settled = true;
  clearTimeout(operationTimer);
  pendingReport = { outcome, exitCode, sha256 };
  child.stdin.end();
  if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) {
    emitReport(true);
    return;
  }
  try {
    signalGroup("SIGTERM");
  } catch {
    emitReport(false);
    return;
  }
  forceTimer = setTimeout(() => {
    try {
      signalGroup("SIGKILL");
    } catch {
      emitReport(false);
    }
  }, 1_000);
  cleanupTimer = setTimeout(() => emitReport(false), 3_000);
}

function consumeLine(line) {
  if (line.length === 0 || settled) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    finish("ambiguous", 4);
    return;
  }
  if (message.id !== requestID || message.type !== "response" || message.command !== "bash") {
    return;
  }
  if (message.success !== true || message.data?.cancelled !== false || message.data?.truncated !== false) {
    finish("ambiguous", 4);
    return;
  }
  const output = String(message.data?.output ?? "").trim();
  if (message.data?.exitCode === 126 && output === "JIDOKA_USER_BASH_DENIED") {
    finish("blocked", 0);
  } else if (message.data?.exitCode === 0 && output === "DENIED") {
    finish("executed-denied", 4);
  } else if (message.data?.exitCode === 0 && /^READ:[0-9a-f]{64}$/.test(output)) {
    finish("read", 2, output.slice(5));
  } else {
    finish("ambiguous", 4);
  }
}

child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  stdoutBuffer += chunk;
  if (stdoutBuffer.length > 1_048_576) {
    finish("ambiguous", 4);
    return;
  }
  let newline;
  while ((newline = stdoutBuffer.indexOf("\n")) >= 0) {
    const line = stdoutBuffer.slice(0, newline);
    stdoutBuffer = stdoutBuffer.slice(newline + 1);
    consumeLine(line);
  }
});
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  stderrBuffer += chunk;
  if (stderrBuffer.length > 1_048_576) finish("ambiguous", 4);
});
child.on("error", () => finish("spawn-error", 5));
child.on("close", () => {
  if (settled) {
    emitReport(true);
  } else {
    finish("early-exit", 5);
    emitReport(true);
  }
});

operationTimer = setTimeout(() => finish("timeout", 3), 60_000);
child.stdin.write(`${JSON.stringify({ id: requestID, type: "bash", command })}\n`);
