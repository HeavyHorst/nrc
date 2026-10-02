import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

// The reminder timer turns derived reminder states into desktop notifications.
// These cases pin the contract: one summary per session, one popup per real
// transition, silence while the operator is already looking at the register.
const source = fs.readFileSync(new URL("./reminder-notify.js", import.meta.url), "utf8");
const nanos = (iso) => BigInt(Date.parse(iso)) * 1000000n;
const RealDate = Date;

// The timer reads its vocabulary from NRCTasks; the fixtures read the same
// values out of tasks.js so a state rename cannot hide behind a test literal.
const tasksSource = fs.readFileSync(new URL("./tasks.js", import.meta.url), "utf8");
const stateBlock = tasksSource.match(/const ReminderState = \{([^}]*)\}/)[1];
const ReminderState = Object.fromEntries(
  [...stateBlock.matchAll(/(\w+):\s*"([A-Z]+)"/g)].map(([, key, value]) => [key, value]),
);

function reminder(id, title, state, deadline) {
  return { asset: { assetId: BigInt(id), convId: 0n }, title, state, deadlineAt: nanos(deadline) };
}

function harness() {
  const deliveries = [];
  const listeners = {};
  const intervals = [];
  const elements = {};
  const stored = new Map();
  let reminders = [];
  let view = "chat";
  let hidden = false;
  let now = RealDate.parse("2026-09-22T12:00:00Z");

  // The timer reads Date.now() to tell a short view switch from an absence.
  class TestDate extends RealDate {
    constructor(...args) { super(...(args.length ? args : [now])); }
    static now() { return now; }
  }

  const document = {
    addEventListener: (name, callback) => { listeners[name] = callback; },
    getElementById: (id) => elements[id] || null,
  };
  Object.defineProperty(document, "hidden", { get: () => hidden });

  const window = {
    NRCTasks: { getReminderSnapshot: () => ({ assetCount: reminders.length, reminders }), ReminderState },
    NRCViewManager: { getActiveView: () => view, setActiveView: (next) => { view = next; } },
    NRCInspector: { openEntity: (ref) => deliveries.push({ opened: ref }) },
    addEventListener: (name, callback) => { listeners[name] = callback; },
    focus() {},
  };

  const notification = {
    permission: "granted",
    requestPermission: () => Promise.resolve("granted"),
  };

  vm.runInNewContext(source, {
    window,
    document,
    Date: TestDate,
    localStorage: {
      getItem: (key) => (stored.has(key) ? stored.get(key) : null),
      setItem: (key, value) => stored.set(key, value),
    },
    Notification: notification,
    sendNotification: (title, options, onClick) => deliveries.push({ title, options, onClick }),
    updateNotificationStatus() {},
    logMessage() {},
    setInterval: (callback, ms) => { intervals.push({ callback, ms }); return intervals.length; },
    currentWorkspaceId: "workspace-a",
  });

  return {
    notify: window.NRCReminderNotify,
    deliveries, listeners, intervals, elements, stored,
    setReminders: (next) => { reminders = next; },
    setView: (next) => { view = next; },
    setHidden: (next) => { hidden = next; },
    advance: (ms) => { now += ms; },
    setPermission: (value, requested) => {
      notification.permission = value;
      notification.requestPermission = () => { requested.push(value); return Promise.resolve("granted"); };
    },
  };
}

test("the first snapshot of a session summarises instead of firing per reminder", () => {
  const h = harness();
  h.setReminders([
    reminder(1, "Rotate S3 key", ReminderState.Late, "2026-09-19T09:00:00Z"),
    reminder(2, "Access review", ReminderState.Late, "2026-09-20T09:00:00Z"),
    reminder(3, "Contract draft", ReminderState.Open, "2026-10-01T09:00:00Z"),
  ]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 1);
  assert.equal(h.deliveries[0].title, "2 REMINDERS NEED ATTENTION");
  assert.match(h.deliveries[0].options.body, /2 LATE/);
  assert.equal(h.deliveries[0].options.tag, "nrc-reminder-summary");
});

test("a transition into the urgency window fires once and never repeats", () => {
  const h = harness();
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Open, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 0, "an open reminder is not a notification");

  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Urgent, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 1);
  assert.equal(h.deliveries[0].title, "Rotate S3 key");
  assert.match(h.deliveries[0].options.body, /^DUE · 2026-10-01/);
  assert.equal(h.deliveries[0].options.tag, "nrc-reminder-1");

  h.notify.evaluate();
  assert.equal(h.deliveries.length, 1, "the same state does not notify twice");
});

test("a reminder that becomes late reports its deadline", () => {
  const h = harness();
  h.setReminders([reminder(7, "Quarterly review", ReminderState.Open, "2026-09-20T09:00:00Z")]);
  h.notify.evaluate();
  h.setReminders([reminder(7, "Quarterly review", ReminderState.Urgent, "2026-09-20T09:00:00Z")]);
  h.notify.evaluate();
  h.setReminders([reminder(7, "Quarterly review", ReminderState.Late, "2026-09-20T09:00:00Z")]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 2);
  assert.match(h.deliveries[1].options.body, /^LATE · 2026-09-20/);
});

test("a reminder seen for the first time is not a transition", () => {
  const h = harness();
  h.setReminders([reminder(1, "Existing", ReminderState.Open, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();

  h.setReminders([
    reminder(1, "Existing", ReminderState.Open, "2026-10-01T09:00:00Z"),
    reminder(2, "Created elsewhere and already late", ReminderState.Late, "2026-09-01T09:00:00Z"),
  ]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 0);
});

test("the reminders view in front suppresses the popup and does not fire later", () => {
  const h = harness();
  h.setView("reminders");
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Open, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();

  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Urgent, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 0, "the state is already on screen");

  h.setView("chat");
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 0, "a seen state is not re-reported after leaving the view");
});

test("a hidden tab reports even while the reminders view is active", () => {
  const h = harness();
  h.setView("reminders");
  h.setHidden(true);
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Late, "2026-09-19T09:00:00Z")]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 1);
});

test("the workspace switch mutes every notification", () => {
  const h = harness();
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Late, "2026-09-19T09:00:00Z")]);
  h.notify.setMode("off");
  assert.equal(h.stored.get("nrc-reminder-notifications:workspace-a"), "off");
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 0);

  h.setReminders([
    reminder(1, "Rotate S3 key", ReminderState.Late, "2026-09-19T09:00:00Z"),
    reminder(2, "Access review", ReminderState.Urgent, "2026-09-23T09:00:00Z"),
  ]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 0, "transitions stay muted");
});

test("an empty snapshot is not a session start", () => {
  const h = harness();
  h.notify.evaluate();
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Late, "2026-09-19T09:00:00Z")]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 1);
  assert.match(h.deliveries[0].title, /1 REMINDERS NEED ATTENTION/);
});

test("returning to the tab after an absence summarises what came due", () => {
  const h = harness();
  h.notify.init();
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Open, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();
  assert.equal(h.deliveries.length, 0);

  h.setHidden(true);
  h.listeners.visibilitychange();
  h.advance(6 * 60 * 1000);
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Late, "2026-10-01T09:00:00Z")]);
  h.setHidden(false);
  h.listeners.visibilitychange();

  assert.equal(h.deliveries.length, 1, "one summary, not one popup per reminder");
  assert.equal(h.deliveries[0].options.tag, "nrc-reminder-summary");
});

test("a brief view switch reports the transition itself", () => {
  const h = harness();
  h.notify.init();
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Open, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();

  h.setHidden(true);
  h.listeners.visibilitychange();
  h.advance(30 * 1000);
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Late, "2026-10-01T09:00:00Z")]);
  h.setHidden(false);
  h.listeners.visibilitychange();

  assert.equal(h.deliveries.length, 1);
  assert.equal(h.deliveries[0].options.tag, "nrc-reminder-1");
});

test("a reconnect summarises what came due while the tab was away", () => {
  const h = harness();
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Open, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();
  h.setReminders([reminder(1, "Rotate S3 key", ReminderState.Late, "2026-10-01T09:00:00Z")]);
  h.notify.sessionStarted();
  assert.equal(h.deliveries.length, 1);
  assert.equal(h.deliveries[0].options.tag, "nrc-reminder-summary");
});

test("clicking a transition notification opens the reminder in the inspector", () => {
  const h = harness();
  h.setReminders([reminder(4, "Rotate S3 key", ReminderState.Open, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();
  h.setReminders([reminder(4, "Rotate S3 key", ReminderState.Late, "2026-10-01T09:00:00Z")]);
  h.notify.evaluate();
  assert.equal(typeof h.deliveries[0].onClick, "function");
  h.deliveries[0].onClick();
  const opened = h.deliveries[1].opened;
  assert.equal(opened.type, "reminder");
  assert.equal(opened.roomId, 0n);
  assert.equal(opened.id, 4n);
});

test("init wires the timer, the focus catch-up and the header switch", () => {
  const h = harness();
  const select = { value: "", dataset: {}, addEventListener(name, callback) { this[name] = callback; } };
  h.elements.reminderNotifications = select;
  h.notify.init();
  select.change({ target: { value: "off" } });
  assert.equal(h.notify.mode(), "off", "the ATTENTION header switch is the visible control");
  assert.equal(select.value, "off");
  select.change({ target: { value: "all" } });
  assert.equal(h.notify.mode(), "all");
  assert.equal(h.intervals.length, 1);
  assert.equal(h.intervals[0].ms, 60000);
  assert.equal(typeof h.listeners.visibilitychange, "function");
  assert.equal(typeof h.listeners.focus, "function");
});

test("the workspace switch persists and asks for permission when it is turned on", () => {
  const h = harness();
  const requested = [];
  h.notify.init();
  h.setPermission("default", requested);

  h.notify.setMode("off");
  assert.equal(h.stored.get("nrc-reminder-notifications:workspace-a"), "off");
  assert.equal(h.notify.mode(), "off");
  assert.deepEqual(requested, [], "turning the timer off never asks for permission");

  h.notify.setMode("all");
  assert.equal(h.stored.get("nrc-reminder-notifications:workspace-a"), "all");
  assert.deepEqual(requested, ["default"]);
});
