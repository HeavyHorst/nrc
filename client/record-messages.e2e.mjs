// A record panel is a document surface plus one messages block. The block
// closes to a register line so the document keeps the panel, renders messages
// as markdown, and keeps ENTER for newlines.
// node client/record-messages.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, serviceWorkers: "block" });
const errors = [];
page.on("pageerror", error => errors.push(error.message));

async function openTask(id = 412) {
  await page.evaluate(async (taskId) => {
    await NRCInspector.close();
    await NRCInspector.openEntity({ roomId: 0n, type: "task", id: BigInt(taskId) });
  }, id);
  await page.locator("#inspectorEntityHost [data-messages-area]").waitFor({ state: "visible" });
}

async function messageState() {
  return page.evaluate(() => {
    const area = document.querySelector("#inspectorEntityHost [data-messages-area]");
    const composer = area.querySelector("[data-composer]");
    const documentHost = area.parentElement.querySelector(".task-detail-tab-content");
    const stream = area.querySelector("[data-messages-stream]");
    return {
      open: area.dataset.messagesOpen,
      composerOpen: composer.dataset.composerOpen,
      strip: area.querySelector("[data-messages-toggle]").textContent.replace(/\s+/g, " ").trim(),
      documentHeight: Math.round(documentHost.getBoundingClientRect().height),
      streamScrolls: stream.scrollHeight > stream.clientHeight,
      messages: [...area.querySelectorAll(".record-message")].map(message => message.dataset.assetId),
    };
  });
}

try {
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${path === "/" ? "/index.html" : path}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCAssets && window.NRCInspector && window.NRCTasks && window.NRCDetailUI);
  await page.evaluate(() => {
    currentRoomId = 0n;
    currentWorkspaceId = "record-messages";
    myNickname = "tester";
    serverReady = true;
    const stamp = BigInt(Date.now()) * 1000000n;
    const task = {
      id: 412n, convId: 0n, title: "North gate barrier inspection",
      description: "## Messprotokoll\n\nBarrier reports fault 14.\n\n| Zyklus | L (mH) |\n|---|---|\n| 1 | 1.42 |",
      status: 2, priority: 2, color: 1, createdBy: "rene", createdAt: stamp, updatedAt: stamp,
      completedAt: 0n, attachments: [], assignee: "kim", project: "site-north", externalRef: "", dueAt: 0n, blockedBy: 0n,
    };
    NRCTasks.roomTasks.set(0n, new Map([[412n, task]]));
    NRCTasks.roomTasks.get(0n).set(512n, {
      id: 512n, convId: 0n, title: "Torque table follow-up", description: "", status: 1, priority: 1,
      color: 1, createdBy: "kim", createdAt: stamp, updatedAt: stamp, completedAt: 0n, attachments: [],
      assignee: "kim", project: "site-north", externalRef: "", dueAt: 0n, blockedBy: 0n,
    });
    const comment = (id, owner, payload, at) => ({
      assetId: BigInt(id), convId: 0n, assetType: 1, parentType: 1, parentId: 412n,
      owner, createdAt: at, updatedAt: at, attachments: [], preview: payload.slice(0, 100), payload,
    });
    const fileAsset = {
      assetId: 2001n, convId: 0n, assetType: 3, parentType: 0, parentId: 0n, owner: "rene",
      createdAt: stamp, updatedAt: stamp, preview: JSON.stringify({ version: 1, title: "Wartungsvertrag 2026" }),
      payload: JSON.stringify({ type: "file", version: 1, title: "Wartungsvertrag 2026", description: "Wartung Standort Nord.", category: "Contract", tags: [] }),
      attachments: [{ fileId: "att_00000000000000000000000000000000", filename: "wartungsvertrag.pdf", mimeType: "application/pdf", size: 248000 }],
    };
    NRCAssets.roomAssets.set(0n, new Map([
      [1811n, comment(1811, "kim", "## Messprotokoll Loop B\n\n- [x] Messreihe dokumentiert", stamp)],
      [1817n, comment(1817, "tester", "Shim liegt im Werkzeugkasten.", stamp + 1000000n)],
      [2001n, fileAsset],
    ]));
    // The record's resources: one linked task and one linked file, so the
    // register lines carry counts the owning modules computed.
    const edge = (edgeId, sourceType, sourceId, targetType, targetId, relation) =>
      ({ edgeId, convId: 0n, sourceType, sourceId, targetType, targetId, relation, createdAt: stamp });
    const linkedTask = edge(9001n, 2, 412n, 2, 512n, 2);
    const linkedFile = edge(9002n, 1, 2001n, 2, 412n, 2);
    NRCEdges.roomEdges.set(0n, new Map([[9001n, linkedTask], [9002n, linkedFile]]));
    NRCEdges.roomEdgesByEntity.set(0n, new Map([
      ["task:412", new Set([9001n, 9002n])],
      ["task:512", new Set([9001n])],
      ["asset:2001", new Set([9002n])],
    ]));
    NRCLinksUI.loadLinks = async () => {};
    window.__sends = [];
    ws.send = () => { window.__sends.push(1); };
    NRCViewManager.setActiveView("tasks");
  });

  // A record panel has no DETAIL/COMMENTS tabs any more.
  await openTask();
  assert.equal(await page.locator("#inspectorHeader .task-detail-tabs").count(), 0, "the record header carries no tabs");
  assert.equal(await page.locator("#inspectorHeader .inspector-view-cell").count(), 0,
    "the record header carries no mode register either: STATE and the EDIT operation already name the mode");

  const closed = await messageState();
  assert.equal(closed.open, "false", "the messages block starts closed");
  assert.match(closed.strip, /^MESSAGES 2 /, `the strip counts the messages (${closed.strip})`);
  assert.match(closed.strip, /tester: Shim liegt im Werkzeugkasten/, "the strip previews the last message");
  assert.ok(closed.documentHeight > 500, `the document owns the closed panel (${closed.documentHeight}px)`);

  // Opening gives the stream its own scroll area without replacing the document.
  await page.locator("#inspectorEntityHost [data-messages-toggle]").click();
  const opened = await messageState();
  assert.equal(opened.open, "true", "the strip opens the block");
  assert.ok(opened.documentHeight > 200, `the document stays visible (${opened.documentHeight}px)`);
  assert.ok(opened.documentHeight < closed.documentHeight, "the document yields the block's height, not the panel");
  assert.deepEqual(opened.messages, ["1811", "1817"], "messages read oldest first");

  // Markdown renders through the shared chat renderer; only own messages delete.
  assert.equal(await page.locator("#inspectorEntityHost .record-message .message-content h2").count(), 1, "headings render");
  assert.equal(await page.locator("#inspectorEntityHost .record-message .message-content ul li").count(), 1, "lists render");
  assert.equal(await page.locator("#inspectorEntityHost .record-message .record-message-delete").count(), 1, "only own messages offer delete");
  assert.equal(await page.locator("#inspectorEntityHost .record-message[data-asset-id='1817'] .record-message-delete").count(), 1, "the own message carries the delete action");

  // M opens the block and the composer, ENTER keeps the draft, CTRL+ENTER sends.
  await page.keyboard.press("Escape");
  assert.equal((await messageState()).open, "false", "ESC collapses the block before the panel");
  await page.keyboard.press("m");
  const composing = await messageState();
  assert.equal(composing.open, "true", "M opens the block");
  assert.equal(composing.composerOpen, "true", "M opens the composer");
  assert.equal(await page.evaluate(() => document.activeElement?.id), "taskCommentInput", "M focuses the draft");

  await page.evaluate(() => { window.__sends = []; });
  await page.keyboard.type("erste Zeile");
  await page.keyboard.press("Enter");
  await page.keyboard.type("zweite Zeile");
  await page.waitForTimeout(50);
  assert.equal(await page.evaluate(() => window.__sends.length), 0, "ENTER writes a newline instead of sending");
  assert.equal(await page.locator("#taskCommentInput").inputValue(), "erste Zeile\nzweite Zeile", "the draft keeps its line break");

  await page.keyboard.press("Control+Enter");
  await page.waitForTimeout(100);
  assert.equal(await page.evaluate(() => window.__sends.length), 1, "CTRL+ENTER sends once");
  assert.equal(await page.locator("#taskCommentInput").inputValue(), "", "sending clears the draft");
  assert.equal((await messageState()).composerOpen, "true", "the composer stays open while the caret is in it");

  // A re-render (an arriving message) must not discard the draft.
  await page.locator("#taskCommentInput").fill("halb geschrieben");
  await page.evaluate(() => {
    NRCTasks.selectTask(NRCTasks.roomTasks.get(0n).get(412n));
  });
  await page.locator("#inspectorEntityHost [data-messages-area]").waitFor({ state: "visible" });
  assert.equal(await page.locator("#taskCommentInput").inputValue(), "halb geschrieben",
    "a re-render keeps the draft");
  assert.equal((await messageState()).composerOpen, "true", "a re-render keeps the composer open");
  assert.equal(await page.locator("#inspectorEntityHost .task-comment-byte-count").textContent(), "16 B / 65,535 B",
    "the restored draft updates the byte count");
  assert.equal(await page.evaluate(() => {
    const stream = document.querySelector("#inspectorEntityHost .record-stream");
    return stream.scrollHeight - stream.clientHeight - stream.scrollTop;
  }), 0, "an open block returns to its newest message after a re-render");
  await page.locator("#taskCommentInput").fill("");

  // SEND returns the space to the document.
  await page.locator("#taskCommentInput").fill("kurz");
  await page.locator("#taskCommentSend").click();
  await page.waitForTimeout(100);
  assert.equal(await page.evaluate(() => window.__sends.length), 2, "SEND sends once");
  assert.equal((await messageState()).composerOpen, "false", "SEND collapses the composer");

  // Resource registers: files and links close to one line each and open in
  // place, so the document keeps the panel. The line's count comes from the
  // module that owns the section.
  const resourceState = () => page.evaluate(() => {
    const host = document.querySelector("#inspectorEntityHost");
    return [...host.querySelectorAll("[data-resource]")].map((block) => {
      const section = block.querySelector(".record-resource-body > .file-assets-section, .record-resource-body > .task-detail-links-section");
      const titleRow = section?.querySelector(".panel-header, .note-links-header, .task-detail-links-header");
      return {
        resource: block.dataset.resource,
        open: block.dataset.resourceOpen,
        line: block.querySelector("[data-resource-toggle]").textContent.replace(/\s+/g, " ").trim(),
        bodyVisible: block.querySelector(".record-resource-body").offsetParent !== null,
        sections: block.querySelectorAll(".file-assets-section, .task-detail-links-section").length,
        titleRow: titleRow ? getComputedStyle(titleRow).display : null,
        documentHeight: Math.round(host.querySelector(".task-detail-tab-content").getBoundingClientRect().height),
      };
    });
  });

  const closedResources = await resourceState();
  assert.deepEqual(closedResources.map((register) => register.resource), ["files", "links"],
    "a record without payload attachments carries a register for files and links only");
  assert.deepEqual(closedResources.map((register) => register.open), ["false", "false"],
    "resource registers start closed");
  assert.deepEqual(closedResources.map((register) => register.line),
    ["FILES 1 Wartungsvertrag 2026", "LINKS 1 #512 Torque table follow-up"],
    "the register line carries the count and the first entry the owning module computed");
  assert.deepEqual(closedResources.map((register) => register.bodyVisible), [false, false],
    "a closed register keeps its section off screen");
  assert.deepEqual(closedResources.map((register) => register.sections), [1, 1],
    "each register holds exactly one section, and none is duplicated");

  // Opening reveals the section in place: the panel is not re-rendered, so the
  // owning module keeps its ids, its hydration and its scroll.
  const heightBefore = closedResources[0].documentHeight;
  await page.evaluate(() => { document.querySelector("#taskDetailLinksList").dataset.probe = "kept"; });
  await page.locator('#inspectorEntityHost [data-resource="links"] [data-resource-toggle]').click();
  const openLinks = (await resourceState()).find((register) => register.resource === "links");
  assert.equal(openLinks.open, "true", "the register line opens the links");
  assert.equal(openLinks.bodyVisible, true, "the links section is on screen");
  assert.equal(openLinks.titleRow, "none", "the register line replaces the section's own title row");
  assert.equal(await page.evaluate(() => document.querySelector("#taskDetailLinksList").dataset.probe), "kept",
    "opening a register does not re-render the panel");
  assert.equal(await page.locator("#inspectorEntityHost .task-detail-link-item").count(), 1,
    "the opened links list holds the linked task");
  assert.ok(openLinks.documentHeight >= heightBefore - 1,
    `the panel keeps its height while a register is open (${openLinks.documentHeight}px)`);

  await page.locator('#inspectorEntityHost [data-resource="files"] [data-resource-toggle]').click();
  const openFiles = (await resourceState()).find((register) => register.resource === "files");
  assert.equal(openFiles.open, "true", "the files register opens too");
  assert.equal(openFiles.titleRow, "none", "the files ledger's own title row yields to the register line");
  assert.equal(await page.locator("#inspectorEntityHost .file-assets-row .note-link-target").first().textContent(),
    "Wartungsvertrag 2026", "the files section renders its rows");

  // The operator's register state survives the re-renders the panel does on its
  // own, the way the composer draft does.
  await page.evaluate(() => { NRCTasks.selectTask(NRCTasks.roomTasks.get(0n).get(412n)); });
  await page.locator("#inspectorEntityHost [data-messages-area]").waitFor({ state: "visible" });
  assert.deepEqual((await resourceState()).map((register) => register.open), ["true", "true"],
    "a re-render keeps the registers as the operator left them");

  // Edit mode keeps the flat resource sections: the form needs its + ADD and
  // + LINK controls rather than a collapsed line.
  await page.locator("#taskDetailToggleFocus").click();
  await page.waitForTimeout(250);
  const editResources = await page.evaluate(() => {
    const host = document.querySelector("#inspectorEntityHost");
    const section = host.querySelector('.detail-edit-section[data-detail-section="resources"]');
    return {
      registers: host.querySelectorAll("[data-resource]").length,
      files: section?.querySelectorAll(".file-assets-section").length ?? 0,
      links: section?.querySelectorAll(".task-detail-links-section").length ?? 0,
      controls: section?.querySelectorAll(".file-assets-section .panel-header .btn").length ?? 0,
    };
  });
  assert.equal(editResources.registers, 0, "the edit form carries no collapsed registers");
  assert.equal(editResources.files, 1, "the edit form keeps the files ledger");
  assert.equal(editResources.links, 1, "the edit form keeps the links section");
  assert.ok(editResources.controls > 0, "the edit form keeps its upload and link controls");
  await openTask();
  assert.deepEqual((await resourceState()).map((register) => register.open), ["false", "false"],
    "a fresh selection returns with its registers closed");

  // A deep link opens the block and marks the message.
  await page.evaluate(() => {
    NRCTasks.openTaskComments(NRCTasks.roomTasks.get(0n).get(412n), 1811n);
  });
  await page.waitForTimeout(400);
  assert.equal((await messageState()).open, "true", "a deep link opens the block");
  assert.equal(await page.locator("#inspectorEntityHost .record-message[data-asset-id='1811'].highlighted").count(), 1,
    "the deep link marks its message");

  // A wide panel is a document surface: the messages become a column beside
  // the document, always open, with a draggable divider.
  await page.evaluate(() => {
    const area = document.querySelector("#inspectorEntityHost [data-messages-area]");
    if (area.dataset.messagesOpen === "true") area.querySelector("[data-messages-toggle]").click();
  });
  await page.evaluate(() => { document.querySelector(".agenda-panel").style.width = "900px"; });
  await page.waitForTimeout(300);
  const surface = await page.evaluate(() => {
    const host = document.querySelector("#inspectorEntityHost");
    const panel = host.querySelector(".task-detail-panel");
    const documentColumn = host.querySelector(".task-detail-tab-content");
    const block = host.querySelector(".record-messages");
    const strip = host.querySelector("[data-messages-toggle]");
    const handle = host.querySelector("[data-record-resize]");
    return {
      panelDisplay: getComputedStyle(panel).display,
      documentRight: Math.round(documentColumn.getBoundingClientRect().right),
      blockLeft: Math.round(block.getBoundingClientRect().left),
      blockWidth: Math.round(block.getBoundingClientRect().width),
      blockHeight: Math.round(block.getBoundingClientRect().height),
      documentHeight: Math.round(documentColumn.getBoundingClientRect().height),
      bodyVisible: host.querySelector("[data-messages-body]").offsetParent !== null,
      messagesOpenAttribute: host.querySelector("[data-messages-area]").dataset.messagesOpen,
      stripHint: getComputedStyle(strip.querySelector("i")).display,
      stripInert: getComputedStyle(strip).pointerEvents,
      handleDisplay: getComputedStyle(handle).display,
      handleRole: handle.getAttribute("role"),
      handleMin: handle.getAttribute("aria-valuemin"),
    };
  });
  assert.equal(surface.panelDisplay, "grid", "a wide panel lays document and messages out as columns");
  assert.ok(surface.documentRight <= surface.blockLeft + 1, "the messages column sits beside the document");
  assert.equal(surface.blockHeight, surface.documentHeight, "both columns fill the panel height");
  assert.equal(surface.bodyVisible, true, "the messages column is always open");
  assert.equal(surface.messagesOpenAttribute, "false", "the column ignores the narrow composition's closed state");
  assert.equal(surface.stripHint, "none", "the column header drops the key hint");
  assert.equal(surface.stripInert, "none", "the column header is not a toggle");
  assert.equal(surface.handleDisplay, "block", "the divider is available");
  assert.equal(surface.handleRole, "separator");
  assert.equal(surface.handleMin, "320");

  // Dragging the divider trades width between the two columns and persists.
  const handleBox = await page.locator("#inspectorEntityHost [data-record-resize]").boundingBox();
  await page.mouse.move(handleBox.x + handleBox.width / 2, handleBox.y + handleBox.height / 2);
  await page.mouse.down();
  await page.mouse.move(handleBox.x + handleBox.width / 2 - 60, handleBox.y + handleBox.height / 2, { steps: 4 });
  await page.mouse.up();
  await page.waitForTimeout(200);
  const dragged = await page.evaluate(() => ({
    blockWidth: Math.round(document.querySelector("#inspectorEntityHost .record-messages").getBoundingClientRect().width),
    stored: localStorage.getItem("nrc.record.messagesWidth"),
    ariaNow: document.querySelector("#inspectorEntityHost [data-record-resize]").getAttribute("aria-valuenow"),
  }));
  assert.equal(dragged.blockWidth, surface.blockWidth + 60, "dragging the divider widens the messages column");
  assert.equal(dragged.stored, String(dragged.blockWidth), "the dragged width persists");
  assert.equal(dragged.ariaNow, String(dragged.blockWidth), "the divider reports its width");

  // ESC belongs to the panel in this composition; nothing collapses silently.
  await page.locator("#taskDetailToggleFocus").click();
  await page.waitForTimeout(250);
  assert.equal(await page.locator("#inspectorEntityHost [data-messages-body]").isVisible(), true,
    "the column stays open next to the edit form");
  await page.evaluate(() => { document.activeElement?.blur?.(); });
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);
  assert.equal(await page.evaluate(() => Boolean(NRCInspector.current())), true, "ESC leaves edit mode, not the panel");
  assert.equal(await page.locator("#taskDetailDesc").count(), 0, "the edit form is closed");
  assert.equal(await page.locator("#inspectorEntityHost [data-messages-body]").isVisible(), true,
    "the messages column is untouched by ESC");

  // Narrowing the panel returns to the stacked composition.
  await openTask();
  await page.evaluate(() => { document.querySelector(".agenda-panel").style.width = "440px"; });
  await page.waitForTimeout(300);
  const stacked = await page.evaluate(() => {
    const host = document.querySelector("#inspectorEntityHost");
    return {
      bodyVisible: host.querySelector("[data-messages-body]").offsetParent !== null,
      handle: getComputedStyle(host.querySelector("[data-record-resize]")).display,
      panelDisplay: getComputedStyle(host.querySelector(".task-detail-panel")).display,
    };
  });
  assert.equal(stacked.bodyVisible, false, "the narrow composition closes the block again");
  assert.equal(stacked.handle, "none", "the divider only exists in the column composition");
  await page.evaluate(() => { localStorage.removeItem("nrc.record.messagesWidth"); });
  await page.evaluate(() => { document.querySelector(".agenda-panel").style.removeProperty("width"); });

  for (const theme of ["lupine", "matte-black"]) {
    await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
    await page.evaluate(async () => {
      await NRCInspector.close();
      await NRCInspector.openEntity({ roomId: 0n, type: "task", id: 412n });
    });
    await page.locator("#inspectorEntityHost [data-messages-toggle]").click();
    assert.equal((await messageState()).open, "true", `${theme}: the block opens`);
    await page.locator("#inspectorEntityHost [data-messages-toggle]").click();
    assert.equal((await messageState()).open, "false", `${theme}: the block closes`);
  }

  assert.deepEqual(errors, [], "no page errors");
  console.log("PASS: record panel keeps the document surface, renders markdown messages and keeps ENTER for newlines");
} finally {
  await browser.close();
}
