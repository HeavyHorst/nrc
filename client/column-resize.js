(function () {
  "use strict";

  const observers = new WeakMap();

  function init({ root, headers, storageKey, defaults, minimums = [], maximums = [], locked = [], viewport, flexible, apply, independent = false, rows, resetControl }) {
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
    let manual = false;
    const save = () => localStorage.setItem(storageKey, JSON.stringify(independent && manual ? { widths, manual: true } : widths));
    try {
      const saved = JSON.parse(localStorage.getItem(storageKey));
      const values = independent && saved?.manual === true ? saved.widths : saved;
      if (Array.isArray(values) && values.length === widths.length) {
        manual = independent && saved?.manual === true;
        widths = normalizeWidths(values);
        save();
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
    const commit = () => {
      // Keep persisted preferences intact. Fit the rendered widths only, so a
      // larger window restores the user's choices instead of saving the squeeze.
      const preferred = preferences();
      if (manual) {
        apply(container, preferred, true);
        handles.forEach(({ handle, index }) => handle.setAttribute("aria-valuenow", String(Math.round(currentWidth(index)))));
        return;
      }
      const total = preferred.reduce((sum, width) => sum + width, 0);
      if (host.clientWidth > 0) {
        preferred[flexible] -= Math.min(Math.max(0, total - host.clientWidth), preferred[flexible] - floor(flexible));
      }
      const minimum = preferred.reduce((sum, _, index) => sum + floor(index), 0);
      const spare = preferred.reduce((sum, width, index) => sum + width - floor(index), 0);
      const scale = host.clientWidth > 0 && spare > 0 ? Math.max(0, Math.min(1, (host.clientWidth - minimum) / spare)) : 1;
      const fitted = preferred.map((width, index) => floor(index) + (width - floor(index)) * scale);
      apply(container, fitted, false);
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

    // Start at the visible widths, not the compressed preferences. Independent
    // columns keep this pixel layout; dependent columns exchange neighbor space.
    const resizeStart = () => headerCells.map((_, index) => currentWidth(index));
    const resize = (index, pixels, start) => {
      if (independent) {
        widths = start.slice();
        widths[index] = clampWidth(start[index] + pixels, index);
        manual = true;
        commit();
        return;
      }
      const next = index + 1;
      const delta = Math.max(
        Math.max(floor(index) - start[index], start[next] - Math.max(maximumWidth(next), start[next])),
        Math.min(pixels, Math.max(maximumWidth(index), start[index]) - start[index], start[next] - floor(next)),
      );
      widths = start.slice();
      widths[index] += delta;
      widths[next] -= delta;
      commit();
    };

    const reset = () => { manual = false; widths = defaults.slice(); commit(); localStorage.removeItem(storageKey); };
    if (resetControl) document.querySelector(resetControl).onclick = reset;
    const fitContent = (index) => {
      let width = minimumWidth(index);
      const cells = [headerCells[index], ...Array.from(document.querySelectorAll(rows), row => row.children[index])];
      for (const cell of cells) {
        if (!cell) continue;
        const clone = cell.cloneNode(true);
        clone.querySelectorAll('.column-resize-handle').forEach(handle => handle.remove());
        clone.removeAttribute('id');
        clone.inert = true;
        clone.style.cssText = 'position:absolute;visibility:hidden;display:block;width:max-content;min-width:0;max-width:none;white-space:nowrap;';
        clone.querySelectorAll('*').forEach(element => {
          element.removeAttribute('id');
          element.style.setProperty('max-width', 'none');
          element.style.setProperty('white-space', 'nowrap');
        });
        cell.parentElement.append(clone);
        width = Math.max(width, Math.ceil(clone.getBoundingClientRect().width));
        clone.remove();
      }
      const start = resizeStart();
      resize(index, width - start[index], start);
      save();
    };

    headerCells.forEach((header, index) => {
      if ((!independent && index >= widths.length - 1) || lockedColumns.has(index)) return;
      const nextHeader = independent ? null : headerCells[index + 1];
      const handle = document.createElement("span");
      handle.className = "column-resize-handle";
      handle.tabIndex = 0;
      handle.title = independent
        ? "Drag or use arrow keys to resize. Double-click or press Enter to fit visible content. Home resets all columns."
        : "Drag to resize. Double-click or press Home to reset all columns.";
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

      handle.addEventListener("dblclick", (event) => { event.preventDefault(); event.stopPropagation(); independent ? fitContent(index) : reset(); });
      handle.addEventListener("click", (event) => { event.preventDefault(); event.stopPropagation(); });
      handle.addEventListener("keydown", (event) => {
        if (independent && event.key === "Enter") {
          event.preventDefault(); event.stopPropagation(); fitContent(index);
          return;
        }
        if (event.key === "Home") {
          event.preventDefault(); event.stopPropagation(); reset();
          return;
        }
        if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
        event.preventDefault(); event.stopPropagation();
        resize(index, event.key === "ArrowRight" ? 8 : -8, resizeStart());
        save();
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
          save();
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
