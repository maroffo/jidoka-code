#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  attestSystemRuntime,
  expectedPiRuntimePaths,
  selectAttestedBuild,
  validatePolicy,
} from "../spikes/pi-runtime-attestation.mjs";

const packageName = "@earendil-works/pi-coding-agent";
const policyRelativePath = "runtime/pi-runtime-builds.json";
const policyPath = fileURLToPath(
  new URL("../../Resources/Pi/runtime/pi-runtime-builds.json", import.meta.url),
);
const policyData = readFileSync(policyPath);
const policySHA256 = createHash("sha256").update(policyData).digest("hex");
assert.equal(
  policySHA256,
  "c4e08dd03294cf3dcd0806f5331817dc836c3cf7d7cca5d0f7e970fe36362484",
);
const policy = JSON.parse(policyData);

assert.deepEqual(validatePolicy(policy), {
  maximum: [0, 90, 0],
  minimum: [0, 84, 0],
});
const selected = selectAttestedBuild(policy, { name: packageName, version: "0.84.0" });
assert.equal(selected.version, "0.84.0");
assert.deepEqual(Object.keys(selected.build).sort(), [...expectedPiRuntimePaths].sort());

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
assert.throws(
  () => selectAttestedBuild(policy, { name: packageName, version: "0.84.1" }),
  /build is not attested/,
);
for (const version of ["0.84", "00.84.0", "0.84.0-beta.1", "v0.84.0"]) {
  assert.throws(
    () => selectAttestedBuild(policy, { name: packageName, version }),
    /invalid Pi semantic version/,
  );
}

const missingDigest = structuredClone(policy);
delete missingDigest.builds["0.84.0"][expectedPiRuntimePaths[0]];
assert.throws(() => validatePolicy(missingDigest), /policy build is invalid/);
const extraDigest = structuredClone(policy);
extraDigest.builds["0.84.0"].unexpected = "a".repeat(64);
assert.throws(() => validatePolicy(extraDigest), /policy build is invalid/);
const outsideBuild = structuredClone(policy);
outsideBuild.builds["0.90.0"] = structuredClone(policy.builds["0.84.0"]);
assert.throws(() => validatePolicy(outsideBuild), /policy build is invalid/);

assert.throws(
  () => attestSystemRuntime({
    attestation: {
      files: {
        [policyRelativePath]: { path: policyPath, sha256: policySHA256 },
      },
    },
    expectedPolicySHA256: "a".repeat(64),
    policyRelativePath,
  }),
  /policy digest mismatch/,
);

const runtime = attestSystemRuntime({
  attestation: {
    files: {
      [policyRelativePath]: {
        path: policyPath,
        sha256: policySHA256,
      },
    },
  },
  expectedPolicySHA256: policySHA256,
  policyRelativePath,
});
assert.equal(runtime.version, "0.84.0");
assert.deepEqual(runtime.compatibility, {
  maximumVersionExclusive: "0.90.0",
  minimumVersion: "0.84.0",
  policySHA256,
});
assert.equal(Object.keys(runtime.digests).length, 5);

process.stdout.write("Pi runtime attestation tests: PASS\n");
