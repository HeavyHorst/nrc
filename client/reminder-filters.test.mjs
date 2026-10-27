import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

// Exercise local calendar days across Berlin's spring DST transition.
process.env.TZ = "Europe/Berlin";
const nanos = (date) => BigInt(Date.parse(date)) * 1000000n;

function harness() {
  const now = Date.parse("2026-03-29T12:00:00+02:00");
  const body = { innerHTML: "", querySelectorAll: () => [] };
  const count = {};
  const buttons = ["all", "today", "upcoming", "overdue"].map((value) => {
    const label = { textContent: "" };
    const countSlot = { textContent: "" };
    const button = {
      dataset: { reminderFilter: value }, classList: { toggle() {} },
      setAttribute(name, value) { this[name] = value; },
      addEventListener(name, callback) { this[name] = callback; },
      querySelector: (selector) => selector === "span" ? label : selector === ".tab-count" ? countSlot : null,
    };
    // A tab reads as its label plus the count in its own slot; the slot is what
    // a refresh writes, so the label survives it.
    Object.defineProperty(button, "textContent", { get: () => `${label.textContent} ${countSlot.textContent}` });
    return button;
  });
  const assets = [
    [1, "Later open", "2026-04-10T12:00:00+02:00", ""],
    [2, "Tomorrow locked", "2026-03-30T12:00:00+02:00", "2026-03-30T08:00:00+02:00"],
    [3, "Today overdue", "2026-03-29T00:00:00+01:00", ""],
    [4, "Today at deadline", "2026-03-29T12:00:00+02:00", ""],
  ].map(([id, title, due, start]) => ({
    assetId: BigInt(id), convId: 7n, assetType: 9,
    payload: JSON.stringify({ title, deadline_at: String(nanos(due)), window_start_at: start ? String(nanos(start)) : "0" }),
  }));
  let saved;
  const context = vm.createContext({
    window: { NRCAssets: { getAssetsByType: () => assets } },
    document: {
      addEventListener() {},
      createElement: () => ({ set textContent(value) { this.innerHTML = value; } }),
      getElementById: (id) => ({ reminderQueueBody: body, reminderQueueCount: count, reminderColumnsReset: {} })[id] || null,
      querySelectorAll: (selector) => selector === "[data-reminder-filter]" ? buttons : [],
    },
    Date: class extends Date { static now() { return now; } },
    clearTimeout, setTimeout,
    TextDecoder, TextEncoder, DataView, Uint8Array, ArrayBuffer, BigInt,
    AssetType: { Reminder: 9 }, currentRoomId: 7n,
    localStorage: { getItem: () => saved || null, setItem: (_key, value) => { saved = value; } },
  });
  for (const file of ["protocol.js", "task-state.js", "tasks.js"]) {
    vm.runInContext(fs.readFileSync(`client/${file}`, "utf8"), context);
  }
  vm.runInContext("initTaskViewState(); renderReminderQueue();", context);
  return { context, buttons, body, count, saved: () => saved };
}

test("reminder filters count independently, keep selection in memory, and compose with hide locked", () => {
  const { context, buttons, body, count, saved } = harness();
  assert.deepEqual(buttons.map((b) => b.textContent), ["ALL 4", "TODAY 2", "UPCOMING 3", "OVERDUE 1"]);
  const ids = () => [...body.innerHTML.matchAll(/data-reminder-row-id="(\d+)"/g)].map((m) => m[1]);
  assert.deepEqual(ids(), ["3", "4", "2", "1"]); // Locked comes before later open.
  buttons[2].click();
  assert.deepEqual(ids(), ["4", "2", "1"]);
  assert.equal(buttons[2]["aria-pressed"], "true");
  assert.equal(buttons[0]["aria-pressed"], "false");
  assert.equal(saved(), undefined);
  assert.equal(vm.runInContext("TaskViewState.filters.reminderView", context), "upcoming");
  vm.runInContext("TaskViewState.filters.hideLockedReminders = true; renderReminderQueue();", context);
  assert.deepEqual(ids(), ["4", "1"]);
  assert.equal(count.textContent, "2 RESULTS");
  assert.deepEqual(buttons.map((b) => b.textContent), ["ALL 3", "TODAY 2", "UPCOMING 2", "OVERDUE 1"]);
  buttons[3].click();
  assert.deepEqual(ids(), ["3"]);
});

test("today uses local midnight boundaries, including the 23-hour DST day", () => {
  const { context } = harness();
  const matches = vm.runInContext("matchesReminderFilter", context);
  const now = nanos("2026-03-29T12:00:00+02:00");
  for (const [date, expected] of [
    ["2026-03-28T23:59:59+01:00", false],
    ["2026-03-29T00:00:00+01:00", true],
    ["2026-03-29T23:59:59+02:00", true],
    ["2026-03-30T00:00:00+02:00", false],
    ["2026-04-29T12:00:00+02:00", false],
  ]) assert.equal(matches({ deadlineAt: nanos(date) }, "today", now), expected, date);
  assert.equal(matches({ deadlineAt: now - 1n }, "overdue", now), true);
  assert.equal(matches({ deadlineAt: now }, "overdue", now), false);
  assert.equal(matches({ deadlineAt: now }, "upcoming", now), true);
});

test("public reminder snapshot and queue distinguish personal, team and legacy preview records", () => {
  const { context, body } = harness();
  const deadline = String(nanos("2026-04-10T12:00:00+02:00"));
  context.window.NRCAssets.getAssetsByType = () => [
    { assetId: 10n, convId: 0n, assetType: 9, payload: JSON.stringify({ title: "Private", deadline_at: deadline, visibility: "personal" }) },
    { assetId: 11n, convId: 0n, assetType: 9, preview: JSON.stringify({ title: "Shared", deadline_at: deadline, visibility: "team" }) },
    { assetId: 12n, convId: 0n, assetType: 9, preview: JSON.stringify({ title: "Legacy", deadline_at: deadline }) },
  ];
  const reminders = context.window.NRCTasks.getReminderSnapshot().reminders;
  assert.deepEqual(Array.from(reminders, r => r.visibility), ["personal", "team", "team"]);
  context.window.NRCTasks.renderReminderQueue();
  assert.match(body.innerHTML, /PERSONAL · OPEN/);
  assert.match(body.innerHTML, /TEAM · OPEN/);
  for (const reminder of reminders) {
    context.reminderForSave = reminder;
    vm.runInContext("currentDetailReminder = reminderForSave", context);
    const fields = {
      reminderDetailTitle: { value: "Edited" }, reminderDetailDeadline: { value: "2026-04-10T12:00" },
      reminderDetailWindowStart: { value: "" }, reminderDetailUrgency: { value: "3" }, reminderDetailNoteId: { value: "" },
    };
    context.document.getElementById = id => fields[id] || null;
    let sent;
    context.window.NRCAssets.sendUpdateAsset = (...args) => { sent = args; };
    vm.runInContext("saveReminderFromDetailPanel()", context);
    assert.equal(sent[2], sent[3], "preview and payload share JSON contract");
    assert.equal(JSON.parse(sent[3]).visibility, reminder.visibility);
    assert.equal(JSON.parse(sent[3]).title, "Edited");
  }
});
