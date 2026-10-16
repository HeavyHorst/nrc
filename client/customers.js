// Customer records are ordinary room assets. The feature flag controls the view,
// not room-level data permissions. All writes use the acknowledged asset RPCs.
(() => {
  const TYPES = { company: 8, contact: 9, activity: 10 };
  const records = new Map();
  let editorDirty = false;
  let inspection = null;
  let editorBusy = false;
  let editorStale = false;
  let enabled = false;
  let room = 0n;
  let selected = null;
  let loading = false;
  let error = "";
  let generation = 0;
  let featureGeneration = 0;
  let editorGeneration = 0;
  let renderQueued = false;
  let companyIds = new Set();
  let companyCursor = 0n;
  let companyHasMore = false;
  let companyTotal = 0;
  let companyPageError = "";
  const companySearchResults = new Map(); // Projections never enter the asset cache.
  let companySearch;
  let searchNotice = "";
  let searchMode = "idle";
  let recordTab = "overview";
  let recordQuery = "";
  let historyFilter = "all";
  const recordPages = {};
  const PAGE_SIZE = 25;
  let pendingNavigation = null;
  let detailGeneration = 0;
  let edgeSession = null;
  let edgeHasMore = false;
  let detailLoading = false;
  let detailReady = true;
  let searchTimer;
  let detailTimer;
  let contactLinksGeneration = 0;
  let loadingIndicator = null;
  const el = id => document.getElementById(id);
  const active = () => window.NRCViewManager?.getActiveView() === "customers";
  const connected = () => typeof serverReady !== "undefined" && serverReady && ws?.readyState === WebSocket.OPEN;
  const escape = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  function metadata(asset) {
    try {
      const value = JSON.parse(asset.preview);
      if (value.version !== 1 || typeof value.title !== "string") return null;
      return value;
    } catch { return null; }
  }

  function date(nanos) {
    return new Date(Number(BigInt(nanos) / 1000000n)).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  }

  function scheduleRender() {
    if (renderQueued) return;
    renderQueued = true;
    queueMicrotask(() => { renderQueued = false; if (enabled && active()) render(); });
  }

  function updateHtml(container, markup) {
    if (container.nrcMarkup === markup) return;
    const focused = document.activeElement;
    const key = focused && container.contains(focused) ?
      ["id", "data-customer-tab", "data-page", "data-company", "data-edit", "data-contact", "data-activity", "data-target"].find(name => focused.hasAttribute(name)) : null;
    const value = key && focused.getAttribute(key);
    container.innerHTML = markup;
    container.nrcMarkup = markup;
    if (key) container.querySelector(`[${key}="${CSS.escape(value)}"]`)?.focus({ preventScroll: true });
  }

  function onAssetChanged(asset, reason) {
    if (!enabled || asset.convId !== room || !Object.values(TYPES).includes(asset.assetType)) return;
    records.set(asset.assetId, asset);
    if (reason === "mutation" && inspection?.id === asset.assetId && !editorBusy) {
      if (editorDirty) {
        editorStale = true;
        el("customerEditorError").textContent = "This record changed elsewhere. Copy your draft and reopen it before saving.";
        updateEditorState();
      } else showInspector(inspection);
    }
    if (reason === "mutation" && asset.assetType !== TYPES.activity) queueSearch();
    if (reason === "mutation" && asset.assetType === TYPES.company && inspection?.type === "contact") loadContactCompanies(inspection);
    scheduleRender();
  }

  function onAssetDeleted(convId, assetId) {
    if (convId !== room) return;
    const type = inspection?.id === assetId ? inspection.type : Object.keys(TYPES).find(kind => TYPES[kind] === records.get(assetId)?.assetType);
    if (type) window.NRCInspector?.entityDeleted({ roomId: convId, type, id: assetId });
    records.delete(assetId);
    companyIds.delete(assetId);
    if (inspection?.type === "contact") loadContactCompanies(inspection);
    queueSearch();
    scheduleRender();
  }

  function isCompanyLink(edge, companyId, assetId) {
    return edge.relation === window.NRCEdges.RelationType.MemberOf &&
      edge.sourceType === 1 && edge.targetType === 1 &&
      ((edge.sourceId === companyId && edge.targetId === assetId) ||
       (edge.targetId === companyId && edge.sourceId === assetId));
  }

  function linkedRecords(companyId, type) {
    const ids = new Set();
    for (const edge of selectedEdges()) {
      const id = edge.sourceId === companyId ? edge.targetId : edge.sourceId;
      if (isCompanyLink(edge, companyId, id)) ids.add(id);
    }
    return list(type).filter(asset => ids.has(asset.assetId));
  }

  function onEdgeChanged(detail, kind) {
    if (!enabled || detail.convId !== room) return;
    if ((kind === "created" || kind === "deleted") && inspection?.type === "contact" && inspection.id &&
        (detail.sourceId === inspection.id || detail.targetId === inspection.id || detail.relation == null)) {
      loadContactCompanies(inspection);
    }
    if (kind === "created" || kind === "deleted") {
      if ((kind === "deleted" && detail.relation == null) ||
          (detail.relation === window.NRCEdges.RelationType.MemberOf && detail.sourceType === 1 && detail.targetType === 1)) queueSearch();
      if (selected !== null && ((detail.sourceType === 1 && detail.sourceId === selected) || (detail.targetType === 1 && detail.targetId === selected))) {
        clearTimeout(detailTimer);
        detailTimer = setTimeout(() => { if (active() && connected()) loadRelationships(true); }, 150);
      }
    }
    scheduleRender();
  }

  function selectedEdges() {
    if (selected === null || !edgeSession) return [];
    return window.NRCEdges.getEdgesForEntity(room, 1, selected).filter(edge => edgeSession.seen.has(edge.edgeId));
  }

  function queueSearch() {
    if (!enabled || !active()) return;
    pendingNavigation = null;
    el("customersPager").setState({ active: false });
    companyHasMore = false;
    ++generation; // In-flight results belong to the old query/live state.
    companySearch?.cancel();
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => loadCompanies(true), 200);
  }

  async function loadCompanies(reset = false) {
    if (!enabled || !active() || !connected()) return;
    if (!reset && (loading || !companyHasMore)) return;
    const request = ++generation;
    const expectedRoom = room;
    const cursor = reset ? 0n : companyCursor;
    const query = el("customersSearch").value.trim();
    const includeArchived = el("customersArchived").checked;
    const cancelled = () => generation !== request || room !== expectedRoom || !active() || !connected();
    let automaticSelection = null;
    if (reset) {
      companySearch?.cancel();
      companySearchResults.clear();
      searchMode = "idle";
      searchNotice = "";
      pendingNavigation = null; companyIds = new Set(); companyCursor = 0n; companyHasMore = false;
    }
    loading = true;
    error = "";
    companyPageError = "";
    render();
    try {
      if (query && reset) {
        companySearch ||= window.NRCSearch.createController();
        try {
          const data = await new Promise((resolve, reject) => companySearch.search({
            query, top_n: 100, include_payload: true,
            filters: { entity_types: ["asset"], asset_types: [8, 9], customer: { include_archived: includeArchived } },
          }, { onResult: resolve, onError: reject }));
          if (cancelled()) return;
          for (const hit of data.results) {
            const ref = hit.entity;
            const asset = { assetId: typeof ref?.id === "string" && /^[1-9]\d*$/.test(ref.id) ? BigInt(ref.id) : 0n,
              convId: expectedRoom, assetType: TYPES.company, preview: hit.preview };
            if (ref?.type !== "asset" || ref.conv_id !== "0" || ref.workspace !== currentWorkspaceId ||
                asset.assetId === 0n || asset.assetId > 18446744073709551615n || hit.metadata?.asset_type !== TYPES.company || !metadata(asset) ||
                (!includeArchived && metadata(asset).archived)) {
              throw new Error("Search returned an invalid company record.");
            }
            companySearchResults.set(asset.assetId, asset);
          }
          companyIds = new Set(companySearchResults.keys());
          companyTotal = companyIds.size;
          searchMode = "results";
          searchNotice = data.stale ? "Search results may be outdated. Refresh to retry reconciliation." :
            data.results.length === 100 ? "TOP 100 · Narrow the query to find more customers." : "";
          if (!metadata(records.get(selected))) automaticSelection = companyIds.values().next().value ?? null;
          return;
        } catch (failure) {
          if (cancelled()) return;
          companySearchResults.clear();
          searchMode = "fallback";
          searchNotice = "Search service unavailable — using NRC server text search.";
        }
      }
      const result = await window.NRCAssets.requestCustomerPage(room, {
        query, includeArchived,
        afterId: cursor, isCancelled: cancelled,
      });
      if (cancelled()) return;
      if (result.hasMore && result.nextId <= cursor) throw new Error("Customer cursor did not advance");
      for (const asset of result.assets) { records.set(asset.assetId, asset); companyIds.add(asset.assetId); }
      companyCursor = result.nextId;
      companyHasMore = result.hasMore;
      companyTotal = result.totalCount;
      if (!metadata(records.get(selected))) automaticSelection = result.assets.find(asset => metadata(asset))?.assetId ?? null;
    } catch (failure) {
      if (generation !== request) return;
      pendingNavigation = null;
      error = companyPageError = failure.message;
    } finally {
      if (generation === request) {
        loading = false;
        if (automaticSelection !== null) selectCompany(automaticSelection);
        else render();
        const pending = pendingNavigation;
        pendingNavigation = null;
        if (pending !== null && pending === selected && active()) selectAdjacentCompany(1);
      }
    }
  }

  function selectAdjacentCompany(direction, from = selected) {
    const adjacent = window.NRCListNavigation.resolveAdjacent(
      el("customersList").querySelectorAll("[data-company]"), from, direction,
      row => BigInt(row.dataset.company),
    );
    pendingNavigation = null;
    if (adjacent.status === "boundary" && direction > 0 && companyHasMore && !error) {
      if (from !== selected) selectCompany(from);
      pendingNavigation = selected;
      loadCompanies();
    }
    if (adjacent.status !== "target") return;
    const id = adjacent.row.dataset.company;
    selectCompany(id);
    const row = el("customersList").querySelector(`[data-company="${id}"]`);
    row?.focus({ preventScroll: true });
    row?.scrollIntoView({ block: "nearest" });
  }

  function handleKeyboardNavigation(event) {
    if (!enabled || !active() || event.defaultPrevented || event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) return;
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    if (event.target.closest?.("input, textarea, select, [contenteditable], #inspector, [role=dialog], [role=menu], [role=listbox]") ||
        window.NRCLinksUI.isPickerVisible() ||
        [...document.querySelectorAll('[aria-modal="true"]')].some(dialog => dialog.getClientRects().length > 0)) return;
    const contact = event.target.closest?.("#customerRecord [data-contact]");
    const company = event.target.closest?.("#customersList [data-company]");
    const direction = event.key === "ArrowDown" ? 1 : -1;
    if (contact) {
      event.preventDefault();
      const adjacent = window.NRCListNavigation.resolveAdjacent(
        contact.parentElement.querySelectorAll("[data-contact]"), contact.dataset.contact, direction,
        row => row.dataset.contact,
      );
      if (adjacent.status === "target") {
        adjacent.row.focus({ preventScroll: true });
        adjacent.row.scrollIntoView({ block: "nearest" });
      }
      return;
    }
    if (!company && (window.NRCInspector?.hasEntity() || event.target.closest?.("#customerRecord"))) return;
    event.preventDefault();
    selectAdjacentCompany(direction, company ? BigInt(company.dataset.company) : selected);
  }

  async function loadRelationships(reset = false) {
    if (!enabled || !active() || !connected() || selected === null) return;
    if (!reset && (detailLoading || !edgeHasMore)) return;
    const request = ++detailGeneration;
    const expectedRoom = room;
    const company = selected;
    const cancelled = () => request !== detailGeneration || expectedRoom !== room || company !== selected || !active();
    if (reset) { edgeSession = null; edgeHasMore = false; }
    detailLoading = true;
    detailReady = false;
    error = "";
    scheduleRender();
    try {
      const result = await window.NRCEdges.requestEdgePage(room, 1, company, { session: edgeSession, isCancelled: cancelled });
      if (cancelled()) return;
      edgeSession = result.session;
      edgeHasMore = result.hasMore;
      // Resolve this relationship set in bounded batches, without fetching bodies
      // or marking a room-wide collection complete.
      const assets = new Set([company]);
      const tasks = new Set();
      for (const edge of selectedEdges()) {
        const outgoing = edge.sourceType === 1 && edge.sourceId === company;
        if ((outgoing ? edge.targetType : edge.sourceType) === 1) assets.add(outgoing ? edge.targetId : edge.sourceId);
        if ((outgoing ? edge.targetType : edge.sourceType) === 2) tasks.add(outgoing ? edge.targetId : edge.sourceId);
      }
      const [, linkedAssets] = await Promise.all([
        window.NRCTasks.requestTasksByIds(expectedRoom, [...tasks]),
        window.NRCAssets.requestAssetsByIds(expectedRoom, [...assets], { force: reset }),
      ]);
      if (!cancelled()) for (const { assetId } of linkedAssets) {
        const current = window.NRCAssets.roomAssets.get(expectedRoom)?.get(assetId);
        if (current) onAssetChanged(current);
      }
      if (!cancelled()) detailReady = true;
    } catch (failure) {
      if (!cancelled()) { error = failure.message; detailReady = !reset; }
    } finally {
      if (!cancelled()) { detailLoading = false; scheduleRender(); }
    }
  }

  async function refreshAccess() {
    const request = ++featureGeneration;
    let allowed = false;
    try {
      const response = await fetch("/api/features", { credentials: "same-origin", cache: "no-store" });
      allowed = response.ok && (await response.json()).customers === true;
    } catch { /* Fail closed, including static or offline clients. */ }
    if (request !== featureGeneration) return;
    enabled = allowed;
    el("customersBtn").hidden = !enabled;
    if (!enabled) {
      ++generation;
      ++detailGeneration;
      companySearch?.cancel();
      clearTimeout(searchTimer);
      clearTimeout(detailTimer);
      records.clear();
      if (inspection) window.NRCInspector?.entityDeleted(inspection);
      if (active()) window.NRCViewManager.setActiveView("chat");
    } else if (active()) reload();
  }

  async function reload() {
    if (!enabled || !active()) return;
    clearTimeout(searchTimer);
    clearTimeout(detailTimer);
    ++generation;
    ++detailGeneration;
    companySearch?.cancel();
    companySearchResults.clear();
    room = 0n;
    records.clear();
    companyIds.clear();
    edgeSession = null;
    error = "";
    companyPageError = "";
    loading = connected();
    render();
    if (!connected()) return;
    await Promise.all([loadCompanies(true), loadRelationships(true)]);
  }

  function onRoomSwitch() {
    ++generation;
    ++detailGeneration;
    companySearch?.cancel();
    companySearchResults.clear();
    edgeSession = null;
    detailLoading = false;
    detailReady = true;
    records.clear();
    selected = null;
    room = 0n;
    if (inspection) window.NRCInspector?.entityDeleted(inspection);
    window.NRCLinksUI?.closeLinkPicker();
    if (active()) reload();
  }

  function onDisconnect() {
    ++generation;
    ++detailGeneration;
    companySearch?.cancel();
    clearTimeout(searchTimer);
    clearTimeout(detailTimer);
    loading = false;
    detailLoading = false;
    error = "OFFLINE — reconnect before reading or saving customer records.";
    ++editorGeneration;
    if (inspection) {
      editorBusy = false;
      editorStale = true;
      el("customerEditorError").textContent = "Connection lost. A sent save may have succeeded. Copy your draft, close and refresh before retrying.";
      updateEditorState();
    }
    scheduleRender();
  }

  function list(type) {
    return [...records.values()].filter(a => a.assetType === type && metadata(a));
  }

  function render() {
    const query = el("customersSearch").value.trim().toLocaleLowerCase();
    const companies = [...companyIds].map(id => companySearchResults.get(id) || records.get(id)).filter(asset => asset && metadata(asset));
    loadingIndicator ||= window.createLoadingIndicator(render);
    const showLoading = loadingIndicator.update(loading && active());
    el("customersList").setAttribute("aria-busy", String(loading));
    if (!loading || companies.length || showLoading || companyPageError) {
      el("customersState").textContent = companyPageError ? "CUSTOMER QUERY FAILED" :
        loading && companies.length === 0 ? "LOADING…" : searchMode === "results" ?
        `${companies.length} RESULTS` : `${companies.length} / ${companyTotal} CUSTOMERS`;
    }
    el("customersPager").setState({
      hasMore: companyHasMore, loading, error: companyPageError, active: active(),
      disabled: !connected(), label: "LOAD MORE CUSTOMERS",
      // The viewport respects both the desktop register and mobile panel clipping.
      root: null,
    });
    el("customersStatus").textContent = [(error !== companyPageError ? error : "") || (!connected() ? "OFFLINE — connect to load customers." : ""), searchNotice].filter(Boolean).join(" ");
    el("customersStatus").hidden = !el("customersStatus").textContent;
    el("customerNew").disabled = !connected() || loading || !!error;
    updateHtml(el("customersList"), companies.map(a => {
      const d = metadata(a);
      return `<button type="button" class="customer-row" data-company="${a.assetId}" aria-pressed="${selected === a.assetId}" title="${escape(d.title)}"><span class="customer-row-copy"><strong class="customer-row-title">${escape(d.title)}</strong><span class="customer-meta customer-row-meta">${escape(d.city || "—")} · ${escape(d.assignee || "UNASSIGNED")}${d.archived ? ' · <span class="customer-row-state">ARCHIVED</span>' : ""}</span></span></button>`;
    }).join("") || (companyPageError || (loading && !showLoading) ? "" : `<p class="customer-empty">${loading ? "Loading customer register…" : query ? "No matching customers." : "No customers. Create the first company in this room."}</p>`));
    // Keep the previous detail DOM intact until every endpoint in the page is
    // hydrated. Its actions must not operate on the newly selected company.
    el("customerRecord").inert = !detailReady;
    el("customerRecord").setAttribute("aria-busy", String(detailLoading));
    if (!detailReady) return;
    // Leave the picker and its anchor intact during live updates. Apply the
    // latest record when the user closes the picker, not on a timer.
    if (window.NRCLinksUI.isPickerVisible()) return;
    // Keep selection stable when a broadcast updates the register. Search only
    // filters the list; the selected record remains explicitly visible.
    const company = records.get(selected);
    if (!company || !metadata(company)) {
      updateHtml(el("customerRecord"), `<p class="customer-empty">${companyPageError ? "Customer register unavailable." : "Select a company to view contacts, history and linked work."}</p>`);
      return;
    }
    const d = metadata(company);
    const people = linkedRecords(selected, TYPES.contact);
    const activities = linkedRecords(selected, TYPES.activity);
    activities.sort((a, b) => a.createdAt === b.createdAt ? (a.assetId > b.assetId ? -1 : 1) : (a.createdAt > b.createdAt ? -1 : 1));
    const disabled = !connected() || loading || !!error ? "disabled" : "";
    const archived = d.archived ? "disabled" : disabled;
    const overview = recordTab === "overview";
    const partial = edgeHasMore || !!error;
    const count = value => `${value}${partial ? "+" : ""}`;
    const matches = value => !recordQuery || String(value).toLocaleLowerCase().includes(recordQuery.toLocaleLowerCase());
    const contacts = overview ? people : people.filter(a => matches(Object.values(metadata(a)).join(" ")));
    const history = overview ? activities : activities.filter(a => (historyFilter === "all" || metadata(a).kind === historyFilter) && matches(Object.values(metadata(a)).join(" ")));
    const work = workEdges();
    const files = (window.NRCFiles?.linkedFiles(company, 1, selectedEdges()) || []).filter(ref => window.NRCAssets.roomAssets.get(room)?.get(ref.assetId)?.assetType === window.NRCAssets.AssetType.File);
    const visibleFiles = overview ? files : files.filter(ref => matches(window.NRCLinksUI.resolveTargetName(room, 1, ref.assetId)));
    const sectionHidden = tab => overview || recordTab === tab ? "" : "hidden";
    updateHtml(el("customerRecord"), `
      <div class="customer-record-header"><nav class="tab-group customer-tabs" aria-label="Customer sections">${[["overview", "OVERVIEW", null], ["contacts", "CONTACTS", people.length], ["activities", "ACTIVITIES", activities.length], ["work", "LINKS", work.length], ["files", "FILES", files.length]].map(([tab, label, total]) => `<button type="button" class="btn nav-tab ${recordTab === tab ? "active" : ""}" data-customer-tab="${tab}" aria-pressed="${recordTab === tab}">${label}${total === null ? "" : `<span class="tab-count">${count(total)}</span>`}</button>`).join("")}</nav>
      <div class="customer-identity"><div><span class="customer-meta">CUSTOMER #${selected} / ${d.archived ? "ARCHIVED" : "ACTIVE"}</span><h2>${escape(d.title)}</h2><span class="customer-meta">${escape(d.city || "—")} · RESPONSIBLE / ${escape(d.assignee || "UNASSIGNED")}</span></div><div class="customer-actions"><button class="btn" data-edit="${selected}" ${disabled}>EDIT</button><button class="btn" id="customerArchive" ${disabled}>${d.archived ? "RESTORE" : "ARCHIVE"}</button></div></div></div>
      <div class="customer-record-body">
      ${partial ? '<p class="customer-meta customer-footnote">PARTIAL · Counts and search cover loaded links only. Load more below.</p>' : ""}
      ${overview ? "" : `<label class="customer-history-filter"><span class="filter-label">SEARCH ${recordTab.toUpperCase()}</span><input id="customerRecordSearch" class="filter-input" type="search" value="${escape(recordQuery)}" placeholder="Search loaded records"></label>`}
      <dl class="customer-facts" ${overview ? "" : "hidden"}><div><dt>CUSTOMER NO.</dt><dd>${escape(d.number || "—")}</dd></div><div><dt>TYPE / SECTOR</dt><dd>${escape([d.account_type, d.sector].filter(Boolean).join(" / ") || "—")}</dd></div><div><dt>PHONE</dt><dd>${escape(d.phone || "—")}</dd></div><div><dt>ADDRESS</dt><dd>${escape(d.address || "—")}</dd></div><div><dt>WEBSITE</dt><dd>${escape(d.website || "—")}</dd></div></dl>
      <div class="customer-overview-grid ${overview ? "is-overview" : ""}">
      <section class="customer-section" ${sectionHidden("contacts")}><div class="panel-header"><div><span>CONTACTS / ${count(people.length)}</span><button class="btn" id="customerContactNew" ${archived}>+ CONTACT</button></div></div><div class="customer-contacts">${contacts.length ? '<div class="customer-contact-head" aria-hidden="true"><span>NAME / ROLE</span><span>EMAIL</span><span>PHONE</span></div>' : ""}${pageItems(contacts, "contacts").map(a => {
        const p = metadata(a);
        return `<button type="button" class="customer-contact" data-contact="${a.assetId}" aria-pressed="${inspection?.type === "contact" && inspection.id === a.assetId}"><span><strong>${escape(p.title)}</strong><span class="customer-meta">${escape(p.role || "—")}</span></span><span>${escape(p.email || "—")}</span><span>${escape(p.phone || "—")}</span></button>`;
      }).join("") || '<p class="customer-empty">No contacts in this selection.</p>'}</div>${recordPager("contacts", contacts.length)}</section>
      <section class="customer-section" ${sectionHidden("activities")}><div class="panel-header"><div><span>${overview ? "LATEST RECORDED ACTIVITIES" : "ACTIVITY HISTORY"} / ${count(activities.length)}</span><button class="btn" id="customerActivityNew" ${archived}>+ ACTIVITY</button></div></div><label class="customer-history-filter" ${overview ? "hidden" : ""}><span class="filter-label">TYPE</span><nrc-select><select class="filter-select" id="customerHistoryFilter" data-custom-select-portal>${["all", "Call", "Meeting", "Email", "Decision"].map(value => `<option value="${value}" ${historyFilter === value ? "selected" : ""}>${value.toUpperCase()}</option>`).join("")}</select></nrc-select></label><div id="customerHistory" class="${overview && history.length > 1 ? "customer-history-timeline" : ""}">${pageItems(history, "activities").map(a => {
        const m = metadata(a);
        return `<button class="customer-event" data-activity="${a.assetId}" data-kind="${escape(m.kind)}"><span class="customer-meta">${escape(date(a.createdAt))} / ${escape(a.owner)} / ${escape(m.kind)}</span><strong>${escape(m.title)}</strong><span>${escape(m.excerpt || "")}</span></button>`;
      }).join("") || '<p class="customer-empty">No activities in this selection.</p>'}</div>${recordPager("activities", history.length)}<p class="customer-meta customer-footnote">RECORD CREATION DATE · CUSTOMER ACTIVITIES, NOT TASK UPDATES</p></section>
      <section class="customer-section" ${sectionHidden("work")}><div class="panel-header"><div><span>LINKED SLICES, TASKS & NOTES / ${count(work.length)}</span><button class="btn" id="customerLinkAdd" ${archived}>+ LINK</button></div></div><div id="customerWork"></div><nrc-link-picker id="customerLinkPicker"></nrc-link-picker></section>
      <section class="customer-section" ${sectionHidden("files")}><div id="customerFiles"></div>${recordPager("files", visibleFiles.length)}</section></div>
      ${edgeHasMore || error ? `<div class="customer-page"><button class="btn" id="customerRelationshipsMore" ${!connected() || detailLoading ? "disabled" : ""}>${error ? "RETRY LOADING LINKS" : "LOAD MORE LINKS"}</button><span class="customer-meta">Contacts, activities, files and work share relationship pages.</span></div>` : ""}</div>`);
    el("customerHistoryFilter").onchange = event => { historyFilter = event.target.value; recordPages.activities = 0; render(); };
    if (el("customerRecordSearch")) el("customerRecordSearch").oninput = event => {
      const position = event.target.selectionStart;
      recordQuery = event.target.value; recordPages[recordTab] = 0; render();
      el("customerRecordSearch").setSelectionRange(position, position);
    };
    if (el("customerRelationshipsMore")) el("customerRelationshipsMore").onclick = () => loadRelationships(!!error);
    el("customerContactNew").onclick = () => edit("contact");
    el("customerActivityNew").onclick = () => edit("activity");
    el("customerArchive").onclick = () => saveRecord(company, { ...d, archived: !d.archived }, "");
    el("customerLinkAdd").onclick = event => {
      event.stopPropagation();
      el("customerLinkPicker").open({
        anchor: event.currentTarget, sourceType: 1, sourceEntity: company,
        onSelect: (item, relation) => window.NRCLinksUI.createPickedLink(company, 1, item, relation),
      });
    };
    window.NRCFiles?.renderSection(el("customerFiles"), company, 1, pageItems(visibleFiles, "files").flatMap(ref => ref.edges), {
      readOnly: !!d.archived,
      partial: detailLoading || edgeHasMore,
    });
    renderWork();
    const activeTab = el("customerRecord").querySelector("nav .active");
    if (activeTab) {
      const nav = activeTab.parentElement;
      if (activeTab.offsetLeft < nav.scrollLeft) nav.scrollLeft = activeTab.offsetLeft;
      else if (activeTab.offsetLeft + activeTab.offsetWidth > nav.scrollLeft + nav.clientWidth) nav.scrollLeft = activeTab.offsetLeft + activeTab.offsetWidth - nav.clientWidth;
    }
  }

  function pageItems(items, tab) {
    if (recordTab === "overview") return items.slice(0, 4);
    if (recordTab !== tab) return [];
    recordPages[tab] = Math.min(recordPages[tab] || 0, Math.max(0, Math.ceil(items.length / PAGE_SIZE) - 1));
    return items.slice(recordPages[tab] * PAGE_SIZE, (recordPages[tab] + 1) * PAGE_SIZE);
  }

  function recordPager(tab, total) {
    if (recordTab === "overview") return total ? `<div class="customer-page"><button type="button" class="btn" data-customer-tab="${tab}">VIEW ALL ${total}${edgeHasMore ? "+" : ""} →</button></div>` : "";
    const page = Math.min(recordPages[tab] || 0, Math.max(0, Math.ceil(total / PAGE_SIZE) - 1));
    return `<div class="customer-page"><span class="customer-meta">${total ? page * PAGE_SIZE + 1 : 0}–${Math.min(total, (page + 1) * PAGE_SIZE)} / ${total} LOADED</span><button type="button" class="btn" data-page="${tab}:previous" ${page === 0 ? "disabled" : ""}>PREVIOUS</button><button type="button" class="btn" data-page="${tab}:next" ${(page + 1) * PAGE_SIZE >= total ? "disabled" : ""}>NEXT</button></div>`;
  }

  function workEdges() {
    return selectedEdges().filter(edge => {
      const outgoing = edge.sourceType === 1 && edge.sourceId === selected;
      if (!outgoing && !(edge.targetType === 1 && edge.targetId === selected)) return false;
      const type = outgoing ? edge.targetType : edge.sourceType;
      const id = outgoing ? edge.targetId : edge.sourceId;
      return type === 2 || [window.NRCAssets.AssetType.Note, window.NRCAssets.AssetType.Slice].includes(window.NRCAssets.roomAssets.get(room)?.get(id)?.assetType);
    });
  }

  function renderWork() {
    const container = el("customerWork");
    if (!container || selected === null || !detailReady) return;
    const edges = workEdges().filter(edge => {
      const outgoing = edge.sourceType === 1 && edge.sourceId === selected;
      return recordTab === "overview" || window.NRCLinksUI.resolveTargetName(room, outgoing ? edge.targetType : edge.sourceType, outgoing ? edge.targetId : edge.sourceId).toLocaleLowerCase().includes(recordQuery.toLocaleLowerCase());
    });
    updateHtml(container, pageItems(edges, "work").map(edge => {
      const outgoing = edge.sourceType === 1 && edge.sourceId === selected;
      const type = outgoing ? edge.targetType : edge.sourceType;
      const id = outgoing ? edge.targetId : edge.sourceId;
      if (connected() && type === 2 && !window.NRCTasks.roomTasks.get(room)?.has(id)) {
        window.NRCTasks.requestTask(room, id, { onSuccess: renderWork });
      }
      const kind = type === 2 ? "TASK" : window.NRCAssets.roomAssets.get(room)?.get(id)?.assetType === window.NRCAssets.AssetType.Slice ? "SLICE" : "NOTE";
      return `<button class="customer-event customer-work-row" data-target="${id}" data-target-type="${type}" title="${escape(window.NRCEdges.RelationTypeNames[edge.relation])}"><span class="customer-meta"><span class="note-link-direction">${outgoing ? "→" : "←"}</span> ${kind} #${id}</span><strong>${escape(window.NRCLinksUI.resolveTargetName(room, type, id))} ↗</strong></button>`;
    }).join("") + (edges.length ? "" : '<p class="customer-empty">No linked slices, tasks or notes in this selection.</p>') + recordPager("work", edges.length));
  }

  function selectCompany(id) {
    pendingNavigation = null;
    window.NRCLinksUI.closeLinkPicker();
    if (selected !== BigInt(id)) {
      recordTab = "overview"; recordQuery = ""; historyFilter = "all";
      for (const tab of Object.keys(recordPages)) delete recordPages[tab];
      el("customerRecord").scrollTop = 0;
    }
    selected = BigInt(id);
    error = "";
    loadRelationships(true);
    render();
  }

  function field(name, label, value = "", required = false, type = "text") {
    if (name === "assignee") {
      return `<div class="task-detail-row detail-edit-field"><span class="detail-edit-label">${label}</span><div><input name="assignee" type="hidden" value="${escape(value)}" maxlength="200"></div></div>`;
    }
    return `<label class="task-detail-row detail-edit-field"><span class="detail-edit-label">${label}</span><input class="task-detail-input" name="${name}" type="${type}" value="${escape(value)}" maxlength="200" ${required ? "required" : ""}></label>`;
  }

  function clearSelection() {
    ++editorGeneration;
    ++contactLinksGeneration;
    inspection = null;
    editorDirty = false;
    editorBusy = false;
    editorStale = false;
    scheduleRender();
  }

  async function confirmDiscardEdits() {
    if (editorBusy) return false;
    return !editorDirty || await window.NRCDialog.confirm("Discard unsaved customer changes?", { title: "UNSAVED CHANGES", confirmLabel: "Discard" });
  }

  function updateEditorState() {
    const blocked = !enabled || !connected() || editorBusy || editorStale;
    for (const id of ["customerSave", "customerEdit", "customerDelete", "customerUnlink"]) {
      if (el(id)) el(id).disabled = blocked;
    }
    for (const id of ["customerCancel", "customerView", "customerClose"]) {
      if (el(id)) el(id).disabled = editorBusy;
    }
    for (const control of el("contactCompanies")?.querySelectorAll("[data-unlink-company], #contactLinkCompany, [data-link-company]") || []) {
      control.disabled = blocked || control.dataset.archived === "true";
    }
    for (const control of el("customerFields")?.querySelectorAll("input, textarea, select") || []) {
      if (control.tagName === "SELECT") control.disabled = blocked;
      else control.readOnly = blocked;
    }
    window.NRCDetailUI.bindSuggestedInput(el("customerFields")?.querySelector('input[name="assignee"]'), {
      name: "RESPONSIBLE",
      suggestions: () => window.NRCTasks?.getFieldChoices?.("assignee", 0n) || [],
    });
    window.NRCDetailUI.setSaveState(editorBusy ? "SAVING…" : editorStale ? "STALE" : editorDirty ? "UNSAVED" : inspection?.subview === "edit" ? "SAVED" : "READ", el("inspectorHeader"));
  }

  function edit(kind, asset = null) {
    if (!enabled || !connected() || loading || error) return;
    return openRecord(kind, asset?.assetId || 0n, { subview: "edit", companyId: kind === "company" ? null : selected });
  }

  function openRecord(kind, id, options = {}) {
    if (!enabled || !TYPES[kind]) return false;
    return window.NRCInspector.openEntity({ roomId: 0n, type: kind, id: BigInt(id), subview: "read", ...options });
  }

  function showInspector(ref, preparedAsset = null) {
    if (window.NRCInspector?.isLoading?.()) return;
    clearSelection();
    inspection = ref;
    const editor = editorGeneration;
    const current = () => enabled && editor === editorGeneration && window.NRCInspector.current() === ref;
    if (preparedAsset && enabled && preparedAsset.assetType === TYPES[ref.type] && metadata(preparedAsset)) {
      records.set(preparedAsset.assetId, preparedAsset);
      renderInspector(ref, preparedAsset, true);
      return;
    }
    el("inspectorHeader").innerHTML = `<div class="inspector-identity-row"><span class="header-text identity-reference">${ref.type.toUpperCase()} ${ref.id ? "#" + ref.id : "/ NEW"}</span><span class="inspector-cell-label">STATE</span>${window.NRCDetailUI.renderSaveState("LOADING")}</div><div class="inspector-mode-row">${window.NRCDetailUI.renderCloseControl("customerClose")}</div>`;
    el("customerClose").onclick = () => window.NRCInspector.close();
    el("inspectorEntityHost").innerHTML = '<div class="customer-inspector"><p id="customerEditorError" class="customer-status" role="alert"></p></div>';
    if (!enabled) {
      el("customerEditorError").textContent = "Customer records are unavailable.";
      return;
    }
    if (!ref.id) { renderInspector(ref, null); return; }
    window.NRCAssets.requestAsset(0n, ref.id, {
      onSuccess({ asset }) {
        if (!current()) return;
        if (asset.assetType !== TYPES[ref.type] || !metadata(asset)) {
          el("customerEditorError").textContent = "Incompatible customer record.";
          return;
        }
        records.set(asset.assetId, asset);
        renderInspector(ref, asset);
      },
      onError(detail) { if (current()) el("customerEditorError").textContent = detail.message || "Record could not be loaded."; },
    });
  }

  function renderCompanyFacts(d, fields) {
    const fact = ([name, label]) => {
      const value = d[name];
      const present = value != null && value !== "";
      let href = "";
      if (present && name === "phone") href = `tel:${String(value).replace(/[^+0-9*#]/g, "")}`;
      if (present && name === "website") {
        try {
          const url = new URL(/^[a-z][a-z0-9+.-]*:/i.test(value) ? value : `https://${value}`);
          if (["https:", "http:"].includes(url.protocol)) href = url.href;
        } catch { /* Keep invalid URLs readable and copyable. */ }
      }
      const text = present ? escape(String(value)) : "—";
      return `<div><dt>${label}</dt><dd>${href ? `<a href="${escape(href)}" title="${text}"${name === "website" ? ' target="_blank" rel="noopener noreferrer"' : ""}>${text}</a>` : text}</dd>${present && ["address", "website", "phone"].includes(name) ? `<button class="btn" type="button" data-copy-company="${name}" aria-label="Copy ${name}">COPY</button>` : ""}</div>`;
    };
    const groups = [
      ["IDENTITY", ["number"]],
      ["CLASSIFICATION", ["account_type", "sector"]],
      ["LOCATION", ["city", "address"]],
      ["CONTACT", ["website", "phone"]],
      ["OWNERSHIP", ["assignee"]],
    ];
    const byName = new Map(fields.map(item => [item[0], item]));
    return `<div class="customer-fact-sections">${groups.map(([label, names]) => `<section class="customer-field-section"><div class="detail-edit-section-title">${label}</div><dl class="contact-facts company-facts">${names.map(name => fact(byName.get(name))).join("")}</dl></section>`).join("")}</div>`;
  }

  function renderContactFacts(d) {
    return `<dl class="contact-facts">${["role", "email", "phone"].map(name => {
      const value = d[name];
      const href = name === "email" ? `mailto:${encodeURIComponent(value || "")}` : `tel:${String(value || "").replace(/[^+0-9*#]/g, "")}`;
      const text = name === "email" ? escape(value).replace(/([@.])/g, "$1<wbr>") : escape(value);
      return `<div><dt>${name.toUpperCase()}</dt><dd>${value ? name === "role" ? text : `<a href="${escape(href)}">${text}</a>` : "—"}</dd>${value && name !== "role" ? `<button class="btn" type="button" data-copy-contact="${name}" aria-label="Copy ${name}">COPY</button>` : ""}</div>`;
    }).join("")}</dl>`;
  }

  function renderCustomerEditFields(kind, d, fields, asset) {
    if (kind === "activity") {
      return `<section class="customer-field-section"><div class="detail-edit-section-title">ACTIVITY RECORD</div><div class="customer-field-grid customer-field-grid--single">${field("title", "SUBJECT", d.title, true)}
        <label class="task-detail-row detail-edit-field"><span class="detail-edit-label">TYPE</span><select class="task-detail-select" name="kind">${["Call", "Meeting", "Email", "Decision"].map(value => `<option ${d.kind === value ? "selected" : ""}>${value}</option>`).join("")}</select></label>
        <label class="task-detail-row detail-edit-field"><span class="detail-edit-label">RECORD</span><textarea class="task-detail-textarea" name="body" required rows="8" maxlength="8000">${escape(asset?.payload || "")}</textarea></label></div></section>`;
    }
    if (kind === "company") {
      const byName = new Map(fields.map(item => [item[0], item]));
      const editField = name => {
        const [, label, type] = byName.get(name);
        return field(name, label, d[name], false, type);
      };
      return `${field("title", "NAME", d.title, true)}
        <section class="customer-field-section"><div class="detail-edit-section-title">IDENTITY</div><div class="customer-field-grid">${editField("number")}${editField("account_type")}</div></section>
        <section class="customer-field-section"><div class="detail-edit-section-title">CLASSIFICATION</div><div class="customer-field-grid">${editField("sector")}${editField("assignee")}</div></section>
        <section class="customer-field-section"><div class="detail-edit-section-title">LOCATION</div><div class="customer-field-grid customer-field-grid--single">${editField("city")}${editField("address")}</div></section>
        <section class="customer-field-section"><div class="detail-edit-section-title">CONTACT</div><div class="customer-field-grid customer-field-grid--single">${editField("website")}${editField("phone")}</div></section>`;
    }
    return `<section class="customer-field-section"><div class="detail-edit-section-title">CONTACT</div><div class="customer-field-grid customer-field-grid--single">${field("title", "NAME", d.title, true)}${fields.map(([name, label, type]) => field(name, label, d[name], false, type)).join("")}</div></section>`;
  }

  async function loadContactCompanies(ref, hydrated = false) {
    const host = el("contactCompanies");
    if (!host || !connected()) return;
    const request = ++contactLinksGeneration;
    const editor = editorGeneration;
    const cancelled = () => request !== contactLinksGeneration || editor !== editorGeneration || !enabled || !connected();
    const indicator = window.createLoadingIndicator(() => {
      if (!cancelled() && !host.hasChildNodes()) host.innerHTML = '<p class="customer-empty" role="status">LOADING LINKED COMPANIES…</p>';
    });
    indicator.update(true);
    host.inert = true;
    host.setAttribute("aria-busy", "true");
    try {
      if (!hydrated) await window.NRCLinksUI.loadLinks(0n, 1, ref.id, cancelled);
      if (cancelled()) return;
      const ids = new Set();
      for (const edge of window.NRCEdges.getEdgesForEntity(0n, 1, ref.id)) {
        const id = edge.sourceId === ref.id ? edge.targetId : edge.sourceId;
        if (isCompanyLink(edge, id, ref.id)) ids.add(id);
      }
      const assets = [...ids].map(id => window.NRCAssets.roomAssets.get(0n)?.get(id));
      const companies = assets.filter(a => a?.assetType === TYPES.company && metadata(a)).sort((a, b) => metadata(a).title.localeCompare(metadata(b).title));
      host.innerHTML = `<div class="panel-header"><div><span>LINKED COMPANIES / ${companies.length}</span><button id="contactLinkCompany" class="btn" type="button" aria-expanded="false">LINK COMPANY</button></div></div>
        <div class="contact-company-list">${companies.length ? `<table class="contact-company-table"><thead><tr><th scope="col">COMPANY</th><th scope="col">ACTIONS</th></tr></thead><tbody>${companies.map(a => `<tr><td>${escape(metadata(a).title)}${metadata(a).archived ? ' <span class="customer-meta">/ ARCHIVED</span>' : ""}</td><td><div class="customer-actions"><button class="btn btn--row" type="button" data-open-company="${a.assetId}" aria-label="Open ${escape(metadata(a).title)}">OPEN</button><button class="btn btn--row" type="button" data-unlink-company="${a.assetId}" data-archived="${!!metadata(a).archived}" aria-label="Unlink ${escape(metadata(a).title)}">UNLINK</button></div></td></tr>`).join("")}</tbody></table>` : '<p class="customer-empty">No linked companies.</p>'}</div>
        <div id="contactCompanyPicker" hidden><label class="customer-history-filter"><span class="filter-label">COMPANY</span><input id="contactCompanySearch" class="filter-input" type="search" placeholder="Search companies" maxlength="200"></label><div id="contactCompanyResults" class="file-assets-picker-list"></div><button id="contactCompanyMore" class="btn" type="button" hidden>LOAD MORE</button></div>`;
      host.querySelectorAll("[data-open-company]").forEach(button => { button.onclick = () => openRecord("company", button.dataset.openCompany); });
      host.querySelectorAll("[data-unlink-company]").forEach(button => { button.onclick = () => removeRecord({ ...ref, companyId: BigInt(button.dataset.unlinkCompany) }, true); });
      let searchGeneration = 0;
      let cursor = 0n;
      let timer;
      const search = async (reset = true) => {
        const searchRequest = ++searchGeneration;
        const stale = () => cancelled() || searchRequest !== searchGeneration;
        if (reset) { cursor = 0n; el("contactCompanyResults").innerHTML = ""; }
        el("contactCompanyMore").disabled = true;
        try {
          const result = await window.NRCAssets.requestCustomerPage(0n, { query: el("contactCompanySearch").value.trim(), afterId: cursor, isCancelled: stale });
          if (stale()) return;
          cursor = result.nextId;
          const available = result.assets.filter(a => metadata(a) && !metadata(a).archived && !ids.has(a.assetId));
          if (!el("contactCompanyResults").children.length) el("contactCompanyResults").textContent = "";
          el("contactCompanyResults").insertAdjacentHTML("beforeend", available.map(a => `<div class="file-assets-picker-row"><span>${escape(metadata(a).title)}</span><button class="btn" type="button" data-link-company="${a.assetId}">LINK</button></div>`).join(""));
          if (!el("contactCompanyResults").children.length) el("contactCompanyResults").textContent = "No unlinked companies in these results.";
          el("contactCompanyMore").hidden = !result.hasMore;
          el("contactCompanyMore").disabled = false;
          host.querySelectorAll("[data-link-company]").forEach(button => { button.onclick = async () => {
            if (editorBusy || editorStale || cancelled()) return;
            editorBusy = true;
            updateEditorState();
            try {
              await new Promise((resolve, reject) => {
                if (!window.NRCEdges.sendCreateEdge(0n, 1, ref.id, 1, BigInt(button.dataset.linkCompany), window.NRCEdges.RelationType.MemberOf, { onSuccess: resolve, onError: detail => reject(new Error(detail.message || "Link failed")) })) reject(new Error("Not connected"));
              });
              if (editor !== editorGeneration) return;
              editorBusy = false;
              loadContactCompanies(ref);
              if (active()) loadRelationships(true);
            } catch (failure) {
              if (editor !== editorGeneration) return;
              editorBusy = false;
              el("customerEditorError").textContent = failure.message;
            }
            updateEditorState();
          }; });
          updateEditorState();
        } catch (failure) { if (!stale()) el("contactCompanyResults").textContent = failure.message; }
      };
      el("contactLinkCompany").onclick = () => {
        const picker = el("contactCompanyPicker");
        picker.hidden = !picker.hidden;
        el("contactLinkCompany").setAttribute("aria-expanded", String(!picker.hidden));
        if (!picker.hidden) { search(); el("contactCompanySearch").focus(); }
      };
      el("contactCompanySearch").oninput = () => { ++searchGeneration; clearTimeout(timer); timer = setTimeout(() => { if (!cancelled()) search(); }, 200); };
      el("contactCompanySearch").onkeydown = event => { if (event.key === "Enter") { event.preventDefault(); event.stopPropagation(); search(); } };
      el("contactCompanyMore").onclick = () => search(false);
      updateEditorState();
    } catch (failure) {
      if (!cancelled()) {
        host.innerHTML = `<p class="customer-status" role="alert">${escape(failure.message)}</p><button class="btn" type="button">RETRY</button>`;
        host.querySelector("button").onclick = () => loadContactCompanies(ref);
      }
    } finally {
      indicator.update(false);
      if (request === contactLinksGeneration && editor === editorGeneration) {
        host.inert = false;
        host.setAttribute("aria-busy", "false");
      }
    }
  }

  function renderInspector(ref, asset, linksHydrated = false) {
    const kind = ref.type;
    const d = asset ? metadata(asset) : {};
    const editing = !asset || ref.subview === "edit";
    const contact = kind === "contact" && asset;
    const companyFacts = kind === "company" && asset;
    const fields = kind === "company" ? [["number", "CUSTOMER NUMBER"], ["account_type", "TYPE"], ["sector", "SECTOR"], ["city", "CITY"], ["address", "ADDRESS"], ["website", "WEBSITE"], ["phone", "PHONE", "tel"], ["assignee", "RESPONSIBLE"]] :
      kind === "contact" ? [["role", "ROLE"], ["email", "EMAIL", "email"], ["phone", "PHONE", "tel"]] : [["kind", "TYPE"]];
    const company = ref.companyId && records.get(ref.companyId);
    const unlink = asset && company && !metadata(company)?.archived && selectedEdges().some(edge => isCompanyLink(edge, ref.companyId, ref.id));
    const register = asset ? window.NRCDetailUI.renderHeaderMetadata([
      { label: "CREATED BY", value: asset.owner, role: "actor" },
      { label: "CREATED", value: window.NRCDetailUI.formatHeaderDate(asset.createdAt) },
      { label: "UPDATED", value: window.NRCDetailUI.formatHeaderDate(asset.updatedAt) },
    ]) : "";
    el("inspectorHeader").innerHTML = `<div class="inspector-identity-row"><span class="header-text identity-reference">${kind.toUpperCase()} ${asset ? "#" + asset.assetId : "/ NEW"}</span>${register}<span class="inspector-cell-label">STATE</span>${window.NRCDetailUI.renderSaveState(editing ? "SAVED" : "READ")}</div><div class="inspector-mode-row">
      ${asset ? window.NRCDetailUI.renderHeaderAction(editing ? { id: "customerView", label: "VIEW", command: "v", title: "Read record (V)" } : { id: "customerEdit", label: "EDIT", command: "e", title: "Edit record (E)" }) : ""}
      ${window.NRCDetailUI.renderCloseControl("customerClose")}</div>`;
    const actions = `${editing ? '<button id="customerSave" class="btn btn--primary task-modal-btn save" type="submit">SAVE</button><button id="customerCancel" class="btn btn--ghost task-modal-btn" type="button">CANCEL</button>' : ""}${asset && kind !== "company" ? '<button id="customerDelete" class="btn btn--danger task-modal-btn danger" type="button">DELETE</button>' : ""}`;
    el("inspectorEntityHost").innerHTML = `<form id="customerForm" class="customer-inspector">
      <div class="customer-inspector-body detail-edit-form">${editing ? `<div id="customerFields" class="customer-fields detail-edit-form">${renderCustomerEditFields(kind, d, fields, asset)}</div>` :
        `<h2 class="note-preview-title">${escape(d.title)}</h2>${contact ? renderContactFacts(d) : companyFacts ? renderCompanyFacts(d, fields) : window.NRCDetailUI.renderMetadataLedger(fields.map(([name, label]) => ({ label, value: d[name] })))}${kind === "activity" ? `<p id="customerActivityBody" class="customer-activity-body">${escape(asset.payload)}</p>` : ""}`}
      ${contact ? '<section id="contactCompanies" class="customer-section" aria-label="Linked companies"></section>' : unlink ? `<p class="customer-meta">LINKED COMPANY / ${escape(metadata(company).title)}</p><button id="customerUnlink" class="btn" type="button">REMOVE FROM THIS COMPANY</button>` : ""}
      <p id="customerEditorError" class="customer-status" role="alert"></p></div>
      ${actions ? `<div class="note-detail-actions">${actions}</div>` : ""}</form>`;
    el("customerClose").onclick = () => window.NRCInspector.close();
    if (el("customerEdit")) el("customerEdit").onclick = () => openRecord(kind, ref.id, { ...ref, subview: "edit" });
    if (el("customerView")) el("customerView").onclick = () => openRecord(kind, ref.id, { ...ref, subview: "read" });
    if (el("customerCancel")) el("customerCancel").onclick = () => asset ? openRecord(kind, ref.id, { ...ref, subview: "read" }) : window.NRCInspector.back();
    if (el("customerDelete")) el("customerDelete").onclick = () => removeRecord(ref, false);
    if (el("customerUnlink")) el("customerUnlink").onclick = () => removeRecord(ref, true);
    if (contact) loadContactCompanies(ref, linksHydrated);
    for (const button of el("customerForm").querySelectorAll("[data-copy-contact], [data-copy-company]")) {
      button.onclick = async () => {
        try { await navigator.clipboard.writeText(d[button.dataset.copyContact || button.dataset.copyCompany]); button.textContent = "COPIED"; }
        catch { el("customerEditorError").textContent = "Copy failed. Select and copy the value manually."; }
      };
    }
    updateEditorState();
    if (!editing) return;
    const form = el("customerForm");
    const editor = editorGeneration;
    form.oninput = event => { if (event.target.closest("#customerFields")) { editorDirty = true; updateEditorState(); } };
    form.onkeydown = event => {
      if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); form.requestSubmit(); }
    };
    form.onsubmit = async event => {
      event.preventDefault();
      if (editor !== editorGeneration || !connected() || !enabled || editorBusy || editorStale) return;
      const values = Object.fromEntries(new FormData(form));
      for (const key of Object.keys(values)) values[key] = values[key].trim();
      if (!values.title || (kind === "activity" && !values.body)) {
        el("customerEditorError").textContent = "Name / subject and record must not be blank.";
        return;
      }
      const body = values.body || "";
      delete values.body;
      const meta = { ...d, ...values, version: 1 };
      delete meta.companyId;
      if (kind === "activity") meta.excerpt = body.slice(0, 160);
      editorBusy = true;
      updateEditorState();
      try {
        const result = await write(asset, TYPES[kind], meta, body, 0n, ref.companyId);
        if (editor !== editorGeneration) return;
        editorBusy = false;
        editorDirty = false;
        if (asset) await openRecord(kind, ref.id, { ...ref, subview: "read" });
        else await window.NRCInspector.back();
        if (kind === "company" && active()) selectCompany(result.asset.assetId);
        scheduleRender();
      } catch (failure) {
        if (editor !== editorGeneration) return;
        editorBusy = false;
        el("customerEditorError").textContent = failure.message;
        updateEditorState();
        el("customerSave").textContent = "RETRY SAVE";
      }
    };
  }

  async function removeRecord(ref, unlink) {
    if (editorBusy || editorStale || !connected() || !enabled) return;
    const editor = editorGeneration;
    const message = unlink ? `Remove the link to company #${ref.companyId}? The record and its links to other companies are preserved.` : `Permanently delete ${ref.type} #${ref.id}? This deletes the record and ALL its links, including links to other companies. This cannot be undone.`;
    const confirmed = await window.NRCDialog.confirm(message, { title: unlink ? "REMOVE COMPANY LINK" : "DELETE RECORD", confirmLabel: unlink ? "Remove link" : "Delete everywhere" });
    if (!confirmed || editor !== editorGeneration || !enabled || !connected() || editorBusy || editorStale) return;
    editorBusy = true;
    updateEditorState();
    try {
      const rpc = send => new Promise((resolve, reject) => {
        if (!send({ onSuccess: resolve, onError: detail => reject(new Error(detail.message || "Operation failed.")) })) reject(new Error("Not connected. Nothing was sent."));
      });
      if (unlink) {
        let page;
        do {
          page = await window.NRCEdges.requestEdgePage(0n, 1, ref.id, { session: page?.session, isCancelled: () => editor !== editorGeneration });
        } while (page.hasMore);
        const edges = window.NRCEdges.getEdgesForEntity(0n, 1, ref.id).filter(edge => isCompanyLink(edge, ref.companyId, ref.id));
        await Promise.all(edges.map(edge => rpc(options => window.NRCEdges.sendDeleteEdge(0n, edge.edgeId, options))));
        if (editor !== editorGeneration) return;
        editorBusy = false;
        if (inspection?.companyId === ref.companyId) inspection.companyId = null;
        // Keep any unsaved fields intact after removing only the association.
        if (ref.type === "contact") loadContactCompanies(inspection);
        else {
          el("customerUnlink")?.previousElementSibling.remove();
          el("customerUnlink")?.remove();
        }
        el("customerEditorError").textContent = "";
        updateEditorState();
        if (active()) loadRelationships(true);
      } else {
        await rpc(options => window.NRCAssets.sendDeleteAsset(0n, ref.id, options));
        window.NRCInspector.entityDeleted(ref);
      }
    } catch (failure) {
      if (editor !== editorGeneration) return;
      editorBusy = false;
      el("customerEditorError").textContent = failure.message;
      updateEditorState();
    }
  }

  function write(asset, type, meta, body, convId, companyId = null) {
    return new Promise((resolve, reject) => {
      const preview = JSON.stringify(meta);
      if (new TextEncoder().encode(preview).length > window.NRCAssets.MAX_PREVIEW_LENGTH) {
        reject(new Error("Metadata exceeds 4 KB. Shorten the fields."));
        return;
      }
      const options = { onSuccess: resolve, onError: detail => reject(new Error(detail.message || "Save failed. Reconnect and refresh before retrying.")) };
      if (!asset && type !== TYPES.company) {
        const id = window.NRCTransactions.sendCreateLinkedAsset(convId, type, preview, body, companyId, {
          ...options,
          onSuccess() {
            // Transaction broadcasts exclude the sender. Reload authoritative
            // assets and edges instead of constructing partial cache objects.
            if (convId === room) reload();
            resolve();
          },
        });
        if (!id) reject(new Error("Not connected. Nothing was sent."));
        return;
      }
      const id = asset ? window.NRCAssets.sendUpdateAsset(convId, asset.assetId, preview, body, type, 0, options) :
        window.NRCAssets.sendCreateAsset(convId, type, 0, 0n, preview, body, 0, options);
      if (!id) reject(new Error("Not connected. Nothing was sent."));
    });
  }

  async function saveRecord(asset, meta, body) {
    if (!enabled || !connected()) return;
    el("customerArchive").disabled = true;
    const editRoom = room;
    try { await write(asset, asset.assetType, meta, body, editRoom); }
    catch (failure) { if (editRoom === room) error = failure.message; }
    scheduleRender();
  }

  function init() {
    el("customersBtn").onclick = () => { if (enabled) window.NRCViewManager.setActiveView("customers"); };
    el("customerNew").onclick = () => edit("company");
    el("customersRefresh").onclick = reload;
    el("customersSearch").oninput = queueSearch;
    el("customersArchived").onchange = queueSearch;
    el("customersPager").addEventListener("nrc:load-more", () => loadCompanies(companyIds.size === 0));
    window.matchMedia?.("(max-width: 768px)").addEventListener("change", scheduleRender);
    document.addEventListener("keydown", handleKeyboardNavigation);
    document.addEventListener("nrc:link-picker-closed", scheduleRender);
    el("customersList").onclick = event => {
      const button = event.target.closest("[data-company]");
      if (button) selectCompany(button.dataset.company);
    };
    el("customerRecord").onclick = event => {
      const tab = event.target.closest("[data-customer-tab]");
      const page = event.target.closest("[data-page]");
      if (tab) {
        recordTab = tab.dataset.customerTab; recordQuery = "";
        render(); el("customerRecord").scrollTop = 0;
        el("customerRecord").querySelector(`nav [data-customer-tab="${recordTab}"]`)?.focus({ preventScroll: true });
        return;
      }
      if (page) {
        const [tab, direction] = page.dataset.page.split(":");
        recordPages[tab] = (recordPages[tab] || 0) + (direction === "next" ? 1 : -1);
        render(); el("customerRecord").scrollTop = 0;
        return;
      }
      const editButton = event.target.closest("[data-edit]");
      const contactButton = event.target.closest("[data-contact]");
      const activityButton = event.target.closest("[data-activity]");
      const target = event.target.closest("[data-target]");
      if (editButton) {
        const asset = records.get(BigInt(editButton.dataset.edit));
        edit(asset.assetType === TYPES.company ? "company" : "contact", asset);
      } else if (contactButton) openRecord("contact", contactButton.dataset.contact, { companyId: selected });
      else if (activityButton) openRecord("activity", activityButton.dataset.activity, { companyId: selected });
      else if (target) window.NRCLinksUI.navigateToTarget(room, Number(target.dataset.targetType), BigInt(target.dataset.target));
    };
    window.NRCEdges.addEdgeChangeListener(onEdgeChanged);
    refreshAccess();
  }

  window.NRCCustomers = {
    isEnabled: () => enabled, reload, refreshAccess, onRoomSwitch, onDisconnect,
    onAssetChanged, onAssetDeleted, metadata, isCompanyLink,
    openRecord, showInspector, clearSelection, confirmDiscardEdits,
    openCompany(asset) {
      if (!enabled) return;
      window.NRCViewManager.setActiveView("customers");
      records.set(asset.assetId, asset);
      selectCompany(asset.assetId);
    },
  };
  document.addEventListener("DOMContentLoaded", init);
})();
