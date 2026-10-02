// Shared modal shell. Native dialog owns inertness, modal stacking and focus
// restoration; callers own content, results and whether cancellation is safe.
const NRCModal = (() => {
  let sequence = 0;

  const activeRoot = () => [...document.querySelectorAll("dialog.nrc-dialog-backdrop[open]")].at(-1);

  function create({ title, className = "", onCancel = () => {}, closeButton = false }) {
    const root = document.createElement("dialog");
    root.className = "nrc-dialog-backdrop";
    const panel = document.createElement("div");
    panel.className = `nrc-dialog ${className}`.trim();
    const heading = document.createElement("div");
    heading.className = "nrc-dialog-title";
    heading.id = `nrcDialogTitle${++sequence}`;
    heading.textContent = title;
    root.setAttribute("aria-labelledby", heading.id);
    panel.append(heading);
    const actions = document.createElement("div");
    actions.className = "nrc-dialog-actions";
    panel.append(actions);
    root.append(panel);
    document.body.append(root);

    const focusable = () => [...panel.querySelectorAll("input, textarea, select, button, a[href], [tabindex], [contenteditable='true']")]
      .filter(el => el.tabIndex >= 0 && !el.matches(":disabled") && !el.closest("[inert]") && el.checkVisibility({ visibilityProperty: true }));
    const view = {
      root, panel, actions,
      canClose: () => true,
      show() {
        if (!root.isConnected || root.open) return;
        const toast = document.querySelector(".toast");
        if (toast) root.append(toast);
        root.showModal();
        const controls = focusable();
        (controls.find(el => el.matches("input, textarea, select")) || controls[0])?.focus();
      },
      close() {
        const toast = root.querySelector(".toast");
        root.close();
        root.remove();
        if (toast) (activeRoot() || document.body).append(toast);
      },
      cancel() {
        if (!view.canClose()) return;
        view.close();
        onCancel();
      },
    };
    if (closeButton) {
      const header = document.createElement("div");
      header.className = "nrc-dialog-header";
      panel.prepend(header);
      const close = document.createElement("button");
      close.type = "button";
      close.className = "btn btn--row nrc-dialog-close";
      close.textContent = "×";
      close.setAttribute("aria-label", "Close");
      close.onclick = () => view.cancel();
      header.append(heading, close);
    }
    root.addEventListener("cancel", event => {
      event.preventDefault();
      view.cancel();
    });
    root.addEventListener("keydown", event => {
      // Native dialog blocks the page, but Tab may still reach browser chrome.
      // Keep the existing wrap behavior, including all visible form controls.
      if (event.key === "Tab") {
        const controls = focusable();
        const first = controls[0], last = controls.at(-1);
        if (!first || event.shiftKey && document.activeElement === first ||
          !event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          (event.shiftKey ? last : first)?.focus();
        }
      }
      // Escape's native default action still fires cancel.
      event.stopPropagation();
    });
    return view;
  }

  return { create, activeRoot };
})();
window.NRCModal = NRCModal;
