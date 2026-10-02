import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = fs.readFileSync(path.resolve("client/view-manager.js"), "utf8");

function loadViewManager() {
  const elements = new Map([
    ["chatDialog", { style: {} }],
    ["notesPanel", { style: {} }],
  ]);
  const events = [];
  const historyLoads = [];
  const unreadViewChanges = [];
  const systemLogExits = [];
  const html = fs.readFileSync(path.resolve("client/index.html"), "utf8");
  const headerClasses = new Set(html.match(/class="(chat-header [^"]+)"/)[1].split(" "));
  const chatHeader = { classList: { toggle(name, enabled) {
    if (enabled) headerClasses.add(name);
    else headerClasses.delete(name);
  } } };
  const window = {
    NRCAI: {
      isWorkbenchBusy: () => false,
      updateAskContextChip() {},
    },
    NRCChatUnread: {
      onViewChanged: (view) => {
        events.push(`unread:${view}`);
        unreadViewChanges.push(view);
      },
    },
    NRCSystemLog: {
      exit: (options) => systemLogExits.push(options),
    },
  };
  const document = {
    body: { classList: { toggle() {} } },
    getElementById: (id) => elements.get(id) || null,
    querySelector: (selector) => selector === ".chat-header" ? chatHeader : null,
  };
  const context = vm.createContext({
    window,
    document,
    currentRoomId: 42n,
    loadRoomHistory: (roomId) => {
      events.push(`history:${roomId}`);
      historyLoads.push(roomId);
    },
  });
  vm.runInContext(source, context, { filename: "view-manager.js" });
  return { elements, events, viewManager: window.NRCViewManager, historyLoads, systemLogExits, unreadViewChanges, headerClasses };
}

test("chat metadata band persists across view changes", () => {
  const { viewManager, headerClasses } = loadViewManager();
  assert.equal(headerClasses.has("metadata-header-register"), true);
  for (const view of ["sullivan", "chat", "systemLog", "notes", "chat"]) {
    viewManager.setActiveView(view);
    assert.equal(headerClasses.has("metadata-header-register"), true, view);
  }
});

test("leaving Sullivan through Notes restores normal chat history", () => {
  const { viewManager, historyLoads } = loadViewManager();

  viewManager.setActiveView("sullivan");
  viewManager.setActiveView("notes");
  viewManager.setActiveView("chat");

  assert.deepEqual(historyLoads, [42n, 42n]);
});

test("returning to Chat renders current history before clearing unread", () => {
  const { events, viewManager } = loadViewManager();

  viewManager.setActiveView("notes");
  viewManager.setActiveView("chat");

  assert.deepEqual(events, ["unread:notes", "history:42", "unread:chat"]);
});

test("view changes notify the chat unread controller", () => {
  const { viewManager, unreadViewChanges } = loadViewManager();

  viewManager.setActiveView("notes");
  viewManager.setActiveView("chat");

  assert.deepEqual(unreadViewChanges, ["notes", "chat"]);
});

test("System Log is a peer view that uses the shared ledger and exits through View Manager", () => {
  const { elements, viewManager, systemLogExits } = loadViewManager();

  viewManager.setActiveView("systemLog");
  assert.equal(viewManager.getActiveView(), "systemLog");
  assert.equal(elements.get("chatDialog").style.display, "flex");

  viewManager.setActiveView("notes");
  assert.equal(systemLogExits.length, 1);
  assert.equal(systemLogExits[0].restoreView, false);
  assert.equal(viewManager.getActiveView(), "notes");
});
