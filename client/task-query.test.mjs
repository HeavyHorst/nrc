import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./task-query.js", import.meta.url), "utf8");
const readString = (view, offset) => {
  const size = view.getUint16(offset, false);
  return { value: new TextDecoder().decode(new Uint8Array(view.buffer, view.byteOffset + offset + 2, size)), newOffset: offset + 2 + size };
};
function harness(t, onAssignees) {
  const window = {};
  vm.runInNewContext(source, { window, TextEncoder, TextDecoder, ArrayBuffer, DataView, Uint8Array, setTimeout, clearTimeout });
  const filters = { status: null, assignee: null, color: null, project: null, blocked: null, overdue: null, search: "" };
  const sort = { column: "priority", direction: "desc" };
  const sent = [], cached = [];
  let room = 7n, ready = true, id = 0;
  const controller = window.createTaskQueryController({
    getRoomId: () => room, getFilters: () => filters, getSort: () => sort, getNickname: () => "René",
    isReady: () => ready, nextId: () => ++id, send: (buffer) => sent.push(new DataView(buffer)),
    readString, parseTask: (view, offset) => ({ task: { id: view.getBigUint64(offset, false) }, newOffset: offset + 8 }),
    cacheTasks: (roomId, tasks) => cached.push({ roomId, tasks }),
    onAssignees,
  });
  t.after(() => controller.disconnect());
  return { controller, filters, sort, sent, cached, encode: window.encodeTaskQuery,
    setRoom: (value) => { room = value; }, setReady: (value) => { ready = value; } };
}
const correlation = (view) => view.getUint32(view.byteLength - 4, false);
test("assignee metadata is unfiltered, chunked, invalidated by mutations and cleared on disconnect", (t) => {
  let changed = 0;
  const h = harness(t, () => changed++);
  h.filters.assignee = "René";
  h.filters.project = "one project";
  h.controller.update();
  const request = h.sent.find(view => view.getUint16(0) === 57);
  assert.equal(request.byteLength, 14);
  assert.equal(request.getBigUint64(2), 0n);
  const chunk = (id, label, more = false) => {
    const bytes = new TextEncoder().encode(label);
    const view = new DataView(new ArrayBuffer(19 + bytes.length));
    view.setUint16(0, 165); view.setBigUint64(2, 0n); view.setUint16(10, 1);
    view.setUint16(12, bytes.length); new Uint8Array(view.buffer, 14, bytes.length).set(bytes);
    view.setUint8(14 + bytes.length, more ? 1 : 0); view.setUint32(15 + bytes.length, id);
    return view;
  };
  h.controller.handleAssignees(chunk(correlation(request), "alex", true));
  assert.deepEqual(Array.from(h.controller.getAssignees()), []);
  h.controller.handleAssignees(chunk(correlation(request), "zoë"));
  assert.deepEqual(Array.from(h.controller.getAssignees()), ["alex", "zoë"]);
  assert.equal(changed, 1);
  h.controller.afterMutation(0n);
  h.controller.update();
  h.controller.handleAssignees(chunk(correlation(request), "stale"));
  assert.deepEqual(Array.from(h.controller.getAssignees()), []);
  const latest = h.sent.findLast(view => view.getUint16(0) === 57);
  h.controller.handleAssignees(chunk(correlation(latest), "new assignee"));
  assert.deepEqual(Array.from(h.controller.getAssignees()), ["new assignee"]);
  h.controller.disconnect();
  assert.deepEqual(Array.from(h.controller.getAssignees()), []);
});
function page(request, ids, { total = ids.length, more = false, text = "", number = 0n, success = true } = {}) {
  const bytes = new TextEncoder().encode(text);
  const view = new DataView(new ArrayBuffer(42 + ids.length * 8 + bytes.length));
  view.setUint16(0, 138); view.setBigUint64(2, request.getBigUint64(2)); view.setUint8(10, success ? 1 : 0); view.setUint16(11, ids.length);
  let offset = 13;
  for (const id of ids) { view.setBigUint64(offset, id); offset += 8; }
  view.setUint8(offset++, more ? 1 : 0); view.setBigInt64(offset, number); offset += 8;
  view.setBigUint64(offset, ids.at(-1) ?? 0n); offset += 8;
  view.setUint16(offset, bytes.length); offset += 2;
  new Uint8Array(view.buffer, offset, bytes.length).set(bytes); offset += bytes.length;
  view.setUint32(offset, total); offset += 4; view.setUint16(offset, 0); offset += 2;
  view.setUint32(offset, correlation(request));
  return view;
}

test("query encodes exact filters, nanoseconds and UTF-8 cursor without truncating IDs", (t) => {
  const h = harness(t);
  const view = new DataView(h.encode({ roomId: "9007199254740999", statusMask: 8, sort: "title", descending: false,
    assignee: "René", project: "ß", color: 4, blocked: false, overdueBefore: 123456789012345678n },
  { number: 0n, text: "東京", taskId: 9007199254740997n }, 73));
  assert.equal(view.getUint16(0), 28);
  assert.equal(view.getBigUint64(2), 0n);
  assert.deepEqual(Array.from(new Uint8Array(view.buffer, 10, 7)), [8, 0, 100, 5, 0, 4, 2]);
  assert.equal(view.getBigInt64(17), 123456789012345678n);
  assert.equal(view.getUint8(25), 1);
  let field = readString(view, 26); assert.equal(field.value, "René");
  assert.equal(view.getUint8(field.newOffset), 1);
  field = readString(view, field.newOffset + 1); assert.equal(field.value, "ß");
  assert.equal(view.getUint8(field.newOffset), 1);
  field = readString(view, field.newOffset + 9); assert.equal(field.value, "東京");
  assert.equal(view.getBigUint64(field.newOffset), 9007199254740997n);
  assert.equal(field.newOffset + 12, view.byteLength);
  assert.equal(correlation(view), 73);
});

test("pages retain server order and frozen filters; changed queries reject stale replies", (t) => {
  const h = harness(t);
  h.filters.status = 3; h.filters.assignee = "me"; h.filters.overdue = true;
  h.controller.update();
  const first = h.sent.at(-1);
  h.controller.handlePage(page(first, [99n, 3n], { total: 3, more: true, text: "", number: 8n }));
  const cutoff = first.getBigInt64(17);
  h.controller.loadMore();
  const second = h.sent.at(-1);
  assert.equal(second.getBigInt64(17), cutoff);
  h.controller.handlePage(page(second, [7n], { total: 3 }));
  assert.deepEqual(Array.from(h.controller.getState().tasks.keys()), [99n, 3n, 7n]);
  const count = h.sent.length;
  h.controller.loadMore(); assert.equal(h.sent.length, count);
  h.filters.project = "Unloaded";
  h.controller.update(); const stale = h.sent.at(-1);
  h.sort.column = "title"; h.sort.direction = "asc";
  h.controller.update(); const current = h.sent.at(-1);
  h.controller.handlePage(page(stale, [111n]));
  assert.equal(h.controller.getState().tasks.size, 0);
  assert.equal(h.cached.length, 2);
  h.controller.handlePage(page(current, [444n]));
  assert.deepEqual(Array.from(h.controller.getState().tasks.keys()), [444n]);
});

test("chat switches retain pending membership; search and disconnect discard it; failed pages retry", (t) => {
  const h = harness(t);
  h.controller.update(); const oldRoom = h.sent.at(-1);
  assert.equal(oldRoom.getUint8(10), 15, "All requests every task status");
  h.setRoom(9n); h.controller.update(); const request = h.sent.at(-1);
  assert.equal(request, oldRoom, "chat switch must not issue a data query");
  h.controller.handlePage(page(request, [], { success: false }));
  assert.equal(h.controller.getState().mode, "error");
  h.controller.loadMore(); const retry = h.sent.at(-1);
  h.controller.handlePage(page(retry, [2n])); assert.equal(h.controller.getState().roomId, 0n);
  h.filters.search = "text"; h.controller.update(); assert.equal(h.controller.getState().mode, "idle");
  h.filters.search = ""; h.controller.update(); const beforeDisconnect = h.sent.at(-1);
  h.controller.disconnect(); h.controller.handlePage(page(beforeDisconnect, [3n]));
  assert.equal(h.controller.getState().tasks.size, 0);
  h.controller.update(); assert.notEqual(correlation(h.sent.at(-1)), correlation(beforeDisconnect));
});

test("Open requests only backlog, todo, and in-progress tasks", (t) => {
  const h = harness(t);
  h.filters.status = "open";
  h.controller.update();
  assert.equal(h.sent.at(-1).getUint8(10), 7);
});

test("live mutations coalesce into a fresh query and facets reject stale correlations", async (t) => {
  const h = harness(t);
  h.controller.update(); const oldProjects = h.sent[0];
  h.setRoom(8n); h.controller.update({ force: true }); const currentProjects = h.sent.at(-2);
  function projects(request, more = false) {
    const view = new DataView(new ArrayBuffer(20));
    view.setUint16(0, 139); view.setBigUint64(2, request.getBigUint64(2)); view.setUint16(10, 1);
    view.setUint16(12, 1); view.setUint8(14, 90); view.setUint8(15, more ? 1 : 0); view.setUint32(16, correlation(request)); return view;
  }
  h.controller.handleProjects(projects(oldProjects)); assert.equal(h.controller.getProjects(0n), undefined);
  h.controller.handleProjects(projects(currentProjects, true)); assert.equal(h.controller.getProjects(0n), undefined);
  h.controller.handleProjects(projects(currentProjects)); assert.deepEqual(Array.from(h.controller.getProjects(0n)), ["Z", "Z"]);
  const before = h.sent.length;
  h.controller.afterMutation(0n); h.controller.afterMutation(0n);
  h.controller.update(); // Reopening the same view must not cancel its scheduled refresh.
  await new Promise((resolve) => setTimeout(resolve, 130));
  assert.equal(h.sent.length, before + 2);
});

test("text search loads workspace facets on reconnect, not chat switches or each keystroke", (t) => {
  const h = harness(t);
  h.filters.search = "text"; h.controller.update();
  assert.equal(h.sent.length, 1); assert.equal(h.sent[0].getUint16(0), 29);
  h.filters.search = "text changed"; h.controller.update(); assert.equal(h.sent.length, 1);
  h.setRoom(8n); h.controller.update(); assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].getBigUint64(2), 0n);
  h.controller.disconnect(); h.controller.update({ force: true });
  assert.equal(h.sent.length, 2); assert.equal(h.sent[1].getUint16(0), 29);
});

test("cursor and project facets preserve leading U+FEFF byte-for-byte", (t) => {
  const h = harness(t);
  h.sort.column = "title"; h.controller.update();
  const request = h.sent.at(-1);
  h.controller.handlePage(page(request, [11n], { more: true, total: 201, text: "\uFEFFx" }));
  assert.equal(h.controller.getState().cursor.text, "\uFEFFx");
  h.controller.loadMore();
  const next = new Uint8Array(h.sent.at(-1).buffer);
  // Empty assignee/project: u16 cursor length at byte 40, text at byte 42.
  assert.deepEqual(Array.from(next.slice(42, 46)), [239, 187, 191, 120]);
  const facet = new DataView(new ArrayBuffer(23));
  facet.setUint16(0, 139); facet.setBigUint64(2, 0n); facet.setUint16(10, 1); facet.setUint16(12, 4);
  new Uint8Array(facet.buffer, 14, 4).set([239, 187, 191, 120]);
  facet.setUint32(19, correlation(h.sent[0]));
  h.controller.handleProjects(facet);
  assert.deepEqual(Array.from(h.controller.getProjects(0n)), ["\uFEFFx"]);
});

test("typing or changing sort cannot cancel mutation-driven facet invalidation", async (t) => {
  for (const search of [true, false]) {
    const h = harness(t);
    h.controller.update();
    const facet = new DataView(new ArrayBuffer(17));
    facet.setUint16(0, 139); facet.setBigUint64(2, 0n); facet.setUint32(13, correlation(h.sent[0]));
    h.controller.handleProjects(facet);
    const before = h.sent.length;
    h.controller.afterMutation(0n);
    if (search) h.filters.search = "new search";
    else h.sort.column = "title";
    h.controller.update();
    assert.equal(h.sent[before].getUint16(0), 29);
    assert.notEqual(correlation(h.sent[before]), correlation(h.sent[0]));
    await new Promise((resolve) => setTimeout(resolve, 130));
    assert.equal(h.sent.length, before + (search ? 1 : 2));
  }
});
