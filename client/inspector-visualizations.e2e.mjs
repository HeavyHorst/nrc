// Real application shell, disposable browser-local records, no server writes.
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs/promises';

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: 'block' });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.routeWebSocket('**/*', socket => socket.onMessage(() => {}));
  await page.route('http://nrc.test/**', async route => {
    const path = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === '/' ? '/index.html' : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: 'Not found' }); }
  });
  await page.goto('http://nrc.test');
  await page.waitForFunction(() => window.NRCInspector && window.NRCAI && typeof marked !== 'undefined');
  await page.evaluate(() => {
    serverReady = true; currentWorkspaceId = 'visual-test'; currentRoomId = 0n; myNickname = 'Rene';
    const task = { id: 217n, convId: 0n, title: 'Pilotbetrieb freigeben', description: 'Rollen und Kernfunktionen prüfen. Danach die Freigabe dokumentieren.', status: 1, priority: 128, color: 0, createdBy: 'Rene', createdAt: 1790336880000000000n, updatedAt: 1790336880000000000n, attachments: [], assignee: 'Rene', project: 'Pilotbetrieb', dueAt: 0n, blockedBy: 204n };
    roomTasks.set(0n, new Map([[217n, task], [204n, { ...task, id: 204n, title: 'Zugang bereitstellen', status: 2, blockedBy: 0n }], [225n, { ...task, id: 225n, title: 'Rollout starten', assignee: 'Julia', blockedBy: 217n }], [226n, { ...task, id: 226n, title: '<img src=x onerror=alert(1)>', blockedBy: 217n }], [227n, { ...task, id: 227n, title: 'Unrelated', blockedBy: 204n }]]));
    const serverTasks = new Map(roomTasks.get(0n));
    serverTasks.set(228n, { ...task, id: 228n, title: 'Nur serverseitig geladen', blockedBy: 217n });
    sendListTaskDependents = (id, after, options) => {
      const rows = [...serverTasks.values()].filter(item => item.blockedBy === id && item.id > after).sort((a, b) => a.id < b.id ? -1 : 1);
      const tasks = rows.slice(0, 2);
      setTimeout(() => options.onSuccess({ tasks, hasMore: rows.length > 2, nextTaskId: tasks.at(-1)?.id || 0n }), 0);
      return 0;
    };
    NRCAssets.roomAssets.set(0n, new Map([[188n, { assetId: 188n, convId: 0n, assetType: 5, owner: 'Rene', preview: JSON.stringify({ title: 'Pilotbetrieb — Freigabeprotokoll', format: 'markdown' }), payload: 'Vor der Freigabe werden Rollen und Kernfunktionen geprüft.\n\nDie Freigabe erfolgt nach dem Zugangstest.\n\nDanach informiert das Projektteam alle Beteiligten.', attachments: [] }]]));
    const currentNote = NRCAssets.roomAssets.get(0n).get(188n);
    NRCAssets.roomAssets.get(0n).set(188n, { ...currentNote, payload: 'Obsolete content from before disconnect.' });
    NRCAssets.requestAsset = (_room, id, options) => queueMicrotask(() => {
      const asset = options.force && id === 188n ? currentNote : NRCAssets.roomAssets.get(0n).get(id);
      if (asset) options.onSuccess({ asset }); else options.onError?.({ message: 'Not found' });
    });
    NRCLinksUI.loadLinks = async () => {};
    NRCEdges.getEdgesForEntity = () => [];
    NRCEdges.requestEdgePage = async () => ({ edges: [], hasMore: false });
    NRCViewManager.setActiveView('kanban');
  });
  const capture = async (selector, name) => {
    if (!process.env.NRC_SCREENSHOT_DIR) return;
    await fs.mkdir(process.env.NRC_SCREENSHOT_DIR, { recursive: true });
    await page.locator(selector).screenshot({ path: `${process.env.NRC_SCREENSHOT_DIR}/${name}.png` });
  };
  for (const width of [1440, 390]) for (const theme of ['lupine', 'matte-black']) {
    await page.setViewportSize({ width, height: 1000 });
    await page.evaluate(async theme => {
      document.documentElement.dataset.theme = theme;
      NRCAI.closeSourcePanel();
      NRCViewManager.setActiveView('kanban');
      await NRCInspector.close();
      await NRCInspector.openEntity({ roomId: 0n, type: 'task', id: 217n });
    }, theme);
    const graph = page.locator('#inspector .task-dependencies');
    await graph.waitFor();
    await graph.locator('[data-dependency-more]').waitFor();
    assert.deepEqual(await graph.locator('[data-dependency-id]').evaluateAll(nodes => nodes.map(node => node.dataset.dependencyId)), ['204', '225', '226']);
    assert.deepEqual(await graph.locator('h3').allTextContents(), ['DEPENDS ON', 'REQUIRED BY']);
    assert.equal(await graph.locator('.task-dependency-reference').filter({ hasText: '#217' }).count(), 0, 'opened task is context, not a dependency');
    assert.equal(await graph.locator('img').count(), 0, 'task titles remain inert');
    await graph.getByRole('button', { name: 'LOAD MORE' }).click();
    await graph.locator('[data-dependency-id="228"]').waitFor();
    assert.match(await graph.textContent(), /3 dependent tasks/);
    assert.ok(await graph.evaluate(el => el.scrollWidth <= el.clientWidth));
    await capture('#inspector', `dependencies-${theme}-${width}`);
    await graph.locator('[data-dependency-id="225"]').click();
    await page.waitForFunction(() => document.querySelector('#inspectorHeader')?.textContent.includes('TASK #225'));
    await page.evaluate(async () => {
      await NRCInspector.close(); NRCViewManager.setActiveView('chat');
      const root = document.createElement('div'); root.id = 'visualAnswer';
      document.getElementById('logOutput').replaceChildren(root);
      NRCAI.renderAnswer(root, { message: 'Die Freigabe folgt auf den Zugangstest.', roomId: 0n, aiSources: [{ type: 'note', id: '188', title: 'Pilotbetrieb — Freigabeprotokoll' }] });
    });
    await page.locator('#visualAnswer summary').click();
    await page.locator('#visualAnswer .ai-source-item').click();
    const source = page.locator('#aiSourcePanel');
    await source.locator('blockquote').waitFor();
    assert.equal(await source.locator('mark').count(), 0, 'no invented citation highlight');
    await capture('#aiSourcePanel', `source-default-${theme}-${width}`);
    await source.getByRole('searchbox').fill('Zugangstest');
    assert.equal(await source.locator('mark').textContent(), 'Zugangstest');
    assert.match(await source.locator('blockquote').textContent(), /Rollen und Kernfunktionen/);
    assert.match(await source.textContent(), /not verified evidence/);
    assert.ok(await source.evaluate(el => el.scrollWidth <= el.clientWidth));
    await capture('#aiSourcePanel', `source-match-${theme}-${width}`);
    await source.getByRole('searchbox').fill('unmatched phrase');
    assert.equal(await source.locator('mark').count(), 0);
    assert.match(await source.textContent(), /No matching text/);
    await page.keyboard.press('Escape');
    await page.evaluate(() => NRCAI.closeSourcePanel());
  }
  await page.evaluate(async () => {
    NRCViewManager.setActiveView('kanban');
    await NRCInspector.openEntity({ roomId: 0n, type: 'task', id: 226n });
    roomTasks.get(0n).get(226n).blockedBy = 0n;
    showTaskDetailPanel(roomTasks.get(0n).get(226n));
  });
  await page.waitForFunction(() => document.querySelector('#inspector .task-dependencies')?.hidden);
  assert.ok(await page.locator('#inspector .task-dependencies').isHidden(), 'no graph for an unrelated task');
  await page.evaluate(async () => {
    await NRCInspector.close();
    await NRCInspector.openEntity({ roomId: 0n, type: 'task', id: 217n });
  });
  await page.locator('[data-dependency-id="204"]').waitFor();
  await page.evaluate(() => {
    const moved = new DataView(new ArrayBuffer(35));
    moved.setUint16(0, 133); moved.setBigUint64(2, 217n); moved.setBigUint64(10, 0n); moved.setUint8(18, 3);
    handleTaskMoved(moved);
  });
  await page.waitForTimeout(250);
  assert.equal(await page.locator('[data-dependency-id="204"]').count(), 1, 'prerequisite retained after moving root out of partial cache');
  assert.equal(await page.evaluate(() => roomTasks.get(0n).has(217n)), false, 'move leaves unloaded DONE cache');
  await page.evaluate(() => {
    taskDependencyQuery.disconnect(true);
    const freshRoot = { ...currentDetailTask, blockedBy: 227n };
    requestTask = (_room, id, options) => queueMicrotask(() => options.onSuccess({ task: id === 217n ? freshRoot : roomTasks.get(0n).get(id) }));
  });
  await page.locator('[data-dependency-retry]').click();
  await page.locator('[data-dependency-id="227"]').waitFor();
  await page.evaluate(() => {
    const moved = new DataView(new ArrayBuffer(35));
    moved.setUint16(0, 133); moved.setBigUint64(2, 225n); moved.setBigUint64(10, 0n); moved.setUint8(18, 2);
    handleTaskMoved(moved);
  });
  await page.waitForTimeout(250);
  assert.equal(await page.locator('[data-dependency-id="227"]').count(), 1, 'retry keeps fresh prerequisite after unrelated mutation');
  assert.equal(await page.locator('[data-dependency-id="204"]').count(), 0);
  assert.deepEqual(errors, []);
  console.log('PASS: dependency direction/navigation/empty state, literal source excerpt search and no invented evidence; both themes at 1440/390');
} finally { await browser.close(); }
