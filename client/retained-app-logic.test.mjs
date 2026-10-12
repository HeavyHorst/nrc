import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const appSource = readFileSync(new URL("app.js", import.meta.url), "utf8");

function extractFunction(name) {
  const start = appSource.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  const bodyStart = appSource.indexOf("{", start);
  let depth = 0;
  for (let index = bodyStart; index < appSource.length; index++) {
    if (appSource[index] === "{") depth++;
    if (appSource[index] === "}" && --depth === 0) return appSource.slice(start, index + 1);
  }
  throw new Error(`unterminated ${name}`);
}

test("mixed retained and legacy records use a transitive timestamp-first order", () => {
  const context = {};
  vm.runInNewContext(`${extractFunction("sortRoomMessages")}; this.sortRoomMessages = sortRoomMessages;`, context);
  const records = [
    { timestamp: 2, retained: true, sequence: 8n },
    { timestamp: 1, retained: false, sequence: 8n },
    { timestamp: 2, retained: true, sequence: 7n },
    { timestamp: 2, retained: false, sequence: 1n },
  ];
  context.sortRoomMessages(records);
  assert.deepEqual(records.map((record) => [record.timestamp, record.retained, record.sequence]), [
    [1, false, 8n],
    [2, true, 7n],
    [2, true, 8n],
    [2, false, 1n],
  ]);
});

test("room sends wait for an explicit retention decision and disabled rooms use legacy", () => {
  const sent = [];
  const errors = [];
  const context = {
    TextEncoder,
    MAX_MESSAGE_CONTENT_BYTES: 50 * 1024,
    clientRequestIdCounter: 1,
    currentRoomId: 2n,
    retainedRoomStates: new Map(),
    isDMConversation: () => false,
    logMessage: (_type, message) => errors.push(message),
    Opcode: { C_SendMessage: 1 },
    ContentType: { PlainText: 0 },
    sendPacket: (buffer) => sent.push(buffer),
    window: {},
  };
  vm.runInNewContext(`${extractFunction("sendRawProtocolMessage")}; this.sendRawProtocolMessage = sendRawProtocolMessage;`, context);

  assert.equal(context.sendRawProtocolMessage("wait"), false);
  assert.equal(sent.length, 0);
  assert.match(errors[0], /INITIALIZING/);

  context.retainedRoomStates.set(2n, "disabled");
  const result = context.sendRawProtocolMessage("legacy");
  assert.equal(result.retained, false);
  assert.equal(new DataView(sent[0]).getUint16(0, false), 1);
});

function retainedSession() {
  let now = 1000;
  const sent = [], errors = [];
  const context = {
    TextEncoder, TextDecoder,
    Date: { now: () => now },
    Math: Object.assign(Object.create(Math), { random: () => 0 }),
    console: { log() {}, warn() {}, error() {} },
    MAX_MESSAGE_CONTENT_BYTES: 50 * 1024,
    MAX_RETAINED_OPERATIONS_IN_FLIGHT: 1,
    MAX_PENDING_RETAINED_SENDS: 256,
    MAX_RETAINED_SEND_ATTEMPTS: 32,
    RETAINED_SEND_RETRY_BUDGET: 30000,
    clientRequestIdCounter: 0,
    currentRoomId: 2n,
    ws: { readyState: 1 }, WebSocket: { OPEN: 1 },
    retainedRoomStates: new Map([[2n, "enabled"]]),
    retainedOperations: new Map(), retainedSendAttempts: new Map(),
    retainedOperationQueue: [], pendingMessages: new Map(),
    retainedSubscriptionRequests: new Map(), retainedHistoryRequests: new Map(),
    retainedHistoryStarted: new Set(), roomHistory: new Map(),
    retransmitCount: 0, retransmitHistory: [], lastAckTime: 0,
    isDMConversation: () => false,
    isConversationVisible: () => false,
    sortRoomMessages() {},
    dispatchCentralizedErrorResponse: () => false,
    logMessage: (_type, message) => errors.push(message),
    Opcode: { C_SendMessage: 1, C_SendMessageV2: 48 },
    ContentType: { PlainText: 0 },
    sendPacket: (buffer) => sent.push(buffer.slice(0)),
    window: {},
    globalThis: { crypto: { getRandomValues: (id) => { id.fill(7); return id; } } },
  };
  vm.runInNewContext(readFileSync(new URL("retained-messages.js", import.meta.url), "utf8"), context);
  vm.runInNewContext([
    "sendRawProtocolMessage", "queuePendingRetainedSend", "finishPendingRetainedSend",
    "drainRetainedOperationQueue", "queueRetainedOperation", "completeRetainedOperation",
    "checkRetransmissions", "requeuePendingRetainedMessages", "parseErrorResponse", "parseAckSendMessage",
  ].map(extractFunction).join("\n"), context);
  return { context, sent, errors, advance: (ms) => { now += ms; } };
}

function sendError(context, correlation, text, origin = 48) {
  const bytes = new TextEncoder().encode(text);
  const view = new DataView(new ArrayBuffer(10 + bytes.length));
  view.setUint16(2, origin);
  view.setUint16(4, bytes.length);
  new Uint8Array(view.buffer, 6, bytes.length).set(bytes);
  view.setUint32(6 + bytes.length, correlation);
  context.parseErrorResponse(view);
}

function sendAck(context, correlation) {
  const view = new DataView(new ArrayBuffer(22));
  view.setUint32(2, correlation);
  view.setBigUint64(6, 91n);
  view.setBigInt64(14, 1000000000n);
  context.parseAckSendMessage(view);
}

test("retained overload backoff has one owner, fresh correlations and a valid late ACK", () => {
  for (const text of ["retained_send_overloaded", "too many retained message operations", "too many retained message sends"]) {
    const { context: c, sent, advance } = retainedSession();
    const first = c.sendRawProtocolMessage("same ID and bytes");
    sendError(c, first.clientReqId, text);
    c.requeuePendingRetainedMessages(2n);
    advance(49);
    c.checkRetransmissions();
    assert.equal(sent.length, 1, "error, tick and subscription must not bypass backoff");
    advance(1);
    c.checkRetransmissions();
    assert.equal(sent.length, 2);
    const attempt = new DataView(sent[1]).getUint32(26);
    assert.notEqual(attempt, first.clientReqId);
    const retryBytes = new Uint8Array(sent[1].slice(0));
    new DataView(retryBytes.buffer).setUint32(26, first.clientReqId);
    assert.deepEqual(retryBytes, new Uint8Array(sent[0]), "only correlation may change");
    sendError(c, first.clientReqId, "retained message storage failed");
    assert.ok(c.pendingMessages.has(first.clientReqId), "stale error cannot cancel a newer attempt");
    const second = c.sendRawProtocolMessage("another logical message");
    assert.notEqual(second.clientReqId, attempt, "new sends cannot reuse a retry correlation");
    sendAck(c, first.clientReqId);
    assert.equal(c.pendingMessages.size, 1);
    assert.ok(c.pendingMessages.has(second.clientReqId));
    assert.equal(sent.length, 3, "late ACK drains other queued work, not a duplicate retry");
    sendAck(c, second.clientReqId);
    assert.equal(c.pendingMessages.size, 0);
    assert.equal(c.retainedSendAttempts.size, 0);
    assert.equal(c.retainedOperations.size, 0);
    assert.equal(c.retainedOperationQueue.length, 0);
  }
});

test("late ACK cancels an unsent timeout retry behind history", () => {
  const { context: c, sent, advance } = retainedSession();
  const first = c.sendRawProtocolMessage("late ACK");
  c.queueRetainedOperation(123, "history", new ArrayBuffer(2));
  advance(5000);
  c.checkRetransmissions();
  assert.equal(sent.length, 2, "history obtains the released scheduling slot");
  assert.equal(c.retainedOperationQueue.length, 1);
  sendAck(c, first.clientReqId);
  c.completeRetainedOperation(123);
  assert.equal(sent.length, 2, "queued retry must be cancelled before draining");
  assert.equal(c.pendingMessages.size, 0);
  assert.equal(c.retainedSendAttempts.size, 0);
});

test("retained retry budget survives disconnect/requeue and expires offline", () => {
  const { context: c, sent, errors, advance } = retainedSession();
  const first = c.sendRawProtocolMessage("uncertain");
  const pending = c.pendingMessages.get(first.clientReqId);
  const firstSentAt = pending.firstSentAt;
  advance(10000);
  c.ws.readyState = 3;
  c.retainedOperations.clear();
  c.retainedOperationQueue = [];
  pending.timestamp = Infinity;
  pending.queued = false;
  pending.attemptCorrelationId = null;
  c.ws.readyState = 1;
  c.requeuePendingRetainedMessages(2n);
  assert.equal(sent.length, 2);
  assert.equal(pending.firstSentAt, firstSentAt);
  c.ws.readyState = 3;
  advance(20000);
  c.checkRetransmissions();
  c.ws.readyState = 1;
  c.requeuePendingRetainedMessages(2n);
  assert.equal(sent.length, 2);
  assert.equal(c.pendingMessages.size, 0);
  assert.equal(c.retainedSendAttempts.size, 0);
  assert.match(errors.at(-1), /UNCONFIRMED/);
});

test("retained state and attempt aliases are bounded, and storage errors do not retry", () => {
  const { context: c, sent, errors, advance } = retainedSession();
  const first = c.sendRawProtocolMessage("storage failure");
  sendError(c, first.clientReqId, "retained message storage failed");
  advance(5000);
  c.checkRetransmissions();
  assert.equal(sent.length, 1);
  assert.equal(c.pendingMessages.size, 0);
  assert.match(errors[0], /storage failed/);
  for (let i = 0; i < 256; i++) assert.ok(c.sendRawProtocolMessage("bounded"));
  assert.equal(c.sendRawProtocolMessage("too many"), false);
  assert.equal(c.pendingMessages.size, 256);

  const session = retainedSession();
  const id = session.context.sendRawProtocolMessage("reconnect flood").clientReqId;
  const pending = session.context.pendingMessages.get(id);
  for (let i = 0; i < 40; i++) {
    session.context.retainedOperations.clear();
    pending.attemptCorrelationId = null;
    session.context.requeuePendingRetainedMessages(2n);
  }
  assert.equal(session.sent.length, 32);
  assert.equal(session.context.retainedSendAttempts.size, 32);
});
