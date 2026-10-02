// Atomic transaction helpers. This module intentionally does not update the
// asset/edge caches: the transaction result identifies committed entities but
// does not contain their complete broadcast representation.

const TRANSACTION_WIRE_VERSION = 1;
const TRANSACTION_FAILED_NONE = 0xffff;
const TRANSACTION_MAX_PREVIEW_LENGTH = 4096;
const TRANSACTION_MAX_PAYLOAD_LENGTH = 65535;

const TransactionOpcode = {
  Apply: 27,
};

const TransactionOperation = {
  AssetCreate: 3,
  AssetPatch: 4,
  EdgeCreate: 5,
};

const TransactionEntity = {
  Asset: 2,
};

const TransactionReference = {
  Existing: 0,
  CreatedBy: 1,
};

const pendingTransactionRpc = new Map();
const transactionTextEncoder = new TextEncoder();

function transactionUint64(value, name) {
  let result;
  try {
    result = BigInt(value);
  } catch (_) {
    throw new TypeError(`${name} must be an unsigned 64-bit integer`);
  }
  if (result < 0n || result > 0xffffffffffffffffn) {
    throw new RangeError(`${name} must be an unsigned 64-bit integer`);
  }
  return result;
}

function transactionUint16(value, name) {
  if (!Number.isInteger(value) || value < 0 || value > 0xffff) {
    throw new RangeError(`${name} must be an unsigned 16-bit integer`);
  }
  return value;
}

function writeTransactionReference(view, offset, kind, value) {
  view.setUint8(offset, kind);
  view.setUint8(offset + 1, TransactionEntity.Asset);
  view.setUint16(offset + 2, 0, false);
  view.setBigUint64(offset + 4, value, false);
  return offset + 12;
}

function settleTransaction(correlationId, ok, detail) {
  const pending = pendingTransactionRpc.get(correlationId);
  if (!pending) return null;
  pendingTransactionRpc.delete(correlationId);
  const callback = ok ? pending.onSuccess : pending.onError;
  if (typeof callback === "function") {
    try {
      callback(detail, pending);
    } catch (error) {
      console.error("[transactions] Pending request callback failed", error);
    }
  }
  return pending;
}

function sendCreateLinkedAsset(convId, assetType, preview, payload, companyId, options = null) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  if (!window.NRCAssets || typeof window.NRCAssets.generateCorrelationId !== "function") {
    throw new Error("NRCAssets.generateCorrelationId is unavailable");
  }

  const convIdValue = 0n;
  const companyIdValue = transactionUint64(companyId, "companyId");
  transactionUint16(assetType, "assetType");
  if (assetType < 1 || assetType > 10 || assetType === 4 || assetType === 7) {
    throw new RangeError("assetType is not transaction-creatable");
  }
  if (typeof preview !== "string" || typeof payload !== "string") {
    throw new TypeError("preview and payload must be strings");
  }

  const previewBytes = transactionTextEncoder.encode(preview);
  const payloadBytes = transactionTextEncoder.encode(payload);
  if (previewBytes.length > TRANSACTION_MAX_PREVIEW_LENGTH) {
    throw new RangeError(`Preview exceeds max length (${previewBytes.length} > ${TRANSACTION_MAX_PREVIEW_LENGTH})`);
  }
  if (payloadBytes.length > TRANSACTION_MAX_PAYLOAD_LENGTH) {
    throw new RangeError(`Payload exceeds max length (${payloadBytes.length} > ${TRANSACTION_MAX_PAYLOAD_LENGTH})`);
  }

  const correlationId = window.NRCAssets.generateCorrelationId();
  if (!Number.isInteger(correlationId) || correlationId <= 0 || correlationId > 0xffffffff) {
    throw new RangeError("generateCorrelationId returned an invalid correlation ID");
  }

  const assetBodyLength = 21 + previewBytes.length + payloadBytes.length;
  const edgeBodyLength = 34;
  const buffer = new ArrayBuffer(2 + 8 + 6 + assetBodyLength + 6 + edgeBodyLength);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, TransactionOpcode.Apply, false); offset += 2;
  view.setUint8(offset, TRANSACTION_WIRE_VERSION); offset += 1;
  view.setUint8(offset, 0); offset += 1;
  view.setUint16(offset, 2, false); offset += 2;
  view.setUint32(offset, correlationId, false); offset += 4;

  view.setUint8(offset, TransactionOperation.AssetCreate); offset += 1;
  view.setUint8(offset, 0); offset += 1;
  view.setUint32(offset, assetBodyLength, false); offset += 4;
  view.setBigUint64(offset, convIdValue, false); offset += 8;
  view.setUint16(offset, assetType, false); offset += 2;
  view.setUint16(offset, 0, false); offset += 2; // ParentType.None
  view.setUint8(offset, 0); offset += 1; // PayloadEncoding.Plain
  view.setUint32(offset, payloadBytes.length, false); offset += 4;
  view.setUint16(offset, previewBytes.length, false); offset += 2;
  new Uint8Array(buffer, offset, previewBytes.length).set(previewBytes); offset += previewBytes.length;
  view.setUint16(offset, payloadBytes.length, false); offset += 2;
  new Uint8Array(buffer, offset, payloadBytes.length).set(payloadBytes); offset += payloadBytes.length;

  view.setUint8(offset, TransactionOperation.EdgeCreate); offset += 1;
  view.setUint8(offset, 0); offset += 1;
  view.setUint32(offset, edgeBodyLength, false); offset += 4;
  view.setBigUint64(offset, convIdValue, false); offset += 8;
  offset = writeTransactionReference(view, offset, TransactionReference.CreatedBy, 0n);
  offset = writeTransactionReference(view, offset, TransactionReference.Existing, companyIdValue);
  view.setUint16(offset, 7, false); // RelationType.MemberOf: the contact/activity belongs to the company

  const requestOptions = options && typeof options === "object" ? options : null;
  pendingTransactionRpc.set(correlationId, {
    convId: convIdValue,
    companyId: companyIdValue,
    assetType,
    onSuccess: requestOptions?.onSuccess,
    onError: requestOptions?.onError,
    context: requestOptions?.context,
  });
  sendPacket(buffer);
  return correlationId;
}

function sendAssetMetadataPatch(asset, preview, payload, options = {}) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  if (preview === null && payload === null) {
    throw new TypeError("preview or payload must be provided");
  }
  if (preview !== null && typeof preview !== "string" || payload !== null && typeof payload !== "string") {
    throw new TypeError("preview and payload must be strings or null");
  }
  const previewBytes = preview === null ? null : transactionTextEncoder.encode(preview);
  const payloadBytes = payload === null ? null : transactionTextEncoder.encode(payload);
  const previewLength = previewBytes?.length || 0;
  const payloadLength = payloadBytes?.length || 0;
  if (previewLength > TRANSACTION_MAX_PREVIEW_LENGTH || payloadLength > TRANSACTION_MAX_PAYLOAD_LENGTH) {
    throw new RangeError("File metadata exceeds protocol limits");
  }
  const correlationId = window.NRCAssets.generateCorrelationId();
  const present = (previewBytes ? 1 : 0) | (payloadBytes ? 2 : 0);
  const bodyLength = 29 + (previewBytes ? 2 + previewLength : 0) + (payloadBytes ? 7 + payloadLength : 0);
  const buffer = new ArrayBuffer(16 + bodyLength);
  const view = new DataView(buffer);
  view.setUint16(0, TransactionOpcode.Apply);
  view.setUint8(2, TRANSACTION_WIRE_VERSION);
  view.setUint16(4, 1);
  view.setUint32(6, correlationId);
  view.setUint8(10, TransactionOperation.AssetPatch);
  view.setUint32(12, bodyLength);
  view.setBigUint64(16, 0n);
  writeTransactionReference(view, 24, TransactionReference.Existing, BigInt(asset.assetId));
  view.setBigInt64(36, BigInt(asset.updatedAt));
  view.setUint8(44, present); // Attachments are intentionally unchanged.
  let offset = 45;
  if (previewBytes) {
    view.setUint16(offset, previewLength); offset += 2;
    new Uint8Array(buffer, offset, previewLength).set(previewBytes); offset += previewLength;
  }
  if (payloadBytes) {
    view.setUint8(offset++, 0);
    view.setUint32(offset, payloadLength); offset += 4;
    view.setUint16(offset, payloadLength); offset += 2;
    new Uint8Array(buffer, offset, payloadLength).set(payloadBytes);
  }
  pendingTransactionRpc.set(correlationId, { kind: "asset_patch", onSuccess: options.onSuccess, onError: options.onError });
  sendPacket(buffer);
  return correlationId;
}

function handleTransactionApplied(dataView) {
  if (!(dataView instanceof DataView) || dataView.byteLength < 12) return false;
  if (dataView.getUint16(0, false) !== 137 || dataView.getUint8(2) !== TRANSACTION_WIRE_VERSION) return false;
  const status = dataView.getUint8(3);
  const correlationId = dataView.getUint32(4, false);
  const failedOperation = dataView.getUint16(8, false);
  const count = dataView.getUint16(10, false);
  if (status > 1 || count > 256 || dataView.byteLength !== 12 + count * 10) return false;

  if (status === 1) {
    if (count !== 0) return false;
    settleTransaction(correlationId, false, {
      correlationId,
      failedOperation,
      message: failedOperation === TRANSACTION_FAILED_NONE
        ? "Transaction rejected"
        : `Transaction rejected at operation ${failedOperation}`,
    });
    return true;
  }
  if (failedOperation !== TRANSACTION_FAILED_NONE) return false;
  if (pendingTransactionRpc.get(correlationId)?.kind === "asset_patch") {
    if (count !== 1 || dataView.getUint8(12) !== TransactionOperation.AssetPatch || dataView.getUint8(13) !== 0) return false;
    settleTransaction(correlationId, true, { correlationId, assetId: dataView.getBigUint64(14) });
    return true;
  }
  if (count !== 2) return false;

  const firstType = dataView.getUint8(12);
  const secondType = dataView.getUint8(22);
  if (firstType !== TransactionOperation.AssetCreate || dataView.getUint8(13) !== 0 ||
      secondType !== TransactionOperation.EdgeCreate || dataView.getUint8(23) !== 0) return false;
  const assetId = dataView.getBigUint64(14, false);
  const edgeId = dataView.getBigUint64(24, false);
  settleTransaction(correlationId, true, { correlationId, assetId, edgeId });
  return true;
}

function handleTransactionErrorResponse(originOpcode, correlationId, message = "") {
  if (originOpcode !== TransactionOpcode.Apply) return false;
  settleTransaction(correlationId, false, {
    correlationId,
    originOpcode,
    message: (message || "Unknown server error").trim(),
  });
  return true;
}

function clearPendingTransactionRpc() {
  for (const correlationId of [...pendingTransactionRpc.keys()]) {
    settleTransaction(correlationId, false, {
      correlationId,
      uncertain: true,
      message: "Connection lost. Transaction outcome is unknown; refresh before retrying.",
    });
  }
}

window.NRCTransactions = {
  sendCreateLinkedAsset,
  sendAssetMetadataPatch,
  handleTransactionApplied,
  handleTransactionErrorResponse,
  clearPendingTransactionRpc,
};
