// WHEN: workspace deadlines, independent of personal attention reasons.
window.NRCCalendar = (() => {
  const el = id => document.getElementById(id);
  const escape = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const pad = value => String(value).padStart(2, "0");
  const dayKey = date => `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  const dayDate = day => new Date(`${day}T12:00:00`);
  function monthDays(month) {
    const first = dayDate(`${month}-01`);
    const start = new Date(first);
    start.setDate(1 - (first.getDay() + 6) % 7);
    const last = new Date(first.getFullYear(), first.getMonth() + 1, 0, 12);
    const count = Math.ceil(((first.getDay() + 6) % 7 + last.getDate()) / 7) * 7;
    return Array.from({ length: count }, (_, index) => {
      const date = new Date(start);
      date.setDate(start.getDate() + index);
      return dayKey(date);
    });
  }
  const today = () => dayKey(new Date());
  const state = { month: today().slice(0, 7), day: today(), mode: "agenda", person: "", project: "",
    rows: [], status: "idle" };
  let query = null, timer = null, pending = null, loaded = [];
  let waitingFor = new Set();
  let rendered = false;
  const encoder = new TextEncoder(), decoder = new TextDecoder("utf-8", { ignoreBOM: true });
  const active = () => window.NRCViewManager?.getActiveView?.() === "calendar";
  const ready = () => typeof serverReady !== "undefined" && serverReady && typeof ws !== "undefined" && ws?.readyState === WebSocket.OPEN;
  function visibleRange(month = state.month, mode = state.mode) {
    const days = monthDays(month);
    const start = new Date(`${mode === "month" ? days[0] : `${month}-01`}T00:00:00`);
    const end = mode === "month" ? new Date(`${days.at(-1)}T00:00:00`) : new Date(`${month}-01T00:00:00`);
    if (mode === "month") end.setDate(end.getDate() + 1);
    else end.setMonth(end.getMonth() + 1);
    return { start: BigInt(start.getTime()) * 1000000n, end: BigInt(end.getTime()) * 1000000n };
  }
  function controller() {
    if (query) return query;
    query = window.createTaskQueryController({
      getNickname: () => myNickname, isReady: ready,
      nextId: () => getRpcCorrelationId(), send: buffer => sendPacket(buffer),
      onProjects: () => complete("projects"), onAssignees: () => complete("assignees"),
      onMetadataError: () => { state.status = "error"; render(); },
    });
    return query;
  }
  function complete(part) {
    if (state.status !== "loading") return;
    waitingFor.delete(part);
    if (!waitingFor.size) { state.rows = loaded; state.status = "ready"; }
    render();
  }
  function encodeRequest(range, person, projectName, cursor, id) {
    const assignee = encoder.encode(person);
    const project = encoder.encode(projectName);
    const buffer = new ArrayBuffer(54 + assignee.length + project.length), view = new DataView(buffer);
    view.setUint16(0, 58); view.setBigUint64(2, 0n);
    view.setBigInt64(10, range.start); view.setBigInt64(18, range.end); view.setUint16(26, 100);
    view.setUint8(28, cursor ? 1 : 0); view.setBigInt64(29, cursor?.at ?? 0n);
    view.setUint8(37, cursor?.kind ?? 0); view.setBigUint64(38, cursor?.id ?? 0n);
    let offset = 46;
    for (const bytes of [assignee, project]) {
      view.setUint16(offset, bytes.length); offset += 2;
      new Uint8Array(buffer, offset, bytes.length).set(bytes); offset += bytes.length;
    }
    view.setUint32(offset, id);
    return buffer;
  }
  function decodePage(view) {
    const count = view.getUint16(10), more = view.getUint8(12) === 1;
    const cursor = { at: view.getBigInt64(13), kind: view.getUint8(21), id: view.getBigUint64(22) };
    const rows = [];
    let offset = 30;
    const text = () => { const size = view.getUint16(offset); offset += 2;
      const value = decoder.decode(new Uint8Array(view.buffer, view.byteOffset + offset, size)); offset += size; return value; };
    for (let i = 0; i < count; i++) {
      const wireKind = view.getUint8(offset++);
      const kind = wireKind === 0 ? "task" : wireKind === 1 ? "reminder" : "appointment";
      const id = view.getBigUint64(offset); offset += 8;
      const at = view.getBigInt64(offset); offset += 8;
      const blocked = view.getUint8(offset++) === 1;
      const title = text(), assignee = text(), project = text();
      const actualStartAt = wireKind === 2 ? view.getBigInt64(offset) : at;
      if (wireKind === 2) offset += 8;
      const endAt = wireKind === 2 ? view.getBigInt64(offset) : 0n;
      if (wireKind === 2) offset += 8;
      const date = new Date(Number(actualStartAt / 1000000n));
      rows.push({ id, kind, at, actualStartAt, endAt, blocked, title, assignee, project, key: `${kind}:${id}`,
        day: dayKey(new Date(Number(at / 1000000n))), time: `${pad(date.getHours())}:${pad(date.getMinutes())}` });
    }
    return { rows, more, cursor };
  }
  function requestPage(cursor = null) {
    const id = getRpcCorrelationId();
    if (pending) clearTimeout(pending.timeout);
    pending = { id, cursor, timeout: setTimeout(() => { pending = null; state.status = "error"; render(); }, 15000) };
    sendPacket(encodeRequest(visibleRange(), state.person === "me" ? myNickname : state.person, state.project, cursor, id));
  }
  function handlePage(view) {
    if (!pending || view.getUint32(view.byteLength - 4) !== pending.id) return;
    clearTimeout(pending.timeout);
    const previous = pending.cursor; pending = null;
    const { rows, more, cursor } = decodePage(view);
    loaded.push(...rows);
    if (more) {
      if (!rows.length || previous && previous.at === cursor.at && previous.kind === cursor.kind && previous.id === cursor.id) {
        state.status = "error"; render(); return;
      }
      requestPage(cursor); return;
    }
    complete("rows");
  }
  function refresh() {
    if (!active()) return;
    if (!ready()) { state.status = "offline"; render(); return; }
    state.status = "loading";
    waitingFor = new Set(["rows", "projects", "assignees"]);
    loaded = [];
    render();
    controller().requestMetadata();
    requestPage();
  }
  function refreshSoon() {
    if (!active() || timer !== null) return;
    timer = setTimeout(() => { timer = null; refresh(); }, 400);
  }
  function disconnect() {
    if (pending) clearTimeout(pending.timeout);
    pending = null; loaded = [];
    clearTimeout(timer); timer = null;
    query?.disconnect();
    state.rows = []; state.status = "offline";
    render();
  }
  function dateLabel(day) {
    return new Intl.DateTimeFormat(undefined, { weekday: "short", day: "numeric", month: "short", year: "numeric" }).format(dayDate(day));
  }
  function rowMarkup(rows) {
    return rows.length ? rows.map(row => `<div class="calendar-row" data-calendar-row="${row.key}">
      <span class="note-link-kind">${row.kind.toUpperCase()}</span>
      <button type="button" class="task-row-open" data-calendar-record="${row.key}" title="${escape(row.title)}">${escape(row.title)}</button>
      <time datetime="${new Date(Number(row.actualStartAt / 1000000n)).toISOString()}">${escape(timeLabel(row))}</time>
      <span class="calendar-owner" title="${escape(row.assignee)}">${escape(row.assignee || "—")}</span>
      <span class="calendar-project" title="${escape(row.project)}">${escape(row.project || "—")}</span>
      <span class="calendar-state">${row.blocked ? "BLOCKED" : ""}</span>
    </div>`).join("") : '<div class="reminder-empty">NO DATED WORK</div>';
  }
  function group(day, rows) {
    return `<section class="calendar-day-list" aria-label="${escape(dateLabel(day))}"><h3 class="attention-group-heading">${escape(dateLabel(day))}${day === today() ? " / TODAY" : ""}<span>${rows.length} ITEMS</span></h3>${rowMarkup(rows)}</section>`;
  }
  const columnHeader = '<div class="calendar-row calendar-column-header"><span class="note-link-kind">KIND</span><span class="calendar-title">TITLE</span><span class="calendar-time">TIME</span><span class="calendar-owner">ASSIGNEE</span><span class="calendar-project">PROJECT</span><span class="calendar-state">STATE</span></div>';
  function timeLabel(row) {
    if (row.kind !== "appointment") return row.time;
    const start = new Date(Number(row.actualStartAt / 1000000n));
    const startText = `${pad(start.getHours())}:${pad(start.getMinutes())}`;
    if (!row.endAt) return startText;
    const end = new Date(Number(row.endAt / 1000000n));
    const endText = `${pad(end.getHours())}:${pad(end.getMinutes())}`;
    return dayKey(start) === dayKey(end) ? `${startText}–${endText}` : `${dayKey(start)} ${startText}–${dayKey(end)} ${endText}`;
  }
  function occursOnDay(row, day) {
    if (row.kind !== "appointment") return row.day === day;
    const start = BigInt(new Date(`${day}T00:00:00`).getTime()) * 1000000n;
    const next = new Date(`${day}T00:00:00`); next.setDate(next.getDate() + 1);
    const end = BigInt(next.getTime()) * 1000000n;
    return row.actualStartAt < end && (row.endAt === 0n ? row.actualStartAt >= start : row.endAt > start);
  }
  function options(id, values, selected) {
    const select = el(id);
    const assignee = id === "calendarPerson";
    const choices = [...new Set([...values.filter(Boolean), ...(selected ? [selected] : [])])]
      .filter(value => !assignee || (value !== myNickname && value !== "me")).sort();
    select.innerHTML = '<option value="">ALL</option>' + (assignee ? '<option value="me">MINE</option>' : "") + choices.map(value => `<option value="${escape(value)}">${escape(value)}</option>`).join("");
    select.value = selected;
  }
  function render() {
    const body = el("calendarBody");
    if (!body || !active()) return;
    const loading = state.status === "loading";
    body.inert = loading;
    body.setAttribute("aria-busy", String(loading));
    body.hidden = (loading || state.status === "error") && !rendered;
    if (el("calendarControls")) {
      el("calendarControls").inert = loading;
      el("calendarControls").hidden = (loading || state.status === "error") && !rendered;
    }
    el("calendarStatus").textContent = loading ? "LOADING WORKSPACE DEADLINES…" :
      state.status === "error" ? "DEADLINE READ FAILED · SHOWING LAST COMPLETE RESULTS · RETRY" :
      state.status === "offline" ? "OFFLINE · RECONNECT TO LOAD DEADLINES" :
      "";
    el("calendarStatus").hidden = !el("calendarStatus").textContent;
    // Keep the last complete calendar intact while its rows and both metadata
    // lists are being replaced. A failed refresh also leaves that usable
    // snapshot in place rather than drawing a mixture of old and new data.
    if (loading || state.status === "error") return;
    const focus = document.activeElement;
    const focusDay = focus?.dataset?.calendarDay;
    const focusRecord = focus?.dataset?.calendarRecord;
    const person = state.person === "me" ? myNickname : state.person;
    const filtered = state.rows.filter(row => (!state.person || (row.kind !== "reminder" && person && row.assignee === person)) &&
      (!state.project || row.project === state.project));
    const monthRange = visibleRange(state.month, "agenda");
    const monthRows = filtered.filter(row => row.kind === "appointment"
      ? row.actualStartAt < monthRange.end && (row.endAt === 0n ? row.actualStartAt >= monthRange.start : row.endAt > monthRange.start)
      : row.day.startsWith(state.month));
    el("calendarRange").textContent = new Intl.DateTimeFormat(undefined, { month: "long", year: "numeric" }).format(dayDate(`${state.month}-01`)).toUpperCase();
    el("calendarCount").textContent = `${monthRows.length} ITEMS`;
    el("calendarContext").textContent = `WHEN · OPEN TASKS, APPOINTMENTS & REMINDER DEADLINES · ${Intl.DateTimeFormat().resolvedOptions().timeZone}${state.person || state.project ? " · FILTERS EXCLUDE REMINDERS" : ""}`;
    options("calendarPerson", [...(query?.getAssignees() || []), ...state.rows.filter(row => row.kind === "appointment").map(row => row.assignee)], state.person);
    options("calendarProject", [...(query?.getProjects(0n) || []), ...state.rows.filter(row => row.kind === "appointment").map(row => row.project)], state.project);
    document.querySelectorAll("[data-calendar-mode]").forEach(button => {
      button.classList.toggle("active", button.dataset.calendarMode === state.mode);
      button.setAttribute("aria-pressed", String(button.dataset.calendarMode === state.mode));
    });
    if (state.mode === "agenda") {
      const days = [...new Set(monthRows.map(row => row.day))];
      body.innerHTML = days.length ? columnHeader + days.map(day => group(day, monthRows.filter(row => row.day === day))).join("") :
        `<div class="reminder-empty">${state.status === "ready" ? "NO DATED WORK IN THIS MONTH FOR THESE FILTERS" : "WAITING FOR WORKSPACE DEADLINES"}</div>`;
    } else {
      body.innerHTML = `<div class="calendar-grid" aria-label="Month dates">${["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"].map(day => `<span class="calendar-weekday">${day}</span>`).join("")}${monthDays(state.month).map(day => {
        const rows = filtered.filter(row => occursOnDay(row, day));
        return `<button type="button" class="calendar-date${day.startsWith(state.month) ? "" : " calendar-outside"}" data-calendar-day="${day}" aria-pressed="${day === state.day}"${day === today() ? ' aria-current="date"' : ""} aria-label="${escape(dateLabel(day))}, ${rows.length} items"><b>${Number(day.slice(-2))}</b>${rows.slice(0, 2).map(row => `<span class="calendar-preview">${escape(row.title)}</span>`).join("")}<small>${rows.length ? `${rows.length} ITEMS` : ""}</small></button>`;
      }).join("")}</div>${columnHeader}${group(state.day, filtered.filter(row => occursOnDay(row, state.day)))}`;
    }
    if (focusDay || focusRecord) Array.from(body.querySelectorAll("button")).find(button =>
      focusDay ? button.dataset.calendarDay === focusDay : button.dataset.calendarRecord === focusRecord)?.focus({ preventScroll: true });
    if (state.status === "ready") rendered = true;
  }
  function init() {
    el("calendarPanel").addEventListener("click", event => {
      const record = event.target.closest("[data-calendar-row]");
      if (record) {
        const row = state.rows.find(row => row.key === record.dataset.calendarRow);
        if (row) window.NRCInspector?.openEntity({ roomId: 0n, type: row.kind, id: row.id });
        return;
      }
      const button = event.target.closest("button");
      if (!button) return;
      if (button.dataset.calendarDay) state.day = button.dataset.calendarDay;
      else if (button.dataset.calendarMode) state.mode = button.dataset.calendarMode;
      else if (button.id === "calendarToday") { state.day = today(); state.month = state.day.slice(0, 7); }
      else if (button.id === "calendarPrev" || button.id === "calendarNext") {
        const date = dayDate(`${state.month}-01`);
        date.setMonth(date.getMonth() + (button.id === "calendarPrev" ? -1 : 1));
        state.month = dayKey(date).slice(0, 7); state.day = `${state.month}-01`;
      } else if (button.id === "calendarRefresh") { refresh(); return; }
      else if (button.id === "calendarAddAppointment") { window.NRCAppointments?.create?.(); return; }
      else return;
      if (button.dataset.calendarDay) render();
      else refresh();
    });
    for (const [id, field] of [["calendarPerson", "person"], ["calendarProject", "project"]]) {
      el(id).addEventListener("change", event => { state[field] = event.target.value; refresh(); });
    }
    document.addEventListener("nrc:task-changed", refreshSoon);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) refreshSoon(); });
  }
  return { init, refresh, refreshSoon, disconnect, render, onViewChanged: view => { if (view === "calendar") refresh(); },
    handlePage, handleTaskProjects: view => query?.handleProjects(view), handleTaskAssignees: view => query?.handleAssignees(view),
    getState: () => state, dayKey, monthDays, visibleRange, occursOnDay, timeLabel, encodeRequest, decodePage };
})();
