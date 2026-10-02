import assert from "node:assert/strict";
import { chromium } from "playwright";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test/");
  await page.waitForFunction(() => window.NRCDialog && window.NRCFiles);
  await page.evaluate(() => {
    const launch = document.createElement("button");
    launch.id = "dialogTestLaunch"; launch.textContent = "OPEN DIALOG";
    document.body.prepend(launch);
    launch.focus();
    window.results = [];
    window.workspaceKeys = 0;
    document.addEventListener("keydown", () => workspaceKeys++);
  });
  const dialog = page.getByRole("dialog");
  await page.evaluate(() => { NRCDialog.confirm("Archive this record?").then(value => results.push(value)); });
  assert.equal(await dialog.getAttribute("aria-labelledby").then(id => page.locator(`#${id}`).textContent()), "CONFIRM ACTION");
  assert.equal(await dialog.locator("button").first().evaluate(el => document.activeElement === el), true);
  await page.evaluate(() => document.getElementById("dialogTestLaunch").focus());
  assert.equal(await dialog.evaluate(el => el.contains(document.activeElement)), true, "background is inert");
  await page.keyboard.press("Shift+Tab");
  assert.equal(await dialog.locator("button").last().evaluate(el => document.activeElement === el), true, "Tab wraps backward");
  await page.keyboard.press("Tab");
  assert.equal(await dialog.locator("button").first().evaluate(el => document.activeElement === el), true, "Tab wraps forward");
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => results.length === 1);
  assert.deepEqual(await page.evaluate(() => results), [false]);
  assert.equal(await page.locator("#dialogTestLaunch").evaluate(el => document.activeElement === el), true);
  assert.equal(await page.evaluate(() => workspaceKeys), 0);

  await page.evaluate(() => { NRCDialog.prompt("Name", { initialValue: "previous" }).then(value => results.push(value)); });
  assert.equal(await dialog.locator("input").evaluate(el => el.selectionEnd - el.selectionStart), 8);
  await dialog.locator("input").fill("  revised  ");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => results.length === 2);
  assert.deepEqual(await page.evaluate(() => results), [false, "revised"]);
  await page.evaluate(() => {
    NRCDialog.prompt("Old").then(value => results.push(value));
    NRCDialog.confirm("Replacement").then(value => results.push(value));
  });
  assert.equal(await dialog.count(), 1);
  await dialog.getByRole("button", { name: "Confirm", exact: true }).click();
  await page.waitForFunction(() => results.length === 4);
  assert.deepEqual(await page.evaluate(() => results.slice(2)), [false, true]);

  // Exercise mixed controls and hidden/disabled endpoints, not only buttons.
  await page.evaluate(() => {
    window.mixed = NRCModal.create({ title: "Mixed controls" });
    const fields = document.createElement("div");
    fields.innerHTML = '<input hidden><fieldset disabled><input></fieldset><input style="visibility:hidden"><textarea id="mixedText"></textarea><select id="mixedSelect"><option>One</option></select><a id="mixedLink" href="#">Link</a><button hidden>Hidden</button>';
    mixed.panel.insertBefore(fields, mixed.actions);
    mixed.show();
  });
  assert.equal(await page.locator("#mixedText").evaluate(el => document.activeElement === el), true);
  await page.keyboard.press("Shift+Tab");
  assert.equal(await page.locator("#mixedLink").evaluate(el => document.activeElement === el), true);
  await page.keyboard.press("Tab");
  assert.equal(await page.locator("#mixedText").evaluate(el => document.activeElement === el), true);
  await page.keyboard.press("Tab");
  assert.equal(await page.locator("#mixedSelect").evaluate(el => document.activeElement === el), true);
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.querySelector("dialog[open]"));

  // Actual file form, nested confirmation, and asynchronous write protection.
  await page.evaluate(() => {
    window.asset = { assetId: 81n, convId: 0n, assetType: 3, owner: "tester", createdAt: 0n,
      preview: '{"type":"file","version":1,"title":"Reference"}',
      payload: '{"type":"file","version":1,"title":"Reference","category":"Specs","description":"Details","tags":[]}',
      attachments: [{ fileId: "ref", filename: "reference.pdf", mimeType: "application/pdf", size: 1024 }] };
    window.fileRoot = NRCFiles.open(asset, { readOnly: false });
  });
  assert.equal(await dialog.locator('form').isVisible(), false);
  await dialog.getByRole("button", { name: "EDIT", exact: true }).click();
  await dialog.locator('[name="title"]').fill('Discarded draft');
  await dialog.getByRole("button", { name: "CANCEL EDIT", exact: true }).click();
  assert.equal(await dialog.locator('dl').isVisible(), true);
  await dialog.getByRole("button", { name: "EDIT", exact: true }).click();
  assert.equal(await dialog.locator('[name="title"]').inputValue(), 'Reference');
  assert.equal(await dialog.locator('dl').isVisible(), false, "edit replaces facts rather than duplicating them");
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["light", "dark"]) {
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 800 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await dialog.getByRole("button", { name: "SAVE METADATA" }).scrollIntoViewIfNeeded();
      const bodyBounds = await dialog.locator(".file-assets-dialog-body").boundingBox();
      const saveBounds = await dialog.getByRole("button", { name: "SAVE METADATA" }).boundingBox();
      const closeBounds = await dialog.getByRole("button", { name: "Close", exact: true }).boundingBox();
      assert.ok(saveBounds.y >= bodyBounds.y + bodyBounds.height, "save stays in the footer outside the scrolling form");
      assert.ok(closeBounds.y + closeBounds.height <= bodyBounds.y, "close stays above the scrolling body");
      await dialog.locator(".file-assets-dialog").screenshot({ path: `.amp/in/artifacts/dialog-file-${theme}-${width}.png` });
    }
  }
  await page.setViewportSize({ width: 1280, height: 800 });
  await dialog.locator("textarea").focus();
  await page.evaluate(() => NRCDialog.notify("File status"));
  await page.evaluate(() => { NRCDialog.confirm("Nested confirmation").then(value => results.push(value)); });
  assert.equal(await page.locator("dialog[open]").count(), 2);
  assert.equal(await page.evaluate(() => document.querySelector(".toast").parentElement === NRCModal.activeRoot()), true, "existing toast follows the top modal");
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => results.length === 5);
  assert.equal(await page.locator("dialog[open]").count(), 1);
  assert.equal(await page.evaluate(() => document.querySelector(".toast").parentElement === fileRoot), true, "toast returns to the underlying modal");
  assert.equal(await dialog.locator("textarea").evaluate(el => document.activeElement === el), true, "nested close returns focus to the file form");
  await page.evaluate(() => {
    ws = { readyState: WebSocket.OPEN };
    NRCTransactions.sendAssetMetadataPatch = (_asset, _preview, _payload, options) => { window.writeOptions = options; return 123; };
  });
  await dialog.getByRole("button", { name: "SAVE METADATA" }).click();
  await page.waitForFunction(() => !!window.writeOptions);
  await page.keyboard.press("Escape");
  await dialog.getByRole("button", { name: "Close", exact: true }).click();
  assert.equal(await page.locator("dialog[open]").count(), 1, "both cancel paths refuse closing during a write");
  await page.evaluate(() => NRCDialog.notify("Write status"));
  assert.equal(await page.evaluate(() => document.querySelector(".toast").parentElement === fileRoot), true, "new notifications are above the modal");
  await page.evaluate(() => writeOptions.onError({ message: "Write failed" }));
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.querySelector("dialog[open]"));
  assert.equal(await page.evaluate(() => document.querySelector(".toast").parentElement === document.body), true, "notification survives closing its dialog");
  await page.locator(".toast").click();

  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["light", "dark"]) {
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 800 });
      await page.evaluate(theme => {
        document.documentElement.dataset.theme = theme;
        NRCDialog.prompt("Name for the new record", { title: "CREATE RECORD", initialValue: "Example" });
      }, theme);
      const bounds = await dialog.locator(".nrc-dialog").boundingBox();
      assert.ok(bounds.x >= 0 && bounds.x + bounds.width <= width, "dialog fits viewport");
      await dialog.locator(".nrc-dialog").screenshot({ path: `.amp/in/artifacts/dialog-${theme}-${width}.png` });
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => !document.querySelector("dialog[open]"));
    }
  }
  assert.deepEqual(errors, []);
  console.log("PASS: native modal isolation, focus/Tab/restore, confirm/prompt results, replacement, nested file dialog, busy write guard; both themes and widths");
} finally { await browser.close(); }
