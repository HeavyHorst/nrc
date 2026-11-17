import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs";

const framesSource = fs.readFileSync(new URL("./protocol.js", import.meta.url), "utf8") + "\n" +
  fs.readFileSync(new URL("./frames.js", import.meta.url), "utf8");

function fixture() {
  const nodes = new Map();
  const document = { getElementById(id) {
    if (!nodes.has(id)) nodes.set(id, { textContent: "", innerHTML: "", setAttribute() {} });
    return nodes.get(id);
  }, addEventListener() {} };
  const requests = [], timers = new Map();
  let sequence = 0, view = "chat";
  const context = vm.createContext({ window: {}, document, DataView, Uint8Array, TextDecoder, TextEncoder,
    serverReady: true, ws: { readyState: 1 }, WebSocket: { OPEN: 1 }, Opcode: { C_ListHistory: 62, C_Chronicle: 68 },
    getRpcCorrelationId: () => ++sequence, sendPacket: buffer => requests.push(new DataView(buffer)),
    setTimeout: fn => { timers.set(sequence, fn); return sequence; }, clearTimeout: id => timers.delete(id) });
  vm.runInContext(framesSource + fs.readFileSync(new URL("chronicle.js", import.meta.url), "utf8") + fs.readFileSync(new URL("history.js", import.meta.url), "utf8"), context);
  const api = context.window.NRCHistory;
  context.window.NRCViewManager = { getActiveView: () => view, setActiveView: next => { view = next; api.onViewChanged(next); } };
  api.init();
  const row = id => ({ id: String(id), timestamp: "1792233000000000000", entityType: "asset", entityId: "9007199254740993", actorId: "subject:42", actorName: "<img>", action: "updated", fields: ["payload", "due_at", "<status>"], entityLabel: "Meeting <notes>", assetType: 5, entityAvailable: true });
  function reply(events, nextBefore = "0", request = requests.at(-1)) {
    const json = new TextEncoder().encode(JSON.stringify({ events, nextBefore }));
    const response = new DataView(new ArrayBuffer(6 + json.length));
    response.setUint16(0, 168); response.setUint32(2, request.getUint32(29)); new Uint8Array(response.buffer, 6).set(json);
    api.handlePage(response);
  }
  function replyChronicle(page, request = requests.at(-1)) {
    const json = new TextEncoder().encode(JSON.stringify(page));
    const response = new DataView(new ArrayBuffer(6 + json.length));
    response.setUint16(0, 174); response.setUint32(2, request.getUint32(request.byteLength - 4)); new Uint8Array(response.buffer, 6).set(json);
    context.window.NRCChronicle.handlePage(response);
  }
  return { api, nodes, requests, timers, context, row, reply, replyChronicle, status: () => nodes.get("historyStatus").textContent };
}

test("history request preserves exact u64 identities and canonical scope in the 33-byte BE wire contract", () => {
  const f = fixture(); f.api.open(2, "9007199254740993");
  const v = f.requests[0];
  assert.equal(v.byteLength, 33); assert.equal(v.getUint16(0), 62); assert.equal(v.getBigUint64(2), 0n);
  assert.equal(v.getUint8(10), 2); assert.equal(v.getBigUint64(11), 9007199254740993n);
  assert.equal(v.getBigUint64(19), 0n); assert.equal(v.getUint16(27), 50);
  f.reply([f.row(90)]);
  assert.match(f.nodes.get("historyBody").innerHTML, /Note #9007199254740993/);
  assert.match(f.nodes.get("historyBody").innerHTML, /Meeting &lt;notes&gt;/);
  assert.match(f.nodes.get("historyBody").innerHTML, /Changed Content, Due date/);
  assert.match(f.nodes.get("historyBody").innerHTML, /&lt;img&gt;/);
  assert.match(f.nodes.get("historyBody").innerHTML, /&lt;status&gt;/);
  assert.equal(f.timers.size, 0);
});

test("deleted records retain names without dead links, while legacy nameless events fall back to IDs", () => {
  const f = fixture(); f.api.open();
  f.reply([{ ...f.row(90), action: "deleted", entityAvailable: false }, { ...f.row(89), entityLabel: undefined, entityAvailable: false }]);
  const html = f.nodes.get("historyBody").innerHTML;
  assert.match(html, /Deleted<br><strong>Meeting &lt;notes&gt;<\/strong>/);
  assert.match(html, /<strong>Note #9007199254740993<\/strong>/);
  assert.doesNotMatch(html, /data-history-record=/);
});

test("history pagination is exclusive, rejects repeated/out-of-order pages, and refresh restarts", () => {
  const f = fixture(); f.api.open(); f.reply([f.row(90)], "90");
  f.nodes.get("historyMore").onclick(); assert.equal(f.requests.at(-1).getBigUint64(19), 90n);
  f.reply([f.row(90)]); assert.match(f.status(), /FAILED/);
  f.api.refresh(); assert.equal(f.requests.at(-1).getBigUint64(19), 0n);
  f.reply([]); assert.match(f.nodes.get("historyBody").innerHTML, /NO HISTORY/);
});

test("history groups local calendar days and merges the day spanning a page boundary", () => {
  const f = fixture(); f.api.open();
  const at = (id, day, hour) => ({ ...f.row(id), timestamp: String(BigInt(new Date(2026, 9, day, hour).getTime()) * 1000000n) });
  f.reply([at(90, 18, 1), at(89, 17, 23)], "89");
  f.nodes.get("historyMore").onclick();
  f.reply([at(88, 17, 22), at(87, 16, 23)]);
  const html = f.nodes.get("historyBody").innerHTML;
  assert.equal((html.match(/<h2>/g) || []).length, 3);
  assert.equal((html.match(/<time /g) || []).length, 4);
  const groups = html.split('<section class="history-day">').slice(1);
  assert.deepEqual(groups.map(group => (group.match(/<time /g) || []).length), [1, 2, 1]);
});

test("scope changes, leaving the view and disconnect discard late replies and timers", () => {
  const f = fixture(); f.api.open(1, "42"); const old = f.requests[0]; f.api.open(2, "71");
  f.reply([f.row(90)], "0", old); assert.match(f.status(), /LOADING/);
  f.api.onViewChanged("chat"); f.reply([f.row(90)]); assert.equal(f.timers.size, 0);
  f.context.serverReady = false; f.api.disconnect(); f.reply([f.row(90)]);
  assert.match(f.status(), /OFFLINE/); assert.equal(f.nodes.get("historyBody").innerHTML, "");
});

test("history timeout exposes retry and load more has a hard 1,000-event bound", () => {
  const f = fixture(); f.api.open(); [...f.timers.values()][0](); assert.match(f.status(), /FAILED/);
  f.api.refresh();
  for (let page = 0; page < 20; page++) {
    const first = 2000 - page * 50;
    f.reply(Array.from({ length: 50 }, (_, i) => f.row(first - i)), String(first - 49));
    if (page < 19) f.nodes.get("historyMore").onclick();
  }
  assert.match(f.status(), /1000 EVENTS/); assert.equal(f.nodes.get("historyMore").disabled, true);
  const count = f.requests.length; f.nodes.get("historyMore").onclick(); assert.equal(f.requests.length, count);
});

const chronicleStatus = { status: "ok", enabled: true, can_delete: false, pending: 3, processing: 1, failed: 1, expired: 0, acknowledged: 4, gap_count: 2, calls: 5, input_tokens: 600, output_tokens: 1000 };
const chronicleEntry = { generation: "9007199254740993", note_id: "18446744073709551615", note_title: '<img src=x onerror=alert(2)>', first_at: "1792233000000000000", last_at: "1792233060000000000", created_at: "1792233120000000000", sources: ["9007199254740997", "9007199254740999"], summary: "<img src=x onerror=alert(1)>\nNicht freigegeben.", model: "gpt-6.1-terra", prompt_version: "chronicle-p5", schema_version: "chronicle-s1", source_available: false };
const settle = () => new Promise(resolve => setImmediate(resolve));

test("AI mode separates successful Ack, partial coverage and exact high-ID result provenance without HTML", async () => {
  const f = fixture(); f.api.open(2, chronicleEntry.note_id); f.nodes.get("historyChronicle").onclick();
  const query = request => JSON.parse(new TextDecoder().decode(new Uint8Array(request.buffer, 2, request.byteLength - 6)));
  assert.deepEqual(query(f.requests.at(-1)), { op: "status", note_id: chronicleEntry.note_id });
  f.replyChronicle(chronicleStatus); await settle();
  const reads = f.requests.slice(-2);
  f.replyChronicle({ status: "ok", entries: [chronicleEntry], cursor: chronicleEntry.generation, more: true }, reads[0]);
  f.replyChronicle({ status: "ok", gaps: [{ first_source: "9007199254741001", last_source: "9007199254741002", note_id: chronicleEntry.note_id, first_at: chronicleEntry.first_at, last_at: chronicleEntry.last_at, input_count: 2, reason: "ttl", source_available: false }], cursor: "9007199254741001", more: false }, reads[1]);
  await settle();
  const html = f.nodes.get("historyBody").innerHTML;
  assert.match(html, /4 NO-CHANGE ACKS/);
  assert.match(html, /2 LOST INPUTS/);
  assert.match(html, /9007199254740997, 9007199254740999/);
  assert.match(html, /SOURCE NO LONGER AVAILABLE/);
  assert.match(html, /&lt;img src=x onerror=alert\(2\)&gt;/);
  assert.match(html, /NOTE #18446744073709551615/);
  assert.match(html, /&lt;img src=x/); assert.doesNotMatch(html, /<img|data-chronicle-delete=/);
  assert.match(html, /chronicle-p5/); assert.match(html, /CREATED/); assert.match(html, /CHANGES/);
  f.nodes.get("historyMore").onclick(); f.replyChronicle(chronicleStatus); await settle();
  assert.deepEqual(query(f.requests.at(-1)), { op: "history", note_id: chronicleEntry.note_id, limit: 16, cursor: chronicleEntry.generation });
  // A duplicate generation is not silently appended, even if its sources look valid.
  f.replyChronicle({ status: "ok", entries: [chronicleEntry], cursor: chronicleEntry.generation, more: false }); await settle();
  assert.match(f.status(), /FAILED/); assert.doesNotMatch(f.nodes.get("historyBody").innerHTML, /Nicht freigegeben/);
});

test("AI requests cannot repopulate the next workspace or technical mode after cancellation", async () => {
  const f = fixture(); f.api.open(); f.nodes.get("historyChronicle").onclick();
  const old = f.requests.at(-1); f.api.disconnect();
  f.replyChronicle({ ...chronicleStatus, can_delete: true }, old); await settle();
  assert.match(f.status(), /OFFLINE/); assert.doesNotMatch(f.nodes.get("historyBody").innerHTML, /PENDING|DELETE/);
  f.nodes.get("historyTechnical").onclick(); f.reply([f.row(42)]);
  assert.match(f.status(), /1 EVENTS/); assert.doesNotMatch(f.nodes.get("historyBody").innerHTML, /AI CHRONICLE/);
  f.api.open(1, "42"); f.nodes.get("historyChronicle").onclick(); await settle();
  assert.match(f.nodes.get("historyBody").innerHTML, /COVERS NOTES ONLY/);
});
