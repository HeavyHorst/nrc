// GPT-Live owns audio only. The server owns plans; only a human button handler
// submits selected IDs. No model/data-channel event can call Apply.
(() => {
  let active = null;
  const actionNames = {
    create_task: "Aufgabe anlegen", update_task: "Aufgabe ändern",
    create_note: "Notiz anlegen", update_note: "Notiz ändern", delete_note: "Notiz löschen",
    create_edge: "Verknüpfung anlegen", delete_edge: "Verknüpfung löschen",
  };
  const fieldNames = {
    id: "Aktions-ID", type: "Typ", status: "Status", title: "Titel",
    description: "Beschreibung", content: "Inhalt", format: "Format",
    project: "Projekt", tags: "Schlagwörter", priority: "Priorität",
    task_id: "Aufgaben-ID", task_status: "Aufgabenstatus", blocked_by: "Blockiert durch Aufgabe",
    asset_id: "Datensatz-ID", edge_id: "Verknüpfungs-ID",
    source_type: "Quelltyp", source_id: "Quell-ID", source_action_id: "Quellaktion",
    target_type: "Zieltyp", target_id: "Ziel-ID", target_action_id: "Zielaktion", relation: "Beziehung",
    expected_updated_at: "Erwartete Datensatzversion", applied_at: "Ausgeführt am", error: "Fehlerdetail",
    created_task_id: "Angelegte Aufgaben-ID", created_asset_id: "Angelegte Datensatz-ID",
    created_edge_id: "Angelegte Verknüpfungs-ID", ticket: "Ticket", ticket_result_id: "Ticket-Ergebnis-ID",
  };
  const valueNames = {
    task: "Aufgabe", note: "Notiz", asset: "Datensatz", markdown: "Markdown", html: "HTML",
    pending: "Ausstehend", applied: "Ausgeführt", failed: "Fehlgeschlagen",
    todo: "Offen", in_progress: "In Arbeit", done: "Erledigt", blocked: "Blockiert",
    Backlog: "Backlog", Todo: "Offen", InProgress: "In Arbeit", Done: "Erledigt", Note: "Notiz",
    "related-to": "Gehört zusammen", "depends-on": "Abhängig von", "member-of": "Mitglied von",
    references: "Verweist auf", blocks: "Blockiert", "derived-from": "Abgeleitet von", supersedes: "Ersetzt",
  };
  function actionName(action) {
    return actionNames[action.type] || action.type || "Aktion";
  }
  function renderFields(values, collapseLongText = false, proposals = []) {
    const fields = document.createElement("div");
    for (const [key, value] of Object.entries(values)) {
      const row = document.createElement("div"); row.className = "ai-action-desc";
      row.classList.add("voice-field");
      row.classList.toggle("voice-field--text", ["content", "description"].includes(key));
      const label = document.createElement("strong"); label.textContent = `${fieldNames[key] || key}: `;
      const fieldValue = document.createElement("div");
      row.append(label, fieldValue);
      if (collapseLongText && ["content", "description"].includes(key) && typeof value === "string" && (value.length > 320 || value.split("\n").length > 4)) {
        const preview = document.createElement("span");
        preview.textContent = value.split("\n").slice(0, 4).join("\n").slice(0, 320) + " …";
        const details = document.createElement("details");
        const summary = document.createElement("summary");
        summary.textContent = "Vollständigen Inhalt anzeigen";
        const full = document.createElement("div"); full.textContent = value;
        details.append(summary, full);
        details.addEventListener("toggle", () => {
          preview.hidden = details.open;
          summary.textContent = details.open ? "Inhalt einklappen" : "Vollständigen Inhalt anzeigen";
        });
        fieldValue.append(preview, details);
      } else if (value !== null && typeof value === "object") {
        if (Array.isArray(value) && !value.length) fieldValue.append("Keine Einträge");
        else fieldValue.append(renderFields(Array.isArray(value) ? Object.fromEntries(value.map((item, i) => [i + 1, item])) : value, collapseLongText, proposals));
      } else {
        const referenced = ["source_action_id", "target_action_id"].includes(key) ? proposals.findIndex(action => action.id === value) : -1;
        const translated = ["type", "status", "task_status", "source_type", "target_type", "relation", "format"].includes(key);
        fieldValue.append(referenced >= 0 ? `Vorschlag ${referenced + 1} · ${actionName(proposals[referenced])}` : value === null ? "Nicht gesetzt" : value === "" ? "Leer" : typeof value === "boolean" ? value ? "Ja" : "Nein" : translated ? valueNames[value] || String(value) : String(value));
      }
      fields.append(row);
    }
    return fields;
  }
  const button = (text, action, variant = "") => {
    const el = document.createElement("button");
    el.type = "button";
    el.className = `btn ${variant}`;
    el.textContent = text;
    el.onclick = action;
    return el;
  };

  async function open() {
    if (active) { active.expand(); return; }
    if (window.NRCMemory?.isBusy()) return;
    const workspace = currentWorkspaceId;
    if (window.NRCMemory?.prepare && !await NRCMemory.prepare(workspace)) return;
    if (workspace !== currentWorkspaceId || active || window.NRCMemory?.isBusy()) return;
    const memoryOptions = window.NRCMemory?.options(workspace) || { execution_policy: "temporary" };
    const memoryLabel = memoryOptions.require_memory ? "" : " · TEMPORÄR";
    const panel = document.createElement("section");
    panel.className = "voice-panel";
    panel.setAttribute("aria-label", "Sullivan-Sprachgespräch");
    const header = document.createElement("header");
    header.className = "panel-header";
    const headerRow = document.createElement("div");
    const toggle = button("MINIMIEREN", () => setCollapsed(!collapsed, false), "btn--ghost");
    toggle.setAttribute("aria-controls", "sullivanVoiceContent");
    const compactName = document.createElement("strong");
    compactName.textContent = "SULLIVAN";
    const compactTime = document.createElement("span");
    compactTime.className = "voice-compact-time";
    const compactNotice = document.createElement("span");
    compactNotice.className = "voice-compact-notice";
    const compactArrow = document.createElement("span");
    compactArrow.className = "voice-compact-arrow";
    compactArrow.setAttribute("aria-hidden", "true");
    headerRow.append(toggle); header.append(headerRow);
    const body = document.createElement("div");
    body.className = "voice-content";
    body.id = "sullivanVoiceContent";
    body.innerHTML = `
      <audio controls hidden aria-label="Sullivan-Sprachausgabe"></audio>
      <div data-voice-answer></div>
      <div data-voice-plan></div>
      <div data-voice-result role="status"></div>`;
    const status = document.createElement("p");
    status.className = "nrc-dialog-message";
    status.setAttribute("data-voice-status", "");
    status.setAttribute("role", "status");
    status.textContent = "Bereit. Mikrofon startet erst nach Klick.";
    const usage = document.createElement("p");
    usage.className = "nrc-dialog-message";
    usage.setAttribute("data-voice-usage", "");
    usage.textContent = `${workspace}${memoryLabel}`;
    const actions = document.createElement("div");
    actions.className = "voice-actions";
    panel.append(header, actions);
    const dock = document.createElement("div");
    dock.className = "voice-dock";
    const narrow = matchMedia("(max-width: 768px)");
    function placeDock() {
      const focused = document.body.matches(".note-share-focused, .sullivan-share-focused");
      const host = document.querySelector(narrow.matches || focused ? ".status-footer" : ".app-sidebar");
      if (dock.parentElement !== host) host.append(dock);
    }
    placeDock();
    narrow.addEventListener("change", placeDock);
    const layoutObserver = new MutationObserver(placeDock);
    layoutObserver.observe(document.body, { attributes: true, attributeFilter: ["class"] });
    const audio = body.querySelector("audio");
    audio.autoplay = true;
    let id = "", peer, events, microphone, pollTimer, clockTimer, closeTimer;
    let started = 0, ended = false, ready = false, applying = false, closeOnly = false;
    let reconciling = false, reconcileDeadline = 0, approvalRevision = -1, completedApprovalRevision = -1;
    let revision = -1, planKey = "", lastApply = "", localSpeech = false;
    let approvedActions = [];
    let forgotten = false;
    let collapsed = false, hasProposal = false, dismissed = false;
    let elapsed = "00:00";
    let displayedError = "";
    const mute = button("MIKROFON STUMM", () => {
      const tracks = microphone?.getAudioTracks() || [];
      const enabled = !tracks[0]?.enabled;
      tracks.forEach(track => { track.enabled = enabled; });
      mute.setAttribute("aria-pressed", String(!enabled));
      updatePanel();
    });
    mute.setAttribute("aria-pressed", "false");
    mute.disabled = true;
    const stop = button("BEENDEN", () => {
      if (applying || reconciling) end();
      else dismissPanel();
    }, "btn--danger");
    stop.setAttribute("aria-label", "BEENDEN");
    stop.title = "Gespräch beenden";
    function dismissPanel() {
      if (applying || reconciling) return;
      dismissed = true;
      window.NRCInspector.removeTemporary("sullivan-voice");
      end(); panel.remove(); dock.remove();
      narrow.removeEventListener("change", placeDock);
      layoutObserver.disconnect();
      if (active?.end === end) active = null;
      document.getElementById("sullivanVoice")?.focus();
    }
    stop.disabled = true;
    actions.append(mute, stop);
    const review = document.createElement("section");
    review.className = "voice-review";
    review.setAttribute("aria-label", "Sullivan-Freigabe");
    const summary = document.createElement("div"); summary.className = "voice-summary";
    summary.append(status, usage);
    const delivery = document.createElement("p");
    delivery.className = "ai-action-desc";
    delivery.dataset.voiceDelivery = "";
    delivery.hidden = true;
    body.prepend(delivery);
    review.append(summary, body);
    let openRequest = 0;
    active = { workspace, executionPolicy: memoryOptions.execution_policy, end, forget, expand: () => setCollapsed(false, false) };
    setCollapsed(true);
    toggle.focus();
    panel.addEventListener("keydown", event => {
      event.stopPropagation(); // Do not trigger workspace shortcuts from panel controls.
      if (event.key === "Escape") {
        event.preventDefault(); setCollapsed(true); toggle.focus();
      }
    });

    function setCollapsed(value, automatic = true) {
      if (dismissed) return;
      const request = ++openRequest;
      if (value) {
        window.NRCInspector.removeTemporary("sullivan-voice");
        collapsed = true;
        updatePanel();
        return;
      }
      window.NRCInspector.openEntity({
        type: "temporary", id: "sullivan-voice",
        render(host, inspectorHeader) {
          collapsed = false;
          host.replaceChildren(review);
          const identity = document.createElement("div");
          identity.className = "inspector-identity-row";
          const heading = document.createElement("span");
          heading.className = "header-text"; heading.textContent = "SULLIVAN · SPRACHE";
          identity.append(heading);
          const mode = document.createElement("div"); mode.className = "inspector-mode-row";
          mode.innerHTML = window.NRCDetailUI.renderCloseControl("voiceReviewClose");
          mode.querySelector("button").onclick = () => {
            if (ended && !applying && !reconciling) dismissPanel();
            else setCollapsed(true);
          };
          inspectorHeader.replaceChildren(identity, mode);
          updatePanel();
        },
        onLeave() {
          openRequest++;
          collapsed = true;
          review.remove();
          updatePanel();
        },
      }, { automatic, isCancelled: () => dismissed || request !== openRequest });
    }

    function updatePanel() {
      if (dismissed) return;
      if (panel.parentElement !== dock) dock.append(panel);
      if (collapsed && review.parentElement !== dock) dock.append(review);
      review.hidden = collapsed;
      body.hidden = collapsed;
      panel.setAttribute("role", "region");
      panel.classList.add("voice-panel--collapsed");
      toggle.setAttribute("aria-expanded", String(!collapsed));
      const label = collapsed ? (applying || reconciling ? "BESTÄTIGUNG AUSSTEHEND" : hasProposal ? "VORSCHLÄGE PRÜFEN" : "ÖFFNEN") : "MINIMIEREN";
      toggle.setAttribute("aria-label", label);
      toggle.title = `${label} · ${workspace} · ${status.textContent}`;
      compactTime.textContent = elapsed;
      compactNotice.textContent = applying || reconciling ? "PRÜFT …" : hasProposal ? "1 FREIGABE" : displayedError ? "FEHLER" : "";
      compactNotice.hidden = !compactNotice.textContent;
      toggle.replaceChildren(compactName, compactTime, compactNotice, compactArrow);
      const muted = mute.getAttribute("aria-pressed") === "true";
      const muteAction = muted ? "MIKROFON AN" : "MIKROFON STUMM";
      mute.setAttribute("aria-label", muteAction);
      mute.title = muteAction;
      mute.textContent = muted ? "MIC AUS" : "MIC AN";
      stop.textContent = "ENDE";
    }

    async function request(op, values = {}) {
      if ((op === "create" || op === "apply") && currentWorkspaceId !== workspace) {
        throw new Error("Workspace gewechselt; keine neue Aktion gestartet.");
      }
      const response = await fetch(getAiUrl() + "/voice/" + op, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ workspace, id, ...values }),
        signal: AbortSignal.timeout(op === "create" || op === "apply" ? 45000 : 10000),
        keepalive: op === "close",
      });
      if (!response.ok) throw new Error(await response.text());
      return response.json();
    }

    function disablePlan() {
      body.querySelectorAll("[data-voice-plan] button, [data-voice-plan] input").forEach(el => { el.disabled = true; });
    }

    function cleanup() {
      if (!lastApply) setCollapsed(false);
      if (!reconciling) clearTimeout(pollTimer);
      clearInterval(clockTimer); clearTimeout(closeTimer);
      microphone?.getTracks().forEach(track => track.stop());
      events?.close(); peer?.close(); audio.srcObject = null;
      ready = false; stop.disabled = true; mute.disabled = true;
      disablePlan();
      window.removeEventListener("pagehide", onPageHide);
    }

    function end(message = "Gespräch beendet. Abschlussverbrauch wird ermittelt …") {
      if (ended) return;
      ended = true;
      status.textContent = message;
      if (!lastApply) setCollapsed(false);
      disablePlan(); stop.disabled = true; mute.disabled = true;
      // Stop capture immediately, but preserve transport for the final usage event.
      microphone?.getTracks().forEach(track => { track.enabled = false; });
      if (events?.readyState === "open" && ready) events.send(JSON.stringify({ type: "session.close" }));
      if (id) request("close").catch(() => {}); // server watchdog also expires abandoned sessions
      if (!peer) cleanup();
      else closeTimer = setTimeout(() => {
        status.textContent = "Gespräch beendet; Abschlussverbrauch unbestätigt. Nicht automatisch neu verbunden.";
        cleanup();
      }, 15000);
    }
    function forget() {
      forgotten = true;
      end();
      approvedActions = [];
      lastApply = "";
      hasProposal = false;
      displayedError = "";
      body.querySelector("[data-voice-answer]").replaceChildren();
      body.querySelector("[data-voice-plan]").replaceChildren();
      body.querySelector("[data-voice-result]").replaceChildren();
      status.textContent = reconciling ? "Verlauf gelöscht. Bestätigungsergebnis wird noch geprüft …" : "Verlauf gelöscht.";
      updatePanel();
    }
    function onPageHide() { end(); }
    window.addEventListener("pagehide", onPageHide);

    async function connect() {
      stop.disabled = false;
      status.textContent = "Mikrofon freigeben …";
      try {
        microphone = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
        if (ended) { cleanup(); return; }
        peer = new RTCPeerConnection();
        peer.ontrack = event => {
          audio.srcObject = new MediaStream([event.track]);
          audio.play().catch(() => { audio.hidden = false; setCollapsed(false); status.textContent = "Bitte Wiedergabe starten."; });
        };
        peer.onconnectionstatechange = () => {
          if (["failed", "disconnected"].includes(peer.connectionState)) end("Verbindung unterbrochen. Kein automatischer Neustart.");
        };
        microphone.getTracks().forEach(track => peer.addTrack(track, microphone));
        events = peer.createDataChannel("oai-events");
        events.onmessage = ({ data }) => {
          let event;
          try { event = JSON.parse(data); } catch { return; }
          if (event.type === "session.started") {
            ready = true;
            if (closeOnly || ended) {
              events.send(JSON.stringify({ type: "session.close" }));
              return;
            }
            mute.disabled = false;
            status.textContent = "VERBUNDEN";
          }
          if (event.type === "session.input_transcript.delta") {
            localSpeech = true; disablePlan();
          }
          if (event.type === "session.closed") {
            ended = true;
            status.textContent = reconciling ? "Gespräch beendet. Bestätigungsergebnis wird noch geprüft …" : "GESPRÄCH BEENDET";
            const seconds = Number(event.usage?.seconds);
            usage.textContent = Number.isFinite(seconds)
              ? `${workspace}${memoryLabel} · ${(seconds / 60).toFixed(1)} Minuten`
              : `Abschlussverbrauch unbestätigt${memoryLabel}.`;
            cleanup();
          }
          if (event.type === "error") end("GPT-Live-Fehler. Gespräch wird beendet.");
        };
        events.onclose = () => { if (!ended) end("Sprachverbindung getrennt; Abschlussverbrauch unbestätigt."); };
        await peer.setLocalDescription(await peer.createOffer());
        if (peer.iceGatheringState !== "complete") await new Promise((resolve, reject) => {
          const timeout = setTimeout(() => { peer.removeEventListener("icegatheringstatechange", changed); reject(new Error("ICE-Zeitlimit")); }, 10000);
          function changed() {
            if (peer.iceGatheringState !== "complete") return;
            clearTimeout(timeout); peer.removeEventListener("icegatheringstatechange", changed); resolve();
          }
          peer.addEventListener("icegatheringstatechange", changed); changed();
        });
        if (ended) { cleanup(); return; }
        status.textContent = "Verbinde GPT-Live …";
        const result = await request("create", { sdp: peer.localDescription.sdp, ...memoryOptions });
        id = result.id; closeOnly = result.close_only === true;
        await peer.setRemoteDescription({ type: "answer", sdp: result.sdp });
        if (ended || closeOnly) {
          if (!ended) end("Serververbindung fehlgeschlagen; Sprachsession wird beendet.");
          else request("close").catch(() => {});
          return;
        }
        started = Date.now();
        clockTimer = setInterval(() => {
          if (currentWorkspaceId !== workspace) { end("Workspace gewechselt. Gespräch beendet."); return; }
          const seconds = Math.floor((Date.now() - started) / 1000);
          if (!ready && seconds >= 15) { end("GPT-Live hat den Gesprächsstart nicht bestätigt."); return; }
          usage.textContent = `${workspace}${memoryLabel} · ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")} / 10:00`;
          elapsed = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
          updatePanel();
          if (seconds >= 600) end("Zeitlimit erreicht. Gespräch beendet.");
        }, 1000);
        poll();
      } catch (error) {
        status.textContent = `Verbindung fehlgeschlagen: ${error.message}`;
        if (id) request("close").catch(() => {});
        ended = true; cleanup();
      }
    }

    function showResult(data, receiptRevision) {
      if (receiptRevision !== approvalRevision || receiptRevision === completedApprovalRevision) return;
      completedApprovalRevision = receiptRevision;
      reconciling = false;
      if (forgotten) {
        lastApply = "receipt";
        status.textContent = "Verlauf gelöscht. Ergebnis der Bestätigung siehe unten.";
        const ids = (data.applied || []).map(entry => entry.entity?.id ?? entry.created_entity?.id ?? entry.deleted_entity?.id ?? entry.action_id);
        body.querySelector("[data-voice-result]").textContent = `${ids.length} Aktionen erfolgreich (IDs: ${ids.join(", ") || "—"}). ${data.failed?.length || 0} mit Fehler oder unbestätigtem Ausgang. Nicht erneut ausführen.`;
        updatePanel();
        return;
      }
      lastApply = JSON.stringify(data);
      hasProposal = false;
      disablePlan();
      const root = body.querySelector("[data-voice-result]");
      root.replaceChildren();
      const summary = document.createElement("p");
      summary.className = "nrc-dialog-message";
      summary.textContent = `${data.applied?.length || 0} Aktionen erfolgreich · ${data.failed?.length || 0} mit Fehler oder unbestätigtem Ausgang. Übrige Aktionen wurden nicht automatisch ausgeführt.`;
      if (data.ok === false || data.failed?.length) summary.textContent += " Datensätze prüfen: Eine Aktion könnte trotz Fehler gespeichert sein. Nicht erneut anwenden.";
      root.append(summary);
      for (const [entries, failed] of [[data.applied || [], false], [data.failed || [], true]]) {
        for (const entry of entries) {
          const action = approvedActions.find(action => action.id === entry.action_id) || entry;
          const card = document.createElement("section"); card.className = "ai-action-plan";
          const title = document.createElement("div"); title.className = "ai-action-plan-header";
          title.textContent = `${actionName(action)}${action.title ? ` · ${action.title}` : ""}`;
          const outcome = document.createElement("p"); outcome.className = "nrc-dialog-message";
          outcome.textContent = failed ? "Fehler oder Ausgang unbestätigt. Datensatz prüfen, nicht erneut ausführen."
            : entry.already_applied ? "Bereits ausgeführt; nicht erneut angewendet." : "Erfolgreich ausgeführt.";
          const content = document.createElement("div"); content.className = "ai-action-plan-status";
          content.append(outcome); card.append(title, content);
          const entity = entry.deleted_entity || entry.entity || entry.created_entity;
          if (entity) {
            const label = `${valueNames[entity.type] || entity.type} #${entity.id}${entity.title ? ` · ${entity.title}` : ""}`;
            if (entry.deleted_entity) {
              const deleted = document.createElement("p"); deleted.className = "ai-action-desc";
              deleted.textContent = `Gelöscht: ${label}`; content.append(deleted);
            } else {
              content.append(button(`${label} ↗`, () => {
                if (applying || reconciling) return;
                setCollapsed(true);
                NRCAI.navigateToSource(entity, 0n);
              }, "btn--ghost"));
            }
          }
          const edge = entry.deleted_edge || entry.created_edge;
          if (edge) content.append(renderFields(edge));
          const details = document.createElement("details");
          const label = document.createElement("summary"); label.textContent = "Technische Details";
          details.append(label, renderFields({ id: entry.action_id, ...(entry.error ? { error: entry.error } : {}) }));
          content.append(details); root.append(card);
        }
      }
      if (data.ok === true && !data.failed?.length) setCollapsed(true);
      else { displayedError = "Ausführung prüfen"; setCollapsed(false); }
      updatePanel();
    }

    async function poll() {
      if (ended && !reconciling) return;
      try {
        const data = await request("status");
        const states = Object.values(data.context_delivery || {}).map(item => item.state);
        delivery.hidden = !states.length || forgotten;
        delivery.textContent = states.some(state => state === "rejected" || state === "unconfirmed")
          ? "Zusatzkontext nicht vollständig bestätigt. Gespeicherter Verlauf bleibt erhalten."
          : states.includes("pending") ? "Zusatzkontext wird an das Sprachmodell übermittelt…"
          : "Zusatzkontext beim Sprachmodell angekommen. Das bestätigt noch keine Sprachausgabe.";
        // Operation reconciliation outlives the audio. In particular, a terminal
        // status can contain the only surviving receipt for an applied write.
        if (data.apply_result) {
          showResult(data.apply_result, data.apply_revision);
        }
        if (data.error && !data.applying && reconciling && data.apply_revision === approvalRevision) {
          reconciling = false;
          hasProposal = false;
          const error = forgotten ? "Ausgang unbestätigt. Datensätze prüfen; nicht erneut ausführen." : data.error;
          body.querySelector("[data-voice-result]").textContent = error;
          displayedError = error;
          setCollapsed(false);
          updatePanel();
        }
        if (data.closed) end(data.error || "Gespräch beendet. Ergebnis der Bestätigung siehe unten.");
        if (ended) {
          if (!reconciling) { cleanup(); return; }
        } else {
          if (data.revision !== revision) { revision = data.revision; localSpeech = false; }
          if (data.error) {
            status.textContent = data.error;
            if (data.error !== displayedError) setCollapsed(false);
          }
          else status.textContent = data.applying ? "BESTÄTIGTE AKTIONEN WERDEN AUSGEFÜHRT …" : data.busy ? "SULLIVAN RECHERCHIERT …" : "VERBUNDEN";
          displayedError = data.error || "";
          const key = `${data.revision}:${data.result?.plan_id || ""}:${!!data.result}:${data.busy}:${data.applying}`;
          if (key !== planKey) {
            planKey = key;
            render(data);
          }
          if (localSpeech || applying || reconciling) disablePlan();
        }
      } catch (error) {
        end(`Status nicht erreichbar: ${error.message}`);
        if (!reconciling) return;
      }
      if (reconciling && Date.now() >= reconcileDeadline) {
        reconciling = false;
        hasProposal = false;
        displayedError = "Ausgang unbestätigt";
        body.querySelector("[data-voice-result]").textContent = "Ausgang weiterhin unbestätigt. Datensätze prüfen; Bestätigung nicht wiederholen.";
        updatePanel();
        end(); cleanup(); return;
      }
      pollTimer = setTimeout(poll, 500);
    }

    function render(data) {
      if (forgotten) return;
      const answer = body.querySelector("[data-voice-answer]");
      const plan = body.querySelector("[data-voice-plan]");
      answer.replaceChildren(); plan.replaceChildren();
      hasProposal = !!data.result?.proposed_actions?.length;
      updatePanel();
      if (!data.result) return;
      const result = data.result;
      const text = document.createElement("p"); text.className = "ai-action-desc"; text.textContent = result.answer;
      answer.append(text);
      for (const source of result.sources || []) {
        answer.append(button(`${source.title || source.type} · ${source.id} ↗`, () => {
          if (applying || reconciling) return;
          setCollapsed(true);
          NRCAI.navigateToSource(source, 0n);
        }, "btn--ghost"));
      }
      if (!result.plan_id || !result.proposed_actions?.length) return;
      const card = document.createElement("div"); card.className = "ai-action-plan";
      const heading = document.createElement("div"); heading.className = "ai-action-plan-header";
      heading.textContent = `VORSCHLAG · ${result.proposed_actions.length} AKTIONEN · REV ${data.revision}`;
      card.append(heading);
      const checks = [];
      for (const [index, action] of result.proposed_actions.entries()) {
        const row = document.createElement("label"); row.className = "ai-action-row";
        const check = document.createElement("input"); check.type = "checkbox"; check.value = action.id;
        check.setAttribute("aria-label", `${actionName(action)}: ${action.title || action.id}`);
        // Deliberately unchecked: selection must be explicit, including deletes.
        checks.push(check);
        const content = document.createElement("div"); content.className = "ai-action-body";
        const title = document.createElement("div"); title.className = "ai-action-title";
        title.textContent = `${index + 1}. ${actionName(action)}`;
        // Keep all approved values, including empty, zero and unknown fields.
        const { type, id, ...values } = action;
        content.append(title, renderFields(values, true, result.proposed_actions));
        row.append(check, content); card.append(row);
      }
      const hint = document.createElement("p"); hint.className = "nrc-dialog-message voice-approval-hint";
      hint.textContent = "Alle Felder prüfen und Aktionen auswählen. Neue Sprache macht diesen Vorschlag ungültig. Gesprochenes Ja führt nichts aus.";
      const confirm = button("AUSWAHL BESTÄTIGEN", async () => {
        const ids = checks.filter(el => el.checked && !el.disabled).map(el => el.value);
        if (!ids.length || applying || reconciling || ended || localSpeech) return;
        applying = true; reconciling = true; reconcileDeadline = Date.now() + 60000;
        approvedActions = result.proposed_actions.filter(action => ids.includes(action.id));
        lastApply = "";
        body.querySelector("[data-voice-result]").replaceChildren();
        approvalRevision = data.revision;
        disablePlan();
        body.querySelectorAll("[data-voice-answer] button").forEach(el => { el.disabled = true; });
        status.textContent = "BESTÄTIGUNG WIRD AUSGEFÜHRT …";
        try { showResult(await request("apply", { revision: data.revision, plan_id: result.plan_id, action_ids: ids }), data.revision); }
        catch (error) {
          if (reconciling) status.textContent = forgotten
            ? "Ausgang unbestätigt. Datensätze prüfen; nicht erneut ausführen."
            : `Nicht erneut bestätigen. Status prüfen: ${error.message}`;
        }
        finally { applying = false; planKey = ""; updatePanel(); }
      }, "btn--primary");
      confirm.disabled = true;
      checks.forEach(check => check.onchange = () => { confirm.disabled = !checks.some(el => el.checked) || localSpeech || applying || reconciling || ended; });
      card.append(hint, confirm); plan.append(card);
      if (data.busy || data.applying || localSpeech) disablePlan();
      else setCollapsed(false);
    }
    // The voice entry is the explicit start gesture; no setup dialog is needed.
    connect();
  }
  document.getElementById("sullivanVoice")?.addEventListener("click", open);
  window.addEventListener("nrc-memory-change", event => {
    if (active?.workspace === event.detail.workspace) active.end("Memory mode changed; start a new conversation.");
  });
  window.addEventListener("nrc-memory-forgotten", event => {
    if (active?.workspace === event.detail.workspace &&
        (!event.detail.personalOnly || active.executionPolicy !== "temporary")) active.forget();
  });
})();
