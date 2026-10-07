// =============================================================================
// NRC NOTES MODULE
// =============================================================================
// Notes as assets with JSON preview format for efficient list rendering.
// Preview: JSON { title, teaser, project, tags, format }
// Payload: Full Markdown or HTML content (fetched on demand)

// =============================================================================
// STATE
// =============================================================================

let notesViewActive = false;
let selectedNoteId = null;
let selectedNoteConvId = null;
let noteListNavigationGeneration = 0;
let currentDetailNote = null;
let noteEditMode = false;
let notePreviewMode = false;
// The note panel's message block closes to one register line; the panel
// re-renders on every comment change, so its open state lives here.
let noteMessagesOpen = null; // Until toggled, open only when comments exist.
let noteSectionsOpen = false;
let noteComposerOpen = false;
let noteComposerDraft = "";
let noteMessagesController = null;
// Resource registers (attachments, links) collapse to one line each so the
// note body keeps the panel.
let noteResourceOpen = {};
let pendingNoteCommentFocusAssetId = null;
let noteEditOriginalPreview = "";
let noteEditOriginalPayload = "";
// Dirty-state tracking for the note edit panel: true once any field is
// modified. Closing/switching while dirty prompts a discard confirmation.
let noteDetailDirty = false;
let noteDetailSaveGeneration = 0;
let initializingNoteAttachments = false;

document.addEventListener("nrc:attachments-changed", () => {
  if (document.querySelector('[data-attachment-editor]')) return;
  if (initializingNoteAttachments || !currentDetailNote || !noteEditMode) return;
  if (!document.getElementById("noteDetailSave")) return;
  setNoteDetailDirty(true);
});
let sharedNoteRoute = null;
let sharedNoteAsset = null;
let sharedNoteEdges = [];
let sharedNoteLoading = false;
let sharedNoteLoadSeq = 0;
let sharedNoteExportFormat = "";
let searchServiceAvailable = null; // null = unknown, true/false after first probe
let notesSearch = null;
let noteKeyboardSelectionTimer = null;
let noteHoverPrefetchTimer = null;
let noteNeighborPrefetchTimer = null;
let pendingNotePageNavigation = null;
let selectedNoteRow = null;
const noteRowsByIdentity = new Map();
let renderedNotesRoomId = null;
let notesListDirty = true;

const NOTES_PAGE_SIZE = 25;
const ESTIMATED_NOTE_ROW_HEIGHT = 28;
const NOTE_KEYBOARD_DETAIL_DELAY_MS = 75;
const notesPaginationByRoom = new Map();

// Project filter state
let notesProjectFilter = null; // null = ALL, string = selected project name
let notesProjectsByRoom = new Map(); // convId -> Set(project names)
let notesTagFilter = null; // null = ALL, string = selected tag name
let notesTagsByRoom = new Map(); // convId -> Set(tag names)

// =============================================================================
// PREVIEW FORMAT
// =============================================================================

const MAX_TEASER_LENGTH = 200;

function normalizeNoteTags(tags) {
  const result = [];
  const seen = new Set();
  for (const rawTag of tags || []) {
    const tag = String(rawTag || "").trim();
    if (!tag || seen.has(tag)) continue;
    seen.add(tag);
    result.push(tag);
  }
  return result;
}

function parseNoteTagsInput(value) {
  return normalizeNoteTags(String(value || "").split(","));
}

function formatNoteTags(tags) {
  return normalizeNoteTags(tags).join(", ");
}

function normalizeNoteFormat(format) {
  return window.NRCHTMLNotes?.normalizeFormat(format) || "markdown";
}

function createNotePreview(title, content, project = "", tags = [], format = "markdown") {
  format = normalizeNoteFormat(format);
  const teaser = generateTeaser(content, format);
  return JSON.stringify({
    title,
    teaser,
    project: String(project || "").trim(),
    tags: normalizeNoteTags(tags),
    format,
  });
}

function parseNotePreview(preview) {
  if (!preview) return { title: "", teaser: "", project: "", tags: [], format: "markdown" };
  
  try {
    const parsed = JSON.parse(preview);
    return {
      title: parsed.title || "",
      teaser: parsed.teaser || "",
      project: typeof parsed.project === "string" ? parsed.project.trim() : "",
      tags: Array.isArray(parsed.tags) ? normalizeNoteTags(parsed.tags) : [],
      format: normalizeNoteFormat(parsed.format),
    };
  } catch {
    // Legacy format: plain text title, no teaser
    return { title: preview, teaser: "", project: "", tags: [], format: "markdown" };
  }
}

function patchNotePreview(preview, changes) {
  let parsed = {};
  try {
    const candidate = JSON.parse(preview || "{}");
    if (candidate && typeof candidate === "object" && !Array.isArray(candidate)) parsed = candidate;
  } catch {
    parsed.title = preview || "";
  }
  return JSON.stringify({ ...parsed, ...changes });
}

// A transaction ACK contains only IDs; the requester receives no asset broadcast.
// Hold the per-note write barrier through the authoritative read, including for
// attachments, whose legacy update sends the entire saved asset.
const noteWritesInFlight = new Set();

function readNoteForWrite(note) {
  return new Promise((resolve, reject) => {
    const sent = window.NRCAssets.sendGetAsset(note.convId, note.assetId, {
      onSuccess: ({ asset }) => resolve(asset),
      onError: detail => reject(new Error(detail?.message || "NOTE REFRESH FAILED")),
    });
    if (!sent) reject(new Error("NOT CONNECTED"));
  });
}

async function writeNote(note, send) {
  const key = `${note.convId}:${note.assetId}`;
  if (noteWritesInFlight.has(key) || noteMarkdownUpdates.has(key)) throw new Error("NOTE SAVE IN PROGRESS — RETRY WHEN SAVED");
  noteWritesInFlight.add(key);
  try {
    // Also reconciles after a conflict or an unconfirmed previous write.
    const current = await readNoteForWrite(note);
    await new Promise((resolve, reject) => {
      const sent = send(current, {
        onSuccess: resolve,
        onError: detail => reject(new Error(detail?.message || "NOTE UPDATE FAILED")),
      });
      if (!sent) reject(new Error("NOT CONNECTED"));
    });
    const saved = await readNoteForWrite(note);
    // Ordinary GETs are not mutations. This read completed a local write, so
    // invalidate filtered lists/options and member snapshots exactly once here.
    handleNoteChanged(saved, "updated", current);
    window.NRCSlices?.onAssetChanged(saved, "mutation", 0);
    return saved;
  } finally {
    noteWritesInFlight.delete(key);
  }
}

function saveNoteMetadata(note, field, value) {
  let normalized;
  if (field === "title") {
    normalized = String(value || "").trim();
    if (!normalized) return Promise.reject(new Error("Title is required"));
    if (new TextEncoder().encode(normalized).length > 256) return Promise.reject(new Error("Title exceeds 256 bytes"));
  } else if (field === "tags") {
    normalized = parseNoteTagsInput(value);
  } else if (field === "project") {
    normalized = String(value || "").trim();
  } else {
    return Promise.reject(new Error(`Unsupported note field: ${field}`));
  }
  return writeNote(note, (current, callbacks) => window.NRCTransactions.sendAssetMetadataPatch(
    current, patchNotePreview(current.preview, { [field]: normalized }), null, callbacks,
  ));
}

function noteFieldControl(note, field, { label, rename = false } = {}) {
  if (!window.NRCDetailUI?.inlineField) return "";
  const metadata = parseNotePreview(note.preview);
  const value = field === "tags" ? formatNoteTags(metadata.tags) : String(metadata[field] || "");
  return window.NRCDetailUI.inlineField({
    key: `note-${note.convId}-${note.assetId}-${field}`,
    label: label ?? field.toUpperCase(),
    name: field.toUpperCase(),
    value,
    display: rename ? "RENAME" : undefined,
    maxBytes: field === "title" ? 256 : undefined,
    required: field === "title",
    save: nextValue => saveNoteMetadata(note, field, nextValue),
  });
}

function noteAttachmentsControl(note) {
  return window.NRCDetailUI.attachmentControl?.(note, attachments => writeNote(note, (current, callbacks) =>
    window.NRCAssets.sendUpdateAsset(current.convId, current.assetId, current.preview, current.payload,
      window.NRCAssets.AssetType.Note, 0, callbacks, attachments),
  ), () => getCanonicalNote(note)) || "";
}

function generateTeaser(content, format = "markdown") {
  if (!content) return "";

  if (normalizeNoteFormat(format) === "html") {
    const doc = new DOMParser().parseFromString(String(content), "text/html");
    doc.querySelectorAll("script, style, noscript, template").forEach((node) => node.remove());
    const text = String(doc.body.textContent || "").replace(/\s+/g, " ").trim();
    return text.length <= MAX_TEASER_LENGTH
      ? text
      : `${text.slice(0, MAX_TEASER_LENGTH).trim()}…`;
  }

  // Strip markdown syntax for cleaner teaser
  let text = content
    .replace(/^#+\s+/gm, "")           // Headers
    .replace(/\*\*([^*]+)\*\*/g, "$1") // Bold
    .replace(/\*([^*]+)\*/g, "$1")     // Italic
    .replace(/__([^_]+)__/g, "$1")     // Bold alt
    .replace(/_([^_]+)_/g, "$1")       // Italic alt
    .replace(/`([^`]+)`/g, "$1")       // Inline code
    .replace(/```[\s\S]*?```/g, "")    // Code blocks
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1") // Links
    .replace(/!\[[^\]]*\]\([^)]+\)/g, "")    // Images
    .replace(/^\s*[-*+]\s+/gm, "")     // List markers
    .replace(/^\s*\d+\.\s+/gm, "")     // Numbered lists
    .replace(/^\s*>\s+/gm, "")         // Blockquotes
    .replace(/\n+/g, " ")              // Newlines to spaces
    .replace(/\s+/g, " ")              // Multiple spaces
    .trim();
  
  if (text.length <= MAX_TEASER_LENGTH) return text;
  return text.slice(0, MAX_TEASER_LENGTH).trim() + "…";
}

// =============================================================================
// ASSET SYSTEM INTEGRATION
// =============================================================================

function getNotesPaginationState(convId) {
  if (!notesPaginationByRoom.has(convId)) {
    notesPaginationByRoom.set(convId, {
      loading: false,
      initialized: false,
      hasMore: true,
      nextCursorUpdatedAt: null,
      nextCursorAssetId: null,
      totalCount: null,
    });
  }
  return notesPaginationByRoom.get(convId);
}

function clearRoomNoteAssets(convId) {
  const roomMap = window.NRCAssets?.roomAssets?.get(convId);
  if (!roomMap) return;

  invalidateNotesList(convId);
  for (const [assetId, asset] of roomMap.entries()) {
    if (asset.assetType === window.NRCAssets.AssetType.Note) {
      roomMap.delete(assetId);
    }
  }
}

function resetNotesPagination(convId, { clearAssets = false } = {}) {
  const state = getNotesPaginationState(convId);
  state.loading = false;
  state.initialized = false;
  state.hasMore = true;
  state.nextCursorUpdatedAt = null;
  state.nextCursorAssetId = null;
  state.totalCount = null;

  if (clearAssets) {
    clearRoomNoteAssets(convId);
  }
}

function fetchNotesPage(convId, { reset = false } = {}) {
  const state = getNotesPaginationState(convId);
  if (state.loading && !reset) return;

  if (reset) {
    // Notes render from the room asset cache. When the project scope changes,
    // keep the cache aligned with the current page set instead of mixing in
    // notes loaded by a previous ALL/project query.
    resetNotesPagination(convId, { clearAssets: true });
  } else if (state.initialized && !state.hasMore) {
    return;
  }

  state.loading = true;

  if (notesTagFilter && window.NRCAssets?.sendListAssetsPagedByTag) {
    window.NRCAssets.sendListAssetsPagedByTag(
      convId,
      window.NRCAssets.AssetType.Note,
      notesTagFilter,
      false,
      NOTES_PAGE_SIZE,
      state.nextCursorUpdatedAt,
      state.nextCursorAssetId,
    );
  } else if (notesProjectFilter && window.NRCAssets?.sendListAssetsPagedByProject) {
    window.NRCAssets.sendListAssetsPagedByProject(
      convId,
      window.NRCAssets.AssetType.Note,
      notesProjectFilter,
      false,
      NOTES_PAGE_SIZE,
      state.nextCursorUpdatedAt,
      state.nextCursorAssetId,
    );
  } else if (window.NRCAssets?.sendListAssetsPaged) {
    window.NRCAssets.sendListAssetsPaged(
      convId,
      window.NRCAssets.AssetType.Note,
      false,
      NOTES_PAGE_SIZE,
      state.nextCursorUpdatedAt,
      state.nextCursorAssetId,
    );
  }

  if (notesViewActive && convId === 0n) {
    renderNotesView();
  }
}

function pauseNotesPageLoader() {
  document.querySelector("#notesList nrc-page-loader")?.setState({ active: false });
}

function sendCreateNote(title, content = "", correlationId = 0, project = "", tags = [], format = "markdown") {
  const preview = createNotePreview(title, content, project, tags, format);
  window.NRCAssets.sendCreateAsset(
    0n,
    window.NRCAssets.AssetType.Note,
    window.NRCAssets.ParentType.None,
    0n,
    preview,
    content,
    correlationId,
  );
}

function sendUpdateNote(
  convId,
  assetId,
  title,
  content = "",
  project = "",
  tags = [],
  attachments = [],
  requestOptions = null,
  format = "markdown",
) {
  const preview = createNotePreview(title, content, project, tags, format);
  return window.NRCAssets.sendUpdateAsset(
    convId,
    assetId,
    preview,
    content,
    window.NRCAssets.AssetType.Note,
    0,
    requestOptions,
    attachments,
  );
}

const noteMarkdownUpdates = new Map();

function getNoteMarkdownUpdateKey(note) {
  return `${note.convId}:${note.assetId}`;
}

function getCanonicalNote(note) {
  return window.NRCAssets?.roomAssets?.get(note.convId)?.get(note.assetId) || note;
}

function getNoteMarkdown(note) {
  return noteMarkdownUpdates.get(getNoteMarkdownUpdateKey(note))?.draft ?? note.payload ?? "";
}

function renderSelectedNoteMarkdown(note) {
  if (
    isSelectedNote(note.convId, note.assetId) &&
    currentDetailNote?.convId === note.convId &&
    notePreviewMode
  ) {
    showNotePreviewPanel(note);
  }
}

function sendPendingNoteMarkdown(state, authoritativeNote) {
  const sentMarkdown = state.draft;
  const { title, project, tags } = parseNotePreview(authoritativeNote.preview);
  state.inFlight = true;

  const correlationId = sendUpdateNote(
    authoritativeNote.convId,
    authoritativeNote.assetId,
    title,
    sentMarkdown,
    project,
    tags,
    authoritativeNote.attachments || [],
    {
      context: `update note #${authoritativeNote.assetId} checkbox`,
      onSuccess: (detail) => {
        if (noteMarkdownUpdates.get(state.key) !== state) return;
        state.inFlight = false;
        if (state.draft !== sentMarkdown) {
          sendPendingNoteMarkdown(state, detail.asset);
        } else {
          noteMarkdownUpdates.delete(state.key);
          renderSelectedNoteMarkdown(detail.asset);
        }
      },
      onError: () => {
        if (noteMarkdownUpdates.get(state.key) !== state) return;
        noteMarkdownUpdates.delete(state.key);
        const canonical = getCanonicalNote(authoritativeNote);
        renderSelectedNoteMarkdown(canonical);
        notifyNoteSaveError("NOTE CHECKBOX UPDATE FAILED; REFRESHING NOTE");
        window.NRCAssets.sendGetAsset(authoritativeNote.convId, authoritativeNote.assetId);
      },
    },
  );

  if (!correlationId) {
    noteMarkdownUpdates.delete(state.key);
    renderSelectedNoteMarkdown(getCanonicalNote(authoritativeNote));
    notifyNoteSaveError("NOT CONNECTED; NOTE CHECKBOX WAS NOT UPDATED");
  }
}

function queueNoteMarkdownUpdate(note, markdown) {
  const key = getNoteMarkdownUpdateKey(note);
  if (noteWritesInFlight.has(key)) {
    renderSelectedNoteMarkdown(getCanonicalNote(note));
    notifyNoteSaveError("NOTE SAVE IN PROGRESS — RETRY WHEN SAVED");
    return;
  }
  let state = noteMarkdownUpdates.get(key);
  if (!state) {
    state = { key, draft: getNoteMarkdown(note), inFlight: false };
    noteMarkdownUpdates.set(key, state);
  }
  state.draft = markdown;
  renderSelectedNoteMarkdown(getCanonicalNote(note));
  if (!state.inFlight) sendPendingNoteMarkdown(state, getCanonicalNote(note));
}

function sendDeleteNote(convId, assetId) {
  window.NRCAssets.sendDeleteAsset(convId, assetId);
}

function getNotesForRoom(convId) {
  return window.NRCAssets.getAssetsByType(convId, window.NRCAssets.AssetType.Note)
    .sort((a, b) => {
      if (a.updatedAt > b.updatedAt) return -1;
      if (a.updatedAt < b.updatedAt) return 1;
      return a.assetId > b.assetId ? -1 : a.assetId < b.assetId ? 1 : 0;
    });
}

// =============================================================================
// VIEW TOGGLE
// =============================================================================

function toggleNotesView() {
  if (notesViewActive) {
    hideNotesView();
  } else {
    showNotesView();
  }
}

function showNotesView() {
  if (window.NRCViewManager) {
    window.NRCViewManager.setActiveView("notes");
  }

  const state = getNotesPaginationState(0n);
  if (!state.initialized && !state.loading) {
    fetchNotesPage(0n, { reset: true });
  }

  // Refresh project list for dropdown
  if (window.NRCAssets?.sendListNoteProjects) {
    window.NRCAssets.sendListNoteProjects(0n);
  }
  if (window.NRCAssets?.sendListNoteTags) {
    window.NRCAssets.sendListNoteTags(0n);
  }

  renderNotesViewIfNeeded();
}

function hideNotesView() {
  pauseNotesPageLoader();
  notesSearch?.cancel();

  if (window.NRCViewManager) {
    window.NRCViewManager.setActiveView("chat");
  }
}

// =============================================================================
// RENDERING
// =============================================================================

function invalidateNotesList(convId) {
  if (renderedNotesRoomId === convId) notesListDirty = true;
}

function renderNotesViewIfNeeded() {
  const searchTerm = (document.getElementById("notesSearch")?.value || "").trim();
  if (searchTerm) {
    renderNotesView();
    return;
  }
  if (!notesListDirty && renderedNotesRoomId === 0n) {
    document.querySelector("#notesList nrc-page-loader")?.setState({ active: notesViewActive });
    return;
  }
  renderNotesView();
}

function renderNotesView({ append = false, debounce = false } = {}) {
  window.NRCColumnResize?.init({
    root: ".notes-container", headers: ".notes-list-header > div", storageKey: "nrc.note.columns.v3",
    // Keep the hidden slot so saved data-column widths retain their indexes.
    defaults: [0, 48, 260, 130, 170, 110, 72, 72],
    minimums: [16, 48, 140, 88, 104, 80, 56, 56],
    locked: [0],
    apply: (container, widths) => container.style.setProperty("--note-columns", widths.map((width) => `${width}px`).join(" ")),
  });
  const notesList = document.getElementById("notesList");
  if (!notesList) return;

  const notesSearchInput = document.getElementById("notesSearch");
  const searchTerm = (notesSearchInput?.value || "").trim();

  if (searchTerm && searchServiceAvailable !== false) {
    pauseNotesPageLoader();
    renderNotesSearchResults(notesList, searchTerm, { debounce });
  } else {
    notesSearch?.cancel();
    renderNotesLocal(notesList, searchTerm, { append });
  }
  renderedNotesRoomId = 0n;
  notesListDirty = false;
}

function renderNotesLocal(notesList, searchTerm, { append = false } = {}) {
  if (!notesList.virtualList) {
    window.NRCVirtualList?.capture(notesList, document.querySelector("#notesPanel .notes-container"),
      notesList.querySelectorAll(".note-card"), (row) => `${row.dataset.convId}:${row.dataset.noteId}`);
  }
  if (notesList.virtualList) {
    notesList.virtualList.destroy();
    notesList.virtualList = null;
    append = false;
  }
  if (!append) {
    selectedNoteRow = null;
    noteRowsByIdentity.clear();
    notesList.innerHTML = "";
  } else {
    for (const emptyState of notesList.querySelectorAll(".notes-empty")) {
      emptyState.remove();
    }
  }
  const pageState = getNotesPaginationState(0n);

  const allNotes = getNotesForRoom(0n);
  const searchLower = searchTerm.toLowerCase();

  const notes = allNotes.filter((note) => {
    const { title, teaser, project, tags } = parseNotePreview(note.preview);
    if (notesProjectFilter !== null && project !== notesProjectFilter) return false;
    if (notesTagFilter !== null && !tags.includes(notesTagFilter)) return false;
    if (searchLower) {
      const titleMatch = title.toLowerCase().includes(searchLower);
      const teaserMatch = teaser.toLowerCase().includes(searchLower);
      const projectMatch = project.toLowerCase().includes(searchLower);
      const tagMatch = tags.some((tag) => tag.toLowerCase().includes(searchLower));
      if (!titleMatch && !teaserMatch && !projectMatch && !tagMatch) return false;
    }
    return true;
  });

  if (pageState.loading && !pageState.initialized && notes.length === 0) {
    notesList.innerHTML = '<div class="notes-empty">LOADING NOTES…</div>';
    updateNotesCount(0);
    return;
  }

  if (notes.length === 0) {
    notesList.innerHTML = '<div class="notes-empty">NO NOTES</div>';
    updateNotesCount(0);
    pauseNotesPageLoader();
    return;
  }

  removeNotesPaginationControls(notesList);

  if (searchLower && searchServiceAvailable === false && pageState.hasMore) {
    const limitedNotice = document.createElement("div");
    limitedNotice.className = "notes-search-limited";
    limitedNotice.textContent = "LOCAL SEARCH SHOWS LOADED NOTES ONLY";
    notesList.appendChild(limitedNotice);
  }

  const existingIds = new Set();
  if (append) {
    for (const el of notesList.querySelectorAll(".note-card")) {
      if (el.dataset.noteId) {
        existingIds.add(el.dataset.noteId);
      }
    }
  }

  if (window.NRCVirtualList && notes.length > 100) {
    // Pagination can cross the threshold from a previously non-virtual list.
    if (append) {
      for (const row of notesList.querySelectorAll(".note-card")) row.remove();
      noteRowsByIdentity.clear();
      selectedNoteRow = null;
    }
    notesList.virtualList = window.NRCVirtualList.create({
      host: notesList,
      scroller: document.querySelector("#notesPanel .notes-container"),
      items: notes,
      render: createNoteCard,
      key: (note) => `${note.convId}:${note.assetId}`,
      dispose: (row) => {
        noteRowsByIdentity.delete(`${row.dataset.convId}:${row.dataset.noteId}`);
        if (selectedNoteRow === row) selectedNoteRow = null;
      },
    });
  } else {
    for (const note of notes) {
      if (append && existingIds.has(note.assetId.toString())) continue;
      notesList.appendChild(createNoteCard(note));
    }
  }

  renderNotesPaginationControls(notesList, pageState, allNotes.length);

  const displayCount = searchLower.length === 0 && Number.isFinite(pageState.totalCount)
    ? pageState.totalCount
    : notes.length;
  updateNotesCount(displayCount);
}

function removeNotesPaginationControls(notesList) {
  const controls = notesList.querySelector(".notes-pagination-controls");
  if (controls) {
    controls.remove();
  }
  const spacer = notesList.querySelector(".notes-unloaded-spacer");
  if (spacer) {
    spacer.remove();
  }
}

function getEstimatedNoteRowHeight(notesList) {
  const row = notesList.querySelector(".note-card");
  if (!row) return ESTIMATED_NOTE_ROW_HEIGHT;

  const height = row.getBoundingClientRect().height;
  return height > 0 ? height : ESTIMATED_NOTE_ROW_HEIGHT;
}

function renderNotesPaginationControls(notesList, pageState, loadedCount) {
  if (!pageState.hasMore && !pageState.loading) {
    return;
  }

  const controls = document.createElement("nrc-page-loader");
  controls.className = "notes-pagination-controls";
  const button = document.createElement("button");
  button.id = "notesLoadMoreBtn";
  controls.appendChild(button);
  controls.setState({
    hasMore: pageState.hasMore, loading: pageState.loading, active: notesViewActive,
    root: document.querySelector("#notesPanel .notes-container"),
  });
  controls.addEventListener("nrc:load-more", () => {
    if (notesViewActive) fetchNotesPage(0n);
  });
  notesList.appendChild(controls);

  if (Number.isFinite(pageState.totalCount) && pageState.totalCount > loadedCount) {
    const unloadedCount = pageState.totalCount - loadedCount;
    const spacer = document.createElement("div");
    spacer.className = "notes-unloaded-spacer";
    spacer.setAttribute("aria-hidden", "true");
    spacer.style.height = `${Math.max(0, unloadedCount * getEstimatedNoteRowHeight(notesList))}px`;
    notesList.appendChild(spacer);
  }
}

function renderNotesSearchResults(notesList, query, { debounce = false } = {}) {
  pauseNotesPageLoader();
  notesSearch ||= window.NRCSearch.createController();
  notesSearch.search({ query, top_n: 10, asset_types: [5] }, {
    debounce: debounce ? 250 : 0,
    onResult: (data) => {
      searchServiceAvailable = true;
      const results = data.results;

      notesList.virtualList?.destroy();
      notesList.virtualList = null;
      selectedNoteRow = null;
      noteRowsByIdentity.clear();
      notesList.innerHTML = "";

      if (results.length === 0) {
        notesList.innerHTML = '<div class="notes-empty">NO RESULTS</div>';
        updateNotesCount(0);
        return;
      }

      // Build a lookup from local assets for metadata (owner, timestamps)
      const localNotes = new Map();
      for (const note of getNotesForRoom(0n)) {
        localNotes.set(note.assetId, note);
      }

      for (const result of results) {
        const assetId = BigInt(result.asset_id);
        const localNote = localNotes.get(assetId);

        // Use local note if available (has full metadata), fall back to search result preview
        const note = localNote || {
          assetId,
          convId: 0n,
          preview: result.preview,
          owner: "",
          createdAt: 0n,
          updatedAt: 0n,
        };

        const card = createNoteCard(note);
        notesList.appendChild(card);
      }

      updateNotesCount(results.length);
    },
    onError: (err) => {
      // Search service unavailable — fall back to local filtering
      console.warn("[NRCNotes] search service unavailable, falling back to local search:", err.message);
      searchServiceAvailable = false;
      renderNotesLocal(notesList, query);
    },
  });
}

function updateNotesCount(count) {
  const notesCountElement = document.getElementById("notesCount");
  if (notesCountElement) {
    notesCountElement.textContent = `${count} RESULTS`;
  }
  window.NRCInspector?.refreshContext();
}

function createNoteCard(note) {
  const { title, project, tags } = parseNotePreview(note.preview);
  
  const card = document.createElement("div");
  card.className = "note-card";
  const isSelected = isSelectedNote(note.convId, note.assetId);
  if (isSelected) {
    card.classList.add("note-selected");
  }
  card.dataset.noteId = note.assetId.toString();
  card.dataset.convId = note.convId.toString();
  noteRowsByIdentity.set(`${card.dataset.convId}:${card.dataset.noteId}`, card);
  if (isSelected) selectedNoteRow = card;

  const markerEl = document.createElement("div");
  markerEl.className = "note-marker";
  markerEl.textContent = isSelected ? "›" : "";
  card.appendChild(markerEl);

  const idEl = document.createElement("div");
  idEl.className = "note-id";
  idEl.textContent = note.assetId.toString();
  idEl.title = `Note #${note.assetId}`;
  card.appendChild(idEl);

  // Header
  const header = document.createElement("div");
  header.className = "note-header";

  const titleEl = document.createElement("div");
  titleEl.className = "note-title";
  titleEl.innerHTML = `<button type="button" class="task-row-open">${escapeHtml(title || "(No title)")}</button>${noteFieldControl(note, "title", { label: "", rename: true })}`;
  titleEl.title = title || "(No title)";
  header.appendChild(titleEl);

  card.appendChild(header);

  const projectEl = document.createElement("div");
  projectEl.className = "note-project";
  projectEl.innerHTML = noteFieldControl(note, "project", { label: "" }) || escapeHtml(project || "—");
  projectEl.title = project || "No project";
  card.appendChild(projectEl);

  const tagsEl = document.createElement("div");
  tagsEl.className = "note-tags";
  const tagsText = normalizeNoteTags(tags).join(" · ");
  tagsEl.innerHTML = noteFieldControl(note, "tags", { label: "" }) || escapeHtml(tagsText || "—");
  tagsEl.title = tagsText || "No tags";
  card.appendChild(tagsEl);

  const ownerEl = document.createElement("div");
  ownerEl.className = "note-owner";
  ownerEl.textContent = note.owner || "—";
  ownerEl.title = note.owner || "No owner";
  card.appendChild(ownerEl);

  const body = document.createElement("div");
  body.className = "note-body";

  const createdStr = typeof formatRelativeAge === "function" ? formatRelativeAge(note.createdAt) : formatNoteTimestamp(note.createdAt);
  body.textContent = createdStr;
  body.title = `Created ${formatNoteTimestamp(note.createdAt)}`;

  card.appendChild(body);

  const updatedEl = document.createElement("div");
  updatedEl.className = "note-updated";
  const updatedStr = note.updatedAt && typeof formatRelativeAge === "function" ? formatRelativeAge(note.updatedAt) : formatNoteTimestamp(note.updatedAt);
  updatedEl.textContent = updatedStr && updatedStr !== createdStr ? updatedStr : "—";
  updatedEl.title = note.updatedAt ? `Updated ${formatNoteTimestamp(note.updatedAt)}` : "Not updated";
  card.appendChild(updatedEl);

  const prefetch = () => window.NRCInspector?.prefetchNote?.({ roomId: note.convId, id: note.assetId });
  card.addEventListener("pointerenter", (event) => {
    if (event.pointerType === "touch") return;
    clearTimeout(noteHoverPrefetchTimer);
    noteHoverPrefetchTimer = setTimeout(() => {
      if (notesViewActive && card.isConnected) prefetch();
    }, 50);
  });
  card.addEventListener("pointerleave", () => clearTimeout(noteHoverPrefetchTimer));
  card.addEventListener("focusin", prefetch);

  // Click to select and fetch full content; guard against discarding unsaved
  // edits in the currently-open note editor.
  card.addEventListener("click", async () => {
    const wasDirty = noteDetailDirty;
    if (await confirmDiscardNoteEditsIfDirty()) {
      if (wasDirty) setNoteDetailDirty(false);
      selectNote(note);
    }
  });

  return card;
}

function formatNoteTimestamp(nanos) {
  if (!nanos || nanos === 0n) return "—";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  return date.toLocaleString();
}

function formatNoteCommentTime(nanos) {
  if (!nanos) return "";
  const ms = Number(nanos / 1000000n);
  const date = new Date(ms);
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `${hours}:${minutes}`;
}

function getNoteComments(note) {
  if (!note || !window.NRCAssets?.getCommentsForAsset) return [];
  return window.NRCAssets.getCommentsForAsset(note.convId, note.assetId);
}

function renderNoteMessagesHtml(note) {
  return window.NRCDetailUI.renderMessages({
    comments: getNoteComments(note),
    currentUser: myNickname,
    formatTime: formatNoteCommentTime,
  });
}

function noteMessagesAreaHtml(note) {
  const comments = getNoteComments(note);
  return window.NRCDetailUI.renderMessagesArea({
    messagesHtml: renderNoteMessagesHtml(note),
    count: comments.length,
    preview: window.NRCDetailUI.messagePreview(comments),
    persistent: true,
    open: noteMessagesOpen ?? comments.length > 0,
    composerOpen: noteComposerOpen,
    draft: noteComposerDraft,
    inputId: "noteCommentInput",
    sendId: "noteCommentSend",
  });
}

function tryFocusPendingNoteCommentInDetailPanel() {
  if (pendingNoteCommentFocusAssetId == null) return;
  noteMessagesController?.open();
  const target = document.querySelector(`.record-message[data-asset-id="${String(pendingNoteCommentFocusAssetId)}"]`);
  if (!target) return;
  target.scrollIntoView({ block: "nearest" });
  target.classList.add("highlighted");
  setTimeout(() => target.classList.remove("highlighted"), 1200);
  pendingNoteCommentFocusAssetId = null;
}

function initNoteCommentEventHandlers(note) {
  noteMessagesController = window.NRCDetailUI.bindMessagesArea({
    root: document.querySelector(".agenda-panel .agenda-content"),
    inputId: "noteCommentInput",
    sendId: "noteCommentSend",
    onSubmit: (text) => window.NRCAssets.sendCreateAssetComment(note.convId, note.assetId, text),
    onDelete: (assetId) => window.NRCAssets.sendDeleteComment(note.convId, BigInt(assetId)),
    onToggle: ({ messagesOpen, composerOpen, draft }) => {
      noteMessagesOpen = messagesOpen;
      noteComposerOpen = composerOpen;
      noteComposerDraft = draft ?? "";
    },
    focusPending: pendingNoteCommentFocusAssetId != null,
  });

  tryFocusPendingNoteCommentInDetailPanel();
}

// =============================================================================
// AUTHENTICATED READ-ONLY NOTE SHARE VIEW
// =============================================================================

function showSharedNoteView(route) {
  sharedNoteRoute = route;
  sharedNoteAsset = null;
  sharedNoteEdges = [];
  sharedNoteLoading = false;

  if (window.NRCViewManager) {
    window.NRCViewManager.setActiveView("noteShare");
  }

  renderSharedNoteView("LOADING NOTE…");
}

function loadSharedNoteView(route = sharedNoteRoute) {
  if (!route || !window.NRCAssets?.sendGetAsset) return;
  sharedNoteRoute = route;
  sharedNoteAsset = null;
  sharedNoteEdges = [];
  sharedNoteLoading = true;
  sharedNoteLoadSeq += 1;
  const loadSeq = sharedNoteLoadSeq;
  renderSharedNoteView("LOADING NOTE…");

  window.NRCAssets.sendGetAsset(route.convId, route.assetId, {
    context: `SHARE NOTE #${route.assetId}`,
    onSuccess: (detail) => {
      if (loadSeq !== sharedNoteLoadSeq) return;
      const asset = detail?.asset;
      if (!asset || asset.assetType !== window.NRCAssets.AssetType.Note) {
        sharedNoteLoading = false;
        renderSharedNoteView("NOTE NOT FOUND");
        return;
      }

      sharedNoteAsset = asset;
      sharedNoteLoading = false;
      renderSharedNoteView();
      loadSharedNoteEdges(asset);
    },
    onError: () => {
      if (loadSeq !== sharedNoteLoadSeq) return;
      sharedNoteLoading = false;
      renderSharedNoteView("NOTE NOT FOUND");
    },
  });
}

function loadSharedNoteEdges(note) {
  if (!note || !window.NRCEdges?.sendListEdges) return;

  window.NRCEdges.sendListEdges(note.convId, window.NRCEdges.TargetType.Asset, note.assetId, {
    context: `SHARE NOTE LINKS #${note.assetId}`,
    onSuccess: (detail) => {
      if (!sharedNoteAsset || sharedNoteAsset.assetId !== note.assetId) return;
      sharedNoteEdges = detail?.edges || [];
      renderSharedNoteView();
      fetchSharedLinkedTargets(note.convId, sharedNoteEdges, note.assetId);
    },
    onError: () => {
      sharedNoteEdges = [];
      renderSharedNoteView();
    },
  });
}

function fetchSharedLinkedTargets(convId, edges, sourceNoteId) {
  if (!window.NRCEdges?.TargetType) return;

  const { TargetType } = window.NRCEdges;
  const roomAssets = window.NRCAssets?.roomAssets?.get(convId);
  const noteIds = new Set();
  const taskIds = new Set();
  const roomTasks = window.NRCTasks?.roomTasks?.get(convId);

  for (const edge of edges || []) {
    const other = getSharedEdgeOtherEndpoint(edge, TargetType.Asset, sourceNoteId);
    if (!other) continue;
    if (other.targetType === TargetType.Task) {
      if (!roomTasks?.has(other.targetId)) taskIds.add(other.targetId);
      continue;
    }
    // FILES owns bounded asset hydration and retry, including non-file assets.
    if (other.targetType !== TargetType.Asset || window.NRCFiles) continue;
    if (roomAssets && roomAssets.has(other.targetId)) continue;
    noteIds.add(other.targetId.toString());
  }

  for (const id of noteIds) {
    window.NRCAssets?.requestAsset?.(convId, BigInt(id), {
      context: `SHARE LINKED NOTE #${id}`,
      onSuccess: () => queueMicrotask(renderSharedNoteView),
    });
  }
  for (const id of taskIds) {
    window.NRCTasks?.requestTask?.(convId, id, {
      onSuccess: () => queueMicrotask(renderSharedNoteView),
    });
  }
}

function getSharedEdgeOtherEndpoint(edge, sourceType, sourceId) {
  if (!edge) return null;
  if (edge.sourceType === sourceType && edge.sourceId === sourceId) {
    return { targetType: edge.targetType, targetId: edge.targetId, direction: "out" };
  }
  if (edge.targetType === sourceType && edge.targetId === sourceId) {
    return { targetType: edge.sourceType, targetId: edge.sourceId, direction: "in" };
  }
  return null;
}

function getSharedLinkedTaskTitle(convId, taskId) {
  const task = window.NRCTasks?.roomTasks?.get(convId)?.get(taskId);
  return task?.title || `TASK #${taskId}`;
}

function getSharedNoteRoomLabel(convId) {
  return "WORKSPACE";
}

function renderSharedNoteView(statusText = "") {
  const panel = document.getElementById("noteSharePanel");
  const headerTitle = document.getElementById("noteShareHeaderTitle");
  const headerMeta = document.getElementById("noteShareHeaderMeta");
  const openBtn = document.getElementById("noteShareOpenNrc");
  const pdfBtn = document.getElementById("noteShareOpenPdf");
  const docxBtn = document.getElementById("noteShareDownloadDocx");
  const content = document.getElementById("noteShareContent");
  if (!panel || !content) return;

  if (openBtn && !openBtn.dataset.bound) {
    openBtn.dataset.bound = "1";
    openBtn.addEventListener("click", openSharedNoteInNrc);
  }
  if (pdfBtn && !pdfBtn.dataset.bound) {
    pdfBtn.dataset.bound = "1";
    pdfBtn.addEventListener("click", () => exportSharedNote("pdf"));
  }
  if (docxBtn && !docxBtn.dataset.bound) {
    docxBtn.dataset.bound = "1";
    docxBtn.addEventListener("click", () => exportSharedNote("docx"));
  }
  updateSharedNoteExportButtons();

  if (headerTitle) {
    headerTitle.textContent = sharedNoteAsset ? `NOTE #${sharedNoteAsset.assetId}` : "NOTE SHARE";
  }

  if (headerMeta) {
    headerMeta.textContent = sharedNoteAsset
      ? `${getSharedNoteRoomLabel(sharedNoteAsset.convId)} · READ ONLY`
      : "READ ONLY";
  }

  if (!sharedNoteAsset) {
    content.innerHTML = `<div class="note-share-status">${escapeHtml(statusText || (sharedNoteLoading ? "LOADING NOTE…" : "NOTE NOT LOADED"))}</div>`;
    return;
  }

  const { title, project, tags, format } = parseNotePreview(sharedNoteAsset.preview);
  window.NRCPageTitle?.set(title || `NOTE #${sharedNoteAsset.assetId}`);
  const tagsHtml = tags.length > 0
    ? tags.map((tag) => `<span class="note-share-tag">${escapeHtml(tag)}</span>`).join("")
    : '<span class="note-share-empty-token">NO TAGS</span>';
  const projectHtml = project
    ? `<span class="note-share-project">${escapeHtml(project)}</span>`
    : '<span class="note-share-empty-token">NO PROJECT</span>';
  const markdownPresentation = sharedNoteAsset.payload
    ? renderNoteMarkdownPresentation(sharedNoteAsset.payload, sharedNoteAsset.attachments || [], format)
    : null;
  const bodyHtml = markdownPresentation && format === "markdown"
    ? markdownPresentation.bodyHtml
    : sharedNoteAsset.payload ? "" : '<em>Empty note.</em>';

  content.innerHTML = `
    <article class="note-share-article">
      <div class="note-share-title">${escapeHtml(title || "(No title)")}</div>
      <div class="note-share-meta">
        ${projectHtml}
        <span>CREATED BY: <span class="identity-actor">${escapeHtml(sharedNoteAsset.owner || "—")}</span></span>
        <span>UPDATED: ${formatNoteTimestamp(sharedNoteAsset.updatedAt)}</span>
      </div>
      <div class="note-share-tags">${tagsHtml}</div>
      <div class="agenda-preview note-share-body" data-note-format="${format}">${bodyHtml}</div>
      <aside class="note-share-sidebar">
        ${renderSharedAmpThreads(markdownPresentation?.ampThreads || [])}
        <section class="note-share-attachments">
          <div class="note-share-section-title">ATTACHMENTS (${(sharedNoteAsset.attachments || []).length})</div>
          ${renderSharedNoteAttachments(sharedNoteAsset.attachments || [])}
        </section>
        <section class="note-share-files"></section>
        <section class="note-share-links">
          <div class="note-share-section-title">LINKED NODES</div>
          ${renderSharedLinkedNodes(sharedNoteAsset, sharedNoteEdges)}
        </section>
      </aside>
    </article>
  `;

  const filesSection = content.querySelector(".note-share-files");
  if (filesSection && window.NRCFiles) {
    window.NRCFiles.renderSection(filesSection, sharedNoteAsset, window.NRCEdges.TargetType.Asset, sharedNoteEdges, {
      readOnly: true,
      onHydrated: () => queueMicrotask(() => renderSharedNoteView()),
    });
  }

  const shareBody = content.querySelector(".note-share-body");
  if (shareBody && format === "html" && sharedNoteAsset.payload) {
    mountHTMLNote(
      shareBody,
      markdownPresentation.bodyHtml,
      sharedNoteAsset.attachments || [],
      title || `Note #${sharedNoteAsset.assetId}`,
    );
  } else if (shareBody) {
    addNoteSectionJumpLedger(shareBody, content);
  }

  content.querySelectorAll(".note-share-body table").forEach((table) => {
    if (table.parentElement?.classList.contains("note-share-table-scroll")) return;
    const wrapper = document.createElement("div");
    wrapper.className = "note-share-table-scroll";
    table.parentNode.insertBefore(wrapper, table);
    wrapper.appendChild(table);
  });

  content.querySelectorAll("button.note-share-link-row[data-type='NOTE']").forEach((row) => {
    row.addEventListener("click", () => {
      if (!row.dataset.id || !sharedNoteAsset) return;
      openSharedLinkedNote(sharedNoteAsset.convId, BigInt(row.dataset.id));
    });
  });

  content.querySelectorAll(".note-share-attachment-row[data-image='1']").forEach((row) => {
    row.addEventListener("click", (e) => {
      e.preventDefault();
      if (!row.dataset.fileId) return;
      const filename = row.dataset.filename || row.dataset.fileId;
      const url = attachmentFileURL(row.dataset.fileId, filename, true);
      if (window.openImageModal) {
        window.openImageModal(url, filename, filename);
      } else {
        window.open(url, "_blank", "noopener,noreferrer");
      }
    });
  });
}

function renderNoteMarkdownWithAttachments(markdown, attachments = []) {
  return parseMarkdown(resolveAttachmentRefs(markdown, attachments));
}

function getAmpThreadReference(value) {
  try {
    const url = new URL(String(value || ""), "https://ampcode.com/");
    if (url.protocol !== "https:" || url.hostname !== "ampcode.com") return null;
    const match = url.pathname.match(/^\/threads\/(T-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\/?$/i);
    if (!match) return null;
    return {
      id: match[1],
      url: `https://ampcode.com/threads/${match[1]}`,
    };
  } catch {
    return null;
  }
}

function isEmptyAmpThreadSourceLine(text, hasContentElement = false) {
  if (hasContentElement) return false;
  return /^(?:(?:(?:sources?|quelle)(?:\s+(?:amp\s+)?threads?)?|amp(?:\s+threads?)?|threads?)\s*:?)?[\s,;|/·.–—-]*$/i.test(
    String(text || "").trim(),
  );
}

const AMP_THREAD_PRESENTATIONAL_ELEMENTS = new Set([
  "B", "BR", "DEL", "EM", "I", "MARK", "S", "SMALL", "SPAN", "STRONG", "SUB", "SUP",
]);

function hasMeaningfulAmpThreadElement(root) {
  return Array.from(root.querySelectorAll("*")).some((element) => (
    !AMP_THREAD_PRESENTATIONAL_ELEMENTS.has(element.tagName)
  ));
}

function cleanupAmpThreadSourceLines(block) {
  const markers = Array.from(block.querySelectorAll("[data-nrc-amp-thread-marker]"));
  markers.forEach((marker) => {
    if (!block.contains(marker)) return;
    let previousBreak = null;
    let nextBreak = null;
    for (const lineBreak of block.querySelectorAll("br")) {
      const position = lineBreak.compareDocumentPosition(marker);
      if (position & Node.DOCUMENT_POSITION_FOLLOWING) {
        previousBreak = lineBreak;
      } else if (position & Node.DOCUMENT_POSITION_PRECEDING) {
        nextBreak = lineBreak;
        break;
      }
    }

    const range = document.createRange();
    if (previousBreak) range.setStartAfter(previousBreak);
    else range.setStart(block, 0);
    if (nextBreak) range.setEndBefore(nextBreak);
    else range.setEnd(block, block.childNodes.length);

    const remainder = range.cloneContents();
    remainder.querySelectorAll("[data-nrc-amp-thread-marker]").forEach((element) => element.remove());
    const isEmptySourceLine = isEmptyAmpThreadSourceLine(
      remainder.textContent,
      hasMeaningfulAmpThreadElement(remainder),
    );
    if (!isEmptySourceLine) {
      marker.remove();
      return;
    }

    range.deleteContents();
    if (nextBreak) nextBreak.remove();
    else if (previousBreak) previousBreak.remove();
  });
}

function renderNoteMarkdownPresentation(markdown, attachments = [], format = "markdown") {
  // Parse full HTML documents inertly so their head, styles and body attributes
  // survive extraction. Only the sandbox renderer mounts the resulting HTML.
  const htmlDocument = format === "html"
    ? new DOMParser().parseFromString(String(markdown || ""), "text/html")
    : null;
  const container = htmlDocument?.body || document.createElement("div");
  if (!htmlDocument) container.innerHTML = renderNoteMarkdownWithAttachments(markdown, attachments);
  const ampThreads = [];
  const seenThreadIds = new Set();
  const cleanupCandidates = new Set();

  container.querySelectorAll("a[href]").forEach((link) => {
    const thread = getAmpThreadReference(link.getAttribute("href"));
    if (!thread) return;
    const key = thread.id.toLowerCase();
    if (!seenThreadIds.has(key)) {
      const linkText = String(link.textContent || "").trim();
      ampThreads.push({
        ...thread,
        label: getAmpThreadReference(linkText) ? thread.id : (linkText || thread.id),
      });
      seenThreadIds.add(key);
    }
    const block = link.closest("p, li");
    if (!block) {
      link.remove();
      return;
    }
    cleanupCandidates.add(block);
    const marker = document.createElement("span");
    marker.dataset.nrcAmpThreadMarker = "";
    link.replaceWith(marker);
  });

  cleanupCandidates.forEach((block) => {
    if (!container.contains(block)) return;
    cleanupAmpThreadSourceLines(block);
    const remainingText = String(block.textContent || "").trim();
    if (!isEmptyAmpThreadSourceLine(remainingText, hasMeaningfulAmpThreadElement(block))) return;
    const list = block.matches("li") ? block.parentElement : null;
    block.remove();
    if (list && !list.querySelector("li")) list.remove();
  });

  return {
    bodyHtml: htmlDocument ? `<!doctype html>\n${htmlDocument.documentElement.outerHTML}` : container.innerHTML,
    ampThreads,
  };
}

function renderNoteAmpThreads(ampThreads) {
  if (!ampThreads || ampThreads.length === 0) return '<div class="note-links-empty">NO AMP THREADS</div>';
  const rows = ampThreads.map((thread) => `
    <div class="note-link-item">
      <span class="note-link-direction">↗</span>
      <span class="note-link-relation">thread</span>
      <a class="note-link-target" href="${escapeHtml(thread.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(thread.label)}</a>
    </div>
  `).join("");
  return `
    <div class="note-links-section note-preview-links note-amp-threads">
      <div class="note-links-header">
        <span class="note-links-label">AMP THREADS (${ampThreads.length})</span>
      </div>
      <div class="note-links-list">${rows}</div>
    </div>
  `;
}

function renderSharedAmpThreads(ampThreads) {
  if (!ampThreads || ampThreads.length === 0) return "";
  const rows = ampThreads.map((thread) => `
    <a class="note-share-link-row" data-type="AMP" href="${escapeHtml(thread.url)}" target="_blank" rel="noopener noreferrer">
      <span class="note-share-link-type">AMP</span>
      <span class="note-share-link-relation">THREAD ↗</span>
      <span class="note-share-link-title">${escapeHtml(thread.label)}</span>
    </a>
  `).join("");
  return `
    <section class="note-share-links note-share-amp-threads">
      <div class="note-share-section-title">AMP THREADS (${ampThreads.length})</div>
      ${rows}
    </section>
  `;
}

async function resolveHTMLAttachmentRefs(html, attachments = []) {
  const parsed = new DOMParser().parseFromString(String(html || ""), "text/html");
  const blobURLs = [];
  const references = [];
  parsed.querySelectorAll("[src], [poster]").forEach((element) => {
    for (const attribute of ["src", "poster"]) {
      if (element.hasAttribute(attribute)) references.push([element, attribute]);
    }
  });
  await Promise.all(references.map(async ([element, attribute]) => {
    const match = element.getAttribute(attribute)?.trim().match(/^att:(\d+)$/i);
    if (!match) return;
    const attachment = attachments[Number(match[1])];
    if (!attachment?.fileId) return;
    try {
      const response = await fetch(attachmentFileURL(attachment.fileId, attachment.filename || "", true));
      if (!response.ok) return;
      const blobURL = URL.createObjectURL(await response.blob());
      blobURLs.push(blobURL);
      element.setAttribute(attribute, blobURL);
    } catch (error) {
      console.warn("Failed to prepare HTML note attachment", error);
    }
  }));
  return { source: `<!doctype html>\n${parsed.documentElement.outerHTML}`, blobURLs };
}

function mountHTMLNote(container, html, attachments = [], title = "HTML note") {
  if (!container || !window.NRCHTMLNotes) return null;
  const frame = window.NRCHTMLNotes.createFrame(html, title);
  container.replaceChildren(frame);
  container.classList.add("note-html-host");
  resolveHTMLAttachmentRefs(html, attachments).then(({ source, blobURLs }) => {
    if (!frame.isConnected) {
      blobURLs.forEach(URL.revokeObjectURL);
      return;
    }
    window.NRCHTMLNotes.updateFrame(frame, source, blobURLs);
  });
  return frame;
}

function renderSharedNoteAttachments(attachments) {
  if (!attachments || attachments.length === 0) {
    return '<div class="note-share-links-empty">NO ATTACHMENTS</div>';
  }

  return attachments.map((att) => {
    const filename = att.filename || att.fileId || "attachment";
    const mimeType = att.mimeType || "application/octet-stream";
    const type = typeof getFileExtension === "function" ? getFileExtension(filename, mimeType) : "FILE";
    const size = typeof formatFileSize === "function" ? formatFileSize(Number(att.size || 0)) : `${att.size || 0} B`;
    const fileId = att.fileId || "";
    const isImage = mimeType.startsWith("image/");
    const inline = isImage || (typeof isPreviewableType === "function" && isPreviewableType(mimeType));
    const href = fileId ? attachmentFileURL(fileId, filename, inline) : "#";
    const downloadAttr = inline ? "" : ` download="${escapeHtml(filename)}"`;

    return `
      <a class="note-share-attachment-row" href="${escapeHtml(href)}"${downloadAttr} ${inline && !isImage ? 'target="_blank" rel="noopener noreferrer"' : ""} data-image="${isImage ? "1" : "0"}" data-file-id="${escapeHtml(fileId)}" data-filename="${escapeHtml(filename)}">
        <span class="note-share-attachment-type">${escapeHtml(type)}</span>
        <span class="note-share-attachment-name">${escapeHtml(filename)}</span>
        <span class="note-share-attachment-size">${escapeHtml(size)}</span>
      </a>
    `;
  }).join("");
}

function renderSharedLinkedNodes(note, edges) {
  if (!window.NRCEdges?.TargetType || !edges || edges.length === 0) {
    return '<div class="note-share-links-empty">NO DIRECT LINKS</div>';
  }

  const { TargetType, RelationTypeNames } = window.NRCEdges;
  const rows = [];
  for (const edge of edges) {
    const other = getSharedEdgeOtherEndpoint(edge, TargetType.Asset, note.assetId);
    if (!other) continue;
    if (window.NRCFiles && other.targetType === TargetType.Asset &&
        window.NRCAssets?.roomAssets?.get(note.convId)?.get(other.targetId)?.assetType === window.NRCAssets.AssetType.File) continue;

    const relation = RelationTypeNames?.[edge.relation] || "link";
    const direction = other.direction === "out" ? "→" : "←";
    const asset = other.targetType === TargetType.Asset
      ? window.NRCAssets?.roomAssets?.get(note.convId)?.get(other.targetId) : null;
    const typeLabel = window.NRCLinksUI.linkTargetKind(other.targetType, asset).label;
    const isNote = other.targetType === TargetType.Asset && asset?.assetType === window.NRCAssets.AssetType.Note;
    const label = other.targetType === TargetType.Asset
      ? window.NRCLinksUI.resolveTargetName(note.convId, other.targetType, other.targetId)
      : getSharedLinkedTaskTitle(note.convId, other.targetId);
    const rowTag = isNote ? "button" : "div";
    const rowType = isNote ? ' type="button"' : "";

    rows.push(`
      <${rowTag} class="note-share-link-row"${rowType} data-type="${typeLabel}" data-id="${other.targetId}">
        <span class="note-share-link-type">${typeLabel}</span>
        <span class="note-share-link-relation" data-relation="${edge.relation}">${escapeHtml(relation)} ${direction}</span>
        <span class="note-share-link-title">${escapeHtml(label)}</span>
      </${rowTag}>
    `);
  }

  return rows.length > 0 ? rows.join("") : '<div class="note-share-links-empty">NO DIRECT LINKS</div>';
}

function openSharedNoteInNrc() {
  if (!sharedNoteAsset) return;
  const note = sharedNoteAsset;
  window.location.hash = "";
  showNotesView();
  selectNote(note);
}

function updateSharedNoteExportButtons() {
  const pdfBtn = document.getElementById("noteShareOpenPdf");
  const docxBtn = document.getElementById("noteShareDownloadDocx");
  const disabled = !sharedNoteAsset || Boolean(sharedNoteExportFormat);
  if (pdfBtn) {
    pdfBtn.disabled = disabled;
    pdfBtn.textContent = sharedNoteExportFormat === "pdf" ? "GENERATING PDF…" : "OPEN PDF";
  }
  if (docxBtn) {
    docxBtn.disabled = disabled;
    docxBtn.textContent = sharedNoteExportFormat === "docx" ? "GENERATING DOCX…" : "DOWNLOAD DOCX";
  }
}

function notifySharedNoteExportError(message) {
  if (window.NRCDialog && typeof window.NRCDialog.notify === "function") {
    window.NRCDialog.notify(message, { logType: "Error" });
  } else if (typeof logMessage === "function") {
    logMessage("Error", message);
  }
}

function downloadSharedNoteBlob(url, filename) {
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
}

async function exportSharedNote(format) {
  if (!sharedNoteAsset || sharedNoteExportFormat) return;

  const note = sharedNoteAsset;
  const { title } = parseNotePreview(note.preview);
  let pdfWindow = null;
  if (format === "pdf") {
    pdfWindow = window.open("", "_blank");
    if (pdfWindow) {
      pdfWindow.document.title = "GENERATING PDF…";
      pdfWindow.document.body.textContent = "GENERATING PDF…";
    }
  }

  sharedNoteExportFormat = format;
  updateSharedNoteExportButtons();
  try {
    const response = await fetch("/exports", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        format,
        title: title || `Note ${note.assetId}`,
        author: note.owner || "",
        date: formatNoteTimestamp(note.updatedAt),
        content: note.payload || "",
        inputFormat: parseNotePreview(note.preview).format,
        attachments: (note.attachments || []).map((attachment) => ({
          fileId: attachment.fileId || "",
          filename: attachment.filename || "",
          mimeType: attachment.mimeType || "application/octet-stream",
        })),
      }),
    });
    if (!response.ok) {
      const detail = (await response.text()).trim();
      throw new Error(detail || `HTTP ${response.status}`);
    }

    const blobUrl = URL.createObjectURL(await response.blob());
    const filename = `note-${note.assetId}.${format}`;
    if (format === "pdf" && pdfWindow) {
      pdfWindow.location.replace(blobUrl);
    } else {
      downloadSharedNoteBlob(blobUrl, filename);
    }
    window.setTimeout(() => URL.revokeObjectURL(blobUrl), 60000);
  } catch (err) {
    if (pdfWindow) pdfWindow.close();
    console.error(`Failed to export shared note as ${format}`, err);
    notifySharedNoteExportError(`FAILED TO EXPORT ${format.toUpperCase()}`);
  } finally {
    sharedNoteExportFormat = "";
    updateSharedNoteExportButtons();
  }
}

function openSharedLinkedNote(convId, assetId) {
  const workspace = encodeURIComponent(currentWorkspaceId || "workspace1");
  window.location.hash = `/note/${workspace}/${assetId}`;
}

function getSharedNoteUrl(note) {
  if (!note) return "";
  const workspace = encodeURIComponent(currentWorkspaceId || "workspace1");
  const path = `#/note/${workspace}/${note.assetId}`;
  return `${window.location.origin}${window.location.pathname}${path}`;
}

async function copySharedNoteLink(note) {
  const url = getSharedNoteUrl(note);
  if (!url) return;

  try {
    await navigator.clipboard.writeText(url);
    window.NRCDialog.notify("NOTE SHARE LINK COPIED");
    logSystem(`COPIED NOTE SHARE LINK #${note.assetId}`, "notes");
  } catch (err) {
    console.warn("Failed to copy note share link", err);
    await window.NRCDialog.prompt("Clipboard access failed. Copy this note link:", {
      title: "COPY NOTE LINK",
      initialValue: url,
    });
  }
}

function clearSharedNoteView() {
  sharedNoteRoute = null;
  sharedNoteAsset = null;
  sharedNoteEdges = [];
  sharedNoteLoading = false;
  sharedNoteExportFormat = "";
  sharedNoteLoadSeq += 1;
}

function refreshSharedNoteView() {
  if (sharedNoteAsset || sharedNoteLoading) {
    renderSharedNoteView();
  }
}

// =============================================================================
// NOTE SELECTION & DETAIL PANEL
// =============================================================================

function isSelectedNote(convId, assetId) {
  return selectedNoteConvId === convId && selectedNoteId === assetId;
}

function prefetchAdjacentNotes() {
  if (!notesViewActive || !selectedNoteRow?.isConnected) return;
  const virtual = document.getElementById("notesList")?.virtualList;
  for (const direction of [-1, 1]) {
    if (virtual) {
      const note = virtual.items[Number(selectedNoteRow.dataset.virtualIndex) + direction];
      if (note) window.NRCInspector?.prefetchNote?.({ roomId: note.convId, id: note.assetId });
    } else {
      const row = direction < 0 ? selectedNoteRow.previousElementSibling : selectedNoteRow.nextElementSibling;
      if (row?.dataset.noteId) window.NRCInspector?.prefetchNote?.({ roomId: row.dataset.convId, id: row.dataset.noteId });
    }
  }
}

function updateRenderedNoteSelection(previousConvId, previousId, nextConvId, nextId) {
  const updateRow = (convId, assetId, selected) => {
    if (convId === null || assetId === null) return;
    const row = selectedNoteRow?.dataset.convId === convId.toString() &&
      selectedNoteRow.dataset.noteId === assetId.toString()
      ? selectedNoteRow
      : noteRowsByIdentity.get(`${convId}:${assetId}`);
    if (!row) return;
    row.classList.toggle("note-selected", selected);
    const marker = row.querySelector(".note-marker");
    if (marker) marker.textContent = selected ? "›" : "";
    if (selected) selectedNoteRow = row;
    else if (selectedNoteRow === row) selectedNoteRow = null;
  };

  if (previousConvId !== nextConvId || previousId !== nextId) {
    updateRow(previousConvId, previousId, false);
  }
  updateRow(nextConvId, nextId, true);
}

function refreshRenderedNoteRow(note) {
  if (note.convId !== 0n) return;
  if (document.getElementById("notesList")?.virtualList) {
    // Membership and sort keys may have changed. Only the owner may replace
    // virtual rows; hidden lists are already dirty and refresh on reopening.
    if (notesViewActive) renderNotesView();
    return;
  }
  const row = document.querySelector(`#notesList .note-card[data-note-id="${note.assetId}"]`);
  if (row) row.replaceWith(createNoteCard(note));
}

function loadNoteDetail(note) {
  if (note.payload !== null && note.payload !== undefined) {
    showNoteDetailPanel(note);
  } else {
    window.NRCAssets.requestAsset(note.convId, note.assetId, {
      onSuccess: ({ asset }) => {
        if (isSelectedNote(note.convId, note.assetId)) showNoteDetailPanel(asset);
      },
    });
  }
}

function selectNote(note, { deferDetail = false, replaceCurrent = false, fromInspector = false, subview = null, focusId = null, loadDetail = true } = {}) {
  noteListNavigationGeneration++;
  if (!fromInspector && window.NRCInspector) {
    window.NRCInspector.openEntity(
      { roomId: note.convId, type: "note", id: note.assetId },
      { subview, focusId, deferDetail, replaceCurrent },
    );
    return;
  }
  const previousNoteConvId = selectedNoteConvId;
  const previousNoteId = selectedNoteId;
  const selectionChanged = !isSelectedNote(note.convId, note.assetId);
  if (selectionChanged) {
    pendingNotePageNavigation = null;
    noteDetailSaveGeneration++;
    noteMessagesOpen = null;
    noteSectionsOpen = false;
    noteComposerOpen = false;
    noteComposerDraft = "";
    noteResourceOpen = {};
    pendingNoteCommentFocusAssetId = null;
    currentDetailNote = null;
  }
  if (subview === "comments") noteMessagesOpen = true;
  if (focusId != null) pendingNoteCommentFocusAssetId = BigInt(focusId);
  selectedNoteConvId = note.convId;
  selectedNoteId = note.assetId;
  updateRenderedNoteSelection(previousNoteConvId, previousNoteId, selectedNoteConvId, selectedNoteId);

  if (selectionChanged) {
    clearTimeout(noteNeighborPrefetchTimer);
    noteNeighborPrefetchTimer = setTimeout(prefetchAdjacentNotes, 100);
  }
  clearTimeout(noteKeyboardSelectionTimer);
  noteKeyboardSelectionTimer = null;

  if (!loadDetail) return;

  if (deferDetail) {
    const { convId, assetId } = note;
    noteKeyboardSelectionTimer = setTimeout(() => {
      noteKeyboardSelectionTimer = null;
      if (!isSelectedNote(convId, assetId)) return;
      const inspected = window.NRCInspector?.current?.();
      if (
        inspected?.type === "note" &&
        inspected.roomId === convId &&
        inspected.id === assetId
      ) {
        window.NRCInspector.openEntity(
          { roomId: convId, type: "note", id: assetId },
          { deferDetail: false, replaceCurrent: true },
        );
        return;
      }
      const currentNote = window.NRCAssets?.roomAssets?.get(convId)?.get(assetId);
      if (currentNote?.assetType === window.NRCAssets.AssetType.Note) {
        loadNoteDetail(currentNote);
      }
    }, NOTE_KEYBOARD_DETAIL_DELAY_MS);
    return;
  }

  loadNoteDetail(note);
}

function openNoteComments(note, commentAssetId = null) {
  if (!note || note.assetType !== window.NRCAssets?.AssetType?.Note) return false;
  if (window.NRCInspector) {
    window.NRCInspector.openEntity(
      { roomId: note.convId, type: "note", id: note.assetId },
      { subview: "comments", focusId: commentAssetId },
    );
    return true;
  }
  selectNote(note, { subview: "comments", focusId: commentAssetId });

  if (
    currentDetailNote &&
    currentDetailNote.convId === note.convId &&
    currentDetailNote.assetId === note.assetId
  ) {
    showNoteDetailPanel(currentDetailNote);
  }

  if (pendingNoteCommentFocusAssetId != null) {
    let attempts = 0;
    const retryFocus = () => {
      if (pendingNoteCommentFocusAssetId == null) return;
      attempts += 1;
      tryFocusPendingNoteCommentInDetailPanel();
      if (pendingNoteCommentFocusAssetId != null && attempts < 8) {
        setTimeout(retryFocus, 120);
      }
    };
    setTimeout(retryFocus, 80);
  }

  return true;
}

function clearNoteSelection({ fromInspector = false, preserveDetail = false } = {}) {
  noteListNavigationGeneration++;
  if (!fromInspector && window.NRCInspector?.hasEntity()) {
    window.NRCInspector.close();
    return;
  }
  clearTimeout(noteKeyboardSelectionTimer);
  noteKeyboardSelectionTimer = null;
  pendingNotePageNavigation = null;
  const previousNoteConvId = selectedNoteConvId;
  const previousNoteId = selectedNoteId;
  selectedNoteConvId = null;
  selectedNoteId = null;
  updateRenderedNoteSelection(previousNoteConvId, previousNoteId, null, null);
  noteDetailSaveGeneration++;
  currentDetailNote = null;
  noteEditMode = false;
  notePreviewMode = false;
  noteMessagesOpen = false;
  noteComposerOpen = false;
  noteComposerDraft = "";
  noteResourceOpen = {};
  pendingNoteCommentFocusAssetId = null;
  noteDetailDirty = false;
  window.NRCLinksUI?.closeLinkPicker();
  if (!preserveDetail) hideNoteDetailPanel();
  window.NRCPageTitle?.set("NOTES");
}

// --- Dirty-state helpers (note edit panel) ----------------------------------
// Returns true if it's safe to close/switch (not dirty, or user confirmed).
async function confirmDiscardNoteEditsIfDirty() {
  if (!noteDetailDirty) return true;
  const confirmed = await window.NRCDialog.confirm(
    "Discard unsaved changes to this note?",
    {
      title: "UNSAVED CHANGES",
      confirmLabel: "Discard",
    },
  );
  return confirmed;
}

function setNoteDetailDirty(dirty) {
  noteDetailDirty = dirty;
  const panel = document.querySelector(".agenda-panel .panel-header");
  const saveBtn = document.getElementById("noteDetailSave");
  if (panel) panel.classList.toggle("is-dirty", dirty);
  if (saveBtn) saveBtn.classList.toggle("is-dirty", dirty);
  if (dirty) {
    noteDetailSaveGeneration++;
    window.NRCDetailUI?.setSaveState("UNSAVED", panel || document);
  }
}

function buildNotePreviewLedger(note, format, editing = false) {
  return `<div class="detail-read-register note-inline-metadata">
    ${noteFieldControl(note, "project")}
    ${noteFieldControl(note, "tags")}
    <div class="record-format"><label class="inline-field-label" ${editing ? 'for="noteDetailFormat"' : ""}>FORMAT</label>${editing
      ? `<nrc-select><select class="note-detail-input" id="noteDetailFormat" title="Content format">
          <option value="markdown" ${format === "markdown" ? "selected" : ""}>MARKDOWN</option>
          <option value="html" ${format === "html" ? "selected" : ""}>HTML</option>
        </select></nrc-select>`
      : `<span>${escapeHtml(format.toUpperCase())}</span>`}</div>
  </div>`;
}

function renderNoteDocumentResources(note, ampThreads) {
  return window.NRCDetailUI.renderDocumentResources({ kind: "note", attachments: note.attachments,
    attachmentControl: noteAttachmentsControl(note), open: noteResourceOpen,
    threadsHtml: window.NRCDetailUI.renderResourceBlock({
      resource: "threads", label: "AMP THREADS", open: noteResourceOpen.threads === true,
      count: ampThreads.length, preview: ampThreads[0]?.label || "", bodyHtml: renderNoteAmpThreads(ampThreads),
    }),
  });
}

function buildNoteHeaderMetadata(note) {
  const rows = [
    { label: "CREATED BY", value: note.owner || "—", role: "actor" },
    { label: "CREATED", value: window.NRCDetailUI.formatHeaderDate(note.createdAt) },
    { label: "UPDATED", value: window.NRCDetailUI.formatHeaderDate(note.updatedAt) },
  ];
  const source = note.source || note.sourceUrl || note.sourceId;
  if (source) rows.push({ label: "SOURCE", value: String(source) });
  return window.NRCDetailUI.renderHeaderMetadata(rows);
}

function addNoteSectionJumpLedger(previewBody, scrollContainer = previewBody) {
  const headings = Array.from(previewBody.querySelectorAll("h1, h2, h3, h4"));
  const used = new Set();
  headings.forEach((heading, index) => {
    const base = heading.textContent.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || `section-${index + 1}`;
    let id = `note-${base}`, suffix = 2;
    while (used.has(id)) id = `note-${base}-${suffix++}`;
    used.add(id); heading.id = id; heading.tabIndex = -1;
  });
  if (headings.length < 2) return;
  const nav = document.createElement("nav"); nav.className = "note-section-jumps"; nav.setAttribute("aria-label", "Note sections");
  const toggle = document.createElement("button");
  toggle.type = "button";
  toggle.className = "record-strip note-sections-toggle";
  toggle.innerHTML = `<b class="record-strip-label">CONTENTS</b><span class="record-strip-count">${headings.length}</span><i class="record-strip-key"></i>`;
  const updateExpanded = () => {
    nav.dataset.collapsed = String(!noteSectionsOpen);
    if (!noteSectionsOpen) nav.scrollTop = 0;
    toggle.setAttribute("aria-expanded", String(noteSectionsOpen));
    toggle.querySelector('.record-strip-key').textContent = noteSectionsOpen ? "−" : "+";
  };
  toggle.onclick = () => { noteSectionsOpen = !noteSectionsOpen; updateExpanded(); };
  updateExpanded();
  nav.append(toggle);
  const links = [];
  const setCurrentSection = (currentIndex) => {
    links.forEach((link, index) => {
      const isCurrent = index === currentIndex;
      link.classList.toggle("current", isCurrent);
      if (isCurrent) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    });
    const currentLink = links[currentIndex];
    if (!currentLink || !noteSectionsOpen) return;
    if (currentLink.offsetTop < nav.scrollTop) {
      nav.scrollTop = currentLink.offsetTop;
    } else if (currentLink.offsetTop + currentLink.offsetHeight > nav.scrollTop + nav.clientHeight) {
      nav.scrollTop = currentLink.offsetTop + currentLink.offsetHeight - nav.clientHeight;
    }
  };
  headings.forEach((heading, index) => {
    const link = document.createElement("a"); link.href = `#${heading.id}`;
    const label = document.createElement("span"); label.className = "note-section-jump-label"; label.textContent = heading.textContent; link.append(label);
    link.dataset.index = String(index + 1).padStart(2, "0");
    link.title = heading.textContent;
    link.addEventListener("click", (event) => {
      event.preventDefault();
      setCurrentSection(index);
      if (scrollContainer === previewBody) {
        heading.scrollIntoView({ block: "start" });
      } else {
        const containerTop = scrollContainer.getBoundingClientRect().top;
        const containerPaddingTop = parseFloat(getComputedStyle(scrollContainer).paddingTop) || 0;
        const stickyBottom = containerTop + containerPaddingTop + nav.getBoundingClientRect().height;
        const targetTop = scrollContainer.scrollTop + heading.getBoundingClientRect().top - stickyBottom - 8;
        scrollContainer.scrollTop = Math.max(0, targetTop);
      }
      heading.focus({ preventScroll: true });
    });
    links.push(link);
    nav.append(link);
  });
  previewBody.before(nav);
  const updateStickyState = () => {
    if (scrollContainer === previewBody) return;
    const containerTop = scrollContainer.getBoundingClientRect().top;
    const containerPaddingTop = parseFloat(getComputedStyle(scrollContainer).paddingTop) || 0;
    const isStuck = nav.getBoundingClientRect().top <= containerTop + containerPaddingTop + 0.5;
    const previousContentCleared = !nav.previousElementSibling || nav.previousElementSibling.getBoundingClientRect().bottom <= containerTop + 0.5;
    nav.classList.toggle("is-stuck", isStuck && previousContentCleared);
  };
  let sectionFrame = 0;
  // A container can outlive the ledger's content: the shared-note view keeps
  // #noteShareContent across renders, so it must not collect one scroll handler
  // per render.
  scrollContainer._nrcSectionJumpDetach?.();
  const onScroll = () => {
    if (sectionFrame) return;
    sectionFrame = requestAnimationFrame(() => {
      sectionFrame = 0;
      updateStickyState();
      let bodyTop = scrollContainer.getBoundingClientRect().top + 8;
      if (scrollContainer !== previewBody) bodyTop = Math.max(bodyTop, nav.getBoundingClientRect().bottom + 10);
      let currentIndex = 0;
      headings.forEach((heading, index) => {
        if (heading.getBoundingClientRect().top <= bodyTop) currentIndex = index;
      });
      if (scrollContainer.scrollTop + scrollContainer.clientHeight >= scrollContainer.scrollHeight - 2) {
        currentIndex = headings.length - 1;
      }
      setCurrentSection(currentIndex);
    });
  };
  scrollContainer.addEventListener("scroll", onScroll, { passive: true });
  scrollContainer._nrcSectionJumpDetach = () => scrollContainer.removeEventListener("scroll", onScroll);
  updateStickyState();
  setCurrentSection(0);
}

function showNoteTitleError() {
  const input = document.getElementById("noteDetailTitle");
  const row = input?.closest(".note-detail-row");
  const err = document.getElementById("noteDetailTitleError");
  if (row) row.classList.add("is-invalid");
  if (err) err.classList.add("is-visible");
  if (input) input.focus();
}

function clearNoteTitleError() {
  const input = document.getElementById("noteDetailTitle");
  const row = input?.closest(".note-detail-row");
  const err = document.getElementById("noteDetailTitleError");
  if (row) row.classList.remove("is-invalid");
  if (err) err.classList.remove("is-visible");
}

function isNotesKeyboardEditableTarget(target) {
  if (!target) return false;
  const tagName = target.tagName;
  return tagName === "INPUT" || tagName === "TEXTAREA" || tagName === "SELECT" || target.isContentEditable;
}

function getNoteById(assetId) {
  const roomMap = window.NRCAssets?.roomAssets?.get(0n);
  if (!roomMap) return null;
  const note = roomMap.get(assetId);
  return note && note.assetType === window.NRCAssets.AssetType.Note ? note : null;
}

function selectNoteRow(row, { deferDetail = true } = {}) {
  if (!row?.dataset.noteId) return false;
  const note = getNoteById(BigInt(row.dataset.noteId));
  if (!note) return false;
  selectNote(note, { deferDetail, replaceCurrent: true });
  const rowIdentity = `${note.convId}:${note.assetId}`;
  requestAnimationFrame(() => {
    const renderedRow = noteRowsByIdentity.get(rowIdentity);
    if (renderedRow?.parentElement === document.getElementById("notesList")) {
      renderedRow.scrollIntoView({ block: "nearest" });
    }
  });
  return true;
}

function selectAdjacentNote(direction, { deferDetail = true } = {}) {
  const notesList = document.getElementById("notesList");
  if (!notesList) return false;

  const virtual = notesList.virtualList;
  if (virtual) {
    const index = selectedNoteId === null ? (direction > 0 ? -1 : virtual.items.length)
      : virtual.items.findIndex((note) => note.assetId === selectedNoteId && note.convId === selectedNoteConvId);
    if (selectedNoteId !== null && index < 0) return false;
    const next = index + direction;
    if (next >= 0 && next < virtual.items.length) {
      return selectNoteRow(virtual.ensure(next), { deferDetail });
    }
    const state = getNotesPaginationState(0n);
    if (next === virtual.items.length && !(document.getElementById("notesSearch")?.value || "").trim() && state.hasMore) {
      pendingNotePageNavigation = { convId: selectedNoteConvId, assetId: selectedNoteId };
      fetchNotesPage(0n);
    }
    return false;
  }

  const hasSelection = selectedNoteId !== null && selectedNoteConvId !== null;
  let currentRow = selectedNoteRow;
  if (
    hasSelection &&
    (!currentRow || currentRow.parentElement !== notesList ||
      currentRow.dataset.noteId !== selectedNoteId.toString() ||
      currentRow.dataset.convId !== selectedNoteConvId.toString())
  ) {
    currentRow = noteRowsByIdentity.get(`${selectedNoteConvId}:${selectedNoteId}`) || null;
    selectedNoteRow = currentRow;
  }
  if (hasSelection && !currentRow) return false;

  let nextRow = hasSelection
    ? (direction > 0 ? currentRow.nextElementSibling : currentRow.previousElementSibling)
    : (direction > 0 ? notesList.firstElementChild : notesList.lastElementChild);
  while (nextRow && !nextRow.matches?.(".note-card[data-note-id]")) {
    nextRow = direction > 0 ? nextRow.nextElementSibling : nextRow.previousElementSibling;
  }

  if (!nextRow && hasSelection) {
    const pageState = getNotesPaginationState(0n);
    const searchTerm = (document.getElementById("notesSearch")?.value || "").trim();
    if (direction > 0 && !searchTerm && pageState.hasMore && selectedNoteId && selectedNoteConvId != null) {
      pendingNotePageNavigation = {
        convId: selectedNoteConvId,
        assetId: selectedNoteId,
      };
      fetchNotesPage(0n);
    }
    return false;
  }
  return nextRow ? selectNoteRow(nextRow, { deferDetail }) : false;
}

function resumePendingNotePageNavigation(convId) {
  const pending = pendingNotePageNavigation;
  if (!pending || pending.convId !== convId) return;
  pendingNotePageNavigation = null;
  if (!notesViewActive || 0n !== convId) return;
  if (!isSelectedNote(pending.convId, pending.assetId)) return;
  selectAdjacentNote(1);
}

// Keyboard-driven adjacent selection respects the dirty guard so arrow-key
// navigation doesn't silently discard unsaved note edits.
async function selectAdjacentNoteGuarded(direction) {
  const generation = ++noteListNavigationGeneration;
  const wasDirty = noteDetailDirty;
  if (!(await confirmDiscardNoteEditsIfDirty())) return false;
  if (generation !== noteListNavigationGeneration) return false;
  if (wasDirty) setNoteDetailDirty(false);
  return selectAdjacentNote(direction, { deferDetail: !wasDirty });
}

async function confirmDeleteSelectedNote() {
  if (!selectedNoteId) return false;
  const note = window.NRCAssets?.roomAssets?.get(selectedNoteConvId)?.get(selectedNoteId) ||
    (currentDetailNote && isSelectedNote(currentDetailNote.convId, currentDetailNote.assetId)
      ? currentDetailNote
      : null);
  if (!note) return false;

  const confirmed = await window.NRCDialog.confirm(
    `Delete note #${note.assetId} “${parseNotePreview(note.preview).title || "(untitled)"}”?`,
    {
      title: "DELETE NOTE",
      confirmLabel: "Delete Note",
    },
  );
  if (!confirmed) return true;

  const convId = note.convId;
  const assetId = note.assetId;
  setNoteDetailDirty(false);
  if (window.NRCInspector) await window.NRCInspector.close();
  else clearNoteSelection({ fromInspector: true });
  sendDeleteNote(convId, assetId);
  return true;
}

function handleNotesKeyboardNavigation(e) {
  if (!notesViewActive) return;

  // Esc closes the preview panel (no dirty guard needed in preview mode;
  // the edit panel handles its own Esc with a dirty guard).
  if (e.key === "Escape") {
    if (window.NRCInspector?.hasEntity()) return;
    if (notePreviewMode && !noteEditMode && selectedNoteId) {
      e.preventDefault();
      clearNoteSelection();
    }
    return;
  }

  // E enters edit mode from preview (matches the EDIT button's "E" hint).
  if ((e.key === "e" || e.key === "E") && !window.NRCInspector?.hasEntity() && notePreviewMode && !noteEditMode && selectedNoteId) {
    if (isNotesKeyboardEditableTarget(e.target)) return;
    e.preventDefault();
    switchToEditPanel();
    return;
  }

  if (isNotesKeyboardEditableTarget(e.target)) return;

  if (e.key === "ArrowDown") {
    e.preventDefault();
    selectAdjacentNoteGuarded(1);
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    selectAdjacentNoteGuarded(-1);
  } else if (e.key === "Delete") {
    e.preventDefault();
    confirmDeleteSelectedNote();
  }
}

function showNoteDetailPanel(note) {
  if (window.NRCInspector?.isLoading?.()) return;
  const { title } = parseNotePreview(note.preview);
  window.NRCPageTitle?.set(title || `NOTE #${note.assetId}`);

  if (noteEditMode) {
    showNoteEditPanel(note);
    return;
  }
  showNotePreviewPanel(note);
}

function showNotePreviewPanel(note) {
  const { title, project, tags, format } = parseNotePreview(note.preview);
  const noteMarkdown = getNoteMarkdown(note);
  const markdownPresentation = noteMarkdown
    ? renderNoteMarkdownPresentation(noteMarkdown, note.attachments || [], format)
    : null;
  const ampThreads = markdownPresentation?.ampThreads || [];
  currentDetailNote = note;
  noteEditMode = false;
  notePreviewMode = true;
  // Preview mode is never dirty; reset so a stale flag from a previously
  // edited note doesn't leave the UNSAVED indicator lit or trigger false
  // close prompts.
  setNoteDetailDirty(false);

  const agendaPanel = document.querySelector(".agenda-panel");
  const agendaHeader = agendaPanel.querySelector(".panel-header");
  const agendaContent = agendaPanel.querySelector(".agenda-content");
  const agendaActions = document.getElementById("agendaActions");
  window.NRCLinksUI?.closeLinkPicker();

  agendaActions.style.display = "none";

  // Stash the live draft so a re-render cannot discard a message the operator
  // is still writing.
  const liveComposer = document.getElementById("noteCommentInput");
  if (liveComposer) noteComposerDraft = liveComposer.value;
  noteResourceOpen = window.NRCDetailUI.readResourceState(agendaContent);

  agendaHeader.innerHTML = `<div class="inspector-identity-row">
    <span class="header-text identity-reference">NOTE #${note.assetId}</span>
    ${buildNoteHeaderMetadata(note)}
    <span class="inspector-cell-label">STATE</span>
    <span class="inspector-state-value">READ</span>
  </div><div class="inspector-mode-row">
    ${window.NRCDetailUI.renderHeaderAction({ id: "noteDetailEdit", label: "EDIT", command: "e", title: "Edit content (E)" })}
    ${window.NRCDetailUI.renderHeaderAction({ id: "noteShareLink", label: "SHARE", command: "s", title: "Copy read-only share link (S)" })}
    <button class="btn btn--danger header-operation inspector-matrix-control" id="noteDetailDelete" title="Delete note">DELETE</button>
    ${window.NRCDetailUI.renderCloseControl("noteDetailClose")}</div>`;

  agendaContent.innerHTML = `
    <div class="note-preview-panel">
      <div class="task-detail-tab-content note-detail-tab-content record-document active" data-tab-content="detail">
        <div class="record-document record-document-scroll">
        <div class="note-preview-title">${escapeHtml(title || "(No title)")}</div>
        <div class="agenda-preview note-preview-body" id="notePreviewBody"></div>
        </div>
        ${renderNoteDocumentResources(note, ampThreads)}
      </div>
      ${noteMessagesAreaHtml(note)}
    </div>
  `;

  const previewBody = document.getElementById("notePreviewBody");
  if (previewBody) {
    if (noteMarkdown) {
      if (format === "html") {
        mountHTMLNote(previewBody, markdownPresentation.bodyHtml, note.attachments || [], title || `Note #${note.assetId}`);
      } else {
        previewBody.innerHTML = markdownPresentation.bodyHtml;
        addNoteSectionJumpLedger(previewBody, previewBody.closest(".record-document-scroll") || previewBody);
        attachMarkdownCheckboxHandlers(
          previewBody,
          () => getNoteMarkdown(note),
          (updatedMarkdown) => queueNoteMarkdownUpdate(note, updatedMarkdown),
        );
      }
    } else {
      previewBody.innerHTML = "<em>Empty note. Click EDIT or double-click to start writing.</em>";
      previewBody.classList.add("note-detail-empty");
    }
    previewBody.addEventListener("dblclick", (event) => {
      if (event.target.closest("input[type='checkbox']")) return;
      switchToEditPanel();
    });
  }

  // Panel-level handlers are bound once on the container. The preview can be the
  // first render of a note (a read-only open), so it binds them too; the guard
  // in the helper keeps it to one binding per container.
  bindNoteDetailPanelHandlers();
  renderNoteLinks(note);
  document.getElementById("noteLinkAdd").onclick = event => {
    document.getElementById("noteLinkPicker").open({
      anchor: event.currentTarget, sourceType: 1, sourceEntity: note,
      onSelect: (item, relation) => window.NRCLinksUI.createPickedLink(note, 1, item, relation),
    });
  };
  initNoteCommentEventHandlers(note);

  const editBtn = document.getElementById("noteDetailEdit");
  if (editBtn) {
    editBtn.addEventListener("click", switchToEditPanel);
  }
  document.getElementById("noteDetailDelete").addEventListener("click", deleteNoteFromPanel);

  const shareBtn = document.getElementById("noteShareLink");
  if (shareBtn) {
    shareBtn.addEventListener("click", () => copySharedNoteLink(note));
  }

  const closeBtn = document.getElementById("noteDetailClose");
  if (closeBtn) {
    closeBtn.addEventListener("click", () => {
      if (window.NRCInspector) window.NRCInspector.close();
      else clearNoteSelection({ fromInspector: true });
    });
  }
}

function switchToEditPanel() {
  if (!currentDetailNote || noteEditMode) return;
  if (!isSelectedNote(currentDetailNote.convId, currentDetailNote.assetId)) return;
  if (noteMarkdownUpdates.has(getNoteMarkdownUpdateKey(currentDetailNote))) {
    notifyNoteSaveError("WAIT FOR THE CHECKBOX UPDATE TO FINISH BEFORE EDITING");
    return;
  }
  noteDetailSaveGeneration++;
  noteEditMode = true;
  notePreviewMode = false;
  showNoteEditPanel(currentDetailNote);
}

function switchToPreviewPanel() {
  if (!currentDetailNote || !noteEditMode) return;
  noteDetailSaveGeneration++;

  noteEditMode = false;
  notePreviewMode = true;
  showNotePreviewPanel(currentDetailNote);
}

function cancelNoteEdit() {
  if (!currentDetailNote) return;
  noteDetailSaveGeneration++;
  // Discard only the DOM draft. Never write the snapshot back into the cache:
  // metadata broadcasts may have advanced while the content editor was open.
  currentDetailNote = getCanonicalNote(currentDetailNote);
  noteEditMode = false;
  notePreviewMode = true;
  setNoteDetailDirty(false);
  showNotePreviewPanel(currentDetailNote);
}

// The panel replaces its own markup on every render, but `.agenda-content`
// itself persists. Panel-level handlers are therefore bound once, on the first
// render; a handler bound per render piles up and saves once per copy on
// Ctrl+Enter.
let noteDetailPanelHandlersBound = false;

function bindNoteDetailPanelHandlers() {
  if (noteDetailPanelHandlersBound) return;
  const agendaContent = document.querySelector(".agenda-panel .agenda-content");
  if (!agendaContent) return;
  noteDetailPanelHandlersBound = true;

  // Resource registers toggle in place; the panel must not re-render, because
  // the files and links modules hydrate into those containers. The live DOM
  // carries the open state; the preview reads it back before it renders.
  window.NRCDetailUI.bindResourceBlocks({ root: agendaContent });

  // Dirty tracking: any edit to the title/project/tags/content marks the
  // note dirty. The link-picker search input is excluded.
  const noteDirtyFields = ["noteDetailContent", "noteDetailFormat"];
  agendaContent.addEventListener("input", (e) => {
    if (noteDirtyFields.includes(e.target.id)) setNoteDetailDirty(true);
  });

  // Keyboard shortcuts for the note edit panel:
  //   Esc  — if dirty, prompt to discard; then return to read-only preview
  //          (not close). Esc again from preview closes the panel.
  //   Ctrl/Cmd+Enter — save from any field (including the body textarea).
  agendaContent.addEventListener("keydown", async (e) => {
    if (e.key === "Escape") {
      // Let the link picker handle its own Escape first.
      if (window.NRCLinksUI && window.NRCLinksUI.isPickerVisible()) return;
      if (window.NRCInspector?.hasEntity()) return;
      e.stopPropagation();
      e.preventDefault();
      if (noteDetailDirty) {
        if (await confirmDiscardNoteEditsIfDirty()) cancelNoteEdit();
      } else {
        switchToPreviewPanel();
      }
    } else if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.stopPropagation();
      e.preventDefault();
      saveNoteFromPanel();
    }
  });
}

function showNoteEditPanel(note) {
  const { title, project, tags, format } = parseNotePreview(note.preview);
  currentDetailNote = note;
  noteEditMode = true;
  notePreviewMode = false;
  noteEditOriginalPreview = note.preview;
  noteEditOriginalPayload = note.payload || "";
  setNoteDetailDirty(false);

  const agendaPanel = document.querySelector(".agenda-panel");
  const agendaHeader = agendaPanel.querySelector(".panel-header");
  const agendaContent = agendaPanel.querySelector(".agenda-content");
  const agendaActions = document.getElementById("agendaActions");
  window.NRCLinksUI?.closeLinkPicker();

  agendaActions.style.display = "none";

  // Stash the live draft so a re-render cannot discard a message the operator
  // is still writing.
  const liveComposer = document.getElementById("noteCommentInput");
  if (liveComposer) noteComposerDraft = liveComposer.value;
  noteResourceOpen = window.NRCDetailUI.readResourceState(agendaContent);

  const MAX_PAYLOAD = window.NRCAssets.MAX_PAYLOAD_LENGTH;

  agendaHeader.innerHTML = `<div class="inspector-identity-row">
    <span class="header-text identity-reference">NOTE #${note.assetId}</span>
    ${buildNoteHeaderMetadata(note)}
    <span class="inspector-cell-label">STATE</span>
    ${window.NRCDetailUI.renderSaveState("SAVED")}
  </div><div class="inspector-mode-row">
    <button class="btn btn--primary header-operation task-modal-btn save" id="noteDetailSave" title="Save content (Ctrl+Enter)">SAVE</button>
    ${window.NRCDetailUI.renderHeaderAction({ id: "noteDetailToggleView", label: "CANCEL", command: "v", title: "Discard content edits (V)" })}
    ${window.NRCDetailUI.renderHeaderAction({ id: "noteShareLink", label: "SHARE", command: "s", title: "Copy read-only share link (S)" })}
    <button class="btn btn--danger header-operation inspector-matrix-control" id="noteDetailDelete" title="Delete note">DELETE</button>
    ${window.NRCDetailUI.renderCloseControl("noteDetailClose")}</div>`;

  agendaContent.innerHTML = `
    <div class="note-detail-panel">
      <div class="task-detail-tab-content note-detail-tab-content detail-edit-form record-document active" data-tab-content="detail">
        <div class="record-document record-document-scroll">
        <div class="note-preview-title"><span class="note-preview-title-text">${escapeHtml(title || "(No title)")}</span>${noteFieldControl(note, "title", { label: "", rename: true })}</div>
        ${buildNotePreviewLedger(note, format, true)}
        <section class="detail-edit-section detail-edit-section--content" data-detail-section="content">
          <div class="note-detail-row note-detail-row-content detail-edit-field detail-edit-field--content">
            <div class="detail-edit-label-row">
              <span class="task-detail-field-stats" id="noteDetailContentStats">0 / ${MAX_PAYLOAD} BYTES</span>
            </div>
            <div class="note-detail-content-container">
              <textarea class="note-detail-textarea" id="noteDetailContent" aria-label="Content" placeholder="${format === "html" ? "Self-contained HTML document..." : "Markdown content..."}">${escapeHtml(note.payload || "")}</textarea>
            </div>
            <div class="note-html-security-note" ${format === "html" ? "" : "hidden"}>HTML/CSS RUNS IN A SCRIPT-FREE SANDBOX. SCRIPTS, NETWORK REQUESTS, FORMS, EMBEDS, LINKS, AND NRC DATA ACCESS ARE BLOCKED.</div>
          </div>
        </section>
        </div>
        ${renderNoteDocumentResources(note, renderNoteMarkdownPresentation(note.payload || "", note.attachments || [], format).ampThreads)}
      </div>
      ${noteMessagesAreaHtml(note)}
    </div>
  `;

  renderNoteLinks(note);

  initNoteEditEventHandlers();
  document.getElementById("noteLinkAdd").onclick = event => {
    event.stopPropagation();
    document.getElementById("noteLinkPicker").open({
      anchor: event.currentTarget, sourceType: 1, sourceEntity: note,
      onSelect: (item, relation) => window.NRCLinksUI.createPickedLink(note, 1, item, relation),
    });
  };
  initNoteCommentEventHandlers(note);

  const editor = document.getElementById("noteDetailContent");
  if (editor) {
    editor.focus();
  }
}

async function deleteNoteFromPanel() {
  const note = currentDetailNote;
  if (!note) return;
  const confirmed = await window.NRCDialog.confirm(
    `Delete note #${note.assetId} “${parseNotePreview(note.preview).title || "(untitled)"}”?`,
    { title: "DELETE NOTE", confirmLabel: "Delete Note" },
  );
  if (confirmed) {
    setNoteDetailDirty(false);
    if (window.NRCInspector) await window.NRCInspector.close();
    else clearNoteSelection({ fromInspector: true });
    sendDeleteNote(note.convId, note.assetId);
  }
}

function initNoteEditEventHandlers() {
  // VIEW toggle: return to read-only preview. If the form is dirty, prompt to
  // discard first (mirrors the task panel's VIEW button). On discard we revert
  // to the original preview; if clean we just switch back preserving the
  // (unchanged) content.
  const viewBtn = document.getElementById("noteDetailToggleView");
  if (viewBtn) {
    viewBtn.addEventListener("click", async () => {
      if (noteDetailDirty) {
        if (await confirmDiscardNoteEditsIfDirty()) cancelNoteEdit();
      } else {
        switchToPreviewPanel();
      }
    });
  }

  const shareBtn = document.getElementById("noteShareLink");
  if (shareBtn) {
    shareBtn.addEventListener("click", () => {
      if (currentDetailNote) {
        copySharedNoteLink(currentDetailNote);
      }
    });
  }

  const closeBtn = document.getElementById("noteDetailClose");
  if (closeBtn) {
    closeBtn.addEventListener("click", () => {
      if (window.NRCInspector) window.NRCInspector.close();
      else confirmDiscardNoteEditsIfDirty().then((confirmed) => {
        if (confirmed) clearNoteSelection({ fromInspector: true });
      });
    });
  }

  const saveBtn = document.getElementById("noteDetailSave");
  if (saveBtn) {
    saveBtn.addEventListener("click", saveNoteFromPanel);
  }

  const deleteBtn = document.getElementById("noteDetailDelete");
  if (deleteBtn) {
    deleteBtn.addEventListener("click", deleteNoteFromPanel);
  }

  const formatInput = document.getElementById("noteDetailFormat");
  if (formatInput) {
    formatInput.addEventListener("change", () => {
      const html = formatInput.value === "html";
      const editor = document.getElementById("noteDetailContent");
      if (editor) editor.placeholder = html ? "Self-contained HTML document..." : "Markdown content...";
      document.querySelector(".note-html-security-note")?.toggleAttribute("hidden", !html);
      setNoteDetailDirty(true);
    });
  }

  const contentEditor = document.getElementById("noteDetailContent");
  if (contentEditor) {
    contentEditor.addEventListener("input", updateNoteDetailFieldStats);
  }

  // Panel-level handlers (dirty tracking, keyboard shortcuts) are bound once on
  // the container; see the helper.
  bindNoteDetailPanelHandlers();

  updateNoteDetailFieldStats();
}

function updateNoteDetailFieldStats() {
  const MAX_TITLE = 256;
  const MAX_PAYLOAD = window.NRCAssets.MAX_PAYLOAD_LENGTH;

  const applyThreshold = (stats, bytes, max) => {
    if (!stats) return;
    stats.textContent = `${bytes.toLocaleString()} / ${max.toLocaleString()} BYTES`;
    stats.classList.remove("is-warn", "is-danger");
    if (bytes > max) {
      stats.classList.add("is-danger");
    } else if (bytes >= max * 0.95) {
      stats.classList.add("is-danger");
    } else if (bytes >= max * 0.8) {
      stats.classList.add("is-warn");
    }
  };

  const contentInput = document.getElementById("noteDetailContent");
  const contentStats = document.getElementById("noteDetailContentStats");
  if (contentInput && contentStats) {
    applyThreshold(contentStats, new TextEncoder().encode(contentInput.value).length, MAX_PAYLOAD);
  }
}

function saveNoteFromPanel() {
  if (!currentDetailNote) return;
  // The panel-level Ctrl+Enter shortcut stays bound while the preview is shown;
  // outside edit mode there is no form to read.
  if (!noteEditMode) return;
  if (!isSelectedNote(currentDetailNote.convId, currentDetailNote.assetId)) return;
  if (noteWritesInFlight.has(`${currentDetailNote.convId}:${currentDetailNote.assetId}`)) {
    notifyNoteSaveError("NOTE SAVE IN PROGRESS — RETRY WHEN SAVED");
    return;
  }

  const format = normalizeNoteFormat(document.getElementById("noteDetailFormat")?.value);
  const content = document.getElementById("noteDetailContent").value;

  const editingNote = getCanonicalNote(currentDetailNote);
  if (!editingNote?.updatedAt) {
    notifyNoteSaveError("NOTE VERSION IS UNAVAILABLE; REFRESH AND RETRY");
    return;
  }
  const preview = patchNotePreview(editingNote.preview, {
    teaser: generateTeaser(content, format),
    format,
  });
  if (new TextEncoder().encode(content).length > window.NRCAssets.MAX_PAYLOAD_LENGTH ||
      new TextEncoder().encode(preview).length > window.NRCAssets.MAX_PREVIEW_LENGTH) {
    window.NRCDetailUI.setSaveState("FAILED", document);
    notifyNoteSaveError("CONTENT OR METADATA EXCEEDS THE BYTE LIMIT");
    return;
  }
  const generation = ++noteDetailSaveGeneration;
  window.NRCDetailUI.setSaveState("SAVING", document);
  writeNote(editingNote, (current, callbacks) => window.NRCTransactions.sendAssetMetadataPatch(
    current, patchNotePreview(current.preview, { teaser: generateTeaser(content, format), format }), content, callbacks,
  )).then(saved => {
    if (generation !== noteDetailSaveGeneration || currentDetailNote?.assetId !== editingNote.assetId || currentDetailNote?.convId !== editingNote.convId) return;
    setNoteDetailDirty(false);
    window.NRCDetailUI.setSaveState("SAVED", document);
    noteEditOriginalPreview = saved.preview;
    noteEditOriginalPayload = content;
  }).catch(error => {
    if (generation !== noteDetailSaveGeneration || currentDetailNote?.assetId !== editingNote.assetId || currentDetailNote?.convId !== editingNote.convId) return;
    noteDetailDirty = true;
    window.NRCDetailUI.setSaveState("FAILED", document);
    notifyNoteSaveError(error.message);
  });
}

function notifyNoteSaveError(message) {
  if (window.NRCDialog && typeof window.NRCDialog.notify === "function") {
    window.NRCDialog.notify(message, { logType: "Error" });
  } else if (typeof logMessage === "function") {
    logMessage("Error", message);
  } else {
    console.warn(message);
  }
}

function hideNoteDetailPanel() {
  const agendaPanel = document.querySelector(".agenda-panel");
  if (!agendaPanel) return;
  
  const agendaHeader = agendaPanel.querySelector(".panel-header");
  const agendaContent = agendaPanel.querySelector(".agenda-content");
  const agendaActions = document.getElementById("agendaActions");

  window.NRCLinksUI?.closeLinkPicker();
  agendaHeader.classList.remove("is-dirty");
  agendaContent.innerHTML = "";
  agendaActions.style.display = "none";
}

// =============================================================================
// EDGE/LINK RENDERING (delegates to NRCLinksUI)
// =============================================================================

function renderNoteLinks(note) {
  if (window.NRCLinksUI) {
    window.NRCLinksUI.renderLinks(note, 1); // TargetType.Asset
  }
}

// =============================================================================
// EDGE CHANGE HANDLER
// =============================================================================

function handleNoteEdgeChanged(edge, action) {
  console.log("[NRCNotes] handleEdgeChanged:", action, edge);

  if (sharedNoteAsset) {
    const { TargetType } = window.NRCEdges;
    const noteAssetId = sharedNoteAsset.assetId;
    if (action === "list") {
      if (edge.targetType === TargetType.Asset && edge.targetId === noteAssetId) {
        sharedNoteEdges = edge.edges || [];
        renderSharedNoteView();
        fetchSharedLinkedTargets(sharedNoteAsset.convId, sharedNoteEdges, noteAssetId);
      }
    } else if (action === "created" || action === "deleted") {
      const involves =
        (edge.sourceType === TargetType.Asset && edge.sourceId === noteAssetId) ||
        (edge.targetType === TargetType.Asset && edge.targetId === noteAssetId);
      if (involves) {
        loadSharedNoteEdges(sharedNoteAsset);
      }
    }
  }
  
  // Re-render links if we're viewing a note that's affected
  if (!currentDetailNote) {
    console.log("[NRCNotes] No currentDetailNote, skipping");
    return;
  }

  const { TargetType } = window.NRCEdges;
  const noteAssetId = currentDetailNote.assetId;
  console.log("[NRCNotes] Current note assetId:", noteAssetId);

  if (edge.convId !== currentDetailNote.convId) return;
  if (action === "all" || action === "cache") {
    renderNoteLinks(currentDetailNote);
    return;
  }
  if (action === "list") {
    // Edge list response - check if it's for our current note
    console.log("[NRCNotes] List response for targetType:", edge.targetType, "targetId:", edge.targetId, "edges:", edge.edges?.length);
    if (edge.targetType === TargetType.Asset && edge.targetId === noteAssetId) {
      console.log("[NRCNotes] Matches current note, re-rendering links");
      renderNoteLinks(currentDetailNote);
    }
    return;
  }

  if (action === "created" || action === "deleted") {
    // Check if this edge involves our current note
    const involves =
      (edge.sourceType === TargetType.Asset && edge.sourceId === noteAssetId) ||
      (edge.targetType === TargetType.Asset && edge.targetId === noteAssetId);

    console.log("[NRCNotes] Edge involves current note:", involves);
    if (involves) {
      renderNoteLinks(currentDetailNote);
    }
  }
}

// =============================================================================
// COMMAND HANDLER
// =============================================================================

function handleNoteCommand(args) {
  const text = args.join(" ");
  if (!text) {
    logMessage("Error", "Usage: /note <title>");
    return true;
  }
  sendCreateNote(text, "");
  logSystem("NOTE CREATED", "notes");
  return true;
}

// =============================================================================
// EVENT HANDLERS
// =============================================================================

function handleNoteChanged(asset, eventType, previousAsset = null) {
  if (eventType === "list_page" && asset && asset.convId !== undefined) {
    const canAppend = !notesListDirty && renderedNotesRoomId === asset.convId;
    invalidateNotesList(asset.convId);
    const state = getNotesPaginationState(asset.convId);
    state.loading = false;
    state.initialized = true;
    state.hasMore = !!asset.hasMore;
    state.nextCursorUpdatedAt = asset.hasMore ? asset.nextCursorUpdatedAt : null;
    state.nextCursorAssetId = asset.hasMore ? asset.nextCursorAssetId : null;
    state.totalCount = Number.isFinite(asset.totalCount) ? asset.totalCount : state.totalCount;

    if (notesViewActive && asset.convId === 0n) {
      const notesSearchInput = document.getElementById("notesSearch");
      const searchTerm = (notesSearchInput?.value || "").trim();
      renderNotesView({ append: searchTerm.length === 0 && canAppend });
      resumePendingNotePageNavigation(asset.convId);
    }
    return;
  }

  if (eventType === "project_list" && asset && asset.convId !== undefined) {
    const projects = asset.projects || [];
    notesProjectsByRoom.set(asset.convId, new Set(projects));
    populateNotesProjectFilter();
    return;
  }

  if (eventType === "tag_list" && asset && asset.convId !== undefined) {
    const tags = asset.tags || [];
    notesTagsByRoom.set(asset.convId, new Set(tags));
    populateNotesTagFilter();
    return;
  }

  if (asset && asset.convId !== undefined) {
    const state = getNotesPaginationState(asset.convId);
    if (eventType === "created" && Number.isFinite(state.totalCount)) {
      state.totalCount += 1;
    }
    if (eventType === "deleted" && Number.isFinite(state.totalCount)) {
      state.totalCount = Math.max(0, state.totalCount - 1);
    }
    if ((eventType === "created" || eventType === "updated" || eventType === "deleted") && asset.convId === 0n) {
      if (window.NRCAssets?.sendListNoteProjects) {
        window.NRCAssets.sendListNoteProjects(0n);
      }
      if (window.NRCAssets?.sendListNoteTags) {
        window.NRCAssets.sendListNoteTags(0n);
      }
    }
    if (eventType === "deleted" && isSelectedNote(asset.convId, asset.assetId)) {
      if (!window.NRCInspector?.entityDeleted?.({ roomId: asset.convId, type: "note", id: asset.assetId })) {
        clearNoteSelection({ fromInspector: true });
      }
    }
  }

  if (
    sharedNoteAsset &&
    asset &&
    asset.convId === sharedNoteAsset.convId &&
    asset.assetId === sharedNoteAsset.assetId
  ) {
    if (eventType === "deleted") {
      sharedNoteAsset = null;
      sharedNoteEdges = [];
      sharedNoteLoading = false;
      renderSharedNoteView("NOTE NOT FOUND");
    } else if (eventType === "updated" || eventType === "fetched") {
      sharedNoteAsset = asset;
      renderSharedNoteView();
    }
  }

  // Refresh an existing row in place, but only render the detail when the
  // response still belongs to the selected note. Stale keyboard-navigation
  // responses must not rebuild the complete notes list.
  if (eventType === "fetched") {
    if (asset) {
      const listFieldsChanged = previousAsset === null ||
        previousAsset.preview !== asset.preview ||
        previousAsset.owner !== asset.owner ||
        previousAsset.createdAt !== asset.createdAt ||
        previousAsset.updatedAt !== asset.updatedAt;
      if (listFieldsChanged) {
        invalidateNotesList(asset.convId);
        refreshRenderedNoteRow(asset);
      }
    }
    if (asset && isSelectedNote(asset.convId, asset.assetId) && !noteEditMode) {
      showNoteDetailPanel(asset);
    }
    if (!noteEditMode) return;
  }

  if (asset === null) {
    notesListDirty = true;
  } else if (asset?.convId !== undefined) {
    invalidateNotesList(asset.convId);
  }

  if (
    eventType === "updated" &&
    asset &&
    isSelectedNote(asset.convId, asset.assetId) &&
    currentDetailNote?.convId === asset.convId &&
    notePreviewMode
  ) {
    showNotePreviewPanel(asset);
  } else if (
    (eventType === "updated" || eventType === "fetched") && asset && noteEditMode &&
    isSelectedNote(asset.convId, asset.assetId) && currentDetailNote?.convId === asset.convId
  ) {
    // Keep the authoritative version/metadata current without replacing the
    // live content textarea (which may contain an unsaved draft).
    currentDetailNote = asset;
    const metadata = document.querySelector(".note-inline-metadata");
    if (metadata) metadata.innerHTML = noteFieldControl(asset, "project") + noteFieldControl(asset, "tags");
    const title = document.querySelector(".note-preview-title");
    if (title) title.innerHTML = `<span class="note-preview-title-text">${escapeHtml(parseNotePreview(asset.preview).title)}</span>${noteFieldControl(asset, "title", { label: "", rename: true })}`;
  }

  // Re-render notes view if we're in notes mode
  if (notesViewActive) {
    if (asset === null || asset.convId === 0n) {
      renderNotesView();
    }
  }
}

function handleNoteCommentChanged(asset, action) {
  if (!asset || asset.parentType !== window.NRCAssets?.ParentType?.Asset) return;

  const noteId = asset.parentId;
  if (
    currentDetailNote &&
    currentDetailNote.assetId === noteId &&
    currentDetailNote.convId === asset.convId
  ) {
    if (!noteDetailDirty) {
      showNoteDetailPanel(currentDetailNote);
    }
  }

  if (
    action === "created" &&
    asset.convId === 0n &&
    asset.owner !== myNickname
  ) {
    const snippet = (asset.payload || asset.preview || "").slice(0, 50);
    const ellipsis = (asset.payload || asset.preview || "").length > 50 ? "..." : "";
    logSystem(
      `${asset.owner} commented on note #${noteId}: "${snippet}${ellipsis}"`,
      "notes",
    );
  }
}

function onNotesRoomSwitch() {
  pauseNotesPageLoader();

  const state = getNotesPaginationState(0n);

  if (notesViewActive) {
    if (!state.initialized && !state.loading) {
      fetchNotesPage(0n, { reset: true });
    }
    // Refresh project list for dropdown
    if (window.NRCAssets?.sendListNoteProjects) {
      window.NRCAssets.sendListNoteProjects(0n);
    }
    if (window.NRCAssets?.sendListNoteTags) {
      window.NRCAssets.sendListNoteTags(0n);
    }
    renderNotesView();
  }
}

// =============================================================================
// INITIALIZATION
// =============================================================================

function initNotes() {
  initNotesSearch();
  initNotesProjectFilter();
  initNotesTagFilter();
  document.addEventListener("keydown", handleNotesKeyboardNavigation);

  // Register for note asset changes
  if (window.NRCAssets && window.NRCAssets.setOnNoteChanged) {
    window.NRCAssets.setOnNoteChanged(handleNoteChanged);
  }

  if (window.NRCAssets && window.NRCAssets.addCommentChangeListener) {
    window.NRCAssets.addCommentChangeListener(handleNoteCommentChanged);
  }

  // Register for edge changes
  if (window.NRCEdges && window.NRCEdges.addEdgeChangeListener) {
    window.NRCEdges.addEdgeChangeListener(handleNoteEdgeChanged);
  }
}

function initNotesProjectFilter() {
  const select = document.getElementById("notesProjectFilter");
  if (!select) return;

  select.addEventListener("change", () => {
    notesProjectFilter = select.value || null;
    if (notesProjectFilter) {
      notesTagFilter = null;
      const tagSelect = document.getElementById("notesTagFilter");
      if (tagSelect) tagSelect.value = "";
    }
    if (notesViewActive) {
      fetchNotesPage(0n, { reset: true });
    }
  });
}

function initNotesTagFilter() {
  const select = document.getElementById("notesTagFilter");
  if (!select) return;

  select.addEventListener("change", () => {
    notesTagFilter = select.value || null;
    if (notesTagFilter) {
      notesProjectFilter = null;
      const projectSelect = document.getElementById("notesProjectFilter");
      if (projectSelect) projectSelect.value = "";
    }
    if (notesViewActive) {
      fetchNotesPage(0n, { reset: true });
    }
  });
}

function populateNotesProjectFilter() {
  const select = document.getElementById("notesProjectFilter");
  if (!select) return;

  const currentValue = select.value;
  const projects = notesProjectsByRoom.get(0n);

  select.innerHTML = '<option value="">ALL</option>';
  if (projects) {
    const sorted = Array.from(projects).sort();
    for (const project of sorted) {
      const option = document.createElement("option");
      option.value = project;
      option.textContent = project;
      select.appendChild(option);
    }
  }

  // Restore selection if still valid
  if (currentValue && (!projects || projects.has(currentValue))) {
    select.value = currentValue;
  } else {
    select.value = "";
    notesProjectFilter = null;
    if (currentValue && notesViewActive) {
      fetchNotesPage(0n, { reset: true });
    }
  }
}

function populateNotesTagFilter() {
  const select = document.getElementById("notesTagFilter");
  if (!select) return;

  const currentValue = select.value;
  const tags = notesTagsByRoom.get(0n);

  select.innerHTML = '<option value="">ALL TAGS</option>';
  if (tags) {
    const sorted = Array.from(tags).sort();
    for (const tag of sorted) {
      const option = document.createElement("option");
      option.value = tag;
      option.textContent = tag;
      select.appendChild(option);
    }
  }

  if (currentValue && (!tags || tags.has(currentValue))) {
    select.value = currentValue;
  } else {
    select.value = "";
    notesTagFilter = null;
    if (currentValue && notesViewActive) {
      fetchNotesPage(0n, { reset: true });
    }
  }
}

function initNotesSearch() {
  const notesSearchInput = document.getElementById("notesSearch");
  if (notesSearchInput) {
    notesSearchInput.addEventListener("input", () => {
      if (notesViewActive) renderNotesView({ debounce: true });
    });
  }

  // Probe search service availability, re-check periodically if down
  probeSearchService();
}

async function probeSearchService() {
  try {
    const response = await fetch(getSearchUrl().replace("/search", "/search/health"), { method: "GET" });
    searchServiceAvailable = response.ok;
  } catch {
    searchServiceAvailable = false;
  }

  if (!searchServiceAvailable) {
    setTimeout(probeSearchService, 60000);
  }
}

// =============================================================================
// EXPORTS
// =============================================================================

window.NRCNotes = {
  // View toggle
  toggleNotesView,
  showNotesView,
  hideNotesView,
  isNotesViewActive: () => notesViewActive,
  
  // Selection
  selectedNoteId: () => selectedNoteId,
  selectNote,
  openNoteComments,
  clearNoteSelection,
  getSharedNoteUrl,
  showSharedNoteView,
  loadSharedNoteView,
  clearSharedNoteView,
  refreshSharedNoteView,
  
  // Edit/Preview mode
  isEditMode: () => noteEditMode,
  switchToPreviewPanel,
  cancelNoteEdit,
  confirmDiscardEdits: confirmDiscardNoteEditsIfDirty,
  
  // Commands
  handleNoteCommand,
  
  // Lifecycle
  initNotes,
  onNotesRoomSwitch,

  // For asset system integration
  sendCreateNote,
  sendUpdateNote,
  sendDeleteNote,
  getNotesForRoom,

  // Project filter
  populateNotesProjectFilter,
  populateNotesTagFilter,

  // For NRCLinksUI
  getCurrentNote: () => currentDetailNote,
  isEditMode: () => noteEditMode,

  parseNotePreview,
  fieldControl: noteFieldControl,
};
