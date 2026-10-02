// Desktop notifications for reminder deadlines.
//
// A reminder's state is derived from its deadline, so nothing has to be stored
// to know when it comes due. This module compares the state of every workspace
// reminder with the state it saw last and reports the transitions. The snapshot
// comes from NRCTasks, which owns the reminder rules, so the register and the
// notification can never disagree about a reminder.
//
// Scope and limits:
// - Only while a tab exists. There is no push channel, so a closed browser is
//   silent and a suspended tab catches up on its next evaluation.
// - Reminders belong to the workspace and carry a creator, not an assignee, so
//   the switch is workspace-scoped rather than per user.
window.NRCReminderNotify = (() => {
  const CHECK_INTERVAL_MS = 60 * 1000;
  const PREFERENCE_PREFIX = "nrc-reminder-notifications";
  // A reminder whose window opens is workable, not urgent: the register shows
  // it, and a third popup per reminder would not earn its interruption.
  const VIEWS_THAT_SHOW_REMINDERS = ["reminders", "attention"];
  const STATUS_EXCEPTIONS = ["BLOCKED", "N/A"];

  const el = (id) => document.getElementById(id);
  // Returning to a tab after this long is a new look at the whole set, so what
  // came due in the meantime is summarised instead of reported one by one.
  const AWAY_THRESHOLD_MS = 5 * 60 * 1000;
  let timer = null;
  let summaryDecided = false;
  let hiddenSince = null;
  const lastStates = new Map();

  // The reminder states come from the module that derives them, so a rename
  // there cannot leave the timer comparing against a vocabulary nobody produces.
  function states() {
    return window.NRCTasks?.ReminderState || null;
  }

  function isLate(reminder) {
    return reminder.state === states()?.Late;
  }

  function isNotifiedState(reminder) {
    const known = states();
    return !!known && (reminder.state === known.Urgent || reminder.state === known.Late);
  }

  function preferenceKey() {
    const workspace = typeof currentWorkspaceId === "string" ? currentWorkspaceId : "";
    return `${PREFERENCE_PREFIX}:${workspace}`;
  }

  function mode() {
    try {
      return localStorage.getItem(preferenceKey()) === "off" ? "off" : "all";
    } catch {
      return "all";
    }
  }

  function setMode(value) {
    const next = value === "off" ? "off" : "all";
    try {
      localStorage.setItem(preferenceKey(), next);
    } catch {
      logMessage("Error", "COULD NOT SAVE NOTIFICATION PREFERENCE");
    }
    // Turning the timer on is the moment to ask for the browser permission, if
    // the browser has not been asked yet.
    if (next === "all" && typeof Notification !== "undefined" &&
        Notification.permission === "default") {
      Notification.requestPermission().then(syncControl);
    }
    syncControl();
  }

  function formatDeadline(nanos) {
    if (!nanos || nanos === 0n) return "";
    const date = new Date(Number(nanos / 1000000n));
    const pad = (value) => String(value).padStart(2, "0");
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
      `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  // The register is in front and the operator is looking at it: the state is
  // already on screen, so the popup would only repeat it. The states are still
  // recorded, which is what keeps them from firing later.
  function suppressed() {
    if (document.hidden) return false;
    const view = window.NRCViewManager?.getActiveView?.();
    return VIEWS_THAT_SHOW_REMINDERS.includes(view);
  }

  function deliver(title, body, tag, reminder) {
    if (typeof sendNotification !== "function") return;
    sendNotification(title, { body, tag }, () => {
      if (reminder) {
        window.NRCInspector?.openEntity?.({ roomId: 0n, type: "reminder", id: reminder.asset.assetId });
      } else {
        window.NRCViewManager?.setActiveView?.("reminders");
      }
      window.focus?.();
    });
  }

  function notifySummary(due) {
    if (mode() === "off" || suppressed()) return;
    const late = due.filter(isLate).length;
    const titles = due.slice(0, 3).map((reminder) => reminder.title).join(" · ");
    deliver(
      `${due.length} REMINDERS NEED ATTENTION`,
      [`${late} LATE`, `${due.length - late} DUE SOON`, titles].filter(Boolean).join(" · "),
      "nrc-reminder-summary",
      null,
    );
  }

  function notifyTransitions(transitions) {
    if (mode() === "off" || suppressed()) return;
    for (const { reminder } of transitions) {
      deliver(
        reminder.title,
        `${isLate(reminder) ? "LATE" : "DUE"} · ${formatDeadline(reminder.deadlineAt)}`,
        `nrc-reminder-${reminder.asset.assetId}`,
        reminder,
      );
    }
  }

  function evaluate() {
    const reminders = window.NRCTasks?.getReminderSnapshot?.()?.reminders || [];
    // An empty snapshot is not a session start, it is no information yet: the
    // workspace asset list arrives after the session is ready.
    if (reminders.length === 0) return;

    // The first snapshot of a session summarises what is already due instead of
    // firing one popup per reminder, so a reload never produces a burst.
    if (!summaryDecided) {
      summaryDecided = true;
      for (const reminder of reminders) lastStates.set(String(reminder.asset.assetId), reminder.state);
      const due = reminders.filter(isNotifiedState);
      if (due.length > 0) notifySummary(due);
      return;
    }

    const transitions = [];
    for (const reminder of reminders) {
      const key = String(reminder.asset.assetId);
      const previous = lastStates.get(key);
      lastStates.set(key, reminder.state);
      // A reminder seen for the first time is not a transition: it either
      // arrived with the asset list or was just created, and neither is news.
      if (previous === undefined || previous === reminder.state) continue;
      if (isNotifiedState(reminder)) transitions.push({ reminder, previous });
    }
    notifyTransitions(transitions);
  }

  // The switch lives in the ATTENTION header; the palette command is the same
  // preference for a keyboard-driven workspace.
  function syncControl() {
    const select = el("reminderNotifications");
    if (select && select.value !== mode()) select.value = mode();
    if (typeof updateNotificationStatus === "function") updateNotificationStatus();
    // The permission readout only speaks up when it has something to say; the
    // preference itself is already visible in the switch beside it.
    const status = el("notificationStatus");
    if (status) status.hidden = !STATUS_EXCEPTIONS.includes(status.textContent.trim());
  }

  function wire() {
    const select = el("reminderNotifications");
    if (select && !select.dataset.reminderNotifyWired) {
      select.dataset.reminderNotifyWired = "1";
      select.addEventListener("change", (event) => setMode(event.target.value));
    }
    syncControl();
  }

  function init() {
    wire();
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        hiddenSince = Date.now();
        return;
      }
      const away = hiddenSince === null ? 0 : Date.now() - hiddenSince;
      hiddenSince = null;
      if (away >= AWAY_THRESHOLD_MS) summaryDecided = false;
      evaluate();
    });
    window.addEventListener("focus", evaluate);
    if (timer === null) timer = setInterval(evaluate, CHECK_INTERVAL_MS);
    evaluate();
  }

  // A (re)connect rebuilds the reminder set from the server, so the next
  // snapshot is a session start again: what came due while the tab was away is
  // summarised rather than delivered as one popup per reminder.
  function sessionStarted() {
    summaryDecided = false;
    evaluate();
  }

  return { init, evaluate, sessionStarted, onReminderChanged: evaluate, mode, setMode, syncControl };
})();
