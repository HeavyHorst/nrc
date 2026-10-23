// Seed replay for the shared client protocol decoder. The coverage-guided
// campaign is opt-in (test/run_js_protocol_fuzz.sh); this test keeps the
// committed Odin-generated and JS-only corpora honest in the normal
// node --test tier.

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import fs from "node:fs";
import test from "node:test";

const require = createRequire(import.meta.url);
const protocol = require("./protocol.js");
const retained = require("./retained-messages.js");
const { decodeServerFrame, SUPPORTED_OPCODES } = require("./frames.js");

const corpusDirs = [
  new URL("../test/protocol_fuzz/corpus/", import.meta.url),
  new URL("./fuzz/corpus/", import.meta.url),
];

function isProtocolError(error) {
  return error instanceof protocol.ProtocolError || error instanceof retained.ProtocolError;
}

function readSeed(name) {
  for (const corpusDir of corpusDirs) {
    const file = new URL(name, corpusDir);
    if (fs.existsSync(file)) return fs.readFileSync(file);
  }
  throw new Error(`missing seed ${name}`);
}

function viewOf(bytes) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

function supportedSeeds() {
  const seeds = [];
  const seen = new Set();
  for (const corpusDir of corpusDirs) {
    for (const name of fs.readdirSync(corpusDir).sort()) {
      if (!name.endsWith(".bin") || seen.has(name)) continue;
      const bytes = readSeed(name);
      if (bytes.length < 2) continue;
      const opcode = bytes.readUInt16BE(0);
      if (!SUPPORTED_OPCODES.includes(opcode)) continue;
      seen.add(name);
      seeds.push({ name, opcode, bytes });
    }
  }
  return seeds;
}

test("every supported response opcode has a committed seed", () => {
  const present = new Set(supportedSeeds().map((seed) => seed.opcode));
  const missing = SUPPORTED_OPCODES.filter((opcode) => !present.has(opcode));
  assert.deepEqual(missing, [], `missing response seeds for opcodes: ${missing.join(", ")}`);
});

const RESPONSE_KINDS = {
  100: "server_ready",
  102: "new_message",
  103: "ack_send_message",
  104: "error_response",
  109: "room_presence",
  121: "dm_started",
  122: "dm_list",
  123: "dm_error",
  124: "dm_left",
  125: "dm_partner_status",
  126: "pong",
  127: "ack_unsubscribe",
  130: "task_created",
  131: "task_updated",
  132: "task_deleted",
  133: "task_moved",
  134: "task_list",
  135: "task_page",
  136: "task_full",
  137: "transaction_result",
  138: "task_query_page",
  139: "task_projects",
  140: "asset_created",
  141: "asset_updated",
  142: "asset_deleted",
  143: "asset_full",
  144: "asset_list",
  145: "asset_page",
  146: "note_projects",
  147: "note_tags",
  150: "edge_created",
  151: "edge_deleted",
  152: "edge_list",
  153: "all_edge_list",
  154: "graph_query",
  155: "graph_path",
  156: "graph_degree",
  157: "graph_common",
  158: "subscription_ready",
  159: "message_page",
  161: "all_edge_page",
  162: "edge_page",
  163: "customer_search_page",
  164: "task_slice_list",
  165: "task_assignees",
  166: "calendar_page",
  167: "workspace_overview",
  168: "history_page",
  169: "ticket_page",
  170: "task_dependents_page",
  171: "slice_owners",
  172: "ticket_assignees",
  173: "calendar_people",
};

test("every supported response opcode maps to its frame kind", () => {
  assert.deepEqual(Object.keys(RESPONSE_KINDS).map(Number), [...SUPPORTED_OPCODES]);
  for (const seed of supportedSeeds()) {
    const decoded = decodeServerFrame(viewOf(seed.bytes));
    assert.equal(decoded.kind, RESPONSE_KINDS[seed.opcode], `${seed.name} kind`);
  }
});

test("committed response seeds decode through the shared decoder", () => {
  const seeds = supportedSeeds();
  assert.ok(seeds.length > 0, "no supported response seeds found");
  for (const seed of seeds) {
    const decoded = decodeServerFrame(viewOf(seed.bytes));
    assert.ok(decoded, `${seed.name} decoded to null`);
    assert.equal(decoded.opcode, seed.opcode, `${seed.name} opcode changed`);
  }
});

test("truncated and trailing-byte frames fail as protocol errors", () => {
  for (const seed of supportedSeeds()) {
    for (let length = 0; length < seed.bytes.length; length += 1) {
      const truncated = seed.bytes.subarray(0, length);
      assert.throws(
        () => decodeServerFrame(viewOf(truncated)),
        (error) => isProtocolError(error),
        `${seed.name} accepted a truncated frame at ${length} bytes`,
      );
    }

    const extended = new Uint8Array(seed.bytes.length + 1);
    extended.set(seed.bytes);
    extended[seed.bytes.length] = 0x5a;
    assert.throws(
      () => decodeServerFrame(viewOf(extended)),
      (error) => isProtocolError(error),
      `${seed.name} accepted a trailing byte`,
    );
  }
});

test("task frames decode their wire fields", () => {
  const decoded = decodeServerFrame(viewOf(readSeed("response_task_created.bin")));
  assert.equal(decoded.kind, "task_created");
  assert.equal(decoded.correlationId, 1);
  assert.equal(decoded.task.id, 7n);
  assert.equal(decoded.task.convId, 42n);
  assert.equal(decoded.task.title, "Ship response fuzzing");
  assert.equal(decoded.task.description, "Exercise the response parsers");
  assert.equal(decoded.task.status, 1);
  assert.equal(decoded.task.assignee, "alice");
  assert.equal(decoded.task.project, "tooling");
  assert.equal(decoded.task.attachments.length, 0);
});

test("unpaged task-list responses accept the protocol maximum", () => {
  const count = 1001;
  const title = new TextEncoder().encode("t");
  const taskSize = 77 + title.length;
  const bytes = new Uint8Array(13 + count * taskSize + 6);
  const view = new DataView(bytes.buffer);
  view.setUint16(0, 134, false);
  view.setBigUint64(2, 0n, false);
  view.setUint8(10, 1);
  view.setUint16(11, count, false);
  let offset = 13;
  for (let i = 0; i < count; i += 1) {
    view.setBigUint64(offset, BigInt(i + 1), false); offset += 8;
    view.setBigUint64(offset, 0n, false); offset += 8;
    view.setUint16(offset, title.length, false); offset += 2;
    bytes.set(title, offset); offset += title.length;
    view.setUint16(offset, 0, false); offset += 2; // description
    view.setUint8(offset++, 0); view.setUint16(offset, 0, false); offset += 2;
    view.setUint16(offset, 0, false); offset += 2; // assignee
    view.setUint8(offset++, 0); view.setUint8(offset++, 0);
    view.setUint16(offset, 0, false); offset += 2; // created by
    view.setBigInt64(offset, 0n, false); offset += 8;
    view.setBigInt64(offset, 0n, false); offset += 8;
    view.setUint16(offset, 0, false); offset += 2; // external ref
    view.setBigInt64(offset, 0n, false); offset += 8;
    view.setBigUint64(offset, 0n, false); offset += 8;
    view.setBigInt64(offset, 0n, false); offset += 8;
    view.setUint16(offset, 0, false); offset += 2; // completed by
    view.setUint16(offset, 0, false); offset += 2; // project
    view.setUint16(offset, 0, false); offset += 2; // attachments
  }
  view.setUint16(offset, 0, false); offset += 2; // error
  view.setUint32(offset, 42, false);
  assert.equal(offset + 4, bytes.byteLength);
  const decoded = decodeServerFrame(viewOf(bytes));
  assert.equal(decoded.tasks.length, count);
  assert.equal(decoded.correlationId, 42);
});

test("asset and note-list decoders preserve their wire counts", () => {
  const assetList = decodeServerFrame(viewOf(readSeed("response_asset_list.bin")));
  assert.equal(assetList.count, assetList.assets.length);
  const projects = decodeServerFrame(viewOf(readSeed("response_note_projects.bin")));
  assert.equal(projects.count, projects.values.length);
  const tags = decodeServerFrame(viewOf(readSeed("response_note_tags.bin")));
  assert.equal(tags.count, tags.values.length);
});

test("asset frames decode their header, payload and attachments", () => {
  const decoded = decodeServerFrame(viewOf(readSeed("response_asset_created.bin")));
  assert.equal(decoded.kind, "asset_created");
  assert.equal(decoded.correlationId, 1);
  assert.equal(decoded.asset.assetType, 5);
  assert.equal(decoded.asset.assetId, 11n);
  assert.equal(decoded.asset.parentType, 1);
  assert.equal(decoded.asset.parentId, 7n);
  assert.equal(decoded.asset.owner, "alice");
  assert.equal(decoded.asset.preview, '{"title":"note"}');
  assert.equal(new TextDecoder().decode(decoded.asset.payload), "body");
  assert.equal(decoded.asset.attachments.length, 0);
});

test("edge frames decode their endpoints and relation", () => {
  const decoded = decodeServerFrame(viewOf(readSeed("response_edge_created.bin")));
  assert.equal(decoded.kind, "edge_created");
  assert.equal(decoded.correlationId, 1);
  assert.equal(decoded.edge.edgeId, 3n);
  assert.equal(decoded.edge.convId, 42n);
  assert.equal(decoded.edge.sourceType, 2);
  assert.equal(decoded.edge.sourceId, 7n);
  assert.equal(decoded.edge.targetType, 1);
  assert.equal(decoded.edge.targetId, 11n);
  assert.equal(decoded.edge.relation, 7);
  assert.equal(decoded.edge.createdBy, "alice");
});

test("retained message pages decode through the shared retained codec", () => {
  const decoded = decodeServerFrame(viewOf(readSeed("response_message_page.bin")));
  assert.equal(decoded.kind, "message_page");
  assert.equal(decoded.value.convId, 42n);
  assert.equal(decoded.value.correlationId, 1);
  assert.equal(decoded.value.messages.length, 1);
  assert.equal(decoded.value.messages[0].authorUsername, "alice");
  assert.equal(decoded.value.messages[0].content, "hello");
});

test("unsupported opcodes are skipped rather than decoded", () => {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setUint16(0, 999, false);
  assert.equal(decodeServerFrame(viewOf(bytes)), null);
});
