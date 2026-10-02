import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

// The ATTENTION register derives every row from a source it does not own, so
// these cases pin the derivation, the counts and the jump targets — not the DOM.
const source = fs.readFileSync(new URL("./attention.js", import.meta.url), "utf8");
const navigationSource = fs.readFileSync(new URL("./list-navigation.js", import.meta.url), "utf8");
const tasksSource = fs.readFileSync(new URL("./tasks.js", import.meta.url), "utf8");
const stateBlock = tasksSource.match(/const ReminderState = \{([^}]*)\}/)[1];
const ReminderState = Object.fromEntries(
  [...stateBlock.matchAll(/(\w+):\s*"([A-Z]+)"/g)].map(([, key, value]) => [key, value]),
);
const statusBlock = tasksSource.match(/const TaskStatus = \{([^}]*)\}/)[1];
const TaskStatus = Object.fromEntries(
  [...statusBlock.matchAll(/(\w+):\s*(\d+)/g)].map(([, key, value]) => [key, Number(value)]),
);

const DAY = 24 * 60 * 60 * 1000;
const nanos = (ms) => BigInt(ms) * 1000000n;
const now = Date.parse("2026-09-22T12:00:00Z");
const RealDate = Date;

// The register formats deadlines and ages from Date.now(), so the fixtures pin
// the clock instead of depending on when the suite runs.
class TestDate extends RealDate {
  constructor(...args) { super(...(args.length ? args : [now])); }
  static now() { return now; }
}

function task(id, overrides = {}) {
  return {
    id: BigInt(id), convId: 0n, title: `Task ${id}`, description: "", status: TaskStatus.Todo,
    orderIndex: 0, assignee: "rene", priority: 128, color: 0, createdBy: "mara",
    createdAt: nanos(now - 7 * DAY), updatedAt: nanos(now - 3 * DAY), externalRef: "",
    dueAt: 0n, blockedBy: 0n, completedAt: 0n, completedBy: "", project: "", attachments: [],
    ...overrides,
  };
}

function reminder(id, title, state, offsetMs) {
  return {
    asset: { assetId: BigInt(id), convId: 0n, updatedAt: nanos(now - 2 * DAY), createdAt: nanos(now - 9 * DAY) },
    title, state, deadlineAt: nanos(now + offsetMs), windowStartAt: 0n, urgencyDays: 3, noteAssetId: 0n,
  };
}

// A headless task query controller is replaced by a scripted one: the register
// asks it for a total per count query and walks the `mine` and dependency rows.
function harness({ tasks = [], counts = {}, taskPages = null, dependencyPages = null, errors = {}, reminders = [], unread = [], dms = [], retained = null, activeView = "attention" } = {}) {
  const opened = [];
  const listeners = {};
  const elements = {};
  const sentQueries = [];
  const pageLoads = [];
  const openedRooms = [];
  const historyRequests = [];
  const logLines = [];
  const flashes = [];
  const scrolls = [];
  const targetRows = new Map();
  const timers = [];
  const KIND_ORDER = ["mine", "blocked", "overdue"];
  const pageSets = {
    // The `mine` query is walked page by page; the two count-only queries are one
    // page each and carry no rows.
    mine: taskPages || [{ tasks, total: counts.mine ?? tasks.length, hasMore: counts.hasMore === true }],
    blocked: dependencyPages || [{ tasks: [], total: counts.blocked ?? 0, hasMore: false }],
    overdue: [{ tasks: [], total: counts.overdue ?? 0, hasMore: false }],
  };
  let queryIndex = -1;
  let pageIndex = 0;
  const walked = new Map();
  const currentKind = () => KIND_ORDER[queryIndex];
  const currentPage = () => {
    const pages = pageSets[currentKind()] || [];
    return pages[Math.min(pageIndex, pages.length - 1)] || { tasks: [], total: 0, hasMore: false };
  };
  const currentError = () => errors[currentKind()] === true || errors[currentKind()] === pageIndex;
  const collectPage = () => { for (const entry of currentPage().tasks) walked.set(entry.id, entry); };

  const viewState = { active: activeView };
  const window = {
    NRCChatUnread: { snapshot: () => unread },
    matchMedia: () => ({ matches: false }),
    createTaskQueryController: (options) => ({
      getState: () => {
        const page = currentPage();
        return { mode: currentError() ? "error" : "results", total: page.total, hasMore: page.hasMore === true,
          tasks: new Map(walked) };
      },
      update: () => {
        queryIndex += 1;
        pageIndex = 0;
        walked.clear();
        sentQueries.push(options.getFilters());
        collectPage();
        options.onChange();
      },
      loadMore: () => {
        pageLoads.push(options.getFilters());
        pageIndex += 1;
        collectPage();
        options.onChange();
      },
      handlePage() {},
      handleProjects() {},
    }),
    NRCTasks: {
      TaskStatus,
      ReminderState,
      getReminderSnapshot: () => ({ assetCount: reminders.length, reminders }),
    },
    // Slices are deliberately not an ATTENTION source. Fail loudly if that
    // obsolete read is ever restored.
    NRCSlices: { readAll: () => { throw new Error("ATTENTION must not read slices"); } },
    NRCViewManager: { getActiveView: () => viewState.active, setActiveView() {} },
    NRCInspector: { openEntity: (ref) => opened.push(ref), refreshContext() {} },
  };

  // The register walks the same openers the browser would: one per rendered row,
  // and only the row carries the key the cursor travels on — exactly as in the
  // production markup, where the opener is a plain button.
  const focused = [];
  const rowScrolls = [];
  const openers = new Map();
  const openerFor = (row) => {
    let opener = openers.get(row.key);
    if (!opener) {
      opener = {
        focus: () => { document.activeElement = opener; focused.push(row.key); },
        closest: (selector) => (selector === ".attention-row" ? opener.row : null),
      };
      opener.row = { dataset: { attentionKey: row.key }, scrollIntoView: (options) => rowScrolls.push([row.key, options?.block]) };
      openers.set(row.key, opener);
    }
    return opener;
  };

  const document = {
    addEventListener: (name, callback) => { listeners[name] = callback; },
    querySelectorAll: (selector) => {
      if (selector === "[data-attention-filter]") return [];
      if (selector === "#attentionBody .attention-row .attention-title") {
        return (window.NRCAttention?.getState?.().rows || []).map(openerFor);
      }
      return [];
    },
    getElementById: (id) => elements[id] || null,
    querySelector: (selector) => {
      const match = selector.match(/\[data-sequence="(\d+)"\]/);
      return match ? targetRows.get(match[1]) || null : null;
    },
  };

  const row = (sequence) => ({
    dataset: { sequence: String(sequence) },
    classes: new Set(),
    classList: {
      add(name) { this.owner.classes.add(name); flashes.push(`${sequence}:${name}`); },
      remove(name) { this.owner.classes.delete(name); },
    },
    scrollIntoView(options) { scrolls.push([String(sequence), options?.block]); },
  });

  const context = {
    window,
    document,
    Date: TestDate,
    BigInt, Number, Math, String, JSON, Set, Map, Array, Object, WebSocket: { OPEN: 1 },
    serverReady: true,
    ws: { readyState: 1, send() {} },
    myNickname: "rene",
    localPacketsOut: 0,
    getRpcCorrelationId: () => 1,
    parseTask: (view, offset) => ({ task: view[offset], newOffset: offset + 1 }),
    activeDMs: new Map(dms.map((dm) => [dm.convId, dm])),
    isDMConversation: (convId) => dms.some((dm) => dm.convId === convId),
    formatDMDisplayName: (username) => username.toUpperCase(),
    getRoomName: (convId) => `ROOM ${convId}`,
    openChatRoom: (convId) => openedRooms.push(convId),
    retainedRoomStates: new Map(retained ? [[retained.convId, retained.state]] : []),
    requestRetainedHistory: (convId, cursor, loaded, options) => historyRequests.push({ convId, cursor, options }),
    logSystem: (message) => logLines.push(message),
    setTimeout: (callback, ms) => { timers.push({ callback, ms }); return timers.length; },
    clearTimeout: (id) => { if (id > 0) timers[id - 1] = null; },
  };
  // The register walks rows with the shared list-navigation contract, which
  // index.html loads before it, so the harness runs the real module too.
  vm.runInNewContext(navigationSource, context);
  vm.runInNewContext(source, context);

  for (const sequence of [7n, 8n]) {
    const entry = row(sequence);
    entry.classList.owner = entry;
    targetRows.set(String(sequence), entry);
  }

  const press = (key, overrides = {}) => {
    let prevented = false;
    listeners.keydown({
      key, target: { tagName: "BODY" }, preventDefault: () => { prevented = true; }, ...overrides,
    });
    return prevented;
  };

  return { attention: window.NRCAttention, opened, listeners, elements, sentQueries, pageLoads,
    openedRooms, historyRequests, logLines, flashes, scrolls, targetRows, document, focused, rowScrolls, viewState, press,
    runTimers: () => { for (const timer of timers.splice(0)) timer?.callback(); },
    timerCount: () => timers.length };
}

test("only actionable tasks are rows; slices and ordinary blocked tasks are excluded", () => {
  const prerequisite = task(3);
  const h = harness({
    tasks: [task(1, { dueAt: nanos(now - DAY) }), task(2, { blockedBy: 9n }), prerequisite,
      task(6, { blockedBy: 9n })],
    dependencyPages: [{ tasks: [
      task(20, { assignee: "mara", blockedBy: 3n }),
      task(21, { assignee: "mara", blockedBy: 1n }),
      task(22, { assignee: "mara", blockedBy: 6n }),
    ], total: 3, hasMore: false }],
    reminders: [reminder(4, "Contract draft", ReminderState.Urgent, 2 * 60 * 60 * 1000)],
  });
  h.attention.refresh();
  assert.deepEqual(Array.from(h.attention.getState().rows, row => [String(row.id), row.reason]),
    [["1", "overdue"], ["3", "unblocks"], ["4", "reminder"]]);
  assert.equal(h.attention.getState().rows.some(row => row.id === 6n), false,
    "a prerequisite that is itself blocked is not actionable");
  assert.equal(h.attention.getState().rows.some(row => row.kind === "SLICE"), false);
});

test("reason sections are exclusive: overdue wins and waiting is only overdue blocked work", () => {
  const both = task(1, { dueAt: nanos(now - DAY), blockedBy: 9n });
  const h = harness({ tasks: [both, task(2, { blockedBy: 9n }), task(3)] });
  h.elements.attentionBody = { innerHTML: "", addEventListener() {} };
  h.attention.refresh();
  assert.deepEqual(Array.from(h.attention.getState().rows, r => [String(r.id), r.reason]),
    [["1", "waiting"], ["3", "assigned"]]);
  const html = h.elements.attentionBody.innerHTML;
  assert.equal((html.match(/data-attention-key="TASK:1"/g) || []).length, 1);
  assert.match(html, /OVERDUE \/ WAITING<span>1 ITEM/);
  assert.match(html, /WAITING ON #9<\/button>/);
  assert.doesNotMatch(html, /VIEW PREREQUISITE|<details/);
  assert.match(html, /Prerequisite #9/);
});

// The register lists the operator's whole open queue, so the row query is walked
// to its last page; the header only carries the `+` when a walk stopped early.
test("the register walks every page of the row query and the header drops the plus when it is complete", () => {
  const first = Array.from({ length: 30 }, (_, index) => task(index + 1));
  const second = Array.from({ length: 4 }, (_, index) => task(index + 31));
  const h = harness({
    taskPages: [
      { tasks: first, total: 34, hasMore: true },
      { tasks: second, total: 34, hasMore: false },
    ],
  });
  h.elements.attentionCount = { textContent: "" };
  h.elements.attentionBody = { innerHTML: "", addEventListener() {} };
  h.attention.refresh();
  const rows = h.attention.getState().rows.filter((row) => row.kind === "TASK");
  assert.equal(rows.length, 34, "the rows of every page are kept");
  assert.deepEqual(Array.from(rows, (row) => String(row.id)).sort(),
    [...first, ...second].map((entry) => String(entry.id)).sort(),
    "the last page is folded in, not dropped");
  assert.equal(h.attention.getState().counts.mine, 34, "the count is the server's total");
  assert.equal(h.elements.attentionCount.textContent, "34 ITEMS · BY REASON",
    "a finished walk needs no plus");
  assert.equal(h.sentQueries.length, 3, "one walk of the three count queries");
  assert.equal(h.pageLoads.length, 1, "the row query asked for its second page");
  assert.match(h.elements.attentionBody.innerHTML, /Task 34/);
});

// A listing that never ends must not spin the client: the walk is capped and the
// header keeps saying that rows exist beyond the ones it holds.
test("a row walk that never ends stops at the cap and still says more exist", () => {
  const taskPages = Array.from({ length: 60 }, (_, index) => ({
    tasks: [task(index + 1)], total: 60, hasMore: true,
  }));
  const h = harness({ taskPages });
  h.elements.attentionCount = { textContent: "" };
  h.elements.attentionBody = { innerHTML: "", addEventListener() {} };
  h.attention.refresh();
  assert.equal(h.attention.getState().rows.filter((row) => row.kind === "TASK").length, 50,
    "the cap bounds the walk");
  assert.equal(h.attention.getState().hasMoreTasks, true, "the walk says it did not finish");
  assert.equal(h.elements.attentionCount.textContent, "50+ ITEMS · BY REASON");
  assert.equal(h.pageLoads.length, 49, "the walk stops at the cap, one page per request");
  assert.equal(h.sentQueries.length, 3, "and the count-only queries still run");
  assert.equal(h.attention.getState().counts.blocked, 0, "their totals are read");
});

test("dependency pages include cross-assignee dependents and use an unscoped blocked query", () => {
  const h = harness({
    tasks: [task(7)],
    dependencyPages: [
      { tasks: [task(20, { assignee: "mara", blockedBy: 7n })], total: 2, hasMore: true },
      { tasks: [task(21, { assignee: "tobias", blockedBy: 7n })], total: 2, hasMore: false },
    ],
  });
  h.attention.refresh();
  const row = h.attention.getState().rows[0];
  assert.equal(row.reason, "unblocks");
  assert.equal(row.detail, "UNBLOCKS 2 TASKS");
  assert.deepEqual(Array.from(row.related, task => task.assignee), ["mara", "tobias"]);
  assert.equal(h.sentQueries[1].assignee, null);
  assert.equal(h.pageLoads.length, 1);
  assert.equal(h.attention.getState().dependenciesIncomplete, false);
});

test("a capped dependency read marks dependent counts and status as partial", () => {
  const pages = Array.from({ length: 60 }, (_, index) => ({
    tasks: [task(index + 20, { assignee: "mara", blockedBy: 7n })], total: 60, hasMore: true,
  }));
  const h = harness({ tasks: [task(7)], dependencyPages: pages });
  h.elements.attentionBody = { innerHTML: "", addEventListener() {} };
  h.elements.attentionDependencyStatus = { hidden: true, textContent: "" };
  h.attention.refresh();
  const row = h.attention.getState().rows[0];
  assert.equal(row.detail, "UNBLOCKS 50+ TASKS");
  assert.equal(h.attention.getState().dependenciesIncomplete, true);
  assert.equal(h.elements.attentionDependencyStatus.hidden, false);
  assert.equal(h.pageLoads.length, 49);
});

test("dependency query errors put the register in error mode", () => {
  const h = harness({ tasks: [task(1)], errors: { blocked: true } });
  h.attention.refresh();
  assert.equal(h.attention.getState().mode, "error");
});

test("the sidebar count is derived while another view is in front", () => {
  const h = harness({
    tasks: [task(1)],
    reminders: [reminder(4, "Contract draft", ReminderState.Late, -DAY)],
    activeView: "notes",
  });
  const badge = { textContent: "", hidden: true, setAttribute(name, value) { this[name] = value; } };
  h.elements.attentionViewCount = badge;
  h.attention.init();
  h.attention.onSessionStarted();
  assert.equal(badge.textContent, "02", "a reload in another view does not hide what is waiting");
  assert.equal(badge.hidden, false);
  assert.equal(badge["aria-label"], "2 items need attention");
});

test("details name due, waiting and unblocks conditions", () => {
  const h = harness({
    tasks: [task(1, { dueAt: nanos(now + DAY) }), task(2, { blockedBy: 9n, dueAt: nanos(now - DAY) }), task(3)],
    dependencyPages: [{ tasks: [task(8, { assignee: "mara", blockedBy: 3n })], total: 1, hasMore: false }],
    reminders: [reminder(4, "Contract draft", ReminderState.Late, -DAY)],
  });
  h.attention.refresh();
  const detailOf = (title) => h.attention.getState().rows.find((row) => row.title === title)?.detail;
  assert.match(detailOf("Task 1"), /^DUE \d{4}-\d{2}-\d{2}$/);
  assert.match(detailOf("Task 2"), /^DUE .* · WAITING ON #9$/);
  assert.equal(detailOf("Task 3"), "UNBLOCKS 1 TASK");
  assert.match(detailOf("Contract draft"), /^DUE \d{4}-\d{2}-\d{2}$/);
});

test("an overdue task outranks a task without a due date", () => {
  const h = harness({
    tasks: [task(1, { dueAt: nanos(now + 5 * DAY) }), task(2, { dueAt: nanos(now - DAY) }), task(3)],
    reminders: [reminder(4, "Contract draft", ReminderState.Late, -DAY)],
  });
  h.attention.refresh();
  // Reasons keep each kind of action together; urgency still sorts within one
  // reason. Undated assigned work and future deadlines stay in the same group.
  assert.deepEqual(Array.from(h.attention.getState().rows, (row) => row.id), [2n, 3n, 1n, 4n]);
});

test("rows of the same urgency fall back to the nearest deadline", () => {
  const h = harness({
    tasks: [task(1, { dueAt: nanos(now + 5 * DAY) }), task(2, { dueAt: nanos(now + DAY) })],
  });
  h.attention.refresh();
  assert.deepEqual(Array.from(h.attention.getState().rows, (row) => row.id), [2n, 1n]);
});

test("each count query asks the server for one filter and reads its total", () => {
  const h = harness({ tasks: [task(1)], counts: { mine: 4, blocked: 2, overdue: 1 } });
  h.attention.refresh();
  // The absence of a filter has to travel as an absence: a query carries a
  // project flag, and an empty string asks the server for the tasks that have no
  // project label instead of for every task.
  assert.deepEqual({ ...h.sentQueries[0] }, {
    status: "open", assignee: "me", project: null, color: null, blocked: null, overdue: false, search: "",
  });
  assert.deepEqual(h.sentQueries.map((filters) => [filters.assignee, filters.blocked, filters.overdue, filters.status]), [
    ["me", null, false, "open"],
    [null, true, false, "open"],
    ["me", null, true, "open"],
  ]);
  const counts = h.attention.getState().counts;
  assert.deepEqual({ ...counts }, { mine: 4, blocked: 0, overdue: 1 });
});

test("a task row opens the task and a reminder row opens the reminder", () => {
  const h = harness({
    tasks: [task(1)],
    reminders: [reminder(4, "Contract draft", ReminderState.Late, -DAY)],
  });
  h.attention.refresh();
  for (const row of h.attention.getState().rows) row.open();

  const targets = h.opened.map((ref) => [ref.type, String(ref.id)]).sort();
  assert.deepEqual(targets, [["reminder", "4"], ["task", "1"]]);
});

test("unread messages become a row per conversation, with the mention as its subject", () => {
  const h = harness({
    unread: [
      { convId: 3n, count: 3, mentionCount: 1, authors: ["MARA KOVAC", "TOBIAS L."], mentionText: "@rene can you confirm?", mentionSequence: 7n, firstSequence: 7n, oldestTimestamp: nanos(now - 6 * 60 * 1000) },
      { convId: 4n, count: 2, mentionCount: 0, authors: ["MARA KOVAC"], firstSequence: null, oldestTimestamp: nanos(now - 4 * 60 * 1000) },
    ],
    dms: [{ convId: 99n, username: "mara", authenticated: true }],
  });
  h.attention.refresh();
  const rows = h.attention.getState().rows;
  assert.deepEqual(Array.from(rows, (row) => [row.kind, row.group, row.chip.label, row.jumpable]), [
    ["MENTION", "message", "@ YOU", true],
    ["MESSAGE", "message", "2 NEW", false],
  ]);
  assert.equal(rows[0].title, "@rene can you confirm?", "a mention leads with what was said");
  assert.equal(rows[1].title, "2 new messages");
  assert.equal(rows[0].detail, "ROOM 3 · MARA KOVAC, TOBIAS L.");
  assert.equal(rows[1].detail, "ROOM 4 · MARA KOVAC", "a room without a retained sequence is not jumpable");
});

test("a direct message is its own kind and never claims a jump", () => {
  const h = harness({
    unread: [{ convId: 99n, count: 1, mentionCount: 1, authors: ["MARA KOVAC"], mentionText: "@rene ping", mentionSequence: 7n, firstSequence: 7n, oldestTimestamp: nanos(now - 60 * 1000) }],
    dms: [{ convId: 99n, username: "mara", authenticated: true }],
  });
  h.attention.refresh();
  const row = h.attention.getState().rows[0];
  assert.equal(row.kind, "DM");
  assert.equal(row.title, "MARA");
  assert.equal(row.detail, "DIRECT · 1 UNREAD");
  assert.equal(row.jumpable, false, "retained direct messages are not enabled");
});

test("a jump opens the room, asks for one page and flashes the target", () => {
  const h = harness({
    unread: [{ convId: 3n, count: 1, mentionCount: 1, authors: ["MARA KOVAC"], mentionText: "@rene ping", mentionSequence: 8n, firstSequence: 8n, oldestTimestamp: nanos(now) }],
    retained: { convId: 3n, state: "enabled" },
  });
  h.attention.refresh();
  h.attention.getState().rows[0].open();

  assert.deepEqual(h.openedRooms, [3n]);
  assert.equal(h.historyRequests.length, 1);
  assert.equal(h.historyRequests[0].cursor, 9n, "the page ends at the target");
  assert.equal(h.historyRequests[0].options.single, true, "a jump fetches one page, not a backfill");

  h.historyRequests[0].options.onPage({ retentionCutoffSeq: 0n });
  assert.deepEqual(h.scrolls, [["8", "center"]]);
  assert.deepEqual(h.flashes, ["8:chat-target"]);
  assert.deepEqual(h.logLines, []);

  h.runTimers();
  assert.equal(h.targetRows.get("8").classes.has("chat-target"), false, "the flash clears itself");
});

test("a target that was trimmed is reported instead of flashed", () => {
  const h = harness({
    unread: [{ convId: 3n, count: 1, mentionCount: 1, authors: ["MARA KOVAC"], mentionText: "@rene ping", mentionSequence: 7n, firstSequence: 7n, oldestTimestamp: nanos(now) }],
    retained: { convId: 3n, state: "enabled" },
  });
  h.attention.refresh();
  h.attention.getState().rows[0].open();
  h.historyRequests[0].options.onPage({ retentionCutoffSeq: 9n });

  assert.deepEqual(h.flashes, [], "nothing is flashed when the message is gone");
  assert.deepEqual(h.logLines, ["MESSAGE 7 IS NO LONGER RETAINED · OPENED LATEST"]);
});

test("a room without retained history opens without a fetch", () => {
  const h = harness({
    unread: [{ convId: 3n, count: 1, mentionCount: 1, authors: ["MARA KOVAC"], mentionText: "@rene ping", mentionSequence: 7n, firstSequence: 7n, oldestTimestamp: nanos(now) }],
    retained: { convId: 3n, state: "disabled" },
  });
  h.attention.refresh();
  h.attention.getState().rows[0].open();
  assert.deepEqual(h.openedRooms, [3n]);
  assert.deepEqual(h.historyRequests, []);
  assert.deepEqual(h.logLines, ["NO RETAINED HISTORY IN ROOM 3 · OPENED LATEST"]);
});

test("the message filter covers mentions, messages and direct messages", () => {
  const h = harness({
    unread: [
      { convId: 3n, count: 1, mentionCount: 1, authors: ["MARA KOVAC"], mentionText: "@rene ping", mentionSequence: 7n, firstSequence: 7n, oldestTimestamp: nanos(now) },
      { convId: 4n, count: 2, mentionCount: 0, authors: ["TOBIAS L."], firstSequence: null, oldestTimestamp: nanos(now) },
      { convId: 99n, count: 1, mentionCount: 0, authors: ["MARA KOVAC"], firstSequence: null, oldestTimestamp: nanos(now) },
    ],
    dms: [{ convId: 99n, username: "mara", authenticated: true }],
    tasks: [task(1)],
  });
  h.elements.attentionBody = { innerHTML: "", addEventListener() {} };
  h.attention.refresh();
  h.attention.setFilter("message");
  assert.equal(h.attention.getState().rows.filter((row) => row.group === "message").length, 3);
  assert.match(h.elements.attentionBody.innerHTML, /MARA/);
  assert.doesNotMatch(h.elements.attentionBody.innerHTML, /Task 1/);
});

test("work changes refresh the register while it is on screen", () => {
  const h = harness({ tasks: [task(1)], counts: { mine: 1 } });
  h.elements.attentionBody = { innerHTML: "", addEventListener() {} };
  h.attention.refresh();
  assert.equal(h.sentQueries.length, 3);
  h.attention.refreshSoon();
  h.attention.refreshSoon();
  assert.equal(h.sentQueries.length, 3, "a burst of changes waits for the debounce");
  assert.equal(h.timerCount(), 1, "and coalesces into one walk");
  h.runTimers();
  assert.equal(h.sentQueries.length, 6, "the debounced walk runs all three queries");
});

test("an empty register says so and clears the sidebar count", () => {
  const h = harness({ elements: {} });
  const badge = { textContent: "07", hidden: false, setAttribute() {} };
  h.elements.attentionViewCount = badge;
  h.elements.attentionCount = { textContent: "" };
  h.elements.attentionBody = { innerHTML: "", addEventListener() {} };
  h.attention.refresh();
  assert.match(h.elements.attentionBody.innerHTML, /NOTHING NEEDS ATTENTION/);
  assert.equal(h.elements.attentionCount.textContent, "0 ITEMS · BY REASON");
  assert.equal(badge.textContent, "");
  assert.equal(badge.hidden, true);
});

test("the sidebar count and the kind filter follow the rows", () => {
  const h = harness({
    tasks: [task(1), task(2, { blockedBy: 9n })],
    reminders: [reminder(4, "Contract draft", ReminderState.Late, -DAY)],
  });
  const badge = { textContent: "", hidden: true, setAttribute(name, value) { this[name] = value; } };
  const body = { innerHTML: "", addEventListener() {} };
  h.elements.attentionViewCount = badge;
  h.elements.attentionBody = body;
  h.attention.refresh();
  assert.equal(badge.textContent, "02", "ordinary blocked work is not actionable");
  assert.equal(badge.hidden, false);
  assert.equal(badge["aria-label"], "2 items need attention");

  h.attention.setFilter("reminder");
  assert.equal(h.attention.getState().filter, "reminder");
  assert.match(body.innerHTML, /Contract draft/);
  assert.doesNotMatch(body.innerHTML, /Task 1/);
});

test("a row title is escaped, never injected", () => {
  const h = harness({ tasks: [task(1, { title: "<img src=x onerror=alert(1)>" })] });
  h.elements.attentionBody = { innerHTML: "", addEventListener() {} };
  h.attention.refresh();
  assert.doesNotMatch(h.elements.attentionBody.innerHTML, /<img/);
  assert.match(h.elements.attentionBody.innerHTML, /&lt;img/);
});

test("dependent and prerequisite links are escaped", () => {
  const h = harness({
    tasks: [task(1), task(2, { blockedBy: 9n, dueAt: nanos(now - DAY) })],
    dependencyPages: [{
      tasks: [task(8, { title: "<svg onload=alert(1)>", assignee: "<admin>", blockedBy: 1n })],
      total: 1,
      hasMore: false,
    }],
  });
  h.elements.attentionBody = { innerHTML: "", addEventListener() {} };
  h.attention.refresh();
  const html = h.elements.attentionBody.innerHTML;
  assert.doesNotMatch(html, /<svg|<admin>/);
  assert.match(html, /&lt;svg onload=alert\(1\)&gt;/);
  assert.match(html, /&lt;admin&gt;/);
  assert.match(html, /Prerequisite #9/);
});

test("a dropped connection abandons the count walk", () => {
  const h = harness({ tasks: [task(1)], counts: { mine: 1 } });
  h.attention.refresh();
  assert.equal(h.attention.getState().mode, "ready");
  h.attention.disconnect();
  assert.equal(h.attention.getState().mode, "idle");
  assert.deepEqual(h.sentQueries.length, 3, "the next refresh starts a fresh walk");
  h.attention.refresh();
  assert.deepEqual(h.sentQueries.length, 6);
});

test("entering the view refreshes, leaving it does not", () => {
  const h = harness({ tasks: [task(1)] });
  h.attention.onViewChanged("notes");
  assert.equal(h.attention.getState().mode, "idle");
  h.attention.onViewChanged("attention");
  assert.equal(h.attention.getState().mode, "ready");
});

test("arrow keys walk the register from wherever the focus is", () => {
  const h = harness({
    tasks: [task(1), task(2)],
    reminders: [reminder(4, "Contract draft", ReminderState.Late, -DAY)],
  });
  h.attention.init();
  h.attention.refresh();
  const keys = h.attention.getState().rows.map((row) => row.key);
  assert.equal(keys.length, 3);

  assert.equal(h.press("ArrowDown"), true, "a key pressed outside the list enters it");
  assert.deepEqual(h.focused, [keys[0]]);
  h.press("ArrowDown");
  assert.deepEqual(h.focused, [keys[0], keys[1]]);
  h.press("ArrowUp");
  assert.deepEqual(h.focused, [keys[0], keys[1], keys[0]]);
  h.press("ArrowUp");
  assert.deepEqual(h.focused.length, 3, "the walk stops at the first row");
  h.press("ArrowDown");
  h.press("ArrowDown");
  h.press("ArrowDown");
  assert.equal(h.focused.at(-1), keys[2], "and at the last one");
  assert.deepEqual(h.rowScrolls, [[keys[0], "nearest"], [keys[1], "nearest"], [keys[0], "nearest"], [keys[1], "nearest"], [keys[2], "nearest"]]);
});

test("arrow keys leave the keyboard to a field, a dialog and another view", () => {
  const h = harness({ tasks: [task(1)] });
  h.attention.init();
  h.attention.refresh();
  assert.equal(h.press("ArrowDown", { target: { tagName: "SELECT" } }), false);
  assert.equal(h.press("ArrowDown", { target: { tagName: "BODY", closest: (selector) => (selector.includes("role=dialog") ? {} : null) } }), false);
  assert.equal(h.press("ArrowDown", { ctrlKey: true }), false);
  assert.equal(h.press("ArrowDown", { defaultPrevented: true }), false);
  assert.deepEqual(h.focused, []);

  h.viewState.active = "kanban";
  assert.equal(h.press("ArrowDown"), false, "another view keeps the arrows");
  assert.deepEqual(h.focused, []);

  h.viewState.active = "attention";
  h.press("ArrowDown");
  assert.equal(h.focused.length, 1);
});
