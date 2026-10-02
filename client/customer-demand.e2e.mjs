// Run only against the disposable customer-workspace-dev fixture.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error("Set NRC_CUSTOMERS_TEST_URL to the disposable fixture");
const browser = await chromium.launch();
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const page = await context.newPage();
  const errors = [];
  const sent = [];
  let socket;
  page.on("pageerror", e => errors.push(e.message));
  page.on("websocket", s => { socket = s; s.on("framesent", e => { if (Buffer.isBuffer(e.payload)) sent.push(e.payload); }); });
  await page.goto(`${url}/#workspace=customer-demand-${Date.now()}`);
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  const ids = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const create = (type, title) => rpc(o => NRCAssets.sendCreateAsset(currentRoomId, type, 0, 0n, JSON.stringify({ version: 1, title }), "", 0, o));
    let first, last, middle;
    for (let i = 0; i < 60; i++) {
      const company = await create(8, `Company ${String(i).padStart(2, "0")}`);
      first ??= company.asset.assetId;
      if (i === 10) middle = company.asset.assetId;
      last = company.asset.assetId;
    }
    const contact = (await create(9, "Zürich Ansprechpartner")).asset.assetId;
    await rpc(o => NRCEdges.sendCreateEdge(currentRoomId, 1, contact, 1, last, 7, o));
    for (let i = 0; i < 114; i++) await rpc(o => NRCTransactions.sendCreateLinkedAsset(currentRoomId, 10,
      JSON.stringify({ version: 1, title: `Call ${i}`, kind: "Call", excerpt: "Decision" }), `Record ${i}`, last, o));
    const unrelated = (await create(5, "Unrelated note")).asset.assetId;
    // Linked to a company this session never opens, so opening another record
    // must not pull it in either.
    await rpc(o => NRCEdges.sendCreateEdge(currentRoomId, 1, middle, 1, unrelated, 1, o));
    const unseen = (await create(9, "Unseen Person")).asset.assetId;
    // The register opens on its first record, so the unseen contact hangs off a
    // company this session never opens: the search has to match it on the server
    // without the client holding its edges.
    const unseenEdge = await rpc(o => NRCEdges.sendCreateEdge(currentRoomId, 1, middle, 1, unseen, 7, o));
    for (let i = 0; i < 40; i++) await rpc(o => NRCAssets.sendCreateAsset(currentRoomId, 5, 0, 0n,
      JSON.stringify({ title: `Paged note ${i}`, padding: "x".repeat(3800) }), "", 0, o));
    return { last: String(last), first: String(first), contact: String(contact), unrelated: String(unrelated), unseenEdge: String(unseenEdge.edge.edgeId) };
  });
  await page.reload();
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  sent.length = 0;
  await page.click("#customersBtn");
  await page.waitForFunction(() => document.getElementById("customersState").textContent === "50 / 60 CUSTOMERS");
  assert.equal(await page.locator(".customer-row").count(), 50);
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 55).length, 1);
  // The register opens on its first record, so exactly that record's own first
  // edge page is read. The listing itself folds nothing: no typed collection and
  // no whole-edge set is fetched for it.
  assert.ok(!sent.some(b => [34, 35, 43, 53].includes(b.readUInt16BE(0))), "register does not read typed collections or the whole edge set");
  const autoSelected = await page.locator('.customer-row[aria-pressed="true"]').getAttribute("data-company");
  const registerEdgeReads = sent.filter(b => b.readUInt16BE(0) === 54);
  assert.equal(registerEdgeReads.length, 1, "the register reads only the auto-selected record's edges");
  assert.equal(registerEdgeReads[0].readBigUInt64BE(12), BigInt(autoSelected), "and reads them for that record");
  const unseenResponse = socket.waitForEvent("framereceived", { predicate: e => Buffer.isBuffer(e.payload) && e.payload.readUInt16BE(0) === 163 });
  await page.fill("#customersSearch", "Unseen Person"); await unseenResponse;
  await page.waitForFunction(() => document.getElementById("customersState").textContent === "1 / 1 CUSTOMERS");
  assert.equal(await page.evaluate(id => !!NRCEdges.getEdge(0n, BigInt(id)), ids.unseenEdge), false);
  const peer = await context.newPage();
  await peer.goto(page.url());
  await peer.waitForFunction(() => serverReady);
  await peer.evaluate(id => new Promise((resolve, reject) => NRCEdges.sendDeleteEdge(currentRoomId, BigInt(id), { onSuccess: resolve, onError: reject })), ids.unseenEdge);
  await page.waitForFunction(() => document.getElementById("customersState").textContent === "0 / 0 CUSTOMERS");
  await peer.close();
  const response = socket.waitForEvent("framereceived", { predicate: e => Buffer.isBuffer(e.payload) && e.payload.readUInt16BE(0) === 163 });
  await page.fill("#customersSearch", "zÜRICH");
  await response;
  await page.waitForFunction(() => document.getElementById("customersState").textContent === "1 / 1 CUSTOMERS");
  assert.equal(await page.locator(".customer-row").getAttribute("data-company"), ids.last, "contact search finds a company beyond the first page");
  assert.equal(await page.evaluate(() => [...NRCAssets.roomAssets.get(0n).values()].filter(a => a.assetType === 9 || a.assetType === 10).length), 0);
  sent.length = 0;
  await page.click(`[data-company="${ids.last}"]`);
  await page.waitForFunction(() => document.querySelectorAll("[data-activity]").length === 49 && !!document.getElementById("customerRelationshipsSentinel"));
  assert.equal(await page.locator(".customer-contact").count(), 1);
  assert.equal(await page.locator("[data-activity]").count(), 49);
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 54).length, 1, "first page only");
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 33).length, 51, "one GET per linked asset plus selected company, no duplicate hydration");
  assert.ok(!sent.some(b => [25, 34, 35, 43, 53].includes(b.readUInt16BE(0))), "detail does not prefetch room tasks, notes or edges");
  assert.ok(sent.filter(b => b.readUInt16BE(0) === 54).every(b => b.readBigUInt64BE(12) === BigInt(ids.last)));
  assert.equal(await page.evaluate(id => NRCAssets.roomAssets.get(0n).has(BigInt(id)), ids.unrelated), false);
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 54).length, 1, "offscreen sentinel does not load another page");
  if (process.env.NRC_CUSTOMERS_SCREENSHOTS) {
    await fs.mkdir(process.env.NRC_CUSTOMERS_SCREENSHOTS, { recursive: true });
    await page.screenshot({ path: `${process.env.NRC_CUSTOMERS_SCREENSHOTS}/demand-partial.png` });
  }
  await page.locator("#customerRelationshipsSentinel").scrollIntoViewIfNeeded();
  await page.waitForFunction(() => document.querySelectorAll("[data-activity]").length === 99);
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 54).length, 2, "first sentinel intersection loads exactly one page");
  await page.locator("#customerRelationshipsSentinel").scrollIntoViewIfNeeded();
  await page.waitForFunction(() => document.querySelectorAll("[data-activity]").length === 114);
  assert.equal(await page.locator("[data-activity]").count(), 114);
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 54).length, 3, "replacement sentinel loads the final page without duplicates");
  assert.equal(await page.locator("#customerRelationshipsSentinel").count(), 0);
  // Search pages never evict the selected company or unrelated shared caches.
  const reset = socket.waitForEvent("framereceived", { predicate: e => Buffer.isBuffer(e.payload) && e.payload.readUInt16BE(0) === 163 });
  await page.fill("#customersSearch", ""); await reset;
  await page.waitForFunction(() => document.querySelectorAll(".customer-row").length === 50);
  await page.click("#customersMore");
  await page.waitForFunction(() => document.getElementById("customersState").textContent === "60 / 60 CUSTOMERS");
  assert.equal(await page.locator("[data-activity]").count(), 114);
  assert.equal(await page.locator("#customersMore").isHidden(), true);
  await page.evaluate(() => {
    const handle = NRCAssets.handleAssetListPage;
    NRCAssets.handleAssetListPage = view => {
      NRCAssets.handleAssetListPage = handle;
      window.releaseNotePage = () => handle(view);
    };
  });
  await page.click("#customerLinkAdd");
  await page.waitForFunction(() => !!window.releaseNotePage);
  assert.equal(await page.locator(".note-link-picker:not(.hidden) .note-link-picker-list").textContent().then(s => s.includes("Paged note")), false, "nothing renders before the page lands");
  await page.evaluate(() => window.releaseNotePage());
  await page.waitForFunction(() => document.querySelectorAll(".note-link-picker:not(.hidden) .note-link-picker-item").length > 0);
  // The page is byte-bounded, so it holds part of the register; the rest is the
  // next page. Either way the released page lands in the open picker by itself.
  const released = await page.locator(".note-link-picker:not(.hidden) .note-link-picker-item").count();
  assert.ok(released < 41, `the released page lands without input (${released} of 41)`);
  await page.locator(".note-link-picker:not(.hidden) .note-link-picker-more").click();
  await page.waitForFunction(() => document.querySelector(".note-link-picker:not(.hidden) .note-link-picker-list").textContent.includes("Unrelated note"));
  assert.equal(await page.locator(".note-link-picker:not(.hidden) .note-link-picker-item").count(), 41, "late note page updates open picker without input");
  await page.keyboard.press("Escape");
  if (process.env.NRC_CUSTOMERS_SCREENSHOTS) {
    await fs.mkdir(process.env.NRC_CUSTOMERS_SCREENSHOTS, { recursive: true });
    for (const theme of ["dark", "light"]) {
      await page.evaluate(theme => document.documentElement.setAttribute("data-theme", theme), theme);
      await page.screenshot({ path: `${process.env.NRC_CUSTOMERS_SCREENSHOTS}/demand-${theme}.png` });
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator(".customer-section").first().scrollIntoViewIfNeeded();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.screenshot({ path: `${process.env.NRC_CUSTOMERS_SCREENSHOTS}/demand-mobile.png` });
  }
  assert.deepEqual(errors, []);
  console.log("PASS server contact search beyond first page; bounded register/detail pages; no whole-room reads; exact endpoint hydration; desktop/mobile states");
} finally { await browser.close(); }
