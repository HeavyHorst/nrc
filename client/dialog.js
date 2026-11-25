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

    const focusable = () => [...root.querySelectorAll("input, textarea, select, button, a[href], [tabindex], [contenteditable='true']")]
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

// Shared local-date selection. Results are epoch milliseconds; null cancels,
// zero explicitly clears an optional date. Calendar days retain local wall time
// across daylight-saving changes rather than adding fixed 24-hour durations.
window.NRCDateTime = {
  pick({ title = "SELECT DATE AND TIME", label = "Date and time", submitLabel = "Apply", initialValue = 0, defaultDays = 7, optional = false, futureOnly = false } = {}) {
    return new Promise(resolve => {
      const view = NRCModal.create({ title, className: "nrc-datetime-dialog", onCancel: () => resolve(null) });
      const body = document.createElement("div");
      body.className = "nrc-datetime";
      body.innerHTML = `<fieldset class="choice-field nrc-datetime-presets"><legend></legend>
        ${[[1,"1 day"],[7,"7 days"],[30,"30 days"],["custom","Custom date"]].map(([value,text]) => `<label class="radio-choice"><input type="radio" name="datePreset" value="${value}"><span>${text}</span></label>`).join("")}
        </fieldset>
        <div class="nrc-datetime-custom" hidden>
          <div class="nrc-datetime-calendar">
            <div class="nrc-datetime-month"><button type="button" class="btn" aria-label="Previous month">‹</button><strong aria-live="polite"></strong><button type="button" class="btn" aria-label="Next month">›</button></div>
            <div class="nrc-datetime-days" role="group" aria-label="Choose date"></div>
          </div>
          <label class="detail-edit-field"><span class="detail-edit-label">TIME</span><input class="nrc-dialog-input" type="time" required><span class="customer-meta"></span></label>
        </div>
        <div class="nrc-dialog-message" role="status" aria-live="polite"></div>`;
      body.querySelector("legend").textContent = label;
      view.panel.insertBefore(body, view.actions);
      const custom = body.querySelector(".nrc-datetime-custom");
      const time = body.querySelector('input[type="time"]');
      const summary = body.querySelector('[role="status"]');
      const days = body.querySelector(".nrc-datetime-days");
      const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
      body.querySelector(".customer-meta").textContent = zone;
      const pad = n => String(n).padStart(2,"0");
      const key = date => `${date.getFullYear()}-${pad(date.getMonth()+1)}-${pad(date.getDate())}`;
      const presetDate = count => {
        const date = new Date();
        date.setDate(date.getDate()+count);
        date.setSeconds(0,0);
        return date;
      };
      let selected = initialValue ? new Date(initialValue) : presetDate(defaultDays);
      let month = new Date(selected.getFullYear(),selected.getMonth(),1);
      time.value = `${pad(selected.getHours())}:${pad(selected.getMinutes())}`;
      const button = (text, action, primary = false) => {
        const el = document.createElement("button");
        el.type = "button";
        el.className = primary ? "btn btn--primary" : "btn btn--ghost";
        el.textContent = text;
        el.onclick = action;
        view.actions.append(el);
        return el;
      };
      const finish = value => { view.close(); resolve(value); };
      button("Cancel", () => finish(null));
      if (optional) button("No date", () => finish(0));
      const submit = button(submitLabel, () => {
        update();
        if (!submit.disabled) finish(selected.getTime());
      }, true);
      function update() {
        const [hours,minutes] = time.value.split(":").map(Number);
        const validTime = time.validity.valid && time.value !== "";
        const candidate = new Date(selected.getFullYear(),selected.getMonth(),selected.getDate(),hours,minutes);
        // Reject nonexistent local wall times during the spring DST gap.
        const valid = validTime && candidate.getHours() === hours && candidate.getMinutes() === minutes && (!futureOnly || candidate.getTime() > Date.now());
        submit.disabled = !valid;
        if (valid) selected = candidate;
        summary.textContent = valid
          ? new Intl.DateTimeFormat("de-DE",{dateStyle:"medium",timeStyle:"short"}).format(selected) + ` · ${zone}`
          : futureOnly && candidate.getTime() <= Date.now() ? "Choose a date and time in the future." : "Choose a valid local date and time.";
      }
      function renderMonth() {
        body.querySelector(".nrc-datetime-month strong").textContent = new Intl.DateTimeFormat(undefined,{month:"long",year:"numeric"}).format(month);
        days.replaceChildren();
        const monday = new Date(2026,0,5);
        for (let i=0;i<7;i++) {
          const day = document.createElement("span");
          day.textContent = new Intl.DateTimeFormat(undefined,{weekday:"short"}).format(monday);
          days.append(day);
          monday.setDate(monday.getDate()+1);
        }
        const offset = (month.getDay()+6)%7;
        const count = new Date(month.getFullYear(),month.getMonth()+1,0).getDate();
        for (let i=0;i<offset;i++) days.append(document.createElement("span"));
        for (let n=1;n<=count;n++) {
          const date = new Date(month.getFullYear(),month.getMonth(),n);
          const day = document.createElement("button");
          day.type = "button";
          day.className = "btn";
          day.textContent = String(n);
          day.setAttribute("aria-label",key(date));
          day.setAttribute("aria-pressed",String(key(date) === key(selected)));
          day.disabled = futureOnly && key(date) < key(new Date());
          day.onclick = () => {
            selected = new Date(date.getFullYear(),date.getMonth(),n,selected.getHours(),selected.getMinutes());
            update(); renderMonth();
            days.querySelector(`[aria-label="${key(date)}"]`)?.focus();
          };
          days.append(day);
        }
      }
      body.querySelectorAll(".nrc-datetime-month button").forEach((el,index) => {
        el.onclick = () => { month.setMonth(month.getMonth()+(index ? 1 : -1)); renderMonth(); };
      });
      body.querySelectorAll('input[type="radio"]').forEach(radio => {
        radio.checked = radio.value === (initialValue ? "custom" : String(defaultDays));
        radio.onchange = () => {
          custom.hidden = radio.value !== "custom";
          if (radio.value !== "custom") {
            selected = presetDate(Number(radio.value));
            time.value = `${pad(selected.getHours())}:${pad(selected.getMinutes())}`;
          }
          month = new Date(selected.getFullYear(),selected.getMonth(),1);
          update(); renderMonth();
        };
      });
      time.oninput = update;
      custom.hidden = !initialValue;
      update(); renderMonth(); view.show();
      body.querySelector('input:checked')?.focus();
    });
  },
};
