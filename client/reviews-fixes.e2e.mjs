// Public UI regression against TestReviewClientPublicUI's authenticated real server.
// No production APIs are invoked or replaced by this browser test.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

const url = process.env.NRC_REVIEW_URL;
assert.ok(url, 'run through NRC_REVIEW_CLIENT_E2E=1 go test -run TestReviewClientPublicUI');
const phase = process.env.NRC_REVIEW_PHASE || 'after';
const before = phase === 'before';
const fixture = await fetch(`${url}/fixture.json`).then(r => r.json());
const output = path.resolve('.amp/in/artifacts/review-p2');
await fs.mkdir(output, {recursive:true});
const browser = await chromium.launch();
const results = [];
try {
  const context = await browser.newContext({viewport:{width:1440,height:1000},deviceScaleFactor:2,serviceWorkers:'block'});
  const page = await context.newPage();
  page.setDefaultTimeout(15000);
  const errors = [], sent = [], received = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('websocket', socket => {
    socket.on('framesent', ({payload}) => {if(Buffer.isBuffer(payload))sent.push(payload)});
    socket.on('framereceived', ({payload}) => {if(Buffer.isBuffer(payload))received.push(payload)});
  });
  const screenshot = async name => page.screenshot({path:path.join(output,`${phase}-${name}.png`)});
  const findingActions = async (contribution, name) => {
    const actions=contribution.locator('[data-finding-references]');
    assert.equal(await contribution.getByRole('button',{name:'FINDINGS / REFERENCES',exact:true}).count(),0);
    assert.equal(await contribution.getByText('REFERENCES · ASSET',{exact:false}).count(),0);
    const linkButton=actions.getByRole('button',{name:'+ LINK TASK / TICKET',exact:true});
    await linkButton.click();
    const picker=page.locator('.note-link-picker:visible');
    await picker.getByRole('button',{name:'TICKET',exact:true}).click();
    await picker.getByText('Review navigation ticket',{exact:true}).click();
    const reference=actions.locator('.note-link-item').filter({has:page.locator(`[data-reference-id="${fixture.ticketId}"][data-reference-type="1"]`)});
    await reference.waitFor();
    assert.equal(await reference.locator('.note-link-kind').textContent(),'TICKET');
    assert.equal(await reference.locator('.note-link-target').textContent(),'Review navigation ticket');
    await reference.getByRole('button',{name:'Review navigation ticket',exact:true}).click();
    await page.waitForFunction(id=>NRCInspector.current()?.type==='ticket' && String(NRCInspector.current().id)===id,fixture.ticketId);
    assert.equal(await page.locator('.review-comparison-dialog').count(),0,'following a reference closes comparison');
    await page.locator('#inspectorBack').click();
    if(name==='comparison')await page.locator('#reviewEditor [data-review-op="compare"]').click();
    await reference.waitFor();
    // Cancel must not create a task or hide either direct action.
    const start=sent.length;
    await actions.getByRole('button',{name:'CREATE TASK FROM THIS FINDING',exact:true}).click();
    await page.getByRole('dialog').last().getByRole('button',{name:'Cancel',exact:true}).click();
    await page.waitForFunction(()=>!document.querySelector('#reviewEditor[aria-busy="true"]'));
    assert.equal(sent.slice(start).filter(b=>b.readUInt16BE(0)===20).length,0);
    for(const mobile of [false,true])for(const theme of ['white','dark']) {
      await page.setViewportSize(mobile?{width:390,height:844}:{width:1440,height:1000});
      await page.evaluate(theme=>setTheme(theme,false),theme);
      if(mobile && name==='record' && !await actions.isVisible()) {
        await page.locator(`#taskListBody [data-task-id="${fixture.taskId}"]`).focus();
        await page.keyboard.press('Enter');
        await follow(page.locator(`button[data-target-id="${fixture.answers.find(a=>a.point_id==='1').id}"]`));
      }
      await actions.scrollIntoViewIfNeeded();
      const boxes=await actions.locator('.customer-actions > button').evaluateAll(buttons=>buttons.map(b=>{const r=b.getBoundingClientRect();return {x:r.x,y:r.y,right:r.right,bottom:r.bottom};}));
      assert.equal(boxes.length,2);
      assert.ok(boxes[1].y>=boxes[0].bottom+3 || boxes[1].x>=boxes[0].right+3,'buttons have a visible horizontal or vertical gap');
      const bounds=await actions.boundingBox(), viewport=page.viewportSize();
      const x=Math.max(0,bounds.x-8), y=Math.max(0,bounds.y-8);
      await page.screenshot({path:path.join(output,`finding-actions-${name}-${mobile?'mobile':'desktop'}-${theme}.png`),clip:{x,y,width:Math.min(viewport.width,bounds.x+bounds.width+8)-x,height:Math.min(viewport.height,bounds.y+bounds.height+8)-y}});
    }
    await page.setViewportSize({width:1440,height:1000});
    await reference.getByRole('button',{name:'Remove link to Review navigation ticket',exact:true}).click();
    await reference.waitFor({state:'detached'});
  };
  const variants = async (name, focus) => {
    const cdp=await context.newCDPSession(page);
    for(const mobile of [false,true])for(const theme of ['light','dark']) {
      await page.setViewportSize(mobile?{width:390,height:844}:{width:1440,height:1000});
      await cdp.send('Emulation.setTouchEmulationEnabled',{enabled:mobile});
      assert.equal(await page.evaluate(()=>matchMedia('(pointer: coarse)').matches),mobile);
      await page.evaluate(theme=>document.documentElement.setAttribute('data-theme',theme),theme);
      // Desktop-to-phone resizing does not automatically reopen the Inspector drawer.
      // Re-enter through the same visible task and relationship controls on phone.
      if(mobile && name==='selected-contribution' && !await focus.isVisible()) {
        await page.locator(`#taskListBody [data-task-id="${fixture.taskId}"]`).focus();
        await page.keyboard.press('Enter');
        await follow(page.locator(`button[data-target-id="${fixture.answers.find(a=>a.point_id==='1').id}"]`));
      }
      await focus.scrollIntoViewIfNeeded();
      await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
      await screenshot(`${name}-${mobile?'mobile':'desktop'}-${theme}`);
    }
    await cdp.send('Emulation.setTouchEmulationEnabled',{enabled:false});
    await page.setViewportSize({width:1440,height:1000});
    await cdp.detach();
  };
  const follow = async locator => {
    await locator.waitFor({state:'attached'});
    const block=locator.locator('xpath=ancestor::*[@data-resource][1]');
    if(await block.count()) {
      const toggle=block.locator('[data-resource-toggle]');
      if(await toggle.getAttribute('aria-expanded')==='false')await toggle.click();
    }
    await locator.click();
  };
  const boot = async () => {
    await page.goto(`${url}/?fresh=${Date.now()}#workspace=${fixture.workspace}`);
    await page.waitForFunction(() => serverReady);
  };
  const reviews = async () => {
    await boot();
    await page.locator('#reviewsBtn').click();
    await page.locator(`[data-review="${fixture.formId}"]`).click();
    await page.locator('[data-review-op="compare"]').waitFor({state:'visible'});
  };
  await reviews();
  if(!before) {
    await page.getByRole('button',{name:'REFERENCES',exact:true}).click();
    await page.getByRole('button',{name:'+ LINK TASK / TICKET',exact:true}).click();
    const picker=page.locator('.note-link-picker:visible');
    await picker.getByText('Review navigation task',{exact:true}).waitFor();
    await picker.getByRole('button',{name:'TICKET',exact:true}).click();
    await picker.getByText('Review navigation ticket',{exact:true}).waitFor();
    await page.keyboard.press('Escape');
    await picker.waitFor({state:'hidden'});
  }
  await page.locator('[data-review-op="compare"]').click();
  for(const point of ['1','2','3']) {
    const answer=fixture.answers.find(a=>a.point_id===point);
    assert.ok(answer);
    const originalBytes=Buffer.byteLength(answer.comment);
    assert.equal(originalBytes,point==='3'?46:4096);
    await page.locator(`[data-cell-point="${point}"][data-cell-run="${fixture.runId}"]`).click();
    const contribution=page.locator('.review-comparison-answer').filter({has:page.locator(`[data-review-op="finding:${answer.id}"]`)});
    assert.ok((await contribution.textContent()).includes(answer.comment),'entire original shown in comparison');
    if(!before && point==='3')await findingActions(contribution,'comparison');
    await contribution.getByRole('button',{name:'CREATE TASK FROM THIS FINDING',exact:true}).click();
    const prompt=page.getByRole('dialog').filter({has:page.locator('input')}).last();
    await prompt.locator('input').fill(`Finding point ${point}`);
    const promptText=await prompt.textContent();
    if(point!=='3' && !before) assert.match(promptText,/excerpt|shorten|4096/i,'prompt explicitly discloses excerpt');
    if(point==='1')await variants('finding-prompt',prompt.locator('.nrc-dialog-message'));
    const start=sent.length, ack=received.length;
    await prompt.getByRole('button',{name:'Create',exact:true}).click();
    await page.locator('.nrc-dialog-input').waitFor({state:'detached'});
    await page.waitForFunction(({before,point,id}) => {
      const status=document.querySelector('[data-comparison-status]')?.textContent || '';
      return before && point!=='3' ? /exceeds.*4096/i.test(status) : status.includes(`CREATED AND LINKED TO ANSWER #${id}`);
    },{before,point,id:answer.id});
    const status=await page.locator('[data-comparison-status]').textContent();
    const packet=sent.slice(start).find(b=>b.readUInt16BE(0)===20);
    if(before && point!=='3') {
      assert.equal(packet,undefined,'baseline refuses over-limit generated task');
      assert.match(status,/4096|description|exceeds/i);
      results.push({point,originalBytes,outcome:'REPRODUCED: no task packet',status});
      await page.locator('[data-comparison-status]').scrollIntoViewIfNeeded();
      await screenshot(`finding-${point}-failure`);
      continue;
    }
    assert.ok(packet,'real create-task packet emitted');
    let offset=10;
    const string=()=>{const n=packet.readUInt16BE(offset);offset+=2;const s=new TextDecoder('utf-8',{fatal:true}).decode(packet.subarray(offset,offset+n));offset+=n;return s};
    assert.equal(string(),`Finding point ${point}`);
    const description=string();
    assert.ok(Buffer.byteLength(description)<=4096,'UTF-8 description bounded');
    assert.ok(description.includes(`Answer asset #${answer.id}`));
    if(point==='3')assert.ok(description.includes(answer.comment),'short comment complete');
    else assert.match(description,/full.*(?:answer|original)|(?:answer|original).*full/i,'clear full-original marker');
    assert.match(status,new RegExp(`CREATED AND LINKED TO ANSWER #${answer.id}`));
    const created=received.slice(ack).find(b=>b.readUInt16BE(0)===130);
    assert.ok(created,'server acknowledged actual task');
    const taskId=created.readBigUInt64BE(2).toString();
    const edge=received.slice(ack).find(b=>b.readUInt16BE(0)===150 && b.readBigUInt64BE(20).toString()===answer.id);
    assert.ok(edge,'server acknowledged edge from concrete answer');
    assert.equal(edge.readUInt16BE(18),1);
    assert.equal(edge.readUInt16BE(28),2);
    assert.equal(edge.readBigUInt64BE(30).toString(),taskId);
    assert.equal(edge.readUInt16BE(38),2,'RelatedTo');
    results.push({point,originalBytes,descriptionBytes:Buffer.byteLength(description),taskId,answerId:answer.id,outcome:'created and linked'});
  }
  // Start each navigation path fresh; public register and relationship controls only.
  await boot();
  await page.locator('#ticketsBtn').click();
  await page.locator(`[data-ticket="${fixture.ticketId}"]`).click();
  const formLink=page.locator(`button[data-work-id="${fixture.formId}"]`);
  await follow(formLink);
  if(!before)await page.locator('#reviewEditor [data-review-op="compare"]').waitFor();
  const formOpened=await page.locator('#reviewEditor').isVisible();
  assert.equal(formOpened,!before,'ticket relationship opens ReviewForm, never generic asset editor');
  results.push({navigation:'ticket → ReviewForm',formOpened});
  await screenshot('ticket-form-navigation');
  await boot();
  if(!await page.locator('#kanbanPanel').isVisible())await page.locator('#tasksBtn').click();
  await page.locator('[data-task-grouping="flat"]').click();
  await page.locator(`#taskListBody [data-task-id="${fixture.taskId}"] .col-id`).click();
  const answer=fixture.answers.find(a=>a.point_id==='1');
  await follow(page.locator(`button[data-target-id="${answer.id}"]`));
  if(!before)await page.locator(`[data-review-answer="${answer.id}"]`).waitFor();
  const answerOpened=await page.locator('#reviewEditor').isVisible();
  assert.equal(answerOpened,!before,'task relationship opens ReviewAnswer as review run');
  results.push({navigation:'task → ReviewAnswer',answerOpened});
  if(!before) {
    const selected=page.locator(`[data-review-answer="${answer.id}"].review-answer-selected`);
    assert.equal(await selected.count(),1,'one concrete contribution selected by stable answer ID');
    assert.equal(await page.locator('.review-answer-selected').count(),1,'same-name answer is not selected');
    assert.ok((await selected.locator('strong').textContent()).includes(`#${fixture.participantId}`));
    assert.ok((await selected.textContent()).includes(answer.comment));
    assert.ok(!(await selected.textContent()).includes('WRONG SAME-NAME CONTRIBUTION'));
    assert.equal(await selected.evaluate(el=>el===document.activeElement || el.contains(document.activeElement)),true,'selected answer focused');
    assert.match(await page.locator('#reviewEditor').textContent(),/Customer Alpha/);
    await findingActions(selected,'record');
    await variants('selected-contribution',selected.locator('strong'));
  } else await screenshot('task-answer-navigation-failure');
  await boot();
  if(!await page.locator('#kanbanPanel').isVisible())await page.locator('#tasksBtn').click();
  await page.locator('[data-task-grouping="flat"]').click();
  await page.locator(`#taskListBody [data-task-id="${fixture.taskId}"] .col-id`).click();
  await follow(page.locator(`button[data-target-id="${fixture.noteId}"]`));
  await page.getByText('Original note control body',{exact:false}).first().waitFor();
  results.push({navigation:'task → Note',outcome:'original note rendered'});
  if(!before) {
    // A separate, small synthetic review for the released Inspector layout.
    await boot();await page.locator('#reviewsBtn').click();await page.locator('#reviewNew').click();
    const editor=page.locator('#reviewEditor'), op=verb=>editor.locator(`[data-review-op="${verb}"]`);
    const confirm=()=>page.getByRole('dialog').last().getByRole('button',{name:'Confirm',exact:true}).click();
    const prompt=async (value,submit='Create')=>{
      const dialog=page.getByRole('dialog').last();await dialog.locator('input').fill(value);
      await dialog.getByRole('button',{name:submit,exact:true}).click();
    };
    assert.equal(await op('delete-draft').count(),0);
    await editor.locator('[name="title"]').fill('Customer portal acceptance');
    await editor.locator('[name="build"]').fill('2.8');
    await editor.locator('[name="environment"]').fill('Staging');
    for(const [index,question] of ['Can customers view their profile?','Do ticket search and filters work?','Can customers read the message timeline?','Can staff save an acceptance result?'].entries()) {
      await op('add').click();
      const point=editor.locator('fieldset').last();
      await point.locator('[name="question"]').fill(question);
      if(index===0) {
        await point.locator('[name="instruction"]').fill('Sign in with a test account. Open My profile and verify the name, email address and organization.');
        await point.locator('[name="expected"]').fill('The profile shows the correct account details.');
      }
    }
    await op('save').click();await op('release').click();await confirm();
    const definitions=editor.locator('.review-form-points');
    await definitions.waitFor();
    assert.equal(await op('delete-draft').count(),0);
    const lifecycleId=await page.evaluate(()=>String(NRCInspector.current().id));
    const lifecycleRow=page.locator(`tr[data-review="${lifecycleId}"]`);
    const captureLifecycle=async name=>{
      const action=op(name==='archived'?'restore':'unrelease');
      for(const [width,theme] of [[1440,'white'],[390,'dark']]) {
        await page.setViewportSize({width,height:900});
        if(width===390)await page.evaluate(()=>NRCInspector.openEntity(NRCInspector.current()));
        await page.evaluate(theme=>setTheme(theme,false),theme);
        await action.scrollIntoViewIfNeeded();
        assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
        await screenshot(`lifecycle-${name}-${theme}`);
      }
      await page.setViewportSize({width:1440,height:1000});
      await action.waitFor();
    };
    await captureLifecycle('released');
    const firstRelease=await page.evaluate(id=>NRCReviews.request('get',{form_id:id}).then(p=>p.form.released_at),lifecycleId);
    const lifecycleDialog=page.getByRole('dialog').last();
    await op('unrelease').click();
    await lifecycleDialog.getByRole('button',{name:'Cancel',exact:true}).click();
    await op('unrelease').click();
    await lifecycleDialog.getByRole('button',{name:'Withdraw release',exact:true}).click();
    await editor.locator('[name="build"]').fill('2.8.1');
    assert.equal(await page.evaluate(()=>String(NRCInspector.current().id)),lifecycleId);
    await op('save').click();await op('release').click();await confirm();
    const newRelease=await page.evaluate(id=>NRCReviews.request('get',{form_id:id}).then(p=>p.form.released_at),lifecycleId);
    assert.notEqual(firstRelease,newRelease);
    const createRun=(token)=>page.evaluate(({id,token})=>NRCReviews.request('run_create',{form_id:id,if_released_at:token,label:'Another run',kind:'qa'}),{id:lifecycleId,token});
    await assert.rejects(createRun(firstRelease),/CONFLICT/);
    await assert.rejects(createRun(undefined),/CONFLICT/);
    const refresh=page.locator('#reviewReload');
    assert.equal(await refresh.evaluate(el=>el.offsetHeight),await page.locator('#reviewClose').evaluate(el=>el.offsetHeight));
    await definitions.locator('summary').click();assert.equal(await definitions.getAttribute('open'),'');
    await definitions.locator('summary').click();
    await op('customer').click();await prompt('Customer QA');
    const checks=editor.locator('[data-review-check]');
    const selfAssign=editor.getByRole('button',{name:'ASSIGN MYSELF',exact:true});
    await editor.getByText('Only assigned staff can save answers here.',{exact:true}).waitFor();
    assert.equal(await selfAssign.count(),0);assert.equal(await editor.locator('[data-answer]').count(),0);
    assert.equal(await op('close').isDisabled(),true);
    const access=editor.locator('#reviewAccessToggle');await access.click();
    for(const verb of ['participant','portal-participant','invite','revoke'])assert.equal(await op(verb).isVisible(),true);
    await page.route('**/api/users/identities',route=>route.fulfill({json:{alice:'Alex Example','sam@example.test':'Sam Example'}}));
    await op('participant').click();
    const accountPicker=page.getByRole('dialog').last();
    await accountPicker.getByLabel('ACCOUNT').selectOption({label:'Sam Example · sam@example.test'});
    await screenshot('staff-account-picker');
    const beforePickerViewport=page.viewportSize();
    const beforePickerTheme=await page.locator('html').getAttribute('data-theme');
    await page.setViewportSize({width:390,height:844});
    await page.evaluate(()=>document.documentElement.dataset.theme='matte-black');
    await screenshot('staff-account-picker-mobile-dark');
    await page.setViewportSize(beforePickerViewport);
    await page.evaluate(theme=>{
      if(theme===null)delete document.documentElement.dataset.theme;
      else document.documentElement.dataset.theme=theme;
    },beforePickerTheme);
    await accountPicker.getByRole('button',{name:'Continue',exact:true}).click();
    await accountPicker.getByRole('button',{name:'Cancel',exact:true}).click();
    await editor.getByText('STAFF PARTICIPANT ASSIGNED',{exact:true}).waitFor();
    const assigned=await page.evaluate(id=>NRCReviews.request('run_get',{run_id:id}),await page.locator('#reviewRunSelect').inputValue());
    assert.ok(assigned.run.participants.some(person=>person.identity==='sam@example.test' && person.name==='Sam Example' && !person.can_close));
    await access.click();
    const visualOutput=path.resolve('.amp/in/artifacts/review-concept-b');
    await fs.mkdir(visualOutput,{recursive:true});
    const desktopWidth=await page.locator('#inspector').evaluate(el=>el.clientWidth);
    const separator=page.getByRole('separator',{name:'Resize Inspector'});
    for(let i=0;i<Math.max(0,Math.ceil((690-desktopWidth)/16));i++)await separator.press('ArrowLeft');
    const capture=async (name,focus=null)=>{
      await editor.evaluate(el=>{
        for(let node=el;node;node=node.parentElement)node.scrollTop=0;
        document.activeElement?.blur();
      });
      if(focus)await focus.scrollIntoViewIfNeeded();
      await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
      assert.equal(await editor.locator('table').evaluate(el=>el.scrollWidth<=el.clientWidth+1),true,'results do not overflow');
      assert.equal(await editor.locator('.review-run-summary').evaluate(el=>el.scrollWidth<=el.clientWidth+1),true,'run summary does not overflow');
      await page.screenshot({path:path.join(visualOutput,`${name}.png`)});
    };
    const teamProgress=editor.getByRole('list',{name:'Team progress'});
    await teamProgress.getByText('0/4 ANSWERED',{exact:true}).waitFor();
    for(const theme of ['white','dark']) {
      await page.evaluate(theme=>setTheme(theme,false),theme);
      await capture(`unassigned-desktop-${theme}`);
    }
    await checks.first().press('ArrowDown');
    assert.equal(await checks.nth(1).evaluate(el=>el===document.activeElement),true);
    await page.keyboard.press('Enter');
    assert.equal(await checks.nth(1).getAttribute('aria-expanded'),'true');
    assert.equal(await checks.first().getAttribute('aria-expanded'),'false');
    await page.keyboard.press('Enter');
    assert.equal(await editor.locator('[data-review-check][aria-expanded="true"]').count(),0);
    assert.equal(await selfAssign.count(),0);
    await checks.first().press('Enter');
    await access.click();
    await op('participant').click();
    await accountPicker.getByLabel('ACCOUNT').selectOption({label:'Alex Example · alice'});
    await accountPicker.getByRole('button',{name:'Continue',exact:true}).click();
    await page.getByRole('dialog').last().getByRole('button',{name:'Cancel',exact:true}).click();
    const answerForm=editor.locator('[data-answer]');await answerForm.waitFor();
    assert.equal(await op('close').isDisabled(),true);
    await answerForm.locator('select').selectOption('yes');
    await answerForm.locator('textarea').fill('Name, email and organization match the test account.');
    await checks.nth(1).click();await checks.first().click();
    assert.match(await answerForm.locator('textarea').inputValue(),/match the test account/);
    await answerForm.getByRole('button',{name:'SAVE MY ANSWER'}).click();
    await editor.getByText('ANSWER SAVED',{exact:true}).waitFor();
    assert.match(await editor.locator('.review-check-row').first().innerText(),/PASSED\s+1/);
    await teamProgress.getByText('1/4 ANSWERED',{exact:true}).waitFor();
    assert.equal(await editor.locator('.review-run-track span').count(),4);
    assert.equal(await editor.locator('.review-run-track .is-answered').count(),1);
    await capture('run-summary-answered-desktop-dark');
    assert.equal(await op('unrelease').count(),0);
    await assert.rejects(page.evaluate(async id=>{
      const form=await NRCReviews.request('get',{form_id:id});
      return NRCReviews.request('unrelease',{form_id:id,if_revision:form.revision});
    },lifecycleId),/A run already exists/);
    const peer=await context.newPage();
    await peer.goto(`${url}/?fresh=${Date.now()}#workspace=${fixture.workspace}`);
    await peer.waitForFunction(()=>serverReady);
    await peer.locator('#reviewsBtn').click();
    const peerRow=peer.locator(`tr[data-review="${lifecycleId}"]`);
    await peerRow.waitFor();
    const reportId=await page.locator('#reviewRunSelect').inputValue();
    const readReport=()=>page.evaluate(id=>NRCReviews.request('run_get',{run_id:id}),reportId);
    const reportBefore=await readReport();
    await op('archive').click();
    await lifecycleDialog.getByRole('button',{name:'Archive',exact:true}).click();
    await lifecycleRow.waitFor({state:'detached'});
    assert.equal(await op('customer').count(),0);
    assert.match(await editor.locator('.review-check-row').first().innerText(),/PASSED\s+1/);
    const scope=page.locator('#reviewsScope');
    await scope.selectOption('archived');
    await lifecycleRow.getByText('ARCHIVED',{exact:true}).waitFor();
    await peerRow.waitFor({state:'detached'});
    await peer.locator('#reviewsScope').selectOption('archived');
    await peerRow.getByText('ARCHIVED',{exact:true}).waitFor();
    assert.deepEqual(await readReport(),reportBefore,'archive must not change the existing report response');
    await assert.rejects(createRun(newRelease),/archived/);
    await assert.rejects(createRun(undefined),/CONFLICT/);
    await captureLifecycle('archived');
    await op('restore').click();
    await lifecycleRow.waitFor({state:'detached'});
    await peerRow.waitFor({state:'detached'});
    await peer.close();
    await scope.selectOption('current');
    await lifecycleRow.getByText('RELEASED',{exact:true}).waitFor();
    assert.equal((await createRun(newRelease)).status,'ok');
    await capture('assigned-desktop-dark');
    const syntheticId=(await page.locator('#inspectorHeader .identity-reference').innerText()).match(/#(\d+)/)[1];
    const syntheticRun=await page.locator('#reviewRunSelect').inputValue();
    await page.setViewportSize({width:390,height:844});
    await boot();
    await page.locator('#reviewsBtn').evaluate(button=>button.click());
    await page.locator(`tr[data-review="${syntheticId}"] td`).last().click();
    await page.locator('#reviewRunSelect').selectOption(syntheticRun);
    await answerForm.waitFor();
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    assert.equal(await answerForm.locator('textarea').evaluate(el=>getComputedStyle(el).fontSize),'16px');
    for(const theme of ['white','dark']) {
      await page.evaluate(theme=>setTheme(theme,false),theme);
      await capture(`assigned-narrow-${theme}`);
    }
    await capture('assigned-narrow-dark-answer',answerForm.getByRole('button',{name:'SAVE MY ANSWER'}));
    await op('copy').click();
    const deleteDraft=op('delete-draft');
    await deleteDraft.waitFor();
    const draftId=await page.evaluate(()=>String(NRCInspector.current().id));
    const dialog=page.getByRole('dialog').last();
    for(const theme of ['white','dark']) {
      await page.evaluate(theme=>setTheme(theme,false),theme);
      await deleteDraft.scrollIntoViewIfNeeded();
      await page.screenshot({path:path.join(visualOutput,`delete-draft-narrow-${theme}.png`)});
    }
    await page.setViewportSize({width:1440,height:1000});
    for(const theme of ['white','dark']) {
      await page.evaluate(theme=>setTheme(theme,false),theme);
      await deleteDraft.click();
      await dialog.getByRole('button',{name:'Delete draft',exact:true}).waitFor();
      await page.screenshot({path:path.join(visualOutput,`delete-draft-dialog-${theme}.png`)});
      await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
      assert.equal(await page.evaluate(()=>String(NRCInspector.current().id)),draftId);
    }
    await deleteDraft.click();
    await dialog.getByRole('button',{name:'Delete draft',exact:true}).click();
    await editor.waitFor({state:'hidden'});
    await page.locator(`[data-review="${draftId}"]`).waitFor({state:'detached'});
    await assert.rejects(page.evaluate(id=>NRCReviews.request('get',{form_id:id}),draftId),/not_found/);
    results.push({inspector:'Concept B',checks:4,keyboard:true,accessDisclosure:true,assignedViaStaffPicker:true,assignedAnswerSaved:true,narrowInputs:16});
  }
  assert.deepEqual(errors,[],'no page errors');
  await fs.writeFile(path.join(output,`${phase}-results.json`),JSON.stringify({phase,results,errors},null,2));
  console.log(JSON.stringify({phase,results,errors},null,2));
  await context.close();
} finally {await browser.close()}
