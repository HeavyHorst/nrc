// =============================================================================
// NRC VIEW MANAGER
// =============================================================================
// Centralizes mutually-exclusive main view switching.
// Views: "chat" | "systemLog" | "sullivan" | "kanban" | "reminders" | "notes" | "noteShare" | "sullivanShare" | "customers" | "attention"
//
// Each module still owns its own rendering and teardown logic.
// This module only handles:
//   1. Hiding all panels
//   2. Clearing cross-module selections
//   3. Showing the target panel's DOM element
//   4. Calling module-specific teardown
//   5. Persisting state and updating header buttons

let activeView = "chat";

const viewPageTitles = {
  chat: "MESSAGES",
  systemLog: "SYSTEM",
  sullivan: "SULLIVAN",
  kanban: "TASKS",
  reminders: "REMINDERS",
  attention: "ATTENTION",
  calendar: "CALENDAR",
  search: "SEARCH",
  notes: "NOTES",
  noteShare: "NOTE SHARE",
  sullivanShare: "SULLIVAN",
  customers: "CUSTOMERS",
};

function getActiveView() {
  return activeView;
}

function setActiveView(view, options = {}) {
  if (view === "customers" && !window.NRCCustomers?.isEnabled()) return;
  if (view === activeView) return;

  const leavingSullivan = (activeView === "sullivan" || activeView === "sullivanShare") &&
    view !== "sullivan" && view !== "sullivanShare";
  if (leavingSullivan && options.force !== true && window.NRCAI?.isWorkbenchBusy?.()) {
    logMessage(
      "Error",
      "SULLIVAN RUN IS PINNED TO ITS CURRENT CONTEXT; STOP OR WAIT BEFORE CHANGING VIEWS",
      window.NRCAI.getDisplayConvId?.(),
      { aiContextRoomId: window.NRCAI.getContextConvId?.() },
    );
    return;
  }

  document.body.classList.toggle("note-share-focused", view === "noteShare");
  document.body.classList.toggle("sullivan-share-focused", view === "sullivanShare");
  document.body.classList.toggle("non-chat-view", view !== "chat");

  if (activeView === "systemLog" && view !== "systemLog" && window.NRCSystemLog?.exit) {
    window.NRCSystemLog.exit({ restoreView: false });
  }

  const chatDialog = document.getElementById("chatDialog");
  const kanbanPanel = document.getElementById("kanbanPanel");
  const remindersPanel = document.getElementById("remindersPanel");
  const notesPanel = document.getElementById("notesPanel");
  const noteSharePanel = document.getElementById("noteSharePanel");
  const customersPanel = document.getElementById("customersPanel");
  const attentionPanel = document.getElementById("attentionPanel");
  const calendarPanel = document.getElementById("calendarPanel");
  const searchPanel = document.getElementById("workspaceSearchPanel");

  // --- Teardown previous view ---

  if (activeView === "kanban") {
    kanbanVisible = false;
  }

  if (activeView === "reminders") {
    remindersVisible = false;
  }

  if (activeView === "notes") {
    notesViewActive = false;
  }

  if (activeView === "noteShare" && view !== "noteShare" && window.NRCNotes?.clearSharedNoteView) {
    window.NRCNotes.clearSharedNoteView();
  }

  if (activeView === "sullivanShare" && view !== "sullivanShare" && window.NRCAI?.clearSullivanShareMode) {
    window.NRCAI.clearSullivanShareMode();
  }

  const inputPanel = document.querySelector(".input-panel");

  // --- Hide all panels ---
  if (chatDialog) chatDialog.style.display = "none";
  if (kanbanPanel) kanbanPanel.style.display = "none";
  if (remindersPanel) remindersPanel.style.display = "none";
  if (notesPanel) notesPanel.style.display = "none";
  if (noteSharePanel) noteSharePanel.style.display = "none";
  if (customersPanel) customersPanel.style.display = "none";
  if (attentionPanel) attentionPanel.style.display = "none";
  if (calendarPanel) calendarPanel.style.display = "none";
  if (searchPanel) searchPanel.style.display = "none";

  // Hide input panel for non-chat views. Sullivan share is still an interactive chat.
  if (inputPanel) inputPanel.style.display = view === "chat" || view === "sullivan" || view === "sullivanShare" ? "" : "none";

  // --- Show target panel ---
  activeView = view;
  document.body.classList.toggle("customers-view", view === "customers");
  window.NRCChat?.syncComposer?.();
  window.NRCInspector?.setActiveView(view);
  window.NRCPageTitle?.set(viewPageTitles[view] || "");

  // Sullivan renders into the shared chat output. Restore the selected room as
  // soon as Sullivan is left so intermediate views cannot preserve its DOM.
  if (leavingSullivan && typeof loadRoomHistory === "function") {
    loadRoomHistory(currentRoomId);
  } else if (view === "chat" && typeof loadRoomHistory === "function") {
    // Messages received in another view are stored without being appended to
    // the hidden chat DOM. Render the complete current-room history on return.
    loadRoomHistory(currentRoomId);
  }
  window.NRCChatUnread?.onViewChanged?.(view);
  window.NRCAttention?.onViewChanged?.(view);
  window.NRCCalendar?.onViewChanged?.(view);

  switch (view) {
    case "chat":
      if (chatDialog) chatDialog.style.display = "flex";
      break;
    case "systemLog":
      if (chatDialog) chatDialog.style.display = "flex";
      break;
    case "sullivan":
    case "sullivanShare":
      if (chatDialog) chatDialog.style.display = "flex";
      break;
    case "kanban":
      kanbanVisible = true;
      if (kanbanPanel) kanbanPanel.style.display = "flex";
      break;
    case "reminders":
      remindersVisible = true;
      if (remindersPanel) remindersPanel.style.display = "flex";
      if (window.NRCTasks) window.NRCTasks.renderReminderQueue();
      break;
    case "attention":
      if (attentionPanel) attentionPanel.style.display = "flex";
      break;
    case "calendar":
      if (calendarPanel) calendarPanel.style.display = "flex";
      break;
    case "notes":
      notesViewActive = true;
      if (notesPanel) notesPanel.style.display = "flex";
      break;
    case "search":
      if (searchPanel) searchPanel.style.display = "flex";
      break;
    case "noteShare":
      if (noteSharePanel) noteSharePanel.style.display = "flex";
      break;
    case "customers":
      if (customersPanel) customersPanel.style.display = "flex";
      window.NRCCustomers.reload();
      break;
  }

  window.NRCWorkspaceSearch?.onViewChanged(view);
  if (view !== "noteShare" && view !== "sullivanShare" && typeof saveUIState === "function") saveUIState();
  if (typeof updateHeaderButtons === "function") updateHeaderButtons();
  if (typeof updateRoomUI === "function") updateRoomUI();
  if (typeof updateDMListUI === "function") updateDMListUI();
  window.NRCAI?.updateAskContextChip?.();
}

window.NRCViewManager = {
  getActiveView,
  setActiveView,
};
