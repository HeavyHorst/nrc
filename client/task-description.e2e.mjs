// UTF-8 byte boundaries in the production task editor and request encoder.
// node client/task-description.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, locale: "en-US", serviceWorkers: "block" });
const errors = [];
page.on("pageerror", error => errors.push(error.message));
try {
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCInspector && window.NRCTasks);
  await page.evaluate(async () => {
    currentRoomId = 7n;
    currentWorkspaceId = "task-description";
    myNickname = "tester";
    serverReady = true;
    const task = { id: 469n, convId: 0n, title: "Task with image references", description: "",
      status: 1, priority: 128, color: 0, createdBy: "tester", createdAt: 1n, updatedAt: 1n,
      completedAt: 0n, attachments: [], assignee: "", project: "" };
    roomTasks.set(0n, new Map([[469n, task]]));
    NRCAssets.roomAssets.set(0n, new Map());
    NRCLinksUI.loadLinks = async () => {};
    window.__sends = [];
    ws.send = data => window.__sends.push(Array.from(new Uint8Array(data)));
    await NRCInspector.openEntity({ roomId: 0n, type: "task", id: 469n });
  });
  await page.locator("#taskDetailToggleFocus").click();
  const editor = page.locator("#taskDetailDesc");
  await editor.waitFor({ state: "visible" });
  assert.equal(await editor.getAttribute("maxlength"), "4096");
  for (const size of [2049, 4096, 4097]) {
    const description = "ä".repeat(Math.floor(size / 2)) + "x".repeat(size % 2);
    await editor.fill(description);
    assert.equal(await page.locator("#taskDetailDescStats").textContent(), `${size.toLocaleString("en-US")} / 4,096 BYTES`);
    const before = await page.evaluate(() => __sends.length);
    await page.locator("#taskDetailSave").click();
    assert.equal(await page.evaluate(() => __sends.length), before + (size <= 4096 ? 1 : 0));
    if (size <= 4096) {
      const sent = await page.evaluate(() => __sends.at(-1));
      // C_UpdateTask: opcode, conv_id, task_id, empty title, description length.
      const bytes = Uint8Array.from(sent);
      assert.equal(new DataView(bytes.buffer).getUint16(20), size);
      assert.equal(new TextDecoder().decode(bytes.slice(22, 22 + size)), description);
    }
  }
  for (const theme of ["white", "matte-black"]) {
    for (const width of [1600, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(async theme => {
        document.documentElement.dataset.theme = theme;
        taskDetailDirty = false; // Reset the fixture draft, then open the responsive drawer normally.
        await NRCInspector.openEntity({ roomId: 0n, type: "task", id: 469n });
      }, theme);
      await page.locator("#taskDetailToggleFocus").click();
      await editor.fill("ä".repeat(2048));
      assert.equal(await editor.isVisible(), true);
      assert.equal(await page.locator("#taskDetailDescStats").textContent(), "4,096 / 4,096 BYTES");
      if (process.env.NRC_DESCRIPTION_SCREENSHOTS) {
        await page.locator(".detail-edit-label-row").screenshot({ path: `${process.env.NRC_DESCRIPTION_SCREENSHOTS}/task-description-${theme}-${width}.png` });
      }
    }
  }
  assert.deepEqual(errors, []);
  console.log("PASS: task descriptions accept 2049/4096 UTF-8 bytes, reject 4097, and preserve request bytes");
} finally {
  await browser.close();
}
