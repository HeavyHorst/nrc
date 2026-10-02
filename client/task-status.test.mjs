// The status a register draws is the control that changes it: the flat task
// table and a slice's member table both open the shared picker and write the
// move the board writes for a drag. node --test client/task-status.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const read = (name) => fs.readFileSync(path.resolve(`client/${name}`), "utf8");

class FakeElement {
  constructor(tagName = "div") {
    this.tagName = tagName.toUpperCase();
    this.children = [];
    this.dataset = {};
    this.style = {};
    this.attributes = new Map();
    this.listeners = new Map();
    this.className = "";
    this.value = "";
    this.classList = {
      add: (...names) => { this.className += ` ${names.join(" ")}`; },
      remove() {}, toggle() {}, contains: () => false,
    };
  }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  append(...children) { children.forEach((child) => this.appendChild(child)); }
  addEventListener(type, callback) { this.listeners.set(type, callback); }
  dispatch(type, target = this) {
    return this.listeners.get(type)?.({ target, preventDefault() {}, stopPropagation() {} });
  }
  querySelector(selector) { return selector === ".col-marker" ? this.children[0] : null; }
  querySelectorAll() { return []; }
  closest(selector) {
    if (selector?.startsWith(".") && this.className.split(/\s+/).includes(selector.slice(1))) return this;
    return this.parentNode?.closest?.(selector) ?? null;
  }
  select() {}
  set innerHTML(value) { this._innerHTML = value; this.children = []; }
  get innerHTML() { return this._innerHTML || ""; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  removeAttribute(name) { this.attributes.delete(name); }
  contains(node) {
    if (node === this) return true;
    return this.children.some((child) => child.contains?.(node) === true);
  }
  focus() { FakeElement.focused = this; }
  scrollIntoView() {}
}

function makeDocument(elements) {
  const listeners = new Map();
  const key = (type, capture) => `${type}:${capture === true}`;
  const bucket = (type, capture) => {
    if (!listeners.has(key(type, capture))) listeners.set(key(type, capture), new Set());
    return listeners.get(key(type, capture));
  };
  return {
    body: new FakeElement("body"),
    activeElement: null,
    createElement: (tag) => new FakeElement(tag),
    getElementById: (id) => elements.get(id) || null,
    querySelectorAll: (selector) => selector.includes("tbody tr[data-task-id]")
      ? elements.get("taskListBody").children.filter((row) => row.dataset.taskId) : [],
    querySelector: () => null,
    addEventListener: (type, callback, capture) => bucket(type, capture).add(callback),
    removeEventListener: (type, callback, capture) => bucket(type, capture).delete(callback),
    listenerCount: (type, capture) => bucket(type, capture).size,
    dispatch: (type, event, capture) => {
      for (const callback of [...bucket(type, capture)]) callback(event);
    },
  };
}

function makeHarness({ realPicker = false } = {}) {
  const elements = new Map([
    ["taskListBody", new FakeElement("tbody")],
    ["taskResultsCount", new FakeElement()],
    ["taskListView", Object.assign(new FakeElement(), { style: { display: "block" } })],
  ]);
  const document = makeDocument(elements);
  const sent = [];
  const pickers = [];
  const window = {
    NRCAssets: { getCommentCount: () => 0 },
    NRCLinksUI: { loadLinks: async () => {} },
    NRCColumnResize: { init() {} },
    NRCViewManager: { getActiveView: () => "kanban" },
    NRCListNavigation: { resolveAdjacent() { return {}; }, sameCompoundIdentity() {} },
  };
  if (!realPicker) {
    // The stub records what the register asked the picker to open and lets a case
    // select an option; the real-picker case loads the shared module instead.
    window.CustomPicker = {
      create: (config) => {
        const picker = { config, dropdown: new FakeElement("div"), isOpen: false, destroyed: false };
        pickers.push(picker);
        return picker;
      },
      open: (picker) => { picker.isOpen = true; },
      close: (picker) => { picker.isOpen = false; picker.config.onClose?.(picker); },
      destroy: (picker) => { picker.destroyed = true; picker.isOpen = false; },
    };
  }
  const sandbox = {
    window, document, console, BigInt, Map, Set, Date, JSON, Promise, AbortController,
    ArrayBuffer, DataView, Uint8Array, TextDecoder, TextEncoder,
    setTimeout, clearTimeout, setInterval, clearInterval,
    requestAnimationFrame: (callback) => callback(),
    localStorage: { getItem: () => null, setItem() {} },
    navigator: { clipboard: { writeText() {} } },
    matchMedia: () => ({ matches: false }),
    confirm: () => true,
    fetch: () => Promise.resolve({ ok: true, json: async () => ({ results: [] }) }),
  };
  vm.createContext(sandbox);
  vm.runInContext(`
    var currentRoomId = 7n, currentWorkspaceId = "workspace-1", myNickname = "tester";
    var ws = { readyState: 1, send: (buffer) => __sent.push(buffer) };
    var serverReady = true, localPacketsOut = 0, clientRequestIdCounter = 0;
    var Opcode = { C_GetTask: 26, C_MoveTask: 23 }, WebSocket = { OPEN: 1 };
    function getRpcCorrelationId() { return ++clientRequestIdCounter; }
    function getSearchUrl() { return "/search"; }
    function isTaskOverdue() { return false; }
    function formatDueDateShort() { return "—"; }
    function formatRelativeAge() { return "—"; }
    function escapeHtml(value) { return String(value); }
    function logSystem() {}
    function logMessage(kind, message) { __errors.push([kind, message]); }
    var __sent = sent, __errors = [];
    // assets.js owns the register's correlation ids in the page; without it the
    // register reads its own send as unsent. Ids skip 0 there, as they do here.
    window.NRCAssets.generateCorrelationId = () => ++clientRequestIdCounter;
  `, Object.assign(sandbox, { sent }));
  vm.runInContext(`${read("task-state.js")}\nwindow.__TaskViewState = TaskViewState;`, sandbox);
  vm.runInContext(read("query-controller.js"), sandbox);
  vm.runInContext(read("task-search.js"), sandbox);
  if (realPicker) vm.runInContext(read("custom-picker.js"), sandbox);
  vm.runInContext(`${read("tasks.js")}\nwindow.__renderTaskList = renderTaskList; window.__closeStatusMenuFor = closeStatusMenuFor;`, sandbox);
  return { sandbox, window, elements, document, sent, pickers };
}

function task(id, status, orderIndex = 0) {
  return {
    id, convId: 0n, title: `Task ${id}`, description: "", status, orderIndex,
    assignee: "", priority: 128, color: 0, externalRef: "", dueAt: 0n,
    blockedBy: 0n, attachments: [], project: "", createdAt: 0n,
  };
}

// One C_MoveTask frame: opcode(2) + conv_id(8) + task_id(8) + status(1) +
// flags(1) + order_index(2) + correlation_id(4), mirroring protocol/tasks.odin.
function readMove(buffer) {
  const view = new DataView(buffer);
  return {
    opcode: view.getUint16(0, false),
    convId: view.getBigUint64(2, false),
    taskId: view.getBigUint64(10, false),
    status: view.getUint8(18),
    flags: view.getUint8(19),
    orderIndex: view.getUint16(20, false),
  };
}

function renderRows({ window, elements, sandbox }, tasks) {
  window.NRCTasks.roomTasks.set(0n, new Map(tasks.map((entry) => [entry.id, entry])));
  vm.runInContext("kanbanVisible = true;", sandbox);
  window.__renderTaskList();
  return elements.get("taskListBody").children.filter((row) => row.dataset.taskId);
}

function statusToken(row) {
  return row.children.find((cell) => cell.className.includes("col-status")).children[0];
}

test("a task row's status token is the control that changes it", () => {
  const harness = makeHarness();
  const rows = renderRows(harness, [task(7n, 1), task(9n, 2)]);
  assert.equal(rows.length, 2);

  const token = statusToken(rows[0]);
  assert.equal(token.tagName, "BUTTON", "the token is a control");
  assert.equal(token.getAttribute("aria-haspopup"), "listbox");
  assert.equal(token.getAttribute("aria-expanded"), "false");
  assert.equal(token.getAttribute("aria-label"), "Status TODO — change status");
  assert.equal(token.className, "status-badge task-row-status status-todo");
  assert.equal(token.textContent, "TODO");

  // The press belongs to the token: the row must not open the task under it.
  let stopped = false;
  token.listeners.get("click")({
    target: token, preventDefault() {}, stopPropagation() { stopped = true; },
  });
  assert.equal(stopped, true, "the token keeps the row from opening the task");

  assert.equal(harness.pickers.length, 1, "the press opens one menu");
  const { config } = harness.pickers[0];
  assert.deepEqual(Array.from(config.options, (option) => option.label),
    ["BACKLOG", "TODO", "IN PROGRESS", "DONE"], "the menu offers the four statuses");
  assert.equal(config.selectedValue, 1, "the menu opens on the status the row holds");
  assert.equal(token.getAttribute("aria-expanded"), "true");
});

test("choosing a status sends the move the board sends for a drag", () => {
  const harness = makeHarness();
  const rows = renderRows(harness, [task(7n, 1), task(9n, 3, 4), task(11n, 3, 7)]);
  const token = statusToken(rows[0]);
  token.listeners.get("click")({ target: token, preventDefault() {}, stopPropagation() {} });

  harness.pickers[0].config.onSelect({ value: 3, label: "DONE" });
  assert.equal(harness.pickers[0].destroyed, true, "the menu closes with its selection");
  assert.equal(harness.sent.length, 1, "one move is written");
  assert.deepEqual(readMove(harness.sent[0]), {
    opcode: 23, convId: 0n, taskId: 7n, status: 3,
    // The register holds one page of the column, so it asks for the end of it and
    // the server folds the position: the move carries the flag, not a position.
    flags: 0x01, orderIndex: 0,
  });

  // Selecting the status the task already holds writes nothing.
  const rowsAgain = renderRows(harness, [task(7n, 1)]);
  const sameToken = statusToken(rowsAgain[0]);
  sameToken.listeners.get("click")({ target: sameToken, preventDefault() {}, stopPropagation() {} });
  harness.pickers[1].config.onSelect({ value: 1, label: "TODO" });
  assert.equal(harness.sent.length, 1, "an unchanged status is not written");
});

test("an outside click and Escape close the menu without a move", () => {
  const harness = makeHarness();
  const rows = renderRows(harness, [task(7n, 1)]);
  const token = statusToken(rows[0]);
  token.listeners.get("click")({ target: token, preventDefault() {}, stopPropagation() {} });
  assert.equal(harness.document.listenerCount("click", true), 1, "an open menu watches for dismissal");
  assert.equal(harness.document.listenerCount("keydown", true), 1);

  harness.document.dispatch("click", { target: new FakeElement("td") }, true);
  assert.equal(harness.pickers[0].destroyed, true, "an outside click closes the menu");
  assert.equal(harness.document.listenerCount("click", true), 0, "a closed menu releases its dismissal");
  assert.equal(token.getAttribute("aria-expanded"), "false");

  // Escape closes the menu and gives the token its focus back.
  token.listeners.get("click")({ target: token, preventDefault() {}, stopPropagation() {} });
  let stopped = false;
  harness.document.dispatch("keydown", {
    key: "Escape", preventDefault() {}, stopPropagation() { stopped = true; },
  }, true);
  assert.equal(harness.pickers[1].destroyed, true);
  assert.equal(stopped, true, "Escape belongs to the menu, not to the register behind it");
  assert.equal(FakeElement.focused, token, "the token keeps the reader's place");
  assert.equal(harness.sent.length, 0, "dismissal writes nothing");
});

test("a row the reader scrolled past takes its menu with it", () => {
  const harness = makeHarness();
  const rows = renderRows(harness, [task(7n, 1)]);
  const token = statusToken(rows[0]);
  token.listeners.get("click")({ target: token, preventDefault() {}, stopPropagation() {} });

  // Another row unmounting is not this menu's business.
  harness.window.__closeStatusMenuFor(new FakeElement("tr"));
  assert.equal(harness.pickers[0].destroyed, false, "a menu belongs to the row that opened it");

  harness.window.__closeStatusMenuFor(rows[0]);
  assert.equal(harness.pickers[0].destroyed, true, "the row that leaves takes its menu with it");
  assert.equal(harness.document.listenerCount("click", true), 0);
});

test("a redraw closes the menu its anchor is rebuilt out of", () => {
  const harness = makeHarness();
  const rows = renderRows(harness, [task(7n, 1)]);
  const token = statusToken(rows[0]);
  token.listeners.get("click")({ target: token, preventDefault() {}, stopPropagation() {} });
  assert.equal(harness.pickers[0].destroyed, false);

  // A table that is rebuilt somewhere else is not this menu's business.
  harness.window.__closeStatusMenuFor(new FakeElement("div"));
  assert.equal(harness.pickers[0].destroyed, false, "another table keeps its hands off the menu");

  harness.window.__renderTaskList();
  assert.equal(harness.pickers[0].destroyed, true, "the rebuilt register carries no menu");
  assert.equal(harness.document.listenerCount("click", true), 0);
});

test("an offline register reports the move instead of writing it", () => {
  const harness = makeHarness();
  const rows = renderRows(harness, [task(7n, 1)]);
  const token = statusToken(rows[0]);
  token.listeners.get("click")({ target: token, preventDefault() {}, stopPropagation() {} });
  vm.runInContext("serverReady = false;", harness.sandbox);

  harness.pickers[0].config.onSelect({ value: 3, label: "DONE" });
  assert.equal(harness.sent.length, 0, "an offline register writes nothing");
  assert.deepEqual(Array.from(harness.sandbox.__errors, (entry) => Array.from(entry)),
    [["Error", "OFFLINE — RECONNECT BEFORE CHANGING A TASK"]]);
});

test("a refused move reports the server's answer and changes nothing", () => {
  const harness = makeHarness();
  const rows = renderRows(harness, [task(7n, 1)]);
  const token = statusToken(rows[0]);
  token.listeners.get("click")({ target: token, preventDefault() {}, stopPropagation() {} });
  harness.pickers[0].config.onSelect({ value: 3, label: "DONE" });
  assert.equal(harness.sent.length, 1, "the move went out before the server answered");

  // The server refuses the move — a full column, or too many active tasks — and
  // answers the move's correlation with S_TaskListResponse.
  const correlationId = vm.runInContext("clientRequestIdCounter", harness.sandbox);
  const message = "Status column is full";
  const messageBytes = new TextEncoder().encode(message);
  const buffer = new ArrayBuffer(2 + 8 + 1 + 2 + 2 + messageBytes.length + 4);
  const view = new DataView(buffer);
  view.setUint16(0, 134, false);
  view.setBigUint64(2, 0n, false);
  view.setUint8(10, 0);
  view.setUint16(11, 0, false);
  view.setUint16(13, messageBytes.length, false);
  new Uint8Array(buffer, 15, messageBytes.length).set(messageBytes);
  view.setUint32(15 + messageBytes.length, correlationId, false);
  vm.runInContext("window.NRCTasks.handleTaskListResponse", harness.sandbox)(view);

  assert.deepEqual(Array.from(harness.sandbox.__errors, (entry) => Array.from(entry)),
    [["Error", message], ["Error", `TASK LIST ERROR: ${message}`]],
    "the register reports what the server answered");
  assert.equal(statusToken(rows[0]).textContent, "TODO", "a refused move leaves the token where it was");
  assert.equal(harness.sent.length, 1, "a refusal writes no second frame");
});

test("the shared picker's own selection path closes the menu and writes the move", () => {
  // The stub above records the register's contract; this case runs the real
  // shared picker, so its re-entrant select → onSelect → destroy → close path is
  // the one under test.
  const harness = makeHarness({ realPicker: true });
  const rows = renderRows(harness, [task(7n, 1)]);
  const token = statusToken(rows[0]);
  token.listeners.get("click")({ target: token, preventDefault() {}, stopPropagation() {} });

  const picker = [...harness.window.CustomPicker.instances][0];
  assert.ok(picker, "the press mounts one picker");
  assert.equal(picker.isOpen, true);
  assert.deepEqual(Array.from(picker.options, (option) => option.label),
    ["BACKLOG", "TODO", "IN PROGRESS", "DONE"]);
  const done = picker.optionsContainer.children.find((option) => option.getAttribute("data-value") === "3");
  assert.ok(done, "the picker holds the drawn statuses");
  picker.dropdown.dispatch("click", done);

  assert.equal(harness.window.CustomPicker.instances.size, 0, "the picker is released with the menu");
  assert.equal(harness.document.listenerCount("click", true), 0, "the menu releases its dismissal");
  assert.equal(token.getAttribute("aria-expanded"), "false");
  assert.deepEqual(readMove(harness.sent[0]), { opcode: 23, convId: 0n, taskId: 7n, status: 3, flags: 0x01, orderIndex: 0 });
});
