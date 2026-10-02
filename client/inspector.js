// Universal Inspector: sole owner of the right rail and inspected-entity history.
(function () {
  const state = { activeView: "chat", stack: [], sequence: 0, intentVersion: 0, returnFocus: null, allowedRoomChange: null, allowedWorkspaceChange: null };
  let backControl = null;
  let detailLoading = false;
  const prefetchedNotes = new Map();
  let prefetchInFlight = 0;

  const shell = () => document.getElementById("inspector");
  const chatContextHost = () => document.getElementById("inspectorChatContextHost");
  const aiContextHost = () => document.getElementById("inspectorAiContextHost");
  const viewContextHost = () => document.getElementById("inspectorViewContextHost");
  const entityHost = () => document.getElementById("inspectorEntityHost");
  const current = () => state.stack[state.stack.length - 1] || null;
  const key = (ref) => ref ? `${ref.roomId}:${ref.type}:${ref.id}` : "";
  const roomName = (roomId) => typeof getRoomName === "function" ? getRoomName(BigInt(roomId)) : String(roomId);

  function normalize(ref) {
    if (!ref || ref.id == null) return null;
    return { ...ref, roomId: 0n, id: BigInt(ref.id), type: String(ref.type).toLowerCase() };
  }

  async function canDispose(ref = current()) {
    if (!ref) return true;
    if (ref.type === "note") return await (window.NRCNotes?.confirmDiscardEdits?.() ?? true);
    if (ref.type === "task") return await (window.NRCTasks?.confirmDiscardTaskEdits?.() ?? true);
    if (ref.type === "reminder") return await (window.NRCTasks?.confirmDiscardReminderEdits?.() ?? true);
    if (ref.type === "appointment") return await (window.NRCAppointments?.confirmDiscardEdits?.() ?? true);
    if (["company", "contact", "activity"].includes(ref.type)) return await (window.NRCCustomers?.confirmDiscardEdits?.() ?? true);
    return true;
  }

  function setDrawer(open, trigger = null) {
    const inspector = shell();
    if (!inspector) return;
    const overlay = matchMedia("(max-width: 1199px)").matches;
    if (open && overlay) {
      if (!document.body.classList.contains("inspector-open")) {
        state.returnFocus = trigger || document.activeElement;
      }
      inspector.setAttribute("role", "dialog");
      inspector.setAttribute("aria-modal", "true");
      inspector.setAttribute("tabindex", "-1");
      requestAnimationFrame(() => {
        if (state.stack.length > 1) document.getElementById("inspectorBack")?.focus();
        else inspector.focus();
      });
    } else if (!open) {
      inspector.removeAttribute("role");
      inspector.removeAttribute("aria-modal");
      inspector.removeAttribute("tabindex");
      const target = state.returnFocus;
      // Let the mobile shell remove background inertness before restoring focus.
      requestAnimationFrame(() => target?.focus?.());
      state.returnFocus = null;
    }
    document.body.classList.toggle("inspector-open", open && overlay);
    updateActions();
  }

  function renderStatus(ref, status, detail) {
    if (key(current()) !== key(ref)) return;
    const host = entityHost();
    if (!host) return;
    showEntityHost();
    const header = document.getElementById("inspectorHeader");
    if (header) {
      const identityRow = document.createElement("div");
      identityRow.className = "inspector-identity-row";
      const identity = document.createElement("span"); identity.className = "header-text identity-reference"; identity.textContent = `${ref.type.toUpperCase()} #${ref.id}`;
      const stateLabel = document.createElement("span"); stateLabel.className = "inspector-cell-label"; stateLabel.textContent = "STATE";
      const stateValue = document.createElement("span"); stateValue.className = "status-value-mono inspector-state-value"; stateValue.textContent = status;
      identityRow.append(identity, stateLabel, stateValue);
      const scopeRow = document.createElement("div");
      scopeRow.className = "inspector-mode-row inspector-context-scope";
      const scope = document.createElement("span"); scope.className = "status-value-mono"; scope.textContent = "NO OBJECT OPERATIONS AVAILABLE";
      scopeRow.append(scope);
      header.replaceChildren(identityRow, scopeRow);
    }
    host.replaceChildren();
    const section = document.createElement("section");
    section.className = "ledger-context-section inspector-status";
    const label = document.createElement("div");
    label.className = "ledger-context-label";
    label.textContent = `${ref.type.toUpperCase()} #${ref.id}`;
    const message = document.createElement("p");
    message.textContent = detail || status;
    section.append(label, message);
    host.append(section);
    updateActions();
  }

  function setDetailLoading(loading) {
    detailLoading = loading;
    const host = entityHost();
    if (host) {
      host.inert = loading;
      host.setAttribute("aria-busy", String(loading));
    }
    const header = document.getElementById("inspectorHeader");
    if (header) {
      header.setAttribute("aria-busy", String(loading));
      for (const button of header.querySelectorAll("button:not(.task-detail-close):not(#inspectorBack)")) button.inert = loading;
    }
  }

  async function readLinkedEntity(ref, isCancelled, { prefetch = false } = {}) {
    const isTask = ref.type === "task";
    const cached = isTask ? window.NRCTasks?.roomTasks?.get(ref.roomId)?.get(ref.id)
      : window.NRCAssets?.roomAssets?.get(ref.roomId)?.get(ref.id);
    const entityRequest = cached && (isTask || cached.payload != null) ? cached : new Promise((resolve, reject) => {
      const options = { onSuccess: detail => resolve(isTask ? detail.task : detail.asset), onError: reject };
      if (isTask) window.NRCTasks.requestTask(ref.roomId, ref.id, options);
      else window.NRCAssets.requestAsset(ref.roomId, ref.id, options);
    });
    // Body and relationships are independent reads. Wait for both even on
    // failure, so exact-read broadcasts cannot publish a partial detail.
    const results = await Promise.allSettled([
      entityRequest,
      window.NRCLinksUI.loadLinks(ref.roomId, isTask ? 2 : 1, ref.id, isCancelled, { prefetch }),
    ]);
    for (const result of results) if (result.status === "rejected") throw result.reason;
    const entity = results[0].value;
    if (!entity || ref.type === "note" && entity.assetType !== AssetType.Note) throw new Error("Record not found");
    return entity;
  }

  function validPrefetch(ref, entry = prefetchedNotes.get(key(ref))) {
    return entry && prefetchedNotes.get(key(ref)) === entry &&
      typeof ws !== "undefined" && entry.socket === ws && serverReady &&
      (!entry.asset || window.NRCAssets?.roomAssets?.get(ref.roomId)?.get(ref.id) === entry.asset) &&
      (entry.foreground?.() || Date.now() < entry.expires);
  }

  function prefetchNote(input) {
    const ref = normalize({ ...input, type: "note" });
    if (!ref || typeof ws === "undefined" || !ws || !serverReady || key(current()) === key(ref)) return;
    if (validPrefetch(ref) || prefetchInFlight >= 2) return;
    // Only likely next selections, never the whole list. Completed entries are
    // short-lived and bounded; full payloads use the existing asset cache.
    const entry = { socket: ws, expires: Date.now() + 10000, promise: null };
    prefetchedNotes.delete(key(ref));
    if (prefetchedNotes.size >= 4) {
      for (const [candidate, pending] of prefetchedNotes) {
        if (pending.foreground?.()) continue;
        prefetchedNotes.delete(candidate);
        break;
      }
    }
    prefetchedNotes.set(key(ref), entry);
    prefetchInFlight++;
    entry.promise = readLinkedEntity(ref, () => !validPrefetch(ref, entry), { prefetch: true })
      .then(asset => { entry.asset = asset; return asset; })
      .catch(() => {
        if (prefetchedNotes.get(key(ref)) === entry) prefetchedNotes.delete(key(ref));
        return null; // Speculation must never surface an error or block retry.
      })
      .finally(() => { prefetchInFlight--; });
  }

  async function loadLinkedEntity(ref, stillCurrent) {
    const isNote = ref.type === "note";
    const isTask = ref.type === "task";
    const cached = isTask ? window.NRCTasks?.roomTasks?.get(ref.roomId)?.get(ref.id)
      : window.NRCAssets?.roomAssets?.get(ref.roomId)?.get(ref.id);
    const select = (entity, options) => isNote
      ? window.NRCNotes.selectNote(entity, { fromInspector: true, subview: ref.subview, focusId: ref.focusId, ...options })
      : isTask ? window.NRCTasks.selectTask(entity, { fromInspector: true, subview: ref.subview, focusId: ref.focusId, ...options })
        : window.NRCCustomers.showInspector(ref, entity);
    if (!entityHost()?.hasChildNodes()) renderStatus(ref, "LOADING", `Loading ${ref.type} #${ref.id}…`);
    setDetailLoading(true);
    const prefetched = prefetchedNotes.get(key(ref));
    const deferDetail = isNote && ref.deferDetail && !(prefetched?.asset && validPrefetch(ref, prefetched));
    if (cached && (isNote || isTask)) {
      select(cached, deferDetail ? { deferDetail: true } : { loadDetail: false });
      if (deferDetail) {
        return;
      }
    }
    try {
      // A click owns the pending work now: unrelated hover entries and the
      // speculative TTL must not cancel it. Mutations still invalidate it.
      if (validPrefetch(ref, prefetched)) prefetched.foreground = stillCurrent;
      let entity = validPrefetch(ref, prefetched) ? await prefetched.promise : null;
      if (!stillCurrent()) return;
      if (!entity || !validPrefetch(ref, prefetched)) {
        entity = await readLinkedEntity(ref, () => !stillCurrent());
      }
      if (!stillCurrent()) return;
      setDetailLoading(false);
      select(entity, {});
      updateActions();
    } catch (error) {
      if (!stillCurrent()) return;
      setDetailLoading(false);
      renderStatus(ref, "LOAD FAILED", error?.message || "Details could not be loaded.");
      const retry = document.createElement("button");
      retry.className = "btn";
      retry.textContent = "RETRY";
      retry.onclick = () => renderEntity(ref);
      entityHost()?.append(retry);
    }
  }

  function renderEntity(ref) {
    const token = ++state.sequence;
    const stillCurrent = () => token === state.sequence && key(current()) === key(ref);
    setDetailLoading(false);
    showEntityHost();
    if (["company", "activity"].includes(ref.type) || ref.type === "contact" && !ref.id) {
      window.NRCCustomers?.showInspector(ref);
    } else if (["note", "task", "contact"].includes(ref.type)) {
      loadLinkedEntity(ref, stillCurrent);
    } else if (ref.type === "reminder") {
      if (!window.NRCTasks?.selectReminder?.(ref.id, { fromInspector: true, roomId: ref.roomId })) {
        renderStatus(ref, "LOADING", `Loading reminder #${ref.id}…`);
        window.NRCAssets?.requestAsset?.(ref.roomId, ref.id, {
          onSuccess: (detail) => {
            if (!stillCurrent()) return;
            if (detail?.asset?.assetType !== AssetType.Reminder || !window.NRCTasks?.selectReminder(ref.id, { fromInspector: true, roomId: ref.roomId }))
              renderStatus(ref, "NOT FOUND", `Reminder #${ref.id} was not found in ${roomName(ref.roomId)}.`);
          },
          onError: () => { if (stillCurrent()) renderStatus(ref, "NOT FOUND", `Reminder #${ref.id} could not be loaded from ${roomName(ref.roomId)}.`); },
        });
      }
    } else if (ref.type === "appointment") {
      window.NRCAppointments?.showInspector?.(ref, stillCurrent);
    } else if (ref.type === "file") {
      window.NRCFiles?.showInspector?.(ref);
    } else renderStatus(ref, "UNSUPPORTED", `Inspector does not support ${ref.type}.`);
    updateActions();
  }

  async function openEntity(input, options = {}) {
    const intent = ++state.intentVersion;
    const ref = normalize({ ...input, ...options });
    if (!ref) return false;
    const existing = current();
    if (existing && key(existing) === key(ref)) {
      if (!(await canDispose(existing))) return false;
      if (!isIntentCurrent(intent)) return false;
      Object.assign(existing, ref);
      renderEntity(existing);
      setDrawer(true);
      return true;
    }
    if (!(await canDispose(existing))) return false;
    if (!isIntentCurrent(intent)) return false;
    const replaceCurrent = Boolean(existing && options.replaceCurrent);
    if (!replaceCurrent || existing.type !== ref.type) {
      clearModuleSelection(existing, true);
    }
    if (replaceCurrent) {
      state.stack[state.stack.length - 1] = ref;
    } else {
      state.stack.push(ref);
    }
    renderEntity(ref);
    setDrawer(true);
    return true;
  }

  function showEntityHost() {
    const entity = entityHost();
    if (chatContextHost()) chatContextHost().hidden = true;
    if (viewContextHost()) viewContextHost().hidden = true;
    if (entity) entity.hidden = false;
  }

  function showContextHost() {
    setDetailLoading(false);
    const chat = chatContextHost();
    const view = viewContextHost();
    const entity = entityHost();
    const usesConversationContext = state.activeView === "chat" ||
      state.activeView === "sullivan" || state.activeView === "sullivanShare";
    if (entity) {
      entity.hidden = true;
      entity.replaceChildren();
    }
    if (chat) chat.hidden = !usesConversationContext;
    if (view) view.hidden = usesConversationContext;
  }

  function clearModuleSelection(ref, preserveDetail = false) {
    if (ref?.type === "note") window.NRCNotes?.clearNoteSelection?.({ fromInspector: true, preserveDetail });
    if (ref?.type === "task") window.NRCTasks?.clearTaskSelection?.({ fromInspector: true, preserveDetail });
    if (ref?.type === "reminder") window.NRCTasks?.clearReminderSelection?.({ fromInspector: true });
    if (ref?.type === "appointment") window.NRCAppointments?.clearSelection?.();
    if (["company", "contact", "activity"].includes(ref?.type)) window.NRCCustomers?.clearSelection();
  }

  async function back() {
    const intent = ++state.intentVersion;
    const ref = current();
    if (!ref || !(await canDispose(ref))) return false;
    if (!isIntentCurrent(intent)) return false;
    clearModuleSelection(ref, state.stack.length > 1);
    state.stack.pop();
    const previous = current();
    if (previous) renderEntity(previous);
    else {
      showContext();
      setDrawer(false);
    }
    return true;
  }

  async function close() {
    const intent = ++state.intentVersion;
    const ref = current();
    if (ref && !(await canDispose(ref))) return false;
    if (!isIntentCurrent(intent)) return false;
    clearModuleSelection(ref);
    state.stack = [];
    showContext();
    setDrawer(false);
    return true;
  }

  function entityDeleted(input) {
    const ref = normalize(input);
    if (!ref) return false;
    const deletedKey = key(ref);
    const wasCurrent = key(current()) === deletedKey;
    const previousLength = state.stack.length;
    state.stack = state.stack.filter((entry) => key(entry) !== deletedKey);
    if (state.stack.length === previousLength) return false;
    state.intentVersion += 1;
    if (wasCurrent) {
      state.sequence += 1;
      clearModuleSelection(ref);
      const previous = current();
      if (previous) renderEntity(previous);
      else {
        showContext();
        setDrawer(false);
      }
    } else {
      updateActions();
    }
    return true;
  }

  function contextRows(rows) {
    const section = document.createElement("section");
    section.className = "ledger-context-section";
    const label = document.createElement("div");
    label.className = "ledger-context-label";
    label.textContent = "CURRENT STATE";
    const values = document.createElement("dl");
    values.className = "ledger-context-values";
    for (const [name, value] of rows) {
      const row = document.createElement("div");
      const dt = document.createElement("dt"); dt.textContent = name;
      const dd = document.createElement("dd"); dd.textContent = value ?? "—";
      if (name === "Room" || name === "Project" || name === "Workspace") dd.className = "identity-scope";
      else if (name === "Assignee" || name === "Owner" || name === "Author") dd.className = "identity-actor";
      row.append(dt, dd); values.append(row);
    }
    section.append(label, values);
    return section;
  }

  function systemLogTimestamp(timestamp) {
    const date = new Date(timestamp);
    const datePart = [date.getFullYear(), date.getMonth() + 1, date.getDate()]
      .map((value, index) => String(value).padStart(index === 0 ? 4 : 2, "0"))
      .join("-");
    const timePart = [date.getHours(), date.getMinutes(), date.getSeconds()]
      .map((value) => String(value).padStart(2, "0"))
      .join(":");
    return `${datePart} ${timePart}.${String(date.getMilliseconds()).padStart(3, "0")}`;
  }

  function renderSystemLogEntry(entry) {
    if (state.activeView !== "systemLog" || current()) return;
    document.body.classList.toggle("system-log-inspector-empty", !entry);
    if (!entry) return;

    showContextHost();
    const host = viewContextHost();
    if (!host) return;
    host.replaceChildren(
      contextRows([
        ["Event", `#${entry.id}`],
        ["Timestamp", systemLogTimestamp(entry.timestamp)],
        ["Level", entry.level],
        ["Source", entry.source],
      ]),
    );
    const messageSection = document.createElement("section");
    messageSection.className = "ledger-context-section";
    const label = document.createElement("div");
    label.className = "ledger-context-label";
    label.textContent = "COMPLETE MESSAGE";
    const message = document.createElement("pre");
    message.className = "system-log-inspector-message";
    message.textContent = entry.message;
    messageSection.append(label, message);
    host.append(messageSection);

    const header = document.getElementById("inspectorHeader");
    if (header) {
      const identityRow = document.createElement("div");
      identityRow.className = "inspector-identity-row";
      const identity = document.createElement("span"); identity.className = "header-text identity-reference"; identity.textContent = `EVENT #${entry.id}`;
      const stateLabel = document.createElement("span"); stateLabel.className = "inspector-cell-label"; stateLabel.textContent = "STATE";
      const stateValue = document.createElement("span"); stateValue.className = "status-value-mono inspector-state-value"; stateValue.textContent = entry.level;
      identityRow.append(identity, stateLabel, stateValue);
      const scopeRow = document.createElement("div");
      scopeRow.className = "inspector-mode-row inspector-context-scope";
      const scope = document.createElement("span"); scope.className = "status-value-mono"; scope.textContent = `${entry.source.toUpperCase()} · ${systemLogTimestamp(entry.timestamp)}`;
      scopeRow.append(scope);
      header.replaceChildren(identityRow, scopeRow);
    }
    updateActions();
  }

  function showContext() {
    if (current()) return;
    const view = state.activeView;
    if (view === "systemLog") {
      renderSystemLogEntry(window.NRCSystemLog?.getSelectedEntry?.() || null);
      return;
    }
    const viewLabel = view === "kanban" ? "TASK LIST" : view.toUpperCase();
    const usesConversationContext = view === "chat" || view === "sullivan" || view === "sullivanShare";
    const host = usesConversationContext ? chatContextHost() : viewContextHost();
    if (!host) return;
    showContextHost();
    const contextRoomId = (view === "sullivan" || view === "sullivanShare")
      ? window.NRCAI?.getContextConvId?.()
      : typeof currentRoomId !== "undefined" ? currentRoomId : null;
    const room = !usesConversationContext ? "WORKSPACE" : contextRoomId != null ? roomName(contextRoomId) : "—";
    if (usesConversationContext) {
      const chatRoom = document.getElementById("inspectorChatRoom");
      const participants = document.getElementById("inspectorChatParticipants");
      const aiContext = aiContextHost();
      if (chatRoom) chatRoom.textContent = room;
      if (participants) {
        participants.textContent = view === "chat"
          ? String(document.querySelectorAll("#usersList .user-item").length || "—")
          : "SULLIVAN";
      }
      if (aiContext) aiContext.hidden = view === "chat";
    }
    const rows = view === "notes" ? [["Scope", "WORKSPACE"], ["Project", document.getElementById("notesProjectFilter")?.selectedOptions?.[0]?.textContent || "ALL"], ["Tag", document.getElementById("notesTagFilter")?.selectedOptions?.[0]?.textContent || "ALL"], ["Search", document.getElementById("notesSearch")?.value || "—"], ["Results", document.getElementById("notesCount")?.textContent || "—"]]
      : view === "kanban" ? [["Scope", "WORKSPACE"], ["Search", document.getElementById("taskSearch")?.value || "—"], ["Assignee", document.getElementById("filterAssignee")?.selectedOptions?.[0]?.textContent || "ALL"], ["Blocked", document.getElementById("blockedCount")?.textContent || "0"], ["Overdue", document.getElementById("overdueCount")?.textContent || "0"]]
      : view === "reminders" ? [["Scope", "WORKSPACE"], ["Queue", document.getElementById("reminderQueueCount")?.textContent || "—"], ["View", "REMINDERS"]]
      : [["View", view.toUpperCase()], ["Inspector", "UNAVAILABLE IN FOCUSED VIEW"]];
    if (!usesConversationContext) {
      host.replaceChildren(contextRows(rows));
      if (view === "notes") {
        const selection = document.createElement("section");
        selection.className = "ledger-context-section inspector-empty-state";
        const selectionLabel = document.createElement("div");
        selectionLabel.className = "ledger-context-label";
        selectionLabel.textContent = "SELECTION";
        const selectionValue = document.createElement("div");
        selectionValue.className = "inspector-empty-state-value";
        selectionValue.textContent = "NO NOTE SELECTED";
        const selectionHelp = document.createElement("p");
        selectionHelp.className = "inspector-empty-state-help";
        selectionHelp.textContent = "Select a note to inspect its content.";
        selection.append(selectionLabel, selectionValue, selectionHelp);
        host.append(selection);
      }
    }
    const header = document.getElementById("inspectorHeader");
    if (header) {
      header.replaceChildren();
      const row = document.createElement("div");
      const title = document.createElement("span"); title.className = "header-text"; title.textContent = "INSPECTOR";
      const stateLabel = document.createElement("span"); stateLabel.className = "inspector-cell-label"; stateLabel.textContent = "STATE";
      const meta = document.createElement("span"); meta.className = "status-value-mono inspector-state-value"; meta.textContent = `${viewLabel} CONTEXT`;
      row.className = "inspector-identity-row";
      row.append(title, stateLabel, meta); header.append(row);
      const scopeRow = document.createElement("div");
      scopeRow.className = "inspector-mode-row inspector-context-scope inspector-context-scope--summary";
      const scopeLabel = document.createElement("small"); scopeLabel.textContent = view === "chat" ? "ROOM / VIEW" : "SCOPE / VIEW";
      const scope = document.createElement("span"); scope.className = "status-value-mono"; scope.textContent = `${room} · ${viewLabel}`;
      scopeRow.append(scopeLabel, scope); header.append(scopeRow);
    }
    updateActions();
  }

  function consumeRoomChange(roomId) {
    if (state.allowedRoomChange === BigInt(roomId)) { state.allowedRoomChange = null; return true; }
    return false;
  }

  async function requestRoomChange(roomId, continuation) {
    const intent = ++state.intentVersion;
    const ref = current();
    if (!(await canDispose(ref))) return false;
    if (!isIntentCurrent(intent)) return false;
    state.allowedRoomChange = BigInt(roomId);
    continuation();
    if (ref && key(current()) === key(ref)) renderEntity(ref);
    return true;
  }

  function consumeWorkspaceChange(workspaceId) {
    if (state.allowedWorkspaceChange === workspaceId) {
      state.allowedWorkspaceChange = null;
      return true;
    }
    return false;
  }

  async function requestWorkspaceChange(workspaceId, continuation) {
    const intent = ++state.intentVersion;
    if (!(await canDispose())) return false;
    if (!isIntentCurrent(intent)) return false;
    state.allowedWorkspaceChange = workspaceId;
    continuation();
    return true;
  }

  function beginExternalLoad() {
    state.intentVersion += 1;
    return state.intentVersion;
  }

  function isIntentCurrent(version) {
    return state.intentVersion === version;
  }

  function updateActions() {
    const hasHistory = state.stack.length > 1;
    const actions = document.getElementById("inspectorActions");
    const modeRow = document.querySelector("#inspectorHeader > .inspector-mode-row");
    backControl ||= document.getElementById("inspectorBack");
    if (!backControl) return;
    backControl.disabled = !hasHistory;
    const destination = hasHistory && modeRow ? modeRow : actions;
    if (destination && backControl.parentElement !== destination) {
      if (hasHistory) destination.prepend(backControl);
      else destination.append(backControl);
    }
  }

  function isEditableShortcutTarget(target) {
    if (!target) return false;
    if (target.isContentEditable) return true;
    const tagName = target.tagName?.toLowerCase();
    return tagName === "input" || tagName === "textarea" || tagName === "select";
  }

  function handleEntityShortcut(event) {
    if (!current() || event.defaultPrevented || event.repeat) return false;
    if (event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) return false;
    if (isEditableShortcutTarget(event.target)) return false;

    const keyName = event.key.toLowerCase();
    if (!/^[12emsv]$/.test(keyName)) return false;
    const selector = keyName === "1"
      ? '[data-tab="detail"]'
      : keyName === "2"
        ? '[data-tab="comments"]'
        : `[data-inspector-command="${keyName}"]`;
    // M reaches the record's message block, which is a panel control rather
    // than a header operation: it opens the composer and focuses it, opening
    // the block first when the panel is too narrow to show the column.
    const messagesArea = keyName === "m" ? entityHost()?.querySelector("[data-messages-area]") : null;
    const control = keyName === "m"
      ? messagesArea?.querySelector("[data-composer-toggle]")
      : document.querySelector(`#inspectorHeader ${selector}`);
    if (!control || detailLoading || control.disabled || control.getAttribute("aria-disabled") === "true") return false;
    event.preventDefault();
    event.stopImmediatePropagation();
    control.click();
    return true;
  }

  function setActiveView(view) {
    state.activeView = view;
    if (view !== "systemLog") document.body.classList.remove("system-log-inspector-empty");
    shell()?.classList.toggle("inspector-entity-only", ["kanban", "notes", "customers", "reminders", "attention", "calendar"].includes(view));
    const focused = view === "noteShare" || view === "sullivanShare";
    shell()?.classList.toggle("inspector-unavailable", focused);
    if (focused) setDrawer(false);
    else if (!current()) showContext();
  }

  document.addEventListener("DOMContentLoaded", () => {
    // Reads fill caches; only mutations invalidate speculative complete details.
    window.NRCEdges?.addEdgeChangeListener((_edge, action) => {
      if (action === "created" || action === "deleted") prefetchedNotes.clear();
    });
    for (const event of ["nrc:asset-created", "nrc:asset-updated", "nrc:asset-deleted", "nrc:task-changed"]) {
      document.addEventListener(event, () => prefetchedNotes.clear());
    }
    backControl = document.getElementById("inspectorBack");
    backControl?.addEventListener("click", back);
    const header = document.getElementById("inspectorHeader");
    if (header && typeof MutationObserver !== "undefined") {
      new MutationObserver(updateActions).observe(header, { childList: true, subtree: true });
    }
    document.addEventListener("focusin", (event) => {
      if (event.target.closest?.("#inspectorHeader .inspector-mode-row")) {
        // Native focus can leave a mostly-visible action clipped at the edge.
        event.target.scrollIntoView({ block: "nearest", inline: "nearest" });
      }
    });
    document.addEventListener("input", (event) => {
      if (!current() && event.target.matches("#notesSearch, #taskSearch")) showContext();
    });
    document.addEventListener("change", (event) => {
      if (!current() && event.target.matches("#notesProjectFilter, #notesTagFilter, #filterAssignee, #filterHideLockedReminders")) showContext();
    });
    document.addEventListener("keydown", (event) => {
      if (event.target.closest?.(".nrc-dialog-backdrop")) return;
      const drawerOpen = document.body.classList.contains("inspector-open");
      if (event.key === "Tab" && drawerOpen) {
        const focusable = Array.from(shell()?.querySelectorAll("button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex='-1'])") || [])
          .filter((element) => element.offsetParent !== null && !element.closest("[inert]"));
        if (focusable.length === 0) return;
        const first = focusable[0];
        const last = focusable[focusable.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
        return;
      }
      if (handleEntityShortcut(event)) return;
      if (event.key !== "Escape" || !current() && !drawerOpen) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      // An open message block collapses before the panel changes mode or closes.
      // CSS owns the composition: in the column composition the register line
      // is inert, so there is nothing to collapse and ESC keeps its panel
      // meaning.
      const strip = entityHost()?.querySelector('[data-messages-area][data-messages-open="true"] [data-messages-toggle]');
      if (strip && getComputedStyle(strip).pointerEvents !== "none") {
        strip.click();
        return;
      }
      // Leave edit mode before closing, using the editor's guarded VIEW action.
      const leaveEdit = document.querySelector('#inspectorHeader #taskDetailToggleFocus[data-inspector-command="v"], #inspectorHeader #noteDetailToggleView') ||
        (current()?.id !== 0n && entityHost()?.querySelector("#customerCancel"));
      if (leaveEdit) {
        leaveEdit.click();
        return;
      }
      if (current()) close();
      else setDrawer(false);
    });
    matchMedia("(max-width: 1199px)").addEventListener("change", (event) => {
      if (!event.matches) {
        shell()?.removeAttribute("role");
        shell()?.removeAttribute("aria-modal");
        shell()?.removeAttribute("tabindex");
        document.body.classList.remove("inspector-open");
      }
      updateActions();
    });
    showContext();
  });

  window.NRCInspector = {
    openEntity, prefetchNote, back, close, entityDeleted, showContext, refreshContext: showContext,
    showSystemLogEntry: renderSystemLogEntry,
    setActiveView, current, hasEntity: () => !!current(), consumeRoomChange,
    requestRoomChange, consumeWorkspaceChange, requestWorkspaceChange,
    beginExternalLoad, isIntentCurrent,
    isLoading: () => detailLoading,
  };
})();
