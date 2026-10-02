// =============================================================================
// TASK REFERENCES IN CHAT MODULE
// =============================================================================
// Handles parsing, rendering, and previewing task references (#123) in messages

let taskPreviewPortal = null;
let taskPreviewHideTimer = null;

/**
 * Parse task references (#123) in text and return array of {id, start, end}
 */
function parseTaskReferences(text) {
  const references = [];
  const regex = /#(\d+)/g;
  let match;

  while ((match = regex.exec(text)) !== null) {
    references.push({
      id: BigInt(match[1]),
      start: match.index,
      end: match.index + match[0].length,
      fullMatch: match[0],
    });
  }

  return references;
}

/**
 * Convert task reference to clickable HTML element
 */
function createTaskReferenceElement(taskId, roomId) {
  const span = document.createElement("span");
  span.className = "task-reference";
  span.dataset.taskId = taskId;
  span.dataset.roomId = roomId;
  span.textContent = `#${taskId}`;

  // Hover preview
  span.addEventListener("mouseenter", (e) => {
    showTaskPreview(e.target, taskId, roomId);
  });

  span.addEventListener("mouseleave", () => {
    hideTaskPreview();
  });

  // Click to jump to task
  span.addEventListener("click", (e) => {
    e.stopPropagation();
    jumpToTask(taskId, roomId);
  });

  return span;
}

/**
 * Render message content with task references highlighted
 * Handles both plain text and HTML content
 */
function renderMessageWithTaskReferences(text, roomId) {
  if (!text || typeof text !== "string") {
    return document.createTextNode("");
  }

  const references = parseTaskReferences(text);

  // If no references, return plain text
  if (references.length === 0) {
    return document.createTextNode(text);
  }

  // Build DOM with interspersed text and task references
  const container = document.createDocumentFragment();
  let lastEnd = 0;

  for (const ref of references) {
    // Add text before reference
    if (ref.start > lastEnd) {
      container.appendChild(
        document.createTextNode(text.substring(lastEnd, ref.start))
      );
    }

    // Add task reference element
    container.appendChild(createTaskReferenceElement(ref.id, roomId));

    lastEnd = ref.end;
  }

  // Add remaining text
  if (lastEnd < text.length) {
    container.appendChild(document.createTextNode(text.substring(lastEnd)));
  }

  return container;
}

/**
 * Show task preview popup on hover
 */
function showTaskPreview(element, taskId, roomId) {
  roomId = 0n;
  // Remove any existing preview
  clearTimeout(taskPreviewHideTimer);
  taskPreviewHideTimer = null;
  taskPreviewPortal?.destroy();
  taskPreviewPortal = null;

  const tasks = window.NRCTasks.roomTasks.get(BigInt(roomId));
  const task = tasks?.get(BigInt(taskId));
  if (!task) {
    showTaskNotFoundPreview(element, taskId);
    window.NRCTasks?.requestTask?.(roomId, taskId, {
      onSuccess: ({ task: loaded }) => {
        if (!element.matches(":hover")) return;
        showTaskPreview(element, loaded.id, loaded.convId);
      },
    });
    return;
  }

  const preview = createTaskPreviewCard(task);
  preview.id = "taskPreviewPopup";

  taskPreviewPortal = Portal.create(preview, element, {
    position: "bottom", align: "left", matchWidth: false, offsetY: 8, flipIfNeeded: true,
  });
  taskPreviewPortal.show();

  // Keep preview visible on hover
  preview.addEventListener("mouseenter", () => {
    clearTimeout(taskPreviewHideTimer);
    taskPreviewHideTimer = null;
  });

  preview.addEventListener("mouseleave", () => {
    hideTaskPreview();
  });
}

/**
 * Hide task preview popup
 */
function hideTaskPreview() {
  clearTimeout(taskPreviewHideTimer);
  taskPreviewHideTimer = setTimeout(() => {
    taskPreviewPortal?.destroy();
    taskPreviewPortal = null;
    taskPreviewHideTimer = null;
  }, 100);
}

/**
 * Create a task preview card showing task details
 */
function createTaskPreviewCard(task) {
  const card = document.createElement("div");
  card.className = "task-preview-card";

  const statusCode =
    window.NRCTasks.TaskStatusCodes[task.status] || "??";
  const statusName = window.NRCTasks.TaskStatusNames[task.status] || "UNKNOWN";
  const colorName = window.NRCTasks.TaskColorNames[task.color] || "—";

  // Format due date
  const dueStr =
    task.dueAt && task.dueAt !== 0n
      ? new Date(Number(task.dueAt / 1000000n)).toLocaleDateString()
      : "—";

  const isOverdue = isTaskOverdue ? isTaskOverdue(task) : false;

  // Build preview HTML
  card.innerHTML = `
    <div class="task-preview-header">
      <div class="task-preview-id">#${task.id}</div>
      <div class="task-preview-status" data-status="${statusCode}">${statusCode}</div>
    </div>
    <div class="task-preview-title">${escapeHtml(task.title)}</div>
    <div class="task-preview-row">
      <span class="task-preview-label">Status:</span>
      <span>${statusName}</span>
    </div>
    <div class="task-preview-row">
      <span class="task-preview-label">Assignee:</span>
      <span>${task.assignee || "—"}</span>
    </div>
    <div class="task-preview-row">
      <span class="task-preview-label">Category:</span>
      <span>${colorName}</span>
    </div>
    <div class="task-preview-row">
      <span class="task-preview-label">Due:</span>
      <span class="${isOverdue ? "task-preview-overdue" : ""}">${dueStr}</span>
    </div>
    ${
      task.description
        ? `<div class="task-preview-desc">${escapeHtml(task.description.substring(0, 100))}${task.description.length > 100 ? "..." : ""}</div>`
        : ""
    }
  `;

  return card;
}

/**
 * Show preview when task doesn't exist
 */
function showTaskNotFoundPreview(element, taskId) {
  const preview = document.createElement("div");
  preview.className = "task-preview-card task-preview-notfound";
  preview.id = "taskPreviewPopup";
  preview.innerHTML = `
    <div class="task-preview-header">
      <div class="task-preview-id">#${taskId}</div>
      <div class="task-preview-status">---</div>
    </div>
    <div class="task-preview-title">Task not found</div>
    <div class="task-preview-row">
      <span>This task doesn't exist in the workspace</span>
    </div>
  `;

  taskPreviewPortal = Portal.create(preview, element, {
    position: "bottom", align: "left", matchWidth: false, offsetY: 8, flipIfNeeded: true,
  });
  taskPreviewPortal.show();
  preview.addEventListener("mouseenter", () => {
    clearTimeout(taskPreviewHideTimer);
    taskPreviewHideTimer = null;
  });
  preview.addEventListener("mouseleave", hideTaskPreview);
}

/**
 * Jump to task in list view
 * - Opens tasks view if not visible
 * - Scrolls to task
 * - Highlights it temporarily
 */
function jumpToTask(taskId, roomId) {
  roomId = 0n;
  const cached = window.NRCTasks?.roomTasks?.get(roomId)?.get(BigInt(taskId));
  if (!cached) {
    window.NRCTasks?.requestTask?.(roomId, taskId, {
      onSuccess: ({ task }) => window.NRCTasks.selectTask(task),
      onError: () => logSystem(`TASK #${taskId} NOT FOUND`, "tasks", "WARN"),
    });
  }
  // Wait for list to render
  setTimeout(() => {
    const tasks = window.NRCTasks?.roomTasks?.get(roomId);
    const task = tasks?.get(BigInt(taskId));
    if (task && typeof window.NRCTasks?.selectTask === "function") {
      // Keep behavior consistent with clicking task links in AI sources: open detail panel.
      window.NRCTasks.selectTask(task);
    }

    const taskElement = document.querySelector(
      `.task-table tbody tr[data-task-id="${taskId}"]`
    );
    if (taskElement) {
      // Scroll into view
      taskElement.scrollIntoView({ behavior: "smooth", block: "nearest" });

      // Highlight briefly
      taskElement.classList.add("task-highlighted");
      setTimeout(() => {
        taskElement.classList.remove("task-highlighted");
      }, 2000);
    }
  }, 100);

  logSystem(`JUMPED TO TASK #${taskId}`, "tasks");
}

/**
 * Apply task reference rendering to existing message elements
 * Recursively processes all text nodes and converts task references to interactive elements
 */
function processMessageTaskReferences(messageElement, roomId) {
  if (!messageElement) return;

  // Process all child nodes recursively
  processNodeForTaskReferences(messageElement, roomId);
}

/**
 * Recursively process a node and its children for task references
 */
function processNodeForTaskReferences(node, roomId) {
  if (!node) return;

  // Handle text nodes
  if (node.nodeType === Node.TEXT_NODE) {
    const text = node.textContent;
    const references = parseTaskReferences(text);

    if (references.length > 0) {
      // Replace text node with processed version
      const processed = renderMessageWithTaskReferences(text, roomId);
      node.parentNode.replaceChild(processed, node);
    }
    return; // Don't process children of text nodes
  }

  // Handle element nodes - process children
  if (node.nodeType === Node.ELEMENT_NODE) {
    // Don't process certain elements (like script tags)
    if (["SCRIPT", "STYLE", "IMG"].includes(node.tagName)) {
      return;
    }

    // Process all child nodes (use Array.from to avoid mutation issues)
    const childNodes = Array.from(node.childNodes);
    for (const child of childNodes) {
      processNodeForTaskReferences(child, roomId);
    }
  }
}

// Export for use in app.js
window.NRCTaskReferences = {
  parseTaskReferences,
  createTaskReferenceElement,
  renderMessageWithTaskReferences,
  showTaskPreview,
  hideTaskPreview,
  processMessageTaskReferences,
  jumpToTask,
};
