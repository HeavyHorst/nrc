// Mobile composition of the existing navigation and inspector, not a second app.
(() => {
  const mobile = matchMedia("(max-width: 768px)");
  const el = id => document.getElementById(id);
  const sidebar = el("primaryNavigation");
  let returnFocus = null;
  let openedRoom = null;
  let openedView = null;

  function closeNavigation() {
    document.body.classList.remove("mobile-navigation-open", "mobile-navigation-more");
    sidebar.removeAttribute("role");
    sidebar.removeAttribute("aria-modal");
    el("mobileRoomSwitch").setAttribute("aria-expanded", "false");
    el("mobileMore").setAttribute("aria-expanded", "false");
    syncInert();
    returnFocus?.focus();
    returnFocus = null;
  }

  function openNavigation(more, trigger) {
    if (!mobile.matches) return;
    returnFocus = trigger;
    openedRoom = currentRoomId;
    openedView = window.NRCViewManager.getActiveView();
    document.body.classList.add("mobile-navigation-open");
    document.body.classList.toggle("mobile-navigation-more", more);
    el("mobileNavigationTitle").textContent = more ? "WORKSPACE VIEWS" : "CHATS & DMS";
    trigger.setAttribute("aria-expanded", "true");
    sidebar.setAttribute("role", "dialog");
    sidebar.setAttribute("aria-modal", "true");
    syncInert();
    el("mobileNavigationClose").focus();
  }

  function syncInert() {
    const navigationOpen = mobile.matches && document.body.classList.contains("mobile-navigation-open");
    const inspectorOpen = mobile.matches && document.body.classList.contains("inspector-open");
    for (const selector of [".main-area", ".mobile-mast", ".mobile-bottom"]) {
      document.querySelector(selector).inert = navigationOpen || inspectorOpen;
    }
    sidebar.inert = inspectorOpen || (mobile.matches && !navigationOpen);
    if (!navigationOpen && !inspectorOpen) window.NRCChat.markRead();
  }

  function sync() {
    const view = window.NRCViewManager.getActiveView();
    el("mobileRoomName").textContent = view === "chat" ? getRoomName(currentRoomId) : view === "systemLog" ? "SYSTEM" : "WORKSPACE";
    el("mobileConnection").textContent = el("connectionStatus").textContent;
    el("mobileMoreUnread").hidden = el("sullivanViewUnread").hidden;
    document.querySelectorAll("[data-mobile-view]").forEach(button => {
      const selected = button.dataset.mobileView === view || button.dataset.mobileView === "notes" && view === "noteShare";
      if (selected) button.setAttribute("aria-current", "page");
      else button.removeAttribute("aria-current");
    });
    if (!["chat", "kanban", "notes", "noteShare"].includes(view)) el("mobileMore").setAttribute("aria-current", "page");
    else el("mobileMore").removeAttribute("aria-current");
    document.body.classList.toggle("mobile-chat-view", view === "chat");
    if (returnFocus && (currentRoomId !== openedRoom || view !== openedView)) closeNavigation();
    syncInert();
  }

  el("mobileRoomSwitch").onclick = event => openNavigation(false, event.currentTarget);
  el("mobileMore").onclick = event => openNavigation(true, event.currentTarget);
  el("mobileNavigationClose").onclick = closeNavigation;
  el("mobileCommands").onclick = () => { closeNavigation(); CommandPalette.open(); };
  el("mobileCommandsClose").onclick = () => { CommandPalette.close(); el("mobileMore").focus(); };
  document.addEventListener("click", event => {
    const toggle = event.target.closest(".mobile-metadata-toggle");
    if (toggle) toggle.setAttribute("aria-expanded", String(toggle.getAttribute("aria-expanded") !== "true"));
  });
  el("mobileInspectorBack").onclick = () => {
    if (el("inspectorBack").disabled) window.NRCInspector.close();
    else window.NRCInspector.back();
  };
  el("mobileChatTools").onclick = () => {
    const open = document.body.classList.toggle("mobile-chat-tools-open");
    el("mobileChatTools").setAttribute("aria-expanded", String(open));
  };
  document.querySelectorAll("[data-mobile-filters]").forEach(button => {
    button.onclick = () => {
      const open = button.closest(".panel-header").classList.toggle("mobile-filters-open");
      button.setAttribute("aria-expanded", String(open));
      el("mobileTaskSort").value = TaskViewState.sortColumn;
      el("mobileTaskSortDirection").textContent = TaskViewState.sortDirection === "asc" ? "ASCENDING ↑" : "DESCENDING ↓";
    };
  });
  el("mobileTaskSort").onchange = () => {
    document.querySelector(`.task-table th[data-sort="${el("mobileTaskSort").value}"]`).click();
    el("mobileTaskSortDirection").textContent = TaskViewState.sortDirection === "asc" ? "ASCENDING ↑" : "DESCENDING ↓";
  };
  el("mobileTaskSortDirection").onclick = () => {
    document.querySelector(`.task-table th[data-sort="${TaskViewState.sortColumn}"]`).click();
    el("mobileTaskSortDirection").textContent = TaskViewState.sortDirection === "asc" ? "ASCENDING ↑" : "DESCENDING ↓";
  };
  document.querySelectorAll("[data-mobile-target]").forEach(button => {
    button.onclick = () => {
      if (button.dataset.mobileView === "chat") openChatRoom(currentRoomId);
      else if (window.NRCViewManager.getActiveView() !== button.dataset.mobileView) el(button.dataset.mobileTarget).click();
      sync();
    };
  });
  sidebar.addEventListener("click", event => {
    // Selecting the already-current room/view also dismisses the switcher.
    if (event.target.closest(".room-item.active, .sidebar-nav-item.active")) closeNavigation();
  });
  sidebar.addEventListener("keydown", event => {
    if (!returnFocus) return;
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); closeNavigation(); }
    if (event.key !== "Tab") return;
    const controls = [...sidebar.querySelectorAll("button, input, [tabindex='0']")].filter(node => node.offsetParent !== null && !node.disabled);
    const first = controls[0], last = controls.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  });
  const observer = new MutationObserver(sync);
  for (const id of ["sidebarViewRoomName", "connectionStatus", "mobileChatUnread", "sullivanViewUnread"]) {
    observer.observe(el(id), { childList: true, characterData: true, subtree: true, attributes: true });
  }
  new MutationObserver(syncInert).observe(document.body, { attributes: true, attributeFilter: ["class"] });
  mobile.addEventListener("change", () => { closeNavigation(); sync(); updateViewport(); });

  function updateViewport() {
    const viewport = window.visualViewport;
    // Do not counteract pinch zoom. On iOS the keyboard resizes only this viewport.
    if (mobile.matches && viewport && viewport.scale === 1) {
      document.documentElement.style.setProperty("--mobile-viewport-height", `${viewport.height}px`);
      document.documentElement.style.setProperty("--mobile-viewport-top", `${viewport.offsetTop}px`);
    } else {
      document.documentElement.style.removeProperty("--mobile-viewport-height");
      document.documentElement.style.removeProperty("--mobile-viewport-top");
    }
  }
  window.visualViewport?.addEventListener("resize", updateViewport);
  window.visualViewport?.addEventListener("scroll", updateViewport);
  sync();
  updateViewport();
})();
