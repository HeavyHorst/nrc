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
