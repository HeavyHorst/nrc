// Run against the disposable test/customer-workspace-dev.mjs fixture.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error("Set NRC_CUSTOMERS_TEST_URL to the disposable fixture");
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`${url}/#workspace=inspector-visibility-${Date.now()}`);
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  const ids = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const task = await rpc(o => NRCTasks.sendCreateTask(0n, "Review release checklist", "Verify the workspace before release.", 128, 0, "", 0n, [], 0, 0, "", o));
    const note = await rpc(o => NRCAssets.sendCreateAsset(0n, 5, 0, 0n,
      JSON.stringify({ version: 1, title: "Release notes" }), "## Release checklist\n\nReview tasks and notes before release.", 0, o));
    return { task: String(task.task.id), note: String(note.asset.assetId) };
  });
  const rail = page.locator("#inspector");
  const open = async type => {
    await page.evaluate(({ type, id }) => NRCInspector.openEntity({ roomId: 0n, type, id: BigInt(id) }), { type, id: ids[type] });
    await page.waitForFunction(() => !NRCInspector.isLoading());
    assert.equal(await rail.isVisible(), true, `${type} opens the rail`);
  };
  const capture = async name => {
    if (!process.env.NRC_INSPECTOR_SCREENSHOTS) return;
    await fs.mkdir(process.env.NRC_INSPECTOR_SCREENSHOTS, { recursive: true });
    await page.screenshot({ path: `${process.env.NRC_INSPECTOR_SCREENSHOTS}/${name}.png` });
  };
  for (const theme of ["light", "dark"]) {
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
      for (const view of ["kanban", "notes", "customers", "reminders", "attention", "calendar"]) {
        await page.evaluate(view => view === "notes" ? NRCNotes.showNotesView() : NRCViewManager.setActiveView(view), view);
        assert.equal(await rail.isHidden(), true, `${view} has no empty rail (${theme}/${width})`);
        if (view === "kanban") {
          for (const grouping of ["flat", "slices"]) {
            await page.locator(`[data-task-grouping="${grouping}"]`).evaluate(el => el.click());
            assert.equal(await rail.isHidden(), true, `${grouping} has no empty rail`);
            await open("task");
            await page.locator("#taskDetailClose").click();
            await page.waitForFunction(() => !NRCInspector.hasEntity());
            assert.equal(await rail.isHidden(), true, `${grouping} hides the closed rail`);
          }
        }
        await open("task");
        await open("note");
        await page.evaluate(() => NRCInspector.back());
        assert.equal(await rail.isVisible(), true, "back to a task keeps the rail");
        assert.equal(await page.evaluate(() => NRCInspector.current().type), "task");
        await page.evaluate(() => NRCInspector.back());
        assert.equal(await rail.isHidden(), true, "back past the last record hides the rail");
        if (view === "notes") {
          await page.locator(`#notesList .note-card[data-note-id="${ids.note}"]`).click();
          await page.waitForFunction(() => NRCInspector.current()?.type === "note" && !NRCInspector.isLoading());
          assert.equal(await rail.isVisible(), true, "clicking a note opens the hidden rail");
        } else await open("note");
        if (view === "notes") await capture(`note-open-${theme}-${width}`);
        await page.locator("#noteDetailClose").click();
        await page.waitForFunction(() => !NRCInspector.hasEntity());
        assert.equal(await rail.isHidden(), true, "note close hides the rail");
        if (view === "notes") await capture(`notes-closed-${theme}-${width}`);
      }
      // A live record survives a view switch; returning to chat restores context.
      await open("note");
      await page.evaluate(() => NRCViewManager.setActiveView("notes"));
      assert.equal(await rail.isVisible(), true);
      await page.evaluate(() => NRCInspector.close());
      assert.equal(await rail.isHidden(), true);
      for (const view of ["chat", "sullivan"]) {
        await page.evaluate(view => NRCViewManager.setActiveView(view), view);
        assert.equal(await rail.evaluate(el => el.classList.contains("inspector-entity-only")), false);
        if (width === 1440) assert.equal(await rail.isVisible(), true, `${view} retains context`);
      }
    }
  }
  assert.deepEqual(errors, []);
  console.log("PASS inspector visibility: six views, flat/slices, open/close/back, view switching, light/dark, desktop/mobile");
} finally {
  await browser.close();
}
