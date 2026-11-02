import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { readFile } from "node:fs/promises";

const framesSource = await readFile(new URL("./protocol.js", import.meta.url), "utf8") + "\n" +
  await readFile(new URL("./frames.js", import.meta.url), "utf8");
const source = framesSource + await readFile(new URL("./transactions.js", import.meta.url), "utf8");

function fixture() {
  const packets = [];
  let nextId = 0x01020304;
  const window = { NRCAssets: { generateCorrelationId: () => nextId++ } };
  const context = vm.createContext({
    window,
    ws: { readyState: 1 },
    WebSocket: { OPEN: 1 },
    sendPacket: (packet) => packets.push(packet),
    TextEncoder,
    TextDecoder,
    DataView,
    ArrayBuffer,
    Uint8Array,
    BigInt,
    console,
  });
  vm.runInContext(source, context);
  return { api: window.NRCTransactions, packets };
}

test("slice tasks encode atomic task membership and settle only a matching commit", () => {
  const { api, packets } = fixture();
  let saved;
  const id = api.sendCreateSliceTask("Why?", "Ä?", 9007199254740993n, { onSuccess: value => { saved = value; } });
  const bytes = new Uint8Array(packets[0]);
  const view = new DataView(packets[0]);
  assert.equal(view.getUint16(0), 27);
  assert.equal(view.getUint16(4), 2);
  assert.equal(bytes[10], 1);
  assert.equal(view.getUint32(12), 47);
  assert.equal(view.getBigUint64(16), 0n);
  assert.deepEqual([...bytes.slice(24, 28)], [0, 128, 0, 0]);
  assert.deepEqual([...bytes.slice(36, 48)], [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual([...bytes.slice(48, 63)], [0, 4, 87, 104, 121, 63, 0, 3, 195, 132, 63, 0, 0, 0, 0]);
  assert.equal(bytes[63], 5);
  assert.equal(view.getUint32(65), 34);
  assert.deepEqual([...bytes.slice(77, 89)], [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual([...bytes.slice(89, 93)], [0, 2, 0, 0]);
  assert.equal(view.getBigUint64(93), 9007199254740993n);
  assert.equal(view.getUint16(101), 7);
  assert.equal(saved, undefined);
  assert.equal(api.handleTransactionApplied(transactionResult(id, 0, 0xffff, [[3, 8n], [5, 9n]])), false);
  assert.equal(saved, undefined);
  assert.equal(api.handleTransactionApplied(transactionResult(id, 0, 0xffff, [[1, 8n], [5, 9n]])), true);
  assert.equal(saved.taskId, 8n);
  assert.equal(saved.edgeId, 9n);
  assert.throws(() => api.sendCreateSliceTask("ä".repeat(129), "", 7n), /256/);
  assert.throws(() => api.sendCreateSliceTask("x", "ä".repeat(2049), 7n), /4096/);
  assert.equal(packets.length, 1);
});

test("sendCreateLinkedAsset writes the exact two-operation transaction wire format", () => {
  const { api, packets } = fixture();
  const correlationId = api.sendCreateLinkedAsset(0x0102030405060708n, 8, "P£", "{}", 0x1112131415161718n);
  assert.equal(correlationId, 0x01020304);
  assert.equal(packets.length, 1);
  assert.deepEqual([...new Uint8Array(packets[0])], [
    0, 27, 1, 0, 0, 2, 1, 2, 3, 4,
    3, 0, 0, 0, 0, 26,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 2, 0, 3, 80, 194, 163, 0, 2, 123, 125,
    5, 0, 0, 0, 0, 34,
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 2, 0, 0, 17, 18, 19, 20, 21, 22, 23, 24,
    0, 7,
  ]);
});

function transactionResult(correlationId, status, failed, entries) {
  const buffer = new ArrayBuffer(12 + entries.length * 10);
  const view = new DataView(buffer);
  view.setUint16(0, 137, false);
  view.setUint8(2, 1);
  view.setUint8(3, status);
  view.setUint32(4, correlationId, false);
  view.setUint16(8, failed, false);
  view.setUint16(10, entries.length, false);
  entries.forEach(([type, id], index) => {
    view.setUint8(12 + index * 10, type);
    view.setBigUint64(14 + index * 10, id, false);
  });
  return view;
}

test("full committed result settles matching request with created asset ID", () => {
  const { api } = fixture();
  let result;
  const correlationId = api.sendCreateLinkedAsset(7n, 8, "", "x", 9n, { onSuccess: (value) => { result = value; } });
  assert.equal(api.handleTransactionApplied(transactionResult(correlationId, 0, 0xffff, [[3, 44n], [5, 55n]])), true);
  assert.deepEqual({ ...result }, { correlationId, assetId: 44n, edgeId: 55n });
});

test("metadata patch encodes optimistic version and text without attachments", () => {
  const { api, packets } = fixture();
  let result;
  const id = api.sendAssetMetadataPatch({ convId: 7n, assetId: 19n, updatedAt: 257n }, "£", "xyz", { onSuccess: value => { result = value; } });
  assert.deepEqual([...new Uint8Array(packets[0])], [
    0, 27, 1, 0, 0, 1, 1, 2, 3, 4,
    4, 0, 0, 0, 0, 43,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 19,
    0, 0, 0, 0, 0, 0, 1, 1,
    3, 0, 2, 194, 163, 0, 0, 0, 0, 3, 0, 3, 120, 121, 122,
  ]);
  assert.equal(api.handleTransactionApplied(transactionResult(id, 0, 0xffff, [[3, 19n]])), false);
  assert.equal(result, undefined);
  assert.equal(api.handleTransactionApplied(transactionResult(id, 0, 0xffff, [[4, 19n]])), true);
  assert.equal(result.assetId, 19n);
  assert.throws(() => api.sendAssetMetadataPatch({ convId: 7n, assetId: 19n, updatedAt: 257n }, "£".repeat(2049), ""), /limits/);
  assert.equal(packets.length, 1);
});

test("metadata patch can update preview or payload independently", () => {
  const { api, packets } = fixture();
  const asset = { assetId: 19n, updatedAt: 257n };
  api.sendAssetMetadataPatch(asset, "meta", null);
  api.sendAssetMetadataPatch(asset, null, "body");
  const preview = new DataView(packets[0]);
  const payload = new DataView(packets[1]);
  assert.equal(preview.getUint32(12, false), 35);
  assert.equal(preview.getUint8(44), 1);
  assert.equal(new TextDecoder().decode(new Uint8Array(packets[0], 47, 4)), "meta");
  assert.equal(payload.getUint32(12, false), 40);
  assert.equal(payload.getUint8(44), 2);
  assert.equal(new TextDecoder().decode(new Uint8Array(packets[1], 52, 4)), "body");
  assert.throws(() => api.sendAssetMetadataPatch(asset, null, null), /must be provided/);
});

test("transaction error routing is opcode- and correlation-aware", () => {
  const { api } = fixture();
  const failures = [];
  const correlationId = api.sendCreateLinkedAsset(7n, 9, "", "x", 9n, { onError: (value) => failures.push(value) });
  assert.equal(api.handleTransactionErrorResponse(30, correlationId, "wrong route"), false);
  assert.equal(failures.length, 0);
  assert.equal(api.handleTransactionErrorResponse(27, correlationId + 1, "wrong correlation"), true);
  assert.equal(failures.length, 0);
  assert.equal(api.handleTransactionErrorResponse(27, correlationId, "atomic failure"), true);
  assert.equal(failures[0].message, "atomic failure");
});

test("rejected result reports failed operation and disconnect settles once with unknown outcome", () => {
  const { api } = fixture();
  const failures = [];
  const first = api.sendCreateLinkedAsset(7n, 10, "", "x", 9n, { onError: (value) => failures.push(value) });
  assert.equal(api.handleTransactionApplied(transactionResult(first, 1, 1, [])), true);
  assert.equal(failures[0].message, "Transaction rejected at operation 1");

  const second = api.sendCreateLinkedAsset(7n, 10, "", "x", 9n, { onError: (value) => failures.push(value) });
  api.clearPendingTransactionRpc();
  api.handleTransactionErrorResponse(27, second, "disconnected");
  assert.equal(failures.length, 2);
  assert.equal(failures[1].uncertain, true);
  assert.match(failures[1].message, /outcome is unknown/);
});
