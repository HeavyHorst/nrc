// Read acknowledgement is personal browser state, never ticket workflow state.
window.NRCRecordActivity = (() => {
  const memory = new Map(), watches = new Map();
  let generation = 0, taskRevision = 0, loading = false, again = false, suspended = false, comments = [], tasks = new Map();
  const identity = () => typeof currentWorkspaceId === 'string' && typeof myNickname === 'string' && myNickname
    ? JSON.stringify([currentWorkspaceId, myNickname]) : '';
  const keyFor = (kind, id) => identity() ? `nrc:record-read:${identity()}:${kind}:${id}` : '';
  function cursor(kind, id) {
    const key = keyFor(kind, id);
    if (!key) return 0n;
    let saved = 0n;
    try { saved = BigInt(window.localStorage.getItem(key) || '0'); } catch {}
    const local = memory.get(key) || 0n;
    return saved > local ? saved : local;
  }
  function changed(detail = { kind: 'task' }) {
    const badge = document.getElementById('tasksUnreadCount'), total = snapshot().length;
    if (badge) { badge.textContent = String(total); badge.hidden = !total; badge.setAttribute('aria-label', `${total} assigned tasks with unread comments`); }
    document.dispatchEvent(new CustomEvent('nrc:record-activity', { detail }));
  }
  function cursors(kind) {
    if (!identity()) return {};
    const prefix = `nrc:record-read:${identity()}:${kind}:`, ids = new Set();
    try {
      for (let i = 0; i < window.localStorage.length; i++) {
        const key = window.localStorage.key(i);
        if (key?.startsWith(prefix)) ids.add(key.slice(prefix.length));
      }
    } catch {}
    for (const key of memory.keys()) if (key.startsWith(prefix)) ids.add(key.slice(prefix.length));
    return Object.fromEntries([...ids].map(id => [id, String(cursor(kind, id))]));
  }
  function markRead(kind, id, through) {
    const key = keyFor(kind, id);
    if (!key || through <= cursor(kind, id)) return;
    memory.set(key, through);
    try { window.localStorage.setItem(key, String(through)); } catch {}
    changed({ kind, id: String(id) });
  }
  // A hidden inspector, collapsed messages or background tab is not a read.
  // Capture the exact last incoming record, not an ID looked up after scrolling.
  function observe(slot, node, kind, id, through) {
    watches.get(slot)?.stop();
    watches.delete(slot);
    if (!node || !through || typeof IntersectionObserver === 'undefined') return;
    const scope = identity();
    const end = document.createElement('span');
    end.setAttribute('aria-hidden', 'true');
    end.style.cssText = 'display:block;height:1px;pointer-events:none';
    node.appendChild(end);
    let visible = false;
    const acknowledge = () => {
      if (suspended || scope !== identity() || !visible || !node.isConnected || !node.getClientRects().length ||
          document.visibilityState !== 'visible' || !document.hasFocus()) return;
      markRead(kind, id, through);
    };
    const observer = new IntersectionObserver(entries => {
      visible = entries.some(entry => entry.target === end && entry.isIntersecting);
      acknowledge();
    });
    observer.observe(end);
    window.addEventListener('focus', acknowledge);
    document.addEventListener('visibilitychange', acknowledge);
    watches.set(slot, { acknowledge, stop() {
      observer.disconnect(); end.remove(); window.removeEventListener('focus', acknowledge);
      document.removeEventListener('visibilitychange', acknowledge);
    } });
  }
  function watchTask(root, task, records) {
    const incoming = records.filter(a => a.owner !== myNickname);
    const last = incoming.reduce((last, a) => !last || a.assetId > last.assetId ? a : last, null);
    observe('task', last && root.querySelector(`.record-message[data-asset-id="${last.assetId}"]`), 'task', task.id, last?.assetId);
  }
  function snapshot() {
    const rows = [];
    for (const task of tasks.values()) {
      if (task.assignee !== myNickname) continue;
      const unread = comments.filter(a => a.parentType === 1 && a.parentId === task.id && a.owner !== myNickname && a.assetId > cursor('task', task.id));
      if (!unread.length) continue;
      unread.sort((a, b) => a.assetId < b.assetId ? -1 : 1);
      rows.push({ task, count: unread.length, first: unread[0], last: unread.at(-1) });
    }
    return rows;
  }
  async function refresh() {
    if (!identity()) return;
    if (loading) { again = true; return; }
    loading = true;
    const scope = identity(), token = generation, revision = taskRevision;
    try {
      const result = await window.NRCAssets.requestAllAssets(0n, 1);
      const next = result.assets.filter(a => a.parentType === 1);
      const parents = await window.NRCTasks.requestTasksByIds(0n, next.map(a => a.parentId));
      if (scope !== identity() || token !== generation) return;
      if (revision !== taskRevision) { again = true; return; }
      comments = next; tasks = new Map(parents.map(task => [task.id, task]));
      suspended = false;
      for (const watch of watches.values()) watch.acknowledge();
      changed();
    } catch {
      // Retain the last confirmed snapshot; a failed read is not an empty inbox.
    } finally {
      if (token === generation) {
        loading = false;
        if (again) { again = false; refresh(); }
      }
    }
  }
  function disconnect() {
    generation++; loading = false; again = false; comments = []; tasks.clear();
    // Keep observers on still-mounted content, but never acknowledge offline.
    // A successful rebuild resumes only the exact captured, rendered records.
    suspended = true; changed();
  }
  for (const event of ['nrc:asset-created', 'nrc:asset-updated', 'nrc:asset-deleted']) document.addEventListener(event, e => {
    if (e.detail?.asset?.assetType === 1) refresh();
  });
  document.addEventListener('nrc:task-changed', e => {
    const { task, reason } = e.detail || {};
    if (!task) return;
    taskRevision++;
    if (reason === 'deleted') tasks.delete(task.id);
    else if (tasks.has(task.id)) tasks.set(task.id, { ...tasks.get(task.id), ...task });
    changed();
  });
  window.addEventListener('storage', e => {
    const prefix = keyFor('ticket', '');
    if (prefix && e.key?.startsWith(prefix)) changed({ kind: 'ticket' });
    else if (e.key?.startsWith('nrc:record-read:')) changed();
  });
  return { cursor, cursors, markRead, observe, watchTask, snapshot, refresh, disconnect };
})();
