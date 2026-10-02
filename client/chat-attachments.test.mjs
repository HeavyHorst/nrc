import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const app = readFileSync(new URL("app.js", import.meta.url), "utf8");
const attachments = readFileSync(new URL("attachments.js", import.meta.url), "utf8");
const sendSource = app.slice(app.indexOf("async function sendChatAttachment("), app.indexOf("function handleImageChunk("));

function fixture(options = {}) {
  const sent = [], logs = [], uploads = [];
  const context = vm.createContext({
    HTMLElement: class {}, customElements: { define() {} },
    window: {},
    URLSearchParams, FormData, WebSocket: { OPEN: 1 }, ws: { readyState: 1 },
    nicknameReceived: true, currentRoomId: 7n, currentWorkspaceId: "alice-private",
    retainedRoomStates: new Map([[7n, "enabled"]]),
    isDMConversation: () => false,
    pendingMessages: new Map([[1, {}]]), roomHistory: new Map(),
    logMessage: (...args) => logs.push(args),
    sendRawProtocolMessage: (content) => {
      sent.push(content);
      return { clientReqId: 1, clientMessageId: "abc", retained: true };
    },
    fetch: async (url, request) => {
      uploads.push({ ...request, url });
      await options.wait;
      return { ok: !options.fail, status: 503, text: async () => "offline", json: async () => ({
        fileId: "att_0123456789abcdef0123456789abcdef",
        filename: options.filename || "report.zip", size: 123,
        mimeType: options.mimeType || "application/zip",
      }) };
    },
    console: { error() {} },
  });
  vm.runInContext(attachments + "\n" + sendSource, context);
  return { context, sent, logs, uploads };
}

test("uploads binary once over HTTP and sends only one retained reference", async () => {
  const { context, sent, logs, uploads } = fixture();
  const file = new File(["binary content"], "report.zip");
  await context.sendChatAttachment(file);
  assert.equal(uploads.length, 1);
  assert.equal(uploads[0].url, "/upload?workspace=alice-private");
  assert.equal(uploads[0].body.get("room"), "7");
  assert.equal(await uploads[0].body.get("file").text(), "binary content");
  assert.equal(sent.length, 1);
  assert.deepEqual(JSON.parse(sent[0]), {
    type: "attachment", version: 1, fileId: "att_0123456789abcdef0123456789abcdef",
    filename: "report.zip", size: 123, mimeType: "application/zip",
    url: "/files/att_0123456789abcdef0123456789abcdef?filename=report.zip",
  });
  assert.equal(logs.at(-1)[3].retained, true);
  assert.equal(logs.at(-1)[3].clientMessageId, "abc");
});

test("image references remain inline and filenames cannot inject Markdown or HTML", async () => {
  const { context, sent } = fixture({ filename: "x](evil)<b>&.png", mimeType: "image/png" });
  await context.sendChatAttachment(new File(["image"], "x.png"));
  const attachment = context.parseChatAttachment(sent[0]);
  assert.equal(attachment.filename, "x](evil)<b>&.png");
  assert.equal(context.chatAttachmentMarkdown(attachment), "![x&#93;&#40;evil&#41;&#60;b&#62;&#38;.png](/files/att_0123456789abcdef0123456789abcdef?inline=true&filename=x%5D%28evil%29%3Cb%3E%26.png)");
});

test("attachment parser rejects unsafe references, unknown versions and invalid sizes", () => {
  const { context } = fixture();
  const valid = JSON.parse(context.encodeChatAttachment({fileId: "att_0123456789abcdef0123456789abcdef", filename: "x.pdf", mimeType: "application/pdf", size: 104857600}));
  assert.ok(context.parseChatAttachment(JSON.stringify(valid)));
  for (const invalid of [{version:2}, {url:"https://evil.test/x"}, {fileId:"../x"}, {size:-1}, {size:104857601}, {size:1.5}, {size:"10"}, {filename:null}]) {
    assert.equal(context.parseChatAttachment(JSON.stringify({...valid,...invalid})), null);
  }
  assert.equal(context.parseChatAttachment("[old file](/files/att_id?filename=x)"), null);
  assert.equal(context.parseChatAttachment("null"), null);
});

test("upload failure and over-limit files never send a chat message", async () => {
  const { context, sent, logs, uploads } = fixture({ fail: true });
  await context.sendChatAttachment(new File(["data"], "x.bin"));
  await context.sendChatAttachment({ name: "huge.bin", size: 100 * 1024 * 1024 + 1 });
  assert.equal(uploads.length, 1);
  assert.equal(sent.length, 0);
  assert.match(logs.at(-1)[1], /100 MB limit/);
});

test("room switches and connection replacement during upload cannot misdeliver files", async () => {
  for (const change of [ctx => ctx.currentRoomId = 8n, ctx => ctx.ws = { readyState: 1 }, ctx => ctx.window.NRCAI = {isSullivanView: () => true}]) {
    let finish;
    const { context, sent, logs } = fixture({ wait: new Promise(resolve => finish = resolve) });
    const sending = context.sendChatAttachment(new File(["data"], "x.bin"));
    change(context);
    finish();
    await sending;
    assert.equal(sent.length, 0);
    assert.match(logs.at(-1)[1], /Conversation or connection changed/);
    assert.equal(logs.at(-1)[2], 7n);
  }
});

test("unknown retention state blocks upload before any HTTP request", async () => {
  const { context, uploads } = fixture();
  context.retainedRoomStates.clear();
  await context.sendChatAttachment(new File(["data"], "x.bin"));
  assert.equal(uploads.length, 0);
});

test("Sullivan rejects attachments before upload or room send", async () => {
  const { context, uploads, sent } = fixture();
  context.window.NRCAI = {isSullivanView: () => true};
  await context.sendChatAttachment(new File(["private"], "x.bin"));
  assert.equal(uploads.length, 0);
  assert.equal(sent.length, 0);
});

test("file rows always download, only supported preview families create players", () => {
  const { context } = fixture();
  context.window = {};
  context.document = { createElement: tag => ({tag, children: [], events: {},
    appendChild(child) { this.children.push(child); },
    setAttribute(name, value) { this[name] = value; },
    addEventListener(name, fn) { this.events[name] = fn; },
  }) };
  for (const [mimeType, expected] of [["application/pdf","a"], ["audio/ogg","audio"], ["video/mp4","video"], ["image/png","img"], ["text/html",null], ["application/zip",null]]) {
    const view = context.renderChatAttachment({fileId:"att_0123456789abcdef0123456789abcdef",filename:"<test>.bin",mimeType,size:1536});
    const row = view.children[0];
    assert.equal(row.download, "<test>.bin");
    assert.equal(row.children[1].textContent, "<test>.bin");
    assert.equal(row.children[2].textContent, "1.5 KB");
    assert.doesNotMatch(row.href, /inline=true/);
    const preview = view.children[1];
    assert.equal(preview?.tag || null, expected);
    if (expected === "audio" || expected === "video") {
      assert.equal(preview.preload, "none");
      assert.equal(preview.controls, true);
      assert.notEqual(preview.autoplay, true);
      preview.events.error();
      assert.match(view.children[2].textContent, /PREVIEW UNAVAILABLE/);
      assert.equal(row.download, "<test>.bin");
    }
    if (mimeType === "application/pdf") {
      assert.equal(preview.target, "_blank");
      assert.equal(preview.rel, "noopener noreferrer");
      assert.match(preview.href, /inline=true/);
    }
  }
});
