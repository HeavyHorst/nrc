// Production History UI and dispatcher against a disposable protocol fixture.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs";

const artifacts = fileURLToPath(new URL("../.amp/in/artifacts/chronicle-titles/mock/", import.meta.url));
fs.mkdirSync(artifacts, { recursive: true });
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, serviceWorkers: "block" });
const page = await context.newPage();
const errors = [];
page.on("pageerror", error => errors.push(error.message));
const shot = name => page.screenshot({ path: `${artifacts}chronicle-${name}.png` });
try {
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${new URL(route.request().url()).pathname === "/" ? "/index.html" : new URL(route.request().url()).pathname}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCChronicle && document.getElementById("historyChronicle").onclick);
  await page.evaluate(() => {
    serverReady = true;
    window.chronicleFixture = { requests: [], enabled: true, permission: false, fail: false, hold: false, empty: false, deleted: false, replies: [] };
    ws = { readyState: WebSocket.OPEN, send: buffer => {
      const v = new DataView(buffer), f = window.chronicleFixture;
      if (v.getUint16(0) !== 74) return;
      const q = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 2, buffer.byteLength - 6)));
      f.requests.push(q);
      const row = { generation: q.cursor === "0" ? "9007199254740993" : "9007199254740994", note_id: "18446744073709551615", note_title: f.title ?? "Freigabe Gerätebestand", first_at: "1794909000000000000", last_at: "1794909060000000000", created_at: "1794909120000000000", sources: ["9007199254740997", "9007199254740999"], summary: "Die Zahl wurde von 17 auf 23 Geräte korrigiert. Die fehlende Freigabe bleibt erhalten.", model: "gpt-6.1-terra", prompt_version: "chronicle-p5", schema_version: "chronicle-s1", source_available: !!f.available };
      if (f.injection) { row.summary = '<img src=x onerror="window.injected=true">'; row.note_title = '<img src=x onerror="window.injected=true">'; row.model = "<script>bad()</script>"; }
      let response;
      if (q.op === "status") response = { status: f.fail ? "forbidden" : "ok", enabled: f.enabled, can_delete: f.permission, pending: 3, processing: 1, failed: 1, expired: 0, acknowledged: 4, gap_count: 2, calls: 507, input_tokens: 23000, output_tokens: 5000 };
      else if (q.op === "history") response = { status: "ok", entries: f.empty || f.deleted ? [] : [row], cursor: f.empty || f.deleted ? "0" : row.generation, more: q.cursor === "0" && !f.empty && !f.deleted };
      else if (q.op === "gaps") response = { status: "ok", gaps: f.empty ? [] : [{ first_source: q.cursor === "0" ? "9007199254741001" : "9007199254741003", last_source: q.cursor === "0" ? "9007199254741002" : "9007199254741004", note_id: q.note_id || "42", note_title: "Rollout-Abnahme", first_at: row.first_at, last_at: row.last_at, input_count: 2, reason: "ttl", source_available: false }], cursor: f.empty ? "0" : q.cursor === "0" ? "9007199254741001" : "9007199254741003", more: !f.empty && q.cursor === "0" };
      else if (q.op === "delete") { f.deleted = true; response = { status: "deleted", deleted_through: "9007199254741002" }; }
      else throw Error("UI attempted service operation");
      const bytes = new TextEncoder().encode(JSON.stringify(response));
      const frame = new DataView(new ArrayBuffer(6 + bytes.length));
      frame.setUint16(0, 180); frame.setUint32(2, v.getUint32(buffer.byteLength - 4)); new Uint8Array(frame.buffer, 6).set(bytes);
      const reply = () => handleBinaryMessage(frame.buffer);
      if (f.hold) f.replies.push(reply); else queueMicrotask(reply);
    } };
  });
  await page.click("#historyBtn"); await page.click("#historyChronicle");
  const ready = () => page.waitForFunction(() => document.getElementById("historyStatus").textContent.includes("ENTRIES LOADED"));
  await ready();
  assert.match(await page.locator('[aria-label="AI entries"] .chronicle-identity').innerText(), /Freigabe Gerätebestand/);
  assert.doesNotMatch(await page.locator('[aria-label="AI entries"] .chronicle-identity').innerText(), /18446744073709551615/);
  assert.match(await page.locator('[aria-label="Coverage gaps"] .chronicle-identity').innerText(), /Rollout-Abnahme/);
  assert.equal(await page.getByText("4 NO-CHANGE ACKS", { exact: false }).isVisible(), false);
  assert.equal(await page.locator('[data-chronicle-system] .chronicle-warning').isVisible(), true);
  await page.locator('[data-chronicle-system] summary').click();
  assert.match(await page.locator("#historyBody").innerText(), /4 NO-CHANGE ACKS/);
  const budgets = await page.locator('[data-chronicle-system]').innerText();
  assert.match(budgets, /507 CALLS TODAY · 23000\/8,000,000 INPUT · 5000\/500,000 OUTPUT TOKENS/);
  assert.match(budgets, /Confirmed responses count actual tokens; pending or unknown outcomes retain their reservation\. No daily call limit\./);
  for (const theme of ["matte-black", "lupine"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
      const system = page.locator('[data-chronicle-system]');
      assert.equal(await system.evaluate(node => node.scrollWidth > node.clientWidth), false);
      await system.screenshot({ path: `${artifacts}chronicle-budget-${theme}-${width}.png` });
    }
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.locator('[data-chronicle-system] summary').click();
  assert.equal(await page.locator('[data-chronicle-technical]').isVisible(), false);
  assert.equal(await page.locator('.chronicle-gap-reason').isVisible(), true);
  assert.equal(await page.locator('.chronicle-summary').innerText(), "Die Zahl wurde von 17 auf 23 Geräte korrigiert. Die fehlende Freigabe bleibt erhalten.");
  await page.locator('[aria-label="AI entries"] summary').click();
  assert.match(await page.locator("#historyBody").innerText(), /9007199254740997, 9007199254740999/);
  assert.equal(await page.locator('[data-chronicle-technical]').isVisible(), true);
  await page.locator('[aria-label="AI entries"] summary').click();
  assert.equal(await page.locator("[data-chronicle-delete]").count(), 0);
  assert.equal(await page.locator("#historyBody [data-history-record]").count(), 0, "deleted sources are not dead inspector links");
  const gapReads = await page.evaluate(() => chronicleFixture.requests.filter(q => q.op === "gaps").length);
  await page.click('[data-chronicle-more="entries"]'); await ready();
  assert.equal(await page.locator(".chronicle-summary").count(), 2);
  assert.equal(await page.evaluate(() => chronicleFixture.requests.filter(q => q.op === "gaps").length), gapReads);
  assert.equal(await page.locator('[data-chronicle-more="entries"]').count(), 0);
  assert.equal(await page.evaluate(() => chronicleFixture.requests.at(-1).cursor), "9007199254740993");
  const entryReads = await page.evaluate(() => chronicleFixture.requests.filter(q => q.op === "history").length);
  await page.click('[data-chronicle-more="gaps"]'); await ready();
  assert.equal(await page.evaluate(() => chronicleFixture.requests.filter(q => q.op === "history").length), entryReads);
  assert.equal(await page.locator('[aria-label="Coverage gaps"] .chronicle-entry').count(), 2);
  assert.equal(await page.locator('[data-chronicle-more]').count(), 0);
  await page.click("#historyRefresh"); await ready();
  for (const theme of ["matte-black", "lupine"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await shot(`desktop-${theme}`);
    await page.setViewportSize({ width: 390, height: 844 });
    await shot(`mobile-${theme}`);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    await page.locator('[aria-label="Coverage gaps"]').scrollIntoViewIfNeeded();
    await shot(`mobile-gaps-${theme}`);
    await page.locator("#historyBody").evaluate(node => node.scrollTop = 0);
    await page.setViewportSize({ width: 1440, height: 1000 });
  }
  await page.locator('[data-chronicle-system] summary').click();
  await page.locator('[aria-label="AI entries"] summary').click();
  await page.locator('[aria-label="Coverage gaps"] summary').click();
  await shot("details");
  await page.setViewportSize({ width: 390, height: 844 });
  await shot("mobile-details");
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.click("#historyRefresh"); await ready();
  assert.equal(await page.locator('[data-chronicle-system]').evaluate(node => node.open), true, "system disclosure survives refresh");
  await page.locator('[data-chronicle-system] summary').click();
  await page.evaluate(() => { chronicleFixture.available = true; NRCHistory.refresh(); }); await ready();
  await page.setViewportSize({ width: 390, height: 844 });
  const noteLink = page.locator('.chronicle-identity [data-history-record]');
  assert.equal(await noteLink.getAttribute('data-history-id'), '18446744073709551615');
  assert.equal(await noteLink.innerText(), 'Freigabe Gerätebestand');
  assert.equal(await noteLink.evaluate(node => node.scrollWidth <= node.clientWidth), true);
  await page.evaluate(() => { chronicleFixture.title = 'Ä'.repeat(128); NRCHistory.refresh(); }); await ready();
  assert.equal(await noteLink.innerText(), 'Ä'.repeat(128));
  assert.equal(await noteLink.evaluate(node => node.scrollWidth <= node.clientWidth), true);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await page.evaluate(() => { chronicleFixture.title = ''; NRCHistory.refresh(); }); await ready();
  assert.equal(await noteLink.innerText(), 'Untitled note');
  await page.evaluate(() => { delete chronicleFixture.title; NRCHistory.refresh(); }); await ready();
  const disclosure = page.locator('[aria-label="AI entries"] summary');
  await disclosure.focus(); await page.keyboard.press('Enter');
  assert.equal(await disclosure.evaluate(node => node.parentElement.open), true);
  await page.keyboard.press('Enter');
  assert.equal(await disclosure.evaluate(node => node.parentElement.open), false);
  await shot('mobile-available-source');
  await disclosure.click();
  await page.locator('[data-chronicle-technical]').scrollIntoViewIfNeeded();
  await shot('mobile-entry-details');
  await page.locator('[data-chronicle-technical]').click();
  assert.equal(await page.locator('#historyTechnical').getAttribute('aria-pressed'), 'true');
  assert.match(await page.locator('#historyScope').innerText(), /18446744073709551615/);
  await page.locator('#historyChronicle').click(); await ready();
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.evaluate(() => { chronicleFixture.available = false; });
  // Injection stays inert, including source IDs and model metadata as text.
  await page.evaluate(() => { chronicleFixture.injection = true; NRCHistory.refresh(); }); await ready();
  assert.equal(await page.locator("#historyBody img, #historyBody script").count(), 0);
  assert.match(await page.locator(".chronicle-summary").innerText(), /<img/);
  assert.match(await page.locator('[aria-label="AI entries"] .chronicle-identity').innerText(), /<img/);
  assert.equal(await page.evaluate(() => window.injected), undefined);
  await page.evaluate(() => { chronicleFixture.injection = false; chronicleFixture.hold = true; NRCHistory.refresh(); });
  await shot("loading");
  // Cancel the held status; a late response cannot leak across a session change.
  await page.evaluate(() => { serverReady = false; updateConnectionStatus(false); NRCHistory.disconnect(); chronicleFixture.replies.shift()(); });
  assert.match(await page.locator("#historyStatus").innerText(), /OFFLINE/);
  assert.equal(await page.locator(".chronicle-summary").count(), 0);
  await shot("offline");
  await page.evaluate(() => { serverReady = true; updateConnectionStatus(true); chronicleFixture.hold = false; chronicleFixture.fail = true; NRCHistory.refresh(); });
  await page.waitForFunction(() => document.getElementById("historyStatus").textContent.includes("FAILED"));
  await shot("error");
  await page.evaluate(() => { chronicleFixture.fail = false; chronicleFixture.empty = true; });
  await page.click("#historyRefresh"); await ready(); await shot("empty");
  await page.evaluate(() => { chronicleFixture.empty = false; chronicleFixture.enabled = false; });
  await page.click("#historyRefresh"); await ready();
  assert.match(await page.locator("#historyBody").innerText(), /Retained explanations remain readable/);
  assert.equal(await page.locator(".chronicle-summary").count(), 1); await shot("disabled");
  await page.evaluate(() => { chronicleFixture.enabled = true; chronicleFixture.permission = true; NRCHistory.open(2, "18446744073709551615"); });
  await ready();
  assert.equal(await page.evaluate(() => chronicleFixture.requests.at(-1).note_id), "18446744073709551615");
  await page.locator("[data-chronicle-delete]").click();
  const dialog = page.locator("dialog[open]");
  await dialog.waitFor();
  assert.match(await dialog.innerText(), /technical history stay unchanged/);
  assert.match(await dialog.innerText(), /Later note changes/); await shot("delete-confirmation");
  await dialog.getByRole("button", { name: "Delete AI chronicle", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("historyBody").textContent.includes("deleted through source"));
  assert.equal(await page.locator(".chronicle-summary").count(), 0);
  assert.equal(await page.evaluate(() => chronicleFixture.requests.filter(q => q.op === "delete").length), 1);
  // Only read/status/delete APIs were ever called; no raw, claim or provider access.
  assert.equal(await page.evaluate(() => chronicleFixture.requests.some(q => !["status", "history", "gaps", "delete"].includes(q.op))), false);
  assert.deepEqual(errors, []);
  console.log("Chronicle browser: exact IDs, independent paging, coverage/Ack, deleted sources, empty/disabled/loading/error/offline, stale-session fencing, server permission and confirmed delete; both themes desktop/mobile PASS");
} finally { await browser.close(); }
