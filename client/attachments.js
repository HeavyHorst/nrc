// =============================================================================
// ATTACHMENTS MODULE - Dense, explicit file attachment handling
// =============================================================================
// Manages file uploads, downloads, and attachment metadata for NRC tasks.
// State indicators: UPLOADED (cyan), PENDING (gray), UPLOADING (cyan animate),
// ERROR (red). Binary protocol via tailscale-proxy service.

const MAX_ATTACHMENTS_PER_TASK = 10;
const MAX_FILE_SIZE = 100 * 1024 * 1024; // 100 MB per file
const PROXY_URL = "";

// Attachment state tracking
let uploadInProgress = false;
let currentUploadProgress = new Map(); // fileId -> {percent, filename}
let currentTaskAttachments = []; // Attachments being edited in detail panel

function emitAttachmentsChanged() {
  document.dispatchEvent(new CustomEvent("nrc:attachments-changed", {
    detail: getAttachmentDraftState(),
  }));
}

function attachmentFileURL(fileId, filename = "", inline = false) {
  const params = new URLSearchParams();
  if (inline) params.set("inline", "true");
  if (filename) params.set("filename", filename);
  const query = params.toString();
  return `${PROXY_URL}/files/${encodeURIComponent(fileId)}${query ? `?${query}` : ""}`;
}

// Versioned chat payload. Keep a canonical local URL for offline reference GC.
function encodeChatAttachment(attachment) {
  return JSON.stringify({
    type: "attachment", version: 1,
    fileId: attachment.fileId, filename: attachment.filename,
    size: Number(attachment.size), mimeType: attachment.mimeType,
    url: attachmentFileURL(attachment.fileId, attachment.filename),
  });
}

function parseChatAttachment(content) {
  try {
    const att = JSON.parse(content);
    if (att?.type !== "attachment" || att.version !== 1 ||
        typeof att.fileId !== "string" || !/^att_[0-9a-f]{32}$/.test(att.fileId) ||
        typeof att.filename !== "string" || !att.filename ||
        typeof att.mimeType !== "string" ||
        !Number.isSafeInteger(att.size) || att.size < 0 || att.size > MAX_FILE_SIZE ||
        att.url !== attachmentFileURL(att.fileId, att.filename)) return null;
    return att;
  } catch {
    return null;
  }
}

function renderChatAttachment(att) {
  const container = document.createElement("div");
  container.className = "chat-attachment";
  const row = document.createElement("a");
  row.className = "note-share-attachment-row";
  row.href = attachmentFileURL(att.fileId, att.filename);
  row.download = att.filename;
  row.title = `Download ${att.filename}`;
  for (const [className, text] of [
    ["note-share-attachment-type", getFileExtension(att.filename, att.mimeType)],
    ["note-share-attachment-name", att.filename],
    ["note-preview-attachment-size", formatFileSize(att.size)],
  ]) {
    const span = document.createElement("span");
    span.className = className;
    span.textContent = text;
    row.appendChild(span);
  }
  container.appendChild(row);
  const url = attachmentFileURL(att.fileId, att.filename, true);
  if (att.mimeType.startsWith("image/")) {
    const image = document.createElement("img");
    image.className = "chat-image";
    image.src = url;
    image.alt = att.filename;
    image.loading = "lazy";
    window.addImageModalHandler?.(image);
    container.appendChild(image);
  } else if (att.mimeType.startsWith("audio/") || att.mimeType.startsWith("video/")) {
    const player = document.createElement(att.mimeType.startsWith("audio/") ? "audio" : "video");
    player.controls = true;
    player.preload = "none";
    player.setAttribute("aria-label", att.filename);
    player.setAttribute("playsinline", "");
    player.src = url;
    container.appendChild(player);
    const status = document.createElement("span");
    status.className = "note-preview-attachment-size";
    status.textContent = "NO AUTOPLAY · DOWNLOAD VIA FILE ROW";
    player.addEventListener("error", () => {
      status.textContent = "PREVIEW UNAVAILABLE · DOWNLOAD VIA FILE ROW";
    });
    container.appendChild(status);
  } else if (att.mimeType === "application/pdf") {
    const preview = document.createElement("a");
    preview.className = "btn";
    preview.textContent = "OPEN PDF ↗";
    preview.href = url;
    preview.target = "_blank";
    preview.rel = "noopener noreferrer";
    container.appendChild(preview);
  }
  return container;
}

function getAttachmentRefURL(attachments, index, inline = false) {
  const attachment = attachments && attachments[Number(index)];
  if (!attachment || !attachment.fileId) return `att:${index}`;
  return attachmentFileURL(attachment.fileId, attachment.filename || "", inline);
}

function resolveAttachmentRefs(content, attachments = []) {
  return String(content || "")
    .replace(/(!?\[[^\]]*\]\()att:(\d+)(\))/g, (match, prefix, index, suffix) => {
      return `${prefix}${getAttachmentRefURL(attachments, index, prefix.startsWith("!"))}${suffix}`;
    })
    .replace(/\b(src|href)=(['"])att:(\d+)\2/g, (match, attr, quote, index) => {
      return `${attr}=${quote}${getAttachmentRefURL(attachments, index, attr === "src")}${quote}`;
    });
}

// Get element ID for detail panel attachments
function getAttachmentElementId(suffix) {
  return "taskDetail" + suffix;
}

// =============================================================================
// FILE UPLOAD
// =============================================================================

// Upload a file to the proxy service
// Returns Promise<Attachment> or rejects with error
async function uploadFile(file, taskId = null, roomId = null) {
  if (!file) {
    throw new Error("No file provided");
  }

  if (file.size > MAX_FILE_SIZE) {
    throw new Error(`File exceeds 100 MB limit (${Math.round(file.size / 1024 / 1024)} MB)`);
  }

  const formData = new FormData();
  formData.append("file", file);
  if (taskId) formData.append("taskId", taskId);
  if (roomId) formData.append("room", roomId);

  try {
    const response = await fetch(`${PROXY_URL}/upload?workspace=${encodeURIComponent(currentWorkspaceId)}`, {
      method: "POST",
      body: formData,
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Upload failed: ${response.status} ${error}`);
    }

    const result = await response.json();

    // Validate response structure
    if (!result.fileId || !result.filename || result.size === undefined) {
      throw new Error("Invalid upload response from proxy");
    }

    // Convert response to internal Attachment format
    return {
      fileId: result.fileId,
      filename: result.filename,
      size: BigInt(result.size),
      mimeType: result.mimeType || "application/octet-stream",
      uploadedAt: BigInt(result.uploadedAt || 0),
      _state: "uploaded", // Track state for UI
    };
  } catch (err) {
    console.error("File upload error:", err);
    throw err;
  }
}

// Handle file input change in task modal
async function handleAttachmentFileSelect(event) {
  const input = event.target;
  const file = input.files?.[0];

  if (!file) return;

  if (currentTaskAttachments.length >= MAX_ATTACHMENTS_PER_TASK) {
    const message = `MAXIMUM ${MAX_ATTACHMENTS_PER_TASK} ATTACHMENTS`;
    if (window.NRCDialog && typeof window.NRCDialog.notify === "function") {
      window.NRCDialog.notify(message, { logType: "Error" });
    } else if (typeof logMessage === "function") {
      logMessage("Error", message);
    }
    input.value = "";
    return;
  }

  const uploadBtn = document.getElementById(getAttachmentElementId("UploadBtn"));
  const progressDiv = document.getElementById(getAttachmentElementId("UploadProgress"));
  const progressBar = document.getElementById(getAttachmentElementId("UploadProgressBar"));
  const statusDiv = document.getElementById(getAttachmentElementId("UploadStatus"));

  // progressDiv and statusDiv are optional UI feedback elements
  // uploadBtn was removed from UI - no longer required

  // Create pending attachment immediately
  const pendingAttachment = {
    fileId: null, // Will be assigned on upload completion
    filename: file.name,
    size: BigInt(file.size),
    mimeType: file.type || "application/octet-stream",
    uploadedAt: 0n,
    _state: "pending",
    _tempId: Math.random().toString(36).substr(2, 9), // Temp ID for tracking
  };

  currentTaskAttachments.push(pendingAttachment);
  renderAttachmentsList();
  emitAttachmentsChanged();

  try {
    if (uploadBtn) uploadBtn.disabled = true;
    if (progressDiv) progressDiv.style.display = "block";

    // Update pending attachment to uploading state
    pendingAttachment._state = "uploading";
    renderAttachmentsList();

    // Perform upload with progress simulation
    const attachment = await uploadFile(file);

    // Replace pending with uploaded
    const idx = currentTaskAttachments.findIndex(
      (a) => a._tempId === pendingAttachment._tempId
    );
    if (idx >= 0) {
      currentTaskAttachments[idx] = attachment;
    }

    if (statusDiv) statusDiv.textContent = `✓ ${file.name} uploaded`;
    if (progressBar) progressBar.style.width = "100%";
    renderAttachmentsList();
    emitAttachmentsChanged();

    setTimeout(() => {
      if (progressDiv) progressDiv.style.display = "none";
    }, 1500);
  } catch (err) {
    // Mark as error
    pendingAttachment._state = "error";
    pendingAttachment._error = err.message;
    renderAttachmentsList();
    emitAttachmentsChanged();

    if (statusDiv) {
      statusDiv.textContent = `✗ ${err.message}`;
      statusDiv.classList.add("error");
    }

    setTimeout(() => {
      if (statusDiv) statusDiv.classList.remove("error");
      if (progressDiv) progressDiv.style.display = "none";
    }, 4000);
  } finally {
    if (uploadBtn) uploadBtn.disabled = false;
    input.value = ""; // Clear input for re-upload
  }
}

// =============================================================================
// ATTACHMENT MANAGEMENT IN MODAL
// =============================================================================

// Initialize attachment tracking for a task modal
function initAttachmentsForTask(task = null) {
  currentTaskAttachments = [];
  if (task && task.attachments && Array.isArray(task.attachments)) {
    currentTaskAttachments = task.attachments.map((att) => ({
      fileId: att.fileId,
      filename: att.filename,
      size: att.size,
      mimeType: att.mimeType,
      uploadedAt: att.uploadedAt,
      _state: "uploaded", // Server-sourced attachments are already uploaded
    }));
  }
  renderAttachmentsList();
  emitAttachmentsChanged();
}

// Add uploaded attachment to current task
function addAttachmentToCurrentTask(attachment) {
  if (currentTaskAttachments.length >= MAX_ATTACHMENTS_PER_TASK) {
    const message = `MAXIMUM ${MAX_ATTACHMENTS_PER_TASK} ATTACHMENTS PER TASK`;
    if (window.NRCDialog && typeof window.NRCDialog.notify === "function") {
      window.NRCDialog.notify(message, { logType: "Error" });
    } else if (typeof logMessage === "function") {
      logMessage("Error", message);
    }
    return;
  }
  currentTaskAttachments.push({
    ...attachment,
    _state: "uploaded",
  });
  renderAttachmentsList();
  emitAttachmentsChanged();
}

// Remove attachment from current task
function removeAttachmentFromCurrentTask(fileId, tempId = null) {
  currentTaskAttachments = currentTaskAttachments.filter((att) => {
    if (tempId) return att._tempId !== tempId; // Remove by temp ID (pending)
    return att.fileId !== fileId; // Remove by file ID (uploaded)
  });
  renderAttachmentsList();
  emitAttachmentsChanged();
}

// Get file extension for type display
function getFileExtension(filename, mimeType) {
  if (mimeType.startsWith("image/")) return "IMG";
  if (mimeType.startsWith("video/")) return "VID";
  if (mimeType.startsWith("audio/")) return "AUD";
  if (mimeType.includes("pdf")) return "PDF";
  if (mimeType.includes("zip") || mimeType.includes("gzip")) return "ZIP";
  if (mimeType.includes("text") || mimeType.includes("plain")) return "TXT";

  // Try file extension
  const ext = filename.split(".").pop()?.toUpperCase();
  return ext && ext.length <= 4 ? ext : "BIN";
}

// Render attachments list as compact rows
function renderAttachmentsList() {
  const container = document.getElementById(getAttachmentElementId("AttachmentsList"));
  if (!container) return;

  container.innerHTML = "";

  // Update count
  const count = document.getElementById(getAttachmentElementId("AttachmentsCount"));
  if (count) {
    count.textContent = `${currentTaskAttachments.length} / ${MAX_ATTACHMENTS_PER_TASK}`;
  }

  if (currentTaskAttachments.length === 0) {
    const empty = document.createElement("div");
    empty.className = "task-attachments-empty";
    empty.textContent = "No attachments — drop files or press + ADD";
    container.appendChild(empty);
    return;
  }

  // Render as grid rows (simple, text-based)
  for (const att of currentTaskAttachments) {
    const row = document.createElement("div");
    row.className = "task-attachment-item";
    row.dataset.fileId = att.fileId || att._tempId;

    // For non-uploaded states, show state inline with filename
    const isUploaded = att._state === "uploaded";
    const statePrefix = !isUploaded ? `[${att._state === "pending" ? "PND" : att._state === "uploading" ? "UPL" : "ERR"}] ` : "";

    // Filename cell (with optional state prefix and progress bar for uploading)
    const filenameCell = document.createElement("div");
    filenameCell.className = "task-attachment-filename-cell";
    
    if (!isUploaded) {
      filenameCell.classList.add(att._state);
    }

    // Filename link/text
    const filename = document.createElement("a");
    filename.className = "task-attachment-filename";
    filename.textContent = statePrefix + att.filename;
    
    if (isUploaded && att.fileId) {
      // Images open in modal
      if (att.mimeType && att.mimeType.startsWith("image/")) {
        filename.href = "#";
        filename.onclick = (e) => {
          e.preventDefault();
          e.stopPropagation();
          if (window.openImageModal) {
            const imageUrl = attachmentFileURL(att.fileId, att.filename, true);
            window.openImageModal(imageUrl, att.filename, att.filename);
          }
        };
      } else if (isPreviewableType(att.mimeType)) {
        filename.href = attachmentFileURL(att.fileId, att.filename, true);
        filename.target = "_blank";
        filename.rel = "noopener noreferrer";
      } else {
        filename.href = attachmentFileURL(att.fileId, att.filename);
        filename.download = att.filename || att.fileId;
      }
    } else {
      // Pending/uploading/error - not clickable
      filename.style.cursor = "default";
      filename.style.pointerEvents = "none";
    }
    
    filenameCell.appendChild(filename);

    // Inline progress bar for uploading state
    if (att._state === "uploading") {
      const progressBar = document.createElement("div");
      progressBar.className = "task-attachment-progress";
      progressBar.dataset.tempId = att._tempId;
      const progressFill = document.createElement("div");
      progressFill.className = "task-attachment-progress-fill";
      progressFill.style.width = (att._progress || 0) + "%";
      progressBar.appendChild(progressFill);
      filenameCell.appendChild(progressBar);
    }

    // Type (uppercase extension)
    const type = document.createElement("div");
    type.className = "task-attachment-type";
    type.textContent = getFileExtension(att.filename, att.mimeType);

    // Size (formatted, right-aligned)
    const size = document.createElement("div");
    size.className = "task-attachment-size";
    size.textContent = formatFileSize(Number(att.size));

    // Markdown copy button
    const mdBtn = document.createElement("button");
    mdBtn.className = "btn btn--row task-attachment-md-btn";
    mdBtn.textContent = "REF";
    mdBtn.type = "button";
    mdBtn.title = "Copy markdown reference";
    if (isUploaded) {
      const idx = currentTaskAttachments.indexOf(att);
      const isImage = att.mimeType && att.mimeType.startsWith("image/");
      mdBtn.onclick = (e) => {
        e.preventDefault();
        const md = isImage ? `![${att.filename}](att:${idx})` : `[${att.filename}](att:${idx})`;
        navigator.clipboard.writeText(md).then(() => {
          mdBtn.textContent = "OK";
          setTimeout(() => { mdBtn.textContent = "REF"; }, 1000);
        });
      };
    } else {
      mdBtn.disabled = true;
      mdBtn.style.opacity = "0.3";
    }

    // Remove button
    const removeBtn = document.createElement("button");
    removeBtn.className = "btn btn--row btn--danger task-attachment-remove-btn";
    removeBtn.textContent = "×";
    removeBtn.type = "button";
    removeBtn.title = "Remove attachment";
    removeBtn.onclick = (e) => {
      e.preventDefault();
      removeAttachmentFromCurrentTask(att.fileId, att._tempId);
    };

    // Build row in grid order (5 columns now)
    row.appendChild(filenameCell);
    row.appendChild(type);
    row.appendChild(size);
    row.appendChild(mdBtn);
    row.appendChild(removeBtn);

    container.appendChild(row);
  }
}

// =============================================================================
// TASK INTEGRATION
// =============================================================================

// Get current attachments for task submission (only uploaded ones)
function getTaskAttachments() {
  return currentTaskAttachments
    .filter((att) => att._state === "uploaded" && att.fileId)
    .map((att) => ({
      fileId: att.fileId,
      filename: att.filename,
      size: att.size,
      mimeType: att.mimeType,
      uploadedAt: att.uploadedAt,
    }));
}

function getAttachmentDraftState() {
  return {
    uploaded: getTaskAttachments(),
    totalCount: currentTaskAttachments.length,
    pendingCount: currentTaskAttachments.filter((att) => att._state === "pending" || att._state === "uploading").length,
    errorCount: currentTaskAttachments.filter((att) => att._state === "error").length,
  };
}

// Clear attachments (e.g., after successful task creation)
function clearTaskAttachments() {
  currentTaskAttachments = [];
  renderAttachmentsList();
  emitAttachmentsChanged();
}

// Initialize attachments for the detail panel
function initAttachmentsForDetailPanel(task) {
  initAttachmentsForTask(task);
  
  // Wire up file input change handler
  const fileInput = document.getElementById(getAttachmentElementId("FileInput"));
  if (fileInput) {
    fileInput.onchange = handleAttachmentFileSelect;
  }
  
  // Wire up [+ ADD] button to trigger file input
  const addBtn = document.getElementById("taskDetailAddFile");
  if (addBtn && fileInput) {
    addBtn.onclick = () => fileInput.click();
  }
}

// =============================================================================
// DOWNLOAD HANDLING
// =============================================================================

// Download file directly
function downloadAttachment(fileId, filename = null) {
  const link = document.createElement("a");
  link.href = attachmentFileURL(fileId, filename || "");
  link.download = filename || fileId;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
}

// Open file in new tab/window (inline display)
function previewAttachment(fileId, mimeType) {
  if (!isPreviewableType(mimeType)) {
    downloadAttachment(fileId);
    return;
  }

  const url = attachmentFileURL(fileId, "", true);
  window.open(url, "_blank", "noopener,noreferrer");
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

// Check if file type can be previewed inline
function isPreviewableType(mimeType) {
  if (!mimeType) return false;
  const previewable = [
    "image/",
    "video/",
    "audio/",
    "application/pdf",
  ];
  return previewable.some((type) => mimeType.startsWith(type));
}

// Format file size for display (B, KB, MB, GB)
function formatFileSize(bytes) {
  // Convert BigInt to Number if needed
  const size = typeof bytes === "bigint" ? Number(bytes) : bytes;
  if (size === 0) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let s = size;
  let unitIndex = 0;
  while (s >= 1024 && unitIndex < units.length - 1) {
    s /= 1024;
    unitIndex++;
  }
  return `${s.toFixed(1)} ${units[unitIndex]}`;
}

function getAttachmentPreviewData(att) {
  const filename = att.filename || att.fileId || "attachment";
  const mimeType = att.mimeType || "application/octet-stream";
  const type = getFileExtension(filename, mimeType);
  const size = formatFileSize(Number(att.size || 0));
  const fileId = att.fileId || "";
  const genericType = !att.mimeType || mimeType === "application/octet-stream";
  const isImage = mimeType.startsWith("image/") || (genericType && /\.(png|jpe?g|gif|webp|avif|bmp)$/i.test(filename));
  const inline = isImage || isPreviewableType(mimeType);
  const href = fileId ? attachmentFileURL(fileId, filename, inline) : "#";
  // DOWNLOAD always saves: the inline flag belongs to OPEN only.
  const downloadHref = fileId ? attachmentFileURL(fileId, filename) : "#";
  const dataAttrs = `data-image="${isImage ? "1" : "0"}" data-file-id="${escapeHtml(fileId)}" data-filename="${escapeHtml(filename)}"`;
  return { filename, type, size, href, downloadHref, inline, isImage, dataAttrs };
}

// The read ledger names the attachment and offers the two operations the file
// service supports: OPEN previews what can be previewed, DOWNLOAD always saves.
// The filename is a label, not a link, so both rows of the ledger read alike.
function renderAttachmentPreviewStripHtml(attachments = [], id = "attachmentPreviewStrip", { inlineImages = false, alwaysOpen = false } = {}) {
  if (!attachments || attachments.length === 0) return "";

  const rows = attachments.map((att) => {
    const data = getAttachmentPreviewData(att);
    return `
      <div class="note-link-item">
        <span class="note-preview-attachment-type">${escapeHtml(data.type)}</span>
        <span class="note-preview-attachment-name" title="${escapeHtml(data.filename)}">${escapeHtml(data.filename)}</span>
        <span class="note-preview-attachment-size">${escapeHtml(data.size)}</span>
        <span class="note-preview-attachment-actions">
          ${(data.inline || alwaysOpen) && data.href !== "#" ? `<button class="btn btn--row" type="button" data-attachment-open ${data.dataAttrs}>OPEN</button>` : ""}
          <a class="btn btn--row" href="${escapeHtml(data.downloadHref)}" download="${escapeHtml(data.filename)}">DOWNLOAD</a>
        </span>
      </div>
      ${inlineImages && data.isImage && data.href !== "#" ? `<button class="file-assets-image" type="button" data-attachment-open ${data.dataAttrs} aria-label="Open ${escapeHtml(data.filename)}"><img src="${escapeHtml(data.href)}" alt="${escapeHtml(data.filename)}" loading="lazy"></button>` : ""}
    `;
  }).join("");

  return `
    <nrc-attachment-list class="note-links-section note-preview-links note-preview-attachments" id="${escapeHtml(id)}">
      <div class="note-links-header">
        <span class="note-links-label">ATTACHMENTS (${attachments.length})</span>
      </div>
      <div class="note-links-list">${rows}</div>
    </nrc-attachment-list>
  `;
}

class NRCAttachmentList extends HTMLElement {
  connectedCallback() {
    this.addEventListener("click", this.openAttachment);
  }

  disconnectedCallback() {
    this.removeEventListener("click", this.openAttachment);
  }

  openAttachment(event) {
    const button = event.target.closest("[data-attachment-open]");
    if (!button || button.closest("nrc-attachment-list") !== this || !button.dataset.fileId) return;
    const filename = button.dataset.filename || button.dataset.fileId;
    const url = attachmentFileURL(button.dataset.fileId, filename, true);
    // Images keep the modal; other previewable files open in their own tab.
    if (button.dataset.image === "1" && window.openImageModal) window.openImageModal(url, filename, filename);
    else window.open(url, "_blank", "noopener,noreferrer");
  }
}

customElements.define("nrc-attachment-list", NRCAttachmentList);

// =============================================================================
// ATTACHMENT POPOVER
// =============================================================================

let activeAttachmentPopover = null;
let activeAttachmentPopoverPortal = null;
let activeAttachmentPopoverAnchor = null;

function showAttachmentPopover(task, anchorElement) {
  closeAttachmentPopover();

  if (!task.attachments || task.attachments.length === 0) return;

  const popover = document.createElement("div");
  popover.className = "attachment-popover";

  // Header
  const header = document.createElement("div");
  header.className = "attachment-popover-header";
  header.innerHTML = `<span>ATTACHMENTS (${task.attachments.length})</span>`;

  const closeBtn = document.createElement("button");
  closeBtn.className = "btn attachment-popover-close";
  closeBtn.textContent = "×";
  closeBtn.onclick = (e) => {
    e.stopPropagation();
    closeAttachmentPopover();
  };
  header.appendChild(closeBtn);
  popover.appendChild(header);

  // Attachment list
  const list = document.createElement("div");
  list.className = "attachment-popover-list";

  for (const att of task.attachments) {
    const item = document.createElement("div");
    item.className = "attachment-popover-item";

    const type = getFileExtension(att.filename, att.mimeType);
    const size = formatFileSize(Number(att.size));

    // Type badge
    const typeBadge = document.createElement("span");
    typeBadge.className = "attachment-popover-type";
    typeBadge.textContent = type;

    // Filename link
    const link = document.createElement("a");
    link.className = "attachment-popover-filename";
    link.href = attachmentFileURL(att.fileId, att.filename);
    link.title = att.filename;
    link.textContent = att.filename;
    link.download = att.filename || att.fileId;

    if (att.mimeType && att.mimeType.startsWith("image/")) {
      link.href = "#";
      link.removeAttribute("download");
      link.onclick = (e) => {
        e.preventDefault();
        e.stopPropagation();
        closeAttachmentPopover();
        if (window.openImageModal) {
          const imageUrl = attachmentFileURL(att.fileId, att.filename, true);
          window.openImageModal(imageUrl, att.filename, att.filename);
        }
      };
    } else if (isPreviewableType(att.mimeType)) {
      link.href = attachmentFileURL(att.fileId, att.filename, true);
      link.removeAttribute("download");
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.onclick = (e) => {
        e.stopPropagation();
        closeAttachmentPopover();
      };
    } else {
      link.onclick = (e) => {
        e.stopPropagation();
        closeAttachmentPopover();
      };
    }

    // Size
    const sizeSpan = document.createElement("span");
    sizeSpan.className = "attachment-popover-size";
    sizeSpan.textContent = size;

    item.appendChild(typeBadge);
    item.appendChild(link);
    item.appendChild(sizeSpan);
    list.appendChild(item);
  }

  popover.appendChild(list);
  activeAttachmentPopover = popover;
  activeAttachmentPopoverAnchor = anchorElement;
  activeAttachmentPopoverPortal = Portal.create(popover, anchorElement, {
    position: "bottom", align: "left", matchWidth: false, offsetY: 4, flipIfNeeded: true,
  });
  activeAttachmentPopoverPortal.show();

  // Click outside to close
  setTimeout(() => {
    if (activeAttachmentPopover !== popover) return;
    document.addEventListener("click", handlePopoverClickOutside);
    document.addEventListener("keydown", handlePopoverEscape);
  }, 0);
}

function closeAttachmentPopover() {
  if (activeAttachmentPopover) {
    activeAttachmentPopoverPortal?.destroy();
    activeAttachmentPopover = null;
    activeAttachmentPopoverPortal = null;
    activeAttachmentPopoverAnchor = null;
    document.removeEventListener("click", handlePopoverClickOutside);
    document.removeEventListener("keydown", handlePopoverEscape);
  }
}

function handlePopoverClickOutside(e) {
  if (activeAttachmentPopover &&
      !activeAttachmentPopover.contains(e.target) &&
      !activeAttachmentPopoverAnchor?.contains(e.target)) {
    closeAttachmentPopover();
  }
}

function handlePopoverEscape(e) {
  if (e.key === "Escape") {
    closeAttachmentPopover();
  }
}
