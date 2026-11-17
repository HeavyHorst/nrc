// Disposable browser fixture. It replaces transport only; production renders/actions run unchanged.
export function installMonitoringFixture() {
  window.monitorFixture = { old: false, fail: false, empty: false, actions: [], requests: [], pendingStatus: [], pendingHistory: [], pendingRegister: [], historyRequests: [] };
  const f = window.monitorFixture;
  const now = BigInt(Date.now()) * 1000000n, rev = String(now - 3456000000000000n);
  const config = { version: 1, name: 'Marketplace / API', enabled: true, interval_ns: 60000000000, failures: 5, recoveries: 5, missing: 5, webhooks: ['42'] };
  f.config = config;
  const definition = { kind: 'http', url: 'https://marketplace.example/health', conditions: [{ field: 'status', op: '==', value: 200 }, { field: 'json', path: '/healthy', op: '==', value: true }] };
  f.definition = definition;
  const incident = { version: 1, title: 'Marketplace / API unavailable', status: 'firing', monitor_id: '12', instance_id: '31', opened_at: String(now - 300000000000n), closed_at: '', acknowledged_by: '', acknowledged_at: '', assigned_to: '' };
  let incidentRevision = BigInt(rev);
  const asset = id => ({ assetId: BigInt(id), assetType: id === '12' ? 15 : 16, updatedAt: id === '12' ? BigInt(rev) : incidentRevision, preview: JSON.stringify(id === '12' ? config : incident), payload: window.monitorFixture?.rawDefinition ?? JSON.stringify(definition) });
  NRCAssets.sendGetAsset = (_room, id, callbacks) => { queueMicrotask(() => callbacks.onSuccess({ asset: asset(String(id)) })); return 1; };
  NRCAssets.requestAllAssets = async () => ({ assets: f.empty ? [] : [asset('51')] });
  serverReady = true; currentWorkspaceId = 'fixture';
  ws = { readyState: WebSocket.OPEN, send(buffer) {
    const v = new DataView(buffer), op = v.getUint16(0);
    if (op !== 73 && op !== 70) return;
    const correlation = v.getUint32(2);
    const statusSequence = f.statusSequence || '17';
    f.requests.push({ op, id: String(v.getBigUint64(6)), cursor: op === 73 ? String(v.getBigUint64(14)) : '', retired: op === 73 && v.getUint8(32) === 1 });
    queueMicrotask(() => {
      if (op === 70) {
        if (v.getBigUint64(14) !== incidentRevision) throw new Error('Wrong revision in incident action');
        const action = v.getUint8(22), assignee = new TextDecoder().decode(new Uint8Array(buffer, 25));
        f.actions.push({ action, assignee });
        if (action === 0) { incident.acknowledged_by = 'rene'; incident.acknowledged_at = String(now); }
        else incident.assigned_to = assignee;
        incidentRevision++;
        const receipt = new DataView(new ArrayBuffer(23)); receipt.setUint16(0, 176); receipt.setUint32(2, correlation); receipt.setBigUint64(6, 51n); receipt.setBigUint64(14, incidentRevision);
        handleBinaryMessage(receipt.buffer); return;
      }
      const monitor = v.getBigUint64(6), cursor = v.getBigUint64(14);
      const base = { revision: f.statusRevision || rev, sequence: statusSequence, evaluated_at: String(now), seen_at: String(now), counts: [1, 0, 0, 0, 0, 0, 0, 0, 0], status: 'firing' };
      const row = monitor === 0n ? { ...base, id: cursor ? '13' : '12', monitor_id: cursor ? '13' : '12', name: cursor ? 'Backup / Storage' : config.name } :
        { ...base, id: '31', monitor_id: '12', identity: f.identity || '{"target":"default"}', failures: f.failures ?? 5, recoveries: f.recoveries ?? 0, value: f.value === undefined ? 0 : f.value, incident_id: '51' };
      if (monitor === 0n && cursor) { row.status = f.secondState || 'healthy'; row.counts = [0, 0, 0, 0, 0, 0, row.status === 'healthy' ? 2 : 0, row.status === 'paused' ? 2 : 0, 0]; }
      const page = { version: 1, monitor_id: String(monitor), at: String(now), cursor_id: row.id, cursor_rank: 0, has_more: !f.empty && monitor === 0n && !cursor, rows: f.empty ? [] : [row] };
      if (monitor !== 0n && f.instancePages) {
        row.id = cursor ? '42' : '41';
        row.identity = f.instanceLabels?.[cursor ? 1 : 0] ?? `${v.getUint8(32) ? 'included' : 'active'}-${cursor ? 'next' : 'first'}`;
        page.cursor_id = row.id;
        page.has_more = !cursor;
      }
      const body = new TextEncoder().encode(JSON.stringify(page)), response = new DataView(new ArrayBuffer(6 + body.length));
      response.setUint16(0, 179); response.setUint32(2, correlation); new Uint8Array(response.buffer, 6).set(body);
      const deliver = () => handleBinaryMessage(response.buffer);
      if (monitor !== 0n && f.deferInstances) f.pendingStatus.push(deliver);
      else deliver();
    });
  } };
  const nativeFetch = window.fetch;
  window.fetch = async (input, options) => {
    const url = new URL(input, location.href);
    if (!url.pathname.startsWith('/monitoring/history/')) return nativeFetch(input, options);
    if (options.headers['X-NRC-Workspace'] !== 'fixture' || url.searchParams.has('workspace')) throw new Error('Invalid history workspace');
    if (f.fail) return new Response('busy', { status: 503 });
    const kind = url.pathname.split('/').at(-1);
    if (kind === 'uptime' && url.searchParams.get('resolution') === '1h') {
      f.historyRequests.push(url.href);
      const id = url.pathname.split('/').at(-2), from = Date.parse(url.searchParams.get('from'));
      if (from % 3600000 || ![1, 7, 30].includes((Date.parse(url.searchParams.get('to')) - from) / 86400000) || url.searchParams.has('acceptance')) throw new Error('Invalid overview range');
      const rows = [];
      for (let i = f.registerMode === 'paused' ? 0 : 1; i < 24; i++) {
        for (const identity of ['host-a', 'host-b']) {
          let healthy = 3600, failing = 0, unknown = 0, paused = 0;
          if (i === 1) { healthy = 0; unknown = 3600; }
          if (i === 2 || f.registerMode === 'paused') { healthy = 0; unknown = 0; paused = 3600; }
          if (i === 3 && identity === 'host-a' && !f.registerMode) { healthy = 2700; failing = 900; }
          if (i === 4 && identity === 'host-a' && !f.registerMode) { healthy = 1800; unknown = 1800; }
          rows.push({ bucket_ns: String(BigInt(from + i * 3600000) * 1000000n), revision: rev, identity, healthy_ns: String(healthy * 1e9), failing_ns: String(failing * 1e9), unknown_ns: String(unknown * 1e9), paused_ns: String(paused * 1e9) });
        }
      }
      rows.push({ ...rows[0], revision: '1', identity: 'old-host', healthy_ns: '3600000000000', unknown_ns: '0' });
      const custom = f.registerRows?.map(r => ({ bucket_ns: String(BigInt(from + r.hour * 3600000) * 1000000n), revision: r.old ? rev : f.statusRevision || rev, identity: r.identity, healthy_ns: String((r.healthy || 0) * 1e9), failing_ns: String((r.failing || 0) * 1e9), unknown_ns: String((r.unknown || 0) * 1e9), paused_ns: String((r.paused || 0) * 1e9) }));
      const response = f.registerMode === 'limit' ? new Response('too large', { status: 422 }) : Response.json({ version: 1, workspace: 'fixture', monitor_id: id, rows: id === '13' || f.registerMode === 'empty' ? [] : custom || rows, pending_rollup_hours_global: f.pendingRollups ?? '1' });
      if (f.deferRegister) return new Promise(resolve => f.pendingRegister.push(() => resolve(response)));
      return response;
    }
    const base = { run_id: 'attempt-17', revision: f.old ? '1' : rev, sequence: f.sequence || '17', observed_at_ns: String(now), acceptance: f.unknown ? 'unknown' : 'confirmed' };
    const rows = f.empty ? [] : kind === 'runs' ? f.runRows?.map(r => ({ ...base, ...r })) || [{ ...base, duration_ns: '125000000', diagnostics: { version: 1, conditions: [
      { index: 0, state: 'fail', actual_type: 'number', actual: '503', expected_number: '200' },
      { index: 1, state: 'pass', actual_type: 'boolean', actual: 'true' },
    ] } }] : kind === 'samples' ? f.sampleRows?.map(({ ago, ...r }) => ({ ...base, observed_at_ns: String(BigInt(Date.parse(url.searchParams.get('to')) - ago * 1000) * 1000000n), identity: url.searchParams.get('identity'), ...r })) || [{ ...base, identity: '{"target":"default"}', condition: 1, value: 0 }] : f.uptimeRows?.map(r => ({ revision: rev, ...r })) || [
      { revision: rev, healthy_ns: '600000000000', failing_ns: '300000000000', unknown_ns: '300000000000', paused_ns: '0' },
      { revision: '1', healthy_ns: '600000000000', failing_ns: '0', unknown_ns: '0', paused_ns: '0' },
    ];
    const response = Response.json({ version: 1, workspace: 'fixture', monitor_id: '12', rows, dropped_process_total: f.drops ?? '2', pending_rollup_hours_global: f.rollups ?? '1' });
    if (f.deferHistoryKind === kind) return new Promise(resolve => f.pendingHistory.push(() => resolve(response)));
    return response;
  };
  const historyFetch = window.fetch;
  Object.assign(f, { activeHistory: 0, maxActiveHistory: 0, rejectedHistory: 0, admittedHistory: [] });
  window.fetch = async (input, options) => {
    if (!f.enforceAdmission || !new URL(input, location.href).pathname.startsWith('/monitoring/history/')) return historyFetch(input, options);
    if (f.activeHistory === 2) { f.rejectedHistory++; return new Response('history busy', { status: 503 }); }
    f.activeHistory++;
    f.maxActiveHistory = Math.max(f.maxActiveHistory, f.activeHistory);
    f.admittedHistory.push(String(input));
    try { return await historyFetch(input, options); }
    finally { f.activeHistory--; }
  };
}
