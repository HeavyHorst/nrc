import assert from "node:assert/strict";
import { chromium } from "playwright";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test/");
  await page.waitForFunction(() => window.NRCDialog && window.NRCFiles);
  await page.evaluate(() => {
    const launch = document.createElement("button");
    launch.id = "dialogTestLaunch"; launch.textContent = "OPEN DIALOG";
    document.body.prepend(launch);
    launch.focus();
    window.results = [];
    window.workspaceKeys = 0;
    document.addEventListener("keydown", () => workspaceKeys++);
  });
  const dialog = page.getByRole("dialog");
  await page.evaluate(() => { NRCDialog.confirm("Archive this record?").then(value => results.push(value)); });
  assert.equal(await dialog.getAttribute("aria-labelledby").then(id => page.locator(`#${id}`).textContent()), "CONFIRM ACTION");
  assert.equal(await dialog.locator("button").first().evaluate(el => document.activeElement === el), true);
  await page.evaluate(() => document.getElementById("dialogTestLaunch").focus());
  assert.equal(await dialog.evaluate(el => el.contains(document.activeElement)), true, "background is inert");
  await page.keyboard.press("Shift+Tab");
  assert.equal(await dialog.locator("button").last().evaluate(el => document.activeElement === el), true, "Tab wraps backward");
  await page.keyboard.press("Tab");
  assert.equal(await dialog.locator("button").first().evaluate(el => document.activeElement === el), true, "Tab wraps forward");
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => results.length === 1);
  assert.deepEqual(await page.evaluate(() => results), [false]);
  assert.equal(await page.locator("#dialogTestLaunch").evaluate(el => document.activeElement === el), true);
  assert.equal(await page.evaluate(() => workspaceKeys), 0);

  await page.evaluate(() => { NRCDialog.prompt("Name", { initialValue: "previous" }).then(value => results.push(value)); });
  assert.equal(await dialog.locator("input").evaluate(el => el.selectionEnd - el.selectionStart), 8);
  await dialog.locator("input").fill("  revised  ");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => results.length === 2);
  assert.deepEqual(await page.evaluate(() => results), [false, "revised"]);
  await page.evaluate(() => {
    NRCDialog.prompt("Old").then(value => results.push(value));
    NRCDialog.confirm("Replacement").then(value => results.push(value));
  });
  assert.equal(await dialog.count(), 1);
  await dialog.getByRole("button", { name: "Confirm", exact: true }).click();
  await page.waitForFunction(() => results.length === 4);
  assert.deepEqual(await page.evaluate(() => results.slice(2)), [false, true]);

  // Exercise mixed controls and hidden/disabled endpoints, not only buttons.
  await page.evaluate(() => {
    window.mixed = NRCModal.create({ title: "Mixed controls" });
    const fields = document.createElement("div");
    fields.innerHTML = '<input hidden><fieldset disabled><input></fieldset><input style="visibility:hidden"><textarea id="mixedText"></textarea><select id="mixedSelect"><option>One</option></select><a id="mixedLink" href="#">Link</a><button hidden>Hidden</button>';
    mixed.panel.insertBefore(fields, mixed.actions);
    mixed.show();
  });
  assert.equal(await page.locator("#mixedText").evaluate(el => document.activeElement === el), true);
  await page.keyboard.press("Shift+Tab");
  assert.equal(await page.locator("#mixedLink").evaluate(el => document.activeElement === el), true);
  await page.keyboard.press("Tab");
  assert.equal(await page.locator("#mixedText").evaluate(el => document.activeElement === el), true);
  await page.keyboard.press("Tab");
  assert.equal(await page.locator("#mixedSelect").evaluate(el => document.activeElement === el), true);
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.querySelector("dialog[open]"));

  // Actual file form, nested confirmation, and asynchronous write protection.
  await page.evaluate(() => {
    window.asset = { assetId: 81n, convId: 0n, assetType: 3, owner: "tester", createdAt: 0n,
      preview: '{"type":"file","version":1,"title":"Reference"}',
      payload: '{"type":"file","version":1,"title":"Reference","category":"Specs","description":"Details","tags":[]}',
      attachments: [{ fileId: "ref", filename: "reference.pdf", mimeType: "application/pdf", size: 1024 }] };
    window.fileRoot = NRCFiles.open(asset, { readOnly: false });
  });
  assert.equal(await dialog.locator('form').isVisible(), false);
  await dialog.getByRole("button", { name: "EDIT", exact: true }).click();
  await dialog.locator('[name="title"]').fill('Discarded draft');
  await dialog.getByRole("button", { name: "CANCEL EDIT", exact: true }).click();
  assert.equal(await dialog.locator('dl').isVisible(), true);
  await dialog.getByRole("button", { name: "EDIT", exact: true }).click();
  assert.equal(await dialog.locator('[name="title"]').inputValue(), 'Reference');
  assert.equal(await dialog.locator('dl').isVisible(), false, "edit replaces facts rather than duplicating them");
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["light", "dark"]) {
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 800 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await dialog.getByRole("button", { name: "SAVE METADATA" }).scrollIntoViewIfNeeded();
      const bodyBounds = await dialog.locator(".file-assets-dialog-body").boundingBox();
      const saveBounds = await dialog.getByRole("button", { name: "SAVE METADATA" }).boundingBox();
      const closeBounds = await dialog.getByRole("button", { name: "Close", exact: true }).boundingBox();
      assert.ok(saveBounds.y >= bodyBounds.y + bodyBounds.height, "save stays in the footer outside the scrolling form");
      assert.ok(closeBounds.y + closeBounds.height <= bodyBounds.y, "close stays above the scrolling body");
      await dialog.locator(".file-assets-dialog").screenshot({ path: `.amp/in/artifacts/dialog-file-${theme}-${width}.png` });
    }
  }
  await page.setViewportSize({ width: 1280, height: 800 });
  await dialog.locator("textarea").focus();
  await page.evaluate(() => NRCDialog.notify("File status"));
  await page.evaluate(() => { NRCDialog.confirm("Nested confirmation").then(value => results.push(value)); });
  assert.equal(await page.locator("dialog[open]").count(), 2);
  assert.equal(await page.evaluate(() => document.querySelector(".toast").parentElement === NRCModal.activeRoot()), true, "existing toast follows the top modal");
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => results.length === 5);
  assert.equal(await page.locator("dialog[open]").count(), 1);
  assert.equal(await page.evaluate(() => document.querySelector(".toast").parentElement === fileRoot), true, "toast returns to the underlying modal");
  assert.equal(await dialog.locator("textarea").evaluate(el => document.activeElement === el), true, "nested close returns focus to the file form");
  await page.evaluate(() => {
    ws = { readyState: WebSocket.OPEN };
    NRCTransactions.sendAssetMetadataPatch = (_asset, _preview, _payload, options) => { window.writeOptions = options; return 123; };
  });
  await dialog.getByRole("button", { name: "SAVE METADATA" }).click();
  await page.waitForFunction(() => !!window.writeOptions);
  await page.keyboard.press("Escape");
  await dialog.getByRole("button", { name: "Close", exact: true }).click();
  assert.equal(await page.locator("dialog[open]").count(), 1, "both cancel paths refuse closing during a write");
  await page.evaluate(() => NRCDialog.notify("Write status"));
  assert.equal(await page.evaluate(() => document.querySelector(".toast").parentElement === fileRoot), true, "new notifications are above the modal");
  await page.evaluate(() => writeOptions.onError({ message: "Write failed" }));
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.querySelector("dialog[open]"));
  assert.equal(await page.evaluate(() => document.querySelector(".toast").parentElement === document.body), true, "notification survives closing its dialog");
  await page.locator(".toast").click();

  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["light", "dark"]) {
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 800 });
      await page.evaluate(theme => {
        document.documentElement.dataset.theme = theme;
        NRCDialog.prompt("Name for the new record", { title: "CREATE RECORD", initialValue: "Example" });
      }, theme);
      const bounds = await dialog.locator(".nrc-dialog").boundingBox();
      assert.ok(bounds.x >= 0 && bounds.x + bounds.width <= width, "dialog fits viewport");
      await dialog.locator(".nrc-dialog").screenshot({ path: `.amp/in/artifacts/dialog-${theme}-${width}.png` });
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => !document.querySelector("dialog[open]"));
    }
  }
  // New-task slice choice is optional, context-aware, and uses the real shared picker.
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.evaluate(() => {
    window.taskCreates = [];
    window.taskEdges = [];
    window.sliceView = false;
    window.NRCSlices.isActive = () => sliceView;
    window.NRCSlices.selectedSlice = () => ({ sliceId: 51n, name: "Release planning" });
    window.NRCAssets.roomAssets.set(0n, new Map([[72n, {
      assetId: 72n, assetType: NRCAssets.AssetType.Slice,
      preview: JSON.stringify({ name: "Customer follow-up" }),
    }]]));
    window.NRCAssets.sendListAssetsPaged = (...args) => {
      window.slicePage = args.at(-1);
      slicePage.onSuccess({ hasMore: false, totalCount: 1 }); return 1;
    };
    sendCreateTask = (...args) => { taskCreates.push(args); return 1; };
    window.NRCEdges.sendCreateEdge = (...args) => { taskEdges.push(args); return 2; };
    promptNewTask();
  });
  assert.equal(await dialog.getByRole("button", { name: "Choose slice…" }).count(), 1, "inactive retained slice is not a default");
  await dialog.getByLabel("Task title").fill("No slice");
  await page.keyboard.press("Enter");
  await page.evaluate(() => taskCreates.at(-1).at(-1).onSuccess({ task: { id: 91n } }));
  assert.equal(await dialog.count(), 0);
  assert.equal(await page.evaluate(() => taskEdges.length), 0);
  await page.evaluate(() => { sliceView = true; promptNewTask(); });
  assert.equal(await dialog.getByRole("button", { name: "#51 · Release planning", exact: true }).count(), 1);
  await dialog.getByRole("button", { name: "Clear slice" }).click();
  await dialog.getByRole("button", { name: "Choose slice…" }).click();
  for (const more of [false, true]) {
    if (more) await page.evaluate(() => slicePage.onSuccess({ hasMore: true, totalCount: 2, nextCursorUpdatedAt: 1n, nextCursorAssetId: 72n }));
    const last = more ? page.getByRole("button", { name: "MORE", exact: true }) : page.getByRole("textbox", { name: "Search link targets" });
    await dialog.getByLabel("Task title").focus();
    await page.keyboard.press("Shift+Tab");
    assert.equal(await last.evaluate(el => el === document.activeElement), true, "backward wrap includes modal portal");
    await page.keyboard.press("Tab");
    assert.equal(await dialog.getByLabel("Task title").evaluate(el => el === document.activeElement), true, "forward wrap includes modal portal");
  }
  await page.getByRole("textbox", { name: "Search link targets" }).click();
  await page.getByRole("textbox", { name: "Search link targets" }).fill("follow-up");
  await page.locator(".note-link-picker-item").filter({ hasText: "Customer follow-up" }).click();
  assert.equal(await dialog.getByRole("button", { name: "#72 · Customer follow-up", exact: true }).count(), 1);
  await dialog.getByLabel("Task title").fill("Check selected membership");
  for (const theme of ["light", "dark"]) {
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 800 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      const bounds = await dialog.locator(".nrc-dialog").boundingBox();
      assert.ok(bounds.x >= 0 && bounds.x + bounds.width <= width);
      await dialog.locator(".nrc-dialog").screenshot({ path: `.amp/in/artifacts/new-task-${theme}-${width}.png` });
      if (width === 390) {
        assert.equal(await dialog.getByLabel("Task title").evaluate(el => getComputedStyle(el).fontSize), "16px");
        await dialog.getByRole("button", { name: "#72 · Customer follow-up", exact: true }).click();
        const search = page.getByRole("textbox", { name: "Search link targets" });
        await search.click();
        assert.equal(await search.evaluate(el => getComputedStyle(el).fontSize), "16px");
        await page.screenshot({ path: `.amp/in/artifacts/new-task-picker-${theme}-${width}.png` });
        await page.keyboard.press("Escape");
        assert.equal(await dialog.count(), 1, "Escape closes only the picker");
      }
    }
  }
  await dialog.getByRole("button", { name: "Create Task", exact: true }).click();
  await page.keyboard.press("Escape");
  assert.equal(await dialog.count(), 1, "pending create cannot be dismissed");
  await page.evaluate(() => taskCreates.at(-1).at(-1).onSuccess({ task: { id: 93n } }));
  assert.deepEqual(await page.evaluate(() => taskEdges.at(-1).slice(0, 6).map(String)), ["0", "2", "93", "1", "72", "7"]);
  await page.evaluate(() => taskEdges.at(-1).at(-1).onError({ message: "Slice unavailable" }));
  assert.match(await dialog.getByRole("status").textContent(), /Task #93 was created/);
  assert.equal(await dialog.getByRole("button", { name: "Create Task", exact: true }).isDisabled(), true);
  await dialog.getByRole("button", { name: "Close", exact: true }).click();
  await page.evaluate(() => promptNewTask());
  await dialog.getByLabel("Task title").fill("Default slice");
  await dialog.getByRole("button", { name: "Create Task", exact: true }).click();
  await page.evaluate(() => taskCreates.at(-1).at(-1).onSuccess({ task: { id: 94n } }));
  assert.equal(await page.evaluate(() => String(taskEdges.at(-1)[4])), "51");
  await page.evaluate(() => taskEdges.at(-1).at(-1).onSuccess());
  assert.equal(await dialog.count(), 0);
  await page.evaluate(() => { serverReady = true; promptNewTask(); });
  await dialog.getByLabel("Task title").fill("Retain rejected draft");
  await dialog.getByRole("button", { name: "Create Task", exact: true }).click();
  await page.evaluate(() => taskCreates.at(-1).at(-1).onError({ message: "Permission denied" }));
  assert.equal(await dialog.getByLabel("Task title").inputValue(), "Retain rejected draft");
  assert.equal(await dialog.getByRole("button", { name: "Create Task", exact: true }).isEnabled(), true);
  await dialog.getByRole("button", { name: "Create Task", exact: true }).click();
  await page.evaluate(() => { serverReady = false; taskCreates.at(-1).at(-1).onError({ message: "Connection closed" }); });
  assert.match(await dialog.getByRole("status").textContent(), /Creation may have succeeded/);
  assert.equal(await dialog.getByRole("button", { name: "Create Task", exact: true }).isDisabled(), true);
  await dialog.getByRole("button", { name: "Close", exact: true }).click();
  await page.clock.install();
  for (const phase of ["create", "membership"]) {
    await page.evaluate(() => { serverReady = true; promptNewTask(); });
    await dialog.getByLabel("Task title").fill("Unacknowledged request");
    await dialog.getByRole("button", { name: "Create Task", exact: true }).click();
    if (phase === "membership") await page.evaluate(() => taskCreates.at(-1).at(-1).onSuccess({ task: { id: 95n } }));
    const counts = await page.evaluate(() => [taskCreates.length, taskEdges.length]);
    await page.clock.fastForward(30001);
    assert.match(await dialog.getByRole("status").textContent(), /outcome is unknown/);
    if (phase === "membership") assert.match(await dialog.getByRole("status").textContent(), /Task #95 was created/);
    assert.equal(await dialog.getByRole("button", { name: "Create Task", exact: true }).isDisabled(), true);
    await dialog.getByRole("button", { name: "Close", exact: true }).click();
    await page.evaluate(phase => {
      if (phase === "create") taskCreates.at(-1).at(-1).onSuccess({ task: { id: 96n } });
      else taskEdges.at(-1).at(-1).onSuccess();
    }, phase);
    assert.deepEqual(await page.evaluate(() => [taskCreates.length, taskEdges.length]), counts, "late acknowledgements cannot advance abandoned requests");
    assert.equal(await dialog.count(), 0);
  }
  console.log("PASS: optional task slice, active-view default, clear/search/change, acknowledged membership, partial failure prevents duplicate creation");
  assert.deepEqual(errors, []);
  console.log("PASS: native modal isolation, focus/Tab/restore, confirm/prompt results, replacement, nested file dialog, busy write guard; both themes and widths");
} finally { await browser.close(); }
