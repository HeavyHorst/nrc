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
  const registerHistory = new Map();
  const hour = 3600000;
  const percent = (n, d) => d > 0n ? `${Number(n * 10000n / d) / 100}%` : 'UNKNOWN';

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
      const state = b.failing > 0n ? 'failing' : capacity > 0n && b.paused === capacity ? 'paused' : known > 0n && known + b.paused === capacity ? 'healthy' : 'unknown';
      const label = `${new Date(range.from + i * width).toLocaleString()} – ${new Date(range.from + (i + 1) * width).toLocaleString()}: ${state.toUpperCase()} · uptime / satisfaction ${percent(b.healthy, known)} · coverage ${percent(known, capacity - b.paused)}`;
      return `<span class="monitor-history-bar" data-state="${state}" role="img" aria-label="${esc(label)}" title="${esc(label)}"></span>`;
    }).join('');
    const pending = result.pending_rollup_hours_global !== '0';
    return {
      trail: `<div class="monitor-history-bars" style="--monitor-bars:${count}" aria-label="${count} completed ${width === hour ? 'hours' : '24-hour periods'}, oldest first">${bars}</div><span class="customer-meta">${esc(new Date(range.from).toLocaleString())} – ${esc(new Date(range.to).toLocaleString())}${pending ? ' · ROLLUPS PENDING (GLOBAL)' : ''}</span>`,
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
    // One register read at a time leaves the gateway's other slot for the Inspector.
    for (const row of snapshot) {
      if (!valid()) return;
      let display;
      try {
        const result = await history(row.id, 'uptime', null, AbortSignal.any([controller.signal, AbortSignal.timeout(8000)]), range);
        display = availability(result, row.revision, range);
      } catch (error) {
        display = { trail: `<span class="customer-meta">${esc(error.message)}</span>`, metrics: 'UNAVAILABLE' };
      }
      if (!valid()) return;
      registerHistory.set(row.id, display);
      const cells = el('monitorList').querySelectorAll('[data-history-monitor]');
      for (const cell of cells) if (cell.dataset.historyMonitor === row.id) cell.innerHTML = display[cell.dataset.historyPart];
    }
    } finally { release(); }
  }
  function rpc(buffer, response) {
    if (!ready()) return Promise.reject(new Error('Offline. Reconnect before reading or changing state.'));
    const id = getRpcCorrelationId();
    new DataView(buffer).setUint32(2, id);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { pending.delete(id); reject(new Error('No response. Refresh before retrying an action.')); }, 15000);
      pending.set(id, { resolve, reject, timeout, response, subject: String(new DataView(buffer).getBigUint64(6)) });
      sendPacket(buffer);
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
        if (page.version !== 1 || page.monitor_id !== request.subject || !Array.isArray(page.rows) || page.rows.length > 16) throw new Error('Invalid status page.');
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
  function statusQuery(id = '0', cursor = null, retired = false) {
    const view = new DataView(new ArrayBuffer(33));
    view.setUint16(0, 73); view.setBigUint64(6, BigInt(id));
    view.setBigUint64(14, BigInt(cursor?.cursor_id || '0')); view.setUint8(22, cursor?.cursor_rank || 0);
    view.setBigUint64(23, BigInt(cursor?.at || '0')); view.setUint8(31, 16); view.setUint8(32, Number(retired));
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
  function render() {
    if (!el('monitorList')) return;
    el('monitorList').setAttribute('aria-busy', String(loading));
    el('monitorHistoryLegend').hidden = tab !== 'status';
    el('monitorMore').hidden = !page?.has_more || tab !== 'status';
    el('monitorMore').disabled = loading;
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
      const m = tab === 'status' ? row : metadata(row);
      const text = tab === 'status' ? `${row.name} #${row.id}` : `${m.title} #${row.assetId} #${m.monitor_id}`;
      return text.toLowerCase().includes(query) && (tab !== 'status' || filter === 'all' || (filter === 'problems' ? ['firing', 'failing', 'error', 'no_data', 'unknown', 'between'].includes(m.status) : m.status === filter));
    });
    const counts = tab === 'status' ? visible.reduce((s, row) => s.map((n, i) => n + row.counts[i]), Array(9).fill(0)) : null;
    el('monitorSummary').textContent = tab === 'status'
      ? `SHOWN: ${visible.length} / ${rows.length} LOADED MONITORS · ${counts.reduce((a, b) => a + b, 0)} INSTANCES · ${counts[0]} FIRING · ${counts[1]} PENDING${page?.has_more ? ' · MORE MONITORS AVAILABLE' : ''}`
      : `SHOWN: ${visible.length} / ${rows.length} LOADED INCIDENTS · ${visible.filter(a => metadata(a).status === 'firing').length} FIRING`;
    el('monitorList').innerHTML = visible.length ? tab === 'status' ? table(['MONITOR / INSTANCES', 'CURRENT STATE', `HISTORY · ${period === 1 ? '24H' : `${period}D`}`, 'UPTIME / SATISFACTION'], visible.map(row => `<tr><td><button class="task-row-open" data-monitor="${esc(row.id)}">${esc(row.name)}</button><span class="customer-meta">#${esc(row.id)} · ${row.counts.reduce((a, b) => a + b, 0)} instances · ${row.counts[0]} firing</span></td><td>${badge(row.status)}<span class="customer-meta">${esc(stamp(row.evaluated_at))}</span></td><td class="monitor-history-cell" data-history-monitor="${esc(row.id)}" data-history-part="trail">${registerHistory.get(row.id)?.trail || '<span class="customer-meta">Reading history…</span>'}</td><td data-history-monitor="${esc(row.id)}" data-history-part="metrics">${registerHistory.get(row.id)?.metrics || '—'}</td></tr>`).join('')) :
      table(['INCIDENT', 'STATE', 'ACKNOWLEDGED', 'ASSIGNEE'], visible.map(asset => { const m = metadata(asset); return `<tr><td><button class="task-row-open" data-incident="${asset.assetId}">${esc(m.title)}</button><span class="customer-meta">#${asset.assetId} · MONITOR #${esc(m.monitor_id)}</span></td><td>${badge(m.status)}</td><td>${esc(m.acknowledged_by || 'NOT ACKNOWLEDGED')}</td><td>${esc(m.assigned_to || 'UNASSIGNED')}</td></tr>`; }).join('')) :
      `<p class="customer-empty">${loading ? 'Reading NRC…' : rows.length ? 'No matching loaded records. Filters apply to loaded records only.' : 'No records loaded.'}</p>`;
  }
  async function refresh(more = false) {
    if (!active()) return;
    const token = ++generation;
    registerController = new AbortController();
    registerHistory.clear();
    loading = true; el('monitorStatus').textContent = ready() ? 'READING NRC' : 'OFFLINE'; render();
    try {
      if (!ready()) throw new Error('Offline. Reconnect to read current state.');
      if (tab === 'status') {
        const next = await statusQuery('0', more ? page : null);
        if (token !== generation) return;
        page = next; rows = more ? [...rows, ...next.rows] : next.rows;
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
    } catch (error) { if (token === generation) el('monitorStatus').textContent = `${error.message} · DISPLAYED ROWS MAY BE STALE`; }
    finally {
      if (token === generation) {
        loading = false; render();
        if (tab === 'status' && ready()) void loadRegisterHistory(token, currentWorkspaceId, rows, registerController);
      }
    }
  }
  function open(type, id) { window.NRCInspector.openEntity({ type, id: BigInt(id) }, { replaceCurrent: window.NRCInspector.current()?.type === type }); }
  function valueScale(row, definition, revision) {
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
    return `<svg class="monitor-value-scale" viewBox="0 0 480 ${bottom + 6}" role="img" aria-label="Relative scale: value ${esc(row.value)}, trigger ${esc(definition.trigger.op)} ${esc(definition.trigger.value)}${definition.recovery ? `, recovery ${esc(definition.recovery.op)} ${esc(definition.recovery.value)}` : ''}. Current revision; not a lifecycle status.">${lanes}<text x="112" y="${bottom}" text-anchor="start">${Number(low.toPrecision(4))}</text><text x="448" y="${bottom}" text-anchor="end">${Number(high.toPrecision(4))}</text><text x="280" y="${bottom}" text-anchor="middle">RELATIVE SCALE</text></svg>`;
  }
  function sampleChart(rows, definition, revision, interval, range) {
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
      const label = `${stamp(row.observed_at_ns)} · ${row.value}${confirmed ? '' : ` · NOT CONFIRMED: ${row.acceptance}`}`;
      const attrs = `data-point="${index}" data-x="${x(row.at)}"`;
      return confirmed ? `<circle ${attrs} class="${!connected.has(row) || index === points.length - 1 ? 'monitor-chart-endpoint' : ''}" cx="${x(row.at)}" cy="${y(row.value)}" r="3"><title>${esc(label)}</title></circle>` : `<rect ${attrs} x="${x(row.at) - 3}" y="${y(row.value) - 3}" width="6" height="6" transform="rotate(45 ${x(row.at)} ${y(row.value)})"><title>${esc(label)}</title></rect>`;
    }).join('');
    const ticks = [low, (low + high) / 2, high].map(v => `<text x="54" y="${y(v * scale) + 4}" text-anchor="end">${Number((v * scale).toPrecision(3))}</text>`).join('');
    const lines = thresholds.map(t => `<line data-threshold="${t.key}" x1="64" x2="464" y1="${y(Number(t.value))}" y2="${y(Number(t.value))}"/>`).join('');
    const times = [range.from, (range.from + range.to) / 2, range.to].map((at, i) => `<text x="${x(at)}" y="195" text-anchor="${['start', 'middle', 'end'][i]}">${esc(new Date(at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }))}</text>`).join('');
    for (const t of omitted) thresholds.push({ ...t, value: 'outside browser numeric range; not plotted' });
    return `<div class="monitor-timeseries"><p class="monitor-chart-readout" aria-live="polite">Hover or tap for values</p><svg viewBox="0 0 480 210" tabindex="0" role="group" aria-label="Last hour, current revision: ${points.length} samples. Use arrow keys to inspect values, Escape to clear. Hollow diamonds are not confirmed. Gaps are not interpolated."><path class="monitor-chart-axis" d="M64,20V168H464"/>${ticks}${times}${lines}<path class="monitor-chart-trace" d="${trace}"/><path class="monitor-chart-guide"/><g class="monitor-chart-points">${markers}</g></svg><div class="monitor-chart-legend"><span>─ VALUE</span>${thresholds.map(t => `<span data-threshold="${t.key}">┄ ${t.key.toUpperCase()} ${esc(t.op)} ${esc(t.value)}</span>`).join('')}<span>◇ NOT CONFIRMED</span></div><p class="customer-meta">CURRENT REVISION · GAPS &gt; ${Number(interval) / 1e9 * 1.5}s</p></div>`;
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
  async function history(id, kind, identity, signal, range = null) {
    const to = kind === 'uptime' ? Math.floor(Date.now() / 300000) * 300000 : Date.now();
    const query = new URLSearchParams({ from: new Date(range?.from ?? to - (kind === 'uptime' ? 86400000 : 3600000)).toISOString(), to: new Date(range?.to ?? to).toISOString(), resolution: range?.resolution ?? (kind === 'uptime' ? '5m' : 'raw') });
    if (kind !== 'uptime') query.set('acceptance', 'all');
    if (identity && kind !== 'runs') query.set('identity', identity);
    const response = await fetch(`/monitoring/history/${id}/${kind}?${query}`, { signal, cache: 'no-store', headers: { 'X-NRC-Workspace': currentWorkspaceId } });
    if (!response.ok) throw new Error(response.status === 422 ? 'History range exceeds retained data or result limit. Use the CLI for a narrower range.' : `History unavailable (HTTP ${response.status}). Current NRC state is independent.`);
    const result = await response.json();
    if (result.version !== 1 || result.workspace !== currentWorkspaceId || result.monitor_id !== String(id) || !Array.isArray(result.rows)) throw new Error('History scope mismatch.');
    return result;
  }
  function diagnostics(run, definition, revision, sequence, instanceRevision) {
    if (!run?.diagnostics) return '<p class="customer-empty">No per-condition diagnostics retained in this range.</p>';
    const current = run.acceptance === 'confirmed' && run.revision === String(revision) && run.revision === instanceRevision && run.sequence === String(sequence);
    const matched = run.revision === String(revision);
    const rows = run.diagnostics.conditions.map(row => {
      const condition = matched ? definition.conditions?.[row.index] : null;
      const expected = row.expected_number ?? (typeof condition?.value === 'number' ? 'numeric threshold (see CLI)' : JSON.stringify(condition?.value));
      const label = condition ? `${condition.field}${condition.path || ''} ${condition.op} ${expected}` : `Condition ${row.index + 1} (definition revision unavailable)`;
      return `<tr><td>${esc(label)}</td><td>${esc(row.actual_type ? `${row.actual ?? ''}${row.truncated ? '… (truncated)' : ''} [${row.actual_type}]` : '—')}${row.reason ? `<br>${esc(row.reason)}` : ''}</td><td><span class="monitor-state" data-state="${esc(row.state)}" aria-hidden="true">${row.state === 'pass' ? '✓' : row.state === 'fail' ? '×' : '—'}</span> ${badge(row.state)}</td></tr>`;
    }).join('');
    return `<p class="customer-meta">${current ? 'MATCHES CURRENT EVALUATION' : 'HISTORICAL / NOT CURRENT'}${run.acceptance !== 'confirmed' ? ' · NOT CONFIRMED' : ''}</p>${run.diagnostics.error ? `<p>${esc(run.diagnostics.error)}</p>` : ''}<div class="monitor-conditions">${table(['CONDITION', 'OBSERVED', 'RESULT'], rows)}</div>`;
  }
  async function showInspector(ref, stillCurrent) {
    const token = ++detailGeneration, scope = currentWorkspaceId;
    historyController = new AbortController();
    const signal = historyController.signal;
    const valid = () => token === detailGeneration && scope === currentWorkspaceId && stillCurrent();
    const host = el('inspectorEntityHost'), header = el('inspectorHeader');
    header.innerHTML = `<div class="inspector-identity-row"><span class="header-text identity-reference">${ref.type.toUpperCase()} #${ref.id}</span><span class="inspector-cell-label">STATE</span><span class="status-value-mono inspector-state-value">READ</span></div><div class="inspector-mode-row"><button class="btn" id="monitorDetailRefresh">REFRESH</button>${window.NRCDetailUI.renderCloseControl('monitorClose')}</div>`;
    el('monitorClose').onclick = () => window.NRCInspector.close();
    el('monitorDetailRefresh').onclick = () => showInspector(ref, stillCurrent);
    host.innerHTML = '<article class="customer-record monitor-record"><p class="customer-empty">Reading NRC…</p></article>';
    const record = host.firstElementChild;
    try {
      if (!ready()) throw new Error('Offline. Reconnect to read this record.');
      const asset = await assetRead(ref.id);
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
      record.classList.add('monitor-inspector');
      header.querySelector('.identity-reference').textContent = `MONITOR / ${config.name}`;
      record.innerHTML = `<h2>CURRENT STATE: ${esc(config.name)}</h2><p class="customer-meta">${esc(definition.kind.toUpperCase())} · EVERY ${esc(config.interval_ns / 1e9)}s${config.timeout_ns ? ` · TIMEOUT ${esc(config.timeout_ns / 1e9)}s` : ''} · ${config.enabled ? 'ENABLED' : 'DISABLED'}</p><pre class="monitor-rule">${esc(definition.query || definition.url || definition.address)}</pre>
        ${section('INSTANCES · CURRENT NRC STATE', '<div class="monitor-instance-toolbar"><span id="monitorInstanceStatus" role="status"></span><label><input id="monitorRetired" type="checkbox"> INCLUDE RETIRED</label></div><div id="monitorInstances"></div><button class="btn" id="monitorInstanceMore" hidden>MORE INSTANCES</button>')}
        <div id="monitorSelection"></div>
        ${section(victoria ? 'VALUE & THRESHOLDS' : definition.conditions?.length ? 'CONDITIONS · ALL MUST PASS' : 'EVALUATION RESULT', `<div id="monitorHistory"><p class="customer-empty">Select an instance.</p></div><h3 class="monitor-subheading">ALARM THRESHOLDS</h3><dl class="monitor-thresholds"><div><dt>TRIGGER</dt><dd>${config.failures} failures</dd></div><div><dt>RESOLVE</dt><dd>${config.recoveries} successes</dd></div><div><dt>MISSING</dt><dd>${config.missing} absent evaluations</dd></div></dl>`)}
        ${section('HISTORY & AVAILABILITY', '<div id="monitorUptime" hidden></div><div id="monitorHistoryDetails"></div>')}
        <section class="monitor-footer">${facts([['MONITOR ID', String(ref.id)], ['REVISION', String(asset.updatedAt)]])}<p class="customer-meta">CLI MANAGED · WEBHOOK ROUTE IDS: ${esc(config.webhooks?.join(', ') || 'NONE')} · Delivery state is not shown here.</p></section>`;
      let instancePage, instances = [], instanceGeneration = 0, historyGeneration = 0, instancesLoading = false, selectedInstance = null;
      const loadInstances = async (more = false) => {
        if (more && (instancesLoading || !instancePage?.has_more)) return;
        const local = ++instanceGeneration;
        instancesLoading = true;
        el('monitorInstanceMore').disabled = true;
        if (!more) {
          instancePage = null; instances = []; historyGeneration++;
          selectedInstance = null; el('monitorSelection').replaceChildren();
          el('monitorUptime').replaceChildren(); el('monitorUptime').hidden = true; el('monitorHistoryDetails').replaceChildren();
          el('monitorInstances').replaceChildren();
          el('monitorInstanceMore').hidden = true;
          el('monitorHistory').textContent = 'Select an instance to read history. Missing history is not healthy time.';
        }
        el('monitorInstanceStatus').textContent = 'Reading NRC…';
        try {
          const next = await statusQuery(String(ref.id), more ? instancePage : null, el('monitorRetired').checked);
          if (!valid() || local !== instanceGeneration) return;
          instancePage = next; instances = more ? [...instances, ...next.rows] : next.rows;
          const single = instances.length === 1 && !next.has_more;
          el('monitorInstances').hidden = single;
          el('monitorInstances').closest('section').querySelector('header').hidden = single;
          el('monitorInstances').classList.add('monitor-instance-list');
          el('monitorInstances').innerHTML = table(['INSTANCE', 'STATE', 'VALUE', 'INCIDENT'], instances.map((row, index) => `<tr${selectedInstance === row.id ? ' class="monitor-selected"' : ''}><td><button class="task-row-open" data-instance="${index}" aria-pressed="${selectedInstance === row.id}" title="${esc(row.identity)}">${instanceLabel(row.identity, true)}</button></td><td>${badge(row.status)}</td><td>${esc(row.value ?? '—')}</td><td>${row.incident_id !== '0' ? `<button class="task-row-open monitor-incident-link" data-incident="${esc(row.incident_id)}" aria-label="Open incident #${esc(row.incident_id)}">#${esc(row.incident_id)}</button>` : '—'}</td></tr>`).join(''));
          el('monitorInstanceStatus').textContent = single ? '1 INSTANCE' : `${instances.length} LOADED · ${instances.filter(r => r.status === 'firing').length} FIRING · ${instances.filter(r => r.status === 'failing').length} PENDING${next.has_more ? ' · MORE AVAILABLE' : ''}`;
          el('monitorInstances').querySelector('table').insertAdjacentHTML('afterbegin', '<colgroup><col><col><col><col></colgroup>');
          el('monitorInstanceStatus').title = `AS OF ${stamp(next.at)}`;
          el('monitorInstanceMore').hidden = !next.has_more;
          if (single && selectedInstance !== instances[0].id) void selectInstance(0);
        } catch (error) { if (valid() && local === instanceGeneration) el('monitorInstanceStatus').textContent = `${error.message} · DISPLAYED ROWS MAY BE STALE`; }
        finally {
          if (valid() && local === instanceGeneration) {
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
        const identity = el('monitorInstances').hidden ? `<h3>${instanceLabel(row.identity)}</h3>` : '';
        el('monitorSelection').innerHTML = `${identity}<p>${badge(row.status)} · ${row.incident_id !== '0' ? `<button class="task-row-open" data-incident="${esc(row.incident_id)}">INCIDENT #${esc(row.incident_id)}</button>` : 'NO ACTIVE INCIDENT'}<span class="customer-meta">VALUE ${esc(row.value ?? '—')} · CURRENT NRC STATE</span></p><div class="monitor-streaks">${streak('FAIL', row.failures, config.failures, 'fail')}${streak('RECOVER', row.recoveries, config.recoveries, 'pass')}</div>`;
        const target = el('monitorHistory');
        if (victoria) {
          target.innerHTML = `${row.revision !== String(asset.updatedAt) ? '<p class="customer-meta">CONFIGURATION CHANGED · VALUE FROM PREVIOUS REVISION</p>' : ''}${table(['LAST OBSERVED VALUE', 'TRIGGER', 'RECOVERY'], `<tr><td>${esc(row.value ?? '—')}</td><td>${esc(definition.trigger.op)} ${esc(definition.trigger.value)}</td><td>${definition.recovery ? `${esc(definition.recovery.op)} ${esc(definition.recovery.value)}` : 'When trigger no longer matches'}</td></tr>`)}${valueScale(row, definition, asset.updatedAt)}<p class="customer-meta">LAST SEEN ${esc(stamp(row.seen_at))} · CURRENT CONFIGURATION THRESHOLDS</p>`;
        } else target.textContent = 'Reading history…';
        el('monitorUptime').replaceChildren(); el('monitorUptime').hidden = true; el('monitorHistoryDetails').replaceChildren();
        // Serialize whole selections, not just the reads within one selection.
        // Wait for the old response; abort alone need not free the server slot yet.
        const previous = inspectorHistoryTail;
        let release;
        inspectorHistoryTail = new Promise(resolve => { release = resolve; });
        await previous;
        try {
          if (!valid() || local !== historyGeneration) return;
          const attempts = await history(ref.id, 'runs', null, signal);
          if (!valid() || local !== historyGeneration) return;
          const to = Date.now(), range = { from: to - hour, to };
          const sample = await history(ref.id, 'samples', row.identity, signal, range);
          if (!valid() || local !== historyGeneration) return;
          const run = attempts.rows.findLast(r => r.acceptance === 'confirmed' && r.revision === String(asset.updatedAt) && r.sequence === row.sequence) || attempts.rows.at(-1);
          if (!victoria) target.innerHTML = diagnostics(run, definition, asset.updatedAt, row.sequence, row.revision);
          const observations = victoria ? sampleChart(sample.rows, definition, asset.updatedAt, config.interval_ns, range) : `${table(['TIME', 'VALUE'], sample.rows.slice(-20).reverse().map(s => `<tr><td>${esc(stamp(s.observed_at_ns))}</td><td>${esc(s.value)}${s.acceptance !== 'confirmed' ? `<span class="customer-meta">NOT CONFIRMED · ${esc(s.acceptance.toUpperCase())}</span>` : ''}</td></tr>`).join(''))}${sample.rows.length > 20 ? '<p class="customer-meta">LATEST 20 SAMPLES</p>' : ''}`;
          el('monitorHistoryDetails').innerHTML = section('HISTORY · LAST HOUR', `<p class="customer-meta">CHECKED ${esc(stamp(run?.observed_at_ns))}</p>${observations}${sample.dropped_process_total !== '0' ? `<p class="customer-meta">PROCESS HISTORY DROPS: ${esc(sample.dropped_process_total)}</p>` : ''}`);
          if (victoria) bindSampleChart(el('monitorHistoryDetails'));
          el('monitorUptime').hidden = false; el('monitorUptime').textContent = 'Reading 24h coverage…';
          try {
            const uptime = await history(ref.id, 'uptime', row.identity, signal);
            if (!valid() || local !== historyGeneration) return;
            const revisionRows = uptime.rows.filter(r => r.revision === String(asset.updatedAt));
            const totals = revisionRows.reduce((s, r) => { for (const k of Object.keys(s)) s[k] += BigInt(r[k]); return s; }, { healthy_ns: 0n, failing_ns: 0n, unknown_ns: 0n, paused_ns: 0n });
            const known = totals.healthy_ns + totals.failing_ns;
            const pct = (n, d) => d ? `${Number(n * 10000n / d) / 100}%` : 'UNKNOWN';
            const meter = (label, n, d, kind) => {
              const value = pct(n, d);
              return `<div><dt>${label}</dt><dd>${value}<div class="monitor-meter" data-kind="${kind}" data-known="${d > 0n}" role="img" aria-label="${label}: ${value}" style="--fill:${d > 0n ? Math.max(0, Math.min(100, Number(n * 10000n / d) / 100)) : 0}%"><span></span></div></dd></div>`;
            };
            el('monitorUptime').innerHTML = `<dl class="customer-facts monitor-metrics">${meter(`24H ${definition.kind.startsWith('victoria') ? 'CONDITION SATISFACTION' : 'UPTIME'} OF KNOWN TIME`, totals.healthy_ns, known, 'uptime')}${meter('24H COVERAGE', known, 86400000000000n - totals.paused_ns, 'coverage')}</dl><p class="customer-meta">HATCHED: NOT COVERED · PAUSED EXCLUDED</p><p class="customer-meta">CURRENT REVISION ONLY${uptime.pending_rollup_hours_global !== '0' ? ' · ROLLUPS PENDING (GLOBAL)' : ''}</p>`;
          } catch (error) { if (valid() && local === historyGeneration) el('monitorUptime').textContent = error.message; }
        } catch (error) { if (valid() && local === historyGeneration) (victoria ? el('monitorHistoryDetails') : target).textContent = error.message; }
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
    generation++; detailGeneration++; registerHistory.clear();
    for (const request of pending.values()) { clearTimeout(request.timeout); request.reject(new Error('Disconnected.')); }
    pending.clear(); rows = []; page = null; loading = false;
    if (el('monitorStatus')) el('monitorStatus').textContent = 'OFFLINE'; render();
    if (['monitor', 'incident'].includes(window.NRCInspector?.current()?.type)) el('inspectorEntityHost').textContent = 'Offline. Reopen this record after reconnecting.';
  }
  function init() {
    el('monitoringBtn').onclick = () => window.NRCViewManager.setActiveView('monitoring');
    for (const [id, value] of [['monitorStatusTab', 'status'], ['monitorIncidentsTab', 'incidents']]) el(id).onclick = () => { tab = value; rows = []; page = null; refresh(); };
    el('monitorRefresh').onclick = () => refresh(); el('monitorMore').onclick = () => refresh(true);
    el('monitorSearch').oninput = render;
    el('monitorStateFilter').onchange = render;
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
      if (event.target.closest('button, input, select, textarea, a') && !event.target.closest('.task-row-open')) return;
      const button = event.target.closest('tbody tr')?.querySelector('[data-monitor], [data-incident]');
      if (button) open(button.dataset.monitor ? 'monitor' : 'incident', button.dataset.monitor || button.dataset.incident);
    };
  }
  return { init, refresh, handlePage, handleError, showInspector, disconnect,
    onViewChanged(view) { if (view === 'monitoring') refresh(); else { generation++; loading = false; } },
  };
})();
