import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {decodeServerFrame}=require('./frames.js');
function frame(page, id=4294967294) {
  const bytes=new TextEncoder().encode(JSON.stringify(page)),view=new DataView(new ArrayBuffer(bytes.length+6));
  view.setUint16(0,182);view.setUint32(2,id);new Uint8Array(view.buffer,6).set(bytes);return view;
}
function client({prompts=[],canClose=false,reply=false}={}) {
  const packets=[];
  const messages=[];
  const opened=[];
  const context={window:{},document:{readyState:'loading',addEventListener(){},getElementById(){return null;}},TextEncoder,TextDecoder,DataView,Uint8Array,ArrayBuffer,setTimeout,clearTimeout,currentWorkspaceId:'reviews',myNickname:'Alice',serverReady:true,ws:{readyState:1},WebSocket:{OPEN:1},getRpcCorrelationId:()=>4294967294,sendPacket:buffer=>packets.push(new DataView(buffer))};
  context.window.NRCFrames={decodeServerFrame};
  context.MAX_TASK_DESCRIPTION_LENGTH=4096;
  context.window.NRCViewManager={setActiveView(){},getActiveView:()=> 'chat'};
  context.window.NRCInspector={current:()=>null,openEntity:async ref=>opened.push(ref)};
  context.window.NRCAssets={requestAllAssets:async()=>[]};
  context.window.NRCDialog={prompt:async message=>{messages.push(message);return prompts.shift() ?? null;},confirm:async()=>canClose,notify:message=>messages.push(message)};
  // Exercise private UI commands without adding a production test/debug API.
  const source=readFileSync(new URL('./reviews.js',import.meta.url),'utf8').replace('  window.NRCReviews={','  window.reviewTest={state,command,load,ticketDraft,comparisonMarkup,contributionMarkup,comparisonState,comparisonPoints,runStatus,setCurrent:fn=>current=fn,setRef:ref=>inspectorRef=ref};\n  window.NRCReviews={');
  vm.runInNewContext(source,context);
  if(reply)context.sendPacket=buffer=>{const packet=new DataView(buffer);packets.push(packet);queueMicrotask(()=>{
    assert.equal(packet.getUint16(0),77);
    context.window.NRCReviews.handlePage(frame(typeof reply==='function'?reply(packetBody(packet)):{status:'ok'}));
  });};
  return {api:context.window.NRCReviews,packets,messages,opened,context,...context.window.reviewTest};
}
test('review frame leading correlation and lossless decimal identities; changed invalidation',()=>{
  const page={status:'ok',form_id:'9007199254740999',revision:'1790000000000000001'};
  assert.deepEqual(decodeServerFrame(frame(page)),{opcode:182,kind:'review',correlationId:4294967294,page});
  assert.equal(decodeServerFrame(frame({status:'changed',run:{id:'42'}})).page.status,'changed');
  assert.throws(()=>decodeServerFrame(frame({status:'unknown'})),/Invalid review status/);
  const truncated=new DataView(new ArrayBuffer(5));truncated.setUint16(0,182);
  assert.throws(()=>decodeServerFrame(truncated),/frame/);
});
test('review RPC uses trailing correlation and routes conflict/error without retry',async()=>{
  const {api,packets}=client();
  const promise=api.request('close',{run_id:'9007199254740999',if_revision:'1790000000000000001',decision:'completed'});
  const view=packets[0];assert.equal(view.getUint16(0),77);assert.equal(view.getUint32(view.byteLength-4),4294967294);
  const request=JSON.parse(new TextDecoder().decode(new Uint8Array(view.buffer,2,view.byteLength-6)));assert.equal(request.run_id,'9007199254740999');
  api.handlePage(frame({status:'conflict'}));await assert.rejects(promise,/CONFLICT/);assert.equal(packets.length,1);
  const next=api.request('get',{form_id:'1'});assert.equal(api.handleError(4294967294,'forbidden'),true);await assert.rejects(next,/forbidden/);
  assert.equal(api.handleError(4294967294,'late'),false);
});
test('team progress counts points, retains every contribution and marks disagreement',()=>{
  const {api}=client();const p=api.progress({points:[{id:'1'},{id:'2'},{id:'3'}]},{answers:[{point_id:'1',result:'yes'},{point_id:'1',result:'no'},{point_id:'2',result:'unable'}]});
  assert.equal(p.answered,2);assert.equal(p.open,1);assert.equal(p.conflicts,1);assert.equal(p.failed,2);assert.equal(p.points[0].answers.length,2);
});
test('disconnect rejects pending writes instead of replaying unknown outcomes',async()=>{
  const {api,packets}=client();const pending=api.request('create',{form:{}});api.disconnect();await assert.rejects(pending,/outcome may be unknown/);assert.equal(packets.length,1);
});
test('reconnect preserves the canonical draft and discard guard; refresh requires a confirmed server read',async()=>{
  const saved={version:1,title:'Saved title',build:'42',environment:'QA',released_at:'',points:[{id:'9',question:'Saved question'}]};
  const c=client({reply:q=>q.op==='get'?{status:'ok',form:saved,revision:'102'}:{status:'ok',runs:[]}});
  c.api.sessionStarted();c.setCurrent(()=>true);
  c.state.id='77';c.state.revision='101';c.state.form={...saved,title:'Unsaved ü title'};c.state.dirty=true;
  c.context.serverReady=false;c.context.ws.readyState=3;c.api.disconnect();
  assert.equal(c.state.id,'77');assert.equal(c.state.form.title,'Unsaved ü title');assert.equal(c.state.dirty,true);
  await c.command('save');assert.equal(c.packets.length,0);
  c.context.serverReady=true;c.context.ws.readyState=1;c.api.sessionStarted();
  assert.equal(c.state.id,'77');assert.equal(c.state.revision,'101');assert.equal(c.state.form.title,'Unsaved ü title');
  assert.equal(await c.api.confirmDiscardEdits(),false);
  await c.command('reload');assert.equal(c.packets.length,0);assert.equal(c.state.dirty,true);
  c.context.window.NRCDialog.confirm=async()=>true;await c.command('reload');
  assert.deepEqual(c.packets.map(p=>packetBody(p).op),['get','run_list']);assert.equal(c.state.form.title,'Saved title');
  assert.equal(c.state.revision,'102');assert.equal(c.state.dirty,false);assert.equal(c.state.notice,'LATEST SERVER STATE');
  c.state.id='';await c.command('reload');assert.notEqual(c.state.notice,'LATEST SERVER STATE');
});
test('a different authenticated session does not inherit a reconnect draft or retest context',()=>{
  const c=client();c.api.sessionStarted();
  Object.assign(c.state,{id:'77',revision:'101',form:{title:'Private draft'},dirty:true,ticket:'9',answerId:'8',predecessor:{id:'81'}});
  c.context.serverReady=false;c.api.disconnect();c.context.currentWorkspaceId='other-workspace';c.context.serverReady=true;c.api.sessionStarted();
  assert.equal(c.state.id,'');assert.equal(c.state.revision,'');assert.equal(c.state.form.title,'');assert.equal(c.state.dirty,false);
  assert.equal(c.state.ticket,'');assert.equal(c.state.answerId,'');assert.equal(c.state.predecessor,null);
});
const packetBody=view=>JSON.parse(new TextDecoder().decode(new Uint8Array(view.buffer,2,view.byteLength-6)));
test('staff can assign a portal account from a later review page without the admin RPC',async()=>{
  const c=client({canClose:true,reply:q=>q.op!=='participant_accounts'?{status:'ok'}:q.cursor?{status:'ok',cursor:'11',accounts:[{login:'customer',name:'Customer',requester:'customer@example.test'}]}:
    {status:'ok',has_more:true,cursor:'10',accounts:[{login:'other',name:'Another contact',requester:'other@example.test'}]}});
  const buttons=[], options=[];
  c.context.Option=function(label,value){Object.assign(this,{label,value});};
  c.context.document.createElement=tag=>{
    const el={append(){},add(option){options.push(option);this.value=option.value;}};
    if(tag==='button')buttons.push(el);
    return el;
  };
  c.context.NRCModal={create:()=>({actions:{before(){},append(){}},close(){},show(){buttons.find(b=>b.textContent==='Continue').onclick();}})};
  c.state.run={id:'41'};c.setCurrent(()=>true);
  await c.command('portal-participant');
  assert.deepEqual(options.map(o=>o.label),['Another contact · other','Customer · customer']);
  assert.deepEqual(c.packets.slice(0,2).map(packetBody),[{op:'participant_accounts',run_id:'41',cursor:''},{op:'participant_accounts',run_id:'41',cursor:'10'}]);
  assert.deepEqual(packetBody(c.packets[2]),{op:'participant_add',run_id:'41',source:'portal',identity:'customer@example.test',name:'Customer',can_close:true});
});
test('an unavailable account directory never sends an assignment',async()=>{
  const c=client({reply:()=>({status:'forbidden'})});c.state.run={id:'41'};c.setCurrent(()=>true);
  await c.command('portal-participant');
  assert.deepEqual(c.packets.map(p=>packetBody(p).op),['participant_accounts']);
  assert.match(c.state.notice,/forbidden/);
});
test('guest invitation uses the configured origin without prompting for a hostname',async()=>{
  const c=client({prompts:['2099-01-01T00:00:00Z'],reply:()=>({status:'ok',invite_id:'73',token:'a'.repeat(64)})});
  c.context.window.NRCDateTime={pick:async options=>{assert.equal(options.futureOnly,true);return Date.parse('2099-01-01T00:00:00Z');}};
  c.context.URL=URL;c.context.fetch=async path=>{assert.equal(path,'/api/features');return {ok:true,json:async()=>({review_portal_origin:'https://tickets.example.test'})};};
  c.state.run={id:'41'};c.setCurrent(()=>true);await c.command('invite');
  assert.equal(c.messages.length,0);
  assert.match(c.state.notice,/https:\/\/tickets\.example\.test\/abnahmen\/einladung#/);
  assert.equal(packetBody(c.packets[0]).op,'invite');
  assert.equal(packetBody(c.packets[0]).expires_at,String(BigInt(Date.parse('2099-01-01T00:00:00Z'))*1000000n));
});
test('revoke remains a valid command for completed runs',async()=>{
  const c=client({canClose:true,reply:true});c.state.run={id:'41',decision:'completed'};c.setCurrent(()=>true);await c.command('revoke:73');
  assert.deepEqual(packetBody(c.packets[0]),{op:'revoke',run_id:'41',invite_id:'73'});assert.equal(c.state.notice,'GUEST LINK #73 REVOKED');
});
test('ticket draft copies editable bounded UTF-8 title and body without NULs',()=>{
  const c=client();const draft=c.ticketDraft({title:'😀'.repeat(300),body:'ü\0'.repeat(2000)});
  assert.equal(new TextEncoder().encode(draft.title).length,256);
  assert.equal(new TextEncoder().encode(draft.points[0].question).length,1024);
  assert.equal(new TextEncoder().encode(draft.points[0].instruction).length,2048);
  assert.equal(draft.points[0].instruction.includes('\0'),false);
  assert.equal(draft.points[0].id,'1');assert.equal(draft.released_at,'');
  assert.equal(c.ticketDraft({title:'Ticket title',body:'Original request'}).points[0].instruction,'Original request');
});
test('run summary state uses answered points even when no answer details were fetched',()=>{
  const c=client();assert.equal(c.runStatus({answered_points:2}),'ACTIVE');
  assert.equal(c.runStatus({answered_points:0,answers:[{}]}),'NOT STARTED');
  assert.equal(c.runStatus({answered_points:2,decision:'accepted'}),'ACCEPTED');
});
test('both linked and unlinked ticket drafts retain the editable seed in the shared Inspector',async()=>{
  const seed={title:'Ticket title',body:'Original request'};
  for(const ticket of ['9007199254740999','']) {
    const c=client();await c.api.open('0',ticket,seed);
    assert.equal(c.opened[0].id,0n);assert.equal(c.opened[0].ticket,ticket);assert.equal(c.opened[0].seed,seed);
  }
});
test('paginated register loads summaries only; comparison explicitly fetches every run',async()=>{
  const c=client({reply:q=>q.op==='get'?{status:'ok',form:{points:[]},revision:'4'}:q.op==='run_list'?{status:'ok',runs:[{id:q.cursor?'12':'11'}],has_more:!q.cursor,cursor:'next'}:{status:'ok',run:{id:q.run_id,answers:[]}}});
  c.state.id='7';c.setCurrent(()=>true);await c.load();
  assert.deepEqual(c.packets.map(p=>packetBody(p).op),['get','run_list','run_list']);assert.equal(c.state.comparison,null);
  await c.command('compare');assert.deepEqual(c.packets.slice(3).map(p=>packetBody(p)),[{op:'run_get',run_id:'11'},{op:'run_get',run_id:'12'}]);
  assert.equal(c.state.comparison.length,2);await c.load();assert.equal(c.state.comparison,null);
});
test('failed comparison does not publish a partial team snapshot',async()=>{
  const c=client({reply:q=>q.run_id==='11'?{status:'ok',run:{id:'11'}}:{status:'forbidden'}});
  c.state.id='7';c.state.runs=[{id:'11'},{id:'12'}];c.setCurrent(()=>true);await c.command('compare');
  assert.equal(c.state.comparison,null);assert.match(c.state.notice,/forbidden/);assert.equal(c.packets.length,2);
});
test('comparison includes all contributions, open points, conflicts and closing decision with escaping',()=>{
  const c=client(),point={id:'1',question:'<Question>'},run={id:'11',label:'Team A',kind:'qa',answered_points:1,decision:'completed',closed_name:'Closer',closed_source:'staff',comment:'Reviewed',participants:[{id:'21',source:'guest',can_close:false},{id:'22',source:'staff',can_close:true}],answers:[{id:'81',point_id:'1',participant_id:'21',name:'Alex',result:'yes',comment:'Works'},{id:'82',point_id:'1',participant_id:'22',name:'Alex',result:'no',comment:'<broken>'}]};
  const html=c.comparisonMarkup({points:[point,{id:'2',question:'Other'}]},[run])+c.contributionMarkup(point,run);
  for(const expected of ['CONFLICTING','OPEN','COMPLETED','Closer','Reviewed','Alex · #21','Alex · #22','Works','&lt;broken&gt;','&lt;Question&gt;','tabindex="0"'])assert.ok(html.includes(expected),expected);
  for(const expected of ['GUEST · SELF-DECLARED NAME · CONTRIBUTE ONLY','STAFF · VERIFIED ACCOUNT · MAY CLOSE','ANSWER ASSET #81','data-finding-references="82"'])assert.ok(html.includes(expected),expected);
  assert.equal(html.includes('<broken>'),false);
});
test('sections group nonadjacent points without renumbering and search/filter match any team',()=>{
  const c=client(),form={points:[{id:'9',question:'Invoice',section:'Billing'},{id:'2',question:'Legacy'},{id:'5',question:'Tax',section:'Billing'}]},runs=[{id:'11',kind:'qa',answers:[{point_id:'5',result:'no'}]}];
  const html=c.comparisonMarkup(form,runs);
  assert.equal(html.split('>Billing</th>').length-1,1);assert.ok(html.indexOf('#5 · Tax')<html.indexOf('#2 · Legacy'));assert.match(html,/UNSECTIONED/);
  // The keyboard handler consumes comparisonPoints too: interleaved author order
  // 9,2,5 must navigate the actual grouped rows 9,5,2, not numeric/source order.
  const keyboardOrder=Array.from(c.comparisonPoints(form,runs),p=>p.id);
  const renderedOrder=[...html.matchAll(/data-cell-point="([^"]+)"/g)].map(m=>m[1]);
  assert.deepEqual(keyboardOrder,['9','5','2']);assert.deepEqual(renderedOrder,keyboardOrder);
  c.comparisonState.query='billing';assert.equal(c.comparisonPoints(form,runs).length,2);
  c.comparisonState.filter='NO';assert.equal(c.comparisonPoints(form,runs)[0].id,'5');
  c.comparisonState.query='missing';assert.match(c.comparisonMarkup(form,runs),/NO MATCHING POINTS/);
});
test('section byte limit accepts absent/empty and rejects multibyte overflow before sending',async()=>{
  for(const section of [undefined,'','😀'.repeat(64),'😀'.repeat(65)]){
    const c=client({reply:{}});c.state.form.points=[{id:'1',section}];await c.command('save');
    if(section?.length>128){assert.equal(c.packets.length,0);assert.match(c.state.notice,/256 UTF-8/);}else assert.equal(c.packets.length,1);
  }
});
test('section and stable identity move together; released points cannot be reordered',async()=>{
  const c=client();c.state.form.points=[{id:'9',section:'Billing'},{id:'2',section:'Other'}];await c.command('down:9');assert.equal(c.state.form.points[1].section,'Billing');assert.equal(c.state.form.points[1].id,'9');
  c.state.form.released_at='released';await c.command('up:9');assert.equal(c.state.form.points[1].id,'9');
});
test('finding task copies the selected concrete provenance and links the answer asset',async()=>{
  const c=client({prompts:['Fix tax']});let task,edge;
  c.context.window.NRCTasks={sendCreateTask(...args){task=args;args.at(-1).onSuccess({task:{id:'9007199254740999'}});return true;}};
  c.context.window.NRCEdges={RelationType:{RelatedTo:1},sendCreateEdge(...args){edge=args;args.at(-1).onSuccess({});return true;}};
  c.state.id='77';c.state.form={title:'Release',build:'42',points:[{id:'19',question:'Tax in PDF'}]};c.state.comparison=[{id:'81',label:'Customer A',kind:'customer',answers:[{id:'91',point_id:'19',participant_id:'21',name:'Alex',result:'no',comment:'Missing mobile tax line'}]}];
  await c.command('finding:91');for(const text of ['form #77','Run #81: Customer A','Point #19: Tax in PDF','Answer asset #91','Alex','Missing mobile tax line'])assert.ok(task[2].includes(text),text);
  assert.equal(edge[2],91n);assert.equal(edge[4],9007199254740999n);assert.match(c.state.notice,/CREATED AND LINKED/);
  task=null;await c.command('finding:missing');assert.equal(task,null);assert.match(c.state.notice,/concrete/);
});
test('finding task default title is UTF-8 bounded while description retains full question',async()=>{
  const c=client();const question='😀'.repeat(256);let task;
  c.context.window.NRCDialog.prompt=async(_message,options)=>options.initialValue;
  c.context.window.NRCTasks={sendCreateTask(...args){task=args;args.at(-1).onSuccess({task:{id:'99'}});return true;}};
  c.context.window.NRCEdges={RelationType:{RelatedTo:1},sendCreateEdge(...args){args.at(-1).onSuccess({});return true;}};
  c.state.id='77';c.state.form={title:'Release',build:'42',points:[{id:'19',question}]};c.state.comparison=[{id:'81',label:'Customer A',kind:'customer',answers:[{id:'91',point_id:'19',participant_id:'21',name:'Alex',result:'no',comment:'Broken'}]}];
  await c.command('finding:91');assert.equal(new TextEncoder().encode(task[1]).length,256);assert.equal(task[1],'😀'.repeat(64));assert.ok(task[2].includes(question));
});

test('4096-byte findings create UTF-8-safe task excerpts through the real task encoder and retain originals',async()=>{
  const source=readFileSync(new URL('./tasks.js',import.meta.url),'utf8');
  const encoder=source.slice(source.indexOf('function sendCreateTask('),source.indexOf('// Sentinel values for update fields:'));
  for(const comment of ['x'.repeat(4096),'ü😀'.repeat(682)+'äö']) {
    assert.equal(new TextEncoder().encode(comment).length,4096);
    const c=client({prompts:['Repair mobile tax line']});let edge;
    vm.runInNewContext(`const MAX_TASK_TITLE_LENGTH=256, MAX_TASK_DESCRIPTION_LENGTH=4096; const pendingTaskRpcs=new Map(); const TaskStatus={Backlog:0}; const Opcode={C_CreateTask:20}; ${encoder}; window.NRCTasks={sendCreateTask}; window.taskReply=id=>pendingTaskRpcs.get(id).onSuccess({task:{id:'99'}});`,c.context);
    c.context.sendPacket=(buffer,id)=>{c.packets.push(new DataView(buffer));queueMicrotask(()=>c.context.window.taskReply(id));};
    c.context.window.NRCEdges={RelationType:{RelatedTo:2},sendCreateEdge(...args){edge=args;args.at(-1).onSuccess({});return true;}};
    c.state.id='77';c.state.form={title:'Invoice acceptance',build:'2026.11',points:[{id:'19',question:'Tax line in exported PDF'}]};
    const answer={id:'91',point_id:'19',participant_id:'21',name:'Alex',result:'no',comment};
    c.state.comparison=[{id:'81',label:'Customer A',kind:'customer',answers:[answer]}];
    await c.command('finding:91');
    assert.equal(c.packets.length,1,c.state.notice);
    const packet=c.packets[0],start=14+packet.getUint16(10),length=packet.getUint16(start-2);
    const description=new TextDecoder('utf-8',{fatal:true}).decode(new Uint8Array(packet.buffer,start,length));
    assert.ok(length<=4096);assert.match(description,/EXCERPT/);assert.match(description,/Answer asset #91/);
    assert.match(description,/Point #19: Tax line in exported PDF/);assert.match(description,/Result: no/);
    assert.ok(comment.startsWith(description.split('Comment: ')[1].split('\n\nEXCERPT')[0]));
    assert.match(c.messages[0],/excerpt/i);assert.equal(answer.comment,comment);
    assert.equal(edge[2],91n);assert.equal(edge[4],99n);assert.equal(edge[5],2);
  }
});

test('answer backlinks resolve the authoritative run and exact participant contribution, never a display name',async()=>{
  const c=client({reply:()=>({status:'ok',run:{id:'81',form_id:'77',answers:[{id:'90',name:'Alex',participant_id:'20'},{id:'91',name:'Alex',participant_id:'21'}]}})});
  c.context.window.NRCAssets={AssetType:{ReviewAnswer:19},requestAssetsByIds:async()=>[{assetType:19,preview:'{"run_id":"81"}'}]};
  await c.api.openAnswer(91n);
  assert.deepEqual(packetBody(c.packets[0]),{op:'run_get',run_id:'81'});
  assert.equal(c.opened[0].type,'review');assert.equal(c.opened[0].id,77n);
  assert.equal(c.opened[0].runId,'81');assert.equal(c.opened[0].answerId,'91');
  for(const reply of [{status:'forbidden'},{status:'ok',run:{id:'82',form_id:'78',answers:[{id:'92',name:'Alex'}]}}]) {
    const denied=client({reply:()=>reply});denied.context.window.NRCAssets=c.context.window.NRCAssets;
    assert.equal(await denied.api.openAnswer(91n),false);assert.equal(denied.opened.length,0);assert.equal(denied.messages.length,1);
  }
});

test('create and copy synchronize the same Inspector history reference and clear consumed context',async()=>{
  for(const operation of ['save','copy','retest']) {
    const form={version:1,title:'New build',build:'42',points:[]};
    const c=client({reply:()=>({status:'ok',form_id:'9007199254740999',revision:'2',form:{...form}})});
    const ref={type:'review',id:operation==='save'?0n:77n,seed:{title:'Ticket seed'},ticket:'8',runId:'81',answerId:'91'};
    c.setRef(ref);c.setCurrent(()=>true);c.state.id=operation==='save'?'':'77';c.state.form=form;
    c.state.run=operation==='save'?null:{id:'81',kind:'customer',label:'Customer A',answers:[{id:'91'}]};
    // Save from an unpersisted ticket draft consumes its link once.
    if(operation==='save') {
      c.state.ticket='8';
      c.context.window.NRCEdges={RelationType:{RelatedTo:2},sendCreateEdge(...args){args.at(-1).onSuccess({});return true;}};
    } else c.state.answerId='91';
    await c.command(operation);
    assert.equal(ref.id,9007199254740999n);assert.equal(c.state.id,String(ref.id));
    assert.equal(ref.seed,null);assert.equal(ref.ticket,'');assert.equal(ref.runId,null);assert.equal(ref.answerId,null);
    assert.equal(c.state.notice.includes('81'),operation==='retest');
    if(operation==='retest')assert.deepEqual({...ref.predecessor},{id:'81',label:'Customer A',kind:'customer'});
    else assert.ok(!ref.predecessor);
    await c.command('save');assert.equal(packetBody(c.packets.at(-1)).op,'update');
    assert.equal(packetBody(c.packets.at(-1)).form_id,'9007199254740999');
  }
});

test('Back remount restores retest lineage until a successful new run consumes it',async()=>{
  const predecessor={id:'81',label:'Customer A',kind:'customer'},ref={type:'review',id:77n,predecessor};
  let fail=true;
  const form={version:1,title:'Retest',build:'43',points:[]};
  const c=client({reply:q=>q.op==='get'?{status:'ok',form,revision:'3'}:q.op==='run_list'?{status:'ok',runs:[]}:q.op==='run_create' && fail?{status:'conflict'}:{status:'ok',run:{id:'82',form_id:'77',previous_run:'81'}}});
  c.context.document.createElement=()=>({querySelector:()=>null});
  c.context.document.getElementById=id=>id==='inspectorEntityHost'?{replaceChildren(){}}:null;
  await c.api.showInspector(ref,()=>false); // A remount initializes state even before its read completes.
  assert.equal(c.state.predecessor,predecessor);c.setCurrent(()=>true);
  await c.command('qa');assert.equal(ref.predecessor,predecessor,'failure must not consume lineage');
  fail=false;await c.command('qa');
  const request=packetBody(c.packets.findLast(p=>packetBody(p).op==='run_create'));
  assert.equal(request.previous_run,'81');assert.equal(request.kind,'customer');assert.equal(request.label,'Customer A');
  assert.equal(ref.predecessor,null);assert.equal(ref.runId,'82');assert.equal(ref.answerId,null);
});
