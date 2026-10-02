// The slice view's keyboard contract: the register and every member table are
// walked with the arrow keys, and the row that moves is the row that opens.
// Production scripts and CSS, with disposable browser-local fixtures.
// node client/slices-keyboard.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: "block" });
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
  await page.waitForFunction(() => window.NRCAssets && window.NRCViewManager && window.NRCSlices);

  // The fixture is browser-local: two slices that share members, so a walk that
  // leaks from one slice's record into another is visible, and the listing frame
  // answers the client's own request on the slice opcode.
  await page.evaluate(() => {
    const encoder = new TextEncoder();
    const bytes = (value) => encoder.encode(value ?? "");
    // Mirrors protocol/tasks.odin serializeTaskSliceList and the unit suite.
    function sliceListFrame({ correlationId, slices }) {
      const names = slices.map((slice) => bytes(slice.name));
      const owners = slices.map((slice) => bytes(slice.owner));
      let size = 2 + 8 + 1 + 2 + 1 + 1 + 8 + 8 + 4 + 4 + 4 + 2 + 4;
      slices.forEach((slice, index) => { size += 2 + names[index].length + 8 + 2 + owners[index].length + 1 + 14 + 16; });
      const buffer = new ArrayBuffer(size);
      const view = new DataView(buffer);
      let offset = 0;
      view.setUint16(offset, 164, false); offset += 2;
      view.setBigUint64(offset, 0n, false); offset += 8;
      view.setUint8(offset, 1); offset += 1;
      view.setUint16(offset, slices.length, false); offset += 2;
      slices.forEach((slice, index) => {
        view.setUint16(offset, names[index].length, false); offset += 2;
        new Uint8Array(buffer, offset, names[index].length).set(names[index]); offset += names[index].length;
        view.setBigUint64(offset, BigInt(slice.sliceId), false); offset += 8;
        view.setUint16(offset, owners[index].length, false); offset += 2;
        new Uint8Array(buffer, offset, owners[index].length).set(owners[index]); offset += owners[index].length;
        view.setUint8(offset, slice.flags ?? 0); offset += 1;
        view.setUint16(offset, slice.backlog ?? 0, false); offset += 2;
        view.setUint16(offset, slice.todo ?? 0, false); offset += 2;
        view.setUint16(offset, slice.inProgress ?? 0, false); offset += 2;
        view.setUint16(offset, slice.done ?? 0, false); offset += 2;
        view.setUint16(offset, slice.blocked ?? 0, false); offset += 2;
        view.setUint16(offset, slice.notes ?? 0, false); offset += 2;
        view.setUint16(offset, slice.files ?? 0, false); offset += 2;
        view.setBigInt64(offset, 0n, false); offset += 8;
        view.setBigInt64(offset, BigInt(Date.now()) * 1000000n, false); offset += 8;
      });
      // One page, and the fixture holds every slice it carries, so the listing
      // ends here and the cursor is zero.
      view.setUint8(offset, 0); offset += 1;
      view.setUint8(offset, 0); offset += 1;
      view.setBigInt64(offset, 0n, false); offset += 8;
      view.setBigUint64(offset, 0n, false); offset += 8;
      view.setUint32(offset, slices.length, false); offset += 4;
      view.setUint32(offset, 0, false); offset += 4;
      view.setUint32(offset, 0, false); offset += 4;
      view.setUint16(offset, 0, false); offset += 2;
      view.setUint32(offset, correlationId, false); offset += 4;
      if (offset !== size) throw new Error("the fixture frame does not fill its declared size");
      return new DataView(buffer);
    }

    const stamp = BigInt(Date.now()) * 1000000n;
    currentRoomId = 7n;
    currentWorkspaceId = "slice-keyboard";
    myNickname = "tester";
    serverReady = true;

    const assets = new Map();
    const tasks = new Map();
    for (const id of [5n, 6n]) {
      assets.set(id, { assetId: id, assetType: 11, preview: JSON.stringify({ version: 1, name: id === 5n ? "Alpha" : "Beta" }) });
    }
    for (const id of [1n, 2n, 3n]) {
      tasks.set(id, { id, convId: 0n, title: `Member task ${id}`, status: 1, priority: Number(id), color: 0, createdAt: stamp + id, attachments: [], assignee: "tester", project: "NRC" });
    }
    for (const id of [201n, 202n]) {
      assets.set(id, { assetId: id, convId: 0n, assetType: 5, owner: "tester", createdAt: stamp, updatedAt: stamp, preview: JSON.stringify({ title: `Member note ${id}` }), payload: "note", attachments: [] });
    }
    for (const id of [301n, 302n]) {
      assets.set(id, { assetId: id, convId: 0n, assetType: 3, owner: "tester", createdAt: stamp, updatedAt: stamp, preview: JSON.stringify({ title: `member-${id}.svg`, category: "Diagram", size: "1 KB" }), attachments: [] });
    }
    NRCAssets.roomAssets.set(0n, assets);
    roomTasks.set(0n, tasks);

    // Alpha carries tasks 1-3, notes 201-202 and files 301-302; Beta carries tasks
    // 2 and 3, the members Alpha's walk last opened.
    const membership = {
      5n: [[2, 1n], [2, 2n], [2, 3n], [1, 201n], [1, 202n], [1, 301n], [1, 302n]],
      6n: [[2, 2n], [2, 3n]],
    };
    let edgeId = 0n;
    const edges = [];
    for (const [sliceId, members] of Object.entries(membership)) {
      for (const [sourceType, sourceId] of members) {
        edges.push({ edgeId: ++edgeId, relation: 7, sourceType, sourceId, targetType: 1, targetId: BigInt(sliceId) });
      }
    }
    NRCEdges.getEdgesForEntity = (roomId, targetType, targetId) => edges.filter((edge) =>
      (edge.sourceType === targetType && edge.sourceId === targetId) ||
      (edge.targetType === targetType && edge.targetId === targetId));
    NRCEdges.requestEdgePage = () => Promise.resolve({});
    NRCTasks.requestTask = (convId, id, { onSuccess } = {}) => { onSuccess?.({ task: tasks.get(id) }); return 1; };
    const requestAsset = NRCAssets.requestAsset;
    NRCAssets.requestAsset = (convId, assetId, options) => {
      const asset = assets.get(assetId);
      if (asset) {
        if (assetId === window.delayedSliceAsset) {
          window.releaseSliceAsset = () => {
            window.delayedSliceAsset = null;
            window.releaseSliceAsset = null;
            options?.onSuccess?.({ asset });
          };
          return 1;
        }
        options?.onSuccess?.({ asset });
        return 1;
      }
      return requestAsset(convId, assetId, options);
    };

    const send = ws.send.bind(ws);
    ws.send = (buffer) => {
      const view = new DataView(buffer);
      if (view.getUint16(0, false) !== 56) { send(buffer); return; }
      const correlationId = view.getUint32(view.byteLength - 4, false);
      window.NRCSlices.handleSliceList(sliceListFrame({
        correlationId,
        slices: [
          { name: "Alpha", sliceId: 5n, owner: "tester", todo: 3, notes: 2, files: 2 },
          { name: "Beta", sliceId: 6n, owner: "tester", todo: 2 },
        ],
      }));
    };
    setTaskGrouping("slices");
    showKanban();
  });
  await page.waitForSelector('#sliceRecord .slice-member[data-member-task="1"]');
  await page.waitForFunction(() => document.querySelectorAll("#sliceRecord .slice-member").length === 7);

  assert.deepEqual(await page.locator("#sliceRecord .slice-facts dt").allTextContents(),
    ["TASKS", "OPEN", "BLOCKED", "DONE", "NOTES", "FILES", "OLDEST OPEN", "LAST MOVED"]);
  assert.equal(await page.locator("#sliceRecord .slice-identity").innerText().then(text => text.includes("OWNER")), false);
  assert.equal(await page.locator('#sliceRecord label[for="sliceOwner"]').textContent(), "OWNER");
  assert.equal(await page.locator('#sliceRecord label[for="sliceOutcome"]').textContent(), "OUTCOME");
  assert.equal(await page.locator("#sliceRecord .slice-record-shape .slice-mark").count(), 3);

  // A head is a grid of its own, so every label must still sit over the column
  // the rows below it fill: a label that drifts is a value read as another field.
  // This window's record pane is narrow and stacks its rows without a head, so
  // the check runs at the widths that draw one, middling and wide.
  for (const size of [{ width: 2000, height: 1200 }, { width: 2560, height: 1400 }]) {
    await page.setViewportSize(size);
    await page.waitForTimeout(150);
    const facts = await page.locator("#sliceRecord .slice-facts").evaluate(element => ({
      display: getComputedStyle(element).display,
      inlinePairs: Array.from(element.children).every(pair => {
        const label = pair.querySelector("dt").getBoundingClientRect();
        const value = pair.querySelector("dd").getBoundingClientRect();
        return value.left >= label.right && Math.abs(value.top - label.top) < 10;
      }),
    }));
    assert.equal(facts.display, "flex", "facts wrap as compact pairs rather than a dashboard grid");
    assert.equal(facts.inlinePairs, true, "each value remains beside its label");
    const headAlignment = await page.evaluate(() => Array.from(document.querySelectorAll("#sliceRecord .slice-members")).map((table) => {
      const head = table.querySelector(".slice-member-head");
      if (getComputedStyle(head).display === "none") return [];
      const visible = (row) => Array.from(row.children).filter((cell) => getComputedStyle(cell).display !== "none");
      const headCells = visible(head);
      const rowCells = visible(table.querySelector(".slice-member"));
      return headCells.slice(0, -1).map((cell, index) => ({
        label: cell.textContent.trim(),
        delta: Math.round(rowCells[index].getBoundingClientRect().x - cell.getBoundingClientRect().x),
      }));
    }));
    for (const table of headAlignment) {
      for (const { label, delta } of table) {
        assert.equal(delta, 0, `the ${label} label sits over the column its rows fill at ${size.width}px`);
      }
    }
  }
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.waitForTimeout(150);

  // The open member, as the reader sees it: the entity the inspector shows and
  // the opener that carries the focus outline.
  const activeMember = () => page.evaluate(() => ({
    open: document.activeElement?.getAttribute?.("data-member-open") ?? null,
    entity: window.NRCInspector.current() ? `${window.NRCInspector.current().type}:${window.NRCInspector.current().id}` : null,
  }));
  const selectedSlice = () => page.locator('#sliceRegisterList [aria-pressed="true"]').getAttribute("data-slice-name");

  // The register walks between slices and keeps the record that belongs to the row.
  assert.equal(await selectedSlice(), "Alpha", "the listing preselects its first slice");
  await page.evaluate(() => { window.delayedSliceAsset = 6n; });
  await page.locator('#sliceRegisterList [data-slice-name="Alpha"]').focus();
  await page.keyboard.press("ArrowDown");
  assert.deepEqual(await page.locator("#sliceRecord").evaluate((record) => ({
    heading: record.querySelector("h2")?.textContent,
    busy: record.getAttribute("aria-busy"),
    inert: record.inert,
  })), { heading: "Alpha", busy: "true", inert: true }, "the old record stays inert until every read for Beta has completed");
  await page.evaluate(() => window.releaseSliceAsset());
  await page.waitForFunction(() => document.querySelector("#sliceRecord h2")?.textContent === "Beta");
  assert.equal(await page.locator("#sliceRecord").evaluate(record => record.inert), false);
  assert.equal(await selectedSlice(), "Beta");
  await page.keyboard.press("ArrowUp");
  await page.waitForFunction(() => document.querySelector("#sliceRecord h2")?.textContent === "Alpha");
  assert.equal(await selectedSlice(), "Alpha", "the register walks back");
  await page.waitForFunction(() => document.querySelectorAll("#sliceRecord .slice-member").length === 7);

  // A click on any column of a member row opens it; the arrow then walks the same
  // table and the inspector follows, as it does in every other list.
  await page.locator('#sliceRecord .slice-member[data-member-task="2"] > .slice-dim').first().click();
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 2n);
  assert.deepEqual(await activeMember(), { open: "task:2", entity: "task:2" }, "the clicked row opens and takes focus");
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 3n);
  assert.deepEqual(await activeMember(), { open: "task:3", entity: "task:3" });
  await page.keyboard.press("ArrowUp");
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 2n);
  await page.keyboard.press("ArrowUp");
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 1n);
  assert.deepEqual(await activeMember(), { open: "task:1", entity: "task:1" });
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(100);
  assert.deepEqual(await activeMember(), { open: "task:1", entity: "task:1" }, "the members table holds at its first row");

  await page.locator('#sliceRecord .slice-member[data-member-note="201"] > .slice-dim').first().click();
  await page.waitForFunction(() => window.NRCInspector.current()?.type === "note");
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 202n);
  assert.deepEqual(await activeMember(), { open: "note:202", entity: "note:202" }, "the notes table walks and opens");
  await page.keyboard.press("ArrowUp");
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 201n);
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(100);
  assert.deepEqual(await activeMember(), { open: "note:201", entity: "note:201" }, "the notes table holds at its first row");

  await page.locator('#sliceRecord .slice-member[data-member-file="301"] > .slice-dim').first().click();
  await page.waitForFunction(() => window.NRCInspector.current()?.type === "file");
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 302n);
  assert.deepEqual(await activeMember(), { open: "file:302", entity: "file:302" }, "the files table walks and opens");
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(100);
  assert.deepEqual(await activeMember(), { open: "file:302", entity: "file:302" }, "the files table holds at its last row");

  // The record's own fields and the register keep their own arrows.
  await page.locator("#sliceOwner").focus();
  await page.keyboard.press("ArrowDown");
  assert.equal(await page.evaluate(() => document.activeElement?.id), "sliceOwner", "a field keeps the arrow keys");
  assert.equal(await selectedSlice(), "Alpha", "a field never moves the register");
  await page.locator("#sliceRecord .slice-member[data-member-task='3'] .slice-member-open").focus();
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(100);
  assert.deepEqual(await activeMember(), { open: "task:3", entity: "file:302" }, "the last member row holds the walk");
  assert.equal(await selectedSlice(), "Alpha", "a member table never moves the register");

  // A table the reader reached with Tab is the table the arrows continue in, even
  // when the click that follows lands on the record itself.
  await page.locator('#sliceRecord .slice-member[data-member-note="201"] .slice-member-open').focus();
  await page.locator("#sliceRecord .slice-facts").click();
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 202n);
  assert.deepEqual(await activeMember(), { open: "note:202", entity: "note:202" }, "a Tab-reached table keeps the walk");

  // The member the reader opened belongs to one slice: another slice's record
  // has no walk of its own until a row of its own is opened.
  await page.locator('#sliceRegisterList [data-slice-name="Beta"]').click();
  await page.waitForFunction(() => document.querySelector("#sliceRecord h2")?.textContent === "Beta");
  const beforeSliceChange = (await activeMember()).entity;
  await page.locator("#sliceRecord .slice-facts").click();
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(150);
  assert.deepEqual(await activeMember(), { open: null, entity: beforeSliceChange }, "another slice's record has no member table to walk yet");
  await page.locator('#sliceRecord .slice-member[data-member-task="2"] > .slice-dim').first().click();
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 2n);
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 3n);
  assert.deepEqual(await activeMember(), { open: "task:3", entity: "task:3" }, "the new slice walks from the row that was opened in it");

  // On a phone the record is a drill-in behind the register and the inspector is
  // a modal that owns the keyboard while it is open. Closing it returns to the
  // member table, which keeps walking; the drilled-past register does not move.
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('#sliceRegisterList [data-slice-name="Alpha"]').click();
  await page.waitForFunction(() => document.querySelector("#sliceRecord h2")?.textContent === "Alpha");
  await page.waitForFunction(() => document.querySelectorAll("#sliceRecord .slice-member").length === 7);

  // What one line cannot hold stacks, so the title must still own the row.
  const stackedTitles = await page.evaluate(() => Array.from(document.querySelectorAll(
    "#sliceRecord .slice-member--task .slice-member-open, #sliceRecord .slice-member--plain .slice-member-open",
  )).map((opener) => ({
    title: Math.round(opener.getBoundingClientRect().width),
    row: Math.round(opener.closest(".slice-member").getBoundingClientRect().width),
  })));
  for (const { title, row } of stackedTitles) {
    assert.ok(title > row / 2, `a stacked member row keeps the title the row (${title} of ${row}px)`);
  }
  await page.locator('#sliceRecord .slice-member[data-member-task="1"] > .slice-dim').first().click();
  await page.waitForFunction(() => document.body.classList.contains("inspector-open") &&
    document.activeElement?.closest?.("#inspector"));
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(150);
  assert.equal(await page.evaluate(() => String(window.NRCInspector.current()?.id)), "1", "the modal keeps the arrows while it is open");
  // The narrow record opens its messages block; Escape collapses that before
  // closing the inspector. Both stages must preserve the member selection.
  assert.equal(await page.locator('#inspector [data-messages-area]').getAttribute("data-messages-open"), "true");
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => document.querySelector('#inspector [data-messages-area]')?.dataset.messagesOpen === "false");
  assert.equal(await page.evaluate(() => document.body.classList.contains("inspector-open") && NRCInspector.current()?.id === 1n), true, "first Escape collapses messages, not the inspector");
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.body.classList.contains("inspector-open") &&
    document.activeElement?.getAttribute?.("data-member-open") === "task:1");
  assert.deepEqual(await activeMember(), { open: "task:1", entity: null }, "closing the modal returns to the member table");
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => window.NRCInspector.current()?.id === 2n);
  assert.equal((await activeMember()).entity, "task:2", "the phone drill-in still walks the member tables");
  assert.equal(await selectedSlice(), "Alpha", "the drilled-past register does not move");
  assert.deepEqual(errors, []);
  console.log("PASS: register and member/note/file arrows walk and open, boundaries hold, fields and the register keep their keys, and a walk belongs to the slice it was opened in");
} finally {
  await browser.close();
}
