import assert from "node:assert/strict";
import { cp, mkdtemp, readFile, rm, appendFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import { buildClient } from "../build.mjs";

const client = fileURLToPath(new URL("../", import.meta.url));
const temp = await mkdtemp(path.join(os.tmpdir(), "nrc-production-e2e-"));
const sourceDir = path.join(temp, "source");
let root = path.resolve(client);
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".woff2": "font/woff2", ".webmanifest": "application/manifest+json", ".png": "image/png", ".ico": "image/x-icon" };
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const name = url.pathname === "/" ? "/index.html" : url.pathname;
  const file = path.resolve(root, "." + name);
  if (!file.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
  try {
    const body = await readFile(file);
    res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream", "Cache-Control": name.startsWith("/assets/") ? "public, max-age=31536000, immutable" : "no-cache" }).end(body);
  } catch { res.writeHead(404).end(); }
});
let browser;
try {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;
  browser = await chromium.launch({ headless: true, args: ["--enable-unsafe-swiftshader"] });
  await cp(client, sourceDir, { recursive: true, filter: (file) => !path.relative(client, file).split(path.sep).some((part) => ["node_modules", "dist"].includes(part)) });
  const first = await buildClient({ sourceDir, outDir: path.join(temp, "first") });
  const context = await browser.newContext();
  const errors = [];
  const graphRequests = [];
  context.on("request", (request) => {
    if (/graphology|@cosmos\.gl/.test(request.url())) graphRequests.push(request.url());
  });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  page.on("pageerror", (error) => errors.push(error.message));
  const loadFonts = () => page.evaluate(async () => {
    const fonts = await Promise.all([document.fonts.load("16px Inter", "NRC 0123"), document.fonts.load('16px "IBM Plex Mono"', "NRC 0123")]);
    return fonts.every((faces) => faces.length > 0 && faces.every((face) => face.status === "loaded"));
  });
  const updateWorker = async (name) => {
    const previous = await page.evaluateHandle(() => navigator.serviceWorker.controller);
    const registration = await page.evaluateHandle(() => navigator.serviceWorker.getRegistration());
    try {
      await page.evaluate((registration) => registration.update(), registration);
      // Keep this predicate synchronous. A Promise is truthy to Playwright's
      // polling loop, even when it resolves to false before activation finishes.
      await page.waitForFunction(({ registration, previous }) =>
        registration.active?.state === "activated" &&
        navigator.serviceWorker.controller === registration.active &&
        navigator.serviceWorker.controller !== previous && previous.state === "redundant",
      { registration, previous });
      assert.equal(await page.evaluate((expected) => caches.has(expected), name), true);
    } finally {
      await previous.dispose();
      await registration.dispose();
    }
  };
  // Exercise the installed source worker -> generated production worker transition.
  await page.goto(url);
  await page.waitForFunction(() => !!navigator.serviceWorker.controller);
  console.log("Source worker installed; testing production upgrade");
  // This older, unrelated cache survives activation. Global caches.match would
  // pick its stale HTML/CSS instead of the newly installed production shell.
  await page.evaluate(async (css) => {
    const stale = await caches.open("unrelated-app-shell");
    await stale.put("./index.html", new Response("<title>STALE SHELL</title>"));
    await stale.put(css, new Response("body {}", { headers: { "Content-Type": "text/css" } }));
  }, first.css);
  root = first.outDir;
  await updateWorker(first.cacheName);
  // No online navigation may warm the new shell before this offline upgrade.
  await cdp.send("Network.clearBrowserCache");
  await context.setOffline(true);
  await page.reload({ waitUntil: "domcontentloaded" });
  assert.equal(await page.evaluate(() => !!(window.marked && window.katex && window.DOMPurify && window.zstdCodec?.ZstdInit)), true);
  assert.equal(await loadFonts(), true);
  assert.deepEqual(errors, [], "production initialization must not throw");
  assert.equal(await page.evaluate(() => window.NRCTasks.createTaskFromPalette !== createTaskFromPalette), true,
    "task API must retain its implementation, not capture app.js's forwarding wrapper");
  assert.ok(await page.locator(`link[href="${first.css}"]`).count());
  assert.equal(await page.evaluate(() => ["Inter", "IBM Plex Mono"].every((name) => [...document.fonts].some((font) => font.family.replaceAll('"', '') === name && font.status === "loaded"))), true);
  const resources = await page.evaluate(() => performance.getEntriesByType("resource").map((r) => r.name));
  assert.ok(!resources.some((name) => /fonts\.(googleapis|gstatic)\.com/.test(name)));

  // A warmed installed shell must work with the HTTP cache cleared and network off.
  await cdp.send("Network.clearBrowserCache");
  await context.setOffline(true);
  await page.reload({ waitUntil: "domcontentloaded" });
  assert.equal(await page.title(), "NRC TERMINAL");
  assert.equal(await loadFonts(), true);
  assert.deepEqual(errors, [], "offline initialization must not throw");
  assert.equal(await page.locator("#messageInput").count(), 1);
  await context.setOffline(false);

  // A CSS-only deployment must change both the URL and installed shell revision.
  await appendFile(path.join(sourceDir, "css/workspace.css"), "\nbody { outline-color: rgb(13, 27, 41); }\n");
  const second = await buildClient({ sourceDir, outDir: path.join(temp, "second") });
  assert.notEqual(first.css, second.css);
  root = second.outDir;
  await updateWorker(second.cacheName);
  await cdp.send("Network.clearBrowserCache");
  await context.setOffline(true);
  await page.reload({ waitUntil: "domcontentloaded" });
  assert.equal(await page.evaluate(() => getComputedStyle(document.body).outlineColor), "rgb(13, 27, 41)");
  await cdp.send("Network.clearBrowserCache");
  await context.setOffline(true);
  await page.reload({ waitUntil: "domcontentloaded" });
  assert.equal(await page.evaluate(() => getComputedStyle(document.body).outlineColor), "rgb(13, 27, 41)");

  await context.setOffline(false);
  await appendFile(path.join(sourceDir, "app.js"), "\nglobalThis.productionRevision = 37;\n");
  const third = await buildClient({ sourceDir, outDir: path.join(temp, "third") });
  assert.notEqual(third.cacheName, second.cacheName);
  assert.notDeepEqual(third.assets.filter((file) => file.endsWith(".js")), second.assets.filter((file) => file.endsWith(".js")));
  root = third.outDir;
  await updateWorker(third.cacheName);
  await cdp.send("Network.clearBrowserCache");
  await context.setOffline(true);
  await page.reload({ waitUntil: "domcontentloaded" });
  assert.equal(await page.evaluate(() => globalThis.productionRevision), 37);
  await cdp.send("Network.clearBrowserCache");
  await context.setOffline(true);
  await page.reload({ waitUntil: "domcontentloaded" });
  assert.equal(await page.evaluate(() => globalThis.productionRevision), 37);
  assert.deepEqual(errors, []);
  console.log("PASS: source-to-production upgrade, offline fonts, CSS/JS deployments and offline upgrades, legacy function capture; no page errors");

  await context.setOffline(false);
  await page.evaluate(() => localStorage.setItem("nrc-ui-state", JSON.stringify({ roomId: "0", mode: "graph" })));
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.NRCViewManager?.getActiveView() === "chat");
  assert.equal(await page.locator("#graphBtn, #graphPanel, #graphContainer").count(), 0, "Graph UI is absent from production output");
  assert.deepEqual(graphRequests, [], "startup, worker installs, and legacy state fallback must not fetch graph libraries");
  assert.deepEqual(errors, []);
  console.log("PASS: Graph UI and renderer requests are absent; legacy saved Graph mode falls back to chat");
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
  await rm(temp, { recursive: true, force: true });
}
