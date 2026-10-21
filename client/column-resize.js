(function () {
  "use strict";

  const observers = new WeakMap();

  function init({ root, headers, storageKey, defaults, minimums = [], maximums = [], locked = [], viewport, flexible, apply }) {
    const container = document.querySelector(root);
    if (!container || container.dataset.columnResizeReady) return;
    container.dataset.columnResizeReady = "true";
    const lockedColumns = new Set(locked);
    const minimumWidth = (index) => Number(minimums[index]) || Math.min(36, Number(defaults[index]) || 36);
    const maximumWidth = (index) => Number(maximums[index]) || 640;
    const clampWidth = (value, index) => Math.max(minimumWidth(index), Math.min(value, maximumWidth(index)));
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
    const headerCells = Array.from(container.querySelectorAll(headers));
    // Flexible columns can grow beyond their saved minimum. Start at the
    // visible boundary, including after the register itself changes width.
    const currentWidth = (index) => headerCells[index].getBoundingClientRect().width;
    const host = document.querySelector(viewport);
    const floor = (index) => lockedColumns.has(index) ? defaults[index] : minimumWidth(index);
    const preferences = () => widths.map((width, index) => width ?? floor(index));
    let scale = 1;
    const commit = () => {
      // Keep persisted preferences intact. Fit the rendered widths only, so a
      // larger window restores the user's choices instead of saving the squeeze.
      const preferred = preferences();
      const minimum = preferred.reduce((sum, _, index) => sum + floor(index), 0);
      const spare = preferred.reduce((sum, width, index) => sum + width - floor(index), 0);
      scale = host.clientWidth > 0 && spare > 0 ? Math.max(0, Math.min(1, (host.clientWidth - minimum) / spare)) : 1;
      const fitted = preferred.map((width, index) => floor(index) + (width - floor(index)) * scale);
      apply(container, fitted);
      handles.forEach(({ handle, index }) => handle.setAttribute("aria-valuenow", String(Math.round(currentWidth(index)))));
    };
    commit();
    observers.get(host)?.disconnect();
    const observer = new ResizeObserver(() => {
      if (!container.isConnected) { observer.disconnect(); return; }
      commit();
    });
    observers.set(host, observer);
    observer.observe(host);

    // Exchange space with TITLE when it follows the handle, otherwise the next column. Invert the
    // current compression so dragging right also grows a compressed column.
    // Only the two edited preferences change; passive fitting never persists.
    const resizeStart = () => {
      const preferred = preferences();
      if (scale === 1) preferred[flexible] = currentWidth(flexible);
      return { preferred, scale };
    };
    const resize = (index, pixels, start) => {
      if (!start.scale) return;
      const next = index < flexible ? flexible : index + 1;
      const delta = Math.max(
        Math.max(floor(index) - start.preferred[index], start.preferred[next] - Math.max(maximumWidth(next), start.preferred[next])),
        Math.min(pixels / start.scale, Math.max(maximumWidth(index), start.preferred[index]) - start.preferred[index], start.preferred[next] - floor(next)),
      );
      widths[index] = start.preferred[index] + delta;
      widths[next] = start.preferred[next] - delta;
      commit();
    };

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
      handle.setAttribute("aria-valuemax", String(maximumWidth(index)));
      handle.setAttribute("aria-valuenow", String(Math.round(currentWidth(index))));
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
        resize(index, event.key === "ArrowRight" ? 8 : -8, resizeStart());
        localStorage.setItem(storageKey, JSON.stringify(widths));
      });
      handle.addEventListener("pointerdown", (event) => {
        if (!event.isPrimary || event.button !== 0 || handle.hasPointerCapture(event.pointerId)) return;
        event.preventDefault(); event.stopPropagation();
        const pointerId = event.pointerId;
        const startX = event.clientX;
        const start = resizeStart();
        dragging = true;
        handle.classList.add("column-resize-handle-dragging");
        container.classList.add("column-resize-dragging");
        activate();
        handle.setPointerCapture(pointerId);
        const move = (moveEvent) => {
          if (moveEvent.pointerId !== pointerId) return;
          resize(index, moveEvent.clientX - startX, start);
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
