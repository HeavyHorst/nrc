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
    window.overviewFixture = { empty: false, fail: false, incomplete: false };
    serverReady = true;
    const encoder = new TextEncoder();
    const names = ["RELEASE 1.8", "CUSTOMER ONBOARDING", "PLATFORM", "CLOSED"];
    const values = [[3, 5, 6, 2], [4, 6, 3, 1], [5, 5, 5, 3], [0, 0, 0, 8]];
    const now = Date.now();
    // Both sides of every bucket boundary, plus empty, done-only and closed.
    const boundaryRows = [0, 1, 5, 6, 15, 16, 30, 31].map((size, i) => ({
      name: `BOUNDARY ${i}`, sliceId: i + 1, flags: 0,
      backlog: i === 0 ? 0 : 1, todo: 0, inProgress: 0, done: Math.max(0, size - 1),
      blocked: [0, 1, 2, 3, 0, 2, 3, 0][i],
      oldestActiveAt: i === 0 ? 0n : BigInt(now - [0, 7, 8, 30, 31, 90, 91, 2][i] * 86400000) * 1000000n,
    }));
    boundaryRows.push({ name: "DONE ONLY", sliceId: 9, flags: 0, backlog: 0, todo: 0, inProgress: 0, done: 4, blocked: 0, oldestActiveAt: 0n });
    boundaryRows.push({ ...boundaryRows[7], name: "CLOSED BOUNDARY", sliceId: 10, flags: 1 });
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
      if (opcode === 28) {
        const view = new DataView(new ArrayBuffer(42));
        view.setUint16(0, 138); view.setUint8(10, f.fail ? 0 : 1);
        // No rows loaded, but server totals must still be used.
        const counts = f.large ? largeCounts : [12, 16, 14, 6];
        view.setUint32(32, f.empty ? 0 : (counts[[1, 2, 4, 8].indexOf(request.getUint8(10))] || 0));
        view.setUint32(38, id);
        handleBinaryMessage(view.buffer);
      }
      if (opcode === 56) {
        let cursorOffset = 14 + request.getUint16(12);
        cursorOffset += 3 + request.getUint16(cursorOffset + 1);
        cursorOffset += 2; // requested page size
        const start = f.large && request.getUint8(cursorOffset) ? Number(request.getBigUint64(cursorOffset + 10)) : 0;
        const allRows = f.empty ? [] : f.boundaries ? boundaryRows : f.large ? largeSlices : names.map((name, i) => ({
          name, sliceId: i + 1, flags: i === 3 ? 1 : 0,
          backlog: values[i][0], todo: values[i][1], inProgress: values[i][2], done: values[i][3],
          blocked: [3, 2, 2, 0][i], oldestActiveAt: BigInt(now - [12, 9, 21, 0][i] * 86400000) * 1000000n,
        }));
        const rows = f.large ? allRows.slice(start, start + 25) : allRows;
        const more = f.incomplete || start + rows.length < allRows.length;
        const view = new DataView(new ArrayBuffer(49 + rows.reduce((n, row) => n + 43 + encoder.encode(row.name).length, 0)));
        let offset = 0;
        const u8 = v => view.setUint8(offset++, v);
        const u16 = v => { view.setUint16(offset, v); offset += 2; };
        const u32 = v => { view.setUint32(offset, v); offset += 4; };
        const u64 = v => { view.setBigUint64(offset, BigInt(v)); offset += 8; };
        const str = value => { const b = encoder.encode(value); u16(b.length); new Uint8Array(view.buffer, offset, b.length).set(b); offset += b.length; };
        u16(164); u64(0); u8(f.fail ? 0 : 1); u16(rows.length);
        rows.forEach(row => { str(row.name); u64(row.sliceId); str(""); u8(row.flags);
          for (const value of [row.backlog, row.todo, row.inProgress, row.done, row.blocked, 0, 0]) u16(value);
          u64(row.oldestActiveAt); u64(0);
        });
        u8(more ? 1 : 0); u8(0); u64(0); u64(rows.at(-1)?.sliceId || 0); u32(allRows.length);
        u32(f.empty || start ? 0 : f.large ? 850 : 39); u32(f.empty || start ? 0 : f.large ? 150 : 9); str(""); u32(id);
        handleBinaryMessage(view.buffer);
      }
    }
    ws = { readyState: WebSocket.OPEN, send: buffer => queueMicrotask(() => reply(buffer)) };
    // The status sender uses the production query encoder and response parser.
  });
  await page.click("#overviewBtn");
  await page.waitForFunction(() => document.getElementById("overviewStatus").hidden);
  assert.match(await page.locator("#overviewBody").innerText(), /48 UNIQUE TASKS/);
  assert.equal(await page.locator("[data-overview-status]").count(), 4);
  assert.equal(await page.locator(".overview-bucket").count(), 13);
  assert.doesNotMatch(await page.locator("#overviewBody").innerText(), /NEEDS ATTENTION|CLOSED\n/);
  assert.deepEqual(await page.locator(".overview-legend").first().locator("span").allTextContents(), ["BACKLOG", "TODO", "IN PROGRESS", "DONE"]);
  assert.deepEqual(await page.locator(".overview-bar--coverage .overview-segment").allTextContents(), ["39", "9"]);
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
  await page.evaluate(() => { window.overviewFixture.fail = false; window.overviewFixture.incomplete = true; });
  await page.click("#overviewRefresh");
  await page.waitForFunction(() => document.getElementById("overviewStatus").textContent.includes("READ FAILED"));
  assert.match(await page.locator("#overviewBody").innerText(), /48 UNIQUE TASKS/);
  await page.evaluate(() => { window.overviewFixture.incomplete = false; });
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
  await page.click("#overviewBtn");
  await page.waitForFunction(() => document.getElementById("overviewStatus").hidden);
  await page.evaluate(() => { window.overviewFixture.boundaries = true; });
  await page.click("#overviewRefresh");
  await page.waitForFunction(() => document.getElementById("overviewStatus").hidden);
  assert.deepEqual(await page.locator(".overview-bucket strong").allTextContents(), ["1", "3", "2", "2", "1", "4", "3", "2", "2", "2", "2", "1", "2"], "boundary values, done tasks, empty slices and closed exclusion");
  await page.evaluate(() => { window.overviewFixture.boundaries = false; });
  await page.evaluate(() => { window.overviewFixture.large = true; });
  await page.click("#overviewRefresh");
  await page.waitForFunction(() => document.getElementById("overviewStatus").hidden && document.getElementById("overviewBody").textContent.includes("1000 UNIQUE TASKS"));
  assert.equal(await page.locator(".overview-bucket").count(), 13, "100 slices produce the same fixed-size distributions as three slices");
  assert.equal(await page.locator("[data-overview-slice]").count(), 0);
  assert.doesNotMatch(await page.locator("#overviewBody").innerText(), /CUSTOMER MIGRATION|MOBILE \/ 100/);
  assert.deepEqual(await page.locator(".overview-distribution").evaluateAll(charts => charts.map(chart => [...chart.querySelectorAll("strong")].reduce((sum, el) => sum + Number(el.textContent), 0))), [100, 100, 100], "each distribution includes every page exactly once");
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
  console.log("Overview: unique server totals, overlapping/closed slices, stale-error retention, status drill-down, empty/offline and theme/width checks passed");
  console.log("Large fixture: 100 slices, 1000 tasks, all pages aggregated into 13 buckets; boundary checks passed");
} finally { await browser.close(); }
