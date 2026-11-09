// One personal conversation for text and voice. Retention is server-owned;
// temporary mode is an explicit page choice, never an outage fallback.
(() => {
  let temporaryWorkspace = null;
  let busy = false;
  let generation = 0;
  let history = null;
  let refreshing = false;
  let reconciling = false;
  // Rendering is optional; cached personal answers still need epoch checks
  // after leaving Sullivan or explicitly choosing a temporary conversation.
  const observations = new Map();
  const localRuns = new Map();

  function trackRun(workspace, id) {
    if (!id) return;
    if (!localRuns.has(workspace)) localRuns.set(workspace, new Set());
    localRuns.get(workspace).add(id);
  }

  function finishRun(workspace, id, rendered) {
    if (rendered || !localRuns.get(workspace)?.delete(id)) return;
    if (history?.workspace === workspace) history.dirty = true;
    void refresh();
  }

  function options(workspace = currentWorkspaceId) {
    const retained = temporaryWorkspace !== workspace;
    return { execution_policy: retained ? "private" : "temporary", require_memory: retained };
  }

  function render() {
    document.querySelectorAll("[data-personal-memory]").forEach(button => {
      button.textContent = "TEMPORÄR";
      button.setAttribute("aria-label", "Temporäres Gespräch");
      button.setAttribute("aria-pressed", String(!options().require_memory));
      button.classList.toggle("active", !options().require_memory);
      button.title = "Temporär: persönlichen Verlauf weder lesen noch speichern";
      button.disabled = busy;
    });
  }

  function change(workspace, retained, notify = true) {
    generation++;
    history = null;
    temporaryWorkspace = retained ? null : workspace;
    document.querySelectorAll("[data-sullivan-history]").forEach(el => el.remove());
    if (notify) window.dispatchEvent(new CustomEvent("nrc-memory-change", { detail: { workspace } }));
    render();
  }

  // Complete invalidation before publishing the new epoch or admitting a run.
  // A policy read is not permission to overwrite an older cached observation.
  async function reconcilePolicy(workspace, policy, { force = false, retained = policy.enabled && options(workspace).require_memory } = {}) {
    if (reconciling || workspace !== currentWorkspaceId) return null;
    const observation = observations.get(workspace);
    if (force || (observation && observation.policy.epoch !== policy.epoch)) {
      reconciling = true;
      try {
        change(workspace, retained, force || options(workspace).require_memory);
        const token = generation;
        localRuns.delete(workspace);
        window.dispatchEvent(new CustomEvent("nrc-memory-forgotten", { detail: { workspace, personalOnly: true } }));
        await window.NRCAI?.forgetLocalHistory?.(workspace, { personalOnly: true });
        if (token !== generation || workspace !== currentWorkspaceId) return null;
        observations.delete(workspace);
        if (policy.enabled && retained) observations.set(workspace, { policy });
        return token;
      } finally { reconciling = false; }
    }
    if (!policy.enabled && options(workspace).require_memory) change(workspace, false);
    if (policy.enabled && retained && !observation) observations.set(workspace, { policy });
    return generation;
  }

  async function request(workspace, operation, values = {}) {
    if (currentWorkspaceId !== workspace) throw new Error("Workspace gewechselt. Bitte erneut öffnen.");
    const response = await fetch(getAiUrl() + "/ask/memory", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ workspace, operation, ...values }),
      signal: AbortSignal.timeout(15000), cache: "no-store",
    });
    if (currentWorkspaceId !== workspace) throw new Error("Workspace gewechselt. Bitte erneut öffnen.");
    if (!response.ok) {
      if (response.status === 403 || response.status === 404) throw new Error("Persönlicher Verlauf ist hier nicht verfügbar. Du kannst ausdrücklich temporär fortfahren.");
      if (response.status === 409) throw new Error("Der Verlauf wurde inzwischen geändert. Bitte aktualisieren.");
      throw new Error("Verbindung zum Verlauf fehlgeschlagen. Änderungen könnten bereits gespeichert sein. Bitte aktualisieren.");
    }
    const result = await response.json();
    if (currentWorkspaceId !== workspace) throw new Error("Workspace gewechselt. Bitte erneut öffnen.");
    return result;
  }

  function stopLocal() {
    if (window.NRCAI?.resetAskSession?.() === false) throw new Error("Eine Bestätigung läuft noch. Bitte das Ergebnis abwarten.");
  }

  function toggleTemporary() {
    if (busy || reconciling) return;
    try {
      stopLocal();
      change(currentWorkspaceId, !options().require_memory);
    } catch (error) { logMessage("Error", error.message); }
  }

  // Durable preferences use the existing Settings command group, not a second
  // settings surface in the conversation header.
  async function settings(value = "") {
    if (busy || reconciling) return;
    const operation = String(value).trim().toLowerCase();
    if (!["", "on", "off", "export", "forget"].includes(operation)) {
      logMessage("CommandResult", "SULLIVAN MEMORY: on | off | export | forget");
      return;
    }
    const workspace = currentWorkspaceId;
    busy = true; render(); window.dispatchEvent(new Event("nrc-memory-busy"));
    try {
      let policy = await request(workspace, "inspect");
      if (!operation) {
        logMessage("CommandResult", `SULLIVAN MEMORY: ${policy.enabled ? "ON" : "OFF"} · ${workspace} · Nur dein Konto. on | off | export | forget. Ausschalten löscht keinen Verlauf. NRC-Betreiber und KI-Anbieter verarbeiten die Inhalte.`);
        return;
      }
      if (operation === "on" || operation === "off") {
        stopLocal();
        policy = await request(workspace, "configure", { confirm: true, policy: { epoch: policy.epoch, enabled: operation === "on" } });
        if (await reconcilePolicy(workspace, policy, { force: true, retained: policy.enabled }) !== generation) return;
        logMessage("CommandResult", `SULLIVAN MEMORY ${policy.enabled ? "ON" : "OFF"} · Bisheriger Verlauf bleibt erhalten.`);
        return;
      }
      if (operation === "forget") {
        const confirmed = await NRCDialog.confirm(`Gesamten persönlichen Verlauf für dein Konto in „${workspace}“ löschen? Laufende Gespräche werden beendet. Bereits bestätigte NRC-Änderungen, Backups und an KI-Anbieter übermittelte Daten bleiben bestehen. Minimale Ausführungsbelege verhindern doppelte Änderungen.`, { title: "VERLAUF LÖSCHEN", confirmLabel: "Endgültig löschen", cancelLabel: "Abbrechen" });
        if (!confirmed) return;
        if (workspace !== currentWorkspaceId) return;
        stopLocal();
        await request(workspace, "forget_all", { epoch: policy.epoch, confirm: true });
        change(workspace, options(workspace).require_memory);
        observations.delete(workspace);
        localRuns.delete(workspace);
        window.dispatchEvent(new CustomEvent("nrc-memory-forgotten", { detail: { workspace } }));
        await window.NRCAI?.forgetLocalHistory?.(workspace);
        return;
      }
      const epoch = policy.epoch;
      const originals = [];
      let after = -1;
      for (;;) {
        const page = await request(workspace, "export", { epoch, after, limit: 100 });
        originals.push(...page);
        if (page.length < 100) break;
        after = page.at(-1).sequence;
      }
      const latest = await request(workspace, "inspect");
      if (latest.epoch !== epoch) throw new Error("Verlauf während des Exports geändert. Bitte aktualisieren.");
      const url = URL.createObjectURL(new Blob([JSON.stringify({ workspace, epoch, originals }, null, 2)], { type: "application/json" }));
      const link = document.createElement("a"); link.href = url; link.download = "sullivan-personal-memory.json";
      link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
      logMessage("CommandResult", "Verlauf exportiert. Die Datei enthält private Gesprächsinhalte und wird beim Vergessen nicht mitgelöscht.");
    } catch (error) {
      if (workspace === currentWorkspaceId) logMessage("Error", error.message);
    } finally { busy = false; render(); window.dispatchEvent(new Event("nrc-memory-busy")); }
  }

  async function prepare(workspace = currentWorkspaceId) {
    if (reconciling || workspace !== currentWorkspaceId) return false;
    const token = generation;
    if (!options(workspace).require_memory) return true;
    try {
      const policy = await request(workspace, "inspect");
      if (token !== generation) return false;
      const reconciled = await reconcilePolicy(workspace, policy);
      return reconciled === generation && workspace === currentWorkspaceId;
    } catch {
      if (currentWorkspaceId === workspace) logMessage("Error", "Persönlicher Verlauf nicht erreichbar. Erneut versuchen oder TEMPORÄR wählen und die Anfrage erneut senden.");
    }
    return false;
  }

  // Restore evidence, not executable plans. No historical response gets Apply
  // buttons, and historical voice output is never played automatically.
  async function resume(output, workspace = currentWorkspaceId, pages = 1) {
    if (reconciling || workspace !== currentWorkspaceId || !output || !window.NRCAI?.isSullivanView?.() || !options(workspace).require_memory || output.querySelector("[data-sullivan-history]")) return;
    if (history?.workspace === workspace) {
      if (!history.dirty) { history.output = output; output.prepend(history.root); return; }
      history.root.remove(); history = null;
    }
    const token = generation;
    const root = document.createElement("section");
    const snapshot = { workspace, root, output, pages: 0, ready: false };
    history = snapshot;
    root.dataset.sullivanHistory = "";
    root.className = "sullivan-history";
    const status = document.createElement("p"); status.className = "nrc-dialog-message"; status.setAttribute("role", "status");
    status.textContent = "Gespräch wird geladen…";
    root.append(status); output.prepend(root);
    const valid = () => token === generation && currentWorkspaceId === workspace && history?.root === root && options(workspace).require_memory;
    try {
      const policy = await request(workspace, "changes");
      if (!valid()) return;
      snapshot.policy = policy;
      if (!policy.enabled) { status.textContent = "Erinnerung ausgeschaltet. Neue Gespräche sind temporär."; return; }
      if (!observations.has(workspace)) observations.set(workspace, { policy });
      const turns = document.createElement("div"); root.append(turns);
      let before = -1;
      const older = document.createElement("button"); older.className = "btn btn--ghost"; older.textContent = "Ältere Nachrichten"; older.type = "button";
      root.insertBefore(older, turns);
      async function load() {
        older.disabled = true;
        try {
          const page = await request(workspace, "history", { epoch: policy.epoch, before, limit: 50 });
          if (!valid()) return;
          snapshot.pages++;
          const fragment = document.createDocumentFragment();
          for (const segment of [...page].reverse()) {
            // Preserve the executable local card without hiding other devices' turns.
            if (segment.run_id && localRuns.get(workspace)?.has(segment.run_id)) continue;
            const records = [];
            for (const record of segment.records) {
              const previous = records.at(-1);
              if (segment.channel === "voice" && previous?.role === record.role) previous.text += record.text || "";
              else records.push({ ...record });
            }
            for (const record of records) {
              if (!record.text || !["user", "assistant", "backend"].includes(record.role)) continue;
              const item = document.createElement("article"); item.className = "sullivan-history-turn";
              const label = document.createElement("strong");
              label.textContent = `${record.role === "user" ? "DU" : record.role === "backend" ? "NRC-ERGEBNIS" : "SULLIVAN"}${segment.channel === "voice" ? " · SPRACHE" : ""}`;
              const text = document.createElement("p"); text.textContent = record.text;
              item.append(label, text);
              if (segment.state !== "complete") {
                const state = document.createElement("small");
                state.textContent = segment.state === "active" ? "Noch in Bearbeitung. Nicht erneut absenden." : "Dieses Gespräch wurde nicht vollständig abgeschlossen.";
                item.append(state);
              }
              fragment.append(item);
            }
          }
          turns.prepend(fragment);
          if (page.length) before = page.at(-1).sequence;
          older.hidden = page.length < 50;
          status.textContent = turns.children.length ? "" : "Schreib oder sprich mit mir.";
        } catch (error) { if (valid()) status.textContent = error.message; }
        finally { older.disabled = false; }
      }
      older.onclick = load;
      for (let page = 0; page < pages; page++) {
        await load();
        if (!valid() || older.hidden) break;
      }
      if (!valid()) return;
      const receipts = await request(workspace, "receipts", { limit: 50 });
      if (!valid() || !receipts.length) return;
      const details = document.createElement("details");
      const title = document.createElement("summary"); title.textContent = "Ergebnisse früherer Bestätigungen";
      details.append(title); root.append(details);
      let receiptBefore = -1;
      const more = document.createElement("button"); more.className = "btn btn--ghost"; more.type = "button"; more.textContent = "Weitere Ergebnisse";
      function showReceipts(page) {
        for (const receipt of page) {
          const row = document.createElement("p");
          const ids = Object.entries(receipt.result || {}).filter(([key, value]) => key.endsWith("_id") && value).map(([key, value]) => `${key}: ${value}`).join(" · ");
          row.textContent = `${receipt.state === "applied" ? "Ausgeführt" : receipt.state === "failed" ? "Fehlgeschlagen" : "Ausgang noch unbestätigt – Datensätze prüfen, nicht erneut ausführen"}${ids ? ` · ${ids}` : ""}`;
          details.append(row);
          if (receipt.state !== "applied") details.open = true;
        }
        if (page.length) receiptBefore = page.at(-1).position;
        more.hidden = page.length < 50;
        details.append(more);
      }
      showReceipts(receipts);
      more.onclick = async () => {
        more.disabled = true;
        try { const page = await request(workspace, "receipts", { before: receiptBefore, limit: 50 }); if (valid()) showReceipts(page); }
        catch (error) { if (valid()) status.textContent = error.message; }
        finally { more.disabled = false; }
      };
    } catch (error) {
      if (valid()) { status.textContent = error.message; const retry = document.createElement("button"); retry.type = "button"; retry.className = "btn"; retry.textContent = "Erneut laden"; retry.onclick = () => { history = null; root.remove(); resume(output, workspace); }; root.append(retry); }
    } finally {
      snapshot.ready = true;
    }
  }

  async function refresh() {
    const workspace = currentWorkspaceId;
    const observation = observations.get(workspace);
    const previous = history;
    const token = generation;
    if (refreshing || reconciling || busy || !observation) return;
    refreshing = true;
    try {
      const policy = await request(workspace, "changes");
      if (busy || token !== generation || currentWorkspaceId !== workspace || observations.get(workspace) !== observation) return;
      if (policy.epoch !== observation.policy.epoch) {
        if (await reconcilePolicy(workspace, policy) !== generation) return;
      } else if (!previous?.ready || !previous.policy || previous.workspace !== workspace || history !== previous) return;
      else if (policy.revision === previous.policy.revision && !previous.dirty) return;
      else {
        if (!window.NRCAI?.isSullivanView?.()) { previous.dirty = true; return; }
        previous.root.remove();
        history = null;
      }
      if (previous?.output.isConnected && previous.workspace === currentWorkspaceId && window.NRCAI?.isSullivanView?.()) {
        await resume(previous.output, previous.workspace, Math.max(1, previous.pages));
      }
    } catch { /* Keep the last snapshot; an outage never selects temporary mode. */ }
    finally { refreshing = false; }
  }

  setInterval(refresh, 5000);
  window.addEventListener("focus", refresh);
  document.addEventListener("click", event => { if (event.target.closest("[data-personal-memory]")) toggleTemporary(); });
  window.NRCMemory = { settings, prepare, resume, refresh, trackRun, finishRun, options, render, isBusy: () => busy };
  render();
})();
