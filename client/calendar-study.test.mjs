import { test } from 'node:test';
import assert from 'node:assert/strict';
import { monthDays, filterRecords, attentionReason } from './design-system/calendar.mjs';

test('month grid is Monday-first across leap years and year boundaries', () => {
  const september = monthDays('2026-09');
  assert.equal(september[0], '2026-08-31');
  assert.equal(september[1], '2026-09-01');
  assert.equal(september.at(-1), '2026-10-04');
  assert.equal(monthDays('2024-02').filter(d => d.startsWith('2024-02')).length, 29);
  assert.equal(monthDays('2026-03').length, 42);
  assert.equal(monthDays('2027-01')[0], '2026-12-28');
});

test('attention reasons do not turn workspace calendar into personal attention', () => {
  const task = { kind: 'TASK', assignee: 'RENE', date: '2026-09-27' };
  assert.equal(attentionReason(task), 'OVERDUE / MY WORK');
  assert.equal(attentionReason({ ...task, date: '2026-09-28' }), 'ASSIGNED TO ME');
  assert.equal(attentionReason({ ...task, assignee: 'ALEX' }), null);
  assert.equal(attentionReason({ ...task, date: '', blocked: true }), 'BLOCKED / MY WORK');
  assert.equal(attentionReason({ kind: 'MENTION', date: '' }), 'MENTIONED / SESSION');
});

test('assignee and project filters intersect and do not invent reminder assignees', () => {
  const records = [
    { id: 1, assignee: 'RENE', project: 'SEARCH' },
    { id: 2, assignee: 'ALEX', project: 'SEARCH' },
    { id: 3, assignee: 'RENE', project: 'PLATFORM' },
    { id: 4, kind: 'REMINDER', assignee: '', project: 'SEARCH' },
  ];
  assert.deepEqual(filterRecords(records, 'RENE', 'SEARCH').map(r => r.id), [1]);
  assert.deepEqual(filterRecords(records, '', 'SEARCH').map(r => r.id), [1, 2, 4]);
  assert.deepEqual(filterRecords(records, 'ALEX', 'PLATFORM'), []);
});
