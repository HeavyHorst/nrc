// Real portal and Odin companion to TestReviewGuestInvitationBrowser. Only
// fixture setup/revocation uses staff authority; guest writes use public forms.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { chromium } from 'playwright';

const { base, phase, tokenA, tokenB, control, artifacts } = JSON.parse(readFileSync(0, 'utf8'));
const fixed = phase === 'after';
mkdirSync(artifacts, { recursive: true });
const scratch = mkdtempSync(join(tmpdir(), 'nrc-guest-switch-'));
const browser = await chromium.launch();
const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 920 }, deviceScaleFactor: 2,
  ...(fixed ? { recordVideo: { dir: scratch, size: { width: 1280, height: 920 } } } : {}) });
await context.addInitScript(() => {
  addEventListener('DOMContentLoaded', () => {
    const cursor = document.createElement('div');
    cursor.style.cssText = 'position:fixed;width:12px;height:12px;border:2px solid #111;background:#fff;border-radius:50%;z-index:2147483647;pointer-events:none;left:8px;top:8px';
    document.body.append(cursor);
    addEventListener('mousemove', e => { cursor.style.left = `${e.clientX}px`; cursor.style.top = `${e.clientY}px`; });
  });
});
const page = await context.newPage();
const errors = [];
page.on('pageerror', e => errors.push(e.message));
const results = { phase };
const shot = async name => {
  await page.waitForLoadState('load');
  assert(!page.url().includes(tokenA) && !page.url().includes(tokenB));
  await page.screenshot({ path: join(artifacts, `${phase}-guest-${name}.png`), fullPage: true });
};
const exchange = async token => {
  const response = page.waitForResponse(r => r.request().method() === 'POST' && r.url() === `${base}/abnahmen/einladung`);
  await page.goto(`${base}/abnahmen/einladung#${token}`);
  const res = await response;
  if (res.ok()) await page.waitForURL(`${base}/abnahmen/gast`);
  else await page.getByText('Einladung konnte nicht geöffnet werden.', { exact: false }).waitFor();
  return res;
};
const joinIfNeeded = async () => {
  const needed = await page.getByLabel('Ihr Name', { exact: true }).count() > 0;
  if (needed) {
    await page.getByLabel('Ihr Name', { exact: true }).fill('Clara · Gastprüfung');
    await page.getByRole('button', { name: 'Teilnehmen', exact: true }).click();
  }
  return needed;
};
const save = async comment => {
  const field = page.getByLabel('Mein Kommentar', { exact: true });
  const box = await field.boundingBox();
  await page.mouse.move(70, 200, { steps: 12 });
  await page.mouse.move(box.x + 40, box.y + 12, { steps: 18 });
  const radio = page.getByRole('radio', { name: 'Abweichung', exact: true });
  if (await radio.count()) await radio.check();
  else await page.getByLabel('Meine Antwort', { exact: true }).selectOption('no');
  await field.fill(comment);
  const button = page.getByRole('button', { name: 'Eigene Antwort speichern', exact: true });
  await button.scrollIntoViewIfNeeded();
  const buttonBox = await button.boundingBox();
  await page.mouse.move(buttonBox.x + 30, buttonBox.y + 15, { steps: 15 });
  await button.click();
  await page.locator('.review-own').filter({ hasText: /Gespeichert: Nein|Eigene gespeicherte Antwort: Nein/ }).waitFor();
  assert.equal(await page.getByLabel('Mein Kommentar', { exact: true }).inputValue(), comment);
};
const hasOwn = async comment => await page.getByLabel('Mein Kommentar', { exact: true }).count() === 1 &&
  await page.getByLabel('Mein Kommentar', { exact: true }).inputValue() === comment;
const canClose = async () => await page.locator('form[action$="/preview"]').count() === 1;
try {
  assert.equal((await exchange(tokenA)).status(), 204);
  assert.equal(await joinIfNeeded(), true);
  assert.equal(await canClose(), false);
  await save('A · ursprünglicher Beitrag');
  const initialCookie = (await context.cookies()).find(c => c.name === '__Host-nrc-review');
  const rejected = await exchange('f'.repeat(64));
  results.invalidExchangeStatus = rejected.status();
  results.invalidPreservesCookie = (await context.cookies()).find(c => c.name === '__Host-nrc-review').value === initialCookie.value;
  if (fixed) {
    assert.equal(rejected.status(), 404);
    assert.equal(rejected.headers()['set-cookie'], undefined);
    assert.equal(results.invalidPreservesCookie, true);
  } else {
    assert.equal(rejected.status(), 204);
    assert.equal(results.invalidPreservesCookie, false);
  }
  await exchange(tokenA);
  results.invalidRoundtripPreservesOwn = await hasOwn('A · ursprünglicher Beitrag');
  assert.equal(results.invalidRoundtripPreservesOwn, fixed);
  if (!fixed) await shot('invalid-return-name-required');
  if (await joinIfNeeded()) await save('A · ursprünglicher Beitrag');

  await exchange(tokenB);
  assert.equal(await joinIfNeeded(), true);
  assert.equal(await canClose(), true);
  await save('B · ursprünglicher Beitrag');
  const csrfB = await page.locator('input[name=csrf]').first().inputValue();
  await exchange(tokenA);
  results.validRoundtripPreservesOwnA = await hasOwn('A · ursprünglicher Beitrag');
  assert.equal(results.validRoundtripPreservesOwnA, fixed);
  if (!fixed) await shot('other-run-return-name-required');
  if (await joinIfNeeded()) await save('A · ursprünglicher Beitrag');
  assert.equal(await canClose(), false);
  const csrfA = await page.locator('input[name=csrf]').first().inputValue();
  assert.notEqual(csrfA, csrfB);
  assert.equal((await context.request.post(`${base}/abnahmen/gast/answer`, { headers: { Origin: base }, form: { csrf: csrfB, point_id: '1', result: 'yes', comment: 'must not cross runs' } })).status(), 403);
  assert.equal((await context.request.post(`${base}/abnahmen/gast/preview`, { headers: { Origin: base }, form: { csrf: csrfA, decision: 'accepted', comment: 'must not close A' } })).status(), 403);
  await save('A · nach Rückkehr bearbeitet');
  await page.reload();
  assert.equal(await hasOwn('A · nach Rückkehr bearbeitet'), true);
  if (fixed) {
    // Max-Age has whole-second precision; the encrypted server expiry is
    // checked exactly by the HTTP regression test.
    assert(Math.abs((await context.cookies()).find(c => c.name === '__Host-nrc-review').expires - initialCookie.expires) < 1, 'exchange extended absolute session expiry');
    await shot('a-restored-editable');
  }
  await exchange(tokenB);
  results.validRoundtripPreservesOwnB = await hasOwn('B · ursprünglicher Beitrag');
  assert.equal(results.validRoundtripPreservesOwnB, fixed);
  if (await joinIfNeeded()) await save('B · ursprünglicher Beitrag');
  assert.equal(await canClose(), true);
  await save('B · nach Rückkehr bearbeitet');
  if (fixed) await shot('b-restored-own-close-right');

  // Revoke the real invitation while its browser session is active, then
  // prove neither a saved cookie nor another exchange bypasses the writer.
  assert.equal((await fetch(`${control}/revoke`, { method: 'POST' })).status, 204);
  assert.equal((await page.reload()).status(), 404);
  await exchange(tokenA);
  if (await joinIfNeeded()) await save('A · nach Rückkehr bearbeitet');
  const activeA = (await context.cookies()).find(c => c.name === '__Host-nrc-review').value;
  const revoked = await exchange(tokenB);
  results.revokedExchangeStatus = revoked.status();
  assert.equal(revoked.status(), fixed ? 404 : 204);
  if (fixed) assert.equal((await context.cookies()).find(c => c.name === '__Host-nrc-review').value, activeA);

  const expiring = await (await fetch(`${control}/expiring`, { method: 'POST' })).json();
  await new Promise(resolve => setTimeout(resolve, Math.max(0, expiring.expires - Date.now() + 150)));
  const expired = await exchange(expiring.token);
  results.expiredExchangeStatus = expired.status();
  assert.equal(expired.status(), fixed ? 404 : 204);
  if (fixed) {
    assert.equal((await context.cookies()).find(c => c.name === '__Host-nrc-review').value, activeA);
    await page.goto(`${base}/abnahmen/gast`);
    assert.equal(await hasOwn('A · nach Rückkehr bearbeitet'), true);
    await shot('a-after-rejected-links');
  }
  assert.deepEqual(errors, []);
  writeFileSync(join(artifacts, `${phase}-guest-results.json`), JSON.stringify(results, null, 2));
  console.log(JSON.stringify(results));
  console.log(fixed ? 'PASS: guest switches, original edits, isolated CSRF/close rights, live revocation/expiry and reload' : 'REPRODUCED: invalid and other invitations lose own identity; revoked/expired exchanges replace cookies');
} finally {
  const video = page.video();
  await context.close();
  if (video) await video.saveAs(join(artifacts, 'after-guest-switches.webm'));
  await browser.close();
  rmSync(scratch, { recursive: true, force: true });
}
