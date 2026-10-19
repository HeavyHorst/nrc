// Run against the disposable test/customer-workspace-dev.mjs fixture only.
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error('Set NRC_CUSTOMERS_TEST_URL to the disposable fixture');
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: 'block' });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${url}/#workspace=customer-loading-${Date.now()}`);
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  await page.evaluate(() => new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 8, 0, 0n,
    JSON.stringify({ version: 1, title: 'Loading test company', city: 'Berlin' }), '', 0,
    { onSuccess: resolve, onError: reject })));
  // Observe actual DOM mutations, including transient states gone by the next frame.
  await page.evaluate(() => {
    window.loadingMutations = [];
    new MutationObserver(() => loadingMutations.push(document.getElementById('customersPanel').textContent))
      .observe(document.getElementById('customersPanel'), { childList: true, subtree: true, characterData: true });
  });
  await page.click('#customersBtn');
  await page.waitForFunction(() => document.querySelector('.customer-identity') &&
    document.getElementById('customerRecord').getAttribute('aria-busy') === 'false');
  assert.equal(await page.evaluate(() => loadingMutations.some(text => text.includes('Select a company to view'))), false);

  for (const theme of ['light', 'dark']) {
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => document.documentElement.setAttribute('data-theme', theme), theme);
      const state = await page.evaluate(async () => {
        const list = document.getElementById('customersList');
        const record = document.getElementById('customerRecord');
        const previousList = list.innerHTML;
        const previousRecord = record.innerHTML;
        const request = NRCAssets.requestCustomerPage;
        let release;
        NRCAssets.requestCustomerPage = (...args) => new Promise(resolve => { release = () => resolve(request(...args)); });
        const reload = NRCCustomers.reload();
        await Promise.resolve();
        const result = {
          listPreserved: list.innerHTML === previousList,
          recordPreserved: record.innerHTML === previousRecord,
          busy: list.getAttribute('aria-busy'), inert: list.inert && record.inert,
          reviewFlash: list.textContent.includes('Loading contact review queue'),
        };
        NRCAssets.requestCustomerPage = request;
        release();
        await reload;
        return result;
      });
      assert.deepEqual(state, { listPreserved: true, recordPreserved: true, busy: 'true', inert: true, reviewFlash: false });
      await page.waitForFunction(() => document.getElementById('customerRecord').getAttribute('aria-busy') === 'false');
    }
  }
  // A genuinely slow read still exposes feedback, then recovers to real content.
  await page.evaluate(() => {
    const request = NRCAssets.requestCustomerPage;
    NRCAssets.requestCustomerPage = (...args) => new Promise(resolve => {
      window.releaseCustomerPage = () => { NRCAssets.requestCustomerPage = request; resolve(request(...args)); };
    });
    NRCCustomers.reload();
  });
  await page.waitForFunction(() => document.getElementById('customersList').textContent.includes('Loading customer register'));
  assert.equal(await page.locator('#customerRecord').getAttribute('aria-busy'), 'true');
  assert.equal(await page.locator('.customer-identity').count(), 1);
  await page.evaluate(() => releaseCustomerPage());
  await page.waitForFunction(() => document.getElementById('customerRecord').getAttribute('aria-busy') === 'false');
  assert.equal(await page.locator('[data-company]').count(), 1);
  assert.deepEqual(errors, []);
  console.log('PASS: first open, fast reload DOM preservation, busy/inert guards, slow feedback and recovery; both themes at 1440/390px');
} finally {
  await browser.close();
}
