// Production shell with deterministic search and exact-read transport fixtures.
// node client/workspace-search.e2e.mjs
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const browser = await chromium.launch();
const context = await browser.newContext({ serviceWorkers: "block", deviceScaleFactor: 2 });
const page = await context.newPage();
const errors = [], requests = [];
let response = { results: [] }, fail = false, release;
const hit = (type, id, title, assetType) => ({
  entity: { workspace: "search-demo", type, id, conv_id: "0" },
  preview: title, payload: "Prepare the customer onboarding package and first meeting.",
  metadata: type === "task" ? { task: { status: 1, project: "Launch", assignee: "Rene" } }
    : { asset_type: assetType, attachments: [{ filename: "onboarding.pdf", status: "indexed" }] },
});
const mixed = { results: [hit("task", "184", "Prepare onboarding pack"), hit("asset", "184", "Onboarding guide", 3), hit("asset", "29", "Kickoff notes", 5), hit("asset", "31", "Meeting document", 2)] };
const capture = async name => {
  if (!process.env.NRC_SEARCH_SCREENSHOTS) return;
  await fs.mkdir(process.env.NRC_SEARCH_SCREENSHOTS, { recursive: true });
  await page.screenshot({ path: `${process.env.NRC_SEARCH_SCREENSHOTS}/${name}.png` });
};
const metrics = selector => page.locator(selector).evaluate(el => {
  const css = getComputedStyle(el);
  return { height: el.getBoundingClientRect().height, color: css.color, background: css.backgroundColor,
    font: css.fontFamily, size: css.fontSize, weight: css.fontWeight, border: css.borderColor };
});
async function checkHeaderConsistency(width) {
  const query = await metrics("#workspaceSearchQuery");
  const selector = await metrics("#workspaceSearchType-trigger");
  const action = await metrics("#workspaceSearchRetry");
  assert.ok(await page.locator("#workspaceSearchType-trigger .custom-select__value").evaluate(el => el.scrollWidth <= el.clientWidth), `${width}: selected type fits without truncation`);
  if (width <= 768) {
    const bottom = selector => page.locator(selector).evaluate(el => el.getBoundingClientRect().bottom);
    const typeBottom = await bottom("#workspaceSearchType-trigger");
    for (const selector of ["#workspaceSearchRetry", '#workspaceSearchForm button[type="submit"]']) {
      assert.ok(Math.abs(typeBottom - await bottom(selector)) <= 1, "mobile type and actions share the bottom baseline");
    }
  }
  const header = await metrics("#workspaceSearchForm");
  const identity = await metrics("#workspaceSearchForm > .header-register-identity-row");
  const controls = await metrics("#workspaceSearchForm > .header-register-control-row");
  await page.evaluate(() => NRCViewManager.setActiveView("notes"));
  assert.deepEqual(query, await metrics("#notesSearch"), `${width}: query height/font/colors match Notes`);
  const notesHeader = await metrics(".notes-header");
  assert.equal(header.background, notesHeader.background, "same semantic header surface");
  if (width > 768) {
    assert.deepEqual(identity, await metrics(".notes-header > .header-register-identity-row"), "same metadata row height/font/colors");
    assert.deepEqual(controls, await metrics(".notes-header > .header-register-control-row"), "same filter row height/font/colors");
  }
  await page.evaluate(() => {
    NRCViewManager.setActiveView("kanban");
    setTaskGrouping("flat");
    document.getElementById("taskFilterBar").classList.add("mobile-filters-open");
  });
  assert.deepEqual(selector, await metrics("#filterStatus-trigger"), `${width}: selector height/font/colors match Tasks`);
  assert.deepEqual(action, await metrics("#filterReset"), `${width}: action height/font/colors match Tasks`);
  await page.evaluate(() => {
    document.getElementById("taskFilterBar").classList.remove("mobile-filters-open");
    NRCViewManager.setActiveView("search");
  });
}
try {
  page.on("pageerror", e => errors.push(e.message));
  await page.addInitScript(() => {
    localStorage.setItem("nrc-ui-state", JSON.stringify({ roomId: "0", mode: "search" }));
    window.WebSocket = class {
      static OPEN = 1; static CONNECTING = 0; static CLOSED = 3;
      readyState = 0;
      send() {} close() {}
    };
  });
  await page.route("http://nrc.test/**", async route => {
    const url = new URL(route.request().url());
    if (url.pathname === "/search") {
      requests.push(route.request().postDataJSON());
      const body = JSON.stringify(response), status = fail ? 503 : 200;
      if (release === "hold") await new Promise(resolve => { release = resolve; });
      await route.fulfill({ status, contentType: "application/json", headers: { "X-NRC-Search-Version": "typed-v1" }, body });
      return;
    }
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${url.pathname === "/" ? "/index.html" : url.pathname}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test/#workspace=search-demo");
  await page.waitForFunction(() => NRCViewManager.getActiveView() === "search" && !!document.querySelector("#workspaceSearchQuery"));
  assert.match(await page.locator("#workspaceSearchStatus").textContent(), /Chat and DMs are not indexed/);
  await page.evaluate(() => {
    window.exactReads = [];
    NRCTasks.requestTask = (room, id, options) => options.onSuccess({ task: {
      id, convId: room, title: "Exact onboarding task", description: "Authoritative task body",
      status: 1, priority: 128, color: 0, assignee: "Rene", project: "Launch", createdBy: "Rene",
      createdAt: 1791374400000000000n, updatedAt: 1791374400000000000n,
      dueAt: 0n, blockedBy: 0n, completedAt: 0n, completedBy: "", externalRef: "", attachments: [],
    } });
    NRCAssets.requestAsset = (room, id, options) => {
      window.exactReads.push(`${room}:${id}`);
      options.onSuccess({ asset: { assetId: id, convId: room, assetType: id === 29n ? 5 : id === 31n ? 2 : 3,
        createdBy: "Rene", createdAt: 1791374400000000000n, updatedAt: 1791374400000000000n,
        preview: id === 29n ? JSON.stringify({ version: 1, title: "Exact kickoff notes" }) : "Onboarding guide",
        payload: id === 29n ? "Authoritative note body" : JSON.stringify({ version: 1, type: "file", title: "Onboarding guide", description: "Exact record read, not search payload", category: "Operations", tags: [] }),
        attachments: [{ fileId: "att_0123456789abcdef0123456789abcdef", filename: window.downloadOnly ? "source.zip" : "onboarding.pdf", mimeType: window.downloadOnly ? "application/zip" : "application/pdf", size: 4096 }] } });
    };
    NRCWorkspaceSearch.onReconnect(); // Exact-read transport fixture is ready.
  });
  const query = page.locator("#workspaceSearchQuery");
  const search = async text => { await query.fill(text); await page.locator("#workspaceSearchForm").dispatchEvent("submit"); await page.waitForFunction(() => document.querySelector("#workspaceSearchPanel").getAttribute("aria-busy") === "false"); };
  response = mixed;
  await search("onboarding");
  assert.equal(await page.locator(".workspace-search-row").count(), 4);
  assert.deepEqual(requests.at(-1).filters, { entity_types: ["task", "asset"], asset_types: [1, 2, 3, 4, 5, 8, 9, 10] });
  assert.equal(requests.at(-1).workspace, "search-demo");
  assert.equal(requests.at(-1).conv_id, "0");
  assert.equal(await page.evaluate(() => NRCAssets.roomAssets.get(0n)?.has(184n) || false), false, "search never fills exact-record cache");
  const file = page.locator('[data-key="asset:184"]');
  await page.locator('[data-key="task:184"]').focus();
  await page.keyboard.press("ArrowDown");
  assert.equal(await file.evaluate(el => el === document.activeElement), true);
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => document.querySelector('[data-key="asset:184"]').getAttribute("aria-pressed") === "true");
  assert.match(await page.locator("#inspectorEntityHost").textContent(), /Exact record read/);
  assert.equal(await page.locator("#inspectorEntityHost a[download]").count(), 1);
  assert.deepEqual(await page.evaluate(() => window.exactReads), ["0:184"]);
  for (const theme of ["light", "dark"]) {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await checkHeaderConsistency(1440);
    await capture(`desktop-${theme}`);
    await page.locator("#workspaceSearchType-trigger").click();
    assert.ok(await page.locator("#portal-container").getByRole("option", { name: "FILES", exact: true }).isVisible());
    await capture(`desktop-type-menu-${theme}`);
    await page.evaluate(() => CustomSelect.closeAll());
    await page.evaluate(() => NRCInspector.close());
    await page.setViewportSize({ width: 390, height: 844 });
    await checkHeaderConsistency(390);
    assert.ok(await query.isVisible());
    assert.equal(await query.evaluate(el => getComputedStyle(el).fontSize), "16px");
    assert.ok(await page.locator("#workspaceSearchPanel").evaluate(el => el.scrollWidth <= el.clientWidth), "mobile search does not overflow");
    await page.locator(".workspace-search-row").last().scrollIntoViewIfNeeded();
    assert.ok(await page.locator(".workspace-search-row").last().evaluate(el => el.getBoundingClientRect().bottom <= document.querySelector(".workspace-search-footer").getBoundingClientRect().top + 1), "last result is reachable above fixed footer");
    await page.locator("#workspaceSearchResults").evaluate(el => el.scrollTop = 0);
    await capture(`mobile-${theme}`);
    await file.click();
    await page.waitForFunction(() => document.body.classList.contains("inspector-open"));
    assert.equal(await page.locator("#inspector").getAttribute("role"), "dialog");
    await capture(`mobile-inspector-${theme}`);
    await page.evaluate(() => NRCInspector.close());
    await page.setViewportSize({ width: 1440, height: 900 });
    await file.click();
  }
  await page.evaluate(() => NRCInspector.close());
  await page.locator('[data-key="task:184"]').click();
  await page.waitForFunction(() => !NRCInspector.isLoading());
  assert.match(await page.locator("#inspectorEntityHost").textContent(), /Authoritative task body/);
  await page.evaluate(() => NRCInspector.close());
  await page.locator('[data-key="asset:29"]').click();
  await page.waitForFunction(() => !NRCInspector.isLoading());
  assert.match(await page.locator("#inspectorEntityHost").textContent(), /Authoritative note body/);
  await page.evaluate(() => NRCInspector.close());
  await page.locator('[data-key="asset:31"]').click();
  assert.match(await page.locator("#inspectorHeader").textContent(), /DOCUMENT #31/);
  await page.evaluate(() => NRCInspector.close());
  // DOWNLOAD is a native anchor, and must participate in the drawer's Tab trap.
  await page.setViewportSize({ width: 390, height: 844 });
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    for (const key of ["asset:184", "asset:31"]) {
      for (const downloadOnly of [false, true]) {
        await page.evaluate(value => window.downloadOnly = value, downloadOnly);
        await page.locator(`[data-key="${key}"]`).click();
        await page.waitForFunction(() => document.body.classList.contains("inspector-open"));
        const first = page.locator("#mobileInspectorBack");
        const download = page.locator("#inspectorEntityHost a[download]");
        await first.focus();
        let reached = false;
        for (let i = 0; i < 12; i++) {
          await page.keyboard.press("Tab");
          if (await download.evaluate(el => el === document.activeElement)) { reached = true; break; }
        }
        assert.ok(reached, `${key}/${theme}/${downloadOnly}: Tab reaches DOWNLOAD`);
        await page.keyboard.press("Tab");
        assert.equal(await first.evaluate(el => el === document.activeElement), true, "last action wraps to first drawer control");
        await page.keyboard.press("Shift+Tab");
        assert.equal(await download.evaluate(el => el === document.activeElement), true, "reverse wrap includes native download link");
        await page.evaluate(() => NRCInspector.close());
      }
    }
  }
  await page.evaluate(() => window.downloadOnly = false);
  await page.evaluate(() => { const el = document.querySelector("#workspaceSearchType"); el.value = "3"; el.dispatchEvent(new Event("change", { bubbles: true })); });
  await page.waitForFunction(() => document.querySelector("#workspaceSearchPanel").getAttribute("aria-busy") === "false");
  assert.deepEqual(requests.at(-1).filters, { entity_types: ["asset"], asset_types: [3] });
  await page.setViewportSize({ width: 1440, height: 900 });
  response = { results: [] };
  await search("missing");
  assert.match(await page.locator("#workspaceSearchStatus").textContent(), /No matching records/);
  await capture("empty");
  response = { results: [], stale: true };
  await search("stale");
  assert.match(await page.locator("#workspaceSearchStatus").textContent(), /outdated/);
  await capture("stale");
  fail = true;
  await search("failure");
  assert.match(await page.locator("#workspaceSearchCount").textContent(), /UNAVAILABLE/);
  await capture("error");
  fail = false;
  response = mixed;
  release = "hold";
  await query.fill("slow");
  await page.locator("#workspaceSearchForm").dispatchEvent("submit");
  await page.waitForFunction(() => document.querySelector("#workspaceSearchPanel").getAttribute("aria-busy") === "true");
  await capture("loading");
  while (typeof release !== "function") await new Promise(r => setTimeout(r, 10));
  await page.evaluate(() => NRCViewManager.setActiveView("notes"));
  release(); release = undefined;
  await page.evaluate(() => NRCViewManager.setActiveView("search"));
  await page.waitForFunction(() => document.querySelectorAll(".workspace-search-row").length === 4);
  response = { results: [hit("task", "7", '<img src=x onerror="window.injected=1">')] };
  await search("unsafe");
  assert.equal(await page.locator("#workspaceSearchResults img").count(), 0);
  assert.equal(await page.evaluate(() => window.injected), undefined);
  response = mixed;
  await search("before disconnect");
  await page.evaluate(() => NRCWorkspaceSearch.onDisconnect());
  const assertOffline = async () => {
    assert.match(await page.locator("#workspaceSearchStatus").textContent(), /offline.*Reconnect to open records/);
    assert.match(await page.locator("#workspaceSearchCount").textContent(), /OFFLINE/);
  };
  await assertOffline();
  await query.fill("HTTP still works"); // Actual debounced input path, not submit.
  await page.waitForFunction(() => document.querySelector("#workspaceSearchPanel").getAttribute("aria-busy") === "false");
  await assertOffline();
  await page.evaluate(() => { const el = document.querySelector("#workspaceSearchType"); el.value = "all"; el.dispatchEvent(new Event("change", { bubbles: true })); });
  await page.waitForFunction(() => document.querySelector("#workspaceSearchPanel").getAttribute("aria-busy") === "false");
  await assertOffline();
  await page.locator("#workspaceSearchRetry").click();
  await page.waitForFunction(() => document.querySelector("#workspaceSearchPanel").getAttribute("aria-busy") === "false");
  await assertOffline();
  await page.evaluate(() => { NRCViewManager.setActiveView("notes"); NRCViewManager.setActiveView("search"); });
  await assertOffline();
  const readsBefore = await page.evaluate(() => window.exactReads.length);
  await page.locator('[data-key="asset:31"]').click();
  assert.equal(await page.evaluate(() => NRCInspector.hasEntity()), false, "offline opener must not start an inspector load");
  assert.equal(await page.evaluate(() => window.exactReads.length), readsBefore, "no uncached exact read is queued offline");
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await capture(`offline-${theme}-${width}`);
    }
  }
  response = { results: [], stale: true };
  await search("offline stale");
  await assertOffline();
  assert.match(await page.locator("#workspaceSearchStatus").textContent(), /outdated/);
  fail = true;
  await search("offline failed HTTP");
  await assertOffline();
  assert.match(await page.locator("#workspaceSearchStatus").textContent(), /Search is unavailable/);
  fail = false;
  await query.fill("");
  await assertOffline();
  response = mixed;
  await search("after reconnect");
  await page.evaluate(() => NRCWorkspaceSearch.onReconnect());
  await page.waitForFunction(() => document.querySelector("#workspaceSearchPanel").getAttribute("aria-busy") === "false");
  assert.doesNotMatch(await page.locator("#workspaceSearchCount").textContent(), /OFFLINE/);
  assert.equal(await page.locator("#workspaceSearchStatus").isHidden(), true);
  await page.locator('[data-key="asset:31"]').click();
  assert.match(await page.locator("#inspectorHeader").textContent(), /READ ONLY/);
  assert.equal(await page.evaluate(() => window.exactReads.length), readsBefore + 1, "exact reads resume after reconnect");
  assert.deepEqual(errors, []);
  console.log("PASS: header/query/selector/action heights, fonts and colors match Notes/Tasks; mixed requests, exact inspectors, attachment Tab traps, both themes/widths, search states, persistent offline warning, blocked reads until reconnect and safe previews");
} finally { await browser.close(); }
