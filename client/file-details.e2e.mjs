// Exercise the real File inspector and dialog with disposable asset responses.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";

// A real, dependency-free, single-page PDF with valid xref offsets.
function pdfFixture() {
  const stream = "BT /F1 24 Tf 40 160 Td (NRC PDF preview fixture) Tj ET";
  const objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 240] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`];
  let pdf = "%PDF-1.4\n";
  const offsets = [0];
  objects.forEach((object, i) => { offsets.push(Buffer.byteLength(pdf)); pdf += `${i + 1} 0 obj\n${object}\nendobj\n`; });
  const xref = Buffer.byteLength(pdf);
  pdf += `xref\n0 6\n0000000000 65535 f \n${offsets.slice(1).map(offset => `${String(offset).padStart(10, "0")} 00000 n \n`).join("")}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf);
}

// Full Chromium's new headless mode includes the native PDF viewer; the
// lightweight headless shell does not implement PDF embedding.
const browser = await chromium.launch({ channel: "chromium" });
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
    if (path.startsWith("/files/document")) return route.fulfill({ contentType: "application/pdf", headers: { "Content-Security-Policy": "sandbox", "X-Content-Type-Options": "nosniff", "Content-Disposition": "inline" }, body: pdfFixture() });
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
  assert.doesNotMatch(await host.textContent(), /ATTACHMENTS \(1\)/);
  assert.equal(await host.locator('.file-assets-binary-name').textContent(), 'Aufgabenmanagement <S08>.PNG');
  assert.equal(await host.getByRole("group").count(), 2);
  assert.equal(await host.locator("img").count(), 1);
  assert.equal(await host.locator("img").getAttribute("src"), "/files/image%2F1?inline=true&filename=Aufgabenmanagement+%3CS08%3E.PNG");
  const download = host.locator("a[download]");
  assert.equal(await download.getAttribute("href"), "/files/image%2F1?filename=Aufgabenmanagement+%3CS08%3E.PNG");
  await host.getByRole("button", { name: "OPEN", exact: true }).click();
  await host.locator(".file-assets-image").focus();
  await page.keyboard.press("Enter");
  assert.deepEqual(await page.evaluate(() => previews.map(p => p[0])), ["image", "image"]);
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["lupine", "matte-black"]) {
    for (const width of [900, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      const actionCenters = await host.locator('.file-assets-binary-actions > .btn').evaluateAll(buttons => buttons.map(button => {
        const range = document.createRange();
        range.selectNodeContents(button);
        const text = range.getBoundingClientRect();
        const box = button.getBoundingClientRect();
        return { text: text.y + text.height / 2, box: box.y + box.height / 2 };
      }));
      for (const action of actionCenters) assert.ok(Math.abs(action.text - action.box) <= 2, 'OPEN and DOWNLOAD labels are vertically centered');
      await host.locator("img").scrollIntoViewIfNeeded();
      await page.waitForFunction(() => [...document.images].every(img => img.complete && img.naturalWidth > 0));
      assert.equal(await host.locator(".file-assets-content").evaluate(el => el.scrollHeight <= el.clientHeight + 1), true, "file preview must not be cropped by an attachment ledger's scrolling cap");
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `${theme}/${width}: no horizontal overflow`);
      await page.evaluate(() => scrollTo(0, 0));
      await page.screenshot({ path: `.amp/in/artifacts/file-inspector-${theme}-${width}.png`, fullPage: true });
    }
  }
  // Dialog uses the same preview and supports returning from metadata editing.
  await page.setViewportSize({ width: 900, height: 1000 });
  await page.evaluate(() => { document.documentElement.dataset.theme = "lupine"; NRCFiles.open(asset, { readOnly: false }); });
  const dialog = page.getByRole("dialog");
  await dialog.waitFor();
  await dialog.getByRole("button", { name: "EDIT", exact: true }).click();
  assert.equal(await dialog.locator(".file-assets-metadata").isVisible(), false);
  await dialog.getByRole("button", { name: "CANCEL EDIT" }).click();
  assert.equal(await dialog.locator(".file-assets-metadata").isVisible(), true);
  await dialog.getByRole("button", { name: "OPEN", exact: true }).click();
  for (const theme of ["lupine", "matte-black"]) {
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
  const pdfResponse = page.waitForResponse(response => response.url().includes('/files/document%2F1'));
  await page.evaluate(() => { asset.attachments[0].fileId = "document/1"; asset.attachments[0].mimeType = "application/pdf"; NRCFiles.showInspector({ id: 5198n }); });
  // Chromium replaces PDF response bodies with its viewer document internally.
  assert.equal((await pdfResponse).headers()["content-type"], "application/pdf");
  assert.equal(pdfFixture().subarray(0, 8).toString(), "%PDF-1.4");
  assert.equal(await host.locator("img").count(), 0);
  assert.equal(await host.locator("object[type='application/pdf']").count(), 1);
  assert.match(await host.locator("object").getAttribute("data"), /^\/files\/document%2F1\?inline=true&filename=/);
  for (const theme of ["lupine", "matte-black"]) {
    for (const width of [900, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await page.waitForTimeout(1000);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await page.screenshot({ path: `.amp/in/artifacts/file-pdf-${theme}-${width}.png`, fullPage: true });
    }
  }
  await page.evaluate(() => {
    Object.defineProperty(navigator, "pdfViewerEnabled", { configurable: true, value: false });
    NRCFiles.showInspector({ id: 5198n });
  });
  assert.equal(await host.locator("object").count(), 0);
  assert.match(await host.textContent(), /If it is unavailable or blank, use OPEN above/);
  await host.getByRole("button", { name: "OPEN", exact: true }).click();
  assert.equal(await page.evaluate(() => previews.at(-1)[0]), "tab");
  await page.evaluate(() => { delete navigator.pdfViewerEnabled; });
  // Unknown binary files still expose OPEN, without an image preview.
  await page.evaluate(() => { asset.attachments[0].mimeType = "application/octet-stream"; asset.attachments[0].filename = "source.zip"; NRCFiles.showInspector({ id: 5198n }); });
  assert.equal(await host.locator("img").count(), 0);
  await host.getByRole("button", { name: "OPEN", exact: true }).click();
  assert.equal(await page.evaluate(() => previews.at(-1)[0]), "tab");
  // Older/API-created records may contain more than one binary; never hide them.
  await page.evaluate(() => {
    asset.attachments.push({ fileId: 'document/2', filename: 'Pilotbetrieb-Importprotokoll-und-technische-Freigabe-2026-10.pdf', mimeType: 'application/pdf', size: 4096 });
    NRCFiles.showInspector({ id: 5198n });
  });
  assert.equal(await host.locator('a[download]').count(), 2);
  assert.ok(await host.getByRole('link', { name: 'DOWNLOAD' }).nth(1).getAttribute('href').then(href => href.includes('document%2F2')));
  assert.ok(await host.locator('.file-assets-binary-name').last().evaluate(el => el.scrollWidth <= el.clientWidth), 'long binary names remain fully readable');
  await page.evaluate(() => { asset.attachments = []; NRCFiles.showInspector({ id: 5198n }); });
  assert.match(await host.textContent(), /No file uploaded/);
  assert.equal(await host.locator('a[download]').count(), 0);
  assert.deepEqual(errors, []);
  console.log("PASS: File inspector/dialog, generic-MIME inline image decoding, OPEN and keyboard preview, native DOWNLOAD, metadata edit/cancel, PDF/binary OPEN, both themes and widths");
} finally { await browser.close(); }
