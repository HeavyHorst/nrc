// Browser-open notifications for the current nickname's workspace appointments.
// Read only the next 15 minutes through the calendar index, independently of the
// visible calendar. Suspended tabs catch up only while the start is still ahead.
window.NRCAppointmentNotify = (() => {
  const LEAD = 15n * 60n * 1000000000n;
  let pending = null, scan = null, generation = 0, timer = null;
  const memory = new Map();
  const scope = () => JSON.stringify([currentWorkspaceId, myNickname]);
  const preferenceKey = () => `nrc-appointment-notifications:${scope()}`;
  const now = () => BigInt(Date.now()) * 1000000n;
  const ready = () => typeof serverReady !== "undefined" && serverReady &&
    typeof ws !== "undefined" && ws?.readyState === WebSocket.OPEN && !!myNickname;
  function mode() {
    try { return localStorage.getItem(preferenceKey()) === "off" ? "off" : "mine"; }
    catch { return "mine"; }
  }
  function enabled() {
    return ready() && mode() === "mine" && typeof Notification !== "undefined" && Notification.permission === "granted";
  }
  function disconnect() {
    generation++;
    if (pending) clearTimeout(pending.timeout);
    pending = null; scan = null;
  }
  function requestPage(cursor = null) {
    const id = getRpcCorrelationId();
    pending = { id, cursor, timeout: setTimeout(disconnect, 15000) };
    sendPacket(window.NRCCalendar.encodeRequest(scan.range, scan.person, "", cursor, id));
  }
  function refresh() {
    if (!enabled() || pending) return;
    const start = now();
    scan = { range: { start, end: start + LEAD + 1n }, person: myNickname, scope: scope(), generation: ++generation, rows: [] };
    requestPage();
  }
  function restart() { disconnect(); refresh(); }
  async function deliver(row, batch) {
    const key = `nrc-appointment-delivered:${batch.scope}`;
    const attempt = () => {
      const time = now();
      if (batch.generation !== generation || batch.scope !== scope() || !enabled() ||
          row.actualStartAt <= time || row.actualStartAt > time + LEAD) return;
      let sent = memory.get(key) || {};
      try {
        const stored = JSON.parse(localStorage.getItem(key) || "{}");
        if (stored && typeof stored === "object" && !Array.isArray(stored)) sent = { ...sent, ...stored };
      } catch { /* Private browsing can deny storage; retain this tab's ledger. */ }
      for (const [id, start] of Object.entries(sent)) {
        try { if (BigInt(start) <= time) delete sent[id]; } catch { delete sent[id]; }
      }
      const identity = `${row.id}:${row.actualStartAt}`;
      if (sent[identity]) return;
      const minutes = Math.ceil(Number(row.actualStartAt - time) / 60000000000);
      const startLabel = new Date(Number(row.actualStartAt / 1000000n)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
      try {
        const delivered = sendNotification(row.title, {
          body: `IN ${minutes} MIN · ${startLabel}${row.project ? ` · ${row.project}` : ""}`,
          tag: `${key}:${identity}`,
        }, () => {
          if (scope() !== batch.scope) return;
          window.focus();
          window.NRCInspector?.openEntity?.({ roomId: 0n, type: "appointment", id: row.id });
        });
        if (!delivered) return;
      } catch { return; } // Unsupported Notification constructors must not consume the alert.
      sent[identity] = row.actualStartAt.toString();
      memory.set(key, sent);
      try { localStorage.setItem(key, JSON.stringify(sent)); } catch { /* Session-only fallback. */ }
    };
    // The shared ledger plus an origin lock prevents duplicate popups in tabs.
    // Older browsers without Web Locks retain best-effort storage/tag deduplication.
    if (window.navigator?.locks) await window.navigator.locks.request(key, attempt);
    else attempt();
  }
  function handlePage(view) {
    if (!pending || view.getUint32(view.byteLength - 4) !== pending.id) return;
    clearTimeout(pending.timeout);
    const previous = pending.cursor;
    pending = null;
    if (!enabled() || scan.scope !== scope()) { disconnect(); return; }
    let page;
    try { page = window.NRCCalendar.decodePage(view); }
    catch { disconnect(); return; }
    scan.rows.push(...page.rows.filter(row => row.kind === "appointment" && row.assignee === scan.person));
    if (page.more) {
      const c = page.cursor;
      if (!page.rows.length || previous && (c.at < previous.at || c.at === previous.at &&
          (c.kind < previous.kind || c.kind === previous.kind && c.id <= previous.id))) { disconnect(); return; }
      requestPage(c);
      return;
    }
    const batch = scan;
    scan = null;
    for (const row of batch.rows) void deliver(row, batch).catch(() => {});
  }
  async function setMode(value) {
    const next = value === "off" ? "off" : "mine";
    try { localStorage.setItem(preferenceKey(), next); }
    catch { logMessage("Error", "COULD NOT SAVE NOTIFICATION PREFERENCE"); return; }
    disconnect();
    if (next === "mine" && typeof Notification !== "undefined" && Notification.permission === "default") {
      await Notification.requestPermission();
      if (typeof updateNotificationStatus === "function") updateNotificationStatus();
    }
    refresh();
  }
  function init() {
    if (timer !== null) return;
    timer = setInterval(refresh, 30000);
    window.addEventListener("focus", restart);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) restart(); });
    for (const event of ["nrc:asset-created", "nrc:asset-updated", "nrc:asset-deleted"]) {
      document.addEventListener(event, e => {
        if (!e.detail?.asset || e.detail.asset.assetType === 12) restart();
      });
    }
    refresh();
  }
  return { init, refresh, restart, disconnect, handlePage, mode, setMode };
})();
