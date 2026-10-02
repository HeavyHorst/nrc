// Variable-height windowing. Keep data order separate from the mounted DOM order.
(function () {
  // Capture before removing any DOM, including the first non-virtual page.
  function capture(host, scroller, rows, key) {
    const top = scroller.getBoundingClientRect().top;
    const header = host.previousElementSibling?.getBoundingClientRect().height || 0;
    const heights = new Map();
    let anchor = null;
    for (const row of rows) {
      const rect = row.getBoundingClientRect();
      if (rect.height <= 0) continue;
      heights.set(key(row), rect.height);
      if (!anchor && rect.bottom > top + header) anchor = { key: key(row), top: rect.top - top };
    }
    host.virtualScrollTop = scroller.scrollTop;
    host.virtualWidth = scroller.clientWidth;
    host.virtualHeights = heights;
    host.virtualAnchor = anchor;
  }

  function create({ host, scroller, items, render, key, dispose = () => {}, columns = 0, estimate = 32 }) {
    const savedScroll = host.virtualScrollTop ?? scroller.scrollTop;
    delete host.virtualScrollTop;
    const rows = new Map();
    const table = columns ? host.closest("table") : null;
    const precedingRows = columns ? 1 + host.children.length : 0;
    table?.setAttribute("aria-rowcount", items.length + precedingRows);
    const previousHeights = host.virtualWidth === scroller.clientWidth ? host.virtualHeights : null;
    const heights = items.map((item) => previousHeights?.get(key(item)) || estimate);
    const savedAnchor = host.virtualAnchor;
    delete host.virtualHeights;
    delete host.virtualAnchor;
    let offsets = [], frame = 0, pinned = null, destroyed = false;
    let dragFrame = 0, dragSpeed = 0;
    const leadingHeight = [...host.children].reduce((sum, row) => sum + row.getBoundingClientRect().height, 0);
    const end = document.createComment("virtual-list-end");
    host.appendChild(end);
    let spacers = [];
    const offset = () => host.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop + leadingHeight;
    function rebuild() {
      offsets = [0];
      for (const height of heights) offsets.push(offsets[offsets.length - 1] + height);
    }
    function indexAt(y) {
      let lo = 0, hi = items.length;
      while (lo < hi) {
        const mid = (lo + hi) >>> 1;
        if (offsets[mid + 1] <= y) lo = mid + 1;
        else hi = mid;
      }
      return Math.min(lo, items.length - 1);
    }
    function schedule() {
      if (!frame && !destroyed) frame = requestAnimationFrame(() => { frame = 0; update(); });
    }
    function measure() {
      if (!scroller.clientHeight) return false;
      const header = host.previousElementSibling?.getBoundingClientRect().height || 0;
      const top = scroller.scrollTop + header - offset();
      const anchor = indexAt(top);
      let correction = 0, changed = false;
      for (const [index, row] of rows) {
        const height = row.getBoundingClientRect().height;
        if (height > 0 && Math.abs(height - heights[index]) > 0.25) {
          if (index < anchor) correction += height - heights[index];
          heights[index] = height;
          changed = true;
        }
      }
      if (changed) {
        rebuild();
        update();
        scroller.scrollTop += correction;
      }
      return changed;
    }
    const observer = new ResizeObserver(() => {
      if (!scroller.clientHeight) return;
      measure();
      schedule();
    });
    function spacer(height, before) {
      if (height <= 0) return;
      const node = document.createElement(columns ? "tr" : "div");
      node.setAttribute("aria-hidden", "true");
      node.style.cssText = "padding:0;border:0;flex-shrink:0;pointer-events:none";
      const cell = columns ? node.appendChild(document.createElement("td")) : node;
      if (columns) cell.colSpan = columns;
      cell.style.cssText = `height:${height}px;padding:0;border:0;box-sizing:border-box`;
      host.insertBefore(node, before);
      spacers.push(node);
    }
    function update() {
      if (destroyed || !items.length) return;
      const top = Math.max(0, scroller.scrollTop - offset());
      const start = indexAt(Math.max(0, top - 300));
      const stop = Math.min(items.length, indexAt(top + (scroller.clientHeight || 600) + 300) + 1);
      const wanted = new Set();
      for (let i = start; i < stop; i++) wanted.add(i);
      if (pinned !== null) wanted.add(pinned);
      for (const [index, row] of rows) {
        if (row.contains(document.activeElement)) wanted.add(index);
      }
      for (const node of spacers) node.remove();
      spacers = [];
      for (const [index, row] of rows) {
        if (!wanted.has(index)) {
          observer.unobserve(row);
          dispose(row);
          row.remove();
          rows.delete(index);
        }
      }
      let previous = 0;
      for (const index of [...wanted].sort((a, b) => a - b)) {
        let row = rows.get(index);
        if (!row) {
          row = render(items[index]);
          row.dataset.virtualIndex = index;
          if (columns) {
            row.setAttribute("aria-rowindex", index + precedingRows + 1);
          }
          rows.set(index, row);
          // Insert only new rows: moving a native drag source cancels the drag.
          const next = [...rows.keys()].filter((i) => i > index).sort((a, b) => a - b)[0];
          host.insertBefore(row, rows.get(next) || end);
          observer.observe(row);
        }
        spacer(offsets[index] - offsets[previous], row);
        previous = index + 1;
      }
      spacer(offsets[items.length] - offsets[previous], end);
    }
    const oldAnchor = scroller.style.overflowAnchor;
    function dragScroll() {
      scroller.scrollTop += dragSpeed;
      dragFrame = requestAnimationFrame(dragScroll);
    }
    function dragOver(event) {
      if (pinned === null) return;
      event.preventDefault();
      const rect = scroller.getBoundingClientRect();
      dragSpeed = event.clientY < rect.top + 48 ? -12 : event.clientY > rect.bottom - 48 ? 12 : 0;
      if (!dragFrame) dragFrame = requestAnimationFrame(dragScroll);
    }
    function stopDrag() {
      cancelAnimationFrame(dragFrame);
      dragFrame = 0;
      dragSpeed = 0;
    }
    scroller.addEventListener("dragover", dragOver);
    scroller.addEventListener("dragleave", stopDrag);
    document.addEventListener("dragend", stopDrag);
    document.addEventListener("drop", stopDrag);
    scroller.style.overflowAnchor = "none";
    scroller.addEventListener("scroll", schedule, { passive: true });
    observer.observe(scroller);
    rebuild();
    update();
    const anchorIndex = savedAnchor ? items.findIndex((item) => key(item) === savedAnchor.key) : -1;
    scrollTo(anchorIndex >= 0 ? offset() + offsets[anchorIndex] - savedAnchor.top : savedScroll);
    function scrollTo(top) {
      scroller.scrollTop = top;
      update();
      // The old window's unmeasured rows can temporarily shorten scrollHeight
      // and clamp a near-bottom request. Retry after mounting the target window.
      scroller.scrollTop = top;
      update();
    }
    function position(index) {
      const top = offset() + offsets[index];
      const header = host.previousElementSibling?.getBoundingClientRect().height || 0;
      if (top < scroller.scrollTop + header || heights[index] > scroller.clientHeight - header) {
        scrollTo(top - header);
      } else if (top + heights[index] > scroller.scrollTop + scroller.clientHeight) {
        scrollTo(top + heights[index] - scroller.clientHeight);
      }
      update();
    }
    function ensure(index) {
      // Complete positioning synchronously. A latent ResizeObserver target
      // would otherwise override later wheel/scrollbar or drag scrolling.
      position(index);
      for (let pass = 0; pass < 4 && measure(); pass++) position(index);
      return rows.get(index);
    }
    return {
      items,
      ensure,
      pin(row) { pinned = row ? Number(row.dataset.virtualIndex) : null; schedule(); },
      destroy() {
        capture(host, scroller, host.querySelectorAll("[data-virtual-index]"),
          (row) => key(items[Number(row.dataset.virtualIndex)]));
        host.virtualHeights = new Map(items.map((item, index) => [key(item), heights[index]]));
        destroyed = true;
        stopDrag();
        scroller.removeEventListener("dragover", dragOver);
        scroller.removeEventListener("dragleave", stopDrag);
        document.removeEventListener("dragend", stopDrag);
        document.removeEventListener("drop", stopDrag);
        cancelAnimationFrame(frame);
        observer.disconnect();
        table?.removeAttribute("aria-rowcount");
        scroller.removeEventListener("scroll", schedule);
        scroller.style.overflowAnchor = oldAnchor;
        for (const row of rows.values()) { dispose(row); row.remove(); }
        for (const node of spacers) node.remove();
        end.remove();
      },
    };
  }
  window.NRCVirtualList = { create, capture };
})();
