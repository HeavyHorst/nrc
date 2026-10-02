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
