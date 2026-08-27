import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
} from "node:fs";
import { dirname, resolve } from "node:path";

const expectedPackageName = "@earendil-works/pi-coding-agent";
const expectedReleaseManifestSHA256 =
  "fe15573a58a4604a3695b092ba8b07ae2432da7b7f07743a8d54a4421ab3aa83";
const maximumRuntimeFileBytes = 16 * 1_048_576;
const maximumNodeLibraryBytes = 128 * 1_048_576;
export const expectedPiRuntimePaths = Object.freeze([
  "dist/cli.js",
  "dist/core/sdk.js",
  "node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js",
  "package.json",
]);

function fail(message) {
  throw new Error(message);
}

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function exactKeys(value, expected) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort())
  );
}

function isDigest(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}

function validAbsolutePath(value) {
  return typeof value === "string" && value.startsWith("/") && resolve(value) === value;
}

function validNodeLoadPath(value) {
  if (typeof value !== "string") return false;
  for (const prefix of ["@rpath/", "@loader_path/"]) {
    if (value.startsWith(prefix)) {
      const name = value.slice(prefix.length);
      return name.length > 0 && !name.includes("/") && !name.includes("\0");
    }
  }
  return validAbsolutePath(value);
}

export function parseVersion(value) {
  const match = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.exec(value);
  if (match === null) fail(`invalid Pi semantic version: ${value}`);
  return match.slice(1).map((component) => Number.parseInt(component, 10));
}

export function compareVersions(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  }
  return 0;
}

export function validatePolicy(policy) {
  if (
    !exactKeys(policy, [
      "builds",
      "maximumVersionExclusive",
      "minimumVersion",
      "package",
      "schemaVersion",
    ]) ||
    policy.schemaVersion !== 2 ||
    policy.package !== expectedPackageName ||
    !exactKeys(policy.builds, Object.keys(policy.builds ?? {})) ||
    Object.keys(policy.builds).length === 0
  ) {
    fail("Pi runtime policy is malformed");
  }
  const minimum = parseVersion(policy.minimumVersion);
  const maximum = parseVersion(policy.maximumVersionExclusive);
  if (compareVersions(minimum, maximum) >= 0) fail("Pi runtime policy range is empty");
  for (const [version, build] of Object.entries(policy.builds)) {
    const parsed = parseVersion(version);
    if (
      compareVersions(parsed, minimum) < 0 ||
      compareVersions(parsed, maximum) >= 0 ||
      !exactKeys(build, ["criticalFiles", "packageTree"]) ||
      !exactKeys(build.criticalFiles, expectedPiRuntimePaths) ||
      Object.values(build.criticalFiles).some((digest) => !isDigest(digest)) ||
      !exactKeys(build.packageTree, ["entryCount", "sha256"]) ||
      !Number.isInteger(build.packageTree.entryCount) ||
      build.packageTree.entryCount < 1 ||
      build.packageTree.entryCount > 100_000 ||
      !isDigest(build.packageTree.sha256)
    ) {
      fail(`Pi runtime policy build is invalid: ${version}`);
    }
  }
  return { maximum, minimum };
}

export function validateNodePolicy(policy) {
  if (
    !exactKeys(policy, ["builds", "runtime", "schemaVersion"]) ||
    policy.schemaVersion !== 2 ||
    policy.runtime !== "node" ||
    !exactKeys(policy.builds, Object.keys(policy.builds ?? {})) ||
    Object.keys(policy.builds).length === 0
  ) {
    fail("Node runtime policy is malformed");
  }
  const buildIdentities = new Set();
  for (const [version, build] of Object.entries(policy.builds)) {
    parseVersion(version);
    if (
      !exactKeys(build, ["dynamicLibraries", "executable"]) ||
      !exactKeys(build.executable, ["canonicalPath", "sha256"]) ||
      !validAbsolutePath(build.executable.canonicalPath) ||
      !isDigest(build.executable.sha256) ||
      !Array.isArray(build.dynamicLibraries) ||
      build.dynamicLibraries.length > 128
    ) {
      fail(`Node runtime policy build is invalid: ${version}`);
    }
    const loadPaths = [];
    const canonicalPaths = [];
    for (const library of build.dynamicLibraries) {
      if (
        !exactKeys(library, ["canonicalPath", "loadPath", "sha256"]) ||
        !validNodeLoadPath(library.loadPath) ||
        !validAbsolutePath(library.canonicalPath) ||
        !isDigest(library.sha256)
      ) {
        fail(`Node dynamic-library policy is invalid: ${version}`);
      }
      loadPaths.push(library.loadPath);
      canonicalPaths.push(library.canonicalPath);
    }
    if (
      JSON.stringify(loadPaths) !== JSON.stringify([...loadPaths].sort()) ||
      new Set(loadPaths).size !== loadPaths.length ||
      new Set(canonicalPaths).size !== canonicalPaths.length
    ) {
      fail(`Node dynamic-library inventory is ambiguous: ${version}`);
    }
    const identity = JSON.stringify([
      build.executable.canonicalPath,
      build.executable.sha256,
      ...build.dynamicLibraries.flatMap((library) => [
        library.loadPath,
        library.canonicalPath,
        library.sha256,
      ]),
    ]);
    if (buildIdentities.has(identity)) {
      fail(`Node runtime policy build is ambiguous: ${version}`);
    }
    buildIdentities.add(identity);
  }
  return policy;
}

export function selectAttestedBuild(policy, packageMetadata) {
  const range = validatePolicy(policy);
  const version = packageMetadata?.version;
  if (packageMetadata?.name !== policy.package || typeof version !== "string") {
    fail("Pi package identity is invalid");
  }
  const parsedVersion = parseVersion(version);
  if (
    compareVersions(parsedVersion, range.minimum) < 0 ||
    compareVersions(parsedVersion, range.maximum) >= 0
  ) {
    fail(`Pi package version is outside the supported range: ${version}`);
  }
  const build = policy.builds[version];
  if (build === undefined) fail(`Pi package build is not attested: ${version}`);
  return {
    build,
    compatibility: {
      maximumVersionExclusive: policy.maximumVersionExclusive,
      minimumVersion: policy.minimumVersion,
    },
    version,
  };
}

function digestRegularFile(path, description, maximumBytes = maximumRuntimeFileBytes) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > maximumBytes) {
    fail(`${description} is not a bounded regular file: ${path}`);
  }
  return sha256(readFileSync(path));
}

export function attestPackageTree(root) {
  if (typeof root !== "string" || !root.startsWith("/")) {
    fail("Pi package root must be one explicit absolute path");
  }
  const canonicalRoot = realpathSync(root);
  const entries = [];
  function walk(directory, relativeDirectory = "") {
    for (const name of readdirSync(directory)) {
      const absolutePath = resolve(directory, name);
      const relativePath = relativeDirectory.length === 0
        ? name
        : `${relativeDirectory}/${name}`;
      const stat = lstatSync(absolutePath);
      if (stat.isSymbolicLink()) {
        const target = readlinkSync(absolutePath);
        const canonicalTarget = realpathSync(resolve(dirname(absolutePath), target));
        if (
          canonicalTarget !== canonicalRoot &&
          !canonicalTarget.startsWith(`${canonicalRoot}/`)
        ) {
          fail(`Pi package symlink escapes the package: ${relativePath}`);
        }
        entries.push({ kind: "symbolicLink", relativePath, target });
      } else if (stat.isDirectory()) {
        entries.push({ kind: "directory", permissions: stat.mode & 0o777, relativePath });
        walk(absolutePath, relativePath);
      } else if (stat.isFile()) {
        if (stat.size > maximumRuntimeFileBytes) {
          fail(`Pi package file is oversized: ${relativePath}`);
        }
        entries.push({
          absolutePath,
          kind: "regularFile",
          permissions: stat.mode & 0o777,
          relativePath,
        });
      } else {
        fail(`Pi package entry has an unsupported type: ${relativePath}`);
      }
      if (entries.length > 100_000) fail("Pi package inventory is oversized");
    }
  }
  walk(canonicalRoot);
  entries.sort((left, right) =>
    Buffer.compare(Buffer.from(left.relativePath), Buffer.from(right.relativePath))
  );
  const hash = createHash("sha256");
  const update = (fields) => {
    hash.update(fields.map((value) => `${Buffer.byteLength(String(value))}:${value}`).join("|") + "\n");
  };
  update(["jidoka-pi-package-tree", "1", "entryCount", String(entries.length)]);
  for (const entry of entries) {
    if (entry.kind === "directory") {
      update(["directory", entry.relativePath, "permissions", String(entry.permissions)]);
    } else if (entry.kind === "symbolicLink") {
      update(["symbolicLink", entry.relativePath, "target", entry.target]);
    } else {
      const data = readFileSync(entry.absolutePath);
      update([
        "regularFile",
        entry.relativePath,
        "permissions",
        String(entry.permissions),
        "size",
        String(data.length),
        "sha256",
        sha256(data),
      ]);
    }
  }
  return { entryCount: entries.length, sha256: hash.digest("hex") };
}

function parseMachO(data) {
  if (data.length < 32 || data.readUInt32LE(0) !== 0xfeedfacf) {
    fail("Node dependency is not a supported Mach-O image");
  }
  const commandCount = data.readUInt32LE(16);
  const commandBytes = data.readUInt32LE(20);
  if (commandCount > 4_096 || commandBytes > data.length - 32) {
    fail("Node Mach-O load-command inventory is invalid");
  }
  const dependencyCommands = new Set([
    0x0000000c,
    0x00000020,
    0x80000018,
    0x8000001f,
    0x80000023,
  ]);
  const dependencies = [];
  const rpaths = [];
  let cursor = 32;
  const end = 32 + commandBytes;
  const readCommandString = (offset, commandSize) => {
    const start = cursor + offset;
    const limit = cursor + commandSize;
    if (start < cursor || start >= limit || limit > data.length) {
      fail("Node Mach-O string offset is invalid");
    }
    const terminator = data.indexOf(0, start);
    if (terminator <= start || terminator >= limit) {
      fail("Node Mach-O string is unterminated");
    }
    const value = data.subarray(start, terminator).toString("utf8");
    if (Buffer.from(value, "utf8").compare(data.subarray(start, terminator)) !== 0) {
      fail("Node Mach-O string is not UTF-8");
    }
    return value;
  };
  for (let index = 0; index < commandCount; index += 1) {
    if (cursor > end - 8) fail("Node Mach-O load command is truncated");
    const command = data.readUInt32LE(cursor);
    const commandSize = data.readUInt32LE(cursor + 4);
    if (commandSize < 8 || cursor + commandSize > end) {
      fail("Node Mach-O load command size is invalid");
    }
    if (dependencyCommands.has(command)) {
      if (commandSize < 24) fail("Node Mach-O dylib command is invalid");
      dependencies.push(readCommandString(data.readUInt32LE(cursor + 8), commandSize));
    } else if (command === 0x8000001c) {
      if (commandSize < 12) fail("Node Mach-O rpath command is invalid");
      rpaths.push(readCommandString(data.readUInt32LE(cursor + 8), commandSize));
    }
    cursor += commandSize;
  }
  if (cursor !== end) fail("Node Mach-O load commands do not fill their inventory");
  return { dependencies, rpaths };
}

function systemMachODependency(path) {
  return path.startsWith("/usr/lib/") || path.startsWith("/System/Library/");
}

function expandRPath(rpath, imagePath, executablePath) {
  const imageDirectory = dirname(imagePath);
  const executableDirectory = dirname(executablePath);
  if (rpath === "@loader_path") return imageDirectory;
  if (rpath.startsWith("@loader_path/")) {
    return resolve(imageDirectory, rpath.slice("@loader_path/".length));
  }
  if (rpath === "@executable_path") return executableDirectory;
  if (rpath.startsWith("@executable_path/")) {
    return resolve(executableDirectory, rpath.slice("@executable_path/".length));
  }
  return rpath.startsWith("/") ? resolve(rpath) : undefined;
}

function resolveMachODependency(
  dependency,
  imagePath,
  rpaths,
  executableRPaths,
  expected,
  executablePath,
) {
  if (dependency.startsWith("/")) {
    const canonical = realpathSync(dependency);
    if (!expected.has(canonical)) fail(`unattested Node dependency: ${dependency}`);
    return canonical;
  }
  for (const [token, directory] of [
    ["@loader_path/", dirname(imagePath)],
    ["@executable_path/", dirname(executablePath)],
  ]) {
    if (dependency.startsWith(token)) {
      const candidate = resolve(directory, dependency.slice(token.length));
      const canonical = realpathSync(candidate);
      if (!expected.has(canonical)) fail(`unattested Node dependency: ${dependency}`);
      return canonical;
    }
  }
  if (!dependency.startsWith("@rpath/")) {
    fail(`unsupported Node dependency path: ${dependency}`);
  }
  const suffix = dependency.slice("@rpath/".length);
  if (suffix.length === 0 || suffix.includes("/")) {
    fail(`invalid Node rpath dependency: ${dependency}`);
  }
  for (const rpath of [...rpaths, ...executableRPaths]) {
    const expanded = expandRPath(rpath, imagePath, executablePath);
    if (expanded === undefined) continue;
    const candidate = resolve(expanded, suffix);
    if (!existsSync(candidate)) continue;
    const canonical = realpathSync(candidate);
    if (!expected.has(canonical)) fail(`unattested Node dependency: ${dependency}`);
    return canonical;
  }
  fail(`missing Node dependency: ${dependency}`);
}

export function attestNodeDependencyClosure(build, executablePath) {
  if (!validAbsolutePath(executablePath)) {
    fail("Node dependency closure executable path must be explicit");
  }
  const expected = new Set(build.dynamicLibraries.map((library) => library.canonicalPath));
  const images = new Map([[executablePath, readFileSync(executablePath)]]);
  for (const library of build.dynamicLibraries) {
    images.set(library.canonicalPath, readFileSync(library.canonicalPath));
  }
  const executableMetadata = parseMachO(images.get(executablePath));
  const reachable = new Set();
  const pending = [executablePath];
  while (pending.length > 0) {
    const imagePath = pending.pop();
    const metadata = parseMachO(images.get(imagePath));
    for (const dependency of metadata.dependencies) {
      if (systemMachODependency(dependency)) continue;
      const canonical = resolveMachODependency(
        dependency,
        imagePath,
        metadata.rpaths,
        executableMetadata.rpaths,
        expected,
        executablePath,
      );
      if (!reachable.has(canonical)) {
        reachable.add(canonical);
        pending.push(canonical);
      }
    }
  }
  if (
    reachable.size !== expected.size ||
    [...reachable].some((path) => !expected.has(path))
  ) {
    fail("Node Mach-O dependency closure does not match the packaged inventory");
  }
  return [...reachable].sort();
}

export function attestReleaseRuntime({
  expectedManifestSHA256 = expectedReleaseManifestSHA256,
  nodeExecutable = process.execPath,
  runtimeRoot,
}) {
  if (
    expectedManifestSHA256 !== expectedReleaseManifestSHA256 ||
    !validAbsolutePath(runtimeRoot) ||
    !validAbsolutePath(nodeExecutable)
  ) {
    fail("release runtime authority input is invalid");
  }
  const rootStat = lstatSync(runtimeRoot);
  const canonicalRoot = realpathSync(runtimeRoot);
  if (
    !rootStat.isDirectory() ||
    rootStat.isSymbolicLink() ||
    canonicalRoot !== runtimeRoot ||
    JSON.stringify(readdirSync(canonicalRoot).sort()) !==
      JSON.stringify(["licenses", "node", "pi", "runtime-manifest.json"])
  ) {
    fail("release runtime root is unsafe or inexact");
  }
  const manifestPath = `${canonicalRoot}/runtime-manifest.json`;
  const manifestData = readFileSync(manifestPath);
  if (sha256(manifestData) !== expectedManifestSHA256 || manifestData.at(-1) !== 0x0a) {
    fail("release runtime manifest digest differs");
  }
  const manifest = JSON.parse(manifestData);
  if (
    !exactKeys(manifest, [
      "licenses", "node", "pi", "rootEntries", "runtimeID", "schemaVersion",
    ]) ||
    manifest.schemaVersion !== 2 ||
    !exactKeys(manifest.node, [
      "adHocCodeDirectorySHA256", "architecture", "entitlementPolicy", "identifier",
      "machoDependencies", "mode", "productionCodeDirectorySHA256", "relativePath",
      "signatureTeam", "sizeAtAdHocQualification", "upstream", "version",
    ]) ||
    !isDigest(manifest.node?.adHocCodeDirectorySHA256) ||
    !isDigest(manifest.node?.productionCodeDirectorySHA256) ||
    manifest.node?.adHocCodeDirectorySHA256 === manifest.node?.productionCodeDirectorySHA256 ||
    manifest.node?.identifier !== "works.earendil.jidoka.runtime.node" ||
    manifest.node?.relativePath !== "node/bin/node" ||
    manifest.node?.version !== process.versions.node ||
    manifest.pi?.package !== expectedPackageName ||
    manifest.pi?.relativeRoot !== "pi" ||
    manifest.pi?.cliRelativePath !== "dist/cli.js" ||
    !exactKeys(manifest.pi?.criticalFiles, expectedPiRuntimePaths) ||
    !exactKeys(manifest.pi?.packageTree, ["entryCount", "sha256"])
  ) {
    fail("release runtime manifest shape differs");
  }
  const canonicalNode = realpathSync(nodeExecutable);
  const expectedNode = `${canonicalRoot}/${manifest.node.relativePath}`;
  if (canonicalNode !== expectedNode || realpathSync(process.execPath) !== expectedNode) {
    fail("release Node executable differs");
  }
  const packageRoot = `${canonicalRoot}/${manifest.pi.relativeRoot}`;
  const metadataPath = `${packageRoot}/package.json`;
  const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
  if (metadata.name !== manifest.pi.package || metadata.version !== manifest.pi.version) {
    fail("release Pi package identity differs");
  }
  const digests = { [manifestPath]: expectedManifestSHA256 };
  for (const relativePath of expectedPiRuntimePaths) {
    const path = `${packageRoot}/${relativePath}`;
    const digest = digestRegularFile(path, "release Pi runtime");
    if (digest !== manifest.pi.criticalFiles[relativePath]) {
      fail(`release Pi runtime digest differs: ${relativePath}`);
    }
    digests[path] = digest;
  }
  const tree = attestPackageTree(packageRoot);
  if (
    tree.entryCount !== manifest.pi.packageTree.entryCount ||
    tree.sha256 !== manifest.pi.packageTree.sha256
  ) {
    fail("release Pi package tree differs");
  }
  digests[`${packageRoot}/#package-tree-v1`] = tree.sha256;
  const [major, minor, patch] = parseVersion(manifest.pi.version);
  return {
    compatibility: {
      maximumVersionExclusive: `${major}.${minor}.${patch + 1}`,
      minimumVersion: manifest.pi.version,
      policySHA256: expectedManifestSHA256,
    },
    digests,
    nodeVersion: manifest.node.version,
    version: manifest.pi.version,
  };
}

export function attestSystemRuntime({
  attestation,
  expectedNodePolicySHA256,
  expectedPolicySHA256,
  nodePath,
  nodePolicyRelativePath,
  piRoot,
  policyRelativePath,
}) {
  if (!validAbsolutePath(nodePath) || !validAbsolutePath(piRoot)) {
    fail("diagnostic runtime paths must be explicit and absolute");
  }
  const policyFile = attestation.files[policyRelativePath];
  if (policyFile?.sha256 !== expectedPolicySHA256) {
    fail("Pi runtime policy digest mismatch");
  }
  const nodePolicyFile = attestation.files[nodePolicyRelativePath];
  if (nodePolicyFile?.sha256 !== expectedNodePolicySHA256) {
    fail("Node runtime policy digest mismatch");
  }
  const policy = JSON.parse(readFileSync(policyFile.path, "utf8"));
  const nodePolicy = validateNodePolicy(JSON.parse(readFileSync(nodePolicyFile.path, "utf8")));
  const packagePath = `${piRoot}/package.json`;
  const packageDigest = digestRegularFile(packagePath, "Pi package metadata");
  const selected = selectAttestedBuild(
    policy,
    JSON.parse(readFileSync(packagePath, "utf8")),
  );

  const digests = {};
  for (const relativePath of expectedPiRuntimePaths) {
    const path = `${piRoot}/${relativePath}`;
    const digest = relativePath === "package.json"
      ? packageDigest
      : digestRegularFile(path, "Pi runtime");
    if (digest !== selected.build.criticalFiles[relativePath]) {
      fail(`Pi runtime digest mismatch: ${relativePath}`);
    }
    digests[path] = digest;
  }
  const tree = attestPackageTree(piRoot);
  if (
    tree.entryCount !== selected.build.packageTree.entryCount ||
    tree.sha256 !== selected.build.packageTree.sha256
  ) {
    fail("Pi package tree digest or inventory mismatch");
  }
  digests[`${piRoot}/#package-tree-v1`] = tree.sha256;

  const nodeDigest = digestRegularFile(nodePath, "Node executable");
  const nodeEntries = Object.entries(nodePolicy.builds).filter(([, build]) =>
    build.executable.canonicalPath === nodePath && build.executable.sha256 === nodeDigest
  );
  if (nodeEntries.length !== 1) fail("Node executable build is not uniquely attested");
  const [nodeVersion, nodeBuild] = nodeEntries[0];
  if (process.versions.node !== nodeVersion) fail("Node runtime version does not match policy");
  digests[nodePath] = nodeDigest;
  for (const library of nodeBuild.dynamicLibraries) {
    const sourcePath = library.loadPath.startsWith("@")
      ? library.canonicalPath
      : library.loadPath;
    if (realpathSync(sourcePath) !== library.canonicalPath) {
      fail(`Node dynamic-library target mismatch: ${library.loadPath}`);
    }
    const digest = digestRegularFile(
      library.canonicalPath,
      "Node dynamic library",
      maximumNodeLibraryBytes,
    );
    if (digest !== library.sha256) {
      fail(`Node dynamic-library digest mismatch: ${library.loadPath}`);
    }
    digests[library.canonicalPath] = digest;
  }
  attestNodeDependencyClosure(nodeBuild, nodePath);
  return {
    compatibility: {
      ...selected.compatibility,
      policySHA256: expectedPolicySHA256,
    },
    digests,
    nodeVersion,
    version: selected.version,
  };
}
