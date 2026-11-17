// Real client -> disposable auth proxy -> real Odin/SQLite -> worker result.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { mkdir } from "node:fs/promises";
const { NRC_ACCEPTANCE_URL: url, NRC_ACCEPTANCE_WORKSPACE: workspace, NRC_ACCEPTANCE_SUMMARY: summary } = process.env;
assert.ok(url && workspace && summary);
const output = new URL("../../../.amp/in/artifacts/chronicle-titles/", import.meta.url);
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  await page.goto(`${url}/#workspace=${encodeURIComponent(workspace)}`);
  await page.waitForFunction(() => typeof serverReady !== "undefined" && serverReady);
  await page.click("#historyBtn"); await page.click("#historyChronicle");
  try {
    await page.waitForFunction(() => document.querySelector(".chronicle-summary"));
  } catch (error) {
    console.log("history diagnostic", await page.locator("#historyPanel").innerText());
    await page.screenshot({ path: new URL("history-failure.png", output).pathname });
    throw error;
  }
  assert.equal(await page.locator(".chronicle-summary").innerText(), summary);
  assert.equal(await page.locator('[aria-label="AI entries"] [data-history-record]').innerText(), "Negation und Zahl");
  assert.equal(await page.locator('[aria-label="Coverage gaps"] [data-history-record]').innerText(), "Zu groß fürs Modell");
  assert.match(await page.locator('[aria-label="Coverage gaps"]').innerText(), /token_limit/);
  assert.equal(await page.locator('[data-chronicle-delete]').count(), 0);
  for (const theme of ["matte-black", "lupine"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
      await page.screenshot({ path: new URL(`real-${theme}-${width}.png`, output).pathname });
      if (width === 390) {
        await page.locator('[aria-label="Coverage gaps"]').scrollIntoViewIfNeeded();
        await page.screenshot({ path: new URL(`real-${theme}-390-gaps.png`, output).pathname });
        await page.locator("#historyBody").evaluate(node => node.scrollTop = 0);
      }
    }
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.reload();
  await page.waitForFunction(() => typeof serverReady !== "undefined" && serverReady);
  await page.click("#historyBtn"); await page.click("#historyChronicle");
  await page.waitForFunction(() => document.querySelector(".chronicle-summary"));
  assert.equal(await page.locator(".chronicle-summary").innerText(), summary);
  assert.deepEqual(errors, []);
  console.log("PASS: real browser/SQLite/worker result and gap, both themes/widths, reload, no delete authority or page errors");
} finally { await browser.close(); }
