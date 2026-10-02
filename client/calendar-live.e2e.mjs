// Real-server acceptance test and review seed. Run only against the disposable
// test/customer-workspace-dev.mjs fixture. Leaves its unique workspace populated.
// NRC_CLIENT_URL=http://127.0.0.1:8091 node client/calendar-live.e2e.mjs
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_CLIENT_URL || "http://127.0.0.1:8091";
assert.ok(["127.0.0.1", "localhost"].includes(new URL(url).hostname), "Use a disposable local fixture");
const workspace = `calendar-review-${Date.now()}`;
const browser = await chromium.launch();

try {
  const page = await browser.newPage({ serviceWorkers: "block", timezoneId: "Europe/Berlin" });
  await page.clock.setFixedTime(new Date("2026-09-26T12:00:00Z"));
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`${url}/#workspace=${workspace}`);
  await page.waitForFunction(() => typeof serverReady !== "undefined" && serverReady && myNickname === "customer-preview");

  const ids = await page.evaluate(async () => {
    // These are deliberately UTC constants. In Europe/Berlin they become the
    // independently asserted local dates/times below, including the 22:xx UTC
    // rollover into the following local day and month.
    const ns = iso => BigInt(Date.parse(iso)) * 1000000n;
    const rpc = send => new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Fixture RPC timeout")), 15000);
      send({ onSuccess: result => { clearTimeout(timer); resolve(result); }, onError: error => {
        clearTimeout(timer); reject(new Error(error?.message || "Fixture RPC failed"));
      } });
    });
    const createTask = async (title, due, assignee, project, status = 1, blockedBy = 0n) => {
      const result = await rpc(options => NRCTasks.sendCreateTask(0n, title,
        "Disposable CALENDAR review data. Safe to edit.", 128, 0, "", due, [], status, 0, project, options));
      if (assignee || blockedBy) await rpc(options => NRCTasks.sendUpdateTask(0n, result.task.id,
        "", "", 255, assignee, 255, 255, "", 0n, blockedBy, [], "", options));
      return result.task.id;
    };
    const createReminder = async (title, due) => {
      const payload = buildReminderPayload({ title, deadlineAt: due, windowStartAt: 0n, urgencyDays: 3, noteAssetId: 0n });
      const result = await rpc(options => NRCAssets.sendCreateAsset(0n, AssetType.Reminder, 0, 0n, title, payload, 0, options));
      return result.asset.assetId;
    };

    const prerequisite = await createTask("Calendar fixture prerequisite", 0n, myNickname, "ALPHA");
    const midnight = await createTask("Local midnight handoff", ns("2026-09-25T22:15:00.000Z"), myNickname, "ALPHA");
    const blocked = await createTask("Blocked own release", ns("2026-09-26T08:00:00.000Z"), myNickname, "ALPHA", 1, prerequisite);
    const foreign = await createTask("Foreign assignee review", ns("2026-09-26T09:30:00.000Z"), "alex", "ALPHA");
    const movable = await createTask("Move due date live", ns("2026-09-27T07:00:00.000Z"), myNickname, "BETA");
    const monthEdge = await createTask("UTC month boundary", ns("2026-09-30T22:30:00.000Z"), "alex", "BETA");
    const undated = await createTask("Undated must stay out", 0n, myNickname, "ALPHA");
    const done = await createTask("Done must stay out", ns("2026-09-26T12:00:00.000Z"), "done-owner", "ALPHA", 3);
    const reminder = await createReminder("Calendar reminder", ns("2026-09-26T11:45:00.000Z"));
    const monthReminder = await createReminder("Boundary reminder", ns("2026-09-30T21:45:00.000Z"));
    return Object.fromEntries(Object.entries({ prerequisite, midnight, blocked, foreign, movable, monthEdge,
      undated, done, reminder, monthReminder }).map(([key, value]) => [key, String(value)]));
  });

  await page.evaluate(() => {
    TaskViewState.filters.assignee = "me";
    NRCTaskQuery.update({ force: true });
  });
  await page.waitForFunction(() => NRCTaskQuery.getAssignees().includes("done-owner"));
  assert.deepEqual(await page.locator("#filterAssignee option").allTextContents(), ["ALL", "MY TASKS", "alex", "done-owner"]);
  await page.evaluate(() => {
    const handlePage = NRCCalendar.handlePage;
    NRCCalendar.handlePage = view => {
      window.releaseCalendarPage = () => {
        NRCCalendar.handlePage = handlePage;
        delete window.releaseCalendarPage;
        handlePage(view);
      };
    };
    NRCViewManager.setActiveView("calendar");
  });
  await page.waitForFunction(() => window.releaseCalendarPage);
  assert.equal(await page.locator("#calendarBody").isVisible(), false, "no partial calendar while the range page is pending");
  assert.equal(await page.locator("#calendarControls").isVisible(), false, "filters are not offered before the complete snapshot");
  await page.evaluate(() => window.releaseCalendarPage());
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
  assert.equal((await page.evaluate(() => NRCCalendar.getState().rows.length)), 6, "only this local month's summaries loaded");

  const agendaRows = page.locator("#calendarBody .calendar-row");
  assert.deepEqual(await agendaRows.locator(".task-row-open").allTextContents(), [
    "Local midnight handoff", "Blocked own release", "Foreign assignee review", "Calendar reminder",
    "Move due date live", "Boundary reminder",
  ], "agenda is chronological and only contains this local month");
  assert.deepEqual(await agendaRows.locator("time").allTextContents(), ["00:15", "10:00", "11:30", "13:45", "09:00", "23:45"]);
  assert.equal(await page.locator(`[data-calendar-record="task:${ids.undated}"]`).count(), 0, "undated task excluded");
  assert.equal(await page.locator(`[data-calendar-record="task:${ids.done}"]`).count(), 0, "done task excluded");
  assert.equal(await page.locator(`[data-calendar-record="task:${ids.foreign}"]`).count(), 1, "other assignees included");
  assert.equal(await page.locator(`[data-calendar-record="task:${ids.blocked}"]`).locator("xpath=..").locator(".calendar-state").textContent(), "BLOCKED");

  const selectFilter = async (id, label) => {
    await page.locator(`#${id}-trigger`).click();
    await page.locator("#portal-container").getByRole("option", { name: label, exact: true }).click();
    await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
    assert.equal(await page.locator(`#${id}-trigger`).getAttribute("aria-expanded"), "false");
  };
  assert.deepEqual(await page.locator(".calendar-column-header span").allTextContents(), ["KIND", "TITLE", "TIME", "ASSIGNEE", "PROJECT", "STATE"]);
  await selectFilter("calendarPerson", "MINE");
  await selectFilter("calendarProject", "ALPHA");
  assert.deepEqual(await agendaRows.locator(".task-row-open").allTextContents(), ["Local midnight handoff", "Blocked own release"]);
  assert.equal(await page.locator('[data-calendar-record^="reminder:"]').count(), 0, "task filters exclude reminders");
  await selectFilter("calendarPerson", "ALL");
  assert.deepEqual(await agendaRows.locator(".task-row-open").allTextContents(), [
    "Local midnight handoff", "Blocked own release", "Foreign assignee review",
  ], "project and assignee filters intersect");
  await selectFilter("calendarProject", "ALL");

  await page.locator('[data-calendar-mode="month"]').click();
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
  await page.locator("#calendarNext").click();
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
  assert.equal(await page.locator("#calendarRange").textContent(), "OCTOBER 2026");
  const octoberFirst = page.locator('[data-calendar-day="2026-10-01"]');
  assert.equal(await octoberFirst.getAttribute("aria-label"), "Thu, Oct 1, 2026, 1 items");
  await page.locator("#calendarToday").click();
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
  assert.equal(await page.locator("#calendarRange").textContent(), "SEPTEMBER 2026");
  const today = page.locator('[data-calendar-day="2026-09-26"]');
  assert.equal(await today.getAttribute("aria-current"), "date");
  assert.equal(await today.getAttribute("aria-pressed"), "true");
  assert.equal(await today.getAttribute("aria-label"), "Sat, Sep 26, 2026, 4 items");

  await page.locator(`[data-calendar-record="task:${ids.foreign}"]`).click();
  await page.waitForFunction(({ id }) => document.querySelector("#inspector")?.textContent.includes(`TASK #${id}`) &&
    document.querySelector("#inspector")?.textContent.includes("Foreign assignee review"), { id: ids.foreign });

  for (const selector of [".note-link-kind", "time", ".calendar-owner", ".calendar-project", ".calendar-state"]) {
    await page.evaluate(() => NRCInspector.close());
    await page.locator(`[data-calendar-row="task:${ids.blocked}"] ${selector}`).click();
    await page.waitForFunction(() => document.querySelector("#inspector")?.textContent.includes("Blocked own release") && NRCInspector.hasEntity());
  }
  await page.evaluate(() => NRCInspector.close());
  await page.locator(`[data-calendar-row="reminder:${ids.reminder}"]`).click({ position: { x: 2, y: 2 } });
  await page.waitForFunction(id => document.querySelector("#inspector")?.textContent.includes(`REMINDER #${id}`) && NRCInspector.hasEntity(), ids.reminder);
  await page.evaluate(() => NRCInspector.close());
  await page.locator(`[data-calendar-record="task:${ids.foreign}"]`).focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => document.querySelector("#inspector")?.textContent.includes("Foreign assignee review") && NRCInspector.hasEntity());

  await page.evaluate(async id => {
    await new Promise((resolve, reject) => NRCTasks.sendUpdateTask(0n, BigInt(id), "", "", 1, "", 255, 255, "",
      BigInt(Date.parse("2026-09-26T14:20:00.000Z")) * 1000000n, 0n, [], "", { onSuccess: resolve, onError: reject }));
  }, ids.movable);
  await page.waitForFunction(id => NRCCalendar.getState().rows.find(row => row.key === `task:${id}`)?.time === "16:20", ids.movable).catch(async error => {
    console.error(await page.evaluate(() => ({ status: NRCCalendar.getState().status, view: NRCViewManager.getActiveView(),
      rows: NRCCalendar.getState().rows.map(row => ({ key: row.key, time: row.time })) })), errors);
    throw error;
  });
  assert.equal(await page.locator(`[data-calendar-record="task:${ids.movable}"]`).locator("xpath=..").locator("time").textContent(), "16:20",
    "acknowledged due edit updates calendar without reload");

  await page.evaluate(async id => {
    await new Promise((resolve, reject) => sendMoveTask(0n, BigInt(id), 3, { onSuccess: resolve, onError: reject }));
  }, ids.blocked);
  await page.waitForFunction(id => !NRCCalendar.getState().rows.some(row => row.key === `task:${id}`), ids.blocked);

  await page.evaluate(async id => {
    const title = "Calendar reminder edited";
    const deadlineAt = BigInt(Date.parse("2026-09-26T15:05:00.000Z")) * 1000000n;
    const payload = buildReminderPayload({ title, deadlineAt, windowStartAt: 0n, urgencyDays: 3, noteAssetId: 0n });
    await new Promise((resolve, reject) => NRCAssets.sendUpdateAsset(0n, BigInt(id), title, payload,
      AssetType.Reminder, 0, { onSuccess: resolve, onError: reject }));
  }, ids.reminder);
  await page.waitForFunction(id => NRCCalendar.getState().rows.find(row => row.key === `reminder:${id}`)?.title === "Calendar reminder edited", ids.reminder);
  assert.equal(await page.locator(`[data-calendar-record="reminder:${ids.reminder}"]`).locator("xpath=..").locator("time").textContent(), "17:05");

  // A second connection deletes records while the observing Calendar owns only
  // summaries. Test each deletion separately: a task refresh must not mask a
  // missing reminder invalidation (or vice versa).
  const peer = await browser.newPage({ serviceWorkers: "block" });
  await peer.goto(`${url}/#workspace=${workspace}`);
  await peer.waitForFunction(() => typeof serverReady !== "undefined" && serverReady);
  const disposable = await peer.evaluate(async () => {
    const due = BigInt(Date.parse("2026-09-26T10:00:00Z")) * 1000000n;
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const task = await rpc(options => NRCTasks.sendCreateTask(0n, "Remote deletion task", "", 128, 0, "", due, [], 1, 0, "", options));
    const payload = buildReminderPayload({ title: "Remote deletion reminder", deadlineAt: due, windowStartAt: 0n, urgencyDays: 3, noteAssetId: 0n });
    const reminder = await rpc(options => NRCAssets.sendCreateAsset(0n, AssetType.Reminder, 0, 0n, "Remote deletion reminder", payload, 0, options));
    return { task: String(task.task.id), reminder: String(reminder.asset.assetId) };
  });
  await page.waitForFunction(ids => ["task", "reminder"].every(kind =>
    NRCCalendar.getState().rows.some(row => row.key === `${kind}:${ids[kind]}`)), disposable);
  await page.evaluate(() => { roomAssets.delete(0n); roomTasks.delete(0n); });
  await peer.evaluate(id => NRCAssets.sendDeleteAsset(0n, BigInt(id)), disposable.reminder);
  await page.waitForFunction(id => !NRCCalendar.getState().rows.some(row => row.key === `reminder:${id}`), disposable.reminder);
  assert.equal(await page.locator(`[data-calendar-row="reminder:${disposable.reminder}"]`).count(), 0);
  await page.evaluate(() => { roomTasks.delete(0n); });
  await peer.evaluate(id => sendDeleteTask(0n, BigInt(id)), disposable.task);
  await page.waitForFunction(id => !NRCCalendar.getState().rows.some(row => row.key === `task:${id}`), disposable.task);
  assert.equal(await page.locator(`[data-calendar-row="task:${disposable.task}"]`).count(), 0);
  await peer.close();

  await page.reload();
  await page.waitForFunction(() => typeof serverReady !== "undefined" && serverReady);
  await page.evaluate(() => NRCViewManager.setActiveView("calendar"));
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
  assert.equal(await page.locator(`[data-calendar-record="task:${ids.movable}"]`).locator("xpath=..").locator("time").textContent(), "16:20");
  assert.equal(await page.locator(`[data-calendar-record="task:${ids.blocked}"]`).count(), 0);
  assert.equal(await page.locator(`[data-calendar-record="reminder:${ids.reminder}"]`).count(), 1, "calendar state restored from server");

  await page.setViewportSize({ width: 390, height: 844 });
  for (const theme of ["white", "matte-black"]) {
    await page.evaluate(theme => setTheme(theme), theme);
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const layout = await page.evaluate(() => {
      const bar = document.querySelector("#calendarPanel .header-register-control-row").getBoundingClientRect();
      return { overflow: document.documentElement.scrollWidth > innerWidth,
        navigationFits: [...document.querySelectorAll(".calendar-navigation button")].every(button => {
          const rect = button.getBoundingClientRect();
          return rect.top >= bar.top && rect.bottom <= bar.bottom && rect.height >= 44;
        }) };
    });
    assert.deepEqual(layout, { overflow: false, navigationFits: true }, `${theme}: narrow navigation stays inside its scroll rail; ${JSON.stringify(await page.locator(".calendar-navigation").boundingBox())}`);
  }
  await page.locator('[data-calendar-mode="month"]').focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => NRCCalendar.getState().status === "ready");
  assert.equal(await page.locator('[data-calendar-mode="month"]').getAttribute("aria-pressed"), "true");
  await page.locator('[data-calendar-day="2026-09-26"]').focus();
  await page.keyboard.press("Enter");
  assert.equal(await page.locator('[data-calendar-day="2026-09-26"]').getAttribute("aria-pressed"), "true");
  assert.deepEqual(errors, []);

  await fs.writeFile("/tmp/nrc-calendar-fixture.json", JSON.stringify({ workspace, ...ids }));
  console.log(`PASS: real calendar agenda/month, local dates, filters, inspector, live edits, uncached remote task/reminder deletion, Done removal, reminder edit, reload. Workspace: ${workspace}`);
} finally {
  await browser.close();
}
