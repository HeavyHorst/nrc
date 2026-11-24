// Independent review forms. Only C_Review writes domain state; references use edges.
(function () {
  const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const blank = () => ({version:1,title:'',build:'',environment:'',released_at:'',points:[]});
  const state = { forms:[], id:'', revision:'', form:blank(), runs:[], run:null, comparison:null, busy:false, dirty:false, notice:'', ticket:'', answerId:'' };
  const requests = new Map();
  let generation = 0, current = () => false;
  let session = null;
  let inspectorRef = null;
  let comparisonView = null;
  const comparisonState = {query:'',filter:'all',point:'',run:''};
  const recordView = {point:null,access:false,definitions:false,drafts:new Map()};
  const host = () => document.getElementById('reviewEditor');
  const connected = () => typeof serverReady !== 'undefined' && serverReady && ws?.readyState === WebSocket.OPEN;
  const write = send => new Promise((resolve,reject) => { if (!send({onSuccess:resolve,onError:e=>reject(Error(e?.message || 'Reference update failed'))})) reject(Error('Not connected')); });
  function request(op, fields = {}) {
    if (!connected()) return Promise.reject(Error('OFFLINE · reconnect first'));
    const id = getRpcCorrelationId(), data = new TextEncoder().encode(JSON.stringify({op,...fields}));
    const view = new DataView(new ArrayBuffer(data.length + 6));
    view.setUint16(0,77); view.setUint32(data.length+2,id); new Uint8Array(view.buffer,2,data.length).set(data);
    return new Promise((resolve,reject) => {
      const timer = setTimeout(() => { requests.delete(id); reject(Error('Outcome unknown · REFRESH before retrying')); },15000);
      requests.set(id,{resolve,reject,timer}); sendPacket(view.buffer,id);
    });
  }
  function settle(id, page, error) {
    const q = requests.get(id); if (!q) return false;
    clearTimeout(q.timer); requests.delete(id);
    if (error) q.reject(Error(error)); else if (page.status !== 'ok') q.reject(Error(({conflict:'CONFLICT · REFRESH to review latest state; no automatic overwrite',has_runs:'A run already exists · REFRESH before continuing',archived:'This form is archived · restore it before creating a run'})[page.status] || `Review command: ${page.status}`)); else q.resolve(page);
    return true;
  }
  function handlePage(view) {
    const d = window.NRCFrames.decodeServerFrame(view);
    if (d.page.status === 'changed') { if (state.run?.id === d.page.run?.id || state.comparison?.some(r=>r.id===d.page.run?.id)) status('RUN CHANGED · SNAPSHOT STALE · REFRESH before answering or closing'); return; }
    settle(d.correlationId,d.page);
  }
  async function chooseParticipant(source, runId) {
    const people=[];
    if(source==='portal') {
      let cursor='';
      do {
        const page=await request('participant_accounts',{run_id:runId,cursor});
        for(const account of page.accounts || [])people.push({identity:account.requester,name:account.name,login:account.login});
        if(!page.has_more)break;
        if(!page.cursor || page.cursor===cursor)throw Error('Portal account cursor did not advance');
        cursor=page.cursor;
      } while(cursor);
    } else {
      const response=await fetch('/api/users/identities',{credentials:'same-origin',cache:'no-store'});
      if(!response.ok)throw Error('Tailscale user directory unavailable');
      for(const [login,name] of Object.entries(await response.json()))people.push({identity:login,name:name || login,login});
    }
    if(!people.length)throw Error('No accounts available to assign');
    people.sort((a,b)=>a.name.localeCompare(b.name) || a.login.localeCompare(b.login));
    return new Promise(resolve=>{
      const modal=NRCModal.create({title:source==='portal'?'ASSIGN PORTAL ACCOUNT':'ASSIGN STAFF',onCancel:()=>resolve(null)});
      const label=document.createElement('label');label.className='detail-edit-field';label.textContent='ACCOUNT';
      const select=document.createElement('select');select.className='filter-select';label.append(select);modal.actions.before(label);
      for(const [i,person] of people.entries())select.add(new Option(person.name===person.login?person.name:`${person.name} · ${person.login}`,String(i)));
      const cancel=document.createElement('button');cancel.type='button';cancel.className='btn btn--ghost';cancel.textContent='Cancel';cancel.onclick=()=>modal.cancel();
      const submit=document.createElement('button');submit.type='button';submit.className='btn btn--primary';submit.textContent='Continue';submit.onclick=()=>{modal.close();resolve(people[Number(select.value)]);};
      modal.actions.append(cancel,submit);modal.show();
    });
  }
  function progress(form, run) {
    const points = form.points.map(point => {
      const answers = (run?.answers || []).filter(a=>a.point_id === point.id);
      return {...point,answers,open:!answers.length,conflict:new Set(answers.map(a=>a.result)).size>1,failed:answers.some(a=>a.result !== 'yes')};
    });
    return {points, answered:points.filter(p=>!p.open).length, open:points.filter(p=>p.open).length, conflicts:points.filter(p=>p.conflict).length, failed:points.filter(p=>p.failed).length};
  }
  function status(text, error=false) {
    state.notice=text;state.noticeError=error;
    const el=document.getElementById('reviewNotice');
    if(el){el.textContent=text;el.classList.toggle('review-notice-error',error);}
    const snapshot=comparisonView?.panel.querySelector('[data-comparison-status]');if(snapshot)snapshot.textContent=text;
  }
  async function action(fn) {
    if (state.busy) return;
    const focused = document.activeElement;
    const focusKey = focused?.closest('#reviewEditor, #inspectorHeader') ? {
      op: focused.dataset.reviewOp, point: focused.dataset.reviewCheck,
      name: focused.name, id: focused.id,
    } : null;
    state.busy = true; host()?.setAttribute('aria-busy','true'); host()?.querySelectorAll('button,input,textarea,select').forEach(el=>el.disabled=true);
    try { await fn(); } catch(e) { status(e.message,true); }
    finally {
      state.busy=false;
      if (current()) {
        render();
        if (focusKey && !comparisonView && (!document.activeElement || document.activeElement === document.body)) {
          const target = [...(host()?.querySelectorAll('button,input,textarea,select,summary') || [])].find(el =>
            (focusKey.op && el.dataset.reviewOp === focusKey.op) ||
            (focusKey.point && el.dataset.reviewCheck === focusKey.point) ||
            (focusKey.id && el.id === focusKey.id) || (focusKey.name && el.name === focusKey.name));
          const fallback = focusKey.op === 'join' ? host()?.querySelector('[data-answer] select') :
            focusKey.op === 'close' ? host()?.querySelector('[data-review-op="retest"]') :
            focusKey.id === 'reviewReload' ? document.getElementById('reviewReload') : null;
          (target || fallback)?.focus({preventScroll:true});
        }
      }
    }
  }
  async function refresh() {
    const g = ++generation;
    const el = document.getElementById('reviewsStatus'); if (el) el.textContent='LOADING…';
    try {
      const page = await window.NRCAssets.requestAllAssets(0n,18,{fullContent:false,isCancelled:()=>g!==generation});
      if (g!==generation) return;
      state.forms = page.assets || page;
      renderList();
    } catch(e) { if (g===generation && el) el.textContent=e.message; }
  }
  function renderList() {
    const list = document.getElementById('reviewsList'); if (!list) return;
    const query = document.getElementById('reviewsSearch')?.value.toLowerCase() || '';
    const archived = document.getElementById('reviewsScope').value==='archived';
    const forms = state.forms.map(a=>{let m={};try {m=JSON.parse(a.preview);} catch {} return {a,m};}).filter(({m})=>!!m.archived===archived);
    const rows = forms.filter(({a,m})=>`${m.title || ''} ${m.build || ''} ${a.assetId}`.toLowerCase().includes(query));
    list.innerHTML = rows.map(({a,m})=> `<tr data-review="${a.assetId}" class="${String(a.assetId)===state.id?'task-row-selected':''}"><td>#${a.assetId}</td><td><button type="button" class="inline-field-value">${esc(m.title || 'Review form')}</button></td><td>${esc(m.build || '—')}</td><td>${m.archived?'ARCHIVED':m.released_at?'RELEASED':'DRAFT'}</td></tr>`).join('') || '<tr><td colspan="4">NO MATCHING FORMS</td></tr>';
    document.getElementById('reviewsStatus').textContent = `${forms.length} FORMS · ${rows.length} SHOWN`;
  }
  function boundedText(value, limit) {
    let result='', bytes=0;
    for(const char of String(value ?? '').replaceAll('\0','')) {
      const size=new TextEncoder().encode(char).length;
      if(bytes+size>limit)break;
      result+=char;bytes+=size;
    }
    return result;
  }
  function ticketDraft(seed) {
    const title=boundedText(seed.title,256).trim() || 'Ticket review';
    return {...blank(),title,points:[{id:'1',question:boundedText(seed.title,1024).trim() || title,instruction:boundedText(seed.body,2048),expected:''}]};
  }
  function syncReference() {
    // Inspector history owns this live reference. Mutate it in place: reopening
    // would remount the editor and invalidate its current-context callback.
    if (!inspectorRef || !current()) return;
    Object.assign(inspectorRef,{id:BigInt(state.id || '0'),runId:state.run?.id || null,answerId:state.answerId || null,seed:null,ticket:state.ticket,predecessor:state.predecessor});
  }
  async function open(id='0', ticket='', seed=null) {
    window.NRCViewManager.setActiveView('reviews');
    await window.NRCInspector.openEntity({type:'review',id:BigInt(id),ticket,seed,runId:null,answerId:null,predecessor:null},{replaceCurrent:window.NRCInspector.current()?.type==='review'});
    refresh();
  }
  async function openAnswer(id) {
    try {
      const [asset]=await window.NRCAssets.requestAssetsByIds(0n,[BigInt(id)]);
      if(asset?.assetType!==window.NRCAssets.AssetType.ReviewAnswer)throw Error('Review answer not found');
      const runId=JSON.parse(asset.preview).run_id;
      const page=await request('run_get',{run_id:runId});
      if(!page.run.answers?.some(answer=>answer.id===String(id)))throw Error('Answer does not belong to this run');
      return await window.NRCInspector.openEntity({type:'review',id:BigInt(page.run.form_id),runId:page.run.id,answerId:String(id),seed:null,ticket:'',predecessor:null});
    } catch(error) {
      window.NRCDialog.notify(error.message);
      return false;
    }
  }
  async function load(runId=state.run?.id) {
    const id=state.id;
    if (!id) return;
    const page = await request('get',{form_id:id});
    const runs = []; let cursor='';
    do {
      const page=await request('run_list',{form_id:id,...(cursor?{cursor}:{})});
      runs.push(...(page.runs || []));
      if (!page.has_more) break;
      if (!page.cursor || page.cursor===cursor) throw Error('Run cursor did not advance');
      cursor=page.cursor;
    } while (current() && state.id===id);
    if (!current() || state.id!==id) return;
    state.comparison=null;
    state.form=page.form; state.revision=page.revision; state.runs=runs; state.dirty=false;
    if (runId) { const detail=await request('run_get',{run_id:runId}); if (!current() || state.id!==id) return; state.run=detail.run;state.participant=detail.participant_id; }
    else {state.run=null;state.participant='';}
    return true;
  }
  const field = (name,label,value,type='input') => `<label class="task-detail-row detail-edit-field"><span class="detail-edit-label">${label}</span>${type==='textarea'?`<textarea class="task-detail-textarea" name="${name}">${esc(value)}</textarea>`:`<input class="task-detail-input" name="${name}" value="${esc(value)}">`}</label>`;
  const btn = (op,label,disabled=false) => `<button class="btn" type="button" data-review-op="${op}" ${disabled?'disabled':''}>${label}</button>`;
  const runStatus = run => run.decision ? run.decision.toUpperCase() : run.answered_points>0 ? 'ACTIVE' : 'NOT STARTED';
  function runListMarkup() {
    const {run,runs,form}=state;
    return `<section class="review-runs" aria-label="Review runs">
      <label class="detail-edit-field"><span class="detail-edit-label">RUN · ${runs.length}</span>
        <select id="reviewRunSelect" class="filter-select" ${runs.length?'':'disabled'}>
          <option value="" disabled ${run?'':'selected'}>${runs.length?'SELECT A RUN…':'NO RUNS YET'}</option>
          ${runs.map(summary=>{
            const selected=summary.id===run?.id, item=selected?run:summary;
            return `<option value="${esc(item.id)}" ${selected?'selected':''}>${esc(item.label)} · #${esc(item.id)} · ${item.answered_points || 0}/${form.points.length} · ${esc(runStatus(item))}</option>`;
          }).join('')}
        </select>
      </label>
      <div class="customer-actions">${form.archived?'':btn('qa','+ TEAM QA')+btn('customer','+ CUSTOMER ACCEPTANCE')}${btn('compare','COMPARE TEAMS',!runs.length)}</div>
    </section>`;
  }
  function cellResult(answers) {
    if (!answers.length) return 'OPEN';
    if (new Set(answers.map(a=>a.result)).size>1) return 'CONFLICTING';
    return {yes:'YES',no:'NO',unable:'UNABLE TO TEST'}[answers[0].result] || 'UNKNOWN';
  }
  function comparisonPoints(form,runs) {
    const filtered=form.points.filter(point=>`${point.id} ${point.section || ''} ${point.question} ${point.instruction} ${point.expected}`.toLowerCase().includes(comparisonState.query.toLowerCase()) &&
      (comparisonState.filter==='all' || runs.some(run=>cellResult((run.answers || []).filter(a=>a.point_id===point.id))===comparisonState.filter)));
    const groups=new Map();
    for(const point of filtered){const key=point.section || '';if(!groups.has(key))groups.set(key,[]);groups.get(key).push(point);}
    return [...groups.values()].flat();
  }
  function comparisonMarkup(form,runs) {
    if(runs===null)return '';
    const points=comparisonPoints(form,runs);
    let section=null;
    return `<section aria-label="Team run comparison"><header class="panel-header"><div><span>POINT × TEAM COMPARISON · ${runs.length} RUNS</span></div></header>
      <div class="review-comparison-scroll" role="region" aria-label="Team comparison. Scroll horizontally for more teams." tabindex="0"><table class="review-comparison-table">
      <caption>${points.length}/${form.points.length} POINTS · SNAPSHOT · select a cell for individual contributions</caption>
      <thead><tr><th scope="col">POINT</th>${runs.map(run=>`<th scope="col">${esc(run.label)} · #${esc(run.id)}<br>${esc(run.kind.toUpperCase())} · ${esc(runStatus(run))}</th>`).join('')}</tr></thead>
      <tbody>${points.map(point=>{
        const group=point.section || 'UNSECTIONED';
        const heading=group!==section?`<tr class="review-section"><th colspan="${runs.length+1}" scope="rowgroup">${esc(group)}</th></tr>`:'';section=group;
        return `${heading}<tr><th scope="row">#${esc(point.id)} · ${esc(point.question)}</th>${runs.map(run=>{
        const answers=(run.answers || []).filter(a=>a.point_id===point.id);
        const result=cellResult(answers), selected=comparisonState.point===point.id && comparisonState.run===run.id;
        return `<td><button type="button" class="review-cell" data-cell-point="${esc(point.id)}" data-cell-run="${esc(run.id)}" aria-pressed="${selected}" aria-label="Point ${esc(point.id)}, ${esc(run.label)}: ${result}">${result==='YES'?'✓ ':result==='NO'?'× ':result==='CONFLICTING'?'≈ ':'○ '}${result}</button></td>`;
      }).join('')}</tr>`;}).join('') || `<tr><td colspan="${runs.length+1}">NO MATCHING POINTS</td></tr>`}
      <tr><th scope="row">DECISION</th>${runs.map(run=>`<td><strong>${run.decision?esc(run.decision.toUpperCase()):'NOT CLOSED'}</strong>${run.decision?`<p>${esc(run.closed_name)} · ${esc(run.closed_source)}</p><p>${esc(run.comment)}</p>`:''}</td>`).join('')}</tr></tbody></table></div></section>`;
  }
  function contributionMarkup(point,run) {
    return `<header class="panel-header"><div><span>POINT #${esc(point.id)} · ${esc(run.label)}</span></div></header><h3>${esc(point.question)}</h3><p>${esc(point.instruction)}</p><p>EXPECTED · ${esc(point.expected) || '—'}</p>${(run.answers || []).filter(a=>a.point_id===point.id).map(a=>{
      const member=run.participants?.find(p=>p.id===a.participant_id);
      const source=member?.source || a.source;
      const provenance=source==='guest'?'GUEST · SELF-DECLARED NAME':source==='staff'?'STAFF · VERIFIED ACCOUNT':source==='portal'?'PORTAL · ASSIGNED ACCOUNT':'UNSPECIFIED SOURCE';
      return `<section class="review-comparison-answer"><strong>${esc(a.name)} · #${esc(a.participant_id)} · ${esc(a.result.toUpperCase())}</strong><p>${provenance} · ${member?member.can_close?'MAY CLOSE':'CONTRIBUTE ONLY':'CLOSE AUTHORITY UNKNOWN'} · ANSWER ASSET #${esc(a.id)}</p><p>${esc(a.comment) || 'NO COMMENT'}</p>${btn('finding:'+a.id,'CREATE TASK FROM THIS FINDING')}${btn('refs:'+a.id,'FINDINGS / REFERENCES')}</section>`;
    }).join('') || '<p>OPEN · No contributions in this snapshot.</p>'}`;
  }
  function paintComparison() {
    if(!comparisonView)return;
    const content=comparisonView.panel.querySelector('[data-comparison-content]');
    content.innerHTML=`<div class="review-comparison-layout">${comparisonMarkup(state.form,state.comparison)}<aside class="review-contribution" aria-label="Selected contribution details" tabindex="-1"></aside></div>`;
    const point=state.form.points.find(p=>p.id===comparisonState.point),run=state.comparison.find(r=>r.id===comparisonState.run);
    content.querySelector('aside').innerHTML=point && run?contributionMarkup(point,run):'<p>Select a point × team cell to inspect each person’s contribution and create a finding task.</p>';
  }
  function showComparison() {
    if(comparisonView){paintComparison();return;}
    comparisonView=NRCModal.create({title:`${state.form.title} · TEAM COMPARISON`,className:'review-comparison-dialog',closeButton:true,onCancel:()=>{comparisonView=null;host()?.querySelector('[data-review-op="compare"]')?.focus({preventScroll:true});}});
    comparisonView.panel.insertAdjacentHTML('beforeend',`<div class="review-comparison-controls"><label class="detail-edit-field"><span class="detail-edit-label">SEARCH POINTS / SECTIONS</span><input type="search" class="filter-input" data-comparison-search value="${esc(comparisonState.query)}"></label><label class="detail-edit-field"><span class="detail-edit-label">RESULT IN ANY TEAM</span><select class="filter-select" data-comparison-filter>${['all','OPEN','CONFLICTING','NO','UNABLE TO TEST','YES'].map(v=>`<option value="${v}">${v==='all'?'ALL RESULTS':v}</option>`).join('')}</select></label>${btn('compare','REFRESH SNAPSHOT')}</div><p class="overview-note" data-comparison-status role="status">${state.form.points.length} POINTS · ${state.comparison.length} RUNS · EXPLICIT SNAPSHOT</p><div data-comparison-content></div><section id="reviewComparisonReferences"></section>`);
    comparisonView.panel.querySelector('[data-comparison-filter]').value=comparisonState.filter;
    comparisonView.panel.oninput=e=>{if(e.target.matches('[data-comparison-search]'))comparisonState.query=e.target.value;else if(e.target.matches('[data-comparison-filter]'))comparisonState.filter=e.target.value;else return;paintComparison();};
    comparisonView.panel.onchange=e=>{if(e.target.matches('[data-comparison-filter]')){comparisonState.filter=e.target.value;paintComparison();}};
    comparisonView.panel.onclick=e=>{
      const cell=e.target.closest('[data-cell-point]');
      if(cell){comparisonState.point=cell.dataset.cellPoint;comparisonState.run=cell.dataset.cellRun;paintComparison();comparisonView.panel.querySelector(`[data-cell-point="${comparisonState.point}"][data-cell-run="${comparisonState.run}"]`)?.focus();}
      const b=e.target.closest('[data-review-op]');if(b)command(b.dataset.reviewOp,b);
    };
    comparisonView.panel.onkeydown=e=>{
      const cell=e.target.closest('[data-cell-point]');if(!cell || !['ArrowDown','ArrowUp','ArrowLeft','ArrowRight','Enter'].includes(e.key))return;
      if(e.key==='Enter'){e.preventDefault();comparisonView.panel.querySelector('aside').focus();return;}
      const points=comparisonPoints(state.form,state.comparison),runs=state.comparison;
      let i=points.findIndex(p=>p.id===cell.dataset.cellPoint),j=runs.findIndex(r=>r.id===cell.dataset.cellRun);
      i=Math.max(0,Math.min(points.length-1,i+(e.key==='ArrowDown'?1:e.key==='ArrowUp'?-1:0)));
      j=Math.max(0,Math.min(runs.length-1,j+(e.key==='ArrowRight'?1:e.key==='ArrowLeft'?-1:0)));
      e.preventDefault();comparisonView.panel.querySelector(`[data-cell-point="${points[i].id}"][data-cell-run="${runs[j].id}"]`)?.click();
    };
    comparisonView.canClose=()=>!state.busy;
    paintComparison();comparisonView.show();
  }
  async function createFindingTask(id) {
    const run=(state.comparison || []).concat(state.run || []).find(r=>r.answers?.some(a=>a.id===id));
    const answer=run?.answers.find(a=>a.id===id),point=state.form.points.find(p=>p.id===answer?.point_id);
    if(!answer || !point)throw Error('Select a concrete contribution before creating a task');
    let description=`Review form #${state.id}: ${state.form.title}\nBuild: ${state.form.build}\nRun #${run.id}: ${run.label} (${run.kind})\nPoint #${point.id}: ${point.question}\nAnswer asset #${answer.id}\nContributor: ${answer.name} (participant #${answer.participant_id})\nResult: ${answer.result}\nComment: ${answer.comment || ''}`;
    const excerpt=new TextEncoder().encode(description).length>MAX_TASK_DESCRIPTION_LENGTH;
    if(excerpt) {
      const source=`\n\nEXCERPT · Full original preserved in linked answer asset #${answer.id} (run #${run.id}).`;
      description=boundedText(description,MAX_TASK_DESCRIPTION_LENGTH-new TextEncoder().encode(source).length)+source;
    }
    const title=await window.NRCDialog.prompt(excerpt?`Finding task title. Description is an excerpt (maximum ${MAX_TASK_DESCRIPTION_LENGTH} UTF-8 bytes). The full original stays unchanged in linked answer #${answer.id}, run #${run.id}.`:'Finding task title',{title:'CREATE TASK FROM SELECTED FINDING',initialValue:boundedText(point.question,256)});if(!title)return;
    const result=await write(options=>window.NRCTasks.sendCreateTask(0n,title,description,128,0,'',0n,[],0,0,'',options));
    status(`TASK #${result.task.id} CREATED · LINK PENDING`);
    try{await link(answer.id,2,result.task.id);status(`TASK #${result.task.id} CREATED AND LINKED TO ANSWER #${answer.id}`);}
    catch(e){throw Error(`Task #${result.task.id} exists but link failed. Use LINK TASK; do not create it again. ${e.message}`);}
  }
  const formatDate = value => window.NRCDetailUI.formatHeaderDate(value);
  const memberLabel = member => `${esc(member.source.toUpperCase())} · ${member.can_close?'MAY CLOSE':'CONTRIBUTE ONLY'}`;
  const showResult = result => {
    const [tone,label]=({YES:['pass','PASSED'],NO:['fail','FAILED'],'UNABLE TO TEST':['neutral','UNABLE TO TEST'],CONFLICTING:['fail','CONFLICTING'],OPEN:['neutral','OPEN']})[result] || ['neutral','UNKNOWN'];
    return `<span class="review-result review-result--${tone}">${label}</span>`;
  };
  function pointDefinition(point) {
    return `<div class="review-definition"><span class="detail-edit-label">QUESTION</span><h3>${esc(point.question)}</h3>
      ${point.section?`<p class="customer-meta">SECTION · ${esc(point.section)}</p>`:''}
      <dl><div><dt class="detail-edit-label">INSTRUCTIONS</dt><dd>${esc(point.instruction) || '—'}</dd></div>
      <div><dt class="detail-edit-label">EXPECTED OUTCOME</dt><dd>${esc(point.expected) || '—'}</dd></div></dl></div>`;
  }
  const selfAssign = () => `<div class="review-self-assign"><span>Assign yourself to contribute.</span>${btn('join','ASSIGN MYSELF')}</div>`;
  function checkDetail(point, run, member) {
    const own=point.answers.find(a=>a.participant_id===member?.id);
    const draft=recordView.drafts.get(`${run.id}:${point.id}`) || own;
    return `<div class="review-check-detail">${pointDefinition(point)}<section class="review-check-contributions" aria-label="Contributions">
      <header class="panel-header"><div><span>CONTRIBUTIONS · ${point.answers.length}</span></div></header>
      ${point.answers.map(a=>{
        const contributor=run.participants?.find(m=>m.id===a.participant_id);
        return `<div data-review-answer="${esc(a.id)}" tabindex="-1" class="review-check-answer${a.id===state.answerId?' review-answer-selected':''}">
          <strong>${esc(a.name)} · #${esc(a.participant_id)} · ${esc(a.result.toUpperCase())} · ANSWER #${esc(a.id)}</strong>
          <p class="customer-meta">${contributor?`${memberLabel(contributor)} · `:''}${esc(formatDate(a.updated_at))}</p>
          <p class="review-answer-comment">${esc(a.comment) || 'NO COMMENT'}</p>${btn('refs:'+a.id,'FINDINGS / REFERENCES')}</div>`;
      }).join('') || '<p class="review-check-answer customer-meta">NO CONTRIBUTIONS</p>'}
      ${run.decision?'':member?.source==='staff'?`<form data-answer="${esc(point.id)}" class="review-answer-form">
        <label class="detail-edit-field"><span class="detail-edit-label">MY RESULT</span><select class="filter-select" name="result" required>
          <option value="">CHOOSE…</option>${[['yes','YES'],['no','NO'],['unable','UNABLE TO TEST']].map(([value,label])=>`<option value="${value}" ${draft?.result===value?'selected':''}>${label}</option>`).join('')}
        </select></label>${field('comment','MY COMMENT',draft?.comment || '','textarea')}<button id="reviewAnswerSave" class="btn" type="submit">SAVE MY ANSWER</button></form>`:
        !member ? selfAssign() : '<p class="customer-meta review-check-answer">Only assigned staff can save answers here.</p>'}
      </section></div>`;
  }
  function runResults(run, member, p) {
    const focused=recordView.point ?? p.points.find(point=>point.answers.some(a=>a.id===state.answerId))?.id ?? p.points[0]?.id;
    return `<section class="review-run-results" aria-label="Run results">
      <div class="review-run-access"><div class="review-run-facts">
        <p class="customer-meta"><strong>${esc(run.label)}</strong> · RUN #${esc(run.id)} · ${esc(run.kind==='qa'?'TEAM QA':'CUSTOMER ACCEPTANCE')} · ${esc(run.decision?.toUpperCase() || 'OPEN')}</p>
        <p class="customer-meta">${p.answered}/${p.points.length} POINTS ANSWERED · ${p.open} OPEN · ${p.conflicts} CONFLICTING · ${p.failed} NOT ALL YES</p>
        <p class="customer-meta">${member?`YOU · ${esc(member.name)} · ${memberLabel(member)}`:'YOU · NOT ASSIGNED'}${run.previous_run?` · RETEST OF RUN #${esc(run.previous_run)}`:''}</p></div>
        <div class="customer-actions"><button class="btn" type="button" id="reviewAccessToggle" aria-expanded="${recordView.access}" aria-controls="reviewAccess">MANAGE ACCESS</button>${run.decision?btn('retest','RETEST FOR NEW BUILD'):btn('close','PREVIEW CLOSE',!member?.can_close)}</div></div>
      <section id="reviewAccess" ${recordView.access?'':'hidden'} aria-label="Manage run access">
        <ul>${(run.participants || []).map(m=>`<li><strong>${esc(m.name)}</strong> · #${esc(m.id)} · ${memberLabel(m)}</li>`).join('') || '<li>NO PARTICIPANTS</li>'}</ul>
        <div class="customer-actions">${run.decision?'':btn('participant','+ STAFF PARTICIPANT')+btn('portal-participant','+ PORTAL ACCOUNT')+btn('invite','GUEST INVITE')}${btn('revoke','REVOKE INVITE')}</div>
      </section>
      ${run.decision?`<p class="review-close-record">Closed by ${esc(run.closed_name)} (${esc(run.closed_source)}) · ${esc(formatDate(run.closed_at))}<br>${esc(run.comment)}</p>`:!member && !focused?selfAssign():''}
      <table class="review-results-table" aria-label="Review checks"><thead><tr><th scope="col">#</th><th scope="col">CHECK</th><th scope="col">TEAM RESULT</th><th scope="col">ANSWERS</th></tr></thead><tbody>
        ${p.points.map((point,i)=>{
          const id=esc(point.id), expanded=point.id===focused;
          return `<tr class="review-check-row"><td>${i+1}</td><th scope="row"><button class="review-check-toggle" type="button" data-review-check="${id}" aria-expanded="${expanded}" aria-controls="review-check-${id}">${esc(point.question)}</button></th>
            <td>${showResult(cellResult(point.answers))}</td><td>${point.answers.length}</td></tr>
            <tr class="review-check-detail-row" id="review-check-${id}" ${expanded?'':'hidden'}><td colspan="4">${expanded?checkDetail(point,run,member):''}</td></tr>`;
        }).join('')}</tbody></table>
    </section>`;
  }
  function render() {
    const root=host(); if (!root || !current()) return;
    const f=state.form, r=state.run, frozen=!!f.released_at, p=progress(f,r);
    const member=r?.participants?.find(m=>m.id===state.participant);
    const header=document.getElementById('inspectorHeader');
    header.innerHTML=`<div class="inspector-identity-row"><span class="header-text identity-reference">REVIEW ${state.id?'#'+state.id:'NEW'}</span><span class="status-value-mono">${f.archived?'ARCHIVED':frozen?'RELEASED':state.dirty?'UNSAVED':'DRAFT'}</span></div><div class="inspector-mode-row">${state.id?window.NRCDetailUI.renderHeaderAction({id:'reviewReload',label:'REFRESH',command:'refresh',title:'Refresh review and team answers'}):''}${window.NRCDetailUI.renderCloseControl('reviewClose')}</div>`;
    document.getElementById('reviewClose').onclick=()=>window.NRCInspector.close();
    const reload=document.getElementById('reviewReload');if(reload)reload.onclick=()=>command('reload');
    root.innerHTML=`<p id="reviewNotice" class="customer-status${state.noticeError?' review-notice-error':''}" role="status" aria-live="polite">${esc(state.notice)}</p>
      ${frozen?`<section class="review-release"><h2>${esc(f.title)}</h2><dl class="review-facts">
        <div><dt>BUILD</dt><dd>${esc(f.build) || '—'}</dd></div><div><dt>ENVIRONMENT</dt><dd>${esc(f.environment) || '—'}</dd></div><div><dt>RELEASED</dt><dd>${esc(formatDate(f.released_at))}</dd></div></dl>
        <details class="review-form-points" ${recordView.definitions?'open':''}><summary>RELEASED POINT DEFINITIONS · ${f.points.length}</summary>
          ${f.points.map((point,i)=>`<section class="review-released-point"><p class="customer-meta">POINT ${i+1} · #${esc(point.id)}</p>${pointDefinition(point)}</section>`).join('')}</details>
        <div class="customer-actions">${btn('copy','COPY TO NEW DRAFT')}${btn('refs:'+state.id,'REFERENCES')}${f.archived?btn('restore','RESTORE FROM ARCHIVE'):(!state.runs.length?btn('unrelease','WITHDRAW RELEASE'):'')+btn('archive','ARCHIVE')}</div></section>
        ${runListMarkup()}${r?runResults(r,member,p):''}`:
        `<form id="reviewForm">${field('title','TITLE',f.title)}${field('build','BUILD',f.build)}${field('environment','ENVIRONMENT',f.environment)}
        <p class="overview-note">${f.points.length}/100 POINTS · STABLE POINT IDS · ARRAY ORDER</p>
        ${f.points.map((point,i)=>`<fieldset data-point="${esc(point.id)}"><legend>POINT ${i+1} · #${esc(point.id)}</legend>${field('section','SECTION · OPTIONAL · MAX 256 UTF-8 BYTES',point.section)}${field('question','QUESTION',point.question)}${field('instruction','INSTRUCTION',point.instruction,'textarea')}${field('expected','EXPECTED RESULT',point.expected,'textarea')}${btn('up:'+point.id,'↑',i===0)}${btn('down:'+point.id,'↓',i===f.points.length-1)}${btn('remove:'+point.id,'REMOVE POINT')}</fieldset>`).join('')}
        <div class="customer-actions">${btn('add','+ POINT',f.points.length>=100)}${btn('save','SAVE DRAFT')}${btn('release','RELEASE',!state.id || state.dirty || !f.build.trim() || !f.points.length)}${state.id?btn('refs:'+state.id,'REFERENCES'):''}${state.id && state.revision?'<button type="button" class="btn btn--danger" data-review-op="delete-draft">DELETE DRAFT</button>':''}</div></form>`}
      <section id="reviewReferences"></section>`;
    root.oninput=e=> {
      const answer=e.target.closest('[data-answer]');
      if(answer) {recordView.drafts.set(`${r.id}:${answer.dataset.answer}`,{result:answer.elements.result.value,comment:answer.elements.comment.value});return;}
      if (frozen || !e.target.closest('#reviewForm') || !e.target.name) return;
      const point=e.target.closest('[data-point]');const target=point?f.points.find(p=>p.id===point.dataset.point):f;target[e.target.name]=e.target.value;
      if(e.target.name==='section')e.target.setCustomValidity(new TextEncoder().encode(e.target.value).length>256?'Section must be at most 256 UTF-8 bytes':'');
      state.dirty=true;status('UNSAVED DRAFT · SAVE BEFORE RELEASE');
    };
    root.onclick=e=> {
      const b=e.target.closest('[data-review-op]');if(b){command(b.dataset.reviewOp,b);return;}
      const toggle=e.target.closest('.review-check-row')?.querySelector('[data-review-check]');
      if(!toggle || state.busy)return;
      recordView.point=toggle.getAttribute('aria-expanded')==='true'?'':toggle.dataset.reviewCheck;
      render();root.querySelector(`[data-review-check="${toggle.dataset.reviewCheck}"]`)?.focus();
    };
    root.onkeydown=e=>{
      if(!e.target.matches('[data-review-check]') || !['ArrowUp','ArrowDown'].includes(e.key))return;
      const checks=[...root.querySelectorAll('[data-review-check]')], index=checks.indexOf(e.target);
      e.preventDefault();checks[index+(e.key==='ArrowDown'?1:-1)]?.focus();
    };
    const runSelect=root.querySelector('#reviewRunSelect');if(runSelect)runSelect.onchange=()=>command(`run:${runSelect.value}`);
    const access=root.querySelector('#reviewAccessToggle');if(access)access.onclick=()=>{
      recordView.access=!recordView.access;
      access.setAttribute('aria-expanded',String(recordView.access));
      root.querySelector('#reviewAccess').hidden=!recordView.access;
    };
    const definitions=root.querySelector('.review-form-points');if(definitions)definitions.ontoggle=()=>{if(definitions.isConnected)recordView.definitions=definitions.open;};
    root.onsubmit=e=>{
      e.preventDefault();
      const form=e.target;
      if(form.id==='reviewForm')return command('save');
      if(!form.matches('[data-answer]') || !connected() || member?.source!=='staff' || r.decision)return;
      const fields={run_id:r.id,point_id:form.dataset.answer,result:form.elements.result.value,comment:form.elements.comment.value};
      action(async()=>{await request('answer',fields);recordView.drafts.delete(`${r.id}:${fields.point_id}`);await load();status('ANSWER SAVED');});
    };
    root.setAttribute('aria-busy','false');
    updateConnectionControls();
  }
  async function command(op, anchor) {
    if (state.busy) return;
    if (!connected()) return status('OFFLINE · LOCAL DRAFT RETAINED · RECONNECT BEFORE SAVING');
    const [verb,id]=op.split(':');
    if (['up','down','remove','add'].includes(verb)) {
      if(state.form.released_at)return;
      const points=state.form.points, i=points.findIndex(p=>p.id===id);
      if(verb==='add' && points.length<100) points.push({id:String(points.reduce((n,p)=>BigInt(p.id)>n?BigInt(p.id):n,0n)+1n),question:'',instruction:'',expected:''});
      if(verb==='remove') points.splice(i,1);
      if(verb==='up' && i>0) [points[i-1],points[i]]=[points[i],points[i-1]];
      if(verb==='down' && i<points.length-1) [points[i+1],points[i]]=[points[i],points[i+1]];
      state.dirty=true;render();return;
    }
    if(verb==='refs') return references(id,anchor);
    return action(async()=> {
      if(verb==='finding')await createFindingTask(id);
      if(verb==='reload') {if(!state.id)return status('UNSAVED NEW FORM · SAVE DRAFT FIRST');if(state.dirty && !await window.NRCDialog.confirm('Discard unsaved form changes and refresh?')) return; if(await load())status('LATEST SERVER STATE');}
      if(verb==='compare') {
        const formId=state.id, runs=[];
        for(const run of state.runs) {
          const page=await request('run_get',{run_id:run.id});
          if(!current() || state.id!==formId)return;
          runs.push(page.run);
        }
        state.comparison=runs;if(host())showComparison();status('COMPARISON LOADED · SNAPSHOT · REFRESH EXPLICITLY FOR NEW CONTRIBUTIONS');
      }
      if(verb==='save') {if(state.form.released_at)return;if(state.form.points.some(p=>typeof (p.section ?? '')!=='string' || new TextEncoder().encode(p.section || '').length>256))throw Error('Section must be a string of at most 256 UTF-8 bytes');const page=await request(state.id?'update':'create',{form_id:state.id,if_revision:state.revision,form:state.form});state.id=page.form_id;state.revision=page.revision;state.form=page.form;state.dirty=false;const ticket=state.ticket;state.ticket='';syncReference();status('DRAFT SAVED'); if(ticket)await link(state.id,1,ticket); refresh();}
      if(verb==='release') {if(!await window.NRCDialog.confirm('Release this form for testing? You can withdraw the release until the first run is created.',{title:'RELEASE REVIEW FORM'}))return;await request('release',{form_id:state.id,if_revision:state.revision});await load();status('');refresh();}
      if(['unrelease','archive','restore'].includes(verb)) {
        const {id,revision}=state, ref=inspectorRef;
        if(verb==='unrelease' && !await window.NRCDialog.confirm('Return this form to draft? It cannot be used for a run until released again.',{title:'WITHDRAW RELEASE',confirmLabel:'Withdraw release'}))return;
        if(verb==='archive' && !await window.NRCDialog.confirm('Move this form to the archive and prevent new runs? Existing runs and reports are kept.',{title:'ARCHIVE REVIEW FORM',confirmLabel:'Archive'}))return;
        if(!current() || inspectorRef!==ref || !connected())return;
        const page=await request(verb,{form_id:id,if_revision:revision});
        if(current() && inspectorRef===ref){state.form=page.form;state.revision=page.revision;status({unrelease:'RELEASE WITHDRAWN · DRAFT EDITABLE',archive:'FORM ARCHIVED',restore:'FORM RESTORED'}[verb]);}
        refresh();
      }
      if(verb==='delete-draft') {
        const {id,revision,form}=state, ref=inspectorRef;
        if(!id || !revision || form.released_at) return;
        if(!await window.NRCDialog.confirm(`Delete review draft #${id} and its links? This cannot be undone.`,{title:'DELETE REVIEW DRAFT',confirmLabel:'Delete draft'})) return;
        if(!current() || inspectorRef!==ref || !connected()) return;
        await request('delete_draft',{form_id:id,if_revision:revision});
        window.NRCInspector.entityDeleted(ref);
        refresh();
      }
      if(verb==='copy' || verb==='retest') {
        const previous=state.run;
        const page=await request('copy',{form_id:state.id});
        state.id=page.form_id;state.revision=page.revision;state.form=page.form;state.runs=[];state.run=null;state.comparison=null;state.dirty=false;
        if(verb==='retest'){state.form.build='';state.dirty=true;}
        Object.assign(recordView,{point:null,access:false,definitions:false});recordView.drafts.clear();
        state.answerId='';state.ticket='';state.predecessor=verb==='retest'?{id:previous.id,label:previous.label,kind:previous.kind}:null;syncReference();status('INDEPENDENT DRAFT · SET NEW BUILD, SAVE AND RELEASE'+(state.predecessor?' · NEXT RUN WILL REFERENCE #'+state.predecessor.id:'')); refresh();
      }
      if(verb==='qa' || verb==='customer') {
        const {id,predecessor:previous,form:{released_at}}=state, ref=inspectorRef;
        const label=previous?.label || await window.NRCDialog.prompt('Run label',{title:'NEW REVIEW RUN'});
        if(!label || !current() || inspectorRef!==ref)return;
        const page=await request('run_create',{form_id:id,if_released_at:released_at,label,kind:previous?.kind || verb,...(previous?{previous_run:previous.id}:{})});
        if(!current() || inspectorRef!==ref)return;
        state.predecessor=null;selectRun(page);await load();
      }
      if(verb==='run') selectRun(await request('run_get',{run_id:id}));
      if(['join','participant','portal-participant'].includes(verb)) {
        const source=verb==='portal-participant'?'portal':'staff';
        const run=state.run, ref=inspectorRef;
        const person=verb==='join'?{identity:'',name:await window.NRCDialog.prompt('Participant display name',{title:'ASSIGN STAFF',submitLabel:'Continue'})}:await chooseParticipant(source,run.id);
        if(!person?.name || !current() || inspectorRef!==ref)return;
        const can_close=await window.NRCDialog.confirm('Allow this participant to explicitly close the run? Cancel assigns contribute-only rights.',{title:'CLOSE PERMISSION'});
        if(!current() || inspectorRef!==ref || state.run!==run)return;
        await request('participant_add',{run_id:run.id,source,identity:person.identity,name:person.name.trim(),can_close});
        await load();status(source==='portal'?'PORTAL ACCOUNT ASSIGNED':'STAFF PARTICIPANT ASSIGNED');
      }
      if(verb==='close') {const r=state.run,p=progress(state.form,r);const decision=r.kind==='qa'?'completed':await window.NRCDialog.prompt('Decision: accepted / conditional / rejected',{title:'CUSTOMER DECISION'});if(!['completed','accepted','conditional','rejected'].includes(decision))return;const comment=await window.NRCDialog.prompt('Closing comment',{title:'CLOSE PREVIEW'});if(comment===null)return;if(!await window.NRCDialog.confirm(`${p.answered}/${state.form.points.length} points answered; ${p.open} open; ${p.conflicts} conflicting; ${p.failed} not all yes. Decision: ${decision}. Closing freezes all answers.`,{title:'CONFIRM EXPLICIT CLOSE'}))return;await request('close',{run_id:r.id,if_revision:r.revision,decision,comment});await load();}
      if(verb==='invite') await invite();
      if(verb==='revoke') {const invite_id=await window.NRCDialog.prompt('Invite ID to revoke',{title:'REVOKE GUEST LINK'});if(invite_id) {await request('revoke',{run_id:state.run.id,invite_id});status('INVITE REVOKED');}}
    });
  }
  function selectRun(page) {
    state.run=page.run;state.participant=page.participant_id;state.answerId='';
    recordView.point=null;recordView.access=false;status('');syncReference();
  }
  const link=(source,type,id)=>write(options=>window.NRCEdges.sendCreateEdge(0n,1,BigInt(source),type,BigInt(id),window.NRCEdges.RelationType.RelatedTo,options));
  async function references(id,anchor) {
    const root=comparisonView?.panel.querySelector('#reviewComparisonReferences') || document.getElementById('reviewReferences'); if(!root)return;
    if (anchor && !comparisonView) (anchor.closest('.customer-actions') || anchor).after(root);
    root.innerHTML='<p role="status">LOADING REFERENCES…</p>';
    try {
      const edges=[];let session;
      do {const page=await window.NRCEdges.requestEdgePage(0n,1,BigInt(id),{session}); edges.push(...page.edges);session=page.session;if(!page.hasMore)break;}while(true);
      const related=edges.filter(e=>e.relation===window.NRCEdges.RelationType.RelatedTo);
      const finding=(state.comparison || []).concat(state.run || []).some(r=>r.answers?.some(a=>a.id===id));
      root.innerHTML=`<header class="panel-header"><div><span>REFERENCES · ASSET #${esc(id)}</span></div></header><p>References remain editable after closure. Removing a link never deletes its endpoints.</p>${related.map(e=>{const outgoing=e.sourceType===1 && String(e.sourceId)===id;return `<p>${outgoing?e.targetType===2?'TASK':'ASSET':e.sourceType===2?'TASK':'ASSET'} #${outgoing?e.targetId:e.sourceId} <button class="btn" data-unlink="${e.edgeId}">REMOVE LINK</button></p>`;}).join('')}${btn('picker','+ LINK TASK / TICKET')}${finding?btn('task','CREATE TASK FROM THIS FINDING'):''}<nrc-link-picker id="reviewReferencePicker"></nrc-link-picker>`;
      root.onclick=async e=> {
        e.stopPropagation();
        const b=e.target.closest('button');if(!b || state.busy)return;
        if(b.dataset.unlink) action(async()=>{await write(options=>window.NRCEdges.sendDeleteEdge(0n,BigInt(b.dataset.unlink),options));status('LINK REMOVED · RECORDS RETAINED');});
        if(b.dataset.reviewOp==='picker') root.querySelector('#reviewReferencePicker').open({anchor:b,sourceType:1,sourceEntity:{assetId:BigInt(id),convId:0n},kinds:['task','ticket'],relation:{value:window.NRCEdges.RelationType.RelatedTo,label:'RELATED TO'},onSelect:item=>action(async()=>{await link(id,item.type==='task'?2:1,item.id);status('REFERENCE LINKED');})});
        if(b.dataset.reviewOp==='task') action(()=>createFindingTask(id));
      };
    }catch(e){root.textContent=e.message;}
  }
  async function invite() {
    const config=await fetch('/api/features',{credentials:'same-origin',cache:'no-store'});
    if(!config.ok)throw Error('Could not load the review portal configuration');
    const {review_portal_origin:origin}=await config.json();
    const url=URL.canParse(origin)?new URL(origin):null;
    if(!url || url.protocol!=='https:' || url.pathname!=='/' || url.search || url.hash || url.username || url.password)throw Error('The public review portal URL is not configured. Contact your NRC administrator.');
    const expires=await window.NRCDialog.prompt('Expiry date and time, including timezone (ISO 8601)',{title:'GUEST LINK EXPIRY'});if(!expires)return;const ms=Date.parse(expires);if(!Number.isFinite(ms)||ms<=Date.now())throw Error('Expiry must be in the future');
    const can_close=await window.NRCDialog.confirm('Grant authority to CLOSE the entire run? Cancel creates a contribute-only link (recommended).',{title:'WARNING · GUEST CLOSE AUTHORITY'});
    const page=await request('invite',{run_id:state.run.id,expires_at:String(BigInt(ms)*1000000n),can_close});
    if(!/^[a-f0-9]{64}$/i.test(page.token))throw Error('Invalid invitation token returned');
    const link=new URL('/abnahmen/einladung',url.origin);link.hash=page.token;
    status(`INVITE #${page.invite_id} · ${can_close?'MAY CLOSE':'CONTRIBUTE ONLY'} · SECRET LINK · ${link.href}`);
  }
  async function showInspector(ref,stillCurrent) {
    Object.assign(recordView,{point:null,access:false,definitions:false});recordView.drafts.clear();
    inspectorRef=ref;current=stillCurrent;state.id=ref.id && String(ref.id)!=='0'?String(ref.id):'';state.form=ref.seed?ticketDraft(ref.seed):blank();state.revision='';state.run=null;state.answerId=ref.answerId || '';state.runs=[];state.comparison=null;state.predecessor=ref.predecessor || null;state.ticket=ref.ticket || '';state.dirty=!!ref.seed;state.notice=ref.seed?'EDITABLE TICKET DRAFT · TITLE AND BODY COPIED WITH PROTOCOL BYTE LIMITS · CHECK ALL POINTS BEFORE RELEASE':'';
    state.noticeError=false;
    const root=document.createElement('article');root.id='reviewEditor';root.className='customer-record';document.getElementById('inspectorEntityHost').replaceChildren(root);render();
    if(state.id) await action(()=>load(ref.runId || undefined));
    if(stillCurrent() && state.answerId) {
      const answer=root.querySelector(`[data-review-answer="${state.answerId}"]`);
      answer?.scrollIntoView({block:'start'});answer?.focus({preventScroll:true});
    }
  }
  async function confirmDiscardEdits() {return !state.busy && (!state.dirty || await window.NRCDialog.confirm('Discard unsaved review form changes?'));}
  function updateConnectionControls() {
    if (!current()) return;
    for (const root of [host(),document.getElementById('inspectorHeader')]) root?.querySelectorAll('button,input,textarea,select').forEach(el=>{
      if (el.matches('#reviewClose, #reviewAccessToggle, [data-review-check]')) return;
      if (!connected()) {
        if (!el.hasAttribute('data-review-offline')) el.setAttribute('data-review-offline',String(el.disabled));
        el.disabled=true;
      } else if (el.hasAttribute('data-review-offline')) {
        el.disabled=el.getAttribute('data-review-offline')==='true';el.removeAttribute('data-review-offline');
      }
    });
  }
  function disconnect() {generation++;for(const [id] of requests)settle(id,null,'Disconnected · outcome may be unknown; refresh before retry');comparisonView?.close();comparisonView=null;state.forms=[];status('OFFLINE · LOCAL DRAFT RETAINED · RECONNECT BEFORE SAVING');updateConnectionControls();renderList();}
  function sessionStarted() {
    const identity=JSON.stringify([currentWorkspaceId,myNickname]);
    if (session!==null && session!==identity) {
      Object.assign(state,{id:'',revision:'',form:blank(),run:null,runs:[],comparison:null,dirty:false,ticket:'',answerId:'',predecessor:null,notice:''});
      recordView.drafts.clear();
      inspectorRef=null;
      if(current())window.NRCInspector.close();
    } else if(current()) {
      status('RECONNECTED · LOCAL DRAFT RETAINED · REFRESH TO FETCH SERVER STATE');updateConnectionControls();
    }
    session=identity;
    if(window.NRCViewManager.getActiveView()==='reviews')refresh();
  }
  window.NRCReviews={open,openAnswer,refresh,showInspector,confirmDiscardEdits,handlePage,handleError:(id,error)=>settle(id,null,error),disconnect,sessionStarted,progress,request};
  document.addEventListener('nrc:asset-updated',e=>{
    if(e.detail.asset.assetType===18 && window.NRCViewManager.getActiveView()==='reviews')refresh();
  });
  function init(){document.getElementById('reviewsBtn')?.addEventListener('click',()=>{window.NRCViewManager.setActiveView('reviews');refresh();});document.getElementById('reviewNew')?.addEventListener('click',()=>open());document.getElementById('reviewsRefresh')?.addEventListener('click',refresh);document.getElementById('reviewsSearch')?.addEventListener('input',renderList);document.getElementById('reviewsScope')?.addEventListener('change',renderList);document.getElementById('reviewsList')?.addEventListener('click',e=>{const b=e.target.closest('[data-review]');if(b)open(b.dataset.review);});}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
