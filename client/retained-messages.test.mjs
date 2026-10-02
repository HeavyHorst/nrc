import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("retained-messages.js", import.meta.url), "utf8");

function loadCodec(crypto = globalThis.crypto) {
  const window = {};
  vm.runInNewContext(source, { window, globalThis: { crypto }, TextDecoder, Uint8Array, ArrayBuffer, DataView, BigInt });
  return window.NRCRetainedMessages;
}

test("retained send and subscription encoders match the server wire format", () => {
  const codec = loadCodec();
  const id = Uint8Array.from({ length: 16 }, (_, index) => index + 1);
  const content = new TextEncoder().encode("hello");
  const send = codec.encodeSendMessage(48, 9n, id, 0x01020304, 0, content);
  const sendView = new DataView(send);

  assert.equal(send.byteLength, 38);
  assert.equal(sendView.getUint16(0, false), 48);
  assert.equal(sendView.getBigUint64(2, false), 9n);
  assert.deepEqual(Array.from(new Uint8Array(send, 10, 16)), Array.from(id));
  assert.equal(sendView.getUint32(26, false), 0x01020304);
  assert.equal(sendView.getUint8(30), 0);
  assert.equal(sendView.getUint16(31, false), 5);
  assert.equal(new TextDecoder().decode(new Uint8Array(send, 33)), "hello");

  const subscribe = codec.encodeSubscribe(49, [2n, 3n], 17);
  const subscribeView = new DataView(subscribe);
  assert.equal(subscribe.byteLength, 24);
  assert.equal(subscribeView.getUint16(0, false), 49);
  assert.equal(subscribeView.getUint16(2, false), 2);
  assert.equal(subscribeView.getBigUint64(4, false), 2n);
  assert.equal(subscribeView.getBigUint64(12, false), 3n);
  assert.equal(subscribeView.getUint32(20, false), 17);
});

test("client message IDs reject zero output and are copied into the retryable frame", () => {
  let calls = 0;
  const codec = loadCodec({
    getRandomValues(bytes) {
      calls++;
      bytes.fill(calls === 1 ? 0 : 0x5a);
      return bytes;
    },
  });
  const id = codec.createClientMessageId();
  const frame = codec.encodeSendMessage(48, 2n, id, 7, 0, new Uint8Array([1, 2]));
  id.fill(0);

  assert.equal(calls, 2);
  assert.equal(codec.clientMessageIdKey(new Uint8Array(frame, 10, 16)), "5a".repeat(16));
});

test("encoders enforce server subscription and content limits", () => {
  const codec = loadCodec();
  const id = new Uint8Array(16).fill(1);
  assert.equal(codec.encodeSubscribe(49, Array.from({ length: 64 }, (_, index) => BigInt(index)), 1).byteLength, 520);
  assert.throws(
    () => codec.encodeSubscribe(49, Array.from({ length: 65 }, (_, index) => BigInt(index)), 1),
    /Too many conversation subscriptions/,
  );
  assert.equal(codec.encodeSendMessage(48, 2n, id, 1, 1, new Uint8Array(50 * 1024)).byteLength, 33 + 50 * 1024);
  assert.throws(
    () => codec.encodeSendMessage(48, 2n, id, 1, 0, new Uint8Array(50 * 1024 + 1)),
    /exceeds maximum size/,
  );
  assert.throws(() => codec.encodeSendMessage(48, 2n, id, 1, 2, new Uint8Array()), /content type/);
});

test("subscription ready parser validates exact length", () => {
  const codec = loadCodec();
  const buffer = new ArrayBuffer(32);
  const view = new DataView(buffer);
  view.setUint16(0, 158, false);
  view.setUint32(2, 99, false);
  view.setUint16(6, 1, false);
  view.setBigUint64(8, 2n, false);
  view.setBigUint64(16, 40n, false);
  view.setBigUint64(24, 3n, false);

  const parsed = codec.parseSubscriptionReady(view);
  assert.equal(parsed.correlationId, 99);
  assert.equal(parsed.entries.length, 1);
  assert.equal(parsed.entries[0].convId, 2n);
  assert.equal(parsed.entries[0].highWaterSeq, 40n);
  assert.equal(parsed.entries[0].retentionCutoffSeq, 3n);
  assert.throws(() => codec.parseSubscriptionReady(new DataView(buffer, 0, 31)), /length mismatch/);
});

test("message page parser decodes records and rejects trailing bytes", () => {
  const codec = loadCodec();
  const username = new TextEncoder().encode("rene");
  const content = new TextEncoder().encode("retained");
  const length = 43 + 45 + username.length + content.length;
  const buffer = new ArrayBuffer(length + 1);
  const view = new DataView(buffer);
  view.setUint16(0, 159, false);
  view.setBigUint64(2, 2n, false);
  view.setUint8(10, 0);
  view.setUint8(11, 1);
  view.setUint8(12, 0);
  view.setBigUint64(13, 42n, false);
  view.setBigUint64(21, 4n, false);
  view.setBigUint64(29, 41n, false);
  view.setUint32(37, 12, false);
  view.setUint16(41, 1, false);
  let offset = 43;
  view.setBigUint64(offset, 2n, false);
  view.setBigUint64(offset + 8, 42n, false);
  new Uint8Array(buffer, offset + 16, 16).fill(0xab);
  offset += 32;
  view.setUint16(offset, username.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, username.length).set(username);
  offset += username.length;
  view.setBigInt64(offset, 1_725_000_000_000_000_000n, false);
  offset += 8;
  view.setUint8(offset++, 0);
  view.setUint16(offset, content.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, content.length).set(content);

  const parsed = codec.parseMessagePage(new DataView(buffer, 0, length));
  assert.equal(parsed.convId, 2n);
  assert.equal(parsed.hasMore, true);
  assert.equal(parsed.messages[0].seq, 42n);
  assert.equal(parsed.messages[0].authorUsername, "rene");
  assert.equal(parsed.messages[0].content, "retained");
  assert.equal(codec.clientMessageIdKey(parsed.messages[0].clientMessageId), "ab".repeat(16));
  assert.throws(() => codec.parseMessagePage(view), /trailing data/);
});
