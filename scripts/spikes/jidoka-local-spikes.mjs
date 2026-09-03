#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { basename, dirname, resolve } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

const developerDirectory = process.env.DEVELOPER_DIR;
const gitPath = "/usr/bin/git";
const releaseRuntimeRoot = realpathSync(process.env.JIDOKA_RELEASE_RUNTIME_ROOT ?? "");
const nodePath = realpathSync(process.execPath);
if (nodePath !== `${releaseRuntimeRoot}/node/bin/node`) {
  fail("Node is outside the attested release runtime");
}
if (typeof developerDirectory !== "string" || developerDirectory.length === 0) {
  fail("DEVELOPER_DIR is required");
}
const gitExecPath = spawnSync(gitPath, ["--exec-path"], {
  encoding: "utf8",
  env: { DEVELOPER_DIR: developerDirectory, PATH: "/usr/bin:/bin" },
}).stdout?.trim();
if (typeof gitExecPath !== "string" || gitExecPath.length === 0) {
  fail("Git executable path is unavailable");
}
const gitHTTPBackendPath = `${gitExecPath}/git-http-backend`;
const zeroSHA = "0".repeat(40);
const maximumOutputBytes = 8 * 1024 * 1024;

function fail(message) {
  throw new Error(message);
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function attestSystemRuntime(options = {}) {
  const expected = options.expected ?? {
    [gitPath]: "1685f2c90307faa05ef5ae8f707d3a18a519c9dad75882768f66abb475f1b3d7",
    [gitHTTPBackendPath]:
      "4026051f87a437197a913d4ca5d3196f1d749bf6060f84c74cc374263988110a",
  };
  const inspectedNodePath = options.nodePath ?? nodePath;
  const inspect = options.lstat ?? lstatSync;
  const read = options.readFile ?? readFileSync;
  const observed = {};
  for (const [path, expectedSHA256] of Object.entries(expected)) {
    const stat = inspect(path);
    if (!stat.isFile() || stat.isSymbolicLink()) fail(`unsafe system runtime: ${path}`);
    const digest = sha256(read(path));
    if (digest !== expectedSHA256) fail(`system runtime digest drift: ${path}`);
    observed[path] = digest;
  }
  observed[inspectedNodePath] = sha256(read(inspectedNodePath));
  return observed;
}

function verifyWorkspace(requestedWorkspace) {
  if (
    typeof requestedWorkspace !== "string" ||
    !/^jidoka-code-local-workspace-[0-9a-f-]{36}$/.test(basename(requestedWorkspace))
  ) {
    fail("app-owned local workspace is absent");
  }
  const stat = lstatSync(requestedWorkspace);
  const workspace = realpathSync(requestedWorkspace);
  if (
    !stat.isDirectory() ||
    stat.isSymbolicLink() ||
    (stat.mode & 0o077) !== 0 ||
    (typeof process.getuid === "function" && stat.uid !== process.getuid()) ||
    !workspace.startsWith(`${realpathSync(tmpdir())}/`)
  ) {
    fail("app-owned local workspace is unsafe");
  }
  return workspace;
}

function runSync(executable, arguments_, options = {}) {
  const command = spawnSync(executable, arguments_, {
    cwd: options.cwd ?? "/",
    encoding: "utf8",
    env: options.env ?? {
      DEVELOPER_DIR: developerDirectory,
      HOME: process.env.HOME,
      PATH: `${developerDirectory}/usr/bin:/usr/bin:/bin`,
      TMPDIR: tmpdir(),
    },
    maxBuffer: maximumOutputBytes,
    stdio: options.stdio ?? ["ignore", "pipe", "pipe"],
  });
  if (command.error !== undefined) throw command.error;
  if (options.expectedStatus !== undefined) {
    if (command.status !== options.expectedStatus) {
      fail(`unexpected command status for ${basename(executable)}: ${command.status}`);
    }
  } else if (command.status !== 0) {
    fail(`command failed for ${basename(executable)}: ${command.stderr.trim()}`);
  }
  return command;
}

function git(arguments_, options = {}) {
  return runSync(gitPath, arguments_, options);
}

function writeExecutable(path, content) {
  writeFileSync(path, content, { mode: 0o700 });
  chmodSync(path, 0o700);
}

function readGit(repository, arguments_) {
  return git(["-C", repository, ...arguments_]).stdout.trim();
}

function listFiles(root) {
  const files = [];
  const visit = (path) => {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      const candidate = `${path}/${entry.name}`;
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) visit(candidate);
      if (entry.isFile()) files.push(candidate);
    }
  };
  visit(root);
  return files;
}

function assertSentinelAbsent(root, sentinel) {
  for (const path of listFiles(root)) {
    const stat = statSync(path);
    if (stat.size > maximumOutputBytes) continue;
    if (readFileSync(path).includes(Buffer.from(sentinel))) {
      fail(`synthetic credential leaked to ${basename(path)}`);
    }
  }
}

function runSecurityComposition(workspace) {
  const fixture = `${workspace}/s5`;
  const repository = `${fixture}/work`;
  const remote = `${fixture}/remote.git`;
  const markers = `${fixture}/markers`;
  mkdirSync(repository, { recursive: true, mode: 0o700 });
  mkdirSync(markers, { mode: 0o700 });
  git(["init", "--bare", remote]);
  git(["init", repository]);
  git(["-C", repository, "config", "user.name", "Jidoka Fixture"]);
  git(["-C", repository, "config", "user.email", "fixture@invalid.example"]);

  const hookPath = `${repository}/.githooks/pre-commit`;
  const helperPath = `${fixture}/credential-helper.sh`;
  const sshPath = `${fixture}/fake-ssh.sh`;
  mkdirSync(dirname(hookPath), { recursive: true, mode: 0o700 });
  writeExecutable(
    hookPath,
    `#!/bin/sh\nprintf '%s\\n' invoked >>'${markers}/hook'\nexit 42\n`,
  );
  writeExecutable(
    helperPath,
    `#!/bin/sh\nprintf '%s\\n' invoked >>'${markers}/credential-helper'\nprintf 'password=%s\\n' "\${JIDOKA_TEST_CREDENTIAL-}"\n`,
  );
  writeExecutable(
    sshPath,
    `#!/bin/sh\nprintf '%s\\n' invoked >>'${markers}/ssh'\nexit 78\n`,
  );
  writeFileSync(
    `${repository}/.gitmodules`,
    [
      '[submodule "local"]',
      "\tpath = Dependencies/local",
      "\turl = ../local-submodule.git",
      '[submodule "remote"]',
      "\tpath = Dependencies/remote",
      "\turl = ssh://fixture.invalid/remote-submodule.git",
      "",
    ].join("\n"),
  );
  writeFileSync(`${repository}/README.md`, "fixture\n");
  git(["-C", repository, "add", "README.md", ".gitmodules", ".githooks/pre-commit"]);
  git(["-C", repository, "commit", "-m", "fixture base"]);
  const headBefore = readGit(repository, ["rev-parse", "HEAD"]);

  git(["-C", repository, "config", "core.hooksPath", ".githooks"]);
  git(["-C", repository, "config", "credential.helper", `!${helperPath}`]);
  git([
    "-C",
    repository,
    "config",
    'url.ssh://fixture.invalid/.insteadOf',
    "https://fixture.invalid/",
  ]);
  git(["-C", repository, "config", "core.sshCommand", sshPath]);
  git(["-C", repository, "remote", "add", "origin", "https://fixture.invalid/repo.git"]);

  writeFileSync(`${repository}/README.md`, "fixture changed\n");
  git(["-C", repository, "add", "README.md"]);
  const commit = git(["-C", repository, "commit", "-m", "must be blocked"], {
    expectedStatus: 1,
  });
  const headAfter = readGit(repository, ["rev-parse", "HEAD"]);
  const trackedHook = readGit(repository, ["ls-files", "--error-unmatch", ".githooks/pre-commit"]);
  const localConfiguration = readGit(repository, [
    "config",
    "--local",
    "--get-regexp",
    "^(credential\\.|url\\.|core\\.sshcommand|remote\\..*\\.url)",
  ]);
  const modules = readFileSync(`${repository}/.gitmodules`, "utf8");
  const syntheticCredential = `JIDOKA_SYNTHETIC_GITHUB_${randomUUID()}`;
  assertSentinelAbsent(fixture, syntheticCredential);

  const environmentKeys = Object.keys(process.env).sort();
  if (
    environmentKeys.includes("GH_TOKEN") ||
    environmentKeys.includes("GITHUB_TOKEN") ||
    environmentKeys.includes("SSH_AUTH_SOCK") ||
    environmentKeys.some((key) => key.startsWith("GIT_CONFIG_"))
  ) {
    fail("packaged local probe inherited credential or Git override state");
  }
  if (
    !localConfiguration.includes("credential.helper") ||
    !localConfiguration.includes("url.ssh://fixture.invalid/.insteadof") ||
    !localConfiguration.includes("core.sshcommand") ||
    !localConfiguration.includes("remote.origin.url") ||
    trackedHook !== ".githooks/pre-commit" ||
    headAfter !== headBefore ||
    !existsSync(`${markers}/hook`) ||
    existsSync(`${markers}/credential-helper`) ||
    existsSync(`${markers}/ssh`) ||
    existsSync(`${remote}/receive-count`)
  ) {
    fail("composed Git security fixture did not fail closed");
  }
  if (
    !modules.includes("url = ../local-submodule.git") ||
    !modules.includes("url = ssh://fixture.invalid/remote-submodule.git")
  ) {
    fail("submodule fixture is incomplete");
  }

  return {
    schemaVersion: 1,
    mode: "security-composition",
    commitArguments: ["commit", "-m"],
    credentialHelperDetected: true,
    credentialHelperInvocations: 0,
    directRemoteExecutionAllowed: false,
    environmentKeys,
    hookBlockedCommit: commit.status !== 0,
    hookBypassArgumentPresent: false,
    hookTracked: true,
    insteadOfDetected: true,
    networkSubmoduleEscalated: true,
    localSubmoduleClassified: true,
    remoteReceiveCount: 0,
    sshCommandDetected: true,
    sshInvocations: 0,
    syntheticCredentialAbsent: true,
  };
}

function runAsync(executable, arguments_, options = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    const stdio = options.fd3 === undefined
      ? ["pipe", "pipe", "pipe"]
      : ["pipe", "pipe", "pipe", "pipe"];
    const child = spawn(executable, arguments_, {
      cwd: options.cwd ?? "/",
      env: options.env,
      stdio,
    });
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let timedOut = false;
    const append = (current, chunk) => {
      const next = Buffer.concat([current, chunk]);
      if (next.length > maximumOutputBytes) {
        child.kill("SIGKILL");
        rejectPromise(new Error("child output exceeded bound"));
      }
      return next;
    };
    child.stdout.on("data", (chunk) => {
      stdout = append(stdout, chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr = append(stderr, chunk);
    });
    child.on("error", rejectPromise);
    if (options.input === undefined) child.stdin.end();
    else child.stdin.end(options.input);
    if (options.fd3 !== undefined) child.stdio[3].end(options.fd3);
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, options.timeoutMs ?? 30_000);
    child.on("close", (status, signal) => {
      clearTimeout(timer);
      if (timedOut) {
        rejectPromise(new Error(`${basename(executable)} timed out`));
        return;
      }
      resolvePromise({
        status,
        signal,
        stdout: stdout.toString("utf8"),
        stderr: stderr.toString("utf8"),
        stdoutBuffer: stdout,
        stderrBuffer: stderr,
      });
    });
  });
}

async function runGitHTTPBackend(root, request, body) {
  const requestURL = new URL(request.url, "http://127.0.0.1");
  const result = await runAsync(
    gitHTTPBackendPath,
    [],
    {
      env: {
        CONTENT_LENGTH: String(body.length),
        DEVELOPER_DIR: developerDirectory,
        CONTENT_TYPE: request.headers["content-type"] ?? "",
        GATEWAY_INTERFACE: "CGI/1.1",
        GIT_HTTP_EXPORT_ALL: "1",
        GIT_PROJECT_ROOT: root,
        PATH: `${developerDirectory}/usr/bin:/usr/bin:/bin`,
        PATH_INFO: requestURL.pathname,
        QUERY_STRING: requestURL.searchParams.toString(),
        REMOTE_ADDR: "127.0.0.1",
        REMOTE_USER: "jidoka",
        REQUEST_METHOD: request.method,
        SERVER_NAME: "127.0.0.1",
        SERVER_PORT: "0",
        SERVER_PROTOCOL: "HTTP/1.1",
      },
      input: body,
    },
  );
  if (result.status !== 0 || result.signal !== null) {
    fail(`git-http-backend failed: ${result.stderr.trim()}`);
  }
  const output = result.stdoutBuffer;
  let separator = output.indexOf("\r\n\r\n");
  let separatorLength = 4;
  if (separator < 0) {
    separator = output.indexOf("\n\n");
    separatorLength = 2;
  }
  if (separator < 0) fail("git-http-backend emitted no CGI header boundary");
  const rawHeaders = output.subarray(0, separator).toString("utf8").split(/\r?\n/);
  const headers = {};
  let status = 200;
  for (const line of rawHeaders) {
    const colon = line.indexOf(":");
    if (colon < 1) continue;
    const name = line.slice(0, colon).trim();
    const value = line.slice(colon + 1).trim();
    if (name.toLowerCase() === "status") status = Number.parseInt(value, 10);
    else headers[name] = value;
  }
  return { status, headers, body: output.subarray(separator + separatorLength) };
}

async function startAuthenticatedGitServer(projectRoot, token, beforeReceive) {
  const counters = { authenticatedRequests: 0, receiveRequests: 0, rejectedRequests: 0 };
  const authorization = `Basic ${Buffer.from(`jidoka:${token}`).toString("base64")}`;
  const server = createServer((request, response) => {
    void (async () => {
      if (request.headers.authorization !== authorization) {
        counters.rejectedRequests += 1;
        response.writeHead(401, { "WWW-Authenticate": 'Basic realm="Jidoka Fixture"' });
        response.end();
        return;
      }
      counters.authenticatedRequests += 1;
      if (request.method === "POST" && request.url?.endsWith("/git-receive-pack")) {
        counters.receiveRequests += 1;
        await beforeReceive(counters.receiveRequests);
      }
      const chunks = [];
      let size = 0;
      for await (const chunk of request) {
        size += chunk.length;
        if (size > maximumOutputBytes) fail("Git HTTP request exceeded bound");
        chunks.push(chunk);
      }
      const backend = await runGitHTTPBackend(projectRoot, request, Buffer.concat(chunks));
      response.writeHead(backend.status, backend.headers);
      response.end(backend.body);
    })().catch((error) => {
      if (!response.headersSent) response.writeHead(500);
      response.end();
      server.emit("fixture-error", error);
    });
  });
  let fixtureError;
  server.on("fixture-error", (error) => {
    fixtureError = error;
  });
  await new Promise((resolvePromise, rejectPromise) => {
    server.once("error", rejectPromise);
    server.listen(0, "127.0.0.1", resolvePromise);
  });
  const address = server.address();
  if (address === null || typeof address === "string") fail("Git HTTP server has no TCP port");
  return {
    counters,
    port: address.port,
    assertHealthy() {
      if (fixtureError !== undefined) throw fixtureError;
    },
    async close() {
      await new Promise((resolvePromise, rejectPromise) => {
        server.close((error) => (error === undefined ? resolvePromise() : rejectPromise(error)));
      });
      if (fixtureError !== undefined) throw fixtureError;
    },
  };
}

async function runAuthenticatedGit({ repository, remoteURL, operationArguments, askpass, token }) {
  const usedPath = `${dirname(askpass)}/askpass-used-${randomUUID()}`;
  const nonce = randomUUID();
  const arguments_ = [
    "-C",
    repository,
    "-c",
    "credential.helper=",
    ...operationArguments,
  ];
  if (arguments_.some((argument) => argument.includes("force"))) {
    fail("force-class Git argument is forbidden");
  }
  const result = await runAsync(gitPath, arguments_, {
    env: {
      DEVELOPER_DIR: developerDirectory,
      GIT_ASKPASS: askpass,
      GIT_ASKPASS_REQUIRE: "force",
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_TERMINAL_PROMPT: "0",
      GIT_TRACE_PACKET: "1",
      HOME: dirname(dirname(askpass)),
      JIDOKA_ASKPASS_FD: "3",
      JIDOKA_ASKPASS_NONCE: nonce,
      JIDOKA_ASKPASS_REMOTE: remoteURL,
      JIDOKA_ASKPASS_USED: usedPath,
      PATH: `${developerDirectory}/usr/bin:/usr/bin:/bin`,
      TMPDIR: tmpdir(),
    },
    fd3: `${token}\n`,
    timeoutMs: 60_000,
  });
  return { ...result, arguments_, askpassUsed: existsSync(usedPath) };
}

async function authenticatedPush({ repository, remoteURL, refspec, askpass, token }) {
  return await runAuthenticatedGit({
    repository,
    remoteURL,
    operationArguments: ["push", "--porcelain", remoteURL, refspec],
    askpass,
    token,
  });
}

async function authenticatedReadRef({ repository, remoteURL, reference, askpass, token }) {
  const result = await runAuthenticatedGit({
    repository,
    remoteURL,
    operationArguments: ["ls-remote", "--refs", remoteURL, reference],
    askpass,
    token,
  });
  if (result.status !== 0 || result.signal !== null || !result.askpassUsed) {
    fail(`authenticated ref read failed: ${result.stderr.trim()}`);
  }
  const lines = result.stdout.trim().split("\n").filter(Boolean);
  if (lines.length !== 1) fail(`authenticated ref read cardinality differs: ${reference}`);
  const [sha, observedReference] = lines[0].split("\t");
  if (observedReference !== reference || !/^[0-9a-f]{40}$/.test(sha)) {
    fail(`authenticated ref read is malformed: ${reference}`);
  }
  return { ...result, sha };
}

async function runGitTransport(workspace) {
  const fixture = `${workspace}/s6`;
  const repositories = `${fixture}/repositories`;
  const repository = `${fixture}/work`;
  const remote = `${repositories}/repo.git`;
  const hookLog = `${fixture}/receive.log`;
  const injectMarker = `${fixture}/inject-race`;
  const askpass = `${fixture}/askpass.sh`;
  mkdirSync(repositories, { recursive: true, mode: 0o700 });
  mkdirSync(repository, { mode: 0o700 });
  git(["init", "--bare", remote]);
  git(["init", repository]);
  git(["-C", repository, "config", "user.name", "Jidoka Fixture"]);
  git(["-C", repository, "config", "user.email", "fixture@invalid.example"]);
  writeFileSync(`${repository}/fixture.txt`, "base\n");
  git(["-C", repository, "add", "fixture.txt"]);
  git(["-C", repository, "commit", "-m", "base"]);
  const baseSHA = readGit(repository, ["rev-parse", "HEAD"]);
  writeFileSync(`${repository}/fixture.txt`, "exact\n");
  git(["-C", repository, "commit", "-am", "exact"]);
  const exactSHA = readGit(repository, ["rev-parse", "HEAD"]);
  git(["-C", repository, "push", remote, `${baseSHA}:refs/heads/main`]);
  git(["--git-dir", remote, "config", "http.receivepack", "true"]);

  writeExecutable(
    `${remote}/hooks/pre-receive`,
    [
      "#!/bin/sh",
      "set -eu",
      "while read old new ref",
      "do",
      `  printf '%s %s %s\\n' "$old" "$new" "$ref" >>'${hookLog}'`,
      "done",
      "exit 0",
      "",
    ].join("\n"),
  );

  const token = `JIDOKA_ASKPASS_${randomUUID()}`;
  const server = await startAuthenticatedGitServer(repositories, token, async () => {
    if (existsSync(injectMarker)) {
      git([
        "--git-dir",
        remote,
        "update-ref",
        "refs/heads/agent/issue-3-race",
        baseSHA,
        zeroSHA,
      ]);
    }
  });
  const remoteURL = `http://jidoka@127.0.0.1:${server.port}/repo.git`;
  writeExecutable(
    askpass,
    [
      "#!/bin/sh",
      "set -eu",
      "case \"$1\" in",
      `  *Password*127.0.0.1:${server.port}*) ;;`,
      "  *) exit 64 ;;",
      "esac",
      `test "\${JIDOKA_ASKPASS_REMOTE-}" = '${remoteURL}'`,
      "test -n \"${JIDOKA_ASKPASS_NONCE-}\"",
      "mkdir \"${JIDOKA_ASKPASS_USED:?}\" 2>/dev/null || exit 65",
      "IFS= read -r secret <&${JIDOKA_ASKPASS_FD:?}",
      "printf '%s\\n' \"$secret\"",
      "",
    ].join("\n"),
  );

  let create;
  let createRead;
  let divergentRead;
  let race;
  let raceRead;
  try {
    create = await authenticatedPush({
      repository,
      remoteURL,
      refspec: `${exactSHA}:refs/heads/agent/issue-1-fixture`,
      askpass,
      token,
    });
    server.assertHealthy();
    if (create.status !== 0 || create.signal !== null || !create.askpassUsed) {
      fail(`authenticated exact create failed: ${create.stderr.trim()}`);
    }
    createRead = await authenticatedReadRef({
      repository,
      remoteURL,
      reference: "refs/heads/agent/issue-1-fixture",
      askpass,
      token,
    });
    const createdSHA = createRead.sha;
    if (createdSHA !== exactSHA) fail("exact create read-back differs");

    const sameSHAOutcome = createdSHA === exactSHA ? "attributable effect" : "escalation";
    git([
      "--git-dir",
      remote,
      "update-ref",
      "refs/heads/agent/issue-2-divergent",
      baseSHA,
      zeroSHA,
    ]);
    divergentRead = await authenticatedReadRef({
      repository,
      remoteURL,
      reference: "refs/heads/agent/issue-2-divergent",
      askpass,
      token,
    });
    const divergentSHA = divergentRead.sha;
    const divergentOutcome = divergentSHA === exactSHA ? "attributable effect" : "escalation";

    writeFileSync(injectMarker, "inject\n", { mode: 0o600 });
    race = await authenticatedPush({
      repository,
      remoteURL,
      refspec: `${exactSHA}:refs/heads/agent/issue-3-race`,
      askpass,
      token,
    });
    server.assertHealthy();
    raceRead = await authenticatedReadRef({
      repository,
      remoteURL,
      reference: "refs/heads/agent/issue-3-race",
      askpass,
      token,
    });
    const raceSHA = raceRead.sha;
    if (race.status === 0 || raceSHA !== baseSHA || !race.askpassUsed) {
      fail("create-only race was not rejected without advancing the ref");
    }
    const createPacket = new RegExp(`${zeroSHA} ${exactSHA} refs/heads/agent/issue-1-fixture`);
    const racePacket = new RegExp(`${zeroSHA} ${exactSHA} refs/heads/agent/issue-3-race`);
    if (!createPacket.test(create.stderr) || !racePacket.test(race.stderr)) {
      fail("Git packet trace did not prove expected-old zero CAS commands");
    }
    if (server.counters.receiveRequests !== 2) fail("Git receive request count differs from two");
    assertSentinelAbsent(fixture, token);
    if (
      [create, createRead, divergentRead, race, raceRead].some((command) =>
        command.arguments_.some((argument) => argument.includes(token)),
      )
    ) {
      fail("synthetic token entered Git argv");
    }
    return {
      schemaVersion: 1,
      mode: "git-transport",
      askpassInvocations: 5,
      askpassOneShot: true,
      authenticatedRequests: server.counters.authenticatedRequests,
      baseSHA,
      createExpectedOld: zeroSHA,
      createPacketExpectedOldObserved: true,
      createReadBackSHA: createdSHA,
      createStatus: "created",
      divergentReadBackSHA: divergentSHA,
      divergentSHAOutcome: divergentOutcome,
      exactSHA,
      forceClassArguments: false,
      raceActorInjectionPoint: "after-advertisement-before-receive",
      raceExpectedOld: zeroSHA,
      racePacketExpectedOldObserved: true,
      raceReadBackSHA: raceSHA,
      raceRejected: true,
      receiveRequests: server.counters.receiveRequests,
      rejectedAuthenticationRequests: server.counters.rejectedRequests,
      sameSHAOutcome,
      syntheticTokenAbsentFromArtifactsAndArgv: true,
    };
  } finally {
    await server.close();
  }
}

const mutationOperations = [
  { name: "bootstrap-label", policy: "unique" },
  { name: "create-marker-comment", policy: "create" },
  { name: "workflow-labels", policy: "idempotent" },
  { name: "claim-issue", policy: "create" },
  { name: "publish-branch", policy: "cas" },
  { name: "create-pr", policy: "create" },
  { name: "pr-issue-label", policy: "idempotent" },
  { name: "link-pr", policy: "create" },
  { name: "complex-plan", policy: "create" },
  { name: "block-issue", policy: "create" },
];
const crashWindows = [
  "prepared",
  "before-socket-write",
  "after-write-before-response",
  "after-2xx-before-commit",
  "during-read-back",
  "after-read-back-before-transition",
];
const visibilityScenarios = ["immediate", "after-31-seconds"];

class StatefulGitHubFixture {
  constructor() {
    this.effects = new Map();
    this.sendCount = 0;
    this.duplicateCreateCount = 0;
  }

  send(key, visibleAt) {
    this.sendCount += 1;
    if (this.effects.has(key)) this.duplicateCreateCount += 1;
    else this.effects.set(key, { visibleAt });
  }

  read(key, atSecond) {
    const effect = this.effects.get(key);
    return effect !== undefined && effect.visibleAt <= atSecond;
  }

  snapshot() {
    return JSON.stringify({
      duplicateCreateCount: this.duplicateCreateCount,
      effects: [...this.effects.entries()],
      sendCount: this.sendCount,
    });
  }

  static restore(snapshot) {
    const value = JSON.parse(snapshot);
    const fixture = new StatefulGitHubFixture();
    fixture.duplicateCreateCount = value.duplicateCreateCount;
    fixture.effects = new Map(value.effects);
    fixture.sendCount = value.sendCount;
    return fixture;
  }
}

function reconcileMutation(operation, crashWindow, visibility) {
  const key = `${operation.name}:${crashWindow}:${visibility}`;
  const service = new StatefulGitHubFixture();
  const intent = {
    key,
    operation: operation.name,
    state: crashWindow === "prepared" ? "prepared" : "sendStarted",
  };
  if (!["prepared", "before-socket-write"].includes(crashWindow)) {
    service.send(key, visibility === "immediate" ? 0 : 31);
  }

  const recoveredService = StatefulGitHubFixture.restore(service.snapshot());
  let attributable = false;
  if (crashWindow === "after-read-back-before-transition" && visibility === "immediate") {
    intent.readBackEvidence = true;
    attributable = true;
  } else {
    for (const second of [1, 2, 5, 10, 30]) {
      if (recoveredService.read(key, second)) {
        attributable = true;
        intent.readBackEvidence = true;
        break;
      }
    }
  }

  let outcome;
  let disposition;
  if (attributable) {
    outcome = "attributable effect";
    disposition = "attributed";
  } else if (["prepared", "before-socket-write"].includes(crashWindow)) {
    outcome = "safe retry";
    disposition = "retryAllowed";
  } else if (["unique", "idempotent", "cas"].includes(operation.policy)) {
    outcome = "safe retry";
    disposition = "retryAllowed";
  } else {
    outcome = "escalation";
    disposition = "ambiguous";
  }

  const rediscovered = ["attributed", "ambiguous", "inFlight"].includes(disposition);
  const lateAttribution =
    disposition === "ambiguous" && recoveredService.read(key, 31) && recoveredService.sendCount === 1;
  if (rediscovered && disposition === "ambiguous") {
    // Discovery is suppressed. Only this read-only late check is permitted.
    intent.state = lateAttribution ? "attributed" : "escalated";
  }
  return {
    attributable,
    disposition,
    lateAttribution,
    outcome,
    rediscoverySuppressed: rediscovered,
    secondCreates: recoveredService.duplicateCreateCount,
    sends: recoveredService.sendCount,
  };
}

function runMutationRecovery() {
  const outcomes = { "safe retry": 0, "attributable effect": 0, escalation: 0 };
  let cases = 0;
  let sends = 0;
  let secondCreates = 0;
  let lateAttributions = 0;
  let suppressedRediscoveries = 0;
  for (const operation of mutationOperations) {
    for (const crashWindow of crashWindows) {
      for (const visibility of visibilityScenarios) {
        const result = reconcileMutation(operation, crashWindow, visibility);
        if (!Object.hasOwn(outcomes, result.outcome)) fail("mutation outcome is not total");
        outcomes[result.outcome] += 1;
        cases += 1;
        sends += result.sends;
        secondCreates += result.secondCreates;
        if (result.lateAttribution) lateAttributions += 1;
        if (result.rediscoverySuppressed) suppressedRediscoveries += 1;
        if (
          operation.policy === "create" &&
          visibility === "after-31-seconds" &&
          !["prepared", "before-socket-write"].includes(crashWindow) &&
          result.outcome !== "escalation"
        ) {
          fail("unknown content create was not escalated");
        }
        if (result.outcome === "attributable effect" && !result.attributable) {
          fail("mutation reached success without attribution evidence");
        }
      }
    }
  }
  if (cases !== 120 || secondCreates !== 0) fail("mutation fault matrix is incomplete");
  return {
    schemaVersion: 1,
    mode: "mutation-recovery",
    cases,
    crashWindowNames: crashWindows,
    crashWindows: crashWindows.length,
    delayedVisibilitySeconds: 31,
    dispositionSuppressesRediscovery: suppressedRediscoveries > 0,
    lateAttributions,
    operationNames: mutationOperations.map((operation) => operation.name),
    operations: mutationOperations.length,
    outcomes,
    readBackScheduleSeconds: [1, 2, 5, 10, 30],
    secondCreateAttempts: secondCreates,
    sends,
    succeededWithoutAttribution: 0,
    suppressedRediscoveries,
    unknownCommentAbsent: "escalation",
    unknownPRAbsent: "escalation",
    visibilityScenarios,
  };
}

export async function buildLocalSpikeReport(mode, workspace, dependencies = {}) {
  const inspectRuntime = dependencies.attestSystemRuntime ?? attestSystemRuntime;
  const security = dependencies.runSecurityComposition ?? runSecurityComposition;
  const gitTransport = dependencies.runGitTransport ?? runGitTransport;
  const mutationRecovery = dependencies.runMutationRecovery ?? runMutationRecovery;
  const systemRuntimeSHA256 = inspectRuntime();
  let report;
  if (mode === "security") report = security(workspace);
  if (mode === "git-transport") report = await gitTransport(workspace);
  if (mode === "mutation-recovery") report = mutationRecovery();
  report.systemRuntimeSHA256 = systemRuntimeSHA256;
  return report;
}

async function main() {
  const mode = process.argv[2];
  if (!['security', 'git-transport', 'mutation-recovery'].includes(mode)) {
    fail("unknown local spike mode");
  }
  if (process.argv.length !== 4) fail("local spike requires one app-owned workspace");
  const workspace = verifyWorkspace(process.argv[3]);
  const report = await buildLocalSpikeReport(mode, workspace);
  process.stdout.write(`${JSON.stringify(report)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`local spike failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}
