import assert from "node:assert/strict";
import { chromium } from "playwright";

const url = process.env.NRC_CLIENT_URL || "http://127.0.0.1:8096";
assert.ok(["127.0.0.1", "localhost"].includes(new URL(url).hostname));
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ serviceWorkers: "block" });
  await page.goto(`${url}/#workspace=appointment-races-${Date.now()}`);
  await page.waitForFunction(() => typeof serverReady !== "undefined" && serverReady);
  const [a, b] = await page.evaluate(async () => {
    const create = title => new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 12, 0, 0n,
      JSON.stringify({ version: 1, title, start_at: "1790596800000000000" }), "", 0,
      { onSuccess: r => resolve(String(r.asset.assetId)), onError: reject }));
    return [await create("A"), await create("B")];
  });
  const open = async id => {
    await page.evaluate(id => NRCInspector.openEntity({ roomId: 0n, type: "appointment", id: BigInt(id) }), id);
    await page.waitForFunction(id => String(NRCInspector.current()?.id) === id && !!document.getElementById("appointmentTitle"), id);
  };
  await open(a);
  await page.evaluate(() => {
    window.updateOriginal = NRCAssets.sendUpdateAsset;
    NRCAssets.sendUpdateAsset = (...args) => { window.pendingUpdate = args; return true; };
  });
  await page.locator("#appointmentTitle").fill("A saved draft");
  await page.locator("#appointmentSave").click();
  assert.equal(await page.locator("#appointmentTitle").isDisabled(), true);
  assert.equal(await page.locator("#appointmentDelete").isDisabled(), true);
  assert.equal(await page.locator('[data-control="appointment-project"] button').isDisabled(), true);
  assert.equal(await page.evaluate(() => NRCAppointments.confirmDiscardEdits()), false);
  await open(a); // same entity does not bypass the pending mutation guard
  await page.evaluate(() => pendingUpdate.at(-1).onError({ message: "Retry test" }));
  assert.equal(await page.locator("#appointmentTitle").isDisabled(), false);
  assert.equal(await page.locator("#appointmentTitle").inputValue(), "A saved draft");
  await page.locator("#appointmentSave").click();
  await page.evaluate(() => {
    const args = pendingUpdate;
    args.at(-1).onSuccess({ asset: { ...NRCAssets.roomAssets.get(0n).get(args[1]), preview: args[2] } });
    NRCAssets.sendUpdateAsset = updateOriginal;
  });
  await page.waitForFunction(() => !document.getElementById("appointmentTitle").disabled);

  // Hold a delete, then simulate another subscriber removing A. Its late local
  // acknowledgement must not clear B's selection or change B's update to create.
  await page.evaluate(() => {
    window.deleteOriginal = NRCAssets.sendDeleteAsset;
    NRCAssets.sendDeleteAsset = (...args) => { window.pendingDelete = args; return true; };
  });
  await page.locator("#appointmentDelete").click();
  await page.getByRole("button", { name: "Delete Appointment", exact: true }).click();
  assert.equal(await page.locator("#appointmentTitle").isDisabled(), true);
  assert.equal(await page.evaluate(() => NRCAppointments.confirmDiscardEdits()), false);
  await page.evaluate(id => NRCInspector.entityDeleted({ roomId: 0n, type: "appointment", id: BigInt(id) }), a);
  await open(b);
  await page.locator("#appointmentTitle").fill("B preserved");
  await page.evaluate(() => {
    pendingDelete.at(-1).onSuccess();
    NRCAssets.sendDeleteAsset = deleteOriginal;
    window.updateIDs = [];
    NRCAssets.sendUpdateAsset = (...args) => { updateIDs.push(String(args[1])); return updateOriginal(...args); };
  });
  await page.locator("#appointmentSave").click();
  await page.waitForFunction(id => NRCAssets.roomAssets.get(0n).get(BigInt(id))?.preview.includes("B preserved"), b);
  assert.deepEqual(await page.evaluate(() => updateIDs), [b]);
  assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), b);

  // A confirmation belongs to the identity present when it opened.
  await open(a);
  await page.locator("#appointmentDelete").click();
  await page.evaluate(id => NRCInspector.entityDeleted({ roomId: 0n, type: "appointment", id: BigInt(id) }), a);
  await open(b);
  await page.getByRole("button", { name: "Delete Appointment", exact: true }).click();
  assert.equal(await page.locator("#appointmentTitle").isDisabled(), false);
  assert.equal(await page.evaluate(id => NRCAssets.roomAssets.get(0n).has(BigInt(id)), b), true);
  await page.locator("#appointmentTitle").fill("Offline draft");
  await page.locator("#appointmentDelete").click();
  await page.context().setOffline(true);
  await page.evaluate(() => ws.close());
  await page.waitForFunction(() => !serverReady);
  await page.getByRole("button", { name: "Delete Appointment", exact: true }).click();
  assert.equal(await page.locator("#appointmentTitle").isDisabled(), false);
  assert.equal(await page.locator("#appointmentTitle").inputValue(), "Offline draft");
  assert.match(await page.locator("#appointmentValidationError").textContent(), /OFFLINE/);
  await page.context().setOffline(false);
  await page.evaluate(() => manualReconnect()); // Explicit clean close above requires manual reconnect.
  await page.waitForFunction(() => serverReady);
  await page.evaluate(() => {
    NRCAssets.sendUpdateAsset = () => undefined;
    NRCAssets.sendDeleteAsset = () => undefined;
  });
  await page.locator("#appointmentSave").click();
  assert.equal(await page.locator("#appointmentTitle").isDisabled(), false);
  assert.match(await page.locator("#appointmentValidationError").textContent(), /SAVE NOT SENT/);
  await page.locator("#appointmentDelete").click();
  await page.getByRole("button", { name: "Delete Appointment", exact: true }).click();
  assert.equal(await page.locator("#appointmentTitle").isDisabled(), false);
  assert.match(await page.locator("#appointmentValidationError").textContent(), /DELETE NOT SENT/);
  await page.evaluate(() => { NRCAssets.sendUpdateAsset = updateOriginal; NRCAssets.sendDeleteAsset = deleteOriginal; });
  await page.locator("#appointmentSave").click();
  await page.waitForFunction(id => NRCAssets.roomAssets.get(0n).get(BigInt(id))?.preview.includes("Offline draft"), b);
  await page.waitForFunction(() => !document.getElementById("appointmentTitle").disabled);
  await page.evaluate(() => NRCAppointments.create());
  await page.waitForFunction(() => NRCInspector.current()?.id === 0n);
  await page.locator("#appointmentTitle").fill("Unsent create");
  await page.locator("#appointmentStart").fill("2026-09-28T14:00");
  await page.evaluate(() => { NRCAssets.sendCreateAsset = () => undefined; });
  await page.locator("#appointmentSave").click();
  assert.equal(await page.locator("#appointmentTitle").isDisabled(), false);
  assert.match(await page.locator("#appointmentValidationError").textContent(), /SAVE NOT SENT/);
  console.log("PASS: pending saves, stale delete ACK/confirmation, offline confirmation, unsent mutations and reconnect retry preserve the correct draft");
} finally { await browser.close(); }
