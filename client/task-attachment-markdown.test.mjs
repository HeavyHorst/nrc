import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const attachmentSource = fs.readFileSync(new URL("./attachments.js", import.meta.url), "utf8");
const noteSource = fs.readFileSync(new URL("./notes.js", import.meta.url), "utf8");

test("attachment read ledger shows every file once and preserves preview/download destinations", () => {
  const sandbox = vm.createContext({
    HTMLElement: class {}, customElements: { define() {} },
    URLSearchParams,
    escapeHtml: (value) => String(value).replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;"),
  });
  vm.runInContext(attachmentSource, sandbox);
  const attachments = [
    { fileId: "image", filename: "screen.png", mimeType: "image/png", size: 2048 },
    { fileId: "pdf", filename: "spec.pdf", mimeType: "application/pdf", size: 1024 },
    { fileId: "zip", filename: "source.zip", mimeType: "application/zip", size: 4096 },
    { fileId: "last", filename: '<last>.bin', size: 512 },
  ];
  const html = sandbox.renderAttachmentPreviewStripHtml(attachments);
  assert.match(html, /<nrc-attachment-list /);
  assert.match(html, /ATTACHMENTS \(4\)/);
  assert.equal((html.match(/class="note-link-item"/g) || []).length, 4);
  assert.doesNotMatch(html, /chip|toggle|is-expanded/);
  // The filename is a label; the two operations are row controls.
  assert.doesNotMatch(html, /note-link-target/);
  assert.match(html, /<span class="note-preview-attachment-name" title="screen.png">screen.png<\/span>/);
  assert.match(html, /data-attachment-open data-image="1" data-file-id="image" data-filename="screen.png">OPEN<\/button>/);
  assert.match(html, /data-attachment-open data-image="0" data-file-id="pdf" data-filename="spec.pdf">OPEN<\/button>/);
  assert.match(html, /<a class="btn btn--row" href="\/files\/pdf\?filename=spec.pdf" download="spec.pdf">DOWNLOAD<\/a>/);
  assert.match(html, /<a class="btn btn--row" href="\/files\/zip\?filename=source.zip" download="source.zip">DOWNLOAD<\/a>/);
  // A binary that no viewer renders offers DOWNLOAD only.
  assert.doesNotMatch(html, /data-file-id="zip"[^>]*>OPEN/);
  assert.match(html, /&lt;last&gt;.bin/);
  assert.equal(sandbox.renderAttachmentPreviewStripHtml([]), "");
});

function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} must exist`);

  let depth = 0;
  let bodyStarted = false;
  for (let index = start; index < source.length; index++) {
    if (source[index] === "{") {
      depth++;
      bodyStarted = true;
    } else if (source[index] === "}") {
      depth--;
      if (bodyStarted && depth === 0) return source.slice(start, index + 1);
    }
  }

  assert.fail(`Could not extract ${name}`);
}

test("shared task/note Markdown renderer resolves attachment references", () => {
  const sandbox = {
    parseMarkdown(markdown) {
      assert.equal(markdown, "![Screenshot](/files/file-1?inline=true&filename=shot.png)");
      return '<p><img src="/files/file-1?inline=true&amp;filename=shot.png" alt="Screenshot"></p>';
    },
    attachments: [{ fileId: "file-1", filename: "shot.png" }],
    URLSearchParams,
  };
  vm.createContext(sandbox);
  vm.runInContext(
    `const PROXY_URL = "";\n` +
      `${extractFunction(attachmentSource, "attachmentFileURL")}\n` +
      `${extractFunction(attachmentSource, "getAttachmentRefURL")}\n` +
      `${extractFunction(attachmentSource, "resolveAttachmentRefs")}\n` +
      `${extractFunction(noteSource, "renderNoteMarkdownWithAttachments")}\n` +
      `result = renderNoteMarkdownWithAttachments("![Screenshot](att:0)", attachments);`,
    sandbox,
  );

  assert.equal(
    sandbox.result,
    '<p><img src="/files/file-1?inline=true&amp;filename=shot.png" alt="Screenshot"></p>',
  );
});
