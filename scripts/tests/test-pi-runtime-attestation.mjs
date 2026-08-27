#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
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
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  attestNodeDependencyClosure,
  attestPackageTree,
  attestReleaseRuntime,
  expectedPiRuntimePaths,
  selectAttestedBuild,
  validateNodePolicy,
  validatePolicy,
} from "../spikes/pi-runtime-attestation.mjs";

function machO(dependencies = [], rpaths = []) {
  const command = (kind, stringOffset, value, prefixWords) => {
    const text = Buffer.from(`${value}\0`, "utf8");
    const size = Math.ceil((stringOffset + text.length) / 8) * 8;
    const data = Buffer.alloc(size);
    data.writeUInt32LE(kind, 0);
    data.writeUInt32LE(size, 4);
    data.writeUInt32LE(stringOffset, 8);
    prefixWords.forEach((word, index) => data.writeUInt32LE(word, 12 + index * 4));
    text.copy(data, stringOffset);
    return data;
  };
  const commands = [
    ...dependencies.map((value) => command(0x0000000c, 24, value, [0, 0, 0])),
    ...rpaths.map((value) => command(0x8000001c, 12, value, [])),
  ];
  const header = Buffer.alloc(32);
  header.writeUInt32LE(0xfeedfacf, 0);
  header.writeUInt32LE(0x0100000c, 4);
  header.writeUInt32LE(2, 12);
  header.writeUInt32LE(commands.length, 16);
  header.writeUInt32LE(commands.reduce((total, value) => total + value.length, 0), 20);
  return Buffer.concat([header, ...commands]);
}

const packageName = "@earendil-works/pi-coding-agent";
const policyPath = fileURLToPath(
  new URL("../../Resources/Pi/runtime/pi-runtime-builds.json", import.meta.url),
);
const nodePolicyPath = fileURLToPath(
  new URL("../../Resources/Pi/runtime/node-runtime-builds.json", import.meta.url),
);
const policyData = readFileSync(policyPath);
const nodePolicyData = readFileSync(nodePolicyPath);
const policySHA256 = createHash("sha256").update(policyData).digest("hex");
const nodePolicySHA256 = createHash("sha256").update(nodePolicyData).digest("hex");
assert.equal(
  policySHA256,
  "a9fd4478272c9d368ce3b1f253cb63a4a936a9354f876c4c30eba64dc694a7f4",
);
assert.equal(
  nodePolicySHA256,
  "cfe0b91f93c46d1c912085ac48a2bac31f8529bc2834c36f6e715ae7f272939d",
);
const policy = JSON.parse(policyData);
const nodePolicy = JSON.parse(nodePolicyData);

assert.deepEqual(validatePolicy(policy), {
  maximum: [0, 90, 0],
  minimum: [0, 84, 0],
});
assert.equal(validateNodePolicy(nodePolicy), nodePolicy);
const duplicateNodeBuild = structuredClone(nodePolicy);
duplicateNodeBuild.builds["26.7.1"] = structuredClone(nodePolicy.builds["26.7.0"]);
assert.throws(() => validateNodePolicy(duplicateNodeBuild), /policy build is ambiguous/);
const selectedPrevious = selectAttestedBuild(policy, {
  name: packageName,
  version: "0.84.0",
});
assert.equal(selectedPrevious.version, "0.84.0");
const selected = selectAttestedBuild(policy, { name: packageName, version: "0.84.2" });
assert.equal(selected.version, "0.84.2");
assert.deepEqual(
  Object.keys(selected.build.criticalFiles).sort(),
  [...expectedPiRuntimePaths].sort(),
);
assert.throws(
  () => selectAttestedBuild(policy, { name: packageName, version: "0.83.0" }),
  /outside the supported range/,
);
assert.throws(
  () => selectAttestedBuild(policy, { name: packageName, version: "0.90.0" }),
  /outside the supported range/,
);
assert.throws(
  () => selectAttestedBuild(policy, { name: packageName, version: "0.89.9" }),
  /build is not attested/,
);

for (const version of ["0.84", "00.84.0", "0.84.0-beta.1", "v0.84.0"]) {
  assert.throws(
    () => selectAttestedBuild(policy, { name: packageName, version }),
    /invalid Pi semantic version/,
  );
}

const missingDigest = structuredClone(policy);
delete missingDigest.builds["0.84.0"].criticalFiles[expectedPiRuntimePaths[0]];
assert.throws(() => validatePolicy(missingDigest), /policy build is invalid/);
const extraDigest = structuredClone(policy);
extraDigest.builds["0.84.0"].unexpected = "a".repeat(64);
assert.throws(() => validatePolicy(extraDigest), /policy build is invalid/);
const changedTree = structuredClone(policy);
changedTree.builds["0.84.0"].packageTree.entryCount += 1;
assert.notDeepEqual(selected.build.packageTree, changedTree.builds["0.84.0"].packageTree);
const treeFixture = realpathSync(mkdtempSync(resolve(tmpdir(), "jidoka-pi-tree-test-")));
try {
  const packageRoot = resolve(treeFixture, "package");
  mkdirSync(resolve(packageRoot, "dist"), { recursive: true });
  const source = resolve(packageRoot, "dist/main.js");
  writeFileSync(source, "first\n");
  const before = attestPackageTree(packageRoot);
  writeFileSync(source, "second\n");
  const after = attestPackageTree(packageRoot);
  assert.equal(before.entryCount, after.entryCount);
  assert.notEqual(before.sha256, after.sha256);
  const outside = resolve(treeFixture, "outside.txt");
  writeFileSync(outside, "outside\n");
  symlinkSync(outside, resolve(packageRoot, "escape"));
  assert.throws(() => attestPackageTree(packageRoot), /symlink escapes/);
} finally {
  rmSync(treeFixture, { force: true, recursive: true });
}
const outsideBuild = structuredClone(policy);
outsideBuild.builds["0.90.0"] = structuredClone(policy.builds["0.84.0"]);
assert.throws(() => validatePolicy(outsideBuild), /policy build is invalid/);
const missingLibraryDigest = structuredClone(nodePolicy);
missingLibraryDigest.builds["26.6.0"].dynamicLibraries[0].sha256 = "invalid";
assert.throws(() => validateNodePolicy(missingLibraryDigest), /dynamic-library policy is invalid/);
assert.throws(
  () => attestNodeDependencyClosure({ dynamicLibraries: [] }),
  /executable path must be explicit/,
);

const machoFixture = realpathSync(mkdtempSync(resolve(tmpdir(), "jidoka-node-macho-test-")));
try {
  const bin = resolve(machoFixture, "bin");
  const shadow = resolve(bin, "shadow");
  const libraryDirectory = resolve(machoFixture, "lib");
  mkdirSync(shadow, { recursive: true });
  mkdirSync(libraryDirectory, { recursive: true });
  const executable = resolve(bin, "node");
  const libraryName = "libnode-fixture.dylib";
  const expectedLibrary = resolve(libraryDirectory, libraryName);
  const shadowLibrary = resolve(shadow, libraryName);
  writeFileSync(
    executable,
    machO([`@rpath/${libraryName}`], ["@loader_path/shadow", "@loader_path/../lib"]),
  );
  writeFileSync(expectedLibrary, machO());
  writeFileSync(shadowLibrary, machO());
  const build = {
    dynamicLibraries: [{
      canonicalPath: realpathSync(expectedLibrary),
      loadPath: expectedLibrary,
      sha256: "a".repeat(64),
    }],
    executable: { canonicalPath: executable, sha256: "b".repeat(64) },
  };
  assert.throws(
    () => attestNodeDependencyClosure(build, executable),
    /unattested Node dependency/,
  );
  unlinkSync(shadowLibrary);
  assert.deepEqual(attestNodeDependencyClosure(build, executable), [realpathSync(expectedLibrary)]);
} finally {
  rmSync(machoFixture, { force: true, recursive: true });
}

assert.throws(
  () => attestReleaseRuntime({
    expectedManifestSHA256: "a".repeat(64),
    nodeExecutable: process.execPath,
    runtimeRoot: "/nonexistent-release-runtime",
  }),
  /authority input is invalid/,
);

process.stdout.write("Pi runtime attestation tests: PASS\n");
