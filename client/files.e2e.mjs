// Real NRC metadata/edge persistence; upload HTTP is stubbed, since the disposable
// customer fixture deliberately has no production file service.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import fs from "node:fs/promises";

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error("Use the disposable customer-workspace-dev fixture");
const browser = await chromium.launch();
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const page = await context.newPage();
  const errors = [], sent = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("websocket", socket => socket.on("framesent", ({ payload }) => { if (Buffer.isBuffer(payload)) sent.push(payload); }));
  await page.route("**/upload", route => route.fulfill({ json: { fileId: "att_11111111111111111111111111111111", filename: "vertrag.pdf", size: 248000, mimeType: "application/pdf", uploadedAt: 1 } }));
  await page.goto(`${url}/#workspace=file-assets-${Date.now()}`);
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  const ids = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const company = await rpc(o => NRCAssets.sendCreateAsset(currentRoomId, 8, 0, 0n, '{"version":1,"title":"Beispiel AG"}', "", 0, o));
    const note = await rpc(o => NRCAssets.sendCreateAsset(currentRoomId, 5, 0, 0n, '{"title":"Wartungsplanung","format":"markdown"}', "# Wartung\nPrüfung der Anlage im Oktober.", 0, o));
    const task = await rpc(o => NRCTasks.sendCreateTask(currentRoomId, "Vertrag verlängern", "Konditionen prüfen.", 128, 0, "", 0n, [], 1, 0, "Kundenbetreuung", o));
    return { company: String(company.asset.assetId), note: String(note.asset.assetId), task: String(task.task.id), room: "0" };
  });
  await page.click("#customersBtn");
  await page.click(`[data-company="${ids.company}"]`);
  await page.locator("#customerFiles").getByRole("button", { name: "+ UPLOAD", exact: true }).click();
  const dialog = page.locator(".file-assets-dialog");
  const filePicker = page.locator(".file-assets-picker");
  await dialog.locator('[name="file"]').setInputFiles({ name: "vertrag.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.4 test") });
  await dialog.locator('[name="title"]').fill("Wartungsvertrag 2026");
  await dialog.locator('[name="category"]').fill("Vertrag");
  await dialog.locator('[name="description"]').fill("Wartung und Service für Standort Berlin.");
  // First link fails deterministically after acknowledged creation. Retrying must
  // use that same asset, not upload or create again.
  await page.evaluate(() => {
    const original = NRCEdges.sendCreateEdge;
    NRCEdges.sendCreateEdge = (...args) => { NRCEdges.sendCreateEdge = original; args.at(-1).onError({ message: "Injected link failure" }); return 999; };
  });
  await dialog.getByRole("button", { name: "UPLOAD", exact: true }).click();
  await page.waitForFunction(() => document.querySelector(".file-assets-write-status")?.textContent.includes("LINK FAILED"));
  const creates = sent.filter(b => b.readUInt16BE(0) === 30).length;
  await dialog.getByRole("button", { name: "UPLOAD", exact: true }).click();
  await dialog.waitFor({ state: "detached" });
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 30).length, creates, "retry creates no second File asset");
  await page.waitForFunction(() => document.querySelector("#customerFiles .file-assets-row")?.textContent.includes("Wartungsvertrag 2026"));
  const file = await page.evaluate(() => String([...NRCAssets.roomAssets.get(0n).values()].find(a => a.assetType === 3).assetId));
  await page.locator("#customerFiles .file-assets-summary button").click();
  assert.equal(await dialog.locator('form').isVisible(), false, "Details starts read-only without duplicate fields");
  await dialog.getByRole("button", { name: "EDIT", exact: true }).click();
  await dialog.locator('[name="category"]').fill("Servicevertrag");
  await dialog.getByRole("button", { name: "SAVE METADATA" }).click();
  await dialog.waitFor({ state: "detached" });
  await page.waitForFunction(id => NRCFiles.parseMetadata(NRCAssets.roomAssets.get(0n).get(BigInt(id))).category === "Servicevertrag", file);
  assert.equal(await page.locator('#customerFiles .file-assets-meta-row').count(), 0, "rows omit secondary metadata");
  assert.equal(await page.locator('#customerFiles').getByRole('button', { name: /^REMOVE FROM THIS RECORD/ }).count(), 0, "unlink is only in Details");
  assert.equal(await page.evaluate(id => NRCAssets.roomAssets.get(0n).get(BigInt(id)).attachments.length, file), 1, "metadata patch retains attachment");
  await page.locator("#customerFiles .file-assets-summary button").click();
  await dialog.getByRole("button", { name: "EDIT", exact: true }).click();
  await dialog.locator('[name="category"]').fill("Local stale edit");
  await page.evaluate(async id => {
    const asset = NRCAssets.roomAssets.get(0n).get(BigInt(id));
    await new Promise((resolve, reject) => NRCTransactions.sendAssetMetadataPatch(asset,
      JSON.stringify({ ...JSON.parse(asset.preview), category: "Concurrent update" }),
      JSON.stringify({ ...JSON.parse(asset.payload), category: "Concurrent update" }),
      { onSuccess: resolve, onError: reject }));
  }, file);
  await dialog.getByRole("button", { name: "SAVE METADATA" }).click();
  await page.waitForFunction(() => document.querySelector(".file-assets-dialog [role=status]")?.textContent.includes("RECONCILE"));
  await dialog.getByRole("button", { name: "Close", exact: true }).click();
  await page.locator("#customerFiles .file-assets-summary button").click();
  await dialog.getByRole("button", { name: "EDIT", exact: true }).click();
  assert.equal(await dialog.locator('[name="category"]').inputValue(), "Concurrent update", "reopen fetches authoritative metadata after conflict");
  await dialog.locator('[name="category"]').fill("Servicevertrag");
  await dialog.getByRole("button", { name: "SAVE METADATA" }).click();
  await dialog.waitFor({ state: "detached" });
  // Both directions and both endpoint types render the dedicated section.
  await page.evaluate(async ({ ids, file }) => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    await rpc(o => NRCEdges.sendCreateEdge(currentRoomId, 1, BigInt(file), 1, BigInt(ids.note), 2, o));
    await rpc(o => NRCEdges.sendCreateEdge(currentRoomId, 2, BigInt(ids.task), 1, BigInt(file), 1, o));
  }, { ids, file });
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"));
  await page.locator("#customerFiles").scrollIntoViewIfNeeded();
  await page.screenshot({ path: ".amp/in/artifacts/nrc-file-assets-customer.png" });
  await page.evaluate(({ ids }) => NRCInspector.openEntity({ roomId: BigInt(ids.room), type: "note", id: BigInt(ids.note) }), { ids });
  await page.waitForFunction(() => document.querySelector("#noteLinksList") && document.querySelector(".note-preview-panel .file-assets-row"));
  assert.equal(await page.locator("#noteLinksList .note-link-item").count(), 0, "file is not duplicated in generic edges");
  await page.locator('[data-resource="files"] [data-resource-toggle]').click();
  assert.equal(await page.locator('.note-preview-panel .file-assets-section .panel-header button').count(), 0, "Files uses the shared Attach and Link actions");
  await page.click("#noteDetailEdit");
  await page.waitForFunction(() => document.getElementById("noteDetailContent"));
  assert.equal(await page.locator(".file-assets-section").filter({ has: page.getByText("Wartungsvertrag 2026", { exact: true }) }).count() > 0, true);
  await page.locator("#noteLinksList").evaluate(el => el.previousElementSibling?.scrollIntoView());
  await page.screenshot({ path: ".amp/in/artifacts/nrc-file-assets-note.png" });
  const previousDetail = await page.locator("#inspectorEntityHost").innerHTML();
  const readsBeforeReplacement = sent.filter(b => b.readUInt16BE(0) === 33 && b.readBigUInt64BE(10) === BigInt(file)).length;
  await page.evaluate(id => {
    NRCAssets.roomAssets.get(0n).delete(BigInt(id));
    const original = NRCAssets.requestAsset;
    NRCAssets.requestAsset = (room, id, options) => {
      NRCAssets.requestAsset = original;
      window.releaseFileRead = () => original(room, id, options);
      return 999;
    };
  }, file);
  await page.evaluate(({ ids }) => NRCInspector.openEntity({ roomId: BigInt(ids.room), type: "task", id: BigInt(ids.task) }), { ids });
  await page.waitForFunction(() => window.releaseFileRead && NRCInspector.isLoading());
  assert.equal(await page.locator("#inspectorEntityHost").innerHTML(), previousDetail, "unknown File does not publish a temporary generic link");
  await page.evaluate(() => { window.releaseFileRead(); delete window.releaseFileRead; });
  await page.waitForFunction(() => document.querySelector(".task-detail-panel .file-assets-row") && !document.querySelector(".task-detail-panel .task-detail-link-item"));
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 33 && b.readBigUInt64BE(10) === BigInt(file)).length - readsBeforeReplacement, 1, "one GET prepares the File before DOM replacement");
  await page.evaluate(({ ids }) => NRCInspector.openEntity({ roomId: BigInt(ids.room), type: "note", id: BigInt(ids.note) }), { ids });
  await page.waitForFunction(() => !NRCInspector.isLoading());
  await page.evaluate(id => {
    NRCAssets.roomAssets.get(0n).delete(BigInt(id));
    window.restoreFileRead = NRCAssets.requestAsset;
    NRCAssets.requestAsset = (room, id, options) => { queueMicrotask(() => options.onError({ message: "Injected GET failure" })); return 999; };
  }, file);
  await page.evaluate(({ ids }) => NRCInspector.openEntity({ roomId: BigInt(ids.room), type: "task", id: BigInt(ids.task) }), { ids });
  await page.waitForFunction(() => document.getElementById("inspectorEntityHost").textContent.includes("Injected GET failure"));
  assert.equal(await page.locator(".task-detail-panel .task-detail-link-delete").count(), 0, "uncached File has no unlink mutation in read-only task");
  await page.evaluate(() => { NRCAssets.requestAsset = window.restoreFileRead; delete window.restoreFileRead; });
  await page.locator("#inspectorEntityHost").getByRole("button", { name: "RETRY", exact: true }).click();
  await page.waitForFunction(() => document.querySelector(".task-detail-panel .file-assets-row"));
  // The read panel keeps its file ledger behind the FILES register line.
  await page.locator('.task-detail-panel [data-resource="files"] [data-resource-toggle]').click();
  await page.locator(".task-detail-panel .file-assets-section").waitFor({ state: "visible" });
  await page.locator(".task-detail-panel .file-assets-section").scrollIntoViewIfNeeded();
  await page.screenshot({ path: ".amp/in/artifacts/nrc-file-assets-task.png" });
  // Reload proves file records and their associations are durable, not optimistic UI.
  await page.reload();
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  await page.click("#customersBtn"); await page.click(`[data-company="${ids.company}"]`);
  await page.waitForFunction(() => document.querySelector("#customerFiles .file-assets-row"));
  // Every entity kind uses the shared paged picker, so older Files are reached
  // through the same MORE control as Notes and Tasks. The picker draws the
  // records this session has loaded and pages the rest in, so the reload is the
  // point: a client that created these Files itself already holds them and the
  // list would render whole without a page request.
  await page.evaluate(async () => {
    for (let i = 0; i < 51; i++) await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(currentRoomId, 3, 0, 0n,
      JSON.stringify({ version: 1, type: "file", title: `Fixture ${i}` }),
      JSON.stringify({ version: 1, type: "file", title: `Fixture ${i}` }), 0,
      { onSuccess: resolve, onError: reject }));
  });
  await page.reload();
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  await page.click("#customersBtn"); await page.click(`[data-company="${ids.company}"]`);
  await page.waitForFunction(() => document.querySelector("#customerFiles .file-assets-row"));
  await page.locator("#customerFiles").getByRole("button", { name: "+ LINK EXISTING", exact: true }).click();
  await page.waitForFunction(() => document.querySelectorAll(".file-assets-picker .note-link-picker-item").length > 0);
  const loadedBeforeMore = await page.evaluate(() => document.querySelectorAll(".file-assets-picker .note-link-picker-item").length);
  assert.ok(loadedBeforeMore < 52, `the picker starts on one page, not the whole register (${loadedBeforeMore})`);
  const more = filePicker.getByRole("button", { name: "MORE", exact: true });
  for (let attempt = 0; attempt < 4 && await more.isVisible(); attempt++) {
    await more.click();
    await page.waitForTimeout(500);
  }
  await page.waitForFunction(() => document.querySelectorAll(".file-assets-picker .note-link-picker-item").length === 52);
  assert.equal(await more.isVisible(), false, "MORE hides once the loaded list covers every matching record");
  const edgesBefore = sent.filter(b => b.readUInt16BE(0) === 40).length;
  await filePicker.locator(".note-link-picker-item").filter({ hasText: "Wartungsvertrag 2026" }).click();
  await filePicker.waitFor({ state: "detached" });
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 40).length, edgesBefore, "existing relation is reconciled, not duplicated");

  // A committed link with a lost acknowledgement times out. A second selection
  // must reconcile the committed relation rather than send another create.
  await page.locator("#customerFiles").getByRole("button", { name: "+ LINK EXISTING", exact: true }).click();
  await page.waitForFunction(() => document.querySelector(".file-assets-picker .note-link-picker-item"));
  await page.evaluate(() => {
    const original = NRCEdges.sendCreateEdge;
    NRCEdges.sendCreateEdge = (...args) => {
      NRCEdges.sendCreateEdge = original;
      args[6] = { ...args[6], onSuccess() {} };
      return original(...args);
    };
  });
  const fixtureRow = filePicker.locator(".note-link-picker-item").filter({ hasText: "Fixture 50" });
  await fixtureRow.click();
  await page.waitForTimeout(15500);
  const committedEdges = sent.filter(b => b.readUInt16BE(0) === 40).length;
  await fixtureRow.click();
  await filePicker.waitFor({ state: "detached" });
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 40).length, committedEdges, "lost acknowledgement recovery does not duplicate edge");
  // Unlink only the additional relation; other links and the File remain.
  const fixtureFile = page.locator("#customerFiles .file-assets-row").filter({ hasText: "Fixture 50" });
  await fixtureFile.locator(".file-assets-summary button").click();
  const deletesBeforeCancel = sent.filter(b => b.readUInt16BE(0) === 42).length;
  const remove = dialog.locator('.nrc-dialog-actions').getByRole("button", { name: "REMOVE FROM THIS RECORD", exact: true });
  assert.equal(await remove.getAttribute('class'), 'btn', "removing a link uses a normal footer button");
  await remove.click();
  await page.locator(".nrc-dialog-backdrop").getByRole("button", { name: "Cancel", exact: true }).click();
  assert.equal(sent.filter(b => b.readUInt16BE(0) === 42).length, deletesBeforeCancel, "cancel sends no unlink");
  assert.equal(await dialog.isVisible(), true, "cancel keeps Details open");
  await remove.click();
  await page.locator(".nrc-dialog-backdrop").getByRole("button", { name: "Confirm", exact: true }).click();
  await fixtureFile.waitFor({ state: "detached" });
  assert.equal(await page.evaluate(() => [...NRCAssets.roomAssets.get(0n).values()].some(a => a.preview.includes('Fixture 50'))), true);
  await page.evaluate(() => document.documentElement.setAttribute("data-theme", "light"));
  await page.locator("#customerFiles").scrollIntoViewIfNeeded();
  await page.screenshot({ path: ".amp/in/artifacts/nrc-file-assets-light.png" });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator("#customerFiles").scrollIntoViewIfNeeded();
  await page.screenshot({ path: ".amp/in/artifacts/nrc-file-assets-narrow.png" });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), "no page overflow");
  await page.setViewportSize({ width: 1440, height: 1100 });
  for (const type of ["note", "task"]) {
    await page.evaluate(({ ids, type }) => NRCInspector.openEntity({ roomId: 0n, type, id: BigInt(ids[type]) }), { ids, type });
    await page.getByRole("button", { name: "Edit ATTACHMENTS: empty" }).click();
    await page.getByRole("button", { name: "FILE WITH METADATA", exact: true }).click();
    await dialog.locator('[name="file"]').setInputFiles({ name: `${type}-record.pdf`, mimeType: "application/pdf", buffer: Buffer.from("test upload") });
    await dialog.locator('[name="title"]').fill(`Shared Attach ${type}`);
    await dialog.getByRole("button", { name: "UPLOAD", exact: true }).click();
    await dialog.waitFor({ state: "detached" });
    await page.waitForFunction(({ ids, type }) => {
      const asset = [...NRCAssets.roomAssets.get(0n).values()].find(a => NRCFiles.parseMetadata(a).title === `Shared Attach ${type}`);
      return asset && NRCEdges.getEdgesForEntity(0n, type === "task" ? 2 : 1, BigInt(ids[type])).some(edge => edge.targetType === 1 && edge.targetId === asset.assetId && edge.relation === 2);
    }, { ids, type });
    assert.equal(await page.locator('[data-attachment-editor]').count(), 0, "metadata upload does not open direct-attachment editing");
  }
  await page.click('#taskDetailLinkAdd');
  const sharedPicker = page.locator('.note-link-picker:visible');
  await sharedPicker.locator('[data-kind="file"]').click();
  await sharedPicker.locator('.note-link-picker-search').fill('Shared Attach note');
  await sharedPicker.locator('.note-link-picker-item').filter({ hasText: 'Shared Attach note' }).click();
  await page.waitForFunction(ids => {
    const file = [...NRCAssets.roomAssets.get(0n).values()].find(a => NRCFiles.parseMetadata(a).title === 'Shared Attach note');
    return NRCEdges.getEdgesForEntity(0n, 2, BigInt(ids.task)).some(edge => edge.targetType === 1 && edge.targetId === file.assetId && edge.relation === 1);
  }, ids);
  assert.deepEqual(errors, []);
  console.log("PASS File upload/link recovery, metadata patch/attachment retention, customer/note/task rendering, reverse edges, persistence, picker and narrow layout. Upload HTTP stubbed; NRC writes real.");
} finally { await browser.close(); }
