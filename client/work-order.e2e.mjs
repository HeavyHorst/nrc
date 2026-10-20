// Run only against the disposable test/customer-workspace-dev.mjs fixture.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { chromium } from 'playwright';

const url = process.env.NRC_WORK_ORDER_TEST_URL;
if (!url) throw new Error('Set NRC_WORK_ORDER_TEST_URL to the disposable fixture');
const workspace = `work-order-${Date.now()}`;
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: 'block' });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${url}/#workspace=${workspace}`);
  await page.waitForFunction(() => serverReady);
  const fixture = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const create = async (title, priority, blocked = 0n) => {
      const task = (await rpc(o => NRCTasks.sendCreateTask(0n, title, '', priority, 0, '', 0n, [], 1, 0, 'Rollout', o))).task;
      if (blocked) await rpc(o => NRCTasks.sendUpdateTask(0n, task.id, '', '', 255, '', 255, 255, '', 0n, blocked, [], '', o));
      return task.id;
    };
    const root = await create('01 · Zugang bereitstellen', 80);
    const child = await create('02 · Dringende Freigabe — benötigt Zugang', 240, root);
    const independent = await create('03 · Betriebshandbuch prüfen', 60);
    const sibling = await create('04 · Schulung planen — benötigt Zugang', 40, root);
    const slice = (await rpc(o => NRCAssets.sendCreateAsset(0n, 11, 0, 0n,
      JSON.stringify({ version: 1, name: 'Rollout · Arbeitsreihenfolge', owner: 'customer-preview', outcome: 'Zugang, Freigabe und Übergabe in nachvollziehbarer Reihenfolge.' }), '', 0, o))).asset.assetId;
    const partial = (await rpc(o => NRCAssets.sendCreateAsset(0n, 11, 0, 0n,
      JSON.stringify({ version: 1, name: 'Teilprojekt · externe Voraussetzung' }), '', 0, o))).asset.assetId;
    const member = (id, target) => rpc(o => NRCEdges.sendCreateEdge(0n, 2, id, 1, target, 7, o));
    const ids = [root, child, independent, sibling];
    for (let i = 0; i < 102; i++) ids.push(await create(`Dokumentation ${String(i + 1).padStart(3, '0')}`, 10));
    for (const id of ids) await member(id, slice);
    await member(child, partial);
    await member(independent, partial);
    return { ids: ids.map(String), root: String(root), child: String(child), slice: String(slice), partial: String(partial) };
  });
  // Exercise actual protocol paging and independently expected ordering.
  const results = await page.evaluate(async f => {
    const first = await NRCTaskQuery.requestPage({ sort: 'workOrder', sliceId: BigInt(f.slice) });
    const second = await NRCTaskQuery.requestPage({ sort: 'workOrder', sliceId: BigInt(f.slice) }, first.cursor);
    const partial = await NRCTaskQuery.requestPage({ sort: 'workOrder', sliceId: BigInt(f.partial) });
    return { first: first.tasks.map(t => String(t.id)), second: second.tasks.map(t => String(t.id)),
      more: [first.hasMore, second.hasMore], total: first.total, partial: partial.tasks.map(t => String(t.id)) };
  }, fixture);
  assert.deepEqual([...results.first, ...results.second], fixture.ids);
  assert.deepEqual(results.more, [true, false]);
  assert.equal(results.first.length, 100);
  assert.equal(results.total, 106);
  assert.deepEqual(results.partial, [fixture.ids[2], fixture.child], 'external unfinished prerequisite remains unresolved');

  const choose = async (selector, label) => {
    await page.locator(`nrc-select:has(${selector}) .custom-select__trigger`).click();
    await page.locator('.custom-select__dropdown:visible').getByRole('option', { name: label, exact: true }).click();
  };
  const capture = async name => {
    if (!process.env.NRC_SCREENSHOT_DIR) return;
    await fs.mkdir(process.env.NRC_SCREENSHOT_DIR, { recursive: true });
    await page.screenshot({ path: `${process.env.NRC_SCREENSHOT_DIR}/${name}.png` });
  };
  for (const theme of ['lupine', 'matte-black']) for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 1000 });
    await page.evaluate(theme => {
      document.documentElement.dataset.theme = theme;
      NRCInspector.close(); NRCViewManager.setActiveView('kanban'); setTaskGrouping('flat');
    }, theme);
    if (width === 390) {
      const filters = page.locator('#kanbanPanel [data-mobile-filters]');
      if (await filters.count() && await filters.getAttribute('aria-expanded') !== 'true') await filters.click();
    }
    await choose('#mobileTaskSort', 'WORK ORDER');
    await page.waitForFunction(() => NRCTaskQuery.getState().mode === 'results' && NRCTaskQuery.getState().query.sort === 'workOrder');
    assert.deepEqual(await page.locator('#taskListBody tr[data-task-id]').evaluateAll(rows => rows.slice(0, 4).map(r => r.dataset.taskId)), fixture.ids.slice(0, 4));
    assert.equal(await page.evaluate(() => TaskViewState.sortDirection), 'asc');
    await capture(`flat-${theme}-${width}`);
    await page.evaluate(async id => {
      setTaskGrouping('slices');
      await NRCInspector.openEntity({ roomId: 0n, type: 'slice', id: BigInt(id) });
    }, fixture.slice);
    await page.waitForSelector('[data-slice-task-sort]');
    await choose('[data-slice-task-sort]', 'WORK ORDER');
    await page.waitForFunction(() => NRCSlices.getState().members.mode === 'ready' && NRCSlices.getState().members.tasks.length === 100);
    await capture(`slice-${theme}-${width}`);
    await page.locator('[data-slice-action="load-more-tasks"]').click();
    await page.waitForFunction(() => NRCSlices.getState().members.tasks.length === 106);
    // No read -> invalidate -> reload loop may discard the appended page.
    await page.waitForTimeout(600);
    assert.equal(await page.evaluate(() => NRCSlices.getState().members.tasks.length), 106);
    await page.evaluate(() => NRCSlices.setTaskSort('createdAt'));
  }
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ workspace, ...fixture, result: 'WorkOrder protocol, paging, scope and UI passed (both themes, 1440/390).' }));
} finally { await browser.close(); }
