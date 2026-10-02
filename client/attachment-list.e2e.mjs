// Real renderer and lifecycle; preview calls are intercepted, downloads stay native.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 2 });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/") return route.fulfill({ contentType: "text/html", body: `<!doctype html><meta charset="utf-8">
      <link rel="stylesheet" href="/css/main.css"><main style="padding:16px;width:100%"></main>
      <script src="/attachments.js"></script>` });
    await route.fulfill({ path: fileURLToPath(new URL(`.${path}`, import.meta.url)) });
  });
  await page.goto("http://nrc.test/");
  await page.evaluate(() => {
    window.escapeHtml = value => {
      const el = document.createElement("span");
      el.textContent = String(value);
      return el.innerHTML.replaceAll('"', "&quot;");
    };
    window.previews = [];
    window.openImageModal = (...args) => previews.push(["image", ...args]);
    window.open = (...args) => previews.push(["tab", ...args]);
    window.files = [
      { fileId: "image/1", filename: 'Screen <review>.png', mimeType: "image/png", size: 2048 },
      { fileId: "pdf2", filename: "spec.pdf", mimeType: "application/pdf", size: 1024 },
      { fileId: "zip3", filename: "source.zip", mimeType: "application/zip", size: 4096 },
    ];
    document.querySelector("main").innerHTML = renderAttachmentPreviewStripHtml(files);
  });
  const host = page.locator("nrc-attachment-list");
  assert.equal(await host.locator(".note-link-item").count(), 3);
  assert.equal(await host.getByRole("button", { name: "OPEN", exact: true }).count(), 2);
  assert.equal(await host.locator("a[download]").count(), 3);
  assert.equal(await host.locator("a").first().getAttribute("href"), "/files/image%2F1?filename=Screen+%3Creview%3E.png");
  assert.equal(await host.locator("a").first().getAttribute("download"), "Screen <review>.png");
  await host.getByRole("button", { name: "OPEN", exact: true }).first().focus();
  await page.keyboard.press("Enter");
  await host.getByRole("button", { name: "OPEN", exact: true }).nth(1).click();
  assert.deepEqual(await page.evaluate(() => previews), [
    ["image", "/files/image%2F1?inline=true&filename=Screen+%3Creview%3E.png", "Screen <review>.png", "Screen <review>.png"],
    ["tab", "/files/pdf2?inline=true&filename=spec.pdf", "_blank", "noopener,noreferrer"],
  ]);
  for (let i = 0; i < 3; i++) {
    await page.evaluate(() => {
      const el = document.querySelector("nrc-attachment-list");
      el.remove();
      el.querySelector("button").click(); // Disconnected hosts must not act.
      document.querySelector("main").append(el);
    });
    await host.locator("button").first().click();
  }
  assert.equal(await page.evaluate(() => previews.length), 5, "reconnection binds once, removal unbinds");
  await page.evaluate(() => {
    const el = document.querySelector("nrc-attachment-list");
    const replacement = document.createElement("template");
    replacement.innerHTML = renderAttachmentPreviewStripHtml([files[1]]);
    el.replaceChildren(...replacement.content.firstElementChild.childNodes);
    el.querySelector("button").innerHTML = "<span>OPEN</span>";
  });
  await host.locator("button span").click();
  assert.deepEqual(await page.evaluate(() => previews.at(-1)), ["tab", "/files/pdf2?inline=true&filename=spec.pdf", "_blank", "noopener,noreferrer"]);
  assert.equal(await page.evaluate(() => previews.length), 6, "replacement rows and nested click targets work without init");
  await page.evaluate(() => {
    document.querySelector("main").innerHTML = renderAttachmentPreviewStripHtml(files);
  });
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["light", "dark"]) {
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 720 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      assert.equal(await host.locator("button").count(), 2);
      const geometry = await host.evaluate(el => {
        const measure = root => [root, ...root.querySelectorAll("*")].map(node => {
          const { x, y, width, height } = node.getBoundingClientRect();
          return [x, y, width, height];
        });
        const component = measure(el);
        const legacy = document.createElement("div");
        legacy.className = el.className;
        legacy.innerHTML = el.innerHTML;
        el.replaceWith(legacy);
        const original = measure(legacy);
        legacy.replaceWith(el);
        return { component, original };
      });
      assert.deepEqual(geometry.component, geometry.original, `${theme}/${width}: host preserves the original div layout`);
      await host.screenshot({ path: `.amp/in/artifacts/attachment-list-${theme}-${width}.png` });
    }
  }
  assert.deepEqual(errors, []);
  console.log("PASS: attachment rendering, escaped/native download URLs, image/PDF previews, keyboard, disconnect/reconnect and row replacement; both themes and widths");
} finally { await browser.close(); }
