// Run against the disposable test/customer-workspace-dev.mjs fixture with a
// workspace-scope server binary, never against a shared workspace.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_WORKSPACE_TEST_URL;
if (!url) throw new Error("Set NRC_WORKSPACE_TEST_URL to the disposable fixture");
const browser = await chromium.launch();
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const page = await context.newPage();
  const errors = [], packets = [], asks = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("websocket", socket => socket.on("framesent", ({ payload }) => {
    if (Buffer.isBuffer(payload)) packets.push(payload);
  }));
  await page.route("**/ai/ask", route => {
    asks.push(route.request().postDataJSON());
    return route.fulfill({ json: { answer: "Workspace answer", sources: [] } });
  });
  await page.goto(`${url}/#workspace=scope-review-${Date.now()}`);
  await page.waitForFunction(() => serverReady && NRCTasks.roomTasks.has(0n));
  const membershipStart = packets.length;
  await page.evaluate(async () => {
    await joinRoomFromPalette("0");
    leaveRoomFromPalette("0");
  });
  assert.equal(await page.evaluate(() => subscribedRooms.has(0n)), false);
  assert.equal(packets.slice(membershipStart).some(p => [2, 3, 49].includes(p.readUInt16BE(0))), false,
    "palette join/leave zero sends no membership requests");
  // Independently test leave against the polluted state an older client allowed.
  await page.evaluate(() => { subscribedRooms.add(0n); leaveRoomFromPalette("0"); subscribedRooms.delete(0n); });
  assert.equal(packets.slice(membershipStart).some(p => p.readUInt16BE(0) === 3), false);
  const peer = await context.newPage();
  await peer.goto(page.url());
  await peer.waitForFunction(() => serverReady);
  const peerNote = await peer.evaluate(() => new Promise((resolve, reject) => NRCAssets.sendCreateAsset(0n, 5, 0, 0n,
    '{"title":"Peer delivery after rejected leave"}', "Scope zero stays subscribed.", 0,
    { onSuccess: result => resolve(String(result.asset.assetId)), onError: reject })));
  await page.waitForFunction(id => NRCAssets.roomAssets.get(0n)?.has(BigInt(id)), peerNote);
  await peer.close();
  const ids = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const task = await rpc(options => NRCTasks.sendCreateTask(3n, "Workspace release checklist", "Shared by every chat room", 100, 0, "", 0n, [], 1, 0, "Release", options));
    const note = await rpc(options => NRCAssets.sendCreateAsset(4n, 5, 0, 0n,
      '{"title":"Workspace operating notes","project":"Release","tags":["operations"]}', "# Workspace operating notes\n\nChat rooms do not partition this document.", 0, options));
    const company = await rpc(options => NRCAssets.sendCreateAsset(3n, 8, 0, 0n,
      '{"version":1,"title":"Workspace customer","city":"Hamburg"}', "", 0, options));
    await rpc(options => NRCEdges.sendCreateEdge(4n, 1, note.asset.assetId, 2, task.task.id, 1, options));
    return { task: String(task.task.id), note: String(note.asset.assetId), company: String(company.asset.assetId) };
  });
  await page.evaluate(taskId => {
    NRCTasks.showKanban();
    return NRCInspector.openEntity({ type: "task", id: taskId });
  }, ids.task);
  await page.click("#taskDetailToggleFocus");
  await page.fill("#taskDetailDesc", "Unsaved workspace draft");
  await page.evaluate(() => switchToRoom(3n));
  assert.equal(await page.inputValue("#taskDetailDesc"), "Unsaved workspace draft");
  assert.equal(await page.evaluate(() => String(NRCInspector.current().roomId)), "0");
  assert.equal(await page.locator("#sidebarViewRoomName").textContent(), "WORKSPACE");
  // Browser-local DM identity: no server DM or message is created by this check.
  await page.evaluate(() => {
    const dm = DM_CONV_FLAG | 123n;
    activeDMs.set(dm, { username: "scope-peer", online: true });
    subscribedRooms.add(dm);
    switchToRoom(dm);
  });
  assert.equal(await page.evaluate(() => NRCViewManager.getActiveView()), "kanban");
  assert.equal(await page.inputValue("#taskDetailDesc"), "Unsaved workspace draft", "DM selection preserves edits too");
  await page.evaluate(() => {
    switchToRoom(3n);
    const dm = DM_CONV_FLAG | 123n;
    activeDMs.delete(dm); subscribedRooms.delete(dm); roomHistory.delete(dm);
  });
  // Save at scope zero: truthiness must not reject a selected task in that scope.
  await page.click("#taskDetailSave");
  await page.waitForFunction(id => NRCTasks.roomTasks.get(0n).get(BigInt(id)).description === "Unsaved workspace draft", ids.task);
  await page.evaluate(noteId => NRCInspector.openEntity({ roomId: 4n, type: "note", id: noteId }), ids.note);
  assert.equal(await page.evaluate(() => String(currentRoomId)), "3", "legacy entity scope must not switch chat");
  assert.equal(await page.evaluate(() => String(NRCNotes.getCurrentNote().convId)), "0");
  await page.evaluate(() => NRCNotes.showNotesView());
  await page.waitForFunction(() => document.getElementById("notesList").textContent.includes("Workspace operating notes"));
  await page.evaluate(() => switchToRoom(4n));
  assert.match(await page.locator("#notesList").textContent(), /Workspace operating notes/);
  assert.equal(await page.evaluate(() => String(NRCInspector.current().id)), ids.note);
  await page.evaluate(async () => NRCAI.handleAsk("Find the workspace checklist", { forceRoom: true, displayConvID: 4n }));
  assert.equal(asks.length, 1);
  assert.equal(asks[0].context_conv_id, "0");
  assert.equal(asks[0].display_conv_id, "4");
  assert.equal(await page.evaluate(() => roomHistory.has(0n) || subscribedRooms.has(0n) || retainedRoomStates.has(0n)), false);

  await page.route("**/ai/ask/ready", route => route.fulfill({ json: { ai_username: "sullivan-scope" } }));
  const aiDisplay = await page.evaluate(async () => {
    const ai = DM_CONV_FLAG | 900n, human = DM_CONV_FLAG | 901n;
    activeDMs.set(ai, { username: "sullivan-scope", online: true });
    activeDMs.set(human, { username: "human-peer", online: true });
    subscribedRooms.add(ai); subscribedRooms.add(human);
    roomHistory.set(ai, []);
    logMessage("Message", "Private human DM transcript", human, { author: "human-peer" });
    await NRCAI.openSullivanWithContext(0n, { focused: false });
    await NRCAI.handleAsk("Completed workspace turn");
    return String(ai);
  });
  await page.locator("#logOutput").getByText("Workspace answer", { exact: true }).waitFor();
  await page.fill("#messageInput", "Workspace follow-up draft");
  for (const destination of ["3", "9223372036854776709", "9223372036854776709", "4"]) {
    await page.evaluate(id => switchToRoom(BigInt(id)), destination);
    await page.waitForFunction(() => document.getElementById("logOutput").textContent.includes("Workspace answer"));
    assert.deepEqual(await page.evaluate(() => ({
      view: NRCViewManager.getActiveView(), display: String(NRCAI.getDisplayConvId()), scope: String(NRCAI.getContextConvId()),
      draft: document.getElementById("messageInput").value,
      humanTranscript: document.getElementById("logOutput").textContent.includes("Private human DM transcript"),
    })), { view: "sullivan", display: aiDisplay, scope: "0", draft: "Workspace follow-up draft", humanTranscript: false });
  }
  // Exercise reconnect with a realistic DM-list reply retaining the mocked
  // AI/human identities. The socket, authentication and session restart are real.
  await page.evaluate(() => {
    const records = [[DM_CONV_FLAG | 900n, "sullivan-scope"], [DM_CONV_FLAG | 901n, "human-peer"]];
    const bytes = new Uint8Array(8 + records.reduce((n, [, name]) => n + 20 + name.length, 0));
    const view = new DataView(bytes.buffer);
    view.setUint16(0, Opcode.S_DMList); view.setUint16(2, records.length);
    let offset = 8;
    for (const [id, name] of records) {
      view.setBigUint64(offset, id); offset += 8;
      view.setUint16(offset, name.length); offset += 2;
      bytes.set(new TextEncoder().encode(name), offset); offset += name.length;
      view.setUint8(offset++, 1); view.setUint8(offset++, 1); offset += 8;
    }
    const original = parseDMList;
    window.scopeTestDMLists = 0;
    parseDMList = () => { original(view); window.scopeTestDMLists++; };
  });
  for (const destination of ["3", "9223372036854776709"]) {
    await page.evaluate(id => {
      switchToRoom(BigInt(id));
      handleImageChunk(JSON.stringify({ type: "image_chunk", imageId: `scope-${id}`, chunkIndex: 0, totalChunks: 1,
        data: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==", mimeType: "image/gif", filename: "private-human-image.gif" }), "human-peer", BigInt(id));
      if (!roomHistory.get(BigInt(id)).some(m => m.imageData?.filename === "private-human-image.gif")) throw new Error("image not reconstructed");
    }, destination);
    assert.equal(await page.locator('#logOutput img').count(), 0, "chat images never enter Sullivan");
    const before = await page.evaluate(() => window.scopeTestDMLists);
    await page.evaluate(() => manualReconnect());
    await page.waitForFunction(count => serverReady && window.scopeTestDMLists > count, before);
    assert.deepEqual(await page.evaluate(() => ({
      view: NRCViewManager.getActiveView(), display: String(NRCAI.getDisplayConvId()), scope: String(NRCAI.getContextConvId()),
      draft: document.getElementById("messageInput").value,
      answer: document.getElementById("logOutput").textContent.includes("Workspace answer"),
      humanTranscript: document.getElementById("logOutput").textContent.includes("Private human DM transcript"),
      images: document.querySelectorAll("#logOutput img").length,
    })), { view: "sullivan", display: aiDisplay, scope: "0", draft: "Workspace follow-up draft", answer: true, humanTranscript: false, images: 0 });
  }
  await page.evaluate(() => switchToRoom(4n));
  await page.click("#sullivanSend");
  await page.waitForFunction(() => !NRCAI.isWorkbenchBusy());
  assert.equal(asks.at(-1).question, "Workspace follow-up draft");
  assert.equal(asks.at(-1).display_conv_id, aiDisplay);
  assert.equal(asks.at(-1).context_conv_id, "0");
  if (process.env.NRC_WORKSPACE_SCREENSHOTS) {
    await fs.mkdir(process.env.NRC_WORKSPACE_SCREENSHOTS, { recursive: true });
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => setTheme(theme), theme);
      for (const width of [1440, 390]) {
        await page.setViewportSize({ width, height: 900 });
        await page.locator("#logOutput .ai-response-actions").last().scrollIntoViewIfNeeded();
        await page.screenshot({ path: `${process.env.NRC_WORKSPACE_SCREENSHOTS}/sullivan-stable-${theme}-${width}.png` });
      }
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
  }
  await page.evaluate(companyId => NRCCustomers.openCompany(NRCAssets.roomAssets.get(0n).get(BigInt(companyId))), ids.company);
  assert.equal(await page.evaluate(() => String(currentRoomId)), "4");

  // The fixture switched directly; normal room joining persists membership.
  await page.evaluate(() => saveRoomsToStorage());
  const noteLink = await page.evaluate(noteId => NRCNotes.getSharedNoteUrl(NRCAssets.roomAssets.get(0n).get(BigInt(noteId))), ids.note);
  assert.match(noteLink, new RegExp(`#/note/[^/]+/${ids.note}$`));
  await page.goto(noteLink);
  await page.reload();
  await page.waitForFunction(() => serverReady && NRCViewManager.getActiveView() === "noteShare");
  assert.equal(await page.evaluate(() => String(currentRoomId)), "4", "share startup preserves saved chat");
  assert.equal(await page.evaluate(() => subscribedRooms.has(0n) || roomHistory.has(0n)), false);

  for (const packet of packets) {
    const opcode = packet.readUInt16BE(0);
    if (opcode === 2 || opcode === 49) {
      const ids = Array.from({ length: packet.readUInt16BE(2) }, (_, i) => packet.readBigUInt64BE(4 + 8 * i));
      if (opcode === 49) assert.ok(!ids.includes(0n), "scope zero never uses retained chat subscription");
    }
    if ((opcode >= 20 && opcode <= 47 && opcode !== 27) || opcode === 53 || opcode === 54 || opcode === 55) {
      assert.equal(packet.readBigUInt64BE(2), 0n, `durable opcode ${opcode}`);
    }
    if ([1, 48, 50, 51].includes(opcode)) assert.notEqual(packet.readBigUInt64BE(2), 0n, `chat opcode ${opcode}`);
  }
  assert.ok(packets.some(p => p.readUInt16BE(0) === 2 && p.readBigUInt64BE(4) === 0n), "legacy data subscription exists");
  assert.deepEqual(errors, []);
  if (process.env.NRC_WORKSPACE_SCREENSHOTS) {
    await fs.mkdir(process.env.NRC_WORKSPACE_SCREENSHOTS, { recursive: true });
    await page.evaluate(() => { location.hash = ""; });
    await page.evaluate(() => NRCNotes.showNotesView());
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => setTheme(theme), theme);
      for (const [width, height] of [[1440, 1000], [390, 844]]) {
        await page.setViewportSize({ width, height });
        await page.screenshot({ path: `${process.env.NRC_WORKSPACE_SCREENSHOTS}/workspace-${theme}-${width}.png` });
      }
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.evaluate(noteId => NRCInspector.openEntity({ type: "note", id: noteId }), ids.note);
    await page.screenshot({ path: `${process.env.NRC_WORKSPACE_SCREENSHOTS}/workspace-selected-note.png` });
  }
  console.log("Workspace data E2E passed: scope-zero wire requests, chat-preserving entity navigation/edit/save, shared lists, roomless share startup, AI scope/display split.");
} finally {
  await browser.close();
}
