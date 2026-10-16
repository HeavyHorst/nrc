// Note surfaces bind their panel-level handlers once, not per render.
// The note detail panel replaces its own markup on the persistent
// `.agenda-content`; a handler bound per render piles up there, so Ctrl+Enter
// saves once per copy and the copies read form fields that only exist in edit
// mode. The shared-note ledger binds a scroll handler on `#noteShareContent`,
// which survives its renders the same way.
// node client/note-surfaces.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, serviceWorkers: "block" });
const errors = [];
page.on("pageerror", error => errors.push(error.message));

async function openNoteEdit(id) {
  await page.evaluate(async (noteId) => { await NRCInspector.openEntity({ roomId: 0n, type: "note", id: BigInt(noteId) }); }, id);
  await page.locator("#noteDetailEdit").click();
  await page.locator("#noteDetailContent").waitFor({ state: "visible" });
}

try {
  await page.context().routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.context().route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.addInitScript(() => {
    window.__panelListeners = [];
    window.__shareScrollListeners = 0;
    const add = EventTarget.prototype.addEventListener;
    const remove = EventTarget.prototype.removeEventListener;
    EventTarget.prototype.addEventListener = function (type, listener, options) {
      if (this instanceof Element && this.classList?.contains("agenda-content")) window.__panelListeners.push(type);
      if (type === "scroll" && this instanceof Element && this.id === "noteShareContent") window.__shareScrollListeners++;
      return add.call(this, type, listener, options);
    };
    EventTarget.prototype.removeEventListener = function (type, listener, options) {
      if (type === "scroll" && this instanceof Element && this.id === "noteShareContent") window.__shareScrollListeners--;
      return remove.call(this, type, listener, options);
    };
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCAssets && window.NRCInspector && window.NRCTasks);
  await page.evaluate(() => {
    currentRoomId = 7n;
    currentWorkspaceId = "note-panel";
    myNickname = "tester";
    serverReady = true;
    const stamp = BigInt(Date.now()) * 1000000n;
    const note = (id, title) => ({ assetId: BigInt(id), convId: 0n, assetType: AssetType.Note, owner: "anna", createdAt: stamp, updatedAt: stamp,
      attachments: [], preview: JSON.stringify({ version: 1, title, format: "markdown", tags: [], project: "" }), payload: `# ${title}\n\nbody` });
    NRCAssets.roomAssets.set(0n, new Map([[1n, note(1, "Note one")], [2n, note(2, "Note two")]]));
    NRCLinksUI.loadLinks = async () => {};
    window.__sends = [];
    ws.send = () => { window.__sends.push(1); };
    NRCAssets.sendGetAsset = (_room, id, callbacks) => {
      queueMicrotask(() => callbacks.onSuccess({ asset: NRCAssets.roomAssets.get(0n).get(id) }));
      return 1;
    };
  });

  // Markdown references share the inspector's cache, lazy reads and history.
  await page.evaluate(async () => {
    const source = NRCAssets.roomAssets.get(0n).get(1n);
    source.payload = "Der Shop-Link führt zum externen Kaufangebot. Siehe [note:2].\n\nPrüfen: [TASK:18446744073709551615].\n\n`[note:2]` [existing [note:2]](https://example.test) [task:0] [task:18446744073709551616]";
    window.__originalReferenceTaskRequest = NRCTasks.requestTask;
    window.__referenceReads = [];
    NRCTasks.requestTask = (room, id, options) => {
      window.__referenceReads.push(String(id));
      window.__resolveReference = () => {
        const task = { id, convId: 0n, title: "Kaufangebot prüfen", description: "Details: [note:2].", status: 0, priority: 128,
          orderIndex: 0, color: 0, assignee: "", project: "", attachments: [], createdAt: source.createdAt, updatedAt: source.updatedAt };
        if (!NRCTasks.roomTasks.has(0n)) NRCTasks.roomTasks.set(0n, new Map());
        NRCTasks.roomTasks.get(0n).set(id, task);
        options.onSuccess({ task });
      };
    };
    NRCViewManager.setActiveView("notes");
    await NRCInspector.openEntity({ type: "note", id: 1n });
  });
  const body = page.locator(".note-preview-body");
  await body.waitFor();
  assert.equal(await body.locator('a[data-nrc-reference]').count(), 2, "code, existing links and invalid IDs stay unchanged");
  assert.equal(await body.locator('a[title="NOTE #2"]').textContent(), "Note two", "cached title is immediate");
  const taskLink = body.locator('a[title="TASK #18446744073709551615"]');
  assert.equal(await taskLink.textContent(), "[task:18446744073709551615]", "unresolved references keep their ID");
  await page.waitForFunction(() => window.__referenceReads.includes("18446744073709551615"));
  await page.evaluate(() => window.__resolveReference());
  await page.waitForFunction(() => document.querySelector('a[title="TASK #18446744073709551615"]')?.textContent === "Kaufangebot prüfen");
  assert.match(await taskLink.getAttribute("href"), /#\/inspect\/note-panel\/task\/18446744073709551615$/);

  // All references resolve, even in hidden content and without cache entries.
  await page.evaluate(() => {
    window.__originalReferenceAssetRequest = NRCAssets.requestAsset;
    NRCAssets.requestAsset = (_room, id, options) => {
      if (id === 9999n) { options.onError?.({ message: "Not found" }); return; }
      const asset = { assetId: id, convId: 0n, assetType: AssetType.Note, preview: JSON.stringify({ title: "Medienpakete verkaufen" }) };
      NRCAssets.roomAssets.get(0n).set(id, asset);
      options.onSuccess({ asset });
    };
    const hidden = document.createElement("div");
    hidden.id = "hiddenReference";
    hidden.hidden = true;
    hidden.innerHTML = parseMarkdown("[task:987] [note:4700] [note:9999]");
    document.body.append(hidden);
  });
  await page.waitForFunction(() => window.__referenceReads.includes("987"));
  await page.evaluate(() => window.__resolveReference());
  assert.equal(await page.locator('#hiddenReference a[title="TASK #987"]').textContent(), "Kaufangebot prüfen", "hidden task references resolve without becoming visible");
  assert.equal(await page.locator('#hiddenReference a[title="NOTE #4700"]').textContent(), "Medienpakete verkaufen", "uncached notes resolve too");
  assert.equal(await page.locator('#hiddenReference a[title="NOTE #9999 · Not available"]').textContent(), "[note:9999]", "missing targets retain an actionable ID fallback");
  await page.evaluate(() => {
    document.getElementById("hiddenReference").remove();
    NRCTasks.requestTask = window.__originalReferenceTaskRequest;
    NRCAssets.requestAsset = window.__originalReferenceAssetRequest;
  });

  const popupPromise = page.context().waitForEvent("page");
  await taskLink.click({ button: "middle" });
  const popup = await popupPromise;
  await popup.waitForFunction(() => window.NRCInspector && currentWorkspaceId === "note-panel");
  assert.match(popup.url(), /#\/inspect\/note-panel\/task\/18446744073709551615$/);
  await popup.evaluate(() => {
    serverReady = true;
    NRCLinksUI.loadLinks = async () => {};
    NRCTasks.requestTask = (_room, id, options) => options.onSuccess({ task: {
      id, convId: 0n, title: "New tab target", description: "Loaded by URL", status: 0, priority: 128,
      orderIndex: 0, color: 0, assignee: "", project: "", attachments: [], createdAt: 1n, updatedAt: 1n,
    } });
    handleShareHashChange();
  });
  await popup.waitForFunction(() => NRCInspector.current()?.type === "task" && !NRCInspector.isLoading());
  assert.equal(await popup.evaluate(() => String(NRCInspector.current().id)), "18446744073709551615");
  assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), "1", "modified click leaves the source inspector unchanged");
  await popup.close();

  await page.evaluate(() => {
    const paragraphs = "A paragraph of the source document.\n\n".repeat(45);
    NRCAssets.roomAssets.get(0n).get(1n).payload = `${paragraphs}[task:18446744073709551615]\n\n${paragraphs}`;
    NRCTasks.roomTasks.get(0n).get(18446744073709551615n).description = `${paragraphs}[note:2]\n\n${paragraphs}`;
    NRCInspector.prefetchNote = () => {};
    window.__pendingLinks = [];
    NRCLinksUI.loadLinks = (_room, type, id) => new Promise(resolve => {
      if (window.__holdNoteLinks && type === 1 && id === 1n) window.__pendingLinks.push(resolve);
      else setTimeout(resolve, 50);
    });
  });
  const scroller = page.locator("#inspectorEntityHost .record-document-scroll");
  for (const theme of ["light", "dark"]) {
    for (const width of [1600, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
      await page.evaluate(() => NRCInspector.openEntity({ type: "note", id: 1n }));
      await page.waitForFunction(() => !NRCInspector.isLoading());
      await taskLink.scrollIntoViewIfNeeded();
      const noteScroll = await scroller.evaluate(el => el.scrollTop);
      assert.ok(noteScroll > 500, "source link is well below the top");
      if (process.env.NRC_REFERENCE_SCREENSHOTS) {
        await fs.mkdir(process.env.NRC_REFERENCE_SCREENSHOTS, { recursive: true });
        await page.locator("#inspector").screenshot({ path: `${process.env.NRC_REFERENCE_SCREENSHOTS}/note-${theme}-${width}.png` });
      }
      await taskLink.click();
      await page.waitForFunction(() => NRCInspector.current()?.type === "task" && !NRCInspector.isLoading());
      assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), "18446744073709551615");
      assert.equal(await page.locator('.task-detail-doc-body a[title="NOTE #2"]').textContent(), "Note two", "task descriptions render the same references");
      await page.waitForFunction(() => document.querySelector("#inspectorEntityHost .record-document-scroll")?.scrollTop === 0);
      const noteLink = page.locator('.task-detail-doc-body a[title="NOTE #2"]');
      await noteLink.scrollIntoViewIfNeeded();
      const taskScroll = await scroller.evaluate(el => el.scrollTop);
      assert.ok(taskScroll > 500, "task link is well below the top");
      if (process.env.NRC_REFERENCE_SCREENSHOTS) {
        await page.locator("#inspector").screenshot({ path: `${process.env.NRC_REFERENCE_SCREENSHOTS}/task-${theme}-${width}.png` });
      }
      await noteLink.click();
      await page.waitForFunction(() => NRCInspector.current()?.id === 2n && !NRCInspector.isLoading());
      await page.locator("#inspectorBack").click();
      await page.waitForFunction(() => NRCInspector.current()?.type === "task" && !NRCInspector.isLoading());
      await page.waitForFunction(top => document.querySelector("#inspectorEntityHost .record-document-scroll")?.scrollTop === top, taskScroll);
      await scroller.evaluate(el => { el.scrollTop = 137; });
      await page.evaluate(() => handleCommentChanged({ parentType: 1, parentId: 18446744073709551615n, convId: 0n }, "fetched"));
      await page.waitForTimeout(80);
      assert.equal(await scroller.evaluate(el => el.scrollTop), 0, "a task comment remount does not replay the old BACK position");

      await page.evaluate(() => {
        window.__holdNoteLinks = true;
        document.dispatchEvent(new CustomEvent("nrc:asset-updated", { detail: { asset: NRCAssets.roomAssets.get(0n).get(1n) } }));
      });
      await page.locator("#inspectorBack").click();
      await page.waitForFunction(() => NRCInspector.current()?.id === 1n && NRCInspector.isLoading() && window.__pendingLinks.length === 1);
      assert.equal(await page.locator(".task-detail-doc-body").count(), 1, "previous task remains mounted during the pending BACK read");
      // A main-view selection interrupts BACK while the old task is still mounted.
      await page.evaluate(() => NRCInspector.openEntity({ type: "note", id: 2n }));
      await page.waitForFunction(() => NRCInspector.current()?.id === 2n && !NRCInspector.isLoading());
      await page.evaluate(() => window.__pendingLinks.shift()());
      await page.locator("#inspectorBack").click();
      await page.waitForFunction(() => NRCInspector.current()?.id === 1n && NRCInspector.isLoading() && window.__pendingLinks.length === 1);
      await page.evaluate(() => {
        window.__holdNoteLinks = false;
        window.__pendingLinks.shift()();
      });
      await page.waitForFunction(() => NRCInspector.current()?.type === "note" && !NRCInspector.isLoading());
      assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), "1", "back restores the source note");
      await page.waitForFunction(top => document.querySelector("#inspectorEntityHost .record-document-scroll")?.scrollTop === top, noteScroll);
      await scroller.evaluate(el => { el.scrollTop = 137; });
      await page.waitForTimeout(80);
      assert.equal(await scroller.evaluate(el => el.scrollTop), 137, "restoration does not lock subsequent scrolling");
      await page.evaluate(() => handleNoteCommentChanged({ parentType: NRCAssets.ParentType.Asset, parentId: 1n, convId: 0n }, "fetched"));
      await page.waitForTimeout(80);
      assert.equal(await scroller.evaluate(el => el.scrollTop), 0, "a note comment remount does not replay the old BACK position");
    }
  }
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.evaluate(async () => {
    await NRCInspector.close();
    NRCAssets.roomAssets.get(0n).get(1n).payload = "# Note one\n\nbody";
  });
  console.log("PASS: note/task Markdown links, cached and uncached titles including hidden content, new-tab URLs, exact 64-bit IDs, exclusions and inspector back navigation");

  // Several renders of the panel: the container keeps one handler per event.
  // click belongs to the resource registers, input and keydown to the edit form.
  await openNoteEdit(1);
  await openNoteEdit(2);
  await openNoteEdit(1);
  assert.deepEqual(await page.evaluate(() => window.__panelListeners), ["click", "input", "keydown", "input", "change", "keydown"], "note and task panels each bind their handlers once");

  // The preview has no form fields: the panel-level shortcut must stay silent.
  await page.locator("#noteDetailToggleView").click();
  await page.locator(".note-preview-panel").waitFor({ state: "visible" });
  await page.evaluate(() => { window.__sends = []; });
  await page.evaluate(() => {
    const target = document.querySelector(".note-preview-body") || document.querySelector(".note-preview-panel");
    target.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
  });
  await page.waitForTimeout(250);
  assert.deepEqual(errors, [], "Ctrl+Enter in the preview reads no form fields");
  assert.equal(await page.evaluate(() => window.__sends.length), 0, "Ctrl+Enter in the preview saves nothing");

  // Ctrl+Enter saves once, and typing still marks the panel dirty.
  await page.locator("#noteDetailEdit").click();
  await page.locator("#noteDetailContent").waitFor({ state: "visible" });
  await page.locator("#noteDetailContent").click();
  await page.locator("#noteDetailContent").press("End");
  await page.keyboard.type(" x");
  await page.waitForTimeout(100);
  assert.equal(await page.locator("#inspectorHeader.is-dirty").count(), 1, "typing marks the panel dirty");
  await page.evaluate(() => { window.__sends = []; });
  await page.keyboard.press("Control+Enter");
  await page.waitForTimeout(250);
  assert.equal(await page.evaluate(() => window.__sends.length), 1, "one save request per Ctrl+Enter");

  // Plain Enter in the content is a newline, never another save.
  await page.evaluate(() => { window.__sends = []; });
  await page.locator("#noteDetailContent").click();
  await page.keyboard.press("Enter");
  await page.waitForTimeout(250);
  assert.equal(await page.evaluate(() => window.__sends.length), 0, "plain Enter writes content without saving");

  assert.deepEqual(errors, [], "no page errors");
  console.log("PASS: note detail panel keeps one panel-level handler per event, saves once and stays silent in preview");

  // The shared-note ledger: `#noteShareContent` survives its renders, so the
  // section-jump scroll handler must be replaced, not stacked.
  await page.evaluate(() => {
    const stamp = BigInt(Date.now()) * 1000000n;
    const note = { convId: 0n, assetId: 20n, assetType: AssetType.Note, owner: "anna", createdAt: stamp, updatedAt: stamp,
      preview: JSON.stringify({ version: 1, title: "Shared note", format: "markdown", tags: [], project: "" }),
      payload: "# Alpha\n\none\n\n## Bravo\n\ntwo\n\n## Charlie\n\nthree", attachments: [] };
    NRCAssets.roomAssets.set(0n, new Map([[20n, note]]));
    NRCViewManager.setActiveView("noteShare");
    sharedNoteAsset = note;
    sharedNoteEdges = [];
    renderSharedNoteView();
  });
  assert.equal(await page.locator(".note-section-jumps a").count(), 3, "the section-jump ledger renders");
  for (let i = 0; i < 3; i++) await page.evaluate(() => renderSharedNoteView());
  assert.equal(await page.evaluate(() => window.__shareScrollListeners), 1, "one scroll handler after repeated renders");
  assert.deepEqual(errors, [], "no page errors");

  console.log("PASS: shared-note ledger keeps one scroll handler across renders");
} finally {
  await browser.close();
}
