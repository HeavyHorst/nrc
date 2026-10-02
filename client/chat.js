// Client-only chat conveniences. Message content remains ordinary Markdown.
window.NRCChat = (() => {
  const unread = new Map();
  const mentionCache = new WeakMap();
  let loading = false;
  let query = "";
  let room = null;
  let quote = "";
  let restoreTop = null;
  let referenceSearch = null;
  const drafts = new Map();
  let composerContext = null;
  const el = (id) => document.getElementById(id);
  const enabled = () => !systemLogVisible && !window.NRCAI?.isSullivanView?.();
  const atBottom = () => logOutput.scrollHeight - logOutput.scrollTop - logOutput.clientHeight < 48;
  const key = (id) => `nrc-chat-notifications:${currentWorkspaceId}:${id}`;

  function notificationMode(id) {
    try {
      const value = localStorage.getItem(key(id));
      return ["all", "mentions", "off"].includes(value) ? value : "all";
    } catch { return "all"; }
  }

  function mentionPattern(name) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return new RegExp(`(^|[^\\p{L}\\p{N}_@.-])@${escaped}(?![\\p{L}\\p{N}_-]|\\.[\\p{L}\\p{N}])`, "iu");
  }

  function isMention(message) {
    if (!myNickname || message.type !== "Message") return false;
    const cached = mentionCache.get(message);
    if (cached?.name === myNickname && cached.text === message.message) return cached.value;
    const content = document.createElement("div");
    content.innerHTML = parseMarkdown(message.message);
    content.querySelectorAll("blockquote, pre, code, a").forEach((node) => node.remove());
    const value = mentionPattern(myNickname).test(content.textContent);
    mentionCache.set(message, { name: myNickname, text: message.message, value });
    return value;
  }

  function suggestions(text, caret, names) {
    const match = text.slice(0, caret).match(/(?:^|\s)@([^\s@]*)$/u);
    if (!match) return null;
    const replaceRange = [caret - match[1].length - 1, caret];
    return {
      replaceRange,
      suggestions: [...new Set(names)].filter((name) => name.toLowerCase().startsWith(match[1].toLowerCase()))
        .sort().slice(0, 15).map((name) => ({
          label: `@${name}`, title: name, statusName: "USER", type: "mention", replaceRange,
        })),
    };
  }

  function quoteText(author, text) {
    // Limit quoted text, flatten Markdown to text at the call site, then escape
    // punctuation so a quote cannot load images or inject new formatting.
    const escape = (value) => value.replace(/([\\`*_{}\[\]()#+.!<>|~-])/g, "\\$1");
    const excerpt = text.length > 2000 ? `${text.slice(0, 2000)}…` : text;
    return `> ${escape(author.replace(/[\r\n]+/g, " "))}:\n${escape(excerpt).split(/\r?\n/).map((line) => `> ${line}`).join("\n")}\n\n`;
  }

  function referenceQuery(text, caret) {
    const match = text.slice(0, caret).match(/(?:^|\s)#([^#\n]*)$/u);
    return match ? { query: match[1].trim(), replaceRange: [caret - match[1].length - 1, caret] } : null;
  }

  function referenceSuggestions(text, caret, entries) {
    const reference = referenceQuery(text, caret);
    if (!reference) return { suggestions: [], replaceRange: [0, 0] };
    const query = reference.query.toLowerCase();
    const unique = new Map(entries.map((entry) => [`${entry.type}:${entry.id}`, entry]));
    const suggestions = [...unique.values()].map((entry) => {
      const title = entry.title.toLowerCase();
      const id = String(entry.id);
      const score = !query || id.startsWith(query) ? 0
        : title.startsWith(query) ? 1
        : query.split(/\s+/).every((word) => title.includes(word)) ? 2 : 3;
      return { ...entry, score };
    }).filter((entry) => entry.score < 3 || entry.remote)
      .sort((a, b) => a.score - b.score || (b.priority || 0) - (a.priority || 0) || a.title.localeCompare(b.title))
      .slice(0, 15).map((entry) => ({
        label: `[${entry.type}:${entry.id}]`, title: entry.title,
        statusName: entry.type.toUpperCase(), type: entry.type,
        replaceRange: reference.replaceRange,
      }));
    return { ...reference, suggestions };
  }

  function cancelReferenceSearch() {
    referenceSearch?.cancel();
  }

  function searchReferences(text, caret, onResult) {
    cancelReferenceSearch();
    const reference = referenceQuery(text, caret);
    if (!reference) return;
    if (!reference.query) { onResult([], "TYPE A TITLE OR ID · LOADED ITEMS"); return; }
    referenceSearch ||= window.NRCSearch.createController();
    const roomId = 0n;
    const workspace = currentWorkspaceId;
    onResult([], "SEARCHING TASKS & NOTES…");
    referenceSearch.search({ query: reference.query, top_n: 15,
      filters: { entity_types: ["task", "asset"], asset_types: [5] },
    }, {
      debounce: 250,
      onResult: (data) => {
        const entries = (data.results || []).filter((result) => result.entity?.id != null &&
          String(result.entity.conv_id) === String(roomId) &&
          (!result.entity.workspace || result.entity.workspace === workspace) &&
          (result.entity.type === "task" || (result.entity.type === "asset" && result.metadata?.asset_type === 5)))
          .map((result) => ({
            type: result.entity.type === "task" ? "task" : "note", id: String(result.entity.id),
            title: result.entity.type === "task" ? result.preview : window.NRCNotes.parseNotePreview(result.preview).title,
            remote: true,
          }));
        onResult(entries, "");
      },
      onError: () => onResult([], "SEARCH UNAVAILABLE · LOADED ITEMS ONLY"),
    });
  }

  function cancelQuote() {
    if (quote && messageInput.value.startsWith(quote)) messageInput.value = messageInput.value.slice(quote.length);
    quote = "";
    el("chatReply").hidden = true;
    messageInput.dispatchEvent(new Event("input"));
  }

  function syncComposer() {
    // Volatile drafts only: no message content written to persistent storage.
    const view = window.NRCViewManager?.getActiveView?.();
    const mode = view === "sullivan" || view === "sullivanShare" ? "ai" : "chat";
    const contextRoom = mode === "ai" ? window.NRCAI?.getContextConvId?.() ?? currentRoomId : currentRoomId;
    const next = `${currentWorkspaceId}:${contextRoom}:${mode}`;
    if (next === composerContext) return;
    if (composerContext !== null) {
      if (messageInput.value) drafts.set(composerContext, { text: messageInput.value, quote, reply: el("chatReplyText").textContent });
      else drafts.delete(composerContext);
      const draft = drafts.get(next);
      messageInput.value = draft?.text || "";
      quote = draft?.quote || "";
      el("chatReplyText").textContent = draft?.reply || "";
      el("chatReplyText").title = draft?.reply || "";
      el("chatReply").hidden = !quote;
      messageInput.closest(".input-container")?.classList.toggle("has-content", !!messageInput.value);
      updateMessageByteCount();
      cancelReferenceSearch();
      hideAutocomplete();
    }
    composerContext = next;
  }

  function decorate(row, message) {
    if (!enabled() || !["Message", "Sent"].includes(message.type)) return;
    if (isMention(message)) {
      row.classList.add("chat-mentioned");
      const badge = document.createElement("span");
      badge.className = "chat-mention-label";
      badge.textContent = "@ YOU";
      row.querySelector(".message-meta").append(badge);
    }
    const reply = document.createElement("button");
    reply.type = "button";
    reply.className = "btn btn--row chat-reply-action";
    reply.textContent = "REPLY";
    reply.setAttribute("aria-label", `Reply to ${message.author || "message"}`);
    reply.onclick = () => {
      cancelQuote();
      const plain = document.createElement("div");
      plain.innerHTML = parseMarkdown(message.message);
      plain.querySelectorAll("p, pre, li, blockquote, br").forEach((node) => node.append("\n"));
      if (message.attachment) plain.textContent = message.attachment.filename;
      const author = message.author === "YOU" ? myNickname || "YOU" : message.author || "UNKNOWN";
      quote = quoteText(author, plain.textContent.trim());
      messageInput.value = quote + messageInput.value;
      el("chatReplyText").textContent = `REPLY TO ${author}: ${plain.textContent.trim().slice(0, 120)}`;
      el("chatReplyText").title = el("chatReplyText").textContent;
      el("chatReply").hidden = false;
      messageInput.focus();
      messageInput.setSelectionRange(messageInput.value.length, messageInput.value.length);
      messageInput.dispatchEvent(new Event("input"));
    };
    row.querySelector(".message-meta").append(reply);
  }

  function received(message) {
    if (enabled() && query && message.roomId === currentRoomId) filterHistory(roomHistory.get(currentRoomId) || []);
    if (!["Message", "Image"].includes(message.type) || message.suppressNotification || message.author === "YOU") return;
    if (!isConversationExposed(message.roomId, message) || document.hidden || !atBottom() || query) {
      if (!unread.has(message.roomId)) {
        unread.set(message.roomId, new Set());
        if (message.roomId === currentRoomId) el("chatUnreadDivider")?.remove();
      }
      const pending = unread.get(message.roomId);
      pending.add(message);
      update();
    }
  }

  function update() {
    for (const [id, pending] of unread) {
      const history = new Set(roomHistory.get(id));
      for (const item of pending) if (!history.has(item)) pending.delete(item);
      if (!pending.size) unread.delete(id);
    }
    if (!enabled() && quote) cancelQuote();
    const pending = unread.get(currentRoomId) || new Set();
    const mentions = [...pending].filter(isMention).length;
    el("chatNewMessages").hidden = !pending.size || !enabled();
    el("chatNewMessages").textContent = `↓ ${pending.size} NEW${mentions ? ` · @ ${mentions}` : ""}`;
    el("chatTools").hidden = !enabled();
    el("chatSearchCount").hidden = !enabled() || !query;
    el("chatSearchClear").hidden = !el("chatSearch").value;
    for (const node of document.querySelectorAll("#roomList [data-room], #dmList [data-dm-id]")) {
      node.querySelector(".chat-mention-label")?.remove();
      const count = [...(unread.get(BigInt(node.dataset.room || node.dataset.dmId)) || [])].filter(isMention).length;
      if (count) {
        const badge = document.createElement("span");
        badge.className = "chat-mention-label";
        badge.textContent = ` @ ${count}`;
        node.append(badge);
      }
    }
  }

  function markRead() {
    if (loading || query || !enabled() || document.hidden || !isConversationExposed(currentRoomId) || !atBottom()) return;
    if (!unread.has(currentRoomId) && !roomActivity.has(currentRoomId)) return;
    unread.delete(currentRoomId);
    clearConversationUnread(currentRoomId);
    update();
  }

  function beforeAppend(message) {
    if (!enabled()) return true;
    const follow = !query && (loading || atBottom() || message.type === "Sent");
    if (!query && unread.get(currentRoomId)?.has(message) && !el("chatUnreadDivider")) {
      const divider = document.createElement("div");
      divider.id = "chatUnreadDivider";
      divider.className = "chat-unread-divider";
      divider.textContent = "NEW MESSAGES";
      logOutput.append(divider);
    }
    return follow;
  }

  function beginHistory(id) {
    syncComposer();
    restoreTop = room === id && !query && !atBottom() ? logOutput.scrollTop : null;
    loading = true;
    if (room !== id) {
      query = "";
      el("chatSearch").value = "";
      room = id;
    }
    el("chatNotifications").value = notificationMode(id);
    update();
  }

  function filterHistory(history) {
    el("chatSearchEmpty")?.remove();
    const count = el("chatSearchCount");
    count.hidden = !enabled() || !query;
    if (count.hidden) { count.textContent = ""; return history; }
    const matches = history.filter(matchesQuery);
    count.textContent = `${matches.length} MATCHES · LOCAL`;
    if (!matches.length) {
      const empty = document.createElement("p");
      empty.id = "chatSearchEmpty";
      empty.className = "filter-label";
      empty.setAttribute("role", "status");
      empty.textContent = "NO MATCHES IN LOADED CHAT";
      logOutput.append(empty);
    }
    return matches;
  }

  function matchesQuery(message) {
    return !enabled() || !query || `${message.author || ""}\n${message.attachment?.filename || ""}\n${message.message || ""}`.toLowerCase().includes(query);
  }

  function endHistory() {
    loading = false;
    if (restoreTop != null) logOutput.scrollTop = restoreTop;
    else if (enabled() && el("chatUnreadDivider")) el("chatUnreadDivider").scrollIntoView({ block: "start" });
    else if (query) logOutput.scrollTop = 0;
    update();
  }

  function init() {
    el("chatCancelReply").onclick = () => { cancelQuote(); messageInput.focus(); };
    messageInput.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && quote && !autocompleteState.isVisible) { event.preventDefault(); cancelQuote(); }
    });
    el("chatSearch").oninput = (event) => {
      query = event.target.value.trim().toLowerCase();
      loadRoomHistory(currentRoomId);
    };
    el("chatSearchClear").onclick = () => {
      el("chatSearch").value = "";
      query = "";
      loadRoomHistory(currentRoomId);
      el("chatSearch").focus();
    };
    el("chatSearch").onkeydown = (event) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        event.target.value = "";
        query = "";
        loadRoomHistory(currentRoomId);
        messageInput.focus();
      }
    };
    el("chatNotifications").onchange = (event) => {
      try { localStorage.setItem(key(currentRoomId), event.target.value); }
      catch { logMessage("Error", "COULD NOT SAVE NOTIFICATION PREFERENCE"); }
      if (event.target.value !== "off" && typeof Notification !== "undefined" && Notification.permission === "default") Notification.requestPermission();
    };
    el("chatNewMessages").onclick = () => {
      query = "";
      el("chatSearch").value = "";
      loadRoomHistory(currentRoomId);
      logOutput.scrollTop = logOutput.scrollHeight;
      markRead();
    };
    logOutput.addEventListener("scroll", markRead);
    document.addEventListener("visibilitychange", markRead);
    window.addEventListener("focus", markRead);
  }

  // The register needs the detail behind an unread count: how many of the
  // pending messages mention the operator, who wrote them, and where the first
  // one sits in the retained history. The rules stay here, next to the map they
  // read, and the count itself comes from the sidebar's own bookkeeping.
  function unreadDetail(convId) {
    const pending = unread.get(convId);
    if (!pending || pending.size === 0) return null;
    const messages = [...pending];
    const mentions = messages.filter(isMention);
    const firstSequence = (list) => {
      let lowest = null;
      for (const message of list) {
        if (message.sequence == null) continue;
        if (lowest === null || message.sequence < lowest) lowest = message.sequence;
      }
      return lowest;
    };
    const authors = [...new Set(messages.map((message) => message.author).filter(Boolean))];
    return {
      count: messages.length,
      mentionCount: mentions.length,
      authors,
      firstSequence: firstSequence(messages),
      mentionSequence: firstSequence(mentions),
      mentionText: mentions.length ? mentions[0].message : null,
    };
  }

  return { init, syncComposer, markRead, suggestions, quoteText, mentionPattern, decorate, received, update,
    unreadDetail,
    referenceQuery, referenceSuggestions, searchReferences, cancelReferenceSearch,
    beforeAppend, beginHistory, filterHistory, endHistory, matchesQuery,
    keepHistory: () => enabled() && (!!query || !!unread.get(currentRoomId)?.size || (!loading && !atBottom())),
    shouldNotify: (message) => notificationMode(message.roomId) === "all" ||
      (notificationMode(message.roomId) === "mentions" && isMention(message)),
    sent: () => {
      quote = "";
      el("chatReply").hidden = true;
      if (query) {
        query = "";
        el("chatSearch").value = "";
        loadRoomHistory(currentRoomId);
      }
    },
  };
})();
