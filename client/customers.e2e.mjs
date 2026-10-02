// Run against test/customer-workspace-dev.mjs, never a shared server.
// NRC_CUSTOMERS_TEST_URL=http://127.0.0.1:8091 node client/customers.e2e.mjs
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error("Set NRC_CUSTOMERS_TEST_URL to the disposable customer fixture");
const browser = await chromium.launch();
const errors = [];
const workspace = `customers-e2e-${Date.now()}`;
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const page = await context.newPage();
  let socket;
  page.on("websocket", value => { socket = value; });
  const search = async query => {
    const response = socket.waitForEvent("framereceived", { predicate: event => Buffer.isBuffer(event.payload) && event.payload.readUInt16BE(0) === 163 });
    await page.fill("#customersSearch", query);
    await response;
    await page.waitForFunction(() => !document.getElementById("customerNew").disabled);
  };
  page.on("pageerror", error => errors.push(error.message));
  async function open(page) {
    await page.goto(`${url}/#workspace=${workspace}`);
    await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
    await page.click("#customersBtn");
    await page.waitForFunction(() => !document.getElementById("customerNew").disabled);
  }
  const save = async () => {
    await page.click("#customerSave");
    await page.waitForFunction(() => !document.getElementById("customerSave"));
    if (await page.locator("#customerClose").count()) await page.click("#customerClose");
    await page.waitForFunction(() => !document.getElementById("customerNew").disabled);
  };
  const capture = async name => {
    if (!process.env.NRC_CUSTOMERS_SCREENSHOTS) return;
    await fs.mkdir(process.env.NRC_CUSTOMERS_SCREENSHOTS, { recursive: true });
    const path = `${process.env.NRC_CUSTOMERS_SCREENSHOTS}/${name}.png`;
    if (name.startsWith("contact-") || name.startsWith("company-read-")) await page.locator("#inspector").screenshot({ path });
    else await page.screenshot({ path, fullPage: true });
  };
  const assertInspector = async () => {
    const theme = await page.locator("html").getAttribute("data-theme");
    for (const mode of ["light", "dark"]) {
      await page.locator("html").evaluate((el, value) => el.setAttribute("data-theme", value), mode);
      for (const viewport of [{ width: 1440, height: 1000 }, { width: 390, height: 844 }, { width: 844, height: 390 }]) {
        await page.setViewportSize(viewport);
        await page.evaluate(() => NRCInspector.openEntity(NRCInspector.current()));
        await page.waitForSelector("#customerForm");
        // The resize event removes the desktop inline width on the next frame.
        await page.waitForFunction(() => innerWidth >= 1200 || !document.getElementById("inspector").style.width);
        const box = await page.locator("#inspector").boundingBox();
        assert.ok(box && box.x >= 0 && box.y >= 0 && box.x + box.width <= viewport.width + 1 && box.y + box.height <= viewport.height + 1, `inspector fits viewport in ${mode}: ${JSON.stringify({ box, viewport })}`);
        assert.equal(await page.locator("dialog[open]").count(), 0, "customer assets use the shared inspector, not native dialogs");
        assert.equal(await page.locator("#inspectorEntityHost #customerForm").count(), 1);
        if (viewport.width < 1200) assert.equal(await page.locator("#inspector").getAttribute("aria-modal"), "true");
      }
    }
    await page.locator("html").evaluate((el, value) => value === null ? el.removeAttribute("data-theme") : el.setAttribute("data-theme", value), theme);
    await page.setViewportSize({ width: 1440, height: 1000 });
  };
  await open(page);
  assert.equal(await page.locator("#inspector").isHidden(), true, "customer record owns the width until an entity is opened");
  assert.equal(await page.locator(".customer-row").count(), 0);
  await capture("empty");
  await page.click("#customerNew");
  await assertInspector();
  await page.fill('[name="title"]', "Nordwerk GmbH");
  await page.fill('[name="number"]', "K-0012");
  await page.fill('[name="city"]', "Hamburg");
  await page.fill('[name="sector"]', "Maschinenbau");
  await page.fill('[name="address"]', "Werkstraße 18, Hamburg");
  await page.fill('[name="assignee"]', "rene");
  await capture("company-editor");
  await save();
  const companyId = await page.locator(".customer-row").getAttribute("data-company");
  await page.evaluate(id => NRCCustomers.openRecord("company", id), companyId);
  await page.waitForSelector(".company-facts");
  assert.equal(await page.locator(".company-facts dd").nth(5).textContent(), "—");
  await page.click("#customerEdit");
  const address = "Paulusstraße 5, 36037 Fulda, Deutschland / Verwaltungsgebäude, Eingang Hinterhof";
  await page.fill('[name="address"]', address);
  await page.fill('[name="website"]', "nordwerk.example/kontakt");
  await page.fill('[name="phone"]', "+49 661 87284");
  await save();
  await page.evaluate(id => NRCCustomers.openRecord("company", id), companyId);
  await page.waitForSelector(".company-facts");
  assert.equal(await page.locator('.company-facts a[href^="https:"]').getAttribute("href"), "https://nordwerk.example/kontakt");
  assert.equal(await page.locator('.company-facts a[href^="tel:"]').getAttribute("href"), "tel:+4966187284");
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  for (const [name, value] of [["address", address], ["website", "nordwerk.example/kontakt"], ["phone", "+49 661 87284"]]) {
    await page.click(`[data-copy-company="${name}"]`);
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), value);
  }
  for (const mode of ["light", "dark"]) {
    await page.locator("html").evaluate((el, value) => el.setAttribute("data-theme", value), mode);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(() => NRCInspector.openEntity(NRCInspector.current()));
      await page.waitForSelector(".company-facts");
      assert.equal(await page.locator(".company-facts dd").nth(4).textContent(), address);
      assert.equal(await page.locator(".customer-inspector-body").evaluate(el => el.scrollWidth <= el.clientWidth), true);
      assert.equal(await page.locator(".customer-inspector-body > :first-child").evaluate(el => el.tagName), "H2");
      await capture(`company-read-${mode}-${width}`);
    }
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.click("#customerEdit");
  await page.fill('[name="website"]', "javascript:alert(1)");
  await save();
  await page.evaluate(id => NRCCustomers.openRecord("company", id), companyId);
  await page.waitForSelector(".company-facts");
  assert.equal(await page.locator(".company-facts dd").nth(5).textContent(), "javascript:alert(1)");
  assert.equal(await page.locator(".company-facts dd").nth(5).locator("a").count(), 0);
  await page.click("#customerClose");
  await page.click("#customerContactNew");
  await assertInspector();
  await page.fill('[name="title"]', "Anna Berger");
  await page.fill('[name="email"]', "anna@nordwerk.example");
  await page.fill('[name="role"]', "Projektleitung");
  await save();
  const contactCard = page.locator(".customer-contact").first();
  assert.equal(await contactCard.evaluate(element => element.tagName), "BUTTON", "the entire contact card is interactive");
  await contactCard.focus();
  await page.keyboard.press("Enter");
  await page.waitForSelector("#customerForm");
  assert.equal(await contactCard.getAttribute("aria-pressed"), "true", "keyboard-opened contact is selected in the register");
  assert.equal(await contactCard.evaluate(el => getComputedStyle(el).display), "grid");
  await page.click("#customerClose");
  await page.waitForFunction(() => document.querySelector('.customer-contact')?.getAttribute('aria-pressed') === 'false');
  await page.click("#customerActivityNew");
  await assertInspector();
  await page.fill('[name="title"]', "Rollout abgestimmt <Freitag>");
  await page.fill('[name="body"]', "Anna bestätigt den Rollout.\nDokumentation vor dem nächsten Termin senden.");
  await save();
  assert.equal(await page.locator("#customerHistory strong").textContent(), "Rollout abgestimmt <Freitag>");
  assert.equal(await page.locator("#customerHistory freitag").count(), 0, "subject is text, not markup");
  await page.click("[data-activity]");
  await page.waitForSelector("#customerActivityBody");
  await assertInspector();
  assert.match(await page.locator("#customerActivityBody").textContent(), /Dokumentation vor/);
  await capture("activity-read");
  await page.click("#customerClose");
  await page.selectOption("#customerHistoryFilter", "Meeting", { force: true });
  assert.equal(await page.locator("[data-activity]:visible").count(), 0);
  await page.selectOption("#customerHistoryFilter", "Call", { force: true });
  assert.equal(await page.locator("[data-activity]:visible").count(), 1);

  // A second real WebSocket session observes acknowledged updates without reload.
  const peer = await context.newPage();
  await open(peer);
  await peer.click(`[data-company="${companyId}"]`);
  await page.click("#customerContactNew");
  await page.fill('[name="title"]', "Markus Wolf");
  await page.fill('[name="role"]', "Technische Leitung");
  await save();
  await peer.waitForFunction(() => document.querySelectorAll(".customer-contact").length === 2);
  await peer.close();

  // Create a real note and link it through the shared picker.
  await page.evaluate(() => new Promise((resolve, reject) => {
    NRCAssets.sendCreateAsset(currentRoomId, AssetType.Note, 0, 0n, JSON.stringify({ title: "Projektauftakt", project: "", tags: [] }), "# Entscheidungen\nEinführung in zwei Phasen.", 0, { onSuccess: resolve, onError: reject });
  }));
  await page.click(`[data-company="${companyId}"]`);
  await page.click("#customerLinkAdd");
  await page.locator(".note-link-picker:not(.hidden) .note-link-picker-item").filter({ hasText: "Projektauftakt" }).click();
  await page.waitForFunction(() => document.getElementById("customerWork").textContent.includes("Projektauftakt"));
  await page.click("#customerWork [data-target]");
  await page.waitForFunction(() => NRCInspector.hasEntity());
  await capture("linked-note");
  await page.evaluate(() => NRCInspector.close());

  await page.evaluate(() => new Promise((resolve, reject) => {
    NRCTasks.sendCreateTask(currentRoomId, "Unterlagen vorbereiten", "Aktuelle Unterlagen für die Abstimmung zusammenstellen.", 180, 0, "", 0n, [], 0, 0, "Kundenbetreuung", { onSuccess: resolve, onError: reject });
  }));
  await page.click("#customerLinkAdd");
  await page.click('.note-link-picker:not(.hidden) [data-kind="task"]');
  await page.locator(".note-link-picker:not(.hidden) .note-link-picker-item").filter({ hasText: "Unterlagen vorbereiten" }).click();
  await page.waitForFunction(() => document.getElementById("customerWork").textContent.includes("Unterlagen vorbereiten"));
  await page.click('#customerWork [data-target-type="2"]');
  await page.waitForFunction(() => NRCInspector.current()?.type === "task");
  await page.evaluate(() => NRCInspector.close());

  await page.reload();
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  await page.click("#customersBtn");
  await page.waitForSelector(`[data-company="${companyId}"]`);
  await page.click(`[data-company="${companyId}"]`);
  await page.waitForFunction(() => document.querySelectorAll(".customer-contact").length === 2);
  assert.equal(await page.locator("[data-activity]").count(), 1, "activity survives fresh client load");
  await page.click(".customer-identity [data-edit]");
  await page.fill('[name="city"]', "Hamburg-Altona");
  // Inject a rejected RPC without a server write, then retry through the real RPC.
  await page.evaluate(() => {
    const send = NRCAssets.sendUpdateAsset;
    NRCAssets.sendUpdateAsset = (...args) => {
      NRCAssets.sendUpdateAsset = send;
      queueMicrotask(() => args[6].onError({ message: "Test rejection" }));
      return 999;
    };
  });
  await page.click("#customerSave");
  await page.waitForFunction(() => document.getElementById("customerEditorError").textContent === "Test rejection");
  assert.equal(await page.inputValue('[name="city"]'), "Hamburg-Altona", "rejected save retains the draft");
  await capture("save-error");
  await save();
  assert.match(await page.locator(".customer-identity").textContent(), /Hamburg-Altona/);
  await search("Anna");
  assert.equal(await page.locator(".customer-row").count(), 1, "contact search finds company");
  await search("no-such-customer");
  assert.equal(await page.locator(".customer-row").count(), 0);
  await search("");
  await page.click("#customerArchive");
  await page.waitForFunction(() => document.getElementById("customerArchive").textContent === "RESTORE");
  await page.waitForFunction(() => document.querySelectorAll(".customer-row").length === 0);
  assert.equal(await page.locator(".customer-row").count(), 0);
  assert.equal(await page.locator(".customer-contact").count(), 2, "archive preserves contacts");
  assert.equal(await page.locator("[data-activity]").count(), 1, "archive preserves history");
  for (const id of ["customerContactNew", "customerActivityNew", "customerLinkAdd"]) {
    assert.equal(await page.locator(`#${id}`).isDisabled(), true, "archived company blocks new work in the UI");
  }
  await page.locator("label").filter({ has: page.locator("#customersArchived") }).click();
  assert.equal(await page.locator("#customersArchived").isChecked(), true);
  await page.waitForFunction(() => document.querySelectorAll(".customer-row").length === 1);
  assert.equal(await page.locator(".customer-row").count(), 1);
  await capture("archived");
  await page.click("#customerArchive");
  await page.waitForFunction(() => document.getElementById("customerArchive").textContent === "ARCHIVE");
  await page.evaluate(() => document.documentElement.setAttribute("data-theme", "light"));
  await capture("customers-light");
  await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"));
  await capture("customers-dark");
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await capture("customers-narrow");
  await page.locator("#customerLinkAdd").scrollIntoViewIfNeeded();
  const linkBox = await page.locator("#customerLinkAdd").boundingBox();
  const navBox = await page.locator(".mobile-bottom").boundingBox();
  assert.ok(linkBox.y >= 0 && linkBox.y + linkBox.height <= navBox.y, "linked work is reachable above mobile navigation");
  await capture("customers-narrow-work");
  await page.setViewportSize({ width: 1440, height: 1000 });

  await page.evaluate(() => { switchToRoom(3n); });
  await page.waitForFunction(() => !document.getElementById("customerNew").disabled);
  assert.equal(await page.locator(`[data-company="${companyId}"]`).count(), 1, "chat rooms share workspace customers");
  await page.evaluate(() => { switchToRoom(2n); });
  await page.waitForSelector(`[data-company="${companyId}"]`);
  await page.click(`[data-company="${companyId}"]`);
  await page.click("#customerActivityNew");
  await page.fill('[name="title"]', "Unsaved draft");
  await page.evaluate(() => ws.close());
  await page.waitForFunction(() => document.getElementById("customerEditorError").textContent.includes("Connection lost"));
  assert.equal(await page.inputValue('[name="title"]'), "Unsaved draft");
  assert.equal(await page.locator("#customerSave").isDisabled(), true);
  await capture("disconnected-draft");
  await page.click("#customerCancel");
  await page.getByRole("button", { name: "Discard", exact: true }).click();
  await page.evaluate(() => manualReconnect());
  await page.waitForFunction(() => serverReady && !document.getElementById("customerNew").disabled, null, { timeout: 20000 });

  // Associations are graph edges, never metadata. One contact can belong to
  // multiple companies, and unrelated edge kinds must not create membership.
  const ids = await page.evaluate(async companyId => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const company = BigInt(companyId);
    const assets = NRCAssets.roomAssets.get(0n);
    const contact = [...assets.values()].find(a => a.assetType === 9 && JSON.parse(a.preview).title === "Anna Berger");
    const activity = [...assets.values()].find(a => a.assetType === 10);
    for (const record of [contact, activity]) {
      if ("companyId" in JSON.parse(record.preview)) throw new Error("relationship leaked into metadata");
    }
    const graph = await rpc(options => NRCEdges.sendGraphQuery(currentRoomId, 1, company, 1, 0, 0, 0, options));
    if (![contact.assetId, activity.assetId].every(id => graph.nodes.some(n => n.type === 1 && n.id === id))) throw new Error("customer relationships missing from graph");
    const second = await rpc(options => NRCAssets.sendCreateAsset(currentRoomId, 8, 0, 0n, JSON.stringify({ version: 1, title: "Second company" }), "", 0, options));
    await rpc(options => NRCEdges.sendCreateEdge(currentRoomId, 1, contact.assetId, 1, second.asset.assetId, 7, options));
    await rpc(options => NRCEdges.sendCreateEdge(currentRoomId, 1, second.asset.assetId, 1, activity.assetId, 1, options));
    return { second: String(second.asset.assetId), contact: String(contact.assetId) };
  }, companyId);
  await page.click(`[data-company="${ids.second}"]`);
  await page.waitForFunction(() => document.querySelectorAll(".customer-contact").length === 1);
  assert.equal(await page.locator(".customer-contact strong").textContent(), "Anna Berger");
  assert.equal(await page.locator("[data-activity]").count(), 0, "References is not activity membership");
  await search("Anna");
  assert.equal(await page.locator(".customer-row").count(), 2, "edge-based search finds both companies");
  await search("");
  await page.click(`[data-company="${companyId}"]`);
  await page.waitForFunction(() => document.querySelectorAll(".customer-contact").length === 2);

  // A peer removes the original link while this client is disconnected. A full
  // edge snapshot must discard the cached relationship after reconnect.
  const editor = await context.newPage();
  await open(editor);
  await page.evaluate(() => ws.close());
  await page.waitForFunction(() => !serverReady);
  await editor.evaluate(async ({ companyId, contact }) => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const result = await rpc(options => NRCEdges.sendListEdges(currentRoomId, 1, BigInt(companyId), options));
    const edge = result.edges.find(e => e.relation === 7 && e.sourceId === BigInt(contact));
    await rpc(options => NRCEdges.sendDeleteEdge(currentRoomId, edge.edgeId, options));
  }, { companyId, contact: ids.contact });
  await page.evaluate(() => manualReconnect());
  await page.waitForFunction(() => serverReady && !document.getElementById("customerNew").disabled, null, { timeout: 20000 });
  await page.waitForFunction(() => document.querySelectorAll(".customer-contact").length === 1);
  assert.equal(await page.locator(".customer-contact strong").textContent(), "Markus Wolf");
  await search("Anna");
  assert.equal(await page.locator(".customer-row").count(), 1, "removed edge cannot survive reconnect in search");
  await search("");
  await editor.close();

  // Invalid company edge rejects the whole transaction: no orphan contact.
  const atomic = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    let rejected = false;
    try {
      await rpc(options => NRCTransactions.sendCreateLinkedAsset(currentRoomId, 9, JSON.stringify({ version: 1, title: "Must not exist" }), "", 18446744073709551615n, options));
    } catch { rejected = true; }
    const result = await rpc(options => NRCAssets.sendListAssets(currentRoomId, 9, false, options));
    return { rejected, orphan: result.assets.some(a => JSON.parse(a.preview).title === "Must not exist") };
  });
  assert.deepEqual(atomic, { rejected: true, orphan: false });

  // A shared contact can be unlinked from one company without deleting either
  // the contact or its other association. Membership is stored member -> company,
  // so the peer's removal above took the contact out of the first company and
  // this restores that one membership; the contact then carries one member-of
  // edge per company.
  await page.evaluate(({ companyId, contact }) => new Promise((resolve, reject) => {
    NRCEdges.sendCreateEdge(0n, 1, BigInt(contact), 1, BigInt(companyId), 7, { onSuccess: resolve, onError: reject });
  }), { companyId, contact: ids.contact });
  await page.click(`[data-company="${ids.second}"]`);
  // Force the contact's companies across page boundaries rather than relying
  // on the selected company's cache or the first edge page.
  await page.evaluate(contact => {
    const request = NRCEdges.requestEdgePage;
    NRCEdges.requestEdgePage = (room, type, id, options) => request(room, type, id, BigInt(id) === BigInt(contact) ? { ...options, limit: 1 } : options);
  }, ids.contact);
  await page.click(`[data-contact="${ids.contact}"]`);
  await page.waitForFunction(() => document.querySelectorAll("[data-unlink-company]").length === 2);
  assert.equal(await page.locator(".contact-facts dd").nth(2).textContent(), "—");
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.click('[data-copy-contact="email"]');
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), "anna@nordwerk.example");
  for (const mode of ["light", "dark"]) {
    await page.locator("html").evaluate((el, value) => el.setAttribute("data-theme", value), mode);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(() => NRCInspector.openEntity(NRCInspector.current()));
      await page.waitForFunction(() => document.querySelectorAll("[data-unlink-company]").length === 2);
      assert.equal(await page.locator(".customer-inspector-body").evaluate(el => el.scrollWidth <= el.clientWidth), true, "contact has no horizontal overflow");
      assert.equal(await page.locator("#contactCompanies").evaluate(el => getComputedStyle(el).borderLeftWidth), "0px", "linked companies has no outer box");
      assert.equal(await page.locator("#contactCompanies > .panel-header").evaluate(el => getComputedStyle(el).borderBottomWidth), "0px", "section header has only one rule");
      await capture(`contact-${mode}-${width}`);
    }
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.click("#customerEdit");
  await page.fill('[name="email"]', "anna.updated@nordwerk.example");
  await page.fill('[name="phone"]', "+49 5221 132206");
  await page.click("#customerClose");
  await page.locator(".nrc-dialog").getByRole("button", { name: "Cancel", exact: true }).click();
  assert.equal(await page.inputValue('[name="email"]'), "anna.updated@nordwerk.example", "cancelled close preserves draft");
  await save();
  await page.click(`[data-contact="${ids.contact}"]`);
  assert.match(await page.locator("#customerForm").textContent(), /anna.updated@nordwerk.example/);
  assert.equal(await page.locator('.contact-facts a[href^="tel:"]').getAttribute("href"), "tel:+495221132206");
  await page.click('[data-copy-contact="phone"]');
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), "+49 5221 132206");
  await page.waitForFunction(() => document.querySelectorAll("[data-unlink-company]").length === 2);
  await capture("contact-complete");
  await page.click(`[data-unlink-company="${ids.second}"]`);
  await page.getByRole("button", { name: "Remove link", exact: true }).click();
  await page.waitForFunction(() => document.querySelectorAll("[data-unlink-company]").length === 1);
  assert.equal(await page.locator(`[data-unlink-company="${companyId}"]`).count(), 1);
  // Link back through the inline picker, preserving unsaved contact fields.
  await page.click("#customerEdit");
  await page.fill('[name="role"]', "Unsaved role");
  await page.click("#contactLinkCompany");
  await page.waitForSelector(`[data-link-company="${ids.second}"]`);
  assert.equal(await page.locator(`[data-link-company="${companyId}"]`).count(), 0, "already linked company is excluded");
  await capture("contact-link-picker");
  await page.click(`[data-link-company="${ids.second}"]`);
  await page.waitForFunction(() => document.querySelectorAll("[data-unlink-company]").length === 2);
  assert.equal(await page.inputValue('[name="role"]'), "Unsaved role", "linking preserves draft");
  await page.click(`[data-unlink-company="${ids.second}"]`);
  await page.getByRole("button", { name: "Remove link", exact: true }).click();
  await page.waitForFunction(() => document.querySelectorAll("[data-unlink-company]").length === 1);
  assert.equal(await page.inputValue('[name="role"]'), "Unsaved role", "unlinking preserves draft");
  await page.click("#customerClose");
  await page.getByRole("button", { name: "Discard", exact: true }).click();
  await page.waitForFunction(() => document.querySelectorAll(".customer-contact").length === 0);
  await page.click(`[data-company="${companyId}"]`);
  await page.waitForSelector(`[data-contact="${ids.contact}"]`);
  await page.click(`[data-contact="${ids.contact}"]`);
  assert.match(await page.locator("#customerForm").textContent(), /anna.updated@nordwerk.example/, "unlink preserves saved record and other company link");

  // Delete is explicit and acknowledged; cancellation and rejection leave the
  // object inspectable. The real delete removes the asset and graph edges.
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => NRCInspector.openEntity(NRCInspector.current()));
  await page.click("#customerDelete");
  const confirmation = page.getByRole("dialog", { name: "DELETE RECORD", exact: true });
  assert.equal(await confirmation.getAttribute("aria-modal"), "true");
  assert.equal(await page.evaluate(() => document.activeElement.textContent), "Cancel", "destructive confirmation starts on safe action");
  await page.keyboard.press("Shift+Tab");
  assert.equal(await page.evaluate(() => document.activeElement.textContent), "Delete everywhere");
  await page.keyboard.press("Tab");
  assert.equal(await page.evaluate(() => document.activeElement.textContent), "Cancel", "focus stays in the confirmation above the inspector");
  await page.keyboard.press("Enter");
  await page.waitForSelector(".nrc-dialog-backdrop", { state: "detached" });
  assert.equal(await page.evaluate(() => document.activeElement.id), "customerDelete");
  await page.click("#customerDelete");
  await page.keyboard.press("Escape");
  assert.equal(await page.locator("#customerDelete").isVisible(), true);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.evaluate(() => {
    const send = NRCAssets.sendDeleteAsset;
    NRCAssets.sendDeleteAsset = (...args) => {
      NRCAssets.sendDeleteAsset = send;
      queueMicrotask(() => args[2].onError({ message: "Delete rejected" }));
      return 999;
    };
  });
  await page.click("#customerDelete");
  await page.getByRole("button", { name: "Delete everywhere", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("customerEditorError").textContent === "Delete rejected");
  assert.equal(await page.locator("#customerDelete").isEnabled(), true);
  await page.click("#customerDelete");
  await page.getByRole("button", { name: "Delete everywhere", exact: true }).click();
  await page.waitForFunction(() => !NRCInspector.hasEntity());
  const deleted = await page.evaluate(async id => {
    await NRCAssets.requestAllAssets(0n, 9);
    const edges = await NRCEdges.requestAllEdges(0n);
    return { asset: NRCAssets.roomAssets.get(0n).has(BigInt(id)), links: edges.edges.some(e => e.sourceType === 1 && e.sourceId === BigInt(id) || e.targetType === 1 && e.targetId === BigInt(id)) };
  }, ids.contact);
  assert.deepEqual(deleted, { asset: false, links: false });

  await page.click("[data-activity]");
  await page.click("#customerEdit");
  assert.match(await page.inputValue('[name="body"]'), /Dokumentation vor/, "editing loads the full activity payload");
  await page.fill('[name="body"]', "Revised decision\nSecond phase approved.");
  await page.selectOption('[name="kind"]', "Decision");
  await save();
  await page.selectOption("#customerHistoryFilter", "all", { force: true });
  await page.click("[data-activity]");
  assert.equal(await page.locator("#customerActivityBody").textContent(), "Revised decision\nSecond phase approved.");
  await page.click("#customerDelete");
  await page.getByRole("button", { name: "Delete everywhere", exact: true }).click();
  await page.waitForFunction(() => document.querySelectorAll("[data-activity]").length === 0);

  // A peer update must not overwrite a dirty inspector draft, and a peer delete
  // must remove the inspected object rather than leave a writable stale form.
  await page.click("[data-contact]");
  await page.click("#customerEdit");
  await page.fill('[name="role"]', "Unsaved local role");
  const contactId = await page.evaluate(() => String(NRCInspector.current().id));
  const remote = await context.newPage();
  await open(remote);
  await remote.evaluate(async id => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const { asset } = await rpc(options => NRCAssets.sendGetAsset(0n, BigInt(id), options));
    await rpc(options => NRCAssets.sendUpdateAsset(0n, asset.assetId, JSON.stringify({ ...JSON.parse(asset.preview), role: "Remote role" }), "", 9, 0, options));
  }, contactId);
  await page.waitForFunction(() => document.getElementById("customerEditorError").textContent.includes("changed elsewhere"));
  assert.equal(await page.inputValue('[name="role"]'), "Unsaved local role");
  assert.equal(await page.locator("#customerSave").isDisabled(), true);
  await page.click("#customerCancel");
  await page.getByRole("button", { name: "Discard", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("customerForm").textContent.includes("Remote role"));
  await remote.evaluate(id => new Promise((resolve, reject) => NRCAssets.sendDeleteAsset(0n, BigInt(id), { onSuccess: resolve, onError: reject })), contactId);
  await page.waitForFunction(() => !NRCInspector.hasEntity());
  await remote.close();
  await page.click("#customerNew");
  // Revoke the HTTP feature response: navigation and direct view entry fail closed.
  await page.route("**/api/features", route => route.fulfill({ json: { customers: false } }));
  await page.evaluate(() => NRCCustomers.refreshAccess());
  assert.equal(await page.locator("#customersBtn").isHidden(), true);
  await page.evaluate(() => NRCViewManager.setActiveView("customers"));
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat");
  assert.equal(await page.locator("#customerForm").count(), 0, "revocation closes the customer inspector");
  assert.deepEqual(errors, []);
  console.log("PASS customer inspector read/edit/create, guarded drafts, acknowledged delete, scoped unlink, peer conflict/delete, persistence, graph membership, reconnect, archive, feature revocation and responsive layout");
} finally {
  await browser.close();
}
