(function () {
  "use strict";

  const MAX_COMMENT_BYTES = window.NRCAssets.MAX_PAYLOAD_LENGTH;

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function renderHeaderAction({ id, label, command, title, className = "" }) {
    return `<button class="btn header-operation inspector-matrix-control ${escapeHtml(className)}" id="${escapeHtml(id)}" data-inspector-command="${escapeHtml(command)}" title="${escapeHtml(title)}"><span>${escapeHtml(label)}</span></button>`;
  }

  function renderCloseControl(id) {
    return `<button class="btn header-operation task-detail-close inspector-matrix-control" id="${escapeHtml(id)}" data-inspector-command="escape" title="Close (Esc)" aria-label="Close"><span>CLOSE</span><b aria-hidden="true">×</b></button>`;
  }

  function setHeaderAction(button, { label, command }) {
    if (!button) return;
    button.dataset.inspectorCommand = command;
    const text = button.querySelector("span");
    if (text) text.textContent = label;
  }

  function renderSaveState(state = "SAVED") {
    return `<span class="detail-save-state" role="status" aria-live="polite" data-save-state="${escapeHtml(state)}">${escapeHtml(state)}</span>`;
  }

  function renderHeaderMetadata(rows) {
    return `<div class="inspector-metadata" tabindex="0" role="region" aria-label="Record metadata">${renderMetadataLedger(rows, { compactDateLabels: true })}</div>`;
  }

  function formatHeaderDate(nanos) {
    return nanos
      ? new Date(Number(BigInt(nanos) / 1000000n)).toLocaleString("de-DE", { dateStyle: "short", timeStyle: "short" })
      : "—";
  }

  function renderMetadataLedger(rows, { className = "", compactDateLabels = false } = {}) {
    const items = rows.map(({ label, value, role = "" }) => {
      const roleClass = role ? ` class="identity-${escapeHtml(role)}"` : "";
      const compact = compactDateLabels && (label === "CREATED" || label === "UPDATED");
      const labelClass = compact ? ' class="metadata-date-label"' : "";
      const title = compact ? ` title="${escapeHtml(label)}: ${escapeHtml(value || "—")}"` : "";
      return `<div><dt${labelClass}>${escapeHtml(label)}</dt><dd${roleClass}${title}>${escapeHtml(value || "—")}</dd></div>`;
    }).join("");
    const classes = `detail-metadata-ledger${className ? ` ${escapeHtml(className)}` : ""}`;
    return `<dl class="${classes}">${items}</dl>`;
  }

  function setSaveState(state, root = document) {
    const status = root.querySelector?.(".detail-save-state");
    if (!status) return;
    status.dataset.saveState = state;
    status.textContent = state;
  }

  // The element owns its field specification, not the table that happens to
  // render it. A portal keeps a draft/error alive when a live register redraws.
  const inlineSpecs = new Map();
  let inlineSequence = 0;
  let activeInline = null;

  function inlineField(spec) {
    const id = spec.key || String(++inlineSequence);
    inlineSpecs.set(id, spec);
    queueMicrotask(() => inlineSpecs.delete(id));
    const display = spec.display ?? (spec.value || "—");
    return `<nrc-inline-field data-control="${id}">${spec.label ? `<span class="inline-field-label">${escapeHtml(spec.label)}</span>` : ""}<button type="button" class="inline-field-value" aria-label="Edit ${escapeHtml(spec.name || spec.label || "field")}: ${escapeHtml(spec.value || "empty")}" aria-haspopup="dialog">${escapeHtml(display)}</button></nrc-inline-field>`;
  }

  function openInlineField(host, spec) {
    if (activeInline?.pending) return;
    activeInline?.close();
    if (spec.type === "attachments") {
      const modal = window.NRCModal.create({ title: "ATTACH", className: "file-assets-dialog file-attach-dialog", closeButton: true });
      const body = document.createElement("div");
      body.className = "file-attach-options";
      body.innerHTML = '<button class="btn" type="button">DIRECT ATTACHMENT</button><p>For this record only. Add or manage attachments.</p><button class="btn" type="button">FILE WITH METADATA</button><p>Reusable across records, with title, tags and description.</p>';
      const [direct, file] = body.querySelectorAll("button");
      direct.onclick = () => { modal.close(); openAttachments(spec); };
      file.onclick = () => {
        const entity = spec.current();
        modal.close();
        window.NRCFiles.openUpload({ entity, sourceType: entity.id != null ? 2 : 1 });
      };
      modal.actions.before(body);
      modal.show();
      return;
    }
    const anchor = host.querySelector("button");
    const ancestors = [];
    for (let parent = host.parentElement; parent && parent !== document.body; parent = parent.parentElement) ancestors.push(parent);
    const restoreFocus = () => {
      if (anchor.isConnected) { anchor.focus({ preventScroll: true }); return; }
      const scope = ancestors.find(element => element.isConnected);
      if (!scope) return;
      const replacement = scope.querySelector(`nrc-inline-field[data-control="${CSS.escape(host.dataset.control)}"] button`);
      const target = replacement || scope.querySelector('button:not(:disabled), input:not(:disabled), [tabindex="0"]') || scope;
      if (target === scope && !scope.hasAttribute("tabindex")) scope.tabIndex = -1;
      target.focus({ preventScroll: true });
    };
    const panel = document.createElement("form");
    panel.className = "inline-field-editor";
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-label", `Edit ${spec.name || spec.label || "field"}`);
    panel.setAttribute("popover", "manual");
    const heading = document.createElement("label");
    heading.textContent = spec.name || spec.label || "VALUE";
    const options = typeof spec.options === "function" ? spec.options() : spec.options;
    const suggestions = typeof spec.suggestions === "function" ? spec.suggestions() : spec.suggestions;
    let input = document.createElement(options ? "select" : "input");
    input.id = `inline-input-${++inlineSequence}`;
    heading.htmlFor = input.id;
    if (options) {
      for (const option of options) input.add(new Option(option.label, option.value));
    } else input.type = spec.type || "text";
    input.value = spec.value ?? "";
    input.required = Boolean(spec.required);
    if (spec.type === "number") input.step = "1";
    const state = document.createElement("span");
    state.className = "inline-field-state";
    state.setAttribute("role", "status");
    state.setAttribute("aria-live", "polite");
    state.textContent = suggestions ? "SEARCH · SELECT OR ENTER NEW · ESC CANCEL" : spec.options ? "SELECT TO SAVE · ESC CANCEL" : "ENTER SAVE · ESC CANCEL";
    const save = document.createElement("button");
    save.type = "submit";
    save.className = "btn btn--primary";
    save.textContent = "SAVE";
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "btn";
    cancel.textContent = "CANCEL";
    const actions = document.createElement("div");
    actions.className = "inline-field-actions";
    actions.append(save, cancel);
    if (spec.action) {
      const action = document.createElement("button");
      action.type = "button";
      action.className = "btn";
      action.textContent = spec.action.label;
      action.onclick = async () => {
        try { await spec.action.run(); }
        catch (error) { state.textContent = error.message || "ACTION FAILED"; }
      };
      actions.append(action);
    }
    panel.append(heading, input);
    let picker = null;
    if (suggestions) {
      const values = [...new Set(suggestions.map(value => String(value).trim()).filter(Boolean))];
      picker = window.CustomPicker.create({
        anchor: input,
        usePortal: false,
        options: [{ value: "", label: "— CLEAR", alwaysVisible: true }, ...values.map(value => ({ value, label: value }))],
        selectedValue: input.value,
        allowCustomValue: true,
        closeOnSelect: false,
        onSelect: option => { if (!session.pending) { input.value = String(option.value); submit(); } },
        onCustomValue: value => { if (!session.pending) { input.value = value; submit(); } },
      });
      picker.dropdown.classList.add("inline-field-picker");
      picker.searchInput.value = input.value;
      input.replaceWith(picker.dropdown);
      picker.searchInput.id = input.id;
      heading.htmlFor = picker.searchInput.id;
      input.removeAttribute("id");
      input = picker.searchInput;
      input.required = Boolean(spec.required);
    }
    panel.append(state, actions);
    const session = {
      pending: false,
      close() {
        if (picker) window.CustomPicker.destroy(picker);
        panel.remove();
        document.removeEventListener("pointerdown", outside, true);
        document.removeEventListener("keydown", keydown, true);
        anchor?.setAttribute("aria-expanded", "false");
        if (activeInline === session) activeInline = null;
      },
    };
    const dismiss = () => { if (!session.pending) { session.close(); restoreFocus(); } };
    const outside = event => { if (!panel.contains(event.target) && !host.contains(event.target)) dismiss(); };
    const keydown = event => {
      if (event.key === "Escape") { event.preventDefault(); event.stopImmediatePropagation(); dismiss(); }
    };
    panel.addEventListener("click", event => event.stopPropagation());
    panel.addEventListener("keydown", event => event.stopPropagation());
    cancel.onclick = dismiss;
    const submit = async event => {
      event?.preventDefault();
      if (session.pending || !input.reportValidity()) return;
      if (input.value === String(spec.value ?? "")) { dismiss(); return; }
      if (spec.maxBytes && new TextEncoder().encode(input.value).length > spec.maxBytes) {
        state.textContent = `EXCEEDS ${spec.maxBytes} UTF-8 BYTES`;
        panel.dataset.state = "failed";
        return;
      }
      session.pending = true;
      input.disabled = save.disabled = cancel.disabled = true;
      state.textContent = "SAVING";
      panel.dataset.state = "saving";
      const value = input.value;
      try {
        await spec.save(value);
        spec.value = value;
        if (anchor?.isConnected && spec.display !== "RENAME") {
          anchor.textContent = options?.find(option => String(option.value) === value)?.label || value || "—";
        }
        session.pending = false;
        session.close();
        restoreFocus();
      } catch (error) {
        session.pending = false;
        input.disabled = save.disabled = cancel.disabled = false;
        state.textContent = error?.message || "SAVE FAILED — RETRY OR CANCEL";
        panel.dataset.state = "failed";
        input.focus();
      }
    };
    panel.onsubmit = submit;
    if (spec.options) input.onchange = submit;
    activeInline = session;
    document.body.append(panel);
    panel.showPopover();
    const rect = anchor.getBoundingClientRect();
    panel.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - panel.offsetWidth - 8))}px`;
    panel.style.top = `${Math.max(8, Math.min(rect.bottom + 2, window.innerHeight - panel.offsetHeight - 8))}px`;
    anchor.setAttribute("aria-expanded", "true");
    document.addEventListener("pointerdown", outside, true);
    document.addEventListener("keydown", keydown, true);
    if (picker) window.CustomPicker.open(picker);
    else {
      input.focus();
      if (input.type === "text") input.select();
    }
  }

  function attachmentControl(entity, save, current = () => entity) {
    return inlineField({ key: `attachments-${entity.id ? "task" : "note"}-${entity.convId}-${entity.id ?? entity.assetId}`, label: "", name: "ATTACHMENTS", display: "+ ATTACH", type: "attachments", current, save });
  }

  // Form-backed fields use the same editor as immediate-save metadata, but
  // commit into the form draft. Its own SAVE still owns the persistence write.
  function bindSuggestedInput(input, { name, suggestions }) {
    if (!input) return;
    input.type = "hidden";
    const spec = {
      name, value: input.value, suggestions,
      save(value) {
        if (!input.isConnected || input.readOnly || input.disabled || input.closest("[inert]")) {
          throw new Error("RECORD CHANGED OR IS SAVING · CLOSE AND REOPEN THIS FIELD");
        }
        if (input.maxLength >= 0 && value.length > input.maxLength) throw new Error(`EXCEEDS ${input.maxLength} CHARACTERS`);
        input.value = value;
        input.dispatchEvent(new Event("input", { bubbles: true }));
      },
    };
    let host = input.nextElementSibling;
    if (host?.tagName !== "NRC-INLINE-FIELD") {
      input.insertAdjacentHTML("afterend", inlineField(spec));
      host = input.nextElementSibling;
    }
    host.spec = spec;
    const button = host.querySelector("button");
    button.textContent = input.value || "—";
    button.setAttribute("aria-label", `Edit ${name}: ${input.value || "empty"}`);
    button.disabled = input.readOnly || input.disabled;
  }

  function openAttachments(spec) {
    let pending = false;
    const modal = window.NRCModal.create({ title: "ATTACHMENTS", closeButton: true });
    modal.root.dataset.attachmentEditor = "true";
    const body = document.createElement("div");
    body.innerHTML = `<label class="btn" for="taskDetailFileInput">+ ADD FILE</label><input type="file" id="taskDetailFileInput" hidden><span id="taskDetailAttachmentsCount"></span><div id="taskDetailAttachmentsList" class="task-detail-attachments-list"></div><span class="inline-field-state" role="status" aria-live="polite"></span>`;
    modal.actions.before(body);
    modal.actions.innerHTML = '<button type="button" class="btn btn--primary">SAVE ATTACHMENTS</button><button type="button" class="btn">CANCEL</button>';
    const [save, cancel] = modal.actions.querySelectorAll("button");
    const state = body.querySelector('[role="status"]');
    modal.canClose = () => !pending && !getAttachmentDraftState().pendingCount;
    cancel.onclick = () => modal.cancel();
    save.onclick = async () => {
      if (pending) return;
      const draft = getAttachmentDraftState();
      if (draft.pendingCount || draft.errorCount) {
        state.textContent = draft.pendingCount ? "WAIT FOR UPLOADS" : "REMOVE FAILED UPLOADS BEFORE SAVING";
        return;
      }
      pending = true;
      save.disabled = cancel.disabled = true;
      body.querySelector("input").disabled = true;
      body.querySelector(".task-detail-attachments-list").inert = true;
      state.textContent = "SAVING";
      try {
        await spec.save(draft.uploaded);
        modal.close();
      } catch (error) {
        state.textContent = error.message || "SAVE FAILED";
        save.disabled = cancel.disabled = false;
        body.querySelector("input").disabled = false;
        body.querySelector(".task-detail-attachments-list").inert = false;
      } finally { pending = false; }
    };
    initAttachmentsForTask(spec.current());
    body.querySelector("input").onchange = handleAttachmentFileSelect;
    modal.show();
  }

  if (window.customElements) window.customElements.define("nrc-inline-field", class extends HTMLElement {
    connectedCallback() {
      if (this.spec) return;
      this.spec = inlineSpecs.get(this.dataset.control);
      inlineSpecs.delete(this.dataset.control);
      this.addEventListener("click", event => {
        event.stopPropagation();
        if (this.spec && event.target.closest("button")) openInlineField(this, this.spec);
      });
      this.addEventListener("dragstart", event => { event.preventDefault(); event.stopPropagation(); });
    }
  });

  // Messages render as markdown through the shared chat renderer, which is the
  // same marked + DOMPurify path a chat message takes. Comments keep their
  // plain-text payload on the wire; only the presentation changes.
  function renderMessageBody(comment) {
    const source = comment.payload || comment.preview || "";
    if (!source) return "";
    const render = typeof window.parseMarkdown === "function"
      ? window.parseMarkdown
      : escapeHtml;
    return `<div class="record-message-body message-content">${render(source)}</div>`;
  }

  function renderMessages({ comments, currentUser, formatTime }) {
    if (!comments || comments.length === 0) {
      return '<div class="record-messages-empty">NO MESSAGES YET · WRITE THE FIRST ONE</div>';
    }
    return comments.map((comment) => {
      const owner = comment.owner || "—";
      const assetId = escapeHtml(comment.assetId);
      return `
      <article class="record-message" data-asset-id="${assetId}">
        <header class="record-message-header">
          <span class="record-message-author">${escapeHtml(owner)}</span>
          <span class="record-message-time">${escapeHtml(formatTime(comment.createdAt))}</span>
          ${comment.owner === currentUser ? `<button class="btn btn--danger record-message-delete" data-asset-id="${assetId}" title="Delete">×</button>` : ""}
        </header>
        ${renderMessageBody(comment)}
      </article>`;
    }).join("");
  }

  // The strip is one register line, so its preview drops markdown syntax: a
  // heading marker or a table pipe reads as noise next to a count.
  function plainMessagePreview(source, limit = 80) {
    const text = String(source ?? "")
      .replace(/```[\s\S]*?```/g, " ")
      .replace(/`([^`]*)`/g, "$1")
      .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/^\s{0,3}(?:#{1,6}|>|[-*+]|\d+\.)\s+/gm, "")
      .replace(/(\*\*|__|\*|_|~~)/g, "")
      .replace(/\|/g, " ")
      .replace(/\s+/g, " ")
      .trim();
    return text.length > limit ? `${text.slice(0, limit)}…` : text;
  }

  function messagePreview(comments, limit = 80) {
    const last = (comments || [])[comments.length - 1];
    if (!last) return "";
    const body = plainMessagePreview(last.payload || last.preview || "", limit);
    return body ? `${last.owner || "—"}: ${body}` : `${last.owner || "—"}`;
  }

  // Resource registers (attachments, files, links, threads) use the same
  // collapsed register line as the messages block: one row that states what is
  // behind it and opens the section in place. The line is a ledger with fixed
  // columns — label, count, preview, state or key — so the count and the
  // preview sit at the same x in every register of a panel. The section bodies
  // keep their own modules and ids. Registers whose contents only the owning
  // module knows start without a count; that module writes the number into the
  // count cell.
  function renderResourceBlock({ resource, label, open = false, count = null, preview = "", bodyHtml = "", actionHtml = "" }) {
    const total = count == null ? "" : String(Number(count) || 0);
    return `
      <div class="record-resource" data-resource="${escapeHtml(resource)}" data-resource-open="${open ? "true" : "false"}">
        <button class="record-strip record-resource-strip" type="button" data-resource-toggle aria-expanded="${open ? "true" : "false"}">
          <b class="record-strip-label">${escapeHtml(label)}</b>
          <span class="record-strip-count" data-resource-count>${escapeHtml(total)}</span>
          <span class="record-strip-preview" data-resource-preview>${escapeHtml(preview)}</span>
          <i class="record-strip-state" data-resource-state></i>
        </button>
        ${actionHtml ? `<div class="document-resource-action">${actionHtml}</div>` : ""}
        <div class="record-resource-body">${bodyHtml}</div>
      </div>`;
  }

  // Read and edit use the same resource hosts, ids and disclosure state.
  function renderDocumentResources({ kind, attachments = [], attachmentControl, open = {}, threadsHtml = "" }) {
    const prefix = kind === "task" ? "taskDetail" : "note";
    const classes = kind === "task" ? "task-detail" : "note";
    return '<div class="document-resources">' + renderResourceBlock({
      resource: "attachments", label: "ATTACHMENTS", open: open.attachments === true,
      count: attachments.length, preview: attachments[0]?.filename || "",
      actionHtml: attachmentControl,
      bodyHtml: typeof renderAttachmentPreviewStripHtml === "function"
        ? renderAttachmentPreviewStripHtml(attachments, `${kind}PreviewAttachments`) : "",
    }) + renderResourceBlock({
      resource: "files", label: "FILES", open: open.files === true,
      bodyHtml: '<section class="file-assets-section"></section>',
    }) + renderResourceBlock({
      resource: "links", label: "LINKS", open: open.links === true,
      actionHtml: `<button class="btn" id="${prefix}LinkAdd">+ LINK</button><nrc-link-picker id="${prefix}LinkPicker"></nrc-link-picker>`,
      bodyHtml: `<div class="${classes}-links-section">
        <div class="${classes}-links-list" id="${prefix}LinksList"></div>
      </div>`,
    }) + threadsHtml + '</div>';
  }

  // The panel re-renders on every asset change, so the open state of its
  // resource registers is read back from the live panel before the render.
  function readResourceState(root) {
    const state = {};
    root?.querySelectorAll?.("[data-resource]").forEach((block) => {
      state[block.dataset.resource] = block.dataset.resourceOpen === "true";
    });
    return state;
  }

  // Bound once per panel container: opening a register must not re-render the
  // panel, because the files and links modules hydrate into those containers.
  // The note and the task panel share one container, so the root is guarded: a
  // second binding would toggle the same click twice. The DOM carries the open
  // state; a panel reads it back with readResourceState before it renders.
  const boundResourceRoots = new WeakSet();

  function bindResourceBlocks({ root }) {
    if (!root || boundResourceRoots.has(root)) return;
    boundResourceRoots.add(root);
    root.addEventListener("click", (event) => {
      const toggle = event.target.closest?.("[data-resource-toggle]");
      if (!toggle) return;
      const block = toggle.closest("[data-resource]");
      if (!block) return;
      const group = toggle.closest(".document-resources");
      if (group) {
        // Toggle the active panel or switch exclusively without rebuilding
        // hydrated lists or disturbing content and comment drafts.
        const open = block.dataset.resourceOpen !== "true";
        for (const resource of group.querySelectorAll("[data-resource]")) {
          const selected = open && resource === block;
          resource.dataset.resourceOpen = String(selected);
          resource.querySelector("[data-resource-toggle]").setAttribute("aria-expanded", String(selected));
        }
        return;
      }
      const open = block.dataset.resourceOpen !== "true";
      block.dataset.resourceOpen = open ? "true" : "false";
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  function renderComposer({ inputId, sendId, open, draft = "" }) {
    return `
      <div class="record-composer" data-composer data-composer-open="${open ? "true" : "false"}">
        <button class="record-composer-bar" type="button" data-composer-toggle aria-expanded="${open ? "true" : "false"}">
          <span>WRITE A MESSAGE…</span>
          <b>M</b>
        </button>
        <div class="task-comment-input-area">
          <label class="task-comment-input-container" for="${escapeHtml(inputId)}">
            <textarea class="task-comment-input" id="${escapeHtml(inputId)}" rows="3" aria-label="Write a message">${escapeHtml(draft)}</textarea>
          </label>
          <div class="task-comment-composer-meta" aria-live="polite">
            <span><b>ENTER</b> SEND</span>
            <span><b>SHIFT+ENTER</b> NEW LINE</span>
            <span class="task-comment-byte-count">0 B / ${MAX_COMMENT_BYTES.toLocaleString()} B</span>
          </div>
          <button class="btn task-comment-send" id="${escapeHtml(sendId)}" type="button">SEND ↵</button>
        </div>
      </div>`;
  }

  // The messages block closes to one register line: label, count, last message,
  // key hint. Opening it gives the stream its own scroll area above the
  // composer, so the record's document keeps the rest of the panel. In a wide
  // panel the block becomes a column beside the document instead (see
  // entities.css).
  function renderMessagesArea({ messagesHtml, count, preview, open = false, composerOpen = false, persistent = false, draft = "", inputId, sendId }) {
    if (persistent) composerOpen = true;
    const areaId = `${inputId}Area`;
    const total = Number(count) || 0;
    const previewText = total === 0
      ? "WRITE THE FIRST ONE — MARKDOWN SUPPORTED"
      : preview || "";
    return `
      <div class="record-messages" id="${escapeHtml(areaId)}" data-messages-area data-messages-persistent="${persistent}" data-messages-open="${open ? "true" : "false"}">
        <div class="record-resize-handle" data-record-resize role="separator" aria-orientation="vertical" tabindex="0" aria-label="Resize messages column"></div>
        <button type="button" data-messages-toggle class="record-strip record-messages-strip" aria-expanded="${open ? "true" : "false"}" aria-controls="${escapeHtml(areaId)}Body">
          <b class="record-strip-label">MESSAGES</b>
          <span class="record-strip-count">${total}</span>
          <span class="record-strip-preview">${escapeHtml(previewText)}</span>
          <i class="record-strip-key">${open ? "−" : "+"}</i>
        </button>
        <div class="record-messages-body" id="${escapeHtml(areaId)}Body" data-messages-body>
          <div class="record-stream" data-messages-stream>${messagesHtml}</div>
          ${renderComposer({ inputId, sendId, open: composerOpen, draft })}
        </div>
      </div>`;
  }

  // The messages column divider only exists in the wide composition (the
  // stacked composition hides it), so the drag handler stays inert there. The
  // width persists like the inspector's own width.
  const MESSAGES_WIDTH_KEY = "nrc.record.messagesWidth";
  const MESSAGES_WIDTH_DEFAULT = 360;
  const MESSAGES_WIDTH_MIN = 320;
  const MESSAGES_WIDTH_MAX = 640;

  function clampMessagesWidth(width) {
    const value = Number(width);
    if (!Number.isFinite(value) || value <= 0) return MESSAGES_WIDTH_DEFAULT;
    return Math.max(MESSAGES_WIDTH_MIN, Math.min(value, MESSAGES_WIDTH_MAX));
  }

  function savedMessagesWidth() {
    try {
      const stored = localStorage.getItem(MESSAGES_WIDTH_KEY);
      return stored == null ? MESSAGES_WIDTH_DEFAULT : clampMessagesWidth(Number(stored));
    } catch (_) {
      return MESSAGES_WIDTH_DEFAULT;
    }
  }

  function bindColumnResize({ panel, handle }) {
    if (!panel || !handle) return null;
    let width = savedMessagesWidth();
    const applyWidth = (next, persist = false) => {
      width = clampMessagesWidth(next);
      panel.style.setProperty("--record-messages-width", `${width}px`);
      handle.setAttribute("aria-valuenow", String(Math.round(width)));
      if (persist) {
        try {
          localStorage.setItem(MESSAGES_WIDTH_KEY, String(width));
        } catch (_) {
          // A blocked storage keeps the width for this session only.
        }
      }
    };
    handle.setAttribute("aria-valuemin", String(MESSAGES_WIDTH_MIN));
    handle.setAttribute("aria-valuemax", String(MESSAGES_WIDTH_MAX));
    applyWidth(width);

    const reset = () => {
      panel.style.removeProperty("--record-messages-width");
      width = MESSAGES_WIDTH_DEFAULT;
      handle.setAttribute("aria-valuenow", String(MESSAGES_WIDTH_DEFAULT));
      try {
        localStorage.removeItem(MESSAGES_WIDTH_KEY);
      } catch (_) {
        // Ignore an unavailable storage.
      }
    };
    handle.addEventListener("dblclick", (event) => {
      event.preventDefault();
      event.stopPropagation();
      reset();
    });
    handle.addEventListener("keydown", (event) => {
      if (event.key === "Home") {
        event.preventDefault();
        event.stopPropagation();
        reset();
        return;
      }
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      event.preventDefault();
      event.stopPropagation();
      // The column sits on the right, so dragging left widens it.
      applyWidth(width + (event.key === "ArrowLeft" ? 16 : -16), true);
    });
    handle.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
    });
    handle.addEventListener("pointerdown", (event) => {
      if (!event.isPrimary || event.button !== 0 || handle.hasPointerCapture(event.pointerId)) return;
      event.preventDefault();
      event.stopPropagation();
      const pointerId = event.pointerId;
      const startX = event.clientX;
      const start = width;
      handle.classList.add("record-resize-handle-dragging");
      handle.setPointerCapture(pointerId);
      const move = (moveEvent) => {
        if (moveEvent.pointerId !== pointerId) return;
        applyWidth(start - (moveEvent.clientX - startX));
      };
      const stop = (stopEvent) => {
        if (stopEvent.pointerId !== pointerId) return;
        handle.removeEventListener("pointermove", move);
        handle.removeEventListener("pointerup", stop);
        handle.removeEventListener("pointercancel", stop);
        handle.removeEventListener("lostpointercapture", stop);
        handle.classList.remove("record-resize-handle-dragging");
        applyWidth(width, true);
      };
      handle.addEventListener("pointermove", move);
      handle.addEventListener("pointerup", stop);
      handle.addEventListener("pointercancel", stop);
      handle.addEventListener("lostpointercapture", stop);
    });
    return { width: () => width, reset };
  }

  // Toggling the messages block or the composer mutates the rendered panel in
  // place. Re-rendering here would discard unsaved edits in the document form,
  // so the panel modules own the state and receive it back through onToggle.
  function bindMessagesArea({ root, inputId, sendId, onSubmit, onDelete, onToggle, focusPending = false }) {
    if (!root) return null;
    const area = root.querySelector("[data-messages-area]");
    if (!area) return null;

    const strip = area.querySelector("[data-messages-toggle]");
    const stream = area.querySelector("[data-messages-stream]");
    const composer = area.querySelector("[data-composer]");
    const composerBar = composer?.querySelector("[data-composer-toggle]");
    const input = root.querySelector(`#${inputId}`);
    const send = root.querySelector(`#${sendId}`);
    const columnResize = bindColumnResize({
      panel: area.parentElement,
      handle: area.querySelector("[data-record-resize]"),
    });

    const isMessagesOpen = () => area.dataset.messagesOpen === "true";
    const isComposerOpen = () => composer?.dataset.composerOpen === "true";
    const persistent = area.dataset.messagesPersistent === "true";
    // The draft travels back with every state change so a panel re-render (an
    // arriving message, for example) cannot drop it.
    const notify = () => onToggle?.({
      messagesOpen: isMessagesOpen(),
      composerOpen: isComposerOpen(),
      draft: input?.value ?? "",
    });

    function scrollStreamToEnd() {
      if (!stream) return;
      const toEnd = () => {
        stream.scrollTop = stream.scrollHeight;
      };
      if (typeof requestAnimationFrame === "function") requestAnimationFrame(toEnd);
      else toEnd();
    }

    function setComposerOpen(open, { focus = false } = {}) {
      if (!composer) return;
      if (persistent) open = true;
      composer.dataset.composerOpen = open ? "true" : "false";
      composerBar?.setAttribute("aria-expanded", open ? "true" : "false");
      if (open && focus) input?.focus();
    }

    function setMessagesOpen(open, { focusComposer = false, notifyChange = true } = {}) {
      area.dataset.messagesOpen = open ? "true" : "false";
      strip?.setAttribute("aria-expanded", open ? "true" : "false");
      const hint = strip?.querySelector("i");
      if (hint) hint.textContent = open ? "−" : "+";
      if (open) {
        if (focusComposer) setComposerOpen(true, { focus: true });
        scrollStreamToEnd();
      } else {
        setComposerOpen(false);
      }
      if (notifyChange) notify();
    }

    if (strip) {
      strip.onclick = () => setMessagesOpen(!isMessagesOpen());
    }

    if (composerBar) {
      composerBar.onclick = () => {
        if (!isMessagesOpen()) setMessagesOpen(true, { focusComposer: true, notifyChange: false });
        else setComposerOpen(true, { focus: true });
        notify();
      };
    }

    if (input && send) {
      const byteCount = composer?.querySelector(".task-comment-byte-count");
      const updateByteCount = () => {
        const bytes = new TextEncoder().encode(input.value).length;
        const invalid = bytes > MAX_COMMENT_BYTES;
        if (byteCount) {
          byteCount.textContent = `${bytes.toLocaleString()} B / ${MAX_COMMENT_BYTES.toLocaleString()} B`;
          byteCount.classList.toggle("composer-byte-count--invalid", invalid);
        }
        input.setAttribute("aria-invalid", String(invalid));
        send.disabled = invalid;
      };
      const submit = () => {
        const text = input.value.trim();
        if (!text) return;
        if (new TextEncoder().encode(text).length > MAX_COMMENT_BYTES) return;
        const result = onSubmit(text);
        if (result === false) return;
        input.value = "";
        updateByteCount();
        // The composer stays open while the caret is in it: Ctrl+Enter keeps
        // writing, a click on SEND returns the space to the document.
        if (input.ownerDocument?.activeElement !== input) setComposerOpen(false);
        notify();
      };
      send.onclick = submit;
      input.oninput = updateByteCount;
      input.onblur = () => {
        if (!input.value.trim()) {
          setComposerOpen(false);
          notify();
        }
      };
      input.onkeydown = (event) => {
        if (event.key === "Escape") {
          event.stopPropagation();
          setComposerOpen(false);
          notify();
          return;
        }
        // Match the chat composer, including IME and touch-keyboard protection.
        // Newlines and composition must not reach the document's save shortcut.
        if (event.key === "Enter") event.stopPropagation();
        if (event.key === "Enter" && !event.shiftKey && !event.isComposing &&
            !(window.matchMedia("(pointer: coarse)").matches && !event.ctrlKey && !event.metaKey)) {
          event.preventDefault();
          submit();
        }
      };
      updateByteCount();
    }

    area.querySelectorAll(".record-message-delete").forEach((button) => {
      button.onclick = (event) => {
        event.stopPropagation();
        onDelete(button.dataset.assetId);
      };
    });

    // A panel re-render rebuilds the stream, so an already open block starts at
    // its newest message. A pending deep link owns the scroll position instead.
    if (isMessagesOpen() && !focusPending) scrollStreamToEnd();

    return {
      isMessagesOpen,
      isComposerOpen,
      scrollToEnd: scrollStreamToEnd,
      columnWidth: () => columnResize?.width() ?? null,
      resetColumnWidth: () => columnResize?.reset(),
      open({ focusComposer = false } = {}) {
        setMessagesOpen(true, { focusComposer });
      },
      close: () => setMessagesOpen(false),
    };
  }

  window.NRCDetailUI = {
    renderHeaderAction,
    renderCloseControl,
    setHeaderAction,
    renderMessages,
    renderMessagesArea,
    bindMessagesArea,
    renderResourceBlock,
    renderDocumentResources,
    readResourceState,
    bindResourceBlocks,
    messagePreview,
    clampMessagesWidth,
    renderSaveState,
    renderHeaderMetadata,
    formatHeaderDate,
    renderMetadataLedger,
    setSaveState,
    inlineField,
    bindSuggestedInput,
    attachmentControl,
  };
})();
