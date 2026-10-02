// NRC_CLIENT_URL=http://localhost:8002 node client/mobile-shell.e2e.mjs
// Real client, isolated sample state and mocked transport; no persistent server writes.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium, devices } from "playwright";

const browser = await chromium.launch();
const errors = [];
try {
  const context = await browser.newContext({ ...devices["iPhone 13"], viewport: { width: 390, height: 844 }, serviceWorkers: "block" });
  const page = await context.newPage();
  page.on("pageerror", error => { errors.push(error.message); console.error(error.message); });
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    const file = new URL(`.${pathname === "/" ? "/index.html" : pathname}`, import.meta.url);
    try { await route.fulfill({ path: fileURLToPath(file) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  // Paint the shell before startup scripts arrive, as on a slow mobile connection.
  let releaseScripts;
  const scriptsReady = new Promise(resolve => { releaseScripts = resolve; });
  await page.route(/\.js(?:\?|$)/, async route => { await scriptsReady; await route.fallback(); });
  const navigation = page.goto(`${process.env.NRC_CLIENT_URL || "http://nrc.test"}#workspace=mobile-test`);
  let initialLog;
  try {
    await page.locator("#logOutput").waitFor({ state: "visible" });
    await page.evaluate(() => document.fonts.ready);
    assert.ok(await page.locator("#chatTools").isHidden(), "mobile tools are collapsed before JavaScript initializes");
    initialLog = await page.locator("#logOutput").boundingBox();
  } finally { releaseScripts(); await navigation; }
  await page.waitForFunction(() => currentWorkspaceId === "mobile-test" && window.NRCChat && ws?.readyState === WebSocket.OPEN);
  assert.equal((await page.locator("#logOutput").boundingBox()).y, initialLog.y, "startup must not shift the chat log");
  // This suite exercises the flat task register. The task view opens on the
  // slice grouping, so select the flat grouping once; it is persisted state.
  await page.evaluate(() => setTaskGrouping("flat"));
  await page.locator("#messageInput").fill("Offline initial draft");
  await page.evaluate(() => loadRoomHistory(currentRoomId));
  assert.equal(await page.locator("#messageInput").inputValue(), "Offline initial draft", "initial non-default workspace owns its draft before ServerReady");
  assert.equal(await page.evaluate(() => matchMedia("(pointer: coarse)").matches), true);
  await page.evaluate(() => {
    currentWorkspaceId = "mobile-test";
    currentRoomId = 2n;
    myNickname = "ben";
    nicknameReceived = true;
    subscribedRooms.add(2n); subscribedRooms.add(8n);
    NRCChat.syncComposer();
    loadRoomHistory(2n);
    roomHistory.clear();
    for (let i = 0; i < 12; i++) logMessage("Message", `Release check ${i}: background the browser and verify reconnect.`, 2n, { author: "anna" });
    logMessage("Message", "Please check [task:42] before the release.", 2n, { author: "mika" });
    const tasks = new Map();
    for (let i = 42; i < 542; i++) tasks.set(BigInt(i), { id: BigInt(i), convId: 0n, title: i === 42 ? "Verify mobile reconnect" : `Release checklist ${i}`, description: "Verify the connection after backgrounding the browser.", status: 1, priority: i === 42 ? 255 : 128, color: 0, assignee: "ben", createdBy: "anna", createdAt: 0n, updatedAt: 0n, dueAt: 0n, blockedBy: 0n, attachments: [], orderIndex: i });
    roomTasks.set(0n, tasks);
    taskListDirty = true;
    updateRoomUI();
    document.getElementById("connectionStatus").textContent = "ONLINE";
  });
  const capture = async name => {
    if (!process.env.NRC_MOBILE_SCREENSHOTS) return;
    await fs.mkdir(process.env.NRC_MOBILE_SCREENSHOTS, { recursive: true });
    await page.screenshot({ path: `${process.env.NRC_MOBILE_SCREENSHOTS}/${name}.png` });
  };
  const draft = page.locator("#messageInput");
  await draft.fill("Release draft");
  for (const value of ["Release draft", "Release draft\nSecond line\nThird line"]) {
    await draft.fill(value);
    const composer = await page.locator(".input-controls").boundingBox();
    const send = await page.locator("#chatSend").boundingBox();
    const attach = await page.locator("#chatAttach").boundingBox();
    assert.equal(send.y, attach.y, "Send and File share the footer row");
    assert.equal(send.y + send.height, composer.y + composer.height, "Send stays at the composer bottom");
    assert.equal(send.height, 44, "Send retains its touch target without growing with the draft");
  }
  await draft.fill("Release draft");
  await draft.press("Enter");
  assert.equal(await draft.inputValue(), "Release draft\n", "touch Enter inserts a newline instead of sending");
  await page.locator("#mobileRoomSwitch").tap();
  assert.equal(await page.locator("#primaryNavigation").getAttribute("role"), "dialog");
  assert.equal(await page.locator(".main-area").evaluate(el => el.inert), true);
  await capture("rooms");
  await page.locator('[data-room="8"]').tap();
  await page.waitForFunction(() => !document.body.classList.contains("mobile-navigation-open"));
  assert.equal(await draft.inputValue(), "");
  await draft.fill("Separate room draft");
  await page.locator("#mobileRoomSwitch").tap();
  await page.locator('[data-room="2"]').tap();
  assert.equal(await draft.inputValue(), "Release draft\n");
  await page.locator('#chatDialog .chat-reply-action').last().tap();
  const quotedDraft = await draft.inputValue();
  await page.locator("#mobileRoomSwitch").tap();
  await page.locator('[data-room="8"]').tap();
  assert.ok(await page.locator("#chatReply").isHidden());
  assert.equal(await draft.inputValue(), "Separate room draft");
  await page.locator("#mobileRoomSwitch").tap();
  await page.locator('[data-room="2"]').tap();
  assert.equal(await draft.inputValue(), quotedDraft);
  assert.ok(await page.locator("#chatReply").isVisible());
  await page.locator("#chatCancelReply").tap();

  await page.evaluate(() => { logOutput.scrollTop = 70; });
  const scroll = await page.locator("#logOutput").evaluate(el => el.scrollTop);
  await page.evaluate(() => NRCInspector.openEntity({ type: "task", roomId: 2n, id: 42n }));
  await page.waitForFunction(() => document.body.classList.contains("inspector-open"));
  const inspector = await page.locator("#inspector").boundingBox();
  assert.equal(inspector.width, 390);
  assert.equal(inspector.y, 0);
  await page.locator("#mobileInspectorBack").tap();
  assert.equal(await draft.inputValue(), "Release draft\n");
  assert.equal(await page.locator("#logOutput").evaluate(el => el.scrollTop), scroll);
  await page.locator('[data-mobile-view="kanban"]').tap();
  assert.ok(await page.locator("#kanbanPanel").isVisible());
  await page.locator('[data-mobile-view="kanban"]').tap();
  assert.ok(await page.locator("#kanbanPanel").isVisible(), "active task tab does not toggle back to chat");
  const rows = page.locator("#taskListBody tr[data-task-id]");
  assert.ok(await rows.count() < 100, "mobile tasks remain virtualized");
  assert.equal(await rows.first().evaluate(el => getComputedStyle(el).display), "grid");
  await page.evaluate(() => document.getElementById("taskListBody").virtualList.ensure(499));
  await page.waitForSelector('#taskListBody [data-virtual-index="499"]');
  await page.evaluate(() => document.getElementById("taskListBody").virtualList.ensure(0));
  await page.waitForSelector('#taskListBody [data-task-id="42"]');
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await capture(`tasks-${theme}`);
    await page.locator('#taskListBody [data-task-id="42"]').tap();
    await page.waitForFunction(() => document.body.classList.contains("inspector-open"));
    await capture(`detail-before-edit-${theme}`);
    await page.locator("#taskDetailToggleFocus").tap();
    await page.locator('.agenda-content nrc-inline-field[data-control$="-status"] button').tap();
    assert.equal(await page.locator(".inline-field-editor select").inputValue(), "1");
    assert.ok(await page.locator(".inline-field-editor").evaluate(el => el.getBoundingClientRect().right <= innerWidth));
    await page.keyboard.press("Escape");
    await page.locator("#taskDetailDesc").fill(`Unsaved mobile description ${theme}`);
    assert.ok(await page.locator("#taskDetailDesc").evaluate(el => el.getBoundingClientRect().right <= innerWidth));
    await capture(`detail-${theme}`);
    const reference = page.locator('.agenda-content nrc-inline-field[data-control$="-externalRef"]');
    await reference.scrollIntoViewIfNeeded();
    const referenceBox = await reference.boundingBox();
    const resourcesBox = await page.locator(".document-resources").boundingBox();
    assert.ok(referenceBox.y + referenceBox.height <= resourcesBox.y, "scrolled fields are not covered by the resource dock");
    await page.locator("#mobileInspectorBack").tap();
    await page.locator(".nrc-dialog-actions").getByRole("button", { name: "Cancel", exact: true }).tap();
    assert.equal(await page.locator("#taskDetailDesc").inputValue(), `Unsaved mobile description ${theme}`, "cancelled discard retains task edits");
    // Content saves wait for their own acknowledgement and never resend metadata.
    await page.evaluate(() => {
      window.mobileSaveAcks = [];
      sendUpdateTask = (...args) => { mobileSaveAcks.push(() => args.at(-1).onSuccess({ task: { ...currentDetailTask, description: args[3] } })); return 1; };
    });
    await page.locator("#taskDetailSave").tap();
    assert.equal(await page.locator("#inspectorHeader [data-save-state]").getAttribute("data-save-state"), "SAVING");
    assert.equal(await page.evaluate(() => mobileSaveAcks.length), 1);
    await page.evaluate(() => mobileSaveAcks[0]());
    assert.equal(await page.locator("#inspectorHeader [data-save-state]").getAttribute("data-save-state"), "SAVED");
    await page.locator("#mobileInspectorBack").tap();
    await page.locator('[data-mobile-view="chat"]').tap();
    await capture(`chat-${theme}`);
    await page.locator("#mobileChatTools").tap();
    assert.ok(await page.locator("#chatSearch").isVisible());
    await capture(`chat-tools-${theme}`);
    await page.locator("#mobileChatTools").tap();
    await page.locator('[data-mobile-view="kanban"]').tap();
  }
  assert.ok(await page.locator("#taskSearch").isVisible(), "collapsed task filters retain query");
  assert.equal((await page.locator("#taskSearch").boundingBox()).height, 32);
  await page.locator("#taskFilterBar [data-mobile-filters]").tap();
  assert.equal((await page.locator("#taskSearch").boundingBox()).height, 32, "expanded task query remains compact");
  assert.equal(await page.locator("#taskSearch").evaluate(el => getComputedStyle(el).fontSize), "16px");
  assert.equal((await page.locator("#mobileTaskSort").boundingBox()).height, 44);
  await page.locator("#mobileTaskSort").selectOption("title");
  assert.equal(await page.evaluate(() => TaskViewState.sortColumn), "title");
  await page.locator("#mobileTaskSortDirection").tap();
  assert.equal(await page.evaluate(() => TaskViewState.sortDirection), "desc");
  await capture("task-filters");
  await page.locator("#taskFilterBar [data-mobile-filters]").tap();
  await page.locator('[data-mobile-view="notes"]').tap();
  assert.ok(await page.locator("#notesSearch").isVisible(), "collapsed note filters retain query");
  assert.equal((await page.locator("#notesSearch").boundingBox()).height, 32);
  await page.locator("#notesPanel [data-mobile-filters]").tap();
  assert.ok(await page.locator("#notesSearch").isVisible());
  assert.equal((await page.locator("#notesSearch").boundingBox()).height, 32, "expanded notes use the same query contract");
  await capture("note-filters");
  await page.locator("#mobileMore").tap();
  await page.locator("#mobileCommands").tap();
  assert.ok(await page.locator("#paletteInput").isVisible());
  for (const viewport of [{ width: 390, height: 844 }, { width: 320, height: 360 }]) {
    await page.setViewportSize(viewport);
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      for (const argument of [false, true]) {
        await page.locator("#paletteInput").fill("join");
        await page.locator("#paletteInput").fill("");
        if (argument) await page.locator(".palette-option").filter({ has: page.getByText("Join room", { exact: true }) }).tap();
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        const bounds = await page.locator(".palette-dialog").evaluate(el => {
          const box = el.getBoundingClientRect();
          const title = getComputedStyle(el, "::before");
          const overlay = el.parentElement.getBoundingClientRect();
          return {
            titleTop: box.top + parseFloat(getComputedStyle(el).borderTopWidth) + parseFloat(title.top) - overlay.top,
            bottom: box.bottom - overlay.top,
            viewportHeight: overlay.height,
          };
        });
        assert.ok(bounds.titleTop >= 8, `${viewport.width}/${theme}/${argument}: title retains an 8px viewport inset`);
        assert.ok(bounds.bottom <= bounds.viewportHeight - 8, "palette fits the reduced viewport without losing bottom padding");
        assert.equal(await page.locator("#paletteArgField").isVisible(), argument);
        await capture(`commands-${viewport.width}-${theme}${argument ? "-argument" : ""}`);
      }
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator("#mobileCommandsClose").tap();
  await page.locator("#mobileMore").tap();
  assert.ok(await page.locator("#sullivanBtn").isVisible());
  assert.equal(await page.locator("#graphBtn").count(), 0, "removed Graph view is absent from mobile overflow");
  await page.locator("#systemLogBtn").tap();
  await page.waitForFunction(() => NRCViewManager.getActiveView() === "systemLog");
  assert.equal(await page.locator("#mobileMore").getAttribute("aria-current"), "page");
  await page.locator('[data-mobile-view="chat"]').tap();
  // Opening a covering surface must not acknowledge the chat underneath it.
  for (const overlay of ["navigation", "inspector"]) {
    await page.evaluate(() => { loadRoomHistory(2n); logOutput.scrollTop = logOutput.scrollHeight; });
    if (overlay === "navigation") await page.locator("#mobileRoomSwitch").tap();
    else await page.evaluate(() => NRCInspector.openEntity({ type: "task", roomId: 2n, id: 42n }));
    await page.evaluate(() => {
      logMessage("Message", "Arrived behind mobile overlay", 2n, { author: "anna" });
      NRCChat.markRead();
    });
    assert.equal(await page.evaluate(() => isConversationExposed(2n)), false);
    assert.equal(await page.evaluate(() => getVisibleConversationId()), null);
    assert.match(await page.locator("#chatNewMessages").textContent(), /1 NEW/);
    if (overlay === "navigation") await page.locator("#mobileNavigationClose").tap();
    else await page.locator("#mobileInspectorBack").tap();
    await page.evaluate(() => { logOutput.scrollTop = logOutput.scrollHeight; NRCChat.markRead(); });
    assert.ok(await page.locator("#chatNewMessages").isHidden());
  }
  // Use the real Sullivan context picker and history path, with only its backend mocked.
  await page.route("**/ask/ready", route => route.fulfill({ json: { ai_username: "sullivan-test" } }));
  await page.evaluate(() => {
    const aiDM = DM_CONV_FLAG | 999n;
    activeDMs.set(aiDM, { username: "sullivan-test", online: true });
    subscribedRooms.add(aiDM); roomHistory.set(aiDM, []);
  });
  await draft.fill("Chat-only draft");
  await page.evaluate(() => NRCAI.openSullivanWithContext(2n, { focused: false }));
  assert.equal(await draft.inputValue(), "");
  await draft.fill("Workspace AI draft");
  assert.equal(await page.locator("#askContextChip").inputValue(), "0");
  assert.equal(await page.locator("#askContextChip").isDisabled(), true);
  await page.locator('[data-mobile-view="chat"]').tap();
  assert.equal(await draft.inputValue(), "Chat-only draft");
  await page.evaluate(() => NRCAI.openSullivanWithContext(8n, { focused: false }));
  assert.equal(await draft.inputValue(), "Workspace AI draft", "chat room does not partition AI workspace drafts");
  await page.locator('[data-mobile-view="kanban"]').tap();
  const taskRow = page.locator('#taskListBody tr[data-task-id="42"]');
  await page.evaluate(() => document.getElementById("taskListBody").virtualList.ensure(0));
  assert.equal(await taskRow.getAttribute("role"), null, "task rows retain table semantics");
  await taskRow.locator(".task-row-open").press("Enter");
  await page.waitForFunction(() => document.body.classList.contains("inspector-open"));
  await page.locator("#mobileInspectorBack").tap();
  await page.locator('[data-mobile-view="chat"]').tap();
  for (const width of [360, 390, 768]) {
    await page.setViewportSize({ width, height: 500 });
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    const send = await page.locator("#chatSend").boundingBox();
    const nav = await page.locator(".mobile-bottom").boundingBox();
    assert.ok(send.y + send.height <= nav.y + 1, "composer above tabs in keyboard-sized viewport");
    assert.ok(nav.y + nav.height <= 501, JSON.stringify({ width, nav }));
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  assert.ok(await page.locator(".mobile-bottom").isHidden());
  assert.ok(await page.locator("#primaryNavigation").isVisible());
  assert.equal(await page.locator("#primaryNavigation").evaluate(el => el.inert), false);
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    assert.ok(await page.locator("#chatTools").isVisible(), "desktop tools remain visible");
    await capture(`desktop-${theme}`);
  }
  assert.deepEqual(errors, []);
  console.log("PASS mobile: room/quote drafts, task save acknowledgements, inspector return, virtualized rows, More navigation, themes, viewport and desktop.");
} finally { await browser.close(); }
