// Run against test/customer-workspace-dev.mjs, never a shared workspace.
import assert from "node:assert/strict";
import { chromium } from "playwright";

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url || !["localhost", "127.0.0.1"].includes(new URL(url).hostname)) throw new Error("Use a disposable local fixture");
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`${url}/#workspace=batch-reads-${Date.now()}`);
  await page.waitForFunction(() => serverReady);
  const result = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const tasks = [];
    for (let i = 0; i < 65; i++) {
      const created = await rpc(options => NRCTasks.sendCreateTask(0n, `Batch task ${i}`, "x".repeat(4096), 1, 0, "", 0n, [], 1, 0, "", options));
      tasks.push(created.task);
    }
    const notes = [];
    for (let i = 0; i < 10; i++) {
      const created = await rpc(options => NRCAssets.sendCreateAsset(0n, 5, 0, 0n, JSON.stringify({ title: `Batch note ${i}` }), `Body ${i}`, 0, options));
      notes.push(created.asset);
    }
    const preview = JSON.stringify({ version: 1, name: "Batch slice", owner: "", outcome: "35 tasks and 10 notes", closed: false });
    const slice = (await rpc(options => NRCAssets.sendCreateAsset(0n, 11, 0, 0n, preview, preview, 0, options))).asset;
    for (const task of tasks.slice(0, 35)) await rpc(options => NRCEdges.sendCreateEdge(0n, 2, task.id, 1, slice.assetId, 7, options));
    for (const note of notes) await rpc(options => NRCEdges.sendCreateEdge(0n, 1, note.assetId, 1, slice.assetId, 7, options));
    roomTasks.clear();
    NRCAssets.roomAssets.clear();
    const sent = [];
    const send = ws.send.bind(ws);
    ws.send = buffer => { sent.push(new DataView(buffer)); send(buffer); };
    // 65 cold IDs require two requests. Overlapping and exact readers share them.
    const all = NRCTasks.requestTasksByIds(0n, [...tasks.map(task => task.id), tasks[0].id, 999999n]);
    const overlap = NRCTasks.requestTasksByIds(0n, [tasks[64].id, tasks[0].id]);
    const exact = new Promise((resolve, reject) => NRCTasks.requestTask(0n, tasks[1].id, { onSuccess: resolve, onError: reject }));
    const [loaded, joined, single] = await Promise.all([all, overlap, exact]);
    const coldRequests = sent.filter(view => view.getUint16(0) === 60).map(view => view.getUint16(15));
    const loadedCorrectly = loaded.length === 65 && loaded.every((task, i) => task.title === `Batch task ${i}` && task.description.length === 4096);
    const joinedCorrectly = joined[0].id === tasks[64].id && joined[1].id === tasks[0].id && single.task.id === tasks[1].id;
    // Exercise the real cold Slice loader, not a transport substitute.
    roomTasks.clear();
    NRCAssets.roomAssets.clear();
    sent.length = 0;
    setTaskGrouping("slices");
    showKanban();
    window.batchWire = sent;
    window.batchExpected = { sliceId: slice.assetId, taskId: tasks[0].id, noteId: notes[0].assetId };
    return { coldRequests, loadedCorrectly, joinedCorrectly };
  });
  assert.deepEqual(result.coldRequests, [64, 2]);
  assert.equal(result.loadedCorrectly, true);
  assert.equal(result.joinedCorrectly, true);
  await page.waitForFunction(() => NRCSlices.getState().members.mode === "ready" && NRCSlices.getState().members.tasks.length === 35);
  const sliceResult = await page.evaluate(() => ({
    tasks: document.querySelectorAll("#sliceRecord [data-member-task]").length,
    notes: NRCSlices.getState().notes.assets.length,
    requests: batchWire.filter(view => [26, 33, 60, 61].includes(view.getUint16(0))).map(view => view.getUint16(0)).sort(),
    previewsOnly: NRCSlices.getState().notes.assets.every(asset => asset.payload == null),
  }));
  assert.equal(sliceResult.tasks, 35);
  assert.equal(sliceResult.notes, 10);
  assert.equal(sliceResult.previewsOnly, true);
  assert.deepEqual(sliceResult.requests, [33, 60, 61]);
  // Opening a note still loads its full body after preview-only hydration.
  const payload = await page.evaluate(async () => {
    const [note] = await NRCAssets.requestAssetsByIds(0n, [batchExpected.noteId], { fullContent: true });
    return note.payload;
  });
  assert.equal(payload, "Body 0");
  await page.waitForFunction(() => NRCCustomers.isEnabled());
  const customer = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const create = (type, title) => rpc(o => NRCAssets.sendCreateAsset(0n, type, 0, 0n,
      JSON.stringify({ version: 1, title }), "", 0, o));
    const company = (await create(8, "Hydration race company")).asset;
    const contact = (await create(9, "Old contact title")).asset;
    const activity = (await create(10, "Deleted activity title")).asset;
    for (const asset of [contact, activity]) await rpc(o => NRCEdges.sendCreateEdge(0n, 1, asset.assetId, 1, company.assetId, 7, o));
    const read = NRCAssets.requestAssetsByIds;
    NRCAssets.requestAssetsByIds = async (...args) => {
      NRCAssets.requestAssetsByIds = read;
      const snapshots = await read(...args);
      return new Promise(resolve => { window.releaseCustomerHydration = () => resolve(snapshots); });
    };
    NRCCustomers.openCompany(company);
    return { contact: String(contact.assetId), activity: String(activity.assetId) };
  });
  await page.waitForFunction(() => !!window.releaseCustomerHydration);
  const hydrated = await page.evaluate(async ({ contact, activity }) => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    await rpc(o => NRCAssets.sendUpdateAsset(0n, BigInt(contact), JSON.stringify({ version: 1, title: "Updated contact title" }), "", 9, 0, o));
    await rpc(o => NRCAssets.sendDeleteAsset(0n, BigInt(activity), o));
    window.releaseCustomerHydration();
    // Inspect this completion, before a later live-event refresh can mask a stale publication.
    await new Promise(resolve => setTimeout(resolve, 0));
    return {
      contacts: document.querySelector(".customer-contacts").textContent,
      history: document.querySelector("#customerHistory").textContent,
    };
  }, customer);
  assert.equal(hydrated.contacts.includes("Updated contact title"), true);
  assert.equal(hydrated.contacts.includes("Old contact title"), false);
  assert.equal(hydrated.history.includes("Deleted activity title"), false);
  assert.deepEqual(errors, []);
  console.log("PASS chunked/overlapping reads; cold slice in two batches; full body on demand; customer hydration preserves concurrent update and deletion");
} finally {
  await browser.close();
}
