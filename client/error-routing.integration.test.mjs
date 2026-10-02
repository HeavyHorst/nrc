import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const clientDir = path.resolve("./client");

function makeCustomEventClass() {
  return class CustomEvent {
    constructor(type, init = {}) {
      this.type = type;
      this.detail = init.detail;
    }
  };
}

function loadAssetsModule() {
  const logs = [];
  const events = [];
  const packets = [];
  const CustomEvent = makeCustomEventClass();
  const sandboxWindow = {
    zstdCodec: null,
  };

  const sandbox = {
    console,
    TextEncoder,
    TextDecoder,
    Uint8Array,
    ArrayBuffer,
    DataView,
    BigInt,
    WebSocket: { OPEN: 1 },
    ws: { readyState: 1 },
    serverReady: true,
    currentRoomId: 1n,
    sendPacket: (buffer) => packets.push(buffer),
    updateAgendaDisplay: () => {},
    logMessage: (kind, message) => logs.push({ kind, message }),
    CustomEvent,
    document: {
      dispatchEvent: (event) => events.push(event),
      addEventListener: () => {},
      removeEventListener: () => {},
    },
    Opcode: {
      C_CreateAsset: 30,
      C_UpdateAsset: 31,
      C_DeleteAsset: 32,
      C_GetAsset: 33,
      C_ListAssets: 34,
      C_ListAssetsPaged: 35,
    },
    window: sandboxWindow,
  };

  const source = fs.readFileSync(path.join(clientDir, "assets.js"), "utf8");
  vm.runInNewContext(source, sandbox, { filename: "assets.js" });

  return {
    assets: sandbox.window.NRCAssets,
    logs,
    events,
    packets,
    windowRef: sandbox.window,
    sandbox,
  };
}

function fullAssetPacket(correlationId, payload = "content", invalid = false, assetType = 5) {
  const bytes = new TextEncoder().encode(payload);
  const view = new DataView(new ArrayBuffer(63 + bytes.length));
  view.setUint16(2, assetType);
  view.setBigUint64(4, 42n);
  view.setBigUint64(40, 0n);
  view.setUint32(49, bytes.length + (invalid ? 1 : 0));
  view.setUint16(55, bytes.length);
  new Uint8Array(view.buffer, 57, bytes.length).set(bytes);
  view.setUint32(59 + bytes.length, correlationId);
  return view;
}

function loadEdgesModule() {
  const logs = [];
  const events = [];
  const packets = [];
  let nextCorrelationId = 1000;
  const CustomEvent = makeCustomEventClass();

  const sandbox = {
    console,
    TextDecoder,
    Uint8Array,
    ArrayBuffer,
    DataView,
    BigInt,
    WebSocket: { OPEN: 1 },
    ws: { readyState: 1 },
    sendPacket: (buffer) => packets.push(buffer),
    logMessage: (kind, message) => logs.push({ kind, message }),
    CustomEvent,
    document: {
      dispatchEvent: (event) => events.push(event),
      addEventListener: () => {},
      removeEventListener: () => {},
    },
    Opcode: {
      C_CreateEdge: 40,
      C_DeleteEdge: 41,
      C_ListEdges: 42,
      C_ListAllEdges: 43,
      C_GraphQuery: 44,
      C_GraphShortestPath: 45,
      C_GraphDegree: 46,
      C_GraphCommonNeighbors: 47,
    },
    window: {
      NRCAssets: {
        generateCorrelationId: () => {
          nextCorrelationId += 1;
          return nextCorrelationId;
        },
      },
    },
  };

  const source = fs.readFileSync(path.join(clientDir, "edges.js"), "utf8");
  vm.runInNewContext(source, sandbox, { filename: "edges.js" });

  return {
    edges: sandbox.window.NRCEdges,
    logs,
    events,
    packets,
  };
}

test("asset update-not-found error settles pending request by correlation", () => {
  const { assets, logs, events, packets } = loadAssetsModule();

  let errorCalls = 0;
  let successCalls = 0;

  const correlationId = assets.sendUpdateAsset(
    42n,
    900n,
    "preview",
    "payload",
    assets.AssetType.Note,
    0,
    {
      context: "NOTE #900",
      onSuccess: () => {
        successCalls += 1;
      },
      onError: (detail) => {
        assert.equal(detail.message, "Asset not found");
        errorCalls += 1;
      },
    },
  );

  assert.ok(correlationId > 0);
  assert.equal(packets.length, 1);

  const handled = assets.handleAssetErrorResponse(31, correlationId, "Asset not found");
  assert.equal(handled, true);
  assert.equal(errorCalls, 1);
  assert.equal(successCalls, 0);

  const errorLog = logs.find((entry) => entry.message.includes("ASSET UPDATE FAILED"));
  assert.ok(errorLog, "expected asset update failure log");
  assert.ok(errorLog.message.includes("NOTE #900"));
  assert.ok(errorLog.message.includes("Asset not found"));

  const errorEvent = events.find((event) => event.type === "nrc:asset-request-error");
  assert.ok(errorEvent, "expected nrc:asset-request-error event");
  assert.equal(errorEvent.detail.correlationId, correlationId);

  // A duplicate centralized error with the same correlation must not retrigger callbacks.
  assets.handleAssetErrorResponse(31, correlationId, "Asset not found");
  assert.equal(errorCalls, 1);
});

test("uncached workspace asset deletion invalidates calendar summaries", () => {
  const { assets, windowRef } = loadAssetsModule();
  let refreshes = 0;
  windowRef.NRCCalendar = { refreshSoon: () => refreshes++ };
  const view = new DataView(new ArrayBuffer(22));
  view.setBigUint64(10, 901n);
  assets.handleAssetDeleted(view);
  assert.equal(refreshes, 1, "no asset cache or pending local delete is necessary");
  view.setBigUint64(2, 42n);
  assets.handleAssetDeleted(view);
  assert.equal(refreshes, 1, "non-workspace deletions do not invalidate calendar");
});

test("asset success settles pending request and prevents stale error settlement", () => {
  const { assets } = loadAssetsModule();

  let successCalls = 0;
  let errorCalls = 0;

  const correlationId = assets.sendDeleteAsset(42n, 901n, {
    onSuccess: () => {
      successCalls += 1;
    },
    onError: () => {
      errorCalls += 1;
    },
  });

  const ack = new ArrayBuffer(22);
  const view = new DataView(ack);
  view.setBigUint64(2, 42n, false);
  view.setBigUint64(10, 901n, false);
  view.setUint32(18, correlationId, false);
  assets.handleAssetDeleted(view);

  assert.equal(successCalls, 1);
  assert.equal(errorCalls, 0);

  assets.handleAssetErrorResponse(32, correlationId, "Asset not found");
  assert.equal(errorCalls, 0);
});

test("asset success publishes full cache before reentrant subscribers; raw refresh still sends", () => {
  for (const payload of ["content", ""]) {
    const { assets, packets } = loadAssetsModule();
    const calls = [];
    const first = assets.requestAsset(7n, 42n, { onSuccess: ({ asset }) => {
      assert.equal(assets.roomAssets.get(0n).get(42n), asset);
      assets.requestAsset(7n, 42n, { onSuccess: ({ asset: cached }) => {
        assert.equal(cached.payload, payload);
        calls.push("reentrant");
      } });
      calls.push("first");
    } });
    assets.requestAsset(7n, 42n, { onSuccess: () => calls.push("second") });
    assets.handleAssetFull(fullAssetPacket(first, payload));
    assert.deepEqual(calls, ["reentrant", "first", "second"]);
    assert.equal(packets.length, 1);
    assets.sendGetAsset(7n, 42n);
    assert.equal(packets.length, 2, "explicit refresh bypasses full cache");
  }
});

test("asset mutation publishes slice changes to the slice register", () => {
  const { assets, windowRef } = loadAssetsModule();
  const changed = [];
  windowRef.NRCSlices = {
    onAssetChanged: (asset, reason, correlationId) => changed.push({ asset, reason, correlationId }),
  };

  assets.handleAssetUpdated(fullAssetPacket(0, "", false, assets.AssetType.Slice));

  assert.equal(changed.length, 1);
  assert.equal(changed[0].asset.assetType, assets.AssetType.Slice);
  assert.equal(changed[0].asset.convId, 0n);
  assert.equal(changed[0].reason, "mutation");
  assert.equal(changed[0].correlationId, 0, "broadcast identity reaches the slice register");
});

test("undecodable full assets fail all subscribers without publishing or notifying success", () => {
  const { assets, packets } = loadAssetsModule();
  let success = 0;
  let errors = 0;
  assets.setOnNoteChanged(() => success++);
  const first = assets.requestAsset(7n, 42n, { onSuccess: () => success++, onError: () => errors++ });
  assets.requestAsset(7n, 42n, { onSuccess: () => success++, onError: () => errors++ });
  assets.handleAssetFull(fullAssetPacket(first, "bad", true));
  assert.equal(success, 0);
  assert.equal(errors, 2);
  assert.equal(assets.roomAssets.has(7n), false);
  assets.requestAsset(7n, 42n);
  assert.equal(packets.length, 2);
});

test("asset disconnect callbacks can queue a shared retry which settles after reconnect", () => {
  const { assets, packets, sandbox } = loadAssetsModule();
  let successes = 0;
  const retry = () => assets.requestAsset(7n, 42n, { onSuccess: () => successes++ });
  assets.requestAsset(7n, 42n, { onError: retry });
  assets.requestAsset(7n, 42n, { onError: retry });
  sandbox.serverReady = false;
  sandbox.ws.readyState = 3;
  assets.clearPendingAssetRpc();
  assert.equal(packets.length, 1);
  sandbox.serverReady = true;
  sandbox.ws.readyState = 1;
  assets.retryPendingAssetRequests();
  assert.equal(packets.length, 2);
  const correlationId = new DataView(packets[1]).getUint32(18);
  assets.handleAssetFull(fullAssetPacket(correlationId));
  assert.equal(successes, 2);
});

test("exact asset reads use full cache entries and coalesce by room and 64-bit ID", () => {
  const { assets, packets } = loadAssetsModule();
  const id = 9007199254740999n;
  const cached = { convId: 0n, assetId: id, payload: "full" };
  assets.roomAssets.set(0n, new Map([[id, cached]]));
  let cachedResult;
  assert.equal(assets.requestAsset(7n, id, { onSuccess: ({ asset }) => { cachedResult = asset; } }), cached);
  assert.equal(cachedResult, cached);
  assert.equal(packets.length, 0);

  const calls = [];
  const first = assets.requestAsset(7n, id + 1n, { onError: () => calls.push("a") });
  const duplicate = assets.requestAsset(7n, id + 1n, { onError: () => calls.push("b") });
  const otherRoom = assets.requestAsset(8n, id + 1n);
  assert.equal(duplicate, first);
  assert.equal(otherRoom, first);
  assert.equal(packets.length, 1);

  assets.handleAssetErrorResponse(33, first, "Asset not found");
  assert.deepEqual(calls, ["a", "b"]);
  const retry = assets.requestAsset(7n, id + 1n);
  assert.notEqual(retry, first);
  assert.equal(packets.length, 2);
});

test("exact asset reads do not mistake preview-only cache entries for full payloads", () => {
  const { assets, packets } = loadAssetsModule();
  assets.roomAssets.set(0n, new Map([[5n, { convId: 0n, assetId: 5n, preview: "title", payload: null }]]));
  assets.requestAsset(4n, 5n);
  assert.equal(packets.length, 1);
});

test("disconnect settles every exact asset subscriber and allows a fresh request", () => {
  const { assets, packets } = loadAssetsModule();
  const calls = [];
  const first = assets.requestAsset(7n, 42n, { onError: () => calls.push("a") });
  assets.requestAsset(7n, 42n, { onError: () => calls.push("b") });
  assets.clearPendingAssetRpc();
  assert.deepEqual(calls, ["a", "b"]);
  assert.notEqual(assets.requestAsset(7n, 42n), first);
  assert.equal(packets.length, 2);
});

test("asset list-paged request without cursor writes correlation at protocol offset", () => {
  const { assets, packets } = loadAssetsModule();

  const correlationId = assets.sendListAssetsPaged(
    42n,
    assets.AssetType.Note,
    true,
    50,
    null,
    null,
  );

  assert.ok(correlationId > 0);
  assert.equal(packets.length, 1);

  const view = new DataView(packets[0]);
  assert.equal(view.getUint16(0, false), 35); // C_ListAssetsPaged
  assert.equal(view.getUint8(15), 0); // has_cursor=false
  assert.equal(view.getUint32(16, false), correlationId);
});

test("off-room note pages still notify the notes cache owner", () => {
  const { assets } = loadAssetsModule();
  const correlation = assets.sendListAssetsPaged(7n, assets.AssetType.Note);
  let event = null;
  assets.setOnNoteChanged((asset, action) => { event = { asset, action }; });
  const packet = new DataView(new ArrayBuffer(38));
  packet.setBigUint64(2, 7n, false);
  packet.setUint8(10, 0);
  packet.setUint8(11, 0);
  packet.setBigInt64(12, 0n, false);
  packet.setBigUint64(20, 0n, false);
  packet.setUint32(28, 0, false);
  packet.setUint16(32, 0, false);
  packet.setUint32(34, correlation, false);

  assets.handleAssetListPage(packet);

  assert.equal(event.action, "list_page");
  assert.equal(event.asset.convId, 7n);
});

test("customer pages do not overwrite the Notes pagination state", async () => {
  const { assets, packets } = loadAssetsModule();
  let noteEvents = 0;
  assets.setOnNoteChanged(() => noteEvents++);
  const load = assets.requestAllAssets(7n, assets.AssetType.CustomerContact);
  const correlation = new DataView(packets[0]).getUint32(16, false);
  const packet = new DataView(new ArrayBuffer(38));
  packet.setBigUint64(2, 7n, false);
  packet.setUint32(34, correlation, false);
  assets.handleAssetListPage(packet);
  await load;
  assert.equal(noteEvents, 0);
});

test("asset list callbacks receive the exact decoded snapshot after the cache is populated", () => {
  const { assets } = loadAssetsModule();
  assets.roomAssets.set(0n, new Map([[999n, { assetId: 999n, assetType: 8 }]]));
  let result;
  let cachedPayloadAtCallback;
  const correlationId = assets.sendListAssets(7n, 8, true, {
    onSuccess(detail) {
      result = detail;
      cachedPayloadAtCallback = assets.roomAssets.get(0n).get(42n)?.payload;
    },
  });
  const full = fullAssetPacket(0, "customer record");
  full.setUint16(2, 8, false);
  const encodedAsset = new Uint8Array(full.buffer, 2, full.byteLength - 6);
  const packet = new DataView(new ArrayBuffer(17 + encodedAsset.length));
  packet.setBigUint64(2, 0n, false);
  packet.setUint8(10, 1);
  packet.setUint16(11, 1, false);
  packet.setUint32(13, correlationId, false);
  new Uint8Array(packet.buffer, 17).set(encodedAsset);
  assets.handleAssetList(packet);
  assert.equal(cachedPayloadAtCallback, "customer record");
  assert.equal(result.assets.length, 1, "snapshot excludes unrelated cached records");
  assert.equal(result.assets[0].assetId, 42n);
  assert.equal(result.assets[0].assetType, 8);
});

test("bulk comment ingestion notifies task comment-count consumers", () => {
  const { assets, packets } = loadAssetsModule();
  let event = null;
  assets.setOnCommentChanged((asset, action) => { event = { asset, action }; });
  assets.sendListComments(7n);
  const correlationId = new DataView(packets[0]).getUint32(14, false);
  const packet = new DataView(new ArrayBuffer(17));
  packet.setBigUint64(2, 7n, false);
  packet.setUint8(10, 1);
  packet.setUint16(11, 0, false);
  packet.setUint32(13, correlationId, false);

  assets.handleAssetList(packet);

  assert.equal(event.action, "list");
  assert.equal(event.asset.convId, 7n);
});

test("edge create error settles pending request by origin opcode and correlation", () => {
  const { edges, logs, events, packets } = loadEdgesModule();

  let errorCalls = 0;
  const correlationId = edges.sendCreateEdge(
    7n,
    edges.TargetType.Task,
    11n,
    edges.TargetType.Asset,
    22n,
    edges.RelationType.RelatedTo,
    {
      context: "TASK #11 -> ASSET #22",
      onError: (detail) => {
        assert.equal(detail.message, "Self-edge not allowed");
        errorCalls += 1;
      },
    },
  );

  assert.ok(correlationId > 0);
  assert.equal(packets.length, 1);

  const handled = edges.handleEdgeErrorResponse(40, correlationId, "Self-edge not allowed");
  assert.equal(handled, true);
  assert.equal(errorCalls, 1);

  const errorLog = logs.find((entry) => entry.message.includes("EDGE CREATE FAILED"));
  assert.ok(errorLog, "expected edge create failure log");
  assert.ok(errorLog.message.includes("TASK #11 -> ASSET #22"));

  const errorEvent = events.find((event) => event.type === "nrc:edge-request-error");
  assert.ok(errorEvent, "expected nrc:edge-request-error event");
  assert.equal(errorEvent.detail.correlationId, correlationId);
});

test("asset handler ignores non-asset origin opcodes", () => {
  const { assets } = loadAssetsModule();

  const handled = assets.handleAssetErrorResponse(40, 123, "not an asset error");
  assert.equal(handled, false);
});

test("note update-not-found clears selected note detail state", () => {
  const { assets, logs, windowRef } = loadAssetsModule();

  let cleared = 0;
  windowRef.NRCNotes = {
    clearNoteSelection: () => {
      cleared += 1;
    },
  };

  const corr = assets.sendUpdateAsset(
    5n,
    777n,
    "note",
    "body",
    assets.AssetType.Note,
    0,
    { context: "NOTE #777" },
  );
  assert.ok(corr > 0);

  const handled = assets.handleAssetErrorResponse(31, corr, "Asset not found");
  assert.equal(handled, true);
  assert.equal(cleared, 1);

  const noteMissingLogs = logs.filter((entry) =>
    entry.message.includes("NOTE #777 NO LONGER EXISTS IN THIS ROOM"),
  );
  assert.equal(noteMissingLogs.length, 1);

  const updateFailure = logs.find((entry) =>
    entry.message.includes("ASSET UPDATE FAILED") && entry.message.includes("NOTE #777"),
  );
  assert.ok(updateFailure, "expected asset update failure log with note context");

  // Duplicate stale-correlation errors must not retrigger note detail clearing.
  assets.handleAssetErrorResponse(31, corr, "Asset not found");
  assert.equal(cleared, 1);
});

test("edge handler ignores non-edge origin opcodes", () => {
  const { edges } = loadEdgesModule();

  const handled = edges.handleEdgeErrorResponse(31, 321, "not an edge error");
  assert.equal(handled, false);
});
