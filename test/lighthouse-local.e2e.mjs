import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

const origin = "http://127.0.0.1:8000";
const html = await fetch(origin, { headers: { "Accept-Encoding": "gzip" } });
assert.equal(html.status, 200);
assert.equal(html.headers.get("content-encoding"), "gzip");
assert.equal(html.headers.get("cache-control"), "no-cache");
const css = (await html.text()).match(/href="(assets\/[^\"]+\.css)"/)[1];
const asset = await fetch(`${origin}/${css}`, { headers: { "Accept-Encoding": "gzip" } });
assert.equal(asset.headers.get("content-encoding"), "gzip");
assert.equal(asset.headers.get("cache-control"), "public, max-age=31536000, immutable");
const compressedCSS = await readFile(new URL(`../client/dist/${css}.gz`, import.meta.url));
assert.equal(Number(asset.headers.get("content-length")), compressedCSS.length, "Nginx must serve the precompressed build file");
assert.match(asset.headers.get("vary"), /Accept-Encoding/i);
const plainAsset = await fetch(`${origin}/${css}`, { headers: { "Accept-Encoding": "identity" } });
assert.equal(plainAsset.headers.get("content-encoding"), null);
assert.equal(await plainAsset.text(), await asset.text(), "compressed and plain responses must have identical content");
for (const file of ["index.html", css]) {
  const expected = await readFile(new URL(`../client/dist/${file}`, import.meta.url), "utf8");
  for (const [accept, encoding, extension] of [
    ["gzip, deflate, br, zstd", "br", ".br"],
    ["br", "br", ".br"],
    ["br;q=0, gzip", "gzip", ".gz"],
    ["br;q=0, gzip;q=0, identity", null, ""],
  ]) {
    const response = await fetch(`${origin}/${file === "index.html" ? "" : file}`, { headers: { "Accept-Encoding": accept } });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-encoding"), encoding, accept);
    assert.match(response.headers.get("vary"), /Accept-Encoding/i);
    assert.equal(Number(response.headers.get("content-length")), (await readFile(new URL(`../client/dist/${file}${extension}`, import.meta.url))).length);
    assert.equal(await response.text(), expected, `${file}: ${accept}`);
  }
}
// Files without .br siblings must retain dynamic gzip for Brotli-capable clients.
for (const file of ["service-worker.js", "latency-worker.js"]) {
  const response = await fetch(`${origin}/${file}`, { headers: { "Accept-Encoding": "br, gzip" } });
  assert.equal(response.headers.get("content-encoding"), "gzip", file);
  assert.equal(await response.text(), await readFile(new URL(`../client/dist/${file}`, import.meta.url), "utf8"));
}
assert.equal((await fetch(`${origin}/assets/missing-fixture.js`)).status, 404);
assert.equal((await fetch(`${origin}/__local_auth`)).status, 404);
assert.equal((await fetch(`${origin}/ai/ready`)).status, 503);
assert.equal((await fetch(`${origin}/ai/ask/apply`, { method: "POST" })).status, 503);
const health = await fetch(`${origin}/search/health`);
assert.equal(health.status, 200);
assert.equal((await health.json()).status, "ok");

const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => { if (message.type() === "error") errors.push(message.text()); });
  await page.goto(origin);
  await page.waitForFunction(() => ws?.readyState === WebSocket.OPEN && nicknameReceived && serverReady && searchServiceAvailable);
  assert.equal(await page.locator("#logOutput").innerText(), "");
  assert.equal(await page.evaluate(() => searchServiceAvailable), true);
  assert.deepEqual(errors, []);
  console.log("PASS: Brotli/gzip/identity negotiation, immutable assets, HTML revalidation, missing asset/auth 404s, real search health, authenticated WebSocket, server readiness, no browser errors");
} finally {
  await browser.close();
}
