// GPT-Live owns audio only. The server owns plans; only a human button handler
// submits selected IDs. No model/data-channel event can call Apply.
(() => {
  let active = null;
  const button = (text, action, variant = "") => {
    const el = document.createElement("button");
    el.type = "button";
    el.className = `btn ${variant}`;
    el.textContent = text;
    el.onclick = action;
    return el;
  };

  function open() {
    if (active) { active.expand(); return; }
    const workspace = currentWorkspaceId;
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
    usage.textContent = `Workspace: ${workspace}`;
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
    const stop = button("BEENDEN", () => end(), "btn--danger");
    stop.setAttribute("aria-label", "BEENDEN");
    stop.title = "Gespräch beenden";
    const dismiss = button("SCHLIESSEN", () => {
      if (applying || reconciling) return;
      dismissed = true;
      window.NRCInspector.removeTemporary("sullivan-voice");
      end(); panel.remove(); dock.remove();
      narrow.removeEventListener("change", placeDock);
      layoutObserver.disconnect();
      if (active?.end === end) active = null;
      document.getElementById("sullivanVoice")?.focus();
    }, "btn--ghost");
    stop.disabled = true;
    actions.append(mute, stop);
    const review = document.createElement("section");
    review.className = "voice-review";
    review.setAttribute("aria-label", "Sullivan-Freigabe");
    const reviewActions = document.createElement("div");
    reviewActions.className = "voice-actions";
    reviewActions.append(dismiss);
    review.append(status, usage, body, reviewActions);
    let openRequest = 0;
    active = { end, expand: () => setCollapsed(false, false) };
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
          const close = button("×", () => setCollapsed(true), "btn--danger task-detail-close");
          close.setAttribute("aria-label", "Zurück zum vorherigen Inhalt");
          identity.append(heading, close);
          const mode = document.createElement("div"); mode.className = "inspector-mode-row";
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
            status.textContent = "VERBUNDEN · Mikrofon an · Änderungen nur per Klick bestätigen.";
          }
          if (event.type === "session.input_transcript.delta") {
            localSpeech = true; disablePlan();
          }
          if (event.type === "session.closed") {
            ended = true;
            status.textContent = reconciling ? "Gespräch beendet. Bestätigungsergebnis wird noch geprüft …" : "GESPRÄCH BEENDET";
            const seconds = Number(event.usage?.seconds);
            usage.textContent = Number.isFinite(seconds)
              ? `${workspace} · ${(seconds / 60).toFixed(1)} Minuten`
              : "Abschlussverbrauch unbestätigt.";
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
        const result = await request("create", { sdp: peer.localDescription.sdp });
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
          usage.textContent = `${workspace} · ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")} / 10:00`;
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
      lastApply = JSON.stringify(data);
      hasProposal = false;
      disablePlan();
      dismiss.disabled = applying;
      const root = body.querySelector("[data-voice-result]");
      root.replaceChildren();
      const summary = document.createElement("p");
      summary.className = "nrc-dialog-message";
      summary.textContent = `${data.applied?.length || 0} Aktionen erfolgreich · ${data.failed?.length || 0} mit Fehler oder unbestätigtem Ausgang. Übrige Aktionen wurden nicht automatisch ausgeführt.`;
      if (data.ok === false || data.failed?.length) summary.textContent += " Datensätze prüfen: Eine Aktion könnte trotz Fehler gespeichert sein. Nicht erneut anwenden.";
      const details = document.createElement("details");
      const title = document.createElement("summary"); title.textContent = "Ausführungsergebnis / Datensatz-IDs";
      const pre = document.createElement("pre"); pre.className = "ai-action-desc"; pre.textContent = JSON.stringify(data, null, 2);
      details.append(title, pre); root.append(summary, details);
      if (data.ok === true && !data.failed?.length) setCollapsed(true);
      else { displayedError = "Ausführung prüfen"; setCollapsed(false); }
      updatePanel();
    }

    async function poll() {
      if (ended && !reconciling) return;
      try {
        const data = await request("status");
        // Operation reconciliation outlives the audio. In particular, a terminal
        // status can contain the only surviving receipt for an applied write.
        if (data.apply_result) {
          showResult(data.apply_result, data.apply_revision);
        }
        if (data.error && !data.applying && reconciling && data.apply_revision === approvalRevision) {
          reconciling = false;
          hasProposal = false;
          body.querySelector("[data-voice-result]").textContent = data.error;
          displayedError = data.error;
          setCollapsed(false);
          updatePanel();
        }
        dismiss.disabled = applying || reconciling;
        if (data.closed) end(data.error || "Gespräch beendet. Ergebnis der Bestätigung siehe unten.");
        if (ended) {
          if (!reconciling) { cleanup(); return; }
        } else {
          if (data.revision !== revision) { revision = data.revision; localSpeech = false; }
          if (data.error) {
            status.textContent = data.error;
            if (data.error !== displayedError) setCollapsed(false);
          }
          else status.textContent = data.applying ? "BESTÄTIGTE AKTIONEN WERDEN AUSGEFÜHRT …" : data.busy ? "SULLIVAN RECHERCHIERT …" : "VERBUNDEN · Änderungen nur per Klick bestätigen.";
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
        reconciling = false; dismiss.disabled = applying;
        hasProposal = false;
        displayedError = "Ausgang unbestätigt";
        body.querySelector("[data-voice-result]").textContent = "Ausgang weiterhin unbestätigt. Datensätze prüfen; Bestätigung nicht wiederholen.";
        updatePanel();
        end(); cleanup(); return;
      }
      pollTimer = setTimeout(poll, 500);
    }

    function render(data) {
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
      for (const action of result.proposed_actions) {
        const row = document.createElement("label"); row.className = "ai-action-row";
        const check = document.createElement("input"); check.type = "checkbox"; check.value = action.id;
        check.setAttribute("aria-label", `${action.type}: ${action.title || action.id}`);
        // Deliberately unchecked: selection must be explicit, including deletes.
        checks.push(check);
        const content = document.createElement("div"); content.className = "ai-action-body";
        const title = document.createElement("div"); title.className = "ai-action-title";
        title.textContent = `${action.type} · ${action.title || action.id}`;
        const fields = document.createElement("pre"); fields.className = "ai-action-desc";
        fields.textContent = JSON.stringify(action, null, 2); // show every approved field, never clip content
        content.append(title, fields); row.append(check, content); card.append(row);
      }
      const hint = document.createElement("p"); hint.className = "nrc-dialog-message";
      hint.textContent = "Alle Felder prüfen und Aktionen auswählen. Neue Sprache macht diesen Vorschlag ungültig. Gesprochenes Ja führt nichts aus.";
      const confirm = button("AUSWAHL BESTÄTIGEN", async () => {
        const ids = checks.filter(el => el.checked && !el.disabled).map(el => el.value);
        if (!ids.length || applying || reconciling || ended || localSpeech) return;
        applying = true; reconciling = true; reconcileDeadline = Date.now() + 60000;
        lastApply = "";
        body.querySelector("[data-voice-result]").replaceChildren();
        approvalRevision = data.revision;
        disablePlan(); dismiss.disabled = true;
        body.querySelectorAll("[data-voice-answer] button").forEach(el => { el.disabled = true; });
        status.textContent = "BESTÄTIGUNG WIRD AUSGEFÜHRT …";
        try { showResult(await request("apply", { revision: data.revision, plan_id: result.plan_id, action_ids: ids }), data.revision); }
        catch (error) { if (reconciling) status.textContent = `Nicht erneut bestätigen. Status prüfen: ${error.message}`; }
        finally { applying = false; planKey = ""; dismiss.disabled = reconciling; updatePanel(); }
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
})();
