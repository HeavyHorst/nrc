// Disposable real-server fixture only; requires test/customer-workspace-dev.mjs.
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
const url = process.env.NRC_TICKETS_TEST_URL;
if (!url) throw new Error('Set NRC_TICKETS_TEST_URL to the disposable fixture');
const browser = await chromium.launch();
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: 'block', extraHTTPHeaders: { 'x-nrc-test-user': 'rene' } });
  const other = await browser.newContext({ serviceWorkers: 'block', extraHTTPHeaders: { 'x-nrc-test-user': 'alex' } });
  const page = await context.newPage(), author = await other.newPage(), errors = [];
  page.on('pageerror', error => errors.push(error.message));
  author.on('pageerror', error => errors.push(error.message));
  const workspace = `activity-${Date.now()}`;
  await Promise.all([page.goto(`${url}/#workspace=${workspace}`), author.goto(`${url}/#workspace=${workspace}`)]);
  await Promise.all([page.waitForFunction(() => serverReady && myNickname === 'rene'), author.waitForFunction(() => serverReady && myNickname === 'alex')]);
  const ids = await author.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const ticket = async (title, assignee, status = 'open') => (await rpc(o => NRCAssets.sendCreateAsset(0n, 13, 0, 0n, JSON.stringify({ version: 1, title, company_id: '', contact_id: '', requester: 'ada@example.test', requester_name: 'Ada', status, assignee }), 'The login form rejects a valid password.', 0, o))).asset.assetId;
    const mine = await ticket('Login fails after update', 'rene', 'waiting_customer');
    const inbox = await ticket('Invoice download is missing', '');
    await ticket('Another operator ticket', 'alex');
    const result = await rpc(o => NRCTasks.sendCreateTask(0n, 'Verify login fix', 'Check the customer reproduction.', 128, 0, '', 0n, [], 0, 0, '', o));
    const task = result.task;
    await rpc(o => NRCTasks.sendUpdateTask(0n, task.id, task.title, task.description, task.status, 'rene', task.priority, task.color, task.externalRef, task.dueAt, task.blockedBy, task.attachments, task.project, o));
    await rpc(o => NRCAssets.sendCreateAsset(0n, 1, 1, task.id, '', 'Reproduced on the customer workspace.', 0, o));
    for (let i = 0; i < 8; i++) await rpc(o => NRCAssets.sendCreateAsset(0n, 1, 1, task.id, '', `Reproduction ${i + 2}: ` + 'The affected login still needs investigation. '.repeat(18), 0, o));
    await rpc(o => NRCAssets.sendCreateAsset(0n, 14, 2, mine, JSON.stringify({ version: 1, kind: 'customer_reply', author: 'Ada' }), 'I tried again; the problem still occurs.', 0, o));
    return { mine: String(mine), inbox: String(inbox), task: String(task.id) };
  });
  await page.bringToFront();
  await page.click('#attentionBtn');
  await page.waitForFunction(() => NRCAttention.getState().rows.some(r => r.kind === 'COMMENT'));
  await page.waitForFunction(() => NRCAttention.getState().rows.filter(r => r.kind === 'TICKET').length === 2);
  assert.equal(await page.textContent('#ticketsUnreadCount'), '2');
  assert.equal(await page.textContent('#tasksUnreadCount'), '1');
  assert.equal(await page.locator('[data-kind=ticket]').count(), 2);
  assert.match(await page.textContent('#attentionBody'), /CUSTOMER WAITING.*SUPPORT INBOX.*UNREAD COMMENTS/s);
  assert.doesNotMatch(await page.textContent('#attentionBody'), /Another operator ticket/);
  if (process.env.NRC_ACTIVITY_SCREENSHOTS) {
    for (const theme of ['lupine', 'dark']) {
      await page.evaluate(theme => setTheme(theme, false), theme);
      await page.screenshot({ path: `${process.env.NRC_ACTIVITY_SCREENSHOTS}/attention-${theme}.png` });
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: `${process.env.NRC_ACTIVITY_SCREENSHOTS}/attention-narrow.png` });
    await page.setViewportSize({ width: 1440, height: 1000 });
  }
  await page.locator('[data-kind=comment] .attention-title').click();
  await page.waitForSelector('.record-message');
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert.equal(await page.evaluate(() => {
    const first = document.querySelector('.record-message').getBoundingClientRect();
    const stream = document.querySelector('[data-messages-stream]').getBoundingClientRect();
    return first.bottom > stream.top && first.top < stream.bottom;
  }), true, 'targeted navigation must stay at the first unread, not jump to the end');
  assert.equal(await page.evaluate(() => document.getElementById('tasksUnreadCount').hidden), false, 'offscreen latest comments remain unread');
  // Reconnect with the same mounted inspector: do not require reopening it to read.
  await page.evaluate(() => { window.activityReconnects = totalReconnects; ws.close(); });
  await page.waitForFunction(() => !serverReady);
  await page.evaluate(() => connectWebSocket()); // A clean close requires explicit reconnect.
  await page.waitForFunction(() => serverReady && totalReconnects > window.activityReconnects);
  await page.waitForFunction(() => NRCRecordActivity.snapshot().length > 0);
  await page.locator('.record-message').last().locator('span[aria-hidden=true]').scrollIntoViewIfNeeded();
  await page.waitForFunction(() => document.getElementById('tasksUnreadCount').hidden);
  await page.click('#taskDetailClose');
  await page.waitForFunction(() => !NRCAttention.getState().rows.some(r => r.kind === 'COMMENT'));
  await page.locator(`[data-attention-key="TICKET:${ids.mine}"] .attention-title`).click();
  await page.locator('#ticketConversation > section').first().locator('article').last().scrollIntoViewIfNeeded();
  await page.waitForFunction(id => NRCRecordActivity.cursor('ticket', BigInt(id)) > BigInt(id), ids.mine);
  await page.click('#attentionBtn');
  await page.waitForFunction(id => NRCAttention.getState().rows.some(r => r.key === `TICKET:${id}` && r.chip.label === 'REPLY NEEDED' && !r.detail.includes('UNREAD')), ids.mine);
  // Public reply clears reply debt; an internal note cannot.
  await author.evaluate(async id => {
    await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 14, 2, BigInt(id), JSON.stringify({ version: 1, kind: 'internal_note', author: myNickname }), 'Investigating privately.', 0, { onSuccess: resolve, onError: reject }));
  }, ids.mine);
  await page.waitForFunction(() => NRCTickets.state.entries.some(a => NRCTickets.metadata(a).kind === 'internal_note'));
  assert.equal(await page.locator(`[data-attention-key="TICKET:${ids.mine}"]`).count(), 1);
  await author.evaluate(async id => {
    await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 14, 2, BigInt(id), JSON.stringify({ version: 1, kind: 'public_reply', author: myNickname }), 'The fix is ready. Please try again.', 0, { onSuccess: resolve, onError: reject }));
  }, ids.mine);
  await page.waitForFunction(id => !NRCAttention.getState().rows.some(r => r.key === `TICKET:${id}`), ids.mine);
  // Reload reconstructs notifications but does not forget read acknowledgements.
  await page.reload(); await page.waitForFunction(() => serverReady);
  await page.click('#attentionBtn');
  await page.waitForFunction(() => NRCTickets.state.tickets.length === 3);
  assert.equal(await page.locator('[data-kind=comment]').count(), 0);
  assert.equal(await page.locator('[data-kind=ticket]').count(), 1);
  // Own task comments must not generate a notification.
  await page.evaluate(async id => {
    await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 1, 1, BigInt(id), '', 'My own progress note.', 0, { onSuccess: resolve, onError: reject }));
    await NRCRecordActivity.refresh();
  }, ids.task);
  assert.equal(await page.evaluate(() => NRCRecordActivity.snapshot().length), 0);
  // A fresh remote comment reappears after the previous one was read.
  await author.evaluate(async id => {
    await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 1, 1, BigInt(id), '', 'A second reproduction needs your review.', 0, { onSuccess: resolve, onError: reject }));
  }, ids.task);
  await page.waitForFunction(() => NRCRecordActivity.snapshot().some(s => s.count === 1));
  assert.equal(await page.textContent('#tasksUnreadCount'), '1');
  assert.deepEqual(errors, []);
  console.log('PASS: two-user tickets/task comments, own-write exclusion, reading, reply debt, internal/public replies, reload and re-notification');
} finally { await browser.close(); }
