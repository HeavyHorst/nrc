// Production client, disposable browser-local records and controllable acknowledgements.
// node client/inline-edit.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${pathname === "/" ? "/index.html" : pathname}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCNotes && window.NRCInspector);
  await page.evaluate(() => {
    currentWorkspaceId = "inline-test";
    currentRoomId = 7n;
    myNickname = "rene";
    serverReady = true;
    const stamp = 1789990000000000000n;
    window.sampleTask = { convId: 0n, id: 41n, title: "Review customer handover", description: "Keep the operational checklist up to date.", status: 1, priority: 128, color: 1, project: "NRC", assignee: "rene", createdBy: "anna", createdAt: stamp, updatedAt: stamp, dueAt: 0n, blockedBy: 0n, attachments: [], orderIndex: 0 };
    roomTasks.set(0n, new Map([[41n, sampleTask], [42n, { ...sampleTask, id: 42n, title: "Prepare release notes", priority: 64 }]]));
    window.sampleNote = { convId: 0n, assetId: 61n, assetType: 5, owner: "anna", createdAt: stamp, updatedAt: stamp, preview: JSON.stringify({ title: "Handover notes", project: "NRC", tags: ["ops"], teaser: "Keep me", format: "markdown", future: 9 }), payload: "# Handover\n\nDocument the verification steps.", attachments: [] };
    NRCAssets.roomAssets.set(0n, new Map([[61n, sampleNote]]));
    NRCEdges.requestEdgePage = () => Promise.resolve({ edges: [], hasMore: false });
    NRCEdges.getEdgesForEntity = () => [];
    NRCAssets.requestAsset = (room, id, options) => { options?.onSuccess?.({ asset: NRCAssets.roomAssets.get(0n).get(id) }); return 1; };
    NRCTasks.requestTask = (room, id, options) => { options?.onSuccess?.({ task: roomTasks.get(0n).get(id) }); return 1; };
    window.NRCTaskQuery = {
      getState: () => ({ mode: "idle", roomId: null, tasks: new Map(), hasMore: false, total: 0 }),
      getProjects: () => [], update() {}, afterMutation() {}, disconnect() {}, handlePage() {},
    };
    getTaskPageState(0n, ALL_TASK_MASK).loaded = true;
    TaskViewState.filters.status = null;
    NRCTaskSearch.isActive = () => false;
    NRCAssets.sendListNoteProjects = () => handleNoteChanged({ convId: 0n, projects: ["NRC", parseNotePreview(serverNote.preview).project] }, "project_list");
    NRCAssets.sendListNoteTags = () => handleNoteChanged({ convId: 0n, tags: parseNotePreview(serverNote.preview).tags }, "tag_list");
    window.taskWrites = [];
    sendUpdateTask = (...args) => { taskWrites.push(args); return 11; };
    window.ackTask = (error = null) => {
      const args = taskWrites.at(-1);
      if (error) { args.at(-1).onError({ message: error }); return; }
      const next = { ...roomTasks.get(0n).get(args[1]) };
      for (const [field, i] of [["title", 2], ["description", 3], ["assignee", 5], ["externalRef", 8], ["project", 12]]) if (args[i]) next[field] = args[i] === "\x00" ? "" : args[i];
      if (args[6] !== 255) next.priority = args[6];
      if (args[7] !== 255) next.color = args[7];
      if (args[11] !== null) next.attachments = args[11];
      roomTasks.get(0n).set(next.id, next);
      args.at(-1).onSuccess({ task: next });
      const original = parseTask;
      parseTask = () => ({ task: next, newOffset: 2 });
      handleTaskUpdated(new DataView(new ArrayBuffer(6)));
      parseTask = original;
    };
    window.noteWrites = [];
    window.serverNote = { ...sampleNote };
    window.noteReads = [];
    window.holdNoteReads = false;
    NRCAssets.sendGetAsset = (_room, _id, callbacks) => {
      const deliver = () => {
        const previous = NRCAssets.roomAssets.get(0n).get(61n);
        const asset = { ...serverNote };
        NRCAssets.roomAssets.get(0n).set(61n, asset);
        handleNoteChanged(asset, "fetched", previous);
        callbacks.onSuccess({ asset });
      };
      if (holdNoteReads) noteReads.push(deliver); else queueMicrotask(deliver);
      return 24;
    };
    NRCTransactions.sendAssetMetadataPatch = (...args) => { noteWrites.push(args); return 22; };
    window.ackNote = (error = null) => {
      const [asset, preview, payload, callbacks] = noteWrites.at(-1);
      if (error) { callbacks.onError({ message: error }); return; }
      if (asset.updatedAt !== serverNote.updatedAt) { callbacks.onError({ message: "version conflict" }); return; }
      serverNote = { ...serverNote, preview: preview ?? serverNote.preview, payload: payload ?? serverNote.payload, updatedAt: serverNote.updatedAt + 1n };
      callbacks.onSuccess({ assetId: serverNote.assetId });
    };
    showKanban();
    TaskViewState.grouping = "flat";
    renderCurrentTaskView();
  });
  const field = (scope, name) => page.locator(scope).locator(`nrc-inline-field[data-control$="-${name}"] button`);
  const editor = page.locator(".inline-field-editor");
  const checkResourceActions = async () => {
    for (const resource of ["links", "files"]) {
      const block = page.locator(`.agenda-content [data-resource="${resource}"]`);
      if (await block.getAttribute("data-resource-open") !== "true") await block.locator("[data-resource-toggle]").click();
      await page.locator('.agenda-content').getByRole("button", { name: "+ LINK", exact: true }).click({ trial: true });
      await page.getByRole("button", { name: "Edit ATTACHMENTS: empty" }).click({ trial: true });
    }
    for (const control of [page.locator('.agenda-content').getByRole("button", { name: "+ LINK", exact: true }), page.getByRole("button", { name: "Edit ATTACHMENTS: empty" })]) {
      await control.hover();
      assert.deepEqual(await control.evaluate(el => {
        const style = getComputedStyle(el);
        return [style.outlineStyle, style.outlineWidth, style.outlineOffset];
      }), ['solid', '1px', '2px'], 'both resource actions expose the same hover outline');
      await page.mouse.move(0, 0);
      await page.keyboard.press('Tab');
      await control.focus();
      assert.equal(await control.evaluate(el => el.matches(':focus-visible') && getComputedStyle(el).outlineWidth === '1px'), true, 'keyboard focus uses the shared outline');
    }
  };
  const row = '#taskListBody tr[data-task-id="41"]';
  await field(row, "priority").click();
  await editor.locator("input").fill("203");
  await editor.locator("input").press("Enter");
  assert.equal(await editor.locator('[role="status"]').textContent(), "SAVING");
  assert.equal(await page.evaluate(() => NRCInspector.hasEntity()), false);
  await page.evaluate(() => ackTask("CONNECTION LOST — RETRY"));
  assert.match(await editor.textContent(), /CONNECTION LOST/);
  assert.equal(await editor.locator("input").inputValue(), "203");
  await editor.getByRole("button", { name: "SAVE", exact: true }).click();
  await page.evaluate(() => ackTask());
  await editor.waitFor({ state: "detached" });
  assert.equal(await field(row, "priority").textContent(), "203");
  assert.equal(await field(row, "priority").evaluate(element => element === document.activeElement), true);
  await field(row, "project").click();
  await editor.locator("input").fill("cancel me");
  await page.keyboard.press("Escape");
  assert.equal(await field(row, "project").textContent(), "NRC");
  assert.equal(await page.evaluate(() => taskWrites.length), 2);

  // Refreshing the virtual table must not take the text draft with it.
  await field(row, "assignee").click();
  await editor.locator("input").fill("mika");
  await page.evaluate(() => { taskListDirty = true; renderCurrentTaskView(); });
  assert.equal(await editor.locator("input").inputValue(), "mika");
  await page.keyboard.press("Escape");
  assert.equal(await field(row, "assignee").evaluate(element => element === document.activeElement), true);
  await page.locator(`${row} .task-row-open`).click();
  await page.waitForSelector("#taskDetailToggleFocus");
  await page.locator("#taskDetailToggleFocus").click();
  await page.locator("#taskDetailDesc").fill("Unsaved description\nwith whitespace  ");
  await field(".agenda-content", "category").click();
  await editor.locator("select").selectOption("2");
  assert.equal(await page.evaluate(() => taskWrites.at(-1)[7]), 2);
  await page.evaluate(() => ackTask());
  await editor.waitFor({ state: "detached" });
  await field(".agenda-content", "project").click();
  await editor.locator("input").fill("Release");
  await editor.locator("input").press("Enter");
  await page.evaluate(() => ackTask());
  await editor.waitFor({ state: "detached" });
  assert.equal(await page.locator("#taskDetailDesc").inputValue(), "Unsaved description\nwith whitespace  ");
  await page.locator("#taskDetailSave").click();
  assert.deepEqual(await page.evaluate(() => {
    const args = taskWrites.at(-1);
    return [args[2], args[3], args[4], args[5], args[6], args[7], args[8], String(args[9]), String(args[10]), args[11], args[12]];
  }), ["", "Unsaved description\nwith whitespace  ", 255, "", 255, 255, "", "0", "0", null, ""]);
  await page.evaluate(() => ackTask());
  await page.locator('#taskDetailToggleFocus[data-inspector-command="v"]').click();
  assert.match(await page.locator(".task-detail-doc-body").textContent(), /Unsaved description/);

  await field(".agenda-content", "externalRef").click();
  await editor.locator("input").fill("https://example.com/review");
  await editor.locator("input").press("Enter");
  await page.evaluate(() => ackTask());
  await editor.waitFor({ state: "detached" });
  await field(".agenda-content", "externalRef").click();
  await page.evaluate(() => { window.open = (...args) => { window.openedReference = args; }; });
  await editor.getByRole("button", { name: "OPEN", exact: true }).click();
  assert.deepEqual(await page.evaluate(() => openedReference), ["https://example.com/review", "_blank", "noopener,noreferrer"]);
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  await page.screenshot({ path: ".amp/in/artifacts/inline-task-reference.png", clip: { x: 1140, y: 0, width: 460, height: 780 } });
  await page.keyboard.press("Escape");
  await checkResourceActions();

  await page.evaluate(async () => {
    await NRCInspector.close();
    const state = getNotesPaginationState(0n);
    state.initialized = true; state.loading = false; state.hasMore = false;
    showNotesView();
    notesProjectFilter = "NRC";
    document.getElementById("notesProjectFilter").value = "NRC";
    renderNotesView();
  });
  const noteRow = '.note-card[data-note-id="61"]';
  await page.waitForSelector(noteRow);
  assert.match(await page.locator(`${noteRow} .note-title`).textContent(), /Handover notes/);
  await field(noteRow, "project").click();
  await editor.locator("input").fill("Operations");
  await editor.locator("input").press("Enter");
  assert.deepEqual(await page.evaluate(() => { const args = noteWrites.at(-1); return [JSON.parse(args[1]).project, JSON.parse(args[1]).teaser, JSON.parse(args[1]).future, args[2]]; }), ["Operations", "Keep me", 9, null]);
  await page.evaluate(() => ackNote());
  await editor.waitFor({ state: "detached" });
  assert.equal(await page.locator(noteRow).count(), 0, "project mutation reapplies the active filter");
  assert.ok((await page.locator("#notesProjectFilter option").allTextContents()).includes("Operations"), "new project is available after a local mutation");
  await page.evaluate(() => { notesProjectFilter = null; document.getElementById("notesProjectFilter").value = ""; renderNotesView(); });
  await page.locator(`${noteRow} .task-row-open`).click();
  await page.waitForSelector("#noteDetailEdit");
  await page.locator("#noteDetailEdit").click();
  await page.locator("#noteDetailContent").fill("A content draft\n");
  await page.evaluate(() => {
    window.attachmentWrites = [];
    NRCAssets.sendUpdateAsset = (...args) => { attachmentWrites.push(args); return 23; };
  });
  await page.locator('[data-resource="attachments"] [data-resource-toggle]').click();
  await page.getByRole("button", { name: "Edit ATTACHMENTS: empty" }).click();
  await page.getByRole("button", { name: "DIRECT ATTACHMENT", exact: true }).click();
  const attachments = page.locator('[data-attachment-editor]');
  assert.equal(await attachments.locator('input[type="file"]').evaluate(input => input.multiple), false, "picker matches the single-file upload handler");
  await attachments.getByRole("button", { name: "SAVE ATTACHMENTS", exact: true }).click();
  assert.deepEqual(await page.evaluate(() => [attachmentWrites.at(-1)[3], attachmentWrites.at(-1)[7]]), ["# Handover\n\nDocument the verification steps.", []], "attachment save never includes an unsaved content draft");
  await page.evaluate(() => attachmentWrites.at(-1)[6].onError({ message: "ATTACHMENT SAVE FAILED" }));
  assert.match(await attachments.textContent(), /ATTACHMENT SAVE FAILED/);
  await attachments.getByRole("button", { name: "SAVE ATTACHMENTS", exact: true }).click();
  await page.evaluate(() => attachmentWrites.at(-1)[6].onSuccess({}));
  await attachments.waitFor({ state: "detached" });
  assert.equal(await page.locator("#noteDetailContent").inputValue(), "A content draft\n");
  await field(".agenda-content", "tags").click();
  await editor.locator("input").fill("ops, release");
  await editor.locator("input").press("Enter");
  await page.evaluate(() => ackNote());
  await editor.waitFor({ state: "detached" });
  assert.equal(await page.locator("#noteDetailContent").inputValue(), "A content draft\n");
  await page.locator("#noteDetailSave").click();
  assert.deepEqual(await page.evaluate(() => { const args = noteWrites.at(-1); return [JSON.parse(args[1]).project, JSON.parse(args[1]).tags, args[2]]; }), ["Operations", ["ops", "release"], "A content draft\n"]);
  await page.getByRole("button", { name: "Edit ATTACHMENTS: empty" }).click();
  await page.getByRole("button", { name: "DIRECT ATTACHMENT", exact: true }).click();
  await attachments.getByRole("button", { name: "SAVE ATTACHMENTS", exact: true }).click();
  assert.match(await attachments.textContent(), /NOTE SAVE IN PROGRESS/);
  assert.equal(await page.evaluate(() => attachmentWrites.length), 2, "pending content blocks full attachment writes");
  await page.evaluate(() => { holdNoteReads = true; });
  await page.evaluate(() => ackNote());
  await page.waitForFunction(() => noteReads.length === 1);
  assert.equal(await page.locator('[data-save-state]').getAttribute("data-save-state"), "SAVING");
  await attachments.getByRole("button", { name: "SAVE ATTACHMENTS", exact: true }).click();
  assert.match(await attachments.textContent(), /NOTE SAVE IN PROGRESS/);
  await page.evaluate(() => { holdNoteReads = false; noteReads.shift()(); });
  await page.waitForFunction(() => document.querySelector('[data-save-state]')?.dataset.saveState === "SAVED");
  await attachments.getByRole("button", { name: "SAVE ATTACHMENTS", exact: true }).click();
  assert.equal(await page.evaluate(() => attachmentWrites.at(-1)[3]), "A content draft\n", "attachment retry reads committed content");
  await page.evaluate(() => attachmentWrites.at(-1)[6].onSuccess({}));
  await attachments.waitFor({ state: "detached" });
  await page.locator("#noteDetailToggleView").click();
  assert.match(await page.locator("#notePreviewBody").textContent(), /A content draft/);
  assert.equal(await page.locator('[data-resource="attachments"]').getAttribute("data-resource-open"), "true", "attachment register stays open across modes");
  await page.getByRole("button", { name: "Edit ATTACHMENTS: empty" }).click();
  await page.getByRole("button", { name: "DIRECT ATTACHMENT", exact: true }).click();
  await page.waitForSelector("[data-attachment-editor]");
  assert.equal(await page.locator("#noteDetailContent").count(), 0, "attachments have their own editor");
  await page.locator('[data-attachment-editor]').getByRole("button", { name: "CANCEL", exact: true }).click();
  await checkResourceActions();

  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await page.locator('.agenda-content [data-resource="links"] [data-resource-toggle]').scrollIntoViewIfNeeded();
    await page.locator(".agenda-panel").screenshot({ path: `.amp/in/artifacts/inline-resources-${theme}.png` });
    await page.locator("#noteDetailEdit").click();
    await field(".agenda-content", "project").click();
    await page.screenshot({ path: `.amp/in/artifacts/inline-note-${theme}.png` });
    await page.keyboard.press("Escape");
    await page.locator("#noteDetailToggleView").click();
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(async () => { await NRCInspector.close(); await NRCInspector.openEntity({ roomId: 0n, type: "note", id: 61n }); });
  await page.locator("#noteDetailEdit").click();
  assert.ok(await field(".agenda-content", "project").isVisible(), "document properties remain visible on narrow screens");
  await field(".agenda-content", "project").click();
  assert.ok(await editor.evaluate(element => { const r = element.getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth && r.bottom <= innerHeight; }));
  assert.equal(await editor.locator("input").evaluate(element => getComputedStyle(element).fontSize), "16px");
  await page.screenshot({ path: ".amp/in/artifacts/inline-note-narrow.png" });
  await page.keyboard.press("Escape");
  assert.deepEqual(errors, []);
  console.log("inline edit e2e: ok — ACK/error/retry, cancel, redraw, partial saves, draft preservation, resources, themes, narrow viewport");
} finally {
  await browser.close();
}
