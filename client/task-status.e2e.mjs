// The status a task register draws is the control that changes it: the flat task
// table and a slice's member table open the shared picker and write the move the
// board writes for a drag, without opening the task.
// Production scripts and CSS, with disposable browser-local fixtures.
// node client/task-status.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: "block" });
const errors = [];
page.on("pageerror", error => errors.push(error.message));
try {
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCAssets && window.NRCViewManager && window.NRCSlices);

  // The fixture is browser-local: two tasks, one slice that carries both, and a
  // socket that records every frame the client writes and answers the slice
  // listing. The task cache is the register's source, so the flat list draws
  // without a server-side query.
  await page.evaluate(() => {
    const encoder = new TextEncoder();
    const bytes = (value) => encoder.encode(value ?? "");
    // Mirrors protocol/tasks.odin serializeTaskSliceList and the unit suite.
    function sliceListFrame({ correlationId, slices }) {
      const names = slices.map((slice) => bytes(slice.name));
      const owners = slices.map((slice) => bytes(slice.owner));
      let size = 2 + 8 + 1 + 2 + 1 + 1 + 8 + 8 + 4 + 4 + 4 + 2 + 4;
      slices.forEach((slice, index) => { size += 2 + names[index].length + 8 + 2 + owners[index].length + 1 + 14 + 16; });
      const buffer = new ArrayBuffer(size);
      const view = new DataView(buffer);
      let offset = 0;
      view.setUint16(offset, 164, false); offset += 2;
      view.setBigUint64(offset, 0n, false); offset += 8;
      view.setUint8(offset, 1); offset += 1;
      view.setUint16(offset, slices.length, false); offset += 2;
      slices.forEach((slice, index) => {
        view.setUint16(offset, names[index].length, false); offset += 2;
        new Uint8Array(buffer, offset, names[index].length).set(names[index]); offset += names[index].length;
        view.setBigUint64(offset, BigInt(slice.sliceId), false); offset += 8;
        view.setUint16(offset, owners[index].length, false); offset += 2;
        new Uint8Array(buffer, offset, owners[index].length).set(owners[index]); offset += owners[index].length;
        view.setUint8(offset, slice.flags ?? 0); offset += 1;
        view.setUint16(offset, slice.backlog ?? 0, false); offset += 2;
        view.setUint16(offset, slice.todo ?? 0, false); offset += 2;
        view.setUint16(offset, slice.inProgress ?? 0, false); offset += 2;
        view.setUint16(offset, slice.done ?? 0, false); offset += 2;
        view.setUint16(offset, slice.blocked ?? 0, false); offset += 2;
        view.setUint16(offset, slice.notes ?? 0, false); offset += 2;
        view.setUint16(offset, slice.files ?? 0, false); offset += 2;
        view.setBigInt64(offset, 0n, false); offset += 8;
        view.setBigInt64(offset, BigInt(Date.now()) * 1000000n, false); offset += 8;
      });
      view.setUint8(offset, 0); offset += 1;
      view.setUint8(offset, 0); offset += 1;
      view.setBigInt64(offset, 0n, false); offset += 8;
      view.setBigUint64(offset, 0n, false); offset += 8;
      view.setUint32(offset, slices.length, false); offset += 4;
      view.setUint32(offset, 0, false); offset += 4;
      view.setUint32(offset, 0, false); offset += 4;
      view.setUint16(offset, 0, false); offset += 2;
      view.setUint32(offset, correlationId, false); offset += 4;
      if (offset !== size) throw new Error("the fixture frame does not fill its declared size");
      return new DataView(buffer);
    }

    const stamp = BigInt(Date.now()) * 1000000n;
    currentRoomId = 7n;
    currentWorkspaceId = "task-status";
    myNickname = "tester";
    serverReady = true;

    // The server's tasks, separate from the register's cache: a move into a status
    // window the register does not hold takes the task out of that cache, and the
    // server still has it.
    const serverTasks = new Map([
      [1n, { id: 1n, convId: 0n, title: "Re-status from the register", status: 1, orderIndex: 3, priority: 128, color: 0, createdAt: stamp, attachments: [], assignee: "tester", project: "NRC" }],
      [2n, { id: 2n, convId: 0n, title: "Member of the slice", status: 3, orderIndex: 1, priority: 96, color: 0, createdAt: stamp + 1n, attachments: [], assignee: "tester", project: "NRC" }],
    ]);
    const assets = new Map([
      [5n, { assetId: 5n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Alpha" }) }],
    ]);
    // The register's cache holds its own copies: a surface reads the copy it has,
    // and only a task the register does not hold is fetched from the fixture's
    // server, exactly as the real cache and the real server behave. A move
    // therefore reaches the member table through the register's confirmation and
    // not through a shared object.
    roomTasks.set(0n, new Map([...serverTasks].map(([id, task]) => [id, { ...task }])));
    NRCAssets.roomAssets.set(0n, assets);

    const edges = [
      { edgeId: 1n, relation: 7, sourceType: 2, sourceId: 1n, targetType: 1, targetId: 5n },
      { edgeId: 2n, relation: 7, sourceType: 2, sourceId: 2n, targetType: 1, targetId: 5n },
    ];
    NRCEdges.getEdgesForEntity = (roomId, targetType, targetId) => edges.filter((edge) =>
      (edge.sourceType === targetType && edge.sourceId === targetId) ||
      (edge.targetType === targetType && edge.targetId === targetId));
    NRCEdges.requestEdgePage = () => Promise.resolve({});
    NRCTasks.requestTask = (convId, id, { onSuccess, onError } = {}) => {
      const task = roomTasks.get(0n)?.get(id) ?? serverTasks.get(id);
      if (task) onSuccess?.({ task }); else onError?.({ message: "task not found" });
      return 1;
    };
    const requestAsset = NRCAssets.requestAsset;
    NRCAssets.requestAsset = (convId, assetId, options) => {
      const asset = assets.get(assetId);
      if (asset) { options?.onSuccess?.({ asset }); return 1; }
      return requestAsset(convId, assetId, options);
    };

    // The fixture has no server-side query: the flat register draws the task
    // cache, and a mutation does not ask a server that is not there.
    window.NRCTaskQuery = {
      getState: () => ({ mode: "idle", roomId: null, tasks: new Map(), hasMore: false, total: 0 }),
      getProjects: () => [],
      update() {}, afterMutation() {}, disconnect() {}, handlePage() {},
    };

    // The register holds every status, so a task that changes status stays in
    // the cache the list draws from instead of leaving its loaded window, and
    // ALL is the filter so the moved row stays on screen.
    getTaskPageState(0n, ALL_TASK_MASK).loaded = true;
    TaskViewState.filters.status = null;

    // The register's own listing is answered inline; everything else the client
    // writes is recorded so a case can read the frame that left it.
    window.__frames = [];
    const send = ws.send.bind(ws);
    ws.send = (buffer) => {
      window.__frames.push(buffer);
      window.__lastSend = Date.now();
      const view = new DataView(buffer);
      if (view.getUint16(0, false) !== 56) return;
      const correlationId = view.getUint32(view.byteLength - 4, false);
      window.NRCSlices.handleSliceList(sliceListFrame({
        correlationId,
        slices: [{ name: "Alpha", sliceId: 5n, owner: "tester",
          todo: [...serverTasks.values()].filter(task => task.status === 1).length,
          inProgress: [...serverTasks.values()].filter(task => task.status === 2).length,
          done: [...serverTasks.values()].filter(task => task.status === 3).length }],
      }));
    };
    window.__sliceListings = () => window.__frames
      .filter((buffer) => new DataView(buffer).getUint16(0, false) === 56).length;
    window.__move = () => {
      const frame = window.__frames.filter((buffer) => new DataView(buffer).getUint16(0, false) === 23).pop();
      if (!frame) return null;
      const view = new DataView(frame);
      return {
        taskId: view.getBigUint64(10, false).toString(),
        status: view.getUint8(18),
        flags: view.getUint8(19),
        orderIndex: view.getUint16(20, false),
      };
    };
    // S_TaskMoved, the acknowledgement the server sends back to the mover. The
    // fixture applies what it acknowledges, like the server does.
    window.__ackMove = ({ taskId, status, orderIndex }) => {
      const stored = serverTasks.get(BigInt(taskId));
      if (stored) { stored.status = status; stored.orderIndex = orderIndex; }
      const completedBy = bytes(status === 3 ? "tester" : "");
      const buffer = new ArrayBuffer(2 + 8 + 8 + 1 + 2 + 8 + 2 + completedBy.length + 4);
      const view = new DataView(buffer);
      let offset = 0;
      view.setUint16(offset, 133, false); offset += 2;
      view.setBigUint64(offset, BigInt(taskId), false); offset += 8;
      view.setBigUint64(offset, 0n, false); offset += 8;
      view.setUint8(offset, status); offset += 1;
      view.setUint16(offset, orderIndex, false); offset += 2;
      view.setBigInt64(offset, status === 3 ? stamp : 0n, false); offset += 8;
      view.setUint16(offset, completedBy.length, false); offset += 2;
      new Uint8Array(buffer, offset, completedBy.length).set(completedBy); offset += completedBy.length;
      view.setUint32(offset, 0, false);
      window.NRCTasks.handleTaskMoved(view);
    };

    // The flat register draws the task cache while the server-side query is
    // idle, which is the fixture's whole listing.
    showKanban();
    TaskViewState.grouping = "flat";
    renderCurrentTaskView();
  });
  await page.waitForSelector('#taskListBody tr[data-task-id="1"]');

  // The client debounces its own refreshes — the register's invalidation, the
  // query — so a case waits for the fixture to go quiet before it drives the
  // next surface: a redraw takes an open menu with it.
  const settled = () => page.waitForFunction(() => Date.now() - (window.__lastSend ?? 0) > 300);

  // --- the flat register ---------------------------------------------------
  const row = page.locator('#taskListBody tr[data-task-id="1"]');
  const token = row.locator(".col-status .task-row-status");
  assert.equal(await token.evaluate((element) => element.tagName), "BUTTON", "the token is a control");
  assert.equal(await token.getAttribute("aria-haspopup"), "listbox");
  assert.equal(await token.getAttribute("aria-expanded"), "false");
  assert.equal(await token.textContent(), "TODO");
  assert.equal(await token.evaluate((element) => getComputedStyle(element).color), "rgb(201, 138, 0)", "the token keeps the status ramp");

  await token.click();
  const menu = page.locator("#portal-container .custom-select__dropdown");
  await menu.waitFor({ state: "visible" });
  assert.equal(await token.getAttribute("aria-expanded"), "true");
  assert.deepEqual(await menu.locator(".custom-select__option").allTextContents(),
    ["BACKLOG", "TODO", "IN PROGRESS", "DONE"], "the menu offers the four statuses");
  assert.equal(await menu.locator(".custom-select__option--selected").textContent(), "TODO", "the menu marks the status the row holds");
  assert.equal(await page.evaluate(() => window.NRCTasks.selectedTaskId()), null, "the press did not open the task");

  // A slice refresh redraws its own tables; the flat register's menu is not its
  // business and stays open.
  await page.evaluate(() => window.NRCSlices.render());
  assert.equal(await menu.isVisible(), true, "another register's redraw leaves the menu alone");

  await menu.locator(".custom-select__option", { hasText: "DONE" }).click();
  await menu.waitFor({ state: "detached" });
  // The register holds one page of the target column, so it carries the append
  // flag and leaves the position to the server: the fixture answers 2, after task 2.
  assert.deepEqual(await page.evaluate(() => window.__move()), { taskId: "1", status: 3, flags: 0x01, orderIndex: 0 },
    "the register asks the server for the end of the target column");
  assert.equal(await page.evaluate(() => window.NRCTasks.selectedTaskId()), null, "the change never opened the task");

  await page.evaluate(() => window.__ackMove({ taskId: 1, status: 3, orderIndex: 2 }));
  await page.waitForFunction(() => document.querySelector('#taskListBody tr[data-task-id="1"] .task-row-status')?.textContent === "DONE");
  const moved = row.locator(".col-status .task-row-status");
  assert.equal(await moved.getAttribute("aria-label"), "Status DONE — change status");
  assert.equal(await moved.evaluate((element) => getComputedStyle(element).color), "rgb(0, 166, 81)", "the token follows the status it now holds");

  // --- a slice's member table ---------------------------------------------
  // The move also invalidates the slice register, whose refresh rebuilds the
  // record: that redraw lands before the member table is driven.
  await settled();
  await page.evaluate(() => { setTaskGrouping("slices"); });
  await page.waitForSelector('#sliceRecord .slice-member[data-member-task="1"]');
  const memberToken = page.locator('#sliceRecord .slice-member[data-member-task="1"] [data-member-status]');
  assert.equal(await memberToken.textContent(), "DONE");
  assert.equal(await memberToken.getAttribute("aria-haspopup"), "listbox");

  // The register holds no page of the target status window, so the move takes the
  // task out of the partial cache: the member table keeps its own snapshot, and
  // the confirmation is what the row reads.
  await page.evaluate(() => { getTaskPageState(0n, ALL_TASK_MASK).loaded = false; });
  await memberToken.click();
  await menu.waitFor({ state: "visible" });
  assert.equal(await menu.locator(".custom-select__option--selected").textContent(), "DONE", "the member menu opens on the member's status");
  assert.equal(await page.evaluate(() => window.NRCInspector?.hasEntity?.() ?? false), false, "the token did not open the member");

  await menu.locator(".custom-select__option", { hasText: "IN PROGRESS" }).click();
  await menu.waitFor({ state: "detached" });
  assert.deepEqual(await page.evaluate(() => window.__move()), { taskId: "1", status: 2, flags: 0x01, orderIndex: 0 },
    "a member is re-statused from its own row");
  // The write alone changes nothing: the row still holds the status the server has
  // not confirmed yet.
  assert.equal(await memberToken.textContent(), "DONE", "the row waits for the confirmation");

  await page.evaluate(() => {
    window.__retainedSections = [document.getElementById("sliceOwner"), document.getElementById("sliceOutcome"),
      ...[...document.querySelectorAll("#sliceRecord .slice-section")].slice(-2)];
    document.getElementById("sliceOutcome").value = "Unsaved outcome";
    // Hold the background detail read across a browser paint.
    NRCEdges.requestEdgePage = () => new Promise(resolve => { window.__finishMemberRefresh = resolve; });
  });
  const afterAck = await page.evaluate(() => {
    window.__ackMove({ taskId: 1, status: 2, orderIndex: 0 });
    return {
      token: document.querySelector('#sliceRecord .slice-member[data-member-task="1"] [data-member-status]')?.textContent ?? null,
      cached: window.NRCTasks.roomTasks.get(0n)?.has(1n) ?? null,
    };
  });
  assert.equal(afterAck.token, "IN PROGRESS", "the member token follows the confirmation without waiting for a refresh");
  assert.equal(afterAck.cached, false, "the move left the register's partial cache");
  await page.waitForFunction(() => document.querySelector('#sliceRecord .slice-member[data-member-task="1"] [data-member-status]')?.textContent === "IN PROGRESS");
  assert.equal(await memberToken.getAttribute("aria-label"), "Status IN PROGRESS — change status");
  assert.equal(await page.evaluate(() => window.NRCInspector?.hasEntity?.() ?? false), false, "the change never opened the member");
  await page.waitForFunction(() => Boolean(window.__finishMemberRefresh));
  assert.deepEqual(await page.evaluate(() => ({
    retained: window.__retainedSections.every(element => element.isConnected),
    inert: document.getElementById("sliceRecord").inert,
    draft: document.getElementById("sliceOutcome").value,
    done: [...document.querySelectorAll(".slice-facts > div")].find(element => element.querySelector("dt").textContent === "DONE").querySelector("dd").textContent,
  })), { retained: true, inert: false, draft: "Unsaved outcome", done: "1" },
  "confirmation and counter refresh retain unrelated sections and keep the record interactive");
  await page.evaluate(() => {
    window.__confirmedToken = document.querySelector('[data-member-status="1"]');
    NRCEdges.requestEdgePage = () => Promise.resolve({});
    window.__finishMemberRefresh({});
  });
  await page.waitForFunction(() => document.getElementById("sliceRecord").getAttribute("aria-busy") === "false");
  assert.equal(await page.evaluate(() => window.__confirmedToken.isConnected &&
    window.__retainedSections.every(element => element.isConnected)), true,
  "the completed background read does not replace unchanged member rows or unrelated sections");

  // A changed member table restores focus to the token the reader was on.
  await memberToken.focus();
  await page.evaluate(() => window.NRCSlices.onTaskMoved(2n, 2, 0));
  assert.equal(await memberToken.evaluate((element) => document.activeElement === element), true,
    "a rebuilt member table gives the focused token its place back");

  await settled();
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["light", "dark"]) {
    await page.evaluate((value) => { document.documentElement.dataset.theme = value; }, theme);
    await page.evaluate(() => { setTaskGrouping("slices"); });
    await page.waitForSelector('#sliceRecord .slice-member[data-member-task="1"] [data-member-status]');
    await memberToken.click();
    await menu.waitFor({ state: "visible" });
    await page.screenshot({ path: `.amp/in/artifacts/task-status-slices-${theme}.png` });
    await page.keyboard.press("Escape");
    await menu.waitFor({ state: "detached" });
    assert.equal(await memberToken.getAttribute("aria-expanded"), "false", "Escape leaves the token closed");
    assert.equal(await memberToken.evaluate((element) => document.activeElement === element), true, "Escape gives the token its focus back");

    // The register draws the tasks it holds: the moved task left its partial cache
    // when it entered a status window the register does not have, so the drawn row
    // here is the other task.
    await page.evaluate(() => { setTaskGrouping("flat"); });
    await page.waitForSelector('#taskListBody tr[data-task-id="2"]');
    await page.locator('#taskListBody tr[data-task-id="2"] .task-row-status').click();
    await menu.waitFor({ state: "visible" });
    await page.screenshot({ path: `.amp/in/artifacts/task-status-register-${theme}.png` });
    await page.keyboard.press("Escape");
    await menu.waitFor({ state: "detached" });
  }

  // --- a phone: the same token in the compact compositions ------------------
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => { setTaskGrouping("slices"); });
  // The record is a drill-in on a phone, so the register opens it first.
  await page.locator('#sliceRegisterList [data-slice-name="Alpha"]').click();
  await page.waitForSelector('#sliceRecord .slice-member[data-member-task="1"] [data-member-status]');
  const phoneMemberToken = page.locator('#sliceRecord .slice-member[data-member-task="1"] [data-member-status]');
  assert.equal(await phoneMemberToken.isVisible(), true, "the member token stays on the phone");
  const memberRow = page.locator('#sliceRecord .slice-member[data-member-task="1"]');
  const fits = await phoneMemberToken.evaluate((element) => {
    const token = element.getBoundingClientRect();
    const row = element.closest(".slice-member").getBoundingClientRect();
    return token.left >= row.left - 0.5 && token.right <= row.right + 0.5;
  });
  assert.equal(fits, true, "the member token stays inside its row");
  await phoneMemberToken.click();
  await menu.waitFor({ state: "visible" });
  await page.screenshot({ path: ".amp/in/artifacts/task-status-phone-slices.png" });
  await page.keyboard.press("Escape");
  await menu.waitFor({ state: "detached" });

  await page.evaluate(() => { setTaskGrouping("flat"); });
  await page.waitForSelector('#taskListBody tr[data-task-id="2"]');
  const phoneToken = page.locator('#taskListBody tr[data-task-id="2"] .task-row-status');
  assert.equal(await phoneToken.isVisible(), true, "the register token stays on the phone");
  await phoneToken.click();
  await menu.waitFor({ state: "visible" });
  await page.screenshot({ path: ".amp/in/artifacts/task-status-phone-register.png" });
  await page.keyboard.press("Escape");
  await menu.waitFor({ state: "detached" });

  assert.deepEqual(errors, []);
  console.log("task status e2e: ok");
} finally {
  await browser.close();
}
