// Browser-local fixtures; no server or persistent writes.
// node client/record-document.e2e.mjs
// NRC_SCREENSHOT_DIR=/absolute/path optionally captures the verified states.
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2, serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    try { await route.fulfill({ path: fileURLToPath(new URL(`.${pathname === "/" ? "/index.html" : pathname}`, import.meta.url)) }); }
    catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCNotes && window.NRCInspector);
  await page.evaluate(() => {
    serverReady = true;
    currentWorkspaceId = "document-test";
    currentRoomId = 7n;
    myNickname = "rene";
    const stamp = 1790336880000000000n;
    const task = { id: 259n, convId: 0n, title: "TaskCards beim Import deduplizieren", description: "Verbundene TaskCards werden beim Import mehrfach angelegt.\n\n### Anforderung\n\n- Karten anhand ihrer stabilen ID erkennen.\n- Eine Karte nur einmal anlegen und mehrfach verlinken.", status: 1, priority: 200, color: 0, createdBy: "rene", createdAt: stamp, updatedAt: stamp, attachments: [], assignee: "anna", project: "antares/edupool_boards", dueAt: 0n, blockedBy: 0n };
    roomTasks.set(0n, new Map([[259n, task]]));
    task.description += "\n\nAmp: [Import review](https://ampcode.com/threads/T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9)\n\n[Duplicate](https://ampcode.com/threads/T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9?view=full)";
    const note = { assetId: 4826n, convId: 0n, assetType: 5, owner: "anna", createdAt: stamp, updatedAt: stamp, attachments: [],
      preview: JSON.stringify({ title: "OIDC: Claims und Scopes", project: "antares/edupool_boards", tags: ["oidc", "sso", "claims"], format: "markdown" }),
      payload: "Technische Referenz für die Anbindung eines Identity Providers.\n\n### Vereinbarungen\n\n- Identität und Rollen explizit zuordnen.\n- Benötigte Scopes dokumentieren.\n- Redirect-URIs und Logout-Verhalten prüfen." };
    note.payload += "\n\n[Import review](https://ampcode.com/threads/T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9)";
    NRCAssets.roomAssets.set(0n, new Map([[4826n, note]]));
    for (const [id, parentType, parentId] of [[9001n, 1, 259n], [9002n, 2, 4826n]]) {
      NRCAssets.roomAssets.get(0n).set(id, { assetId: id, convId: 0n, assetType: 1, parentType, parentId,
        owner: "anna", createdAt: stamp, updatedAt: stamp, attachments: [], preview: "Prüfung mit realen Importdaten",
        payload: "Bitte auch **mehrfach verknüpfte Einträge** prüfen. Die Referenzen sollen erhalten bleiben." });
    }
    NRCAssets.requestAsset = (_room, id, options) => { queueMicrotask(() => options.onSuccess({ asset: NRCAssets.roomAssets.get(0n).get(id) })); return 1; };
    NRCLinksUI.loadLinks = async () => {};
    NRCEdges.getEdgesForEntity = () => [{ edgeId: 1n, convId: 0n, sourceType: 2, sourceId: 259n, targetType: 1, targetId: 4826n, relation: 0 }];
    NRCEdges.requestEdgePage = async () => ({ edges: [], hasMore: false });
    NRCDialog.confirm = async () => true;
    NRCViewManager.setActiveView("notes");
  });
  const capture = async name => {
    if (!process.env.NRC_SCREENSHOT_DIR) return;
    await fs.mkdir(process.env.NRC_SCREENSHOT_DIR, { recursive: true });
    await page.locator("#inspector").screenshot({ path: `${process.env.NRC_SCREENSHOT_DIR}/${name}.png` });
  };
  const geometry = async selector => page.locator(selector).evaluate(el => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  });
  await page.evaluate(() => {
    const task = roomTasks.get(0n).get(259n);
    const empty = document.createElement("div");
    empty.innerHTML = buildTaskHeaderMetadata(task);
    if (empty.textContent.includes("COMPLETED")) throw new Error("Open task has completion metadata");
    task.completedAt = 1790231580000000000n;
    task.createdBy = "tag:amp-edupool";
  });
  for (const width of [2200, 1600, 390]) {
    await page.setViewportSize({ width, height: 1000 });
    await page.locator("#inspector").evaluate((el, width) => {
      el.style.width = width === 2200 ? "1100px" : width === 1600 ? "440px" : "";
    }, width);
    for (const theme of ["lupine", "matte-black"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      for (const type of ["task", "note"]) {
        await page.evaluate(async type => {
          await NRCInspector.close();
          await NRCInspector.openEntity({ roomId: 0n, type, id: type === "task" ? 259n : 4826n });
        }, type);
        const title = type === "task" ? ".task-detail-doc-title" : ".note-preview-title";
        const content = type === "task" ? ".task-detail-doc-body" : "#notePreviewBody";
        const editor = type === "task" ? "#taskDetailDesc" : "#noteDetailContent";
        const edit = type === "task" ? "#taskDetailToggleFocus" : "#noteDetailEdit";
        const cancel = type === "task" ? "#taskDetailToggleFocus" : "#noteDetailToggleView";
        await page.locator(title).waitFor();
        if (width > 768) {
          const listHeader = await geometry("#notesPanel .header-register-identity-row");
          const identity = await geometry("#inspectorHeader .inspector-identity-row");
          assert.equal(identity.height, listHeader.height, "record and list identity bands have equal heights");
          assert.equal(identity.y + identity.height, listHeader.y + listHeader.height, "identity bands share a bottom baseline");
          const metadata = page.locator("#inspectorHeader .inspector-metadata");
          assert.deepEqual(await metadata.evaluate(el => ({
            scrollbar: getComputedStyle(el).scrollbarWidth,
            verticalOverflow: el.scrollHeight > el.clientHeight,
          })), { scrollbar: "none", verticalOverflow: false }, "provenance has no visible scrollbar or clipped height");
          if (width === 1600) {
            const fixed = await geometry("#inspectorHeader .header-text");
            await metadata.focus();
            await page.keyboard.press("ArrowRight");
            await page.waitForFunction(() => document.querySelector("#inspectorHeader .inspector-metadata").scrollLeft > 0);
            assert.deepEqual(await geometry("#inspectorHeader .header-text"), fixed, "scrolling provenance leaves record identity fixed");
            await page.keyboard.press("ArrowLeft");
            await page.waitForFunction(() => document.querySelector("#inspectorHeader .inspector-metadata").scrollLeft === 0);
          }
        }
        if (type === "task") {
          assert.equal(await page.locator('.inspector-identity-row .inspector-metadata').count(), 1);
          assert.deepEqual(await page.locator('.inspector-metadata dt').allTextContents(), ['CREATED BY', 'CREATED', 'UPDATED', 'COMPLETED']);
          assert.equal(await page.locator('.record-document-scroll .detail-metadata-ledger').count(), 0, 'no duplicate body provenance');
        }
        assert.ok(await page.locator(`.inspector-mode-row #${type}DetailDelete`).isVisible(), 'delete is available in the read header');
        assert.equal(await page.locator(`.agenda-content #${type}DetailDelete`).count(), 0, 'no bottom delete action');
        await page.evaluate(() => { window.deleteConfirmation = null; NRCDialog.confirm = async message => { window.deleteConfirmation = message; return false; }; });
        await page.locator(`#${type}DetailDelete`).click();
        assert.match(await page.evaluate(() => window.deleteConfirmation), new RegExp(`Delete ${type} #`));
        assert.ok(await page.locator(title).isVisible(), 'cancelling deletion preserves the record');
        await page.evaluate(() => { NRCDialog.confirm = async () => true; });
        const before = { title: await geometry(title), properties: type === "task" ? await geometry(".record-document > .detail-read-register") : null };
        if (type === "note") {
          assert.equal(await page.locator('.note-inline-metadata').count(), 0, 'read mode omits note metadata');
          assert.equal(await page.locator('.note-preview-title nrc-inline-field').count(), 0, 'read mode omits rename');
        }
        const fields = await page.locator(".record-document > .detail-read-register .inline-field-label").allTextContents();
        assert.equal(await page.locator(title).evaluate(el => getComputedStyle(el).textTransform), "none");
        assert.equal(await page.locator('.document-resources [data-resource-open="true"]').count(), 0, "no resource tab is selected by default");
        const send = await geometry('.task-comment-send');
        const footer = await geometry('.task-comment-composer-meta');
        const input = await geometry('.task-comment-input-container');
        assert.ok(send.y >= footer.y && send.y + send.height <= footer.y + footer.height, 'send button fits inside footer');
        const inset = await page.locator('.task-comment-composer-meta').evaluate(el => parseFloat(getComputedStyle(el).paddingLeft));
        assert.equal(input.x + input.width - send.x - send.width, inset, 'send has the same right inset as the footer left inset');
        assert.equal(await page.locator('.task-comment-send').textContent(), 'SEND ↵');
        if (width === 2200) {
          const styles = await page.locator('#chatAttach, #chatSend, .task-comment-send').evaluateAll(elements => elements.map(el => {
            const style = getComputedStyle(el);
            return { font: style.font, padding: style.padding, border: style.borderWidth };
          }));
          assert.deepEqual(styles[1], styles[0], 'chat send shares the global file button typography and sizing');
          assert.deepEqual(styles[2], styles[0], 'comment send shares the global file button typography and sizing');
          const dock = await geometry('.document-resources');
          const commentsFooter = await geometry('.task-comment-composer-meta');
          assert.equal(dock.height, commentsFooter.height, 'resource and comment footers include the same border-box height');
          assert.equal(dock.y, commentsFooter.y, 'adjacent footer top borders align');
        }
        await page.locator('[data-resource="links"] [data-resource-toggle]').click();
        assert.ok(await page.locator('[data-resource="links"] .record-resource-body').isVisible());
        assert.equal(await page.locator('[data-resource="links"] [data-resource-count]').textContent(), "1");
        const resources = await geometry('.document-resources');
        const documentBox = await geometry('.task-detail-tab-content');
        assert.ok(Math.abs(resources.y + resources.height - documentBox.y - documentBox.height) < 2, "resources dock at the document bottom even for short content");
        const strips = await page.locator('.document-resources [data-resource-toggle]').evaluateAll(els => els.map(el => el.getBoundingClientRect().y));
        assert.ok(strips.every(y => Math.abs(y - strips[0]) < 1), "all resource counters share one row");
        const actionBounds = await page.locator('.document-resources').evaluate(bar => {
          const bounds = bar.getBoundingClientRect();
          return [...bar.querySelectorAll('.document-resource-action > button, .document-resource-action > nrc-inline-field > button')].map(button => {
            const rect = button.getBoundingClientRect();
            return { text: button.textContent, left: rect.left - bounds.left, right: bounds.right - rect.right,
              scrollWidth: button.scrollWidth, clientWidth: button.clientWidth };
          });
        });
        assert.ok(actionBounds.every(b => b.left >= 0 && b.right >= 0 && b.scrollWidth <= b.clientWidth),
          `${type}/${theme}/${width}: resource actions fit without horizontal clipping: ${JSON.stringify(actionBounds)}`);
        assert.equal(await page.locator('[data-resource="links"] .note-links-header, [data-resource="links"] .task-detail-links-header').count(), 0, "no repeated links heading");
        await page.locator(`#${type}CommentInput`).fill('Draft survives collapse');
        const expandedDocument = await geometry('.task-detail-tab-content');
        await page.locator('[data-messages-toggle]').click();
        assert.ok(await page.locator('[data-messages-body]').isHidden(), 'messages collapse to their header');
        const collapsedDocument = await geometry('.task-detail-tab-content');
        assert.ok(collapsedDocument.height > expandedDocument.height || collapsedDocument.width > expandedDocument.width, 'collapsing reclaims document space');
        await page.locator('[data-messages-toggle]').click();
        assert.equal(await page.locator(`#${type}CommentInput`).inputValue(), 'Draft survives collapse');
        await page.locator(`#${type}CommentInput`).fill('');
        assert.ok(await page.locator('[data-messages-stream]').isVisible());
        assert.equal(await page.locator('.record-message').count(), 1, "the comment history renders without opening a tab");
        assert.match(await page.locator('.record-message').textContent(), /Referenzen sollen erhalten bleiben/);
        assert.ok(await page.locator(`#${type}CommentInput`).isVisible(), "composer is visible without opening a tab");
        await page.locator(`#${type}CommentInput`).focus();
        await page.locator(`#${type}CommentInput`).press("Escape");
        await page.locator(title).click();
        assert.ok(await page.locator(`#${type}CommentInput`).isVisible(), "Escape and blur never hide comments");
        await capture(`${type}-${theme}-${width}-read`);
        {
          const threads = page.locator('.document-resources [data-resource="threads"]');
          assert.equal(await threads.locator('[data-resource-count]').textContent(), "1");
          await threads.locator('[data-resource-toggle]').click();
          assert.ok(await threads.locator('.record-resource-body').isVisible());
          assert.equal(await page.locator('.document-resources [data-resource-open="true"]').count(), 1, "threads replace the links panel");
          const threadLink = threads.locator('a');
          assert.equal(await threadLink.count(), 1, 'thread references are deduplicated');
          assert.equal(await threadLink.textContent(), 'Import review');
          assert.equal(await threadLink.getAttribute('href'), 'https://ampcode.com/threads/T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9');
          assert.equal(await page.locator(content).locator('a[href*="ampcode.com/threads/"]').count(), 0, 'thread links move out of the document body');
          await capture(`${type}-${theme}-${width}-amp-threads`);
        }
        if (width === 390) {
          await page.locator('.document-resources').scrollIntoViewIfNeeded();
          await capture(`${type}-${theme}-${width}-resources`);
        }
        await page.locator('[data-resource="attachments"] [data-resource-toggle]').click();
        await page.locator(edit).click();
        await page.locator(editor).waitFor();
        if (type === "task") assert.equal(await page.locator('.inspector-identity-row .inspector-metadata').count(), 1, 'edit mode preserves header metadata');
        assert.ok(await page.locator(`.inspector-mode-row #${type}DetailDelete`).isVisible(), 'delete stays in the edit header');
        assert.equal(await page.locator('.document-resources [data-resource="threads"]').getAttribute('data-resource-open'), 'false', "attachments replace the Amp threads panel");
        assert.equal(await page.locator('.document-resources [data-resource="threads"] [data-resource-count]').textContent(), '1', 'edit retains the threads register');
        if (type === "task") assert.match(await page.locator(editor).inputValue(), /Amp: \[Import review\]\(https:\/\/ampcode.com\/threads\//, 'editing preserves original Markdown');
        assert.ok(await page.locator('.record-message').isVisible(), "comments stay visible during content editing");
        // Focusing the editor on a phone may scroll the document. Compare from
        // the same scroll origin, then exercise scrolling separately below.
        await page.locator(".record-document-scroll").evaluate(el => el.scrollTop = 0);
        const after = { title: await geometry(title), properties: await geometry(".record-document > .detail-read-register") };
        for (const part of type === "task" ? ["title", "properties"] : ["title"]) for (const axis of type === "task" ? ["x", "y", "width", "height"] : ["x", "y", "width"]) {
          assert.ok(Math.abs(before[part][axis] - after[part][axis]) <= 1, `${type}/${theme}/${width}: stable ${part}.${axis}: ${before[part][axis]} -> ${after[part][axis]}`);
        }
        if (type === "task") assert.deepEqual(await page.locator(".record-document > .detail-read-register .inline-field-label").allTextContents(), fields);
        else {
          assert.ok(await page.locator('.note-inline-metadata').isVisible(), 'edit retains note metadata');
          assert.ok(await page.locator('.note-preview-title nrc-inline-field').isVisible(), 'edit retains rename');
        }
        assert.equal(await page.locator('[data-resource="attachments"]').getAttribute("data-resource-open"), "true", "disclosures survive entering edit");
        await page.locator('[data-resource="attachments"] [data-resource-toggle]').click();
        assert.equal(await page.locator('.document-resources [data-resource-open="true"]').count(), 0, "clicking the active resource clears the selection");
        await page.locator('[data-resource="files"] [data-resource-toggle]').click();
        assert.equal(await page.locator('.document-resources [data-resource-open="true"]').count(), 1);
        assert.ok(await page.locator('[data-resource="files"] .record-resource-body').isVisible());
        assert.equal(await page.locator('[data-resource="files"] .record-resource-body .panel-header').count(), 0, "no second toolbar is rendered inside Files");
        assert.equal(await page.locator('[data-resource="files"] > .document-resource-action').count(), 0, "Files reuses Attach and Link");
        assert.ok(await page.locator('[data-resource="attachments"] > .document-resource-action').isVisible());
        assert.ok(await page.locator('[data-resource="links"] > .document-resource-action').isVisible());
        assert.ok(!(await page.locator('[data-resource="links"] .record-resource-body').isVisible()));
        assert.ok(await page.locator(`#inspectorHeader #${type}DetailSave`).isVisible(), "save remains in the fixed header");
        assert.equal(await page.locator(cancel).textContent(), "CANCEL");
        await page.locator(".record-document-scroll").evaluate(el => el.scrollTop = 0);
        await capture(`${type}-${theme}-${width}-edit`);
        const deleteBox = await geometry(`#${type}DetailDelete`);
        const panelBox = await geometry("#inspector");
        assert.ok(deleteBox.y + deleteBox.height <= panelBox.y + panelBox.height, "delete action stays inside the panel");
        await page.locator(cancel).click();
        assert.equal(await page.locator('[data-resource="attachments"]').getAttribute("data-resource-open"), "false", "clean cancel preserves resource state");
        assert.equal(await page.locator('[data-resource="files"]').getAttribute("data-resource-open"), "true", "selected resource survives cancel");
        await page.locator(edit).click();
        const original = await page.locator(editor).inputValue();
        await page.locator(editor).fill(`${original}\n\nUnsaved addition`);
        assert.equal(await page.locator('[data-save-state]').textContent(), "UNSAVED");
        await page.locator(cancel).click();
        await page.locator(content).waitFor();
        assert.doesNotMatch(await page.locator(content).textContent(), /Unsaved addition/, "cancel discards only the draft");
        assert.equal(await page.locator('[data-resource="attachments"]').getAttribute("data-resource-open"), "false", "disclosures survive leaving edit");
        await page.locator('[data-resource="files"] [data-resource-toggle]').click();
        await page.locator(edit).click();
        assert.equal(await page.locator('.document-resources [data-resource-open="true"]').count(), 0, "no selection survives entering edit");
        await page.locator(cancel).click();
        assert.equal(await page.locator('.document-resources [data-resource-open="true"]').count(), 0, "no selection survives returning to read");
        assert.ok(await page.locator("#inspector").evaluate(el => el.scrollWidth <= el.clientWidth + 1), "no horizontal panel overflow");
      }
    }
  }
  // Long Markdown and HTML keep the resources reachable and the HTML sandbox.
  await page.evaluate(() => {
    const note = NRCAssets.roomAssets.get(0n).get(4826n);
    note.payload = "# First section\n\n" + "A long paragraph with useful reference text.\n\n".repeat(120) + "# Final section\n\nDone.";
    showNotePreviewPanel(note);
  });
  const dockBefore = await geometry('.document-resources');
  assert.equal(await page.locator('.note-sections-toggle').getAttribute('aria-expanded'), 'false', 'contents start collapsed');
  assert.ok(await page.locator('.note-section-jumps a').first().isHidden());
  await page.locator('.note-sections-toggle').click();
  const tocHeight = (await geometry('.note-section-jumps')).height;
  await page.locator('.note-sections-toggle').click();
  assert.ok(await page.locator('.note-section-jumps a').first().isHidden());
  assert.ok((await geometry('.note-section-jumps')).height < tocHeight, 'collapsed contents reclaim vertical space');
  await page.evaluate(() => showNotePreviewPanel(currentDetailNote));
  assert.equal(await page.locator('.note-sections-toggle').getAttribute('aria-expanded'), 'false', 'contents state survives rerender');
  await page.locator('.note-sections-toggle').click();
  const emptyThreads = page.locator('[data-resource="threads"]');
  assert.equal(await emptyThreads.locator('[data-resource-count]').textContent(), '0', 'notes without thread links retain the tab');
  await emptyThreads.locator('[data-resource-toggle]').click();
  assert.ok(await emptyThreads.getByText('NO AMP THREADS', { exact: true }).isVisible());
  await emptyThreads.locator('[data-resource-toggle]').click();
  await page.locator('.note-section-jumps a').last().click();
  assert.ok(await page.locator(".record-document-scroll").evaluate(el => el.scrollTop > 0), "long document content scrolls independently");
  assert.deepEqual(await geometry('.document-resources'), dockBefore, "scrolling content never moves the resources");
  await page.evaluate(() => {
    const note = NRCAssets.roomAssets.get(0n).get(4826n);
    note.preview = JSON.stringify({ ...JSON.parse(note.preview), format: "html" });
    note.payload = "<h1>HTML document</h1><p>Sandboxed content</p>";
    showNotePreviewPanel(note);
  });
  await page.locator(".note-html-frame").waitFor();
  assert.equal(await page.locator(".note-html-frame").getAttribute("sandbox"), "allow-same-origin", "existing script-free sandbox is unchanged");
  for (const [width, height, railWidth] of [[1600, 1200, 660], [2200, 1000, 1100], [390, 844, 0], [1600, 600, 440]]) {
    await page.setViewportSize({ width, height });
    await page.locator("#inspector").evaluate((el, railWidth) => el.style.width = railWidth ? `${railWidth}px` : "", railWidth);
    await page.evaluate(async () => {
      await NRCInspector.close();
      await NRCInspector.openEntity({ roomId: 0n, type: "note", id: 4826n });
    });
    for (const theme of ["lupine", "matte-black"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await page.evaluate(() => {
        currentDetailNote.payload = `<h1>HTML document</h1>${"<p>Sandboxed content: the document scrolls inside the frame.</p>".repeat(80)}`;
        showNotePreviewPanel(currentDetailNote);
      });
      const frame = await geometry(".note-html-frame");
      const column = await geometry(".record-document-scroll");
      const title = await geometry(".note-preview-title");
      assert.ok(Math.abs(frame.y - (title.y + title.height)) < 2, "HTML starts directly below the title");
      assert.ok(Math.abs(frame.y + frame.height - (column.y + column.height)) < 2, "HTML fills the document column, including tall and short viewports");
      assert.ok(await page.locator(".record-document-scroll").evaluate(el => el.scrollHeight <= el.clientHeight + 1), "outer document has no second scroll area");
      await page.waitForFunction(() => {
        const doc = document.querySelector(".note-html-frame").contentDocument;
        return doc?.scrollingElement?.scrollHeight > doc.scrollingElement.clientHeight;
      });
      await capture(`html-note-${width}x${height}-${theme}`);
    }
  }
  await page.locator("#noteDetailEdit").click();
  assert.equal(await emptyThreads.locator('[data-resource-count]').textContent(), '0', 'HTML edit also retains the empty tab');
  assert.equal(await page.locator("#noteDetailFormat").inputValue(), "html");
  assert.ok(await page.locator(".note-html-security-note").isVisible());
  await page.evaluate(() => {
    window.commentSends = [];
    NRCAssets.sendCreateAssetComment = (_room, _id, text) => { commentSends.push(text); return true; };
  });
  await page.locator('#noteCommentInput').fill('First line');
  await page.locator('#noteCommentInput').press('Shift+Enter');
  await page.locator('#noteCommentInput').pressSequentially('Second line');
  assert.deepEqual(await page.evaluate(() => commentSends), [], "Shift+Enter never sends");
  await page.locator('#noteCommentInput').press('Enter');
  assert.deepEqual(await page.evaluate(() => commentSends), ['First line\nSecond line'], "Enter sends once");
  await page.locator('#noteCommentInput').fill('Follow-up');
  await page.locator('#noteCommentSend').click();
  assert.deepEqual(await page.evaluate(() => commentSends), ['First line\nSecond line', 'Follow-up']);
  assert.equal(await page.locator('#noteCommentInput').inputValue(), '');
  assert.ok(await page.locator('#noteCommentInput').isVisible(), "sending and blur leave the composer visible");
  await page.evaluate(() => {
    NRCAssets.roomAssets.get(0n).delete(9002n);
    showNotePreviewPanel(NRCAssets.roomAssets.get(0n).get(4826n));
  });
  assert.ok(await page.locator('.record-messages-empty').isVisible(), "empty history remains visible too");
  assert.ok(await page.locator('#noteCommentInput').isVisible());
  await page.evaluate(() => NRCAssets.roomAssets.get(0n).delete(9001n));
  for (const width of [1600, 390]) {
    await page.setViewportSize({ width, height: 1000 });
    await page.locator('#inspector').evaluate((el, width) => el.style.width = width === 1600 ? '440px' : '', width);
    for (const theme of ['lupine', 'matte-black']) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      for (const type of ['task', 'note']) {
        const openRecord = async (options = {}) => page.evaluate(async ({ type, options }) => {
          await NRCInspector.close();
          await NRCInspector.openEntity({ roomId: 0n, type, id: type === 'task' ? 259n : 4826n }, options);
        }, { type, options });
        const rerender = async () => page.evaluate(type => {
          if (type === 'task') showTaskDetailPanel(currentDetailTask);
          else showNotePreviewPanel(currentDetailNote);
        }, type);
        await openRecord();
        const toggle = page.locator('[data-messages-toggle]');
        const input = page.locator(`#${type}CommentInput`);
        assert.equal(await toggle.getAttribute('aria-expanded'), 'false', 'empty records start collapsed');
        assert.ok(await page.locator('[data-messages-body]').isHidden());
        await capture(`${type}-${theme}-${width}-empty`);
        await toggle.click();
        assert.ok(await input.isVisible(), 'opening empty messages exposes the composer');
        await input.fill('First message draft');
        await rerender();
        assert.equal(await toggle.getAttribute('aria-expanded'), 'true', 'manual opening survives rerender');
        assert.equal(await input.inputValue(), 'First message draft');
        await toggle.click();
        await rerender();
        assert.equal(await toggle.getAttribute('aria-expanded'), 'false', 'manual collapse survives rerender');
        await toggle.click();
        assert.equal(await input.inputValue(), 'First message draft', 'collapse preserves the draft');
        await input.fill('');
        await openRecord({ subview: 'comments' });
        assert.equal(await toggle.getAttribute('aria-expanded'), 'true', 'explicit comments navigation opens empty messages');
        assert.ok(await input.isVisible());
      }
    }
  }
  await page.evaluate(async () => {
    await NRCInspector.close();
    roomTasks.get(0n).get(259n).description = "";
    await NRCInspector.openEntity({ roomId: 0n, type: "task", id: 259n });
  });
  const emptyTaskThreads = page.locator('[data-resource="threads"]');
  assert.equal(await emptyTaskThreads.locator('[data-resource-count]').textContent(), '0', 'tasks without descriptions retain the empty threads register');
  await emptyTaskThreads.locator('[data-resource-toggle]').click();
  assert.ok(await emptyTaskThreads.getByText('NO AMP THREADS', { exact: true }).isVisible());
  assert.ok(await page.getByText('No description', { exact: true }).isVisible());
  assert.deepEqual(errors, []);
  console.log("PASS: stable task/note geometry, compact resources, persistent comments and sending, cancel, long content and HTML; two themes at 2200/1600/390px");
} finally {
  await browser.close();
}
