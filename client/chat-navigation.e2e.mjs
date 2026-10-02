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
  assert.deepEqual(errors, []);
  console.log("PASS: per-chat unread counts, direct/same-room/keyboard navigation, no duplicate Chat view, mobile switcher and Chat shortcut.");
} finally {
  await browser.close();
}
