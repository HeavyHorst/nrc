// Build the JS-only response seeds that the Odin corpus cannot provide.
//
// The Odin seed generator only writes frames its own parsers can re-parse. The
// page/list frames below have serializers but no Odin response parser, so they
// live in client/fuzz/corpus and are validated by decodeServerFrame instead.
// Run: node client/fuzz/build-seeds.cjs

const fs = require("node:fs");
const path = require("node:path");
const { decodeServerFrame } = require("../frames.js");

const outDir = path.join(__dirname, "corpus");

class Writer {
  constructor(size = 64 * 1024) {
    this.buffer = new ArrayBuffer(size);
    this.view = new DataView(this.buffer);
    this.offset = 0;
  }
  u8(value) {
    this.view.setUint8(this.offset, value);
    this.offset += 1;
  }
  u16(value) {
    this.view.setUint16(this.offset, value, false);
    this.offset += 2;
  }
  u32(value) {
    this.view.setUint32(this.offset, value, false);
    this.offset += 4;
  }
  u64(value) {
    this.view.setBigUint64(this.offset, BigInt(value), false);
    this.offset += 8;
  }
  i64(value) {
    this.view.setBigInt64(this.offset, BigInt(value), false);
    this.offset += 8;
  }
  str(value) {
    const bytes = new TextEncoder().encode(value);
    this.u16(bytes.length);
    new Uint8Array(this.buffer, this.offset, bytes.length).set(bytes);
    this.offset += bytes.length;
  }
  bytes() {
    return Buffer.from(new Uint8Array(this.buffer, 0, this.offset));
  }
}

function writeTask(w, task) {
  w.u64(task.id);
  w.u64(task.convId);
  w.str(task.title);
  w.str(task.description);
  w.u8(task.status);
  w.u16(task.orderIndex);
  w.str(task.assignee);
  w.u8(task.priority);
  w.u8(task.color);
  w.str(task.createdBy);
  w.i64(task.createdAt);
  w.i64(task.updatedAt);
  w.str(task.externalRef);
  w.i64(task.dueAt);
  w.u64(task.blockedBy);
  w.i64(task.completedAt);
  w.str(task.completedBy);
  w.str(task.project);
  w.u16(task.attachments.length);
  for (const attachment of task.attachments) {
    w.str(attachment.fileId);
    w.str(attachment.filename);
    w.u64(attachment.size);
    w.str(attachment.mimeType);
    w.i64(attachment.uploadedAt);
  }
}

function writeAssetHeader(w, asset) {
  w.u16(asset.assetType);
  w.u64(asset.assetId);
  w.u16(asset.parentType);
  w.u64(asset.parentId);
  w.str(asset.owner);
  w.i64(asset.createdAt);
  w.i64(asset.updatedAt);
  w.u64(asset.convId);
  w.u8(asset.payloadEncoding);
  w.u32(asset.payloadRawLen);
  w.str(asset.preview);
  w.u16(asset.attachments.length);
  for (const attachment of asset.attachments) {
    w.str(attachment.fileId);
    w.str(attachment.filename);
    w.u64(attachment.size);
    w.str(attachment.mimeType);
    w.i64(attachment.uploadedAt);
  }
}

function writeEdge(w, edge) {
  w.u64(edge.edgeId);
  w.u64(edge.convId);
  w.u16(edge.sourceType);
  w.u64(edge.sourceId);
  w.u16(edge.targetType);
  w.u64(edge.targetId);
  w.u16(edge.relation);
  w.i64(edge.createdAt);
  w.str(edge.createdBy);
}

const task = {
  id: 7n,
  convId: 42n,
  title: "Ship response fuzzing",
  description: "Exercise the response parsers",
  status: 1,
  orderIndex: 1,
  assignee: "alice",
  priority: 2,
  color: 5,
  createdBy: "alice",
  createdAt: 1_700_000_000_000_000_000n,
  updatedAt: 1_700_000_100_000_000_000n,
  externalRef: "NRC-400",
  dueAt: 0n,
  blockedBy: 0n,
  completedAt: 0n,
  completedBy: "",
  project: "tooling",
  attachments: [],
};

const asset = {
  assetType: 5,
  assetId: 11n,
  parentType: 1,
  parentId: 7n,
  owner: "alice",
  createdAt: 1_700_000_000_000_000_000n,
  updatedAt: 1_700_000_100_000_000_000n,
  convId: 42n,
  payloadEncoding: 0,
  payloadRawLen: 4,
  preview: '{"title":"note"}',
  attachments: [],
};

const edge = {
  edgeId: 3n,
  convId: 42n,
  sourceType: 2,
  sourceId: 7n,
  targetType: 1,
  targetId: 11n,
  relation: 7,
  createdAt: 1_700_000_000_000_000_000n,
  createdBy: "alice",
};

const seeds = {
  response_transaction_result: w => {
    w.u16(137);
    w.u8(1); // wire version
    w.u8(0); // committed
    w.u32(1); // correlation
    w.u16(0xffff); // no failed operation
    w.u16(1);
    w.u8(3); // AssetCreate
    w.u8(0);
    w.u64(11);
  },
  response_task_query_page: w => {
    w.u16(138);
    w.u64(42);
    w.u8(1);
    w.u16(1);
    writeTask(w, task);
    w.u8(0);
    w.i64(0);
    w.u64(0);
    w.str("");
    w.u32(1);
    w.str("");
    w.u32(1);
  },
  response_task_projects: w => {
    w.u16(139);
    w.u64(0);
    w.u16(1);
    w.str("tooling");
    w.u8(0);
    w.u32(1);
  },
  response_edge_list_page: w => {
    w.u16(162);
    w.u64(42);
    w.u16(2);
    w.u64(7);
    w.u8(0);
    w.u64(0);
    w.u32(1);
    w.u16(1);
    w.u32(1);
    writeEdge(w, edge);
  },
  response_customer_search_page: w => {
    w.u16(163);
    w.u64(0);
    w.u8(0);
    w.u64(0);
    w.u32(1);
    w.u16(1);
    w.u32(1);
    writeAssetHeader(w, asset);
  },
  response_task_assignees: w => {
    w.u16(165);
    w.u64(0);
    w.u16(1);
    w.str("alice");
    w.u8(0);
    w.u32(1);
  },
  response_calendar_page: w => {
    w.u16(166);
    w.u64(0);
    w.u16(1);
    w.u8(0);
    w.i64(1_700_000_000_000_000_000n);
    w.u8(0);
    w.u64(7);
    w.u8(0); // task row
    w.u64(7);
    w.i64(1_700_000_000_000_000_000n);
    w.u8(0);
    w.str("Ship response fuzzing");
    w.str("alice");
    w.str("tooling");
    w.u32(1);
  },
  response_workspace_overview: w => {
    w.u16(167);
    w.u64(0);
    w.u8(1);
    w.i64(1_700_000_000_000_000_000n);
    for (const value of [1, 0, 0, 0]) w.u32(value);
    w.u32(1);
    w.u32(0);
    w.u32(1);
    for (const value of [1, 0, 0, 0, 0]) w.u32(value);
    for (const value of [0, 0, 0]) w.u32(value);
    for (const value of [1, 0, 0, 0, 0]) w.u32(value);
    w.str("");
    w.u32(1);
  },
  response_history_page: w => {
    w.u16(168);
    w.u32(1);
    const bytes = new TextEncoder().encode('{"events":[],"nextBefore":"0"}');
    new Uint8Array(w.buffer, w.offset, bytes.length).set(bytes);
    w.offset += bytes.length;
  },
  response_ticket_page: w => {
    w.u16(169);
    w.u32(1);
    const metadata = new TextEncoder().encode('{"total":0}');
    w.u32(metadata.length);
    new Uint8Array(w.buffer, w.offset, metadata.length).set(metadata);
    w.offset += metadata.length;
    w.u16(1);
    w.u8(0);
    writeAssetHeader(w, asset);
  },
  response_task_dependents_page: w => {
    w.u16(170);
    w.u64(0);
    w.u64(7);
    w.u8(1);
    w.u16(1);
    writeTask(w, { ...task, blockedBy: 7n });
    w.u8(0);
    w.u64(7);
    w.str("");
    w.u32(1);
  },
  response_slice_owners: w => {
    w.u16(171);
    w.u64(0);
    w.u16(1);
    w.str("alice");
    w.u8(0);
    w.u32(1);
  },
  response_ticket_assignees: w => {
    w.u16(172);
    w.u64(0);
    w.u16(1);
    w.str("alice");
    w.u8(0);
    w.u32(1);
  },
  response_calendar_people: w => {
    w.u16(173);
    w.u64(0);
    w.u16(1);
    w.str("alice");
    w.u8(0);
    w.u32(1);
  },
};

fs.mkdirSync(outDir, { recursive: true });
for (const [name, build] of Object.entries(seeds)) {
  const writer = new Writer();
  build(writer);
  const bytes = writer.bytes();
  const decoded = decodeServerFrame(
    new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
  );
  if (!decoded || decoded.opcode !== bytes.readUInt16BE(0)) {
    throw new Error(`${name} did not decode`);
  }
  fs.writeFileSync(path.join(outDir, `${name}.bin`), bytes);
  console.log(`wrote ${name}.bin (${bytes.length} bytes, ${decoded.kind})`);
}
