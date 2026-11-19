// NRC owns current state; DuckDB observations never overwrite it.
window.NRCMonitoring = (() => {
  const pending = new Map();
  const el = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const ready = () => typeof serverReady !== 'undefined' && serverReady && ws?.readyState === WebSocket.OPEN;
  const active = () => window.NRCViewManager?.getActiveView() === 'monitoring';
  const stamp = ns => !ns || ns === '0' ? '—' : new Date(Number(BigInt(ns) / 1000000n)).toLocaleString();
  const metadata = asset => JSON.parse(asset.preview);
  let generation = 0, tab = 'status', page = null, rows = [], loading = false;
  let detailGeneration = 0, historyController;
  let inspectorHistoryTail = Promise.resolve();
  let registerHistoryTail = Promise.resolve();
  let registerController;
  let period = 1;
  let statusPages = 1, refreshTimer, searchTimer;
  let registerWindow = null;
  let pageError = false;
  const registerHistory = new Map();
  const inspectorHistory = new Map();
  const hour = 3600000;
  const historyMaxAge = 5 * 60000;
  const percent = (n, d) => d > 0n ? `${Number(n * 10000n / d) / 100}%` : 'UNKNOWN';
  const displayUnits = { number: 'Number', percent: 'Percent (0–100)', bytes: 'Bytes (IEC)' };
  const conditionUnits = { ...displayUnits, bits: 'Bits (SI)', nanoseconds: 'Duration (ns)', microseconds: 'Duration (µs)', milliseconds: 'Duration (ms)', seconds: 'Duration (s)', percent_ratio: 'Percent (0–1)' };
  const conditionUnit = condition => condition.unit || (['latency_ns', 'certificate_remaining_ns'].includes(condition.field) ? 'nanoseconds' : 'number');

  function formatValue(value, unit = 'number') {
    if (value == null) return '—';
    let number = Number(value);
    if (!Number.isFinite(number)) return String(value);
    let suffix = unit === 'percent' || unit === 'percent_ratio' ? ' %' : '';
    if (unit === 'percent_ratio') number *= 100;
    if (unit === 'bytes') {
      const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB', 'ZiB', 'YiB'];
      let index = 0;
      while (Math.abs(number) >= 1024 && index < units.length - 1) { number /= 1024; index++; }
      suffix = ` ${units[index]}`;
    }
    if (unit === 'bits') {
      const units = ['bit', 'kbit', 'Mbit', 'Gbit', 'Tbit', 'Pbit', 'Ebit'];
      let index = 0;
      while (Math.abs(number) >= 1000 && index < units.length - 1) { number /= 1000; index++; }
      suffix = ` ${units[index]}`;
    }
    const durationFactor = { nanoseconds: 1e-9, microseconds: 1e-6, milliseconds: 1e-3, seconds: 1 }[unit];
    if (durationFactor) {
      number *= durationFactor;
      const units = [[86400, 'd'], [3600, 'h'], [60, 'min'], [1, 's'], [1e-3, 'ms'], [1e-6, 'µs'], [1e-9, 'ns']];
      const [factor, label] = units.find(([factor]) => Math.abs(number) >= factor) || units.at(-1);
      number /= factor;
      suffix = ` ${label}`;
    }
    const magnitude = Math.abs(number);
    return (magnitude > 0 && (magnitude < 0.01 || magnitude >= 1e6)
      ? number.toExponential(2)
      : number.toLocaleString(undefined, { maximumFractionDigits: 2, useGrouping: false })) + suffix;
  }

  function cachedHistory(row) {
    const cached = registerHistory.get(row.id);
    return cached?.scope === currentWorkspaceId && cached.revision === row.revision && cached.period === period && cached.to === Math.floor(Date.now() / hour) * hour ? cached : null;
  }
  function historyDisplay(row, part) {
    const cached = cachedHistory(row);
    if (!cached) return part === 'trail' ? '<span class="customer-meta">Reading history…</span>' : '—';
    return cached[part] + (part === 'trail' && Date.now() - cached.updatedAt >= historyMaxAge ? `<span class="customer-meta">${esc(cached.error || 'HISTORY UPDATING · PREVIOUS RESULT')}</span>` : '');
  }

  function availability(result, revision, range) {
    const width = range.to - range.from === 24 * hour ? hour : 24 * hour;
    const count = (range.to - range.from) / width;
    const start = BigInt(range.from) * 1000000n, step = BigInt(width) * 1000000n;
    const buckets = Array.from({ length: count }, () => ({ healthy: 0n, failing: 0n, paused: 0n }));
    const identities = new Set();
    for (const row of result.rows) {
      if (row.revision !== revision) continue;
      const at = BigInt(row.bucket_ns) - start;
      if (at < 0n || at >= BigInt(count) * step || at % BigInt(hour * 1e6) !== 0n) continue;
      identities.add(row.identity);
      const bucket = buckets[Number(at / step)];
      bucket.healthy += BigInt(row.healthy_ns);
      bucket.failing += BigInt(row.failing_ns);
      bucket.paused += BigInt(row.paused_ns);
    }
    const capacity = BigInt(identities.size) * step;
    let healthy = 0n, failing = 0n, paused = 0n;
    const bars = buckets.map((b, i) => {
      healthy += b.healthy; failing += b.failing; paused += b.paused;
      const known = b.healthy + b.failing;
      const unknown = capacity - known - b.paused;
      const state = b.failing > 0n ? 'failing' : capacity > 0n && b.paused === capacity ? 'paused' : known > 0n && unknown === 0n ? 'healthy' : known + b.paused > 0n ? 'partial' : 'unknown';
      const duration = ns => `${(Number(ns) / 1e9).toLocaleString(undefined, { maximumFractionDigits: 2 })} s`;
      const label = `${new Date(range.from + i * width).toLocaleString()} – ${new Date(range.from + (i + 1) * width).toLocaleString()}: ${state.toUpperCase()} · uptime / satisfaction ${percent(b.healthy, known)} · coverage ${percent(known, capacity - b.paused)} · INSTANCE TIME: healthy ${duration(b.healthy)} · failing ${duration(b.failing)} · unknown ${capacity > 0n ? duration(unknown) : 'UNKNOWN'} · paused ${duration(b.paused)}`;
      // Fractions are durations, not an inferred event order. Keep subpixel gaps
      // proportional; the separate marker makes them discoverable at any width.
      const parts = ['healthy', 'failing', 'unknown', 'paused'].map(part => {
        const value = part === 'unknown' ? unknown : b[part];
        const share = capacity > 0n ? Number(value) / Number(capacity) * 100 : part === 'unknown' ? 100 : 0;
        return `<span class="monitor-history-part monitor-history-${part}" style="width:${share}%"></span>`;
      }).join('');
      return `<button type="button" class="monitor-history-bar" data-state="${state}" data-gap="${unknown > 0n || capacity === 0n}" aria-pressed="false" aria-label="${esc(label)}" title="${esc(label)}"><span class="monitor-history-fill" aria-hidden="true">${parts}</span></button>`;
    }).join('');
    const pending = result.pending_rollup_hours_global !== '0';
    return {
      trail: `<div class="monitor-history-bars" style="--monitor-bars:${count}" role="group" aria-label="${count} completed ${width === hour ? 'hours' : '24-hour periods'}, oldest first; select a period for instance-time durations">${bars}</div><span class="customer-meta">${esc(new Date(range.from).toLocaleString())} – ${esc(new Date(range.to).toLocaleString())}${pending ? ' · ROLLUPS PENDING (GLOBAL)' : ''}</span><p class="monitor-history-detail customer-meta" hidden></p>`,
      metrics: `<strong>${percent(healthy, healthy + failing)}</strong><span class="customer-meta">COVERAGE ${percent(healthy + failing, BigInt(count) * capacity - paused)}</span><span class="customer-meta">${identities.size ? `${identities.size} observed identities` : 'NO HISTORY'} · current revision</span>`,
    };
  }
  async function loadRegisterHistory(token, scope, snapshot, controller) {
    const to = Math.floor(Date.now() / hour) * hour;
    const range = { from: to - period * 24 * hour, to, resolution: '1h' };
    const valid = () => token === generation && scope === currentWorkspaceId && active() && tab === 'status';
    const previous = registerHistoryTail;
    let release;
    registerHistoryTail = new Promise(resolve => { release = resolve; });
    await previous;
    try {
    // One bounded page at a time leaves the gateway's other slot for the Inspector.
    const missing = snapshot.filter(row => { const cached = cachedHistory(row); return !cached || Date.now() - cached.updatedAt >= historyMaxAge; });
    for (let offset = 0; offset < missing.length; offset += 16) {
      if (!valid()) return;
      const batch = missing.slice(offset, offset + 16);
      let results;
      try {
        results = await historyBatch(batch.map(row => row.id), range, AbortSignal.any([controller.signal, AbortSignal.timeout(8000)]), valid);
      } catch (error) {
        results = batch.map(row => ({ monitor_id: row.id, error: error.message }));
      }
      if (!valid()) return;
      for (const [index, row] of batch.entries()) {
        const result = results[index], cached = cachedHistory(row);
        const display = result.error
          ? cached ? { trail: cached.trail, metrics: cached.metrics, error: `HISTORY UPDATE FAILED · PREVIOUS RESULT · ${result.error}` } : { trail: `<span class="customer-meta">${esc(result.error)}</span>`, metrics: 'UNAVAILABLE', error: result.error }
          : availability(result, row.revision, range);
        registerHistory.set(row.id, { ...display, scope, revision: row.revision, period, to, updatedAt: display.error ? 0 : Date.now() });
      }
      const cells = el('monitorList').querySelectorAll('[data-history-monitor]');
      const byID = new Map(batch.map(row => [row.id, row]));
      for (const cell of cells) if (byID.has(cell.dataset.historyMonitor)) cell.innerHTML = historyDisplay(byID.get(cell.dataset.historyMonitor), cell.dataset.historyPart);
    }
    } finally { release(); }
  }
  async function historyBatch(ids, range, signal, valid) {
    if (!valid()) return [];
    const query = new URLSearchParams({ ids: ids.join(','), from: new Date(range.from).toISOString(), to: new Date(range.to).toISOString(), resolution: range.resolution });
    const response = await fetch(`/monitoring/history/batch/uptime?${query}`, { signal, cache: 'no-store', headers: { 'X-NRC-Workspace': currentWorkspaceId } });
    // Large pages split serially; never increase the two-slot admission pressure.
    if (response.status === 422 && ids.length > 1) {
      const middle = Math.ceil(ids.length / 2);
      return [...await historyBatch(ids.slice(0, middle), range, signal, valid), ...await historyBatch(ids.slice(middle), range, signal, valid)];
    }
    if (!response.ok) throw new Error(`History unavailable (HTTP ${response.status}). Current NRC state is independent.`);
    const result = await response.json();
    if (result.version !== 1 || result.workspace !== currentWorkspaceId || result.monitor_id !== 'batch' || !Array.isArray(result.monitor_ids) || result.monitor_ids.join(',') !== ids.join(',') || !Array.isArray(result.results) || result.results.length !== ids.length || result.results.some((row, i) => row.monitor_id !== ids[i] || ![200, 404, 422].includes(row.status) || !Array.isArray(row.rows))) throw new Error('History scope mismatch.');
    return result.results.map(row => ({ ...row, pending_rollup_hours_global: result.pending_rollup_hours_global, ...(row.status === 200 ? {} : { error: `History unavailable (HTTP ${row.status}). Current NRC state is independent.` }) }));
  }
  function rpc(buffer, response) {
    if (!ready()) return Promise.reject(new Error('Offline. Reconnect before reading or changing state.'));
    const id = getRpcCorrelationId();
    new DataView(buffer).setUint32(2, id);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { pending.delete(id); reject(new Error('No response. Refresh before retrying an action.')); }, 15000);
      pending.set(id, { resolve, reject, timeout, response, subject: String(new DataView(buffer).getBigUint64(6)) });
      sendPacket(buffer, response === 181 ? id : 0);
    });
  }
  function handlePage(view) {
    if (view.byteLength < 6) return;
    const id = view.getUint32(2), request = pending.get(id);
    if (!request) return;
    pending.delete(id); clearTimeout(request.timeout);
    try {
      if (view.getUint16(0) !== request.response) throw new Error('Unexpected monitoring response.');
      if (request.response === 176) {
        if (view.byteLength !== 23 || String(view.getBigUint64(6)) !== request.subject || view.getBigInt64(14) <= 0n || view.getUint8(22) > 1) throw new Error('Invalid incident receipt.');
        request.resolve(null);
      } else {
        const page = JSON.parse(new TextDecoder().decode(new Uint8Array(view.buffer, view.byteOffset + 6, view.byteLength - 6)));
        if (page.version !== 1 || !Array.isArray(page.rows) || page.rows.length > 16) throw new Error('Invalid status page.');
        if (request.response === 181) {
          if (typeof page.has_more !== 'boolean' || !/^\d+$/.test(page.cursor_id) || page.rows.some(row => !/^[1-9]\d*$/.test(row.id) || typeof row.preview !== 'string')) throw new Error('Invalid open incident page.');
        } else if (page.monitor_id !== request.subject) throw new Error('Status scope mismatch.');
        request.resolve(page);
      }
    } catch (error) { request.reject(error); }
  }
  function handleError(error) {
    const request = pending.get(error.correlationId);
    if (!request) return false;
    pending.delete(error.correlationId); clearTimeout(request.timeout);
    request.reject(new Error(error.errorMsg)); return true;
  }
  async function readOpenIncidents({ isCancelled = () => false } = {}) {
    const assets = new Map();
    let cursor = 0n;
    do {
      if (isCancelled()) throw new Error('Incident read cancelled.');
      const view = new DataView(new ArrayBuffer(15));
      view.setUint16(0, 76); view.setBigUint64(6, cursor); view.setUint8(14, 16);
      const page = await rpc(view.buffer, 181);
      if (isCancelled()) throw new Error('Incident read cancelled.');
      for (const row of page.rows) {
        const assetId = BigInt(row.id);
        assets.set(assetId, { assetId, assetType: 16, preview: row.preview });
      }
      if (!page.has_more) return { assets: [...assets.values()] };
      const next = BigInt(page.cursor_id);
      if (next <= cursor) throw new Error('Incident cursor did not advance.');
      cursor = next;
    } while (true);
  }
  function statusQuery(id = '0', cursor = null, retired = false) {
    const search = new TextEncoder().encode(id === '0' ? el('monitorSearch').value.trim() : '');
    if (search.length > 256) throw new Error('Search exceeds 256 UTF-8 bytes.');
    const view = new DataView(new ArrayBuffer(id === '0' ? 34 + search.length : 33));
    view.setUint16(0, 73); view.setBigUint64(6, BigInt(id));
    view.setBigUint64(14, BigInt(cursor?.cursor_id || '0')); view.setUint8(22, cursor?.cursor_rank || 0);
    view.setBigUint64(23, BigInt(cursor?.at || '0')); view.setUint8(31, 16); view.setUint8(32, Number(retired));
    if (id === '0') {
      view.setUint8(33, ['all', 'problems', 'healthy', 'paused'].indexOf(el('monitorStateFilter').value));
      new Uint8Array(view.buffer, 34).set(search);
    }
    return rpc(view.buffer, 179);
  }
  function assetRead(id) {
    return new Promise((resolve, reject) => window.NRCAssets.sendGetAsset(0n, BigInt(id), {
      onSuccess: result => resolve(result.asset), onError: error => reject(new Error(error?.message || 'Record read failed.')),
    }));
  }
  function badge(status) { return `<span class="monitor-state" data-state="${esc(status)}">${esc(status.replaceAll('_', ' ').toUpperCase())}</span>`; }
  function streak(label, value, limit, state) {
    const progress = limit > 0 ? Math.min(100, value / limit * 100) : 0;
    const graphic = limit > 0 && limit <= 20
      ? Array.from({ length: limit }, (_, i) => `<i class="monitor-streak-step${i < value ? ' is-filled' : ''}"></i>`).join('')
      : `<i class="monitor-streak-track"><i style="width:${progress}%"></i></i>`;
    return `<span class="monitor-streak" data-state="${state}"><span>${label} ${value}/${limit}</span><span class="monitor-streak-graphic" aria-hidden="true">${graphic}</span></span>`;
  }
  function instanceLabel(identity, compact = false) {
    try {
      const labels = JSON.parse(identity);
      if (labels && typeof labels === 'object' && !Array.isArray(labels)) return Object.entries(labels).map(([key, value]) => `<span class="monitor-identity-label">${compact && key === 'instance' ? '' : `<small>${esc(key)}</small> `}${esc(typeof value === 'object' ? JSON.stringify(value) : value)}</span>`).join('') || esc(identity);
    } catch {}
    return esc(identity);
  }
  function section(title, content) { return `<section class="customer-section"><header class="panel-header"><div><span>${title}</span></div></header>${content}</section>`; }
  function facts(entries) { return `<dl class="customer-facts">${entries.map(([label, value]) => `<div><dt>${esc(label)}</dt><dd>${esc(value)}</dd></div>`).join('')}</dl>`; }
  function table(headers, body) { return `<table class="task-table monitor-table"><thead><tr>${headers.map(h => `<th scope="col">${h}</th>`).join('')}</tr></thead><tbody>${body}</tbody></table>`; }
  function loadMoreNearEnd() {
    const scroller = el('monitorRegisterScroll');
    if (!active() || tab !== 'status' || loading || pageError || !ready() || !page?.has_more || !scroller?.clientHeight) return;
    if (scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight <= 400) void refresh(true);
  }
  function render() {
    if (!el('monitorList')) return;
    const focusedMonitor = el('monitorList').contains(document.activeElement) ? document.activeElement.dataset.monitor : null;
    const scroller = el('monitorRegisterScroll');
    const previousBody = el('monitorList').querySelector('tbody');
    if (registerWindow) registerWindow.destroy();
    else if (previousBody) window.NRCVirtualList.capture(previousBody, scroller, previousBody.rows,
      row => row.querySelector('[data-monitor], [data-incident]')?.dataset.monitor || row.querySelector('[data-incident]')?.dataset.incident);
    registerWindow = null;
    el('monitorList').setAttribute('aria-busy', String(loading));
    el('monitorHistoryLegend').hidden = tab !== 'status';
    el('monitorRefresh').disabled = loading;
    el('monitorStatusTab').setAttribute('aria-pressed', String(tab === 'status'));
    el('monitorIncidentsTab').setAttribute('aria-pressed', String(tab === 'incidents'));
    el('monitorStatusTab').classList.toggle('active', tab === 'status');
    el('monitorIncidentsTab').classList.toggle('active', tab === 'incidents');
    el('monitorStatusFilters').hidden = tab !== 'status';
    el('monitorBucketSize').textContent = `1 BAR = ${period === 1 ? '1 COMPLETED HOUR' : '24 COMPLETED HOURS'}`;
    const query = el('monitorSearch').value.trim().toLowerCase();
    const filter = el('monitorStateFilter').value;
    const visible = rows.filter(row => {
      if (tab === 'status') return true; // Server filters before pagination.
      const m = metadata(row);
      return `${m.title} #${row.assetId} #${m.monitor_id}`.toLowerCase().includes(query);
    });
    el('monitorFilterScope').textContent = tab === 'status' ? 'SEARCH & STATE: ALL WORKSPACE MONITORS · COUNTS: LOADED MATCHES · PROBLEMS FIRST · RULES VIA CLI' : 'SEARCH & COUNTS: LOADED INCIDENTS · RULES VIA CLI';
    const counts = tab === 'status' ? visible.reduce((s, row) => s.map((n, i) => n + row.counts[i]), Array(9).fill(0)) : null;
    el('monitorSummary').textContent = tab === 'status'
      ? `SHOWN: ${visible.length} / ${rows.length} LOADED MONITORS · ${counts.reduce((a, b) => a + b, 0)} INSTANCES · ${counts[0]} FIRING · ${counts[1]} PENDING${page?.has_more ? ' · MORE MONITORS AVAILABLE' : ''}`
      : `SHOWN: ${visible.length} / ${rows.length} LOADED INCIDENTS · ${visible.filter(a => metadata(a).status === 'firing').length} FIRING`;
    const renderRow = row => {
      const node = document.createElement('tr');
      if (tab === 'status') node.innerHTML = `<td><button class="task-row-open" data-monitor="${esc(row.id)}">${esc(row.name)}</button><span class="customer-meta">#${esc(row.id)} · ${row.counts.reduce((a, b) => a + b, 0)} instances · ${row.counts[0]} firing</span></td><td>${badge(row.status)}<span class="customer-meta">${esc(stamp(row.evaluated_at))}</span></td><td class="monitor-history-cell" data-history-monitor="${esc(row.id)}" data-history-part="trail">${historyDisplay(row, 'trail')}</td><td data-history-monitor="${esc(row.id)}" data-history-part="metrics">${historyDisplay(row, 'metrics')}</td>`;
      else {
        const m = metadata(row);
        node.innerHTML = `<td><button class="task-row-open" data-incident="${row.assetId}">${esc(m.title)}</button><span class="customer-meta">#${row.assetId} · MONITOR #${esc(m.monitor_id)}</span></td><td>${badge(m.status)}</td><td>${esc(m.acknowledged_by || 'NOT ACKNOWLEDGED')}</td><td>${esc(m.assigned_to || 'UNASSIGNED')}</td>`;
      }
      return node;
    };
    el('monitorList').innerHTML = visible.length ? table(tab === 'status'
      ? ['MONITOR / INSTANCES', 'CURRENT STATE', `HISTORY · ${period === 1 ? '24H' : `${period}D`}`, 'UPTIME / SATISFACTION']
      : ['INCIDENT', 'STATE', 'ACKNOWLEDGED', 'ASSIGNEE'], '') :
      `<p class="customer-empty">${loading ? 'Reading NRC…' : tab === 'status' && page && (query || filter !== 'all') ? 'No matching monitors in this workspace.' : rows.length ? 'No matching loaded records.' : 'No records loaded.'}</p>`;
    const body = el('monitorList').querySelector('tbody');
    if (body) {
      if (previousBody) for (const property of ['virtualScrollTop', 'virtualWidth', 'virtualHeights', 'virtualAnchor']) body[property] = previousBody[property];
      if (visible.length > 100) {
        // Render only the viewport; measured spacers keep the full loaded height.
        registerWindow = window.NRCVirtualList.create({
          host: body, scroller, items: visible, columns: 4,
          estimate: scroller.clientWidth <= 700 ? 240 : 100,
          key: row => String(row.id ?? row.assetId),
          render: renderRow,
        });
        const focusIndex = visible.findIndex(row => row.id === focusedMonitor);
        if (focusIndex >= 0) {
          // Mount the focused control without pulling a scrolled-away reader
          // back to it on every live status refresh.
          const scrollTop = scroller.scrollTop;
          registerWindow.ensure(focusIndex);
          scroller.scrollTop = scrollTop;
        }
      } else {
        body.append(...visible.map(renderRow));
        scroller.scrollTop = body.virtualScrollTop ?? scroller.scrollTop;
      }
    }
    if (focusedMonitor) [...el('monitorList').querySelectorAll('[data-monitor]')].find(button => button.dataset.monitor === focusedMonitor)?.focus({ preventScroll: true });
  }
  async function refresh(more = false, automatic = false) {
    if (!active()) return;
    if (more && (loading || !page?.has_more)) return;
    if (automatic && (loading || !ready() || tab !== 'status' || document.hidden)) return;
    clearTimeout(searchTimer);
    const token = ++generation;
    pageError = false;
    registerController = new AbortController();
    if (!more && !automatic) {
      el('monitorRegisterScroll').scrollTop = 0;
      for (const cached of registerHistory.values()) cached.updatedAt = 0;
    }
    loading = true; el('monitorStatus').textContent = ready() ? 'READING NRC' : 'OFFLINE';
    if (automatic) {
      el('monitorList').setAttribute('aria-busy', 'true');
      el('monitorRefresh').disabled = true;
    } else render();
    try {
      if (!ready()) throw new Error('Offline. Reconnect to read current state.');
      if (tab === 'status') {
        let next, replacement = [], count = 0;
        const targetPages = automatic ? statusPages : 1;
        do {
          next = await statusQuery('0', count ? next : more ? page : null);
          if (token !== generation) return;
          replacement.push(...next.rows); count++;
        } while (count < targetPages && next.has_more);
        // Live rank changes can repeat IDs across pages. Keep the latest row at
        // its first position, but retain the cursor from the actual server page.
        page = next; rows = [...new Map((more ? [...rows, ...replacement] : replacement).map(row => [row.id, row])).values()];
        statusPages = more ? statusPages + 1 : count;
        const ids = new Set(rows.map(row => row.id));
        for (const id of registerHistory.keys()) if (!ids.has(id)) registerHistory.delete(id);
      } else {
        const result = await window.NRCAssets.requestAllAssets(0n, 16, { isCancelled: () => token !== generation });
        if (token !== generation) return;
        rows = result.assets.sort((a, b) => {
          const am = metadata(a), bm = metadata(b);
          const rank = m => m.status === 'firing' ? (m.acknowledged_by ? 1 : 0) : 2;
          return rank(am) - rank(bm) || (a.assetId < b.assetId ? -1 : a.assetId > b.assetId ? 1 : 0);
        }); page = null;
      }
      el('monitorStatus').textContent = `${rows.length} LOADED${page?.has_more ? ' · MORE AVAILABLE' : ''} · ${new Date().toLocaleTimeString()}`;
    } catch (error) { if (token === generation) { pageError = true; el('monitorStatus').textContent = `${error.message} · DISPLAYED ROWS MAY BE STALE`; } }
    finally {
      if (token === generation) {
        loading = false; render();
        if (tab === 'status' && ready()) void loadRegisterHistory(token, currentWorkspaceId, rows, registerController);
        if (!pageError) requestAnimationFrame(loadMoreNearEnd);
      }
    }
  }
  function open(type, id) { window.NRCInspector.openEntity({ type, id: BigInt(id) }, { replaceCurrent: window.NRCInspector.current()?.type === type }); }
  function valueScale(row, definition, revision, unit) {
    if (row.revision !== String(revision) || typeof row.value !== 'number' || !Number.isFinite(row.value)) return '';
    const entries = [{ key: 'value', value: row.value }, ...['trigger', 'recovery'].filter(key => definition[key]).map(key => ({ key, value: Number(definition[key].value) }))];
    if (entries.some(entry => !Number.isFinite(entry.value))) return '<p class="customer-meta">Scale unavailable: threshold outside browser numeric range.</p>';
    const values = entries.map(entry => entry.value), magnitude = Math.max(...values.map(Math.abs)) || 1;
    const low = Math.min(...values), high = Math.max(...values), span = high / magnitude - low / magnitude;
    const position = value => span ? 112 + (value / magnitude - low / magnitude) / span * 336 : 280;
    const lanes = entries.map((entry, index) => {
      const y = 18 + index * 24, x = position(entry.value);
      return `<g data-scale="${entry.key}"><text x="0" y="${y + 4}">${entry.key.toUpperCase()}</text><path class="monitor-scale-track" d="M100,${y}H460"/>${entry.key === 'value' ? `<circle cx="${x}" cy="${y}" r="4"/>` : `<path class="monitor-scale-marker" d="M${x},${y - 6}V${y + 6}"/>`}</g>`;
    }).join('');
    const bottom = entries.length * 24 + 16;
    return `<svg class="monitor-value-scale" viewBox="0 0 480 ${bottom + 6}" role="img" aria-label="Relative scale: value ${esc(formatValue(row.value, unit))}, trigger ${esc(definition.trigger.op)} ${esc(formatValue(definition.trigger.value, unit))}${definition.recovery ? `, recovery ${esc(definition.recovery.op)} ${esc(formatValue(definition.recovery.value, unit))}` : ''}. Current revision; not a lifecycle status.">${lanes}<text x="112" y="${bottom}" text-anchor="start">${esc(formatValue(low, unit))}</text><text x="448" y="${bottom}" text-anchor="end">${esc(formatValue(high, unit))}</text><text x="280" y="${bottom}" text-anchor="middle">RELATIVE SCALE</text></svg>`;
  }
  function sampleChart(rows, definition, revision, interval, range, unit) {
    const samples = rows.map(row => ({ ...row, at: Number(BigInt(row.observed_at_ns) / 1000000n) })).filter(row => row.at >= range.from && row.at < range.to).sort((a, b) => a.at - b.at);
    const usable = row => row.revision === String(revision) && typeof row.value === 'number' && Number.isFinite(row.value);
    const points = samples.filter(usable);
    if (!points.length) return '<p class="customer-empty">No numeric samples for the current revision in this hour.</p>';
    const allThresholds = ['trigger', 'recovery'].filter(key => definition[key]).map(key => ({ ...definition[key], key }));
    const thresholds = allThresholds.filter(t => Number.isFinite(Number(t.value)));
    const omitted = allThresholds.filter(t => !Number.isFinite(Number(t.value)));
    const values = [...points.map(row => row.value), ...thresholds.map(t => Number(t.value))];
    // Normalize before subtracting so opposite large finite values cannot overflow the axis.
    const scale = Math.max(...values.map(Math.abs)) || 1;
    let low = Math.min(...values) / scale, high = Math.max(...values) / scale;
    const pad = (high - low || 0.2) * 0.1;
    low = Math.max(low - pad, -Number.MAX_VALUE / scale); high = Math.min(high + pad, Number.MAX_VALUE / scale);
    const x = at => 64 + (at - range.from) / (range.to - range.from) * 400;
    const y = value => 168 - (value / scale - low) / (high - low) * 148;
    let previous = null, trace = '';
    const connected = new Set();
    for (const row of samples) {
      if (!usable(row)) { previous = null; continue; }
      const confirmed = row.acceptance === 'confirmed';
      if (confirmed && previous && row.at > previous.at && row.at - previous.at <= Number(interval) / 1e6 * 1.5) {
        trace += `M${x(previous.at)},${y(previous.value)}L${x(row.at)},${y(row.value)}`;
        connected.add(previous); connected.add(row);
      }
      previous = confirmed ? row : null;
    }
    const markers = points.map((row, index) => {
      const confirmed = row.acceptance === 'confirmed';
      const formatted = formatValue(row.value, unit);
      const label = `${stamp(row.observed_at_ns)} · ${formatted}${formatted === String(row.value) ? '' : ` · RAW ${row.value}`}${confirmed ? '' : ` · NOT CONFIRMED: ${row.acceptance}`}`;
      const attrs = `data-point="${index}" data-x="${x(row.at)}"`;
      return confirmed ? `<circle ${attrs} class="${!connected.has(row) || index === points.length - 1 ? 'monitor-chart-endpoint' : ''}" cx="${x(row.at)}" cy="${y(row.value)}" r="3"><title>${esc(label)}</title></circle>` : `<rect ${attrs} x="${x(row.at) - 3}" y="${y(row.value) - 3}" width="6" height="6" transform="rotate(45 ${x(row.at)} ${y(row.value)})"><title>${esc(label)}</title></rect>`;
    }).join('');
    const ticks = [low, (low + high) / 2, high].map(v => `<text x="54" y="${y(v * scale) + 4}" text-anchor="end">${esc(formatValue(v * scale, unit))}</text>`).join('');
    const lines = thresholds.map(t => `<line data-threshold="${t.key}" x1="64" x2="464" y1="${y(Number(t.value))}" y2="${y(Number(t.value))}"/>`).join('');
    const times = [range.from, (range.from + range.to) / 2, range.to].map((at, i) => `<text x="${x(at)}" y="195" text-anchor="${['start', 'middle', 'end'][i]}">${esc(new Date(at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }))}</text>`).join('');
    for (const t of omitted) thresholds.push({ ...t, value: 'outside browser numeric range; not plotted' });
    return `<div class="monitor-timeseries"><p class="monitor-chart-readout" aria-live="polite">Hover or tap for values</p><svg viewBox="0 0 480 210" tabindex="0" role="group" aria-label="Last hour, current revision: ${points.length} samples. Use arrow keys to inspect values, Escape to clear. Hollow diamonds are not confirmed. Gaps are not interpolated."><path class="monitor-chart-axis" d="M64,20V168H464"/>${ticks}${times}${lines}<path class="monitor-chart-trace" d="${trace}"/><path class="monitor-chart-guide"/><g class="monitor-chart-points">${markers}</g></svg><div class="monitor-chart-legend"><span>─ VALUE</span>${thresholds.map(t => `<span data-threshold="${t.key}" title="${esc(t.value)}">┄ ${t.key.toUpperCase()} ${esc(t.op)} ${esc(formatValue(t.value, unit))}</span>`).join('')}<span>◇ NOT CONFIRMED</span></div><p class="customer-meta">CURRENT REVISION · GAPS &gt; ${Number(interval) / 1e9 * 1.5}s</p></div>`;
  }
  function bindSampleChart(host) {
    const svg = host.querySelector('.monitor-timeseries svg');
    if (!svg) return;
    const points = [...svg.querySelectorAll('[data-point]')], readout = host.querySelector('.monitor-chart-readout'), guide = svg.querySelector('.monitor-chart-guide');
    let selected = -1, pinned = false;
    const show = index => {
      if (index === selected) return;
      if (selected >= 0) points[selected].classList.remove('is-active');
      selected = index;
      const point = points[index];
      point?.classList.add('is-active');
      readout.textContent = point ? point.querySelector('title').textContent : 'Hover or tap for values';
      guide.setAttribute('d', point ? `M${point.dataset.x},20V168` : '');
    };
    const nearest = event => {
      const p = new DOMPoint(event.clientX, event.clientY).matrixTransform(svg.getScreenCTM().inverse());
      if (p.x < 64 || p.x > 464 || p.y < 20 || p.y > 168) return -1;
      let index = -1, distance = 12;
      points.forEach((point, i) => { const d = Math.abs(Number(point.dataset.x) - p.x); if (d < distance) { index = i; distance = d; } });
      return index;
    };
    svg.onpointermove = event => { if (!pinned && event.pointerType !== 'touch') show(nearest(event)); };
    svg.onpointerleave = () => { if (!pinned) show(-1); };
    svg.onclick = event => { const index = nearest(event); pinned = index >= 0 && !(pinned && index === selected); show(pinned ? index : -1); };
    svg.onkeydown = event => {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End', 'Escape'].includes(event.key)) return;
      event.preventDefault();
      event.stopPropagation();
      pinned = event.key !== 'Escape';
      show(event.key === 'Escape' ? -1 : event.key === 'Home' ? 0 : event.key === 'End' ? points.length - 1 : Math.max(0, Math.min(points.length - 1, selected < 0 ? 0 : selected + (event.key === 'ArrowLeft' ? -1 : 1))));
    };
  }
  function recentChecks(host, rows, runs, definition, revision, range) {
    const samples = rows.filter(row => {
      const at = Number(BigInt(row.observed_at_ns) / 1000000n);
      return at >= range.from && at < range.to;
    }).sort((a, b) => BigInt(a.observed_at_ns) < BigInt(b.observed_at_ns) ? -1 : BigInt(a.observed_at_ns) > BigInt(b.observed_at_ns) ? 1 : 0).slice(-20);
    if (!samples.length) { host.innerHTML = '<p class="customer-empty">No checks retained in this hour.</p>'; return; }
    const attempts = new Map(runs.map(run => [run.run_id, run]));
    const checks = samples.map(sample => {
      const reason = sample.acceptance !== 'confirmed' ? `NOT CONFIRMED · ${sample.acceptance.toUpperCase()}` : sample.revision !== String(revision) ? 'PREVIOUS CONFIGURATION' : '';
      const state = reason ? 'unknown' : String(sample.condition) === '0' ? 'healthy' : String(sample.condition) === '1' ? 'failing' : 'unknown';
      const label = `${stamp(sample.observed_at_ns)} · ${state === 'healthy' ? 'PASSED' : state === 'failing' ? 'FAILED' : 'UNKNOWN'}${reason ? ` · ${reason}` : ''}`;
      // Join by the retained attempt ID, never a possibly repeated sequence number.
      const run = sample.run_id ? attempts.get(sample.run_id) : null;
      const duration = run?.duration_ns != null ? `<p class="customer-meta">CHECK DURATION ${esc((Number(run.duration_ns) / 1e6).toFixed(1))} ms</p>` : '';
      const conditions = run?.diagnostics && !run.diagnostics.conditions.length ? (run.diagnostics.error ? `<p>${esc(run.diagnostics.error)}</p>` : '') : diagnostics(run, definition, revision, null, null);
      return { state, label, details: `<p>${esc(label)}</p>${duration}${conditions}` };
    });
    host.innerHTML = `<p class="customer-meta">${checks.filter(check => check.state === 'healthy').length} OF ${checks.length} SHOWN CHECKS PASSED · LATEST ${esc(stamp(samples.at(-1).observed_at_ns))}</p><div class="monitor-checks" role="group" aria-label="Recent checks, oldest to newest">${checks.map((check, i) => `<button type="button" class="monitor-check" data-state="${check.state}" data-check="${i}" aria-label="${esc(check.label)}" aria-pressed="false">${check.state === 'healthy' ? '✓' : check.state === 'failing' ? '×' : '—'}</button>`).join('')}</div><div class="monitor-check-detail" aria-live="polite"></div>`;
    const buttons = [...host.querySelectorAll('[data-check]')], detail = host.querySelector('.monitor-check-detail');
    // Overlay intrinsic-sized panels so the tallest check reserves space before
    // hovering, including after wrapping at narrow Inspector widths.
    const panels = document.createElement('div');
    panels.className = 'monitor-check-panels';
    panels.setAttribute('aria-live', 'polite');
    detail.removeAttribute('aria-live');
    detail.replaceWith(panels);
    panels.append(detail);
    for (const check of checks) {
      const panel = document.createElement('div');
      panel.innerHTML = check.details;
      panel.inert = true;
      panel.setAttribute('aria-hidden', 'true');
      panels.append(panel);
    }
    let pinned = -1;
    const show = index => {
      buttons.forEach((button, i) => { button.classList.toggle('is-active', i === index); button.setAttribute('aria-pressed', String(i === pinned)); });
      [...panels.children].forEach((panel, i) => {
        const selected = i === index + 1;
        panel.classList.toggle('monitor-check-detail', selected);
        panel.inert = !selected;
        panel.setAttribute('aria-hidden', String(!selected));
      });
    };
    buttons.forEach((button, i) => {
      button.onpointerenter = event => { if (pinned < 0 && event.pointerType !== 'touch') show(i); };
      button.onpointerleave = () => { if (pinned < 0) show(-1); };
      button.onfocus = () => { if (pinned < 0) show(i); };
      button.onblur = () => { if (pinned < 0) show(-1); };
      button.onclick = () => { pinned = pinned === i ? -1 : i; show(pinned); };
      button.onkeydown = event => {
        if (event.key !== 'Escape') return;
        event.preventDefault(); event.stopPropagation(); pinned = -1; show(-1);
      };
    });
  }
  async function history(id, row, revision, victoria, signal, range) {
    const identity = row.identity;
    const query = new URLSearchParams({ from: new Date(range.from).toISOString(), to: new Date(range.to).toISOString(), resolution: 'raw', acceptance: 'all', identity });
    query.set('view', victoria ? 'chart' : 'checks');
    if (!victoria) { query.set('revision', String(revision)); query.set('sequence', row.sequence); }
    // URLSearchParams serializes to ASCII; the gateway limits the encoded query to 8192 bytes.
    if (query.toString().length > 8192) {
      for (const key of ['view', 'revision', 'sequence']) query.delete(key);
    }
    const response = await fetch(`/monitoring/history/${id}/inspector?${query}`, { signal, cache: 'no-store', headers: { 'X-NRC-Workspace': currentWorkspaceId } });
    if (!response.ok) throw new Error(response.status === 422 ? 'History range exceeds retained data or result limit. Use the CLI for a narrower range.' : `History unavailable (HTTP ${response.status}). Current NRC state is independent.`);
    const result = await response.json();
    if (result.version !== 1 || result.workspace !== currentWorkspaceId || result.monitor_id !== String(id) || result.kind !== 'inspector' || result.identity !== identity) throw new Error('History scope mismatch.');
    if (['runs', 'samples', 'uptime'].some(key => {
      const section = result.sections?.[key];
      const end = key === 'uptime' ? Math.floor(range.to / 300000) * 300000 : range.to;
      const start = key === 'uptime' ? end - 86400000 : range.from;
      return !section || ![200, 422].includes(section.status) || !Array.isArray(section.rows) || Date.parse(section.from) !== start || Date.parse(section.to) !== end || (section.status !== 200 && section.rows.length);
    })) throw new Error('Invalid Inspector history response.');
    return result;
  }
  function diagnostics(run, definition, revision, sequence, instanceRevision) {
    if (!run?.diagnostics) return '<p class="customer-empty">No per-condition diagnostics retained in this range.</p>';
    const current = run.acceptance === 'confirmed' && run.revision === String(revision) && run.revision === instanceRevision && run.sequence === String(sequence);
    const matched = run.revision === String(revision);
    const rows = run.diagnostics.conditions.map(row => {
      const condition = matched ? definition.conditions?.[row.index] : null;
      const expected = row.expected_number ?? (typeof condition?.value === 'number' ? 'numeric threshold (see CLI)' : JSON.stringify(condition?.value));
      const unit = condition ? conditionUnit(condition) : 'number';
      const formatted = unit !== 'number';
      const label = condition ? `${condition.field}${condition.path || ''} ${condition.op} ${formatted && row.expected_number != null ? formatValue(row.expected_number, unit) : expected}` : `Condition ${row.index + 1} (definition revision unavailable)`;
      const actual = formatted && row.actual_type === 'number' && !row.truncated ? formatValue(row.actual, unit) : `${row.actual ?? ''}${row.truncated ? '… (truncated)' : ''} [${row.actual_type}]`;
      return `<tr><td title="${esc(expected)}">${esc(label)}</td><td title="${esc(row.actual ?? '')}">${esc(row.actual_type ? actual : '—')}${row.reason ? `<br>${esc(row.reason)}` : ''}</td><td><span class="monitor-state" data-state="${esc(row.state)}" aria-hidden="true">${row.state === 'pass' ? '✓' : row.state === 'fail' ? '×' : '—'}</span> ${badge(row.state)}</td></tr>`;
    }).join('');
    return `<p class="customer-meta">${current ? 'MATCHES CURRENT EVALUATION' : 'HISTORICAL / NOT CURRENT'}${run.acceptance !== 'confirmed' ? ' · NOT CONFIRMED' : ''}</p>${run.diagnostics.error ? `<p>${esc(run.diagnostics.error)}</p>` : ''}<div class="monitor-conditions">${table(['CONDITION', 'OBSERVED', 'RESULT'], rows)}</div>`;
  }
  async function showInspector(ref, stillCurrent, { retryConfigChange = true, retired = false } = {}) {
    const token = ++detailGeneration, scope = currentWorkspaceId;
    historyController = new AbortController();
    const signal = historyController.signal;
    const valid = () => token === detailGeneration && scope === currentWorkspaceId && stillCurrent();
    const host = el('inspectorEntityHost'), header = el('inspectorHeader');
    header.innerHTML = `<div class="inspector-identity-row"><span class="header-text identity-reference">${ref.type.toUpperCase()} #${ref.id}</span><span class="inspector-cell-label">STATE</span><span class="status-value-mono inspector-state-value">READ</span></div><div class="inspector-mode-row">${window.NRCDetailUI.renderHeaderAction({ id: 'monitorDetailRefresh', label: 'REFRESH', command: 'refresh', title: 'Refresh record' })}${window.NRCDetailUI.renderCloseControl('monitorClose')}</div>`;
    el('monitorClose').onclick = () => window.NRCInspector.close();
    el('monitorDetailRefresh').onclick = () => showInspector(ref, stillCurrent);
    host.innerHTML = '<article class="customer-record monitor-record"><p class="customer-empty">Reading NRC…</p></article>';
    const record = host.firstElementChild;
    try {
      if (!ready()) throw new Error('Offline. Reconnect to read this record.');
      // Independent NRC reads share the first round trip. Capture failures now:
      // the asset may still be pending when the instance read is rejected.
      const assetRequest = assetRead(ref.id);
      let initialInstances = ref.type === 'monitor'
        ? statusQuery(String(ref.id), null, retired).then(page => ({ page }), error => ({ error }))
        : null;
      const asset = await assetRequest;
      if (!valid()) return;
      if (asset.assetType !== (ref.type === 'monitor' ? 15 : 16)) throw new Error('Record type changed.');
      const config = metadata(asset);
      if (ref.type === 'incident') {
        record.innerHTML = `<h2>${esc(config.title)}</h2>${badge(config.status)}${facts([['MONITOR', `#${config.monitor_id}`], ['INSTANCE', `#${config.instance_id}`], ['OPENED', stamp(config.opened_at)], ['CLOSED', stamp(config.closed_at)], ['ACKNOWLEDGED BY', config.acknowledged_by || '—'], ['ACKNOWLEDGED AT', stamp(config.acknowledged_at)], ['ASSIGNED TO', config.assigned_to || 'UNASSIGNED']])}
          <p>Acknowledging confirms ownership, not recovery. The monitor lifecycle determines when this incident closes.</p>
          <div class="customer-actions"><button class="btn" id="incidentAck" ${config.acknowledged_by ? 'disabled' : ''}>ACKNOWLEDGE</button><button class="btn" id="incidentMonitor">OPEN MONITOR</button></div>
          <form id="incidentAssignment" class="customer-fields"><label class="detail-edit-field">ASSIGNEE<input class="task-detail-input" name="assignee" value="${esc(config.assigned_to)}" placeholder="Exact identity; empty clears assignment"></label><button class="btn" type="submit">ASSIGN</button></form><p id="incidentResult" role="status"></p>`;
        el('incidentMonitor').onclick = () => open('monitor', config.monitor_id);
        const act = async (action, assignee = '') => {
          const bytes = new TextEncoder().encode(assignee);
          if (bytes.length > 32) { el('incidentResult').textContent = 'Assignee exceeds 32 UTF-8 bytes.'; return; }
          const view = new DataView(new ArrayBuffer(25 + bytes.length));
          view.setUint16(0, 70); view.setBigUint64(6, BigInt(ref.id)); view.setBigUint64(14, BigInt(asset.updatedAt)); view.setUint8(22, action); view.setUint16(23, bytes.length); new Uint8Array(view.buffer, 25).set(bytes);
          record.inert = true;
          try { await rpc(view.buffer, 176); if (valid()) { await showInspector(ref, stillCurrent); refresh(); } }
          catch (error) { if (valid()) el('incidentResult').textContent = `${error.message} Refresh before retrying; the action may have succeeded.`; }
          finally { record.inert = false; }
        };
        el('incidentAck').onclick = () => act(0);
        el('incidentAssignment').onsubmit = event => { event.preventDefault(); act(1, new FormData(event.target).get('assignee')); };
        return;
      }
      const definition = JSON.parse(asset.payload);
      const victoria = definition.kind === 'victoriametrics' || definition.kind === 'victorialogs';
      const numericConditions = (definition.conditions || []).flatMap((condition, index) => typeof condition.value === 'number' ? [{ condition, index }] : []);
      const conditionDisplay = numericConditions.length ? `<form id="monitorConditionDisplay" class="customer-fields">${numericConditions.map(({ condition, index }) => `<label class="detail-edit-field">${esc(condition.field + (condition.path || ''))}<select class="task-detail-input" data-condition-unit="${index}" aria-label="Display unit for ${esc(condition.field + (condition.path || ''))}">${Object.entries(conditionUnits).map(([value, label]) => `<option value="${value}"${conditionUnit(condition) === value ? ' selected' : ''}>${label}</option>`).join('')}</select></label>`).join('')}<button class="btn" type="submit">SAVE UNITS</button></form><p id="monitorUnitStatus" role="status"></p>` : '';
      const historyPanel = '<div id="monitorHistoryDetails"></div>';
      record.classList.add('monitor-inspector');
      header.querySelector('.identity-reference').textContent = `MONITOR / ${config.name}`;
      record.innerHTML = `<div class="monitor-console"><aside class="monitor-rail" aria-label="Selected instance"><h3 class="monitor-subheading">SELECTED INSTANCE</h3><div id="monitorSelection"></div><p class="monitor-no-selection">Select an instance.</p><p id="monitorHistoryStatus" class="customer-meta" role="status"></p><div id="monitorUptime" hidden></div></aside>
        <div class="monitor-evidence"><h2>${esc(config.name)}</h2><p class="customer-meta">${esc(definition.kind.toUpperCase())} · EVERY ${esc(config.interval_ns / 1e9)}s${config.timeout_ns ? ` · TIMEOUT ${esc(config.timeout_ns / 1e9)}s` : ''} · ${config.enabled ? 'ENABLED' : 'DISABLED'}</p>${victoria ? `<details class="monitor-query"><summary>QUERY</summary><pre class="monitor-rule">${esc(definition.query)}</pre></details>` : `<pre class="monitor-rule">${esc(definition.url || definition.address)}</pre>`}
        ${victoria ? `<form id="monitorDisplay" class="customer-fields"><label class="detail-edit-field">DISPLAY UNIT<select id="monitorUnit" class="task-detail-input">${Object.entries(displayUnits).map(([value, label]) => `<option value="${value}"${(config.unit || 'number') === value ? ' selected' : ''}>${label}</option>`).join('')}</select></label><button class="btn" type="submit">SAVE UNIT</button></form><p id="monitorUnitStatus" role="status"></p>` : ''}
        ${section('INSTANCES · CURRENT NRC STATE', '<div class="monitor-instance-toolbar"><span id="monitorInstanceStatus" role="status"></span><label><input id="monitorRetired" type="checkbox"> INCLUDE RETIRED</label></div><div id="monitorInstances"></div><button class="btn" id="monitorInstanceMore" hidden>MORE INSTANCES</button>')}
        ${victoria ? historyPanel : ''}
        ${section(victoria ? 'VALUE & THRESHOLDS' : definition.conditions?.length ? 'CONDITIONS · ALL MUST PASS' : 'EVALUATION RESULT', `${conditionDisplay}<div id="monitorHistory"><p class="customer-empty">Select an instance.</p></div><h3 class="monitor-subheading">ALARM THRESHOLDS</h3><dl class="monitor-thresholds"><div><dt>TRIGGER</dt><dd>${config.failures} failures</dd></div><div><dt>RESOLVE</dt><dd>${config.recoveries} successes</dd></div><div><dt>MISSING</dt><dd>${config.missing} absent evaluations</dd></div></dl>`)}
        </div></div>${victoria ? '' : historyPanel}`;
      el('monitorRetired').checked = retired;
      if (victoria || numericConditions.length) el(victoria ? 'monitorDisplay' : 'monitorConditionDisplay').onsubmit = async event => {
        event.preventDefault();
        const form = event.currentTarget;
        const unit = victoria ? el('monitorUnit').value : null;
        if (victoria ? unit === (config.unit || 'number') : numericConditions.every(({ condition, index }) => form.querySelector(`[data-condition-unit="${index}"]`).value === conditionUnit(condition))) return;
        form.inert = true;
        try {
          // Preserve exact decimal tokens in both policy and check definitions.
          const exact = (_key, value, context) => typeof value === 'number' ? JSON.rawJSON(context.source) : value;
          const preview = victoria ? JSON.stringify({ ...JSON.parse(asset.preview, exact), unit }) : null;
          let payload = null;
          if (!victoria) {
            const check = JSON.parse(asset.payload, exact);
            for (const { index } of numericConditions) check.conditions[index].unit = form.querySelector(`[data-condition-unit="${index}"]`).value;
            payload = JSON.stringify(check);
          }
          await new Promise((resolve, reject) => {
            if (!window.NRCTransactions.sendAssetMetadataPatch(asset, preview, payload, {
              onSuccess: resolve, onError: detail => reject(new Error(detail.message || 'Save unconfirmed')),
            })) reject(new Error('Not connected. Nothing sent.'));
          });
          if (valid()) { await showInspector(ref, stillCurrent); refresh(); }
        } catch (error) {
          if (valid()) el('monitorUnitStatus').textContent = `${error.message} · Refresh and check the saved unit before retrying.`;
        } finally { form.inert = false; }
      };
      let instancePage, instances = [], instanceGeneration = 0, historyGeneration = 0, instancesLoading = false, selectedInstance = null;
      const loadInstances = async (more = false) => {
        if (more && (instancesLoading || !instancePage?.has_more)) return;
        const local = ++instanceGeneration;
        instancesLoading = true;
        el('monitorInstanceMore').disabled = true;
        if (!more) {
          instancePage = null; instances = []; historyGeneration++;
          selectedInstance = null; el('monitorSelection').replaceChildren();
          el('monitorHistoryStatus').textContent = '';
          el('monitorUptime').replaceChildren(); el('monitorUptime').hidden = true; el('monitorHistoryDetails').replaceChildren();
          el('monitorInstances').replaceChildren();
          el('monitorInstanceMore').hidden = true;
          el('monitorHistory').textContent = 'Select an instance to read history. Missing history is not healthy time.';
        }
        el('monitorInstanceStatus').textContent = 'Reading NRC…';
        try {
          const initial = initialInstances;
          initialInstances = null;
          const result = initial ? await initial : null;
          if (result?.error) throw result.error;
          const readPage = () => statusQuery(String(ref.id), more ? instancePage : null, el('monitorRetired').checked);
          let next = result ? result.page : await readPage();
          if (!valid() || local !== instanceGeneration) return;
          let configRevision = next.config_revision;
          if (configRevision === undefined) {
            // Older servers omit the fence. Bracket the page read with asset reads.
            if (result) next = await readPage();
            if (!valid() || local !== instanceGeneration) return;
            configRevision = String((await assetRead(ref.id)).updatedAt);
            if (!valid() || local !== instanceGeneration) return;
          }
          if (configRevision !== String(asset.updatedAt)) {
            if (retryConfigChange) return showInspector(ref, stillCurrent, { retryConfigChange: false, retired: el('monitorRetired').checked });
            historyGeneration++;
            record.textContent = 'Monitor configuration changed while loading. Refresh to read the current state.';
            return;
          }
          instancePage = next; instances = more ? [...instances, ...next.rows] : next.rows;
          const single = instances.length === 1 && !next.has_more;
          el('monitorInstances').hidden = single;
          el('monitorInstances').closest('section').querySelector('header').hidden = single;
          el('monitorInstances').classList.add('monitor-instance-list');
          el('monitorInstances').innerHTML = table(['INSTANCE', 'STATE', 'VALUE', 'INCIDENT'], instances.map((row, index) => `<tr${selectedInstance === row.id ? ' class="monitor-selected"' : ''}><td><button class="task-row-open" data-instance="${index}" aria-pressed="${selectedInstance === row.id}" title="${esc(row.identity)}">${instanceLabel(row.identity, true)}</button></td><td>${badge(row.status)}</td><td title="${esc(row.value ?? '—')}">${esc(formatValue(row.value, config.unit))}</td><td>${row.incident_id !== '0' ? `<button class="task-row-open monitor-incident-link" data-incident="${esc(row.incident_id)}" aria-label="Open incident #${esc(row.incident_id)}">#${esc(row.incident_id)}</button>` : '—'}</td></tr>`).join(''));
          el('monitorInstanceStatus').textContent = single ? '1 INSTANCE' : `${instances.length} LOADED · ${instances.filter(r => r.status === 'firing').length} FIRING · ${instances.filter(r => r.status === 'failing').length} PENDING${next.has_more ? ' · MORE AVAILABLE' : ''}`;
          el('monitorInstances').querySelector('table').insertAdjacentHTML('afterbegin', '<colgroup><col><col><col><col></colgroup>');
          el('monitorInstanceStatus').title = `AS OF ${stamp(next.at)}`;
          el('monitorInstanceMore').hidden = !next.has_more;
          if (selectedInstance === null && instances.length) void selectInstance(0);
        } catch (error) { if (valid() && local === instanceGeneration) el('monitorInstanceStatus').textContent = `${error.message} · DISPLAYED ROWS MAY BE STALE`; }
        finally {
          if (valid() && local === instanceGeneration && el('monitorInstanceMore')) {
            instancesLoading = false;
            el('monitorInstanceMore').disabled = false;
          }
        }
      };
      el('monitorRetired').onchange = () => loadInstances();
      el('monitorInstanceMore').onclick = () => loadInstances(true);
      const selectInstance = async index => {
        const row = instances[index], local = ++historyGeneration;
        selectedInstance = row.id;
        for (const item of el('monitorInstances').querySelectorAll('[data-instance]')) {
          const selected = Number(item.dataset.instance) === index;
          item.setAttribute('aria-pressed', String(selected)); item.closest('tr').classList.toggle('monitor-selected', selected);
        }
        const identity = `<h3>${instanceLabel(row.identity, true)}</h3>`;
        el('monitorSelection').innerHTML = `${identity}<p>${badge(row.status)}${row.incident_id !== '0' ? `<button class="task-row-open" data-incident="${esc(row.incident_id)}">INCIDENT #${esc(row.incident_id)}</button>` : 'NO ACTIVE INCIDENT'}</p><div class="monitor-reading" title="${esc(row.value ?? '—')}"><span class="customer-meta">LAST OBSERVED VALUE</span><strong>${esc(formatValue(row.value, config.unit))}</strong></div><div class="monitor-streaks">${streak('FAIL', row.failures, config.failures, 'fail')}${streak('RECOVER', row.recoveries, config.recoveries, 'pass')}</div>`;
        const target = el('monitorHistory');
        if (victoria) {
          const threshold = rule => rule ? `${esc(rule.op)} ${esc(formatValue(rule.value, config.unit))}` : 'When trigger no longer matches';
          el('monitorSelection').querySelector('.monitor-reading').insertAdjacentHTML('afterend', `<dl class="monitor-thresholds" aria-label="Current configuration thresholds"><div><dt>TRIGGER</dt><dd>${threshold(definition.trigger)}</dd></div><div><dt>RECOVERY</dt><dd>${threshold(definition.recovery)}</dd></div></dl>`);
          target.innerHTML = `${row.revision !== String(asset.updatedAt) ? '<p class="customer-meta">CONFIGURATION CHANGED · VALUE FROM PREVIOUS REVISION</p>' : ''}${valueScale(row, definition, asset.updatedAt, config.unit)}<p class="customer-meta">LAST SEEN ${esc(stamp(row.seen_at))} · CURRENT CONFIGURATION THRESHOLDS</p>`;
        } else target.textContent = 'Reading history…';
        el('monitorUptime').replaceChildren(); el('monitorUptime').hidden = true; el('monitorHistoryDetails').replaceChildren();
        const key = JSON.stringify([scope, String(ref.id), String(asset.updatedAt), row.identity]);
        const cached = inspectorHistory.get(key);
        const usable = cached && Date.now() - cached.at < historyMaxAge;
        const renderHistory = (result, previous = false) => {
          const { runs: attempts, samples: sample, uptime } = result.sections;
          const range = { from: Date.parse(sample.from), to: Date.parse(sample.to) };
          const limit = 'History section exceeds retention or result limits. Use the CLI for a narrower range.';
          const run = attempts.rows.findLast(r => r.acceptance === 'confirmed' && r.revision === String(asset.updatedAt) && r.sequence === row.sequence) || attempts.rows.at(-1);
          if (!victoria) target.innerHTML = attempts.status === 200 ? diagnostics(run, definition, asset.updatedAt, previous ? null : row.sequence, row.revision) : `<p>${limit}</p>`;
          const observations = sample.status !== 200 ? `<p>${limit}</p>` : victoria ? sampleChart(sample.rows, definition, asset.updatedAt, config.interval_ns, range, config.unit) : '<div class="monitor-recent-checks"></div>';
          el('monitorHistoryDetails').innerHTML = section(victoria ? 'HISTORY · LAST HOUR' : 'RECENT CHECKS · LAST HOUR', `${observations}${result.dropped_process_total !== '0' ? `<p class="customer-meta">PROCESS HISTORY DROPS: ${esc(result.dropped_process_total)}</p>` : ''}`);
          if (victoria) bindSampleChart(el('monitorHistoryDetails'));
          else if (sample.status === 200) recentChecks(el('monitorHistoryDetails').querySelector('.monitor-recent-checks'), sample.rows, attempts.rows, definition, asset.updatedAt, range);
          el('monitorUptime').hidden = false;
          if (uptime.status !== 200) el('monitorUptime').textContent = limit;
          else {
            const revisionRows = uptime.rows.filter(r => r.revision === String(asset.updatedAt));
            const totals = revisionRows.reduce((s, r) => { for (const k of Object.keys(s)) s[k] += BigInt(r[k]); return s; }, { healthy_ns: 0n, failing_ns: 0n, unknown_ns: 0n, paused_ns: 0n });
            const known = totals.healthy_ns + totals.failing_ns;
            const pct = (n, d) => d ? `${Number(n * 10000n / d) / 100}%` : 'UNKNOWN';
            const meter = (label, n, d, kind) => {
              const value = pct(n, d);
              return `<div><dt>${label}</dt><dd>${value}<div class="monitor-meter" data-kind="${kind}" data-known="${d > 0n}" role="img" aria-label="${label}: ${value}" style="--fill:${d > 0n ? Math.max(0, Math.min(100, Number(n * 10000n / d) / 100)) : 0}%"><span></span></div></dd></div>`;
            };
            el('monitorUptime').innerHTML = `<dl class="customer-facts monitor-metrics">${meter(`24H ${definition.kind.startsWith('victoria') ? 'CONDITION SATISFACTION' : 'UPTIME'} OF KNOWN TIME`, totals.healthy_ns, known, 'uptime')}${meter('24H COVERAGE', known, 86400000000000n - totals.paused_ns, 'coverage')}</dl>`;
          }
        };
        if (usable) renderHistory(cached.result, true);
        else inspectorHistory.delete(key);
        el('monitorHistoryStatus').textContent = usable ? 'HISTORY UPDATING · PREVIOUS RESULT' : 'Reading history…';
        // Cache hits render immediately, but refreshes still share only one
        // Inspector slot. Waiting selections skip requests when superseded.
        const previous = inspectorHistoryTail;
        let release;
        inspectorHistoryTail = new Promise(resolve => { release = resolve; });
        await previous;
        try {
          if (!valid() || local !== historyGeneration) return;
          const to = Date.now(), range = { from: to - hour, to };
          const result = await history(ref.id, row, asset.updatedAt, victoria, signal, range);
          if (!valid() || local !== historyGeneration) return;
          renderHistory(result);
          el('monitorHistoryStatus').textContent = '';
          // Bound memory to eight <=4 MiB responses; refresh every selection.
          inspectorHistory.delete(key);
          inspectorHistory.set(key, { result, at: Date.now() });
          while (inspectorHistory.size > 8) inspectorHistory.delete(inspectorHistory.keys().next().value);
        } catch (error) {
          if (valid() && local === historyGeneration) el('monitorHistoryStatus').textContent = `${error.message}${usable ? ' · PREVIOUS RESULT · UPDATE FAILED' : ''}`;
        }
        finally { release(); }
      };
      el('monitorInstances').onclick = event => {
        const incident = event.target.closest('[data-incident]');
        if (incident) { open('incident', incident.dataset.incident); return; }
        const button = event.target.closest('[data-instance]');
        if (button) void selectInstance(Number(button.dataset.instance));
      };
      el('monitorSelection').onclick = event => {
        const incident = event.target.closest('[data-incident]');
        if (incident) open('incident', incident.dataset.incident);
      };
      await loadInstances();
    } catch (error) { if (valid()) record.textContent = error.message; }
  }
  function disconnect() {
    clearTimeout(searchTimer);
    generation++; detailGeneration++; registerHistory.clear(); inspectorHistory.clear();
    for (const request of pending.values()) { clearTimeout(request.timeout); request.reject(new Error('Disconnected.')); }
    pending.clear(); rows = []; page = null; loading = false;
    if (el('monitorStatus')) el('monitorStatus').textContent = 'OFFLINE'; render();
    if (['monitor', 'incident'].includes(window.NRCInspector?.current()?.type)) el('inspectorEntityHost').textContent = 'Offline. Reopen this record after reconnecting.';
  }
  function init() {
    clearInterval(refreshTimer);
    refreshTimer = setInterval(() => void refresh(false, true), 30000);
    el('monitoringBtn').onclick = () => window.NRCViewManager.setActiveView('monitoring');
    for (const [id, value] of [['monitorStatusTab', 'status'], ['monitorIncidentsTab', 'incidents']]) el(id).onclick = () => { tab = value; rows = []; page = null; refresh(); };
    el('monitorRefresh').onclick = () => refresh();
    el('monitorRegisterScroll').addEventListener('scroll', loadMoreNearEnd, { passive: true });
    new ResizeObserver(loadMoreNearEnd).observe(el('monitorRegisterScroll'));
    const filtersChanged = (delay = 0) => {
      clearTimeout(searchTimer);
      if (tab !== 'status') { render(); return; }
      generation++; rows = []; page = null; statusPages = 1; loading = true;
      render();
      searchTimer = setTimeout(() => refresh(), delay);
    };
    el('monitorSearch').oninput = () => filtersChanged(250);
    el('monitorStateFilter').onchange = () => filtersChanged();
    el('monitorPeriods').onclick = event => {
      const button = event.target.closest('[data-monitor-days]');
      if (!button || Number(button.dataset.monitorDays) === period) return;
      period = Number(button.dataset.monitorDays);
      for (const item of el('monitorPeriods').children) {
        const selected = item === button;
        item.classList.toggle('active', selected); item.setAttribute('aria-pressed', String(selected));
      }
      const token = ++generation;
      registerController = new AbortController(); registerHistory.clear();
      // A period change supersedes a pending status read as well.
      if (loading) { refresh(); return; }
      render();
      if (ready() && tab === 'status') void loadRegisterHistory(token, currentWorkspaceId, rows, registerController);
    };
    el('monitorList').onclick = event => {
      const period = event.target.closest('button.monitor-history-bar');
      if (period) {
        const cell = period.closest('.monitor-history-cell');
        const selected = period.getAttribute('aria-pressed') !== 'true';
        for (const bar of cell.querySelectorAll('.monitor-history-bar')) bar.setAttribute('aria-pressed', String(selected && bar === period));
        const detail = cell.querySelector('.monitor-history-detail');
        detail.hidden = !selected;
        detail.replaceChildren(period.querySelector('.monitor-history-fill').cloneNode(true), document.createTextNode(`${period.getAttribute('aria-label')} · TIME SHARES, NOT EVENT ORDER`));
        return;
      }
      if (event.target.closest('button, input, select, textarea, a') && !event.target.closest('.task-row-open')) return;
      const button = event.target.closest('tbody tr')?.querySelector('[data-monitor], [data-incident]');
      if (button) open(button.dataset.monitor ? 'monitor' : 'incident', button.dataset.monitor || button.dataset.incident);
    };
  }
  return { init, refresh, handlePage, handleError, showInspector, disconnect, readOpenIncidents,
    onViewChanged(view) { if (view === 'monitoring') refresh(); else { generation++; loading = false; } },
  };
})();
