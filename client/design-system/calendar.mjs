// Isolated interaction study. No network calls or persistent writes.
export const TODAY = '2026-09-28';
export function monthDays(month) {
  const first = new Date(`${month}-01T12:00:00Z`);
  const start = new Date(first);
  start.setUTCDate(1 - (first.getUTCDay() + 6) % 7);
  const last = new Date(first);
  last.setUTCMonth(last.getUTCMonth() + 1, 0);
  const count = Math.ceil(((first.getUTCDay() + 6) % 7 + last.getUTCDate()) / 7) * 7;
  return Array.from({ length: count }, (_, i) => {
    const day = new Date(start);
    day.setUTCDate(start.getUTCDate() + i);
    return day.toISOString().slice(0, 10);
  });
}
export function filterRecords(records, person, project) {
  return records.filter(r => (!person || r.assignee === person) && (!project || r.project === project));
}
export function attentionReason(record) {
  if (record.kind === 'MENTION') return 'MENTIONED / SESSION';
  if (record.kind === 'REMINDER') return record.date && record.date < TODAY ? 'DUE REMINDERS / WORKSPACE' : null;
  if (record.assignee !== 'RENE') return null;
  if (record.date && record.date < TODAY) return 'OVERDUE / MY WORK';
  if (record.blocked) return 'BLOCKED / MY WORK';
  return 'ASSIGNED TO ME';
}
const records = [
  { id: '184', title: 'Review deployment checklist', date: '2026-09-25', assignee: 'RENE', project: 'PLATFORM' },
  { id: '175', title: 'Confirm backup retention policy', date: '2026-09-12', assignee: 'ALEX', project: 'PLATFORM' },
  { id: '191', title: 'Ship search index', date: TODAY, assignee: 'RENE', project: 'SEARCH' },
  { id: '204', title: 'Verify customer export permissions before rollout to external collaborators', date: TODAY, assignee: 'ALEX', project: 'PLATFORM' },
  { id: '208', title: 'Document backup recovery procedure', date: TODAY, assignee: 'JORDAN', project: 'PLATFORM' },
  { id: 'r1', kind: 'REMINDER', title: 'Customer follow-up', date: TODAY, time: '14:00', project: 'CUSTOMERS' },
  { id: 'r2', kind: 'REMINDER', title: 'License renewal', date: TODAY, time: '16:00', project: 'ADMIN' },
  { id: '205', title: 'Run load test for search', date: TODAY, assignee: 'RENE', project: 'SEARCH', blocked: true },
  { id: '206', title: 'Update user documentation', date: TODAY, assignee: 'ALEX', project: 'SEARCH' },
  { id: '207', title: 'Review security findings', date: TODAY, assignee: 'JORDAN', project: 'PLATFORM' },
  { id: '209', title: 'Prepare demo environment', date: '2026-09-29', assignee: 'JORDAN', project: 'PLATFORM' },
  { id: 'r3', kind: 'REMINDER', title: 'Customer follow-up', date: '2026-09-29', time: '14:00', project: 'CUSTOMERS' },
  { id: '212', title: 'Verify restore test', date: '2026-09-30', assignee: 'RENE', project: 'PLATFORM' },
  { id: '215', title: 'October release review', date: '2026-10-02', assignee: 'RENE', project: 'SEARCH' },
  { id: '218', title: 'Investigate intermittent indexing failure', date: '', assignee: 'RENE', project: 'SEARCH', blocked: true },
  { id: 'm1', kind: 'MENTION', title: 'Alex mentioned you in Engineering: can you review the rollout?', date: '', project: 'PLATFORM' },
].map(r => ({ kind: 'TASK', assignee: '', time: '', ...r }));

if (typeof document !== 'undefined') {
  const $ = id => document.getElementById(id);
  const state = { view: 'calendar', mode: 'agenda', month: '2026-09', day: TODAY, person: '', project: '', selected: null, overdue: false };
  let opener;
  const escape = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const dateLabel = day => new Intl.DateTimeFormat('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${day}T12:00:00Z`)).toUpperCase();
  const sorted = list => [...list].sort((a, b) => (a.date + a.time).localeCompare(b.date + b.time) || a.id.localeCompare(b.id));
  function rows(list) {
    return list.length ? sorted(list).map(r => `<button class="study-row ${state.selected === r.id ? 'selected' : ''}" data-record="${r.id}"><small>${r.kind}</small><strong>${r.kind === 'TASK' ? `#${r.id} ` : ''}${escape(r.title)}</strong><small>${r.time || (r.date ? 'DATE ONLY' : 'UNDATED')}</small><small class="study-person">${r.assignee || '—'}</small><small class="study-project">${r.project}</small></button>`).join('') : '<p class="study-empty">No matching items. Try another date or filter.</p>';
  }
  const group = (title, list) => `<section class="study-group"><h2>${title} · ${list.length} ITEMS</h2>${rows(list)}</section>`;
  function render() {
    const attention = state.view === 'attention';
    const filtered = filterRecords(records, state.person, state.project).filter(r => r.kind !== 'MENTION' && r.date);
    const past = filtered.filter(r => r.date < TODAY);
    $('title').textContent = attention ? 'ATTENTION' : 'CALENDAR';
    $('range').textContent = attention ? 'MY WORK & SIGNALS' : `${new Intl.DateTimeFormat('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${state.month}-01T12:00:00Z`)).toUpperCase()} · EUROPE/BERLIN`;
    $('controls').hidden = attention;
    $('context').textContent = attention ? 'WHY · Work relevant to Rene, grouped by reason—not by date. Includes undated work and session mentions.' : `WHEN · Workspace deadlines, in date order. ${state.person ? 'Assignee filter shows tasks only; reminders have no assignee.' : 'Reminders and task deadlines; no chat signals or undated work.'}`;
    document.querySelectorAll('[data-view]').forEach(b => b.setAttribute('aria-pressed', b.dataset.view === state.view));
    document.querySelectorAll('[data-mode]').forEach(b => b.setAttribute('aria-pressed', b.dataset.mode === state.mode));
    $('overdue').innerHTML = attention || !past.length ? '' : `<button class="study-overdue" id="past-toggle" aria-expanded="${state.overdue}">${state.overdue ? '▾' : '▸'} ${past.length} PAST-DUE ITEMS · ${state.overdue ? 'HIDE' : 'SHOW'} DATES BEFORE TODAY</button>${state.overdue ? [...new Set(sorted(past).map(r => r.date))].map(day => group(dateLabel(day), past.filter(r => r.date === day))).join('') : ''}`;
    if (attention) {
      const reasons = ['OVERDUE / MY WORK', 'BLOCKED / MY WORK', 'ASSIGNED TO ME', 'DUE REMINDERS / WORKSPACE', 'MENTIONED / SESSION'];
      $('records').innerHTML = reasons.map(reason => {
        const list = records.filter(r => attentionReason(r) === reason);
        return list.length ? group(reason, list) : '';
      }).join('');
    } else if (state.mode === 'agenda') {
      const list = filtered.filter(r => r.date.startsWith(state.month));
      const days = [...new Set(sorted(list).map(r => r.date))];
      $('records').innerHTML = days.length ? days.map(day => group(`${dateLabel(day)}${day === TODAY ? ' / TODAY' : ''}`, list.filter(r => r.date === day))).join('') : '<p class="study-empty">No dated work in this month for these filters.</p>';
    } else {
      $('records').innerHTML = `<div class="study-month"><div class="study-grid">${['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'].map(d => `<div class="study-weekday">${d}</div>`).join('')}${monthDays(state.month).map(day => {
        const list = sorted(filtered.filter(r => r.date === day));
        return `<button class="study-day ${day.startsWith(state.month) ? '' : 'outside'} ${day === state.day ? 'selected' : ''}" data-day="${day}" aria-label="${dateLabel(day)}, ${list.length} items" aria-pressed="${day === state.day}" ${day === TODAY ? 'aria-current="date"' : ''}><b>${Number(day.slice(-2))} ${day === TODAY ? '<em>TODAY</em>' : ''}</b>${list.slice(0, 2).map(r => `<span>${escape(r.title)}</span>`).join('')}<span>${list.length ? `${list.length} ITEMS` : ''}</span></button>`;
      }).join('')}</div><div class="study-day-list">${group(dateLabel(state.day), filtered.filter(r => r.date === state.day))}</div></div>`;
    }
    renderInspector();
  }
  function renderInspector() {
    const r = records.find(r => r.id === state.selected);
    $('inspector').hidden = !r;
    if (!r) return;
    $('inspector').innerHTML = `<header class="panel-header"><div><span>INSPECTOR / ${r.kind}</span><button class="btn btn--danger" id="close" aria-label="Close inspector">×</button></div></header><div class="study-document"><h2>${escape(r.title)}</h2><dl><dt>RECORD</dt><dd>${r.kind === 'TASK' ? '#' : ''}${r.id}</dd><dt>PROJECT</dt><dd>${r.project}</dd>${r.assignee ? `<dt>ASSIGNEE</dt><dd>${r.assignee}</dd>` : ''}<dt>DEADLINE</dt><dd>${r.date ? dateLabel(r.date) : 'NO DATE'} ${r.time}</dd><dt>ATTENTION REASON</dt><dd>${attentionReason(r) || 'Not in your attention register'}</dd></dl>${r.kind !== 'MENTION' ? `<form id="deadline-form"><label for="deadline">EDIT DEADLINE / PROTOTYPE ONLY</label><input id="deadline" type="date" value="${r.date}" required><button class="btn" type="submit">SAVE DATE</button></form>` : ''}<p>Shared record: a date change appears in both views. This study uses in-memory examples, not your workspace.</p></div>`;
  }
  document.addEventListener('click', event => {
    const b = event.target.closest('button');
    if (!b) return;
    if (b.dataset.record) { opener = b.dataset.record; state.selected = b.dataset.record; render(); $('close').focus(); return; }
    if (b.dataset.view) { state.view = b.dataset.view; state.selected = null; }
    else if (b.dataset.mode) { state.mode = b.dataset.mode; state.selected = null; }
    else if (b.dataset.day) { state.day = b.dataset.day; state.selected = null; }
    else if (b.id === 'past-toggle') state.overdue = !state.overdue;
    else if (b.id === 'close') { close(); return; }
    else if (b.id === 'theme') { const dark = document.documentElement.dataset.theme !== 'matte-black'; document.documentElement.dataset.theme = dark ? 'matte-black' : 'lupine'; b.textContent = dark ? 'LIGHT THEME' : 'DARK THEME'; return; }
    else if (b.id === 'today') { state.month = TODAY.slice(0, 7); state.day = TODAY; state.selected = null; }
    else if (b.id === 'prev' || b.id === 'next') {
      const date = new Date(`${state.month}-01T12:00:00Z`);
      date.setUTCMonth(date.getUTCMonth() + (b.id === 'prev' ? -1 : 1));
      state.month = date.toISOString().slice(0, 7); state.day = `${state.month}-01`; state.selected = null;
    } else return;
    const focusId = b.id, day = b.dataset.day;
    render();
    if (focusId) $(focusId)?.focus();
    if (day) document.querySelector(`[data-day="${day}"]`)?.focus();
  });
  function close() { state.selected = null; render(); document.querySelector(`[data-record="${opener}"]`)?.focus(); }
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && state.selected) close(); });
  for (const id of ['person', 'project']) $(id).addEventListener('change', e => { state[id] = e.target.value; state.selected = null; render(); });
  document.addEventListener('submit', e => {
    if (e.target.id !== 'deadline-form') return;
    e.preventDefault();
    const r = records.find(r => r.id === state.selected);
    r.date = $('deadline').value;
    render();
    $('status').textContent = `Updated ${r.id} to ${r.date} · Prototype memory only. Reload resets changes.`;
    $('deadline').focus();
  });
  render();
}
