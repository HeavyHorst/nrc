// node client/reminder-notify.e2e.mjs (optional NRC_CLIENT_URL override)
//
// The reminder timer turns derived reminder states into desktop notifications.
// This fixture drives it in a real browser: the snapshot comes from injected
// reminder assets, `sendNotification` is stubbed to collect the deliveries, and
// deadlines are moved the way passing time moves them. Deadlines are derived
// from Date.now() so the fixture does not depend on the wall clock.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch();
try {
  const context = await browser.newContext({ serviceWorkers: "block", deviceScaleFactor: 2, locale: "en-US", timezoneId: "Europe/Berlin" });
  // Headless Chromium reports notifications as blocked and cannot be talked out
  // of it, so the fixture presents the granted state a working browser has. The
  // blocked case is checked below by denying the permission again.
  await context.addInitScript(() => Object.defineProperty(Notification, "permission", { configurable: true, get: () => "granted" }));
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.routeWebSocket("**/*", (socket) => socket.onMessage(() => {}));
  if (!process.env.NRC_CLIENT_URL) {
    // A loopback origin keeps Notification available without a running server.
    await page.route("http://localhost/**", async route => {
      const path = new URL(route.request().url()).pathname;
      try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
      catch { await route.fulfill({ status: 404, body: "Not found" }); }
    });
  }
  await page.goto(process.env.NRC_CLIENT_URL || "http://localhost/");
  await page.waitForFunction(() => window.NRCReminderNotify && window.NRCTasks && window.NRCAssets);

  await page.evaluate(() => {
    serverReady = true;
    ws = { readyState: WebSocket.OPEN, send() {} };
    myNickname = "reviewer";
    currentWorkspaceId = "workspace-review";

    const DAY = 24 * 60 * 60 * 1000;
    const stamp = BigInt(Date.parse("2026-09-22T12:00:00Z")) * 1000000n;
    const assets = new Map();
    for (const [id, title] of [[1n, "Rotate S3 key (prod)"], [2n, "Access review"]]) {
      assets.set(id, {
        assetId: id, convId: 0n, assetType: AssetType.Reminder, owner: "reviewer",
        createdAt: stamp, updatedAt: stamp, attachments: [],
        preview: JSON.stringify({ version: 1, title }),
        payload: JSON.stringify({ title, window_start_at: "0", deadline_at: "0", urgency_days: 3 }),
      });
    }
    NRCAssets.roomAssets.set(0n, assets);

    // A deadline relative to now, so "late" and "due soon" never depend on the
    // hour the fixture runs at.
    window.setDeadline = (id, offsetMs) => {
      const asset = NRCAssets.roomAssets.get(0n).get(BigInt(id));
      const parsed = JSON.parse(asset.payload);
      parsed.deadline_at = String((BigInt(Date.now()) + BigInt(offsetMs)) * 1000000n);
      asset.payload = JSON.stringify(parsed);
    };
    window.setDeadline(1, -2 * DAY);
    window.setDeadline(2, DAY);

    window.notificationDeliveries = [];
    sendNotification = (title, options, onClick) => window.notificationDeliveries.push({ title, options, onClick });

    window.inspectorOpens = [];
    const openEntity = NRCInspector.openEntity.bind(NRCInspector);
    NRCInspector.openEntity = (ref) => { window.inspectorOpens.push(ref); return openEntity(ref); };
  });

  // The reminders header carries the permission token, which stays quiet while
  // notifications work and speaks up for the one case the switch cannot express.
  await page.evaluate(() => NRCViewManager.setActiveView("reminders"));
  const status = page.locator(".reminder-queue-header #notificationStatus");
  assert.equal(await status.isVisible(), false, "the permission token stays quiet while notifications work");
  const permissionToken = await page.evaluate(() => {
    const original = Object.getOwnPropertyDescriptor(Notification, "permission");
    const read = () => {
      NRCReminderNotify.syncControl();
      const el = document.getElementById("notificationStatus");
      return { text: el.textContent, hidden: el.hidden };
    };
    Object.defineProperty(Notification, "permission", { configurable: true, get: () => "denied" });
    const blocked = read();
    if (original) Object.defineProperty(Notification, "permission", original);
    else delete Notification.permission;
    return { blocked, restored: read() };
  });
  assert.deepEqual(permissionToken.blocked, { text: "BLOCKED", hidden: false });
  assert.deepEqual(permissionToken.restored, { text: "ON", hidden: true });

  // A popup while the register is in front would only repeat what is on screen.
  await page.evaluate(() => NRCReminderNotify.sessionStarted());
  assert.equal(await page.evaluate(() => window.notificationDeliveries.length), 0, "the visible reminders view suppresses the popup");

  // The first look at a session summarises; it does not fire one popup per reminder.
  await page.evaluate(() => NRCViewManager.setActiveView("chat"));
  await page.evaluate(() => NRCReminderNotify.sessionStarted());
  const summary = await page.evaluate(() => window.notificationDeliveries.map(({ title, options }) => ({ title, options })));
  assert.equal(summary.length, 1);
  assert.equal(summary[0].title, "2 REMINDERS NEED ATTENTION");
  assert.equal(summary[0].options.body, "1 LATE · 1 DUE SOON · Rotate S3 key (prod) · Access review");
  assert.equal(summary[0].options.tag, "nrc-reminder-summary");

  // A deadline passing is a transition: one popup, with the reminder as its subject.
  await page.evaluate(() => {
    window.notificationDeliveries.length = 0;
    window.setDeadline(2, -60 * 60 * 1000);
    NRCReminderNotify.evaluate();
  });
  const transitions = await page.evaluate(() => window.notificationDeliveries.map(({ title, options }) => ({ title, options })));
  assert.equal(transitions.length, 1, "only the reminder that changed reports");
  assert.equal(transitions[0].title, "Access review");
  assert.match(transitions[0].options.body, /^LATE · \d{4}-\d{2}-\d{2} \d{2}:\d{2}$/);
  assert.equal(transitions[0].options.tag, "nrc-reminder-2");

  // Re-evaluating the same state stays silent.
  await page.evaluate(() => { window.notificationDeliveries.length = 0; NRCReminderNotify.evaluate(); });
  assert.equal(await page.evaluate(() => window.notificationDeliveries.length), 0);

  // Clicking the popup opens the reminder itself.
  await page.evaluate(() => {
    window.notificationDeliveries.length = 0;
    window.setDeadline(2, 60 * 60 * 1000);
    NRCReminderNotify.evaluate();
  });
  assert.equal(await page.evaluate(() => window.notificationDeliveries.length), 1);
  await page.evaluate(() => window.notificationDeliveries[0].onClick());
  assert.deepEqual(await page.evaluate(() => window.inspectorOpens.map((ref) => [ref.type, String(ref.id)])), [["reminder", "2"]]);

  // The workspace switch lives in the ATTENTION header, and the palette command
  // carries the same preference. The muting is checked from another view so the
  // visible register cannot be what keeps the popup away.
  const command = await page.evaluate(() => {
    const entry = COMMANDS.find((item) => item.id === "settings.reminder-notifications");
    return entry ? { title: entry.title, group: entry.group, arg: entry.arg } : null;
  });
  assert.deepEqual(command, { title: "Reminder notifications", group: "Settings", arg: "state" });
  await page.evaluate(() => NRCViewManager.setActiveView("attention"));
  await page.locator(".custom-select:has(#reminderNotifications) .custom-select__trigger").click();
  await page.locator("#portal-container").getByRole("option", { name: "OFF", exact: true }).click();
  assert.equal(await page.evaluate(() => NRCReminderNotify.mode()), "off");
  assert.equal(await page.locator("#reminderNotifications").inputValue(), "off");
  assert.equal(await page.evaluate(() => localStorage.getItem("nrc-reminder-notifications:workspace-review")), "off");
  await page.evaluate(() => {
    window.notificationDeliveries.length = 0;
    window.setDeadline(2, -60 * 60 * 1000);
    NRCReminderNotify.evaluate();
  });
  assert.equal(await page.evaluate(() => window.notificationDeliveries.length), 0, "OFF keeps the timer silent");
  await page.evaluate(() => NRCViewManager.setActiveView("attention"));
  await page.locator(".custom-select:has(#reminderNotifications) .custom-select__trigger").click();
  await page.locator("#portal-container").getByRole("option", { name: "ALL", exact: true }).click();
  assert.equal(await page.evaluate(() => NRCReminderNotify.mode()), "all");

  assert.deepEqual(errors, [], "no page errors");
  console.log("reminder-notify e2e passed");
} finally {
  await browser.close();
}
