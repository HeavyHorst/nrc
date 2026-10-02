import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const enc = new TextEncoder();
const quiet = { log() {}, warn() {}, error() {} };

function customEvent() {
  return class CustomEvent { constructor(type, init = {}) { this.type = type; this.detail = init.detail; } };
}

function load(file) {
  const packets = [];
  let correlation = 100;
  const window = { zstdCodec: null };
  window.NRCAssets = { generateCorrelationId: () => ++correlation };
  const context = vm.createContext({
    window, console: quiet, TextEncoder, TextDecoder, Uint8Array, ArrayBuffer, DataView, BigInt,
    WebSocket: { OPEN: 1 }, ws: { readyState: 1 }, serverReady: true, currentRoomId: 1n,
    sendPacket: packet => packets.push(packet), updateAgendaDisplay() {}, logMessage() {},
    CustomEvent: customEvent(), document: { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} },
    Opcode: {
      C_CreateAsset: 30, C_UpdateAsset: 31, C_DeleteAsset: 32, C_GetAsset: 33,
      C_ListAssets: 34, C_ListAssetsPaged: 35, C_CreateEdge: 40, C_DeleteEdge: 41,
      C_ListEdges: 42, C_ListAllEdges: 43, C_GraphQuery: 44, C_GraphShortestPath: 45,
      C_GraphDegree: 46, C_GraphCommonNeighbors: 47, C_ListAllEdgesPaged: 53,
      C_ListEdgesPaged: 54, C_SearchCustomers: 55,
    },
  });
  vm.runInContext(fs.readFileSync(new URL(file, import.meta.url), "utf8"), context, { filename: file });
  return { api: file === "assets.js" ? window.NRCAssets : window.NRCEdges, packets, context };
}

test("newer asset headers invalidate old payloads instead of blessing them with a new version", () => {
  const { context } = load("assets.js");
  vm.runInContext(`
    storeAsset({ convId: 1n, assetId: 9n, updatedAt: 10n, payload: "old" });
    storeAsset({ convId: 1n, assetId: 9n, updatedAt: 11n, payload: null });
  `, context);
  assert.equal(vm.runInContext("roomAssets.get(1n).get(9n).payload", context), null);
  vm.runInContext(`
    storeAsset({ convId: 1n, assetId: 9n, updatedAt: 11n, payload: "" });
    storeAsset({ convId: 1n, assetId: 9n, updatedAt: 11n, payload: null });
  `, context);
  assert.equal(vm.runInContext("roomAssets.get(1n).get(9n).payload", context), "");
});

function writer() {
  const parts = [];
  return {
    u8: n => parts.push(Uint8Array.of(n)),
    u16(n) { const b = new Uint8Array(2); new DataView(b.buffer).setUint16(0, n); parts.push(b); },
    u32(n) { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n); parts.push(b); },
    u64(n) { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n)); parts.push(b); },
    i64(n) { const b = new Uint8Array(8); new DataView(b.buffer).setBigInt64(0, BigInt(n)); parts.push(b); },
    text(s) { const b = enc.encode(s); this.u16(b.length); parts.push(b); },
    bytes(b) { parts.push(b); },
    done() { const n = parts.reduce((v, p) => v + p.length, 0); const out = new Uint8Array(n); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return new DataView(out.buffer); },
  };
}

function assetBytes({ type = 8, id, room = 0n, preview = `asset-${id}`, updated = id }, includeAttachments = true) {
  const w = writer(); w.u16(type); w.u64(id); w.u16(0); w.u64(0); w.text("owner");
  w.i64(1); w.i64(updated); w.u64(room); w.u8(0); w.u32(0); w.text(preview);
  if (includeAttachments) w.u16(0);
  return new Uint8Array(w.done().buffer);
}

function assetPage(correlation, assets, { room = 0n, more = false, cursorTime = 0n, cursorId = 0n } = {}) {
  const w = writer(); w.u16(130); w.u64(room); w.u8(0); w.u8(more ? 1 : 0); w.i64(cursorTime);
  w.u64(cursorId); w.u32(assets.length); w.u16(assets.length); w.u32(correlation);
  for (const a of assets) w.bytes(assetBytes({ room, ...a })); return w.done();
}

function fullAsset(opcode, correlation, asset, deleted = false) {
  const w = writer(); w.u16(opcode);
  if (deleted) { w.u64(asset.room ?? 0n); w.u64(asset.id); w.u32(correlation); return w.done(); }
  const preview = asset.preview ?? `asset-${asset.id}`;
  w.bytes(assetBytes(asset, false)); w.u16(enc.encode(preview).length); w.bytes(enc.encode(preview)); w.u16(0); w.u32(correlation);
  return w.done();
}

function edgeBytes({ id, room = 0n, sourceType = 1, sourceId, targetType = 1, targetId }) {
  const w = writer(); w.u64(id); w.u64(room); w.u16(sourceType); w.u64(sourceId); w.u16(targetType);
  w.u64(targetId); w.u16(1); w.i64(1); w.text("owner"); return new Uint8Array(w.done().buffer);
}

function edgePage(correlation, edges, { room = 0n, more = false, next = 0n } = {}) {
  const w = writer(); w.u16(153); w.u64(room); w.u8(more ? 1 : 0); w.u64(next); w.u32(edges.length);
  w.u16(edges.length); w.u32(correlation); for (const e of edges) w.bytes(edgeBytes({ room, ...e })); return w.done();
}

function edgeEvent(opcode, correlation, edge, deleted = false) {
  const w = writer(); w.u16(opcode);
  if (deleted) { w.u64(edge.room ?? 0n); w.u64(edge.id); w.u32(correlation); }
  else { w.bytes(edgeBytes(edge)); w.u32(correlation); }
  return w.done();
}

function scopedEdges(correlation, endpoint, edges, room = 0n) {
  const w = writer(); w.u16(142); w.u64(room); w.u16(endpoint.type); w.u64(endpoint.id); w.u16(edges.length);
  for (const e of edges) w.bytes(edgeBytes({ room, ...e })); w.u32(correlation); return w.done();
}

function assetCorrelation(packet) { const v = new DataView(packet); return v.getUint8(15) ? v.getUint32(32) : v.getUint32(16); }
function edgeCorrelation(packet) { return new DataView(packet).getUint32(20); }

function incidentPage(correlation, edges, { more = false, next = 0n } = {}) {
  const w = writer(); w.u16(162); w.u64(0); w.u16(1); w.u64(10); w.u8(more ? 1 : 0);
  w.u64(next); w.u32(3); w.u16(edges.length); w.u32(correlation);
  for (const e of edges) w.bytes(edgeBytes(e)); return w.done();
}

test("incident pages prune only covered endpoint IDs and preserve live changes", async () => {
  const f = load("edges.js");
  const stale = { id: 1n, sourceId: 10n, targetId: 20n };
  const future = { id: 9n, sourceId: 30n, targetId: 10n };
  const unrelated = { id: 2n, sourceId: 40n, targetId: 50n };
  for (const e of [stale, future, unrelated]) f.api.handleEdgeCreated(edgeEvent(150, 0, e));
  let promise = f.api.requestEdgePage(7n, 1, 10n);
  const packet = new DataView(f.packets.at(-1));
  assert.equal(packet.byteLength, 34); assert.equal(packet.getUint16(0), 54);
  assert.equal(packet.getBigUint64(12), 10n); assert.equal(packet.getBigUint64(22), 0n);
  f.api.handleEdgeListPage(incidentPage(packet.getUint32(30), [{ id: 4n, sourceId: 10n, targetId: 60n }], { more: true, next: 4n }));
  const first = await promise;
  assert.equal(f.api.getEdgesForRoom(0n).map(e => e.edgeId).sort().join(","), "2,4,9");
  assert.equal(f.packets.length, 1, "a short page does not automatically drain");
  promise = f.api.requestEdgePage(7n, 1, 10n, { session: first.session });
  f.api.handleEdgeDeleted(edgeEvent(151, 0, future, true));
  f.api.handleEdgeCreated(edgeEvent(150, 0, { id: 11n, sourceId: 10n, targetId: 80n }));
  f.api.handleEdgeListPage(incidentPage(new DataView(f.packets.at(-1)).getUint32(30), [future]));
  await promise;
  assert.equal(f.api.getEdgesForRoom(0n).map(e => e.edgeId).sort().join(","), "11,2,4");
});

test("uncached edge deletion still invalidates listeners and paged reads reject correlated errors", async () => {
  const f = load("edges.js");
  const events = [];
  f.api.addEdgeChangeListener((detail, kind, correlationId) => events.push([detail.convId, detail.edgeId, kind, correlationId]));
  f.api.handleEdgeDeleted(edgeEvent(151, 0, { id: 123n }, true));
  assert.deepEqual(events, [[0n, 123n, "deleted", 0]], "listeners can distinguish broadcasts from local acknowledgements");
  const p = f.api.requestEdgePage(7n, 1, 10n);
  f.api.handleEdgeErrorResponse(54, new DataView(f.packets.at(-1)).getUint32(30), "denied");
  await assert.rejects(p, /denied/);
  const assets = load("assets.js");
  const search = assets.api.requestCustomerPage(7n);
  assets.api.handleAssetErrorResponse(55, new DataView(assets.packets.at(-1)).getUint32(23), "denied");
  await assert.rejects(search, /denied/);
});

test("customer search wire uses UTF-8 bytes and stale results do not populate caches", async () => {
  const f = load("assets.js");
  let cancelled = false;
  const promise = f.api.requestCustomerPage(7n, { query: "Müller", afterId: 99n, includeArchived: true, isCancelled: () => cancelled });
  const packet = new DataView(f.packets.at(-1));
  assert.equal(packet.byteLength, 34); assert.equal(packet.getUint16(0), 55);
  assert.equal(packet.getBigUint64(12), 99n); assert.equal(packet.getUint8(20), 1);
  assert.equal(packet.getUint16(21), 7);
  const w = writer(); w.u16(163); w.u64(0); w.u8(0); w.u64(101); w.u32(1); w.u16(1); w.u32(packet.getUint32(30));
  w.bytes(assetBytes({ id: 101n }));
  cancelled = true;
  f.api.handleCustomerSearchPage(w.done());
  await assert.rejects(promise, /cancelled/);
  assert.equal(f.api.roomAssets.get(0n)?.size ?? 0, 0);
  await assert.rejects(f.api.requestCustomerPage(7n, { query: "ü".repeat(129) }), /256/);
  const disconnected = f.api.requestCustomerPage(7n);
  f.api.clearPendingAssetRpc();
  await assert.rejects(disconnected, /Connection closed/);
});

test("asset paging follows hasMore on short pages and accumulates customer 8/9/10 caches", async () => {
  const f = load("assets.js");
  for (const type of [8, 9, 10]) {
    const promise = f.api.requestAllAssets(7n, type, { limit: 50 });
    assert.equal(new DataView(f.packets.at(-1)).getUint16(10), type);
    f.api.handleAssetListPage(assetPage(assetCorrelation(f.packets.at(-1)), [{ type, id: BigInt(type * 10) }], { more: true, cursorTime: 2n, cursorId: BigInt(type * 10) }));
    assert.equal(f.packets.length, (type - 7) * 2, "short page with hasMore must send another request");
    f.api.handleAssetListPage(assetPage(assetCorrelation(f.packets.at(-1)), [{ type, id: BigInt(type * 10 + 1) }]));
    assert.equal((await promise).assets.map(a => a.assetId).join(","), `${type * 10},${type * 10 + 1}`);
  }
  assert.equal(f.api.roomAssets.get(0n).size, 6);
});

test("asset snapshot does not lose create/delete/update mutations received while loading", async () => {
  const f = load("assets.js");
  f.api.handleAssetListPage(assetPage(0, [{ id: 1n }, { id: 2n }]));
  const promise = f.api.requestAllAssets(7n, 8);
  const cid = assetCorrelation(f.packets.at(-1));
  f.api.handleAssetCreated(fullAsset(130, 0, { type: 8, id: 3n, preview: "live-create" }));
  f.api.handleAssetUpdated(fullAsset(131, 0, { type: 8, id: 1n, preview: "live-update" }));
  f.api.handleAssetDeleted(fullAsset(132, 0, { id: 2n }, true));
  f.api.handleAssetListPage(assetPage(cid, [{ id: 1n, preview: "stale" }, { id: 2n, preview: "stale" }]));
  const result = await promise;
  assert.equal(f.api.roomAssets.get(0n).get(1n).preview, "live-update");
  assert.equal(f.api.roomAssets.get(0n).has(2n), false);
  assert.equal(f.api.roomAssets.get(0n).get(3n).preview, "live-create");
  assert.equal(result.assets.map(a => a.assetId).sort().join(","), "1,3");
});

test("cancelled and failed generic note prefetches preserve the preloaded Notes cache", async () => {
  for (const outcome of ["cancelled", "failed"]) {
    const f = load("assets.js");
    const noteChanges = [];
    f.api.setOnNoteChanged((asset, action) => noteChanges.push([asset.convId, action]));
    f.api.handleAssetListPage(assetPage(0, [{ type: 5, id: 1n, preview: "preloaded" }]));

    let cancelled = false;
    const promise = f.api.requestAllAssets(7n, 5, { reset: true, isCancelled: () => cancelled });
    f.api.handleAssetListPage(assetPage(assetCorrelation(f.packets.at(-1)), [{ type: 5, id: 2n }], {
      more: true, cursorTime: 2n, cursorId: 2n,
    }));
    assert.equal(f.api.roomAssets.get(0n).has(1n), true, "the initial generic page must not clear Notes");

    const nextCid = assetCorrelation(f.packets.at(-1));
    if (outcome === "cancelled") {
      cancelled = true;
      f.api.handleAssetListPage(assetPage(nextCid, []));
      await assert.rejects(promise, /cancelled/);
    } else {
      f.api.handleAssetErrorResponse(35, nextCid, "prefetch failed");
      await assert.rejects(promise, /prefetch failed/);
    }

    assert.equal(f.api.roomAssets.get(0n).has(1n), true, `${outcome} prefetch must retain preloaded Notes`);
    assert.deepEqual(noteChanges.map(([, action]) => action),
      outcome === "cancelled" ? ["cache", "cache"] : ["cache"],
      "each received page invalidates the Notes cache view");
  }
});

test("generic note prefetch invalidates the Notes view without emitting paging events", async () => {
  const f = load("assets.js");
  const changes = [];
  f.api.setOnNoteChanged((asset, action) => changes.push({ convId: asset.convId, action }));
  const promise = f.api.requestAllAssets(7n, 5, { reset: true });
  f.api.handleAssetListPage(assetPage(assetCorrelation(f.packets.at(-1)), [{ type: 5, id: 1n }], {
    more: true, cursorTime: 1n, cursorId: 1n,
  }));
  f.api.handleAssetListPage(assetPage(assetCorrelation(f.packets.at(-1)), [{ type: 5, id: 2n }]));
  await promise;

  assert.deepEqual(changes.map(({ action }) => action), ["cache", "cache", "cache"]);
  assert.equal(changes.every(({ convId }) => convId === 0n), true);
  assert.equal(changes.some(({ action }) => action === "list_page"), false,
    "generic prefetch must leave Notes pagination state untouched");
});

test("full and scoped edge snapshots remove stale edges from map and both endpoint indexes", async () => {
  const f = load("edges.js");
  const old = { id: 1n, sourceId: 10n, targetId: 20n };
  f.api.handleEdgeCreated(edgeEvent(140, 0, old));
  const all = f.api.requestAllEdges(7n); f.api.handleAllEdgeListPage(edgePage(edgeCorrelation(f.packets.at(-1)), [])); await all;
  assert.equal(f.api.roomEdges.get(0n).has(1n), false);
  assert.equal(f.api.getEdgesForEntity(0n, 1, 10n).length, 0);
  assert.equal(f.api.getEdgesForEntity(0n, 1, 20n).length, 0);
  f.api.handleEdgeCreated(edgeEvent(140, 0, old));
  f.api.sendListEdges(7n, 1, 10n); const request = new DataView(f.packets.at(-1));
  f.api.handleEdgeList(scopedEdges(request.getUint32(20), { type: 1, id: 10n }, []));
  assert.equal(f.api.roomEdges.get(0n).has(1n), false);
  assert.equal(f.api.getEdgesForEntity(0n, 1, 10n).length, 0);
  assert.equal(f.api.getEdgesForEntity(0n, 1, 20n).length, 0);
});

test("scoped edge snapshot cannot remove a live create or resurrect a live delete", () => {
  const f = load("edges.js");
  const endpoint = { type: 1, id: 10n };
  const deleted = { id: 1n, sourceId: 10n, targetId: 20n };
  f.api.handleEdgeCreated(edgeEvent(140, 0, deleted));
  f.api.sendListEdges(7n, endpoint.type, endpoint.id);
  const cid = new DataView(f.packets.at(-1)).getUint32(20);
  f.api.handleEdgeDeleted(edgeEvent(141, 0, deleted, true));
  const created = { id: 2n, sourceId: 10n, targetId: 30n };
  f.api.handleEdgeCreated(edgeEvent(140, 0, created));
  f.api.handleEdgeList(scopedEdges(cid, endpoint, [deleted]));
  assert.equal(f.api.roomEdges.get(0n).has(1n), false);
  assert.equal(f.api.roomEdges.get(0n).has(2n), true);
  assert.equal(f.api.getEdgesForEntity(0n, 1, 30n)[0].edgeId, 2n);
});

test("edge pagination honors hasMore and live create/delete are not lost or resurrected", async () => {
  const f = load("edges.js");
  const stale = { id: 1n, sourceId: 10n, targetId: 20n };
  f.api.handleEdgeCreated(edgeEvent(140, 0, stale));
  const promise = f.api.requestAllEdges(7n, { limit: 100 });
  f.api.handleAllEdgeListPage(edgePage(edgeCorrelation(f.packets.at(-1)), [stale], { more: true, next: 1n }));
  assert.equal(f.packets.length, 2);
  f.api.handleEdgeDeleted(edgeEvent(141, 0, stale, true));
  const live = { id: 3n, sourceId: 30n, targetId: 40n };
  f.api.handleEdgeCreated(edgeEvent(140, 0, live));
  f.api.handleAllEdgeListPage(edgePage(edgeCorrelation(f.packets.at(-1)), [stale]));
  const ids = (await promise).edges.map(e => e.edgeId).sort();
  assert.equal(ids.join(","), "3");
});

test("paging failures, cancellation, and disconnect reject rather than resolve", async () => {
  for (const file of ["assets.js", "edges.js"]) {
    const f = load(file); const asset = file === "assets.js";
    const start = () => asset ? f.api.requestAllAssets(7n, 8) : f.api.requestAllEdges(7n);
    let p = start(); const packet = f.packets.at(-1); const cid = asset ? assetCorrelation(packet) : edgeCorrelation(packet);
    (asset ? f.api.handleAssetErrorResponse : f.api.handleEdgeErrorResponse)(asset ? 35 : 53, cid, "denied");
    await assert.rejects(p, /denied/);
    let cancelled = false; p = asset ? f.api.requestAllAssets(7n, 8, { isCancelled: () => cancelled }) : f.api.requestAllEdges(7n, { isCancelled: () => cancelled });
    cancelled = true; const cid2 = asset ? assetCorrelation(f.packets.at(-1)) : edgeCorrelation(f.packets.at(-1));
    if (asset) f.api.handleAssetListPage(assetPage(cid2, [])); else f.api.handleAllEdgeListPage(edgePage(cid2, []));
    await assert.rejects(p, /cancelled/);
    p = start(); (asset ? f.api.clearPendingAssetRpc : f.api.clearPendingEdgeRpc)();
    await assert.rejects(p, /Connection closed/);
  }
});
