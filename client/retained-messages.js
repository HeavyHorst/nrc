(function () {
  "use strict";

  const MAX_PAGE_MESSAGES = 100;
  const MAX_SUBSCRIPTIONS = 64;
  const MAX_USERNAME_BYTES = 255;
  const MAX_CONTENT_BYTES = 50 * 1024;
  const textDecoder = new TextDecoder("utf-8", { fatal: true });

  function createClientMessageId(cryptoProvider = globalThis.crypto) {
    if (!cryptoProvider?.getRandomValues) {
      throw new Error("Secure random message IDs are unavailable");
    }
    const id = new Uint8Array(16);
    do {
      cryptoProvider.getRandomValues(id);
    } while (id.every((value) => value === 0));
    return id;
  }

  function clientMessageIdKey(id) {
    return Array.from(id, (value) => value.toString(16).padStart(2, "0")).join("");
  }

  function encodeSendMessage(opcode, convId, clientMessageId, correlationId, contentType, contentBytes) {
    if (clientMessageId.byteLength !== 16) throw new Error("Client message ID must be 16 bytes");
    if (contentType < 0 || contentType > 1) throw new Error("Invalid message content type");
    if (contentBytes.byteLength > MAX_CONTENT_BYTES) throw new Error("Message content exceeds maximum size");
    const buffer = new ArrayBuffer(33 + contentBytes.byteLength);
    const view = new DataView(buffer);
    view.setUint16(0, opcode, false);
    view.setBigUint64(2, BigInt(convId), false);
    new Uint8Array(buffer, 10, 16).set(clientMessageId);
    view.setUint32(26, correlationId, false);
    view.setUint8(30, contentType);
    view.setUint16(31, contentBytes.byteLength, false);
    new Uint8Array(buffer, 33).set(contentBytes);
    return buffer;
  }

  function encodeSubscribe(opcode, convIds, correlationId) {
    if (convIds.length > MAX_SUBSCRIPTIONS) throw new Error("Too many conversation subscriptions");
    const buffer = new ArrayBuffer(8 + convIds.length * 8);
    const view = new DataView(buffer);
    view.setUint16(0, opcode, false);
    view.setUint16(2, convIds.length, false);
    convIds.forEach((convId, index) => view.setBigUint64(4 + index * 8, BigInt(convId), false));
    view.setUint32(4 + convIds.length * 8, correlationId, false);
    return buffer;
  }

  function encodeRangeRequest(opcode, convId, cursor, limit, correlationId) {
    if (limit < 1 || limit > MAX_PAGE_MESSAGES) throw new Error("Invalid retained message page size");
    const buffer = new ArrayBuffer(24);
    const view = new DataView(buffer);
    view.setUint16(0, opcode, false);
    view.setBigUint64(2, BigInt(convId), false);
    view.setBigUint64(10, BigInt(cursor), false);
    view.setUint16(18, limit, false);
    view.setUint32(20, correlationId, false);
    return buffer;
  }

  function parseSubscriptionReady(view) {
    if (view.byteLength < 8) throw new Error("S_SubscriptionReady too short");
    const correlationId = view.getUint32(2, false);
    const count = view.getUint16(6, false);
    if (count > MAX_SUBSCRIPTIONS) throw new Error("S_SubscriptionReady has too many entries");
    if (view.byteLength !== 8 + count * 24) throw new Error("S_SubscriptionReady length mismatch");
    const entries = [];
    for (let index = 0; index < count; index++) {
      const offset = 8 + index * 24;
      entries.push({
        convId: view.getBigUint64(offset, false),
        highWaterSeq: view.getBigUint64(offset + 8, false),
        retentionCutoffSeq: view.getBigUint64(offset + 16, false),
      });
    }
    return { correlationId, entries };
  }

  function parseMessagePage(view) {
    if (view.byteLength < 43) throw new Error("S_MessagePage too short");
    const flagValues = [view.getUint8(10), view.getUint8(11), view.getUint8(12)];
    if (flagValues.some((value) => value > 1)) throw new Error("S_MessagePage has invalid flags");
    const count = view.getUint16(41, false);
    if (count > MAX_PAGE_MESSAGES) throw new Error("S_MessagePage has too many messages");
    const page = {
      convId: view.getBigUint64(2, false),
      ascending: flagValues[0] === 1,
      hasMore: flagValues[1] === 1,
      truncated: flagValues[2] === 1,
      highWaterSeq: view.getBigUint64(13, false),
      retentionCutoffSeq: view.getBigUint64(21, false),
      continuationCursor: view.getBigUint64(29, false),
      correlationId: view.getUint32(37, false),
      messages: [],
    };
    let offset = 43;
    for (let index = 0; index < count; index++) {
      if (view.byteLength < offset + 45) throw new Error("S_MessagePage record too short");
      const convId = view.getBigUint64(offset, false);
      const seq = view.getBigUint64(offset + 8, false);
      const clientMessageId = new Uint8Array(view.buffer, view.byteOffset + offset + 16, 16).slice();
      offset += 32;
      const usernameLength = view.getUint16(offset, false);
      offset += 2;
      if (usernameLength > MAX_USERNAME_BYTES) throw new Error("S_MessagePage username exceeds maximum size");
      if (view.byteLength < offset + usernameLength + 11) throw new Error("S_MessagePage username length mismatch");
      const authorUsername = textDecoder.decode(
        new Uint8Array(view.buffer, view.byteOffset + offset, usernameLength),
      );
      offset += usernameLength;
      const timestamp = view.getBigInt64(offset, false);
      offset += 8;
      const contentType = view.getUint8(offset++);
      if (contentType > 1) throw new Error("S_MessagePage content type is invalid");
      const contentLength = view.getUint16(offset, false);
      offset += 2;
      if (contentLength > MAX_CONTENT_BYTES) throw new Error("S_MessagePage content exceeds maximum size");
      if (view.byteLength < offset + contentLength) throw new Error("S_MessagePage content length mismatch");
      const content = textDecoder.decode(
        new Uint8Array(view.buffer, view.byteOffset + offset, contentLength),
      );
      offset += contentLength;
      page.messages.push({ convId, seq, clientMessageId, authorUsername, timestamp, contentType, content });
    }
    if (offset !== view.byteLength) throw new Error("S_MessagePage has trailing data");
    return page;
  }

  window.NRCRetainedMessages = {
    MAX_PAGE_MESSAGES,
    MAX_SUBSCRIPTIONS,
    MAX_USERNAME_BYTES,
    MAX_CONTENT_BYTES,
    createClientMessageId,
    clientMessageIdKey,
    encodeSendMessage,
    encodeSubscribe,
    encodeRangeRequest,
    parseSubscriptionReady,
    parseMessagePage,
  };
})();
