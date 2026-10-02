// node client/attention.e2e.mjs (optional NRC_CLIENT_URL override)
//
// The ATTENTION register derives its rows from a headless task query, the
// reminder snapshot and a headless read of the slice listing. This fixture answers
// the frames the client sends through the real receive path, so the dispatcher, the
// count queries, the slice walk, the rendering and the jump targets are all
// exercised together.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch();
try {
  const context = await browser.newContext({ serviceWorkers: "block", deviceScaleFactor: 2, locale: "en-US", timezoneId: "Europe/Berlin" });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.routeWebSocket("**/*", (socket) => socket.onMessage(() => {}));
  if (!process.env.NRC_CLIENT_URL) {
    await page.route("http://localhost/**", async route => {
      const path = new URL(route.request().url()).pathname;
      try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
      catch { await route.fulfill({ status: 404, body: "Not found" }); }
    });
  }
  await page.goto(process.env.NRC_CLIENT_URL || "http://localhost/");
  await page.waitForFunction(() => window.NRCAttention && window.NRCTasks && window.NRCSlices);

  await page.evaluate(() => {
    serverReady = true;
    myNickname = "rene";
    currentWorkspaceId = "workspace-attention";

    const DAY = 24 * 60 * 60 * 1000;
    const stamp = BigInt(Date.now()) * 1000000n;
    const nanos = (offsetMs) => BigInt(Date.now() + offsetMs) * 1000000n;

    // ---- the fixture server -------------------------------------------------
    const encoder = new TextEncoder();
    const text = (view, offset, value) => {
      const bytes = encoder.encode(value);
      view.setUint16(offset, bytes.length, false);
      new Uint8Array(view.buffer, offset + 2, bytes.length).set(bytes);
      return offset + 2 + bytes.length;
    };
    const taskFrame = (view, offset, task) => {
      view.setBigUint64(offset, BigInt(task.id), false); offset += 8;
      view.setBigUint64(offset, 0n, false); offset += 8;
      offset = text(view, offset, task.title);
      offset = text(view, offset, "");
      view.setUint8(offset++, task.status);
      view.setUint16(offset, 0, false); offset += 2;
      offset = text(view, offset, task.assignee);
      view.setUint8(offset++, 128);
      view.setUint8(offset++, 0);
      offset = text(view, offset, task.createdBy);
      view.setBigInt64(offset, task.createdAt, false); offset += 8;
      view.setBigInt64(offset, task.updatedAt, false); offset += 8;
      offset = text(view, offset, "");
      view.setBigInt64(offset, task.dueAt, false); offset += 8;
      view.setBigUint64(offset, BigInt(task.blockedBy), false); offset += 8;
      view.setBigInt64(offset, 0n, false); offset += 8;
      offset = text(view, offset, "");
      offset = text(view, offset, task.project ?? "");
      view.setUint16(offset, 0, false); offset += 2;
      return offset;
    };
    const sendTaskPage = (correlationId, tasks, total, hasMore = false) => {
      const size = 2 + 8 + 1 + 2 + tasks.length * 256 + 1 + 8 + 8 + 2 + 4 + 2 + 4;
      const bytes = new Uint8Array(size);
      const view = new DataView(bytes.buffer);
      view.setUint16(0, 138, false);
      view.setBigUint64(2, 0n, false);
      view.setUint8(10, 1);
      view.setUint16(11, tasks.length, false);
      let offset = 13;
      for (const task of tasks) offset = taskFrame(view, offset, task);
      // A page that leaves more rows behind carries the cursor the next request
      // asks from; the fixture only has to prove the walk follows it.
      view.setUint8(offset++, hasMore ? 1 : 0);
      view.setBigInt64(offset, hasMore ? stamp : 0n, false); offset += 8;
      view.setBigUint64(offset, hasMore ? BigInt(tasks.at(-1).id) : 0n, false); offset += 8;
      view.setUint16(offset, 0, false); offset += 2;
      view.setUint32(offset, total, false); offset += 4;
      view.setUint16(offset, 0, false); offset += 2;
      view.setUint32(offset, correlationId, false);
      handleBinaryMessage(bytes.buffer.slice(0, offset + 4));
    };

    // Two of the three tasks carry a project label, the third does not. The
    // server treats a query with a project flag as "this exact project", so a
    // register that sends an empty project instead of no project filter would
    // only ever see the one task without a label.
    const mine = [
      { id: 11n, title: "Fix shard handoff stall on resume", status: 2, assignee: "rene", createdBy: "mara",
        createdAt: stamp - BigInt(9 * DAY) * 1000000n, updatedAt: stamp - BigInt(2 * 60 * 60 * 1000) * 1000000n,
        dueAt: 0n, blockedBy: 412n, project: "MIGRATION" },
      { id: 12n, title: "Write migration note for WAL v3", status: 1, assignee: "rene", createdBy: "mara",
        createdAt: stamp - BigInt(12 * DAY) * 1000000n, updatedAt: stamp - BigInt(3 * DAY) * 1000000n,
        dueAt: nanos(-3 * DAY), blockedBy: 0n, project: "MIGRATION" },
      { id: 13n, title: "Rotate S3 key (prod)", status: 1, assignee: "rene", createdBy: "tobias",
        createdAt: stamp - BigInt(2 * DAY) * 1000000n, updatedAt: stamp - BigInt(20 * 60 * 1000) * 1000000n,
        dueAt: 0n, blockedBy: 0n, project: "" },
      { id: 14n, title: "Approve rollout window", status: 1, assignee: "rene", createdBy: "mara",
        createdAt: stamp - BigInt(4 * DAY) * 1000000n, updatedAt: stamp - BigInt(60 * 60 * 1000) * 1000000n,
        dueAt: 0n, blockedBy: 0n, project: "MIGRATION" },
      { id: 15n, title: "Publish overdue blocked release note", status: 1, assignee: "rene", createdBy: "mara",
        createdAt: stamp - BigInt(6 * DAY) * 1000000n, updatedAt: stamp - BigInt(DAY) * 1000000n,
        dueAt: nanos(-DAY), blockedBy: 14n, project: "MIGRATION" },
    ];
    // The blocked query is deliberately all-assignee and paginated. It supplies
    // direct dependents for actionable prerequisites, not additional rows.
    const dependencies = [
      mine[0], mine[4],
      { id: 21n, title: "Deploy worker image", status: 1, assignee: "alex", createdBy: "rene",
        createdAt: stamp, updatedAt: stamp, dueAt: 0n, blockedBy: 12n, project: "MIGRATION" },
      { id: 22n, title: "Notify support", status: 1, assignee: "mara", createdBy: "rene",
        createdAt: stamp, updatedAt: stamp, dueAt: 0n, blockedBy: 14n, project: "MIGRATION" },
    ];
    // The project flag sits after the assignee, whose length is a u16 at offset
    // 26, and the correlation id is last.
    const readProjectFilter = (frame) => {
      const assigneeLength = frame.getUint16(26, false);
      let offset = 28 + assigneeLength;
      const hasProject = frame.getUint8(offset) === 1; offset += 1;
      const projectLength = frame.getUint16(offset, false); offset += 2;
      const project = new TextDecoder().decode(new Uint8Array(frame.buffer, offset, projectLength));
      offset += projectLength;
      return { hasProject, project, hasCursor: frame.getUint8(offset) === 1 };
    };
    // ---- the slice listing ------------------------------------------------
    // The read is answered over the wire like the task query: the owner filter is
    // applied here, the way the server applies it, so the register folds the answer
    // instead of the window the slice register has scrolled to.
    const slices = [
      { name: "Q4 customer migration", sliceId: 5n, owner: "rene", flags: 0, backlog: 0, todo: 8, inProgress: 3,
        done: 2, blocked: 3, notes: 2, files: 1, lastMovedAt: stamp - BigInt(60 * 60 * 1000) * 1000000n },
      // Blocked, but neither mine nor assigned to anyone: the register watches
      // the operator's work, and a slice nobody owns is nobody's.
      { name: "Quiet slice", sliceId: 6n, owner: "mara", flags: 0, backlog: 1, todo: 0, inProgress: 0,
        done: 4, blocked: 2, notes: 0, files: 0, lastMovedAt: stamp },
      { name: "Unowned slice", sliceId: 7n, owner: "", flags: 0, backlog: 0, todo: 1, inProgress: 0,
        done: 0, blocked: 4, notes: 0, files: 0, lastMovedAt: stamp },
    ];
    window.sliceFixture = slices;
    window.sentSliceReads = [];
    const sendSliceList = (frame) => {
      const ownerLength = frame.getUint16(12, false);
      const owner = new TextDecoder().decode(new Uint8Array(frame.buffer, frame.byteOffset + 14, ownerLength));
      const hasOwner = frame.getUint8(11) === 1;
      let offset = 14 + ownerLength;
      const hasName = frame.getUint8(offset) === 1; offset += 1;
      const nameLength = frame.getUint16(offset, false); offset += 2;
      const name = new TextDecoder().decode(new Uint8Array(frame.buffer, frame.byteOffset + offset, nameLength));
      offset += nameLength;
      const limit = frame.getUint16(offset, false); offset += 2;
      const hasCursor = frame.getUint8(offset) === 1;
      const correlationId = frame.getUint32(frame.byteLength - 4, false);
      window.sentSliceReads.push({ hasOwner, owner, hasName, name, limit, hasCursor });
      const matching = window.sliceFixture.filter((slice) => (!hasOwner || slice.owner === owner) &&
        (!hasName || slice.name.toLowerCase().includes(name.toLowerCase())));
      const page = matching.slice(0, limit);
      let size = 2 + 8 + 1 + 2 + 1 + 1 + 8 + 8 + 4 + 4 + 4 + 2 + 4;
      for (const slice of page) size += 2 + slice.name.length + 8 + 2 + slice.owner.length + 1 + 14 + 16;
      const bytes = new Uint8Array(size);
      const view = new DataView(bytes.buffer);
      let at = 0;
      view.setUint16(at, 164, false); at += 2;
      view.setBigUint64(at, 0n, false); at += 8;
      view.setUint8(at++, 1);
      view.setUint16(at, page.length, false); at += 2;
      for (const slice of page) {
        at = text(view, at, slice.name);
        view.setBigUint64(at, slice.sliceId, false); at += 8;
        at = text(view, at, slice.owner);
        view.setUint8(at++, slice.flags);
        for (const value of [slice.backlog, slice.todo, slice.inProgress, slice.done, slice.blocked, slice.notes, slice.files]) {
          view.setUint16(at, value, false); at += 2;
        }
        view.setBigInt64(at, 0n, false); at += 8;
        view.setBigInt64(at, slice.lastMovedAt, false); at += 8;
      }
      view.setUint8(at++, 0);
      view.setUint8(at++, 0);
      view.setBigInt64(at, 0n, false); at += 8;
      view.setBigUint64(at, 0n, false); at += 8;
      view.setUint32(at, matching.length, false); at += 4;
      view.setUint32(at, 0, false); at += 4;
      view.setUint32(at, 0, false); at += 4;
      view.setUint16(at, 0, false); at += 2;
      view.setUint32(at, correlationId, false); at += 4;
      handleBinaryMessage(bytes.buffer.slice(0, at));
    };

    window.sentQueries = [];
    window.allQueries = [];
    ws = {
      readyState: WebSocket.OPEN,
      send(buffer) {
        const frame = new DataView(buffer);
        if (frame.getUint16(0, false) === 56) { sendSliceList(frame); return; }
        if (frame.getUint16(0, false) !== 28) return;
        const projectFilter = readProjectFilter(frame);
        window.allQueries.push(projectFilter);
        window.sentQueries.push({
          blocked: frame.getUint8(16),
          overdue: frame.getBigInt64(17, false) !== 0n,
          ...projectFilter,
          correlationId: frame.getUint32(frame.byteLength - 4, false),
        });
      },
    };
    // Answer every query the register sends, per filter, the way the server
    // would. The register asks one filter at a time, so the answers have to keep
    // arriving while it walks its three queries. A page is filtered by the
    // project flag it was asked for; the totals are the server's own numbers.
    window.answerEmpty = false;
    window.answerQueries = () => {
      for (const query of window.sentQueries.splice(0)) {
        const matching = query.hasProject ? mine.filter((task) => task.project === query.project) : mine;
        if (window.answerEmpty) sendTaskPage(query.correlationId, [], 0);
        else if (query.overdue) sendTaskPage(query.correlationId, [], 2);
        else if (query.blocked === 1 && !query.hasCursor) sendTaskPage(query.correlationId, dependencies.slice(0, 2), dependencies.length, true);
        else if (query.blocked === 1) sendTaskPage(query.correlationId, dependencies.slice(2), dependencies.length);
        // The row query is walked to its last page: the first answer leaves a
        // cursor behind, the second one ends the walk.
        else if (!query.hasCursor) sendTaskPage(query.correlationId, matching.slice(0, 3), matching.length, true);
        else sendTaskPage(query.correlationId, matching.slice(3), matching.length);
      }
    };
    window.autoAnswer = setInterval(() => window.answerQueries(), 20);

    // ---- the other two sources ---------------------------------------------
    const assets = new Map();
    for (const [id, title, offset] of [[1n, "Rotate customer contract draft", -DAY], [2n, "Quarterly access review", 2 * 60 * 60 * 1000]]) {
      assets.set(id, {
        assetId: id, convId: 0n, assetType: AssetType.Reminder, owner: "rene",
        createdAt: stamp, updatedAt: stamp, attachments: [],
        preview: JSON.stringify({ version: 1, title }),
        payload: JSON.stringify({ title, window_start_at: "0", deadline_at: String(nanos(offset)), urgency_days: 3 }),
      });
    }
    NRCAssets.roomAssets.set(0n, assets);

    // ---- chat: one unread mention and one plain message in room 3 ----------
    const newMessage = (roomId, text, seq, author) => {
      const authorBytes = encoder.encode(author), content = encoder.encode(text);
      const bytes = new Uint8Array(31 + authorBytes.length + content.length);
      const view = new DataView(bytes.buffer);
      view.setUint16(0, Opcode.S_NewMessage);
      view.setBigUint64(2, roomId, false);
      view.setBigUint64(10, BigInt(seq), false);
      view.setUint16(18, authorBytes.length, false);
      bytes.set(authorBytes, 20);
      let offset = 20 + authorBytes.length;
      view.setBigInt64(offset, BigInt(Date.now()) * 1000000n, false); offset += 8;
      view.setUint8(offset++, 0);
      view.setUint16(offset, content.length, false); offset += 2;
      bytes.set(content, offset);
      parseNewMessage(view);
    };
    currentRoomId = 2n;
    subscribedRooms.clear(); subscribedRooms.add(2n); subscribedRooms.add(3n);
    roomHistory.clear(); roomActivity.clear();
    retainedRoomStates.set(3n, "enabled");
    newMessage(3n, "Rotation is scheduled for Thursday.", 40, "tobias");
    newMessage(3n, "@rene can you confirm the key rotation window?", 41, "mara");
    window.pushMessage = newMessage;

    // The jump asks for one page before the target; answer it the way the
    // server would, with the target as the newest record.
    window.pageRequests = [];
    const originalSend = ws.send;
    ws.send = (buffer) => {
      const frame = new DataView(buffer);
      if (frame.getUint16(0, false) === 50) {
        window.pageRequests.push({ convId: frame.getBigUint64(2, false), cursor: frame.getBigUint64(10, false),
          correlationId: frame.getUint32(frame.byteLength - 4, false) });
        return;
      }
      originalSend(buffer);
    };
    window.answerPageRequest = ({ sequence, content, author, cutoff = 0n }) => {
      const request = window.pageRequests.shift();
      const authorBytes = encoder.encode(author), contentBytes = encoder.encode(content);
      const size = 43 + 32 + 2 + authorBytes.length + 8 + 1 + 2 + contentBytes.length;
      const bytes = new Uint8Array(size);
      const view = new DataView(bytes.buffer);
      view.setUint16(0, 159);
      view.setBigUint64(2, request.convId, false);
      view.setUint8(10, 0); view.setUint8(11, 0); view.setUint8(12, 0);
      view.setBigUint64(13, BigInt(sequence), false);
      view.setBigUint64(21, cutoff, false);
      view.setBigUint64(29, 0n, false);
      view.setUint32(37, request.correlationId, false);
      view.setUint16(41, 1, false);
      let offset = 43;
      view.setBigUint64(offset, request.convId, false); offset += 8;
      view.setBigUint64(offset, BigInt(sequence), false); offset += 8;
      offset += 16;
      view.setUint16(offset, authorBytes.length, false); offset += 2;
      bytes.set(authorBytes, offset); offset += authorBytes.length;
      view.setBigInt64(offset, BigInt(Date.now()) * 1000000n, false); offset += 8;
      view.setUint8(offset++, 0);
      view.setUint16(offset, contentBytes.length, false); offset += 2;
      bytes.set(contentBytes, offset);
      handleBinaryMessage(bytes.buffer.slice(0, size));
    };

    window.inspectorOpens = [];
    const openEntity = NRCInspector.openEntity.bind(NRCInspector);
    NRCInspector.openEntity = (ref) => { window.inspectorOpens.push(ref); return openEntity(ref); };
    window.sliceSelections = [];
    const select = NRCSlices.select;
    NRCSlices.select = (name, options) => { window.sliceSelections.push({ name, options }); return select(name, options); };
  });

  // A reload in another view must not hide what is waiting: the sidebar count is
  // derived without the register on screen. The app calls this when its session
  // is up, which the stubbed socket does not do on its own.
  await page.evaluate(() => {
    NRCViewManager.setActiveView("notes");
    window.NRCAttention.onSessionStarted();
  });
  await page.waitForFunction(() => document.getElementById("attentionViewCount").textContent === "07", null, { timeout: 10000 });
  assert.equal(await page.locator("#attentionPanel").isVisible(), false, "the count arrives without the register on screen");
  assert.equal(await page.evaluate(() => window.NRCAttention.getState().mode), "ready");

  // Entering the view runs the three count queries; the fixture answers them.
  await page.evaluate(() => { window.allQueries.length = 0; NRCViewManager.setActiveView("attention"); });
  await page.waitForFunction(() => window.NRCAttention.getState().mode === "ready", null, { timeout: 10000 });
  const queries = await page.evaluate(() => window.NRCAttention.getState().counts);
  assert.deepEqual({ ...queries }, { mine: 5, blocked: 2, overdue: 2 }, "blocked counts are folded from the all-assignee query");

  const rows = page.locator("#attentionBody .attention-row");
  await rows.first().waitFor();
  // Every open task assigned to me is a row, whatever project it carries, and
  // the register asks for all projects instead of filtering on an empty one.
  const taskTitles = (await page.locator('#attentionBody .attention-row[data-kind="task"] .attention-title').allTextContents()).sort();
  assert.deepEqual(taskTitles, ["Approve rollout window", "Publish overdue blocked release note", "Rotate S3 key (prod)", "Write migration note for WAL v3"],
    "ordinary blocked work is excluded while actionable and overdue-waiting work remains");
  assert.deepEqual(await page.evaluate(() => window.allQueries.map((query) => [query.hasProject, query.hasCursor])),
    [[false, false], [false, true], [false, false], [false, true], [false, false]],
    "both own work and all-assignee blocked dependencies are fully paginated");
  // Blocked slices are work context, not actionable task rows.
  assert.equal(await page.locator('#attentionBody .attention-row[data-kind="slice"]').count(), 0);
  assert.equal(await rows.count(), 7, "four actionable tasks, two due reminders and an unread mention");
  const kinds = (await rows.locator(".note-link-kind").allTextContents()).sort();
  assert.deepEqual(kinds, ["MENTION", "REMINDER", "REMINDER", "TASK", "TASK", "TASK", "TASK"]);
  const chips = (await rows.locator(".attention-state").allTextContents()).sort();
  assert.deepEqual(chips, ["@ YOU", "DUE", "LATE", "MINE", "OVERDUE", "UNBLOCKS", "WAITING"]);
  // The order itself is pinned by the unit cases; here the integration matters.
  assert.equal(await rows.first().locator(".note-link-kind").textContent(), "TASK", "the most urgent row leads");
  await page.waitForFunction(() => document.getElementById("attentionCount")?.textContent === "7 ITEMS · BY REASON");
  assert.deepEqual(await page.locator("#attentionBody .attention-group-heading").allTextContents(), [
    "OVERDUE / MY WORK1 ITEM", "OVERDUE / WAITING1 ITEM", "UNBLOCKS / MY WORK1 ITEM", "ASSIGNED TO ME1 ITEM",
    "DUE REMINDERS / WORKSPACE2 ITEMS", "MENTIONED / SESSION1 ITEM",
  ]);
  assert.equal(await page.locator("#attentionMessageCount").textContent(), "1");
  assert.equal(await page.locator("#attentionMineCount").textContent(), "5");
  assert.equal(await page.locator("#attentionBlockedCount").textContent(), "2");
  assert.equal(await page.locator("#attentionOverdueCount").textContent(), "2");
  assert.equal(await page.locator("#attentionViewCount").textContent(), "07");
  assert.equal(await page.locator("#attentionViewCount").isVisible(), true, "the sidebar entry carries the count");

  // The kind filter narrows the register without changing the source.
  await page.locator('[data-attention-filter="reminder"]').click();
  assert.equal(await rows.count(), 2);
  assert.deepEqual(await rows.locator(".note-link-kind").allTextContents(), ["REMINDER", "REMINDER"]);
  assert.deepEqual(await page.locator("#attentionBody .attention-group-heading").allTextContents(), ["DUE REMINDERS / WORKSPACE2 ITEMS"]);
  await page.locator('[data-attention-filter="message"]').click();
  assert.equal(await rows.count(), 1);
  await page.locator('[data-attention-filter="all"]').click();
  assert.equal(await rows.count(), 7);

  // Dependency disclosure uses direct open dependents across assignees, and
  // every disclosed task (plus a waiting row's prerequisite) opens by ID.
  const unblocks = page.locator('[data-attention-key="TASK:14"] + .attention-dependents');
  const toggle = page.locator('[data-attention-key="TASK:14"] [data-attention-toggle]');
  await page.waitForFunction(() => document.querySelector('[data-attention-key="TASK:14"] [data-attention-toggle]')?.textContent === "▸ UNBLOCKS 2 TASKS");
  assert.equal(await unblocks.isVisible(), false);
  assert.equal(await toggle.getAttribute("aria-expanded"), "false");
  assert.deepEqual(await unblocks.locator("button").allTextContents(), [
    "#15 · Publish overdue blocked release note · rene", "#22 · Notify support · mara",
  ]);
  await page.evaluate(() => window.inspectorOpens.length = 0);
  await toggle.focus();
  await page.keyboard.press("Enter");
  assert.equal(await unblocks.isVisible(), true);
  assert.equal(await toggle.getAttribute("aria-expanded"), "true");
  assert.deepEqual(await page.evaluate(() => window.inspectorOpens), [], "disclosure does not open its task");
  await page.evaluate(() => NRCAttention.render());
  assert.equal(await unblocks.isVisible(), true, "refresh preserves expansion");
  await toggle.press("Space");
  assert.equal(await unblocks.isVisible(), false);
  await toggle.click();
  await unblocks.locator('[data-attention-task="22"]').click();
  const waiting = page.locator('[data-attention-key="TASK:15"]');
  assert.equal(await waiting.locator('[data-attention-task="14"]').textContent(), "WAITING ON #14");
  await waiting.locator('[data-attention-task="14"]').click();
  assert.deepEqual(await page.evaluate(() => window.inspectorOpens.map(ref => String(ref.id))), ["22", "14"]);

  // The register is a list: the arrows walk its rows, stop at the ends and leave
  // the focus on the row opener, so the row's shared focus outline follows and
  // Enter keeps activating what the cursor points at.
  const focusedRow = () => page.evaluate(() => {
    const row = document.activeElement?.closest?.(".attention-row") || null;
    return row ? { kind: row.dataset.kind, key: row.dataset.attentionKey,
      tag: document.activeElement.tagName, outlined: getComputedStyle(row).outlineStyle !== "none" } : null;
  });
  await page.evaluate(() => document.activeElement?.blur?.());
  assert.equal(await focusedRow(), null, "the list starts without a cursor");
  await page.keyboard.press("ArrowDown");
  assert.deepEqual(await focusedRow(), { kind: "task", key: "TASK:12", tag: "BUTTON", outlined: true },
    "the first key enters the list at its most urgent row");
  await page.keyboard.press("ArrowDown");
  assert.equal((await focusedRow()).key, "TASK:15", "keyboard navigation crosses the reason heading");
  await page.keyboard.press("ArrowUp");
  assert.equal((await focusedRow()).key, "TASK:12");
  await page.keyboard.press("ArrowUp");
  assert.equal((await focusedRow()).key, "TASK:12", "the walk stops at the first row instead of wrapping");

  // Jump targets: the inspector for tasks and reminders.
  await page.evaluate(() => window.inspectorOpens.length = 0);
  await page.locator('#attentionBody .attention-row[data-kind="task"]').first().locator(".attention-title").click();
  assert.deepEqual(await page.evaluate(() => window.inspectorOpens.map((ref) => [ref.type, String(ref.id)])), [["task", "12"]]);
  await page.evaluate(() => window.inspectorOpens.length = 0);
  await page.locator('#attentionBody .attention-row[data-kind="reminder"]').first().locator(".attention-title").click();
  assert.deepEqual(await page.evaluate(() => window.inspectorOpens.map((ref) => [ref.type, String(ref.id)])), [["reminder", "1"]]);
  // A mention row jumps into its room, asks for one page and flashes the target.
  await page.evaluate(() => NRCViewManager.setActiveView("attention"));
  await page.locator('[data-attention-filter="message"]').click();
  const messageRow = page.locator('#attentionBody .attention-row[data-kind="mention"]');
  await messageRow.waitFor();
  assert.equal(await messageRow.locator(".attention-jump").count(), 1, "the row says it can jump");
  assert.equal(await messageRow.locator(".attention-title").textContent(), "@rene can you confirm the key rotation window?");
  await messageRow.locator(".attention-title").click();
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "chat");
  assert.equal(await page.evaluate(() => String(currentRoomId)), "3");
  const pageRequest = await page.evaluate(() => {
    const request = window.pageRequests[0];
    return request ? { convId: String(request.convId), cursor: String(request.cursor) } : null;
  });
  assert.deepEqual(pageRequest, { convId: "3", cursor: "42" }, "one page, ending at the mention");

  await page.evaluate(() => window.answerPageRequest({
    sequence: 41, content: "@rene can you confirm the key rotation window?", author: "mara",
  }));
  await page.waitForFunction(() => document.querySelector('#logOutput [data-sequence="41"]')?.classList.contains("chat-target"));
  assert.equal(await page.locator('#logOutput [data-sequence="41"]').textContent().then((value) => value.includes("@rene can you confirm")), true,
    "the flashed row is the mention");
  await page.waitForFunction(() => !document.querySelector('#logOutput [data-sequence="41"]')?.classList.contains("chat-target"), null, { timeout: 5000 });

  // Enter activates the focused row exactly once: the opener button owns the
  // key, and a second handler would fetch the jump target page twice. The mention
  // above was read by the jump, so a second one makes the room unread again.
  await page.evaluate(() => {
    NRCViewManager.setActiveView("notes");
    window.pushMessage(3n, "@rene the key is rotated, please confirm", 42, "mara");
  });
  await page.waitForFunction(() => window.NRCAttention.getState().rows.some((row) => row.kind === "MENTION"),
    null, { timeout: 10000 });
  await page.evaluate(() => { window.pageRequests.length = 0; NRCViewManager.setActiveView("attention"); });
  await page.locator('[data-attention-filter="message"]').click();
  await messageRow.waitFor();
  // The cursor survives a refresh that lands while the register is on screen, so
  // the row keeps the focus and the key reaches it.
  let activated = false;
  for (let attempt = 0; attempt < 10 && !activated; attempt += 1) {
    await messageRow.locator(".attention-title").focus();
    await page.keyboard.press("Enter");
    activated = await page.evaluate(() => NRCViewManager.getActiveView() === "chat");
  }
  assert.equal(activated, true, "Enter activates the row the cursor stands on");
  assert.equal(await page.evaluate(() => window.pageRequests.length), 1, "one page request, not two");

  // Leaving the register hands the view back. The mention that was just read is
  // no longer unread, so its row cleared itself and the count followed the rows:
  // the register reports a condition, not a history.
  await page.evaluate(() => NRCViewManager.setActiveView("chat"));
  assert.equal(await page.locator("#attentionPanel").isVisible(), false);
  assert.equal(await page.locator("#attentionBtn").getAttribute("class").then((value) => value.includes("active")), false);
  await page.waitForFunction(() => window.NRCAttention.getState().rows.length === 6, null, { timeout: 10000 });
  assert.equal(await page.locator("#attentionViewCount").textContent(), "06");

  // With nothing to report the register says so and clears the sidebar count.
  await page.evaluate(() => {
    NRCAssets.roomAssets.set(0n, new Map());
    window.sliceFixture = [];
    roomActivity.clear();
    window.answerEmpty = true;
    NRCViewManager.setActiveView("chat");
    NRCViewManager.setActiveView("attention");
  });
  await page.waitForFunction(() => window.NRCAttention.getState().mode === "ready" && window.NRCAttention.getState().rows.length === 0,
    null, { timeout: 10000 });
  assert.equal((await page.locator("#attentionBody").textContent()).trim(), "NOTHING NEEDS ATTENTION");
  assert.equal(await page.locator("#attentionViewCount").isVisible(), false);

  assert.deepEqual(errors, [], "no page errors");
  console.log("attention e2e passed");
} finally {
  await browser.close();
}
