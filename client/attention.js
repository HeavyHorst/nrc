// ATTENTION register: the derived work rows that need the operator.
//
// Every row is a condition, not an event, and every row clears itself: a task
// that stops being mine or a reminder that is handled. The
// register therefore owns no state of its own and never needs a dismiss action,
// which is what keeps it from becoming a second truth next to the sidebar badges
// and the chat unread state.
//
// Sources, all of them owned elsewhere:
// - tasks: a headless task query per count, with the row query walked to its last
//   page, so the numbers come from the server's `total_count` and the rows are the
//   operator's whole open queue rather than whatever happens to be loaded in the
//   task register.
// - reminders: `NRCTasks.getReminderSnapshot()`, the same snapshot the reminder
//   timer reports from.
// - dependencies: all pages of open blocked tasks, including other assignees.
//   Only actionable prerequisites owned by the reader become UNBLOCKS rows.
window.NRCAttention = (() => {
  const FILTERS = ["all", "task", "reminder", "message"];
  // One primary reason per row. Overdue wins over unblocks for actionable tasks; kind
  // filters still operate independently of the reason sections.
  const REASONS = [
    ["overdue", "OVERDUE / MY WORK"],
    ["waiting", "OVERDUE / WAITING"],
    ["unblocks", "UNBLOCKS / MY WORK"],
    ["assigned", "ASSIGNED TO ME"],
    ["reminder", "DUE REMINDERS / WORKSPACE"],
    ["mention", "MENTIONED / SESSION"],
    ["message", "UNREAD / SESSION"],
  ];
  // The flash runs for as long as the animation does; the class is dropped after
  // it so a second jump to the same message replays it.
  const FLASH_MS = 2000;
  const REFRESH_DEBOUNCE_MS = 400;
  const TONES = { danger: "attention-state--danger", priority: "attention-state--priority",
    blocked: "attention-state--blocked", new: "attention-state--new", mine: "attention-state--mine" };
  // The count queries run one after another: the controller keeps a single
  // pending page, so a second request would cancel the first.
  const COUNT_QUERIES = ["mine", "blocked", "overdue"];
  // The row query is walked to its end, so the register lists the operator's whole
  // open queue instead of one page of it. The cap is far above what one reader owns
  // and only exists so a listing that never ends cannot spin the client.
  const MAX_TASK_PAGES = 50;

  const el = (id) => document.getElementById(id);
  const nowNanos = () => BigInt(Date.now()) * 1000000n;

  const state = {
    mode: "idle", // idle | loading | ready | error
    filter: "all",
    rows: [],
    tasks: [],
    hasMoreTasks: false,
    counts: { mine: 0, blocked: 0, overdue: 0 },
    reminders: { due: 0, total: 0 },
    dependencies: [],
    dependenciesIncomplete: true,
  };

  let countController = null;
  let countFilters = null;
  let countQuery = null;
  // Pages of the current row walk, the first one included. A fresh walk starts at
  // one and the cap stops it, so a listing that never ends cannot spin the client.
  let taskPages = 0;

  // ---------------------------------------------------------------------------
  // Task counts and rows
  // ---------------------------------------------------------------------------

  function ready() {
    return typeof serverReady !== "undefined" && serverReady &&
      typeof ws !== "undefined" && ws?.readyState === WebSocket.OPEN;
  }

  function nickname() {
    return typeof myNickname === "string" ? myNickname : "";
  }

  function filterFor(kind) {
    // `project: null` is "every project". An empty string is not the absence of a
    // filter: the query carries a project flag, and the server matches that flag
    // against the task's own project, so `""` would ask for the tasks that have
    // no project label and hide every task that has one.
    const base = { status: "open", assignee: "me", project: null, color: null, blocked: null, overdue: false, search: "" };
    if (kind === "blocked") return { ...base, assignee: null, blocked: true };
    if (kind === "overdue") return { ...base, overdue: true };
    return base;
  }

  function controller() {
    if (countController) return countController;
    if (typeof window.createTaskQueryController !== "function") return null;
    countController = window.createTaskQueryController({
      getRoomId: () => 0n,
      getFilters: () => countFilters || filterFor("mine"),
      getSort: () => ({ column: "dueAt", direction: "asc" }),
      getNickname: nickname,
      isReady: ready,
      nextId: () => (typeof getRpcCorrelationId === "function" ? getRpcCorrelationId() : 0),
      send: (buffer) => {
        // The production sender owns the transport counters.
        if (typeof sendPacket === "function") { sendPacket(buffer); return; }
        if (typeof ws !== "undefined" && ws?.readyState === WebSocket.OPEN) ws.send(buffer);
      },
      parseTask: (view, offset) => parseTask(view, offset),
      // Counts must not seed the task register's cache or trigger its renders.
      cacheTasks: () => {},
      onProjects: () => {},
      onChange: () => advanceCountQuery(),
    });
    return countController;
  }

  function runCountQuery(kind) {
    const headless = controller();
    if (!headless || !ready()) return;
    countQuery = kind;
    countFilters = filterFor(kind);
    // A row walk starts over at its first page.
    taskPages = 0;
    // The row query is the first one, so it also carries the first page of rows.
    headless.update({ force: true });
  }

  function advanceCountQuery() {
    const headless = controller();
    if (!headless || !countQuery) return;
    const kind = countQuery;
    const result = headless.getState();
    if (result.mode === "loading") return;
    if (result.mode === "error") {
      countQuery = null;
      state.mode = "error";
      render();
      return;
    }
    if (kind !== "blocked") state.counts[kind] = result.total;
    if (kind === "mine" || kind === "blocked") {
      // Every page is kept: the register lists the operator's open queue, so the
      // rows are followed to their last page before the count-only queries run.
      // The walk ends when the server says so, when the connection it was asked
      // over is gone, or at the cap.
      if (kind === "mine") {
        state.tasks = [...result.tasks.values()];
        state.hasMoreTasks = result.hasMore === true;
      } else {
        state.dependencies = [...result.tasks.values()];
        state.dependenciesIncomplete = result.hasMore === true;
        state.counts.blocked = state.dependencies.filter(task => task.assignee === nickname()).length;
      }
      taskPages += 1;
      if (result.hasMore && ready() && taskPages < MAX_TASK_PAGES) {
        headless.loadMore();
        return;
      }
    }
    const next = COUNT_QUERIES[COUNT_QUERIES.indexOf(kind) + 1];
    countQuery = null;
    if (next) runCountQuery(next);
    else refreshDerived();
  }

  // ---------------------------------------------------------------------------
  // Rows
  // ---------------------------------------------------------------------------

  function formatDate(nanos) {
    if (!nanos || nanos === 0n) return "";
    const date = new Date(Number(nanos / 1000000n));
    const pad = (value) => String(value).padStart(2, "0");
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  }

  function formatAge(nanos) {
    if (!nanos || nanos === 0n) return "";
    const minutes = Math.max(0, Math.floor((Date.now() - Number(nanos / 1000000n)) / 60000));
    if (minutes < 60) return `${minutes}M`;
    if (minutes < 60 * 24) return `${Math.floor(minutes / 60)}H`;
    return `${Math.floor(minutes / (60 * 24))}D`;
  }

  function taskRow(task, dependents, prerequisite) {
    const now = nowNanos();
    const due = task.dueAt > 0n ? task.dueAt : 0n;
    const overdue = due > 0n && due < now && task.status !== window.NRCTasks?.TaskStatus?.Done;
    const blocked = task.blockedBy !== 0n;
    if (blocked && !overdue) return null;
    const related = blocked ? [prerequisite || { id: task.blockedBy, title: `Prerequisite #${task.blockedBy}` }] : dependents;
    let detail = "";
    if (blocked) detail = `DUE ${formatDate(due)} · WAITING ON #${task.blockedBy}`;
    else if (dependents.length) detail = `UNBLOCKS ${dependents.length}${state.dependenciesIncomplete ? "+" : ""} TASK${dependents.length === 1 ? "" : "S"}`;
    else if (due > 0n) detail = `DUE ${formatDate(due)}`;
    else if (task.createdBy) detail = `ASSIGNED BY ${task.createdBy}`;
    let chip = { label: "MINE", tone: "mine" };
    if (overdue) chip = { label: "OVERDUE", tone: "danger" };
    if (blocked) chip = { label: "WAITING", tone: "blocked" };
    else if (!overdue && dependents.length) chip = { label: "UNBLOCKS", tone: "priority" };
    return {
      kind: "TASK", group: "task", id: task.id, title: task.title, detail,
      reason: blocked ? "waiting" : overdue ? "overdue" : dependents.length ? "unblocks" : "assigned",
      related,
      chip, age: formatAge(task.updatedAt), sortKey: Number(due > 0n ? due : task.updatedAt),
      open: () => window.NRCInspector?.openEntity?.({ roomId: 0n, type: "task", id: task.id }),
    };
  }

  function reminderRow(reminder) {
    const states = window.NRCTasks?.ReminderState;
    const late = reminder.state === states?.Late;
    return {
      kind: "REMINDER", group: "reminder", id: reminder.asset.assetId, title: reminder.title,
      reason: "reminder",
      detail: `DUE ${formatDate(reminder.deadlineAt)}`,
      chip: late ? { label: "LATE", tone: "danger" } : { label: "DUE", tone: "priority" },
      age: formatAge(reminder.asset.updatedAt), sortKey: Number(reminder.deadlineAt),
      open: () => window.NRCInspector?.openEntity?.({ roomId: 0n, type: "reminder", id: reminder.asset.assetId }),
    };
  }

  function isDirectMessage(convId) {
    return typeof isDMConversation === "function" && isDMConversation(convId);
  }

  function conversationName(convId) {
    if (isDirectMessage(convId)) {
      const dm = typeof activeDMs !== "undefined" ? activeDMs.get(convId) : null;
      if (!dm?.username) return null;
      return typeof formatDMDisplayName === "function"
        ? formatDMDisplayName(dm.username, dm.authenticated)
        : dm.username;
    }
    return typeof getRoomName === "function" ? getRoomName(convId) : null;
  }

  // The flash is the only acknowledgement a jump needs: the message keeps the
  // mention tint for a moment and then returns to its normal surface.
  function flashTarget(convId, sequence, page) {
    const target = BigInt(sequence);
    if (page?.retentionCutoffSeq > 0n && target < page.retentionCutoffSeq) {
      logSystem(`MESSAGE ${target} IS NO LONGER RETAINED · OPENED LATEST`, "chat", "DEBUG");
      return;
    }
    const row = document.querySelector(`#logOutput [data-sequence="${target}"]`);
    if (!row) {
      logSystem(`MESSAGE ${target} WAS NOT FOUND IN ${conversationName(convId)}`, "chat", "DEBUG");
      return;
    }
    row.scrollIntoView({ block: "center" });
    row.classList.add("chat-target");
    if (window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches) return;
    setTimeout(() => row.classList.remove("chat-target"), FLASH_MS);
  }

  // A jump is the chat's own navigation plus one page around the target. DMs
  // have no retained history and a room with retention off has nothing to fetch,
  // so those rows simply open the conversation.
  function openConversation(convId, sequence) {
    if (typeof openChatRoom !== "function") return;
    openChatRoom(convId);
    if (sequence == null || isDirectMessage(convId)) return;
    if (typeof retainedRoomStates !== "undefined" && retainedRoomStates.get(convId) === "disabled") {
      logSystem(`NO RETAINED HISTORY IN ${conversationName(convId)} · OPENED LATEST`, "chat", "DEBUG");
      return;
    }
    requestRetainedHistory(convId, BigInt(sequence) + 1n, 0, {
      single: true,
      onPage: (page) => flashTarget(convId, sequence, page),
    });
  }

  function messageRows() {
    const entries = window.NRCChatUnread?.snapshot?.() || [];
    const rows = [];
    for (const entry of entries) {
      const name = conversationName(entry.convId);
      if (!name) continue;
      const direct = isDirectMessage(entry.convId);
      // Everything in a direct message is addressed to the operator, so a
      // mention there is not a separate signal.
      const mentions = direct ? 0 : entry.mentionCount || 0;
      const sequence = mentions > 0 ? entry.mentionSequence : entry.firstSequence;
      const authors = (entry.authors || []).slice(0, 2).join(", ");
      rows.push({
        kind: direct ? "DM" : mentions > 0 ? "MENTION" : "MESSAGE",
        group: "message",
        reason: mentions > 0 ? "mention" : "message",
        id: entry.convId,
        title: mentions > 0 && entry.mentionText
          ? entry.mentionText
          : direct ? name : `${entry.count} new message${entry.count === 1 ? "" : "s"}`,
        detail: direct ? `DIRECT · ${entry.count} UNREAD` : [name, authors].filter(Boolean).join(" · "),
        chip: mentions > 0
          ? { label: "@ YOU", tone: "new" }
          : { label: `${entry.count} NEW`, tone: "new" },
        age: formatAge(entry.oldestTimestamp),
        sortKey: Number(entry.oldestTimestamp || 0n),
        jumpable: !direct && sequence != null,
        open: () => openConversation(entry.convId, sequence),
      });
    }
    return rows;
  }

  function reminderRows() {
    const snapshot = window.NRCTasks?.getReminderSnapshot?.();
    const reminders = snapshot?.reminders || [];
    const states = window.NRCTasks?.ReminderState;
    const due = reminders.filter((reminder) => reminder.state === states?.Urgent || reminder.state === states?.Late);
    state.reminders = { due: due.length, total: reminders.length };
    return due.map(reminderRow).sort((left, right) => left.sortKey - right.sortKey);
  }

  // The order follows the same vocabulary as the chips: what is due now, then
  // what has a deadline, then blocked work, then everything else. Sorting by a
  // raw timestamp would put an overdue task behind a task without a due date.
  function urgencyRank(row) {
    if (row.chip.tone === "danger") return 0;
    if (row.chip.tone === "priority" || row.kind === "MENTION") return 1;
    if (row.chip.tone === "blocked") return 2;
    return 3;
  }

  function buildRows() {
    const tasksById = new Map([...state.dependencies, ...state.tasks].map(task => [task.id, task]));
    const dependents = new Map();
    for (const task of state.dependencies) {
      if (!task.blockedBy || task.status === window.NRCTasks?.TaskStatus?.Done) continue;
      if (!dependents.has(task.blockedBy)) dependents.set(task.blockedBy, []);
      dependents.get(task.blockedBy).push(task);
    }
    const rows = [
      ...state.tasks.map(task => taskRow(task, dependents.get(task.id) || [], tasksById.get(task.blockedBy))),
      ...reminderRows(),
      ...messageRows(),
    ].filter((row) => row?.title);
    for (const row of rows) row.key = `${row.kind}:${row.id}`;
    rows.sort((left, right) =>
      REASONS.findIndex(([reason]) => reason === left.reason) -
        REASONS.findIndex(([reason]) => reason === right.reason) ||
      urgencyRank(left) - urgencyRank(right) ||
      left.sortKey - right.sortKey ||
      left.title.localeCompare(right.title));
    state.rows = rows;
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  function render() {
    const body = el("attentionBody");
    if (!body) return; // painting only; the derivation happened in refreshDerived
    // A repaint replaces the rows, so a cursor that stood on one of them is put
    // back where it was: the keyboard must not lose its place because a refresh
    // landed while the reader was walking the register.
    const cursorKey = document.activeElement?.closest?.(".attention-row")?.dataset?.attentionKey ?? null;
    const dependencyFocus = document.activeElement?.matches?.("[data-attention-toggle], [data-attention-task]");
    const expanded = new Set(Array.from(body.querySelectorAll?.(".attention-dependents:not([hidden])") || [], node => node.dataset.dependencyKey));
    const visible = state.rows.filter((row) => state.filter === "all" || row.group === state.filter);
    const countEl = el("attentionCount");
    // The row walk ends on the server's last page, so the header normally states
    // the rows it holds. A walk that stopped early — the cap, or a connection that
    // went away mid-walk — says so instead of looking complete.
    if (countEl) countEl.textContent = `${state.rows.length}${state.hasMoreTasks ? "+" : ""} ITEMS · BY REASON`;
    const dependencyStatus = el("attentionDependencyStatus");
    if (dependencyStatus) {
      dependencyStatus.hidden = !state.dependenciesIncomplete;
      dependencyStatus.textContent = "DEPENDENCY LIST INCOMPLETE · UNBLOCKS COUNTS MAY BE PARTIAL";
    }

    const mine = el("attentionMineCount");
    if (mine) mine.textContent = state.counts.mine;
    const blocked = el("attentionBlockedCount");
    if (blocked) blocked.textContent = `${state.counts.blocked}${state.dependenciesIncomplete ? "+" : ""}`;
    const overdue = el("attentionOverdueCount");
    if (overdue) overdue.textContent = state.counts.overdue;
    const messages = el("attentionMessageCount");
    if (messages) messages.textContent = state.rows.filter((row) => row.group === "message").length;

    document.querySelectorAll("[data-attention-filter]").forEach((button) => {
      const value = button.dataset.attentionFilter;
      const active = value === state.filter;
      const label = button.querySelector("span");
      const count = button.querySelector(".tab-count");
      if (count) {
        count.textContent = value === "all"
          ? state.rows.length
          : state.rows.filter((row) => row.group === value).length;
      }
      if (label) label.textContent = value.toUpperCase();
      button.classList.toggle("active", active);
      button.setAttribute("aria-pressed", String(active));
    });

    if (visible.length === 0) {
      body.innerHTML = `<div class="reminder-empty">${state.rows.length === 0 ? "NOTHING NEEDS ATTENTION" : "NO MATCHING ROWS"}</div>`;
    } else {
      body.innerHTML = `<div class="attention-list-header">
          <span class="attention-marker"></span><span>KIND</span><span>TITLE</span><span>DETAIL</span><span>STATE</span><span>AGE</span>
        </div>` + REASONS.map(([reason, label]) => {
        const rows = visible.filter((row) => row.reason === reason);
        if (!rows.length) return "";
        return `<section class="attention-group" aria-labelledby="attention-reason-${reason}">
          <h3 class="attention-group-heading" id="attention-reason-${reason}">${label}<span>${rows.length} ${rows.length === 1 ? "ITEM" : "ITEMS"}</span></h3>` + rows.map((row) => `
        <div class="attention-row" data-kind="${row.kind.toLowerCase()}" data-attention-key="${escapeHtml(row.key)}">
          <span class="attention-marker" aria-hidden="true">›</span>
          <span class="note-link-kind">${row.kind}</span>
          <button type="button" class="task-row-open attention-title" title="${escapeHtml(row.title)}" aria-label="${escapeHtml(`Open ${row.kind.toLowerCase()} ${row.id}: ${row.title}`)}">${escapeHtml(row.title)}</button>
          <span class="attention-context" title="${escapeHtml(row.detail)}">${row.related?.length ? row.reason === "waiting"
            ? `<button type="button" class="task-row-open attention-context-text" data-attention-task="${row.related[0].id}" title="${escapeHtml(row.related[0].title)}">WAITING ON #${row.related[0].id}</button>`
            : `<button type="button" class="task-row-open attention-context-text" data-attention-toggle aria-expanded="${expanded.has(row.key)}" aria-controls="attention-dependents-${row.id}">${expanded.has(row.key) ? "▾" : "▸"} UNBLOCKS ${row.related.length}${state.dependenciesIncomplete ? "+" : ""} TASK${row.related.length === 1 ? "" : "S"}</button>`
            : `${row.jumpable ? `<span class="attention-jump" title="${escapeHtml(`Opens ${row.detail.split(" · ")[0]} and flashes the message`)}">↦</span>` : ""}<span class="attention-context-text">${escapeHtml(row.detail)}</span>`}</span>
          <span class="attention-state ${TONES[row.chip.tone] || ""}">${escapeHtml(row.chip.label)}</span>
          <span class="attention-age">${escapeHtml(row.age)}</span>
        </div>${row.related?.length && row.reason !== "waiting" ? `<div id="attention-dependents-${row.id}" class="attention-dependents" data-dependency-key="${escapeHtml(row.key)}"${expanded.has(row.key) ? "" : " hidden"}><div>${row.related.map(task => `<button class="btn btn--row" type="button" data-attention-task="${task.id}">#${task.id} · ${escapeHtml(task.title)}${task.assignee ? ` · ${escapeHtml(task.assignee)}` : ""}</button>`).join("")}</div></div>` : ""}`).join("") + "</section>";
      }).join("");
    }

    updateSidebarCount();
    window.NRCInspector?.refreshContext?.();
    if (cursorKey) {
      const opener = Array.from(body.querySelectorAll(".attention-row"))
        .find((row) => row.dataset.attentionKey === cursorKey)
        ?.querySelector(dependencyFocus ? "[data-attention-toggle], [data-attention-task]" : ".attention-title");
      opener?.focus({ preventScroll: true });
    }
  }

  function rowFor(node) {
    const key = node?.dataset?.attentionKey;
    return state.rows.find((row) => row.key === key) || null;
  }

  function activate(node) {
    const row = rowFor(node);
    if (row) row.open();
  }

  // ---------------------------------------------------------------------------
  // Keyboard
  // ---------------------------------------------------------------------------

  // The cursor is the focused row opener, so the register needs no selection of
  // its own: the shared row outline follows the focus, and Enter keeps working
  // because the opener is a button.
  function registerOpeners() {
    return Array.from(document.querySelectorAll("#attentionBody .attention-row .attention-title"));
  }

  function handleKeyboardNavigation(event) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    if (!isActive()) return;
    if (event.defaultPrevented || event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) return;
    const target = event.target;
    if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" ||
      target.tagName === "SELECT" || target.isContentEditable)) return;
    if (target?.closest?.("#inspector, [role=dialog], [role=menu], [role=listbox]")) return;
    if (window.NRCLinksUI?.isPickerVisible?.()) return;

    const openers = registerOpeners();
    if (openers.length === 0) return;
    const navigation = window.NRCListNavigation;
    if (!navigation?.resolveAdjacent) return;
    // The key is carried by the row, the focus by its opener, so the identity is
    // read from the row on both sides of the walk.
    const keyOf = (node) => node?.closest?.(".attention-row")?.dataset?.attentionKey ?? null;
    const adjacent = navigation.resolveAdjacent(
      openers, keyOf(document.activeElement), event.key === "ArrowDown" ? 1 : -1, keyOf,
    );
    event.preventDefault();
    if (adjacent.status !== "target") return;
    adjacent.row.focus({ preventScroll: true });
    adjacent.row.closest(".attention-row")?.scrollIntoView({ block: "nearest" });
  }

  function updateSidebarCount() {
    const badge = el("attentionViewCount");
    if (!badge) return;
    const total = state.rows.length;
    badge.textContent = total > 0 ? String(total).padStart(2, "0") : "";
    badge.hidden = total === 0;
    badge.setAttribute("aria-label", `${total} item${total === 1 ? "" : "s"} need attention`);
  }

  function setFilter(value) {
    if (!FILTERS.includes(value)) return;
    state.filter = value;
    render();
  }

  // ---------------------------------------------------------------------------
  // Refresh
  // ---------------------------------------------------------------------------

  function refreshDerived() {
    buildRows();
    state.mode = "ready";
    // The count is navigation state and has to be right before the view was ever
    // opened — a reload in another view must not hide what is waiting. Only the
    // register itself is painted while it is on screen.
    if (isActive()) render();
    else updateSidebarCount();
  }

  function refresh() {
    state.mode = "loading";
    state.dependenciesIncomplete = true;
    runCountQuery("mine");
  }

  // Work changes arrive in bursts (a drag writes many task updates), so the
  // register coalesces them into one walk of its sources. The walk runs in the
  // background too: it is what keeps the sidebar count current.
  let refreshTimer = null;
  function refreshSoon() {
    if (refreshTimer !== null) return;
    refreshTimer = setTimeout(() => { refreshTimer = null; refresh(); }, REFRESH_DEBOUNCE_MS);
  }

  function handleTaskQueryPage(dataView) {
    if (!countController) return;
    countController.handlePage(dataView);
  }

  function handleTaskProjects(dataView) {
    if (!countController) return;
    countController.handleProjects(dataView);
  }

  // A dropped connection abandons the count walk; the next view entry starts a
  // fresh one instead of answering a request that no longer exists.
  function disconnect() {
    countQuery = null;
    countFilters = null;
    taskPages = 0;
    countController?.disconnect?.();
    countController = null;
    state.dependencies = [];
    state.dependenciesIncomplete = true;
    state.mode = "idle";
  }

  // A reconnect rebuilds the work from the server and the chat unread state is
  // session-scoped, so the register starts a fresh walk for the sidebar count.
  function onSessionStarted() {
    refresh();
  }

  function onViewChanged(view) {
    if (view !== "attention") return;
    refresh();
  }

  function init() {
    document.querySelectorAll("[data-attention-filter]").forEach((button) => {
      button.addEventListener("click", () => setFilter(button.dataset.attentionFilter));
    });
    const body = el("attentionBody");
    if (body) {
      // Activation belongs to the row's opener button: it is the accessible
      // control and handles Enter and Space natively. A second keydown handler
      // here would activate a jump twice and fetch the target page twice.
      body.addEventListener("click", (event) => {
        const toggle = event.target.closest("[data-attention-toggle]");
        if (toggle) {
          const list = el(toggle.getAttribute("aria-controls"));
          list.hidden = !list.hidden;
          toggle.setAttribute("aria-expanded", String(!list.hidden));
          toggle.textContent = `${list.hidden ? "▸" : "▾"}${toggle.textContent.slice(1)}`;
          return;
        }
        const link = event.target.closest("[data-attention-task]");
        if (link) {
          window.NRCInspector?.openEntity?.({ roomId: 0n, type: "task", id: BigInt(link.dataset.attentionTask) });
          return;
        }
        const node = event.target.closest("[data-attention-key]");
        if (node) activate(node);
      });
    }
    document.addEventListener("keydown", handleKeyboardNavigation);
    document.addEventListener("nrc:task-changed", refreshSoon);
    document.addEventListener("nrc:asset-created", refreshSoon);
  }

  function isActive() {
    return window.NRCViewManager?.getActiveView?.() === "attention";
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  return { init, refresh, refreshSoon, render, setFilter, onViewChanged, handleTaskQueryPage,
    handleTaskProjects, disconnect, onSessionStarted, getState: () => state, isActive };
})();
