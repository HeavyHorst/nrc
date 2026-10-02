// Real custom-element lifecycle, Portal and CustomSelect; deterministic local data.
// Run: node client/link-picker.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 2 });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.route("http://nrc.test/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    if (pathname === "/") return route.fulfill({ contentType: "text/html", body: `
      <meta charset="utf-8">
      <link rel="stylesheet" href="/css/main.css"><link rel="stylesheet" href="/css/custom-select.css">
      <main style="padding: 300px 20px 0"><section id="editor" class="agenda-content" style="width: 440px">
        <button id="a" class="btn">FIRST</button><nrc-link-picker id="first"></nrc-link-picker>
        <button id="b" class="btn">SECOND</button><nrc-link-picker id="second"></nrc-link-picker>
      </section><button id="outside" class="btn">OUTSIDE</button></main>` });
    await route.fulfill({ path: fileURLToPath(new URL(`.${pathname}`, import.meta.url)) });
  });
  await page.goto("http://nrc.test/");
  for (const file of ["portal.js", "custom-picker.js", "custom-select.js", "links-ui.js"]) {
    await page.addScriptTag({ url: `http://nrc.test/${file}` });
  }
  await page.evaluate(() => {
    window.requests = [];
    window.selected = [];
    window.notes = [
      { assetId: 11n, preview: "Source note" },
      { assetId: 42n, preview: "Architecture" },
      { assetId: 73n, preview: "Runbook" },
    ];
    window.NRCNotes = { getNotesForRoom: () => notes, parseNotePreview: title => ({ title }) };
    window.NRCAssets = { AssetType: { Note: 5, File: 3 }, roomAssets: new Map(), sendListAssetsPaged: (...args) => requests.push(args) };
    window.NRCTasks = { roomTasks: new Map([[7n, new Map([[99n, { id: 99n, title: "Task target" }]])]]), sendListTasksPaged: (...args) => requests.push(args) };
    window.openFirst = (extra = {}) => first.open({ anchor: a, sourceType: 1, sourceEntity: { convId: 7n, assetId: 11n }, onSelect: (item, relation) => selected.push([String(item.id), relation]), ...extra });
    window.openSecond = (extra = {}) => second.open({ anchor: b, sourceType: 2, sourceEntity: { convId: 7n, id: 99n }, onSelect: item => selected.push([String(item.id)]), ...extra });
    a.onclick = event => { event.stopPropagation(); openFirst(); };
    b.onclick = event => { event.stopPropagation(); openSecond(); };
  });

  await page.click("#a");
  assert.equal(await page.evaluate(() => first.isConnected && first.panel.closest(".portal-wrapper") !== null), true);
  assert.equal(await page.evaluate(() => CustomSelect.instances.get(first.relationSelect).portal.config.boundary === editor), true, "nested select retains the editor boundary after portal reparenting");
  assert.deepEqual(await page.locator(".portal-wrapper [data-kind]").allTextContents(), ["NOTE", "TASK", "FILE"]);
  assert.deepEqual(await page.locator(".note-link-picker-item-title").allTextContents(), ["Architecture", "Runbook"]);
  assert.equal(await page.getByRole("textbox", { name: "Search link targets" }).evaluate(el => document.activeElement === el), true);

  // Cursor retries retain the cursor, and changing kind invalidates an old page.
  await page.evaluate(() => requests.at(-1).at(-1).onSuccess({ hasMore: true, nextCursorUpdatedAt: 17n, nextCursorAssetId: 73n, totalCount: 9 }));
  await page.getByRole("button", { name: "MORE", exact: true }).click();
  assert.deepEqual(await page.evaluate(() => requests.at(-1).slice(4, 6).map(String)), ["17", "73"]);
  await page.evaluate(() => requests.at(-1).at(-1).onError({ message: "Page unavailable" }));
  await page.getByRole("button", { name: "RETRY", exact: true }).click();
  await page.evaluate(() => { window.oldPage = requests.at(-1).at(-1); });
  await page.getByRole("button", { name: "TASK", exact: true }).click();
  await page.evaluate(() => oldPage.onError({ message: "STALE ERROR" }));
  assert.equal(await page.evaluate(() => first.state.loadError), "");
  assert.deepEqual(await page.locator(".note-link-picker-item-title").allTextContents(), ["Task target"]);
  await page.getByRole("button", { name: "NOTE", exact: true }).click();

  // Nested relation portal owns its keyboard and doesn't close the entity picker.
  await page.getByRole("button", { name: "Link relation: references", exact: true }).click();
  const nestedBounds = await page.evaluate(() => {
    const menu = CustomSelect.instances.get(first.relationSelect).portal.wrapper.getBoundingClientRect();
    const boundary = editor.getBoundingClientRect();
    return { left: menu.left >= boundary.left, right: menu.right <= boundary.right };
  });
  assert.deepEqual(nestedBounds, { left: true, right: true }, "nested menu stays inside editor horizontally");
  if (process.env.NRC_SELECT_SCREENSHOT) await page.screenshot({ path: process.env.NRC_SELECT_SCREENSHOT, clip: { x: 0, y: 0, width: 520, height: 400 } });
  await page.locator(".custom-select__option").filter({ hasText: /^blocks$/ }).click();
  assert.equal(await page.evaluate(() => first.state.relation), 4);
  assert.equal(await page.evaluate(() => first.state.isVisible), true);
  await page.getByRole("textbox", { name: "Search link targets" }).fill("Runbook");
  await page.keyboard.press("Enter");
  assert.deepEqual(await page.evaluate(() => selected), [["73", 4]]);
  assert.equal(await page.evaluate(() => NRCLinksUI.isPickerVisible()), false);

  await page.click("#a");
  await page.keyboard.press("ArrowDown");
  assert.equal(await page.evaluate(() => CustomSelect.instances.get(first.relationSelect).portal.config.boundary === editor), true, "reopened nested select retains its boundary");
  assert.equal(await page.locator(".note-link-picker-item.highlighted").textContent(), "#73Runbook");
  await page.click("#b");
  assert.equal(await page.evaluate(() => first.state.isVisible), false);
  assert.notEqual(await page.evaluate(() => second.state === first.state), true);
  await page.evaluate(() => requests[0].at(-1).onError({ message: "OLD FIRST ERROR" }));
  assert.equal(await page.evaluate(() => second.state.loadError), "");
  await page.keyboard.press("Escape");
  await page.click("#a");
  await page.click("#outside");
  assert.equal(await page.evaluate(() => NRCLinksUI.isPickerVisible()), false);

  // One pending selection cannot be submitted twice. A synchronous throw is retryable.
  await page.evaluate(() => {
    window.writes = 0;
    openFirst({ onSelect: () => { writes++; return new Promise(resolve => { window.finishWrite = resolve; }); } });
  });
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  assert.equal(await page.evaluate(() => writes), 1);
  await page.evaluate(() => { first.close(true); openSecond(); finishWrite(); });
  assert.equal(await page.evaluate(() => second.state.isVisible), true);
  await page.evaluate(() => {
    second.close();
    openFirst({ onSelect: () => { throw new Error("Write refused"); } });
  });
  await page.keyboard.press("Enter");
  assert.equal(await page.evaluate(() => first.state.loadError), "Write refused");
  assert.equal(await page.evaluate(() => first.state.selecting), false);

  // Removing a portaled host cleans both nested and outer portals and invalidates writes.
  await page.evaluate(() => {
    first.close();
    openFirst({ onSelect: () => new Promise((resolve, reject) => { window.rejectWrite = reject; }) });
    first.acceptPickerSelection();
    CustomSelect.instances.get(first.relationSelect).trigger.click();
    window.detached = first;
    editor.remove();
    rejectWrite(new Error("Late failure"));
  });
  assert.equal(await page.evaluate(() => NRCLinksUI.isPickerVisible()), false);
  assert.equal(await page.locator(".portal-wrapper").count(), 0);
  assert.equal(await page.evaluate(() => CustomSelect.instances.size), 0);
  assert.equal(await page.evaluate(() => detached.state.loadError), "");

  // Dynamic file/slice consumers use the same element and fixed relation/type.
  await page.evaluate(() => {
    NRCLinksUI.openEntityPicker({ anchor: outside, sourceType: 1, sourceEntity: { convId: 7n, assetId: 11n }, kinds: ["file"], relation: { value: 2, label: "related-to" }, onSelect: () => {} });
  });
  assert.equal(await page.locator("nrc-link-picker").count(), 1);
  assert.equal(await page.locator(".note-link-picker-fixed-type").textContent(), "FILE");
  assert.equal(await page.locator(".note-link-picker [data-kind]").count(), 0);
  assert.equal(await page.locator(".note-link-picker-relation").isVisible(), false);
  await page.keyboard.press("Escape");
  assert.equal(await page.locator("nrc-link-picker").count(), 0);
  assert.equal(await page.locator(".portal-wrapper").count(), 0);

  // Exercise the actual file reconciliation chain, not just an arbitrary callback.
  await page.addScriptTag({ url: "http://nrc.test/files.js" });
  await page.evaluate(() => {
    window.ws = { readyState: WebSocket.OPEN };
    window.edgeReads = [];
    window.edgeWrites = [];
    window.NRCEdges = {
      requestEdgePage: (...args) => new Promise(resolve => edgeReads.push({ args, resolve })),
      getEdgesForEntity: () => [],
      sendCreateEdge: (...args) => { edgeWrites.push(args); return edgeWrites.length; },
    };
    NRCAssets.roomAssets.set(7n, new Map([[81n, { assetId: 81n, assetType: 3, payload: '{"title":"Reference file"}', attachments: [] }]]));
    window.mountFiles = () => {
      window.fileOwner = document.createElement("section");
      window.fileSection = document.createElement("section");
      fileOwner.append(fileSection);
      document.querySelector("main").append(fileOwner);
      NRCFiles.renderSection(fileSection, { convId: 7n, assetId: 11n }, 1, []);
    };
    mountFiles();
  });
  await page.getByRole("button", { name: "+ LINK EXISTING", exact: true }).click();
  assert.deepEqual(await page.evaluate(async () => {
    const picker = fileOwner.querySelector("nrc-link-picker");
    const anchor = picker.anchor;
    NRCFiles.refresh();
    await Promise.resolve();
    document.querySelector("main").style.paddingLeft = "240px";
    window.dispatchEvent(new Event("resize"));
    const a = anchor.getBoundingClientRect(), p = picker.panel.getBoundingClientRect();
    return {
      connected: anchor.isConnected,
      sameButton: anchor === [...fileSection.querySelectorAll("button")].find(b => b.textContent === "+ LINK EXISTING"),
      expanded: anchor.getAttribute("aria-expanded"),
      aligned: Math.abs(p.right - a.right) < 2 && Math.abs(p.bottom - (a.top - 2)) < 2,
    };
  }), { connected: true, sameButton: true, expanded: "true", aligned: true });

  // Both a terminal page and a continuation must stop after host disposal.
  for (const hasMore of [false, true]) {
    await page.locator(".file-assets-picker .note-link-picker-item").click();
    const readCount = await page.evaluate(() => edgeReads.length);
    await page.evaluate(async hasMore => {
      fileOwner.remove();
      edgeReads.at(-1).resolve({ hasMore, session: {} });
      await Promise.resolve();
      await Promise.resolve();
    }, hasMore);
    assert.equal(await page.evaluate(() => edgeReads.at(-1).args.at(-1).isCancelled()), true);
    assert.equal(await page.evaluate(() => edgeWrites.length), 0, "disposed picker cannot start a write");
    assert.equal(await page.evaluate(() => edgeReads.length), readCount, "disposed picker cannot fetch another page");
    await page.evaluate(() => mountFiles());
    await page.getByRole("button", { name: "+ LINK EXISTING", exact: true }).click();
  }

  // A live session still creates the intended edge. An ACK after disposal must
  // not refresh a different surviving file section.
  await page.locator(".file-assets-picker .note-link-picker-item").click();
  await page.evaluate(async () => {
    edgeReads.at(-1).resolve({ hasMore: false });
    await Promise.resolve();
  });
  assert.deepEqual(await page.evaluate(() => edgeWrites[0].slice(0, 6).map(String)), ["7", "1", "11", "1", "81", "2"]);
  assert.equal(await page.evaluate(async () => {
    fileOwner.remove();
    mountFiles();
    const list = fileSection.querySelector(".file-assets-list");
    const child = list.firstChild;
    edgeWrites[0].at(-1).onSuccess();
    await Promise.resolve();
    await Promise.resolve();
    return list.firstChild === child;
  }), true, "late write acknowledgement must not trigger refresh");
  await page.getByRole("button", { name: "+ LINK EXISTING", exact: true }).click();
  await page.locator(".file-assets-picker .note-link-picker-item").click();
  await page.evaluate(async () => { edgeReads.at(-1).resolve({ hasMore: false }); await Promise.resolve(); });
  await page.evaluate(() => edgeWrites.at(-1).at(-1).onSuccess());
  assert.equal(await page.evaluate(() => NRCLinksUI.isPickerVisible()), false, "live acknowledgement completes selection");

  // A dynamic picker host must not become a third flex item in slice headers.
  await page.evaluate(() => {
    document.querySelector("main").style.cssText = "padding: 300px 20px 0";
    const editor = document.createElement("section");
    editor.id = "editor";
    editor.className = "agenda-content";
    document.querySelector("main").append(editor);
    editor.style.width = "100%";
    editor.innerHTML = ["task", "note", "file"].map(kind => `
      <section class="slice-section">
        <div class="panel-header"><div><span>${kind.toUpperCase()}S / 0</span><button class="btn" data-kind="${kind}">+ ASSIGN ${kind.toUpperCase()}</button></div></div>
      </section>`).join("");
    editor.onclick = event => {
      const anchor = event.target.closest("button[data-kind]");
      if (!anchor) return;
      event.stopPropagation();
      NRCLinksUI.openEntityPicker({
        anchor, sourceType: 1, sourceEntity: { convId: 7n, assetId: 11n },
        kinds: [anchor.dataset.kind], relation: { value: 7, label: "member-of" },
      });
    };
  });
  for (const width of [1280, 390]) {
    await page.setViewportSize({ width, height: 900 });
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      for (const kind of ["task", "note", "file"]) {
        const button = page.locator(`#editor button[data-kind="${kind}"]`);
        const before = await button.boundingBox();
        await button.click();
        assert.deepEqual(await button.boundingBox(), before, `${kind} assign stays put at ${width}px in ${theme}`);
        const panel = await page.locator(".portal-wrapper .note-link-picker").boundingBox();
        if (width === 1280) {
          assert.ok(Math.abs(panel.x + panel.width - before.x - before.width) < 2, "picker aligns with the unchanged button");
        } else {
          assert.ok(panel.x >= 0 && panel.x + panel.width <= width, "phone picker is clamped inside the viewport");
        }
        if (process.env.NRC_SLICE_PICKER_SCREENSHOT && kind === "task") {
          await page.screenshot({ path: process.env.NRC_SLICE_PICKER_SCREENSHOT.replace(/\.png$/, `-${width}-${theme}.png`) });
        }
        await page.keyboard.press("Escape");
        assert.deepEqual(await button.boundingBox(), before, "closing restores the same layout");
      }
    }
  }
  assert.deepEqual(errors, []);
  console.log("PASS: picker lifecycle, isolation, paging/retry, keyboard, nested portals; real file reconciliation cancellation, late ACK suppression, and stable anchor after refresh/resize");
} finally {
  await browser.close();
}
