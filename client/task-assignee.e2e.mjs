// Task detail assignee dropdown: it must survive the panel's own re-renders.
// The panel replaces its markup on every render while `.agenda-content`
// persists, so a dismissal handler bound per render keeps a reference to a
// detached input and closes the live dropdown on a click inside the field.
// node client/task-assignee.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, serviceWorkers: "block" });
const errors = [];
page.on("pageerror", error => errors.push(error.message));

const dropdown = () => page.locator(".inline-field-editor");
const dropdownVisible = () => dropdown().isVisible();
const options = () => dropdown().getByRole("option").allTextContents();
const assignee = page.locator(".inline-field-editor input");
const outside = page.locator("#inspectorHeader .header-text");

async function openTaskEdit(id) {
  await page.evaluate(async (taskId) => { await NRCInspector.openEntity({ roomId: 0n, type: "task", id: BigInt(taskId) }); }, id);
  await page.locator("#taskDetailToggleFocus").click();
  await page.locator('.agenda-content nrc-inline-field[data-control$="-assignee"] button').click();
  await assignee.waitFor({ state: "visible" });
}

try {
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.route("http://nrc.test/api/users", route => route.fulfill({ json: ["anna", "ben", "rene", "tester"] }));
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCAssets && window.NRCViewManager && window.NRCInspector);
  await page.evaluate(() => {
    currentRoomId = 7n;
    currentWorkspaceId = "task-assignee";
    myNickname = "tester";
    serverReady = true;
    const stamp = BigInt(Date.now()) * 1000000n;
    const tasks = new Map();
    for (const id of [6n, 7n]) {
      tasks.set(id, { id, convId: 0n, title: `Task ${id}`, description: "", status: 1, priority: 128,
        color: 0, createdBy: "anna", createdAt: stamp, updatedAt: stamp, completedAt: 0n, attachments: [], assignee: "", project: "" });
    }
    roomTasks.set(0n, tasks);
    NRCAssets.roomAssets.set(0n, new Map());
    NRCLinksUI.loadLinks = async () => {};
    taskListDirty = true;
    window.__sends = [];
    ws.send = () => { window.__sends.push(1); };
  });

  await openTaskEdit(6);
  await assignee.click();
  await page.waitForTimeout(250);
  assert.equal(await dropdownVisible(), true, "the dropdown stays open after focusing the assignee field");
  assert.deepEqual(await options(), ["— CLEAR", "anna", "ben", "rene", "tester"], "the directory from /api/users is listed");

  // A later render of the same panel must not leave a stale dismissal handler.
  await page.keyboard.press("Escape");
  await openTaskEdit(7);
  await assignee.click();
  await page.waitForTimeout(250);
  assert.equal(await dropdownVisible(), true, "the dropdown still opens after a later panel render");

  // The shared picker filters directory suggestions; text remains free-form.
  await assignee.fill("ben");
  assert.equal(await assignee.inputValue(), "ben");
  await outside.click();
  assert.equal(await dropdownVisible(), false, "a click outside cancels the field editor");
  await page.locator('.agenda-content nrc-inline-field[data-control$="-assignee"] button').click();
  await assignee.fill("re");
  await assignee.click();
  await page.waitForTimeout(100);
  assert.equal(await dropdownVisible(), true, "typing filters the list");
  assert.deepEqual(await options(), ["— CLEAR", "rene"], "the picker filters names and retains the clear action");
  await outside.click();
  await page.waitForTimeout(100);
  assert.equal(await dropdownVisible(), false, "a click outside the field closes the dropdown");

  // Panel-level keyboard handling is bound once: one save request per shortcut.
  await page.locator('.agenda-content nrc-inline-field[data-control$="-assignee"] button').click();
  await assignee.fill("tester");
  await page.waitForTimeout(100);
  await page.keyboard.press("Enter");
  await page.waitForTimeout(250);
  assert.equal(await page.evaluate(() => window.__sends.length), 1, "one save request per Enter");

  // Customer responsibility uses the same picker, while retaining the form's
  // explicit persistence boundary and stale/offline protection.
  await page.route("http://nrc.test/api/features", route => route.fulfill({ json: { customers: true } }));
  await page.reload();
  await page.waitForFunction(() => window.NRCCustomers?.isEnabled() && userDirectory().length === 4);
  await page.evaluate(async () => {
    serverReady = true;
    currentWorkspaceId = "person-forms";
    currentRoomId = 7n;
    window.company = { convId: 0n, assetId: 88n, assetType: 8, owner: "tester", createdAt: 1n, updatedAt: 1n,
      preview: JSON.stringify({ version: 1, title: "Example company", assignee: "" }), payload: "", attachments: [] };
    NRCAssets.roomAssets.set(0n, new Map([[88n, company]]));
    NRCAssets.requestAsset = (_room, _id, options) => { options.onSuccess({ asset: company }); return 1; };
    window.companyWrites = [];
    NRCAssets.sendUpdateAsset = (...args) => { companyWrites.push(args); return 1; };
    await NRCInspector.openEntity({ roomId: 0n, type: "company", id: 88n, subview: "edit" });
  });
  const responsible = () => page.getByRole("button", { name: /^Edit RESPONSIBLE:/ });
  for (const theme of ["white", "matte-black"]) {
    for (const width of [1600, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await page.evaluate(() => NRCInspector.openEntity(NRCInspector.current()));
      await responsible().click();
      assert.deepEqual(await options(), ["— CLEAR", "anna", "ben", "rene", "tester"]);
      if (process.env.NRC_PERSON_SCREENSHOTS) await dropdown().screenshot({ path: `${process.env.NRC_PERSON_SCREENSHOTS}/customer-responsible-${theme}-${width}.png` });
      await page.keyboard.press("Escape");
    }
  }
  await responsible().click();
  await assignee.fill("be");
  await dropdown().getByRole("option", { name: "ben", exact: true }).click();
  assert.equal(await page.locator('input[name="assignee"]').inputValue(), "ben");
  assert.equal(await responsible().textContent(), "ben");
  assert.equal(await page.locator("#inspectorHeader .detail-save-state").textContent(), "UNSAVED");
  assert.equal(await page.evaluate(() => companyWrites.length), 0, "selection does not persist before the form SAVE");
  await responsible().click();
  await assignee.fill("cancelled");
  await page.keyboard.press("Escape");
  assert.equal(await page.locator('input[name="assignee"]').inputValue(), "ben");
  await page.locator("#customerSave").click();
  assert.equal(await page.evaluate(() => JSON.parse(companyWrites[0][2]).assignee), "ben", "the existing form SAVE includes the chosen person");
  assert.equal(await responsible().isDisabled(), true, "a pending record save locks the person field");
  await page.evaluate(() => companyWrites[0].at(-1).onError({ message: "Test rejection" }));
  await page.waitForFunction(() => document.getElementById("customerEditorError")?.textContent === "Test rejection");
  await responsible().click();
  await page.evaluate(() => NRCCustomers.onDisconnect());
  await assignee.fill("must-not-save");
  await dropdown().getByRole("button", { name: "SAVE", exact: true }).click();
  assert.equal(await page.locator('input[name="assignee"]').inputValue(), "ben", "an editor opened before disconnect cannot mutate the now-locked form");
  assert.match(await dropdown().locator(".inline-field-state").textContent(), /RECORD CHANGED/);
  await page.keyboard.press("Escape");

  assert.deepEqual(errors, [], "no page errors");
  console.log("PASS: shared task/customer person picker, draft/save boundary, both themes and widths, and offline protection");
} finally {
  await browser.close();
}
