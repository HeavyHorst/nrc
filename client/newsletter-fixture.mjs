// Disposable in-memory fake Mailjet. No external requests, credentials, CRM or mail.
// node client/newsletter-fixture.mjs (PORT=8097 by default)
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(new URL('./', import.meta.url));
const state = {configured:true,from_name:'NRC Demo',from_email:'newsletter@example.invalid',reply_to:'reply@example.invalid',templates:[{id:'demo',name:'FAKE MAILJET · Monatsbrief',variables:['einleitung','inhalt']}],campaigns:[{id:'1',title:'Oktober-Ausgabe',template_id:'demo',subject:'Neuigkeiten im Oktober',variables:{einleitung:'Guten Tag!',inhalt:'Dies ist ausschließlich eine lokale Demo.'},status:'draft',revision:1,tested_revision:0,recipients:[]}],subscribers:['not_subscribed','pending','subscribed','unsubscribed','blocked'].map((status,i) => ({contact_id:String(i+1),name:['Anna Beispiel','Ben Muster','Clara Demo','David Beispiel','Eva Muster'][i],email:`demo${i+1}@example.invalid`,status,source:'FAKE MAILJET · Demo'})),audience:{total:5,eligible:1,not_subscribed:1,unsubscribed:1,blocked:1}};
state.subscribers[2].import_proof = {email:'demo3@example.invalid',source:'Zoho export',confirmed_at:'2025-02-03T10:20:00Z',evidence:'DOI export #123',scope:'Produktnewsletter',external_id:'123',imported_at:'2026-10-17T10:00:00Z'};
state.customers = [{customer_id:'101',name:'Beispiel GmbH',contacts:[state.subscribers[0],state.subscribers[3]]},{customer_id:'102',name:'Muster Software KG',contacts:[]},{customer_id:'103',name:'Demo Handel',contacts:[state.subscribers[2]]}];
for (const [i, ids] of [[0,['101','102']],[1,['102']],[2,['103']],[3,['101']],[4,[]]]) {
  state.subscribers[i].companies = ids.map(id => ({customer_id:id,name:state.customers.find(c=>c.customer_id===id).name}));
}
function audience(campaign) {
  const customers = state.customers.filter(c => campaign.audience === 'all_customers' || campaign.customer_ids?.includes(c.customer_id));
  const contacts = campaign.kind === 'service' ? customers.flatMap(c=>c.contacts) : state.subscribers;
  const eligible = contacts.filter(c=>campaign.kind === 'service' ? c.status !== 'blocked' : c.status === 'subscribed');
  const recipients = [...new Map(eligible.map(c=>[c.email,{...c,status:'pending'}])).values()];
  return {customers:customers.length,recipients,excluded:contacts.length-eligible.length,duplicates:eligible.length-recipients.length,missing:customers.filter(c=>!c.contacts.length)};
}
const shell = `<!doctype html><html lang="de" data-theme="light"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="/css/main.css"><link rel="stylesheet" href="/css/custom-select.css"><body><header class="panel-header"><div><span>MAILJET-DEMO · KEIN VERSAND</span><button class="btn" onclick="document.documentElement.dataset.theme=document.documentElement.dataset.theme==='dark'?'light':'dark'">Theme</button></div></header><button id="newsletterBtn" class="btn" hidden>NEWSLETTER</button><section id="newsletterPanel" class="nl-panel" style="display:flex;height:calc(100dvh - 6rem)"></section><script>const currentWorkspaceId='demo';window.NRCViewManager={getActiveView:()=> 'newsletter',setActiveView:()=>NRCNewsletter.open()};</script><script src="/dialog.js"></script><script src="/custom-picker.js"></script><script src="/custom-select.js"></script><script src="/newsletter.js"></script><script>addEventListener('DOMContentLoaded',async()=>{await NRCNewsletter.refreshAccess();await NRCNewsletter.open()})</script></body></html>`;
http.createServer(async (req,res) => {
  const url = new URL(req.url,'http://fixture');
  const json = (data,status=200) => {res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(data));};
  try {
    if (url.pathname === '/api/features') return json({customers:true,newsletter:true,newsletter_workspace:'demo'});
    if (url.pathname === '/newsletter/api/state' || url.pathname === '/newsletter/api/summary') {
      state.audience = {total:state.subscribers.length,eligible:state.subscribers.filter(s=>s.status==='subscribed').length,not_subscribed:state.subscribers.filter(s=>['pending','not_subscribed'].includes(s.status)).length,unsubscribed:state.subscribers.filter(s=>s.status==='unsubscribed').length,blocked:state.subscribers.filter(s=>s.status==='blocked').length};
      return json(url.pathname.endsWith('/summary') ? {...state,subscribers:[]} : state);
    }
    if (url.pathname.startsWith('/newsletter/api/')) {
      let raw = ''; for await (const chunk of req) raw += chunk;
      const body = raw ? JSON.parse(raw) : {};
      const parts = url.pathname.split('/').slice(3);
      if (parts[0] === 'subscribers' && parts[1] === 'search') {
        const matches = state.subscribers.filter(s => `${s.name} ${s.email} ${(s.companies || []).map(c=>c.name).join(' ')}`.toLowerCase().includes((body.query || '').trim().toLowerCase()));
        const offset = Math.min(body.offset || 0,matches.length), rows = matches.slice(offset,offset+(body.limit || 25));
        return json({subscribers:rows,total_count:matches.length,next_offset:offset+rows.length,has_more:offset+rows.length<matches.length});
      }
      if (parts[0] === 'subscribers') {
        const subscriber = state.subscribers.find(s => s.contact_id === parts[1]);
        if (!subscriber) return json({error:'Nicht gefunden'},404);
        subscriber.status = parts[2] === 'invite' ? 'pending' : 'unsubscribed'; subscriber.source = body.source || subscriber.source;
        state.audience.eligible = state.subscribers.filter(s => s.status === 'subscribed').length;
        return json(subscriber);
      }
      let campaign = state.campaigns.find(c => c.id === parts[1]);
      if (!parts[1]) {campaign = {...body,id:String(state.campaigns.length+1),status:'draft',revision:1,tested_revision:0,recipients:[]};state.campaigns.unshift(campaign);return json(campaign);}
      if (!campaign) return json({error:'Nicht gefunden'},404);
      if (body.revision !== campaign.revision) return json({error:'Versionskonflikt'},409);
      if (parts[2] === 'audience') return json({audience:audience(campaign),token:'fake-audience-token'});
      if (parts[2] === 'preview') return json({html:'<div style="font:16px sans-serif;padding:28px"><h2>NRC · Monatsbrief</h2><p>{{var:einleitung}}</p><p>{{var:inhalt}}</p><hr><p>FAKE MAILJET · Vorlagenansicht, kein Versand.</p></div>',text:'{{var:einleitung}}\n{{var:inhalt}}',exact:false,notice:'FAKE MAILJET · Vorlagenansicht. Platzhalter bleiben unverändert; die fertige Mail prüfen Sie per Testmail.'});
      if (parts[2] === 'test') campaign.tested_revision = campaign.revision;
      else if (parts[2] === 'send') {
        if (body.confirmation !== campaign.subject || campaign.tested_revision !== campaign.revision) return json({error:'Bestätigung fehlt'},400);
        if (campaign.kind === 'service' && body.audience_token !== 'fake-audience-token') return json({error:'Empfänger prüfen'},409);
        campaign.status = 'sent'; campaign.recipients = audience(campaign).recipients.map(s => ({...s,status:'sent'}));
      } else {Object.assign(campaign,body);campaign.revision++;campaign.tested_revision=0;}
      return json(campaign);
    }
    if (url.pathname === '/') {res.setHeader('Content-Type','text/html; charset=utf-8');return res.end(shell.replace('<script src="/newsletter.js">','<script src="/loading-indicator.js"></script><script src="/page-loader.js"></script><script src="/newsletter.js">'));}
    const filename = path.resolve(root,'.'+decodeURIComponent(url.pathname));
    if (!filename.startsWith(root) || !/\.(css|js|woff2)$/.test(filename)) {res.writeHead(404);return res.end();}
    res.setHeader('Content-Type',filename.endsWith('.css')?'text/css':filename.endsWith('.js')?'text/javascript':'font/woff2');res.end(await readFile(filename));
  } catch {res.writeHead(500);res.end('Fixture error');}
}).listen(Number(process.env.PORT || 8097),'0.0.0.0',() => console.log('FAKE MAILJET fixture ready; no external mail · port '+(process.env.PORT || 8097)));
