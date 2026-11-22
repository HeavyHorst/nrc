// Real UI + authenticated Odin stack; reads wire traffic, never calls domain APIs.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {chromium} from 'playwright';

const url=process.env.NRC_REVIEW_URL;
assert.ok(url,'run with NRC_REVIEW_IDENTITY=1 NRC_REVIEW_CLIENT_E2E=1 go test -run TestReviewClientPublicUI');
const phase=process.env.NRC_REVIEW_PHASE || 'after', before=phase==='before';
const reconnect=process.env.NRC_REVIEW_RECONNECT==='1';
const fixture=await fetch(`${url}/fixture.json`).then(r=>r.json());
const output=path.resolve('.amp/in/artifacts/review-p2-latest');
await fs.mkdir(output,{recursive:true});
const browser=await chromium.launch({args:[`--remote-debugging-port=${process.env.NRC_REVIEW_RECORD==='1'?9339:0}`,'--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4']});
const results=[],errors=[];
try {
  const context=await browser.newContext({viewport:{width:1440,height:1000},deviceScaleFactor:2,serviceWorkers:'block',...(reconnect?{recordVideo:{dir:output,size:{width:1440,height:1000}}}:{})});
  if(reconnect)await context.addInitScript(()=>{
    addEventListener('DOMContentLoaded',()=>{
      const cursor=document.createElement('div');cursor.style.cssText='position:fixed;width:12px;height:12px;border:2px solid #111;background:#fff;border-radius:50%;z-index:2147483647;pointer-events:none;left:8px;top:8px';document.body.append(cursor);
      addEventListener('mousemove',e=>{cursor.style.left=e.clientX+'px';cursor.style.top=e.clientY+'px'});
    });
  });
  const page=await context.newPage();
  const sent=[],received=[];
  page.on('pageerror',e=>errors.push(e.message));
  page.on('websocket',socket=>{
    socket.on('framesent',({payload})=>{if(Buffer.isBuffer(payload) && payload.readUInt16BE(0)===77)sent.push(JSON.parse(payload.subarray(2,-4).toString()))});
    socket.on('framereceived',({payload})=>{if(Buffer.isBuffer(payload) && payload.readUInt16BE(0)===182)received.push(JSON.parse(payload.subarray(6).toString()))});
  });
  const op=verb=>page.locator(`#reviewEditor [data-review-op="${verb}"]`);
  const boot=async()=>{await page.goto(`${url}/?identity=${Date.now()}#workspace=${fixture.workspace}`);await page.waitForFunction(()=>serverReady)};
  const idle=()=>page.waitForFunction(()=>document.getElementById('reviewEditor')?.getAttribute('aria-busy')==='false');
  const save=async()=>{await op('save').click();await page.getByText('DRAFT SAVED',{exact:true}).waitFor();await idle()};
  const confirm=async()=>{const d=page.getByRole('dialog').last();await d.getByRole('button',{name:'Confirm',exact:true}).click()};
  const prompt=async value=>{const d=page.getByRole('dialog').last();await d.locator('input').fill(value);await d.getByRole('button',{name:'Create',exact:true}).click()};
  const ref=()=>page.evaluate(()=>{const r=NRCInspector.current();return {...r,id:String(r.id),roomId:String(r.roomId)}});
  const visibleID=async()=> (await page.locator('#inspectorHeader .identity-reference').textContent()).match(/#(\d+)/)?.[1] || '0';
  const shot=async name=>{if(reconnect)await page.locator('#reviewEditor').evaluate(el=>{document.activeElement?.blur();for(let node=el;node;node=node.parentElement)node.scrollTop=0;for(const node of el.querySelectorAll('*'))if(node.scrollTop)node.scrollTop=0});await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));await page.screenshot({path:path.join(output,`client-${phase}-${name}.png`)})};
  const task=async(discard=false)=>{if(!await page.locator('#kanbanPanel').isVisible())await page.locator('#tasksBtn').click();await page.locator('[data-task-grouping="flat"]').click();await page.locator(`#taskListBody [data-task-id="${fixture.taskId}"] .col-id`).click();if(discard)await confirm();await page.waitForFunction(()=>NRCInspector.current()?.type==='task')};
  const roundtrip=async(discard=false)=>{await task(discard);await page.locator('#inspectorBack').click();await page.locator('#reviewEditor').waitFor();await idle()};
  const original=async()=>{await boot();await page.locator('#reviewsBtn').click();await page.locator(`[data-review="${fixture.formId}"]`).click();await op('copy').waitFor();await idle()};
  if(reconnect) {
    await original();await op('copy').click();await idle();
    await page.locator('#reviewForm [name="build"]').fill('reconnect-build');await save();
    const id=await visibleID(),title=page.locator('#reviewForm [name="title"]');
    await title.fill('Ungespeicherter Entwurf · nach Verbindungsabbruch erhalten');
    const box=await title.boundingBox();await page.mouse.move(box.x+box.width/2,box.y+box.height/2,{steps:20});
    await shot('reconnect-draft-before-loss');
    assert.equal((await page.request.post(`${url}/disconnect-transport`)).status(),204);await page.waitForFunction(()=>!serverReady);
    if(!before) {
      assert.equal(await op('save').isDisabled(),true);
      assert.equal(await title.inputValue(),'Ungespeicherter Entwurf · nach Verbindungsabbruch erhalten');
      assert.equal(await visibleID(),id);await shot('reconnect-offline-preserved');
    }
    assert.equal((await page.request.post(`${url}/restore-transport`)).status(),204);await page.waitForFunction(()=>serverReady);
    if(before) {
      const start=sent.length;await page.locator('#inspectorHeader [data-review-op="reload"]').click();await idle();
      await page.getByText('LATEST SERVER STATE',{exact:true}).waitFor();
      assert.equal(await title.inputValue(),'');assert.equal(await visibleID(),'0');
      assert.equal(sent.slice(start).filter(q=>q.op==='get').length,0);
      results.push({reconnect:true,lostDraft:true,falseLatestServerState:true});await shot('reconnect-before-false-refresh');
    } else {
      await page.getByText('RECONNECTED · LOCAL DRAFT RETAINED · REFRESH TO FETCH SERVER STATE',{exact:true}).waitFor();
      assert.equal(await visibleID(),id);assert.equal((await ref()).id,id);assert.equal(await op('save').isEnabled(),true);
      assert.equal(await title.inputValue(),'Ungespeicherter Entwurf · nach Verbindungsabbruch erhalten');
      await shot('reconnect-after-preserved');
      const start=sent.length;
      const refresh=page.locator('#inspectorHeader [data-review-op="reload"]');
      const saveBox=await op('save').boundingBox();await page.mouse.move(saveBox.x+saveBox.width/2,saveBox.y+saveBox.height/2,{steps:60});
      const refreshBox=await refresh.boundingBox();await page.mouse.move(refreshBox.x+refreshBox.width/2,refreshBox.y+refreshBox.height/2,{steps:60});await refresh.click();
      const cancel=page.getByRole('dialog').getByRole('button',{name:'Cancel',exact:true});await cancel.waitFor();
      const cancelBox=await cancel.boundingBox();await page.mouse.move(cancelBox.x+cancelBox.width/2,cancelBox.y+cancelBox.height/2,{steps:60});await shot('reconnect-refresh-discard-guard');
      await cancel.click();await idle();
      assert.equal(sent.slice(start).filter(q=>q.op==='get').length,0);
      assert.equal(await title.inputValue(),'Ungespeicherter Entwurf · nach Verbindungsabbruch erhalten');
      await save();const writes=sent.slice(start).filter(q=>['create','update'].includes(q.op));
      assert.equal(writes.length,1);assert.equal(writes[0].op,'update');assert.equal(writes[0].form_id,id);
      await refresh.click();await page.getByText('LATEST SERVER STATE',{exact:true}).waitFor();await idle();
      assert.equal(sent.slice(start).filter(q=>q.op==='get' && q.form_id===id).length,1);
      assert.equal(await title.inputValue(),'Ungespeicherter Entwurf · nach Verbindungsabbruch erhalten');
      await roundtrip();assert.equal(await visibleID(),id);assert.equal(await title.inputValue(),'Ungespeicherter Entwurf · nach Verbindungsabbruch erhalten');
      results.push({reconnect:true,id,preservedDraft:true,guardedRefresh:true,persistedOnce:true});await shot('reconnect-after-saved');
    }
  } else {
  for(const kind of ['create','ticket-create','copy','retest']) {
    if(kind==='create' || kind==='ticket-create') {
      await boot();
      if(kind==='create') {await page.locator('#reviewsBtn').click();await page.locator('#reviewNew').click();await page.locator('#reviewForm [name="title"]').fill('Inspector identity new draft');await op('add').click();await page.locator('[name="question"]').fill('Does canonical identity survive history?')}
      else {await page.locator('#ticketsBtn').click();await page.locator(`[data-ticket="${fixture.ticketId}"]`).click();await page.getByRole('button',{name:'+ REVIEW FORM',exact:true}).click();await confirm()}
      await page.locator('#reviewForm [name="build"]').fill('identity-build');await save();
    } else {
      await original();
      if(kind==='retest') {
        await op(`run:${fixture.runId}`).click();await idle();
        await op('close').click();await prompt('conditional');await prompt('Retest identity regression');await confirm();await op('retest').waitFor();
      }
      await op(kind).click();await idle();
      const copiedID=await visibleID();
      await roundtrip(kind==='retest');
      await shot(`${kind}-immediate-returned`);
      if(before) {
        assert.notEqual(await visibleID(),copiedID,'copy itself must reproduce stale history before any Save');
        results.push({kind,stage:'immediately after copy, before Save',id:copiedID,returnedID:await visibleID()});
        // Re-enter the persisted new draft via its public register to continue
        // testing the Save/Back scenario independently on both versions.
        await page.locator('#reviewsBtn').click();await page.locator(`[data-review="${copiedID}"]`).click();await idle();
      } else {
        assert.equal(await visibleID(),copiedID);assert.equal((await ref()).id,copiedID);
        if(kind==='retest')assert.equal((await ref()).predecessor.id,fixture.runId);
      }
      await page.locator('#reviewForm [name="build"]').fill('identity-new-build');await save();
    }
    const id=await visibleID(), initial=await ref();
    assert.notEqual(id,fixture.formId);assert.notEqual(id,'0');
    await shot(`${kind}-saved`);
    await roundtrip();
    const returned=await ref(), returnedID=await visibleID();
    const result={kind,id,initial,returned,returnedID};
    await shot(`${kind}-history-restored`);
    if(before && (kind==='create' || kind==='ticket-create')) {
      assert.notEqual(returnedID,id,'negative control must restore wrong form');
      if(await op('save').count()) {const start=sent.length;await page.locator('#reviewForm [name="title"]').fill('Duplicate caused by stale inspector identity');await save();result.secondSave=sent.slice(start).find(q=>['create','update'].includes(q.op)).op;assert.equal(result.secondSave,'create')}
    } else if(!before) {
      assert.equal(initial.id,id);assert.equal(returned.id,id);assert.equal(returnedID,id);
      for(const key of ['seed','ticket','answerId'])assert.ok(!returned[key],`${key} cleared`);
      assert.ok(!returned.runId,'old run not carried to new draft');
      assert.equal(await page.locator('#reviewForm [name="build"]').inputValue(),kind==='create' || kind==='ticket-create'?'identity-build':'identity-new-build');
      const start=sent.length;await save();const writes=sent.slice(start).filter(q=>['create','update'].includes(q.op));assert.equal(writes.length,1);assert.equal(writes[0].op,'update');assert.equal(writes[0].form_id,id);result.secondSave='update';
      if(kind==='retest') {
        assert.equal(returned.predecessor.id,fixture.runId);
        await op('release').click();await confirm();await op('qa').waitFor();await idle();
        const start=sent.length;await op('qa').click();await page.locator('[data-answer]').first().waitFor();await idle();
        const create=sent.slice(start).find(q=>q.op==='run_create');assert.equal(create.previous_run,fixture.runId);assert.equal(create.kind,'customer');assert.equal(create.label,'Customer Alpha');
        const run=received.findLast(q=>q.run?.form_id===id)?.run;assert.equal(run.previous_run,fixture.runId);result.newRun=run;
        await roundtrip();assert.equal((await ref()).runId,run.id);assert.ok(!((await ref()).predecessor));
        await shot('retest-run-after-back');
      }
    }
    await shot(`${kind}-returned`);results.push(result);
  }
  // Typed Answer link remains pinned to exactly one contribution and survives Back.
  await boot();await task();
  const answer=fixture.answers.find(a=>a.point_id==='1');
  const link=page.locator(`button[data-target-id="${answer.id}"]`);
  const follow=async()=>{
    await link.waitFor({state:'attached'});
    const group=link.locator('xpath=ancestor::*[@data-resource][1]');
    if(await group.count()){const toggle=group.locator('[data-resource-toggle]');if(await toggle.getAttribute('aria-expanded')==='false')await toggle.click()}
    await link.click();await page.locator(`[data-review-answer="${answer.id}"].review-answer-selected`).waitFor();
  };
  await follow();
  await roundtrip();
  assert.equal((await ref()).answerId,answer.id);assert.equal((await ref()).runId,fixture.runId);assert.equal(await page.locator('.review-answer-selected').count(),1);
  await shot('typed-answer-after-back');
  for(const mobile of [false,true])for(const theme of ['light','dark']) {
    await page.setViewportSize(mobile?{width:390,height:844}:{width:1440,height:1000});
    await page.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);
    if(mobile && !await page.locator('.review-answer-selected').isVisible()) {await page.locator(`#taskListBody [data-task-id="${fixture.taskId}"]`).focus();await page.keyboard.press('Enter');await follow()}
    await shot(`typed-answer-${mobile?'narrow':'desktop'}-${theme}`);
  }
  }
  // Optional human-pointer clip, through agent-browser attached to this real UI.
  if(process.env.NRC_REVIEW_RECORD==='1') {
    await page.setViewportSize({width:1440,height:1000});await original();
    const execute=promisify(execFile),session=`rp2-${phase}-${process.pid}`;
    const env={...process.env,ACTION_VIDEO_SESSION:session,AGENT_BROWSER_CDP:'9339'};
    const recorder=process.env.NRC_REVIEW_RECORDER;
    assert.ok(recorder,'NRC_REVIEW_RECORDER must point to action-video.mjs');
    const record=(...args)=>execute('node',[recorder,...args],{env});
    try {
      const cdp=await context.newCDPSession(page),{targetInfo}=await cdp.send('Target.getTargetInfo');await cdp.detach();
      await execute('agent-browser',['--session',session,'--restore','--cdp','9339','tab',targetInfo.targetId],{env});
      const attached=await execute('agent-browser',['--session',session,'snapshot'],{env});
      assert.match(attached.stdout,/COPY TO NEW DRAFT/,'agent-browser attached to settled review UI');
      // agent-browser's human pointer currently halves CDP coordinates at DPR 2.
      // Screenshots above remain 2x; use 1x only for this interaction recording.
      await execute('agent-browser',['--session',session,'set','viewport','1440','1000','1'],{env});
      await record('start',`/tmp/client-${phase}-identity-raw.mp4`,'--fps','15');
      await record('hover','[data-review-op="compare"]');
      await record('click','[data-review-op="copy"]');await idle();
      const clipID=await visibleID();assert.notEqual(clipID,fixture.formId);
      await record('fill','#reviewForm [name="build"]','clip-build');
      await record('click','[data-review-op="save"]');await idle();
      if(!await page.locator('#kanbanPanel').isVisible())await record('click','#tasksBtn');
      assert.equal(await page.locator('#kanbanPanel').isVisible(),true,`recorded Tasks click must open task register; view=${await page.evaluate(()=>NRCViewManager.getActiveView())}`);
      await record('click','[data-task-grouping="flat"]');
      await record('click',`#taskListBody [data-task-id="${fixture.taskId}"] .col-id`);
      await record('click','#inspectorBack');await idle();
      assert.equal(await visibleID()===clipID,!before);
      await record('hover','#inspectorHeader .identity-reference');
      await record('stop',path.join(output,`client-${phase}-identity-flow.mp4`));
    } finally {await execute('agent-browser',['--session',session,'close'],{env}).catch(()=>{})}
  }
  assert.deepEqual(errors,[]);
  await fs.writeFile(path.join(output,`client-${phase}-${reconnect?'reconnect':'identity'}-results.json`),JSON.stringify({phase,results,errors},null,2));
  console.log(JSON.stringify({phase,results,errors},null,2));
  const video=reconnect?page.video():null;
  await context.close();
  if(video){await video.saveAs(path.join(output,`client-${phase}-reconnect.webm`));await fs.unlink(await video.path());}
} finally {await browser.close()}
