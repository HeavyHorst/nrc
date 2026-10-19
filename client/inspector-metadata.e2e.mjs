// NRC_CLIENT_URL=http://localhost:8001 node client/inspector-metadata.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ serviceWorkers: "block", deviceScaleFactor: 2, locale: "en-US", timezoneId: "Europe/Berlin" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.route("**/api/features", route => route.fulfill({ json: { customers: true } }));
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  if (!process.env.NRC_CLIENT_URL) await page.route("http://nrc.test/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    if (pathname === "/api/features") return route.fulfill({ json: { customers: true } });
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${pathname === "/" ? "/index.html" : pathname}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto(process.env.NRC_CLIENT_URL || "http://nrc.test");
  await page.waitForFunction(() => window.NRCCustomers?.isEnabled());
  await page.evaluate(() => {
    serverReady = true;
    ws = { readyState: WebSocket.OPEN, send() {} };
    const createdAt = BigInt(Date.parse("2026-09-15T21:37:42Z")) * 1000000n;
    const updatedAt = BigInt(Date.parse("2026-09-16T08:14:59Z")) * 1000000n;
    const assets = new Map();
    for (const [id, assetType, title] of [[1n, 5, "Note"], [2n, 6, "Reminder"], [3n, 8, "Company"], [4n, 9, "Contact"], [5n, 10, "Activity"]]) {
      assets.set(id, { assetId: id, convId: 0n, assetType, owner: "author<&>", createdAt, updatedAt, attachments: [],
        preview: JSON.stringify({ version: 1, title, format: "markdown", kind: "Call" }),
        payload: assetType === 6 ? JSON.stringify({ title, deadline_at: String(updatedAt), window_start_at: "0" }) : "Record content",
        source: id === 1n ? "source<&>" : undefined });
    }
    for (const [id, parentType, parentId] of [[7n, 1, 6n], [8n, 2, 1n]]) {
      assets.set(id, { assetId: id, convId: 0n, assetType: 1, parentType, parentId,
        owner: "reviewer", createdAt, updatedAt, attachments: [], preview: "Review", payload: "Reviewed" });
    }
    NRCAssets.roomAssets.set(0n, assets);
    NRCAssets.requestAsset = (room, id, options) => queueMicrotask(() => options.onSuccess({ asset: assets.get(id) }));
    NRCLinksUI.loadLinks = async () => {};
    NRCTasks.roomTasks.set(0n, new Map([[6n, { id: 6n, convId: 0n, title: "Task", description: "Task content", status: 1, priority: 128,
      color: 0, createdBy: "author<&>", createdAt, updatedAt, completedAt: updatedAt, attachments: [], assignee: "", project: "" }]]));
    NRCViewManager.setActiveView("notes");
  });
  for (const width of [2200, 1440, 390]) {
    await page.setViewportSize({ width, height: 900 });
    await page.locator("#inspector").evaluate((el, width) => el.style.width = width === 2200 ? "1100px" : "", width);
    for (const theme of ["lupine", "matte-black"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      for (const [type, id] of [["note", 1], ["reminder", 2], ["company", 3], ["contact", 4], ["activity", 5], ["task", 6]]) {
        await page.evaluate(async ({ type, id }) => {
          await NRCInspector.close();
          await NRCInspector.openEntity({ roomId: 0n, type, id: BigInt(id) });
        }, { type, id });
        const metadata = page.locator("#inspectorHeader .inspector-info");
        const info = page.locator('#inspectorHeader button[popovertarget]').first();
        await page.waitForFunction(() => document.querySelector('#inspectorEntityHost')?.getAttribute('aria-busy') !== 'true');
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        assert.equal(await metadata.count(), 1, `${width}/${theme}/${type}: ${errors.join("; ")} ${await page.locator("#inspectorEntityHost").textContent()}`);
        assert.equal(await metadata.isVisible(), false, "provenance starts behind INFO");
        assert.equal(await info.textContent(), "INFO");
        if (type !== "reminder") assert.equal(await page.locator('#inspectorHeader [data-history-kind]').isVisible(), true, "HISTORY stays separate");
        await info.focus();
        await page.keyboard.press("Enter");
        await metadata.waitFor();
        assert.deepEqual(await metadata.locator("dt").allTextContents(), ["CREATED BY", "CREATED", "UPDATED", ...(type === "note" ? ["SOURCE"] : type === "task" ? ["COMPLETED"] : [])]);
        assert.equal(await metadata.locator("dd").first().textContent(), "author<&>", "values are text, never HTML");
        assert.deepEqual((await metadata.locator("dd").allTextContents()).slice(1, 3), ["15.09.26, 23:37", "16.09.26, 10:14"], "short dotted dates and local minute precision even in an English browser");
        assert.equal(await page.locator("#inspectorEntityHost .detail-object-register").count(), 0, "no duplicate body provenance");
        assert.equal(await page.locator("#inspectorHeader .inspector-mode-row small").count(), 0, "Inspector commands use clear one-line labels");
        if (type === "task") {
          assert.deepEqual((await page.locator(".task-detail-read-register .inline-field-label").allTextContents()).sort(),
            ["STATUS", "PRIORITY", "CATEGORY", "DUE", "PROJECT", "ASSIGNEE", "BLOCKED BY", "REFERENCE"].sort(),
            "Task read mode exposes operational fields");
        }
        const identityHeight = (await page.locator("#inspectorHeader .inspector-identity-row").boundingBox()).height;
        assert.ok(identityHeight >= 20 && identityHeight <= 30, `${width}/${theme}/${type}: compact one-line identity band (${identityHeight}px)`);
        const box = await metadata.boundingBox();
        assert.ok(box.x >= 16 && box.x + box.width <= width - 16 && Math.abs(box.x + box.width / 2 - width / 2) < 2, "popup fits and is centered");
        assert.ok(await metadata.evaluate(el => el.scrollWidth <= el.clientWidth), "no horizontal scrolling");
        if (width === 390) assert.equal(await metadata.locator("dd").first().evaluate(el => getComputedStyle(el).fontSize), "16px");
        assert.equal(await metadata.locator('[autofocus]').evaluate(el => el === document.activeElement), true);
        if (type === "note") assert.equal(await metadata.locator("dd").last().textContent(), "source<&>");
        if (process.env.NRC_SCREENSHOT_DIR && ["task", "note"].includes(type)) {
          await fs.mkdir(process.env.NRC_SCREENSHOT_DIR, { recursive: true });
          await page.screenshot({ path: `${process.env.NRC_SCREENSHOT_DIR}/${type}-${width}-${theme}-info.png` });
        }
        await page.keyboard.press("Escape");
        assert.equal(await metadata.isVisible(), false);
        assert.equal(await info.evaluate(el => el === document.activeElement), true, "Escape restores INFO focus");
        assert.equal(await page.locator("#inspector").isVisible(), true, "Escape leaves inspector open");
        await info.click();
        await metadata.getByRole("button", { name: "Close record info" }).click();
        assert.equal(await metadata.isVisible(), false);
        assert.equal(await info.evaluate(el => el === document.activeElement), true, "close restores focus");
        await info.click();
        await page.mouse.click(2, 450);
        assert.equal(await metadata.isVisible(), false, "outside click dismisses");
        if (type === "note" || type === "task") {
          const discussionOpen = type === "note" && width <= 768 ? "false" : "true";
          assert.equal(await page.locator("#inspectorEntityHost [data-messages-area]").getAttribute("data-messages-open"), discussionOpen,
            "narrow notes prioritize reading; other discussions stay visible");
          await info.click();
          await metadata.waitFor();
          assert.equal(await metadata.locator("dd").first().textContent(), "author<&>", "provenance persists while messages are open");
          await page.keyboard.press("Escape");
          assert.equal(await page.locator("#inspectorEntityHost [data-messages-toggle]").getAttribute("aria-expanded"), discussionOpen,
            "INFO leaves discussion state unchanged");
        }
        for (const selector of type === "note" ? ['#noteDetailEdit'] : type === "task" ? ['#taskDetailToggleFocus'] : ["company", "contact", "activity"].includes(type) ? ['#customerEdit'] : []) {
          await page.locator(`#inspectorHeader ${selector}`).click();
          await info.click();
          await metadata.waitFor();
          assert.equal(await metadata.locator("dd").first().textContent(), "author<&>", "provenance persists across modes");
          await page.keyboard.press("Escape");
          if (selector === "#noteDetailEdit") {
            assert.equal(await page.locator(".note-preview-title").count(), 1, "note title stays visible while editing");
            assert.deepEqual(await page.locator(".note-inline-metadata .inline-field-label").allTextContents(), ["PROJECT", "TAGS", "FORMAT"]);
          } else if (selector === "#taskDetailToggleFocus") {
            assert.equal(await page.locator(".task-detail-doc-title").count(), 1, "task title stays visible while editing");
            assert.equal(await page.locator(".task-detail-read-register .inline-field-label").count(), 8, "same property register in both modes");
          } else if (selector === "#customerEdit") {
            assert.ok(await page.locator(".customer-field-section .detail-edit-section-title").count() > 0, "Customer edit fields are grouped");
          }
        }
        if (type === "reminder") {
          await page.locator('#reminderDetailEdit').click();
          const openNote = page.locator('#reminderDetailOpenNote');
          assert.equal(await openNote.isDisabled(), true, 'no action without a linked note');
          await page.selectOption('#reminderDetailNoteId', '1');
          assert.equal(await openNote.isEnabled(), true, 'selected note can be opened');
          await page.selectOption('#reminderDetailNoteId', '');
          assert.equal(await openNote.isDisabled(), true, 'removing the link disables opening');
          await page.locator('#reminderDetailView').click();
          await page.getByRole('button', { name: 'Discard', exact: true }).click();
        }
      }
    }
  }
  assert.deepEqual(errors, []);
  console.log("PASS: six inspectors, both themes, three widths, read/edit/messages, INFO rows, escaping, native dismissal and focus restoration");
} finally {
  await browser.close();
}
