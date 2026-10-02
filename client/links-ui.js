// =============================================================================
// LINKS UI - Shared entity picker and link rendering
// =============================================================================

// Only visibility is coordinated globally; each element owns its session.
let activeLinkPicker = null;

class NRCLinkPicker extends HTMLElement {
  session = 0;
  state = {
    isVisible: false,
    targetKind: "note",
    relation: 1, // Default: References
    highlightedIndex: 0,
    filteredItems: [],
    loading: false,
    loadError: "",
    loadGeneration: 0,
    hasMore: false,
    cursorPrimary: null,
    cursorId: null,
    totalCount: null,
    selecting: false,
    portal: null,
    sourceType: 1, // 1=Asset (Note), 2=Task
    sourceEntity: null,
  };

  connectedCallback() {
    if (this.children.length) return;
    this.innerHTML = renderLinkPickerContent();
    this.panel = this.firstElementChild;
    this.search = this.querySelector(".note-link-picker-search");
    this.list = this.querySelector(".note-link-picker-list");
    this.relationSelect = this.querySelector("select");
    this.onKeydown = (event) => this.handlePickerKeydown(event);
    this.onOutsideClick = (event) => this.handlePickerClickOutside(event);
    this.search.oninput = () => {
      this.state.highlightedIndex = 0;
      this.updateLinkPickerList();
    };
    this.relationSelect.onchange = () => {
      this.state.relation = Number(this.relationSelect.value);
      this.state.highlightedIndex = 0;
    };
    this.querySelector(".note-link-picker-types").onclick = (event) => {
      const button = event.target.closest("[data-kind]");
      if (!button) return;
      event.stopPropagation();
      this.state.targetKind = button.dataset.kind;
      this.state.highlightedIndex = 0;
      this.panel.querySelectorAll("[data-kind]").forEach(other => other.classList.toggle("active", other === button));
      this.loadLinkPickerItems({ reset: true });
    };
    this.querySelector(".note-link-picker-more").onclick = (event) => {
      event.stopPropagation();
      this.loadLinkPickerItems();
    };
  }

  disconnectedCallback() {
    // The host stays in the editor; only its panel is moved by Portal.
    this.close(true);
  }

  open({
    anchor,
    sourceType = 1,
    sourceEntity,
    kinds = ["note", "task", "file"],
    relation = null,
    onSelect = null,
  }) {
    if (!anchor || !sourceEntity || activeLinkPicker?.state.selecting) return;
    kinds = kinds.filter(kind => LINK_PICKER_KINDS[kind]);
    if (!kinds.length) throw new Error("Link picker requires a target kind");
    const wasOpen = this.state.isVisible;
    activeLinkPicker?.close();
    if (wasOpen) return;
    this.session++;
    this.anchor = anchor;
    this.onSelect = onSelect;
    this.state.sourceType = sourceType;
    this.state.sourceEntity = sourceEntity;
    this.state.targetKind = kinds[0];
    this.state.relation = relation?.value ?? 1;
    this.state.highlightedIndex = 0;
    this.search.value = "";
    this.relationSelect.value = String(this.state.relation);
    const fixed = this.panel.querySelector(".note-link-picker-fixed-relation");
    fixed.textContent = relation?.label || "";
    fixed.hidden = !relation;
    this.relationSelect.parentElement.hidden = !!relation;
    this.panel.querySelector(".note-link-picker-types").innerHTML = kinds.length === 1
      ? `<span class="note-link-picker-fixed-type">${LINK_PICKER_KINDS[kinds[0]].label}</span>`
      : kinds.map((kind, index) => `<button class="btn note-link-picker-type${index === 0 ? " active" : ""}" type="button" data-kind="${kind}">${LINK_PICKER_KINDS[kind].label}</button>`).join("");
    this.panel.classList.remove("hidden");
    this.state.isVisible = true;
    activeLinkPicker = this;
    this.anchor.setAttribute("aria-expanded", "true");
    if (typeof Portal !== "undefined") {
      this.relationSelect.parentElement.portalBoundary = anchor.closest(".agenda-content");
      this.state.portal = Portal.create(this.panel, anchor, {
        position: "top",
        align: "right",
        matchWidth: false,
        offsetY: 2,
      });
      this.state.portal.show();
    }
    document.addEventListener("keydown", this.onKeydown, true);
    document.addEventListener("click", this.onOutsideClick);
    this.loadLinkPickerItems({ reset: true });
    this.search.focus();
  }

  close(force = false) {
    if (!this.state.isVisible || (this.state.selecting && !force)) return;
    this.state.isVisible = false;
    this.session++;
    this.state.loadGeneration++;
    this.state.selecting = false;
    window.CustomSelect?.close(this.relationSelect);
    this.state.portal?.destroy();
    this.state.portal = null;
    // A removed editor has no portal origin left to restore into.
    this.append(this.panel);
    this.panel.classList.add("hidden");
    this.anchor?.setAttribute("aria-expanded", "false");
    document.removeEventListener("keydown", this.onKeydown, true);
    document.removeEventListener("click", this.onOutsideClick);
    if (activeLinkPicker === this) activeLinkPicker = null;
    this.state.sourceEntity = null;
    if (this.dynamic) this.remove();
    document.dispatchEvent(new CustomEvent("nrc:link-picker-closed"));
  }

  loadLinkPickerItems({ reset = false } = {}) {
    const linkPickerState = this.state;
    if (!linkPickerState.isVisible || !linkPickerState.sourceEntity) return;
    if (linkPickerState.loading && !reset) return;
    if (!reset && !linkPickerState.hasMore) return;
    if (reset) {
      linkPickerState.loading = false;
      linkPickerState.hasMore = true;
      linkPickerState.cursorPrimary = null;
      linkPickerState.cursorId = null;
      linkPickerState.totalCount = null;
    }
    const generation = ++linkPickerState.loadGeneration;
    const room = linkPickerState.sourceEntity.convId;
    const kind = linkPickerState.targetKind;
    const current = () =>
      generation === linkPickerState.loadGeneration &&
      linkPickerState.isVisible &&
      linkPickerState.targetKind === kind;
    const cursorPrimary = linkPickerState.cursorPrimary;
    const cursorId = linkPickerState.cursorId;
    if (kind === "task") {
      if (!window.NRCTasks?.sendListTasksPaged)
        return this.pickerLoadFailed("PAGINATION UNAVAILABLE");
    } else {
      const assetType =
        kind === "file"
          ? window.NRCAssets?.AssetType?.File
          : window.NRCAssets?.AssetType?.Note;
      if (assetType == null || !window.NRCAssets?.sendListAssetsPaged)
        return this.pickerLoadFailed("PAGINATION UNAVAILABLE");
    }
    linkPickerState.loading = true;
    linkPickerState.loadError = "";
    this.updateLinkPickerList({ preserveScroll: !reset });
    const onSuccess = (detail) => {
      if (!current()) return;
      const nextPrimary =
        kind === "task" ? detail.nextCursorSortAt : detail.nextCursorUpdatedAt;
      const nextId =
        kind === "task" ? detail.nextCursorTaskId : detail.nextCursorAssetId;
      if (
        detail.hasMore &&
        (nextPrimary == null ||
          nextId == null ||
          (nextPrimary === cursorPrimary && nextId === cursorId))
      ) {
        this.pickerLoadFailed("INVALID PAGE CURSOR", { preserveScroll: true });
        return;
      }
      linkPickerState.loading = false;
      linkPickerState.hasMore = !!detail.hasMore;
      linkPickerState.cursorPrimary = detail.hasMore ? nextPrimary : null;
      linkPickerState.cursorId = detail.hasMore ? nextId : null;
      linkPickerState.totalCount = Number.isFinite(detail.totalCount)
        ? detail.totalCount
        : linkPickerState.totalCount;
      this.updateLinkPickerList({ preserveScroll: true });
    };
    const onError = (error) => {
      if (current())
        this.pickerLoadFailed(error?.message || "PAGINATION FAILED", {
          preserveScroll: true,
        });
    };
    const sent =
      kind === "task"
        ? window.NRCTasks.sendListTasksPaged(
            room,
            0x1f,
            50,
            cursorPrimary,
            cursorId,
            { onSuccess, onError },
          )
        : window.NRCAssets.sendListAssetsPaged(
            room,
            kind === "file"
              ? window.NRCAssets.AssetType.File
              : window.NRCAssets.AssetType.Note,
            false,
            50,
            cursorPrimary,
            cursorId,
            { onSuccess, onError },
          );
    if (sent === undefined) this.pickerLoadFailed("PAGINATION UNAVAILABLE");
  }

  pickerLoadFailed(message, { preserveScroll = false } = {}) {
    const linkPickerState = this.state;
    linkPickerState.loading = false;
    linkPickerState.loadError = message;
    this.updateLinkPickerList({ preserveScroll });
  }

  updateLinkPickerList({ preserveScroll = false } = {}) {
    const linkPickerState = this.state;
    const isTask = linkPickerState.sourceType === 2;
    const list = this.list;
    const searchInput = this.search;
    const previousScrollTop = preserveScroll ? list.scrollTop : 0;

    const sourceEntity = linkPickerState.sourceEntity;
    if (!sourceEntity) return;

    const searchTerm = (searchInput?.value || "").toLowerCase().trim();
    let items = [];

    if (linkPickerState.targetKind === "note") {
      // Get notes via window.NRCNotes
      const notes =
        window.NRCNotes?.getNotesForRoom?.(sourceEntity.convId) || [];
      for (const note of notes) {
        if (!isTask && note.assetId === sourceEntity.assetId) continue;

        const { title } = window.NRCNotes?.parseNotePreview?.(note.preview) || {
          title: "",
        };
        if (searchTerm && !title.toLowerCase().includes(searchTerm)) continue;

        items.push({
          id: note.assetId,
          label: `#${note.assetId}`,
          title: title || "(No title)",
          type: "note",
        });
      }
    } else if (linkPickerState.targetKind === "task") {
      // Get tasks via window.NRCTasks
      const tasks = window.NRCTasks?.roomTasks?.get(sourceEntity.convId);
      if (tasks) {
        for (const [taskId, task] of tasks) {
          if (isTask && taskId === sourceEntity.id) continue;
          if (searchTerm && !task.title?.toLowerCase().includes(searchTerm))
            continue;

          items.push({
            id: taskId,
            label: `#${taskId}`,
            title: task.title || "(No title)",
            type: "task",
          });
        }
      }
    } else if (linkPickerState.targetKind === "file") {
      const assets = window.NRCAssets?.roomAssets?.get(sourceEntity.convId);
      if (assets) {
        for (const asset of assets.values()) {
          if (asset.assetType !== window.NRCAssets.AssetType.File) continue;
          const title =
            window.NRCFiles?.parseMetadata?.(asset)?.title ||
            `FILE #${asset.assetId}`;
          if (searchTerm && !title.toLowerCase().includes(searchTerm)) continue;
          items.push({
            id: asset.assetId,
            label: `#${asset.assetId}`,
            title,
            type: "file",
            asset,
          });
        }
      }
    }

    linkPickerState.filteredItems = items;
    list.innerHTML = "";
    const picker = list.closest(".note-link-picker");
    const status = picker?.querySelector(
      ".note-link-picker-footer [role=status]",
    );
    const moreButton = picker?.querySelector(".note-link-picker-more");
    if (status)
      status.textContent = linkPickerState.loading
        ? "LOADING…"
        : linkPickerState.loadError ||
          `${items.length}${linkPickerState.totalCount == null ? "" : ` / ${linkPickerState.totalCount}`} LOADED`;
    // MORE is the promise that records are still out of reach. The list is drawn
    // from the loaded assets, so a session that already holds them all renders
    // every match while the last page still reports more on the server; the button
    // has nothing left to add then and hides. A search narrows `items` below the
    // total, so filtering keeps it.
    const everythingLoaded =
      linkPickerState.totalCount != null &&
      items.length >= linkPickerState.totalCount;
    if (moreButton) {
      moreButton.hidden =
        everythingLoaded ||
        (!linkPickerState.hasMore && !linkPickerState.loadError);
      moreButton.disabled = linkPickerState.loading;
      moreButton.textContent = linkPickerState.loadError ? "RETRY" : "MORE";
    }

    if (items.length === 0) {
      list.innerHTML = `<div class="note-link-picker-empty">${linkPickerState.loading ? "LOADING…" : linkPickerState.loadError ? "LOAD FAILED" : "NO ITEMS FOUND"}</div>`;
      list.scrollTop = previousScrollTop;
      return;
    }

    items.forEach((item, index) => {
      const el = document.createElement("div");
      el.className = "note-link-picker-item";
      if (index === linkPickerState.highlightedIndex) {
        el.classList.add("highlighted");
      }
      el.dataset.index = index;

      const idSpan = document.createElement("span");
      idSpan.className = "note-link-picker-item-id";
      idSpan.textContent = item.label;

      const titleSpan = document.createElement("span");
      titleSpan.className = "note-link-picker-item-title";
      titleSpan.textContent = item.title;

      el.appendChild(idSpan);
      el.appendChild(titleSpan);

      el.addEventListener("click", () => {
        linkPickerState.highlightedIndex = index;
        this.acceptPickerSelection();
      });

      el.addEventListener("mouseenter", () => {
        linkPickerState.highlightedIndex = index;
        el.parentElement
          .querySelectorAll(".note-link-picker-item")
          .forEach((item) => {
            item.classList.remove("highlighted");
          });
        el.classList.add("highlighted");
      });

      list.appendChild(el);
    });
    if (linkPickerState.loading || linkPickerState.loadError) {
      const status = document.createElement("div");
      status.className = "note-link-picker-status";
      status.textContent = linkPickerState.loading
        ? "LOADING ALL ITEMS…"
        : linkPickerState.loadError;
      list.appendChild(status);
    }
    list.scrollTop = previousScrollTop;
  }

  async acceptPickerSelection() {
    const linkPickerState = this.state;
    if (linkPickerState.selecting || !linkPickerState.isVisible) return;
    const item =
      linkPickerState.filteredItems[linkPickerState.highlightedIndex];
    if (!item) return;

    const session = this.session;
    const isCancelled = () => session !== this.session || !this.state.isVisible || !this.isConnected;
    linkPickerState.selecting = true;
    try {
      await this.onSelect(item, linkPickerState.relation, isCancelled);
      if (!isCancelled()) this.close(true);
    } catch (error) {
      if (!isCancelled()) {
        linkPickerState.selecting = false;
        linkPickerState.loadError = error?.message || "LINK FAILED";
        this.updateLinkPickerList();
      }
    }
  }

  movePickerHighlight(delta) {
    const linkPickerState = this.state;
    const count = linkPickerState.filteredItems.length;
    if (count === 0) return;

    linkPickerState.highlightedIndex =
      (linkPickerState.highlightedIndex + delta + count) % count;
    this.updatePickerHighlight();
  }

  updatePickerHighlight() {
    const linkPickerState = this.state;
    const list = this.list;

    const items = list.querySelectorAll(".note-link-picker-item");
    items.forEach((item, index) => {
      item.classList.toggle(
        "highlighted",
        index === linkPickerState.highlightedIndex,
      );
    });

    const highlighted = list.querySelector(
      ".note-link-picker-item.highlighted",
    );
    if (highlighted) {
      highlighted.scrollIntoView({ block: "nearest" });
    }
  }

  handlePickerKeydown(e) {
    const linkPickerState = this.state;
    if (!linkPickerState.isVisible) return;

    const customSelect = e.target.closest?.(".custom-select");
    const isInsideOpenCustomSelect =
      customSelect?.classList.contains("custom-select--open") ||
      [...(window.CustomSelect?.instances?.values?.() || [])].some(
        (instance) => instance.isOpen && instance.dropdown.contains(e.target),
      );
    if (isInsideOpenCustomSelect || (customSelect && e.key !== "Escape")) {
      return;
    }

    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      e.stopPropagation();
      this.movePickerHighlight(e.key === "ArrowDown" ? 1 : -1);
    } else if (e.key === "Enter") {
      e.preventDefault();
      e.stopPropagation();
      this.acceptPickerSelection();
    } else if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      this.close();
    }
  }

  handlePickerClickOutside(e) {
    if (!this.state.isVisible) return;

    const picker = this.panel;
    const addBtn = this.anchor;
    const relationSelect = this.relationSelect;
    const relationDropdown =
      window.CustomSelect?.instances?.get(relationSelect)?.dropdown;

    // The relation picker rebuilds its options during selection. The event path
    // still names the original dropdown even after the clicked row is removed.
    const path = e.composedPath();
    if (!path.includes(picker) && !path.includes(addBtn) && !path.includes(relationDropdown)) {
      this.close();
    }
  }
}

const LINK_PICKER_KINDS = {
  note: { label: "NOTE", targetType: 1 },
  task: { label: "TASK", targetType: 2 },
  file: { label: "FILE", targetType: 1 },
};

function renderLinkPickerContent() {
  return `<div class="note-link-picker hidden">
    <div class="note-link-picker-header">
      <nrc-select><select class="note-link-picker-relation" aria-label="Link relation" data-custom-select-portal data-custom-select-align="auto" data-custom-select-boundary=".agenda-content" data-custom-select-search-placeholder="FILTER RELATION...">
        <option value="1">references</option><option value="2">related-to</option>
        <option value="3">depends-on</option><option value="4">blocks</option>
        <option value="5">derived-from</option><option value="6">supersedes</option>
      </select></nrc-select>
      <span class="note-link-picker-fixed-relation" hidden></span>
      <div class="note-link-picker-types"></div>
    </div>
    <input type="text" class="note-link-picker-search" aria-label="Search link targets" placeholder="SEARCH..." autocomplete="off">
    <div class="note-link-picker-list"></div>
    <div class="note-link-picker-footer"><span role="status"></span><button class="btn note-link-picker-more" type="button">MORE</button></div>
  </div>`;
}

customElements.define("nrc-link-picker", NRCLinkPicker);

function openEntityPicker({ className = "", container, ...options }) {
  if (
    !options.anchor ||
    !options.sourceEntity ||
    activeLinkPicker?.state.selecting
  )
    return;
  activeLinkPicker?.close();
  const picker = document.createElement("nrc-link-picker");
  picker.dynamic = true;
  // Lists may replace their rows during pagination. Mount in their owning editor.
  (container || options.anchor.parentElement).append(picker);
  if (className) picker.panel.classList.add(className);
  picker.open(options);
  return picker;
}

function createPickedLink(sourceEntity, sourceType, item, relation) {
  window.NRCEdges.sendCreateEdge(
    sourceEntity.convId,
    sourceType,
    sourceType === 2 ? sourceEntity.id : sourceEntity.assetId,
    LINK_PICKER_KINDS[item.type].targetType,
    item.id,
    relation,
  );
}

// =============================================================================
// LINKS RENDERING
// =============================================================================

async function loadLinks(convId, sourceType, entityId, isCancelled, { prefetch = false } = {}) {
  // Offline inspection continues to use the last cached detail.
  if (typeof serverReady !== "undefined" && !serverReady) return;
  let page;
  do {
    page = await window.NRCEdges.requestEdgePage(convId, sourceType, entityId, {
      session: page?.session, isCancelled, limit: prefetch ? 5 : undefined,
    });
    if (isCancelled()) return;
    if (prefetch && page.hasMore) throw new Error("Note exceeds speculative link budget");
  } while (page.hasMore);
  const assets = new Set();
  const tasks = new Set();
  for (const edge of window.NRCEdges.getEdgesForEntity(convId, sourceType, entityId)) {
    const outgoing = edge.sourceType === sourceType && edge.sourceId === entityId;
    const type = outgoing ? edge.targetType : edge.sourceType;
    const id = outgoing ? edge.targetId : edge.sourceId;
    (type === 2 ? tasks : assets).add(id);
  }
  // Hover must not fan out across an arbitrarily large graph. A click can
  // finish a high-degree note through the normal, complete loading path.
  if (prefetch && assets.size + tasks.size > 4) throw new Error("Note exceeds speculative target budget");
  const results = await Promise.allSettled([
    ...[...assets].map(id => new Promise((resolve, reject) => {
      const request = window.NRCAssets.requestAsset(convId, id, { onSuccess: resolve, onError: reject });
      if (request === undefined) reject(new Error("Asset transport unavailable"));
    })),
    ...[...tasks].map(id => new Promise((resolve, reject) => {
      window.NRCTasks.requestTask(convId, id, { onSuccess: resolve, onError: reject });
    })),
  ]);
  // Keep already-issued requests accounted for even when one target fails.
  for (const result of results) if (result.status === "rejected") throw result.reason;
}

// Kind of a link endpoint: tasks first, notes second, customer records last.
// Asset targets use the shared asset type label (NOTE, REMINDER, COMPANY,
// CONTACT, ACTIVITY, SLICE). An uncached asset reads as a note: the link
// picker's asset targets are notes, and the list re-renders once the target
// hydrates.
function linkTargetKind(targetType, asset) {
  if (targetType === window.NRCEdges?.TargetType?.Task) return { label: "TASK", order: 0 };
  const label = asset ? window.NRCAssets?.getAssetTypeLabel?.(asset.assetType) || "NOTE" : "NOTE";
  return { label, order: label === "NOTE" ? 1 : 2 };
}

// An asset carries its own label in the preview: a note (and every customer
// record) a `title`, a slice its `name`. A preview that does not decode is the
// legacy plain-text title.
function assetPreviewLabel(asset) {
  const preview = asset?.preview;
  if (typeof preview !== "string" || preview === "") return "";
  try {
    const parsed = JSON.parse(preview);
    const label = parsed?.title || parsed?.name;
    return typeof label === "string" && label.trim() ? label.trim() : "";
  } catch {
    return preview.trim();
  }
}

// The slice register lists slice names for ids whose asset has not arrived yet.
function sliceName(sliceId) {
  const slices = window.NRCSlices?.getState?.().slices ?? [];
  return slices.find((entry) => String(entry.sliceId) === String(sliceId))?.name || "";
}

function compareLinkTargetIds(a, b) {
  if (a === b) return 0;
  return a < b ? -1 : 1;
}

function renderLinks(entity, sourceType) {
  if (window.NRCInspector?.isLoading?.()) return;
  const isTask = sourceType === 2;
  const listId = isTask ? "taskDetailLinksList" : "noteLinksList";
  const entityId = isTask ? entity.id : entity.assetId;
  const itemClass = isTask ? "task-detail-link-item" : "note-link-item";
  const emptyClass = isTask ? "task-detail-links-empty" : "note-links-empty";
  const directionClass = isTask ? "task-detail-link-direction" : "note-link-direction";
  const relationClass = isTask ? "task-detail-link-relation" : "note-link-relation";
  const targetClass = isTask ? "task-detail-link-target" : "note-link-target";
  const deleteClass = isTask ? "btn btn--row btn--danger task-detail-link-delete" : "btn btn--row btn--danger note-link-delete";

  const linksList = document.getElementById(listId);
  if (!linksList || !window.NRCEdges) return;
  const renderGeneration = (linksList.nrcLinksRenderGeneration || 0) + 1;
  linksList.nrcLinksRenderGeneration = renderGeneration;

  const { TargetType, RelationTypeNames, getEdgesForEntity } = window.NRCEdges;
  const edges = getEdgesForEntity(entity.convId, sourceType, entityId);

  // The read panels put files and links in separate resource registers; the edit
  // form keeps the flat layout and its sibling lookup.
  const linksRegister = linksList.closest?.("[data-resource]");

  if (window.NRCFiles) {
    const linksSection = linksList.closest(".note-links-section, .task-detail-links-section");
    let filesSection = linksRegister
      ? linksRegister.parentElement?.querySelector?.('[data-resource="files"] .file-assets-section')
      : linksSection?.previousElementSibling;
    if (linksSection && !linksRegister && !filesSection?.classList.contains("file-assets-section")) {
      filesSection = document.createElement("section");
      filesSection.className = "file-assets-section";
      linksSection.before(filesSection);
    }
    const readOnly = false; // Resource actions are independent of content editing.
    if (filesSection) window.NRCFiles.renderSection(filesSection, entity, sourceType, edges, {
      readOnly,
      hideWhenEmpty: readOnly,
      onHydrated: () => { if (document.getElementById(listId) === linksList) renderLinks(entity, sourceType); },
    });
  }

  linksList.innerHTML = "";

  const canAddLink = true;

  const showDelete = canAddLink;

  // Links are grouped by kind — tasks first, then notes, then customer records —
  // and ordered by target id inside each kind. The list reads by artifact
  // instead of by edge arrival order, and every row carries its kind token.
  const fileAssetType = window.NRCAssets?.AssetType?.File ?? 3;
  const roomAssets = window.NRCAssets?.roomAssets?.get(entity.convId);
  const entries = [];
  for (const edge of edges) {
    const isOutgoing = edge.sourceType === sourceType && edge.sourceId === entityId;
    const targetType = isOutgoing ? edge.targetType : edge.sourceType;
    const targetId = isOutgoing ? edge.targetId : edge.sourceId;
    const asset = targetType === TargetType.Asset ? roomAssets?.get(targetId) : null;

    if (window.NRCFiles && targetType === TargetType.Asset && asset?.assetType === fileAssetType) continue;
    entries.push({ edge, isOutgoing, targetType, targetId, kind: linkTargetKind(targetType, asset) });
  }
  entries.sort((a, b) => a.kind.order - b.kind.order || compareLinkTargetIds(a.targetId, b.targetId));

  // A links section inside a resource register keeps the collapsed line in step
  // with the list it holds: the number cell carries only the count, because the
  // label has its own column.
  if (linksRegister) {
    const count = linksRegister.querySelector("[data-resource-count]");
    if (count) count.textContent = String(entries.length);
    const preview = linksRegister.querySelector("[data-resource-preview]");
    if (preview) preview.textContent = entries.length
      ? resolveTargetName(entity.convId, entries[0].targetType, entries[0].targetId)
      : "";
    linksRegister.hidden = !canAddLink && entries.length === 0;
  }

  if (edges.length === 0) {
    // The affordance is named only where it exists: read-only previews have no
    // + LINK control.
    linksList.innerHTML = canAddLink
      ? `<div class="${emptyClass}">No active links — add with + LINK or accept a suggestion</div>`
      : `<div class="${emptyClass}">No active links</div>`;
    return;
  }

  for (const { edge, isOutgoing, targetType, targetId, kind } of entries) {
    const item = document.createElement("div");
    item.className = itemClass;
    item.dataset.edgeId = edge.edgeId.toString();

    const targetName = resolveTargetName(entity.convId, targetType, targetId);
    const isTargetTask = targetType === TargetType.Task;

    const direction = document.createElement("span");
    direction.className = directionClass;
    direction.textContent = isOutgoing ? "→" : "←";
    item.appendChild(direction);

    const kindToken = document.createElement("span");
    kindToken.className = "note-link-kind";
    kindToken.dataset.kind = kind.label.toLowerCase();
    kindToken.textContent = kind.label;
    item.appendChild(kindToken);

    const relation = document.createElement("span");
    relation.className = relationClass;
    relation.dataset.relation = String(edge.relation);
    relation.textContent = RelationTypeNames[edge.relation] || "link";
    item.appendChild(relation);

    const target = document.createElement("button");
    target.type = "button";
    target.className = targetClass + (isTargetTask ? " task-target" : " note-target");
    target.textContent = targetName;
    target.dataset.targetType = targetType;
    target.dataset.targetId = targetId.toString();
    target.addEventListener("click", () => navigateToTarget(entity.convId, targetType, targetId, sourceType));
    item.appendChild(target);

    if (showDelete) {
      const deleteBtn = document.createElement("button");
      deleteBtn.className = deleteClass;
      deleteBtn.textContent = "×";
      deleteBtn.title = "Remove link";
      deleteBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        deleteEdge(entity.convId, edge.edgeId);
      });
      item.appendChild(deleteBtn);
    }

    linksList.appendChild(item);
  }

  // Lazy-fetch uncached targets so linked entities always show their titles.
  const uncachedNotes = new Set();
  const uncachedTasks = new Set();
  const roomTasks = window.NRCTasks?.roomTasks?.get(entity.convId);
  for (const { targetType, targetId } of entries) {
    if (targetType === TargetType.Asset && (!roomAssets || !roomAssets.has(targetId))) {
      uncachedNotes.add(targetId);
    } else if (targetType === TargetType.Task && (!roomTasks || !roomTasks.has(targetId))) {
      uncachedTasks.add(targetId);
    }
  }
  for (const noteId of uncachedNotes) {
    if (window.NRCFiles) continue; // FILES owns bounded asset hydration and retry.
    window.NRCAssets?.requestAsset?.(entity.convId, noteId, {
      onSuccess: () => {
        // Re-render links now that we have the preview
        if (document.getElementById(listId) === linksList && linksList.nrcLinksRenderGeneration === renderGeneration) renderLinks(entity, sourceType);
      },
    });
  }
  for (const taskId of uncachedTasks) {
    window.NRCTasks?.requestTask?.(entity.convId, taskId, {
      onSuccess: () => {
        if (document.getElementById(listId) === linksList && linksList.nrcLinksRenderGeneration === renderGeneration) renderLinks(entity, sourceType);
      },
    });
  }
}

function resolveTargetName(convId, targetType, targetId) {
  const { TargetType } = window.NRCEdges;

  if (targetType === TargetType.Asset) {
    const assets = window.NRCAssets?.roomAssets?.get(convId);
    if (assets) {
      const asset = assets.get(targetId);
      if (asset) {
        // A slice is named by its preview's `name`, every other kind by `title`.
        const label = assetPreviewLabel(asset) || sliceName(targetId);
        return label || `${assetKindTitle(asset.assetType)} #${targetId}`;
      }
    }
    return sliceName(targetId) || `Note #${targetId}`;
  } else if (targetType === TargetType.Task) {
    const tasks = window.NRCTasks?.roomTasks?.get(convId);
    if (tasks) {
      const task = tasks.get(targetId);
      if (task) {
        return `#${targetId} ${task.title}`;
      }
    }
    return `Task #${targetId}`;
  }
  return `#${targetId}`;
}

function assetKindTitle(assetType) {
  const label = window.NRCAssets?.getAssetTypeLabel?.(assetType) || "Note";
  return label.charAt(0) + label.slice(1).toLowerCase();
}

function navigateToTarget(convId, targetType, targetId, sourceType = 1) {
  const { TargetType } = window.NRCEdges;

  if (targetType === TargetType.Asset) {
    const asset = window.NRCAssets?.roomAssets?.get(convId)?.get(targetId);
    if (asset && asset.assetType === window.NRCAssets?.AssetType?.CustomerCompany) {
      window.NRCCustomers?.openCompany(asset);
      return;
    }
    if (asset && [9, 10].includes(asset.assetType)) {
      window.NRCCustomers?.openRecord(asset.assetType === 9 ? "contact" : "activity", targetId);
      return;
    }
    // A slice lives in the task view: switch there and select the record the
    // register lists by name. An asset that has not arrived yet still counts as
    // a slice when the register lists its id.
    const sliceId = asset ? asset.assetType === (window.NRCAssets?.AssetType?.Slice ?? 11) : Boolean(sliceName(targetId));
    if (sliceId) {
      window.NRCViewManager?.setActiveView?.("kanban");
      const name = sliceName(targetId);
      if (name) window.NRCSlices?.select?.(name, { focusDetail: true });
      else window.NRCSlices?.ensureLoaded?.();
      return;
    }
    if (window.NRCInspector) {
      window.NRCInspector.openEntity({ roomId: convId, type: "note", id: targetId });
    }
  } else if (targetType === TargetType.Task) {
    if (window.NRCInspector) {
      window.NRCInspector.openEntity({ roomId: convId, type: "task", id: targetId });
    }
  }
}

function deleteEdge(convId, edgeId) {
  if (window.NRCEdges) {
    window.NRCEdges.sendDeleteEdge(convId, edgeId);
  }
}

// Export for use in notes.js and tasks.js
window.NRCLinksUI = {
  isPickerVisible: () => !!activeLinkPicker,
  openEntityPicker,
  createPickedLink,
  closeLinkPicker: (force = false) => activeLinkPicker?.close(force),
  updateLinkPickerList: () => activeLinkPicker?.updateLinkPickerList(),

  // Links rendering
  loadLinks,
  renderLinks,
  linkTargetKind,
  resolveTargetName,
  navigateToTarget,
  deleteEdge,
};
