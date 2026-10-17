// Disposable Go HTTP fixture, matching the nrc-publish browser-test workflow.
// Production main has no fixture switch. No production data or credentials used.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const cwd = dirname(fileURLToPath(import.meta.url));
const scratch = mkdtempSync(join(tmpdir(), 'nrc-tickets-browser-'));
const binary = join(scratch, 'preview.test');
const base = 'http://127.0.0.1:18196';
const auth = { username: 'anna', password: 'fixture-password-only' };
const artifacts = process.env.TICKETS_SCREENSHOTS;
if (artifacts) mkdirSync(artifacts, { recursive: true });
let server, browser;
try {
  execFileSync('go', ['test', '-c', '-o', binary], { cwd, stdio: 'inherit' });
  browser = await chromium.launch();
  const theme = join(scratch, 'theme.css');
  writeFileSync(theme, ':root { --accent:#744b88; --accent-hover:#573766; --header-background:#30223c; --background:#f6f3f8; --text:#282331; --border:#ded5e5; --radius:8px; }');
  for (const branded of [false, true]) {
    let logs = '';
    server = spawn(binary, ['-test.run', '^TestBrowserFixture$', '-test.timeout', '0'], {
      cwd, env: { ...process.env, TMPDIR: scratch, TICKETS_TEST_ADDR: '127.0.0.1:18196', TICKETS_TEST_ORIGIN: base,
        TICKETS_BRAND: branded ? 'Example & Co · Kundenservice' : '',
        TICKETS_THEME_FILE: branded ? theme : '', TICKETS_LOGO_FILE: branded ? resolve(cwd, '../../../logo/favicon.png') : '',
        TICKETS_FOOTER_TEXT: branded ? '© Example & Co · Wir helfen Ihnen weiter.' : '',
        TICKETS_IMPRINT_URL: branded ? 'https://example.org/impressum' : '',
        TICKETS_PRIVACY_URL: branded ? 'https://example.org/datenschutz' : '',
        TICKETS_CONTACT_URL: branded ? 'https://example.org/kontakt' : '', TICKETS_TERMS_URL: '',
      }, stdio: ['ignore', 'pipe', 'pipe'],
    });
    server.stdout.on('data', b => { logs += b; }); server.stderr.on('data', b => { logs += b; });
    let ready = false;
    for (let i = 0; i < 100; i++) {
      try { if ((await fetch(base)).status === 401) { ready = true; break; } } catch {}
      if (server.exitCode !== null) break;
      await new Promise(r => setTimeout(r, 100));
    }
    assert(ready, `Fixture failed: ${logs}`);
    const context = await browser.newContext({ httpCredentials: auth, viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 2 });
    const page = await context.newPage();
    const errors = []; page.on('pageerror', e => errors.push(e.message));
    const shot = async name => { if (artifacts) await page.screenshot({ path: resolve(artifacts, `${name}-images.png`), fullPage: true }); };
    await page.goto(`${base}/new`);
    assert.equal(await page.title(), branded ? 'Example & Co · Kundenservice' : 'Ihr Kundenportal');
    assert.equal(await page.locator('footer').count(), branded ? 1 : 0);
    if (branded) {
      assert(await page.locator('.brand img').evaluate(img => img.complete && img.naturalWidth > 0));
      assert.equal(await page.locator('footer a').count(), 3);
      assert.equal(await page.locator('button').evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(116, 75, 136)');
    }
    await page.getByLabel('Betreff').fill('Rechnungsexport enthält nur die Kopfzeile');
    await page.getByLabel('Ihre Nachricht').fill('Seit dem letzten Update fehlen die Rechnungen im Export. Die CSV-Datei habe ich angehängt.');
    const data = Buffer.from('Rechnungsnummer;Datum;Betrag\r\n');
    const png = Buffer.from(await page.evaluate(() => {
      const canvas = document.createElement('canvas'); canvas.width = 840; canvas.height = 300;
      const c = canvas.getContext('2d');
      c.fillStyle = '#f4f6fa'; c.fillRect(0, 0, 840, 300);
      c.fillStyle = '#123e55'; c.fillRect(0, 0, 840, 64);
      c.fillStyle = '#fff'; c.font = 'bold 24px sans-serif'; c.fillText('Rechnungsexport · Oktober 2026', 24, 42);
      c.fillStyle = '#203247'; c.font = '20px sans-serif'; c.fillText('Rechnungsnummer         Datum                  Betrag', 24, 108);
      c.fillStyle = '#d6e0e7'; c.fillRect(24, 124, 792, 2);
      c.fillStyle = '#a12f38'; c.font = 'bold 22px sans-serif'; c.fillText('Export unvollständig: 0 Datensätze', 24, 180);
      c.fillStyle = '#526575'; c.font = '18px sans-serif'; c.fillText('Erwartet: 42 Rechnungen · Zeitraum: 01.–17. Oktober', 24, 224);
      return canvas.toDataURL('image/png').split(',')[1];
    }), 'base64');
    const choose = async (files, keyboard = false) => {
      const [chooser] = await Promise.all([
        page.waitForEvent('filechooser'),
        keyboard ? page.getByLabel('Dateien hinzufügen', { exact: true }).press('Space') : page.getByLabel('Dateien hinzufügen', { exact: true }).click(),
      ]);
      await chooser.setFiles(files);
    };
    await choose([{ name: 'Rechnungsexport.csv', mimeType: 'text/csv', buffer: data }, { name: 'Export-Screenshot.png', mimeType: 'image/png', buffer: png }]);
    assert.match(await page.locator('#selected-files').textContent(), /2 Dateien ausgewählt: Rechnungsexport.csv, Export-Screenshot.png/);
    await shot(branded ? 'tickets-branded-new' : 'tickets-default-new');
    await page.getByRole('button', { name: 'Anfrage senden' }).click();
    await page.waitForURL('**/tickets/21');
    const link = page.getByRole('link', { name: 'Rechnungsexport.csv', exact: true });
    const response = await context.request.get(base + await link.getAttribute('href'));
    assert.equal(response.status(), 200);
    assert.deepEqual(await response.body(), data);
    assert.match(response.headers()['content-disposition'], /^attachment;/);
    const originalPreview = page.getByRole('img', { name: 'Vorschau: Export-Screenshot.png', exact: true });
    await originalPreview.scrollIntoViewIfNeeded();
    await originalPreview.evaluate(img => img.decode());
    assert.equal(await originalPreview.evaluate(img => img.naturalWidth), 840);
    const previewResponse = await context.request.get(base + await originalPreview.getAttribute('src'));
    assert.equal(previewResponse.headers()['content-type'], 'image/png');
    assert.deepEqual(await previewResponse.body(), png);
    const popupPromise = page.waitForEvent('popup');
    await page.getByRole('link', { name: 'Bild Export-Screenshot.png öffnen', exact: true }).click();
    const popup = await popupPromise;
    await popup.waitForLoadState();
    assert.match(popup.url(), /\?preview=1$/);
    await popup.close();
    await page.getByLabel('Ihre Antwort', { exact: true }).fill('Ergänzend die Diagnose aus unserem Browser.');
    await choose([{ name: 'Browserdiagnose.txt', mimeType: 'text/plain', buffer: Buffer.from('Browserdiagnose: Export liefert null Datensätze.\n') }, { name: 'Antwort-Screenshot.png', mimeType: 'image/png', buffer: png }], true);
    await page.getByRole('button', { name: 'Antwort senden' }).click();
    await page.waitForURL('**/tickets/21');
    await page.getByRole('link', { name: 'Browserdiagnose.txt', exact: true }).waitFor();
    await page.reload();
    assert.equal(await page.getByRole('link', { name: /Rechnungsexport.csv|Browserdiagnose.txt/ }).count(), 2);
    for (const img of await page.locator('.attachment-preview img').all()) {
      await img.scrollIntoViewIfNeeded(); await img.evaluate(img => img.decode());
    }
    assert.equal(await page.locator('.attachment-preview img').count(), 2);
    assert.equal(await page.locator('#selected-files').textContent(), 'Keine Dateien ausgewählt.');
    await shot(branded ? 'tickets-branded-detail' : 'tickets-default-detail');
    assert.equal((await context.request.get(`${base}/tickets/2`)).status(), 404);
    assert.equal((await context.request.get(`${base}/tickets/1/attachments/11/att_0123456789abcdef0123456789abcdef`)).status(), 404);
    await page.setViewportSize({ width: 390, height: 1000 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await shot(branded ? 'tickets-branded-narrow' : 'tickets-default-narrow');
    await page.goto(`${base}/new`);
    await page.getByLabel('Betreff').fill('Anfrage ohne Anlage');
    await page.getByLabel('Ihre Nachricht').fill('Nur Text, kein Anhang ausgewählt.');
    await page.getByRole('button', { name: 'Anfrage senden' }).click();
    await page.waitForURL('**/tickets/23');
    await page.getByLabel('Ihre Antwort', { exact: true }).fill('Auch diese Antwort benötigt keine Anlage.');
    await page.getByRole('button', { name: 'Antwort senden' }).click();
    await page.getByText('Auch diese Antwort benötigt keine Anlage.', { exact: true }).waitFor();
    assert.equal(await page.locator('.attachments a').count(), 0);
    assert.deepEqual(errors, []);
    await context.close();
    if (!branded) {
      const plain = await browser.newContext({ httpCredentials: auth, javaScriptEnabled: false, viewport: { width: 1100, height: 900 }, deviceScaleFactor: 2 });
      const form = await plain.newPage();
      await form.goto(`${base}/new`);
      const input = form.getByLabel('Dateien hinzufügen', { exact: true });
      assert.equal(await input.evaluate(el => getComputedStyle(el).opacity), '1');
      assert.equal(await form.locator('#selected-files').isVisible(), false);
      await form.getByLabel('Betreff').fill('Anfrage ohne JavaScript');
      await form.getByLabel('Ihre Nachricht').fill('Dateien bleiben auch ohne Script auswählbar.');
      await input.setInputFiles({ name: 'Ohne-JavaScript.txt', mimeType: 'text/plain', buffer: data });
      assert.equal(await input.evaluate(el => el.files[0].name), 'Ohne-JavaScript.txt');
      assert.equal(await form.locator('#selected-files').textContent(), '', 'no false empty-selection description without JS');
      if (artifacts) await form.screenshot({ path: resolve(artifacts, 'tickets-no-js-upload.png'), fullPage: true });
      await form.getByRole('button', { name: 'Anfrage senden' }).click();
      await form.waitForURL('**/tickets/25');
      const link = form.getByRole('link', { name: 'Ohne-JavaScript.txt', exact: true });
      const download = await plain.request.get(base + await link.getAttribute('href'));
      assert.deepEqual(await download.body(), data);
      await plain.close();
    }
    const closed = new Promise(r => server.once('exit', r)); server.kill('SIGTERM'); await closed; server = null;
  }
  console.log('PASS: custom file chooser and filenames, original/reply image previews and full-size opening, exact downloads, reload, privacy, default/custom branding and narrow layout');
} finally {
  if (browser) await browser.close();
  if (server?.exitCode === null) { const closed = new Promise(r => server.once('exit', r)); server.kill('SIGTERM'); await closed; }
  rmSync(scratch, { recursive: true, force: true });
}
