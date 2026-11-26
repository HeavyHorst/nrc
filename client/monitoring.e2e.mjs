import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { fileURLToPath } from 'node:url';
import { installMonitoringFixture } from './monitoring-fixture.mjs';

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, locale: 'en-US', deviceScaleFactor: 2, serviceWorkers: 'block' });
const errors = [];
page.on('pageerror', e => errors.push(e.message));
try {
  await page.routeWebSocket('**/*', socket => socket.onMessage(() => {}));
  await page.route('http://nrc.test/**', async route => {
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${new URL(route.request().url()).pathname === '/' ? '/index.html' : new URL(route.request().url()).pathname}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: 'Not found' }); }
  });
  await page.goto('http://nrc.test');
  await page.waitForFunction(() => window.NRCMonitoring && window.NRCTickets);
  await page.evaluate(installMonitoringFixture);
  await page.evaluate(() => { monitorFixture.empty = true; });
  await page.click('#monitoringBtn');
  await page.waitForFunction(() => document.querySelector('#monitorList > .customer-empty')?.textContent === 'No records loaded.');
  for (const width of [1600, 390]) {
    await page.setViewportSize({ width, height: 1000 });
    const aligned = await page.evaluate(() => {
      const textLeft = selector => {
        const range = document.createRange();
        range.selectNodeContents(document.querySelector(selector));
        return range.getBoundingClientRect().left;
      };
      return Math.abs(textLeft('#monitorList > .customer-empty') - textLeft('#monitorSummary')) < 1;
    });
    assert.equal(aligned, true, 'Empty register text aligns with summary at desktop and mobile widths');
  }
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.evaluate(() => { monitorFixture.empty = false; });
  await page.click('#monitorRefresh');
  await page.waitForSelector('[data-monitor="12"]');
  // The whole register row opens its record, including nested text and empty cell space.
  for (const width of [1600, 390]) {
    await page.setViewportSize({ width, height: 1000 });
    for (const tab of ['Status', 'Incidents']) {
      await page.click(`#monitor${tab}Tab`);
      const marker = tab === 'Status' ? '#monitorDetailRefresh' : '#incidentAck';
      for (const selector of ['td:first-child .customer-meta', 'td:nth-child(2)', 'td:last-child']) {
        await page.locator(`#monitorList tbody tr:first-child ${selector}`).click({ position: { x: 3, y: 3 } });
        await page.waitForSelector(marker);
        const controls = await page.locator('#inspectorHeader button').evaluateAll(buttons => buttons.map(button => {
          const { y, height } = button.getBoundingClientRect(); return { y, height };
        }));
        assert.ok(controls.every(control => control.y === controls[0].y && control.height === controls[0].height), 'Header actions share one height and baseline');
        await page.evaluate(() => NRCInspector.close());
        await page.waitForSelector(marker, { state: 'hidden' });
      }
      // Preserve keyboard access through the existing record button.
      await page.locator('#monitorList .task-row-open').first().press('Enter');
      await page.waitForSelector(marker);
      await page.evaluate(() => NRCInspector.close());
    }
  }
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.click('#monitorStatusTab');
  await page.waitForSelector('[data-monitor="12"]');
  await page.waitForSelector('[data-monitor="13"]');
  assert.match(await page.locator('#monitorSummary').textContent(), /2 \/ 2 LOADED MONITORS.*3 INSTANCES.*1 FIRING/);
  const historyHelp = page.locator('.monitor-history-help');
  assert.equal(await historyHelp.locator('p').isVisible(), false, 'History explanation starts collapsed');
  await historyHelp.locator('summary').focus();
  await page.keyboard.press('Enter');
  assert.equal(await historyHelp.locator('p').isVisible(), true, 'Keyboard opens interpretation details');
  assert.match(await historyHelp.locator('p').textContent(), /A failed condition does not necessarily mean the service was unreachable/);
  await page.keyboard.press('Space');
  assert.equal(await historyHelp.locator('p').isVisible(), false, 'Keyboard closes interpretation details');
  assert.equal(await page.locator('#monitorMore').count(), 0);
  assert.equal(await page.locator('#monitorIncidentsTab').evaluate(e => e.getBoundingClientRect().right <= e.parentElement.getBoundingClientRect().right), true, 'Both tabs fit their group');
  const trail = page.locator('[data-history-monitor="12"][data-history-part="trail"]');
  const metrics = page.locator('[data-history-monitor="12"][data-history-part="metrics"]');
  await page.waitForSelector('[data-history-monitor="12"] .monitor-history-bar');
  // 41.25 healthy instance-hours / 41.5 known; coverage 41.5 / (48 - 2 paused).
  assert.equal(await metrics.textContent(), '99.39%Coverage 90.21%');
  assert.match(await metrics.locator('.monitor-history-metrics').getAttribute('title'), /2 observed identities.*current revision/);
  assert.equal(await trail.locator('.monitor-history-bar').count(), 24);
  assert.equal(await trail.locator('.monitor-history-axis > span').count(), 24, 'Each completed hour has a local-time axis label');
  assert.equal(await trail.locator('[data-state="healthy"]').count(), 19);
  assert.equal(await trail.locator('[data-state="unknown"]').count(), 2);
  assert.equal(await trail.locator('[data-state="partial"]').count(), 1);
  assert.equal(await trail.locator('[data-state="paused"]').count(), 1);
  assert.match(await trail.locator('[data-state="failing"]').getAttribute('aria-label'), /87.5%.*coverage 100%/);
  assert.match(await trail.textContent(), /ROLLUPS PENDING/);
  const healthyColors = await page.evaluate(() => {
    const colors = THEMES.map(theme => {
      setTheme(theme, false);
      return getComputedStyle(document.querySelector('#monitorList .monitor-history-healthy')).backgroundColor;
    });
    setTheme('lupine', false);
    return colors;
  });
  for (const color of healthyColors) assert.ok(['rgb(0, 166, 81)', 'rgb(64, 200, 112)'].includes(color), `Healthy must stay green: ${color}`);
  // Failed time stays proportional, including subpixel failures. Separate
  // markers keep brief failures and gaps discoverable without inflating them.
  await page.evaluate(() => { monitorFixture.registerRows = [
    { hour: 0, identity: 'a', healthy: 3558, unknown: 42 },
    { hour: 1, identity: 'a', healthy: 900, failing: 1800, unknown: 450, paused: 450 },
    { hour: 2, identity: 'a', paused: 3600 },
    { hour: 4, identity: 'a', healthy: 3599, failing: 1 },
    { hour: 5, identity: 'a', failing: 3600 },
  ]; });
  await page.click('#monitorRefresh');
  await page.waitForSelector('[data-history-monitor="12"] button[aria-label*="unknown 42 s"]');
  for (const width of [1600, 390]) {
    await page.setViewportSize({ width, height: 1000 });
    for (const [index, shares] of [[0, [98.833333, 0, 1.166667, 0]], [1, [25, 50, 12.5, 12.5]], [2, [0, 0, 0, 100]], [3, [0, 0, 100, 0]], [4, [99.972222, 0.027778, 0, 0]], [5, [0, 100, 0, 0]]]) {
      const bar = trail.locator('.monitor-history-bar').nth(index);
      const rendered = await bar.evaluate(b => [...b.querySelectorAll('.monitor-history-part')].map(p => p.getBoundingClientRect().width / b.getBoundingClientRect().width * 100));
      rendered.forEach((value, i) => assert.ok(Math.abs(value - shares[i]) < 0.3, `Rendered share ${value} matches ${shares[i]} at width ${width}`));
      assert.equal(await bar.getAttribute('data-gap'), String([0, 1, 3].includes(index)));
    }
    const failing = trail.locator('.monitor-history-bar').nth(1);
    for (const theme of await page.evaluate(() => THEMES)) {
      await page.evaluate(theme => setTheme(theme, false), theme);
      const paint = await failing.evaluate(button => ({
        color: getComputedStyle(button.querySelector('.monitor-history-failing')).backgroundColor,
        legend: getComputedStyle(document.querySelector('#monitorHistoryLegend [data-state="failing"]')).backgroundColor,
        marker: getComputedStyle(button, '::before').backgroundColor,
        gap: getComputedStyle(button, '::after').borderBottomWidth,
      }));
      assert.equal(paint.color, paint.legend, 'Only failed time uses the failing color');
      assert.equal(paint.marker, paint.legend, 'The failure marker matches failed time');
      assert.equal(await failing.locator('.monitor-history-fill').isVisible(), true, 'Time shares stay visible in failed periods');
      assert.equal(paint.gap, '3px', 'Failure does not hide the gap marker');
      const brief = trail.locator('.monitor-history-bar').nth(4);
      const marker = await brief.evaluate(button => ({
        width: getComputedStyle(button, '::before').width,
        height: getComputedStyle(button, '::before').height,
        color: getComputedStyle(button, '::before').backgroundColor,
      }));
      assert.deepEqual(marker, { width: '2px', height: '4px', color: paint.legend }, 'A one-second failure retains a visible marker at both widths');
    }
    await page.evaluate(() => setTheme('lupine', false));
    const bar = trail.locator('.monitor-history-bar').first();
    await bar.press('Enter');
    assert.equal(await bar.getAttribute('aria-pressed'), 'true');
    assert.match(await trail.locator('.monitor-history-detail-summary').textContent(), /Passed 59 min 18 sNo data 42 sCoverage 98.83%/);
    assert.match(await trail.locator('.monitor-history-detail-percentages').textContent(), /Passed 98.83%No data 1.16%/);
    assert.equal(await page.locator('#monitorDetailRefresh').isVisible(), false, 'Period activation does not open the monitor Inspector');
    await failing.click();
    assert.equal(await bar.getAttribute('aria-pressed'), 'false');
    assert.match(await trail.locator('.monitor-history-detail-summary').textContent(), /Passed 15 minFailed 30 minNo data 7 min 30 sPaused 7 min 30 sCoverage 85.71%/);
    assert.deepEqual(await trail.locator('.monitor-history-detail .monitor-history-fill > .monitor-history-part').evaluateAll(parts => parts.map(part => part.style.width)), ['25%', '50%', '12.5%', '12.5%']);
    assert.match(await trail.locator('.monitor-history-detail-percentages').textContent(), /Passed 25%Failed 50%No data 12.5%Paused 12.5%/);
    assert.equal(await trail.locator('.monitor-history-detail .monitor-history-fill').isVisible(), true);
    await failing.press('Space');
    assert.equal(await trail.locator('.monitor-history-detail').isVisible(), false);
    await trail.locator('.monitor-history-bar').nth(4).click();
    assert.match(await trail.locator('.monitor-history-detail-summary').textContent(), /Passed 59 min 59 sFailed 1 sCoverage 100%/);
    await trail.locator('.monitor-history-bar').nth(4).click();
    assert.equal(await page.locator('#monitorRegisterScroll').evaluate(e => e.scrollWidth <= e.clientWidth), true);
  }
  await page.setViewportSize({ width: 1600, height: 1000 });
  // A revision change halfway through hour 12 excludes the earlier half-hour.
  await page.evaluate(() => {
    const from = Math.floor(Date.now() / 3600000) * 3600000 - 86400000;
    monitorFixture.statusRevision = String(BigInt(from + 12.5 * 3600000) * 1000000n);
    monitorFixture.registerRows = [
      { hour: 12, identity: 'a', old: true, healthy: 1800 },
      { hour: 12, identity: 'a', healthy: 900, failing: 900 },
      { hour: 13, identity: 'a', healthy: 3600 },
    ];
  });
  await page.click('#monitorRefresh');
  await page.waitForSelector('[data-history-monitor="12"] .monitor-history-bar');
  assert.equal(await metrics.textContent(), '83.33%Coverage 6.25%');
  assert.match(await metrics.locator('.monitor-history-metrics').getAttribute('title'), /1 observed identities/);
  assert.match(await trail.locator('.monitor-history-bar').nth(12).getAttribute('aria-label'), /50%.*coverage 50%/);
  for (const [data, coverage] of [
    [[{ hour: 0, identity: 'early', healthy: 3600 }, { hour: 23, identity: 'late', healthy: 1800, paused: 1800 }], '3.15%'],
    [[{ hour: 0, identity: 'a', healthy: 3600 }, { hour: 0, identity: 'b', paused: 3600 }], '2.12%'],
  ]) {
    await page.evaluate(data => { monitorFixture.statusRevision = ''; monitorFixture.registerRows = data; }, data);
    await page.click('#monitorRefresh');
    await page.waitForFunction(() => !document.getElementById('monitorList').textContent.includes('HISTORY UPDATING'));
    await page.waitForSelector('[data-history-monitor="12"] .monitor-history-bar');
    assert.equal(await metrics.textContent(), `100%Coverage ${coverage}`);
    assert.match(await metrics.locator('.monitor-history-metrics').getAttribute('title'), /2 observed identities/);
  }
  assert.equal(await trail.locator('.monitor-history-bar').first().getAttribute('data-state'), 'healthy');
  assert.match(await trail.locator('.monitor-history-bar').first().getAttribute('aria-label'), /coverage 100%/);
  // A completed rollup becomes visible only after refresh, without filling gaps.
  await page.evaluate(() => { monitorFixture.registerRows = []; });
  await page.click('#monitorRefresh');
  await page.waitForFunction(() => document.querySelector('[data-history-part="metrics"]').textContent.includes('NO HISTORY'));
  await page.evaluate(() => { monitorFixture.registerRows = [{ hour: 23, identity: 'a', healthy: 3600 }]; monitorFixture.pendingRollups = '0'; });
  assert.match(await metrics.textContent(), /NO HISTORY/);
  await page.click('#monitorRefresh');
  await page.waitForSelector('[data-history-monitor="12"] [data-state="healthy"]');
  assert.match(await metrics.textContent(), /100%.*Coverage 4.16%/);
  assert.doesNotMatch(await trail.textContent(), /ROLLUPS PENDING/);
  await page.evaluate(() => { delete monitorFixture.registerRows; delete monitorFixture.pendingRollups; });
  for (const [mode, expected] of [['empty', /UNKNOWN.*Coverage UNKNOWN.*NO HISTORY/], ['paused', /UNKNOWN.*Coverage UNKNOWN/], ['limit', /UNKNOWN.*Coverage UNKNOWN/]]) {
    await page.evaluate(mode => { monitorFixture.registerMode = mode; }, mode);
    await page.click('#monitorRefresh');
    await page.waitForFunction(() => !/Reading history|HISTORY UPDATING/.test(document.querySelector('[data-history-part="trail"]').textContent));
    assert.match(await metrics.textContent(), expected);
    assert.match(await page.locator('#monitorList').textContent(), /FIRING/);
    assert.equal(await trail.locator('[data-state="healthy"]').count(), 0);
    if (mode === 'paused') assert.equal(await trail.locator('[data-state="paused"]').count(), 24);
    if (mode === 'limit') assert.match(await trail.textContent(), /HISTORY UPDATE FAILED.*HTTP 422/);
  }
  // A delayed response from the previous refresh cannot replace the newer history.
  await page.evaluate(() => { monitorFixture.registerMode = ''; monitorFixture.deferRegister = true; });
  await page.click('#monitorRefresh');
  await page.waitForFunction(() => monitorFixture.pendingRegister.length === 1);
  await page.evaluate(() => { monitorFixture.registerMode = 'empty'; });
  await page.click('#monitorRefresh');
  assert.equal(await page.evaluate(() => monitorFixture.pendingRegister.length), 1);
  await page.evaluate(() => { monitorFixture.pendingRegister.shift()(); });
  await page.waitForFunction(() => monitorFixture.pendingRegister.length === 1);
  await page.evaluate(() => { monitorFixture.pendingRegister.shift()(); });
  await page.waitForFunction(() => document.querySelector('[data-history-part="metrics"]').textContent.includes('NO HISTORY'));
  assert.match(await metrics.textContent(), /NO HISTORY/);
  await page.click('#monitorRefresh');
  await page.waitForFunction(() => monitorFixture.pendingRegister.length === 1);
  await page.evaluate(async () => { currentWorkspaceId = 'other'; NRCMonitoring.disconnect(); monitorFixture.pendingRegister.shift()(); await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); });
  assert.equal(await trail.locator('.monitor-history-bar').count(), 0);
  assert.equal(await metrics.count(), 0);
  await page.evaluate(() => { currentWorkspaceId = 'fixture'; });
  // Switching tabs also invalidates held results, including fixtures ignoring abort.
  await page.click('#monitorRefresh');
  await page.waitForFunction(() => monitorFixture.pendingRegister.length === 1);
  await page.click('#monitorIncidentsTab');
  await page.evaluate(async () => { monitorFixture.pendingRegister.shift()(); await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); });
  assert.equal(await page.locator('[data-history-monitor]').count(), 0);
  assert.equal(await page.locator('#monitorHistoryLegend').isVisible(), false);
  await page.evaluate(() => { monitorFixture.deferRegister = false; monitorFixture.registerMode = ''; });
  await page.click('#monitorStatusTab');
  await page.waitForSelector('[data-monitor="12"]');
  await page.waitForSelector('[data-monitor="13"]');
  assert.equal(await page.locator('#monitorList tbody tr').count(), 2);
  await page.waitForFunction(() => document.querySelector('[data-history-monitor="13"][data-history-part="metrics"]')?.textContent.includes('NO HISTORY'));
  assert.match(await page.locator('#monitorSummary').textContent(), /2 \/ 2 LOADED MONITORS.*3 INSTANCES.*1 FIRING/);
  await page.fill('#monitorSearch', 'BACKUP');
  await page.waitForSelector('#monitorList [data-monitor="13"]');
  assert.deepEqual(await page.locator('#monitorList [data-monitor]').evaluateAll(nodes => nodes.map(n => n.dataset.monitor)), ['13']);
  assert.match(await page.locator('#monitorSummary').textContent(), /1 \/ 1 LOADED MONITORS.*2 INSTANCES.*0 FIRING/);
  await page.fill('#monitorSearch', '#12');
  await page.waitForSelector('#monitorList [data-monitor="12"]');
  assert.equal(await page.locator('#monitorList [data-monitor="12"]').count(), 1);
  await page.fill('#monitorSearch', '');
  for (const [state, ids] of [['problems', ['12']], ['healthy', ['13']], ['paused', []], ['all', ['12', '13']]]) {
    await page.selectOption('#monitorStateFilter', state);
    await page.waitForFunction(() => document.getElementById('monitorList').getAttribute('aria-busy') === 'false');
    if (state === 'all') await page.waitForSelector('[data-monitor="13"]');
    assert.deepEqual(await page.locator('#monitorList [data-monitor]').evaluateAll(nodes => nodes.map(n => n.dataset.monitor)), ids);
  }
  await page.waitForSelector('[data-monitor="13"]');
  // Boundaries 23/24 and 47/48 distinguish hourly input from 24-hour display buckets.
  await page.evaluate(() => { monitorFixture.registerRows = [
    { hour: 23, identity: 'a', healthy: 3600 }, { hour: 24, identity: 'a', failing: 3600 },
    { hour: 47, identity: 'a', healthy: 1800, paused: 1800 }, { hour: 48, identity: 'a', healthy: 3600 },
  ]; });
  for (const [days, coverage] of [[7, '2.08%'], [30, '0.48%']]) {
    await page.click(`[data-monitor-days="${days}"]`);
    await page.waitForFunction(days => document.querySelectorAll('[data-history-monitor="12"] .monitor-history-bar').length === days, days);
    assert.match(await metrics.textContent(), /71.42%/);
    assert.ok((await metrics.textContent()).includes(`Coverage ${coverage}`));
    assert.equal(await trail.locator('.monitor-history-bar').nth(0).getAttribute('data-state'), 'partial');
    assert.equal(await trail.locator('.monitor-history-bar').nth(1).getAttribute('data-state'), 'failing');
    assert.equal(await trail.locator('.monitor-history-bar').nth(2).getAttribute('data-state'), 'partial');
    const url = await page.evaluate(() => monitorFixture.historyRequests.findLast(u => new URL(u).searchParams.get('ids')?.split(',').includes('12')));
    const q = new URL(url).searchParams;
    assert.equal(Date.parse(q.get('to')) - Date.parse(q.get('from')), days * 86400000);
  }
  await page.evaluate(() => { delete monitorFixture.registerRows; });
  await page.evaluate(() => { monitorFixture.deferRegister = true; });
  await page.click('[data-monitor-days="7"]');
  await page.waitForFunction(() => monitorFixture.pendingRegister.length === 1);
  await page.click('[data-monitor-days="30"]');
  assert.equal(await page.evaluate(() => monitorFixture.pendingRegister.length), 1);
  await page.evaluate(() => { monitorFixture.deferRegister = false; monitorFixture.pendingRegister.shift()(); });
  await page.waitForFunction(() => document.querySelectorAll('[data-history-monitor="12"] .monitor-history-bar').length === 30);
  assert.equal(await trail.locator('.monitor-history-bar').count(), 30, 'Old period must not replace the current history');
  await page.click('[data-monitor-days="1"]');
  await page.waitForSelector('[data-history-monitor="12"] .monitor-history-bar');
  await page.waitForFunction(() => document.querySelector('[data-history-monitor="13"][data-history-part="metrics"]')?.textContent.includes('NO HISTORY'));
  await page.evaluate(() => { monitorFixture.secondState = 'paused'; });
  await page.click('#monitorRefresh');
  await page.waitForSelector('[data-monitor="13"]');
  await page.selectOption('#monitorStateFilter', 'paused');
  await page.waitForFunction(() => document.getElementById('monitorList').getAttribute('aria-busy') === 'false');
  assert.deepEqual(await page.locator('#monitorList [data-monitor]').evaluateAll(nodes => nodes.map(n => n.dataset.monitor)), ['13']);
  assert.match(await page.locator('#monitorSummary').textContent(), /1 \/ 1 LOADED MONITORS.*2 INSTANCES.*0 FIRING/);
  await page.selectOption('#monitorStateFilter', 'all');
  await page.waitForSelector('[data-monitor="12"]');
  await page.waitForFunction(() => document.querySelector('[data-history-monitor="13"][data-history-part="metrics"]')?.textContent.includes('NO HISTORY'));
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => {
    const list = document.getElementById('monitorRegisterScroll');
    const cards = [...document.querySelectorAll('#monitorList tbody tr')];
    return list.scrollWidth <= list.clientWidth && cards.every(card => {
      const bars = card.querySelector('.monitor-history-bars').getBoundingClientRect();
      const bounds = card.getBoundingClientRect();
      return bars.left >= bounds.left && bars.right <= bounds.right;
    });
  }), true);
  await page.setViewportSize({ width: 1280, height: 1000 });
  assert.deepEqual(await page.evaluate(() => ['table', 'thead tr', 'tbody', 'tbody tr', 'td'].map(s => getComputedStyle(document.querySelector(`#monitorList ${s}`)).display)), ['table', 'table-row', 'table-row-group', 'table-row', 'table-cell'], 'Task-register responsive rules must not leak into monitoring');
  await page.setViewportSize({ width: 1600, height: 1000 });
  // A held register read plus a held selection must leave the latest selection usable.
  await page.evaluate(() => { Object.assign(monitorFixture, { enforceAdmission: true, deferRegister: true, deferHistoryKind: 'inspector', instancePages: true }); });
  await page.click('#monitorRefresh');
  await page.waitForFunction(() => monitorFixture.pendingRegister.length === 1);
  await page.click('[data-monitor="12"]');
  await page.waitForSelector('[data-instance="0"]');
  assert.equal(await page.locator('#monitorInstances').isVisible(), true, 'One row with more pages is not a single instance');
  assert.equal(await page.locator('[data-instance="0"]').getAttribute('aria-pressed'), 'true', 'The first loaded instance is selected even with more pages available');
  assert.equal(await page.locator('#monitorSelection h3').textContent(), await page.locator('[data-instance="0"]').textContent());
  await page.setViewportSize({ width: 1280, height: 1000 });
  assert.equal(await page.locator('#monitorList thead').isVisible(), false, 'Narrow register beside Inspector must use cards even on desktop');
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.click('#monitorInstanceMore');
  await page.waitForSelector('[data-instance="1"]');
  assert.equal(await page.locator('[data-instance="0"]').getAttribute('aria-pressed'), 'true', 'Loading another page preserves the selection');
  await page.click('[data-instance="0"]');
  await page.waitForFunction(() => monitorFixture.pendingHistory.length === 1);
  await page.click('[data-monitor-days="7"]');
  await page.click('[data-monitor-days="30"]');
  assert.equal(await page.evaluate(() => monitorFixture.pendingRegister.length), 1, 'Replacement register reads wait for the occupied slot');
  await page.click('[data-instance="1"]');
  await page.click('[data-instance="0"]');
  await page.click('[data-instance="1"]');
  assert.equal(await page.evaluate(() => monitorFixture.rejectedHistory), 0);
  await page.evaluate(() => { monitorFixture.deferHistoryKind = ''; monitorFixture.pendingHistory.shift()(); });
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
  await page.waitForSelector('#monitorUptime .monitor-meter');
  assert.equal(await page.locator('[data-instance="1"]').getAttribute('aria-pressed'), 'true');
  assert.equal(await page.locator('#monitorSelection h3').textContent(), await page.locator('[data-instance="1"]').textContent(), 'Status rail identifies the selected instance');
  assert.equal(await page.evaluate(() => monitorFixture.admittedHistory.filter(url => url.includes('/inspector?')).length), 2);
  assert.equal(await page.evaluate(() => monitorFixture.maxActiveHistory), 2);
  assert.equal(await page.evaluate(() => monitorFixture.rejectedHistory), 0);
  await page.evaluate(() => { monitorFixture.deferRegister = false; monitorFixture.pendingRegister.shift()(); });
  await page.waitForFunction(() => monitorFixture.activeHistory === 0);
  assert.equal(await page.evaluate(() => monitorFixture.rejectedHistory), 0);
  assert.equal(await trail.locator('.monitor-history-bar').count(), 30, 'Only the latest queued period renders');
  await page.click('[data-monitor="12"]');
  await page.waitForSelector('[data-instance="0"]');
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
  await page.waitForSelector('#monitorUptime .monitor-meter');
  assert.match(await page.locator('#monitorHistory').textContent(), /MATCHES CURRENT EVALUATION.*503.*true/s);
  assert.match(await page.locator('#monitorUptime').textContent(), /66.66%.*1.04%/);
  assert.equal(await page.locator('.monitor-meter[data-kind="uptime"]').evaluate(e => e.style.getPropertyValue('--fill')), '66.66%');
  assert.equal(await page.locator('.monitor-meter[data-kind="coverage"]').evaluate(e => e.style.getPropertyValue('--fill')), '1.04%');
  assert.equal(await page.locator('.monitor-streak[data-state="fail"] .is-filled').count(), 5);
  assert.equal(await page.locator('.monitor-streak[data-state="pass"] .is-filled').count(), 0);
  assert.equal(await page.locator('.monitor-meter[data-kind="coverage"] > span').evaluate(e => getComputedStyle(e).backgroundColor), await page.locator('.monitor-thresholds dt').first().evaluate(e => getComputedStyle(e).color));
  assert.deepEqual(await page.locator('.monitor-conditions th:visible').allTextContents(), ['CONDITION', 'OBSERVED', 'RESULT']);
  assert.equal(await page.locator('[data-instance="0"]').getAttribute('aria-pressed'), 'true');
  assert.equal(await page.locator('.monitor-record details').count(), 0);
  assert.equal(await page.locator('#monitorHistoryDetails .monitor-checks').isVisible(), true);
  assert.equal(await page.locator('#monitorHistoryDetails table:visible').count(), 0);
  assert.doesNotMatch(await page.locator('#monitorHistoryDetails').innerText(), /confirmed|SEQ|buckets|ACCEPTANCE/);
  assert.match(await page.locator('#monitorHistoryDetails').textContent(), /PROCESS HISTORY DROPS: 2/);
  assert.doesNotMatch(await page.locator('#monitorUptime').textContent(), /ROLLUPS PENDING|CURRENT REVISION ONLY|HATCHED:/);
  const checkDefinition = await page.evaluate(() => monitorFixture.definition);
  for (const kind of ['http', 'tcp']) {
    await page.evaluate(kind => {
      if (kind === 'tcp') {
        for (const key of Object.keys(monitorFixture.definition)) delete monitorFixture.definition[key];
        Object.assign(monitorFixture.definition, { kind: 'tcp', address: 'example.test:443' });
        monitorFixture.runRows = [{ run_id: 'attempt-17', duration_ns: '125000000', diagnostics: { version: 1, error: 'connect_failed', conditions: [] } }];
      }
      monitorFixture.sampleRows = [
        { ago: 10, run_id: 'attempt-17', condition: 1, value: 0 },
        { ago: 60, run_id: 'unconfirmed', condition: 0, value: 1, acceptance: 'unknown' },
        { ago: 120, run_id: 'previous', condition: 0, value: 1, revision: '1' },
        { ago: 180, run_id: 'pass-b', condition: 0, value: 1 },
        { ago: 240, run_id: 'pass-a', condition: 0, value: 1 },
        { ago: 3601, run_id: 'outside', condition: 0, value: 1 },
      ];
    }, kind);
    await page.click('#monitorDetailRefresh');
    await page.click('[data-instance="0"]');
    await page.waitForFunction(() => document.querySelectorAll('.monitor-check').length === 5);
    assert.deepEqual(await page.locator('.monitor-check').evaluateAll(nodes => nodes.map(n => n.dataset.state)), ['healthy', 'healthy', 'unknown', 'unknown', 'failing']);
    assert.match(await page.locator('.monitor-recent-checks').textContent(), /2 OF 5 SHOWN CHECKS PASSED/);
    const detail = page.locator('.monitor-check-detail');
    for (const width of [1600, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      if (!await page.locator('.monitor-checks').isVisible()) {
        await page.click('[data-monitor="12"]');
        await page.click('[data-instance="0"]');
        await page.waitForFunction(() => document.querySelectorAll('.monitor-check').length === 5);
      }
      await page.waitForFunction(() => document.getElementById('monitorHistoryStatus').textContent === '');
      await page.locator('.monitor-checks').scrollIntoViewIfNeeded();
      const before = await page.locator('.monitor-checks').boundingBox();
      for (const index of [4, 0, 3, 4]) {
        const box = await page.locator('.monitor-check').nth(index).boundingBox();
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 8 });
        assert.equal((await page.locator('.monitor-checks').boundingBox()).y, before.y, 'Hover must not move the check strip under the pointer');
      }
      await page.mouse.move(before.x + before.width / 2, before.y - 4);
      assert.equal(await page.locator('.monitor-check-panels').isVisible(), false, 'Idle strip reserves no detail space');
      assert.equal((await page.locator('.monitor-checks').boundingBox()).y, before.y);
    }
    await page.setViewportSize({ width: 1600, height: 1000 });
    await page.locator('.monitor-check').last().hover();
    assert.match(await detail.textContent(), kind === 'http' ? /FAILED.*CHECK DURATION 125.0 ms.*503/s : /FAILED.*CHECK DURATION 125.0 ms.*connect_failed/s);
    await page.locator('.monitor-check').first().hover();
    assert.match(await detail.textContent(), /PASSED.*No per-condition diagnostics/s);
    assert.doesNotMatch(await detail.textContent(), /503|125.0/, 'Never borrow diagnostics from another run with the same sequence');
    await page.locator('.monitor-check').nth(2).click();
    await page.locator('.monitor-check').last().hover();
    assert.match(await detail.textContent(), /PREVIOUS CONFIGURATION/);
    assert.equal(await page.locator('.monitor-check').nth(2).getAttribute('aria-pressed'), 'true');
    await page.locator('.monitor-check').nth(2).press('Escape');
    assert.equal(await detail.textContent(), '');
    await page.locator('.monitor-check').nth(3).focus();
    assert.match(await detail.textContent(), /NOT CONFIRMED · UNKNOWN/);
    await page.locator('.monitor-check').nth(3).press('Enter');
    await page.locator('.monitor-check').last().hover();
    assert.match(await detail.textContent(), /NOT CONFIRMED · UNKNOWN/);
  }
  await page.evaluate(() => { monitorFixture.sampleRows = Array.from({ length: 23 }, (_, i) => ({ ago: (i + 1) * 60, condition: i < 20 ? 0 : 1, value: i < 20 ? 1 : 0 })); });
  await page.click('#monitorDetailRefresh');
  await page.click('[data-instance="0"]');
  await page.waitForFunction(() => document.querySelectorAll('.monitor-check').length === 20);
  assert.match(await page.locator('.monitor-recent-checks').textContent(), /20 OF 20 SHOWN CHECKS PASSED/);
  await page.evaluate(() => { monitorFixture.sampleRows = []; });
  await page.click('#monitorDetailRefresh');
  await page.click('[data-instance="0"]');
  await page.waitForFunction(() => document.getElementById('monitorHistoryDetails').textContent.includes('No checks retained'));
  assert.equal(await page.locator('.monitor-check').count(), 0);
  await page.evaluate(definition => {
    delete monitorFixture.sampleRows; delete monitorFixture.runRows;
    for (const key of Object.keys(monitorFixture.definition)) delete monitorFixture.definition[key];
    Object.assign(monitorFixture.definition, definition);
  }, checkDefinition);
  await page.click('#monitorDetailRefresh');
  await page.evaluate(() => { monitorFixture.drops = '0'; monitorFixture.rollups = '0'; });
  await page.click('[data-instance="0"]');
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
  await page.waitForSelector('#monitorUptime .monitor-meter');
  assert.doesNotMatch(await page.locator('.monitor-record').textContent(), /HISTORY DROPS|ROLLUPS PENDING/);
  // Replacing the instance snapshot must invalidate both rendered and pending history.
  await page.evaluate(() => { monitorFixture.statusSequence = '18'; });
  await page.check('#monitorRetired');
  await page.waitForFunction(() => document.getElementById('monitorInstanceStatus').textContent.includes('LOADED'));
  assert.doesNotMatch(await page.locator('#monitorHistory').textContent(), /MATCHES CURRENT EVALUATION/);
  assert.equal(await page.locator('[data-instance="0"]').getAttribute('aria-pressed'), 'true', 'Replacing the snapshot selects its first instance');
  await page.evaluate(() => { monitorFixture.statusSequence = '17'; monitorFixture.deferHistoryKind = 'inspector'; });
  await page.uncheck('#monitorRetired');
  await page.click('[data-instance="0"]');
  await page.waitForFunction(() => monitorFixture.pendingHistory.length === 1);
  await page.evaluate(() => { monitorFixture.statusSequence = '18'; });
  await page.check('#monitorRetired');
  await page.waitForFunction(() => document.getElementById('monitorInstanceStatus').textContent.includes('LOADED'));
  await page.evaluate(async () => {
    monitorFixture.deferHistoryKind = '';
    monitorFixture.pendingHistory.shift()();
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
  assert.match(await page.locator('#monitorHistory').textContent(), /HISTORICAL \/ NOT CURRENT/);
  assert.doesNotMatch(await page.locator('#monitorHistory').textContent(), /MATCHES CURRENT EVALUATION|Reading history/);

  // A filter reset cannot continue the old cursor, even through a queued click.
  await page.evaluate(() => { monitorFixture.instancePages = true; });
  await page.uncheck('#monitorRetired');
  await page.waitForSelector('#monitorInstanceMore:not([hidden])');
  await page.evaluate(() => { monitorFixture.deferInstances = true; });
  await page.check('#monitorRetired');
  await page.waitForFunction(() => monitorFixture.pendingStatus.length === 1);
  assert.equal(await page.locator('#monitorInstanceMore').isDisabled(), true);
  await page.evaluate(() => { document.getElementById('monitorInstanceMore').onclick(); });
  assert.equal(await page.evaluate(() => monitorFixture.pendingStatus.length), 1);
  assert.equal(await page.locator('#monitorInstances [data-instance]').count(), 0);
  await page.evaluate(() => { monitorFixture.pendingStatus.shift()(); });
  await page.waitForFunction(() => document.getElementById('monitorInstances').textContent.includes('included-first'));
  await page.click('#monitorInstanceMore');
  await page.waitForFunction(() => monitorFixture.pendingStatus.length === 1);
  assert.deepEqual(await page.evaluate(() => { const r = monitorFixture.requests.at(-1); return [r.cursor, r.retired]; }), ['41', true]);
  // Deliver the replacement first, then a late continuation from the old filter.
  await page.uncheck('#monitorRetired');
  await page.waitForFunction(() => monitorFixture.pendingStatus.length === 2);
  await page.evaluate(() => { monitorFixture.pendingStatus.pop()(); });
  await page.waitForFunction(() => document.getElementById('monitorInstances').textContent.includes('active-first'));
  await page.evaluate(async () => {
    monitorFixture.pendingStatus.shift()();
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
  assert.doesNotMatch(await page.locator('#monitorInstances').textContent(), /included-/);
  assert.equal(await page.locator('#monitorInstances [data-instance]').count(), 1);
  await page.evaluate(() => { monitorFixture.deferInstances = false; });
  await page.click('#monitorInstanceMore');
  await page.waitForFunction(() => document.getElementById('monitorInstances').textContent.includes('active-next'));
  assert.equal(await page.locator('#monitorInstances [data-instance]').count(), 2);
  await page.evaluate(() => { monitorFixture.statusSequence = '17'; });
  await page.check('#monitorRetired');
  await page.evaluate(() => { monitorFixture.old = true; });
  await page.click('[data-instance="0"]');
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
  await page.waitForFunction(() => document.getElementById('monitorHistory').textContent.includes('HISTORICAL / NOT CURRENT'));
  assert.match(await page.locator('#monitorHistory').textContent(), /definition revision unavailable/);
  for (const mismatch of [{ unknown: true, sequence: '17' }, { unknown: false, sequence: '16' }]) {
    await page.evaluate(value => Object.assign(monitorFixture, { old: false }, value), mismatch);
    await page.click('[data-instance="0"]');
    await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
    await page.waitForFunction(() => document.getElementById('monitorHistory').textContent.includes('HISTORICAL / NOT CURRENT'));
    assert.doesNotMatch(await page.locator('#monitorHistory').textContent(), /definition revision unavailable/);
    if (mismatch.unknown) {
      assert.match(await page.locator('#monitorHistory').textContent(), /NOT CONFIRMED/);
      assert.match(await page.locator('.monitor-check').first().getAttribute('aria-label'), /NOT CONFIRMED · UNKNOWN/);
    }
  }
  await page.evaluate(() => { monitorFixture.instancePages = false; monitorFixture.sequence = '17'; monitorFixture.identity = JSON.stringify({ host: 'cluster01c', mountpoint: '/var/lib/mysql', label: '<img src=x onerror=alert(1)>' }); });
  await page.uncheck('#monitorRetired');
  await page.waitForFunction(() => document.getElementById('monitorHistory').textContent.includes('MATCHES CURRENT EVALUATION'));
  assert.equal(await page.locator('#monitorInstances').isVisible(), false, 'A complete single-instance result opens automatically');
  assert.match(await page.locator('#monitorSelection').textContent(), /host cluster01c.*mountpoint \/var\/lib\/mysql.*<img/s);
  assert.equal(await page.locator('#monitorSelection img').count(), 0);
  assert.equal(await page.locator('#monitorHistoryDetails .monitor-checks').isVisible(), true);
  assert.equal(await page.locator('#monitorSelection [data-state="firing"]').count(), 1);
  assert.equal(await page.locator('#monitorHistory').textContent().then(t => t.includes('cluster01c')), false);
  const previousViewport = page.viewportSize();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.click('[data-monitor="12"]');
  await page.waitForSelector('#monitorHistoryDetails .monitor-checks');
  const lastCheck = page.locator('#monitorHistoryDetails .monitor-check').last();
  await lastCheck.scrollIntoViewIfNeeded();
  const checkBox = await lastCheck.boundingBox();
  assert.ok(checkBox.y >= 0 && checkBox.y + checkBox.height <= 844, 'Last check remains reachable by scrolling on narrow screens');
  await page.setViewportSize(previousViewport);
  // Partial streaks and missing/paused history must not look complete or healthy.
  await page.evaluate(() => { Object.assign(monitorFixture, { failures: 2, recoveries: 3, uptimeRows: [] }); });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
  await page.waitForSelector('#monitorUptime .monitor-meter');
  assert.equal(await page.locator('.monitor-streak[data-state="fail"] .is-filled').count(), 2);
  assert.equal(await page.locator('.monitor-streak[data-state="pass"] .is-filled').count(), 3);
  assert.match(await page.locator('.monitor-meter[data-kind="uptime"]').getAttribute('aria-label'), /UNKNOWN/);
  assert.equal(await page.locator('.monitor-meter[data-kind="uptime"]').getAttribute('data-known'), 'false');
  assert.equal(await page.locator('.monitor-meter[data-kind="coverage"]').evaluate(e => e.style.getPropertyValue('--fill')), '0%');
  await page.evaluate(() => {
    monitorFixture.config.failures = 100;
    monitorFixture.failures = 25;
    monitorFixture.uptimeRows = [{ healthy_ns: '0', failing_ns: '0', unknown_ns: '0', paused_ns: '86400000000000' }];
  });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
  await page.waitForSelector('#monitorUptime .monitor-meter');
  assert.match(await page.locator('.monitor-streak[data-state="fail"]').textContent(), /25\/100/);
  assert.equal(await page.locator('.monitor-streak-track > i').evaluate(e => e.style.width), '25%');
  assert.match(await page.locator('.monitor-meter[data-kind="coverage"]').getAttribute('aria-label'), /UNKNOWN/);
  await page.evaluate(() => { monitorFixture.config.failures = 5; Object.assign(monitorFixture, { failures: 5, recoveries: 0, uptimeRows: undefined }); });
  // An automatic read must not repopulate a replacement snapshot with no instances.
  await page.evaluate(() => { monitorFixture.deferHistoryKind = 'inspector'; });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => monitorFixture.pendingHistory.length === 1);
  await page.evaluate(() => { monitorFixture.empty = true; });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => document.getElementById('monitorInstanceStatus').textContent.includes('0 LOADED'));
  await page.evaluate(async () => { monitorFixture.pendingHistory.shift()(); await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); });
  assert.equal(await page.locator('#monitorSelection').textContent(), '');
  assert.equal(await page.locator('#monitorHistoryDetails').textContent(), '');
  assert.equal(await page.locator('#monitorUptime').isVisible(), false);
  await page.evaluate(() => { monitorFixture.empty = false; monitorFixture.deferHistoryKind = ''; });
  // Automatic refresh must keep both a stale result warning and history visible.
  await page.evaluate(() => { monitorFixture.old = true; });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => document.getElementById('monitorHistory').textContent.includes('HISTORICAL / NOT CURRENT'));
  assert.equal(await page.locator('#monitorHistory').isVisible(), true);
  assert.equal(await page.locator('#monitorHistoryDetails .monitor-checks').isVisible(), true);
  await page.evaluate(() => { monitorFixture.fail = true; });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus').textContent.includes('HTTP 503'));
  await page.click('#monitorSelection [data-incident="51"]');
  await page.waitForSelector('#incidentAck');
  await page.click('#incidentAck');
  await page.waitForFunction(() => document.getElementById('incidentAck')?.disabled);
  assert.match(await page.locator('.monitor-record').textContent(), /FIRING.*rene/s);
  await page.fill('[name="assignee"]', 'oncall');
  await page.locator('#incidentAssignment button').click();
  await page.waitForFunction(() => document.querySelector('[name=assignee]')?.value === 'oncall' && monitorFixture.actions.length === 2);
  assert.deepEqual(await page.evaluate(() => monitorFixture.actions), [{ action: 0, assignee: '' }, { action: 1, assignee: 'oncall' }]);
  // Display metadata formats each numeric condition, not its neighbors or verdict.
  await page.evaluate(() => {
    Object.assign(monitorFixture, { fail: false, old: false, unknown: false });
    monitorFixture.previousDefinition = structuredClone(monitorFixture.definition);
    Object.assign(monitorFixture.definition, { kind: 'http', conditions: [{ field: 'json', path: '/n', op: '>', value: 1024 }] });
    monitorFixture.runRows = [{ diagnostics: { conditions: [{ index: 0, state: 'pass', actual_type: 'number', actual: '1536', expected_number: '1024' }] } }];
  });
  for (const [unit, actual, expected, display, threshold] of [
    ['bytes', '1536', '1024', '1.5 KiB', '1 KiB'],
    ['bits', '1536', '1024', '1.54 kbit', '1.02 kbit'],
    ['nanoseconds', '6657382707732876', '1814400000000000', '77.05 d', '21 d'],
    ['nanoseconds', '999', '1000', '999 ns', '1 µs'],
    ['microseconds', '1500', '1000', '1.5 ms', '1 ms'],
    ['milliseconds', '-1500', '0', '-1.5 s', '0 ns'],
    ['seconds', '3600', '60', '1 h', '1 min'],
    ['percent', '12.345', '90', '12.35 %', '90 %'],
    ['percent_ratio', '0.12345', '0.9', '12.35 %', '90 %'],
  ]) {
    await page.evaluate(({ unit, actual, expected }) => {
      monitorFixture.definition.conditions[0].unit = unit;
      Object.assign(monitorFixture.runRows[0].diagnostics.conditions[0], { actual, expected_number: expected });
    }, { unit, actual, expected });
    await page.click('[data-monitor="12"]');
    await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '' && document.querySelector('#monitorHistory table'));
    assert.equal(await page.locator('#monitorHistory tbody td:nth-child(2)').textContent(), display);
    assert.equal(await page.locator('#monitorHistory tbody td:nth-child(2)').getAttribute('title'), actual);
    assert.equal(await page.locator('#monitorHistory tbody td:first-child').textContent(), `json/n > ${threshold}`);
    assert.match(await page.locator('#monitorHistory tbody td:last-child').textContent(), /PASS/);
  }
  await page.evaluate(() => { monitorFixture.old = true; });
  await page.click('[data-monitor="12"]');
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '' && document.getElementById('monitorHistory').textContent.includes('definition revision unavailable'));
  assert.equal(await page.locator('#monitorHistory tbody td:nth-child(2)').textContent(), '0.12345 [number]', 'Old diagnostics never borrow current units');
  await page.evaluate(() => {
    monitorFixture.old = false;
    monitorFixture.rawDefinition = '{"kind":"http","url":"https://example.com","conditions":[{"field":"json","path":"/large","op":">","value":9007199254740993},{"field":"json","path":"/healthy","op":"==","value":true}]}';
    monitorFixture.originalConditionPatch = NRCTransactions.sendAssetMetadataPatch;
    monitorFixture.conditionPatches = [];
    NRCTransactions.sendAssetMetadataPatch = (asset, preview, payload, callbacks) => {
      monitorFixture.conditionPatches.push({ revision: String(asset.updatedAt), preview, payload });
      if (monitorFixture.conditionConflict) queueMicrotask(() => callbacks.onError({ message: 'Revision conflict' }));
      else { monitorFixture.rawDefinition = payload; queueMicrotask(callbacks.onSuccess); }
      return 1;
    };
  });
  await page.click('[data-monitor="12"]');
  await page.waitForSelector('[data-condition-unit="0"]');
  assert.equal(await page.locator('[data-condition-unit]').count(), 1, 'Boolean conditions do not receive numeric display controls');
  await page.selectOption('[data-condition-unit="0"]', 'bytes');
  await page.click('#monitorConditionDisplay button');
  await page.waitForFunction(() => document.querySelector('[data-condition-unit="0"]')?.value === 'bytes' && !document.querySelector('#monitorConditionDisplay').inert);
  const patch = await page.evaluate(() => monitorFixture.conditionPatches[0]);
  assert.equal(patch.preview, null, 'Condition units only patch the check payload');
  assert.match(patch.payload, /"value":9007199254740993,"unit":"bytes"/);
  assert.match(patch.payload, /"path":"\/healthy","op":"==","value":true/);
  await page.evaluate(() => { monitorFixture.conditionConflict = true; });
  await page.selectOption('[data-condition-unit="0"]', 'bits');
  await page.click('#monitorConditionDisplay button');
  await page.waitForFunction(() => document.getElementById('monitorUnitStatus').textContent.includes('Revision conflict'));
  assert.equal(await page.locator('[data-condition-unit="0"]').inputValue(), 'bits');
  assert.equal(await page.evaluate(() => monitorFixture.conditionPatches.length), 2, 'Conflicting saves are not replayed');
  await page.evaluate(() => {
    NRCTransactions.sendAssetMetadataPatch = monitorFixture.originalConditionPatch;
    delete monitorFixture.rawDefinition; delete monitorFixture.runRows;
    Object.assign(monitorFixture.definition, monitorFixture.previousDefinition);
  });
  // Units change presentation, never the raw measurements or threshold positions.
  await page.evaluate(() => {
    Object.assign(monitorFixture.definition, { kind: 'victoriametrics', query: 'filesystem query', trigger: { op: '>', value: 90 }, recovery: { op: '<', value: 85 } });
    delete monitorFixture.definition.conditions;
    delete monitorFixture.definition.url;
    Object.assign(monitorFixture, { instancePages: true, instanceLabels: ['{"instance":"cluster01c:9100","mountpoint":"/home/media03"}'], fail: true, old: false });
  });
  for (const [unit, value, expected] of [['percent', 92.74672464115285, '92.75 %'], ['bytes', 1536, '1.5 KiB'], ['bytes', 1073741824, '1 GiB'], ['bytes', 1023, '1023 B'], ['number', 0.00000123, '1.23e-6'], ['percent', 0, '0 %'], ['percent', null, '—']]) {
    await page.evaluate(({ unit, value }) => { monitorFixture.config.unit = unit; monitorFixture.value = value; }, { unit, value });
    await page.click('[data-monitor="12"]');
    await page.waitForSelector('#monitorInstances tbody tr');
    assert.equal(await page.locator('#monitorInstances tbody td:nth-child(3)').first().textContent(), expected);
    assert.equal(await page.locator('#monitorInstances tbody td:nth-child(3)').first().getAttribute('title'), String(value ?? '—'));
    assert.equal(await page.locator('#monitorUnit').inputValue(), unit);
    for (const width of [1600, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.click('[data-monitor="12"]');
      await page.waitForSelector('#monitorInstances tbody tr');
      assert.equal(await page.locator('#monitorInstances thead').isVisible(), true);
      assert.equal(await page.locator('#monitorInstances').evaluate(host => host.scrollWidth <= host.clientWidth), true, `Instance columns fit at ${width}px`);
      assert.equal(await page.locator('#monitorInstances tbody td:nth-child(3)').first().evaluate(cell => {
        const range = document.createRange(); range.selectNodeContents(cell);
        return range.getClientRects().length === 1;
      }), true, 'A measurement never wraps across lines');
    }
    await page.setViewportSize({ width: 1600, height: 1000 });
  }
  await page.evaluate(() => {
    monitorFixture.config.unit = 'bytes';
    Object.assign(monitorFixture, { value: 1536, fail: false, sampleRows: [{ ago: 60, value: 1536 }] });
    Object.assign(monitorFixture.definition, { trigger: { op: '>', value: 1024 }, recovery: { op: '<', value: 512 } });
  });
  await page.click('[data-monitor="12"]');
  await page.waitForSelector('[data-instance="0"]');
  await page.click('[data-instance="0"]');
  await page.waitForSelector('.monitor-timeseries svg');
  const selectedValues = page.locator('#monitorSelection .monitor-reading strong, #monitorSelection .monitor-thresholds dd');
  assert.deepEqual(await selectedValues.allTextContents(), ['1.5 KiB', '> 1 KiB', '< 512 B']);
  assert.equal(await page.locator('#monitorHistory table').count(), 0);
  assert.match(await page.locator('.monitor-chart-points title').first().textContent(), /1.5 KiB · RAW 1536/);
  assert.match(await page.locator('.monitor-chart-legend').textContent(), /TRIGGER > 1 KiB.*RECOVERY < 512 B/);
  assert.deepEqual(await page.locator('.monitor-value-scale [data-scale]').evaluateAll(lanes => lanes.map(g => g.dataset.scale === 'value' ? +g.querySelector('circle').getAttribute('cx') : +g.querySelector('.monitor-scale-marker').getAttribute('d').match(/^M([^,]+)/)[1])), [448, 280, 112], 'IEC formatting does not alter raw-value positions');
  await page.evaluate(() => {
    monitorFixture.value = 1536;
    monitorFixture.fail = true;
    delete monitorFixture.sampleRows;
    monitorFixture.config.unit = 'number';
    monitorFixture.savedUnitPatches = [];
    monitorFixture.originalPatch = NRCTransactions.sendAssetMetadataPatch;
    NRCTransactions.sendAssetMetadataPatch = (asset, preview, payload, callbacks) => {
      monitorFixture.savedUnitPatches.push({ revision: String(asset.updatedAt), preview: JSON.parse(preview), payload });
      if (monitorFixture.unitConflict) queueMicrotask(() => callbacks.onError({ message: 'Revision conflict' }));
      else { Object.assign(monitorFixture.config, JSON.parse(preview)); queueMicrotask(callbacks.onSuccess); }
      return 1;
    };
  });
  await page.click('[data-monitor="12"]');
  await page.waitForSelector('#monitorUnit');
  const rawDefinition = await page.evaluate(() => JSON.stringify(monitorFixture.definition));
  await page.selectOption('#monitorUnit', 'bytes');
  await page.click('#monitorDisplay button');
  await page.waitForFunction(() => document.querySelector('#monitorInstances tbody td:nth-child(3)')?.textContent === '1.5 KiB');
  assert.equal(await page.locator('#monitorUnit').inputValue(), 'bytes', 'Saved unit survives the Inspector reload');
  assert.deepEqual(await page.evaluate(() => ({ payload: monitorFixture.savedUnitPatches[0].payload, definition: JSON.stringify(monitorFixture.definition), raw: monitorFixture.value })), { payload: null, definition: rawDefinition, raw: 1536 });
  await page.evaluate(() => { monitorFixture.unitConflict = true; });
  await page.selectOption('#monitorUnit', 'percent');
  await page.click('#monitorDisplay button');
  await page.waitForFunction(() => document.getElementById('monitorUnitStatus').textContent.includes('Revision conflict'));
  assert.equal(await page.locator('#monitorUnit').inputValue(), 'percent', 'A failed save retains the chosen unit for review');
  assert.equal(await page.evaluate(() => monitorFixture.config.unit), 'bytes', 'Conflicting save does not overwrite the saved unit');
  assert.equal(await page.evaluate(() => monitorFixture.savedUnitPatches.length), 2, 'No automatic retry after an uncertain write');
  await page.evaluate(() => {
    NRCTransactions.sendAssetMetadataPatch = monitorFixture.originalPatch;
    delete monitorFixture.config.unit;
    delete monitorFixture.instanceLabels;
    monitorFixture.instancePages = false;
  });
  // Victoria uses the selected NRC snapshot, never HTTP diagnostics or History availability.
  for (const kind of ['victoriametrics', 'victorialogs']) {
    await page.evaluate(kind => {
      Object.assign(monitorFixture.definition, { kind, query: 'fixture query', trigger: { op: '<', value: 10 }, recovery: { op: '>', value: 15 } });
      delete monitorFixture.definition.conditions;
      delete monitorFixture.definition.url;
      Object.assign(monitorFixture, { value: 18.4, recoveries: 3, failures: 0, fail: true, old: false });
    }, kind);
    await page.click('[data-monitor="12"]');
    await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent.includes('HTTP 503'));
    assert.deepEqual(await selectedValues.allTextContents(), ['18.4', '< 10', '> 15']);
    assert.equal(await page.locator('#monitorSelection [data-state="firing"]').count(), 1);
    assert.match(await page.locator('#monitorSelection').textContent(), /RECOVER 3\/5/);
    assert.deepEqual(await page.locator('.monitor-value-scale').evaluate(svg => [...svg.querySelectorAll('[data-scale]')].map(g => g.dataset.scale === 'value' ? +g.querySelector('circle').getAttribute('cx') : +g.querySelector('.monitor-scale-marker').getAttribute('d').match(/^M([^,]+)/)[1])), [448, 112, 312], 'Same numeric axis even when History is unavailable; recovery-range value does not change FIRING');
    await page.evaluate(() => {
      monitorFixture.fail = false;
      monitorFixture.sampleRows = [
        { ago: 600, value: 25 }, { ago: 540, value: 20 },
        { ago: 480, value: 18, acceptance: 'unknown' }, { ago: 420, value: 16 },
        { ago: 360, value: null }, { ago: 300, value: 14 },
        { ago: 180, value: 12 }, { ago: 150, value: 9999, revision: '1' },
        { ago: 120, value: 11 }, { ago: 60, value: 7 },
      ].reverse(); // Rendering must order observations, not rely on arrival order.
    });
    await page.click('#monitorDetailRefresh');
    await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
    await page.waitForSelector('#monitorUptime .monitor-meter');
    assert.deepEqual(await selectedValues.allTextContents(), ['18.4', '< 10', '> 15']);
    assert.doesNotMatch(await page.locator('#monitorHistory').textContent(), /No per-condition|503|PASS/);
    const chart = page.locator('#monitorHistoryDetails .monitor-timeseries');
    assert.equal(await page.locator('#monitorHistoryDetails table').count(), 0);
    assert.equal(await chart.locator('circle').count(), 7);
    assert.equal(await chart.locator('rect').count(), 1);
    assert.match(await chart.locator('rect title').textContent(), /18 · NOT CONFIRMED: unknown/);
    assert.doesNotMatch(await chart.textContent(), /9999/);
    assert.equal((await chart.locator('.monitor-chart-trace').getAttribute('d')).match(/L/g).length, 2, 'Only adjacent confirmed values connect, never across missing values, revisions or time gaps');
    const geometry = await chart.evaluate(e => ({
      firstX: +e.querySelector('circle').getAttribute('cx'), lastX: +e.querySelector('circle:last-child').getAttribute('cx'),
      triggerY: +e.querySelector('line[data-threshold="trigger"]').getAttribute('y1'), recoveryY: +e.querySelector('line[data-threshold="recovery"]').getAttribute('y1'),
      firstY: +e.querySelector('circle').getAttribute('cy'), lastY: +e.querySelector('circle:last-child').getAttribute('cy'),
    }));
    assert.ok(Math.abs(geometry.firstX - (64 + 400 * 50 / 60)) < 0.001, 'A late-starting series must not stretch across the whole hour');
    assert.ok(Math.abs(geometry.lastX - geometry.firstX - 60) < 0.001);
    assert.ok(geometry.firstY < geometry.recoveryY && geometry.recoveryY < geometry.triggerY && geometry.triggerY < geometry.lastY, 'Values and thresholds use the same numeric scale');
    const svg = chart.locator('svg'), readout = chart.locator('.monitor-chart-readout');
    await svg.scrollIntoViewIfNeeded();
    assert.equal(await chart.locator('circle').first().evaluate(e => getComputedStyle(e).opacity), '0', 'Connected points do not form a permanent dot cloud');
    assert.equal(await chart.locator('circle').nth(2).evaluate(e => getComputedStyle(e).opacity), '1', 'Isolated values remain visible');
    const position = async x => svg.evaluate((e, x) => { const p = new DOMPoint(x, 80).matrixTransform(e.getScreenCTM()); return { x: p.x, y: p.y }; }, x);
    const first = await position(64 + 400 * 50 / 60);
    await page.mouse.move(first.x, first.y);
    assert.match(await readout.textContent(), / · 25$/);
    assert.equal(await chart.locator('circle').first().evaluate(e => getComputedStyle(e).opacity), '1');
    await page.mouse.move(0, 0);
    assert.equal(await readout.textContent(), 'Hover or tap for values');
    await svg.press('Home');
    await svg.press('ArrowRight');
    assert.match(await readout.textContent(), / · 20$/);
    await svg.press('End');
    assert.match(await readout.textContent(), / · 7$/);
    await svg.press('Escape');
    // Chromium touch input, not a synthetic DOM click: tapping pins and tapping again clears.
    const touch = await page.context().newCDPSession(page);
    await touch.send('Emulation.setTouchEmulationEnabled', { enabled: true });
    const unknown = await position(64 + 400 * 52 / 60);
    for (const expected of [/18 · NOT CONFIRMED: unknown/, /Hover or tap for values/]) {
      await touch.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [unknown] });
      await touch.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      assert.match(await readout.textContent(), expected);
    }
    await touch.send('Emulation.setTouchEmulationEnabled', { enabled: false });
    await touch.detach();
    await page.evaluate(() => { monitorFixture.sampleRows = Array.from({ length: 32 }, (_, i) => ({ ago: (i + 1) * 60, value: 0 })); });
    await page.click('#monitorDetailRefresh');
    await page.waitForFunction(() => document.querySelectorAll('#monitorHistoryDetails circle').length === 32);
    assert.doesNotMatch(await chart.innerHTML(), /NaN|Infinity/);
    await page.evaluate(() => { monitorFixture.sampleRows = [{ ago: 60, value: 123, revision: '1' }]; });
    await page.click('#monitorDetailRefresh');
    await page.waitForFunction(() => document.getElementById('monitorHistoryDetails')?.textContent.includes('No numeric samples for the current revision'));
    assert.equal(await chart.count(), 0, 'Previous-revision samples must not be compared to new thresholds');
    await page.evaluate(() => { monitorFixture.statusRevision = '1'; monitorFixture.value = null; delete monitorFixture.definition.recovery; monitorFixture.sampleRows = [{ ago: 60, value: -3 }]; });
    await page.click('#monitorDetailRefresh');
    await page.waitForFunction(() => document.getElementById('monitorHistory')?.textContent.includes('CONFIGURATION CHANGED'));
    assert.deepEqual(await selectedValues.allTextContents(), ['—', '< 10', 'When trigger no longer matches']);
    assert.equal(await page.locator('.monitor-value-scale').count(), 0);
    await page.waitForSelector('#monitorHistoryDetails circle');
    assert.equal(await chart.locator('line').count(), 1, 'An absent recovery threshold must not invent a zero line');
    assert.match(await chart.locator('circle title').textContent(), / · -3$/);
    assert.equal(await chart.locator('.monitor-chart-trace').getAttribute('d'), '', 'A single point remains a point, not a fabricated history');
    await page.evaluate(() => { delete monitorFixture.statusRevision; });
  }
  for (const scenario of [
    { value: -5, trigger: 0, recovery: 10, expected: [112, 224, 448] },
    { value: 0, trigger: 0, recovery: 0, expected: [280, 280, 280] },
    { value: 3, trigger: 0, expected: [448, 112] },
    { value: null, trigger: 0, expected: [] },
    { value: 3, trigger: 0, revision: '1', expected: [] },
  ]) {
    await page.evaluate(s => {
      monitorFixture.value = s.value; monitorFixture.statusRevision = s.revision;
      monitorFixture.definition.trigger = { op: '>', value: s.trigger };
      if (s.recovery !== undefined) monitorFixture.definition.recovery = { op: '<', value: s.recovery };
      else delete monitorFixture.definition.recovery;
    }, scenario);
    await page.click('#monitorDetailRefresh');
    await page.waitForSelector('#monitorSelection .monitor-thresholds');
    const positions = await page.locator('#monitorHistory').evaluate(host => [...host.querySelectorAll('[data-scale]')].map(g => g.dataset.scale === 'value' ? +g.querySelector('circle').getAttribute('cx') : +g.querySelector('.monitor-scale-marker').getAttribute('d').match(/^M([^,]+)/)[1]));
    assert.deepEqual(positions, scenario.expected);
  }
  for (const key of ['trigger', 'recovery']) {
    await page.evaluate(key => {
      monitorFixture.value = 10; delete monitorFixture.statusRevision;
      monitorFixture.sampleRows = [{ ago: 120, value: 8 }, { ago: 60, value: 10 }];
      monitorFixture.rawDefinition = JSON.stringify({ ...monitorFixture.definition, trigger: { op: '>', value: 12 }, recovery: { op: '<', value: 9 }, [key]: { op: key === 'trigger' ? '>' : '<', value: 'OVERFLOW' } }).replace('"OVERFLOW"', key === 'trigger' ? '99e308' : '-99e308');
    }, key);
    await page.click('#monitorDetailRefresh');
    await page.waitForFunction(() => document.getElementById('monitorHistoryStatus')?.textContent === '');
    await page.waitForSelector('.monitor-timeseries svg');
    assert.equal(await page.locator('.monitor-value-scale').count(), 0);
    assert.match(await page.locator('#monitorHistory').textContent(), /Scale unavailable: threshold outside browser numeric range/);
    assert.match(await page.locator('.monitor-chart-legend').textContent(), /outside browser numeric range; not plotted/);
    assert.equal(await page.locator('.monitor-timeseries svg line').count(), 1);
    assert.doesNotMatch(await page.locator('.monitor-timeseries svg').innerHTML(), /NaN|Infinity/);
    assert.equal(await page.locator('.monitor-chart-points [data-point]').count(), 2);
  }
  await page.evaluate(() => {
    delete monitorFixture.rawDefinition;
    monitorFixture.instancePages = true;
    monitorFixture.instanceLabels = [JSON.stringify({ instance: '<cluster01c>', mountpoint: '/var/lib/mysql/tenant-with-a-long-name/replication-data/archive', namespace: 'production' }), 'legacy identity'];
  });
  await page.click('#monitorDetailRefresh');
  await page.waitForSelector('[data-instance="0"]');
  await page.click('#monitorInstanceMore');
  await page.waitForSelector('[data-instance="1"]');
  assert.deepEqual(await page.locator('[data-instance="0"] small').allTextContents(), ['mountpoint', 'namespace']);
  assert.match(await page.locator('[data-instance="0"]').textContent(), /<cluster01c>.*\/var\/lib\/mysql.*production/);
  assert.equal(await page.locator('[data-instance="0"] cluster01c').count(), 0, 'Identity values remain escaped');
  assert.equal(await page.locator('[data-instance="1"]').textContent(), 'legacy identity');
  assert.doesNotMatch(await page.locator('#monitorInstances').textContent(), /FAIL |RECOVER /);
  assert.equal(await page.locator('#monitorInstances [data-incident]').first().textContent(), '#51');
  await page.click('[data-instance="0"]');
  assert.equal(await page.locator('[data-instance="0"]').getAttribute('aria-pressed'), 'true');
  assert.match(await page.locator('#monitorSelection').textContent(), /FAIL.*RECOVER/s, 'Streaks remain in selected details');
  assert.match(await page.locator('#monitorSelection').textContent(), /cluster01c.*mountpoint.*namespace/s);
  await page.click('[data-instance="1"]');
  assert.equal(await page.locator('[data-instance="0"]').getAttribute('aria-pressed'), 'false');
  assert.equal(await page.locator('[data-instance="1"]').getAttribute('aria-pressed'), 'true');
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 390, 'Long identities wrap without overflowing the narrow Inspector');
  assert.match(await page.locator('[data-instance="0"]').textContent(), /replication-data\/archive/);
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.locator('#monitorInstances [data-incident]').first().click();
  await page.waitForSelector('#incidentAck');
  await page.evaluate(() => { NRCMonitoring.disconnect(); });
  assert.match(await page.locator('#inspectorEntityHost').textContent(), /Offline/);
  assert.equal(await page.locator('#incidentAck').count(), 0);
  // Polling reloads server-ranked pages; unchanged histories are not fetched again.
  await page.setViewportSize({ width: 1600, height: 600 });
  await page.clock.install({ time: new Date('2026-11-18T10:30:00Z') });
  await page.reload();
  await page.clock.pauseAt(new Date('2026-11-18T10:31:00Z'));
  await page.evaluate(installMonitoringFixture);
  await page.evaluate(() => { monitorFixture.overviewIDs = Array.from({ length: 17 }, (_, i) => String(100 + i)); });
  await page.click('#monitoringBtn');
  await page.waitForFunction(() => document.querySelectorAll('#monitorList .monitor-history-bars').length === 16);
  assert.equal(await page.evaluate(() => monitorFixture.historyRequests.length), 1, 'One history request for 16 monitors');
  await page.locator('#monitorRegisterScroll').evaluate(e => { e.scrollTop = e.scrollHeight; e.dispatchEvent(new Event('scroll')); });
  await page.waitForFunction(() => document.querySelectorAll('#monitorList .monitor-history-bars').length === 17);
  assert.equal(await page.evaluate(() => monitorFixture.historyRequests.length), 2);
  assert.equal(await page.evaluate(() => new URL(monitorFixture.historyRequests[1]).searchParams.get('ids')), '116', 'More only reads the added monitor');
  await page.evaluate(() => { monitorFixture.firingID = '999'; monitorFixture.overviewIDs.unshift('999'); });
  await page.clock.runFor(30000);
  assert.equal(await page.locator('#monitorList [data-monitor]').first().getAttribute('data-monitor'), '999');
  assert.equal(await page.locator('#monitorList [data-monitor]').count(), 18, 'Polling preserves loaded page depth');
  assert.equal(await page.evaluate(() => monitorFixture.historyRequests.length), 3);
  assert.equal(await page.evaluate(() => new URL(monitorFixture.historyRequests[2]).searchParams.get('ids')), '999');
  await page.clock.runFor(30000);
  assert.equal(await page.evaluate(() => monitorFixture.historyRequests.length), 3, 'Status polls do not force history refreshes');
  await page.clock.runFor(270000);
  assert.equal(await page.evaluate(() => monitorFixture.historyRequests.length), 6, 'Expired histories refresh in bounded batches');
  await page.evaluate(() => { monitorFixture.deferRegister = true; });
  await page.click('#monitorRefresh');
  await page.waitForFunction(() => monitorFixture.pendingRegister.length === 1);
  assert.equal(await page.locator('#monitorList .monitor-history-bars').count(), 16, 'Previous bars remain while refreshing');
  assert.match(await page.locator('#monitorList').textContent(), /HISTORY UPDATING · PREVIOUS RESULT/);
  await page.evaluate(() => { monitorFixture.deferRegister = false; monitorFixture.pendingRegister.shift()(); });
  await page.waitForFunction(() => !document.getElementById('monitorList').textContent.includes('HISTORY UPDATING'));
  await page.evaluate(() => { monitorFixture.splitBatch = true; });
  await page.click('#monitorRefresh');
  await page.waitForFunction(() => !document.getElementById('monitorList').textContent.includes('HISTORY UPDATING'));
  assert.equal(await page.locator('#monitorList .monitor-history-bars').count(), 16, 'Oversized batches split without losing rows');
  await page.click('#monitorIncidentsTab');
  const inactiveRequests = await page.evaluate(() => monitorFixture.requests.length);
  await page.clock.runFor(60000);
  assert.equal(await page.evaluate(() => monitorFixture.requests.length), inactiveRequests, 'No status polling in Incidents');
  await page.click('#monitorStatusTab');
  await page.waitForFunction(() => document.getElementById('monitorList').getAttribute('aria-busy') === 'false');
  await page.locator('#monitorRegisterScroll').evaluate(e => { e.scrollTop = e.scrollHeight; e.dispatchEvent(new Event('scroll')); });
  await page.waitForFunction(() => document.querySelectorAll('#monitorList [data-monitor]').length === 18);
  // The first row drops behind the cursor between pages; use new IDs so the
  // duplicate would enter the history batch rather than hitting a warm cache.
  await page.evaluate(() => {
    monitorFixture.splitBatch = false;
    monitorFixture.overviewIDs = Array.from({ length: 17 }, (_, i) => String(200 + i));
    monitorFixture.overviewAfterFirst = [...monitorFixture.overviewIDs.slice(1), '200'];
  });
  const beforeDuplicate = await page.evaluate(() => monitorFixture.historyRequests.length);
  await page.clock.runFor(30000);
  await page.waitForFunction(() => document.querySelectorAll('#monitorList .monitor-history-bars').length === 17);
  assert.equal(await page.locator('#monitorList [data-monitor="200"]').count(), 1);
  const batchIDs = await page.evaluate(start => monitorFixture.historyRequests.slice(start).flatMap(url => new URL(url).searchParams.get('ids').split(',')), beforeDuplicate);
  assert.equal(batchIDs.length, 17);
  assert.equal(new Set(batchIDs).size, 17, 'A rank change must not invalidate a batch with duplicate IDs');
  assert.ok(batchIDs.includes('216'), 'The unrelated monitor still receives history');
  await page.locator('#monitorList [data-monitor="205"]').focus();
  await page.evaluate(() => { monitorFixture.deferOverview = true; });
  await page.clock.runFor(30000);
  assert.equal(await page.evaluate(() => document.activeElement.dataset.monitor), '205', 'Poll start retains focus');
  await page.evaluate(() => { monitorFixture.deferOverview = false; monitorFixture.pendingStatus.shift()(); });
  await page.waitForFunction(() => document.getElementById('monitorList').getAttribute('aria-busy') === 'false');
  assert.equal(await page.evaluate(() => document.activeElement.dataset.monitor), '205', 'Completed poll restores focus by stable ID');
  // A user moving focus while a poll is pending must not have it stolen back.
  await page.evaluate(() => { monitorFixture.deferOverview = true; });
  await page.clock.runFor(30000);
  await page.locator('#monitorSearch').focus();
  await page.evaluate(() => { monitorFixture.deferOverview = false; monitorFixture.pendingStatus.shift()(); });
  await page.waitForFunction(() => document.getElementById('monitorList').getAttribute('aria-busy') === 'false');
  assert.equal(await page.evaluate(() => document.activeElement.id), 'monitorSearch');
  await page.click('#monitorRefresh');
  await page.waitForFunction(() => document.getElementById('monitorList').getAttribute('aria-busy') === 'false');
  assert.equal(await page.locator('#monitorList [data-monitor="200"]').count(), 0);
  await page.fill('#monitorSearch', '#200');
  await page.clock.runFor(300);
  await page.waitForSelector('#monitorList [data-monitor="200"]');
  assert.equal(await page.locator('#monitorList [data-monitor]').count(), 1, 'Server search reaches an unloaded page');
  assert.equal(await page.evaluate(() => monitorFixture.requests.at(-1).cursor), '0', 'Search resets pagination');
  await page.clock.runFor(30000);
  assert.equal(await page.evaluate(() => monitorFixture.requests.at(-1).search), '#200', 'Polling preserves the server query');
  // A response from a superseded query must not replace the new result.
  await page.evaluate(() => { monitorFixture.deferOverview = true; });
  await page.fill('#monitorSearch', '#201');
  await page.clock.runFor(300);
  await page.waitForFunction(() => monitorFixture.pendingStatus.length === 1);
  await page.fill('#monitorSearch', '#202');
  await page.clock.runFor(300);
  await page.waitForFunction(() => monitorFixture.pendingStatus.length === 2);
  await page.evaluate(() => { monitorFixture.deferOverview = false; monitorFixture.pendingStatus.pop()(); });
  await page.waitForSelector('#monitorList [data-monitor="202"]');
  await page.evaluate(() => monitorFixture.pendingStatus.shift()());
  assert.deepEqual(await page.locator('#monitorList [data-monitor]').evaluateAll(nodes => nodes.map(n => n.dataset.monitor)), ['202']);
  // More and a two-page poll must retain both filters, not just the cursor.
  await page.evaluate(() => {
    monitorFixture.overviewIDs = ['900', ...Array.from({ length: 18 }, (_, i) => String(300 + i)), '999'];
    monitorFixture.firingID = '305';
  });
  await page.fill('#monitorSearch', 'Monitor 3');
  await page.selectOption('#monitorStateFilter', 'healthy');
  await page.clock.runFor(300);
  await page.waitForFunction(() => document.getElementById('monitorList').getAttribute('aria-busy') === 'false');
  assert.equal(await page.locator('#monitorList [data-monitor]').count(), 16);
  const filteredStart = await page.evaluate(() => monitorFixture.requests.length);
  await page.locator('#monitorRegisterScroll').evaluate(e => { e.scrollTop = e.scrollHeight; e.dispatchEvent(new Event('scroll')); });
  await page.waitForFunction(() => document.querySelectorAll('#monitorList [data-monitor]').length === 17);
  const expectedFiltered = Array.from({ length: 18 }, (_, i) => String(300 + i)).filter(id => id !== '305');
  assert.deepEqual(await page.locator('#monitorList [data-monitor]').evaluateAll(nodes => nodes.map(n => n.dataset.monitor)), expectedFiltered);
  await page.clock.runFor(30000);
  await page.waitForFunction(() => document.getElementById('monitorList').getAttribute('aria-busy') === 'false');
  assert.deepEqual(await page.locator('#monitorList [data-monitor]').evaluateAll(nodes => nodes.map(n => n.dataset.monitor)), expectedFiltered);
  assert.deepEqual(await page.evaluate(start => monitorFixture.requests.slice(start).filter(r => r.id === '0').map(({ cursor, search, state }) => ({ cursor, search, state })), filteredStart), [
    { cursor: '316', search: 'monitor 3', state: 2 },
    { cursor: '0', search: 'monitor 3', state: 2 },
    { cursor: '316', search: 'monitor 3', state: 2 },
  ]);
  // Both initial NRC reads start before either reply. Either reply order must
  // render the same record, and an early status failure must remain local.
  await page.reload();
  await page.waitForFunction(() => window.NRCMonitoring && window.NRCTickets);
  await page.evaluate(installMonitoringFixture);
  await page.evaluate(() => {
    const read = NRCAssets.sendGetAsset;
    monitorFixture.pendingAssets = [];
    NRCAssets.sendGetAsset = (...args) => { monitorFixture.pendingAssets.push(() => read(...args)); return 1; };
    monitorFixture.deferInstances = true;
    monitorFixture.sampleRows = [{ ago: 60, condition: 1, value: 0 }];
  });
  await page.click('#monitoringBtn');
  await page.click('[data-monitor="12"]');
  await page.waitForFunction(() => monitorFixture.pendingAssets.length === 1 && monitorFixture.pendingStatus.length === 1);
  await page.evaluate(() => monitorFixture.pendingStatus.shift()());
  assert.match(await page.locator('.monitor-record').textContent(), /Reading NRC/);
  await page.evaluate(() => monitorFixture.pendingAssets.shift()());
  await page.waitForSelector('.monitor-check');
  assert.match(await page.locator('#monitorHistory').textContent(), /MATCHES CURRENT EVALUATION/);
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => monitorFixture.pendingAssets.length === 1 && monitorFixture.pendingStatus.length === 1);
  await page.evaluate(() => monitorFixture.pendingAssets.shift()());
  await page.waitForSelector('.monitor-record h2');
  assert.equal(await page.locator('#monitorSelection').textContent(), '');
  await page.evaluate(() => monitorFixture.pendingStatus.shift()());
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus').textContent === '' && document.querySelector('.monitor-check'));
  assert.match(await page.locator('#monitorHistory').textContent(), /MATCHES CURRENT EVALUATION/);
  assert.equal(await page.evaluate(() => monitorFixture.requests.filter(r => r.id === '12').length), 2, 'One instance read per opening or refresh');
  await page.evaluate(() => {
    const send = ws.send;
    ws.send = buffer => {
      const view = new DataView(buffer);
      if (view.getUint16(0) !== 73) return send(buffer);
      // One remaining admission slot: if the optional read takes it first,
      // the required asset will not be available to render.
      if (!monitorFixture.pendingAssets.length) return send(buffer);
      queueMicrotask(() => {
        NRCMonitoring.handleError({ correlationId: view.getUint32(2), errorMsg: 'Instance read rejected' });
        monitorFixture.failureSent = true;
      });
    };
  });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => monitorFixture.failureSent && monitorFixture.pendingAssets.length === 1);
  await page.evaluate(() => monitorFixture.pendingAssets.shift()());
  await page.waitForFunction(() => document.getElementById('monitorInstanceStatus')?.textContent.includes('Instance read rejected'));
  assert.match(await page.locator('.monitor-record h2').textContent(), /Marketplace/);
  assert.equal(await page.locator('#monitorSelection').textContent(), '');
  // A page tagged with another config must never start a history read. Retry
  // once; if configurations keep changing leave refresh available to the user.
  await page.reload();
  await page.waitForFunction(() => window.NRCMonitoring && window.NRCTickets);
  await page.evaluate(installMonitoringFixture);
  await page.evaluate(() => { monitorFixture.pageRevision = '1'; });
  await page.click('#monitoringBtn');
  await page.click('[data-monitor="12"]');
  await page.waitForFunction(() => document.querySelector('.monitor-record')?.textContent.includes('configuration changed while loading'));
  assert.equal(await page.evaluate(() => monitorFixture.requests.filter(r => r.id === '12').length), 2);
  assert.equal(await page.evaluate(() => monitorFixture.inspectorRequests.length), 0);
  await page.evaluate(() => {
    delete monitorFixture.pageRevision;
    monitorFixture.definition.kind = 'victoriametrics';
    monitorFixture.definition.trigger = { op: '>', value: 1 };
    monitorFixture.identity = JSON.stringify({ instance: '/'.repeat(2683) });
    monitorFixture.expectFullHistory = true;
    monitorFixture.sampleRows = [{ ago: 60, condition: 1, value: 2 }];
  });
  await page.click('#monitorDetailRefresh');
  await page.waitForSelector('#monitorUptime [role="img"]');
  const full = new URL(await page.evaluate(() => monitorFixture.inspectorRequests.at(-1)));
  assert.equal(full.searchParams.get('identity'), JSON.stringify({ instance: '/'.repeat(2683) }));
  assert.ok(full.search.length - 1 <= 8192 && full.search.length - 1 + '&view=chart'.length > 8192);
  // Legacy status pages lack config_revision. Change the configuration after
  // the page was taken, before the confirming asset read; retry with the filter intact.
  await page.evaluate(() => Object.assign(monitorFixture, { legacyStatus: true, instancePages: true, deferInstances: true }));
  await page.check('#monitorRetired');
  await page.waitForFunction(() => monitorFixture.pendingStatus.length === 1);
  await page.evaluate(() => {
    monitorFixture.assetRevision = '222';
    monitorFixture.config.name = 'Changed configuration';
    monitorFixture.deferInstances = false;
    monitorFixture.pendingStatus.shift()();
  });
  await page.waitForFunction(() => document.querySelector('.monitor-record h2')?.textContent.includes('Changed configuration') && document.querySelector('#monitorInstances')?.textContent.includes('included-first'));
  assert.ok(await page.isChecked('#monitorRetired'));
  // Inspector uses one bundled read, and cached data is explicitly historical
  // while that read is held or fails. A new identity must never see the old data.
  await page.reload();
  await page.waitForFunction(() => window.NRCMonitoring && window.NRCTickets);
  await page.evaluate(installMonitoringFixture);
  await page.evaluate(() => { monitorFixture.sampleRows = [{ ago: 60, condition: 1, value: 0 }]; });
  await page.click('#monitoringBtn');
  await page.click('[data-monitor="12"]');
  await page.waitForSelector('.monitor-check');
  assert.equal(await page.evaluate(() => monitorFixture.inspectorRequests.length), 1);
  assert.match(await page.locator('#monitorHistory').textContent(), /MATCHES CURRENT EVALUATION/);
  await page.evaluate(() => { monitorFixture.deferHistoryKind = 'inspector'; monitorFixture.sampleRows = [{ ago: 60, condition: 0, value: 1 }]; });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => monitorFixture.pendingHistory.length === 1);
  assert.match(await page.locator('#monitorHistoryStatus').textContent(), /PREVIOUS RESULT/);
  assert.equal(await page.locator('.monitor-check').getAttribute('data-state'), 'failing');
  assert.doesNotMatch(await page.locator('#monitorHistory').textContent(), /MATCHES CURRENT EVALUATION/);
  await page.evaluate(() => { monitorFixture.deferHistoryKind = ''; monitorFixture.pendingHistory.shift()(); });
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus').textContent === '');
  assert.equal(await page.locator('.monitor-check').getAttribute('data-state'), 'healthy');
  assert.equal(await page.evaluate(() => monitorFixture.inspectorRequests.length), 2);
  await page.evaluate(() => { monitorFixture.fail = true; });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus').textContent.includes('503'));
  assert.equal(await page.locator('.monitor-check').getAttribute('data-state'), 'healthy', 'Failed revalidation preserves the previous result');
  await page.evaluate(() => { monitorFixture.fail = false; monitorFixture.identity = 'other-target'; monitorFixture.deferHistoryKind = 'inspector'; });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => monitorFixture.pendingHistory.length === 1);
  assert.equal(await page.locator('.monitor-check').count(), 0, 'An identity change cannot reuse another instance history');
  await page.evaluate(() => { monitorFixture.deferHistoryKind = ''; monitorFixture.pendingHistory.shift()(); });
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus').textContent === '');
  await page.evaluate(() => { monitorFixture.sectionLimit = 'runs'; });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus').textContent === '');
  assert.match(await page.locator('#monitorHistory').textContent(), /section exceeds/);
  assert.equal(await page.locator('.monitor-check').count(), 1, 'A run limit does not discard samples');
  assert.match(await page.locator('#monitorUptime').textContent(), /66.66%/);
  await page.clock.setSystemTime(await page.evaluate(() => Date.now() + 300001));
  await page.evaluate(() => { monitorFixture.deferHistoryKind = 'inspector'; });
  await page.click('#monitorDetailRefresh');
  await page.waitForFunction(() => monitorFixture.pendingHistory.length === 1);
  assert.equal(await page.locator('.monitor-check').count(), 0, 'Expired history is not reused');
  await page.evaluate(() => { monitorFixture.deferHistoryKind = ''; monitorFixture.pendingHistory.shift()(); });
  await page.waitForFunction(() => document.getElementById('monitorHistoryStatus').textContent === '');
  const openCachedMonitor = async (id = '12', held = false) => {
    const before = await page.evaluate(() => monitorFixture.inspectorRequests.length);
    await page.evaluate(id => NRCInspector.openEntity({ type: 'monitor', id: BigInt(id) }, { replaceCurrent: true }), id);
    await page.waitForFunction(({ before, held }) => monitorFixture.inspectorRequests.length > before && (held ? monitorFixture.pendingHistory.length === 1 : document.getElementById('monitorHistoryStatus')?.textContent === ''), { before, held });
  };
  const releaseCachedRead = async () => {
    await page.evaluate(() => { monitorFixture.deferHistoryKind = ''; monitorFixture.pendingHistory.shift()(); });
    await page.waitForFunction(() => document.getElementById('monitorHistoryStatus').textContent === '');
  };
  for (const scope of ['workspace', 'monitor', 'revision']) {
    await page.evaluate(() => { currentWorkspaceId = 'fixture'; monitorFixture.workspace = 'fixture'; monitorFixture.assetRevision = '100'; monitorFixture.sectionLimit = ''; });
    await openCachedMonitor();
    // Positive control: the same complete key really has a usable cache entry.
    await page.evaluate(() => { monitorFixture.deferHistoryKind = 'inspector'; });
    await openCachedMonitor('12', true);
    assert.match(await page.locator('#monitorHistoryStatus').textContent(), /PREVIOUS RESULT/);
    assert.equal(await page.locator('.monitor-check').count(), 1);
    await releaseCachedRead();
    await page.evaluate(scope => {
      monitorFixture.deferHistoryKind = 'inspector';
      if (scope === 'workspace') currentWorkspaceId = monitorFixture.workspace = 'other-workspace';
      if (scope === 'revision') monitorFixture.assetRevision = '101';
    }, scope);
    await openCachedMonitor(scope === 'monitor' ? '13' : '12', true);
    assert.equal(await page.locator('.monitor-check').count(), 0, `${scope} must isolate cached history`);
    assert.doesNotMatch(await page.locator('#monitorHistoryStatus').textContent(), /PREVIOUS RESULT/);
    await releaseCachedRead();
  }
  await page.evaluate(() => { currentWorkspaceId = monitorFixture.workspace = 'fixture'; monitorFixture.assetRevision = '100'; });
  for (let i = 0; i < 9; i++) {
    await page.evaluate(i => { monitorFixture.identity = `eviction-${i}`; }, i);
    await openCachedMonitor();
  }
  await page.evaluate(() => { monitorFixture.identity = 'eviction-0'; monitorFixture.deferHistoryKind = 'inspector'; });
  await openCachedMonitor('12', true);
  assert.equal(await page.locator('.monitor-check').count(), 0, 'The ninth key evicts the oldest cache entry');
  await releaseCachedRead();
  await page.evaluate(() => { monitorFixture.identity = 'eviction-8'; monitorFixture.deferHistoryKind = 'inspector'; });
  await openCachedMonitor('12', true);
  assert.equal(await page.locator('.monitor-check').count(), 1, 'Eviction retains the newest entry');
  assert.match(await page.locator('#monitorHistoryStatus').textContent(), /PREVIOUS RESULT/);
  await releaseCachedRead();
  // Long registers load at the scroll boundary, then window rows without losing
  // their measured height, history or position during a live status refresh.
  await page.evaluate(() => NRCInspector.close());
  await page.clock.resume();
  await page.reload();
  await page.waitForFunction(() => window.NRCMonitoring && window.NRCTickets);
  await page.evaluate(installMonitoringFixture);
  await page.evaluate(() => { monitorFixture.overviewIDs = Array.from({ length: 160 }, (_, i) => String(1000 + i)); });
  await page.click('#monitoringBtn');
  await page.click('#monitorRefresh');
  await page.waitForFunction(() => document.getElementById('monitorSummary').textContent.includes('16 / 16'));
  await page.evaluate(() => { monitorFixture.deferOverview = true; });
  const beforeScroll = await page.evaluate(() => monitorFixture.requests.length);
  await page.locator('#monitorRegisterScroll').evaluate(e => {
    e.scrollTop = e.scrollHeight;
    for (let i = 0; i < 5; i++) e.dispatchEvent(new Event('scroll'));
  });
  await page.waitForFunction(() => monitorFixture.pendingStatus.length === 1);
  assert.equal(await page.evaluate(() => monitorFixture.requests.length), beforeScroll + 1, 'Repeated scroll events do not request a page twice');
  await page.evaluate(() => { monitorFixture.deferOverview = false; monitorFixture.pendingStatus.shift()(); });
  await page.waitForFunction(() => document.getElementById('monitorSummary').textContent.includes('32 / 32'));
  for (let loaded = 48; loaded <= 160; loaded += 16) {
    await page.locator('#monitorRegisterScroll').evaluate(e => { e.scrollTop = e.scrollHeight; e.dispatchEvent(new Event('scroll')); });
    await page.waitForFunction(loaded => document.getElementById('monitorSummary').textContent.includes(`${loaded} / ${loaded}`), loaded);
  }
  await page.waitForFunction(() => document.getElementById('monitorList').getAttribute('aria-busy') === 'false');
  assert.ok(await page.locator('#monitorList [data-monitor]').count() < 40, 'Only the viewport and overscan remain mounted');
  assert.equal(await page.locator('#monitorList table').getAttribute('aria-rowcount'), '161');
  assert.ok(await page.locator('#monitorRegisterScroll').evaluate(e => e.scrollHeight > e.clientHeight * 10), 'Spacers preserve the full loaded register height');
  await page.locator('#monitorRegisterScroll').evaluate(e => { e.scrollTop = 0; });
  await page.waitForSelector('[data-monitor="1000"]');
  await page.waitForSelector('[data-history-monitor="1000"] .monitor-history-bars');
  await page.locator('#monitorList [data-monitor="1002"]').focus();
  await page.evaluate(() => NRCMonitoring.refresh(false, true));
  assert.equal(await page.evaluate(() => document.activeElement.dataset.monitor), '1002', 'Virtual status refresh preserves the focused monitor');
  const exhaustedRequests = await page.evaluate(() => monitorFixture.requests.length);
  await page.locator('#monitorRegisterScroll').evaluate(e => { e.scrollTop = e.scrollHeight; e.dispatchEvent(new Event('scroll')); });
  await page.waitForSelector('[data-monitor="1159"]');
  assert.equal(await page.evaluate(() => monitorFixture.requests.length), exhaustedRequests, 'The exhausted register does not request another page');
  const scrolledPosition = await page.locator('#monitorRegisterScroll').evaluate(e => e.scrollTop);
  await page.evaluate(() => NRCMonitoring.refresh(false, true));
  assert.equal(await page.evaluate(() => document.activeElement.dataset.monitor), '1002');
  assert.ok(Math.abs(await page.locator('#monitorRegisterScroll').evaluate(e => e.scrollTop) - scrolledPosition) < 5, 'Polling does not scroll back to an offscreen focused monitor');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('#monitorRegisterScroll').evaluate(e => { e.scrollTop = 0; });
  await page.waitForSelector('[data-monitor="1000"]');
  assert.equal(await page.locator('#monitorRegisterScroll').evaluate(e => e.scrollWidth <= e.clientWidth), true, 'Virtual cards stay within the narrow register');
  await page.locator('#monitorRegisterScroll').evaluate(e => { e.scrollTop = e.scrollHeight; });
  await page.waitForSelector('[data-monitor="1159"]');
  assert.deepEqual(errors, []);
  console.log('PASS: hourly history, weighted uptime/coverage, gaps/pauses, stale history races, narrow layout, status pagination, diagnostics, history failure, ACK/assignment, disconnect');
} finally { await browser.close(); }
