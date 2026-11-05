// Production voice UI with simulated media/provider transport. No API key,
// shared workspace or billable session. --serve exposes the same review fixture.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

const html = `<!doctype html><html lang="de" data-theme="dark"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="/css/main.css"><link rel="stylesheet" href="/css/voice.css"></head><body>
<div class="retro-container"><div class="app-shell">
<aside class="app-sidebar"><nav aria-label="Workspace views">Navigation</nav></aside>
<main class="content-shell"><button id="sullivanVoice" class="btn">VOICE</button><label>Notiz <textarea id="workspaceNote" class="task-detail-textarea">Rollout-Notizen</textarea></label></main>
<footer class="status-footer"><span>VERBUNDEN</span></footer>
</div></div>
<aside id="inspector" class="inspector ledger-context agenda-panel" style="position:fixed;right:0;top:0;width:min(450px,100vw);height:85vh;display:flex;flex-direction:column;background:var(--surface-panel)">
<header id="inspectorHeader" class="panel-header inspector-matrix-header"></header><div id="inspectorEntityHost" style="flex:1;min-height:0" hidden></div><div id="inspectorChatContextHost"></div><div id="inspectorViewContextHost"></div><div id="inspectorActions"><button id="inspectorBack" class="btn header-operation inspector-back inspector-matrix-control"><small>NAV ←</small><span>BACK</span></button></div>
</aside>
<script>
let currentWorkspaceId = 'voice-test';
function getAiUrl() { return '/ai'; }
window.NRCAI = { navigateToSource() { fixture.navigations++; } };
window.fixture = { applies: [], creates: 0, closes: 0, navigations: 0, tracks: [], deny: false, failCreate: false, unknownApply: false, holdApply: false,
  state: { revision: 1, result: null, transcript: 'Nutzer: Erstelle eine Aufgabe und eine Notiz für den Rollout.' } };
window.NRCLinksUI = {loadLinks: async()=>{}};
window.NRCAssets = {MAX_PAYLOAD_LENGTH: 1048576};
window.NRCTasks = {
 roomTasks:new Map([[0n,new Map([[10n,{id:10n}],[20n,{id:20n}]])]]),
 confirmDiscardTaskEdits:()=>{fixture.discards=(fixture.discards||0)+1;return !fixture.editing;},
 clearTaskSelection(){},
 selectTask(task){document.getElementById('inspectorHeader').textContent='TASK '+task.id;document.getElementById('inspectorEntityHost').innerHTML=fixture.editing?'<textarea id="recordDraft">Ungespeicherter Entwurf</textarea>':'<div class="record-document-scroll">TASK '+task.id+'</div>';}
};
fixture.propose = () => { fixture.state.result = { answer: 'Zwei Vorschläge sind vorbereitet. Bitte prüfe die Felder und bestätige nur die gewünschten Aktionen.',
  plan_id: 'plan-' + fixture.state.revision, proposed_actions: [
    { id: 'task', type: 'create_task', title: 'Rollout prüfen', description: 'Freigabe und offene Blocker prüfen.', priority: 128 },
    { id: 'note', type: 'create_note', title: 'Rollout-Entscheidung', content: 'Freigabe steht noch aus.', format: 'markdown' }] }; };
fixture.speak = () => { fixture.channel.onmessage({data: JSON.stringify({type:'session.input_transcript.delta',delta:'Nur die Notiz.'})}); fixture.state.revision++; fixture.state.result = null; };
fixture.propose();
Object.defineProperty(navigator.mediaDevices, 'getUserMedia', { value: async () => {
  if (fixture.deny) throw new Error('Mikrofon verweigert');
  const track = { enabled: true, stopped: false, stop() { this.stopped = true; } }; fixture.tracks.push(track);
  return { getTracks: () => [track], getAudioTracks: () => [track] };
}});
window.RTCPeerConnection = class extends EventTarget {
  iceGatheringState = 'complete'; connectionState = 'connected';
  addTrack() {}
  createDataChannel() { return fixture.channel = { readyState: 'open', close() {}, send(value) {
    if (JSON.parse(value).type === 'session.close') setTimeout(() => { fixture.state.closed = true; this.onmessage({data: JSON.stringify({type:'session.closed',usage:{seconds:42}})}); }, 20);
  }}; }
  async createOffer() { return {sdp:'offer',type:'offer'}; }
  async setLocalDescription(offer) { this.localDescription = offer; }
  async setRemoteDescription() { setTimeout(() => fixture.channel.onmessage({data:JSON.stringify({type:'session.started'})}), 10); }
  close() { this.connectionState = 'closed'; }
};
const originalFetch = window.fetch;
window.fetch = async (url, options) => {
  if (!String(url).startsWith('/ai/voice/')) return originalFetch(url, options);
  const op = String(url).split('/').at(-1), req = JSON.parse(options.body);
  if (op === 'create') { fixture.creates++; if (fixture.failCreate) return new Response('GPT-Live is not configured', {status:503}); return Response.json({id:'voice',sdp:'answer'}); }
  if (op === 'status') return Response.json(fixture.state);
  if (op === 'close') { fixture.closes++; return Response.json({ok:true}); }
  if (op === 'apply') {
    fixture.applies.push(req);
    if (req.revision !== fixture.state.revision || !fixture.state.result || !req.action_ids.length) return new Response('stale', {status:409});
    fixture.state.result = null;
    fixture.state.applying = true;
    delete fixture.state.apply_result;
    fixture.state.apply_revision = req.revision;
    if (fixture.holdApply) await new Promise(resolve => { fixture.releaseApply = resolve; });
    fixture.state.applying = false;
    if (fixture.terminalApply) {
      delete fixture.state.apply_result;
      fixture.state.error = 'Ausgang unbekannt; Datensätze prüfen.';
      fixture.state.closed = true;
      if (fixture.holdResponse) await new Promise(resolve => { fixture.releaseResponse = resolve; });
      throw new TypeError('response lost');
    }
    const data = fixture.applyResult || {ok:true,applied:req.action_ids.map(action_id => ({action_id,created_entity:{type:'note',id:81}})),failed:[]};
    fixture.state.apply_result = data;
    if (fixture.holdResponse) await new Promise(resolve => { fixture.releaseResponse = resolve; });
    if (fixture.unknownApply) throw new TypeError('response lost');
    return Response.json(data);
  }
  throw new Error('unexpected voice operation');
};
</script><script src="/dialog.js"></script><script src="/detail-ui.js"></script><script src="/inspector.js"></script><script src="/voice.js"></script></body></html>`;

const server = createServer(async (req, res) => {
  if (req.url === "/") { res.setHeader("Content-Type", "text/html"); res.end(html); return; }
  const pathname = new URL(req.url, "http://fixture").pathname;
  if (!/^\/(css\/[a-z-]+\.css|dialog\.js|detail-ui\.js|inspector\.js|voice\.js)$/.test(pathname)) { res.writeHead(404).end(); return; }
  try {
    res.setHeader("Content-Type", pathname.endsWith(".css") ? "text/css" : "text/javascript");
    res.end(await readFile(new URL(`.${pathname}`, import.meta.url)));
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(Number(process.env.PORT || 0), "127.0.0.1", resolve));
const url = `http://127.0.0.1:${server.address().port}`;
if (process.argv.includes("--serve")) {
  console.log(`Voice UI fixture: ${url} (simulated transport)`);
} else {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({viewport:{width:1280,height:900},deviceScaleFactor:2});
    const errors = []; page.on("pageerror", e => errors.push(e.message));
    const open = async () => { await page.goto(url); };
    await open();
    await page.evaluate(() => {
      fixture.state.result.proposed_actions = [
        {id:'edit',type:'update_note',title:'Entscheidung',asset_id:81,content:'Vollständiger Inhalt\n'.repeat(30)+'ENDE <script>unsafe</script>',tags:[],project:'',extra:{enabled:false,count:0}},
        {id:'delete',type:'delete_note',title:'Alte Notiz',asset_id:82,expected_updated_at:'1793881234567890123'},
        {id:'edge',type:'create_edge',source_type:'note',source_action_id:'other',target_type:'note',target_action_id:'edit',relation:'related-to'},
        {id:'task',type:'update_task',title:'Rollout',task_id:9,task_status:'InProgress',priority:0,blocked_by:7},
        {id:'other',type:'update_note',title:'Entscheidung',asset_id:83,content:'Andere Notiz'},
      ];
      fixture.applyResult = {ok:false,applied:[
        {action_id:'edit',entity:{type:'note',id:81,title:'Entscheidung'},already_applied:true},
        {action_id:'delete',deleted_entity:{type:'note',id:82,title:'Alte Notiz'}},
        {action_id:'edge',created_edge:{edge_id:23,source_type:'note',source_id:81,target_type:'task',target_id:9,relation:'related-to'}},
      ],failed:[{action_id:'task',error:'outcome_unknown: <script>unsafe</script>'}]};
    });
    await page.click('#sullivanVoice');
    await page.waitForSelector('[data-voice-plan] input');
    assert.equal(await page.locator('[data-voice-plan]').innerText().then(text => text.includes('ENDE <script>unsafe</script>')), false);
    const disclosure = page.locator('[data-voice-plan] summary');
    assert.equal(await disclosure.innerText(), 'Vollständigen Inhalt anzeigen');
    await disclosure.focus();
    await page.keyboard.press('Enter');
    await page.waitForFunction(() => document.querySelector('[data-voice-plan] summary').textContent === 'Inhalt einklappen');
    assert.equal(await page.locator('[data-voice-plan] details > div').textContent(), await page.evaluate(() => fixture.state.result.proposed_actions[0].content));
    assert.equal(await page.locator('[data-voice-plan] input:checked').count(), 0, 'expanding content never approves an action');
    const planText = (await page.locator('[data-voice-plan]').innerText()).replace(/\s+/g, ' ');
    for (const text of ['1. Notiz ändern', '5. Notiz ändern', 'ENDE <script>unsafe</script>', 'Projekt: Leer', 'Schlagwörter: Keine Einträge', 'enabled: Nein', 'count: 0', 'Erwartete Datensatzversion: 1793881234567890123', 'Quellaktion: Vorschlag 5 · Notiz ändern', 'Zielaktion: Vorschlag 1 · Notiz ändern', 'Aufgabenstatus: In Arbeit', 'Priorität: 0']) assert.ok(planText.includes(text), text);
    assert.equal(await page.locator('[data-voice-plan] details').count(), 1, 'only the long content has a disclosure');
    assert.ok(!planText.includes('Technische Details'));
    await disclosure.click();
    await page.waitForFunction(() => document.querySelector('[data-voice-plan] summary').textContent === 'Vollständigen Inhalt anzeigen');
    assert.equal(await page.locator('[data-voice-plan]').innerText().then(text => text.includes('ENDE <script>unsafe</script>')), false);
    assert.equal(await page.locator('[data-voice-plan] pre, [data-voice-plan] script').count(), 0);
    for (const check of await page.locator('[data-voice-plan] input').all()) await check.check();
    await page.getByRole('button', {name:'AUSWAHL BESTÄTIGEN'}).click();
    await page.waitForSelector('[data-voice-result] .ai-action-plan');
    const resultText = (await page.locator('[data-voice-result]').innerText()).replace(/\s+/g, ' ');
    for (const text of ['Bereits ausgeführt; nicht erneut angewendet.', 'Gelöscht: Notiz #82', 'Verknüpfungs-ID: 23', 'Datensatz prüfen, nicht erneut ausführen.']) assert.ok(resultText.includes(text), text);
    assert.equal(await page.locator('[data-voice-result] button').count(), 1, 'deleted records and edges do not get dead links');
    await page.locator('[data-voice-result] details').last().locator('summary').click();
    assert.match(await page.locator('[data-voice-result]').innerText(), /Fehlerdetail:\s+outcome_unknown: <script>unsafe<\/script>/);
    assert.equal(await page.locator('[data-voice-result] pre, [data-voice-result] script').count(), 0);
    await page.getByRole('button', {name:'Notiz #81 · Entscheidung ↗'}).click();
    assert.equal(await page.evaluate(() => fixture.navigations), 1);
    assert.equal(await page.evaluate(() => fixture.applies.length), 1);
    await open();
    assert.equal(await page.evaluate(() => fixture.creates), 0, "opening does not create a billed session");
    await page.evaluate(() => { fixture.state.result = {answer:'Eine normale Antwort.',proposed_actions:[]}; });
    await page.click('#sullivanVoice');
    await page.waitForFunction(() => fixture.creates === 1 && document.querySelector('[data-voice-answer]').textContent.includes('normale Antwort'));
    assert.equal(await page.locator('.voice-content').isVisible(), false, 'normal answers keep the default compact view');
    await page.evaluate(() => { fixture.state.revision++; fixture.propose(); });
    await page.waitForSelector("[data-voice-plan] input");
    assert.equal(await page.locator('#inspectorEntityHost .voice-review').isVisible(), true, 'proposals open in the inspector');
    await page.locator('#workspaceNote').fill('Notiz während des Gesprächs');
    assert.equal(await page.locator('#workspaceNote').inputValue(), 'Notiz während des Gesprächs');
    await page.getByRole('button', {name:'MINIMIEREN',exact:true}).click();
    assert.equal(await page.locator('.voice-content').isVisible(), false);
    assert.ok((await page.locator('.voice-panel').boundingBox()).height <= 86, 'desktop compact controls use two rows with inset actions');
    const docked = await page.locator('.voice-panel').boundingBox();
    assert.ok(docked.x + docked.width <= (await page.locator('#workspaceNote').boundingBox()).x, 'sidebar controls never cover workspace content');
    await page.getByRole('button', {name:'VORSCHLÄGE PRÜFEN',exact:true}).click();
    await page.getByRole('button', {name:'MINIMIEREN',exact:true}).click();
    assert.deepEqual(await page.locator('.voice-panel').boundingBox(), docked, 'restore fixed dock position');
    await page.setViewportSize({width:390,height:844});
    await page.waitForSelector('.status-footer .voice-dock');
    const clamped = await page.locator('.voice-panel').boundingBox();
    assert.ok(clamped.x >= 0 && clamped.x + clamped.width <= 390 && clamped.y + clamped.height <= 844, 'dock stays inside resized viewport');
    await page.setViewportSize({width:1280,height:900});
    await page.waitForSelector('.app-sidebar .voice-dock');
    for (const focused of ['note-share-focused', 'sullivan-share-focused']) {
      await page.evaluate(name => document.body.classList.add(name), focused);
      await page.waitForSelector('.status-footer .voice-panel');
      const footerPanel = await page.locator('.voice-panel').boundingBox();
      assert.ok(footerPanel.y + footerPanel.height <= 900, 'focused view keeps footer controls on screen');
      await page.evaluate(name => document.body.classList.remove(name), focused);
      await page.waitForSelector('.app-sidebar .voice-panel');
    }
    await page.getByRole('button', {name:'MIKROFON STUMM',exact:true}).click();
    assert.equal(await page.evaluate(() => fixture.tracks[0].enabled), false);
    assert.equal(await page.getByRole('button', {name:'MIKROFON AN',exact:true}).innerText(), 'MIC AUS');
    await page.getByRole('button', {name:'MIKROFON AN',exact:true}).click();
    await page.locator('#workspaceNote').fill('Auch minimiert editierbar');
    assert.equal(await page.getByRole('button', {name:'MIKROFON STUMM',exact:true}).isEnabled(), true);
    assert.equal(await page.evaluate(() => fixture.closes), 0);
    await page.click('#sullivanVoice');
    assert.equal(await page.locator('.voice-panel').count(), 1);
    assert.equal(await page.evaluate(() => fixture.creates), 1, 'restore never creates another session');
    assert.equal(await page.getByRole("button", {name:"AUSWAHL BESTÄTIGEN"}).isDisabled(), true);
    assert.equal(await page.locator("[data-voice-plan] input:checked").count(), 0);
    await page.locator('[data-voice-plan] input[value="note"]').check();
    await page.getByRole("button", {name:"AUSWAHL BESTÄTIGEN"}).click();
    await page.waitForFunction(() => fixture.applies.length === 1);
    assert.deepEqual(await page.evaluate(() => fixture.applies[0].action_ids), ["note"]);
    await page.waitForFunction(() => document.querySelector('[data-voice-result]').textContent.includes('1 Aktionen erfolgreich'));
    assert.equal(await page.locator("[data-voice-result]").innerText().then(s => s.includes("1 Aktionen erfolgreich")), true);
    await page.getByRole("button", {name:"MIKROFON STUMM",exact:true}).click();
    assert.equal(await page.evaluate(() => fixture.tracks[0].enabled), false);
    assert.equal(await page.evaluate(() => fixture.closes), 0, "mute does not close billing");
    await page.getByRole("button", {name:"BEENDEN",exact:true}).click();
    await page.waitForFunction(() => fixture.tracks[0].stopped);
    assert.equal(await page.locator('.voice-panel, .voice-dock, .voice-review').count(), 0);
    assert.equal(await page.evaluate(() => fixture.closes), 1);

    // Ending removes both compact controls and an open review, without taking
    // over another record. Final usage must not resurrect the dismissed UI.
    for (const width of [1280, 390]) for (const theme of ['white', 'dark']) for (const expanded of [false, true]) {
      await open();
      await page.setViewportSize({width, height:900});
      await page.evaluate(async theme => {
        document.documentElement.dataset.theme = theme;
        fixture.state.result = null;
      }, theme);
      await page.click('#sullivanVoice');
      await page.waitForFunction(() => !document.querySelector('.voice-actions button').disabled);
      await page.evaluate(() => NRCInspector.openEntity({type:'task',id:10}));
      await page.waitForFunction(() => !NRCInspector.isLoading());
      if (expanded) await page.getByRole('button', {name:'ÖFFNEN',exact:true}).click();
      await page.getByRole('button', {name:'BEENDEN',exact:true}).click();
      await page.waitForFunction(() => fixture.tracks[0].stopped && !NRCInspector.isLoading());
      assert.equal(await page.locator('.voice-panel, .voice-dock, .voice-review').count(), 0);
      assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), '10');
      assert.equal(await page.evaluate(() => fixture.closes), 1);
    }
    await page.setViewportSize({width:1280,height:900});

    await open();
    await page.click('#sullivanVoice');
    await page.waitForSelector("[data-voice-plan] input");
    await page.locator('[data-voice-plan] input[value="note"]').check();
    await page.evaluate(() => fixture.speak());
    assert.equal(await page.getByRole("button", {name:"AUSWAHL BESTÄTIGEN"}).isDisabled(), true);
    assert.equal(await page.evaluate(() => fixture.applies.length), 0, "speech never applies");
    await page.evaluate(() => { fixture.propose(); fixture.unknownApply = true; });
    await page.waitForFunction(() => document.querySelector('[data-voice-plan] input:not(:disabled)'));
    await page.locator('[data-voice-plan] input[value="note"]').check();
    await page.getByRole("button", {name:"AUSWAHL BESTÄTIGEN"}).click();
    await page.waitForFunction(() => document.querySelector('[data-voice-result]').textContent.includes('1 Aktionen erfolgreich'));
    assert.equal(await page.evaluate(() => fixture.applies.length), 1, "lost response is not retried");
    await page.evaluate(() => { currentWorkspaceId = 'other'; });
    await page.waitForFunction(() => fixture.tracks[0].stopped);

    // The write receipt must survive audio shutdown AND a lost HTTP response.
    await open();
    await page.evaluate(() => {
      fixture.holdApply = true; fixture.unknownApply = true;
      fixture.state.result.sources = [{type:'note',id:42,title:'Rollout-Quelle'}];
    });
    await page.click('#sullivanVoice');
    await page.waitForSelector("[data-voice-plan] input");
    await page.locator('[data-voice-plan] input[value="note"]').check();
    // Exercise the navigation race synchronously, before a status poll can
    // remove the source. A retained handler must also respect the close guard.
    await page.evaluate(() => {
      const source = document.querySelector('[data-voice-answer] button');
      document.querySelector('[data-voice-plan] button').click();
      if (!source.disabled) throw new Error('source stays enabled during approval');
      source.onclick();
    });
    assert.equal(await page.evaluate(() => fixture.navigations), 0);
    assert.equal(await page.locator('#inspectorEntityHost .voice-review').isVisible(), true);
    await page.waitForFunction(() => fixture.releaseApply);
    await page.getByRole('button', {name:'Close',exact:true}).focus();
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('.voice-content').isVisible(), false, 'Close leaves pending approval running in the dock');
    assert.equal(await page.evaluate(() => fixture.closes), 0, 'Inspector Close does not end audio');
    await page.locator('#workspaceNote').fill('Weiterarbeiten trotz laufender Bestätigung');
    await page.getByRole("button", {name:"BEENDEN",exact:true}).click();
    await page.waitForFunction(() => fixture.tracks[0].stopped);
    await page.evaluate(() => fixture.releaseApply());
    await page.waitForFunction(() => document.querySelector('[data-voice-result]').textContent.includes('81'));
    await page.click('#sullivanVoice');
    await page.waitForSelector('#inspectorEntityHost .voice-review');
    assert.equal(await page.locator('[data-voice-result]').isVisible(), true);
    assert.equal(await page.evaluate(() => fixture.applies.length), 1, "closed audio does not cause a write replay");
    await page.getByRole('button', {name:'Close',exact:true}).focus();
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('.voice-panel, .voice-dock, .voice-review').count(), 0, 'Close dismisses a settled result after audio ends');

    // Source navigation must leave both audio and the result panel alive.
    await open();
    await page.evaluate(() => { fixture.state.result.sources = [{type:'note',id:42,title:'Rollout-Quelle'}]; });
    await page.click('#sullivanVoice');
    await page.getByRole('button', {name:'Rollout-Quelle · 42 ↗',exact:true}).click();
    assert.equal(await page.evaluate(() => fixture.navigations), 1);
    assert.equal(await page.evaluate(() => fixture.closes), 0);
    assert.equal(await page.evaluate(() => fixture.tracks[0].stopped), false);
    assert.equal(await page.locator('.voice-content').isVisible(), false);
    await page.getByRole('button', {name:'VORSCHLÄGE PRÜFEN',exact:true}).click();
    assert.equal(await page.locator('[data-voice-plan] input').count(), 2);

    await page.setViewportSize({width:390,height:844});
    await open();
    await page.click('#sullivanVoice');
    await page.waitForSelector('[data-voice-plan] input');
    await page.getByRole('button', {name:'MINIMIEREN',exact:true}).click();
    await page.waitForFunction(() => document.querySelector('.voice-panel--collapsed'));
    assert.ok((await page.locator('.voice-panel').boundingBox()).height <= 56, 'narrow minimized panel stays one row with touch targets');
    await page.locator('#workspaceNote').fill('Notiz auf schmalem Bildschirm');
    await page.getByRole('button', {name:'VORSCHLÄGE PRÜFEN',exact:true}).click();
    assert.equal(await page.locator('[data-voice-plan] input').first().isVisible(), true);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.setViewportSize({width:1280,height:900});

    for (const width of [1280,390]) for (const view of ['noteShare','sullivanShare']) {
      await open();
      await page.setViewportSize({width,height:900});
      await page.evaluate(view => {
        document.body.classList.add(view === 'noteShare' ? 'note-share-focused' : 'sullivan-share-focused');
        NRCInspector.setActiveView(view);
      }, view);
      await page.click('#sullivanVoice');
      await page.waitForFunction(() => document.querySelector('.voice-compact-notice').textContent === '1 FREIGABE');
      await page.getByRole('button', {name:'VORSCHLÄGE PRÜFEN',exact:true}).click();
      await page.locator('[data-voice-plan] input[value="note"]').check();
      assert.equal(await page.locator('#inspector').isVisible(), true);
      await page.click('#inspectorBack');
      assert.equal(await page.locator('#inspector').isVisible(), false);
      assert.equal(await page.evaluate(() => document.body.classList.contains('inspector-open')), false);
      assert.equal(await page.evaluate(() => fixture.applies.length), 0);
    }
    await page.setViewportSize({width:1280,height:900});

    await open();
    await page.evaluate(() => { fixture.state.result = null; fixture.state.error = 'Recherche fehlgeschlagen'; });
    await page.click('#sullivanVoice');
    await page.waitForSelector('#inspectorEntityHost .voice-review');
    await page.getByRole('button', {name:'MINIMIEREN',exact:true}).click();
    await page.waitForTimeout(1200); // More than two status polls with the same error.
    assert.equal(await page.locator('.voice-content').isVisible(), false, 'acknowledged error does not repeatedly open');
    await page.evaluate(() => { fixture.state.error = 'Neue Fehlermeldung'; });
    await page.waitForSelector('#inspectorEntityHost .voice-review');
    await page.getByRole('button', {name:'BEENDEN',exact:true}).click();
    await page.waitForFunction(() => fixture.tracks[0].stopped);
    assert.equal(await page.locator('.voice-panel, .voice-dock').count(), 0, 'late close event does not resurrect dismissed controls');

    // A polled receipt settles A before its HTTP response; B must survive both
    // a late success and a lost response, and still require fresh selection.
    for (const lostResponse of [false, true]) {
      await open();
      await page.evaluate(lost => { fixture.holdResponse = true; fixture.unknownApply = lost; }, lostResponse);
      await page.click('#sullivanVoice');
      await page.waitForSelector('[data-voice-plan] input:not(:disabled)');
      await page.locator('[data-voice-plan] input[value="note"]').check();
      await page.getByRole('button', {name:'AUSWAHL BESTÄTIGEN'}).click();
      await page.waitForFunction(() => fixture.releaseResponse && document.querySelector('[data-voice-result]').textContent.includes('81'));
      await page.evaluate(() => { fixture.state.revision++; fixture.propose(); });
      await page.waitForFunction(() => document.querySelector('[data-voice-plan]').textContent.includes('REV 2'));
      await page.evaluate(() => fixture.releaseResponse());
      await page.waitForSelector('[data-voice-plan] input:not(:disabled)');
      assert.equal(await page.locator('[data-voice-plan] input:checked').count(), 0);
      assert.equal(await page.getByRole('button', {name:'AUSWAHL BESTÄTIGEN'}).isDisabled(), true);
      assert.equal(await page.evaluate(() => fixture.applies.length), 1);
      await page.evaluate(() => { fixture.holdResponse = false; fixture.unknownApply = false; });
      await page.locator('[data-voice-plan] input[value="task"]').check();
      await page.getByRole('button', {name:'AUSWAHL BESTÄTIGEN'}).click();
      await page.waitForFunction(() => fixture.applies.length === 2 && document.querySelector('[data-voice-result]').textContent.includes('81'));
      assert.deepEqual(await page.evaluate(() => fixture.applies[1].action_ids), ['task']);
      assert.equal(await page.evaluate(() => fixture.applies[1].revision), 2);
    }

    // Existing record history is shared with voice, not a second dialog stack.
    await open();
    await page.evaluate(async () => { await NRCInspector.openEntity({type:'task',id:10}); });
    await page.waitForFunction(() => !NRCInspector.isLoading());
    await page.click('#sullivanVoice');
    await page.waitForSelector('#inspectorEntityHost [data-voice-plan] input');
    await page.click('#inspectorBack');
    await page.waitForFunction(() => NRCInspector.current()?.id === 10n && !NRCInspector.isLoading());
    assert.equal(await page.evaluate(() => fixture.applies.length), 0, 'Back never applies');
    await page.getByRole('button', {name:'VORSCHLÄGE PRÜFEN',exact:true}).click();
    await page.locator('[data-voice-plan] input[value="note"]').check();
    await page.getByRole('button', {name:'AUSWAHL BESTÄTIGEN'}).click();
    await page.waitForFunction(() => NRCInspector.current()?.id === 10n && !NRCInspector.isLoading());
    assert.match(await page.locator('#inspectorEntityHost').innerText(), /TASK 10/);

    await page.evaluate(() => { fixture.holdApply=true; fixture.holdResponse=true; fixture.terminalApply=true; fixture.state.revision++; fixture.propose(); });
    await page.waitForSelector('#inspectorEntityHost [data-voice-plan] input:not(:disabled)');
    await page.locator('[data-voice-plan] input[value="note"]').check();
    await page.getByRole('button', {name:'AUSWAHL BESTÄTIGEN'}).click();
    await page.waitForFunction(() => fixture.releaseApply);
    await page.evaluate(async () => { fixture.editing=true; await NRCInspector.openEntity({type:'task',id:20}); fixture.releaseApply(); });
    await page.waitForFunction(() => fixture.releaseResponse && fixture.tracks[0].stopped && document.querySelector('[data-voice-result]').textContent.includes('Ausgang unbekannt'));
    await page.evaluate(() => fixture.releaseResponse());
    await page.waitForFunction(() => document.querySelector('.voice-compact-notice').textContent === 'FEHLER');
    assert.equal(await page.locator('#recordDraft').inputValue(), 'Ungespeicherter Entwurf');
    assert.equal(await page.evaluate(() => fixture.applies.length), 2, 'unknown second outcome is never resubmitted');
    assert.match(await page.locator('[data-voice-result]').textContent(), /Ausgang unbekannt/);

    await open();
    await page.evaluate(async () => { fixture.holdApply=true; await NRCInspector.openEntity({type:'task',id:10}); });
    await page.waitForFunction(() => !NRCInspector.isLoading());
    await page.click('#sullivanVoice');
    await page.waitForSelector('#inspectorEntityHost [data-voice-plan] input');
    await page.locator('[data-voice-plan] input[value="note"]').check();
    await page.getByRole('button', {name:'AUSWAHL BESTÄTIGEN'}).click();
    await page.waitForFunction(() => fixture.releaseApply);
    await page.evaluate(() => NRCInspector.openEntity({type:'task',id:20}));
    await page.waitForFunction(() => NRCInspector.current()?.id === 20n && !NRCInspector.isLoading());
    await page.evaluate(() => fixture.releaseApply());
    await page.waitForFunction(() => document.querySelector('[data-voice-result]').textContent.includes('81'));
    assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), '20', 'receipt must not navigate away from a newer record');

    await open();
    await page.evaluate(async () => { fixture.editing=true; await NRCInspector.openEntity({type:'task',id:10}); });
    await page.waitForSelector('#recordDraft');
    await page.click('#sullivanVoice');
    await page.waitForFunction(() => document.querySelector('.voice-compact-notice').textContent === '1 FREIGABE');
    assert.equal(await page.locator('#recordDraft').inputValue(), 'Ungespeicherter Entwurf');
    assert.equal(await page.evaluate(() => fixture.discards || 0), 0, 'background proposal never asks to discard edits');
    await page.getByRole('button', {name:'VORSCHLÄGE PRÜFEN',exact:true}).click();
    assert.equal(await page.locator('#recordDraft').inputValue(), 'Ungespeicherter Entwurf', 'refusing explicit navigation preserves draft');
    assert.equal(await page.evaluate(() => fixture.discards), 1);

    for (const flag of ["deny", "failCreate"]) {
      await open(); await page.evaluate(flag => { fixture[flag] = true; }, flag);
      await page.click('#sullivanVoice');
      await page.waitForFunction(() => document.querySelector('[data-voice-status]').textContent.includes('fehlgeschlagen'));
      assert.equal(await page.evaluate(() => fixture.tracks.every(track => track.stopped)), true);
    }
    assert.deepEqual(errors, []);
    console.log("PASS voice UI: nonmodal editing, minimize/restore, source navigation, narrow layout, explicit approval, exact selection, correction, lost-response recovery, mute/end, workspace change, denied microphone, unavailable provider");
  } finally { await browser.close(); server.close(); }
}
