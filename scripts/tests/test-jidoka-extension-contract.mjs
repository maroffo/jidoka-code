#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  cpSync,
  existsSync,
  linkSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildWorkspaceQuery,
  editWorkspaceFile,
  expectedActiveTools,
  jidokaExtensionContract,
  loadRuntimeConfiguration,
  readWorkspaceFile,
  runWorkspaceQuery,
  validateBuiltInToolCall,
  validateTerminalResult,
  writeWorkspaceFile,
} from "../../Resources/Pi/runtime/jidoka-extension-contract.mjs";

const root = realpathSync(fileURLToPath(new URL("../../Resources/Pi", import.meta.url)));
const temporary = realpathSync(mkdtempSync(`${tmpdir()}/jidoka-extension-contract-`));
chmodSync(temporary, 0o700);
const workspace = resolve(temporary, "workspace");
mkdirSync(resolve(workspace, "Sources/Feature"), { recursive: true, mode: 0o700 });
execFileSync("/usr/bin/git", ["init", "--quiet", workspace], {
  env: {
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    HOME: temporary,
    PATH: "/usr/bin:/bin",
  },
});
writeFileSync(resolve(workspace, "README.md"), "fixture\n", { mode: 0o600 });
writeFileSync(resolve(workspace, "Sources/Feature/Value.swift"), "let value = 1\n", {
  mode: 0o600,
});

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function writeConfiguration(
  directory,
  {
    resourceRoot = root,
    workflow = "planning",
    role = "writer",
    toolPolicy = "writer",
    allowedWritePaths = ["Sources/Feature"],
    allowedCommandIDs = ["check", "test"],
  } = {},
) {
  const manifestPath = resolve(resourceRoot, "workflow-resources.json");
  const path = resolve(directory, `configuration-${createHash("sha256").update(String(Math.random())).digest("hex")}.json`);
  const configuration = {
    allowedCommandIDs,
    allowedWritePaths,
    artifactSHA256: "a".repeat(64),
    contractVersion: "1",
    nonce: "nonce-12345678",
    resourceManifestPath: manifestPath,
    resourceManifestSHA256: sha256(readFileSync(manifestPath)),
    resourceRoot,
    role,
    schemaVersion: 1,
    toolPolicy,
    workflow,
    workspaceRoot: workspace,
  };
  writeFileSync(path, `${JSON.stringify(configuration)}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
  return path;
}

try {
  const configuration = loadRuntimeConfiguration(writeConfiguration(temporary));
  assert.equal(configuration.workflow, "planning");
  assert.deepEqual(expectedActiveTools(configuration), [
    "jidoka_code_edit",
    "jidoka_code_preflight",
    "jidoka_code_read",
    "jidoka_code_result",
    "jidoka_code_workspace_query",
    "jidoka_code_write",
  ]);
  assert.equal(expectedActiveTools(configuration).includes("bash"), false);
  assert.equal(expectedActiveTools(configuration).includes("gh"), false);
  assert.deepEqual(jidokaExtensionContract.workspaceOperations, [
    "status",
    "diff",
    "log",
    "show",
    "search",
    "list",
  ]);

  validateBuiltInToolCall(configuration, {
    toolName: "jidoka_code_read",
    input: { path: "README.md" },
  });
  validateBuiltInToolCall(configuration, {
    toolName: "jidoka_code_write",
    input: { path: "Sources/Feature/New.swift" },
  });
  assert.throws(
    () => validateBuiltInToolCall(configuration, {
      toolName: "jidoka_code_write",
      input: { path: "README.md" },
    }),
    /write-path-not-approved/,
  );
  assert.throws(
    () => validateBuiltInToolCall(configuration, {
      toolName: "jidoka_code_read",
      input: { path: "../outside" },
    }),
    /tool-path-escape/,
  );
  for (const path of [".GIT/config", ".GiT/hooks/pre-commit", ".PI/settings.json"]) {
    assert.throws(
      () => validateBuiltInToolCall(configuration, {
        toolName: "jidoka_code_read",
        input: { path },
      }),
      /forbidden-tool-path/,
    );
  }

  const readResult = readWorkspaceFile(configuration, { path: "README.md" });
  assert.equal(readResult.content, "fixture\n");
  const writeResult = writeWorkspaceFile(configuration, {
    path: "Sources/Feature/New.swift",
    content: "let newValue = 2\n",
  });
  assert.equal(writeResult.outputSHA256, sha256("let newValue = 2\n"));
  const editResult = editWorkspaceFile(configuration, {
    path: "Sources/Feature/New.swift",
    oldText: "2",
    newText: "3",
  });
  assert.equal(editResult.outputSHA256, sha256("let newValue = 3\n"));
  assert.equal(readFileSync(resolve(workspace, "Sources/Feature/New.swift"), "utf8"), "let newValue = 3\n");
  assert.throws(
    () => validateBuiltInToolCall(configuration, {
      toolName: "bash",
      input: { command: "git push" },
    }),
    /inactive-tool-call/,
  );

  const external = resolve(temporary, "external");
  mkdirSync(external, { mode: 0o700 });
  symlinkSync(external, resolve(workspace, "Sources/Feature/link"));
  assert.throws(
    () => validateBuiltInToolCall(configuration, {
      toolName: "jidoka_code_write",
      input: { path: "Sources/Feature/link/escape.swift" },
    }),
    /symbolic-tool-path/,
  );
  writeFileSync(resolve(workspace, "AtName.txt"), "without at\n", { mode: 0o600 });
  writeFileSync(resolve(workspace, "@AtName.txt"), "with at\n", { mode: 0o600 });
  assert.equal(
    readWorkspaceFile(configuration, { path: "@AtName.txt" }).content,
    "with at\n",
  );

  const aliasTarget = resolve(temporary, "alias-target.txt");
  writeFileSync(aliasTarget, "outside workspace\n", { mode: 0o600 });
  symlinkSync(aliasTarget, resolve(workspace, "Capture d’ecran.txt"));
  assert.throws(
    () => readWorkspaceFile(configuration, { path: "Capture d'ecran.txt" }),
    /ENOENT/,
  );
  assert.throws(
    () => readWorkspaceFile(configuration, { path: "Capture d’ecran.txt" }),
    /symbolic-tool-path/,
  );

  const externalHardlinkTarget = resolve(temporary, "hardlink-target.txt");
  const workspaceHardlink = resolve(workspace, "Hardlink.txt");
  writeFileSync(externalHardlinkTarget, "OUTSIDE-HARDLINK-SENTINEL\n", { mode: 0o600 });
  linkSync(externalHardlinkTarget, workspaceHardlink);
  assert.throws(
    () => readWorkspaceFile(configuration, { path: "Hardlink.txt" }),
    /unsafe-tool-file/,
  );
  await assert.rejects(
    runWorkspaceQuery(configuration, {
      operation: "search",
      query: "OUTSIDE-HARDLINK-SENTINEL",
    }),
    /unsafe-tool-file/,
  );
  const isolatedGitEnvironment = {
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    HOME: temporary,
    PATH: "/usr/bin:/bin",
  };
  execFileSync("/usr/bin/git", ["-C", workspace, "add", "--", "Hardlink.txt"], {
    env: isolatedGitEnvironment,
  });
  writeFileSync(externalHardlinkTarget, "OUTSIDE-HARDLINK-DIFF-SENTINEL\n");
  await assert.rejects(
    runWorkspaceQuery(configuration, { operation: "diff" }),
    /unsafe-workspace-diff-file/,
  );
  execFileSync(
    "/usr/bin/git",
    ["-C", workspace, "rm", "--cached", "--force", "--", "Hardlink.txt"],
    { env: isolatedGitEnvironment },
  );
  unlinkSync(workspaceHardlink);

  const redirectedWorkspace = resolve(temporary, "redirected-workspace");
  mkdirSync(redirectedWorkspace, { mode: 0o700 });
  writeFileSync(
    resolve(redirectedWorkspace, ".git"),
    `gitdir: ${resolve(workspace, ".git")}\n`,
    { mode: 0o600 },
  );
  assert.throws(
    () => buildWorkspaceQuery(
      { ...configuration, workspaceRoot: redirectedWorkspace },
      { operation: "status" },
    ),
    /unsafe-git-directory/,
  );

  execFileSync(
    "/usr/bin/git",
    ["-C", workspace, "config", "--local", "core.worktree", external],
    { env: isolatedGitEnvironment },
  );
  assert.throws(
    () => buildWorkspaceQuery(configuration, { operation: "status" }),
    /indirect-git-config/,
  );
  execFileSync(
    "/usr/bin/git",
    ["-C", workspace, "config", "--local", "--unset", "core.worktree"],
    { env: isolatedGitEnvironment },
  );

  const alternates = resolve(workspace, ".git/objects/info/alternates");
  writeFileSync(alternates, `${external}\n`, { mode: 0o600 });
  assert.throws(
    () => buildWorkspaceQuery(configuration, { operation: "status" }),
    /indirect-git-metadata/,
  );
  unlinkSync(alternates);

  execFileSync("/usr/bin/git", ["-C", workspace, "add", "--", "README.md"], {
    env: isolatedGitEnvironment,
  });
  const filterMarker = resolve(temporary, "filter-executed");
  const filterScript = resolve(temporary, "filter.sh");
  writeFileSync(
    filterScript,
    `#!/bin/sh\n: >'${filterMarker}'\n/bin/cat\n`,
    { mode: 0o700 },
  );
  execFileSync(
    "/usr/bin/git",
    ["-C", workspace, "config", "--local", "filter.jidoka-review.clean", filterScript],
    { env: isolatedGitEnvironment },
  );
  const informationAttributes = resolve(workspace, ".git/info/attributes");
  writeFileSync(informationAttributes, "README.md filter=jidoka-review\n", { mode: 0o600 });
  writeFileSync(resolve(workspace, "README.md"), "review change\n", { mode: 0o600 });
  await assert.rejects(
    runWorkspaceQuery(configuration, { operation: "diff" }),
    /unsafe-git-config/,
  );
  assert.equal(existsSync(filterMarker), false);
  execFileSync(
    "/usr/bin/git",
    ["-C", workspace, "config", "--local", "--unset", "filter.jidoka-review.clean"],
    { env: isolatedGitEnvironment },
  );
  unlinkSync(informationAttributes);
  execFileSync(
    "/usr/bin/git",
    ["-C", workspace, "rm", "--cached", "--force", "--", "README.md"],
    { env: isolatedGitEnvironment },
  );
  writeFileSync(resolve(workspace, "README.md"), "fixture\n", { mode: 0o600 });

  const status = buildWorkspaceQuery(configuration, { operation: "status" });
  assert.deepEqual(status, {
    arguments: [
      `--git-dir=${configuration.workspaceRoot}/.git`,
      `--work-tree=${configuration.workspaceRoot}`,
      "-c",
      `core.worktree=${configuration.workspaceRoot}`,
      "-c",
      "core.bare=false",
      "-c",
      "core.attributesFile=/dev/null",
      "-c",
      "core.excludesFile=/dev/null",
      "--no-optional-locks",
      "-c",
      "core.fsmonitor=false",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "diff.external=",
      "status",
      "--short",
      "--branch",
      "--untracked-files=all",
      "--",
      ".",
      ":(exclude,icase).git",
      ":(exclude,icase).git/**",
      ":(exclude,icase).pi",
      ":(exclude,icase).pi/**",
      ":(exclude,icase).agents",
      ":(exclude,icase).agents/**",
      ":(exclude,glob,icase)**/.git",
      ":(exclude,glob,icase)**/.git/**",
      ":(exclude,glob,icase)**/.pi",
      ":(exclude,glob,icase)**/.pi/**",
      ":(exclude,glob,icase)**/.agents",
      ":(exclude,glob,icase)**/.agents/**",
    ],
    executable: "/usr/bin/git",
  });
  const diff = buildWorkspaceQuery(configuration, { operation: "diff" });
  assert.equal(diff.arguments.includes(":(exclude,icase).pi/**"), true);
  assert.equal(diff.arguments.includes(":(exclude,icase).agents/**"), true);
  const show = buildWorkspaceQuery(configuration, {
    operation: "show",
    revision: "a".repeat(40),
  });
  assert.equal(show.arguments.includes("--no-patch"), true);

  const search = buildWorkspaceQuery(configuration, {
    operation: "search",
    path: "Sources",
    query: "credential helper; git push",
    limit: 10,
  });
  assert.equal(search.executable, "jidoka-code-in-process-search");
  assert.deepEqual(search.arguments, ["credential helper; git push", "Sources", "10"]);
  const hostileFind = buildWorkspaceQuery(configuration, {
    operation: "list",
    path: "-delete",
  });
  assert.equal(hostileFind.executable, "jidoka-code-in-process-list");
  assert.deepEqual(hostileFind.arguments, ["-delete", "root"]);
  const statusResult = await runWorkspaceQuery(configuration, { operation: "status" });
  assert.equal(statusResult.operation, "status");
  const hostilePath = resolve(workspace, "-delete");
  writeFileSync(hostilePath, "must survive\n", { mode: 0o600 });
  const listResult = await runWorkspaceQuery(configuration, {
    operation: "list",
    path: "-delete",
  });
  assert.equal(listResult.content.includes("./-delete"), true);
  assert.equal(existsSync(hostilePath), true);

  for (const reserved of [".pi", ".agents"]) {
    mkdirSync(resolve(workspace, reserved), { mode: 0o700 });
    writeFileSync(resolve(workspace, reserved, "private.txt"), "W5_RESERVED_SENTINEL\n", {
      mode: 0o600,
    });
  }
  writeFileSync(resolve(workspace, ".git/private.txt"), "W5_RESERVED_SENTINEL\n", {
    mode: 0o600,
  });
  for (const reserved of ["Sources/.pI", "Sources/.AGENTS"]) {
    mkdirSync(resolve(workspace, reserved), { mode: 0o700 });
    writeFileSync(resolve(workspace, reserved, "nested.txt"), "W5_RESERVED_SENTINEL\n", {
      mode: 0o600,
    });
  }
  const reservedSearch = await runWorkspaceQuery(configuration, {
    operation: "search",
    query: "W5_RESERVED_SENTINEL",
  });
  assert.equal(reservedSearch.content, "");
  const reservedList = await runWorkspaceQuery(configuration, { operation: "list" });
  const reservedListLower = reservedList.content.toLowerCase();
  assert.equal(reservedListLower.includes("/.git"), false);
  assert.equal(reservedListLower.includes("/.pi"), false);
  assert.equal(reservedListLower.includes("/.agents"), false);
  const sourceSearch = await runWorkspaceQuery(configuration, {
    operation: "search",
    query: "let value = 1",
  });
  assert.equal(sourceSearch.content.includes("./Sources/Feature/Value.swift:1"), true);
  execFileSync(
    "/usr/bin/git",
    ["-C", workspace, "add", "-f", ".pi/private.txt", "Sources/.pI/nested.txt"],
    {
    env: {
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
      HOME: temporary,
      PATH: "/usr/bin:/bin",
      },
    },
  );
  writeFileSync(resolve(workspace, ".pi/private.txt"), "W5_RESERVED_CHANGED\n", {
    mode: 0o600,
  });
  writeFileSync(resolve(workspace, "Sources/.pI/nested.txt"), "W5_NESTED_CHANGED\n", {
    mode: 0o600,
  });
  const reservedDiff = await runWorkspaceQuery(configuration, { operation: "diff" });
  assert.equal(reservedDiff.content.includes("W5_RESERVED_CHANGED"), false);
  assert.equal(reservedDiff.content.includes(".pi/private.txt"), false);
  assert.equal(reservedDiff.content.includes("W5_NESTED_CHANGED"), false);
  assert.equal(reservedDiff.content.toLowerCase().includes("sources/.pi/nested.txt"), false);
  const reservedStatus = await runWorkspaceQuery(configuration, { operation: "status" });
  assert.equal(reservedStatus.content.toLowerCase().includes(".pi/private.txt"), false);
  assert.equal(reservedStatus.content.toLowerCase().includes(".agents/private.txt"), false);
  assert.equal(reservedStatus.content.toLowerCase().includes("sources/.pi/nested.txt"), false);
  assert.equal(reservedStatus.content.toLowerCase().includes("sources/.agents/nested.txt"), false);
  assert.throws(
    () => buildWorkspaceQuery(configuration, { operation: "status", remote: "origin" }),
    /invalid-status-query/,
  );
  assert.throws(
    () => buildWorkspaceQuery(configuration, { operation: "show", revision: "HEAD" }),
    /invalid-show-query/,
  );
  assert.throws(
    () => buildWorkspaceQuery(configuration, { operation: "fetch" }),
    /invalid-workspace-query/,
  );

  const validResult = {
    approvedCommandIDs: ["check"],
    artifactSHA256: "a".repeat(64),
    nonce: "nonce-12345678",
    payload: {
      approvedCommandDigests: [],
      approvedPlanDigest: null,
      classifierFacts: {
        crossModuleConcurrency: false,
        crossRepositoryCoordination: false,
        dataLossMigration: false,
        designAlternatives: false,
        humanDecisionGap: false,
        infrastructureBlastRadius: false,
        nonDestructiveSchema: false,
        operationalRollback: false,
        publicAPI: false,
        releaseOrTag: false,
        securityOrSecretCore: false,
        unresolvedDesignDebate: false,
        unverifiable: false,
        workstreamCount: 1,
      },
      commandDefinitions: [],
      evidence: ["one bounded workstream"],
      findings: [],
      planMarkdown: "# Plan\n",
      proposedComplexity: "simple",
      severity: "none",
      summary: "Bounded local plan.",
      verdict: "pass",
    },
    role: "writer",
    schemaVersion: 1,
    workflow: "planning",
  };
  assert.equal(validateTerminalResult(configuration, validResult), validResult);
  assert.throws(
    () => validateTerminalResult(configuration, {
      ...validResult,
      approvedCommandIDs: ["arbitrary"],
    }),
    /invalid-terminal-envelope/,
  );
  assert.throws(
    () => validateTerminalResult(configuration, {
      ...validResult,
      argv: ["/bin/sh", "-c", "git push"],
    }),
    /invalid-terminal-envelope/,
  );
  assert.throws(
    () => validateTerminalResult(configuration, {
      ...validResult,
      payload: { ...validResult.payload, unexpected: true },
    }),
    /invalid-terminal-payload/,
  );

  const readOnly = loadRuntimeConfiguration(
    writeConfiguration(temporary, {
      workflow: "pr-review",
      role: "security",
      toolPolicy: "read-only",
      allowedWritePaths: [],
      allowedCommandIDs: [],
    }),
  );
  assert.deepEqual(expectedActiveTools(readOnly), [
    "jidoka_code_preflight",
    "jidoka_code_read",
    "jidoka_code_result",
    "jidoka_code_workspace_query",
  ]);
  assert.throws(
    () => validateBuiltInToolCall(readOnly, {
      toolName: "jidoka_code_edit",
      input: { path: "Sources/Feature/Value.swift" },
    }),
    /inactive-tool-call/,
  );

  const copiedRoot = resolve(temporary, "mutated-pi");
  cpSync(root, copiedRoot, { recursive: true });
  writeFileSync(resolve(copiedRoot, "skills/jidoka-code-plan/SKILL.md"), "mutated\n");
  assert.throws(
    () => loadRuntimeConfiguration(writeConfiguration(temporary, { resourceRoot: copiedRoot })),
    /resource-digest-mismatch/,
  );

  rmSync(copiedRoot, { recursive: true, force: true });
  cpSync(root, copiedRoot, { recursive: true });
  const copiedPlanDirectory = resolve(copiedRoot, "skills/jidoka-code-plan");
  const externalPlanDirectory = resolve(temporary, "external-plan-directory");
  cpSync(copiedPlanDirectory, externalPlanDirectory, { recursive: true });
  rmSync(copiedPlanDirectory, { recursive: true, force: true });
  symlinkSync(externalPlanDirectory, copiedPlanDirectory, "dir");
  assert.throws(
    () => loadRuntimeConfiguration(writeConfiguration(temporary, { resourceRoot: copiedRoot })),
    /unsafe-resource-file/,
  );

  rmSync(copiedRoot, { recursive: true, force: true });
  cpSync(root, copiedRoot, { recursive: true });
  const copiedSkill = resolve(copiedRoot, "skills/jidoka-code-plan/SKILL.md");
  const externalSkill = resolve(temporary, "external-plan-skill.md");
  cpSync(copiedSkill, externalSkill);
  rmSync(copiedSkill);
  linkSync(externalSkill, copiedSkill);
  assert.throws(
    () => loadRuntimeConfiguration(writeConfiguration(temporary, { resourceRoot: copiedRoot })),
    /unsafe-resource-file/,
  );

  process.stdout.write("Jidoka extension contract tests: PASS\n");
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
