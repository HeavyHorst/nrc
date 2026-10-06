// Real renderers and styles with disposable, browser-local records.
// node client/files-share.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1400, height: 900 }, deviceScaleFactor: 2, serviceWorkers: "block" });
try {
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCFiles && window.NRCNotes);
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  // Contexts own their insets; empty, loading and failed lists use the same
  // alignment within a context. Document resources beat note-preview padding.
  for (const width of [1400, 390]) {
    await page.setViewportSize({ width, height: 900 });
    const styles = await page.evaluate(() => {
      const host = document.createElement("div");
      document.body.append(host);
      const result = {};
      try {
        for (const [name, classes] of Object.entries({
          plain: [], preview: ["note-preview-panel"], share: ["note-share-sidebar"],
          customer: ["customer-record"],
          register: ["record-resource", "record-resource-body"],
          document: ["note-preview-panel", "document-resources", "record-resource", "record-resource-body"],
        })) {
          host.replaceChildren();
          let parent = host;
          for (const className of classes) {
            const wrapper = document.createElement("div"); wrapper.className = className;
            parent.append(wrapper); parent = wrapper;
          }
          parent.innerHTML = `<section class="file-assets-section"><div class="file-assets-list"><div class="file-assets-row">First</div><div class="file-assets-row">Last</div></div><p class="file-assets-empty">EMPTY</p><p class="file-assets-loading">LOADING</p><p class="file-assets-error">ERROR</p></section>`;
          const section = parent.firstElementChild;
          const css = selector => getComputedStyle(section.querySelector(selector));
          const rem = parseFloat(getComputedStyle(document.documentElement).fontSize);
          const padding = style => [style.paddingTop, style.paddingRight, style.paddingBottom, style.paddingLeft].map(v => parseFloat(v) / rem);
          result[name] = { section: padding(getComputedStyle(section)), row: padding(css(".file-assets-row")),
            empty: padding(css(".file-assets-empty")), loading: padding(css(".file-assets-loading")), error: padding(css(".file-assets-error")),
            firstBorder: css(".file-assets-row").borderBottomWidth, lastBorder: css(".file-assets-row:last-child").borderBottomWidth };
        }
      } finally { host.remove(); }
      return result;
    });
    const inset = (vertical, horizontal) => [vertical, horizontal, vertical, horizontal];
    for (const [name, expected] of Object.entries({ plain: [.125, 0, 0, 0], preview: [.25, .75, .5, .75], share: [0, 0, 0, 0], customer: [.125, 0, 0, 0], register: [.375, .75, .5, .75], document: [0, 0, 0, 0] })) {
      assert.deepEqual(styles[name].section, expected, `${width}/${name}: section inset`);
      assert.deepEqual(styles[name].row, inset(.375, name === "document" ? .75 : .25), `${width}/${name}: row inset`);
      const stateInset = inset(["customer", "document"].includes(name) ? .5 : .25, name === "document" ? .75 : 0);
      for (const state of ["empty", "loading", "error"]) assert.deepEqual(styles[name][state], stateInset, `${width}/${name}/${state}: state inset`);
      assert.equal(styles[name].firstBorder, "1px");
      assert.equal(styles[name].lastBorder, "0px");
    }
  }
  await page.evaluate(() => {
    const stamp = BigInt(Date.now()) * 1000000n;
    const note = { convId: 0n, assetId: 20n, assetType: NRCAssets.AssetType.Note, owner: "reviewer", updatedAt: stamp, createdAt: stamp, preview: JSON.stringify({ title: "Files in shared notes", project: "NRC", tags: ["review"] }), payload: "## Documents\nReusable files appear alongside direct attachments.\n\nSource: https://ampcode.com/threads/T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9", attachments: [] };
    const file = { ...note, assetId: 40n, assetType: NRCAssets.AssetType.File, preview: JSON.stringify({ type: "file", version: 1, title: "Interface specification" }), payload: JSON.stringify({ type: "file", version: 1, title: "Interface specification", description: "Shared reference document", category: "Documentation" }), attachments: [{ fileId: "test-file", filename: "interface.pdf", mimeType: "application/pdf", size: 2048n }] };
    NRCAssets.roomAssets.set(0n, new Map([[20n, note], [50n, { ...note, assetId: 50n, preview: JSON.stringify({ title: "Related note" }) }]]));
    window.fixtureNote = note;
    window.fixtureEdges = [
      { edgeId: 1n, sourceType: 1, sourceId: 20n, targetType: 1, targetId: 40n, relation: 1 },
      { edgeId: 2n, sourceType: 1, sourceId: 40n, targetType: 1, targetId: 20n, relation: 2 },
      { edgeId: 3n, sourceType: 1, sourceId: 20n, targetType: 1, targetId: 50n, relation: 1 },
    ];
    NRCAssets.requestAsset = (room, id, options) => {
      window.finishFileLoad = () => { NRCAssets.roomAssets.get(room).set(id, file); options.onSuccess({ asset: file }); };
      window.failFileLoad = () => options.onError({ message: "Fixture read failure" });
      return 1;
    };
    NRCViewManager.setActiveView("noteShare");
    sharedNoteAsset = note;
    sharedNoteEdges = fixtureEdges;
    renderSharedNoteView();
  });
  assert.match(await page.locator(".note-share-files").innerText(), /LOADING FILE RECORDS/);
  await page.evaluate(() => {
    window.originalFileRead = NRCAssets.sendGetAsset;
    NRCAssets.sendGetAsset = NRCAssets.requestAsset;
    failFileLoad();
  });
  await page.locator(".note-share-files .file-assets-error").waitFor();
  await page.locator(".note-share-files").screenshot({ path: ".amp/in/artifacts/files-share-retry.png" });
  await page.locator(".note-share-files").getByRole("button", { name: "RETRY", exact: true }).click();
  await page.locator(".note-share-files .file-assets-loading").waitFor();
  await page.evaluate(() => finishFileLoad());
  await page.evaluate(() => { NRCAssets.sendGetAsset = originalFileRead; });
  await page.locator(".note-share-files .file-assets-row").waitFor();
  assert.equal(await page.locator(".note-share-files .file-assets-title").innerText(), "FILES (1)");
  assert.equal(await page.locator(".note-share-files .file-assets-row").count(), 1, "Both edge directions deduplicate the File");
  assert.equal(await page.locator(".note-share-links [data-type='NOTE']").count(), 1, "Files are not mislabeled as notes");
  assert.match(await page.locator(".note-share-links [data-type='NOTE']").innerText(), /Related note/);
  const shareButtons = await page.locator(".note-share-files button").allTextContents();
  assert.deepEqual(shareButtons.filter((label) => /UNLINK|UPLOAD|LINK EXISTING/.test(label)), [], "No write controls in share");
  assert.ok(shareButtons.includes("Interface specification"), "the File record stays reachable through its title");
  assert.equal(shareButtons.includes("DETAILS"), false, "no duplicate Details action");
  assert.equal(await page.locator(".note-share-files a[download]").getAttribute("download"), "interface.pdf");
  for (const theme of ["light", "dark"]) {
    for (const width of [1400, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
      const borders = await page.locator(".note-share-files, .note-share-attachments").evaluateAll(els => els.map(el => getComputedStyle(el).border));
      assert.equal(borders[0], borders[1], "Share sidebar frames match");
      const headerStyles = await page.locator(".note-share-sidebar .note-share-section-title, .note-share-files > .panel-header").evaluateAll(headers => headers.map(header => {
        const box = getComputedStyle(header), text = getComputedStyle(header.querySelector(".file-assets-title") || header);
        return [box.padding, box.backgroundColor, box.borderBottom, text.color, text.fontSize, text.fontWeight, text.letterSpacing, header.getBoundingClientRect().height];
      }));
      assert.ok(headerStyles.length >= 3);
      for (const style of headerStyles) assert.deepEqual(style, headerStyles[0], `${theme}/${width}: share section headers use one visual contract`);
      assert.ok(await page.locator(".note-share-files").evaluate(el => el.scrollWidth <= el.clientWidth), "No File overflow");
      // The read-only plate's export operations follow the shared header
      // operation contract: one-line verbs without synthetic OUT/OP cells, on
      // one control height and one bottom baseline.
      const exportActions = page.locator(".note-share-header .header-operation");
      assert.deepEqual(await exportActions.allTextContents(), ["OPEN PDF", "DOWNLOAD DOCX", "OPEN IN NRC"]);
      const exportGeometry = await exportActions.evaluateAll(actions => actions.map(action => {
        const rect = action.getBoundingClientRect();
        const row = action.closest(".header-register-identity-row").getBoundingClientRect();
        return {
          label: action.textContent.trim(),
          synthetic: getComputedStyle(action, "::before").content,
          height: rect.height,
          baseline: Math.round(row.bottom - rect.bottom),
          borders: ["Top", "Right", "Bottom", "Left"].map(side => getComputedStyle(action)[`border${side}Width`]),
        };
      }));
      for (const action of exportGeometry) {
        assert.equal(action.synthetic, "none", `${theme}/${width}/${action.label}: no synthetic OUT/OP label`);
        assert.deepEqual(action.borders, ["1px", "1px", "1px", "1px"], `${theme}/${width}/${action.label}: complete button frame`);
      }
      assert.equal(new Set(exportGeometry.map(action => action.height)).size, 1, `${theme}/${width}: export actions share one height`);
      assert.equal(new Set(exportGeometry.map(action => action.baseline)).size, 1, `${theme}/${width}: export actions share one baseline`);
      if (width > 768) {
        const operationHeight = await page.evaluate(() => parseFloat(getComputedStyle(document.documentElement).fontSize) * 1.2);
        assert.ok(Math.abs(exportGeometry[0].height - operationHeight) < 1, `${theme}/${width}: export actions use the shared desktop operation height`);
      }
      await page.locator(".note-share-header > .header-register-identity-row").evaluate(row => { row.scrollLeft = row.scrollWidth; });
      assert.ok(await page.locator("#noteShareOpenNrc").evaluate(button => {
        const rect = button.getBoundingClientRect();
        const row = button.parentElement.getBoundingClientRect();
        return rect.left >= row.left && rect.right <= row.right;
      }), `${theme}/${width}: the final action's whole frame is reachable`);
      await page.locator(".note-share-header").screenshot({ path: `.amp/in/artifacts/files-share-header-${theme}-${width}.png` });
      await page.locator(".note-share-sidebar").screenshot({ path: `.amp/in/artifacts/files-share-${theme}-${width}.png` });
    }
  }
  const standalone = await page.evaluate(() => {
    const host = document.createElement("div"); host.className = "customer-record";
    const section = document.createElement("section"); host.append(section); document.body.append(host);
    try {
      return [false, true, false].map(readOnly => {
        for (let i = 0; i < 2; i++) NRCFiles.renderSection(section, fixtureNote, 1, fixtureEdges, { readOnly, partial: true });
        return { headers: section.querySelectorAll(".panel-header").length, lists: section.querySelectorAll(".file-assets-list").length,
          title: section.querySelector(".file-assets-title").textContent, actions: [...section.querySelectorAll(".panel-header button")].map(b => b.textContent) };
      });
    } finally { host.remove(); }
  });
  for (const [index, state] of standalone.entries()) {
    assert.equal(state.headers, 1, "standalone sections own exactly one header across re-renders");
    assert.equal(state.lists, 1);
    assert.equal(state.title, "FILES (1) · PARTIAL");
    assert.deepEqual(state.actions, index === 1 ? [] : ["+ UPLOAD", "+ LINK EXISTING"], "read-only transitions replace write controls");
  }
  await page.evaluate(async () => {
    NRCViewManager.setActiveView("notes");
    NRCEdges.getEdgesForEntity = () => fixtureEdges;
    NRCLinksUI.loadLinks = async () => {};
    await NRCInspector.openEntity({ roomId: 0n, type: "note", id: 20n });
    showNotePreviewPanel(fixtureNote);
    renderLinks(fixtureNote, NRCEdges.TargetType.Asset);
  });
  // The read panel keeps each resource behind its register line; the preview
  // reads the line's state back before it renders, so a register the operator
  // opened stays open across renders.
  const openRegister = (resource) => page.evaluate((name) => {
    const block = document.querySelector(`.note-preview-panel [data-resource="${name}"]`);
    if (block.dataset.resourceOpen !== "true") block.querySelector("[data-resource-toggle]").click();
  }, resource);

  for (const theme of ["light", "dark"]) {
    for (const width of [1400, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
      const files = page.locator(".note-preview-panel .file-assets-section");
      await page.evaluate(async () => {
        await NRCInspector.openEntity({ roomId: 0n, type: "note", id: 20n });
        showNotePreviewPanel(fixtureNote);
      });
      const registerLine = async (resource) => (await page.locator(`.note-preview-panel [data-resource="${resource}"] [data-resource-toggle]`).innerText()).replace(/\s+/g, " ").trim();
      assert.match(await registerLine("files"), /^FILES 1$/,
        `${theme}/${width}: the register line carries the linked File`);
      assert.match(await registerLine("threads"), /^AMP THREADS 1$/,
        `${theme}/${width}: Amp threads close to their own register line`);
      await openRegister("files");
      await files.waitFor({ state: "visible" });
      await page.evaluate(() => {
        const section = document.querySelector(".note-preview-panel .file-assets-section");
        for (let i = 0; i < 3; i++) NRCFiles.renderSection(section, fixtureNote, 1, fixtureEdges, { partial: true });
      });
      assert.equal(await files.locator(".panel-header, .file-assets-title").count(), 0, "no duplicate title is rendered in a document");
      assert.equal(await files.locator(".file-assets-list").count(), 1, "headerless re-renders retain exactly one list");
      assert.equal(await files.locator(".file-assets-row").count(), 1);
      assert.match(await registerLine("files"), /^FILES 1 PARTIAL$/);
      await page.evaluate(() => NRCFiles.renderSection(document.querySelector(".note-preview-panel .file-assets-section"), fixtureNote, 1, fixtureEdges));
      assert.equal(await files.evaluate(el => getComputedStyle(el).borderLeftWidth), "0px");
      assert.equal(await files.evaluate(el => getComputedStyle(el).padding), "0px", "Files has no extra section inset around its rows");
      const registerFrames = await page.locator('.note-preview-panel [data-resource="files"], .note-preview-panel [data-resource="threads"]')
        .evaluateAll(els => els.map(el => getComputedStyle(el).borderTop));
      assert.equal(registerFrames[0], registerFrames[1], "file and thread registers share one frame");
      await page.locator(".note-preview-panel").screenshot({ path: `.amp/in/artifacts/files-detail-${theme}-${width}.png` });
    }
  }
  await page.evaluate(() => {
    NRCFiles.renderSection(document.querySelector(".note-preview-panel .file-assets-section"), fixtureNote, 1, [], { readOnly: true, hideWhenEmpty: true });
  });
  assert.equal(await page.locator(".note-preview-panel .file-assets-section").isHidden(), true, "Read-only Notes hide an empty Files section like empty Attachments");
  await page.locator(".note-preview-panel").screenshot({ path: ".amp/in/artifacts/files-detail-empty.png" });
  await page.evaluate(() => {
    NRCFiles.renderSection(document.querySelector(".note-preview-panel .file-assets-section"), fixtureNote, 1, [], { readOnly: false, hideWhenEmpty: true });
  });
  assert.equal(await page.locator(".note-preview-panel .file-assets-section").isVisible(), true, "Editable Notes retain the empty Files controls");
  assert.equal(await page.locator('.note-preview-panel [data-resource="files"] [data-resource-count]').innerText(), "0");
  assert.equal(await page.locator(".note-preview-panel .file-assets-title").count(), 0, "document tab owns the title, not a hidden duplicate");
  await page.locator(".note-preview-panel").screenshot({ path: ".amp/in/artifacts/files-detail-empty-editable.png" });
  await page.evaluate(() => showNoteEditPanel(fixtureNote));
  await page.locator("#noteLinkAdd").waitFor();
  await page.evaluate(() => {
    const block = document.querySelector('[data-resource="files"]');
    if (block.dataset.resourceOpen !== "true") block.querySelector('[data-resource-toggle]').click();
  });
  await page.evaluate(() => NRCFiles.renderSection(document.querySelector(".note-detail-panel .file-assets-section"), fixtureNote, 1, [], { readOnly: false }));
  for (const theme of ["light", "dark"]) {
    await page.evaluate(value => { document.documentElement.dataset.theme = value; }, theme);
    const controls = await page.locator('.document-resource-action > .btn, .document-resource-action > nrc-inline-field > button').evaluateAll(buttons => buttons.map(button => {
      const style = getComputedStyle(button);
      return {
        backgroundColor: style.backgroundColor,
        borderColor: style.borderTopColor,
        borderStyle: style.borderTopStyle,
        boxShadow: style.boxShadow,
        color: style.color,
      };
    }));
    assert.equal(controls.length, 2);
    assert.deepEqual(controls[1], controls[0], "Attach and Link share the resource action appearance");
    await page.locator(".note-detail-panel").screenshot({ path: `.amp/in/artifacts/note-edit-buttons-${theme}.png` });
  }
  await page.evaluate(() => {
    window.pickerPageLoads = [];
    NRCAssets.sendListAssetsPaged = (room, type, descending, limit, cursorAt, cursorId, options) => {
      pickerPageLoads.push(`asset:${type}`);
      if (type === NRCAssets.AssetType.Note) { window.releaseStaleNotePickerPage = () => options.onSuccess({ hasMore: false, nextCursorUpdatedAt: null, nextCursorAssetId: null, totalCount: 1 }); return 1; }
      queueMicrotask(() => options.onSuccess({ hasMore: false, nextCursorUpdatedAt: null, nextCursorAssetId: null, totalCount: 1 }));
      return 1;
    };
  });
  await page.click('#noteLinkAdd');
  const picker = page.locator(".note-link-picker:visible");
  await picker.waitFor({ state: "visible" });
  await picker.locator('[data-kind="file"]').click();
  await picker.locator(".note-link-picker-item").waitFor();
  assert.equal(await picker.locator(".note-link-picker-search").getAttribute("placeholder"), "SEARCH...");
  assert.equal(await picker.locator(".note-link-picker-item-title").innerText(), "Interface specification");
  assert.equal(await picker.locator(".note-link-picker-footer [role=status]").innerText(), "1 / 1 LOADED");
  assert.equal(await picker.getByRole("button", { name: "MORE", exact: true }).count(), 0, "MORE is hidden after the final page");
  await picker.screenshot({ path: ".amp/in/artifacts/files-picker-dark.png" });
  await page.keyboard.press("Escape");
  await picker.waitFor({ state: "hidden" });
  await page.evaluate(() => document.documentElement.dataset.theme = "light");
  await page.click('#noteLinkAdd');
  await picker.locator('[data-kind="file"]').click();
  await picker.locator(".note-link-picker-item").waitFor();
  await picker.screenshot({ path: ".amp/in/artifacts/files-picker-light.png" });
  await page.keyboard.press("Escape");
  await page.evaluate(() => {
    const anchor = document.createElement("button"); anchor.id = "sharedPickerTestAnchor"; document.body.append(anchor);
    NRCTasks.roomTasks.set(0n, new Map([[70n, { id: 70n, convId: 0n, title: "Shared pagination task" }]]));
    NRCTasks.sendListTasksPaged = (room, mask, limit, cursorAt, cursorId, options) => { pickerPageLoads.push("task"); queueMicrotask(() => options.onSuccess({ hasMore: false, nextCursorSortAt: null, nextCursorTaskId: null, totalCount: 1 })); return 1; };
    NRCLinksUI.openEntityPicker({ anchor, sourceType: 1, sourceEntity: fixtureNote, kinds: ["note", "task"], relation: { value: 1, label: "references" }, onSelect: () => {} });
  });
  const sharedPicker = page.locator(".note-link-picker:not(.file-assets-picker):visible");
  await sharedPicker.locator(".note-link-picker-item").waitFor();
  await sharedPicker.locator("[data-kind='task']").click();
  await page.waitForFunction(() => window.pickerPageLoads.includes("task"));
  assert.deepEqual(await page.evaluate(() => pickerPageLoads), ["asset:5", "asset:3", "asset:5", "asset:3", "asset:5", "task"]);
  assert.equal(await sharedPicker.locator(".note-link-picker-item-title").innerText(), "Shared pagination task");
  await page.evaluate(() => releaseStaleNotePickerPage());
  assert.equal(await sharedPicker.locator(".note-link-picker-item-title").innerText(), "Shared pagination task", "A stale Note page cannot replace the selected Task kind");
  await page.keyboard.press("Escape");
  console.log("File share hydration, deduplication, read-only actions, and responsive borders passed.");
} finally { await browser.close(); }
