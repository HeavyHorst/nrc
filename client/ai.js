// =============================================================================
// NRC AI MODULE
// =============================================================================

(function () {
  let activePortal = null;
  let activeKeyHandler = null;
  let aiServiceAvailable = null; // null=unknown, true/false after first call
  let pendingNoteEdges = null; // tracks note+task creation for edge linking
  const askSessionByContext = new Map(); // key: "displayConv:contextConv" -> session_id
  const askPlanByDisplayConv = new Map(); // key: displayConv -> latest pending action plan
  const askLastContextByDisplayConv = new Map(); // key: displayConv -> contextConv
  let assetPreviewHideTimer = null;
  let assetPreviewPortal = null;

  const AI_DM_WAIT_TIMEOUT_MS = 6000;
  const AI_DM_POLL_MS = 120;
  const AI_BOT_PREFIX = "sullivan-";
  const ASK_CONTEXT_STORAGE_PREFIX = "nrc.askContext";
  const ASK_LAST_NON_DM_PREFIX = "nrc.askLastNonDM";
  const SULLIVAN_MODE = "plan";
  let sullivanShareContextConvId = null;
  let sullivanDisplayConvId = null;
  let sullivanOpenSequence = 0;
  let activeSullivanOpenController = null;
  let activeSullivanOpenDisplayConvId = null;
  let activeAskRun = null;
  let activeActionPlanApply = null;
  let aiRunSequence = 0;
  let aiPlanSequence = 0;

  function isWorkbenchBusy() {
    return !!activeAskRun || !!activeActionPlanApply;
  }

  function isSullivanView() {
    const view = window.NRCViewManager?.getActiveView?.();
    return view === "sullivan" || view === "sullivanShare";
  }

  function getDisplayConvId() {
    return sullivanDisplayConvId;
  }

  function getContextConvId() {
    return sullivanDisplayConvId == null ? null : resolveAskContextForDisplay(sullivanDisplayConvId).contextConvId;
  }

  function getContextForDisplay(displayConvId) {
    return resolveAskContextForDisplay(BigInt(displayConvId)).contextConvId;
  }

  function cancelSullivanOpen() {
    sullivanOpenSequence++;
    activeSullivanOpenController?.abort();
    activeSullivanOpenController = null;
    activeSullivanOpenDisplayConvId = null;
  }

  function logWorkbenchMessage(type, message, displayConvId = sullivanDisplayConvId, contextConvId = null, metadata = {}) {
    const resolvedContextConvId = contextConvId ?? (
      displayConvId == null ? null : resolveAskContextForDisplay(displayConvId).contextConvId
    );
    logMessage(type, message, displayConvId, {
      ...metadata,
      aiContextRoomId: resolvedContextConvId,
    });
  }

  function setRunBusy(run = activeAskRun) {
    const inSullivan = isSullivanView() && sullivanDisplayConvId != null;
    const ownsRun = !!run && String(run.displayConvId) === String(sullivanDisplayConvId);
    const ownsApply = !!activeActionPlanApply && String(activeActionPlanApply.displayConvId) === String(sullivanDisplayConvId);
    const busy = inSullivan && (ownsRun || ownsApply);
    const send = document.getElementById("sullivanSend");
    const stop = document.getElementById("sullivanStop");
    if (send) send.disabled = busy;
    if (stop) stop.hidden = !(ownsRun && inSullivan);
    messageInput.disabled = busy;
    ["askResetChip", "askClearViewChip"].forEach((id) => {
      const control = document.getElementById(id);
      if (control) control.disabled = busy;
    });
    const contextSelect = document.getElementById("askContextChip");
    if (contextSelect) contextSelect.disabled = true;
    if (busy) closeAskContextPicker();
    document.getElementById("sullivanComposerBar")?.setAttribute("aria-busy", String(busy));
    document.querySelectorAll(".ai-response-actions [data-requires-idle=true]").forEach((control) => {
      control.disabled = isWorkbenchBusy();
    });
    if (typeof updateDMListUI === "function") updateDMListUI();
    refreshActionPlanCards();
  }

  function renderEmptyState() {
    const output = document.getElementById("logOutput");
    if (!output || output.children.length || !isSullivanView() || sullivanDisplayConvId == null) return;
    const { contextConvId } = resolveAskContextForDisplay(sullivanDisplayConvId);
    const state = document.createElement("section");
    state.className = "sullivan-empty";
    const heading = document.createElement("strong");
    heading.textContent = "SULLIVAN / WORKBENCH READY";
    const context = document.createElement("div");
    context.textContent = `CONTEXT: ${getRoomName(contextConvId)} · MODE: PLAN · HISTORY: EPHEMERAL`;
    const guidance = document.createElement("div");
    guidance.textContent = "Sullivan may propose changes; nothing is applied without explicit approval.";
    const examples = document.createElement("ul");
    ["Summarize open decisions and cite the evidence.", "Find blocked tasks and explain each blocker.", "Propose a plan for this room's next milestone."].forEach((text) => {
      const item = document.createElement("li");
      item.textContent = text;
      examples.appendChild(item);
    });
    state.append(heading, context, guidance, examples);
    output.appendChild(state);
  }

  function updateWorkbenchUI() {
    const active = isSullivanView() && sullivanDisplayConvId != null;
    document.body.classList.toggle("sullivan-workbench", active);
    const bar = document.getElementById("sullivanComposerBar");
    if (!bar) return;
    bar.hidden = !active;
    if (!active) {
      messageInput.placeholder = "";
      setRunBusy(null);
      return;
    }
    const title = document.getElementById("chatHeaderTitle");
    if (title) title.textContent = "SULLIVAN / AI WORKBENCH";
    const context = resolveAskContextForDisplay(sullivanDisplayConvId).contextConvId;
    document.getElementById("sullivanComposerContext").textContent = `CONTEXT / ${getRoomName(context)}`;
    messageInput.placeholder = "";
    setRunBusy(activeAskRun);
    document.querySelector("#logOutput > .sullivan-empty")?.remove();
    renderEmptyState();
  }

  function askContextStorageKey(displayConvId) {
    return `${ASK_CONTEXT_STORAGE_PREFIX}:${currentWorkspaceId}:${String(displayConvId)}`;
  }

  function askLastNonDMStorageKey() {
    return `${ASK_LAST_NON_DM_PREFIX}:${currentWorkspaceId}`;
  }

  function parseStoredConvID(raw) {
    if (raw == null || raw === "") return null;
    try {
      return BigInt(raw);
    } catch {
      return null;
    }
  }

  function persistAskContext(displayConvId, contextConvId) {
    try {
      localStorage.setItem(
        askContextStorageKey(displayConvId),
        String(contextConvId),
      );
    } catch {
      // Ignore storage failures; in-memory behavior still works.
    }
  }

  function readPersistedAskContext(displayConvId) {
    try {
      return parseStoredConvID(localStorage.getItem(askContextStorageKey(displayConvId)));
    } catch {
      return null;
    }
  }

  function clearPersistedAskContext(displayConvId) {
    try {
      localStorage.removeItem(askContextStorageKey(displayConvId));
    } catch {
      // Ignore storage failures.
    }
  }

  function rememberLastNonDMRoom(convId) {
    if (typeof isDMConversation === "function" && isDMConversation(convId)) return;
    try {
      localStorage.setItem(askLastNonDMStorageKey(), String(convId));
    } catch {
      // Ignore storage failures.
    }
  }

  function readLastNonDMRoom() {
    try {
      return parseStoredConvID(localStorage.getItem(askLastNonDMStorageKey()));
    } catch {
      return null;
    }
  }

  function isConversationAvailable(convId) {
    if (convId == null) return false;
    const id = BigInt(convId);
    if (typeof isDMConversation === "function" && isDMConversation(id)) {
      const dm = activeDMs?.get(id);
      return !!(dm && !dm.optimistic);
    }
    return !!subscribedRooms?.has(id);
  }

  function setAskContext(displayConvId, contextConvId, persist = true) {
    const displayID = BigInt(displayConvId);
    const contextID = 0n;
    const previousContextID = askLastContextByDisplayConv.get(String(displayID));
    if (previousContextID != null && previousContextID !== String(contextID)) {
      invalidateActionPlans(String(displayID));
    }
    askLastContextByDisplayConv.set(String(displayID), String(contextID));
    if (persist) {
      persistAskContext(displayID, contextID);
    }
  }

  function resolveAskContextForDisplay(displayConvId) {
    return { contextConvId: 0n, source: "workspace" };
  }

  function buildContextPickerOptions() {
    const options = [];

    const roomIDs = Array.from(subscribedRooms || [])
      .filter((id) => !(typeof isDMConversation === "function" && isDMConversation(id)))
      .sort((a, b) => {
        if (a === 1n) return -1;
        if (b === 1n) return 1;
        return Number(a - b);
      });
    roomIDs.forEach((id) => {
      options.push({ convId: id, label: getRoomName(id) });
    });

    const dmEntries = Array.from(activeDMs || [])
      .filter(([, dm]) => dm && !dm.optimistic)
      .sort((a, b) => {
        const an = (a[1]?.username || "").toLowerCase();
        const bn = (b[1]?.username || "").toLowerCase();
        return an.localeCompare(bn);
      });
    dmEntries.forEach(([convId]) => {
      options.push({ convId: BigInt(convId), label: getRoomName(BigInt(convId)) });
    });

    return options;
  }

  function closeAskContextPicker() {
    const select = document.getElementById("askContextChip");
    if (select) CustomSelect.close(select);
  }

  function ensureAskContextChip() {
    let chip = document.getElementById("askContextChip");
    if (chip) return chip;

    const container = document.getElementById("chatHeaderAIControls");
    if (!container) return null;

    const cell = document.createElement("div");
    cell.className = "header-filter-cell ask-context-chip";
    const label = document.createElement("label");
    label.className = "filter-label";
    label.htmlFor = "askContextChip";
    label.textContent = "CONTEXT";
    chip = document.createElement("select");
    chip.id = "askContextChip";
    chip.className = "filter-select";
    chip.setAttribute("data-custom-select", "");
    chip.setAttribute("data-custom-select-portal", "");
    chip.setAttribute("data-custom-select-search-placeholder", "FILTER CONTEXT...");
    chip.title = "Choose Sullivan context";
    chip.addEventListener("change", () => {
      if (chip.disabled || sullivanDisplayConvId == null) return;
      const displayConvId = BigInt(sullivanDisplayConvId);
      const convId = BigInt(chip.value);
      setAskContext(displayConvId, convId, true);
      updateAskContextChip();
      if (typeof updateRoomUI === "function") updateRoomUI();
      loadRoomHistory(displayConvId, { aiContextRoomId: convId });
      logSystem(`SULLIVAN CONTEXT SET: ${getRoomName(convId)}`, "ai");
    });

    const control = document.createElement("nrc-select");
    control.append(chip);
    cell.append(label, control);
    container.appendChild(cell);
    return chip;
  }

  function ensureAskResetButton() {
    let button = document.getElementById("askResetChip");
    if (button) return button;

    const container = document.getElementById("chatHeaderAIControls");
    if (!container) return null;

    button = document.createElement("button");
    button.type = "button";
    button.id = "askResetChip";
    button.className = "btn btn--primary header-operation ask-reset-chip header-register-control header-create-action";
    button.style.display = "none";
    button.textContent = "+ SESSION";
    button.title = "Reset the AI session and begin a fresh transcript";
    button.addEventListener("click", async (event) => {
      event.preventDefault();
      event.stopPropagation();

      if (isWorkbenchBusy()) return;
      const displayConvId = BigInt(sullivanDisplayConvId);
      const contextConvId = resolveAskContextForDisplay(displayConvId).contextConvId;
      resetAskSession(contextConvId, displayConvId);

      if (window.NRCChat?.clearCurrentRoomMessages) {
        await window.NRCChat.clearCurrentRoomMessages({ logResult: false, roomId: displayConvId, aiContextRoomId: contextConvId });
      }

      renderEmptyState();
    });

    container.appendChild(button);
    const clear = document.createElement("button");
    clear.type = "button";
    clear.id = "askClearViewChip";
    clear.className = "btn header-operation header-register-control";
    clear.textContent = "CLEAR VIEW";
    clear.title = "Clear this ephemeral transcript without resetting the AI session";
    clear.addEventListener("click", async () => {
      if (isWorkbenchBusy()) return;
      const displayConvId = BigInt(sullivanDisplayConvId);
      const contextConvId = resolveAskContextForDisplay(displayConvId).contextConvId;
      await window.NRCChat?.clearCurrentRoomMessages?.({ logResult: false, roomId: displayConvId, aiContextRoomId: contextConvId });
      invalidateActionPlans(String(displayConvId));
      renderEmptyState();
    });
    container.appendChild(clear);
    return button;
  }

  function ensureSullivanShareButton() {
    let button = document.getElementById("sullivanShareChip");
    if (button) return button;

    const container = document.getElementById("chatHeaderAIControls");
    if (!container) return null;

    button = document.createElement("button");
    button.type = "button";
    button.id = "sullivanShareChip";
    button.className = "btn header-operation ask-share-chip header-register-control";
    button.style.display = "none";
    button.textContent = "SHARE";
    button.title = "Copy focused Sullivan link for this context";
    button.addEventListener("click", async (event) => {
      event.preventDefault();
      event.stopPropagation();

      const displayConvId = BigInt(sullivanDisplayConvId);
      const { contextConvId } = resolveAskContextForDisplay(displayConvId);
      const url = getSullivanShareUrl(contextConvId);
      try {
        await navigator.clipboard.writeText(url);
        window.NRCDialog.notify("SULLIVAN CONTEXT LINK COPIED");
        logSystem(`COPIED SULLIVAN CONTEXT LINK: ${getRoomName(contextConvId)}`, "ai");
      } catch (err) {
        console.warn("Failed to copy Sullivan share link", err);
        await window.NRCDialog.prompt("Clipboard access failed. Copy this Sullivan link:", {
          title: "COPY SULLIVAN LINK",
          initialValue: url,
        });
      }
    });

    container.appendChild(button);
    return button;
  }

  function ensureSullivanOpenNrcButton() {
    let button = document.getElementById("sullivanOpenNrcChip");
    if (button) return button;

    const container = document.getElementById("chatHeaderAIControls");
    if (!container) return null;

    button = document.createElement("button");
    button.type = "button";
    button.id = "sullivanOpenNrcChip";
    button.className = "btn header-operation ask-open-nrc-chip header-register-control";
    button.style.display = "none";
    button.textContent = "OPEN IN NRC";
    button.title = "Exit focused Sullivan view";
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      exitSullivanShareMode();
    });

    container.appendChild(button);
    return button;
  }

  function updateAskContextChip() {
    const chip = ensureAskContextChip();
    const resetButton = ensureAskResetButton();
    const shareButton = ensureSullivanShareButton();
    const openNrcButton = ensureSullivanOpenNrcButton();
    const container = document.getElementById("chatHeaderAIControls");
    if (!chip || !resetButton || !shareButton || !openNrcButton || !container) return;

    if (!isSullivanView() || sullivanDisplayConvId == null) {
      closeAskContextPicker();
      container.style.display = "none";
      resetButton.style.display = "none";
      shareButton.style.display = "none";
      openNrcButton.style.display = "none";
      updateWorkbenchUI();
      return;
    }

    const displayConvId = BigInt(sullivanDisplayConvId);
    if (typeof isAIDMConversation !== "function" || !isAIDMConversation(displayConvId)) {
      closeAskContextPicker();
      container.style.display = "none";
      resetButton.style.display = "none";
      shareButton.style.display = "none";
      openNrcButton.style.display = "none";
      updateWorkbenchUI();
      return;
    }

    const { contextConvId } = resolveAskContextForDisplay(displayConvId);
    const options = [{ convId: 0n, label: "WORKSPACE" }];
    chip.replaceChildren(...options.map((option) => new Option(option.label, String(option.convId))));
    chip.value = String(contextConvId);
    chip.disabled = true;
    chip.title = "Sullivan uses durable workspace content";
    container.style.display = "inline-flex";
    resetButton.style.display = "inline-flex";
    shareButton.style.display = "inline-flex";
    openNrcButton.style.display = sullivanShareContextConvId != null && window.NRCViewManager?.getActiveView?.() === "sullivanShare" ? "inline-flex" : "none";
    updateWorkbenchUI();
  }

  function onRoomChanged(roomId = currentRoomId) {
    if (roomId == null) {
      updateAskContextChip();
      return;
    }

    const activeRoomId = BigInt(roomId);
    if (!(typeof isDMConversation === "function" && isDMConversation(activeRoomId))) {
      rememberLastNonDMRoom(activeRoomId);
    }
    updateAskContextChip();
  }

  function onSelectedRoomChanged(roomId) {
    if (!isSullivanView() || sullivanDisplayConvId == null || isWorkbenchBusy()) return;
    setAskContext(sullivanDisplayConvId, 0n, true);
    updateAskContextChip();
    loadRoomHistory(sullivanDisplayConvId, { aiContextRoomId: 0n });
  }

  function onDisplayConversationRemoved(convId) {
    if (String(convId) !== String(sullivanDisplayConvId)) return;
    const removedDisplayOwnedByOpen = activeSullivanOpenController != null &&
      String(activeSullivanOpenDisplayConvId) === String(convId);
    if (removedDisplayOwnedByOpen) cancelSullivanOpen();
    if (activeAskRun && String(activeAskRun.displayConvId) === String(convId)) {
      activeAskRun.controller.abort();
      activeAskRun = null;
    }
    sullivanDisplayConvId = null;
    sullivanShareContextConvId = null;
    if (isSullivanView()) window.NRCViewManager?.setActiveView?.("chat", { force: true });
    loadRoomHistory(currentRoomId);
  }

  function setKeyHandler(handler) {
    if (activeKeyHandler) {
      document.removeEventListener("keydown", activeKeyHandler);
    }
    activeKeyHandler = handler;
    if (handler) {
      document.addEventListener("keydown", handler);
    }
  }

  function showAiLoading(title, inputText) {
    if (activePortal) {
      activePortal.destroy();
      activePortal = null;
    }

    const container = document.createElement("div");
    container.className = "ai-preview ai-ask-preview";

    const header = buildAiPortalHeader(title);
    container.appendChild(header);

    const contextEl = document.createElement("div");
    contextEl.className = "ai-ask-question";
    const preview = inputText.length > 80 ? inputText.slice(0, 80) + "..." : inputText;
    contextEl.textContent = preview;
    container.appendChild(contextEl);

    const loadingEl = document.createElement("div");
    loadingEl.className = "ai-ask-loading";
    loadingEl.textContent = "PROCESSING ...";
    container.appendChild(loadingEl);

    activePortal = Portal.create(container, messageInput, {
      position: "top",
      align: "left",
      matchWidth: true,
      offsetY: 4,
    });
    activePortal.show();

    setKeyHandler(function onKeyDown(e) {
      if (e.key === "Escape") {
        e.preventDefault();
        if (activePortal) { activePortal.hide(); activePortal = null; }
        setKeyHandler(null);
      }
    });
  }

  // -- Paste-to-Task --
  async function handlePasteToTask(rawText) {
    showAiLoading("AI TASK EXTRACTION", rawText);

    try {
      const response = await fetch(getAiUrl() + "/paste-to-task", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          workspace: currentWorkspaceId,
          conv_id: "0",
          raw_text: rawText,
        }),
      });

      if (!response.ok) {
        const errText = await response.text();
        if (activePortal) { activePortal.hide(); activePortal = null; }
        logMessage("Error", `AI SERVICE ERROR: ${response.status} ${errText}`);
        return;
      }

      aiServiceAvailable = true;
      const data = await response.json();
      showTaskPreview(data.task);
    } catch (err) {
      aiServiceAvailable = false;
      if (activePortal) { activePortal.hide(); activePortal = null; }
      logMessage("Error", `AI SERVICE UNAVAILABLE: ${err.message}`);
    }
  }

  function showTaskPreview(task) {
    if (activePortal) {
      activePortal.destroy();
      activePortal = null;
    }

    const container = document.createElement("div");
    container.className = "ai-preview ai-task-preview";

    // Header
    const header = buildAiPortalHeader("AI TASK EXTRACTION");
    container.appendChild(header);

    // Title field (editable)
    const titleRow = createEditableField("TITLE", task.title, "ai-task-title");
    container.appendChild(titleRow);

    // Description preview (plain markdown text)
    const descPreview = document.createElement("div");
    descPreview.className = "ai-note-content-preview";
    const desc = task.description || "";
    descPreview.textContent = desc.length > 200 ? desc.slice(0, 200) + "..." : desc;
    container.appendChild(descPreview);
    container.dataset.taskDesc = desc;

    // Store raw metadata as data attributes
    container.dataset.priority = task.priority || 0;
    container.dataset.status = (task.status || "backlog").toUpperCase();
    container.dataset.color = (task.color || "none").toUpperCase();

    // Metadata row: priority, status, color
    const metaRow = document.createElement("div");
    metaRow.className = "ai-preview-meta";

    const priorityLabel = document.createElement("span");
    priorityLabel.className = "ai-meta-item";
    priorityLabel.textContent = `PRI:${task.priority}`;

    const statusLabel = document.createElement("span");
    statusLabel.className = "ai-meta-item";
    statusLabel.textContent = `STS:${container.dataset.status}`;

    const colorLabel = document.createElement("span");
    colorLabel.className = "ai-meta-item";
    colorLabel.textContent = `CLR:${container.dataset.color}`;

    metaRow.appendChild(priorityLabel);
    metaRow.appendChild(statusLabel);
    metaRow.appendChild(colorLabel);
    container.appendChild(metaRow);

    // Actions: confirm
    const actions = document.createElement("div");
    actions.className = "ai-preview-actions";

    const confirmBtn = document.createElement("button");
    confirmBtn.className = "btn btn--primary btn--icon ai-confirm-btn";
    confirmBtn.textContent = "+";
    confirmBtn.title = "Create task (Enter)";
    confirmBtn.addEventListener("click", () => {
      createTaskFromPreview(container);
    });

    actions.appendChild(confirmBtn);
    container.appendChild(actions);

    // Create portal anchored to input area, position: top
    activePortal = Portal.create(container, messageInput, {
      position: "top",
      align: "left",
      matchWidth: true,
      offsetY: 4,
    });
    activePortal.show();

    // Focus title for editing
    const titleInput = container.querySelector("#ai-task-title");
    if (titleInput) titleInput.focus();

    // Handle Esc/Enter globally while portal is visible
    setKeyHandler(function onKeyDown(e) {
      if (e.key === "Escape") {
        e.preventDefault();
        if (activePortal) {
          activePortal.hide();
          activePortal = null;
        }
        setKeyHandler(null);
      } else if (e.key === "Enter" && !e.shiftKey) {
        if (container.contains(document.activeElement)) {
          e.preventDefault();
          createTaskFromPreview(container);
          setKeyHandler(null);
        }
      }
    });
  }

  function createEditableField(label, value, id) {
    const row = document.createElement("div");
    row.className = "ai-preview-field";

    const lbl = document.createElement("label");
    lbl.className = "ai-field-label";
    lbl.textContent = label;
    lbl.setAttribute("for", id);

    const input = document.createElement("input");
    input.type = "text";
    input.className = "ai-field-input";
    input.id = id;
    input.value = value || "";

    row.appendChild(lbl);
    row.appendChild(input);
    return row;
  }

  function createTaskFromPreview(container) {
    const title = container.querySelector("#ai-task-title")?.value?.trim();
    const desc = container.dataset.taskDesc || "";

    if (!title) {
      logMessage("Error", "TASK TITLE REQUIRED");
      return;
    }

    const priority = parseInt(container.dataset.priority) || 0;
    const status = statusFromString(container.dataset.status || "BACKLOG");
    const color = colorFromString(container.dataset.color || "NONE");

    let taskErrorHandled = false;
    const correlationId = sendCreateTask(
      0n,
      title,
      desc,
      priority,
      color,
      "",
      0n,
      [],
      status,
      0,
      "",
      {
        onSuccess: ({ task }) => logMessage("CommandResult", `✓ AI TASK #${task.id} CREATED: ${task.title}`),
        onError: (error) => {
          taskErrorHandled = true;
          logMessage("Error", `AI TASK CREATE FAILED: ${error?.message || "SERVER REJECTED REQUEST"}`);
        },
      },
    );
    if (!correlationId && !taskErrorHandled) logMessage("Error", "AI TASK CREATE FAILED: NOT CONNECTED");

    if (activePortal) {
      activePortal.hide();
      activePortal = null;
    }
  }

  function statusFromString(s) {
    switch (s) {
      case "TODO":
        return TaskStatus.Todo;
      case "IN PROGRESS":
        return TaskStatus.InProgress;
      case "DONE":
        return TaskStatus.Done;
      case "NOTE":
        return TaskStatus.Note;
      default:
        return TaskStatus.Backlog;
    }
  }

  function colorFromString(c) {
    switch (c) {
      case "CYAN":
        return TaskColor.Cyan;
      case "RED":
        return TaskColor.Red;
      case "GREEN":
        return TaskColor.Green;
      case "GRAY":
        return TaskColor.Gray;
      case "GOLD":
        return TaskColor.Gold;
      default:
        return TaskColor.None;
    }
  }

  // -- Paste-to-Note --
  async function handlePasteToNote(rawText) {
    showAiLoading("AI NOTE EXTRACTION", rawText);

    try {
      const response = await fetch(getAiUrl() + "/paste-to-note", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          workspace: currentWorkspaceId,
          conv_id: "0",
          raw_text: rawText,
          extract_tasks: true,
        }),
      });

      if (!response.ok) {
        const errText = await response.text();
        if (activePortal) { activePortal.hide(); activePortal = null; }
        logMessage("Error", `AI SERVICE ERROR: ${response.status} ${errText}`);
        return;
      }

      aiServiceAvailable = true;
      const data = await response.json();
      showNotePreview(data);
    } catch (err) {
      aiServiceAvailable = false;
      if (activePortal) { activePortal.hide(); activePortal = null; }
      logMessage("Error", `AI SERVICE UNAVAILABLE: ${err.message}`);
    }
  }

  function showNotePreview(data) {
    if (activePortal) {
      activePortal.destroy();
      activePortal = null;
    }

    const container = document.createElement("div");
    container.className = "ai-preview ai-note-preview";

    // Header
    const header = buildAiPortalHeader("AI NOTE EXTRACTION");
    container.appendChild(header);

    // Note title
    const titleRow = createEditableField(
      "TITLE",
      data.note?.title || "",
      "ai-note-title",
    );
    container.appendChild(titleRow);

    const projectRow = createEditableField(
      "PROJECT",
      data.note?.project || "",
      "ai-note-project",
    );
    container.appendChild(projectRow);

    const tagsRow = createEditableField(
      "TAGS",
      Array.isArray(data.note?.tags) ? data.note.tags.join(", ") : "",
      "ai-note-tags",
    );
    container.appendChild(tagsRow);

    // Note content preview (truncated)
    const contentPreview = document.createElement("div");
    contentPreview.className = "ai-note-content-preview";
    const content = data.note?.content || "";
    contentPreview.textContent =
      content.length > 200 ? content.slice(0, 200) + "..." : content;
    container.appendChild(contentPreview);

    // Store full content as data attribute
    container.dataset.noteContent = content;

    // Extracted tasks (toggleable)
    const tasks = data.extracted_tasks || [];
    if (tasks.length > 0) {
      const tasksHeader = document.createElement("div");
      tasksHeader.className = "ai-preview-subheader";
      tasksHeader.textContent = `EXTRACTED TASKS (${tasks.length})`;
      container.appendChild(tasksHeader);

      tasks.forEach((task, i) => {
        const taskRow = document.createElement("div");
        taskRow.className = "ai-extracted-task";

        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.checked = true;
        checkbox.id = `ai-extract-task-${i}`;
        checkbox.dataset.index = i;

        const label = document.createElement("label");
        label.setAttribute("for", `ai-extract-task-${i}`);
        label.textContent = task.title;

        taskRow.appendChild(checkbox);
        taskRow.appendChild(label);
        container.appendChild(taskRow);
      });
    }

    // Suggested links (note-to-note)
    const suggestedLinks = data.suggested_links || [];
    if (suggestedLinks.length > 0) {
      const linksHeader = document.createElement("div");
      linksHeader.className = "ai-preview-subheader";
      linksHeader.textContent = `SUGGESTED LINKS (${suggestedLinks.length})`;
      container.appendChild(linksHeader);

      suggestedLinks.forEach((link, i) => {
        const linkRow = document.createElement("div");
        linkRow.className = "ai-extracted-task";

        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.checked = true;
        checkbox.id = `ai-suggest-link-${i}`;
        checkbox.dataset.index = i;

        const label = document.createElement("label");
        label.setAttribute("for", `ai-suggest-link-${i}`);
        label.textContent = `${link.title} [${link.relation}]`;

        linkRow.appendChild(checkbox);
        linkRow.appendChild(label);
        container.appendChild(linkRow);
      });
    }

    // Store tasks and suggested links data
    container.dataset.extractedTasks = JSON.stringify(tasks);
    container.dataset.suggestedLinks = JSON.stringify(suggestedLinks);

    // Actions
    const actions = document.createElement("div");
    actions.className = "ai-preview-actions";

    const confirmBtn = document.createElement("button");
    confirmBtn.className = "btn btn--primary btn--icon ai-confirm-btn";
    confirmBtn.textContent = "+";
    confirmBtn.title = "Create note and tasks (Enter)";
    confirmBtn.addEventListener("click", () => {
      createNoteFromPreview(container);
    });

    actions.appendChild(confirmBtn);
    container.appendChild(actions);

    activePortal = Portal.create(container, messageInput, {
      position: "top",
      align: "left",
      matchWidth: true,
      offsetY: 4,
    });
    activePortal.show();

    setKeyHandler(function onKeyDown(e) {
      if (e.key === "Escape") {
        e.preventDefault();
        if (activePortal) {
          activePortal.hide();
          activePortal = null;
        }
        setKeyHandler(null);
      } else if (
        e.key === "Enter" &&
        !e.shiftKey &&
        container.contains(document.activeElement)
      ) {
        e.preventDefault();
        createNoteFromPreview(container);
        setKeyHandler(null);
      }
    });
  }

  function createNoteFromPreview(container) {
    const title = container.querySelector("#ai-note-title")?.value?.trim();
    const project = container.querySelector("#ai-note-project")?.value?.trim() || "";
    const tags = String(container.querySelector("#ai-note-tags")?.value || "")
      .split(",")
      .map((tag) => tag.trim())
      .filter(Boolean);
    const content = normalizeNoteContentTitleDuplication(
      title,
      container.dataset.noteContent || "",
    );

    if (!title) {
      logMessage("Error", "NOTE TITLE REQUIRED");
      return;
    }

    const genId = window.NRCAssets.generateCorrelationId;

    // Generate correlation IDs for all creates so we can match responses
    const noteCorrelationId = genId();

    // Create the note asset (uses notes.js for proper JSON preview format)
    window.NRCNotes.sendCreateNote(title, content, noteCorrelationId, project, tags);
    logMessage("CommandResult", `✓ AI NOTE CREATED: ${title}`);

    // Create enabled extracted tasks
    const tasks = JSON.parse(container.dataset.extractedTasks || "[]");
    const checkboxes = container.querySelectorAll('input[id^="ai-extract-task-"]');
    let taskCount = 0;
    const taskCorrelationIds = new Set();

    checkboxes.forEach((cb) => {
      if (cb.checked) {
        const idx = parseInt(cb.dataset.index);
        const task = tasks[idx];
        if (task) {
          const taskCorrId = genId();
          const priority = task.priority || 0;
          const status = statusFromString(
            (task.status || "backlog").toUpperCase(),
          );
          const color = colorFromString(
            (task.color || "none").toUpperCase(),
          );
          let taskErrorHandled = false;
          const sentCorrelationId = sendCreateTask(
            0n,
            task.title,
            task.description || "",
            priority,
            color,
            "",
            0n,
            [],
            status,
            taskCorrId,
            "",
            {
              onSuccess: ({ task: createdTask }) => logMessage("CommandResult", `✓ EXTRACTED TASK #${createdTask.id} CREATED: ${createdTask.title}`),
              onError: (error) => {
                taskErrorHandled = true;
                logMessage("Error", `EXTRACTED TASK CREATE FAILED: ${error?.message || "SERVER REJECTED REQUEST"}`);
                rejectPendingExtractedTask(taskCorrId);
              },
            },
          );
          if (sentCorrelationId) {
            taskCorrelationIds.add(sentCorrelationId);
            taskCount++;
          } else if (!taskErrorHandled) {
            logMessage("Error", `EXTRACTED TASK NOT SENT: ${task.title || "UNTITLED"}`);
          }
        }
      }
    });

    // Collect checked suggested links
    const suggestedLinks = JSON.parse(container.dataset.suggestedLinks || "[]");
    const linkCheckboxes = container.querySelectorAll('input[id^="ai-suggest-link-"]');
    const checkedLinks = [];

    linkCheckboxes.forEach((cb) => {
      if (cb.checked) {
        const idx = parseInt(cb.dataset.index);
        const link = suggestedLinks[idx];
        if (link) {
          checkedLinks.push(link);
        }
      }
    });

    if (taskCount > 0 || checkedLinks.length > 0) {
      setupPendingEdges(noteCorrelationId, taskCorrelationIds, taskCount, checkedLinks);
    }

    if (activePortal) {
      activePortal.hide();
      activePortal = null;
    }
  }

  function normalizeNoteContentTitleDuplication(title, content) {
    if (!title || !content) return content;

    const lines = content.split(/\r?\n/);
    let i = 0;
    while (i < lines.length && lines[i].trim() === "") i++;
    if (i >= lines.length) return content;

    const normalize = (value) =>
      value
        .trim()
        .toLowerCase()
        .replace(/\s+/g, " ");

    const normalizedTitle = normalize(title);
    const firstLine = lines[i];
    const firstTrimmed = firstLine.trim();
    let removeThrough = -1;

    // ATX heading: # Title
    const atxMatch = firstTrimmed.match(/^#{1,6}\s*(.*?)\s*#*\s*$/);
    if (atxMatch && normalize(atxMatch[1]) === normalizedTitle) {
      removeThrough = i;
    }

    // Setext heading:
    // Title
    // =====
    if (removeThrough < 0 && i + 1 < lines.length) {
      const underline = lines[i + 1].trim();
      if (/^(=+|-+)$/u.test(underline) && normalize(firstTrimmed) === normalizedTitle) {
        removeThrough = i + 1;
      }
    }

    // Plain first line identical to title
    if (removeThrough < 0 && normalize(firstTrimmed) === normalizedTitle) {
      removeThrough = i;
    }

    if (removeThrough < 0) return content;

    let start = removeThrough + 1;
    while (start < lines.length && lines[start].trim() === "") start++;
    return lines.slice(start).join("\n");
  }

  function relationStringToType(s) {
    const { RelationType } = window.NRCEdges;
    switch (s) {
      case "references": return RelationType.References;
      case "related-to": return RelationType.RelatedTo;
      case "depends-on": return RelationType.DependsOn;
      case "blocks": return RelationType.Blocks;
      case "derived-from": return RelationType.DerivedFrom;
      case "supersedes": return RelationType.Supersedes;
      default: return RelationType.RelatedTo;
    }
  }

  function setupPendingEdges(noteCorrelationId, taskCorrelationIds, taskCount, suggestedLinks = []) {
    cleanupPendingEdges();

    pendingNoteEdges = {
      noteCorrelationId,
      noteId: null,
      taskCorrelationIds, // Set of u32 correlation IDs
      expectedCount: taskCount,
      taskIds: [],
      suggestedLinks,
      roomId: 0n,
      timeoutId: setTimeout(handlePendingEdgesTimeout, 10000),
    };

    pendingNoteEdges.onAssetCreated = function (e) {
      if (!pendingNoteEdges) return;
      const { asset, correlationId } = e.detail;
      if (correlationId && correlationId === pendingNoteEdges.noteCorrelationId) {
        pendingNoteEdges.noteId = asset.assetId;
        tryFinalizeEdges();
      }
    };

    pendingNoteEdges.onTaskCreated = function (e) {
      if (!pendingNoteEdges) return;
      const { task, correlationId } = e.detail;
      if (correlationId && pendingNoteEdges.taskCorrelationIds.has(correlationId)) {
        pendingNoteEdges.taskCorrelationIds.delete(correlationId);
        pendingNoteEdges.taskIds.push(task.id);
        tryFinalizeEdges();
      }
    };

    document.addEventListener("nrc:asset-created", pendingNoteEdges.onAssetCreated);
    document.addEventListener("nrc:task-created", pendingNoteEdges.onTaskCreated);
  }

  function rejectPendingExtractedTask(correlationId) {
    if (!pendingNoteEdges || !pendingNoteEdges.taskCorrelationIds.delete(correlationId)) return;
    pendingNoteEdges.expectedCount = Math.max(0, pendingNoteEdges.expectedCount - 1);
    tryFinalizeEdges();
  }

  function tryFinalizeEdges() {
    if (!pendingNoteEdges) return;
    if (!pendingNoteEdges.noteId) return;
    if (pendingNoteEdges.taskIds.length < pendingNoteEdges.expectedCount) return;

    const { roomId, noteId, taskIds, suggestedLinks } = pendingNoteEdges;
    for (const taskId of taskIds) {
      window.NRCEdges.linkAssetToTask(roomId, noteId, taskId);
    }

    // Create note-to-note edges for suggested links (target IDs are already known)
    let linkCount = 0;
    for (const link of suggestedLinks) {
      const relation = relationStringToType(link.relation);
      window.NRCEdges.linkAssets(roomId, noteId, BigInt(link.asset_id), relation);
      linkCount++;
    }

    const parts = [];
    if (taskIds.length > 0) parts.push(`${taskIds.length} TASK(S)`);
    if (linkCount > 0) parts.push(`${linkCount} NOTE(S)`);
    if (parts.length > 0) {
      logMessage("CommandResult", `✓ LINKED NOTE TO ${parts.join(" AND ")}`);
    }
    cleanupPendingEdges();
  }

  function handlePendingEdgesTimeout() {
    if (!pendingNoteEdges) return;

    const taskLinked = pendingNoteEdges.taskIds.length;
    const taskExpected = pendingNoteEdges.expectedCount;
    const taskMissing = Math.max(0, taskExpected - taskLinked);
    const noteReady = pendingNoteEdges.noteId != null;
    const noteLinkCount = pendingNoteEdges.suggestedLinks.length;

    logMessage(
      "System",
      `AI NOTE LINKING TIMED OUT: NOTE READY=${noteReady ? "YES" : "NO"}, TASKS LINKED=${taskLinked}/${taskExpected}, TASKS MISSING=${taskMissing}, NOTE LINKS PENDING=${noteLinkCount}`,
    );

    cleanupPendingEdges();
  }

  function cleanupPendingEdges() {
    if (!pendingNoteEdges) return;
    clearTimeout(pendingNoteEdges.timeoutId);
    document.removeEventListener("nrc:asset-created", pendingNoteEdges.onAssetCreated);
    document.removeEventListener("nrc:task-created", pendingNoteEdges.onTaskCreated);
    pendingNoteEdges = null;
  }

  function closeActivePortal() {
    if (activePortal) {
      activePortal.hide();
      activePortal = null;
    }
    setKeyHandler(null);
  }

  function askContextKey(displayConvId, contextConvId) {
    return `${String(displayConvId)}:${String(contextConvId)}`;
  }

  function isAIBotUsername(username) {
    const normalized = String(username || "").toLowerCase();
    return normalized.startsWith(AI_BOT_PREFIX);
  }

  function findExistingAIDM(options = {}) {
    const onlineOnly = options.onlineOnly === true;
    if (typeof activeDMs === "undefined" || !activeDMs?.size) return null;

    for (const [convId, dm] of activeDMs) {
      if (!dm || dm.optimistic) continue;
      if (onlineOnly && !dm.online) continue;
      if (isAIBotUsername(dm.username)) {
        return { convId, username: dm.username, online: !!dm.online };
      }
    }
    return null;
  }

  function closeStaleAIDMs(keepConvId) {
    if (typeof activeDMs === "undefined" || !activeDMs?.size) return;
    if (typeof sendLeaveDM !== "function") return;

    for (const [convId, dm] of activeDMs) {
      if (!dm || dm.optimistic) continue;
      if (!isAIBotUsername(dm.username)) continue;
      if (convId === keepConvId) continue;
      if (dm.online) continue;

      sendLeaveDM(convId);
      logMessage("Activity", `CLOSING STALE AI DM: ${getRoomName(convId)}`, keepConvId);
    }
  }

  function findDMByUsername(username) {
    if (!username || typeof activeDMs === "undefined" || !activeDMs?.size) return null;
    for (const [convId, dm] of activeDMs) {
      if (!dm || dm.optimistic) continue;
      if (dm.username === username) {
        return { convId, username: dm.username };
      }
    }
    return null;
  }

  function findAIBotInPresence(users) {
    if (!users || users.size === 0) return null;
    for (const [username, info] of users) {
      if (!info) continue;
      const userType = info.userType;
      const isBotLike =
        userType === UserType.Bot || userType === UserType.System || userType === UserType.Admin;
      if (!isBotLike) continue;
      if (myNickname && username === myNickname) continue;
      if (isAIBotUsername(username)) {
        return { username };
      }
    }
    return null;
  }

  function findAIBotInCurrentRoom() {
    if (typeof roomPresence === "undefined") return null;
    return findAIBotInPresence(roomPresence.get(currentRoomId));
  }

  function findAIBotInKnownRooms() {
    if (typeof roomPresence === "undefined") return null;

    for (const [, users] of roomPresence) {
      const found = findAIBotInPresence(users);
      if (found) {
        return found;
      }
    }
    return null;
  }

  function ensureChatViewForAskDM() {
    if (window.NRCViewManager?.setActiveView) {
      if (window.NRCViewManager.getActiveView?.() === "sullivanShare") {
        return;
      }
      window.NRCViewManager.setActiveView("sullivan");
    }
  }

  function waitForDM(username, timeoutMs, requireOnline = false, signal = null) {
    return new Promise((resolve) => {
      const deadline = Date.now() + timeoutMs;
      const finish = (value) => {
        clearInterval(timer);
        signal?.removeEventListener("abort", onAbort);
        resolve(value);
      };
      const onAbort = () => finish(null);
      const timer = setInterval(() => {
        const existing = findDMByUsername(username);
        if (existing) {
          const dm = activeDMs.get(existing.convId);
          if (requireOnline && !(dm && dm.online)) {
            if (Date.now() >= deadline) {
              finish(null);
            }
            return;
          }
          finish(existing);
          return;
        }
        if (Date.now() >= deadline) {
          finish(null);
        }
      }, AI_DM_POLL_MS);
      signal?.addEventListener("abort", onAbort, { once: true });
      if (signal?.aborted) onAbort();
    });
  }

  async function ensureAskBackendReady(contextConvId, signal = null) {
    const requestBody = { workspace: currentWorkspaceId };
    if (contextConvId != null) {
      requestBody.context_conv_id = String(contextConvId);
    }

    const response = await fetch(getAiUrl() + "/ask/ready", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(requestBody),
      signal,
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`AI READY FAILED: ${response.status} ${errText}`);
    }

    const data = await response.json();
    const aiUsername = String(data.ai_username || "").trim();
    if (!aiUsername) {
      throw new Error("AI READY FAILED: MISSING SULLIVAN USERNAME");
    }
    return { ...data, ai_username: aiUsername };
  }

  async function resolveAskDisplayConversation(forceRoom, aiUsername, signal = null) {
    if (forceRoom) {
      return { convId: currentRoomId, mode: "room", aiUsername: "AI" };
    }

    const targetUsername = String(aiUsername || "").trim();
    if (!targetUsername) {
      throw new Error("SULLIVAN USERNAME IS UNAVAILABLE");
    }
    if (typeof sendStartDM !== "function") {
      throw new Error("AI DM START IS UNAVAILABLE");
    }

    const existing = findDMByUsername(targetUsername);
    const existingDM = existing ? activeDMs.get(existing.convId) : null;
    if (existing && existingDM?.online) {
      return { convId: existing.convId, mode: "dm", aiUsername: targetUsername };
    }

    const startRequested = sendStartDM(targetUsername, { allowExisting: true, suppressAutoSwitch: true });
    if (!startRequested) {
      throw new Error(`FAILED TO REQUEST SULLIVAN DM (${targetUsername})`);
    }
    const opened = await waitForDM(targetUsername, AI_DM_WAIT_TIMEOUT_MS, true, signal);
    if (signal?.aborted) throw new DOMException("Aborted", "AbortError");
    if (opened) {
      return { convId: opened.convId, mode: "dm", aiUsername: targetUsername };
    }

    throw new Error(`FAILED TO OPEN SULLIVAN DM (${targetUsername})`);
  }

  function getSullivanShareUrl(contextConvId) {
    const workspace = encodeURIComponent(currentWorkspaceId || "workspace1");
    const path = `#/sullivan/${workspace}`;
    return `${window.location.origin}${window.location.pathname}${path}`;
  }

  function clearSullivanShareMode() {
    sullivanShareContextConvId = null;
    updateAskContextChip();
  }

  function exitSullivanShareMode() {
    cancelSullivanOpen();
    if (window.location.hash.match(/^#\/sullivan\//)) {
      window.location.hash = "";
    }
    if (window.NRCViewManager?.getActiveView?.() === "sullivanShare") {
      window.NRCViewManager.setActiveView("sullivan");
    }
    clearSullivanShareMode();
  }

  async function openSullivanWithContext(contextConvId, options = {}) {
    if (isWorkbenchBusy()) {
      logWorkbenchMessage("Error", "SULLIVAN IS BUSY; STOP OR WAIT BEFORE CHANGING CONTEXT");
      return;
    }
    activeSullivanOpenController?.abort();
    const openSequence = ++sullivanOpenSequence;
    const controller = new AbortController();
    activeSullivanOpenController = controller;
    activeSullivanOpenDisplayConvId = null;
    const isCurrentOpen = () => openSequence === sullivanOpenSequence && !controller.signal.aborted;
    const contextID = 0n;

    let askReadyInfo;
    try {
      askReadyInfo = await ensureAskBackendReady(contextID, controller.signal);
    } catch (err) {
      if (err.name === "AbortError" || !isCurrentOpen()) return;
      logMessage("Error", `AI SERVICE UNAVAILABLE: ${err.message}`);
      return;
    }
    if (!isCurrentOpen()) return;

    let displayInfo;
    try {
      displayInfo = await resolveAskDisplayConversation(false, askReadyInfo.ai_username, controller.signal);
    } catch (err) {
      if (err.name === "AbortError" || !isCurrentOpen()) return;
      logMessage("Error", `FAILED TO OPEN SULLIVAN DM: ${err.message}`);
      return;
    }
    if (!isCurrentOpen()) return;

    const displayConvId = BigInt(displayInfo.convId);
    activeSullivanOpenDisplayConvId = displayConvId;
    sullivanShareContextConvId = contextID;
    sullivanDisplayConvId = displayConvId;
    closeStaleAIDMs(displayConvId);
    setAskContext(displayConvId, contextID, true);
    rememberLastNonDMRoom(contextID);

    if (options.focused !== false && window.NRCViewManager?.setActiveView) {
      window.NRCViewManager.setActiveView("sullivanShare");
    } else if (window.NRCViewManager?.setActiveView) {
      window.NRCViewManager.setActiveView("sullivan");
    }

    updateAskContextChip();
    if (typeof updateRoomUI === "function") updateRoomUI();
    await loadRoomHistory(displayConvId, { aiContextRoomId: contextID });
    if (!isCurrentOpen()) return;
    if (typeof clearDMUnread === "function") clearDMUnread(displayConvId);
    roomActivity?.delete?.(displayConvId);
    if (typeof updateDMListUI === "function") updateDMListUI();
    if (activeSullivanOpenController === controller) {
      activeSullivanOpenController = null;
      activeSullivanOpenDisplayConvId = null;
    }
  }

  function buildAskUserTurn(question, contextConvId, mode) {
    const contextName = typeof getRoomName === "function"
      ? getRoomName(contextConvId)
      : String(contextConvId);
    const modeLabel = mode ? String(mode).toUpperCase() : "PLAN";
    return `**QUERY · ${modeLabel} · CONTEXT ${contextName}**\n${question}`;
  }

  function formatToolTraceSummary(trace) {
    if (!Array.isArray(trace) || trace.length === 0) return "";
    return trace
      .map((entry) => {
        const name = String(entry.tool || "tool");
        const status = String(entry.status || "ok").toUpperCase();
        const duration = entry.duration_ms != null ? `${entry.duration_ms}ms` : "?ms";
        return `${name}:${status}:${duration}`;
      })
      .join(" -> ");
  }

  function buildAskAnswerMessage(data, contextConvId) {
    const lines = [];
    const contextName = typeof getRoomName === "function"
      ? getRoomName(contextConvId)
      : String(contextConvId);

    lines.push(`**AI RESPONSE · CONTEXT ${contextName}**`);
    if ((data.history_turns || 0) > 0) {
      lines.push(`**FOLLOW-UP CONTEXT:** LAST ${data.history_turns} TURN(S)`);
    }

    const answer = (data.answer || "").trim();
    if (answer) {
      lines.push("");
      lines.push(answer);
    }

    const sources = data.sources || [];
    if (sources.length > 0) {
      lines.push("");
      lines.push(`**SOURCES (${sources.length})**`);
      sources.forEach((src) => {
        const type = src.type || "source";
        const id = src.id != null ? String(src.id) : "?";
        const title = src.title || src.preview || `${type} ${id}`;
        lines.push(`- [${type}:${id}] ${title}`);
      });
    }

    return lines.join("\n");
  }

  function resetBackendAskSession(sessionID) {
    const id = String(sessionID || "").trim();
    if (!id) return;
    fetch(getAiUrl() + "/ask/session/reset", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ workspace: currentWorkspaceId, agent_session_id: id }),
    }).catch((err) => {
      console.warn("AI session reset failed", err);
    });
  }

  function invalidateAskSession(sessionID, resetBackend = true) {
    const id = String(sessionID || "").trim();
    if (!id) return;
    for (const [storedKey, storedSessionID] of askSessionByContext) {
      if (String(storedSessionID) === id) askSessionByContext.delete(storedKey);
    }
    for (const [storedDisplayID, plan] of askPlanByDisplayConv) {
      if (String(plan.agentSessionId) === id) askPlanByDisplayConv.delete(storedDisplayID);
    }
    refreshActionPlanCards();
    if (resetBackend) resetBackendAskSession(id);
  }

  function logAskRunTerminal(displayConvId, aiRunId, question, mode, contextConvId, status, message) {
    logMessage("Activity", message, displayConvId, {
      aiRunId,
      aiQuestion: question,
      aiMode: mode,
      aiContextRoomId: contextConvId,
      aiRunStatus: status,
    });
  }

  function resetAskSession(contextConvId = null, displayConvId = null) {
    if (activeActionPlanApply) return false;
    const resetDisplayId = displayConvId == null ? null : String(displayConvId);
    if (activeAskRun && (resetDisplayId == null || String(activeAskRun.displayConvId) === resetDisplayId)) {
      activeAskRun.controller.abort();
      activeAskRun = null;
      setRunBusy(null);
    }
    if (contextConvId != null && displayConvId != null) {
      const key = askContextKey(displayConvId, contextConvId);
      const sessionID = askSessionByContext.get(key);
      if (sessionID) {
        invalidateAskSession(sessionID, false);
      } else {
        askSessionByContext.delete(key);
        invalidateActionPlans(String(displayConvId));
      }
      resetBackendAskSession(sessionID);
      return true;
    }
    const sessionIDs = new Set(askSessionByContext.values());
    askSessionByContext.clear();
    askPlanByDisplayConv.clear();
    refreshActionPlanCards();
    askLastContextByDisplayConv.clear();
    sessionIDs.forEach(resetBackendAskSession);
    return true;
  }

  // -- Ask --
  async function handleAsk(question, options = {}) {
    if (isWorkbenchBusy()) {
      const displayConvId = options.displayConvID ?? sullivanDisplayConvId ?? currentRoomId;
      logWorkbenchMessage("Error", "SULLIVAN IS BUSY; STOP OR WAIT FOR THE ACTIVE RUN", displayConvId);
      return;
    }
    const originConvId = BigInt(options.displayConvID ?? sullivanDisplayConvId ?? currentRoomId);
    const controller = new AbortController();
    const aiRunId = `ai-${Date.now().toString(36)}-${++aiRunSequence}`;
    activeAskRun = { id: aiRunId, controller, displayConvId: originConvId };
    invalidateActionPlans(String(originConvId));
    setRunBusy(activeAskRun);
    closeActivePortal();
    const originIsDM = typeof isDMConversation === "function" && isDMConversation(originConvId);

    if (!originIsDM) {
      rememberLastNonDMRoom(originConvId);
    }

    const initialDisplayConvId = originConvId;
    let resolvedDisplayInfo = options.forceRoom === true
      ? { convId: initialDisplayConvId, aiUsername: "AI" }
      : null;

    const contextConvId = 0n;
    setAskContext(initialDisplayConvId, contextConvId, true);
    activeAskRun.contextConvId = contextConvId;

    const initialMode = SULLIVAN_MODE;
    const preflightRunVisible = isAIDMConversation(initialDisplayConvId);
    if (preflightRunVisible) {
      document.querySelector(".sullivan-empty")?.remove();
      logMessage("Sent", buildAskUserTurn(question, contextConvId, initialMode), initialDisplayConvId, {
        author: "YOU", aiRunId, aiQuestion: question, aiMode: initialMode,
        aiContextRoomId: contextConvId, aiRunStatus: "running",
      });
      logMessage("Activity", "AI PREPARING SERVICE + DISPLAY ...", initialDisplayConvId, {
        aiRunId, aiQuestion: question, aiMode: initialMode,
        aiContextRoomId: contextConvId, aiRunStatus: "running",
      });
    }

    if (options.forceRoom !== true) {
      let askReadyInfo;
      try {
        askReadyInfo = await ensureAskBackendReady(contextConvId, controller.signal);
      } catch (err) {
        if (err.name === "AbortError" || controller.signal.aborted) {
          if (preflightRunVisible) {
            logAskRunTerminal(initialDisplayConvId, aiRunId, question, initialMode, contextConvId, "cancelled", "AI RUN CANCELLED");
          }
          if (activeAskRun?.id === aiRunId) activeAskRun = null;
          setRunBusy(activeAskRun);
          return;
        }
        aiServiceAvailable = false;
        logWorkbenchMessage("Error", `AI SERVICE UNAVAILABLE: ${err.message}`, initialDisplayConvId, contextConvId);
        if (preflightRunVisible) {
          logAskRunTerminal(initialDisplayConvId, aiRunId, question, initialMode, contextConvId, "error", `AI RUN FAILED: ${err.message}`);
        }
        if (activeAskRun?.id === aiRunId) activeAskRun = null;
        setRunBusy(activeAskRun);
        return;
      }

      try {
        resolvedDisplayInfo = await resolveAskDisplayConversation(false, askReadyInfo.ai_username, controller.signal);
      } catch (err) {
        if (err.name === "AbortError" || controller.signal.aborted) {
          if (preflightRunVisible) {
            logAskRunTerminal(initialDisplayConvId, aiRunId, question, initialMode, contextConvId, "cancelled", "AI RUN CANCELLED");
          }
          if (activeAskRun?.id === aiRunId) activeAskRun = null;
          setRunBusy(activeAskRun);
          return;
        }
        logWorkbenchMessage("Error", `FAILED TO OPEN SULLIVAN DM: ${err.message}`, initialDisplayConvId, contextConvId);
        if (preflightRunVisible) {
          logAskRunTerminal(initialDisplayConvId, aiRunId, question, initialMode, contextConvId, "error", `AI RUN FAILED: ${err.message}`);
        }
        if (activeAskRun?.id === aiRunId) activeAskRun = null;
        setRunBusy(activeAskRun);
        return;
      }
    }

    if (resolvedDisplayInfo?.mode === "dm") {
      const resolvedDisplayConvId = BigInt(resolvedDisplayInfo.convId);
      sullivanDisplayConvId = resolvedDisplayConvId;
      activeAskRun.displayConvId = resolvedDisplayConvId;
      setAskContext(resolvedDisplayConvId, contextConvId, true);
      ensureChatViewForAskDM();
      closeStaleAIDMs(resolvedDisplayConvId);
    }

    const requestDisplayConvId =
      resolvedDisplayInfo?.convId != null
        ? BigInt(resolvedDisplayInfo.convId)
        : initialDisplayConvId;

    if (requestDisplayConvId !== initialDisplayConvId) {
      invalidateActionPlans(String(requestDisplayConvId));
    }
    activeAskRun.displayConvId = requestDisplayConvId;
    setRunBusy(activeAskRun);

    if (requestDisplayConvId !== initialDisplayConvId) {
      setAskContext(requestDisplayConvId, contextConvId, true);
    }

    const initialContextKey = askContextKey(initialDisplayConvId, contextConvId);
    const contextKey = askContextKey(requestDisplayConvId, contextConvId);

    const explicitSessionID = options.followUp === true && options.sessionID
      ? String(options.sessionID)
      : null;
    const sessionID = explicitSessionID || askSessionByContext.get(contextKey) || "";
    const followUpRequested = !!sessionID;
    const mode = SULLIVAN_MODE;
    activeAskRun.displayConvId = requestDisplayConvId;
    setRunBusy(activeAskRun);
    document.querySelector(".sullivan-empty")?.remove();

    if (!preflightRunVisible) {
      logMessage(
        "Sent",
        buildAskUserTurn(question, contextConvId, mode),
        requestDisplayConvId,
        { author: "YOU", aiRunId, aiQuestion: question, aiMode: mode, aiContextRoomId: contextConvId, aiRunStatus: "running" },
      );
    }
    logMessage(
      "Activity",
      `AI PROCESSING (${followUpRequested ? "FOLLOW-UP" : "FRESH"}) ...`,
      requestDisplayConvId, { aiRunId, aiQuestion: question, aiMode: mode, aiContextRoomId: contextConvId, aiRunStatus: "running" },
    );

    const requestBody = {
      workspace: currentWorkspaceId,
      conv_id: String(contextConvId),
      context_conv_id: String(contextConvId),
      question: question,
      message: question,
      display_conv_id: String(requestDisplayConvId),
      mode,
    };
    if (options.taskID != null) {
      requestBody.task_id = Number(options.taskID);
    }
    if (followUpRequested) {
      requestBody.follow_up = true;
      requestBody.session_id = sessionID;
      requestBody.agent_session_id = sessionID;
    }

    try {
      const response = await fetch(getAiUrl() + "/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(requestBody),
        signal: controller.signal,
      });

      if (!response.ok) {
        const errText = await response.text();
        logMessage("Activity", `AI RUN FAILED: ${response.status} ${errText}`, requestDisplayConvId,
          { aiRunId, aiQuestion: question, aiMode: mode, aiContextRoomId: contextConvId, aiRunStatus: "error" });
        return;
      }

      aiServiceAvailable = true;
      const data = await response.json();
      const responseSessionID = data.agent_session_id || data.session_id;
      if (controller.signal.aborted || activeAskRun?.id !== aiRunId) {
        invalidateAskSession(responseSessionID || sessionID);
        logAskRunTerminal(requestDisplayConvId, aiRunId, question, mode, contextConvId, "cancelled", "AI RUN CANCELLED");
        return;
      }

      const responseDisplayInfo = resolvedDisplayInfo;
      const responseDisplayConvId = requestDisplayConvId;

      if (responseDisplayConvId !== initialDisplayConvId) {
        setAskContext(responseDisplayConvId, contextConvId, true);
      }

      const responseContextKey = askContextKey(responseDisplayConvId, contextConvId);
      if (responseSessionID) {
        askSessionByContext.set(initialContextKey, responseSessionID);
        askSessionByContext.set(contextKey, responseSessionID);
        askSessionByContext.set(responseContextKey, responseSessionID);
      }

      const proposedActions = Array.isArray(data.proposed_actions) ? data.proposed_actions : [];
      const effectiveMode = data.mode || requestBody.mode;
      let actionPlan = null;
      if (effectiveMode === "plan" && responseSessionID && data.plan_id && proposedActions.length > 0) {
        invalidateActionPlans(String(responseDisplayConvId));
        actionPlan = {
          agentSessionId: responseSessionID,
          planId: data.plan_id,
          validityId: `plan-${Date.now().toString(36)}-${++aiPlanSequence}`,
          mode: data.mode || requestBody.mode || "plan",
          actions: proposedActions,
          pendingActionCount: data.pending_action_count || proposedActions.length,
          contextConvId: String(contextConvId),
          displayConvId: String(responseDisplayConvId),
        };
        askPlanByDisplayConv.set(String(responseDisplayConvId), actionPlan);
      } else if (effectiveMode === "plan") {
        invalidateActionPlans(String(responseDisplayConvId));
      }

      logMessage(
        "Message",
        buildAskAnswerMessage(data, contextConvId),
        responseDisplayConvId,
        {
          author: responseDisplayInfo?.aiUsername || "AI",
          aiSources: data.sources || [],
          aiActionPlan: actionPlan,
          aiContextRoomId: contextConvId,
          aiRunId,
          aiQuestion: question,
          aiAnswer: (data.answer || "").trim(),
          aiMode: mode,
          aiRunStatus: "complete",
          suppressNotification: true,
        },
      );
    } catch (err) {
      if (err.name === "AbortError" || controller.signal.aborted) {
        invalidateAskSession(sessionID);
        logAskRunTerminal(requestDisplayConvId, aiRunId, question, mode, contextConvId, "cancelled", "AI RUN CANCELLED");
        return;
      }
      aiServiceAvailable = false;
      logMessage("Activity", `AI RUN FAILED: ${err.message}`, requestDisplayConvId,
        { aiRunId, aiQuestion: question, aiMode: mode, aiContextRoomId: contextConvId, aiRunStatus: "error" });
    } finally {
      if (activeAskRun?.id === aiRunId) activeAskRun = null;
      setRunBusy(activeAskRun);
    }
  }

  function buildAiPortalHeader(title) {
    const header = document.createElement("div");
    header.className = "panel-header ai-ask-header";

    const headerInner = document.createElement("div");
    headerInner.className = "ai-ask-header-inner";

    const titleEl = document.createElement("span");
    titleEl.textContent = title;

    const closeBtn = document.createElement("span");
    closeBtn.className = "btn task-detail-close";
    closeBtn.textContent = "×";
    closeBtn.title = "Close (Esc)";
    closeBtn.addEventListener("click", () => {
      if (activePortal) {
        activePortal.hide();
        activePortal = null;
      }
      setKeyHandler(null);
    });

    headerInner.appendChild(titleEl);
    headerInner.appendChild(closeBtn);
    header.appendChild(headerInner);

    return header;
  }

  function actionPlanDisplayLabel(plan) {
    const count = Array.isArray(plan?.actions) ? plan.actions.length : 0;
    const planId = String(plan?.planId || "plan");
    return `ACTION PLAN · ${planId} · ${count} ACTION(S)`;
  }

  function isCurrentActionPlan(plan) {
    if (!plan?.displayConvId || !plan.validityId) return false;
    const current = askPlanByDisplayConv.get(String(plan.displayConvId));
    return !!current &&
      current.validityId === plan.validityId &&
      String(current.agentSessionId) === String(plan.agentSessionId) &&
      String(current.planId) === String(plan.planId) &&
      String(current.contextConvId) === String(plan.contextConvId);
  }

  function refreshActionPlanCards() {
    document.querySelectorAll(".ai-action-plan").forEach((card) => {
      const plan = card._nrcActionPlan;
      if (!plan) return;
      const valid = isCurrentActionPlan(plan);
      const busy = isWorkbenchBusy();
      card.classList.toggle("expired", !valid);
      card.querySelectorAll("button, input[type=checkbox]").forEach((control) => {
        control.disabled = !valid || busy || control.dataset.applied === "true";
      });
      const status = card.querySelector(".ai-action-plan-status");
      if (!valid && status && !card.classList.contains("cancelled") && !status.textContent) {
        status.textContent = "EXPIRED. THIS PLAN IS READ ONLY.";
      }
    });
  }

  function invalidateActionPlans(displayConvId = null) {
    if (displayConvId == null) askPlanByDisplayConv.clear();
    else askPlanByDisplayConv.delete(String(displayConvId));
    refreshActionPlanCards();
  }

  async function applyActionPlan(plan, actionIds, statusEl = null) {
    if (!plan || !plan.agentSessionId || !plan.planId) {
      logWorkbenchMessage("Error", "AI ACTION PLAN IS MISSING SESSION OR PLAN ID");
      return null;
    }
    if (!isCurrentActionPlan(plan)) {
      throw new Error("PLAN EXPIRED: ONLY THE LATEST PLAN CAN BE APPLIED");
    }
    if (isWorkbenchBusy()) {
      throw new Error("SULLIVAN IS BUSY");
    }
    const ids = Array.isArray(actionIds) ? actionIds.map(String).filter(Boolean) : [];
    if (statusEl) statusEl.textContent = "APPLYING ...";
    activeActionPlanApply = { displayConvId: String(plan.displayConvId) };
    setRunBusy(activeAskRun);
    try {
      if (!isCurrentActionPlan(plan)) {
        throw new Error("PLAN EXPIRED: ONLY THE LATEST PLAN CAN BE APPLIED");
      }
      const response = await fetch(getAiUrl() + "/ask/apply", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          workspace: currentWorkspaceId,
          agent_session_id: plan.agentSessionId,
          plan_id: plan.planId,
          action_ids: ids,
        }),
      });

      if (!response.ok) {
        const errText = await response.text();
        throw new Error(`APPLY FAILED: ${response.status} ${errText}`);
      }

      const data = await response.json();
      const appliedIds = new Set((data.applied || []).map((entry) => String(entry.action_id)));
      const failedById = new Map((data.failed || []).map((entry) => [String(entry.action_id), entry]));
      plan.actions.forEach((action) => {
        const actionId = String(action.id);
        if (appliedIds.has(actionId)) {
          action.status = "applied";
          delete action.applyError;
        } else if (failedById.has(actionId)) {
          const failed = failedById.get(actionId);
          action.applyError = failed.error || failed.message || "SERVER REJECTED ACTION";
        }
      });
      if (statusEl) statusEl.textContent = formatApplyResultSummary(data);
      if (plan.actions.every((action) => action.status === "applied")) {
        invalidateActionPlans(String(plan.displayConvId));
      }
      return data;
    } finally {
      activeActionPlanApply = null;
      setRunBusy(activeAskRun);
    }
  }

  function formatApplyResultSummary(result) {
    const applied = Array.isArray(result?.applied) ? result.applied.length : 0;
    const failed = Array.isArray(result?.failed) ? result.failed.length : 0;
    const created = Array.isArray(result?.created_entities) ? result.created_entities : [];
    const deleted = Array.isArray(result?.deleted_entities) ? result.deleted_entities : [];
    const edgeCount = Array.isArray(result?.created_edges) ? result.created_edges.length : 0;
    const deletedEdgeCount = Array.isArray(result?.deleted_edges) ? result.deleted_edges.length : 0;
    const createdText = created
      .map((entity) => {
        if (entity.type === "task") return `#${entity.id}`;
        if (entity.type === "note") return `[Note:${entity.id}]`;
        return `${String(entity.type || "entity").toUpperCase()}:${entity.id}`;
      })
      .join(", ");
    const deletedText = deleted
      .map((entity) => {
        if (entity.type === "note") return `[Note:${entity.id}]`;
        return `${String(entity.type || "entity").toUpperCase()}:${entity.id}`;
      })
      .join(", ");
    const details = [];
    if (createdText) details.push(createdText);
    if (edgeCount > 0) details.push(`${edgeCount} EDGE(S)`);
    if (deletedText) details.push(`DELETED ${deletedText}`);
    if (deletedEdgeCount > 0) details.push(`DELETED ${deletedEdgeCount} EDGE(S)`);
    const detailText = details.length ? ` (${details.join(", ")})` : "";
    if (failed > 0 && applied > 0) return `PARTIAL APPLY: ${applied} APPLIED, ${failed} FAILED${detailText}`;
    if (failed > 0) return `APPLY FAILED: ${failed} FAILED`;
    return `APPLIED: ${applied} ACTION(S)${detailText}`;
  }

  function formatActionEndpoint(action, side) {
    const type = String(action?.[`${side}_type`] || "Entity");
    const actionId = action?.[`${side}_action_id`];
    if (actionId) return `${type}:@${actionId}`;
    const id = action?.[`${side}_id`];
    return `${type}:${id || "?"}`;
  }

  function formatActionForCard(action) {
    const id = escapePreviewText(action.id || "?");
    const type = String(action.type || "");
    const title = escapePreviewText(action.title || "(Untitled)");
    const description = escapePreviewText(action.description || "");
    const content = escapePreviewText(action.content || "");
    const contentPreview = content.length > 360 ? `${content.slice(0, 360)}...` : content;

    const noteMetaParts = [];
    if (action.project) noteMetaParts.push(`PROJECT ${escapePreviewText(action.project)}`);
    if (Array.isArray(action.tags) && action.tags.length > 0) {
      noteMetaParts.push(`TAGS ${escapePreviewText(action.tags.join(", "))}`);
    }
    const noteMeta = noteMetaParts.length > 0 ? ` · ${noteMetaParts.join(" · ")}` : "";

    if (type === "create_task") {
      const priority = action.priority != null ? String(action.priority).padStart(3, "0") : "---";
      return {
        title: `${id}. CREATE TASK · PRI ${escapePreviewText(priority)} · ${title}`,
        detail: description,
      };
    }
    if (type === "update_task") {
      const taskID = action.task_id || "?";
      const priority = action.priority != null ? String(action.priority).padStart(3, "0") : "---";
      const status = escapePreviewText(action.task_status || "---");
      const blocker = action.blocked_by ? ` · BLOCKED BY #${escapePreviewText(action.blocked_by)}` : "";
      return {
        title: `${id}. UPDATE TASK · #${escapePreviewText(taskID)} · ${status} · PRI ${escapePreviewText(priority)} · ${title}${blocker}`,
        detail: description,
      };
    }
    if (type === "create_note") {
      return {
        title: `${id}. CREATE NOTE · ${title}${noteMeta}`,
        detail: contentPreview,
      };
    }
    if (type === "update_note") {
      const noteID = action.asset_id || "?";
      return {
        title: `${id}. UPDATE NOTE · [Note:${escapePreviewText(noteID)}] · ${title}${noteMeta}`,
        detail: contentPreview,
      };
    }
    if (type === "delete_note") {
      const noteID = action.asset_id || "?";
      const expected = action.expected_updated_at ? ` · EXPECT ${escapePreviewText(action.expected_updated_at)}` : "";
      return {
        title: `${id}. DELETE NOTE · [Note:${escapePreviewText(noteID)}] · ${title}${expected}`,
        detail: "",
      };
    }
    if (type === "create_edge") {
      const source = escapePreviewText(formatActionEndpoint(action, "source"));
      const target = escapePreviewText(formatActionEndpoint(action, "target"));
      const relation = escapePreviewText(action.relation || "related-to");
      return {
        title: `${id}. CREATE EDGE · ${source} --${relation}--> ${target}`,
        detail: "",
      };
    }
    if (type === "delete_edge") {
      const edgeID = action.edge_id || "?";
      const source = escapePreviewText(formatActionEndpoint(action, "source"));
      const target = escapePreviewText(formatActionEndpoint(action, "target"));
      const relation = escapePreviewText(action.relation || "related-to");
      return {
        title: `${id}. DELETE EDGE · #${escapePreviewText(edgeID)} · ${source} --${relation}--> ${target}`,
        detail: "",
      };
    }
    return {
      title: `${id}. ${escapePreviewText(type.toUpperCase() || "ACTION")} · ${title}`,
      detail: description || contentPreview,
    };
  }

  function renderActionPlan(rootEl, plan) {
    if (!rootEl || !plan || !Array.isArray(plan.actions) || plan.actions.length === 0) return;

    const card = document.createElement("div");
    card.className = "ai-action-plan";
    card._nrcActionPlan = plan;

    const header = document.createElement("div");
    header.className = "ai-action-plan-header";
    header.textContent = actionPlanDisplayLabel(plan);
    card.appendChild(header);

    const list = document.createElement("div");
    list.className = "ai-action-plan-list";
    const checkboxes = [];

    plan.actions.forEach((action) => {
      const row = document.createElement("label");
      row.className = "ai-action-row";
      row.classList.toggle("applied", action.status === "applied");
      row.classList.toggle("failed", !!action.applyError);
      row.dataset.actionId = String(action.id || "");

      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = action.status !== "applied";
      checkbox.disabled = action.status === "applied";
      if (action.status === "applied") checkbox.dataset.applied = "true";
      checkbox.value = String(action.id || "");
      checkboxes.push(checkbox);
      row.appendChild(checkbox);

      const body = document.createElement("div");
      body.className = "ai-action-body";
      const formatted = formatActionForCard(action);
      const actionDetail = [formatted.detail, action.applyError ? `FAILED: ${escapePreviewText(action.applyError)}` : ""]
        .filter(Boolean)
        .join("\n");
      body.innerHTML = `
        <div class="ai-action-title">${formatted.title}</div>
        ${actionDetail ? `<div class="ai-action-desc">${actionDetail}</div>` : ""}
      `;
      row.appendChild(body);
      list.appendChild(row);
    });
    card.appendChild(list);

    const actions = document.createElement("div");
    actions.className = "ai-action-plan-actions";
    const applySelected = document.createElement("button");
    applySelected.type = "button";
    applySelected.className = "btn btn--primary ai-action-apply";
    applySelected.textContent = "APPLY SELECTED";
    const applyAll = document.createElement("button");
    applyAll.type = "button";
    applyAll.className = "btn ai-action-apply-all";
    applyAll.textContent = "APPLY ALL";
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "btn btn--danger ai-action-cancel";
    cancel.textContent = "CANCEL";
    actions.appendChild(applySelected);
    actions.appendChild(applyAll);
    actions.appendChild(cancel);
    card.appendChild(actions);

    const status = document.createElement("div");
    status.className = "ai-action-plan-status";
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    status.setAttribute("aria-atomic", "true");
    card.appendChild(status);

    const setBusy = (busy) => {
      applySelected.disabled = busy;
      applyAll.disabled = busy;
      cancel.disabled = busy;
      checkboxes.forEach((checkbox) => {
        if (!checkbox.dataset.applied) checkbox.disabled = busy;
      });
    };

    const runApply = async (ids) => {
      if (!ids.length) {
        status.textContent = "NO ACTIONS SELECTED";
        return;
      }
      setBusy(true);
      try {
        const result = await applyActionPlan(plan, ids, status);
        const appliedIds = new Set((result?.applied || []).map((entry) => String(entry.action_id)));
        checkboxes.forEach((checkbox) => {
          if (appliedIds.has(String(checkbox.value))) {
            checkbox.checked = false;
            checkbox.disabled = true;
            checkbox.dataset.applied = "true";
            checkbox.closest(".ai-action-row")?.classList.add("applied");
          }
        });
      } catch (err) {
        status.textContent = err.message || String(err);
        logWorkbenchMessage("Error", status.textContent, plan.displayConvId, plan.contextConvId);
      } finally {
        refreshActionPlanCards();
      }
    };

    applySelected.addEventListener("click", () => {
      const selected = checkboxes
        .filter((checkbox) => checkbox.checked && !checkbox.disabled)
        .map((checkbox) => checkbox.value);
      runApply(selected);
    });

    applyAll.addEventListener("click", () => {
      runApply(checkboxes
        .filter((checkbox) => checkbox.dataset.applied !== "true")
        .map((checkbox) => checkbox.value)
        .filter(Boolean));
    });

    cancel.addEventListener("click", () => {
      if (plan.contextConvId && plan.displayConvId) {
        resetAskSession(BigInt(plan.contextConvId), BigInt(plan.displayConvId));
      } else {
        resetBackendAskSession(plan.agentSessionId);
      }
      invalidateActionPlans(String(plan.displayConvId || currentRoomId));
      card.classList.add("cancelled");
      status.textContent = "CANCELLED. NO NRC MUTATION WAS SENT.";
      setBusy(true);
    });

    rootEl.appendChild(card);
    refreshActionPlanCards();
  }

  function parseApplyShortcut(text) {
    const raw = String(text || "").trim();
    if (/^cancel$/i.test(raw)) {
      return { type: "cancel" };
    }
    const match = raw.match(/^apply(?:\s+(all|\d+(?:\s*,\s*\d+)*))?$/i);
    if (!match) return null;
    const spec = (match[1] || "all").toLowerCase();
    if (spec === "all") return { type: "apply", actionIds: [] };
    return { type: "apply", actionIds: spec.split(",").map((part) => part.trim()).filter(Boolean) };
  }

  async function handleAIDMText(text) {
    const shortcut = parseApplyShortcut(text);
    if (!shortcut) {
      handleAsk(text);
      return;
    }

    const displayConvId = getDisplayConvId();
    const plan = askPlanByDisplayConv.get(String(displayConvId));
    if (!plan) {
      logWorkbenchMessage("Error", "NO PENDING AI ACTION PLAN IN THIS SULLIVAN DM", displayConvId);
      return;
    }

    if (shortcut.type === "cancel") {
      if (plan.contextConvId && plan.displayConvId) {
        resetAskSession(BigInt(plan.contextConvId), BigInt(plan.displayConvId));
      } else {
        resetBackendAskSession(plan.agentSessionId);
      }
      invalidateActionPlans(String(displayConvId));
      logSystem("AI ACTION PLAN CANCELLED", "ai");
      return;
    }

    try {
      const result = await applyActionPlan(plan, shortcut.actionIds || []);
      logSystem(formatApplyResultSummary(result), "ai");
    } catch (err) {
      logWorkbenchMessage("Error", err.message || String(err), displayConvId, plan.contextConvId);
    }
  }

  function openAssetSource(asset, src, targetRoomId) {
    if (!asset) {
      logSystem(`ASSET #${src.id} NOT FOUND IN ROOM`, "ai", "WARN");
      return;
    }

    // In focused share views the side panels are force-hidden
    // (body.sullivan-share-focused / body.note-share-focused .agenda-panel),
    // so in-app navigation (selectNote) renders into invisible DOM. Open the
    // read-only note share URL in a new tab instead.
    const activeView = window.NRCViewManager?.getActiveView?.();
    if (
      (activeView === "sullivanShare" || activeView === "noteShare") &&
      asset.assetType === AssetType.Note
    ) {
      const url = window.NRCNotes?.getSharedNoteUrl?.(asset);
      if (url) {
        window.open(url, "_blank", "noopener,noreferrer");
        return;
      }
    }

    if (asset.assetType === AssetType.Comment) {
      if (asset.parentType === window.NRCAssets?.ParentType?.Asset) {
        const parent = window.NRCAssets?.roomAssets?.get(targetRoomId)?.get(asset.parentId);
        if (parent && parent.assetType === AssetType.Note && window.NRCNotes) {
          if (window.NRCNotes.openNoteComments) {
            window.NRCNotes.openNoteComments(parent, asset.assetId);
          } else {
            window.NRCNotes.selectNote(parent);
          }
        } else {
          logSystem(`COMMENT #${src.id} LINKED NOTE NOT FOUND IN ROOM`, "ai", "WARN");
        }
      } else {
        const taskId = asset.parentId;
        const task = window.NRCTasks?.roomTasks?.get(targetRoomId)?.get(taskId);
        if (task) {
          if (window.NRCTasks.openTaskComments) {
            window.NRCTasks.openTaskComments(task, asset.assetId);
          } else {
            window.NRCTasks.selectTask(task);
          }
        } else {
          logSystem(`COMMENT #${src.id} LINKED TASK NOT FOUND IN ROOM`, "ai", "WARN");
        }
      }
    } else if (asset.assetType === AssetType.Note && window.NRCNotes) {
      window.NRCNotes.selectNote(asset);
    } else if (asset.assetType === AssetType.Reminder) {
      if (window.NRCInspector) window.NRCInspector.openEntity({ roomId: targetRoomId, type: "reminder", id: asset.assetId });
      else window.NRCTasks?.selectReminder?.(asset.assetId, { roomId: targetRoomId });
    } else {
      logSystem(`ASSET #${src.id} (${assetTypeLabel(asset.assetType)})`, "ai");
    }
  }

  function navigateToSource(src, contextRoomId = currentRoomId) {
    const targetRoomId = 0n;

    if (window.NRCInspector && (src.type === "task" || src.type === "note" || src.type === "reminder")) {
      window.NRCInspector.openEntity({ roomId: targetRoomId, type: src.type, id: src.id });
      return;
    }

    if (src.type === "task") {
      const tasks = window.NRCTasks?.roomTasks?.get(targetRoomId);
      const task = tasks?.get(BigInt(src.id));
      if (task) {
        window.NRCTasks?.selectTask(task);
      } else {
        logSystem(`TASK #${src.id} NOT FOUND IN ROOM`, "ai", "WARN");
      }
    } else if (src.type === "note" || src.type === "reminder") {
      const assetId = BigInt(src.id);
      const asset = window.NRCAssets?.roomAssets?.get(targetRoomId)?.get(assetId);
      if (asset) {
        openAssetSource(asset, src, targetRoomId);
      } else {
        window.NRCAssets?.requestAsset?.(targetRoomId, assetId, {
          onSuccess: (detail) => openAssetSource(detail?.asset, src, targetRoomId),
          onError: () => logSystem(`${src.type.toUpperCase()} #${src.id} NOT FOUND IN ROOM`, "ai", "WARN"),
        });
      }
    } else if (src.type === "asset") {
      const assetId = BigInt(src.id);
      const asset = window.NRCAssets?.roomAssets?.get(targetRoomId)?.get(assetId);
      if (asset) {
        openAssetSource(asset, src, targetRoomId);
        return;
      }

      if (!window.NRCAssets?.requestAsset) {
        logSystem(`ASSET #${src.id} NOT FOUND IN ROOM`, "ai", "WARN");
        return;
      }

      const inspectorIntent = window.NRCInspector?.beginExternalLoad?.();
      const isCurrentIntent = () => inspectorIntent == null || window.NRCInspector?.isIntentCurrent?.(inspectorIntent);
      logSystem(`LOADING ASSET #${src.id}`, "ai", "DEBUG");
      window.NRCAssets.requestAsset(targetRoomId, assetId, {
        onSuccess: (detail) => {
          if (!isCurrentIntent()) return;
          openAssetSource(detail?.asset, src, targetRoomId);
        },
        onError: () => {
          if (!isCurrentIntent()) return;
          logSystem(`ASSET #${src.id} NOT FOUND IN ROOM`, "ai", "WARN");
        },
      });
    }
  }

  function escapePreviewText(value) {
    const text = value == null ? "" : String(value);
    return text
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }

  function shouldRenderAssetPreviewMarkdown(assetType) {
    return (
      assetType === AssetType.Agenda ||
      assetType === AssetType.Document ||
      assetType === AssetType.Note
    );
  }

  function renderAssetPreviewSnippetHTML(text, renderMarkdown) {
    const snippetText = text == null ? "" : String(text).trim();
    if (!snippetText) return "";

    if (renderMarkdown && typeof window.parseMarkdown === "function") {
      return window.parseMarkdown(snippetText);
    }

    return escapePreviewText(snippetText);
  }

  function hideAssetPreviewNow() {
    assetPreviewPortal?.destroy();
    assetPreviewPortal = null;
  }

  function hideAssetPreviewDelayed() {
    if (assetPreviewHideTimer) {
      clearTimeout(assetPreviewHideTimer);
    }
    assetPreviewHideTimer = setTimeout(() => {
      hideAssetPreviewNow();
      assetPreviewHideTimer = null;
    }, 120);
  }

  function buildAssetPreviewFromAsset(asset, source) {
    const label = assetTypeLabel(asset.assetType).toUpperCase();
    let title = source?.title || `Asset #${asset.assetId}`;
    let snippet = "";
    let renderMarkdown = shouldRenderAssetPreviewMarkdown(asset.assetType);

    if (asset.assetType === AssetType.Note && window.NRCNotes?.parseNotePreview) {
      const parsed = window.NRCNotes.parseNotePreview(asset.preview || "");
      title = parsed.title || title;
      renderMarkdown = parsed.format !== "html";
      snippet = ((parsed.format === "html" ? parsed.teaser : asset.payload) || parsed.teaser || "").trim();
    } else {
      const previewText = String(asset.preview || "").trim();
      const payloadText = String(asset.payload || "").trim();
      title = previewText || title;
      snippet = payloadText || previewText;
    }

    if (snippet.length > 220) {
      snippet = `${snippet.slice(0, 220)}...`;
    }

    return {
      found: true,
      label,
      title,
      snippet,
      renderMarkdown,
      assetID: asset.assetId,
    };
  }

  function getAssetPreviewData(source, contextRoomId) {
    const roomId = 0n;
    const assets = window.NRCAssets?.roomAssets?.get(roomId);
    const asset = assets?.get(BigInt(source.id));

    if (!asset) {
      return {
        found: false,
        label: "ASSET",
        title: source?.title || `Asset #${source.id}`,
        snippet: "Loading...",
      };
    }

    return buildAssetPreviewFromAsset(asset, source);
  }

  function renderAssetPreviewCardHTML(previewData, source) {
    const title = escapePreviewText(previewData.title || "(Untitled)");
    const snippetHtml = renderAssetPreviewSnippetHTML(
      previewData.snippet,
      previewData.renderMarkdown === true,
    );
    const idText = escapePreviewText(String(previewData.assetID || source.id));
    const status = escapePreviewText(previewData.label || "ASSET");

    return `
      <div class="task-preview-header">
        <div class="task-preview-id">#${idText}</div>
        <div class="task-preview-status">${status}</div>
      </div>
      <div class="task-preview-title">${title}</div>
      ${snippetHtml ? `<div class="task-preview-desc asset-preview-markdown">${snippetHtml}</div>` : ""}
    `;
  }

  function showAssetReferencePreview(anchorEl, source, contextRoomId) {
    if (!anchorEl || !source || source.type !== "asset") return;

    if (assetPreviewHideTimer) {
      clearTimeout(assetPreviewHideTimer);
      assetPreviewHideTimer = null;
    }
    hideAssetPreviewNow();

    const roomId = 0n;
    const previewData = getAssetPreviewData(source, contextRoomId);
    const card = document.createElement("div");
    card.className = `task-preview-card${previewData.found ? "" : " task-preview-notfound"}`;
    card.id = "assetReferencePreviewPopup";
    card.innerHTML = renderAssetPreviewCardHTML(previewData, source);

    const portal = Portal.create(card, anchorEl, {
      position: "bottom", align: "left", matchWidth: false, offsetY: 8, flipIfNeeded: true,
    });
    assetPreviewPortal = portal;
    portal.show();

    card.addEventListener("mouseenter", () => {
      if (assetPreviewHideTimer) {
        clearTimeout(assetPreviewHideTimer);
        assetPreviewHideTimer = null;
      }
    });
    card.addEventListener("mouseleave", () => {
      hideAssetPreviewNow();
    });

    if (!previewData.found && window.NRCAssets?.requestAsset) {
      window.NRCAssets.requestAsset(roomId, BigInt(source.id), {
        onSuccess: (detail) => {
          if (assetPreviewPortal !== portal || !anchorEl.isConnected || !detail?.asset) return;
          const c = card;
          const data = buildAssetPreviewFromAsset(detail.asset, source);
          c.className = "task-preview-card";
          c.innerHTML = renderAssetPreviewCardHTML(data, source);
          portal.reposition();
        },
        onError: () => {
          if (assetPreviewPortal !== portal || !anchorEl.isConnected) return;
          const c = card;
          const fallback = {
            found: false,
            label: "ASSET",
            title: source?.title || `Asset #${source.id}`,
            snippet: "Asset not found.",
          };
          c.innerHTML = renderAssetPreviewCardHTML(fallback, source);
          portal.reposition();
        },
      });
    }
  }

  function processAssetReferences(rootEl, sources = [], contextRoomId = currentRoomId) {
    if (!rootEl) return;

    const sourceByTaskID = new Map();
    const sourceByAssetID = new Map();
    (sources || []).forEach((src) => {
      if (!src || src.id == null) return;
      if (src.type === "task") {
        sourceByTaskID.set(String(src.id), src);
      } else if (src.type === "asset") {
        sourceByAssetID.set(String(src.id), src);
      }
    });

    const assetRefRegex = /\[\s*(task|asset|comment|document|file|agenda|note|reminder)\s*:\s*(\d+)\s*\]/gi;
    const walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT, null);
    const textNodes = [];
    let current;

    while ((current = walker.nextNode())) {
      if (current.parentElement?.closest("a, code, pre, .task-reference")) continue;
      if (assetRefRegex.test(current.nodeValue || "")) {
        textNodes.push(current);
      }
      assetRefRegex.lastIndex = 0;
    }

    textNodes.forEach((node) => {
      const text = node.nodeValue || "";
      const frag = document.createDocumentFragment();
      let lastIndex = 0;
      assetRefRegex.lastIndex = 0;
      let match;

      while ((match = assetRefRegex.exec(text)) !== null) {
        const [full, typeName, idStr] = match;
        const matchStart = match.index;

        if (matchStart > lastIndex) {
          frag.appendChild(document.createTextNode(text.slice(lastIndex, matchStart)));
        }

        const link = document.createElement("span");
        link.className = "task-reference";
        link.textContent = `[${typeName.toLowerCase()}:${idStr}]`;
        link.tabIndex = 0;
        link.setAttribute("role", "link");
        link.addEventListener("keydown", (event) => {
          if (event.key === "Enter") { event.preventDefault(); link.click(); }
        });
        const source = typeName.toLowerCase() === "task"
          ? (sourceByTaskID.get(idStr) || { type: "task", id: idStr, title: `Task #${idStr}` })
          : (sourceByAssetID.get(idStr) || { type: "asset", id: idStr, title: `[${typeName}:${idStr}]` });
        link.addEventListener("click", (e) => {
          e.preventDefault();
          e.stopPropagation();
          navigateToSource(source, contextRoomId);
        });
        if (source.type === "task" && window.NRCTaskReferences?.showTaskPreview) {
          link.addEventListener("mouseenter", () => {
            window.NRCTaskReferences.showTaskPreview(link, BigInt(source.id), BigInt(contextRoomId));
          });
          link.addEventListener("mouseleave", () => {
            window.NRCTaskReferences.hideTaskPreview?.();
          });
        } else if (source.type === "asset") {
          link.addEventListener("mouseenter", () => {
            showAssetReferencePreview(link, source, contextRoomId);
          });
          link.addEventListener("mouseleave", () => {
            hideAssetPreviewDelayed();
          });
        }
        frag.appendChild(link);

        lastIndex = matchStart + full.length;
      }

      if (lastIndex < text.length) {
        frag.appendChild(document.createTextNode(text.slice(lastIndex)));
      }

      node.parentNode?.replaceChild(frag, node);
    });
  }

  function assetTypeLabel(t) {
    switch (t) {
      case AssetType.Comment: return "Comment";
      case AssetType.Document: return "Document";
      case AssetType.File: return "File";
      case AssetType.Agenda: return "Agenda";
      case AssetType.Note: return "Note";
      default: return `Type${t}`;
    }
  }

  function answerWithSources(messageData) {
    const lines = [messageData.aiAnswer || ""];
    const sources = Array.isArray(messageData.aiSources) ? messageData.aiSources : [];
    if (sources.length) {
      lines.push("", "Sources:", ...sources.map((source) =>
        `- [${source.type || "source"}:${source.id ?? "?"}] ${source.title || source.preview || "Untitled"}`));
    }
    return lines.join("\n").trim();
  }

  function conciseTitle(text) {
    return String(text || "Sullivan response").replace(/[#*_`\n]/g, " ").trim().slice(0, 72) || "Sullivan response";
  }

  function truncateUtf8(text, maxBytes) {
    const encoder = new TextEncoder();
    let result = "";
    let usedBytes = 0;
    for (const character of String(text || "")) {
      const characterBytes = encoder.encode(character).length;
      if (usedBytes + characterBytes > maxBytes) break;
      result += character;
      usedBytes += characterBytes;
    }
    return result;
  }

  function renderResponseActions(root, messageData) {
    if (!messageData?.aiRunId || !messageData.aiAnswer || !messageData.aiQuestion ||
        messageData.aiContextRoomId == null || messageData.roomId == null || messageData.aiRunStatus !== "complete") return;
    if (root.querySelector(".ai-response-actions")) return;
    const actions = document.createElement("div");
    actions.className = "ai-response-actions";
    const add = (label, title, handler, requiresIdle = false) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "btn";
      button.textContent = label;
      button.title = title;
      if (requiresIdle) {
        button.dataset.requiresIdle = "true";
        button.disabled = isWorkbenchBusy();
      }
      button.addEventListener("click", handler);
      actions.appendChild(button);
    };
    const feedback = (text, error = false) => logWorkbenchMessage(
      error ? "Error" : "CommandResult",
      text,
      messageData.roomId,
      messageData.aiContextRoomId,
    );
    add("COPY", "Copy answer body", async () => {
      try {
        await navigator.clipboard.writeText(messageData.aiAnswer);
        feedback("✓ SULLIVAN ANSWER COPIED");
      } catch (err) {
        feedback(`COPY FAILED: ${err.message}`, true);
      }
    });
    add("SAVE AS NOTE", "Save answer and source references in the captured context", async () => {
      const title = await window.NRCDialog.prompt("Note title:", { title: "SAVE SULLIVAN RESPONSE", initialValue: conciseTitle(messageData.aiQuestion) });
      if (!title) return;
      const preview = JSON.stringify({ title, teaser: messageData.aiAnswer.slice(0, 240), project: "", tags: ["sullivan"] });
      const correlationId = window.NRCAssets?.sendCreateAsset(
        BigInt(messageData.aiContextRoomId), window.NRCAssets.AssetType.Note,
        window.NRCAssets.ParentType.None, 0n, preview, answerWithSources(messageData), 0,
        { onSuccess: () => feedback(`✓ NOTE SAVED IN ${getRoomName(BigInt(messageData.aiContextRoomId))}`),
          onError: (error) => feedback(`NOTE SAVE FAILED: ${error?.message || "SERVER REJECTED REQUEST"}`, true) },
      );
      if (!correlationId) feedback("NOTE SAVE FAILED: NOT CONNECTED", true);
    }, true);
    add("CREATE TASK", "Create a task in the captured context", async () => {
      const title = await window.NRCDialog.prompt("Task title:", { title: "CREATE TASK FROM RESPONSE", initialValue: conciseTitle(messageData.aiQuestion) });
      if (!title) return;
      const correlationId = window.NRCTasks?.sendCreateTask(
        BigInt(messageData.aiContextRoomId), truncateUtf8(title, 256), truncateUtf8(answerWithSources(messageData), 2048), 128, 0,
        "", 0n, [], 0, 0, "",
        {
          onSuccess: ({ task }) => feedback(`✓ TASK #${task.id} CREATED IN ${getRoomName(BigInt(messageData.aiContextRoomId))}`),
          onError: (error) => feedback(`TASK CREATE FAILED: ${error?.message || "SERVER REJECTED REQUEST"}`, true),
        },
      );
      if (correlationId) feedback("TASK CREATE REQUEST SENT");
      else feedback("TASK CREATE FAILED: NOT CONNECTED", true);
    }, true);
    add("RETRY", "Retry as a fresh run without prior conversational context", () => {
      if (isWorkbenchBusy()) return;
      resetAskSession(BigInt(messageData.aiContextRoomId), BigInt(messageData.roomId));
      handleAsk(messageData.aiQuestion, { contextConvID: messageData.aiContextRoomId, displayConvID: messageData.roomId });
    }, true);
    add("NEW SESSION", "Reset the session and clear the transcript", async () => {
      if (isWorkbenchBusy()) return;
      resetAskSession(BigInt(messageData.aiContextRoomId), BigInt(messageData.roomId));
      await window.NRCChat?.clearCurrentRoomMessages?.({
        logResult: false,
        roomId: BigInt(messageData.roomId),
        aiContextRoomId: BigInt(messageData.aiContextRoomId),
      });
      renderEmptyState();
    }, true);
    root.appendChild(actions);
  }

  document.getElementById("sullivanSend")?.addEventListener("click", () => sendBinaryMessage(messageInput.value));
  document.getElementById("sullivanStop")?.addEventListener("click", () => {
    if (activeAskRun && String(activeAskRun.displayConvId) === String(sullivanDisplayConvId)) {
      activeAskRun.controller.abort();
    }
  });

  // Expose module
  window.NRCAI = {
    handlePasteToTask,
    handlePasteToNote,
    handleAsk,
    isWorkbenchBusy,
    isSullivanView,
    getDisplayConvId,
    getContextConvId,
    getContextForDisplay,
    cancelSullivanOpen,
    openSullivan: (displayConvId = null) => {
      const displayDM = displayConvId == null ? null : activeDMs?.get(BigInt(displayConvId));
      const useCapturedContext = displayDM != null && ((displayDM.unread || 0) > 0 || roomActivity?.has?.(BigInt(displayConvId)));
      const context = useCapturedContext
        ? getContextForDisplay(displayConvId)
        : (typeof isDMConversation !== "function" || !isDMConversation(currentRoomId))
          ? currentRoomId
          : readLastNonDMRoom() || DEFAULT_ROOM_ID;
      return openSullivanWithContext(context, { focused: false });
    },
    onSelectedRoomChanged,
    onDisplayConversationRemoved,
    handleAIDMText,
    processAssetReferences,
    linkAssetReferencesInAnswer: processAssetReferences,
    renderActionPlan,
    resetAskSession,
    onRoomChanged,
    updateAskContextChip,
    openSullivanWithContext,
    clearSullivanShareMode,
    exitSullivanShareMode,
    navigateToSource,
    renderEmptyState,
    renderResponseActions,
  };
})();
