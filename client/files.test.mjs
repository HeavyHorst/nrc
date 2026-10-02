import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync("client/files.js", "utf8");
function load() {
  const window = {};
  vm.runInNewContext(source, { window, document: {}, TextEncoder, BigInt, console }, { filename: "files.js" });
  return window.NRCFiles;
}

test("version 1 metadata is normalized while unknown keys are retained", () => {
  const value = load().metadata({ type: "future", version: 9, title: "  Plan  ", tags: [" a ", ""], extra: { retained: true } });
  assert.deepEqual(JSON.parse(JSON.stringify(value)), { type: "file", version: 1, title: "Plan", tags: ["a"], extra: { retained: true }, description: "", category: "" });
});

test("both edge directions are inspected and duplicate file targets retain scoped edges", () => {
  const files = load();
  const result = files.linkedFiles({ id: 9n }, 2, [
    { edgeId: 1n, sourceType: 2, sourceId: 9n, targetType: 1, targetId: 40n, relation: 1 },
    { edgeId: 2n, sourceType: 1, sourceId: 40n, targetType: 2, targetId: 9n, relation: 6 },
    { edgeId: 3n, sourceType: 2, sourceId: 10n, targetType: 1, targetId: 41n },
  ]);
  assert.equal(result.length, 1);
  assert.equal(result[0].assetId, 40n);
  assert.deepEqual(Array.from(result[0].edges, (e) => e.edgeId), [1n, 2n]);
});

test("HTML escaping covers metadata and attribute-sensitive characters", () => {
  assert.equal(load().escape(`<x a="'">&`), "&lt;x a=&quot;&#39;&quot;&gt;&amp;");
});
