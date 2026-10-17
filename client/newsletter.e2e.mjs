// Disposable fake Mailjet + production newsletter UI. Never sends external mail.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {chromium} from 'playwright';

const fixture = spawn(process.execPath, ['client/newsletter-fixture.mjs'], {env:{...process.env,PORT:'18997'}, stdio:['ignore','pipe','inherit']});
let browser;
try {
  await Promise.race([once(fixture.stdout,'data'), once(fixture,'exit').then(() => { throw new Error('newsletter fixture exited'); })]);
  browser = await chromium.launch({headless:true, ...(process.env.CHROME_BIN ? {executablePath:process.env.CHROME_BIN} : {})});
  const page = await browser.newPage({viewport:{width:1440,height:1000},deviceScaleFactor:2});
  const errors = [], mutations = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => {if (request.method() !== 'GET') mutations.push(request.url());});
  await page.goto('http://127.0.0.1:18997');
  await page.locator('.nl-row').click();
  assert.equal(await page.locator('#nlSubject').inputValue(),'Neuigkeiten im Oktober');
  assert.equal(await page.getByRole('button', {name:'Kampagnen 1',pressed:true}).isVisible(),true);
  assert.equal(await page.getByLabel('Einleitung', {exact:true}).inputValue(),'Guten Tag!');
  assert.equal(await page.getByLabel('Inhalt', {exact:true}).inputValue(),'Dies ist ausschließlich eine lokale Demo.');
  assert.equal(await page.locator('#nlSend').isDisabled(),true,'untested campaign cannot send');
  await page.locator('#nlPreview').click();
  await page.locator('#nlFrame').waitFor({state:'visible'});
  assert.match(await page.frameLocator('#nlFrame').locator('body').innerText(),/\{\{var:einleitung\}\}/);
  assert.equal(await page.locator('#nlFrame').getAttribute('sandbox'),'');
  assert.equal(mutations.filter(url => /\/(send|test|invite)$/.test(url)).length,0,'opening and preview never mail');

  const external = [];
  // Chromium may emit a request event even for a CSP-blocked frame reload.
  // Routing runs only for requests that passed CSP and would reach the network.
  await page.route('https://tracker.invalid/**', route => {external.push(route.request().url()); return route.abort();});
  await page.route('**/campaigns/1/preview', route => route.fulfill({json:{html:'<script>parent.previewPwned=true</script><img src="https://tracker.invalid/pixel" onerror="parent.previewPwned=true"><p>Isolierte Vorlage</p>',text:''}}));
  await page.locator('#nlPreview').click();
  await page.frameLocator('#nlFrame').getByText('Isolierte Vorlage').waitFor();
  assert.equal(await page.evaluate(() => window.previewPwned),undefined,'template cannot execute script in the workspace');
  assert.deepEqual(external,[],'template preview cannot load tracking resources');
  await page.unroute('**/campaigns/1/preview');

  await page.locator('#nlSubject').fill('Freigabe Oktober');
  await page.getByLabel('Einleitung', {exact:true}).fill('Liebe Kunden,\nwillkommen!');
  await page.getByLabel('Inhalt', {exact:true}).fill('Zwei Neuigkeiten für Oktober.');
  assert.equal(await page.locator('#nlTest').isDisabled(),true,'unsaved changes cannot be tested');
  const savedRequest = page.waitForRequest(request => request.method() === 'PUT' && request.url().endsWith('/campaigns/1'));
  await page.locator('#nlSave').click();
  assert.deepEqual((await savedRequest).postDataJSON().variables, {einleitung:'Liebe Kunden,\nwillkommen!',inhalt:'Zwei Neuigkeiten für Oktober.'},'readable labels and multiline editing preserve exact Mailjet keys');
  await page.locator('#nlTest:enabled').waitFor();
  await page.locator('#nlRefresh').click();
  await page.waitForFunction(() => !document.querySelector('#nlRefresh').disabled);
  assert.equal(await page.locator('#nlSubject').inputValue(),'Freigabe Oktober','refresh preserves the form');
  await page.locator('#nlTestEmail').fill('test@example.invalid');
  await page.locator('#nlTest').click();
  assert.equal(await page.getByRole('dialog', {name:'Testmail senden'}).isVisible(),true);
  await page.keyboard.press('Escape');
  await page.locator('#newsletterDialog').waitFor({state:'detached'});
  assert.equal(await page.locator('#nlTest').evaluate(node => node === document.activeElement),true,'cancel restores focus to the opener');
  await page.locator('#nlTest').click();
  assert.equal(mutations.filter(url => url.endsWith('/test')).length,0,'test requires separate confirmation');
  let releaseTest, startedTest;
  const testGate = new Promise(resolve => releaseTest = resolve);
  const testStarted = new Promise(resolve => startedTest = resolve);
  await page.route('**/campaigns/1/test', async route => {startedTest(); await testGate; await route.continue();});
  await page.locator('#newsletterDialog [type=submit]').click();
  await testStarted;
  await page.keyboard.press('Escape');
  assert.equal(await page.getByRole('dialog', {name:'Testmail senden'}).isVisible(),true,'an in-progress send cannot be dismissed as if cancelled');
  releaseTest();
  await page.locator('#newsletterDialog').waitFor({state:'detached'});
  await page.unroute('**/campaigns/1/test');
  assert.equal(await page.locator('#nlTest').evaluate(node => node === document.activeElement),true,'successful test restores focus after enabling controls');
  assert.equal(await page.locator('#nlSend').isEnabled(),true);
  await page.locator('#nlSend').click();
  await page.locator('#nlConfirmation').fill('Falscher Betreff');
  await page.locator('#newsletterDialog [type=submit]').click();
  await page.waitForFunction(() => document.querySelector('#nlDialogStatus').textContent.includes('stimmt nicht'));
  assert.equal(mutations.filter(url => url.endsWith('/send')).length,0,'wrong subject must not send');
  await page.locator('#nlConfirmation').fill('Freigabe Oktober');
  await page.locator('#newsletterDialog [type=submit]').click();
  await page.locator('#newsletterDialog').waitFor({state:'detached'});
  assert.match(await page.locator('#nlCampaignState').innerText(),/Versendet/);
  assert.equal(await page.locator('#nlSave').isDisabled(),true);
  assert.equal(await page.getByLabel('Inhalt', {exact:true}).isDisabled(),true);
  assert.equal(await page.locator('#nlSend').isDisabled(),true,'finished campaigns cannot resend');

  await page.locator('#nlSubscriberTab').click();
  assert.equal(await page.getByRole('button', {name:'Kontakte & Einwilligungen 5',pressed:true}).isVisible(),true);
  assert.match(await page.locator('[data-contact-id="1"]').innerText(),/Firma: Beispiel GmbH · Muster Software KG/);
  assert.match(await page.locator('[data-contact-id="5"]').innerText(),/Keine Zuordnung/);
  await page.getByLabel('Kontakte suchen').fill('Muster Software');
  assert.equal(await page.locator('#nlContactCount').innerText(),'2 / 5 Kontakte');
  await page.evaluate(() => { window.NRCInspector = {openEntity(ref) { window.openedNewsletterContact = {...ref,roomId:String(ref.roomId),id:String(ref.id)}; }}; });
  const beforeOpen = mutations.length;
  await page.getByRole('button',{name:'Kontakt Anna Beispiel öffnen',exact:true}).click();
  assert.deepEqual(await page.evaluate(() => window.openedNewsletterContact),{roomId:'0',type:'contact',id:'1',subview:'read'});
  assert.equal(mutations.length,beforeOpen,'opening a contact never invites or unsubscribes');
  await page.route('**/api/features', route => route.fulfill({json:{customers:false,newsletter:true,newsletter_workspace:'demo'}}));
  await page.evaluate(() => NRCNewsletter.refreshAccess());
  assert.equal(await page.getByRole('button',{name:'Kontakt Anna Beispiel öffnen',exact:true}).isDisabled(),true,'newsletter access does not imply customer access');
  assert.equal(await page.locator('[data-invite="0"]').isEnabled(),true,'newsletter actions retain their independent permission');
  await page.unroute('**/api/features');
  await page.evaluate(() => NRCNewsletter.refreshAccess());
  assert.equal(await page.getByRole('button',{name:'Kontakt Anna Beispiel öffnen',exact:true}).isEnabled(),true);
  await page.getByLabel('Kontakte suchen').fill('Clara');
  assert.equal(await page.locator('#nlContactCount').innerText(),'1 / 5 Kontakte');
  assert.equal(await page.locator('#nlContacts .nl-contact').count(),1);
  await page.getByLabel('Kontakte suchen').fill('');
  await page.locator('[data-invite="0"]').click();
  await page.locator('#newsletterDialog [type=submit]').click();
  await page.waitForFunction(() => document.querySelector('#nlDialogStatus').textContent.includes('Quelle'));
  assert.equal(mutations.filter(url => url.endsWith('/invite')).length,0);
  await page.locator('#nlConfirmation').fill('Individuelle Anfrage per Supportgespräch');
  await page.locator('#newsletterDialog [type=submit]').click();
  await page.locator('#newsletterDialog').waitFor({state:'detached'});
  assert.match(await page.locator('#nlContacts .nl-contact').first().innerText(),/Bestätigung ausstehend/);
  assert.equal(await page.evaluate(() => document.activeElement.closest('[data-contact-id]')?.dataset.contactId),'1','successful invitation restores focus to the refreshed contact row');
  assert.equal(mutations.filter(url => url.endsWith('/test')).length,1);
  assert.equal(mutations.filter(url => url.endsWith('/send')).length,1);
  assert.equal(mutations.filter(url => url.endsWith('/invite')).length,1);

  for (const theme of ['light','dark']) {
    await page.evaluate(theme => document.documentElement.dataset.theme=theme,theme);
    for (const width of [1440,900,390]) {
      await page.setViewportSize({width,height:1000});
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),true,`${theme} ${width}: no horizontal overflow`);
      await page.locator('#nlCampaignTab').click();
      assert.equal(await page.locator('#nlSubject').isVisible(),true);
      assert.equal(await page.locator('#nlCampaignTab').getAttribute('aria-pressed'),'true');
      assert.equal(await page.evaluate(() => document.querySelector('#nlCampaigns').scrollWidth <= document.querySelector('#nlCampaigns').clientWidth),true,'campaign panes fit the available width');
      await page.locator('#nlSubscriberTab').click();
      assert.equal(await page.locator('#nlSearch').isVisible(),true);
      assert.equal(await page.locator('#nlCampaignTab').getAttribute('aria-pressed'),'false');
    }
  }
  await page.locator('#nlNew').click();
  assert.equal(await page.locator('#nlCampaignTab').getAttribute('aria-pressed'),'true','new campaign opens its editor even from the subscriber register');
  assert.equal(await page.locator('#nlHeading').innerText(),'Neue Kampagne');
  assert.equal(await page.locator('#nlSubject').inputValue(),'');
  assert.equal(await page.locator('#nlPreviewEmpty').isVisible(),true);
  await page.locator('#nlTitle').fill('Konflikttest');
  await page.locator('#nlSubject').fill('Lokaler Betreff');
  await page.getByLabel('Inhalt', {exact:true}).fill('Ungespeicherter Text\nbleibt erhalten.');
  await page.evaluate(() => window.NRCNewsletter.disconnect());
  assert.equal(await page.getByLabel('Inhalt', {exact:true}).inputValue(),'Ungespeicherter Text\nbleibt erhalten.');
  assert.equal(await page.locator('#nlSave').isDisabled(),true);
  const beforeOffline = mutations.length;
  await page.locator('#nlSubscriberTab').click();
  await page.getByLabel('Kontakte suchen').fill('Ben');
  assert.equal(await page.locator('#nlContacts button:enabled').count(),0,'filtering cannot re-enable disconnected contact actions');
  await page.locator('[data-invite="0"]').dispatchEvent('click');
  await page.locator('[data-optout="0"]').dispatchEvent('click');
  assert.equal(await page.locator('#newsletterDialog').count(),0,'disconnected actions cannot open a send dialog');
  await page.route('**/api/features', route => route.fulfill({status:503,json:{error:'offline'}}));
  await page.evaluate(() => window.NRCNewsletter.refreshAccess());
  await page.getByLabel('Kontakte suchen').fill('Anna');
  assert.equal(await page.locator('#nlContacts button:enabled').count(),0);
  assert.equal(mutations.length,beforeOffline,'filtering and failed revalidation never mutate newsletter state');
  assert.equal(await page.locator('#nlSave').isDisabled(),true,'failed revalidation cannot enable sending');
  assert.equal(await page.getByLabel('Inhalt', {exact:true}).inputValue(),'Ungespeicherter Text\nbleibt erhalten.');
  await page.unroute('**/api/features');
  await page.locator('#nlRefresh').click();
  await page.waitForFunction(() => !document.querySelector('#nlSave').disabled);
  assert.equal(await page.locator('#nlSave').isEnabled(),true);
  assert.equal(await page.getByLabel('Inhalt', {exact:true}).inputValue(),'Ungespeicherter Text\nbleibt erhalten.','same-workspace reconnect preserves unsaved form values');
  await page.locator('#nlCampaignTab').click();

  let concurrentEdit = false;
  await page.route('**/newsletter/api/state', async route => {
    if (!concurrentEdit) {
      concurrentEdit = true;
      const changed = await page.request.put('http://127.0.0.1:18997/newsletter/api/campaigns/2', {data:{revision:1,title:'Parallel geändert',template_id:'demo',subject:'Anderer Betreff',variables:{inhalt:'Extern'}}});
      assert.equal(changed.status(),200);
    }
    await route.continue();
  });
  await page.locator('#nlSave').click();
  await page.waitForFunction(() => document.querySelector('#nlStatus').textContent.includes('extern geändert'));
  assert.equal(await page.locator('#nlSubject').inputValue(),'Lokaler Betreff');
  assert.equal(await page.locator('#nlTest').isDisabled(),true,'a newer server revision cannot silently validate stale form values');
  assert.match(await page.locator('#nlRevision').innerText(),/^R1 /);
  const staleSave = page.waitForRequest(request => request.method() === 'PUT' && request.url().endsWith('/campaigns/2'));
  await page.locator('#nlSave').click();
  assert.equal((await staleSave).postDataJSON().revision,1,'stale content stays bound to its actual base revision');
  await page.waitForFunction(() => document.querySelector('#nlStatus').textContent.includes('Versionskonflikt'));
  await page.unroute('**/newsletter/api/state');

  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', {name:/Parallel geändert/}).click();
  await page.locator('#nlTestEmail').fill('conflict@example.invalid');
  await page.route('**/newsletter/api/state', async route => {
    const changed = await page.request.put('http://127.0.0.1:18997/newsletter/api/campaigns/2', {data:{revision:2,title:'Erneut geändert',template_id:'demo',subject:'Dritter Betreff',variables:{inhalt:'Noch neuer'}}});
    assert.equal(changed.status(),200);
    await route.continue();
  });
  await page.locator('#nlTest').click();
  await page.locator('#newsletterDialog [type=submit]').click();
  await page.locator('#newsletterDialog').waitFor({state:'detached'});
  assert.equal(await page.locator('#nlPreview').isDisabled(),true);
  assert.equal(await page.locator('#nlRefresh').evaluate(node => node === document.activeElement),true,'conflict after successful test focuses an enabled fallback');
  await page.unroute('**/newsletter/api/state');

  await page.reload();
  await page.locator('#nlTitle:enabled').waitFor();
  const selectVisible = async (id, name) => {
    await page.locator('nrc-select').filter({has:page.locator(id)}).locator('button').click();
    await page.getByRole('listbox').getByRole('option',{name,exact:true}).click();
  };
  await selectVisible('#nlKind','Serviceinformation · ohne Werbung');
  await page.locator('#nlTitle').fill('Wartungsinformation');
  await page.locator('#nlSubject').fill('Wartung am Sonntag');
  await page.locator('#nlServiceReason').fill('Notwendige Unterbrechung für Sicherheitsupdate');
  await page.locator('#nlCustomers input[value="101"]').check();
  await page.locator('#nlSave').click();
  await page.locator('#nlReviewAudience:enabled').waitFor();
  await page.locator('#nlReviewAudience').click();
  await page.waitForFunction(() => document.querySelector('#nlEligible').textContent === '2');
  assert.match(await page.locator('#nlAudienceNotice').innerText(),/1 Kunden/);
  assert.equal(await page.locator('#nlSend').isDisabled(),true,'review does not replace a test');
  await selectVisible('#nlScope','Alle nicht archivierten Kunden');
  assert.match(await page.locator('#nlRevision').innerText(),/UNGESPEICHERT/);
  assert.equal(await page.locator('#nlReviewAudience').isDisabled(),true);
  assert.equal(await page.locator('#nlCustomers').isHidden(),true);
  await page.locator('#nlSave').click();
  await page.locator('#nlTest:enabled').waitFor();
  await page.locator('#nlTestEmail').fill('service-test@example.invalid');
  await page.locator('#nlTest').click();
  await page.locator('#newsletterDialog [type=submit]').click();
  await page.locator('#newsletterDialog').waitFor({state:'detached'});
  assert.equal(await page.locator('#nlSend').isDisabled(),true,'fresh audience review required');
  await page.locator('#nlReviewAudience').click();
  await page.locator('#nlSend:enabled').waitFor();
  assert.equal(await page.locator('#nlEligible').innerText(),'3');
  assert.match(await page.locator('#nlAudienceNotice').innerText(),/Muster Software KG/);
  await selectVisible('#nlScope','Ausgewählte Kunden');
  assert.match(await page.locator('#nlRevision').innerText(),/UNGESPEICHERT/);
  assert.equal(await page.locator('#nlSend').isDisabled(),true,'visible scope change invalidates tested/reviewed draft');
  assert.equal(await page.locator('#nlTest').isDisabled(),true);
  await selectVisible('#nlScope','Alle nicht archivierten Kunden');
  await page.locator('#nlSave').click();
  await page.locator('#nlTest:enabled').waitFor();
  await page.locator('#nlTest').click();
  await page.locator('#newsletterDialog [type=submit]').click();
  await page.locator('#newsletterDialog').waitFor({state:'detached'});
  await page.locator('#nlReviewAudience').click();
  await page.locator('#nlSend:enabled').waitFor();
  for (const theme of ['light','dark']) {
    await page.evaluate(t => document.documentElement.dataset.theme = t,theme);
    for (const width of [1440,900,390]) {
      await page.setViewportSize({width,height:1000});
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),true,`service ${theme} ${width}: no horizontal overflow`);
    }
  }
  await page.setViewportSize({width:1440,height:1000});
  await page.locator('#nlSend').click();
  assert.match(await page.locator('#nlDialogMessage').innerText(),/3 Kunden.*Muster Software KG/);
  const serviceSend = page.waitForRequest(r=>r.url().endsWith('/send'));
  await page.locator('#nlConfirmation').fill('Wartung am Sonntag');
  await page.locator('#newsletterDialog [type=submit]').click();
  assert.equal((await serviceSend).postDataJSON().audience_token,'fake-audience-token');
  await page.locator('#newsletterDialog').waitFor({state:'detached'});
  assert.match(await page.locator('#nlRecipients').innerText(),/demo4@example.invalid/,'service includes unsubscribed designated contact');
  await page.locator('#nlSubscriberTab').click();
  assert.equal(await page.locator('#nlSubscribers input[type=file]').count(),0,'consent import is CLI/API-only');
  assert.equal(await page.getByRole('button',{name:/Import prüfen|Einwilligungen übernehmen/}).count(),0);
  assert.equal(mutations.filter(url => url.endsWith('/consents/import')).length,0);
  await page.locator('[data-contact-id="3"] summary').click();
  assert.match(await page.locator('[data-contact-id="3"] details').innerText(),/Produktnewsletter.*DOI export #123/,'existing imported proof remains readable');

  await page.route('**/api/features', route => route.fulfill({status:403,json:{error:'denied'}}));
  await page.evaluate(() => window.NRCNewsletter.refreshAccess());
  assert.equal(await page.locator('#nlForm').count(),0,'permission denial clears private draft content');
  assert.equal(await page.locator('#newsletterBtn').isHidden(),true);
  await page.unroute('**/api/features');
  await page.reload();
  await page.locator('#nlTitle').fill('Nur für diesen Workspace');
  await page.route('**/api/features', route => route.fulfill({json:{newsletter:true,newsletter_workspace:'another'}}));
  await page.evaluate(() => window.NRCNewsletter.refreshAccess());
  assert.equal(await page.locator('#nlForm').count(),0,'workspace mismatch must not retain a private draft');
  assert.deepEqual(errors,[]);
  console.log('Newsletter browser: labels/keys, tabs/counts, modal focus/Escape, save/test/send/DOI/preview, reconnect preservation, denial/workspace clearing and concurrent-revision conflict passed; light/dark at 1440/900/390. No external mail.');
} finally {
  await browser?.close();
  fixture.kill('SIGTERM');
  await once(fixture,'exit');
}
