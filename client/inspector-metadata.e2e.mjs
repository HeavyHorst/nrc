// NRC_CLIENT_URL=http://localhost:8001 node client/inspector-metadata.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ serviceWorkers: "block", deviceScaleFactor: 2, locale: "en-US", timezoneId: "Europe/Berlin" });
  await page.route("**/api/features", route => route.fulfill({ json: { customers: true } }));
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.goto(process.env.NRC_CLIENT_URL || "http://localhost:8001");
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
    NRCAssets.roomAssets.set(0n, assets);
    NRCAssets.requestAsset = (room, id, options) => queueMicrotask(() => options.onSuccess({ asset: assets.get(id) }));
    NRCLinksUI.loadLinks = async () => {};
    NRCTasks.roomTasks.set(0n, new Map([[6n, { id: 6n, convId: 0n, title: "Task", description: "Task content", status: 1, priority: 128,
      color: 0, createdBy: "author<&>", createdAt, updatedAt, completedAt: updatedAt, attachments: [], assignee: "", project: "" }]]));
    NRCViewManager.setActiveView("notes");
  });
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 });
    for (const theme of ["lupine", "matte-black"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      for (const [type, id] of [["note", 1], ["reminder", 2], ["company", 3], ["contact", 4], ["activity", 5], ["task", 6]]) {
        await page.evaluate(async ({ type, id }) => {
          await NRCInspector.close();
          await NRCInspector.openEntity({ roomId: 0n, type, id: BigInt(id) });
        }, { type, id });
        const metadata = page.locator("#inspectorHeader .inspector-metadata");
        await metadata.waitFor();
        assert.deepEqual(await metadata.locator("dt").allTextContents(), ["CREATED BY", "CREATED", "UPDATED", ...(type === "note" ? ["SOURCE"] : type === "task" ? ["COMPLETED"] : [])]);
        assert.equal(await metadata.locator("dd").first().textContent(), "author<&>", "values are text, never HTML");
        assert.deepEqual((await metadata.locator("dd").allTextContents()).slice(1, 3), ["15.09.26, 23:37", "16.09.26, 10:14"], "short dotted dates and local minute precision even in an English browser");
        assert.equal(await metadata.locator("dl > div").nth(2).evaluate(el => getComputedStyle(el, "::before").content), '"·"', "midpoint separates date fields");
        assert.equal(await page.locator("#inspectorEntityHost .detail-object-register").count(), 0, "no duplicate body provenance");
        assert.equal(await page.locator("#inspectorHeader .inspector-mode-row small").count(), 0, "Inspector commands use clear one-line labels");
        if (type === "task") {
          assert.deepEqual(await page.locator(".task-detail-read-register .inline-field-label").allTextContents(),
            ["STATUS", "PRIORITY", "CATEGORY", "DUE", "PROJECT", "ASSIGNEE", "BLOCKED BY", "REFERENCE"],
            "Task read mode exposes operational fields");
        }
        assert.equal((await page.locator("#inspectorHeader .inspector-identity-row").boundingBox()).height, 20);
        const geometry = await metadata.evaluate(el => {
          const state = el.parentElement.lastElementChild;
          return { width: el.clientWidth, right: el.getBoundingClientRect().right, stateLeft: state.getBoundingClientRect().left,
            stateClipped: state.scrollWidth > state.clientWidth };
        });
        assert.ok(geometry.width > 0 && geometry.right <= geometry.stateLeft && !geometry.stateClipped, `${width}/${theme}/${type}: metadata and state fit`);
        assert.deepEqual(await metadata.locator(".metadata-date-label").evaluateAll(labels => labels.map(el => getComputedStyle(el).position)),
          Array(2).fill(geometry.width <= 560 ? "absolute" : "static"), "date labels compact based on available metadata width");
        assert.equal(await metadata.locator("dd").nth(1).getAttribute("title"), "CREATED: 15.09.26, 23:37", "hidden label remains available as a tooltip");
        await metadata.focus();
        for (let i = 0; i < 30; i++) await page.keyboard.press("ArrowRight");
        await page.waitForTimeout(200);
        assert.ok(await metadata.evaluate(el => el.scrollLeft + el.clientWidth >= el.scrollWidth - 1), "keyboard reaches final metadata field");
        if (type === "note" || type === "task") {
          assert.equal(await page.locator("#inspectorEntityHost [data-messages-area]").getAttribute("data-messages-open"), "true",
            "comments are visible without a tab");
          await metadata.waitFor();
          assert.equal(await metadata.locator("dd").first().textContent(), "author<&>", "provenance persists while messages are open");
          assert.equal(await page.locator("#inspectorEntityHost [data-messages-toggle]").getAttribute("aria-expanded"), "true",
            "comments start expanded and can be collapsed");
        }
        for (const selector of type === "note" ? ['#noteDetailEdit'] : type === "task" ? ['#taskDetailToggleFocus'] : ["company", "contact", "activity"].includes(type) ? ['#customerEdit'] : []) {
          await page.locator(`#inspectorHeader ${selector}`).click();
          await metadata.waitFor();
          assert.equal(await metadata.locator("dd").first().textContent(), "author<&>", "provenance persists across modes");
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
      }
    }
  }
  await page.setViewportSize({ width: 1800, height: 900 });
  const metadata = page.locator("#inspectorHeader .inspector-metadata");
  for (const width of [561, 560, 561]) {
    await metadata.evaluate((el, width) => el.style.flex = `0 0 ${width}px`, width);
    assert.deepEqual(await metadata.locator(".metadata-date-label").evaluateAll(labels => labels.map(el => getComputedStyle(el).position)),
      Array(2).fill(width <= 560 ? "absolute" : "static"), "labels hide and restore at the container boundary without a viewport change");
    assert.match(await metadata.ariaSnapshot(), /term: CREATED/);
    assert.match(await metadata.ariaSnapshot(), /term: UPDATED/);
  }
  console.log("PASS: six entity inspectors, both themes, desktop/mobile widths, read/edit/messages, 560/561px label boundary, accessible date labels and keyboard metadata scrolling");
} finally {
  await browser.close();
}
