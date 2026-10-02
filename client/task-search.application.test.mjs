import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const read = (name) => fs.readFileSync(path.resolve(`client/${name}`), "utf8");
const flush = () => new Promise((resolve) => setImmediate(resolve));

class FakeElement {
  constructor(tagName = "div") {
    this.tagName = tagName.toUpperCase();
    this.children = [];
    this.dataset = {};
    this.style = {};
    this.listeners = new Map();
    this.className = "";
    this.classList = {
      add: (...names) => names.forEach((name) => this.className += ` ${name}`),
      remove() {}, toggle() {}, contains: () => false,
    };
  }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  append(...children) { children.forEach((child) => this.appendChild(child)); }
  replaceChildren(...children) { this.children = []; this.append(...children); }
  addEventListener(type, callback) { this.listeners.set(type, callback); }
  dispatch(type, target = this) { return this.listeners.get(type)?.({ target, preventDefault() {}, stopPropagation() {} }); }
  querySelector(selector) { return selector === ".col-marker" ? this.children[0] : null; }
  querySelectorAll() { return []; }
  closest() { return null; }
  set innerHTML(value) { this._innerHTML = value; this.children = []; }
  get innerHTML() { return this._innerHTML || ""; }
  setAttribute() {}
  removeAttribute() {}
  focus() {}
  scrollIntoView() {}
}

function response(results) {
  return { ok: true, headers: { get: () => "typed-v1" }, json: async () => ({ results }) };
}

function projection(id) {
  return {
    entity: { type: "task", id: String(id), conv_id: "0" },
    preview: "Indexed completed task",
    metadata: { task: { status: 3, priority: 200, color: 5, project: "nrc", created_at: 50 } },
  };
}

function taskFullResponse(correlationId) {
  const title = new TextEncoder().encode("Hydrated completed task");
  const buffer = new ArrayBuffer(98 + title.length);
  const view = new DataView(buffer);
  let offset = 2;
  view.setBigUint64(offset, 0n, false); offset += 8;
  view.setUint8(offset++, 1); view.setUint8(offset++, 1);
  view.setBigUint64(offset, 99n, false); offset += 8;
  view.setBigUint64(offset, 0n, false); offset += 8;
  view.setUint16(offset, title.length, false); offset += 2;
  new Uint8Array(buffer, offset, title.length).set(title); offset += title.length;
  view.setUint16(offset, 0, false); offset += 2; // description
  view.setUint8(offset++, 3); view.setUint16(offset, 0, false); offset += 2;
  view.setUint16(offset, 0, false); offset += 2; // assignee
  view.setUint8(offset++, 200); view.setUint8(offset++, 5);
  view.setUint16(offset, 0, false); offset += 2; // created by
  for (let i = 0; i < 2; i++) { view.setBigInt64(offset, 0n, false); offset += 8; }
  view.setUint16(offset, 0, false); offset += 2; // external ref
  view.setBigInt64(offset, 0n, false); offset += 8;
  view.setBigUint64(offset, 0n, false); offset += 8;
  view.setBigInt64(offset, 0n, false); offset += 8;
  view.setUint16(offset, 0, false); offset += 2; // completed by
  view.setUint16(offset, 0, false); offset += 2; // project
  view.setUint16(offset, 0, false); offset += 2; // attachments
  view.setUint16(offset, 0, false); offset += 2; // error
  view.setUint32(offset, correlationId, false);
  return new DataView(buffer);
}

function makeHarness({ now = null } = {}) {
  const elements = new Map([
    ["taskListBody", new FakeElement("tbody")],
    ["taskResultsCount", new FakeElement()],
    ["taskListView", Object.assign(new FakeElement(), { style: { display: "block" } })],
  ]);
  const documentListeners = new Map();
  const document = {
    body: new FakeElement("body"), activeElement: null,
    createElement: (tag) => new FakeElement(tag),
    getElementById: (id) => elements.get(id) || null,
    querySelectorAll: (selector) => selector.includes("tbody tr[data-task-id]") ? elements.get("taskListBody").children.filter((row) => row.dataset.taskId) : [],
    querySelector: () => null,
    addEventListener: (type, callback) => documentListeners.set(type, callback),
  };
  const sent = [];
  const fetches = [];
  const window = {
    NRCAssets: { getCommentCount: () => 0 },
    NRCLinksUI: { loadLinks: async () => {} },
    NRCColumnResize: { init() {} },
    NRCViewManager: { getActiveView: () => "kanban" },
    NRCListNavigation: { resolveAdjacent() { return {}; }, sameCompoundIdentity() {} },
  };
  const ClockDate = now === null ? Date : class extends Date { static now() { return now(); } };
  const sandbox = {
    window, document, console, BigInt, Map, Set, Date: ClockDate, JSON, Promise, AbortController,
    ArrayBuffer, DataView, Uint8Array, TextDecoder, TextEncoder,
    setTimeout, clearTimeout, setInterval, clearInterval,
    requestAnimationFrame: (callback) => callback(),
    localStorage: { getItem: () => null, setItem() {} },
    navigator: { clipboard: { writeText() {} } },
    matchMedia: () => ({ matches: false }),
    confirm: () => true,
    fetch: (...args) => { fetches.push(args); return Promise.resolve(response([projection(99)])); },
  };
  vm.createContext(sandbox);
  vm.runInContext(`
    var currentRoomId = 7n, currentWorkspaceId = "workspace-1", myNickname = "tester";
    var ws = { readyState: 1, send: (buffer) => __sent.push(buffer) };
    var serverReady = true, localPacketsOut = 0, clientRequestIdCounter = 0;
    var Opcode = { C_GetTask: 26 }, WebSocket = { OPEN: 1 };
    function getRpcCorrelationId() { return ++clientRequestIdCounter; }
    function getSearchUrl() { return "/search"; }
    function isTaskOverdue() { return false; }
    function formatDueDateShort() { return "—"; }
    function formatRelativeAge() { return "—"; }
    function escapeHtml(value) { return String(value); }
    function logSystem() {}
    var __sent = sent;
  `, Object.assign(sandbox, { sent }));
  vm.runInContext(`${read("task-state.js")}\nwindow.__TaskViewState = TaskViewState;`, sandbox);
  vm.runInContext(read("query-controller.js"), sandbox);
  vm.runInContext(read("task-search.js"), sandbox);
  vm.runInContext(`${read("tasks.js")}\nwindow.__renderTaskList = renderTaskList; window.__renderTaskListIfNeeded = renderTaskListIfNeeded; window.__invalidateTaskList = invalidateTaskList; window.__expireTaskList = () => { taskListValidUntilMs = 0; }; window.__getTaskListValidUntil = getTaskListValidUntil; window.__loadMoreTasksNearEnd = loadMoreTasksNearEnd; window.__handleCommentChanged = handleCommentChanged; window.__setKanbanVisible = (visible) => { kanbanVisible = visible; };`, sandbox);
  vm.runInContext(read("inspector.js"), sandbox);
  return { sandbox, window, elements, sent, fetches };
}

test("workspace task keyboard navigation follows selection and clamps at list boundaries", () => {
  const { sandbox, elements } = makeHarness();
  vm.runInContext(read("list-navigation.js"), sandbox);
  vm.runInContext(`
    kanbanVisible = true;
    selectTask = (task) => { selectedTaskId = task.id; selectedTaskConvId = task.convId; };
    roomTasks.set(0n, new Map([41n, 7n, 23n].map(id => [id, { id, convId: 0n }])));
  `, sandbox);
  for (const id of [41, 7, 23]) {
    const row = new FakeElement("tr");
    row.dataset = { taskId: String(id), convId: "0" };
    elements.get("taskListBody").appendChild(row);
  }
  for (const [key, expected] of [
    ["ArrowDown", 41n], ["ArrowDown", 7n], ["ArrowDown", 23n],
    ["ArrowDown", 23n], ["ArrowUp", 7n], ["ArrowUp", 41n], ["ArrowUp", 41n],
  ]) {
    vm.runInContext(`handleTaskListKeyboardNavigation({ key: "${key}", preventDefault() {} })`, sandbox);
    assert.equal(vm.runInContext("selectedTaskId", sandbox), expected, key);
  }
  vm.runInContext("selectedTaskId = null; selectedTaskConvId = null;", sandbox);
  vm.runInContext('handleTaskListKeyboardNavigation({ key: "ArrowUp", preventDefault() {} })', sandbox);
  assert.equal(vm.runInContext("selectedTaskId", sandbox), 23n);
});

test("reopening an unchanged task list preserves its rendered rows", () => {
  const { window, elements } = makeHarness();
  window.NRCTasks.roomTasks.set(0n, new Map([[1n, {
    id: 1n, convId: 0n, title: "Keep this row", description: "", status: 0,
    assignee: "", priority: 128, color: 0, externalRef: "", dueAt: 0n,
    blockedBy: 0n, attachments: [], project: "", createdAt: 0n,
  }]]));

  window.__renderTaskListIfNeeded();
  const firstRow = elements.get("taskListBody").children[0];
  window.__renderTaskListIfNeeded();
  assert.equal(elements.get("taskListBody").children[0], firstRow);

  window.__invalidateTaskList(0n);
  window.__renderTaskListIfNeeded();
  assert.notEqual(elements.get("taskListBody").children[0], firstRow);

  const secondRow = elements.get("taskListBody").children[0];
  window.__expireTaskList();
  window.__renderTaskListIfNeeded();
  assert.notEqual(elements.get("taskListBody").children[0], secondRow, "crossing a due-date boundary invalidates time-dependent rows");
});

test("task-list validity expires immediately after the next active due date", () => {
  const { window } = makeHarness();
  const dueMs = Date.now() + 60_000;
  const tasks = new Map([
    [1n, { status: 0, dueAt: BigInt(dueMs) * 1000000n }],
    [2n, { status: 3, dueAt: BigInt(dueMs - 30_000) * 1000000n }],
  ]);
  assert.equal(window.__getTaskListValidUntil(tasks), dueMs + 1);
});

test("a deadline crossed during rendering prevents reuse on reopen", () => {
  let nowMs = 1_000;
  const { window, elements } = makeHarness({ now: () => nowMs });
  window.NRCTasks.roomTasks.set(0n, new Map([[1n, {
    id: 1n, convId: 0n, title: "Deadline crossing", description: "", status: 0,
    assignee: "", priority: 128, color: 0, externalRef: "", dueAt: 1_001_000_000n,
    blockedBy: 0n, attachments: [], project: "", createdAt: 0n,
  }]]));

  window.__renderTaskListIfNeeded();
  const firstRow = elements.get("taskListBody").children[0];
  nowMs = 2_000;
  window.__renderTaskListIfNeeded();

  assert.notEqual(elements.get("taskListBody").children[0], firstRow);
});

test("off-room bulk comments do not rebuild the visible task list", () => {
  const { window, elements } = makeHarness();
  window.NRCTasks.roomTasks.set(0n, new Map([[1n, {
    id: 1n, convId: 0n, title: "Workspace task", description: "", status: 0,
    assignee: "", priority: 128, color: 0, externalRef: "", dueAt: 0n,
    blockedBy: 0n, attachments: [], project: "", createdAt: 0n,
  }]]));
  window.__renderTaskListIfNeeded();
  const firstRow = elements.get("taskListBody").children[0];
  window.__setKanbanVisible(true);

  window.__handleCommentChanged({ convId: 8n }, "list");

  assert.equal(elements.get("taskListBody").children[0], firstRow);
});

test("indexed unloaded Done projection renders, opens Inspector, and hydrates via C_GetTask", async () => {
  const { window, elements, sent } = makeHarness();
  window.__TaskViewState.filters.search = "completed";
  window.NRCTaskSearch.update();
  await flush();
  window.__renderTaskList();

  const row = elements.get("taskListBody").children.find((candidate) => candidate.dataset.taskId === "99");
  assert.ok(row, "the actual task-list renderer includes the unloaded indexed projection");
  assert.equal(row.children[3].children[0].tagName, "BUTTON");
  assert.equal(row.children[3].children[0].textContent, "Indexed completed task");
  assert.equal(window.NRCTasks.roomTasks.get(0n)?.has(99n) || false, false);

  await row.dispatch("click");
  assert.equal(window.NRCInspector.current().id, 99n);
  assert.equal(sent.length, 1);
  const request = new DataView(sent[0]);
  assert.equal(request.getUint16(0, false), 26, "Inspector hydration uses C_GetTask");
  assert.equal(request.getBigUint64(10, false), 99n);
  let selected = null;
  window.NRCTasks.selectTask = (task) => { selected = task; };
  window.NRCTasks.handleTaskFull(taskFullResponse(request.getUint32(18, false)));
  await flush();
  assert.equal(window.NRCTasks.roomTasks.get(0n).get(99n).title, "Hydrated completed task");
  assert.equal(selected?.id, 99n, "the correlated response completes Inspector navigation");
});

test("app lifecycle callbacks show loaded-only fallback, retry, and suppress the old response", async () => {
  const { window, elements } = makeHarness();
  const pending = [];
  window.NRCTaskSearch = window.createTaskSearchController({
    fetchImpl: () => new Promise((resolve) => pending.push(resolve)),
    getSearchUrl: () => "/search", getWorkspace: () => "workspace-1", getRoomId: () => 7n,
    getNickname: () => "tester", getFilters: () => window.__TaskViewState.filters,
    getLoadedTasks: () => window.NRCTasks.roomTasks.get(0n), onChange: () => window.__renderTaskList(),
  });
  window.NRCTasks.roomTasks.set(0n, new Map([[1n, { id: 1n, convId: 0n, title: "Loaded task", status: 0, attachments: [] }]]));
  window.__TaskViewState.filters.search = "task";
  window.NRCTaskSearch.update();
  window.NRCTaskSearch.onDisconnect(); // app.js ws.onclose seam
  assert.match(elements.get("taskListBody").children[0].innerHTML, /LOADED TASKS ONLY/);
  assert.ok(elements.get("taskListBody").children.some((row) => row.dataset.taskId === "1"));

  window.NRCTaskSearch.onReconnect(); // app.js post-initializeSession seam
  pending[1](response([projection(99)]));
  await flush();
  pending[0](response([projection(88)]));
  await flush();
  assert.deepEqual(Array.from(window.NRCTaskSearch.getState().tasks.keys()), [99n]);
  assert.equal(elements.get("taskListBody").children.some((row) => row.dataset.taskId === "88"), false);

  const app = read("app.js");
  assert.match(app, /initializeSession\(\);\s*window\.NRCTaskSearch\?\.onReconnect\?\.\(\)/);
  assert.match(app, /ws\.onclose[\s\S]*?window\.NRCTaskSearch\?\.onDisconnect\?\.\(\)/);
});

test("server priority pages remain draggable and use query neighbors, not unrelated cached tasks", () => {
  const { sandbox, window, elements } = makeHarness();
  const task = (id, priority) => ({ id, priority, convId: 0n, title: `Task ${id}`, status: 0,
    assignee: "", project: "", dueAt: 0n, createdAt: 0n, blockedBy: 0n, attachments: [] });
  const tasks = [task(1n, 240), task(2n, 200), task(3n, 100)];
  const query = { mode: "results", roomId: 0n, tasks: new Map(tasks.map(t => [t.id, t])), total: 3, hasMore: false };
  window.NRCTaskQuery = { getState: () => query, getProjects: () => [] };
  window.NRCTasks.roomTasks.set(0n, new Map([...query.tasks, [4n, task(4n, 175)]]));
  window.__renderTaskList();
  const rows = elements.get("taskListBody").children;
  assert.equal(rows.length, 3);
  assert.ok(rows.every(row => row.draggable));
  rows[1].getBoundingClientRect = () => ({ top: 0, height: 20 });
  sandbox.__sourceRow = rows[0]; sandbox.__targetRow = rows[1];
  vm.runInContext(`
    sendUpdateTask = (...args) => { window.__update = args; };
    draggedRow = { element: __sourceRow, taskId: 1n, convId: 0n };
    handleRowDrop({ preventDefault() {}, currentTarget: __targetRow, clientY: 25 });
    draggedRow = null;
  `, sandbox);
  assert.equal(window.__update[6], 150);
  window.__TaskViewState.sortColumn = "title";
  window.__renderTaskList();
  assert.ok(elements.get("taskListBody").children.every(row => !row.draggable));
});

test("the task register head reads N / M RESULTS while part of the listing is drawn and M RESULTS once all of it is", () => {
  const { window, elements } = makeHarness();
  const task = (id) => ({ id, priority: 200, convId: 0n, title: `Task ${id}`, status: 0,
    assignee: "", project: "", dueAt: 0n, createdAt: 0n, blockedBy: 0n, attachments: [] });
  const tasks = [task(1n), task(2n), task(3n)];
  const query = { mode: "results", roomId: 0n, tasks: new Map(tasks.map((t) => [t.id, t])), total: 3, hasMore: false };
  window.NRCTaskQuery = { getState: () => query, getProjects: () => [] };

  window.__renderTaskList();
  assert.equal(elements.get("taskResultsCount").textContent, "3 RESULTS",
    "a complete listing reads its matching count alone, like the notes and reminders registers");

  query.hasMore = true;
  query.total = 40;
  window.__renderTaskList();
  assert.equal(elements.get("taskResultsCount").textContent, "3 / 40 RESULTS",
    "a partially drawn listing says how many of the matching tasks it has drawn");
});

test("a query started while the list is hidden invalidates its previously rendered rows", (t) => {
  const { sandbox, window, elements } = makeHarness();
  window.__renderTaskList();
  const previous = elements.get("taskListBody").innerHTML;
  window.__setKanbanVisible(false);
  vm.runInContext(read("task-query.js"), sandbox);
  t.after(() => window.NRCTaskQuery.disconnect());
  window.NRCTaskQuery.update();
  assert.equal(elements.get("taskListBody").innerHTML, previous);
  window.__renderTaskListIfNeeded();
  assert.match(elements.get("taskListBody").innerHTML, /LOADING TASKS/);
});

test("task pagination loads automatically only near the scroll boundary", () => {
  const { window, elements } = makeHarness();
  const scroller = elements.get("taskListView");
  Object.assign(scroller, { clientHeight: 500, scrollHeight: 1500, scrollTop: 0 });
  let loads = 0;
  window.NRCTaskQuery = {
    getState: () => ({ mode: "results", hasMore: true }),
    loadMore: () => { loads++; },
  };

  window.__loadMoreTasksNearEnd();
  assert.equal(loads, 0);
  scroller.scrollTop = 601;
  window.__loadMoreTasksNearEnd();
  assert.equal(loads, 1);

  window.__TaskViewState.filters.search = "ranked";
  window.__loadMoreTasksNearEnd();
  assert.equal(loads, 1, "top-100 text search does not page the ordered task query");
});
