// Isolated real-control browser contract: no shared workspace or conference.
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {chromium} from 'playwright';
const root = new URL('./', import.meta.url).pathname;
const fixture = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/css/main.css"><link rel="stylesheet" href="/css/custom-select.css"></head><body style="overflow:auto"><main class="agenda-panel inspector" style="display:block;position:relative;width:min(100%,720px);height:auto;margin:auto"><header class="panel-header inspector-matrix-header"></header><div class="agenda-content"></div></main>
<script>
var myNickname='anna',serverReady=true; function userDirectory(){return ['anna','alex','rene'];}
var asset={assetId:42n,assetType:12,owner:'anna',payload:'',preview:JSON.stringify({version:2,title:'Weekly pilot review',start_at:'1792486800000000000',end_at:'1792489500000000000',timezone:'Europe/Berlin',repeat:'weekly',weekdays:[2,4],until:'2026-12-31',participants:['alex'],conference:'nrc',exceptions:[],description:'Review the pilot and agree next steps.',assignee:'anna',project:'NRC',url:''})};
window.NRCAssets={MAX_PAYLOAD_LENGTH:65535,AssetType:{Appointment:12},roomAssets:new Map([[0n,new Map([[42n,asset]])]]),sendUpdateAsset:(room,id,preview,payload,type,flags,options)=>{asset.preview=preview;window.saved=JSON.parse(preview);options.onSuccess({asset});return true;}};
window.NRCInspector={current:()=>window.ref,openEntity:ref=>{window.ref=ref;NRCAppointments.showInspector(ref);},close(){},back(){}};
window.NRCDialog={confirm:async()=>true};window.NRCCalls={available:()=>true,joinAppointment:async(id,at)=>{window.joined=[String(id),String(at)];if(window.failJoin)throw Error('Conference temporarily unavailable');return {url:'https://conference.example.invalid/join?ticket=fixture',expires_at:1900000000};}};
</script><script src="/custom-picker.js"></script><script src="/custom-select.js"></script><script src="/detail-ui.js"></script><script src="/appointments.js"></script><script>NRCInspector.openEntity({id:42n,roomId:0n,type:'appointment',occurrenceAt:1793095200000000000n,actualStartAt:1793095200000000000n,endAt:1793097900000000000n});</script></body></html>`;
const server = http.createServer(async(req,res)=>{
  const pathname = new URL(req.url,'http://fixture').pathname;
  if(pathname==='/'){res.setHeader('Content-Type','text/html');res.end(fixture);return;}
  const file=path.resolve(root,'.'+pathname);
  if(!file.startsWith(root)){res.writeHead(403).end();return;}
  try{res.setHeader('Content-Type',({'.js':'text/javascript','.css':'text/css'})[path.extname(file)]||'application/octet-stream');res.end(await readFile(file));}catch{res.writeHead(404).end();}
});
await new Promise(r=>server.listen(process.argv.includes('--serve')?8147:0,'127.0.0.1',r));
if(process.argv.includes('--serve')) console.log('Appointment fixture ready on port 8147');
else {
  const browser=await chromium.launch({headless:true});
  try {
    const page=await browser.newPage(); const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.evaluate(()=>{failJoin=true;});
    await page.click('button.schedule-primary');
    assert.match(await page.textContent('#appointmentValidationError'),/temporarily unavailable/);
    await page.evaluate(()=>{failJoin=false;});
    await page.click('button.schedule-primary');
    assert.equal(await page.locator('a.schedule-primary').getAttribute('target'),'_blank');
    assert.deepEqual(await page.evaluate(()=>joined),['42','1793095200000000000']);
    assert.equal(page.context().pages().length,1,'prepare never opens a popup');
    await page.click('#appointmentEdit');
    assert.equal(await page.inputValue('#appointmentScope'),'occurrence');
    assert.ok(await page.locator('#appointmentTitle').isDisabled());
    assert.ok(await page.locator('#appointmentTitle').isHidden(),'series-only controls are hidden in occurrence mode');
    assert.ok(await page.locator('#appointmentRepeat').isHidden());
    await page.click('[data-remove-person]');
    await page.fill('#appointmentStart','2026-10-27T11:30');
    await page.fill('#appointmentEnd','2026-10-27T12:15');
    await page.click('#appointmentSave');
    const saved=await page.evaluate(()=>saved);
    assert.deepEqual(saved.participants,['alex']);
    assert.deepEqual(saved.exceptions[0].participants,[]);
    assert.equal(saved.exceptions[0].at,'1793095200000000000');
    await page.click('#appointmentEdit');
    await page.selectOption('#appointmentScope','series');
    assert.ok(await page.locator('#appointmentTitle').isVisible());
    assert.ok(await page.locator('#appointmentCancelled').isHidden(),'cancellation must not imply cancelling the entire series');
    await page.selectOption('#appointmentPerson','rene');
    await page.click('#appointmentAddPerson');
    await page.click('#appointmentSave');
    assert.deepEqual(await page.evaluate(()=>saved.participants),['alex','rene']);
    await page.click('#appointmentEdit');
    await page.check('#appointmentCancelled');
    await page.click('#appointmentSave');
    assert.equal(await page.evaluate(()=>saved.exceptions[0].cancelled),true);
    assert.deepEqual(await page.evaluate(()=>saved.exceptions[0]),{at:'1793095200000000000',cancelled:true},'cancellation must not retain invalid time/participant overrides');
    assert.equal(await page.locator('button.schedule-primary').count(),0,'cancelled occurrences cannot prepare a conference');
    await page.evaluate(()=>{myNickname='reader';NRCInspector.openEntity({...ref,subview:'read'});});
    assert.ok(await page.locator('#appointmentEdit').isHidden());
    await page.evaluate(()=>{
      const data=JSON.parse(asset.preview);data.repeat='';data.exceptions=[];asset.preview=JSON.stringify(data);
      NRCInspector.openEntity({...ref,subview:'read'});
    });
    await page.click('button.schedule-primary');
    assert.deepEqual(await page.evaluate(()=>joined),['42','1792486800000000000'],'single appointments send their current start, never a stale occurrence ref');
    await page.evaluate(()=>{NRCCalls.available=()=>false;NRCInspector.openEntity({...ref,subview:'read'});});
    assert.ok(await page.locator('button.schedule-primary').isDisabled());
    await page.evaluate(()=>{myNickname='anna';NRCInspector.openEntity({...ref,subview:'edit'});});
    await page.selectOption('#appointmentRepeat','daily');
    await page.click('#appointmentSave');
    assert.deepEqual(await page.evaluate(()=>saved.weekdays),[],'weekly days do not survive switching recurrence mode');
    await page.reload();
    await page.click('#appointmentEdit');
    await page.fill('#appointmentStart','2026-10-27T11:15');
    await page.click('#appointmentSave');
    assert.equal(await page.evaluate(()=>saved.exceptions[0].end_at),'1793097900000000000','start-only edit must keep the displayed 11:45 end');
    assert.equal(await page.textContent('.schedule-hours'),'11:15 – 11:45');
    await page.click('#appointmentEdit');
    await page.selectOption('#appointmentScope','series');
    await page.check('#appointmentResetExceptions');
    await page.click('#appointmentSave');
    assert.equal(await page.textContent('.schedule-hours'),'11:00 – 11:45','clearing override ignores stale navigation timestamps');
    await page.evaluate(()=>NRCInspector.openEntity({...ref,actualStartAt:1793097000000000000n,endAt:1793100600000000000n}));
    assert.equal(await page.textContent('.schedule-hours'),'11:00 – 11:45','current asset determines effective times, not stale row data');
    await page.click('#appointmentEdit');
    await page.selectOption('#appointmentScope','series');
    await page.selectOption('#appointmentRepeat','');
    await page.fill('#appointmentStart','2026-03-29T01:30');
    await page.fill('#appointmentEnd','2026-03-29T02:30');
    const beforeGap=await page.evaluate(()=>asset.preview);
    await page.click('#appointmentSave');
    assert.match(await page.textContent('#appointmentValidationError'),/END.*(INVALID|EXIST)/);
    assert.equal(await page.evaluate(()=>asset.preview),beforeGap,'DST gap end sends no mutation');
    await page.fill('#appointmentEnd','');
    await page.click('#appointmentSave');
    assert.equal(await page.evaluate(()=>saved.end_at),'','explicitly empty end remains supported');
    assert.deepEqual(errors,[]);
    console.log('Appointment browser contracts passed: explicit prepare, occurrence identity, reschedule, remove/add participants, owner gating.');
  } finally {await browser.close();server.close();}
}
