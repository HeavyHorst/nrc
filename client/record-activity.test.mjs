import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('./record-activity.js', import.meta.url), 'utf8');
function fixture(storage = new Map()) {
  const listeners = new Map(), observers = [];
  const addEventListener = (name, fn) => { if (!listeners.has(name)) listeners.set(name, new Set()); listeners.get(name).add(fn); };
  const removeEventListener = (name, fn) => listeners.get(name)?.delete(fn);
  const dispatchEvent = event => { for (const fn of listeners.get(event.type) || []) fn(event); };
  const document = { addEventListener, removeEventListener, dispatchEvent, visibilityState: 'visible', focused: true,
    hasFocus() { return this.focused; }, getElementById: () => null,
    createElement: () => ({ setAttribute() {}, style: {}, remove() {} }) };
  const records = [
    { assetId: 10n, parentType: 1, parentId: 1n, owner: 'alex' },
    { assetId: 11n, parentType: 1, parentId: 1n, owner: 'rene' },
    { assetId: 12n, parentType: 1, parentId: 2n, owner: 'alex' },
    { assetId: 13n, parentType: 1, parentId: 1n, owner: 'mara' },
  ];
  const tasks = [{ id: 1n, assignee: 'rene', title: 'Assigned' }, { id: 2n, assignee: 'mara', title: 'Other' }];
  const window = { addEventListener, removeEventListener,
    localStorage: { getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value),
      get length() { return storage.size; }, key: i => [...storage.keys()][i] },
    NRCAssets: { requestAllAssets: async () => ({ assets: records }) },
    NRCTasks: { requestTasksByIds: async () => tasks } };
  const context = vm.createContext({ window, document, myNickname: 'rene', currentWorkspaceId: 'alpha',
    CustomEvent: class { constructor(type) { this.type = type; } },
    IntersectionObserver: class { constructor(callback) { this.callback = callback; observers.push(this); } observe(target) { this.target = target; } disconnect() {} } });
  vm.runInContext(source, context);
  return { api: window.NRCRecordActivity, document, window, records, tasks, context, observers, storage,
    event: (type, detail) => dispatchEvent({ type, detail }),
    visible: () => { const io = observers.at(-1); io.callback([{ target: io.target, isIntersecting: true }]); } };
}

test('assigned comments exclude own writes; read cursors survive reload without crossing workspace/user boundaries', async () => {
  const f = fixture(); await f.api.refresh();
  assert.deepEqual(Array.from(f.api.snapshot(), s => [s.task.id, s.count, s.first.assetId]), [[1n, 2, 10n]]);
  f.api.markRead('task', 1n, 10n);
  assert.equal(f.api.snapshot()[0].count, 1);
  f.api.markRead('task', 1n, 9n); // A stale tab cannot move the cursor backwards.
  assert.equal(f.api.cursor('task', 1n), 10n);
  const reloaded = fixture(f.storage); await reloaded.api.refresh();
  assert.equal(reloaded.api.snapshot()[0].first.assetId, 13n);
  assert.equal(reloaded.api.cursors('task')['1'], '10');
  assert.equal(Object.keys(reloaded.api.cursors('ticket')).length, 0);
  reloaded.context.currentWorkspaceId = 'beta';
  assert.equal(reloaded.api.cursor('task', 1n), 0n);
  assert.equal(Object.keys(reloaded.api.cursors('task')).length, 0);
  reloaded.context.currentWorkspaceId = 'alpha'; reloaded.context.myNickname = 'alex';
  assert.equal(reloaded.api.cursor('task', 1n), 0n);
  f.event('nrc:task-changed', { task: { id: 2n, assignee: 'rene', title: 'Reassigned' }, reason: 'updated' });
  assert.equal(f.api.snapshot().length, 2);
  f.event('nrc:task-changed', { task: { id: 1n, status: 2 }, reason: 'moved' });
  assert.equal(f.api.snapshot().length, 2, 'partial status events retain the assignee');
  f.event('nrc:task-changed', { task: { id: 1n }, reason: 'deleted' });
  assert.equal(f.api.snapshot().length, 1);
});

test('only a visible message end in a focused tab acknowledges the captured record', () => {
  const f = fixture(), node = { isConnected: true, rendered: false, getClientRects() { return this.rendered ? [{}] : []; }, appendChild() {} };
  f.api.observe('task', node, 'task', 1n, 13n);
  f.visible(); assert.equal(f.api.cursor('task', 1n), 0n);
  node.rendered = true; f.document.focused = false;
  f.visible(); assert.equal(f.api.cursor('task', 1n), 0n);
  f.document.focused = true; f.document.visibilityState = 'hidden';
  f.visible(); assert.equal(f.api.cursor('task', 1n), 0n);
  f.document.visibilityState = 'visible'; f.event('focus');
  assert.equal(f.api.cursor('task', 1n), 13n);
  f.api.observe('task', node, 'task', 1n, 19n);
  f.context.currentWorkspaceId = 'beta'; f.visible();
  assert.equal(f.api.cursor('task', 1n), 0n, 'an old observer cannot mark the next workspace read');
});

test('a snapshot completing after disconnect cannot resurrect old-workspace notifications', async () => {
  const f = fixture(); let complete;
  f.window.NRCAssets.requestAllAssets = () => new Promise(resolve => { complete = resolve; });
  const pending = f.api.refresh(); f.api.disconnect();
  f.context.currentWorkspaceId = 'beta';
  complete({ assets: f.records }); await pending;
  assert.equal(f.api.snapshot().length, 0);
});

test('assignment changes during a parent read invalidate the captured projection', async () => {
  const f = fixture(); await f.api.refresh();
  let complete;
  f.window.NRCTasks.requestTasksByIds = () => {
    const captured = f.tasks.map(task => ({ ...task }));
    f.window.NRCTasks.requestTasksByIds = async () => f.tasks;
    return new Promise(resolve => { complete = () => resolve(captured); });
  };
  const pending = f.api.refresh(); await new Promise(resolve => setImmediate(resolve));
  f.tasks[0] = { ...f.tasks[0], assignee: 'mara' };
  f.event('nrc:task-changed', { task: f.tasks[0], reason: 'updated' });
  complete(); await pending; await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.api.snapshot().length, 0, 'the old assignee must not overwrite a live reassignment');
});

test('a mounted message observer resumes after reconnect without acknowledging unseen newer content', async () => {
  const f = fixture(), node = { isConnected: true, getClientRects: () => [{}], appendChild() {} };
  f.api.observe('task', node, 'task', 1n, 10n);
  f.api.disconnect(); f.visible();
  assert.equal(f.api.cursor('task', 1n), 0n, 'offline visibility is not acknowledged');
  await f.api.refresh();
  assert.equal(f.api.cursor('task', 1n), 10n);
  assert.equal(f.api.snapshot()[0].first.assetId, 13n, 'newer loaded but unrendered comments remain unread');
});
