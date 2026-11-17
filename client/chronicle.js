// Read-only AI explanations and coverage; never exposes service/raw operations.
window.NRCChronicle = (() => {
  const MAX = 1000;
  let kind = 0, noteId = "0", revision = 0, mode = "offline", notice = "";
  let systemOpen = false;
  let status = null, entries = [], gaps = [], cursor = "0", gapCursor = "0", more = false, moreGaps = false;
  const requests = new Map();
  const active = () => window.NRCHistory?.isChronicle() && window.NRCViewManager?.getActiveView() === "history";
  const ready = () => typeof serverReady !== "undefined" && serverReady && ws?.readyState === WebSocket.OPEN;
  const escape = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const decimal = s => typeof s === "string" && /^(0|[1-9]\d{0,19})$/.test(s) && BigInt(s) <= 18446744073709551615n;
  const positive = s => decimal(s) && s !== "0";
  const count = n => Number.isSafeInteger(n) && n >= 0;
  const time = s => {
    if (!positive(s) || BigInt(s) > 9223372036854775807n) throw Error("Invalid chronicle time");
    return new Date(Number(BigInt(s) / 1000000n)).toLocaleString();
  };
  function cancel() {
    revision++;
    for (const q of requests.values()) { clearTimeout(q.timer); q.resolve(null); }
    requests.clear();
  }
  function clear() { entries = []; gaps = []; cursor = gapCursor = "0"; more = moreGaps = false; status = null; }
  function request(op, options = {}) {
    const correlation = getRpcCorrelationId();
    const data = new TextEncoder().encode(JSON.stringify({ op, ...(kind === 2 ? { note_id: noteId } : {}), ...options }));
    const view = new DataView(new ArrayBuffer(6 + data.length));
    view.setUint16(0, Opcode.C_Chronicle); view.setUint32(2 + data.length, correlation);
    new Uint8Array(view.buffer, 2, data.length).set(data);
    return new Promise(resolve => {
      const timer = setTimeout(() => { requests.delete(correlation); resolve(null); }, 15000);
      requests.set(correlation, { resolve, timer });
      sendPacket(view.buffer, correlation);
    });
  }
  function handlePage(view) {
    const decoded = window.NRCFrames.decodeChronicleResponse(view);
    const q = requests.get(decoded.correlationId);
    if (!q) return;
    clearTimeout(q.timer); requests.delete(decoded.correlationId); q.resolve(decoded.page);
  }
  function handleError(correlation) {
    const q = requests.get(correlation);
    if (!q) return false;
    clearTimeout(q.timer); requests.delete(correlation); q.resolve(null); return true;
  }
  function validatePage(page, isGap, previous) {
    const rows = isGap ? page?.gaps : page?.entries;
    if (page?.status !== "ok" || !Array.isArray(rows) || rows.length > 16 || typeof page.more !== "boolean" || !decimal(page.cursor)) throw Error("Chronicle read failed");
    for (const row of rows) {
      const id = isGap ? row.first_source : row.generation;
      if (!positive(id) || BigInt(id) <= BigInt(previous) || !positive(row.note_id) || typeof row.source_available !== "boolean") throw Error("Invalid chronicle identity");
      if (row.note_title !== undefined && (typeof row.note_title !== "string" || new TextEncoder().encode(row.note_title).length > 256)) throw Error("Invalid note title");
      if (kind === 2 && row.note_id !== noteId) throw Error("Wrong note scope");
      previous = id;
      time(row.first_at); time(row.last_at);
      if (BigInt(row.first_at) > BigInt(row.last_at)) throw Error("Invalid change interval");
      if (isGap) {
        if (!positive(row.last_source) || BigInt(row.last_source) < BigInt(id) || !count(row.input_count) || row.input_count < 1 || typeof row.reason !== "string" || row.reason.length > 64) throw Error("Invalid coverage gap");
      } else {
        time(row.created_at);
        if (typeof row.summary !== "string" || new TextEncoder().encode(row.summary).length > 4096 || !row.summary.trim() || !Array.isArray(row.sources) || row.sources.length < 1 || row.sources.length > 32) throw Error("Invalid chronicle result");
        let source = 0n;
        for (const id of row.sources) { if (!positive(id) || BigInt(id) <= source) throw Error("Invalid source order"); source = BigInt(id); }
        if (![row.model, row.prompt_version, row.schema_version].every(s => typeof s === "string" && s.length <= 128)) throw Error("Invalid provenance");
      }
    }
    if (rows.length && page.cursor !== previous || page.more && !rows.length) throw Error("Invalid chronicle cursor");
    return rows;
  }
  function identity(row) {
    const name = escape(row.note_title?.trim() || "Untitled note");
    return row.source_available
      ? `<button type="button" class="inline-field-value" data-history-record="asset" data-history-id="${row.note_id}" data-history-asset-type="5">${name}</button>`
      : `<strong>${name}</strong> · SOURCE NO LONGER AVAILABLE`;
  }
  function render() {
    if (!active()) return;
    const busy = mode === "loading" || mode === "deleting";
    const body = document.getElementById("historyBody");
    systemOpen = body.querySelector?.("[data-chronicle-system]")?.open ?? systemOpen;
    document.getElementById("historyScope").textContent = kind ? `RECORD #${noteId} · NOTES ONLY` : "WORKSPACE · NOTES ONLY";
    document.getElementById("historyClear").hidden = !kind;
    document.getElementById("historyStatus").textContent = mode === "offline" ? "OFFLINE · RECONNECT TO READ AI CHRONICLE" : mode === "error" ? "AI CHRONICLE READ FAILED · REFRESH / RETRY" : mode === "loading" ? "LOADING AI CHRONICLE…" : mode === "deleting" ? "DELETING AI CHRONICLE…" : `${status?.enabled ? "CAPTURE ENABLED" : "CAPTURE DISABLED"} · ${entries.length} ENTRIES LOADED · OLDEST FIRST`;
    body.setAttribute("aria-busy", String(busy));
    let html = '<div class="chronicle-register">';
    if (notice) html += `<p class="chronicle-notice" role="status">${escape(notice)}</p>`;
    if (kind === 1) html += '<p class="overview-note">AI CHRONICLE COVERS NOTES ONLY. TASK CHANGES REMAIN IN TECHNICAL HISTORY.</p>';
    if (status) {
      html += `<details class="chronicle-details" data-chronicle-system ${systemOpen ? "open" : ""}><summary>SYSTEM DETAILS${status.pending ? ` <span>${status.pending} PENDING</span>` : ""}${status.failed || status.gap_count || status.expired ? ` <span class="chronicle-warning">${status.failed} FAILED / PARKED · ${status.gap_count} LOST INPUTS · ${status.expired} EXPIRED</span>` : ""}</summary><div class="chronicle-system"><p>${status.pending} PENDING · ${status.processing} PROCESSING · ${status.failed} FAILED / PARKED</p><p>${status.acknowledged} NO-CHANGE ACKS · ${status.gap_count} LOST INPUTS · ${status.expired} EXPIRED</p><p>${status.calls} CALLS TODAY · ${status.input_tokens}/8,000,000 INPUT · ${status.output_tokens}/500,000 OUTPUT TOKENS</p><p>Workspace token budgets reset at midnight UTC. Confirmed responses count actual tokens; pending or unknown outcomes retain their reservation. No daily call limit.</p><p>Processing and failed are subsets of pending. No-change acknowledgements are successful processing, not gaps. Expired inputs are unavailable even before cleanup.</p><p>Capture enabled does not confirm provider availability. No backfill before opt-in; use REFRESH to check progress.</p></div></details>`;
      if (!status.enabled) html += '<p class="chronicle-notice">Processing is disabled. Retained explanations remain readable; re-enabling does not revive old claims.</p>';
      if (kind === 2 && status.can_delete) html += `<div><button type="button" class="btn btn--danger" data-chronicle-delete="${noteId}" ${busy || !ready() ? "disabled" : ""}>DELETE AI CHRONICLE FOR THIS NOTE</button></div>`;
    }
    html += `<section class="chronicle-feed" aria-label="AI entries"><header class="panel-header"><div><span>AI ENTRIES <small>(${entries.length} LOADED)</small></span><span>OLDEST GENERATION FIRST</span></div></header>`;
    if (!entries.length && mode === "ready" && kind !== 1) html += '<p class="chronicle-empty">NO AI ENTRIES IN THIS SCOPE. This does not mean every change was covered.</p>';
    html += '<ol class="chronicle-entries">';
    for (const row of entries) {
      html += `<li class="chronicle-entry"><div class="chronicle-content"><div class="chronicle-identity"><span>CHANGED ${escape(time(row.last_at))}</span><span>${identity(row)}</span></div><p class="chronicle-summary">${escape(row.summary)}</p><details class="chronicle-details"><summary>DETAILS</summary><div class="chronicle-system"><p>NOTE #${row.note_id}<br>CHANGES ${escape(time(row.first_at))} – ${escape(time(row.last_at))}<br>CREATED ${escape(time(row.created_at))}</p><p>SOURCES ${row.sources.join(", ")}<br>${escape(row.model)} · ${escape(row.prompt_version)} · ${escape(row.schema_version)}</p><div class="chronicle-actions"><button class="btn" type="button" data-chronicle-technical="${row.note_id}">TECHNICAL HISTORY</button>${status?.can_delete && kind !== 2 ? ` <button class="btn btn--danger" type="button" data-chronicle-delete="${row.note_id}" ${busy ? "disabled" : ""}>DELETE NOTE’S AI CHRONICLE</button>` : ""}</div></div></details></div></li>`;
    }
    html += `</ol>${pager("entries", entries.length, more, busy)}</section><section class="chronicle-feed" aria-label="Coverage gaps"><header class="panel-header"><div><span>COVERAGE GAPS <small>(${gaps.length} LOADED)</small></span><span>OLDEST SOURCE FIRST</span></div></header>`;
    if (!gaps.length && mode === "ready" && kind !== 1) html += '<p class="chronicle-empty">NO RECORDED GAPS IN THE LOADED PAGE</p>';
    html += '<ol class="chronicle-entries">';
    for (const row of gaps) html += `<li class="chronicle-entry chronicle-gap"><div class="chronicle-content"><div class="chronicle-identity"><span>CHANGED ${escape(time(row.last_at))}</span><span>${identity(row)}</span></div><p class="chronicle-gap-reason chronicle-warning">COVERAGE GAP · ${row.input_count} LOST INPUTS · ${escape(row.reason === "ttl" ? "TTL EXPIRED" : row.reason)}</p><details class="chronicle-details"><summary>DETAILS</summary><p class="chronicle-meta">NOTE #${row.note_id}<br>CHANGES ${escape(time(row.first_at))} – ${escape(time(row.last_at))}<br>SOURCE RANGE ${row.first_source} – ${row.last_source}</p></details></div></li>`;
    body.innerHTML = html + `</ol>${pager("gaps", gaps.length, moreGaps, busy)}</section></div>`;
    document.getElementById("historyMore").hidden = true;
    document.getElementById("historyRefresh").disabled = busy || !ready();
  }
  function pager(section, loaded, hasMore, busy) {
    return `<footer class="chronicle-pager"><span>${loaded >= MAX ? "1,000 ROW DISPLAY LIMIT · REFRESH TO RESTART" : hasMore ? "MORE AVAILABLE" : "END OF LOADED PAGE"}</span>${hasMore ? `<button type="button" class="btn" data-chronicle-more="${section}" ${busy || mode !== "ready" || !ready() ? "disabled" : ""}>LOAD MORE ${section.toUpperCase()}</button>` : ""}</footer>`;
  }
  async function load(append = false, message = "", section = "both") {
    cancel(); const current = revision;
    if (!append) clear();
    notice = message;
    if (!ready()) { clear(); mode = "offline"; render(); return; }
    if (kind === 1) { mode = "ready"; render(); return; }
    mode = "loading"; render();
    try {
      const s = await request("status");
      if (current !== revision) return;
      if (s?.status !== "ok" || typeof s.enabled !== "boolean" || typeof s.can_delete !== "boolean" || ![s.pending, s.processing, s.failed, s.expired, s.acknowledged, s.gap_count, s.calls, s.input_tokens, s.output_tokens].every(count)) throw Error();
      status = s;
      const fetchEntries = section !== "gaps" && (!append || more) && entries.length < MAX;
      const fetchGaps = section !== "entries" && (!append || moreGaps) && gaps.length < MAX;
      const [h, g] = await Promise.all([fetchEntries ? request("history", { limit: Math.min(16, MAX - entries.length), cursor }) : null, fetchGaps ? request("gaps", { limit: Math.min(16, MAX - gaps.length), cursor: gapCursor }) : null]);
      if (current !== revision) return;
      // Validate both pages before publishing either, including on append.
      const nextEntries = fetchEntries ? validatePage(h, false, cursor) : [];
      const nextGaps = fetchGaps ? validatePage(g, true, gapCursor) : [];
      entries.push(...nextEntries); gaps.push(...nextGaps);
      if (h) { cursor = h.cursor; more = h.more && entries.length < MAX; }
      if (g) { gapCursor = g.cursor; moreGaps = g.more && gaps.length < MAX; }
      mode = "ready";
    } catch { clear(); mode = "error"; }
    render();
  }
  async function remove(id) {
    if (!status?.can_delete || !ready() || mode !== "ready" || !positive(id)) return;
    const current = revision;
    const approved = await window.NRCDialog.confirm(`Delete the entire AI chronicle for note #${id}? Existing AI texts and pending changes through the server's source watermark are removed or suppressed. The note and technical history stay unchanged. Later note changes may create new AI entries.`, { title: "DELETE AI CHRONICLE", confirmLabel: "Delete AI chronicle" });
    if (!approved || current !== revision || !active() || !ready()) return;
    mode = "deleting"; render();
    const result = await request("delete", { note_id: id });
    if (current !== revision) return;
    if (result?.status === "deleted" && decimal(result.deleted_through)) {
      await load(false, `AI chronicle deleted through source ${result.deleted_through}. Later changes may create new entries.`);
    } else {
      clear(); mode = "error";
      notice = result?.status === "forbidden" ? "Deletion is not permitted for this authenticated identity." : "Deletion outcome not confirmed. Refresh to reconcile; the delete request was not retried.";
      render();
    }
  }
  function init() {
    document.addEventListener("click", event => {
      const moreButton = event.target.closest("[data-chronicle-more]");
      if (moreButton && mode === "ready") load(true, "", moreButton.dataset.chronicleMore);
      const deleted = event.target.closest("[data-chronicle-delete]");
      if (deleted) remove(deleted.dataset.chronicleDelete);
      const technical = event.target.closest("[data-chronicle-technical]");
      if (technical) window.NRCHistory.openTechnical(2, technical.dataset.chronicleTechnical);
    });
  }
  return { init, handlePage, handleError, load, cancel,
    open(type, id) { kind = type; noteId = String(id); load(); },
    disconnect() { cancel(); clear(); kind = 0; noteId = "0"; mode = "offline"; notice = ""; render(); } };
})();
