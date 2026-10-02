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

  const input = page.locator("#messageInput");
  assert.ok(await page.locator("#chatSearchCount").isHidden(), "no idle search label");
  await input.fill("Draft");
  await page.locator("#logOutput .log-row .col-message").last().hover();
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
  await page.locator("#logOutput .log-row .col-message").last().hover();
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
      assert.equal(await reply.evaluate((node) => getComputedStyle(node).opacity), "0", "reply hidden at rest");
      if (width === 1440) await page.screenshot({ path: `.amp/in/artifacts/chat-reply-rest-${theme}.png` });
      await reply.focus();
      assert.equal(await reply.evaluate((node) => getComputedStyle(node).opacity), "1", "reply exposed by keyboard focus");
      await input.focus();
      await page.locator("#logOutput .log-row .col-message").last().hover();
      assert.equal(await reply.evaluate((node) => getComputedStyle(node).opacity), "1", "hovering message text exposes reply");
      assert.equal(await page.locator(".chat-reply-action").first().evaluate((node) => getComputedStyle(node).opacity), "0", "other replies remain hidden");
      if (width === 1440) await page.screenshot({ path: `.amp/in/artifacts/chat-reply-hover-${theme}.png` });
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
      assert.equal(await reply.evaluate((node) => getComputedStyle(node).opacity), "1", "touch action visible without hover");
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
    if (links.length !== 2 || links[0].textContent !== "[task:123]" || links[1].textContent !== "[note:18446744073709551615]") throw new Error("typed reference rendering or code/link exclusion failed");
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
  assert.deepEqual(errors, []);
  console.log("PASS: chat quotes/send, mouse/keyboard mentions, scroll/unread, local search, notification isolation, desktop/mobile light/dark");
} finally {
  await context.close();
  await browser.close();
}
