// The slice register's filters and its pages: the filters are the server's, so a
// page carries only what matches, and the register asks for the next page as the
// reader reaches the end of the drawn rows.
// Production scripts and CSS, with disposable browser-local fixtures.
// node client/slice-filters.e2e.mjs
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

  // The fixture is a small server: it holds the workspace's slices, filters them
  // the way the request asks, orders them the way the register orders (closed
  // sink, movement desc, ID asc) and answers one page per request.
  await page.evaluate(() => {
    const encoder = new TextEncoder();
    const decoder = new TextDecoder("utf-8", { ignoreBOM: true });
    const bytes = (value) => encoder.encode(value ?? "");

    // Mirrors protocol/tasks.odin serializeTaskSliceList and the unit suite.
    function sliceListFrame({ correlationId, slices, total, hasMore, nextCursor }) {
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
        view.setUint8(offset, slice.closed ? 1 : 0); offset += 1;
        view.setUint16(offset, slice.backlog ?? 0, false); offset += 2;
        view.setUint16(offset, slice.todo ?? 0, false); offset += 2;
        view.setUint16(offset, slice.inProgress ?? 0, false); offset += 2;
        view.setUint16(offset, slice.done ?? 0, false); offset += 2;
        view.setUint16(offset, slice.blocked ?? 0, false); offset += 2;
        view.setUint16(offset, slice.notes ?? 0, false); offset += 2;
        view.setUint16(offset, slice.files ?? 0, false); offset += 2;
        view.setBigInt64(offset, 0n, false); offset += 8;
        view.setBigInt64(offset, slice.movedAt, false); offset += 8;
      });
      view.setUint8(offset, hasMore ? 1 : 0); offset += 1;
      view.setUint8(offset, nextCursor?.closed ? 1 : 0); offset += 1;
      view.setBigInt64(offset, nextCursor?.sortAt ?? 0n, false); offset += 8;
      view.setBigUint64(offset, nextCursor?.sliceId ?? 0n, false); offset += 8;
      view.setUint32(offset, total, false); offset += 4;
      view.setUint32(offset, 0, false); offset += 4;
      view.setUint32(offset, 0, false); offset += 4;
      view.setUint16(offset, 0, false); offset += 2;
      view.setUint32(offset, correlationId, false); offset += 4;
      if (offset !== size) throw new Error("the fixture frame does not fill its declared size");
      return new DataView(buffer);
    }

    // The request body carries no opcode: conv_id, the flags, the owner, the name,
    // the page bound, the cursor and the correlation id.
    function requestOf(view) {
      const ownerLength = view.getUint16(12, false);
      const owner = decoder.decode(new Uint8Array(view.buffer, view.byteOffset + 14, ownerLength));
      let offset = 14 + ownerLength;
      const hasName = view.getUint8(offset) === 1;
      offset += 1;
      const nameLength = view.getUint16(offset, false);
      offset += 2;
      const name = decoder.decode(new Uint8Array(view.buffer, view.byteOffset + offset, nameLength));
      offset += nameLength;
      const limit = view.getUint16(offset, false);
      offset += 2;
      const hasCursor = view.getUint8(offset) === 1;
      offset += 1;
      let cursor = null;
      if (hasCursor) {
        cursor = { closed: view.getUint8(offset) === 1, sortAt: view.getBigInt64(offset + 1, false), sliceId: view.getBigUint64(offset + 9, false) };
        offset += 17;
      }
      return {
        includeClosed: view.getUint8(10) === 1,
        hasOwner: view.getUint8(11) === 1,
        owner, hasName, name, limit, cursor,
        correlationId: view.getUint32(offset, false),
      };
    }

    // The register's order, and the only one.
    function less(left, right) {
      if (left.closed !== right.closed) return !left.closed;
      if (left.sortAt !== right.sortAt) return left.sortAt > right.sortAt;
      return left.sliceId < right.sliceId;
    }
    const key = (slice) => ({ closed: slice.closed, sortAt: slice.movedAt, sliceId: slice.sliceId });

    const slices = [];
    for (let i = 0; i < 120; i++) {
      slices.push({ name: `Tester work ${String(i + 1).padStart(3, "0")}`, sliceId: BigInt(1000 + i), owner: "tester", closed: false, movedAt: BigInt(9000 - i), todo: i % 3 === 0 ? 1 : 0 });
    }
    for (let i = 0; i < 20; i++) {
      slices.push({ name: `Anke work ${String(i + 1).padStart(3, "0")}`, sliceId: BigInt(2000 + i), owner: "anke", closed: false, movedAt: BigInt(8000 - i), backlog: 1 });
    }
    for (let i = 0; i < 10; i++) {
      slices.push({ name: `Unowned work ${String(i + 1).padStart(3, "0")}`, sliceId: BigInt(3000 + i), owner: "", closed: false, movedAt: BigInt(7000 - i) });
    }
    window.__fixtureRequests = [];

    currentRoomId = 7n;
    currentWorkspaceId = "slice-filters";
    myNickname = "tester";
    serverReady = true;

    NRCAssets.roomAssets.set(0n, new Map());
    NRCEdges.getEdgesForEntity = () => [];
    NRCEdges.requestEdgePage = () => Promise.resolve({});

    const send = ws.send.bind(ws);
    ws.send = (buffer) => {
      const view = new DataView(buffer);
      if (view.getUint16(0, false) !== 56) { send(buffer); return; }
      const request = requestOf(view);
      window.__fixtureRequests.push(request);
      let matching = slices.slice()
        .filter((slice) => (request.includeClosed || !slice.closed) &&
          (!request.hasOwner || slice.owner === request.owner) &&
          (!request.hasName || slice.name.toLowerCase().includes(request.name.toLowerCase())))
        .sort((left, right) => (less(key(left), key(right)) ? -1 : 1));
      const total = matching.length;
      if (request.cursor) matching = matching.filter((slice) => less(request.cursor, key(slice)));
      const page = matching.slice(0, request.limit);
      const hasMore = matching.length > page.length;
      const last = page[page.length - 1];
      window.NRCSlices.handleSliceList(sliceListFrame({
        correlationId: request.correlationId,
        slices: page,
        total,
        hasMore,
        nextCursor: hasMore && last ? key(last) : null,
      }));
    };
    setTaskGrouping("slices");
    showKanban();
  });
  await page.waitForSelector("#sliceRegisterList .slice-row");

  const rows = () => page.locator("#sliceRegisterList .slice-row").count();
  const head = () => page.locator("#sliceResultsCount").textContent();
  const status = () => page.locator("#sliceStatus").textContent();
  const rowNames = () => page.locator("#sliceRegisterList .slice-row").evaluateAll((elements) => elements.map((element) => element.dataset.sliceName));
  const chooseOwner = async (value) => {
    await page.locator("#sliceOwnerFilter-trigger").click();
    await page.locator(`.custom-select__option[data-value="${value}"]`).click();
  };
  const scrollToEnd = () => page.evaluate(() => {
    const register = document.querySelector("#sliceView .slice-register");
    register.scrollTop = register.scrollHeight;
  });

  // One page is drawn, and the head says how many of the listing's slices that is.
  assert.equal(await rows(), 100, "the register draws one page");
  assert.equal(await head(), "100 / 150 SLICES / 34 OPEN");
  assert.equal(await page.locator("#sliceRegisterList .slice-row").first().getAttribute("data-slice-name"), "Tester work 001");

  // Reaching the end of the drawn rows asks for the next page.
  await scrollToEnd();
  await page.waitForFunction(() => document.querySelectorAll("#sliceRegisterList .slice-row").length === 150);
  assert.equal(await head(), "150 SLICES / 60 OPEN", "the whole listing is drawn");
  // The register's own requests are the unfiltered ones; the attention register
  // reads its own listing (owner = me) beside them.
  const registerRequests = await page.evaluate(() => window.__fixtureRequests.filter((request) => !request.hasOwner));
  assert.equal(registerRequests.length, 2, "the register asked for the two pages it drew");
  assert.equal(registerRequests[0].limit, 100, "the register asks for a page at a time");
  assert.equal(registerRequests[0].cursor, null, "the first page carries no cursor");
  assert.equal(registerRequests[1].cursor.closed, false, "the next page asks where the previous one stopped");
  assert.equal(registerRequests[1].cursor.sliceId, 1099n, "the cursor names the last drawn slice");

  // The owner filter is the server's: the request carries it, and only the rows it
  // matches arrive. The register was scrolled to its end, so the filtered page that
  // does not fill the viewport is followed by the next one without a scroll.
  await chooseOwner("me");
  await page.waitForFunction(() => document.querySelectorAll("#sliceRegisterList .slice-row").length === 120);
  const mineRequest = await page.evaluate(() => window.__fixtureRequests.find((request) => request.hasOwner));
  assert.equal(mineRequest.hasOwner, true);
  assert.equal(mineRequest.owner, "tester", "MY SLICES resolves to the reader's own name");
  assert.equal(await head(), "120 SLICES / 40 OPEN");
  assert.equal((await rowNames()).every((name) => name.startsWith("Tester work")), true, "only the reader's slices are drawn");

  // The walk at the end of the drawn rows asks for the next page too: the cursor is
  // put back to where the first page ended, as a reader who never scrolled has it.
  await page.evaluate(() => {
    const state = window.NRCSlices.getState();
    const last = state.slices[99];
    state.slices.length = 100;
    state.cursor = { closed: last.flags !== 0, sortAt: last.lastMovedAt, sliceId: last.sliceId };
    state.hasMore = true;
    state.selected = last.name;
    window.NRCSlices.render();
  });
  await page.locator("#sliceRegisterList .slice-row").last().focus();
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => document.querySelectorAll("#sliceRegisterList .slice-row").length === 120);

  // The name query narrows by the name a slice is addressed by.
  await page.locator("#filterReset").click();
  await page.waitForFunction(() => document.querySelectorAll("#sliceRegisterList .slice-row").length >= 100);
  await page.locator("#sliceQuery").fill("anke work");
  await page.waitForFunction(() => document.querySelectorAll("#sliceRegisterList .slice-row").length === 20);
  assert.equal(await head(), "20 SLICES / 20 OPEN");
  assert.equal(await page.locator("#sliceRegisterList .slice-row").first().getAttribute("data-slice-name"), "Anke work 001");

  // A filter that matches nothing says so instead of reading as an empty workspace.
  await page.locator("#sliceQuery").fill("zzz");
  await page.waitForFunction(() => document.querySelectorAll("#sliceRegisterList .slice-row").length === 0);
  assert.equal(await head(), "0 SLICES / 0 OPEN");
  assert.equal(await status(), "NO SLICES MATCH THE FILTER");
  assert.equal(await page.locator("#sliceStatus").isVisible(), true);

  // RESET clears both filters and asks for the listing again.
  await page.locator("#filterReset").click();
  await page.waitForFunction(() => document.querySelectorAll("#sliceRegisterList .slice-row").length >= 100);
  await scrollToEnd();
  await page.waitForFunction(() => document.querySelectorAll("#sliceRegisterList .slice-row").length === 150);
  assert.equal(await page.locator("#sliceQuery").inputValue(), "");
  assert.equal(await page.locator("#sliceOwnerFilter").inputValue(), "");
  assert.equal(await page.locator("#sliceStatus").isVisible(), false);

  assert.deepEqual(errors, []);
  console.log("PASS: slice filters are asked of the server, pages fill as the register is walked, and the head and status report what is drawn");
} finally {
  await browser.close();
}
