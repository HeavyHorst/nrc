// Workspace search results are projections; exact reads remain owned by the inspector.
(() => {
  const assetNames = { 1: "COMMENT", 2: "DOCUMENT", 3: "FILE", 4: "AGENDA", 5: "NOTE", 8: "COMPANY", 9: "CONTACT", 10: "ACTIVITY" };
  const statuses = ["BACKLOG", "TODO", "IN PROGRESS", "DONE", "NOTE"];
  const limit = 50;
  let controller, panel, query, type, results, status, count;
  let rows = [], selected = null, mode = "idle", stale = false;
  let requestQuery = "", requestType = "all";
  let connected = false;

  function buildRequest(text, kind) {
    const filters = kind === "task" ? { entity_types: ["task"] }
      : kind === "all" ? { entity_types: ["task", "asset"], asset_types: [1, 2, 3, 4, 5, 8, 9, 10] }
      : { entity_types: ["asset"], asset_types: [Number(kind)] };
    return { query: text.trim(), top_n: limit, include_payload: true, filters };
  }

  function object(text) {
    try { const value = JSON.parse(text); return value && typeof value === "object" && !Array.isArray(value) ? value : {}; }
    catch { return {}; }
  }

  function projectResult(result, workspace) {
    const entity = result?.entity;
    if (!entity || !["task", "asset"].includes(entity.type) || entity.conv_id !== "0" ||
        (entity.workspace != null && entity.workspace !== workspace) ||
        typeof entity.id !== "string" || !/^[1-9]\d*$/.test(entity.id) || BigInt(entity.id) > 18446744073709551615n) {
      throw new Error("Search returned an invalid workspace record.");
    }
    const assetType = Number(result.metadata?.asset_type || result.asset_type);
    if (entity.type === "asset" && !assetNames[assetType]) throw new Error("Search returned an unsupported record type.");
    const preview = object(result.preview), payload = object(result.payload);
    const task = result.metadata?.task;
    const label = entity.type === "task" ? "TASK" : assetNames[assetType];
    const title = String(preview.title || payload.title || (Object.keys(preview).length ? "" : result.preview) || `${label} #${entity.id}`);
    let excerpt = String(preview.teaser || preview.excerpt || payload.description || payload.content || payload.body || result.payload || "");
    if (preview.format === "html" || payload.format === "html") excerpt = "HTML document · open record to read";
    else if (Object.keys(payload).length && !payload.description && !payload.content && !payload.body) excerpt = "";
    const context = entity.type === "task"
      ? [statuses[task?.status] || "", task?.project && `Project: ${task.project}`, task?.assignee && `Assignee: ${task.assignee}`].filter(Boolean).join(" · ")
      : assetType >= 8 && assetType <= 10
        ? [preview.number, preview.role, preview.email, preview.city, preview.kind, preview.assignee, preview.archived && "ARCHIVED"].filter(Boolean).join(" · ")
      : [preview.project || payload.category || "", Array.isArray(preview.tags) ? preview.tags.join(", ") : ""].filter(Boolean).join(" · ");
    const attachments = Array.isArray(result.metadata?.attachments) ? result.metadata.attachments : [];
    const refType = entity.type === "task" ? "task" : ({ 3: "file", 5: "note", 8: "company", 9: "contact", 10: "activity" })[assetType] || "asset";
    return {
      key: `${entity.type}:${entity.id}`, label, id: entity.id, title,
      excerpt: excerpt.replace(/\s+/g, " ").trim().slice(0, 240), context,
      attachments: attachments.map(a => `${a.filename || a.file_id || "Attachment"} · ${String(a.status || "unknown").toUpperCase()}`).join("; "),
      ref: { roomId: 0n, id: BigInt(entity.id), type: refType, assetType },
    };
  }

  function textElement(tag, className, text) {
    const el = document.createElement(tag);
    el.className = className;
    el.textContent = text;
    return el;
  }

  function render() {
    if (!panel) return;
    const messages = {
      idle: "Search persistent workspace records and their indexed attachments. Chat and DMs are not indexed.",
      loading: "Searching workspace records…",
      empty: "No matching records. Try another phrase or record type.",
      error: "Search is unavailable. No complete results can be shown. Retry the search.",
    };
    const searchNotice = stale ? "Cached results may be outdated: server reconciliation failed. Retry the search." : messages[mode] || "";
    status.textContent = [!connected && "Workspace connection is offline. Reconnect to open records.", searchNotice].filter(Boolean).join(" ");
    status.hidden = !status.textContent;
    status.dataset.state = mode === "error" || !connected || stale ? "warning" : mode;
    count.textContent = mode === "loading" ? "SEARCHING" : mode === "error" ? "UNAVAILABLE"
      : mode === "idle" ? "READY" : `${rows.length} RESULTS${stale ? " · STALE" : ""}`;
    if (!connected) count.textContent += " · OFFLINE";
    panel.setAttribute("aria-busy", String(mode === "loading"));
    document.getElementById("workspaceSearchScope").textContent = currentWorkspaceId;
    document.getElementById("workspaceSearchLimit").textContent = rows.length === limit ? "TOP 50 · NARROW THE QUERY TO FIND MORE" : "RELEVANCE ORDER · SEMANTIC + TEXT";
    results.replaceChildren();
    for (const row of rows) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "workspace-search-row";
      button.dataset.key = row.key;
      button.setAttribute("aria-pressed", String(row.key === selected));
      button.append(textElement("span", "workspace-search-identity", `${row.label} #${row.id}`));
      const copy = textElement("span", "workspace-search-copy", "");
      copy.append(textElement("span", "workspace-search-title", row.title));
      if (row.excerpt) copy.append(textElement("span", "workspace-search-excerpt", row.excerpt));
      if (row.attachments) copy.append(textElement("span", "workspace-search-attachments", `Attachments: ${row.attachments}`));
      button.append(copy, textElement("span", "workspace-search-context", row.context));
      button.addEventListener("click", () => open(row, button));
      results.append(button);
    }
  }

  async function open(row, button) {
    // HTTP search can remain available without the exact-record WebSocket.
    // Do not queue reads (including cached-record relationship reads) offline.
    if (!connected) return;
    if (await window.NRCInspector.openEntity(row.ref, { replaceCurrent: true }) && button?.isConnected) {
      selected = row.key;
      for (const el of results.children) el.setAttribute("aria-pressed", String(el.dataset.key === selected));
      button?.scrollIntoView({ block: "nearest" });
    }
  }

  function update({ debounce = 0 } = {}) {
    if (!controller) return;
    const text = query.value.trim();
    controller.cancel();
    rows = []; selected = null; stale = false;
    requestQuery = text; requestType = type.value;
    mode = text ? "loading" : "idle";
    render();
    if (!text) return;
    controller.search(buildRequest(text, type.value), {
      debounce,
      onResult(data) {
        const keys = new Set();
        const projected = data.results.map(result => projectResult(result, currentWorkspaceId));
        rows = projected.filter(row => { if (keys.has(row.key)) return false; keys.add(row.key); return true; });
        stale = data.stale === true;
        mode = rows.length ? "results" : "empty";
        render();
      },
      onError() { rows = []; mode = "error"; render(); },
    });
  }

  function onViewChanged(view) {
    if (!panel) return;
    if (view !== "search") { controller.cancel(); if (mode === "loading") mode = "idle"; return; }
    if (mode === "idle" || query.value.trim() !== requestQuery || type.value !== requestType) update();
    query.focus();
  }

  function init() {
    panel = document.getElementById("workspaceSearchPanel");
    query = document.getElementById("workspaceSearchQuery");
    type = document.getElementById("workspaceSearchType");
    results = document.getElementById("workspaceSearchResults");
    status = document.getElementById("workspaceSearchStatus");
    count = document.getElementById("workspaceSearchCount");
    connected = typeof serverReady !== "undefined" && serverReady;
    controller = window.NRCSearch.createController();
    document.getElementById("workspaceSearchForm").addEventListener("submit", event => { event.preventDefault(); update(); });
    query.addEventListener("input", () => update({ debounce: 250 }));
    type.addEventListener("change", () => update());
    document.getElementById("workspaceSearchRetry").addEventListener("click", () => update());
    panel.addEventListener("keydown", event => {
      if (event.target.closest("input, select, .custom-select, #workspaceSearchForm") || event.altKey || event.ctrlKey || event.metaKey) return;
      const direction = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0;
      let row;
      if (direction) row = window.NRCListNavigation.resolveAdjacent(rows, event.target.closest(".workspace-search-row")?.dataset.key || selected, direction, r => r.key).row;
      else if (event.key === "Home") row = rows[0];
      else if (event.key === "End") row = rows.at(-1);
      if (row) { event.preventDefault(); results.querySelector(`[data-key="${row.key}"]`)?.focus(); }
    });
    render();
  }

  // Less common indexed asset kinds have no editor surface. Keep their exact
  // payload read-only and use the same attachment ledger, never the search projection.
  function showInspector(ref, stillCurrent) {
    const host = document.getElementById("inspectorEntityHost");
    const header = document.getElementById("inspectorHeader");
    const title = `${assetNames[ref.assetType] || "ASSET"} #${ref.id}`;
    header.innerHTML = `<div class="inspector-identity-row"><span class="header-text identity-reference">${title}</span><span class="inspector-cell-label">STATE</span><span id="searchAssetState" class="status-value-mono">LOADING</span></div><div class="inspector-mode-row">${window.NRCDetailUI.renderCloseControl("searchAssetClose")}</div>`;
    document.getElementById("searchAssetClose").onclick = () => window.NRCInspector.close();
    host.replaceChildren(textElement("p", "file-assets-error", "Loading record…"));
    window.NRCAssets.requestAsset(0n, ref.id, {
      onSuccess({ asset }) {
        if (!stillCurrent()) return;
        if (!asset || asset.assetType !== ref.assetType) {
          document.getElementById("searchAssetState").textContent = "NOT FOUND";
          host.replaceChildren(textElement("p", "file-assets-error", "Record not found.")); return;
        }
        document.getElementById("searchAssetState").textContent = "READ ONLY";
        const body = textElement("div", "customer-inspector-body", "");
        body.append(textElement("h2", "workspace-search-title", object(asset.preview).title || asset.preview), textElement("pre", "workspace-search-payload", asset.payload || ""));
        body.insertAdjacentHTML("beforeend", renderAttachmentPreviewStripHtml(asset.attachments, "searchAssetAttachments"));
        host.replaceChildren(body);
      },
      onError() {
        if (!stillCurrent()) return;
        document.getElementById("searchAssetState").textContent = "LOAD FAILED";
        host.replaceChildren(textElement("p", "file-assets-error", "Record could not be loaded. Select it again to retry."));
      },
    });
  }

  window.NRCWorkspaceSearch = {
    init, update, buildRequest, projectResult, onViewChanged, showInspector,
    onDisconnect() {
      connected = false;
      controller?.cancel();
      if (mode === "loading") mode = "idle";
      render();
    },
    onReconnect() {
      connected = true;
      if (panel && window.NRCViewManager.getActiveView() === "search") update();
      else render();
    },
  };
})();
