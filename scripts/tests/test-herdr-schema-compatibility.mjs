#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const schemaPath = new URL("../../Resources/Herdr/api-schema-0.8.2.json", import.meta.url);
const root = JSON.parse(readFileSync(schemaPath, "utf8"));
const methods = [
  "ping",
  "session.snapshot",
  "workspace.create",
  "workspace.focus",
  "tab.focus",
  "pane.focus",
  "layout.apply",
  "layout.export",
  "pane.process_info",
  "pane.get",
  "pane.split",
  "pane.send_text",
  "pane.send_keys",
  "pane.close",
  "pane.report_agent",
  "pane.report_metadata",
  "pane.clear_agent_authority",
  "agent.get",
  "agent.rename",
];
const resultTypes = [
  "pong",
  "session_snapshot",
  "workspace_info",
  "workspace_created",
  "tab_info",
  "pane_info",
  "layout_apply",
  "layout_export",
  "pane_process_info",
  "agent_info",
  "ok",
];

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map((key) => [key, canonical(value[key])]),
  );
}

function pointer(reference) {
  let value = root;
  for (const raw of reference.slice(2).split("/")) {
    value = value[raw.replaceAll("~1", "/").replaceAll("~0", "~")];
  }
  return value;
}

function referencedDefinitions(nodes) {
  const definitions = {};
  const visit = (value) => {
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (!value || typeof value !== "object") return;
    if (typeof value.$ref === "string" && !(value.$ref in definitions)) {
      definitions[value.$ref] = pointer(value.$ref);
      visit(definitions[value.$ref]);
    }
    Object.values(value).forEach(visit);
  };
  nodes.forEach(visit);
  return definitions;
}

function variantsByConst(variants, key, values) {
  return values.map((value) => {
    const found = variants.find((item) => item?.properties?.[key]?.const === value);
    assert.ok(found, `missing approved ${key}: ${value}`);
    return found;
  });
}

assert.equal(root.protocol, 20);
const requestMethods = new Set(
  root.schemas.request.oneOf.map((item) => item.properties.method.const),
);
assert.ok(requestMethods.has("pane.input.set"));
for (const method of methods) assert.ok(requestMethods.has(method));
const rightClick = root.schemas.request.$defs.PaneSplitParams.properties.right_click;
assert.deepEqual(rightClick, {
  $ref: "#/schemas/request/$defs/PaneRightClickTarget",
  default: "herdr",
});
assert.ok(!root.schemas.request.$defs.PaneSplitParams.required.includes("right_click"));

const request = variantsByConst(root.schemas.request.oneOf, "method", methods);
const response = variantsByConst(
  root.schemas.success_response.$defs.ResponseResult.oneOf,
  "type",
  resultTypes,
);
const requestDefinitions = referencedDefinitions(request);
delete requestDefinitions["#/schemas/request/$defs/PaneRightClickTarget"];
delete requestDefinitions["#/schemas/request/$defs/PaneSplitParams"].properties.right_click;
const projection = canonical({
  methods,
  request,
  requestDefinitions,
  resultTypes,
  response,
  responseDefinitions: referencedDefinitions(response),
  error: root.schemas.error_response,
});
const digest = createHash("sha256")
  .update(JSON.stringify(projection))
  .digest("hex");
assert.equal(
  digest,
  "911923a145328cd59124ac95ecf0066ef167673636d5409a26bf89adc4b4d6f3",
  "a Jidoka-used Herdr request/result/error shape drifted",
);

process.stdout.write("Herdr 0.8.2 used-contract compatibility tests: PASS\n");
