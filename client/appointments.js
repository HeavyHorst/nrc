// Durable calendar appointments. The server indexes the JSON preview; payload is intentionally empty.
window.NRCAppointments = (() => {
  let selected = null;
  let dirty = false;
  let saving = false;
  let generation = 0;
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
      if (data.version !== 1 || !String(data.title || "").trim() || startAt <= 0n || (endAt && endAt <= startAt)) return null;
      return { asset, version: 1, title: String(data.title).trim(), startAt, endAt,
        description: String(data.description || ""), assignee: String(data.assignee || ""),
        project: String(data.project || ""), url: String(data.url || "") };
    } catch { return null; }
  }
  function validate(values) {
    if (!values.title.trim()) return "TITLE IS REQUIRED";
    if (values.startAt <= 0n || values.startAt > 9223372036854775807n) return "START TIME IS INVALID";
    if (values.endAt > 9223372036854775807n) return "END TIME IS INVALID";
    if (values.endAt && values.endAt <= values.startAt) return "END MUST BE AFTER START";
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
    return JSON.stringify({ version: 1, title: values.title.trim(), start_at: values.startAt.toString(),
      end_at: values.endAt ? values.endAt.toString() : "", description: values.description,
      assignee: values.assignee.trim(), project: values.project.trim(), url: values.url.trim() });
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
    return {
      title: document.getElementById("appointmentTitle")?.value || "",
      startAt: selected && start === localValue(selected.startAt) ? selected.startAt : localNanos(start),
      endAt: selected && end === localValue(selected.endAt) ? selected.endAt : localNanos(end),
      description: document.getElementById("appointmentDescription")?.value || "",
      assignee: metadata.assignee,
      project: metadata.project,
      url: document.getElementById("appointmentUrl")?.value || "",
    };
  }
  function setError(message) {
    const target = document.getElementById("appointmentValidationError");
    if (target) { target.textContent = message; target.hidden = !message; }
  }
  function setSaving(value) {
    saving = value;
    document.querySelectorAll(".appointment-detail-panel input, .appointment-detail-panel textarea, .appointment-detail-panel button, #appointmentSave, #appointmentSaveHeader, #appointmentCancel, #appointmentDelete")
      .forEach(control => { control.disabled = value; });
  }
  function save() {
    if (saving) return false;
    if (typeof serverReady === "undefined" || !serverReady) { setError("OFFLINE · RECONNECT BEFORE SAVING"); return false; }
    const values = readForm(), error = validate(values);
    setError(error); if (error) return false;
    setSaving(true);
    const token = generation;
    const preview = serialize(values), assets = window.NRCAssets;
    const options = { onSuccess: result => {
      if (token !== generation) return;
      setSaving(false);
      dirty = false; selected = parse(result.asset); window.NRCCalendar?.refreshSoon?.();
      if (selected) window.NRCInspector.openEntity({ roomId: 0n, type: "appointment", id: selected.asset.assetId }, { replaceCurrent: true });
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
    if (!(await window.NRCDialog.confirm(`Delete appointment #${id} “${selected.title}”?`,
      { title: "DELETE APPOINTMENT", confirmLabel: "Delete Appointment" }))) return;
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
    const panel = document.querySelector(".agenda-panel"), header = panel?.querySelector(".panel-header");
    const content = panel?.querySelector(".agenda-content");
    if (!panel || !header || !content) return;
    const fresh = !appointment.asset;
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    let meeting = "";
    try { const url = new URL(appointment.url); if (["http:", "https:"].includes(url.protocol)) meeting = url.href; } catch {}
    metadata = { assignee: appointment.assignee, project: appointment.project };
    const token = generation;
    const field = name => window.NRCDetailUI.inlineField({ key: `appointment-${name}`, name: name.toUpperCase(), label: name.toUpperCase(),
      value: metadata[name], display: metadata[name] || "—", suggestions: () => choices(name, metadata[name]),
      save: value => {
        if (token !== generation || saving) throw new Error("APPOINTMENT CHANGED OR IS SAVING · CLOSE AND REOPEN THIS FIELD");
        metadata[name] = String(value).trim(); dirty = true;
      } });
    header.innerHTML = `<div class="inspector-identity-row"><span class="header-text">APPOINTMENT${fresh ? " / NEW" : ` #${appointment.asset.assetId}`}</span><span class="inspector-cell-label">STATE</span><span class="status-value-mono inspector-state-value">${fresh ? "DRAFT" : "DURABLE"}</span></div><div class="inspector-mode-row"><button class="btn btn--primary header-operation inspector-matrix-control" id="appointmentSaveHeader" type="button">SAVE</button>${window.NRCDetailUI.renderCloseControl("appointmentClose")}</div>`;
    content.innerHTML = `<div class="task-detail-panel task-detail-panel-editable reminder-detail-panel detail-edit-form appointment-detail-panel">
      <label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">TITLE</span><input id="appointmentTitle" class="task-detail-input" maxlength="256" value="${escape(appointment.title)}"></label>
      <div class="detail-edit-grid detail-edit-grid--reminder-dates"><label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">START · ${escape(zone)}</span><input id="appointmentStart" type="datetime-local" class="task-detail-input" value="${localValue(appointment.startAt)}"></label><label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">END · ${escape(zone)} / OPTIONAL</span><input id="appointmentEnd" type="datetime-local" class="task-detail-input" value="${localValue(appointment.endAt)}"></label></div>
      <label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">DESCRIPTION</span><textarea id="appointmentDescription" class="task-detail-textarea" maxlength="2048">${escape(appointment.description)}</textarea></label>
      <div class="detail-edit-grid detail-edit-grid--task-meta">${field("assignee")}${field("project")}</div>
      <label class="task-detail-row detail-edit-field"><span class="task-detail-label detail-edit-label">MEETING URL / OPTIONAL</span><input id="appointmentUrl" type="url" class="task-detail-input" value="${escape(appointment.url)}"></label>
      <div id="appointmentValidationError" class="reminder-detail-validation-error" role="alert" hidden></div></div>
      <div class="task-detail-actions"><button class="btn btn--primary task-modal-btn save" id="appointmentSave">SAVE</button>${fresh ? '<button class="btn btn--ghost task-modal-btn" id="appointmentCancel">CANCEL</button>' : ""}${meeting ? `<a class="btn task-modal-btn" href="${escape(meeting)}" target="_blank" rel="noopener noreferrer">OPEN MEETING ↗</a>` : ""}${fresh ? "" : '<button class="btn btn--danger task-modal-btn danger" id="appointmentDelete">DELETE</button>'}</div>`;
    content.oninput = () => { dirty = true; }; content.onchange = () => { dirty = true; };
    document.getElementById("appointmentSave").onclick = save;
    document.getElementById("appointmentSaveHeader").onclick = save;
    document.getElementById("appointmentClose").onclick = () => window.NRCInspector.close();
    if (fresh) document.getElementById("appointmentCancel").onclick = () => window.NRCInspector.back();
    document.getElementById("appointmentDelete")?.addEventListener("click", remove);
  }
  function showInspector(ref, stillCurrent = () => true) {
    generation += 1; saving = false;
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
  function clearSelection() { generation += 1; selected = null; dirty = false; saving = false; }
  document.addEventListener("nrc:asset-created", event => { if (event.detail.asset.assetType === 12) window.NRCCalendar?.refreshSoon?.(); });
  document.addEventListener("nrc:asset-updated", event => { if (event.detail.asset.assetType !== 12) return; window.NRCCalendar?.refreshSoon?.(); if (selected?.asset.assetId === event.detail.asset.assetId && !dirty && !saving) { selected = parse(event.detail.asset); if (selected) render(selected); } });
  document.addEventListener("nrc:asset-deleted", event => { if (event.detail.asset?.assetType !== 12) return; window.NRCCalendar?.refreshSoon?.(); window.NRCInspector?.entityDeleted?.({ roomId: 0n, type: "appointment", id: event.detail.assetId }); });
  return { parse, validate, serialize, localNanos, localValue, showInspector, create, save, confirmDiscardEdits, clearSelection };
})();
