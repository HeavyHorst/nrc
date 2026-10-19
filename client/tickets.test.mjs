import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('./tickets.js', import.meta.url), 'utf8');
function fixture(uploadFile = async () => { throw new Error('upload unavailable'); }) {
  const listeners = new Map();
  const elements = new Map();
  const element = () => ({ isConnected: true, innerHTML: '', textContent: '', value: '', dataset: {}, addEventListener() {}, append(child) { this.lastChild = child; }, parentElement: { append(child) { this.lastChild = child; }, parentElement: { after() {} } },
    closest() { return { after() {} }; }, before() {},
    querySelectorAll() { return []; },
    querySelector(selector) { return elements.get(selector) || null; } });
  for (const id of ['ticketsBtn', 'ticketNew', 'ticketsRefresh', 'ticketsList', 'ticketEditor', 'ticketMetadata', 'ticketsStatus', 'ticketVisibility', 'ticketConversation', 'ticketWork', '#ticketFields', '#ticketReply', '#ticketLink', '#ticketAssignSlice', '#ticketLinkPicker']) elements.set(id, element());
  elements.set('ticketReply', elements.get('#ticketReply'));
  elements.set('[data-ticket-files]', element());
  elements.set('[data-ticket-uploads]', element());
  elements.set('[data-ticket-recipient]', element());
  let success, failure;
  const sent = [], pages = [];
  const window = {
    NRCViewManager: { setActiveView() {} },
    NRCAssets: {
      requestAllAssets: async (room, type, options) => { pages.push([room, type, options]); return { assets: type === 13 ? records : entries }; },
      requestTicketPage: async query => {
        pages.push(query);
        const assets = query.mode === 'entries' ? entries.filter(a => String(a.parentId) === query.parent) : records;
        return { assets, total_count: assets.length, has_more: false, cursor: {} };
      },
      requestAssetsByIds: async () => [],
      sendCreateAsset(...args) { sent.push(args); success = args[7].onSuccess; failure = args[7].onError; return 7; },
      sendUpdateAsset(...args) { sent.push(args); success = args[6].onSuccess; failure = args[6].onError; return 8; },
      sendGetAsset(room, id, options) { options.onSuccess({ asset: records.find(a => a.assetId === id) }); return 9; },
    },
    NRCEdges: { getEdgesForEntity: () => [], RelationType: { RelatedTo: 2 } },
    NRCLinksUI: { loadLinks: async () => {} },
  };
  window.NRCTransactions = { sendAssetMetadataPatch(asset, preview, payload, options) {
    return window.NRCAssets.sendUpdateAsset(0n, asset.assetId, preview, payload, 13, 0, options, asset.attachments);
  } };
  const records = [1n, 2n].map(assetId => ({ assetId, updatedAt: 123456789n, convId: 0n, assetType: 13, payload: 'Original request', attachments: [{ fileId: 7n }], preview: JSON.stringify({ version: 1, title: `Ticket ${assetId}`, company_id: '42', contact_id: '', requester: 'ada@example.test', status: 'open', assignee: 'Sam' }) }));
  const entries = [];
  const document = { readyState: 'complete', getElementById: id => elements.get(id) || null, querySelector: () => null, querySelectorAll: () => [],
    addEventListener(name, callback) { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(callback); }, createElement: element };
  vm.runInNewContext(readFileSync(new URL('./detail-ui.js', import.meta.url), 'utf8'), { window, TextEncoder });
  const controls = new Map();
  window.NRCDetailUI.inlineField = spec => { controls.set(spec.name, spec); return ''; };
  vm.runInNewContext(source, { window, document, myNickname: 'Staff', uploadFile });
  const submit = async form => { elements.get(form).onsubmit({ preventDefault() {} }); await Promise.resolve(); };
  const input = (name, value) => elements.get('ticketEditor').oninput({ target: { name, value } });
  return { api: window.NRCTickets, window, elements, records, entries, sent, pages, submit, input,
    event: (name, detail) => listeners.get(name)?.forEach(callback => callback({ detail })),
    edit: (name, value) => controls.get(name).save(value), ack: value => success(value), fail: message => failure({ message }) };
}

test('company ID is authoritative and public conversation excludes internal and unknown kinds', async () => {
  const f = fixture(); await f.api.reload();
  assert.equal(f.api.matches(f.records[0], { company: '42', status: 'open', owner: 'Sam', search: 'ADA' }), true);
  assert.equal(f.api.matches(f.records[0], { company: '43' }), false);
  f.api.state.entries = ['internal_note', 'customer_reply', 'public_reply', 'unknown'].map((kind, i) => ({ assetId: BigInt(i), parentType: 2, parentId: 1n, createdAt: BigInt(4 - i), preview: JSON.stringify({ kind }) }));
  assert.deepEqual(Array.from(f.api.conversation('1', false), a => f.api.metadata(a).kind), ['public_reply', 'customer_reply']);
  assert.deepEqual(Array.from(f.api.conversation('1', true), a => f.api.metadata(a).kind), ['internal_note']);
  assert.deepEqual(f.pages.map(p => p.mode || 'register'), ['register', 'attention']);
  f.entries.push(...f.api.state.entries);
  f.api.open('', '1');
  await f.api.reload();
  const html = f.elements.get('ticketConversation').innerHTML;
  for (const label of ['PUBLIC REPLY', 'CUSTOMER REPLY', 'INTERNAL NOTE']) assert.ok(html.includes(`${label} /`));
  assert.doesNotMatch(html, /public_reply|customer_reply|internal_note|unknown/);
});

test('ticket register sends filters and sort before paging and ignores an obsolete response', async () => {
  const f = fixture(), pending = [];
  f.window.NRCAssets.requestAllAssets = () => { throw new Error('register must not download every ticket or entry'); };
  f.window.NRCAssets.requestTicketPage = query => query.mode === 'attention'
    ? Promise.resolve({ assets: [], has_more: false })
    : new Promise(resolve => pending.push({ query, resolve }));
  f.api.state.filters = { status: 'open', owner: 'Sam', company: '42' };
  f.api.state.sort = 'title'; f.api.state.direction = 'asc';
  const old = f.api.reload();
  f.api.state.filters.status = 'closed';
  const current = f.api.reload();
  assert.equal(pending[1].query.status, 'closed');
  assert.equal(pending[1].query.assignee, 'Sam');
  assert.equal(pending[1].query.company, '42');
  assert.equal(pending[1].query.sort, 'title');
  assert.equal(pending[1].query.descending, false);
  assert.equal(pending[1].query.limit, 50);
  pending[1].resolve({ assets: [f.records[1]], total_count: 61, has_more: true, cursor: { id: '2' } });
  await current;
  pending[0].resolve({ assets: [f.records[0]], total_count: 1, has_more: false, cursor: { id: '1' } });
  await old;
  assert.deepEqual(Array.from(f.api.state.rows, a => a.assetId), [2n]);
  assert.equal(f.api.state.total, 61);
  assert.equal(f.api.state.hasMore, true);
  assert.equal(f.api.state.cursor.id, '2');
  assert.equal(f.api.state.entries.length, 0);
});

test('a read acknowledgement supersedes an initial page that captured older unread state', async () => {
  const f = fixture(), pending = [];
  let through = '0';
  f.window.NRCRecordActivity = { cursors: () => ({ '1': through }), cursor: () => BigInt(through) };
  f.window.NRCAssets.requestTicketPage = query => query.mode === 'attention'
    ? Promise.resolve({ assets: [], has_more: false })
    : new Promise(resolve => pending.push({ query, resolve }));
  const first = f.api.reload();
  through = '10';
  f.event('nrc:record-activity', { kind: 'ticket', id: '1' });
  assert.equal(pending.length, 2);
  assert.equal(pending[1].query.read['1'], '10');
  pending[0].resolve({ assets: [f.records[0]], total_count: 1, has_more: false });
  await first;
  assert.equal(f.api.state.rows.length, 0, 'obsolete initial response cannot commit');
  pending[1].resolve({ assets: [f.records[1]], total_count: 1, has_more: false });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(Array.from(f.api.state.rows, a => a.assetId), [2n]);
});

test('read and unknown-deletion refreshes retain loaded depth; task activity does not reset tickets', async () => {
  const f = fixture();
  const rows = Array.from({ length: 61 }, (_, i) => ({ ...f.records[0], assetId: BigInt(i + 1) }));
  let reads = 0;
  f.window.NRCAssets.requestTicketPage = async query => {
    if (query.mode === 'attention') return { assets: [], has_more: false };
    reads++;
    const start = query.cursor?.id ? 50 : 0;
    return { assets: rows.slice(start, start + 50), total_count: 61, has_more: start === 0, cursor: { id: String(start + 50) } };
  };
  f.api.state.rows = rows;
  f.event('nrc:record-activity', { kind: 'task' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(reads, 0);
  f.event('nrc:record-activity', { kind: 'ticket', id: '60' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.api.state.rows.length, 61);
  assert.equal(reads, 2);
  f.event('nrc:asset-deleted', { convId: 0n, assetId: 999n, asset: null });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(reads, 4);
  assert.equal(f.api.state.rows.length, 61);
  f.api.state.sort = 'company_id';
  f.event('nrc:asset-updated', { asset: { assetType: 8 } });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(reads, 6, 'linked-name ordering is server-derived and must be refreshed');
});

test('staff conversation displays email provenance and precise mail status as escaped metadata', async () => {
  const f = fixture();
  const original = JSON.parse(f.records[0].preview);
  f.records[0].preview = JSON.stringify({ ...original, channel: 'email' });
  for (const [i, status] of ['queued', 'sent', 'failed', 'unknown'].entries()) {
    f.entries.push({ assetId: BigInt(10 + i), parentType: 2, parentId: 1n, createdAt: 1n, payload: 'Reply', preview: JSON.stringify({ kind: 'public_reply', channel: 'email', recipient: 'ada@example.test', mail_delivery: status }) });
  }
  await f.api.reload(); f.api.open('', '1');
  await f.api.reload();
  const html = f.elements.get('ticketConversation').innerHTML;
  assert.match(html, /ORIGINAL REQUEST[^<]*EMAIL/);
  for (const label of ['TO ada@example.test', 'MAIL QUEUED', 'MAIL SERVER ACCEPTED', 'MAIL FAILED', 'MAIL STATUS UNKNOWN']) assert.ok(html.includes(label));
  assert.doesNotMatch(html, /DELIVERED|FORWARDED BY/);
});

test('failed and pending saves preserve per-record drafts and never report dispatch as success', async () => {
  const f = fixture(); await f.api.reload(); f.api.open('', '1'); await f.api.reload();
  const initialSections = f.elements.get('ticketConversation').innerHTML.split('</section>');
  assert.match(initialSections[0], /ORIGINAL REQUEST/);
  assert.doesNotMatch(initialSections[0], /No entries/);
  assert.match(initialSections[1], /No entries/);
  f.input('message', 'Reply draft');
  const saving = f.edit('TITLE', '<unsaved>');
  const rejected = assert.rejects(saving, /Permission denied/);
  assert.equal(f.api.state.pending, true);
  assert.match(f.elements.get('ticketsStatus').textContent, /awaiting NRC/);
  assert.equal(f.sent[0][1], 1n);
  assert.equal(JSON.parse(f.sent[0][2]).title, '<unsaved>');
  assert.equal(f.sent[0][7][0].fileId, 7n);
  f.api.open('', '2'); f.fail('Permission denied'); await new Promise(resolve => setImmediate(resolve));
  await rejected;
  assert.equal(f.api.state.selected, '2');
  assert.match(f.elements.get('ticketsStatus').textContent, /Permission denied/);
  f.api.open('', '1');
  assert.equal(f.api.state.drafts.get('1').message, 'Reply draft');
  await f.api.reload();
  assert.equal(f.api.state.drafts.get('1').title, 'Ticket 1');
});

test('entry defaults internal; public reply requires explicit mode and keeps draft on rejection', async () => {
  const f = fixture(); await f.api.reload(); f.api.open('', '1');
  f.input('message', 'Private triage'); await f.submit('#ticketReply');
  assert.equal(f.sent[0][1], 14); assert.equal(f.sent[0][2], 2); assert.equal(f.sent[0][3], 1n);
  assert.deepEqual(JSON.parse(f.sent[0][4]), { version: 1, kind: 'internal_note', author: 'Staff' });
  f.fail('offline'); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.api.state.drafts.get('1').message, 'Private triage');
  f.input('kind', 'public_reply'); await f.submit('#ticketReply');
  assert.equal(JSON.parse(f.sent[1][4]).kind, 'public_reply');
  assert.equal(JSON.parse(f.sent[1][4]).recipient, 'ada@example.test');
  assert.equal(f.sent[1][7].ifParentUpdatedAt, 123456789n);
  assert.equal(f.sent[0][7].ifParentUpdatedAt, undefined);
  f.fail('Asset parent version conflict'); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.api.state.drafts.get('1').message, 'Private triage');
  assert.equal(f.api.state.drafts.get('1').kind, 'public_reply');
  assert.match(f.elements.get('ticketsStatus').textContent, /Asset parent version conflict/);
  await f.submit('#ticketReply');
  f.ack({ asset: { assetId: 10n } }); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.api.state.drafts.get('1').message, '');
  assert.equal(f.api.state.drafts.get('1').kind, 'internal_note');
});

test('selection failure never substitutes another record; failed refresh retains current draft', async () => {
  const f = fixture(); await f.api.reload(); f.api.open('', '999');
  assert.match(f.elements.get('ticketEditor').innerHTML, /unavailable/);
  assert.equal(f.api.state.drafts.has('999'), false);
  f.api.open('', '1'); f.input('message', 'Keep me');
  await new Promise(resolve => setImmediate(resolve));
  f.window.NRCAssets.requestTicketPage = async () => { throw new Error('read failed'); };
  await f.api.reload();
  assert.equal(f.api.state.selected, '1'); assert.equal(f.api.state.drafts.get('1').message, 'Keep me');
  assert.match(f.api.state.error, /read failed/);
});

test('create adopts acknowledged ID; a later save updates instead of duplicating the ticket', async () => {
  const f = fixture(); await f.api.reload(); f.api.open('42');
  f.input('title', 'New request'); f.input('body', 'Original'); await f.submit('#ticketFields');
  assert.equal(f.sent[0][1], 13); assert.equal(f.sent[0][2], 0);
  const asset = { ...f.records[0], assetId: 3n, preview: f.sent[0][4], payload: f.sent[0][5] };
  f.input('body', 'Late draft must not masquerade as the original');
  f.records.push(asset); f.ack({ asset }); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.api.state.selected, '3');
  assert.match(f.elements.get('ticketConversation').innerHTML, />Original<\/p>/);
  assert.doesNotMatch(f.elements.get('ticketConversation').innerHTML, /Late draft/);
  const update = f.edit('STATUS', 'resolved');
  assert.equal(f.sent[1][1], 3n); assert.equal(JSON.parse(f.sent[1][2]).status, 'resolved');
  assert.equal(f.sent[1][3], null, 'metadata edits leave the original request untouched');
  f.records[2] = { ...asset, preview: f.sent[1][2] };
  f.input('message', 'Reply written while saving'); f.ack({ asset }); await update;
  assert.equal(f.api.state.drafts.get('3').message, 'Reply written while saving');
  assert.match(f.elements.get('ticketConversation').innerHTML, />Original<\/p>/);
});

test('a concurrent edit between ACK and readback cannot become the base of an older draft', async () => {
  const f = fixture(); await f.api.reload(); f.api.open('', '1');
  await new Promise(resolve => setImmediate(resolve));
  const updating = assert.rejects(f.edit('ASSIGNEE', 'My change'), /Ticket changed again/);
  f.records[0] = { ...f.records[0], preview: JSON.stringify({ ...JSON.parse(f.sent[0][2]), assignee: 'Other staff' }) };
  f.ack({}); await new Promise(resolve => setImmediate(resolve));
  await updating;
  assert.match(f.api.state.error, /Ticket changed again/);
  f.window.NRCTransactions.sendAssetMetadataPatch = (base, preview, payload, options) => {
    if (base.preview !== f.records[0].preview) options.onError({ message: 'stale draft' });
    else { f.records[0].preview = preview; options.onSuccess({}); }
    return 1;
  };
  await assert.rejects(f.edit('ASSIGNEE', 'My change'), /stale draft/);
  assert.match(f.api.state.error, /stale draft/);
  assert.equal(JSON.parse(f.records[0].preview).assignee, 'Other staff');
});

test('public recipient is persisted identity, not an unsaved requester draft', async () => {
  const f = fixture(); await f.api.reload(); f.api.open('', '1');
  f.input('requester', 'different@example.test'); f.input('kind', 'public_reply'); f.input('message', 'Hello');
  assert.match(f.elements.get('ticketVisibility').textContent, /PUBLIC REPLY TO ada@example.test/);
  assert.doesNotMatch(f.elements.get('ticketVisibility').textContent, /different@example.test/);
  await f.submit('#ticketReply'); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.sent.length, 0);
  assert.match(f.api.state.error, /Requester changed/);
  assert.equal(f.api.state.drafts.get('1').message, 'Hello');
  const uploads = f.api.state.drafts.get('1').uploads;
  uploads.push({ filename: 'inflight.png' });
  f.records[0] = { ...f.records[0], preview: JSON.stringify({ ...JSON.parse(f.records[0].preview), requester: 'new@example.test' }) };
  await f.api.reload();
  assert.equal(f.elements.get('[data-ticket-recipient]').hidden, false);
  f.elements.get('[data-ticket-recipient]').onclick();
  assert.equal(f.api.state.drafts.get('1').requester, 'new@example.test');
  assert.equal(f.api.state.drafts.get('1').message, 'Hello');
  assert.equal(f.api.state.drafts.get('1').kind, 'public_reply');
  assert.equal(f.api.state.drafts.get('1').uploads, uploads);
  assert.equal(uploads[0].filename, 'inflight.png');
});

test('disconnect during metadata ACK or readback never reports successful persistence', async () => {
  for (const boundary of ['ack', 'readback']) {
    const f = fixture(); await f.api.reload(); f.api.open('', '1');
    await new Promise(resolve => setImmediate(resolve));
    let readback;
    f.window.NRCAssets.sendGetAsset = (room, id, options) => { readback = options; return 9; };
    const saving = assert.rejects(f.edit('TITLE', 'Retain this edit'), /Save not confirmed/);
    if (boundary === 'readback') { f.ack({}); await new Promise(resolve => setImmediate(resolve)); }
    f.api.disconnect();
    if (boundary === 'ack') f.fail('Disconnected');
    else readback.onError({ message: 'Disconnected' });
    await saving;
    assert.equal(f.api.state.pending, false);
    assert.equal(f.api.state.drafts.get('1').title, 'Ticket 1');
    assert.doesNotMatch(f.api.state.notice, /ACKNOWLEDGED/);
    if (boundary === 'ack') assert.equal(readback, undefined);
  }
});

test('unavailable transport is not a successful save', async () => {
  const f = fixture(); await f.api.reload(); f.api.open('', '1'); f.input('message', 'Reply draft');
  f.window.NRCAssets.sendUpdateAsset = () => 0;
  await assert.rejects(f.edit('TITLE', 'Offline draft'), /Not connected/);
  assert.equal(f.api.state.pending, false);
  assert.match(f.api.state.error, /Not connected/);
  assert.equal(f.api.state.drafts.get('1').message, 'Reply draft');
});

test('reply attachments block unsettled uploads, survive rejection and clear only acknowledged files', async () => {
  const f = fixture(); await f.api.reload(); f.api.open('', '1');
  const d = f.api.state.drafts.get('1');
  const upload = { filename: 'private.txt' };
  d.uploads.push(upload); f.input('message', 'Private file');
  await f.submit('#ticketReply');
  assert.equal(f.sent.length, 0);
  upload.attachment = { fileId: 'private', filename: 'private.txt', size: 7n };
  await f.submit('#ticketReply');
  assert.equal(JSON.parse(f.sent[0][4]).kind, 'internal_note');
  assert.equal(f.sent[0][8][0], upload.attachment);
  f.fail('rejected'); await new Promise(resolve => setImmediate(resolve));
  assert.equal(d.uploads[0], upload);
  f.input('kind', 'public_reply'); await f.submit('#ticketReply');
  assert.equal(JSON.parse(f.sent[1][4]).kind, 'public_reply');
  const newer = { attachment: { fileId: 'newer' } }; d.uploads.push(newer);
  f.api.open('', '2'); f.ack({ asset: { assetId: 12n } });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(Array.from(d.uploads), [newer]);
  assert.equal(f.api.state.drafts.get('2').uploads.length, 0);
});

test('new ticket attachments use asset metadata, never preview JSON, and survive failed creation', async () => {
  const f = fixture(); await f.api.reload(); f.api.open();
  f.input('title', 'Attached request');
  const d = f.api.state.drafts.get('');
  const attachment = { fileId: 'original', filename: 'original.txt', size: 12n };
  d.uploads.push({ attachment });
  await f.submit('#ticketFields');
  assert.equal(f.sent[0][8][0], attachment);
  assert.equal('uploads' in JSON.parse(f.sent[0][4]), false);
  f.fail('offline'); await new Promise(resolve => setImmediate(resolve));
  assert.equal(d.uploads[0].attachment, attachment);
  await f.submit('#ticketFields');
  const asset = { ...f.records[0], assetId: 3n, preview: f.sent[1][4], attachments: [attachment] };
  f.records.push(asset); f.ack({ asset }); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.api.state.selected, '3'); assert.equal(d.uploads.length, 0);
  const update = f.edit('ASSIGNEE', 'Pat');
  assert.equal(f.sent[2][7][0], attachment, 'metadata patch preserves original attachments');
  assert.equal('uploads' in JSON.parse(f.sent[2][2]), false);
  f.records[2] = { ...asset, preview: f.sent[2][2] }; f.ack({}); await update;
});

test('file selection limits and captured upload completion survive editor navigation without overwriting another draft', async () => {
  const completions = [];
  const f = fixture(file => new Promise((resolve, reject) => completions.push({ file, resolve, reject })));
  await f.api.reload(); f.api.open('', '1');
  const input = f.elements.get('[data-ticket-files]');
  const select = files => { input.files = files; input.onchange(); };
  select([{ name: 'too-big', size: 100 * 1024 * 1024 + 1 }]);
  assert.match(f.api.state.error, /100 MB/); assert.equal(f.api.state.drafts.get('1').uploads.length, 0);
  select(Array.from({ length: 11 }, (_, i) => ({ name: `file-${i}`, size: 1 })));
  await Promise.resolve(); assert.equal(completions.length, 10); assert.match(f.api.state.error, /Maximum 10/);
  f.api.open('', '2');
  completions[0].resolve({ fileId: 'first', filename: 'file-0' });
  completions[1].reject(new Error('offline'));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.api.state.drafts.get('1').uploads[0].attachment.fileId, 'first');
  assert.equal(f.api.state.drafts.get('2').uploads.length, 0);
  assert.equal(f.elements.get('[data-ticket-uploads]').innerHTML, '');
  f.api.open('', '1');
  assert.match(f.elements.get('[data-ticket-uploads]').innerHTML, /BLOB UPLOAD FAILED · offline/);
  assert.match(f.elements.get('[data-ticket-uploads]').innerHTML, /BLOB UPLOADED · TICKET NOT YET SAVED/);
  const queue = f.elements.get('[data-ticket-uploads]');
  queue.onclick({ target: { closest: () => ({ dataset: { removeUpload: '1' } }) } });
  assert.equal(f.api.state.drafts.get('1').uploads.length, 9);
});

test('refreshing ticket metadata keeps live reply upload completion and errors visible', async () => {
  const completions = [];
  const f = fixture(() => new Promise((resolve, reject) => completions.push({ resolve, reject })));
  f.window.NRCDialog = { confirm: async () => true };
  await f.api.reload(); f.api.open('', '1');
  const input = f.elements.get('[data-ticket-files]');
  input.files = [{ name: 'first.txt', size: 1 }, { name: 'second.txt', size: 1 }]; input.onchange();
  await Promise.resolve();
  await f.api.reload();
  completions[0].resolve({ fileId: 'first', filename: 'first.txt' });
  completions[1].reject(new Error('offline after reset'));
  await new Promise(resolve => setImmediate(resolve));
  const text = f.elements.get('[data-ticket-uploads]').innerHTML;
  assert.match(text, /BLOB UPLOADED · TICKET NOT YET SAVED/);
  assert.match(text, /BLOB UPLOAD FAILED · offline after reset/);
  assert.doesNotMatch(text, /UPLOADING BLOB/);
});

test('incoming replies resurface waiting/closed tickets; reading and internal notes never answer the customer', async () => {
  const f = fixture(); await f.api.reload();
  const a = f.records[0]; a.createdAt = 10n; a.updatedAt = 90n;
  a.preview = JSON.stringify({ ...f.api.metadata(a), status: 'waiting_customer', assignee: 'Staff' });
  assert.equal(f.api.activity(a).waiting, false);
  const entry = (assetId, kind, createdAt) => ({ assetId, parentType: 2, parentId: a.assetId, createdAt, preview: JSON.stringify({ kind }) });
  f.api.state.entries = f.entries;
  f.entries.push(entry(10n, 'public_reply', 20n), entry(11n, 'customer_reply', 30n));
  assert.equal(f.api.activity(a).waiting, true);
  f.window.NRCRecordActivity = { cursor: () => 11n, cursors: () => ({ '1': '11' }), observe() {} };
  assert.equal(f.api.activity(a).unread, 0);
  f.entries.push(entry(12n, 'internal_note', 40n));
  a.preview = JSON.stringify({ ...f.api.metadata(a), status: 'closed' });
  assert.equal(f.api.activity(a).waiting, true, 'metadata/status edits cannot silently answer a follow-up');
  f.entries.push(entry(13n, 'public_reply', 50n));
  assert.equal(f.api.activity(a).waiting, false);
  f.entries.push(entry(14n, 'customer_reply', 60n));
  assert.equal(f.api.activity(a).waiting, true);
  assert.equal(f.api.activity(a).unread, 1);
  assert.equal(f.api.activity(a).timestamp, 60n, 'metadata update time is not conversation activity');
  await f.api.reload();
  assert.equal(f.api.snapshot().length, 1, 'another assignee does not enter my inbox');
});
