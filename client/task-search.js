(function () {
  const TASK_SEARCH_DEBOUNCE_MS = 250;
  const TASK_SEARCH_RESULT_LIMIT = 100;

  function taskFiltersForRequest(filters, nickname, nowMs) {
    const task = {
      statuses: filters.status === null ? [0, 1, 2, 3]
        : filters.status === "open" ? [0, 1, 2] : [filters.status],
    };
    if (filters.assignee !== null) {
      task.assignees = [filters.assignee === "me" ? nickname : filters.assignee];
    }
    if (filters.color !== null) task.colors = [filters.color];
    if (filters.project !== null) task.projects = [filters.project];
    if (filters.blocked !== null) task.blocked = filters.blocked;
    if (filters.overdue === true) task.overdue_before = nowMs * 1000000;
    return task;
  }

  function taskFromSearchResult(result, roomId, cachedTask) {
    if (cachedTask) return cachedTask;
    const metadata = result?.metadata?.task;
    if (!metadata || result?.entity?.type !== "task") return null;
    const convId = BigInt(result.entity.conv_id);
    if (convId !== BigInt(roomId)) return null;
    return {
      id: BigInt(result.entity.id),
      convId,
      title: metadata.title || result.preview || `Task #${result.entity.id}`,
      description: "",
      status: metadata.status,
      orderIndex: metadata.order_index || 0,
      assignee: metadata.assignee || "",
      priority: metadata.priority || 0,
      color: metadata.color || 0,
      createdBy: metadata.created_by || "",
      createdAt: BigInt(metadata.created_at || 0),
      updatedAt: BigInt(metadata.updated_at || 0),
      externalRef: metadata.external_ref || "",
      dueAt: BigInt(metadata.due_at || 0),
      blockedBy: BigInt(metadata.blocked_by || 0),
      completedAt: BigInt(metadata.completed_at || 0),
      completedBy: metadata.completed_by || "",
      project: metadata.project || "",
      attachments: [],
      __searchResult: true,
    };
  }

  function createTaskSearchController(options) {
    const now = options.now || Date.now;
    const search = window.NRCSearch.createController(options);
    let state = { mode: "idle", query: "", roomId: null, tasks: new Map(), stale: false, error: null };

    const notify = () => options.onChange?.(state);

    function setFallback(query, roomId, error) {
      state = { mode: "fallback", query, roomId, tasks: new Map(), stale: false, error };
      notify();
    }

    function update({ debounce = false } = {}) {
      search.cancel();
      const query = String(options.getFilters().search || "").trim();
      const roomId = 0n;
      if (!query) {
        state = { mode: "idle", query: "", roomId, tasks: new Map(), stale: false, error: null };
        notify();
        return;
      }
      state = { mode: "loading", query, roomId, tasks: new Map(), stale: false, error: null };
      notify();
      search.search({
        query, top_n: TASK_SEARCH_RESULT_LIMIT,
        filters: { entity_types: ["task"], task: taskFiltersForRequest(options.getFilters(), options.getNickname(), now()) },
      }, {
        debounce: debounce ? TASK_SEARCH_DEBOUNCE_MS : 0,
        onResult: (data) => {
          const loaded = options.getLoadedTasks(roomId) || new Map();
          const tasks = new Map();
          for (const result of data.results) {
            if (result?.entity?.type !== "task") throw new Error("search service returned a non-task result");
            const id = BigInt(result.entity.id);
            const task = taskFromSearchResult(result, roomId, loaded.get(id));
            if (!task) throw new Error("search service returned invalid task metadata");
            tasks.set(task.id, task);
          }
          state = { mode: "results", query, roomId, tasks, stale: data.stale === true, error: null };
          notify();
        },
        onError: (error) => setFallback(query, roomId, error),
      });
    }

    function onDisconnect() {
      const query = String(options.getFilters().search || "").trim();
      const roomId = 0n;
      search.cancel();
      if (query) setFallback(query, roomId, new Error("Task transport disconnected"));
    }

    return {
      update,
      onRoomSwitch: () => update(),
      onReconnect: () => update(),
      onDisconnect,
      cancel: search.cancel,
      getState: () => state,
      getTask: (roomId, taskId) => state.mode === "results" && state.roomId === BigInt(roomId)
        ? state.tasks.get(BigInt(taskId))
        : null,
    };
  }

  window.createTaskSearchController = createTaskSearchController;
  window.NRCTaskSearch = createTaskSearchController({
    fetchImpl: (...args) => fetch(...args),
    getSearchUrl: () => getSearchUrl(),
    getWorkspace: () => currentWorkspaceId,
    getRoomId: () => currentRoomId,
    getNickname: () => myNickname,
    getFilters: () => TaskViewState.filters,
    getLoadedTasks: (roomId) => window.NRCTasks?.roomTasks?.get(BigInt(roomId)),
    onChange: () => {
      if (window.NRCTasks?.isKanbanVisible?.()) renderCurrentTaskView();
    },
  });
})();
