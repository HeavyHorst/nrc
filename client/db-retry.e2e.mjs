// Run only against the disposable authenticated test/customer-workspace-dev.mjs fixture.
import assert from "node:assert/strict";
import { chromium } from "playwright";
const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url || !["localhost", "127.0.0.1"].includes(new URL(url).hostname)) throw new Error("Use a disposable local fixture");
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ serviceWorkers: "block" });
  page.on("pageerror", error => console.error(error));
  await page.goto(`${url}/#workspace=overload-${Date.now()}`);
  await page.waitForFunction(() => serverReady);
  const result = await page.evaluate(async () => {
    const refusals = [], frames = [], closes = [], sends = new Map();
    ws.addEventListener("close", event => closes.push([event.code, event.reason]));
    const send = ws.send.bind(ws);
    ws.send = packet => {
      const view = new DataView(packet);
      if (view.getUint16(0) === 20) {
        const id = view.getUint32(view.byteLength - 6);
        sends.set(id, (sends.get(id) || 0) + 1);
      }
      send(packet);
    };
    ws.addEventListener("message", async event => {
      const view = new DataView(event.data instanceof ArrayBuffer ? event.data : await event.data.arrayBuffer());
      frames.push(view.getUint16(0));
      if ([104,134].includes(view.getUint16(0))) {
        const response = NRCFrames.decodeServerFrame(view);
        if (response.errorMsg || response.error) refusals.push(response.errorMsg || response.error);
      }
    });
    const tasks = await Promise.race([new Promise((_, reject) => setTimeout(() => reject(new Error(`Timeout: ${JSON.stringify({refusals, frames, closes, sends:[...sends], pending:[...pendingTaskRpcs.keys()]})}`)), 10000)), Promise.all(Array.from({ length: 12 }, (_, i) => new Promise((resolve, reject) => {
      NRCTasks.sendCreateTask(0n, `Overload task ${i}`, "synthetic", 1, 0, "", 0n, [], 1, 0, "", { onSuccess: resolve, onError: error => reject(new Error(`Task ${i}: ${error?.message}; refusals=${JSON.stringify(refusals)}`)) });
    })))]);
    const ids = tasks.map(result => result.task.id);
    const stored = await NRCTasks.requestTasksByIds(0n, ids);
    return { refusals, attempts: [...sends.values()], unique: new Set(ids).size,
      titles: stored.map(task => task.title).sort(),
      cached: [...roomTasks.get(0n).values()].filter(task => task.title.startsWith("Overload task ")).length };
  });
  assert.ok(result.refusals.includes("db_connection_overloaded"), JSON.stringify(result));
  assert.ok(result.attempts.some(count => count > 1));
  assert.ok(result.attempts.every(count => count <= 4));
  assert.equal(result.unique, 12);
  assert.equal(result.cached, 12);
  assert.deepEqual(result.titles, Array.from({length:12}, (_,i) => `Overload task ${i}`).sort());
  console.log(JSON.stringify(result));
  await page.evaluate(() => {
    const task = [...roomTasks.get(0n).values()].find(task => task.title === "Overload task 0");
    selectTask(task, { fromInspector: true, loadDetail: false });
    showTaskDetailPanel(task, { view: false });
    window.descriptionRetryCheck = { id: task.id, attempts: [] };
    const send = ws.send.bind(ws);
    let refuse = true;
    ws.send = packet => {
      const view = new DataView(packet);
      if (view.getUint16(0) === 21 && view.getBigUint64(10) === task.id) {
        const offset = 20 + view.getUint16(18);
        const description = new TextDecoder().decode(new Uint8Array(packet, offset + 2, view.getUint16(offset)));
        descriptionRetryCheck.attempts.push(description);
        if (refuse) {
          refuse = false;
          // Refuse before sending to the real server, then use the real retry
          // dispatcher and timers. Subsequent writes reach the disposable DB.
          const code = new TextEncoder().encode("db_connection_overloaded");
          const response = new DataView(new ArrayBuffer(10 + code.length));
          response.setUint16(0, 104); response.setUint16(2, 21);
          response.setUint16(4, code.length);
          new Uint8Array(response.buffer, 6, code.length).set(code);
          response.setUint32(6 + code.length, view.getUint32(view.byteLength - 6));
          queueMicrotask(() => handleBinaryMessage(response.buffer));
          return;
        }
      }
      send(packet);
    };
    for (const value of ["A", "B", "C"]) {
      const editor = document.getElementById("taskDetailDesc");
      editor.value = value;
      editor.dispatchEvent(new Event("input", { bubbles: true }));
      document.getElementById("taskDetailSave").click();
    }
    if (descriptionRetryCheck.attempts.join(",") !== "A") throw new Error("Later save overtook the refused save");
  });
  await page.waitForFunction(() => document.querySelector(".detail-save-state")?.dataset.saveState === "SAVED");
  const saved = await page.evaluate(async () => {
    const result = await new Promise((resolve, reject) => NRCTasks.requestTask(0n, descriptionRetryCheck.id,
      { force: true, onSuccess: resolve, onError: reject }));
    return { description: result.task.description, attempts: descriptionRetryCheck.attempts };
  });
  assert.deepEqual(saved, { description: "C", attempts: ["A", "A", "C"] });
  console.log("PASS serialized detail saves: refused A, retried A, persisted C; intermediate B coalesced");
  await page.evaluate(async () => {
    const { task } = await new Promise((resolve, reject) => NRCTasks.sendCreateTask(0n,
      "Description conflict", "- [ ] original", 1, 0, "", 0n, [], 1, 0, "",
      { onSuccess: resolve, onError: reject }));
    window.descriptionConflict = { id: task.id, attempts: 0, refuseNext: true };
    const send = ws.send.bind(ws);
    ws.send = packet => {
      const view = new DataView(packet);
      if (view.getUint16(0) === 21 && view.getBigUint64(10) === task.id) {
        descriptionConflict.attempts++;
        if (descriptionConflict.refuseNext) {
          descriptionConflict.refuseNext = false;
          const code = new TextEncoder().encode("db_connection_overloaded");
          const response = new DataView(new ArrayBuffer(10 + code.length));
          response.setUint16(0, 104); response.setUint16(2, 21);
          response.setUint16(4, code.length);
          new Uint8Array(response.buffer, 6, code.length).set(code);
          response.setUint32(6 + code.length, view.getUint32(view.byteLength - 6));
          queueMicrotask(() => handleBinaryMessage(response.buffer));
          return;
        }
      }
      send(packet);
    };
    selectTask(task, { fromInspector: true, loadDetail: false });
    showTaskDetailPanel(task, { view: false });
    const editor = document.getElementById("taskDetailDesc");
    editor.value = "- [ ] new description";
    editor.dispatchEvent(new Event("input", { bubbles: true }));
    document.getElementById("taskDetailSave").click();
    revertTaskDetail(); // Return to read mode while the submitted save awaits retry.
    const checkbox = document.querySelector(".task-detail-doc-body input[data-nrc-markdown-checkbox]");
    if (!checkbox) throw new Error("Checkbox not rendered");
    checkbox.click();
    if (descriptionConflict.attempts !== 1 || checkbox.checked) throw new Error("Checkbox overtook detail save");
    if (!document.querySelector(".toast")?.textContent.includes("WAIT FOR THE DESCRIPTION SAVE")) throw new Error("Missing blocked-checkbox notice");
  });
  await page.waitForFunction(() => !taskDetailSaves.has(`0:${descriptionConflict.id}`));
  const forward = await page.evaluate(async () => {
    const { task } = await new Promise((resolve, reject) => NRCTasks.requestTask(0n, descriptionConflict.id,
      { force: true, onSuccess: resolve, onError: reject }));
    showTaskDetailPanel(task);
    descriptionConflict.refuseNext = true;
    document.querySelector(".task-detail-doc-body input[data-nrc-markdown-checkbox]").click();
    showTaskDetailPanel(task, { view: false }); // Reopening must not bypass the save guard.
    const editor = document.getElementById("taskDetailDesc");
    editor.value = "would overwrite checkbox";
    editor.dispatchEvent(new Event("input", { bubbles: true }));
    document.getElementById("taskDetailSave").click();
    if (descriptionConflict.attempts !== 3 || editor.value !== "would overwrite checkbox") throw new Error("Detail save overtook checkbox");
    if (!document.querySelector(".toast")?.textContent.includes("WAIT FOR THE CHECKBOX UPDATE TO FINISH BEFORE SAVING")) throw new Error("Missing blocked-save notice");
    return task.description;
  });
  assert.equal(forward, "- [ ] new description");
  await page.waitForFunction(() => !taskMarkdownUpdates.has(`0:${descriptionConflict.id}`));
  const reverse = await page.evaluate(async () => {
    const { task } = await new Promise((resolve, reject) => NRCTasks.requestTask(0n, descriptionConflict.id,
      { force: true, onSuccess: resolve, onError: reject }));
    return { description: task.description, attempts: descriptionConflict.attempts };
  });
  assert.deepEqual(reverse, { description: "- [x] new description", attempts: 4 });
  console.log("PASS detail/checkbox exclusion in both directions, notices visible, final checked description persisted");
} finally { await browser.close(); }
