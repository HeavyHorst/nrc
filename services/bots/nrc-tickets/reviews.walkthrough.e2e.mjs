// Real-stack companion to TestReviewRealStackWalkthrough. All browser writes
// travel through rendered public forms; authoritative responses are never mocked.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, readdirSync, mkdtempSync, copyFileSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { chromium } from 'playwright';

const fixture = JSON.parse(readFileSync(0, 'utf8'));
const { base, token, login, password, runId, shortRunId, title, shortTitle, artifacts } = fixture;
const comment = 'Freigabe mit Vorbehalt: Steuerzeile im PDF korrigieren und im Nachtest belegen.';
const firstAnswer = 'Im PDF R-2026-104 fehlt die Steuerzeile; Netto und Brutto sind vorhanden.';
const ownerAnswer = 'In meiner Ansicht vorhanden; bitte PDF-Version gemeinsam vergleichen.';
const secondAnswer = 'Nachprüfung 2: Steuerzeile fehlt auch nach erneutem Download.';
const thirdAnswer = 'Nachprüfung 3: Steuerzeile fehlt weiterhin im PDF R-2026-104.';
const tax = 'Stimmt die Mehrwertsteuer im PDF?';
const chromeDir = join(process.env.HOME, '.agent-browser/browsers');
let executablePath = process.env.NRC_REVIEW_CHROME;
if (!executablePath) {
  try {
    const versions = readdirSync(chromeDir).filter(n => n.startsWith('chrome-')).sort();
    if (versions.length) executablePath = join(chromeDir, versions.at(-1), 'chrome');
  } catch { /* Fall back to the project's installed Playwright browser. */ }
}
mkdirSync(artifacts, { recursive: true });
const browser = await chromium.launch({ ...(executablePath ? { executablePath } : {}) });
// Failed or in-progress reruns must not replace the previous completed evidence.
const staging = mkdtempSync(join(tmpdir(), 'nrc-review-walkthrough-'));
const captures = [];
const errors = [];
const options = { ignoreHTTPSErrors: true, viewport: { width: 1440, height: 1050 }, deviceScaleFactor: 2 };
const watch = page => page.on('pageerror', e => errors.push(e.message));
const text = async locator => (await locator.textContent()) ?? '';
const check = async (page, phrase) => assert((await text(page.locator('main'))).includes(phrase), `Missing visible content: ${phrase}`);
const shot = async (page, name, fullPage = true, target = null) => {
  await page.waitForLoadState('load');
  await page.locator('main').boundingBox();
  assert(!page.url().includes(token), 'Invitation fragment must be removed before capture');
  assert(!(await text(page.locator('body'))).includes(token), 'Token must never appear in visible content');
  const path = resolve(staging, `${name}.png`);
  if (target) await target.screenshot({ path });
  else await page.screenshot({ path, fullPage });
  captures.push(`${name}.png`);
};
const answerForm = page => page.locator('form[action$="/answer"]');
const resultInput = (page, result) => answerForm(page).locator(`input[name=result][value=${result}]`);
const answer = async (page, result, value) => {
  await resultInput(page, result).check();
  await answerForm(page).getByLabel('Mein Kommentar', { exact: true }).fill(value);
  await answerForm(page).getByRole('button', { name: 'Speichern und weiter', exact: true }).click();
  assert.equal(await page.locator('input[name=point_id]').inputValue(), '20');
};
const returnToTax = async page => {
  await page.getByRole('navigation', { name: 'Prüfpunkte' }).getByRole('link').filter({ hasText: tax }).click();
  assert.equal(await page.locator('input[name=point_id]').inputValue(), '19');
};
const selectTaxSection = async page => {
  await page.getByRole('navigation', { name: 'Abschnitte' }).getByRole('link').filter({ hasText: 'Rechnung & Steuern' }).click();
  await returnToTax(page);
};
const closeButton = page => page.getByRole('button', { name: 'Abnahme verbindlich abschließen', exact: true });
const updatedPreview = page => page.getByRole('button', { name: 'Aktualisierte Abschlussvorschau öffnen', exact: true });
const assertDraft = async page => {
  assert.equal(await page.getByLabel('Entscheidung', { exact: true }).inputValue(), 'conditional');
  assert.equal(await page.getByLabel('Abschlusskommentar', { exact: true }).inputValue(), comment);
  assert(await page.locator('form[action$="/preview"]').evaluate(form => form.querySelector('button').getBoundingClientRect().top - form.querySelector('textarea').getBoundingClientRect().bottom >= 12));
  await page.getByRole('heading', { name: 'Änderungen und weiterer Klärungsbedarf', exact: true }).waitFor();
  assert.equal(await closeButton(page).count(), 0, 'Conflict must not expose a close button');
  assert.equal(await page.locator('form[action$="/close"]').count(), 0);
  await page.getByRole('alert').waitFor();
  await check(page, 'seit Ihrer Durchsicht geändert');
  assert.equal(await updatedPreview(page).count(), 1);
  assert(await page.locator('.review-issue-links a[href="#point-19"]').count() > 0);
};
const revealTax = async page => {
  await page.locator('.review-issue-links a[href="#point-19"]').click();
  // Native find-in-page/fragment expansion must reveal details even without JS.
  await page.locator('#point-19 h2').waitFor({ state: 'visible' });
  assert.notEqual(await page.locator('details.review-all').getAttribute('open'), null);
};

try {
  const owner = await browser.newContext({ ...options, javaScriptEnabled: false });
  const ownerPage = await owner.newPage(); watch(ownerPage);
  const invitation = await browser.newContext(options);
  const joinPage = await invitation.newPage(); watch(joinPage);
  const requests = [];
  joinPage.on('request', r => requests.push(r.url()));
  await joinPage.goto(`${base}/abnahmen/einladung#${token}`);
  await joinPage.getByLabel('Ihr Name', { exact: true }).waitFor();
  assert.equal(joinPage.url(), `${base}/abnahmen/gast`);
  assert(requests.every(u => !u.includes(token)), 'Token leaked into request URL');
  assert.equal(await joinPage.getByRole('heading', { level: 1 }).textContent(), title);
  await check(joinPage, 'denselben Browser auf demselben Gerät');
  await check(joinPage, 'acht Stunden');
  assert.equal(await joinPage.getByText('Einladungslink weitergeben', { exact: true }).locator('..').getAttribute('open'), null);
  assert.equal(await joinPage.evaluate(() => localStorage.length + sessionStorage.length), 0);
  const cookies = await invitation.cookies();
  const cookie = cookies.find(c => c.name === '__Host-nrc-review');
  assert(cookie?.secure && cookie.httpOnly && cookie.sameSite === 'Strict');
  // Fragment exchange is the only JS-dependent step. Carry its secure cookie
  // into an isolated no-JS guest context before submitting even the name form.
  const guest = await browser.newContext({ ...options, javaScriptEnabled: false });
  await guest.addCookies(cookies);
  await invitation.close();
  const guestPage = await guest.newPage(); watch(guestPage);
  await guestPage.goto(`${base}/abnahmen/gast`);
  await guestPage.getByLabel('Ihr Name', { exact: true }).fill('Clara · Kundentest');
  await shot(guestPage, '01-einladung-name');
  await guestPage.getByRole('button', { name: 'Teilnehmen', exact: true }).click();
  await guestPage.getByRole('heading', { level: 1, name: title, exact: true }).waitFor();
  await check(guestPage, '0 / 48 beantwortet');
  assert.equal(await closeButton(guestPage).count(), 0);
  assert.equal(await guestPage.getByRole('button', { name: 'Abschlussvorschau öffnen', exact: true }).count(), 0);
  assert.equal(await guestPage.locator('section[aria-label="Eigener Fortschritt"]').count(), 1);
  await selectTaxSection(guestPage);
  await resultInput(guestPage, 'no').check();
  await guestPage.getByLabel('Mein Kommentar', { exact: true }).fill(firstAnswer);
  await shot(guestPage, '02-gast-fehler-eintragen');
  await guestPage.getByRole('button', { name: 'Speichern und weiter', exact: true }).click();
  assert.equal(await guestPage.locator('input[name=point_id]').inputValue(), '20');
  await check(guestPage, '1 / 48 beantwortet');
  await shot(guestPage, '03-gast-gespeichert-weiter');
  await returnToTax(guestPage);
  await guestPage.reload();
  assert.equal(await guestPage.getByLabel('Mein Kommentar', { exact: true }).inputValue(), firstAnswer);
  assert.equal(await resultInput(guestPage, 'no').isChecked(), true);
  await check(guestPage, 'Gespeichert: Nein');
  await shot(guestPage, '04-gast-rueckkehr-eigener-beitrag');

  await ownerPage.goto(`${base}/abnahmen`);
  await ownerPage.getByLabel('Benutzername').fill(login);
  await ownerPage.getByLabel('Passwort').fill(password);
  await ownerPage.getByRole('button', { name: 'Anmelden' }).click();
  await ownerPage.locator(`a[href="/abnahmen/${runId}"]`).click();
  await selectTaxSection(ownerPage);
  await ownerPage.locator('.review-team:not([open]) > summary').click();
  await check(ownerPage, firstAnswer);
  await answer(ownerPage, 'yes', ownerAnswer);
  await returnToTax(ownerPage);
  await check(ownerPage, 'Widersprüchliche Teamantworten');
  assert.equal(await ownerPage.getByLabel('Mein Kommentar', { exact: true }).inputValue(), ownerAnswer);
  await check(ownerPage, '1 / 48 beantwortet');
  await shot(ownerPage, '05-teamkonflikt-yes-und-no', true, ownerPage.locator('.review-work'));
  await ownerPage.locator('.review-finish > summary').click();
  await ownerPage.getByLabel('Entscheidung', { exact: true }).selectOption('conditional');
  await ownerPage.getByLabel('Abschlusskommentar', { exact: true }).fill(comment);
  await ownerPage.getByRole('button', { name: 'Abschlussvorschau öffnen', exact: true }).click();
  await ownerPage.getByRole('heading', { name: 'Abschlussvorschau', exact: true }).waitFor();
  assert.equal(await ownerPage.locator('form[action$="/close"] input[name=comment]').inputValue(), comment);
  const firstRevision = await ownerPage.locator('input[name=if_revision]').inputValue();
  assert((await ownerPage.locator('input[name=snapshot]').inputValue()).length > 0);
  assert.equal(await ownerPage.locator('input[name=reviewed]').getAttribute('required'), '');
  const content = await text(ownerPage.locator('main'));
  assert(content.indexOf(comment) < content.indexOf('Vor dem Abschluss prüfen'), 'Closure comment must precede issue list');
  await shot(ownerPage, '06-vorschau-vorbehalt-kommentar');
  await shot(ownerPage, '06c-abschlussbestaetigung', true, ownerPage.locator('article').filter({ has: ownerPage.getByRole('heading', { name: 'Abschluss bestätigen', exact: true }) }));
  await revealTax(ownerPage);
  await check(ownerPage, firstAnswer);
  await shot(ownerPage, '06b-vorschau-punkt-ohne-javascript', false);

  await answer(guestPage, 'no', secondAnswer);
  await ownerPage.locator('input[name=reviewed]').check();
  const staleClose = ownerPage.waitForResponse(r => r.request().method() === 'POST' && r.url().endsWith('/close'));
  await closeButton(ownerPage).click();
  assert.equal((await staleClose).status(), 409);
  await assertDraft(ownerPage);
  assert.notEqual(await ownerPage.locator('input[name=if_revision]').inputValue(), firstRevision);
  await shot(ownerPage, '07-stale-close-entwurf-erhalten');
  await ownerPage.locator('.review-decision').evaluate(e => e.scrollIntoView({ block: 'start' }));
  await shot(ownerPage, '07c-entwurf-und-aenderungsliste', false);
  await revealTax(ownerPage);
  assert.equal(await ownerPage.locator('#point-19 .review-change').count(), 1);
  await check(ownerPage, secondAnswer);
  assert.match(await text(ownerPage.locator('#point-19')), /Rechnung & Steuern · Punkt 19/);
  await shot(ownerPage, '07b-konkreter-geaenderter-punkt', false);

  // Another guest write while the owner is reading the preserved draft must
  // produce a second 409, not silently bless a newer revision on /preview.
  await returnToTax(guestPage);
  await answer(guestPage, 'no', thirdAnswer);
  const stalePreview = ownerPage.waitForResponse(r => r.request().method() === 'POST' && r.url().endsWith('/preview'));
  await updatedPreview(ownerPage).click();
  assert.equal((await stalePreview).status(), 409);
  await assertDraft(ownerPage);
  await shot(ownerPage, '08-erneuter-konflikt-entwurf-erhalten');
  await ownerPage.locator('.review-decision').evaluate(e => e.scrollIntoView({ block: 'start' }));
  await shot(ownerPage, '08d-entwurf-und-aenderungsliste', false);
  await revealTax(ownerPage);
  assert.equal(await ownerPage.locator('#point-19 .review-change').count(), 1);
  await check(ownerPage, thirdAnswer);
  await shot(ownerPage, '08c-erneut-geaenderter-punkt', false);
  await updatedPreview(ownerPage).click();
  await ownerPage.getByRole('heading', { name: 'Abschlussvorschau', exact: true }).waitFor();
  assert.equal(await ownerPage.locator('form[action$="/close"] input[name=comment]').inputValue(), comment);
  assert.equal(await ownerPage.locator('form[action$="/close"] input[name=decision]').inputValue(), 'conditional');
  assert.equal(await ownerPage.locator('input[name=reviewed]').isChecked(), false);
  await shot(ownerPage, '08b-erneute-aktuelle-vorschau');
  await revealTax(ownerPage);
  await check(ownerPage, thirdAnswer);
  await ownerPage.locator('input[name=reviewed]').check();
  await closeButton(ownerPage).click();
  await ownerPage.getByRole('heading', { name: 'Mit Vorbehalt abgenommen', exact: true }).waitFor();
  assert.equal(await ownerPage.locator('main form').count(), 0);
  await check(ownerPage, comment);
  await check(ownerPage, '45 bestanden');
  await check(ownerPage, '1 mit Abweichung');
  await check(ownerPage, '1 nicht prüfbar');
  await check(ownerPage, '1 unbeantwortet');
  await shot(ownerPage, '09-bericht-desktop');
  await ownerPage.locator('details.review-all > summary').click();
  assert.equal(await ownerPage.locator('details.review-all article').count(), 48);
  await check(ownerPage, thirdAnswer);
  await check(ownerPage, ownerAnswer);
  await ownerPage.locator('details.review-all > summary').click();
  await ownerPage.setViewportSize({ width: 390, height: 900 });
  assert.equal(await ownerPage.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await shot(ownerPage, '09b-bericht-schmal');
  await guestPage.reload();
  await guestPage.getByRole('heading', { name: 'Mit Vorbehalt abgenommen', exact: true }).waitFor();
  assert.equal(await guestPage.locator('form').count(), 0);

  // Short existing forms use one editor without section navigation.
  await ownerPage.setViewportSize({ width: 1440, height: 1050 });
  await ownerPage.getByRole('link', { name: '← Meine Abnahmen', exact: true }).click();
  await ownerPage.locator(`a[href="/abnahmen/${shortRunId}"]`).click();
  await ownerPage.getByRole('heading', { level: 1, name: shortTitle, exact: true }).waitFor();
  assert.equal(await answerForm(ownerPage).count(), 1);
  assert.equal(await ownerPage.getByRole('navigation', { name: 'Abschnitte' }).count(), 0);
  const shortPoint = ownerPage.locator('#point-1');
  await resultInput(ownerPage, 'yes').check();
  await shortPoint.getByLabel('Mein Kommentar', { exact: true }).fill('Hilfeseite im Bestandsbogen geöffnet.');
  await shortPoint.getByRole('button', { name: 'Speichern und weiter', exact: true }).click();
  await ownerPage.getByRole('navigation', { name: 'Prüfpunkte' }).locator('a[href$="#point-1"]').click();
  await ownerPage.reload();
  assert.equal(await shortPoint.getByLabel('Mein Kommentar', { exact: true }).inputValue(), 'Hilfeseite im Bestandsbogen geöffnet.');
  await ownerPage.locator('.review-finish > summary').click();
  assert(await ownerPage.locator('form[action$="/preview"]').evaluate(form => form.querySelector('button').getBoundingClientRect().top - form.querySelector('textarea').getBoundingClientRect().bottom >= 12));
  await shot(ownerPage, '10-kurz-bestandsbogen');

  const enhanced = await browser.newContext({ ...options, storageState: await owner.storageState() });
  const smooth = await enhanced.newPage(); watch(smooth);
  await smooth.goto(`${base}/abnahmen`);
  await smooth.getByRole('heading', { name: 'Meine Abnahmen', exact: true }).waitFor();
  assert.equal(await smooth.locator('.ticket-table tbody tr').count(), 2);
  assert.deepEqual((await smooth.locator('.ticket-status').allTextContents()).sort(), ['In Bearbeitung', 'Mit Vorbehalt abgenommen']);
  const listTitles = () => smooth.locator('.ticket-table tbody a').allTextContents();
  const statusTab = name => smooth.getByRole('navigation', { name: 'Abnahmen nach Status filtern' }).getByRole('link', { name, exact: true });
  assert.deepEqual(await listTitles(), [shortTitle, title]);
  await shot(smooth, '13-abnahmeliste-filter-desktop');
  await smooth.setViewportSize({ width: 390, height: 900 });
  assert.equal(await smooth.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await shot(smooth, '13b-abnahmeliste-filter-schmal');
  await smooth.setViewportSize({ width: 1440, height: 1050 });
  const filter = smooth.getByRole('button', { name: 'Filtern', exact: true });
  const filtered = () => smooth.locator('[data-list-filters][aria-busy]').waitFor({ state: 'detached' });
  await smooth.evaluate(() => { window.listHeading = document.querySelector('h1'); });
  await smooth.getByLabel('Sortierung').selectOption('oldest');
  await filter.click();
  await filtered();
  assert(await smooth.evaluate(() => window.listHeading === document.querySelector('h1')));
  assert.deepEqual(await listTitles(), [title, shortTitle]);
  await smooth.getByRole('searchbox').fill('  MUSTERFIRMA NORD  ');
  await filter.click();
  await filtered();
  assert.deepEqual(await listTitles(), [title]);
  await statusTab('Offen / In Bearbeitung').click();
  await smooth.getByRole('heading', { name: 'Keine passenden Abnahmen' }).waitFor();
  assert.equal(await smooth.getByRole('searchbox').inputValue(), 'MUSTERFIRMA NORD');
  assert.equal(await smooth.getByLabel('Sortierung').inputValue(), 'oldest');
  await shot(smooth, '13c-abnahmeliste-kein-treffer');
  await statusTab('Abgeschlossen').click();
  await filtered();
  assert.deepEqual(await listTitles(), [title]);
  await smooth.getByRole('searchbox').fill(`#${shortRunId}`);
  await filter.click();
  await filtered();
  await smooth.getByRole('heading', { name: 'Keine passenden Abnahmen' }).waitFor();
  await statusTab('Offen / In Bearbeitung').click();
  await filtered();
  assert.deepEqual(await listTitles(), [shortTitle]);
  await smooth.getByRole('link', { name: shortTitle, exact: true }).click();
  await smooth.locator('#point-2').waitFor();
  await smooth.locator('a[href$="#point-1"]').click();
  await smooth.locator('#point-1').waitFor();
  await smooth.evaluate(() => { window.reviewHeader = document.querySelector('header'); });
  const sameDocument = () => smooth.evaluate(() => window.reviewHeader === document.querySelector('header'));
  const pointLink = id => smooth.getByRole('navigation', { name: 'Prüfpunkte' }).locator(`a[href$="#point-${id}"]`);
  await smooth.getByLabel('Mein Kommentar', { exact: true }).fill('Noch nicht gespeichert');
  await smooth.locator('.review-finish > summary').click();
  await smooth.getByLabel('Abschlusskommentar', { exact: true }).fill('Abschlussentwurf');
  // Hold the real GET to make a blank view or a premature swap observable.
  let releasePoint;
  const delayedPoint = new Promise(resolve => { releasePoint = resolve; });
  const pointURL = url => url.pathname === `/abnahmen/${shortRunId}` && url.searchParams.get('point') === '2';
  let startedPoint;
  const pointRequested = new Promise(resolve => { startedPoint = resolve; });
  await smooth.route(pointURL, async route => { startedPoint(); await delayedPoint; await route.continue(); }, { times: 1 });
  await pointLink(2).click();
  await Promise.race([pointRequested, smooth.waitForEvent('framenavigated', { timeout: 10000 }).then(() => { throw new Error('Unexpected document navigation'); })]);
  try {
    assert(await smooth.locator('#point-1').isVisible());
    assert(await sameDocument());
  } finally {
    releasePoint();
  }
  await smooth.locator('#point-2').waitFor();
  assert(await sameDocument());
  assert.equal(await pointLink(2).getAttribute('aria-current'), 'step');
  assert.equal(await smooth.getByLabel('Abschlusskommentar', { exact: true }).inputValue(), 'Abschlussentwurf');
  assert.equal(await smooth.evaluate(() => document.activeElement.tagName), 'H2');
  await shot(smooth, '12-pruefpunkt-gewechselt');
  await smooth.goBack();
  await smooth.locator('#point-1').waitFor();
  assert.equal(await smooth.getByLabel('Mein Kommentar', { exact: true }).inputValue(), 'Noch nicht gespeichert');
  await smooth.getByRole('button', { name: 'Speichern und weiter' }).click();
  await smooth.locator('#point-2').waitFor();
  assert(await sameDocument());
  await pointLink(1).click();
  await smooth.locator('#point-1').waitFor();
  await smooth.reload();
  assert.equal(await smooth.getByLabel('Mein Kommentar', { exact: true }).inputValue(), 'Noch nicht gespeichert');
  await smooth.getByRole('link', { name: '← Meine Abnahmen', exact: true }).click();
  assert.equal(await smooth.getByRole('searchbox').inputValue(), `#${shortRunId}`);
  assert.equal(await smooth.getByLabel('Sortierung').inputValue(), 'oldest');
  assert.equal(await statusTab('Offen / In Bearbeitung').getAttribute('aria-current'), 'page');
  assert.deepEqual(await listTitles(), [shortTitle]);
  await enhanced.close();
  assert.deepEqual(errors, []);
  for (const name of captures) {
    copyFileSync(join(staging, name), join(artifacts, name));
    console.log(`Screenshot .amp/in/artifacts/review-ux/${name}`);
  }
  console.log('PASS: real TLS/Odin; new guest and owner; 48 points; no-JS forms/preview/details; two revision conflicts; original closure draft; read-only report; short existing form.');
  await owner.close(); await guest.close();
} catch (error) {
  // Playwright errors can contain invitation URLs. Redact before logging and do
  // not allow an uncaught stack to disclose an invitation capability.
  console.error(String(error?.stack ?? error).replaceAll(token, '[redacted-invitation]').replaceAll(password, '[redacted-password]'));
  process.exitCode = 1;
} finally {
  await browser.close();
  rmSync(staging, { recursive: true, force: true });
}
