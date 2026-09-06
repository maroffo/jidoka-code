import { readFileSync } from "node:fs";

function fail(message) {
  process.stderr.write(`rollout expected-values validation failed: ${message}\n`);
  process.exit(65);
}

function object(value, name) {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    fail(`${name} must be an object`);
  }
  return value;
}

function exactKeys(value, expected, name) {
  const observed = Object.keys(object(value, name)).sort();
  const required = [...expected].sort();
  if (JSON.stringify(observed) !== JSON.stringify(required)) {
    fail(`${name} keys differ`);
  }
}

function integer(value, expected, name) {
  if (!Number.isInteger(value) || value !== expected) {
    fail(`${name} must equal ${expected}`);
  }
}

if (process.argv.length !== 4 && !(process.argv.length === 5 && process.argv[4] === "--paths")) {
  fail("expected <values.json> <schema.json>");
}

let values;
let schema;
try {
  values = JSON.parse(readFileSync(process.argv[2], "utf8"));
  schema = JSON.parse(readFileSync(process.argv[3], "utf8"));
} catch {
  fail("input is not valid JSON");
}

exactKeys(
  values,
  ["qualificationCounters", "release", "requiredSourcePaths", "schemaVersion"],
  "root"
);
integer(values.schemaVersion, 1, "schemaVersion");

exactKeys(
  values.release,
  [
    "bundleBuild",
    "bundleVersion",
    "databaseSchemaVersion",
    "engineProtocolVersion",
    "maximumConcurrency",
    "rolloutPolicyVersion",
  ],
  "release"
);
if (values.release.bundleVersion !== "0.2.0") {
  fail("release.bundleVersion must equal 0.2.0");
}
integer(values.release.bundleBuild, 4, "release.bundleBuild");
integer(values.release.databaseSchemaVersion, 10, "release.databaseSchemaVersion");
integer(values.release.engineProtocolVersion, 12, "release.engineProtocolVersion");
integer(values.release.maximumConcurrency, 1, "release.maximumConcurrency");
integer(values.release.rolloutPolicyVersion, 1, "release.rolloutPolicyVersion");

const counterKeys = [
  "credentialReads",
  "gitRemoteReads",
  "githubMutations",
  "providerCalls",
];
exactKeys(values.qualificationCounters, counterKeys, "qualificationCounters");
for (const key of counterKeys) {
  integer(values.qualificationCounters[key], 0, `qualificationCounters.${key}`);
}

if (
  !Array.isArray(values.requiredSourcePaths) ||
  values.requiredSourcePaths.length === 0 ||
  values.requiredSourcePaths.length > 64 ||
  new Set(values.requiredSourcePaths).size !== values.requiredSourcePaths.length
) {
  fail("requiredSourcePaths must be a non-empty unique bounded array");
}
for (const path of values.requiredSourcePaths) {
  if (
    typeof path !== "string" ||
    path.length > 256 ||
    !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(path) ||
    path.split("/").includes("..")
  ) {
    fail("requiredSourcePaths contains an unsafe path");
  }
}

exactKeys(
  schema,
  ["$id", "$schema", "additionalProperties", "properties", "required", "title", "type"],
  "schema root"
);
if (
  schema.$schema !== "https://json-schema.org/draft/2020-12/schema" ||
  schema.additionalProperties !== false ||
  schema.type !== "object" ||
  !Array.isArray(schema.required) ||
  JSON.stringify([...schema.required].sort()) !==
    JSON.stringify(["qualificationCounters", "release", "requiredSourcePaths", "schemaVersion"].sort())
) {
  fail("schema root contract differs");
}

if (process.argv[4] === "--paths") {
  process.stdout.write(`${values.requiredSourcePaths.join("\n")}\n`);
} else {
  process.stdout.write("rollout-expected-values=ok schema=1\n");
}
