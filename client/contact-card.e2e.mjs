// Run only against test/customer-workspace-dev.mjs (disposable real server).
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error("Set NRC_CUSTOMERS_TEST_URL to the disposable fixture");
const browser = await chromium.launch();
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, serviceWorkers: "block", permissions: ["clipboard-read", "clipboard-write"] });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`${url}/#workspace=contact-card-${Date.now()}`);
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  const ids = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const create = async (type, data) => (await rpc(o => NRCAssets.sendCreateAsset(0n, type, 0, 0n, JSON.stringify({ version: 1, ...data }), "", 0, o))).asset.assetId;
    const company = await create(8, { title: "Nordwerk GmbH" });
    const second = await create(8, { title: "Medienzentrum" });
    const contact = await create(9, { title: "Anna Berger", role: "Projektleitung", email: "anna@nordwerk.example", phone: "+49 30 123456", source: "Manual entry", review_status: "reviewed", service_for: [] });
    const empty = await create(9, { title: "Unassigned contact" });
    await rpc(o => NRCEdges.sendCreateEdge(0n, 1, contact, 1, company, NRCEdges.RelationType.MemberOf, o));
    return { company: String(company), second: String(second), contact: String(contact), empty: String(empty) };
  });
  const open = async id => {
    await page.evaluate(id => NRCCustomers.openRecord("contact", id), id);
    await page.waitForSelector(".contact-card");
    await page.waitForFunction(() => document.querySelector("#contactCompanies")?.getAttribute("aria-busy") === "false");
  };
  const capture = async name => {
    if (!process.env.NRC_CUSTOMERS_SCREENSHOTS) return;
    await fs.mkdir(process.env.NRC_CUSTOMERS_SCREENSHOTS, { recursive: true });
    await page.locator("#inspector").screenshot({ path: `${process.env.NRC_CUSTOMERS_SCREENSHOTS}/${name}.png` });
  };
  await open(ids.contact);
  assert.equal(await page.locator("#contactCardCompany").textContent(), "Nordwerk GmbH");
  assert.equal(await page.locator("#inspectorHeader #customerDelete").count(), 1);
  assert.equal(await page.locator("#customerForm #customerDelete, #customerForm [data-service-company]").count(), 0);
  assert.doesNotMatch(await page.locator("#customerForm").textContent(), /Manual entry|reviewed/);
  await page.locator("#inspectorHeader").getByRole("button", { name: "INFO", exact: true }).click();
  assert.match(await page.locator(".inspector-info:popover-open").textContent(), /Manual entry/);
  await page.keyboard.press("Escape");
  await page.locator('[data-copy-contact="email"]').click();
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), "anna@nordwerk.example");
  for (const theme of ["light", "dark"]) {
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await open(ids.contact);
      assert.equal(await page.locator(".customer-inspector-body").evaluate(el => el.scrollWidth <= el.clientWidth), true);
      await capture(`contact-${theme}-${width}`);
    }
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.evaluate(() => document.documentElement.dataset.theme = "light");
  await page.click("#customerEdit");
  await page.locator(`[data-service-company="${ids.company}"]`).check();
  await capture("contact-edit");
  await page.click("#customerSave");
  await page.waitForSelector(".contact-card");
  await page.waitForFunction(() => document.querySelector(".contact-company-service")?.textContent === "SERVICE INFORMATION / ENABLED");
  await page.evaluate(({ contact, second }) => new Promise((resolve, reject) => NRCEdges.sendCreateEdge(0n, 1, BigInt(contact), 1, BigInt(second), NRCEdges.RelationType.MemberOf, { onSuccess: resolve, onError: reject })), ids);
  await open(ids.contact);
  assert.equal(await page.locator("#contactCardCompany").isHidden(), true);
  assert.deepEqual((await page.locator(".contact-company-service").allTextContents()).sort(), ["SERVICE INFORMATION / ENABLED", "SERVICE INFORMATION / NOT ENABLED"]);
  await capture("contact-multiple");
  await open(ids.empty);
  assert.equal(await page.locator("#contactCardCompany").isHidden(), true);
  assert.equal(await page.locator(".contact-methods dd").allTextContents().then(values => values.join("")), "——");
  assert.match(await page.locator("#contactCompanies").textContent(), /No linked companies/);
  await capture("contact-empty");
  await page.click("#customerDelete");
  await page.locator(".nrc-dialog").getByRole("button", { name: "Cancel", exact: true }).click();
  assert.equal(await page.locator(".contact-card h2").textContent(), "Unassigned contact");
  assert.deepEqual(errors, []);
  console.log("PASS: contact card, header delete/cancel, provenance, clipboard, per-company service save, single/multiple/empty companies; light/dark at 1440/390 without overflow");
} finally {
  await browser.close();
}
