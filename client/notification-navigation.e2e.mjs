// Real two-user broadcasts; only the operating-system Notification is replaced.
// Run against test/customer-workspace-dev.mjs, never a shared installation.
import assert from "node:assert/strict";
import { chromium } from "playwright";

const url = process.env.NRC_NOTIFICATION_TEST_URL;
if (!url) throw new Error("Set NRC_NOTIFICATION_TEST_URL to the disposable fixture");
assert.ok(["localhost", "127.0.0.1"].includes(new URL(url).hostname));
const browser = await chromium.launch();
try {
  const context = await browser.newContext({ serviceWorkers: "block", extraHTTPHeaders: { "x-nrc-test-user": "rene" } });
  await context.addInitScript(() => {
    window.notifications = [];
    window.Notification = class {
      static permission = "granted";
      constructor(title, options) { this.title = title; this.options = options; notifications.push(this); }
      close() { this.closed = true; }
    };
  });
  const other = await browser.newContext({ serviceWorkers: "block", extraHTTPHeaders: { "x-nrc-test-user": "alex" } });
  const page = await context.newPage(), author = await other.newPage();
  const errors = [];
  for (const p of [page, author]) p.on("pageerror", error => errors.push(error.message));
  const workspace = `notification-${Date.now()}`;
  await Promise.all([page.goto(`${url}/#workspace=${workspace}`), author.goto(`${url}/#workspace=${workspace}`)]);
  await page.waitForFunction(() => serverReady && myNickname === "rene");
  await author.waitForFunction(() => serverReady && myNickname === "alex");
  const id = await author.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const { task } = await rpc(o => NRCTasks.sendCreateTask(0n, "Review notification target", "Open this exact record.", 128, 0, "", 0n, [], 0, 0, "", o));
    await rpc(o => NRCTasks.sendUpdateTask(0n, task.id, task.title, task.description, task.status, "rene", task.priority, task.color, task.externalRef, task.dueAt, task.blockedBy, task.attachments, task.project, o));
    return String(task.id);
  });
  const clickNotification = async title => {
    await page.waitForFunction(title => notifications.some(n => n.title === title), title);
    await page.evaluate(title => notifications.findLast(n => n.title === title).onclick(), title);
    assert.equal(await page.evaluate(title => notifications.findLast(n => n.title === title).closed, title), true);
  };
  const expectTask = async () => {
    await page.waitForFunction(id => String(NRCInspector.current()?.id) === id && NRCInspector.current()?.type === "task", id);
    await page.locator("#inspectorEntityHost .task-detail-document").waitFor({ state: "visible" });
    assert.match(await page.textContent("#inspectorEntityHost"), /Open this exact record\./);
    assert.equal(new URL(page.url()).hash, `#/inspect/${workspace}/task/${id}`);
  };
  await clickNotification("Task Assigned");
  await expectTask();
  // Repeated clicks must reopen even though the URL has not changed.
  await page.evaluate(() => NRCInspector.close());
  await clickNotification("Task Assigned");
  await expectTask();
  // Rejecting a notification jump preserves both the draft and its URL.
  const draftId = await page.evaluate(async () => {
    const result = await new Promise((resolve, reject) => NRCTasks.sendCreateTask(0n, "Draft must survive", "Original draft", 128, 0, "", 0n, [], 0, 0, "", { onSuccess: resolve, onError: reject }));
    location.hash = `#/inspect/${currentWorkspaceId}/task/${result.task.id}`;
    return String(result.task.id);
  });
  await page.waitForFunction(id => String(NRCInspector.current()?.id) === id, draftId);
  await page.locator("#taskDetailToggleFocus").click();
  await page.locator("#taskDetailDesc").fill("Keep this unsaved draft");
  const draftHash = new URL(page.url()).hash;
  await page.evaluate(() => { void notifications.find(n => n.title === "Task Assigned").onclick(); });
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  assert.equal(new URL(page.url()).hash, draftHash);
  assert.equal(await page.evaluate(() => String(NRCInspector.current()?.id)), draftId);
  assert.equal(await page.locator("#taskDetailDesc").inputValue(), "Keep this unsaved draft");
  await page.evaluate(() => { void notifications.find(n => n.title === "Task Assigned").onclick(); });
  await page.getByRole("button", { name: "Discard", exact: true }).click();
  await expectTask();
  // A cold load of the copied URL must fetch the record without a warm cache.
  await page.reload();
  await page.waitForFunction(() => serverReady);
  await expectTask();
  await author.evaluate(async id => {
    const task = NRCTasks.roomTasks.get(0n).get(BigInt(id));
    await new Promise((resolve, reject) => NRCTasks.sendUpdateTask(0n, task.id, "Updated notification target", task.description, task.status, "rene", task.priority, task.color, task.externalRef, task.dueAt, task.blockedBy, task.attachments, task.project, { onSuccess: resolve, onError: reject }));
  }, id);
  await clickNotification("Task Updated");
  await expectTask();
  await author.evaluate(id => sendMoveTask(0n, BigInt(id), TaskStatus.Done), id);
  await clickNotification("Task Completed");
  await expectTask();
  await page.waitForFunction(() => currentDetailTask?.status === TaskStatus.Done);
  await author.evaluate(id => sendDeleteTask(0n, BigInt(id)), id);
  await clickNotification("Task Deleted");
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "kanban");
  await page.locator("#kanbanPanel").waitFor({ state: "visible" });
  await page.locator("#createTaskHeaderBtn").waitFor({ state: "visible" });
  await page.locator('[data-task-grouping="flat"]').click();
  await page.getByText("Draft must survive", { exact: true }).waitFor({ state: "visible" });

  const chatRoom = await author.evaluate(() => {
    sendBinaryMessage("Chat notification destination");
    return String(currentRoomId);
  });
  await page.waitForFunction(() => notifications.some(n => n.options.body === "Chat notification destination"));
  await page.evaluate(() => notifications.find(n => n.options.body === "Chat notification destination").onclick());
  await page.waitForFunction(room => String(currentRoomId) === room && NRCViewManager.getActiveView() === "chat", chatRoom);

  // Non-task record URLs use the same startup route and fetch their own detail.
  const ticketId = await author.evaluate(async () => {
    const result = await new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 13, 0, 0n,
      JSON.stringify({ version: 1, title: "Ticket deep-link target", company_id: "", contact_id: "", requester: "ada@example.test", requester_name: "Ada", status: "open", assignee: "rene" }),
      "Ticket destination body.", 0, { onSuccess: resolve, onError: error => reject(new Error(JSON.stringify(error))) }));
    return String(result.asset.assetId);
  });
  await page.goto(`${url}/#/inspect/${workspace}/ticket/${ticketId}`);
  await page.waitForFunction(() => serverReady);
  await page.locator("#ticketMetadata").waitFor({ state: "visible" });
  assert.equal(await page.evaluate(() => NRCInspector.current().type), "ticket");
  assert.match(await page.textContent("#inspectorEntityHost"), /Ticket deep-link target/);
  assert.deepEqual(errors, []);
  console.log("PASS: assignment/update/completion clicks, repeated click, dirty draft cancel/accept, cold deep link, visible deleted-task fallback, chat destination, ticket deep link");
} finally { await browser.close(); }
