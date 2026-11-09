// Production memory controls and restoration against a disposable HTTP fixture.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";
import { parse } from "acorn";

const app = await readFile(new URL("app.js", import.meta.url), "utf8");
const fixtureCode = parse(app, { ecmaVersion: "latest" }).body.filter(node =>
  node.type === "FunctionDeclaration" && ["clearStoredMessages", "clearCurrentRoomMessages", "loadRoomHistory"].includes(node.id.name) ||
  node.type === "VariableDeclaration" && node.declarations.some(declaration => declaration.id.name === "NRCDialog") ||
  node.type === "ExpressionStatement" && ["window.NRCChat.clearSullivanHistory =", "window.NRCDialog ="].some(prefix => app.slice(node.start, node.end).startsWith(prefix)),
).map(node => app.slice(node.start, node.end)).join("\n");
const html = `<!doctype html><html lang="de" data-theme="dark"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/css/main.css"></head><body>
<button class="btn" data-personal-memory>TEMPORÄR</button><div id="settingsResult" role="status"></div>
<textarea id="messageInput"></textarea><div id="logOutput"></div><div id="restored"></div>
<div class="ai-response-actions"><button data-requires-idle="true" id="responseAction">SAVE RESPONSE</button></div>
<script src="/dialog.js"></script><script>
let currentWorkspaceId='memory-test'; function getAiUrl(){return '/ai';}
const messageInput=document.getElementById('messageInput'); let currentRoomId=1n;
const roomHistory=new Map([[1n,[{message:'ordinary room message'}]],[2n,[{message:'older private answer',aiContextRoomId:0n}]]]);
const isDMConversation=()=>false, isAIDMConversation=()=>true;
let systemLogVisible=false;
function resetLedgerContext(){} function updateChatStats(){}
function displayMessage(message){document.getElementById('logOutput').append(document.createTextNode(message.message+' '));}
function logMessage(type,message,roomId,metadata={}){if(roomId==null){document.getElementById('settingsResult').textContent=message;return;}roomHistory.set(roomId,[...(roomHistory.get(roomId)||[]),{type,message,...metadata}]);loadRoomHistory(roomId);}
window.NRCChat={beginHistory(){},endHistory(){},filterHistory:messages=>messages}; ${fixtureCode}
</script><script src="/personal-memory.js"></script><script src="/ai.js"></script></body></html>`;
const server = createServer(async (req, res) => {
  const path = new URL(req.url, "http://localhost").pathname;
  try {
    if (path === "/") { res.setHeader("Content-Type", "text/html"); res.end(html); return; }
    res.setHeader("Content-Type", path.endsWith(".js") ? "text/javascript" : "text/css");
    res.end(await readFile(new URL(`.${path}`, import.meta.url)));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = []; page.on("pageerror", error => errors.push(error.message));
  const asks = [];
  await page.route("**/ai/ask", route => {
    asks.push(route.request().postDataJSON());
    return route.fulfill({ contentType: "application/json", body: JSON.stringify({answer:"private answer"}) });
  });
  let policy = { enabled: false, epoch: 0, revision: 0, bytes: 5000, segments: 101 };
  let originals = Array.from({ length: 101 }, (_, sequence) => ({ sequence, revision: 2, state: "complete", channel: sequence % 2 ? "voice" : "chat", records: [{ role: "user", text: `private <script> evidence ${sequence}` }] }));
  const turns = Array.from({length:51}, (_, sequence) => ({sequence, channel:sequence % 2 ? 'voice' : 'chat', state:sequence === 50 ? 'active' : 'complete', records:[
    {role:'assistant',text:`Historical <script> evidence ${sequence}`,plan_id:'old-plan',proposed_actions:[{id:'old-action',type:'create_note',content:'never execute'}]},
  ]}));
  const receipts = Array.from({length:51}, (_, position) => ({position,state:position === 50 ? 'pending' : 'applied',result:{note_id:position + 100},plan_id:'old-plan',action_id:'old-action'}));
  let conflict = false, unavailable = false;
  const requests = [];
  await page.route("**/ai/ask/memory", async route => {
    const req = route.request().postDataJSON(); requests.push(req);
    let result, status = 200;
    if (unavailable) { status = 403; result = "unavailable"; }
    else if (req.operation === "inspect" || req.operation === "changes") result = policy;
    else if (req.operation === "history" || req.operation === "receipts") {
      const key = req.operation === 'history' ? 'sequence' : 'position';
      const source = req.operation === 'history' ? turns : receipts;
      result = [...source].reverse().filter(item => req.before == null || req.before === -1 || item[key] < req.before).slice(0, req.limit);
    } else if (req.operation === "export") {
      status = req.epoch === policy.epoch ? 200 : 409;
      result = originals.filter(item => item.sequence > req.after).slice(0, req.limit);
    } else if (!req.confirm || conflict || (req.policy?.epoch ?? req.epoch) !== policy.epoch) {
      status = 409; result = "conflict";
    } else {
      assert.ok(['configure', 'forget_all'].includes(req.operation));
      if (req.operation === "configure") policy = { ...policy, ...req.policy };
      if (req.operation === "forget_all") originals = [];
      policy = { ...policy, epoch: policy.epoch + 1, segments: originals.length };
      result = policy;
    }
    await route.fulfill({ status, contentType: "application/json", body: JSON.stringify(result) });
  });
  const button = name => page.getByRole("button", { name, exact: true });
  const idle = () => page.waitForFunction(() => !NRCMemory.isBusy());
  const setting = value => page.evaluate(value => NRCMemory.settings(value), value);
  const open = async (reload = false) => {
    if (reload) await page.goto(`http://127.0.0.1:${server.address().port}`);
    await setting('');
    await idle();
    assert.equal(await page.locator('dialog[open]').count(), 0, 'settings status does not open a new menu');
  };
  const forget = async (confirm = true) => {
    const before = requests.filter(req => req.operation === 'forget_all').length;
    await page.evaluate(() => { void NRCMemory.settings('forget'); });
    await page.getByRole('dialog', {name:'VERLAUF LÖSCHEN',exact:true}).waitFor();
    assert.equal(requests.filter(req => req.operation === 'forget_all').length, before);
    await button(confirm ? 'Endgültig löschen' : 'Abbrechen').click();
    await idle();
    assert.equal(requests.filter(req => req.operation === 'forget_all').length, before + Number(confirm));
  };
  await open(true);
  assert.equal(await page.locator('#responseAction').isDisabled(), false);
  assert.equal(await page.locator('.personal-memory-dialog').count(), 0, 'no separate memory settings surface');
  assert.deepEqual(await page.evaluate(() => NRCMemory.options()), { execution_policy: "private", require_memory: true });
  assert.equal(requests.filter(req => req.operation !== "inspect").length, 0);
  await setting('on');
  assert.equal(policy.enabled, true);
  assert.deepEqual(Object.keys(requests.find(req => req.operation === 'configure').policy).sort(), ['enabled', 'epoch']);
  assert.equal(await page.locator('dialog[open]').count(), 0);
  await open();
  const download = page.waitForEvent('download');
  await setting('export');
  const exported = JSON.parse(await readFile(await (await download).path(), 'utf8'));
  assert.equal(exported.originals.length, 101);
  assert.equal(exported.originals[100].records[0].text, 'private <script> evidence 100');
  assert.deepEqual(requests.filter(req => req.operation === 'export').map(req => req.after), [-1,99]);
  await idle();
  await forget(false);
  assert.equal(originals.length, 101);
  await setting('off');
  assert.equal(policy.enabled, false);
  assert.equal(originals.length, 101, 'disabling preserves exportable history');
  await setting('on');
  assert.equal(await page.locator('dialog[open]').count(), 0);
  const beforeAsk = requests.length;
  await page.evaluate(() => NRCAI.handleAsk('secret question', {forceRoom:true}));
  assert.equal(requests[beforeAsk].operation, 'inspect', 'chat prepares saved consent');
  assert.equal(asks.at(-1).require_memory, true);
  assert.match(await page.locator('#logOutput').innerText(), /private answer/);
  await open(); await forget();
  assert.equal(originals.length, 0);
  assert.deepEqual(await page.evaluate(() => [...roomHistory.values()].flat().map(message => message.message)), ['ordinary room message']);
  assert.doesNotMatch(await page.locator('#logOutput').innerText(), /secret|private/);
  await setting('off');
  assert.equal(policy.enabled, false);
  assert.equal(await page.evaluate(() => NRCMemory.options().require_memory), false);
  conflict = true;
  const before = requests.length;
  await setting('on');
  assert.match(await page.locator('#settingsResult').innerText(), /inzwischen geändert/);
  assert.equal(requests.length, before + 2, 'inspect then one mutation; uncertain mutation is never retried');
  assert.equal(await page.locator('#responseAction').isDisabled(), false);

  // An outage must block a new personal request until the explicit temporary choice.
  unavailable = true; conflict = false;
  await page.reload();
  const askCount = asks.length;
  await page.evaluate(() => NRCAI.handleAsk('temporary question', {forceRoom:true}));
  assert.match(await page.locator('#settingsResult').innerText(), /nicht erreichbar/);
  assert.equal(asks.length, askCount);
  assert.equal(await page.locator('dialog[open]').count(), 0, 'outage does not open a settings dialog');
  await button('Temporäres Gespräch').click();
  await page.evaluate(() => NRCAI.handleAsk('temporary question', {forceRoom:true}));
  assert.equal(await page.locator('dialog[open]').count(), 0);
  assert.equal(asks.at(-1).execution_policy, 'temporary');
  assert.equal(asks.at(-1).require_memory, false);
  assert.equal(await page.evaluate(() => NRCMemory.options('other-workspace').require_memory), true);

  unavailable = false; policy.enabled = true;
  await open(true);
  assert.equal(await page.evaluate(() => NRCMemory.options().require_memory), true, 'reload uses saved personal consent');
  const count = requests.length;
  await button('Temporäres Gespräch').click(); await idle();
  assert.equal(requests.length, count, 'temporary choice does not mutate saved consent');
  assert.equal(policy.enabled, true);
  assert.equal(await page.locator('dialog[open]').count(), 0);
  await open();
  for (const outcome of ['success','error','abort']) {
    await page.evaluate(() => {
      const original = window.fetch;
      window.fetch = (url, init) => String(url).endsWith('/ask') ? new Promise((resolve,reject) => {
        window.releaseAsk = outcome => {
          window.fetch = original;
          if (outcome === 'abort') reject(new DOMException('late cancellation','AbortError'));
          else resolve(new Response(outcome === 'success' ? JSON.stringify({answer:'late private answer'}) : 'late private error', {status:outcome === 'success'?200:503}));
        };
      }) : original(url,init);
      window.lateAsk = NRCAI.handleAsk('late secret question', {forceRoom:true});
    });
    await page.waitForFunction(() => window.releaseAsk);
    await forget();
    await page.evaluate(async outcome => { releaseAsk(outcome); delete window.releaseAsk; await lateAsk; }, outcome);
    assert.deepEqual(await page.evaluate(() => [...roomHistory.values()].flat().map(message => message.message)), ['ordinary room message'], `late ${outcome} cannot restore forgotten text`);
    assert.equal(await page.locator('#responseAction').isDisabled(), false);
  }

  // The default starts immediately, without a consent dialog or policy mutation.
  policy.enabled = true;
  await page.reload();
  const firstUseCount = asks.length;
  const configured = requests.filter(req => req.operation === 'configure').length;
  await page.evaluate(() => NRCAI.handleAsk('Remember this first question', {forceRoom:true}));
  assert.equal(asks.length, firstUseCount + 1);
  assert.equal(asks.at(-1).require_memory, true);
  assert.equal(await page.locator('dialog[open]').count(), 0);
  assert.equal(requests.filter(req => req.operation === 'configure').length, configured);

  // Local answers need epoch observation even without a restored history panel.
  // Switching to temporary must not disconnect that privacy invalidation.
  await open();
  await button('Temporäres Gespräch').click(); await idle();
  await page.evaluate(() => { window.NRCViewManager = {getActiveView: () => 'chat'}; });
  const beforeRemoteForget = requests.length;
  policy.epoch++; policy.revision++;
  await page.evaluate(() => NRCMemory.refresh());
  assert.equal(requests.length, beforeRemoteForget + 1, 'temporary mode still observes cached personal content');
  assert.equal(await page.evaluate(() => NRCMemory.options().require_memory), false, 'remote deletion preserves explicit temporary choice');
  assert.deepEqual(await page.evaluate(() => [...roomHistory.values()].flat().map(message => message.message)), ['ordinary room message'], 'remote deletion clears cached personal answers without a history panel');
  const afterRemoteForget = requests.length;
  await page.evaluate(() => NRCMemory.refresh());
  assert.equal(requests.length, afterRemoteForget, 'temporary scope without personal content stops polling');
  await page.evaluate(() => { currentWorkspaceId = 'untouched-workspace'; return NRCMemory.refresh(); });
  assert.equal(requests.length, afterRemoteForget, 'untouched workspaces are not polled');

  policy.enabled = false;
  await page.reload();
  await page.evaluate(() => NRCAI.handleAsk('Respect my saved opt-out', {forceRoom:true}));
  assert.equal(asks.at(-1).execution_policy, 'temporary');
  assert.equal(await page.locator('dialog[open]').count(), 0);
  assert.equal(policy.enabled, false);
  policy.enabled = true;

  await page.reload();
  requests.length = 0;
  await page.evaluate(() => {
    window.NRCViewManager = {getActiveView: () => 'sullivan'};
    return NRCMemory.resume(document.getElementById('restored'));
  });
  assert.equal(await page.locator('.sullivan-history-turn').count(), 50);
  assert.match(await page.locator('[data-sullivan-history]').innerText(), /Noch in Bearbeitung/);
  await button('Ältere Nachrichten').click();
  await page.waitForFunction(() => document.querySelectorAll('.sullivan-history-turn').length === 51);
  assert.match(await page.locator('.sullivan-history-turn').first().innerText(), /evidence 0/);
  assert.match(await page.locator('.sullivan-history-turn').last().innerText(), /evidence 50/);
  assert.equal(await button('Ältere Nachrichten').isVisible(), false);
  await button('Weitere Ergebnisse').click();
  await page.waitForFunction(() => document.querySelectorAll('[data-sullivan-history] details p').length === 51);
  assert.equal(await button('Weitere Ergebnisse').isVisible(), false);
  assert.match(await page.locator('[data-sullivan-history] details').innerText(), /Datensätze prüfen, nicht erneut ausführen/);
  assert.match(await page.locator('[data-sullivan-history] details').innerText(), /note_id: 100/);
  assert.equal(await page.locator('[data-sullivan-history] input, [data-sullivan-history] script, [data-sullivan-history] audio, [data-sullivan-history] .ai-action-plan').count(), 0);
  assert.equal(await page.locator('[data-sullivan-history] button:visible').count(), 0, 'restored plans and receipts have no executable controls');
  assert.deepEqual(requests.filter(req => req.operation === 'history').map(req => req.before), [-1,1]);
  assert.deepEqual(requests.filter(req => req.operation === 'receipts').map(req => req.before ?? -1), [-1,1]);
  const resumeCount = requests.length;
  await page.evaluate(() => NRCMemory.resume(document.getElementById('restored')));
  assert.equal(requests.length, resumeCount, 'resume is idempotent');
  assert.equal(await page.locator('[data-sullivan-history]').count(), 1);

  // A remote completion updates an active segment and its receipt; local live
  // plans remain executable only in their original card, never restored copies.
  await page.evaluate(() => {
    NRCMemory.trackRun('memory-test', 'local-run');
    const card = document.createElement('div'); card.className = 'ai-workbench-run'; card.textContent = 'Local approval stays';
    document.getElementById('restored').append(card);
  });
  turns[50].state = 'complete';
  receipts[50].state = 'applied';
  turns.push({sequence:51,run_id:'remote-run',channel:'voice',state:'complete',records:[{role:'user',text:'Remote voice'},{role:'user',text:' update'}]});
  turns.push({sequence:52,run_id:'local-run',channel:'chat',state:'complete',records:[{role:'assistant',text:'Duplicate local card'}]});
  policy.revision++;
  await page.evaluate(() => NRCMemory.refresh());
  assert.equal(await page.locator('.sullivan-history-turn').count(), 52);
  assert.match(await page.locator('[data-sullivan-history]').innerText(), /Remote voice update/);
  assert.doesNotMatch(await page.locator('[data-sullivan-history]').innerText(), /Duplicate local card|Noch in Bearbeitung|Ausgang noch unbestätigt/);
  assert.equal(await page.locator('.ai-workbench-run').textContent(), 'Local approval stays');
  const historyCount = requests.filter(req => req.operation === 'history').length;
  await page.evaluate(() => NRCMemory.refresh());
  assert.equal(requests.filter(req => req.operation === 'history').length, historyCount, 'unchanged revision does not scan originals');

  await page.evaluate(() => {
    window.NRCViewManager = {getActiveView: () => 'chat'};
    document.getElementById('restored').textContent = 'Ordinary room';
  });
  policy.revision++;
  await page.evaluate(() => NRCMemory.refresh());
  assert.equal(await page.locator('#restored').textContent(), 'Ordinary room', 'background refresh cannot insert private originals in an ordinary room');
  await page.evaluate(() => {
    NRCViewManager.getActiveView = () => 'sullivan';
    return NRCMemory.resume(document.getElementById('restored'));
  });
  assert.match(await page.locator('[data-sullivan-history]').innerText(), /Remote voice update/);

  // The original was saved, but no local answer was rendered. Even if a poll
  // consumed that revision while the request was pending, recovery must appear.
  await page.route('**/ai/ask', async route => {
    const req = route.request().postDataJSON();
    turns.push({sequence:53,run_id:req.run_id,channel:'chat',state:'complete',records:[{role:'assistant',text:'Saved answer despite lost response'}]});
    policy.revision++;
    await page.evaluate(() => NRCMemory.refresh());
    await route.abort('failed');
  });
  await page.evaluate(() => NRCAI.handleAsk('Lost response recovery', {forceRoom:true}));
  await page.evaluate(() => NRCMemory.refresh());
  await page.waitForFunction(() => document.querySelector('[data-sullivan-history]')?.textContent.includes('Saved answer despite lost response'));
  assert.equal(await page.locator('[data-sullivan-history] .ai-action-plan').count(), 0);

  await page.evaluate(() => {
    NRCViewManager.getActiveView = () => 'chat';
    NRCAI.getDisplayConvId = () => 2n;
    roomHistory.set(1n,[{message:'ordinary room message'}]);
    roomHistory.set(2n,[{message:'Stale local personal answer',aiContextRoomId:0n}]);
    loadRoomHistory(1n);
  });
  const ordinary = await page.locator('#logOutput').textContent();
  turns.shift(); policy.epoch++; policy.revision++;
  await page.evaluate(() => NRCMemory.refresh());
  assert.equal(await page.locator('#logOutput').textContent(), ordinary, 'off-view epoch invalidation preserves the visible ordinary room');
  assert.equal(await page.locator('#logOutput [data-sullivan-history]').count(), 0);
  assert.equal(await page.evaluate(() => [...roomHistory.values()].flat().filter(item => item.aiContextRoomId != null).length), 0);
  await page.evaluate(() => {
    NRCViewManager.getActiveView = () => 'sullivan';
    return NRCMemory.resume(document.getElementById('restored'));
  });
  assert.match(await page.locator('[data-sullivan-history]').innerText(), /Remote voice update/);

  turns.splice(0); policy.epoch++; policy.revision++;
  await page.evaluate(() => NRCMemory.refresh());
  assert.equal(await page.locator('.sullivan-history-turn').count(), 0, 'remote forgetting removes the restored transcript');
  await open(); await forget();
  assert.equal(await page.locator('[data-sullivan-history]').count(), 0, 'forget removes restored copies');

  // A late epoch response from a previous workspace must not clear the next
  // workspace's cache. Returning to the original scope still observes deletion.
  await page.reload();
  await page.route('**/ai/ask', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({answer:'Personal answer before temporary'}) }));
  await page.evaluate(() => NRCAI.handleAsk('Personal question before temporary', {forceRoom:true}));
  await open(); await button('Temporäres Gespräch').click(); await idle();
  await page.evaluate(() => {
    const original = window.fetch;
    window.fetch = (url, init) => JSON.parse(init.body).operation === 'changes' ? new Promise(resolve => {
      window.releaseChanges = () => { window.fetch = original; resolve(new Response(JSON.stringify({enabled:true,epoch:999,revision:999}))); };
    }) : original(url, init);
    window.staleRefresh = NRCMemory.refresh();
  });
  await page.waitForFunction(() => window.releaseChanges);
  await page.evaluate(async () => {
    currentWorkspaceId = 'untouched-workspace';
    releaseChanges(); await staleRefresh;
  });
  assert.match(await page.locator('#logOutput').innerText(), /Personal answer before temporary/, 'late response does not clear another workspace');
  await page.evaluate(() => { currentWorkspaceId = 'memory-test'; });

  // Remote personal deletion must not silently erase newer temporary answers.
  // This intentionally uses production AI logging and production cache clearing.
  await page.route('**/ai/ask', route => {
    asks.push(route.request().postDataJSON());
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify({answer:'New temporary answer survives', agent_session_id:'temporary-session'}) });
  });
  await page.evaluate(() => NRCAI.handleAsk('New temporary question survives', {forceRoom:true}));
  await page.evaluate(() => {
    const original = window.fetch;
    window.fetch = (url, init) => String(url).endsWith('/ask') ? new Promise(resolve => {
      window.pendingTemporaryRequest = JSON.parse(init.body);
      window.temporarySignal = init.signal;
      window.releaseTemporary = () => {
        window.fetch = original;
        resolve(Response.json({answer:'Late temporary completion survives',agent_session_id:'temporary-session'}));
      };
    }) : original(url, init);
    window.pendingTemporary = NRCAI.handleAsk('Pending temporary question survives', {forceRoom:true});
  });
  await page.waitForFunction(() => window.releaseTemporary);
  assert.equal(await page.evaluate(() => pendingTemporaryRequest.agent_session_id), 'temporary-session');
  policy.epoch++; policy.revision++;
  await page.evaluate(() => NRCMemory.refresh());
  assert.equal(await page.evaluate(() => NRCMemory.options().require_memory), false);
  assert.doesNotMatch(await page.locator('#logOutput').innerText(), /Personal answer before temporary/);
  assert.match(await page.locator('#logOutput').innerText(), /New temporary answer survives/, 'remote personal deletion preserves newer temporary answers');
  assert.equal(await page.evaluate(() => temporarySignal.aborted), false, 'remote personal deletion does not abort a temporary request');
  await page.evaluate(async () => { releaseTemporary(); await pendingTemporary; });
  assert.match(await page.locator('#logOutput').innerText(), /Late temporary completion survives/);
  await page.evaluate(() => NRCAI.handleAsk('Temporary follow-up after forgetting', {forceRoom:true}));
  assert.equal(asks.at(-1).agent_session_id, 'temporary-session', 'temporary session survives personal invalidation');
  assert.equal(await page.evaluate(() => [...roomHistory.values()].flat().filter(message => message.aiContextRoomId != null).every(message => message.aiExecutionPolicy === 'temporary')), true);

  // Mixed legacy/personal evidence makes the entire card non-preservable.
  await page.evaluate(async () => {
    roomHistory.set(2n, [
      {message:'legacy personal fragment',aiContextRoomId:0n,aiRunId:'mixed'},
      {message:'temporary-tagged fragment',aiContextRoomId:0n,aiRunId:'mixed',aiExecutionPolicy:'temporary'},
      {message:'temporary with personal plan',aiContextRoomId:0n,aiRunId:'mixed-plan',aiExecutionPolicy:'temporary',aiActionPlan:{executionPolicy:'private'}},
    ]);
    await NRCAI.forgetLocalHistory('memory-test', {personalOnly:true});
  });
  assert.equal(await page.evaluate(() => roomHistory.get(2n).length), 0);
  assert.match(await page.locator('#logOutput').innerText(), /New temporary answer survives/);
  await open(); await forget();
  assert.deepEqual(await page.evaluate(() => [...roomHistory.values()].flat().map(message => message.message)), ['ordinary room message'], 'explicit local forget remains broad');
  await button('Temporäres Gespräch').click(); await idle();
  for (const outcome of ['success', 'error', 'abort']) {
    await page.evaluate(() => {
      const original = window.fetch;
      window.fetch = (url, init) => String(url).endsWith('/ask') ? new Promise((resolve, reject) => {
        window.releasePersonal = outcome => {
          window.fetch = original;
          if (outcome === 'abort') reject(new DOMException('late personal cancellation', 'AbortError'));
          else resolve(new Response(outcome === 'success' ? JSON.stringify({answer:'Forbidden late personal answer'}) : 'Forbidden late personal error', {status:outcome === 'success' ? 200 : 503}));
        };
      }) : original(url, init);
      window.pendingPersonal = NRCAI.handleAsk('Forgotten personal question', {forceRoom:true});
    });
    await page.waitForFunction(() => window.releasePersonal);
    policy.epoch++; policy.revision++;
    await page.evaluate(() => NRCMemory.refresh());
    await page.evaluate(async outcome => { releasePersonal(outcome); delete window.releasePersonal; await pendingPersonal; }, outcome);
    assert.deepEqual(await page.evaluate(() => [...roomHistory.values()].flat().map(message => message.message)), ['ordinary room message'], `late personal ${outcome} cannot restore remotely forgotten text`);
  }
  for (const transition of ['remote inspect', 'local disable/enable']) {
    await page.reload();
    await page.route('**/ai/ask', route => route.fulfill({json:{answer:'Old epoch personal answer'}}));
    await page.evaluate(() => NRCAI.handleAsk('Old epoch question', {forceRoom:true}));
    if (transition === 'local disable/enable') {
      await open();
      await setting('off');
      assert.doesNotMatch(await page.locator('#logOutput').innerText(), /Old epoch/, 'local disable clears the old personal context immediately');
      await setting('on');
    } else {
      policy.epoch++; policy.revision++;
      await page.evaluate(() => {
        const clear = NRCAI.forgetLocalHistory;
        NRCAI.forgetLocalHistory = async (...args) => {
          await new Promise(resolve => { window.releaseEpochClear = resolve; });
          NRCAI.forgetLocalHistory = clear;
          return clear(...args);
        };
      });
    }
    await page.evaluate(() => {
      const original = window.fetch;
      window.fetch = (url, init) => String(url).endsWith('/ask') ? new Promise(resolve => {
        window.newEpochSignal = init.signal;
        window.oldContentAtDispatch = [...roomHistory.values()].flat().some(message => message.message.includes('Old epoch'));
        window.releaseNewEpoch = () => {
          window.fetch = original;
          resolve(Response.json({answer:'New epoch personal answer'}));
        };
      }) : original(url, init);
      window.newEpochAsk = NRCAI.handleAsk('New epoch question', {forceRoom:true});
    });
    if (transition === 'remote inspect') {
      await page.waitForFunction(() => window.releaseEpochClear);
      assert.equal(await page.evaluate(() => typeof window.releaseNewEpoch), 'undefined', 'dispatch waits for asynchronous invalidation');
      await page.evaluate(() => NRCAI.handleAsk('Concurrent request during clearing', {forceRoom:true}));
      assert.equal(await page.evaluate(() => typeof window.releaseNewEpoch), 'undefined', 'concurrent preparation cannot bypass invalidation');
      await page.evaluate(() => releaseEpochClear());
    }
    await page.waitForFunction(() => window.releaseNewEpoch);
    assert.equal(await page.evaluate(() => oldContentAtDispatch), false, `${transition}: old content is cleared before dispatch`);
    await page.evaluate(() => NRCMemory.refresh());
    assert.equal(await page.evaluate(() => newEpochSignal.aborted), false, `${transition}: next poll preserves the new epoch request`);
    await page.evaluate(async () => { releaseNewEpoch(); await newEpochAsk; });
    assert.match(await page.locator('#logOutput').innerText(), /New epoch personal answer/);
    assert.doesNotMatch(await page.locator('#logOutput').innerText(), /Old epoch/);
  }
  assert.deepEqual(errors, []);
  console.log('PASS personal memory: automatic personal default, saved opt-out, settings, explicit temporary fallback, scoped mode, paginated export/history/receipts, inert restoration, confirmed forget, late suppression, conflict, desktop/mobile themes');
} finally { await browser.close(); server.close(); }
