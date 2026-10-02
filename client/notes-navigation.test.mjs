import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = fs.readFileSync(path.resolve("client/notes.js"), "utf8");

function makeRow(convId, noteId) {
  const classes = new Set(["note-card"]);
  const marker = { textContent: "" };
  return {
    dataset: { convId: String(convId), noteId: String(noteId) },
    parentElement: null,
    previousElementSibling: null,
    nextElementSibling: null,
    classList: {
      add: (name) => classes.add(name),
      toggle(name, enabled) {
        if (enabled) classes.add(name);
        else classes.delete(name);
      },
      contains: (name) => classes.has(name),
    },
    matches: (selector) => selector === ".note-card[data-note-id]",
    querySelector: (selector) => selector === ".note-marker" ? marker : null,
    marker,
    scrolls: 0,
    scrollIntoView() { this.scrolls += 1; },
  };
}

function loadNotes() {
  const inspectorCalls = [];
  const animationFrames = [];
  let inspectorCurrent = null;
  const notesSearchInput = { value: "" };
  const renderedRows = [];
  const notesList = {
    allowListRender: false,
    renderedRows,
    firstElementChild: null,
    lastElementChild: null,
    set innerHTML(_value) {
      if (!this.allowListRender) throw new Error("selection changes must not rebuild the notes list");
      renderedRows.length = 0;
    },
    querySelector(selector) {
      if (this.allowListRender) return null;
      throw new Error("adjacent navigation should use the tracked row");
    },
    querySelectorAll() { return []; },
    appendChild(row) { renderedRows.push(row); return row; },
  };
  const document = {
    addEventListener() {},
    getElementById(id) {
      if (id === "notesList") return notesList;
      if (id === "notesSearch") return notesSearchInput;
      return null;
    },
    querySelector() { return null; },
    querySelectorAll() { throw new Error("adjacent navigation must not scan every note row"); },
  };
  const window = {
    NRCAssets: {
      AssetType: { Note: 5 },
      roomAssets: new Map(),
      getAssetsByType(convId, type) {
        return Array.from(this.roomAssets.get(convId)?.values() || []).filter((asset) => asset.assetType === type);
      },
      sendGetAsset() { throw new Error("deferred Inspector navigation must not use a bare asset request"); },
    },
    NRCInspector: {
      openEntity(input, options) {
        inspectorCurrent = { ...input, ...options };
        inspectorCalls.push({ input, options });
      },
      current: () => inspectorCurrent,
      setCurrent: (ref) => { inspectorCurrent = ref; },
      hasEntity: () => false,
    },
    NRCPageTitle: { set() {} },
  };
  const hookSource = `${source}\n;globalThis.notesNavigationTest = {
    setSelection(convId, noteId, row) {
      selectedNoteConvId = convId;
      selectedNoteId = noteId;
      selectedNoteRow = row;
      noteRowsByIdentity.set(String(convId) + ":" + String(noteId), row);
    },
    registerRow(convId, noteId, row) {
      noteRowsByIdentity.set(String(convId) + ":" + String(noteId), row);
    },
    updateSelection(previousConvId, previousId, nextConvId, nextId) {
      updateRenderedNoteSelection(previousConvId, previousId, nextConvId, nextId);
    },
    clearSelection() { clearNoteSelection({ fromInspector: true }); },
    selectAdjacent(direction) { return selectAdjacentNote(direction); },
    setInspectorCurrent(ref) { window.NRCInspector.setCurrent(ref); },
    startRenderProbe() {
      let renders = 0;
      let lastOptions = null;
      renderNotesView = (options = {}) => {
        renders += 1;
        lastOptions = options;
        renderedNotesRoomId = 0n;
        notesListDirty = false;
      };
      return {
        renderIfNeeded: () => renderNotesViewIfNeeded(),
        invalidate: (convId) => invalidateNotesList(convId),
        setRoom: (convId) => { currentRoomId = convId; },
        setActive: (active) => { notesViewActive = active; },
        renders: () => renders,
        lastOptions: () => lastOptions,
      };
    },
    renderFiltered(project, tag) {
      document.getElementById("notesList").allowListRender = true;
      notesProjectFilter = project;
      notesTagFilter = tag;
      createNoteCard = (note) => ({ note });
      renderNotesPaginationControls = () => {};
      updateNotesCount = () => {};
      renderNotesLocal(document.getElementById("notesList"), "");
      return document.getElementById("notesList").renderedRows.map((row) => row.note.assetId);
    },
  };`;
  const context = {
    window,
    document,
    currentRoomId: 1n,
    currentWorkspaceId: "workspace",
    requestAnimationFrame(callback) { animationFrames.push(callback); },
    setTimeout,
    clearTimeout,
    closeLinkPicker() {},
    console,
    BigInt,
    Map,
    Set,
  };
  vm.runInNewContext(hookSource, context, { filename: "notes.js" });
  return { context, window, notesList, notesSearchInput, inspectorCalls, animationFrames };
}

test("clearing a note patches only the selected row", () => {
  const { context } = loadNotes();
  const row = makeRow(1n, 10n);
  row.classList.add("note-selected");
  row.marker.textContent = "›";
  context.notesNavigationTest.setSelection(1n, 10n, row);

  context.notesNavigationTest.clearSelection();

  assert.equal(row.classList.contains("note-selected"), false);
  assert.equal(row.marker.textContent, "");
});

test("selecting a note patches its row marker without rebuilding the list", () => {
  const { context } = loadNotes();
  const row = makeRow(1n, 10n);
  context.notesNavigationTest.registerRow(1n, 10n, row);

  context.notesNavigationTest.updateSelection(null, null, 1n, 10n);

  assert.equal(row.classList.contains("note-selected"), true);
  assert.equal(row.marker.textContent, "›");
});

test("reopening an unchanged notes list reuses its rendered rows", () => {
  const { context, notesSearchInput } = loadNotes();
  const probe = context.notesNavigationTest.startRenderProbe();

  probe.renderIfNeeded();
  probe.renderIfNeeded();
  assert.equal(probe.renders(), 1);

  probe.invalidate(2n);
  probe.renderIfNeeded();
  assert.equal(probe.renders(), 1, "another room cannot invalidate the rendered list");

  probe.invalidate(0n);
  probe.renderIfNeeded();
  assert.equal(probe.renders(), 2, "a changed note cache is rendered on reopen");

  probe.setRoom(2n);
  probe.renderIfNeeded();
  assert.equal(probe.renders(), 2, "switching chats preserves workspace rows");

  notesSearchInput.value = "pending query";
  probe.renderIfNeeded();
  probe.renderIfNeeded();
  assert.equal(probe.renders(), 4, "search results are asynchronous and must not use the local-list cache");
});

test("an exact note fetch invalidates a retained list when it cannot patch membership", () => {
  const { context } = loadNotes();
  const probe = context.notesNavigationTest.startRenderProbe();
  probe.renderIfNeeded();

  context.window.NRCAssets.roomAssets.set(0n, new Map());
  context.window.NRCAssets.roomAssets.get(0n).set(99n, {
    convId: 0n, assetId: 99n, assetType: 5, payload: "full", preview: "Fetched note",
  });
  vm.runInContext("handleNoteChanged(window.NRCAssets.roomAssets.get(0n).get(99n), 'fetched')", context);
  probe.renderIfNeeded();

  assert.equal(probe.renders(), 2);
});

test("payload hydration keeps a retained note list valid when list fields are unchanged", () => {
  const { context } = loadNotes();
  const probe = context.notesNavigationTest.startRenderProbe();
  probe.renderIfNeeded();
  const previous = {
    convId: 0n, assetId: 99n, assetType: 5, payload: null, preview: "Same note",
    owner: "tester", createdAt: 1n, updatedAt: 2n,
  };
  const fetched = { ...previous, payload: "full" };
  context.window.NRCAssets.roomAssets.set(0n, new Map([[99n, fetched]]));
  context.previous = previous;
  vm.runInContext("handleNoteChanged(window.NRCAssets.roomAssets.get(0n).get(99n), 'fetched', previous)", context);
  probe.renderIfNeeded();

  assert.equal(probe.renders(), 1);
});

test("a note page rebuilds instead of appending across an outstanding invalidation", () => {
  const { context } = loadNotes();
  const probe = context.notesNavigationTest.startRenderProbe();
  probe.setActive(true);
  probe.renderIfNeeded();

  context.window.NRCAssets.roomAssets.set(0n, new Map([[99n, {
    convId: 0n, assetId: 99n, assetType: 5, payload: "full", preview: "Fetched note",
  }]]));
  vm.runInContext("handleNoteChanged(window.NRCAssets.roomAssets.get(0n).get(99n), 'fetched')", context);
  vm.runInContext("handleNoteChanged({ convId: 0n, count: 25, hasMore: true, nextCursorUpdatedAt: 1n, nextCursorAssetId: 1n, totalCount: 100 }, 'list_page')", context);

  assert.equal(probe.lastOptions().append, false);
});

test("local project and tag filters exclude unrelated notes added through shared asset cache", () => {
  const { context, window } = loadNotes();
  const preview = (title, project, tags) => JSON.stringify({ title, project, tags });
  window.NRCAssets.roomAssets.set(0n, new Map([
    [1n, { convId: 0n, assetId: 1n, assetType: 5, preview: preview("match", "Apollo", ["urgent"]) }],
    [2n, { convId: 0n, assetId: 2n, assetType: 5, preview: preview("wrong project", "Gemini", ["urgent"]) }],
    [3n, { convId: 0n, assetId: 3n, assetType: 5, preview: preview("wrong tag", "Apollo", ["later"]) }],
    [4n, { convId: 0n, assetId: 4n, assetType: 8, preview: preview("customer", "Apollo", ["urgent"]) }],
  ]));

  assert.deepEqual(Array.from(context.notesNavigationTest.renderFiltered("Apollo", "urgent")), [1n]);
});

test("adjacent note navigation follows sibling rows and requests deferred replacement", () => {
  const { context, window, notesList, inspectorCalls, animationFrames } = loadNotes();
  const first = makeRow(0n, 10n);
  const second = makeRow(0n, 20n);
  const third = makeRow(0n, 30n);
  first.nextElementSibling = second;
  second.previousElementSibling = first;
  second.nextElementSibling = third;
  third.previousElementSibling = second;
  for (const row of [first, second, third]) row.parentElement = notesList;
  notesList.firstElementChild = first;
  notesList.lastElementChild = third;
  window.NRCAssets.roomAssets.set(0n, new Map([
    [10n, { convId: 0n, assetId: 10n, assetType: 5, payload: null }],
    [20n, { convId: 0n, assetId: 20n, assetType: 5, payload: null }],
    [30n, { convId: 0n, assetId: 30n, assetType: 5, payload: null }],
  ]));
  for (const row of [first, second, third]) {
    context.notesNavigationTest.registerRow(0n, BigInt(row.dataset.noteId), row);
  }
  context.notesNavigationTest.setSelection(0n, 20n, second);

  assert.equal(context.notesNavigationTest.selectAdjacent(1), true);
  assert.equal(inspectorCalls.length, 1);
  assert.equal(inspectorCalls[0].input.id, 30n);
  assert.equal(inspectorCalls[0].options.deferDetail, true);
  assert.equal(inspectorCalls[0].options.replaceCurrent, true);
  for (const callback of animationFrames) callback();
  assert.equal(third.scrolls, 1);
});

test("settled deferred navigation reopens the current Inspector entity after cache eviction", async () => {
  const { context, window, inspectorCalls } = loadNotes();
  const note = { convId: 1n, assetId: 44n, assetType: 5, payload: null };
  window.NRCAssets.roomAssets.set(1n, new Map([[44n, note]]));
  context.notesNavigationTest.setInspectorCurrent({ roomId: 1n, type: "note", id: 44n, deferDetail: true });

  window.NRCNotes.selectNote(note, { fromInspector: true, deferDetail: true });
  assert.equal(inspectorCalls.length, 0);
  window.NRCAssets.roomAssets.get(1n).delete(44n);
  await new Promise((resolve) => setTimeout(resolve, 100));

  assert.equal(inspectorCalls.length, 1);
  assert.equal(inspectorCalls[0].input.id, 44n);
  assert.equal(inspectorCalls[0].options.deferDetail, false);
  assert.equal(inspectorCalls[0].options.replaceCurrent, true);
});

test("prefetch follows only immediate neighbours in normal and 897-row virtual lists", () => {
  const { context, window, notesList } = loadNotes();
  const prefetched = [];
  window.NRCInspector.prefetchNote = ref => prefetched.push(BigInt(ref.id));
  context.notesNavigationTest.startRenderProbe().setActive(true);
  const row = makeRow(0n, 1450n);
  row.isConnected = true;
  row.previousElementSibling = makeRow(0n, 33n);
  row.nextElementSibling = makeRow(0n, 71n);
  context.notesNavigationTest.setSelection(0n, 1450n, row);
  context.prefetchAdjacentNotes();
  assert.deepEqual(prefetched, [33n, 71n]);

  prefetched.length = 0;
  notesList.virtualList = { items: Array.from({ length: 897 }, (_, i) => ({ convId: 0n, assetId: BigInt(1000 + i) })) };
  row.dataset.virtualIndex = "450";
  context.prefetchAdjacentNotes();
  assert.deepEqual(prefetched, [1449n, 1451n], "virtual data order, not mounted siblings, determines neighbours");
  prefetched.length = 0;
  row.dataset.virtualIndex = "0";
  context.prefetchAdjacentNotes();
  assert.deepEqual(prefetched, [1001n], "no wraparound at the list boundary");
  prefetched.length = 0;
  row.isConnected = false;
  context.prefetchAdjacentNotes();
  assert.deepEqual(prefetched, [], "an unmounted selection must not speculate");
});

test("neighbour prefetch waits for selection to settle and cancels the previous timer", t => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { context, window } = loadNotes();
  const prefetched = [];
  window.NRCInspector.prefetchNote = ref => prefetched.push(BigInt(ref.id));
  context.notesNavigationTest.startRenderProbe().setActive(true);
  const rows = [10n, 20n, 30n, 40n].map(id => makeRow(0n, id));
  rows.forEach((row, i) => {
    row.isConnected = true;
    row.previousElementSibling = rows[i - 1];
    row.nextElementSibling = rows[i + 1];
    context.notesNavigationTest.registerRow(0n, BigInt(row.dataset.noteId), row);
  });
  context.notesNavigationTest.setSelection(0n, 10n, rows[0]);
  const select = id => window.NRCNotes.selectNote({ convId: 0n, assetId: id }, { fromInspector: true, loadDetail: false });
  select(20n);
  t.mock.timers.tick(99);
  assert.deepEqual(prefetched, []);
  select(30n);
  t.mock.timers.tick(99);
  assert.deepEqual(prefetched, [], "the previous selection timer must be cancelled");
  t.mock.timers.tick(1);
  assert.deepEqual(prefetched, [20n, 40n]);
});
