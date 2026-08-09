import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";

const MAX_RECORD_BYTES = 1_048_576;

function fail(message) {
  process.stderr.write(`herdr s11 fixture failed: ${message}\n`);
  process.exit(1);
}

function absolute(value, name) {
  if (!path.isAbsolute(value) || value.includes("\0") || path.normalize(value) !== value) {
    fail(`invalid ${name}`);
  }
  return value;
}

async function request(socketPath, method, params) {
  absolute(socketPath, "socket path");
  const id = `s11-${crypto.randomUUID()}`;
  const payload = `${JSON.stringify({ id, method, params })}\n`;
  if (Buffer.byteLength(payload) > MAX_RECORD_BYTES) fail("oversized request");
  const record = await new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let buffer = Buffer.alloc(0);
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("timeout"));
    }, 5_000);
    socket.on("connect", () => socket.write(payload));
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > MAX_RECORD_BYTES) {
        clearTimeout(timer);
        socket.destroy();
        reject(new Error("oversized response"));
        return;
      }
      const newline = buffer.indexOf(0x0a);
      if (newline >= 0) {
        clearTimeout(timer);
        socket.destroy();
        resolve(buffer.subarray(0, newline).toString("utf8"));
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
  const response = JSON.parse(record);
  if (response.id !== id) fail("response id mismatch");
  if (response.error) fail(`remote ${String(response.error.code ?? "unknown")}`);
  if (!response.result) fail("missing result");
  return response.result;
}

function assertObserverFrames(fileValue) {
  const file = absolute(fileValue, "observer file");
  const records = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
  let frameCount = 0;
  for (const record of records) {
    let value;
    try {
      value = JSON.parse(record);
    } catch {
      fail("malformed observer record");
    }
    if (typeof value.bytes !== "string") continue;
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.bytes)) {
      fail("malformed observer bytes");
    }
    const bytes = Buffer.from(value.bytes, "base64");
    if (bytes.length === 0 || bytes.length > MAX_RECORD_BYTES) fail("invalid observer frame");
    frameCount += 1;
  }
  if (frameCount === 0) fail("observer emitted no terminal frames");
}

function assertAuthoritativeScreen(fileValue, runID) {
  const file = absolute(fileValue, "screen file");
  if (!/^[a-z0-9][a-z0-9-]{7,63}$/.test(runID)) fail("invalid screen run id");
  const compact = fs.readFileSync(file, "utf8").replace(/\s/g, "");
  if (
    !compact.includes("visible-no-secret") ||
    !compact.includes('"herdr_keys":[]') ||
    !compact.includes(`"run_id":"${runID}"`)
  ) {
    fail("authoritative screen omitted fixture evidence");
  }
}

function rolePane(label, host, runRoot, cwd, runID) {
  return {
    command: [host, "--launch-attempt-id", runID],
    cwd,
    env: { JIDOKA_CODE_HERDR_RUN_ROOT: runRoot },
    label,
    type: "pane",
  };
}

function prepareDescriptor([
  runRootValue,
  workspaceID,
  childValue,
  cwdValue,
  runID,
  alias,
  role,
]) {
  const runRoot = absolute(runRootValue, "run root");
  const child = absolute(childValue, "child executable");
  const cwd = absolute(cwdValue, "working directory");
  if (!/^[a-z0-9][a-z0-9-]{7,63}$/.test(runID)) fail("invalid run id");
  if (!/^[a-z][a-z0-9_-]{0,31}$/.test(alias)) fail("invalid alias");
  if (!new Set(["plan", "review"]).has(role)) fail("invalid role");
  const runRootStatus = fs.lstatSync(runRoot);
  const cwdStatus = fs.lstatSync(cwd);
  if (
    !runRootStatus.isDirectory() ||
    runRootStatus.isSymbolicLink() ||
    !cwdStatus.isDirectory() ||
    cwdStatus.isSymbolicLink() ||
    fs.realpathSync(child) !== child
  ) {
    fail("non-canonical path");
  }
  const runDirectory = path.join(runRoot, runID);
  fs.mkdirSync(runDirectory, { mode: 0o700 });
  const descriptor = {
    agentAlias: alias,
    childArguments: ["--run-id", runID, "--hold-ms", "5000"],
    childEnvironment: {
      JIDOKA_FIXTURE_ROLE: role,
      JIDOKA_FIXTURE_SENTINEL: "visible-no-secret",
    },
    childExecutable: child,
    childWorkingDirectory: cwd,
    executionTimeoutMilliseconds: 10_000,
    abortGraceMilliseconds: 1_000,
    displayAgent: `Jidoka | synthetic ${role}`,
    expectedWorkspaceID: workspaceID,
    generation: 1,
    jobID: "job-s11-0001",
    launchAttemptID: runID,
    repositoryID: "repo-s11-0001",
    role,
    runID,
    runNonce: `nonce-s11-${role}-00000001`,
    schemaVersion: 1,
    title: `Synthetic Herdr ${role} canary`,
  };
  const bytes = Buffer.from(`${JSON.stringify(descriptor)}\n`, "utf8");
  const digest = crypto.createHash("sha256").update(bytes).digest("hex");
  fs.writeFileSync(path.join(runDirectory, "launch.json"), bytes, {
    flag: "wx",
    mode: 0o600,
  });
  fs.writeFileSync(path.join(runDirectory, "launch.sha256"), `${digest}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  process.stdout.write(`${JSON.stringify({ digest, runID })}\n`);
}

async function main() {
  const [command, ...values] = process.argv.slice(2);
  switch (command) {
    case "ping": {
      if (values.length !== 1) fail("ping arguments");
      process.stdout.write(`${JSON.stringify(await request(values[0], "ping", {}))}\n`);
      return;
    }
    case "snapshot": {
      if (values.length !== 1) fail("snapshot arguments");
      process.stdout.write(`${JSON.stringify(await request(values[0], "session.snapshot", {}))}\n`);
      return;
    }
    case "create-workspace": {
      if (values.length !== 3) fail("create-workspace arguments");
      const [socketPath, label, cwd] = values;
      process.stdout.write(
        `${JSON.stringify(
          await request(socketPath, "workspace.create", {
            cwd: absolute(cwd, "workspace cwd"),
            env: {},
            focus: false,
            label,
          }),
        )}\n`,
      );
      return;
    }
    case "apply-layout": {
      if (values.length !== 8) fail("apply-layout arguments");
      const [
        socketPath,
        workspaceID,
        tabLabel,
        hostValue,
        runRootValue,
        cwdValue,
        planRunID,
        reviewRunID,
      ] = values;
      const host = absolute(hostValue, "host executable");
      const runRoot = absolute(runRootValue, "run root");
      const cwd = absolute(cwdValue, "pane cwd");
      process.stdout.write(
        `${JSON.stringify(
          await request(socketPath, "layout.apply", {
            focus: false,
            root: {
              direction: "right",
              first: rolePane("plan", host, runRoot, cwd, planRunID),
              ratio: 0.5,
              second: rolePane("review", host, runRoot, cwd, reviewRunID),
              type: "split",
            },
            tab_label: tabLabel,
            workspace_id: workspaceID,
          }),
        )}\n`,
      );
      return;
    }
    case "export-layout": {
      if (values.length !== 2) fail("export-layout arguments");
      const [socketPath, tabID] = values;
      process.stdout.write(
        `${JSON.stringify(await request(socketPath, "layout.export", { tab_id: tabID }))}\n`,
      );
      return;
    }
    case "assert-observer": {
      if (values.length !== 1) fail("assert-observer arguments");
      assertObserverFrames(values[0]);
      return;
    }
    case "assert-screen": {
      if (values.length !== 2) fail("assert-screen arguments");
      assertAuthoritativeScreen(values[0], values[1]);
      return;
    }
    case "prepare-descriptor": {
      if (values.length !== 7) fail("prepare-descriptor arguments");
      prepareDescriptor(values);
      return;
    }
    default:
      fail("closed command required");
  }
}

await main();
