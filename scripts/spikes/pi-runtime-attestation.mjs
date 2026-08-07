import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";

const piRoot = "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent";
const expectedPackageName = "@earendil-works/pi-coding-agent";
const maximumRuntimeFileBytes = 1_048_576;
const expectedNodeFiles = Object.freeze({
  "/opt/homebrew/Cellar/node/26.6.0/bin/node":
    "1ef99ea25fe70c9b67e7efe768ef8ee22148d3cabc703db6131b57aeb617d040",
});
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
    policy.schemaVersion !== 1 ||
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
      !exactKeys(build, expectedPiRuntimePaths) ||
      Object.values(build).some((digest) => !/^[0-9a-f]{64}$/.test(digest))
    ) {
      fail(`Pi runtime policy build is invalid: ${version}`);
    }
  }
  return { maximum, minimum };
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

function digestRegularFile(path, description) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > maximumRuntimeFileBytes) {
    fail(`${description} is not a bounded regular file: ${path}`);
  }
  return sha256(readFileSync(path));
}

export function attestSystemRuntime({
  attestation,
  expectedPolicySHA256,
  policyRelativePath,
}) {
  const policyFile = attestation.files[policyRelativePath];
  if (policyFile?.sha256 !== expectedPolicySHA256) {
    fail("Pi runtime policy digest mismatch");
  }
  const policy = JSON.parse(readFileSync(policyFile.path, "utf8"));
  const packagePath = `${piRoot}/package.json`;
  const packageDigest = digestRegularFile(packagePath, "Pi package metadata");
  const selected = selectAttestedBuild(
    policy,
    JSON.parse(readFileSync(packagePath, "utf8")),
  );

  const digests = {};
  for (const [path, expectedSHA256] of Object.entries(expectedNodeFiles)) {
    const digest = digestRegularFile(path, "system runtime");
    if (digest !== expectedSHA256) fail(`system runtime digest mismatch: ${path}`);
    digests[path] = digest;
  }
  for (const relativePath of expectedPiRuntimePaths) {
    const path = `${piRoot}/${relativePath}`;
    const digest = relativePath === "package.json"
      ? packageDigest
      : digestRegularFile(path, "Pi runtime");
    if (digest !== selected.build[relativePath]) {
      fail(`Pi runtime digest mismatch: ${relativePath}`);
    }
    digests[path] = digest;
  }
  return {
    compatibility: {
      ...selected.compatibility,
      policySHA256: expectedPolicySHA256,
    },
    digests,
    version: selected.version,
  };
}
