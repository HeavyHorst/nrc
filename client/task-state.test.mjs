import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = fs.readFileSync(path.resolve("client/task-state.js"), "utf8");
test("assignee choices include indexed offline owners without cached task rows or chat presence", () => {
  const window = { NRCTaskQuery: { getAssignees: () => ["zoe", "tester", "alex", "alex"] } };
  const context = { window, myNickname: "tester", localStorage: { getItem: () => null }, document: { getElementById: () => null } };
  vm.runInNewContext(`${source}\nwindow.options = getAssigneeFilterOptions();`, context);
  assert.deepEqual(Array.from(window.options, item => [item.label, item.value]), [["ALL", ""], ["MY TASKS", "me"], ["alex", "alex"], ["zoe", "zoe"]]);
});

function loadTaskState(overrides = {}) {
  const sandbox = {
    window: {},
    localStorage: { setItem() {}, getItem() { return null; } },
    document: { getElementById() { return null; } },
    myNickname: "tester",
    isTaskOverdue: (task) => Boolean(task.overdue),
    ...overrides,
  };
  vm.runInNewContext(`${source}\nwindow.__getSortedTasks = getSortedTasks; window.__getFilteredTasks = getFilteredTasks; window.__refreshAfterFilter = refreshTaskViewAfterFilterChange; window.__populateProjectFilter = populateProjectFilter; window.__state = TaskViewState;`, sandbox);
  return sandbox.window;
}

test("task sorting has a deterministic compound-identity tie-break", () => {
  const { __getSortedTasks: sort, __state: state } = loadTaskState();
  state.sortColumn = "title";
  state.sortDirection = "asc";
  const tasks = [
    { convId: 2n, id: 1n, title: "same" },
    { convId: 1n, id: 2n, title: "same" },
    { convId: 1n, id: 1n, title: "same" },
  ];
  assert.deepEqual(Array.from(sort(tasks), (task) => `${task.convId}:${task.id}`), ["1:1", "1:2", "2:1"]);
  state.sortDirection = "desc";
  assert.deepEqual(Array.from(sort(tasks), (task) => `${task.convId}:${task.id}`), ["1:1", "1:2", "2:1"]);
});

test("filter changes invalidate active remote search results and rerender reminders", () => {
  let updates = 0;
  let reminderRenders = 0;
  const { __refreshAfterFilter: refresh } = loadTaskState({
    window: {
      NRCTaskSearch: { update: () => { updates++; } },
      NRCTasks: { renderReminderQueue: () => { reminderRenders++; } },
    },
  });
  refresh();
  assert.equal(updates, 1);
  assert.equal(reminderRenders, 1);
});

test("Open hides completed tasks while All and Done retain their literal meanings", () => {
  const { __getFilteredTasks: filter, __state: state } = loadTaskState();
  const tasks = new Map([
    [1n, { id: 1n, status: 0 }],
    [2n, { id: 2n, status: 3 }],
  ]);

  assert.deepEqual(Array.from(filter(tasks), (task) => task.id), [1n]);
  state.filters.status = null;
  assert.deepEqual(Array.from(filter(tasks), (task) => task.id), [1n, 2n]);
  state.filters.status = 3;
  assert.deepEqual(Array.from(filter(tasks), (task) => task.id), [2n]);
});

test("project option rebuilding preserves empty and case-variant remote facets", () => {
  const select = {
    value: "",
    options: [],
    set innerHTML(_value) { this.options = []; this.value = ""; },
    appendChild(option) { this.options.push(option); },
  };
  const document = {
    getElementById: (id) => id === "filterProject" ? select : null,
    createElement: () => ({ value: "", textContent: "" }),
  };
  const roomTasks = new Map([[0n, new Map()]]);
  const loaded = loadTaskState({ document, roomTasks, currentRoomId: 7n });
  loaded.__state.filters.project = "nrc";
  loaded.__populateProjectFilter();
  assert.equal(select.value, "nrc");
  assert.equal(loaded.__state.filters.project, "nrc");

  roomTasks.get(0n).set(1n, { status: 3, project: "NRC" });
  loaded.__populateProjectFilter();
  assert.equal(select.value, "nrc");
  assert.equal(loaded.__state.filters.project, "nrc");
  assert.deepEqual(select.options.map((option) => option.value), ["NRC", "nrc"]);

  loaded.NRCTaskQuery = { getProjects: () => ["NRC", "nrc", "Unloaded history"] };
  loaded.__populateProjectFilter();
  assert.deepEqual(select.options.map((option) => option.value), ["NRC", "Unloaded history", "nrc"]);
  assert.equal(select.value, "nrc");
});

test("reload ignores old saved filters but preserves sorting; new filters stay in memory", () => {
  const elements = Object.fromEntries([
    "filterStatus", "filterAssignee", "filterColor", "filterProject", "filterFlags",
    "filterHideLockedReminders", "taskSearch",
  ].map((id) => [id, {
    value: "", checked: false, options: [], listeners: {},
    set innerHTML(_value) { this.options = []; this.value = ""; },
    appendChild(option) { this.options.push(option); },
    addEventListener(event, handler) { this.listeners[event] = handler; },
  }]));
  const filters = {
    status: 0, assignee: "offline-user", color: 5, project: "Saved project",
    blocked: true, overdue: true, hideLockedReminders: true,
    search: "query", reminderView: "all",
  };
  let saved;
  const sandbox = {
    window: {}, myNickname: "tester", myTasksOnly: false, roomTasks: new Map(), currentRoomId: 7n,
    renderTaskList() {},
    document: {
      getElementById: (id) => elements[id],
      querySelectorAll: () => [],
      createElement: () => ({ value: "", textContent: "" }),
    },
    localStorage: {
      getItem: () => JSON.stringify({ filters, sortColumn: "title", sortDirection: "asc" }),
      setItem: (_key, value) => { saved = JSON.parse(value); },
    },
  };
  vm.runInNewContext(`${source}\ninitTaskViewState();`, sandbox);
  const defaults = {
    status: "open", assignee: null, color: null, project: null,
    blocked: null, overdue: null, hideLockedReminders: false,
    search: "", reminderView: "all",
  };
  const currentFilters = () => JSON.parse(vm.runInNewContext("JSON.stringify(TaskViewState.filters)", sandbox));
  assert.deepEqual(currentFilters(), defaults);
  assert.equal(elements.filterStatus.value, "open");
  for (const id of ["filterColor", "filterProject", "filterAssignee", "filterFlags", "taskSearch"]) {
    assert.equal(elements[id].value, "");
  }
  assert.equal(elements.filterHideLockedReminders.checked, false);
  for (const [value, blocked, overdue] of [
    ["", null, null],
    ["blocked", true, null],
    ["overdue", null, true],
    ["both", true, true],
  ]) {
    elements.filterFlags.value = value;
    elements.filterFlags.listeners.change();
    assert.equal(currentFilters().blocked, blocked, `${value || "all"}: blocked state`);
    assert.equal(currentFilters().overdue, overdue, `${value || "all"}: overdue state`);
  }
  // RESET clears the register on screen: the slice grouping routes to the slice
  // register, and the flat list resets its own filters.
  const sliceResets = [];
  sandbox.window.NRCSlices = {
    resetFilters: () => sliceResets.push(true),
    ensureLoaded() {},
    render() {},
  };
  vm.runInNewContext("resetFilters();", sandbox);
  assert.equal(sliceResets.length, 1, "the slice grouping resets the slice filters");
  assert.equal(currentFilters().blocked, true,
    "the flat-list filters are not cleared from the slice grouping");
  assert.equal(sandbox.myTasksOnly, false);

  elements.filterProject.value = "New project";
  elements.filterProject.listeners.change();
  assert.equal(currentFilters().project, "New project", "a filter change lands in memory");
  assert.equal(saved, undefined, "filter changes do not write storage");
  vm.runInNewContext("saveViewState();", sandbox);
  assert.deepEqual(saved, { sortColumn: "title", sortDirection: "asc", grouping: "slices" });
  vm.runInNewContext("TaskViewState.grouping = 'flat'; resetFilters(); populateProjectFilter(); populateAssigneeFilter();", sandbox);
  assert.deepEqual(currentFilters(), defaults);
  assert.equal(elements.filterProject.value, "");
  assert.equal(elements.filterAssignee.value, "");
  assert.equal(elements.filterFlags.value, "");
});

test("remote semantic results preserve structured filters without requiring a substring", () => {
  const { __getFilteredTasks: filter, __state: state } = loadTaskState();
  state.filters = {
    status: 3, assignee: "me", blocked: true, overdue: null,
    hideLockedReminders: false, search: "conceptual query", color: 5, project: "nrc",
  };
  const matching = {
    convId: 1n, id: 1n, title: "Different words", description: "", status: 3,
    assignee: "tester", blockedBy: 2n, color: 5, project: "nrc",
  };
  const wrongProject = { ...matching, id: 2n, project: "other" };
  const tasks = new Map([[matching.id, matching], [wrongProject.id, wrongProject]]);
  assert.deepEqual(Array.from(filter(tasks, { applyTextSearch: false }), (task) => task.id), [1n]);
  assert.deepEqual(Array.from(filter(tasks), (task) => task.id), []);
});

test("task priority direction is applied once", () => {
  const { __getSortedTasks: sort, __state: state } = loadTaskState();
  const tasks = [
    { convId: 1n, id: 1n, priority: 10 },
    { convId: 1n, id: 2n, priority: 200 },
  ];
  state.sortColumn = "priority";
  state.sortDirection = "desc";
  assert.deepEqual(Array.from(sort(tasks), (task) => task.priority), [200, 10]);
  state.sortDirection = "asc";
  assert.deepEqual(Array.from(sort(tasks), (task) => task.priority), [10, 200]);
});

test("tasks without due dates stay last in either direction", () => {
  const { __getSortedTasks: sort, __state: state } = loadTaskState();
  const tasks = [
    { convId: 1n, id: 1n, dueAt: 0n },
    { convId: 1n, id: 2n, dueAt: 100n },
    { convId: 1n, id: 3n, dueAt: 200n },
  ];
  state.sortColumn = "dueAt";
  state.sortDirection = "asc";
  assert.deepEqual(Array.from(sort(tasks), (task) => task.id), [2n, 3n, 1n]);
  state.sortDirection = "desc";
  assert.deepEqual(Array.from(sort(tasks), (task) => task.id), [3n, 2n, 1n]);
});
