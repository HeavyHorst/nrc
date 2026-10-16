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
    NRCAssets.requestAssetsByIds = (_room, ids) => Promise.all(ids.map(id => new Promise(resolve =>
      NRCAssets.requestAsset(0n, id, { onSuccess: detail => {
        if (!NRCAssets.roomAssets.has(0n)) NRCAssets.roomAssets.set(0n, new Map());
        NRCAssets.roomAssets.get(0n).set(id, detail.asset);
        resolve(detail.asset);
      } }))));
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
  assert.equal(requests.at(-1).top_n, 20);
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
  // Asymmetric lists cross both display-page and relationship-page boundaries.
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.evaluate(() => {
    const assets = new Map(), edges = [];
    const make = (id, assetType, title, extra = {}) => {
      const asset = { assetId: BigInt(id), convId: 0n, assetType, preview: JSON.stringify({ version: 1, title, ...extra }),
        payload: assetType === 3 ? JSON.stringify({ type: "file", version: 1, title }) : "Fixture record", attachments: [], owner: "Rene", createdAt: BigInt(Date.UTC(2026, 9, id % 15 + 1)) * 1000000n };
      assets.set(asset.assetId, asset);
      return asset;
    };
    const company = make(200, 8, "Nordwerk GmbH", { city: "Herford", assignee: "Rene", number: "C-200", address: "Werkstraße 18, Herford", website: "https://nordwerk.example", sector: "Medien" });
    const link = asset => edges.push({ edgeId: BigInt(edges.length + 1), convId: 0n, sourceType: 1, sourceId: asset.assetId,
      targetType: 1, targetId: 200n, relation: [9, 10].includes(asset.assetType) ? 7 : 2 });
    for (let i = 0; i < 26; i++) link(make(300 + i, 9, `Contact ${String(i + 1).padStart(2, "0")}`, { role: i ? (i % 2 ? "Support" : "") : "Project lead", email: `contact${i + 1}@nordwerk.example`, phone: "+49 5221 12345" }));
    for (let i = 0; i < 8; i++) link(make(400 + i, 10, `Customer discussion ${i + 1}`, { kind: i % 2 ? "Call" : "Meeting", excerpt: "Training schedule agreed; documentation sent." }));
    for (let i = 0; i < 30; i++) link(make(500 + i, 5, `Rollout documentation ${i + 1}`));
    for (let i = 0; i < 27; i++) link(make(600 + i, 3, `Customer document ${i + 1}`));
    link(make(700, 11, "Rollout 2026"));
    window.customerEdgeReads = 0;
    NRCAssets.roomAssets.set(0n, assets);
    NRCAssets.requestAssetsByIds = async (_room, ids) => ids.map(id => assets.get(id)).filter(Boolean);
    NRCAssets.requestAsset = (_room, id, options) => options.onSuccess({ asset: assets.get(id) });
    NRCTasks.requestTasksByIds = async () => [];
    NRCEdges.getEdgesForEntity = (_room, _type, id) => id === 200n ? edges : [];
    NRCEdges.requestEdgePage = async (_room, _type, id, options = {}) => {
      if (id !== 200n) return { session: { seen: new Set() }, hasMore: false };
      window.customerEdgeReads++;
      if (window.failCustomerPage) { window.failCustomerPage = false; throw new Error("Fixture relationship failure"); }
      const size = options.session ? edges.length : 50;
      return { session: { seen: new Set(edges.slice(0, size).map(edge => edge.edgeId)) }, hasMore: size < edges.length };
    };
    document.getElementById("customersSearch").value = "";
    NRCCustomers.openCompany(company);
  });
  await page.waitForFunction(() => document.querySelector("#customerRecord h2")?.textContent === "Nordwerk GmbH" && !document.getElementById("customerRecord").inert);
  assert.equal(await page.locator("[data-contact]:visible").count(), 4);
  assert.equal(await page.locator("[data-activity]:visible").count(), 4);
  assert.doesNotMatch(await page.locator(".customer-record-body").textContent(), /Counts and search cover loaded links only/);
  assert.match(await page.locator('nav [data-customer-tab="contacts"]').textContent(), /26\+/);
  await page.locator('nav [data-customer-tab="contacts"]').click();
  assert.match(await page.locator(".customer-record-body").textContent(), /Counts and search cover loaded links only/);
  await page.locator('nav [data-customer-tab="overview"]').click();
  await page.waitForTimeout(500);
  assert.equal(await page.evaluate(() => window.customerEdgeReads), 1, "overview does not drain relationship pages");
  await capture("overview-partial");
  await page.evaluate(() => window.failCustomerPage = true);
  await page.locator("#customerRelationshipsMore").click();
  await page.waitForFunction(() => document.getElementById("customersStatus").textContent.includes("Fixture relationship failure"));
  await page.locator("#customerRelationshipsMore").click();
  await page.waitForFunction(() => !document.getElementById("customerRecord").inert && document.getElementById("customerRelationshipsMore")?.textContent === "LOAD MORE LINKS");
  await page.locator("#customerRelationshipsMore").click();
  await page.waitForFunction(() => !document.getElementById("customerRelationshipsMore"));
  const tab = name => page.locator(`nav [data-customer-tab="${name}"]`).click();
  await tab("contacts");
  assert.equal(await page.locator("[data-contact]:visible").count(), 25);
  await page.locator('[data-page="contacts:next"]').click();
  assert.equal(await page.locator("[data-contact]:visible").count(), 1);
  assert.match(await page.locator("[data-contact]:visible").textContent(), /Contact 26/);
  await tab("activities"); await tab("contacts");
  assert.match(await page.locator("[data-contact]:visible").textContent(), /Contact 26/, "tab changes preserve display pages");
  await page.locator("#customerRecordSearch").fill("contact1@");
  assert.equal(await page.locator("[data-contact]:visible").count(), 1);
  assert.match(await page.locator("[data-contact]:visible").textContent(), /Contact 01/);
  await page.locator("[data-contact]:visible").click();
  await page.waitForSelector("#customerForm");
  assert.match(await page.locator("#customerForm").textContent(), /Contact 01/);
  await page.evaluate(() => NRCInspector.close());
  await tab("activities");
  await page.locator("#customerHistoryFilter").selectOption("Meeting", { force: true });
  assert.equal(await page.locator("[data-activity]:visible").count(), 4);
  assert.deepEqual(await page.locator("[data-activity]:visible").evaluateAll(rows => rows.map(row => row.dataset.kind)), Array(4).fill("Meeting"));
  await tab("work");
  await page.locator("#customerRecordSearch").fill("Rollout 2026");
  assert.match(await page.locator("#customerWork").textContent(), /SLICE #700/);
  await tab("files");
  assert.equal(await page.locator(".file-assets-row:visible").count(), 25);
  await page.locator('[data-page="files:next"]').click();
  assert.equal(await page.locator(".file-assets-row:visible").count(), 2);
  assert.match(await page.locator("#customerFiles").textContent(), /Customer document 27/);
  for (const theme of ["catppuccin-latte", "dark"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
      for (const section of ["overview", "contacts", "activities", "work", "files"]) {
        await tab(section);
        await page.evaluate(() => document.getElementById("customersPanel").scrollTop = 0);
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no page-level horizontal overflow");
        assert.ok(await page.locator(".customer-tabs .active").evaluate(button => {
          const tab = button.getBoundingClientRect(), nav = button.parentElement.getBoundingClientRect();
          return tab.left >= nav.left - 1 && tab.right <= nav.right + 1;
        }), "selected section remains visible in the horizontally scrolling tab strip");
        await capture(`${section}-${theme}-${width}`);
        const lastPage = page.locator("#customerRecord .customer-page:visible").last();
        await lastPage.scrollIntoViewIfNeeded();
        assert.ok(await lastPage.evaluate(element => {
          const bounds = element.getBoundingClientRect();
          const root = document.getElementById(innerWidth <= 768 ? "customersPanel" : "customerRecord").getBoundingClientRect();
          const header = document.querySelector(".customer-record-header").getBoundingClientRect();
          return bounds.bottom <= root.bottom + 1 && bounds.top >= header.bottom - 1;
        }), "last page controls scroll clear of the fixed footer and sticky customer header");
      }
    }
  }
  assert.deepEqual(errors, []);
  console.log("PASS: customer search and exact-read contracts; bounded overview, tab paging, search, activity filter, slice links, files, partial/retry states; both themes and widths");
} finally { await browser.close(); }
