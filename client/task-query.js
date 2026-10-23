// Indexed task pages have their own ordered membership, independent of the
// shared entity cache used by references, graph loading and live updates.
(function () {
  const sorts = ["priority", "status", "assignee", "dueAt", "createdAt", "title", "color", "project", "workOrder"];
  const encoder = new TextEncoder();
  function encodeTaskQuery(query, cursor, correlationId) {
    const assignee = encoder.encode(query.assignee ?? "");
    const project = encoder.encode(query.project ?? "");
    const cursorText = encoder.encode(cursor?.text ?? "");
    const buffer = new ArrayBuffer(54 + assignee.length + project.length + cursorText.length + (query.sliceId ? 8 : 0));
    const view = new DataView(buffer);
    let offset = 0;
    const u8 = (v) => view.setUint8(offset++, v);
    const u16 = (v) => { view.setUint16(offset, v, false); offset += 2; };
    const u64 = (v) => { view.setBigUint64(offset, BigInt(v), false); offset += 8; };
    const i64 = (v) => { view.setBigInt64(offset, BigInt(v), false); offset += 8; };
    const bytes = (v) => { u16(v.length); new Uint8Array(buffer, offset, v.length).set(v); offset += v.length; };
    u16(28); u64(0n); u8(query.statusMask); u16(100);
    u8(sorts.indexOf(query.sort)); u8(query.sort !== "workOrder" && query.descending ? 1 : 0);
    u8(query.color ?? 255); u8(query.blocked === null ? 0 : query.blocked ? 1 : 2);
    i64(query.overdueBefore);
    u8(query.assignee !== null ? 1 : 0); bytes(assignee);
    u8(query.project !== null ? 1 : 0); bytes(project);
    u8(cursor ? 1 : 0); i64(cursor?.number ?? 0); bytes(cursorText); u64(cursor?.taskId ?? 0);
    view.setUint32(offset, correlationId, false);
    offset += 4;
    if (query.sliceId) u64(query.sliceId);
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
    const pageRequests = new Map();
    function requestPage(query, cursor = null) {
      if (!options.isReady()) return Promise.reject(new Error("Offline"));
      return new Promise((resolve, reject) => {
        const correlationId = options.nextId();
        const timer = setTimeout(() => {
          pageRequests.delete(correlationId);
          reject(new Error("Task page timed out"));
        }, 15000);
        pageRequests.set(correlationId, { resolve, reject, timer });
        options.send(encodeTaskQuery({ statusMask: 15, assignee: null, project: null, color: 255,
          blocked: null, overdueBefore: 0n, ...query }, cursor, correlationId));
      });
    }
    const notify = () => options.onChange?.();
    function cancelPage() {
      if (pending) clearTimeout(pending.timer);
      pending = null;
    }
    function currentQuery() {
      const f = options.getFilters();
      return {
        roomId: "0", statusMask: f.status === null ? 15 : f.status === "open" ? 7 : 1 << f.status,
        sort: options.getSort().column,
        descending: options.getSort().column !== "workOrder" && options.getSort().direction === "desc",
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
      const page = window.NRCFrames.decodeTaskQueryPage(view);
      const correlationId = page.correlationId;
      const request = pageRequests.get(correlationId);
      if (!request && (!pending || pending.correlationId !== correlationId)) return;
      const roomId = page.convId;
      if (roomId !== (request ? 0n : pending.target.roomId)) return;
      const target = request ? { tasks: new Map() } : pending.target;
      if (request) { clearTimeout(request.timer); pageRequests.delete(correlationId); }
      else cancelPage();
      if (!page.success) {
        if (request) { request.reject(new Error(page.error || "Task query failed")); return; }
        target.mode = "error"; target.error = page.error; notify(); return;
      }
      for (const task of page.tasks) target.tasks.set(task.id, task);
      options.cacheTasks(roomId, page.tasks, { scopedPage: Boolean(request) });
      Object.assign(target, {
        mode: "results",
        hasMore: page.hasMore,
        total: page.totalCount,
        cursor: {
          number: page.nextCursorNumber,
          text: page.nextCursorText,
          taskId: page.nextCursorTaskId,
        },
      });
      if (request) { request.resolve({ tasks: page.tasks, hasMore: page.hasMore, total: page.totalCount, cursor: target.cursor }); return; }
      notify();
    }
    function handleProjects(view) {
      const page = window.NRCFrames.decodeStringList(view);
      const correlationId = page.correlationId;
      const roomId = page.convId;
      if (projectRequest?.correlationId !== correlationId || projectRequest.roomId !== roomId) return;
      projectRequest.values.push(...page.values);
      if (page.hasMore) return;
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
      const page = window.NRCFrames.decodeStringList(view);
      if (!assigneeRequest || page.convId !== 0n || page.correlationId !== assigneeRequest.correlationId) return;
      assigneeRequest.values.push(...page.values);
      if (page.hasMore) return;
      assignees = assigneeRequest.values;
      clearTimeout(assigneeRequest.timer); assigneeRequest = null;
      options.onAssignees();
    }
    function disconnect() {
      for (const request of pageRequests.values()) {
        clearTimeout(request.timer); request.reject(new Error("Task query reset"));
      }
      pageRequests.clear();
      if (assigneeRequest) clearTimeout(assigneeRequest.timer);
      assigneeRequest = null; assignees = null;
      if (projectRequest) clearTimeout(projectRequest.timer);
      projectRoom = null;
      clearTimeout(refreshTimer); cancelPage(); projectRequest = null; projects.clear(); signature = null;
      state = { mode: "idle", roomId: null, tasks: new Map(), hasMore: false, total: 0 };
    }
    return { update, loadMore, requestPage, afterMutation, handlePage, handleProjects, handleAssignees, disconnect,
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
    cacheTasks: (roomId, tasks, { scopedPage = false } = {}) => {
      if (!roomTasks.has(roomId)) roomTasks.set(roomId, new Map());
      for (const task of tasks) roomTasks.get(roomId).set(task.id, task);
      // A slice reading its own page is not a mutation. Invalidating slices
      // here would request another page forever and discard LOAD MORE results.
      if (scopedPage) taskListDirty = true;
      else invalidateTaskList(roomId);
    },
    onProjects: () => populateProjectFilter(),
    onAssignees: () => populateAssigneeFilter(),
    onChange: () => {
      invalidateTaskList(0n);
      if (window.NRCTasks?.isKanbanVisible?.()) renderCurrentTaskView();
    },
  });
})();
