// Real-server appointment acceptance test. Use only the disposable workspace fixture.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_CLIENT_URL || "http://127.0.0.1:8096";
assert.ok(["127.0.0.1", "localhost"].includes(new URL(url).hostname));
const workspace = `appointment-review-${Date.now()}`;
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ serviceWorkers: "block", timezoneId: "Europe/Berlin", viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2 });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`${url}/#workspace=${workspace}`);
  await page.waitForFunction(() => typeof serverReady !== "undefined" && serverReady);
  await page.evaluate(() => { NRCCalendar.getState().month = "2026-09"; NRCViewManager.setActiveView("calendar"); });
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
  await page.locator("#calendarAddAppointment").click();
  assert.equal(await page.locator("#appointmentClose").count(), 1);
  assert.equal(await page.locator("#appointmentCancelHeader").count(), 0);
  const headerEdge = await page.locator("#inspectorHeader").boundingBox();
  const closeEdge = await page.locator("#appointmentClose").boundingBox();
  assert.ok(Math.abs(headerEdge.x + headerEdge.width - closeEdge.x - closeEdge.width) < 16, "Close stays at the right edge");
  await page.locator("#appointmentCancel").click();
  assert.equal(await page.evaluate(() => NRCInspector.current()), null);
  await page.locator("#calendarAddAppointment").click();
  await page.locator("#appointmentTitle").fill("Unsaved meeting");
  await page.locator("#appointmentCancel").click();
  await page.locator(".nrc-dialog-actions").getByRole("button", { name: "Cancel", exact: true }).click();
  assert.equal(await page.locator("#appointmentTitle").inputValue(), "Unsaved meeting");
  await page.locator("#appointmentCancel").click();
  await page.locator(".nrc-dialog-actions").getByRole("button", { name: "Discard", exact: true }).click();
  assert.equal(await page.evaluate(() => NRCInspector.current()), null);
  await page.locator("#calendarAddAppointment").click();
  await page.locator("#appointmentSave").click();
  assert.match(await page.locator("#appointmentValidationError").textContent(), /TITLE/);
  await page.locator("#appointmentTitle").fill("Video call with Alex");
  await page.locator("#appointmentStart").fill("2026-09-28T14:00");
  await page.locator("#appointmentEnd").fill("2026-09-28T13:00");
  await page.locator("#appointmentSave").click();
  assert.match(await page.locator("#appointmentValidationError").textContent(), /AFTER START/);
  await page.locator("#appointmentEnd").fill("2026-09-28T14:45");
  await page.locator("#appointmentDescription").fill("Review the release plan and agree the next milestone.");
  await page.locator("#appointmentUrl").fill("https://meet.example.test/release-review");
  await page.getByRole("button", { name: "Edit PROJECT: empty", exact: true }).click();
  await page.locator(".inline-field-editor input").fill("NRC");
  await page.locator(".inline-field-editor input").press("Enter");
  await page.waitForFunction(() => !document.querySelector(".inline-field-editor"));
  await page.evaluate(() => { NRCAppointments.save(); NRCAppointments.save(); }); // rapid duplicate submit
  await page.waitForFunction(() => NRCInspector.current()?.id > 0n && NRCCalendar.getState().rows.length === 1).catch(async error => {
    console.error(await page.evaluate(() => ({ error: document.querySelector("#appointmentValidationError")?.textContent,
      start: document.querySelector("#appointmentStart")?.value, current: String(NRCInspector.current()?.id), status: NRCCalendar.getState().status })), errors);
    throw error;
  });
  const id = await page.evaluate(() => String(NRCInspector.current().id));
  assert.equal(await page.locator("#appointmentCancelHeader, #appointmentCancel").count(), 0);
  assert.equal(await page.locator("#appointmentClose").count(), 1);
  assert.equal(await page.locator(`[data-calendar-row="appointment:${id}"] time`).textContent(), "14:00–14:45");
  assert.equal(await page.locator(`[data-calendar-row="appointment:${id}"] .calendar-project`).textContent(), "NRC");
  await page.locator("#appointmentTitle").fill("Video call with Alex · confirmed");
  await page.locator("#appointmentSave").click();
  await page.waitForFunction(() => NRCCalendar.getState().rows[0]?.title.endsWith("confirmed"));
  assert.equal(await page.evaluate(() => NRCCalendar.getState().rows.length), 1, "editing must not create a duplicate");
  await page.reload();
  await page.waitForFunction(() => typeof serverReady !== "undefined" && serverReady);
  await page.evaluate(() => { NRCCalendar.getState().month = "2026-09"; NRCViewManager.setActiveView("calendar"); });
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready" && NRCCalendar.getState().rows.length === 1);
  await page.locator(`[data-calendar-row="appointment:${id}"]`).click();
  await page.waitForSelector("#appointmentTitle");
  assert.equal(await page.locator("#appointmentTitle").inputValue(), "Video call with Alex · confirmed");
  assert.equal(await page.locator("#appointmentUrl").inputValue(), "https://meet.example.test/release-review");
  assert.equal(await page.getByRole("link", { name: "OPEN MEETING ↗" }).getAttribute("href"), "https://meet.example.test/release-review");
  await page.evaluate(() => NRCInspector.close());

  const spanning = await page.evaluate(async () => {
    const ns = text => String(BigInt(Date.parse(text)) * 1000000n);
    const create = record => new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 12, 0, 0n,
      JSON.stringify({ version: 1, ...record }), "", 0, { onSuccess: result => resolve(String(result.asset.assetId)), onError: reject }));
    const spanning = await create({ title: "Maintenance window", start_at: ns("2026-08-31T22:00:00+02:00"), end_at: ns("2026-09-02T00:00:00+02:00"), assignee: "alex", project: "OPS" });
    await create({ title: "Month-end handover", start_at: ns("2026-09-30T23:00:00+02:00"), end_at: ns("2026-10-01T02:00:00+02:00"), assignee: "customer-preview", project: "NRC" });
    await create({ title: "Check-in with supplier", start_at: ns("2026-09-29T09:30:00+02:00"), assignee: "alex", project: "OPS" });
    return spanning;
  });
  await page.waitForFunction(() => NRCCalendar.getState().rows.length === 4);
  await page.locator('[data-calendar-mode="month"]').click();
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
  await page.locator('[data-calendar-day="2026-09-01"]').click();
  assert.equal(await page.locator(`[data-calendar-row="appointment:${spanning}"]`).count(), 1);
  await page.locator('[data-calendar-day="2026-09-02"]').click();
  assert.equal(await page.locator(`[data-calendar-row="appointment:${spanning}"]`).count(), 0, "exclusive midnight end");
  await page.locator('[data-calendar-mode="agenda"]').click();
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
  await page.locator("#calendarPerson-trigger").click();
  await page.locator("#portal-container").getByRole("option", { name: "MINE", exact: true }).click();
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready" && NRCCalendar.getState().rows.length === 2);
  await page.locator("#calendarPerson-trigger").click();
  await page.locator("#portal-container").getByRole("option", { name: "ALL", exact: true }).click();
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready" && NRCCalendar.getState().rows.length === 4);
  // Delete the multi-day fixture using the real confirmation control.
  await page.locator(`[data-calendar-row="appointment:${spanning}"]`).click();
  await page.locator("#appointmentDelete").click();
  await page.getByRole("button", { name: "Delete Appointment", exact: true }).click();
  await page.waitForFunction(() => NRCCalendar.getState().rows.length === 3);
  await page.locator(`[data-calendar-row="appointment:${id}"]`).click();
  await page.waitForSelector("#appointmentTitle");
  const assertMetadataFits = async () => {
    const footer = await page.locator(".agenda-content > .task-detail-actions").evaluate(element => {
      const rect = element.getBoundingClientRect(), style = getComputedStyle(element);
      const buttons = [...element.children].map(button => button.getBoundingClientRect());
      const root = getComputedStyle(document.documentElement);
      const chatHeight = parseFloat(root.getPropertyValue("--record-footer-height")) * parseFloat(root.fontSize);
      return { height: rect.height, expected: Math.max(chatHeight, Math.max(...buttons.map(button => button.height)) + parseFloat(style.paddingTop) + parseFloat(style.paddingBottom) + parseFloat(style.borderTopWidth)),
        anchored: Math.abs(rect.bottom - element.parentElement.getBoundingClientRect().bottom) < 2,
        contained: buttons.every(button => button.top >= rect.top && button.bottom <= rect.bottom) };
    });
    assert.ok(Math.abs(footer.height - footer.expected) < 1, "footer must match chat rail height or grow only to fit touch controls");
    assert.ok(footer.anchored && footer.contained, "footer stays bottom-anchored without clipping buttons");
    const fields = await page.locator(".appointment-detail-panel .inline-field-value").evaluateAll(buttons => buttons.map(button => ({
      width: button.clientWidth, content: button.scrollWidth, height: button.clientHeight, contentHeight: button.scrollHeight,
    })));
    assert.equal(fields.length, 2);
    for (const field of fields) {
      assert.ok(field.width > 0 && field.content <= field.width + 1, "metadata must not be truncated horizontally");
      assert.ok(field.contentHeight <= field.height + 1, "wrapped metadata must remain fully visible");
    }
  };
  await assertMetadataFits();
  // Long unbroken values exercise wrapping rather than merely a short fixture.
  await page.locator('[data-control="appointment-assignee"] button').evaluate(button => { button.textContent = "a".repeat(32); });
  await page.locator('[data-control="appointment-project"] button').evaluate(button => { button.textContent = "p".repeat(128); });
  await assertMetadataFits();
  await page.evaluate(() => NRCInspector.openEntity(NRCInspector.current()));
  const dir = new URL("../.amp/in/artifacts/", import.meta.url);
  await fs.mkdir(dir, { recursive: true });
  await page.screenshot({ path: new URL("appointments-desktop.png", dir).pathname });
  await page.evaluate(() => document.documentElement.dataset.theme = "matte-black");
  await page.screenshot({ path: new URL("appointments-dark.png", dir).pathname });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => NRCInspector.openEntity(NRCInspector.current()));
  await assertMetadataFits();
  await page.screenshot({ path: new URL("appointments-narrow.png", dir).pathname });
  assert.deepEqual(errors, []);
  await fs.writeFile("/tmp/nrc-appointment-fixture.json", JSON.stringify({ workspace, url, id }));
  console.log("PASS: appointment create/edit/reload/delete, validation, filters and cross-month exclusive-end overlap", workspace);
} finally { await browser.close(); }
