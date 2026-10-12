// Production UI with disposable protocol fixtures; no server writes.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: "block" });
const errors = [];
page.on("pageerror", error => errors.push(error.message));
try {
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${new URL(route.request().url()).pathname === "/" ? "/index.html" : new URL(route.request().url()).pathname}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCOverview && window.NRCSlices);
  await page.evaluate(() => {
    window.overviewFixture = { empty: false, fail: false, malformed: false, requests: [] };
    serverReady = true;
    const now = Date.now();
    const projects = ["PLATFORM", "CUSTOMER ONBOARDING", "BILLING", "MOBILE", "SECURITY", "SEARCH", "INTEGRATIONS", "OPERATIONS"];
    const largeSlices = Array.from({ length: 100 }, (_, i) => ({
      name: `${projects[i % projects.length]} / ${String(i + 1).padStart(3, "0")}`,
      sliceId: i + 1, flags: 0, backlog: 0, todo: 0, inProgress: 0, done: 0, blocked: 0,
      oldestActiveAt: 0n, members: [],
    }));
    largeSlices[41].name = "CUSTOMER MIGRATION / ENTERPRISE EUROPE / 042";
    const largeTasks = Array.from({ length: 1000 }, (_, i) => {
      const bucket = i % 20;
      const status = bucket < 5 ? 0 : bucket < 12 ? 1 : bucket < 17 ? 2 : 3;
      const memberships = i < 850 ? [i < 80 ? 0 : (i * 17) % 98] : [];
      if (memberships.length && i % 7 === 0) memberships.push((memberships[0] + 11) % 98);
      const task = { id: i + 1, title: `${projects[i % projects.length]}: test work item ${i + 1}`,
        status, blocked: status !== 3 && i % 13 === 0,
        createdAt: now - (1 + (i * 37) % 180) * 86400000,
        slices: memberships.map(index => largeSlices[index].name) };
      for (const index of memberships) {
        const slice = largeSlices[index];
        slice[["backlog", "todo", "inProgress", "done"][status]]++;
        if (task.blocked) slice.blocked++;
        const created = BigInt(task.createdAt) * 1000000n;
        if (status !== 3 && (slice.oldestActiveAt === 0n || created < slice.oldestActiveAt)) slice.oldestActiveAt = created;
        slice.members.push(task.id);
      }
      return task;
    });
    const largeCounts = [0, 0, 0, 0];
    for (const task of largeTasks) largeCounts[task.status]++;
    window.overviewLargeData = { tasks: largeTasks, slices: largeSlices, counts: largeCounts };
    function reply(buffer) {
      const request = new DataView(buffer), opcode = request.getUint16(0);
      const id = request.getUint32(request.byteLength - 4);
      const f = window.overviewFixture;
      if (window.NRCViewManager.getActiveView() === "overview") f.requests.push(opcode);
      if (opcode === 28) {
        const view = new DataView(new ArrayBuffer(42));
        view.setUint16(0, 138); view.setUint8(10, f.fail ? 0 : 1);
        // No rows loaded, but server totals must still be used.
        const counts = f.large ? largeCounts : [12, 16, 14, 6];
        view.setUint32(32, f.empty ? 0 : (counts[[1, 2, 4, 8].indexOf(request.getUint8(10))] || 0));
        view.setUint32(38, id);
        handleBinaryMessage(view.buffer);
      }
      if (opcode === 59) {
        if (request.byteLength !== 14 || request.getBigUint64(2) !== 0n) throw new Error("Invalid overview request");
        // Fixed server aggregates, not production-client aggregation. Odin tests
        // verify the fold; this checks decoding/rendering of independent values.
        const values = f.empty ? Array(20).fill(0) : f.large ?
          [250, 350, 250, 150, 850, 150, 100, 2, 0, 87, 10, 1, 42, 57, 1, 0, 0, 0, 98, 2] :
          [12, 16, 14, 6, 39, 9, 3, 0, 0, 1, 2, 0, 0, 2, 1, 0, 3, 0, 0, 0];
        const view = new DataView(new ArrayBuffer(105));
        view.setUint16(0, 167); view.setUint8(10, f.fail ? 0 : 1);
        view.setBigUint64(11, BigInt(now) * 1000000n);
        values.forEach((value, i) => view.setUint32(19 + i * 4, value));
        view.setUint16(99, f.malformed ? 1 : 0);
        view.setUint32(101, id);
        handleBinaryMessage(view.buffer);
      }
    }
    ws = { readyState: WebSocket.OPEN, send: buffer => queueMicrotask(() => reply(buffer)) };
    // Overview sends one fixed-size request through the production dispatcher.
  });
  await page.click("#overviewBtn");
  await page.waitForFunction(() => document.getElementById("overviewStatus").hidden);
  assert.deepEqual(await page.evaluate(() => window.overviewFixture.requests), [59], "one overview request, no slice pages or task queries");
  assert.match(await page.locator("#overviewBody").innerText(), /48 UNIQUE TASKS/);
  assert.equal(await page.locator("[data-overview-status]").count(), 4);
  assert.equal(await page.locator(".overview-bucket").count(), 13);
  assert.doesNotMatch(await page.locator("#overviewBody").innerText(), /NEEDS ATTENTION|CLOSED\n/);
  assert.deepEqual(await page.locator(".overview-legend").first().locator("span").allTextContents(), ["BACKLOG", "TODO", "IN PROGRESS", "DONE"]);
  assert.deepEqual(await page.locator(".overview-bar--coverage .overview-segment").allTextContents(), ["39", "9"]);
  assert.deepEqual(await page.locator(".overview-bar--coverage .overview-segment").evaluateAll(segments => segments.map(el => el.getAttribute("aria-label"))), ["In at least one slice: 39", "Without slice: 9"]);
  assert.equal(await page.locator(".overview-legend").last().locator("i").count(), 2, "coverage labels have matching color swatches without repeated numbers");
  assert.equal(await page.locator("#inspector").isVisible(), false);
  assert.equal(await page.locator("#inspector").evaluate(el => getComputedStyle(el).display), "none", "the inspector must release its layout space, not merely become invisible");
  assert.deepEqual(await page.locator(".overview-bucket strong").allTextContents(), ["0", "0", "1", "2", "0", "0", "2", "1", "0", "3", "0", "0", "0"]);
  const share = await page.locator(".overview-bucket-track > span").nth(2).evaluate(el => el.getBoundingClientRect().width / el.parentElement.getBoundingClientRect().width);
  assert.ok(Math.abs(share - 1 / 3) < 0.01, "bucket bars show the share of all open slices");
  assert.equal(await page.locator(".overview-explanation").getAttribute("open"), null);
  await page.locator(".overview-explanation summary").click();
  assert.equal(await page.locator(".overview-explanation p").isVisible(), true);
  await page.locator(".overview-explanation summary").click();
  await page.evaluate(() => { window.overviewFixture.fail = true; });
  await page.click("#overviewRefresh");
  await page.waitForFunction(() => document.getElementById("overviewStatus").textContent.includes("READ FAILED"));
  assert.match(await page.locator("#overviewBody").innerText(), /48 UNIQUE TASKS/);
  await page.evaluate(() => { window.overviewFixture.fail = false; window.overviewFixture.malformed = true; });
  await page.click("#overviewRefresh");
  await page.waitForFunction(() => document.getElementById("overviewStatus").textContent.includes("READ FAILED"));
  assert.match(await page.locator("#overviewBody").innerText(), /48 UNIQUE TASKS/);
  await page.evaluate(() => { window.overviewFixture.malformed = false; });
  await page.click("#overviewRefresh");
  await page.waitForFunction(() => document.getElementById("overviewStatus").hidden);
  if (process.env.OVERVIEW_SCREENSHOTS) {
    const dir = fileURLToPath(new URL("../.amp/in/artifacts/", import.meta.url));
    fs.mkdirSync(dir, { recursive: true });
    for (const theme of ["lupine", "matte-black"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await page.screenshot({ path: `${dir}overview-${theme}.png` });
      await page.setViewportSize({ width: 390, height: 844 });
      await page.locator(".overview-chart").last().scrollIntoViewIfNeeded();
      assert.equal(await page.locator(".overview-chart").last().evaluate(el => el.getBoundingClientRect().bottom <= document.querySelector(".mobile-bottom").getBoundingClientRect().top), true, "coverage can be scrolled fully above mobile navigation");
      assert.equal(await page.locator("#overviewBody").evaluate(el => el.scrollWidth <= el.clientWidth), true);
      await page.setViewportSize({ width: 390, height: 1400 });
      await page.locator("#overviewBody").evaluate(el => { el.scrollTop = 0; });
      await page.screenshot({ path: `${dir}overview-${theme}-narrow.png` });
      await page.setViewportSize({ width: 1600, height: 1000 });
    }
  }
  await page.click('[data-overview-status="2"]');
  assert.equal(await page.evaluate(() => window.NRCViewManager.getActiveView()), "kanban");
  assert.equal(await page.locator("#filterStatus").inputValue(), "2");
  await page.evaluate(() => window.NRCViewManager.setActiveView("chat"));
  assert.equal(await page.locator("#inspector").isVisible(), true, "Overview does not hide the inspector after leaving");
  // Let the Tasks view's debounced metadata refresh finish before measuring
  // Overview's own requests (it is not a request made by Overview).
  await page.waitForTimeout(250);
  await page.click("#overviewBtn");
  await page.waitForFunction(() => document.getElementById("overviewStatus").hidden);
  await page.evaluate(() => { window.overviewFixture.large = true; window.overviewFixture.requests = []; });
  await page.click("#overviewRefresh");
  await page.waitForFunction(() => document.getElementById("overviewStatus").hidden && document.getElementById("overviewBody").textContent.includes("1000 UNIQUE TASKS"));
  assert.equal(await page.locator(".overview-bucket").count(), 13, "100 slices produce the same fixed-size distributions as three slices");
  assert.equal(await page.locator("[data-overview-slice]").count(), 0);
  assert.doesNotMatch(await page.locator("#overviewBody").innerText(), /CUSTOMER MIGRATION|MOBILE \/ 100/);
  assert.deepEqual(await page.evaluate(() => window.overviewFixture.requests), [59], "large workspaces still need only one request");
  assert.deepEqual(await page.locator(".overview-distribution").evaluateAll(charts => charts.map(chart => [...chart.querySelectorAll("strong")].reduce((sum, el) => sum + Number(el.textContent), 0))), [100, 100, 100], "each distribution preserves complete server totals");
  assert.deepEqual(await page.locator("[data-overview-status]").allTextContents(), ["250", "350", "250", "150"]);
  assert.deepEqual(await page.locator(".overview-legend").last().locator("span").allTextContents(), ["IN AT LEAST ONE SLICE", "WITHOUT SLICE"]);
  assert.deepEqual(await page.locator(".overview-bar--coverage .overview-segment").allTextContents(), ["850", "150"]);
  assert.equal(await page.locator("#overviewBody").evaluate(el => el.scrollWidth <= el.clientWidth), true);
  if (process.env.OVERVIEW_SCREENSHOTS) {
    const dir = fileURLToPath(new URL("../.amp/in/artifacts/", import.meta.url));
    const data = await page.evaluate(() => JSON.stringify(window.overviewLargeData, (_, value) => typeof value === "bigint" ? value.toString() : value, 2));
    fs.writeFileSync(`${dir}overview-100-slices-1000-tasks.json`, data);
    await page.evaluate(() => { document.documentElement.dataset.theme = "lupine"; document.getElementById("overviewBody").scrollTop = 0; });
    await page.screenshot({ path: `${dir}overview-large-desktop.png` });
    await page.locator(".overview-chart").last().scrollIntoViewIfNeeded();
    await page.screenshot({ path: `${dir}overview-large-desktop-coverage.png` });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator("#overviewBody").evaluate(el => { el.scrollTop = 0; });
    await page.screenshot({ path: `${dir}overview-large-narrow.png` });
    assert.equal(await page.locator("#overviewBody").evaluate(el => el.scrollWidth <= el.clientWidth), true);
    await page.locator(".overview-chart").last().scrollIntoViewIfNeeded();
    assert.equal(await page.locator(".overview-chart").last().evaluate(el => el.getBoundingClientRect().bottom <= document.querySelector(".mobile-bottom").getBoundingClientRect().top), true);
    await page.screenshot({ path: `${dir}overview-large-narrow-coverage.png` });
    await page.setViewportSize({ width: 1600, height: 1000 });
  }
  await page.evaluate(() => { window.overviewFixture.empty = true; });
  await page.click("#overviewRefresh");
  await page.waitForFunction(() => document.getElementById("overviewBody").textContent.includes("NO TASKS"));
  assert.equal(await page.locator("[data-overview-status]").count(), 0);
  await page.evaluate(() => { serverReady = false; window.NRCOverview.disconnect(); });
  assert.match(await page.locator("#overviewStatus").innerText(), /OFFLINE/);
  assert.equal(await page.locator("#overviewBody").innerText(), "");
  assert.deepEqual(errors, []);
  console.log("Overview: one 14-byte request / 105-byte response, aggregate decoding, failure/malformed retention, status drill-down, empty/offline and theme/width checks passed");
  console.log("Large fixture: 100 slices, 1000 tasks rendered from one server aggregate; no slice-page or task-query requests");
} finally { await browser.close(); }
