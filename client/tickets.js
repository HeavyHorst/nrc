// Workspace tickets are NRC assets, not a second helpdesk database.
(function () {
  const statuses = ['open', 'in_progress', 'waiting_customer', 'resolved', 'closed'];
  const statusLabels = { open: 'OPEN', in_progress: 'IN PROGRESS', waiting_customer: 'WAITING ON CUSTOMER', resolved: 'RESOLVED', closed: 'CLOSED' };
  const priorities = ['low', 'normal', 'high', 'urgent'];
  const kinds = ['internal_note', 'public_reply'];
  const kindLabels = { public_reply: 'PUBLIC REPLY', customer_reply: 'CUSTOMER REPLY', internal_note: 'INTERNAL NOTE' };
  const state = { tickets: [], entries: [], selected: '', drafts: new Map(), filters: {}, pending: false, error: '', loading: false, notice: '', sort: 'activity', direction: 'desc' };
  Object.assign(state, { rows: [], attention: [], cursor: null, hasMore: false, total: 0 });
  let generation = 0, session = '';
  let listGeneration = 0, detailGeneration = 0, attentionGeneration = 0;
  let attentionTimer;
  const readCursors = () => window.NRCRecordActivity?.cursors('ticket') || {};
  function pageAssets(page) {
    return page.assets.map((asset, i) => ({ ...asset, ticketActivity: page.activity?.[i] }));
  }
  let workLoading = false, workAgain = false;
  let searchController;
  let searchState = { mode: 'idle', ids: new Set(), stale: false };
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  function metadata(asset) { try { const value = JSON.parse(asset.preview); return value && typeof value === 'object' ? { priority: 'normal', follow_up_at: '', ...value } : {}; } catch { return {}; } }
  function followUpInput(value) {
    if (!value) return '';
    const date = new Date(Number(value));
    if (!Number.isFinite(date.getTime())) return '';
    const pad = n => String(n).padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }
  function followUpValue(value) {
    if (!value) return '';
    const ms = new Date(value).getTime();
    if (!Number.isFinite(ms) || ms <= 0) throw new Error('Choose a valid follow-up date after 1970.');
    return String(ms);
  }
  function followUpLabel(value, due = Number(value) <= Date.now()) {
    if (!value) return '—';
    const date = new Date(Number(value));
    if (!Number.isFinite(date.getTime())) return 'OUT OF DATE RANGE';
    return `${due ? 'DUE · ' : ''}${date.toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'short' })}`;
  }
  function matches(asset, filters) {
    const m = metadata(asset);
    const query = String(filters.search || '').trim().toLowerCase();
    const text = query ? [m.title, m.requester, m.requester_name, `#${asset.assetId}`, asset.payload,
      ...state.entries.filter(entry => entry.parentType === 2 && entry.parentId === asset.assetId).map(entry => entry.payload)].join('\n').toLowerCase() : '';
    return (!filters.status || m.status === filters.status) && (!filters.owner || m.assignee === filters.owner) &&
      (!filters.priority || m.priority === filters.priority) &&
      (filters.follow_up !== 'due' || (Number(m.follow_up_at) > 0 && Number(m.follow_up_at) <= Date.now())) &&
      (!filters.company || m.company_id === filters.company) && (!query || text.includes(query));
  }
  function updateSearch({ debounce = false, preserve = false } = {}) {
    searchController?.cancel();
    const query = String(state.filters.search || '').trim();
    const { status = '', owner = '', company = '', priority = '', follow_up = '' } = state.filters;
    const key = JSON.stringify([query, status, owner, company, priority, follow_up]);
    if (!query || key !== searchState.key) searchState = { mode: query ? 'loading' : 'idle', ids: new Set(), stale: false, key };
    renderList(); renderStatus();
    if (!query) { loadPage(true, preserve); return; }
    // Due-time filtering must happen before any ranked top-N truncation.
    if (follow_up === 'due') {
      searchState = { mode: 'due-text', ids: new Set(), stale: false, key };
      loadPage(true, preserve); return;
    }
    listGeneration++; state.loading = false; state.hasMore = false;
    searchController ||= window.NRCSearch.createController();
    searchController.search({ query, top_n: 100,
      filters: { entity_types: ['asset'], asset_types: [13], ticket: { status, assignee: owner, company_id: company, priority } },
    }, {
      debounce: debounce ? 250 : 0,
      onResult: data => {
        const ids = new Set();
        for (const result of data.results) {
          if (result.entity?.type !== 'asset' || result.entity.conv_id !== '0' || result.asset_type !== 13 ||
            !result.metadata?.ticket || !/^[1-9]\d*$/.test(result.entity.id)) throw new Error('Invalid ticket search result');
          ids.add(result.entity.id);
        }
        searchState = { mode: 'results', ids, stale: data.stale === true, key };
        loadPage(true, preserve);
      },
      onError: () => { searchState = { mode: 'fallback', ids: new Set(), stale: false, key }; loadPage(true, preserve); },
    });
  }
  function conversation(id, internal) {
    return state.entries.filter(a => String(a.parentId) === String(id) && a.parentType === 2 &&
      (internal ? metadata(a).kind === 'internal_note' : ['customer_reply', 'public_reply'].includes(metadata(a).kind)))
      .sort((a, b) => a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : a.assetId < b.assetId ? -1 : 1);
  }
  function activity(asset) {
    if (asset.ticketActivity) {
      const summary = asset.ticketActivity;
      return { unread: summary.unread, waiting: summary.waiting, followUpDue: summary.follow_up_due === true, latest: { assetId: BigInt(summary.latest) }, timestamp: BigInt(summary.timestamp) };
    }
    const entries = state.entries.filter(a => a.parentType === 2 && a.parentId === asset.assetId);
    const publicEntries = entries.filter(a => ['customer_reply', 'public_reply'].includes(metadata(a).kind));
    const incoming = [asset, ...publicEntries.filter(a => metadata(a).kind === 'customer_reply')];
    const latest = incoming.reduce((last, a) => a.assetId > last.assetId ? a : last, asset);
    const answered = publicEntries.some(a => metadata(a).kind === 'public_reply' && a.assetId > latest.assetId);
    // Once the customer follows up, metadata edits must not hide the reply debt.
    // Explicit workflow state and the unanswered conversation are independent.
    const paused = latest === asset && ['waiting_customer', 'resolved', 'closed'].includes(metadata(asset).status);
    const cursor = window.NRCRecordActivity?.cursor('ticket', asset.assetId) || 0n;
    const unread = incoming.filter(a => a.assetId > cursor && (a !== asset || a.owner !== (typeof myNickname === 'string' ? myNickname : ''))).length;
    const last = [asset, ...entries].reduce((last, a) => (a.createdAt || 0n) > (last.createdAt || 0n) ? a : last, asset);
    return { unread, waiting: !answered && !paused, latest, timestamp: last.createdAt || 0n };
  }
  function snapshot() {
    const me = typeof myNickname === 'string' ? myNickname : '';
    return state.attention.map(asset => ({ asset, ...activity(asset) }))
      .filter(item => !metadata(item.asset).assignee || metadata(item.asset).assignee === me);
  }
  function publishActivity() {
    const badge = document.getElementById('ticketsUnreadCount');
    const total = snapshot().filter(item => item.unread).length;
    if (badge) { badge.textContent = String(total); badge.hidden = !total; badge.setAttribute('aria-label', `${total} unread tickets assigned to you or unassigned`); }
    document.dispatchEvent?.(new CustomEvent('nrc:tickets-activity'));
  }
  function draft() {
    if (!state.drafts.has(state.selected)) {
      const a = state.tickets.find(a => String(a.assetId) === state.selected);
      state.drafts.set(state.selected, { version: 1, title: '', company_id: state.filters.company || '', contact_id: '', requester: '', requester_name: '', status: 'open', assignee: '', priority: 'normal', follow_up_at: '', ...metadata(a || {}), ...(!a ? { body: '' } : {}), message: '', kind: 'internal_note' });
    }
    const d = state.drafts.get(state.selected);
    d.uploads ||= [];
    return d;
  }
  const attachmentHtml = (asset, id) => typeof renderAttachmentPreviewStripHtml === 'function'
    ? renderAttachmentPreviewStripHtml(asset.attachments || [], id) : '';
  function attachmentComposer() {
    return '<div class="detail-edit-field"><span class="detail-edit-label">ATTACH FILES · 10 MAX · 100 MB EACH</span><div><button type="button" class="btn" data-ticket-add-files>+ ADD FILE</button><input type="file" multiple data-ticket-files aria-label="Ticket attachments" hidden></div><div data-ticket-uploads role="status"></div></div>';
  }
  function renderUploads(d, host) {
    if (!host?.isConnected || host.ticketDraft !== d) return;
    const list = host.querySelector('[data-ticket-uploads]');
    if (list) {
      list.innerHTML = d.uploads.map((u, i) => `<div class="note-link-item"><span class="note-preview-attachment-name">${esc(u.filename)}</span><span class="customer-meta">${esc(u.error ? `BLOB UPLOAD FAILED · ${u.error}` : u.attachment ? 'BLOB UPLOADED · TICKET NOT YET SAVED' : 'UPLOADING BLOB…')}</span><button type="button" class="btn btn--row btn--danger" data-remove-upload="${i}">REMOVE</button></div>`).join('');
      list.onclick = event => {
        const button = event.target.closest('[data-remove-upload]');
        if (!button || state.pending) return;
        d.uploads.splice(Number(button.dataset.removeUpload), 1);
        renderUploads(d, host); renderStatus();
      };
    }
  }
  function queueFiles(files, d, host) {
    for (const file of files) {
      if (d.uploads.length >= 10) { state.error = 'Maximum 10 attachments. Remove a queued file first.'; break; }
      if (file.size > 100 * 1024 * 1024) { state.error = `${file.name}: file exceeds 100 MB limit.`; continue; }
      const upload = { filename: file.name };
      d.uploads.push(upload);
      Promise.resolve().then(() => uploadFile(file)).then(attachment => { upload.attachment = attachment; }, error => { upload.error = error.message || 'Upload failed'; })
        .finally(() => {
          const activeHost = document.getElementById('ticketEditor');
          const current = activeHost?.ticketDraft;
          if (current?.uploads.includes(upload)) renderUploads(current, activeHost);
          renderStatus();
        });
    }
    renderUploads(d, host); renderStatus();
  }
  async function loadPage(reset = false, preserve = false) {
    if (!reset && (state.loading || !state.hasMore)) return;
    const token = reset ? ++listGeneration : listGeneration, scope = generation;
    const depth = preserve ? Math.max(50, state.rows.length) : 50;
    const anchor = preserve && state.rows.some(a => String(a.assetId) === state.selected) ? state.selected : '';
    const scroller = document.getElementById('ticketsRegister'), scrollTop = scroller?.scrollTop;
    if (reset) { state.cursor = null; state.hasMore = false; }
    state.loading = true; state.error = ''; renderStatus();
    try {
      const query = {
        status: state.filters.status || '', assignee: state.filters.owner || '', company: state.filters.company || '',
        priority: state.filters.priority || '', follow_up: state.filters.follow_up || '',
        sort: state.sort, descending: state.direction === 'desc', limit: 50, cursor: state.cursor || {}, read: readCursors(),
        search_results: searchState.mode === 'results', ids: [...searchState.ids],
        search: ['fallback', 'due-text'].includes(searchState.mode) ? state.filters.search || '' : '',
      };
      let page, rows = [];
      do {
        page = await window.NRCAssets.requestTicketPage(query, { isCancelled: () => token !== listGeneration || scope !== generation });
        if (token !== listGeneration || scope !== generation) return;
        rows.push(...pageAssets(page));
        query.cursor = page.cursor;
      } while (preserve && page.has_more && (rows.length < depth || (anchor && !rows.some(a => String(a.assetId) === anchor))));
      state.rows = reset ? rows : [...state.rows, ...rows.filter(a => !state.rows.some(b => b.assetId === a.assetId))];
      const selected = state.tickets.find(a => String(a.assetId) === state.selected);
      state.tickets = [...state.rows];
      if (selected) {
        const index = state.tickets.findIndex(a => a.assetId === selected.assetId);
        if (index < 0) state.tickets.push(selected);
        else state.tickets[index] = { ...selected, ticketActivity: state.tickets[index].ticketActivity };
      }
      state.cursor = page.cursor; state.hasMore = page.has_more; state.total = page.total_count;
      renderList();
      if (preserve && scroller) scroller.scrollTop = scrollTop;
      const links = rows.flatMap(a => { const m = metadata(a); return [m.company_id, m.contact_id].filter(Boolean); });
      window.NRCAssets.requestAssetsByIds(0n, links).then(() => { if (token === listGeneration && scope === generation) renderList(); }).catch(() => {});
    } catch (error) { if (token === listGeneration && scope === generation) state.error = error.message; }
    finally {
      if (token === listGeneration && scope === generation) { state.loading = false; renderStatus(); }
    }
  }
  async function refreshAttention() {
    clearTimeout(attentionTimer);
    const token = ++attentionGeneration, scope = generation, rows = [];
    let cursor = {};
    try {
      for (;;) {
        const page = await window.NRCAssets.requestTicketPage({ mode: 'attention', sort: 'id', descending: true, omit_total_count: true, cursor, read: readCursors(), limit: 100 },
          { isCancelled: () => token !== attentionGeneration || scope !== generation });
        if (token !== attentionGeneration || scope !== generation) return;
        rows.push(...pageAssets(page));
        if (!page.has_more) break;
        cursor = page.cursor;
      }
      state.attention = rows; publishActivity();
      // An open scheduled register must cross deadlines too, using server time.
      // Leave in-flight queries and edits alone; retain loaded depth and scroll.
      if (window.NRCViewManager?.getActiveView?.() === 'tickets' && !state.loading && !state.pending && searchState.mode !== 'loading' &&
          (state.filters.follow_up === 'due' || state.rows.some(a => metadata(a).follow_up_at))) {
        await loadPage(true, true);
      }
    } catch { /* Retain the last confirmed attention snapshot on failure. */ }
    finally {
      if (token === attentionGeneration && scope === generation && session && typeof serverReady !== 'undefined' && serverReady) {
        attentionTimer = setTimeout(refreshAttention, 30000);
      }
    }
  }
  async function loadDetail() {
    const id = state.selected, token = ++detailGeneration, scope = generation;
    if (!id) return;
    state.detailLoading = true; renderConversation(); renderStatus();
    const cancelled = () => id !== state.selected || token !== detailGeneration || scope !== generation;
    try {
      const { asset } = await write(options => window.NRCAssets.sendGetAsset(0n, BigInt(id), options));
      if (cancelled()) return;
      if (!asset || asset.assetType !== 13) throw new Error('Ticket unavailable');
      let cursor = {}, entries = [];
      for (;;) {
        const page = await window.NRCAssets.requestTicketPage({ mode: 'entries', parent: id, cursor, limit: 100 }, { isCancelled: cancelled });
        if (cancelled()) return;
        entries.push(...page.assets);
        if (!page.has_more) break;
        cursor = page.cursor;
      }
      if (cancelled()) return;
      state.tickets = [...state.tickets.filter(a => String(a.assetId) !== id), asset];
      state.entries = entries;
      state.detailLoading = false;
      if (!state.drafts.has(id)) editor();
      renderMetadata(); renderConversation(); renderSavedAttachments(); hydrateWork();
    } catch (error) { if (!cancelled()) { state.detailLoading = false; state.error = error.message; renderStatus(); } }
    finally { if (!cancelled()) renderStatus(); }
  }
  let peopleGeneration = 0;
  async function reload({ preserve = false } = {}) {
    const scope = generation;
    const peopleScope = ++peopleGeneration;
    let people;
    const peopleRead = window.NRCAssets.requestPersonList(66, { isCancelled: () => scope !== generation || peopleScope !== peopleGeneration })
      .then(values => { people = values; })
      .catch(error => { if (scope === generation && peopleScope === peopleGeneration) { state.error = error.message; renderStatus(); } });
    const list = String(state.filters.search || '').trim() ? updateSearch({ preserve }) : loadPage(true, preserve);
    await Promise.all([list, refreshAttention(), loadDetail(), peopleRead]);
    if (scope !== generation) return;
    const assigneeSelect = document.getElementById('ticketAssigneeFilter');
    if (assigneeSelect && people && peopleScope === peopleGeneration) {
      const names = [...new Set([...people, state.filters.owner].filter(Boolean))].sort();
      const options = '<option value="">ALL ASSIGNEES</option>' + names.map(name => `<option value="${esc(name)}">${esc(name)}</option>`).join('');
      if (assigneeSelect.innerHTML !== options) assigneeSelect.innerHTML = options;
      assigneeSelect.value = state.filters.owner || '';
    }
    const customerSelect = document.getElementById('ticketCustomerFilter');
    if (customerSelect) {
      customerSelect.disabled = true;
      try {
        const { assets } = await window.NRCAssets.requestAllAssets(0n, 8, { isCancelled: () => scope !== generation });
        if (scope !== generation) return;
        const companies = assets.filter(a => typeof metadata(a).title === 'string').sort((a, b) => metadata(a).title.localeCompare(metadata(b).title));
        const selected = state.filters.company || '';
        customerSelect.innerHTML = '<option value="">ALL CUSTOMERS</option>' + companies.map(a => `<option value="${a.assetId}">${esc(metadata(a).title)} · #${a.assetId}${metadata(a).archived ? ' · ARCHIVED' : ''}</option>`).join('') +
          (selected && !companies.some(a => String(a.assetId) === selected) ? `<option value="${esc(selected)}">CUSTOMER #${esc(selected)} · UNAVAILABLE</option>` : '');
        customerSelect.value = selected;
        customerSelect.disabled = false;
        renderList();
      } catch (error) { if (scope === generation) { state.error = error.message; renderStatus(); } }
    }
  }
  let refreshQueued = false;
  function scheduleRefresh() {
    if (refreshQueued) return;
    refreshQueued = true;
    const scope = generation;
    Promise.resolve().then(() => { refreshQueued = false; if (scope === generation) reload({ preserve: true }); });
  }
  function write(send) {
    return new Promise((resolve, reject) => {
      const id = send({ onSuccess: resolve, onError: e => reject(new Error(e?.message || 'Save failed')) });
      if (!id) reject(new Error('Not connected. Draft retained; nothing confirmed saved.'));
    });
  }
  async function save(entry = false) {
    if (state.pending) return;
    const selected = state.selected, d = draft(), snapshot = { ...d, uploads: [...d.uploads] };
    if (!entry) {
      const input = document.querySelector('#ticketFields [name=follow_up_at]');
      try { if (input) snapshot.follow_up_at = followUpValue(input.value); }
      catch (error) { state.error = error.message; renderStatus(); return; }
    }
    if (snapshot.uploads.some(u => !u.attachment)) { state.error = 'Wait for blob uploads; remove failed uploads before saving. Draft retained.'; renderStatus(); return; }
    if (selected && !state.tickets.some(a => String(a.assetId) === selected)) { state.error = 'Ticket is unavailable. Draft retained; refresh before saving.'; renderStatus(); return; }
    if (entry ? !snapshot.message.trim() : !snapshot.title.trim()) { state.error = entry ? 'Message is required.' : 'Title is required.'; renderStatus(); return; }
    if (!statuses.includes(snapshot.status) || !/^\d*$/.test(snapshot.company_id) || !/^\d*$/.test(snapshot.contact_id)) { state.error = 'Invalid status or company/contact ID.'; renderStatus(); return; }
    state.pending = true; state.error = ''; state.notice = ''; renderStatus();
    try {
      const api = window.NRCAssets;
      if (entry) {
        if (!selected || !kinds.includes(snapshot.kind)) throw new Error('Save the ticket first.');
        if (snapshot.kind === 'public_reply' && snapshot.requester !== metadata(state.tickets.find(a => String(a.assetId) === selected)).requester) {
          throw new Error('Requester changed. Use current recipient before sending a public reply.');
        }
        const author = typeof myNickname === 'string' ? myNickname : '';
        const preview = { version: 1, kind: snapshot.kind, author };
        if (snapshot.kind === 'public_reply') preview.recipient = snapshot.requester;
        const parentOptions = snapshot.kind === 'public_reply'
          ? { ifParentUpdatedAt: state.tickets.find(a => String(a.assetId) === selected).updatedAt }
          : {};
        if (snapshot.kind === 'public_reply' && !parentOptions.ifParentUpdatedAt) throw new Error('Ticket version unavailable. Refresh before sending. Draft retained.');
        await write(options => api.sendCreateAsset(0n, 14, 2, BigInt(selected), JSON.stringify(preview), snapshot.message, 0, { ...options, ...parentOptions }, snapshot.uploads.map(u => u.attachment)));
        d.uploads = d.uploads.filter(u => !snapshot.uploads.includes(u));
        if (d.message === snapshot.message) d.message = '';
        if (d.kind === snapshot.kind) { d.kind = 'internal_note'; snapshot.kind = d.kind; }
      } else {
        const { body, message, kind, uploads, ...preview } = snapshot;
        const result = await write(options => api.sendCreateAsset(0n, 13, 0, 0n, JSON.stringify(preview), body, 0, options, uploads.map(u => u.attachment)));
        d.uploads = d.uploads.filter(u => !uploads.includes(u));
        const id = String(result.asset.assetId);
        if (!state.tickets.some(asset => String(asset.assetId) === id)) state.tickets.push(result.asset);
        delete d.body;
        state.drafts.set(id, d); state.drafts.delete('');
        if (state.selected === selected) { state.selected = id; editor(); }
      }
      state.notice = Object.keys(snapshot).some(key => key !== 'uploads' && key !== 'body' && d[key] !== snapshot[key] && !(entry && key === 'message' && d.message === '')) ? 'SAVED SNAPSHOT · NEWER DRAFT UNSAVED' : 'SAVED · NRC ACKNOWLEDGED';
      await reload({ preserve: true });
      // Acknowledgement, not dispatch, is the save boundary. Keep the selected draft.
      if (entry && state.selected === selected) {
        const input = document.querySelector('#ticketEditor [name=message]');
        if (input) input.value = d.message;
        renderConversation();
        renderSavedAttachments();
        renderUploads(d, document.getElementById('ticketEditor'));
      }
    } catch (error) { state.error = error.message; }
    finally {
      state.pending = false; renderStatus();
      if (!entry && window.NRCInspector?.current()?.type === 'ticket' && window.NRCInspector.current().id === 0n && state.selected) selectTicket(state.selected);
    }
  }
  function renderStatus() {
    const el = document.getElementById('ticketsStatus');
    const searchStatus = searchState.mode === 'loading' ? 'SEARCHING' : searchState.mode === 'results'
      ? `${searchState.ids.size} RESULTS · TOP 100${searchState.stale ? ' · INDEX STALE' : ''}`
      : searchState.mode === 'fallback' ? 'SERVER TEXT FALLBACK' : searchState.mode === 'due-text' ? 'DUE · SERVER TEXT SEARCH' : '';
    if (el) {
      el.textContent = state.error || (state.pending ? 'SAVING · awaiting NRC acknowledgement' : state.loading ? 'LOADING PAGE' : `${state.rows.length} / ${state.total} TICKETS${searchStatus ? ` · ${searchStatus}` : ''}`);
      el.title = searchState.mode === 'due-text' ? 'Due follow-ups: server text search applies before pagination, without ranked search truncation.' : searchState.mode === 'fallback' ? 'Search service unavailable. Server searches ticket metadata, requests and conversations before paging.' : searchState.mode === 'results' ? 'Search service: up to 100 ticket results. Index updates are asynchronous.' : '';
    }
    document.getElementById('ticketsPager')?.setState({ hasMore: state.hasMore, loading: state.loading, error: state.error,
      active: window.NRCViewManager?.getActiveView?.() === 'tickets', root: document.getElementById('ticketsRegister'), label: 'LOAD MORE TICKETS' });
    const detailStatus = document.getElementById('ticketStatus');
    if (detailStatus) {
      detailStatus.textContent = state.error || (state.pending ? 'SAVING · awaiting NRC acknowledgement' : state.selected && state.notice === 'UNSAVED DRAFT' ? '' : state.notice);
      detailStatus.hidden = !detailStatus.textContent;
    }
    const blocked = state.drafts.get(state.selected)?.uploads?.some(u => !u.attachment);
    document.querySelectorAll('#ticketEditor button[data-save]').forEach(b => b.disabled = state.pending || state.detailLoading || (!state.selected && blocked));
    document.querySelectorAll('#ticketEditor [data-ticket-files], #ticketEditor [data-ticket-add-files], #ticketEditor [data-remove-upload]').forEach(el => el.disabled = state.pending);
    const body = document.querySelector('#ticketEditor [name=body]');
    if (body) body.readOnly = state.pending;
    const create = document.getElementById('ticketNew'); if (create) create.disabled = state.pending;
    const reply = document.getElementById('ticketReply');
    if (reply && (!state.selected || state.tickets.some(a => String(a.assetId) === state.selected))) {
      const d = draft(), isPublic = d.kind === 'public_reply';
      reply.querySelectorAll('[name=kind]').forEach(input => { input.checked = input.value === d.kind; });
      const draftState = document.getElementById('ticketDraftState');
      if (draftState) draftState.textContent = state.pending ? 'SAVING' : d.message.trim() || d.uploads.length ? 'UNSAVED DRAFT' : 'NEW MESSAGE';
      const requester = metadata(state.tickets.find(a => String(a.assetId) === state.selected) || {}).requester;
      const visibility = document.getElementById('ticketVisibility');
      if (visibility) visibility.textContent = isPublic ? `PUBLIC REPLY TO ${requester || 'REQUESTER'} · VISIBLE IN CUSTOMER PORTAL${d.requester !== requester ? ' · REQUESTER CHANGED — CONFIRM CURRENT RECIPIENT FIRST' : ''}` : 'INTERNAL NOTE · ONLY NRC STAFF CAN SEE THIS';
      const acceptRecipient = reply.querySelector('[data-ticket-recipient]');
      if (acceptRecipient) {
        acceptRecipient.hidden = !isPublic || d.requester === requester;
        acceptRecipient.disabled = state.pending;
        acceptRecipient.onclick = () => { d.requester = requester; renderStatus(); };
      }
      const send = reply.querySelector('button[data-save]');
      if (send) {
        send.textContent = isPublic ? 'SEND CUSTOMER REPLY' : 'SAVE INTERNAL NOTE';
        send.disabled = state.pending || blocked || (isPublic && d.requester !== requester);
      }
      reply.dataset.visibility = isPublic ? 'public' : 'internal';
    }
  }
  function contactName(m) {
    return customerName(m.contact_id) || m.requester_name || m.requester || '';
  }
  function renderList() {
    const el = document.getElementById('ticketsList'); if (!el) return;
    const rows = (searchState.mode === 'loading' ? [] : state.rows).map(asset => ({ asset, ...activity(asset) }));
    const focused = el.contains?.(document.activeElement) ? document.activeElement.closest('[data-ticket]')?.dataset.ticket : null;
    const titleFocused = !!document.activeElement?.closest('nrc-inline-field');
    el.innerHTML = rows.map(({ asset: a, unread, waiting, timestamp, followUpDue }) => {
      const m = metadata(a), selected = state.selected === String(a.assetId);
      const context = [customerName(m.company_id), m.assignee || 'UNASSIGNED'].filter(Boolean).join(' · ');
      const date = new Date(Number(m.follow_up_at));
      const scheduled = !!m.follow_up_at, validDate = Number.isFinite(date.getTime());
      const dateLabel = !scheduled ? '' : validDate ? date.toLocaleString(undefined, { day: 'numeric', month: 'short', ...(date.getFullYear() !== new Date().getFullYear() ? { year: 'numeric' } : {}), hour: '2-digit', minute: '2-digit' }) : 'OUT OF DATE RANGE';
      const due = followUpDue ?? (scheduled && Number(m.follow_up_at) <= Date.now());
      const identity = session, selection = state.selected;
      const title = window.NRCDetailUI.inlineField({
        key: `ticket-row-${a.assetId}-title`, name: 'TITLE', label: '', value: m.title,
        required: true, maxBytes: 256,
        save: value => saveMetadata(a, { title: value.trim() }, identity, selection),
      });
      return `<tr data-ticket="${a.assetId}" class="${selected ? 'task-row-selected' : ''}" aria-selected="${selected}"><td class="col-id">#${a.assetId}</td><td class="col-title">${title}<span class="customer-meta" title="${esc(context)}">${esc(context)}</span></td><td class="col-status">${esc(statusLabels[m.status] || m.status)}${waiting ? '<span class="customer-meta">CUSTOMER WAITING</span>' : ''}</td><td class="col-priority" data-priority="${esc(m.priority)}">${esc(m.priority.toUpperCase())}</td><td class="col-follow-up${due ? ' ticket-follow-up-due' : ''}" title="${esc(scheduled ? followUpLabel(m.follow_up_at, due) : 'No follow-up scheduled')}">${due ? '<span>DUE</span>' : ''}<span class="customer-meta">${esc(dateLabel)}</span></td><td class="col-activity" title="${esc(window.NRCDetailUI.formatHeaderDate(timestamp))}">${timestamp ? esc(typeof formatRelativeAge === 'function' ? formatRelativeAge(timestamp) : window.NRCDetailUI.formatHeaderDate(timestamp)) : ''}${unread ? `<span class="col-unread">${unread} UNREAD</span>` : ''}</td></tr>`;
    }).join('') || `<tr><td colspan="6" class="customer-empty">${searchState.mode === 'loading' ? 'Searching tickets…' : 'No matching tickets.'}</td></tr>`;
    el.querySelectorAll('[data-ticket]').forEach(row => {
      row.tabIndex = 0;
      row.setAttribute('aria-label', `Open ticket ${row.dataset.ticket}: ${row.querySelector('nrc-inline-field button').textContent}`);
    });
    document.querySelectorAll('#ticketsTable th[data-sort]').forEach(th => {
      const active = th.dataset.sort === state.sort;
      th.classList.toggle('sorted-asc', active && state.direction === 'asc');
      th.classList.toggle('sorted-desc', active && state.direction === 'desc');
      th.setAttribute('aria-sort', active ? state.direction === 'asc' ? 'ascending' : 'descending' : 'none');
    });
    const sort = document.getElementById('ticketsSort');
    if (sort) sort.value = `${state.sort}:${state.direction}`;
    if (focused) el.querySelector(`[data-ticket="${focused}"]${titleFocused ? ' nrc-inline-field button' : ''}`)?.focus({ preventScroll: true });
    window.NRCColumnResize?.init({
      root: '#ticketsTable', headers: 'thead th', storageKey: 'nrc.ticket.columns.v3',
      viewport: '#ticketsRegister', flexible: 1,
      independent: true, rows: '#ticketsList tr[data-ticket]', resetControl: '#ticketColumnsReset',
      defaults: [56, 280, 160, 104, 160, 100], minimums: [48, 160, 110, 88, 130, 88],
      maximums: [640, 4096],
      apply: (table, widths, manual) => {
        table.style.tableLayout = 'fixed';
        const fixed = widths.reduce((sum, width, i) => sum + (i === 1 ? 0 : width), 0);
        table.style.setProperty('--task-table-width', manual ? `${fixed + widths[1]}px` : '100%');
        table.querySelectorAll('thead th').forEach((th, i) => th.style.width = i === 1 && !manual ? `max(${widths[i]}px, calc(100% - ${fixed}px))` : `${widths[i]}px`);
      },
    });
  }
  function customerName(id) {
    if (!id) return '';
    const linked = window.NRCAssets.roomAssets?.get(0n)?.get(BigInt(id));
    return metadata(linked || {}).title || `#${id}`;
  }
  function renderConversation() {
    const el = document.getElementById('ticketConversation'); if (!el) return;
    if (state.detailLoading) { el.textContent = 'Loading conversation…'; return; }
    const selected = state.tickets.find(a => String(a.assetId) === state.selected);
    const mailMeta = asset => {
      const m = metadata(asset), labels = [];
      if (m.channel === 'email') labels.push('EMAIL');
      if (m.recipient) labels.push(`TO ${m.recipient}`);
      if (m.mail_delivery) labels.push(({ queued: 'MAIL QUEUED', sent: 'MAIL SERVER ACCEPTED', failed: 'MAIL FAILED', unknown: 'MAIL STATUS UNKNOWN' })[m.mail_delivery] || 'MAIL STATUS UNKNOWN');
      return labels.length ? ` / ${esc(labels.join(' · '))}` : '';
    };
    el.innerHTML = [false, true].map(internal => `<section class="customer-section${internal ? ' ticket-internal' : ''}"><div class="panel-header"><div><span>${internal ? 'INTERNAL NOTES · NEVER PUBLIC' : 'PUBLIC CONVERSATION'}</span></div></div>${!internal && selected ? `<article class="customer-event" data-ticket-entry="${selected.assetId}"><span class="customer-meta">ORIGINAL REQUEST / ${esc(metadata(selected).requester_name || metadata(selected).requester)}${mailMeta(selected)}</span><p class="customer-activity-body">${esc(selected.payload)}</p></article>` : ''}${conversation(state.selected, internal).map(a => `<article class="customer-event" data-ticket-entry="${a.assetId}"><span class="customer-meta">${esc(kindLabels[metadata(a).kind])} / ${esc(metadata(a).author)} / ${esc(window.NRCDetailUI.formatHeaderDate(a.createdAt))}${mailMeta(a)}</span><p class="customer-activity-body">${esc(a.payload)}</p></article>`).join('') || (internal || !selected ? '<p class="customer-empty">No entries.</p>' : '')}</section>`).join('');
    if (selected && el.querySelector) {
      const { latest } = activity(selected);
      window.NRCRecordActivity?.observe('ticket', el.querySelector(`[data-ticket-entry="${latest.assetId}"]`), 'ticket', selected.assetId, latest.assetId);
    }
  }
  function renderSavedAttachments() {
    const root = document.getElementById('ticketConversation');
    if (!root?.querySelectorAll) return;
    const selected = state.tickets.find(a => String(a.assetId) === state.selected);
    const assets = [...(selected ? [selected] : []), ...conversation(state.selected, false), ...conversation(state.selected, true)];
    root.querySelectorAll('article').forEach((article, index) => {
      if (assets[index]) article.insertAdjacentHTML('beforeend', attachmentHtml(assets[index], `ticket-attachments-${assets[index].assetId}`));
    });
  }
  async function saveMetadata(base, patch, identity = session, selection = String(base.assetId)) {
    if (state.pending) throw new Error('Another save is pending. Retry when it finishes.');
    if (identity !== session) throw new Error('Session changed. Reopen the ticket.');
    if (state.selected !== selection) throw new Error('Ticket changed. Reopen this field.');
    const preview = JSON.stringify({ ...metadata(base), ...patch });
    const token = generation;
    state.pending = true; state.error = ''; renderStatus();
    try {
      if (base.payload == null) {
        const { asset } = await write(options => window.NRCAssets.sendGetAsset(0n, base.assetId, options));
        if (token !== generation || identity !== session || state.selected !== selection) throw new Error('Session changed. Reopen this field.');
        if (asset.updatedAt !== base.updatedAt || asset.preview !== base.preview) throw new Error('Ticket changed. Reopen this field.');
        base = asset;
      }
      await write(options => window.NRCTransactions.sendAssetMetadataPatch(base, preview, null, options));
      if (token !== generation) throw new Error('Connection changed. Save not confirmed; refresh and reopen this field.');
      const { asset } = await write(options => window.NRCAssets.sendGetAsset(0n, base.assetId, options));
      if (token !== generation) throw new Error('Connection changed. Save not confirmed; refresh and reopen this field.');
      if (asset.preview !== preview || asset.payload !== base.payload) throw new Error('Ticket changed again. Refresh and reopen this field.');
      const savedDraft = state.drafts.get(String(base.assetId));
      if (savedDraft) Object.assign(savedDraft, patch);
      state.notice = 'SAVED · NRC ACKNOWLEDGED';
      await reload({ preserve: true });
    } catch (error) {
      if (token !== generation) throw new Error('Connection changed. Save not confirmed; refresh and reopen this field.');
      state.error = `${error.message} · REFRESH AND REOPEN FIELD TO USE THE SAVED VERSION`;
      throw new Error(state.error);
    } finally { state.pending = false; renderStatus(); }
  }
  function renderMetadata() {
    const root = document.getElementById('ticketMetadata'); if (!root) return;
    const asset = state.tickets.find(a => String(a.assetId) === state.selected); if (!asset) return;
    if (asset.payload == null) { root.textContent = 'Loading ticket…'; return; }
    const m = metadata(asset);
    const customerOpen = root.querySelector('.ticket-customer-details')?.open;
    const identity = session;
    const control = (name, label, extra = {}) => window.NRCDetailUI.inlineField({
      key: `ticket-${asset.assetId}-${name}`, name: label, label, value: m[name] || '',
      save: value => saveMetadata(asset, { [name]: value.trim() }, identity), ...extra,
    });
    const customer = (name, label) => {
      const linked = window.NRCAssets.roomAssets?.get(0n)?.get(BigInt(m[name] || '0'));
      return `<div><span class="inline-field-label">${label}</span><button type="button" class="inline-field-value" data-ticket-customer aria-label="Edit ${label} AND ${label === 'COMPANY' ? 'CONTACT' : 'COMPANY'}">${esc(metadata(linked || {}).title || (m[name] ? `#${m[name]}` : '—'))}</button></div>`;
    };
    root.innerHTML = `<div class="task-detail-doc-title">${esc(m.title)} ${control('title', 'TITLE', { label: '', display: 'RENAME', required: true, maxBytes: 256 })}</div>
      <div class="detail-read-register task-detail-read-register">${control('status', 'STATUS', { display: statusLabels[m.status], options: statuses.map(value => ({ value, label: statusLabels[value] })) })}
      ${control('assignee', 'ASSIGNEE', { maxBytes: 64, suggestions: () => [...new Set([...(typeof userDirectory === 'function' ? userDirectory() : []), ...state.tickets.map(a => metadata(a).assignee)].filter(Boolean))] })}
      ${control('priority', 'PRIORITY', { display: m.priority.toUpperCase(), options: priorities.map(value => ({ value, label: value.toUpperCase() })) })}
      ${control('follow_up_at', 'FOLLOW-UP · LOCAL TIME', { type: 'datetime-local', clearable: !!m.follow_up_at, value: followUpInput(m.follow_up_at), display: followUpLabel(m.follow_up_at), save: value => saveMetadata(asset, { follow_up_at: followUpValue(value) }, identity) })}</div>
      <details class="ticket-customer-details"${customerOpen ? ' open' : ''}><summary>CUSTOMER DETAILS <span>${esc(customerName(m.company_id) || m.requester_name || m.requester || 'NOT ASSIGNED')}</span></summary><div class="record-document"><div class="detail-read-register task-detail-read-register">
      ${customer('company_id', 'COMPANY')}${customer('contact_id', 'CONTACT')}
      ${control('requester', 'REQUESTER', { maxBytes: 320 })}${control('requester_name', 'REQUESTER NAME', { maxBytes: 256 })}</div></div></details>`;
  }
  function editor() {
    const host = document.getElementById('ticketEditor'); if (!host) return;
    const resourceOpen = window.NRCDetailUI.readResourceState(host);
    host.ticketDraft = null;
    if (state.selected && !state.tickets.some(a => String(a.assetId) === state.selected) && !state.drafts.has(state.selected)) {
      host.innerHTML = '<p class="customer-empty">Ticket not loaded or unavailable. Refresh to retry. No editable record has been substituted.</p>'; return;
    }
    const d = draft();
    host.ticketDraft = d;
    const field = (name, label) => {
      if (name === 'company_id' || name === 'contact_id') {
        const company = name === 'company_id', kind = company ? 'COMPANY' : 'CONTACT';
        const cached = window.NRCAssets.roomAssets?.get(0n)?.get(BigInt(d[name] || '0'));
        const title = cached?.assetType === (company ? 8 : 9) ? metadata(cached).title : '';
        return `<label class="task-detail-row detail-edit-field"><span class="detail-edit-label" id="ticket-${name}-label">${kind}</span><nrc-select><select name="${name}" class="filter-select" aria-labelledby="ticket-${name}-label" disabled ${state.selected ? '' : 'data-custom-select-portal'} data-custom-select-search-placeholder="SEARCH ${kind === 'COMPANY' ? 'COMPANIES' : 'CONTACTS'}…"><option value="">NO ${kind}</option>${d[name] ? `<option value="${esc(d[name])}" data-company="${esc(d.company_id)}" selected>${esc(title || kind)} · #${esc(d[name])}</option>` : ''}</select></nrc-select>${company ? '<span id="ticketCompanyStatus" class="customer-meta" role="status"></span>' : ''}</label>`;
      }
      return `<label class="task-detail-row detail-edit-field"><span class="detail-edit-label">${label}</span><input class="task-detail-input" name="${name}" value="${esc(d[name])}"></label>`;
    };
    const resources = state.selected ? '<div id="ticketWork" class="document-resources ticket-resources" aria-label="Internal ticket resources">' + [
      ['tasks', 'TASKS', '<button type="button" class="btn" id="ticketLink">+ LINK TASK</button>'],
      ['slices', 'SLICES', '<button type="button" class="btn" id="ticketAssignSlice">+ ASSIGN SLICE</button>'],
      ['references', 'REFERENCES', '<button type="button" class="btn" id="ticketReference">+ LINK REFERENCE</button>'],
    ].map(([resource, label, actionHtml]) => window.NRCDetailUI.renderResourceBlock({
      resource, label, open: resourceOpen[resource] === true, actionHtml,
      bodyHtml: '<p class="customer-empty">Loading links…</p>',
    })).join('') + '</div><nrc-link-picker id="ticketLinkPicker"></nrc-link-picker>' : '';
    host.innerHTML = `<p id="ticketStatus" class="customer-status" role="status" aria-live="polite" hidden></p>${state.selected ? '<div id="ticketMetadata" class="record-document ticket-metadata"></div>' : `<h2>New ticket</h2>
        <form id="ticketFields">${field('title', 'TITLE')}${field('company_id', 'COMPANY ID')}${field('contact_id', 'CONTACT ID')}${field('requester', 'REQUESTER · PORTAL ACCOUNT IDENTITY')}${field('requester_name', 'REQUESTER NAME')}${field('assignee', 'ASSIGNEE')}
          <label class="task-detail-row">STATUS <select name="status" class="filter-select">${statuses.map(s => `<option value="${s}" ${d.status === s ? 'selected' : ''}>${statusLabels[s]}</option>`).join('')}</select></label>
          <label class="task-detail-row">PRIORITY <select name="priority" class="filter-select">${priorities.map(value => `<option value="${value}" ${d.priority === value ? 'selected' : ''}>${value.toUpperCase()}</option>`).join('')}</select></label>
          <label class="task-detail-row detail-edit-field"><span class="detail-edit-label">FOLLOW-UP · LOCAL TIME</span><input name="follow_up_at" type="datetime-local" class="task-detail-input" value="${esc(followUpInput(d.follow_up_at))}"></label>
          <label class="detail-edit-field ticket-original-request"><span class="detail-edit-label">ORIGINAL REQUEST</span><textarea name="body" class="task-detail-textarea" rows="5" maxlength="32000">${esc(d.body)}</textarea></label>
          <button class="btn btn--primary" data-save>SAVE TICKET</button>
        </form>`}<div id="ticketConversation" class="ticket-conversation"></div>
      ${state.selected ? `<form id="ticketReply"><fieldset class="choice-field ticket-audience"><legend>AUDIENCE</legend>${kinds.map(k => `<label class="radio-choice"><input type="radio" name="kind" value="${k}" ${d.kind === k ? 'checked' : ''}><span>${k === 'internal_note' ? 'INTERNAL NOTE' : 'PUBLIC REPLY'}</span></label>`).join('')}</fieldset><p id="ticketVisibility" class="customer-meta" role="status"></p><button type="button" class="btn" data-ticket-recipient hidden>USE CURRENT RECIPIENT</button><span id="ticketDraftState" class="customer-meta" role="status"></span><textarea name="message" class="task-detail-textarea" rows="4" maxlength="32000" aria-label="Ticket message"></textarea><button class="btn" data-save>SAVE INTERNAL NOTE</button></form>` : ''}${resources}`;
    window.NRCDetailUI.bindResourceBlocks({ root: host });
    const composer = host.querySelector(state.selected ? '#ticketReply' : '#ticketFields');
    composer.querySelector('button[data-save]')?.insertAdjacentHTML('beforebegin', attachmentComposer());
    const fileInput = host.querySelector('[data-ticket-files]');
    const addFiles = host.querySelector('[data-ticket-add-files]');
    if (addFiles) addFiles.onclick = () => { if (!state.pending) fileInput.click(); };
    if (fileInput) fileInput.onchange = () => {
      if (!state.pending) queueFiles(Array.from(fileInput.files || []), d, host);
      fileInput.value = '';
    };
    renderUploads(d, host);
    const messageField = host.querySelector('[name=message]'); if (messageField) messageField.value = d.message;
    const customerValues = state.selected ? { company_id: d.company_id, contact_id: d.contact_id } : d;
    const customerRoot = state.selected ? document.createElement('form') : host;
    if (state.selected) {
      customerRoot.className = 'customer-fields';
      customerRoot.innerHTML = field('company_id', 'COMPANY') + field('contact_id', 'CONTACT');
    }
    const companySelect = customerRoot.querySelector('[name=company_id]');
    if (companySelect) {
      const d = customerValues;
      const contactSelect = customerRoot.querySelector('[name=contact_id]');
      const status = customerRoot.querySelector('#ticketCompanyStatus');
      let loading = false, companies = [], pairs = [];
      const renderContacts = () => {
        const available = pairs.filter(p => !d.company_id || p.companyId === d.company_id);
        const retained = d.contact_id && !available.some(p => p.contactId === d.contact_id && p.companyId === d.company_id);
        contactSelect.innerHTML = '<option value="">NO CONTACT</option>' + available.map(p => `<option value="${p.contactId}" data-company="${p.companyId}" ${p.contactId === d.contact_id && p.companyId === d.company_id ? 'selected' : ''}>${esc(p.title)} · #${p.contactId} / ${esc(p.companyTitle)} · #${p.companyId}</option>`).join('') +
          (retained ? `<option value="${esc(d.contact_id)}" data-company="${esc(d.company_id)}" selected>CONTACT #${esc(d.contact_id)} · UNAVAILABLE</option>` : '');
        companySelect.disabled = loading || !!d.contact_id;
        status.textContent = d.contact_id ? 'Company fixed by contact. Clear CONTACT to change it.' : '';
      };
      companySelect.onchange = () => { d.company_id = companySelect.value; renderContacts(); };
      contactSelect.onchange = () => {
        d.contact_id = contactSelect.value;
        if (d.contact_id) {
          d.company_id = contactSelect.selectedOptions[0].dataset.company;
          companySelect.value = d.company_id;
        }
        renderContacts();
      };
      const loadCustomers = async () => {
        if (loading) return;
        loading = true; companySelect.disabled = true; contactSelect.disabled = true; status.textContent = 'Loading companies and contacts…';
        const isCancelled = () => !companySelect.isConnected;
        try {
          const [companyPage, contactPage] = await Promise.all([8, 9].map(type => window.NRCAssets.requestAllAssets(0n, type, { isCancelled })));
          if (isCancelled()) return;
          companies = companyPage.assets.filter(a => typeof metadata(a).title === 'string' && (!metadata(a).archived || String(a.assetId) === d.company_id))
            .sort((a, b) => metadata(a).title.localeCompare(metadata(b).title));
          const byId = new Map(companies.map(a => [String(a.assetId), a]));
          const loadedPairs = [];
          for (const contact of contactPage.assets.filter(a => typeof metadata(a).title === 'string' && (!metadata(a).archived || String(a.assetId) === d.contact_id))) {
            let page;
            do {
              page = await window.NRCEdges.requestEdgePage(0n, 1, contact.assetId, { session: page?.session, isCancelled });
            } while (page.hasMore);
            if (isCancelled()) return;
            const seen = new Set();
            for (const edge of window.NRCEdges.getEdgesForEntity(0n, 1, contact.assetId)) {
              if (edge.relation !== window.NRCEdges.RelationType.MemberOf || edge.sourceType !== 1 || edge.targetType !== 1) continue;
              const companyId = String(edge.sourceId === contact.assetId ? edge.targetId : edge.sourceId);
              if (!byId.has(companyId) || seen.has(companyId)) continue;
              seen.add(companyId);
              loadedPairs.push({ contactId: String(contact.assetId), title: metadata(contact).title, companyId, companyTitle: metadata(byId.get(companyId)).title });
            }
          }
          pairs = loadedPairs.sort((a, b) => a.title.localeCompare(b.title) || a.companyTitle.localeCompare(b.companyTitle));
          companySelect.innerHTML = '<option value="">NO COMPANY</option>' + companies.map(a => `<option value="${a.assetId}">${esc(metadata(a).title)} · #${a.assetId}${metadata(a).archived ? ' · ARCHIVED' : ''}</option>`).join('') +
            (d.company_id && !byId.has(d.company_id) ? `<option value="${esc(d.company_id)}">COMPANY #${esc(d.company_id)} · UNAVAILABLE</option>` : '');
          companySelect.value = d.company_id;
          renderContacts();
        } catch {
          if (!isCancelled()) status.textContent = 'Companies/contacts unavailable. Existing selection retained; reopen CUSTOMER or the new-ticket form to retry.';
        } finally {
          loading = false;
          if (!isCancelled()) { companySelect.disabled = !!d.contact_id; contactSelect.disabled = false; }
        }
      };
      if (state.selected) {
        const root = host.querySelector('#ticketMetadata');
        if (root) root.onclick = e => {
          if (!e.target.closest('[data-ticket-customer]') || state.pending) return;
          const base = state.tickets.find(a => String(a.assetId) === state.selected);
          const identity = session;
          Object.assign(d, { company_id: metadata(base).company_id, contact_id: metadata(base).contact_id });
          companySelect.innerHTML = '<option value="">NO COMPANY</option>' + (d.company_id ? `<option value="${esc(d.company_id)}" selected>COMPANY #${esc(d.company_id)}</option>` : '');
          renderContacts();
          const view = window.NRCModal.create({ title: 'CUSTOMER · COMPANY / CONTACT', className: 'file-assets-dialog', closeButton: true });
          customerRoot.querySelector('button[type="submit"]')?.remove();
          const submit = document.createElement('button'); submit.type = 'submit'; submit.className = 'btn btn--primary'; submit.textContent = 'SAVE CUSTOMER';
          customerRoot.append(submit); view.actions.before(customerRoot);
          view.canClose = () => !state.pending;
          customerRoot.onsubmit = async event => {
            event.preventDefault(); if (loading || state.pending) return;
            submit.disabled = true;
            companySelect.disabled = contactSelect.disabled = true;
            try { await saveMetadata(base, { ...d }, identity); view.close(); }
            catch (error) { status.textContent = error.message; }
            finally { submit.disabled = false; companySelect.disabled = !!d.contact_id; contactSelect.disabled = false; }
          };
          view.show(); loadCustomers();
        };
      } else loadCustomers();
    }
    host.oninput = e => { if (e.target.name) {
      try { d[e.target.name] = e.target.name === 'follow_up_at' ? followUpValue(e.target.value) : e.target.value; state.error = ''; state.notice = 'UNSAVED DRAFT'; }
      catch (error) { state.error = error.message; }
      renderStatus();
    } };
    host.onchange = host.oninput;
    const fields = host.querySelector('#ticketFields'); if (fields) fields.onsubmit = e => { e.preventDefault(); save(); };
    const reply = host.querySelector('#ticketReply'); if (reply) reply.onsubmit = e => { e.preventDefault(); save(true); };
    const link = host.querySelector('#ticketLink');
    if (link && window.NRCTasks?.sendCreateTask) {
      const entity = state.tickets.find(a => String(a.assetId) === state.selected);
      const create = document.createElement('button'); create.type = 'button'; create.className = 'btn'; create.dataset.save = ''; create.textContent = '+ CREATE TASK';
      create.onclick = async () => {
        if (state.pending || !await window.NRCDialog.confirm(`Create an internal task for “${metadata(entity).title}” and link it to this ticket?`, { title: 'CREATE LINKED TASK' })) return;
        if (state.pending) return;
        state.pending = true; state.error = ''; renderStatus();
        let task;
        try {
          const result = await write(options => window.NRCTasks.sendCreateTask(0n, metadata(entity).title, `Ticket #${entity.assetId}`, 128, 0, `ticket:${entity.assetId}`, 0n, [], 0, 0, '', options));
          task = result.task;
          await write(options => window.NRCEdges.sendCreateEdge(0n, 1, entity.assetId, 2, task.id, window.NRCEdges.RelationType.RelatedTo, options));
          state.notice = `TASK #${task.id} CREATED AND LINKED · TICKET STATUS UNCHANGED`; renderWork();
        } catch (error) {
          state.error = task ? `Task #${task.id} created, but link failed. Use LINK TASK to reconnect it. ${error.message}` : error.message;
        } finally { state.pending = false; renderStatus(); }
      };
      link.parentElement.append(create);
    }
    if (link) {
      const assign = host.querySelector('#ticketAssignSlice');
      assign.onclick = () => {
        const entity = state.tickets.find(a => String(a.assetId) === state.selected);
        host.querySelector('#ticketLinkPicker').open({ anchor: assign, sourceType: 1, sourceEntity: entity, kinds: ['slice'], relation: { value: window.NRCEdges.RelationType.MemberOf, label: 'MEMBER OF' }, onSelect: async item => {
          try {
            await write(options => window.NRCEdges.sendCreateEdge(0n, 1, entity.assetId, 1, item.id, window.NRCEdges.RelationType.MemberOf, options));
            renderWork();
          } catch (error) { state.error = error.message; renderStatus(); }
        } });
      };
    }
    if (link) link.onclick = () => {
      const entity = state.tickets.find(a => String(a.assetId) === state.selected);
      host.querySelector('#ticketLinkPicker').open({ anchor: link, sourceType: 1, sourceEntity: entity, kinds: ['task'], relation: { value: window.NRCEdges.RelationType.RelatedTo, label: 'RELATED TO' }, onSelect: async item => {
        try {
          await write(options => window.NRCEdges.sendCreateEdge(0n, 1, entity.assetId, item.type === 'task' ? 2 : 1, item.id, window.NRCEdges.RelationType.RelatedTo, options));
          renderWork();
        } catch (error) { state.error = error.message; renderStatus(); }
      } });
    };
    const reference = host.querySelector('#ticketReference');
    if (reference) reference.onclick = () => {
      const entity = state.tickets.find(a => String(a.assetId) === state.selected);
      host.querySelector('#ticketLinkPicker').open({ anchor: reference, sourceType: 1, sourceEntity: entity, kinds: ['note', 'file'], onSelect: async (item, relation) => {
        try {
          await write(options => window.NRCEdges.sendCreateEdge(0n, 1, entity.assetId, 1, item.id, relation, options));
          await window.NRCLinksUI.loadLinks(0n, 1, entity.assetId, () => state.selected !== String(entity.assetId));
          renderWork();
        } catch (error) { state.error = error.message; renderStatus(); }
      } });
    };
    if (state.selected) {
      renderWork();
      hydrateWork();
    }
    renderMetadata(); renderConversation(); renderSavedAttachments(); renderStatus();
  }
  async function hydrateWork() {
    if (!state.selected || !window.NRCLinksUI?.loadLinks) return;
    if (workLoading) { workAgain = true; return; }
    workLoading = true;
    const id = state.selected, token = generation;
    const cancelled = () => state.selected !== id || generation !== token;
    try {
      await window.NRCLinksUI.loadLinks(0n, 1, BigInt(id), cancelled);
      if (!cancelled()) renderWork();
    } catch (error) {
      if (!cancelled()) { state.error = `Links unavailable: ${error.message}`; renderStatus(); }
    } finally {
      workLoading = false;
      if (workAgain) { workAgain = false; hydrateWork(); }
    }
  }
  function renderWork() {
    const work = document.getElementById('ticketWork'); if (!work || !window.NRCEdges) return;
    if (!state.selected) return;
    const id = BigInt(state.selected);
    const groups = { tasks: [], slices: [], references: [] };
    for (const e of window.NRCEdges.getEdgesForEntity(0n, 1, id)) {
      const outgoing = e.sourceType === 1 && e.sourceId === id;
      const type = outgoing ? e.targetType : e.sourceType, target = outgoing ? e.targetId : e.sourceId;
      const asset = type === 1 ? window.NRCAssets.roomAssets?.get(0n)?.get(target) : null;
      const task = type === 2 ? window.NRCTasks?.roomTasks?.get(0n)?.get(target) : null;
      const group = type === 2 ? 'tasks' : asset?.assetType === 11 && e.relation === window.NRCEdges.RelationType.MemberOf ? 'slices' : 'references';
      const kind = window.NRCLinksUI.linkTargetKind(type, asset).label;
      const title = window.NRCLinksUI.resolveTargetName(0n, type, target);
      const context = task ? `<span class="customer-meta ticket-work-context">${esc(window.NRCTasks.TaskStatusNames[task.status])} · ${esc(task.assignee || 'UNASSIGNED')}</span>` : '';
      groups[group].push(`<div class="note-link-item" data-edge-id="${e.edgeId}">
        <span class="note-link-direction" aria-label="${outgoing ? 'Outgoing link' : 'Incoming link'}">${outgoing ? '→' : '←'}</span>
        <span class="note-link-kind" data-kind="${esc(kind.toLowerCase())}">${esc(kind)}</span>
        <span class="note-link-relation" data-relation="${e.relation}">${esc(window.NRCEdges.RelationTypeNames?.[e.relation] || 'link')}</span>
        <button type="button" class="note-link-target" data-work-id="${target}" data-work-type="${type}">${esc(title)}${context}</button>
        <button type="button" class="btn btn--row btn--danger note-link-delete" data-remove-work="${e.edgeId}" data-save title="Remove link" aria-label="Remove link to ${esc(title)}" ${state.pending ? 'disabled' : ''}>×</button>
      </div>`);
    }
    for (const [name, rows] of Object.entries(groups)) {
      const block = work.querySelector(`[data-resource="${name}"]`); if (!block) continue;
      block.querySelector('[data-resource-count]').textContent = String(rows.length);
      block.querySelector('.record-resource-body').innerHTML = rows.join('') || '<p class="customer-empty">No linked records.</p>';
    }
    work.onclick = async e => {
      const remove = e.target.closest('[data-remove-work]');
      if (remove) {
        if (state.pending) return;
        state.pending = true; state.error = ''; renderStatus();
        try {
          await write(options => window.NRCEdges.sendDeleteEdge(0n, BigInt(remove.dataset.removeWork), options));
          renderWork();
        } catch (error) { state.error = error.message; }
        finally { state.pending = false; renderStatus(); }
        return;
      }
      const b = e.target.closest('[data-work-id]');
      if (b) window.NRCLinksUI.navigateToTarget(0n, Number(b.dataset.workType), BigInt(b.dataset.workId));
    };
  }
  function open(company = '', id = '') {
    state.filters.company = String(company);
    window.NRCViewManager.setActiveView('tickets');
    const filter = document.querySelector('#ticketsPanel [data-filter=company]'); if (filter) filter.value = state.filters.company;
    if (id) selectTicket(String(id));
    else if (!window.NRCInspector) { state.selected = ''; editor(); }
    reload();
  }
  function selectTicket(id) {
    if (window.NRCInspector) return window.NRCInspector.openEntity({ type: 'ticket', id: BigInt(id || '0') }, { replaceCurrent: window.NRCInspector.current()?.type === 'ticket' });
    state.selected = String(id); state.entries = []; state.detailLoading = !!id; editor(); renderList(); return loadDetail();
  }
  async function showInspector(ref, stillCurrent) {
    if (state.selected !== (ref.id ? String(ref.id) : '')) { state.error = ''; state.notice = ''; }
    state.selected = ref.id ? String(ref.id) : '';
    const host = document.getElementById('inspectorEntityHost');
    const header = document.getElementById('inspectorHeader');
    if (!host || !header) return;
    const record = document.createElement('article'); record.id = 'ticketEditor'; record.className = 'customer-record'; record.setAttribute('aria-label', 'Ticket detail');
    host.replaceChildren(record);
    header.innerHTML = `<div class="inspector-identity-row"><span class="header-text identity-reference">${ref.id ? `TICKET #${ref.id}` : 'NEW TICKET'}</span><span class="inspector-cell-label">STATE</span><span class="status-value-mono inspector-state-value">${ref.id ? 'READ' : 'EDITING'}</span></div><div class="inspector-mode-row">${window.NRCDetailUI.renderHeaderAction({ id: 'ticketReplyFocus', label: 'MESSAGE', command: 'm', title: 'Focus message composer (M)' })}${ref.id ? window.NRCDetailUI.renderHeaderMetadata([], 2, ref.id) : ''}${window.NRCDetailUI.renderCloseControl('ticketInspectorClose')}</div>`;
    document.getElementById('ticketInspectorClose').onclick = () => window.NRCInspector.close();
    document.getElementById('ticketReplyFocus').onclick = () => record.querySelector('[name=message], [name=title]')?.focus();
    state.entries = []; state.detailLoading = !!ref.id; editor(); renderList();
    await loadDetail();
    if (!stillCurrent()) return;
    if (ref.id && !record.ticketDraft) editor();
  }
  async function confirmDiscardEdits() {
    // Reply/new-ticket drafts are record-owned, not Inspector-owned. Field-local
    // edits use the same outside-click / Escape cancellation as tasks and notes.
    return !state.pending;
  }
  function clearSelection() {
    state.selected = '';
    state.entries = []; state.detailLoading = false;
    renderList();
  }
  async function mountCustomer(container, companyId) {
    if (!container) return;
    const id = String(companyId);
    const generation = (container.ticketGeneration || 0) + 1;
    container.ticketGeneration = generation;
    if (container.ticketCompany !== id) container.textContent = '';
    container.ticketCompany = id;
    container.setAttribute('aria-busy', 'true');
    container.inert = true;
    const loadingTimer = setTimeout(() => {
      if (container.isConnected && container.ticketGeneration === generation && !container.textContent) {
        container.textContent = 'Loading tickets from NRC…';
      }
    }, 150);
    try {
      const { assets, has_more, total_count } = await window.NRCAssets.requestTicketPage({ company: id, sort: 'activity', descending: true, limit: 25 });
      if (!container.isConnected || container.ticketGeneration !== generation) return;
      const tickets = assets;
      container.innerHTML = tickets.map(asset => `<button class="customer-event" data-customer-ticket="${asset.assetId}"><span class="customer-meta">#${asset.assetId} / ${esc(metadata(asset).status)}</span><strong>${esc(metadata(asset).title)}</strong></button>`).join('') || '<p class="customer-empty">No tickets for this customer.</p>';
      if (has_more) container.innerHTML += `<button class="btn" data-all-tickets>VIEW ALL ${total_count} TICKETS</button>`;
      container.onclick = event => { const row = event.target.closest('[data-customer-ticket]'); if (row) open(id, row.dataset.customerTicket); else if (event.target.closest('[data-all-tickets]')) open(id); };
    } catch (error) { if (container.isConnected && container.ticketGeneration === generation) container.textContent = `Tickets unavailable: ${error.message}. Open tickets to retry.`; }
    finally {
      clearTimeout(loadingTimer);
      if (container.ticketGeneration === generation) {
        container.setAttribute('aria-busy', 'false');
        container.inert = false;
      }
    }
  }
  function init() {
    const nav = document.getElementById('ticketsBtn'); if (!nav) return;
    nav.onclick = () => open();
    document.getElementById('ticketNew').onclick = () => selectTicket('');
    document.getElementById('ticketsRefresh').onclick = () => { state.error = ''; reload(); };
    document.getElementById('ticketsPager')?.addEventListener('nrc:load-more', () => loadPage(!state.cursor));
    document.getElementById('ticketsList').onclick = e => { const row = e.target.closest('[data-ticket]'); if (row) selectTicket(row.dataset.ticket); };
    document.getElementById('ticketsList').onkeydown = e => {
      if (!e.target.matches('[data-ticket]') || !['Enter', ' '].includes(e.key)) return;
      e.preventDefault(); e.stopPropagation(); selectTicket(e.target.dataset.ticket);
    };
    document.getElementById('ticketsSort')?.addEventListener('change', e => {
      [state.sort, state.direction] = e.target.value.split(':');
      loadPage(true);
    });
    document.querySelectorAll('#ticketsTable th[data-sort]').forEach(th => th.onclick = e => {
      if (e.target.closest('.column-resize-handle')) return;
      state.direction = state.sort === th.dataset.sort && state.direction === 'asc' ? 'desc' : 'asc';
      state.sort = th.dataset.sort; loadPage(true);
    });
    document.addEventListener('keydown', e => {
      if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || e.shiftKey || window.NRCViewManager?.getActiveView?.() !== 'tickets') return;
      if (e.target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) || e.target.closest?.('#inspector, dialog, nrc-select, nrc-link-picker, [role="menu"], .column-resize-handle')) return;
      if (!['ArrowDown', 'ArrowUp', 'Enter'].includes(e.key)) return;
      const rows = document.querySelectorAll('#ticketsList [data-ticket]');
      const adjacent = e.key === 'Enter' ? null : window.NRCListNavigation.resolveAdjacent(rows, state.selected || null, e.key === 'ArrowDown' ? 1 : -1, row => row.dataset.ticket);
      if (adjacent?.status === 'boundary') { e.preventDefault(); return; }
      const next = e.key === 'Enter' ? Array.from(rows).find(row => row.dataset.ticket === state.selected) : adjacent.row;
      if (!next || e.key === 'Enter' && e.target.closest('button')) return;
      e.preventDefault();
      Promise.resolve(selectTicket(next.dataset.ticket)).then(opened => {
        if (opened === false) return;
        const row = document.querySelector(`#ticketsList [data-ticket="${next.dataset.ticket}"]`);
        row?.scrollIntoView({ block: 'nearest' });
        if (!document.body.classList.contains('inspector-open')) row?.querySelector('button')?.focus({ preventScroll: true });
      });
    });
    document.querySelectorAll('#ticketsPanel [data-filter]').forEach(el => {
      el[el.tagName === 'SELECT' ? 'onchange' : 'oninput'] = () => { state.filters[el.dataset.filter] = el.value; updateSearch({ debounce: el.dataset.filter === 'search' }); };
    });
    for (const type of ['nrc:asset-created', 'nrc:asset-updated', 'nrc:asset-deleted']) document.addEventListener(type, e => {
      const asset = e.detail?.asset;
      if (type === 'nrc:asset-deleted' && asset?.assetType === 13) window.NRCInspector?.entityDeleted({ type: 'ticket', id: asset.assetId });
      const unknownDeletion = type === 'nrc:asset-deleted' && !asset && e.detail?.convId === 0n;
      const renamedSortDependency = [8, 9].includes(asset?.assetType) && ['company_id', 'contact_id'].includes(state.sort);
      if ([13, 14].includes(asset?.assetType) || unknownDeletion || renamedSortDependency) scheduleRefresh();
      else { renderWork(); renderList(); }
    });
    document.addEventListener('nrc:task-changed', e => {
      renderWork();
      const task = e.detail?.task;
      if (state.selected && task?.convId === 0n && e.detail.reason !== 'deleted' && window.NRCEdges.getEdgesForEntity(0n, 1, BigInt(state.selected)).some(edge =>
        (edge.sourceType === 2 && edge.sourceId === task.id) || (edge.targetType === 2 && edge.targetId === task.id))) hydrateWork();
    });
    document.addEventListener('nrc:record-activity', e => {
      if (e.detail?.kind !== 'ticket') return;
      refreshAttention(); if (state.rows.length || state.loading) loadPage(true, true);
    });
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && session && typeof serverReady !== 'undefined' && serverReady) refreshAttention();
    });
    window.NRCEdges?.addEdgeChangeListener?.((edge, reason) => {
      renderWork();
      if (state.selected && reason === 'created' && edge.convId === 0n &&
        ((edge.sourceType === 1 && String(edge.sourceId) === state.selected) || (edge.targetType === 1 && String(edge.targetId) === state.selected))) hydrateWork();
    });
  }
  function disconnect() {
    clearTimeout(attentionTimer);
    generation++; state.loading = false; state.reloadAgain = false;
    searchController?.cancel(); searchState = { mode: 'idle', ids: new Set(), stale: false };
    state.tickets = []; state.entries = []; state.rows = []; state.attention = []; state.hasMore = false; state.total = 0;
    renderList(); publishActivity();
  }
  function sessionStarted() {
    const identity = JSON.stringify([currentWorkspaceId, myNickname]);
    if (session && session !== identity) {
      disconnect(); state.selected = ''; state.drafts.clear(); state.filters = {}; state.error = ''; state.notice = '';
      const host = document.getElementById('ticketEditor'); if (host) host.innerHTML = '';
    }
    session = identity; reload();
  }
  window.NRCTickets = { open, reload, metadata, matches, conversation, mountCustomer, state, activity, snapshot, disconnect, sessionStarted, showInspector, clearSelection, confirmDiscardEdits };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
