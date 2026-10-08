// First-class File assets. Integration points intentionally live on window.NRCFiles.
(() => {
  "use strict";

  const mounted = new Map();
  const loads = new Map(); // room:id -> pending | failed; prevents render/request loops
  const encoder = new TextEncoder();
  let refreshQueued = false;

  function escape(value) {
    return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }

  function metadata(input = {}) {
    return {
      ...input,
      type: "file",
      version: 1,
      title: String(input.title || "").trim(),
      description: String(input.description || ""),
      category: String(input.category || ""),
      tags: Array.isArray(input.tags) ? input.tags.map(String).map((v) => v.trim()).filter(Boolean) : [],
    };
  }

  function parseMetadata(asset) {
    try { return metadata(JSON.parse(asset?.payload || asset?.preview || "{}")); }
    catch (_) { return metadata({ title: asset?.preview || "" }); }
  }

  function editableMetadata(asset) {
    try {
      const value = JSON.parse(asset.payload);
      const preview = JSON.parse(asset.preview);
      return value?.type === "file" && value.version === 1 && typeof value.title === "string" &&
        preview?.version === 1 && typeof preview.title === "string";
    } catch { return false; }
  }

  function sendAcknowledged(send, onSuccess, onError) {
    let settled = false;
    const finish = (callback, detail) => {
      if (settled) return;
      settled = true; clearTimeout(timer); callback(detail);
    };
    const timer = setTimeout(() => finish(onError, { uncertain: true, message: "No acknowledgement; outcome is unknown" }), 15000);
    const options = { onSuccess: value => finish(onSuccess, value), onError: value => finish(onError, value) };
    try { if (send(options) == null) options.onError({ message: "Request was not sent" }); }
    catch (error) { options.onError({ uncertain: true, message: error.message }); }
  }

  function entityId(entity, sourceType) {
    return BigInt(sourceType === 2 ? entity.id : entity.assetId);
  }

  function linkedFiles(entity, sourceType, edges) {
    const id = entityId(entity, sourceType);
    const grouped = new Map();
    for (const edge of Array.isArray(edges) ? edges : []) {
      let other = null;
      if (edge.sourceType === sourceType && BigInt(edge.sourceId) === id) other = [edge.targetType, edge.targetId];
      else if (edge.targetType === sourceType && BigInt(edge.targetId) === id) other = [edge.sourceType, edge.sourceId];
      if (!other || other[0] !== 1) continue;
      const key = String(other[1]);
      if (!grouped.has(key)) grouped.set(key, { assetId: BigInt(other[1]), edges: [] });
      grouped.get(key).edges.push(edge);
    }
    return [...grouped.values()];
  }

  function notify(message, error = false) {
    window.NRCDialog?.notify?.(message, error ? { logType: "Error" } : undefined);
  }

  function connectedRender(container) {
    const state = mounted.get(container);
    if (state && container.isConnected !== false && !container.closest?.("[inert]")) renderSection(container, state.entity, state.sourceType, state.edges, state.options);
  }

  function refresh() {
    if (refreshQueued) return;
    refreshQueued = true;
    queueMicrotask(() => {
      refreshQueued = false;
      for (const [container] of mounted) {
        if (container.isConnected === false) mounted.delete(container);
        else connectedRender(container);
      }
    });
  }

  function hydrate(room, id) {
    const key = `${room}:${id}`;
    const retry = loads.get(key) === "retry";
    if ((!retry && loads.has(key)) || !window.NRCAssets?.requestAsset) return;
    loads.set(key, "pending");
    sendAcknowledged(o => (retry ? window.NRCAssets.sendGetAsset : window.NRCAssets.requestAsset)(room, id, o),
      () => {
        loads.delete(key); refresh();
        // The inspector can replace its DOM while this shared read is pending.
        // Notify surviving owners, not the owner that happened to start it.
        for (const [container, state] of [...mounted]) {
          if (container.isConnected && BigInt(state.entity.convId) === room) state.options.onHydrated?.();
        }
      },
      () => { loads.set(key, "failed"); refresh(); });
  }

  function button(text, action, className = "btn") {
    const el = document.createElement("button");
    el.type = "button"; el.className = className; el.textContent = text;
    el.addEventListener("click", action); return el;
  }

  function closeModal(root) { root.nrcClose?.(); }
  function modal(title, closeLabel = "CANCEL") {
    const view = window.NRCModal.create({ title, className: "file-assets-dialog", closeButton: true });
    const { root, panel, actions } = view;
    const box = document.createElement("div"); box.className = "file-assets-dialog-body";
    panel.insertBefore(box, actions);
    view.box = box;
    root.nrcClose = view.close;
    if (closeLabel) actions.append(button(closeLabel, view.cancel));
    queueMicrotask(() => view.show());
    return view;
  }

  // The file read view is one markup with two hosts: the details modal, and the
  // inspector that a file reference opens in.
  function fileReadBody(asset) {
    const body = document.createElement("div"); body.className = "customer-fields file-assets-details";
    body.innerHTML = fileFacts(asset) + renderAttachmentPreviewStripHtml(asset.attachments, "fileDetailsAttachments", { inlineImages: true, alwaysOpen: true });
    return body;
  }

  // Both read hosts use the same compact, grouped metadata register.
  function fileFacts(asset) {
    const data = parseMetadata(asset), att = asset.attachments?.[0];
    const updated = new Date(Number(BigInt(asset.updatedAt ?? asset.createdAt ?? 0) / 1000000n)).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
    const fact = (label, value) => `<dt>${label}</dt><dd>${escape(value || "—")}</dd>`;
    return `<section class="file-assets-metadata" aria-label="File metadata">
      <h2 class="file-assets-heading">${escape(data.title || att?.filename || "Untitled file")}</h2>
      ${data.description ? `<p class="file-assets-description">${escape(data.description)}</p>` : ""}
      <dl>
        <div class="file-assets-fact-group" role="group" aria-label="File">${fact("FILENAME", att?.filename)}${fact("TYPE", att?.mimeType)}${fact("SIZE", att ? formatFileSize(Number(att.size)) : "—")}</div>
        <div class="file-assets-fact-group" role="group" aria-label="Classification">${fact("CATEGORY", data.category)}${fact("TAGS", data.tags.join(", "))}</div>
        <div class="file-assets-fact-group" role="group" aria-label="Record info">${fact("OWNER", asset.owner)}${fact("UPDATED", updated)}</div>
      </dl>
    </section>`;
  }

  // showInspector renders a file reference into the inspector, so a file member
  // opens where every other reference in the client opens. Editing stays in the
  // file section's DETAILS view, which owns the metadata form.
  function showInspector(ref) {
    const header = document.getElementById("inspectorHeader");
    const host = document.getElementById("inspectorEntityHost");
    if (!header || !host) return;
    const intent = window.NRCInspector?.beginExternalLoad?.();
    const stillCurrent = () => intent == null || window.NRCInspector?.isIntentCurrent?.(intent);
    const render = (state, message) => {
      header.innerHTML = `<div class="inspector-identity-row"><span class="header-text identity-reference">FILE #${escape(ref.id)}</span><span class="inspector-cell-label">STATE</span>${window.NRCDetailUI.renderSaveState(state)}</div><div class="inspector-mode-row">${window.NRCDetailUI.renderCloseControl("fileInspectorClose")}</div>`;
      const close = document.getElementById("fileInspectorClose");
      if (close) close.onclick = () => window.NRCInspector?.close?.();
      if (message) {
        const status = document.createElement("p"); status.className = "file-assets-error"; status.setAttribute("role", "status"); status.textContent = message;
        host.replaceChildren(status);
        return;
      }
      host.replaceChildren();
    };
    render("LOADING", `Loading file #${ref.id}…`);
    window.NRCAssets.requestAsset(0n, ref.id, {
      onSuccess({ asset }) {
        if (!stillCurrent()) return;
        if (!asset || asset.assetType !== window.NRCAssets.AssetType.File) {
          render("NOT FOUND", `File #${ref.id} was not found.`);
          return;
        }
        render("READ ONLY", null);
        const body = document.createElement("div"); body.className = "customer-inspector-body file-assets-details";
        body.innerHTML = fileFacts(asset);
        body.insertAdjacentHTML("beforeend", renderAttachmentPreviewStripHtml(asset.attachments, "fileInspectorAttachments", { inlineImages: true, alwaysOpen: true }));
        const shell = document.createElement("div"); shell.className = "customer-inspector";
        shell.append(body);
        host.append(shell);
      },
      onError(detail) {
        if (stillCurrent()) render("LOAD FAILED", detail?.message || `File #${ref.id} could not be loaded.`);
      },
    });
  }

  function open(asset, { readOnly = true, links = [] } = {}) {
    if (!asset) return null;
    const data = parseMetadata(asset);
    const view = modal("FILE DETAILS", null);
    const body = fileReadBody(asset);
    let busy = false;
    view.canClose = () => !busy;
    if (!readOnly && editableMetadata(asset)) {
      const form = document.createElement("form"); form.className = "customer-fields file-assets-form";
      form.hidden = true;
      form.innerHTML = `<label>TITLE<input class="nrc-dialog-input" name="title" required value="${escape(data.title)}"></label><div class="file-assets-field-pair"><label>CATEGORY<input class="nrc-dialog-input" name="category" value="${escape(data.category)}"></label><label>TAGS<input class="nrc-dialog-input" name="tags" value="${escape(data.tags.join(", "))}"></label></div><label>DESCRIPTION<textarea class="nrc-dialog-input" name="description" rows="3">${escape(data.description)}</textarea></label><p role="status"></p>`;
      body.append(form);
      form.id = `${view.root.getAttribute("aria-labelledby")}-form`;
      const saveButton = Object.assign(document.createElement("button"), { type: "submit", className: "btn btn--primary", textContent: "SAVE METADATA" });
      saveButton.setAttribute("form", form.id);
      saveButton.hidden = true;
      const editButton = button("EDIT", () => {
        body.querySelector(".file-assets-metadata").hidden = true;
        form.hidden = false; saveButton.hidden = false; editButton.hidden = true; cancelEdit.hidden = false;
        form.elements.title.focus();
      });
      const cancelEdit = button("CANCEL EDIT", () => {
        if (busy) return;
        form.reset(); form.hidden = true; saveButton.hidden = true; editButton.hidden = false; cancelEdit.hidden = true;
        body.querySelector(".file-assets-metadata").hidden = false;
        editButton.focus();
      });
      cancelEdit.hidden = true;
      view.actions.prepend(editButton, saveButton, cancelEdit);
      form.onsubmit = event => {
        event.preventDefault();
        if (busy || !isOpen()) return;
        const next = metadata({ ...data, title: form.elements.title.value, category: form.elements.category.value, tags: form.elements.tags.value.split(","), description: form.elements.description.value });
        const status = form.querySelector("[role=status]");
        if (!next.title) { status.textContent = "TITLE REQUIRED"; return; }
        const preview = JSON.stringify({ ...JSON.parse(asset.preview || "{}"), version: 1, type: "file", title: next.title, category: next.category });
        const payload = JSON.stringify(next);
        if (encoder.encode(preview).length > 4096 || encoder.encode(payload).length > 65535) {
          status.textContent = "METADATA EXCEEDS PROTOCOL LIMITS"; return;
        }
        busy = true;
        saveButton.disabled = true;
        status.textContent = "SAVING…";
        try {
          sendAcknowledged(options => window.NRCTransactions.sendAssetMetadataPatch(asset, preview, payload, options),
            () => { busy = false; closeModal(view.root); window.NRCAssets.sendGetAsset(asset.convId, asset.assetId, { onSuccess: refresh }); },
            error => { busy = false; status.textContent = `${error.message}. CLOSE AND REOPEN TO RECONCILE BEFORE RETRYING.`; });
        } catch (error) { busy = false; saveButton.disabled = false; status.textContent = error.message; }
      };
    }
    if (!readOnly && links.length) {
      for (const edge of links) view.actions.prepend(button(`REMOVE FROM THIS RECORD${links.length > 1 ? ` · ${window.NRCEdges.RelationTypeNames[edge.relation] || "link"} #${edge.edgeId}` : ""}`, async () => {
        if (busy) return;
        if (!await window.NRCDialog?.confirm?.("Remove this link from the current record? The File itself and its links to other records will be kept.", { title: "REMOVE FROM THIS RECORD" })) return;
        if (!view.root.isConnected || busy) return;
        if (!isOpen()) return notify("WEBSOCKET IS NOT CONNECTED", true);
        busy = true;
        sendAcknowledged(o => window.NRCEdges.sendDeleteEdge(asset.convId, edge.edgeId, o),
          () => { busy = false; closeModal(view.root); refresh(); },
          e => { busy = false; notify(e?.message || "Unlink failed", true); });
      }));
    }
    view.box.append(body); return view.root;
  }

  function isOpen() { return typeof ws !== "undefined" && ws?.readyState === WebSocket.OPEN; }
  function linkExisting(room, sourceType, sourceId, fileId, done, isCancelled = () => false) {
    if (isCancelled()) return done(null);
    if (!isOpen()) return done(new Error("WebSocket is not connected"));
    // Always reconcile before creating: the previous acknowledgement may have
    // been lost even though the edge committed. Only scoped incident edges load.
    const reconcile = session => sendAcknowledged(o => {
      if (isCancelled()) { o.onSuccess(null); return true; }
      window.NRCEdges.requestEdgePage(room, sourceType, sourceId, { session, isCancelled }).then(o.onSuccess, o.onError);
      return true;
    }, detail => {
      if (isCancelled()) return done(null);
      if (detail.hasMore) return reconcile(detail.session);
      const existing = window.NRCEdges.getEdgesForEntity(room, sourceType, sourceId).some(edge =>
        edge.sourceType === sourceType && edge.sourceId === sourceId &&
        edge.targetType === 1 && edge.targetId === fileId && edge.relation === 2);
      if (existing) return done(null);
      sendAcknowledged(options => window.NRCEdges.sendCreateEdge(room, sourceType, sourceId, 1, fileId, 2, options),
        () => done(null), e => done(Object.assign(new Error(e?.message || "Link failed"), e)));
    }, e => done(Object.assign(new Error(e.message || "Cannot reconcile links"), e)));
    reconcile();
  }

  function openUpload(state) {
    const room = BigInt(state.entity.convId), sourceId = entityId(state.entity, state.sourceType);
    const view = modal("UPLOAD FILE"); let writing = false, createdId = null, createUnknown = false;
    view.canClose = () => {
      if (writing) return false;
      if (createdId) notify(`FILE #${createdId} WAS RETAINED. USE LINK EXISTING TO ASSIGN IT.`);
      return true;
    };
    const form = document.createElement("form"); form.className = "customer-fields file-assets-upload-form file-assets-form";
    form.innerHTML = `<label>FILE<input class="nrc-dialog-input" name="file" type="file" required></label><label>TITLE<input class="nrc-dialog-input" name="title" maxlength="200" required></label><div class="file-assets-field-pair"><label>CATEGORY<input class="nrc-dialog-input" name="category" maxlength="200"></label><label>TAGS<input class="nrc-dialog-input" name="tags" placeholder="comma separated"></label></div><label>DESCRIPTION<textarea class="nrc-dialog-input" name="description" maxlength="8000" rows="3"></textarea></label><p class="file-assets-write-status" role="status"></p>`;
    form.id = `${view.root.getAttribute("aria-labelledby")}-form`;
    const submit = Object.assign(document.createElement("button"), { type: "submit", className: "btn btn--primary", textContent: "UPLOAD" });
    submit.setAttribute("form", form.id);
    view.actions.prepend(submit);
    view.box.append(form); const status = form.querySelector(".file-assets-write-status");
    form.addEventListener("submit", async (event) => {
      event.preventDefault(); if (writing) return;
      if (createUnknown) return notify("CREATE OUTCOME IS UNKNOWN. RECOVER WITH LINK EXISTING; DO NOT CREATE AGAIN.", true);
      if (createdId) {
        writing = true; submit.disabled = true;
        return linkExisting(room, state.sourceType, sourceId, createdId, (err) => {
          writing = false; submit.disabled = false;
          if (err) status.textContent = `FILE #${createdId} EXISTS; LINK FAILED: ${err.message}`;
          else { closeModal(view.root); refresh(); }
        });
      }
      const file = form.elements.file.files?.[0], title = form.elements.title.value.trim();
      if (!file || !title) return notify("FILE AND NONBLANK TITLE ARE REQUIRED", true);
      if (!isOpen()) return notify("WEBSOCKET IS NOT CONNECTED", true);
      const data = metadata({ title, description: form.elements.description.value, category: form.elements.category.value, tags: form.elements.tags.value.split(",") });
      const payload = JSON.stringify(data), preview = JSON.stringify({ type: "file", version: 1, title: data.title, category: data.category, filename: file.name });
      if (encoder.encode(preview).length > 4096 || encoder.encode(payload).length > 65535) { status.textContent = "METADATA EXCEEDS PROTOCOL LIMITS"; return; }
      writing = true; submit.disabled = true;
      for (const input of form.querySelectorAll("input, textarea")) input.disabled = true;
      status.textContent = "UPLOADING BINARY…";
      try {
        const attachment = await uploadFile(file, null, room);
        status.textContent = "CREATING FILE RECORD…";
        sendAcknowledged(options => window.NRCAssets.sendCreateAsset(room, window.NRCAssets.AssetType.File, 0, 0n, preview, payload, 0, options, [attachment]),
          (detail) => {
            createdId = BigInt(detail.assetId ?? detail.asset?.assetId); status.textContent = `FILE #${createdId} CREATED; LINKING…`;
            linkExisting(room, state.sourceType, sourceId, createdId, (err) => {
              writing = false; submit.disabled = false;
              if (err) { status.textContent = `FILE #${createdId} EXISTS; LINK FAILED: ${err.message}. SUBMIT TO RETRY THIS LINK.`; }
              else { closeModal(view.root); refresh(); }
            });
          },
          (err) => { writing = false; createUnknown = true; status.textContent = `CREATE NOT CONFIRMED: ${err?.message || "unknown error"}. CLOSE AND CHECK LINK EXISTING BEFORE CREATING AGAIN.`; });
      } catch (err) { writing = false; submit.disabled = false; for (const input of form.querySelectorAll("input, textarea")) input.disabled = false; status.textContent = err.message; }
    });
  }

  function openPicker(state, anchor) {
    const room = BigInt(state.entity.convId), sourceId = entityId(state.entity, state.sourceType);
    window.NRCLinksUI?.openEntityPicker?.({
      anchor,
      container: anchor.closest(".file-assets-section").parentElement,
      sourceType: state.sourceType,
      sourceEntity: state.entity,
      kinds: ["file"],
      relation: { value: 2, label: "related-to" },
      className: "file-assets-picker",
      onSelect: (item, relation, isCancelled) => new Promise((resolve, reject) => linkExisting(room, state.sourceType, sourceId, item.id, err => {
        if (isCancelled()) return resolve();
        if (err) reject(err);
        else { refresh(); resolve(); }
      }, isCancelled)),
    });
  }

  // A files section rendered inside a resource register (the read panels) keeps
  // the collapsed line in step with what the section holds: the register states
  // the count and the first file, the section below carries the rows. The count
  // cell carries only the number; a partial list states that in the register's
  // trailing slot, so no column shifts.
  function updateResourceRegister(container, visible, partial) {
    const block = container.closest?.("[data-resource]");
    if (!block) return;
    const count = block.querySelector("[data-resource-count]");
    if (count) count.textContent = String(visible.length);
    const state = block.querySelector("[data-resource-state]");
    if (state) state.textContent = partial ? "PARTIAL" : "";
    const preview = block.querySelector("[data-resource-preview]");
    if (preview) {
      const first = visible[0];
      const att = first?.asset?.attachments?.[0];
      preview.textContent = first ? parseMetadata(first.asset).title || att?.filename || `FILE #${first.assetId}` : "";
    }
    // A register that hides its section when empty (the note preview) hides with
    // it, unless the operator opened it on purpose.
    block.hidden = container.hidden === true && block.dataset.resourceOpen !== "true";
  }

  function renderSection(container, entity, sourceType, edges, options = {}) {
    const state = { entity, sourceType, edges: Array.isArray(edges) ? edges : [], options: { readOnly: false, partial: false, hideWhenEmpty: false, ...options } };
    const resource = container.closest('.document-resources > [data-resource="files"]');
    const previous = mounted.get(container);
    const sameOwner = previous && previous.sourceType === sourceType &&
      BigInt(previous.entity.convId) === BigInt(entity.convId) && entityId(previous.entity, sourceType) === entityId(entity, sourceType) &&
      previous.options.readOnly === state.options.readOnly;
    if (!sameOwner) {
      for (const picker of container.parentElement?.querySelectorAll("nrc-link-picker") || []) {
        if (container.contains(picker.anchor)) picker.close(true);
      }
      container.replaceChildren();
    }
    mounted.set(container, state); container.classList.add("file-assets-section");
    const room = BigInt(entity.convId), refs = linkedFiles(entity, sourceType, state.edges), cache = window.NRCAssets?.roomAssets?.get(room);
    const visible = [], unknown = [], failures = [];
    // requestAsset coalesces concurrent owner reads; this layer supplies bounded
    // failure state and explicit retry for unresolved endpoints.
    for (const ref of refs) { const asset = cache?.get(ref.assetId); if (!asset) { unknown.push(ref); hydrate(room, ref.assetId); } else if (asset.assetType === window.NRCAssets.AssetType.File) { if (asset.payload == null) { unknown.push(ref); hydrate(room, ref.assetId); } else visible.push({ ...ref, asset }); } }
    for (const ref of unknown) if (loads.get(`${room}:${ref.assetId}`) === "failed") failures.push(ref);
    container.hidden = state.options.readOnly && state.options.hideWhenEmpty && visible.length === 0 && unknown.length === 0;
    updateResourceRegister(container, visible, state.options.partial);
    if (!container.querySelector(".file-assets-list")) {
      // The document resource tab already owns the title, count and actions.
      // Standalone sections (customers and shared notes) own their own header.
      if (!resource) {
        const header = document.createElement("div"); header.className = "panel-header"; const bar = document.createElement("div");
        const title = document.createElement("span"); title.className = "file-assets-title"; bar.append(title);
        if (!state.options.readOnly) bar.append(
          button("+ UPLOAD", () => openUpload(mounted.get(container))),
          button("+ LINK EXISTING", event => { event.stopPropagation(); openPicker(mounted.get(container), event.currentTarget); }),
        );
        header.append(bar); container.append(header);
      }
      const list = document.createElement("div"); list.className = "file-assets-list"; container.append(list);
    }
    const title = container.querySelector(".file-assets-title");
    if (title) title.textContent = `FILES (${visible.length})${state.options.partial ? " · PARTIAL" : ""}`;
    const list = container.querySelector(".file-assets-list"); list.replaceChildren();
    if (!visible.length || unknown.length) { const empty = document.createElement("p"); empty.className = failures.length ? "file-assets-error" : unknown.length ? "file-assets-loading" : "file-assets-empty"; empty.textContent = failures.length ? "SOME FILE RECORDS COULD NOT BE LOADED" : unknown.length ? "LOADING FILE RECORDS…" : "NO FILES IN LOADED LINKS"; list.append(empty); }
    if (failures.length) list.append(button("RETRY", () => { for (const ref of failures) loads.set(`${room}:${ref.assetId}`, "retry"); refresh(); }));
    for (const item of visible) {
      const data = parseMetadata(item.asset), att = item.asset.attachments?.[0], row = document.createElement("div"); row.className = "file-assets-row";
      // Match attachment rows; metadata and relationship actions live in Details.
      const filename = att?.filename || "MISSING ATTACHMENT";
      const kind = typeof getFileExtension === "function" ? getFileExtension(filename, att?.mimeType || "") : "FILE";
      const summary = document.createElement("div"); summary.className = "file-assets-summary";
      const titleText = data.title || filename || `FILE #${item.assetId}`;
      const title = document.createElement("button"); title.type = "button"; title.className = "note-link-target"; title.textContent = titleText; title.title = `${titleText} — open record`;
      title.addEventListener("click", () => sendAcknowledged(o => window.NRCAssets.sendGetAsset(room, item.assetId, o),
        detail => open(detail.asset, { readOnly: state.options.readOnly, links: item.edges }), e => notify(e.message, true)));
      summary.append(Object.assign(document.createElement("span"), { className: "file-assets-type", textContent: kind }), title);
      const sizeLine = document.createElement("span"); sizeLine.className = "file-assets-size"; sizeLine.textContent = att ? formatFileSize(Number(att.size)) : "—";
      row.append(summary, sizeLine);
      const actions = document.createElement("div"); actions.className = "file-assets-actions";
      if (att) { const openLink = document.createElement("a"); openLink.className = "btn btn--row"; openLink.textContent = "OPEN"; openLink.href = attachmentFileURL(att.fileId, att.filename, true); openLink.target = "_blank"; openLink.rel = "noopener noreferrer"; const down = openLink.cloneNode(true); down.textContent = "DOWNLOAD"; down.href = attachmentFileURL(att.fileId, att.filename); down.download = att.filename; down.removeAttribute("target"); actions.append(openLink, down); }
      row.append(actions);
      list.append(row);
    }
    return container;
  }

  window.NRCFiles = { renderSection, refresh, open, openUpload, showInspector, metadata, parseMetadata, editableMetadata, linkedFiles, escape };
})();
