// Production UI, deterministic HTTP/exact-read fixtures; no shared server writes.
// NRC_CUSTOMER_SEARCH_SCREENSHOTS=.amp/in/artifacts/customer-search node client/customer-search.e2e.mjs
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const browser = await chromium.launch();
const context = await browser.newContext({ serviceWorkers: "block", deviceScaleFactor: 2, viewport: { width: 1440, height: 900 } });
const page = await context.newPage();
const requests = [], errors = [];
const preview = (title, extra = {}) => JSON.stringify({ version: 1, title, ...extra });
const hit = (id, type, title, extra = {}) => ({ entity: { workspace: "customer-search-demo", conv_id: "0", type: "asset", id },
  metadata: { asset_type: type }, preview: preview(title, extra), payload: type === 10 ? "Discussed the rollout and training schedule." : "" });
let response = { results: [hit("99", 8, "Nordwerk GmbH", { number: "C-099", city: "Herford", assignee: "Rene" })] };
let fail = false, hold = false, release;
const capture = async name => {
  if (!process.env.NRC_CUSTOMER_SEARCH_SCREENSHOTS) return;
  await fs.mkdir(process.env.NRC_CUSTOMER_SEARCH_SCREENSHOTS, { recursive: true });
  await page.screenshot({ path: `${process.env.NRC_CUSTOMER_SEARCH_SCREENSHOTS}/${name}.png` });
};
try {
  page.on("pageerror", error => errors.push(error.message));
  await page.addInitScript(() => {
    window.WebSocket = class { static OPEN = 1; static CONNECTING = 0; static CLOSED = 3; readyState = 0; send() {} close() {} };
  });
  await page.route("http://nrc.test/**", async route => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/features") return route.fulfill({ json: { customers: true } });
    if (url.pathname === "/search") {
      requests.push(route.request().postDataJSON());
      const json = response, status = fail ? 503 : 200;
      if (hold) await new Promise(resolve => { release = resolve; });
      await route.fulfill({ status, json, headers: { "X-NRC-Search-Version": "typed-v1" } });
      return;
    }
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${url.pathname === "/" ? "/index.html" : url.pathname}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404 }); }
  });
  await page.goto("http://nrc.test/#workspace=customer-search-demo");
  await page.waitForFunction(() => NRCCustomers.isEnabled());
  await page.evaluate(() => {
    serverReady = true; ws.readyState = WebSocket.OPEN;
    window.registerReads = []; window.exactReads = [];
    const company = (id, title) => ({ assetId: id, convId: 0n, assetType: 8, preview: JSON.stringify({ version: 1, title }), payload: "", attachments: [], createdAt: 0n });
    NRCAssets.requestCustomerPage = async (_room, options) => {
      window.registerReads.push({ query: options.query, cursor: String(options.afterId), includeArchived: options.includeArchived });
      return { assets: options.afterId ? [company(2n, "Second page company")] : [company(1n, options.query ? "Text fallback company" : "Regular company")],
        totalCount: 2, nextId: options.afterId ? 0n : 1n, hasMore: !options.afterId };
    };
    NRCAssets.requestAsset = (_room, id, options) => {
      window.exactReads.push(String(id));
      const type = id === 100n ? 9 : id === 101n ? 10 : 8;
      const asset = { ...company(id, id === 99n ? "Exact Nordwerk company" : id === 100n ? "Exact Anna contact" : id === 101n ? "Exact rollout activity" : "Regular company"), assetType: type,
        preview: JSON.stringify({ version: 1, title: id === 99n ? "Exact Nordwerk company" : id === 100n ? "Exact Anna contact" : id === 101n ? "Exact rollout activity" : "Regular company", email: "anna@example.com", role: "Engineer", kind: "Meeting" }), payload: "Authoritative activity body" };
      options.onSuccess({ asset });
    };
    NRCEdges.requestEdgePage = async () => ({ session: { seen: new Set() }, hasMore: false });
    NRCEdges.getEdgesForEntity = () => [];
    NRCViewManager.setActiveView("customers");
    NRCWorkspaceSearch.onReconnect();
  });
  const waitRegister = () => page.waitForFunction(() => !document.getElementById("customerNew").disabled);
  await waitRegister();
  assert.equal(requests.length, 0, "empty register never queries embeddings");
  assert.match(await page.locator("#customersList").textContent(), /Regular company/);
  const query = page.locator("#customersSearch");
  const search = async text => {
    const previous = requests.length;
    await query.fill(text);
    await page.waitForFunction(n => document.getElementById("customersState").textContent.includes("RESULTS"), previous);
    assert.ok(requests.length > previous);
    await waitRegister();
  };
  await search("Anna");
  assert.deepEqual(requests.at(-1).filters, { entity_types: ["asset"], asset_types: [8, 9], customer: { include_archived: false } });
  assert.equal(requests.at(-1).conv_id, "0");
  assert.equal(requests.at(-1).workspace, "customer-search-demo");
  assert.equal(await page.locator(".customer-row").getAttribute("data-company"), "99");
  assert.equal(await page.evaluate(() => NRCAssets.roomAssets.get(0n)?.has(99n) || false), false, "projections never write exact cache");
  await page.locator(".customer-row").click();
  await page.waitForFunction(() => document.querySelector("#customerRecord").textContent.includes("Exact Nordwerk company"));
  assert.ok((await page.evaluate(() => window.exactReads)).includes("99"));
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
      await capture(`register-${theme}-${width}`);
    }
  }
  response = { ...response, stale: true };
  await page.locator("#customersRefresh").click();
  await page.waitForFunction(() => document.getElementById("customersStatus").textContent.includes("outdated"));
  await capture("register-stale");
  await page.locator("label:has(#customersArchived)").click();
  await page.waitForFunction(() => document.getElementById("customersState").textContent.includes("RESULTS"));
  await page.waitForTimeout(300);
  assert.equal(requests.at(-1).filters.customer.include_archived, true);
  const beforeClear = requests.length;
  await query.fill("   "); await waitRegister();
  await page.waitForFunction(() => document.getElementById("customersState").textContent.includes("CUSTOMERS"));
  assert.equal(requests.length, beforeClear, "clearing query restores NRC listing without HTTP search");
  await page.evaluate(() => document.getElementById("customersPager").dispatchEvent(new CustomEvent("nrc:load-more")));
  await page.waitForFunction(() => window.registerReads.at(-1).cursor === "1");
  assert.match(await page.locator("#customersList").textContent(), /Second page company/);
  fail = true;
  await query.fill("fallback");
  await page.waitForFunction(() => document.getElementById("customersStatus").textContent.includes("using NRC server text search"));
  assert.equal((await page.evaluate(() => window.registerReads)).at(-1).query, "fallback");
  assert.match(await page.locator("#customersList").textContent(), /Text fallback company/);
  await capture("register-fallback");
  fail = false; hold = true;
  await query.fill("late");
  while (!release) await new Promise(resolve => setTimeout(resolve, 10));
  await query.fill("");
  await page.waitForFunction(() => document.getElementById("customersList").textContent.includes("Regular company"));
  hold = false; release();
  await page.waitForTimeout(300);
  assert.doesNotMatch(await page.locator("#customersList").textContent(), /Nordwerk/);
  await page.evaluate(() => { serverReady = false; NRCCustomers.onDisconnect(); });
  const offlineRequests = requests.length;
  await query.fill("offline"); await page.waitForTimeout(300);
  assert.equal(requests.length, offlineRequests);
  assert.match(await page.locator("#customersStatus").textContent(), /OFFLINE/);
  await page.evaluate(() => { serverReady = true; NRCViewManager.setActiveView("search"); });
  response = { results: [hit("99", 8, "Nordwerk GmbH", { number: "C-099", city: "Herford" }),
    hit("100", 9, "Anna Richter", { role: "Engineer", email: "anna@example.com" }), hit("101", 10, "Rollout discussion", { kind: "Meeting", excerpt: "Training and rollout" })] };
  await page.locator("#workspaceSearchQuery").fill("rollout");
  await page.locator("#workspaceSearchForm").dispatchEvent("submit");
  await page.waitForFunction(() => document.querySelectorAll(".workspace-search-row").length === 3);
  assert.deepEqual(requests.at(-1).filters.asset_types, [1, 2, 3, 4, 5, 8, 9, 10]);
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
      await capture(`global-${theme}-${width}`);
    }
  }
  for (const [id, title] of [["99", "Exact Nordwerk company"], ["100", "Exact Anna contact"], ["101", "Exact rollout activity"]]) {
    await page.locator(`[data-key="asset:${id}"]`).click();
    await page.waitForFunction(title => document.getElementById("inspectorEntityHost").textContent.includes(title), title);
    await page.evaluate(() => NRCInspector.close());
  }
  assert.deepEqual(errors, []);
  console.log("PASS: customer hybrid/blank/paged/fallback/stale/archive/offline/cancel contracts, uncached projections and exact reads; company/contact/activity global inspectors; both themes and widths");
} finally { await browser.close(); }
