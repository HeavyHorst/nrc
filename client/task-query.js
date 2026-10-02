// Indexed task pages have their own ordered membership, independent of the
// shared entity cache used by references, graph loading and live updates.
(function () {
  const sorts = ["priority", "status", "assignee", "dueAt", "createdAt", "title", "color", "project"];
  const encoder = new TextEncoder();
  const decoder = new TextDecoder("utf-8", { ignoreBOM: true });
  function readQueryString(view, offset) {
    const length = view.getUint16(offset, false);
    return { value: decoder.decode(new Uint8Array(view.buffer, view.byteOffset + offset + 2, length)), newOffset: offset + 2 + length };
  }

  function encodeTaskQuery(query, cursor, correlationId) {
    const assignee = encoder.encode(query.assignee ?? "");
    const project = encoder.encode(query.project ?? "");
    const cursorText = encoder.encode(cursor?.text ?? "");
    const buffer = new ArrayBuffer(54 + assignee.length + project.length + cursorText.length);
    const view = new DataView(buffer);
    let offset = 0;
    const u8 = (v) => view.setUint8(offset++, v);
    const u16 = (v) => { view.setUint16(offset, v, false); offset += 2; };
    const u64 = (v) => { view.setBigUint64(offset, BigInt(v), false); offset += 8; };
    const i64 = (v) => { view.setBigInt64(offset, BigInt(v), false); offset += 8; };
    const bytes = (v) => { u16(v.length); new Uint8Array(buffer, offset, v.length).set(v); offset += v.length; };
    u16(28); u64(0n); u8(query.statusMask); u16(100);
    u8(sorts.indexOf(query.sort)); u8(query.descending ? 1 : 0);
    u8(query.color ?? 255); u8(query.blocked === null ? 0 : query.blocked ? 1 : 2);
    i64(query.overdueBefore);
    u8(query.assignee !== null ? 1 : 0); bytes(assignee);
    u8(query.project !== null ? 1 : 0); bytes(project);
    u8(cursor ? 1 : 0); i64(cursor?.number ?? 0); bytes(cursorText); u64(cursor?.taskId ?? 0);
    view.setUint32(offset, correlationId, false);
    return buffer;
  }

  function createTaskQueryController(options) {
    let state = { mode: "idle", roomId: null, tasks: new Map(), hasMore: false, total: 0 };
    let signature = null;
    let pending = null;
    let projectRequest = null;
    let projectRoom = null;
    let assigneeRequest = null;
    let assignees = null;
    let refreshTimer = null;
    const projects = new Map();
    const notify = () => options.onChange?.();
    function cancelPage() {
      if (pending) clearTimeout(pending.timer);
      pending = null;
    }
    function currentQuery() {
      const f = options.getFilters();
      return {
        roomId: "0", statusMask: f.status === null ? 15 : f.status === "open" ? 7 : 1 << f.status,
        sort: options.getSort().column, descending: options.getSort().direction === "desc",
        assignee: f.assignee === "me" ? options.getNickname() : f.assignee,
        project: f.project, color: f.color, blocked: f.blocked, overdue: f.overdue === true,
      };
    }
    function requestProjects({ force = false } = {}) {
      if (!options.isReady()) return;
      const roomId = 0n;
      if (!force && projectRoom === roomId) return;
      if (projectRequest) clearTimeout(projectRequest.timer);
      projectRoom = roomId;
      const correlationId = options.nextId();
      const buffer = new ArrayBuffer(14);
      const view = new DataView(buffer);
      view.setUint16(0, 29, false); view.setBigUint64(2, roomId, false); view.setUint32(10, correlationId, false);
      const timer = setTimeout(() => {
        if (projectRequest?.correlationId !== correlationId) return;
        projectRequest = null; projectRoom = null;
        options.onMetadataError?.();
      }, 15000);
      projectRequest = { roomId, correlationId, values: [], timer };
      options.send(buffer);
    }
    function loadMore() {
      if (pending || !options.isReady() || !state.query || (state.mode === "results" && !state.hasMore)) return;
      const target = state;
      const correlationId = options.nextId();
      const timer = setTimeout(() => {
        if (pending?.correlationId !== correlationId) return;
        pending = null; target.mode = "error"; notify();
      }, 15000);
      pending = { correlationId, target, timer };
      state.mode = "loading";
      options.send(encodeTaskQuery(state.query, state.cursor, correlationId));
      notify();
    }
    function update({ force = false } = {}) {
      requestProjects({ force });
      requestAssignees({ force });
      if (options.getFilters().search || !options.isReady()) {
        clearTimeout(refreshTimer);
        cancelPage(); signature = null;
        if (state.mode === "idle") return;
        state = { mode: "idle", roomId: null, tasks: new Map(), hasMore: false, total: 0 };
        notify(); return;
      }
      const query = currentQuery();
      const nextSignature = JSON.stringify(query);
      if (!force && signature === nextSignature) return;
      clearTimeout(refreshTimer);
      cancelPage(); signature = nextSignature;
      query.overdueBefore = query.overdue ? BigInt(Date.now()) * 1000000n : 0n;
      state = { mode: "loading", roomId: BigInt(query.roomId), query, tasks: new Map(), cursor: null, hasMore: true, total: 0 };
      loadMore();
    }
    function afterMutation(roomId) {
      if (BigInt(roomId) !== 0n) return;
      // Invalidate immediately: an intervening filter/search update may consume
      // this refresh before the debounce expires, but must not discard it.
      projectRoom = null;
      assignees = null;
      if (assigneeRequest) clearTimeout(assigneeRequest.timer);
      assigneeRequest = null;
      signature = null;
      clearTimeout(refreshTimer);
      refreshTimer = setTimeout(() => update(), 100);
    }
    function handlePage(view) {
      // Correlation is the final field, so superseded pages need not be parsed
      // and cannot overwrite newer entities in the shared cache either.
      const correlationId = view.getUint32(view.byteLength - 4, false);
      if (!pending || pending.correlationId !== correlationId) return;
      const roomId = view.getBigUint64(2, false);
      if (roomId !== pending.target.roomId) return;
      const target = pending.target;
      cancelPage();
      let offset = 11;
      const count = view.getUint16(offset, false); offset += 2;
      const loaded = [];
      for (let i = 0; i < count; i++) {
        const parsed = options.parseTask(view, offset);
        loaded.push(parsed.task); offset = parsed.newOffset;
      }
      const hasMore = view.getUint8(offset++) === 1;
      const number = view.getBigInt64(offset, false); offset += 8;
      const taskId = view.getBigUint64(offset, false); offset += 8;
      const text = readQueryString(view, offset); offset = text.newOffset;
      const total = view.getUint32(offset, false); offset += 4;
      const error = readQueryString(view, offset);
      if (!view.getUint8(10)) { target.mode = "error"; target.error = error.value; notify(); return; }
      for (const task of loaded) target.tasks.set(task.id, task);
      options.cacheTasks(roomId, loaded);
      Object.assign(target, { mode: "results", hasMore, total, cursor: { number, text: text.value, taskId } });
      notify();
    }
    function handleProjects(view) {
      const correlationId = view.getUint32(view.byteLength - 4, false);
      const roomId = view.getBigUint64(2, false);
      if (projectRequest?.correlationId !== correlationId || projectRequest.roomId !== roomId) return;
      const count = view.getUint16(10, false);
      let offset = 12;
      for (let i = 0; i < count; i++) {
        const parsed = readQueryString(view, offset); projectRequest.values.push(parsed.value); offset = parsed.newOffset;
      }
      if (view.getUint8(offset) === 1) return;
      projects.set(roomId, projectRequest.values);
      clearTimeout(projectRequest.timer);
      projectRequest = null;
      options.onProjects?.();
    }
    function requestAssignees({ force = false } = {}) {
      if (!options.onAssignees || !options.isReady() || (!force && (assignees !== null || assigneeRequest))) return;
      if (assigneeRequest) clearTimeout(assigneeRequest.timer);
      const correlationId = options.nextId();
      const buffer = new ArrayBuffer(14);
      const view = new DataView(buffer);
      view.setUint16(0, 57, false); view.setBigUint64(2, 0n, false); view.setUint32(10, correlationId, false);
      const timer = setTimeout(() => { assigneeRequest = null; options.onMetadataError?.(); }, 15000);
      assigneeRequest = { correlationId, values: [], timer };
      options.send(buffer);
    }
    function handleAssignees(view) {
      if (!assigneeRequest || view.getBigUint64(2, false) !== 0n ||
          view.getUint32(view.byteLength - 4, false) !== assigneeRequest.correlationId) return;
      const count = view.getUint16(10, false);
      let offset = 12;
      for (let i = 0; i < count; i++) {
        const parsed = readQueryString(view, offset);
        assigneeRequest.values.push(parsed.value); offset = parsed.newOffset;
      }
      if (view.getUint8(offset) === 1) return;
      assignees = assigneeRequest.values;
      clearTimeout(assigneeRequest.timer); assigneeRequest = null;
      options.onAssignees();
    }
    function disconnect() {
      if (assigneeRequest) clearTimeout(assigneeRequest.timer);
      assigneeRequest = null; assignees = null;
      if (projectRequest) clearTimeout(projectRequest.timer);
      projectRoom = null;
      clearTimeout(refreshTimer); cancelPage(); projectRequest = null; projects.clear(); signature = null;
      state = { mode: "idle", roomId: null, tasks: new Map(), hasMore: false, total: 0 };
    }
    return { update, loadMore, afterMutation, handlePage, handleProjects, handleAssignees, disconnect,
      requestMetadata: () => { requestProjects({ force: true }); requestAssignees({ force: true }); },
      getAssignees: () => assignees || [],
      getState: () => state, getProjects: (roomId) => projects.get(BigInt(roomId)) };
  }

  window.createTaskQueryController = createTaskQueryController;
  window.encodeTaskQuery = encodeTaskQuery;
  window.NRCTaskQuery = createTaskQueryController({
    getRoomId: () => currentRoomId,
    getFilters: () => TaskViewState.filters,
    getSort: () => ({ column: TaskViewState.sortColumn, direction: TaskViewState.sortDirection }),
    getNickname: () => myNickname,
    isReady: () => typeof serverReady !== "undefined" && serverReady && ws?.readyState === WebSocket.OPEN,
    nextId: () => getRpcCorrelationId(),
    send: (buffer) => { ws.send(buffer); localPacketsOut++; },
    parseTask: (view, offset) => parseTask(view, offset),
    cacheTasks: (roomId, tasks) => {
      if (!roomTasks.has(roomId)) roomTasks.set(roomId, new Map());
      for (const task of tasks) roomTasks.get(roomId).set(task.id, task);
      invalidateTaskList(roomId);
    },
    onProjects: () => populateProjectFilter(),
    onAssignees: () => populateAssigneeFilter(),
    onChange: () => {
      invalidateTaskList(0n);
      if (window.NRCTasks?.isKanbanVisible?.()) renderCurrentTaskView();
    },
  });
})();
