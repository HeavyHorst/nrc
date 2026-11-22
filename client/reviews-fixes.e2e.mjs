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
  await page.locator('[data-review-op="compare"]').click();
  for(const point of ['1','2','3']) {
    const answer=fixture.answers.find(a=>a.point_id===point);
    assert.ok(answer);
    const originalBytes=Buffer.byteLength(answer.comment);
    assert.equal(originalBytes,point==='3'?46:4096);
    await page.locator(`[data-cell-point="${point}"][data-cell-run="${fixture.runId}"]`).click();
    const contribution=page.locator('.review-comparison-answer').filter({has:page.locator(`[data-review-op="finding:${answer.id}"]`)});
    assert.ok((await contribution.textContent()).includes(answer.comment),'entire original shown in comparison');
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
    await variants('selected-contribution',selected.locator('strong'));
  } else await screenshot('task-answer-navigation-failure');
  await boot();
  if(!await page.locator('#kanbanPanel').isVisible())await page.locator('#tasksBtn').click();
  await page.locator('[data-task-grouping="flat"]').click();
  await page.locator(`#taskListBody [data-task-id="${fixture.taskId}"] .col-id`).click();
  await follow(page.locator(`button[data-target-id="${fixture.noteId}"]`));
  await page.getByText('Original note control body',{exact:false}).first().waitFor();
  results.push({navigation:'task → Note',outcome:'original note rendered'});
  assert.deepEqual(errors,[],'no page errors');
  await fs.writeFile(path.join(output,`${phase}-results.json`),JSON.stringify({phase,results,errors},null,2));
  console.log(JSON.stringify({phase,results,errors},null,2));
  await context.close();
} finally {await browser.close()}
