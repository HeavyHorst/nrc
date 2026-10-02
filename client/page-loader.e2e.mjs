// Real custom-element lifecycle plus production Notes/Customers integration.
// node client/page-loader.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/features") return route.fulfill({ json: { customers: true } });
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.goto("http://nrc.test/");

  // Retain queued callbacks deliberately: a disconnected observer may still
  // deliver them. Verify identity guards, not just calls to disconnect().
  const result = await page.evaluate(() => {
    const NativeObserver = window.IntersectionObserver;
    window.IntersectionObserver = class {
      constructor(callback, options) { this.callback = callback; this.options = options; }
      observe() {}
      disconnect() { this.disconnected = true; }
      deliver() { this.callback([{ isIntersecting: true }]); }
    };
    try {
      const host = document.createElement("section");
      document.body.append(host);
      const a = document.createElement("nrc-page-loader"), b = document.createElement("nrc-page-loader");
      let first = 0, second = 0;
      a.addEventListener("nrc:load-more", () => first++);
      b.addEventListener("nrc:load-more", () => second++);
      a.setState({ hasMore: true, root: host });
      b.setState({ hasMore: true });
      host.append(a, b);
      const initial = a.observer;
      const rootCorrect = initial.options.root === host;
      initial.deliver(); initial.deliver(); a.button.click();
      const single = first === 1 && second === 0;
      a.setState({ loading: true }); a.button.click(); initial.deliver();
      const busy = a.getAttribute("aria-busy") === "true" && a.button.disabled && first === 1;
      a.setState({ loading: false, error: "Failed <not markup>" });
      initial.deliver();
      const errorStopsAuto = !a.observer && first === 1 && a.status.textContent === "Failed <not markup>" && !a.status.children.length;
      a.button.click(); a.button.click();
      const retryOnce = first === 2;
      a.setState({ error: "" });
      const stale = a.observer;
      a.setState({ active: false }); stale.deliver(); a.button.click();
      const inactive = first === 2 && stale.disconnected;
      a.setState({ active: true, disabled: true }); a.button.click();
      const disabled = first === 2 && !a.observer;
      a.setState({ disabled: false });
      const removed = a.observer;
      a.remove(); removed.deliver();
      const disconnected = removed.disconnected && first === 2;
      host.append(a); removed.deliver();
      a.observer.deliver();
      const reconnected = first === 3;
      a.setState({ hasMore: false });
      const exhausted = a.hidden && !a.observer && a.button.disabled;
      b.observer.deliver();
      const isolated = second === 1;
      b.setState({ hasMore: true });
      host.hidden = true; b.observer.deliver();
      const hidden = second === 1;
      host.hidden = false;
      window.IntersectionObserver = undefined;
      b.setState({ hasMore: true }); b.button.click();
      const fallback = second === 2;
      host.remove();
      return { rootCorrect, single, busy, errorStopsAuto, retryOnce, inactive, disabled, disconnected, reconnected, exhausted, isolated, hidden, fallback };
    } finally { window.IntersectionObserver = NativeObserver; }
  });
  for (const [name, passed] of Object.entries(result)) assert.equal(passed, true, name);

  // Real observer, virtualized Notes, real paging handler and cursor boundary.
  await page.setViewportSize({ width: 1800, height: 800 });
  await page.evaluate(() => {
    const notes = new Map();
    for (let i = 1; i <= 125; i++) notes.set(BigInt(i), {
      assetId: BigInt(i), convId: 0n, assetType: 5, owner: "tester", createdAt: 0n, updatedAt: BigInt(i),
      preview: JSON.stringify({ title: `Operational note ${i}`, project: "NRC", tags: [] }),
    });
    NRCAssets.roomAssets.set(0n, notes);
    Object.assign(getNotesPaginationState(0n), { initialized: true, loading: false, hasMore: true, totalCount: 127, nextCursorUpdatedAt: 901n, nextCursorAssetId: 57n });
    window.pageRequests = [];
    NRCAssets.sendListAssetsPaged = (...args) => pageRequests.push(args);
    invalidateNotesList(0n);
    showNotesView();
  });
  assert.equal(await page.evaluate(() => pageRequests.length), 0, "offscreen boundary does not prefetch");
  const horizontal = await page.evaluate(() => {
    const scroller = document.querySelector("#notesPanel .notes-container");
    scroller.style.setProperty("--note-columns", "0px 48px 1800px 130px 170px 110px 72px 72px");
    scroller.scrollLeft = scroller.clientWidth * 0.75;
    scroller.scrollTop = scroller.scrollHeight;
    const button = document.getElementById("notesLoadMoreBtn").getBoundingClientRect();
    return { left: scroller.scrollLeft, width: scroller.clientWidth, scrollWidth: scroller.scrollWidth, buttonRight: button.right, rootLeft: scroller.getBoundingClientRect().left, buttonOffscreen: button.right < scroller.getBoundingClientRect().left };
  });
  assert.ok(horizontal.left > 0 && horizontal.buttonOffscreen, JSON.stringify(horizontal));
  await page.waitForFunction(() => pageRequests.length === 1);
  assert.deepEqual(await page.evaluate(() => pageRequests[0].map(String)), ["0", "5", "false", "25", "901", "57"]);
  assert.equal(await page.locator("#notesLoadMoreBtn").isDisabled(), true);
  if (process.env.NRC_PAGER_SCREENSHOTS) {
    await fs.mkdir(process.env.NRC_PAGER_SCREENSHOTS, { recursive: true });
    for (const [theme, width] of [["dark", 1280], ["light", 390]]) {
      await page.setViewportSize({ width, height: 800 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await page.locator("#notesLoadMoreBtn").scrollIntoViewIfNeeded();
      await page.screenshot({ path: `${process.env.NRC_PAGER_SCREENSHOTS}/page-loader-notes-${theme}.png` });
    }
    await page.setViewportSize({ width: 1280, height: 800 });
  }
  await page.evaluate(() => {
    NRCViewManager.setActiveView("chat");
    showNotesView();
  });
  assert.equal(await page.evaluate(() => pageRequests.length), 1, "view return while loading does not duplicate page");
  await page.evaluate(() => handleNoteChanged({ convId: 0n, hasMore: false, totalCount: 125 }, "list_page"));
  assert.equal(await page.locator("#notesList nrc-page-loader").count(), 0, "last page removes control and observer");

  // Initial register errors must retry the first page, not an invalid continuation.
  await page.waitForFunction(() => NRCCustomers.isEnabled());
  await page.evaluate(() => {
    serverReady = true;
    window.customerRequests = [];
    NRCAssets.requestCustomerPage = (room, options) => new Promise((resolve, reject) => customerRequests.push({ options, resolve, reject }));
    NRCViewManager.setActiveView("customers");
  });
  await page.waitForFunction(() => customerRequests.length === 1);
  await page.evaluate(() => customerRequests[0].reject(new Error("CUSTOMER PAGE UNAVAILABLE")));
  await page.getByRole("button", { name: "RETRY", exact: true }).waitFor();
  assert.equal(await page.locator("#customersPager [role=status]").textContent(), "CUSTOMER PAGE UNAVAILABLE");
  assert.equal(await page.locator("#customersState").textContent(), "CUSTOMER QUERY FAILED");
  assert.equal(await page.locator("#customersList").textContent(), "", "failure must not claim an empty register");
  assert.equal(await page.evaluate(() => customerRequests.length), 1);

  if (process.env.NRC_PAGER_SCREENSHOTS) {
    await fs.mkdir(process.env.NRC_PAGER_SCREENSHOTS, { recursive: true });
    for (const [theme, width] of [["dark", 1280], ["light", 390]]) {
      await page.setViewportSize({ width, height: 800 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await page.screenshot({ path: `${process.env.NRC_PAGER_SCREENSHOTS}/page-loader-${theme}.png` });
    }
  }
  await page.locator("#customersMore").click();
  await page.waitForFunction(() => customerRequests.length === 2);
  assert.equal(await page.evaluate(() => String(customerRequests[1].options.afterId)), "0");
  await page.fill("#customersSearch", "different query");
  await page.waitForFunction(() => customerRequests.length === 3);
  assert.equal(await page.evaluate(() => customerRequests[1].options.isCancelled()), true);
  await page.evaluate(() => {
    customerRequests[1].reject(new Error("STALE ERROR"));
    customerRequests[2].resolve({ assets: [], hasMore: false, nextId: 0n, totalCount: 0 });
  });
  await page.waitForFunction(() => document.getElementById("customersPager").hidden);
  assert.equal(await page.locator("#customersPager [role=status]").textContent(), "");
  assert.equal(await page.locator("#customersState").textContent(), "0 / 0 CUSTOMERS");

  // A detail failure must neither block register continuation nor disable its
  // retry. Exercise both completion orders of concurrent reload failures.
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.evaluate(() => {
    window.customerRequests = [];
    window.edgeRequests = [];
    NRCEdges.requestEdgePage = () => new Promise((resolve, reject) => edgeRequests.push({ resolve, reject }));
    NRCCustomers.reload();
  });
  await page.waitForFunction(() => customerRequests.length === 1);
  await page.evaluate(() => customerRequests[0].resolve({
    assets: Array.from({ length: 50 }, (_, i) => ({ assetType: 8, assetId: BigInt(i + 1), convId: 0n, preview: JSON.stringify({ version: 1, title: `Company ${i + 1}` }) })),
    hasMore: true, nextId: 73n, totalCount: 51,
  }));
  await page.waitForFunction(() => edgeRequests.length === 1);
  await page.evaluate(() => edgeRequests[0].reject(new Error("DETAIL UNAVAILABLE")));
  await page.waitForFunction(() => document.getElementById("customersStatus").textContent === "DETAIL UNAVAILABLE");
  assert.equal(await page.locator("#customersMore").isDisabled(), false, "detail failure must not disable manual continuation");
  await page.locator("#customersMore").evaluate(button => button.click());
  await page.waitForFunction(() => customerRequests.length === 2);
  assert.equal(await page.evaluate(() => String(customerRequests[1].options.afterId)), "73");
  await page.evaluate(() => customerRequests[1].reject(new Error("CONTINUATION FAILED")));
  await page.waitForFunction(() => document.getElementById("customersMore").textContent === "RETRY");
  assert.equal(await page.locator(".customer-row").count(), 50, "page error preserves loaded rows");
  await page.locator("#customersMore").evaluate(button => button.click());
  await page.waitForFunction(() => customerRequests.length === 3);
  assert.equal(await page.evaluate(() => String(customerRequests[2].options.afterId)), "73", "retry keeps continuation cursor");
  for (const order of ["register-first", "detail-first"]) {
    await page.evaluate(() => {
      customerRequests = []; edgeRequests = [];
      NRCCustomers.reload();
    });
    await page.waitForFunction(() => customerRequests.length === 1 && edgeRequests.length === 1);
    await page.evaluate(async order => {
      if (order === "register-first") {
        customerRequests[0].reject(new Error("REGISTER FAILED"));
        await new Promise(resolve => setTimeout(resolve, 0));
        edgeRequests[0].reject(new Error("DETAIL FAILED"));
      } else {
        edgeRequests[0].reject(new Error("DETAIL FAILED"));
        await new Promise(resolve => setTimeout(resolve, 0));
        customerRequests[0].reject(new Error("REGISTER FAILED"));
      }
    }, order);
    await page.waitForFunction(() => document.getElementById("customersMore").textContent === "RETRY");
    assert.equal(await page.locator("#customersMore").isDisabled(), false, `${order}: independent register retry`);
    await page.locator("#customersMore").evaluate(button => button.click());
    await page.waitForFunction(() => customerRequests.length === 2);
    assert.equal(await page.evaluate(() => String(customerRequests[1].options.afterId)), "0", "reload retry starts at first page");
  }
  assert.deepEqual(errors, []);
  console.log("PASS: page-loader lifecycle, stale callbacks, single request, retry, isolation, hidden/disabled/exhausted states; Notes virtual paging and cursor; Customers initial retry and stale query response");
} finally { await browser.close(); }
