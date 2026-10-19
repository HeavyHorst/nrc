// Production shell with deterministic HTTP health and presence fixtures; no server writes.
// node client/subsystems.e2e.mjs
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium, devices } from "playwright";

const browser = await chromium.launch();
const errors = [];
let search = { status: 200, body: '{"status":"ok"}' };
let ai = { status: 503, body: "Unavailable" };
let publish = { status: 200, body: '{"status":"ok"}' };
let metrics = { status: 200, body: '{"status":"degraded"}' };
let newsletter = { status: 200, body: '{"status":"ok"}' };
let tickets = { status: 200, body: '{"status":"ok"}' };
const healthRequests = [];
try {
  for (const mobile of [false, true]) {
    const context = await browser.newContext({
      ...(mobile ? devices["iPhone 13"] : { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 }),
      serviceWorkers: "block",
    });
    const page = await context.newPage();
    page.on("pageerror", error => errors.push(error.message));
    await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
    await page.route("http://nrc.test/**", async route => {
      const url = new URL(route.request().url());
      if (url.pathname.startsWith("/api/subsystems/")) {
        healthRequests.push(url.pathname);
        const response = { search, ai, publish, metrics, newsletter, tickets }[url.pathname.split("/").at(-1)];
        await route.fulfill({ ...response, contentType: "application/json" });
        return;
      }
      if (url.pathname === "/search/health") {
        await route.fulfill({ status: 200, contentType: "application/json", body: '{"status":"ok"}' });
        return; // Existing Notes availability probe is independent of the register.
      }
      try { await route.fulfill({ path: fileURLToPath(new URL(`.${url.pathname === "/" ? "/index.html" : url.pathname}`, import.meta.url)) }); }
      catch { await route.fulfill({ status: 404, body: "Not found" }); }
    });
    const before = healthRequests.length;
    await page.goto("http://nrc.test/#workspace=subsystems-test");
    await page.waitForFunction(() => window.NRCChat && ws?.readyState === WebSocket.OPEN);
    assert.equal(healthRequests.length, before, "opening the app does not probe services");
    if (mobile) assert.equal(await page.evaluate(() => matchMedia("(pointer: coarse)").matches), true);
    await page.evaluate(() => {
      currentRoomId = 2n;
      roomPresence.set(2n, new Map([
        ["Alex", { userType: UserType.User }], ["Rene-admin", { userType: UserType.Admin }],
        ["search-worker", { userType: UserType.Bot }], ["system", { userType: UserType.System }],
      ]));
      updatePresenceDisplay();
      logMessage("Message", "Search and Sullivan now have their own status register.", 2n, { author: "Alex" });
    });
    assert.deepEqual(await page.locator("#usersList .username").allTextContents(), ["Alex", "Rene-admin"]);
    assert.equal(await page.locator(".users-section-count").textContent(), "2");
    const trigger = page.locator("#subsystemsToggle");
    const panel = page.locator("#subsystemsPanel");
    const capture = async name => {
      if (!process.env.NRC_SUBSYSTEM_SCREENSHOTS) return;
      await fs.mkdir(process.env.NRC_SUBSYSTEM_SCREENSHOTS, { recursive: true });
      await page.screenshot({ path: `${process.env.NRC_SUBSYSTEM_SCREENSHOTS}/${name}.png` });
    };
    await capture(mobile ? "subsystems-mobile-closed" : "subsystems-desktop-closed");
    for (const theme of ["light", "dark"]) {
      search = { status: 200, body: '{"status":"ok"}' };
      ai = { status: 200, body: '{"status":"unavailable"}' };
      publish = { status: 200, body: '{"status":"ok"}' };
      metrics = { status: 200, body: '{"status":"degraded"}' };
      newsletter = { status: 200, body: '{"status":"ok"}' };
      tickets = { status: 200, body: '{"status":"ok"}' };
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await trigger.click();
      await page.waitForFunction(() => document.getElementById("subsystemsChecked").textContent.startsWith("LAST CHECK"));
      assert.equal(await trigger.getAttribute("aria-expanded"), "true");
      assert.equal(await page.locator("#subsystemsClose").evaluate(el => el === document.activeElement), true);
      assert.match(await panel.textContent(), /✓ REACHABLE/);
      assert.match(await page.locator('[data-subsystem="ai"]').textContent(), /! UNAVAILABLE.*Health endpoint unavailable/);
      assert.match(await page.locator('[data-subsystem="publish"]').textContent(), /✓ REACHABLE/);
      assert.match(await page.locator('[data-subsystem="metrics"]').textContent(), /! DEGRADED/);
      assert.equal(await page.locator("#subsystemsSummary").textContent(), "! 2 ISSUES");
      assert.deepEqual(await panel.locator("tbody th").allTextContents(), ["SEARCH", "SULLIVAN / AI", "PUBLISH", "METRICS", "NEWSLETTER", "TICKET PORTAL"]);
      for (const id of ["newsletter", "tickets"]) assert.match(await page.locator(`[data-subsystem="${id}"]`).textContent(), /✓ REACHABLE/);
      assert.equal(await panel.locator('[data-state="unknown"]').count(), 0);
      const fits = await panel.evaluate(el => {
        const r = el.getBoundingClientRect();
        return r.left >= 0 && r.right <= innerWidth && r.top >= 0 && r.bottom <= innerHeight && el.scrollWidth <= el.clientWidth;
      });
      assert.ok(fits, `${mobile ? "mobile" : "desktop"} ${theme}: register fits viewport`);
      const closeFits = await page.locator("#subsystemsClose").evaluate(el => el.getBoundingClientRect().bottom <= el.closest("header").getBoundingClientRect().bottom);
      assert.ok(closeFits, "close touch target stays within header");
      await capture(`subsystems-${mobile ? "mobile" : "desktop"}-${theme}`);
      ai = { status: 404, body: "Not found" };
      search = { status: 200, body: "<html>not a health response</html>" };
      publish = { status: 200, body: '{"status":"not_configured"}' };
      metrics = { status: 200, body: '{"status":"unknown"}' };
      newsletter = { status: 200, body: '{"status":"not_configured"}' };
      tickets = { status: 200, body: '{"status":"not_configured"}' };
      await page.locator("#subsystemsRefresh").click();
      await page.waitForFunction(() => document.getElementById("subsystemsRefresh").getAttribute("aria-busy") === "false");
      assert.equal(await panel.locator('[data-state="unknown"]').count(), 6, "missing route and non-JSON response are unknown, not service failures");
      assert.equal(await page.locator("#subsystemsSummary").textContent(), "DETAILS");
      if (!mobile && theme === "light") await capture("subsystems-not-configured");
      await page.keyboard.press("Escape");
      assert.ok(await panel.isHidden());
      assert.equal(await trigger.evaluate(el => el === document.activeElement), true);
    }
    await trigger.click();
    await page.locator("#subsystemsClose").click();
    assert.ok(await panel.isHidden());
    await trigger.click();
    await page.locator(mobile ? ".mobile-connection" : ".users-bar").click();
    assert.ok(await panel.isHidden(), "outside click closes register");
    await trigger.click();
    await page.keyboard.press("Tab");
    await page.keyboard.press("Tab");
    await page.waitForFunction(() => document.getElementById("subsystemsPanel").hidden);
    await trigger.click();
    await trigger.focus();
    await page.keyboard.press("Shift+Tab");
    await panel.waitFor({ state: "hidden" });
    assert.ok(await panel.isHidden(), "leaving the toggle backwards closes the register");
    await trigger.click();
    await trigger.focus();
    await page.keyboard.press("Tab");
    assert.equal(await page.locator("#subsystemsClose").evaluate(el => el === document.activeElement), true, "Tab from toggle enters the register");
    assert.ok(await panel.isVisible(), "moving focus into the register keeps it open");
    await page.keyboard.press("Tab");
    await page.keyboard.press("Tab");
    await panel.waitFor({ state: "hidden" });
    assert.ok(await panel.isHidden(), "leaving the register forwards closes it");
    assert.ok(healthRequests.every(path => ["search", "ai", "publish", "metrics", "newsletter", "tickets"].some(id => path === `/api/subsystems/${id}`)), "no readiness actions or private endpoints are probed");
    await page.evaluate(() => { updateUsersList([]); NRCInspector.refreshContext(); });
    assert.equal(await page.locator(".users-section-count").textContent(), "0");
    await context.close();
  }
  assert.deepEqual(errors, []);
  console.log("PASS: people-only presence; six subsystems; reachability/failure/unknown; refresh, Escape, close, outside click, focus exit; desktop/touch layouts in both themes");
} finally {
  await browser.close();
}
