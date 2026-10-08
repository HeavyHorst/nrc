// Exercise the real File inspector and dialog with disposable asset responses.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 }, deviceScaleFactor: 2 });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/") return route.fulfill({ contentType: "text/html", body: `<!doctype html><meta charset="utf-8">
      <link rel="stylesheet" href="/css/main.css"><main style="max-width:56rem;margin:auto">
      <div class="panel-header ledger-context-header inspector-matrix-header" id="inspectorHeader"></div><div class="agenda-content inspector-entity-host" id="inspectorEntityHost"></div></main>
      <script src="/dialog.js"></script><script src="/attachments.js"></script>
      <script>window.NRCAssets = { MAX_PAYLOAD_LENGTH: 65535 };</script>
      <script src="/detail-ui.js"></script><script src="/files.js"></script>` });
    if (path.startsWith("/files/")) return route.fulfill({ contentType: "application/octet-stream", path: fileURLToPath(new URL("./icons/icon-512.png", import.meta.url)) });
    await route.fulfill({ path: fileURLToPath(new URL(`.${path}`, import.meta.url)) });
  });
  await page.goto("http://nrc.test/");
  await page.evaluate(() => {
    window.escapeHtml = value => String(value).replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
    window.previews = [];
    window.openImageModal = (...args) => previews.push(["image", ...args]);
    window.open = (...args) => previews.push(["tab", ...args]);
    const metadata = JSON.stringify({ type: "file", version: 1, title: "Aufgaben-Dashboard — Designreferenz", description: "Originalentwurf, PDF-Seite 8. Vollständig gerendert.\nKeine Live-Abnahme.", category: "design-reference", tags: ["hueber", "dashboard"] });
    window.asset = { assetId: 5198n, convId: 1n, assetType: 3, payload: metadata, preview: metadata, owner: "tag:amp-edupoold", updatedAt: 1791460920000000000n, attachments: [{ fileId: "image/1", filename: 'Aufgabenmanagement <S08>.PNG', mimeType: "application/octet-stream", size: 267674 }] };
    window.NRCAssets = { AssetType: { File: 3 }, requestAsset: (_room, _id, options) => options.onSuccess({ asset }) };
    NRCFiles.showInspector({ id: 5198n });
  });
  const host = page.locator("#inspectorEntityHost");
  assert.equal(await host.locator("h2").textContent(), "Aufgaben-Dashboard — Designreferenz");
  assert.equal(await host.getByRole("group").count(), 3);
  assert.equal(await host.locator("img").count(), 1);
  assert.equal(await host.locator("img").getAttribute("src"), "/files/image%2F1?inline=true&filename=Aufgabenmanagement+%3CS08%3E.PNG");
  const download = host.locator("a[download]");
  assert.equal(await download.getAttribute("href"), "/files/image%2F1?filename=Aufgabenmanagement+%3CS08%3E.PNG");
  await host.getByRole("button", { name: "OPEN", exact: true }).click();
  await host.locator(".file-assets-image").focus();
  await page.keyboard.press("Enter");
  assert.deepEqual(await page.evaluate(() => previews.map(p => p[0])), ["image", "image"]);
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["light", "dark"]) {
    for (const width of [900, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await host.locator("img").scrollIntoViewIfNeeded();
      await page.waitForFunction(() => [...document.images].every(img => img.complete && img.naturalWidth > 0));
      assert.equal(await host.locator(".note-links-list").evaluate(el => el.scrollHeight <= el.clientHeight + 1), true, "preview must not be cropped by the attachment ledger's scrolling cap");
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `${theme}/${width}: no horizontal overflow`);
      await page.evaluate(() => scrollTo(0, 0));
      await page.screenshot({ path: `.amp/in/artifacts/file-inspector-${theme}-${width}.png`, fullPage: true });
    }
  }
  // Dialog uses the same preview and supports returning from metadata editing.
  await page.setViewportSize({ width: 900, height: 1000 });
  await page.evaluate(() => { document.documentElement.dataset.theme = "light"; NRCFiles.open(asset, { readOnly: false }); });
  const dialog = page.getByRole("dialog");
  await dialog.waitFor();
  await dialog.getByRole("button", { name: "EDIT", exact: true }).click();
  assert.equal(await dialog.locator(".file-assets-metadata").isVisible(), false);
  await dialog.getByRole("button", { name: "CANCEL EDIT" }).click();
  assert.equal(await dialog.locator(".file-assets-metadata").isVisible(), true);
  await dialog.getByRole("button", { name: "OPEN", exact: true }).click();
  for (const theme of ["light", "dark"]) {
    for (const width of [900, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      assert.equal(await dialog.evaluate(el => el.scrollWidth <= el.clientWidth + 1), true);
      assert.equal(await dialog.locator(".file-assets-heading").evaluate(el => el.scrollWidth <= el.clientWidth + 1), true, "title must wrap, not clip");
      assert.equal(await dialog.locator(".file-assets-dialog-body").evaluate(el => el.scrollWidth <= el.clientWidth + 1), true, "dialog content must not overflow horizontally");
      await dialog.screenshot({ path: `.amp/in/artifacts/file-dialog-${theme}-${width}.png` });
    }
  }
  await page.evaluate(() => document.querySelector("dialog").nrcClose());
  // Explicit non-image MIME must not be reinterpreted by a .png suffix.
  await page.evaluate(() => { asset.attachments[0].mimeType = "application/pdf"; NRCFiles.showInspector({ id: 5198n }); });
  assert.equal(await host.locator("img").count(), 0);
  await host.getByRole("button", { name: "OPEN", exact: true }).click();
  assert.equal(await page.evaluate(() => previews.at(-1)[0]), "tab");
  // Unknown binary files still expose OPEN, without an image preview.
  await page.evaluate(() => { asset.attachments[0].mimeType = "application/octet-stream"; asset.attachments[0].filename = "source.zip"; NRCFiles.showInspector({ id: 5198n }); });
  assert.equal(await host.locator("img").count(), 0);
  await host.getByRole("button", { name: "OPEN", exact: true }).click();
  assert.equal(await page.evaluate(() => previews.at(-1)[0]), "tab");
  assert.deepEqual(errors, []);
  console.log("PASS: File inspector/dialog, generic-MIME inline image decoding, OPEN and keyboard preview, native DOWNLOAD, metadata edit/cancel, PDF/binary OPEN, both themes and widths");
} finally { await browser.close(); }
