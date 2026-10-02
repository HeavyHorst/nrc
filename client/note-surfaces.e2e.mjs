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
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
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

  // Several renders of the panel: the container keeps one handler per event.
  // click belongs to the resource registers, input and keydown to the edit form.
  await openNoteEdit(1);
  await openNoteEdit(2);
  await openNoteEdit(1);
  assert.deepEqual(await page.evaluate(() => window.__panelListeners), ["click", "input", "keydown"], "one panel-level handler per event");

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
