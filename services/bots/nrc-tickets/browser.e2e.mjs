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
async function signIn(page, path = '') {
  await page.goto(`${base}${path}`);
  await page.getByLabel('Benutzername').fill(auth.username);
  await page.getByLabel('Passwort').fill(auth.password);
  await page.getByRole('button', { name: 'Anmelden' }).click();
  await page.getByRole('button', { name: 'Abmelden' }).waitFor();
}
async function portalGet(context, url) {
  // Playwright's HTTP client doesn't send Secure cookies on HTTP loopback,
  // unlike Chromium. Reuse the cookie Chromium obtained through the form.
  const cookie = (await context.cookies()).find(c => c.name === '__Host-nrc-ticket-session');
  assert(cookie);
  return context.request.get(url, { headers: { Cookie: `${cookie.name}=${cookie.value}` }, maxRedirects: 0 });
}
const artifacts = process.env.TICKETS_SCREENSHOTS;
if (artifacts) mkdirSync(artifacts, { recursive: true });
let server, browser;
try {
  execFileSync('go', ['test', '-c', '-o', binary], { cwd, stdio: 'inherit' });
  browser = await chromium.launch();
  const theme = join(scratch, 'theme.css');
  writeFileSync(theme, ':root { --accent:#744b88; --accent-hover:#573766; --header-background:#30223c; --background:#f6f3f8; --text:#282331; --border:#ded5e5; --radius:8px; }');
  for (const branded of [false, true, 'team', 'password']) {
    let logs = '';
    server = spawn(binary, ['-test.run', '^TestBrowserFixture$', '-test.timeout', '0'], {
      cwd, env: { ...process.env, TMPDIR: scratch, TICKETS_TEST_ADDR: '127.0.0.1:18196', TICKETS_TEST_ORIGIN: base,
        TICKETS_TEST_SHARING: branded === 'team' ? '1' : '',
        TICKETS_TEST_PASSWORD: branded === 'password' ? '1' : '',
        TICKETS_BRAND: branded === 'team' ? 'Antares Kundenportal' : branded ? 'Example & Co · Kundenservice' : '',
        TICKETS_THEME_FILE: typeof branded === 'string' ? resolve(cwd, '../../../docker/branding/antares.css') : branded ? theme : '',
        TICKETS_LOGO_FILE: typeof branded === 'string' ? resolve(cwd, '../../../docker/branding/antares-logo.png') : branded ? resolve(cwd, '../../../logo/favicon.png') : '',
        TICKETS_FOOTER_TEXT: branded === true ? '© Example & Co · Wir helfen Ihnen weiter.' : '',
        TICKETS_IMPRINT_URL: branded ? 'https://example.org/impressum' : '',
        TICKETS_PRIVACY_URL: branded ? 'https://example.org/datenschutz' : '',
        TICKETS_CONTACT_URL: branded ? 'https://example.org/kontakt' : '', TICKETS_TERMS_URL: '',
      }, stdio: ['ignore', 'pipe', 'pipe'],
    });
    server.stdout.on('data', b => { logs += b; }); server.stderr.on('data', b => { logs += b; });
    let ready = false;
    for (let i = 0; i < 100; i++) {
      try { if ((await fetch(`${base}/health`)).status === 200) { ready = true; break; } } catch {}
      if (server.exitCode !== null) break;
      await new Promise(r => setTimeout(r, 100));
    }
    assert(ready, `Fixture failed: ${logs}`);
    const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 2 });
    const page = await context.newPage();
    const errors = []; page.on('pageerror', e => errors.push(e.message));
    const shot = async name => { if (artifacts) await page.screenshot({ path: resolve(artifacts, `${name}-images.png`), fullPage: true }); };
    await signIn(page);
    if (branded === 'password') {
      const other = await browser.newPage();
      await signIn(other);
      await page.getByRole('link', { name: 'Mein Konto' }).click();
      await page.getByRole('heading', { name: 'Mein Konto' }).waitFor();
      assert.deepEqual(await page.locator('.profile-group h3').allTextContents(), ['Technik', 'Projektteam']);
      await shot('profile-desktop');
      await page.setViewportSize({ width: 390, height: 900 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await shot('profile-mobile');
      await page.setViewportSize({ width: 1440, height: 1100 });
      await page.getByRole('link', { name: 'Passwort ändern' }).click();
      await page.getByRole('heading', { name: 'Passwort ändern' }).waitFor();
      await shot('password-desktop');
      await page.setViewportSize({ width: 390, height: 900 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await shot('password-mobile');
      const newPassword = 'replacement-fixture-passphrase';
      const change = async (current, repeat = newPassword) => {
        await page.getByLabel('Aktuelles Passwort', { exact: true }).fill(current);
        await page.getByLabel('Neues Passwort', { exact: true }).fill(newPassword);
        await page.getByLabel('Neues Passwort wiederholen', { exact: true }).fill(repeat);
        return (await Promise.all([
          page.waitForResponse(r => r.request().method() === 'POST' && r.url().endsWith('/konto/passwort')),
          page.getByRole('button', { name: 'Passwort ändern' }).click(),
        ]))[0];
      };
      assert.equal((await change(auth.password, 'different-fixture-passphrase')).status(), 400);
      assert.equal((await change('wrong-fixture-password')).status(), 400);
      await page.getByRole('alert').filter({ hasText: 'Das aktuelle Passwort ist falsch.' }).waitFor();
      await shot('password-error');
      assert.equal((await change(auth.password)).status(), 303);
      await page.getByRole('status').filter({ hasText: 'Passwort geändert' }).waitFor();
      await shot('password-changed');
      await other.reload();
      await other.getByRole('heading', { name: 'Anmelden' }).waitFor();
      await page.getByLabel('Benutzername').fill(auth.username);
      await page.getByLabel('Passwort', { exact: true }).fill(auth.password);
      await page.getByRole('button', { name: 'Anmelden' }).click();
      await page.getByText('Benutzername oder Passwort ist falsch.').waitFor();
      await page.getByLabel('Benutzername').fill(auth.username);
      await page.getByLabel('Passwort', { exact: true }).fill(newPassword);
      await page.getByRole('button', { name: 'Anmelden' }).click();
      await page.getByRole('heading', { name: 'Meine Anfragen' }).waitFor();
      assert.deepEqual(errors, []);
      await other.close();
      await context.close();
      const closed = new Promise(r => server.once('exit', r)); server.kill('SIGTERM'); await closed; server = null;
      continue;
    }
    if (branded === 'team') {
      await page.getByRole('link', { name: 'Mein Konto' }).click();
      await page.getByRole('link', { name: 'Teamanfragen ansehen' }).click();
      assert.equal(await page.getByLabel('Sichtbarkeit').inputValue(), 'team');
      assert.doesNotMatch(await page.locator('table').textContent(), /Meine Anfrage/);
      await page.getByRole('link', { name: 'Meine Anfragen', exact: true }).click();
      const teamTicket = page.getByRole('link', { name: 'Rechnungsexport unvollständig', exact: true });
      await teamTicket.waitFor();
      assert.match(await page.locator('table').textContent(), /Team/);
      assert.match(await page.locator('table').textContent(), /Meine Anfrage/);
      assert.doesNotMatch(await page.locator('table').textContent(), /Ticket 3|Ticket 4|Ticket 5/);
      assert.match(await page.locator('tbody tr').first().textContent(), /Meine Rechnung/);
      await shot('tickets-team-list');
      await page.setViewportSize({ width: 390, height: 1000 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await shot('tickets-team-list-narrow');
      await page.setViewportSize({ width: 1440, height: 1100 });
      await page.getByLabel('Sortierung').selectOption('oldest');
      await page.getByRole('button', { name: 'Filtern' }).click();
      assert.match(await page.locator('tbody tr').first().textContent(), /Rechnungsexport unvollständig/);
      await page.getByRole('link', { name: 'Erledigt', exact: true }).click();
      await page.getByRole('heading', { name: 'Keine passenden Anfragen' }).waitFor();
      await shot('tickets-filter-empty');
      await page.getByRole('link', { name: 'Filter zurücksetzen' }).click();
      await page.getByLabel('Suche', { exact: true }).fill('UNVOLLSTÄNDIG');
      await page.getByRole('button', { name: 'Filtern' }).click();
      assert.equal(await page.locator('tbody tr').count(), 1);
      await teamTicket.waitFor();
      await page.getByRole('link', { name: 'Anzeigen' }).click();
      assert.equal(await page.locator('tbody tr').count(), 1);
      await page.getByLabel('Suche', { exact: true }).fill('#2');
      await page.getByLabel('Sichtbarkeit').selectOption('team');
      await page.getByRole('button', { name: 'Filtern' }).click();
      await teamTicket.click();
      await page.getByRole('heading', { name: /Teamanfrage von/ }).waitFor();
      assert.equal(await page.locator('.ticket-heading .ticket-status').innerText(), 'Ihre Antwort wird erwartet');
      assert.equal(await page.locator('.ticket-aside .ticket-status').count(), 0);
      assert.doesNotMatch(await page.locator('main').textContent(), /INTERNAL_ONLY_DIAGNOSIS/);
      await page.getByRole('link', { name: 'Zur Anfragenliste' }).click();
      assert.equal(await page.getByLabel('Suche', { exact: true }).inputValue(), '#2');
      assert.equal(await page.getByLabel('Sichtbarkeit').inputValue(), 'team');
      await teamTicket.click();
      await context.grantPermissions(['clipboard-read', 'clipboard-write']);
      await page.getByRole('button', { name: 'Link zur Anfrage kopieren' }).click();
      await page.getByText('Link kopiert.', { exact: true }).waitFor();
      assert.equal(await page.evaluate(() => navigator.clipboard.readText()), `${base}/tickets/2`);
      await page.getByRole('link', { name: 'Antwort schreiben' }).click();
      assert.equal(new URL(page.url()).hash, '#reply-body');
      await page.evaluate(() => { navigator.clipboard.writeText = async () => { throw new Error('denied'); }; });
      await page.getByRole('button', { name: 'Link zur Anfrage kopieren' }).click();
      await page.getByRole('status').filter({ hasText: 'Automatisches Kopieren fehlgeschlagen' }).waitFor();
      assert.equal(await page.locator('.ticket-direct-link').innerText(), `${base}/tickets/2`);
      await shot('tickets-copy-fallback');
      await page.getByLabel('Ihre Antwort', { exact: true }).fill('Ich ergänze die Diagnose für unser Technikteam.');
      await page.getByLabel('Dateien hinzufügen', { exact: true }).setInputFiles({ name: 'Teamdiagnose.txt', mimeType: 'text/plain', buffer: Buffer.from('Team diagnosis') });
      await page.getByRole('button', { name: 'Antwort senden' }).click();
      await page.getByText('Ich ergänze die Diagnose für unser Technikteam.', { exact: true }).waitFor();
      await page.reload();
      assert.equal(new URL(page.url()).searchParams.get('q'), '#2');
      const link = page.locator('.ticket-files').getByRole('link', { name: 'Teamdiagnose.txt', exact: true });
      assert.equal(await (await portalGet(context, base + await link.getAttribute('href'))).text(), 'Team diagnosis');
      assert.match(await page.locator('article').last().textContent(), /Anna/);
      await shot('tickets-team-detail');
      await page.setViewportSize({ width: 390, height: 1000 });
      await page.locator('.ticket-aside details:not([open])').waitFor({ state: 'attached' });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await shot('tickets-team-narrow');
      assert.equal(await link.isVisible(), false);
      await page.getByText('Zur Anfrage', { exact: true }).click();
      assert.equal(await link.isVisible(), true);
      await shot('tickets-team-files-narrow');
      const heading = page.getByRole('heading', { name: /Teamanfrage von/ });
      await heading.evaluate(h => { h.firstChild.textContent = `Teamanfrage von ${'LangerName'.repeat(12)}`; });
      assert.equal(await heading.evaluate(h => h.scrollWidth <= h.clientWidth), true);
      await shot('tickets-long-name-narrow');
      assert.equal((await portalGet(context, `${base}/tickets/3`)).status(), 404);
      assert.deepEqual(errors, []);
      await context.close();
      const closed = new Promise(r => server.once('exit', r)); server.kill('SIGTERM'); await closed; server = null;
      continue;
    }
    if (branded) {
      await page.getByRole('link', { name: 'Mein Konto' }).click();
      await page.getByText('Nur eigene Anfragen sichtbar.').waitFor();
      await shot('profile-no-sharing');
    }
    await page.goto(`${base}/new`);
    assert.equal(await page.title(), branded ? 'Example & Co · Kundenservice' : 'Ihr Kundenportal');
    assert.equal(await page.locator('footer').count(), branded ? 1 : 0);
    if (branded) {
      assert(await page.locator('.brand img').evaluate(img => img.complete && img.naturalWidth > 0));
      assert.equal(await page.locator('footer a').count(), 3);
      assert.equal(await page.getByRole('button', { name: 'Anfrage senden' }).evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(116, 75, 136)');
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
    const link = page.locator('.ticket-thread').getByRole('link', { name: 'Rechnungsexport.csv', exact: true });
    const response = await portalGet(context, base + await link.getAttribute('href'));
    assert.equal(response.status(), 200);
    assert.deepEqual(await response.body(), data);
    assert.match(response.headers()['content-disposition'], /^attachment;/);
    const originalPreview = page.getByRole('img', { name: 'Vorschau: Export-Screenshot.png', exact: true });
    await originalPreview.scrollIntoViewIfNeeded();
    await originalPreview.evaluate(img => img.decode());
    assert.equal(await originalPreview.evaluate(img => img.naturalWidth), 840);
    const previewResponse = await portalGet(context, base + await originalPreview.getAttribute('src'));
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
    await page.locator('.ticket-files').getByRole('link', { name: 'Browserdiagnose.txt', exact: true }).waitFor();
    await page.reload();
    assert.equal(await page.locator('.ticket-files').getByRole('link', { name: /Rechnungsexport.csv|Browserdiagnose.txt/ }).count(), 2);
    for (const img of await page.locator('.attachment-preview img').all()) {
      await img.scrollIntoViewIfNeeded(); await img.evaluate(img => img.decode());
    }
    assert.equal(await page.locator('.attachment-preview img').count(), 2);
    assert.equal(await page.locator('#selected-files').textContent(), 'Keine Dateien ausgewählt.');
    await shot(branded ? 'tickets-branded-detail' : 'tickets-default-detail');
    assert.equal((await portalGet(context, `${base}/tickets/2`)).status(), 404);
    assert.equal((await portalGet(context, `${base}/tickets/1/attachments/11/att_0123456789abcdef0123456789abcdef`)).status(), 404);
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
      const plain = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 1100, height: 900 }, deviceScaleFactor: 2 });
      const form = await plain.newPage();
      await signIn(form, '/new');
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
      assert.equal(await form.locator('.ticket-copy').isVisible(), false);
      assert.equal(await form.getByRole('link', { name: 'Direktlink zur Anfrage' }).getAttribute('href'), '/tickets/25');
      if (artifacts) await form.screenshot({ path: resolve(artifacts, 'tickets-no-js-detail.png'), fullPage: true });
      const link = form.locator('.ticket-thread').getByRole('link', { name: 'Ohne-JavaScript.txt', exact: true });
      const download = await portalGet(plain, base + await link.getAttribute('href'));
      assert.deepEqual(await download.body(), data);
      await plain.close();
    }
    const closed = new Promise(r => server.once('exit', r)); server.kill('SIGTERM'); await closed; server = null;
  }
  console.log('PASS: custom file chooser, image previews, exact downloads, reload, privacy, branding, narrow layout; team list/detail/reply/file upload with real author and no indirect/private access');
} finally {
  if (browser) await browser.close();
  if (server?.exitCode === null) { const closed = new Promise(r => server.once('exit', r)); server.kill('SIGTERM'); await closed; }
  rmSync(scratch, { recursive: true, force: true });
}
