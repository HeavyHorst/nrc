// Browser contract tests: real NRC UI, controlled signaling and external page.
// No external conference, credentials, microphone or camera is used.
import assert from 'node:assert/strict';
import http from 'node:http';
import {readFile, mkdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';

const root = fileURLToPath(new URL(process.env.NRC_CALLS_DIST ? './dist/' : './', import.meta.url));
const server = http.createServer(async (req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, 'http://fixture').pathname);
  const file = path.resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
  if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
  try {
    const data = await readFile(file);
    res.setHeader('Content-Type', ({'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml'})[path.extname(file)] || 'application/octet-stream');
    res.end(data);
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch({headless:true});
const context = await browser.newContext({serviceWorkers:'block', viewport:{width:1280,height:800}, deviceScaleFactor:2});
const page = await context.newPage();
const errors = [];
page.on('pageerror', error => errors.push(error.message));
let socket, commands = [], feature = true, restored = [];
const dm = '9223372036854775809';
const state = (status, extra = {}, join) => socket.send(JSON.stringify({type:'state', call:{id:'call-1',dm_id:dm,caller:'alice',callee:'bob',state:status,...extra}, ...(join ? {join} : {})}));
const credentials = {url:'https://conference.example.invalid/session?ticket=fixture-token',conference_id:'conference-1',title:'alice · bob',expires_at:Math.floor(Date.now()/1000)+3600};
const externalRequests = [];
try {
  await page.route('**/api/features', route => route.fulfill({json:{calls:feature}}));
  await context.route('https://conference.example.invalid/**', route => {
    externalRequests.push(route.request());
    return route.fulfill({contentType:'text/html',body:'<title>Conference fixture</title><p>External conference fixture — no audio/video</p>'});
  });
  await page.routeWebSocket('**/*', route => {
    if (route.url().includes('/calls/ws/')) {
      socket = route;
      route.onMessage(raw => {
        const command = JSON.parse(raw); commands.push(command);
        if (command.action === 'appointment') route.send(JSON.stringify({type:'appointment', request_id:command.request_id, join:{url:'https://conference.example.invalid/scheduled',expires_at:Math.floor(Date.now()/1000)+300}}));
      });
      route.send(JSON.stringify({type:'ready',username:'bob',conferences:restored}));
    } else route.onMessage(() => {});
  });
  await page.goto(`http://127.0.0.1:${server.address().port}`);
  await page.waitForFunction(() => window.NRCCalls && window.NRCViewManager && ws?.readyState === WebSocket.OPEN);
  await page.evaluate(dm => {
    currentWorkspaceId = 'calls-e2e'; currentRoomId = BigInt(dm);
    activeDMs.set(currentRoomId, {username:'alice',online:true,authenticated:true});
    activeDMs.set(9223372036854775810n, {username:'charlie',online:true,authenticated:true});
    subscribedRooms.add(currentRoomId); myNickname = 'bob'; nicknameReceived = true;
    window.NRCViewManager.setActiveView('chat'); updateRoomUI();
  }, dm);
  assert.ok(await page.locator('#callStart').isHidden(), 'feature absent before discovery');
  await page.evaluate(() => NRCCalls.refreshAccess());
  await page.waitForFunction(() => !document.getElementById('callStart').disabled);
  const scheduled = await page.evaluate(() => NRCCalls.joinAppointment(42n, 1793095200000000000n));
  assert.equal(scheduled.url, 'https://conference.example.invalid/scheduled');
  const request = commands.pop();
  assert.equal(request.action, 'appointment');
  assert.equal(request.appointment_id, '42');
  assert.equal(request.occurrence_at, '1793095200000000000');
  assert.ok(await page.locator('#callPanel').isHidden(), 'scheduled prepare must not ring or open the DM panel');
  await page.evaluate(() => { currentRoomId = 1n; updateRoomUI(); });
  assert.ok(await page.locator('#callStart').isHidden(), 'never offer calls in a public room');
  await page.evaluate(dm => { currentRoomId = BigInt(dm); updateRoomUI(); }, dm);
  await page.locator('#callStart').click();
  await page.waitForFunction(() => document.getElementById('callStart').disabled);
  assert.deepEqual(commands.pop(), {action:'start',dm_id:dm,call_id:''});
  state('ringing', {caller:'bob',callee:'alice'});
  await page.waitForFunction(() => document.getElementById('callStatus').textContent === 'Calling…');
  assert.ok(await page.locator('#callAccept').isHidden());
  await page.locator('#callEnd').click();
  assert.equal(commands.at(-1).action, 'cancel');
  state('ended',{reason:'cancel'});
  await page.waitForFunction(() => document.getElementById('callStatus').textContent === 'Call cancelled');

  for (const width of [1280,390]) for (const theme of ['lupine','matte-black']) {
    await page.setViewportSize({width,height:800});
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await page.locator('#messageInput').focus();
    state('ringing');
    await page.waitForFunction(() => document.getElementById('callStatus').textContent === 'Incoming video call');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'messageInput', 'incoming call preserves focus');
    assert.ok(await page.locator('#callEnd').isHidden());
    const box = await page.locator('#callPanel').boundingBox();
    assert.ok(box.x >= 0 && box.x + box.width <= width && box.y + box.height <= 800, 'call panel fits viewport');
    if (process.env.NRC_CALLS_CAPTURE) {
      await mkdir('.amp/in/artifacts', {recursive:true});
      await page.locator('#callPanel').screenshot({path:`.amp/in/artifacts/calls-incoming-${theme}-${width}.png`});
    }
    await page.locator('#callDecline').focus();
    await page.keyboard.press('Enter');
    assert.equal(commands.at(-1).action, 'decline');
    state('ended',{reason:'decline'});
    await page.waitForFunction(() => document.getElementById('callStatus').textContent === 'Call declined');
  }
  await page.setViewportSize({width:1280,height:800});
  await page.evaluate(() => document.documentElement.dataset.theme = 'lupine');
  state('ringing');
  await page.locator('#callAccept').click();
  assert.equal(commands.at(-1).action, 'accept');
  state('accepted',{},credentials);
  await page.locator('#callJoin').waitFor({state:'visible'});
  assert.ok(await page.locator('#callStart').isEnabled(), 'acceptance releases the invitation locally');
  assert.ok(await page.locator('#callEnd').isHidden(), 'no hangup for external conferences');
  assert.ok(await page.locator('#callDismiss').isVisible());
  assert.equal(await page.locator('#callJoin').getAttribute('href'), credentials.url);
  assert.equal(externalRequests.length, 0, 'acceptance does not load provider code or open unsolicited windows');
  for (const width of [1280,390]) for (const theme of ['lupine','matte-black']) {
    await page.setViewportSize({width,height:800});
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    const box = await page.locator('#callPanel').boundingBox();
    assert.ok(box.x >= 0 && box.x + box.width <= width && box.y + box.height <= 800);
    const historyBox = await page.locator('#callHistory').boundingBox();
    assert.ok(historyBox.x >= 0 && historyBox.x + historyBox.width <= width, 'conference recovery control stays within viewport');
    assert.ok(await page.locator('#callExternalHint').isVisible());
    if (process.env.NRC_CALLS_CAPTURE) await page.locator('#callPanel').screenshot({path:`.amp/in/artifacts/calls-external-${theme}-${width}.png`});
    if (process.env.NRC_CALLS_CAPTURE && width === 390) await page.screenshot({path:`.amp/in/artifacts/calls-page-${theme}-${width}.png`});
    await page.locator('#callInvite').click();
    await page.locator('dialog[open]').waitFor();
    if (process.env.NRC_CALLS_CAPTURE) await page.locator('dialog[open] .nrc-dialog').screenshot({path:`.amp/in/artifacts/calls-invite-${theme}-${width}.png`});
    await page.keyboard.press('Escape');
    await page.locator('#callDismiss').click();
    await page.locator('#callHistory').click();
    if (process.env.NRC_CALLS_CAPTURE) await page.locator('dialog[open] .nrc-dialog').screenshot({path:`.amp/in/artifacts/calls-library-${theme}-${width}.png`});
    await page.locator('.call-library-entry').click();
    assert.equal(await page.locator('#callJoin').getAttribute('href'), credentials.url, 'hidden panel can be reopened');
  }
  // Invite a third participant into the retained conference, not a fresh call.
  await page.locator('#callInvite').click();
  await page.locator('#callInviteUser').selectOption('9223372036854775810', {force:true});
  await page.getByRole('button', {name:'INVITE',exact:true}).click();
  assert.deepEqual(commands.at(-1), {action:'start',dm_id:'9223372036854775810',call_id:'',conference_id:'conference-1'});
  state('ringing', {dm_id:'9223372036854775810',caller:'bob',callee:'charlie'});
  await page.waitForFunction(() => document.getElementById('callStatus').textContent === 'Calling…');
  assert.equal(await page.locator('#callPeer').textContent(), credentials.title, 'conference title does not become the invitee');
  assert.equal(await page.locator('#callInvitationPeer').textContent(), 'INVITATION · charlie');
  assert.equal(await page.locator('#callJoin').getAttribute('href'), credentials.url);
  assert.ok(await page.locator('#callInvite').isDisabled());
  state('ended',{dm_id:'9223372036854775810',reason:'decline'});
  await page.waitForFunction(() => document.getElementById('callStatus').textContent === 'Call declined');
  assert.equal(await page.locator('#callJoin').getAttribute('href'), credentials.url, 'declining a new invitation preserves existing conference');
  assert.ok(await page.locator('#callInvite').isEnabled());
  const popupPromise = context.waitForEvent('page');
  await page.locator('#callJoin').click();
  const popup = await popupPromise;
  await popup.waitForLoadState();
  assert.equal(popup.url(), credentials.url);
  assert.equal(await popup.evaluate(() => window.opener), null, 'external provider cannot access NRC');
  assert.equal(externalRequests[0].headers().referer, undefined, 'no NRC referrer sent');
  const commandCount = commands.length;
  await page.locator('#callDismiss').hover();
  assert.equal(await page.locator('#callDismiss').evaluate(button => {
    const style = getComputedStyle(button);
    return style.color !== style.backgroundColor;
  }), true, 'dismiss glyph remains visible on hover');
  await page.locator('#callDismiss').click();
  assert.ok(await page.locator('#callPanel').isHidden());
  assert.equal(await page.locator('#callJoin').getAttribute('href'), null);
  assert.equal(commands.length, commandCount, 'dismiss is local, not a provider hangup');
  assert.ok(!popup.isClosed(), 'dismiss does not terminate external media');
  await page.locator('#callStart').click();
  assert.equal(commands.at(-1).action, 'start', 'a new call can start after acceptance');
  state('ringing', {caller:'bob',callee:'alice'});
  await page.locator('#callEnd').click();
  state('ended',{reason:'cancel'});

  state('accepted');
  await page.waitForFunction(() => document.getElementById('callStatus').textContent === 'Invitation accepted on another device');
  assert.ok(await page.locator('#callEnd').isHidden());
  assert.ok(await page.locator('#callJoin').isHidden(), 'no link on unselected device');
  for (const url of ['javascript:alert(1)', 'data:text/html,bad', 'http://conference.example.invalid', 'https://user:password@conference.example.invalid', '/relative']) {
    state('accepted',{}, {url});
    await page.waitForFunction(() => document.getElementById('callStatus').textContent.startsWith('Invalid conference link'));
    assert.equal(await page.locator('#callJoin').getAttribute('href'), null);
    assert.ok(await page.locator('#callStart').isEnabled());
  }
  state('ringing'); state('accepted',{},credentials);
  await page.locator('#callJoin').waitFor({state:'visible'});
  socket.close();
  await page.waitForFunction(() => document.getElementById('callStart').disabled);
  assert.equal(await page.locator('#callJoin').getAttribute('href'), credentials.url, 'signaling disconnect does not invalidate a delivered link');
  assert.ok(await page.locator('#callExternalHint').isVisible());
  restored = [credentials];
  await page.evaluate(() => NRCCalls.refreshAccess());
  await page.waitForFunction(() => !document.getElementById('callStart').disabled);
  await page.locator('#callHistory').click();
  await page.locator('.call-library-entry').click();
  await page.locator('#callJoin').waitFor({state:'visible'});
  assert.equal(await page.locator('#callJoin').getAttribute('href'), credentials.url, 'authenticated reconnect restores conference access');
  state('accepted',{}, {...credentials, expires_at:Math.floor(Date.now()/1000)+2});
  await page.waitForFunction(() => document.getElementById('callInvite').disabled);
  assert.ok(await page.locator('#callJoin').isHidden(), 'expired link cannot be used');
  assert.match(await page.locator('#callExpiry').textContent(), /Links expired/);
  for (const width of [1280,390]) for (const theme of ['lupine','matte-black']) {
    await page.setViewportSize({width,height:800});
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    if (process.env.NRC_CALLS_CAPTURE) await page.locator('#callPanel').screenshot({path:`.amp/in/artifacts/calls-expired-${theme}-${width}.png`});
  }
  await page.reload();
  await page.waitForFunction(() => window.NRCCalls && ws?.readyState === WebSocket.OPEN);
  await page.evaluate(async dm => {
    currentWorkspaceId = 'calls-e2e'; currentRoomId = BigInt(dm);
    activeDMs.set(currentRoomId, {username:'alice',online:true,authenticated:true});
    await NRCCalls.refreshAccess();
  }, dm);
  await page.waitForFunction(() => document.getElementById('callHistory').textContent === 'CONFERENCES (1)');
  await page.locator('#callHistory').click();
  await page.locator('.call-library-entry').click();
  assert.equal(await page.locator('#callJoin').getAttribute('href'), credentials.url, 'full page reload restores from authenticated server snapshot');
  await page.evaluate(() => NRCCalls.disconnect());
  assert.equal(await page.locator('#callJoin').getAttribute('href'), null, 'workspace disconnect clears participant link');
  assert.ok(await page.locator('#callPanel').isHidden());
  await popup.close();
  feature = false;
  await page.evaluate(() => NRCCalls.refreshAccess());
  assert.ok(await page.locator('#callStart').isHidden());
  assert.deepEqual(errors, []);
  console.log('PASS: DM-only opt-in, start/cancel, keyboard decline, generic external join, noopener/noreferrer, unsafe URL rejection, other-device isolation and link cleanup; both themes at 1280/390px');
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
