// =============================================================================
// NRC SLICE VIEW
// =============================================================================
// A slice is an explicit work stream: an asset of type `AssetType.Slice` whose
// members are the tasks, notes and files linked to it with a `member-of` edge.
//
// This module derives nothing. The server lists the records and folds each one's
// counters from its membership edges, so the register, the record and the CLI
// read one definition of membership and cannot disagree.
//
// Membership is an edge, which is what lets a slice span projects and lets one
// task belong to more than one slice. Closure is an act by the owner, not a
// consequence of the members reaching Done.
(function () {
  const LIST_TASK_SLICES = 56;
  const SLICE_ASSET_TYPE = 11;
  const NOTE_ASSET_TYPE = 5;
  const FILE_ASSET_TYPE = 3;

  const MAX_PROJECT_LENGTH = 128;
  const MAX_OWNER_LENGTH = 32;
  const MAX_OUTCOME_LENGTH = 2048;
  const REQUEST_TIMEOUT_MS = 15000;
  const MEMBER_PAGE_LIMIT = 200;
  // The register draws a page at a time: a workspace may hold more work streams
  // than one frame carries, and closed slices pile up. The next page is asked for
  // as the reader reaches the end of the drawn rows.
  const PAGE_SIZE = 100;
  const LOAD_MORE_MARGIN = 400;

  // The record's strip stays bounded as a slice grows: it shows the first N task
  // members and the rest become a count. The exact member count is always in the
  // row header and in the record's facts.
  const RECORD_MARK_CAP = 64;
  const REGISTER_STALE_HOURS = 168; // one week

  const STATUS_CLASS = {
    backlog: "slice-mark",
    todo: "slice-mark slice-mark--todo",
    inprogress: "slice-mark slice-mark--inprogress",
    done: "slice-mark slice-mark--done",
  };
  const STATUS_LABEL = { backlog: "BACKLOG", todo: "TODO", inprogress: "IN PROGRESS", done: "DONE" };
  // The register's bar reads the counters in the order the record's legend names
  // them. Each pair is the mark's class suffix and the counter it draws.
  const SHAPE_SEGMENTS = [
    ["backlog", "backlog"],
    ["todo", "todo"],
    ["inprogress", "inProgress"],
    ["done", "done"],
  ];
  const FLAG_CLOSED = 1;

  const encoder = new TextEncoder();
  const decoder = new TextDecoder("utf-8", { ignoreBOM: true });

  // Entity and relation kinds come from the edge module, so a slice and a link
  // cannot disagree about what a task or a member-of edge is.
  const edgeTargets = () => window.NRCEdges.TargetType;
  const edgeRelations = () => window.NRCEdges.RelationType;

  const state = {
    roomId: 0n,
    mode: "idle", // idle | loading | ready | error
    error: "",
    slices: [],
    // How many slices the filters match, and where the next page continues. The
    // register draws the pages it has asked for and says how many of the listing's
    // slices those are.
    total: 0,
    hasMore: false,
    cursor: null,
    loadingMore: false,
    pageError: "",
    assignedTasks: 0,
    unassignedTasks: 0,
    includeClosed: false,
    // The filters the register asks the server with. They survive no reload, like
    // the other registers' filters.
    filters: { owner: null, query: "" },
    selected: null,
    // The slice the detail on screen belongs to. A refresh of the same slice
    // keeps what is already shown instead of blanking it.
    detailSliceId: null,
    detail: { mode: "idle", error: "" },
    members: { mode: "idle", tasks: [] },
    notes: { mode: "idle", assets: [] },
    files: { mode: "idle", assets: [] },
    createOpen: false,
    writeError: "",
    refreshError: "",
    writePending: false,
    generation: 0,
  };

  let pendingList = null;
  let listRefreshTimer = null;
  // What the last listing carried. A derived view that asks for the list is
  // answered with the same list, so the announcement below has to be about a
  // change or it would have that view ask again, forever.
  let listSignature = null;
  let ownerAutocomplete = null;
  let detailGeneration = 0;
  let detailLoading = false;
  let selectionGeneration = 0;
  // What the record's fields were last painted with, so a later render can tell
  // the reader's text from the record's own value.
  let paintedFields = null;
  // The member table the reader is in: the `data-member-open` value of the member
  // last opened or focused, and the slice it belongs to. A click on a member row
  // leaves focus on the record itself, so an arrow key that arrives there has to
  // read this instead of the focused node. Keying it by slice means a record for
  // another slice simply has no member table to walk yet.
  let activeMember = null;

  function escape(value) {
    return String(value ?? "").replace(/[&<>"']/g, (character) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character]
    ));
  }

  function updateHtml(container, markup, { preserveSections = false } = {}) {
    if (!container || container.nrcMarkup === markup) return;
    // A record refresh changes individual sections, not the whole document.
    // Compare against the last paint (not live form values or menu attributes),
    // so untouched fields and member tables retain their nodes and focus.
    if (preserveSections && container.children?.length && container.nrcMarkup) {
      const previous = document.createElement("template");
      const next = document.createElement("template");
      previous.innerHTML = container.nrcMarkup;
      next.innerHTML = markup;
      const before = [...previous.content.children];
      const after = [...next.content.children];
      if (before.length === after.length && before.length === container.children.length &&
          before.every((section, index) => section.tagName === after[index].tagName)) {
        before.forEach((section, index) => {
          if (section.outerHTML === after[index].outerHTML) return;
          const current = container.children[index];
          current.nrcMarkup = section.innerHTML;
          updateHtml(current, after[index].innerHTML);
          for (const attribute of [...current.attributes]) {
            if (!after[index].hasAttribute(attribute.name)) current.removeAttribute(attribute.name);
          }
          for (const attribute of after[index].attributes) current.setAttribute(attribute.name, attribute.value);
        });
        container.nrcMarkup = markup;
        return;
      }
    }
    // A container that is rebuilt takes the status menu its row opened with it,
    // and the menu closes while its anchor is still inside: a menu in another
    // table is not this render's business.
    window.NRCTasks?.closeStatusMenuFor?.(container);
    const focused = document.activeElement;
    // A member row is the click target and its opener is what the keyboard
    // reaches, so focus is restored through the opener's own attribute: the row
    // carries the identity but is not focusable. The status token is its own
    // control, so it carries its member's identity the same way.
    const key = focused && container.contains(focused) ?
      ["id", "data-slice-name", "data-member-open", "data-member-status"].find((name) => focused.hasAttribute(name)) : null;
    const value = key && focused.getAttribute(key);
    container.innerHTML = markup;
    container.nrcMarkup = markup;
    if (key) container.querySelector(`[${key}="${CSS.escape(value)}"]`)?.focus({ preventScroll: true });
  }

  function connected() {
    return typeof serverReady !== "undefined" && serverReady && ws?.readyState === WebSocket.OPEN;
  }

  function identity() {
    return typeof myNickname === "string" ? myNickname : "";
  }

  function active() {
    return window.NRCViewManager?.getActiveView() === "kanban" && TaskViewState.grouping === "slices";
  }

  // ---------------------------------------------------------------------------
  // Slice readings
  // ---------------------------------------------------------------------------

  function isClosed(slice) {
    return (slice.flags & FLAG_CLOSED) !== 0;
  }

  function openCount(slice) {
    return slice.backlog + slice.todo + slice.inProgress;
  }

  function taskCount(slice) {
    return slice.backlog + slice.todo + slice.inProgress + slice.done;
  }

  // Members are every kind the slice carries; the strip is drawn from the task
  // members, because only tasks have a status to draw.
  function memberCount(slice) {
    return taskCount(slice) + slice.notes + slice.files;
  }

  function ageHours(timestamp) {
    if (!timestamp || timestamp <= 0n) return null;
    return Number(BigInt(Date.now()) * 1000000n - timestamp) / 3.6e12;
  }

  function formatAge(timestamp) {
    const hours = ageHours(timestamp);
    if (hours === null) return "—";
    if (hours < 1) return `${Math.max(1, Math.round(hours * 60))}M`;
    if (hours < 24) return `${Math.round(hours)}H`;
    return `${Math.round(hours / 24)}D`;
  }

  // A register holds counters and nothing else: the wire carries no member
  // identity and no member order for a listing, so a register's shape is the
  // share each status holds, and the blocked share drawn against the whole
  // slice. It can never look like the record's strip, which is the one surface
  // that draws members, because it is the one surface that holds them.
  function renderShape(slice, { wide = false } = {}) {
    const tasks = taskCount(slice);
    // A blocked count cannot name the member it belongs to, so it is drawn as a
    // share of the task members and can never exceed them.
    const blocked = tasks ? Math.min(slice.blocked, tasks) : 0;
    const segment = (status, count) => count ?
      `<span class="slice-bar-seg slice-bar-seg--${status}" style="--slice-share:${count}"></span>` : "";
    const bar = tasks ?
      `<div class="slice-bar">${SHAPE_SEGMENTS.map(([status, counter]) => segment(status, slice[counter])).join("")}</div>` :
      // A slice that carries no task members has no share to draw. The band stays
      // so the register keeps its rhythm and says so instead of showing nothing.
      `<div class="slice-bar slice-bar--empty"></div>`;
    const blockedBar = blocked ?
      `<div class="slice-bar slice-bar--blocked">${segment("blocked", blocked)}` +
        `<span class="slice-bar-track" style="--slice-share:${tasks - blocked}"></span></div>` : "";
    return `<div class="slice-bar-group${wide ? " slice-bar-group--wide" : ""}">${bar}${blockedBar}</div>`;
  }

  // The record's strip is one mark per task member, in creation order, and the
  // blocked members break out of the band where they sit in that order.
  function renderStrip(marks, cap, { wide = false } = {}) {
    const classes = [wide ? "slice-strip slice-strip--wide" : "slice-strip"];
    if (marks.length > cap) classes.push("slice-strip--overflow");
    const visible = marks.length > cap ? marks.slice(0, cap) : marks;
    const rendered = visible.map((mark) => `<span class="${STATUS_CLASS[mark.status]}${mark.blocked ? " slice-mark--blocked" : ""}"></span>`);
    const overflow = marks.length > visible.length ?
      `<span class="slice-strip-overflow">+${marks.length - visible.length}</span>` : "";
    return `<div class="${classes.join(" ")}">${rendered.join("")}${overflow}</div>`;
  }

  function memberMarks(tasks) {
    return tasks.map((task) => ({
      status: ["backlog", "todo", "inprogress", "done"][task.status] ?? "backlog",
      blocked: Boolean(task.blockedBy && task.blockedBy !== 0n),
    }));
  }

  // The register's first token is whose work stream a row is, because that is
  // what the owner filter narrows by; a slice nobody owns says so rather than
  // drawing nothing.
  function metaLine(slice) {
    const open = openCount(slice);
    const parts = [escape(slice.owner || "UNASSIGNED"), `<span class="${open > 6 ? "slice-alert" : ""}">${open} OPEN</span>`];
    if (slice.blocked) parts.push(`<span class="slice-alert">${slice.blocked} BLOCKED</span>`);
    parts.push(`${slice.done} DONE`);
    if (slice.notes) parts.push(`${slice.notes} NOTE${slice.notes === 1 ? "" : "S"}`);
    if (slice.files) parts.push(`${slice.files} FILE${slice.files === 1 ? "" : "S"}`);
    const idleHours = ageHours(slice.lastMovedAt);
    if (idleHours !== null) {
      parts.push(`<span class="${idleHours >= REGISTER_STALE_HOURS ? "slice-cold" : ""}">MOVED ${formatAge(slice.lastMovedAt)}</span>`);
    }
    if (isClosed(slice)) parts.push("CLOSED");
    return parts.join(" · ");
  }

  // ---------------------------------------------------------------------------
  // Filters
  // ---------------------------------------------------------------------------
  //
  // A register of every work stream grows past what a reader can scan, and the
  // first question a reader asks of it is whose work a row is. So the owner is
  // the filter the register leads with, and the name query is the second: a slice
  // is addressed by its name, and nothing else in the listing is text.
  //
  // The filters are the server's, the way the task query filters tasks: a page
  // carries only what matches, and the register keeps asking for pages as the
  // reader walks it. Nothing is derived here, so a filtered listing is complete
  // rather than a narrowing of the window that happened to be loaded. MY SLICES is
  // resolved into the reader's own name, exactly as MY TASKS resolves the
  // assignee, so a request carries a name and never an identity.

  const OWNER_MINE = "me";
  const OWNER_UNASSIGNED = "unassigned";

  function queryText() {
    return state.filters.query.trim();
  }

  function filterActive() {
    return state.filters.owner !== null || queryText() !== "";
  }

  // The owner a filter names: MY SLICES is the reader's own name, UNASSIGNED is the
  // empty one, and a name filter is one owner.
  function ownerName(owner) {
    if (owner === OWNER_MINE) return identity();
    if (owner === OWNER_UNASSIGNED) return "";
    return owner ?? "";
  }

  function ownerFilter() {
    return ownerName(state.filters.owner);
  }

  // The owner filter offers every owner the register has seen: the set grows as
  // pages arrive and never shrinks, because a filter that narrowed the listing
  // must not take the other owners out of the dropdown. The reader's own name stays
  // out of the list because MY SLICES says it.
  const seenOwners = new Set();
  let ownerOptions = null;

  function syncOwnerFilter() {
    const select = document.getElementById("sliceOwnerFilter");
    if (!select) return;
    const me = identity();
    for (const slice of state.slices) {
      if (slice.owner && slice.owner !== me) seenOwners.add(slice.owner);
    }
    const owners = new Set(seenOwners);
    const current = state.filters.owner;
    if (current !== null && current !== OWNER_MINE && current !== OWNER_UNASSIGNED) owners.add(current);
    const listed = Array.from(owners).sort();
    const signature = listed.join("\u0000");
    // The option set is rebuilt only when it changes: a refresh must not replace
    // the dropdown the reader has open.
    if (signature !== ownerOptions) {
      ownerOptions = signature;
      select.innerHTML = `<option value="">ALL</option>` +
        `<option value="${OWNER_MINE}">MY SLICES</option>` +
        `<option value="${OWNER_UNASSIGNED}">UNASSIGNED</option>` +
        listed.map((owner) => `<option value="${escape(owner)}">${escape(owner)}</option>`).join("");
    }
    const value = state.filters.owner ?? "";
    if (select.value !== value) select.value = value;
  }

  // The controls are painted from the state, so a filter that was dropped — by
  // RESET, or by creating a slice — is visible in the register as well as in the
  // rows. The query keeps the reader's own text, so a render cannot take the
  // space that was just typed.
  function syncFilterControls() {
    syncOwnerFilter();
    const query = document.getElementById("sliceQuery");
    if (query && query.value !== state.filters.query) query.value = state.filters.query;
  }

  // A filter change asks the server for the listing again: the page the reader is
  // looking at was folded for the filter it was asked with.
  function setOwnerFilter(owner) {
    const next = owner ? String(owner) : null;
    if (state.filters.owner === next) return Promise.resolve(false);
    state.filters.owner = next;
    syncFilterControls();
    return requestList({ force: true });
  }

  function setQuery(query) {
    const next = String(query ?? "");
    if (state.filters.query === next) return Promise.resolve(false);
    state.filters.query = next;
    syncFilterControls();
    return requestList({ force: true });
  }

  function resetFilters() {
    if (!filterActive()) return Promise.resolve(false);
    state.filters = { owner: null, query: "" };
    syncFilterControls();
    return requestList({ force: true });
  }

  // ---------------------------------------------------------------------------
  // Wire
  // ---------------------------------------------------------------------------

  // One page of a listing is one request. The cursor is the last slice of the
  // previous page, carried in the register's own order, so a continued listing asks
  // where the previous page stopped.
  function encodeListRequest(correlationId, cursor, filters, includeClosed) {
    const ownerBytes = encoder.encode(ownerName(filters.owner));
    const nameBytes = encoder.encode(String(filters.query ?? "").trim());
    const hasName = nameBytes.length > 0;
    // opcode, conv id, the two flags, the owner and its length, the name flag and
    // its length, the page bound, the cursor flag and the correlation id.
    const buffer = new ArrayBuffer(24 + ownerBytes.length + nameBytes.length + (cursor ? 17 : 0));
    const view = new DataView(buffer);
    view.setUint16(0, LIST_TASK_SLICES, false);
    view.setBigUint64(2, state.roomId, false);
    view.setUint8(10, includeClosed ? 1 : 0);
    view.setUint8(11, filters.owner !== null && filters.owner !== undefined ? 1 : 0);
    view.setUint16(12, ownerBytes.length, false);
    let offset = 14;
    new Uint8Array(buffer, offset, ownerBytes.length).set(ownerBytes);
    offset += ownerBytes.length;
    view.setUint8(offset, hasName ? 1 : 0);
    offset += 1;
    view.setUint16(offset, nameBytes.length, false);
    offset += 2;
    new Uint8Array(buffer, offset, nameBytes.length).set(nameBytes);
    offset += nameBytes.length;
    view.setUint16(offset, PAGE_SIZE, false);
    offset += 2;
    view.setUint8(offset, cursor ? 1 : 0);
    offset += 1;
    if (cursor) {
      view.setUint8(offset, cursor.closed ? 1 : 0);
      offset += 1;
      view.setBigInt64(offset, BigInt(cursor.sortAt), false);
      offset += 8;
      view.setBigUint64(offset, BigInt(cursor.sliceId), false);
      offset += 8;
    }
    view.setUint32(offset, correlationId, false);
    return buffer;
  }

  // requestPage asks for one page: the first when the cursor is null, the next one
  // when it is not. A page that continues a listing keeps what is on screen and
  // says it is loading; a page that starts one replaces the listing when it lands.
  // The returned promise settles when the page arrived or failed, so a caller that
  // walks pages (the CLI's sibling here is the attention register) can wait.
  function requestPage(cursor) {
    if (!connected()) {
      state.mode = state.slices.length ? state.mode : "idle";
      return Promise.resolve(false);
    }
    if (pendingList) return Promise.resolve(false);
    const correlationId = window.NRCAssets.generateCorrelationId();
    const timer = setTimeout(() => {
      if (pendingList?.correlationId !== correlationId) return;
      const request = pendingList;
      pendingList = null;
      state.loadingMore = false;
      if (request.cursor === null) {
        state.mode = "error";
        state.error = "Slice listing timed out";
      } else {
        state.pageError = "The next page did not arrive. Scroll to ask again.";
      }
      request.settle?.(false);
      render();
    }, REQUEST_TIMEOUT_MS);
    let settle = null;
    const settled = new Promise((resolve) => { settle = resolve; });
    pendingList = { correlationId, timer, cursor, slices: [], settle };
    if (cursor === null) {
      state.mode = "loading";
      state.error = "";
      state.pageError = "";
    } else {
      state.loadingMore = true;
      state.pageError = "";
    }
    ws.send(encodeListRequest(correlationId, cursor, state.filters, state.includeClosed));
    localPacketsOut++;
    render();
    return settled;
  }

  function requestList({ force = false } = {}) {
    if (pendingList) {
      if (!force) return Promise.resolve(false);
      clearTimeout(pendingList.timer);
      pendingList.settle?.(false);
      pendingList = null;
      state.loadingMore = false;
    }
    return requestPage(null);
  }

  // loadMore asks for the next page. A page is only asked for when the server said
  // there is one, so the register never invents a request.
  function loadMore() {
    if (!state.hasMore || !state.cursor || pendingList) return Promise.resolve(false);
    return requestPage(state.cursor);
  }

  // loadMoreNearEnd asks for the next page as the reader reaches the end of the
  // register, which is how the task list and the note list fill themselves too.
  function loadMoreNearEnd() {
    if (!state.hasMore || !state.cursor || pendingList) return;
    const register = document.querySelector?.("#sliceView .slice-register") ?? null;
    if (!register || register.clientHeight <= 0) return;
    const remaining = register.scrollHeight - register.scrollTop - register.clientHeight;
    if (remaining <= LOAD_MORE_MARGIN) loadMore();
  }

  // afterRender lets the register fill its viewport without a scroll event: a page
  // that does not reach the bottom leaves nothing to scroll.
  function afterRender(callback) {
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(callback);
    else setTimeout(callback, 0);
  }

  function invalidate({ debounce = true } = {}) {
    clearTimeout(listRefreshTimer);
    if (!debounce) {
      requestList({ force: true });
      return;
    }
    listRefreshTimer = setTimeout(() => requestList({ force: true }), 120);
  }

  function readString(view, offset) {
    const length = view.getUint16(offset, false);
    const value = decoder.decode(new Uint8Array(view.buffer, view.byteOffset + offset + 2, length));
    return { value, newOffset: offset + 2 + length };
  }

  // ---------------------------------------------------------------------------
  // Headless reads
  // ---------------------------------------------------------------------------
  //
  // The register draws the pages the reader has scrolled to; a derived view (the
  // attention register) needs the whole listing of one filter instead, because a
  // count folded from a window is a statement about the window and not about the
  // work. So a derived view gets its own read: the same request, its own
  // correlation id, every page walked to the end, and nothing of the register's
  // window, filter or selection touched.

  // A walk is bounded so a listing that never ends cannot spin the client. The cap
  // is far above what one reader owns.
  const MAX_READ_PAGES = 50;

  const headlessReads = new Map();

  function readPage(filters, cursor) {
    if (!connected()) return Promise.resolve(null);
    const correlationId = window.NRCAssets.generateCorrelationId();
    return new Promise((resolve) => {
      const read = { filters, cursor, resolve, timer: null };
      read.timer = setTimeout(() => {
        if (headlessReads.get(correlationId) !== read) return;
        headlessReads.delete(correlationId);
        resolve(null);
      }, REQUEST_TIMEOUT_MS);
      headlessReads.set(correlationId, read);
      ws.send(encodeListRequest(correlationId, cursor, filters, filters.includeClosed === true));
      localPacketsOut++;
    });
  }

  // readAll walks one filtered listing to its end and answers the rows and the
  // total the server reported, or null when the listing could not be read.
  async function readAll({ owner = null, query = "", includeClosed = false } = {}) {
    const filters = { owner, query, includeClosed };
    const slices = [];
    let cursor = null;
    let total = 0;
    for (let page = 0; page < MAX_READ_PAGES; page++) {
      const result = await readPage(filters, cursor);
      if (result == null || !result.success) return null;
      slices.push(...result.slices);
      total = result.total;
      // A page that carries no row cannot advance the cursor, so the walk ends
      // rather than asking for the same page again.
      if (!result.hasMore || !result.cursor || result.slices.length === 0) return { slices, total };
      cursor = result.cursor;
    }
    return { slices, total };
  }

  // A read is abandoned when the connection it was asked over is gone: the answer
  // would name a listing the next session knows nothing about.
  function cancelHeadlessReads() {
    for (const read of headlessReads.values()) {
      clearTimeout(read.timer);
      read.resolve(null);
    }
    headlessReads.clear();
  }

  // readSlicePage parses one S_TaskSliceList frame: the rows and the facts that
  // belong to the page. The register's window and a headless read read one frame the
  // same way, so a change to the wire lands in both.
  function readSlicePage(dataView) {
    const roomId = dataView.getBigUint64(2, false);
    const success = dataView.getUint8(10) !== 0;
    const count = dataView.getUint16(11, false);
    const slices = [];
    let offset = 13;
    for (let i = 0; i < count; i++) {
      const name = readString(dataView, offset); offset = name.newOffset;
      const sliceId = dataView.getBigUint64(offset, false); offset += 8;
      const owner = readString(dataView, offset); offset = owner.newOffset;
      const flags = dataView.getUint8(offset); offset += 1;
      const backlog = dataView.getUint16(offset, false); offset += 2;
      const todo = dataView.getUint16(offset, false); offset += 2;
      const inProgress = dataView.getUint16(offset, false); offset += 2;
      const done = dataView.getUint16(offset, false); offset += 2;
      const blocked = dataView.getUint16(offset, false); offset += 2;
      const notes = dataView.getUint16(offset, false); offset += 2;
      const files = dataView.getUint16(offset, false); offset += 2;
      const oldestActiveAt = dataView.getBigInt64(offset, false); offset += 8;
      const lastMovedAt = dataView.getBigInt64(offset, false); offset += 8;
      slices.push({
        name: name.value, sliceId, owner: owner.value, flags,
        backlog, todo, inProgress, done, blocked, notes, files,
        oldestActiveAt, lastMovedAt,
      });
    }
    const hasMore = dataView.getUint8(offset) === 1; offset += 1;
    const cursorClosed = dataView.getUint8(offset) === 1; offset += 1;
    const cursorSortAt = dataView.getBigInt64(offset, false); offset += 8;
    const cursorSliceId = dataView.getBigUint64(offset, false); offset += 8;
    const total = dataView.getUint32(offset, false); offset += 4;
    const assignedTasks = dataView.getUint32(offset, false); offset += 4;
    const unassignedTasks = dataView.getUint32(offset, false); offset += 4;
    const error = readString(dataView, offset); offset = error.newOffset;
    return {
      roomId, success, slices, hasMore, total, assignedTasks, unassignedTasks,
      error: error.value,
      cursor: hasMore ? { closed: cursorClosed, sortAt: cursorSortAt, sliceId: cursorSliceId } : null,
    };
  }

  function handleSliceList(dataView) {
    const correlationId = dataView.getUint32(dataView.byteLength - 4, false);
    // A headless read owns its correlation id, so a derived view can walk the whole
    // listing while the register asks for its own pages.
    const headless = headlessReads.get(correlationId);
    if (headless) {
      headlessReads.delete(correlationId);
      clearTimeout(headless.timer);
      headless.resolve(readSlicePage(dataView));
      return;
    }
    if (!pendingList || correlationId !== pendingList.correlationId) return;

    const page = readSlicePage(dataView);
    if (page.roomId !== state.roomId) return;
    const { success, hasMore, cursor, total, assignedTasks, unassignedTasks, error } = page;

    const request = pendingList;
    const first = request.cursor === null;
    clearTimeout(request.timer);
    pendingList = null;
    state.loadingMore = false;
    request.slices = page.slices;
    if (!success) {
      request.settle?.(false);
      if (first) {
        state.mode = "error";
        state.error = error || "Slice listing failed";
      } else {
        state.pageError = error || "The next page could not be loaded.";
      }
      render();
      return;
    }

    // The question is asked before the rows are replaced, because it reads the
    // record the rows still name.
    const keepRecord = state.selected !== null && recordDirty();
    state.slices = first ? request.slices : state.slices.concat(request.slices);
    state.total = total;
    state.hasMore = hasMore;
    state.cursor = cursor;
    // The workspace counters are folded on the first page of an unfiltered
    // listing, so a later page has nothing to say about them.
    if (first) {
      state.assignedTasks = assignedTasks;
      state.unassignedTasks = unassignedTasks;
    }
    state.mode = "ready";
    state.error = "";
    state.pageError = "";
    // The record follows the register: a listing that no longer carries the open
    // slice opens the first row it draws — unless the reader has unsaved work in
    // that record, which is the reader's to keep.
    const carried = state.selected !== null && state.slices.some((slice) => slice.name === state.selected);
    if (!carried && !keepRecord) {
      state.selected = state.slices.length ? state.slices[0].name : null;
    }
    // Derived views (the attention register) re-read the work streams when they
    // change. The announcement is a courtesy, not a contract: a minimal harness
    // without an event model still exercises the register. It is made only for a
    // listing that differs from the one before, because the register asks for the
    // listing itself and would otherwise answer its own request with another walk —
    // and only for a first page, because a continuation page carries more of the
    // same work streams rather than new ones.
    if (first) {
      const signature = state.slices.map((slice) => [slice.sliceId, slice.name, slice.owner, slice.flags,
        slice.backlog, slice.todo, slice.inProgress, slice.done, slice.blocked, slice.notes,
        slice.files, slice.lastMovedAt].join(":")).join("|");
      if (signature !== listSignature) {
        listSignature = signature;
        if (typeof document?.dispatchEvent === "function") {
          document.dispatchEvent(new CustomEvent("nrc:slices-changed", { detail: { total } }));
        }
      }
    }
    loadDetail();
    request.settle?.(true);
    // A page that does not fill the register leaves nothing to scroll, so the next
    // one is asked for without waiting for a scroll event.
    afterRender(loadMoreNearEnd);
  }

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  function selectedSlice() {
    return state.slices.find((slice) => slice.name === state.selected) ?? null;
  }

  function select(name, { focusDetail = false } = {}) {
    const view = document.getElementById("sliceView");
    // On a phone the record is a drill-in behind the register, so a tap has to
    // reveal it even when the tapped row is the slice already selected: the
    // listing preselects its first row, which is the row most likely tapped.
    if (view && window.matchMedia?.("(max-width: 768px)").matches) {
      view.dataset.sliceMobileDetail = "true";
    }
    if (state.selected !== name) {
      state.selected = name;
      state.createOpen = false;
      state.writeError = "";
      state.refreshError = "";
      loadDetail();
    }
    if (focusDetail) view?.querySelector(".slice-record")?.focus?.({ preventScroll: true });
  }

  // The owner and the outcome are live fields on the record, so a selection
  // change that would replace them asks first. The task and note lists guard
  // their clicks and their arrow keys the same way.
  function recordDirty() {
    const slice = selectedSlice();
    // Only the record on screen can carry edits; a record that has not arrived
    // yet, or one that belongs to another slice, has no fields to lose.
    if (!slice || state.detail.mode !== "ready" || state.detailSliceId !== slice.sliceId) return false;
    const fields = recordFields(slice);
    const owner = document.getElementById("sliceOwner")?.value ?? fields.owner;
    const outcome = document.getElementById("sliceOutcome")?.value ?? fields.outcome;
    return owner !== fields.owner || outcome !== fields.outcome;
  }

  async function confirmDiscardRecordEdits() {
    if (!recordDirty()) return true;
    return Boolean(await window.NRCDialog.confirm("Discard unsaved changes to this slice?", {
      title: "UNSAVED CHANGES",
      confirmLabel: "Discard",
    }));
  }

  // selectGuarded is the interactive selection: a click or an arrow key must not
  // take the record — and whatever was typed into it — away without an answer.
  // The generation marks the newest request, so a second keypress while the
  // question is open cannot apply a second time.
  async function selectGuarded(name) {
    if (name === state.selected) {
      select(name);
      return true;
    }
    const generation = ++selectionGeneration;
    if (!(await confirmDiscardRecordEdits())) return false;
    if (generation !== selectionGeneration) return false;
    select(name);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Membership
  // ---------------------------------------------------------------------------

  // memberRefs reads the slice's membership out of the edge cache. The caller
  // loads the page first; everything after that is local, so rendering a member
  // list costs no request.
  function memberRefs(sliceId) {
    const targetType = edgeTargets().Asset;
    const relation = edgeRelations().MemberOf;
    return window.NRCEdges.getEdgesForEntity(0n, targetType, sliceId)
      .filter((edge) => edge.relation === relation)
      .map((edge) => {
        const sliceIsTarget = edge.targetType === targetType && edge.targetId === sliceId;
        return {
          type: sliceIsTarget ? edge.sourceType : edge.targetType,
          id: sliceIsTarget ? edge.sourceId : edge.targetId,
          edgeId: edge.edgeId,
        };
      });
  }

  // sliceRecordData reads the slice's own record from the asset cache. The wire
  // listing carries the counters; the owner, the outcome and the closure live in
  // the record, so the record is requested alongside the members.
  function sliceRecordData(slice) {
    const asset = window.NRCAssets?.roomAssets?.get(0n)?.get(slice.sliceId);
    if (!asset?.preview) return null;
    try {
      const parsed = JSON.parse(asset.preview);
      return parsed && typeof parsed === "object" ? parsed : null;
    } catch {
      return null;
    }
  }

  // The record's two live fields, as the record holds them. The owner falls back
  // to the listing's copy, which is what the field shows until the record lands:
  // the register and the record are read together, so a render must not wait for
  // one of them to name the owner.
  function recordFields(slice) {
    const record = sliceRecordData(slice) ?? {};
    return {
      sliceId: slice.sliceId,
      owner: record.owner ?? slice.owner ?? "",
      outcome: record.outcome ?? "",
    };
  }

  function loadDetail() {
    const generation = ++detailGeneration;
    const slice = selectedSlice();
    if (!slice) {
      detailLoading = false;
      state.detailSliceId = null;
      state.detail = { mode: "idle", error: "" };
      state.members = { mode: "idle", tasks: [] };
      state.notes = { mode: "idle", assets: [] };
      state.files = { mode: "idle", assets: [] };
      state.refreshError = "";
      render();
      return;
    }
    // A refresh must not blank what is already on screen. The record only says
    // "loading" when it has nothing for this slice yet, because replacing the
    // member rows takes the row out from under a click that is on its way to it:
    // the press lands on the old node, the release on the new one, and the click
    // is dispatched at the container, where it means nothing.
    const showing = state.detailSliceId === slice.sliceId && state.members.mode === "ready";
    detailLoading = true;
    if (!showing) {
      state.detailSliceId = null;
      state.detail = { mode: "loading", error: "" };
      state.members = { mode: "loading", tasks: [] };
      state.notes = { mode: "loading", assets: [] };
      state.files = { mode: "loading", assets: [] };
      state.refreshError = "";
    }
    render();

    // The record and the members are read together: the record carries the
    // owner, the outcome and the closure, and the edges carry the members.
    const record = new Promise((resolve, reject) => {
      window.NRCAssets.requestAsset(0n, slice.sliceId, {
        onSuccess: resolve,
        onError: detail => reject(new Error(detail?.message || "Slice record could not be loaded.")),
      });
    });

    // One edge read answers what the slice carries. The entities behind the
    // edges come from the caches the other views already fill, and only what is
    // missing is fetched.
    const members = window.NRCEdges.requestEdgePage(
      0n, edgeTargets().Asset, slice.sliceId, { limit: MEMBER_PAGE_LIMIT },
    ).then(() => resolveMembers(slice));

    Promise.all([record, members])
      .then(([, resolved]) => {
        if (generation !== detailGeneration) return;
        state.detailSliceId = slice.sliceId;
        state.members = { mode: "ready", tasks: resolved.tasks };
        state.notes = { mode: "ready", assets: resolved.notes };
        state.files = { mode: "ready", assets: resolved.files };
        state.detail = { mode: "ready", error: "" };
        state.refreshError = "";
        detailLoading = false;
        render();
      })
      .catch((failure) => {
        if (generation !== detailGeneration) return;
        detailLoading = false;
        // A refresh that fails leaves the last known list in place and says so;
        // erasing a list the reader can still use would be the worse answer.
        if (showing) {
          state.refreshError = "Slice could not be refreshed; this is the last known list.";
          render();
          return;
        }
        state.detailSliceId = null;
        state.detail = { mode: "error", error: failure.message || "Slice could not be loaded." };
        state.members = { mode: "error", tasks: [] };
        state.notes = { mode: "error", assets: [] };
        state.files = { mode: "error", assets: [] };
        render();
      });
  }

  function resolveMembers(slice) {
    const refs = memberRefs(slice.sliceId);
    const tasks = [];
    const notes = [];
    const files = [];
    let remaining = refs.length;

    return new Promise((resolve, reject) => {
      const settle = () => {
        tasks.sort((a, b) => Number((a.createdAt ?? 0n) - (b.createdAt ?? 0n)));
        resolve({ tasks, notes, files });
      };
      const done = () => {
        if (--remaining <= 0) settle();
      };

      if (!refs.length) {
        settle();
        return;
      }

      for (const ref of refs) {
        if (ref.type === edgeTargets().Task) {
          window.NRCTasks.requestTask(0n, ref.id, {
            onSuccess: (detail) => {
              if (detail?.task) tasks.push(detail.task);
              done();
            },
            onError: detail => reject(new Error(detail?.message || "Slice task could not be loaded.")),
          });
          continue;
        }
        window.NRCAssets.requestAsset(0n, ref.id, {
          onSuccess: (detail) => {
            const asset = detail?.asset;
            if (asset?.assetType === FILE_ASSET_TYPE) files.push(asset);
            else if (asset?.assetType === NOTE_ASSET_TYPE) notes.push(asset);
            done();
          },
          onError: detail => reject(new Error(detail?.message || "Slice asset could not be loaded.")),
        });
      }
    });
  }

  // assignMembers links entities to the slice. The picker and the edge RPC are
  // the shared ones, so a slice member is an ordinary member-of edge.
  function assignMembers(kind, entityIds) {
    const slice = selectedSlice();
    if (!slice || !entityIds.length) return;
    if (!connected()) {
      state.writeError = "OFFLINE — reconnect before assigning a member.";
      render();
      return;
    }
    const targetType = kind === "task" ? edgeTargets().Task : edgeTargets().Asset;
    state.writePending = true;
    state.writeError = "";
    render();
    let pending = entityIds.length;
    const settle = (message) => {
      state.writePending = false;
      state.writeError = message ?? "";
      invalidate({ debounce: false });
      loadDetail();
      render();
    };
    for (const entityId of entityIds) {
      const sent = window.NRCEdges.sendCreateEdge(
        0n, targetType, entityId, edgeTargets().Asset, slice.sliceId, edgeRelations().MemberOf,
        {
          onSuccess: () => { if (--pending <= 0) settle(""); },
          onError: (detail) => { if (--pending <= 0) settle(detail?.message || "Assign failed"); },
        },
      );
      if (sent == null) {
        pending = 0;
        settle("Assign was not sent.");
        return;
      }
    }
  }

  function unassignMember(kind, entityId) {
    const slice = selectedSlice();
    if (!slice) return;
    const targetType = kind === "task" ? edgeTargets().Task : edgeTargets().Asset;
    const ref = memberRefs(slice.sliceId).find((entry) => entry.type === targetType && entry.id === entityId);
    if (!ref) {
      state.writeError = "No membership to remove.";
      render();
      return;
    }
    if (!connected()) {
      state.writeError = "OFFLINE — reconnect before removing a member.";
      render();
      return;
    }
    state.writePending = true;
    state.writeError = "";
    render();
    const sent = window.NRCEdges.sendDeleteEdge(0n, ref.edgeId, {
      onSuccess: () => {
        state.writePending = false;
        invalidate({ debounce: false });
        loadDetail();
        render();
      },
      onError: (detail) => {
        state.writePending = false;
        state.writeError = detail?.message || "Unassign failed";
        render();
      },
    });
    if (sent == null) {
      state.writePending = false;
      state.writeError = "Unassign was not sent.";
      render();
    }
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  function slicePreview(name, { owner = "", outcome = "", closed = false, closedAt = 0, closedBy = "" } = {}) {
    return JSON.stringify({
      version: 1,
      name,
      owner,
      outcome,
      closed,
      closed_at: Number(closedAt),
      closed_by: closedBy,
    });
  }

  // createSlice materializes a work stream. Everything after this is assignment:
  // the record carries the owner, the outcome and the closure, and the members
  // are edges.
  function createSlice(name, { owner = "", outcome = "" } = {}) {
    const trimmed = String(name ?? "").trim();
    if (!trimmed) {
      state.writeError = "A slice needs a name.";
      render();
      return;
    }
    if (trimmed.length > MAX_PROJECT_LENGTH) {
      state.writeError = `A slice name is limited to ${MAX_PROJECT_LENGTH} bytes.`;
      render();
      return;
    }
    if (!connected()) {
      state.writeError = "OFFLINE — reconnect before creating a slice.";
      render();
      return;
    }
    if (state.slices.some((slice) => slice.name === trimmed)) {
      state.writeError = "A slice with that name already exists.";
      render();
      return;
    }
    const preview = slicePreview(trimmed, { owner, outcome });
    if (encoder.encode(preview).length > window.NRCAssets.MAX_PREVIEW_LENGTH) {
      state.writeError = "Slice record exceeds the preview limit; shorten the outcome.";
      render();
      return;
    }
    state.writePending = true;
    state.writeError = "";
    render();
    const sent = window.NRCAssets.sendCreateAsset(0n, SLICE_ASSET_TYPE, 0, 0n, preview, outcome, 0, {
      onSuccess: () => {
        state.writePending = false;
        state.createOpen = false;
        state.selected = trimmed;
        // A slice is created without an owner, so a filter that would hide it is
        // dropped: the register has to show the slice that was just made.
        state.filters = { owner: null, query: "" };
        invalidate({ debounce: false });
        loadDetail();
        render();
      },
      onError: (detail) => {
        state.writePending = false;
        state.writeError = detail?.message || "Slice could not be created";
        render();
      },
    });
    if (sent == null) {
      state.writePending = false;
      state.writeError = "Create was not sent.";
      render();
    }
  }

  // saveRecord writes the owner and the outcome from the open fields. Every slice
  // has a record, so this is always an update.
  function saveRecord() {
    const slice = selectedSlice();
    if (!slice) return;
    if (!connected()) {
      state.writeError = "OFFLINE — reconnect before changing a slice.";
      render();
      return;
    }
    const record = sliceRecordData(slice) ?? {};
    const owner = document.getElementById("sliceOwner")?.value ?? record.owner ?? "";
    const outcome = document.getElementById("sliceOutcome")?.value ?? record.outcome ?? "";
    const next = {
      owner,
      outcome,
      closed: isClosed(slice),
      closedAt: 0,
      closedBy: "",
    };
    if (owner.length > MAX_OWNER_LENGTH || outcome.length > MAX_OUTCOME_LENGTH) {
      state.writeError = "Owner or outcome exceeds the record limit.";
      render();
      return;
    }
    const preview = slicePreview(slice.name, next);
    if (encoder.encode(preview).length > window.NRCAssets.MAX_PREVIEW_LENGTH) {
      state.writeError = "Slice record exceeds the preview limit; shorten the outcome.";
      render();
      return;
    }
    state.writePending = true;
    state.writeError = "";
    render();
    const sent = window.NRCAssets.sendUpdateAsset(0n, slice.sliceId, preview, outcome, SLICE_ASSET_TYPE, 0, {
      onSuccess: () => {
        state.writePending = false;
        invalidate({ debounce: false });
        loadDetail();
        render();
      },
      onError: (detail) => {
        state.writePending = false;
        state.writeError = detail?.message || "Slice update failed";
        render();
      },
    });
    if (sent == null) {
      state.writePending = false;
      state.writeError = "Update was not sent.";
      render();
    }
  }

  function setClosed(slice, closed) {
    const record = sliceRecordData(slice) ?? {};
    const owner = record.owner ?? slice.owner ?? "";
    const outcome = document.getElementById("sliceOutcome")?.value ?? record.outcome ?? "";
    const next = {
      owner,
      outcome,
      closed,
      closedAt: closed ? BigInt(Date.now()) * 1000000n : 0,
      closedBy: closed ? identity() : "",
    };
    const preview = slicePreview(slice.name, next);
    if (encoder.encode(preview).length > window.NRCAssets.MAX_PREVIEW_LENGTH) {
      state.writeError = "Slice record exceeds the preview limit; shorten the outcome.";
      render();
      return;
    }
    state.writePending = true;
    state.writeError = "";
    render();
    window.NRCAssets.sendUpdateAsset(0n, slice.sliceId, preview, next.outcome, SLICE_ASSET_TYPE, 0, {
      onSuccess: () => {
        state.writePending = false;
        invalidate({ debounce: false });
        loadDetail();
        render();
      },
      onError: (detail) => {
        state.writePending = false;
        state.writeError = detail?.message || "Slice update failed";
        render();
      },
    });
  }

  function closeSlice(slice) {
    setClosed(slice, true);
  }

  function reopenSlice(slice) {
    setClosed(slice, false);
  }

  // deleteSlice removes the slice and its memberships. Deleting is the one act
  // that cannot be undone: closure has REOPEN, membership has assign. So the
  // dialog names what is released before anything is sent, and the members are
  // never part of it — they are records of their own and stay.
  async function deleteSlice(slice) {
    if (!slice) return false;
    if (!connected()) {
      state.writeError = "OFFLINE — reconnect before deleting a slice.";
      render();
      return false;
    }
    const members = memberCount(slice);
    const message = members
      ? `Delete slice “${slice.name}”? Its ${members} ${members === 1 ? "membership is" : "memberships are"} released and the record, including its outcome, is gone. The tasks, notes and files themselves stay.`
      : `Delete slice “${slice.name}”? The record is gone, and nothing was assigned to it.`;
    const confirmed = await window.NRCDialog.confirm(message, { title: "DELETE SLICE", confirmLabel: "Delete slice" });
    if (!confirmed) return false;
    // The dialog is a round trip, so the connection is checked again after it.
    if (!connected()) {
      state.writeError = "OFFLINE — reconnect before deleting a slice.";
      render();
      return false;
    }
    state.writePending = true;
    state.writeError = "";
    render();
    const sent = window.NRCAssets.sendDeleteAsset(0n, slice.sliceId, {
      onSuccess: () => {
        state.writePending = false;
        if (state.selected === slice.name) state.selected = null;
        // The record that was open is the one that was deleted, so a phone
        // returns to the register instead of the next slice's record.
        const view = document.getElementById("sliceView");
        if (view) view.dataset.sliceMobileDetail = "false";
        invalidate({ debounce: false });
        render();
      },
      onError: (detail) => {
        state.writePending = false;
        state.writeError = detail?.message || "Slice could not be deleted";
        render();
      },
    });
    if (sent == null) {
      state.writePending = false;
      state.writeError = "Delete was not sent.";
      render();
    }
    return true;
  }

  // onAssetDeleted reacts to a slice that is gone, whichever client removed it.
  // The register refreshes and the record closes, so a deleted slice cannot stay
  // on screen as a record that no longer exists.
  function onAssetDeleted(convId, assetId) {
    if (convId !== state.roomId) return;
    const deleted = state.slices.find((slice) => slice.sliceId === assetId);
    if (deleted && deleted.name === state.selected) {
      state.selected = null;
      state.detailSliceId = null;
      state.detail = { mode: "idle", error: "" };
      state.members = { mode: "idle", tasks: [] };
      state.notes = { mode: "idle", assets: [] };
      state.files = { mode: "idle", assets: [] };
      state.refreshError = "";
    }
    invalidate({ debounce: false });
    render();
  }

  // Slice records arrive through the shared asset stream. A mutation changes the
  // register's owner/closure fields and can also change the selected record's
  // outcome, so both surfaces have to follow it without waiting for a reload.
  // Cache fills are reads initiated by this module and must not invalidate the
  // listing again, or loading a record would create a refresh loop. Likewise,
  // nonzero correlation ids are acknowledgements of local writes whose callbacks
  // already refresh the view; broadcasts from other clients carry zero.
  function onAssetChanged(asset, reason, correlationId) {
    if (reason !== "mutation" || correlationId !== 0 || asset?.convId !== state.roomId) return;
    if (asset.assetType === NOTE_ASSET_TYPE) {
      const index = state.notes.assets.findIndex(note => note.assetId === asset.assetId);
      if (index !== -1) {
        state.notes.assets[index] = asset;
        render();
      }
      return;
    }
    if (asset.assetType !== SLICE_ASSET_TYPE) return;
    invalidate();
    if (selectedSlice()?.sliceId === asset.assetId) render();
  }

  // A move is confirmed by the server before it is drawn anywhere. A member table
  // holds its own snapshot of a task, and a move into a status window the task
  // register does not hold leaves that snapshot as the only copy of the confirmed
  // status, so the confirmation is what the member rows read. Nothing is written
  // here: the register already wrote the move, and this follows its answer.
  function onTaskMoved(taskId, status, orderIndex) {
    let changed = false;
    for (const task of state.members.tasks) {
      if (task.id !== taskId) continue;
      task.status = status;
      task.orderIndex = orderIndex;
      changed = true;
    }
    if (changed) render();
  }

  // Membership is represented by MemberOf edges. Edge broadcasts are stored
  // before listeners run, so refreshing the selected record can immediately read
  // the new membership. A deleted edge may be absent from the local cache; in
  // that case its relation is unknown and the safe answer is to refresh because
  // the wire deletion carries only the edge id.
  function onEdgeChanged(edge, reason, correlationId) {
    if (correlationId !== 0 || edge?.convId !== state.roomId || (reason !== "created" && reason !== "deleted")) return;
    const relationUnknown = reason === "deleted" && edge.relation == null;
    if (!relationUnknown && edge.relation !== edgeRelations().MemberOf) return;

    invalidate();
    const selectedId = selectedSlice()?.sliceId;
    if (selectedId != null && (relationUnknown || edge.sourceId === selectedId || edge.targetId === selectedId)) {
      loadDetail();
    }
  }

  // openMemberPicker assigns an existing entity. The picker and the edge RPC are
  // the shared ones.
  function openMemberPicker(anchor, kind) {
    const slice = selectedSlice();
    if (!slice) return;
    if (!window.NRCLinksUI?.openEntityPicker) {
      state.writeError = "Member assignment is unavailable in this client.";
      render();
      return;
    }
    window.NRCLinksUI.openEntityPicker({
      anchor,
      sourceType: edgeTargets().Asset,
      sourceEntity: { convId: 0n, assetId: slice.sliceId },
      kinds: [kind],
      relation: { value: edgeRelations().MemberOf, label: "member-of" },
      className: "slice-member-picker",
      onSelect: (item, relation, isCancelled) => new Promise((resolve, reject) => {
        if (isCancelled()) return resolve();
        const sent = window.NRCEdges.sendCreateEdge(
          0n,
          kind === "task" ? edgeTargets().Task : edgeTargets().Asset, item.id,
          edgeTargets().Asset, slice.sliceId, edgeRelations().MemberOf,
          {
            onSuccess: () => {
              if (!isCancelled()) { invalidate({ debounce: false }); loadDetail(); }
              resolve();
            },
            onError: (detail) => reject(new Error(detail?.message || "Assign failed")),
          },
        );
        if (sent == null) reject(new Error("Request was not sent"));
      }),
    });
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  // A field the reader has typed into is the reader's text; a field that still
  // holds what was painted is the record's own value and follows the record. So
  // an update from elsewhere stays visible, and a background refresh — which
  // re-renders the record — cannot take text that was never saved. `painted` is
  // what the fields were last painted with, not what they are about to be.
  function liveDraft(painted) {
    const slice = selectedSlice();
    if (!painted || !slice || painted.sliceId !== slice.sliceId) return null;
    const owner = document.getElementById("sliceOwner");
    const outcome = document.getElementById("sliceOutcome");
    if (!owner && !outcome) return null;
    const draft = {
      owner: owner && owner.value !== painted.owner ? owner.value : null,
      outcome: outcome && outcome.value !== painted.outcome ? outcome.value : null,
    };
    if (draft.owner === null && draft.outcome === null) return null;
    // Where the caret sits is part of what the reader is doing, so the text goes
    // back where it was typed instead of to the end of the field.
    const focused = document.activeElement;
    if (focused === owner || focused === outcome) {
      draft.caret = { id: focused.id, start: focused.selectionStart, end: focused.selectionEnd };
    }
    return draft;
  }

  // The value goes back only when it differs, so a render that left the field
  // alone does not move the caret.
  function putFieldValue(field, value, caret) {
    if (field.value !== value) field.value = value;
    if (caret?.id === field.id && document.activeElement === field) {
      field.setSelectionRange(caret.start, caret.end);
    }
  }

  function applyDraft(draft) {
    if (!draft) return;
    const owner = document.getElementById("sliceOwner");
    if (owner && draft.owner !== null) putFieldValue(owner, draft.owner, draft.caret);
    const outcome = document.getElementById("sliceOutcome");
    if (outcome && draft.outcome !== null) putFieldValue(outcome, draft.outcome, draft.caret);
  }

  function render() {
    const view = document.getElementById("sliceView");
    if (!view) return;
    const list = document.getElementById("sliceRegisterList");
    const record = document.getElementById("sliceRecord");
    const status = document.getElementById("sliceStatus");
    const count = document.getElementById("sliceResultsCount");
    const createRow = document.getElementById("sliceCreateRow");
    const createButton = document.getElementById("sliceCreateBtn");

    const loaded = state.slices.length;
    if (count) {
      const open = state.slices.reduce((sum, slice) => sum + openCount(slice), 0);
      // The server says how many slices the filters match; the register draws the
      // pages it has asked for, so the head says how many of them those are. The
      // open count is folded from the drawn rows, like the task register's alerts.
      const scope = state.hasMore ? `${loaded} / ${state.total} SLICES` : `${state.total} SLICES`;
      const unassigned = state.unassignedTasks ? ` · ${state.unassignedTasks} TASKS WITHOUT A SLICE` : "";
      count.textContent = state.mode === "loading" && !loaded ? "LOADING SLICES…" : `${scope} / ${open} OPEN${unassigned}`;
    }

    if (status) {
      const message = state.mode === "error" ? state.error :
        state.pageError ? state.pageError :
        state.mode === "loading" && !loaded ? "LOADING SLICES…" :
        state.loadingMore ? "LOADING MORE SLICES…" :
        state.mode === "ready" && !loaded && filterActive() ? "NO SLICES MATCH THE FILTER" :
        state.mode === "ready" && !loaded ? "NO SLICES IN THIS WORKSPACE" : "";
      status.textContent = message;
      status.dataset.state = state.mode === "error" || state.pageError ? "error" : "info";
      status.hidden = message === "";
    }

    if (createRow) createRow.hidden = !state.createOpen;
    if (createButton) createButton.setAttribute("aria-expanded", String(state.createOpen));

    const slice = selectedSlice();
    const fields = slice ? recordFields(slice) : null;
    const draft = liveDraft(paintedFields);
    updateHtml(list, state.slices.map(renderRow).join(""));
    const detailReady = !slice ||
      (state.detail.mode === "ready" && state.detailSliceId === slice.sliceId);
    if (record) {
      record.inert = !detailReady;
      record.setAttribute("aria-busy", String(Boolean(slice) && detailLoading));
    }
    if (record && !detailReady) {
      if (state.detail.mode === "error") {
        updateHtml(record, `<p class="slice-empty">${escape(state.detail.error)}</p>`);
        record.inert = false;
      }
      syncFilterControls();
      return;
    }
    const previousOwner = document.getElementById("sliceOwner");
    updateHtml(record, renderRecord(fields), { preserveSections: paintedFields?.sliceId === slice?.sliceId });
    // The fields are painted with the record's own values; what the reader typed
    // over them is put back, and remembered for the next render to read again.
    paintedFields = fields;
    applyDraft(draft);

    // Retained fields already have their autocomplete listeners.
    const owner = document.getElementById("sliceOwner");
    if (owner !== previousOwner || !ownerAutocomplete) {
      ownerAutocomplete = window.NRCTasks?.attachUserAutocomplete?.({
        input: owner,
        dropdown: document.getElementById("sliceOwnerDropdown"),
      }) ?? null;
    }

    // The filter controls are painted from the state on every render, so a
    // listing that arrived with new owners offers them without a second path.
    syncFilterControls();
  }

  function renderRow(slice) {
    const selected = slice.name === state.selected;
    const classes = ["slice-row"];
    if (isClosed(slice)) classes.push("slice-row--closed");
    const idleHours = ageHours(slice.lastMovedAt);
    if (idleHours !== null && idleHours >= REGISTER_STALE_HOURS) classes.push("slice-row--cold");
    return `<button type="button" class="${classes.join(" ")}" data-slice-name="${escape(slice.name)}" aria-pressed="${selected}">
      <span class="slice-row-copy">
        <span class="slice-row-head">
          <strong class="slice-row-title">${escape(slice.name)}</strong>
          <span class="slice-row-count">${memberCount(slice)} MEM</span>
        </span>
        ${renderShape(slice)}
        <span class="slice-row-meta">${metaLine(slice)}</span>
      </span>
    </button>`;
  }

  function renderRecord(fields) {
    const slice = selectedSlice();
    if (!slice || !fields) {
      return `<p class="slice-empty">Select a slice to see its members, outcome and closure.</p>`;
    }
    const members = state.members;
    const notes = state.notes;
    const files = state.files;
    const closed = isClosed(slice);
    // The record carries the owner, the outcome and the closure, so the write
    // buttons stay out of reach until it is loaded: saving an empty form would
    // erase what the slice already says.
    const ready = state.detail.mode === "ready";
    const locked = state.writePending || !ready;

    const facts = [
      ["TASKS", taskCount(slice), false],
      ["OPEN", openCount(slice), openCount(slice) > 6],
      ["BLOCKED", slice.blocked, slice.blocked > 0],
      ["DONE", slice.done, false],
      ["NOTES", slice.notes, false],
      ["FILES", slice.files, false],
      ["OLDEST OPEN", formatAge(slice.oldestActiveAt), false],
      ["LAST MOVED", formatAge(slice.lastMovedAt), false],
    ];

    // The detail gate above calls this only after every member has landed. The
    // record can therefore draw one mark per task without a partial fallback.
    const stripMarks = members.tasks.length ? memberMarks(members.tasks) : null;
    const shapeNote = stripMarks ? "CREATION ORDER, OLDEST LEFT" : "NO TASK MEMBERS TO DRAW";

    const outcome = fields.outcome;
    const owner = fields.owner;

    return `
      <button class="btn slice-mobile-back mobile-only" type="button" data-slice-action="back">← SLICES</button>
      <div class="slice-identity">
        <div>
          <span class="slice-note">SLICE #${slice.sliceId} / ${closed ? "CLOSED" : "ACTIVE"} / OPENED ${formatAge(slice.oldestActiveAt)} AGO</span>
          <h2>${escape(slice.name)}</h2>
        </div>
        <div class="slice-identity-actions">
          <button class="btn" data-slice-action="save" ${locked ? "disabled" : ""}>SAVE</button>
          ${closed
            ? `<button class="btn" data-slice-action="reopen" ${locked ? "disabled" : ""}>REOPEN SLICE</button>`
            : `<button class="btn btn--danger" data-slice-action="close" ${locked ? "disabled" : ""}>CLOSE SLICE</button>`}
          <button class="btn btn--danger" data-slice-action="delete" ${locked ? "disabled" : ""}>DELETE SLICE</button>
        </div>
      </div>
      ${state.writeError ? `<p class="slice-status-line" data-state="error">${escape(state.writeError)}</p>` : ""}
      ${state.refreshError ? `<p class="slice-status-line" data-state="error">${escape(state.refreshError)}</p>` : ""}
      <dl class="slice-facts">${facts.map(([label, value, alert]) =>
        `<div><dt>${label}</dt><dd class="${alert ? "slice-alert" : ""}">${escape(value)}</dd></div>`).join("")}</dl>
      <div class="slice-record-shape">
        ${stripMarks ? renderStrip(stripMarks, RECORD_MARK_CAP, { wide: true }) : renderShape(slice, { wide: true })}
        <p class="slice-strip-legend">${shapeNote}${stripMarks ? " · BACKLOG · TODO · IN PROGRESS · DONE · RED SPIKE BLOCKED" : ""}</p>
      </div>
      <div class="slice-record-fields">
        <div class="slice-field slice-field--owner">
          <label class="slice-note" for="sliceOwner">OWNER</label>
          <div class="slice-owner-wrapper">
            <input class="filter-input slice-owner-input" id="sliceOwner" type="text" maxlength="${MAX_OWNER_LENGTH}" placeholder="UNASSIGNED" value="${escape(owner)}" autocomplete="off">
            <div id="sliceOwnerDropdown" class="assignee-dropdown hidden"></div>
          </div>
        </div>
        <div class="slice-field slice-field--outcome">
          <label class="slice-note" for="sliceOutcome">OUTCOME</label>
          <textarea class="filter-input slice-outcome-input" id="sliceOutcome" rows="1" maxlength="${MAX_OUTCOME_LENGTH}" placeholder="One sentence. A slice is done when this is true.">${escape(outcome)}</textarea>
        </div>
      </div>
      <section class="slice-section">
        <div class="panel-header"><div><span>MEMBERS / ${taskCount(slice)}</span><button class="btn" data-slice-action="assign" data-slice-kind="task" ${state.writePending ? "disabled" : ""}>+ ASSIGN TASK</button></div></div>
        ${renderMembers(members)}
      </section>
      <section class="slice-section">
        <div class="panel-header"><div><span>NOTES / ${slice.notes}</span><button class="btn" data-slice-action="assign" data-slice-kind="note" ${state.writePending ? "disabled" : ""}>+ ASSIGN NOTE</button></div></div>
        ${renderNotes(notes)}
      </section>
      <section class="slice-section">
        <div class="panel-header"><div><span>FILES / ${slice.files}</span><button class="btn" data-slice-action="assign" data-slice-kind="file" ${state.writePending ? "disabled" : ""}>+ ASSIGN FILE</button></div></div>
        ${renderFiles(files)}
      </section>
      <p class="slice-footnote">MEMBERS ARE ASSIGNED. A LABEL SAYS WHICH REPOSITORY SOMETHING BELONGS TO; A SLICE SAYS WHICH WORK STREAM IT MOVES.</p>`;
  }

  function renderMembers(members) {
    if (!members.tasks.length) {
      return `<p class="slice-empty">No tasks are assigned to this slice. Use + ASSIGN TASK to add one.</p>`;
    }
    const head = `<div class="slice-member-head slice-member--task"><span>ID</span><span>PRI</span><span>TITLE</span><span>STATUS</span><span>ASN</span><span>DUE</span><span>BLK</span><span></span></div>`;
    const rows = members.tasks.map((task) => {
      const status = ["backlog", "todo", "inprogress", "done"][task.status] ?? "backlog";
      const blocked = Boolean(task.blockedBy && task.blockedBy !== 0n);
      const identity = `task:${task.id}`;
      const selected = activeMember?.sliceId === state.detailSliceId && activeMember.open === identity;
      // The status a row draws is the control that changes it, so a member is
      // re-statused without opening it. The token and the menu are the task
      // register's, so one task reads the same in both tables.
      return `<div class="slice-member slice-member--task${selected ? " slice-member-selected" : ""}" data-member-task="${task.id}">
        <span class="slice-dim">#${task.id}</span>
        <span class="slice-dim">${window.NRCTasks?.fieldControl?.(task, "priority", { label: "" }) ?? task.priority ?? 0}</span>
        <span class="inline-title"><button type="button" class="slice-member-open" data-member-open="${identity}"${selected ? ' aria-current="true"' : ""}>${escape(task.title || "untitled")}</button>${window.NRCTasks?.fieldControl?.(task, "title", { label: "", rename: true }) || ""}</span>
        <button type="button" class="status-badge task-row-status status-${status}" data-member-status="${task.id}" aria-haspopup="listbox" aria-expanded="false" aria-label="Status ${STATUS_LABEL[status]} — change status">${STATUS_LABEL[status]}</button>
        <span class="slice-dim">${window.NRCTasks?.fieldControl?.(task, "assignee", { label: "" }) ?? escape(task.assignee || "—")}</span>
        <span class="slice-dim">${window.NRCTasks?.fieldControl?.(task, "dueAt", { label: "" }) ?? formatAge(task.dueAt)}</span>
        <span class="${blocked ? "slice-alert" : "slice-dim"}">${window.NRCTasks?.fieldControl?.(task, "blockedBy", { label: "" }) ?? (blocked ? `#${task.blockedBy}` : "—")}</span>
        <button type="button" class="btn btn--row" data-slice-unassign="task" data-slice-member="${task.id}" ${state.writePending ? "disabled" : ""}>UNASSIGN</button>
      </div>`;
    }).join("");
    return `<div class="slice-members">${head}${rows}</div>`;
  }

  function renderNotes(notes) {
    if (!notes.assets.length) return `<p class="slice-empty">No notes are assigned to this slice.</p>`;
    const head = `<div class="slice-member-head slice-member--plain"><span>ID</span><span>TITLE</span><span>AGE</span><span>MOD</span><span></span></div>`;
    const rows = notes.assets.map((asset) => {
      let title = `Note #${asset.assetId}`;
      try {
        const parsed = JSON.parse(asset.preview);
        if (parsed && typeof parsed.title === "string" && parsed.title) title = parsed.title;
      } catch { /* a note without a decodable preview keeps its ID as its title */ }
      const identity = `note:${asset.assetId}`;
      const selected = activeMember?.sliceId === state.detailSliceId && activeMember.open === identity;
      return `<div class="slice-member slice-member--plain${selected ? " slice-member-selected" : ""}" data-member-note="${asset.assetId}">
        <span class="slice-dim">#${asset.assetId}</span>
        <span class="inline-title"><button type="button" class="slice-member-open" data-member-open="${identity}"${selected ? ' aria-current="true"' : ""}>${escape(title)}</button>${window.NRCNotes?.fieldControl?.(asset, "title", { label: "", rename: true }) || ""}</span>
        <span class="slice-dim">${formatAge(asset.createdAt)}</span>
        <span class="slice-dim">${formatAge(asset.updatedAt)}</span>
        <button type="button" class="btn btn--row" data-slice-unassign="note" data-slice-member="${asset.assetId}" ${state.writePending ? "disabled" : ""}>UNASSIGN</button>
      </div>`;
    }).join("");
    return `<div class="slice-members">${head}${rows}</div>`;
  }

  function renderFiles(files) {
    if (!files.assets.length) return `<p class="slice-empty">No files are assigned to this slice.</p>`;
    const head = `<div class="slice-member-head slice-member--file"><span>ID</span><span>TITLE</span><span>CATEGORY</span><span>SIZE</span><span></span></div>`;
    const rows = files.assets.map((asset) => {
      const parsed = fileMetadata(asset);
      const identity = `file:${asset.assetId}`;
      const selected = activeMember?.sliceId === state.detailSliceId && activeMember.open === identity;
      return `<div class="slice-member slice-member--file${selected ? " slice-member-selected" : ""}" data-member-file="${asset.assetId}">
        <span class="slice-dim">#${asset.assetId}</span>
        <button type="button" class="slice-member-open" data-member-open="${identity}"${selected ? ' aria-current="true"' : ""}>${escape(parsed.title)}</button>
        <span class="slice-dim">${escape(parsed.category)}</span>
        <span class="slice-dim">${escape(parsed.size)}</span>
        <button type="button" class="btn btn--row" data-slice-unassign="file" data-slice-member="${asset.assetId}" ${state.writePending ? "disabled" : ""}>UNASSIGN</button>
      </div>`;
    }).join("");
    return `<div class="slice-members">${head}${rows}</div>`;
  }

  function fileMetadata(asset) {
    const parsed = { title: `File #${asset.assetId}`, category: "—", size: "—" };
    try {
      const preview = JSON.parse(asset.preview);
      if (preview && typeof preview.title === "string" && preview.title) parsed.title = preview.title;
      if (preview && typeof preview.category === "string" && preview.category) parsed.category = preview.category;
      if (preview && typeof preview.size === "string" && preview.size) parsed.size = preview.size;
    } catch { /* a file without a decodable preview keeps its ID as its title */ }
    return parsed;
  }

  // ---------------------------------------------------------------------------
  // Keyboard navigation
  // ---------------------------------------------------------------------------
  //
  // The register and the record's member tables are lists like every other list
  // in the client, so the arrow keys walk them and the row that moves is the row
  // that opens. In the register an arrow changes the selection, which is what
  // puts a record on screen; in a member table it opens the adjacent member in
  // the inspector, which is where a member is read.

  function isEditableTarget(target) {
    if (!target) return false;
    const tagName = target.tagName;
    return tagName === "INPUT" || tagName === "TEXTAREA" || tagName === "SELECT" || target.isContentEditable;
  }

  function keyboardActive() {
    const view = document.getElementById("sliceView");
    return window.NRCListNavigation.isKeyboardViewActive(
      window.NRCViewManager?.getActiveView?.(),
      "kanban",
      active(),
      view?.style.display !== "none",
      Boolean(view?.querySelector("[data-slice-name]")),
    );
  }

  // On a phone the register is the surface and the record is a drill-in, so a
  // register that is off screen is not a register the arrows may move.
  function registerVisible() {
    return Boolean(document.querySelector("#sliceView .slice-register")?.getClientRects().length);
  }

  async function selectAdjacentSlice(direction) {
    const rows = Array.from(document.querySelectorAll("#sliceRegisterList [data-slice-name]"));
    let adjacent = window.NRCListNavigation.resolveAdjacent(
      rows,
      state.selected,
      direction,
      (row) => row.dataset.sliceName,
    );
    // A filter can hide the slice the record is open on, and the record stays
    // where the reader left it: the walk enters the drawn rows from there
    // instead of stopping at a selection that is not among them.
    if (adjacent.status === "missing-selection") {
      adjacent = window.NRCListNavigation.resolveAdjacent(rows, null, direction, (row) => row.dataset.sliceName);
    }
    if (adjacent.status !== "target") {
      // The walk reached the end of what is drawn: when the server has more, the
      // next page is asked for so the following keypress has somewhere to go.
      if (adjacent.status === "boundary" && direction > 0) loadMore();
      return false;
    }
    const name = adjacent.row.dataset.sliceName;
    // The guard can decline, and a declined answer leaves the register where it
    // was: the row that would have moved is not focused either.
    if (!(await selectGuarded(name))) return false;
    // The register is re-rendered with the new selection, so the row that moved
    // is read back from the markup instead of reused from the old render.
    const row = document.querySelector(`#sliceRegisterList [data-slice-name="${CSS.escape(name)}"]`);
    row?.focus({ preventScroll: true });
    row?.scrollIntoView({ block: "nearest" });
    return true;
  }

  function memberOpenIdentity(row) {
    return row?.querySelector(".slice-member-open")?.dataset.memberOpen ?? null;
  }

  function activateMemberRow(row) {
    const opener = row?.querySelector(".slice-member-open");
    if (!opener?.dataset.memberOpen) return false;
    activeMember = { sliceId: state.detailSliceId, open: opener.dataset.memberOpen };
    const record = row.closest?.("#sliceRecord") ?? document.getElementById("sliceRecord");
    record?.querySelectorAll?.(".slice-member-selected").forEach((member) => {
      member.classList.remove("slice-member-selected");
      member.querySelector(".slice-member-open")?.removeAttribute("aria-current");
    });
    row.classList.add("slice-member-selected");
    opener.setAttribute("aria-current", "true");
    return true;
  }

  function memberRows(row) {
    return Array.from(row?.parentElement?.querySelectorAll(":scope > .slice-member") ?? []);
  }

  // Opening a member is one act, whether a click or an arrow key reaches it: the
  // row carries the reference and the inspector is where it opens. The opener
  // takes focus, so the row the reader is in draws the focus outline.
  function openMemberRow(row) {
    const opener = row?.querySelector(".slice-member-open");
    const [kind, id] = (opener?.dataset.memberOpen ?? "").split(":");
    if (!kind || !id) return false;
    activateMemberRow(row);
    opener.focus({ preventScroll: true });
    row.scrollIntoView({ block: "nearest" });
    window.NRCInspector?.openEntity?.({ roomId: 0n, type: kind, id: BigInt(id) });
    return true;
  }

  // One table at a time, the way every other list in the client is walked: the
  // row an arrow starts from is the focused one, or the member the reader last
  // opened when focus is on the record itself. A boundary holds.
  function walkMemberTable(row, direction) {
    const adjacent = window.NRCListNavigation.resolveAdjacent(
      memberRows(row), memberOpenIdentity(row), direction, memberOpenIdentity,
    );
    return adjacent.status === "target" ? openMemberRow(adjacent.row) : false;
  }

  function rememberedMemberRow(record) {
    if (!record || activeMember?.sliceId !== state.detailSliceId) return null;
    const opener = record.querySelector(`.slice-member-open[data-member-open="${CSS.escape(activeMember.open)}"]`);
    return opener?.closest(".slice-member") ?? null;
  }

  function handleKeyboardNavigation(event) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    if (!keyboardActive()) return;
    if (event.defaultPrevented || event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) return;
    if (isEditableTarget(event.target)) return;
    if (event.target.closest?.("#inspector, [role=dialog], [role=menu], [role=listbox]")) return;
    if (window.NRCLinksUI?.isPickerVisible?.()) return;

    const direction = event.key === "ArrowDown" ? 1 : -1;
    const record = event.target.closest?.("#sliceRecord") ?? null;
    const memberRow = record ? event.target.closest(".slice-member") : null;
    if (memberRow) {
      event.preventDefault();
      walkMemberTable(memberRow, direction);
      return;
    }
    // A click on a member row leaves focus on the record itself, so the arrow
    // reads the member the reader last opened instead of the focused node.
    const remembered = rememberedMemberRow(record);
    if (remembered) {
      event.preventDefault();
      walkMemberTable(remembered, direction);
      return;
    }
    // A key pressed in the record belongs to the record: it holds the slice's
    // own fields and controls, and moving the register's selection from there
    // would take the record away from under the reader.
    if (record || event.target.closest?.(".slice-create-row")) return;
    if (!registerVisible()) return;
    event.preventDefault();
    selectAdjacentSlice(direction);
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  function init() {
    window.NRCEdges?.addEdgeChangeListener?.(onEdgeChanged);
    const view = document.getElementById("sliceView");
    if (!view) return;

    view.addEventListener("click", (event) => {
      // The owner dropdown belongs to the field, not to the view: a click
      // anywhere else dismisses it before the click is interpreted.
      const ownerField = document.getElementById("sliceOwner");
      if (ownerField && !ownerField.contains(event.target) &&
          !document.getElementById("sliceOwnerDropdown")?.contains(event.target)) {
        ownerAutocomplete?.hide();
      }
      const row = event.target.closest("[data-slice-name]");
      if (row) {
        selectGuarded(row.dataset.sliceName);
        return;
      }
      const action = event.target.closest("[data-slice-action]");
      if (action) {
        const slice = selectedSlice();
        switch (action.dataset.sliceAction) {
          case "new":
            state.createOpen = !state.createOpen;
            state.writeError = "";
            render();
            document.getElementById("sliceCreateName")?.focus();
            return;
          case "cancel-create":
            state.createOpen = false;
            render();
            return;
          case "create": {
            const name = document.getElementById("sliceCreateName")?.value ?? "";
            createSlice(name);
            return;
          }
          case "save":
            if (slice) saveRecord();
            return;
          case "close":
            if (slice) closeSlice(slice);
            return;
          case "reopen":
            if (slice) reopenSlice(slice);
            return;
          case "delete":
            if (slice) deleteSlice(slice);
            return;
          case "assign":
            openMemberPicker(action, action.dataset.sliceKind);
            return;
          case "back":
            view.dataset.sliceMobileDetail = "false";
            return;
        }
      }
      const unassign = event.target.closest("[data-slice-unassign]");
      if (unassign) {
        unassignMember(unassign.dataset.sliceUnassign, BigInt(unassign.dataset.sliceMember));
        return;
      }
      // A member's status is a control, and it is matched before the row: the
      // menu belongs to the token, not to the reference the row carries.
      const statusToken = event.target.closest("[data-member-status]");
      if (statusToken) {
        const task = state.members.tasks.find((member) => member.id === BigInt(statusToken.dataset.memberStatus));
        if (task) window.NRCTasks?.openTaskStatusMenu?.(statusToken, task);
        return;
      }
      const member = event.target.closest("[data-member-task], [data-member-note], [data-member-file]");
      if (member) {
        // A member is a reference to an entity that lives in its own view, so it
        // opens in the inspector like every other reference in the client. The
        // attribute sits on the row, so the whole member is the target and not
        // only its title; UNASSIGN is matched above and keeps its own action.
        openMemberRow(member);
        return;
      }
    });

    view.addEventListener("keydown", (event) => {
      if (event.key !== "Enter") return;
      if (event.target?.id !== "sliceCreateName") return;
      event.preventDefault();
      createSlice(event.target.value);
    });

    // The filter controls live in the register bar the task filters share, so they
    // are bound by id rather than through the slice view. Every change asks the
    // server for the listing again, because the page on screen was folded for the
    // filter it was asked with.
    const ownerFilter = document.getElementById("sliceOwnerFilter");
    ownerFilter?.addEventListener("change", () => {
      setOwnerFilter(ownerFilter.value);
    });
    const queryFilter = document.getElementById("sliceQuery");
    queryFilter?.addEventListener("input", () => {
      setQuery(queryFilter.value);
    });

    // The register fills itself as the reader reaches its end.
    view.querySelector(".slice-register")?.addEventListener("scroll", loadMoreNearEnd, { passive: true });

    // Where the focus is, the reader is: an opener reached with Tab anchors its
    // table the same way an opened member does, so the arrows continue there.
    view.addEventListener("focusin", (event) => {
      const opener = event.target.closest?.(".slice-member-open");
      if (opener?.dataset.memberOpen) {
        activateMemberRow(opener.closest(".slice-member"));
      }
    });

    document.addEventListener("keydown", handleKeyboardNavigation);
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  function ensureLoaded() {
    if (active()) requestList();
  }

  function isActive() {
    return active();
  }

  function onRoomSwitch() {
    ++detailGeneration;
    detailLoading = false;
    state.selected = null;
    state.detailSliceId = null;
    state.detail = { mode: "idle", error: "" };
    state.members = { mode: "idle", tasks: [] };
    state.notes = { mode: "idle", assets: [] };
    state.files = { mode: "idle", assets: [] };
    activeMember = null;
    state.createOpen = false;
    state.refreshError = "";
    state.cursor = null;
    state.hasMore = false;
    state.loadingMore = false;
    state.pageError = "";
    cancelHeadlessReads();
    // The owners of the previous workspace's listing are not the owners of this
    // one's, so the filter's options start over with it.
    seenOwners.clear();
    requestList({ force: true });
  }

  function disconnect() {
    ++detailGeneration;
    detailLoading = false;
    if (pendingList) {
      clearTimeout(pendingList.timer);
      pendingList.settle?.(false);
      pendingList = null;
    }
    cancelHeadlessReads();
    // A reconnect starts a new conversation with the server, so the next listing
    // is announced even if it happens to carry the same slices.
    listSignature = null;
    state.mode = state.slices.length ? state.mode : "idle";
    state.loadingMore = false;
    state.writePending = false;
    render();
  }

  function setIncludeClosed(value) {
    if (state.includeClosed === value) return;
    state.includeClosed = value;
    requestList({ force: true });
  }

  init();

  window.NRCSlices = {
    requestList,
    // A page of the register: the next one is asked for as the reader reaches the
    // end of the drawn rows, and `loadMore` is the same request a caller can drive.
    loadMore,
    loadMoreNearEnd,
    invalidate,
    handleSliceList,
    select,
    // The guarded selection is the interactive one, and `recordDirty` is what it
    // reads: both are exposed so a test can drive the question without a click.
    selectGuarded,
    recordDirty,
    isActive,
    ensureLoaded,
    setIncludeClosed,
    getIncludeClosed: () => state.includeClosed,
    // The register's filters: the owner, the name query and the reset that clears
    // both are exposed so the shared RESET and the tests drive one write path.
    setOwnerFilter,
    setQuery,
    resetFilters,
    getFilters: () => ({ ...state.filters }),
    filterActive,
    // A derived view (the attention register) folds a whole filtered listing
    // without touching the register's window: `readAll` walks its pages.
    readAll,
    getState: () => state,
    selectedSlice,
    render,
    renderShape,
    renderStrip,
    onRoomSwitch,
    disconnect,
    // Exposed for tests and for the slice record's own controls; a slice is the
    // only place membership is written, so the task list never assigns.
    assignMembers,
    unassignMember,
    openMemberPicker,
    createSlice,
    saveRecord,
    closeSlice,
    reopenSlice,
    deleteSlice,
    onAssetChanged,
    onAssetDeleted,
    onEdgeChanged,
    // The task register confirms a move through this module, so a member table
    // keeps the status the server answered with even when the move took the task
    // out of the partial task cache.
    onTaskMoved,
    isClosed,
    openCount,
    taskCount,
    memberCount,
    memberRefs,
  };
})();
