#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const releaseRuntimeRoot = realpathSync(process.env.JIDOKA_RELEASE_RUNTIME_ROOT ?? "");
const nodePath = realpathSync(process.execPath);
const typeboxPath = `${releaseRuntimeRoot}/pi/node_modules/typebox`;
if (nodePath !== `${releaseRuntimeRoot}/node/bin/node`) {
  throw new Error("Node is outside the attested release runtime");
}
const expectedRuntimeSHA256 =
  "b6bae1cb282d95b3c1a3e6e4f37c5b967aa5bd3885ec3050c5d7bddb72b4a19b";

function fail(message) {
  throw new Error(message);
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function runChild(runtimePath, markerPath) {
  const loaded = await import(pathToFileURL(runtimePath).href);
  let providerHook;
  const pi = {
    on(event, handler) {
      if (event === "before_provider_request") providerHook = handler;
    },
    registerCommand() {},
    registerTool() {},
  };
  loaded.default(pi);
  if (typeof providerHook !== "function") fail("provider hook was not registered");
  const simulatedProviderRequest = async () => {
    await providerHook();
    writeFileSync(markerPath, "provider-request\n", { flag: "a" });
  };
  await simulatedProviderRequest();
  await simulatedProviderRequest();
  writeFileSync(markerPath, "second-request-returned\n", { flag: "a" });
}

function verifyPrivateDirectory(path) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0) {
    fail(`unsafe test directory: ${basename(path)}`);
  }
}

function runParent(sourceRuntimePath) {
  const sourceStat = lstatSync(sourceRuntimePath);
  if (!sourceStat.isFile() || sourceStat.isSymbolicLink()) {
    fail("runtime source is not a regular file");
  }
  if (sha256(readFileSync(sourceRuntimePath)) !== expectedRuntimeSHA256) {
    fail("runtime source digest drift");
  }

  const root = mkdtempSync(`${tmpdir()}/jidoka-provider-gate-`);
  chmodSync(root, 0o700);
  try {
    verifyPrivateDirectory(root);
    const runtimePath = `${root}/jidoka-runtime.ts`;
    copyFileSync(sourceRuntimePath, runtimePath);
    chmodSync(runtimePath, 0o600);
    mkdirSync(`${root}/node_modules`, { mode: 0o700 });
    symlinkSync(typeboxPath, `${root}/node_modules/typebox`);

    const home = `${realpathSync(root)}/home`;
    const ledgerParent = `${home}/Library/Application Support/JidokaCode/Consent`;
    mkdirSync(ledgerParent, { recursive: true, mode: 0o700 });
    for (const path of [home, `${home}/Library`, `${home}/Library/Application Support`, `${home}/Library/Application Support/JidokaCode`, ledgerParent]) {
      chmodSync(path, 0o700);
    }
    const ledgerPath = `${ledgerParent}/provider-call-ledger.json`;
    const attemptId = "s4-gate-preflight";
    const ledger = {
      schemaVersion: 1,
      authorizedCallCap: 19,
      model: "openai-codex/gpt-5.6-sol:max",
      retry: false,
      attempts: [
        {
          attemptId,
          fixtureId: "gate-preflight",
          profile: "review",
          workflow: "S4",
          state: "reserved",
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
        },
      ],
    };
    writeFileSync(ledgerPath, `${JSON.stringify(ledger)}\n`, { mode: 0o600 });
    chmodSync(ledgerPath, 0o600);
    const markerPath = `${root}/provider-markers.txt`;
    const child = spawnSync(nodePath, [resolve(process.argv[1]), "child", runtimePath, markerPath], {
      cwd: "/",
      encoding: "utf8",
      env: {
        HOME: home,
        JIDOKA_PROVIDER_ATTEMPT_ID: attemptId,
        JIDOKA_PROVIDER_GATE: "1",
        JIDOKA_PROVIDER_LEDGER: ledgerPath,
        JIDOKA_RELEASE_RUNTIME_ROOT: releaseRuntimeRoot,
        PATH: "/usr/bin:/bin",
        TMPDIR: tmpdir(),
      },
      timeout: 10_000,
    });
    if (
      child.status !== 86 ||
      child.signal !== null ||
      child.stdout !== "" ||
      child.stderr !== "JIDOKA_PROVIDER_GATE_BLOCKED:multiple-provider-requests\n"
    ) {
      fail("provider gate child did not fail closed on request two");
    }
    const persisted = JSON.parse(readFileSync(ledgerPath, "utf8"));
    const attempt = persisted.attempts?.[0];
    const markers = readFileSync(markerPath, "utf8");
    if (
      persisted.attempts?.length !== 1 ||
      attempt?.attemptId !== attemptId ||
      attempt?.state !== "issued" ||
      attempt?.providerRequestCount !== 1 ||
      markers !== "provider-request\n" ||
      existsSync(`${ledgerPath}.lock`)
    ) {
      fail("provider gate state or request cardinality is invalid");
    }
    return {
      schemaVersion: 1,
      firstRequestIssued: true,
      lockCleanup: true,
      networkProviderCalls: 0,
      secondRequestBlocked: true,
      simulatedProviderRequestsReached: 1,
      terminationStatus: child.status,
    };
  } finally {
    if (existsSync(root)) {
      verifyPrivateDirectory(root);
      rmSync(root, { recursive: true });
    }
  }
}

if (process.argv[2] === "child") {
  if (process.argv.length !== 5) fail("invalid child arguments");
  await runChild(process.argv[3], process.argv[4]);
} else {
  if (process.argv.length !== 3) fail("usage: pi-provider-gate-probe.mjs RUNTIME");
  process.stdout.write(`${JSON.stringify(runParent(process.argv[2]))}\n`);
}
