// Durable calendar appointments. The server indexes the JSON preview; payload is intentionally empty.
window.NRCAppointments = (() => {
  let selected = null;
  let dirty = false;
  let saving = false;
  let generation = 0;
  let editing = false;
  let reference = {};
  let participants = [];
  let joinTimer;
  const browserZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone;
  function zonedValue(value, timezone = browserZone()) {
    if (!value) return "";
    const parts = new Intl.DateTimeFormat("sv-SE", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(new Date(Number(value / 1000000n)));
    const p = Object.fromEntries(parts.map(p => [p.type, p.value]));
    return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
  }
  // Search offsets around the requested wall time. Gaps have no match; folds
  // select the earliest instant, independently of the browser's timezone.
  function zonedNanos(value, timezone) {
    if (!value) return 0n;
    const wall = Date.parse(`${value}Z`);
    if (!Number.isFinite(wall)) return 0n;
    const candidates = new Set();
    for (const hours of [-36, -12, 0, 12, 36]) {
      const probe = wall + hours * 3600000;
      const formatted = zonedValue(BigInt(probe) * 1000000n, timezone);
      const offset = Date.parse(`${formatted}Z`) - Math.floor(probe / 60000) * 60000;
      const candidate = BigInt(wall - offset) * 1000000n;
      if (zonedValue(candidate, timezone) === value) candidates.add(candidate);
    }
    return [...candidates].sort((a, b) => a < b ? -1 : 1)[0] || 0n;
  }
  const occurrenceMode = () => !!selected?.repeat && !!reference.occurrenceAt && document.getElementById("appointmentScope")?.value === "occurrence";
  let metadata = { assignee: "", project: "" };
  const escape = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const nanos = value => {
    try { return value === "" || value == null ? 0n : BigInt(value); } catch { return 0n; }
  };
  const localValue = value => {
    if (!value) return "";
    const date = new Date(Number(value / 1000000n));
    const pad = part => String(part).padStart(2, "0");
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
  };
  const localNanos = value => {
    if (!value) return 0n;
    const milliseconds = new Date(value).getTime();
    return Number.isFinite(milliseconds) ? BigInt(milliseconds) * 1000000n : 0n;
  };
  function parse(asset) {
    if (!asset || asset.assetType !== (window.NRCAssets?.AssetType?.Appointment ?? 12)) return null;
    try {
      const data = JSON.parse(asset.preview || "{}");
      const startAt = nanos(data.start_at), endAt = nanos(data.end_at);
      if (![1, 2].includes(data.version) || !String(data.title || "").trim() || startAt <= 0n || (endAt && endAt <= startAt)) return null;
      return { asset, version: data.version, timezone: data.timezone || browserZone(), repeat: data.repeat || "", weekdays: data.weekdays || [], until: data.until || "", participants: data.participants || [], conference: data.conference || (data.url ? "external" : "none"), exceptions: data.exceptions || [], title: String(data.title).trim(), startAt, endAt,
        description: String(data.description || ""), assignee: String(data.assignee || ""),
        project: String(data.project || ""), url: String(data.url || "") };
    } catch { return null; }
  }
  function validate(values) {
    if (!values.title.trim()) return "TITLE IS REQUIRED";
    if (values.startAt <= 0n || values.startAt > 9223372036854775807n) return "START TIME IS INVALID";
    if (values.endAt > 9223372036854775807n) return "END TIME IS INVALID";
    if (values.endAt && values.endAt <= values.startAt) return "END MUST BE AFTER START";
    if (values.version === 2) {
      try { new Intl.DateTimeFormat("en", { timeZone: values.timezone }).format(); } catch { return "INVALID IANA TIMEZONE"; }
      if (!["", "daily", "weekly", "monthly"].includes(values.repeat)) return "INVALID REPEAT";
      if (values.repeat && values.endAt - values.startAt > 86400000000000n) return "RECURRING DURATION MUST NOT EXCEED 24 HOURS";
      if (values.repeat === "weekly" && !values.weekdays.length) return "SELECT AT LEAST ONE WEEKDAY";
      if (values.until && (!/^\d{4}-\d{2}-\d{2}$/.test(values.until) || values.until < zonedValue(values.startAt, values.timezone).slice(0, 10))) return "UNTIL MUST BE ON OR AFTER START";
      if (values.participants.length > 64 || new Set(values.participants).size !== values.participants.length) return "PARTICIPANTS MUST BE UNIQUE · MAX 64";
      if (values.participants.some(p => !p || p.trim() !== p || /[\x00-\x1f\x7f]/.test(p) || new TextEncoder().encode(p).length > 255)) return "INVALID PARTICIPANT USERNAME";
      if (values.conference === "external" && !values.url.trim()) return "EXTERNAL CONFERENCE REQUIRES A MEETING URL";
      if (values.exceptions.length > 32) return "MAXIMUM 32 OCCURRENCE OVERRIDES";
    }
    const bytes = value => new TextEncoder().encode(value).length;
    for (const [field, limit] of [["title", 256], ["assignee", 32], ["project", 128], ["description", 2048], ["url", 2048]]) {
      if (bytes(values[field]) > limit) return `${field.toUpperCase()} EXCEEDS ${limit} BYTES`;
    }
    if (values.url) {
      try { if (!["http:", "https:"].includes(new URL(values.url).protocol)) return "MEETING URL MUST USE HTTP OR HTTPS"; } catch { return "MEETING URL IS INVALID"; }
    }
    if (bytes(serialize(values)) > 4096) return "APPOINTMENT EXCEEDS 4096 BYTES";
    return "";
  }
  function serialize(values) {
    return JSON.stringify({ ...(values.version === 2 ? { timezone: values.timezone, repeat: values.repeat, weekdays: values.weekdays, until: values.until, participants: values.participants, conference: values.conference, exceptions: values.exceptions } : {}), version: values.version === 2 ? 2 : 1, title: values.title.trim(), start_at: values.startAt.toString(),
      end_at: values.endAt ? values.endAt.toString() : "", description: values.description,
      assignee: values.assignee.trim(), project: values.project.trim(), url: values.url.trim() });
  }
  function effectiveOccurrence(appointment, at) {
    const original = appointment.repeat ? nanos(at) || appointment.startAt : appointment.startAt;
    const exception = appointment.repeat ? appointment.exceptions?.find(e => nanos(e.at) === original) : undefined;
    const startAt = exception?.start_at !== undefined ? nanos(exception.start_at) : original;
    const endAt = exception?.end_at !== undefined ? nanos(exception.end_at) : appointment.endAt ? startAt + appointment.endAt - appointment.startAt : 0n;
    return { original, exception, startAt, endAt };
  }
  function choices(field, current) {
    const rows = window.NRCCalendar?.getState?.().rows || [];
    const values = rows.map(row => row[field]).filter(Boolean);
    values.push(...(window.NRCTasks?.getFieldChoices?.(field, 0n) || []));
    if (field === "assignee" && typeof myNickname !== "undefined") values.push(myNickname);
    if (current) values.push(current);
    if (field === "assignee" && typeof userDirectory === "function") values.push(...userDirectory());
    return [...new Set(values)].sort();
  }
  function readForm() {
    const start = document.getElementById("appointmentStart")?.value || "";
    const end = document.getElementById("appointmentEnd")?.value || "";
    const timezone = document.getElementById("appointmentTimezone")?.value || browserZone();
    const current = selected && occurrenceMode() ? effectiveOccurrence(selected, reference.occurrenceAt) : selected;
    const startAt = current && start === zonedValue(current.startAt, timezone) ? current.startAt : zonedNanos(start, timezone);
    const endAt = current && end === zonedValue(current.endAt, timezone) ? current.endAt : zonedNanos(end, timezone);
    if (end && endAt === 0n) throw new Error("END TIME IS INVALID OR DOES NOT EXIST IN THIS TIMEZONE");
    const values = {
      version: 2, timezone, repeat: document.getElementById("appointmentRepeat")?.value || "",
      weekdays: Array.from(document.querySelectorAll("[data-appointment-weekday]:checked"), el => Number(el.value)),
      until: document.getElementById("appointmentUntil")?.value || "", participants: [...participants],
      conference: document.getElementById("appointmentConference")?.value || "none", exceptions: document.getElementById("appointmentResetExceptions")?.checked ? [] : selected?.exceptions || [],
      title: document.getElementById("appointmentTitle")?.value || "",
      startAt, endAt,
      description: document.getElementById("appointmentDescription")?.value || "",
      assignee: metadata.assignee,
      project: metadata.project,
      url: document.getElementById("appointmentUrl")?.value || "",
    };
    if (values.repeat !== "weekly") values.weekdays = [];
    if (!values.repeat) values.until = "";
    if (occurrenceMode()) {
      const error = validate({ ...values, until: "" }); // A moved occurrence may lie beyond the series' last original date.
      if (error) throw new Error(error);
      const { original, exception: previous } = current;
      const override = { at: original.toString(), cancelled: !!document.getElementById("appointmentCancelled")?.checked };
      if (values.startAt !== original) override.start_at = values.startAt.toString();
      const inheritedEnd = selected.endAt ? values.startAt + selected.endAt - selected.startAt : 0n;
      if (previous?.end_at !== undefined || values.endAt !== inheritedEnd) override.end_at = values.endAt ? values.endAt.toString() : "";
      if (previous?.participants !== undefined || JSON.stringify(values.participants) !== JSON.stringify(selected.participants)) override.participants = values.participants;
      if (override.cancelled) { delete override.start_at; delete override.end_at; delete override.participants; }
      return { ...selected, version: 2, exceptions: [...selected.exceptions.filter(e => nanos(e.at) !== original), override] };
    }
    return values;
  }
  function setError(message) {
    const target = document.getElementById("appointmentValidationError");
    if (target) { target.textContent = message; target.hidden = !message; }
    if (message) window.NRCDetailUI.setSaveState("ERROR", document.querySelector(".agenda-panel"));
  }
  function setSaving(value) {
    saving = value;
    window.NRCDetailUI.setSaveState(value ? "SAVING" : dirty ? "UNSAVED" : "EDITING", document.querySelector(".agenda-panel"));
    document.querySelectorAll(".appointment-detail-panel input, .appointment-detail-panel select, .appointment-detail-panel textarea, .appointment-detail-panel button, #appointmentSave, #appointmentCancel, #appointmentDelete, #appointmentEdit")
      .forEach(control => {
        if (value) { control.dataset.appointmentWasDisabled = String(control.disabled); control.disabled = true; }
        else if (control.dataset.appointmentWasDisabled !== undefined) { control.disabled = control.dataset.appointmentWasDisabled === "true"; delete control.dataset.appointmentWasDisabled; }
      });
  }
  function save() {
    if (saving || !editing) return false;
    if (selected?.asset && selected.asset.owner !== (typeof myNickname === "undefined" ? "" : myNickname)) { setError("ONLY THE ORGANIZER CAN EDIT THIS APPOINTMENT"); return false; }
    if (typeof serverReady === "undefined" || !serverReady) { setError("OFFLINE · RECONNECT BEFORE SAVING"); return false; }
    let values;
    try { values = readForm(); } catch (error) { setError(error.message || "INVALID APPOINTMENT TIME"); return false; }
    const error = validate(values);
    setError(error); if (error) return false;
    if (!occurrenceMode() && values.exceptions.length && selected &&
        (["startAt", "repeat", "timezone", "until"].some(field => selected[field] !== values[field]) || JSON.stringify(selected.weekdays) !== JSON.stringify(values.weekdays))) {
      setError("RESET OCCURRENCE EXCEPTIONS BEFORE CHANGING THE SERIES RULE"); return false;
    }
    const resetOccurrence = !occurrenceMode() && selected && ["startAt", "endAt", "repeat", "timezone"].some(field => selected[field] !== values[field]);
    setSaving(true);
    const token = generation;
    const preview = serialize(values), assets = window.NRCAssets;
    const options = { onSuccess: result => {
      if (token !== generation) return;
      setSaving(false);
      dirty = false; selected = parse(result.asset); window.NRCCalendar?.refreshSoon?.();
      if (resetOccurrence) reference = { ...reference, occurrenceAt: undefined, actualStartAt: undefined, endAt: undefined };
      if (selected) window.NRCInspector.openEntity({ ...reference, roomId: 0n, type: "appointment", id: selected.asset.assetId, subview: "read" }, { replaceCurrent: true });
    }, onError: result => {
      if (token !== generation) return;
      setSaving(false);
      setError(result?.message || "APPOINTMENT SAVE FAILED");
    } };
    const sent = selected?.asset
      ? assets.sendUpdateAsset(0n, selected.asset.assetId, preview, "", assets.AssetType.Appointment, 0, options)
      : assets.sendCreateAsset(0n, assets.AssetType.Appointment, assets.ParentType.None, 0n, preview, "", 0, options);
    if (!sent) options.onError({ message: "APPOINTMENT SAVE NOT SENT · CHECK CONNECTION AND RETRY" });
    return Boolean(sent);
  }
  async function remove() {
    if (saving || !selected?.asset) return;
    const id = selected.asset.assetId, token = generation;
    if (!(await window.NRCDialog.confirm(`Delete ${selected.repeat ? "the entire series and all its occurrences" : "appointment"} #${id} “${selected.title}”?`,
      { title: selected.repeat ? "DELETE ENTIRE SERIES" : "DELETE APPOINTMENT", confirmLabel: selected.repeat ? "Delete Series" : "Delete Appointment" }))) return;
    if (token !== generation || saving) return;
    if (typeof serverReady === "undefined" || !serverReady) { setError("OFFLINE · RECONNECT BEFORE DELETING"); return; }
    setSaving(true);
    const options = { onSuccess: () => {
      if (token === generation) setSaving(false);
      window.NRCInspector?.entityDeleted?.({ roomId: 0n, type: "appointment", id });
      window.NRCCalendar?.refreshSoon?.();
    }, onError: result => {
      if (token !== generation) return;
      setSaving(false);
      setError(result?.message || "APPOINTMENT DELETE FAILED");
    } };
    if (!window.NRCAssets.sendDeleteAsset(0n, id, options)) options.onError({ message: "APPOINTMENT DELETE NOT SENT · CHECK CONNECTION AND RETRY" });
  }
  function render(appointment) {
    clearTimeout(joinTimer);
    const panel = document.querySelector(".agenda-panel"), header = panel?.querySelector(".panel-header");
    const content = panel?.querySelector(".agenda-content");
    if (!panel || !header || !content) return;
    const fresh = !appointment.asset;
    const zone = appointment.timezone || browserZone();
    const { exception, original, startAt: pickedStart, endAt: pickedEnd } = effectiveOccurrence(appointment, reference.occurrenceAt);
    const canEdit = fresh || appointment.asset.owner === (typeof myNickname === "undefined" ? "" : myNickname);
    let meeting = "";
    try { const url = new URL(appointment.url); if (appointment.conference === "external" && ["http:", "https:"].includes(url.protocol)) meeting = url.href; } catch {}
    if (!editing) {
      const start = new Date(Number(pickedStart / 1000000n));
      const end = pickedEnd ? new Date(Number(pickedEnd / 1000000n)) : null;
      const time = date => date.toLocaleTimeString("de-DE", { timeZone: zone, hour: "2-digit", minute: "2-digit" });
      const endText = end ? `${zonedValue(pickedStart, zone).slice(0, 10) === zonedValue(pickedEnd, zone).slice(0, 10) ? "" : end.toLocaleDateString("de-DE", { timeZone: zone, dateStyle: "medium" }) + " · "}${time(end)}` : "";
      header.innerHTML = `<div class="inspector-identity-row"><span class="header-text">APPOINTMENT #${appointment.asset.assetId}</span><span class="inspector-cell-label">STATE</span><span class="status-value-mono inspector-state-value">READ</span></div><div class="inspector-mode-row">${window.NRCDetailUI.renderHeaderAction({ id: "appointmentEdit", label: "EDIT", command: "e", title: "Edit appointment (E)" })}${window.NRCDetailUI.renderCloseControl("appointmentClose")}</div>`;
      content.innerHTML = `<article class="schedule-detail appointment-detail-panel">
        <h2>${escape(appointment.title)}</h2>
        <section class="schedule-time" aria-label="Appointment time"><p class="schedule-date">${escape(start.toLocaleDateString("de-DE", { dateStyle: "full" }))}</p><p class="schedule-hours">${escape(time(start))}${endText ? ` – ${escape(endText)}` : ""}</p><p class="schedule-zone">${escape(zone)}</p></section>
        ${meeting ? `<a class="btn btn--primary schedule-primary" href="${escape(meeting)}" target="_blank" rel="noopener noreferrer">OPEN MEETING ↗</a>` : ""}
        ${appointment.description ? `<p class="schedule-description">${escape(appointment.description)}</p>` : ""}
        ${window.NRCDetailUI.renderMetadataLedger([{ label: "ASSIGNEE", value: appointment.assignee }, { label: "PROJECT", value: appointment.project }])}
        <div id="appointmentValidationError" class="reminder-detail-validation-error" role="alert" hidden></div>
        </article><div class="task-detail-actions"><button class="btn btn--danger task-modal-btn danger" id="appointmentDelete">DELETE</button></div>`;
      content.oninput = null; content.onchange = null;
      content.querySelector(".schedule-date").textContent = start.toLocaleDateString("de-DE", { timeZone: zone, dateStyle: "full" });
      const facts = document.createElement("p");
      facts.className = "schedule-description";
      facts.textContent = `${(appointment.repeat || "SINGLE").toUpperCase()}${appointment.repeat === "weekly" ? ` · ${appointment.weekdays.map(day => ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"][day - 1]).join(", ")}` : ""}${appointment.until ? ` · UNTIL ${appointment.until}` : ""} · ORGANIZER ${appointment.asset.owner || "—"} · PARTICIPANTS ${(exception?.participants || appointment.participants || []).join(", ") || "—"}${exception?.cancelled ? " · CANCELLED" : ""}`;
      content.querySelector("article").append(facts);
      if (appointment.conference === "nrc" && !exception?.cancelled) {
        const prepare = document.createElement("button");
        prepare.className = "btn btn--primary schedule-primary";
        prepare.textContent = window.NRCCalls?.available?.() ? "PREPARE CONFERENCE" : "CONFERENCE UNAVAILABLE";
        prepare.disabled = !window.NRCCalls?.available?.();
        const hint = document.createElement("p"); hint.className = "schedule-zone";
        hint.textContent = "Opens in a new tab · available 15 minutes before start until 15 minutes after end (one hour if no end).";
        const token = generation;
        prepare.onclick = async () => {
          prepare.disabled = true; setError("");
          try {
            const ticket = await window.NRCCalls.joinAppointment(appointment.asset.assetId, original);
            if (token !== generation) return;
            const url = new URL(ticket.url);
            if (url.protocol !== "https:" || url.username || url.password || !Number.isFinite(ticket.expires_at) || ticket.expires_at * 1000 <= Date.now()) throw new Error("Invalid or expired conference link");
            const link = document.createElement("a"); link.className = prepare.className;
            link.href = url.href; link.target = "_blank"; link.rel = "noopener noreferrer";
            link.textContent = "JOIN CONFERENCE ↗";
            hint.textContent = `Personal link · valid until ${new Date(ticket.expires_at * 1000).toLocaleTimeString([], {hour:"2-digit", minute:"2-digit"})} · opens in a new tab`;
            prepare.replaceWith(link);
            joinTimer = setTimeout(() => {
              if (token !== generation) return;
              link.removeAttribute("href"); link.replaceWith(prepare);
              prepare.disabled = !window.NRCCalls?.available?.();
              hint.textContent = "Personal link expired · prepare a new link to recheck access.";
            }, Math.min(2147483647, ticket.expires_at * 1000 - Date.now()));
          } catch (error) { if (token === generation) { setError(error.message || "CONFERENCE PREPARATION FAILED"); prepare.disabled = false; } }
        };
        content.querySelector("article").append(prepare);
        content.querySelector("article").append(hint);
      }
      document.getElementById("appointmentEdit").onclick = () => window.NRCInspector.openEntity({ ...window.NRCInspector.current(), subview: "edit" });
      document.getElementById("appointmentEdit").hidden = !canEdit;
      document.getElementById("appointmentClose").onclick = () => window.NRCInspector.close();
      document.getElementById("appointmentDelete").onclick = remove;
      document.getElementById("appointmentDelete").hidden = !canEdit;
      document.getElementById("appointmentDelete").textContent = appointment.repeat ? "DELETE SERIES" : "DELETE";
      return;
    }
    metadata = { assignee: appointment.assignee, project: appointment.project };
    const token = generation;
    const field = name => window.NRCDetailUI.inlineField({ key: `appointment-${name}`, name: name.toUpperCase(), label: name.toUpperCase(),
      value: metadata[name], display: metadata[name] || "—", suggestions: () => choices(name, metadata[name]),
      save: value => {
        if (token !== generation || saving) throw new Error("APPOINTMENT CHANGED OR IS SAVING · CLOSE AND REOPEN THIS FIELD");
        metadata[name] = String(value).trim(); dirty = true;
        window.NRCDetailUI.setSaveState("UNSAVED", panel);
      } });
    header.innerHTML = `<div class="inspector-identity-row"><span class="header-text">APPOINTMENT${fresh ? " / NEW" : ` #${appointment.asset.assetId}`}</span><span class="inspector-cell-label">STATE</span>${window.NRCDetailUI.renderSaveState("EDITING")}</div><div class="inspector-mode-row">${window.NRCDetailUI.renderHeaderAction({ id: "appointmentSave", label: "SAVE", command: "s", title: "Save appointment (S)", className: "btn--primary" })}${window.NRCDetailUI.renderHeaderAction({ id: "appointmentCancel", label: "CANCEL", command: "v", title: "Cancel editing (V)" })}${window.NRCDetailUI.renderCloseControl("appointmentClose")}</div>`;
    content.innerHTML = `<div class="task-detail-panel task-detail-panel-editable reminder-detail-panel detail-edit-form appointment-detail-panel">
      <label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">TITLE</span><input id="appointmentTitle" class="task-detail-input" maxlength="256" value="${escape(appointment.title)}"></label>
      <fieldset class="schedule-fieldset"><legend>WHEN · ${escape(zone)}</legend><div class="detail-edit-grid detail-edit-grid--reminder-dates"><label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">START</span><input id="appointmentStart" type="datetime-local" class="task-detail-input" value="${localValue(appointment.startAt)}"></label><label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">END / OPTIONAL</span><input id="appointmentEnd" type="datetime-local" class="task-detail-input" value="${localValue(appointment.endAt)}"></label></div></fieldset>
      <label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">DESCRIPTION</span><textarea id="appointmentDescription" class="task-detail-textarea" maxlength="2048">${escape(appointment.description)}</textarea></label>
      <div class="detail-edit-grid detail-edit-grid--task-meta">${field("assignee")}${field("project")}</div>
      <label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">MEETING URL / OPTIONAL</span><input id="appointmentUrl" type="url" class="task-detail-input" value="${escape(appointment.url)}"></label>
      <div id="appointmentValidationError" class="reminder-detail-validation-error" role="alert" hidden></div></div>
      ${fresh ? "" : '<div class="task-detail-actions"><button class="btn btn--danger task-modal-btn danger" id="appointmentDelete">DELETE</button></div>'}`;
    content.oninput = content.onchange = () => { dirty = true; window.NRCDetailUI.setSaveState("UNSAVED", panel); };
    const form = content.querySelector(".appointment-detail-panel");
    const select = (id, label, options, value) => `<label class="task-detail-row detail-edit-field"><span class="detail-edit-label">${label}</span><nrc-select><select id="${id}" class="task-detail-select">${options.map(([v, text]) => `<option value="${escape(v)}"${v === value ? " selected" : ""}>${escape(text)}</option>`).join("")}</select></nrc-select></label>`;
    form.insertAdjacentHTML("afterbegin", `${appointment.repeat && reference.occurrenceAt ? select("appointmentScope", "EDIT SCOPE", [["occurrence", "THIS OCCURRENCE"], ["series", "ENTIRE SERIES"]], "occurrence") : ""}
      <label class="task-detail-row detail-edit-field"><span class="detail-edit-label">IANA TIMEZONE</span><input id="appointmentTimezone" class="task-detail-input" value="${escape(zone)}"></label>
      ${select("appointmentRepeat", "REPEAT", [["", "SINGLE"], ["daily", "DAILY"], ["weekly", "WEEKLY"], ["monthly", "MONTHLY · SKIP MISSING DAYS"]], appointment.repeat || "")}
      <fieldset class="schedule-fieldset"><legend>WEEKLY DAYS</legend>${["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"].map((day, i) => `<label><input type="checkbox" data-appointment-weekday value="${i + 1}"${appointment.weekdays?.includes(i + 1) ? " checked" : ""}>${day} </label>`).join("")}</fieldset>
      <label class="task-detail-row detail-edit-field"><span class="detail-edit-label">UNTIL / OPTIONAL · INCLUSIVE</span><input id="appointmentUntil" type="date" class="task-detail-input" value="${escape(appointment.until || "")}"></label>
      ${select("appointmentConference", "CONFERENCE", [["none", "NONE"], ["external", "EXTERNAL URL"], ["nrc", "NRC CONFERENCE"]], appointment.conference || "none")}
      <fieldset class="schedule-fieldset"><legend>PARTICIPANTS · ORGANIZER ${escape(appointment.asset?.owner || (typeof myNickname === "undefined" ? "" : myNickname))} IS INCLUDED</legend><div id="appointmentParticipants"></div>${select("appointmentPerson", "ADD PERSON", [["", "CHOOSE PERSON"], ...choices("assignee", "").filter(p => p !== (appointment.asset?.owner || (typeof myNickname === "undefined" ? "" : myNickname))).map(p => [p, p])], "")}<button type="button" class="btn" id="appointmentAddPerson">ADD PARTICIPANT</button></fieldset>
      ${appointment.repeat && reference.occurrenceAt ? '<label><input id="appointmentCancelled" type="checkbox"> CANCEL THIS OCCURRENCE</label>' : ""}
      ${appointment.exceptions?.length ? '<label><input id="appointmentResetExceptions" type="checkbox"> RESET ALL OCCURRENCE EXCEPTIONS ON SAVE · required when changing the series rule</label>' : ""}`);
    participants = [...(exception?.participants || appointment.participants || [])];
    function renderPeople() {
      const list = document.getElementById("appointmentParticipants");
      list.innerHTML = participants.map((p, i) => `<button type="button" class="btn" data-remove-person="${i}" aria-label="Remove ${escape(p)}">${escape(p)} ×</button>`).join("") || "NO ADDITIONAL PARTICIPANTS";
      list.onclick = e => { const button = e.target.closest("[data-remove-person]"); if (button) { participants.splice(Number(button.dataset.removePerson), 1); renderPeople(); content.onchange(); } };
    }
    renderPeople();
    document.getElementById("appointmentAddPerson").onclick = () => { const person = document.getElementById("appointmentPerson").value; if (person && !participants.includes(person) && participants.length < 64) { participants.push(person); renderPeople(); content.onchange(); } };
    function updateScope() {
      const one = occurrenceMode();
      document.getElementById("appointmentStart").value = zonedValue(one ? pickedStart : appointment.startAt, zone);
      document.getElementById("appointmentEnd").value = zonedValue(one ? pickedEnd : appointment.endAt, zone);
      for (const id of ["appointmentTitle", "appointmentDescription", "appointmentTimezone", "appointmentRepeat", "appointmentUntil", "appointmentConference", "appointmentUrl"]) {
        document.getElementById(id).disabled = one;
        document.getElementById(id).closest("label").hidden = one;
      }
      form.querySelector("[data-appointment-weekday]").closest("fieldset").hidden = one;
      form.querySelector(".detail-edit-grid--task-meta").hidden = one;
      form.querySelectorAll("[data-appointment-weekday], nrc-inline-field").forEach(el => { el.inert = one; if (el.matches("input")) el.disabled = one; });
      if (document.getElementById("appointmentCancelled")) { document.getElementById("appointmentCancelled").closest("label").hidden = !one; document.getElementById("appointmentCancelled").disabled = !one; document.getElementById("appointmentCancelled").checked = !!exception?.cancelled; }
      if (document.getElementById("appointmentResetExceptions")) { document.getElementById("appointmentResetExceptions").closest("label").hidden = one; document.getElementById("appointmentResetExceptions").disabled = one; document.getElementById("appointmentResetExceptions").checked = false; }
      participants = [...(one ? exception?.participants || appointment.participants || [] : appointment.participants || [])]; renderPeople();
    }
    document.getElementById("appointmentScope")?.addEventListener("change", updateScope);
    updateScope();
    document.getElementById("appointmentSave").disabled = !canEdit;
    document.getElementById("appointmentSave").onclick = save;
    document.getElementById("appointmentClose").onclick = () => window.NRCInspector.close();
    document.getElementById("appointmentCancel").onclick = () => fresh ? window.NRCInspector.back() : window.NRCInspector.openEntity({ ...window.NRCInspector.current(), subview: "read" });
    document.getElementById("appointmentDelete")?.addEventListener("click", remove);
    if (document.getElementById("appointmentDelete")) document.getElementById("appointmentDelete").textContent = appointment.repeat ? "DELETE SERIES" : "DELETE";
  }
  function showInspector(ref, stillCurrent = () => true) {
    reference = { ...ref };
    generation += 1; saving = false;
    editing = BigInt(ref.id) === 0n || ref.subview === "edit";
    if (BigInt(ref.id) === 0n) { selected = null; dirty = false; render({ title: "", startAt: 0n, endAt: 0n, description: "", assignee: typeof myNickname === "undefined" ? "" : myNickname, project: "", url: "" }); return; }
    const cached = window.NRCAssets.roomAssets.get(0n)?.get(BigInt(ref.id));
    const show = asset => { if (!stillCurrent()) return; selected = parse(asset); if (selected) { dirty = false; render(selected); } };
    if (cached?.payload != null) show(cached);
    else {
      const content = document.querySelector(".agenda-content");
      if (content) content.textContent = "LOADING APPOINTMENT…";
      window.NRCAssets.requestAsset(0n, BigInt(ref.id), { onSuccess: result => show(result.asset), onError: () => {
        if (stillCurrent() && content) content.textContent = "APPOINTMENT COULD NOT BE LOADED";
      } });
    }
  }
  function create() { window.NRCInspector?.openEntity?.({ roomId: 0n, type: "appointment", id: 0n }); }
  async function confirmDiscardEdits() {
    if (saving) return false;
    return !dirty || await window.NRCDialog.confirm("Discard unsaved appointment changes?", { title: "UNSAVED APPOINTMENT", confirmLabel: "Discard" });
  }
  function clearSelection() { generation += 1; clearTimeout(joinTimer); selected = null; dirty = false; saving = false; }
  document.addEventListener("nrc:asset-created", event => { if (event.detail.asset.assetType === 12) window.NRCCalendar?.refreshSoon?.(); });
  document.addEventListener("nrc:asset-updated", event => { if (event.detail.asset.assetType !== 12) return; window.NRCCalendar?.refreshSoon?.(); if (selected?.asset.assetId === event.detail.asset.assetId && !dirty && !saving) { generation++; selected = parse(event.detail.asset); if (selected) render(selected); } });
  document.addEventListener("nrc:calls-access", () => { if (selected && !editing && selected.conference === "nrc") { generation++; render(selected); } });
  document.addEventListener("nrc:asset-deleted", event => { if (event.detail.asset?.assetType !== 12) return; window.NRCCalendar?.refreshSoon?.(); window.NRCInspector?.entityDeleted?.({ roomId: 0n, type: "appointment", id: event.detail.assetId }); });
  return { parse, validate, serialize, localNanos, localValue, zonedValue, zonedNanos, showInspector, create, save, confirmDiscardEdits, clearSelection };
})();
