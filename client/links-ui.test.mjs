import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = fs.readFileSync(path.resolve("client/links-ui.js"), "utf8");

function loadLinksUI({ edges = [], getEdgesForEntity = null, onRequestTask = null, onRequestAsset = null, requestEdgePage = null, slices = [] } = {}) {
  const opened = [];
  const customerOpened = [];
  const sliceSelects = [];
  const activeViews = [];
  let sliceLoads = 0;
  let kanbanShows = 0;
  let noteClears = 0;
  let taskClears = 0;
  const roomTasks = new Map();
  const roomAssets = new Map();
  const assetTypeLabels = { 3: "FILE", 5: "NOTE", 6: "REMINDER", 8: "COMPANY", 9: "CONTACT", 10: "ACTIVITY", 11: "SLICE" };
  const window = {
    NRCAssets: {
      roomAssets,
      requestAsset: (...args) => onRequestAsset?.(...args),
      getAssetTypeLabel: assetType => assetTypeLabels[assetType] || "NOTE",
    },
    NRCEdges: {
      TargetType: { Asset: 1, Task: 2 },
      RelationTypeNames: { 1: "references" },
      getEdgesForEntity: getEdgesForEntity || (() => edges),
      requestEdgePage,
    },
    NRCInspector: { openEntity: (ref) => opened.push(ref) },
    NRCViewManager: { setActiveView: (view) => activeViews.push(view) },
    NRCSlices: {
      getState: () => ({ slices }),
      select: (name, options) => sliceSelects.push([name, options]),
      ensureLoaded: () => { sliceLoads += 1; },
    },
    NRCCustomers: { openRecord: (type, id) => customerOpened.push([type, id]) },
    NRCNotes: {
      clearNoteSelection: () => { noteClears += 1; },
      parseNotePreview: preview => {
        try {
          return { title: JSON.parse(preview).title || "" };
        } catch {
          return { title: String(preview || "") };
        }
      },
    },
    NRCTasks: {
      roomTasks,
      requestTask: (...args) => onRequestTask?.(roomTasks, ...args),
      isKanbanVisible: () => false,
      showKanban: () => { kanbanShows += 1; },
      clearTaskSelection: () => { taskClears += 1; },
    },
  };
  const elements = new Map();
  const createElement = () => {
    const element = {
      children: [],
      className: "",
      dataset: {},
      textContent: "",
      appendChild(child) { this.children.push(child); },
      addEventListener() {},
    };
    Object.defineProperty(element, "innerHTML", {
      set(value) {
        this.children = [];
        this.html = value;
      },
      get() { return this.html || ""; },
    });
    return element;
  };
  const document = {
    addEventListener() {},
    createElement,
    getElementById(id) { return elements.get(id) || null; },
  };
  elements.set("noteLinksList", createElement());
  elements.set("taskDetailLinksList", createElement());

  vm.runInNewContext(source, {
    window, document, console, BigInt,
    HTMLElement: class {},
    customElements: { define(name) { assert.equal(name, "nrc-link-picker"); } },
  }, { filename: "links-ui.js" });
  return {
    linksUI: window.NRCLinksUI,
    elements,
    roomTasks,
    roomAssets,
    createElement,
    opened,
    customerOpened,
    kanbanShows: () => kanbanShows,
    noteClears: () => noteClears,
    taskClears: () => taskClears,
    sliceSelects,
    sliceLoads: () => sliceLoads,
    activeViews,
  };
}

test("task links open the concrete task in the inspector without changing views", () => {
  const { linksUI, opened, kanbanShows, noteClears } = loadLinksUI();

  linksUI.navigateToTarget(7n, 2, 42n, 1);

  assert.equal(opened.length, 1);
  assert.equal(opened[0].roomId, 7n);
  assert.equal(opened[0].type, "task");
  assert.equal(opened[0].id, 42n);
  assert.equal(kanbanShows(), 0);
  assert.equal(noteClears(), 0);
});

test("note links open the concrete note in the inspector without changing views", () => {
  const { linksUI, opened, taskClears } = loadLinksUI();

  linksUI.navigateToTarget(7n, 1, 84n, 2);

  assert.equal(opened.length, 1);
  assert.equal(opened[0].roomId, 7n);
  assert.equal(opened[0].type, "note");
  assert.equal(opened[0].id, 84n);
  assert.equal(taskClears(), 0);
});

test("contact and activity links open typed customer inspectors rather than notes", () => {
  const { linksUI, opened, customerOpened, roomAssets } = loadLinksUI();
  roomAssets.set(0n, new Map([[91n, { assetType: 9 }], [104n, { assetType: 10 }]]));
  linksUI.navigateToTarget(0n, 1, 91n);
  linksUI.navigateToTarget(0n, 1, 104n);
  assert.deepEqual(customerOpened, [["contact", 91n], ["activity", 104n]]);
  assert.deepEqual(opened, []);
});

test("uncached task link targets delegate coalescing to the task loader and re-render with their title", () => {
  const edges = [1n, 2n].map((edgeId) => ({
    edgeId,
    sourceType: 1,
    sourceId: 10n,
    targetType: 2,
    targetId: 240n,
    relation: 1,
  }));
  const requests = [];
  const { linksUI, elements, roomTasks } = loadLinksUI({
    edges,
    onRequestTask(_roomTasks, convId, taskId, options) {
      requests.push({ convId, taskId, options });
      return requests.length;
    },
  });

  linksUI.renderLinks({ convId: 7n, assetId: 10n }, 1);
  linksUI.renderLinks({ convId: 7n, assetId: 10n }, 1);

  assert.equal(requests.length, 2);
  roomTasks.set(7n, new Map([[240n, { id: 240n, title: "Resolved title" }]]));
  requests[1].options.onSuccess();
  const renderedLinks = elements.get("noteLinksList").children;
  assert.equal(renderedLinks.length, 2);
  assert.equal(renderedLinks[0].children[3].textContent, "#240 Resolved title");
  assert.equal(renderedLinks[1].children[3].textContent, "#240 Resolved title");
});

test("link rows carry their kind token and sort tasks before notes and records", () => {
  const edges = [
    { edgeId: 3n, sourceType: 1, sourceId: 10n, targetType: 1, targetId: 91n, relation: 1 },
    { edgeId: 2n, sourceType: 1, sourceId: 10n, targetType: 1, targetId: 40n, relation: 2 },
    { edgeId: 1n, sourceType: 1, sourceId: 10n, targetType: 2, targetId: 240n, relation: 1 },
    { edgeId: 4n, sourceType: 1, sourceId: 10n, targetType: 1, targetId: 12n, relation: 1 },
  ];
  const { linksUI, elements, roomAssets, roomTasks } = loadLinksUI({ edges });
  roomAssets.set(7n, new Map([
    [40n, { assetId: 40n, assetType: 5, preview: JSON.stringify({ title: "Runbook" }) }],
    [91n, { assetId: 91n, assetType: 9, preview: JSON.stringify({ title: "Ada Lovelace" }) }],
    [12n, { assetId: 12n, assetType: 8, preview: JSON.stringify({ title: "Edupool GmbH" }) }],
  ]));
  roomTasks.set(7n, new Map([[240n, { id: 240n, title: "Cut over fastsearch" }]]));

  linksUI.renderLinks({ convId: 7n, assetId: 10n }, 1);

  const rows = elements.get("noteLinksList").children;
  assert.deepEqual(rows.map(row => row.dataset.edgeId), ["1", "2", "4", "3"]);
  assert.deepEqual(rows.map(row => row.children[1].textContent), ["TASK", "NOTE", "COMPANY", "CONTACT"]);
  assert.deepEqual(rows.map(row => row.children[3].textContent), [
    "#240 Cut over fastsearch",
    "Runbook",
    "Edupool GmbH",
    "Ada Lovelace",
  ]);
});

test("cached asset targets without a title fall back to their kind label", () => {
  const edges = [{ edgeId: 1n, sourceType: 1, sourceId: 10n, targetType: 1, targetId: 91n, relation: 1 }];
  const { linksUI, elements, roomAssets } = loadLinksUI({ edges });
  roomAssets.set(7n, new Map([[91n, { assetId: 91n, assetType: 9, preview: "" }]]));

  linksUI.renderLinks({ convId: 7n, assetId: 10n }, 1);

  const row = elements.get("noteLinksList").children[0];
  assert.equal(row.children[1].textContent, "CONTACT");
  assert.equal(row.children[3].textContent, "Contact #91");
});

test("failed linked task requests can be retried", () => {
  const edge = { edgeId: 1n, sourceType: 1, sourceId: 10n, targetType: 2, targetId: 240n, relation: 1 };
  const requests = [];
  const { linksUI } = loadLinksUI({
    edges: [edge],
    onRequestTask(_roomTasks, convId, taskId, options) {
      requests.push({ convId, taskId, options });
      return requests.length;
    },
  });

  linksUI.renderLinks({ convId: 7n, assetId: 10n }, 1);
  linksUI.renderLinks({ convId: 7n, assetId: 10n }, 1);

  assert.equal(requests.length, 2);
});

test("a completed task request cannot replace links for a newer entity", () => {
  const edgesByEntity = new Map([
    [10n, [{ edgeId: 1n, sourceType: 1, sourceId: 10n, targetType: 2, targetId: 240n, relation: 1 }]],
    [11n, [{ edgeId: 2n, sourceType: 1, sourceId: 11n, targetType: 2, targetId: 241n, relation: 1 }]],
  ]);
  let pending;
  const { linksUI, elements, roomTasks } = loadLinksUI({
    getEdgesForEntity: (_convId, _sourceType, entityId) => edgesByEntity.get(entityId),
    onRequestTask(_roomTasks, convId, taskId, options) {
      pending = { convId, taskId, options };
      return 1;
    },
  });

  linksUI.renderLinks({ convId: 7n, assetId: 10n }, 1);
  roomTasks.set(7n, new Map([[241n, { id: 241n, title: "Current task" }]]));
  linksUI.renderLinks({ convId: 7n, assetId: 11n }, 1);
  roomTasks.get(7n).set(240n, { id: 240n, title: "Old task" });
  pending.options.onSuccess();

  const renderedLinks = elements.get("noteLinksList").children;
  assert.equal(renderedLinks.length, 1);
  assert.equal(renderedLinks[0].children[3].textContent, "#241 Current task");
});

test("shared target completion cannot render through a detached links panel", () => {
  for (const targetType of [1, 2]) {
    const requests = [];
    const onRequest = (_room, _id, options) => { requests.push(options); return 1; };
    const f = loadLinksUI({
      getEdgesForEntity: (_room, _type, id) => [{ edgeId: id, sourceType: 1, sourceId: id, targetType, targetId: 240n, relation: 1 }],
      onRequestTask: (_cache, ...args) => onRequest(...args),
      onRequestAsset: onRequest,
    });
    f.linksUI.renderLinks({ convId: 7n, assetId: 10n }, 1);
    f.elements.set("noteLinksList", f.createElement());
    f.linksUI.renderLinks({ convId: 7n, assetId: 11n }, 1);
    assert.equal(requests.length, 2);
    if (targetType === 1) f.roomAssets.set(7n, new Map([[240n, { assetId: 240n, preview: "Loaded" }]]));
    else f.roomTasks.set(7n, new Map([[240n, { id: 240n, title: "Loaded" }]]));
    requests.forEach((request) => request.onSuccess());
    assert.equal(f.elements.get("noteLinksList").children[0].dataset.edgeId, "11");
  }
});

test("detail preparation drains pages and awaits distinct typed targets in both directions", async () => {
  const calls = [];
  const pending = [];
  const session = {};
  let pages = 0;
  const { linksUI } = loadLinksUI({
    edges: [
      { sourceType: 1, sourceId: 99n, targetType: 2, targetId: 10n },
      { sourceType: 2, sourceId: 10n, targetType: 1, targetId: 99n },
      { sourceType: 2, sourceId: 10n, targetType: 2, targetId: 99n },
    ],
    async requestEdgePage(room, type, id, options) {
      assert.deepEqual([room, type, id], [0n, 2, 10n]);
      assert.equal(options.session, pages ? session : undefined);
      return { hasMore: ++pages === 1, session };
    },
    onRequestAsset(room, id, options) { calls.push(["asset", room, id]); pending.push(options.onSuccess); return 1; },
    onRequestTask(_cache, room, id, options) { calls.push(["task", room, id]); pending.push(options.onSuccess); return 2; },
  });
  let ready = false;
  const load = linksUI.loadLinks(0n, 2, 10n, () => false).then(() => { ready = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(pages, 2);
  assert.deepEqual(calls, [["asset", 0n, 99n], ["task", 0n, 99n]]);
  pending[0]();
  await Promise.resolve();
  assert.equal(ready, false, "one target cannot publish the detail");
  pending[1]();
  await load;
  assert.equal(ready, true);
});

test("cancelled detail preparation stops before further pages or target reads", async () => {
  let cancelled = false;
  let pages = 0;
  const { linksUI } = loadLinksUI({
    async requestEdgePage() { pages++; cancelled = true; return { hasMore: true, session: {} }; },
    onRequestAsset() { assert.fail("cancelled load hydrated an asset"); },
    onRequestTask() { assert.fail("cancelled load hydrated a task"); },
  });
  await linksUI.loadLinks(0n, 1, 10n, () => cancelled);
  assert.equal(pages, 1);
});

test("a linked slice is named from its preview, a note from its title", () => {
  const edges = [8n, 9n].map((edgeId, index) => ({
    edgeId,
    sourceType: 2,
    sourceId: 7n,
    targetType: 1,
    targetId: index === 0 ? 40n : 41n,
    relation: 2,
  }));
  const { linksUI, elements, roomAssets } = loadLinksUI({ edges, getEdgesForEntity: () => edges });
  roomAssets.set(0n, new Map([
    [40n, { assetId: 40n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Wartung Nordtor Q4", owner: "rene" }) }],
    [41n, { assetId: 41n, assetType: 5, preview: JSON.stringify({ version: 1, title: "Wartungsplanung Nord" }) }],
  ]));

  linksUI.renderLinks({ convId: 0n, id: 7n }, 2);

  const rows = elements.get("taskDetailLinksList").children.map((item) => item.children.map((child) => child.textContent));
  // Rows sort by kind: notes before the other asset kinds.
  assert.deepEqual(rows.map((cells) => cells[1]), ["NOTE", "SLICE"], "the slice carries its own kind token");
  assert.deepEqual(rows.map((cells) => cells.at(-2)), ["Wartungsplanung Nord", "Wartung Nordtor Q4"]);
  assert.deepEqual(rows.map((cells) => cells.at(-1)), ["×", "×"], "unlink stays available without entering the content editor");
});

test("a linked slice opens the slice record in the task view", () => {
  const { linksUI, roomAssets, sliceSelects, activeViews, kanbanShows } = loadLinksUI({
    slices: [{ sliceId: 40n, name: "Wartung Nordtor Q4" }],
  });
  roomAssets.set(0n, new Map([[40n, { assetId: 40n, assetType: 11, preview: JSON.stringify({ name: "Wartung Nordtor Q4" }) }]]));

  linksUI.navigateToTarget(0n, 1, 40n, 2);

  assert.deepEqual(activeViews, ["kanban"], "the slice lives in the task view");
  assert.equal(sliceSelects.length, 1);
  assert.equal(sliceSelects[0][0], "Wartung Nordtor Q4");
  assert.equal(sliceSelects[0][1].focusDetail, true);
  assert.equal(kanbanShows(), 0, "the slice opens through its own register");
});

test("an unresolved slice id still resolves through the slice register", () => {
  const { linksUI, sliceSelects, sliceLoads, activeViews } = loadLinksUI({ slices: [{ sliceId: 40n, name: "Wartung Nordtor Q4" }] });

  linksUI.navigateToTarget(0n, 1, 40n, 2);

  assert.deepEqual(activeViews, ["kanban"]);
  assert.equal(sliceSelects.length, 1);
  assert.equal(sliceSelects[0][0], "Wartung Nordtor Q4");
  assert.equal(sliceLoads(), 0);
});

test("speculation abandons high-degree notes before paging or hydrating targets", async t => {
  for (const hasMore of [false, true]) {
    await t.test(`first page hasMore=${hasMore}`, async () => {
      let pages = 0;
      const { linksUI } = loadLinksUI({
        edges: Array.from({ length: 5 }, (_, i) => ({ sourceType: 1, sourceId: 10n, targetType: 1, targetId: BigInt(20 + i) })),
        async requestEdgePage(_room, _type, _id, options) {
          pages++;
          assert.equal(options.limit, 5);
          return { hasMore, session: {} };
        },
        onRequestAsset() { assert.fail("over-budget speculation must not hydrate targets"); },
      });
      await assert.rejects(linksUI.loadLinks(0n, 1, 10n, () => false, { prefetch: true }), /speculative .* budget/);
      assert.equal(pages, 1);
    });
  }
});
