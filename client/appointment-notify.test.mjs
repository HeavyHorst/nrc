import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const calendar = fs.readFileSync(new URL("./calendar.js", import.meta.url), "utf8");
const source = fs.readFileSync(new URL("./appointment-notify.js", import.meta.url), "utf8");
const base = Date.parse("2026-09-28T12:00:00Z");
const nanos = minutes => BigInt(base + minutes * 60000) * 1000000n;
const row = (id, minutes, extra = {}) => ({ id: BigInt(id), kind: 2, at: nanos(minutes), actualStartAt: nanos(minutes),
  endAt: 0n, title: `Meeting ${id}`, assignee: "rene", project: "NRC", ...extra });
function page(request, rows, more = false) {
  const strings = rows.map(r => [r.title, r.assignee, r.project].map(s => new TextEncoder().encode(s)));
  const view = new DataView(new ArrayBuffer(34 + rows.reduce((size, r, i) => size + 18 + (r.kind === 2 ? 16 : 0) + strings[i].reduce((s, b) => s + 2 + b.length, 0), 0)));
  view.setUint16(0, 166); view.setUint16(10, rows.length); view.setUint8(12, +more);
  const last = rows.at(-1) || row(0, 0);
  view.setBigInt64(13, last.at); view.setUint8(21, last.kind); view.setBigUint64(22, last.id);
  let offset = 30;
  rows.forEach((r, i) => {
    view.setUint8(offset++, r.kind); view.setBigUint64(offset, r.id); offset += 8;
    view.setBigInt64(offset, r.at); offset += 8; view.setUint8(offset++, 0);
    for (const bytes of strings[i]) {
      view.setUint16(offset, bytes.length); offset += 2;
      new Uint8Array(view.buffer, offset, bytes.length).set(bytes); offset += bytes.length;
    }
    if (r.kind === 2) { view.setBigInt64(offset, r.actualStartAt); view.setBigInt64(offset + 8, r.endAt); offset += 16; }
  });
  view.setUint32(offset, request.getUint32(request.byteLength - 4));
  return view;
}
function harness(stored = new Map(), locks = null) {
  let time = base, id = 0, success = true;
  const sent = [], delivered = [], opened = [], listeners = {}, timers = new Map();
  const document = { addEventListener: (event, fn) => { listeners[event] = fn; }, hidden: true };
  const window = { navigator: { locks }, addEventListener: (event, fn) => { listeners[event] = fn; }, focus() {},
    NRCInspector: { openEntity: ref => opened.push(ref) } };
  class Clock extends Date { constructor(...args) { super(...(args.length ? args : [time])); } static now() { return time; } }
  const context = vm.createContext({ window, document, Date: Clock, Intl, TextEncoder, TextDecoder, ArrayBuffer, Uint8Array, DataView,
    currentWorkspaceId: "test", myNickname: "rene", serverReady: true, ws: { readyState: 1 }, WebSocket: { OPEN: 1 },
    Notification: { permission: "granted", requestPermission: async () => "granted" },
    localStorage: { getItem: key => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value) },
    setTimeout: fn => { const n = ++id; timers.set(n, fn); return n; }, clearTimeout: n => timers.delete(n),
    setInterval: fn => { listeners.interval = fn; return 1; }, getRpcCorrelationId: () => ++id,
    sendPacket: buffer => sent.push(new DataView(buffer)), logMessage() {},
    sendNotification: (title, options, click) => { if (!success) return false; delivered.push({ title, options, click }); return true; },
  });
  vm.runInContext(calendar, context); vm.runInContext(source, context);
  const api = window.NRCAppointmentNotify;
  return { api, context, sent, delivered, opened, listeners, timers, stored,
    advance: ms => { time += ms; }, fail: () => { success = false; }, succeed: () => { success = true; },
    reply: (rows, more = false, request = sent.at(-1)) => api.handlePage(page(request, rows, more)) };
}

test("queries own next 15 minutes without loading or opening Calendar; exact boundaries", () => {
  const h = harness(); h.api.init();
  const q = h.sent[0];
  assert.equal(q.getUint16(0), 58); assert.equal(q.getBigInt64(10), nanos(0));
  assert.equal(q.getBigInt64(18), nanos(15) + 1n);
  assert.equal(new TextDecoder().decode(new Uint8Array(q.buffer, 48, q.getUint16(46))), "rene");
  h.reply([row(1, -1, { endAt: nanos(20) }), row(2, 0), row(3, 15), row(4, 16),
    row(5, 5, { assignee: "alex" }), row(6, 6, { kind: 0 }), row(7, 7, { kind: 1 }), row(8, 8, { assignee: "" })]);
  assert.deepEqual(h.delivered.map(d => d.title), ["Meeting 3"]);
  assert.match(h.delivered[0].options.body, /IN 15 MIN/);
  h.delivered[0].click(); assert.equal(h.opened[0].type, "appointment"); assert.equal(h.opened[0].id, 3n);
});
test("pages completely, rejects unrelated replies, and deduplicates polls, reloads and reschedules", () => {
  const h = harness(); h.api.refresh();
  const wrong = new DataView(new ArrayBuffer(4)); h.api.handlePage(wrong);
  h.reply([row(1, 5)], true); assert.equal(h.delivered.length, 0);
  assert.equal(h.sent[1].getUint8(28), 1); assert.equal(h.sent[1].getBigUint64(38), 1n);
  h.reply([row(2, 10)]); assert.equal(h.delivered.length, 2);
  h.api.refresh(); h.reply([row(1, 5), row(2, 10)]); assert.equal(h.delivered.length, 2);
  const reload = harness(h.stored); reload.api.refresh(); reload.reply([row(1, 5), row(2, 11)]);
  assert.deepEqual(reload.delivered.map(d => d.title), ["Meeting 2"]);
});
test("permission, preference and offline state prevent reads; enabling does not consume missed alerts", async () => {
  const h = harness(); h.context.Notification.permission = "denied";
  h.api.refresh(); assert.equal(h.sent.length, 0);
  h.context.Notification.permission = "granted"; await h.api.setMode("off");
  h.api.refresh(); assert.equal(h.sent.length, 0);
  h.context.serverReady = false; await h.api.setMode("mine"); assert.equal(h.sent.length, 0);
  h.context.serverReady = true; h.api.refresh(); h.reply([row(1, 5)]); assert.equal(h.delivered.length, 1);
});
test("disconnect, workspace changes and mutations discard stale replies; no late catch-up", () => {
  const h = harness(); h.api.init(); const stale = h.sent.at(-1);
  h.listeners["nrc:asset-deleted"]({ detail: {} });
  h.reply([row(1, 5)], false, stale); assert.equal(h.delivered.length, 0);
  h.reply([]); h.api.restart(); h.context.currentWorkspaceId = "other";
  h.reply([row(1, 5)]); assert.equal(h.delivered.length, 0);
  h.api.restart(); h.advance(6 * 60000); h.reply([row(1, 5)]); assert.equal(h.delivered.length, 0);
  h.api.restart(); const beforeClose = h.sent.at(-1); h.api.disconnect();
  h.reply([row(2, 10)], false, beforeClose); assert.equal(h.delivered.length, 0);
});
test("failed delivery and timed-out reads retry, stalled pagination never delivers partial results", () => {
  const h = harness(); h.api.refresh(); [...h.timers.values()][0]();
  h.api.refresh(); assert.equal(h.sent.length, 2);
  h.reply([row(1, 5)], true); h.reply([row(1, 5)], true); assert.equal(h.delivered.length, 0);
  h.fail(); h.api.refresh(); h.reply([row(1, 5)]); assert.equal(h.delivered.length, 0);
  h.succeed(); h.api.refresh(); h.reply([row(1, 5)]); assert.equal(h.delivered.length, 1);
});
test("two tabs serialize shared ledger checks; a queued delivery is cancelled by a live change", async () => {
  const queue = [], stored = new Map();
  const locks = { request: async (key, fn) => { queue.push(fn); } };
  const a = harness(stored, locks), b = harness(stored, locks);
  a.api.refresh(); b.api.refresh(); a.reply([row(1, 5)]); b.reply([row(1, 5)]);
  queue.shift()(); queue.shift()(); assert.equal(a.delivered.length + b.delivered.length, 1);
  a.api.refresh(); a.reply([row(2, 6)]); a.api.restart(); queue.shift()(); assert.equal(a.delivered.length, 1);
});
