import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const window = {};
vm.runInNewContext(fs.readFileSync("client/workspace-search.js", "utf8"), { window });
const { buildRequest, projectResult } = window.NRCWorkspaceSearch;
const plain = value => JSON.parse(JSON.stringify(value));
const result = (type, id, assetType) => ({ entity: { workspace: "demo", type, id, conv_id: "0" }, preview: "Title", metadata: { asset_type: assetType } });

test("mixed search has explicit types, all indexed asset kinds, payload and a bounded limit", () => {
  assert.deepEqual(plain(buildRequest("  plans  ", "all")), {
    query: "plans", top_n: 50, include_payload: true,
    filters: { entity_types: ["task", "asset"], asset_types: [1, 2, 3, 4, 5, 8, 9, 10] },
  });
  assert.deepEqual(plain(buildRequest("plans", "task").filters), { entity_types: ["task"] });
  assert.deepEqual(plain(buildRequest("plans", "3").filters), { entity_types: ["asset"], asset_types: [3] });
});

test("task and file with the same large ID retain independent identities and exact BigInts", () => {
  const id = "18446744073709551615";
  const task = projectResult(result("task", id), "demo");
  const file = projectResult(result("asset", id, 3), "demo");
  assert.notEqual(task.key, file.key);
  assert.equal(file.ref.id, 18446744073709551615n);
  assert.equal(file.ref.type, "file");
  assert.equal(task.ref.type, "task");
  assert.equal(projectResult(result("asset", "2", 5), "demo").ref.type, "note");
  assert.equal(projectResult(result("asset", "2", 2), "demo").ref.assetType, 2);
});

test("foreign scope, unsafe numeric IDs and unknown kinds fail instead of opening wrong records", () => {
  for (const entity of [
    { workspace: "other" }, { conv_id: "7" }, { type: "message" },
    { id: 9007199254740993 }, { id: "0" }, { id: "01" }, { id: "18446744073709551616" },
  ]) {
    const hit = result("task", "23");
    Object.assign(hit.entity, entity);
    assert.throws(() => projectResult(hit, "demo"));
  }
  assert.throws(() => projectResult(result("asset", "2", 7), "demo"));
});

test("customer kinds retain their own inspector identities and readable metadata", () => {
  for (const [assetType, type, label] of [[8, "company", "COMPANY"], [9, "contact", "CONTACT"], [10, "activity", "ACTIVITY"]]) {
    const hit = result("asset", "18446744073709551615", assetType);
    hit.preview = JSON.stringify({ version: 1, title: "Customer record", number: "C-007", role: "Engineer", email: "alice@example.com", excerpt: "Discussed rollout", archived: true });
    const row = projectResult(hit, "demo");
    assert.equal(row.ref.type, type);
    assert.equal(row.label, label);
    assert.equal(row.ref.id, 18446744073709551615n);
    assert.equal(row.title, "Customer record");
    assert.equal(row.excerpt, "Discussed rollout");
    assert.equal(row.context, "C-007 · Engineer · alice@example.com · ARCHIVED");
    assert.deepEqual(plain(buildRequest("alice", String(assetType)).filters), { entity_types: ["asset"], asset_types: [assetType] });
  }
});

test("structured previews, plain task text and HTML notes get distinct safe projections", () => {
  const hit = result("asset", "9", 5);
  hit.preview = JSON.stringify({ title: "Meeting notes", tags: ["team"] });
  hit.payload = JSON.stringify({ format: "html", content: "<script>bad()</script>" });
  hit.metadata.attachments = [{ filename: "recording.wav", status: "indexed" }];
  const note = projectResult(hit, "demo");
  assert.equal(note.title, "Meeting notes");
  assert.equal(note.excerpt, "HTML document · open record to read");
  assert.equal(note.attachments, "recording.wav · INDEXED");
  const task = result("task", "7");
  task.payload = "First line\nSecond line";
  task.metadata.task = { status: 2, project: "Launch", assignee: "Rene" };
  const projected = projectResult(task, "demo");
  assert.equal(projected.excerpt, "First line Second line");
  assert.equal(projected.context, "IN PROGRESS · Project: Launch · Assignee: Rene");
});
