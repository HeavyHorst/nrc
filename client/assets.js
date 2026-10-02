// =============================================================================
// NRC ASSETS MODULE
// =============================================================================
// Generic asset management for comments, documents, files, and agendas.
// Server stores opaque payloads; frontend owns the schema.

const AssetType = {
  Comment: 1,
  Document: 2,
  File: 3,
  Agenda: 4,
  Note: 5,
  Reminder: 6,
  RoomMapping: 7,
  CustomerCompany: 8,
  CustomerContact: 9,
  CustomerActivity: 10,
  Slice: 11,
  Appointment: 12,
};

// Asset limits (must match server protocol/assets.odin)
const MAX_PREVIEW_LENGTH = 4096;
const MAX_PAYLOAD_LENGTH = 65535; // Payload length is encoded as uint16 on the wire.

const ParentType = {
  None: 0,
  Task: 1,
  Asset: 2,
};

const PayloadEncoding = {
  Plain: 0,
  Zstd: 1,
};

const assetTextEncoder = new TextEncoder();
const assetTextDecoder = new TextDecoder();

let zstdStreamCodec = null;
let zstdInitPromise = null;

function ensureZstdCodec() {
  if (zstdStreamCodec) return Promise.resolve(zstdStreamCodec);
  if (zstdInitPromise) return zstdInitPromise;

  if (!window.zstdCodec || typeof window.zstdCodec.ZstdInit !== "function") {
    console.warn("[assets] zstd codec not available; using plain payload encoding");
    zstdInitPromise = Promise.resolve(null);
    return zstdInitPromise;
  }

  zstdInitPromise = window.zstdCodec
    .ZstdInit()
    .then((codec) => {
      zstdStreamCodec = codec.ZstdStream;
      return zstdStreamCodec;
    })
    .catch((error) => {
      console.error("[assets] Failed to initialize zstd codec", error);
      return null;
    });

  return zstdInitPromise;
}

function encodeAssetPayloadForWire(payload) {
  const rawPayloadBytes = assetTextEncoder.encode(payload);
  if (rawPayloadBytes.length > MAX_PAYLOAD_LENGTH) {
    throw new Error(`Payload exceeds max length (${rawPayloadBytes.length} > ${MAX_PAYLOAD_LENGTH})`);
  }

  if (zstdStreamCodec && rawPayloadBytes.length > 0) {
    try {
      const compressed = zstdStreamCodec.compress(rawPayloadBytes, 3, false);
      if (compressed.length <= MAX_PAYLOAD_LENGTH) {
        return {
          payloadBytes: compressed,
          payloadEncoding: PayloadEncoding.Zstd,
          payloadRawLen: rawPayloadBytes.length,
        };
      }

      console.warn(
        `[assets] Compressed payload too large (${compressed.length}); falling back to plain encoding`,
      );
    } catch (error) {
      console.error("[assets] zstd compression failed; falling back to plain encoding", error);
    }
  }

  return {
    payloadBytes: rawPayloadBytes,
    payloadEncoding: PayloadEncoding.Plain,
    payloadRawLen: rawPayloadBytes.length,
  };
}

function decodeAssetPayloadFromWire(payloadEncoding, payloadRawLen, payloadBytes) {
  if (payloadEncoding === PayloadEncoding.Plain) {
    if (payloadRawLen !== payloadBytes.length) {
      throw new Error(`Plain payload length mismatch (raw=${payloadRawLen}, wire=${payloadBytes.length})`);
    }
    return assetTextDecoder.decode(payloadBytes);
  }

  if (payloadEncoding === PayloadEncoding.Zstd) {
    if (!zstdStreamCodec) {
      throw new Error("zstd payload received before codec initialization");
    }

    const rawBytes = zstdStreamCodec.decompress(payloadBytes);
    if (rawBytes.length !== payloadRawLen) {
      throw new Error(`Decoded payload length mismatch (raw=${payloadRawLen}, decoded=${rawBytes.length})`);
    }
    return assetTextDecoder.decode(rawBytes);
  }

  throw new Error(`Unsupported payload encoding: ${payloadEncoding}`);
}

// Per-room asset storage: roomId → Map(assetId → asset)
const roomAssets = new Map();

// Pending asset requests (for retry on reconnect)
// Keyed map avoids duplicate enqueue of the same list request.
const pendingAssetRequests = new Map();
const pendingAssetRpcByCorrelation = new Map();
const pendingExactAssetRequests = new Map();
let nextCorrelationId = 1;
let assetMutationSequence = 0;
const assetMutationVersions = new Map();

function assetMutationKey(convId, assetId) {
  return `${BigInt(convId)}:${BigInt(assetId)}`;
}

function markAssetMutation(convId, assetId) {
  assetMutationVersions.set(assetMutationKey(convId, assetId), ++assetMutationSequence);
}

const AssetOriginOpcode = {
  Create: 30,
  Update: 31,
  Delete: 32,
  Get: 33,
  List: 34,
  ListPaged: 35,
  ListPagedByProject: 36,
  ListProjects: 37,
  ListPagedByTag: 38,
  ListTags: 39,
  SearchCustomers: 55,
};

function normalizeAssetRequestOptions(options) {
  return options && typeof options === "object" ? options : null;
}

function registerPendingAssetRpc(correlationId, request) {
  if (!correlationId) return;
  pendingAssetRpcByCorrelation.set(correlationId, request);
}

function settlePendingAssetRpc(correlationId, ok, detail) {
  if (!correlationId) return null;

  const pending = pendingAssetRpcByCorrelation.get(correlationId);
  if (!pending) return null;

  pendingAssetRpcByCorrelation.delete(correlationId);

  const callback = ok ? pending.onSuccess : pending.onError;
  if (typeof callback === "function") {
    try {
      callback(detail, pending);
    } catch (callbackError) {
      console.error("[assets] Pending request callback failed", callbackError);
    }
  }

  const eventName = ok ? "nrc:asset-request-success" : "nrc:asset-request-error";
  document.dispatchEvent(
    new CustomEvent(eventName, {
      detail: {
        correlationId,
        kind: pending.kind,
        convId: pending.convId,
        assetId: pending.assetId ?? null,
        originOpcode: pending.originOpcode,
        result: ok ? detail : null,
        error: ok ? null : detail,
      },
    }),
  );

  return pending;
}

function getAssetRequestKindFromOriginOpcode(originOpcode) {
  switch (originOpcode) {
    case AssetOriginOpcode.Create:
      return "create";
    case AssetOriginOpcode.Update:
      return "update";
    case AssetOriginOpcode.Delete:
      return "delete";
    case AssetOriginOpcode.Get:
      return "get";
    case AssetOriginOpcode.List:
      return "list";
    case AssetOriginOpcode.ListPaged:
      return "list_paged";
    case AssetOriginOpcode.ListPagedByProject:
      return "list_paged_project";
    case AssetOriginOpcode.ListProjects:
      return "list_projects";
    case AssetOriginOpcode.ListPagedByTag:
      return "list_paged_tag";
    case AssetOriginOpcode.ListTags:
      return "list_tags";
    case AssetOriginOpcode.SearchCustomers:
      return "customer_search";
    default:
      return null;
  }
}

function getAssetRequestLabel(kind) {
  switch (kind) {
    case "create":
      return "CREATE";
    case "update":
      return "UPDATE";
    case "delete":
      return "DELETE";
    case "get":
      return "GET";
    case "list":
      return "LIST";
    case "list_paged":
      return "LIST PAGE";
    case "list_paged_project":
      return "LIST PROJECT PAGE";
    case "list_paged_tag":
      return "LIST TAG PAGE";
    case "list_projects":
      return "LIST PROJECTS";
    case "list_tags":
      return "LIST TAGS";
    default:
      return "REQUEST";
  }
}

function getAssetTypeLabel(assetType) {
  switch (assetType) {
    case AssetType.Comment:
      return "COMMENT";
    case AssetType.Document:
      return "DOCUMENT";
    case AssetType.File:
      return "FILE";
    case AssetType.Agenda:
      return "AGENDA";
    case AssetType.Note:
      return "NOTE";
    case AssetType.Reminder:
      return "REMINDER";
    case AssetType.RoomMapping:
      return "ROOM MAPPING";
    case AssetType.CustomerCompany:
      return "COMPANY";
    case AssetType.CustomerContact:
      return "CONTACT";
    case AssetType.CustomerActivity:
      return "ACTIVITY";
    case AssetType.Slice:
      return "SLICE";
    case AssetType.Appointment:
      return "APPOINTMENT";
    default:
      return assetType == null ? "ANY" : `TYPE ${assetType}`;
  }
}

function formatAssetRequestContext(pending) {
  if (!pending) return "ASSET REQUEST";

  const roomPart = pending.convId !== undefined ? `ROOM ${pending.convId}` : "ROOM ?";
  const assetPart = pending.assetId !== undefined && pending.assetId !== null
    ? `ASSET #${pending.assetId}`
    : null;

  return assetPart ? `${roomPart} ${assetPart}` : roomPart;
}

function buildPendingAssetRequestKey(convId, assetType, fullContent) {
  return `list:${convId.toString()}:${assetType === null ? "all" : String(assetType)}:${fullContent ? 1 : 0}`;
}

function buildPendingAssetPageRequestKey(convId, assetType, fullContent, limit, cursorUpdatedAt, cursorAssetId) {
  const cursorPart =
    cursorUpdatedAt !== null && cursorAssetId !== null
      ? `${cursorUpdatedAt.toString()}:${cursorAssetId.toString()}`
      : "none";
  return `list_paged:${convId.toString()}:${String(assetType)}:${fullContent ? 1 : 0}:${limit}:${cursorPart}`;
}

function formatPayloadCompressionStats(rawLen, wireLen) {
  if (rawLen <= 0) {
    return {
      ratioText: "n/a",
      savingsText: "0.0%",
    };
  }

  const ratio = wireLen / rawLen;
  const savingsPercent = ((rawLen - wireLen) / rawLen) * 100;
  return {
    ratioText: `${ratio.toFixed(3)}x`,
    savingsText: `${savingsPercent.toFixed(1)}%`,
  };
}

function logNotePayloadCompression(op, convId, payloadEncoding, payloadRawLen, payloadWireLen, assetId = null) {
  const encodingLabel = payloadEncoding === PayloadEncoding.Zstd ? "zstd" : "plain";
  const { ratioText, savingsText } = formatPayloadCompressionStats(payloadRawLen, payloadWireLen);
  const targetLabel = assetId === null ? `room:${convId.toString()}` : `note:${assetId.toString()}`;
  const message =
    `NOTE ${op} PAYLOAD ${targetLabel} RAW ${payloadRawLen}B WIRE ${payloadWireLen}B ` +
    `RATIO ${ratioText} SAVED ${savingsText} ENCODING ${encodingLabel}`;

  console.log(`[assets] ${message}`);
  if (typeof logSystem === "function") {
    logSystem(message, "assets", "DEBUG");
  }
}

function normalizedAssetAttachments(attachments = []) {
  return Array.isArray(attachments)
    ? attachments.filter((att) => att && att.fileId).slice(0, 10)
    : [];
}

function getAssetAttachmentsWireSize(attachments = []) {
  let size = 2;
  for (const att of normalizedAssetAttachments(attachments)) {
    size +=
      2 + assetTextEncoder.encode(att.fileId || "").length +
      2 + assetTextEncoder.encode(att.filename || "").length +
      8 +
      2 + assetTextEncoder.encode(att.mimeType || "").length +
      8;
  }
  return size;
}

function writeAssetAttachments(view, buffer, offset, attachments = []) {
  const normalized = normalizedAssetAttachments(attachments);
  view.setUint16(offset, normalized.length, false);
  offset += 2;
  for (const att of normalized) {
    const fileIdBytes = assetTextEncoder.encode(att.fileId || "");
    const filenameBytes = assetTextEncoder.encode(att.filename || "");
    const mimeTypeBytes = assetTextEncoder.encode(att.mimeType || "");

    view.setUint16(offset, fileIdBytes.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, fileIdBytes.length).set(fileIdBytes);
    offset += fileIdBytes.length;

    view.setUint16(offset, filenameBytes.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, filenameBytes.length).set(filenameBytes);
    offset += filenameBytes.length;

    view.setBigUint64(offset, BigInt(att.size || 0), false);
    offset += 8;

    view.setUint16(offset, mimeTypeBytes.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, mimeTypeBytes.length).set(mimeTypeBytes);
    offset += mimeTypeBytes.length;

    view.setBigInt64(offset, BigInt(att.uploadedAt || 0), false);
    offset += 8;
  }
  return offset;
}

function parseAssetAttachments(dataView, offset) {
  const count = dataView.getUint16(offset, false);
  offset += 2;
  const attachments = [];
  for (let i = 0; i < count; i += 1) {
    const fileIdLen = dataView.getUint16(offset, false);
    offset += 2;
    const fileId = assetTextDecoder.decode(new Uint8Array(dataView.buffer, offset, fileIdLen));
    offset += fileIdLen;

    const filenameLen = dataView.getUint16(offset, false);
    offset += 2;
    const filename = assetTextDecoder.decode(new Uint8Array(dataView.buffer, offset, filenameLen));
    offset += filenameLen;

    const size = dataView.getBigUint64(offset, false);
    offset += 8;

    const mimeTypeLen = dataView.getUint16(offset, false);
    offset += 2;
    const mimeType = assetTextDecoder.decode(new Uint8Array(dataView.buffer, offset, mimeTypeLen));
    offset += mimeTypeLen;

    const uploadedAt = dataView.getBigInt64(offset, false);
    offset += 8;

    attachments.push({ fileId, filename, size, mimeType, uploadedAt });
  }
  return { attachments, newOffset: offset };
}

// =============================================================================
// WIRE PROTOCOL - SEND
// =============================================================================

function sendCreateAsset(
  convId,
  assetType,
  parentType = ParentType.None,
  parentId = 0n,
  preview = "",
  payload = "",
  correlationId = 0,
  requestOptions = null,
  attachments = [],
) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  if (correlationId === 0) {
    correlationId = generateCorrelationId();
  }

  const previewBytes = assetTextEncoder.encode(preview);
  let payloadBytes;
  let payloadEncoding;
  let payloadRawLen;
  try {
    ({ payloadBytes, payloadEncoding, payloadRawLen } = encodeAssetPayloadForWire(payload));
  } catch (error) {
    console.error("[assets] Failed to encode create payload", error);
    return;
  }

  if (assetType === AssetType.Note) {
    logNotePayloadCompression("CREATE", convId, payloadEncoding, payloadRawLen, payloadBytes.length);
  }

  // Buffer: Opcode(2) + conv_id(8) + asset_type(2) + parent_type(2) + parent_id(8)
  //       + payload_encoding(1) + payload_raw_len(4)
  //       + preview_len(2) + preview + payload_len(2) + payload + attachments + correlation_id(4)
  const attachmentsSize = getAssetAttachmentsWireSize(attachments);
  const bufferSize =
    2 + 8 + 2 + 2 + 8 + 1 + 4 + 2 + previewBytes.length + 2 + payloadBytes.length + attachmentsSize + 4;

  const buffer = new ArrayBuffer(bufferSize);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_CreateAsset, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setUint16(offset, assetType, false);
  offset += 2;

  view.setUint16(offset, parentType, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(parentId), false);
  offset += 8;

  view.setUint8(offset, payloadEncoding);
  offset += 1;

  view.setUint32(offset, payloadRawLen, false);
  offset += 4;

  view.setUint16(offset, previewBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, previewBytes.length).set(previewBytes);
  offset += previewBytes.length;

  view.setUint16(offset, payloadBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, payloadBytes.length).set(payloadBytes);
  offset += payloadBytes.length;

  offset = writeAssetAttachments(view, buffer, offset, attachments);

  view.setUint32(offset, correlationId, false);

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "create",
    originOpcode: AssetOriginOpcode.Create,
    convId: BigInt(convId),
    assetId: null,
    assetType,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendUpdateAsset(
  convId,
  assetId,
  preview = "",
  payload = "",
  assetTypeHint = null,
  correlationId = 0,
  requestOptions = null,
  attachments = [],
) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  if (correlationId === 0) {
    correlationId = generateCorrelationId();
  }

  const previewBytes = assetTextEncoder.encode(preview);
  let payloadBytes;
  let payloadEncoding;
  let payloadRawLen;
  try {
    ({ payloadBytes, payloadEncoding, payloadRawLen } = encodeAssetPayloadForWire(payload));
  } catch (error) {
    console.error("[assets] Failed to encode update payload", error);
    return;
  }

  if (assetTypeHint === AssetType.Note) {
    logNotePayloadCompression(
      "UPDATE",
      convId,
      payloadEncoding,
      payloadRawLen,
      payloadBytes.length,
      assetId,
    );
  }

  // Buffer: Opcode(2) + conv_id(8) + asset_id(8) + payload_encoding(1) + payload_raw_len(4)
  //       + preview_len(2) + preview + payload_len(2) + payload + attachments + correlation_id(4)
  const attachmentsSize = getAssetAttachmentsWireSize(attachments);
  const bufferSize =
    2 + 8 + 8 + 1 + 4 + 2 + previewBytes.length + 2 + payloadBytes.length + attachmentsSize + 4;

  const buffer = new ArrayBuffer(bufferSize);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_UpdateAsset, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setBigUint64(offset, BigInt(assetId), false);
  offset += 8;

  view.setUint8(offset, payloadEncoding);
  offset += 1;

  view.setUint32(offset, payloadRawLen, false);
  offset += 4;

  view.setUint16(offset, previewBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, previewBytes.length).set(previewBytes);
  offset += previewBytes.length;

  view.setUint16(offset, payloadBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, payloadBytes.length).set(payloadBytes);
  offset += payloadBytes.length;

  offset = writeAssetAttachments(view, buffer, offset, attachments);

  view.setUint32(offset, correlationId, false);

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "update",
    originOpcode: AssetOriginOpcode.Update,
    convId: BigInt(convId),
    assetId: BigInt(assetId),
    assetType: assetTypeHint,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendDeleteAsset(convId, assetId, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = generateCorrelationId();

  // Buffer: Opcode(2) + conv_id(8) + asset_id(8) + correlation_id(4)
  const buffer = new ArrayBuffer(22);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_DeleteAsset, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setBigUint64(10, BigInt(assetId), false);
  view.setUint32(18, correlationId, false);

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "delete",
    originOpcode: AssetOriginOpcode.Delete,
    convId: BigInt(convId),
    assetId: BigInt(assetId),
    assetType: null,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendGetAsset(convId, assetId, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) {
    const key = `get:${BigInt(convId)}:${BigInt(assetId)}`;
    let pending = pendingAssetRequests.get(key);
    if (!pending) {
      pending = { type: "get", convId, assetId, subscribers: [] };
      pendingAssetRequests.set(key, pending);
    }
    const opts = normalizeAssetRequestOptions(requestOptions);
    if (opts) pending.subscribers.push(opts);
    return 0;
  }

  const correlationId = generateCorrelationId();

  // Buffer: Opcode(2) + conv_id(8) + asset_id(8) + correlation_id(4)
  const buffer = new ArrayBuffer(22);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_GetAsset, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setBigUint64(10, BigInt(assetId), false);
  view.setUint32(18, correlationId, false);

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "get",
    originOpcode: AssetOriginOpcode.Get,
    convId: BigInt(convId),
    assetId: BigInt(assetId),
    assetType: null,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

// Exact reads require a full payload; list-cache previews are not sufficient.
function requestAsset(convId, assetId, requestOptions = null) {
  const normalizedConvId = 0n;
  const normalizedAssetId = BigInt(assetId);
  const cached = roomAssets.get(normalizedConvId)?.get(normalizedAssetId);
  if (cached?.payload != null && !requestOptions?.force) {
    requestOptions?.onSuccess?.(
      { kind: "get", asset: cached, correlationId: 0 },
      { kind: "get", convId: normalizedConvId, assetId: normalizedAssetId, context: requestOptions?.context },
    );
    return cached;
  }

  const key = `${normalizedConvId}:${normalizedAssetId}`;
  const subscriber = normalizeAssetRequestOptions(requestOptions);
  const pending = pendingExactAssetRequests.get(key);
  if (pending) {
    if (subscriber) pending.subscribers.push(subscriber);
    return pending.correlationId;
  }
  const entry = { correlationId: undefined, subscribers: subscriber ? [subscriber] : [] };
  pendingExactAssetRequests.set(key, entry);
  const settle = (callbackName, detail) => {
    if (pendingExactAssetRequests.get(key) !== entry) return;
    pendingExactAssetRequests.delete(key);
    notifyPendingGetSubscribers(entry.subscribers, callbackName, detail, {
      kind: "get", convId: normalizedConvId, assetId: normalizedAssetId,
    });
  };
  entry.correlationId = sendGetAsset(normalizedConvId, normalizedAssetId, {
    onSuccess: (detail) => settle("onSuccess", detail),
    onError: (detail) => settle("onError", detail),
  });
  if (entry.correlationId === undefined) pendingExactAssetRequests.delete(key);
  return entry.correlationId;
}

function sendListAssets(convId, assetType = null, fullContent = false, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) {
    const key = buildPendingAssetRequestKey(convId, assetType, fullContent);
    pendingAssetRequests.set(key, { type: "list", convId, assetType, fullContent });
    return 0;
  }

  const correlationId = generateCorrelationId();

  // Buffer: Opcode(2) + conv_id(8) + filter_by_type(1) + asset_type(2) + full_content(1) + correlation_id(4)
  const buffer = new ArrayBuffer(18);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_ListAssets, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setUint8(10, assetType !== null ? 1 : 0);
  view.setUint16(11, assetType !== null ? assetType : 0, false);
  view.setUint8(13, fullContent ? 1 : 0);
  view.setUint32(14, correlationId, false);

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "list",
    originOpcode: AssetOriginOpcode.List,
    convId: BigInt(convId),
    assetId: null,
    assetType,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendListAssetsPaged(
  convId,
  assetType,
  fullContent = false,
  limit = 50,
  cursorUpdatedAt = null,
  cursorAssetId = null,
  requestOptions = null,
) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) {
    const key = buildPendingAssetPageRequestKey(
      convId,
      assetType,
      fullContent,
      limit,
      cursorUpdatedAt,
      cursorAssetId,
    );
    pendingAssetRequests.set(key, {
      type: "list_paged",
      convId,
      assetType,
      fullContent,
      limit,
      cursorUpdatedAt,
      cursorAssetId,
    });
    return 0;
  }

  const correlationId = generateCorrelationId();

  // Wire format diverges by cursor presence for compatibility with the server parser:
  // - has_cursor=1: opcode(2) + conv_id(8) + asset_type(2) + full_content(1) + limit(2)
  //               + has_cursor(1) + cursor_updated_at(8) + cursor_asset_id(8) + correlation_id(4)
  // - has_cursor=0: opcode(2) + conv_id(8) + asset_type(2) + full_content(1) + limit(2)
  //               + has_cursor(1) + correlation_id(4) + legacy_padding(8)
  const hasCursor = cursorUpdatedAt !== null && cursorAssetId !== null;
  const buffer = new ArrayBuffer(hasCursor ? 36 : 28);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_ListAssetsPaged, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setUint16(10, assetType, false);
  view.setUint8(12, fullContent ? 1 : 0);
  view.setUint16(13, limit, false);
  view.setUint8(15, hasCursor ? 1 : 0);
  if (hasCursor) {
    view.setBigInt64(16, BigInt(cursorUpdatedAt), false);
    view.setBigUint64(24, BigInt(cursorAssetId), false);
    view.setUint32(32, correlationId, false);
  } else {
    // correlation_id must be immediate when no cursor is present.
    view.setUint32(16, correlationId, false);
    view.setBigUint64(20, 0n, false);
  }

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "list_paged",
    originOpcode: AssetOriginOpcode.ListPaged,
    convId: BigInt(convId),
    assetId: null,
    assetType,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
    snapshotStartVersion: opts?.snapshotStartVersion,
  });

  sendPacket(buffer);

  return correlationId;
}

// Load a complete preview snapshot. Pages are byte bounded, so hasMore rather
// than page length is authoritative. Mutations received while loading win over
// page data and are not removed by snapshot reconciliation.
function requestAllAssets(convId, assetType, options = {}) {
  const normalizedConvId = 0n;
  const limit = options.limit ?? 100;
  const startVersion = assetMutationSequence;
  const snapshot = new Map();

  return new Promise((resolve, reject) => {
    const fail = (message) => reject(message instanceof Error ? message : new Error(message));
    const cancelled = () => typeof options.isCancelled === "function" && options.isCancelled();

    const requestPage = (cursorUpdatedAt = null, cursorAssetId = null) => {
      if (cancelled()) return fail("Asset pagination cancelled");
      if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) {
        return fail("Connection is not ready for asset pagination");
      }

      const correlationId = sendListAssetsPaged(
        normalizedConvId, assetType, options.fullContent === true, limit, cursorUpdatedAt, cursorAssetId,
        {
          context: options.context,
          snapshotStartVersion: startVersion,
          onSuccess(detail) {
            if (cancelled()) return fail("Asset pagination cancelled");
            for (const asset of detail.assets) snapshot.set(asset.assetId, asset);
            if (detail.hasMore) {
              if (detail.nextCursorUpdatedAt === cursorUpdatedAt && detail.nextCursorAssetId === cursorAssetId) {
                return fail("Asset pagination cursor did not advance");
              }
              requestPage(detail.nextCursorUpdatedAt, detail.nextCursorAssetId);
              return;
            }

            if (!roomAssets.has(normalizedConvId)) roomAssets.set(normalizedConvId, new Map());
            const cache = roomAssets.get(normalizedConvId);
            for (const [assetId, cached] of cache) {
              if (cached.assetType === assetType && !snapshot.has(assetId) &&
                  (assetMutationVersions.get(assetMutationKey(normalizedConvId, assetId)) ?? 0) <= startVersion) {
                cache.delete(assetId);
                window.NRCCustomers?.onAssetDeleted?.(normalizedConvId, assetId);
              }
            }
            const assets = Array.from(cache.values()).filter((asset) => asset.assetType === assetType);
            if (assetType === AssetType.Note && onNoteChanged) onNoteChanged({ convId: normalizedConvId }, "cache");
            resolve({ assets });
          },
          onError(detail) { fail(detail?.message || "Asset pagination failed"); },
        },
      );
      if (!correlationId) fail("Connection is not ready for asset pagination");
    };

    requestPage();
  });
}

function requestCustomerPage(convId, options = {}) {
  convId = 0n;
  const query = new TextEncoder().encode(options.query ?? "");
  return new Promise((resolve, reject) => {
    if (query.length > 256) return reject(new Error("Search is limited to 256 UTF-8 bytes"));
    if (!ws || ws.readyState !== WebSocket.OPEN) return reject(new Error("Not connected"));
    const correlationId = generateCorrelationId();
    const buffer = new ArrayBuffer(27 + query.length);
    const view = new DataView(buffer);
    view.setUint16(0, Opcode.C_SearchCustomers);
    view.setBigUint64(2, BigInt(convId));
    view.setUint16(10, options.limit ?? 50);
    view.setBigUint64(12, options.afterId ?? 0n);
    view.setUint8(20, options.includeArchived ? 1 : 0);
    view.setUint16(21, query.length);
    new Uint8Array(buffer, 23, query.length).set(query);
    view.setUint32(23 + query.length, correlationId);
    registerPendingAssetRpc(correlationId, {
      kind: "customer_search", originOpcode: AssetOriginOpcode.SearchCustomers, convId: BigInt(convId),
      snapshotStartVersion: assetMutationSequence,
      isCancelled: options.isCancelled,
      onSuccess: resolve, onError: detail => reject(new Error(detail.message || "Customer search failed")),
    });
    sendPacket(buffer);
  });
}

function handleCustomerSearchPage(view) {
  const correlationId = view.getUint32(25);
  const pending = pendingAssetRpcByCorrelation.get(correlationId);
  if (!pending) return;
  const convId = view.getBigUint64(2);
  if (pending.isCancelled?.() || pending.convId !== convId) {
    settlePendingAssetRpc(correlationId, false, { message: "Customer search cancelled" });
    return;
  }
  const assets = [];
  let offset = 29;
  for (let i = 0; i < view.getUint16(23); i++) {
    const parsed = parseAsset(view, offset);
    offset = parsed.newOffset;
    const version = assetMutationVersions.get(assetMutationKey(convId, parsed.asset.assetId)) ?? 0;
    if (version <= pending.snapshotStartVersion) storeAsset(parsed.asset);
    const asset = roomAssets.get(convId)?.get(parsed.asset.assetId);
    if (asset) assets.push(asset);
  }
  settlePendingAssetRpc(correlationId, true, {
    convId, assets, hasMore: view.getUint8(10) === 1, nextId: view.getBigUint64(11), totalCount: view.getUint32(19),
  });
}

function sendListAssetsPagedByProject(
  convId,
  assetType,
  project,
  fullContent = false,
  limit = 50,
  cursorUpdatedAt = null,
  cursorAssetId = null,
  requestOptions = null,
) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) {
    const key = `list_paged_project:${convId.toString()}:${String(assetType)}:${project}:${fullContent ? 1 : 0}:${limit}`;
    pendingAssetRequests.set(key, {
      type: "list_paged_project",
      convId,
      assetType,
      project,
      fullContent,
      limit,
      cursorUpdatedAt,
      cursorAssetId,
    });
    return 0;
  }

  const correlationId = generateCorrelationId();

  const hasCursor = cursorUpdatedAt !== null && cursorAssetId !== null;
  const projectBytes = assetTextEncoder.encode(project);
  const baseSize = hasCursor ? 34 : 18; // opcode(2) + conv_id(8) + asset_type(2) + full_content(1) + limit(2) + has_cursor(1) + [cursor(16)] + project_len(2)
  const buffer = new ArrayBuffer(baseSize + projectBytes.length + 4);
  const view = new DataView(buffer);

  let offset = 0;
  view.setUint16(offset, Opcode.C_ListAssetsPagedByProject, false);
  offset += 2;
  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;
  view.setUint16(offset, assetType, false);
  offset += 2;
  view.setUint8(offset, fullContent ? 1 : 0);
  offset += 1;
  view.setUint16(offset, limit, false);
  offset += 2;
  view.setUint8(offset, hasCursor ? 1 : 0);
  offset += 1;
  if (hasCursor) {
    view.setBigInt64(offset, BigInt(cursorUpdatedAt), false);
    offset += 8;
    view.setBigUint64(offset, BigInt(cursorAssetId), false);
    offset += 8;
  }
  view.setUint16(offset, projectBytes.length, false);
  offset += 2;
  new Uint8Array(buffer).set(projectBytes, offset);
  offset += projectBytes.length;
  view.setUint32(offset, correlationId, false);

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "list_paged_project",
    originOpcode: AssetOriginOpcode.ListPagedByProject,
    convId: BigInt(convId),
    assetId: null,
    assetType,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendListAssetsPagedByTag(
  convId,
  assetType,
  tag,
  fullContent = false,
  limit = 50,
  cursorUpdatedAt = null,
  cursorAssetId = null,
  requestOptions = null,
) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) {
    const key = `list_paged_tag:${convId.toString()}:${String(assetType)}:${tag}:${fullContent ? 1 : 0}:${limit}`;
    pendingAssetRequests.set(key, {
      type: "list_paged_tag",
      convId,
      assetType,
      tag,
      fullContent,
      limit,
      cursorUpdatedAt,
      cursorAssetId,
    });
    return 0;
  }

  const correlationId = generateCorrelationId();

  const hasCursor = cursorUpdatedAt !== null && cursorAssetId !== null;
  const tagBytes = assetTextEncoder.encode(tag);
  const baseSize = hasCursor ? 34 : 18;
  const buffer = new ArrayBuffer(baseSize + tagBytes.length + 4);
  const view = new DataView(buffer);

  let offset = 0;
  view.setUint16(offset, Opcode.C_ListAssetsPagedByTag, false);
  offset += 2;
  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;
  view.setUint16(offset, assetType, false);
  offset += 2;
  view.setUint8(offset, fullContent ? 1 : 0);
  offset += 1;
  view.setUint16(offset, limit, false);
  offset += 2;
  view.setUint8(offset, hasCursor ? 1 : 0);
  offset += 1;
  if (hasCursor) {
    view.setBigInt64(offset, BigInt(cursorUpdatedAt), false);
    offset += 8;
    view.setBigUint64(offset, BigInt(cursorAssetId), false);
    offset += 8;
  }
  view.setUint16(offset, tagBytes.length, false);
  offset += 2;
  new Uint8Array(buffer).set(tagBytes, offset);
  offset += tagBytes.length;
  view.setUint32(offset, correlationId, false);

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "list_paged_tag",
    originOpcode: AssetOriginOpcode.ListPagedByTag,
    convId: BigInt(convId),
    assetId: null,
    assetType,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendListNoteProjects(convId, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) {
    const key = `list_projects:${convId.toString()}`;
    pendingAssetRequests.set(key, {
      type: "list_projects",
      convId,
    });
    return 0;
  }

  const correlationId = generateCorrelationId();

  const buffer = new ArrayBuffer(14); // opcode(2) + conv_id(8) + correlation_id(4)
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_ListNoteProjects, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setUint32(10, correlationId, false);

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "list_projects",
    originOpcode: AssetOriginOpcode.ListProjects,
    convId: BigInt(convId),
    assetId: null,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendListNoteTags(convId, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) {
    const key = `list_tags:${convId.toString()}`;
    pendingAssetRequests.set(key, {
      type: "list_tags",
      convId,
    });
    return 0;
  }

  const correlationId = generateCorrelationId();

  const buffer = new ArrayBuffer(14);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_ListNoteTags, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setUint32(10, correlationId, false);

  const opts = normalizeAssetRequestOptions(requestOptions);
  registerPendingAssetRpc(correlationId, {
    kind: "list_tags",
    originOpcode: AssetOriginOpcode.ListTags,
    convId: BigInt(convId),
    assetId: null,
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

// =============================================================================
// COMMENT HELPERS
// =============================================================================

function sendCreateComment(convId, taskId, text) {
  sendCreateAsset(
    convId,
    AssetType.Comment,
    ParentType.Task,
    BigInt(taskId),
    text.slice(0, 100), // Preview is first 100 chars
    text,
  );
}

function sendCreateAssetComment(convId, assetId, text) {
  sendCreateAsset(
    convId,
    AssetType.Comment,
    ParentType.Asset,
    BigInt(assetId),
    text.slice(0, 100),
    text,
  );
}

function sendDeleteComment(convId, assetId) {
  sendDeleteAsset(convId, assetId);
}

function sendListComments(convId) {
  sendListAssets(convId, AssetType.Comment, true);
}

function sortCommentsByCreatedAt(comments) {
  return comments.sort((a, b) => {
    if (a.createdAt < b.createdAt) return -1;
    if (a.createdAt > b.createdAt) return 1;
    return 0;
  });
}

function getCommentsForTask(convId, taskId) {
  const taskIdBigInt = BigInt(taskId);
  return sortCommentsByCreatedAt(
    getAssetsByType(convId, AssetType.Comment)
      .filter((a) => a.parentType === ParentType.Task && a.parentId === taskIdBigInt),
  );
}

function getCommentsForAsset(convId, assetId) {
  const assetIdBigInt = BigInt(assetId);
  return sortCommentsByCreatedAt(
    getAssetsByType(convId, AssetType.Comment)
      .filter((a) => a.parentType === ParentType.Asset && a.parentId === assetIdBigInt),
  );
}

function getCommentCount(convId, taskId) {
  return getCommentsForTask(convId, taskId).length;
}

function getAssetCommentCount(convId, assetId) {
  return getCommentsForAsset(convId, assetId).length;
}

// Callback for comment changes (set by tasks.js)
let onCommentChanged = null;
const commentChangeListeners = new Set();

function setOnCommentChanged(callback) {
  onCommentChanged = callback;
}

function addCommentChangeListener(callback) {
  if (typeof callback !== "function") return () => {};
  commentChangeListeners.add(callback);
  return () => commentChangeListeners.delete(callback);
}

function notifyCommentChanged(asset, action) {
  if (onCommentChanged) {
    onCommentChanged(asset, action);
  }
  for (const listener of commentChangeListeners) {
    listener(asset, action);
  }
}

// =============================================================================
// NOTE CALLBACK (set by notes.js)
// =============================================================================

let onNoteChanged = null;
let onReminderChanged = null;

function setOnNoteChanged(callback) {
  onNoteChanged = callback;
}

function setOnReminderChanged(callback) {
  onReminderChanged = callback;
}

// =============================================================================
// WIRE PROTOCOL - RECEIVE
// =============================================================================

function parseAsset(dataView, offset, includeAttachments = true) {
  const assetType = dataView.getUint16(offset, false);
  offset += 2;

  const assetId = dataView.getBigUint64(offset, false);
  offset += 8;

  const parentType = dataView.getUint16(offset, false);
  offset += 2;

  const parentId = dataView.getBigUint64(offset, false);
  offset += 8;

  const ownerLen = dataView.getUint16(offset, false);
  offset += 2;
  const ownerBytes = new Uint8Array(dataView.buffer, offset, ownerLen);
  const owner = assetTextDecoder.decode(ownerBytes);
  offset += ownerLen;

  const createdAt = dataView.getBigInt64(offset, false);
  offset += 8;

  const updatedAt = dataView.getBigInt64(offset, false);
  offset += 8;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const payloadEncoding = dataView.getUint8(offset);
  offset += 1;

  const payloadRawLen = dataView.getUint32(offset, false);
  offset += 4;

  const previewLen = dataView.getUint16(offset, false);
  offset += 2;
  const previewBytes = new Uint8Array(dataView.buffer, offset, previewLen);
  const preview = assetTextDecoder.decode(previewBytes);
  offset += previewLen;

  let attachments = [];
  if (includeAttachments) {
    const parsedAttachments = parseAssetAttachments(dataView, offset);
    attachments = parsedAttachments.attachments;
    offset = parsedAttachments.newOffset;
  }

  return {
    asset: {
      assetType,
      assetId,
      parentType,
      parentId,
      owner,
      createdAt,
      updatedAt,
      convId,
      payloadEncoding,
      payloadRawLen,
      preview,
      payload: null, // Only set by parseAssetFull
      attachments,
    },
    newOffset: offset,
  };
}

function parseAssetFull(dataView, offset) {
  const { asset, newOffset } = parseAsset(dataView, offset, false);
  offset = newOffset;

  const payloadLen = dataView.getUint16(offset, false);
  offset += 2;
  const payloadBytes = new Uint8Array(dataView.buffer.slice(offset, offset + payloadLen));
  try {
    asset.payload = decodeAssetPayloadFromWire(asset.payloadEncoding, asset.payloadRawLen, payloadBytes);
  } catch (error) {
    console.error("[assets] Failed to decode asset payload", {
      assetId: asset.assetId.toString(),
      convId: asset.convId.toString(),
      payloadEncoding: asset.payloadEncoding,
      payloadRawLen: asset.payloadRawLen,
      payloadLen,
      error,
    });
    asset.payload = null;
  }
  offset += payloadLen;

  const parsedAttachments = parseAssetAttachments(dataView, offset);
  asset.attachments = parsedAttachments.attachments;
  offset = parsedAttachments.newOffset;

  return { asset, newOffset: offset };
}

function handleAssetCreated(dataView) {
  const { asset, newOffset } = parseAssetFull(dataView, 2);
  if (dataView.byteLength < newOffset + 4) {
    console.error("S_AssetCreated missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(newOffset, false);

  settlePendingAssetRpc(correlationId, true, {
    kind: "create",
    asset,
    correlationId,
  });

  markAssetMutation(asset.convId, asset.assetId);
  storeAsset(asset, "mutation", correlationId);

  if (asset.assetType === AssetType.Agenda && asset.convId === 0n) {
    updateAgendaDisplay();
  }

  if (asset.assetType === AssetType.Comment) {
    notifyCommentChanged(asset, "created");
  }

  if (asset.assetType === AssetType.Note && onNoteChanged) {
    onNoteChanged(asset, "created");
  }

  if (asset.assetType === AssetType.Reminder && onReminderChanged) {
    onReminderChanged(asset, "created");
  }

  if (asset.assetType === AssetType.RoomMapping) {
    window.NRCRooms?.handleRoomMappingAsset?.(asset);
  }

  document.dispatchEvent(new CustomEvent("nrc:asset-created", { detail: { asset, correlationId } }));
}

function handleAssetUpdated(dataView) {
  const { asset, newOffset } = parseAssetFull(dataView, 2);
  if (dataView.byteLength < newOffset + 4) {
    console.error("S_AssetUpdated missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(newOffset, false);

  settlePendingAssetRpc(correlationId, true, {
    kind: "update",
    asset,
    correlationId,
  });

  markAssetMutation(asset.convId, asset.assetId);
  storeAsset(asset, "mutation", correlationId);

  if (asset.assetType === AssetType.Agenda && asset.convId === 0n) {
    updateAgendaDisplay();
  }

  if (asset.assetType === AssetType.Comment) {
    notifyCommentChanged(asset, "updated");
  }

  if (asset.assetType === AssetType.Note && onNoteChanged) {
    onNoteChanged(asset, "updated");
  }

  if (asset.assetType === AssetType.Reminder && onReminderChanged) {
    onReminderChanged(asset, "updated");
  }

  if (asset.assetType === AssetType.RoomMapping) {
    window.NRCRooms?.handleRoomMappingAsset?.(asset);
  }

  document.dispatchEvent(new CustomEvent("nrc:asset-updated", { detail: { asset, correlationId } }));
}

function handleAssetDeleted(dataView) {
  const convId = dataView.getBigUint64(2, false);
  const assetId = dataView.getBigUint64(10, false);
  if (dataView.byteLength < 22) {
    console.error("S_AssetDeleted missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(18, false);
  markAssetMutation(convId, assetId);
  const deletedAsset = roomAssets.get(convId)?.get(assetId) || null;

  settlePendingAssetRpc(correlationId, true, {
    kind: "delete",
    convId,
    assetId,
    correlationId,
  });

  // A slice owns a register of its own, and it has to refresh whether or not the
  // deleted asset happened to be cached here: a slice removed by another client
  // must not stay on screen as a record that no longer exists.
  if (convId === 0n) {
    window.NRCSlices?.onAssetDeleted?.(convId, assetId);
    // Calendar owns summaries, so the full asset need not be cached here.
    window.NRCCalendar?.refreshSoon();
  }

  if (roomAssets.has(convId)) {
    const assets = roomAssets.get(convId);
    const asset = assets.get(assetId);
    assets.delete(assetId);
    window.NRCCustomers?.onAssetDeleted?.(convId, assetId);
    window.NRCFiles?.refresh();

    if (
      asset &&
      asset.assetType === AssetType.Agenda &&
      convId === 0n
    ) {
      updateAgendaDisplay();
    }

    if (asset && asset.assetType === AssetType.Comment) {
      notifyCommentChanged(asset, "deleted");
    }

    if (asset && asset.assetType === AssetType.Note && onNoteChanged) {
      onNoteChanged(asset, "deleted");
    }

    if (asset && asset.assetType === AssetType.Reminder && onReminderChanged) {
      onReminderChanged(asset, "deleted");
    }

    if (asset && asset.assetType === AssetType.RoomMapping) {
      window.NRCRooms?.handleRoomMappingDeleted?.(asset);
    }
  }
  document.dispatchEvent(new CustomEvent("nrc:asset-deleted", { detail: { convId, assetId, asset: deletedAsset, correlationId } }));
}

function handleAssetFull(dataView) {
  const { asset, newOffset } = parseAssetFull(dataView, 2);
  if (dataView.byteLength < newOffset + 4) {
    console.error("S_AssetFull missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(newOffset, false);

  if (asset.payload === null) {
    settlePendingAssetRpc(correlationId, false, {
      kind: "get", correlationId, message: "Failed to decode asset payload",
    });
    return;
  }
  // Success callbacks may synchronously request this entity again.
  const previousAsset = roomAssets.get(asset.convId)?.get(asset.assetId) || null;
  storeAsset(asset);
  settlePendingAssetRpc(correlationId, true, {
    kind: "get",
    asset,
    correlationId,
  });

  if (asset.assetType === AssetType.Agenda && asset.convId === 0n) {
    updateAgendaDisplay();
  }

  // Notify comment callback for full asset fetches (refreshes detail panel)
  if (asset.assetType === AssetType.Comment) {
    notifyCommentChanged(asset, "fetched");
  }

  // Notify note callback for full asset fetches (shows detail panel with content)
  if (asset.assetType === AssetType.Note && onNoteChanged) {
    onNoteChanged(asset, "fetched", previousAsset);
  }

  if (asset.assetType === AssetType.Reminder && onReminderChanged) {
    onReminderChanged(asset, "fetched");
  }

  if (asset.assetType === AssetType.RoomMapping) {
    window.NRCRooms?.handleRoomMappingAsset?.(asset);
  }
}

function handleAssetList(dataView) {
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const fullContent = dataView.getUint8(offset) === 1;
  offset += 1;

  const count = dataView.getUint16(offset, false);
  offset += 2;

  if (dataView.byteLength < offset + 4) {
    console.error("S_AssetList missing correlation_id");
    return 0;
  }
  const correlationId = dataView.getUint32(offset, false);
  offset += 4;

  // Clear existing assets for this room (only if we have data)
  if (!roomAssets.has(convId)) {
    roomAssets.set(convId, new Map());
  }

  const listedAssets = [];
  for (let i = 0; i < count; i++) {
    let asset, newOffset;
    if (fullContent) {
      ({ asset, newOffset } = parseAssetFull(dataView, offset));
    } else {
      ({ asset, newOffset } = parseAsset(dataView, offset));
    }
    offset = newOffset;
    storeAsset(asset);
    listedAssets.push(asset);
    if (asset.assetType === AssetType.RoomMapping) {
      window.NRCRooms?.handleRoomMappingAsset?.(asset);
    }
  }

  const pending = settlePendingAssetRpc(correlationId, true, {
    kind: "list", convId, count, fullContent, correlationId, assets: listedAssets,
  });

  // Update agenda display if this is current room
  if (convId === 0n) {
    updateAgendaDisplay();
  }

  // Notify notes callback to re-render notes view after list fetch
  if (convId === 0n && onNoteChanged) {
    onNoteChanged(null, "list");
  }

  if (convId === 0n && onReminderChanged) {
    onReminderChanged(null, "list");
  }

  if (pending?.assetType === AssetType.Comment) {
    notifyCommentChanged({ convId }, "list");
  }

  return correlationId;
}

function handleAssetListPage(dataView) {
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const fullContent = dataView.getUint8(offset) === 1;
  offset += 1;

  const hasMore = dataView.getUint8(offset) === 1;
  offset += 1;

  const nextCursorUpdatedAt = dataView.getBigInt64(offset, false);
  offset += 8;

  const nextCursorAssetId = dataView.getBigUint64(offset, false);
  offset += 8;

  const totalCount = dataView.getUint32(offset, false);
  offset += 4;

  const count = dataView.getUint16(offset, false);
  offset += 2;

  if (dataView.byteLength < offset + 4) {
    console.error("S_AssetListPage missing correlation_id");
    return 0;
  }
  const correlationId = dataView.getUint32(offset, false);
  offset += 4;
  const pending = pendingAssetRpcByCorrelation.get(correlationId);

  if (!roomAssets.has(convId)) {
    roomAssets.set(convId, new Map());
  }

  const assets = [];
  for (let i = 0; i < count; i++) {
    let asset, newOffset;
    if (fullContent) {
      ({ asset, newOffset } = parseAssetFull(dataView, offset));
    } else {
      ({ asset, newOffset } = parseAsset(dataView, offset));
    }
    offset = newOffset;
    assets.push(asset);
    const version = assetMutationVersions.get(assetMutationKey(convId, asset.assetId)) ?? 0;
    if (pending?.snapshotStartVersion == null || version <= pending.snapshotStartVersion) storeAsset(asset);
  }

  settlePendingAssetRpc(correlationId, true, {
    kind: "list_paged", convId, count, hasMore, nextCursorUpdatedAt,
    nextCursorAssetId, totalCount, fullContent, correlationId, assets,
  });

  if (onNoteChanged && pending?.assetType === AssetType.Note && pending.snapshotStartVersion != null) {
    onNoteChanged({ convId }, "cache");
  }
  if (onNoteChanged && pending?.assetType === AssetType.Note && pending.snapshotStartVersion == null) {
    onNoteChanged(
      {
        convId,
        count,
        hasMore,
        nextCursorUpdatedAt,
        nextCursorAssetId,
        totalCount,
        correlationId,
      },
      "list_page",
    );
  }

  return correlationId;
}

function handleNoteProjectList(dataView) {
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const count = dataView.getUint16(offset, false);
  offset += 2;

  if (dataView.byteLength < offset + 4) {
    console.error("S_NoteProjectList missing correlation_id");
    return 0;
  }
  const correlationId = dataView.getUint32(offset, false);
  offset += 4;

  const projects = [];
  for (let i = 0; i < count; i++) {
    if (dataView.byteLength < offset + 2) break;
    const projectLen = dataView.getUint16(offset, false);
    offset += 2;
    if (dataView.byteLength < offset + projectLen) break;
    const projectBytes = new Uint8Array(dataView.buffer, offset, projectLen);
    projects.push(assetTextDecoder.decode(projectBytes));
    offset += projectLen;
  }

  settlePendingAssetRpc(correlationId, true, {
    kind: "list_projects",
    convId,
    count,
    projects,
    correlationId,
  });

  // Notify notes callback
  if (convId === 0n && onNoteChanged) {
    onNoteChanged({ convId, projects, correlationId }, "project_list");
  }

  return correlationId;
}

function handleNoteTagList(dataView) {
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const count = dataView.getUint16(offset, false);
  offset += 2;

  if (dataView.byteLength < offset + 4) {
    console.error("S_NoteTagList missing correlation_id");
    return 0;
  }
  const correlationId = dataView.getUint32(offset, false);
  offset += 4;

  const tags = [];
  for (let i = 0; i < count; i++) {
    if (dataView.byteLength < offset + 2) break;
    const tagLen = dataView.getUint16(offset, false);
    offset += 2;
    if (dataView.byteLength < offset + tagLen) break;
    const tagBytes = new Uint8Array(dataView.buffer, offset, tagLen);
    tags.push(assetTextDecoder.decode(tagBytes));
    offset += tagLen;
  }

  settlePendingAssetRpc(correlationId, true, {
    kind: "list_tags",
    convId,
    count,
    tags,
    correlationId,
  });

  if (convId === 0n && onNoteChanged) {
    onNoteChanged({ convId, tags, correlationId }, "tag_list");
  }

  return correlationId;
}

function handleAssetErrorResponse(originOpcode, correlationId, errorMsg = "") {
  const kind = getAssetRequestKindFromOriginOpcode(originOpcode);
  if (!kind) {
    return false;
  }

  const pending = settlePendingAssetRpc(correlationId, false, {
    kind,
    originOpcode,
    correlationId,
    message: errorMsg,
  });

  if (!pending) {
    return true;
  }

  const contextText = pending.context || formatAssetRequestContext(pending);
  const label = getAssetRequestLabel(pending.kind || kind);
  const message = (errorMsg || "Unknown server error").trim();
  const isAssetNotFound = /asset not found/i.test(message);

  if (
    pending.kind === "update" &&
    pending.assetType === AssetType.Note &&
    pending.assetId != null &&
    isAssetNotFound
  ) {
    if (typeof window.NRCNotes?.clearNoteSelection === "function") {
      window.NRCNotes.clearNoteSelection();
    }
    logMessage("Error", `NOTE #${pending.assetId} NO LONGER EXISTS IN THIS ROOM`);
  }

  if (
    pending.kind === "delete" &&
    pending.assetType === AssetType.Note &&
    pending.assetId != null &&
    isAssetNotFound
  ) {
    if (typeof window.NRCNotes?.clearNoteSelection === "function") {
      window.NRCNotes.clearNoteSelection();
    }
  }

  if (
    pending.kind === "update" &&
    pending.assetType === AssetType.Reminder &&
    pending.assetId != null &&
    isAssetNotFound
  ) {
    if (typeof window.NRCTasks?.clearReminderSelection === "function") {
      window.NRCTasks.clearReminderSelection();
    }
  }

  if (
    pending.kind === "delete" &&
    pending.assetType === AssetType.Reminder &&
    pending.assetId != null &&
    isAssetNotFound
  ) {
    if (typeof window.NRCTasks?.clearReminderSelection === "function") {
      window.NRCTasks.clearReminderSelection();
    }
  }

  if (
    pending.kind === "delete" &&
    pending.assetType === AssetType.Comment &&
    pending.assetId != null &&
    isAssetNotFound
  ) {
    if (typeof window.NRCTasks?.clearTaskSelection === "function") {
      window.NRCTasks.clearTaskSelection();
    }
  }

  logMessage("Error", `ASSET ${label} FAILED (${contextText}): ${message}`);
  return true;
}

function clearPendingAssetRpc() {
  for (const [correlationId, pending] of pendingAssetRpcByCorrelation) {
    settlePendingAssetRpc(correlationId, false, {
      kind: pending.kind,
      originOpcode: pending.originOpcode,
      correlationId,
      message: "Connection closed before the server acknowledged the request",
    });
  }
}

// =============================================================================
// STORAGE HELPERS
// =============================================================================

function storeAsset(asset, reason = "cache", correlationId = null) {
  if (!roomAssets.has(asset.convId)) {
    roomAssets.set(asset.convId, new Map());
  }
  const roomMap = roomAssets.get(asset.convId);
  const existing = roomMap.get(asset.assetId);
  
  // Preserve payload if incoming asset doesn't have it (e.g., from list response)
  // Check for null specifically - empty string "" is a valid payload
  if (existing && existing.payload != null && asset.payload === null && existing.updatedAt === asset.updatedAt) {
    asset.payload = existing.payload;
  }
  
  roomMap.set(asset.assetId, asset);
  window.NRCSlices?.onAssetChanged?.(asset, reason, correlationId);
  window.NRCCustomers?.onAssetChanged?.(asset, reason);
  window.NRCFiles?.refresh();
}

function getAssetsForRoom(roomId) {
  const assets = roomAssets.get(roomId);
  return assets ? Array.from(assets.values()) : [];
}

function getAssetsByType(roomId, assetType) {
  return getAssetsForRoom(roomId).filter((a) => a.assetType === assetType);
}

function getAgendaAsset(roomId) {
  const agendas = getAssetsByType(roomId, AssetType.Agenda);
  return agendas.length > 0 ? agendas[0] : null;
}

// =============================================================================
// AGENDA INTEGRATION
// =============================================================================

function sendSetAgendaViaAsset(convId, content, requestOptions = null) {
  const existing = getAgendaAsset(convId);

  if (existing) {
    // Update existing agenda asset
    return sendUpdateAsset(convId, existing.assetId, content, content, AssetType.Agenda, 0, requestOptions);
  } else {
    // Create new agenda asset
    return sendCreateAsset(
      convId,
      AssetType.Agenda,
      ParentType.None,
      0n,
      content,
      content,
      0,
      requestOptions,
    );
  }
}

function sendGetAgendaViaAsset(convId) {
  sendListAssets(convId, AssetType.Agenda);
}

function sendGetAllAssets(convId) {
  // Fetch non-note assets required for default room rendering.
  // Notes are paginated in notes.js via C_ListAssetsPaged.
  sendListAssets(convId, AssetType.Agenda, false);
  // Fetch comments with full content (needed for comment counts and detail view)
  sendListComments(convId);
  // Fetch reminders with full content for urgency sorting
  sendListAssets(convId, AssetType.Reminder, true);
}

function sendGetRoomMappings() {
  return sendListAssets(0n, AssetType.RoomMapping, true);
}

function notifyPendingGetSubscribers(subscribers, callbackName, detail, pending) {
  for (const subscriber of subscribers) {
    const callback = subscriber[callbackName];
    if (typeof callback !== "function") continue;
    try {
      callback(detail, { ...pending, context: subscriber.context });
    } catch (error) {
      console.error(`[assets] Pending GET ${callbackName} callback failed`, error);
    }
  }
}

// Retry pending requests on reconnect
function retryPendingAssetRequests() {
  const requests = Array.from(pendingAssetRequests.values());
  pendingAssetRequests.clear();

  for (const req of requests) {
    if (req.type === "get") {
      const subscribers = req.subscribers || [];
      sendGetAsset(req.convId, req.assetId, subscribers.length > 0 ? {
        context: `retry get asset ${req.assetId}`,
        onSuccess: (detail, pending) => {
          notifyPendingGetSubscribers(subscribers, "onSuccess", detail, pending);
        },
        onError: (detail, pending) => {
          notifyPendingGetSubscribers(subscribers, "onError", detail, pending);
        },
      } : null);
    } else if (req.type === "list") {
      sendListAssets(req.convId, req.assetType, req.fullContent || false);
    } else if (req.type === "list_paged") {
      sendListAssetsPaged(
        req.convId,
        req.assetType,
        req.fullContent || false,
        req.limit || 50,
        req.cursorUpdatedAt ?? null,
        req.cursorAssetId ?? null,
      );
    } else if (req.type === "list_paged_project") {
      sendListAssetsPagedByProject(
        req.convId,
        req.assetType,
        req.project,
        req.fullContent || false,
        req.limit || 50,
        req.cursorUpdatedAt ?? null,
        req.cursorAssetId ?? null,
      );
    } else if (req.type === "list_paged_tag") {
      sendListAssetsPagedByTag(
        req.convId,
        req.assetType,
        req.tag,
        req.fullContent || false,
        req.limit || 50,
        req.cursorUpdatedAt ?? null,
        req.cursorAssetId ?? null,
      );
    } else if (req.type === "list_projects") {
      sendListNoteProjects(req.convId);
    } else if (req.type === "list_tags") {
      sendListNoteTags(req.convId);
    }
  }
}

// =============================================================================
// ROOM SWITCHING
// =============================================================================

function onAssetRoomSwitch() {
  // Fetch all assets with full content
  sendGetAllAssets(0n);
}

// =============================================================================
// INITIALIZATION
// =============================================================================

function initAssets() {
  // Warm codec initialization so compressed payloads are ready before first asset traffic.
  return ensureZstdCodec();
}

function generateCorrelationId() {
  const id = nextCorrelationId;
  nextCorrelationId = (nextCorrelationId + 1) & 0xFFFFFFFF;
  if (nextCorrelationId === 0) nextCorrelationId = 1; // skip 0
  return id;
}

// Export for use in app.js
window.NRCAssets = {
  // Handlers
  handleAssetCreated,
  handleAssetUpdated,
  handleAssetDeleted,
  handleAssetFull,
  handleAssetList,
  handleAssetListPage,
  handleCustomerSearchPage,
  handleNoteProjectList,
  handleNoteTagList,

  // Send functions
  sendCreateAsset,
  sendUpdateAsset,
  sendDeleteAsset,
  sendGetAsset,
  requestAsset,
  sendListAssets,
  sendListAssetsPaged,
  requestAllAssets,
  requestCustomerPage,
  sendListAssetsPagedByProject,
  sendListNoteProjects,
  sendListAssetsPagedByTag,
  sendListNoteTags,

  // Agenda helpers
  sendSetAgendaViaAsset,
  sendGetAgendaViaAsset,
  sendGetAllAssets,
  sendGetRoomMappings,
  getAgendaAsset,

  // Comment helpers
  sendCreateComment,
  sendCreateAssetComment,
  sendDeleteComment,
  sendListComments,
  getCommentsForTask,
  getCommentsForAsset,
  getCommentCount,
  getAssetCommentCount,
  setOnCommentChanged,
  addCommentChangeListener,
  sendGetAsset,

  // Note callback (notes.js handles the rest)
  setOnNoteChanged,
  setOnReminderChanged,

  // Storage
  getAssetsForRoom,
  getAssetsByType,
  roomAssets,

  // Labels
  getAssetTypeLabel,

  // Lifecycle
  initAssets,
  onAssetRoomSwitch,
  retryPendingAssetRequests,
  clearPendingAssetRpc,

  // Correlation
  generateCorrelationId,
  handleAssetErrorResponse,

  // Constants
  AssetType,
  ParentType,
  PayloadEncoding,
  MAX_PREVIEW_LENGTH,
  MAX_PAYLOAD_LENGTH,
};

initAssets();
