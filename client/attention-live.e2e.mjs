// Real-server acceptance test and review seed. Run only against the disposable
// test/customer-workspace-dev.mjs fixture. Leaves its unique workspace populated.
// NRC_CLIENT_URL=http://127.0.0.1:8091 node client/attention-live.e2e.mjs
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_CLIENT_URL || "http://127.0.0.1:8091";
assert.ok(["127.0.0.1", "localhost"].includes(new URL(url).hostname), "Use a disposable local fixture");
const workspace = `attention-review-${Date.now()}`;
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ serviceWorkers: "block", timezoneId: "Europe/Berlin" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`${url}/#workspace=${workspace}`);
  await page.waitForFunction(() => typeof serverReady !== "undefined" && serverReady && myNickname === "customer-preview");
  const ids = await page.evaluate(async () => {
    const stamp = BigInt(Date.now()) * 1000000n;
    const day = 86400000000000n;
    const rpc = send => new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Fixture RPC timeout")), 15000);
      send({ onSuccess: result => { clearTimeout(timer); resolve(result); }, onError: error => { clearTimeout(timer); reject(new Error(error?.message || "Fixture RPC failed")); } });
    });
    const create = async (title, due = 0n, blocked = 0n, assignee = myNickname) => {
      const result = await rpc(options => NRCTasks.sendCreateTask(0n, title,
        "Disposable ATTENTION review data. You can edit this task safely.", 128, 0, "", due, [], 1, 0, "NRC RELEASE", options));
      await rpc(options => NRCTasks.sendUpdateTask(0n, result.task.id, "", "", 1, assignee, 255, 255, "", 0n, blocked, [], "", options));
      return result.task.id;
    };
    const prerequisite = await create("Confirm rollout approval");
    const overdue = await create("Review deployment checklist", stamp - 2n * day, prerequisite);
    const blocked = await create("Ship search index after rollout approval", 0n, prerequisite);
    const otherDependent = await create("Publish rollout notice for support", 0n, prerequisite, "alex");
    await create("Verify customer export permissions before rollout to external collaborators", stamp + 3n * day);
    await create("Document backup recovery procedure");
    await create("Prepare October release review", stamp + 7n * day);
    for (const [title, offset] of [["Customer follow-up", -day], ["Renew staging certificate", day]]) {
      const payload = buildReminderPayload({ title, deadlineAt: stamp + offset, windowStartAt: 0n, urgencyDays: 3, noteAssetId: 0n });
      await rpc(options => NRCAssets.sendCreateAsset(0n, AssetType.Reminder, 0, 0n, title, payload, 0, options));
    }
    // Existing slice API writes the asset and its MemberOf edge over the socket.
    const slice = await rpc(options => NRCAssets.sendCreateAsset(0n, AssetType.Slice, 0, 0n,
      JSON.stringify({ version: 1, name: "Search release", owner: myNickname, outcome: "Release verified and deployed" }), "", 0, options));
    await rpc(options => NRCEdges.sendCreateEdge(0n, TargetType.Task, blocked, TargetType.Asset, slice.asset.assetId, RelationType.MemberOf, options));
    return { overdue: String(overdue), blocked: String(blocked), prerequisite: String(prerequisite),
      otherDependent: String(otherDependent), slice: String(slice.asset.assetId) };
  });
  await page.evaluate(() => NRCViewManager.setActiveView("attention"));
  await page.waitForFunction(() => NRCAttention.getState().rows.filter(r => r.kind === "TASK").length === 5);
  assert.deepEqual(await page.locator(".attention-group-heading").allTextContents(), [
    "OVERDUE / WAITING1 ITEM", "UNBLOCKS / MY WORK1 ITEM", "ASSIGNED TO ME3 ITEMS", "DUE REMINDERS / WORKSPACE2 ITEMS",
  ]);
  const disclosure = page.locator(`[data-attention-key="TASK:${ids.prerequisite}"] + .attention-dependents`);
  const toggle = page.locator(`[data-attention-key="TASK:${ids.prerequisite}"] [data-attention-toggle]`);
  assert.equal(await toggle.textContent(), "▸ UNBLOCKS 3 TASKS");
  assert.equal(await disclosure.isVisible(), false);
  assert.ok((await disclosure.locator("button").allTextContents()).some(text => text.includes("alex")),
    "dependency disclosure includes another assignee");
  await toggle.click();
  await disclosure.locator(`[data-attention-task="${ids.otherDependent}"]`).click();
  await page.waitForFunction(() => document.querySelector("#inspector")?.textContent.includes("Publish rollout notice for support"));
  const prerequisiteLink = page.locator(`[data-attention-key="TASK:${ids.overdue}"]`);
  await prerequisiteLink.locator(`[data-attention-task="${ids.prerequisite}"]`).click();
  await page.waitForFunction(() => document.querySelector("#inspector")?.textContent.includes("Confirm rollout approval"));
  // Acknowledge a real edit while Attention remains open. No manual refresh:
  // the same row must move between reasons after its own update acknowledgement.
  await page.evaluate(async id => {
    await new Promise((resolve, reject) => NRCTasks.sendUpdateTask(0n, BigInt(id), "", "", 1, "", 255, 255, "",
      BigInt(Date.now() + 86400000) * 1000000n, 0n, [], "", { onSuccess: resolve, onError: reject }));
  }, ids.overdue);
  await page.waitForFunction(id => !NRCAttention.getState().rows.some(r => r.kind === "TASK" && String(r.id) === id), ids.overdue);
  assert.equal(await page.locator("#attention-reason-overdue").count(), 0);
  // Done removes an actionable prerequisite from attention, even with only a
  // TaskMoved response.
  await page.evaluate(async id => {
    await new Promise((resolve, reject) => sendMoveTask(0n, BigInt(id), 3, { onSuccess: resolve, onError: reject }));
  }, ids.prerequisite);
  await page.waitForFunction(id => !NRCAttention.getState().rows.some(r => String(r.id) === id && r.kind === "TASK"), ids.prerequisite);
  await page.waitForFunction(({ blocked, overdue }) => {
    const state = NRCAttention.getState();
    return state.mode === "ready" && state.dependencies.length === 0 &&
      [blocked, overdue].every(id => state.rows.some(r => r.kind === "TASK" && String(r.id) === id && r.reason === "assigned"));
  }, ids);
  assert.equal(await page.locator("#attentionBlockedCount").textContent(), "0", "completion automatically unblocks dependents");
  // Restore the illustrative prerequisite and overdue + waiting record for review.
  await page.evaluate(async id => {
    await new Promise((resolve, reject) => sendMoveTask(0n, BigInt(id), 1, { onSuccess: resolve, onError: reject }));
  }, ids.prerequisite);
  await page.waitForFunction(id => NRCAttention.getState().rows.find(r => r.kind === "TASK" && String(r.id) === id)?.reason === "assigned", ids.prerequisite);
  assert.equal(await page.locator("#attentionBlockedCount").textContent(), "0", "reopening does not restore dependencies");
  await page.evaluate(async ({ overdue, prerequisite, blocked, otherDependent }) => {
    for (const id of [blocked, otherDependent]) {
      await new Promise((resolve, reject) => NRCTasks.sendUpdateTask(0n, BigInt(id), "", "", 1, "", 255, 255, "",
        0n, BigInt(prerequisite), [], "", { onSuccess: resolve, onError: reject }));
    }
    await new Promise((resolve, reject) => NRCTasks.sendUpdateTask(0n, BigInt(overdue), "", "", 1, "", 255, 255, "",
      BigInt(Date.now() - 2 * 86400000) * 1000000n, BigInt(prerequisite), [], "", { onSuccess: resolve, onError: reject }));
  }, ids);
  await page.waitForFunction(id => NRCAttention.getState().rows.find(r => r.kind === "TASK" && String(r.id) === id)?.reason === "waiting", ids.overdue);
  await page.locator('[data-attention-filter="reminder"]').click();
  assert.equal(await page.locator(".attention-group").count(), 1);
  await page.locator('[data-attention-filter="all"]').click();
  await page.locator(`[data-attention-key="TASK:${ids.prerequisite}"] .attention-title`).click();
  await page.waitForFunction(() => document.querySelector("#inspector")?.textContent.includes("Confirm rollout approval"));
  await page.reload();
  await page.waitForFunction(() => typeof serverReady !== "undefined" && serverReady);
  await page.evaluate(() => NRCViewManager.setActiveView("attention"));
  await page.waitForFunction(() => NRCAttention.getState().rows.filter(r => r.kind === "TASK").length === 5);
  assert.equal(await page.locator(".attention-group-heading").count(), 4, "real server records survive page reload");
  assert.deepEqual(errors, []);
  await fs.writeFile("/tmp/nrc-attention-fixture.json", JSON.stringify({ workspace, ...ids }));
  console.log(`PASS: real-server actionable WHY groups, dependency links, own edits, automatic unblocking, reopen semantics, filters, inspector, reload. Workspace: ${workspace}`);
} finally {
  await browser.close();
}
