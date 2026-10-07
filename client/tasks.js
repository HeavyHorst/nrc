// =============================================================================
// NRC TASKS/KANBAN MODULE
// =============================================================================
// Handles task management with 4-column kanban board:
// BACKLOG | TODO | IN PROGRESS | DONE

const TaskStatus = {
  Backlog: 0,
  Todo: 1,
  InProgress: 2,
  Done: 3,
  Note: 4,
};

const TaskStatusNames = ["BACKLOG", "TODO", "IN PROGRESS", "DONE", "NOTE"];
const TaskStatusCodes = ["BL", "TD", "WP", "DN", "NT"];

const TaskColor = {
  None: 0,
  Cyan: 1,
  Red: 2,
  Green: 3,
  Gray: 4,
  Gold: 5,
};

const TaskColorNames = ["—", "ACTIVE", "BLOCKED", "READY", "DEFERRED", "TEST"];
const TaskColorNamesShort = ["—", "ACT", "BLK", "RDY", "DEF", "TST"];
const TaskColorCSS = ["none", "cyan", "red", "green", "gray", "gold"];

// Protocol limits (must match server protocol/types.odin)
const MAX_TASK_TITLE_LENGTH = 256;
const MAX_TASK_DESCRIPTION_LENGTH = 2048;
const MAX_ASSIGNEE_LENGTH = 32;
const MAX_EXTERNAL_REF_LENGTH = 512;
const MAX_PROJECT_LENGTH = 128;
const REMINDER_DEFAULT_URGENCY_DAYS = 3;

const ReminderState = {
  Late: "LATE",
  Urgent: "URGENT",
  Open: "OPEN",
  Locked: "LOCKED",
};

// Filter state
let myTasksOnly = false;
let taskDetailSaveGeneration = 0;
// Note: notesViewActive moved to notes.js

// Task detail panel state
let selectedTaskId = null; // Currently selected task ID (null when no task selected)
let selectedTaskConvId = null;
let taskListNavigationGeneration = 0;
let currentDetailTask = null; // The task currently being edited in the detail panel
// The messages block of the detail panel closes to one register line. The
// panel re-renders on every comment change, so its open state lives here and
// is handed back to the renderer.
let taskMessagesOpen = null; // Until toggled, open only when comments exist.
let taskComposerOpen = false;
let taskComposerDraft = "";
let taskMessagesController = null;
// Resource registers (files, links) collapse to one line each so the document
// keeps the panel. Read back from the live panel before every render.
let taskResourceOpen = {};
let pendingCommentFocusAssetId = null;
let selectedReminderAssetId = null;
let currentDetailReminder = null;
let reminderDetailDirty = false;
let reminderNotePreviewPortal = null;
let reminderNotePreviewHideTimer = null;

// Dirty-state tracking for the task detail panel.
// `taskDetailDirty` is true once any field is modified; `taskDetailSnapshot`
// holds the original field values for CANCEL/revert. Closing or switching
// tasks while dirty prompts a discard confirmation.
let taskDetailDirty = false;
let taskDetailSnapshot = null;
let initializingTaskAttachments = false;

document.addEventListener("nrc:attachments-changed", () => {
  if (document.querySelector('[data-attachment-editor]')) return;
  if (initializingTaskAttachments || !currentDetailTask || descriptionFocusMode) return;
  if (!document.getElementById("taskDetailSave")) return;
  setTaskDetailDirty(true);
});

function parseNotePreviewTitle(preview) {
  const parsed = parseNotePreviewMeta(preview);
  if (parsed.title) return parsed.title;
  return parsed.raw;
}

function parseNotePreviewMeta(preview) {
  if (!preview) return { title: "", teaser: "", project: "", tags: [], raw: "" };
  // Notes use JSON preview format: {"title":"...","teaser":"...","project":"...","tags":[...]}
  if (preview[0] === "{" && preview.includes("\"title\"")) {
    try {
      const obj = JSON.parse(preview);
      if (obj && typeof obj === "object") {
        const title = typeof obj.title === "string" ? obj.title.trim() : "";
        const teaser = typeof obj.teaser === "string" ? obj.teaser.trim() : "";
        const project = typeof obj.project === "string" ? obj.project.trim() : "";
        const tags = Array.isArray(obj.tags)
          ? obj.tags.map((tag) => String(tag).trim()).filter(Boolean)
          : [];
        return { title, teaser, project, tags, raw: "" };
      }
    } catch {
      // fallthrough
    }
  }

  return {
    title: "",
    teaser: "",
    project: "",
    tags: [],
    raw: String(preview).trim(),
  };
}

function hideReminderNotePreview() {
  clearTimeout(reminderNotePreviewHideTimer);
  reminderNotePreviewHideTimer = setTimeout(() => {
    reminderNotePreviewPortal?.destroy();
    reminderNotePreviewPortal = null;
    reminderNotePreviewHideTimer = null;
  }, 100);
}

function createReminderNotePreviewCard(note) {
  const card = document.createElement("div");
  card.className = "task-preview-card reminder-note-preview-card";

  const { title, teaser, raw } = parseNotePreviewMeta(note.preview || "");
  const noteTitle = title || raw || `(NO TITLE)`;
  const bodySource = (note.payload || teaser || "").trim();
  const bodySnippet = bodySource.length > 220 ? `${bodySource.slice(0, 220)}...` : bodySource;

  card.innerHTML = `
    <div class="task-preview-header">
      <div class="task-preview-id">#${note.assetId}</div>
      <div class="task-preview-status">NOTE</div>
    </div>
    <div class="task-preview-title">${escapeHtml(noteTitle)}</div>
    ${bodySnippet ? `<div class="task-preview-desc">${escapeHtml(bodySnippet)}</div>` : '<div class="task-preview-row"><span>Empty note</span></div>'}
  `;

  return card;
}

function showReminderNotePreview(element, noteId) {
  clearTimeout(reminderNotePreviewHideTimer);
  reminderNotePreviewHideTimer = null;
  reminderNotePreviewPortal?.destroy();
  reminderNotePreviewPortal = null;

  const roomAssets = window.NRCAssets?.roomAssets?.get(0n);
  const note = roomAssets ? roomAssets.get(noteId) : null;

  const preview = note && note.assetType === AssetType.Note
    ? createReminderNotePreviewCard(note)
    : (() => {
      const missing = document.createElement("div");
      missing.className = "task-preview-card task-preview-notfound reminder-note-preview-card";
      missing.innerHTML = `
        <div class="task-preview-header">
          <div class="task-preview-id">#${noteId}</div>
          <div class="task-preview-status">---</div>
        </div>
        <div class="task-preview-title">Note not found</div>
        <div class="task-preview-row"><span>This note isn't in the workspace</span></div>
      `;
      return missing;
    })();

  preview.id = "reminderNotePreviewPopup";
  reminderNotePreviewPortal = Portal.create(preview, element, {
    position: "bottom", align: "left", matchWidth: false, offsetY: 8, flipIfNeeded: true,
  });
  reminderNotePreviewPortal.show();

  preview.addEventListener("mouseenter", () => {
    clearTimeout(reminderNotePreviewHideTimer);
    reminderNotePreviewHideTimer = null;
  });

  preview.addEventListener("mouseleave", () => {
    hideReminderNotePreview();
  });
}

// Note: Note detail panel state moved to notes.js

// Sync detail panel STS field if the given task is currently selected
function syncDetailPanelStatus(convId, taskId, newStatus) {
  if (selectedTaskId !== taskId || selectedTaskConvId !== convId || !currentDetailTask) return;
  currentDetailTask = { ...currentDetailTask, status: newStatus };
  const control = document.querySelector(`.agenda-content nrc-inline-field[data-control="task-${convId}-${taskId}-status"]`);
  if (control) control.outerHTML = fieldControl(currentDetailTask, "status");
}

// =============================================================================
// METRICS CALCULATION
// =============================================================================

function calculateMetrics(tasks) {
  const metrics = {
    backlog: 0,
    todo: 0,
    inProgress: 0,
    done: 0,
    blocked: 0,
    overdue: 0,
  };

  for (const task of tasks.values()) {
    // Count by status
    switch (task.status) {
      case TaskStatus.Backlog:
        metrics.backlog++;
        break;
      case TaskStatus.Todo:
        metrics.todo++;
        break;
      case TaskStatus.InProgress:
        metrics.inProgress++;
        break;
      case TaskStatus.Done:
        metrics.done++;
        break;
    }

    // Count blocked tasks (only non-Done)
    if (
      task.blockedBy &&
      task.blockedBy !== 0n &&
      task.status !== TaskStatus.Done
    ) {
      metrics.blocked++;
    }

    // Count overdue tasks (non-Done with due date in the past)
    if (isTaskOverdue(task)) {
      metrics.overdue++;
    }

    // Apply "my tasks only" filter if enabled
    if (myTasksOnly && myNickname && task.assignee !== myNickname) {
      // Metrics should reflect filtered view, so we need to exclude filtered tasks
      // This is handled by only iterating filtered tasks below
    }
  }

  return metrics;
}

function calculateMetricsFiltered(tasks) {
  const metrics = {
    backlog: 0,
    todo: 0,
    inProgress: 0,
    done: 0,
    blocked: 0,
    overdue: 0,
  };

  // Use the new filter system if available
  const filteredTasks =
    typeof getFilteredTasks === "function"
      ? getFilteredTasks(tasks)
      : Array.from(tasks.values());

  for (const task of filteredTasks) {
    // Count by status
    switch (task.status) {
      case TaskStatus.Backlog:
        metrics.backlog++;
        break;
      case TaskStatus.Todo:
        metrics.todo++;
        break;
      case TaskStatus.InProgress:
        metrics.inProgress++;
        break;
      case TaskStatus.Done:
        metrics.done++;
        break;
    }

    // Count blocked tasks (only non-Done)
    if (
      task.blockedBy &&
      task.blockedBy !== 0n &&
      task.status !== TaskStatus.Done
    ) {
      metrics.blocked++;
    }

    // Count overdue tasks (non-Done with due date in the past)
    if (isTaskOverdue(task)) {
      metrics.overdue++;
    }
  }

  return metrics;
}

function updateMetricsDisplay(metrics) {
  // Update blocked/overdue counts in task filter bar
  const blockedCount = document.getElementById("blockedCount");
  const overdueCount = document.getElementById("overdueCount");
  if (blockedCount) blockedCount.textContent = metrics.blocked;
  if (overdueCount) overdueCount.textContent = metrics.overdue;
  window.NRCInspector?.refreshContext();
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

// Format nanoseconds timestamp to display date string (YYYY-MM-DD)
function formatDueDate(nanos) {
  if (!nanos || nanos === 0n) return "";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  return date.toISOString().split("T")[0];
}

function formatDueDateShort(nanos) {
  if (!nanos || nanos === 0n) return "";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${month}-${day}`;
}

function formatReminderDate(nanos) {
  if (!nanos || nanos === 0n) return "";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

// Format nanoseconds timestamp to datetime-local input value
function formatDateTimeLocal(nanos) {
  if (!nanos || nanos === 0n) return "";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  // Format: YYYY-MM-DDTHH:MM
  const pad = value => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

// Parse datetime-local input value to nanoseconds
function parseDateTimeLocal(value) {
  if (!value) return 0n;
  const date = new Date(value);
  if (isNaN(date.getTime())) return 0n;
  return BigInt(date.getTime()) * 1000000n;
}

function parseNanosField(value) {
  if (value === null || value === undefined || value === "") return 0n;
  if (typeof value === "bigint") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return 0n;
    return BigInt(Math.trunc(value));
  }
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) return 0n;
    try {
      return BigInt(trimmed);
    } catch {
      return 0n;
    }
  }
  return 0n;
}

function parseReminderAsset(asset) {
  if (!asset || asset.assetType !== AssetType.Reminder) return null;

  let parsed = null;
  const candidates = [asset.payload, asset.preview];
  for (const raw of candidates) {
    if (!raw || typeof raw !== "string") continue;
    const trimmed = raw.trim();
    if (!trimmed.startsWith("{")) continue;
    try {
      parsed = JSON.parse(trimmed);
      break;
    } catch {
      // Fall through to next candidate.
    }
  }

  const data = parsed || {};
  const title = (data.title || data.name || asset.preview || "").toString().trim();
  const deadlineAt = parseNanosField(data.deadline_at ?? data.deadlineAt);
  if (!title || deadlineAt === 0n) return null;

  const windowStartAt = parseNanosField(data.window_start_at ?? data.windowStartAt);
  const urgencyDaysRaw = Number(data.urgency_days ?? data.urgencyDays ?? REMINDER_DEFAULT_URGENCY_DAYS);
  const urgencyDays = Number.isFinite(urgencyDaysRaw) && urgencyDaysRaw >= 1
    ? Math.trunc(urgencyDaysRaw)
    : REMINDER_DEFAULT_URGENCY_DAYS;

  let noteAssetId = 0n;
  const noteCandidate = data.note_asset_id ?? data.noteAssetId;
  if (noteCandidate !== null && noteCandidate !== undefined && noteCandidate !== "") {
    try {
      noteAssetId = BigInt(noteCandidate);
    } catch {
      noteAssetId = 0n;
    }
  }

  return {
    asset,
    title,
    deadlineAt,
    windowStartAt,
    urgencyDays,
    noteAssetId,
  };
}

function getReminderState(reminder, nowNanos) {
  if (reminder.deadlineAt !== 0n && nowNanos > reminder.deadlineAt) {
    return ReminderState.Late;
  }
  if (reminder.windowStartAt !== 0n && nowNanos < reminder.windowStartAt) {
    return ReminderState.Locked;
  }
  const urgencyWindowNs = BigInt(reminder.urgencyDays) * 24n * 60n * 60n * 1000000000n;
  if (reminder.deadlineAt !== 0n && reminder.deadlineAt - nowNanos <= urgencyWindowNs) {
    return ReminderState.Urgent;
  }
  return ReminderState.Open;
}

function matchesReminderFilter(reminder, filter, nowNanos) {
  if (filter === "overdue") return reminder.deadlineAt < nowNanos;
  if (filter === "upcoming") return reminder.deadlineAt >= nowNanos;
  if (filter === "today") {
    const now = new Date(Number(nowNanos / 1000000n));
    const due = new Date(Number(reminder.deadlineAt / 1000000n));
    return due.getFullYear() === now.getFullYear() &&
      due.getMonth() === now.getMonth() && due.getDate() === now.getDate();
  }
  return true;
}

function buildReminderPayload(reminder) {
  return JSON.stringify({
    title: reminder.title,
    window_start_at: reminder.windowStartAt.toString(),
    deadline_at: reminder.deadlineAt.toString(),
    urgency_days: reminder.urgencyDays,
    note_asset_id: reminder.noteAssetId !== 0n ? reminder.noteAssetId.toString() : "",
  });
}

function deleteReminder(reminderAssetId, roomId = 0n) {
  if (!window.NRCAssets || roomId == null) return;
  window.NRCAssets.sendDeleteAsset(roomId, reminderAssetId);
}

async function confirmAndDeleteReminder(reminder) {
  if (!reminder) return false;
  const confirmed = await window.NRCDialog.confirm(
    `Delete reminder #${reminder.asset.assetId} “${reminder.title || "(untitled)"}”?`,
    { title: "DELETE REMINDER", confirmLabel: "Delete Reminder" },
  );
  if (!confirmed) return true;

  const convId = reminder.asset.convId;
  const assetId = reminder.asset.assetId;
  const isInspected = selectedReminderAssetId === assetId && currentDetailReminder?.asset?.convId === convId;
  if (isInspected) {
    reminderDetailDirty = false;
    if (window.NRCInspector) {
      if (!(await window.NRCInspector.close())) return true;
    } else {
      clearReminderSelection({ fromInspector: true });
    }
  }
  deleteReminder(assetId, convId);
  return true;
}

function getReminderByAssetId(reminderAssetId, roomId = 0n) {
  const assets = window.NRCAssets?.getAssetsByType(roomId, AssetType.Reminder) || [];
  const asset = assets.find((a) => a.assetId === reminderAssetId);
  return parseReminderAsset(asset);
}

function clearReminderSelection({ fromInspector = false } = {}) {
  if (!fromInspector && window.NRCInspector?.hasEntity()) {
    window.NRCInspector.close();
    return;
  }
  selectedReminderAssetId = null;
  currentDetailReminder = null;
  reminderDetailDirty = false;
  hideReminderDetailPanel();
  renderReminderQueue();
}

function selectReminder(reminderAssetId, { fromInspector = false, roomId = 0n } = {}) {
  if (!fromInspector && window.NRCInspector) {
    window.NRCInspector.openEntity({ roomId, type: "reminder", id: reminderAssetId });
    return;
  }
  const reminder = getReminderByAssetId(reminderAssetId, roomId);
  if (!reminder) return false;

  if (selectedTaskId) {
    clearTaskSelection({ fromInspector: true });
  }
  if (window.NRCNotes && window.NRCNotes.selectedNoteId && window.NRCNotes.selectedNoteId()) {
    window.NRCNotes.clearNoteSelection({ fromInspector: true });
  }

  selectedReminderAssetId = reminderAssetId;
  currentDetailReminder = reminder;
  showReminderDetailPanel(reminder);
  renderReminderQueue();
  return true;
}

function buildReminderNoteOptions(selectedNoteAssetId, roomId = 0n) {
  const options = ['<option value="">—</option>'];
  const notes = window.NRCAssets?.getAssetsByType(roomId, AssetType.Note) || [];

  notes.sort((a, b) => {
    if (a.updatedAt > b.updatedAt) return -1;
    if (a.updatedAt < b.updatedAt) return 1;
    return 0;
  });

  const selectedIdStr = selectedNoteAssetId && selectedNoteAssetId !== 0n
    ? selectedNoteAssetId.toString()
    : "";
  let selectedFound = false;

  for (const note of notes) {
    const idStr = note.assetId.toString();
    const title = parseNotePreviewTitle(note.preview) || `NOTE #${idStr}`;
    const selectedAttr = idStr === selectedIdStr ? " selected" : "";
    if (selectedAttr) selectedFound = true;
    options.push(`<option value="${idStr}"${selectedAttr}>#${idStr} ${escapeHtml(title)}</option>`);
  }

  if (selectedIdStr && !selectedFound) {
    options.push(`<option value="${selectedIdStr}" selected>#${selectedIdStr} (MISSING)</option>`);
  }

  return options.join("");
}

function saveReminderFromDetailPanel() {
  if (!currentDetailReminder) return;

  const setValidationError = (message) => {
    const errorEl = document.getElementById("reminderDetailValidationError");
    if (!errorEl) return;
    errorEl.textContent = message || "";
    errorEl.style.display = message ? "block" : "none";
  };

  setValidationError("");

  const title = document.getElementById("reminderDetailTitle")?.value.trim() || "";
  const windowStartInput = document.getElementById("reminderDetailWindowStart")?.value || "";
  const deadlineInput = document.getElementById("reminderDetailDeadline")?.value || "";
  const urgencyInput = document.getElementById("reminderDetailUrgency")?.value || "";
  const noteIdInput = document.getElementById("reminderDetailNoteId")?.value || "";

  if (!title) {
    setValidationError("TITLE IS REQUIRED");
    return;
  }

  const deadlineAt = parseDateTimeLocal(deadlineInput);
  if (deadlineAt === 0n) {
    setValidationError("DEADLINE IS REQUIRED");
    return;
  }

  const windowStartAt = windowStartInput ? parseDateTimeLocal(windowStartInput) : 0n;
  if (windowStartAt !== 0n && windowStartAt > deadlineAt) {
    setValidationError("WINDOW START MUST BE BEFORE DEADLINE");
    return;
  }

  const urgencyDaysRaw = Number.parseInt(urgencyInput, 10);
  const urgencyDays = Number.isFinite(urgencyDaysRaw) && urgencyDaysRaw > 0
    ? urgencyDaysRaw
    : REMINDER_DEFAULT_URGENCY_DAYS;

  let noteAssetId = 0n;
  if (noteIdInput) {
    try {
      noteAssetId = BigInt(noteIdInput);
    } catch {
      setValidationError("INVALID LINKED NOTE ID");
      return;
    }
  }

  const updatedReminder = {
    title,
    windowStartAt,
    deadlineAt,
    urgencyDays,
    noteAssetId,
  };

  const payload = buildReminderPayload(updatedReminder);
  const preview = `${title} | DUE ${formatDueDateShort(deadlineAt)}`;

  window.NRCAssets.sendUpdateAsset(currentDetailReminder.asset.convId, currentDetailReminder.asset.assetId, preview, payload);
  reminderDetailDirty = false;
}

function showReminderDetailPanel(reminder) {
  currentDetailReminder = reminder;
  reminderDetailDirty = false;

  const agendaPanel = document.querySelector(".agenda-panel");
  if (!agendaPanel) return;
  const agendaHeader = agendaPanel.querySelector(".panel-header");
  const agendaContent = agendaPanel.querySelector(".agenda-content");
  const agendaActions = document.getElementById("agendaActions");
  window.NRCLinksUI?.closeLinkPicker();

  agendaActions.style.display = "none";

  const state = getReminderState(reminder, BigInt(Date.now()) * 1000000n);
  const noteOptions = buildReminderNoteOptions(reminder.noteAssetId, reminder.asset.convId);
  agendaHeader.innerHTML = `<div class="inspector-identity-row">
    <span class="header-text">REMINDER #${reminder.asset.assetId}</span>
    ${window.NRCDetailUI.renderHeaderMetadata([
      { label: "CREATED BY", value: reminder.asset.owner || "—", role: "actor" },
      { label: "CREATED", value: window.NRCDetailUI.formatHeaderDate(reminder.asset.createdAt) },
      { label: "UPDATED", value: window.NRCDetailUI.formatHeaderDate(reminder.asset.updatedAt) },
    ])}
    <span class="inspector-cell-label">STATE</span>
    <span class="status-value-mono inspector-state-value">${state}</span>
  </div><div class="inspector-mode-row">
    <div class="inspector-view-cell">
      <div class="task-detail-tabs">
        <button class="btn nav-tab inspector-matrix-control active" data-tab="detail" type="button" aria-current="page"><span>DETAIL</span></button>
      </div>
    </div>
    ${window.NRCDetailUI.renderHeaderAction({ id: "reminderDetailSaveHeader", label: "SAVE", command: "s", title: "Save reminder (S)" })}
    ${window.NRCDetailUI.renderHeaderAction({ id: "reminderDetailOpenNoteHeader", label: "NOTE", command: "v", title: "Open linked note (V)" })}
    ${window.NRCDetailUI.renderCloseControl("reminderDetailClose")}
  </div>`;

  agendaContent.innerHTML = `
    <div class="task-detail-panel task-detail-panel-editable reminder-detail-panel detail-edit-form">
      <div class="task-detail-row detail-edit-field">
        <label class="task-detail-label detail-edit-label" for="reminderDetailTitle">TITLE</label>
        <input type="text" class="task-detail-input" id="reminderDetailTitle" value="${escapeHtml(reminder.title)}" maxlength="256">
      </div>
      <div class="detail-edit-grid detail-edit-grid--reminder-dates">
        <div class="task-detail-row detail-edit-field">
          <label class="task-detail-label detail-edit-label" for="reminderDetailWindowStart">WINDOW START</label>
          <input type="datetime-local" class="task-detail-input" id="reminderDetailWindowStart" value="${formatDateTimeLocal(reminder.windowStartAt)}">
        </div>
        <div class="task-detail-row detail-edit-field">
          <label class="task-detail-label detail-edit-label" for="reminderDetailDeadline">DUE</label>
          <input type="datetime-local" class="task-detail-input" id="reminderDetailDeadline" value="${formatDateTimeLocal(reminder.deadlineAt)}">
        </div>
      </div>
      <div class="detail-edit-grid detail-edit-grid--reminder-meta">
        <div class="task-detail-row detail-edit-field">
          <label class="task-detail-label detail-edit-label" for="reminderDetailUrgency">URGENCY</label>
          <input type="text" class="task-detail-input" id="reminderDetailUrgency" value="${reminder.urgencyDays}" maxlength="2">
        </div>
        <div class="task-detail-row detail-edit-field">
          <label class="task-detail-label detail-edit-label" for="reminderDetailNoteId">LINKED NOTE</label>
          <nrc-select><select class="task-detail-select" id="reminderDetailNoteId" data-custom-select-search-placeholder="FILTER NOTE...">${noteOptions}</select></nrc-select>
        </div>
      </div>
      <div class="reminder-detail-validation-error" id="reminderDetailValidationError" style="display:none;"></div>
    </div>
    <div class="task-detail-actions">
      <button class="btn btn--primary task-modal-btn save" id="reminderDetailSave">SAVE</button>
      <button class="btn btn--secondary task-modal-btn" id="reminderDetailOpenNote">OPEN NOTE</button>
      <button class="btn btn--danger task-modal-btn danger" id="reminderDetailDelete">DELETE</button>
    </div>
  `;

  const reminderDirtyFields = new Set(["reminderDetailTitle", "reminderDetailWindowStart", "reminderDetailDeadline", "reminderDetailUrgency", "reminderDetailNoteId"]);
  const markReminderDirty = (event) => {
    if (reminderDirtyFields.has(event.target.id)) reminderDetailDirty = true;
  };
  agendaContent.oninput = markReminderDirty;
  agendaContent.onchange = markReminderDirty;

  const closeBtn = document.getElementById("reminderDetailClose");
  if (closeBtn) {
    closeBtn.onclick = () => window.NRCInspector?.close() ?? clearReminderSelection({ fromInspector: true });
  }

  const saveBtn = document.getElementById("reminderDetailSave");
  if (saveBtn) {
    saveBtn.onclick = saveReminderFromDetailPanel;
  }
  const headerSaveBtn = document.getElementById("reminderDetailSaveHeader");
  if (headerSaveBtn) {
    headerSaveBtn.onclick = saveReminderFromDetailPanel;
  }

  const openNoteBtn = document.getElementById("reminderDetailOpenNote");
  const headerOpenNoteBtn = document.getElementById("reminderDetailOpenNoteHeader");
  const openLinkedNote = () => {
    const noteIdInput = document.getElementById("reminderDetailNoteId")?.value || "";
    if (!noteIdInput) {
      logSystem("NO LINKED NOTE SET", "tasks", "WARN");
      return;
    }
    try {
      openReminderLinkedNote(BigInt(noteIdInput));
    } catch {
      logMessage("Error", "Invalid note ID");
    }
  };
  if (openNoteBtn) {
    openNoteBtn.onclick = openLinkedNote;
  }
  if (headerOpenNoteBtn) {
    headerOpenNoteBtn.onclick = openLinkedNote;
  }

  const deleteBtn = document.getElementById("reminderDetailDelete");
  if (deleteBtn) {
    deleteBtn.onclick = () => confirmAndDeleteReminder(reminder);
  }
}

function hideReminderDetailPanel() {
  const agendaPanel = document.querySelector(".agenda-panel");
  if (!agendaPanel) return;

  const agendaHeader = agendaPanel.querySelector(".panel-header");
  const agendaContent = agendaPanel.querySelector(".agenda-content");
  const agendaActions = document.getElementById("agendaActions");

  agendaContent.oninput = null;
  agendaContent.onchange = null;
  agendaHeader.classList.remove("is-dirty");
  agendaContent.innerHTML = "";
  agendaActions.style.display = "none";
}

function openReminderLinkedNote(noteAssetId) {
  if (!noteAssetId || noteAssetId === 0n) return;
  const roomId = 0n;
  if (window.NRCInspector) {
    window.NRCInspector.openEntity({ roomId, type: "note", id: noteAssetId });
    return;
  }
  const note = window.NRCAssets?.roomAssets?.get(roomId)?.get(noteAssetId);
  if (note?.assetType === AssetType.Note) {
    window.NRCNotes?.selectNote(note);
  } else {
    window.NRCAssets?.sendGetAsset?.(roomId, noteAssetId, {
      onSuccess: (detail) => {
        if (detail?.asset?.assetType === AssetType.Note) window.NRCNotes?.selectNote(detail.asset);
      },
    });
  }
}

function isRemindersKeyboardEditableTarget(target) {
  if (!target) return false;
  const tagName = target.tagName;
  return tagName === "INPUT" || tagName === "TEXTAREA" || tagName === "SELECT" || target.isContentEditable;
}

function isRemindersKeyboardActive() {
  const activeView = window.NRCViewManager?.getActiveView?.();
  const queueBody = document.getElementById("reminderQueueBody");
  return window.NRCListNavigation.isKeyboardViewActive(
    activeView,
    "reminders",
    remindersVisible,
    document.getElementById("remindersPanel")?.style.display !== "none",
    Boolean(queueBody?.querySelector("[data-reminder-row-id]")),
  );
}

function getVisibleReminderRows() {
  return Array.from(document.querySelectorAll("#reminderQueueBody [data-reminder-row-id]"));
}

function selectReminderRow(row) {
  if (!row?.dataset.reminderRowId) return false;
  const reminderId = BigInt(row.dataset.reminderRowId);
  const reminder = getReminderByAssetId(reminderId);
  if (!reminder) return false;
  selectReminder(reminderId);
  requestAnimationFrame(() => {
    document.querySelector(`#reminderQueueBody [data-reminder-row-id="${row.dataset.reminderRowId}"]`)
      ?.scrollIntoView({ block: "nearest" });
  });
  return true;
}

function selectAdjacentReminder(direction) {
  const rows = getVisibleReminderRows();
  if (rows.length === 0) return false;

  const selectedInCurrentRoom = currentDetailReminder?.asset?.convId === 0n;
  const selectedId = selectedInCurrentRoom && selectedReminderAssetId ? selectedReminderAssetId.toString() : null;
  const currentIndex = selectedId
    ? rows.findIndex((row) => row.dataset.reminderRowId === selectedId)
    : -1;
  let nextIndex;
  if (currentIndex === -1) {
    nextIndex = direction > 0 ? 0 : rows.length - 1;
  } else {
    nextIndex = Math.max(0, Math.min(rows.length - 1, currentIndex + direction));
  }

  return selectReminderRow(rows[nextIndex]);
}

async function confirmDeleteSelectedReminder() {
  if (!selectedReminderAssetId) return false;
  const reminder = currentDetailReminder || getReminderByAssetId(selectedReminderAssetId);
  if (!reminder) return false;
  return await confirmAndDeleteReminder(reminder);
}

function handleRemindersKeyboardNavigation(e) {
  if (!isRemindersKeyboardActive()) return;
  if (isRemindersKeyboardEditableTarget(e.target)) return;

  if (e.key === "ArrowDown") {
    e.preventDefault();
    selectAdjacentReminder(1);
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    selectAdjacentReminder(-1);
  } else if (e.key === "Delete") {
    e.preventDefault();
    confirmDeleteSelectedReminder();
  }
}

// The one parsing path for workspace reminders: the reminder register renders
// this snapshot and the reminder timer reports its transitions, so the view and
// the notification can never disagree about a reminder's state.
function getReminderSnapshot(nowNanos = BigInt(Date.now()) * 1000000n) {
  const assets = window.NRCAssets?.getAssetsByType(0n, AssetType.Reminder) || [];
  return {
    assetCount: assets.length,
    reminders: assets
      .map(parseReminderAsset)
      .filter((reminder) => reminder)
      .map((reminder) => ({ ...reminder, state: getReminderState(reminder, nowNanos) })),
  };
}

function renderReminderQueue() {
  hideReminderNotePreview();

  const queueBody = document.getElementById("reminderQueueBody");
  const countEl = document.getElementById("reminderQueueCount");
  if (!queueBody || !countEl) return;

  const snapshot = getReminderSnapshot();
  const nowNanos = BigInt(Date.now()) * 1000000n;
  const hideLockedReminders =
    typeof TaskViewState !== "undefined" &&
    TaskViewState.filters &&
    TaskViewState.filters.hideLockedReminders === true;

  const filter = typeof TaskViewState !== "undefined"
    ? TaskViewState.filters.reminderView || "all" : "all";
  const available = snapshot.reminders
    .filter((r) => !(hideLockedReminders && r.state === ReminderState.Locked));

  document.querySelectorAll("[data-reminder-filter]").forEach((button) => {
    const value = button.dataset.reminderFilter;
    const count = available.filter((r) => matchesReminderFilter(r, value, nowNanos)).length;
    const label = button.querySelector("span");
    const countSlot = button.querySelector(".tab-count");
    if (label) label.textContent = value.toUpperCase();
    if (countSlot) countSlot.textContent = String(count);
    button.classList.toggle("active", value === filter);
    button.setAttribute("aria-pressed", String(value === filter));
  });

  const reminders = available
    .filter((r) => matchesReminderFilter(r, filter, nowNanos))
    .sort((a, b) => {
      if (a.deadlineAt !== b.deadlineAt) return a.deadlineAt < b.deadlineAt ? -1 : 1;
      if (a.windowStartAt !== b.windowStartAt) return a.windowStartAt < b.windowStartAt ? -1 : 1;
      return a.title.localeCompare(b.title);
    });

  countEl.textContent = `${reminders.length} RESULTS`;
  window.NRCInspector?.refreshContext();

  if (reminders.length === 0) {
    queueBody.innerHTML = `<div class="reminder-empty">${snapshot.assetCount === 0 ? "NO ACTIVE REMINDERS" : "NO MATCHING REMINDERS"}</div>`;
    return;
  }

  const roomAssets = window.NRCAssets?.roomAssets?.get(0n);

  const uncachedNoteIds = new Set();
  for (const r of reminders) {
    if (r.noteAssetId && r.noteAssetId !== 0n && roomAssets && !roomAssets.has(r.noteAssetId)) {
      uncachedNoteIds.add(r.noteAssetId);
    }
  }
  for (const noteId of uncachedNoteIds) {
    window.NRCAssets?.sendGetAsset(0n, noteId, {
      onSuccess: () => {
        renderReminderQueue();
      },
    });
  }

  queueBody.innerHTML = `<div class="reminder-list-header">
    <span class="reminder-marker"></span><span>ID</span><span>TITLE</span>
    <span>STATE</span><span>WINDOW START</span><span>DEADLINE</span><span>LINKED NOTE</span>
  </div>` + reminders
    .map((r) => {
      let noteLabel = '<span class="reminder-note">—</span>';
      if (r.noteAssetId && r.noteAssetId !== 0n) {
        const note = roomAssets ? roomAssets.get(r.noteAssetId) : null;
        const noteTitle = note ? (parseNotePreviewTitle(note.preview) || `NOTE #${r.noteAssetId}`) : `NOTE #${r.noteAssetId}`;
        noteLabel = `<span class="reminder-note reminder-note-link" data-note-id="${r.noteAssetId}" title="${escapeHtml(`#${r.noteAssetId} ${noteTitle}`)}">${escapeHtml(`#${r.noteAssetId} ${noteTitle}`)}</span>`;
      }
      const isSelected = selectedReminderAssetId === r.asset.assetId && currentDetailReminder?.asset?.convId === r.asset.convId;
      return `
        <div class="reminder-row ${isSelected ? "reminder-row-selected" : ""}" data-reminder-row-id="${r.asset.assetId}">
          <span class="reminder-marker" aria-hidden="true">${isSelected ? "›" : ""}</span>
          <span class="reminder-id" title="Reminder #${r.asset.assetId}">${r.asset.assetId}</span>
          <button type="button" class="task-row-open reminder-title" aria-label="${escapeHtml(`Open reminder ${r.asset.assetId}: ${r.title}`)}" ${isSelected ? 'aria-current="true"' : ""} title="${escapeHtml(r.title)}">${escapeHtml(r.title)}</button>
          <span class="reminder-state reminder-state-${r.state.toLowerCase()}">${r.state}</span>
          <span class="reminder-time">${r.windowStartAt !== 0n ? formatReminderDate(r.windowStartAt) : "—"}</span>
          <span class="reminder-time">${formatReminderDate(r.deadlineAt)}</span>
          ${noteLabel}
        </div>
      `;
    })
    .join("");

  window.NRCColumnResize?.init({
    root: ".reminder-list-header", headers: ":scope > span", storageKey: "nrc.reminder.columns.v1",
    // Keep the hidden slot so saved data-column widths retain their indexes.
    defaults: [0, 48, 320, 90, 130, 130, 180],
    minimums: [16, 48, 160, 80, 110, 110, 120],
    locked: [0],
    apply: (header, widths) => header.parentElement.style.setProperty("--reminder-columns", widths.map((width) => `${width}px`).join(" ")),
  });

  queueBody.querySelectorAll("[data-note-id]").forEach((el) => {
    el.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      hideReminderNotePreview();
      const noteId = el.dataset.noteId ? BigInt(el.dataset.noteId) : 0n;
      openReminderLinkedNote(noteId);
    });

    el.addEventListener("mouseenter", () => {
      const noteId = el.dataset.noteId ? BigInt(el.dataset.noteId) : 0n;
      if (noteId !== 0n) {
        showReminderNotePreview(el, noteId);
      }
    });

    el.addEventListener("mouseleave", () => {
      hideReminderNotePreview();
    });
  });

  queueBody.querySelectorAll("[data-reminder-row-id]").forEach((el) => {
    el.addEventListener("click", () => {
      const reminderId = el.dataset.reminderRowId ? BigInt(el.dataset.reminderRowId) : 0n;
      if (reminderId !== 0n) {
        selectReminder(reminderId);
      }
    });
  });
}

async function createReminder() {
  if (!window.NRCAssets || !window.NRCDialog) return;

  const title = await window.NRCDialog.prompt("Reminder title:", {
    title: "CREATE REMINDER",
    placeholder: "Rotate S3 key (prod)",
  });
  if (!title || !title.trim()) return;

  const windowStartInput = await window.NRCDialog.prompt(
    "Window start (YYYY-MM-DDTHH:MM, optional):",
    { title: "CREATE REMINDER", placeholder: "2026-03-01T00:00" },
  );

  const deadlineInput = await window.NRCDialog.prompt(
    "Deadline (YYYY-MM-DDTHH:MM, required):",
    { title: "CREATE REMINDER", placeholder: "2026-03-15T23:59" },
  );
  if (!deadlineInput || !deadlineInput.trim()) {
    window.NRCDialog.notify("DEADLINE IS REQUIRED FOR REMINDERS", { logType: "Error" });
    return;
  }

  const deadlineAt = parseDateTimeLocal(deadlineInput.trim());
  if (deadlineAt === 0n) {
    window.NRCDialog.notify("INVALID DEADLINE FORMAT (USE YYYY-MM-DDTHH:MM)", { logType: "Error" });
    return;
  }

  const windowStartAt = windowStartInput && windowStartInput.trim().length > 0
    ? parseDateTimeLocal(windowStartInput.trim())
    : 0n;

  if (windowStartAt !== 0n && windowStartAt > deadlineAt) {
    window.NRCDialog.notify("WINDOW START MUST BE BEFORE DEADLINE", { logType: "Error" });
    return;
  }

  const noteIdInput = await window.NRCDialog.prompt(
    "Linked note ID (optional):",
    { title: "CREATE REMINDER", placeholder: "204" },
  );

  let noteAssetId = 0n;
  if (noteIdInput && noteIdInput.trim().length > 0) {
    try {
      noteAssetId = BigInt(noteIdInput.trim());
    } catch {
      window.NRCDialog.notify("INVALID NOTE ID", { logType: "Error" });
      return;
    }
  }

  const reminder = {
    title: title.trim(),
    windowStartAt,
    deadlineAt,
    urgencyDays: REMINDER_DEFAULT_URGENCY_DAYS,
    noteAssetId,
  };
  const payload = buildReminderPayload(reminder);

  const preview = `${title.trim()} | DUE ${formatDueDateShort(deadlineAt)}`;

  window.NRCAssets.sendCreateAsset(
    0n,
    AssetType.Reminder,
    ParentType.None,
    0n,
    preview,
    payload,
    window.NRCAssets.generateCorrelationId(),
  );
}

// Check if a task is overdue (has due date in the past and not Done)
function isTaskOverdue(task) {
  if (!task.dueAt || task.dueAt === 0n) return false;
  if (task.status === TaskStatus.Done) return false;
  const nowNanos = BigInt(Date.now()) * 1000000n;
  return task.dueAt < nowNanos;
}

// Get the blocking task (if any)
function getBlockingTask(convId, blockedBy) {
  if (!blockedBy || blockedBy === 0n) return null;
  const tasks = roomTasks.get(convId);
  if (!tasks) return null;
  return tasks.get(blockedBy) || null;
}

// Get the title of the blocking task (if any)
function getBlockingTaskTitle(convId, blockedBy) {
  const blockingTask = getBlockingTask(convId, blockedBy);
  if (!blockingTask) return blockedBy ? `#${blockedBy}` : null;
  return blockingTask.title;
}

// Check if blocking task is done (unblocked)
function isBlockerDone(convId, blockedBy) {
  const blockingTask = getBlockingTask(convId, blockedBy);
  return blockingTask && blockingTask.status === TaskStatus.Done;
}

// Update byte limit stats display for a field
function updateFieldByteLimitStats(inputEl, statsEl, maxBytes) {
  if (!inputEl || !statsEl) return;
  const bytes = new TextEncoder().encode(inputEl.value).length;
  statsEl.textContent = `${bytes}/${maxBytes}`;
  if (bytes > maxBytes) {
    statsEl.style.color = "var(--accent-danger)";
  } else {
    statsEl.style.color = "";
  }
}

// Get the full blocking chain (recursive)
// Returns array of task IDs from direct blocker to root: [directBlocker, nextBlocker, ...]
function getBlockingChain(convId, taskId, maxDepth = 10) {
  const chain = [];
  const visited = new Set();
  const tasks = roomTasks.get(convId);
  if (!tasks) return chain;

  let currentTask = tasks.get(taskId);
  if (!currentTask) return chain;

  let depth = 0;
  while (
    depth < maxDepth &&
    currentTask &&
    currentTask.blockedBy &&
    currentTask.blockedBy !== 0n
  ) {
    const blockedBy = currentTask.blockedBy;

    // Prevent infinite loops
    if (visited.has(blockedBy)) break;
    visited.add(blockedBy);

    chain.push(blockedBy);

    // Get the next task in the chain
    currentTask = getBlockingTask(convId, blockedBy);
    depth++;
  }

  return chain;
}

// Format blocking chain for display
// Input: [456, 789, 999]
// Output: "#456 → #789 → #999" (with truncation if too long)
function formatBlockingChain(chain) {
  if (!chain || chain.length === 0) return "—";

  const MAX_DISPLAY = 3;
  let formatted = chain
    .slice(0, MAX_DISPLAY)
    .map((id) => `#${id}`)
    .join(" → ");

  if (chain.length > MAX_DISPLAY) {
    formatted += ` → ... (${chain.length} total)`;
  }

  return formatted;
}

// Highlight blocking chain in list view (table rows)
function highlightBlockingChainList(convId, taskId) {
  const chain = getBlockingChain(convId, taskId);

  chain.forEach((blockerId, index) => {
    const blockerRow = document.querySelector(
      `.task-table tbody tr[data-task-id="${blockerId}"]`,
    );
    if (blockerRow) {
      blockerRow.classList.add(`task-row-highlight-depth-${index}`);

      // Add depth badge to priority cell (absolute positioned)
      const priCell = blockerRow.querySelector(".col-priority");
      if (priCell && !priCell.querySelector(".task-row-depth-badge")) {
        const depthBadge = document.createElement("span");
        depthBadge.className = "task-row-depth-badge";
        depthBadge.textContent = `D${index}`;
        depthBadge.dataset.depthLevel = index;
        priCell.appendChild(depthBadge);
      }
    }
  });
}

// Clear blocking chain highlighting in list view
function clearBlockingChainHighlightList(convId, taskId) {
  const chain = getBlockingChain(convId, taskId);

  chain.forEach((blockerId, index) => {
    const blockerRow = document.querySelector(
      `.task-table tbody tr[data-task-id="${blockerId}"]`,
    );
    if (blockerRow) {
      blockerRow.classList.remove(`task-row-highlight-depth-${index}`);

      // Remove depth badge from priority cell
      const priCell = blockerRow.querySelector(".col-priority");
      if (priCell) {
        const depthBadge = priCell.querySelector(".task-row-depth-badge");
        if (depthBadge) {
          depthBadge.remove();
        }
      }
    }
  });
}

// Format completed timestamp for display
function formatCompletedAt(nanos) {
  if (!nanos || nanos === 0n) return "";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  return date.toISOString().replace("T", " ").slice(0, 16);
}

function formatCompletedAtShort(nanos) {
  if (!nanos || nanos === 0n) return "";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  const hours = String(date.getHours()).padStart(2, "0");
  const mins = String(date.getMinutes()).padStart(2, "0");
  return `${month}-${day} ${hours}:${mins}`;
}

// Format generic nanoseconds timestamp for detail headers
function formatDateTime(nanos) {
  if (!nanos || nanos === 0n) return "--:--";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  if (Number.isNaN(date.getTime())) return "--:--";
  return date.toISOString().replace("T", " ").slice(0, 16);
}

// Format relative age (e.g., "2d ago", "3h ago")
function formatRelativeAge(nanos) {
  if (!nanos || nanos === 0n) return "";
  const ms = Number(nanos / 1000000n);
  const now = Date.now();
  const diffMs = now - ms;

  const seconds = Math.floor(diffMs / 1000);
  if (seconds < 60) return `${seconds}s ago`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;

  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;

  const months = Math.floor(days / 30);
  return `${months}mo ago`;
}

// =============================================================================
// STATE
// =============================================================================

const roomTasks = new Map(); // roomId (BigInt) -> Map<taskId (BigInt), Task>
const pendingTaskUpdateCorrelations = new Set(); // Skip notifications for acknowledged local updates
const pendingTaskDeletes = new Set(); // Track task IDs we're deleting (to skip self-notifications)
const pendingTaskRpcs = new Map();
const pendingExactTaskRequests = new Map();
const taskPageState = new Map(); // `${convId}:${mask}` -> pagination state
const taskMarkdownUpdates = new Map();
let kanbanVisible = false;
let remindersVisible = false;
let renderedTaskListRoomId = null;
let taskListDirty = true;
let renderedTaskSearchState = null;
let taskListValidUntilMs = Infinity;

function invalidateTaskList(convId) {
  if (renderedTaskListRoomId === convId) taskListDirty = true;
  // A slice's counters are folded from the tasks it carries, so a mutation that
  // invalidates the flat register can move a slice's silhouette too.
  if (convId === 0n) window.NRCSlices?.invalidate?.();
}

function refreshTaskSearchAfterMutation(convId) {
  window.NRCTaskQuery?.afterMutation(convId);
  if (convId === 0n && TaskViewState.filters.search) {
    window.NRCTaskSearch?.update?.({ debounce: true });
  }
}

// Metrics state
let currentMetrics = {
  backlog: 0,
  todo: 0,
  inProgress: 0,
  done: 0,
  blocked: 0,
  overdue: 0,
};

// =============================================================================
// PROTOCOL: MESSAGE SENDERS
// =============================================================================

function getRpcCorrelationId() {
  if (window.NRCAssets && typeof window.NRCAssets.generateCorrelationId === "function") {
    return window.NRCAssets.generateCorrelationId();
  }
  return 0;
}

function sendCreateTask(
  convId,
  title,
  description = "",
  priority = 128,
  color = 0,
  externalRef = "",
  dueAt = 0n,
  attachments = [],
  status = TaskStatus.Backlog,
  correlationId = 0,
  project = "",
  requestOptions = null,
) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) return;

  if (correlationId === 0) {
    correlationId = getRpcCorrelationId();
  }

  const titleBytes = new TextEncoder().encode(title);
  const descBytes = new TextEncoder().encode(description);
  const extRefBytes = new TextEncoder().encode(externalRef);
  const projectBytes = new TextEncoder().encode(project);
  if (titleBytes.length > MAX_TASK_TITLE_LENGTH || descBytes.length > MAX_TASK_DESCRIPTION_LENGTH) {
    requestOptions?.onError?.({
      correlationId,
      message: titleBytes.length > MAX_TASK_TITLE_LENGTH
        ? `Task title exceeds ${MAX_TASK_TITLE_LENGTH} UTF-8 bytes`
        : `Task description exceeds ${MAX_TASK_DESCRIPTION_LENGTH} UTF-8 bytes`,
    });
    return;
  }

  // Encode attachments
  const encodedAttachments = [];
  for (const att of attachments) {
    const fileIdBytes = new TextEncoder().encode(att.fileId);
    const filenameBytes = new TextEncoder().encode(att.filename);
    const mimeTypeBytes = new TextEncoder().encode(att.mimeType);

    encodedAttachments.push({
      fileId: fileIdBytes,
      filename: filenameBytes,
      size: att.size,
      mimeType: mimeTypeBytes,
      uploadedAt: att.uploadedAt,
    });
  }

  // Calculate buffer size
  // Opcode(2) + conv_id(8) + title_len(2) + title + desc_len(2) + desc + priority(1) + color(1) + ext_ref_len(2) + ext_ref + due_at(8) + att_count(2) + status(1) + correlation_id(4) + project_len(2) + project
  let bufferSize =
    2 +
    8 +
    2 +
    titleBytes.length +
    2 +
    descBytes.length +
    1 +
    1 +
    2 +
    extRefBytes.length +
    8 +
    2 +
    1 +
    4 +
    2 +
    projectBytes.length;

  // Add attachment sizes
  for (const att of encodedAttachments) {
    bufferSize +=
      2 +
      att.fileId.length +
      2 +
      att.filename.length +
      8 +
      2 +
      att.mimeType.length +
      8;
  }

  const buffer = new ArrayBuffer(bufferSize);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_CreateTask, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setUint16(offset, titleBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, titleBytes.length).set(titleBytes);
  offset += titleBytes.length;

  view.setUint16(offset, descBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, descBytes.length).set(descBytes);
  offset += descBytes.length;

  view.setUint8(offset, priority);
  offset += 1;

  view.setUint8(offset, color);
  offset += 1;

  view.setUint16(offset, extRefBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, extRefBytes.length).set(extRefBytes);
  offset += extRefBytes.length;

  view.setBigInt64(offset, BigInt(dueAt), false);
  offset += 8;

  // Encode attachments count
  view.setUint16(offset, encodedAttachments.length, false);
  offset += 2;

  // Encode each attachment
  for (const att of encodedAttachments) {
    view.setUint16(offset, att.fileId.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, att.fileId.length).set(att.fileId);
    offset += att.fileId.length;

    view.setUint16(offset, att.filename.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, att.filename.length).set(att.filename);
    offset += att.filename.length;

    view.setBigUint64(offset, att.size, false);
    offset += 8;

    view.setUint16(offset, att.mimeType.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, att.mimeType.length).set(att.mimeType);
    offset += att.mimeType.length;

    view.setBigInt64(offset, att.uploadedAt, false);
    offset += 8;
  }

  // Status (default Backlog=0)
  view.setUint8(offset, status);
  offset += 1;

  view.setUint32(offset, correlationId, false);
  offset += 4;

  view.setUint16(offset, projectBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, projectBytes.length).set(projectBytes);
  offset += projectBytes.length;

  if (requestOptions && typeof requestOptions === "object") {
    pendingTaskRpcs.set(correlationId, {
      onSuccess: requestOptions.onSuccess,
      onError: requestOptions.onError,
    });
  }

  ws.send(buffer);
  localPacketsOut++;
  return correlationId;
}

// Sentinel values for update fields:
// dueAt: 0n = no change, -1n = clear, positive = set new value
// blockedBy: 0n = no change, max_u64 = clear, other = set blocker task ID
const UPDATE_BLOCKED_BY_CLEAR = 0xffffffffffffffffn;

function taskUpdatePromise(task, patch) {
  return new Promise((resolve, reject) => {
    const fail = (detail) => reject(new Error(detail?.message || "TASK UPDATE FAILED"));
    if (patch.status !== undefined) {
      const sent = sendMoveTask(task.convId, task.id, patch.status, { onSuccess: resolve, onError: fail });
      if (!sent) fail({ message: "STATUS CHANGE WAS NOT SENT" });
      return;
    }
    const sent = sendUpdateTask(
      task.convId, task.id,
      patch.title ?? "", patch.description ?? "", patch.status ?? 255,
      patch.assignee ?? "", patch.priority ?? 255, patch.color ?? 255,
      patch.externalRef ?? "", patch.dueAt ?? 0n, patch.blockedBy ?? 0n,
      patch.attachments ?? null, patch.project ?? "",
      { onSuccess: ({ task: updatedTask }) => resolve(updatedTask), onError: fail },
    );
    if (!sent) fail({ message: "TASK UPDATE WAS NOT SENT" });
  });
}

function taskFieldSpec(task, field) {
  const clearText = (value, old) => value === "" && old ? "\x00" : value;
  const bytes = (value, max, name) => {
    if (new TextEncoder().encode(value).length > max) throw new Error(`${name} EXCEEDS ${max} UTF-8 BYTES`);
  };
  const specs = {
    title: { label: "TITLE", value: task.title || "", required: true, maxBytes: MAX_TASK_TITLE_LENGTH,
      save(value) { value = value.trim(); bytes(value, MAX_TASK_TITLE_LENGTH, "TITLE"); if (!value) throw new Error("TITLE REQUIRED"); return { title: value }; } },
    assignee: { label: "ASSIGNEE", value: task.assignee || "", maxBytes: MAX_ASSIGNEE_LENGTH,
      save(value) { value = value.trim(); bytes(value, MAX_ASSIGNEE_LENGTH, "ASSIGNEE"); return { assignee: clearText(value, task.assignee) }; } },
    project: { label: "PROJECT", value: task.project || "", maxBytes: MAX_PROJECT_LENGTH,
      save(value) { value = value.trim(); bytes(value, MAX_PROJECT_LENGTH, "PROJECT"); return { project: clearText(value, task.project) }; } },
    externalRef: { label: "REFERENCE", value: task.externalRef || "", maxBytes: MAX_EXTERNAL_REF_LENGTH,
      action: task.externalRef ? {
        label: /^https?:\/\//.test(task.externalRef) ? "OPEN" : "COPY",
        run: () => /^https?:\/\//.test(task.externalRef)
          ? window.open(task.externalRef, "_blank", "noopener,noreferrer")
          : navigator.clipboard.writeText(task.externalRef),
      } : null,
      save(value) { value = value.trim(); bytes(value, MAX_EXTERNAL_REF_LENGTH, "REFERENCE"); return { externalRef: clearText(value, task.externalRef) }; } },
    priority: { label: "PRIORITY", value: String(task.priority ?? 0), type: "number",
      save(value) { const number = Number(value); if (!Number.isInteger(number) || number < 0 || number > 254) throw new Error("PRIORITY MUST BE 0–254"); return { priority: number }; } },
    category: { label: "CATEGORY", value: String(task.color ?? 0), display: TaskColorNames[task.color] || "—",
      options: TaskColorNames.map((label, value) => ({ value: String(value), label })),
      save(value) { const color = Number(value); if (!Number.isInteger(color) || color < 0 || color >= TaskColorNames.length) throw new Error("INVALID CATEGORY"); return { color }; } },
    status: { label: "STATUS", value: String(task.status ?? 0), display: TaskStatusNames[task.status] || "—",
      options: TaskStatusNames.slice(0, 4).map((label, value) => ({ value: String(value), label })),
      save(value) { const status = Number(value); if (!Number.isInteger(status) || status < 0 || status > 3) throw new Error("INVALID STATUS"); return { status, moveStatus: status !== task.status }; } },
    dueAt: { label: "DUE", value: formatDateTimeLocal(task.dueAt), display: task.dueAt && task.dueAt !== 0n ? formatDueDateShort(task.dueAt) : "—", type: "datetime-local",
      save(value) { if (!value) return { dueAt: task.dueAt && task.dueAt !== 0n ? -1n : 0n }; const dueAt = parseDateTimeLocal(value); if (!dueAt) throw new Error("INVALID DUE DATE"); return { dueAt: dueAt === task.dueAt ? 0n : dueAt }; } },
    blockedBy: { label: "BLOCKED BY", value: task.blockedBy && task.blockedBy !== 0n ? String(task.blockedBy) : "", display: task.blockedBy && task.blockedBy !== 0n ? `#${task.blockedBy}` : "—",
      save(value) { const clean = value.trim().replace(/^#/, ""); if (!clean) return { blockedBy: task.blockedBy && task.blockedBy !== 0n ? UPDATE_BLOCKED_BY_CLEAR : 0n }; let blockedBy; try { blockedBy = BigInt(clean); } catch { throw new Error("BLOCKER MUST BE A TASK ID"); } if (blockedBy <= 0n) throw new Error("BLOCKER MUST BE A TASK ID"); if (blockedBy === task.id) throw new Error("A TASK CANNOT BLOCK ITSELF"); return { blockedBy: blockedBy === task.blockedBy ? 0n : blockedBy }; } },
  };
  return specs[field];
}

function taskFieldChoices(field, convId = 0n) {
  const values = new Set();
  if (field === "assignee") {
    for (const value of userDirectory()) values.add(value);
    for (const value of window.NRCTaskQuery?.getAssignees?.() || []) values.add(value);
  } else if (field === "project") {
    for (const value of window.NRCTaskQuery?.getProjects?.(convId) || []) values.add(value);
  }
  for (const task of roomTasks.get(BigInt(convId))?.values() || []) {
    if (task[field]) values.add(task[field]);
  }
  return [...values].map(String).filter(Boolean).sort((a, b) => a.localeCompare(b));
}

function fieldControl(task, field, { label, rename = false } = {}) {
  const spec = taskFieldSpec(task, field);
  if (field === "assignee" || field === "project") spec.suggestions = () => taskFieldChoices(field, task.convId);
  if (field === "blockedBy") {
    spec.options = () => {
      const options = [{ value: "", label: "— NONE" }, ...Array.from(roomTasks.get(task.convId)?.values() || [])
        .filter(candidate => candidate.id !== task.id)
        .map(candidate => ({ value: String(candidate.id), label: `#${candidate.id} · ${candidate.title}` }))];
      if (spec.value && !options.some(option => option.value === spec.value)) options.push({ value: spec.value, label: `#${spec.value}` });
      return options;
    };
  }
  if (!spec || !window.NRCDetailUI?.inlineField) return escapeHtml(spec?.display ?? spec?.value ?? "—");
  return window.NRCDetailUI.inlineField({
    ...spec,
    key: `task-${task.convId}-${task.id}-${field}`,
    name: spec.label,
    label: label ?? spec.label,
    display: rename ? "RENAME" : spec.display,
    save: async (value) => {
      const patch = taskFieldSpec(getCanonicalTask(task), field).save(String(value));
      delete patch.moveStatus;
      return taskUpdatePromise(task, patch);
    },
  });
}

function openField(anchor, task, field) {
  if (!anchor) return false;
  anchor.insertAdjacentHTML("beforebegin", fieldControl(task, field));
  anchor.previousElementSibling?.querySelector?.("button")?.click();
  return true;
}

function taskAttachmentsControl(task) {
  return window.NRCDetailUI.attachmentControl?.(task, attachments => taskUpdatePromise(getCanonicalTask(task), { attachments }), () => getCanonicalTask(task)) || "";
}

function sendUpdateTask(
  convId,
  taskId,
  title = "",
  description = "",
  status = TaskStatus.Backlog,
  assignee = "",
  priority = 255,
  color = 255,
  externalRef = "",
  dueAt = 0n,
  blockedBy = 0n,
  attachments = [],
  project = "",
  requestOptions = null,
) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) return;

  const correlationId = getRpcCorrelationId();

  const titleBytes = new TextEncoder().encode(title);
  const descBytes = new TextEncoder().encode(description);
  const assigneeBytes = new TextEncoder().encode(assignee);
  const extRefBytes = new TextEncoder().encode(externalRef);
  const projectBytes = new TextEncoder().encode(project);

  // Encode attachments
  const encodedAttachments = [];
  for (const att of attachments || []) {
    const fileIdBytes = new TextEncoder().encode(att.fileId);
    const filenameBytes = new TextEncoder().encode(att.filename);
    const mimeTypeBytes = new TextEncoder().encode(att.mimeType);

    encodedAttachments.push({
      fileId: fileIdBytes,
      filename: filenameBytes,
      size: att.size,
      mimeType: mimeTypeBytes,
      uploadedAt: att.uploadedAt,
    });
  }

  // Calculate buffer size
  // Opcode(2) + conv_id(8) + task_id(8) + title_len(2) + title + desc_len(2) + desc +
  // status(1) + assignee_len(2) + assignee + priority(1) + color(1) + ext_ref_len(2) + ext_ref +
  // due_at(8) + blocked_by(8) + att_count(2) + correlation_id(4) + project_len(2) + project
  let bufferSize =
    2 +
    8 +
    8 +
    2 +
    titleBytes.length +
    2 +
    descBytes.length +
    1 +
    2 +
    assigneeBytes.length +
    1 +
    1 +
    2 +
    extRefBytes.length +
    8 +
    8 +
    2 +
    4 +
    2 +
    projectBytes.length;

  // Add attachment sizes
  for (const att of encodedAttachments) {
    bufferSize +=
      2 +
      att.fileId.length +
      2 +
      att.filename.length +
      8 +
      2 +
      att.mimeType.length +
      8;
  }

  const buffer = new ArrayBuffer(bufferSize);
  const view = new DataView(buffer);
  let offset = 0;

  view.setUint16(offset, Opcode.C_UpdateTask, false);
  offset += 2;

  view.setBigUint64(offset, BigInt(convId), false);
  offset += 8;

  view.setBigUint64(offset, BigInt(taskId), false);
  offset += 8;

  view.setUint16(offset, titleBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, titleBytes.length).set(titleBytes);
  offset += titleBytes.length;

  view.setUint16(offset, descBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, descBytes.length).set(descBytes);
  offset += descBytes.length;

  view.setUint8(offset, status);
  offset += 1;

  view.setUint16(offset, assigneeBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, assigneeBytes.length).set(assigneeBytes);
  offset += assigneeBytes.length;

  view.setUint8(offset, priority);
  offset += 1;

  view.setUint8(offset, color);
  offset += 1;

  view.setUint16(offset, extRefBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, extRefBytes.length).set(extRefBytes);
  offset += extRefBytes.length;

  view.setBigInt64(offset, BigInt(dueAt), false);
  offset += 8;

  view.setBigUint64(offset, BigInt(blockedBy), false);
  offset += 8;

  // Encode attachments count
  view.setUint16(offset, attachments === null ? 0xffff : encodedAttachments.length, false);
  offset += 2;

  // Encode each attachment
  for (const att of encodedAttachments) {
    view.setUint16(offset, att.fileId.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, att.fileId.length).set(att.fileId);
    offset += att.fileId.length;

    view.setUint16(offset, att.filename.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, att.filename.length).set(att.filename);
    offset += att.filename.length;

    view.setBigUint64(offset, att.size, false);
    offset += 8;

    view.setUint16(offset, att.mimeType.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, att.mimeType.length).set(att.mimeType);
    offset += att.mimeType.length;

    view.setBigInt64(offset, att.uploadedAt, false);
    offset += 8;
  }

  view.setUint32(offset, correlationId, false);
  offset += 4;

  view.setUint16(offset, projectBytes.length, false);
  offset += 2;
  new Uint8Array(buffer, offset, projectBytes.length).set(projectBytes);
  offset += projectBytes.length;

  // Track this update to skip self-notification
  pendingTaskUpdateCorrelations.add(correlationId);
  if (requestOptions && typeof requestOptions === "object") {
    pendingTaskRpcs.set(correlationId, {
      onSuccess: requestOptions.onSuccess,
      onError: requestOptions.onError,
    });
  }

  ws.send(buffer);
  localPacketsOut++;
  return correlationId;
}

function sendDeleteTask(convId, taskId) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = getRpcCorrelationId();

  // Opcode(2) + conv_id(8) + task_id(8) + correlation_id(4)
  const buffer = new ArrayBuffer(22);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_DeleteTask, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setBigUint64(10, BigInt(taskId), false);
  view.setUint32(18, correlationId, false);

  // Track this delete to skip self-notification
  pendingTaskDeletes.add(BigInt(taskId));

  ws.send(buffer);
  localPacketsOut++;
}

// A move asks the server for the end of the target column instead of naming a
// position: a register draws one page at a time, so the client does not hold the
// column, and the order is the server's to fold. The acknowledgement carries the
// folded position. Mirrors protocol MoveTaskFlag_APPEND.
function sendMoveTask(convId, taskId, status, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) return;

  const correlationId = getRpcCorrelationId();

  // Opcode(2) + conv_id(8) + task_id(8) + status(1) + flags(1) + order_index(2) + correlation_id(4)
  const buffer = new ArrayBuffer(26);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_MoveTask, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setBigUint64(10, BigInt(taskId), false);
  view.setUint8(18, status);
  view.setUint8(19, TASK_MOVE_APPEND);
  // The position the flag asks for is the server's to fold.
  view.setUint16(20, 0, false);
  view.setUint32(22, correlationId, false);

  if (requestOptions && typeof requestOptions === "object") {
    pendingTaskRpcs.set(correlationId, {
      onSuccess: requestOptions.onSuccess,
      onError: requestOptions.onError,
    });
  }

  ws.send(buffer);
  localPacketsOut++;
  return correlationId;
}

function sendGetTasks(convId) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const correlationId = getRpcCorrelationId();

  // Opcode(2) + conv_id(8) + correlation_id(4)
  const buffer = new ArrayBuffer(14);
  const view = new DataView(buffer);

  view.setUint16(0, Opcode.C_GetTasks, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setUint32(10, correlationId, false);

  ws.send(buffer);
  localPacketsOut++;
}

const ACTIVE_TASK_MASK = 0x07;
const DONE_TASK_MASK = 0x08;
const ALL_TASK_MASK = 0x1f;
const TASK_PAGE_SIZE = 100;

function taskPageKey(convId, statusMask) {
  return `0:${statusMask}`;
}

function getTaskPageState(convId, statusMask) {
  const key = taskPageKey(convId, statusMask);
  if (!taskPageState.has(key)) {
    taskPageState.set(key, { loaded: false, loading: false, hasMore: true, cursorSortAt: null, cursorTaskId: null, totalCount: 0 });
  }
  return taskPageState.get(key);
}

function sendListTasksPaged(convId, statusMask, limit = TASK_PAGE_SIZE, cursorSortAt = null, cursorTaskId = null, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) return;
  const correlationId = getRpcCorrelationId();
  const hasCursor = cursorSortAt !== null && cursorTaskId !== null;
  const buffer = new ArrayBuffer(2 + 8 + 1 + 2 + 1 + (hasCursor ? 16 : 0) + 4);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint16(offset, Opcode.C_ListTasksPaged, false); offset += 2;
  view.setBigUint64(offset, BigInt(convId), false); offset += 8;
  view.setUint8(offset, statusMask); offset += 1;
  view.setUint16(offset, limit, false); offset += 2;
  view.setUint8(offset, hasCursor ? 1 : 0); offset += 1;
  if (hasCursor) {
    view.setBigInt64(offset, BigInt(cursorSortAt), false); offset += 8;
    view.setBigUint64(offset, BigInt(cursorTaskId), false); offset += 8;
  }
  view.setUint32(offset, correlationId, false);
  pendingTaskRpcs.set(correlationId, { ...requestOptions, convId: BigInt(convId), statusMask, firstPage: !hasCursor });
  ws.send(buffer);
  localPacketsOut++;
  return correlationId;
}

function sendGetTask(convId, taskId, requestOptions = null) {
  convId = 0n;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) return;
  const correlationId = getRpcCorrelationId();
  const buffer = new ArrayBuffer(22);
  const view = new DataView(buffer);
  view.setUint16(0, Opcode.C_GetTask, false);
  view.setBigUint64(2, BigInt(convId), false);
  view.setBigUint64(10, BigInt(taskId), false);
  view.setUint32(18, correlationId, false);
  pendingTaskRpcs.set(correlationId, { ...requestOptions, convId: BigInt(convId), taskId: BigInt(taskId) });
  ws.send(buffer);
  localPacketsOut++;
  return correlationId;
}

function loadTaskPage(convId, statusMask, { reset = false } = {}) {
  convId = 0n;
  const state = getTaskPageState(convId, statusMask);
  if (state.loading) return state.promise;
  if (!reset && state.loaded && !state.hasMore) return Promise.resolve(state);
  if (reset) Object.assign(state, { loaded: false, hasMore: true, cursorSortAt: null, cursorTaskId: null });
  state.loading = true;
  state.promise = new Promise((resolve, reject) => {
    const sent = sendListTasksPaged(convId, statusMask, TASK_PAGE_SIZE, state.cursorSortAt, state.cursorTaskId, {
      onSuccess: (result) => { state.loading = false; resolve(result); },
      onError: (error) => { state.loading = false; reject(error); },
    });
    if (sent === undefined) { state.loading = false; reject(new Error("Task transport unavailable")); }
  });
  return state.promise;
}

async function drainTaskPages(convId, statusMask, { reset = false } = {}) {
  let first = true;
  do {
    await loadTaskPage(convId, statusMask, { reset: reset && first });
    first = false;
  } while (getTaskPageState(convId, statusMask).hasMore);
  return getTaskPageState(convId, statusMask);
}

function loadActiveTasks(convId) {
  return drainTaskPages(convId, ACTIVE_TASK_MASK, { reset: true })
    .then((state) => {
      logSystem(`LOADED ${state.totalCount} WORKSPACE TASKS`, "tasks", "DEBUG");
      return state;
    })
    .catch((err) => console.warn("[NRCTasks] Active task load failed:", err));
}

function requestTask(convId, taskId, requestOptions = null) {
  const normalizedConvId = 0n;
  const normalizedTaskId = BigInt(taskId);
  const cached = roomTasks.get(normalizedConvId)?.get(normalizedTaskId);
  if (cached) { requestOptions?.onSuccess?.({ task: cached }); return cached; }

  const key = `${normalizedConvId}:${normalizedTaskId}`;
  const subscriber = requestOptions && typeof requestOptions === "object" ? requestOptions : null;
  const pending = pendingExactTaskRequests.get(key);
  if (pending) {
    if (subscriber) pending.subscribers.push(subscriber);
    return pending.correlationId;
  }
  const entry = { correlationId: undefined, subscribers: subscriber ? [subscriber] : [] };
  pendingExactTaskRequests.set(key, entry);
  const settle = (callbackName, detail) => {
    if (pendingExactTaskRequests.get(key) !== entry) return;
    pendingExactTaskRequests.delete(key);
    for (const options of entry.subscribers) {
      try {
        options[callbackName]?.(detail);
      } catch (error) {
        console.error(`[NRCTasks] Exact task ${callbackName} callback failed`, error);
      }
    }
  };
  entry.correlationId = sendGetTask(normalizedConvId, normalizedTaskId, {
    onSuccess: (detail) => settle("onSuccess", detail),
    onError: (detail) => settle("onError", detail),
  });
  if (entry.correlationId === undefined) settle("onError", { message: "Task transport unavailable" });
  return entry.correlationId;
}

// =============================================================================
// PROTOCOL: MESSAGE PARSERS
// =============================================================================

function parseTask(dataView, offset) {
  const task = {};

  task.id = dataView.getBigUint64(offset, false);
  offset += 8;

  task.convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const titleLen = dataView.getUint16(offset, false);
  offset += 2;
  const titleBytes = new Uint8Array(dataView.buffer, offset, titleLen);
  task.title = new TextDecoder().decode(titleBytes);
  offset += titleLen;

  const descLen = dataView.getUint16(offset, false);
  offset += 2;
  const descBytes = new Uint8Array(dataView.buffer, offset, descLen);
  task.description = new TextDecoder().decode(descBytes);
  offset += descLen;

  task.status = dataView.getUint8(offset);
  offset += 1;

  task.orderIndex = dataView.getUint16(offset, false);
  offset += 2;

  const assigneeLen = dataView.getUint16(offset, false);
  offset += 2;
  const assigneeBytes = new Uint8Array(dataView.buffer, offset, assigneeLen);
  task.assignee = new TextDecoder().decode(assigneeBytes);
  offset += assigneeLen;

  task.priority = dataView.getUint8(offset);
  offset += 1;

  task.color = dataView.getUint8(offset);
  offset += 1;

  const createdByLen = dataView.getUint16(offset, false);
  offset += 2;
  const createdByBytes = new Uint8Array(dataView.buffer, offset, createdByLen);
  task.createdBy = new TextDecoder().decode(createdByBytes);
  offset += createdByLen;

  task.createdAt = dataView.getBigInt64(offset, false);
  offset += 8;

  task.updatedAt = dataView.getBigInt64(offset, false);
  offset += 8;

  const extRefLen = dataView.getUint16(offset, false);
  offset += 2;
  const extRefBytes = new Uint8Array(dataView.buffer, offset, extRefLen);
  task.externalRef = new TextDecoder().decode(extRefBytes);
  offset += extRefLen;

  // New fields: dueAt, blockedBy, completedAt, completedBy
  task.dueAt = dataView.getBigInt64(offset, false);
  offset += 8;

  task.blockedBy = dataView.getBigUint64(offset, false);
  offset += 8;

  task.completedAt = dataView.getBigInt64(offset, false);
  offset += 8;

  const completedByLen = dataView.getUint16(offset, false);
  offset += 2;
  const completedByBytes = new Uint8Array(
    dataView.buffer,
    offset,
    completedByLen,
  );
  task.completedBy = new TextDecoder().decode(completedByBytes);
  offset += completedByLen;

  const projectLen = dataView.getUint16(offset, false);
  offset += 2;
  const projectBytes = new Uint8Array(dataView.buffer, offset, projectLen);
  task.project = new TextDecoder().decode(projectBytes);
  offset += projectLen;

  // Parse attachments array
  task.attachments = [];
  const attachmentCount = dataView.getUint16(offset, false);
  offset += 2;

  for (let i = 0; i < attachmentCount; i++) {
    // fileId (string with u16 length prefix)
    const fileIdLen = dataView.getUint16(offset, false);
    offset += 2;
    const fileIdBytes = new Uint8Array(dataView.buffer, offset, fileIdLen);
    const fileId = new TextDecoder().decode(fileIdBytes);
    offset += fileIdLen;

    // filename (string with u16 length prefix)
    const filenameLen = dataView.getUint16(offset, false);
    offset += 2;
    const filenameBytes = new Uint8Array(dataView.buffer, offset, filenameLen);
    const filename = new TextDecoder().decode(filenameBytes);
    offset += filenameLen;

    // size (u64)
    const size = dataView.getBigUint64(offset, false);
    offset += 8;

    // mimeType (string with u16 length prefix)
    const mimeLen = dataView.getUint16(offset, false);
    offset += 2;
    const mimeBytes = new Uint8Array(dataView.buffer, offset, mimeLen);
    const mimeType = new TextDecoder().decode(mimeBytes);
    offset += mimeLen;

    // uploadedAt (i64)
    const uploadedAt = dataView.getBigInt64(offset, false);
    offset += 8;

    task.attachments.push({
      fileId,
      filename,
      size,
      mimeType,
      uploadedAt,
    });
  }

  return { task, newOffset: offset };
}

function readTaskWireString(dataView, offset) {
  const length = dataView.getUint16(offset, false);
  offset += 2;
  const value = new TextDecoder().decode(new Uint8Array(dataView.buffer, offset, length));
  return { value, newOffset: offset + length };
}

function maskIncludesStatus(mask, status) {
  return status >= 0 && status < 8 && (mask & (1 << status)) !== 0;
}

function isTaskStatusCacheLoaded(convId, status) {
  return getTaskPageState(convId, ALL_TASK_MASK).loaded ||
    (status === TaskStatus.Done
      ? getTaskPageState(convId, DONE_TASK_MASK).loaded
      : status <= TaskStatus.InProgress && getTaskPageState(convId, ACTIVE_TASK_MASK).loaded);
}

function handleTaskListPage(dataView) {
  let offset = 2;
  const convId = dataView.getBigUint64(offset, false); offset += 8;
  const success = dataView.getUint8(offset) !== 0; offset += 1;
  const taskCount = dataView.getUint16(offset, false); offset += 2;
  const tasks = [];
  for (let i = 0; i < taskCount; i++) {
    const parsed = parseTask(dataView, offset);
    tasks.push(parsed.task);
    offset = parsed.newOffset;
  }
  const hasMore = dataView.getUint8(offset) !== 0; offset += 1;
  const nextCursorSortAt = dataView.getBigInt64(offset, false); offset += 8;
  const nextCursorTaskId = dataView.getBigUint64(offset, false); offset += 8;
  const totalCount = dataView.getUint32(offset, false); offset += 4;
  const error = readTaskWireString(dataView, offset); offset = error.newOffset;
  if (dataView.byteLength < offset + 4) return console.error("S_TaskListPage missing correlation_id");
  const correlationId = dataView.getUint32(offset, false);
  const pending = pendingTaskRpcs.get(correlationId);
  if (!pending) return console.warn("[S_TaskListPage] Unknown correlation:", correlationId);
  pendingTaskRpcs.delete(correlationId);
  const state = getTaskPageState(convId, pending.statusMask);

  if (!success) {
    pending.onError?.({ convId, correlationId, message: error.value });
    return;
  }

  if (!roomTasks.has(convId)) roomTasks.set(convId, new Map());
  const tasksMap = roomTasks.get(convId);
  if (pending.firstPage) {
    for (const [id, task] of tasksMap) {
      if (maskIncludesStatus(pending.statusMask, task.status)) tasksMap.delete(id);
    }
  }
  for (const task of tasks) tasksMap.set(task.id, task);
  invalidateTaskList(convId);
  Object.assign(state, {
    loaded: true,
    hasMore,
    cursorSortAt: hasMore ? nextCursorSortAt : null,
    cursorTaskId: hasMore ? nextCursorTaskId : null,
    totalCount,
  });
  pending.onSuccess?.({ convId, tasks, hasMore, nextCursorSortAt, nextCursorTaskId, totalCount, correlationId });
  if (convId === 0n && kanbanVisible) renderCurrentTaskView();
}

function handleTaskFull(dataView) {
  let offset = 2;
  const convId = dataView.getBigUint64(offset, false); offset += 8;
  const success = dataView.getUint8(offset) !== 0; offset += 1;
  const hasTask = dataView.getUint8(offset) !== 0; offset += 1;
  let task = null;
  if (hasTask) {
    const parsed = parseTask(dataView, offset);
    task = parsed.task;
    offset = parsed.newOffset;
  }
  const error = readTaskWireString(dataView, offset); offset = error.newOffset;
  if (dataView.byteLength < offset + 4) return console.error("S_TaskFull missing correlation_id");
  const correlationId = dataView.getUint32(offset, false);
  const pending = pendingTaskRpcs.get(correlationId);
  if (pending) pendingTaskRpcs.delete(correlationId);
  if (!success || !hasTask) {
    pending?.onError?.({ convId, correlationId, message: error.value || "Task not found" });
    return;
  }
  if (!roomTasks.has(convId)) roomTasks.set(convId, new Map());
  roomTasks.get(convId).set(task.id, task);
  invalidateTaskList(convId);
  pending?.onSuccess?.({ convId, task, correlationId });
  if (convId === 0n && kanbanVisible) renderCurrentTaskView();
}

function handleTaskCreated(dataView) {
  // Skip opcode (2 bytes)
  const { task, newOffset } = parseTask(dataView, 2);
  if (dataView.byteLength < newOffset + 4) {
    console.error("S_TaskCreated missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(newOffset, false);
  const pendingRpc = pendingTaskRpcs.get(correlationId);
  if (pendingRpc) {
    pendingTaskRpcs.delete(correlationId);
    if (typeof pendingRpc.onSuccess === "function") {
      pendingRpc.onSuccess({ task, correlationId });
    }
  }

  // Store only statuses whose partial cache is present. Active creates are retained
  // during startup as that cache is being drained.
  if (!roomTasks.has(task.convId)) {
    roomTasks.set(task.convId, new Map());
  }
  if (task.status !== TaskStatus.Done || isTaskStatusCacheLoaded(task.convId, task.status)) {
    roomTasks.get(task.convId).set(task.id, task);
  }
  invalidateTaskList(task.convId);
  refreshTaskSearchAfterMutation(task.convId);

  // Update UI if viewing this room's tasks
  if (task.convId === 0n && kanbanVisible) {
    renderCurrentTaskView();
  }

  logSystem(`TASK #${task.id} CREATED: "${task.title}"`, "tasks");

  // Notify if task is assigned to current user (and not created by them)
  if (
    task.assignee &&
    task.assignee === myNickname &&
    task.createdBy !== myNickname
  ) {
    sendNotification("Task Assigned", { body: task.title });
  }

  notifyTaskChanged(task, "created");
  document.dispatchEvent(new CustomEvent("nrc:task-created", { detail: { task, correlationId } }));
}

function handleTaskErrorResponse(originOpcode, correlationId, errorMsg = "") {
  if (originOpcode !== Opcode.C_CreateTask && originOpcode !== Opcode.C_UpdateTask && originOpcode !== Opcode.C_MoveTask && originOpcode !== Opcode.C_GetTask) return false;
  const pendingRpc = pendingTaskRpcs.get(correlationId);
  if (!pendingRpc) return false;
  pendingTaskRpcs.delete(correlationId);
  pendingTaskUpdateCorrelations.delete(correlationId);
  if (typeof pendingRpc.onError === "function") {
    pendingRpc.onError({ correlationId, message: errorMsg || "Task request failed" });
  }
  return true;
}

function handleTaskUpdated(dataView) {
  // Skip opcode (2 bytes)
  const { task, newOffset } = parseTask(dataView, 2);
  if (dataView.byteLength < newOffset + 4) {
    console.error("S_TaskUpdated missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(newOffset, false);

  // Get old task for comparison (before updating store)
  const oldTask = roomTasks.has(task.convId)
    ? roomTasks.get(task.convId).get(task.id)
    : null;

  // Update task in store
  if (!roomTasks.has(task.convId)) {
    roomTasks.set(task.convId, new Map());
  }
  if (task.status !== TaskStatus.Done || isTaskStatusCacheLoaded(task.convId, task.status)) {
    roomTasks.get(task.convId).set(task.id, task);
  } else {
    roomTasks.get(task.convId).delete(task.id);
  }
  invalidateTaskList(task.convId);
  refreshTaskSearchAfterMutation(task.convId);

  const pendingRpc = pendingTaskRpcs.get(correlationId);
  if (pendingRpc) {
    pendingTaskRpcs.delete(correlationId);
    if (typeof pendingRpc.onSuccess === "function") {
      pendingRpc.onSuccess({ task, correlationId });
    }
  }

  if (
    selectedTaskId === task.id &&
    selectedTaskConvId === task.convId
  ) {
    currentDetailTask = task;
    if (descriptionFocusMode) enterDescriptionFocus();
    else {
      const workflow = document.querySelector('[data-detail-section="workflow"] .detail-edit-grid');
      const people = document.querySelector('[data-detail-section="people"] .detail-edit-grid');
      if (workflow) workflow.innerHTML = ["status", "priority", "category", "dueAt"].map(field => fieldControl(task, field)).join("");
      if (people) people.innerHTML = ["assignee", "blockedBy", "project", "externalRef", "title"].map(field => fieldControl(task, field)).join("");
    }
  }

  // Update UI if viewing this room's tasks
  if (task.convId === 0n && kanbanVisible) {
    renderCurrentTaskView();
  }

  logSystem(`TASK UPDATED: ${task.title}`, "tasks");

  // Derived views also need our own acknowledged edits; only the desktop
  // notification below is suppressed for the requester.
  notifyTaskChanged(task, "updated");

  // Skip notification if this was our own update
  if (pendingTaskUpdateCorrelations.has(correlationId)) {
    pendingTaskUpdateCorrelations.delete(correlationId);
    return;
  }

  // Notify if your task was modified or newly assigned to you
  const wasAssignedToMe = oldTask && oldTask.assignee === myNickname;
  const isAssignedToMe = task.assignee === myNickname;
  if (isAssignedToMe && !wasAssignedToMe) {
    sendNotification("Task Assigned", { body: task.title });
  } else if (wasAssignedToMe && isAssignedToMe) {
    sendNotification("Task Updated", { body: task.title });
  }
}

// Derived views refresh on a mutation instead of polling: the attention
// register, the reminder timer and anything else that reads task state.
function notifyTaskChanged(task, reason) {
  document.dispatchEvent(new CustomEvent("nrc:task-changed", { detail: { task, reason } }));
}

function handleTaskDeleted(dataView) {
  // Skip opcode (2 bytes)
  let offset = 2;

  const taskId = dataView.getBigUint64(offset, false);
  offset += 8;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  if (dataView.byteLength < offset + 4) {
    console.error("S_TaskDeleted missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);

  // Remove from store
  if (roomTasks.has(convId)) {
    const tasks = roomTasks.get(convId);
    const task = tasks.get(taskId);
    const taskTitle = task ? task.title : `#${taskId}`;

    // Notify if your task was deleted (but not if you deleted it yourself)
    if (pendingTaskDeletes.has(taskId)) {
      pendingTaskDeletes.delete(taskId);
    } else if (task && task.assignee === myNickname) {
      sendNotification("Task Deleted", { body: taskTitle });
    }

    tasks.delete(taskId);
    invalidateTaskList(convId);

    logSystem(`TASK #${taskId} DELETED`, "tasks");
  }
  notifyTaskChanged({ id: taskId, convId }, "deleted");

  if (selectedTaskId === taskId && selectedTaskConvId === convId) {
    if (!window.NRCInspector?.entityDeleted?.({ roomId: convId, type: "task", id: taskId })) {
      clearTaskSelection({ fromInspector: true });
    }
  }
  refreshTaskSearchAfterMutation(convId);

  // Update UI if viewing this room's tasks
  if (convId === 0n && kanbanVisible) {
    renderCurrentTaskView();
  }

  if (correlationId) {
    console.debug("[S_TaskDeleted] correlation_id:", correlationId);
  }
}

function handleTaskMoved(dataView) {
  // Skip opcode (2 bytes)
  let offset = 2;

  const taskId = dataView.getBigUint64(offset, false);
  offset += 8;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const status = dataView.getUint8(offset);
  offset += 1;

  const orderIndex = dataView.getUint16(offset, false);
  offset += 2;

  const completedAt = dataView.getBigInt64(offset, false);
  offset += 8;

  const completedByLen = dataView.getUint16(offset, false);
  offset += 2;
  const completedByBytes = new Uint8Array(
    dataView.buffer,
    offset,
    completedByLen,
  );
  const completedBy = new TextDecoder().decode(completedByBytes);
  offset += completedByLen;

  if (dataView.byteLength < offset + 4) {
    console.error("S_TaskMoved missing correlation_id");
    return;
  }
  const correlationId = dataView.getUint32(offset, false);

  const pendingRpc = pendingTaskRpcs.get(correlationId);
  if (pendingRpc) {
    pendingTaskRpcs.delete(correlationId);
    if (typeof pendingRpc.onSuccess === "function") {
      pendingRpc.onSuccess({ convId, taskId, status, orderIndex, correlationId });
    }
  }

  // S_TaskMoved has no full task body. Remove entries which moved outside the
  // loaded partial cache, and retrieve the body when they enter one.
  let enteredLoadedCache = false;
  if (roomTasks.has(convId)) {
    const tasks = roomTasks.get(convId);
    const task = tasks.get(taskId);
    if (task) {
      const prevStatus = task.status;
      enteredLoadedCache = prevStatus !== status && isTaskStatusCacheLoaded(convId, status);
      if (!isTaskStatusCacheLoaded(convId, status)) {
        tasks.delete(taskId);
      } else {
        task.status = status;
        task.orderIndex = orderIndex;
        task.completedAt = completedAt;
        task.completedBy = completedBy;
      }

      if (prevStatus !== status) {
        logSystem(`TASK #${taskId} MOVED: ${TaskStatusNames[prevStatus]} → ${TaskStatusNames[status]}`, "tasks");
      }

      // Notify if your task was moved to Done by someone else
      if (
        task.assignee === myNickname &&
        status === TaskStatus.Done &&
        prevStatus !== TaskStatus.Done &&
        completedBy !== myNickname
      ) {
        sendNotification("Task Completed", {
          body: `${task.title} marked done by ${completedBy}`,
        });
      }
    }
  }
  if (!roomTasks.get(convId)?.has(taskId) && isTaskStatusCacheLoaded(convId, status)) {
    enteredLoadedCache = true;
  }
  // A move into a status window the register does not hold takes the task out of
  // the partial cache, and the tables that hold their own snapshot of it — a
  // slice's member list — keep the status the server just confirmed.
  window.NRCSlices?.onTaskMoved?.(taskId, status, orderIndex);
  invalidateTaskList(convId);
  if (enteredLoadedCache) sendGetTask(convId, taskId);
  refreshTaskSearchAfterMutation(convId);

  // Update UI if viewing this room's tasks
  if (kanbanVisible && convId === 0n) {
    renderCurrentTaskView();
  }
  syncDetailPanelStatus(convId, taskId, status);

  notifyTaskChanged({ id: taskId, convId, status }, "moved");

  if (correlationId) {
    console.debug("[S_TaskMoved] correlation_id:", correlationId);
  }
}

function handleTaskListResponse(dataView) {
  // Skip opcode (2 bytes)
  let offset = 2;

  const convId = dataView.getBigUint64(offset, false);
  offset += 8;

  const success = dataView.getUint8(offset) !== 0;
  offset += 1;

  const taskCount = dataView.getUint16(offset, false);
  offset += 2;

  if (!success) {
    // Skip to error
    for (let i = 0; i < taskCount; i++) {
      const { newOffset } = parseTask(dataView, offset);
      offset = newOffset;
    }
    const errorLen = dataView.getUint16(offset, false);
    offset += 2;
    const errorBytes = new Uint8Array(dataView.buffer, offset, errorLen);
    const errorMsg = new TextDecoder().decode(errorBytes);
    offset += errorLen;
    if (dataView.byteLength < offset + 4) {
      console.error("S_TaskListResponse missing correlation_id");
      return;
    }
    const correlationId = dataView.getUint32(offset, false);
    pendingTaskUpdateCorrelations.delete(correlationId);
    const pendingRpc = pendingTaskRpcs.get(correlationId);
    if (pendingRpc) {
      pendingTaskRpcs.delete(correlationId);
      if (typeof pendingRpc.onError === "function") {
        pendingRpc.onError({ convId, correlationId, message: errorMsg });
      }
    }
    logMessage("Error", `TASK LIST ERROR: ${errorMsg}`);
    return;
  }

  // Clear existing tasks for this room and repopulate
  roomTasks.set(convId, new Map());
  const tasksMap = roomTasks.get(convId);

  for (let i = 0; i < taskCount; i++) {
    const { task, newOffset } = parseTask(dataView, offset);
    offset = newOffset;
    tasksMap.set(task.id, task);
  }
  invalidateTaskList(convId);

  if (selectedTaskId && selectedTaskConvId === convId && !tasksMap.has(selectedTaskId)) {
    if (!window.NRCInspector?.entityDeleted?.({ roomId: convId, type: "task", id: selectedTaskId })) {
      clearTaskSelection({ fromInspector: true });
    }
  }

  const errorLen = dataView.getUint16(offset, false);
  offset += 2 + errorLen;
  if (dataView.byteLength < offset + 4) {
    console.error("S_TaskListResponse missing correlation_id");
    return;
  }

  logSystem(`LOADED ${taskCount} WORKSPACE TASKS`, "tasks", "DEBUG");

  // Update UI if viewing this room's tasks
  if (convId === 0n && kanbanVisible) {
    renderCurrentTaskView();
  }

  if (selectedTaskId && selectedTaskConvId === convId && descriptionFocusMode) {
    const selectedTask = tasksMap.get(selectedTaskId);
    if (selectedTask) {
      currentDetailTask = selectedTask;
      enterDescriptionFocus();
    }
  }
}

function clearPendingTaskRpcs() {
  window.NRCTaskQuery?.disconnect();
  // The register's headless controller holds its own pending page and has to be
  // dropped with the connection, or a reconnect would answer a dead request.
  window.NRCAttention?.disconnect?.();
  const pendingRequests = [...pendingTaskRpcs];
  pendingTaskRpcs.clear();
  pendingTaskUpdateCorrelations.clear();
  taskPageState.clear();
  roomTasks.clear();
  renderedTaskListRoomId = null;
  taskListDirty = true;
  for (const [correlationId, pending] of pendingRequests) {
    try {
      pending.onError?.({ correlationId, message: "Connection closed before task request acknowledgement" });
    } catch (error) {
      console.error("[NRCTasks] Disconnect callback failed", error);
    }
  }
}

// =============================================================================
// UI: TASKS VIEW
// =============================================================================

function toggleKanban() {
  if (kanbanVisible) {
    hideKanban();
  } else {
    showKanban();
  }
}

// Note: toggleNotesView, showNotesView, hideNotesView moved to notes.js

function showKanban() {
  if (window.NRCViewManager) {
    window.NRCViewManager.setActiveView("kanban");
  }

  // Activating the view must not force a redraw of a register that is already
  // current: the flat task list keeps its virtual list across view switches, and
  // renderTaskList rebuilds it. Only a grouping change or a mutation redraws.
  if (TaskViewState.grouping === "flat") {
    window.NRCTaskQuery?.update();
    renderTaskListIfNeeded();
    if (window.NRCTasks && window.NRCTasks.renderReminderQueue) {
      window.NRCTasks.renderReminderQueue();
    }
    return;
  }
  renderCurrentTaskView();
}

function hideKanban() {
  if (window.NRCViewManager) {
    window.NRCViewManager.setActiveView("chat");
  }
}

function toggleReminders() {
  if (remindersVisible) {
    hideReminders();
  } else {
    showReminders();
  }
}

function showReminders() {
  if (window.NRCViewManager) {
    window.NRCViewManager.setActiveView("reminders");
  }
  renderReminderQueue();
}

function hideReminders() {
  if (window.NRCViewManager) {
    window.NRCViewManager.setActiveView("chat");
  }
}

function prepareTaskRender() {
  const tasksMap = roomTasks.get(0n);
  const searchState = window.NRCTaskSearch?.getState?.();
  const queryState = window.NRCTaskQuery?.getState();
  const querying = !TaskViewState.filters.search && queryState?.roomId === 0n && queryState.mode !== "idle";
  const searching = Boolean(
    TaskViewState.filters.search &&
    searchState &&
    searchState.query === TaskViewState.filters.search &&
    searchState.roomId === 0n,
  );
  let sourceTasks = tasksMap;
  let applyTextSearch = true;
  let ranked = false;
  let filtered;
  if (querying) {
    sourceTasks = queryState.tasks;
    filtered = Array.from(sourceTasks.values());
    ranked = true; // Preserve the server's global order across page boundaries.
  } else if (searching && searchState.mode === "results") {
    sourceTasks = new Map();
    for (const [id, resultTask] of searchState.tasks) {
      sourceTasks.set(id, tasksMap?.get(id) || resultTask);
    }
    applyTextSearch = false;
    ranked = true;
    // Exact facets were applied by nrc-search before top-N. Do not post-filter
    // its ranked result set and accidentally change the shared filter contract.
    filtered = Array.from(sourceTasks.values());
  } else if (searching && searchState.mode === "loading") {
    sourceTasks = new Map();
    applyTextSearch = false;
    ranked = true;
  }
  if (!filtered) filtered = getFilteredTasks(sourceTasks, { applyTextSearch });
  const taskResultsCount = document.getElementById("taskResultsCount");
  if (taskResultsCount) {
    const total = sourceTasks?.size || 0;
    if (querying) taskResultsCount.textContent = queryState.mode === "error"
      ? `${total} LOADED · QUERY FAILED`
      : queryState.mode === "loading" ? `${total} LOADED · LOADING…`
      // The server says how many tasks the filters match and the register draws
      // the pages it has asked for: the head reads N / M RESULTS while part of
      // the listing is drawn and M RESULTS once all of it is, like the slice
      // register's N / M SLICES.
      : queryState.hasMore ? `${total} / ${queryState.total} RESULTS`
      : `${queryState.total} RESULTS`;
    else if (searching && searchState.mode === "loading") taskResultsCount.textContent = "SEARCHING…";
    else if (searching && searchState.mode === "fallback") taskResultsCount.textContent = `${filtered.length} LOCAL RESULTS`;
    else if (searching && searchState.stale) taskResultsCount.textContent = `${filtered.length} RESULTS · INDEX STALE`;
    else taskResultsCount.textContent = filtered.length === total
      ? `${total} RESULTS`
      : `${filtered.length} / ${total} RESULTS`;
  }

  const metrics = calculateMetrics(new Map(filtered.map((task) => [task.id, task])));
  currentMetrics = metrics;
  updateMetricsDisplay(metrics);
  updateFilterStatus();
  if (typeof populateAssigneeFilter === "function") {
    populateAssigneeFilter();
  }
  if (typeof populateProjectFilter === "function") {
    populateProjectFilter();
  }

  return { tasksMap, filtered, searchState: searching ? searchState : null, queryState: querying ? queryState : null, ranked };
}

function loadMoreTasksNearEnd() {
  const scroller = document.getElementById("taskListView");
  const query = window.NRCTaskQuery;
  const state = query?.getState?.();
  if (
    !scroller || scroller.clientHeight <= 0 ||
    TaskViewState.filters.search || state?.mode !== "results" || !state.hasMore
  ) return;

  const remaining = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
  if (remaining <= 400) query.loadMore();
}

// =============================================================================
// LIST VIEW RENDERING
// =============================================================================

function renderTaskListIfNeeded() {
  const searchState = window.NRCTaskSearch?.getState?.() || null;
  if (Date.now() >= taskListValidUntilMs && TaskViewState.filters.overdue) {
    window.NRCTaskQuery?.update({ force: true });
  }
  if (
    !taskListDirty &&
    renderedTaskListRoomId === 0n &&
    renderedTaskSearchState === searchState &&
    Date.now() < taskListValidUntilMs
  ) return;
  renderTaskList();
}

function getTaskListValidUntil(tasksMap) {
  let validUntilMs = Infinity;
  const nowNanos = BigInt(Date.now()) * 1000000n;
  for (const task of tasksMap?.values() || []) {
    if (!task.dueAt || task.dueAt === 0n || task.status === TaskStatus.Done || task.dueAt < nowNanos) continue;
    validUntilMs = Math.min(validUntilMs, Number(task.dueAt / 1000000n) + 1);
  }
  return validUntilMs;
}

function renderTaskList() {
  const tbody = document.getElementById("taskListBody");
  if (!tbody) return;
  // Keep the native drag source alive across incoming pages, mutations and
  // comment counts. Drop reads canonical state; dragend flushes one rebuild.
  if (draggedRow) {
    taskListDirty = true;
    return;
  }

  const validUntilMs = getTaskListValidUntil(roomTasks.get(0n));
  const { filtered, searchState, queryState, ranked } = prepareTaskRender();
  const sorted = ranked ? filtered : getSortedTasks(filtered);

  window.NRCColumnResize?.init({
    root: ".task-table", headers: "thead th", storageKey: "nrc.task.columns.v1",
    defaults: [16, 48, 52, 280, 104, 110, 120, 86, 48, 64, 48, 48, 70, 72],
    minimums: [16, 48, 44, 160, 84, 72, 88, 72, 40, 48, 40, 40, 56, 56],
    locked: [0],
    apply: (table, widths) => {
      table.style.tableLayout = "fixed";
      // Let TITLE absorb spare space instead of the native table distributing
      // it across every column (which makes a 48px ID render wider than 48px).
      // The hidden marker consumes no space; TITLE retains its resized minimum.
      const fixedWidth = widths.reduce((sum, width, index) => sum + (index === 0 || index === 3 ? 0 : width), 0);
      table.querySelectorAll("thead th").forEach((cell, index) => {
        if (widths[index]) cell.style.width = index === 3
          ? `max(${widths[index]}px, calc(100% - ${fixedWidth}px))`
          : `${widths[index]}px`;
      });
    },
  });

  updateSortHeaders();

  if (!tbody.virtualList) {
    window.NRCVirtualList?.capture(tbody, document.getElementById("taskListView"),
      tbody.querySelectorAll("tr[data-task-id]"), (row) => `${row.dataset.convId}:${row.dataset.taskId}`);
  }
  tbody.virtualList?.destroy();
  tbody.virtualList = null;
  // The register is rebuilt from the tasks, so an open status menu whose token is
  // one of these rows closes with it; a menu in another table is not this
  // register's business.
  closeStatusMenuFor(tbody);
  tbody.innerHTML = "";

  if (sorted.length === 0) {
    let message = "NO TASKS";
    if (queryState?.mode === "loading") message = "LOADING TASKS…";
    else if (queryState?.mode === "error") message = "TASK QUERY FAILED — RECONNECT OR CHANGE FILTERS TO RETRY";
    else if (searchState?.mode === "loading") message = "SEARCHING TASKS…";
    else if (searchState?.mode === "fallback") message = "SEARCH UNAVAILABLE — LOCAL SEARCH COVERS LOADED TASKS ONLY";
    else if (searchState?.mode === "results") message = searchState.stale ? "NO RESULTS · SEARCH INDEX STALE" : "NO SEARCH RESULTS";
    tbody.innerHTML = `<tr><td colspan="14" class="task-list-empty">${message}</td></tr>`;
    renderedTaskListRoomId = 0n;
    taskListDirty = false;
    renderedTaskSearchState = window.NRCTaskSearch?.getState?.() || null;
    taskListValidUntilMs = validUntilMs;
    requestAnimationFrame(loadMoreTasksNearEnd);
    return;
  }

  if (searchState?.mode === "fallback" || searchState?.stale) {
    const notice = document.createElement("tr");
    notice.innerHTML = `<td colspan="14" class="task-list-empty">${searchState.mode === "fallback" ? "SEARCH UNAVAILABLE — SHOWING LOADED TASKS ONLY" : "SEARCH INDEX STALE — RESULTS MAY BE OUT OF DATE"}</td>`;
    tbody.appendChild(notice);
  }

  const draggable = !ranked || (queryState?.mode === "results" && TaskViewState.sortColumn === "priority");
  if (window.NRCVirtualList && sorted.length > 100) {
    tbody.virtualList = window.NRCVirtualList.create({
      host: tbody, scroller: document.getElementById("taskListView"),
      items: sorted, columns: 14,
      estimate: window.matchMedia?.("(max-width: 768px)").matches ? 68 : 32,
      render: (task) => createTaskRow(task, { draggable }),
      key: (task) => `${task.convId}:${task.id}`,
      dispose: closeStatusMenuFor,
    });
  } else {
    sorted.forEach((task) => {
      tbody.appendChild(createTaskRow(task, { draggable }));
    });
  }
  renderedTaskListRoomId = 0n;
  taskListDirty = false;
  renderedTaskSearchState = window.NRCTaskSearch?.getState?.() || null;
  taskListValidUntilMs = validUntilMs;
  requestAnimationFrame(loadMoreTasksNearEnd);
}

function createTaskRow(task, { draggable = true } = {}) {
  const row = document.createElement("tr");
  row.dataset.taskId = task.id.toString();
  row.dataset.convId = task.convId.toString();
  row.draggable = draggable;
  const isSelected = selectedTaskId === task.id && selectedTaskConvId === task.convId;
  if (isSelected) {
    row.classList.add("task-row-selected");
  }

  // Drag events for priority reordering
  if (draggable) {
    row.addEventListener("dragstart", handleRowDragStart);
    row.addEventListener("dragend", handleRowDragEnd);
    row.addEventListener("dragover", handleRowDragOver);
    row.addEventListener("dragleave", handleRowDragLeave);
    row.addEventListener("drop", handleRowDrop);
  }

  const markerTd = document.createElement("td");
  markerTd.className = "col-marker";
  markerTd.textContent = isSelected ? "›" : "";
  row.appendChild(markerTd);

  const idTd = document.createElement("td");
  idTd.className = "col-id";
  idTd.textContent = task.id.toString();
  idTd.title = `Task #${task.id}`;
  row.appendChild(idTd);

  // Priority
  const priTd = document.createElement("td");
  priTd.className = "col-priority";
  const priValue = task.priority || 0;
  priTd.innerHTML = fieldControl(task, "priority", { label: "" });
  if (priValue >= 200) priTd.classList.add("priority-high");
  else if (priValue >= 128) priTd.classList.add("priority-medium");
  else priTd.classList.add("priority-low");
  row.appendChild(priTd);

  // Title
  const titleTd = document.createElement("td");
  titleTd.className = "col-title";
  const titleButton = document.createElement("button");
  titleButton.type = "button";
  titleButton.className = "task-row-open";
  titleButton.textContent = task.title || "(untitled)";
  titleTd.appendChild(titleButton);
  const renameControl = document.createElement("span");
  renameControl.innerHTML = fieldControl(task, "title", { label: "", rename: true });
  titleTd.appendChild(renameControl);
  titleTd.title = task.title || "";
  row.appendChild(titleTd);

  // Status
  const statusTd = document.createElement("td");
  statusTd.className = "col-status";
  const statusName = TaskStatusNames[task.status] || "??";
  statusTd.appendChild(createTaskStatusControl(task));
  row.appendChild(statusTd);

  // Assignee
  const asnTd = document.createElement("td");
  asnTd.className = "col-assignee";
  asnTd.innerHTML = fieldControl(task, "assignee", { label: "" });
  asnTd.title = task.assignee || "";
  row.appendChild(asnTd);

  titleButton.setAttribute(
    "aria-label",
    `Open task ${task.id}: ${task.title || "untitled"}. Status ${statusName}. Priority ${priValue}. Assignee ${task.assignee || "unassigned"}`,
  );

  // Project
  const projectTd = document.createElement("td");
  projectTd.className = "col-project";
  projectTd.innerHTML = fieldControl(task, "project", { label: "" });
  projectTd.title = task.project || "";
  row.appendChild(projectTd);

  // Due date
  const dueTd = document.createElement("td");
  dueTd.className = "col-due";
  dueTd.innerHTML = fieldControl(task, "dueAt", { label: "" });
  if (task.dueAt && task.dueAt !== 0n) {
    if (isTaskOverdue(task)) {
      dueTd.classList.add("overdue");
    }
  }
  row.appendChild(dueTd);

  // Blocked by
  const blkTd = document.createElement("td");
  blkTd.className = "col-blk";
  blkTd.innerHTML = fieldControl(task, "blockedBy", { label: "" });
  if (task.blockedBy && task.blockedBy !== 0n) {
    // Hover on BLK cell to highlight blocking chain
    blkTd.addEventListener("mouseenter", () => {
      highlightBlockingChainList(task.convId, task.id);
    });
    blkTd.addEventListener("mouseleave", () => {
      clearBlockingChainHighlightList(task.convId, task.id);
    });
  }
  row.appendChild(blkTd);

  // External reference
  const refTd = document.createElement("td");
  refTd.className = "col-ref";
  refTd.innerHTML = fieldControl(task, "externalRef", { label: "" });
  if (task.externalRef && task.externalRef.trim().length > 0) {
    const isUrl =
      task.externalRef.startsWith("http://") ||
      task.externalRef.startsWith("https://");
    refTd.classList.add("has-reference");
    if (isUrl) {
      refTd.title = task.externalRef;
    }
  }
  row.appendChild(refTd);

  // Attachments count
  const attTd = document.createElement("td");
  attTd.className = "col-att";
  const attCount = task.attachments ? task.attachments.length : 0;
  if (attCount > 0) {
    const attIndicator = document.createElement("span");
    attIndicator.className = "att-indicator";
    attIndicator.title = `${attCount} attachment(s)`;
    attIndicator.textContent = attCount;
    attIndicator.style.cursor = "pointer";
    attIndicator.addEventListener("click", (e) => {
      e.stopPropagation();
      showAttachmentPopover(task, attIndicator);
    });
    attTd.appendChild(attIndicator);
  } else {
    attTd.textContent = "—";
  }
  row.appendChild(attTd);

  // Comments count
  const cmtTd = document.createElement("td");
  cmtTd.className = "col-cmt";
  const cmtCount = window.NRCAssets.getCommentCount(task.convId, task.id);
  if (cmtCount > 0) {
    const cmtIndicator = document.createElement("span");
    cmtIndicator.className = "cmt-indicator";
    cmtIndicator.title = `${cmtCount} comment${cmtCount > 1 ? "s" : ""}`;
    cmtIndicator.textContent = cmtCount;
    cmtTd.appendChild(cmtIndicator);
  } else {
    cmtTd.textContent = "—";
  }
  row.appendChild(cmtTd);

  // Category/Color
  const colorTd = document.createElement("td");
  colorTd.className = "col-color";
  const colorIndex = task.color >= 0 && task.color <= 5 ? task.color : 0;
  const colorCss = TaskColorCSS[colorIndex];
  const colorName = TaskColorNames[colorIndex];
  colorTd.innerHTML = fieldControl(task, "category", { label: "" });
  row.appendChild(colorTd);

  // Age
  const ageTd = document.createElement("td");
  ageTd.className = "col-age";
  ageTd.textContent = task.createdAt ? formatRelativeAge(task.createdAt) : "—";
  row.appendChild(ageTd);

  // Single click to select (opens detail panel); guard against discarding
  // unsaved edits in the currently-open detail panel.
  const openTask = async () => {
    if (window.NRCInspector) selectTask(task);
    else if (await confirmDiscardTaskEditsIfDirty()) selectTask(task);
  };
  row.addEventListener("click", async (e) => {
    if (e.target.closest("button, input, select, textarea") && !e.target.closest(".task-row-open")) return;
    await openTask();
  });

  return row;
}

// =============================================================================
// INLINE STATUS CHANGE
// =============================================================================
//
// The status a table draws is the control that changes it: the flat register and
// a slice's member table carry the same token, and it opens the statuses in
// place, so a task is re-statused without opening it. The write is the board's
// own move, because a status change is a move: the server derives completed_at
// and completed_by from the transition, exactly as it does for a drag.

const TASK_STATUS_CLASSES = ["backlog", "todo", "inprogress", "done"];

// MoveTaskFlags.Append: the move asks for the end of the target column, and the
// position is the server's to fold. Mirrors protocol MoveTaskFlag_APPEND.
const TASK_MOVE_APPEND = 0x01;

function taskStatusClass(status) {
  return TASK_STATUS_CLASSES[status] || "";
}

// One menu at a time, owned by the register that opened it: a redraw takes the
// menu with it, because its anchor is one of the rows being rebuilt.
let activeStatusMenu = null;

function closeTaskStatusMenu() {
  const menu = activeStatusMenu;
  if (!menu) return;
  activeStatusMenu = null;
  menu.anchor.setAttribute("aria-expanded", "false");
  document.removeEventListener("click", menu.onOutsideClick, true);
  document.removeEventListener("keydown", menu.onKeydown, true);
  window.CustomPicker?.destroy(menu.picker);
}

// The menu is the shared picker, the one the detail panel's STATUS field opens,
// anchored to the token in the row. It is built when it is opened rather than
// with the row, so a register of a thousand tasks carries a thousand badges and
// no dropdowns.
function openTaskStatusMenu(anchor, task) {
  if (activeStatusMenu?.anchor === anchor) {
    closeTaskStatusMenu();
    return;
  }
  closeTaskStatusMenu();
  if (!window.CustomPicker) return;
  const menu = { anchor, picker: null, onOutsideClick: null, onKeydown: null };
  const picker = window.CustomPicker.create({
    anchor,
    options: TaskStatusNames.slice(0, 4).map((label, value) => ({ value, label })),
    selectedValue: Number(task.status) || 0,
    placeholder: "FILTER STATUS...",
    position: "bottom",
    align: "auto",
    matchWidth: false,
    offsetY: 2,
    onSelect: (option) => {
      closeTaskStatusMenu();
      moveTaskToStatus(task, Number(option.value));
    },
    // The picker closes itself on Escape and on an outside click as well; the
    // menu is the same menu whichever path closed it.
    onClose: () => {
      if (activeStatusMenu === menu) closeTaskStatusMenu();
    },
  });
  menu.picker = picker;
  menu.onOutsideClick = (event) => {
    if (anchor.contains(event.target) || picker.dropdown.contains(event.target)) return;
    closeTaskStatusMenu();
  };
  // Escape belongs to the open menu: it closes the menu and gives the token its
  // focus back instead of reaching the register behind it.
  menu.onKeydown = (event) => {
    if (event.key !== "Escape") return;
    event.stopPropagation();
    closeTaskStatusMenu();
    anchor.focus({ preventScroll: true });
  };
  activeStatusMenu = menu;
  anchor.setAttribute("aria-expanded", "true");
  // The press that opened the menu has already left the document by the time the
  // dismissal is bound, so the menu cannot close itself on the way in.
  document.addEventListener("click", menu.onOutsideClick, true);
  document.addEventListener("keydown", menu.onKeydown, true);
  window.CustomPicker.open(picker);
}

// A status change is a move, and the client asks for the end of the column it
// enters rather than naming a position: the register holds one page of the
// column, so the server — which folds the column — resolves the order.
function moveTaskToStatus(task, status) {
  if (!task || status === task.status) return;
  if (!ws || ws.readyState !== WebSocket.OPEN || !serverReady) {
    reportTaskStatusError("OFFLINE — RECONNECT BEFORE CHANGING A TASK");
    return;
  }
  const sent = sendMoveTask(task.convId ?? 0n, task.id, status, {
    onError: (detail) => reportTaskStatusError(detail?.message || "STATUS CHANGE FAILED"),
  });
  if (!sent) reportTaskStatusError("STATUS CHANGE WAS NOT SENT");
}

function reportTaskStatusError(message) {
  if (window.NRCDialog?.notify) window.NRCDialog.notify(message, { logType: "Error" });
  else logMessage("Error", message);
}

// The token reads exactly as it always has; it is the control now, and the row
// carries the focus outline the way it does for every other opener in a row.
function createTaskStatusControl(task) {
  const statusName = TaskStatusNames[task.status] || "??";
  const button = document.createElement("button");
  button.type = "button";
  button.className = `status-badge task-row-status status-${taskStatusClass(task.status)}`;
  button.textContent = statusName;
  button.setAttribute("aria-haspopup", "listbox");
  button.setAttribute("aria-expanded", "false");
  button.setAttribute("aria-label", `Status ${statusName} — change status`);
  button.addEventListener("click", (event) => {
    // The press belongs to the token, so the row does not open the task under it.
    event.stopPropagation();
    openTaskStatusMenu(button, task);
  });
  return button;
}

// A row that leaves a table takes the menu it opened with it: the anchor is about
// to be detached, and a menu anchored to nothing has nowhere to sit. The virtual
// list calls this as it unmounts a row the reader has scrolled past, and a
// container that is rebuilt calls it while its old markup is still in place.
function closeStatusMenuFor(node) {
  if (activeStatusMenu && node?.contains(activeStatusMenu.anchor)) closeTaskStatusMenu();
}

function updateSortHeaders() {
  const headers = document.querySelectorAll(".task-table th[data-sort]");
  headers.forEach((th) => {
    th.classList.remove("sorted-asc", "sorted-desc");
    if (th.dataset.sort === TaskViewState.sortColumn) {
      th.classList.add(
        TaskViewState.sortDirection === "asc" ? "sorted-asc" : "sorted-desc",
      );
    }
  });
}

function updateTaskListSelection() {
  document.querySelectorAll(".task-table tbody tr[data-task-id]").forEach((row) => {
    const isSelected = selectedTaskId != null && selectedTaskConvId != null &&
      row.dataset.taskId === selectedTaskId.toString() &&
      row.dataset.convId === selectedTaskConvId.toString();
    row.classList.toggle("task-row-selected", Boolean(isSelected));
    const marker = row.querySelector(".col-marker");
    if (marker) marker.textContent = isSelected ? "›" : "";
  });
}

function isTaskListKeyboardEditableTarget(target) {
  if (!target) return false;
  const tagName = target.tagName;
  return tagName === "INPUT" || tagName === "TEXTAREA" || tagName === "SELECT" || target.isContentEditable;
}

function isTaskListKeyboardActive() {
  const activeView = window.NRCViewManager?.getActiveView?.();
  return Boolean(
    (!activeView || activeView === "kanban") &&
    kanbanVisible &&
    document.getElementById("taskListView")?.style.display !== "none"
  );
}

function getVisibleTaskRows() {
  return Array.from(document.querySelectorAll(".task-table tbody tr[data-task-id]"));
}

function selectTaskRow(row) {
  if (!row?.dataset.taskId || !row.dataset.convId) return false;
  const convId = BigInt(row.dataset.convId);
  const taskId = BigInt(row.dataset.taskId);
  const task = roomTasks.get(convId)?.get(taskId) || window.NRCTaskSearch?.getTask?.(convId, taskId);
  if (!task) return false;
  selectTask(task);
  requestAnimationFrame(() => {
    document.querySelector(`.task-table tbody tr[data-task-id="${row.dataset.taskId}"]`)
      ?.scrollIntoView({ block: "nearest" });
  });
  return true;
}

function selectAdjacentTask(direction) {
  const virtual = document.getElementById("taskListBody")?.virtualList;
  if (virtual) {
    const index = selectedTaskId === null ? (direction > 0 ? -1 : virtual.items.length)
      : virtual.items.findIndex((task) => task.id === selectedTaskId && task.convId === selectedTaskConvId);
    if (selectedTaskId !== null && index < 0) return false;
    const next = Math.max(0, Math.min(virtual.items.length - 1, index + direction));
    return selectTaskRow(virtual.ensure(next));
  }
  const rows = getVisibleTaskRows();
  const selectedIdentity = selectedTaskId != null && selectedTaskConvId != null
    ? { convId: selectedTaskConvId.toString(), id: selectedTaskId.toString() }
    : null;
  const result = window.NRCListNavigation.resolveAdjacent(
    rows,
    selectedIdentity,
    direction,
    (row) => ({ convId: row.dataset.convId, id: row.dataset.taskId }),
    window.NRCListNavigation.sameCompoundIdentity,
  );
  if (!result.row || result.status === "missing-selection") return false;
  return selectTaskRow(result.row);
}

// Keyboard-driven adjacent selection respects the dirty guard so arrow-key
// navigation doesn't silently discard unsaved edits.
async function selectAdjacentTaskGuarded(direction) {
  const generation = ++taskListNavigationGeneration;
  if (window.NRCInspector) return selectAdjacentTask(direction);
  if (!(await confirmDiscardTaskEditsIfDirty())) return false;
  if (generation !== taskListNavigationGeneration) return false;
  return selectAdjacentTask(direction);
}

async function confirmDeleteSelectedTask() {
  if (!selectedTaskId) return false;
  const task = currentDetailTask || roomTasks.get(selectedTaskConvId)?.get(selectedTaskId);
  if (!task) return false;

  const confirmed = await window.NRCDialog.confirm(
    `Delete task #${task.id} “${task.title || "(untitled)"}”?`,
    {
      title: "DELETE TASK",
      confirmLabel: "Delete Task",
    },
  );
  if (!confirmed) return true;

  const convId = task.convId;
  const taskId = task.id;
  setTaskDetailDirty(false);
  if (window.NRCInspector) await window.NRCInspector.close();
  else clearTaskSelection({ fromInspector: true });
  sendDeleteTask(convId, taskId);
  return true;
}

function handleTaskListKeyboardNavigation(e) {
  if (!isTaskListKeyboardActive()) return;

  // Esc closes the panel only in read-only view mode. In edit mode the panel's
  // own Esc handler (on .agenda-content) runs first and returns to view; if
  // focus is on the task list itself in edit mode, Esc is a no-op here so the
  // user isn't dropped out of an unsaved edit without a discard prompt.
  // This mirrors the notes preview/edit Esc behavior.
  if (e.key === "Escape") {
    if (window.NRCInspector?.hasEntity()) return;
    if (descriptionFocusMode && selectedTaskId) {
      e.preventDefault();
      clearTaskSelection();
    }
    return;
  }

  if (isTaskListKeyboardEditableTarget(e.target)) return;

  // E enters edit mode from the read-only view (matches notes' "E" shortcut).
  if ((e.key === "e" || e.key === "E") && !window.NRCInspector?.hasEntity() && descriptionFocusMode && selectedTaskId) {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    e.preventDefault();
    exitDescriptionFocus();
    return;
  }

  if (e.key === "ArrowDown") {
    e.preventDefault();
    selectAdjacentTaskGuarded(1);
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    selectAdjacentTaskGuarded(-1);
  } else if (e.key === "Delete") {
    e.preventDefault();
    confirmDeleteSelectedTask();
  }
}

// =============================================================================
// NOTES VIEW RENDERING
// =============================================================================

// Note: Notes rendering and detail panel moved to notes.js

// =============================================================================
// DESCRIPTION FOCUS VIEW (rendered Markdown reading mode)
// =============================================================================

// `descriptionFocusMode` toggles a rendered-Markdown reading view of the task
// description (the FOCUS button). The description field itself is now a
// first-class, always-editable textarea — no separate preview/edit swap.
// `descriptionFocusDraft` stashes the live textarea value while the focus
// view is shown, so unsaved edits survive the round-trip (the focus view
// re-renders from currentDetailTask on exit).
let descriptionFocusMode = false;
let descriptionFocusDraft = null;

// =============================================================================
// USER DIRECTORY
// =============================================================================
//
// Every person picker shares the directory from /api/users; the open
// room's presence is the fallback before it loads.

let allUsers = [];
let usersRequest = null;

// The directory is shared by every field that takes a person's name, so it is
// requested once per page load and reused: a second field must not start a
// second request, and it should still see the list when the first one lands.
function fetchUsersList() {
  if (!usersRequest) {
    usersRequest = (async () => {
      try {
        const response = await fetch("/api/users");
        if (!response.ok) return;
        allUsers = await response.json();
      } catch (err) {
        console.error("Failed to fetch users list:", err);
      }
    })();
  }
  return usersRequest;
}

function userDirectory() {
  if (allUsers.length) return allUsers;
  if (typeof roomPresence !== "undefined" && currentRoomId) {
    const presence = roomPresence.get(currentRoomId);
    if (presence) return Array.from(presence.keys());
  }
  return [];
}

// Build HTML options for blocked-by select
function buildBlockedByOptions(convId, currentTaskId, currentBlockedBy) {
  const tasks = roomTasks.get(convId);
  let options = `<option value="0">--- (none)</option>`;

  if (tasks) {
    for (const [id, t] of tasks.entries()) {
      // Don't allow self-blocking
      if (id === currentTaskId) continue;
      const selected = currentBlockedBy === id ? "selected" : "";
      const statusCode = TaskStatusCodes[t.status] || "??";
      options += `<option value="${id}" ${selected}>[${statusCode}] ${escapeHtml(t.title)}</option>`;
    }
  }

  return options;
}

// =============================================================================
// LIST VIEW DRAG AND DROP (Priority Reordering)
// =============================================================================

let draggedRow = null;

function handleRowDragStart(e) {
  document.getElementById("taskListBody")?.virtualList?.pin(e.currentTarget);
  draggedRow = {
    taskId: BigInt(e.currentTarget.dataset.taskId),
    convId: BigInt(e.currentTarget.dataset.convId),
    element: e.currentTarget,
  };
  e.currentTarget.classList.add("dragging");
  e.dataTransfer.effectAllowed = "move";
}

function handleRowDragEnd(e) {
  document.getElementById("taskListBody")?.virtualList?.pin(null);
  e.currentTarget.classList.remove("dragging");
  draggedRow = null;

  // Remove drag indicators from all rows
  document.querySelectorAll(".task-table tbody tr").forEach((row) => {
    row.classList.remove("drag-over-above", "drag-over-below");
  });
  if (taskListDirty && kanbanVisible) renderTaskListIfNeeded();
}

function handleRowDragOver(e) {
  e.preventDefault();
  if (!draggedRow || e.currentTarget === draggedRow.element) return;
  if (draggedRow.convId !== 0n) return;

  e.dataTransfer.dropEffect = "move";

  // Determine if dropping above or below based on mouse position
  const rect = e.currentTarget.getBoundingClientRect();
  const midY = rect.top + rect.height / 2;
  const isAbove = e.clientY < midY;

  // Clear previous indicators
  document.querySelectorAll(".task-table tbody tr").forEach((row) => {
    row.classList.remove("drag-over-above", "drag-over-below");
  });

  e.currentTarget.classList.add(
    isAbove ? "drag-over-above" : "drag-over-below",
  );
}

function handleRowDragLeave(e) {
  e.currentTarget.classList.remove("drag-over-above", "drag-over-below");
}

function handleRowDrop(e) {
  e.preventDefault();
  e.currentTarget.classList.remove("drag-over-above", "drag-over-below");

  if (!draggedRow || e.currentTarget === draggedRow.element) return;
  if (draggedRow.convId !== 0n || TaskViewState.filters.search) return;

  const targetTaskId = BigInt(e.currentTarget.dataset.taskId);
  const tasks = roomTasks.get(draggedRow.convId);
  if (!tasks) return;

  const draggedTaskData = tasks.get(draggedRow.taskId);
  if (!draggedTaskData) return;

  // Determine drop position
  const rect = e.currentTarget.getBoundingClientRect();
  const midY = rect.top + rect.height / 2;
  const isAbove = e.clientY < midY;

  // Get current sorted task list (excluding dragged task)
  const query = window.NRCTaskQuery?.getState();
  if (query?.mode !== "idle" && query?.roomId === 0n &&
      (query.mode !== "results" || TaskViewState.sortColumn !== "priority" || !query.tasks.has(draggedRow.taskId))) return;
  const sortedTasks = query?.mode === "results" && query.roomId === 0n
    ? Array.from(query.tasks.values()).filter((t) => t.id !== draggedRow.taskId)
    : getSortedTasks(getFilteredTasks(tasks).filter((t) => t.id !== draggedRow.taskId));

  // Find target index
  const targetIndex = sortedTasks.findIndex((t) => t.id === targetTaskId);
  if (targetIndex === -1) return;

  // Calculate new priority based on adjacent tasks
  const newPriority = calculateListPriority(sortedTasks, targetIndex, isAbove);

  // Optimistic update
  draggedTaskData.priority = newPriority;
  renderTaskList();

  // Send to server
  sendUpdateTask(
    draggedRow.convId,
    draggedRow.taskId,
    draggedTaskData.title,
    draggedTaskData.description,
    draggedTaskData.status,
    draggedTaskData.assignee,
    newPriority,
    draggedTaskData.color,
    draggedTaskData.externalRef,
    draggedTaskData.dueAt || 0n,
    draggedTaskData.blockedBy || 0n,
    draggedTaskData.attachments || [],
    draggedTaskData.project || "",
  );
}

function calculateListPriority(sortedTasks, targetIndex, isAbove) {
  // List is sorted by current sort column, but we adjust priority
  // to place the task at the visual position
  const insertIndex = isAbove ? targetIndex : targetIndex + 1;

  if (sortedTasks.length === 0) return 128;

  // Get priorities of adjacent tasks at insert position
  const aboveTask = insertIndex > 0 ? sortedTasks[insertIndex - 1] : null;
  const belowTask =
    insertIndex < sortedTasks.length ? sortedTasks[insertIndex] : null;
  const step = TaskViewState.sortColumn === "priority" && TaskViewState.sortDirection === "asc" ? -10 : 10;

  if (!aboveTask && belowTask) {
    // Inserting at top
    return Math.max(0, Math.min(255, belowTask.priority + step));
  }
  if (aboveTask && !belowTask) {
    // Inserting at bottom
    return Math.max(0, Math.min(255, aboveTask.priority - step));
  }
  if (aboveTask && belowTask) {
    // Inserting between two tasks
    return Math.floor((aboveTask.priority + belowTask.priority) / 2);
  }

  return 128;
}

// =============================================================================
// PALETTE ACTIONS
// =============================================================================

function createTaskFromPalette(title) {
  const taskTitle = (title || "").trim();
  if (!taskTitle) {
    logMessage("Error", "Task title required");
    return;
  }
  sendCreateTask(0n, taskTitle, "", 128, 0);
}

function markTaskDoneFromPalette(taskIdValue) {
  const taskIdStr = (taskIdValue || "").trim();
  if (!taskIdStr) {
    logMessage("Error", "Task ID required");
    return;
  }
  let taskId;
  try {
    taskId = BigInt(taskIdStr);
  } catch {
    logMessage("Error", "Invalid task ID");
    return;
  }
  const tasks = roomTasks.get(0n);
  if (tasks && tasks.has(taskId)) {
    sendMoveTask(0n, taskId, TaskStatus.Done);
  } else {
    logMessage("Error", `Task #${taskIdStr} not found`);
  }
}

function deleteTaskFromPalette(taskIdValue) {
  const taskIdStr = (taskIdValue || "").trim();
  if (!taskIdStr) {
    logMessage("Error", "Task ID required");
    return;
  }
  try {
    sendDeleteTask(0n, BigInt(taskIdStr));
  } catch {
    logMessage("Error", "Invalid task ID");
  }
}

function refreshTasksFromPalette() {
  window.NRCTaskQuery?.update({ force: true });
  loadActiveTasks(0n);
}

function setAssigneeFilterFromPalette(value) {
  const assigneeValue = (value || "").trim();
  const normalized = assigneeValue.toLowerCase();
  const filterValue =
    normalized === "" || normalized === "all"
      ? null
      : normalized === "my" || normalized === "mine" || normalized === "my tasks"
        ? "me"
        : assigneeValue;

  if (typeof TaskViewState !== "undefined" && TaskViewState.filters) {
    TaskViewState.filters.assignee = filterValue;
  }
  myTasksOnly = filterValue === "me";

  const assigneeSelect = document.getElementById("filterAssignee");
  if (assigneeSelect) assigneeSelect.value = filterValue || "";

  if (typeof refreshTaskViewAfterFilterChange === "function") {
    refreshTaskViewAfterFilterChange();
  } else {
    renderCurrentTaskView();
  }
}

// =============================================================================
// ROOM SWITCHING
// =============================================================================

function onRoomSwitch() {
  window.NRCTaskQuery?.update();
  window.NRCTaskSearch?.onRoomSwitch?.();
  window.NRCSlices?.onRoomSwitch?.();
  // Fetch tasks if kanban is active
  if (kanbanVisible || remindersVisible) {
    renderReminderQueue();
    if (kanbanVisible) {
      renderCurrentTaskView();
    }
  }

  // Notes room switch handled by notes.js via onNotesRoomSwitch
}

// =============================================================================
// TASK DETAIL PANEL (COMMENTS)
// =============================================================================

function selectTask(task, { fromInspector = false, subview = null, focusId = null, loadDetail = true } = {}) {
  taskListNavigationGeneration++;
  if (!fromInspector && window.NRCInspector) {
    window.NRCInspector.openEntity({ roomId: task.convId, type: "task", id: task.id }, { subview, focusId });
    return;
  }
  // A draft belongs to the record it was written on.
  if (selectedTaskConvId !== task.convId || selectedTaskId !== task.id) {
    taskMessagesOpen = null;
    taskComposerOpen = false;
    taskComposerDraft = "";
    taskResourceOpen = {};
  }
  if (subview === "comments") taskMessagesOpen = true;
  if (focusId != null) pendingCommentFocusAssetId = BigInt(focusId);
  taskDetailSaveGeneration++;
  selectedTaskConvId = task.convId;
  selectedTaskId = task.id;
  updateTaskListSelection();
  if (loadDetail) showTaskDetailPanel(task);
}

function clearTaskSelection({ fromInspector = false, preserveDetail = false } = {}) {
  taskListNavigationGeneration++;
  if (!fromInspector && window.NRCInspector?.hasEntity()) {
    window.NRCInspector.close();
    return;
  }
  taskDetailSaveGeneration++;
  selectedTaskConvId = null;
  selectedTaskId = null;
  taskMessagesOpen = null;
  taskComposerOpen = false;
  taskComposerDraft = "";
  taskResourceOpen = {};
  descriptionFocusMode = false;
  descriptionFocusDraft = null;
  taskDetailDirty = false;
  taskDetailSnapshot = null;
  currentDetailTask = null;
  updateTaskListSelection();
  if (!preserveDetail) hideTaskDetailPanel();
  window.NRCPageTitle?.set("TASKS");
}

// --- Dirty-state helpers (task detail panel) -------------------------------
// Returns true if it's safe to close/switch (not dirty, or user confirmed).
async function confirmDiscardTaskEditsIfDirty() {
  if (!taskDetailDirty) return true;
  const confirmed = await window.NRCDialog.confirm(
    "Discard unsaved changes to this task?",
    {
      title: "UNSAVED CHANGES",
      confirmLabel: "Discard",
    },
  );
  return confirmed;
}

// Snapshot the task's editable fields for revert + dirty baseline.
function snapshotTaskDetail(task) {
  taskDetailSnapshot = {
    title: task.title ?? "",
    description: task.description ?? "",
    externalRef: task.externalRef ?? "",
    project: task.project ?? "",
    priority: task.priority ?? 0,
    color: task.color ?? 0,
    status: task.status ?? 0,
    dueAt: task.dueAt ?? 0n,
    blockedBy: task.blockedBy ?? 0,
    assignee: task.assignee ?? "",
    attachments: Array.isArray(task.attachments)
      ? task.attachments.map((a) => ({ ...a }))
      : [],
  };
  setTaskDetailDirty(false);
}

function setTaskDetailDirty(dirty) {
  taskDetailDirty = dirty;
  const panel = document.querySelector(".agenda-panel .panel-header");
  const saveBtn = document.getElementById("taskDetailSave");
  if (panel) panel.classList.toggle("is-dirty", dirty);
  if (saveBtn) saveBtn.classList.toggle("is-dirty", dirty);
  if (dirty) {
    taskDetailSaveGeneration++;
    window.NRCDetailUI?.setSaveState("UNSAVED", panel || document);
  }
}

// Revert the form to the snapshot by re-rendering the panel from the
// (unmutated) currentDetailTask. The snapshot itself stays so a fresh
// CANCEL after no further edits is a no-op re-render.
function revertTaskDetail() {
  if (!currentDetailTask) return;
  taskDetailSaveGeneration++;
  showTaskDetailPanel(currentDetailTask);
}

// Deep links (chat references, notifications) land on a single message. The
// messages block opens first, then the message is scrolled into view; when the
// asset list is still in flight the caller retries.
function tryFocusPendingCommentInDetailPanel() {
  if (pendingCommentFocusAssetId == null) return;
  taskMessagesController?.open();

  const target = document.querySelector(`.record-message[data-asset-id="${String(pendingCommentFocusAssetId)}"]`);
  if (!target) return;

  target.scrollIntoView({ behavior: "smooth", block: "nearest" });
  target.classList.add("highlighted");
  setTimeout(() => target.classList.remove("highlighted"), 1200);
  pendingCommentFocusAssetId = null;
}

function openTaskComments(task, commentAssetId = null) {
  if (!task) return false;

  if (window.NRCInspector) {
    window.NRCInspector.openEntity(
      { roomId: task.convId, type: "task", id: task.id },
      { subview: "comments", focusId: commentAssetId },
    );
    return true;
  }

  selectTask(task, { subview: "comments", focusId: commentAssetId });

  if (pendingCommentFocusAssetId != null) {
    // If comments arrive slightly later (asset list refresh), retry briefly.
    let attempts = 0;
    const retryFocus = () => {
      if (pendingCommentFocusAssetId == null) return;
      attempts += 1;
      tryFocusPendingCommentInDetailPanel();
      if (pendingCommentFocusAssetId != null && attempts < 8) {
        setTimeout(retryFocus, 120);
      }
    };
    setTimeout(retryFocus, 80);
  }

  return true;
}

function getSelectedTask() {
  if (selectedTaskId == null || selectedTaskConvId == null) return null;
  const tasks = roomTasks.get(selectedTaskConvId);
  if (!tasks) return null;
  return tasks.get(selectedTaskId) || null;
}

function getTaskMarkdownUpdateKey(task) {
  return `${task.convId}:${task.id}`;
}

function getCanonicalTask(task) {
  return roomTasks.get(task.convId)?.get(task.id) || task;
}

function getTaskMarkdown(task) {
  return taskMarkdownUpdates.get(getTaskMarkdownUpdateKey(task))?.draft ?? task.description ?? "";
}

function renderTaskDocumentResources(task, ampThreads) {
  return window.NRCDetailUI.renderDocumentResources({ kind: "task", attachments: task.attachments,
    attachmentControl: taskAttachmentsControl(task), open: taskResourceOpen,
    threadsHtml: window.NRCDetailUI.renderResourceBlock({
      resource: "threads", label: "AMP THREADS", open: taskResourceOpen.threads === true,
      count: ampThreads.length, preview: ampThreads[0]?.label || "", bodyHtml: renderNoteAmpThreads(ampThreads),
    }),
  });
}

function renderSelectedTaskMarkdown(task) {
  if (
    selectedTaskId === task.id &&
    selectedTaskConvId === task.convId &&
    descriptionFocusMode
  ) {
    currentDetailTask = task;
    enterDescriptionFocus();
  }
}

function sendPendingTaskMarkdown(state, task) {
  const sentMarkdown = state.draft;
  state.inFlight = true;

  const correlationId = sendUpdateTask(
    task.convId,
    task.id,
    "",
    sentMarkdown,
    255,
    "",
    255,
    255,
    "",
    0n,
    0n,
    null,
    "",
    {
      onSuccess: ({ task: updatedTask }) => {
        if (taskMarkdownUpdates.get(state.key) !== state) return;
        state.inFlight = false;
        if (state.draft !== sentMarkdown) {
          sendPendingTaskMarkdown(state, updatedTask);
        } else {
          taskMarkdownUpdates.delete(state.key);
          renderSelectedTaskMarkdown(updatedTask);
        }
      },
      onError: () => {
        if (taskMarkdownUpdates.get(state.key) !== state) return;
        taskMarkdownUpdates.delete(state.key);
        renderSelectedTaskMarkdown(getCanonicalTask(task));
        logMessage("Error", "TASK CHECKBOX UPDATE FAILED; REFRESHING TASKS");
        requestTask(task.convId, task.id);
      },
    },
  );

  if (!correlationId) {
    taskMarkdownUpdates.delete(state.key);
    renderSelectedTaskMarkdown(getCanonicalTask(task));
    logMessage("Error", "NOT CONNECTED; TASK CHECKBOX WAS NOT UPDATED");
  }
}

function queueTaskMarkdownUpdate(task, markdown) {
  const key = getTaskMarkdownUpdateKey(task);
  let state = taskMarkdownUpdates.get(key);
  if (!state) {
    state = { key, draft: getTaskMarkdown(task), inFlight: false };
    taskMarkdownUpdates.set(key, state);
  }
  state.draft = markdown;
  renderSelectedTaskMarkdown(getCanonicalTask(task));
  if (!state.inFlight) sendPendingTaskMarkdown(state, getCanonicalTask(task));
}

function formatCommentTime(nanos) {
  if (!nanos) return "";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `${hours}:${minutes}`;
}

// The panel replaces its own markup on every render, but `.agenda-content`
// itself persists. Panel-level handlers are therefore bound once, on the first
// render, and resolve the fields they guard at event time.
let taskDetailPanelHandlersBound = false;

function bindTaskDetailPanelHandlers(agendaContent) {
  if (taskDetailPanelHandlersBound) return;
  taskDetailPanelHandlersBound = true;

  // Dirty tracking: any input/change in the detail panel marks it dirty.
  // The link picker (search input) and comment input are excluded — they
  // are not part of the task's editable fields.
  const dirtyFieldIds = new Set([
    "taskDetailPriority",
    "taskDetailStatus",
    "taskDetailColor",
    "taskDetailTitle",
    "taskDetailDesc",
    "taskDetailExternalRef",
    "taskDetailProject",
    "taskDetailDueAt",
    "taskDetailBlockedBy",
    "taskDetailAssignee",
  ]);
  agendaContent.addEventListener("input", (e) => {
    if (e.target.id && dirtyFieldIds.has(e.target.id)) {
      setTaskDetailDirty(true);
      // Clearing an inline title error as the user types.
      if (e.target.id === "taskDetailTitle") clearTaskDetailTitleError();
    }
  });
  agendaContent.addEventListener("change", (e) => {
    if (e.target.id && dirtyFieldIds.has(e.target.id)) {
      setTaskDetailDirty(true);
    }
  });

  // Resource registers toggle in place; the panel must not re-render, because
  // the files and links modules hydrate into those containers. The live DOM
  // carries the open state; this render reads it back in showTaskDetailPanel.
  window.NRCDetailUI.bindResourceBlocks({ root: agendaContent });

  // Wire up keyboard shortcuts for the detail panel
  agendaContent.addEventListener("keydown", handleDetailPanelKeydown);
}

function buildTaskHeaderMetadata(task) {
  const rows = [
    { label: "CREATED BY", value: task.createdBy || "—", role: "actor" },
    { label: "CREATED", value: window.NRCDetailUI.formatHeaderDate(task.createdAt) },
    { label: "UPDATED", value: window.NRCDetailUI.formatHeaderDate(task.updatedAt) },
  ];
  if (task.completedAt && task.completedAt !== 0n) {
    rows.push({ label: "COMPLETED", value: window.NRCDetailUI.formatHeaderDate(task.completedAt) });
  }
  return window.NRCDetailUI.renderHeaderMetadata(rows);
}

function renderTaskDocumentProperties(task) {
  const fields = ["status", "priority", "category", "dueAt", "project", "assignee", "blockedBy", "externalRef"];
  return `<div class="task-detail-doc-title">${escapeHtml(task.title)} ${fieldControl(task, "title", { label: "", rename: true })}</div>
    <div class="detail-read-register task-detail-read-register">${fields.map(field => fieldControl(task, field)).join("")}</div>`;
}

// `view` defaults to the rendered document; the content editor uses false.
function showTaskDetailPanel(task, { view = true } = {}) {
  if (window.NRCInspector?.isLoading?.()) return;
  window.NRCPageTitle?.set(task.title || `TASK #${task.id}`);

  // Stash the live draft so a re-render (an arriving message, for example)
  // cannot discard a message the operator is still writing.
  const liveComposer = document.getElementById("taskCommentInput");
  if (liveComposer) taskComposerDraft = liveComposer.value;
  const livePanel = document.querySelector(".agenda-panel .agenda-content");
  taskResourceOpen = window.NRCDetailUI.readResourceState(livePanel);

  // Track current task for editing
  currentDetailTask = task;

  // Snapshot for dirty-state revert + close guard
  snapshotTaskDetail(task);

  const agendaPanel = document.querySelector(".agenda-panel");
  const agendaHeader = agendaPanel.querySelector(".panel-header");
  const agendaContent = agendaPanel.querySelector(".agenda-content");
  const agendaActions = document.getElementById("agendaActions");
  window.NRCLinksUI?.closeLinkPicker();

  // Legacy action host is not used by Inspector entity views.
  agendaActions.style.display = "none";

  // Update header with tabs
  const comments = window.NRCAssets.getCommentsForTask(task.convId, task.id);
  const commentCount = comments.length;
  agendaHeader.innerHTML = `<div class="inspector-identity-row">
    <span class="header-text identity-reference">TASK #${task.id}</span>
    ${buildTaskHeaderMetadata(task)}
    <span class="inspector-cell-label">STATE</span>
    ${view || descriptionFocusMode ? '<span class="inspector-state-value">READ</span>' : window.NRCDetailUI.renderSaveState("SAVED")}
  </div><div class="inspector-mode-row">
    <button class="btn btn--primary header-operation task-modal-btn save" id="taskDetailSave" title="Save description (Ctrl+Enter)">SAVE</button>
    ${window.NRCDetailUI.renderHeaderAction({ id: "taskDetailToggleFocus", label: view || descriptionFocusMode ? "EDIT" : "CANCEL", command: view || descriptionFocusMode ? "e" : "v", title: view || descriptionFocusMode ? "Edit description (E)" : "Discard description edits (V)" })}
    <button class="btn btn--danger header-operation inspector-matrix-control" id="taskDetailDelete" title="Delete task">DELETE</button>
    ${window.NRCDetailUI.renderCloseControl("taskDetailClose")}</div>`;

  const messagesHtml = window.NRCDetailUI.renderMessages({
    comments,
    currentUser: myNickname,
    formatTime: formatCommentTime,
  });
  const lastMessagePreview = window.NRCDetailUI.messagePreview(comments);

  agendaContent.innerHTML = `
    <div class="task-detail-panel task-detail-panel-editable">
      <!-- Document surface: the read-only document or the edit form. The
           container keeps its historical tab-content class, which carries the
           scroll and mobile contracts. -->
      <div class="task-detail-tab-content detail-edit-form task-detail-edit-form record-document active" data-tab-content="detail">
        <div class="record-document record-document-scroll">
        ${renderTaskDocumentProperties(task)}
        <section class="detail-edit-section" data-detail-section="core">
          <div class="task-detail-row task-detail-row-desc detail-edit-field detail-edit-field--content">
            <div class="detail-edit-label-row">
              <span class="task-detail-field-stats" id="taskDetailDescStats">0 / 2,048 BYTES</span>
            </div>
            <div class="task-detail-desc-container">
              <textarea class="task-detail-textarea" id="taskDetailDesc" aria-label="Description" maxlength="2048" placeholder="Description...">${escapeHtml(task.description || "")}</textarea>
            </div>
          </div>
        </section>
        </div>
        ${renderTaskDocumentResources(task, renderNoteMarkdownPresentation(getTaskMarkdown(task), task.attachments || []).ampThreads)}
      </div>
      ${window.NRCDetailUI.renderMessagesArea({
        messagesHtml,
        count: commentCount,
        preview: lastMessagePreview,
        persistent: true,
        open: taskMessagesOpen ?? commentCount > 0,
        composerOpen: taskComposerOpen,
        draft: taskComposerDraft,
        inputId: "taskCommentInput",
        sendId: "taskCommentSend",
      })}
    </div>
  `;

  document.getElementById("taskDetailClose").onclick = () => {
    if (window.NRCInspector) window.NRCInspector.close();
    else confirmDiscardTaskEditsIfDirty().then((confirmed) => {
      if (confirmed) clearTaskSelection({ fromInspector: true });
    });
  };

  // Wire up the view/edit toggle. In view mode it reads "EDIT" and switches to
  // the edit form (no discard prompt — entering edit loses nothing). In edit
  // mode it reads "VIEW" and returns to read-only view; if the form is dirty,
  // prompt to discard unsaved edits first (mirrors notes' CANCEL → preview).
  const focusBtn = document.getElementById("taskDetailToggleFocus");
  if (focusBtn) {
    focusBtn.onclick = async () => {
      if (descriptionFocusMode) {
        exitDescriptionFocus();
      } else {
        if (taskDetailDirty) {
          if (await confirmDiscardTaskEditsIfDirty()) revertTaskDetail();
        } else {
          enterDescriptionFocus();
        }
      }
    };
  }

  // Wire up action buttons
  document.getElementById("taskDetailSave").onclick = saveTaskFromDetailPanel;
  document.getElementById("taskDetailDelete").onclick = async () => {
    if (currentDetailTask) {
      const confirmed = await window.NRCDialog.confirm(
        `Delete task #${currentDetailTask.id} “${currentDetailTask.title || "(untitled)"}”?`,
        {
          title: "DELETE TASK",
          confirmLabel: "Delete Task",
        },
      );
      if (confirmed) {
        const convId = currentDetailTask.convId;
        const taskId = currentDetailTask.id;
        setTaskDetailDirty(false);
        if (window.NRCInspector) await window.NRCInspector.close();
        else clearTaskSelection({ fromInspector: true });
        sendDeleteTask(convId, taskId);
      }
    }
  };

  // Panel-level handlers (dirty tracking, dropdown dismissal, keyboard
  // shortcuts) are bound once on the container; see the helper.
  bindTaskDetailPanelHandlers(agendaContent);

  // Wire up field stats updates
  const fieldIds = ["taskDetailDesc"];
  fieldIds.forEach((id) => {
    const field = document.getElementById(id);
    if (field) {
      field.addEventListener("input", updateDetailFieldStats);
    }
  });

  taskMessagesController = window.NRCDetailUI.bindMessagesArea({
    root: agendaContent,
    inputId: "taskCommentInput",
    sendId: "taskCommentSend",
    onSubmit: (text) => window.NRCAssets.sendCreateComment(task.convId, task.id, text),
    onDelete: (assetId) => window.NRCAssets.sendDeleteComment(task.convId, BigInt(assetId)),
    onToggle: ({ messagesOpen, composerOpen, draft }) => {
      taskMessagesOpen = messagesOpen;
      taskComposerOpen = composerOpen;
      taskComposerDraft = draft ?? "";
    },
    focusPending: pendingCommentFocusAssetId != null,
  });

  // Initialize field stats with current values
  updateDetailFieldStats();

  // The Inspector hydrates links before publishing the detail.
  if (window.NRCLinksUI) {
    window.NRCLinksUI.renderLinks(task, 2); // 2 = TargetType.Task
  }

  tryFocusPendingCommentInDetailPanel();

  document.getElementById("taskDetailLinkAdd").onclick = event => {
    event.stopPropagation();
    document.getElementById("taskDetailLinkPicker").open({
      anchor: event.currentTarget, sourceType: 2, sourceEntity: task,
      onSelect: (item, relation) => window.NRCLinksUI.createPickedLink(task, 2, item, relation),
    });
  };

  // Default to read-only view mode (rendered description + links, action bar
  // hidden), mirroring the notes preview panel. Callers that need the edit
  // form (e.g. exitDescriptionFocus re-rendering into edit mode) pass
  // { view: false }.
  if (view && currentDetailTask) {
    enterDescriptionFocus();
  }
}

async function handleDetailPanelKeydown(e) {
  if (e.key === "Escape") {
    // Close the link picker first if it's open.
    if (window.NRCLinksUI && window.NRCLinksUI.isPickerVisible()) {
      e.stopPropagation();
      window.NRCLinksUI.closeLinkPicker();
      return;
    }
    if (window.NRCInspector?.hasEntity()) return;
    e.stopPropagation();
    if (descriptionFocusMode) {
      // View mode: ESC closes the panel (matches notes preview).
      clearTaskSelection();
    } else {
      // Edit mode: if dirty, prompt to discard; then return to read-only view.
      // If clean, just switch to view. Either path lands in view mode, not
      // back into the edit form.
      (async () => {
        if (taskDetailDirty) {
          if (await confirmDiscardTaskEditsIfDirty()) revertTaskDetail();
        } else {
          enterDescriptionFocus();
        }
      })();
    }
  } else if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
    // Ctrl/Cmd+Enter saves from any field (edit mode only).
    e.stopPropagation();
    e.preventDefault();
    saveTaskFromDetailPanel();
  }
}

function enterDescriptionFocus() {
  const tabContent = document.querySelector('.task-detail-tab-content[data-tab-content="detail"]');
  if (!tabContent || !currentDetailTask) return;

  taskResourceOpen = window.NRCDetailUI.readResourceState(tabContent);
  descriptionFocusMode = true;
  const task = currentDetailTask;

  // Stash the live textarea value so unsaved edits are not discarded by the
  // focus view (which re-renders from currentDetailTask on exit).
  const editor = document.getElementById("taskDetailDesc");
  const liveDesc = editor ? editor.value : getTaskMarkdown(task);
  descriptionFocusDraft = liveDesc;

  // Build a document view (like notes preview)
  const presentation = renderNoteMarkdownPresentation(liveDesc, task.attachments || []);
  const renderedDesc = liveDesc.trim()
    ? presentation.bodyHtml
    : '<span class="task-detail-desc-empty">No description</span>';

  tabContent.innerHTML = `
    <div class="task-detail-document record-document record-document-scroll">
      ${renderTaskDocumentProperties(task)}
      <div class="agenda-preview task-detail-doc-body">${renderedDesc}</div>
    </div>
    ${renderTaskDocumentResources(task, presentation.ampThreads)}
  `;

  const descriptionBody = tabContent.querySelector(".task-detail-doc-body");
  attachMarkdownCheckboxHandlers(
    descriptionBody,
    () => getTaskMarkdown(task),
    (updatedMarkdown) => queueTaskMarkdownUpdate(task, updatedMarkdown),
  );

  document.getElementById("taskDetailLinkAdd").onclick = event => {
    document.getElementById("taskDetailLinkPicker").open({
      anchor: event.currentTarget, sourceType: 2, sourceEntity: task,
      onSelect: (item, relation) => window.NRCLinksUI.createPickedLink(task, 2, item, relation),
    });
  };
  // Resources remain actionable while reading the description.
  if (window.NRCLinksUI) {
    window.NRCLinksUI.renderLinks(task, 2);
  }

  // Hide the action bar (SAVE / HAND OFF / DELETE) in focus mode
  const actions = document.querySelector(".task-detail-actions");
  if (actions) actions.style.display = "none";
  document.getElementById("taskDetailSave").hidden = true;
  const state = document.querySelector(".agenda-panel .detail-save-state");
  if (state) window.NRCDetailUI.setSaveState("READ", document);

  const focusBtn = document.getElementById("taskDetailToggleFocus");
  window.NRCDetailUI.setHeaderAction(focusBtn, { label: "EDIT", command: "e" });
  if (focusBtn) focusBtn.title = "Edit description (E)";
}

function exitDescriptionFocus() {
  if (
    currentDetailTask &&
    taskMarkdownUpdates.has(getTaskMarkdownUpdateKey(currentDetailTask))
  ) {
    logMessage("System", "WAIT FOR THE CHECKBOX UPDATE TO FINISH BEFORE EDITING");
    return;
  }
  descriptionFocusMode = false;
  const focusBtn = document.getElementById("taskDetailToggleFocus");
  window.NRCDetailUI.setHeaderAction(focusBtn, { label: "CANCEL", command: "v" });
  // Re-render the full edit panel (stay in edit mode — do not auto-enter view).
  if (currentDetailTask) {
    showTaskDetailPanel(currentDetailTask, { view: false });
    // Restore the stashed draft so unsaved edits survive the focus round-trip.
    // showTaskDetailPanel resets dirty (snapshots from the saved task), so
    // re-mark dirty if the draft differs from the snapshot baseline.
    if (descriptionFocusDraft != null) {
      const editor = document.getElementById("taskDetailDesc");
      if (editor && editor.value !== descriptionFocusDraft) {
        editor.value = descriptionFocusDraft;
      }
      const stillDirty =
        taskDetailSnapshot && descriptionFocusDraft !== (taskDetailSnapshot.description ?? "");
      if (typeof updateDetailFieldStats === "function") updateDetailFieldStats();
      setTaskDetailDirty(stillDirty);
      descriptionFocusDraft = null;
    }
  }
}

function saveTaskFromDetailPanel() {
  if (!currentDetailTask) return;

  const task = currentDetailTask;
  const descriptionField = document.getElementById("taskDetailDesc");
  if (!descriptionField) return;
  const descValue = descriptionField.value;
  if (new TextEncoder().encode(descValue).length > MAX_TASK_DESCRIPTION_LENGTH) {
    window.NRCDetailUI.setSaveState("FAILED", document);
    return;
  }
  const description = descValue === "" && task.description ? "\x00" : descValue;
  const generation = ++taskDetailSaveGeneration;
  window.NRCDetailUI.setSaveState("SAVING", document);
  const sent = sendUpdateTask(task.convId, task.id, "", description, 255, "", 255, 255, "", 0n, 0n,
    null, "", {
      onSuccess: ({ task: updatedTask }) => {
        if (generation !== taskDetailSaveGeneration) return;
        currentDetailTask = updatedTask;
        descriptionFocusDraft = updatedTask.description || "";
        snapshotTaskDetail(updatedTask);
        window.NRCDetailUI.setSaveState("SAVED", document);
      },
      onError: () => {
        if (generation !== taskDetailSaveGeneration) return;
        taskDetailDirty = true;
        window.NRCDetailUI.setSaveState("FAILED", document);
      },
    });
  if (!sent) {
    taskDetailDirty = true;
    window.NRCDetailUI.setSaveState("FAILED", document);
  }
}

// --- Inline title error (task detail) --------------------------------------
function showTaskDetailTitleError() {
  const input = document.getElementById("taskDetailTitle");
  const row = input?.closest(".task-detail-row");
  const err = document.getElementById("taskDetailTitleError");
  if (row) row.classList.add("is-invalid");
  if (err) err.classList.add("is-visible");
  if (input) input.focus();
}

function clearTaskDetailTitleError() {
  const input = document.getElementById("taskDetailTitle");
  const row = input?.closest(".task-detail-row");
  const err = document.getElementById("taskDetailTitleError");
  if (row) row.classList.remove("is-invalid");
  if (err) err.classList.remove("is-visible");
}

function updateDetailFieldStats() {
  const updateStat = (inputId, statsId, maxBytes) => {
    const input = document.getElementById(inputId);
    const stats = document.getElementById(statsId);
    if (!input || !stats) return;

    const bytes = new TextEncoder().encode(input.value).length;
    stats.textContent = `${bytes.toLocaleString()} / ${maxBytes.toLocaleString()} BYTES`;

    // Threshold escalation: dim < 80%, amber 80–95%, red > 95% (incl. over).
    stats.classList.remove("is-warn", "is-danger");
    if (bytes > maxBytes) {
      stats.classList.add("is-danger");
    } else if (bytes >= maxBytes * 0.95) {
      stats.classList.add("is-danger");
    } else if (bytes >= maxBytes * 0.8) {
      stats.classList.add("is-warn");
    }
  };

  updateStat("taskDetailTitle", "taskDetailTitleStats", MAX_TASK_TITLE_LENGTH);
  updateStat("taskDetailDesc", "taskDetailDescStats", MAX_TASK_DESCRIPTION_LENGTH);
  updateStat("taskDetailExternalRef", "taskDetailRefStats", 512);
  updateStat("taskDetailProject", "taskDetailProjectStats", 128);
  updateStat("taskDetailAssignee", "taskDetailAssigneeStats", 32);
}

function hideTaskDetailPanel() {
  // Clear the current detail task
  currentDetailTask = null;

  // Clear the Inspector entity view.
  const agendaPanel = document.querySelector(".agenda-panel");
  const agendaHeader = agendaPanel.querySelector(".panel-header");
  const agendaContent = agendaPanel.querySelector(".agenda-content");
  const agendaActions = document.getElementById("agendaActions");

  window.NRCLinksUI?.closeLinkPicker();
  agendaHeader.classList.remove("is-dirty");
  agendaContent.innerHTML = "";
  agendaActions.style.display = "none";
}

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

function handleCommentChanged(asset, action) {
  // Refresh the detail panel if viewing the affected task
  if (
    currentDetailTask &&
    asset.parentType === 1 &&
    asset.parentId === BigInt(currentDetailTask.id) &&
    asset.convId === currentDetailTask.convId
  ) {
    const task = roomTasks.get(currentDetailTask.convId)?.get(currentDetailTask.id) || null;
    if (task && !taskDetailDirty) {
      // Preserve the current view/edit mode so an arriving comment doesn't
      // yank a dirty editor into read-only view (or vice versa).
      showTaskDetailPanel(task, { view: descriptionFocusMode });
    }
  }

  // Update comment count badges on cards (skip for fetched - no count change)
  if (action !== "fetched") {
    invalidateTaskList(asset.convId);
    if (kanbanVisible && asset.convId === 0n) renderCurrentTaskView();
  }

  // Durable activity belongs to the operator log, not the selected chat.
  if (
    action === "created" &&
    asset.parentType === 1 &&
    asset.convId === 0n &&
    asset.owner !== myNickname
  ) {
    const taskId = asset.parentId;
    const snippet = (asset.payload || asset.preview || "").slice(0, 50);
    const ellipsis =
      (asset.payload || asset.preview || "").length > 50 ? "..." : "";
    logSystem(
      `${asset.owner} commented on #${taskId}: "${snippet}${ellipsis}"`,
      "tasks",
    );
  }
}

function handleReminderChanged(asset) {
  if (selectedReminderAssetId && currentDetailReminder) {
    const selectedRoomId = currentDetailReminder.asset.convId;
    const selectedChanged = asset?.convId === selectedRoomId && asset?.assetId === selectedReminderAssetId;
    if (selectedChanged && !reminderDetailDirty) {
      const reminder = getReminderByAssetId(selectedReminderAssetId, selectedRoomId);
      if (reminder) {
        currentDetailReminder = reminder;
        showReminderDetailPanel(reminder);
      } else {
        clearReminderSelection();
      }
    }
  }

  if (remindersVisible && (!asset || asset.convId === 0n)) renderReminderQueue();

  // The reminder timer owns its own transition bookkeeping; it is told about
  // the change instead of polling the asset store.
  window.NRCReminderNotify?.onReminderChanged?.(asset);
  window.NRCAttention?.refreshSoon?.();
  window.NRCCalendar?.refreshSoon();
}

// Register for comment changes
function initTaskDetailPanel() {
  if (window.NRCAssets && window.NRCAssets.setOnCommentChanged) {
    window.NRCAssets.setOnCommentChanged(handleCommentChanged);
  }
  if (window.NRCAssets && window.NRCAssets.setOnReminderChanged) {
    window.NRCAssets.setOnReminderChanged(handleReminderChanged);
  }
  // Note: onNoteChanged registration moved to notes.js
}

// =============================================================================
// TASK LINKS (using consolidated functions from notes.js)
// =============================================================================

function handleTaskEdgeChanged(edge, action) {
  if (!currentDetailTask) return;
  if (edge.convId !== currentDetailTask.convId) return;

  const { TargetType } = window.NRCEdges;
  const taskId = currentDetailTask.id;

  if (action === "all" || action === "cache") {
    window.NRCLinksUI?.renderLinks(currentDetailTask, 2);
    return;
  }
  if (action === "list") {
    if (edge.targetType === TargetType.Task && edge.targetId === taskId) {
      if (window.NRCLinksUI) {
        window.NRCLinksUI.renderLinks(currentDetailTask, 2);
      }
    }
    return;
  }

  if (action === "created" || action === "deleted") {
    const involves =
      (edge.sourceType === TargetType.Task && edge.sourceId === taskId) ||
      (edge.targetType === TargetType.Task && edge.targetId === taskId);

    if (involves && window.NRCLinksUI) {
      window.NRCLinksUI.renderLinks(currentDetailTask, 2);
    }
  }
}

// =============================================================================
// INIT
// =============================================================================

function initTasks() {
  fetchUsersList();
  initTaskDetailPanel();
  document.addEventListener("keydown", handleTaskListKeyboardNavigation);
  document.addEventListener("keydown", handleRemindersKeyboardNavigation);
  const createReminderBtn = document.getElementById("createReminderBtn");
  if (createReminderBtn) {
    createReminderBtn.onclick = () => {
      createReminder();
    };
  }
  document.getElementById("taskListView")?.addEventListener("scroll", loadMoreTasksNearEnd, { passive: true });
  // Note: initNotesSearch moved to notes.js

  // Register for edge changes to update task links
  if (window.NRCEdges && window.NRCEdges.addEdgeChangeListener) {
    window.NRCEdges.addEdgeChangeListener(handleTaskEdgeChanged);
  }
}

// Export for use in app.js
window.NRCTasks = {
  sendCreateTask,
  handleTaskErrorResponse,
  handleTaskCreated,
  handleTaskUpdated,
  handleTaskDeleted,
  handleTaskMoved,
  handleTaskListResponse,
  handleTaskListPage,
  handleTaskFull,
  clearPendingTaskRpcs,
  createTaskFromPalette,
  markTaskDoneFromPalette,
  deleteTaskFromPalette,
  refreshTasksFromPalette,
  setAssigneeFilterFromPalette,
  toggleKanban,
  showKanban,
  hideKanban,
  toggleReminders,
  showReminders,
  hideReminders,
  sendGetTasks,
  sendListTasksPaged,
  sendGetTask,
  requestTask,
  loadTaskPage,
  drainTaskPages,
  loadActiveTasks,
  initTasks,
  onRoomSwitch,
  roomTasks,
  TaskStatus,
  TaskStatusNames,
  TaskStatusCodes,
  TaskColor,
  TaskColorNames,
  renderReminderQueue,
  getReminderSnapshot,
  ReminderState,
  toggleMyTasksFilter,
  initFilterState,
  getFieldChoices: taskFieldChoices,
  fieldControl,
  openField,
  sendUpdateTask,
  // The status token in a table is the control that changes it: a slice's member
  // table draws its own rows as markup and opens the shared menu from there, and
  // a container that is rebuilt closes the menu its rows own.
  openTaskStatusMenu,
  closeTaskStatusMenu,
  closeStatusMenuFor,
  getMyTasksOnly: () => myTasksOnly,
  isKanbanVisible: () => kanbanVisible,
  isRemindersVisible: () => remindersVisible,
  // Task detail panel
  selectedTaskId: () => selectedTaskId,
  selectedTaskConvId: () => selectedTaskConvId,
  selectTask,
  openTaskComments,
  clearTaskSelection,
  clearReminderSelection,
  selectedReminderAssetId: () => selectedReminderAssetId,
  selectReminder,
  confirmDiscardTaskEdits: confirmDiscardTaskEditsIfDirty,
  confirmDiscardReminderEdits: async () => !reminderDetailDirty || await window.NRCDialog.confirm(
    "Discard unsaved changes to this reminder?",
    { title: "UNSAVED CHANGES", confirmLabel: "Discard" },
  ),
  requestTasksForRoom: sendGetTasks,
  handleTaskEdgeChanged,
  // Note: Notes exports moved to window.NRCNotes
};

// =============================================================================
// FILTER UI
// =============================================================================

function toggleMyTasksFilter() {
  if (!myNickname) {
    logSystem("CANNOT FILTER BY TASKS: IDENTITY NOT AVAILABLE", "tasks", "WARN");
    return;
  }
  setAssigneeFilterFromPalette(myTasksOnly ? "all" : "me");
}

function updateFilterStatus() {
  const statusEl = document.getElementById("myTasksStatus");
  if (!statusEl) return;

  if (myTasksOnly) {
    statusEl.textContent = "MINE";
    statusEl.style.color = "var(--accent-highlight)";
  } else {
    statusEl.textContent = "ALL";
    statusEl.style.color = "var(--text-primary)";
  }
}

function initFilterState() {
  // Initialize new task view state system
  if (typeof initTaskViewState === "function") {
    initTaskViewState();
  }

  // Update status display
  updateFilterStatus();

  // Wire up sidebar row click handler
  const myTasksRow = document.getElementById("myTasksRow");
  if (myTasksRow) {
    myTasksRow.addEventListener("click", () => {
      window.NRCTasks.toggleMyTasksFilter();
    });
  }
}
