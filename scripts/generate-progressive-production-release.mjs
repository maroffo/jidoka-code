function fail(message) {
  process.stderr.write(`progressive release manifest generation failed: ${message}\n`);
  process.exit(1);
}

if (process.argv.length !== 13) {
  fail("expected 11 manifest values");
}

const [
  sourceCommit,
  sourceTree,
  bundleVersion,
  bundleBuildText,
  helperSHA256,
  herdrHostSHA256,
  databaseSchemaVersionText,
  engineProtocolVersionText,
  runtimeManifestSHA256,
  runtimeTreeSHA256,
  workflowResourcesSHA256,
] = process.argv.slice(2);

const sha1 = /^[0-9a-f]{40}$/;
const sha256 = /^[0-9a-f]{64}$/;
if (!sha1.test(sourceCommit) || !sha1.test(sourceTree)) {
  fail("source identity is malformed");
}
if (
  ![
    helperSHA256,
    herdrHostSHA256,
    runtimeManifestSHA256,
    runtimeTreeSHA256,
    workflowResourcesSHA256,
  ].every((value) => sha256.test(value))
) {
  fail("digest is malformed");
}
if (bundleVersion !== "0.2.0" || bundleBuildText !== "3") {
  fail("bundle identity differs from release 0.2.0 build 3");
}
if (databaseSchemaVersionText !== "10" || engineProtocolVersionText !== "12") {
  fail("schema or protocol identity differs");
}

const manifest = {
  bundleBuild: Number(bundleBuildText),
  bundleVersion,
  databaseSchemaVersion: Number(databaseSchemaVersionText),
  engineProtocolVersion: Number(engineProtocolVersionText),
  helperSHA256,
  herdrHostSHA256,
  manifestSchemaVersion: 1,
  runtimeManifestSHA256,
  runtimeTreeSHA256,
  sourceCommit,
  sourceTree,
  workflowResourcesSHA256,
};
process.stdout.write(JSON.stringify(manifest));
