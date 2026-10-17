import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const source = await readFile(new URL('./newsletter.js', import.meta.url), 'utf8');
function fixture(fetch) {
  const button = {hidden:true}; const panel = {replaceChildren(){this.cleared = true;},append(node){this.message = node.textContent;}};
  const window = {addEventListener(){}, NRCViewManager:{getActiveView:() => 'chat'}};
  vm.runInNewContext(source, {window,currentWorkspaceId:'w',document:{getElementById:id => ({newsletterBtn:button,newsletterPanel:panel})[id],createElement:() => ({setAttribute(){}}),addEventListener(){}},fetch,AbortController,DOMException,console});
  return {api:window.NRCNewsletter,button,panel};
}
test('newsletter is initially hidden; only strict feature true enables it, with no mail requests', async () => {
  const calls = []; let flag = 'true';
  const f = fixture(async (url,options) => { calls.push([url,options.method]); return {ok:true,status:200,json:async () => ({newsletter:flag,newsletter_workspace:'w'})}; });
  assert.equal(f.api.isEnabled(),false);
  await f.api.refreshAccess(); assert.equal(f.button.hidden,true);
  flag = true; await f.api.refreshAccess(); assert.equal(f.button.hidden,false);
  assert.deepEqual(calls, [['/api/features','GET'],['/api/features','GET']]);
  f.api.clear(); assert.equal(f.api.isEnabled(),false); assert.equal(f.button.hidden,true); assert.equal(f.panel.cleared,true);
});
test('workspace reset aborts pending access and ignores late responses', async () => {
  let finish, signal;
  const f = fixture((url,options) => { signal = options.signal; return new Promise(resolve => finish = resolve); });
  const pending = f.api.refreshAccess(); f.api.clear(); assert.equal(signal.aborted,true);
  finish({ok:true,status:200,json:async () => ({newsletter:true})}); await pending;
  assert.equal(f.api.isEnabled(),false); assert.equal(f.button.hidden,true);
});
test('permission denial keeps feature hidden', async () => {
  const f = fixture(async () => ({ok:false,status:403,json:async () => ({})}));
  await f.api.refreshAccess(); assert.equal(f.api.isEnabled(),false); assert.equal(f.button.hidden,true);
  assert.equal(f.panel.message,'Keine Berechtigung für Newsletter.');
});
test('newsletter only appears in its configured workspace, not another open workspace', async () => {
  const f = fixture(async () => ({ok:true,status:200,json:async () => ({newsletter:true,newsletter_workspace:'another'})}));
  await f.api.refreshAccess();
  assert.equal(f.api.isEnabled(),false);
  assert.equal(f.button.hidden,true);
});
