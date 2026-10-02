// =============================================================================
// NRC EDGES MODULE
// =============================================================================
// Knowledge graph edges - non-ownership links between assets and tasks.
// Edges are deleted when either endpoint is deleted.

// =============================================================================
// TYPES
// =============================================================================

const RelationType = {
  References: 1,
  RelatedTo: 2,
  DependsOn: 3,
  Blocks: 4,
  DerivedFrom: 5,
  Supersedes: 6,
  MemberOf: 7,
};

const RelationTypeNames = {
  1: "references",
  2: "related-to",
  3: "depends-on",
  4: "blocks",
  5: "derived-from",
  6: "supersedes",
  7: "member-of",
};

const TargetType = {
  Asset: 1,
  Task: 2,
};

// =============================================================================
// STATE
// =============================================================================

// Per-room edge storage: roomId → Map(edgeId → edge)
const roomEdges = new Map();

// Adjacency index: roomId → Map(entityKey → Set(edgeId))
// entityKey format: "asset:123" or "task:456"
const roomEdgesByEntity = new Map();

// Callbacks for edge changes
const edgeChangeListeners = [];

function addEdgeChangeListener(callback) {
  edgeChangeListeners.push(callback);
}

const graphQueryListeners = [];

function addGraphQueryListener(callback) {
  graphQueryListeners.push(callback);
}

const pendingEdgeRpcByCorrelation = new Map();
let edgeMutationSequence = 0;
const edgeMutationVersions = new Map();

const EdgeOriginOpcode = {
  Create: 40,
  Delete: 41,
  List: 42,
  ListAll: 43,
  GraphQuery: 44,
  GraphPath: 45,
  GraphDegree: 46,
  GraphCommon: 47,
  ListAllPaged: 53,
  ListPaged: 54,
};

function normalizeEdgeRequestOptions(options) {
  return options && typeof options === "object" ? options : null;
}

function registerPendingEdgeRpc(correlationId, request) {
  if (!correlationId) return;
  pendingEdgeRpcByCorrelation.set(correlationId, request);
}

function settlePendingEdgeRpc(correlationId, ok, detail) {
  if (!correlationId) return null;

  const pending = pendingEdgeRpcByCorrelation.get(correlationId);
  if (!pending) return null;

  pendingEdgeRpcByCorrelation.delete(correlationId);

  const callback = ok ? pending.onSuccess : pending.onError;
  if (typeof callback === "function") {
    try {
      callback(detail, pending);
    } catch (callbackError) {
      console.error("[NRCEdges] Pending request callback failed", callbackError);
    }
  }

  const eventName = ok ? "nrc:edge-request-success" : "nrc:edge-request-error";
  document.dispatchEvent(
    new CustomEvent(eventName, {
      detail: {
        correlationId,
        kind: pending.kind,
        convId: pending.convId,
        originOpcode: pending.originOpcode,
        result: ok ? detail : null,
        error: ok ? null : detail,
      },
    }),
  );

  return pending;
}

function getEdgeRequestKindFromOriginOpcode(originOpcode) {
  switch (originOpcode) {
    case EdgeOriginOpcode.Create:
      return "create";
    case EdgeOriginOpcode.Delete:
      return "delete";
    case EdgeOriginOpcode.List:
      return "list";
    case EdgeOriginOpcode.ListAll:
      return "list_all";
    case EdgeOriginOpcode.GraphQuery:
      return "graph_query";
    case EdgeOriginOpcode.GraphPath:
      return "graph_path";
    case EdgeOriginOpcode.GraphDegree:
      return "graph_degree";
    case EdgeOriginOpcode.GraphCommon:
      return "graph_common";
    case EdgeOriginOpcode.ListAllPaged:
      return "list_all_paged";
    case EdgeOriginOpcode.ListPaged:
      return "list_paged";
    default:
      return null;
  }
}

function getEdgeRequestLabel(kind) {
  switch (kind) {
    case "create":
      return "CREATE";
    case "delete":
      return "DELETE";
    case "list":
      return "LIST";
    case "list_all":
      return "LIST ALL";
    case "graph_query":
      return "GRAPH QUERY";
    case "graph_path":
      return "GRAPH PATH";
    case "graph_degree":
      return "GRAPH DEGREE";
    case "graph_common":
      return "GRAPH COMMON";
    default:
      return "REQUEST";
  }
}

function formatEdgeRequestContext(pending) {
  if (!pending) return "ROOM ?";
  return pending.context || `ROOM ${pending.convId ?? "?"}`;
}

function getRpcCorrelationId() {
  if (window.NRCAssets && typeof window.NRCAssets.generateCorrelationId === "function") {
    return window.NRCAssets.generateCorrelationId();
  }
  return 0;
}

// =============================================================================
// ENTITY KEY HELPERS
// =============================================================================

function makeEntityKey(targetType, targetId) {
  const typeStr = targetType === TargetType.Asset ? "asset" : "task";
  return `${typeStr}:${targetId}`;
}

function parseEntityKey(key) {
  const [typeStr, idStr] = key.split(":");
  return {
    targetType: typeStr === "asset" ? TargetType.Asset : TargetType.Task,
    targetId: BigInt(idStr),
  };
}

// =============================================================================
// WIRE PROTOCOL - SEND
// =============================================================================

function sendCreateEdge(convId, sourceType, sourceId, targetType, targetId, relation, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = getRpcCorrelationId();

  // Buffer: Opcode(2) + conv_id(8) + source_type(2) + source_id(8) + target_type(2) + target_id(8) + relation(2) + correlation_id(4)
  const buffer = new ArrayBuffer(36);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_CreateEdge, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setUint16(offset, sourceType, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(sourceId), false);
  offset += 8;

  view.setUint16(offset, targetType, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(targetId), false);
  offset += 8;

  view.setUint16(offset, relation, false);
  offset += 2;

  view.setUint32(offset, correlationId, false);

  const opts = normalizeEdgeRequestOptions(requestOptions);
  registerPendingEdgeRpc(correlationId, {
    kind: "create",
    originOpcode: EdgeOriginOpcode.Create,
    convId: BigInt(convId),
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendDeleteEdge(convId, edgeId, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = getRpcCorrelationId();

  // Buffer: Opcode(2) + conv_id(8) + edge_id(8) + correlation_id(4)
  const buffer = new ArrayBuffer(22);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_DeleteEdge, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setBigUint64(10, BigInt(edgeId), false);
  view.setUint32(18, correlationId, false);

  const opts = normalizeEdgeRequestOptions(requestOptions);
  registerPendingEdgeRpc(correlationId, {
    kind: "delete",
    originOpcode: EdgeOriginOpcode.Delete,
    convId: BigInt(convId),
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendListEdges(convId, targetType, targetId, requestOptions = null) {
  convId = 0n;
  console.log("[NRCEdges] sendListEdges called:", { convId, targetType, targetId });
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    console.warn("[NRCEdges] WebSocket not open, cannot send");
    return 0;
  }

  const correlationId = getRpcCorrelationId();

  // Buffer: Opcode(2) + conv_id(8) + target_type(2) + target_id(8) + correlation_id(4)
  const buffer = new ArrayBuffer(24);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_ListEdges, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setUint16(offset, targetType, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(targetId), false);
  offset += 8;

  view.setUint32(offset, correlationId, false);

  const opts = normalizeEdgeRequestOptions(requestOptions);
  registerPendingEdgeRpc(correlationId, {
    kind: "list",
    originOpcode: EdgeOriginOpcode.List,
    convId: BigInt(convId),
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
    snapshotStartVersion: edgeMutationSequence,
  });

  console.log("[NRCEdges] Sending C_ListEdges packet");
  sendPacket(buffer);

  return correlationId;
}

function sendListAllEdges(convId, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = getRpcCorrelationId();

  // Buffer: Opcode(2) + conv_id(8) + correlation_id(4)
  const buffer = new ArrayBuffer(14);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_ListAllEdges, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setUint32(10, correlationId, false);

  const opts = normalizeEdgeRequestOptions(requestOptions);
  registerPendingEdgeRpc(correlationId, {
    kind: "list_all",
    originOpcode: EdgeOriginOpcode.ListAll,
    convId: BigInt(convId),
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
    snapshotStartVersion: edgeMutationSequence,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendListAllEdgesPaged(convId, limit = 100, afterEdgeId = 0n, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return 0;
  const correlationId = getRpcCorrelationId();
  const buffer = new ArrayBuffer(24);
  const view = new DataView(buffer);
  view.setUint16(0, Opcode.C_ListAllEdgesPaged, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setUint16(10, limit, false);
  view.setBigUint64(12, BigInt(afterEdgeId), false);
  view.setUint32(20, correlationId, false);
  const opts = normalizeEdgeRequestOptions(requestOptions);
  registerPendingEdgeRpc(correlationId, {
    kind: "list_all_paged", originOpcode: EdgeOriginOpcode.ListAllPaged,
    convId: BigInt(convId), onSuccess: opts?.onSuccess, onError: opts?.onError,
    context: opts?.context,
    snapshotStartVersion: opts?.snapshotStartVersion,
  });
  sendPacket(buffer);
  return correlationId;
}

function requestAllEdges(convId, options = {}) {
  const normalizedConvId = 0n;
  const startVersion = edgeMutationSequence;
  const snapshot = new Map();
  const limit = options.limit ?? 100;
  return new Promise((resolve, reject) => {
    const fail = (value) => reject(value instanceof Error ? value : new Error(value));
    const cancelled = () => typeof options.isCancelled === "function" && options.isCancelled();
    const page = (afterEdgeId = 0n) => {
      if (cancelled()) return fail("Edge pagination cancelled");
      if (!ws || ws.readyState !== WebSocket.OPEN) return fail("Connection is not ready for edge pagination");
      const id = sendListAllEdgesPaged(normalizedConvId, limit, afterEdgeId, {
        context: options.context,
        snapshotStartVersion: startVersion,
        onSuccess(detail) {
          if (cancelled()) return fail("Edge pagination cancelled");
          for (const edge of detail.edges) snapshot.set(edge.edgeId, edge);
          if (detail.hasMore) {
            if (detail.nextEdgeId === afterEdgeId) return fail("Edge pagination cursor did not advance");
            return page(detail.nextEdgeId);
          }
          reconcileEdgeSnapshot(normalizedConvId, snapshot, startVersion);
          const edges = getEdgesForRoom(normalizedConvId);
          for (const listener of edgeChangeListeners) {
            listener({ convId: normalizedConvId, edges }, "all");
          }
          resolve({ edges });
        },
        onError(detail) { fail(detail?.message || "Edge pagination failed"); },
      });
      if (!id) fail("Connection is not ready for edge pagination");
    };
    page();
  });
}

// A caller keeps the session between explicit LOAD MORE requests. Reconcile only
// the covered ID range; cached edges beyond the cursor are not yet authoritative.
function requestEdgePage(convId, targetType, targetId, options = {}) {
  convId = 0n;
  targetId = BigInt(targetId);
  const session = options.session ?? { startVersion: edgeMutationSequence, seen: new Set(), cursor: 0n };
  return new Promise((resolve, reject) => {
    const cancelled = () => options.isCancelled?.();
    if (cancelled() || !ws || ws.readyState !== WebSocket.OPEN) return reject(new Error("Connection is not ready for edge pagination"));
    const correlationId = getRpcCorrelationId();
    const buffer = new ArrayBuffer(34);
    const view = new DataView(buffer);
    view.setUint16(0, Opcode.C_ListEdgesPaged);
    view.setBigUint64(2, convId);
    view.setUint16(10, targetType);
    view.setBigUint64(12, targetId);
    view.setUint16(20, options.limit ?? 50);
    view.setBigUint64(22, session.cursor);
    view.setUint32(30, correlationId);
    registerPendingEdgeRpc(correlationId, {
      kind: "list_paged", originOpcode: EdgeOriginOpcode.ListPaged, convId,
      onError: detail => reject(new Error(detail.message || "Edge page failed")),
      onSuccess(detail) {
        if (cancelled()) return reject(new Error("Edge pagination cancelled"));
        if (detail.convId !== convId || detail.targetType !== targetType || detail.targetId !== targetId ||
            (detail.hasMore && detail.nextEdgeId <= session.cursor)) return reject(new Error("Invalid edge page"));
        for (const edge of detail.edges) {
          session.seen.add(edge.edgeId);
          if ((edgeMutationVersions.get(`${convId}:${edge.edgeId}`) ?? 0) <= session.startVersion) storeEdge(edge);
        }
        session.cursor = detail.nextEdgeId;
        for (const edge of getEdgesForEntity(convId, targetType, targetId)) {
          if ((!detail.hasMore || edge.edgeId <= session.cursor) && !session.seen.has(edge.edgeId) &&
              (edgeMutationVersions.get(`${convId}:${edge.edgeId}`) ?? 0) <= session.startVersion) removeEdge(convId, edge.edgeId);
        }
        resolve({ ...detail, session });
        // Reconciliation also changes reverse adjacency of linked entities.
        for (const listener of edgeChangeListeners) listener({ convId }, "cache");
        for (const listener of edgeChangeListeners) listener(detail, detail.hasMore ? "list_page" : "list");
      },
    });
    sendPacket(buffer);
  });
}

function handleEdgeListPage(view) {
  const detail = {
    convId: view.getBigUint64(2), targetType: view.getUint16(10), targetId: view.getBigUint64(12),
    hasMore: view.getUint8(20) === 1, nextEdgeId: view.getBigUint64(21), totalCount: view.getUint32(29), edges: [],
  };
  let offset = 39;
  for (let i = 0; i < view.getUint16(33); i++) {
    const parsed = parseEdge(view, offset);
    offset = parsed.newOffset;
    detail.edges.push(parsed.edge);
  }
  settlePendingEdgeRpc(view.getUint32(35), true, detail);
}

function sendGraphQuery(convId, startType, startId, maxDepth, relationMask, direction, flags, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = getRpcCorrelationId();

  const buffer = new ArrayBuffer(29);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_GraphQuery, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setUint16(offset, startType, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(startId), false);
  offset += 8;

  view.setUint8(offset, maxDepth);
  offset += 1;

  view.setUint16(offset, relationMask, false);
  offset += 2;

  view.setUint8(offset, direction);
  offset += 1;

  view.setUint8(offset, flags);
  offset += 1;

  view.setUint32(offset, correlationId, false);

  const opts = normalizeEdgeRequestOptions(requestOptions);
  registerPendingEdgeRpc(correlationId, {
    kind: "graph_query",
    originOpcode: EdgeOriginOpcode.GraphQuery,
    convId: BigInt(convId),
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendShortestPath(convId, fromType, fromId, toType, toId, relationMask, direction, maxDepth, flags, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = getRpcCorrelationId();

  const buffer = new ArrayBuffer(39);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_GraphShortestPath, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setUint16(offset, fromType, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(fromId), false);
  offset += 8;

  view.setUint16(offset, toType, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(toId), false);
  offset += 8;

  view.setUint16(offset, relationMask, false);
  offset += 2;

  view.setUint8(offset, direction);
  offset += 1;

  view.setUint8(offset, maxDepth);
  offset += 1;

  view.setUint8(offset, flags);
  offset += 1;

  view.setUint32(offset, correlationId, false);

  const opts = normalizeEdgeRequestOptions(requestOptions);
  registerPendingEdgeRpc(correlationId, {
    kind: "graph_path",
    originOpcode: EdgeOriginOpcode.GraphPath,
    convId: BigInt(convId),
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendDegreeQuery(convId, topN, typeFilter, relationMask, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = getRpcCorrelationId();

  const buffer = new ArrayBuffer(20);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_GraphDegree, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setUint16(offset, topN, false);
  offset += 2;

  view.setUint16(offset, typeFilter, false);
  offset += 2;

  view.setUint16(offset, relationMask, false);
  offset += 2;

  view.setUint32(offset, correlationId, false);

  const opts = normalizeEdgeRequestOptions(requestOptions);
  registerPendingEdgeRpc(correlationId, {
    kind: "graph_degree",
    originOpcode: EdgeOriginOpcode.GraphDegree,
    convId: BigInt(convId),
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

function sendCommonNeighbors(convId, aType, aId, bType, bId, relationMask, direction, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = getRpcCorrelationId();

  const buffer = new ArrayBuffer(37);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_GraphCommonNeighbors, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setUint16(offset, aType, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(aId), false);
  offset += 8;

  view.setUint16(offset, bType, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(bId), false);
  offset += 8;

  view.setUint16(offset, relationMask, false);
  offset += 2;

  view.setUint8(offset, direction);
  offset += 1;

  view.setUint32(offset, correlationId, false);

  const opts = normalizeEdgeRequestOptions(requestOptions);
  registerPendingEdgeRpc(correlationId, {
    kind: "graph_common",
    originOpcode: EdgeOriginOpcode.GraphCommon,
    convId: BigInt(convId),
    onSuccess: opts?.onSuccess,
    onError: opts?.onError,
    context: opts?.context,
  });

  sendPacket(buffer);

  return correlationId;
}

// =============================================================================
// WIRE PROTOCOL - RECEIVE
// =============================================================================

function parseEdge(dataView, offset) {
  const edgeId = dataView.getBigUint64(offset, false);
  offset += 8;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const sourceType = dataView.getUint16(offset, false);
  offset += 2;

  const sourceId = dataView.getBigUint64(offset, false);
  offset += 8;

  const targetType = dataView.getUint16(offset, false);
  offset += 2;

  const targetId = dataView.getBigUint64(offset, false);
  offset += 8;

  const relation = dataView.getUint16(offset, false);
  offset += 2;

  const createdAt = dataView.getBigInt64(offset, false);
  offset += 8;

  const createdByLen = dataView.getUint16(offset, false);
  offset += 2;
  const createdByBytes = new Uint8Array(dataView.buffer, offset, createdByLen);
  const createdBy = new TextDecoder().decode(createdByBytes);
  offset += createdByLen;

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
      createdBy,
    },
    newOffset: offset,
  };
}

function handleEdgeCreated(dataView) {
  console.log("[NRCEdges] handleEdgeCreated received");
  const { edge, newOffset } = parseEdge(dataView, 2);
  if (dataView.byteLength < newOffset + 4) {
    console.error("S_EdgeCreated missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(newOffset, false);

  settlePendingEdgeRpc(correlationId, true, {
    kind: "create",
    edge,
    correlationId,
  });

  console.log("[NRCEdges] Created edge:", edge);
  markEdgeMutation(edge.convId, edge.edgeId);
  storeEdge(edge);

  for (const listener of edgeChangeListeners) {
    listener(edge, "created", correlationId);
  }
}

function handleEdgeDeleted(dataView) {
  if (dataView.byteLength < 22) {
    console.error("S_EdgeDeleted missing correlation_id");
    return;
  }
  const convId = dataView.getBigUint64(2, false);
  const edgeId = dataView.getBigUint64(10, false);
  const correlationId = dataView.getUint32(18, false);
  markEdgeMutation(convId, edgeId);

  settlePendingEdgeRpc(correlationId, true, {
    kind: "delete",
    convId,
    edgeId,
    correlationId,
  });

  const edge = getEdge(convId, edgeId);
  removeEdge(convId, edgeId);

  for (const listener of edgeChangeListeners) {
    listener(edge || { convId, edgeId }, "deleted", correlationId);
  }
}

function handleEdgeList(dataView) {
  console.log("[NRCEdges] handleEdgeList received");
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const targetType = dataView.getUint16(offset, false);
  offset += 2;

  const targetId = dataView.getBigUint64(offset, false);
  offset += 8;

  const count = dataView.getUint16(offset, false);
  offset += 2;

  console.log("[NRCEdges] EdgeList for convId:", convId, "targetType:", targetType, "targetId:", targetId, "count:", count);

  const edges = [];
  for (let i = 0; i < count; i++) {
    const { edge, newOffset } = parseEdge(dataView, offset);
    offset = newOffset;
    edges.push(edge);
  }

  if (dataView.byteLength < offset + 4) {
    console.error("S_EdgeList missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);
  const pending = pendingEdgeRpcByCorrelation.get(correlationId);
  for (const edge of edges) {
    const version = edgeMutationVersions.get(`${convId}:${edge.edgeId}`) ?? 0;
    if (pending?.snapshotStartVersion == null || version <= pending.snapshotStartVersion) storeEdge(edge);
  }

  // A scoped list is a complete snapshot for this endpoint.
  const present = new Set(edges.map((edge) => edge.edgeId));
  for (const edge of getEdgesForEntity(convId, targetType, targetId)) {
    const version = edgeMutationVersions.get(`${convId}:${edge.edgeId}`) ?? 0;
    if (!present.has(edge.edgeId) && version <= (pending?.snapshotStartVersion ?? edgeMutationSequence)) {
      removeEdge(convId, edge.edgeId);
    }
  }

  settlePendingEdgeRpc(correlationId, true, {
    kind: "list",
    convId,
    targetType,
    targetId,
    count,
    edges,
    correlationId,
  });

  console.log("[NRCEdges] Stored edges:", edges.length, "listeners:", edgeChangeListeners.length);
  for (const listener of edgeChangeListeners) {
    listener({ convId, targetType, targetId, edges }, "list");
  }
}

function handleAllEdgeList(dataView) {
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const count = dataView.getUint32(offset, false);
  offset += 4;

  const edges = [];
  for (let i = 0; i < count; i++) {
    const { edge, newOffset } = parseEdge(dataView, offset);
    offset = newOffset;
    edges.push(edge);
  }

  if (dataView.byteLength < offset + 4) {
    console.error("S_AllEdgeList missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);
  const pending = pendingEdgeRpcByCorrelation.get(correlationId);
  for (const edge of edges) {
    const version = edgeMutationVersions.get(`${convId}:${edge.edgeId}`) ?? 0;
    if (pending?.snapshotStartVersion == null || version <= pending.snapshotStartVersion) storeEdge(edge);
  }

  reconcileEdgeSnapshot(
    convId,
    new Map(edges.map((edge) => [edge.edgeId, edge])),
    pending?.snapshotStartVersion ?? edgeMutationSequence,
  );

  settlePendingEdgeRpc(correlationId, true, {
    kind: "list_all",
    convId,
    count,
    edges,
    correlationId,
  });

  for (const listener of edgeChangeListeners) {
    listener({ convId, edges }, "all");
  }
}

function handleAllEdgeListPage(dataView) {
  let offset = 2;
  const convId = dataView.getBigUint64(offset, false); offset += 8;
  const hasMore = dataView.getUint8(offset) === 1; offset += 1;
  const nextEdgeId = dataView.getBigUint64(offset, false); offset += 8;
  const totalCount = dataView.getUint32(offset, false); offset += 4;
  const count = dataView.getUint16(offset, false); offset += 2;
  const correlationId = dataView.getUint32(offset, false); offset += 4;
  const pending = pendingEdgeRpcByCorrelation.get(correlationId);
  const edges = [];
  for (let i = 0; i < count; i++) {
    const parsed = parseEdge(dataView, offset); offset = parsed.newOffset;
    edges.push(parsed.edge);
    const version = edgeMutationVersions.get(`${convId}:${parsed.edge.edgeId}`) ?? 0;
    if (pending?.snapshotStartVersion == null || version <= pending.snapshotStartVersion) storeEdge(parsed.edge);
  }
  settlePendingEdgeRpc(correlationId, true, {
    kind: "list_all_paged", convId, hasMore, nextEdgeId, totalCount,
    count, correlationId, edges,
  });
  // Page notifications are deliberately distinct from complete snapshots.
  for (const listener of edgeChangeListeners) listener({ convId, edges, hasMore }, "all_page");
  return correlationId;
}

function handleGraphQueryResult(dataView) {
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const startType = dataView.getUint16(offset, false);
  offset += 2;

  const startId = dataView.getBigUint64(offset, false);
  offset += 8;

  const truncated = dataView.getUint8(offset);
  offset += 1;

  const nodeCount = dataView.getUint16(offset, false);
  offset += 2;

  const nodes = [];
  for (let i = 0; i < nodeCount; i++) {
    const type = dataView.getUint16(offset, false);
    offset += 2;

    const id = dataView.getBigUint64(offset, false);
    offset += 8;

    const depth = dataView.getUint8(offset);
    offset += 1;

    nodes.push({ type, id, depth });
  }

  const edgeCount = dataView.getUint16(offset, false);
  offset += 2;

  const edges = [];
  for (let i = 0; i < edgeCount; i++) {
    const { edge, newOffset } = parseEdge(dataView, offset);
    offset = newOffset;
    edges.push(edge);
  }

  if (dataView.byteLength < offset + 4) {
    console.error("S_GraphQueryResult missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);

  settlePendingEdgeRpc(correlationId, true, {
    kind: "graph_query",
    convId,
    startType,
    startId,
    truncated,
    nodes,
    edges,
    correlationId,
  });

  for (const listener of graphQueryListeners) {
    listener({ type: "bfs", convId, startType, startId, truncated, nodes, edges });
  }
}

function handleShortestPathResult(dataView) {
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const fromType = dataView.getUint16(offset, false);
  offset += 2;

  const fromId = dataView.getBigUint64(offset, false);
  offset += 8;

  const toType = dataView.getUint16(offset, false);
  offset += 2;

  const toId = dataView.getBigUint64(offset, false);
  offset += 8;

  const found = dataView.getUint8(offset);
  offset += 1;

  const pathLength = dataView.getUint8(offset);
  offset += 1;

  const nodeCount = dataView.getUint16(offset, false);
  offset += 2;

  const nodes = [];
  for (let i = 0; i < nodeCount; i++) {
    const type = dataView.getUint16(offset, false);
    offset += 2;

    const id = dataView.getBigUint64(offset, false);
    offset += 8;

    nodes.push({ type, id });
  }

  const edgeCount = dataView.getUint16(offset, false);
  offset += 2;

  const edges = [];
  for (let i = 0; i < edgeCount; i++) {
    const { edge, newOffset } = parseEdge(dataView, offset);
    offset = newOffset;
    edges.push(edge);
  }

  if (dataView.byteLength < offset + 4) {
    console.error("S_GraphShortestPathResult missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);

  settlePendingEdgeRpc(correlationId, true, {
    kind: "graph_path",
    convId,
    fromType,
    fromId,
    toType,
    toId,
    found,
    pathLength,
    nodes,
    edges,
    correlationId,
  });

  for (const listener of graphQueryListeners) {
    listener({ type: "path", convId, fromType, fromId, toType, toId, found, pathLength, nodes, edges });
  }
}

function handleDegreeResult(dataView) {
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const count = dataView.getUint16(offset, false);
  offset += 2;

  const entries = [];
  for (let i = 0; i < count; i++) {
    const type = dataView.getUint16(offset, false);
    offset += 2;

    const id = dataView.getBigUint64(offset, false);
    offset += 8;

    const degree = dataView.getUint16(offset, false);
    offset += 2;

    entries.push({ type, id, degree });
  }

  if (dataView.byteLength < offset + 4) {
    console.error("S_GraphDegreeResult missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);

  settlePendingEdgeRpc(correlationId, true, {
    kind: "graph_degree",
    convId,
    entries,
    correlationId,
  });

  for (const listener of graphQueryListeners) {
    listener({ type: "degree", convId, entries });
  }
}

function handleCommonNeighborsResult(dataView) {
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const aType = dataView.getUint16(offset, false);
  offset += 2;

  const aId = dataView.getBigUint64(offset, false);
  offset += 8;

  const bType = dataView.getUint16(offset, false);
  offset += 2;

  const bId = dataView.getBigUint64(offset, false);
  offset += 8;

  const nodeCount = dataView.getUint16(offset, false);
  offset += 2;

  const nodes = [];
  for (let i = 0; i < nodeCount; i++) {
    const type = dataView.getUint16(offset, false);
    offset += 2;

    const id = dataView.getBigUint64(offset, false);
    offset += 8;

    nodes.push({ type, id });
  }

  const edgeCount = dataView.getUint16(offset, false);
  offset += 2;

  const edges = [];
  for (let i = 0; i < edgeCount; i++) {
    const { edge, newOffset } = parseEdge(dataView, offset);
    offset = newOffset;
    edges.push(edge);
  }

  if (dataView.byteLength < offset + 4) {
    console.error("S_GraphCommonNeighborsResult missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);

  settlePendingEdgeRpc(correlationId, true, {
    kind: "graph_common",
    convId,
    aType,
    aId,
    bType,
    bId,
    nodes,
    edges,
    correlationId,
  });

  for (const listener of graphQueryListeners) {
    listener({ type: "common", convId, aType, aId, bType, bId, nodes, edges });
  }
}

function handleEdgeErrorResponse(originOpcode, correlationId, errorMsg = "") {
  const kind = getEdgeRequestKindFromOriginOpcode(originOpcode);
  if (!kind) {
    return false;
  }

  const pending = settlePendingEdgeRpc(correlationId, false, {
    kind,
    originOpcode,
    correlationId,
    message: errorMsg,
  });

  if (!pending) {
    return true;
  }

  const context = formatEdgeRequestContext(pending);
  const label = getEdgeRequestLabel(pending.kind || kind);
  const message = (errorMsg || "Unknown server error").trim();
  logMessage("Error", `EDGE ${label} FAILED (${context}): ${message}`);
  return true;
}

function clearPendingEdgeRpc() {
  for (const [correlationId, pending] of pendingEdgeRpcByCorrelation) {
    settlePendingEdgeRpc(correlationId, false, {
      kind: pending.kind, originOpcode: pending.originOpcode, correlationId,
      message: "Connection closed before the server acknowledged the request",
    });
  }
}

// =============================================================================
// STORAGE HELPERS
// =============================================================================

function storeEdge(edge) {
  // Store in edge map
  if (!roomEdges.has(edge.convId)) {
    roomEdges.set(edge.convId, new Map());
  }
  roomEdges.get(edge.convId).set(edge.edgeId, edge);

  // Update adjacency index for source
  addToAdjacency(edge.convId, edge.sourceType, edge.sourceId, edge.edgeId);

  // Update adjacency index for target
  addToAdjacency(edge.convId, edge.targetType, edge.targetId, edge.edgeId);
}

function markEdgeMutation(convId, edgeId) {
  edgeMutationVersions.set(`${BigInt(convId)}:${BigInt(edgeId)}`, ++edgeMutationSequence);
}

function reconcileEdgeSnapshot(convId, snapshot, startVersion) {
  if (!roomEdges.has(convId)) roomEdges.set(convId, new Map());
  for (const [edgeId] of roomEdges.get(convId)) {
    const version = edgeMutationVersions.get(`${convId}:${edgeId}`) ?? 0;
    if (!snapshot.has(edgeId) && version <= startVersion) removeEdge(convId, edgeId);
  }
}

function removeEdge(convId, edgeId) {
  const edges = roomEdges.get(convId);
  if (!edges) return;

  const edge = edges.get(edgeId);
  if (!edge) return;

  // Remove from adjacency index
  removeFromAdjacency(convId, edge.sourceType, edge.sourceId, edgeId);
  removeFromAdjacency(convId, edge.targetType, edge.targetId, edgeId);

  // Remove from edge map
  edges.delete(edgeId);
}

function addToAdjacency(convId, targetType, targetId, edgeId) {
  if (!roomEdgesByEntity.has(convId)) {
    roomEdgesByEntity.set(convId, new Map());
  }
  const entityMap = roomEdgesByEntity.get(convId);
  const key = makeEntityKey(targetType, targetId);
  if (!entityMap.has(key)) {
    entityMap.set(key, new Set());
  }
  entityMap.get(key).add(edgeId);
}

function removeFromAdjacency(convId, targetType, targetId, edgeId) {
  const entityMap = roomEdgesByEntity.get(convId);
  if (!entityMap) return;

  const key = makeEntityKey(targetType, targetId);
  const edgeSet = entityMap.get(key);
  if (!edgeSet) return;

  edgeSet.delete(edgeId);
  if (edgeSet.size === 0) {
    entityMap.delete(key);
  }
}

function getEdge(convId, edgeId) {
  const edges = roomEdges.get(convId);
  return edges ? edges.get(edgeId) : null;
}

function getEdgesForRoom(convId) {
  const edges = roomEdges.get(convId);
  return edges ? Array.from(edges.values()) : [];
}

function getEdgesForEntity(convId, targetType, targetId) {
  const entityMap = roomEdgesByEntity.get(convId);
  if (!entityMap) return [];

  const key = makeEntityKey(targetType, targetId);
  const edgeIds = entityMap.get(key);
  if (!edgeIds) return [];

  const edges = roomEdges.get(convId);
  if (!edges) return [];

  return Array.from(edgeIds).map((id) => edges.get(id)).filter(Boolean);
}

// =============================================================================
// HIGH-LEVEL HELPERS
// =============================================================================

// Link two assets
function linkAssets(convId, sourceAssetId, targetAssetId, relation = RelationType.References) {
  sendCreateEdge(convId, TargetType.Asset, sourceAssetId, TargetType.Asset, targetAssetId, relation);
}

// Link an asset to a task
function linkAssetToTask(convId, assetId, taskId, relation = RelationType.References) {
  sendCreateEdge(convId, TargetType.Asset, assetId, TargetType.Task, taskId, relation);
}

// Link a task to another task
function linkTasks(convId, sourceTaskId, targetTaskId, relation = RelationType.DependsOn) {
  sendCreateEdge(convId, TargetType.Task, sourceTaskId, TargetType.Task, targetTaskId, relation);
}

// Get all linked assets for a note
function getLinkedAssetsForNote(convId, noteAssetId) {
  const edges = getEdgesForEntity(convId, TargetType.Asset, noteAssetId);
  return edges
    .filter((e) => e.targetType === TargetType.Asset || e.sourceType === TargetType.Asset)
    .map((e) => {
      // Return the "other" asset ID
      if (e.sourceId === noteAssetId) {
        return { assetId: e.targetId, relation: e.relation, direction: "out" };
      } else {
        return { assetId: e.sourceId, relation: e.relation, direction: "in" };
      }
    });
}

// Get all linked tasks for an asset
function getLinkedTasksForAsset(convId, assetId) {
  const edges = getEdgesForEntity(convId, TargetType.Asset, assetId);
  return edges
    .filter((e) => e.targetType === TargetType.Task || e.sourceType === TargetType.Task)
    .map((e) => {
      if (e.sourceType === TargetType.Asset && e.sourceId === assetId) {
        return { taskId: e.targetId, relation: e.relation, direction: "out" };
      } else {
        return { taskId: e.sourceId, relation: e.relation, direction: "in" };
      }
    });
}

// =============================================================================
// ROOM SWITCHING
// =============================================================================

function onEdgeRoomSwitch() {
  // Could fetch edges for entities in the new room if needed
  // For now, edges are fetched on-demand per entity
}

// =============================================================================
// INITIALIZATION
// =============================================================================

function initEdges() {
  // Nothing to initialize yet
}

// =============================================================================
// EXPORTS
// =============================================================================

window.NRCEdges = {
  // Handlers
  handleEdgeCreated,
  handleEdgeDeleted,
  handleEdgeList,
  handleAllEdgeList,
  handleAllEdgeListPage,
  handleEdgeListPage,
  handleGraphQueryResult,
  handleShortestPathResult,
  handleDegreeResult,
  handleCommonNeighborsResult,

  // Send functions
  sendCreateEdge,
  sendDeleteEdge,
  sendListEdges,
  sendListAllEdges,
  sendListAllEdgesPaged,
  requestAllEdges,
  requestEdgePage,
  sendGraphQuery,
  sendShortestPath,
  sendDegreeQuery,
  sendCommonNeighbors,

  // High-level helpers
  linkAssets,
  linkAssetToTask,
  linkTasks,
  getLinkedAssetsForNote,
  getLinkedTasksForAsset,

  // Storage
  getEdge,
  getEdgesForRoom,
  getEdgesForEntity,
  roomEdges,
  roomEdgesByEntity,

  // Callbacks
  addEdgeChangeListener,
  addGraphQueryListener,

  // Lifecycle
  initEdges,
  onEdgeRoomSwitch,
  clearPendingEdgeRpc,

  // Centralized Error Routing
  handleEdgeErrorResponse,

  // Constants
  RelationType,
  RelationTypeNames,
  TargetType,
};
