import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const source = fs.readFileSync(fileURLToPath(new URL("./note-html.js", import.meta.url)), "utf8");

function loadHTMLNotes() {
  const document = {
    addEventListener() {},
    querySelectorAll() { return []; },
    documentElement: {},
  };
  const window = {
    addEventListener() {},
    location: { origin: "https://nrc.example" },
    open() {},
  };
  class MutationObserver {
    observe() {}
  }
  vm.runInNewContext(source, { window, document, URL, MutationObserver, console });
  return window.NRCHTMLNotes;
}

test("HTML note format is explicit and legacy values remain Markdown", () => {
  const notes = loadHTMLNotes();
  assert.equal(notes.normalizeFormat("html"), "html");
  assert.equal(notes.normalizeFormat("HTML"), "html");
  assert.equal(notes.normalizeFormat(""), "markdown");
  assert.equal(notes.normalizeFormat("unknown"), "markdown");
});

test("HTML note sandbox never grants script execution", () => {
  assert.match(source, /setAttribute\("sandbox", "allow-same-origin"\)/);
  assert.doesNotMatch(source, /allow-scripts/);
  assert.match(source, /SVG_ANIMATION_ELEMENTS/);
  for (const element of ["animate", "animatemotion", "animatetransform", "discard", "set"]) {
    assert.match(source, new RegExp(`"${element}"`));
  }
  assert.match(source, /"connect-src 'none'"/);
  assert.match(source, /"script-src 'none'"/);
  assert.match(source, /"form-action 'none'"/);
  assert.match(source, /"frame-src 'none'"/);
  assert.match(source, /"object-src 'none'"/);
});

test("HTML note renderer exposes stable NRC theme aliases", () => {
  for (const token of [
    "--nrc-bg",
    "--nrc-surface",
    "--nrc-text",
    "--nrc-border",
    "--nrc-panel-border",
    "--nrc-control-border",
    "--nrc-panel-radius",
    "--nrc-control-radius",
    "--nrc-accent",
    "--nrc-success",
    "--nrc-danger",
    "--nrc-font-mono",
  ]) {
    assert.match(source, new RegExp(token));
  }
});

test("HTML note renderer uses the NRC scrollbar inside its iframe", () => {
  assert.match(source, /\*::\-webkit-scrollbar \{ width: 0\.375rem; height: 0\.375rem;/);
  assert.match(source, /\*::\-webkit-scrollbar-track \{ background: var\(--nrc-bg\);/);
  assert.match(source, /\*::\-webkit-scrollbar-thumb \{ background: var\(--nrc-border\);/);
});
