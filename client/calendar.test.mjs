import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { execFileSync } from "node:child_process";

const calendarSource = fs.readFileSync(new URL("./calendar.js", import.meta.url), "utf8");
const querySource = fs.readFileSync(new URL("./task-query.js", import.meta.url), "utf8");
const ns = value => BigInt(Date.parse(value)) * 1000000n;

function response(request, rows, { more = false, cursor = null, correlation = null } = {}) {
  const encoder = new TextEncoder();
  const encoded = rows.map(row => ({ ...row, strings: [row.title, row.assignee || "", row.project || ""].map(value => encoder.encode(value)) }));
  const size = 34 + encoded.reduce((total, row) => total + 18 + row.strings.reduce((n, value) => n + 2 + value.length, 0) + (row.kind === 2 ? 16 : 0), 0);
  const view = new DataView(new ArrayBuffer(size));
  view.setUint16(0, 166); view.setBigUint64(2, 0n); view.setUint16(10, rows.length); view.setUint8(12, more ? 1 : 0);
  const last = cursor || rows.at(-1) || { at: 0n, kind: 0, id: 0n };
  view.setBigInt64(13, last.at); view.setUint8(21, last.kind || 0); view.setBigUint64(22, last.id);
  let offset = 30;
  for (const row of encoded) {
    view.setUint8(offset++, row.kind || 0); view.setBigUint64(offset, row.id); offset += 8;
    view.setBigInt64(offset, row.at); offset += 8; view.setUint8(offset++, row.blocked ? 1 : 0);
    for (const bytes of row.strings) { view.setUint16(offset, bytes.length); offset += 2; new Uint8Array(view.buffer, offset, bytes.length).set(bytes); offset += bytes.length; }
    if (row.kind === 2) { view.setBigInt64(offset, row.actualStartAt); offset += 8; view.setBigInt64(offset, row.endAt || 0n); offset += 8; }
  }
  view.setUint32(offset, correlation ?? request.getUint32(request.byteLength - 4));
  return view;
}

function harness({ ready = true } = {}) {
  const elements = {}, listeners = {}, sent = [], opened = [];
  let id = 40;
  const element = id => elements[id] ||= { id, innerHTML: "", textContent: "", value: "", hidden: false,
    attributes: {}, setAttribute(name, value) { this.attributes[name] = value; },
    addEventListener(name, fn) { (this.listeners ||= {})[name] = fn; }, querySelectorAll() { return []; } };
  for (const id of ["calendarBody", "calendarRange", "calendarCount", "calendarContext", "calendarStatus", "calendarPerson",
    "calendarProject", "calendarPanel", "calendarControls"]) element(id);
  const document = { activeElement: null, hidden: false, getElementById: id => elements[id] || null,
    querySelectorAll: () => [], addEventListener: (name, fn) => { listeners[name] = fn; } };
  const window = { NRCViewManager: { getActiveView: () => "calendar" }, NRCInspector: { openEntity: ref => opened.push(ref) } };
  const detachedTimeout = (fn, delay) => { const timer = setTimeout(fn, delay); timer.unref(); return timer; };
  const context = { window, document, TextEncoder, TextDecoder, ArrayBuffer, DataView, Uint8Array, Date, Intl, BigInt, Number,
    String, Math, Array, Object, Set, Map, JSON, WebSocket: { OPEN: 1 }, serverReady: ready,
    ws: { readyState: ready ? 1 : 0 }, myNickname: "rene", getRpcCorrelationId: () => ++id,
    sendPacket: buffer => sent.push(new DataView(buffer)), readString() {}, parseTask() {}, setTimeout: detachedTimeout, clearTimeout };
  vm.runInNewContext(querySource, context);
  vm.runInNewContext(calendarSource, context);
  window.NRCCalendar.getState().month = "2026-09";
  window.NRCCalendar.getState().day = "2026-09-15";
  window.NRCCalendar.init();
  const requests = opcode => sent.filter(view => view.getUint16(0) === opcode);
  return { calendar: window.NRCCalendar, elements, sent, requests, opened,
    metadata: () => {
      for (const opcode of [29, 57]) {
        const request = requests(opcode).at(-1);
        const values = opcode === 29 ? ["NRC", "OUTSIDE MONTH"] : ["rene", "outside-owner"];
        const bytes = values.map(value => new TextEncoder().encode(value));
        const view = new DataView(new ArrayBuffer(17 + bytes.reduce((n, b) => n + 2 + b.length, 0)));
        view.setUint16(10, values.length);
        let offset = 12;
        for (const b of bytes) { view.setUint16(offset, b.length); offset += 2; new Uint8Array(view.buffer, offset, b.length).set(b); offset += b.length; }
        view.setUint32(offset + 1, request.getUint32(10));
        if (opcode === 29) window.NRCCalendar.handleTaskProjects(view);
        else window.NRCCalendar.handleTaskAssignees(view);
      }
    },
    reply: (request, rows, options) => window.NRCCalendar.handlePage(response(request, rows, options)) };
}

const task = (id, title = `Task ${id}`, at = ns("2026-09-15T12:30:00Z"), overrides = {}) =>
  ({ id: BigInt(id), kind: 0, title, at, assignee: "rene", project: "NRC", blocked: false, ...overrides });
const reminder = (id, title = `Reminder ${id}`, at = ns("2026-09-16T08:45:00Z")) =>
  ({ id: BigInt(id), kind: 1, title, at, assignee: "", project: "", blocked: false });
const appointment = (id, overrides = {}) => ({ id: BigInt(id), kind: 2, title: `Appointment ${id}`,
  at: ns("2026-09-01T00:00:00Z"), actualStartAt: ns("2026-08-31T22:00:00Z"), endAt: ns("2026-09-02T10:00:00Z"),
  assignee: "alex", project: "OPS", blocked: false, ...overrides });

test("range request uses opcodes 58/166, local grid bounds, filters, and workspace metadata", () => {
  const h = harness(); h.calendar.refresh();
  assert.deepEqual(h.sent.slice(0, 3).map(view => view.getUint16(0)), [29, 57, 58]);
  assert.equal(h.sent[0].getBigUint64(2), 0n); assert.equal(h.sent[1].getBigUint64(2), 0n);
  const request = h.requests(58)[0];
  assert.equal(request.getBigUint64(2), 0n); assert.equal(request.getBigInt64(10), ns("2026-09-01T00:00:00"));
  assert.equal(request.getBigInt64(18), ns("2026-10-01T00:00:00")); assert.equal(request.getUint16(26), 100);
  assert.equal(request.getUint8(28), 0); assert.equal(request.byteLength, 54);
  h.reply(request, []);
  assert.equal(h.calendar.getState().status, "loading", "metadata must finish too");
  h.metadata(); assert.equal(h.calendar.getState().status, "ready");
  assert.match(h.elements.calendarPerson.innerHTML, /outside-owner/);
  assert.match(h.elements.calendarProject.innerHTML, /OUTSIDE MONTH/);

  h.calendar.getState().mode = "month"; h.elements.calendarPerson.value = "me";
  h.elements.calendarPerson.listeners.change({ target: h.elements.calendarPerson });
  const filtered = h.requests(58).at(-1);
  assert.equal(new TextDecoder().decode(new Uint8Array(filtered.buffer, 48, 4)), "rene");
  const days = h.calendar.monthDays("2026-09");
  assert.equal(filtered.getBigInt64(10), ns(`${days[0]}T00:00:00`));
  assert.equal(filtered.getBigInt64(18), ns("2026-10-05T00:00:00"));
  h.elements.calendarProject.value = "R&D";
  h.elements.calendarProject.listeners.change({ target: h.elements.calendarProject });
  const project = h.requests(58).at(-1);
  assert.equal(h.requests(58).length, 3, "each filter change issues a fresh range query");
  assert.equal(new TextDecoder().decode(new Uint8Array(project.buffer, 54, 3)), "R&D");
});

test("pagination is staged, stale correlations are ignored, and no arbitrary page cap exists", () => {
  const h = harness(); h.calendar.refresh(); const first = h.requests(58)[0];
  h.metadata();
  h.calendar.handlePage(response(first, [task(99)], { correlation: first.getUint32(first.byteLength - 4) + 1 }));
  assert.equal(h.calendar.getState().rows.length, 0);
  h.reply(first, [task(1)], { more: true });
  assert.equal(h.elements.calendarBody.hidden, true); assert.equal(h.elements.calendarBody.inert, true);
  assert.equal(h.calendar.getState().rows.length, 0);
  for (let page = 1; page <= 55; page++) {
    const request = h.requests(58).at(-1);
    assert.equal(request.getUint8(28), 1);
    h.reply(request, [task(page + 1)], { more: page < 55 });
  }
  assert.equal(h.requests(58).length, 56); assert.equal(h.calendar.getState().rows.length, 56);
  assert.equal(h.calendar.getState().status, "ready"); assert.equal(h.elements.calendarBody.hidden, false);
  assert.equal(h.elements.calendarBody.inert, false); assert.equal(h.elements.calendarControls.hidden, false);
  assert.equal(h.elements.calendarControls.inert, false);
});

test("the calendar stays unchanged until rows and all metadata are loaded", () => {
  const h = harness();
  h.calendar.refresh();
  h.metadata();
  h.reply(h.requests(58)[0], [task(1, "Complete snapshot")]);
  const complete = h.elements.calendarBody.innerHTML;
  assert.match(complete, /Complete snapshot/);

  h.calendar.refresh();
  const next = h.requests(58).at(-1);
  assert.equal(h.elements.calendarBody.innerHTML, complete, "refresh keeps the last complete view");
  assert.equal(h.elements.calendarBody.hidden, false, "a complete snapshot remains visible while its replacement loads");
  assert.equal(h.elements.calendarBody.inert, true, "retained rows cannot be opened while their snapshot is stale");
  assert.equal(h.elements.calendarControls.inert, true, "filters cannot start another mixed snapshot");
  assert.equal(h.elements.calendarBody.attributes["aria-busy"], "true");

  h.reply(next, [task(2, "Replacement snapshot")]);
  assert.equal(h.elements.calendarBody.innerHTML, complete, "rows alone do not render before metadata");
  h.metadata();
  assert.match(h.elements.calendarBody.innerHTML, /Replacement snapshot/);
  assert.doesNotMatch(h.elements.calendarBody.innerHTML, /Complete snapshot/);
  assert.equal(h.elements.calendarBody.inert, false);
  assert.equal(h.elements.calendarControls.inert, false);
  assert.equal(h.elements.calendarBody.attributes["aria-busy"], "false");
});

test("month and grid calculations remain local and stable through DST", () => {
  const calendar = harness().calendar;
  assert.deepEqual(Array.from(calendar.monthDays("2026-09")).slice(0, 2), ["2026-08-31", "2026-09-01"]);
  assert.equal(calendar.monthDays("2024-02").filter(day => day.startsWith("2024-02")).length, 29);
  const script = `const fs=require('fs'),vm=require('vm');const window={};const document={getElementById(){}};
    vm.runInNewContext(fs.readFileSync(${JSON.stringify(new URL("./calendar.js", import.meta.url).pathname)},'utf8'),{window,document,Date,Intl,BigInt,Number,String,Math,Array,Object,Set,Map,TextEncoder,TextDecoder});
    const c=window.NRCCalendar; process.stdout.write(JSON.stringify([c.monthDays('2026-03'),c.monthDays('2026-11'),c.visibleRange('2026-03','month')],(_,v)=>typeof v==='bigint'?String(v):v));`;
  const [spring, fall, range] = JSON.parse(execFileSync(process.execPath, ["-e", script], { env: { ...process.env, TZ: "America/New_York" }, encoding: "utf8" }));
  assert.deepEqual([spring[0], spring.at(-1)], ["2026-02-23", "2026-04-05"]);
  assert.deepEqual([fall[0], fall.at(-1)], ["2026-10-26", "2026-12-06"]);
  assert.equal(range.start, String(ns("2026-02-23T00:00:00-05:00")));
  assert.equal(range.end, String(ns("2026-04-06T00:00:00-04:00")));
});

test("compact summaries escape markup and every row surface opens the typed inspector", () => {
  const h = harness(); h.calendar.refresh(); const request = h.requests(58)[0];
  h.metadata();
  h.reply(request, [task(7, '<b>"unsafe" & gone</b>', undefined, { assignee: 'a"<', project: "p&", blocked: true }), reminder(7)]);
  let html = h.elements.calendarBody.innerHTML;
  assert.match(html, /&lt;b&gt;&quot;unsafe&quot; &amp; gone&lt;\/b&gt;/); assert.doesNotMatch(html, /<b>"unsafe"/);
  assert.match(html, /title="a&quot;&lt;"/); assert.match(html, /title="p&amp;"/);
  const click = key => h.elements.calendarPanel.listeners.click({ target: { closest: selector => selector === "[data-calendar-row]" ? { dataset: { calendarRow: key } } : null } });
  click("task:7"); click("reminder:7");
  assert.deepEqual(h.opened.map(ref => [ref.roomId, ref.type, ref.id]), [[0n, "task", 7n], [0n, "reminder", 7n]]);
});

test("appointment rows decode their appended interval, span local days, expose facets, and open the inspector", () => {
  const h = harness(); h.calendar.refresh(); const request = h.requests(58)[0]; h.metadata();
  h.reply(request, [appointment(12)]);
  const row = h.calendar.getState().rows[0];
  assert.equal(row.kind, "appointment"); assert.equal(row.actualStartAt, ns("2026-08-31T22:00:00Z"));
  assert.equal(row.endAt, ns("2026-09-02T10:00:00Z"));
  assert.equal(h.calendar.occursOnDay(row, "2026-09-01"), true);
  assert.equal(h.calendar.occursOnDay(row, "2026-09-02"), true);
  assert.equal(h.calendar.occursOnDay(row, "2026-09-03"), false);
  assert.equal(h.calendar.occursOnDay({ ...row, actualStartAt: ns("2026-09-01T12:00:00Z"), endAt: ns("2026-09-02T00:00:00") }, "2026-09-02"), false,
    "an interval ending at local midnight does not occupy the next day");
  assert.match(h.elements.calendarPerson.innerHTML, /alex/); assert.match(h.elements.calendarProject.innerHTML, /OPS/);
  h.calendar.getState().mode = "month";
  row.day = "2026-08-31"; // grid starts in the previous month, but this interval crosses into September
  h.calendar.render();
  assert.equal(h.elements.calendarCount.textContent, "1 ITEMS");
  h.calendar.getState().mode = "agenda";
  row.day = "2026-09-01";
  h.calendar.getState().person = "alex"; h.calendar.render(); assert.match(h.elements.calendarBody.innerHTML, /Appointment 12/);
  h.calendar.getState().person = "rene"; h.calendar.render(); assert.doesNotMatch(h.elements.calendarBody.innerHTML, /Appointment 12/);
  h.elements.calendarPanel.listeners.click({ target: { closest: selector => selector === "[data-calendar-row]" ? { dataset: { calendarRow: "appointment:12" } } : null } });
  assert.deepEqual(Array.from(Object.values(h.opened.at(-1))), [0n, "appointment", 12n]);
});

test("disconnect clears a pending snapshot and renders offline", () => {
  const h = harness(); h.calendar.refresh(); h.calendar.disconnect();
  assert.equal(h.calendar.getState().status, "offline"); assert.deepEqual(Array.from(h.calendar.getState().rows), []);
  assert.match(h.elements.calendarStatus.textContent, /OFFLINE/);
});

test("remote task deletion notifies summary views without a task cache", () => {
  const source = fs.readFileSync(new URL("./tasks.js", import.meta.url), "utf8");
  const events = [];
  const context = { roomTasks: new Map(), selectedTaskId: null, selectedTaskConvId: null,
    kanbanVisible: false, refreshTaskSearchAfterMutation() {}, console,
    notifyTaskChanged: (task, reason) => events.push([String(task.id), String(task.convId), reason]) };
  vm.runInNewContext(source.slice(source.indexOf("function handleTaskDeleted("), source.indexOf("function handleTaskMoved(")), context);
  const view = new DataView(new ArrayBuffer(22));
  view.setBigUint64(2, 19n);
  context.handleTaskDeleted(view);
  assert.deepEqual(events, [["19", "0", "deleted"]]);
});
