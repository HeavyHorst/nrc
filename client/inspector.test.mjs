import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = fs.readFileSync(path.resolve("client/inspector.js"), "utf8");
const flush = () => new Promise(resolve => setImmediate(resolve));

function loadInspector() {
  const selected = [];
  const cleared = [];
  const events = new Map();
  const roomTasks = new Map([
    [0n, new Map([
      [10n, { convId: 0n, id: 10n }],
      [20n, { convId: 0n, id: 20n }],
    ])],
  ]);
  const document = {
    body: { classList: { contains: () => false, toggle() {}, remove() {} } },
    activeElement: null,
    addEventListener(type, listener) { events.set(type, listener); },
    getElementById() { return null; },
    querySelector() { return null; },
  };
  const window = {
    NRCLinksUI: { loadLinks: async () => {} },
    NRCAssets: { roomAssets: new Map([[0n, new Map([[90n, { assetId: 90n, payload: "" }]])]]) },
    NRCTasks: {
      roomTasks,
      selectTask: (task, options) => { if (options.loadDetail !== false) selected.push(task.id); },
      clearTaskSelection: () => cleared.push("task"),
      confirmDiscardTaskEdits: () => true,
    },
  };
  const context = {
    window,
    document,
    currentRoomId: 1n,
    AssetType: { Note: 5 },
    ws: {},
    serverReady: true,
    Date: { now: () => 1000 },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    requestAnimationFrame: (callback) => callback(),
    setTimeout,
    clearTimeout,
    console,
    BigInt,
  };
  vm.runInNewContext(source, context, { filename: "inspector.js" });
  return { inspector: window.NRCInspector, selected, cleared, window, events, context };
}

function loadInspectorShortcuts(entityHost = null) {
  const listeners = new Map();
  const controls = new Map();
  const roomTasks = new Map([[0n, new Map([[10n, { convId: 0n, id: 10n }]])]]);
  const document = {
    body: { classList: { contains: () => false, toggle() {}, remove() {} } },
    activeElement: null,
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(listener);
    },
    getElementById(id) { return id === "inspectorEntityHost" ? entityHost : null; },
    querySelector(selector) { return controls.get(selector) || null; },
  };
  const window = {
    NRCLinksUI: { loadLinks: async () => {} },
    NRCTasks: {
      roomTasks,
      selectTask() {},
      clearTaskSelection() {},
      confirmDiscardTaskEdits: () => true,
    },
  };
  vm.runInNewContext(source, {
    window,
    document,
    currentRoomId: 1n,
    requestAnimationFrame: (callback) => callback(),
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    setTimeout,
    clearTimeout,
    console,
    BigInt,
  }, { filename: "inspector.js" });
  listeners.get("DOMContentLoaded")[0]();

  function addControl(selector) {
    const control = {
      clicks: 0,
      disabled: false,
      getAttribute: () => null,
      click() { this.clicks += 1; },
    };
    controls.set(`#inspectorHeader ${selector}`, control);
    return control;
  }

  function press(key, overrides = {}) {
    const event = {
      key,
      target: { tagName: "DIV", isContentEditable: false },
      defaultPrevented: false,
      repeat: false,
      ctrlKey: false,
      altKey: false,
      metaKey: false,
      shiftKey: false,
      propagationStopped: false,
      preventDefault() { this.defaultPrevented = true; },
      stopImmediatePropagation() { this.propagationStopped = true; },
      ...overrides,
    };
    for (const listener of listeners.get("keydown")) listener(event);
    return event;
  }

  return { inspector: window.NRCInspector, addControl, press };
}

function makeTestNode() {
  return {
    children: [],
    className: "",
    hidden: false,
    textContent: "",
    querySelectorAll() { return []; },
    setAttribute(name, value) { this[name] = value; },
    hasChildNodes() { return this.children.length > 0; },
    append(...children) { this.children.push(...children); },
    replaceChildren(...children) { this.children = children; },
  };
}

test("Notes context renders aligned scope bands and an explicit empty selection", () => {
  const header = makeTestNode();
  const inspector = makeTestNode();
  inspector.classList = { toggle() {} };
  const chatHost = makeTestNode();
  const viewHost = makeTestNode();
  const entityHost = makeTestNode();
  const elements = new Map([
    ["inspector", inspector],
    ["inspectorHeader", header],
    ["inspectorChatContextHost", chatHost],
    ["inspectorViewContextHost", viewHost],
    ["inspectorEntityHost", entityHost],
    ["notesProjectFilter", { selectedOptions: [{ textContent: "ALL" }] }],
    ["notesTagFilter", { selectedOptions: [{ textContent: "ALL TAGS" }] }],
    ["notesSearch", { value: "" }],
    ["notesCount", { textContent: "27 RESULTS" }],
  ]);
  const document = {
    body: { classList: { contains: () => false, toggle() {}, remove() {} } },
    activeElement: null,
    addEventListener() {},
    createElement: makeTestNode,
    getElementById: (id) => elements.get(id) || null,
    querySelector() { return null; },
  };
  const window = {};
  vm.runInNewContext(source, {
    window,
    document,
    currentRoomId: 1n,
    requestAnimationFrame: (callback) => callback(),
    setTimeout,
    clearTimeout,
    console,
    BigInt,
  }, { filename: "inspector.js" });

  window.NRCInspector.setActiveView("notes");

  assert.equal(viewHost.children.length, 2);
  assert.equal(viewHost.children[0].children[0].textContent, "CURRENT STATE");
  assert.equal(viewHost.children[1].children[0].textContent, "SELECTION");
  assert.equal(viewHost.children[1].children[1].textContent, "NO NOTE SELECTED");
  assert.equal(viewHost.children[1].children[2].textContent, "Select a note to inspect its content.");
  assert.equal(header.children[1].className, "inspector-mode-row inspector-context-scope inspector-context-scope--summary");
  assert.equal(header.children[1].children[0].textContent, "SCOPE / VIEW");
  assert.equal(header.children[1].children[1].textContent, "WORKSPACE · NOTES");
});

test("System Log selection renders complete event context and controls empty rail state", () => {
  const classes = new Set();
  const header = makeTestNode();
  const chatHost = makeTestNode();
  const viewHost = makeTestNode();
  const entityHost = makeTestNode();
  const elements = new Map([
    ["inspectorHeader", header],
    ["inspectorChatContextHost", chatHost],
    ["inspectorViewContextHost", viewHost],
    ["inspectorEntityHost", entityHost],
  ]);
  const document = {
    body: {
      classList: {
        contains: (name) => classes.has(name),
        toggle(name, force) { if (force) classes.add(name); else classes.delete(name); },
        remove: (name) => classes.delete(name),
      },
    },
    activeElement: null,
    addEventListener() {},
    createElement: makeTestNode,
    getElementById: (id) => elements.get(id) || null,
    querySelector() { return null; },
  };
  const window = {};
  vm.runInNewContext(source, {
    window,
    document,
    currentRoomId: 1n,
    requestAnimationFrame: (callback) => callback(),
    setTimeout,
    clearTimeout,
    console,
    BigInt,
    Date,
  }, { filename: "inspector.js" });

  window.NRCInspector.setActiveView("systemLog");
  assert.equal(classes.has("system-log-inspector-empty"), true);

  window.NRCInspector.showSystemLogEntry({
    id: 17,
    timestamp: new Date(2026, 7, 30, 22, 9, 8, 482).getTime(),
    level: "WARN",
    source: "websocket",
    message: "Complete event message without table truncation",
  });

  assert.equal(classes.has("system-log-inspector-empty"), false);
  assert.equal(header.children[0].children[0].textContent, "EVENT #17");
  assert.equal(header.children[0].children[2].textContent, "WARN");
  assert.equal(viewHost.children[1].children[1].textContent, "Complete event message without table truncation");

  window.NRCInspector.showSystemLogEntry(null);
  assert.equal(classes.has("system-log-inspector-empty"), true);
});

test("opening an unloaded task hydrates it before detail navigation", async () => {
  let requested = null;
  const roomTasks = new Map([[0n, new Map()]]);
  const selectedTasks = [];
  const document = {
    body: { classList: { contains: () => false, toggle() {}, remove() {} } },
    activeElement: null,
    addEventListener() {},
    getElementById() { return null; },
    querySelector() { return null; },
  };
  const testWindow = {
    NRCLinksUI: { loadLinks: async () => {} },
    NRCTasks: {
      roomTasks,
      selectTask: (task) => selectedTasks.push(task),
      clearTaskSelection() {},
      confirmDiscardTaskEdits: () => true,
      requestTask: (roomId, taskId, options) => {
        requested = { roomId, taskId };
        const task = { convId: roomId, id: taskId, status: 3, title: "Unloaded Done task" };
        roomTasks.get(roomId).set(taskId, task);
        options.onSuccess({ task });
      },
    },
  };
  vm.runInNewContext(source, {
    window: testWindow,
    document,
    currentRoomId: 1n,
    requestAnimationFrame: (callback) => callback(),
    setTimeout,
    clearTimeout,
    console,
    BigInt,
  }, { filename: "inspector.js" });

  await testWindow.NRCInspector.openEntity({ roomId: 1n, type: "task", id: 99n });
  await flush();
  assert.deepEqual(requested, { roomId: 0n, taskId: 99n });
  assert.equal(roomTasks.get(0n).get(99n).title, "Unloaded Done task");
  assert.equal(selectedTasks[0].id, 99n);
});

test("an older room-change confirmation cannot override a newer intent", async () => {
  const { inspector } = loadInspector();
  let continued = false;
  const pending = inspector.requestRoomChange(2n, () => { continued = true; });
  inspector.beginExternalLoad();
  assert.equal(await pending, false);
  assert.equal(continued, false);
});

test("deleted entities are removed from Inspector history", async () => {
  const { inspector, cleared } = loadInspector();
  await inspector.openEntity({ roomId: 1n, type: "task", id: 10n });
  await inspector.openEntity({ roomId: 1n, type: "task", id: 20n });
  assert.equal(inspector.entityDeleted({ roomId: 1n, type: "task", id: 20n }), true);
  assert.equal(inspector.current().id, 10n);
  assert.deepEqual(cleared, ["task", "task"]);
  assert.equal(inspector.entityDeleted({ roomId: 1n, type: "task", id: 20n }), false);
});

test("customer types participate in inspector history, disposal guards and deletion", async () => {
  for (const type of ["company", "contact", "activity"]) {
    const { inspector, window, cleared } = loadInspector();
    const rendered = [];
    let dispose = true;
    window.NRCCustomers = {
      showInspector: ref => rendered.push([ref.type, ref.id]),
      clearSelection: () => cleared.push(type),
      confirmDiscardEdits: () => dispose,
    };
    await inspector.openEntity({ type: "task", id: 10n });
    await inspector.openEntity({ type, id: 90n });
    await flush();
    assert.deepEqual(rendered, [[type, 90n]]);
    dispose = false;
    assert.equal(await inspector.close(), false);
    assert.equal(await inspector.back(), false);
    assert.equal(await inspector.openEntity({ type: "task", id: 20n }), false);
    assert.equal(await inspector.requestWorkspaceChange("other", () => assert.fail("draft was discarded")), false);
    assert.equal(inspector.current().id, 90n);
    dispose = true;
    await inspector.openEntity({ type: "task", id: 20n });
    await inspector.back();
    await flush();
    assert.deepEqual(rendered, [[type, 90n], [type, 90n]]);
    inspector.entityDeleted({ type, id: 90n });
    assert.equal(inspector.current().id, 10n);
    assert.equal(cleared.filter(value => value === type).length, 2);
  }
});

test("deleting another customer does not invalidate the current entity load", async () => {
  const { inspector, window, selected } = loadInspector();
  window.NRCCustomers = { showInspector() {}, clearSelection() {}, confirmDiscardEdits: () => true };
  await inspector.openEntity({ type: "contact", id: 90n });
  let finish;
  window.NRCTasks.requestTask = (_room, _id, options) => { finish = options.onSuccess; };
  await inspector.openEntity({ type: "task", id: 99n });
  assert.equal(inspector.entityDeleted({ type: "contact", id: 100n }), false);
  assert.equal(inspector.entityDeleted({ type: "contact", id: 90n }), true);
  finish({ task: { convId: 0n, id: 99n } });
  await flush();
  assert.deepEqual(selected, [99n]);
});

test("replacing an inspected list entity does not grow history or clear same-type selection", async () => {
  const { inspector, cleared } = loadInspector();
  await inspector.openEntity({ roomId: 1n, type: "task", id: 10n });
  await inspector.openEntity(
    { roomId: 1n, type: "task", id: 20n },
    { replaceCurrent: true },
  );

  assert.equal(inspector.current().id, 20n);
  assert.deepEqual(cleared, []);
  await inspector.back();
  assert.equal(inspector.current(), null, "replacement must not leave the prior row in history");
  assert.deepEqual(cleared, ["task"]);
});

test("entity shortcuts activate only the available inspector matrix controls", async () => {
  const { inspector, addControl, press } = loadInspectorShortcuts();
  const detail = addControl('[data-tab="detail"]');
  const comments = addControl('[data-tab="comments"]');
  const edit = addControl('[data-inspector-command="e"]');
  const share = addControl('[data-inspector-command="s"]');
  await inspector.openEntity({ roomId: 1n, type: "task", id: 10n });
  await flush();

  for (const [key, control] of [["1", detail], ["2", comments], ["e", edit], ["s", share]]) {
    const event = press(key);
    assert.equal(control.clicks, 1, `${key} should click its matrix control`);
    assert.equal(event.defaultPrevented, true);
    assert.equal(event.propagationStopped, true);
  }

  const unavailable = press("v");
  assert.equal(unavailable.defaultPrevented, false);
  assert.equal(unavailable.propagationStopped, false);
});

test("M reaches the record message block instead of the header", async () => {
  const strip = { clicks: 0, disabled: false, getAttribute: () => null, click() { this.clicks += 1; } };
  const composerBar = { clicks: 0, disabled: false, getAttribute: () => null, click() { this.clicks += 1; } };
  const area = {
    dataset: { messagesOpen: "false" },
    querySelector: (selector) => selector === "[data-messages-toggle]"
      ? strip
      : selector === "[data-composer-toggle]"
        ? composerBar
        : null,
  };
  const host = {
    querySelector: (selector) => (selector === "[data-messages-area]" ? area : null),
    setAttribute() {},
    hasChildNodes: () => true,
    replaceChildren() {},
    append() {},
  };
  const { inspector, press } = loadInspectorShortcuts(host);
  await inspector.openEntity({ roomId: 1n, type: "task", id: 10n });
  await flush();

  // M means "write a message": it opens the composer, which opens the block
  // first when the panel is too narrow to show the messages column.
  const closed = press("m");
  assert.equal(composerBar.clicks, 1, "M opens the composer");
  assert.equal(strip.clicks, 0, "M never toggles the block itself");
  assert.equal(closed.defaultPrevented, true);
  assert.equal(closed.propagationStopped, true);

  area.dataset.messagesOpen = "true";
  press("m");
  assert.equal(composerBar.clicks, 2, "M focuses the composer in an open block too");
  assert.equal(strip.clicks, 0);
});

test("entity shortcuts preserve browser commands and editable controls", async () => {
  const { inspector, addControl, press } = loadInspectorShortcuts();
  const share = addControl('[data-inspector-command="s"]');
  await inspector.openEntity({ roomId: 1n, type: "task", id: 10n });
  await flush();

  const browserShortcut = press("s", { ctrlKey: true });
  const macBrowserShortcut = press("s", { metaKey: true });
  const altShortcut = press("s", { altKey: true });
  const shiftedShortcut = press("S", { shiftKey: true });
  const repeatedShortcut = press("s", { repeat: true });
  const inputTyping = press("s", { target: { tagName: "INPUT", isContentEditable: false } });
  const textareaTyping = press("s", { target: { tagName: "TEXTAREA", isContentEditable: false } });
  const contentEditableTyping = press("s", { target: { tagName: "DIV", isContentEditable: true } });

  assert.equal(share.clicks, 0);
  for (const event of [browserShortcut, macBrowserShortcut, altShortcut, shiftedShortcut, repeatedShortcut, inputTyping, textareaTyping, contentEditableTyping]) {
    assert.equal(event.defaultPrevented, false);
    assert.equal(event.propagationStopped, false);
  }
});

test("share command remains available while Notes is active", async () => {
  const { inspector, addControl, press } = loadInspectorShortcuts();
  const share = addControl('[data-inspector-command="s"]');
  await inspector.openEntity({ roomId: 1n, type: "task", id: 10n });
  await flush();
  inspector.setActiveView("notes");

  assert.equal(share.disabled, false);
  const event = press("s");
  assert.equal(share.clicks, 1);
  assert.equal(event.defaultPrevented, true);
  assert.equal(event.propagationStopped, true);
});

for (const first of ["body", "links", "links-error"]) {
test(`preview-only notes load body and links concurrently (${first} first)`, async () => {
  const entityHost = makeTestNode();
  const chatHost = makeTestNode();
  const viewHost = makeTestNode();
  const header = makeTestNode();
  header.controls = [{ stale: true }];
  header.replaceChildren = function (...children) {
    this.children = children;
    this.controls = [];
  };
  const share = { disabled: false };
  let pendingRequest = null;
  let pendingLinks = null;
  const selections = [];
  const previewOnlyNote = { convId: 0n, assetId: 44n, assetType: 5, payload: null };
  const document = {
    body: { classList: { contains: () => false, toggle() {}, remove() {} } },
    activeElement: null,
    addEventListener() {},
    createElement: makeTestNode,
    getElementById(id) {
      if (id === "inspectorHeader") return header;
      if (id === "inspectorEntityHost") return entityHost;
      if (id === "inspectorChatContextHost") return chatHost;
      if (id === "inspectorViewContextHost") return viewHost;
      return null;
    },
    querySelector(selector) {
      if (selector === '#inspectorHeader [data-inspector-command="s"]') {
        return header.controls.includes(share) ? share : null;
      }
      return null;
    },
  };
  const window = {
    NRCLinksUI: { loadLinks: () => new Promise((resolve, reject) => { pendingLinks = { resolve, reject }; }) },
    NRCAssets: {
      roomAssets: new Map([[0n, new Map([[44n, previewOnlyNote]])]]),
      requestAsset: (_roomId, _assetId, options) => { pendingRequest = options; },
    },
    NRCNotes: {
      selectNote(_note, options) {
        selections.push(options);
        if (options.loadDetail !== false) header.controls = [share];
      },
      clearNoteSelection() {},
      confirmDiscardEdits: () => true,
    },
  };
  vm.runInNewContext(source, {
    window,
    document,
    currentRoomId: 1n,
    AssetType: { Note: 5 },
    requestAnimationFrame: (callback) => callback(),
    setTimeout,
    clearTimeout,
    console,
    BigInt,
    Promise,
  }, { filename: "inspector.js" });

  window.NRCInspector.setActiveView("notes");
  await window.NRCInspector.openEntity({ roomId: 1n, type: "note", id: 44n });
  assert.ok(pendingRequest, "preview-only note should be hydrated by Inspector");
  assert.ok(pendingLinks, "relationships must start before the body response arrives");
  assert.equal(selections.length, 1);
  assert.equal(selections[0].loadDetail, false, "preview selection should update before hydration");
  assert.equal(header.controls.length, 0, "loading header must remove previous controls");

  const hydrated = { ...previewOnlyNote, payload: "Full note" };
  const finishBody = () => pendingRequest.onSuccess({ asset: hydrated });
  const finishLinks = () => first === "links-error"
    ? pendingLinks.reject(new Error("Relationship read failed")) : pendingLinks.resolve();
  (first === "body" ? finishBody : finishLinks)();
  await flush();
  assert.equal(selections.length, 1, "partial results must not publish the detail");
  assert.equal(window.NRCInspector.isLoading(), true, "pending reads must keep broadcast-driven renders blocked, even on failure");
  (first === "body" ? finishLinks : finishBody)();
  await flush();
  assert.equal(window.NRCInspector.isLoading(), false);
  if (first === "links-error") {
    assert.equal(selections.length, 1, "failed relationships must not publish a partial note");
    assert.equal(entityHost.children.at(-1).textContent, "RETRY");
  } else {
    assert.equal(selections.length, 2);
    assert.notEqual(selections[1].loadDetail, false);
    assert.equal(share.disabled, false);
  }

  await window.NRCInspector.close();
  pendingRequest = null;
  pendingLinks = null;
  selections.length = 0;
  await window.NRCInspector.openEntity(
    { roomId: 1n, type: "note", id: 44n },
    { deferDetail: true },
  );
  assert.equal(pendingRequest, null, "deferred navigation must not hydrate immediately");
  assert.equal(pendingLinks, null, "deferred navigation must not fetch relationships immediately");
  assert.equal(selections.length, 1);
  assert.equal(selections[0].deferDetail, true);

  await window.NRCInspector.openEntity(
    { roomId: 1n, type: "note", id: 44n },
    { deferDetail: false, replaceCurrent: true },
  );
  assert.equal(window.NRCInspector.current().deferDetail, false);
  assert.ok(pendingRequest, "settled navigation should use Inspector hydration and error handling");
});
}

// A file reference is opened by the slice record like any other member, so the
// inspector has to route it to the file renderer instead of reporting an
// unsupported type.
test("a file reference reaches the file inspector", async () => {
  const { inspector, window } = loadInspector();
  const opened = [];
  window.NRCFiles = { showInspector: (ref) => opened.push(`${ref.type}:${ref.id}`) };
  const result = await inspector.openEntity({ roomId: 0n, type: "file", id: 7n });
  await flush();
  assert.equal(result, true);
  assert.deepEqual(opened, ["file:7"], "the file renderer owns the reference");
});

test("a reference type the inspector does not know stays unsupported", async () => {
  const { inspector, window } = loadInspector();
  const opened = [];
  window.NRCFiles = { showInspector: (ref) => opened.push(`${ref.type}:${ref.id}`) };
  const result = await inspector.openEntity({ roomId: 0n, type: "sprocket", id: 7n });
  await flush();
  assert.equal(result, true);
  assert.deepEqual(opened, [], "an unknown type must not reach the file renderer");
});

function loadNotePrefetchInspector() {
  const fixture = loadInspector();
  const { window, events, inspector } = fixture;
  const bodies = [], links = [], rendered = [], selections = [];
  const assets = new Map();
  window.NRCAssets.roomAssets.set(0n, assets);
  window.NRCAssets.requestAsset = (_room, id, options) => bodies.push({ id, options });
  window.NRCLinksUI.loadLinks = (_room, _type, id, cancelled) => new Promise((resolve, reject) => {
    links.push({ id, resolve, reject, cancelled });
  });
  window.NRCNotes = {
    selectNote(note, options) {
      selections.push(options);
      if (options.loadDetail !== false && !options.deferDetail) rendered.push(note.assetId);
    },
    clearNoteSelection() {},
    confirmDiscardEdits: () => true,
  };
  let edgeListener;
  window.NRCEdges = { addEdgeChangeListener: listener => { edgeListener = listener; } };
  events.get("DOMContentLoaded")();
  const ref = id => ({ roomId: 0n, type: "note", id });
  const finish = async (id) => {
    for (const body of bodies.filter(body => body.id === id && !body.finished)) {
      body.finished = true;
      const asset = { convId: 0n, assetId: id, assetType: 5, payload: `Body ${id}` };
      assets.set(id, asset);
      body.options.onSuccess({ asset });
    }
    for (const link of links.filter(link => link.id === id)) link.resolve();
    await flush();
  };
  return { ...fixture, bodies, links, rendered, selections, assets, finish,
    prefetch: id => inspector.prefetchNote(ref(id)),
    open: (id, options = {}) => inspector.openEntity(ref(id), { replaceCurrent: true, ...options }),
    edgeMutation: action => edgeListener({}, action),
  };
}

test("click adopts an in-flight prefetch; completed prefetch bypasses keyboard delay", async () => {
  const f = loadNotePrefetchInspector();
  f.prefetch(1n); f.prefetch(1n);
  assert.equal(f.bodies.length, 1);
  assert.equal(f.links.length, 1);
  assert.deepEqual(f.rendered, [], "prefetch never selects a note");
  await f.open(1n);
  assert.equal(f.links.length, 1, "click must not duplicate edge reads");
  assert.equal(f.inspector.isLoading(), true);
  await f.finish(1n);
  assert.deepEqual(f.rendered, [1n]);

  f.prefetch(2n);
  await f.finish(2n);
  await f.open(2n, { deferDetail: true });
  await flush();
  assert.deepEqual(f.rendered, [1n, 2n]);
  assert.equal(f.links.length, 2, "warm keyboard selection needs no network read");
  assert.equal(f.selections.some(options => options.deferDetail), false);
});

test("prefetch bounds work independently of list size and retries a failed speculative read", async () => {
  const f = loadNotePrefetchInspector();
  for (let id = 1n; id <= 897n; id++) f.prefetch(id);
  assert.equal(f.bodies.length, 2, "at most two speculative reads may be in flight");
  assert.equal(f.links.length, 2);
  f.links[0].reject(new Error("Transient failure"));
  await f.finish(1n);
  await f.finish(2n);
  assert.deepEqual(f.rendered, []);
  await f.open(1n);
  assert.equal(f.links.length, 3, "a failed prefetch must not poison a real selection");
  await f.finish(1n);
  assert.deepEqual(f.rendered, [1n]);
});

test("prefetch is invalidated by mutations, expiry, reconnect and asset-cache replacement", async t => {
  const invalidations = {
    "edge created": f => f.edgeMutation("created"),
    "edge deleted": f => f.edgeMutation("deleted"),
    "asset changed": f => f.events.get("nrc:asset-updated")(),
    "asset deleted": f => f.events.get("nrc:asset-deleted")(),
    "task changed": f => f.events.get("nrc:task-changed")(),
    "expiry": f => { f.context.Date.now = () => 11000; },
    "reconnect": f => { f.context.ws = {}; },
    "cache replacement": f => { f.assets.set(1n, { ...f.assets.get(1n), payload: "New body" }); },
  };
  for (const [name, invalidate] of Object.entries(invalidations)) {
    await t.test(name, async () => {
      const f = loadNotePrefetchInspector();
      f.prefetch(1n); await f.finish(1n);
      invalidate(f);
      await f.open(1n);
      assert.equal(f.links.length, 2, "invalidated relationships must be read again");
      assert.deepEqual(f.rendered, []);
      await f.finish(1n);
      assert.deepEqual(f.rendered, [1n]);
    });
  }
});

test("invalidated or stale in-flight prefetch cannot publish partial or wrong details", async () => {
  const f = loadNotePrefetchInspector();
  f.prefetch(1n);
  await f.open(1n);
  f.edgeMutation("created");
  assert.equal(f.links[0].cancelled(), true);
  await f.finish(1n);
  assert.equal(f.links.length, 2, "invalidation during adoption triggers a fresh read");
  assert.deepEqual(f.rendered, []);
  await f.open(2n);
  await f.finish(2n);
  await f.finish(1n);
  assert.deepEqual(f.rendered, [2n], "old completion must not overwrite a newer selection");
});

test("adopted pending prefetch survives capacity eviction and speculative expiry", async () => {
  const f = loadNotePrefetchInspector();
  f.prefetch(1n);
  for (const id of [2n, 3n, 4n]) { f.prefetch(id); await f.finish(id); }
  await f.open(1n);
  f.prefetch(5n);
  assert.equal(f.links[0].cancelled(), false, "new hover must evict an unselected entry, not the clicked one");
  f.context.Date.now = () => 11000;
  assert.equal(f.links[0].cancelled(), false, "foreground ownership outlives speculative TTL");
  await f.finish(1n);
  assert.deepEqual(f.rendered, [1n]);
  assert.equal(f.links.filter(link => link.id === 1n).length, 1);
});

test("real link preparation keeps failed target fan-out inside the speculative budget", async () => {
  const f = loadNotePrefetchInspector();
  f.context.HTMLElement = class {};
  f.context.customElements = { define() {} };
  vm.runInNewContext(fs.readFileSync(path.resolve("client/links-ui.js"), "utf8"), f.context);
  const pages = [];
  f.window.NRCEdges.requestEdgePage = async (_room, _type, id, options) => {
    pages.push(id);
    assert.equal(options.limit, 5);
    return { hasMore: false };
  };
  f.window.NRCEdges.getEdgesForEntity = (_room, _type, id) => Array.from({ length: 4 }, (_, index) => ({
    sourceType: 1, sourceId: id, targetType: 1, targetId: id * 10n + BigInt(index + 1),
  }));
  for (const id of [1n, 2n, 3n]) f.assets.set(id, { convId: 0n, assetId: id, assetType: 5, payload: "Body" });
  f.prefetch(1n); f.prefetch(2n);
  await flush();
  assert.equal(f.bodies.length, 8, "two preparations may issue at most four target reads each");
  f.bodies.find(body => body.id === 11n).options.onError(new Error("Target failed"));
  await flush();
  f.prefetch(3n);
  assert.deepEqual(pages, [1n, 2n], "one failed child cannot release capacity while siblings remain pending");
  for (const id of [12n, 13n, 14n]) await f.finish(id);
  f.prefetch(3n);
  await flush();
  assert.deepEqual(pages, [1n, 2n, 3n]);
  for (const id of [21n, 22n, 23n, 24n, 31n, 32n, 33n, 34n]) await f.finish(id);
  assert.deepEqual(f.rendered, [], "speculative failure and success never publish details");
});
