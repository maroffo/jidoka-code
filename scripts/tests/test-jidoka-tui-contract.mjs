#!/usr/bin/env node

import assert from "node:assert/strict";
import {
  chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import {
  canonicalJSON,
  createPrivateJSONFile,
  currentRunMessages,
  loadTUIRuntimeConfiguration,
  persistRuntimeFailure,
  persistTerminalResult,
  pinnedPromptAction,
  readPinnedPrompt,
  readPreparedTerminalResult,
  recordSessionIdentity,
  recoverExecutedTerminalDetails,
  sha256,
  waitForResultAcknowledgement,
} from "../../Resources/Pi/runtime/jidoka-tui-contract.mjs";

function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "jidoka-tui-contract.")));
  chmodSync(root, 0o700);
  const channelDirectory = join(root, "channel");
  const sessionDirectory = join(root, "sessions");
  const workspaceRoot = join(root, "workspace");
  for (const path of [channelDirectory, sessionDirectory, workspaceRoot]) mkdirSync(path, { mode: 0o700 });
  const promptPath = join(channelDirectory, "prompt.txt");
  const prompt = Buffer.from("Pinned prompt.\n", "utf8");
  writeFileSync(promptPath, prompt, { mode: 0o600, flag: "wx" });
  const configuration = {
    acknowledgementTimeoutMilliseconds: 2_000,
    channelDirectory,
    expectedCommands: [
      { name: "jidoka-code-preflight", origin: "top-level", path: "/fixture/runtime.ts", scope: "temporary", source: "extension" },
      { name: "skill:jidoka-code-issue-triage", origin: "top-level", path: "/fixture/SKILL.md", scope: "temporary", source: "skill" },
      { name: "llama", origin: "top-level", path: "<inline:llama.cpp>", scope: "temporary", source: "extension" },
    ],
    expectedSessionID: null,
    launchMode: "fresh",
    modelID: "fixture",
    modelProvider: "jidoka-fixture",
    promptPath,
    promptSHA256: sha256(prompt),
    resumeBoundarySHA256: null,
    role: "triage",
    runID: "run-h3-fixture",
    runNonce: "b".repeat(64),
    schemaVersion: 3,
    sessionDirectory,
    sessionName: "jidoka-run-h3-fixture",
    thinkingLevel: "off",
    workflow: "issue-triage",
    workspaceRoot,
  };
  const configurationPath = join(channelDirectory, "tui-configuration.json");
  writeFileSync(configurationPath, `${canonicalJSON(configuration)}\n`, { mode: 0o600, flag: "wx" });
  const details = {
    approvedCommandIDs: [],
    artifactSHA256: "a".repeat(64),
    nonce: "workflow-nonce",
    payload: { verdict: "human" },
    resultSequence: 1,
    role: "triage",
    schemaVersion: 1,
    workflow: "issue-triage",
  };
  return { channelDirectory, configuration, configurationPath, details, prompt };
}

test("strict private configuration pins prompt and runtime identity", () => {
  const value = fixture();
  assert.deepEqual(loadTUIRuntimeConfiguration(value.configurationPath), value.configuration);
  const prompt = readPinnedPrompt(value.configuration);
  assert.equal(prompt, value.prompt.toString("utf8"));
  assert.equal(pinnedPromptAction(value.configuration, prompt, []), "send");
  assert.throws(
    () => pinnedPromptAction(
      { ...value.configuration, launchMode: "resume" },
      prompt,
      [prompt],
    ),
    /pre-result-recovery-required/,
  );

  const unsafe = { ...value.configuration, extra: true };
  const unsafePath = join(resolve(value.channelDirectory, ".."), "unsafe.json");
  writeFileSync(unsafePath, `${canonicalJSON(unsafe)}\n`, { mode: 0o600 });
  assert.throws(() => loadTUIRuntimeConfiguration(unsafePath), /configuration-schema/);
});

test("terminal result is create-only, canonical, and idempotent", () => {
  const value = fixture();
  const first = persistTerminalResult(value.configuration, value.details);
  const second = persistTerminalResult(value.configuration, value.details);
  assert.equal(first.resultSHA256, second.resultSHA256);
  assert.equal(
    first.envelope.sessionBoundarySHA256,
    sha256(Buffer.from(canonicalJSON(value.details), "utf8")),
  );
  assert.deepEqual(readPreparedTerminalResult(value.configuration), first);
  assert.equal(readFileSync(first.path, "utf8"), `${canonicalJSON(first.envelope)}\n`);

  assert.throws(
    () => persistTerminalResult(value.configuration, { ...value.details, payload: { verdict: "ready" } }),
    /result\.json-divergent/,
  );
});

test("complete prepared result recovers, partial staging is ignored, and partial prepared fails closed", () => {
  const recovered = fixture();
  const expected = persistTerminalResult(recovered.configuration, recovered.details);
  const bytes = readFileSync(expected.path);

  const second = fixture();
  writeFileSync(join(second.channelDirectory, ".result.json.prepared"), bytes, { mode: 0o600, flag: "wx" });
  const finalized = persistTerminalResult(second.configuration, second.details);
  assert.equal(readFileSync(finalized.path, "utf8"), bytes.toString("utf8"));

  const staged = fixture();
  writeFileSync(
    join(staged.channelDirectory, "..result.json.prepared.crash.staging"),
    "{",
    { mode: 0o600, flag: "wx" },
  );
  assert.equal(
    persistTerminalResult(staged.configuration, staged.details).envelope.runID,
    staged.configuration.runID,
  );

  const partial = fixture();
  writeFileSync(join(partial.channelDirectory, ".result.json.prepared"), "{", { mode: 0o600, flag: "wx" });
  assert.throws(() => persistTerminalResult(partial.configuration, partial.details), /prepared-divergent/);
});

test("boundaryless resume requires an existing exact same-run session proof", () => {
  const missing = fixture();
  const sessionID = "019fe66a-08e5-7566-be79-08c7cda1d7bf";
  const sessionFile = join(missing.configuration.sessionDirectory, `${sessionID}.jsonl`);
  const resumed = {
    ...missing.configuration,
    expectedSessionID: sessionID,
    launchMode: "resume",
    resumeBoundarySHA256: null,
  };
  assert.throws(
    () => recordSessionIdentity(resumed, sessionID, sessionFile),
    /same-run-session-proof-required/,
  );

  const proven = fixture();
  const provenSessionFile = join(proven.configuration.sessionDirectory, `${sessionID}.jsonl`);
  const identity = recordSessionIdentity(proven.configuration, sessionID, provenSessionFile);
  const provenResume = {
    ...proven.configuration,
    expectedSessionID: sessionID,
    launchMode: "resume",
    resumeBoundarySHA256: null,
  };
  assert.deepEqual(
    recordSessionIdentity(provenResume, sessionID, provenSessionFile),
    identity,
  );
  assert.throws(
    () => recordSessionIdentity(
      { ...provenResume, runID: "run-new-logical-round", runNonce: "e".repeat(64) },
      sessionID,
      provenSessionFile,
    ),
    /same-run-session-proof-mismatch/,
  );

  const crossRun = fixture();
  const crossRunSessionFile = join(crossRun.configuration.sessionDirectory, `${sessionID}.jsonl`);
  const boundary = "a".repeat(64);
  const crossRunResume = {
    ...crossRun.configuration,
    expectedSessionID: sessionID,
    launchMode: "resume",
    resumeBoundarySHA256: boundary,
  };
  const crossRunIdentity = recordSessionIdentity(
    crossRunResume,
    sessionID,
    crossRunSessionFile,
  );
  assert.equal(crossRunIdentity.originLaunchMode, "resume");
  assert.equal(crossRunIdentity.originResumeBoundarySHA256, boundary);
  assert.throws(
    () => recordSessionIdentity(
      { ...crossRunResume, resumeBoundarySHA256: null },
      sessionID,
      crossRunSessionFile,
    ),
    /same-run-session-proof-origin/,
  );
});

test("resume requires a causally paired successful terminal tool result", () => {
  const value = fixture();
  const { resultSequence: _resultSequence, ...argumentsValue } = value.details;
  const assistant = {
    role: "assistant",
    content: [{
      type: "toolCall", id: "result-call", name: "jidoka_code_result", arguments: argumentsValue,
    }],
  };
  assert.throws(
    () => recoverExecutedTerminalDetails([assistant]),
    /terminal-result-execution-unknown/,
  );
  const toolResult = {
    role: "toolResult", toolCallId: "result-call", toolName: "jidoka_code_result",
    isError: false, details: value.details,
  };
  assert.deepEqual(
    recoverExecutedTerminalDetails([assistant, toolResult]),
    value.details,
  );
  assert.throws(
    () => recoverExecutedTerminalDetails([
      assistant, { ...toolResult, toolCallId: "different-call" },
    ]),
    /unpaired-recorded-terminal-result/,
  );
});

test("cross-run resume requires an exact settled terminal boundary", () => {
  const value = fixture();
  const priorDetails = {
    ...value.details,
    artifactSHA256: "c".repeat(64),
    nonce: "prior-workflow-nonce",
  };
  const priorArguments = { ...priorDetails };
  delete priorArguments.resultSequence;
  const priorMessages = [
    { role: "user", content: "Prior pinned prompt.\n" },
    {
      role: "assistant",
      content: [{
        type: "toolCall", id: "prior-result", name: "jidoka_code_result",
        arguments: priorArguments,
      }],
    },
    {
      role: "toolResult", toolCallId: "prior-result", toolName: "jidoka_code_result",
      isError: false, details: priorDetails,
    },
  ];
  const boundary = sha256(Buffer.from(canonicalJSON(priorDetails), "utf8"));
  const resumed = {
    ...value.configuration,
    expectedSessionID: "019fe66a-08e5-7566-be79-08c7cda1d7bf",
    launchMode: "resume",
    resumeBoundarySHA256: boundary,
  };
  assert.deepEqual(currentRunMessages(resumed, priorMessages), []);
  assert.equal(
    pinnedPromptAction(resumed, value.prompt.toString("utf8"), []),
    "send",
  );
  assert.throws(
    () => currentRunMessages(
      { ...resumed, resumeBoundarySHA256: "d".repeat(64) },
      priorMessages,
    ),
    /resume-boundary-mismatch/,
  );

  const currentArguments = { ...value.details };
  delete currentArguments.resultSequence;
  const currentMessages = [
    ...priorMessages,
    { role: "user", content: value.prompt.toString("utf8") },
    {
      role: "assistant",
      content: [{
        type: "toolCall", id: "current-result", name: "jidoka_code_result",
        arguments: currentArguments,
      }],
    },
    {
      role: "toolResult", toolCallId: "current-result", toolName: "jidoka_code_result",
      isError: false, details: value.details,
    },
  ];
  assert.deepEqual(
    recoverExecutedTerminalDetails(currentRunMessages(resumed, currentMessages)),
    value.details,
  );
  assert.throws(
    () => currentRunMessages(
      { ...resumed, resumeBoundarySHA256: null },
      currentMessages,
    ),
    /resume-boundary-required/,
  );
});

test("planning and orchestration writer rounds resume after the exact prior boundary", () => {
  for (const workflow of ["planning", "orchestration"]) {
    const value = fixture();
    const details = {
      ...value.details,
      nonce: `${workflow}-round-1`,
      payload: { status: "settled" },
      role: "writer",
      workflow,
    };
    const argumentsValue = { ...details };
    delete argumentsValue.resultSequence;
    const history = [
      { role: "user", content: `${workflow} round 1` },
      {
        role: "assistant",
        content: [{
          type: "toolCall", id: `${workflow}-result`, name: "jidoka_code_result",
          arguments: argumentsValue,
        }],
      },
      {
        role: "toolResult", toolCallId: `${workflow}-result`,
        toolName: "jidoka_code_result", isError: false, details,
      },
    ];
    const resumed = {
      ...value.configuration,
      expectedSessionID: "019fe66a-08e5-7566-be79-08c7cda1d7bf",
      launchMode: "resume",
      resumeBoundarySHA256: sha256(Buffer.from(canonicalJSON(details), "utf8")),
      role: "writer",
      workflow,
    };
    assert.deepEqual(currentRunMessages(resumed, history), []);
    assert.equal(
      pinnedPromptAction(resumed, value.prompt.toString("utf8"), []),
      "send",
    );
  }
});

test("runtime failure is create-only and bound to the logical run", () => {
  const value = fixture();
  const path = persistRuntimeFailure(value.configuration, "COMMAND_PROVENANCE_MISMATCH");
  assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), {
    code: "COMMAND_PROVENANCE_MISMATCH",
    runID: value.configuration.runID,
    runNonce: value.configuration.runNonce,
    schemaVersion: 1,
    status: "failed",
  });
  assert.equal(
    persistRuntimeFailure(value.configuration, "COMMAND_PROVENANCE_MISMATCH"),
    path,
  );
  assert.throws(
    () => persistRuntimeFailure(value.configuration, "MODEL_MISMATCH"),
    /runtime-failure.json-divergent/,
  );
});

test("acknowledgement binds run identity and result digest", async () => {
  const value = fixture();
  const prepared = persistTerminalResult(value.configuration, value.details);
  const acknowledgement = {
    resultSHA256: prepared.resultSHA256,
    runID: value.configuration.runID,
    runNonce: value.configuration.runNonce,
    schemaVersion: 1,
    status: "accepted",
  };
  createPrivateJSONFile(
    value.channelDirectory,
    "acknowledgement.json",
    ".acknowledgement.json.prepared",
    acknowledgement,
  );
  await waitForResultAcknowledgement(value.configuration, prepared.resultSHA256);

  const divergent = fixture();
  const divergentResult = persistTerminalResult(divergent.configuration, divergent.details);
  createPrivateJSONFile(
    divergent.channelDirectory,
    "acknowledgement.json",
    ".acknowledgement.json.prepared",
    {
      ...acknowledgement,
      resultSHA256: "c".repeat(64),
      runID: divergent.configuration.runID,
      runNonce: divergent.configuration.runNonce,
    },
  );
  await assert.rejects(
    waitForResultAcknowledgement(divergent.configuration, divergentResult.resultSHA256),
    /accepted-identity/,
  );

  const interrupted = fixture();
  const interruptedResult = persistTerminalResult(interrupted.configuration, interrupted.details);
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    waitForResultAcknowledgement(
      interrupted.configuration,
      interruptedResult.resultSHA256,
      controller.signal,
    ),
    /acknowledgement-aborted/,
  );
});

test("symlinked configuration is rejected", () => {
  const value = fixture();
  const link = join(resolve(value.channelDirectory, ".."), "configuration-link.json");
  symlinkSync(value.configurationPath, link);
  assert.throws(() => loadTUIRuntimeConfiguration(link), /unsafe-configuration-file/);
});
