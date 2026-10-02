// =============================================================================
// NRC TASK VIEW STATE MANAGEMENT
// =============================================================================
// Centralized state for task filtering, sorting, and view mode.
// Both Kanban and List views consume this state.

const TaskViewState = {
  sortColumn: "priority", // 'priority' | 'status' | 'assignee' | 'dueAt' | 'createdAt' | 'title'
  sortDirection: "desc", // 'asc' | 'desc'
  // Slices are the primary read: one row per work stream, with the flat task
  // register one toggle away for finding a single task.
  grouping: "slices", // 'slices' | 'flat'
  filters: {
    status: "open", // null = all, 'open' = active, 0-3 = specific status
    assignee: null, // null = all, 'me' = current user, string = specific user
    blocked: null, // null = all, true = blocked only, false = not blocked
    overdue: null, // null = all, true = overdue only
    hideLockedReminders: false, // false = show all reminders, true = hide LOCKED reminders
    reminderView: "all", // all | today | upcoming | overdue
    search: "", // text search in title/description
    color: null, // null = all, 0-5 = specific category
    project: null, // null = all, string = selected project
  },
};

// =============================================================================
// FILTERING
// =============================================================================

function getFilteredTasks(tasksMap, { applyTextSearch = true } = {}) {
  if (!tasksMap || tasksMap.size === 0) return [];

  const tasks = Array.from(tasksMap.values());
  const f = TaskViewState.filters;

  return tasks.filter((task) => {
    // Exclude notes (status=4) from kanban/list view - notes have their own view
    if (task.status === 4) return false;

    if (f.status === "open" && task.status === 3) return false;

    // Status filter
    if (typeof f.status === "number" && task.status !== f.status) return false;

    // Assignee filter
    if (f.assignee !== null) {
      if (f.assignee === "me") {
        if (task.assignee !== myNickname) return false;
      } else if (task.assignee !== f.assignee) {
        return false;
      }
    }

    // Blocked filter
    if (f.blocked === true) {
      if (!task.blockedBy || task.blockedBy === 0n) return false;
    } else if (f.blocked === false) {
      if (task.blockedBy && task.blockedBy !== 0n) return false;
    }

    // Overdue filter
    if (f.overdue === true && !isTaskOverdue(task)) return false;

    // Color/category filter
    if (f.color !== null && task.color !== f.color) return false;

    // Project filter
    if (f.project !== null && (task.project || "") !== f.project) return false;

    // Text search
    if (applyTextSearch && f.search && f.search.length > 0) {
      const searchLower = f.search.toLowerCase();
      const titleMatch =
        task.title && task.title.toLowerCase().includes(searchLower);
      const descMatch =
        task.description &&
        task.description.toLowerCase().includes(searchLower);
      const projectMatch =
        task.project && task.project.toLowerCase().includes(searchLower);
      if (!titleMatch && !descMatch && !projectMatch) return false;
    }

    return true;
  });
}

// =============================================================================
// SORTING
// =============================================================================

function getSortedTasks(tasks) {
  if (!tasks || tasks.length === 0) return [];

  const col = TaskViewState.sortColumn;
  const dir = TaskViewState.sortDirection === "asc" ? 1 : -1;

  return [...tasks].sort((a, b) => {
    let cmp = 0;

    switch (col) {
      case "priority":
        cmp = (a.priority || 0) - (b.priority || 0);
        break;
      case "status":
        cmp = (a.status || 0) - (b.status || 0);
        break;
      case "assignee":
        cmp = (a.assignee || "").localeCompare(b.assignee || "");
        break;
      case "project":
        cmp = (a.project || "").localeCompare(b.project || "");
        break;
      case "dueAt":
        // Tasks without due date go to end
        const aDue = a.dueAt || 0n;
        const bDue = b.dueAt || 0n;
        if (aDue === 0n && bDue === 0n) cmp = 0;
        else if (aDue === 0n) return 1;
        else if (bDue === 0n) return -1;
        else cmp = aDue < bDue ? -1 : aDue > bDue ? 1 : 0;
        break;
      case "createdAt":
        cmp =
          a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0;
        break;
      case "title":
        cmp = (a.title || "").localeCompare(b.title || "");
        break;
      case "color":
        cmp = (a.color || 0) - (b.color || 0);
        break;
      default:
        cmp = 0;
    }

    if (cmp !== 0) return cmp * dir;
    if (a.convId !== b.convId) return a.convId < b.convId ? -1 : 1;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
}

function toggleSort(column) {
  if (TaskViewState.sortColumn === column) {
    TaskViewState.sortDirection =
      TaskViewState.sortDirection === "asc" ? "desc" : "asc";
  } else {
    TaskViewState.sortColumn = column;
    TaskViewState.sortDirection = column === "priority" ? "desc" : "asc";
  }
  saveViewState();
  window.NRCTaskQuery?.update();
  renderCurrentTaskView();
}

// =============================================================================
// VIEW MODE
// =============================================================================

function renderCurrentTaskView() {
  const slices = TaskViewState.grouping === "slices" && window.NRCSlices;
  const listView = document.getElementById("taskListView");
  const sliceView = document.getElementById("sliceView");
  if (listView) listView.style.display = slices ? "none" : "block";
  if (sliceView) sliceView.style.display = slices ? "flex" : "none";
  if (slices) {
    window.NRCSlices.ensureLoaded();
    window.NRCSlices.render();
  } else {
    renderTaskList();
  }
  if (window.NRCTasks && window.NRCTasks.renderReminderQueue) {
    window.NRCTasks.renderReminderQueue();
  }
}

function setTaskGrouping(grouping) {
  const next = grouping === "flat" ? "flat" : "slices";
  if (TaskViewState.grouping === next) return;
  TaskViewState.grouping = next;
  saveViewState();
  syncGroupingTabs();
  if (next === "flat") window.NRCTaskQuery?.update({ force: true });
  renderCurrentTaskView();
}

function syncGroupingTabs() {
  document.querySelectorAll("[data-task-grouping]").forEach((button) => {
    const isActive = button.dataset.taskGrouping === TaskViewState.grouping;
    button.classList.toggle("active", isActive);
    button.setAttribute("aria-pressed", String(isActive));
  });
  const slices = TaskViewState.grouping === "slices";
  // The GROUP toggle swaps the flat-list filters for the slice filters. The cells
  // stay direct children of the register's scroll row, so the shared
  // header-register rules keep matching them in both groupings; the marker is
  // what the swap reads.
  document.querySelectorAll("[data-slice-filter]").forEach((cell) => { cell.hidden = !slices; });
  const filterBar = document.getElementById("taskFilterBar");
  if (filterBar) filterBar.classList.toggle("task-grouping-slices", slices);
  const sliceCount = document.getElementById("sliceResultsCount");
  if (sliceCount) sliceCount.hidden = !slices;
  const flatCount = document.getElementById("taskResultsCount");
  if (flatCount) flatCount.hidden = slices;
}

function refreshTaskViewAfterFilterChange() {
  window.NRCTaskQuery?.update();
  if (window.NRCTaskSearch) {
    window.NRCTaskSearch.update();
    window.NRCTasks?.renderReminderQueue?.();
  } else {
    renderCurrentTaskView();
  }
}

// =============================================================================
// FILTER UI
// =============================================================================

function applyFilterFromUI() {
  const f = TaskViewState.filters;

  const statusSelect = document.getElementById("filterStatus");
  const assigneeSelect = document.getElementById("filterAssignee");
  const colorSelect = document.getElementById("filterColor");
  const projectSelect = document.getElementById("filterProject");
  const flagsSelect = document.getElementById("filterFlags");
  const hideLockedRemindersCheck = document.getElementById("filterHideLockedReminders");
  const searchInput = document.getElementById("taskSearch");

  if (statusSelect) {
    f.status = statusSelect.value === ""
      ? null
      : statusSelect.value === "open" ? "open" : parseInt(statusSelect.value, 10);
  }
  if (assigneeSelect) {
    f.assignee = assigneeSelect.value === "" ? null : assigneeSelect.value;
  }
  if (colorSelect) {
    f.color = colorSelect.value === "" ? null : parseInt(colorSelect.value, 10);
  }
  if (projectSelect) {
    f.project = projectSelect.value === "" ? null : projectSelect.value;
  }
  if (flagsSelect) {
    f.blocked = flagsSelect.value === "blocked" || flagsSelect.value === "both" ? true : null;
    f.overdue = flagsSelect.value === "overdue" || flagsSelect.value === "both" ? true : null;
  }
  if (hideLockedRemindersCheck) {
    f.hideLockedReminders = hideLockedRemindersCheck.checked;
  }
  if (searchInput) {
    f.search = searchInput.value.trim();
  }

  // Sync legacy myTasksOnly for kanban compatibility
  myTasksOnly = f.assignee === "me";

  refreshTaskViewAfterFilterChange();
}

function resetFilters() {
  // RESET clears the register the reader is looking at. In the slice grouping
  // that is the slice filters; the flat list keeps its own state until it is the
  // register on screen.
  if (TaskViewState.grouping === "slices") {
    window.NRCSlices?.resetFilters?.();
    return;
  }

  TaskViewState.filters = {
    status: "open",
    assignee: null,
    blocked: null,
    overdue: null,
    hideLockedReminders: false,
    reminderView: "all",
    search: "",
    color: null,
    project: null,
  };
  myTasksOnly = false;

  // Reset UI elements
  const statusSelect = document.getElementById("filterStatus");
  const assigneeSelect = document.getElementById("filterAssignee");
  const colorSelect = document.getElementById("filterColor");
  const projectSelect = document.getElementById("filterProject");
  const flagsSelect = document.getElementById("filterFlags");
  const hideLockedRemindersCheck = document.getElementById("filterHideLockedReminders");
  const searchInput = document.getElementById("taskSearch");

  if (statusSelect) statusSelect.value = "open";
  if (assigneeSelect) assigneeSelect.value = "";
  if (colorSelect) colorSelect.value = "";
  if (projectSelect) projectSelect.value = "";
  if (flagsSelect) flagsSelect.value = "";
  if (hideLockedRemindersCheck) hideLockedRemindersCheck.checked = false;
  if (searchInput) searchInput.value = "";

  refreshTaskViewAfterFilterChange();
}

function populateProjectFilter() {
  const select = document.getElementById("filterProject");
  if (!select) return;

  const currentValue = TaskViewState.filters.project;
  select.innerHTML = '<option value="">ALL</option>';

  const tasks = roomTasks.get(0n);
  const projects = new Map();
  const addProject = (value) => {
    const project = value || "";
    if (project) projects.set(project, project);
  };
  const serverProjects = window.NRCTaskQuery?.getProjects(0n);
  if (serverProjects) serverProjects.forEach(addProject);
  if (!serverProjects && tasks) {
    for (const task of tasks.values()) {
      if (task.status !== 4) addProject(task.project);
    }
  }
  const searchState = window.NRCTaskSearch?.getState?.();
  if (searchState?.mode === "results" && searchState.roomId === 0n) {
    for (const task of searchState.tasks.values()) {
      if (task.status !== 4) addProject(task.project);
    }
  }

  for (const project of Array.from(projects.values()).sort()) {
    const opt = document.createElement("option");
    opt.value = project;
    opt.textContent = project;
    select.appendChild(opt);
  }

  if (currentValue) {
    const matchingProject = projects.get(currentValue);
    if (matchingProject) {
      select.value = matchingProject;
      TaskViewState.filters.project = matchingProject;
    } else {
      const opt = document.createElement("option");
      opt.value = currentValue;
      opt.textContent = currentValue;
      select.appendChild(opt);
      select.value = currentValue;
    }
  }
}

function getAssigneeFilterOptions() {
  const options = [
    { label: "ALL", value: "" },
    { label: "MY TASKS", value: "me" },
  ];
  const users = new Set();
  for (const user of window.NRCTaskQuery?.getAssignees?.() || []) users.add(user);

  if (typeof knownRoomUsers !== "undefined" && knownRoomUsers.size > 0) {
    for (const user of knownRoomUsers) users.add(user);
  }
  if (typeof roomPresence !== "undefined" && typeof currentRoomId !== "undefined") {
    const presence = roomPresence.get(currentRoomId);
    if (presence) {
      for (const user of presence.keys()) users.add(user);
    }
  }

  for (const user of Array.from(users).sort()) {
    if (user && user !== myNickname) {
      options.push({ label: user, value: user });
    }
  }

  return options;
}

function populateAssigneeFilter() {
  const select = document.getElementById("filterAssignee");
  if (!select) return;

  const currentValue = TaskViewState.filters.assignee;
  select.innerHTML = "";

  const options = getAssigneeFilterOptions();
  if (currentValue && !options.some((option) => option.value === currentValue)) {
    options.push({ label: currentValue, value: currentValue });
  }
  for (const option of options) {
    const opt = document.createElement("option");
    opt.value = option.value;
    opt.textContent = option.label;
    select.appendChild(opt);
  }

  select.value = currentValue ?? "";
}

// =============================================================================
// SORT PERSISTENCE (filters are session-only, like the other views)
// =============================================================================

function saveViewState() {
  try {
    const state = {
      sortColumn: TaskViewState.sortColumn,
      sortDirection: TaskViewState.sortDirection,
      grouping: TaskViewState.grouping,
    };
    localStorage.setItem("nrc_task_view_state", JSON.stringify(state));
  } catch (e) {
    // localStorage may not be available
  }
}

function loadViewState() {
  try {
    const saved = localStorage.getItem("nrc_task_view_state");
    if (saved) {
      const state = JSON.parse(saved);
      if (state.sortColumn) TaskViewState.sortColumn = state.sortColumn;
      if (state.sortDirection)
        TaskViewState.sortDirection = state.sortDirection;
      if (state.grouping === "flat" || state.grouping === "slices")
        TaskViewState.grouping = state.grouping;
    }
  } catch (e) {
    // localStorage may not be available
  }
}

function initTaskViewState() {
  loadViewState();

  document.querySelectorAll("[data-task-grouping]").forEach((button) => {
    button.addEventListener("click", () => setTaskGrouping(button.dataset.taskGrouping));
  });
  syncGroupingTabs();

  const includeClosed = document.getElementById("sliceIncludeClosed");
  if (includeClosed) {
    includeClosed.checked = window.NRCSlices?.getIncludeClosed?.() === true;
    includeClosed.addEventListener("change", () => {
      window.NRCSlices?.setIncludeClosed?.(includeClosed.checked);
    });
  }

  document.querySelectorAll("[data-reminder-filter]").forEach((button) => {
    button.addEventListener("click", () => {
      TaskViewState.filters.reminderView = button.dataset.reminderFilter;
      window.NRCTasks?.renderReminderQueue?.();
    });
  });

  // Wire up filter event listeners
  const filterElements = ["filterStatus", "filterAssignee", "filterColor", "filterProject", "filterFlags"];
  filterElements.forEach((id) => {
    const el = document.getElementById(id);
    if (el && (id === "filterStatus" || id === "filterColor")) {
      const key = id === "filterStatus" ? "status" : "color";
      el.value = TaskViewState.filters[key] ?? "";
    }
    if (el && id === "filterFlags") {
      el.value = TaskViewState.filters.blocked === true
        ? TaskViewState.filters.overdue === true ? "both" : "blocked"
        : TaskViewState.filters.overdue === true ? "overdue" : "";
    }
    if (el) el.addEventListener("change", applyFilterFromUI);
  });

  const hideLockedRemindersCheck = document.getElementById("filterHideLockedReminders");
  if (hideLockedRemindersCheck) {
    hideLockedRemindersCheck.checked = TaskViewState.filters.hideLockedReminders === true;
    hideLockedRemindersCheck.addEventListener("change", applyFilterFromUI);
  }

  const searchInput = document.getElementById("taskSearch");
  if (searchInput) {
    searchInput.value = TaskViewState.filters.search || "";
    searchInput.addEventListener("input", () => {
      TaskViewState.filters.search = searchInput.value.trim();
      window.NRCTaskQuery?.update();
      if (window.NRCTaskSearch) window.NRCTaskSearch.update({ debounce: true });
      else renderCurrentTaskView();
    });
  }

  const resetBtn = document.getElementById("filterReset");
  if (resetBtn) {
    resetBtn.addEventListener("click", resetFilters);
  }

  // Sort headers (for list view)
  document.querySelectorAll(".task-table th[data-sort]").forEach((th) => {
    th.addEventListener("click", () => toggleSort(th.dataset.sort));
  });

  populateAssigneeFilter();
  populateProjectFilter();
}
