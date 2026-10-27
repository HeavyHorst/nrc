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

async function verifyIndependentColumns(view, theme) {
  const config = {
    tasks: ['#taskListView', 'thead th', 3, '#taskColumnsReset', '#taskListBody tr[data-task-id] .col-title'],
    notes: ['#notesPanel .notes-container', '.notes-list-header > div', 2, '#noteColumnsReset', '#notesList .note-header'],
    reminders: ['#reminderQueueBody', '.reminder-list-header > span', 2, '#reminderColumnsReset', '#reminderQueueBody .reminder-title'],
    tickets: ['#ticketsRegister', 'thead th', 1, '#ticketColumnsReset', '#ticketsList tr[data-ticket] .col-title'],
  }[view];
  const [hostSelector, cellsSelector, titleIndex, resetSelector, contentSelector] = config;
  const host = page.locator(hostSelector);
  const cells = host.locator(cellsSelector);
  const widths = () => cells.evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().width));
  const reset = page.locator(resetSelector);
  await reset.click();
  await host.evaluate(el => { el.scrollLeft = 0; });
  const initial = await widths();
  const titleHandle = cells.nth(titleIndex).getByRole('separator');
  const box = await titleHandle.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2 + 93, box.y + box.height / 2, { steps: 12 });
  await page.mouse.up();
  const grown = await widths();
  initial.forEach((width, index) => assert.ok(Math.abs(grown[index] - width - (index === titleIndex ? 93 : 0)) < 1, `${view}: pointer changes only TITLE`));
  if (view === 'reminders') {
    await page.evaluate(() => renderReminderQueue());
    const refreshed = await widths();
    grown.forEach((width, index) => assert.ok(Math.abs(refreshed[index] - width) < 1, 'reminder row refresh preserves manual widths'));
  }
  assert.equal(await host.evaluate(el => el.scrollWidth > el.clientWidth + 80), true, `${view}: wider table scrolls`);
  await host.screenshot({ path: `.amp/in/artifacts/excel-${view}-${theme}-resized.png` });
  const viewport = page.viewportSize();
  await page.setViewportSize({ width: 2100, height: viewport.height });
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const wider = await widths();
  grown.forEach((width, index) => assert.ok(Math.abs(wider[index] - width) < 1, `${view}: manual widths do not stretch with the window`));
  await page.setViewportSize({ width: 390, height: viewport.height });
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert.equal(await host.evaluate(el => el.scrollWidth <= el.clientWidth + 1), view !== 'reminders', `${view}: mobile keeps its existing stacked or scrolling layout`);
  await host.screenshot({ path: `.amp/in/artifacts/excel-${view}-${theme}-mobile.png` });
  await page.setViewportSize(viewport);
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const returned = await widths();
  grown.forEach((width, index) => assert.ok(Math.abs(returned[index] - width) < 1, `${view}: desktop widths survive mobile layout`));

  // Auto-fit grows a deliberately narrow title and leaves an edited neighbor alone.
  await titleHandle.focus();
  for (let i = 0; i < 160; i++) await page.keyboard.press('ArrowLeft');
  const narrow = await widths();
  await titleHandle.dblclick();
  const fitted = await widths();
  assert.ok(fitted[titleIndex] > narrow[titleIndex] + 20, `${view}: content fit grows a truncated title`);
  fitted.forEach((width, index) => { if (index !== titleIndex) assert.ok(Math.abs(width - narrow[index]) < 1, `${view}: content fit preserves other columns`); });
  assert.equal(await page.locator(contentSelector).evaluateAll(cells => cells.every(cell => [ ...(cell.matches('button') ? [cell] : []), ...cell.querySelectorAll('button')].every(button => button.scrollWidth <= button.clientWidth + 1))), true, `${view}: fitted titles are not truncated`);
  await host.screenshot({ path: `.amp/in/artifacts/excel-${view}-${theme}-fit.png` });
  const last = cells.last().getByRole('separator');
  const lastBefore = (await widths()).at(-1);
  await last.focus(); await page.keyboard.press('ArrowRight');
  assert.ok(Math.abs((await widths()).at(-1) - lastBefore - 8) < 1, `${view}: final column is resizable`);
  await reset.click();
  const restored = await widths();
  initial.forEach((width, index) => assert.ok(Math.abs(restored[index] - width) < 1, `${view}: explicit reset restores automatic layout`));
}

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
    window.NRCTaskQuery = undefined; // Render the fixture cache, without server paging.
    localStorage.setItem('nrc.note.columns.v4', JSON.stringify([0, 600, 3000, 550, 500]));
    localStorage.setItem('nrc.task.columns.v2', JSON.stringify([0, 48, 64, 3000, 104, 86, 48, 64, 48, 48, 70, 72]));
    localStorage.setItem('nrc.reminder.columns.v1', JSON.stringify([0, 48, 3000, 160, 130, 130, 180]));
    const stamp = BigInt(Date.now()) * 1000000n;
    const assets = new Map();
    const tasks = new Map();
    for (let i = 1; i <= 3; i++) {
      const id = i === 3 ? 123456789012n : BigInt(i);
      tasks.set(id, { id, convId: 0n, title: `Task ${i}: Tabellenkonvention prüfen`, status: 1, priority: i * 60, color: 0, createdAt: stamp, attachments: [], assignee: "tester", project: "NRC" });
      assets.set(id, { assetId: id, convId: 0n, assetType: AssetType.Note, owner: "tester", createdAt: stamp, updatedAt: stamp, preview: JSON.stringify({ title: `Note ${i}: Interface-Prinzipien`, project: "NRC", tags: ["review"] }), payload: "Review content", attachments: [] });
      assets.set(id + 30n, { assetId: id + 30n, convId: 0n, assetType: AssetType.Reminder, owner: "tester", createdAt: stamp, updatedAt: stamp, attachments: [], payload: JSON.stringify({ title: `Reminder ${i}: UI-Review vorbereiten`, visibility: i === 1 ? undefined : i === 2 ? "personal" : "team", deadline_at: String(stamp + BigInt(i - 2) * 86400000000000n), window_start_at: "0", note_asset_id: "1" }) });
    }
    Object.assign(tasks.get(123456789012n), {
      status: 2,
      priority: 240,
      color: 4,
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
        if (theme === 'lupine' && width === 1600) {
          const host = page.locator({ tasks: '#taskListView', notes: '#notesPanel .notes-container', reminders: '#reminderQueueBody' }[view]);
          const key = { tasks: 'nrc.task.columns.v2', notes: 'nrc.note.columns.v4', reminders: 'nrc.reminder.columns.v1' }[view];
          const saved = await page.evaluate(key => localStorage.getItem(key), key);
          for (const viewportWidth of [1600, 2560, 1500, 5200, 1600]) {
            await page.setViewportSize({ width: viewportWidth, height: 1000 });
            await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
            await page.waitForFunction(selector => { const el = document.querySelector(selector); return el.scrollWidth <= el.clientWidth + 1; }, { tasks: '#taskListView', notes: '#notesPanel .notes-container', reminders: '#reminderQueueBody' }[view]);
            assert.equal(await page.evaluate(key => localStorage.getItem(key), key), saved, `${view}: fitting never overwrites saved widths`);
            if (view === 'tasks' && viewportWidth === 1600) {
              assert.ok(Math.abs(await host.locator('th.col-status').evaluate(el => el.getBoundingClientRect().width) - 104) < 1, 'oversized saved TITLE shrinks before STATUS');
              assert.ok(Math.abs(await host.locator('th.col-color').evaluate(el => el.getBoundingClientRect().width) - 100) < 1, 'oversized saved TITLE does not squeeze CAT');
              const category = host.locator('td.col-color button').filter({ hasText: 'DEFERRED' });
              assert.equal(await category.evaluate(el => el.scrollWidth <= el.clientWidth), true, 'longest category label fits without truncation');
            }
            if (viewportWidth === 5200 && view === 'notes') {
              assert.ok(Math.abs(await page.locator('.notes-list-header > :nth-child(4)').evaluate(el => el.getBoundingClientRect().width) - 550) < 1, 'wide window restores preferred tag width');
            }
          }
          if (view !== 'reminders') {
            await page.evaluate(view => NRCInspector.openEntity({ type: view === 'tasks' ? 'task' : 'note', id: 1n }), view);
            await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
            assert.equal(await host.evaluate(el => el.scrollWidth <= el.clientWidth + 1), true, `${view}: oversized preferences fit beside Inspector`);
            assert.equal(await page.evaluate(key => localStorage.getItem(key), key), saved);
            await page.evaluate(() => NRCInspector.close());
            await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
          }
          await host.screenshot({ path: `.amp/in/artifacts/fit-${view}-saved-widths.png` });
          const reset = host.getByRole('separator', { name: 'Resize ID column', exact: true });
          const compressed = Number(await reset.getAttribute('aria-valuenow'));
          const cells = host.locator({ tasks: 'thead th', notes: '.notes-list-header > div', reminders: '.reminder-list-header > span' }[view]);
          const beforeResize = await cells.evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().right));
          // Notes have an oversized ID and TITLE is already at its minimum.
          const direction = view === 'notes' ? -1 : 1;
          await reset.focus(); await page.keyboard.press(direction > 0 ? 'ArrowRight' : 'ArrowLeft');
          assert.ok((Number(await reset.getAttribute('aria-valuenow')) - compressed) * direction > 0, `${view}: compressed ID follows the requested direction`);
          const afterResize = await cells.evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().right));
          beforeResize.forEach((value, index) => {
            const shift = index >= 1 ? direction * 8 : 0;
            if (index !== 1) assert.ok(Math.abs(afterResize[index] - value - shift) < 1, `${view}: other columns retain their widths`);
          });
          if (view === 'notes') {
            for (const defaults of [false, true]) {
              if (defaults) { await reset.focus(); await page.keyboard.press('Home'); }
              const preferences = await page.evaluate(key => localStorage.getItem(key), key);
              const tags = host.getByRole('separator', { name: 'Resize TAGS column', exact: true });
              const before = await tags.boundingBox();
              await tags.focus(); await page.keyboard.press('ArrowRight');
              const after = await tags.boundingBox();
              assert.ok(Math.abs(after.x - before.x - 8) < 1, `TAGS boundary moves 8px at ${defaults ? 'default' : 'compressed'} widths`);
              await page.mouse.move(after.x + after.width / 2, after.y + after.height / 2);
              await page.mouse.down();
              await page.mouse.move(after.x + after.width / 2 - 12, after.y + after.height / 2);
              await page.mouse.up();
              assert.ok(Math.abs((await tags.boundingBox()).x - before.x + 4) < 1, 'TAGS pointer moves the grabbed boundary');
              if (preferences) {
                const changed = await page.evaluate(key => JSON.parse(localStorage.getItem(key)).widths, key);
                JSON.parse(preferences).widths.slice(0, 3).forEach((value, index) => assert.ok(Math.abs(changed[index] - value) < 1));
              }
            }
          }
          await reset.focus(); await page.keyboard.press('Home');
        }
        const dimensions = await page.locator(selector).first().evaluate(row => {
          const css = getComputedStyle(row);
          return { height: row.getBoundingClientRect().height, border: css.borderBottom, width: css.borderBottomWidth };
        });
        assert.equal(dimensions.width, "1px", `${view} row separator at ${width}`);
        if (width > 768) {
          if (view === 'reminders') assert.ok(Math.abs(dimensions.height - 34) < 1, `${view} row height: ${dimensions.height}`);
          else assert.ok(dimensions.height >= 44, `${view} has space for title and metadata: ${dimensions.height}`);
          borders.push(dimensions.border);
          const headerSelector = { tasks: ".task-table:has(#taskListBody) thead tr", notes: ".notes-list-header", reminders: ".reminder-list-header" }[view];
          const header = page.locator(headerSelector);
          assert.equal(await header.evaluate(el => Math.abs(el.lastElementChild.getBoundingClientRect().right - el.getBoundingClientRect().right) <= 1), true, `${view} columns fill the header without a trailing empty strip`);
          assert.equal(await page.locator(selector).first().evaluate(el => Math.abs(el.lastElementChild.getBoundingClientRect().right - el.getBoundingClientRect().right) <= 1), true, `${view} columns fill each row without a trailing empty strip`);
          const geometry = await header.evaluate(el => [...el.children].slice(0, 2).map(cell => ({ width: cell.getBoundingClientRect().width, align: getComputedStyle(cell).textAlign })));
          assert.equal(geometry[0].width, 0, `${view} legacy selection header takes no space`);
          assert.deepEqual(await page.locator(selector).locator(".col-marker, .note-marker, .reminder-marker").evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().width)), [0, 0, 0], `${view} legacy selection cells take no space`);
          assert.ok(Math.abs(geometry[1].width - 48) < 1, `${view} ID width: ${geometry[1].width}`);
          assert.equal(geometry[1].align, "left", `${view} ID header alignment`);
          assert.deepEqual(await page.locator(selector).locator(".col-id, .note-id, .reminder-id").evaluateAll(cells => cells.map(cell => getComputedStyle(cell).textAlign)), ["left", "left", "left"], `${view} short and long IDs share left alignment`);
          const longId = page.locator(selector).locator(".col-id, .note-id, .reminder-id").filter({ hasText: "1234567890" });
          assert.deepEqual(await longId.evaluate(el => ({ overflow: getComputedStyle(el).overflowX, ellipsis: getComputedStyle(el).textOverflow, title: el.title.includes(el.textContent) })), { overflow: "hidden", ellipsis: "ellipsis", title: true }, `${view} long IDs stay inside their column and expose the full value`);
          if (view === "notes") assert.equal(await longId.evaluate(el => getComputedStyle(el).display), "block", "Flex text clips the ID suffix without an ellipsis");
          if (view === "tasks" || view === "notes") {
            const titles = page.locator(`${selector} nrc-inline-field[data-control$="-title"] button`);
            assert.equal(await titles.count(), 3);
            assert.ok((await titles.allTextContents()).every(title => title && title !== "RENAME"), "the title itself is the edit control");
          }
          const handle = header.getByRole("separator", { name: "Resize ID column", exact: true });
          await handle.focus();
          await page.keyboard.press("ArrowRight");
          const resizedId = 56;
          assert.equal(await handle.getAttribute("aria-valuenow"), String(resizedId));
          assert.ok(Math.abs(await header.locator(":scope > :nth-child(2)").evaluate(cell => cell.getBoundingClientRect().width) - resizedId) < 1, `${view} rendered ID width follows resize`);
          if (view === "reminders") {
            await page.evaluate(() => renderReminderQueue());
            assert.equal(await handle.getAttribute("aria-valuenow"), "56", "Reminder resize survives row refresh");
            await handle.focus();
          }
          await page.keyboard.press("Home");
          assert.equal(await handle.getAttribute("aria-valuenow"), "48");
          assert.ok(Math.abs(await header.locator(":scope > :nth-child(2)").evaluate(cell => cell.getBoundingClientRect().width) - 48) < 1, `${view} rendered ID width follows reset`);
          {
            const titleHandle = header.getByRole('separator', { name: 'Resize TITLE column', exact: true });
            const titleCell = header.locator(`:scope > :nth-child(${view === 'tasks' ? 4 : 3})`);
            const before = (await titleCell.boundingBox()).width;
            const handleBox = await titleHandle.boundingBox();
            const cellBox = await titleCell.boundingBox();
            assert.ok(Math.abs(handleBox.height - cellBox.height) <= 1, `${view} title handle spans the header height`);
            assert.ok(Math.abs(handleBox.x + handleBox.width / 2 - (cellBox.x + cellBox.width)) <= 1, `${view} title handle sits on the column boundary`);
            if (view === 'tasks') {
              await page.mouse.move(handleBox.x + handleBox.width / 2, handleBox.y + handleBox.height / 2);
              await page.mouse.down();
              await page.mouse.move(handleBox.x + handleBox.width / 2 - 37, handleBox.y + handleBox.height / 2);
              await page.mouse.move(handleBox.x + handleBox.width / 2, handleBox.y + handleBox.height / 2);
              assert.ok(Math.abs((await titleCell.boundingBox()).width - before) < 1, 'returning the pointer to its start restores the boundary');
              await page.mouse.move(handleBox.x + handleBox.width / 2 - 37, handleBox.y + handleBox.height / 2);
              await page.mouse.up();
              assert.ok(Math.abs((await titleCell.boundingBox()).width - (before - 37)) < 1, 'pointer moves TITLE boundary without an empty strip');
              await page.locator('#taskColumnsReset').click();
              assert.equal((await titleCell.boundingBox()).width, before, 'RESET COLUMNS restores automatic width');
            }
            await titleHandle.focus(); await page.keyboard.press('ArrowRight');
            assert.ok(Math.abs((await titleCell.boundingBox()).width - (before + 8)) < 1, 'keyboard grows TITLE by 8px');
            const box = await titleHandle.boundingBox();
            await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
            await page.mouse.down(); await page.mouse.move(box.x + box.width / 2 - 137, box.y + box.height / 2); await page.mouse.up();
            assert.ok(Math.abs((await titleCell.boundingBox()).width - (before - 129)) < 1, `${view} pointer moves TITLE without overflowing the register`);
            await header.screenshot({ path: `.amp/in/artifacts/resize-${view}-${theme}-manual.png` });
            {
              await titleHandle.focus(); await page.keyboard.press('ArrowRight');
              assert.ok(Math.abs((await titleCell.boundingBox()).width - (before - 121)) < 1, 'keyboard resize starts at the current boundary');
              await page.setViewportSize({ width: 1900, height: 1000 });
              assert.ok(Math.abs((await titleCell.boundingBox()).width - (before - 121)) < 1, `${view}: window resize preserves exact manual width`);
              const hostSelector = { tasks: '#taskListView', notes: '#notesPanel .notes-container', reminders: '#reminderQueueBody' }[view];
              await page.locator(hostSelector).screenshot({ path: `.amp/in/artifacts/${view}-table-fill-${theme}.png` });
              if (view !== 'reminders') {
                await page.setViewportSize({ width: 390, height: 1000 });
                assert.equal(await page.locator(hostSelector).evaluate(host => host.scrollWidth <= host.clientWidth + 1), true, 'manual desktop widths do not overflow the mobile register');
                await page.setViewportSize({ width: 900, height: 1000 });
                assert.equal(await page.locator(hostSelector).evaluate(host => host.scrollWidth <= host.clientWidth + 1), true, 'manual desktop widths do not overflow the compact register');
              }
              await page.setViewportSize({ width, height: 1000 });
              await page.waitForFunction(({ selector, before }) => Math.abs(document.querySelector(selector).getBoundingClientRect().width - before) < 1, { selector: `${headerSelector} > :nth-child(${view === 'tasks' ? 4 : 3})`, before: before - 121 });
            }
            await titleHandle.focus(); await page.keyboard.press('Home');
            assert.equal((await titleCell.boundingBox()).width, before, 'reset restores automatic/default title width');
            await header.screenshot({ path: `.amp/in/artifacts/resize-${view}-${theme}-default.png` });
          }
          await verifyIndependentColumns(view, theme);
        }
        assert.equal(await page.locator(selector).getByRole("button", { name: /delete/i }).count(), 0);
        await page.screenshot({ path: `.amp/in/artifacts/entity-${view}-${theme}-${width}.png` });
      }
      if (width > 768) assert.equal(new Set(borders).size, 1, "All desktop separators use the same token");
      const title = page.locator('[data-reminder-row-id="32"] .reminder-title');
      await title.focus();
      await page.keyboard.press("Enter");
      await page.locator("#reminderDetailDelete").waitFor({ state: "visible" });
      assert.equal(await page.locator("#inspectorHeader #reminderDetailDelete").count(), 1, "Reminder delete belongs to the shared header actions");
      assert.equal(await page.locator('[data-reminder-row-id="32"] .reminder-marker').textContent(), "›");
      assert.equal(await page.locator('[data-reminder-row-id="32"] .reminder-title').getAttribute("aria-current"), "true");
      assert.equal(await page.locator(".reminder-row-selected").count(), 1);
      assert.match(await page.locator(".reminder-detail-panel").innerText(), /VISIBILITY · FIXED AT CREATION\s+PERSONAL/);
      assert.equal(await page.locator(".reminder-detail-panel select[id*=Visibility]").count(), 0);
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
      await page.evaluate(() => { void createReminder(); });
      const personalRadio = page.getByRole("radio", { name: "PERSONAL — ONLY YOU" });
      const teamRadio = page.getByRole("radio", { name: "TEAM — WORKSPACE" });
      await personalRadio.waitFor({ state: "visible" });
      assert.equal(await personalRadio.isChecked(), true);
      assert.equal(await teamRadio.isChecked(), false);
      assert.equal(await page.getByRole("group", { name: "VISIBILITY · FIXED AT CREATION" }).count(), 1);
      await page.screenshot({ path: `.amp/in/artifacts/reminder-create-${theme}-${width}.png` });
      await personalRadio.focus();
      await page.keyboard.press("ArrowDown");
      assert.equal(await teamRadio.isChecked(), true);
      assert.equal(await personalRadio.isChecked(), false);
      await page.screenshot({ path: `.amp/in/artifacts/reminder-create-team-${theme}-${width}.png` });
      await page.keyboard.press("Escape");
      if (width === 390) {
        assert.equal(await page.locator("#reminderQueueBody").evaluate(el => { el.scrollLeft = 100; return el.scrollLeft; }), 100);
      }
    }
  }
  for (const visibility of ["personal", "team"]) {
    await page.evaluate(() => {
      window.reminderCreated = null;
      NRCAssets.sendCreateAsset = (...args) => { window.reminderCreated = { preview: args[4], payload: args[5] }; };
      NRCAssets.requestAllAssets = async () => ({ assets: NRCAssets.getAssetsByType(0n, AssetType.Note) });
      NRCDialog.prompt = async message => message.startsWith("Reminder title") ? "Visibility contract" : message.startsWith("Deadline") ? "2027-01-01T12:00" : "";
      void createReminder();
    });
    await page.locator(`input[name="reminderCreateVisibility"][value="${visibility}"]`).check();
    await page.getByRole("button", { name: "NEXT", exact: true }).click();
    await page.locator('#reminderCreateNote').waitFor({ state: 'attached' });
    if (visibility === 'team') await page.locator('#reminderCreateNote').selectOption({ index: 1 });
    const linkedNote = await page.locator('#reminderCreateNote').inputValue();
    await page.getByRole('button', { name: 'CREATE', exact: true }).click();
    await page.waitForFunction(() => window.reminderCreated);
    const sent = await page.evaluate(() => window.reminderCreated);
    assert.equal(sent.preview, sent.payload);
    assert.equal(JSON.parse(sent.payload).visibility, visibility);
    assert.equal(JSON.parse(sent.payload).note_asset_id, linkedNote);
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
      assert.deepEqual(await row.locator(":scope > :is(.col-status, .col-priority, .col-blk, .col-ref, .col-att, .col-cmt)").allTextContents(),
        ["240", "IN PROGRESS", "#2", "https://example.com/nrc/register-review", "2", "2"], "compact task fixture fills every status and signal field");
      assert.match(await row.locator('.register-row-meta').textContent(), /tester/);
      assert.notEqual(await row.locator(".col-due").textContent(), "—", "compact task fixture includes a due date");
      await page.getByText("Validate the responsive two-line register with complete operational metadata.", { exact: true }).waitFor();
    }
    const hostWidth = (await host.boundingBox()).width;
    const inspectorWidth = (await page.locator("#inspector").boundingBox()).width;
    assert.equal(inspectorWidth, 720, `${view} restores the persisted wide Inspector`);
    assert.ok(hostWidth <= 700, `${view} fixture enters the compact container range (${hostWidth}px list / ${inspectorWidth}px Inspector)`);
    assert.ok((await row.boundingBox()).height >= 50, `${view} makes space for title, metadata and operational fields`);
    assert.equal(await row.evaluate(el => getComputedStyle(el).borderBottomWidth), "1px", `${view} compact row retains its shared divider`);
    const compact = await row.evaluate((element, view) => {
      const title = element.querySelector('nrc-inline-field[data-control$="-title"] button').getBoundingClientRect();
      const metadata = element.querySelector('.register-row-meta').getBoundingClientRect();
      return {
        titleAboveMetadata: title.bottom <= metadata.top + 1,
        titleUsable: title.width > 100,
        overflow: element.scrollWidth - element.clientWidth,
      };
    }, view);
    assert.deepEqual({ ...compact, overflow: compact.overflow > 1 }, { titleAboveMetadata: true, titleUsable: true, overflow: false }, `${view} keeps identity above aligned metadata without overflow (${compact.overflow}px)`);
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
    assert.ok((await row.boundingBox()).height >= 50, `${view} keeps the compact register geometry in the dark theme`);
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
    assert.ok((await row.boundingBox()).height >= 44, `${view} retains its title and second-line metadata`);
  }
  await page.evaluate(async () => { await NRCInspector.close(); showNotesView(); });
  const noteHost = page.locator('#notesPanel .notes-container');
  await noteHost.evaluate(el => { el.style.width = '800px'; });
  const noteTitleHandle = page.getByRole('separator', { name: 'Resize TITLE column', exact: true });
  await noteTitleHandle.focus();
  for (let i = 0; i < 40; i++) await page.keyboard.press('ArrowRight');
  assert.equal(await noteHost.evaluate(el => el.scrollWidth > el.clientWidth + 1), true, 'widening title creates horizontal scrolling');
  await noteHost.evaluate(el => { el.scrollLeft = el.scrollWidth; });
  const visibleAge = await page.locator('#notesList .note-card').first().evaluate(row => {
    const host = row.closest('.notes-container').getBoundingClientRect();
    const age = row.querySelector('.note-body').getBoundingClientRect();
    return age.right <= host.right + 1 && age.left >= host.left && age.right <= row.getBoundingClientRect().right + 1;
  });
  assert.equal(visibleAge, true, 'horizontal scrolling reaches the trailing age column');
  await noteTitleHandle.focus(); await page.keyboard.press('Home');
  await noteHost.evaluate(el => { el.style.width = '380px'; el.scrollLeft = 0; });
  const narrowNote = page.locator('#notesList .note-card').first();
  assert.ok((await narrowNote.locator('.note-title button').boundingBox()).width > 100, 'title remains usable in a 380px desktop register');
  assert.equal(await page.locator('.notes-list-header').evaluate(header => {
    const bounds = header.getBoundingClientRect();
    const title = header.children[2].getBoundingClientRect();
    const tags = header.children[3].getBoundingClientRect();
    return title.bottom <= tags.top && title.top >= bounds.top && tags.bottom <= bounds.bottom;
  }), true, 'compact title and tags headers occupy separate rows inside the header');
  await page.evaluate(() => { serverReady = true; renderNotesView(); });
  await narrowNote.locator('.note-project button').click();
  assert.equal(await page.locator('.inline-field-editor').isVisible(), true, 'narrow project editor remains reachable');
  await page.keyboard.press('Escape');
  assert.equal(await narrowNote.evaluate(row => row.scrollWidth <= row.clientWidth + 1), true);
  await page.screenshot({ path: '.amp/in/artifacts/entity-notes-380px.png' });
  await noteHost.evaluate(el => { el.style.width = ''; });

  // Old grid layouts contain a 24px locked marker. Collapse only that column;
  // preserve an intentionally widened ID and asymmetric title width.
  const restored = await page.evaluate(() => {
    const host = document.createElement("div");
    host.id = "resize-migration-test";
    document.body.append(host);
    localStorage.setItem("resize-migration-test", JSON.stringify([24, 112, 333]));
    let widths;
    NRCColumnResize.init({ root: "#resize-migration-test", viewport: "#resize-migration-test", flexible: 2, headers: "span", storageKey: "resize-migration-test", defaults: [0, 48, 260], minimums: [16, 48, 140], locked: [0], apply: (_host, value) => { widths = value; } });
    host.remove();
    localStorage.removeItem("resize-migration-test");
    return widths;
  });
  assert.deepEqual(restored, [0, 112, 333]);
  assert.deepEqual(errors, []);
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.evaluate(() => showNotesView());
  await noteTitleHandle.focus(); await page.keyboard.press('ArrowLeft');
  const savedNoteWidth = await page.locator('.notes-list-header > div').nth(2).evaluate(el => el.getBoundingClientRect().width);
  await page.evaluate(() => { setTaskGrouping("flat"); showKanban(); });
  const persistedTitle = page.locator('#taskListView th.col-title');
  const persistedHandle = persistedTitle.getByRole('separator');
  await persistedHandle.focus();
  await page.keyboard.press('ArrowLeft');
  const savedTitleWidth = (await persistedTitle.boundingBox()).width;
  await page.reload();
  await page.waitForFunction(() => window.NRCAssets && window.NRCViewManager);
  await page.evaluate(() => {
    currentRoomId = 7n;
    currentWorkspaceId = "table-test";
    window.NRCTaskQuery = undefined;
    setTaskGrouping("flat"); showKanban(); renderCurrentTaskView();
  });
  await persistedTitle.waitFor({ state: 'visible' });
  assert.equal((await persistedTitle.boundingBox()).width, savedTitleWidth, 'manual title width survives page reload');
  assert.equal(await page.locator('#taskListView').evaluate(host => {
    const age = host.querySelector('th.col-age').getBoundingClientRect();
    return Math.abs(age.right - host.querySelector('table').getBoundingClientRect().right) <= 1;
  }), true, 'empty rows span only visible columns, without a phantom trailing column');
  await persistedHandle.focus();
  await page.keyboard.press('Home');
  await page.evaluate(() => showNotesView());
  assert.ok(Math.abs(await page.locator('.notes-list-header > div').nth(2).evaluate(el => el.getBoundingClientRect().width) - savedNoteWidth) < 1, 'manual note width survives reload');
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
      for (const selector of [".note-card", ".reminder-row", ".attention-row", '.task-table tbody tr:not([aria-hidden="true"])', ".customer-row", ".customer-event:not(.history-event)", ".slice-row", ".file-assets-picker-row", "#divider-fixtures .file-assets-row:first-child", ".customer-contact", ".slice-member"]) {
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
  await page.addInitScript(() => {
    if (!localStorage.getItem('nrc.ticket.columns.v3')) localStorage.setItem('nrc.ticket.columns.v3', JSON.stringify([600, 640, 550, 500, 450, 400]));
  });
  await page.goto('http://nrc.test');
  await page.waitForFunction(() => window.NRCTickets);
  const seedTicket = () => {
    const asset = { assetId: 81n, convId: 0n, assetType: 13, createdAt: BigInt(Date.now()) * 1000000n, updatedAt: BigInt(Date.now()) * 1000000n,
      preview: JSON.stringify({ version: 1, title: 'Ticket: Responsive register', requester: 'customer@example.test', status: 'open', assignee: 'tester' }), payload: '', attachments: [] };
    NRCAssets.requestTicketPage = async () => ({ assets: [asset], has_more: false, total_count: 1, cursor: {} });
    NRCAssets.requestPersonList = async () => ['tester'];
    NRCAssets.requestAssetsByIds = async () => [];
    NRCAssets.requestAllAssets = async () => ({ assets: [] });
    NRCTickets.open();
  };
  await page.evaluate(seedTicket);
  await page.locator('#ticketsList tr[data-ticket]').waitFor();
  const ticketSaved = await page.evaluate(() => localStorage.getItem('nrc.ticket.columns.v3'));
  for (const theme of ['lupine', 'matte-black']) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    for (const width of [1500, 2560, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      assert.equal(await page.locator('#ticketsRegister').evaluate(el => el.scrollWidth <= el.clientWidth + 1), true, `ticket columns fit at ${width}`);
      assert.equal(await page.evaluate(() => localStorage.getItem('nrc.ticket.columns.v3')), ticketSaved);
      await page.locator('#ticketsPanel').screenshot({ path: `.amp/in/artifacts/fit-tickets-${theme}-${width}.png` });
    }
  }
  await page.setViewportSize({ width: 1500, height: 1000 });
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const ticketTitle = page.locator('#ticketsTable th').nth(1);
  const ticketTitleWidth = (await ticketTitle.boundingBox()).width;
  await ticketTitle.getByRole('separator').focus();
  await page.keyboard.press('ArrowRight');
  assert.ok(Math.abs((await ticketTitle.boundingBox()).width - ticketTitleWidth - 8) < 1, 'compressed ticket title grows by 8px without overflow');
  assert.equal(await page.locator('#ticketsRegister').evaluate(el => el.scrollWidth > el.clientWidth + 1), true);
  for (const theme of ['lupine', 'matte-black']) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await verifyIndependentColumns('tickets', theme);
  }
  await ticketTitle.getByRole('separator').focus(); await page.keyboard.press('ArrowRight');
  const savedTicketWidths = await page.locator('#ticketsTable th').evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().width));
  await page.reload();
  await page.waitForFunction(() => window.NRCTickets);
  await page.evaluate(seedTicket);
  await page.locator('#ticketsList tr[data-ticket]').waitFor();
  const restoredTicketWidths = await page.locator('#ticketsTable th').evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().width));
  savedTicketWidths.forEach((width, index) => assert.ok(Math.abs(restoredTicketWidths[index] - width) < 1, 'manual ticket widths survive reload'));
  const seedReminder = () => {
    const stamp = BigInt(Date.now()) * 1000000n;
    NRCAssets.roomAssets.set(0n, new Map([[91n, { assetId: 91n, convId: 0n, assetType: AssetType.Reminder, createdAt: stamp, updatedAt: stamp,
      payload: JSON.stringify({ title: 'Reminder: Persist independent column widths', visibility: 'team', deadline_at: String(stamp + 86400000000000n), window_start_at: '0' }), attachments: [] }]]));
    NRCViewManager.setActiveView('reminders');
    renderReminderQueue();
  };
  await page.evaluate(seedReminder);
  const reminderCells = page.locator('.reminder-list-header > span');
  await reminderCells.nth(2).getByRole('separator').focus(); await page.keyboard.press('ArrowRight');
  const reminderWidths = await reminderCells.evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().width));
  await page.reload();
  await page.waitForFunction(() => window.NRCAssets && window.NRCViewManager);
  await page.evaluate(seedReminder);
  const reminderRestored = await reminderCells.evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().width));
  reminderWidths.forEach((width, index) => assert.ok(Math.abs(reminderRestored[index] - width) < 1, 'manual reminder widths survive reload'));
  await page.locator('[data-reminder-filter="overdue"]').click();
  assert.equal(await page.locator('#reminderColumnsReset').isDisabled(), true, 'empty filtered reminder table disables reset');
  await page.locator('[data-reminder-filter="all"]').click();
  const afterFilter = await reminderCells.evaluateAll(cells => cells.map(cell => cell.getBoundingClientRect().width));
  reminderWidths.forEach((width, index) => assert.ok(Math.abs(afterFilter[index] - width) < 1, 'empty filter and return preserves reminder widths'));
  await page.locator('#reminderColumnsReset').click();
  assert.equal(await page.evaluate(() => localStorage.getItem('nrc.reminder.columns.v1')), null, 'reset after header recreation clears manual widths');
  assert.deepEqual(errors, []);
  console.log("PASS: saved widths fit notes/tasks/reminders/tickets without losing preferences; resize/reset, both themes, desktop/mobile and Inspector layouts");
} finally {
  await browser.close();
}
