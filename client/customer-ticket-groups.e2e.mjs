// Real, disposable NRC stack: test/customer-workspace-dev.mjs. Never production.
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error('Set NRC_CUSTOMERS_TEST_URL to the disposable customer fixture');
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: 'block' });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(`${url}/#workspace=ticket-groups-${Date.now()}`);
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  const ids = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const create = async (type, title, extra = {}, body = '') => (await rpc(o => NRCAssets.sendCreateAsset(0n, type, 0, 0n, JSON.stringify({ version: 1, title, ...extra }), body, 0, o))).asset;
    const company = await create(8, 'Nordwerk GmbH', { opaque: { keep: true } }, 'Company body must survive');
    const ada = await create(9, 'Ada Berger'), bea = await create(9, 'Bea Sommer'), outsider = await create(9, 'Other company contact');
    await rpc(o => NRCEdges.sendCreateEdge(0n, 1, ada.assetId, 1, company.assetId, 7, o));
    await rpc(o => NRCEdges.sendCreateEdge(0n, 1, company.assetId, 1, bea.assetId, 7, o));
    NRCCustomers.openCompany(company);
    return Object.fromEntries(Object.entries({ company: company.assetId, ada: ada.assetId, bea: bea.assetId, outsider: outsider.assetId }).map(([k,v]) => [k,String(v)]));
  });
  await page.locator('nav [data-customer-tab="contacts"]').click();
  await page.click('#customerTicketGroupNew');
  const dialog = page.locator('dialog[open]');
  await dialog.getByLabel('Group name').fill('Technik');
  assert.equal(await dialog.locator(`[data-group-contact="${ids.outsider}"]`).count(), 0);
  await dialog.locator(`[data-group-contact="${ids.ada}"]`).check();
  await dialog.locator(`[data-group-contact="${ids.bea}"]`).check();
  await dialog.getByRole('button', { name: 'SAVE GROUP', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('dialog[open]'));
  await page.waitForFunction(() => document.querySelector('[data-ticket-group]'));
  const read = () => page.evaluate(async id => {
    const { asset } = await new Promise((resolve,reject) => NRCAssets.requestAsset(0n,BigInt(id),{force:true,onSuccess:resolve,onError:reject}));
    return { metadata: JSON.parse(asset.preview), body: asset.payload };
  }, ids.company);
  const saved = await read(), groupId = saved.metadata.ticket_groups[0].id;
  assert.deepEqual(saved.metadata.ticket_groups[0], { id: groupId, name: 'Technik', contact_ids: [ids.ada,ids.bea] });
  assert.deepEqual(saved.metadata.opaque, { keep: true });
  assert.equal(saved.body, 'Company body must survive');
  // Ordinary company edits must not erase sharing configuration or its body.
  await page.evaluate(id => NRCCustomers.openRecord('company', id, { subview: 'edit' }), ids.company);
  await page.locator('#customerFields input[name="city"]').fill('Hamburg');
  await page.click('#customerSave');
  await page.waitForFunction(() => !document.getElementById('customerSave'));
  await page.click('#customerClose');
  const edited = await read();
  assert.equal(edited.metadata.city, 'Hamburg');
  assert.deepEqual(edited.metadata.ticket_groups, saved.metadata.ticket_groups);
  assert.equal(edited.body, 'Company body must survive');
  await page.locator(`[data-ticket-group="${groupId}"]`).click();
  await dialog.getByLabel('Group name').fill('Projektteam');
  await dialog.locator(`[data-group-contact="${ids.bea}"]`).uncheck();
  await dialog.getByRole('button', { name: 'SAVE GROUP', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('dialog[open]'));
  assert.deepEqual((await read()).metadata.ticket_groups, [{ id: groupId, name: 'Projektteam', contact_ids: [ids.ada] }]);
  // A concurrent company edit cannot be overwritten by a stale group dialog.
  await page.locator(`[data-ticket-group="${groupId}"]`).click();
  await dialog.getByLabel('Group name').fill('Stale name');
  await page.evaluate(async id => {
    const rpc = send => new Promise((resolve,reject) => send({onSuccess:resolve,onError:reject}));
    const {asset} = await rpc(o=>NRCAssets.requestAsset(0n,BigInt(id),o));
    await rpc(o=>NRCTransactions.sendAssetMetadataPatch(asset,JSON.stringify({...JSON.parse(asset.preview),city:'Concurrent city'}),null,o));
  }, ids.company);
  await dialog.getByRole('button', { name: 'SAVE GROUP', exact: true }).click();
  await dialog.getByRole('alert').filter({ hasText: 'Transaction rejected' }).waitFor();
  assert.equal(await dialog.getByLabel('Group name').inputValue(), 'Stale name');
  assert.equal((await read()).metadata.city, 'Concurrent city');
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  const discard = page.getByRole('dialog', { name: 'UNSAVED CHANGES', exact: true });
  await discard.getByRole('button', { name: 'Cancel', exact: true }).click();
  assert.equal(await dialog.getByLabel('Group name').inputValue(), 'Stale name', 'cancel preserves the dirty editor');
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await discard.getByRole('button', { name: 'Discard', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('dialog[open]'));
  await page.locator(`[data-ticket-group="${groupId}"]`).click();
  await dialog.getByLabel('Group name').waitFor();
  await dialog.getByRole('button', { name: 'DELETE GROUP', exact: true }).click();
  await page.locator('dialog[open]').last().getByRole('button', { name: 'Confirm', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('dialog[open]'));
  assert.deepEqual((await read()).metadata.ticket_groups, []);
  assert.deepEqual(errors, []);
  console.log('Ticket groups E2E passed: company-scoped selection, create/rename/revoke/delete, preserved body/metadata, stale-save rejection.');
} finally { await browser.close(); }
