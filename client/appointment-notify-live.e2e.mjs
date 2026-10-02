// Real indexed reads and live events, with the OS Notification boundary mocked.
import assert from "node:assert/strict";
import { chromium } from "playwright";

const url = process.env.NRC_CLIENT_URL || "http://127.0.0.1:8096";
assert.ok(["127.0.0.1", "localhost"].includes(new URL(url).hostname));
const browser = await chromium.launch();
try {
  const context = await browser.newContext({ serviceWorkers: "block" });
  await context.addInitScript(() => {
    window.alerts = [];
    window.Notification = class {
      static permission = "granted";
      constructor(title, options) { this.title = title; this.options = options; window.alerts.push(this); }
      close() {}
    };
  });
  const workspace = `notify-e2e-${Date.now()}`;
  const a = await context.newPage(), b = await context.newPage();
  const errors = [];
  for (const p of [a, b]) {
    p.on("pageerror", error => errors.push(error.message));
    await p.goto(`${url}/#workspace=${workspace}`);
    await p.waitForFunction(() => typeof serverReady !== "undefined" && serverReady && window.NRCAppointmentNotify);
    await p.evaluate(() => NRCViewManager.setActiveView("chat"));
  }
  const id = await a.evaluate(async () => {
    const create = (title, owner, minutes) => new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 12, 0, 0n,
      JSON.stringify({ version: 1, title, start_at: String(BigInt(Date.now() + minutes * 60000) * 1000000n), assignee: owner }), "", 0,
      { onSuccess: result => resolve(String(result.asset.assetId)), onError: reject }));
    await create("Other person's call", "other", 10);
    await create("Already started", myNickname, -1);
    return create("Own upcoming call", myNickname, 14);
  });
  await a.waitForFunction(() => Object.keys(localStorage).some(key => key.startsWith("nrc-appointment-delivered:")));
  const count = async () => (await a.evaluate(() => alerts.length)) + (await b.evaluate(() => alerts.length));
  assert.equal(await count(), 1, "two tabs must deliver only one own upcoming appointment");
  const receiver = (await a.evaluate(() => alerts.length)) ? a : b;
  assert.equal(await receiver.evaluate(() => alerts[0].title), "Own upcoming call");
  await receiver.evaluate(() => alerts[0].onclick());
  await receiver.waitForFunction(id => String(NRCInspector.current()?.id) === id, id);
  await Promise.all([a, b].map(p => p.evaluate(() => NRCAppointmentNotify.restart())));
  await a.waitForTimeout(500);
  assert.equal(await count(), 1);
  await b.reload(); await b.waitForFunction(() => typeof serverReady !== "undefined" && serverReady);
  await b.waitForTimeout(500); assert.equal(await b.evaluate(() => alerts.length), 0, "reload must retain deduplication");

  // Shared editor keyboard contract: exact match must not select CLEAR;
  // explicit navigation selects the highlighted existing value, not typed text.
  await a.evaluate(() => {
    window.pickerWrites = [];
    const host = document.createElement("div"); host.id = "pickerE2E";
    host.innerHTML = NRCDetailUI.inlineField({ key: "picker-e2e", name: "PROJECT", value: "", suggestions: () => ["ALPHA", "ALPINE"],
      save: value => { pickerWrites.push(value); return new Promise((resolve, reject) => { window.finishPicker = resolve; window.failPicker = reject; }); } });
    document.body.append(host);
  });
  const open = () => a.locator("#pickerE2E button").click();
  await open(); await a.locator(".inline-field-editor input").fill("ALPHA");
  await a.locator(".inline-field-editor input").press("Enter");
  assert.deepEqual(await a.evaluate(() => pickerWrites), ["ALPHA"]);
  await a.locator(".inline-field-editor [data-value='']").click();
  await a.evaluate(() => finishPicker());
  await a.waitForFunction(() => !document.querySelector(".inline-field-editor"));
  assert.equal(await a.locator("#pickerE2E button").textContent(), "ALPHA");
  await open(); await a.locator(".inline-field-editor input").fill("ALP");
  await a.locator(".inline-field-editor input").press("End");
  await a.locator(".inline-field-editor input").press("Enter");
  assert.deepEqual(await a.evaluate(() => pickerWrites), ["ALPHA", "ALPINE"]);
  await a.evaluate(() => failPicker(new Error("Expected rejection")));
  await a.waitForFunction(() => document.querySelector(".inline-field-editor")?.dataset.state === "failed");
  await a.locator(".inline-field-editor input").press("Escape");
  assert.equal(await a.locator("#pickerE2E button").textContent(), "ALPHA");
  await open(); await a.locator(".inline-field-editor input").fill("NEW PROJECT");
  await a.locator(".inline-field-editor input").press("Enter");
  assert.equal(await a.evaluate(() => pickerWrites.at(-1)), "NEW PROJECT");
  await a.evaluate(() => finishPicker());
  await a.waitForFunction(() => !document.querySelector(".inline-field-editor"));
  await open(); await a.locator(".inline-field-editor [data-value='']").click();
  assert.equal(await a.evaluate(() => pickerWrites.at(-1)), "");
  await a.evaluate(() => finishPicker());
  assert.deepEqual(errors, []);
  console.log("PASS: real indexed notification outside Calendar, two-tab deduplication, reload, inspector click; shared picker exact/new/navigation/clear/cancel/failure/pending save");
} finally { await browser.close(); }
