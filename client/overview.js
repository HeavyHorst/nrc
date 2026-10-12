// Workspace facts, not a second personal Attention queue.
window.NRCOverview = (() => {
  const labels = ["BACKLOG", "TODO", "IN PROGRESS", "DONE"];
  const colors = ["backlog", "todo", "inprogress", "done"];
  const pending = new Map();
  let generation = 0, timer = null, snapshot = null, mode = "offline";
  const el = id => document.getElementById(id);
  const active = () => window.NRCViewManager?.getActiveView() === "overview";
  const ready = () => typeof serverReady !== "undefined" && serverReady && ws?.readyState === WebSocket.OPEN;
  function query() {
    const id = getRpcCorrelationId();
    return new Promise(resolve => {
      const timeout = setTimeout(() => { pending.delete(id); resolve(null); }, 15000);
      pending.set(id, { resolve, timeout });
      const view = new DataView(new ArrayBuffer(14));
      view.setUint16(0, Opcode.C_GetWorkspaceOverview);
      view.setBigUint64(2, 0n); // Canonical workspace data scope.
      view.setUint32(10, id);
      sendPacket(view.buffer);
    });
  }
  function handlePage(view) {
    if (view.byteLength < 105) return;
    const id = view.getUint32(view.byteLength - 4, false);
    const request = pending.get(id);
    if (!request) return;
    pending.delete(id); clearTimeout(request.timeout);
    if (view.getBigUint64(2) !== 0n || view.getUint8(10) !== 1 || view.byteLength !== 105 + view.getUint16(99)) {
      request.resolve(null); return;
    }
    let offset = 19; // opcode, scope, success, server sampling time
    const counts = n => Array.from({ length: n }, () => { const value = view.getUint32(offset); offset += 4; return value; });
    const status = counts(4), [assignedTasks, unassignedTasks, openSlices] = counts(3);
    request.resolve({ counts: status, assignedTasks, unassignedTasks, openSlices,
      sizes: counts(5), blockages: counts(3), ages: counts(5) });
  }
  function cancel() {
    generation++;
    clearTimeout(timer);
    for (const request of pending.values()) { clearTimeout(request.timeout); request.resolve(null); }
    pending.clear();
  }
  async function refresh() {
    if (!active()) return;
    cancel();
    if (!ready()) { mode = "offline"; render(); return; }
    const current = generation;
    mode = "loading"; render();
    const result = await query();
    if (current !== generation) return;
    if (result === null) mode = "error";
    else { snapshot = result; mode = "ready"; }
    render();
  }
  function refreshSoon() {
    if (!active()) return;
    clearTimeout(timer); timer = setTimeout(refresh, 150);
  }
  function segments(counts, total, interactive = false) {
    return counts.map((value, i) => value ? `<${interactive ? "button type=\"button\"" : "span"} class="overview-segment overview-${colors[i]}" style="flex-grow:${value}" ${interactive ? `data-overview-status="${i}"` : ""} title="${labels[i]}: ${value}" aria-label="${labels[i]}: ${value} of ${total}">${value}</${interactive ? "button" : "span"}>` : "").join("");
  }
  function section(title, content) {
    return `<section class="overview-chart"><header class="panel-header"><div><span>${title}</span></div></header>${content}</section>`;
  }
  function distribution(title, labels, values, total) {
    return section(title, `<div class="overview-distribution">${labels.map((label, i) => {
      const share = total ? values[i] / total * 100 : 0;
      return `<div class="overview-bucket"><span>${label}</span><span class="overview-bucket-track"><span style="width:${share}%"></span></span><strong>${values[i]}</strong><small>${Math.round(share)}%</small></div>`;
    }).join("")}</div><p class="overview-note">${total} OPEN SLICES · SHARE OF SLICES</p>`);
  }
  function render() {
    if (!active() || !el("overviewBody")) return;
    el("overviewStatus").textContent = mode === "loading" ? "LOADING WORKSPACE OVERVIEW…" : mode === "error" ?
      "READ FAILED · RETRY · LAST COMPLETE RESULTS RETAINED" : mode === "offline" ? "OFFLINE · RECONNECT TO REFRESH" : "";
    el("overviewStatus").hidden = mode === "ready";
    el("overviewBody").setAttribute("aria-busy", String(mode === "loading"));
    if (!snapshot) { el("overviewBody").innerHTML = ""; return; }
    if (mode === "loading" || mode === "error") return;
    const { counts, sizes, blockages, ages, openSlices, assignedTasks, unassignedTasks } = snapshot;
    const total = counts.reduce((a, b) => a + b, 0);
    const legend = `<div class="overview-legend">${labels.map((label, i) => `<span><i class="overview-${colors[i]}"></i>${label}</span>`).join("")}</div>`;
    el("overviewBody").innerHTML = section(`WORKSPACE STATUS <small>${total} UNIQUE TASKS</small>`,
      total ? `<div class="overview-bar overview-bar--hero">${segments(counts, total, true)}</div>${legend}` : '<p class="overview-note">NO TASKS IN THIS WORKSPACE</p>') +
      `<div class="overview-grid">` +
      distribution("WORK SIZE <small>TASKS PER SLICE</small>", ["0 TASKS", "1–5 TASKS", "6–15 TASKS", "16–30 TASKS", "31+ TASKS"], sizes, openSlices) +
      distribution("BLOCKAGES <small>BLOCKED TASKS PER SLICE</small>", ["0 BLOCKED", "1–2 BLOCKED", "3+ BLOCKED"], blockages, openSlices) +
      distribution("OLDEST OPEN TASK <small>AGE SINCE CREATION</small>", ["≤7 DAYS", "8–30 DAYS", "31–90 DAYS", "91+ DAYS", "NO OPEN TASKS"], ages, openSlices) + `</div>` +
      section(`SLICE COVERAGE <small>${assignedTasks + unassignedTasks} UNIQUE TASKS</small>`,
        `<div class="overview-bar overview-bar--coverage">${assignedTasks ? `<span class="overview-segment overview-backlog" style="flex-grow:${assignedTasks}" title="In at least one slice: ${assignedTasks}" aria-label="In at least one slice: ${assignedTasks}">${assignedTasks}</span>` : ""}${unassignedTasks ? `<span class="overview-segment overview-inprogress" style="flex-grow:${unassignedTasks}" title="Without slice: ${unassignedTasks}" aria-label="Without slice: ${unassignedTasks}">${unassignedTasks}</span>` : ""}</div><div class="overview-legend"><span><i class="overview-backlog"></i>IN AT LEAST ONE SLICE</span><span><i class="overview-inprogress"></i>WITHOUT SLICE</span></div>`) +
      `<details class="overview-explanation"><summary>HOW TO READ THIS OVERVIEW</summary><p>Workspace status and coverage count each task once. Each distribution counts every open slice once, including empty slices. Work size includes done tasks; slice memberships may overlap. Coverage includes closed slices. Blocked is a flag, not a status. Age uses completed days since the oldest open task was created, not time in status. Without slice means membership, not assignee.</p></details>`;
  }
  function init() {
    el("overviewBtn").addEventListener("click", () => window.NRCViewManager.setActiveView("overview"));
    el("overviewRefresh").addEventListener("click", refresh);
    el("overviewBody").addEventListener("click", event => {
      const status = event.target.closest("[data-overview-status]");
      if (!status) return;
      window.NRCTasks.showKanban(); setTaskGrouping("flat"); resetFilters();
      const filter = el("filterStatus"); filter.value = status.dataset.overviewStatus;
      filter.dispatchEvent(new Event("change", { bubbles: true }));
    });
    for (const event of ["nrc:task-changed", "nrc:asset-created", "nrc:asset-updated", "nrc:asset-deleted", "nrc:slices-changed"]) document.addEventListener(event, refreshSoon);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) refreshSoon(); });
  }
  return { init, refresh, refreshSoon, handlePage, render,
    disconnect() { cancel(); snapshot = null; mode = "offline"; render(); },
    onViewChanged(view) { if (view === "overview") refresh(); else cancel(); } };
})();
