import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { parse } from "acorn";

const source = readFileSync(new URL("app.js", import.meta.url), "utf8");
const names = new Set(["getMessageText", "isSullivanAuthor", "isAiAnswerMessage", "normalizeAiRunStep", "parseNewMessage"]);
const functions = parse(source, { ecmaVersion: "latest" }).body
  .filter((node) => node.type === "FunctionDeclaration" && names.has(node.id.name))
  .map((node) => source.slice(node.start, node.end)).join("\n");

function messageFrame(author, text) {
  const username = new TextEncoder().encode(author);
  const content = new TextEncoder().encode(text);
  const frame = new DataView(new ArrayBuffer(31 + username.length + content.length));
  frame.setBigUint64(2, 42n);
  frame.setBigUint64(10, 1n);
  frame.setUint16(18, username.length);
  new Uint8Array(frame.buffer, 20, username.length).set(username);
  frame.setUint16(29 + username.length, content.length);
  new Uint8Array(frame.buffer, 31 + username.length).set(content);
  return frame;
}

test("AI DM drops room and workspace progress but preserves answers and other authors", () => {
  const messages = [];
  const context = {
    TextDecoder,
    myNickname: "rene",
    isDMConversation: () => true,
    formatDMDisplayName: (name) => name,
    isAIDMConversation: () => true,
    window: {},
    logMessage: (_type, text) => messages.push(text),
    getVisibleConversationId: () => 42n,
  };
  vm.runInNewContext(functions, context);
  const answer = "**AI RESPONSE · CONTEXT WORKSPACE**\nDone.";
  context.parseNewMessage(messageFrame("sullivan-ai", answer));
  for (const scope of ["ROOM", "WORKSPACE"]) {
    context.parseNewMessage(messageFrame("sullivan", `SEARCHING ${scope} CONTEXT + TRAVERSING GRAPH ...`));
  }
  assert.deepEqual(messages, [answer], "late progress must not become chat history");

  const ordinary = "SEARCHING WORKSPACE CONTEXT + TRAVERSING GRAPH ...";
  context.parseNewMessage(messageFrame("alex", ordinary));
  assert.deepEqual(messages, [answer, ordinary], "other authors must not be filtered");
});
