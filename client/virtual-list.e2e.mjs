// NRC_CLIENT_URL=http://localhost:8000 node client/virtual-list.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 2, serviceWorkers: "block" });
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
const settle = () => page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
try {
  let serverSocket;
  await page.routeWebSocket("**/*", (socket) => {
    serverSocket = socket;
    socket.onMessage(() => {});
  });
  // The default test URL serves production files through Playwright, so CI
  // needs neither a running static server nor an Odin build for this suite.
  await page.route("http://nrc.test/**", async (route) => {
    const pathname = new URL(route.request().url()).pathname;
    const file = new URL(`.${pathname === "/" ? "/index.html" : pathname}`, import.meta.url);
    try { await route.fulfill({ path: fileURLToPath(file) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto(process.env.NRC_CLIENT_URL || "http://nrc.test");
  await page.waitForFunction(() => window.NRCVirtualList && window.NRCNotes && window.NRCViewManager);
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const count of [500, 1000, 2000]) {
    await page.evaluate((count) => {
      currentRoomId = 7n;
      currentWorkspaceId = "virtual-test";
      const notes = new Map(), tasks = new Map();
      for (let i = 1; i <= count; i++) {
        const id = BigInt(i);
        notes.set(id, { assetId: id, convId: 0n, assetType: 5, preview: JSON.stringify({ title: `Note ${i}: operational checklist`, project: "NRC", tags: ["test"] }), owner: "tester", createdAt: 0n, updatedAt: id });
        tasks.set(id, { id, convId: 0n, title: `Task ${i}: verify operational checklist`, status: 1, priority: i % 256, color: 0, createdAt: 0n, attachments: [] });
      }
      NRCAssets.roomAssets.set(0n, notes);
      roomTasks.set(0n, tasks);
      Object.assign(getNotesPaginationState(0n), { initialized: true, loading: false, hasMore: false, totalCount: count });
      invalidateNotesList(0n);
      taskListDirty = true;
    }, count);
    for (const kind of ["notes", "tasks"]) {
      const baseline = await page.evaluate(async (kind) => {
        const virtual = window.NRCVirtualList;
        window.NRCVirtualList = null;
        const start = performance.now();
        if (kind === "notes") showNotesView(); else { setTaskGrouping("flat"); showKanban(); }
        const handlerMs = performance.now() - start;
        await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
        const frameMs = performance.now() - start;
        window.NRCVirtualList = virtual;
        if (kind === "notes") notesListDirty = true; else taskListDirty = true;
        return { handlerMs, frameMs };
      }, kind);
      const result = await page.evaluate(async (kind) => {
        const start = performance.now();
        if (kind === "notes") showNotesView(); else { setTaskGrouping("flat"); showKanban(); }
        const handlerMs = performance.now() - start;
        await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
        const host = document.getElementById(kind === "notes" ? "notesList" : "taskListBody");
        return { handlerMs, frameMs: performance.now() - start, mounted: host.querySelectorAll("[data-virtual-index]").length, total: host.virtualList?.items.length };
      }, kind);
      assert.equal(result.total, count);
      assert.ok(result.mounted > 0 && result.mounted < 100, JSON.stringify(result));
      console.log(JSON.stringify({ count, kind, baseline, virtual: result }));
      await page.evaluate((kind) => {
        const host = document.getElementById(kind === "notes" ? "notesList" : "taskListBody");
        host.virtualList.ensure(host.virtualList.items.length - 1);
      }, kind);
      await settle();
      assert.equal(await page.locator(`[data-virtual-index="${count - 1}"]`).count(), 1);
      // Navigate through an unmounted selection, not just through DOM siblings.
      assert.equal(await page.evaluate((kind) => {
        const host = document.getElementById(kind === "notes" ? "notesList" : "taskListBody");
        const item = host.virtualList.items[200];
        if (kind === "notes") {
          selectedNoteId = item.assetId; selectedNoteConvId = item.convId;
          return selectAdjacentNote(1);
        }
        selectedTaskId = item.id; selectedTaskConvId = item.convId;
        return selectAdjacentTask(1);
      }, kind), true);
      await settle();
      assert.equal(await page.locator(`#${kind === "notes" ? "notesList" : "taskListBody"} [data-virtual-index="201"]`).count(), 1);
      await page.evaluate(() => NRCInspector.close());
      const reused = await page.evaluate((kind) => {
        const host = document.getElementById(kind === "notes" ? "notesList" : "taskListBody");
        const old = host.virtualList;
        NRCViewManager.setActiveView("chat");
        if (kind === "notes") showNotesView(); else { setTaskGrouping("flat"); showKanban(); }
        return old === host.virtualList;
      }, kind);
      assert.equal(reused, true, "view cache keeps its virtual list");
    }
  }
  // A drag source stays mounted while the viewport moves far away.
  await page.evaluate(() => {
    const host = document.getElementById("taskListBody");
    const row = host.virtualList.ensure(0);
    window.dragSource = row;
    row.dispatchEvent(new DragEvent("dragstart", { bubbles: true, dataTransfer: new DataTransfer() }));
    host.virtualList.ensure(800);
  });
  await settle();
  assert.equal(await page.evaluate(() => dragSource.isConnected), true);
  const dragTop = await page.evaluate(() => {
    const scroller = document.getElementById("taskListView");
    const rect = scroller.getBoundingClientRect();
    scroller.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, clientY: rect.bottom - 8, dataTransfer: new DataTransfer() }));
    return scroller.scrollTop;
  });
  await page.waitForFunction((top) => document.getElementById("taskListView").scrollTop > top + 24, dragTop);
  await page.evaluate(() => document.dispatchEvent(new DragEvent("dragend")));
  await page.evaluate(() => {
    const target = document.querySelector('#taskListBody [data-virtual-index="800"]');
    const rect = target.getBoundingClientRect();
    const task = roomTasks.get(draggedRow.convId).get(draggedRow.taskId);
    window.priorityBeforeDrop = task.priority;
    window.droppedTask = task;
    target.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, clientY: rect.top + 1, dataTransfer: new DataTransfer() }));
    dragSource.dispatchEvent(new DragEvent("dragend", { bubbles: true }));
  });
  await settle();
  assert.equal(await page.evaluate(() => droppedTask.priority !== priorityBeforeDrop), true, "offscreen drop updates priority");
  // Native HTML drag must survive window reconciliation, not only synthetic events.
  await page.evaluate(() => document.getElementById("taskListBody").virtualList.ensure(0));
  await settle();
  const sourceBox = await page.locator('#taskListBody [data-virtual-index="0"] .col-id').boundingBox();
  const scrollBox = await page.locator("#taskListView").boundingBox();
  await page.mouse.move(sourceBox.x + 10, sourceBox.y + 10);
  await page.mouse.down();
  await page.mouse.move(sourceBox.x + 10, sourceBox.y + 30, { steps: 5 });
  await page.mouse.move(sourceBox.x + 10, scrollBox.y + scrollBox.height - 12, { steps: 10 });
  await page.waitForFunction(() => draggedRow && document.getElementById("taskListView").scrollTop > 100);
  assert.equal(await page.evaluate(() => draggedRow.element.isConnected), true);
  await page.evaluate(() => {
    window.nativeSource = draggedRow.element;
    window.nativeTask = roomTasks.get(draggedRow.convId).get(draggedRow.taskId);
    window.nativePriority = nativeTask.priority;
    window.nativeList = document.getElementById("taskListBody").virtualList;
    // A live comment on another task must not destroy the source.
    handleCommentChanged({ convId: 0n, parentType: 1, parentId: 2n, owner: myNickname }, "updated");
  });
  assert.equal(await page.evaluate(() => nativeSource.isConnected && nativeList === document.getElementById("taskListBody").virtualList && taskListDirty), true);
  await page.evaluate(() => document.getElementById("taskListBody").virtualList.ensure(810));
  await settle();
  const nativeTarget = await page.locator('#taskListBody [data-virtual-index="800"] .col-id').boundingBox();
  await page.mouse.move(nativeTarget.x + 10, nativeTarget.y + 5, { steps: 5 });
  await page.mouse.up();
  await settle();
  assert.equal(await page.evaluate(() => draggedRow === null && !taskListDirty && document.getElementById("taskListBody").virtualList !== nativeList), true, "native dragend flushes live updates");
  assert.equal(await page.evaluate(() => nativeTask.priority !== nativePriority), true, "native drop commits priority");
  // Expanding a measured overscan row above the viewport keeps the reading anchor.
  const anchor = await page.evaluate(() => {
    const host = document.getElementById("taskListBody");
    host.virtualList.ensure(300);
    return true;
  });
  assert.ok(anchor);
  await settle();
  const anchorTop = await page.evaluate(() => {
    const rows = [...document.querySelectorAll("#taskListBody [data-virtual-index]")];
    const bounds = document.getElementById("taskListView").getBoundingClientRect();
    window.readingRow = rows.find((row) => row.getBoundingClientRect().top > bounds.top + 40);
    const top = readingRow.getBoundingClientRect().top;
    rows[0].style.height = "150px";
    return top;
  });
  await settle();
  await settle();
  assert.ok(Math.abs(await page.evaluate(() => readingRow.getBoundingClientRect().top) - anchorTop) < 2, "height correction preserves reading anchor");
  // Local search invalidates the virtual snapshot, including the empty state.
  await page.evaluate(() => {
    showNotesView();
    searchServiceAvailable = false;
    document.getElementById("notesSearch").value = "Note 1999:";
    renderNotesView();
  });
  assert.equal(await page.locator("#notesList .note-card").count(), 1);
  await page.evaluate(() => {
    document.getElementById("notesSearch").value = "no-such-note";
    renderNotesView();
  });
  assert.match(await page.locator("#notesList").innerText(), /NO NOTES/);
  await page.evaluate(() => {
    document.getElementById("notesSearch").value = "";
    renderNotesView();
    const state = getNotesPaginationState(0n);
    state.hasMore = true;
    // Prevent network I/O while checking boundary navigation intent.
    state.loading = true;
    const last = document.getElementById("notesList").virtualList.items.at(-1);
    selectedNoteId = last.assetId; selectedNoteConvId = last.convId;
    selectAdjacentNote(1);
  });
  assert.equal(await page.evaluate(() => pendingNotePageNavigation.assetId === selectedNoteId), true);
  await page.evaluate(() => {
    pendingNotePageNavigation = null;
    Object.assign(getNotesPaginationState(0n), { hasMore: false, loading: false });
    renderNotesView({ append: true });
  });
  for (const width of [1280, 390]) {
    await page.setViewportSize({ width, height: 720 });
    for (const theme of ["light", "dark"]) {
      await page.evaluate((theme) => document.documentElement.dataset.theme = theme, theme);
      for (const kind of ["notes", "tasks"]) {
        await page.evaluate((kind) => {
          if (kind === "notes") showNotesView(); else { setTaskGrouping("flat"); showKanban(); }
          const host = document.getElementById(kind === "notes" ? "notesList" : "taskListBody");
          host.virtualList.ensure(500);
        }, kind);
        await settle();
        await page.waitForFunction((kind) => {
          const host = document.getElementById(kind === "notes" ? "notesList" : "taskListBody");
          const scroller = kind === "notes" ? host.parentElement : document.getElementById("taskListView");
          const row = host.querySelector('[data-virtual-index="500"]');
          if (!row) return false;
          const rect = row.getBoundingClientRect(), bounds = scroller.getBoundingClientRect();
          return rect.bottom > bounds.top && rect.top < bounds.bottom;
        }, kind);
        await page.screenshot({ path: `.amp/in/artifacts/virtual-${kind}-${width}-${theme}.png` });
      }
    }
  }
  await page.evaluate(() => showNotesView());
  await settle();
  const beforeAppend = await page.evaluate(() => {
    const row = document.querySelector('#notesList [data-virtual-index="500"]');
    const top = row.getBoundingClientRect().top;
    renderNotesView({ append: true });
    return top;
  });
  await settle();
  assert.ok(Math.abs(await page.locator('#notesList [data-virtual-index="500"]').evaluate((row) => row.getBoundingClientRect().top) - beforeAppend) < 2, "pagination retains measured mobile heights and position");
  await page.evaluate(() => {
    const host = document.getElementById("notesList");
    const row = host.virtualList.ensure(500);
    const button = row.appendChild(document.createElement("button"));
    button.textContent = "Focus test";
    button.focus({ preventScroll: true });
    window.focusedControl = button;
    host.virtualList.ensure(900);
  });
  await settle();
  assert.equal(await page.evaluate(() => focusedControl.isConnected && document.activeElement === focusedControl), true, "focused row remains mounted");
  await page.evaluate(() => { focusedControl.remove(); });
  // Real binary AssetFull delivery must not replace a virtual row behind its
  // owner's back. Pure payload hydration keeps both the instance and row.
  const fullNotePacket = async (changed) => page.evaluate((changed) => {
    const host = document.getElementById("notesList");
    const row = host.virtualList.ensure(200);
    const note = host.virtualList.items[200];
    window.hydratedId = note.assetId;
    window.hydratedRow = row;
    window.hydratedList = host.virtualList;
    const encode = (text) => new TextEncoder().encode(text);
    const owner = encode(note.owner), preview = encode(changed ? "Changed by exact fetch" : note.preview), payload = encode("Full note content");
    const view = new DataView(new ArrayBuffer(63 + owner.length + preview.length + payload.length));
    view.setUint16(0, Opcode.S_AssetFull);
    view.setUint16(2, 5);
    view.setBigUint64(4, note.assetId);
    view.setUint16(22, owner.length);
    new Uint8Array(view.buffer, 24, owner.length).set(owner);
    view.setBigInt64(24 + owner.length, note.createdAt);
    view.setBigInt64(32 + owner.length, note.updatedAt);
    view.setBigUint64(40 + owner.length, note.convId);
    view.setUint32(49 + owner.length, payload.length);
    view.setUint16(53 + owner.length, preview.length);
    new Uint8Array(view.buffer, 55 + owner.length, preview.length).set(preview);
    view.setUint16(55 + owner.length + preview.length, payload.length);
    new Uint8Array(view.buffer, 57 + owner.length + preview.length, payload.length).set(payload);
    return Array.from(new Uint8Array(view.buffer));
  }, changed);
  serverSocket.send(Buffer.from(await fullNotePacket(false)));
  await page.waitForFunction(() => NRCAssets.roomAssets.get(0n).get(hydratedId).payload === "Full note content");
  assert.equal(await page.evaluate(() => hydratedRow.isConnected && hydratedList === document.getElementById("notesList").virtualList && hydratedRow.dataset.virtualIndex === "200"), true);
  await page.evaluate(() => document.getElementById("notesList").virtualList.ensure(800));
  await settle();
  await page.evaluate(() => document.getElementById("notesList").virtualList.ensure(200));
  await settle();
  assert.equal(await page.evaluate(() => document.querySelectorAll(`#notesList [data-note-id="${hydratedId}"]`).length), 1);
  serverSocket.send(Buffer.from(await fullNotePacket(true)));
  await page.waitForFunction(() => NRCAssets.roomAssets.get(0n).get(hydratedId).preview === "Changed by exact fetch");
  assert.equal(await page.evaluate(() => document.getElementById("notesList").virtualList.items.find((note) => note.assetId === hydratedId).preview), "Changed by exact fetch");

  // No completed keyboard/ensure target may pull a later scrollbar movement back.
  await page.evaluate(() => {
    const host = document.getElementById("notesList");
    host.virtualList.ensure(0);
    selectedNoteId = null; selectedNoteConvId = null;
    document.activeElement?.blur();
  });
  await settle();
  await page.keyboard.press("ArrowDown");
  await settle();
  await page.evaluate(() => { document.querySelector("#notesPanel .notes-container").scrollTop = 15000; });
  await settle();
  await settle();
  assert.ok(await page.evaluate(() => document.querySelector("#notesPanel .notes-container").scrollTop) > 10000, "manual scroll is not overridden by an old keyboard target");
  const dirtySelection = await page.evaluate(() => {
    document.activeElement?.blur();
    setNoteDetailDirty(true);
    return String(selectedNoteId);
  });
  await page.keyboard.press("ArrowDown");
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  assert.equal(await page.evaluate(() => String(selectedNoteId)), dirtySelection, "cancelled keyboard navigation preserves selection");
  await page.evaluate(() => setNoteDetailDirty(false));
  await page.evaluate(() => NRCInspector.close());

  // The first page-to-window transition must retain a mobile reading anchor.
  for (const kind of ["notes", "tasks"]) {
    const position = await page.evaluate((kind) => {
      if (kind === "notes") {
        const all = [...NRCAssets.roomAssets.get(0n).values()].sort((a, b) => Number(b.assetId - a.assetId));
        window.nextPage = all.slice(100, 125);
        NRCAssets.roomAssets.set(0n, new Map(all.slice(0, 100).map((note) => [note.assetId, note])));
        Object.assign(getNotesPaginationState(0n), { totalCount: 125, hasMore: false });
        renderNotesView();
      } else {
        window.nextTasks = [...roomTasks.get(0n).values()].slice(100, 200);
        roomTasks.set(0n, new Map([...roomTasks.get(0n)].slice(0, 100)));
        taskListDirty = true;
        setTaskGrouping("flat");
        showKanban();
      }
      const host = document.getElementById(kind === "notes" ? "notesList" : "taskListBody");
      const scroller = kind === "notes" ? host.parentElement : document.getElementById("taskListView");
      const rows = host.querySelectorAll(kind === "notes" ? ".note-card" : "tr[data-task-id]");
      rows[90].scrollIntoView({ block: "start" });
      const top = scroller.getBoundingClientRect().top;
      const header = host.previousElementSibling?.getBoundingClientRect().height || 0;
      const visible = [...rows].find((row) => row.getBoundingClientRect().bottom > top + header);
      window.thresholdRowId = kind === "notes" ? visible.dataset.noteId : visible.dataset.taskId;
      return visible.getBoundingClientRect().top - top;
    }, kind);
    await page.evaluate((kind) => {
      if (kind === "notes") {
        for (const note of nextPage) NRCAssets.roomAssets.get(0n).set(note.assetId, note);
        handleNoteChanged({ convId: 0n, count: 25, totalCount: 125, hasMore: false }, "list_page");
      } else {
        for (const task of nextTasks) roomTasks.get(0n).set(task.id, task);
        renderTaskList();
      }
    }, kind);
    await settle();
    const after = await page.evaluate((kind) => {
      const host = document.getElementById(kind === "notes" ? "notesList" : "taskListBody");
      const row = host.querySelector(`[data-${kind === "notes" ? "note" : "task"}-id="${thresholdRowId}"]`);
      const scroller = kind === "notes" ? host.parentElement : document.getElementById("taskListView");
      return { total: host.virtualList.items.length, top: row?.getBoundingClientRect().top - scroller.getBoundingClientRect().top };
    }, kind);
    assert.equal(after.total, kind === "notes" ? 125 : 200);
    assert.ok(Math.abs(after.top - position) < 2, `${kind} threshold anchor moved: ${position} -> ${after.top}`);
  }
  assert.deepEqual(errors, []);
  console.log("Virtual lists: sizes, offscreen navigation, reuse, drag/drop and responsive themes passed");
} finally {
  await browser.close();
}
