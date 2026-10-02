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

  assert.deepEqual(errors, [], "no page errors");
  console.log("PASS: task assignee picker survives panel re-renders, filtering, dismissal and Enter");
} finally {
  await browser.close();
}
