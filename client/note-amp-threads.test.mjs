import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = fs.readFileSync(path.resolve("client/notes.js"), "utf8");

function loadAmpThreadParser() {
  const context = {
    window: {
      NRCAssets: {
        AssetType: { Note: 5 },
        roomAssets: new Map(),
      },
    },
    document: {
      addEventListener() {},
      getElementById() { return null; },
      querySelector() { return null; },
      querySelectorAll() { return []; },
    },
    currentRoomId: 1n,
    currentWorkspaceId: "workspace",
    requestAnimationFrame() {},
    setTimeout,
    clearTimeout,
    console,
    BigInt,
    Map,
    Set,
    URL,
  };
  vm.runInNewContext(
    `${source}\n;globalThis.ampThreadParser = getAmpThreadReference; globalThis.emptyAmpThreadSourceLine = isEmptyAmpThreadSourceLine;`,
    context,
    { filename: "notes.js" },
  );
  return {
    parse: context.ampThreadParser,
    isEmptySourceLine: context.emptyAmpThreadSourceLine,
  };
}

test("recognizes and canonicalizes Amp thread URLs", () => {
  const { parse } = loadAmpThreadParser();
  const id = "T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9";

  const result = parse(`https://ampcode.com/threads/${id}/?view=full#reply`);

  assert.equal(result.id, id);
  assert.equal(result.url, `https://ampcode.com/threads/${id}`);
});

test("rejects lookalike hosts, insecure URLs, and non-thread paths", () => {
  const { parse } = loadAmpThreadParser();
  const id = "T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9";

  assert.equal(parse(`https://example.com/threads/${id}`), null);
  assert.equal(parse(`https://ampcode.com.example/threads/${id}`), null);
  assert.equal(parse(`http://ampcode.com/threads/${id}`), null);
  assert.equal(parse(`https://ampcode.com/settings/${id}`), null);
});

test("removes orphaned source labels without removing neighboring prose", () => {
  const { isEmptySourceLine } = loadAmpThreadParser();

  assert.equal(isEmptySourceLine("Source:"), true);
  assert.equal(isEmptySourceLine("Source thread:"), true);
  assert.equal(isEmptySourceLine("Source Amp threads:"), true);
  assert.equal(isEmptySourceLine("Quelle: —"), true);
  assert.equal(isEmptySourceLine("Recent change: production validated"), false);
  assert.equal(isEmptySourceLine("Source thread: implementation details"), false);
  assert.equal(isEmptySourceLine("Status date: 2026-09-09"), false);
  assert.equal(isEmptySourceLine("Source: architecture document"), false);
  assert.equal(isEmptySourceLine("Source:", true), false);
});

test("cleans only visual lines containing extracted Amp links", async (t) => {
  const { chromium } = await import("playwright");
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.setContent("<!doctype html><body></body>");
  await page.addScriptTag({
    content: `window.parseMarkdown = (value) => value; window.resolveAttachmentRefs = (value) => value; window.NRCAssets = { AssetType: { Note: 5 }, roomAssets: new Map() }; ${source}`,
  });

  const id = "T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9";
  const href = `https://ampcode.com/threads/${id}`;
  const cases = await page.evaluate(({ href }) => {
    const render = (html) => renderNoteMarkdownPresentation(html).bodyHtml;
    return {
      adjacent: render(`<p>Source: <a href="${href}">thread</a><br>Recent change</p>`),
      divider: render(`<p>Before<br>—<br>Source: <a href="${href}">thread</a><br>After</p>`),
      semantic: render(`<p>Source: <video controls src="/demo.mp4"></video> <a href="${href}">thread</a><br>After</p>`),
      nested: render(`<p><em>Before<br>Source: <a href="${href}">thread</a></em></p>`),
      sourceThread: render(`<p>Source thread: <a href="${href}">thread</a><br>Status date: 2026-09-09</p>`),
      standalone: render(`<p><strong>Source thread:</strong> <a href="${href}">thread</a></p><p>Status date: 2026-09-09</p>`),
      prose: render(`<p>Source thread: <a href="${href}">thread</a> implementation details<br>Status date: 2026-09-09</p>`),
      noLink: render(`<p>Source thread:<br>Status date: 2026-09-09</p>`),
    };
  }, { href });

  assert.equal(cases.adjacent, "<p>Recent change</p>");
  assert.equal(cases.divider, "<p>Before<br>—<br>After</p>");
  assert.match(cases.semantic, /^<p>Source: <video controls="" src="\/demo\.mp4"><\/video> <br>After<\/p>$/);
  assert.equal(cases.nested, "<p><em>Before</em></p>");
  assert.equal(cases.sourceThread, "<p>Status date: 2026-09-09</p>");
  assert.equal(cases.standalone, "<p>Status date: 2026-09-09</p>");
  assert.equal(cases.prose, "<p>Source thread:  implementation details<br>Status date: 2026-09-09</p>");
  assert.equal(cases.noLink, "<p>Source thread:<br>Status date: 2026-09-09</p>");
});

test("HTML notes extract threads in share, preview and edit without changing source or sandbox", async (t) => {
  const { chromium } = await import("playwright");
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage({ serviceWorkers: "block" });
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.route("http://nrc.test/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    const file = path.resolve("client", `.${pathname === "/" ? "/index.html" : pathname}`);
    if (fs.existsSync(file)) await route.fulfill({ path: file });
    else await route.fulfill({ status: 404, body: "Not found" });
  });
  await page.goto("http://nrc.test");
  await page.waitForFunction(() => window.NRCNotes && window.NRCHTMLNotes);
  const href = "https://ampcode.com/threads/T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9";
  const original = `<!doctype html><html lang="de"><head><style>.runbook { padding: 12px; color: var(--nrc-text); }</style></head><body class="runbook"><h2>HTML runbook</h2><p>Keep this content.</p><footer><p>Source: <a href="${href}?view=full#reply">Import review</a></p><p><a href="${href}">Duplicate</a></p></footer><footer class="ledger">Source: ${href}</footer><p><a href="https://example.com">Other source</a></p><img src="att:0"><script>window.htmlNoteExecuted = true</script></body></html>`;
  await page.evaluate(({ original }) => {
    serverReady = true;
    currentWorkspaceId = "html-thread-test";
    currentRoomId = 7n;
    myNickname = "reviewer";
    const stamp = 1790336880000000000n;
    window.htmlThreadNote = { assetId: 651n, convId: 0n, assetType: 5, owner: "reviewer", createdAt: stamp, updatedAt: stamp, attachments: [],
      preview: JSON.stringify({ title: "HTML runbook", format: "html", project: "NRC", tags: [] }), payload: original };
    NRCAssets.roomAssets.set(0n, new Map([[651n, htmlThreadNote]]));
    NRCLinksUI.loadLinks = async () => {};
    NRCEdges.getEdgesForEntity = () => [];
    NRCEdges.requestEdgePage = async () => ({ edges: [], hasMore: false });
  }, { original });
  for (const theme of ["light", "dark"]) {
    for (const width of [1400, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(theme => {
        document.documentElement.dataset.theme = theme;
        NRCViewManager.setActiveView("noteShare");
        sharedNoteAsset = htmlThreadNote;
        sharedNoteEdges = [];
        renderSharedNoteView();
      }, theme);
      const links = page.locator('.note-share-amp-threads a');
      assert.equal(await links.count(), 1);
      assert.equal(await links.locator('.note-share-link-title').textContent(), "Import review");
      assert.equal(await links.getAttribute("href"), href);
      assert.equal(await links.getAttribute("rel"), "noopener noreferrer");
      const frame = page.locator('.note-share-body iframe');
      assert.equal(await frame.getAttribute("sandbox"), "allow-same-origin");
      const srcdoc = await frame.getAttribute("srcdoc");
      assert.match(srcdoc, /<html lang="de"/);
      assert.match(srcdoc, /body class="runbook"/);
      assert.match(srcdoc, /\.runbook \{/);
      assert.match(srcdoc, /src="att:0"/);
      assert.doesNotMatch(srcdoc, /ampcode\.com|Source:|Duplicate|<script/);
      assert.equal(await page.locator('.note-share-body h2, .note-share-body script').count(), 0, "authored HTML never enters the parent DOM");
      await page.frameLocator('.note-share-body iframe').getByText("Keep this content.").waitFor();
      if (process.env.NRC_SCREENSHOT_DIR) {
        fs.mkdirSync(process.env.NRC_SCREENSHOT_DIR, { recursive: true });
        await page.locator('.note-share-amp-threads').screenshot({ path: `${process.env.NRC_SCREENSHOT_DIR}/html-amp-share-${theme}-${width}.png` });
      }
    }
  }
  await page.evaluate(() => {
    NRCViewManager.setActiveView("notes");
    selectNote(htmlThreadNote, { fromInspector: true, loadDetail: false });
    showNotePreviewPanel(htmlThreadNote);
  });
  assert.equal(await page.locator('[data-resource="threads"] [data-resource-count]').textContent(), "1");
  assert.doesNotMatch(await page.locator('#notePreviewBody iframe').getAttribute("srcdoc"), /ampcode\.com/);
  await page.evaluate(() => switchToEditPanel());
  assert.equal(await page.locator('[data-resource="threads"] [data-resource-count]').textContent(), "1");
  assert.equal(await page.locator('#noteDetailContent').inputValue(), original);
  assert.equal(await page.evaluate(() => htmlThreadNote.payload), original);
  assert.equal(await page.evaluate(() => window.htmlNoteExecuted), undefined);
});

test("HTML text URLs extract and deduplicate threads without consuming prose or inert content", async (t) => {
  const { chromium } = await import("playwright");
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.setContent("<!doctype html><body></body>");
  await page.addScriptTag({
    content: `window.NRCAssets = { AssetType: { Note: 5 }, roomAssets: new Map() }; ${source}`,
  });
  const href = "https://ampcode.com/threads/T-01a0330e-a729-7219-9a29-9e546b59761a";
  const result = await page.evaluate(({ href }) => {
    const html = `<html><head><style>/* ${href} */</style></head><body><footer class="ledger">Source: ${href}</footer><p>Read (${href}?view=full#reply), then continue.</p><p>Source: <span>${href}</span><br>Keep next line.</p><p>Keep https://example.com and ${href}/invalid.</p><script>const source = "${href}";</script><textarea>${href}</textarea></body></html>`;
    const presentation = renderNoteMarkdownPresentation(html, [], "html");
    const doc = new DOMParser().parseFromString(presentation.bodyHtml, "text/html");
    return { threads: presentation.ampThreads, footer: doc.querySelector("footer")?.outerHTML,
      paragraphs: Array.from(doc.querySelectorAll("p"), p => p.textContent),
      style: doc.querySelector("style").textContent, script: doc.querySelector("script").textContent,
      textarea: doc.querySelector("textarea").textContent };
  }, { href });
  assert.deepEqual(result.threads, [{ id: "T-01a0330e-a729-7219-9a29-9e546b59761a", url: href, label: "T-01a0330e-a729-7219-9a29-9e546b59761a" }]);
  assert.equal(result.footer, undefined);
  assert.deepEqual(result.paragraphs, ["Read (), then continue.", "Keep next line.", `Keep https://example.com and ${href}/invalid.`]);
  assert.equal(result.style, `/* ${href} */`);
  assert.equal(result.script, `const source = "${href}";`);
  assert.equal(result.textarea, href);
});
