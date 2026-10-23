// Browser-level client integration; no server or persistent data required.
// Run against a served client: NRC_CLIENT_URL=http://localhost:8000 node client/chat.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import fs from "node:fs/promises";

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1440, height: 900 } });
const page = await context.newPage();
const errors = [];
page.on("pageerror", (error) => errors.push(error.message));
async function selectMessage(row) {
  await row.scrollIntoViewIfNeeded();
  await row.locator(".col-message").evaluate(body => {
    const range = document.createRange();
    range.selectNodeContents(body.querySelector("p") || body);
    window.getSelection().removeAllRanges();
    window.getSelection().addRange(range);
  });
  await row.page().waitForFunction(() => document.querySelector("#logOutput .message-selected"));
}
try {
  await page.routeWebSocket("**/*", (socket) => socket.onMessage(() => {}));
  await page.goto(process.env.NRC_CLIENT_URL || "http://localhost:8000");
  await page.waitForFunction(() => window.NRCChat && window.NRCViewManager && typeof marked !== "undefined" && ws?.readyState === WebSocket.OPEN);
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  await page.evaluate(() => {
    myNickname = "ben";
    nicknameReceived = true;
    currentWorkspaceId = "chat-e2e";
    currentRoomId = 2n;
    roomHistory.clear();
    roomPresence.set(2n, new Map([["anna", {}], ["andy", {}], ["ben", {}]]));
    retainedRoomStates.set(2n, "disabled");
    window.NRCViewManager.setActiveView("chat");
    loadRoomHistory(2n);
    for (let i = 0; i < 180; i++) logMessage("Message", `Status ${i}: running checks`, 2n, { author: "anna" });
    updateRoomUI();
  });
  assert.equal(await page.locator("#logOutput .log-row").count(), 150);
  assert.ok(await page.evaluate(() => logOutput.scrollHeight - logOutput.clientHeight - logOutput.scrollTop < 48), "burst follows bottom");
  assert.ok(await page.locator("#chatNewMessages").isHidden());

  // Transport diagnostics must never become room messages, including retry exhaustion.
  const connectionDiagnostics = await page.evaluate(() => {
    const before = roomHistory.get(2n).length;
    const firstLog = systemLogHistory.length;
    ws.dispatchEvent(new Event("error"));
    ws.dispatchEvent(new CloseEvent("close", { code: 1013, reason: "storage busy", wasClean: false }));
    resetReconnection();
    reconnectAttempts = maxReconnectAttempts;
    ws.dispatchEvent(new CloseEvent("close", { code: 1006, wasClean: false }));
    resetReconnection();
    ws.dispatchEvent(new CloseEvent("close", { code: 1000, reason: "normal shutdown", wasClean: true }));
    updateConnectionStatus(true);
    retainedRoomStates.set(2n, "disabled");
    return {
      before, after: roomHistory.get(2n).length,
      endpoint: ws.url,
      retryEndpoint: getWsUrl(),
      entries: getSystemLogEntries().slice(firstLog),
    };
  });
  assert.equal(connectionDiagnostics.after, connectionDiagnostics.before);
  assert.equal(await page.locator("#logOutput .log-row").count(), 150);
  assert.deepEqual(connectionDiagnostics.entries.map(({ level, source }) => [level, source]), [
    ["ERROR", "websocket"], ["WARN", "websocket"], ["WARN", "websocket"],
    ["WARN", "websocket"], ["ERROR", "websocket"], ["INFO", "websocket"],
  ]);
  connectionDiagnostics.entries.forEach((entry, index) => {
    assert.ok(entry.message.includes(index === 2 ? connectionDiagnostics.retryEndpoint : connectionDiagnostics.endpoint));
  });
  assert.match(connectionDiagnostics.entries[0].message, /readyState=OPEN.*no failure cause/);
  assert.match(connectionDiagnostics.entries[1].message, /code=1013; clean=false; reason=storage busy; reconnect=scheduled/);
  assert.match(connectionDiagnostics.entries[2].message, /delay=1000ms; retry=1\//);
  assert.match(connectionDiagnostics.entries[3].message, /code=1006.*No close reason provided; reconnect=stopped/);
  assert.match(connectionDiagnostics.entries[4].message, /retry limit=.*manual reconnect required/);
  assert.match(connectionDiagnostics.entries[5].message, /code=1000; clean=true; reason=normal shutdown; reconnect=stopped/);

  const input = page.locator("#messageInput");
  assert.ok(await page.locator("#chatSearchCount").isHidden(), "no idle search label");
  const emptyComposer = await page.locator('.input-controls').boundingBox();
  assert.ok(emptyComposer.height <= 44, 'idle desktop composer occupies one row');
  assert.ok(await page.locator('#messageByteCount').isHidden());
  await input.fill('First line\nSecond line\nThird line');
  const expandedComposer = await page.locator('.input-controls').boundingBox();
  assert.ok(expandedComposer.height > emptyComposer.height, 'multiline chat grows');
  assert.equal(expandedComposer.y + expandedComposer.height, emptyComposer.y + emptyComposer.height, 'chat grows upward');
  await input.fill('ä'.repeat(23039));
  assert.ok(await page.locator('#messageByteCount').isHidden(), 'below 90% of UTF-8 limit');
  await input.fill('ä'.repeat(23040));
  assert.ok(await page.locator('#messageByteCount').isVisible(), 'counter appears at 90%');
  await input.fill('');
  assert.equal((await page.locator('.input-controls').boundingBox()).height, emptyComposer.height, 'clearing shrinks chat');
  await input.fill("Draft");
  await selectMessage(page.locator("#logOutput .log-row").last());
  await page.locator(".chat-reply-action").last().click();
  assert.match(await input.inputValue(), /^> anna:\n> Status 179: running checks\n\nDraft$/);
  await input.press("Escape");
  assert.equal(await input.inputValue(), "Draft");
  assert.ok(await page.locator("#chatReply").isHidden());

  await input.fill("Hi @an");
  await page.screenshot({ path: ".amp/in/artifacts/chat-autocomplete.png" });
  await page.locator(".autocomplete-option-command").filter({ hasText: "@anna" }).click();
  assert.equal(await input.inputValue(), "Hi @anna ");
  await input.fill("Hi @an");
  await input.press("ArrowDown");
  await input.press("Tab");
  assert.equal(await input.inputValue(), "Hi @anna ");

  await page.evaluate(() => { logOutput.scrollTop = 250; });
  const top = await page.evaluate(() => logOutput.scrollTop);
  await page.evaluate(() => logMessage("Message", "@ben Please verify the build.", 2n, { author: "anna" }));
  assert.equal(await page.evaluate(() => logOutput.scrollTop), top, "incoming message preserves reading position");
  assert.equal(await page.locator(".chat-mentioned").count(), 1);
  assert.match(await page.locator("#chatNewMessages").innerText(), /1 NEW · @ 1/);
  assert.equal(await page.locator("#chatUnreadDivider").count(), 1);
  await page.screenshot({ path: ".amp/in/artifacts/chat-unread.png" });
  await page.locator("#chatNewMessages").click();
  assert.ok(await page.locator("#chatNewMessages").isHidden());
  assert.ok(await page.evaluate(() => logOutput.scrollHeight - logOutput.clientHeight - logOutput.scrollTop < 48));

  const search = page.locator("#chatSearch");
  await search.fill("running checks");
  assert.ok(await page.locator("#chatSearchCount").isVisible(), "search exposes result count");
  assert.equal(await page.locator("#logOutput .log-row").count(), 180, "all loaded search matches are accessible");
  await search.fill("Status 0:");
  assert.equal(await page.locator("#logOutput .log-row").count(), 1, "search includes messages outside the DOM window");
  await search.fill("does-not-exist");
  assert.equal(await page.locator("#logOutput .log-row").count(), 0);
  assert.match(await page.locator("#chatSearchCount").innerText(), /0 MATCHES/);
  await page.screenshot({ path: ".amp/in/artifacts/chat-search-empty.png" });
  await page.evaluate(() => logMessage("Message", "does-not-exist now exists", 2n, { author: "anna" }));
  assert.equal(await page.locator("#logOutput .log-row").count(), 1);
  assert.match(await page.locator("#chatSearchCount").innerText(), /1 MATCHES/);
  assert.equal(await page.locator(".header-register-identity-row > #chatSearchCount").count(), 1);
  await page.getByRole("button", { name: "Clear chat search", exact: true }).click();
  assert.equal(await search.inputValue(), "");
  assert.ok(await search.evaluate(el => el === document.activeElement));
  assert.ok(await page.locator("#chatSearchCount").isHidden());
  assert.ok(await page.locator("#chatSearchClear").isHidden());
  await search.fill("Status 0:");
  await search.press("Escape");
  assert.ok(await page.locator("#chatSearchCount").isHidden(), "clearing search hides result count");

  assert.equal(await page.locator(".chat-header > #chatTools.header-register-control-row").count(), 1);
  const notifyTrigger = page.locator("#chatTools .custom-select__trigger");
  await notifyTrigger.click();
  await page.getByRole("listbox").getByRole("option", { name: "@ ONLY", exact: true }).click();
  assert.equal(await page.locator("#chatNotifications").inputValue(), "mentions");
  const policy = await page.evaluate(() => {
    const check = (message, roomId = 2n) => NRCChat.shouldNotify({ type: "Message", message, roomId });
    return [check("@ben hello"), check("ordinary"), check("> @ben quoted"), check("`@ben`"), check("[@ben](https://example.com)"), check("ordinary", 3n)];
  });
  assert.deepEqual(policy, [true, false, false, false, false, true]);
  await page.locator("#chatNotifications").selectOption("off");
  assert.equal(await page.evaluate(() => NRCChat.shouldNotify({ type: "Message", message: "@ben", roomId: 2n })), false);
  await page.evaluate(() => { currentRoomId = 3n; loadRoomHistory(3n); });
  assert.equal(await page.locator("#chatNotifications").inputValue(), "all");
  assert.match(await notifyTrigger.innerText(), /ALL/);
  await page.evaluate(() => { currentRoomId = 2n; loadRoomHistory(2n); });
  assert.equal(await page.locator("#chatNotifications").inputValue(), "off");
  assert.match(await notifyTrigger.innerText(), /OFF/);
  const delivery = await page.evaluate(() => {
    const original = sendNotification;
    const deliveries = [];
    sendNotification = (title) => deliveries.push(title);
    try {
      currentRoomId = 3n;
      loadRoomHistory(3n);
      logMessage("Message", "@ben muted", 2n, { author: "anna" });
      localStorage.setItem(`nrc-chat-notifications:${currentWorkspaceId}:2`, "mentions");
      logMessage("Message", "ordinary", 2n, { author: "anna" });
      logMessage("Message", "> @ben quoted", 2n, { author: "anna" });
      logMessage("Message", "@ben notify", 2n, { author: "anna" });
      currentRoomId = 2n;
      loadRoomHistory(2n);
      return deliveries;
    } finally { sendNotification = original; }
  });
  assert.equal(delivery.length, 1, "receive path obeys notification preferences");
  await page.evaluate(() => {
    currentWorkspaceId = "other-workspace";
    loadRoomHistory(2n);
  });
  assert.equal(await page.locator("#chatNotifications").inputValue(), "all");
  await page.evaluate(() => { currentWorkspaceId = "chat-e2e"; loadRoomHistory(2n); });
  assert.equal(await page.locator("#chatNotifications").inputValue(), "mentions");

  await page.evaluate(() => showSystemLog());
  assert.ok(await page.locator("#chatTools").isHidden());
  await page.evaluate(() => exitSystemLog());
  assert.ok(await page.locator("#chatTools").isVisible());

  // Exercise the existing send path, capture the outgoing wire frame rather than
  // depending on a running Odin server. Failed sends must keep the draft.
  await selectMessage(page.locator("#logOutput .log-row").last());
  await page.locator(".chat-reply-action").last().click();
  const draft = await input.inputValue();
  await page.evaluate(() => { ws = { readyState: 3 }; });
  await page.locator("#chatSend").click();
  assert.equal(await input.inputValue(), draft);
  await page.evaluate(() => {
    window.chatFrames = [];
    ws = { readyState: WebSocket.OPEN, send: (frame) => window.chatFrames.push(frame) };
  });
  await page.locator("#chatSend").click();
  assert.equal(await input.inputValue(), "");
  assert.ok(await page.locator("#chatReply").isHidden());
  assert.ok(await page.evaluate(() => window.chatFrames.length > 0));
  assert.equal(await page.locator(".type-sent blockquote").count(), 1);

  // Representative review fixture, separate from the deliberate failed send.
  await page.evaluate(async () => {
    await clearCurrentRoomMessages({ logResult: false });
    logMessage("Sent", "Can we test the release today?", 2n, { author: "YOU" });
    logMessage("Message", "The WebSocket tests passed. The build is ready.", 2n, { author: "anna" });
    logMessage("Sent", "> anna:\n> The WebSocket tests passed.\n\nThanks, I'll run the smoke tests next.", 2n, { author: "YOU" });
  });
  for (const theme of ["light", "dark"]) {
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate((theme) => {
        document.documentElement.dataset.theme = theme;
        logMessage("Message", "@ben The build is ready. **Please check the release.**", 2n, { author: "anna" });
        logOutput.scrollTop = logOutput.scrollHeight;
      }, theme);
      await input.fill("");
      await page.mouse.move(0, 0);
      const reply = page.locator(".chat-reply-action").last();
      const actions = page.locator("#logOutput .message-copy-actions").last();
      assert.equal(await actions.evaluate((node) => getComputedStyle(node).opacity), "0", "actions hidden at rest");
      if (width === 1440) await page.screenshot({ path: `.amp/in/artifacts/chat-reply-rest-${theme}.png` });
      await reply.focus();
      assert.equal(await actions.evaluate((node) => getComputedStyle(node).opacity), "1", "actions exposed by keyboard focus");
      await input.focus();
      await page.locator("#logOutput .log-row .col-message").last().hover();
      assert.equal(await actions.evaluate((node) => getComputedStyle(node).opacity), "0", "hover alone does not expose actions");
      const beforeSelection = await page.locator("#logOutput .log-row").last().boundingBox();
      await selectMessage(page.locator("#logOutput .log-row").last());
      assert.equal(await actions.evaluate((node) => getComputedStyle(node).opacity), "1", "selection exposes actions");
      assert.equal(await page.locator("#logOutput .message-copy-actions").first().evaluate((node) => getComputedStyle(node).opacity), "0", "other actions remain hidden");
      assert.equal((await page.locator("#logOutput .log-row").last().boundingBox()).height, beforeSelection.height, "selection does not shift messages");
      for (const backwards of [false, true]) {
        if (backwards) {
          await page.evaluate(() => {
            const s = getSelection();
            s.setBaseAndExtent(s.focusNode, s.focusOffset, s.anchorNode, s.anchorOffset);
          });
          await page.waitForFunction(() => {
            const r = getSelection().getRangeAt(0).getClientRects()[0];
            const a = document.querySelector(".message-selected .message-copy-actions").getBoundingClientRect();
            return Math.abs(a.left + a.width / 2 - r.left) <= a.width / 2 + 4;
          });
        }
        const end = await page.evaluate(backwards => {
          const rects = [...getSelection().getRangeAt(0).getClientRects()];
          return rects[backwards ? 0 : rects.length - 1].toJSON();
        }, backwards);
        const a = await actions.boundingBox();
        assert.ok(Math.abs(a.x + a.width / 2 - (backwards ? end.left : end.right)) <= a.width / 2 + 4, "toolbar stays near the active selection endpoint");
        assert.ok(a.y + a.height <= end.top || a.y >= end.bottom, "toolbar does not cover the endpoint line");
        const bounds = await page.locator("#logOutput").boundingBox();
        assert.ok(a.x >= bounds.x && a.x + a.width <= bounds.x + bounds.width, "toolbar stays inside transcript");
      }
      if (width === 1440) await page.screenshot({ path: `.amp/in/artifacts/chat-reply-selected-${theme}.png` });
      await page.locator(".chat-reply-action").last().click();
      await page.keyboard.insertText("I'll check the release now.");
      if (width === 390 && await page.locator("#chatSearch").isHidden()) {
        await page.locator("#mobileChatTools").click();
      }
      assert.ok(await page.locator("#chatSearch").isVisible());
      assert.ok(await page.locator("#chatCancelReply").isVisible());
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no horizontal overflow");
      await page.screenshot({ path: `.amp/in/artifacts/chat-${theme}-${width}.png` });
      await input.press("Escape");
    }
  }
  const touchContext = await browser.newContext({ serviceWorkers: "block", hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });
  try {
    const touchPage = await touchContext.newPage();
    await touchPage.routeWebSocket("**/*", (socket) => socket.onMessage(() => {}));
    await touchPage.goto(process.env.NRC_CLIENT_URL || "http://localhost:8000");
    await touchPage.waitForFunction(() => window.NRCChat && ws?.readyState === WebSocket.OPEN);
    await touchPage.evaluate(() => {
      loadRoomHistory(2n);
      logMessage("Message", "The build is ready for review.", 2n, { author: "anna" });
    });
    for (const theme of ["light", "dark"]) {
      await touchPage.evaluate((theme) => { document.documentElement.dataset.theme = theme; }, theme);
      const reply = touchPage.locator(".chat-reply-action").last();
      await selectMessage(touchPage.locator("#logOutput .log-row").last());
      assert.equal(await touchPage.locator(".message-copy-actions").last().evaluate((node) => getComputedStyle(node).opacity), "1", "touch selection exposes actions");
      await touchPage.screenshot({ path: `.amp/in/artifacts/chat-reply-touch-${theme}.png` });
      await reply.tap();
      assert.ok(await touchPage.locator("#chatCancelReply").isVisible());
      await touchPage.locator("#chatCancelReply").tap();
    }
  } finally { await touchContext.close(); }
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.evaluate(() => {
    currentRoomId = 2n;
    window.NRCViewManager.setActiveView("chat");
    window.NRCTasks.roomTasks.set(0n, new Map([[123n, { id: 123n, title: "Release checklist", priority: 0 }]]));
    window.NRCAssets.roomAssets.set(0n, new Map([[456n, { assetId: 456n, assetType: 5, preview: JSON.stringify({ title: "Release notes" }) }]]));
    loadRoomHistory(2n);
    logMessage("Message", "See [task:123] and [note:456].", 2n, { author: "anna" });
  });
  const requests = [];
  await page.route("**/search", async (route) => {
    const body = route.request().postDataJSON();
    requests.push(body);
    if (body.query === "failure") return route.fulfill({ status: 503, body: "unavailable" });
    if (body.query === "slow") await new Promise((resolve) => setTimeout(resolve, 500));
    await route.fulfill({ headers: { "X-NRC-Search-Version": "typed-v1" }, json: { results: body.query === "missing" ? [] : [
      { entity: { type: "asset", id: "18446744073709551615", conv_id: "0" }, metadata: { asset_type: 5 }, preview: JSON.stringify({ title: `${body.query} archive` }) },
      { entity: { type: "task", id: "987", conv_id: "0" }, metadata: { task: { status: 3 } }, preview: "Release deployment" },
      { entity: { type: "task", id: "888", conv_id: "3" }, preview: "Wrong room" },
      { entity: { type: "asset", id: "889", conv_id: "0" }, metadata: { asset_type: 1 }, preview: "Not a note" },
    ] } });
  });
  await input.fill("See #Release");
  await page.waitForFunction(() => document.querySelectorAll("#chatAutocomplete .autocomplete-option").length === 4);
  assert.deepEqual(requests.at(-1), { workspace: "chat-e2e", query: "Release", conv_id: "0", top_n: 15, filters: { entity_types: ["task", "asset"], asset_types: [5] } });
  assert.equal(await page.evaluate(() => window.NRCTasks.roomTasks.get(0n).has(987n)), false, "remote task was never loaded by pagination");
  assert.equal(await page.locator(".autocomplete-option-command").filter({ hasText: "[task:987]" }).evaluate((el) => el.firstChild.textContent), "Release deployment", "server title is the primary text");
  for (const theme of ["light", "dark"]) {
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate((theme) => { document.documentElement.dataset.theme = theme; }, theme);
      await input.focus();
      assert.ok(await page.locator("#chatAutocomplete").isVisible());
      assert.ok(await page.locator("#chatAutocomplete").evaluate((el) => el.scrollWidth <= el.clientWidth));
      await page.screenshot({ path: `.amp/in/artifacts/chat-references-${theme}-${width}.png` });
    }
  }
  await page.locator(".autocomplete-option-command").getByText("[note:456]", { exact: true }).click();
  assert.equal(await input.inputValue(), "See [note:456] ");
  await input.fill("See #123");
  await input.press("Tab");
  assert.equal(await input.inputValue(), "See [task:123] ");
  await input.fill("#remote");
  await page.locator(".autocomplete-option-command").getByText("[note:18446744073709551615]", { exact: true }).waitFor();
  await input.press("Enter");
  assert.equal(await input.inputValue(), "[note:18446744073709551615] ");
  await input.fill("#deployment");
  await page.locator(".autocomplete-option-command").filter({ hasText: "Release deployment" }).click();
  assert.equal(await input.inputValue(), "[task:987] ", "unloaded task inserts its exact typed reference");
  for (const [query, status] of [["failure", "SEARCH UNAVAILABLE"], ["missing", "NO MATCHES"]]) {
    await input.fill(`#${query}`);
    await page.locator(".autocomplete-status").filter({ hasText: status }).waitFor();
    await page.screenshot({ path: `.amp/in/artifacts/chat-references-${query}.png` });
    await input.press("Escape");
    assert.ok(await page.locator("#chatAutocomplete").isHidden());
  }
  await input.fill("#slow");
  await page.waitForTimeout(300);
  await input.press("Escape");
  await page.waitForTimeout(600);
  assert.ok(await page.locator("#chatAutocomplete").isHidden(), "stale search cannot reopen dismissed picker");
  await input.fill("#slow");
  await page.waitForTimeout(300);
  await input.fill("#missing");
  await page.locator(".autocomplete-status").filter({ hasText: "NO MATCHES" }).waitFor();
  await page.waitForTimeout(600);
  assert.equal(await page.locator("#chatAutocomplete .autocomplete-option").count(), 0, "stale results cannot replace a newer query");
  await input.fill("#slow");
  await page.waitForTimeout(300);
  await page.evaluate(() => { currentRoomId = 3n; });
  await page.waitForTimeout(600);
  assert.equal(await page.locator("#chatAutocomplete .autocomplete-option").count(), 2, "chat room changes preserve workspace search results");
  await page.evaluate(() => { currentRoomId = 2n; hideAutocomplete(); });
  await page.evaluate(() => {
    const root = document.createElement("div");
    root.innerHTML = '<p>[TASK:123] [note:18446744073709551615]</p><code>[task:123]</code><a href="#"><strong>[note:456]</strong></a>';
    window.NRCAI.processAssetReferences(root, [], 2n);
    const links = root.querySelectorAll(".task-reference");
    if (links.length !== 2 || links[0].textContent !== "Release checklist" || links[1].textContent !== "[note:18446744073709551615]") throw new Error("typed reference rendering or code/link exclusion failed");
    const opened = [];
    const originalOpen = window.NRCInspector.openEntity;
    const originalGet = window.NRCAssets.requestAsset;
    window.NRCInspector.openEntity = (entity) => opened.push(String(entity.id));
    window.NRCAssets.requestAsset = (room, id) => opened.push(String(id));
    try {
      links[0].dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
      links[1].click();
      if (opened.join(",") !== "123,18446744073709551615") throw new Error("reference navigation lost entity ID");
    } finally {
      window.NRCInspector.openEntity = originalOpen;
      window.NRCAssets.requestAsset = originalGet;
    }
  });
  console.log("PASS: unified task/note picker, remote workspace search, keyboard/mouse insertion, empty/error/cancel states, exact 64-bit navigation and Markdown exclusions");
  await page.evaluate(() => {
    serverReady = true;
    window.__originalTitleRequest = NRCAssets.requestAsset;
    window.__resolveChatTitle = null;
    NRCAssets.requestAsset = (_room, id, options) => {
      if (id === 9999n) { options.onError?.({ message: "Not found" }); return; }
      window.__resolveChatTitle = () => {
        const asset = { assetId: id, convId: 0n, assetType: AssetType.Note, preview: JSON.stringify({ title: "Freigabe prüfen" }) };
        NRCAssets.roomAssets.get(0n).set(id, asset);
        options.onSuccess({ asset });
      };
    };
    NRCAssets.roomAssets.get(0n).set(708n, { assetId: 708n, convId: 0n, assetType: AssetType.File, preview: JSON.stringify({ filename: "angebot.pdf" }) });
    logMessage("Message", "[task:123] #123 [note:18446744073709551615] [file:708] [note:9999] `#123` [unchanged](https://example.com/#123)", 2n, { author: "anna" });
  });
  const titleLinks = page.locator("#logOutput .log-row").last().locator(".task-reference");
  assert.deepEqual(await titleLinks.allTextContents(), ["Release checklist", "Release checklist", "[note:18446744073709551615]", "angebot.pdf", "[note:9999]"]);
  await page.waitForFunction(() => typeof window.__resolveChatTitle === "function");
  await page.evaluate(() => window.__resolveChatTitle());
  assert.equal(await titleLinks.nth(2).textContent(), "Freigabe prüfen");
  assert.equal(await titleLinks.nth(2).getAttribute("title"), "NOTE #18446744073709551615");
  assert.match(await titleLinks.nth(4).getAttribute("title"), /NOTE #9999.*Not available/);
  await page.evaluate(() => {
    const task = NRCTasks.roomTasks.get(0n).get(123n);
    task.title = "Release final prüfen";
    document.dispatchEvent(new CustomEvent("nrc:task-changed", { detail: { task, reason: "updated" } }));
    const asset = NRCAssets.roomAssets.get(0n).get(18446744073709551615n);
    asset.preview = JSON.stringify({ title: "Freigabe erteilt" });
    document.dispatchEvent(new CustomEvent("nrc:asset-updated", { detail: { asset } }));
  });
  assert.deepEqual(await titleLinks.allTextContents(), ["Release final prüfen", "Release final prüfen", "Freigabe erteilt", "angebot.pdf", "[note:9999]"]);
  assert.match(await page.evaluate(() => roomHistory.get(2n).at(-1).message), /\[note:18446744073709551615\]/, "stored reference survives display resolution and renames");
  await page.evaluate(() => { NRCAssets.requestAsset = window.__originalTitleRequest; });
  console.log("PASS: chat titles from cache and exact reads, legacy IDs, files, renames, missing targets and unchanged stored references");
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.evaluate(() => logMessage("Sent", "Eigene **Nachricht** mit [task:123].", 2n, { author: "ben" }));
  const ownCopy = page.locator("#logOutput .log-row").last();
  await selectMessage(ownCopy);
  await ownCopy.getByRole("button", { name: "Kopieren", exact: true }).click();
  await ownCopy.getByText("Kopiert", { exact: true }).waitFor();
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), "Eigene **Nachricht** mit [task:123].");
  await ownCopy.getByRole("button", { name: "Mit Formatierung kopieren", exact: true }).click();
  await ownCopy.getByText("Mit Formatierung kopiert", { exact: true }).waitFor();
  const ownHTML = await page.evaluate(async () => (await (await navigator.clipboard.read())[0].getType("text/html")).text());
  assert.match(ownHTML, /<strong>Nachricht<\/strong>/);
  assert.match(ownHTML, /Release final prüfen/);
  assert.doesNotMatch(ownHTML, /message-copy-actions|Mit Formatierung kopiert|Kopiert/);
  assert.equal(await page.locator("#logOutput .log-row.type-message").first().getByRole("button", { name: "Mit Formatierung kopieren", exact: true }).count(), 1, "received messages expose the same direct controls");
  console.log("PASS: shared direct copy controls on own and received chat messages, Markdown IDs and formatted title links");
  await page.unroute("**/search");
  await page.route("**/search", async (route) => {
    const body = route.request().postDataJSON();
    assert.deepEqual(body.asset_types, [5], "notes retain their legacy search contract");
    assert.equal(body.conv_id, "0");
    if (body.query === "slow") await new Promise((resolve) => setTimeout(resolve, 500));
    await route.fulfill({ json: { results: [{ asset_id: "789", preview: JSON.stringify({ title: "Remote note title" }) }] } });
  });
  await page.evaluate(() => {
    window.NRCAssets.roomAssets.set(0n, new Map());
    searchServiceAvailable = true;
    window.NRCViewManager.setActiveView("notes");
  });
  if (await page.locator("#notesSearch").isHidden()) await page.locator("#notesPanel [data-mobile-filters]").click();
  await page.locator("#notesSearch").fill("remote");
  await page.locator("#notesList .note-title").getByText("Remote note title", { exact: true }).waitFor();
  assert.equal(await page.locator('#notesList .note-card[data-note-id="789"]').count(), 1);
  await page.locator("#notesSearch").fill("slow");
  await page.waitForTimeout(300);
  await page.locator("#notesSearch").fill("");
  await page.waitForTimeout(600);
  assert.equal(await page.locator("#notesList .note-card").count(), 0, "clearing notes search discards the delayed remote result");
  console.log("PASS: Notes uses shared search with legacy response rendering and cancellation on clear");
  await page.goto(new URL("design-system/", process.env.NRC_CLIENT_URL || "http://localhost:8000").href);
  for (const theme of ["light", "dark"]) {
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate((theme) => { document.documentElement.dataset.theme = theme; }, theme);
      const surfaces = await page.evaluate(() => {
        const sample = document.querySelector("#markdownQuotes .note-description");
        const results = [];
        for (const name of ["agenda-preview", "note-description", "note-detail-preview", "task-detail-desc-preview", "message-content", "asset-preview-markdown"]) {
          sample.className = name;
          const quote = sample.querySelector("blockquote");
          results.push({
            name,
            border: getComputedStyle(quote).borderLeftWidth,
            leftMargin: getComputedStyle(quote).marginLeft,
            rightMargin: getComputedStyle(quote).marginRight,
            nestedMargin: getComputedStyle(quote.querySelector("blockquote")).marginLeft,
            firstMargin: getComputedStyle(quote.firstElementChild).marginTop,
            lastMargin: getComputedStyle(quote.lastElementChild).marginBottom,
            nestedBackground: getComputedStyle(quote.querySelector("blockquote")).backgroundColor,
            fits: quote.scrollWidth <= quote.clientWidth,
          });
        }
        sample.className = "note-description";
        return results;
      });
      for (const surface of surfaces) {
        assert.equal(surface.border, "2px", surface.name);
        assert.equal(surface.leftMargin, width <= 768 ? "4px" : "8px", surface.name);
        assert.equal(surface.rightMargin, "0px", surface.name);
        assert.equal(surface.nestedMargin, "0px", surface.name);
        assert.equal(surface.firstMargin, "0px", surface.name);
        assert.equal(surface.lastMargin, "0px", surface.name);
        assert.equal(surface.nestedBackground, "rgba(0, 0, 0, 0)", surface.name);
        assert.ok(surface.fits, surface.name);
      }
      await page.locator("#markdownQuotes").screenshot({ path: `.amp/in/artifacts/markdown-quotes-${theme}-${width}.png` });
    }
  }
  console.log("PASS: shared Markdown quote styles across six surfaces, nested content, light/dark, desktop/mobile");

  // Exercise the real Sullivan request/render path, with disposable service replies.
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(process.env.NRC_CLIENT_URL || "http://localhost:8000");
  await page.waitForFunction(() => window.NRCAI && ws?.readyState === WebSocket.OPEN);
  await page.evaluate(async () => {
    currentRoomId = 2n;
    NRCViewManager.setActiveView("chat");
    await clearCurrentRoomMessages({ roomId: 2n, logResult: false });
    loadRoomHistory(2n);
    logMessage("Message", "Erste Nachricht", 2n, { author: "anna", timestamp: 1000 });
    logMessage("Message", "Kurz danach", 2n, { author: "anna", timestamp: 300999 });
    logMessage("Message", "Nach fünf Minuten", 2n, { author: "anna", timestamp: 600999 });
    logMessage("Message", "Andere Person", 2n, { author: "mika", timestamp: 601000 });
  });
  assert.equal(await page.locator(".col-tag").filter({ hasText: "anna" }).nth(1).isVisible(), false, "consecutive messages share their author label");
  assert.ok(await page.locator(".col-tag").filter({ hasText: "anna" }).nth(2).isVisible(), "five-minute boundary begins a new group");
  assert.ok(await page.locator(".col-tag").filter({ hasText: "mika" }).isVisible(), "changing author begins a new group");
  const times = page.locator("#logOutput .col-time");
  assert.ok(await times.nth(0).isVisible(), "group starts with a timestamp");
  assert.ok(await times.nth(1).isHidden(), "continuation omits its timestamp");
  assert.ok(await times.nth(2).isVisible(), "five-minute boundary restores the timestamp");
  assert.ok(await times.nth(3).isVisible(), "different author restores the timestamp");
  const messageGaps = await page.locator("#logOutput .log-row").evaluateAll(rows => {
    const paragraphs = rows.map(row => row.querySelector(".col-message p").getBoundingClientRect());
    return paragraphs.slice(1).map((paragraph, index) => paragraph.top - paragraphs[index].bottom);
  });
  assert.ok(messageGaps[0] <= 8, "consecutive messages stay compact, without accumulated paragraph/card spacing");
  assert.ok(messageGaps[1] > messageGaps[0] + 16, "five-minute pause retains visible group separation");
  assert.ok(messageGaps[2] > messageGaps[0] + 16, "speaker change retains visible group separation");
  assert.equal(await page.locator("#logOutput [data-avatar]").count(), 0);
  await selectMessage(page.locator("#logOutput .log-row").nth(1));
  await page.evaluate(() => {
    const bodies = document.querySelectorAll("#logOutput .col-message");
    const range = document.createRange();
    range.setStart(bodies[0].firstChild, 0);
    range.setEndAfter(bodies[1].lastChild);
    window.getSelection().removeAllRanges();
    window.getSelection().addRange(range);
  });
  await page.waitForFunction(() => !document.querySelector("#logOutput .message-selected"));
  await page.evaluate(() => window.getSelection().removeAllRanges());
  for (const text of ["**QUERY** SELECT * FROM tasks", "**ASK**\nKeep this second line", "**QUERY · PLAN · CONTEXT WORKSPACE**\nNot an AI turn"]) {
    await page.evaluate(text => logMessage("Sent", text, 2n), text);
    const sent = page.locator("#logOutput .log-row").last();
    assert.equal(await sent.locator(".col-message").innerText(), text.replaceAll("**", ""));
    assert.equal(await sent.evaluate(node => node.classList.contains("ledger-ai-query")), false);
  }
  await page.route("**/ask/ready", route => route.fulfill({ json: { ai_username: "sullivan-test" } }));
  const askRequests = [];
  await page.route("**/ask", async route => {
    askRequests.push(route.request().postDataJSON());
    await route.fulfill({ json: {
      answer: "Jochen Keil gehört zum **Kreismedienzentrum Esslingen**. [asset:1517] [asset:1515]\n\nSiehe #123, [task:123] und #18446744073709551615. `#123` [#123](https://example.org)\n\n## Nächste Schritte\n\n- **Kontakt prüfen**\n- *Freigabe einholen*\n\n| Kontakt | Status |\n| --- | --- |\n| Jochen | Offen |",
      sources: [{ type: "asset", id: "1517", title: "Jochen Keil", preview: "Kontakt · Keil@kmz-es.de" },
        { type: "task", id: "123", title: "Freigabe prüfen" },
        { type: "task", id: "18446744073709551615", title: "Große Task-ID" },
        { type: "asset", id: "1515", title: "Kreismedienzentrum Esslingen" }],
      session_id: "chat-design-test", history_turns: askRequests.length - 1,
    } });
  });
  await page.evaluate(async () => {
    currentRoomId = 2n;
    const aiDM = DM_CONV_FLAG | 999n;
    activeDMs.set(aiDM, { username: "sullivan-test", online: true });
    subscribedRooms.add(aiDM); roomHistory.set(aiDM, []);
    NRCAssets.roomAssets.set(0n, new Map([[1517n, { assetId: 1517n, assetType: NRCAssets.AssetType.CustomerContact,
      preview: JSON.stringify({ version: 1, title: "Jochen Keil", email: "keil@example.org", role: "<Koordination>" }) }]]));
    await NRCAI.openSullivanWithContext(0n, { focused: true });
    logMessage("Sent", "**QUERY · PLAN · CONTEXT WORKSPACE**\nFrühere Frage", aiDM, { aiContextRoomId: 0n });
    await NRCAI.handleAsk("Zu welchem Kunden gehört Jochen Keil?");
  });
  assert.equal(await page.locator(".ledger-ai-query .col-message").first().innerText(), "Frühere Frage");
  assert.equal(await page.locator(".ledger-ai-query .col-message").last().innerText(), "Zu welchem Kunden gehört Jochen Keil?");
  const answer = page.locator(".ledger-ai-answer").last();
  assert.ok((await answer.innerText()).includes("Jochen Keil gehört zum Kreismedienzentrum Esslingen"));
  assert.ok(!(await page.locator("#logOutput").innerText()).match(/AI COMPLETE|AI RESPONSE|FOLLOW-UP CONTEXT|QUERY ·/));
  assert.equal(await page.locator(".sullivan-empty").count(), 0);
  assert.equal(await page.locator("#sullivanStop").isVisible(), false);
  assert.equal(await answer.locator(".task-reference").first().innerText(), "[1]");
  assert.deepEqual(await answer.getByRole("link", { name: "Quelle: Freigabe prüfen", exact: true }).allTextContents(), ["[2]", "[2]"]);
  assert.equal(await answer.locator("code").innerText(), "#123");
  assert.equal(await answer.locator('a[href="https://example.org"]').innerText(), "#123");
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await selectMessage(answer);
  await answer.getByRole("button", { name: "Kopieren", exact: true }).click();
  await answer.getByText("Kopiert", { exact: true }).waitFor();
  const markdownCopy = await page.evaluate(() => navigator.clipboard.readText());
  assert.match(markdownCopy, /\*\*Kreismedienzentrum Esslingen\*\*/);
  assert.match(markdownCopy, /\[asset:1517\]/, "Markdown copy keeps the stored references");
  await answer.getByRole("button", { name: "Mit Formatierung kopieren", exact: true }).click();
  await answer.getByText("Mit Formatierung kopiert", { exact: true }).waitFor();
  const richCopy = await page.evaluate(async () => {
    const [item] = await navigator.clipboard.read();
    return { types: item.types, html: await (await item.getType("text/html")).text(), plain: await (await item.getType("text/plain")).text() };
  });
  assert.ok(richCopy.types.includes("text/html") && richCopy.types.includes("text/plain"));
  assert.equal(richCopy.plain, markdownCopy, "text-only targets retain the Markdown fallback");
  assert.doesNotMatch(richCopy.html, /message-copy-actions|ai-response-actions|ai-response-evidence|Recherche|Als Notiz speichern|Mit Formatierung kopiert/);
  await page.evaluate(() => {
    const editor = document.createElement("div");
    editor.id = "clipboardPasteTarget";
    editor.contentEditable = "true";
    editor.style.cssText = "position:fixed;inset:20px;z-index:20000;background:white;color:black;overflow:auto";
    document.body.append(editor);
    editor.focus();
  });
  try {
    await page.keyboard.press("Control+V");
    const pasted = page.locator("#clipboardPasteTarget");
    await pasted.locator("h2").waitFor();
    assert.equal(await pasted.locator("h2").innerText(), "Nächste Schritte");
    assert.equal(await pasted.locator("strong").first().innerText(), "Kreismedienzentrum Esslingen");
    assert.equal(await pasted.locator("ul li").count(), 2);
    assert.equal(await pasted.locator("em").innerText(), "Freigabe einholen");
    assert.equal(await pasted.locator("table tbody td").first().innerText(), "Jochen");
    assert.equal(await pasted.locator("code").innerText(), "#123");
    assert.equal(await pasted.locator("a[href]").innerText(), "#123");
    assert.equal(new URL(await pasted.locator("a[href]").getAttribute("href")).href, "https://example.org/");
    assert.ok((await pasted.innerText()).includes("[1]"), "formatted copy retains the visible citation numbering");
    assert.equal(await pasted.locator("button, details").count(), 0, "pasting never includes answer controls or research UI");
  } finally { await page.evaluate(() => document.getElementById("clipboardPasteTarget").remove()); }
  await page.evaluate(() => {
    window.__originalClipboardWrite = navigator.clipboard.write;
    navigator.clipboard.write = async () => { throw new Error("clipboard denied"); };
  });
  try {
    await selectMessage(answer);
    await answer.getByRole("button", { name: "Mit Formatierung kopieren", exact: true }).click();
    await answer.getByText("Kopieren fehlgeschlagen: clipboard denied", { exact: true }).waitFor();
  } finally { await page.evaluate(() => { navigator.clipboard.write = window.__originalClipboardWrite; }); }
  console.log("PASS: real Markdown and HTML clipboard writes, formatted paste with headings/lists/table/code/links/citations, UI exclusion and denied-write feedback");
  const taskCitation = answer.getByRole("link", { name: "Quelle: Große Task-ID", exact: true });
  await taskCitation.focus();
  await page.keyboard.press("Enter");
  assert.equal(await page.locator("#aiSourcePanel h2").innerText(), "Große Task-ID");
  await page.evaluate(() => {
    window.originalInspectorOpen = NRCInspector.openEntity;
    NRCInspector.openEntity = ref => { window.openedSource = { type: ref.type, id: String(ref.id) }; };
  });
  await page.getByRole("button", { name: "Datensatz öffnen ↗", exact: true }).click();
  assert.deepEqual(await page.evaluate(() => window.openedSource), { type: "task", id: "18446744073709551615" });
  await page.evaluate(() => { NRCInspector.openEntity = window.originalInspectorOpen; });
  await page.evaluate(async () => {
    await NRCAI.openSullivanWithContext(0n, { focused: true });
  });
  await answer.locator(".ai-response-evidence > summary").click();
  assert.ok((await answer.locator(".ai-response-evidence").innerText()).includes("processing fresh"), "completed research remains inspectable");
  await answer.locator(".ai-response-evidence > summary").click();
  const citation = answer.getByRole("link", { name: "Quelle: Jochen Keil" });
  await citation.focus();
  await page.keyboard.press("Enter");
  assert.equal(await page.locator("#aiSourcePanel h2").innerText(), "Jochen Keil");
  assert.equal(await page.locator("#aiSourcePanel .ai-source-facts a").getAttribute("href"), "mailto:keil%40example.org");
  assert.ok((await page.locator("#aiSourcePanel .ai-source-facts").innerText()).includes("<Koordination>"));
  assert.ok((await page.locator("#aiSourcePanel .ai-source-facts").innerText()).includes("CRM Kontakt"));
  await page.locator("#aiSourcePanel .ai-source-item").last().click();
  assert.equal(await page.locator("#aiSourcePanel h2").innerText(), "Kreismedienzentrum Esslingen");
  assert.equal(await page.locator("#aiSourcePanel .ai-source-facts a").count(), 0, "uncached sources never inherit another record's details");
  await page.keyboard.press("Escape");
  assert.equal(await page.locator("#aiSourcePanel").count(), 0);
  assert.equal(await citation.evaluate(node => node === document.activeElement), true, "closing evidence returns focus to its citation");
  await answer.locator(".ai-response-more > summary").click();
  assert.ok(await answer.getByRole("button", { name: "Als Notiz speichern", exact: true }).isVisible());
  assert.equal(await answer.getByRole("button", { name: "NEW SESSION", exact: true }).count(), 0);
  await page.evaluate(async () => NRCAI.handleAsk("Wer arbeitet da noch?"));
  assert.equal(askRequests[1].session_id, "chat-design-test", "new presentation preserves follow-up context");

  // Transport-only historical answers have no aiAnswer/aiSources metadata.
  await page.evaluate(() => logMessage("Message", "**AI RESPONSE · CONTEXT WORKSPACE**\n**FOLLOW-UP CONTEXT:** LAST 1 TURN(S)\n\nHistorische Antwort. [note:91]\n\n**SOURCES (1)**\n- [note:91] Gesprächsnotiz", NRCAI.getDisplayConvId(), { author: "sullivan-ai", aiContextRoomId: 0n }));
  const historical = page.locator(".ledger-ai-answer").last();
  assert.equal(await historical.getByRole("link", { name: "Quelle: Gesprächsnotiz" }).innerText(), "[1]");
  await selectMessage(historical);
  await historical.getByRole("button", { name: "Kopieren", exact: true }).click();
  await historical.getByText("Kopiert", { exact: true }).waitFor();
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), "Historische Antwort. [note:91]", "historical copies omit transport envelopes");
  await historical.locator(".ai-response-evidence > summary").click();
  assert.ok((await historical.innerText()).includes("[1] Gesprächsnotiz"));
  for (const theme of ["light", "dark"]) {
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; logOutput.scrollTop = 0; }, theme);
      await page.locator(".ledger-ai-answer .task-reference").first().click();
      assert.ok(await page.locator("#aiSourcePanel").isVisible());
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
      assert.equal(await page.locator("#logOutput").evaluate(node => node.inert), width === 390);
      assert.equal(await input.evaluate(node => !!node.closest("[inert]")), false, "visible composer remains usable");
      if (width === 390) {
        for (const key of ["Shift+Tab", "Tab", "Tab", "Shift+Tab"]) {
          await page.keyboard.press(key);
          assert.equal(await page.evaluate(() => !!document.activeElement.closest("#logOutput, .chat-header")), false, "covered transcript and header never receive focus");
        }
        await page.keyboard.press("Escape");
        assert.equal(await page.locator("#aiSourcePanel").count(), 0);
        assert.equal(await page.locator("#logOutput").evaluate(node => node.inert), false);
        assert.equal(await page.locator(".ledger-ai-answer .task-reference").first().evaluate(node => node === document.activeElement), true);
        await page.locator(".ledger-ai-answer .task-reference").first().click();
        await page.setViewportSize({ width: 1440, height: 1000 });
        assert.equal(await page.locator("#logOutput").evaluate(node => node.inert), false);
        await page.locator(".ledger-ai-answer .task-reference").first().focus();
        await page.setViewportSize({ width: 390, height: 1000 });
        await page.waitForFunction(() => document.activeElement.closest("#aiSourcePanel"));
      }
      const composer = await input.boundingBox();
      assert.ok(composer.y + composer.height <= 1000, "composer stays inside viewport");
      await page.locator("#aiSourcePanel button[aria-label='Quellen schließen']").click();
    }
  }
  await page.locator(".ledger-ai-answer .task-reference").first().click();
  await page.evaluate(() => { NRCViewManager.setActiveView("chat"); loadRoomHistory(2n); });
  assert.equal(await page.locator("#aiSourcePanel").count(), 0);
  assert.equal(await page.locator("#logOutput").evaluate(node => node.inert), false);
  console.log("PASS: Sullivan requests/follow-up, clean answers, historical citations, research disclosure, source selection, keyboard focus, actions, light/dark desktop/mobile");
  assert.deepEqual(errors, []);
  console.log("PASS: chat quotes/send, mouse/keyboard mentions, scroll/unread, local search, notification isolation, desktop/mobile light/dark");
} finally {
  await context.close();
  await browser.close();
}
