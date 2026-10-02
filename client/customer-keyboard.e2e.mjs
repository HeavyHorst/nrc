// Run only against test/customer-workspace-dev.mjs (disposable data).
import assert from "node:assert/strict";
import { chromium } from "playwright";

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error("Set NRC_CUSTOMERS_TEST_URL to the disposable fixture");
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`${url}/#workspace=customer-keyboard-${Date.now()}`);
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    for (let i = 0; i < 3; i++) {
      const result = await rpc(o => NRCAssets.sendCreateAsset(currentRoomId, 8, 0, 0n,
        JSON.stringify({ version: 1, title: `Company ${i}` }), "", 0, o));
      for (let j = 0; j < 3; j++) await rpc(o => NRCTransactions.sendCreateLinkedAsset(currentRoomId, 9,
        JSON.stringify({ version: 1, title: `Contact ${i}-${j}` }), "", result.asset.assetId, o));
    }
  });
  await page.click("#customersBtn");
  await page.waitForFunction(() => document.querySelectorAll(".customer-row").length === 3);
  await page.waitForFunction(() => document.querySelector("#customerRecord h2")?.textContent === "Company 0");
  const companies = page.locator(".customer-row");
  const contacts = page.locator(".customer-contact");
  const focused = async row => assert.equal(await row.evaluate(el => el === document.activeElement), true);
  const selectedCompany = () => page.locator('.customer-row[aria-pressed="true"]').getAttribute("data-company");
  assert.equal(await selectedCompany(), await companies.first().getAttribute("data-company"), "the first company is selected automatically");

  for (const theme of ["light", "dark"]) {
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.locator("html").evaluate((el, theme) => el.setAttribute("data-theme", theme), theme);
      await companies.first().click();
      await page.waitForFunction(() => !document.getElementById("customerRecord").inert && document.querySelectorAll(".customer-contact").length === 3);
      const firstId = await selectedCompany();
      // Tab focus and selected company can differ. Navigate from focus.
      await companies.nth(1).focus();
      await page.keyboard.press("ArrowDown");
      await focused(companies.nth(2));
      assert.equal(await selectedCompany(), await companies.nth(2).getAttribute("data-company"));
      await page.keyboard.press("ArrowDown");
      await focused(companies.nth(2));
      await page.keyboard.press("ArrowUp");
      await focused(companies.nth(1));
      await page.keyboard.press("ArrowUp");
      await focused(companies.first());
      await page.waitForFunction(() => !document.getElementById("customerRecord").inert && document.querySelectorAll(".customer-contact").length === 3);
      assert.equal(await selectedCompany(), firstId);
      await contacts.first().focus();
      await page.keyboard.press("ArrowUp");
      await focused(contacts.first());
      await page.keyboard.press("ArrowDown");
      await focused(contacts.nth(1));
      await page.keyboard.press("ArrowDown");
      await focused(contacts.nth(2));
      await page.keyboard.press("ArrowDown");
      await focused(contacts.nth(2));
      await page.keyboard.press("ArrowUp");
      await focused(contacts.nth(1));
      assert.equal(await selectedCompany(), firstId, "contact arrows never change the company");
      await page.keyboard.press("Enter");
      await page.waitForSelector("#customerForm");
      assert.equal(await contacts.nth(1).getAttribute("aria-pressed"), "true");
      const editedContact = await contacts.nth(2).getAttribute("data-contact");
      await page.evaluate(id => NRCCustomers.openRecord("contact", BigInt(id)), editedContact);
      await page.waitForSelector("#customerEdit");
      for (const cancel of ["Escape", "Cancel"]) {
        await page.click("#customerEdit");
        await page.locator('#customerFields [name="title"]').fill("Unsaved contact name");
        if (cancel === "Escape") await page.keyboard.press("Escape");
        else await page.click("#customerCancel");
        await page.locator(".nrc-dialog").getByRole("button", { name: "Cancel", exact: true }).click();
        assert.equal(await page.locator('#customerFields [name="title"]').inputValue(), "Unsaved contact name");
        await page.keyboard.press("Escape");
        await page.getByRole("button", { name: "Discard", exact: true }).click();
        await page.waitForSelector("#customerEdit");
        assert.deepEqual(await page.evaluate(() => ({ id: String(NRCInspector.current().id), subview: NRCInspector.current().subview })),
          { id: editedContact, subview: "read" }, "cancel editing stays on the current contact");
        assert.notEqual(await page.locator("#customerForm h2").textContent(), "Unsaved contact name");
      }
      await page.click("#customerEdit");
      await page.waitForSelector("#customerCancel");
      await page.keyboard.press("Escape");
      await page.waitForSelector("#customerEdit");
      assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), editedContact, "clean edit also stays on the current contact");
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => NRCInspector.current() === null);
      await page.evaluate(async id => {
        await NRCCustomers.openRecord("contact", BigInt(id));
        await NRCCustomers.openRecord("contact", 0n, { subview: "edit" });
      }, editedContact);
      await page.locator('#customerFields [name="title"]').fill("Uncreated contact");
      await page.keyboard.press("Escape");
      await page.getByRole("button", { name: "Discard", exact: true }).click();
      await page.waitForFunction(() => NRCInspector.current() === null);
      if (width === 1440) {
        await contacts.first().focus();
        await page.keyboard.press("ArrowDown");
        await focused(contacts.nth(1));
        await companies.first().focus();
        await page.keyboard.press("ArrowDown");
        await focused(companies.nth(1));
      }
      await page.locator("#customersSearch").focus();
      const before = await selectedCompany();
      await page.keyboard.press("ArrowDown");
      await focused(page.locator("#customersSearch"));
      assert.equal(await selectedCompany(), before);
    }
  }
  // Task and note editors use the same Escape contract, even with history.
  const editRefs = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const { task } = await rpc(o => NRCTasks.sendCreateTask(0n, "Escape task", "Original task body", 128, 0, "", 0n, [], 0, 0, "", o));
    const { asset } = await rpc(o => NRCAssets.sendCreateAsset(0n, 5, 0, 0n, '{"title":"Escape note"}', "Original note body", 0, o));
    return [{ type: "task", id: String(task.id), field: "#taskDetailDesc" }, { type: "note", id: String(asset.assetId), field: "#noteDetailContent" }];
  });
  for (const theme of ["light", "dark"]) {
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.locator("html").evaluate((el, theme) => el.setAttribute("data-theme", theme), theme);
      for (const ref of editRefs) {
        await page.evaluate(async ref => {
          await NRCInspector.openEntity({ type: "contact", id: BigInt(document.querySelector("[data-contact]").dataset.contact) });
          await NRCInspector.openEntity({ type: ref.type, id: BigInt(ref.id) });
        }, ref);
        const edit = page.locator('#inspectorHeader [data-inspector-command="e"]');
        await edit.click();
        const original = await page.locator(ref.field).inputValue();
        await page.locator(ref.field).fill("Unsaved edit");
        await page.keyboard.press("Escape");
        await page.locator(".nrc-dialog").getByRole("button", { name: "Cancel", exact: true }).click();
        assert.equal(await page.locator(ref.field).inputValue(), "Unsaved edit");
        await page.keyboard.press("Escape");
        await page.getByRole("button", { name: "Discard", exact: true }).click();
        await edit.waitFor();
        assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), ref.id);
        await edit.click();
        assert.equal(await page.locator(ref.field).inputValue(), original, "discard restores the original content");
        await page.keyboard.press("Escape");
        await edit.waitFor();
        assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), ref.id, "clean editor stays on the same record");
        await page.keyboard.press("Escape");
        await page.waitForFunction(() => NRCInspector.current() === null);
      }
    }
  }
  // Release exact reads individually: no partially hydrated company may appear,
  // and a superseded selection must not overwrite a newer one.
  await companies.first().click();
  await page.waitForFunction(() => !document.getElementById("customerRecord").inert);
  const original = await page.locator("#customerRecord").innerHTML();
  await page.evaluate(() => {
    const request = NRCAssets.requestAsset;
    window.heldCustomerReads = [];
    window.restoreCustomerReads = () => { NRCAssets.requestAsset = request; };
    NRCAssets.requestAsset = (room, id, options) => request(room, id, {
      ...options,
      onSuccess: result => window.heldCustomerReads.push(() => options.onSuccess(result)),
    });
  });
  await companies.nth(1).click();
  await page.waitForFunction(() => window.heldCustomerReads.length === 4);
  assert.equal(await page.locator("#customerRecord").innerHTML(), original);
  assert.equal(await page.locator("#customerRecord").getAttribute("aria-busy"), "true");
  assert.equal(await page.locator("#customerRecord").evaluate(el => el.inert), true);
  await page.evaluate(() => window.heldCustomerReads.shift()());
  assert.equal(await page.locator("#customerRecord").innerHTML(), original, "one response cannot publish partial details");
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => window.heldCustomerReads.length === 7);
  await page.evaluate(() => window.heldCustomerReads.splice(3).forEach(release => release()));
  await page.waitForFunction(() => !document.getElementById("customerRecord").inert);
  assert.equal(await page.locator("#customerRecord h2").textContent(), "Company 2");
  assert.deepEqual(await contacts.locator("strong").allTextContents(), ["Contact 2-0", "Contact 2-1", "Contact 2-2"]);
  const latest = await page.locator("#customerRecord").innerHTML();
  await page.evaluate(() => {
    window.heldCustomerReads.splice(0).forEach(release => release());
    window.restoreCustomerReads();
  });
  assert.equal(await page.locator("#customerRecord").innerHTML(), latest, "late responses cannot restore the previous selection");
  await page.evaluate(() => {
    const request = NRCEdges.requestEdgePage;
    NRCEdges.requestEdgePage = async () => { throw new Error("Test relationship failure"); };
    window.restoreCustomerEdges = () => { NRCEdges.requestEdgePage = request; };
  });
  await companies.first().click();
  await page.waitForFunction(() => document.getElementById("customersStatus").textContent === "Test relationship failure");
  assert.equal(await page.locator("#customerRecord").innerHTML(), latest, "failures preserve the last complete detail");
  assert.equal(await page.locator("#customerRecord").evaluate(el => el.inert), true);
  await page.evaluate(() => window.restoreCustomerEdges());
  await companies.first().click();
  await page.waitForFunction(() => !document.getElementById("customerRecord").inert);
  assert.equal(await page.locator("#customerRecord h2").textContent(), "Company 0");
  await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const { task } = await rpc(o => NRCTasks.sendCreateTask(0n, "Linked task ready", "", 128, 0, "", 0n, [], 0, 0, "", o));
    const company = BigInt(document.querySelectorAll("[data-company]")[2].dataset.company);
    await rpc(o => NRCEdges.sendCreateEdge(0n, 2, task.id, 1, company, 2, o));
    const request = NRCTasks.requestTask;
    NRCTasks.requestTask = (room, id, options) => request(room, id, {
      ...options, onSuccess: result => { window.releaseCustomerTask = () => options.onSuccess(result); },
    });
    window.restoreCustomerTasks = () => { NRCTasks.requestTask = request; };
  });
  const beforeTask = await page.locator("#customerRecord").innerHTML();
  await companies.nth(2).click();
  await page.waitForFunction(() => !!window.releaseCustomerTask);
  assert.equal(await page.locator("#customerRecord").innerHTML(), beforeTask, "task hydration also blocks publication");
  await page.evaluate(() => { window.restoreCustomerTasks(); window.releaseCustomerTask(); });
  await page.waitForFunction(() => !document.getElementById("customerRecord").inert);
  assert.equal(await page.locator("#customerRecord h2").textContent(), "Company 2");
  assert.match(await page.locator("#customerWork").textContent(), /Linked task ready/);
  assert.deepEqual(errors, []);
  console.log("Customer keyboard navigation and contact/task/note Escape behavior passed in both themes at desktop and mobile widths.");
} finally {
  await browser.close();
}
