// Read-only durable change register. No record snapshots or mutation operations.
window.NRCHistory = (() => {
  let kind = 0, entityId = "0", events = [], before = "0", pending = null, timer;
  let mode = "offline";
  const active = () => window.NRCViewManager?.getActiveView() === "history";
  const ready = () => typeof serverReady !== "undefined" && serverReady && ws?.readyState === WebSocket.OPEN;
  const escape = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const assetNames = { 1: "Comment", 2: "Document", 3: "File", 4: "Agenda", 5: "Note", 6: "Reminder", 7: "Room", 8: "Company", 9: "Contact", 10: "Activity", 11: "Slice", 12: "Appointment" };
  const inspectorTypes = { 3: "file", 5: "note", 6: "reminder", 8: "company", 9: "contact", 10: "activity", 11: "slice", 12: "appointment" };
  const fieldNames = { title: "Title", description: "Description", status: "Status", order_index: "Position", assignee: "Assignee", priority: "Priority", color: "Color", external_ref: "External reference", due_at: "Due date", blocked_by: "Dependency", completed_at: "Completion date", completed_by: "Completed by", project: "Project", attachments: "Attachments", asset_type: "Record type", parent_type: "Parent record", parent_id: "Parent record", owner: "Owner", preview: "Details", payload: "Content", source: "Linked record", target: "Linked record", relation: "Relationship" };
  function record(kind, id, label, assetType, available) {
    const type = kind === "task" ? "Task" : assetNames[assetType] || "Record";
    const identity = `${type} #${id}`;
    const name = label || identity;
    const title = available === true
      ? `<button type="button" class="inline-field-value" data-history-record="${escape(kind)}" data-history-id="${escape(id)}" data-history-asset-type="${escape(assetType || 0)}" aria-label="Open ${escape(type.toLowerCase())}: ${escape(name)}">${escape(name)}</button>`
      : `<strong>${escape(name)}</strong>`;
    return { title, metadata: `${escape(label ? identity : type)}${available === true ? "" : " · No longer available"}` };
  }
  function change(event) {
    if (event.entityType === "edge") {
      const source = record(event.sourceType, event.sourceId, event.sourceLabel, event.sourceAssetType, event.sourceAvailable);
      const target = record(event.targetType, event.targetId, event.targetLabel, event.targetAssetType, event.targetAvailable);
      return `${event.action === "deleted" ? "Unlinked" : "Linked"} ${source.title}<br>${event.action === "deleted" ? "from" : "to"} ${target.title}<br><small>${source.metadata} · ${target.metadata}</small>`;
    }
    const fields = [...new Set(event.fields.map(field => fieldNames[field] || field.replaceAll("_", " ")))];
    const action = event.action === "created" ? "Created" : event.action === "deleted" ? "Deleted" : `Changed ${fields.join(", ") || "details"} on`;
    const entity = record(event.entityType, event.entityId, event.entityLabel, event.assetType, event.entityAvailable);
    return `${escape(action)}<br>${entity.title}<br><small>${entity.metadata}</small>`;
  }
  function cancel() { clearTimeout(timer); pending = null; }
  function timeline() {
    let day = "", html = "";
    for (const event of events) {
      const date = new Date(Number(BigInt(event.timestamp) / 1000000n));
      const key = `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
      if (key !== day) {
        if (day) html += "</ol></section>";
        day = key;
        html += `<section class="history-day"><h2>${escape(date.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" }))}</h2><ol class="customer-history-timeline history-events">`;
      }
      const icon = event.entityType === "edge" ? '<path d="m10 13 4-4m-6 2-2 2a3 3 0 0 0 4 4l2-2m0-6 2-2a3 3 0 0 1 4 4l-2 2"/>' : event.action === "deleted" ? '<path d="M5 7h14M9 7V4h6v3M7 7l1 13h8l1-13M10 10v7m4-7v7"/>' : event.action === "created" ? '<path d="M12 5v14M5 12h14"/>' : '<path d="m5 15-1 5 5-1L20 8l-4-4Zm9-9 4 4"/>';
      html += `<li class="customer-event history-event"><div class="history-meta"><time datetime="${date.toISOString()}" title="${escape(date.toLocaleString())}">${escape(date.toLocaleTimeString())}</time><span tabindex="0" title="${escape(event.actorId)}" aria-label="${escape(event.actorName)} (${escape(event.actorId)})">${escape(event.actorName || event.actorId)}</span></div><svg class="history-icon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${icon}</svg><div class="history-change">${change(event)}</div></li>`;
    }
    return html + "</ol></section>";
  }
  function render() {
    const body = document.getElementById("historyBody");
    if (!body) return;
    const selected = events.find(event => event.entityId === entityId && event.entityType === (kind === 1 ? "task" : "asset"));
    document.getElementById("historyScope").textContent = kind ? `${selected?.entityLabel || (kind === 1 ? "Task" : assetNames[selected?.assetType] || "Record")} #${entityId}` : "WORKSPACE";
    document.getElementById("historyClear").hidden = !kind;
    document.getElementById("historyStatus").textContent = mode === "loading" ? "LOADING HISTORY…" : mode === "offline" ? "OFFLINE · RECONNECT TO READ HISTORY" : mode === "error" ? "HISTORY READ FAILED · RETRY" : `${events.length} EVENTS · NEWEST FIRST · ${kind ? "INCLUDING RELATED LINKS" : "INCLUDING DELETED RECORDS"}`;
    body.setAttribute("aria-busy", String(mode === "loading"));
    body.innerHTML = events.length ? timeline() : mode === "ready" ? '<p class="overview-note">NO HISTORY IN THIS SCOPE</p>' : "";
    document.getElementById("historyMore").hidden = before === "0";
    document.getElementById("historyMore").disabled = mode !== "ready" || events.length >= 1000;
    document.getElementById("historyRefresh").disabled = mode === "loading" || !ready();
  }
  function load(more = false) {
    if (more && (pending || before === "0" || events.length >= 1000)) return;
    cancel();
    if (!more) { events = []; before = "0"; }
    if (!ready()) { mode = "offline"; render(); return; }
    const correlation = getRpcCorrelationId();
    pending = { correlation, cursor: more ? before : "0", limit: Math.min(50, 1000 - events.length) };
    const view = new DataView(new ArrayBuffer(33));
    view.setUint16(0, Opcode.C_ListHistory); view.setBigUint64(2, 0n);
    view.setUint8(10, kind); view.setBigUint64(11, BigInt(entityId));
    view.setBigUint64(19, BigInt(pending.cursor)); view.setUint16(27, pending.limit); view.setUint32(29, correlation);
    mode = "loading"; render();
    timer = setTimeout(() => { pending = null; mode = "error"; render(); }, 15000);
    sendPacket(view.buffer);
  }
  function handlePage(view) {
    if (view.byteLength < 6 || view.getUint32(2) !== pending?.correlation) return;
    const { cursor, limit } = pending;
    cancel();
    try {
      const page = JSON.parse(new TextDecoder().decode(new Uint8Array(view.buffer, view.byteOffset + 6, view.byteLength - 6)));
      const decimal = value => typeof value === "string" && /^\d+$/.test(value) && BigInt(value) <= 18446744073709551615n;
      if (page.error || !Array.isArray(page.events) || page.events.length > limit || !decimal(page.nextBefore)) throw Error();
      let previous = cursor === "0" ? null : BigInt(cursor);
      for (const event of page.events) {
        if (!decimal(event.id) || !decimal(event.entityId) || !decimal(event.timestamp) || !["task", "asset", "edge"].includes(event.entityType) || !["created", "updated", "deleted"].includes(event.action) || !Array.isArray(event.fields) || !event.fields.every(field => typeof field === "string") || (previous !== null && BigInt(event.id) >= previous)) throw Error();
        previous = BigInt(event.id);
      }
      if (page.nextBefore !== "0" && (!page.events.length || BigInt(page.nextBefore) > previous)) throw Error();
      events.push(...page.events); before = page.nextBefore; mode = "ready";
    } catch { mode = "error"; }
    render();
  }
  function open(type = 0, id = "0") {
    kind = type; entityId = String(id); cancel(); events = []; before = "0";
    if (active()) load(); else window.NRCViewManager.setActiveView("history");
  }
  function init() {
    document.getElementById("historyBtn").onclick = () => open();
    document.getElementById("historyClear").onclick = () => open();
    document.getElementById("historyRefresh").onclick = () => load();
    document.getElementById("historyMore").onclick = () => load(true);
    document.addEventListener("click", event => {
      const button = event.target.closest("[data-history-kind]");
      if (button) open(Number(button.dataset.historyKind), button.dataset.historyId);
      const target = event.target.closest("[data-history-record]");
      if (target && ready()) {
        const assetType = Number(target.dataset.historyAssetType);
        window.NRCInspector.openEntity({ roomId: 0n, id: BigInt(target.dataset.historyId), type: target.dataset.historyRecord === "task" ? "task" : inspectorTypes[assetType] || "asset", assetType });
      }
    });
  }
  return { init, open, handlePage, refresh: () => { if (active()) load(); },
    onViewChanged: view => { cancel(); if (view === "history") load(); },
    disconnect: () => { cancel(); events = []; before = "0"; mode = "offline"; render(); } };
})();
