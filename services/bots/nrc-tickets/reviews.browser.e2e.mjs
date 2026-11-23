// Disposable authoritative-source fixture. Tests the real rendered portal and
// browser cookie/Origin behavior, not the Odin authorization implementation.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const cwd = dirname(fileURLToPath(import.meta.url));
const scratch = mkdtempSync(join(tmpdir(), 'nrc-review-browser-'));
const binary = join(scratch, 'review.test');
const base = 'http://localhost:18197'; // Chromium treats loopback as secure.
const token = 'a'.repeat(64); // Test fixture only, never a production invite.
async function signIn(page, path) {
  await page.goto(`${base}${path}`);
  await page.getByLabel('Benutzername').fill('anna');
  await page.getByLabel('Passwort').fill('fixture-password-only');
  await page.getByRole('button', { name: 'Anmelden' }).click();
  await page.getByRole('button', { name: 'Abmelden' }).waitFor();
}
const artifacts = process.env.TICKETS_SCREENSHOTS;
if (artifacts) mkdirSync(artifacts, { recursive: true });
let server, browser;
try {
  execFileSync('go', ['test', '-c', '-o', binary], { cwd, stdio: 'inherit' });
  let logs = '';
  server = spawn(binary, ['-test.run', '^TestReviewBrowserFixture$', '-test.timeout', '0'], {
    cwd, env: { ...process.env, TICKETS_REVIEW_TEST_ADDR: '127.0.0.1:18197', TICKETS_REVIEW_TEST_ORIGIN: base },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  server.stdout.on('data', b => { logs += b; }); server.stderr.on('data', b => { logs += b; });
  let ready = false;
  for (let i = 0; i < 100; i++) {
    try { if ((await fetch(`${base}/health`)).status === 200) { ready = true; break; } } catch {}
    if (server.exitCode !== null) break;
    await new Promise(r => setTimeout(r, 100));
  }
  assert(ready, `Fixture failed: ${logs}`);
  browser = await chromium.launch();
  const account = await browser.newContext({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 2 });
  const page = await account.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  const shot = async (p, name) => { if (artifacts) await p.screenshot({ path: resolve(artifacts, `${name}.png`), fullPage: true }); };
  await signIn(page, '/abnahmen');
  await page.getByRole('link', { name: 'Zweite Seite · Nachtest' }).waitFor();
  await page.getByRole('link', { name: 'Release-Abnahme · Technikteam' }).click();
  assert.equal(await page.getByRole('navigation', { name: 'Abschnitte' }).count(), 0);
  assert.equal(await page.locator('form[action$="/answer"]').count(), 2);
  const point = page.locator('article').filter({ has: page.getByRole('heading', { name: 'Funktioniert der Export?' }) });
  await point.getByLabel('Meine Antwort', { exact: true }).selectOption('yes');
  await point.getByLabel('Mein Kommentar').fill('Export geprüft, funktioniert.');
  await point.getByRole('button', { name: 'Eigene Antwort speichern' }).click();
  await page.getByText('Widersprüchliche Teamantworten', { exact: true }).waitFor();
  assert.match(await page.locator('main').textContent(), /1 \/ 2/);
  await shot(page, 'review-account');
  await page.getByLabel('Entscheidung', { exact: true }).selectOption('conditional');
  await page.getByLabel('Abschlusskommentar').fill('Bitte Export im Nachtest vergleichen.');
  await page.getByRole('button', { name: 'Abschlussvorschau öffnen' }).click();
  await page.getByRole('heading', { name: 'Abschlussvorschau', exact: true }).waitFor();
  assert.equal(await page.locator('input[name=if_revision]').inputValue(), '101');
  await shot(page, 'review-close-preview');

  const guest = await browser.newContext({ viewport: { width: 390, height: 900 }, deviceScaleFactor: 2 });
  const gp = await guest.newPage();
  gp.on('pageerror', e => errors.push(e.message));
  const requested = [];
  gp.on('request', r => requested.push(r.url()));
  await gp.goto(`${base}/abnahmen/einladung#${token}`);
  try { await gp.getByLabel('Ihr Name', { exact: true }).waitFor({ timeout: 10000 }); }
  catch (e) { throw new Error(`Guest exchange failed at ${gp.url()}: ${await gp.locator('body').textContent()}; browser errors: ${errors.join('; ')}`, { cause: e }); }
  assert.equal(gp.url(), `${base}/abnahmen/gast`);
  assert(requested.every(u => !u.includes(token)), 'invite leaked into an HTTP URL');
  assert.equal(await gp.evaluate(() => localStorage.length + sessionStorage.length), 0);
  assert.equal(await gp.evaluate(() => document.cookie), '');
  const cookie = (await guest.cookies()).find(c => c.name === '__Host-nrc-review');
  assert(cookie?.secure && cookie.httpOnly && cookie.sameSite === 'Strict');
  await gp.getByLabel('Ihr Name', { exact: true }).fill('Gast Müller');
  await gp.getByRole('button', { name: 'Teilnehmen', exact: true }).click();
  await gp.getByRole('heading', { name: 'Release-Abnahme', exact: true }).waitFor();
  assert.equal(await gp.getByRole('button', { name: 'Abschlussvorschau öffnen' }).count(), 0);
  assert.equal(await gp.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  const guestPoint = gp.locator('article').filter({ has: gp.getByRole('heading', { name: 'Ist die Hilfe erreichbar?' }) });
  await guestPoint.getByLabel('Meine Antwort', { exact: true }).selectOption('unable');
  await guestPoint.getByLabel('Mein Kommentar').fill('Kein Zugriff auf die Hilfe.');
  await guestPoint.getByRole('button', { name: 'Eigene Antwort speichern' }).click();
  await gp.locator('.review-own .body').filter({ hasText: 'Kein Zugriff auf die Hilfe.' }).waitFor();
  await gp.reload();
  assert.match(await gp.locator('main').textContent(), /Gast Müller · Gastname \(Selbstangabe\) · Nicht prüfbar/);
  await shot(gp, 'review-guest-narrow');
  assert.equal((await guest.request.get(`${base}/tickets/1`, { maxRedirects: 0 })).status(), 303);
  const csrf = await gp.locator('input[name=csrf]').first().inputValue();
  const rejected = await guest.request.post(`${base}/abnahmen/gast/answer`, { headers: { Origin: 'https://evil.test' }, form: { csrf, point_id: '2', result: 'yes' } });
  assert.equal(rejected.status(), 403);

  // The guest answer changed the run after the account's explicit preview.
  await page.locator('input[name=reviewed]').check();
  await page.getByRole('button', { name: 'Abnahme verbindlich abschließen' }).click();
  await page.getByRole('alert').waitFor();
  assert.match(await page.getByRole('alert').textContent(), /geändert/);
  assert.equal(await page.getByRole('button', { name: 'Abnahme verbindlich abschließen' }).count(), 0);
  assert.equal(await page.getByLabel('Entscheidung', { exact: true }).inputValue(), 'conditional');
  assert.equal(await page.getByLabel('Abschlusskommentar').inputValue(), 'Bitte Export im Nachtest vergleichen.');
  assert.equal(await page.locator('.review-change').count(), 1);
  await page.locator('.review-issue-links a[href="#point-2"]').click();
  await page.locator('#point-2').waitFor({state:'visible'});
  await page.getByRole('button', { name: 'Aktualisierte Abschlussvorschau öffnen' }).click();
  await page.locator('input[name=reviewed]').check();
  await page.getByRole('button', { name: 'Abnahme verbindlich abschließen' }).click();
  await page.getByRole('heading', { name: 'Mit Vorbehalt abgenommen' }).waitFor();
  await shot(page, 'review-closed');

  // The 48-point workflow persists and advances without client-side JavaScript.
  const noJS = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 2, ...(artifacts ? { recordVideo: { dir: join(scratch, 'video'), size: { width: 1440, height: 1100 } } } : {}) });
  const lp = await noJS.newPage();
  await signIn(lp, '/abnahmen/73');
  assert.equal(await lp.locator('form[action$="/answer"]').count(), 1);
  assert.equal(await lp.locator('input[name=point_id]').inputValue(), '19');
  assert.match(await lp.locator('main').textContent(), /18 \/ 48/);
  assert.match(await lp.locator('#point-19').textContent(), /NRC-Konto · Nein/);
  assert.doesNotMatch(await lp.locator('#point-19').textContent(), /01\.01\.1970/);
  assert.equal(await lp.getByRole('navigation', { name: 'Abschnitte' }).getByRole('link').count(), 6);
  assert.equal(await lp.locator('.review-sections a[aria-current] span:last-child').evaluate(e => e.clientHeight <= parseFloat(getComputedStyle(e).lineHeight) + 1), true);
  assert.equal(await lp.locator('#point-19').evaluate(e => e.querySelector('button').getBoundingClientRect().top - e.querySelector('textarea').getBoundingClientRect().bottom >= 12), true);
  await shot(lp, 'review-48-desktop');
  await lp.getByLabel('Meine Antwort', { exact: true }).selectOption('yes');
  await lp.getByLabel('Mein Kommentar').fill('Steuerbetrag mit Rechnung verglichen.');
  await lp.getByRole('button', { name: 'Speichern und weiter' }).click();
  assert.equal(await lp.locator('input[name=point_id]').inputValue(), '20');
  assert.match(await lp.locator('main').textContent(), /19 \/ 48/);
  await lp.goto(`${base}/abnahmen/73?point=19`);
  assert.equal(await lp.getByLabel('Mein Kommentar').inputValue(), 'Steuerbetrag mit Rechnung verglichen.');
  await lp.getByText('Widersprüchliche Teamantworten', { exact: true }).waitFor();
  await lp.setViewportSize({ width: 390, height: 900 });
  assert.equal(await lp.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await shot(lp, 'review-48-narrow');
  await lp.goto(`${base}/abnahmen/74`);
  assert.equal(await lp.locator('main form').count(), 0);
  assert.equal(await lp.locator('.review-all').getAttribute('open'), null);
  assert.match(await lp.locator('main').textContent(), /45 bestanden/);
  assert.equal(await lp.locator('header nav a').evaluateAll(links => links.every(e => getComputedStyle(e).whiteSpace === 'nowrap')), true);
  assert.deepEqual(await lp.locator('.review-result-bar rect').evaluateAll(rects => rects.map(e => [e.getAttribute('x'), e.getAttribute('width')])), [['0','45'],['45','2'],['47','1'],['48','0']]);
  assert.equal(await lp.locator('main').evaluate(e => e.textContent.indexOf('Mit Vorbehalt abgenommen') < e.textContent.indexOf('Freigabe:')), true);
  assert.equal(await lp.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await shot(lp, 'review-report-narrow');
  await lp.locator('.review-all > summary').click();
  assert.equal(await lp.locator('.review-all article').count(), 48);
  await lp.getByRole('heading', { name: 'Stimmt die Mehrwertsteuer im PDF?', exact: true }).waitFor();
  await lp.setViewportSize({ width: 1440, height: 1100 });
  await lp.locator('.review-all > summary').click();
  await shot(lp, 'review-report-desktop');
  await noJS.close();
  if (artifacts) await lp.video().saveAs(resolve(artifacts, 'review-nojs-workflow.webm'));
  assert.deepEqual(errors, []);
  await account.close(); await guest.close();
  console.log('Review browser E2E passed: account list/pages, own/team answers, preview conflict, closure, fragment exchange, encrypted guest cookies, narrow layout, CSRF and ticket-login isolation.');
} finally {
  if (browser) await browser.close();
  if (server && server.exitCode === null) { const closed = new Promise(r => server.once('exit', r)); server.kill('SIGTERM'); await closed; }
  rmSync(scratch, { recursive: true, force: true });
}
