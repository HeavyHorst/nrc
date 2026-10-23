// Shared server-to-client frame decoders.
//
// The browser loads this file after protocol.js and uses the same decoders the
// Jazzer target calls. It consumes a whole frame: header, records and trailing
// correlation id. Malformed input raises a ProtocolError from this module or
// from protocol.js/retained-messages.js.

(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory(require("./protocol.js"), require("./retained-messages.js"));
  } else {
    root.NRCFrames = factory(root.NRCProtocol, root.NRCRetainedMessages);
  }
})(typeof window !== "undefined" ? window : globalThis, function (protocol, retained) {
  "use strict";

  const {
    ProtocolError,
    parseTask,
    parseAssetAttachments,
    parseAsset,
    parseAssetPayload,
    parseEdge,
  } = protocol;

  const textDecoder = new TextDecoder();
  // Query cursors and facet values round-trip through the wire and are compared
  // byte-for-byte, so keep a leading U+FEFF instead of letting TextDecoder strip it.
  const exactTextDecoder = new TextDecoder("utf-8", { ignoreBOM: true });
  const MAX_TASK_PAGE_SIZE = 1000;

function need(view, offset, size) {
  if (
    !Number.isInteger(offset) ||
    !Number.isInteger(size) ||
    offset < 0 ||
    size < 0 ||
    offset + size > view.byteLength
  ) {
    throw new ProtocolError("truncated frame");
  }
}

function u8(view, offset) {
  need(view, offset, 1);
  return view.getUint8(offset);
}

function u16(view, offset) {
  need(view, offset, 2);
  return view.getUint16(offset, false);
}

function u32(view, offset) {
  need(view, offset, 4);
  return view.getUint32(offset, false);
}

function u64(view, offset) {
  need(view, offset, 8);
  return view.getBigUint64(offset, false);
}

function i64(view, offset) {
  need(view, offset, 8);
  return view.getBigInt64(offset, false);
}

function bytes(view, offset, length) {
  need(view, offset, length);
  return new Uint8Array(view.buffer, view.byteOffset + offset, length);
}

function text(view, offset, length) {
  return textDecoder.decode(bytes(view, offset, length));
}

// Length-prefixed UTF-8 string. The length is a big-endian u16.
function wireString(view, offset) {
  const length = u16(view, offset);
  const value = text(view, offset + 2, length);
  return { value, newOffset: offset + 2 + length };
}

function exactWireString(view, offset) {
  const length = u16(view, offset);
  const value = exactTextDecoder.decode(bytes(view, offset + 2, length));
  return { value, newOffset: offset + 2 + length };
}

function flag(view, offset) {
  const value = u8(view, offset);
  if (value > 1) throw new ProtocolError("invalid flag");
  return value === 1;
}

function expectEnd(view, offset) {
  if (offset !== view.byteLength) throw new ProtocolError("trailing bytes");
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

function parseTaskList(view, offset, count) {
  const tasks = [];
  for (let i = 0; i < count; i += 1) {
    const parsed = parseTask(view, offset);
    tasks.push(parsed.task);
    offset = parsed.newOffset;
  }
  return { tasks, newOffset: offset };
}

function parseEdgeList(view, offset, count) {
  const edges = [];
  for (let i = 0; i < count; i += 1) {
    const parsed = parseEdge(view, offset);
    edges.push(parsed.edge);
    offset = parsed.newOffset;
  }
  return { edges, newOffset: offset };
}

function parseNodes(view, offset, count, withDepth) {
  const nodes = [];
  for (let i = 0; i < count; i += 1) {
    const type = u16(view, offset);
    offset += 2;
    const id = u64(view, offset);
    offset += 8;
    if (withDepth) {
      const depth = u8(view, offset);
      offset += 1;
      nodes.push({ type, id, depth });
    } else {
      nodes.push({ type, id });
    }
  }
  return { nodes, newOffset: offset };
}

function parseFullAsset(view, offset) {
  const parsed = parseAsset(view, offset, false);
  const asset = parsed.asset;
  offset = parsed.newOffset;
  const payload = parseAssetPayload(view, offset);
  asset.payload = payload.payload;
  offset = payload.newOffset;
  const attachments = parseAssetAttachments(view, offset);
  asset.attachments = attachments.attachments;
  return { asset, newOffset: attachments.newOffset };
}

function retainedCodec() {
  const codec = retained || (typeof window !== "undefined" ? window.NRCRetainedMessages : null);
  if (!codec) throw new ProtocolError("retained message codec is not loaded");
  return codec;
}

// ---------------------------------------------------------------------------
// Handshake, chat, presence and direct messages
// ---------------------------------------------------------------------------

function decodeServerReady(view) {
  let offset = 2;
  const build = wireString(view, offset);
  offset = build.newOffset;
  const protocolVersion = u32(view, offset);
  offset += 4;
  const cpu = wireString(view, offset);
  offset = cpu.newOffset;
  const username = wireString(view, offset);
  offset = username.newOffset;
  const isAuthenticated = flag(view, offset);
  offset += 1;
  expectEnd(view, offset);
  return {
    buildVersion: build.value,
    protocolVersion,
    cpuModel: cpu.value,
    username: username.value,
    isAuthenticated,
  };
}

function decodeNewMessage(view) {
  let offset = 2;
  const convId = u64(view, offset);
  offset += 8;
  const seq = u64(view, offset);
  offset += 8;
  const author = wireString(view, offset);
  offset = author.newOffset;
  const timestamp = i64(view, offset);
  offset += 8;
  const contentType = u8(view, offset);
  offset += 1;
  const contentLength = u16(view, offset);
  offset += 2;
  const content = text(view, offset, contentLength);
  offset += contentLength;
  expectEnd(view, offset);
  return {
    convId,
    seq,
    authorUsername: author.value,
    timestamp,
    contentType,
    content,
  };
}

function decodeAckSendMessage(view) {
  const clientReqId = u32(view, 2);
  const assignedSeq = u64(view, 6);
  const timestamp = i64(view, 14);
  expectEnd(view, 22);
  return { clientReqId, assignedSeq, timestamp };
}

function decodeErrorResponse(view) {
  const originOpcode = u16(view, 2);
  const error = wireString(view, 4);
  const correlationId = u32(view, error.newOffset);
  expectEnd(view, error.newOffset + 4);
  return { originOpcode, errorMsg: error.value, correlationId };
}

function decodeRoomPresenceUpdate(view) {
  let offset = 2;
  const convId = u64(view, offset);
  offset += 8;
  const eventType = u8(view, offset);
  offset += 1;
  const sequence = u64(view, offset);
  offset += 8;
  const username = wireString(view, offset);
  offset = username.newOffset;
  const isAuthenticated = flag(view, offset);
  offset += 1;
  const userType = u8(view, offset);
  offset += 1;
  const oldUsername = wireString(view, offset);
  offset = oldUsername.newOffset;
  const count = u16(view, offset);
  offset += 2;
  const userList = [];
  for (let i = 0; i < count; i += 1) {
    const user = wireString(view, offset);
    offset = user.newOffset;
    const authenticated = flag(view, offset);
    offset += 1;
    const type = u8(view, offset);
    offset += 1;
    userList.push({ username: user.value, isAuthenticated: authenticated, userType: type });
  }
  expectEnd(view, offset);
  return {
    convId,
    eventType,
    sequence,
    username: username.value,
    isAuthenticated,
    userType,
    oldUsername: oldUsername.value,
    userList,
  };
}

function decodePongResponse(view) {
  const timestamp = u64(view, 2);
  const serverTimestamp = u64(view, 10);
  expectEnd(view, 18);
  return { timestamp, serverTimestamp };
}

function decodeAckUnsubscribeConvs(view) {
  const correlationId = u32(view, 2);
  expectEnd(view, 6);
  return { correlationId };
}

function decodeDMStarted(view) {
  let offset = 2;
  const convId = u64(view, offset);
  offset += 8;
  const username = wireString(view, offset);
  offset = username.newOffset;
  const authenticated = flag(view, offset);
  offset += 1;
  const online = flag(view, offset);
  offset += 1;
  const isInitiator = flag(view, offset);
  offset += 1;
  const correlationId = u32(view, offset);
  offset += 4;
  expectEnd(view, offset);
  return {
    convId,
    username: username.value,
    authenticated,
    online,
    isInitiator,
    correlationId,
  };
}

function decodeDMList(view) {
  let offset = 2;
  const count = u16(view, offset);
  offset += 2;
  const correlationId = u32(view, offset);
  offset += 4;
  const entries = [];
  for (let i = 0; i < count; i += 1) {
    const convId = u64(view, offset);
    offset += 8;
    const username = wireString(view, offset);
    offset = username.newOffset;
    const authenticated = flag(view, offset);
    offset += 1;
    const online = flag(view, offset);
    offset += 1;
    const lastSeen = u64(view, offset);
    offset += 8;
    entries.push({
      convId,
      username: username.value,
      authenticated,
      online,
      lastSeen,
    });
  }
  expectEnd(view, offset);
  return { count, correlationId, entries };
}

function decodeDMError(view) {
  let offset = 2;
  const errorCode = u8(view, offset);
  offset += 1;
  const target = wireString(view, offset);
  offset = target.newOffset;
  const message = wireString(view, offset);
  offset = message.newOffset;
  const correlationId = u32(view, offset);
  offset += 4;
  expectEnd(view, offset);
  return {
    errorCode,
    targetUsername: target.value,
    message: message.value,
    correlationId,
  };
}

function decodeDMLeft(view) {
  const convId = u64(view, 2);
  const correlationId = u32(view, 10);
  expectEnd(view, 14);
  return { convId, correlationId };
}

function decodeDMPartnerStatus(view) {
  let offset = 2;
  const convId = u64(view, offset);
  offset += 8;
  const online = flag(view, offset);
  offset += 1;
  const username = wireString(view, offset);
  offset = username.newOffset;
  const lastSeen = u64(view, offset);
  offset += 8;
  expectEnd(view, offset);
  return { convId, online, username: username.value, lastSeen };
}

// ---------------------------------------------------------------------------
// Task, slice, calendar, overview and ticket frames
// ---------------------------------------------------------------------------

function decodeStringList(view) {
  const convId = u64(view, 2);
  const count = u16(view, 10);
  let offset = 12;
  const values = [];
  for (let i = 0; i < count; i += 1) {
    const value = exactWireString(view, offset);
    values.push(value.value);
    offset = value.newOffset;
  }
  const hasMore = flag(view, offset);
  offset += 1;
  const correlationId = u32(view, offset);
  offset += 4;
  expectEnd(view, offset);
  return { convId, values, hasMore, correlationId };
}

function decodeTaskQueryPage(view) {
  let offset = 2;
  const convId = u64(view, offset);
  offset += 8;
  const success = flag(view, offset);
  offset += 1;
  const count = u16(view, offset);
  offset += 2;
  if (count > MAX_TASK_PAGE_SIZE) throw new ProtocolError("too many tasks in query page");
  const tasks = [];
  for (let i = 0; i < count; i += 1) {
    const parsed = parseTask(view, offset);
    tasks.push(parsed.task);
    offset = parsed.newOffset;
  }
  const hasMore = flag(view, offset);
  offset += 1;
  if (hasMore && count === 0) throw new ProtocolError("empty task query page claims more");
  const nextCursorNumber = i64(view, offset);
  offset += 8;
  const nextCursorTaskId = u64(view, offset);
  offset += 8;
  const cursorText = exactWireString(view, offset);
  offset = cursorText.newOffset;
  const totalCount = u32(view, offset);
  offset += 4;
  const error = exactWireString(view, offset);
  offset = error.newOffset;
  const correlationId = u32(view, offset);
  offset += 4;
  expectEnd(view, offset);
  return {
    convId,
    success,
    tasks,
    hasMore,
    nextCursorNumber,
    nextCursorTaskId,
    nextCursorText: cursorText.value,
    totalCount,
    error: error.value,
    correlationId,
  };
}

function decodeTaskDependentsPage(view) {
  let offset = 2;
  const convId = u64(view, offset);
  offset += 8;
  const taskId = u64(view, offset);
  offset += 8;
  const success = flag(view, offset);
  offset += 1;
  const count = u16(view, offset);
  offset += 2;
  if (count > MAX_TASK_PAGE_SIZE) throw new ProtocolError("too many task dependents");
  const tasks = [];
  let lastTaskId = 0n;
  for (let i = 0; i < count; i += 1) {
    const parsed = parseTask(view, offset);
    if (parsed.task.id <= lastTaskId) throw new ProtocolError("task dependents must have ascending IDs");
    lastTaskId = parsed.task.id;
    tasks.push(parsed.task);
    offset = parsed.newOffset;
  }
  const hasMore = flag(view, offset);
  offset += 1;
  const nextTaskId = u64(view, offset);
  offset += 8;
  const error = wireString(view, offset);
  offset = error.newOffset;
  const correlationId = u32(view, offset);
  offset += 4;
  expectEnd(view, offset);
  if (hasMore && count === 0) throw new ProtocolError("empty dependent page claims more");
  if (nextTaskId !== lastTaskId) throw new ProtocolError("dependent cursor mismatch");
  return {
    convId,
    taskId,
    success,
    tasks,
    hasMore,
    nextTaskId,
    error: error.value,
    correlationId,
  };
}

function decodeTaskSliceList(view) {
  let offset = 2;
  const roomId = u64(view, offset);
  offset += 8;
  const success = flag(view, offset);
  offset += 1;
  const count = u16(view, offset);
  offset += 2;
  if (count > 512) throw new ProtocolError("too many task slices");
  const slices = [];
  for (let i = 0; i < count; i += 1) {
    const name = exactWireString(view, offset);
    offset = name.newOffset;
    const sliceId = u64(view, offset);
    offset += 8;
    const owner = exactWireString(view, offset);
    offset = owner.newOffset;
    const flags = u8(view, offset);
    offset += 1;
    const backlog = u16(view, offset);
    offset += 2;
    const todo = u16(view, offset);
    offset += 2;
    const inProgress = u16(view, offset);
    offset += 2;
    const done = u16(view, offset);
    offset += 2;
    const blocked = u16(view, offset);
    offset += 2;
    const notes = u16(view, offset);
    offset += 2;
    const files = u16(view, offset);
    offset += 2;
    const tickets = u16(view, offset);
    offset += 2;
    const oldestActiveAt = i64(view, offset);
    offset += 8;
    const lastMovedAt = i64(view, offset);
    offset += 8;
    slices.push({
      name: name.value,
      sliceId,
      owner: owner.value,
      flags,
      backlog,
      todo,
      inProgress,
      done,
      blocked,
      notes,
      files,
      tickets,
      oldestActiveAt,
      lastMovedAt,
    });
  }
  const hasMore = flag(view, offset);
  offset += 1;
  const cursorClosed = flag(view, offset);
  offset += 1;
  const cursorSortAt = i64(view, offset);
  offset += 8;
  const cursorSliceId = u64(view, offset);
  offset += 8;
  const total = u32(view, offset);
  offset += 4;
  const assignedTasks = u32(view, offset);
  offset += 4;
  const unassignedTasks = u32(view, offset);
  offset += 4;
  const error = exactWireString(view, offset);
  offset = error.newOffset;
  const correlationId = u32(view, offset);
  offset += 4;
  expectEnd(view, offset);
  return {
    roomId,
    success,
    slices,
    hasMore,
    cursor: hasMore
      ? { closed: cursorClosed, sortAt: cursorSortAt, sliceId: cursorSliceId }
      : null,
    total,
    assignedTasks,
    unassignedTasks,
    error: error.value,
    correlationId,
  };
}

function decodeTransactionResult(view) {
  const version = u8(view, 2);
  const status = u8(view, 3);
  const correlationId = u32(view, 4);
  const failedOperation = u16(view, 8);
  const count = u16(view, 10);
  if (version !== 1) throw new ProtocolError("unsupported transaction result version");
  if (status > 1) throw new ProtocolError("invalid transaction result status");
  if (count > 256) throw new ProtocolError("too many transaction results");
  let offset = 12;
  const operations = [];
  for (let i = 0; i < count; i += 1) {
    const type = u8(view, offset);
    offset += 1;
    if (u8(view, offset) !== 0) throw new ProtocolError("reserved transaction result byte");
    offset += 1;
    const entityId = u64(view, offset);
    offset += 8;
    operations.push({ type, entityId });
  }
  expectEnd(view, offset);
  return { version, status, correlationId, failedOperation, operations };
}

function decodeCalendarPage(view) {
  let offset = 2;
  const roomId = u64(view, offset);
  offset += 8;
  const count = u16(view, offset);
  offset += 2;
  if (count > 100) throw new ProtocolError("too many calendar rows");
  const more = flag(view, offset);
  offset += 1;
  const cursor = { at: i64(view, offset), kind: u8(view, offset + 8), id: u64(view, offset + 9) };
  offset += 17;
  const rows = [];
  for (let i = 0; i < count; i += 1) {
    const kind = u8(view, offset);
    offset += 1;
    if (kind > 3) throw new ProtocolError("invalid calendar row kind");
    const id = u64(view, offset);
    offset += 8;
    const at = i64(view, offset);
    offset += 8;
    const blocked = flag(view, offset);
    offset += 1;
    const title = exactWireString(view, offset);
    offset = title.newOffset;
    const assignee = exactWireString(view, offset);
    offset = assignee.newOffset;
    const project = exactWireString(view, offset);
    offset = project.newOffset;
    let actualStartAt = at;
    let endAt = 0n;
    if (kind >= 2) {
      actualStartAt = i64(view, offset);
      offset += 8;
      endAt = i64(view, offset);
      offset += 8;
    }
    let occurrenceAt = actualStartAt;
    if (kind === 3) {
      occurrenceAt = i64(view, offset);
      offset += 8;
    }
    rows.push({
      kind,
      id,
      at,
      blocked,
      title: title.value,
      assignee: assignee.value,
      project: project.value,
      actualStartAt,
      endAt,
      occurrenceAt,
    });
  }
  const correlationId = u32(view, offset);
  offset += 4;
  expectEnd(view, offset);
  return { roomId, rows, more, cursor, correlationId };
}

function decodeWorkspaceOverview(view) {
  let offset = 2;
  const convId = u64(view, offset);
  offset += 8;
  const success = flag(view, offset);
  offset += 1;
  const sampledAt = i64(view, offset);
  offset += 8;
  const counts = (length) => {
    const values = [];
    for (let i = 0; i < length; i += 1) {
      values.push(u32(view, offset));
      offset += 4;
    }
    return values;
  };
  const statusCounts = counts(4);
  const assignedTasks = u32(view, offset);
  offset += 4;
  const unassignedTasks = u32(view, offset);
  offset += 4;
  const openSlices = u32(view, offset);
  offset += 4;
  const sizeBuckets = counts(5);
  const blockedBuckets = counts(3);
  const ageBuckets = counts(5);
  const error = wireString(view, offset);
  offset = error.newOffset;
  const correlationId = u32(view, offset);
  offset += 4;
  expectEnd(view, offset);
  return {
    convId,
    success,
    sampledAt,
    statusCounts,
    assignedTasks,
    unassignedTasks,
    openSlices,
    sizeBuckets,
    blockedBuckets,
    ageBuckets,
    error: error.value,
    correlationId,
  };
}

function decodeHistoryPage(view) {
  const correlationId = u32(view, 2);
  const length = view.byteLength - 6;
  const page = text(view, 6, length);
  let parsed;
  try {
    parsed = JSON.parse(page);
  } catch {
    throw new ProtocolError("invalid history page JSON");
  }
  return { correlationId, page: parsed };
}

function decodeTicketPage(view) {
  const correlationId = u32(view, 2);
  const length = u32(view, 6);
  const metadata = text(view, 10, length);
  let offset = 10 + length;
  const count = u16(view, offset);
  offset += 2;
  const fullContent = flag(view, offset);
  offset += 1;
  const assets = [];
  for (let i = 0; i < count; i += 1) {
    const parsed = fullContent
      ? parseFullAsset(view, offset)
      : parseAsset(view, offset, true);
    assets.push(parsed.asset);
    offset = parsed.newOffset;
  }
  expectEnd(view, offset);
  let page;
  try {
    page = JSON.parse(metadata);
  } catch {
    throw new ProtocolError("invalid ticket page JSON");
  }
  return { correlationId, page, count, fullContent, assets };
}

function decodeCustomerSearchPage(view) {
  let offset = 2;
  const convId = u64(view, offset);
  offset += 8;
  const hasMore = flag(view, offset);
  offset += 1;
  const nextCompanyId = u64(view, offset);
  offset += 8;
  const totalCount = u32(view, offset);
  offset += 4;
  const count = u16(view, offset);
  offset += 2;
  const correlationId = u32(view, offset);
  offset += 4;
  const assets = [];
  for (let i = 0; i < count; i += 1) {
    const parsed = parseAsset(view, offset, true);
    assets.push(parsed.asset);
    offset = parsed.newOffset;
  }
  expectEnd(view, offset);
  return {
    convId,
    hasMore,
    nextCompanyId,
    totalCount,
    count,
    assets,
    correlationId,
  };
}

function decodeEdgeListPage(view) {
  let offset = 2;
  const convId = u64(view, offset);
  offset += 8;
  const targetType = u16(view, offset);
  offset += 2;
  const targetId = u64(view, offset);
  offset += 8;
  const hasMore = flag(view, offset);
  offset += 1;
  const nextEdgeId = u64(view, offset);
  offset += 8;
  const totalCount = u32(view, offset);
  offset += 4;
  const count = u16(view, offset);
  offset += 2;
  const correlationId = u32(view, offset);
  offset += 4;
  const edges = [];
  for (let i = 0; i < count; i += 1) {
    const parsed = parseEdge(view, offset);
    edges.push(parsed.edge);
    offset = parsed.newOffset;
  }
  expectEnd(view, offset);
  return {
    convId,
    targetType,
    targetId,
    hasMore,
    nextEdgeId,
    totalCount,
    edges,
    correlationId,
  };
}

// ---------------------------------------------------------------------------
// Server frame dispatch
// ---------------------------------------------------------------------------

const SUPPORTED_OPCODES = Object.freeze([
  100, 102, 103, 104, 109, // handshake, chat, error, presence
  121, 122, 123, 124, 125, 126, 127, // direct messages, pong, unsubscribe ack
  130, 131, 132, 133, 134, 135, 136, // tasks
  137, 138, 139, // transaction result, task query, task projects
  140, 141, 142, 143, 144, 145, 146, 147, // assets
  150, 151, 152, 153, 154, 155, 156, 157, // edges and graph results
  158, 159, // retained messages
  161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, // pages and lists
]);

function decodeServerFrame(view) {
  if (view.byteLength < 2) throw new ProtocolError("frame too short");
  const opcode = u16(view, 0);
  let offset = 2;

  switch (opcode) {
    case 130: { // S_TaskCreated
      const parsed = parseTask(view, offset);
      const correlationId = u32(view, parsed.newOffset);
      expectEnd(view, parsed.newOffset + 4);
      return { opcode, kind: "task_created", task: parsed.task, correlationId };
    }
    case 131: { // S_TaskUpdated
      const parsed = parseTask(view, offset);
      const correlationId = u32(view, parsed.newOffset);
      expectEnd(view, parsed.newOffset + 4);
      return { opcode, kind: "task_updated", task: parsed.task, correlationId };
    }
    case 132: { // S_TaskDeleted
      const taskId = u64(view, offset);
      offset += 8;
      const convId = u64(view, offset);
      offset += 8;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return { opcode, kind: "task_deleted", taskId, convId, correlationId };
    }
    case 133: { // S_TaskMoved
      const taskId = u64(view, offset);
      offset += 8;
      const convId = u64(view, offset);
      offset += 8;
      const status = u8(view, offset);
      offset += 1;
      const orderIndex = u16(view, offset);
      offset += 2;
      const completedAt = i64(view, offset);
      offset += 8;
      const completedBy = wireString(view, offset);
      offset = completedBy.newOffset;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return {
        opcode,
        kind: "task_moved",
        taskId,
        convId,
        status,
        orderIndex,
        completedAt,
        completedBy: completedBy.value,
        correlationId,
      };
    }
    case 134: { // S_TaskListResponse
      const convId = u64(view, offset);
      offset += 8;
      const success = flag(view, offset);
      offset += 1;
      const count = u16(view, offset);
      offset += 2;
      const parsed = parseTaskList(view, offset, count);
      offset = parsed.newOffset;
      const error = wireString(view, offset);
      offset = error.newOffset;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return {
        opcode,
        kind: "task_list",
        convId,
        success,
        tasks: parsed.tasks,
        error: error.value,
        correlationId,
      };
    }
    case 135: { // S_TaskListPage
      const convId = u64(view, offset);
      offset += 8;
      const success = flag(view, offset);
      offset += 1;
      const count = u16(view, offset);
      offset += 2;
      if (count > MAX_TASK_PAGE_SIZE) throw new ProtocolError("too many tasks in page");
      const parsed = parseTaskList(view, offset, count);
      offset = parsed.newOffset;
      const hasMore = flag(view, offset);
      offset += 1;
      const nextCursorSortAt = i64(view, offset);
      offset += 8;
      const nextCursorTaskId = u64(view, offset);
      offset += 8;
      const totalCount = u32(view, offset);
      offset += 4;
      const error = wireString(view, offset);
      offset = error.newOffset;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return {
        opcode,
        kind: "task_page",
        convId,
        success,
        tasks: parsed.tasks,
        hasMore,
        nextCursorSortAt,
        nextCursorTaskId,
        totalCount,
        error: error.value,
        correlationId,
      };
    }
    case 136: { // S_TaskFull
      const convId = u64(view, offset);
      offset += 8;
      const success = flag(view, offset);
      offset += 1;
      const hasTask = flag(view, offset);
      offset += 1;
      let task = null;
      if (hasTask) {
        const parsed = parseTask(view, offset);
        task = parsed.task;
        offset = parsed.newOffset;
      }
      const error = wireString(view, offset);
      offset = error.newOffset;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return {
        opcode,
        kind: "task_full",
        convId,
        success,
        hasTask,
        task,
        error: error.value,
        correlationId,
      };
    }

    case 140: // S_AssetCreated
    case 141: // S_AssetUpdated
    case 143: { // S_AssetFull
      const parsed = parseFullAsset(view, offset);
      const correlationId = u32(view, parsed.newOffset);
      expectEnd(view, parsed.newOffset + 4);
      return {
        opcode,
        kind: opcode === 140 ? "asset_created" : opcode === 141 ? "asset_updated" : "asset_full",
        asset: parsed.asset,
        correlationId,
      };
    }
    case 142: { // S_AssetDeleted
      const convId = u64(view, offset);
      offset += 8;
      const assetId = u64(view, offset);
      offset += 8;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return { opcode, kind: "asset_deleted", convId, assetId, correlationId };
    }
    case 144: { // S_AssetList
      const convId = u64(view, offset);
      offset += 8;
      const fullContent = flag(view, offset);
      offset += 1;
      const count = u16(view, offset);
      offset += 2;
      const correlationId = u32(view, offset);
      offset += 4;
      const assets = [];
      for (let i = 0; i < count; i += 1) {
        const parsed = fullContent
          ? parseFullAsset(view, offset)
          : parseAsset(view, offset, true);
        assets.push(parsed.asset);
        offset = parsed.newOffset;
      }
      expectEnd(view, offset);
      return { opcode, kind: "asset_list", convId, fullContent, count, assets, correlationId };
    }
    case 145: { // S_AssetListPage
      const convId = u64(view, offset);
      offset += 8;
      const fullContent = flag(view, offset);
      offset += 1;
      const hasMore = flag(view, offset);
      offset += 1;
      const nextCursorUpdatedAt = i64(view, offset);
      offset += 8;
      const nextCursorAssetId = u64(view, offset);
      offset += 8;
      const totalCount = u32(view, offset);
      offset += 4;
      const count = u16(view, offset);
      offset += 2;
      const correlationId = u32(view, offset);
      offset += 4;
      const assets = [];
      for (let i = 0; i < count; i += 1) {
        const parsed = fullContent
          ? parseFullAsset(view, offset)
          : parseAsset(view, offset, true);
        assets.push(parsed.asset);
        offset = parsed.newOffset;
      }
      expectEnd(view, offset);
      return {
        opcode,
        kind: "asset_page",
        convId,
        fullContent,
        hasMore,
        nextCursorUpdatedAt,
        nextCursorAssetId,
        totalCount,
        count,
        assets,
        correlationId,
      };
    }
    case 146: // S_NoteProjectList
    case 147: { // S_NoteTagList
      const convId = u64(view, offset);
      offset += 8;
      const count = u16(view, offset);
      offset += 2;
      const correlationId = u32(view, offset);
      offset += 4;
      const values = [];
      for (let i = 0; i < count; i += 1) {
        const value = wireString(view, offset);
        values.push(value.value);
        offset = value.newOffset;
      }
      expectEnd(view, offset);
      return {
        opcode,
        kind: opcode === 146 ? "note_projects" : "note_tags",
        convId,
        count,
        values,
        correlationId,
      };
    }

    case 150: { // S_EdgeCreated
      const parsed = parseEdge(view, offset);
      const correlationId = u32(view, parsed.newOffset);
      expectEnd(view, parsed.newOffset + 4);
      return { opcode, kind: "edge_created", edge: parsed.edge, correlationId };
    }
    case 151: { // S_EdgeDeleted
      const convId = u64(view, offset);
      offset += 8;
      const edgeId = u64(view, offset);
      offset += 8;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return { opcode, kind: "edge_deleted", convId, edgeId, correlationId };
    }
    case 152: { // S_EdgeList
      const convId = u64(view, offset);
      offset += 8;
      const targetType = u16(view, offset);
      offset += 2;
      const targetId = u64(view, offset);
      offset += 8;
      const count = u16(view, offset);
      offset += 2;
      const parsed = parseEdgeList(view, offset, count);
      offset = parsed.newOffset;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return {
        opcode,
        kind: "edge_list",
        convId,
        targetType,
        targetId,
        edges: parsed.edges,
        correlationId,
      };
    }
    case 153: { // S_AllEdgeList
      const convId = u64(view, offset);
      offset += 8;
      const count = u32(view, offset);
      offset += 4;
      const parsed = parseEdgeList(view, offset, count);
      offset = parsed.newOffset;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return { opcode, kind: "all_edge_list", convId, edges: parsed.edges, correlationId };
    }
    case 154: { // S_GraphQueryResult
      const convId = u64(view, offset);
      offset += 8;
      const startType = u16(view, offset);
      offset += 2;
      const startId = u64(view, offset);
      offset += 8;
      const truncated = flag(view, offset);
      offset += 1;
      const nodeCount = u16(view, offset);
      offset += 2;
      const nodes = parseNodes(view, offset, nodeCount, true);
      offset = nodes.newOffset;
      const edgeCount = u16(view, offset);
      offset += 2;
      const edges = parseEdgeList(view, offset, edgeCount);
      offset = edges.newOffset;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return {
        opcode,
        kind: "graph_query",
        convId,
        startType,
        startId,
        truncated,
        nodes: nodes.nodes,
        edges: edges.edges,
        correlationId,
      };
    }
    case 155: { // S_GraphShortestPathResult
      const convId = u64(view, offset);
      offset += 8;
      const fromType = u16(view, offset);
      offset += 2;
      const fromId = u64(view, offset);
      offset += 8;
      const toType = u16(view, offset);
      offset += 2;
      const toId = u64(view, offset);
      offset += 8;
      const found = flag(view, offset);
      offset += 1;
      const pathLength = u8(view, offset);
      offset += 1;
      const nodeCount = u16(view, offset);
      offset += 2;
      const nodes = parseNodes(view, offset, nodeCount, false);
      offset = nodes.newOffset;
      const edgeCount = u16(view, offset);
      offset += 2;
      const edges = parseEdgeList(view, offset, edgeCount);
      offset = edges.newOffset;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return {
        opcode,
        kind: "graph_path",
        convId,
        fromType,
        fromId,
        toType,
        toId,
        found,
        pathLength,
        nodes: nodes.nodes,
        edges: edges.edges,
        correlationId,
      };
    }
    case 156: { // S_GraphDegreeResult
      const convId = u64(view, offset);
      offset += 8;
      const count = u16(view, offset);
      offset += 2;
      const entries = [];
      for (let i = 0; i < count; i += 1) {
        const type = u16(view, offset);
        offset += 2;
        const id = u64(view, offset);
        offset += 8;
        const degree = u16(view, offset);
        offset += 2;
        entries.push({ type, id, degree });
      }
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return { opcode, kind: "graph_degree", convId, entries, correlationId };
    }
    case 157: { // S_GraphCommonNeighborsResult
      const convId = u64(view, offset);
      offset += 8;
      const aType = u16(view, offset);
      offset += 2;
      const aId = u64(view, offset);
      offset += 8;
      const bType = u16(view, offset);
      offset += 2;
      const bId = u64(view, offset);
      offset += 8;
      const nodeCount = u16(view, offset);
      offset += 2;
      const nodes = parseNodes(view, offset, nodeCount, false);
      offset = nodes.newOffset;
      const edgeCount = u16(view, offset);
      offset += 2;
      const edges = parseEdgeList(view, offset, edgeCount);
      offset = edges.newOffset;
      const correlationId = u32(view, offset);
      expectEnd(view, offset + 4);
      return {
        opcode,
        kind: "graph_common",
        convId,
        aType,
        aId,
        bType,
        bId,
        nodes: nodes.nodes,
        edges: edges.edges,
        correlationId,
      };
    }

    case 158: { // S_SubscriptionReady
      const value = retainedCodec().parseSubscriptionReady(view);
      return { opcode, kind: "subscription_ready", value };
    }
    case 159: { // S_MessagePage
      const value = retainedCodec().parseMessagePage(view);
      return { opcode, kind: "message_page", value };
    }

    case 161: { // S_AllEdgeListPage
      const convId = u64(view, offset);
      offset += 8;
      const hasMore = flag(view, offset);
      offset += 1;
      const nextEdgeId = u64(view, offset);
      offset += 8;
      const totalCount = u32(view, offset);
      offset += 4;
      const count = u16(view, offset);
      offset += 2;
      const correlationId = u32(view, offset);
      offset += 4;
      const parsed = parseEdgeList(view, offset, count);
      expectEnd(view, parsed.newOffset);
      return {
        opcode,
        kind: "all_edge_page",
        convId,
        hasMore,
        nextEdgeId,
        totalCount,
        edges: parsed.edges,
        correlationId,
      };
    }
    case 162: // S_EdgeListPage
      return { opcode, kind: "edge_page", ...decodeEdgeListPage(view) };

    case 100: // S_ServerReady
      return { opcode, kind: "server_ready", ...decodeServerReady(view) };
    case 102: // S_NewMessage
      return { opcode, kind: "new_message", ...decodeNewMessage(view) };
    case 103: // S_AckSendMessage
      return { opcode, kind: "ack_send_message", ...decodeAckSendMessage(view) };
    case 104: // S_ErrorResponse
      return { opcode, kind: "error_response", ...decodeErrorResponse(view) };
    case 109: // S_RoomPresenceUpdate
      return { opcode, kind: "room_presence", ...decodeRoomPresenceUpdate(view) };
    case 121: // S_DMStarted
      return { opcode, kind: "dm_started", ...decodeDMStarted(view) };
    case 122: // S_DMList
      return { opcode, kind: "dm_list", ...decodeDMList(view) };
    case 123: // S_DMError
      return { opcode, kind: "dm_error", ...decodeDMError(view) };
    case 124: // S_DMLeft
      return { opcode, kind: "dm_left", ...decodeDMLeft(view) };
    case 125: // S_DMPartnerStatus
      return { opcode, kind: "dm_partner_status", ...decodeDMPartnerStatus(view) };
    case 126: // S_Pong
      return { opcode, kind: "pong", ...decodePongResponse(view) };
    case 127: // S_AckUnsubscribeConvs
      return { opcode, kind: "ack_unsubscribe", ...decodeAckUnsubscribeConvs(view) };
    case 137: // S_TransactionResult
      return { opcode, kind: "transaction_result", ...decodeTransactionResult(view) };
    case 138: // S_TaskQueryPage
      return { opcode, kind: "task_query_page", ...decodeTaskQueryPage(view) };
    case 139: // S_TaskProjects
      return { opcode, kind: "task_projects", ...decodeStringList(view) };
    case 163: // S_CustomerSearchPage
      return { opcode, kind: "customer_search_page", ...decodeCustomerSearchPage(view) };
    case 164: // S_TaskSliceList
      return { opcode, kind: "task_slice_list", ...decodeTaskSliceList(view) };
    case 165: // S_TaskAssignees
      return { opcode, kind: "task_assignees", ...decodeStringList(view) };
    case 166: // S_CalendarPage
      return { opcode, kind: "calendar_page", ...decodeCalendarPage(view) };
    case 167: // S_WorkspaceOverview
      return { opcode, kind: "workspace_overview", ...decodeWorkspaceOverview(view) };
    case 168: // S_HistoryPage
      return { opcode, kind: "history_page", ...decodeHistoryPage(view) };
    case 169: // S_TicketPage
      return { opcode, kind: "ticket_page", ...decodeTicketPage(view) };
    case 170: // S_TaskDependentsPage
      return { opcode, kind: "task_dependents_page", ...decodeTaskDependentsPage(view) };
    case 171: // S_SliceOwners
      return { opcode, kind: "slice_owners", ...decodeStringList(view) };
    case 172: // S_TicketAssignees
      return { opcode, kind: "ticket_assignees", ...decodeStringList(view) };
    case 173: // S_CalendarPeople
      return { opcode, kind: "calendar_people", ...decodeStringList(view) };
    default:
      return null;
  }
}

  return {
    ProtocolError,
    SUPPORTED_OPCODES,
    decodeServerFrame,
    decodeServerReady,
    decodeNewMessage,
    decodeAckSendMessage,
    decodeErrorResponse,
    decodeRoomPresenceUpdate,
    decodePongResponse,
    decodeAckUnsubscribeConvs,
    decodeDMStarted,
    decodeDMList,
    decodeDMError,
    decodeDMLeft,
    decodeDMPartnerStatus,
    decodeStringList,
    decodeTaskQueryPage,
    decodeTaskDependentsPage,
    decodeTaskSliceList,
    decodeTransactionResult,
    decodeCalendarPage,
    decodeWorkspaceOverview,
    decodeHistoryPage,
    decodeTicketPage,
    decodeCustomerSearchPage,
    decodeEdgeListPage,
  };
});
