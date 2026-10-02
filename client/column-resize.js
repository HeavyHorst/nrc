(function () {
  "use strict";

  function init({ root, headers, storageKey, defaults, minimums = [], locked = [], apply }) {
    const container = document.querySelector(root);
    if (!container || container.dataset.columnResizeReady) return;
    container.dataset.columnResizeReady = "true";
    const lockedColumns = new Set(locked);
    const minimumWidth = (index) => Number(minimums[index]) || Math.min(36, Number(defaults[index]) || 36);
    const clampWidth = (value, index) => Math.max(minimumWidth(index), Math.min(value, 640));
    const normalizeWidths = (values) => values.map((value, index) => {
      if (lockedColumns.has(index)) return defaults[index];
      const width = Number(value);
      return Number.isFinite(width) && width > 0 ? clampWidth(width, index) : defaults[index];
    });
    let widths = defaults.slice();
    try {
      const saved = JSON.parse(localStorage.getItem(storageKey));
      if (Array.isArray(saved) && saved.length === widths.length) {
        widths = normalizeWidths(saved);
        localStorage.setItem(storageKey, JSON.stringify(widths));
      }
      else if (saved != null) localStorage.removeItem(storageKey);
    } catch (_) {
      localStorage.removeItem(storageKey);
    }
    const handles = [];
    const commit = () => {
      apply(container, widths);
      handles.forEach(({ handle, index }) => handle.setAttribute("aria-valuenow", String(Math.round(widths[index]))));
    };
    commit();

    const headerCells = Array.from(container.querySelectorAll(headers));
    headerCells.forEach((header, index) => {
      if (index >= widths.length - 1 || lockedColumns.has(index)) return;
      const nextHeader = headerCells[index + 1];
      const handle = document.createElement("span");
      handle.className = "column-resize-handle";
      handle.tabIndex = 0;
      handle.title = "Drag to resize. Double-click or press Home to reset all columns.";
      handle.setAttribute("role", "separator");
      handle.setAttribute("aria-orientation", "vertical");
      handle.setAttribute("aria-label", `Resize ${header.textContent.trim() || "column"} column`);
      handle.setAttribute("aria-valuemin", String(minimumWidth(index)));
      handle.setAttribute("aria-valuemax", "640");
      handle.setAttribute("aria-valuenow", String(Math.round(widths[index])));
      handles.push({ handle, index });

      let dragging = false;
      const activate = () => {
        header.classList.add("column-resize-active");
        nextHeader?.classList.add("column-resize-adjacent");
      };
      const deactivate = () => {
        if (dragging || handle.matches(":hover") || document.activeElement === handle) return;
        header.classList.remove("column-resize-active");
        nextHeader?.classList.remove("column-resize-adjacent");
      };
      handle.addEventListener("pointerenter", activate);
      handle.addEventListener("pointerleave", deactivate);
      handle.addEventListener("focus", activate);
      handle.addEventListener("blur", deactivate);

      const reset = () => { widths = defaults.slice(); commit(); localStorage.removeItem(storageKey); };
      handle.addEventListener("dblclick", (event) => { event.preventDefault(); event.stopPropagation(); reset(); });
      handle.addEventListener("click", (event) => { event.preventDefault(); event.stopPropagation(); });
      handle.addEventListener("keydown", (event) => {
        if (event.key === "Home") {
          event.preventDefault(); event.stopPropagation(); reset();
          return;
        }
        if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
        event.preventDefault(); event.stopPropagation();
        widths[index] = clampWidth(widths[index] + (event.key === "ArrowRight" ? 8 : -8), index);
        commit(); localStorage.setItem(storageKey, JSON.stringify(widths));
      });
      handle.addEventListener("pointerdown", (event) => {
        if (!event.isPrimary || event.button !== 0 || handle.hasPointerCapture(event.pointerId)) return;
        event.preventDefault(); event.stopPropagation();
        const pointerId = event.pointerId;
        const startX = event.clientX;
        const start = widths[index];
        dragging = true;
        handle.classList.add("column-resize-handle-dragging");
        container.classList.add("column-resize-dragging");
        activate();
        handle.setPointerCapture(pointerId);
        const move = (moveEvent) => {
          if (moveEvent.pointerId !== pointerId) return;
          widths[index] = clampWidth(start + moveEvent.clientX - startX, index);
          commit();
        };
        const stop = (stopEvent) => {
          if (stopEvent.pointerId !== pointerId) return;
          handle.removeEventListener("pointermove", move);
          handle.removeEventListener("pointerup", stop);
          handle.removeEventListener("pointercancel", stop);
          handle.removeEventListener("lostpointercapture", stop);
          dragging = false;
          handle.classList.remove("column-resize-handle-dragging");
          container.classList.remove("column-resize-dragging");
          deactivate();
          localStorage.setItem(storageKey, JSON.stringify(widths));
        };
        handle.addEventListener("pointermove", move);
        handle.addEventListener("pointerup", stop);
        handle.addEventListener("pointercancel", stop);
        handle.addEventListener("lostpointercapture", stop);
      });
      header.append(handle);
    });
  }

  window.NRCColumnResize = { init };
})();
