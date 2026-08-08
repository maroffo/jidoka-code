import { createHash, randomBytes } from "node:crypto";
import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { basename, dirname, relative, resolve, sep } from "node:path";
import { TextDecoder } from "node:util";

const contractVersion = "1";
const maximumConfigurationBytes = 65_536;
const maximumResourceBytes = 1_048_576;
const maximumQueryBytes = 65_536;
const maximumToolFileBytes = 4 * 1_048_576;
const maximumToolTextBytes = 512 * 1_024;
const maximumQueryEntries = 10_000;
const maximumQueryScanBytes = 64 * 1_048_576;
const maximumGitMetadataEntries = 1_000_000;
const safeGitPrefix = Object.freeze([
  "--no-optional-locks",
  "-c",
  "core.fsmonitor=false",
  "-c",
  "core.hooksPath=/dev/null",
  "-c",
  "diff.external=",
]);
const reservedGitPathspecExclusions = Object.freeze([
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
]);
const allowedWorkflows = new Set([
  "pr-review",
  "issue-triage",
  "planning",
  "orchestration",
]);
const allowedRoles = Object.freeze({
  "pr-review": new Set(["architecture", "security", "test", "synthesis"]),
  "issue-triage": new Set(["triage"]),
  planning: new Set(["writer", "architecture", "security", "test", "synthesis"]),
  orchestration: new Set(["writer", "architecture", "security", "test", "synthesis"]),
});
const readOnlyTools = Object.freeze([
  "jidoka_code_preflight",
  "jidoka_code_read",
  "jidoka_code_result",
  "jidoka_code_workspace_query",
]);
const writerTools = Object.freeze([
  ...readOnlyTools,
  "jidoka_code_edit",
  "jidoka_code_write",
].sort());
const workspaceOperations = Object.freeze(["status", "diff", "log", "show", "search", "list"]);
const hardRiskFlags = Object.freeze([
  "security-or-secret-core",
  "data-loss-migration",
  "release-or-tag",
  "infrastructure-blast-radius",
  "cross-repository-coordination",
  "unresolved-design-debate",
  "unverifiable",
]);
const resultKeys = Object.freeze([
  "approvedCommandIDs",
  "artifactSHA256",
  "nonce",
  "payload",
  "role",
  "schemaVersion",
  "workflow",
]);

function fail(message) {
  throw new Error(`JIDOKA_EXTENSION_CONTRACT:${message}`);
}

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, expected) {
  return (
    isObject(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort())
  );
}

function isDigest(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}

function isIdentifier(value) {
  return typeof value === "string" && /^[a-z0-9][a-z0-9-]{0,63}$/.test(value);
}

function readRegularJSON(path, maximumBytes, requirePrivate) {
  if (typeof path !== "string" || !path.startsWith("/") || resolve(path) !== path) {
    fail("invalid-json-path");
  }
  const stat = lstatSync(path);
  const unsafePermissions = requirePrivate && (stat.mode & 0o077) !== 0;
  const unsafeOwner =
    requirePrivate && typeof process.getuid === "function" && stat.uid !== process.getuid();
  if (
    !stat.isFile() ||
    stat.isSymbolicLink() ||
    stat.size > maximumBytes ||
    unsafePermissions ||
    unsafeOwner
  ) {
    fail("unsafe-json-file");
  }
  try {
    return { data: readFileSync(path), stat };
  } catch {
    fail("unreadable-json-file");
  }
}

function validateRoot(path, name, requirePrivate = false) {
  if (typeof path !== "string" || !path.startsWith("/") || resolve(path) !== path) {
    fail(`invalid-${name}`);
  }
  const stat = lstatSync(path);
  const unsafePermissions = requirePrivate && (stat.mode & 0o077) !== 0;
  const unsafeOwner =
    requirePrivate && typeof process.getuid === "function" && stat.uid !== process.getuid();
  if (
    !stat.isDirectory() ||
    stat.isSymbolicLink() ||
    realpathSync(path) !== path ||
    unsafePermissions ||
    unsafeOwner
  ) {
    fail(`unsafe-${name}`);
  }
  return path;
}

function reservedPathComponent(value) {
  return [".git", ".pi", ".agents"].includes(value.toLowerCase());
}

function validRelativePath(path) {
  if (
    typeof path !== "string" ||
    path.length === 0 ||
    path.length > 1_024 ||
    path.startsWith("/") ||
    path.includes("\0") ||
    path.includes("\\")
  ) {
    return false;
  }
  const parts = path.split("/");
  return parts.every((part) =>
    part.length > 0 &&
    part !== "." &&
    part !== ".." &&
    !reservedPathComponent(part)
  );
}

function validateStringArray(value, predicate, maximumItems = 256) {
  return (
    Array.isArray(value) &&
    value.length <= maximumItems &&
    new Set(value).size === value.length &&
    value.every(predicate)
  );
}

function validateRole(workflow, role) {
  return allowedWorkflows.has(workflow) && allowedRoles[workflow]?.has(role) === true;
}

function expectedToolPolicy(workflow, role) {
  return role === "writer" && (workflow === "planning" || workflow === "orchestration")
    ? "writer"
    : "read-only";
}

function readContainedResourceFile(resourceRoot, relativePath) {
  if (!validRelativePath(relativePath)) fail("invalid-resource-entry");
  const components = relativePath.split("/");
  let current = resourceRoot;
  for (let index = 0; index < components.length; index += 1) {
    current = resolve(current, components[index]);
    const stat = lstatSync(current);
    if (stat.isSymbolicLink()) fail("unsafe-resource-file");
    if (index < components.length - 1 && !stat.isDirectory()) {
      fail("unsafe-resource-file");
    }
    if (index === components.length - 1) {
      if (!stat.isFile() || stat.nlink !== 1 || stat.size > maximumResourceBytes) {
        fail("unsafe-resource-file");
      }
    }
    if (
      realpathSync(current) !== current ||
      (current !== resourceRoot && !current.startsWith(`${resourceRoot}${sep}`))
    ) {
      fail("resource-path-escape");
    }
  }
  const { data } = readExactRegularFile(current);
  if (data.length > maximumResourceBytes) fail("unsafe-resource-file");
  return data;
}

function loadResourceManifest(configuration) {
  const manifestPath = configuration.resourceManifestPath;
  if (
    typeof manifestPath !== "string" ||
    resolve(manifestPath) !== manifestPath ||
    dirname(manifestPath) !== configuration.resourceRoot ||
    !manifestPath.endsWith("/workflow-resources.json")
  ) {
    fail("invalid-resource-manifest-path");
  }
  const data = readContainedResourceFile(
    configuration.resourceRoot,
    "workflow-resources.json",
  );
  if (sha256(data) !== configuration.resourceManifestSHA256) {
    fail("resource-manifest-digest-mismatch");
  }
  let manifest;
  try {
    manifest = JSON.parse(data);
  } catch {
    fail("malformed-resource-manifest");
  }
  if (
    !exactKeys(manifest, ["contractVersion", "resources", "schemaVersion"]) ||
    manifest.schemaVersion !== 1 ||
    manifest.contractVersion !== contractVersion ||
    !isObject(manifest.resources) ||
    Object.keys(manifest.resources).length < 8
  ) {
    fail("invalid-resource-manifest");
  }
  for (const [relativePath, expectedDigest] of Object.entries(manifest.resources)) {
    if (!validRelativePath(relativePath) || !isDigest(expectedDigest)) {
      fail("invalid-resource-entry");
    }
    const absolutePath = resolve(configuration.resourceRoot, relativePath);
    if (!absolutePath.startsWith(`${configuration.resourceRoot}${sep}`)) {
      fail("resource-path-escape");
    }
    const data = readContainedResourceFile(configuration.resourceRoot, relativePath);
    if (sha256(data) !== expectedDigest) {
      fail(`resource-digest-mismatch:${relativePath}`);
    }
  }
  return manifest;
}

export function loadRuntimeConfiguration(path = process.env.JIDOKA_CODE_CONFIG) {
  const { data } = readRegularJSON(path, maximumConfigurationBytes, true);
  let configuration;
  try {
    configuration = JSON.parse(data);
  } catch {
    fail("malformed-configuration");
  }
  const keys = [
    "allowedCommandIDs",
    "allowedWritePaths",
    "artifactSHA256",
    "contractVersion",
    "nonce",
    "resourceManifestPath",
    "resourceManifestSHA256",
    "resourceRoot",
    "role",
    "schemaVersion",
    "toolPolicy",
    "workflow",
    "workspaceRoot",
  ];
  if (
    !exactKeys(configuration, keys) ||
    configuration.schemaVersion !== 1 ||
    configuration.contractVersion !== contractVersion ||
    !validateRole(configuration.workflow, configuration.role) ||
    configuration.toolPolicy !== expectedToolPolicy(configuration.workflow, configuration.role) ||
    !/^[a-z0-9][a-z0-9-]{7,63}$/.test(configuration.nonce) ||
    !isDigest(configuration.artifactSHA256) ||
    !isDigest(configuration.resourceManifestSHA256) ||
    !validateStringArray(configuration.allowedCommandIDs, isIdentifier, 64) ||
    !validateStringArray(configuration.allowedWritePaths, validRelativePath, 256) ||
    (configuration.toolPolicy === "read-only" && configuration.allowedWritePaths.length !== 0)
  ) {
    fail("invalid-configuration");
  }
  configuration.resourceRoot = validateRoot(configuration.resourceRoot, "resource-root");
  configuration.workspaceRoot = validateRoot(
    configuration.workspaceRoot,
    "workspace-root",
    true,
  );
  configuration.resourceManifest = loadResourceManifest(configuration);
  return Object.freeze(configuration);
}

export function expectedActiveTools(configuration) {
  return configuration.toolPolicy === "writer" ? [...writerTools] : [...readOnlyTools];
}

function relativeWorkspacePath(configuration, requestedPath, mode) {
  const path = requestedPath;
  if (typeof path !== "string" || path.length === 0 || path.includes("\0")) {
    fail("invalid-tool-path");
  }
  const absolutePath = path.startsWith("/")
    ? resolve(path)
    : resolve(configuration.workspaceRoot, path);
  if (
    absolutePath !== configuration.workspaceRoot &&
    !absolutePath.startsWith(`${configuration.workspaceRoot}${sep}`)
  ) {
    fail("tool-path-escape");
  }
  const relativePath = relative(configuration.workspaceRoot, absolutePath);
  if (relativePath !== "" && !validRelativePath(relativePath)) {
    fail("forbidden-tool-path");
  }

  const components = relativePath === "" ? [] : relativePath.split("/");
  let current = configuration.workspaceRoot;
  for (const component of components) {
    current = resolve(current, component);
    if (!existsSync(current)) break;
    const stat = lstatSync(current);
    if (stat.isSymbolicLink()) fail("symbolic-tool-path");
    const canonical = realpathSync(current);
    if (
      canonical !== configuration.workspaceRoot &&
      !canonical.startsWith(`${configuration.workspaceRoot}${sep}`)
    ) {
      fail("redirected-tool-path");
    }
  }

  if (mode === "write") {
    const allowed = configuration.allowedWritePaths.some(
      (prefix) => relativePath === prefix || relativePath.startsWith(`${prefix}/`),
    );
    if (!allowed) fail("write-path-not-approved");
  }
  return { absolutePath, relativePath };
}

function sameFileIdentity(left, right) {
  return (
    left.dev === right.dev &&
    left.ino === right.ino &&
    left.size === right.size &&
    left.mode === right.mode &&
    left.nlink === right.nlink
  );
}

function readExactRegularFile(path) {
  const before = lstatSync(path);
  if (
    !before.isFile() ||
    before.isSymbolicLink() ||
    before.nlink !== 1 ||
    before.size > maximumToolFileBytes ||
    typeof constants.O_NOFOLLOW !== "number"
  ) {
    fail("unsafe-tool-file");
  }
  let descriptor;
  try {
    descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const opened = fstatSync(descriptor);
    if (
      !opened.isFile() ||
      opened.nlink !== 1 ||
      !sameFileIdentity(before, opened)
    ) fail("changed-tool-file");
    const data = Buffer.alloc(opened.size);
    let offset = 0;
    while (offset < data.length) {
      const count = readSync(descriptor, data, offset, data.length - offset, null);
      if (count <= 0) fail("short-tool-file");
      offset += count;
    }
    const after = fstatSync(descriptor);
    if (!sameFileIdentity(opened, after)) fail("changed-tool-file");
    return { data, mode: opened.mode & 0o777 };
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function decodeToolText(data) {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(data);
  } catch {
    fail("tool-file-invalid-utf8");
  }
}

function validateToolText(value, name, allowEmpty = true) {
  if (
    typeof value !== "string" ||
    (!allowEmpty && value.length === 0) ||
    Buffer.byteLength(value, "utf8") > maximumToolFileBytes ||
    value.includes("\0")
  ) {
    fail(`invalid-${name}`);
  }
  return value;
}

function atomicWriteExact(path, content) {
  const data = Buffer.from(content, "utf8");
  let mode = 0o644;
  if (existsSync(path)) mode = readExactRegularFile(path).mode;
  const parent = dirname(path);
  const parentStat = lstatSync(parent);
  if (!parentStat.isDirectory() || parentStat.isSymbolicLink()) fail("unsafe-tool-parent");
  const temporaryPath = resolve(
    parent,
    `.${basename(path)}.jidoka-${process.pid}-${randomBytes(12).toString("hex")}`,
  );
  let descriptor;
  try {
    descriptor = openSync(
      temporaryPath,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      mode,
    );
    let offset = 0;
    while (offset < data.length) {
      const count = writeSync(descriptor, data, offset, data.length - offset);
      if (count <= 0) fail("short-tool-write");
      offset += count;
    }
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporaryPath, path);
    const persisted = readExactRegularFile(path).data;
    if (sha256(persisted) !== sha256(data)) fail("tool-write-verification-failed");
    return { bytes: data.length, outputSHA256: sha256(data) };
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    try {
      unlinkSync(temporaryPath);
    } catch (cleanupError) {
      if (cleanupError?.code !== "ENOENT") throw cleanupError;
    }
    throw error;
  }
}

export function readWorkspaceFile(configuration, parameters) {
  if (
    !isObject(parameters) ||
    typeof parameters.path !== "string" ||
    !Object.keys(parameters).every((key) => ["limit", "offset", "path"].includes(key))
  ) {
    fail("invalid-read-request");
  }
  const offset = parameters.offset ?? 1;
  const limit = parameters.limit ?? 200;
  if (!Number.isInteger(offset) || offset < 1 || offset > 1_000_000) {
    fail("invalid-read-offset");
  }
  if (!Number.isInteger(limit) || limit < 1 || limit > 2_000) fail("invalid-read-limit");
  const target = relativeWorkspacePath(configuration, parameters.path, "read");
  const data = readExactRegularFile(target.absolutePath).data;
  const text = decodeToolText(data);
  const lines = text.split("\n");
  const selected = lines.slice(offset - 1, offset - 1 + limit).join("\n");
  if (Buffer.byteLength(selected, "utf8") > maximumToolTextBytes) {
    fail("read-output-limit");
  }
  return {
    content: selected,
    endLine: Math.min(lines.length, offset - 1 + limit),
    fileSHA256: sha256(data),
    relativePath: target.relativePath,
    startLine: offset,
    totalLines: lines.length,
    truncated: offset - 1 + limit < lines.length,
  };
}

export function writeWorkspaceFile(configuration, parameters) {
  if (!exactKeys(parameters, ["content", "path"]) || typeof parameters.path !== "string") {
    fail("invalid-write-request");
  }
  const content = validateToolText(parameters.content, "write-content");
  const target = relativeWorkspacePath(configuration, parameters.path, "write");
  return { relativePath: target.relativePath, ...atomicWriteExact(target.absolutePath, content) };
}

export function editWorkspaceFile(configuration, parameters) {
  if (
    !exactKeys(parameters, ["newText", "oldText", "path"]) ||
    typeof parameters.path !== "string"
  ) {
    fail("invalid-edit-request");
  }
  const oldText = validateToolText(parameters.oldText, "edit-old-text", false);
  const newText = validateToolText(parameters.newText, "edit-new-text");
  const target = relativeWorkspacePath(configuration, parameters.path, "write");
  const source = decodeToolText(readExactRegularFile(target.absolutePath).data);
  const first = source.indexOf(oldText);
  if (first < 0 || source.indexOf(oldText, first + oldText.length) >= 0) {
    fail("edit-match-not-unique");
  }
  const updated = `${source.slice(0, first)}${newText}${source.slice(first + oldText.length)}`;
  validateToolText(updated, "edit-result");
  return { relativePath: target.relativePath, ...atomicWriteExact(target.absolutePath, updated) };
}

export function validateBuiltInToolCall(configuration, event) {
  if (!isObject(event) || typeof event.toolName !== "string" || !isObject(event.input)) {
    fail("invalid-tool-call");
  }
  const active = new Set(expectedActiveTools(configuration));
  if (!active.has(event.toolName)) fail("inactive-tool-call");
  const pathTools = new Set([
    "jidoka_code_read",
    "jidoka_code_write",
    "jidoka_code_edit",
  ]);
  if (!pathTools.has(event.toolName)) return;
  const mode = event.toolName === "jidoka_code_read" ? "read" : "write";
  relativeWorkspacePath(configuration, event.input.path, mode);
}

function safeLocalGitSetting(key, value, workspaceRoot) {
  switch (key) {
    case "core.repositoryformatversion": return value === "0";
    case "core.filemode":
    case "core.ignorecase":
    case "core.precomposeunicode":
      return value === "true" || value === "false";
    case "core.bare": return value === "false";
    case "core.logallrefupdates": return value === "true";
    case "user.name": return value === "Jidoka Code";
    case "user.email": return value === "jidoka-code@invalid.example";
    case "commit.gpgsign": return value === "false";
    case "remote.origin.url":
      return value.startsWith("/") && resolve(value) === value && value !== workspaceRoot;
    case "remote.origin.fetch":
      return value === "+refs/heads/*:refs/remotes/origin/*";
    default:
      if (key.startsWith("branch.")) {
        return (
          (key.endsWith(".remote") && value === "origin") ||
          (key.endsWith(".merge") && value.startsWith("refs/heads/"))
        );
      }
      if (key.startsWith("submodule.") && key.endsWith(".url")) {
        return value.startsWith("/") && resolve(value) === value;
      }
      return false;
  }
}

function validateLocalGitConfiguration(gitDirectory, workspaceRoot) {
  const configPath = resolve(gitDirectory, "config");
  const result = spawnSync(
    "/usr/bin/git",
    ["config", "--file", configPath, "--no-includes", "--null", "--list"],
    {
      cwd: workspaceRoot,
      encoding: "buffer",
      env: {
        GIT_CONFIG_GLOBAL: "/dev/null",
        GIT_CONFIG_NOSYSTEM: "1",
        HOME: "/var/empty",
        LANG: "en_US.UTF-8",
        LC_ALL: "en_US.UTF-8",
        PATH: "/usr/bin:/bin",
      },
      maxBuffer: maximumResourceBytes,
      timeout: 3_000,
    },
  );
  if (
    result.error !== undefined ||
    result.signal !== null ||
    result.status !== 0 ||
    result.stderr.length !== 0 ||
    result.stdout.length > maximumResourceBytes
  ) {
    fail("unsafe-git-config");
  }
  const records = result.stdout.subarray(0, -1).toString("utf8").split("\0");
  if (result.stdout.length === 0 || result.stdout.at(-1) !== 0) {
    fail("unsafe-git-config");
  }
  for (const record of records) {
    const separator = record.indexOf("\n");
    if (separator <= 0) fail("unsafe-git-config");
    const key = record.slice(0, separator).toLowerCase();
    const value = record.slice(separator + 1);
    if (!safeLocalGitSetting(key, value, workspaceRoot)) {
      fail("unsafe-git-config");
    }
  }
}

function validateGitRepositoryMetadata(configuration) {
  const gitDirectory = resolve(configuration.workspaceRoot, ".git");
  const rootStat = lstatSync(gitDirectory);
  if (
    !rootStat.isDirectory() ||
    rootStat.isSymbolicLink() ||
    realpathSync(gitDirectory) !== gitDirectory ||
    !gitDirectory.startsWith(`${configuration.workspaceRoot}${sep}`)
  ) {
    fail("unsafe-git-directory");
  }
  let entryCount = 0;
  function walk(directory, depth) {
    if (depth > 64) fail("git-metadata-depth-limit");
    const names = readdirSync(directory)
      .sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
    for (const name of names) {
      entryCount += 1;
      if (entryCount > maximumGitMetadataEntries) fail("git-metadata-entry-limit");
      const path = resolve(directory, name);
      const stat = lstatSync(path);
      if (
        stat.isSymbolicLink() ||
        realpathSync(path) !== path ||
        !path.startsWith(`${gitDirectory}${sep}`)
      ) {
        fail("unsafe-git-metadata");
      }
      if (stat.isFile() && stat.nlink !== 1) fail("unsafe-git-metadata");
      if (stat.isDirectory()) walk(path, depth + 1);
    }
  }
  walk(gitDirectory, 0);
  for (const forbidden of [
    "commondir",
    "config.worktree",
    "objects/info/alternates",
    "objects/info/http-alternates",
  ]) {
    if (existsSync(resolve(gitDirectory, forbidden))) fail("indirect-git-metadata");
  }
  const configData = readExactRegularFile(resolve(gitDirectory, "config")).data;
  if (configData.length > maximumResourceBytes) fail("unsafe-git-config");
  let configText;
  try {
    configText = new TextDecoder("utf-8", { fatal: true }).decode(configData);
  } catch {
    fail("unsafe-git-config");
  }
  if (
    /^\s*\[\s*include(?:if)?(?:\s|\])/imu.test(configText) ||
    /^\s*worktree\s*=/imu.test(configText) ||
    /^\s*worktreeconfig\s*=\s*true\s*$/imu.test(configText) ||
    /^\s*bare\s*=\s*true\s*$/imu.test(configText)
  ) {
    fail("indirect-git-config");
  }
  validateLocalGitConfiguration(gitDirectory, configuration.workspaceRoot);
  return gitDirectory;
}

function gitWorkspacePrefix(configuration) {
  const gitDirectory = validateGitRepositoryMetadata(configuration);
  return [
    `--git-dir=${gitDirectory}`,
    `--work-tree=${configuration.workspaceRoot}`,
    "-c",
    `core.worktree=${configuration.workspaceRoot}`,
    "-c",
    "core.bare=false",
    "-c",
    "core.attributesFile=/dev/null",
    "-c",
    "core.excludesFile=/dev/null",
    ...safeGitPrefix,
  ];
}

function exactQueryKeys(parameters, expectedOptional) {
  const keys = Object.keys(parameters);
  return keys.every((key) => key === "operation" || expectedOptional.has(key));
}

function validatedLimit(value, fallback, maximum) {
  if (value === undefined) return fallback;
  if (!Number.isInteger(value) || value < 1 || value > maximum) fail("invalid-query-limit");
  return value;
}

export function buildWorkspaceQuery(configuration, parameters) {
  if (
    !isObject(parameters) ||
    typeof parameters.operation !== "string" ||
    !workspaceOperations.includes(parameters.operation)
  ) {
    fail("invalid-workspace-query");
  }
  const operation = parameters.operation;
  const path = parameters.path === undefined
    ? undefined
    : relativeWorkspacePath(configuration, parameters.path, "read").relativePath || ".";
  switch (operation) {
    case "status":
      if (!exactQueryKeys(parameters, new Set())) fail("invalid-status-query");
      return {
        arguments: [
          ...gitWorkspacePrefix(configuration),
          "status",
          "--short",
          "--branch",
          "--untracked-files=all",
          "--",
          ".",
          ...reservedGitPathspecExclusions,
        ],
        executable: "/usr/bin/git",
      };
    case "diff": {
      if (!exactQueryKeys(parameters, new Set(["path"]))) fail("invalid-diff-query");
      const argv = [
        ...gitWorkspacePrefix(configuration),
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--no-color",
        "--",
        path ?? ".",
        ...reservedGitPathspecExclusions,
      ];
      return { arguments: argv, executable: "/usr/bin/git" };
    }
    case "log": {
      if (!exactQueryKeys(parameters, new Set(["limit"]))) fail("invalid-log-query");
      const limit = validatedLimit(parameters.limit, 20, 100);
      return {
        arguments: [
          ...gitWorkspacePrefix(configuration),
          "log",
          "--no-decorate",
          "--no-color",
          "--format=%H%x00%P%x00%an%x00%aI%x00%s",
          "-n",
          String(limit),
        ],
        executable: "/usr/bin/git",
      };
    }
    case "show": {
      if (
        !exactQueryKeys(parameters, new Set(["revision"])) ||
        typeof parameters.revision !== "string" ||
        !/^[0-9a-f]{40}$/.test(parameters.revision)
      ) {
        fail("invalid-show-query");
      }
      return {
        arguments: [
          ...gitWorkspacePrefix(configuration),
          "show",
          "--no-ext-diff",
          "--no-textconv",
          "--no-color",
          "--format=fuller",
          "--stat",
          "--no-patch",
          parameters.revision,
        ],
        executable: "/usr/bin/git",
      };
    }
    case "search": {
      if (
        !exactQueryKeys(parameters, new Set(["limit", "path", "query"])) ||
        typeof parameters.query !== "string" ||
        parameters.query.length < 1 ||
        parameters.query.length > 256 ||
        /[\0\r\n]/.test(parameters.query)
      ) {
        fail("invalid-search-query");
      }
      const limit = validatedLimit(parameters.limit, 50, 200);
      return {
        arguments: [parameters.query, path ?? ".", String(limit)],
        executable: "jidoka-code-in-process-search",
      };
    }
    case "list": {
      if (!exactQueryKeys(parameters, new Set(["path"]))) fail("invalid-list-query");
      return {
        arguments: [path ?? ".", parameters.path === undefined ? "children" : "root"],
        executable: "jidoka-code-in-process-list",
      };
    }
    default:
      fail("unsupported-workspace-query");
  }
}

function boundedWorkspaceEntries(
  configuration,
  startRelativePath,
  maximumDepth,
  includeRoot,
  failAtDepthLimit,
) {
  const startRelative = startRelativePath === "." ? "" : startRelativePath;
  const startAbsolute =
    startRelative.length === 0
      ? configuration.workspaceRoot
      : resolve(configuration.workspaceRoot, startRelative);
  const entries = [];
  function walk(absolutePath, relativePath, depth, include) {
    const name = relativePath.length === 0 ? "" : basename(relativePath);
    if (name.length > 0 && reservedPathComponent(name)) return;
    if (entries.length >= maximumQueryEntries) fail("workspace-query-entry-limit");
    const stat = lstatSync(absolutePath);
    if (include) entries.push({ absolutePath, relativePath, stat });
    if (stat.isSymbolicLink() || !stat.isDirectory()) return;
    relativeWorkspacePath(configuration, relativePath || ".", "read");
    const names = readdirSync(absolutePath)
      .filter((child) => !reservedPathComponent(child))
      .sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
    if (depth >= maximumDepth) {
      if (failAtDepthLimit && names.length > 0) fail("workspace-query-depth-limit");
      return;
    }
    for (const child of names) {
      const childRelative = relativePath.length === 0 ? child : `${relativePath}/${child}`;
      walk(resolve(absolutePath, child), childRelative, depth + 1, true);
    }
  }
  walk(startAbsolute, startRelative, 0, includeRoot);
  return entries;
}

function validateWorkspaceDiffFiles(configuration) {
  const entries = boundedWorkspaceEntries(configuration, ".", 32, false, true);
  for (const entry of entries) {
    if (
      entry.stat.isFile() &&
      !entry.stat.isSymbolicLink() &&
      entry.stat.nlink !== 1
    ) {
      fail("unsafe-workspace-diff-file");
    }
  }
}

function boundedQueryResult(operation, content) {
  const data = Buffer.from(content, "utf8");
  if (data.length > maximumQueryBytes) fail("workspace-query-output-limit");
  return { content, operation, outputSHA256: sha256(data) };
}

function runInProcessSearch(configuration, parameters, invocation) {
  const [query, startRelativePath, rawLimit] = invocation.arguments;
  const limit = Number.parseInt(rawLimit, 10);
  const entries = boundedWorkspaceEntries(
    configuration,
    startRelativePath,
    32,
    true,
    true,
  );
  const queryBytes = Buffer.from(query, "utf8");
  const matches = [];
  let scannedBytes = 0;
  for (const entry of entries) {
    if (!entry.stat.isFile() || entry.stat.isSymbolicLink()) continue;
    scannedBytes += entry.stat.size;
    if (scannedBytes > maximumQueryScanBytes) fail("workspace-query-scan-limit");
    const data = readExactRegularFile(entry.absolutePath).data;
    let lineNumber = 1;
    let start = 0;
    while (start <= data.length) {
      const newline = data.indexOf(0x0a, start);
      const end = newline < 0 ? data.length : newline;
      const line = data.subarray(start, end);
      if (line.indexOf(queryBytes) >= 0) {
        let rendered;
        try {
          rendered = new TextDecoder("utf-8", { fatal: true }).decode(line)
            .replace(/[\u0000-\u001f\u007f]/g, (value) =>
              `\\x${value.codePointAt(0).toString(16).padStart(2, "0")}`
            );
        } catch {
          rendered = `[binary match sha256=${sha256(line)}]`;
        }
        const displayPath = entry.relativePath.length === 0 ? "." : `./${entry.relativePath}`;
        matches.push(`${displayPath}:${lineNumber}:${rendered}`);
        if (matches.length >= limit) {
          return boundedQueryResult(parameters.operation, `${matches.join("\n")}\n`);
        }
      }
      if (newline < 0) break;
      start = newline + 1;
      lineNumber += 1;
    }
  }
  return boundedQueryResult(
    parameters.operation,
    matches.length === 0 ? "" : `${matches.join("\n")}\n`,
  );
}

function runInProcessList(configuration, parameters, invocation) {
  const [startRelativePath, rootMode] = invocation.arguments;
  const entries = boundedWorkspaceEntries(
    configuration,
    startRelativePath,
    3,
    rootMode === "root",
    false,
  );
  const lines = entries.map((entry) =>
    entry.relativePath.length === 0 ? "." : `./${entry.relativePath}`
  );
  return boundedQueryResult(
    parameters.operation,
    lines.length === 0 ? "" : `${lines.join("\n")}\n`,
  );
}

export async function runWorkspaceQuery(configuration, parameters, signal) {
  if (signal?.aborted) fail("workspace-query-already-aborted");
  const invocation = buildWorkspaceQuery(configuration, parameters);
  if (invocation.executable === "jidoka-code-in-process-search") {
    return runInProcessSearch(configuration, parameters, invocation);
  }
  if (invocation.executable === "jidoka-code-in-process-list") {
    return runInProcessList(configuration, parameters, invocation);
  }
  if (parameters.operation === "diff") validateWorkspaceDiffFiles(configuration);
  const environment = {
    GIT_ASKPASS: "/usr/bin/false",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_SSH_COMMAND: "/usr/bin/false",
    GIT_TERMINAL_PROMPT: "0",
    GIT_OPTIONAL_LOCKS: "0",
    HOME: "/var/empty",
    LANG: "en_US.UTF-8",
    LC_ALL: "en_US.UTF-8",
    PATH: "/usr/bin:/bin",
    TMPDIR: process.env.TMPDIR ?? "/tmp",
  };
  return await new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(invocation.executable, invocation.arguments, {
      cwd: configuration.workspaceRoot,
      detached: true,
      env: environment,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      if (error !== undefined) rejectPromise(error);
      else resolvePromise(result);
    };
    const terminate = () => {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch (error) {
        if (error?.code !== "ESRCH") throw error;
      }
    };
    const abort = () => {
      terminate();
      finish(new Error("JIDOKA_WORKSPACE_QUERY_ABORTED"));
    };
    const append = (current, chunk) => {
      if (current.length + chunk.length > maximumQueryBytes) {
        terminate();
        finish(new Error("JIDOKA_WORKSPACE_QUERY_OUTPUT_LIMIT"));
        return current;
      }
      return Buffer.concat([current, chunk]);
    };
    const timer = setTimeout(() => {
      terminate();
      finish(new Error("JIDOKA_WORKSPACE_QUERY_TIMEOUT"));
    }, 10_000);
    signal?.addEventListener("abort", abort, { once: true });
    child.stdout.on("data", (chunk) => {
      stdout = append(stdout, chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr = append(stderr, chunk);
    });
    child.on("error", (error) => finish(error));
    child.on("close", (code, processSignal) => {
      if (settled) return;
      if (code !== 0 || processSignal !== null) {
        finish(new Error("JIDOKA_WORKSPACE_QUERY_FAILED"));
        return;
      }
      let text;
      let diagnostic;
      try {
        const decoder = new TextDecoder("utf-8", { fatal: true });
        text = decoder.decode(stdout);
        diagnostic = decoder.decode(stderr);
      } catch {
        finish(new Error("JIDOKA_WORKSPACE_QUERY_INVALID_UTF8"));
        return;
      }
      if (diagnostic.length > 0) {
        finish(new Error("JIDOKA_WORKSPACE_QUERY_DIAGNOSTIC"));
        return;
      }
      finish(undefined, {
        content: text,
        operation: parameters.operation,
        outputSHA256: sha256(stdout),
      });
    });
  });
}

function validateFinding(value) {
  return (
    exactKeys(value, ["evidence", "line", "path", "recommendation", "severity"]) &&
    ["critical", "major", "minor", "info"].includes(value.severity) &&
    typeof value.path === "string" &&
    value.path.length <= 1_024 &&
    Number.isInteger(value.line) &&
    value.line >= 0 &&
    typeof value.evidence === "string" &&
    value.evidence.length > 0 &&
    value.evidence.length <= 4_096 &&
    typeof value.recommendation === "string" &&
    value.recommendation.length > 0 &&
    value.recommendation.length <= 4_096
  );
}

function validateCommonPayload(payload) {
  return (
    typeof payload.summary === "string" &&
    payload.summary.length > 0 &&
    payload.summary.length <= 2_000 &&
    ["none", "info", "minor", "major", "critical"].includes(payload.severity)
  );
}

function validatePRPayload(payload) {
  return (
    exactKeys(payload, [
      "commitNarrativeSHA256",
      "domain",
      "evidence",
      "findings",
      "severity",
      "summary",
      "verdict",
    ]) &&
    validateCommonPayload(payload) &&
    ["pass", "block"].includes(payload.verdict) &&
    ["architecture", "security", "test", "synthesis"].includes(payload.domain) &&
    isDigest(payload.commitNarrativeSHA256) &&
    validateStringArray(payload.evidence, (value) => typeof value === "string" && value.length > 0) &&
    Array.isArray(payload.findings) &&
    payload.findings.length <= 100 &&
    payload.findings.every(validateFinding)
  );
}

function validateTriagePayload(payload) {
  const rubricKeys = ["bounded", "safe", "specified", "testable"];
  return (
    exactKeys(payload, [
      "complexityGuess",
      "hardRiskFlags",
      "questions",
      "rationale",
      "rubric",
      "severity",
      "summary",
      "verdict",
    ]) &&
    validateCommonPayload(payload) &&
    ["ready", "needs-spec", "human"].includes(payload.verdict) &&
    ["simple", "moderate", "complex", "humanOwned", "unknown"].includes(
      payload.complexityGuess,
    ) &&
    exactKeys(payload.rubric, rubricKeys) &&
    rubricKeys.every(
      (key) => typeof payload.rubric[key] === "string" && payload.rubric[key].length > 0,
    ) &&
    validateStringArray(
      payload.hardRiskFlags,
      (value) => hardRiskFlags.includes(value),
      hardRiskFlags.length,
    ) &&
    validateStringArray(
      payload.questions,
      (value) => typeof value === "string" && value.length > 0 && value.length <= 1_000,
      20,
    ) &&
    typeof payload.rationale === "string" &&
    payload.rationale.length > 0 &&
    payload.rationale.length <= 8_000
  );
}

function validateClassifierFacts(value) {
  const keys = [
    "crossModuleConcurrency",
    "crossRepositoryCoordination",
    "dataLossMigration",
    "designAlternatives",
    "humanDecisionGap",
    "infrastructureBlastRadius",
    "nonDestructiveSchema",
    "operationalRollback",
    "publicAPI",
    "releaseOrTag",
    "securityOrSecretCore",
    "unresolvedDesignDebate",
    "unverifiable",
    "workstreamCount",
  ];
  return (
    exactKeys(value, keys) &&
    Number.isInteger(value.workstreamCount) &&
    value.workstreamCount >= 1 &&
    value.workstreamCount <= 100 &&
    keys
      .filter((key) => key !== "workstreamCount")
      .every((key) => typeof value[key] === "boolean")
  );
}

function validateCommandDefinition(value) {
  const keys = [
    "approvedHookPath",
    "arguments",
    "environmentOverrides",
    "executableOrRepositoryScript",
    "id",
    "rationale",
    "registryKind",
    "sourceDigest",
    "timeoutSeconds",
    "workingDirectory",
  ];
  return (
    exactKeys(value, keys) &&
    isIdentifier(value.id) &&
    [
      "makeTargets",
      "swiftBuildTest",
      "xcodebuildBuildTest",
      "repositoryScript",
      "gitRead",
      "gitStage",
      "gitCommit",
    ].includes(value.registryKind) &&
    typeof value.executableOrRepositoryScript === "string" &&
    validateStringArray(
      value.arguments,
      (argument) => typeof argument === "string" && !argument.includes("\0"),
    ) &&
    isObject(value.environmentOverrides) &&
    Object.entries(value.environmentOverrides).every(
      ([key, item]) => /^[A-Z][A-Z0-9_]{0,63}$/.test(key) && typeof item === "string",
    ) &&
    (value.workingDirectory === "." || validRelativePath(value.workingDirectory)) &&
    Number.isInteger(value.timeoutSeconds) &&
    value.timeoutSeconds >= 1 &&
    value.timeoutSeconds <= 3_600 &&
    typeof value.rationale === "string" &&
    value.rationale.length > 0 &&
    value.rationale.length <= 2_000 &&
    (value.sourceDigest === null || isDigest(value.sourceDigest)) &&
    (value.approvedHookPath === null || validRelativePath(value.approvedHookPath))
  );
}

function validatePlanningPayload(payload) {
  return (
    exactKeys(payload, [
      "approvedCommandDigests",
      "approvedPlanDigest",
      "classifierFacts",
      "commandDefinitions",
      "evidence",
      "findings",
      "planMarkdown",
      "proposedComplexity",
      "severity",
      "summary",
      "verdict",
    ]) &&
    validateCommonPayload(payload) &&
    ["pass", "revise", "escalate"].includes(payload.verdict) &&
    ["simple", "moderate", "complex", "humanOwned", "unknown"].includes(
      payload.proposedComplexity,
    ) &&
    validateClassifierFacts(payload.classifierFacts) &&
    Array.isArray(payload.commandDefinitions) &&
    payload.commandDefinitions.length <= 64 &&
    payload.commandDefinitions.every(validateCommandDefinition) &&
    validateStringArray(payload.approvedCommandDigests, isDigest, 64) &&
    (payload.approvedPlanDigest === null || isDigest(payload.approvedPlanDigest)) &&
    validateStringArray(payload.evidence, (value) => typeof value === "string" && value.length > 0) &&
    Array.isArray(payload.findings) &&
    payload.findings.length <= 100 &&
    payload.findings.every(validateFinding) &&
    typeof payload.planMarkdown === "string" &&
    payload.planMarkdown.length <= 262_144
  );
}

function validateOrchestrationPayload(payload) {
  return (
    exactKeys(payload, [
      "changedPaths",
      "evidence",
      "findings",
      "requestedCommandIDs",
      "severity",
      "summary",
      "verdict",
    ]) &&
    validateCommonPayload(payload) &&
    ["pass", "revise", "block"].includes(payload.verdict) &&
    validateStringArray(payload.changedPaths, validRelativePath) &&
    validateStringArray(payload.requestedCommandIDs, isIdentifier, 64) &&
    validateStringArray(payload.evidence, (value) => typeof value === "string" && value.length > 0) &&
    Array.isArray(payload.findings) &&
    payload.findings.length <= 100 &&
    payload.findings.every(validateFinding)
  );
}

export function validateTerminalResult(configuration, parameters) {
  if (
    !exactKeys(parameters, resultKeys) ||
    parameters.schemaVersion !== 1 ||
    parameters.workflow !== configuration.workflow ||
    parameters.role !== configuration.role ||
    parameters.nonce !== configuration.nonce ||
    parameters.artifactSHA256 !== configuration.artifactSHA256 ||
    !validateStringArray(parameters.approvedCommandIDs, isIdentifier, 64) ||
    !parameters.approvedCommandIDs.every((id) => configuration.allowedCommandIDs.includes(id)) ||
    !isObject(parameters.payload)
  ) {
    fail("invalid-terminal-envelope");
  }
  const validPayload =
    configuration.workflow === "pr-review"
      ? validatePRPayload(parameters.payload)
      : configuration.workflow === "issue-triage"
        ? validateTriagePayload(parameters.payload)
        : configuration.workflow === "planning"
          ? validatePlanningPayload(parameters.payload)
          : validateOrchestrationPayload(parameters.payload);
  if (!validPayload) fail("invalid-terminal-payload");
  if (
    configuration.workflow === "orchestration" &&
    JSON.stringify(parameters.approvedCommandIDs) !==
      JSON.stringify(parameters.payload.requestedCommandIDs)
  ) {
    fail("orchestration-command-id-mismatch");
  }
  return parameters;
}

export const jidokaExtensionContract = Object.freeze({
  contractVersion,
  hardRiskFlags,
  readOnlyTools,
  resultKeys,
  workspaceOperations,
  writerTools,
});
