// Client navigation and unread delivery fixtures; no shared server or data.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const browser = await chromium.launch();
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.goto(process.env.NRC_CLIENT_URL || "http://127.0.0.1:8000");
  await page.waitForFunction(() => window.NRCChat && window.NRCViewManager && ws?.readyState === WebSocket.OPEN);
  await page.evaluate(() => {
    myNickname = "reviewer"; nicknameReceived = true;
    currentRoomId = 2n;
    subscribedRooms.clear(); subscribedRooms.add(2n); subscribedRooms.add(3n);
    roomHistory.clear(); roomActivity.clear();
    retainedRoomStates.set(2n, "disabled"); retainedRoomStates.set(3n, "disabled");
    NRCViewManager.setActiveView("notes");
    updateRoomUI();
    let seq = 0n;
    window.receiveChatFixture = (roomId, text) => {
      const author = new TextEncoder().encode("anna"), content = new TextEncoder().encode(text);
      const bytes = new Uint8Array(31 + author.length + content.length), view = new DataView(bytes.buffer);
      view.setUint16(0, Opcode.S_NewMessage); view.setBigUint64(2, roomId); view.setBigUint64(10, ++seq);
      view.setUint16(18, author.length); bytes.set(author, 20);
      let offset = 20 + author.length;
      view.setBigInt64(offset, BigInt(Date.now()) * 1000000n); offset += 8;
      view.setUint8(offset++, 0); view.setUint16(offset, content.length); offset += 2; bytes.set(content, offset);
      parseNewMessage(view);
    };
    for (let i = 0; i < 2; i++) receiveChatFixture(2n, `Engineering update ${i}`);
    for (let i = 0; i < 5; i++) receiveChatFixture(3n, `Operations update ${i}`);
  });
  const room = id => page.locator(`#roomList [data-room="${id}"]`);
  const badge = id => room(id).locator(".sidebar-unread-count");
  assert.equal(await page.getByRole("navigation", { name: "Chats", exact: true }).count(), 1);
  assert.equal(await page.getByRole("navigation", { name: "Workspace views", exact: true }).getByRole("button", { name: "CHAT", exact: true }).count(), 0);
  assert.equal(await page.locator("#roomList .active").count(), 0, "data views do not select a chat");
  assert.equal(await badge(2).textContent(), "02");
  assert.equal(await badge(3).textContent(), "05");

  await room(3).click();
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat");
  assert.equal(await room(3).getAttribute("aria-current"), "page");
  assert.equal(await badge(3).isHidden(), true);
  assert.equal(await badge(2).textContent(), "02", "opening another chat must not clear the previous selection's unread");
  assert.match(await page.locator("#logOutput").textContent(), /Operations update 4/);
  await page.click("#notesBtn");
  await page.evaluate(() => receiveChatFixture(3n, "Another operations update"));
  assert.equal(await badge(3).textContent(), "01");
  await room(3).click();
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat", "same selected room also opens chat");
  assert.equal(await badge(3).isHidden(), true);
  await room(2).focus();
  await page.keyboard.press("Enter");
  assert.equal(await room(2).getAttribute("aria-current"), "page");
  assert.equal(await badge(2).isHidden(), true);

  await page.evaluate(async () => {
    await showSystemLog();
    for (let i = 0; i < 2; i++) receiveChatFixture(2n, `Engineering while in System Log ${i}`);
    for (let i = 0; i < 5; i++) receiveChatFixture(3n, `Operations while in System Log ${i}`);
  });
  assert.equal(await badge(2).textContent(), "02");
  assert.equal(await badge(3).textContent(), "05");
  await room(3).click();
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat");
  assert.equal(await badge(2).textContent(), "02", "leaving System Log must not mark the previous chat read");
  assert.equal(await badge(3).isHidden(), true);
  await room(2).click();

  await page.evaluate(() => {
    receiveChatFixture(2n, "Release checks completed.");
    for (let i = 0; i < 3; i++) receiveChatFixture(3n, `Deployment update ${i}`);
  });
  if (process.env.NRC_CHAT_NAV_SCREENSHOTS) {
    await fs.mkdir(process.env.NRC_CHAT_NAV_SCREENSHOTS, { recursive: true });
    await page.mouse.move(1100, 500);
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => setTheme(theme), theme);
      await page.screenshot({ path: `${process.env.NRC_CHAT_NAV_SCREENSHOTS}/chats-${theme}-desktop.png` });
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.click("#mobileRoomSwitch");
  assert.equal(await page.locator("#mobileNavigationTitle").textContent(), "CHATS & DMS");
  assert.equal(await badge(3).textContent(), "03");
  if (process.env.NRC_CHAT_NAV_SCREENSHOTS) {
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => setTheme(theme), theme);
      await page.screenshot({ path: `${process.env.NRC_CHAT_NAV_SCREENSHOTS}/chats-${theme}-narrow.png` });
    }
  }
  await room(3).click();
  await page.waitForFunction(() => !document.body.classList.contains("mobile-navigation-open"));
  assert.equal(await page.locator("#mobileRoomName").textContent(), "OPERATIONS");
  await page.locator('[data-mobile-view="notes"]').click();
  await page.locator('[data-mobile-view="chat"]').click();
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat");
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.evaluate(() => {
    const dm = DM_CONV_FLAG | 42n;
    activeDMs.set(dm, { username: "anna", online: true });
    subscribedRooms.add(dm);
    NRCViewManager.setActiveView("notes");
    updateDMListUI();
  });
  await page.locator("#dmList [data-dm-id]").click();
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat", "DM entries directly open chat too");
  assert.equal(await page.evaluate(() => currentRoomId === (DM_CONV_FLAG | 42n)), true);

  // Navigation must remain independent of both preparation and execution.
  const deferred = () => {
    let resolve;
    const promise = new Promise(done => { resolve = done; });
    return { promise, resolve };
  };
  let readyGate = null, askGate = null, applyGate = null;
  let readyArrived = deferred(), askArrived = deferred(), applyArrived = deferred();
  const askRequests = [], applyRequests = [];
  let askStatus = 200;
  await page.route("**/ask/ready", async route => {
    readyArrived.resolve();
    if (readyGate) await readyGate.promise;
    await route.fulfill({ json: { ai_username: "sullivan-navigation" } });
  });
  await page.route("**/ask", async route => {
    askRequests.push(route.request().postDataJSON());
    askArrived.resolve();
    if (askGate) await askGate.promise;
    await route.fulfill({ status: askStatus, json: {
      answer: "Workspace review completed.", session_id: "navigation-session", mode: "plan", plan_id: "navigation-plan",
      proposed_actions: [{ id: "1", type: "create_task", title: "Review workspace", status: "pending" }],
    } });
  });
  await page.route("**/ask/apply", async route => {
    applyRequests.push(route.request().postDataJSON());
    applyArrived.resolve();
    if (applyGate) await applyGate.promise;
    await route.fulfill({ json: { applied: [{ action_id: "1" }], failed: [] } });
  });
  await page.evaluate(async () => {
    const dm = DM_CONV_FLAG | 999n;
    activeDMs.set(dm, { username: "sullivan-navigation", online: true });
    subscribedRooms.add(dm); roomHistory.set(dm, []);
    await NRCAI.openSullivanWithContext(0n, { focused: false });
  });
  readyGate = deferred(); askGate = deferred(); readyArrived = deferred();
  await page.evaluate(() => { window.navigationAsk = NRCAI.handleAsk("Review the workspace"); });
  await readyArrived.promise;
  await page.locator("#notesBtn").click();
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "notes");
  await page.locator("#systemLogBtn").click();
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "systemLog");
  await room(3).click();
  assert.equal(await page.locator("#messageInput").isEnabled(), true);
  await page.locator("#messageInput").fill("Independent chat draft");
  assert.equal(await page.locator("#sullivanViewStatus").textContent(), "RUNNING");
  readyGate.resolve(); readyGate = null;
  await askArrived.promise;
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat", "late preparation never steals navigation");
  assert.equal(await page.locator("#messageInput").inputValue(), "Independent chat draft");
  assert.equal(askRequests[0].context_conv_id, "0");
  assert.equal(askRequests[0].display_conv_id, String((1n << 63n) | 999n));
  await page.locator("#sullivanBtn").click();
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "sullivan");
  const transcript = await page.locator("#logOutput").boundingBox();
  const run = await page.locator("#logOutput .ai-workbench-run").first().boundingBox();
  assert.ok(run.x - transcript.x < 32 && run.width <= 760, "Sullivan keeps a bounded reading width at the chat's left edge");
  assert.ok(await page.locator("#sullivanStop").isVisible());
  assert.ok(await page.locator("#askResetChip").isDisabled());
  assert.ok(await page.locator("#askClearViewChip").isDisabled());
  await page.locator("#notesBtn").click();
  askGate.resolve(); askGate = null;
  await page.evaluate(() => window.navigationAsk);
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "notes", "background answer never steals navigation");
  assert.ok(await page.locator("#sullivanViewStatus").isHidden());
  await room(3).click();
  assert.equal(await page.locator("#messageInput").inputValue(), "Independent chat draft");
  assert.doesNotMatch(await page.locator("#logOutput").innerText(), /Workspace review completed|PINNED TO/);
  await page.locator("#sullivanBtn").click();
  await page.getByRole("button", { name: "APPLY ALL", exact: true }).waitFor();
  assert.match(await page.locator("#logOutput").innerText(), /Workspace review completed/);

  applyGate = deferred();
  await page.getByRole("button", { name: "APPLY ALL", exact: true }).click();
  await applyArrived.promise;
  await room(2).click();
  assert.equal(await page.locator("#messageInput").isEnabled(), true);
  assert.equal(await page.locator("#sullivanViewStatus").textContent(), "APPLYING");
  await page.locator("#sullivanBtn").click();
  assert.ok(await page.getByRole("button", { name: "APPLY ALL", exact: true }).isDisabled());
  assert.ok(await page.locator("#askResetChip").isDisabled());
  assert.ok(await page.locator("#askClearViewChip").isDisabled());
  await room(2).click();
  applyGate.resolve(); applyGate = null;
  await page.waitForFunction(() => !NRCAI.isWorkbenchBusy());
  assert.equal(applyRequests.length, 1, "returning to a running apply never repeats mutations");
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat");
  await page.locator("#sullivanBtn").click();
  await page.locator('.ai-action-row input[data-applied="true"]').waitFor({ state: "attached" });
  assert.equal(await page.locator('.ai-action-row input[data-applied="true"]').count(), 1);
  assert.ok(await page.locator("#askResetChip").isEnabled());

  // Failures stay with Sullivan; Stop remains available after navigating back.
  askStatus = 503; askGate = deferred(); askArrived = deferred();
  await page.evaluate(() => { window.navigationAsk = NRCAI.handleAsk("Fail in background"); });
  await askArrived.promise;
  await room(3).click();
  askGate.resolve(); askGate = null;
  await page.evaluate(() => window.navigationAsk);
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat");
  assert.doesNotMatch(await page.locator("#logOutput").innerText(), /AI RUN FAILED|PINNED TO/);
  await page.locator("#sullivanBtn").click();
  await page.waitForFunction(() => logOutput.textContent.includes("AI RUN FAILED: 503"));
  await page.locator("#logOutput .ai-run-header").last().click();
  assert.match(await page.locator("#logOutput").innerText(), /AI RUN FAILED: 503/);
  askStatus = 200; askGate = deferred(); askArrived = deferred();
  await page.evaluate(() => { window.navigationAsk = NRCAI.handleAsk("Cancel after returning"); });
  await askArrived.promise;
  await page.locator("#notesBtn").click();
  await page.locator("#sullivanBtn").click();
  await page.locator("#sullivanStop").click();
  await page.evaluate(() => window.navigationAsk);
  assert.equal(await page.evaluate(() => NRCAI.isWorkbenchBusy()), false);
  assert.ok(await page.locator("#messageInput").isEnabled());
  assert.match(await page.locator("#logOutput").innerText(), /CANCELLED/);
  askGate.resolve(); askGate = null;
  assert.doesNotMatch(await page.evaluate(() => (roomHistory.get(DM_CONV_FLAG | 999n) || []).map(m => m.message).join("\n")), /PINNED TO/);
  readyGate = deferred(); readyArrived = deferred();
  await page.evaluate(() => { window.navigationOpen = NRCAI.openSullivanWithContext(0n, { focused: false }); });
  await readyArrived.promise;
  await page.locator("#notesBtn").click();
  readyGate.resolve(); readyGate = null;
  await page.evaluate(() => window.navigationOpen);
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "notes", "late opening never reverses a navigation choice");
  console.log("PASS: Sullivan preparation/answer/apply navigation, correct background routing, chat drafts, return/stop, errors, session guards and single apply.");
  assert.deepEqual(errors, []);
  console.log("PASS: per-chat unread counts, direct/same-room/keyboard navigation, no duplicate Chat view, mobile switcher and Chat shortcut.");
} finally {
  await browser.close();
}
