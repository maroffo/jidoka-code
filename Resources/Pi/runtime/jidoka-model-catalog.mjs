import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { isAbsolute, join, normalize } from "node:path";
import { pathToFileURL } from "node:url";

const SCHEMA_VERSION = 1;
const MAXIMUM_MODELS = 4096;
const MAXIMUM_AUTH_BYTES = 1_048_576;
const MAXIMUM_MODELS_CONFIG_BYTES = 1_048_576;
const MAXIMUM_MODELS_STORE_BYTES = 8 * 1_048_576;
const TEXT = /^[A-Za-z0-9][A-Za-z0-9._ +()/:-]{0,255}$/u;
const COMPONENT = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$/u;

function fail() {
  throw new Error("MODEL_CATALOG_FAILED");
}

function sameFile(left, right) {
  return (
    left.dev === right.dev &&
    left.ino === right.ino &&
    left.mode === right.mode &&
    left.nlink === right.nlink &&
    left.uid === right.uid &&
    left.gid === right.gid &&
    left.size === right.size &&
    left.mtimeNs === right.mtimeNs &&
    left.ctimeNs === right.ctimeNs
  );
}

async function readBoundedText(path, maximumBytes, privateFile, signal) {
  let handle;
  try {
    handle = await open(
      path,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK
    );
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    fail();
  }
  try {
    const before = await handle.stat({ bigint: true });
    const mode = before.mode & 0o777n;
    if (
      !before.isFile() ||
      before.uid !== BigInt(process.getuid()) ||
      before.nlink !== 1n ||
      before.size < 0n ||
      before.size > BigInt(maximumBytes) ||
      (privateFile ? mode & 0o077n : mode & 0o022n) !== 0n
    ) {
      fail();
    }
    const bytes = Buffer.alloc(Number(before.size));
    let offset = 0;
    while (offset < bytes.length) {
      signal.throwIfAborted();
      const { bytesRead } = await handle.read(
        bytes,
        offset,
        bytes.length - offset,
        offset
      );
      if (bytesRead === 0) fail();
      offset += bytesRead;
    }
    const text = bytes.toString("utf8");
    const after = await handle.stat({ bigint: true });
    if (!sameFile(before, after)) fail();
    return { handle, path: `/dev/fd/${handle.fd}`, text };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

async function readObject(path, maximumBytes, signal) {
  const file = await readBoundedText(path, maximumBytes, true, signal);
  if (file === undefined) return {};
  try {
    const value = JSON.parse(file.text);
    if (!value || typeof value !== "object" || Array.isArray(value)) fail();
    return value;
  } catch {
    fail();
  } finally {
    await file.handle.close();
  }
}

class SnapshotCredentialStore {
  constructor(entries) {
    this.entries = entries;
  }

  async read(providerId, options) {
    options?.signal?.throwIfAborted();
    const value = this.entries[providerId];
    return value === undefined ? undefined : structuredClone(value);
  }

  async list(options) {
    options?.signal?.throwIfAborted();
    return Object.entries(this.entries).map(([providerId, credential]) => ({
      providerId,
      type: credential?.type,
    }));
  }

  async modify() {
    throw new Error("credential snapshot is read-only");
  }

  async delete() {
    throw new Error("credential snapshot is read-only");
  }
}

class SnapshotModelsStore {
  constructor(entries) {
    this.entries = entries;
  }

  async read(providerId, options) {
    options?.signal?.throwIfAborted();
    const value = this.entries[providerId];
    return value === undefined ? undefined : structuredClone(value);
  }

  async write(_providerId, _entry, options) {
    options?.signal?.throwIfAborted();
  }

  async delete(_providerId, options) {
    options?.signal?.throwIfAborted();
  }
}

try {
  const agentDirectory = process.env.PI_CODING_AGENT_DIR;
  const packageRoot = process.argv[2];
  if (
    process.argv.length !== 3 ||
    process.env.PI_OFFLINE !== "1" ||
    typeof process.getuid !== "function" ||
    typeof agentDirectory !== "string" ||
    !isAbsolute(agentDirectory) ||
    normalize(agentDirectory) !== agentDirectory ||
    typeof packageRoot !== "string" ||
    !isAbsolute(packageRoot) ||
    normalize(packageRoot) !== packageRoot
  ) fail();

  const signal = AbortSignal.timeout(10_000);
  const credentialEntries = await readObject(
    join(agentDirectory, "auth.json"),
    MAXIMUM_AUTH_BYTES,
    signal
  );
  const modelStoreEntries = await readObject(
    join(agentDirectory, "models-store.json"),
    MAXIMUM_MODELS_STORE_BYTES,
    signal
  );
  const modelsConfigSnapshot = await readBoundedText(
    join(agentDirectory, "models.json"),
    MAXIMUM_MODELS_CONFIG_BYTES,
    false,
    signal
  );

  const moduleURL = (relativePath) =>
    pathToFileURL(join(packageRoot, relativePath)).href;
  const [{ ModelRuntime }, { ModelConfig }, { getSupportedThinkingLevels }] =
    await Promise.all([
      import(moduleURL("dist/core/model-runtime.js")),
      import(moduleURL("dist/core/model-config.js")),
      import(moduleURL("node_modules/@earendil-works/pi-ai/dist/models.js")),
    ]);

  const credentials = new SnapshotCredentialStore(credentialEntries);
  const modelsStore = new SnapshotModelsStore(modelStoreEntries);
  let runtime;
  try {
    const modelConfig = await ModelConfig.load(modelsConfigSnapshot?.path);
    if (modelConfig.getError() !== undefined) fail();
    runtime = await ModelRuntime.create({
      credentials,
      modelsPath: null,
      modelsStore,
      allowModelNetwork: false,
      refreshOnCreate: false,
      signal,
    });
    runtime.config = modelConfig;
    runtime.configureRadiusProviders();
    runtime.rebuildProviders();
    const refresh = await runtime.models.refresh({ allowNetwork: false, signal });
    if (refresh.aborted || refresh.errors.size !== 0) fail();
    runtime.updateModelSnapshot();
  } finally {
    await modelsConfigSnapshot?.handle.close();
  }
  const available = await runtime.getAvailable(undefined, { signal });
  if (
    runtime.getError() !== undefined ||
    !Array.isArray(available) ||
    available.length > MAXIMUM_MODELS
  ) {
    fail();
  }

  const models = available.map((model) => {
    if (
      typeof model.provider !== "string" ||
      !COMPONENT.test(model.provider) ||
      model.provider.includes("/") ||
      typeof model.id !== "string" ||
      !COMPONENT.test(model.id) ||
      typeof model.name !== "string" ||
      !TEXT.test(model.name) ||
      !Array.isArray(model.input) ||
      !model.input.every((value) => value === "text" || value === "image") ||
      typeof model.reasoning !== "boolean" ||
      !Number.isSafeInteger(model.contextWindow) ||
      model.contextWindow <= 0 ||
      !Number.isSafeInteger(model.maxTokens) ||
      model.maxTokens <= 0
    ) {
      fail();
    }
    const thinkingLevels = getSupportedThinkingLevels(model);
    if (!Array.isArray(thinkingLevels) || thinkingLevels.length === 0) fail();
    return {
      provider: model.provider,
      id: model.id,
      name: model.name,
      reasoning: model.reasoning,
      input: [...model.input],
      contextWindow: model.contextWindow,
      maxTokens: model.maxTokens,
      thinkingLevels,
    };
  });

  models.sort((lhs, rhs) =>
    lhs.provider.localeCompare(rhs.provider) ||
    lhs.name.localeCompare(rhs.name) ||
    lhs.id.localeCompare(rhs.id)
  );
  process.stdout.write(`${JSON.stringify({ schemaVersion: SCHEMA_VERSION, models })}\n`);
} catch {
  process.stderr.write("MODEL_CATALOG_FAILED\n");
  process.exitCode = 1;
}
