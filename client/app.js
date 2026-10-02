// =============================================================================
// CONNECTION CONFIGURATION
// =============================================================================

let currentWorkspaceId = "workspace1"; // Current workspace ID
let recentWorkspaces = []; // Array of recent workspace IDs

// Determine WebSocket URL from current browser location
function getBaseWsUrl() {
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${window.location.host}/`;
}

// Generate WebSocket URL for current workspace
function getWsUrl() {
  return getBaseWsUrl() + currentWorkspaceId;
}

// Search service URL (proxied through nginx on same origin)
function getSearchUrl() {
  return `${window.location.protocol}//${window.location.host}/search`;
}

function getAiUrl() {
  return `${window.location.protocol}//${window.location.host}/ai`;
}
const logOutput = document.getElementById("logOutput");
const messageInput = document.getElementById("messageInput");
const imageInput = document.getElementById("imageInput");
const messageByteCount = document.getElementById("messageByteCount");
const MAX_MESSAGE_CONTENT_BYTES = 50 * 1024;

function updateMessageByteCount() {
  if (!messageByteCount) return 0;
  const byteLength = new TextEncoder().encode(messageInput.value).length;
  messageByteCount.textContent = `${byteLength.toLocaleString()} B / ${MAX_MESSAGE_CONTENT_BYTES.toLocaleString()} B`;
  messageByteCount.classList.toggle("composer-byte-count--invalid", byteLength > MAX_MESSAGE_CONTENT_BYTES);
  return byteLength;
}

function clearMessageInput() {
  messageInput.value = "";
  messageInput.closest(".input-container")?.classList.remove("has-content");
  updateMessageByteCount();
}

// =============================================================================
// CONNECTION STATE
// =============================================================================

let ws;
let clientRequestIdCounter = 0;
let serverReady = false; // Track if server is ready to receive messages
let pendingInitialization = null; // Store initialization function to call when ready

// =============================================================================
// PROTOCOL DEFINITIONS
// =============================================================================
const Opcode = {
  C_SendMessage: 1,
  C_SubscribeConvs: 2,
  C_UnsubscribeConvs: 3,
  // 4, 5 reserved (formerly C_SetAgenda, C_GetAgenda - now handled via asset infrastructure)
  // 6, 7 reserved (formerly C_SetDiagram, C_GetDiagram)
  C_Stats: 8,
  C_Ping: 19,
  // 10-15 reserved (formerly C_JoinVoice, C_LeaveVoice, C_AudioFrame, C_StartScreenshare, C_StopScreenshare, C_ScreenFrame)
  S_ServerReady: 100,
  S_NewMessage: 102,
  S_AckSendMessage: 103,
  S_ErrorResponse: 104,
  // 105, 106 reserved (formerly S_AgendaResponse, S_AgendaUpdated - now handled via asset infrastructure)
  // 107, 108 reserved (formerly S_DiagramResponse, S_DiagramUpdated)
  S_RoomPresenceUpdate: 109,
  S_StatsResponse: 110,
  S_Pong: 126,
  S_AckUnsubscribeConvs: 127,
  // 112-120 reserved (formerly S_VoiceJoined, S_VoiceLeft, S_AudioFrame, S_Speaking, S_VoiceMetrics, S_ScreenshareStarted, S_ScreenshareEnded, S_ScreenFrame, S_ScreenshareMetrics)
  // Direct Messages (Client -> Server)
  C_StartDM: 16,
  C_ListDMs: 17,
  C_LeaveDM: 18,
  // Direct Messages (Server -> Client)
  S_DMStarted: 121,
  S_DMList: 122,
  S_DMError: 123,
  S_DMLeft: 124,
  S_DMPartnerStatus: 125,
  // Tasks/Kanban (Client -> Server)
  C_CreateTask: 20,
  C_UpdateTask: 21,
  C_DeleteTask: 22,
  C_MoveTask: 23,
  C_GetTasks: 24,
  C_ListTasksPaged: 25,
  C_GetTask: 26,
  C_ListTaskSlices: 56,
  // Tasks/Kanban (Server -> Client)
  S_TaskCreated: 130,
  S_TaskUpdated: 131,
  S_TaskDeleted: 132,
  S_TaskMoved: 133,
  S_TaskListResponse: 134,
  S_TaskListPage: 135,
  S_TaskFull: 136,
  S_TaskQueryPage: 138,
  S_TaskProjects: 139,
  S_TaskSliceList: 164,
  S_TaskAssignees: 165,
  S_CalendarPage: 166,
  // Assets (Client -> Server)
  C_CreateAsset: 30,
  C_UpdateAsset: 31,
  C_DeleteAsset: 32,
  C_GetAsset: 33,
  C_ListAssets: 34,
  C_ListAssetsPaged: 35,
  C_ListAssetsPagedByProject: 36,
  C_ListNoteProjects: 37,
  C_ListAssetsPagedByTag: 38,
  C_ListNoteTags: 39,
  // Assets (Server -> Client)
  S_AssetCreated: 140,
  S_AssetUpdated: 141,
  S_AssetDeleted: 142,
  S_AssetFull: 143,
  S_AssetList: 144,
  S_AssetListPage: 145,
  S_NoteProjectList: 146,
  S_NoteTagList: 147,
  C_SearchCustomers: 55,
  S_CustomerSearchPage: 163,
  C_ApplyTransaction: 27,
  S_TransactionResult: 137,
  // Edges/Knowledge Graph (Client -> Server)
  C_CreateEdge: 40,
  C_DeleteEdge: 41,
  C_ListEdges: 42,
  C_ListAllEdges: 43,
  C_ListAllEdgesPaged: 53,
  C_ListEdgesPaged: 54,
  // Edges/Knowledge Graph (Server -> Client)
  S_EdgeCreated: 150,
  S_EdgeDeleted: 151,
  S_EdgeList: 152,
  S_AllEdgeList: 153,
  S_AllEdgeListPage: 161,
  S_EdgeListPage: 162,
  // Graph Queries (Client -> Server)
  C_GraphQuery: 44,
  C_GraphShortestPath: 45,
  C_GraphDegree: 46,
  C_GraphCommonNeighbors: 47,
  C_SendMessageV2: 48,
  C_SubscribeConvsV2: 49,
  C_ListMessagesBefore: 50,
  C_ReplayMessagesAfter: 51,
  // Graph Queries (Server -> Client)
  S_GraphQueryResult: 154,
  S_GraphShortestPathResult: 155,
  S_GraphDegreeResult: 156,
  S_GraphCommonNeighborsResult: 157,
  S_SubscriptionReady: 158,
  S_MessagePage: 159,
};

const EXPECTED_PROTOCOL_VERSION = 8;

const ContentType = {
  PlainText: 0,
  Markdown: 1,
};

const UserType = {
  User: 0,
  Admin: 1,
  Bot: 2,
  System: 3,
};

// =============================================================================
// USER & ROOM MANAGEMENT
// =============================================================================
let myNickname = null; // Identity assigned by server during handshake
let nicknameReceived = false; // Set once ServerReady includes identity
const DEFAULT_ROOM_ID = 2n;
const ENGINEERING_ROOM_ID = 2n;
const OPERATIONS_ROOM_ID = 3n;
const SYSTEM_ROOM_ID = 7n;
let currentRoomId = DEFAULT_ROOM_ID; // Current active room
let subscribedRooms = new Set([DEFAULT_ROOM_ID]); // Rooms we're subscribed to
let roomNames = new Map([[DEFAULT_ROOM_ID, "ENGINEERING"]]); // Room ID to name mapping
const ROOM_COLOR_COUNT = 6;
let roomMappingsByName = new Map(); // Normalized room name -> { convId, displayName, assetId }
let roomActivity = new Map(); // Room ID -> unread message count
let roomHistory = new Map(); // Store message history per room
let retainedRoomStates = new Map(); // Room ID -> "unknown", "enabled", or "disabled"
let retainedSubscriptionRequests = new Map(); // correlation ID -> requested room IDs
let retainedHistoryRequests = new Map(); // correlation ID -> paging state
let retainedHistoryStarted = new Set(); // Rooms loaded during this connection
let retainedOperationQueue = [];
let retainedOperations = new Map(); // correlation ID -> in-flight operation kind
const MAX_RETAINED_OPERATIONS_IN_FLIGHT = 1;
let systemLogHistory = []; // Client/operator log, separate from room history
let systemLogVisible = false;
let systemLogNextId = 1;
let systemLogSelectedId = null;
let systemLogLevelFilter = "ALL";
let systemLogSourceFilter = "ALL";
let systemLogQuery = "";
let systemLogFollowing = true;
let systemLogNewCount = 0;
let roomPresence = new Map(); // Store active users per room (roomId -> Map of username -> {isAuthenticated})
let roomPresenceSequences = new Map(); // Store latest presence sequence per room (roomId -> sequence number)

// =============================================================================
// DIRECT MESSAGES (DM)
// =============================================================================
let activeDMs = new Map(); // conv_id (BigInt) -> {username, authenticated, online, lastSeen, unread, optimistic}
const DM_CONV_FLAG = 0x8000000000000000n; // High bit marks DM conversations
const AI_BOT_PREFIX = "sullivan-";
const lastDMStartTimes = new Map();
const DM_START_DEBOUNCE_MS = 300;
const DM_OPTIMISTIC_TIMEOUT_MS = 5000;
let pendingOptimisticDMs = new Map(); // username → {tempId, timeout}
const pendingDMStarts = new Map(); // username → {timeout, correlationId}
const suppressedDMStartCorrelations = new Set();
let optimisticDMCounter = 0n; // Counter for generating temporary IDs
let pendingLeaveDMs = new Set(); // conv_id values currently awaiting S_DMLeft or S_DMError

function isDMConversation(convId) {
  return (BigInt(convId) & DM_CONV_FLAG) !== 0n;
}

function isAIDMConversation(convId) {
  if (!isDMConversation(convId)) return false;
  const dm = activeDMs.get(BigInt(convId));
  return !!(dm && dm.username && dm.username.toLowerCase().startsWith(AI_BOT_PREFIX));
}

function clearPendingOptimisticDMs() {
  for (const [username, pending] of pendingDMStarts) {
    clearTimeout(pending.timeout);
    pendingDMStarts.delete(username);
  }
  for (const [username, pending] of pendingOptimisticDMs) {
    clearTimeout(pending.timeout);
    activeDMs.delete(pending.tempId);
    pendingOptimisticDMs.delete(username);
  }
  suppressedDMStartCorrelations.clear();
  updateDMListUI();
}

// =============================================================================
// PRESENCE RECONCILIATION
// =============================================================================

let currentRoomReconciliationTimer = null; // Single timer for current active room
const INITIAL_RECONCILIATION_DELAY = 5000; // 5 seconds after room switch
const PERIODIC_RECONCILIATION_INTERVAL = 45000; // 45 seconds periodic

// Start reconciliation for the current active room only
function startPresenceReconciliation() {
  // Clear any existing timer
  stopPresenceReconciliation();

  if (!currentRoomId || !subscribedRooms.has(currentRoomId)) {
    return;
  }

  // Schedule initial reconciliation after delay
  const initialTimer = setTimeout(() => {
    if (currentRoomId && subscribedRooms.has(currentRoomId)) {
      logSystem(`RECONCILING ROOM ${getRoomName(currentRoomId)}`, "presence", "DEBUG");
      subscribeToConversations([currentRoomId]); // Triggers fresh UserListSync

      // Schedule periodic reconciliation
      const periodicTimer = setInterval(() => {
        if (currentRoomId && subscribedRooms.has(currentRoomId)) {
          logSystem(`PERIODIC RECONCILIATION ${getRoomName(currentRoomId)}`, "presence", "DEBUG");
          subscribeToConversations([currentRoomId]);
        } else {
          // Current room no longer valid, stop reconciliation
          stopPresenceReconciliation();
        }
      }, PERIODIC_RECONCILIATION_INTERVAL);

      currentRoomReconciliationTimer = periodicTimer;
    }
  }, INITIAL_RECONCILIATION_DELAY);

  currentRoomReconciliationTimer = initialTimer;
}

// Stop reconciliation for current room
function stopPresenceReconciliation() {
  if (currentRoomReconciliationTimer) {
    clearTimeout(currentRoomReconciliationTimer);
    clearInterval(currentRoomReconciliationTimer);
    currentRoomReconciliationTimer = null;
  }
}

// =============================================================================
// MESSAGE STORAGE HELPERS - REMOVED (Real-time only)
// =============================================================================

function sortRoomMessages(history) {
  history.sort((left, right) => {
    if (left.timestamp !== right.timestamp) return left.timestamp - right.timestamp;
    if (left.retained && right.retained && left.sequence != null && right.sequence != null) {
      return left.sequence < right.sequence ? -1 : left.sequence > right.sequence ? 1 : 0;
    }
    if (left.retained !== right.retained) return left.retained ? -1 : 1;
    return 0;
  });
}

function storeMessageInRoom(messageData, roomId = null) {
  const targetRoomId = roomId || currentRoomId;

  if (!roomHistory.has(targetRoomId)) {
    roomHistory.set(targetRoomId, []);
  }

  const history = roomHistory.get(targetRoomId);
  const duplicate = history.find((existing) =>
    (messageData.retained && existing.retained && messageData.sequence != null && existing.sequence === messageData.sequence) ||
    (messageData.clientMessageId && existing.clientMessageId === messageData.clientMessageId),
  );
  if (duplicate) {
    Object.assign(duplicate, messageData);
    if (duplicate.retained && duplicate.sequence != null) sortRoomMessages(history);
    return false;
  }
  history.push(messageData);

  if (messageData.retained && messageData.sequence != null) {
    sortRoomMessages(history);
  }

  // Limit history size per room if needed
  if (history.length > 1000) {
    history.shift();
  }
  return true;
}

function storeSystemLogMessage(messageData) {
  messageData.systemLogId = systemLogNextId++;
  systemLogHistory.push(messageData);

  if (systemLogHistory.length > 1000) {
    systemLogHistory.shift();
  }
}

function inferSystemLogLevel(messageData) {
  const explicitLevel = messageData.systemLevel || messageData.level;
  if (explicitLevel) return String(explicitLevel).toUpperCase();
  if (messageData.type === "Error") return "ERROR";

  const text = String(messageData.message || "");
  if (/\b(error|failed|failure|invalid)\b/i.test(text)) return "ERROR";
  if (/\b(warn|warning|retry|reconnect)\b/i.test(text)) return "WARN";
  if (/\b(debug|trace)\b/i.test(text)) return "DEBUG";
  return "INFO";
}

function inferSystemLogSource(messageData) {
  const explicitSource = messageData.systemSource || messageData.source;
  if (explicitSource) return String(explicitSource).toLowerCase();

  const text = String(messageData.message || "");
  if (/\b(metrics|latency|jitter|backpressure|io_uring)\b/i.test(text)) return "metrics";
  if (/\b(task|tasks|kanban|completed)\b/i.test(text)) return "tasks";
  if (/\b(note|notes|asset|assets|image|payload|attachment)\b/i.test(text)) return "assets";
  if (/\b(graph|similar|path|degree|neighbors)\b/i.test(text)) return "graph";
  if (/\b(ai|ask|action plan|sullivan)\b/i.test(text)) return "ai";
  if (/\b(dm|direct message)\b/i.test(text)) return "dm";
  if (/\b(auth|authenticated|identity)\b/i.test(text)) return "auth";
  if (/\b(workspace)\b/i.test(text)) return "workspace";
  if (/\b(presence|user list|joined|left|renamed)\b/i.test(text)) return "presence";
  if (/\b(subscribed|unsubscribed|websocket|connection|reconnect)\b/i.test(text)) return "websocket";
  if (/\b(room|switched|workspace|initialized)\b/i.test(text)) return "client";
  return "client";
}

function formatSystemLogTime(timestamp) {
  const date = new Date(timestamp);
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  const seconds = String(date.getSeconds()).padStart(2, "0");
  const millis = String(date.getMilliseconds()).padStart(3, "0");
  return `${hours}:${minutes}:${seconds}.${millis}`;
}

function formatSystemLogDate(timestamp) {
  const date = new Date(timestamp);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function getSystemLogEntries() {
  return systemLogHistory.map((messageData) => ({
    id: messageData.systemLogId,
    timestamp: messageData.timestamp || Date.now(),
    level: inferSystemLogLevel(messageData),
    source: inferSystemLogSource(messageData),
    message: String(messageData.message || ""),
  }));
}

function getFilteredSystemLogEntries() {
  const query = systemLogQuery.trim().toLowerCase();
  return getSystemLogEntries().filter((entry) => {
    if (systemLogLevelFilter !== "ALL" && entry.level !== systemLogLevelFilter) return false;
    if (systemLogSourceFilter !== "ALL" && entry.source !== systemLogSourceFilter) return false;
    if (query && !`${entry.level} ${entry.source} ${entry.message}`.toLowerCase().includes(query)) return false;
    return true;
  });
}

function getSelectedSystemLogEntry() {
  return getFilteredSystemLogEntries().find((entry) => entry.id === systemLogSelectedId) || null;
}

function updateSystemLogSelection() {
  document.querySelectorAll(".system-log-table tbody tr[data-system-log-id]").forEach((row) => {
    const selected = Number(row.dataset.systemLogId) === systemLogSelectedId;
    row.classList.toggle("system-log-row-selected", selected);
    const marker = row.querySelector(".system-log-col-marker");
    if (marker) marker.textContent = selected ? "›" : "";
  });
}

function updateSystemLogInspector() {
  window.NRCInspector?.showSystemLogEntry?.(getSelectedSystemLogEntry());
}

function updateSystemLogHeaderState() {
  const follow = document.getElementById("systemLogFollow");
  if (follow) {
    follow.classList.toggle("active", systemLogFollowing);
    follow.setAttribute("aria-pressed", String(systemLogFollowing));
    follow.textContent = systemLogFollowing
      ? "FOLLOW"
      : systemLogNewCount > 0 ? `PAUSED · ${systemLogNewCount} NEW` : "PAUSED";
  }
}

function selectSystemLogRow(id) {
  systemLogSelectedId = id;
  updateSystemLogSelection();
  updateSystemLogHeaderState();
  updateSystemLogInspector();
  requestAnimationFrame(() => {
    document
      .querySelector(`.system-log-table tbody tr[data-system-log-id="${id}"]`)
      ?.scrollIntoView({ block: "nearest" });
  });
}

function selectAdjacentSystemLogRow(direction) {
  const rows = Array.from(document.querySelectorAll(".system-log-table tbody tr[data-system-log-id]"));
  if (rows.length === 0) return false;

  const currentIndex = rows.findIndex((row) => Number(row.dataset.systemLogId) === systemLogSelectedId);
  let nextIndex;
  if (currentIndex === -1) {
    nextIndex = direction > 0 ? 0 : rows.length - 1;
  } else {
    nextIndex = Math.max(0, Math.min(rows.length - 1, currentIndex + direction));
  }

  selectSystemLogRow(Number(rows[nextIndex].dataset.systemLogId));
  return true;
}

function selectSystemLogBoundary(direction) {
  const rows = Array.from(document.querySelectorAll(".system-log-table tbody tr[data-system-log-id]"));
  if (rows.length === 0) return false;
  const row = direction > 0 ? rows[rows.length - 1] : rows[0];
  selectSystemLogRow(Number(row.dataset.systemLogId));
  return true;
}

function isSystemLogKeyboardEditableTarget(target) {
  if (!target) return false;
  const tagName = target.tagName;
  return tagName === "INPUT" || tagName === "TEXTAREA" || tagName === "SELECT" || target.isContentEditable;
}

function handleSystemLogKeyboardNavigation(e) {
  if (!systemLogVisible) return false;
  if (isSystemLogKeyboardEditableTarget(e.target)) return false;

  if (e.key === "ArrowDown") {
    e.preventDefault();
    return selectAdjacentSystemLogRow(1);
  }
  if (e.key === "ArrowUp") {
    e.preventDefault();
    return selectAdjacentSystemLogRow(-1);
  }
  if (e.key === "Home") {
    e.preventDefault();
    return selectSystemLogBoundary(-1);
  }
  if (e.key === "End") {
    e.preventDefault();
    return selectSystemLogBoundary(1);
  }
  if (e.key === "Escape") {
    e.preventDefault();
    exitSystemLog();
    return true;
  }

  return false;
}

function renderSystemLog({ scrollToEnd = systemLogFollowing } = {}) {
  const logOutput = document.getElementById("logOutput");
  if (!logOutput) return;

  logOutput.innerHTML = "";

  const entries = getFilteredSystemLogEntries();

  if (entries.length > 0 && !entries.some((entry) => entry.id === systemLogSelectedId)) {
    systemLogSelectedId = entries[entries.length - 1].id;
  } else if (entries.length === 0) {
    systemLogSelectedId = null;
  }

  const view = document.createElement("div");
  view.className = "system-log-view";

  const tableWrap = document.createElement("div");
  tableWrap.className = "system-log-table-wrap";

  const table = document.createElement("table");
  table.className = "system-log-table";
  table.innerHTML = `
    <thead>
      <tr>
        <th class="system-log-col-marker"></th>
        <th class="system-log-col-time">Time</th>
        <th class="system-log-col-level">Level</th>
        <th class="system-log-col-source">Source</th>
        <th class="system-log-col-message">Message</th>
      </tr>
    </thead>
    <tbody></tbody>
  `;

  const tbody = table.querySelector("tbody");
  if (entries.length === 0) {
    const row = document.createElement("tr");
    row.className = "system-log-empty-row";
    row.innerHTML = '<td colspan="5">NO SYSTEM LOG ENTRIES</td>';
    tbody.appendChild(row);
  } else {
    for (const entry of entries) {
      const row = document.createElement("tr");
      row.dataset.systemLogId = String(entry.id);
      row.className = `system-log-level-${entry.level.toLowerCase()}`;
      if (entry.id === systemLogSelectedId) {
        row.classList.add("system-log-row-selected");
      }
      row.innerHTML = `
        <td class="system-log-col-marker">${entry.id === systemLogSelectedId ? "›" : ""}</td>
        <td class="system-log-col-time" title="${escapeHtml(`${formatSystemLogDate(entry.timestamp)} ${formatSystemLogTime(entry.timestamp)}`)}">${escapeHtml(formatSystemLogTime(entry.timestamp))}</td>
        <td class="system-log-col-level">${escapeHtml(entry.level)}</td>
        <td class="system-log-col-source">${escapeHtml(entry.source)}</td>
        <td class="system-log-col-message"></td>
      `;
      row.querySelector(".system-log-col-message").textContent = entry.message;
      row.addEventListener("click", () => selectSystemLogRow(entry.id));
      tbody.appendChild(row);
    }
  }

  tableWrap.appendChild(table);
  view.appendChild(tableWrap);
  logOutput.appendChild(view);

  updateChatStats();
  updateSystemLogHeaderState();
  updateSystemLogInspector();
  if (scrollToEnd) {
    requestAnimationFrame(() => {
      tableWrap.scrollTop = tableWrap.scrollHeight;
    });
  }
}

function handleVisibleSystemLogEntry() {
  if (!systemLogVisible) return;
  if (systemLogFollowing) {
    systemLogNewCount = 0;
    systemLogSelectedId = getFilteredSystemLogEntries().at(-1)?.id ?? null;
    renderSystemLog({ scrollToEnd: true });
  } else {
    systemLogNewCount += 1;
    updateChatStats();
    updateSystemLogHeaderState();
  }
}

async function showSystemLog() {
  if (window.NRCAI?.isWorkbenchBusy?.()) {
    logMessage(
      "Error",
      "SULLIVAN RUN IS PINNED TO ITS CURRENT CONTEXT; STOP OR WAIT BEFORE OPENING SYSTEM LOG",
      window.NRCAI.getDisplayConvId?.(),
      { aiContextRoomId: window.NRCAI.getContextConvId?.() },
    );
    return false;
  }
  if (window.NRCInspector?.hasEntity?.() && !(await window.NRCInspector.close())) {
    return false;
  }
  systemLogVisible = true;

  if (window.NRCViewManager) {
    window.NRCViewManager.setActiveView("systemLog");
    if (window.NRCViewManager.getActiveView() !== "systemLog") {
      systemLogVisible = false;
      return false;
    }
  }

  systemLogLevelFilter = "ALL";
  systemLogSourceFilter = "ALL";
  systemLogQuery = "";
  systemLogFollowing = true;
  systemLogNewCount = 0;

  const title = document.getElementById("chatHeaderTitle");
  if (title) title.textContent = "SYSTEM";
  const statsLabel = document.getElementById("chatStatsLabel");
  if (statsLabel) statsLabel.textContent = "EVENTS / LAST";

  // Populate and show header filter controls
  const controls = document.getElementById("systemLogHeaderControls");
  if (controls) {
    const allEntries = getSystemLogEntries();
    const levels = Array.from(new Set(allEntries.map((e) => e.level))).sort();
    const sources = Array.from(new Set(allEntries.map((e) => e.source))).sort();

    const levelFilter = document.getElementById("systemLogLevelFilter");
    if (levelFilter) {
      levelFilter.innerHTML = `<option value="ALL">ALL</option>${levels.map((l) => `<option value="${escapeHtml(l)}">${escapeHtml(l)}</option>`).join("")}`;
    }

    const sourceFilter = document.getElementById("systemLogSourceFilter");
    if (sourceFilter) {
      sourceFilter.innerHTML = `<option value="ALL">ALL</option>${sources.map((s) => `<option value="${escapeHtml(s)}">${escapeHtml(s)}</option>`).join("")}`;
    }

    const search = document.getElementById("systemLogSearch");
    if (search) search.value = "";

    controls.style.display = "flex";
  }

  const resetFilters = document.getElementById("systemLogResetFilters");
  if (resetFilters) resetFilters.onclick = () => {
    systemLogLevelFilter = "ALL";
    systemLogSourceFilter = "ALL";
    systemLogQuery = "";
    const levelFilter = document.getElementById("systemLogLevelFilter");
    const sourceFilter = document.getElementById("systemLogSourceFilter");
    const search = document.getElementById("systemLogSearch");
    if (levelFilter) levelFilter.value = "ALL";
    if (sourceFilter) sourceFilter.value = "ALL";
    if (search) search.value = "";
    renderSystemLog();
  };

  const levelFilter = document.getElementById("systemLogLevelFilter");
  if (levelFilter) levelFilter.onchange = (event) => {
    systemLogLevelFilter = event.target.value || "ALL";
    renderSystemLog();
  };

  const sourceFilter = document.getElementById("systemLogSourceFilter");
  if (sourceFilter) sourceFilter.onchange = (event) => {
    systemLogSourceFilter = event.target.value || "ALL";
    renderSystemLog();
  };

  const search = document.getElementById("systemLogSearch");
  if (search) search.oninput = (event) => {
    systemLogQuery = event.target.value || "";
    renderSystemLog({ scrollToEnd: false });
  };

  const follow = document.getElementById("systemLogFollow");
  if (follow) follow.onclick = () => {
    systemLogFollowing = !systemLogFollowing;
    if (systemLogFollowing) {
      systemLogNewCount = 0;
      systemLogSelectedId = getFilteredSystemLogEntries().at(-1)?.id ?? null;
      renderSystemLog({ scrollToEnd: true });
    } else {
      updateSystemLogHeaderState();
    }
  };

  renderSystemLog();
  updateHeaderButtons();
  return true;
}

function exitSystemLog(options = {}) {
  if (!systemLogVisible) return;

  systemLogVisible = false;

  const title = document.getElementById("chatHeaderTitle");
  if (title) title.textContent = "MESSAGES";
  const statsLabel = document.getElementById("chatStatsLabel");
  if (statsLabel) statsLabel.textContent = "MSG / LAST";

  const controls = document.getElementById("systemLogHeaderControls");
  if (controls) controls.style.display = "none";

  if (options.restoreView !== false && window.NRCViewManager?.getActiveView?.() === "systemLog") {
    window.NRCViewManager.setActiveView("chat");
    return;
  }

  if (options.restoreView === false) return;

  updateRoomUI();
  loadRoomHistory(currentRoomId);
}

window.NRCSystemLog = {
  show: showSystemLog,
  exit: exitSystemLog,
  getSelectedEntry: getSelectedSystemLogEntry,
};

// --- Image handling ---
const imageChunks = new Map(); // imageId -> {chunks: [], totalChunks: number, mimeType: string, filename: string}

// =============================================================================
// MONITORING & METRICS
// =============================================================================

// --- Latency Measurement (Web Worker) ---
let latencyWorker = null; // Web Worker for latency calculations
let latencyStats = {
  current: 0,
  avg: 0,
  p95: 0,
  jitterAvg: 0,
  jitterP95: 0,
  stabilityState: "stable",
};
let pingInterval = null; // Reference to ping interval timer
let pendingPings = new Map(); // Store pending ping timestamps by request ID

// Initialize latency worker
function initLatencyWorker() {
  if (latencyWorker) return;
  try {
    latencyWorker = new Worker("latency-worker.js");
    latencyWorker.onmessage = (e) => {
      if (e.data.type === "stats") {
        latencyStats = e.data.data;
        // Schedule UI update on next frame
        scheduleStatsUpdate();
        if (latencyStats.stabilityChanged) {
          logMessage(
            "System",
            `LATENCY STABILITY: ${latencyStats.stabilityState}`,
          );
        }
      }
    };
    latencyWorker.onerror = (e) => {
      console.error("Latency worker error:", e);
    };
  } catch (e) {
    console.warn(
      "Failed to init latency worker, falling back to main thread:",
      e,
    );
  }
}

function terminateLatencyWorker() {
  if (latencyWorker) {
    latencyWorker.terminate();
    latencyWorker = null;
  }
}
let localPacketsIn = 0n;
let localPacketsOut = 0n;
let connectionStartTime = 0;
let totalReconnects = 0;
let uptimeInterval = null;
let initialConnection = true;

// --- New Metrics & Reliability ---
let lastPacketTime = 0;
let lastReconcileTime = 0;
let lastAckTime = 0;
let reconnectHistory = []; // Array of timestamps
let retransmitCount = 0;
let retransmitHistory = []; // Array of timestamps
let pendingMessages = new Map(); // reqId -> {buffer, timestamp, attempts, type}
let retransmissionInterval = null;
let serverClientSkew = 0;

// --- Batched DOM Updates ---
let pendingStatsUpdate = false;
let pendingDomUpdates = [];
let rafHandle = null;

function scheduleStatsUpdate() {
  if (pendingStatsUpdate) return;
  pendingStatsUpdate = true;
  if (!rafHandle) {
    rafHandle = requestAnimationFrame(flushDomUpdates);
  }
}

function scheduleDomUpdate(fn) {
  pendingDomUpdates.push(fn);
  if (!rafHandle) {
    rafHandle = requestAnimationFrame(flushDomUpdates);
  }
}

let pendingLocalStatsUpdate = false;

function scheduleLocalStatsUpdate() {
  if (pendingLocalStatsUpdate) return;
  pendingLocalStatsUpdate = true;
  if (!rafHandle) {
    rafHandle = requestAnimationFrame(flushDomUpdates);
  }
}

function flushDomUpdates() {
  rafHandle = null;

  // Flush latency/jitter display updates
  if (pendingStatsUpdate) {
    pendingStatsUpdate = false;
    updateLatencyDisplay();
    updateJitterDisplay();
  }

  // Flush local stats display updates
  if (pendingLocalStatsUpdate) {
    pendingLocalStatsUpdate = false;
    updateLocalStatsDisplay();
  }

  // Flush queued DOM updates
  const updates = pendingDomUpdates;
  pendingDomUpdates = [];
  for (const fn of updates) {
    try {
      fn();
    } catch (e) {
      console.error("DOM update error:", e);
    }
  }
}

// --- Transport Stats (Rates & Frames) ---
let rxBytesInterval = 0;
let rxFramesInterval = 0;
let txBytesInterval = 0;
let txFramesInterval = 0;
let frameSizes = []; // Rolling buffer for avg/max calculation (last N frames)
const MAX_FRAME_SAMPLES = 100;

// --- Receiver Pipeline Stats ---
let decodeTimes = []; // Store decode times for averaging
const MAX_DECODE_SAMPLES = 100;
let burstFrames = 0; // Frames processed in current tick
let maxBurstSize = 0; // Max burst observed
let lastBurstTime = 0; // Time of last burst update
let lastLoopTime = performance.now(); // For loop lag calculation
let loopLagHistory = []; // Store lag samples
let pipelineResetTimer = null;

// --- Reconnection Management ---
let reconnectAttempts = 0; // Current reconnection attempt count
let maxReconnectAttempts = 10; // Maximum reconnection attempts
let baseReconnectDelay = 1000; // Base delay in milliseconds (1 second)
let maxReconnectDelay = 30000; // Maximum delay in milliseconds (30 seconds)
let reconnectTimer = null; // Reference to reconnection timer
let isReconnecting = false; // Flag to prevent multiple reconnection attempts

// Room name mapping for functional theme. IDs are preserved for existing data.
const DEFAULT_ROOMS = [
  { id: ENGINEERING_ROOM_ID, name: "ENGINEERING" },
  { id: OPERATIONS_ROOM_ID, name: "OPERATIONS" },
];
// =============================================================================
// COMMAND REGISTRY AND AUTOCOMPLETE
// =============================================================================
// AUTOCOMPLETE SYSTEM
// =============================================================================

// Command registry for the command palette. Chat input does not execute commands.
const COMMANDS = [
  {
    id: "help.show",
    title: "Show help",
    desc: "Show available commands",
    group: "General",
    execute: showCommandHelp,
  },
  {
    id: "rooms.join",
    title: "Join room",
    desc: "Join a room by name or ID",
    arg: "room",
    group: "Rooms",
    execute: joinRoomFromPalette,
  },
  {
    id: "rooms.leave",
    title: "Leave room",
    desc: "Leave a room",
    arg: "room",
    group: "Rooms",
    execute: leaveRoomFromPalette,
  },
  {
    id: "rooms.switch",
    title: "Switch room",
    desc: "Switch to a room",
    arg: "room",
    group: "Rooms",
    execute: switchRoomFromPalette,
  },
  {
    id: "workspace.switch",
    title: "Switch workspace",
    desc: "Switch to workspace",
    arg: "workspace_id",
    group: "Workspace",
    execute: switchWorkspaceFromPalette,
  },
  {
    id: "messages.clear-current-room",
    title: "Clear room messages",
    desc: "Clear messages for current room",
    group: "Utility",
    execute: clearCurrentRoomMessages,
  },
  {
    id: "rooms.refresh-participants",
    title: "Refresh participants",
    desc: "Refresh room participants list",
    group: "Utility",
    execute: refreshRoomParticipants,
  },
  {
    id: "connection.reconnect",
    title: "Reconnect",
    desc: "Manually reconnect to server",
    group: "Utility",
    execute: manualReconnect,
  },
  {
    id: "tasks.create",
    title: "Create task",
    desc: "Create a task",
    arg: "title",
    group: "Tasks",
    execute: createTaskFromPalette,
  },
  {
    id: "tasks.done",
    title: "Mark task done",
    desc: "Mark a task done",
    arg: "task_id",
    group: "Tasks",
    execute: markTaskDoneFromPalette,
  },
  {
    id: "tasks.delete",
    title: "Delete task",
    desc: "Delete a task",
    arg: "task_id",
    group: "Tasks",
    execute: deleteTaskFromPalette,
  },
  {
    id: "tasks.refresh",
    title: "Refresh tasks",
    desc: "Reload workspace tasks",
    group: "Tasks",
    execute: refreshTasksFromPalette,
  },
  {
    id: "notes.create",
    title: "Create note",
    desc: "Create a note",
    arg: "text",
    group: "Tasks",
    execute: createNoteFromPalette,
  },
  {
    id: "tasks.filter-assignee",
    title: "Filter task by assignee",
    desc: "Filter tasks by assignee",
    arg: "assignee",
    group: "Tasks",
    execute: setTaskAssigneeFilterFromPalette,
  },
  {
    id: "dm.start",
    title: "Start direct message",
    desc: "Start a direct message with a user",
    arg: "username",
    group: "User",
    execute: startDMFromPalette,
  },
  {
    id: "ai.task-from-text",
    title: "AI: Create task from text",
    desc: "Extract task from pasted text using AI",
    arg: "text",
    group: "AI",
    execute: aiTaskFromTextFromPalette,
  },
  {
    id: "ai.note-from-text",
    title: "AI: Create note from text",
    desc: "Clean up text into a note using AI",
    arg: "text",
    group: "AI",
    execute: aiNoteFromTextFromPalette,
  },
  {
    id: "ai.ask",
    title: "Sullivan Workbench",
    desc: "Send Sullivan a room-aware request; proposed changes require approval",
    arg: "request",
    group: "AI",
    execute: askSullivanFromPalette,
  },
  {
    id: "settings.notifications",
    title: "Enable notifications",
    desc: "Enable desktop notifications (requires browser permission)",
    group: "Settings",
    execute: handleNotificationsCommand,
  },
  {
    id: "settings.reminder-notifications",
    title: "Reminder notifications",
    desc: "Desktop notifications when a reminder comes due",
    arg: "state",
    group: "Settings",
    execute: handleReminderNotificationsCommand,
  },
  {
    id: "settings.appointment-notifications",
    title: "Appointment notifications",
    desc: "Own appointments, 15 minutes before start (browser tab must remain open)",
    arg: "mine|off",
    group: "Settings",
    execute: handleAppointmentNotificationsCommand,
  },
  {
    id: "settings.theme",
    title: "Set theme",
    desc: "Set an NRC or Omarchy color theme",
    arg: "theme",
    group: "Settings",
    execute: handleThemeCommand,
  },
];

const GROUP_ORDER = [
  "General",
  "Rooms",
  "Workspace",
  "Utility",
  "Tasks",
  "User",
  "AI",
  "Settings",
  "Other",
];

// Autocomplete state
let autocompleteState = {
  isVisible: false,
  highlightedIndex: -1,
  suggestions: [],
  dropdownElement: null,
  portal: null,
};

// Helper functions for command registry
// =============================================================================
// AUTOCOMPLETE SUGGESTIONS
// =============================================================================

function getSuggestions(fullText, caretPos, remoteEntries = []) {
  const names = [...(roomPresence.get(currentRoomId)?.keys() || [])];
  const dm = activeDMs.get(currentRoomId);
  if (dm) names.push(dm.username);
  const mentions = window.NRCChat.suggestions(fullText, caretPos, names);
  if (mentions) return mentions;
  const textBeforeCaret = fullText.slice(0, caretPos);
  const lines = textBeforeCaret.split("\n");
  const currentLine = lines[lines.length - 1];

  if (currentLine.includes("#")) {
    return getReferenceSuggestions(fullText, caretPos, remoteEntries);
  }

  return { suggestions: [], replaceRange: [0, 0] };
}

// Both entity kinds use typed Markdown references; old #123 messages still work.
function getReferenceSuggestions(fullText, caretPos, remoteEntries = []) {
  const tasks = [...(window.NRCTasks?.roomTasks.get(0n)?.values() || [])]
    .map((task) => ({ type: "task", id: task.id, title: task.title, priority: task.priority }));
  const notes = (window.NRCNotes?.getNotesForRoom(0n) || [])
    .map((note) => ({ type: "note", id: note.assetId, title: window.NRCNotes.parseNotePreview(note.preview).title }));
  return window.NRCChat.referenceSuggestions(fullText, caretPos, [...tasks, ...notes, ...remoteEntries]);
}

// =============================================================================
// AUTOCOMPLETE UI
// =============================================================================

function createAutocompleteDropdown() {
  const dropdown = document.createElement("div");
  dropdown.id = "chatAutocomplete";
  dropdown.className = "autocomplete-dropdown hidden";
  dropdown.role = "listbox";
  dropdown.setAttribute("aria-live", "polite");
  return dropdown;
}

function renderSuggestions(suggestions, status = "") {
  if (!autocompleteState.dropdownElement) {
    autocompleteState.dropdownElement = createAutocompleteDropdown();
    messageInput.parentNode.appendChild(autocompleteState.dropdownElement);
    autocompleteState.portal = Portal.create(autocompleteState.dropdownElement, messageInput.parentNode, { position: "top" });
    messageInput.setAttribute("aria-controls", "chatAutocomplete");
    messageInput.setAttribute("aria-autocomplete", "list");
    autocompleteState.dropdownElement.addEventListener("mousedown", (event) => event.preventDefault());
  }

  const dropdown = autocompleteState.dropdownElement;
  dropdown.innerHTML = "";
  dropdown.classList.add("task-mode");
  dropdown.classList.toggle("entity-mode", suggestions.some((suggestion) => suggestion.type === "task" || suggestion.type === "note"));

  if (suggestions.length === 0 && !status) {
    hideAutocomplete();
    return;
  }

  let optionIndex = 0;

  suggestions.forEach((suggestion) => {
    const option = document.createElement("div");
    option.className = "autocomplete-option";
    option.role = "option";
    option.id = `chatAutocompleteOption${optionIndex}`;
    option.dataset.index = optionIndex;
    option.setAttribute("aria-selected", "false");

    const idCell = document.createElement("span");
    idCell.className = "autocomplete-option-command";
    const isEntity = suggestion.type === "task" || suggestion.type === "note";
    idCell.textContent = isEntity ? (suggestion.title || `Untitled ${suggestion.type}`) : suggestion.label;
    if (isEntity) {
      const reference = document.createElement("span");
      reference.className = "autocomplete-reference-id";
      reference.textContent = suggestion.label;
      idCell.append(reference);
    }

    const statusCell = document.createElement("span");
    statusCell.className = "autocomplete-option-aliases";
    statusCell.textContent = suggestion.statusName;

    const titleCell = document.createElement("span");
    titleCell.className = "autocomplete-option-description";
    titleCell.textContent = suggestion.title;

    option.appendChild(idCell);
    option.appendChild(statusCell);
    if (!isEntity) option.appendChild(titleCell);

    const index = optionIndex;
    option.addEventListener("click", () => acceptSuggestion(index));

    dropdown.appendChild(option);
    optionIndex++;
  });

  if (status) {
    const notice = document.createElement("div");
    notice.className = "autocomplete-option-description autocomplete-status";
    notice.setAttribute("role", "status");
    notice.textContent = status;
    dropdown.append(notice);
  }
  autocompleteState.highlightedIndex = suggestions.length ? 0 : -1;
  dropdown.classList.remove("hidden");
  autocompleteState.isVisible = true;
  autocompleteState.suggestions = suggestions;
  autocompleteState.portal.show();
  updateHighlight();
}

function hideAutocomplete() {
  window.NRCChat.cancelReferenceSearch();
  if (autocompleteState.dropdownElement) {
    autocompleteState.dropdownElement.classList.add("hidden");
  }

  autocompleteState.portal?.hide();
  messageInput.removeAttribute("aria-activedescendant");
  autocompleteState.isVisible = false;
  autocompleteState.highlightedIndex = -1;
  autocompleteState.suggestions = [];
}

function updateHighlight() {
  if (!autocompleteState.dropdownElement || !autocompleteState.isVisible) {
    return;
  }

  if (autocompleteState.highlightedIndex >= 0) messageInput.setAttribute("aria-activedescendant", `chatAutocompleteOption${autocompleteState.highlightedIndex}`);
  else messageInput.removeAttribute("aria-activedescendant");
  const options = autocompleteState.dropdownElement.querySelectorAll(
    ".autocomplete-option",
  );
  options.forEach((option) => {
    const optionIndex = parseInt(option.dataset.index, 10);
    const isHighlighted = optionIndex === autocompleteState.highlightedIndex;
    option.classList.toggle("highlighted", isHighlighted);
    option.setAttribute("aria-selected", isHighlighted.toString());
  });

  // Scroll highlighted option into view (scroll first cell)
  if (autocompleteState.highlightedIndex >= 0) {
    const highlightedOption = autocompleteState.dropdownElement.querySelector(
      `.autocomplete-option[data-index="${autocompleteState.highlightedIndex}"]`,
    );
    if (highlightedOption) {
      const firstCell = highlightedOption.querySelector(
        ".autocomplete-option-command",
      );
      if (firstCell) {
        firstCell.scrollIntoView({
          block: "nearest",
        });
      }
    }
  }
}

function moveHighlight(direction) {
  if (
    !autocompleteState.isVisible ||
    autocompleteState.suggestions.length === 0
  ) {
    return;
  }

  const maxIndex = autocompleteState.suggestions.length - 1;

  if (direction === "up") {
    autocompleteState.highlightedIndex =
      autocompleteState.highlightedIndex <= 0
        ? maxIndex
        : autocompleteState.highlightedIndex - 1;
  } else if (direction === "down") {
    autocompleteState.highlightedIndex =
      autocompleteState.highlightedIndex >= maxIndex
        ? 0
        : autocompleteState.highlightedIndex + 1;
  }

  updateHighlight();
}

function acceptSuggestion(index = autocompleteState.highlightedIndex) {
  if (
    !autocompleteState.isVisible ||
    index < 0 ||
    index >= autocompleteState.suggestions.length
  ) {
    return;
  }

  const suggestion = autocompleteState.suggestions[index];

  const currentText = messageInput.value;
  const [start, end] = suggestion.replaceRange;
  messageInput.value = currentText.slice(0, start) + suggestion.label + " " + currentText.slice(end);
  const newCaretPos = start + suggestion.label.length + 1;
  messageInput.setSelectionRange(newCaretPos, newCaretPos);

  hideAutocomplete();
  messageInput.focus();
  updateMessageByteCount();
}

function handleAutocompleteInput() {
  const fullText = messageInput.value;
  const caretPos = messageInput.selectionStart;

  const result = getSuggestions(fullText, caretPos);

  if (result.suggestions.length > 0) {
    renderSuggestions(result.suggestions);
  } else {
    hideAutocomplete();
  }
  if (result.suggestions[0]?.type === "mention") {
    window.NRCChat.cancelReferenceSearch();
    return;
  }
  window.NRCChat.searchReferences(fullText, caretPos, (entries, status) => {
    if (messageInput.value !== fullText || messageInput.selectionStart !== caretPos || document.activeElement !== messageInput) return;
    const selected = autocompleteState.suggestions[autocompleteState.highlightedIndex]?.label;
    const results = getSuggestions(fullText, caretPos, entries).suggestions;
    renderSuggestions(results, status || (results.length ? "" : "NO MATCHES"));
    const index = results.findIndex((suggestion) => suggestion.label === selected);
    if (index >= 0) { autocompleteState.highlightedIndex = index; updateHighlight(); }
  });
}

function updateAutocompleteRoomData() {
  // If autocomplete is visible and showing room suggestions, refresh them
  if (autocompleteState.isVisible) {
    handleAutocompleteInput();
  }
}

// =============================================================================
// WEBSOCKET CONNECTION MANAGEMENT
// =============================================================================

async function connectWebSocket() {
  if (window.NRCAssets && typeof window.NRCAssets.initAssets === "function") {
    await window.NRCAssets.initAssets();
  }

  // Clear any existing reconnection timer
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  const attemptText =
    reconnectAttempts > 0
      ? ` (attempt ${reconnectAttempts + 1}/${maxReconnectAttempts})`
      : "";
  logSystem(`CONNECTING TO WORKSPACE ${currentWorkspaceId}${attemptText}`, "websocket");

  ws = new WebSocket(getWsUrl());
  ws.binaryType = "arraybuffer"; // Crucial for binary data

  ws.onopen = () => {
    updateConnectionStatus(true);
    serverReady = false; // Reset server ready flag
    window.NRCCalendar?.disconnect();
    window.NRCAppointmentNotify?.disconnect();
    logSystem("CONNECTED; WAITING FOR SERVER READY", "websocket");

    // Update connection stats
    if (!initialConnection) {
      totalReconnects++;
      reconnectHistory.push(Date.now());
    }
    initialConnection = false;
    connectionStartTime = Date.now();
    startUptimeTimer();
    startRetransmissionLoop(); // Start reliability layer
    updateConnectionStatsDisplay(); // Update reconnect count immediately

    // Reset reconnection state on successful connection
    reconnectAttempts = 0;
    isReconnecting = false;

    // Store the initialization logic to run when server is ready
    pendingInitialization = async () => {
      logSystem("SERVER READY; INITIALIZING SESSION", "websocket");
      await initializeSession();
      window.NRCTaskSearch?.onReconnect?.();
      window.NRCTaskQuery?.update({ force: true });
      logSystem("SESSION READY", "websocket");
      const currentNoteShareRoute = parseNoteShareRouteFromHash();
      if (currentNoteShareRoute && window.NRCNotes?.loadSharedNoteView) {
        window.NRCNotes.loadSharedNoteView(currentNoteShareRoute);
      }
      const currentSullivanShareRoute = parseSullivanShareRouteFromHash();
      if (currentSullivanShareRoute && window.NRCAI?.openSullivanWithContext) {
        window.NRCAI.openSullivanWithContext(currentSullivanShareRoute.contextConvId, { focused: true });
      }
    };
  };

  ws.onclose = (event) => {
    updateConnectionStatus(false);
    serverReady = false; // Reset server ready flag
    window.NRCCalendar?.disconnect();
    window.NRCAppointmentNotify?.disconnect();
    window.NRCCustomers?.onDisconnect();
    pendingInitialization = null; // Clear any pending initialization
    retainedRoomStates.clear();
    retainedSubscriptionRequests.clear();
    retainedHistoryRequests.clear();
    retainedHistoryStarted.clear();
    retainedOperationQueue = [];
    retainedOperations.clear();
    for (const pending of pendingMessages.values()) {
      if (pending.retained) pending.timestamp = Number.POSITIVE_INFINITY;
    }
    stopPingInterval(); // Stop ping measurements
    stopUptimeTimer(); // Stop uptime timer
    connectionStartTime = 0;
    updateConnectionStatsDisplay();
    stopPresenceReconciliation(); // Stop reconciliation timer
    clearPendingOptimisticDMs();
    const wasCleanClose = event.wasClean;
    const closeCode = event.code;
    const closeReason = event.reason || "Unknown reason";

    if (window.NRCAssets && typeof window.NRCAssets.clearPendingAssetRpc === "function") {
      window.NRCAssets.clearPendingAssetRpc();
    }
    if (window.NRCTasks && typeof window.NRCTasks.clearPendingTaskRpcs === "function") {
      window.NRCTasks.clearPendingTaskRpcs();
    }
    window.NRCTaskSearch?.onDisconnect?.();
    window.NRCTransactions?.clearPendingTransactionRpc();
    if (window.NRCEdges && typeof window.NRCEdges.clearPendingEdgeRpc === "function") {
      window.NRCEdges.clearPendingEdgeRpc();
    }

    logMessage(
      "System",
      `DISCONNECTED (Code: ${closeCode}, Clean: ${wasCleanClose}, Reason: ${closeReason})`,
    );

    // Attempt reconnection unless it was a clean close or we've exceeded max attempts
    if (!wasCleanClose && reconnectAttempts < maxReconnectAttempts) {
      attemptReconnection();
    } else if (reconnectAttempts >= maxReconnectAttempts) {
      logMessage(
        "Error",
        `MAX RECONNECTION ATTEMPTS REACHED (${maxReconnectAttempts})`,
      );
      isReconnecting = false;
    }
  };

  ws.onerror = (error) => {
    updateConnectionStatus(false);
    logMessage("Error", `CONNECTION ERROR`);
    console.error("WebSocket Error:", error);
  };

  ws.onmessage = (event) => {
    localPacketsIn++;
    scheduleLocalStatsUpdate();
    if (event.data instanceof ArrayBuffer) {
      handleBinaryMessage(event.data);
    } else {
      logMessage("Received", `Received non-binary message: ${event.data}`);
    }
  };
}

function sendPacket(data) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(data);
    localPacketsOut++;

    // Track transport stats
    if (data instanceof ArrayBuffer) {
      trackTxFrame(data.byteLength);
    } else if (data instanceof Blob) {
      trackTxFrame(data.size);
    } else if (typeof data === "string") {
      // Approximate size for text frames
      trackTxFrame(new TextEncoder().encode(data).length);
    }

    scheduleLocalStatsUpdate();
  } else {
    console.error("Cannot send packet: WebSocket not open");
  }
}

// Initialize authenticated session
async function initializeSession() {
  // Scope 0 delivers durable workspace events, independently of chat rooms.
  subscribeToConversations([0n, ...subscribedRooms]);
  window.NRCAssets.sendGetAllAssets(0n);
  window.NRCTasks.loadActiveTasks(0n);

  if (window.NRCAssets?.sendGetRoomMappings) {
    window.NRCAssets.sendGetRoomMappings();
  }

  let messagesLoaded = 0;
  for (const roomId of subscribedRooms) {
    if (await loadMessagesFromStorage(roomId)) {
      messagesLoaded++;
    }
  }

  if (messagesLoaded > 0) {
    logSystem(`RESTORED MESSAGES FOR ${messagesLoaded} ROOM(S)`, "client", "DEBUG");
  }

  updateRoomUI();
  if (window.NRCAI?.isSullivanView?.()) {
    loadRoomHistory(window.NRCAI.getDisplayConvId(), { aiContextRoomId: window.NRCAI.getContextConvId() });
  } else {
    loadRoomHistory(currentRoomId);
  }
  startPresenceReconciliation();

  // Restore DMs (server will auto-resubscribe)
  requestDMList();

  // The reminder set is rebuilt per session; the timer decides what to report
  // once the workspace asset list has arrived.
  window.NRCReminderNotify?.sessionStarted?.();
  window.NRCAppointmentNotify?.restart();
  window.NRCAttention?.onSessionStarted?.();
  window.NRCCalendar?.refresh();
}

// --- Reconnection Logic ---

function attemptReconnection() {
  if (isReconnecting || reconnectAttempts >= maxReconnectAttempts) {
    return;
  }

  // Check if there's already a timer running
  if (reconnectTimer) {
    return;
  }

  isReconnecting = true;
  reconnectAttempts++;

  // Calculate delay with exponential backoff: min(baseDelay * 2^attempts, maxDelay)
  const delay = Math.min(
    baseReconnectDelay * Math.pow(2, reconnectAttempts - 1),
    maxReconnectDelay,
  );

  logMessage(
    "System",
    `RECONNECTING IN ${Math.round(delay / 1000)}s... (${reconnectAttempts}/${maxReconnectAttempts})`,
  );

  reconnectTimer = setTimeout(() => {
    // Clear the timer reference
    reconnectTimer = null;
    // Allow the connection attempt
    isReconnecting = false;
    connectWebSocket();
  }, delay);
}

function resetReconnection() {
  reconnectAttempts = 0;
  isReconnecting = false;
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

// =============================================================================
// TRANSPORT TRACKING
// =============================================================================

function trackRxFrame(size) {
  localPacketsIn++;
  rxBytesInterval += size;
  rxFramesInterval++;

  // Update frame size buffer (used for both avg and max)
  frameSizes.push(size);
  if (frameSizes.length > MAX_FRAME_SAMPLES) {
    frameSizes.shift();
  }
}

function trackTxFrame(size) {
  localPacketsOut++;
  txBytesInterval += size;
  txFramesInterval++;
}

function updateTransportStats() {
  const elRx = document.getElementById("statsRxRate");
  const elTx = document.getElementById("statsTxRate");
  const elAvg = document.getElementById("statsFrameAvg");
  const elMax = document.getElementById("statsFrameMax");
  const connected = ws?.readyState === WebSocket.OPEN;

  // Update Rates
  if (elRx) {
    elRx.textContent = connected ? `${formatBytes(rxBytesInterval)}/s` : "—";
  }
  if (elTx) {
    elTx.textContent = connected ? `${formatBytes(txBytesInterval)}/s` : "—";
  }

  // Reset interval counters
  rxBytesInterval = 0;
  rxFramesInterval = 0;
  txBytesInterval = 0;
  txFramesInterval = 0;

  // Update Frame Stats (both avg and max from same sample buffer)
  if (frameSizes.length > 0) {
    const total = frameSizes.reduce((a, b) => a + b, 0);
    const avg = Math.round(total / frameSizes.length);
    const max = Math.max(...frameSizes);
    if (elAvg) elAvg.textContent = `${avg} B`;
    if (elMax) elMax.textContent = `${max} B`;
  } else {
    if (elAvg) elAvg.textContent = "—";
    if (elMax) elMax.textContent = "—";
  }
}

function formatBytes(bytes) {
  if (bytes === 0) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(0)) + " " + sizes[i];
}

// =============================================================================
// PIPELINE TRACKING
// =============================================================================

function trackDecodeTime(duration) {
  decodeTimes.push(duration);
  if (decodeTimes.length > MAX_DECODE_SAMPLES) {
    decodeTimes.shift();
  }
}

function trackBurst() {
  burstFrames++;
  // Reset burst counter on next tick if not already scheduled
  if (!pipelineResetTimer) {
    pipelineResetTimer = requestAnimationFrame(() => {
      if (burstFrames > 10) {
        console.log(
          `[PIPELINE] Burst detected: ${burstFrames} frames in this tick`,
        );
      }
      if (burstFrames > maxBurstSize) {
        maxBurstSize = burstFrames;
        lastBurstTime = Date.now();
      }
      burstFrames = 0;
      pipelineResetTimer = null;
    });
  }
}

function updatePipelineStats() {
  const elDecode = document.getElementById("statsDecodeTime");
  const elBurst = document.getElementById("statsBurstRate");
  const elLag = document.getElementById("statsLoopLag");

  // Decode Time (Avg / Max)
  if (elDecode && decodeTimes.length > 0) {
    const avg = decodeTimes.reduce((a, b) => a + b, 0) / decodeTimes.length;
    const max = Math.max(...decodeTimes);
    elDecode.textContent = `${avg.toFixed(2)}ms (max ${max.toFixed(1)}ms)`;
  }

  // Burst Rate
  if (elBurst) {
    // Decay max burst over time: Reset if older than 2 seconds
    if (Date.now() - lastBurstTime > 2000) {
      maxBurstSize = 0;
    }
    elBurst.textContent = `${Math.max(1, maxBurstSize)} frames/tick`;
  }

  // Loop Lag
  const now = performance.now();
  const delta = now - lastLoopTime;
  lastLoopTime = now;

  // Calculate drift from expected 1000ms interval (since this is called by uptime timer)
  // But uptime timer is setInterval(1000), so delta should be ~1000.
  // Lag is excess time: delta - 1000.
  const lag = Math.max(0, delta - 1000);

  if (elLag) {
    elLag.textContent = `${lag.toFixed(1)}ms`;
    if (lag > 50) elLag.style.color = "var(--accent-danger)";
    else elLag.style.color = "";
  }
}

// =============================================================================
// UTILS
// =============================================================================

function generateRevHash(str) {
  let hash = 5381;
  for (let i = 0; i < str.length; i++) {
    hash = (hash << 5) + hash + str.charCodeAt(i); /* hash * 33 + c */
  }
  // Return as positive hex string (8 chars)
  return (hash >>> 0)
    .toString(16)
    .toUpperCase()
    .padStart(8, "0")
    .substring(0, 8);
}

// =============================================================================
// WEBSOCKET MESSAGE PARSING
// =============================================================================

function handleBinaryMessage(arrayBuffer) {
  const startDecode = performance.now();
  // Track transport stats
  trackRxFrame(arrayBuffer.byteLength);
  trackBurst();

  if (arrayBuffer.byteLength < 2) {
    logMessage("Error", "Received binary message too short for opcode.");
    return;
  }

  lastPacketTime = Date.now();

  const dataView = new DataView(arrayBuffer);
  const opcode = dataView.getUint16(0, false); // Big Endian

  try {
    switch (opcode) {
      case Opcode.S_ServerReady:
        logSystem("RECEIVED SERVER READY SIGNAL", "protocol", "DEBUG");
        if (!parseServerReady(dataView)) {
          serverReady = false;
          ws.close(1000, "Protocol version mismatch");
          break;
        }
        serverReady = true;
        window.NRCCustomers?.refreshAccess();
        // Start ping interval for latency measurement
        startPingInterval();
        // Retry any pending asset requests (agenda via assets)
        if (window.NRCAssets) {
          window.NRCAssets.retryPendingAssetRequests();
        }
        // Run pending initialization if we have any
        if (pendingInitialization) {
          const init = pendingInitialization;
          pendingInitialization = null; // Clear immediately to prevent double-run
          init();
        }
        break;
      case Opcode.S_AckSendMessage:
        parseAckSendMessage(dataView);
        break;
      case Opcode.S_NewMessage:
        parseNewMessage(dataView);
        break;
      case Opcode.S_SubscriptionReady:
        parseRetainedSubscriptionReady(dataView);
        break;
      case Opcode.S_MessagePage:
        parseRetainedMessagePage(dataView);
        break;
      case Opcode.S_RoomPresenceUpdate:
        parseRoomPresenceUpdate(dataView);
        break;
      case Opcode.S_StatsResponse:
        // Browser client no longer renders server stats from protocol payload.
        break;
      case Opcode.S_Pong:
        parsePongResponse(dataView);
        break;
      case Opcode.S_AckUnsubscribeConvs:
        parseAckUnsubscribeConvs(dataView);
        break;
      // Tasks/Kanban messages
      case Opcode.S_TaskCreated:
        if (window.NRCTasks) window.NRCTasks.handleTaskCreated(dataView);
        break;
      case Opcode.S_TaskUpdated:
        if (window.NRCTasks) window.NRCTasks.handleTaskUpdated(dataView);
        break;
      case Opcode.S_TaskDeleted:
        if (window.NRCTasks) window.NRCTasks.handleTaskDeleted(dataView);
        break;
      case Opcode.S_TaskMoved:
        if (window.NRCTasks) window.NRCTasks.handleTaskMoved(dataView);
        break;
      case Opcode.S_TaskListResponse:
        if (window.NRCTasks) window.NRCTasks.handleTaskListResponse(dataView);
        break;
      case Opcode.S_TaskListPage:
        if (window.NRCTasks) window.NRCTasks.handleTaskListPage(dataView);
        break;
      case Opcode.S_TaskFull:
        if (window.NRCTasks) window.NRCTasks.handleTaskFull(dataView);
        break;
      case Opcode.S_TaskQueryPage:
        window.NRCTaskQuery?.handlePage(dataView);
        window.NRCAttention?.handleTaskQueryPage?.(dataView);
        break;
      case Opcode.S_TaskProjects:
        window.NRCTaskQuery?.handleProjects(dataView);
        window.NRCAttention?.handleTaskProjects?.(dataView);
        window.NRCCalendar?.handleTaskProjects(dataView);
        break;
      case Opcode.S_TaskAssignees:
        window.NRCTaskQuery?.handleAssignees(dataView);
        window.NRCCalendar?.handleTaskAssignees(dataView);
        break;
      case Opcode.S_CalendarPage:
        window.NRCCalendar?.handlePage(dataView);
        window.NRCAppointmentNotify?.handlePage(dataView);
        break;
      case Opcode.S_TaskSliceList:
        window.NRCSlices?.handleSliceList(dataView);
        break;
      // Asset messages
      case Opcode.S_AssetCreated:
        window.NRCAssets.handleAssetCreated(dataView);
        break;
      case Opcode.S_AssetUpdated:
        window.NRCAssets.handleAssetUpdated(dataView);
        break;
      case Opcode.S_AssetDeleted:
        window.NRCAssets.handleAssetDeleted(dataView);
        break;
      case Opcode.S_AssetFull:
        window.NRCAssets.handleAssetFull(dataView);
        break;
      case Opcode.S_AssetList:
        window.NRCAssets.handleAssetList(dataView);
        break;
      case Opcode.S_AssetListPage:
        window.NRCAssets.handleAssetListPage(dataView);
        break;
      case Opcode.S_CustomerSearchPage:
        window.NRCAssets.handleCustomerSearchPage(dataView);
        break;
      case Opcode.S_NoteProjectList:
        window.NRCAssets.handleNoteProjectList(dataView);
        break;
      case Opcode.S_NoteTagList:
        window.NRCAssets.handleNoteTagList(dataView);
        break;
      // Edge/Knowledge Graph messages
      case Opcode.S_TransactionResult:
        window.NRCTransactions.handleTransactionApplied(dataView);
        break;
      case Opcode.S_EdgeCreated:
        if (window.NRCEdges) window.NRCEdges.handleEdgeCreated(dataView);
        break;
      case Opcode.S_EdgeDeleted:
        if (window.NRCEdges) window.NRCEdges.handleEdgeDeleted(dataView);
        break;
      case Opcode.S_EdgeList:
        if (window.NRCEdges) window.NRCEdges.handleEdgeList(dataView);
        break;
      case Opcode.S_AllEdgeList:
        if (window.NRCEdges) window.NRCEdges.handleAllEdgeList(dataView);
        break;
      case Opcode.S_AllEdgeListPage:
        window.NRCEdges.handleAllEdgeListPage(dataView);
        break;
      case Opcode.S_EdgeListPage:
        window.NRCEdges.handleEdgeListPage(dataView);
        break;
      // Graph Query messages
      case Opcode.S_GraphQueryResult:
        if (window.NRCEdges) window.NRCEdges.handleGraphQueryResult(dataView);
        break;
      case Opcode.S_GraphShortestPathResult:
        if (window.NRCEdges) window.NRCEdges.handleShortestPathResult(dataView);
        break;
      case Opcode.S_GraphDegreeResult:
        if (window.NRCEdges) window.NRCEdges.handleDegreeResult(dataView);
        break;
      case Opcode.S_GraphCommonNeighborsResult:
        if (window.NRCEdges) window.NRCEdges.handleCommonNeighborsResult(dataView);
        break;
      // Direct Messages
      case Opcode.S_DMStarted:
        parseDMStarted(dataView);
        break;
      case Opcode.S_DMList:
        parseDMList(dataView);
        break;
      case Opcode.S_DMError:
        parseDMError(dataView);
        break;
      case Opcode.S_DMLeft:
        parseDMLeft(dataView);
        break;
      case Opcode.S_DMPartnerStatus:
        parseDMPartnerStatus(dataView);
        break;
      case Opcode.S_ErrorResponse:
        parseErrorResponse(dataView);
        break;
      default:
        logMessage(
          "Received",
          `Received unknown binary message opcode: ${opcode}`,
        );
    }
  } catch (e) {
    logMessage(
      "Error",
      `Error parsing binary message (Opcode: ${opcode}): ${e.message}`,
    );
    console.error("Parsing error:", e);
  }

  // Track decode time
  trackDecodeTime(performance.now() - startDecode);
}

function parseSystemStats(dataView) {
  // Removed as S_SystemStats is deprecated
}

function parseServerReady(dataView) {
  // S_ServerReady Payload: { build_version: []byte, protocol_version: u32, cpu_model: []byte, username: []byte, is_authenticated: bool }
  let offset = 2; // Skip opcode

  if (dataView.byteLength < offset + 2) return false;

  const buildLen = dataView.getUint16(offset, false);
  offset += 2;
  if (dataView.byteLength < offset + buildLen + 4) return false;

  const buildBytes = new Uint8Array(dataView.buffer, offset, buildLen);
  const buildVersion = new TextDecoder("utf-8").decode(buildBytes);
  offset += buildLen;

  const protocolVersion = dataView.getUint32(offset, false);
  offset += 4;

  if (dataView.byteLength < offset + 2) return false;
  const cpuLen = dataView.getUint16(offset, false);
  offset += 2;
  if (dataView.byteLength < offset + cpuLen) return false;
  const cpuBytes = new Uint8Array(dataView.buffer, offset, cpuLen);
  const cpuModel = new TextDecoder("utf-8").decode(cpuBytes);
  offset += cpuLen;

  if (dataView.byteLength < offset + 2) return false;
  const usernameLen = dataView.getUint16(offset, false);
  offset += 2;
  if (dataView.byteLength < offset + usernameLen) return false;
  const usernameBytes = new Uint8Array(dataView.buffer, offset, usernameLen);
  const username = new TextDecoder("utf-8").decode(usernameBytes);
  offset += usernameLen;

  if (dataView.byteLength !== offset + 1) return false;
  const isAuthenticated = dataView.getUint8(offset) !== 0;
  offset += 1;

  if (username) {
    myNickname = username;
    nicknameReceived = true;
  }

  const authStatusEl = document.getElementById("authStatus");
  if (authStatusEl) {
    authStatusEl.textContent = isAuthenticated ? "VERIFIED" : "UNVERIFIED";
  }

  updateSystemStatsDisplay(buildVersion, protocolVersion, cpuModel);

  if (protocolVersion !== EXPECTED_PROTOCOL_VERSION) {
    logMessage(
      "Error",
      `PROTOCOL VERSION MISMATCH: server=${protocolVersion} client=${EXPECTED_PROTOCOL_VERSION}. UPDATE SERVER AND CLIENT TOGETHER.`,
    );
    return false;
  }
  return true;
}

function updateSystemStatsDisplay(build, proto, cpu) {
  const elBuild = document.getElementById("statsBuild");
  const elProto = document.getElementById("statsProto");
  const elCpu = document.getElementById("statsCpuModel");

  if (build !== null && elBuild) elBuild.textContent = build;
  if (proto !== null && elProto) elProto.textContent = `V${proto}`;
  if (cpu !== null && elCpu) {
    elCpu.textContent = cpu;
    elCpu.setAttribute("title", cpu);
  }
}

function updateLocalStatsDisplay() {
  const elIn = document.getElementById("statsIn");
  const elOut = document.getElementById("statsOut");
  if (elIn) elIn.textContent = localPacketsIn.toString();
  if (elOut) elOut.textContent = localPacketsOut.toString();
}

function updateConnectionStatsDisplay() {
  // Update Reconnects
  const elReconnects = document.getElementById("statsReconnects");
  if (elReconnects) {
    // Calculate recent reconnects (last 24h)
    const now = Date.now();
    const recent = reconnectHistory.filter(
      (t) => now - t < 24 * 60 * 60 * 1000,
    ).length;
    elReconnects.textContent = `${recent} in last 24h`;
  }

  // Update Last Packet
  const elLastPacket = document.getElementById("statsLastPacket");
  if (elLastPacket) {
    if (lastPacketTime > 0) {
      const diff = Date.now() - lastPacketTime;
      const seconds = Math.round(diff / 1000);
      elLastPacket.textContent = `${seconds}s ago`;
    } else {
      elLastPacket.textContent = "—";
    }
  }

  // Update Skew
  const elSkew = document.getElementById("statsSkew");
  if (elSkew) {
    const sign = serverClientSkew >= 0 ? "+" : "";
    const direction =
      serverClientSkew > 0
        ? "server ahead"
        : serverClientSkew < 0
          ? "server behind"
          : "synced";
    elSkew.textContent = `${sign}${serverClientSkew}ms (${direction})`;
  }

  // Update Retries
  const elRetries = document.getElementById("statsRetransmits");
  if (elRetries) {
    const now = Date.now();
    const recent = retransmitHistory.filter((t) => now - t < 60 * 1000).length;
    elRetries.textContent = `${retransmitCount} (${recent} recent)`;
  }

  // Update Uptime
  const elUptime = document.getElementById("statsUptime");
  if (elUptime && connectionStartTime > 0) {
    const now = Date.now();
    const uptimeMs = now - connectionStartTime;

    const totalSeconds = Math.floor(uptimeMs / 1000);
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;

    const pad = (n) => n.toString().padStart(2, "0");
    elUptime.textContent = `${pad(hours)}:${pad(minutes)}:${pad(seconds)}`;
  } else if (elUptime) {
    elUptime.textContent = "00:00:00";
  }

  // Update Transport Stats
  updateTransportStats();
  updatePipelineStats();
}

function startUptimeTimer() {
  stopUptimeTimer();
  updateConnectionStatsDisplay(); // Initial update
  uptimeInterval = setInterval(updateConnectionStatsDisplay, 1000);
}

function stopUptimeTimer() {
  if (uptimeInterval) {
    clearInterval(uptimeInterval);
    uptimeInterval = null;
  }
}

// =============================================================================
// RELIABILITY & RETRANSMISSION
// =============================================================================

function startRetransmissionLoop() {
  if (retransmissionInterval) {
    clearInterval(retransmissionInterval);
  }
  // Check for retransmissions every 50ms
  retransmissionInterval = setInterval(checkRetransmissions, 50);
}

function stopRetransmissionLoop() {
  if (retransmissionInterval) {
    clearInterval(retransmissionInterval);
    retransmissionInterval = null;
  }
}

function checkRetransmissions() {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const now = Date.now();
  const RETRY_TIMEOUT = 5000;
  const MAX_RETRIES = 3;

  for (const [reqId, msgData] of pendingMessages.entries()) {
    if (now - msgData.timestamp > RETRY_TIMEOUT) {
      // Time to retry?
      if (msgData.attempts < MAX_RETRIES) {
        console.warn(
          `Retransmitting message ${reqId} (Attempt ${msgData.attempts + 1})`,
        );

        // Retransmit
        sendPacket(msgData.buffer);

        // Update state
        msgData.timestamp = now; // Reset timer
        msgData.attempts++;

        // Update stats
        retransmitCount++;
        retransmitHistory.push(now);
      } else {
        console.error(
          `Message ${reqId} has no ACK after ${MAX_RETRIES} retries.`,
        );
        if (msgData.retained) {
          msgData.timestamp = Number.POSITIVE_INFINITY;
          logMessage("Error", "MESSAGE ACK DELAYED; WAITING FOR SERVER OR RECONNECT");
        } else {
          pendingMessages.delete(reqId);
          logMessage("Error", `Failed to send message after ${MAX_RETRIES} attempts.`);
        }
      }
    }
  }
}

function parseAckSendMessage(dataView) {
  // S_AckSendMessage Payload: { client_req_id: u32, assigned_seq: u64, timestamp: i64 }
  let offset = 2; // Skip opcode

  if (dataView.byteLength < offset + 4 + 8 + 8) {
    console.error("Received S_AckSendMessage payload too short.");
    return;
  }

  const clientReqId = dataView.getUint32(offset, false);
  offset += 4;
  const assignedSeq = dataView.getBigUint64(offset, false);
  offset += 8;
  const timestamp = dataView.getBigInt64(offset, false);
  offset += 8;

  lastAckTime = Date.now();

  // Remove from pending messages (Ack received)
  const pending = pendingMessages.get(clientReqId);
  if (pending) {
    if (pending.messageData) {
      pending.messageData.sequence = assignedSeq;
      pending.messageData.timestamp = Number(timestamp / 1000000n);
      const history = roomHistory.get(pending.messageData.roomId);
      if (history) sortRoomMessages(history);
      if (isConversationVisible(pending.messageData.roomId, pending.messageData)) {
        loadRoomHistory(pending.messageData.roomId);
      }
    }
    pendingMessages.delete(clientReqId);
    completeRetainedOperation(clientReqId);
  }

  // Don't show ack messages in chat - just log to console for debugging
  console.log(`Message acknowledged - REQ:${clientReqId} SEQ:${assignedSeq}`);
}

function parseErrorResponse(dataView) {
  let offset = 2; // Skip opcode

  if (dataView.byteLength < offset + 2 + 2) {
    console.error("S_ErrorResponse payload too short");
    return;
  }

  const originOpcode = dataView.getUint16(offset, false);
  offset += 2;

  const errorMsgLen = dataView.getUint16(offset, false);
  offset += 2;

  let errorMsg = "";
  if (errorMsgLen > 0 && dataView.byteLength >= offset + errorMsgLen) {
    errorMsg = new TextDecoder().decode(new Uint8Array(dataView.buffer, offset, errorMsgLen));
    offset += errorMsgLen;
  }

  if (dataView.byteLength < offset + 4) {
    console.error("S_ErrorResponse missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);

  const opcodeName = Object.entries(Opcode).find(([, v]) => v === originOpcode)?.[0] || `opcode ${originOpcode}`;
  console.error(`[S_ErrorResponse] ${opcodeName}: ${errorMsg} (corr=${correlationId})`);

  if (originOpcode === Opcode.C_SendMessageV2) {
    const pending = pendingMessages.get(correlationId);
    completeRetainedOperation(correlationId);
    if (pending && errorMsg === "too many retained message operations" && pending.attempts < 3) {
      pending.attempts++;
      pending.timestamp = Number.POSITIVE_INFINITY;
      queueRetainedOperation(correlationId, "send", pending.buffer, () => {
        pending.timestamp = Date.now();
      });
      return;
    }
    pendingMessages.delete(correlationId);
  }
  if (originOpcode === Opcode.C_SubscribeConvsV2) retainedSubscriptionRequests.delete(correlationId);
  if (originOpcode === Opcode.C_ListMessagesBefore || originOpcode === Opcode.C_ReplayMessagesAfter) {
    const request = retainedHistoryRequests.get(correlationId);
    completeRetainedOperation(correlationId);
    if (request && errorMsg === "too many retained message operations" && request.attempts < 3) {
      request.attempts++;
      queueRetainedOperation(correlationId, "history", request.buffer);
      return;
    }
    if (request) retainedHistoryStarted.delete(request.convId);
    retainedHistoryRequests.delete(correlationId);
  }

  if (dispatchCentralizedErrorResponse(originOpcode, correlationId, errorMsg, opcodeName)) {
    return;
  }

  logMessage("Error", `Server error for ${opcodeName}: ${errorMsg}`);
}

function dispatchCentralizedErrorResponse(originOpcode, correlationId, errorMsg, opcodeName) {
  if (window.NRCTransactions?.handleTransactionErrorResponse(originOpcode, correlationId, errorMsg)) {
    return true;
  }
  if (
    window.NRCTasks &&
    typeof window.NRCTasks.handleTaskErrorResponse === "function" &&
    window.NRCTasks.handleTaskErrorResponse(originOpcode, correlationId, errorMsg)
  ) {
    return true;
  }

  if (
    window.NRCAssets &&
    typeof window.NRCAssets.handleAssetErrorResponse === "function" &&
    window.NRCAssets.handleAssetErrorResponse(originOpcode, correlationId, errorMsg)
  ) {
    return true;
  }

  if (
    window.NRCEdges &&
    typeof window.NRCEdges.handleEdgeErrorResponse === "function" &&
    window.NRCEdges.handleEdgeErrorResponse(originOpcode, correlationId, errorMsg)
  ) {
    return true;
  }

  // Keep DM-specific error channel behavior unchanged.
  if (originOpcode === Opcode.C_StartDM) {
    clearPendingOptimisticDMs();
    return false;
  }

  return false;
}

// =============================================================================
// DIRECT MESSAGES - PROTOCOL
// =============================================================================

function sendStartDM(targetUsername, options = {}) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    logMessage("Error", "NOT CONNECTED");
    return false;
  }

  const allowExisting = options.allowExisting === true;

  // Check if we already have a DM with this user
  let existingDM = null;
  for (const [, dm] of activeDMs) {
    if (dm.username === targetUsername && !dm.optimistic) {
      existingDM = dm;
      break;
    }
  }
  if (existingDM && !allowExisting) {
    return false;
  }

  if (pendingDMStarts.has(targetUsername)) {
    const pending = pendingDMStarts.get(targetUsername);
    if (options.suppressAutoSwitch === true) {
      suppressedDMStartCorrelations.add(pending.correlationId);
    }
    return true;
  }

  // Check if we already have a pending optimistic DM for this user
  if (pendingOptimisticDMs.has(targetUsername)) {
    if (options.suppressAutoSwitch === true) {
      suppressedDMStartCorrelations.add(pendingOptimisticDMs.get(targetUsername).correlationId);
    }
    return true;
  }

  // Debounce per target so starting an unrelated human DM cannot suppress Sullivan.
  const now = Date.now();
  const lastStartTime = lastDMStartTimes.get(targetUsername) || 0;
  if (now - lastStartTime < DM_START_DEBOUNCE_MS) return false;
  lastDMStartTimes.set(targetUsername, now);

  const correlationId =
    window.NRCAssets && typeof window.NRCAssets.generateCorrelationId === "function"
      ? window.NRCAssets.generateCorrelationId()
      : (clientRequestIdCounter = ((clientRequestIdCounter + 1) >>> 0) || 1);
  if (options.suppressAutoSwitch === true) suppressedDMStartCorrelations.add(correlationId);

  const timeout = setTimeout(() => {
    pendingDMStarts.delete(targetUsername);
    const optimistic = pendingOptimisticDMs.get(targetUsername);
    if (optimistic) {
      activeDMs.delete(optimistic.tempId);
      pendingOptimisticDMs.delete(targetUsername);
      updateDMListUI();
    }
    logMessage("Error", `DM WITH ${targetUsername} TIMED OUT`);
  }, DM_OPTIMISTIC_TIMEOUT_MS);
  pendingDMStarts.set(targetUsername, {
    timeout,
    correlationId,
  });

  if (!existingDM) {
    // Add optimistic entry
    optimisticDMCounter += 1n;
    const tempId = -optimisticDMCounter; // Negative IDs for optimistic entries
    activeDMs.set(tempId, {
      username: targetUsername,
      authenticated: false,
      online: true,
      lastSeen: 0,
      unread: 0,
      optimistic: true,
    });

    pendingOptimisticDMs.set(targetUsername, {
      tempId,
      timeout,
      correlationId,
    });
    updateDMListUI();
  }

  const usernameBytes = new TextEncoder().encode(targetUsername);
  const buf = new ArrayBuffer(2 + 2 + usernameBytes.length + 4);
  const view = new DataView(buf);

  view.setUint16(0, Opcode.C_StartDM, false);
  view.setUint16(2, usernameBytes.length, false);
  new Uint8Array(buf, 4).set(usernameBytes);
  view.setUint32(4 + usernameBytes.length, correlationId, false);

  sendPacket(buf);
  return true;
}

function requestDMList() {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId =
    window.NRCAssets && typeof window.NRCAssets.generateCorrelationId === "function"
      ? window.NRCAssets.generateCorrelationId()
      : 0;

  const buf = new ArrayBuffer(6);
  const view = new DataView(buf);
  view.setUint16(0, Opcode.C_ListDMs, false);
  view.setUint32(2, correlationId, false);
  sendPacket(buf);
}

function sendLeaveDM(convId) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const convIdBig = BigInt(convId);
  if (pendingLeaveDMs.has(convIdBig)) return;

  pendingLeaveDMs.add(convIdBig);

  const correlationId =
    window.NRCAssets && typeof window.NRCAssets.generateCorrelationId === "function"
      ? window.NRCAssets.generateCorrelationId()
      : 0;

  const buf = new ArrayBuffer(2 + 8 + 4);
  const view = new DataView(buf);
  view.setUint16(0, Opcode.C_LeaveDM, false);
  view.setBigUint64(2, convIdBig, false);
  view.setUint32(10, correlationId, false);
  sendPacket(buf);
}

function parseDMStarted(dataView) {
  let offset = 2; // Skip opcode

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const usernameLen = dataView.getUint16(offset, false);
  offset += 2;

  const username = new TextDecoder().decode(
    new Uint8Array(dataView.buffer, offset, usernameLen),
  );
  offset += usernameLen;

  const authenticated = dataView.getUint8(offset) !== 0;
  offset += 1;

  const online = dataView.getUint8(offset) !== 0;
  offset += 1;

  const isInitiator = dataView.getUint8(offset) !== 0;
  offset += 1;

  if (dataView.byteLength < offset + 4) {
    console.error("S_DMStarted missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);

  // Clear optimistic entry if pending for this username
  const suppressAutoSwitch = suppressedDMStartCorrelations.delete(correlationId);
  if (pendingDMStarts.get(username)?.correlationId === correlationId) {
    const pending = pendingDMStarts.get(username);
    clearTimeout(pending.timeout);
    pendingDMStarts.delete(username);
  }
  if (pendingOptimisticDMs.get(username)?.correlationId === correlationId) {
    const pending = pendingOptimisticDMs.get(username);
    clearTimeout(pending.timeout);
    activeDMs.delete(pending.tempId); // Remove optimistic entry
    pendingOptimisticDMs.delete(username);
  }

  // Store/update DM with real data. Unread is cleared only after the target
  // conversation has actually been opened and rendered.
  const previousUnread = activeDMs.get(convId)?.unread || 0;
  activeDMs.set(convId, {
    username,
    authenticated,
    online,
    lastSeen: Date.now(),
    unread: previousUnread,
    optimistic: false,
  });
  subscribedRooms.add(convId);

  // Update UI
  updateDMListUI();
  updateRoomUI();

  // Show contextual notification based on who initiated
  if (isInitiator) {
    logSystem(`DM OPENED WITH ${formatDMDisplayName(username, authenticated)}`, "dm");
    // Auto-switch to the new DM conversation
    if (!suppressAutoSwitch) switchToRoom(convId);
  } else {
    logSystem(`${formatDMDisplayName(username, authenticated)} STARTED A DM WITH YOU`, "dm");
    showDMNotification(convId, username, authenticated);
  }

  // Keep correlation_id available for debugging when present.
  if (correlationId) {
    console.debug("[S_DMStarted] correlation_id:", correlationId);
  }
}

function parseDMList(dataView) {
  let offset = 2; // Skip opcode

  const count = dataView.getUint16(offset, false);
  offset += 2;

  if (dataView.byteLength < offset + 4) {
    console.error("S_DMList missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);
  offset += 4;

  // Preserve unread counts from existing DMs
  const oldUnreads = new Map();
  const oldDMIds = new Set(activeDMs.keys());
  const previousSullivanDisplayId = window.NRCAI?.getDisplayConvId?.();
  for (const [convId, dm] of activeDMs) {
    if (dm.unread > 0) {
      oldUnreads.set(convId, dm.unread);
    }
  }

  activeDMs.clear();

  for (let i = 0; i < count; i++) {
    const convId = dataView.getBigUint64(offset, false);
    offset += 8;

    const usernameLen = dataView.getUint16(offset, false);
    offset += 2;

    const username = new TextDecoder().decode(
      new Uint8Array(dataView.buffer, offset, usernameLen),
    );
    offset += usernameLen;

    const authenticated = dataView.getUint8(offset) !== 0;
    offset += 1;

    const online = dataView.getUint8(offset) !== 0;
    offset += 1;

    const lastSeen = Number(dataView.getBigUint64(offset, false)) * 1000; // Convert to ms
    offset += 8;

    activeDMs.set(convId, {
      username,
      authenticated,
      online,
      lastSeen,
      unread: oldUnreads.get(convId) || 0,
      optimistic: false,
    });
    subscribedRooms.add(convId);
    oldDMIds.delete(convId);
    if (pendingDMStarts.has(username)) {
      clearTimeout(pendingDMStarts.get(username).timeout);
      pendingDMStarts.delete(username);
    }
    if (pendingOptimisticDMs.has(username)) {
      clearTimeout(pendingOptimisticDMs.get(username).timeout);
      pendingOptimisticDMs.delete(username);
    }
  }

  for (const staleDMId of oldDMIds) {
    subscribedRooms.delete(staleDMId);
  }
  if (previousSullivanDisplayId != null && !activeDMs.has(BigInt(previousSullivanDisplayId))) {
    window.NRCAI?.onDisplayConversationRemoved?.(previousSullivanDisplayId);
  }
  updateDMListUI();
  updateRoomUI();

  if (correlationId) {
    console.debug("[S_DMList] correlation_id:", correlationId);
  }
}

function parseDMError(dataView) {
  let offset = 2;

  const errorCode = dataView.getUint8(offset);
  offset += 1;

  const usernameLen = dataView.getUint16(offset, false);
  offset += 2;

  const targetUsername = new TextDecoder().decode(
    new Uint8Array(dataView.buffer, offset, usernameLen),
  );
  offset += usernameLen;

  const msgLen = dataView.getUint16(offset, false);
  offset += 2;

  const message = new TextDecoder().decode(
    new Uint8Array(dataView.buffer, offset, msgLen),
  );
  offset += msgLen;

  if (dataView.byteLength < offset + 4) {
    console.error("S_DMError missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);

  // If this is an idempotent leave race, treat as successful cleanup.
  if (errorCode === 3) {
    for (const convId of pendingLeaveDMs) {
      if (!activeDMs.has(convId)) {
        continue;
      }

      const dm = activeDMs.get(convId);
      const sameTarget = !targetUsername || dm?.username === targetUsername;
      if (!sameTarget) {
        continue;
      }

      pendingLeaveDMs.delete(convId);
      window.NRCAI?.onDisplayConversationRemoved?.(convId);
      activeDMs.delete(convId);
      subscribedRooms.delete(convId);
      if (currentRoomId === convId) {
        switchToRoom(DEFAULT_ROOM_ID);
      }
      updateDMListUI();
      updateRoomUI();
      logSystem("LEFT DM", "dm");
      return;
    }
  }

  const errorMessages = {
    1: "USER NOT FOUND",
    2: "CANNOT DM YOURSELF",
    3: "DM NOT FOUND",
    4: "NOT AUTHENTICATED",
  };

  logMessage("Error", `DM ERROR: ${errorMessages[errorCode] || message}`);
  if (correlationId) {
    console.debug("[S_DMError] correlation_id:", correlationId);
  }

  // Clean up the specific pending optimistic DM entry
  suppressedDMStartCorrelations.delete(correlationId);
  if (targetUsername) {
    if (pendingDMStarts.get(targetUsername)?.correlationId === correlationId) {
      clearTimeout(pendingDMStarts.get(targetUsername).timeout);
      pendingDMStarts.delete(targetUsername);
    }
  }
  if (targetUsername && pendingOptimisticDMs.get(targetUsername)?.correlationId === correlationId) {
    const pending = pendingOptimisticDMs.get(targetUsername);
    clearTimeout(pending.timeout);
    activeDMs.delete(pending.tempId);
    pendingOptimisticDMs.delete(targetUsername);
    updateDMListUI();
  }
}

function parseDMLeft(dataView) {
  if (dataView.byteLength < 14) {
    console.error("S_DMLeft missing correlation_id");
    return;
  }
  const convId = dataView.getBigUint64(2, false);
  const correlationId = dataView.getUint32(10, false);
  pendingLeaveDMs.delete(convId);
  window.NRCAI?.onDisplayConversationRemoved?.(convId);

  // Remove from local state
  activeDMs.delete(convId);
  subscribedRooms.delete(convId);

  // If currently viewing this DM, switch to the default room
  if (currentRoomId === convId) {
    switchToRoom(DEFAULT_ROOM_ID);
  }

  updateDMListUI();
  updateRoomUI();
  logSystem("LEFT DM", "dm");

  if (correlationId) {
    console.debug("[S_DMLeft] correlation_id:", correlationId);
  }
}

function parseDMPartnerStatus(dataView) {
  let offset = 2;
  const convId = dataView.getBigUint64(offset, false);
  offset += 8;
  const online = dataView.getUint8(offset) !== 0;
  offset += 1;
  const usernameLen = dataView.getUint16(offset, false);
  offset += 2;
  const usernameBytes = new Uint8Array(dataView.buffer, offset, usernameLen);
  offset += usernameLen;
  const username = new TextDecoder().decode(usernameBytes);
  const lastSeen = Number(dataView.getBigUint64(offset, false)) * 1000; // Convert to ms

  const dm = activeDMs.get(convId);
  if (dm) {
    dm.online = online;
    dm.lastSeen = lastSeen;
    updateDMListUI();
  }
}

// =============================================================================
// DIRECT MESSAGES - UI
// =============================================================================

function updateDMListUI() {
  const container = document.getElementById("dmList");
  if (!container) return;

  container.innerHTML = "";
  let dmCount = 0;
  let aiUnread = false;

  for (const [convId, dm] of activeDMs) {
    const isAI = isAIDMConversation(convId);
    if (isAI) {
      aiUnread ||= (dm.unread || 0) > 0;
      continue;
    }
    dmCount++;
    const el = document.createElement("div");
    el.className = "btn nav-tab room-item dm-entry";
    el.setAttribute("role", "button");
    el.tabIndex = 0;
    el.addEventListener("keydown", event => {
      if (event.target === el && (event.key === "Enter" || event.key === " ")) { event.preventDefault(); el.click(); }
    });
    el.dataset.dmId = convId.toString();
    const activeView = window.NRCViewManager?.getActiveView?.();
    const sullivanActive = activeView === "sullivan" || activeView === "sullivanShare";
    if (!sullivanActive && convId === currentRoomId) {
      el.classList.add("active");
    }

    // Optimistic entries show "connecting" state
    if (dm.optimistic) {
      el.classList.add("dm-optimistic");
      el.innerHTML = `
                <span class="dm-username">${escapeHtml(formatDMDisplayName(dm.username, dm.authenticated))}</span>
                <span class="dm-status connecting"></span>
            `;
    } else {
      const statusClass = dm.online ? "online" : "offline";
      const authClass = dm.authenticated ? "authenticated" : "";
      const unreadBadge =
        dm.unread > 0 ? '<span class="dm-unread-badge"></span>' : "";
      const lastSeenText =
        !dm.online && dm.lastSeen ? formatLastSeen(dm.lastSeen) : "";

      el.innerHTML = `
                <span class="dm-username ${authClass}">${escapeHtml(formatDMDisplayName(dm.username, dm.authenticated))}</span>
                <span class="dm-status ${statusClass}"></span>
                ${lastSeenText ? `<span class="dm-last-seen">${lastSeenText}</span>` : ""}
                ${unreadBadge}
                <button class="dm-leave-btn" title="Leave DM">×</button>
            `;

      // Attach leave button handler
      const leaveBtn = el.querySelector(".dm-leave-btn");
      if (leaveBtn) {
        leaveBtn.onclick = (e) => {
          e.stopPropagation();
          sendLeaveDM(convId);
        };
      }
    }

    el.onclick = () => openChatRoom(convId);
    container.appendChild(el);
  }

  const unread = document.getElementById("sullivanViewUnread");
  if (unread) unread.hidden = !aiUnread;
  if (dmCount === 0) container.innerHTML = '<div class="dm-empty">NO ACTIVE DMS</div>';
  window.NRCChat.update();
}

function formatLastSeen(timestamp) {
  const now = Date.now();
  const diff = now - timestamp;

  const seconds = Math.floor(diff / 1000);
  if (seconds < 60) return "just now";

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;

  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function formatDMDisplayName(username, authenticated = false) {
  if (typeof username !== "string") {
    return username;
  }

  if (username.includes("-")) {
    // AI bot DMs should keep a stable base label even when offline/auth state changes.
    if (username.toLowerCase().startsWith(AI_BOT_PREFIX)) {
      return username.split("-")[0];
    }
    if (authenticated) {
      return username.split("-")[0];
    }
  }
  return username;
}

function showDMNotification(convId, username, authenticated = false) {
  const displayName = formatDMDisplayName(username, authenticated);

  // Flash the DM entry in sidebar
  const dmEntry = document.querySelector(`[data-dm-id="${convId}"]`);
  if (dmEntry) {
    dmEntry.classList.add("dm-new");
    setTimeout(() => dmEntry.classList.remove("dm-new"), 5000);
  }

  // Show toast (if not already viewing this DM)
  if (currentRoomId !== convId) {
    showToast(`NEW DM FROM ${displayName}`, () => switchToRoom(convId));
    incrementUnread();
  }
}

function showToast(message, onClick) {
  // Remove any existing toast
  const existing = document.querySelector(".toast");
  if (existing) existing.remove();

  const toast = document.createElement("div");
  toast.className = "toast";
  toast.textContent = message;
  toast.onclick = () => {
    onClick?.();
    toast.remove();
  };
  // Native modal dialogs are above the page's stacking contexts.
  (NRCModal.activeRoot() || document.body).appendChild(toast);

  // Auto-dismiss after 5 seconds
  setTimeout(() => toast.remove(), 5000);
}

const NRCDialog = (() => {
  let activeDialog = null;

  function closeActiveDialog(result) {
    if (!activeDialog) return;
    const { view, resolve } = activeDialog;
    activeDialog = null;
    view.close();
    resolve(result);
  }

  function openDialog({ title, message, bodyBuilder, actionsBuilder, onEnter }) {
    if (activeDialog) {
      closeActiveDialog(false);
    }

    return new Promise((resolve) => {
      const view = NRCModal.create({ title, onCancel: () => closeActiveDialog(false) });
      const { panel, actions } = view;

      const messageEl = document.createElement("div");
      messageEl.className = "nrc-dialog-message";
      messageEl.textContent = message;
      panel.appendChild(messageEl);

      const bodyResult = bodyBuilder ? bodyBuilder(panel) : null;

      actionsBuilder(actions, bodyResult);
      panel.appendChild(actions);
      view.root.addEventListener("keydown", (event) => {
        if (event.key === "Enter" && event.target.tagName !== "BUTTON" && !event.shiftKey && onEnter) {
          event.preventDefault();
          onEnter(bodyResult);
        }
      });
      activeDialog = { view, resolve };
      view.show();
      bodyResult?.input?.select();
    });
  }

  function createButton(label, style, onClick) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = style ? `btn ${style}` : "btn";
    button.textContent = label;
    button.onclick = onClick;
    return button;
  }

  return {
    notify(message, options = {}) {
      const { onClick = null, logType = null } = options;
      showToast(message, onClick);
      if (logType && typeof logMessage === "function") {
        logMessage(logType, message);
      }
    },

    confirm(message, options = {}) {
      const {
        title = "CONFIRM ACTION",
        confirmLabel = "Confirm",
        cancelLabel = "Cancel",
      } = options;

      return openDialog({
        title,
        message,
        actionsBuilder(actions) {
          const cancelBtn = createButton(cancelLabel, "", () =>
            closeActiveDialog(false),
          );
          const confirmBtn = createButton(confirmLabel, "btn--danger", () =>
            closeActiveDialog(true),
          );
          actions.appendChild(cancelBtn);
          actions.appendChild(confirmBtn);
        },
        onEnter() {
          closeActiveDialog(true);
        },
      });
    },

    prompt(message, options = {}) {
      const {
        title = "INPUT REQUIRED",
        placeholder = "",
        submitLabel = "Create",
        cancelLabel = "Cancel",
        initialValue = "",
      } = options;

      return openDialog({
        title,
        message,
        bodyBuilder(panel) {
          const input = document.createElement("input");
          input.className = "nrc-dialog-input";
          input.type = "text";
          input.placeholder = placeholder;
          input.value = initialValue;
          panel.appendChild(input);
          return { input };
        },
        actionsBuilder(actions, bodyResult) {
          const cancelBtn = createButton(cancelLabel, "", () =>
            closeActiveDialog(null),
          );
          const submitBtn = createButton(submitLabel, "btn--primary", () => {
            const value = bodyResult.input.value.trim();
            closeActiveDialog(value || null);
          });
          actions.appendChild(cancelBtn);
          actions.appendChild(submitBtn);
        },
        onEnter(bodyResult) {
          const value = bodyResult.input.value.trim();
          closeActiveDialog(value || null);
        },
      });
    },
  };
})();

window.NRCDialog = NRCDialog;

function onDMMessageReceived(convId) {
  if (String(convId) === String(getVisibleConversationId())) return;

  const dm = activeDMs.get(convId);
  if (dm) {
    dm.unread = (dm.unread || 0) + 1;
    updateDMListUI();
  }
}

function isMobileConversationCovered() {
  return matchMedia("(max-width: 768px)").matches &&
    (document.body.classList.contains("mobile-navigation-open") || document.body.classList.contains("inspector-open"));
}

function getVisibleConversationId() {
  if (isMobileConversationCovered()) return null;
  if (window.NRCAI?.isSullivanView?.()) {
    return window.NRCAI.getDisplayConvId?.();
  }
  if (window.NRCViewManager?.getActiveView?.() !== "chat" || systemLogVisible) {
    return null;
  }
  return currentRoomId;
}

function updateChatUnreadCount() {
  for (const row of document.querySelectorAll("#roomList [data-room]")) {
    const count = Number(roomActivity.get(BigInt(row.dataset.room))) || 0;
    const badge = row.querySelector(".sidebar-unread-count");
    badge.textContent = count > 0 ? String(count).padStart(2, "0") : "";
    badge.hidden = count === 0;
    badge.setAttribute("aria-label", `${count} unread message${count === 1 ? "" : "s"}`);
    row.classList.toggle("has-activity", count > 0);
  }
  const mobileBadge = document.getElementById("mobileChatUnread");
  if (mobileBadge) {
    const count = Number(roomActivity.get(currentRoomId)) || 0;
    mobileBadge.textContent = count > 0 ? String(count).padStart(2, "0") : "";
    mobileBadge.hidden = count === 0;
  }
}

function markConversationUnread(convId) {
  roomActivity.set(convId, (Number(roomActivity.get(convId)) || 0) + 1);
  if (isDMConversation(convId)) onDMMessageReceived(convId);
  updateChatUnreadCount();
  window.NRCAttention?.refreshSoon?.();
}

function clearConversationUnread(convId) {
  roomActivity.delete(convId);
  if (isDMConversation(convId)) clearDMUnread(convId);
  updateChatUnreadCount();
  window.NRCAttention?.refreshSoon?.();
}

window.NRCChatUnread = {
  onViewChanged(view) {
    window.NRCChat.update();
    if (view === "chat" && !systemLogVisible) {
      clearConversationUnread(currentRoomId);
    } else {
      updateChatUnreadCount();
    }
  },
  // One source for every unread reading: the count is the same bookkeeping the
  // sidebar badges render, so the register and the badges can never disagree.
  // The chat map adds the detail behind it — mentions, authors, sequences.
  snapshot() {
    const entries = [];
    for (const [convId, count] of roomActivity) {
      if (!(count > 0)) continue;
      const detail = window.NRCChat?.unreadDetail?.(convId) || {};
      entries.push({ convId, count, ...detail });
    }
    return entries;
  },
};

function clearDMUnread(convId) {
  const dm = activeDMs.get(convId);
  if (dm && dm.unread > 0) {
    dm.unread = 0;
    updateDMListUI();
  }
}

function showDMUserPicker() {
  const picker = document.getElementById("dmUserPicker");
  if (!picker) return;

  const input = document.getElementById("dmUserSearch");
  picker.classList.remove("hidden");
  if (input) {
    input.value = "";
    input.focus();
  }
  filterDMUsers();
}

function hideDMUserPicker() {
  const picker = document.getElementById("dmUserPicker");
  if (picker) picker.classList.add("hidden");
}

function filterDMUsers() {
  const input = document.getElementById("dmUserSearch");
  const dropdown = document.getElementById("dmUserDropdown");
  if (!input || !dropdown) return;

  const query = input.value.toLowerCase().trim();

  // Get users from room presence of current room
  const currentPresence = roomPresence.get(currentRoomId);
  const users = currentPresence ? Array.from(currentPresence.keys()) : [];

  // Filter: exclude self, match query
  const filtered = users.filter(
    (user) => user.toLowerCase().includes(query) && user !== myNickname,
  );

  dropdown.innerHTML = "";

  if (filtered.length === 0) {
    dropdown.innerHTML = '<div class="dm-user-empty">NO USERS FOUND</div>';
    return;
  }

  filtered.forEach((user) => {
    const option = document.createElement("div");
    option.className = "dm-user-option";
    option.textContent = user;
    option.onclick = () => {
      sendStartDM(user);
      hideDMUserPicker();
    };
    dropdown.appendChild(option);
  });
}

function initDMUserPicker() {
  const startBtn = document.getElementById("startDMBtn");
  const input = document.getElementById("dmUserSearch");
  const picker = document.getElementById("dmUserPicker");

  if (startBtn) {
    startBtn.onclick = showDMUserPicker;
  }

  if (input) {
    input.oninput = filterDMUsers;
    input.onkeydown = (e) => {
      if (e.key === "Escape") {
        hideDMUserPicker();
      } else if (e.key === "Enter") {
        const firstOption = document.querySelector(".dm-user-option");
        if (firstOption) firstOption.click();
      }
    };
  }

  // Close picker when clicking outside
  if (picker) {
    const wrapper = document.querySelector(".dm-picker-wrapper");
    document.addEventListener("click", (e) => {
      if (
        !picker.classList.contains("hidden") &&
        wrapper &&
        !wrapper.contains(e.target)
      ) {
        hideDMUserPicker();
      }
    });
  }
}

function parseRoomPresenceUpdate(dataView) {
  // S_RoomPresenceUpdate Payload: { conv_id: u64, event_type: u8, sequence: u64, username: []byte, is_authenticated: bool, user_type: u8, old_username: []byte, user_list: []{username: []byte, is_authenticated: bool, user_type: u8} }
  let offset = 2; // Skip opcode

  if (dataView.byteLength < offset + 8 + 1 + 8 + 2) {
    logMessage(
      "Error",
      "⚠ PAYLOAD CORRUPTION - S_RoomPresenceUpdate too short",
    );
    return;
  }

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;
  const eventType = dataView.getUint8(offset);
  offset += 1;
  const sequence = dataView.getBigUint64(offset, false);
  offset += 8;

  // Parse username (length-prefixed)
  const usernameLength = dataView.getUint16(offset, false);
  offset += 2;
  if (dataView.byteLength < offset + usernameLength + 1 + 1 + 2) {
    logMessage("Error", "⚠ PAYLOAD CORRUPTION - Username length mismatch");
    return;
  }

  let username = "";
  if (usernameLength > 0) {
    const usernameBytes = new Uint8Array(
      dataView.buffer,
      offset,
      usernameLength,
    );
    username = new TextDecoder("utf-8").decode(usernameBytes);
    offset += usernameLength;
  }

  // Parse is_authenticated flag for username
  const isAuthenticated = dataView.getUint8(offset) !== 0;
  offset += 1;

  // Parse user_type for username (skip for now)
  const userType = dataView.getUint8(offset);
  offset += 1;

  // Parse old_username (length-prefixed) - for UserRenamed events
  const oldUsernameLength = dataView.getUint16(offset, false);
  offset += 2;
  if (dataView.byteLength < offset + oldUsernameLength + 2) {
    logMessage("Error", "⚠ PAYLOAD CORRUPTION - Old username length mismatch");
    return;
  }

  let oldUsername = "";
  if (oldUsernameLength > 0) {
    const oldUsernameBytes = new Uint8Array(
      dataView.buffer,
      offset,
      oldUsernameLength,
    );
    oldUsername = new TextDecoder("utf-8").decode(oldUsernameBytes);
    offset += oldUsernameLength;
  }

  // Parse user list count
  const userListCount = dataView.getUint16(offset, false);
  offset += 2;

  // Parse user list with auth flags (for sync events)
  const userList = [];
  for (let i = 0; i < userListCount; i++) {
    if (dataView.byteLength < offset + 2) {
      logMessage(
        "Error",
        "⚠ PAYLOAD CORRUPTION - User list entry length missing",
      );
      return;
    }

    const userLength = dataView.getUint16(offset, false);
    offset += 2;
    if (dataView.byteLength < offset + userLength + 1 + 1) {
      logMessage(
        "Error",
        "⚠ PAYLOAD CORRUPTION - User list entry content missing",
      );
      return;
    }

    const userBytes = new Uint8Array(dataView.buffer, offset, userLength);
    const user = new TextDecoder("utf-8").decode(userBytes);
    offset += userLength;

    // Parse auth flag for this user
    const userIsAuthenticated = dataView.getUint8(offset) !== 0;
    offset += 1;

    // Parse user_type for this user
    const userUserType = dataView.getUint8(offset);
    offset += 1;

    userList.push({ username: user, isAuthenticated: userIsAuthenticated, userType: userUserType });
  }

  // Update room presence state
  updateRoomPresence(
    convId,
    eventType,
    Number(sequence),
    username,
    isAuthenticated,
    userType,
    oldUsername,
    userList,
  );
}

function updateRoomPresence(
  convId,
  eventType,
  sequence,
  username,
  isAuthenticated,
  userType,
  oldUsername,
  userList,
) {
  // Check sequence number to handle out-of-order messages
  const currentSequence = roomPresenceSequences.get(convId) || 0;

  // UserListSync is always authoritative - accept regardless of sequence order
  if (eventType === 2) {
    // UserListSync
    roomPresenceSequences.set(convId, sequence);
  } else {
    // For UserJoined/UserLeft/UserRenamed, only accept if sequence is newer
    if (sequence <= currentSequence) {
      // Ignore older incremental updates
      return;
    }
    roomPresenceSequences.set(convId, sequence);
  }

  // Ensure room presence map exists (username -> {isAuthenticated, userType})
  if (!roomPresence.has(convId)) {
    roomPresence.set(convId, new Map());
  }

  const presenceMap = roomPresence.get(convId);

  // Event types: 0=UserJoined, 1=UserLeft, 2=UserListSync, 3=UserRenamed
  switch (eventType) {
    case 0: // UserJoined
      if (username) {
        presenceMap.set(username, { isAuthenticated, userType });
        if (convId === currentRoomId) {
          logSystem(`${username} JOINED ${getRoomName(convId)}`, "presence");
        }
      }
      break;

    case 1: // UserLeft
      if (username) {
        presenceMap.delete(username);
        if (convId === currentRoomId) {
          logSystem(`${username} LEFT ${getRoomName(convId)}`, "presence");
        }
      }
      break;

    case 2: // UserListSync
      presenceMap.clear();
      for (const user of userList) {
        presenceMap.set(user.username, {
          isAuthenticated: user.isAuthenticated,
          userType: user.userType,
        });
      }
      if (convId === currentRoomId) {
        const usernames = Array.from(presenceMap.keys());
        logSystem(`ROOM USERS IN ${getRoomName(convId)}: ${usernames.join(", ")}`, "presence", "DEBUG");
      }
      break;

    case 3: // UserRenamed
      if (oldUsername && username) {
        const oldUserInfo = presenceMap.get(oldUsername);
        presenceMap.delete(oldUsername);
        presenceMap.set(username, { isAuthenticated, userType });
        if (convId === currentRoomId) {
          logSystem(`${oldUsername} RENAMED TO ${username}`, "presence");
        }
      }
      break;
  }

  // Update UI if this is the current room
  if (convId === currentRoomId) {
    updatePresenceDisplay();
  }
}

function updatePresenceDisplay() {
  const currentUsers = roomPresence.get(currentRoomId) || new Map();
  const userCount = currentUsers.size;

  // Update presence list if it exists
  // Convert Map entries to array of {username, isAuthenticated, userType}
  const userEntries = Array.from(currentUsers.entries()).map(
    ([username, info]) => ({
      username,
      isAuthenticated: info.isAuthenticated,
      userType: info.userType ?? UserType.User,
    }),
  );
  updateUsersList(userEntries);
  window.NRCInspector?.refreshContext();
}

function updateUsersList(users) {
  const usersList = document.getElementById("usersList");

  if (!usersList) return;

  if (users.length === 0) {
    usersList.innerHTML = '<div class="no-users">No users</div>';
    return;
  }

  // Separate into bots and regular users
  const bots = users.filter(
    (u) =>
      u.userType === UserType.Bot ||
      u.userType === UserType.System ||
      u.userType === UserType.Admin,
  );
  const regularUsers = users.filter(
    (u) =>
      u.userType !== UserType.Bot &&
      u.userType !== UserType.System &&
      u.userType !== UserType.Admin,
  );

  // Sort alphabetically
  bots.sort((a, b) => a.username.localeCompare(b.username));
  regularUsers.sort((a, b) => a.username.localeCompare(b.username));

  const renderUser = (user) => {
    const isBot = user.userType === UserType.Bot || user.userType === UserType.System || user.userType === UserType.Admin;
    let displayName = user.username;
    if (isBot && user.isAuthenticated && displayName.includes("-")) {
      displayName = displayName.split("-")[0];
    }
    return `<div class="user-item" data-username="${escapeHtml(user.username)}" title="Click to start DM">
                    <span class="username">${escapeHtml(displayName)}</span>
                </div>`;
  };

  const renderSection = (label, count, items) => {
    const labelHtml = `<span class="users-section-label">${label} <span class="users-section-count">${count}</span></span>`;
    const itemsHtml = items.map(renderUser).join("");
    return `<div class="users-section">${labelHtml}${itemsHtml}</div>`;
  };

  usersList.innerHTML =
    renderSection("USERS", regularUsers.length, regularUsers) +
    renderSection("BOTS", bots.length, bots);

  // Add click handlers for starting DMs
  usersList.querySelectorAll(".user-item[data-username]").forEach((el) => {
    el.style.cursor = "pointer";
    el.onclick = () => {
      const username = el.dataset.username;
      if (username) {
        sendStartDM(username);
      }
    };
  });
}

function escapeHtml(unsafe) {
  return unsafe
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function updateChatStats() {
  const logOutput = document.getElementById("logOutput");
  const countEl = document.getElementById("chatMsgCount");
  const timeEl = document.getElementById("chatLastTime");

  if (!logOutput || !countEl || !timeEl) return;

  if (systemLogVisible) {
    const entries = getFilteredSystemLogEntries();
    const totalEntries = systemLogHistory.length;
    countEl.textContent = entries.length === totalEntries ? entries.length : `${entries.length}/${totalEntries}`;
    const lastEntry = entries[entries.length - 1];
    timeEl.textContent = lastEntry ? formatSystemLogTime(lastEntry.timestamp).slice(0, 8) : "--:--:--";
    return;
  }

  const rows = logOutput.querySelectorAll(".log-row");
  const visibleRoomId = window.NRCAI?.isSullivanView?.() ? window.NRCAI.getDisplayConvId?.() : currentRoomId;
  const visibleContextId = window.NRCAI?.isSullivanView?.() ? window.NRCAI.getContextConvId?.() : null;
  const totalHistory = (roomHistory.get(visibleRoomId) || []).filter(
    (message) => visibleContextId == null || String(message.aiContextRoomId) === String(visibleContextId),
  ).length;
  const domCount = rows.length;
  countEl.textContent = totalHistory > domCount ? `${domCount}/${totalHistory}` : domCount;

  if (rows.length > 0) {
    const lastRow = rows[rows.length - 1];
    const timeCol = lastRow.querySelector(".col-time");
    if (timeCol) {
      timeEl.textContent = (timeCol.dataset.fullTime || timeCol.textContent).substring(0, 8);
    }
  } else {
    timeEl.textContent = "--:--:--";
  }
}

function parseNewMessage(dataView) {
  // S_NewMessage Payload: { conv_id: u64, seq: u64, author_id: u64, timestamp: i64, content_type: u8, content_len: u16, content: []byte }
  let offset = 2; // Skip opcode

  if (dataView.byteLength < offset + 8 + 8 + 8 + 8 + 1 + 2) {
    logMessage("Error", "PAYLOAD CORRUPTION - S_NewMessage too short");
    return;
  }

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;
  const seq = dataView.getBigUint64(offset, false);
  offset += 8;

  // Parse username (length-prefixed)
  const usernameLength = dataView.getUint16(offset, false);
  offset += 2;
  if (dataView.byteLength < offset + usernameLength) {
    logMessage("Error", "PAYLOAD CORRUPTION - Username length mismatch");
    return;
  }
  const usernameBytes = new Uint8Array(dataView.buffer, offset, usernameLength);
  const authorUsername = new TextDecoder("utf-8").decode(usernameBytes);
  offset += usernameLength;

  const timestamp = dataView.getBigInt64(offset, false);
  offset += 8;
  const contentType = dataView.getUint8(offset);
  offset += 1;
  const contentLength = dataView.getUint16(offset, false);
  offset += 2; // Protocol uses u16

  if (dataView.byteLength < offset + contentLength) {
    logMessage("Error", "PAYLOAD CORRUPTION - Content length mismatch");
    return;
  }

  const contentBytes = new Uint8Array(dataView.buffer, offset, contentLength);
  const content = new TextDecoder("utf-8").decode(contentBytes);

  const date = new Date(Number(timestamp / 1000000n));
  const isOwnMessage = myNickname && authorUsername === myNickname;
  const normalizedAuthorName = isDMConversation(convId)
    ? formatDMDisplayName(authorUsername)
    : authorUsername;
  const authorName = isOwnMessage ? "YOU" : normalizedAuthorName;
  const timeStr = date.toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });

  // Check if this is an image chunk message
  try {
    const messageData = JSON.parse(content);
    if (
      messageData.type === "image_chunk" ||
      messageData.type === "image_complete"
    ) {
      handleImageChunk(content, authorUsername, convId);

      // Count one logical image when its completion marker arrives off-screen.
      if (messageData.type === "image_complete" && !isOwnMessage && String(convId) !== String(getVisibleConversationId())) {
        markConversationUnread(convId);
        updateRoomUI();
      }
      return;
    }
  } catch (e) {
    // Not JSON, treat as regular text message
  }

  let aiContextRoomId = null;
  if (isAIDMConversation(convId)) {
    const isProgress = !!normalizeAiRunStep({ type: "Message", message: content, author: authorName });
    if (isProgress) return; // Plain-text progress has no run ID and cannot be safely correlated.
    aiContextRoomId = window.NRCAI?.getContextForDisplay?.(convId);
  }

  // Store message in the correct room's history
  logMessage("Message", content, convId, {
    author: authorName,
    timestamp: date.getTime(),
    aiContextRoomId,
    sequence: seq,
  });

  // Track messages received while their chat conversation is not visible.
  if (!isOwnMessage && String(convId) !== String(getVisibleConversationId())) {
    markConversationUnread(convId);
    updateRoomUI();
  }
}

function drainRetainedOperationQueue() {
  while (
    retainedOperations.size < MAX_RETAINED_OPERATIONS_IN_FLIGHT &&
    retainedOperationQueue.length > 0 &&
    ws?.readyState === WebSocket.OPEN
  ) {
    const operation = retainedOperationQueue.shift();
    retainedOperations.set(operation.correlationId, operation.kind);
    operation.onSend?.();
    sendPacket(operation.buffer);
  }
}

function queueRetainedOperation(correlationId, kind, buffer, onSend = null) {
  retainedOperationQueue.push({ correlationId, kind, buffer, onSend });
  drainRetainedOperationQueue();
}

function completeRetainedOperation(correlationId) {
  if (retainedOperations.delete(correlationId)) drainRetainedOperationQueue();
}

function requestRetainedHistory(convId, cursor = 0n, loaded = 0, options = {}) {
  const correlationId = (clientRequestIdCounter = (clientRequestIdCounter + 1) >>> 0);
  const buffer = window.NRCRetainedMessages.encodeRangeRequest(
    Opcode.C_ListMessagesBefore,
    convId,
    cursor,
    window.NRCRetainedMessages.MAX_PAGE_MESSAGES,
    correlationId,
  );
  retainedHistoryRequests.set(correlationId, {
    convId, loaded, buffer, attempts: 0,
    // A jump wants exactly one page around a known sequence, and it wants to be
    // told when that page is in — backfill chaining would fetch up to a thousand
    // messages and the caller would have to poll for the row.
    single: options.single === true,
    onPage: typeof options.onPage === "function" ? options.onPage : null,
  });
  queueRetainedOperation(correlationId, "history", buffer);
}

function requeuePendingRetainedMessages(convId) {
  for (const [correlationId, pending] of pendingMessages.entries()) {
    if (!pending.retained || pending.convId !== convId) continue;
    const alreadyQueued = retainedOperationQueue.some(
      (operation) => operation.correlationId === correlationId,
    );
    if (alreadyQueued || retainedOperations.has(correlationId)) continue;
    queueRetainedOperation(correlationId, "send", pending.buffer, () => {
      pending.timestamp = Date.now();
    });
  }
}

function parseRetainedSubscriptionReady(dataView) {
  const ready = window.NRCRetainedMessages.parseSubscriptionReady(dataView);
  const requestedRooms = retainedSubscriptionRequests.get(ready.correlationId) || [];
  retainedSubscriptionRequests.delete(ready.correlationId);
  const enabledRooms = new Set(ready.entries.map((entry) => entry.convId));

  for (const convId of requestedRooms) {
    const enabled = enabledRooms.has(convId);
    retainedRoomStates.set(convId, enabled ? "enabled" : "disabled");
    if (!enabled) {
      let dropped = 0;
      for (const [correlationId, pending] of pendingMessages.entries()) {
        if (pending.retained && pending.convId === convId) {
          pendingMessages.delete(correlationId);
          dropped++;
        }
      }
      if (dropped > 0) logMessage("Error", "UNCONFIRMED RETAINED MESSAGE WAS NOT RESENT", convId);
    }
  }
  for (const entry of ready.entries) {
    requeuePendingRetainedMessages(entry.convId);
    if (!retainedHistoryStarted.has(entry.convId)) {
      retainedHistoryStarted.add(entry.convId);
      requestRetainedHistory(entry.convId);
    }
  }
}

function ingestRetainedMessage(record, suppressNotification) {
  const clientMessageId = window.NRCRetainedMessages.clientMessageIdKey(record.clientMessageId);
  const isOwnMessage = myNickname && record.authorUsername === myNickname;
  const authorName = isOwnMessage ? "YOU" : record.authorUsername;
  const timestamp = Number(record.timestamp / 1000000n);

  try {
    const messageData = JSON.parse(record.content);
    if (messageData.type === "image_chunk" || messageData.type === "image_complete") {
      handleImageChunk(record.content, record.authorUsername, record.convId, {
        timestamp,
        sequence: record.seq,
        retained: true,
      });
      return;
    }
  } catch (error) {
    // Plain text is the common path.
  }

  logMessage(isOwnMessage ? "Sent" : "Message", record.content, record.convId, {
    author: authorName,
    timestamp,
    sequence: record.seq,
    clientMessageId,
    retained: true,
    suppressNotification,
  });

  if (!suppressNotification && !isOwnMessage && String(record.convId) !== String(getVisibleConversationId())) {
    markConversationUnread(record.convId);
    updateRoomUI();
  }
}

function parseRetainedMessagePage(dataView) {
  const page = window.NRCRetainedMessages.parseMessagePage(dataView);
  const request = retainedHistoryRequests.get(page.correlationId);
  if (request) {
    retainedHistoryRequests.delete(page.correlationId);
    completeRetainedOperation(page.correlationId);
  }

  for (const record of page.messages) {
    if (record.convId !== page.convId) throw new Error("S_MessagePage conversation mismatch");
    ingestRetainedMessage(record, !!request);
  }

  if (request) {
    const loaded = request.loaded + page.messages.length;
    if (isConversationVisible(page.convId)) loadRoomHistory(page.convId);
    request.onPage?.(page);
    if (!request.single && page.hasMore && loaded < 1000 && page.continuationCursor > 0n) {
      requestRetainedHistory(page.convId, page.continuationCursor, loaded);
    }
  }
}

// =============================================================================
// WEBSOCKET MESSAGE SENDING
// =============================================================================

function sendRawProtocolMessage(content) {
  const textEncoder = new TextEncoder();
  const contentBytes = textEncoder.encode(content);
  if (contentBytes.byteLength > MAX_MESSAGE_CONTENT_BYTES) {
    logMessage("Error", `MESSAGE EXCEEDS ${MAX_MESSAGE_CONTENT_BYTES.toLocaleString()} BYTE LIMIT`);
    return false;
  }
  const clientReqId = clientRequestIdCounter++;

  const retainedState = retainedRoomStates.get(currentRoomId);
  if (
    !isDMConversation(currentRoomId) &&
    retainedState !== "enabled" &&
    retainedState !== "disabled"
  ) {
    logMessage("Error", "MESSAGE HISTORY IS INITIALIZING; PLEASE RETRY");
    return false;
  }

  if (!isDMConversation(currentRoomId) && retainedState === "enabled") {
    const clientMessageIdBytes = window.NRCRetainedMessages.createClientMessageId();
    const clientMessageId = window.NRCRetainedMessages.clientMessageIdKey(clientMessageIdBytes);
    const buffer = window.NRCRetainedMessages.encodeSendMessage(
      Opcode.C_SendMessageV2,
      currentRoomId,
      clientMessageIdBytes,
      clientReqId,
      ContentType.PlainText,
      contentBytes,
    );
    pendingMessages.set(clientReqId, {
      buffer,
      timestamp: Number.POSITIVE_INFINITY,
      attempts: 0,
      retained: true,
      convId: currentRoomId,
      clientMessageId,
      messageData: null,
    });
    queueRetainedOperation(clientReqId, "send", buffer, () => {
      const pending = pendingMessages.get(clientReqId);
      if (pending) pending.timestamp = Date.now();
    });
    return { clientReqId, clientMessageId, retained: true };
  }

  // Calculate buffer size: Opcode(2) + ConvID(8) + ClientReqID(4) + ContentType(1) + ContentLength(2) + ContentBytes
  const payloadSize = 8 + 4 + 1 + 2 + contentBytes.byteLength;
  const bufferSize = 2 + payloadSize;
  const buffer = new ArrayBuffer(bufferSize);
  const dataView = new DataView(buffer);

  let offset = 0;

  // Write Opcode (u16, Big Endian)
  dataView.setUint16(offset, Opcode.C_SendMessage, false);
  offset += 2;
  // Write ConversationID (u64, Big Endian)
  dataView.setBigUint64(offset, currentRoomId, false);
  offset += 8;
  // Write ClientReqID (u32, Big Endian)
  dataView.setUint32(offset, clientReqId, false);
  offset += 4;
  // Write ContentType (u8)
  dataView.setUint8(offset, ContentType.PlainText);
  offset += 1;
  // Write Content Length (u16, Big Endian)
  dataView.setUint16(offset, contentBytes.byteLength, false);
  offset += 2;
  // Write Content Bytes
  new Uint8Array(buffer, offset).set(contentBytes);

  // Send the ArrayBuffer
  sendPacket(buffer);
  return { clientReqId, clientMessageId: null, retained: false };
}

function sendBinaryMessage(text) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    const displayConvId = window.NRCAI?.isSullivanView?.() ? window.NRCAI.getDisplayConvId?.() : null;
    logMessage("Error", "WebSocket is not connected.", displayConvId, {
      aiContextRoomId: displayConvId == null ? null : window.NRCAI.getContextConvId?.(),
    });
    return;
  }
  if (!text.trim()) {
    return; // Don't send empty messages
  }
  if (new TextEncoder().encode(text).byteLength > MAX_MESSAGE_CONTENT_BYTES) {
    logMessage("Error", `MESSAGE EXCEEDS ${MAX_MESSAGE_CONTENT_BYTES.toLocaleString()} BYTE LIMIT`);
    return;
  }

  // Block sending until server identity handshake completes.
  if (!nicknameReceived) {
    const displayConvId = window.NRCAI?.isSullivanView?.() ? window.NRCAI.getDisplayConvId?.() : null;
    logMessage("Error", "Still waiting for server identity, please wait...", displayConvId, {
      aiContextRoomId: displayConvId == null ? null : window.NRCAI.getContextConvId?.(),
    });
    clearMessageInput();
    return;
  }

  // In AI DMs, plain text becomes /ask follow-up.
  if (window.NRCAI?.isSullivanView?.()) {
    if (!window.NRCAI?.handleAsk) {
      logMessage("Error", "AI MODULE NOT LOADED");
      clearMessageInput();
      return;
    }
    if (window.NRCAI.isWorkbenchBusy?.()) {
      logMessage("Error", "SULLIVAN IS BUSY; STOP OR WAIT FOR THE ACTIVE RUN");
      return;
    }
    if (window.NRCAI.handleAIDMText) {
      window.NRCAI.handleAIDMText(text);
    } else {
      window.NRCAI.handleAsk(text);
    }
    clearMessageInput();
    return;
  }

  // Send the message using shared protocol helper
  const sendResult = sendRawProtocolMessage(text);
  if (!sendResult) return;
  window.NRCChat.sent();

  // UI feedback and cleanup
  const now = new Date();
  const timeStr = now.toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  logMessage("Sent", text, null, {
    author: "YOU",
    timestamp: Date.now(),
    clientMessageId: sendResult.clientMessageId,
    retained: sendResult.retained,
  });
  const pending = pendingMessages.get(sendResult.clientReqId);
  if (pending) {
    pending.messageData = (roomHistory.get(currentRoomId) || []).find(
      (message) => message.clientMessageId === sendResult.clientMessageId,
    ) || null;
  }

  clearMessageInput();
}

// =============================================================================
// CHAT ATTACHMENTS (legacy image chunks remain readable below)
// =============================================================================

async function sendChatAttachment(file) {
  if (window.NRCAI?.isSullivanView?.()) {
    logMessage("Error", "FILE ATTACHMENTS ARE AVAILABLE IN CHAT, NOT SULLIVAN");
    return;
  }
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    logMessage("Error", "WebSocket is not connected.");
    return;
  }

  if (!nicknameReceived) {
    logMessage("Error", "Still waiting for server identity, please wait...");
    return;
  }

  const retainedState = retainedRoomStates.get(currentRoomId);
  if (!isDMConversation(currentRoomId) && retainedState !== "enabled" && retainedState !== "disabled") {
    logMessage("Error", "MESSAGE HISTORY IS INITIALIZING; PLEASE RETRY");
    return;
  }

  const roomId = currentRoomId;
  const socket = ws;
  logMessage("System", `UPLOADING ${file.name}`, roomId);
  try {
    const attachment = await uploadFile(file, null, String(roomId));
    // Never redirect a completed upload into a different conversation/session.
    if (currentRoomId !== roomId || ws !== socket || ws.readyState !== WebSocket.OPEN || !nicknameReceived || window.NRCAI?.isSullivanView?.()) {
      throw new Error("Conversation or connection changed; select the file again to send");
    }
    const content = encodeChatAttachment(attachment);
    const result = sendRawProtocolMessage(content);
    if (!result) return;
    logMessage("Sent", content, roomId, {
      author: "YOU",
      timestamp: Date.now(),
      clientMessageId: result.clientMessageId,
      retained: result.retained,
    });
    const pending = pendingMessages.get(result.clientReqId);
    if (pending) {
      pending.messageData = (roomHistory.get(roomId) || []).find(
        (message) => message.clientMessageId === result.clientMessageId,
      ) || null;
    }
  } catch (error) {
    logMessage("Error", `ATTACHMENT FAILED: ${error.message}`, roomId);
  }
}

function chatAttachmentMarkdown(attachment) {
  const label = attachment.filename.replace(/[\\`*_{}\[\]<>()!#&]/g, (char) => `&#${char.charCodeAt(0)};`).replace(/[\r\n]/g, " ");
  const image = attachment.mimeType.startsWith("image/");
  const url = attachmentFileURL(attachment.fileId, attachment.filename, image);
  return `${image ? "!" : ""}[${label}](${url})`;
}

function handleImageChunk(message, authorUsername = null, roomId = null, metadata = {}) {
  const data = JSON.parse(message);

  if (data.type === "image_chunk") {
    const {
      imageId,
      chunkIndex,
      totalChunks,
      data: chunkData,
      mimeType,
      filename,
    } = data;

    if (!imageChunks.has(imageId)) {
      imageChunks.set(imageId, {
        chunks: new Array(totalChunks),
        totalChunks: totalChunks,
        mimeType: mimeType,
        filename: filename,
        receivedChunks: 0,
        authorUsername: authorUsername,
        roomId: roomId || currentRoomId, // Store room ID
        timestamp: metadata.timestamp || Date.now(),
        sequence: metadata.sequence ?? null,
        retained: metadata.retained === true,
      });
    }

    const imageData = imageChunks.get(imageId);
    if (chunkIndex === totalChunks - 1) {
      imageData.timestamp = metadata.timestamp || imageData.timestamp;
      imageData.sequence = metadata.sequence ?? imageData.sequence;
      imageData.retained = metadata.retained === true;
    }
    if (!imageData.chunks[chunkIndex]) {
      imageData.chunks[chunkIndex] = chunkData;
      imageData.receivedChunks++;

      // Check if we have all chunks
      if (imageData.receivedChunks === imageData.totalChunks) {
        reconstructImage(imageId);
      }
    }
  } else if (data.type === "image_complete") {
    // This is just a marker, actual reconstruction happens when all chunks are received
    const { imageId } = data;
    if (imageChunks.has(imageId)) {
      reconstructImage(imageId);
    }
  }
}

function reconstructImage(imageId) {
  const imageData = imageChunks.get(imageId);
  if (!imageData || imageData.receivedChunks !== imageData.totalChunks) {
    return;
  }

  // Reconstruct base64 data
  const fullBase64 = imageData.chunks.join("");
  const dataUrl = `data:${imageData.mimeType};base64,${fullBase64}`;

  // Display received image (from other users)
  displayReceivedImageMessage(
    imageData.filename,
    dataUrl,
    imageData.mimeType,
    imageData.authorUsername,
    imageData.roomId,
    {
      timestamp: imageData.timestamp,
      sequence: imageData.sequence,
      clientMessageId: `image:${imageId}`,
      retained: imageData.retained,
    },
  );

  // Clean up
  imageChunks.delete(imageId);
}

function displayReceivedImageMessage(
  filename,
  dataUrl,
  mimeType,
  authorUsername,
  roomId,
  metadata = {},
) {
  const messageData = {
    type: "Image",
    message: filename,
    timestamp: metadata.timestamp || Date.now(),
    roomId: roomId || currentRoomId,
    imageData: {
      dataUrl: dataUrl,
      filename: filename,
      mimeType: mimeType,
    },
    author: authorUsername,
    sequence: metadata.sequence ?? null,
    clientMessageId: metadata.clientMessageId || null,
    retained: metadata.retained === true,
  };

  // Store in room history using shared helper
  const added = storeMessageInRoom(messageData, messageData.roomId);

  // Use the same view/context boundary as ordinary incoming messages.
  if (added && isConversationVisible(messageData.roomId, messageData)) {
    displayMessage(messageData);
  }

  // Update message counts
}

function subscribeToConversations(convIds) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    logMessage("Error", "WebSocket is not connected.");
    return;
  }

  const roomIds = convIds.filter((convId) =>
    convId !== 0n && !isDMConversation(convId) && retainedRoomStates.get(convId) !== "disabled",
  );
  const legacyIds = convIds.filter((convId) =>
    convId === 0n || isDMConversation(convId) || retainedRoomStates.get(convId) === "disabled",
  );

  for (let start = 0; start < roomIds.length; start += 64) {
    const batch = roomIds.slice(start, start + 64);
    batch.forEach((convId) => {
      if (!retainedRoomStates.has(convId)) retainedRoomStates.set(convId, "unknown");
    });
    const correlationId = (clientRequestIdCounter = (clientRequestIdCounter + 1) >>> 0);
    retainedSubscriptionRequests.set(correlationId, batch);
    sendPacket(window.NRCRetainedMessages.encodeSubscribe(
      Opcode.C_SubscribeConvsV2,
      batch,
      correlationId,
    ));
  }

  for (let start = 0; start < legacyIds.length; start += 64) {
    const batch = legacyIds.slice(start, start + 64);
    const buffer = new ArrayBuffer(4 + batch.length * 8);
    const dataView = new DataView(buffer);
    dataView.setUint16(0, Opcode.C_SubscribeConvs, false);
    dataView.setUint16(2, batch.length, false);
    batch.forEach((convId, index) => dataView.setBigUint64(4 + index * 8, convId, false));
    sendPacket(buffer);
  }

  const roomNames = convIds.map(id => getRoomName(id)).join(", ");
  logSystem(`SUBSCRIBED TO ${roomNames}`, "websocket", "DEBUG");
}

function unsubscribeFromConversations(convIds) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    logMessage("Error", "WebSocket is not connected.");
    return;
  }

  const correlationId = (clientRequestIdCounter = (clientRequestIdCounter + 1) >>> 0);
  // Opcode(2) + Count(2) + ConvIDs(8 * count) + CorrelationID(4)
  const bufferSize = 2 + 2 + convIds.length * 8 + 4;
  const buffer = new ArrayBuffer(bufferSize);
  const dataView = new DataView(buffer);

  let offset = 0;

  // Write Opcode (u16, Big Endian)
  dataView.setUint16(offset, Opcode.C_UnsubscribeConvs, false);
  offset += 2;
  // Write Count (u16, Big Endian)
  dataView.setUint16(offset, convIds.length, false);
  offset += 2;
  // Write Conversation IDs (u64 each, Big Endian)
  for (const convId of convIds) {
    dataView.setBigUint64(offset, convId, false);
    offset += 8;
  }
  dataView.setUint32(offset, correlationId, false);

  // Send the ArrayBuffer
  sendPacket(buffer);
  const roomNames = convIds.map(id => getRoomName(id)).join(", ");
  logSystem(`UNSUBSCRIBED FROM ${roomNames}`, "websocket", "DEBUG");
}

function parseAckUnsubscribeConvs(dataView) {
  if (dataView.byteLength !== 6) {
    console.error(`S_AckUnsubscribeConvs invalid length: ${dataView.byteLength}`);
    return;
  }
  const correlationId = dataView.getUint32(2, false);
  console.log(`[S_AckUnsubscribeConvs] completed correlation=${correlationId}`);
}

function refreshRoomParticipants() {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    logMessage("Error", "⚠ NOT CONNECTED TO SERVER");
    return;
  }

  if (!serverReady) {
    logMessage("Error", "⚠ SERVER NOT READY");
    return;
  }

  // Re-subscribe to current room to trigger fresh presence update
  logMessage(
    "System",
    `>> REFRESHING PARTICIPANTS FOR ${getRoomName(currentRoomId)}...`,
  );
  subscribeToConversations([currentRoomId]);

  // Also show current known participants immediately
  const participants = roomPresence.get(currentRoomId);
  if (participants && participants.size > 0) {
    const participantList = Array.from(participants).join(", ");
    logMessage(
      "System",
      `CURRENT PARTICIPANTS IN ${getRoomName(currentRoomId)}: ${participantList}`,
    );
  } else {
    logMessage(
      "System",
      `NO PARTICIPANTS CURRENTLY KNOWN IN ${getRoomName(currentRoomId)}`,
    );
  }
}

// =============================================================================
// ROOM MANAGEMENT
// =============================================================================

function normalizeRoomName(name) {
  const normalized = String(name || "").trim().replace(/^#/, "").toUpperCase();
  if (!/^[A-Z0-9_-]{1,32}$/.test(normalized)) {
    return null;
  }
  return normalized;
}

function registerRoomMapping(normalizedName, convId, displayName = normalizedName, assetId = null) {
  const roomId = BigInt(convId);
  roomMappingsByName.set(normalizedName, {
    convId: roomId,
    displayName,
    assetId,
  });
  roomNames.set(roomId, displayName);
  updateAutocompleteRoomData();
}

function handleRoomMappingAsset(asset) {
  if (!window.NRCAssets || asset.assetType !== window.NRCAssets.AssetType.RoomMapping) return;
  if (asset.convId !== 0n || !asset.payload) return;

  try {
    const mapping = JSON.parse(asset.payload);
    const normalizedName = normalizeRoomName(mapping.normalized_name || mapping.name || asset.preview);
    if (!normalizedName || !mapping.conv_id) return;

    registerRoomMapping(
      normalizedName,
      BigInt(mapping.conv_id),
      normalizeRoomName(mapping.display_name || normalizedName) || normalizedName,
      asset.assetId,
    );
    window.NRCNotes?.refreshSharedNoteView?.();
  } catch (error) {
    console.warn("Failed to parse room mapping asset", error);
  }
}

function handleRoomMappingDeleted(asset) {
  const normalizedName = normalizeRoomName(asset.preview);
  if (!normalizedName) return;

  const mapping = roomMappingsByName.get(normalizedName);
  if (!mapping || (asset.assetId != null && mapping.assetId !== asset.assetId)) return;

  roomMappingsByName.delete(normalizedName);
  roomNames.delete(mapping.convId);
  updateAutocompleteRoomData();
  window.NRCNotes?.refreshSharedNoteView?.();
}

function resolveKnownRoomName(roomName) {
  const normalizedName = normalizeRoomName(roomName);
  if (!normalizedName) return null;

  for (let [id, name] of roomNames.entries()) {
    if (name === normalizedName) {
      return { convId: id, displayName: name, normalizedName };
    }
  }

  const mapping = roomMappingsByName.get(normalizedName);
  if (mapping) {
    return { convId: mapping.convId, displayName: mapping.displayName, normalizedName };
  }

  return null;
}

function createRoomMapping(roomName) {
  return new Promise((resolve, reject) => {
    const normalizedName = normalizeRoomName(roomName);
    if (!normalizedName) {
      reject(new Error("Invalid room name (use A-Z, 0-9, _, -; max 32 characters)"));
      return;
    }

    if (normalizedName === "SYSTEM") {
      reject(new Error("SYSTEM is reserved for the operator log"));
      return;
    }

    const existing = resolveKnownRoomName(normalizedName);
    if (existing) {
      resolve(existing);
      return;
    }

    if (!window.NRCAssets?.sendCreateAsset) {
      reject(new Error("Asset system not ready"));
      return;
    }

    const payload = JSON.stringify({ version: 1, normalized_name: normalizedName });
    const correlationId = window.NRCAssets.sendCreateAsset(
      0n,
      window.NRCAssets.AssetType.RoomMapping,
      window.NRCAssets.ParentType.None,
      0n,
      normalizedName,
      payload,
      0,
      {
        onSuccess: ({ asset }) => {
          handleRoomMappingAsset(asset);
          const resolved = resolveKnownRoomName(normalizedName);
          if (resolved) {
            resolve(resolved);
          } else {
            reject(new Error("Server returned an invalid room mapping"));
          }
        },
        onError: (error) => {
          reject(new Error(error?.error || "Failed to create room mapping"));
        },
      },
    );

    if (!correlationId) {
      reject(new Error("Server is not ready"));
    }
  });
}

function getRoomName(roomId) {
  if (roomId === 0n) return "WORKSPACE";
  // Handle DM conversations
  if (isDMConversation(roomId)) {
    const dm = activeDMs.get(roomId);
    if (dm && isAIDMConversation(roomId)) {
      return formatDMDisplayName(dm.username, dm.authenticated).toUpperCase();
    }
    return dm
      ? `DM: ${formatDMDisplayName(dm.username, dm.authenticated).toUpperCase()}`
      : "DM";
  }
  return roomNames.get(roomId) || `ROOM-${roomId}`;
}

function getRoomColorIndex(roomId) {
  const count = BigInt(ROOM_COLOR_COUNT);
  const offset = BigInt(roomId) - DEFAULT_ROOM_ID;
  return Number((offset % count + count) % count);
}

// Explicit chat navigation; internal room changes can still preserve data views.
function openChatRoom(roomId) {
  if (roomId === 0n) return;
  switchToRoom(roomId);
  if (currentRoomId === roomId) window.NRCViewManager.setActiveView("chat");
}

function switchToRoom(roomId) {
  if (roomId === 0n) return; // Workspace data is not a chat destination.
  if (roomId === SYSTEM_ROOM_ID) {
    showSystemLog();
    return;
  }

  if (window.NRCAI?.isWorkbenchBusy?.()) {
    logMessage("Error", "SULLIVAN RUN IS PINNED TO ITS CURRENT CONTEXT; STOP OR WAIT BEFORE CHANGING ROOMS",
      window.NRCAI.getDisplayConvId?.(), { aiContextRoomId: window.NRCAI.getContextConvId?.() });
    return;
  }

  if (roomId === currentRoomId) {
    return; // Already in this room
  }

  // Clear DM unread count if switching to a DM
  if (isDMConversation(roomId)) {
    clearDMUnread(roomId);
  }

  const roomName = getRoomName(roomId);
  currentRoomId = roomId;
  // Restoring Chat clears its unread count, so select the destination first.
  if (systemLogVisible) {
    exitSystemLog();
  }
  window.NRCChat.syncComposer();
  logSystem(`SWITCHED TO ${roomName}`, "room");

  // Subscribe to room if not already subscribed
  if (!subscribedRooms.has(roomId)) {
    subscribedRooms.add(roomId);
    subscribeToConversations([roomId]);
  }

  if (window.NRCViewManager?.getActiveView?.() === "chat") {
    clearConversationUnread(roomId);
  } else {
    updateChatUnreadCount();
  }

  if (window.NRCAI?.isSullivanView?.()) {
    window.NRCAI.onSelectedRoomChanged?.(roomId);
  } else {
    loadRoomHistory(roomId);
  }

  updateRoomUI();
  updateDMListUI();
  updatePresenceDisplay();
  startPresenceReconciliation();

  // Save UI state to localStorage
  saveUIState();
}

async function joinRoom(roomIdOrName) {
  let roomId;
  let roomName;

  // Check if it's a room name (string) or ID (BigInt/number)
  if (typeof roomIdOrName === "string") {
    try {
      const resolved = await createRoomMapping(roomIdOrName);
      roomId = resolved.convId;
      roomName = resolved.displayName;
    } catch (error) {
      logMessage("Error", error.message || "Failed to join room");
      return;
    }
  } else {
    // It's a numeric ID - ensure it's BigInt
    roomId =
      typeof roomIdOrName === "bigint" ? roomIdOrName : BigInt(roomIdOrName);
    if (roomId === SYSTEM_ROOM_ID) {
      showSystemLog();
      return;
    }
    roomName = getRoomName(roomId);
  }

  if (roomId === 0n) {
    logMessage("Error", "WORKSPACE DATA SCOPE IS NOT A CHAT ROOM");
    return;
  }

  // Add to subscribed rooms
  subscribedRooms.add(roomId);

  // Subscribe to the room
  subscribeToConversations([roomId]);

  // Switch to the room
  switchToRoom(roomId);

  // Save to localStorage
  saveRoomsToStorage();

  logMessage("CommandResult", `JOINED ${roomName}`);
}

function leaveRoom(roomIdOrName) {
  let roomId;
  let roomName;

  // Check if it's a room name (string) or ID (BigInt/number)
  if (typeof roomIdOrName === "string") {
    roomName = roomIdOrName.toUpperCase();

    // First try to find existing room with this custom name
    for (let [id, name] of roomNames.entries()) {
      if (name === roomName) {
        roomId = id;
        break;
      }
    }

    // If not found by name, check if it matches the ROOM-{ID} pattern
    if (!roomId) {
      const roomIdMatch = roomName.match(/^ROOM-(\d+)$/);
      if (roomIdMatch) {
        const extractedId = BigInt(roomIdMatch[1]);
        // Check if this room actually exists in our subscribed rooms
        if (subscribedRooms.has(extractedId)) {
          roomId = extractedId;
        }
      }
    }

    if (!roomId) {
      logMessage("Error", `Room ${roomName} not found`);
      return;
    }
  } else {
    // It's a numeric ID - ensure it's BigInt
    roomId =
      typeof roomIdOrName === "bigint" ? roomIdOrName : BigInt(roomIdOrName);
    roomName = getRoomName(roomId);
  }

  if (roomId === 0n) {
    logMessage("Error", "WORKSPACE DATA SCOPE IS NOT A CHAT ROOM");
    return;
  }

  // Check if we're subscribed to this room
  if (!subscribedRooms.has(roomId)) {
    logMessage("Error", `Not subscribed to ${roomName}`);
    return;
  }

  // Remove from subscribed rooms
  subscribedRooms.delete(roomId);

  // Unsubscribe from the room
  unsubscribeFromConversations([roomId]);

  // Clear room data
  roomActivity.delete(roomId);
  roomHistory.delete(roomId);
  roomPresence.delete(roomId);
  roomPresenceSequences.delete(roomId);

  // If we're leaving the current room, switch to another room or default
  if (roomId === currentRoomId) {
    if (subscribedRooms.size > 0) {
      // Switch to the first available room
      const nextRoomId = subscribedRooms.values().next().value;
      switchToRoom(nextRoomId);
    } else {
      // No rooms left, clear chat
      document.getElementById("logOutput").innerHTML = "";
      currentRoomId = null;
    }
  }

  updateRoomUI();
  updateAutocompleteRoomData();

  // Save to localStorage
  saveRoomsToStorage();

  logMessage("CommandResult", `LEFT ${roomName}`);
}

// =============================================================================
// DATA PERSISTENCE (LOCALSTORAGE)
// =============================================================================

const ROOM_MEMBERSHIP_STORAGE_PREFIX = "nrc-room-membership:";

function getRoomMembershipStorageKey() {
  return `${ROOM_MEMBERSHIP_STORAGE_PREFIX}${currentWorkspaceId}`;
}

function saveRoomsToStorage() {
  try {
    const rooms = Array.from(subscribedRooms)
      .filter((roomId) => !isDMConversation(roomId) && roomId !== SYSTEM_ROOM_ID)
      .map((roomId) => ({
        id: roomId.toString(),
        name: roomNames.get(roomId) || null,
      }));

    localStorage.setItem(
      getRoomMembershipStorageKey(),
      JSON.stringify({ version: 1, rooms }),
    );
  } catch (e) {
    console.warn("Failed to save room membership:", e);
  }
}

function loadRoomsFromStorage() {
  try {
    const stored = localStorage.getItem(getRoomMembershipStorageKey());
    if (!stored) return Promise.resolve(false);

    const state = JSON.parse(stored);
    const rooms = Array.isArray(state?.rooms) ? state.rooms : [];
    let loaded = 0;

    rooms.forEach((room) => {
      if (!room || !room.id) return;

      try {
        const roomId = BigInt(room.id);
        if (roomId === 0n || roomId === SYSTEM_ROOM_ID || isDMConversation(roomId)) return;

        subscribedRooms.add(roomId);
        if (room.name) {
          const normalizedName = normalizeRoomName(room.name);
          if (normalizedName) {
            roomNames.set(roomId, normalizedName);
          }
        }
        loaded++;
      } catch (e) {
        console.warn("Ignoring invalid stored room membership:", room, e);
      }
    });

    return Promise.resolve(loaded > 0);
  } catch (e) {
    console.warn("Failed to load room membership:", e);
    return Promise.resolve(false);
  }
}

function clearStoredRooms() {
  try {
    localStorage.removeItem(getRoomMembershipStorageKey());
  } catch (e) {
    console.warn("Failed to clear room membership:", e);
  }
  return Promise.resolve();
}

// --- UI State Storage (localStorage) ---

const UI_STATE_KEY = "nrc-ui-state";

function saveUIState() {
  try {
    const viewToMode = {
      chat: "message",
      systemLog: "systemLog",
      kanban: "task",
      reminders: "reminders",
      attention: "attention",
      calendar: "calendar",
      notes: "notes",
      graph: "graph",
    };
    const view = window.NRCViewManager ? window.NRCViewManager.getActiveView() : "chat";
    const state = {
      roomId: currentRoomId.toString(),
      mode: viewToMode[view] || "message",
    };
    localStorage.setItem(UI_STATE_KEY, JSON.stringify(state));
  } catch (e) {
    console.warn("Failed to save UI state:", e);
  }
}

function loadUIState() {
  try {
    const stored = localStorage.getItem(UI_STATE_KEY);
    if (!stored) return null;
    const state = JSON.parse(stored);
    if (state.roomId) {
      state.roomId = BigInt(state.roomId);
    }
    return state;
  } catch (e) {
    console.warn("Failed to load UI state:", e);
    return null;
  }
}

// --- Workspace Storage ---

function saveWorkspaceToStorage() {
  // No-op: Persistence removed
}

function loadWorkspaceFromStorage() {
  // First check URL hash
  const hash = window.location.hash.substring(1); // Remove #
  const params = new URLSearchParams(hash);
  const urlWorkspace = params.get("workspace");

  if (urlWorkspace) {
    console.log("Loaded workspace from URL:", urlWorkspace);
    return Promise.resolve(urlWorkspace);
  }

  // No fallback to IndexedDB
  return Promise.resolve("workspace1"); // Default workspace
}

function saveRecentWorkspaces() {
  // No-op: Persistence removed
}

function loadRecentWorkspaces() {
  // No-op: Persistence removed
  return Promise.resolve(false);
}

function addToRecentWorkspaces(workspaceId) {
  // Remove if already exists
  recentWorkspaces = recentWorkspaces.filter((ws) => ws !== workspaceId);

  // Add to beginning
  recentWorkspaces.unshift(workspaceId);

  // Keep only last 10
  if (recentWorkspaces.length > 10) {
    recentWorkspaces = recentWorkspaces.slice(0, 10);
  }

  saveRecentWorkspaces();
}

function clearStoredWorkspaceData() {
  // No-op: Persistence removed
  return Promise.resolve();
}

// --- Workspace Switching ---

function switchToWorkspace(workspaceId) {
  // Validate workspace ID
  if (!workspaceId || workspaceId.trim() === "") {
    logMessage("Error", "⚠ WORKSPACE ID CANNOT BE EMPTY");
    return false;
  }

  // Clean the workspace ID (remove extra spaces)
  workspaceId = workspaceId.trim();

  if (window.NRCInspector?.hasEntity() && !window.NRCInspector.consumeWorkspaceChange(workspaceId)) {
    window.NRCInspector.requestWorkspaceChange(workspaceId, () => switchToWorkspace(workspaceId));
    return true;
  }

  // Check if already connected to this workspace
  if (workspaceId === currentWorkspaceId) {
    logSystem(`ALREADY IN WORKSPACE ${workspaceId}`, "workspace", "DEBUG");
    return true;
  }

  // Add current workspace to recent list
  if (currentWorkspaceId && currentWorkspaceId !== workspaceId) {
    addToRecentWorkspaces(currentWorkspaceId);
  }

  // Save new workspace to storage - REMOVED
  // chatStorage.setMetadata("currentWorkspace", workspaceId);

  // Reload page with new workspace
  logSystem(`SWITCHING TO WORKSPACE ${workspaceId}`, "workspace");
  window.location.hash = `workspace=${encodeURIComponent(workspaceId)}`;
  window.location.reload();

  return true;
}

function updateRoomUI() {
  if (window.NRCAI?.onRoomChanged) {
    window.NRCAI.onRoomChanged(currentRoomId);
  }

  if (window.NRCViewManager?.getActiveView() === "chat") {
    window.NRCPageTitle?.set(systemLogVisible ? "SYSTEM" : getRoomName(currentRoomId));
  }

  const title = document.getElementById("chatHeaderTitle");
  if (title) {
    title.textContent = systemLogVisible
      ? "SYSTEM"
      : window.NRCAI?.isSullivanView?.() ? "SULLIVAN / AI WORKBENCH" : "MESSAGES";
  }

  // Data views never inherit the selected chat's scope.
  const sidebarViewRoomName = document.getElementById("sidebarViewRoomName");
  if (sidebarViewRoomName) sidebarViewRoomName.textContent = "WORKSPACE";

  // Update room list (sorted: default room first, then others in numeric order)
  const roomList = document.getElementById("roomList");
  roomList.innerHTML = "";

  // Sort rooms: default room first, then others in numeric order
  // Filter out DM conversations - they're shown in the DM list section
  const sortedRooms = Array.from(subscribedRooms)
    .filter((id) => id !== 0n && !isDMConversation(id))
    .sort((a, b) => {
      if (a === DEFAULT_ROOM_ID) return -1;
      if (b === DEFAULT_ROOM_ID) return 1;
      return Number(a - b); // Others in numeric order
    });

  for (let roomId of sortedRooms) {
    const roomDiv = document.createElement("div");
    roomDiv.className = "btn nav-tab room-item";
    roomDiv.setAttribute("role", "button");
    roomDiv.tabIndex = 0;
    roomDiv.addEventListener("keydown", event => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); roomDiv.click(); }
    });
    roomDiv.dataset.room = roomId.toString();
    roomDiv.style.setProperty("--room-accent", `var(--room-color-${getRoomColorIndex(roomId)})`);
    roomDiv.textContent = getRoomName(roomId);

    const badge = document.createElement("span");
    badge.className = "sidebar-unread-count";
    badge.hidden = true;
    roomDiv.appendChild(badge);

    if (roomId === currentRoomId && window.NRCViewManager?.getActiveView() === "chat") {
      roomDiv.classList.add("active");
      roomDiv.setAttribute("aria-current", "page");
    }

    if (roomActivity.has(roomId)) {
      roomDiv.classList.add("has-activity");
    }

    // Add click handler for room switching
    roomDiv.addEventListener("click", () => openChatRoom(roomId));

    roomList.appendChild(roomDiv);
  }

  window.NRCChat.update();
  // Update autocomplete if it's currently visible
  updateAutocompleteRoomData();

  // Update agenda display for current room
  updateAgendaDisplay();
  updateChatUnreadCount();
  window.NRCInspector?.refreshContext();
}

function updateAgendaDisplay() {
  // Agenda assets remain supported by the protocol, but Memo has no frontend view.
}

function formatOwnerTimestamp(owner, timestampStr) {
  return `BY <span class="status-value-mono">${escapeHtml(owner || "—")}</span> // <span class="status-value-mono">${escapeHtml(timestampStr)}</span>`;
}

function countMarkdownTaskListItems(tokens) {
  let count = 0;
  for (const token of tokens || []) {
    if (token.type === "list") {
      for (const item of token.items || []) {
        if (item.task) count++;
        count += countMarkdownTaskListItems(item.tokens);
      }
    } else if (token.type === "blockquote") {
      count += countMarkdownTaskListItems(token.tokens);
    }
  }
  return count;
}

// Build source offsets only when the line scan agrees exactly with Marked's
// parsed task-list item count. Ambiguous documents stay read-only rather than
// risk toggling the wrong source text.
function getMarkdownCheckboxOffsets(markdown) {
  const source = String(markdown || "");
  let parsedCount;
  try {
    parsedCount = countMarkdownTaskListItems(marked.lexer(source));
  } catch (error) {
    console.warn("Unable to map Markdown checkboxes:", error);
    return [];
  }

  const offsets = [];
  const lines = source.split("\n");
  let sourceOffset = 0;
  let fence = null;

  for (const line of lines) {
    const withoutQuote = line.replace(/^\s*(?:>\s*)*/, "");
    const fenceMatch = withoutQuote.match(/^ {0,3}(`{3,}|~{3,})/);
    if (fence) {
      if (fenceMatch && fenceMatch[1][0] === fence.char && fenceMatch[1].length >= fence.length) {
        fence = null;
      }
      sourceOffset += line.length + 1;
      continue;
    }
    if (fenceMatch) {
      fence = { char: fenceMatch[1][0], length: fenceMatch[1].length };
      sourceOffset += line.length + 1;
      continue;
    }

    const checkboxMatch = line.match(
      /^(\s*(?:>\s*)*(?:[*+-]|\d+[.)])\s+\[)([ xX])(\])(?:[ \t]|$)/,
    );
    if (checkboxMatch) offsets.push(sourceOffset + checkboxMatch[1].length);
    sourceOffset += line.length + 1;
  }

  return offsets.length === parsedCount ? offsets : [];
}

function toggleMarkdownCheckbox(markdown, checkboxIndex) {
  const source = String(markdown || "");
  const offset = getMarkdownCheckboxOffsets(source)[checkboxIndex];
  if (offset === undefined || !/[ xX]/.test(source[offset])) return null;
  const newState = source[offset].toLowerCase() === "x" ? " " : "x";
  return `${source.slice(0, offset)}${newState}${source.slice(offset + 1)}`;
}

function attachMarkdownCheckboxHandlers(container, getMarkdown, onToggle) {
  if (!container) return;

  const checkboxes = container.querySelectorAll(
    "input[type='checkbox'][data-nrc-markdown-checkbox]",
  );
  if (checkboxes.length !== getMarkdownCheckboxOffsets(getMarkdown()).length) return;

  checkboxes.forEach((checkbox, index) => {
    checkbox.removeAttribute("disabled");
    checkbox.addEventListener("dblclick", (event) => {
      event.preventDefault();
      event.stopPropagation();
    });
    checkbox.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      const updatedMarkdown = toggleMarkdownCheckbox(getMarkdown(), index);
      if (updatedMarkdown !== null) onToggle(updatedMarkdown);
    });
  });
}

// =============================================================================
// MESSAGE HISTORY MANAGEMENT
// =============================================================================

// --- Markdown Support ---

function parseMarkdown(text) {
  marked.setOptions({
    breaks: true,
    gfm: true,
  });

  const source = text == null ? "" : String(text);
  const renderedHtml = marked.parse(source);
  const container = document.createElement("div");
  container.innerHTML = renderedHtml;

  container.querySelectorAll("img").forEach((image) => {
    image.classList.add("markdown-image");
    image.setAttribute("role", "button");
    image.setAttribute("tabindex", "0");
    image.title = image.title || image.alt || "Open image full width";
  });

  const checkboxOffsets = getMarkdownCheckboxOffsets(source);
  const renderedCheckboxes = container.querySelectorAll("input[type='checkbox'][disabled]");
  if (renderedCheckboxes.length === checkboxOffsets.length) {
    renderedCheckboxes.forEach((checkbox, index) => {
      checkbox.dataset.nrcMarkdownCheckbox = String(index);
    });
  }

  // Apply KaTeX rendering after markdown conversion so inline math like
  // $O(\log n)$ and block math via $$...$$ render in normal chat content.
  if (typeof renderMathInElement === "function") {
    try {
      renderMathInElement(container, {
        throwOnError: false,
        strict: "ignore",
        output: "html",
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "\\[", right: "\\]", display: true },
          { left: "$", right: "$", display: false },
          { left: "\\(", right: "\\)", display: false },
        ],
      });
    } catch (err) {
      console.warn("KaTeX render failed:", err);
    }
  }

  return DOMPurify.sanitize(container.innerHTML);
}

function splitMessageContent(message) {
  // Split message after first colon to separate timestamp/author from content
  // Format: <b>USERNAME</b> 22:51 message content
  const colonIndex = message.indexOf(":");

  if (colonIndex !== -1) {
    // Find the space after the timestamp (after the colon and two digits)
    const afterColon = colonIndex + 3; // Skip ":xx" where xx are minutes
    const spaceIndex = message.indexOf(" ", afterColon);

    if (spaceIndex !== -1) {
      const prefix = message.substring(0, spaceIndex);
      const content = message.substring(spaceIndex + 1); // +1 to skip space
      return { prefix, content };
    }
  }

  // Return null if format doesn't match expected pattern
  return null;
}

// --- Message Persistence ---

function saveMessagesToStorage(roomId) {
  // No-op: Persistence removed
}

function loadMessagesFromStorage(roomId) {
  // No-op: Persistence removed
  return Promise.resolve(false);
}

function clearStoredMessages(roomId = null) {
  // No-op: Persistence removed
}

async function clearCurrentRoomMessages(options = {}) {
  const { logResult = true, roomId = currentRoomId, aiContextRoomId = null } = options;

  clearStoredMessages(roomId);
  if (aiContextRoomId == null) {
    roomHistory.set(roomId, []);
  } else {
    const contextID = String(aiContextRoomId);
    roomHistory.set(roomId, (roomHistory.get(roomId) || []).filter(
      (message) => String(message.aiContextRoomId) !== contextID,
    ));
  }
  if (roomId === currentRoomId || String(window.NRCAI?.getDisplayConvId?.()) === String(roomId)) {
    await loadRoomHistory(roomId, { aiContextRoomId });
  }

  if (logResult) {
    logMessage(
      "CommandResult",
      `✓ CLEARED MESSAGES FOR ${getRoomName(roomId)}`,
    );
  }
}

window.NRCChat = window.NRCChat || {};
window.NRCChat.clearCurrentRoomMessages = clearCurrentRoomMessages;

// --- UI and Logging ---

function systemLogMeta(source, level = "INFO") {
  return {
    systemSource: source,
    systemLevel: level,
  };
}

function logSystem(message, source = "client", level = "INFO") {
  logMessage("System", message, null, systemLogMeta(source, level));
}

function logMessage(type, message, roomId = null, metadata = {}) {
  const targetRoomId = roomId ?? currentRoomId;
  const attachment = (type === "Message" || type === "Sent") ? parseChatAttachment(message) : null;
  const messageData = {
    type: type,
    message: attachment ? chatAttachmentMarkdown(attachment) : message,
    attachment,
    timestamp: metadata.timestamp || Date.now(),
    roomId: targetRoomId,
    author: metadata.author || null,
    imageData: metadata.imageData || null,
    aiSources: metadata.aiSources || null,
    aiActionPlan: metadata.aiActionPlan || null,
    aiContextRoomId: metadata.aiContextRoomId ?? null,
    aiRunId: metadata.aiRunId || null,
    aiQuestion: metadata.aiQuestion || null,
    aiAnswer: metadata.aiAnswer || null,
    aiMode: metadata.aiMode || null,
    aiRunStatus: metadata.aiRunStatus || null,
    systemLevel: metadata.systemLevel || metadata.level || null,
    systemSource: metadata.systemSource || metadata.source || null,
    pid: metadata.pid || null,
    suppressNotification: metadata.suppressNotification === true,
    sequence: metadata.sequence ?? null,
    clientMessageId: metadata.clientMessageId || null,
    retained: metadata.retained === true,
  };
  if (isAiRunStatusMessage(messageData)) {
    messageData.suppressNotification = true;
  }

  // Keep console logging for debugging
  if (type === "System" || type === "Error" || type === "Activity") {
    console.log(message);
  }

  // If System message, route to the client-side operator log.
  if (type === "System") {
    const systemMessageData = { ...messageData, roomId: null };
    storeSystemLogMessage(systemMessageData);
    handleVisibleSystemLogEntry();
    return;
  }

  // Mirror user-visible errors into the operator log as structured ERROR entries.
  if (type === "Error") {
    const systemErrorData = {
      ...messageData,
      roomId: null,
      systemLevel: messageData.systemLevel || "ERROR",
      systemSource: messageData.systemSource || inferSystemLogSource(messageData),
    };
    storeSystemLogMessage(systemErrorData);
    handleVisibleSystemLogEntry();
  }

  // If Activity message, route to current room with targetRoomId
  if (type === "Activity") {
    const activityMessageData = { ...messageData, roomId: targetRoomId };
    storeMessageInRoom(activityMessageData, targetRoomId);

    // Only display if it's for the current room
    if (isConversationVisible(targetRoomId, activityMessageData)) {
      displayMessage(activityMessageData);
    }
    return;
  }

  // Store chat messages and command results
  if (
    type === "Message" ||
    type === "Sent" ||
    type === "CommandResult" ||
    type === "Error" ||
    type === "Image"
  ) {
    // Store using shared helper
    if (!storeMessageInRoom(messageData, targetRoomId)) {
      if (isConversationVisible(targetRoomId, messageData)) loadRoomHistory(targetRoomId);
      return;
    }

    window.NRCChat.received(messageData);
    if (type === "Message" && !messageData.suppressNotification) {
      // Suppress desktop popups when the message is already visible in the active room.
      const isVisibleInActiveRoom =
        isConversationExposed(targetRoomId, messageData) && !document.hidden;
      const isOwnMessage = messageData.author === "YOU";
      if (!isVisibleInActiveRoom && !isOwnMessage && window.NRCChat.shouldNotify(messageData)) {
        const roomLabel = getRoomName(targetRoomId);
        const authorLabel = messageData.author || "MESSAGE";
        sendNotification(`[${roomLabel}] ${authorLabel}`, {
          body: messageData.message,
        });
      }
      incrementUnread();
    }
  }

  // Only display message if it's for the current room
  if (isConversationVisible(targetRoomId, messageData)) {
    displayMessage(messageData);
  }
}

function isConversationExposed(roomId, messageData = null) {
  if (isMobileConversationCovered()) return false;
  return isConversationVisible(roomId, messageData);
}

function isConversationVisible(roomId, messageData = null) {
  const activeView = window.NRCViewManager?.getActiveView?.() || "chat";
  if (activeView === "chat" && !systemLogVisible && roomId === currentRoomId && !window.NRCAI?.isSullivanView?.()) return true;
  if (!window.NRCAI?.isSullivanView?.()) return false;
  if (String(window.NRCAI.getDisplayConvId?.()) !== String(roomId)) return false;
  if (messageData?.aiContextRoomId == null) return false;
  return String(messageData.aiContextRoomId) === String(window.NRCAI.getContextConvId?.());
}

// A string third argument is a URL to open; a function is invoked in place, so
// an in-app destination (an inspector record, a view) can be the click target.
function sendNotification(title, options = {}, onClickUrl = null) {
  if (!("Notification" in window)) {
    console.warn(
      "[Notifications] Browser does not support desktop notifications",
    );
    return;
  }

  if (Notification.permission === "denied") {
    console.warn(
      "[Notifications] Permission denied - use /notifications to check status",
    );
    return;
  }

  if (Notification.permission === "default") {
    console.warn(
      "[Notifications] Permission not granted - use /notifications to enable",
    );
    return;
  }

  const notification = new Notification(title, options);
  if (onClickUrl) {
    notification.onclick = () => {
      if (typeof onClickUrl === "function") {
        onClickUrl();
      } else {
        window.open(onClickUrl, "_blank");
      }
      notification.close();
    };
  }
  return true;
}

// =============================================================================
// FAVICON BADGE (unread indicator on browser tab)
// =============================================================================
const originalFaviconHref = "favicon.png";
const defaultPageTitle = "NRC TERMINAL";
let pageTitle = defaultPageTitle;
let faviconBadgeActive = false;
let unreadCount = 0;

function updateDocumentTitle() {
  const title = unreadCount > 0 ? `(${unreadCount}) ${pageTitle}` : pageTitle;
  document.title = title;

  const pwaTitlebarTitle = document.getElementById("pwaTitlebarTitle");
  if (pwaTitlebarTitle) {
    pwaTitlebarTitle.textContent =
      title === defaultPageTitle ? title : `NRC TERMINAL — ${title}`;
  }
}

function setPageTitle(content) {
  const title = String(content || "").trim();
  pageTitle = title ? `${title} · NRC` : defaultPageTitle;
  updateDocumentTitle();
}

window.NRCPageTitle = {
  set: setPageTitle,
  reset: () => setPageTitle(""),
};

function setFaviconBadge(show) {
  faviconBadgeActive = show;

  const link =
    document.querySelector('link[rel="icon"]') ||
    document.createElement("link");
  link.rel = "icon";
  link.type = "image/png";

  if (show && unreadCount > 0) {
    const countText = unreadCount > 9 ? "9+" : String(unreadCount);
    const fontSize = countText.length > 1 ? 14 : 16;
    const themeStyles = getComputedStyle(document.documentElement);
    const iconBackground = themeStyles.getPropertyValue("--bg-primary").trim();
    const iconBorder = themeStyles.getPropertyValue("--border-strong").trim();
    const iconAccent = themeStyles.getPropertyValue("--accent-current").trim();
    const badgeBackground = themeStyles.getPropertyValue("--accent-danger").trim();
    const badgeText = themeStyles.getPropertyValue("--on-danger").trim();
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" fill="${iconBackground}"/>
  <rect x="2" y="2" width="60" height="60" fill="none" stroke="${iconBorder}" stroke-width="2"/>
  <text x="32" y="44" font-family="Recursive, IBM Plex Mono, monospace" font-size="28" font-weight="700"
        text-anchor="middle" fill="${iconAccent}" letter-spacing="2">NRC</text>
  <rect x="48" y="36" width="3" height="12" fill="${iconAccent}" opacity="0.8"/>
  <circle cx="52" cy="12" r="12" fill="${badgeBackground}"/>
  <text x="52" y="17" font-family="Recursive, Arial, sans-serif" font-size="${fontSize}" font-weight="700"
        text-anchor="middle" fill="${badgeText}">${countText}</text>
</svg>`;
    link.href = "data:image/svg+xml," + encodeURIComponent(svg);
    link.type = "image/svg+xml";
  } else {
    link.href = originalFaviconHref;
    link.type = "image/png";
  }

  updateDocumentTitle();

  if (!link.parentNode) document.head.appendChild(link);
}

function incrementUnread() {
  if (!document.hidden) return;
  unreadCount++;
  setFaviconBadge(true);
}

// Clear badge when tab gains focus
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    unreadCount = 0;
    setFaviconBadge(false);
  }
});

function handleNotificationsCommand() {
  if (!("Notification" in window)) {
    logMessage("Error", "NOTIFICATIONS NOT SUPPORTED IN THIS BROWSER");
    return;
  }

  const permission = Notification.permission;
  updateNotificationStatus();

  if (permission === "granted") {
    // Already enabled, no message needed
  } else if (permission === "denied") {
    logMessage(
      "Error",
      "NOTIFICATIONS: BLOCKED - reset in browser Site Settings",
    );
  } else {
    Notification.requestPermission().then((result) => {
      updateNotificationStatus();
      if (result === "granted") {
        new Notification("NRC", { body: "Notifications enabled" });
      } else if (result === "denied") {
        logMessage("Error", "NOTIFICATIONS: BLOCKED");
      }
      // Dismissed: no message needed
    });
  }
}

// Reminder notifications are workspace-scoped because a reminder carries a
// creator, not an assignee. The switch lives in the command palette until the
// ATTENTION register header carries it.
function handleReminderNotificationsCommand(args) {
  const value = String(args || "").trim().toLowerCase();
  if (value !== "all" && value !== "off") {
    const current = window.NRCReminderNotify?.mode?.() === "off" ? "OFF" : "ALL";
    logMessage("CommandResult", `REMINDER NOTIFICATIONS: ${current} (USE ALL|OFF)`);
    return;
  }
  window.NRCReminderNotify?.setMode?.(value);
  logMessage("CommandResult", `REMINDER NOTIFICATIONS ${value.toUpperCase()}`);
}

function handleAppointmentNotificationsCommand(args) {
  const value = String(args || "").trim().toLowerCase();
  if (value !== "mine" && value !== "off") {
    logMessage("CommandResult", `APPOINTMENT NOTIFICATIONS: ${window.NRCAppointmentNotify?.mode().toUpperCase()} (USE MINE|OFF) · 15 MIN BEFORE START · OPEN TAB REQUIRED`);
    return;
  }
  window.NRCAppointmentNotify?.setMode(value).catch(() => logMessage("Error", "COULD NOT ENABLE APPOINTMENT NOTIFICATIONS"));
}

function updateNotificationStatus() {
  const el = document.getElementById("notificationStatus");
  if (!el) return;

  if (!("Notification" in window)) {
    el.textContent = "N/A";
    return;
  }

  const permission = Notification.permission;
  if (permission === "granted") {
    el.textContent = "ON";
    el.classList.add("status-ok");
    el.classList.remove("status-error");
  } else if (permission === "denied") {
    el.textContent = "BLOCKED";
    el.classList.add("status-error");
    el.classList.remove("status-ok");
  } else {
    el.textContent = "OFF";
    el.classList.remove("status-ok", "status-error");
  }
}

// =============================================================================
// COLOR THEME MANAGEMENT
// =============================================================================

const THEMES = [
  "lupine",
  "matte-black",
  "tokyo-night",
  "ayu",
  "modus-vivendi",
  "catppuccin",
  "catppuccin-latte",
  "ethereal",
  "everforest",
  "flexoki-light",
  "forest-night",
  "gruvbox",
  "hackerman",
  "kanagawa",
  "last-horizon",
  "lumon",
  "miasma",
  "nord",
  "osaka-jade",
  "retro-82",
  "ristretto",
  "solitude",
  "rose-pine",
  "vantablack",
  "white",
];

let currentTheme = THEMES[0];

function handleThemeCommand(args) {
  const arg = args.toLowerCase().trim();

  if (THEMES.includes(arg)) {
    setTheme(arg);
  } else if (arg === "") {
    cycleTheme();
  } else {
    logMessage("Error", `USAGE: /theme [${THEMES.join("|")}]`);
  }
}

function setTheme(theme, persist = true) {
  currentTheme = theme;
  document.documentElement.setAttribute("data-theme", theme);
  document.querySelector('meta[name="theme-color"]').content = getComputedStyle(
    document.documentElement,
  ).getPropertyValue("--bg-primary").trim();
  updateThemeStatus();
  document.dispatchEvent(new CustomEvent("nrc:theme-changed", { detail: { theme } }));

  if (persist) {
    try {
      localStorage.setItem("nrc-theme", theme);
    } catch (e) {
      console.warn("Failed to save theme:", e);
    }
  }
}

function cycleTheme() {
  const currentIndex = THEMES.indexOf(currentTheme);
  const nextTheme = THEMES[(currentIndex + 1) % THEMES.length];
  setTheme(nextTheme);
}

function updateThemeStatus() {
  const el = document.getElementById("themeStatus");
  if (!el) return;
  el.textContent = currentTheme.toUpperCase();
}

function initTheme() {
  try {
    const requestedTheme = new URLSearchParams(window.location.search).get("theme");
    const savedTheme = localStorage.getItem("nrc-theme");
    if (THEMES.includes(requestedTheme)) {
      setTheme(requestedTheme, false);
    } else if (THEMES.includes(savedTheme)) {
      setTheme(savedTheme);
    } else {
      setTheme(currentTheme);
    }
  } catch (e) {
    console.warn("Failed to load theme:", e);
    setTheme(currentTheme);
  }

  const themeRow = document.getElementById("themeToggleRow");
  if (themeRow) {
    themeRow.addEventListener("click", () => {
      cycleTheme();
    });
  }
}

// Maximum number of message rows to keep in the DOM for performance
const MAX_DOM_MESSAGES = 150;

function trimOldMessages() {
  const logOutput = document.getElementById("logOutput");
  if (!logOutput) return;

  const rows = logOutput.querySelectorAll(":scope > .log-row, :scope > .ai-workbench-run");
  // Keep the reading position until the local-history bound is reached.
  const limit = window.NRCChat.keepHistory() ? 1000 : MAX_DOM_MESSAGES;
  if (rows.length > limit) {
    const rowsToRemove = rows.length - limit;
    for (let i = 0; i < rowsToRemove; i++) {
      rows[i].remove();
    }
  }
}

function getMessageText(messageData) {
  return String(messageData?.message || "").trim();
}

function isSullivanAuthor(messageData) {
  const author = String(messageData?.author || "").toLowerCase();
  return author === "sullivan" || author.startsWith("sullivan-");
}

function isAiAnswerMessage(messageData) {
  if (messageData?.type !== "Message") return false;
  if (!isSullivanAuthor(messageData) && !messageData.aiContextRoomId) return false;
  return /^\*\*AI RESPONSE\b/i.test(getMessageText(messageData));
}

function normalizeAiRunStep(messageData) {
  const text = getMessageText(messageData);
  if (!text) return null;

  const upper = text.toUpperCase();
  if (messageData?.type === "Activity" && upper === "AI PREPARING SERVICE + DISPLAY ...") {
    return { label: "preparing service + display", state: "running", raw: text };
  }
  if (messageData?.type === "Activity" && /^AI PROCESSING \((FRESH|FOLLOW-UP)\) \.\.\.$/i.test(text)) {
    const mode = text.match(/\(([^)]+)\)/)?.[1] || "RUN";
    return { label: `processing ${mode.toLowerCase()}`, state: "running", raw: text };
  }
  if (messageData?.type === "Activity" && upper === "AI RUN CANCELLED") {
    return { label: "request cancelled", state: "error", raw: text, cancelled: true, terminal: true };
  }
  if (messageData?.type === "Activity" && upper.startsWith("AI RUN FAILED:")) {
    return { label: text, state: "error", raw: text, terminal: true };
  }

  if (messageData?.type !== "Message" || !isSullivanAuthor(messageData)) return null;
  if (isAiAnswerMessage(messageData)) return null;

  if (upper === "RECEIVED REQUEST. PREPARING CONTEXT ...") {
    return { label: "request received / preparing context", state: "ok", raw: text };
  }
  if (upper === "SEARCHING WORKSPACE CONTEXT + TRAVERSING GRAPH ...") {
    return { label: "workspace context + graph traversal", state: "running", raw: text };
  }
  if (upper === "SEARCHING ROOM CONTEXT + TRAVERSING GRAPH ...") {
    return { label: "room context + graph traversal", state: "running", raw: text };
  }
  if (upper === "RUNNING REASONING PASS ...") {
    return { label: "reasoning pass", state: "running", raw: text };
  }
  if (/FAILED|ERROR/.test(upper)) {
    return { label: text.replace(/\.+$/, "").toLowerCase(), state: "error", raw: text, terminal: false };
  }

  const traceMatch = text.match(/^([a-z][a-z0-9_]*):(OK|ERROR):(\d+)ms$/i);
  if (traceMatch) {
    const toolName = traceMatch[1];
    return {
      label: toolName.replace(/_/g, " "),
      state: traceMatch[2].toLowerCase() === "ok" ? "ok" : "error",
      duration: `${traceMatch[3]}ms`,
      parentLabel: toolName === "room_context" ? "room context + graph traversal" : "reasoning pass",
      depth: 1,
      raw: text,
    };
  }

  return null;
}

function isAiRunStatusMessage(messageData) {
  return !!normalizeAiRunStep(messageData);
}

function resetLedgerContext() {
  const values = {
    ledgerQuery: "NO ACTIVE AI QUERY",
    ledgerMode: "—",
    ledgerScope: "—",
    ledgerRunStatus: "IDLE",
    ledgerRunPhase: "—",
    ledgerSourceCount: "00",
    ledgerAgent: "—",
    ledgerGenerated: "—",
  };
  Object.entries(values).forEach(([id, value]) => {
    const element = document.getElementById(id);
    if (element) element.textContent = value;
  });

  const query = document.getElementById("ledgerQuery");
  query?.classList.add("ledger-query-empty");

  document.getElementById("ledgerRunStatus")?.classList.remove(
    "ledger-value-complete",
    "ledger-value-error",
  );

  const sources = document.getElementById("ledgerSources");
  if (sources) {
    sources.innerHTML = '<div class="ledger-context-empty">NO SOURCES IN ACTIVE RESPONSE</div>';
  }
}

function updateLedgerQuery(messageData) {
  if (messageData?.type !== "Sent") return;

  const lines = getMessageText(messageData).split("\n");
  const header = lines[0]?.replaceAll("**", "").trim() || "";
  const match = header.match(/^(?:ASK|QUERY)\s*·\s*([^·]+)\s*·\s*CONTEXT\s+(.+)$/i);
  if (!match) return;

  resetLedgerContext();

  const query = document.getElementById("ledgerQuery");
  if (query) {
    query.textContent = lines.slice(1).join(" ").trim() || "AI QUERY";
    query.classList.remove("ledger-query-empty");
  }
  const mode = document.getElementById("ledgerMode");
  const scope = document.getElementById("ledgerScope");
  if (mode) mode.textContent = match[1].trim().toUpperCase();
  if (scope) scope.textContent = match[2].trim().toUpperCase();
}

function updateLedgerRun(step) {
  const status = document.getElementById("ledgerRunStatus");
  const phase = document.getElementById("ledgerRunPhase");
  if (status && !(step?.state === "error" && step?.terminal === false)) {
    status.textContent = step?.cancelled ? "CANCELLED" : step?.state === "error" ? "ERROR" : "RUNNING";
    status.classList.toggle("ledger-value-error", step?.state === "error");
    status.classList.remove("ledger-value-complete");
  }
  if (phase && step?.label) phase.textContent = step.label.toUpperCase();
}

function completeLedgerRun() {
  const status = document.getElementById("ledgerRunStatus");
  if (!status) return;
  status.textContent = "COMPLETE";
  status.classList.remove("ledger-value-error");
  status.classList.add("ledger-value-complete");
}

function openLedgerSource(type, id, source = null, contextRoomId = currentRoomId) {
  if (window.NRCAI?.navigateToSource) {
    window.NRCAI.navigateToSource(source || { type, id }, contextRoomId);
    return;
  }
  const normalized = String(type).toLowerCase();
  const entityType = normalized === "task" ? "task" : normalized === "reminder" ? "reminder" : "note";
  window.NRCInspector?.openEntity({ roomId: 0n, type: entityType, id });
}

function updateLedgerAnswer(messageData) {
  if (!isAiAnswerMessage(messageData)) return;

  completeLedgerRun();

  const agent = document.getElementById("ledgerAgent");
  const generated = document.getElementById("ledgerGenerated");
  if (agent) agent.textContent = String(messageData.author || "AI").toUpperCase();
  if (generated) generated.textContent = formatChatTimestamp(messageData.timestamp).slice(0, 8);

  const sources = Array.isArray(messageData.aiSources) ? messageData.aiSources : [];
  const contextRoomId = messageData.aiContextRoomId ?? messageData.roomId ?? currentRoomId;
  const count = document.getElementById("ledgerSourceCount");
  if (count) count.textContent = String(sources.length).padStart(2, "0");

  const list = document.getElementById("ledgerSources");
  if (!list) return;
  list.innerHTML = "";

  if (sources.length === 0) {
    list.innerHTML = '<div class="ledger-context-empty">NO SOURCES IN ACTIVE RESPONSE</div>';
    return;
  }

  sources.forEach((source) => {
    const type = String(source?.type || "source");
    const id = source?.id == null ? "?" : String(source.id);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "ledger-source-card";

    const reference = document.createElement("strong");
    reference.textContent = `${type}:${id}`.toUpperCase();
    const title = document.createElement("span");
    title.textContent = source?.title || source?.preview || "UNTITLED SOURCE";

    button.appendChild(reference);
    button.appendChild(title);
    button.addEventListener("click", () => openLedgerSource(type, id, source, contextRoomId));
    list.appendChild(button);
  });
}

function initLedgerContext() {
  resetLedgerContext();
}

function formatChatTimestamp(timestamp) {
  const date = new Date(timestamp);
  const hours = date.getHours().toString().padStart(2, "0");
  const minutes = date.getMinutes().toString().padStart(2, "0");
  const seconds = date.getSeconds().toString().padStart(2, "0");
  const millis = date.getMilliseconds().toString().padStart(3, "0");
  return `${hours}:${minutes}:${seconds}.${millis}`;
}

function getOpenAiRunRow(logOutput) {
  const rows = logOutput.querySelectorAll(":scope > .ai-workbench-run");
  for (let i = rows.length - 1; i >= 0; i--) {
    if (rows[i].dataset.aiRunStatus === "running") return rows[i];
  }
  return null;
}

function getAiRunContainer(logOutput, aiRunId, create = false) {
  let run = aiRunId
    ? Array.from(logOutput.querySelectorAll(":scope > .ai-workbench-run"))
      .find((candidate) => candidate.dataset.aiRunId === String(aiRunId))
    : getOpenAiRunRow(logOutput);
  if (!run && create && aiRunId) {
    run = document.createElement("section");
    run.className = "ai-workbench-run ai-workbench-run--running";
    run.dataset.aiRunId = String(aiRunId);
    run.dataset.aiRunStatus = "running";
    logOutput.appendChild(run);
  }
  return run;
}

function setAiRunContainerStatus(run, status) {
  if (!run) return;
  run.dataset.aiRunStatus = status;
  run.classList.remove(
    "ai-workbench-run--running", "ai-workbench-run--complete",
    "ai-workbench-run--error", "ai-workbench-run--cancelled",
  );
  run.classList.add(`ai-workbench-run--${status}`);
}

function updateAiRunHeader(row, statusText, titleText = null) {
  const headerTitle = row.querySelector(".ai-run-title-label");
  const headerStatus = row.querySelector(".ai-run-status");
  if (headerTitle && titleText) headerTitle.textContent = titleText;
  if (!headerStatus) return;
  headerStatus.textContent = statusText;
}

function setAiRunStepState(stepEl, state) {
  stepEl.classList.remove("ai-run-step--running", "ai-run-step--ok", "ai-run-step--error");
  stepEl.classList.add(`ai-run-step--${state}`);
  const mark = stepEl.querySelector(".ai-run-mark");
  if (mark) mark.textContent = state === "error" ? "×" : state === "running" ? "⟳" : "✓";
}

function findAiRunStepByLabel(steps, label) {
  return Array.from(steps.children).find((stepEl) => stepEl.dataset.label === label) || null;
}

function appendAiRunStep(row, step) {
  const steps = row.querySelector(".ai-run-steps");
  if (!steps) return;

  const stepEl = document.createElement("div");
  stepEl.className = `ai-run-step ai-run-step--${step.state}`;
  if (step.depth) stepEl.classList.add("ai-run-step--child");
  stepEl.dataset.label = step.label;
  if (step.parentLabel) stepEl.dataset.parentLabel = step.parentLabel;
  stepEl.title = step.raw || step.label;

  const mark = document.createElement("span");
  mark.className = "ai-run-mark";
  mark.textContent = step.state === "error" ? "×" : step.state === "running" ? "⟳" : "✓";

  const label = document.createElement("span");
  label.className = "ai-run-label";
  label.textContent = step.label;

  stepEl.appendChild(mark);
  stepEl.appendChild(label);

  if (step.duration) {
    const duration = document.createElement("span");
    duration.className = "ai-run-duration";
    duration.textContent = step.duration;
    stepEl.appendChild(duration);
  }

  if (step.parentLabel) {
    const parentStep = findAiRunStepByLabel(steps, step.parentLabel);
    if (parentStep) {
      setAiRunStepState(parentStep, step.state);

      let insertBefore = parentStep.nextElementSibling;
      while (insertBefore && insertBefore.dataset.parentLabel === step.parentLabel) {
        insertBefore = insertBefore.nextElementSibling;
      }
      steps.insertBefore(stepEl, insertBefore);
    } else {
      steps.appendChild(stepEl);
    }
  } else {
    steps.appendChild(stepEl);
  }

  if (step.state === "error" && step.terminal !== false) {
    row.classList.add("ai-run-row--error");
    row.dataset.complete = "true";
    updateAiRunHeader(row, "DETAILS", step.cancelled ? "AI CANCELLED" : "AI ERROR");
  }
}

function renderAiRunStatus(messageData, timeStr) {
  const logOutput = document.getElementById("logOutput");
  if (!logOutput) return;

  const step = normalizeAiRunStep(messageData);
  if (!step) return;
  let run = getAiRunContainer(logOutput, messageData.aiRunId, false);
  if (!run) run = getOpenAiRunRow(logOutput);
  if (!run) return;
  if (run.dataset.aiRunStatus !== "running") return;
  updateLedgerRun(step);
  let row = run.querySelector(":scope > .ai-run-row");
  if (!row) {
    row = document.createElement("div");
    row.className = "log-row type-activity ai-run-row";

    const colTime = document.createElement("div");
    colTime.className = "col-time";
    colTime.textContent = timeStr.slice(0, 5);
    colTime.dataset.fullTime = timeStr;
    colTime.title = timeStr;

    const colTag = document.createElement("div");
    colTag.className = "col-tag";
    colTag.textContent = "SULLIVAN";
    colTag.title = "SULLIVAN AI RUN";

    const messageMeta = document.createElement("div");
    messageMeta.className = "message-meta";
    messageMeta.append(colTag, colTime);

    const colMessage = document.createElement("div");
    colMessage.className = "col-message message-content";

    const block = document.createElement("div");
    block.className = "ai-run-block";

    const header = document.createElement("button");
    header.type = "button";
    header.className = "ai-run-header";
    header.setAttribute("aria-expanded", "false");
    header.innerHTML = '<span class="ai-run-title"><span class="ai-run-indicator" aria-hidden="true">■</span><span class="ai-run-title-label">SULLIVAN THINKING</span></span><span class="ai-run-status" role="status" aria-live="polite" aria-atomic="true">PREPARING</span>';
    header.addEventListener("click", () => {
      row.classList.toggle("ai-run-row--expanded");
      header.setAttribute("aria-expanded", String(row.classList.contains("ai-run-row--expanded")));
    });

    const steps = document.createElement("div");
    steps.className = "ai-run-steps";
    steps.setAttribute("role", "log");
    steps.setAttribute("aria-live", "polite");
    steps.setAttribute("aria-relevant", "additions text");

    block.appendChild(header);
    block.appendChild(steps);
    colMessage.appendChild(block);
    row.appendChild(messageMeta);
    row.appendChild(colMessage);
    run.appendChild(row);
  }

  appendAiRunStep(row, step);
  if (!(step.state === "error" && step.terminal !== false)) {
    updateAiRunHeader(row, step.label.toUpperCase());
  }
  if (step.state === "error" && step.terminal !== false) {
    const status = step.cancelled ? "cancelled" : "error";
    setAiRunContainerStatus(run, status);
    row.classList.remove("ai-run-row--expanded");
    row.querySelector(".ai-run-header")?.setAttribute("aria-expanded", "false");
  }
  logOutput.scrollTop = logOutput.scrollHeight;
  trimOldMessages();
  updateChatStats();
}

function completeOpenAiRun(aiRunId, terminalStatus = "complete") {
  const logOutput = document.getElementById("logOutput");
  if (!logOutput) return;

  const run = getAiRunContainer(logOutput, aiRunId, false) || (!aiRunId ? getOpenAiRunRow(logOutput) : null);
  const row = run?.querySelector(":scope > .ai-run-row");
  if (!run || !row) return;

  row.querySelectorAll(".ai-run-step--running").forEach((stepEl) => {
    stepEl.classList.remove("ai-run-step--running");
    stepEl.classList.add("ai-run-step--ok");
    const mark = stepEl.querySelector(".ai-run-mark");
    if (mark) mark.textContent = "✓";
  });
  row.classList.add("ai-run-row--complete");
  setAiRunContainerStatus(run, terminalStatus);
  updateAiRunHeader(
    row,
    "DETAILS",
    terminalStatus === "complete" ? "AI COMPLETE" : `AI ${terminalStatus.toUpperCase()}`,
  );
  const header = row.querySelector(".ai-run-header");
  row.classList.remove("ai-run-row--expanded");
  header?.setAttribute("aria-expanded", "false");
  if (terminalStatus === "complete") completeLedgerRun();
}

function displayMessage(messageData) {
  // System messages belong to the operator log, not regular room history.
  if (messageData.type === "System" && !systemLogVisible) return;
  if (!window.NRCChat.matchesQuery(messageData)) return;

  const logOutput = document.getElementById("logOutput");
  if (!logOutput) return;
  const followChat = window.NRCChat.beforeAppend(messageData);

  if (isAiRunStatusMessage(messageData)) {
    renderAiRunStatus(messageData, formatChatTimestamp(messageData.timestamp));
    return;
  }

  const logRow = document.createElement("div");
  logRow.classList.add("log-row");
  logRow.classList.add(`type-${messageData.type.toLowerCase()}`);
  // A retained message can be addressed by its sequence; that is what a jump
  // from the attention register looks for.
  if (messageData.retained && messageData.sequence != null) {
    logRow.dataset.sequence = String(messageData.sequence);
  }
  if (messageData.type === "Sent") logRow.classList.add("message-own");
  if (isAiAnswerMessage(messageData)) logRow.classList.add("ledger-ai-answer");
  if (messageData.type === "Sent" && /^\*\*(?:ASK|QUERY)\b/i.test(getMessageText(messageData))) {
    logRow.classList.add("ledger-ai-query");
  }

  // 1. TIME Column
  const timeStr = formatChatTimestamp(messageData.timestamp);

  const colTime = document.createElement("div");
  colTime.className = "col-time";
  colTime.textContent = timeStr.slice(0, 5);
  colTime.dataset.fullTime = timeStr;
  colTime.title = timeStr;

  // 2. TAG Column
  const colTag = document.createElement("div");
  colTag.className = "col-tag";

  let tagText = "INFO";
  if (messageData.author) {
    tagText = messageData.author;
    colTag.classList.add("identity-actor");
  } else if (messageData.type === "CommandResult") {
    tagText = "CMD";
  } else if (messageData.type === "Error") {
    tagText = "ERROR";
  } else if (messageData.type === "System") {
    tagText = "SYSTEM";
  } else if (messageData.type === "Sent") {
    tagText = "YOU";
    colTag.classList.add("identity-actor");
  } else {
    tagText = messageData.type.toUpperCase();
  }

  colTag.textContent = tagText;
  colTag.title = tagText;

  const messageMeta = document.createElement("div");
  messageMeta.className = "message-meta";
  messageMeta.append(colTag, colTime);
  logRow.appendChild(messageMeta);

  // 3. MESSAGE Column
  const colMessage = document.createElement("div");
  colMessage.className = "col-message message-content";

  // Handle Image content
  if (messageData.type === "Image") {
    if (
      messageData.imageData &&
      (messageData.imageData.dataUrl || messageData.imageData.blob)
    ) {
      // Valid image data
    } else {
      // Corrupted or missing data - fallback to text
      colMessage.innerHTML = `<div class="error-message">[IMAGE MISSING] ${messageData.imageData?.filename || messageData.message || "Unknown Image"}</div>`;
      logRow.appendChild(colMessage);
      logOutput.appendChild(logRow);
      return;
    }
  }

  if (messageData.attachment) {
    colMessage.appendChild(renderChatAttachment(messageData.attachment));
  } else if (messageData.type === "Image" && messageData.imageData) {
    const imageElement = document.createElement("img");
    imageElement.src = messageData.imageData.dataUrl;
    imageElement.alt = messageData.imageData.filename;
    imageElement.className = "chat-image";
    imageElement.title = `${messageData.imageData.filename} (${messageData.imageData.mimeType})`;

    colMessage.appendChild(imageElement);

    // Add modal handler
    if (window.addImageModalHandler) {
      window.addImageModalHandler(imageElement);
    }
  } else if (messageData.type === "Message" || messageData.type === "Sent") {
    // Parse markdown first (converts to HTML)
    const htmlContent = parseMarkdown(messageData.message);
    colMessage.innerHTML = htmlContent;

    const taskRefRoomId = messageData.aiContextRoomId ?? messageData.roomId;

    // Then process task references in the parsed HTML
    // This must happen AFTER innerHTML to process the actual DOM
    if (window.NRCTaskReferences) {
      window.NRCTaskReferences.processMessageTaskReferences(
        colMessage,
        taskRefRoomId,
      );
    }

    if (window.NRCAI?.processAssetReferences) {
      window.NRCAI.processAssetReferences(
        colMessage,
        messageData.aiSources || [],
        messageData.aiContextRoomId ?? messageData.roomId,
      );
    }

    if (
      messageData.aiActionPlan &&
      window.NRCAI?.renderActionPlan &&
      !colMessage.querySelector(".ai-action-plan")
    ) {
      window.NRCAI.renderActionPlan(colMessage, messageData.aiActionPlan);
    }
    if (isAiAnswerMessage(messageData) && window.NRCAI?.renderResponseActions) {
      window.NRCAI.renderResponseActions(colMessage, messageData);
    }
  } else if (messageData.type === "Activity") {
    // Activity messages: plain text but with task reference processing
    colMessage.textContent = messageData.message;

    // Process task references in activity messages
    if (window.NRCTaskReferences) {
      window.NRCTaskReferences.processMessageTaskReferences(
        colMessage,
        messageData.roomId,
      );
    }
  } else if (messageData.type === "CommandResult" || messageData.type === "System") {
    // Command results and system log entries preserve newlines for multi-line output.
    colMessage.style.whiteSpace = "pre-wrap";
    colMessage.textContent = messageData.message;
  } else {
    colMessage.textContent = messageData.message;
  }

  window.NRCChat.decorate(logRow, messageData);
  logRow.appendChild(colMessage);

  let appendTarget = logOutput;
  if (messageData.aiRunId) {
    appendTarget = getAiRunContainer(logOutput, messageData.aiRunId, true);
  }
  appendTarget.appendChild(logRow);
  if (isAiAnswerMessage(messageData)) completeOpenAiRun(messageData.aiRunId, "complete");
  updateLedgerQuery(messageData);
  updateLedgerAnswer(messageData);

  if (followChat) logOutput.scrollTop = logOutput.scrollHeight;

  // Keep only the last 150 messages in DOM for performance
  trimOldMessages();

  // Update chat header stats
  updateChatStats();
}

// =============================================================================
// MESSAGE DISPLAY & LOGGING
// =============================================================================

function loadRoomHistory(roomId, options = {}) {
  if (systemLogVisible) {
    if (systemLogFollowing) renderSystemLog();
    return;
  }

  window.NRCChat.beginHistory(roomId);
  const logOutput = document.getElementById("logOutput");
  // Clear current chat
  logOutput.innerHTML = "";
  resetLedgerContext();

  // Load history for this room
  const contextID = options.aiContextRoomId == null ? null : String(options.aiContextRoomId);
  const history = (roomHistory.get(roomId) || []).filter(
    (message) => contextID == null || String(message.aiContextRoomId) === contextID,
  );
  for (const messageData of window.NRCChat.filterHistory(history)) {
    displayMessage(messageData);
  }
  window.NRCChat.endHistory();

  if ((isAIDMConversation(roomId) || contextID != null) && history.length === 0) {
    window.NRCAI?.renderEmptyState?.();
  }

  // Update chat header stats after loading history
  updateChatStats();
}

// =============================================================================
// STATUS & METRICS DISPLAY
// =============================================================================

function updateConnectionStatus(connected) {
  const connectionStatus = document.getElementById("connectionStatus");
  const latency = document.getElementById("currentLatency");
  const latencyMetric = latency?.closest(".status-footer-metric--latency");
  const rxRate = document.getElementById("statsRxRate");
  const txRate = document.getElementById("statsTxRate");

  if (connected) {
    connectionStatus.classList.add("connected");
    connectionStatus.textContent = "ONLINE";
  } else {
    connectionStatus.classList.remove("connected");
    connectionStatus.textContent = "OFFLINE";
  }

  if (latency) latency.textContent = "—";
  latencyMetric?.classList.remove("degraded", "critical");
  if (rxRate) rxRate.textContent = connected ? "0 B/s" : "—";
  if (txRate) txRate.textContent = connected ? "0 B/s" : "—";
}

// =============================================================================
// USER INPUT & COMMAND PROCESSING
// =============================================================================

function showCommandHelp() {
  const groups = new Map();
  for (const command of COMMANDS) {
    const group = command.group || "Other";
    if (!groups.has(group)) groups.set(group, []);
    groups.get(group).push(command);
  }

  const lines = ["AVAILABLE PALETTE ACTIONS:", "---------------------------------------------------"];
  for (const group of GROUP_ORDER) {
    const commands = groups.get(group);
    if (!commands || commands.length === 0) continue;
    lines.push("", `${group.toUpperCase()}:`);
    for (const command of commands) {
      const arg = command.arg ? ` ${command.arg.toUpperCase()}` : "";
      lines.push(`${command.title}${arg} - ${command.desc}`);
    }
  }
  logMessage("CommandResult", lines.join("\n"));
}

function parseRoomIdentifier(value) {
  const room = (value || "").trim();
  if (!room) return null;
  if (/^\d+$/.test(room)) {
    try {
      return BigInt(room);
    } catch {
      return null;
    }
  }
  return room;
}

async function joinRoomFromPalette(room) {
  const roomId = parseRoomIdentifier(room);
  if (roomId === null) {
    logMessage("Error", "Room name or ID required");
    return;
  }
  await joinRoom(roomId);
}

function leaveRoomFromPalette(room) {
  const roomId = parseRoomIdentifier(room);
  if (roomId === null) {
    if (currentRoomId) {
      leaveRoom(currentRoomId);
    } else {
      logMessage("Error", "No current room to leave");
    }
    return;
  }
  leaveRoom(roomId);
}

function findSubscribedRoom(room) {
  if (!room) return null;
  if (room.toUpperCase() === "SYSTEM") return SYSTEM_ROOM_ID;

  for (const [id, name] of roomNames.entries()) {
    if (name.toLowerCase() === room.toLowerCase()) return id;
  }

  const roomIdMatch = room.toUpperCase().match(/^ROOM-(\d+)$/);
  if (roomIdMatch) {
    const extractedId = BigInt(roomIdMatch[1]);
    if (subscribedRooms.has(extractedId)) return extractedId;
  }

  if (/^\d+$/.test(room)) {
    try {
      return BigInt(room);
    } catch {
      return null;
    }
  }

  return null;
}

function switchRoomFromPalette(room) {
  const targetRoomId = findSubscribedRoom((room || "").trim());
  if (targetRoomId === SYSTEM_ROOM_ID) {
    showSystemLog();
    return;
  }
  if (targetRoomId && subscribedRooms.has(targetRoomId)) {
    switchToRoom(targetRoomId);
  } else {
    logMessage("Error", `Room ${room || ""} not found or not joined.`);
  }
}

function switchWorkspaceFromPalette(workspaceId) {
  const id = (workspaceId || "").trim();
  if (!id) {
    logMessage("CommandResult", `Current workspace: ${currentWorkspaceId}`);
    return;
  }
  switchToWorkspace(id);
}

function createTaskFromPalette(title) {
  if (!window.NRCTasks?.createTaskFromPalette) {
    logMessage("Error", "TASKS MODULE NOT LOADED");
    return;
  }
  window.NRCTasks.createTaskFromPalette(title);
}

function markTaskDoneFromPalette(taskId) {
  if (!window.NRCTasks?.markTaskDoneFromPalette) {
    logMessage("Error", "TASKS MODULE NOT LOADED");
    return;
  }
  window.NRCTasks.markTaskDoneFromPalette(taskId);
}

function deleteTaskFromPalette(taskId) {
  if (!window.NRCTasks?.deleteTaskFromPalette) {
    logMessage("Error", "TASKS MODULE NOT LOADED");
    return;
  }
  window.NRCTasks.deleteTaskFromPalette(taskId);
}

function refreshTasksFromPalette() {
  if (!window.NRCTasks?.refreshTasksFromPalette) {
    logMessage("Error", "TASKS MODULE NOT LOADED");
    return;
  }
  window.NRCTasks.refreshTasksFromPalette();
}

function createNoteFromPalette(text) {
  if (!window.NRCNotes?.handleNoteCommand) {
    logMessage("Error", "NOTES MODULE NOT LOADED");
    return;
  }
  window.NRCNotes.handleNoteCommand([(text || "").trim()]);
}

function setTaskAssigneeFilterFromPalette(value) {
  if (!window.NRCTasks?.setAssigneeFilterFromPalette) {
    logMessage("Error", "TASKS MODULE NOT LOADED");
    return;
  }
  window.NRCTasks.setAssigneeFilterFromPalette(value);
  const label = (value || "").trim() || "ALL";
  logSystem(`FILTER ASSIGNEE: ${label}`, "tasks");
}

function startDMFromPalette(username) {
  const user = (username || "").trim();
  if (!user) {
    logMessage("Error", "Username required");
    return;
  }
  sendStartDM(user);
}

function aiTaskFromTextFromPalette(text) {
  const rawText = (text || "").trim();
  if (!window.NRCAI?.handlePasteToTask) {
    logMessage("Error", "AI MODULE NOT LOADED");
    return;
  }
  if (!rawText) {
    logMessage("Error", "Text required");
    return;
  }
  window.NRCAI.handlePasteToTask(rawText);
}

function aiNoteFromTextFromPalette(text) {
  const noteText = (text || "").trim();
  if (!window.NRCAI?.handlePasteToNote) {
    logMessage("Error", "AI MODULE NOT LOADED");
    return;
  }
  if (!noteText) {
    logMessage("Error", "Text required");
    return;
  }
  window.NRCAI.handlePasteToNote(noteText);
}

function askSullivanFromPalette(input) {
  if (!window.NRCAI?.handleAsk) {
    logMessage("Error", "AI MODULE NOT LOADED");
    return;
  }

  const askArgs = (input || "").trim().split(/\s+/).filter(Boolean);
  let forceRoom = false;
  for (let i = 0; i < askArgs.length;) {
    const arg = askArgs[i].toLowerCase();
    if (arg === "--room") {
      forceRoom = true;
      askArgs.splice(i, 1);
      continue;
    }
    if (arg === "--plan") {
      askArgs.splice(i, 1);
      continue;
    }
    i++;
  }

  if (askArgs.length === 1 && askArgs[0].toLowerCase() === "reset") {
    if (window.NRCAI.resetAskSession()) {
      logSystem("SULLIVAN SESSION RESET", "ai");
    } else {
      logMessage("Error", "AI ACTION PLAN APPLY IS IN PROGRESS");
    }
    return;
  }

  const question = askArgs.join(" ");
  if (!question) {
    logMessage("Error", "Question required");
    return;
  }
  window.NRCAI.handleAsk(question, { forceRoom });
}

// =============================================================================
// EVENT LISTENERS
// =============================================================================

window.NRCChat.init();

imageInput.addEventListener("change", (event) => {
  for (const file of event.target.files) sendChatAttachment(file);
  event.target.value = "";
});

document.getElementById("chatAttach")?.addEventListener("click", () => imageInput.click());

document.getElementById("chatSend")?.addEventListener("click", () => {
  sendBinaryMessage(messageInput.value);
});

messageInput.addEventListener("keydown", (event) => {
  // Handle autocomplete navigation first
  if (autocompleteState.isVisible) {
    switch (event.key) {
      case "ArrowUp":
        event.preventDefault();
        moveHighlight("up");
        return;
      case "ArrowDown":
        event.preventDefault();
        moveHighlight("down");
        return;
      case "Tab":
      case "Enter":
        if (!event.shiftKey && autocompleteState.suggestions.length) {
          event.preventDefault();
          acceptSuggestion();
          return;
        }
        if (!event.shiftKey) hideAutocomplete();
        break;
      case "Escape":
        event.preventDefault();
        hideAutocomplete();
        return;
    }
  }

  // Original Enter key handling - only if autocomplete is not visible
  if (
    event.key === "Enter" &&
    !event.shiftKey &&
    !event.isComposing &&
    !(matchMedia("(pointer: coarse)").matches && !event.ctrlKey && !event.metaKey) &&
    !autocompleteState.isVisible
  ) {
    event.preventDefault();
    sendBinaryMessage(messageInput.value);
  }
});

// Auto-resize textarea based on content and handle autocomplete
messageInput.addEventListener("input", () => {
  // Handle autocomplete
  handleAutocompleteInput();
  // Toggle cursor visibility based on content
  const container = messageInput.closest(".input-container");
  if (container) {
    container.classList.toggle("has-content", messageInput.value.length > 0);
  }
  updateMessageByteCount();
});

// Handle key up events for autocomplete (for cursor movement without content change)
messageInput.addEventListener("keyup", (event) => {
  // Only update autocomplete for cursor movement keys when visible
  if (
    autocompleteState.isVisible &&
    ["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)
  ) {
    handleAutocompleteInput();
  }
});

// Hide autocomplete when textarea loses focus (unless clicking on dropdown)
messageInput.addEventListener("blur", (event) => {
  // Delay hiding to allow for dropdown clicks
  setTimeout(() => {
    if (
      autocompleteState.isVisible &&
      document.activeElement !== messageInput &&
      !autocompleteState.dropdownElement?.contains(document.activeElement)
    ) {
      hideAutocomplete();
    }
  }, 150);
});

// Prevent default behavior on message input when autocomplete interferes
messageInput.addEventListener("keypress", (event) => {
  // Prevent form submission on Enter when autocomplete is visible
  if (event.key === "Enter" && autocompleteState.isVisible && !event.shiftKey) {
    event.preventDefault();
  }
});

// =============================================================================
// VOICE & SCREEN SHARE HEADER BUTTONS
// =============================================================================

document.getElementById("sullivanBtn").addEventListener("click", () => {
  const view = window.NRCViewManager?.getActiveView?.();
  if (view === "sullivan" || view === "sullivanShare") return;
  window.NRCAI?.openSullivan?.();
});

document.getElementById("systemLogBtn").addEventListener("click", () => {
  if (systemLogVisible) {
    exitSystemLog();
  } else {
    showSystemLog();
  }
});

document.getElementById("tasksBtn").addEventListener("click", () => {
  if (window.NRCTasks) {
    window.NRCTasks.toggleKanban();
  }
});

document.getElementById("remindersBtn").addEventListener("click", () => {
  if (window.NRCTasks) {
    window.NRCTasks.toggleReminders();
  }
});

document.getElementById("attentionBtn").addEventListener("click", () => {
  const view = window.NRCViewManager?.getActiveView?.();
  window.NRCViewManager?.setActiveView?.(view === "attention" ? "chat" : "attention");
});

document.getElementById("calendarBtn").addEventListener("click", () => {
  window.NRCViewManager?.setActiveView("calendar");
});

document.getElementById("notesBtn").addEventListener("click", () => {
  if (window.NRCNotes) {
    window.NRCNotes.toggleNotesView();
  }
});

function updateHeaderButtons() {
  const sullivanBtn = document.getElementById("sullivanBtn");
  const remindersBtn = document.getElementById("remindersBtn");
  const tasksBtn = document.getElementById("tasksBtn");
  const notesBtn = document.getElementById("notesBtn");
  const systemLogBtn = document.getElementById("systemLogBtn");
  const attentionBtn = document.getElementById("attentionBtn");

  const view = window.NRCViewManager ? window.NRCViewManager.getActiveView() : "chat";
  if (attentionBtn) attentionBtn.classList.toggle("active", view === "attention");
  document.getElementById("calendarBtn")?.classList.toggle("active", view === "calendar");
  document.getElementById("customersBtn")?.classList.toggle("active", view === "customers");

  if (sullivanBtn) {
    sullivanBtn.classList.toggle("active", view === "sullivan" || view === "sullivanShare");
  }

  if (remindersBtn) {
    remindersBtn.classList.toggle("active", view === "reminders");
  }

  if (tasksBtn) {
    tasksBtn.classList.toggle("active", view === "kanban");
  }

  if (notesBtn) {
    notesBtn.classList.toggle("active", view === "notes" || view === "noteShare");
  }

  if (systemLogBtn) {
    systemLogBtn.classList.toggle("active", view === "systemLog");
  }
}

// =============================================================================
// CLIPBOARD FILE PASTE FUNCTIONALITY
// =============================================================================

// Share clipboard files through the same upload path as the file picker.
document.addEventListener("paste", (event) => {
  // Only handle paste events when message input is focused
  if (document.activeElement !== messageInput) {
    return;
  }

  const clipboardData =
    event.clipboardData || event.originalEvent.clipboardData;
  if (!clipboardData || !clipboardData.items) {
    return;
  }

  // Text-only paste keeps the browser's normal behavior.
  for (let i = 0; i < clipboardData.items.length; i++) {
    const item = clipboardData.items[i];

    if (item.kind === "file") {
      event.preventDefault(); // Prevent default paste behavior

      const file = item.getAsFile();
      if (!file) continue;
      sendChatAttachment(file);
    }
  }
});

// =============================================================================
// PANEL RESIZING
// =============================================================================

function initAgendaPanelResize() {
  const agendaPanel = document.querySelector(".agenda-panel");
  const resizeHandle = document.querySelector(".agenda-resize-handle");
  if (!agendaPanel || !resizeHandle) return;
  const storageKey = "nrc.inspector.width";
  const defaultWidth = 440;
  const savedWidth = () => {
    const width = Number(localStorage.getItem(storageKey));
    return Number.isFinite(width) && width > 0 ? width : defaultWidth;
  };
  const clamp = (width) => {
    // The CSS cap is 64rem; a record that carries a document needs the room, so
    // the drag may reach it within the window share below.
    const ceiling = Math.min(64 * parseFloat(getComputedStyle(document.documentElement).fontSize), window.innerWidth * 0.6);
    return Math.max(360, Math.min(Number.isFinite(width) ? width : defaultWidth, ceiling));
  };
  const applyWidth = (width, persist = false) => {
    if (window.matchMedia("(max-width: 1199px)").matches) {
      agendaPanel.style.removeProperty("width");
      return;
    }
    const clamped = clamp(width);
    agendaPanel.style.width = `${clamped}px`;
    if (persist) localStorage.setItem(storageKey, String(clamped));
  };
  applyWidth(savedWidth());
  let isResizing = false;
  let resizePointerId = null;
  let startX = 0;
  let startWidth = 0;

  resizeHandle.addEventListener("pointerdown", (e) => {
    if (!e.isPrimary || e.button !== 0 || isResizing || window.matchMedia("(max-width: 1199px)").matches) return;
    isResizing = true;
    resizePointerId = e.pointerId;
    startX = e.clientX;
    startWidth = parseInt(
      document.defaultView.getComputedStyle(agendaPanel).width,
      10,
    );
    resizeHandle.setPointerCapture(e.pointerId);
    resizeHandle.addEventListener("pointermove", doResize);
    resizeHandle.addEventListener("pointerup", stopResize);
    resizeHandle.addEventListener("pointercancel", stopResize);
    resizeHandle.addEventListener("lostpointercapture", stopResize);
    document.body.style.cursor = "col-resize";
  });

  function doResize(e) {
    if (!isResizing || e.pointerId !== resizePointerId) return;
    const diff = startX - e.clientX; // Reversed because we're resizing from left edge
    applyWidth(startWidth + diff);
  }

  function stopResize(e) {
    if (!isResizing || e.pointerId !== resizePointerId) return;
    isResizing = false;
    resizePointerId = null;
    resizeHandle.removeEventListener("pointermove", doResize);
    resizeHandle.removeEventListener("pointerup", stopResize);
    resizeHandle.removeEventListener("pointercancel", stopResize);
    resizeHandle.removeEventListener("lostpointercapture", stopResize);
    document.body.style.cursor = "default";

    applyWidth(parseFloat(agendaPanel.style.width), true);
  }
  resizeHandle.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    applyWidth(parseFloat(getComputedStyle(agendaPanel).width) + (event.key === "ArrowLeft" ? 16 : -16), true);
  });
  resizeHandle.addEventListener("dblclick", () => {
    localStorage.removeItem(storageKey);
    applyWidth(defaultWidth);
  });
  window.addEventListener("resize", () => applyWidth(savedWidth()));
}

// =============================================================================
// PING/PONG LATENCY MEASUREMENT
// =============================================================================

function sendPing() {
  if (!serverReady || !ws || ws.readyState !== WebSocket.OPEN) {
    return;
  }

  const beforeCreateTime = performance.now();
  const sendTime = Date.now();
  const timestamp = BigInt(sendTime) * 1000000n; // Convert to nanoseconds
  const buffer = new ArrayBuffer(2 + 8); // opcode + timestamp
  const dataView = new DataView(buffer);

  // Write opcode
  dataView.setUint16(0, Opcode.C_Ping, false); // Big Endian

  // Write timestamp
  dataView.setBigUint64(2, timestamp, false); // Big Endian

  const beforeSendTime = performance.now();

  // Store the timestamp for latency calculation, plus metadata
  pendingPings.set(Number(timestamp), {
    sentAt: sendTime,
    beforeCreateTime,
    beforeSendTime,
    sentPacketTime: null,
  });

  sendPacket(buffer);
  const afterSendTime = performance.now();
  pendingPings.get(Number(timestamp)).sentPacketTime = afterSendTime;
}

function parsePongResponse(dataView) {
  // S_Pong payload: timestamp(8) + server_timestamp(8)
  let offset = 2; // Skip opcode

  if (dataView.byteLength < offset + 16) {
    logMessage("Error", "⚠ PAYLOAD CORRUPTION - S_Pong too short");
    return;
  }

  const pongReceivedAt = performance.now(); // High-resolution timestamp
  const now = Date.now();

  const timestamp = dataView.getBigUint64(offset, false);
  offset += 8;
  const serverTimestamp = dataView.getBigUint64(offset, false);
  offset += 8;

  // Find matching ping timestamp
  const pingData = pendingPings.get(Number(timestamp));
  if (pingData !== undefined) {
    const rtt = now - pingData.sentAt;

    // Log large latencies with detailed breakdown
    if (rtt > 100) {
      const bufferCreateTime =
        pingData.beforeSendTime - pingData.beforeCreateTime;
      const sendTime = pingData.sentPacketTime - pingData.beforeSendTime;
      const totalSendTime = pingData.sentPacketTime - pingData.beforeCreateTime;

      console.warn(`[LATENCY SPIKE] RTT=${rtt}ms`);
      console.warn(
        `  └─ Send side: buffer=${bufferCreateTime.toFixed(2)}ms, send=${sendTime.toFixed(2)}ms, total=${totalSendTime.toFixed(2)}ms`,
      );
      console.warn(
        `  └─ Pong received at: ${pongReceivedAt.toFixed(2)}ms (perf time)`,
      );
      console.warn(
        `  └─ timestamp=${Number(timestamp)}, sent=${pingData.sentAt}`,
      );
    }

    updateLatency(rtt);
    pendingPings.delete(Number(timestamp));

    // Calculate skew: server_ts - (client_send + rtt/2)
    // serverTimestamp is in nanos, convert to millis
    const serverTimeMs = Number(serverTimestamp) / 1000000;
    serverClientSkew = Math.round(serverTimeMs - (pingData.sentAt + rtt / 2));
  }
}

function updateLatency(latencyMs) {
  // Offload calculations to Web Worker
  if (latencyWorker) {
    latencyWorker.postMessage({ type: "addLatency", data: { latencyMs } });
  } else {
    // Fallback: update stats directly and schedule UI update
    latencyStats.current = latencyMs;
    scheduleStatsUpdate();
  }
}

function updateJitterDisplay() {
  const jitterElement = document.getElementById("statsJitter");
  if (jitterElement && latencyStats.jitterAvg > 0) {
    jitterElement.textContent = `±${latencyStats.jitterAvg}ms (RFC 3550)`;
  }
}

function updateLatencyDisplay() {
  const latencyElement = document.getElementById("currentLatency");
  if (latencyElement && latencyStats.current > 0) {
    latencyElement.textContent = `${latencyStats.current}ms`;
    const metric = latencyElement.closest(".status-footer-metric--latency");
    metric?.classList.toggle(
      "degraded",
      latencyStats.current > 100 && latencyStats.current <= 250,
    );
    metric?.classList.toggle("critical", latencyStats.current > 250);
    metric?.setAttribute(
      "title",
      `Current WebSocket round-trip time; p95 ${latencyStats.p95}ms; jitter ${latencyStats.jitterAvg}ms`,
    );
  }
}

function startPingInterval() {
  // Initialize latency worker
  initLatencyWorker();

  // Send ping every 5 seconds
  if (pingInterval) {
    clearInterval(pingInterval);
  }

  let lastPingScheduledTime = Date.now();
  pingInterval = setInterval(() => {
    const now = Date.now();
    const expectedInterval = 5000;
    const actualInterval = now - lastPingScheduledTime;
    const jitterInMs = actualInterval - expectedInterval;

    // Log if ping interval is delayed (event loop blocking)
    if (jitterInMs > 50) {
      console.warn(
        `[PING INTERVAL DELAY] Expected 5000ms, got ${actualInterval}ms (jitter: +${jitterInMs}ms)`,
      );
    }

    lastPingScheduledTime = now;
    sendPing();
  }, 5000);

  // Send initial ping
  sendPing();
}

function stopPingInterval() {
  if (pingInterval) {
    clearInterval(pingInterval);
    pingInterval = null;
  }
  pendingPings.clear();
  terminateLatencyWorker();
}

// =============================================================================
// MANUAL RECONNECTION CONTROL
// =============================================================================

function manualReconnect() {
  logMessage("CommandResult", ">> MANUAL RECONNECTION REQUESTED");

  // Reset reconnection state
  resetReconnection();

  // Close existing connection if any
  if (ws && ws.readyState !== WebSocket.CLOSED) {
    ws.close();
  }

  // Wait a bit then reconnect
  setTimeout(() => {
    connectWebSocket();
  }, 500);
}

window.NRCRooms = {
  handleRoomMappingAsset,
  handleRoomMappingDeleted,
  normalizeRoomName,
};

function parseNoteShareRouteFromHash() {
  const hash = window.location.hash || "";
  const match = hash.match(/^#\/note\/([^/]+)\/(?:([0-9]+)\/)?([0-9]+)$/);
  if (!match) return null;

  try {
    return {
      workspaceId: decodeURIComponent(match[1]),
      convId: 0n,
      assetId: BigInt(match[3]),
    };
  } catch (e) {
    console.warn("Invalid note share route", e);
    return null;
  }
}

function parseSullivanShareRouteFromHash() {
  const hash = window.location.hash || "";
  const match = hash.match(/^#\/sullivan\/([^/]+)(?:\/([0-9]+))?$/);
  if (!match) return null;

  try {
    return {
      workspaceId: decodeURIComponent(match[1]),
      contextConvId: 0n,
    };
  } catch (e) {
    console.warn("Invalid Sullivan share route", e);
    return null;
  }
}

const initialNoteShareRoute = parseNoteShareRouteFromHash();
const initialSullivanShareRoute = parseSullivanShareRouteFromHash();

function handleShareHashChange() {
  const noteRoute = parseNoteShareRouteFromHash();
  const sullivanRoute = parseSullivanShareRouteFromHash();
  if (!sullivanRoute) {
    window.NRCAI?.cancelSullivanOpen?.();
  }
  if (noteRoute) {
    if (noteRoute.workspaceId !== currentWorkspaceId) {
      window.location.reload();
      return;
    }

    if (window.NRCNotes?.showSharedNoteView) {
      window.NRCNotes.showSharedNoteView(noteRoute);
    }
    if (serverReady && window.NRCNotes?.loadSharedNoteView) {
      window.NRCNotes.loadSharedNoteView(noteRoute);
    }
    return;
  }

  if (sullivanRoute) {
    if (sullivanRoute.workspaceId !== currentWorkspaceId) {
      window.location.reload();
      return;
    }

    if (serverReady && window.NRCAI?.openSullivanWithContext) {
      window.NRCAI.openSullivanWithContext(sullivanRoute.contextConvId, { focused: true });
    }
    return;
  }

  if (window.NRCViewManager?.getActiveView?.() === "noteShare") {
    if (window.NRCNotes?.showNotesView) {
      window.NRCNotes.showNotesView();
    } else {
      window.NRCViewManager.setActiveView("chat");
    }
  }

  if (window.NRCViewManager?.getActiveView?.() === "sullivanShare") {
    window.NRCViewManager.setActiveView("chat");
  }
}

window.addEventListener("hashchange", handleShareHashChange);

// =============================================================================
// APPLICATION INITIALIZATION
// =============================================================================

// Initialize IndexedDB and then load app data
(async function initApp() {
  // Capture before asynchronous initialization lets view modules save defaults.
  const savedUIState = loadUIState();
  // Load workspace from URL (or default)
  const initialShareRoute = initialNoteShareRoute || initialSullivanShareRoute;
  currentWorkspaceId = initialShareRoute?.workspaceId || await loadWorkspaceFromStorage();
  logSystem(`INITIALIZED WORKSPACE ${currentWorkspaceId}`, "workspace");

  // Set up default room data
  currentRoomId = DEFAULT_ROOM_ID;
  let initialRoomId = DEFAULT_ROOM_ID;

  // Auto-join all predefined rooms, then restore rooms explicitly joined by the user.
  DEFAULT_ROOMS.forEach(({ id: roomId, name }) => {
    subscribedRooms.add(roomId);
    roomNames.set(roomId, name);

    // Initialize history for this room if not exists
    if (!roomHistory.has(roomId)) {
      roomHistory.set(roomId, []);
    }
  });
  await loadRoomsFromStorage();

  // Restore UI state from localStorage (but don't set currentRoomId yet)
  if (savedUIState) {
    if (savedUIState.roomId && subscribedRooms.has(savedUIState.roomId)) {
      initialRoomId = savedUIState.roomId;
    }
  }

  logMessage(
    "System",
    `>> INITIALIZED DEFAULT ROOM DATA FOR WORKSPACE: ${currentWorkspaceId}`,
  );

  // Initialize the current room view
  switchToRoom(initialRoomId);
  window.NRCChat.syncComposer();

  // No history loading

  updateAgendaDisplay(); // Initialize agenda display
  updateNotificationStatus(); // Initialize notification status display
  initTheme(); // Initialize color theme
  initAgendaPanelResize(); // Initialize panel resizing
  initImageModal(); // Initialize image modal functionality
  initKanban(); // Initialize kanban board
  window.NRCAttention?.init?.(); // Attention register
  window.NRCCalendar?.init();
  window.NRCReminderNotify?.init?.(); // Reminder deadline timer and NOTIFY switch
  window.NRCAppointmentNotify?.init();
  initDMUserPicker(); // Initialize DM user picker
  updateDMListUI(); // Initialize DM list display

  // Restore mode after view modules are initialized
  if (initialNoteShareRoute && window.NRCNotes) {
    window.NRCNotes.showSharedNoteView(initialNoteShareRoute);
  } else if (initialSullivanShareRoute && window.NRCViewManager) {
    window.NRCViewManager.setActiveView("sullivanShare");
  } else if (savedUIState) {
    if (savedUIState.mode === "task" && window.NRCTasks) {
      window.NRCTasks.showKanban();
    } else if (savedUIState.mode === "reminders" && window.NRCTasks) {
      window.NRCTasks.showReminders();
    } else if (savedUIState.mode === "notes" && window.NRCNotes) {
      window.NRCNotes.showNotesView();
    } else if (savedUIState.mode === "systemLog") {
      showSystemLog();
    } else if (savedUIState.mode === "attention") {
      window.NRCViewManager.setActiveView("attention");
    } else if (savedUIState.mode === "calendar") {
      window.NRCViewManager.setActiveView("calendar");
    }
  }

  // Start the connection
  await connectWebSocket();
})();

function initKanban() {
  if (window.NRCTasks) {
    window.NRCTasks.initTasks();
    window.NRCTasks.initFilterState();
  }
  if (window.NRCNotes) {
    window.NRCNotes.initNotes();
  }
  document.getElementById("createTaskHeaderBtn")?.addEventListener("click", promptNewTask);
  document.getElementById("createNoteHeaderBtn")?.addEventListener("click", promptNewNote);
}

// =============================================================================
// IMAGE MODAL FUNCTIONALITY
// =============================================================================

function initImageModal() {
  const modal = document.getElementById("imageModal");
  const modalImage = document.getElementById("imageModalImage");
  const modalTitle = document.getElementById("imageModalTitle");
  const closeBtn = document.getElementById("imageModalClose");
  const backdrop = document.querySelector(".image-modal-backdrop");
  let previousFocus = null;
  let previousBodyOverflow = "";

  // Function to open modal with image
  function openImageModal(imageSrc, imageAlt, imageTitle) {
    previousFocus = document.activeElement;
    previousBodyOverflow = document.body.style.overflow;
    modalImage.src = imageSrc;
    modalImage.alt = imageAlt;
    modalTitle.textContent = String(imageTitle || imageAlt || "IMAGE").toUpperCase();
    modal.classList.add("show");
    modal.setAttribute("aria-hidden", "false");
    document.body.style.overflow = "hidden"; // Prevent background scrolling
    closeBtn.focus();
  }

  // Function to close modal
  function closeImageModal() {
    modal.classList.remove("show");
    modal.setAttribute("aria-hidden", "true");
    document.body.style.overflow = previousBodyOverflow;
    previousFocus?.focus?.();
    previousFocus = null;
    // Clear image src to free memory
    setTimeout(() => {
      if (!modal.classList.contains("show")) {
        modalImage.src = "";
      }
    }, 200);
  }

  // Close button click handler
  closeBtn.addEventListener("click", closeImageModal);

  // Backdrop click handler
  backdrop.addEventListener("click", closeImageModal);

  // ESC key handler
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && modal.classList.contains("show")) {
      closeImageModal();
    }
  });

  function openRenderedImage(event) {
    const image = event.target.closest?.("img.chat-image, img.markdown-image");
    if (!image) return;
    event.preventDefault();
    openImageModal(image.currentSrc || image.src, image.alt, image.title || image.alt || "IMAGE");
  }

  // Markdown appears in chat, tasks, notes, and shared views. Delegating once
  // keeps dynamically rendered images zoomable without per-view handlers.
  document.addEventListener("click", openRenderedImage);
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    if (!event.target.matches?.("img.markdown-image")) return;
    openRenderedImage(event);
  });

  // Keep global handler for compatibility (but it's now a no-op since delegation handles it)
  window.addImageModalHandler = function (imageElement) {
    // No-op: event delegation handles all chat-image clicks
  };

  // Expose openImageModal globally for attachments
  window.openImageModal = openImageModal;
}
// connectWebSocket(); - Moved to initApp

// =============================================================================
// COMMAND PALETTE
// =============================================================================

const CommandPalette = (() => {
  const overlay = document.getElementById("commandPalette");
  const input = document.getElementById("paletteInput");
  const results = document.getElementById("paletteResults");
  const argBar = document.getElementById("paletteArgBar");
  const argField = document.getElementById("paletteArgField");
  const argSubmit = document.getElementById("paletteArgSubmit");

  let active = false;
  let selectedCommand = null;
  let highlightedIndex = -1;
  let filteredCommands = [];
  let argSuggestions = [];
  let selectedArgIndex = -1;

  function open() {
    if (active) { close(); return; }
    active = true;
    selectedCommand = null;
    highlightedIndex = -1;
    filteredCommands = [...COMMANDS];
    argSuggestions = [];
    selectedArgIndex = -1;
    input.value = "";
    hideArgInput();
    renderResults();
    overlay.classList.remove("hidden");
    input.focus();
  }

  function close() {
    if (!active) return;
    active = false;
    hideArgInput();
    overlay.classList.add("hidden");
    selectedCommand = null;
    filteredCommands = [];
    argSuggestions = [];
  }

  function isActive() {
    return active;
  }

  function hideArgInput() {
    argBar.classList.add("hidden");
    selectedCommand = null;
    argSuggestions = [];
    selectedArgIndex = -1;
  }

  function buildArgSuggestions(cmd) {
    if (!cmd.arg) return [];
    if (cmd.arg === "room") {
      const isSwitch = cmd.id === "rooms.switch";
      if (isSwitch) {
        return Array.from(subscribedRooms)
          .filter((id) => !isDMConversation(id))
          .map((id) => ({ label: getRoomName(id), value: getRoomName(id) }));
      }
      const allRooms = [];
      const seen = new Set();
      for (const id of subscribedRooms) {
        if (isDMConversation(id)) continue;
        const name = getRoomName(id);
        if (!seen.has(name)) { seen.add(name); allRooms.push({ label: name, value: name }); }
      }
      for (const name of roomNames.values()) {
        if (!seen.has(name)) { seen.add(name); allRooms.push({ label: name, value: name }); }
      }
      return allRooms;
    }
    if (cmd.arg === "workspace_id") {
      return recentWorkspaces.map((ws) => ({ label: ws, value: ws }));
    }
    if (cmd.arg === "username") {
      const presence = roomPresence.get(currentRoomId);
      if (presence) {
        return Array.from(presence.keys())
          .filter((u) => u !== myNickname)
          .map((u) => ({ label: u, value: u }));
      }
    }
    if (cmd.arg === "task_id") {
      const tasks = window.NRCTasks?.roomTasks?.get(0n);
      if (!tasks) return [];
      return Array.from(tasks.values())
        .filter((task) => task.status !== window.NRCTasks.TaskStatus.Done)
        .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
        .map((task) => ({
          label: `#${task.id} ${task.title}`,
          value: task.id.toString(),
        }));
    }
    if (cmd.arg === "assignee") {
      if (typeof populateAssigneeFilter === "function") {
        populateAssigneeFilter();
      }
      if (typeof getAssigneeFilterOptions === "function") {
        return getAssigneeFilterOptions().map((option) => ({
          label: option.label,
          value: option.value,
        }));
      }
      return [
        { label: "ALL", value: "" },
        { label: "MY TASKS", value: "me" },
      ];
    }
    if (cmd.arg === "theme") {
      return THEMES.map((theme) => ({ label: theme, value: theme }));
    }
    if (cmd.arg === "state") {
      return [
        { label: "ALL", value: "all" },
        { label: "OFF", value: "off" },
      ];
    }
    return [];
  }

  function filterArgSuggestions(query) {
    const q = query.toLowerCase().trim();
    if (!q) {
      selectedArgIndex = argSuggestions.length > 0 ? 0 : -1;
      return;
    }
    const filtered = argSuggestions.filter((s) => s.label.toLowerCase().includes(q));
    selectedArgIndex = filtered.length > 0 ? 0 : -1;
    return filtered;
  }

  function showArgInput(cmd) {
    selectedCommand = cmd;
    argSuggestions = buildArgSuggestions(cmd);
    selectedArgIndex = argSuggestions.length > 0 ? 0 : -1;
    argField.value = "";
    argField.placeholder = cmd.arg ? cmd.arg.toUpperCase() : "";
    argBar.classList.remove("hidden");
    renderResults();
    argField.focus();
  }

  function filterCommands(query) {
    const q = query.toLowerCase().trim();
    if (!q) {
      filteredCommands = [...COMMANDS];
      return;
    }
    filteredCommands = COMMANDS.filter((cmd) => {
      const title = cmd.title.toLowerCase();
      const id = cmd.id.toLowerCase();
      const desc = cmd.desc.toLowerCase();
      return (
        title.includes(q) ||
        id.includes(q) ||
        desc.includes(q) ||
        (cmd.keywords || []).some((keyword) => keyword.toLowerCase().includes(q))
      );
    });
  }

  function renderResults() {
    results.innerHTML = "";

    if (selectedCommand && argSuggestions.length > 0) {
      renderArgSuggestions();
      return;
    }

    if (filteredCommands.length === 0) {
      const empty = document.createElement("div");
      empty.className = "palette-results-empty";
      empty.textContent = "NO MATCHING COMMANDS";
      results.appendChild(empty);
      return;
    }

    // Group by category, preserving GROUP_ORDER
    const groups = {};
    for (const cmd of filteredCommands) {
      const group = cmd.group || "Other";
      if (!groups[group]) groups[group] = [];
      groups[group].push(cmd);
    }

    let idx = 0;

    for (const groupName of GROUP_ORDER) {
      const cmds = groups[groupName];
      if (!cmds || cmds.length === 0) continue;

      for (const cmd of cmds) {
        const optionIndex = idx;
        const opt = document.createElement("div");
        opt.className = "palette-option";
        if (optionIndex === highlightedIndex) opt.classList.add("highlighted");
        if (selectedCommand && selectedCommand.id === cmd.id) opt.classList.add("highlighted");
        opt.dataset.index = optionIndex;

        const groupSpan = document.createElement("span");
        groupSpan.className = "palette-option-group";
        groupSpan.textContent = groupName.toLowerCase();
        opt.appendChild(groupSpan);

        const cmdSpan = document.createElement("span");
        cmdSpan.className = "palette-option-cmd";
        cmdSpan.textContent = cmd.title;
        opt.appendChild(cmdSpan);

        const descSpan = document.createElement("span");
        descSpan.className = "palette-option-desc";
        descSpan.textContent = cmd.desc;
        opt.appendChild(descSpan);

        if (cmd.arg) {
          const argSpan = document.createElement("span");
          argSpan.className = "palette-option-arg";
          argSpan.textContent = cmd.arg;
          opt.appendChild(argSpan);
        }

        opt.addEventListener("click", (e) => {
          if (selectedCommand) return;
          const index = parseInt(e.currentTarget.dataset.index, 10);
          if (!isNaN(index)) acceptCommand(index);
        });

        opt.addEventListener("mousemove", () => {
          if (selectedCommand) return;
          if (highlightedIndex !== optionIndex) {
            const prev = results.querySelector(".palette-option.highlighted");
            if (prev) prev.classList.remove("highlighted");
            highlightedIndex = optionIndex;
            opt.classList.add("highlighted");
          }
        });

        results.appendChild(opt);
        idx++;
      }
    }

    // Scroll selected into view
    const highlighted = results.querySelector(".palette-option.highlighted");
    if (highlighted) {
      highlighted.scrollIntoView({ block: "nearest" });
    }
  }

  function renderArgSuggestions() {
    const header = document.createElement("div");
    header.className = "palette-group-header";
    header.textContent = "SUGGESTIONS";
    results.appendChild(header);

    const visible = argField.value.trim()
      ? argSuggestions.filter((s) => s.label.toLowerCase().includes(argField.value.toLowerCase().trim()))
      : argSuggestions;

    if (visible.length === 0) {
      const empty = document.createElement("div");
      empty.className = "palette-results-empty";
      empty.textContent = "NO MATCHING SUGGESTIONS";
      results.appendChild(empty);
      return;
    }

    for (let i = 0; i < visible.length; i++) {
      const opt = document.createElement("div");
      opt.className = "palette-option";
      if (i === selectedArgIndex) opt.classList.add("highlighted");
      opt.dataset.argIndex = i;

      const groupSpan = document.createElement("span");
      groupSpan.className = "palette-option-group";
      groupSpan.textContent = selectedCommand.group ? selectedCommand.group.toLowerCase() : "";
      opt.appendChild(groupSpan);

      const labelSpan = document.createElement("span");
      labelSpan.className = "palette-option-cmd";
      labelSpan.textContent = visible[i].label;
      opt.appendChild(labelSpan);

      const descSpan = document.createElement("span");
      descSpan.className = "palette-option-desc";
      descSpan.textContent = visible[i].value;
      opt.appendChild(descSpan);

      opt.addEventListener("click", () => {
        if (!selectedCommand) return;
        executeCommand(selectedCommand, visible[i].value);
        close();
      });

      opt.addEventListener("mousemove", () => {
        if (selectedArgIndex !== i) {
          const prev = results.querySelector(".palette-option.highlighted");
          if (prev) prev.classList.remove("highlighted");
          selectedArgIndex = i;
          opt.classList.add("highlighted");
        }
      });

      results.appendChild(opt);
    }
  }

  function moveHighlight(dir) {
    if (filteredCommands.length === 0) return;
    const prev = results.querySelector(".palette-option.highlighted");
    if (prev) prev.classList.remove("highlighted");

    highlightedIndex = (highlightedIndex + dir + filteredCommands.length) % filteredCommands.length;
    const next = results.querySelector(`.palette-option[data-index="${highlightedIndex}"]`);
    if (next) {
      next.classList.add("highlighted");
      next.scrollIntoView({ block: "nearest" });
    }
  }

  function acceptCommand(index) {
    const cmd = filteredCommands[index];
    if (!cmd) return;

    if (cmd.arg) {
      showArgInput(cmd);
      return;
    }

    executeCommand(cmd);
    close();
  }

  function executeCommand(cmd, arg) {
    Promise.resolve().then(() => cmd.execute(arg || "")).catch((err) => {
      console.error("Palette command failed:", err);
      logMessage("Error", "Command failed");
    });
  }

  // Palette input handlers
  input.addEventListener("input", () => {
    if (selectedCommand) {
      hideArgInput();
    }
    highlightedIndex = -1;
    filterCommands(input.value);
    if (filteredCommands.length > 0) highlightedIndex = 0;
    renderResults();
  });

  input.addEventListener("keydown", (e) => {
    if (selectedCommand) return;

    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        moveHighlight(1);
        break;
      case "ArrowUp":
        e.preventDefault();
        moveHighlight(-1);
        break;
      case "Enter":
        e.preventDefault();
        if (highlightedIndex >= 0 && highlightedIndex < filteredCommands.length) {
          acceptCommand(highlightedIndex);
        }
        break;
      case "Escape":
        e.preventDefault();
        close();
        break;
    }
  });

  function getVisibleArgSuggestions() {
    if (!selectedCommand || argSuggestions.length === 0) return [];
    const q = argField.value.toLowerCase().trim();
    return q ? argSuggestions.filter((s) => s.label.toLowerCase().includes(q)) : argSuggestions;
  }

  // Arg input handlers
  argField.addEventListener("input", () => {
    if (!selectedCommand || argSuggestions.length === 0) return;
    const visible = getVisibleArgSuggestions();
    selectedArgIndex = visible.length > 0 ? 0 : -1;
    renderResults();
  });

  argField.addEventListener("keydown", (e) => {
    const visible = getVisibleArgSuggestions();

    switch (e.key) {
      case "ArrowDown":
        if (visible.length > 0) {
          e.preventDefault();
          selectedArgIndex = Math.min(selectedArgIndex + 1, visible.length - 1);
          renderResults();
        }
        break;
      case "ArrowUp":
        if (visible.length > 0) {
          e.preventDefault();
          selectedArgIndex = Math.max(selectedArgIndex - 1, 0);
          renderResults();
        }
        break;
      case "Enter":
        e.preventDefault();
        if (selectedCommand) {
          if (visible.length > 0 && selectedArgIndex >= 0 && selectedArgIndex < visible.length) {
            executeCommand(selectedCommand, visible[selectedArgIndex].value);
          } else if (argField.value.trim()) {
            executeCommand(selectedCommand, argField.value.trim());
          } else {
            return;
          }
          close();
        }
        break;
      case "Escape":
        e.preventDefault();
        close();
        break;
    }
  });

  argSubmit.addEventListener("click", () => {
    if (selectedCommand && argField.value.trim()) {
      executeCommand(selectedCommand, argField.value.trim());
      close();
    }
  });

  // Close on backdrop click
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) close();
  });

  return { open, close, isActive };
})();

// =============================================================================
// KEYBOARD SHORTCUTS
// =============================================================================

function initKeyboardShortcuts() {
  document.addEventListener("keydown", handleGlobalKeydown);
}

function initHeaderControlFocus() {
  document.addEventListener("focusin", (event) => {
    const row = event.target.closest?.(".header-register-control-row, .inspector-mode-row");
    if (!row || row.scrollWidth <= row.clientWidth) return;
    event.target.scrollIntoView({ block: "nearest", inline: "nearest" });
  });
}

function handleGlobalKeydown(e) {
  const activeEl = document.activeElement;
  const isTyping =
    activeEl &&
    (activeEl.tagName === "INPUT" ||
      activeEl.tagName === "TEXTAREA" ||
      activeEl.isContentEditable);

  if (!e.ctrlKey && !e.altKey && !e.metaKey && handleSystemLogKeyboardNavigation(e)) {
    return;
  }

  // Esc always works - close modals/exit modes
  if (e.key === "Escape") {
    const imageModal = document.getElementById("imageModal");
    if (imageModal && imageModal.classList.contains("show")) {
      return; // Let image modal handle it
    }
    const taskModal = document.getElementById("taskModal");
    if (taskModal && taskModal.style.display !== "none") {
      return; // Let task modal handle it
    }
    if (window.NRCInspector?.hasEntity() || document.body.classList.contains("inspector-open")) {
      return; // The Inspector's dedicated handler owns its Back/Close semantics.
    }
    if (window.NRCTasks && kanbanVisible) {
      window.NRCTasks.hideKanban();
      e.preventDefault();
      return;
    }
  }

  // Ctrl shortcuts
  if (e.ctrlKey && !e.altKey) {
    switch (e.key.toLowerCase()) {
      case "p": // Command palette
        e.preventDefault();
        CommandPalette.open();
        return;

      case "j": // Chat mode: return to chat from any view
        e.preventDefault();
        if (window.NRCViewManager) {
          window.NRCViewManager.setActiveView("chat");
        }
        return;

      case ";": // Notes mode (US layout)
      case "ö": // Notes mode (German layout)
        e.preventDefault();
        if (window.NRCNotes) {
          window.NRCNotes.toggleNotesView();
        }
        return;

      case "k": // Tasks view: toggle between chat and tasks
      case "l":
        e.preventDefault();
        if (window.NRCTasks) {
          window.NRCTasks.toggleKanban();
        }
        return;

      case "shift":
        // Handled below with other modifiers
        return;
    }

  }

  // Alt shortcuts
  if (e.altKey && !e.ctrlKey && !e.metaKey) {
    switch (e.key.toLowerCase()) {
      case "n": // New card
        if (window.NRCTasks && kanbanVisible) {
          e.preventDefault();
          promptNewTask();
        }
        return;

      case "t": // Cycle color theme
        e.preventDefault();
        cycleTheme();
        return;

      case "/": // Focus input
        e.preventDefault();
        messageInput.focus();
        return;
    }
  }

  // Room switching with number keys (1-8) when not typing
  if (!window.NRCInspector?.hasEntity() && !isTyping && !e.ctrlKey && !e.altKey && !e.metaKey) {
    const num = parseInt(e.key, 10);
    if (num >= 1 && num <= 8) {
      const roomId = BigInt(num);
      if (subscribedRooms.has(roomId)) {
        switchToRoom(roomId);
      }
    }
  }
}

async function promptNewTask() {
  const title = await window.NRCDialog.prompt("Task title:", {
    title: "NEW TASK",
    placeholder: "Enter task title",
    submitLabel: "Create Task",
  });

  if (title) {
    sendCreateTask(0n, title, "", 128);
  }
}

async function promptNewNote() {
  const title = await window.NRCDialog.prompt("Note title:", {
    title: "NEW NOTE",
    placeholder: "Enter note title",
    submitLabel: "Create Note",
  });

  if (title) {
    window.NRCNotes.sendCreateNote(title, "");
    logSystem("NOTE CREATED", "notes");
  }
}

// Initialize shortcuts on load
initLedgerContext();
initKeyboardShortcuts();
initHeaderControlFocus();
