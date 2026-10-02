import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = fs.readFileSync(path.resolve("client/detail-ui.js"), "utf8");

function loadDetailUI(maxCommentBytes = 5, parseMarkdown = null, coarsePointer = false) {
  const window = { NRCAssets: { MAX_PAYLOAD_LENGTH: maxCommentBytes }, matchMedia: () => ({ matches: coarsePointer }) };
  if (parseMarkdown) window.parseMarkdown = parseMarkdown;
  vm.runInNewContext(source, { window, TextEncoder }, { filename: "detail-ui.js" });
  return window.NRCDetailUI;
}

// Mirrors the markup renderMessagesArea produces, with just enough DOM surface
// for the binding: attributes, datasets, the byte counter and the stream.
function makeMessagesDom() {
  const attributes = new Map();
  const byteToggles = [];
  const byteCount = {
    textContent: "",
    classList: { toggle: (name, enabled) => byteToggles.push([name, enabled]) },
  };
  const input = {
    value: "",
    ownerDocument: { activeElement: null },
    setAttribute: (name, value) => attributes.set(name, value),
    focus() {},
  };
  const send = { disabled: false };
  const hint = { textContent: "M" };
  const strip = {
    dataset: {},
    setAttribute: (name, value) => attributes.set(`strip:${name}`, value),
    querySelector: (selector) => (selector === "i" ? hint : null),
  };
  const composerBar = { setAttribute: (name, value) => attributes.set(`bar:${name}`, value) };
  const composer = {
    dataset: { composerOpen: "false" },
    querySelector: (selector) => {
      if (selector === ".task-comment-byte-count") return byteCount;
      if (selector === "[data-composer-toggle]") return composerBar;
      return null;
    },
  };
  const stream = { scrollTop: 0, scrollHeight: 500 };
  const area = {
    dataset: { messagesOpen: "false" },
    querySelector: (selector) => {
      if (selector === "[data-messages-toggle]") return strip;
      if (selector === "[data-messages-stream]") return stream;
      if (selector === "[data-composer]") return composer;
      return null;
    },
    querySelectorAll: () => [],
  };
  const root = {
    querySelector: (selector) => {
      if (selector === "[data-messages-area]") return area;
      if (selector === "#commentInput") return input;
      if (selector === "#commentSend") return send;
      return null;
    },
  };
  return { root, area, strip, hint, composer, composerBar, input, send, byteCount, stream, attributes, byteToggles };
}

function bindMessages(dom, { onSubmit, onDelete = () => {}, onToggle } = {}) {
  return loadDetailUI(5).bindMessagesArea({
    root: dom.root,
    inputId: "commentInput",
    sendId: "commentSend",
    onSubmit,
    onDelete,
    onToggle,
  });
}

test("metadata ledger renders explicit labels, actor roles, and escaped values", () => {
  const detailUI = loadDetailUI();

  const html = detailUI.renderMetadataLedger([
    { label: "CREATED BY", value: "ALICE & BOB", role: "actor" },
    { label: "UPDATED", value: "2026-08-24 12:30" },
  ]);

  assert.equal(
    html,
    '<dl class="detail-metadata-ledger"><div><dt>CREATED BY</dt><dd class="identity-actor">ALICE &amp; BOB</dd></div><div><dt>UPDATED</dt><dd>2026-08-24 12:30</dd></div></dl>',
  );
});

test("the messages register line states its count in the count cell", () => {
  const detailUI = loadDetailUI();

  const empty = detailUI.renderMessagesArea({ messagesHtml: "", count: 0, preview: "", inputId: "in", sendId: "send" });
  assert.match(empty, /<b class="record-strip-label">MESSAGES<\/b>/);
  assert.match(empty, /<span class="record-strip-count">0<\/span>/);
  assert.match(empty, /<span class="record-strip-preview">WRITE THE FIRST ONE — MARKDOWN SUPPORTED<\/span>/);

  const one = detailUI.renderMessagesArea({ messagesHtml: "", count: 1, preview: "KIM: hi", inputId: "in", sendId: "send" });
  assert.match(one, /<span class="record-strip-count">1<\/span>/);
  assert.match(one, /<span class="record-strip-preview">KIM: hi<\/span>/);
});

test("the messages column width clamps to its band and falls back to the default", () => {
  const detailUI = loadDetailUI();

  assert.equal(detailUI.clampMessagesWidth(360), 360);
  assert.equal(detailUI.clampMessagesWidth(10), 320);
  assert.equal(detailUI.clampMessagesWidth(9999), 640);
  assert.equal(detailUI.clampMessagesWidth("abc"), 360);
  assert.equal(detailUI.clampMessagesWidth(undefined), 360);
});

test("the strip preview drops markdown syntax and names the author", () => {
  const detailUI = loadDetailUI();

  assert.equal(detailUI.messagePreview([]), "");
  assert.equal(
    detailUI.messagePreview([{ owner: "KIM", payload: "## Messprotokoll\n\nWerte **außerhalb** | Tabelle\n\n- Punkt" }]),
    "KIM: Messprotokoll Werte außerhalb Tabelle Punkt",
  );
  assert.equal(
    detailUI.messagePreview([{ owner: "RENE", payload: "`nrc task attach --file a.pdf`" }]),
    "RENE: nrc task attach --file a.pdf",
  );
  assert.equal(
    detailUI.messagePreview([{ owner: "KIM", payload: "x".repeat(120) }]).endsWith("…"),
    true,
  );
});

test("messages render as markdown through the shared renderer", () => {
  const detailUI = loadDetailUI(5, (text) => `<p>rendered:${text}</p>`);

  const html = detailUI.renderMessages({
    comments: [{ assetId: "17", owner: "KIM", createdAt: 1n, payload: "**bold**" }],
    currentUser: "KIM",
    formatTime: () => "11:40",
  });

  assert.match(html, /<article class="record-message" data-asset-id="17">/);
  assert.match(html, /<span class="record-message-author">KIM<\/span>/);
  assert.match(html, /<span class="record-message-time">11:40<\/span>/);
  assert.match(html, /<div class="record-message-body message-content"><p>rendered:\*\*bold\*\*<\/p><\/div>/);
  assert.match(html, /class="btn btn--danger record-message-delete" data-asset-id="17"/);
});

test("messages fall back to escaped text without a markdown renderer and hide delete on foreign messages", () => {
  const detailUI = loadDetailUI();

  const html = detailUI.renderMessages({
    comments: [{ assetId: "18", owner: "RENE", createdAt: 1n, payload: "<script>alert(1)</script>" }],
    currentUser: "KIM",
    formatTime: () => "12:05",
  });

  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.doesNotMatch(html, /<script>/);
  assert.doesNotMatch(html, /record-message-delete/);
});

test("an empty record states that there is nothing to read", () => {
  const detailUI = loadDetailUI();

  const html = detailUI.renderMessages({ comments: [], currentUser: "KIM", formatTime: () => "" });

  assert.equal(html, '<div class="record-messages-empty">NO MESSAGES YET · WRITE THE FIRST ONE</div>');
});

test("the messages block renders closed with its count, preview, and composer bar", () => {
  const detailUI = loadDetailUI();

  const html = detailUI.renderMessagesArea({
    messagesHtml: "<article class=\"record-message\"></article>",
    count: 3,
    preview: "KIM: Shim liegt im Werkzeugkasten",
    inputId: "taskCommentInput",
    sendId: "taskCommentSend",
  });

  assert.match(html, /data-messages-open="false"/);
  assert.match(html, /<b class="record-strip-label">MESSAGES<\/b>/);
  assert.match(html, /<span class="record-strip-count">3<\/span>/);
  assert.match(html, /KIM: Shim liegt im Werkzeugkasten/);
  assert.match(html, /<i class="record-strip-key">\+<\/i>/);
  assert.match(html, /data-composer-open="false"/);
  assert.match(html, /id="taskCommentInput"/);
  assert.match(html, /id="taskCommentSend"/);
  assert.match(html, /<b>ENTER<\/b> SEND/);
  assert.match(html, /<b>SHIFT\+ENTER<\/b> NEW LINE/);
});

test("a restored draft fills the composer and stays escaped", () => {
  const detailUI = loadDetailUI();

  const html = detailUI.renderMessagesArea({
    messagesHtml: "",
    count: 0,
    preview: "",
    open: true,
    composerOpen: true,
    draft: "erste Zeile\n<b>zweite</b>",
    inputId: "taskCommentInput",
    sendId: "taskCommentSend",
  });

  assert.match(html, /<textarea class="task-comment-input" id="taskCommentInput" rows="3" aria-label="Write a message">erste Zeile\n&lt;b&gt;zweite&lt;\/b&gt;<\/textarea>/);
  assert.doesNotMatch(html, /<b>zweite<\/b>/);
});

test("an empty messages block invites the first message", () => {
  const detailUI = loadDetailUI();

  const html = detailUI.renderMessagesArea({
    messagesHtml: "",
    count: 0,
    preview: "",
    inputId: "noteCommentInput",
    sendId: "noteCommentSend",
  });

  assert.match(html, /<span class="record-strip-count">0<\/span>/);
  assert.match(html, /WRITE THE FIRST ONE — MARKDOWN SUPPORTED/);
});

test("opening the block reports its state and scrolls the stream to the end", () => {
  const detailUI = loadDetailUI();
  const dom = makeMessagesDom();
  const states = [];
  const controller = detailUI.bindMessagesArea({
    root: dom.root,
    inputId: "commentInput",
    sendId: "commentSend",
    onSubmit: () => {},
    onDelete: () => {},
    onToggle: (state) => states.push(state),
  });

  dom.strip.onclick();

  assert.equal(dom.area.dataset.messagesOpen, "true");
  assert.equal(dom.attributes.get("strip:aria-expanded"), "true");
  assert.equal(dom.hint.textContent, "−");
  assert.equal(dom.stream.scrollTop, 500);
  assert.equal(states.at(-1).messagesOpen, true);
  assert.equal(states.at(-1).composerOpen, false);
  assert.equal(controller.isMessagesOpen(), true);

  dom.strip.onclick();

  assert.equal(dom.area.dataset.messagesOpen, "false");
  assert.equal(dom.hint.textContent, "+");
  assert.equal(states.at(-1).messagesOpen, false);
  assert.equal(states.at(-1).composerOpen, false);
});

test("the composer bar opens the block and focuses the draft", () => {
  const detailUI = loadDetailUI();
  const dom = makeMessagesDom();
  let focused = 0;
  dom.input.focus = () => { focused += 1; };
  const states = [];

  detailUI.bindMessagesArea({
    root: dom.root,
    inputId: "commentInput",
    sendId: "commentSend",
    onSubmit: () => {},
    onDelete: () => {},
    onToggle: (state) => states.push(state),
  });

  dom.composerBar.onclick();

  assert.equal(dom.area.dataset.messagesOpen, "true");
  assert.equal(dom.composer.dataset.composerOpen, "true");
  assert.equal(dom.attributes.get("bar:aria-expanded"), "true");
  assert.equal(focused, 1);
  assert.equal(states.at(-1).messagesOpen, true);
  assert.equal(states.at(-1).composerOpen, true);
});

test("the composer collapses on Escape and when it loses focus while empty", () => {
  const detailUI = loadDetailUI();
  const dom = makeMessagesDom();
  const stopped = [];

  detailUI.bindMessagesArea({
    root: dom.root,
    inputId: "commentInput",
    sendId: "commentSend",
    onSubmit: () => {},
    onDelete: () => {},
  });

  dom.composerBar.onclick();
  dom.input.onkeydown({ key: "Escape", stopPropagation: () => stopped.push("escape") });
  assert.equal(dom.composer.dataset.composerOpen, "false");
  assert.deepEqual(stopped, ["escape"]);

  dom.composerBar.onclick();
  dom.input.value = "draft";
  dom.input.onblur();
  assert.equal(dom.composer.dataset.composerOpen, "true", "a draft keeps the composer open");

  dom.input.value = "   ";
  dom.input.onblur();
  assert.equal(dom.composer.dataset.composerOpen, "false");
});

test("composer displays its byte limit and submits valid text", () => {
  const detailUI = loadDetailUI();
  const dom = makeMessagesDom();
  const submitted = [];

  detailUI.bindMessagesArea({
    root: dom.root,
    inputId: "commentInput",
    sendId: "commentSend",
    onSubmit: (text) => submitted.push(text),
    onDelete() {},
  });

  dom.input.value = "hello";
  dom.input.oninput();
  assert.equal(dom.byteCount.textContent, "5 B / 5 B");
  assert.equal(dom.send.disabled, false);
  dom.send.onclick();
  assert.deepEqual(submitted, ["hello"]);
  assert.equal(dom.input.value, "");
});

test("state changes report the draft so a re-render can restore it", () => {
  const detailUI = loadDetailUI(4096);
  const dom = makeMessagesDom();
  const states = [];

  detailUI.bindMessagesArea({
    root: dom.root,
    inputId: "commentInput",
    sendId: "commentSend",
    onSubmit: () => {},
    onDelete: () => {},
    onToggle: (state) => states.push(state),
  });

  dom.input.value = "halb geschrieben";
  dom.strip.onclick();

  assert.equal(states.at(-1).draft, "halb geschrieben", "the draft travels with the state");
});

test("composer rejects an oversized draft without clearing it", () => {
  const detailUI = loadDetailUI();
  const dom = makeMessagesDom();
  const submitted = [];

  detailUI.bindMessagesArea({
    root: dom.root,
    inputId: "commentInput",
    sendId: "commentSend",
    onSubmit: (text) => submitted.push(text),
    onDelete() {},
  });

  dom.input.value = "ééé";
  dom.input.oninput();
  assert.equal(dom.byteCount.textContent, "6 B / 5 B");
  assert.equal(dom.send.disabled, true);
  assert.equal(dom.attributes.get("aria-invalid"), "true");
  dom.send.onclick();
  assert.deepEqual(submitted, []);
  assert.equal(dom.input.value, "ééé");
});

for (const coarsePointer of [false, true]) test(`comment shortcuts match chat (touch=${coarsePointer})`, () => {
  const detailUI = loadDetailUI(4096, null, coarsePointer);
  const dom = makeMessagesDom();
  const submitted = [];

  detailUI.bindMessagesArea({
    root: dom.root,
    inputId: "commentInput",
    sendId: "commentSend",
    onSubmit: (text) => submitted.push(text),
    onDelete() {},
  });

  for (const [modifiers, sends] of [
    [{}, !coarsePointer], [{ shiftKey: true }, false], [{ ctrlKey: true }, true],
    [{ metaKey: true }, true], [{ ctrlKey: true, shiftKey: true }, false],
    [{ isComposing: true }, false], [{ ctrlKey: true, isComposing: true }, false],
  ]) {
    submitted.length = 0;
    dom.input.value = "first line";
    let prevented = false;
    let stopped = false;
    dom.input.onkeydown({ key: "Enter", ...modifiers, preventDefault: () => { prevented = true; }, stopPropagation() { stopped = true; } });
    assert.deepEqual(submitted, sends ? ["first line"] : [], JSON.stringify(modifiers));
    assert.equal(prevented, sends);
    assert.equal(stopped, true, "comment Enter never reaches the document save shortcut");
    assert.equal(dom.input.value, sends ? "" : "first line");
  }
});

test("a resource register renders one line carrying its label, count and first entry", () => {
  const detailUI = loadDetailUI();

  const closed = detailUI.renderResourceBlock({
    resource: "files",
    label: "FILES",
    count: 2,
    preview: "Wartungsvertrag 2026",
    bodyHtml: '<section class="file-assets-section"></section>',
  });
  assert.match(closed, /class="record-resource" data-resource="files" data-resource-open="false"/);
  assert.match(closed, /class="record-strip record-resource-strip" type="button" data-resource-toggle aria-expanded="false"/);
  assert.match(closed, /<b class="record-strip-label">FILES<\/b>/);
  assert.match(closed, /<span class="record-strip-count" data-resource-count>2<\/span>/);
  assert.match(closed, /<span class="record-strip-preview" data-resource-preview>Wartungsvertrag 2026<\/span>/);
  assert.match(closed, /<i class="record-strip-state" data-resource-state><\/i>/);
  assert.match(closed, /<div class="record-resource-body"><section class="file-assets-section"><\/section><\/div>/);

  const open = detailUI.renderResourceBlock({
    resource: "links",
    label: "LINKS",
    open: true,
    preview: "#184 & <unsafe>",
    bodyHtml: "<div></div>",
  });
  assert.match(open, /data-resource="links" data-resource-open="true"/);
  assert.match(open, /data-resource-toggle aria-expanded="true"/);
  assert.match(open, /<span class="record-strip-count" data-resource-count><\/span>/, "a module-owned register starts without a count");
  assert.match(open, /<span class="record-strip-preview" data-resource-preview>#184 &amp; &lt;unsafe&gt;<\/span>/);
});

test("resource registers read their state back from the live panel", () => {
  const detailUI = loadDetailUI();
  const files = { dataset: { resource: "files", resourceOpen: "true" } };
  const links = { dataset: { resource: "links", resourceOpen: "false" } };
  const root = { querySelectorAll: (selector) => (selector === "[data-resource]" ? [files, links] : []) };

  const state = detailUI.readResourceState(root);
  assert.equal(state.files, true, "an open register stays open");
  assert.equal(state.links, false, "a closed register stays closed");
  assert.deepEqual(Object.keys(detailUI.readResourceState(null)), [], "a missing panel has no state");
});

test("a resource register opens and closes in place without a re-render", () => {
  const detailUI = loadDetailUI();
  const attributes = new Map();
  const block = { dataset: { resource: "files", resourceOpen: "false" } };
  const toggle = {
    setAttribute: (name, value) => attributes.set(name, value),
    closest: (selector) => (selector === "[data-resource]" ? block : null),
  };
  const listeners = {};
  const root = { addEventListener: (type, handler) => { (listeners[type] ||= []).push(handler); } };
  detailUI.bindResourceBlocks({ root });

  const clickToggle = () => listeners.click.forEach((handler) => handler({
    target: { closest: (selector) => (selector === "[data-resource-toggle]" ? toggle : null) },
  }));

  clickToggle();
  assert.equal(block.dataset.resourceOpen, "true", "the first click opens the register");
  assert.equal(attributes.get("aria-expanded"), "true");

  clickToggle();
  assert.equal(block.dataset.resourceOpen, "false", "the next click closes it");
  assert.equal(attributes.get("aria-expanded"), "false");

  listeners.click.forEach((handler) => handler({ target: { closest: () => null } }));
  assert.equal(block.dataset.resourceOpen, "false", "a click inside the body is not a toggle");
});

test("a second binding on the same panel adds no second toggle", () => {
  const detailUI = loadDetailUI();
  const block = { dataset: { resource: "files", resourceOpen: "false" } };
  const toggle = {
    setAttribute: () => {},
    closest: (selector) => (selector === "[data-resource]" ? block : null),
  };
  const listeners = {};
  const root = { addEventListener: (type, handler) => { (listeners[type] ||= []).push(handler); } };

  // The note and the task panel bind on the shared container; one click must
  // toggle once, not twice.
  detailUI.bindResourceBlocks({ root });
  detailUI.bindResourceBlocks({ root });
  assert.equal(listeners.click.length, 1, "the container keeps one register handler");

  listeners.click[0]({ target: { closest: (selector) => (selector === "[data-resource-toggle]" ? toggle : null) } });
  assert.equal(block.dataset.resourceOpen, "true");
});
