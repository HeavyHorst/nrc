// Disposable protocol fixture through the production app dispatcher; no backend writes.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs";

const artifacts = fileURLToPath(new URL("../.amp/in/artifacts/", import.meta.url));
fs.mkdirSync(artifacts, { recursive: true });
const browser = await chromium.launch({ headless: true, args: ["--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4"] });
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, serviceWorkers: "block" });
const page = await context.newPage();
const errors = [];
page.on("pageerror", error => errors.push(error.message));
try {
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${new URL(route.request().url()).pathname === "/" ? "/index.html" : new URL(route.request().url()).pathname}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCHistory && document.getElementById("historyBtn").onclick);
  await page.evaluate(() => {
    serverReady = true;
    window.historyFixture = { requests: [], empty: false, fail: false, hold: false, replies: [], escaped: true };
    ws = { readyState: WebSocket.OPEN, send: buffer => {
      const request = new DataView(buffer);
      if (request.getUint16(0) !== 62) return;
      if (request.byteLength !== 33 || request.getBigUint64(2) !== 0n || request.getUint16(27) !== 50) throw Error("Invalid history request");
      const f = window.historyFixture;
      f.requests.push({ kind: request.getUint8(10), entityId: request.getBigUint64(11).toString(), before: request.getBigUint64(19).toString() });
      const cursor = request.getBigUint64(19);
      const id = cursor ? cursor - 1n : 9007199254740999n;
      const events = f.empty ? [] : Array.from({ length: 3 }, (_, i) => ({
        id: String(id - BigInt(i)), timestamp: String(BigInt(Date.UTC(2026, 9, cursor ? 16 : 17, 10, 30 - i)) * 1000000n),
        actorId: "subject:stable-rene", actorName: "Rene", entityType: ["task", "asset", "edge"][i],
        entityId: "9007199254740993", action: ["updated", "deleted", "created"][i], fields: i ? [] : ["status", "assignee"],
        entityLabel: i === 0 ? (f.escaped ? "<img src=x>" : "Prepare customer proposal") : "Old onboarding checklist",
        assetType: i === 1 ? 5 : 0, entityAvailable: i === 0,
        ...(i === 2 ? { sourceType: "asset", sourceId: "42", sourceLabel: "Meeting notes", sourceAssetType: 5, sourceAvailable: true, targetType: "asset", targetId: "71", targetLabel: "Website relaunch", targetAssetType: 11, targetAvailable: true } : {}),
      }));
      const json = JSON.stringify(f.fail ? { error: "Unavailable" } : { events, nextBefore: !cursor && events.length ? events.at(-1).id : "0" });
      const bytes = new TextEncoder().encode(json);
      const response = new DataView(new ArrayBuffer(6 + bytes.length));
      response.setUint16(0, 168); response.setUint32(2, request.getUint32(29));
      new Uint8Array(response.buffer, 6).set(bytes);
      const reply = () => handleBinaryMessage(response.buffer);
      if (f.hold) f.replies.push(reply); else queueMicrotask(reply);
    } };
  });
  await page.click("#historyBtn");
  await page.waitForFunction(() => document.getElementById("historyStatus").textContent.includes("3 EVENTS"));
  assert.equal(await page.locator("#historyBody img").count(), 0, "fields and actor names are text, not HTML");
  assert.match(await page.locator("#historyBody").innerText(), /Old onboarding checklist/);
  assert.equal(await page.locator('#historyBody .history-event:nth-child(2) button').count(), 0, "deleted records are not dead links");
  assert.equal(await page.locator('#historyBody [title="subject:stable-rene"]').count(), 3);
  await page.evaluate(() => { historyFixture.escaped = false; NRCHistory.refresh(); });
  await page.waitForFunction(() => document.getElementById("historyBody").textContent.includes("Prepare customer proposal"));
  await page.locator("#historyBody .history-event").nth(1).hover();
  assert.equal(await page.locator("#historyBody .history-event").nth(1).evaluate(row => getComputedStyle(row).outlineStyle), "none", "noninteractive rows do not look clickable");
  await page.locator('#historyBody .history-meta span').first().focus();
  await page.keyboard.press("Tab");
  assert.equal(await page.locator('#historyBody [data-history-record="task"]').evaluate(button => getComputedStyle(button).outlineStyle), "solid", "record names retain keyboard focus indicators");
  await page.click("#historyMore");
  await page.waitForFunction(() => document.getElementById("historyStatus").textContent.includes("6 EVENTS"));
  assert.equal(await page.locator("#historyMore").isVisible(), false);
  assert.equal(await page.evaluate(() => historyFixture.requests.at(-1).before), "9007199254740997");
  assert.equal(await page.locator("#historyBody .history-day").count(), 2, "older pages appear under their calendar day");
  for (const theme of ["matte-black", "lupine"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await page.screenshot({ path: `${artifacts}history-desktop-${theme}.png` });
  }
  await page.locator("#historyBody .history-event").last().scrollIntoViewIfNeeded();
  assert.equal(await page.evaluate(() => {
    const body = document.getElementById("historyBody").getBoundingClientRect();
    const last = document.querySelector("#historyBody .history-day:last-child li:last-child").getBoundingClientRect();
    return last.top >= body.top && last.bottom <= body.bottom + 1;
  }), true, "the full last event is reachable inside the scrollable history");
  await page.evaluate(() => document.getElementById("historyBody").scrollTop = 0);
  // Real inspector navigation remains on History and exposes the selected record.
  await page.evaluate(() => {
    NRCLinksUI.loadLinks = async () => {};
    NRCTasks.requestTask = (_room, id, options) => options.onSuccess({ task: { id, convId: 0n, title: "Prepare customer proposal", description: "Current task contents", status: 1, priority: 128, orderIndex: 0, color: 0, assignee: "", project: "", attachments: [], createdAt: 1n, updatedAt: 1n } });
  });
  await page.locator('#historyBody [data-history-record="task"]').first().click();
  await page.waitForFunction(() => NRCInspector.current()?.id === 9007199254740993n && !NRCInspector.isLoading());
  assert.equal(await page.locator("#inspector").isVisible(), true);
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "history");
  await page.screenshot({ path: `${artifacts}history-record-open.png` });
  await page.click("#taskDetailClose");
  assert.equal(await page.locator("#inspector").isVisible(), false);
  // Shared metadata entry point exercises task/asset scoping and delegated navigation.
  await page.evaluate(() => {
    const node = document.createElement("div"); node.id = "historyTestMetadata";
    node.innerHTML = NRCDetailUI.renderHeaderMetadata([], 1, "9007199254740993");
    document.getElementById("historyBody").prepend(node);
  });
  await page.click("#historyTestMetadata button");
  await page.waitForFunction(() => historyFixture.requests.at(-1).kind === 1);
  assert.match(await page.locator("#historyScope").innerText(), /Prepare customer proposal #9007199254740993/i);
  await page.click("#historyClear");
  assert.equal(await page.evaluate(() => historyFixture.requests.at(-1).entityId), "0");
  await page.evaluate(() => { historyFixture.hold = true; NRCHistory.open(2, "71"); NRCHistory.open(1, "42"); historyFixture.replies.shift()(); });
  assert.match(await page.locator("#historyStatus").innerText(), /LOADING/);
  await page.evaluate(() => { historyFixture.replies.shift()(); historyFixture.hold = false; });
  await page.waitForFunction(() => document.getElementById("historyStatus").textContent.includes("3 EVENTS"));
  await page.evaluate(() => { historyFixture.fail = true; NRCHistory.refresh(); });
  await page.waitForFunction(() => document.getElementById("historyStatus").textContent.includes("FAILED"));
  await page.evaluate(() => { historyFixture.fail = false; historyFixture.empty = true; });
  await page.click("#historyRefresh");
  await page.waitForFunction(() => document.getElementById("historyBody").textContent.includes("NO HISTORY"));
  for (const theme of ["matte-black", "lupine"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await page.screenshot({ path: `${artifacts}history-empty-desktop-${theme}.png` });
  }
  await page.setViewportSize({ width: 390, height: 844 });
  const cdp = await context.newCDPSession(page);
  await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: true });
  assert.equal(await page.evaluate(() => matchMedia("(pointer: coarse)").matches), true, "Chromium mobile touch emulation");
  for (const theme of ["matte-black", "lupine"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await page.screenshot({ path: `${artifacts}history-empty-mobile-${theme}.png` });
    await page.evaluate(() => { historyFixture.empty = false; NRCHistory.open(); });
    await page.waitForFunction(() => document.getElementById("historyStatus").textContent.includes("3 EVENTS"));
    await page.screenshot({ path: `${artifacts}history-mobile-${theme}.png` });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "no document overflow");
    await page.evaluate(() => { historyFixture.empty = true; NRCHistory.refresh(); });
  }
  await page.evaluate(() => { historyFixture.hold = true; NRCHistory.refresh(); serverReady = false; NRCHistory.disconnect(); historyFixture.replies.shift()(); });
  assert.match(await page.locator("#historyStatus").innerText(), /OFFLINE/);
  assert.equal(await page.locator("#historyBody .history-event").count(), 0);
  assert.deepEqual(errors, []);
  console.log("History browser fixture: request bytes, app routing, lossless IDs, escaping, paging/exhaustion, task/asset scope, clear, stale responses, error/retry, empty, disconnect; both themes at 1440 and 390: PASS");
} finally { await browser.close(); }
