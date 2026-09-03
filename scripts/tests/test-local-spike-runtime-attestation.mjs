#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  attestSystemRuntime,
  buildLocalSpikeReport,
} from "../spikes/jidoka-local-spikes.mjs";

const root = mkdtempSync(join(tmpdir(), "jidoka-local-runtime-test."));
const git = join(root, "git");
const backend = join(root, "git-http-backend");
const node = join(root, "node");
const bytes = new Map([
  [git, Buffer.from("qualified-git")],
  [backend, Buffer.from("qualified-git-http-backend")],
  [node, Buffer.from("qualified-node")],
]);

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

try {
  for (const [path, value] of bytes) writeFileSync(path, value, { mode: 0o500 });
  const qualified = {
    [git]: sha256(bytes.get(git)),
    [backend]: sha256(bytes.get(backend)),
  };
  assert.deepEqual(
    attestSystemRuntime({ expected: qualified, nodePath: node }),
    {
      ...qualified,
      [node]: sha256(bytes.get(node)),
    },
  );

  for (const driftedPath of [git, backend]) {
    const expected = {
      ...qualified,
      [driftedPath]: "0".repeat(64),
    };
    for (const mode of ["security", "git-transport", "mutation-recovery"]) {
      let effects = 0;
      await assert.rejects(
        buildLocalSpikeReport(mode, "/unused", {
          attestSystemRuntime: () =>
            attestSystemRuntime({ expected, nodePath: node }),
          runSecurityComposition: () => {
            effects += 1;
            return {};
          },
          runGitTransport: async () => {
            effects += 1;
            return {};
          },
          runMutationRecovery: () => {
            effects += 1;
            return {};
          },
        }),
        new RegExp(`system runtime digest drift: ${driftedPath}`),
      );
      assert.equal(effects, 0);
    }
  }
} finally {
  rmSync(root, { recursive: true, force: true });
}

process.stdout.write("Local spike runtime attestation tests: PASS\n");
