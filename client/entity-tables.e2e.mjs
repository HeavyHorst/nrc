// Production renderers and CSS, with disposable browser-local fixtures.
// node client/entity-tables.e2e.mjs
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
  await page.waitForFunction(() => window.NRCAssets && window.NRCViewManager);
  await page.evaluate(() => {
    currentRoomId = 7n;
    currentWorkspaceId = "table-test";
    myNickname = "tester";
    const stamp = BigInt(Date.now()) * 1000000n;
    const assets = new Map();
    const tasks = new Map();
    for (let i = 1; i <= 3; i++) {
      const id = i === 3 ? 123456789012n : BigInt(i);
      tasks.set(id, { id, convId: 0n, title: `Task ${i}: Tabellenkonvention prüfen`, status: 1, priority: i * 60, color: 0, createdAt: stamp, attachments: [], assignee: "tester", project: "NRC" });
      assets.set(id, { assetId: id, convId: 0n, assetType: AssetType.Note, owner: "tester", createdAt: stamp, updatedAt: stamp, preview: JSON.stringify({ title: `Note ${i}: Interface-Prinzipien`, project: "NRC", tags: ["review"] }), payload: "Review content", attachments: [] });
      assets.set(id + 30n, { assetId: id + 30n, convId: 0n, assetType: AssetType.Reminder, owner: "tester", createdAt: stamp, updatedAt: stamp, attachments: [], payload: JSON.stringify({ title: `Reminder ${i}: UI-Review vorbereiten`, deadline_at: String(stamp + BigInt(i - 2) * 86400000000000n), window_start_at: "0", note_asset_id: "1" }) });
    }
    Object.assign(tasks.get(123456789012n), {
      status: 2,
      priority: 240,
      color: 1,
      description: "Validate the responsive two-line register with complete operational metadata.",
      dueAt: stamp + 7n * 86400000000000n,
      blockedBy: 2n,
      externalRef: "https://example.com/nrc/register-review",
      attachments: [
        { fileId: "register-spec", filename: "register-spec.pdf", mimeType: "application/pdf", size: 248000n },
        { fileId: "register-capture", filename: "register-capture.png", mimeType: "image/png", size: 84200n },
      ],
    });
    for (let i = 1; i <= 2; i++) {
      const commentId = 9000n + BigInt(i);
      assets.set(commentId, {
        assetId: commentId, convId: 0n, assetType: AssetType.Comment,
        parentType: ParentType.Task, parentId: 123456789012n,
        owner: i === 1 ? "tester" : "reviewer", createdAt: stamp + BigInt(i), updatedAt: stamp + BigInt(i),
        preview: `Register review ${i}`, payload: `Register review ${i}`, attachments: [],
      });
    }
    NRCAssets.roomAssets.set(0n, assets);
    roomTasks.set(0n, tasks);
    Object.assign(getNotesPaginationState(0n), { initialized: true, loading: false, hasMore: false, totalCount: 3 });
    invalidateNotesList(0n);
    taskListDirty = true;
  });
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["lupine", "matte-black"]) {
    for (const width of [1600, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
      const borders = [];
      for (const view of ["tasks", "notes", "reminders"]) {
        await page.evaluate(async view => {
          await NRCInspector.close();
          if (view === "tasks") { setTaskGrouping("flat"); showKanban(); }
          else if (view === "notes") showNotesView();
          else NRCViewManager.setActiveView(view);
        }, view);
        const selector = { tasks: "#taskListBody tr[data-task-id]", notes: "#notesList .note-card", reminders: "#reminderQueueBody .reminder-row" }[view];
        await page.locator(selector).first().waitFor({ state: "visible" });
        assert.equal(await page.locator(selector).count(), 3);
        const dimensions = await page.locator(selector).first().evaluate(row => {
          const css = getComputedStyle(row);
          return { height: row.getBoundingClientRect().height, border: css.borderBottom, width: css.borderBottomWidth };
        });
        assert.equal(dimensions.width, "1px", `${view} row separator at ${width}`);
        if (width > 768) {
          assert.ok(Math.abs(dimensions.height - 34) < 1, `${view} row height: ${dimensions.height}`);
          borders.push(dimensions.border);
          const headerSelector = { tasks: ".task-table thead tr", notes: ".notes-list-header", reminders: ".reminder-list-header" }[view];
          const header = page.locator(headerSelector);
          const geometry = await header.evaluate(el => [...el.children].slice(0, 2).map(cell => ({ width: cell.getBoundingClientRect().width, align: getComputedStyle(cell).textAlign })));
          assert.equal(geometry[0].width, 0, `${view} legacy selection header takes no space`);
          assert.deepEqual(await page.locator(selector).locator(".col-marker, .note-marker, .reminder-marker").evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().width)), [0, 0, 0], `${view} legacy selection cells take no space`);
          assert.ok(Math.abs(geometry[1].width - 48) < 1, `${view} ID width: ${geometry[1].width}`);
          assert.equal(geometry[1].align, "left", `${view} ID header alignment`);
          assert.deepEqual(await page.locator(selector).locator(".col-id, .note-id, .reminder-id").evaluateAll(cells => cells.map(cell => getComputedStyle(cell).textAlign)), ["left", "left", "left"], `${view} short and long IDs share left alignment`);
          const longId = page.locator(selector).locator(".col-id, .note-id, .reminder-id").filter({ hasText: "1234567890" });
          assert.deepEqual(await longId.evaluate(el => ({ overflow: getComputedStyle(el).overflowX, ellipsis: getComputedStyle(el).textOverflow, title: el.title.includes(el.textContent) })), { overflow: "hidden", ellipsis: "ellipsis", title: true }, `${view} long IDs stay inside their column and expose the full value`);
          if (view === "notes") assert.equal(await longId.evaluate(el => getComputedStyle(el).display), "block", "Flex text clips the ID suffix without an ellipsis");
          if (view === "tasks") {
            const renameOffsets = await page.locator(`${selector} .col-title`).evaluateAll(cells => cells.map(cell => {
              const cellRight = cell.getBoundingClientRect().right - parseFloat(getComputedStyle(cell).paddingRight);
              const renameRight = cell.querySelector("nrc-inline-field").getBoundingClientRect().right;
              return Math.abs(cellRight - renameRight);
            }));
            assert.ok(renameOffsets.every(offset => offset < 1), `Task rename controls align at the title column end: ${renameOffsets.join(", ")}`);
          }
          if (view === "notes") {
            const renameRights = await page.locator(`${selector} .note-title nrc-inline-field`).evaluateAll(fields => fields.map(field => field.getBoundingClientRect().right));
            assert.ok(Math.max(...renameRights) - Math.min(...renameRights) < 1, `Note rename controls share one column position: ${renameRights.join(", ")}`);
          }
          const handle = header.getByRole("separator", { name: "Resize ID column", exact: true });
          await handle.focus();
          await page.keyboard.press("ArrowRight");
          assert.equal(await handle.getAttribute("aria-valuenow"), "56");
          assert.ok(Math.abs(await header.locator(":scope > :nth-child(2)").evaluate(cell => cell.getBoundingClientRect().width) - 56) < 1, `${view} rendered ID width follows resize`);
          if (view === "reminders") {
            await page.evaluate(() => renderReminderQueue());
            assert.equal(await handle.getAttribute("aria-valuenow"), "56", "Reminder resize survives row refresh");
            await handle.focus();
          }
          await page.keyboard.press("Home");
          assert.equal(await handle.getAttribute("aria-valuenow"), "48");
          assert.ok(Math.abs(await header.locator(":scope > :nth-child(2)").evaluate(cell => cell.getBoundingClientRect().width) - 48) < 1, `${view} rendered ID width follows reset`);
        }
        if (width <= 768 && view === "tasks") {
          const renameRights = await page.locator(`${selector} .col-title nrc-inline-field`).evaluateAll(fields => fields.map(field => field.getBoundingClientRect().right));
          assert.ok(Math.max(...renameRights) - Math.min(...renameRights) < 1, `Mobile task rename controls share one position: ${renameRights.join(", ")}`);
        }
        if (width <= 768 && view === "notes") {
          const renameRights = await page.locator(`${selector} .note-title nrc-inline-field`).evaluateAll(fields => fields.map(field => field.getBoundingClientRect().right));
          assert.ok(Math.max(...renameRights) - Math.min(...renameRights) < 1, `Mobile note rename controls share one position: ${renameRights.join(", ")}`);
        }
        assert.equal(await page.locator(selector).getByRole("button", { name: /delete/i }).count(), 0);
        await page.screenshot({ path: `.amp/in/artifacts/entity-${view}-${theme}-${width}.png` });
      }
      if (width > 768) assert.equal(new Set(borders).size, 1, "All desktop separators use the same token");
      const title = page.locator('[data-reminder-row-id="32"] .reminder-title');
      await title.focus();
      await page.keyboard.press("Enter");
      await page.locator("#reminderDetailDelete").waitFor({ state: "visible" });
      assert.equal(await page.locator('[data-reminder-row-id="32"] .reminder-marker').textContent(), "›");
      assert.equal(await page.locator('[data-reminder-row-id="32"] .reminder-title').getAttribute("aria-current"), "true");
      assert.equal(await page.locator(".reminder-row-selected").count(), 1);
      await page.screenshot({ path: `.amp/in/artifacts/entity-selected-${theme}-${width}.png` });
      // Cancel the real confirmation: it must identify the selected reminder,
      // and neither the local asset nor the selected row may disappear.
      await page.locator("#reminderDetailDelete").click();
      const dialog = page.locator(".nrc-dialog-backdrop .nrc-dialog");
      await dialog.waitFor({ state: "visible" });
      assert.match(await dialog.innerText(), /Reminder 2: UI-Review vorbereiten/);
      await page.keyboard.press("Escape");
      assert.equal(await page.evaluate(() => NRCAssets.roomAssets.get(0n).has(32n)), true);
      await page.evaluate(() => NRCInspector.close());
      if (width === 390) {
        assert.equal(await page.locator("#reminderQueueBody").evaluate(el => { el.scrollLeft = 100; return el.scrollLeft; }), 100);
      }
    }
  }
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.evaluate(() => {
    document.documentElement.dataset.theme = "lupine";
    // Resize restores the persisted width. An inline override races with the
    // pending mobile-to-desktop resize event and falls back to the default.
    localStorage.setItem("nrc.inspector.width", "720");
    window.dispatchEvent(new Event("resize"));
  });
  for (const view of ["tasks", "notes"]) {
    await page.evaluate(async view => {
      if (view === "tasks") { setTaskGrouping("flat"); showKanban(); }
      else showNotesView();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    }, view);
    const host = page.locator(view === "tasks" ? "#taskListView" : "#notesPanel .notes-container");
    const row = page.locator(view === "tasks" ? "#taskListBody tr[data-task-id]" : "#notesList .note-card").first();
    await row.click();
    await page.waitForFunction(view => document.querySelector(view === "tasks" ? "#taskListBody tr[data-task-id]" : "#notesList .note-card")
      ?.classList.contains(view === "tasks" ? "task-row-selected" : "note-selected"), view);
    if (view === "tasks") {
      assert.deepEqual(await row.locator(":scope > :is(.col-status, .col-priority, .col-assignee, .col-blk, .col-ref, .col-att, .col-cmt)").allTextContents(),
        ["240", "IN PROGRESS", "tester", "#2", "https://example.com/nrc/register-review", "2", "2"], "compact task fixture fills every status and signal field");
      assert.notEqual(await row.locator(".col-due").textContent(), "—", "compact task fixture includes a due date");
      await page.getByText("Validate the responsive two-line register with complete operational metadata.", { exact: true }).waitFor();
    }
    const hostWidth = (await host.boundingBox()).width;
    const inspectorWidth = (await page.locator("#inspector").boundingBox()).width;
    assert.equal(inspectorWidth, 720, `${view} restores the persisted wide Inspector`);
    assert.ok(hostWidth <= 700, `${view} fixture enters the compact container range (${hostWidth}px list / ${inspectorWidth}px Inspector)`);
    assert.equal((await row.boundingBox()).height, 50, `${view} uses the two-line desktop row beside a wide Inspector`);
    assert.equal(await row.evaluate(el => getComputedStyle(el).borderBottomWidth), "1px", `${view} compact row retains its shared divider`);
    const compact = await row.evaluate((element, view) => {
      const title = element.querySelector(view === "tasks" ? ".col-title" : ".note-header").getBoundingClientRect();
      const metadata = element.querySelector(view === "tasks" ? ".col-status" : ".note-project").getBoundingClientRect();
      const hidden = element.querySelector(view === "tasks" ? ".col-project" : ".note-updated");
      return {
        titleAboveMetadata: title.bottom <= metadata.top + 1,
        hiddenSecondaryField: getComputedStyle(hidden).display === "none",
        overflow: element.scrollWidth - element.clientWidth,
      };
    }, view);
    assert.deepEqual({ ...compact, overflow: compact.overflow > 1 }, { titleAboveMetadata: true, hiddenSecondaryField: true, overflow: false }, `${view} keeps identity above aligned metadata without overflow (${compact.overflow}px)`);
    await page.screenshot({ path: `.amp/in/artifacts/entity-${view}-compact-inspector.png` });
  }
  await page.evaluate(() => { document.documentElement.dataset.theme = "matte-black"; });
  for (const view of ["tasks", "notes"]) {
    await page.evaluate(async view => {
      if (view === "tasks") { setTaskGrouping("flat"); showKanban(); }
      else showNotesView();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    }, view);
    const row = page.locator(view === "tasks" ? "#taskListBody tr[data-task-id]" : "#notesList .note-card").first();
    await row.click();
    await page.waitForFunction(view => NRCInspector.current()?.type === (view === "tasks" ? "task" : "note"), view);
    assert.equal((await row.boundingBox()).height, 50, `${view} keeps the compact register geometry in the dark theme`);
    assert.equal(await row.evaluate(element => element.scrollWidth - element.clientWidth > 1), false, `${view} dark compact row does not overflow`);
    await page.screenshot({ path: `.amp/in/artifacts/entity-${view}-compact-inspector-dark.png` });
  }
  await page.evaluate(() => {
    localStorage.setItem("nrc.inspector.width", "440");
    window.dispatchEvent(new Event("resize"));
  });
  for (const view of ["tasks", "notes"]) {
    await page.evaluate(async view => {
      if (view === "tasks") { setTaskGrouping("flat"); showKanban(); }
      else showNotesView();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    }, view);
    const host = page.locator(view === "tasks" ? "#taskListView" : "#notesPanel .notes-container");
    const row = page.locator(view === "tasks" ? "#taskListBody tr[data-task-id]" : "#notesList .note-card").first();
    assert.equal((await page.locator("#inspector").boundingBox()).width, 440, `${view} restores the persisted narrow Inspector`);
    assert.ok((await host.boundingBox()).width > 700, `${view} fixture leaves the compact container range`);
    assert.ok(Math.abs((await row.boundingBox()).height - 34) < 1, `${view} restores the one-line desktop row when the Inspector narrows`);
  }
  // Old grid layouts contain a 24px locked marker. Collapse only that column;
  // preserve an intentionally widened ID and asymmetric title width.
  const restored = await page.evaluate(() => {
    const host = document.createElement("div");
    host.id = "resize-migration-test";
    document.body.append(host);
    localStorage.setItem("resize-migration-test", JSON.stringify([24, 112, 333]));
    let widths;
    NRCColumnResize.init({ root: "#resize-migration-test", headers: "span", storageKey: "resize-migration-test", defaults: [0, 48, 260], minimums: [16, 48, 140], locked: [0], apply: (_host, value) => { widths = value; } });
    host.remove();
    localStorage.removeItem("resize-migration-test");
    return widths;
  });
  assert.deepEqual(restored, [0, 112, 333]);
  assert.deepEqual(errors, []);
  // An asymmetric token override catches a family reverting to panel/content
  // borders even when those happen to look alike in a particular theme.
  await page.goto("http://nrc.test/design-system/index.html");
  await page.evaluate(() => {
    const fixtures = document.createElement("div");
    fixtures.id = "divider-fixtures";
    fixtures.innerHTML = `<div class="file-assets-picker-row">File picker result</div>
      <section class="file-assets-section"><div class="file-assets-row">First file</div><div class="file-assets-row">Last file</div></section>
      <table class="task-table"><tbody><tr aria-hidden="true"><td></td></tr></tbody></table>`;
    document.body.append(fixtures);
  });
  for (const theme of ["light", "dark"]) {
    for (const width of [1600, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => {
        document.documentElement.dataset.theme = theme;
        document.documentElement.style.setProperty("--border-list", "rgb(13, 57, 91)");
      }, theme);
      for (const selector of [".note-card", ".reminder-row", ".attention-row", '.task-table tbody tr:not([aria-hidden="true"])', ".customer-row", ".customer-event", ".slice-row", ".file-assets-picker-row", "#divider-fixtures .file-assets-row:first-child", ".customer-contact", ".slice-member"]) {
        const rows = page.locator(selector);
        assert.ok(await rows.count(), `${selector} has a catalogue fixture`);
        const edge = [".customer-contact", ".slice-member"].includes(selector) ? "borderTop" : "borderBottom";
        const borders = await rows.evaluateAll((rows, edge) => rows.map(row => getComputedStyle(row)[edge]), edge);
        assert.ok(borders.every(border => border === "1px solid rgb(13, 57, 91)"), `${selector} uses shared divider at ${theme}/${width}: ${borders}`);
      }
      for (const selector of ['#divider-fixtures tr[aria-hidden="true"]', "#divider-fixtures .file-assets-row:last-child"]) {
        assert.equal(await page.locator(selector).evaluate(row => getComputedStyle(row).borderBottomWidth), "0px", `${selector} remains borderless`);
      }
    }
  }
  console.log("PASS: collapsed legacy markers, 48px left-aligned IDs and headers, resize/reset/persistence, long IDs, shared rows, both themes and widths, selection and detail-only delete");
} finally {
  await browser.close();
}
