// =============================================================================
// NRC PROTOCOL DECODERS
// =============================================================================
// Pure server-to-client record decoders shared by the browser client and the
// frame dispatcher in client/frames.js. Nothing here touches the DOM or client
// state: malformed input raises ProtocolError, and a successful decode returns
// plain records. The browser handlers in tasks.js, assets.js, edges.js and the
// other client modules call these functions so the fuzzer exercises the same
// code the client runs.
//
// The wire formats follow the Odin serializers in protocol/tasks.odin,
// protocol/assets.odin and protocol/edges.odin. Keep the byte order and field
// order identical.

(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.NRCProtocol = factory();
  }
})(typeof window !== "undefined" ? window : globalThis, function () {
  "use strict";

  const textDecoder = new TextDecoder();

  class ProtocolError extends Error {
    constructor(message) {
      super(message);
      this.name = "ProtocolError";
    }
  }

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

  // ---------------------------------------------------------------------------
  // Records
  // ---------------------------------------------------------------------------

  function parseTask(view, offset) {
    const task = {};

    task.id = u64(view, offset);
    offset += 8;
    task.convId = u64(view, offset);
    offset += 8;

    let field = wireString(view, offset);
    task.title = field.value;
    offset = field.newOffset;

    field = wireString(view, offset);
    task.description = field.value;
    offset = field.newOffset;

    task.status = u8(view, offset);
    offset += 1;
    task.orderIndex = u16(view, offset);
    offset += 2;

    field = wireString(view, offset);
    task.assignee = field.value;
    offset = field.newOffset;

    task.priority = u8(view, offset);
    offset += 1;
    task.color = u8(view, offset);
    offset += 1;

    field = wireString(view, offset);
    task.createdBy = field.value;
    offset = field.newOffset;

    task.createdAt = i64(view, offset);
    offset += 8;
    task.updatedAt = i64(view, offset);
    offset += 8;

    field = wireString(view, offset);
    task.externalRef = field.value;
    offset = field.newOffset;

    task.dueAt = i64(view, offset);
    offset += 8;
    task.blockedBy = u64(view, offset);
    offset += 8;
    task.completedAt = i64(view, offset);
    offset += 8;

    field = wireString(view, offset);
    task.completedBy = field.value;
    offset = field.newOffset;

    field = wireString(view, offset);
    task.project = field.value;
    offset = field.newOffset;

    const attachmentCount = u16(view, offset);
    offset += 2;
    task.attachments = [];
    for (let i = 0; i < attachmentCount; i += 1) {
      const fileId = wireString(view, offset);
      offset = fileId.newOffset;
      const filename = wireString(view, offset);
      offset = filename.newOffset;
      const size = u64(view, offset);
      offset += 8;
      const mimeType = wireString(view, offset);
      offset = mimeType.newOffset;
      const uploadedAt = i64(view, offset);
      offset += 8;
      task.attachments.push({
        fileId: fileId.value,
        filename: filename.value,
        size,
        mimeType: mimeType.value,
        uploadedAt,
      });
    }

    return { task, newOffset: offset };
  }

  function parseAssetAttachments(view, offset) {
    const count = u16(view, offset);
    offset += 2;
    const attachments = [];
    for (let i = 0; i < count; i += 1) {
      const fileId = wireString(view, offset);
      offset = fileId.newOffset;
      const filename = wireString(view, offset);
      offset = filename.newOffset;
      const size = u64(view, offset);
      offset += 8;
      const mimeType = wireString(view, offset);
      offset = mimeType.newOffset;
      const uploadedAt = i64(view, offset);
      offset += 8;
      attachments.push({
        fileId: fileId.value,
        filename: filename.value,
        size,
        mimeType: mimeType.value,
        uploadedAt,
      });
    }
    return { attachments, newOffset: offset };
  }

  function parseAsset(view, offset, includeAttachments = true) {
    const assetType = u16(view, offset);
    offset += 2;
    const assetId = u64(view, offset);
    offset += 8;
    const parentType = u16(view, offset);
    offset += 2;
    const parentId = u64(view, offset);
    offset += 8;

    const owner = wireString(view, offset);
    offset = owner.newOffset;

    const createdAt = i64(view, offset);
    offset += 8;
    const updatedAt = i64(view, offset);
    offset += 8;
    const convId = u64(view, offset);
    offset += 8;

    const payloadEncoding = u8(view, offset);
    offset += 1;
    const payloadRawLen = u32(view, offset);
    offset += 4;

    const preview = wireString(view, offset);
    offset = preview.newOffset;

    let attachments = [];
    if (includeAttachments) {
      const parsed = parseAssetAttachments(view, offset);
      attachments = parsed.attachments;
      offset = parsed.newOffset;
    }

    return {
      asset: {
        assetType,
        assetId,
        parentType,
        parentId,
        owner: owner.value,
        createdAt,
        updatedAt,
        convId,
        payloadEncoding,
        payloadRawLen,
        preview: preview.value,
        payload: null,
        attachments,
      },
      newOffset: offset,
    };
  }

  // Payload is copied so callers may decode it after the frame is released.
  function parseAssetPayload(view, offset) {
    const length = u16(view, offset);
    offset += 2;
    const payload = new Uint8Array(bytes(view, offset, length));
    return { payload, newOffset: offset + length };
  }

  function parseEdge(view, offset) {
    const edgeId = u64(view, offset);
    offset += 8;
    const convId = u64(view, offset);
    offset += 8;
    const sourceType = u16(view, offset);
    offset += 2;
    const sourceId = u64(view, offset);
    offset += 8;
    const targetType = u16(view, offset);
    offset += 2;
    const targetId = u64(view, offset);
    offset += 8;
    const relation = u16(view, offset);
    offset += 2;
    const createdAt = i64(view, offset);
    offset += 8;
    const createdBy = wireString(view, offset);
    offset = createdBy.newOffset;

    return {
      edge: {
        edgeId,
        convId,
        sourceType,
        sourceId,
        targetType,
        targetId,
        relation,
        createdAt,
        createdBy: createdBy.value,
      },
      newOffset: offset,
    };
  }

  return {
    ProtocolError,
    parseTask,
    parseAssetAttachments,
    parseAsset,
    parseAssetPayload,
    parseEdge,
  };
});
