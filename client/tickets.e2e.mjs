// Run against test/customer-workspace-dev.mjs with a ticket-capable server.
// This fixture owns disposable data and a fake staff identity; never production.
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const url = process.env.NRC_TICKETS_TEST_URL;
if (!url) throw new Error('Set NRC_TICKETS_TEST_URL to the disposable real-server fixture');
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: 'block' });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${url}/#workspace=tickets-browser-${Date.now()}`);
  await page.waitForFunction(() => serverReady);
  const customer = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const create = async (type, title) => (await rpc(o => NRCAssets.sendCreateAsset(0n, type, 0, 0n, JSON.stringify({ version: 1, title }), '', 0, o))).asset.assetId;
    const a = await create(8, 'Ticket customer'), b = await create(8, 'Ticket customer');
    const ada = await create(9, 'Ada'), bea = await create(9, 'Bea'), shared = await create(9, 'Shared contact');
    const edge = (from, to, relation = NRCEdges.RelationType.MemberOf) => rpc(o => NRCEdges.sendCreateEdge(0n, 1, from, 1, to, relation, o));
    await edge(ada, a); await edge(b, bea); // Membership reads accept both directions.
    await edge(shared, a); await edge(shared, b);
    await edge(ada, b, NRCEdges.RelationType.RelatedTo); // Not customer membership.
    return Object.fromEntries(Object.entries({ a, b, ada, bea, shared }).map(([key, id]) => [key, String(id)]));
  });
  await page.click('#ticketsBtn');
  assert.equal(await page.locator('#ticketEditor').count(), 0, 'register starts full-width without an embedded editor');
  await page.click('#ticketNew');
  await page.waitForSelector('#inspectorEntityHost #ticketFields');
  await page.waitForFunction(() => !document.querySelector('[name=contact_id]').disabled && !document.querySelector('#ticketCompanyStatus').textContent);
  const pick = async (name, search, label) => {
    await page.locator(`nrc-select:has(select[name="${name}"]) .custom-select__trigger`).click();
    await page.locator('.custom-select__dropdown input:visible').fill(search);
    await page.locator('.custom-select__dropdown').getByRole('option', { name: label, exact: true }).click();
  };
  // Company first scopes contacts, using membership rather than arbitrary links.
  await pick('company_id', 'Ticket customer', `Ticket customer · #${customer.a}`);
  assert.deepEqual(await page.locator('[name=contact_id] option').evaluateAll(options => options.map(o => o.value).sort()), ['', customer.ada, customer.shared].sort());
  await pick('contact_id', 'Ada', `Ada · #${customer.ada} / Ticket customer · #${customer.a}`);
  assert.equal(await page.locator('[name=company_id]').isDisabled(), true);
  await pick('contact_id', 'NO CONTACT', 'NO CONTACT');
  assert.equal(await page.locator('[name=company_id]').isDisabled(), false);
  await pick('company_id', 'Ticket customer', `Ticket customer · #${customer.b}`);
  assert.deepEqual(await page.locator('[name=contact_id] option').evaluateAll(options => options.map(o => o.value).sort()), ['', customer.bea, customer.shared].sort());
  await pick('company_id', 'NO COMPANY', 'NO COMPANY');
  // Contact first names each company explicitly when a contact belongs to two.
  await pick('contact_id', 'Shared contact', `Shared contact · #${customer.shared} / Ticket customer · #${customer.b}`);
  assert.equal(await page.inputValue('[name=company_id]'), customer.b);
  assert.equal(await page.locator('[name=company_id]').isDisabled(), true);
  await page.fill('[name=title]', 'Login regression');
  await page.fill('[name=requester]', 'customer@example.test');
  await page.fill('[name=requester_name]', 'Customer');
  await page.fill('[name=body]', 'Original request');
  const attach = async (name, text) => {
    assert.equal(await page.locator('[data-ticket-files]').isVisible(), false);
    const chooser = page.waitForEvent('filechooser');
    await page.getByRole('button', { name: '+ ADD FILE', exact: true }).click();
    await (await chooser).setFiles({ name, mimeType: 'text/plain', buffer: Buffer.from(text) });
    await page.waitForFunction(() => NRCTickets.state.drafts.get(NRCTickets.state.selected).uploads.every(u => u.attachment));
    assert.match(await page.textContent('[data-ticket-uploads]'), /BLOB UPLOADED · TICKET NOT YET SAVED/);
  };
  await attach('original.txt', 'original bytes');
  await page.evaluate(() => {
    const original = NRCAssets.sendCreateAsset;
    NRCAssets.sendCreateAsset = (...args) => {
      NRCAssets.sendCreateAsset = original;
      const options = args[7];
      args[7] = { ...options, onSuccess: result => {
        window.releaseTicketAck = () => { delete window.releaseTicketAck; options.onSuccess(result); };
      } };
      return original(...args);
    };
  });
  await page.click('#ticketFields button[data-save]');
  await page.waitForFunction(() => typeof window.releaseTicketAck === 'function');
  assert.equal(await page.locator('[name=body]').evaluate(el => el.readOnly), true);
  await page.locator('[name=body]').press('End');
  await page.locator('[name=body]').press('x');
  assert.equal(await page.inputValue('[name=body]'), 'Original request');
  await page.evaluate(() => window.releaseTicketAck());
  await page.waitForFunction(() => NRCTickets.state.selected && !NRCTickets.state.pending);
  const id = await page.evaluate(() => NRCTickets.state.selected);
  await page.waitForFunction(id => NRCInspector.current()?.type === 'ticket' && String(NRCInspector.current().id) === id, id);
  assert.match(await page.textContent('#inspectorHeader'), new RegExp(`TICKET #${id}`));
  await page.fill('[name=message]', 'Private diagnosis');
  await attach('private.txt', 'private bytes');
  await page.click('#ticketReply button[data-save]');
  await page.waitForFunction(() => NRCTickets.state.entries.length === 1 && !NRCTickets.state.pending);
  await page.selectOption('[name=kind]', 'public_reply');
  assert.match(await page.textContent('#ticketVisibility'), /VISIBLE IN CUSTOMER PORTAL/);
  assert.equal(await page.textContent('#ticketReply button[data-save]'), 'SEND CUSTOMER REPLY');
  await page.fill('[name=message]', 'Public answer');
  await attach('public.txt', 'public bytes');
  await page.click('#ticketReply button[data-save]');
  await page.waitForFunction(() => NRCTickets.state.entries.length === 2 && !NRCTickets.state.pending);
  assert.equal(await page.inputValue('[name=kind]'), 'internal_note');
  const publicConversation = await page.locator('#ticketConversation > section').first().textContent();
  assert.match(publicConversation, /Original request/);
  assert.match(publicConversation, /Public answer/);
  assert.doesNotMatch(publicConversation, /Private diagnosis/);
  assert.match(publicConversation, /original.txt/); assert.match(publicConversation, /public.txt/);
  assert.doesNotMatch(publicConversation, /private.txt/);
  const privateConversation = await page.locator('#ticketConversation > section').last().textContent();
  assert.match(privateConversation, /private.txt/); assert.doesNotMatch(privateConversation, /public.txt|original.txt/);
  for (const [filename, bytes] of [['original.txt', 'original bytes'], ['private.txt', 'private bytes'], ['public.txt', 'public bytes']]) {
    const href = await page.locator(`#ticketConversation a[download="${filename}"]`).getAttribute('href');
    assert.equal(await page.evaluate(async href => (await fetch(href)).text(), href), bytes);
  }
  assert.equal(await page.locator('[data-ticket-uploads]').textContent(), '');

  // Competing staff update: a stale editor must not silently overwrite it.
  assert.equal(await page.locator('#ticketEditor details, #ticketEditor summary, #ticketEditor [name=body]').count(), 0, 'no ticket-specific disclosure or duplicate original request editor');
  const inline = async (label, value) => {
    await page.getByRole('button', { name: new RegExp(`^Edit ${label}:`) }).click();
    await page.locator('.inline-field-editor input').fill(value);
    await page.locator('.inline-field-editor input').press('Enter');
    await page.waitForFunction(() => !NRCTickets.state.pending && !document.querySelector('.inline-field-editor'));
  };
  await inline('ASSIGNEE', 'Initial owner');
  const savedOriginal = await page.evaluate(async id => (await NRCAssets.requestAssetsByIds(0n, [BigInt(id)], { force: true }))[0].payload, id);
  assert.equal(savedOriginal, 'Original request', 'inline metadata save preserves original request');
  assert.deepEqual(await page.evaluate(async id => (await NRCAssets.requestAssetsByIds(0n, [BigInt(id)], { force: true }))[0].attachments.map(a => a.filename), id), ['original.txt'], 'metadata save preserves original attachments');
  await page.getByRole('button', { name: 'Edit COMPANY AND CONTACT', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('[name=contact_id]').disabled);
  assert.equal(await page.inputValue('[name=company_id]'), customer.b);
  assert.equal(await page.inputValue('[name=contact_id]'), customer.shared);
  assert.equal(await page.locator('[name=company_id]').isDisabled(), true);
  await pick('contact_id', 'NO CONTACT', 'NO CONTACT');
  await pick('company_id', 'Ticket customer', `Ticket customer · #${customer.a}`);
  await pick('contact_id', 'Ada', `Ada · #${customer.ada} / Ticket customer · #${customer.a}`);
  await page.evaluate(() => {
    const original = NRCTransactions.sendAssetMetadataPatch;
    NRCTransactions.sendAssetMetadataPatch = (...args) => {
      window.releaseCustomerSave = () => { NRCTransactions.sendAssetMetadataPatch = original; original(...args); };
      return 1;
    };
  });
  await page.getByRole('button', { name: 'SAVE CUSTOMER', exact: true }).click();
  assert.equal(await page.locator('[name=company_id]').isDisabled(), true);
  assert.equal(await page.locator('[name=contact_id]').isDisabled(), true);
  await page.evaluate(() => window.releaseCustomerSave());
  await page.waitForFunction(() => !NRCTickets.state.pending && !document.querySelector('dialog[open]'));
  assert.deepEqual(await page.evaluate(id => { const m = NRCTickets.metadata(NRCTickets.state.tickets.find(a => String(a.assetId) === id)); return [m.company_id, m.contact_id]; }, id), [customer.a, customer.ada]);
  await page.getByRole('button', { name: 'Edit COMPANY AND CONTACT', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('[name=contact_id]').disabled);
  await pick('contact_id', 'NO CONTACT', 'NO CONTACT');
  await pick('company_id', 'Ticket customer', `Ticket customer · #${customer.b}`);
  await pick('contact_id', 'Shared contact', `Shared contact · #${customer.shared} / Ticket customer · #${customer.b}`);
  await page.getByRole('button', { name: 'SAVE CUSTOMER', exact: true }).click();
  await page.waitForFunction(() => !NRCTickets.state.pending && !document.querySelector('dialog[open]'));
  await page.evaluate(() => {
    const original = NRCAssets.requestAllAssets;
    let fail = true;
    NRCAssets.requestAllAssets = (room, type, options) => {
      if (type === 9 && fail) { fail = false; return Promise.reject(new Error('temporary contact read failure')); }
      return original(room, type, options);
    };
  });
  await page.getByRole('button', { name: 'Edit COMPANY AND CONTACT', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('#ticketCompanyStatus').textContent.includes('unavailable'));
  assert.equal(await page.inputValue('[name=company_id]'), customer.b);
  assert.equal(await page.inputValue('[name=contact_id]'), customer.shared);
  assert.equal(await page.locator('[name=company_id]').isDisabled(), true);
  await page.locator('dialog[open]').getByRole('button', { name: 'Close', exact: true }).click();
  await page.getByRole('button', { name: 'Edit COMPANY AND CONTACT', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('#ticketCompanyStatus').textContent.startsWith('Company fixed'));
  await page.locator('dialog[open]').getByRole('button', { name: 'Close', exact: true }).click();
  await page.getByRole('button', { name: /^Edit ASSIGNEE:/ }).click();
  await page.locator('.inline-field-editor input').fill('My unsaved owner');
  await page.evaluate(async () => {
    const asset = NRCTickets.state.tickets.find(a => String(a.assetId) === NRCTickets.state.selected);
    const preview = { ...JSON.parse(asset.preview), assignee: 'Other staff member' };
    await new Promise((resolve, reject) => NRCTransactions.sendAssetMetadataPatch(asset, JSON.stringify(preview), null, { onSuccess: resolve, onError: reject }));
  });
  await page.locator('.inline-field-editor input').press('Enter');
  await page.waitForFunction(() => !NRCTickets.state.pending && !!NRCTickets.state.error);
  assert.equal(await page.locator('.inline-field-editor input').inputValue(), 'My unsaved owner');
  await page.locator('.inline-field-editor').getByRole('button', { name: 'CANCEL', exact: true }).click();
  const owner = await page.evaluate(async id => {
    const assets = await NRCAssets.requestAssetsByIds(0n, [BigInt(id)], { force: true });
    return JSON.parse(assets[0].preview).assignee;
  }, id);
  assert.equal(owner, 'Other staff member');

  await page.getByRole('button', { name: '+ CREATE TASK', exact: true }).click();
  await page.getByRole('button', { name: 'Confirm', exact: true }).click();
  await page.waitForFunction(() => !NRCTickets.state.pending && NRCTickets.state.notice.includes('CREATED AND LINKED'));
  const task = await page.evaluate(() => {
    const edge = NRCEdges.getEdgesForEntity(0n, 1, BigInt(NRCTickets.state.selected))[0];
    return String(edge.targetId);
  });
  await page.evaluate(async task => {
    await new Promise((resolve, reject) => sendMoveTask(0n, BigInt(task), 3, { onSuccess: resolve, onError: reject }));
  }, task);
  await page.waitForFunction(() => /Login regression.*DONE.*UNASSIGNED/s.test(document.querySelector('#ticketWork').textContent));
  await page.reload();
  await page.waitForFunction(() => serverReady);
  await page.click('#ticketsBtn');
  await page.waitForSelector(`[data-ticket="${id}"]`);
  await page.click(`[data-ticket="${id}"]`);
  assert.match(await page.textContent('#ticketConversation'), /Private diagnosis/);
  await page.waitForFunction(() => document.querySelector('#ticketWork')?.textContent.includes('Login regression'));
  assert.match(await page.textContent('#ticketWork'), /Login regression/);
  const resource = name => page.locator(`#ticketWork [data-resource="${name}"]`);
  assert.equal(await resource('tasks').locator('[data-resource-count]').textContent(), '1');
  assert.equal(await resource('tasks').locator('[data-resource-toggle]').getAttribute('aria-expanded'), 'false');
  await resource('tasks').locator('[data-resource-toggle]').focus();
  await page.keyboard.press('Enter');
  assert.equal(await resource('tasks').locator('.record-resource-body').isVisible(), true);
  assert.match(await resource('tasks').textContent(), /DONE.*UNASSIGNED/s);
  assert.equal(await resource('tasks').locator('.note-link-kind').textContent(), 'TASK');
  assert.equal(await resource('tasks').locator('.note-link-direction').textContent(), '→');
  assert.equal(await resource('tasks').locator('.note-link-relation').textContent(), 'related-to');
  assert.equal(await page.locator('#ticketWork').evaluate(node => !!(node.compareDocumentPosition(document.getElementById('ticketConversation')) & Node.DOCUMENT_POSITION_FOLLOWING)), true, 'resources precede the conversation');
  await page.fill('[name=message]', 'Keep this reply draft while changing resources.');
  const note = await page.evaluate(async () => {
    const result = await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 5, 0, 0n, JSON.stringify({ title: 'Login investigation guide' }), 'Internal diagnostic steps.', 0, { onSuccess: resolve, onError: reject }));
    return String(result.asset.assetId);
  });
  await page.click('#ticketReference');
  await page.locator('.note-link-picker-item').filter({ hasText: 'Login investigation guide' }).click();
  await page.waitForFunction(() => document.querySelector('#ticketWork [data-resource="references"] [data-resource-count]').textContent === '1');
  await resource('references').locator('[data-resource-toggle]').click();
  assert.equal(await resource('tasks').locator('.record-resource-body').isVisible(), false, 'one resource is open at a time');
  assert.equal(await resource('references').locator(`[data-work-id="${note}"]`).isVisible(), true);
  assert.equal(await page.inputValue('[name=message]'), 'Keep this reply draft while changing resources.');
  assert.equal(await resource('references').locator('.note-link-kind').textContent(), 'NOTE');
  await resource('references').getByRole('button', { name: 'Remove link to Login investigation guide', exact: true }).click();
  await page.waitForFunction(() => !NRCTickets.state.pending && document.querySelector('#ticketWork [data-resource="references"] [data-resource-count]').textContent === '0');
  // Unlinking keeps the target record and the reply draft; reverse edges display ←.
  await page.evaluate(async ({ note, id }) => {
    const result = await NRCAssets.requestAssetsByIds(0n, [BigInt(note)], { fullContent: true, force: true });
    if (!result.length) throw new Error('Unlink deleted target note');
    await new Promise((resolve, reject) => NRCEdges.sendCreateEdge(0n, 1, BigInt(note), 1, BigInt(id), NRCEdges.RelationType.RelatedTo, { onSuccess: resolve, onError: reject }));
  }, { note, id });
  await page.waitForFunction(() => document.querySelector('#ticketWork [data-resource="references"] .note-link-direction')?.textContent === '←');
  assert.equal(await page.inputValue('[name=message]'), 'Keep this reply draft while changing resources.');
  await page.click('#ticketsRefresh');
  await page.waitForFunction(() => !NRCTickets.state.loading);
  assert.equal(await resource('references').locator('[data-resource-toggle]').getAttribute('aria-expanded'), 'true', 'refresh preserves disclosure state');
  assert.equal(await page.inputValue('[name=message]'), 'Keep this reply draft while changing resources.');
  assert.match(await page.locator('#ticketConversation > section').first().textContent(), /original.txt/);
  assert.match(await page.locator('#ticketConversation > section').first().textContent(), /public.txt/);
  assert.doesNotMatch(await page.locator('#ticketConversation > section').first().textContent(), /private.txt/);
  assert.match(await page.locator('#ticketConversation > section').last().textContent(), /private.txt/);
  assert.equal(await page.evaluate(() => NRCTickets.state.drafts.get(NRCTickets.state.selected).status), 'open', 'task completion does not close ticket');

  // Slice membership is MemberOf, not a general work link, and both views agree.
  const sliceId = await page.evaluate(async () => {
    const result = await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 11, 0, 0n, JSON.stringify({ version: 1, name: 'Support rollout', owner: '', outcome: '', closed: false }), '', 0, { onSuccess: resolve, onError: reject }));
    return String(result.asset.assetId);
  });
  // A remote edge may arrive before its slice is in the local asset cache.
  const remoteEdge = await page.evaluate(async ({ id, sliceId }) => {
    NRCAssets.roomAssets.get(0n).delete(BigInt(sliceId));
    const result = await new Promise((resolve, reject) => NRCEdges.sendCreateEdge(0n, 1, BigInt(id), 1, BigInt(sliceId), NRCEdges.RelationType.MemberOf, { onSuccess: resolve, onError: reject }));
    return String(result.edge.edgeId);
  }, { id, sliceId });
  await page.waitForFunction(() => document.querySelector('#ticketWork [data-resource="slices"] [data-resource-count]').textContent === '1');
  assert.equal(await page.inputValue('[name=message]'), 'Keep this reply draft while changing resources.');
  await resource('slices').locator('[data-resource-toggle]').click();
  await resource('slices').locator(`[data-remove-work="${remoteEdge}"]`).click();
  await page.waitForFunction(() => document.querySelector('#ticketWork [data-resource="slices"] [data-resource-count]').textContent === '0');
  await page.click('#ticketAssignSlice');
  await page.locator('.note-link-picker-item').filter({ hasText: 'Support rollout' }).click();
  await page.waitForFunction(({ id, sliceId }) => NRCEdges.getEdgesForEntity(0n, 1, BigInt(id)).some(e => e.relation === 7 && e.targetId === BigInt(sliceId)), { id, sliceId });
  assert.equal(await resource('slices').locator('[data-resource-count]').textContent(), '1');
  await page.evaluate(async ({ id, sliceId }) => {
    await new Promise((resolve, reject) => NRCEdges.sendCreateEdge(0n, 1, BigInt(id), 1, BigInt(sliceId), NRCEdges.RelationType.RelatedTo, { onSuccess: resolve, onError: reject }));
  }, { id, sliceId });
  assert.equal(await resource('slices').locator('[data-resource-count]').textContent(), '1', 'a general slice link is not a second membership');
  assert.equal(await resource('references').locator('[data-resource-count]').textContent(), '2');
  if (await resource('slices').locator('[data-resource-toggle]').getAttribute('aria-expanded') !== 'true') await resource('slices').locator('[data-resource-toggle]').click();
  await resource('slices').locator(`[data-work-id="${sliceId}"]`).click();
  await page.waitForSelector(`#sliceRecord [data-member-ticket="${id}"]`);
  await page.waitForFunction(() => NRCSlices.selectedSlice()?.tickets === 1);
  assert.match(await page.textContent('#sliceRecord [data-member-ticket]'), /Login regression.*open.*Other staff member/s);
  assert.equal(await page.evaluate(() => NRCSlices.selectedSlice().tickets), 1);
  assert.equal(await page.evaluate(() => NRCSlices.memberCount(NRCSlices.selectedSlice())), 1);
  if (process.env.NRC_TICKETS_SCREENSHOTS) {
    for (const theme of ['lupine', 'dark']) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await page.locator('[data-member-ticket]').scrollIntoViewIfNeeded();
      await page.waitForFunction(() => Array.from(document.querySelectorAll('.slice-member--ticket')).every(row => getComputedStyle(row.children[2]).display !== 'none'));
      await page.screenshot({ path: `${process.env.NRC_TICKETS_SCREENSHOTS}/ticket-slice-${theme}.png` });
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await page.evaluate(sliceId => NRCInspector.openEntity({ type: 'slice', id: BigInt(sliceId) }), sliceId);
    await page.locator('[data-member-ticket]').scrollIntoViewIfNeeded();
    assert.equal(await page.locator('[data-member-ticket] > :nth-child(3)').isVisible(), true);
    await page.screenshot({ path: `${process.env.NRC_TICKETS_SCREENSHOTS}/ticket-slice-narrow.png` });
    await page.setViewportSize({ width: 1440, height: 1000 });
  }
  await page.click(`#sliceRecord [data-member-ticket="${id}"] [data-slice-unassign]`);
  await page.waitForFunction(() => NRCSlices.selectedSlice().tickets === 0 && NRCSlices.getState().tickets.assets.length === 0);
  await page.click('[data-slice-kind="ticket"]');
  await page.locator('.note-link-picker-item').filter({ hasText: 'Login regression' }).click();
  await page.waitForSelector(`#sliceRecord [data-member-ticket="${id}"]`);
  await page.evaluate(() => NRCViewManager.setActiveView('kanban'));
  await page.click(`#sliceRecord [data-member-open="ticket:${id}"]`);
  await page.waitForFunction(id => NRCInspector.current()?.type === 'ticket' && NRCTickets.state.selected === id, id);
  await page.waitForSelector('#inspectorEntityHost #ticketConversation');
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), 'kanban', 'linked ticket leaves surrounding view intact');
  await page.evaluate(() => {
    const original = NRCAssets.sendCreateAsset;
    NRCAssets.sendCreateAsset = (...args) => { NRCAssets.sendCreateAsset = original; queueMicrotask(() => args[7].onError({ message: 'Reply denied (fixture)' })); return 1; };
  });
  await page.locator('#ticketReply button[data-save]').click();
  await page.waitForFunction(() => NRCTickets.state.error.includes('Reply denied'));
  assert.equal(await page.locator('#inspectorEntityHost #ticketStatus').isVisible(), true);
  assert.match(await page.textContent('#ticketStatus'), /Reply denied/);
  assert.equal(await page.inputValue('[name=message]'), 'Keep this reply draft while changing resources.');

  // The company tab resolves the same ticket record, not a copy.
  const company = customer.b;
  await page.click('#customersBtn');
  await page.waitForSelector(`#customersList [data-company="${company}"]`);
  await page.click(`#customersList [data-company="${company}"]`);
  await page.click('[data-customer-tab="tickets"]');
  await page.waitForSelector(`[data-customer-ticket="${id}"]`);
  await page.click(`[data-customer-ticket="${id}"]`);
  assert.equal(await page.evaluate(() => NRCTickets.state.selected), id);
  const fileId = await page.evaluate(async id => {
    const attachment = NRCTickets.state.tickets.find(a => String(a.assetId) === id).attachments[0];
    const data = { type: 'file', version: 1, title: 'Login diagnostic file', description: '', category: '', tags: [] };
    const result = await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 3, 0, 0n, JSON.stringify(data), JSON.stringify(data), 0, { onSuccess: resolve, onError: reject }, [attachment]));
    return String(result.asset.assetId);
  }, id);
  await page.click('#ticketReference');
  await page.locator('.note-link-picker-type[data-kind="file"]').click();
  await page.locator('.note-link-picker-item').filter({ hasText: 'Login diagnostic file' }).click();
  await resource('references').locator('[data-resource-toggle]').click();
  await resource('references').locator(`[data-work-id="${fileId}"]`).click();
  await page.waitForSelector('.file-assets-metadata');
  assert.match(await page.textContent('.file-assets-metadata'), /Login diagnostic file.*original.txt/s);
  assert.match(await page.textContent('#fileInspectorAttachments'), /original.txt/);

  // Register navigation uses visible sort/filter order, not storage order.
  const keyboardTickets = await page.evaluate(async () => {
    const create = async title => String((await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 13, 0, 0n, JSON.stringify({ version: 1, title, status: 'open', assignee: 'Sam', requester: 'keyboard@example.test', requester_name: title, company_id: '', contact_id: '' }), 'Keyboard original request', 0, { onSuccess: resolve, onError: reject }))).asset.assetId);
    return { zulu: await create('Keyboard Zulu'), alpha: await create('Keyboard Alpha') };
  });
  await page.click('#ticketsBtn');
  await page.evaluate(() => NRCInspector.close());
  const search = page.locator('#ticketsPanel [data-filter="search"]');
  await search.fill('Keyboard');
  await page.waitForFunction(() => document.querySelectorAll('#ticketsList [data-ticket]').length === 2);
  const taskSort = () => page.evaluate(() => JSON.stringify([TaskViewState.sortColumn, TaskViewState.sortDirection, localStorage.getItem('nrc_task_view_state')]));
  const taskSortBefore = await taskSort();
  await page.locator('#ticketsTable th[data-sort="contact_id"] button').click();
  assert.deepEqual(await page.locator('#ticketsList [data-ticket]').evaluateAll(rows => rows.map(r => r.dataset.ticket)), [keyboardTickets.alpha, keyboardTickets.zulu]);
  await page.locator('#ticketsTable th[data-sort="contact_id"] button').click();
  assert.deepEqual(await page.locator('#ticketsList [data-ticket]').evaluateAll(rows => rows.map(r => r.dataset.ticket)), [keyboardTickets.zulu, keyboardTickets.alpha]);
  await page.locator('#ticketsTable th[data-sort="company_id"] button').click();
  await page.locator('#ticketsTable th[data-sort="title"] button').focus();
  await page.keyboard.press('Enter');
  assert.equal(await taskSort(), taskSortBefore, 'ticket sorting never changes or persists task sorting');
  assert.equal(await page.locator('#ticketsTable th[data-sort="title"]').getAttribute('aria-sort'), 'ascending');
  assert.deepEqual(await page.locator('#ticketsList [data-ticket]').evaluateAll(rows => rows.map(r => r.dataset.ticket)), [keyboardTickets.alpha, keyboardTickets.zulu]);
  await page.locator('#ticketsRegister').focus();
  await page.keyboard.press('ArrowDown');
  await page.waitForFunction(id => NRCTickets.state.selected === id, keyboardTickets.alpha);
  assert.equal(await page.locator(`#ticketsList [data-ticket="${keyboardTickets.alpha}"]`).getAttribute('aria-selected'), 'true');
  assert.equal(await page.locator('#inspectorEntityHost #ticketEditor').count(), 1);
  await page.keyboard.press('m');
  assert.equal(await page.locator('[name=message]').evaluate(el => el === document.activeElement), true, 'M reaches the reply composer');
  await page.locator('#ticketsRegister').focus();
  await page.keyboard.press('ArrowDown');
  await page.waitForFunction(id => NRCTickets.state.selected === id, keyboardTickets.zulu);
  await page.keyboard.press('ArrowDown');
  assert.equal(await page.evaluate(() => NRCTickets.state.selected), keyboardTickets.zulu, 'last row is a boundary, not wraparound');
  await page.locator('[name=message]').fill('Retained keyboard reply');
  await page.locator('[name=message]').press('ArrowUp');
  assert.equal(await page.evaluate(() => NRCTickets.state.selected), keyboardTickets.zulu, 'composer owns arrow keys');
  await page.locator('#ticketsRegister').focus();
  await page.keyboard.press('ArrowUp');
  await page.waitForFunction(id => NRCTickets.state.selected === id, keyboardTickets.alpha);
  await page.keyboard.press('ArrowDown');
  await page.waitForFunction(id => NRCTickets.state.selected === id, keyboardTickets.zulu);
  assert.equal(await page.inputValue('[name=message]'), 'Retained keyboard reply');
  await search.focus(); await page.keyboard.press('ArrowUp');
  assert.equal(await page.evaluate(() => NRCTickets.state.selected), keyboardTickets.zulu, 'filter owns arrow keys');
  await page.locator('#ticketsRegister').focus(); await page.keyboard.press('Escape');
  await page.waitForFunction(() => !NRCInspector.hasEntity());
  const resize = page.locator('#ticketsTable th[data-sort="id"] [role="separator"]');
  await resize.focus();
  const width = Number(await resize.getAttribute('aria-valuenow'));
  await page.keyboard.press('ArrowRight');
  assert.equal(Number(await resize.getAttribute('aria-valuenow')), width + 8);
  await page.keyboard.press('ArrowDown');
  assert.equal(await page.evaluate(() => NRCTickets.state.selected), '', 'separator does not navigate rows');
  await page.keyboard.press('Home');
  await search.fill('no matching ticket');
  await page.waitForFunction(() => document.querySelector('#ticketsList').textContent.includes('No matching tickets'));
  assert.match(await page.textContent('#ticketsList'), /No matching tickets/);
  await page.locator('#ticketsRegister').focus(); await page.keyboard.press('ArrowDown');
  assert.equal(await page.evaluate(() => NRCInspector.hasEntity()), false, 'empty list does not open a record');
  await search.fill('');
  // The search service owns text matching; hits in replies and semantic matches
  // must not be discarded by a second title-only browser filter.
  const searchRequests = [];
  let searchOffline = false;
  await page.route('**/search', async route => {
    const request = route.request().postDataJSON();
    searchRequests.push(request);
    if (searchOffline) return route.fulfill({ status: 503, body: 'Search unavailable' });
    const result = await page.evaluate(id => {
      const asset = NRCTickets.state.tickets.find(a => String(a.assetId) === id);
      return { entity: { type: 'asset', id, conv_id: '0' }, asset_type: 13, metadata: { ticket: NRCTickets.metadata(asset) }, preview: asset.preview, score: 1 };
    }, id);
    await route.fulfill({ headers: { 'Content-Type': 'application/json', 'X-NRC-Search-Version': 'typed-v1' }, body: JSON.stringify({ results: [result], stale: true }) });
  });
  await search.fill('  semantic synonym  ');
  await page.waitForFunction(() => document.querySelector('#ticketsStatus').textContent.includes('INDEX STALE'));
  assert.deepEqual(await page.locator('#ticketsList [data-ticket]').evaluateAll(rows => rows.map(r => r.dataset.ticket)), [id]);
  const statusFilter = page.locator('#ticketsPanel [data-filter="status"]');
  await statusFilter.selectOption('open');
  await page.locator('#ticketsPanel [data-filter="owner"]').fill('Other staff member');
  await page.locator('#ticketsPanel [data-filter="company"]').fill(customer.b);
  await page.waitForFunction(() => document.querySelector('#ticketsStatus').textContent.includes('INDEX STALE'));
  assert.equal(searchRequests.at(-1).query, 'semantic synonym');
  assert.deepEqual(searchRequests.at(-1).filters, { entity_types: ['asset'], asset_types: [13], ticket: { status: 'open', assignee: 'Other staff member', company_id: customer.b } });
  assert.equal(searchRequests.at(-1).top_n, 100);
  await page.locator(`#ticketsList [data-ticket="${id}"] button`).click();
  await page.waitForSelector('#inspectorEntityHost #ticketEditor');
  assert.match(await page.textContent('#ticketConversation'), /Public answer/);
  await page.evaluate(() => NRCInspector.close());
  searchOffline = true;
  await statusFilter.selectOption('');
  await page.locator('#ticketsPanel [data-filter="owner"]').fill('');
  await page.locator('#ticketsPanel [data-filter="company"]').fill('');
  await search.fill('Private diagnosis');
  await page.waitForFunction(() => document.querySelector('#ticketsStatus').textContent.includes('LOCAL FALLBACK'));
  assert.deepEqual(await page.locator('#ticketsList [data-ticket]').evaluateAll(rows => rows.map(r => r.dataset.ticket)), [id], 'fallback also searches internal entry bodies');
  if (process.env.NRC_TICKETS_SCREENSHOTS) await page.screenshot({ path: `${process.env.NRC_TICKETS_SCREENSHOTS}/ticket-search-fallback.png` });
  await page.unroute('**/search');
  await search.fill('');
  if (process.env.NRC_TICKETS_SCREENSHOTS) {
    await page.evaluate(() => setTheme('lupine', false));
    await page.screenshot({ path: `${process.env.NRC_TICKETS_SCREENSHOTS}/ticket-register.png` });
    await page.locator(`#ticketsList [data-ticket="${id}"] button`).click();
    for (const theme of ['lupine', 'light', 'matte-black']) {
      await page.evaluate(theme => setTheme(theme, false), theme);
      await page.screenshot({ path: `${process.env.NRC_TICKETS_SCREENSHOTS}/ticket-inspector-${theme}.png` });
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await page.evaluate(() => setTheme('lupine', false));
    await page.locator(`#ticketsList [data-ticket="${id}"] button`).click();
    await page.waitForFunction(() => document.body.classList.contains('inspector-open'));
    assert.equal(await page.locator('#inspector').getAttribute('aria-modal'), 'true');
    await page.screenshot({ path: `${process.env.NRC_TICKETS_SCREENSHOTS}/ticket-inspector-narrow.png` });
    await page.keyboard.press('Escape');
    await page.waitForFunction(() => !document.body.classList.contains('inspector-open'));
    await page.waitForFunction(id => document.activeElement?.closest('[data-ticket]')?.dataset.ticket === id, id);
    await page.screenshot({ path: `${process.env.NRC_TICKETS_SCREENSHOTS}/ticket-register-narrow.png` });
    assert.equal(await page.locator('#ticketsRegister').evaluate(el => el.scrollWidth <= el.clientWidth), true);
    const ticketSortBefore = await page.evaluate(() => [NRCTickets.state.sort, NRCTickets.state.direction]);
    await page.evaluate(() => NRCViewManager.setActiveView('kanban'));
    await page.locator('#kanbanPanel [data-mobile-filters]').click();
    await page.locator('[data-task-grouping="flat"]').click();
    await page.selectOption('#mobileTaskSort', 'title');
    assert.equal(await page.evaluate(() => TaskViewState.sortColumn), 'title');
    assert.deepEqual(await page.evaluate(() => [NRCTickets.state.sort, NRCTickets.state.direction]), ticketSortBefore, 'mobile task sorting never touches ticket sorting');
  }
  assert.deepEqual(errors, []);
  console.log('PASS: ticket register sorting/filtering, arrow navigation/boundaries, keyboard resizing, draft retention, shared Inspector; company/contact picks, attachments, stale-write rejection, task/slice links and navigation');
} finally {
  await browser.close();
}
