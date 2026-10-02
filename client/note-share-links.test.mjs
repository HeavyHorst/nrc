import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

function setup(files = true) {
  const assets = new Map();
  const tasks = new Map([[20n, { title: "Cached task" }]]);
  const requests = [];
  const queued = [];
  const window = {
    NRCFiles: files ? {} : undefined,
    NRCAssets: {
      AssetType: { Note: 5, File: 3, Slice: 11 },
      roomAssets: new Map([[0n, assets]]),
      getAssetTypeLabel: type => ({ 5: "NOTE", 3: "FILE", 8: "COMPANY", 11: "SLICE" })[type],
      requestAsset: (room, id, options) => requests.push({ type: "asset", room, id, options }),
    },
    NRCTasks: {
      roomTasks: new Map([[0n, tasks]]),
      requestTask: (room, id, options) => requests.push({ type: "task", room, id, options }),
    },
    NRCEdges: { TargetType: { Asset: 1, Task: 2 }, RelationTypeNames: { 1: "references", 7: "member-of" } },
  };
  const context = vm.createContext({
    window, document: { addEventListener() {} }, console,
    HTMLElement: class {}, customElements: { define() {} },
    queueMicrotask: callback => queued.push(callback),
    escapeHtml: value => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;"),
  });
  for (const file of ["links-ui.js", "notes.js"]) {
    vm.runInContext(fs.readFileSync(`client/${file}`, "utf8"), context);
  }
  vm.runInContext("sharedNoteAsset = { convId: 0n, assetId: 10n }; renderSharedNoteView = () => {};", context);
  return { context, window, assets, tasks, requests, queued };
}

const outgoing = (type, id, relation = 1) => ({ sourceType: 1, sourceId: 10n, targetType: type, targetId: id, relation });
const incoming = (type, id) => ({ sourceType: type, sourceId: id, targetType: 1, targetId: 10n, relation: 1 });

test("share edge loading fetches uncached tasks in both directions with FILES enabled", () => {
  const s = setup();
  const edges = [outgoing(2, 20n), outgoing(2, 21n), incoming(2, 22n), outgoing(2, 21n), outgoing(1, 30n)];
  s.window.NRCEdges.sendListEdges = (_room, _type, _id, options) => options.onSuccess({ edges });
  vm.runInContext("loadSharedNoteEdges(sharedNoteAsset)", s.context);
  assert.deepEqual(s.requests.map(r => [r.type, r.room, r.id]), [["task", 0n, 21n], ["task", 0n, 22n]]);
  s.tasks.set(21n, { title: "Completed <task>" });
  s.requests[0].options.onSuccess();
  assert.equal(s.queued.length, 1, "completion schedules a fresh render");
  assert.match(vm.runInContext("renderSharedLinkedNodes(sharedNoteAsset, sharedNoteEdges)", s.context), /Completed &lt;task>/);
});

test("share asset fallback fetches both directions without FILES and skips cached targets", () => {
  const s = setup(false);
  s.assets.set(31n, { assetType: 5, preview: "Cached" });
  s.context.edges = [outgoing(1, 30n), incoming(1, 32n), outgoing(1, 30n), outgoing(1, 31n)];
  vm.runInContext("fetchSharedLinkedTargets(0n, edges, 10n)", s.context);
  assert.deepEqual(s.requests.map(r => [r.type, r.id]), [["asset", 30n], ["asset", 32n]]);
});

test("share rows use real asset kinds and names, preserve note buttons, and exclude files", () => {
  const s = setup();
  s.assets.set(30n, { assetType: 11, preview: JSON.stringify({ name: "Release <September>" }) });
  s.assets.set(31n, { assetType: 5, preview: JSON.stringify({ title: "Architecture" }) });
  s.assets.set(32n, { assetType: 8, preview: JSON.stringify({ title: "Example company" }) });
  s.assets.set(33n, { assetType: 3, preview: JSON.stringify({ title: "Separate file" }) });
  s.context.edges = [outgoing(1, 30n, 7), incoming(1, 31n), outgoing(1, 32n), outgoing(1, 33n), outgoing(1, 34n), outgoing(2, 29n)];
  const html = vm.runInContext("renderSharedLinkedNodes(sharedNoteAsset, edges)", s.context);
  assert.match(html, /<div[^>]*data-type="SLICE"[^>]*data-id="30"/);
  assert.match(html, /Release &lt;September>/);
  assert.match(html, /<button[^>]*data-type="NOTE"[^>]*data-id="31"/);
  assert.match(html, /references ←/);
  assert.match(html, /data-type="COMPANY"/);
  assert.match(html, /Example company/);
  assert.doesNotMatch(html, /Separate file|data-id="33"/);
  assert.match(html, /Note #34/);
  assert.match(html, /TASK #29/);
  assert.doesNotMatch(html, /<button[^>]*data-id="34"/);
});
