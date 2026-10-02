// Oracle regressions against the disposable test/customer-workspace-dev.mjs.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error("Set NRC_CUSTOMERS_TEST_URL to the disposable fixture");
const browser = await chromium.launch();
const workspace = `customer-review-${Date.now()}`;
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`${url}/#workspace=${workspace}`);
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  const ids = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    let company;
    for (let i = 0; i < 40; i++) {
      const result = await rpc(options => NRCAssets.sendCreateAsset(currentRoomId, 8, 0, 0n,
        JSON.stringify({ version: 1, title: `Company ${String(i).padStart(2, "0")}`, city: "Hamburg", padding: "x".repeat(3800) }), "", 0, options));
      if (i === 0) company = result.asset.assetId;
    }
    const contact = await rpc(options => NRCTransactions.sendCreateLinkedAsset(currentRoomId, 9, '{"version":1,"title":"Anna Berger","role":"Project lead"}', "", company, options));
    await rpc(options => NRCTransactions.sendCreateLinkedAsset(currentRoomId, 10, '{"version":1,"title":"Rollout agreed","kind":"Call","excerpt":"Send documentation before Friday."}', "Send documentation before Friday.", company, options));
    const note = await rpc(options => NRCAssets.sendCreateAsset(currentRoomId, 5, 0, 0n, '{"title":"Project brief"}', "# Project brief", 0, options));
    const edge = await rpc(options => NRCEdges.sendCreateEdge(currentRoomId, 1, note.asset.assetId, 1, company, 1, options));
    for (let i = 0; i < 70; i++) {
      await rpc(options => NRCTasks.sendCreateTask(currentRoomId, `Completed task ${i}`, "d".repeat(2000), 100, 0, "", 0n, [], 3, 0, "Customer work", options));
    }
    return { company: String(company), contact: String(contact.assetId), note: String(note.asset.assetId), edge: String(edge.edge.edgeId) };
  });
  await page.reload();
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  await page.click("#customersBtn");
  await page.waitForFunction(() => !document.getElementById("customerNew").disabled);
  assert.ok(await page.locator(".customer-row").count() < 40, "byte-bounded register stops after its first page");
  // The register opens on its first record, so the arrows walk from there.
  assert.equal(await page.locator('.customer-row[aria-pressed="true"] strong').textContent(), "Company 00", "register opens on its first record");
  await page.keyboard.press("ArrowDown");
  assert.equal(await page.locator('.customer-row[aria-pressed="true"] strong').textContent(), "Company 01");
  await page.keyboard.press("ArrowUp");
  assert.equal(await page.locator('.customer-row[aria-pressed="true"] strong').textContent(), "Company 00");
  await page.locator("#customersSearch").focus();
  await page.keyboard.press("ArrowDown");
  assert.equal(await page.locator('.customer-row[aria-pressed="true"] strong').textContent(), "Company 00", "search owns its arrow keys");
  await page.locator(".customers-register").evaluate(register => { register.scrollTop = register.scrollHeight; });
  await page.waitForFunction(() => document.querySelectorAll(".customer-row").length === 40);
  assert.equal(await page.locator(".customer-row").count(), 40, ">128 KiB asset register loads automatically on scroll");

  // Keyboard continuation must work even while the next page is in flight.
  await page.locator(".customers-register").evaluate(register => { register.scrollTop = 0; });
  await page.click("#customersRefresh");
  await page.waitForFunction(() => !document.getElementById("customerNew").disabled);
  const firstPageCount = await page.locator(".customer-row").count();
  const customerCountBeforePaging = await page.locator("#customersState").textContent();
  await page.evaluate(() => {
    const request = NRCAssets.requestCustomerPage;
    window.customerPageCalls = 0;
    NRCAssets.requestCustomerPage = async (...args) => {
      window.customerPageCalls++;
      await new Promise(resolve => { window.releaseCustomerPage = resolve; });
      NRCAssets.requestCustomerPage = request;
      return request(...args);
    };
    document.querySelector(".customer-row:last-child").click();
  });
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => !!window.releaseCustomerPage);
  assert.equal(await page.locator("#customersState").textContent(), customerCountBeforePaging, "paging preserves the loaded customer count while the next page is in flight");
  if (process.env.NRC_CUSTOMERS_SCREENSHOTS) {
    await fs.mkdir(process.env.NRC_CUSTOMERS_SCREENSHOTS, { recursive: true });
    await page.screenshot({ path: `${process.env.NRC_CUSTOMERS_SCREENSHOTS}/review-paging-in-flight.png`, fullPage: true });
  }
  await page.keyboard.press("ArrowDown");
  assert.equal(await page.evaluate(() => window.customerPageCalls), 1, "repeat keys do not duplicate in-flight pages");
  await page.evaluate(() => window.releaseCustomerPage());
  await page.waitForFunction(index => document.querySelectorAll(".customer-row")[index]?.getAttribute("aria-pressed") === "true", firstPageCount);
  assert.equal(await page.locator("#customersState").textContent(), "40 / 40 CUSTOMERS", "customer count advances directly after paging");
  assert.equal(await page.locator('.customer-row[aria-pressed="true"] strong').textContent(), `Company ${String(firstPageCount).padStart(2, "0")}`);
  assert.equal(await page.evaluate(() => document.activeElement.getAttribute("aria-pressed")), "true", "focus follows selection across the page boundary");
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.setAttribute("data-theme", theme), theme);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.evaluate(async () => {
      document.getElementById("customersPanel").scrollTop = 0;
      await NRCCustomers.reload();
    });
    await page.waitForFunction(() => !document.getElementById("customerNew").disabled);
    assert.ok(await page.locator(".customer-row").count() < 40);
    await page.locator("#customersMore").evaluate(button => button.scrollIntoView({ block: "end" }));
    await page.waitForFunction(() => document.querySelectorAll(".customer-row").length === 40);
    assert.equal(await page.locator("#customersMore").isHidden(), true, "mobile scroll exhausts pages without clicking");
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.click(`[data-company="${ids.company}"]`);
  await page.waitForFunction(() => document.getElementById("customerWork").textContent.includes("Project brief"));
  assert.equal(await page.locator("#customerWork .note-link-direction").textContent(), "←", "incoming relation direction is explicit");
  await page.click("#customerLinkAdd");
  await page.click('.note-link-picker:not(.hidden) [data-kind="task"]');
  await page.waitForFunction(() => document.querySelectorAll(".note-link-picker:not(.hidden) .note-link-picker-item").length === 50);
  await page.locator(".note-link-picker:not(.hidden) .note-link-picker-more").click();
  // The newest 50 already carry the last task, so waiting for its title proves
  // nothing; the second page is what has to land.
  await page.waitForFunction(() => document.querySelectorAll(".note-link-picker:not(.hidden) .note-link-picker-item").length === 70);
  assert.equal(await page.locator(".note-link-picker:not(.hidden) .note-link-picker-item").count(), 70, ">128KiB completed tasks load through pages");
  assert.equal(await page.locator(".note-link-picker:not(.hidden) .note-link-picker-more").isHidden(), true, "MORE hides once every matching task is loaded");
  await page.keyboard.press("Escape");

  // Actual write, delayed UI acknowledgement. Later keystrokes cannot be lost.
  await page.click(".customer-identity [data-edit]");
  await page.fill('[name="city"]', "Berlin");
  await page.locator("#customerSave").focus();
  await page.keyboard.press("ArrowDown");
  assert.equal(await page.locator('.customer-row[aria-pressed="true"]').getAttribute("data-company"), ids.company, "editor controls own their arrow keys");
  await page.evaluate(() => {
    const send = NRCAssets.sendUpdateAsset;
    NRCAssets.sendUpdateAsset = (...args) => {
      NRCAssets.sendUpdateAsset = send;
      const success = args[6].onSuccess;
      args[6].onSuccess = result => { window.finishCustomerSave = () => success(result); };
      return send(...args);
    };
  });
  await page.click("#customerSave");
  await page.waitForFunction(() => !!window.finishCustomerSave);
  assert.equal(await page.locator('[name="city"]').evaluate(input => input.readOnly), true);
  await page.locator('[name="city"]').focus();
  await page.keyboard.type("ignored");
  assert.equal(await page.inputValue('[name="city"]'), "Berlin");
  assert.equal(await page.evaluate(() => NRCInspector.close()), false, "pending acknowledged writes block disposal");
  await page.evaluate(() => window.finishCustomerSave());
  await page.waitForFunction(() => !document.getElementById("customerSave"));
  assert.match(await page.locator(".customer-identity").textContent(), /Berlin/);
  await page.click(".customer-identity [data-edit]");
  await page.fill('[name="city"]', "Draft city");
  await page.keyboard.press("Escape");
  await page.locator(".nrc-dialog").getByRole("button", { name: "Cancel", exact: true }).click();
  assert.equal(await page.inputValue('[name="city"]'), "Draft city");
  await page.click("#customerCancel");
  await page.getByRole("button", { name: "Discard", exact: true }).click();
  await page.click("#customerClose");

  const peer = await context.newPage();
  await peer.goto(`${url}/#workspace=${workspace}`);
  await peer.waitForFunction(() => serverReady);
  await page.click("#customerLinkAdd");
  await page.getByRole("textbox", { name: "Search link targets" }).fill("Project");
  await peer.evaluate(async company => {
    await new Promise((resolve, reject) => NRCTransactions.sendCreateLinkedAsset(currentRoomId, 9,
      '{"version":1,"title":"Markus Wolf","role":"Engineering"}', "", BigInt(company), { onSuccess: resolve, onError: reject }));
  }, ids.company);
  await page.waitForFunction(() => [...NRCAssets.roomAssets.get(0n).values()].some(a => a.assetType === 9 && a.preview.includes("Markus")));
  assert.equal(await page.evaluate(() => NRCLinksUI.isPickerVisible()), true);
  assert.equal(await page.getByRole("textbox", { name: "Search link targets" }).inputValue(), "Project");
  assert.equal(await page.getByRole("textbox", { name: "Search link targets" }).evaluate(el => document.activeElement === el), true);
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => document.querySelectorAll(".customer-contact").length === 2);
  await page.click(`#customerWork [data-target="${ids.note}"]`);
  await page.waitForFunction(() => NRCInspector.current()?.type === "note" && document.getElementById("noteLinksList")?.textContent.includes("Company 00"));

  // A committed create whose result is lost must not invite a second Create.
  await page.click("#customerActivityNew");
  await page.fill('[name="title"]', "Committed without acknowledgement");
  await page.fill('[name="body"]', "Retain this draft until reconnection confirms the result.");
  await page.evaluate(() => {
    const handler = NRCTransactions.handleTransactionApplied;
    NRCTransactions.handleTransactionApplied = () => { NRCTransactions.handleTransactionApplied = handler; ws.close(); };
  });
  await page.click("#customerSave");
  await page.waitForFunction(() => document.getElementById("customerEditorError").textContent.includes("Connection lost"));
  assert.equal(await page.locator("#customerSave").isDisabled(), true);
  assert.equal(await page.inputValue('[name="title"]'), "Committed without acknowledgement");
  await page.click("#customerCancel");
  await page.getByRole("button", { name: "Discard", exact: true }).click();
  // Delete an edge at the peer while the first client's cache is offline.
  await peer.evaluate(edge => new Promise((resolve, reject) => NRCEdges.sendDeleteEdge(currentRoomId, BigInt(edge), { onSuccess: resolve, onError: reject })), ids.edge);
  await page.evaluate(() => manualReconnect());
  await page.waitForFunction(() => serverReady && !document.getElementById("customerNew").disabled);
  await page.waitForFunction(() => document.getElementById("customerRecord").textContent.includes("Committed without acknowledgement"));
  const cache = await page.evaluate(({ note, edge }) => ({
    edgePresent: !!NRCEdges.getEdge(0n, BigInt(edge)),
    reversePresent: NRCEdges.getEdgesForEntity(0n, 1, BigInt(note)).some(e => e.edgeId === BigInt(edge)),
    committedCount: [...NRCAssets.roomAssets.get(0n).values()].filter(a => a.assetType === 10 && a.preview.includes("Committed without acknowledgement")).length,
  }), ids);
  assert.deepEqual(cache, { edgePresent: false, reversePresent: false, committedCount: 1 });
  assert.equal(await page.evaluate(() => NRCInspector.current()?.type), "note", "inspector stays open during reconciliation");
  assert.equal(await page.locator("#noteLinksList .note-link-item").count(), 0, "open inspector refreshes removed edge DOM");
  await page.evaluate(() => NRCInspector.close());
  await peer.close();

  const capture = async name => {
    if (!process.env.NRC_CUSTOMERS_SCREENSHOTS) return;
    await fs.mkdir(process.env.NRC_CUSTOMERS_SCREENSHOTS, { recursive: true });
    await page.screenshot({ path: `${process.env.NRC_CUSTOMERS_SCREENSHOTS}/${name}.png`, fullPage: true });
  };
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.setAttribute("data-theme", theme), theme);
    await capture(`review-${theme}`);
  }
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.locator("#customersState").isVisible(), true);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await capture("review-mobile");
  // The stacked register exposes the paging sentinel when switching to mobile.
  // Let automatic pagination settle before Playwright waits on row stability.
  await page.waitForFunction(() => document.querySelectorAll(".customer-row").length === 40 && !document.getElementById("customerNew").disabled);
  await page.locator(".customer-footnote").scrollIntoViewIfNeeded();
  const footnote = await page.locator(".customer-footnote").boundingBox();
  const nav = await page.locator(".mobile-bottom").boundingBox();
  assert.ok(footnote.y >= 0 && footnote.y + footnote.height <= nav.y, "all history content scrolls above mobile navigation");
  await capture("review-mobile-history");
  assert.deepEqual(errors, []);
  console.log("PASS customer arrow navigation, delayed page continuation without duplicate requests, search/editor key isolation, desktop/mobile automatic pagination in both themes, >128KiB register, delayed ACK/locked draft, dirty cancel, live picker/focus, committed lost ACK, shared edge reconciliation, and mobile headers");
} finally {
  await browser.close();
}
