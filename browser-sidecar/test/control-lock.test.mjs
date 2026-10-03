import assert from 'node:assert/strict';
import test from 'node:test';

import { ControlLock, changesPage } from '../lib/control-lock.mjs';

const ada = { id: '1', name: 'Ada' };
const grace = { id: '2', name: 'Grace' };
const nobody = { id: null, name: null };

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function recorded(lock) {
  const changes = [];
  lock.on('change', (holder, previous, reason) => changes.push([holder?.user.name ?? null, previous?.user.name ?? null, reason]));
  return changes;
}

test('tells the tools that change the page from those that only look', () => {
  for (const name of ['browser_navigate', 'browser_click', 'browser_type', 'browser_evaluate', 'browser_press_key', 'browser_file_upload']) {
    assert.equal(changesPage(name, {}), true, name);
  }
  for (const name of ['browser_snapshot', 'browser_take_screenshot', 'browser_console_messages', 'browser_network_requests', 'browser_wait_for']) {
    assert.equal(changesPage(name, {}), false, name);
  }
  assert.equal(changesPage('browser_tabs', { action: 'list' }), false);
  assert.equal(changesPage('browser_tabs', { action: 'select', index: 1 }), true);
  assert.equal(changesPage('a_tool_added_later', undefined), true, 'an unknown tool is taken to change the page');
});

test('one person holds control at a time', () => {
  const lock = new ControlLock();
  const changes = recorded(lock);

  assert.equal(lock.acquire('a1', ada).taken, true);
  const refused = lock.acquire('g1', grace);
  assert.equal(refused.taken, false);
  assert.equal(refused.holder.user.name, 'Ada');
  assert.equal(lock.release('g1'), false, 'only the holder can hand back');

  assert.equal(lock.release('a1'), true);
  assert.equal(lock.acquire('g1', grace).taken, true);
  assert.deepEqual(changes, [['Ada', null, 'taken'], [null, 'Ada', 'handed_back'], ['Grace', null, 'taken']]);
});

test('a person moves control between their own connections, and nobody else can take it', () => {
  const lock = new ControlLock();
  const changes = recorded(lock);
  lock.acquire('a1', ada);
  const since = lock.holder.since;

  assert.equal(lock.acquire('a2', ada).taken, true);
  assert.equal(lock.holder.key, 'a2');
  assert.equal(lock.holder.since, since, 'it is the same takeover');
  assert.deepEqual(changes.at(-1), ['Ada', 'Ada', 'moved']);

  lock.release('a2');
  lock.acquire('n1', nobody);
  assert.equal(lock.acquire('n2', nobody).taken, false, 'connections without a user are told apart by connection');
});

test('control held by a connection that dropped is released after the grace period', async () => {
  const lock = new ControlLock({ graceMs: 30 });
  const changes = recorded(lock);
  lock.acquire('a1', ada);

  lock.disconnected('g1');
  lock.disconnected('a1');
  assert.equal(lock.holder.key, 'a1', 'it is kept during the grace period');
  await sleep(60);

  assert.equal(lock.holder, null);
  assert.deepEqual(changes.at(-1), [null, 'Ada', 'disconnected']);
});

test('taking control back from another connection within the grace period keeps it', async () => {
  const lock = new ControlLock({ graceMs: 30 });
  lock.acquire('a1', ada);
  lock.disconnected('a1');
  lock.acquire('a2', ada);
  await sleep(60);

  assert.equal(lock.holder?.key, 'a2');
});

test('an agent call goes ahead at once when nobody holds control, or when it only looks', async () => {
  const lock = new ControlLock();
  assert.equal(await lock.admit('browser_click', {}, 1000), null);

  lock.acquire('a1', ada);
  assert.equal(await lock.admit('browser_snapshot', {}, 1000), null);
});

test('an agent call that changes the page waits for control to be handed back', async () => {
  const lock = new ControlLock();
  const events = [];
  lock.on('agent_waiting', (wait) => events.push(['waiting', wait.tool]));
  lock.on('agent_done', (done) => events.push(['done', done.admitted]));
  lock.acquire('a1', ada);

  const admitted = lock.admit('browser_click', { target: 'e5' }, 1000);
  await sleep(10);
  assert.equal(lock.agentWaiting.tool, 'browser_click');
  lock.release('a1');

  assert.equal(await admitted, null);
  assert.equal(lock.agentWaiting, null);
  assert.deepEqual(events, [['waiting', 'browser_click'], ['done', true]]);
});

test('an agent call is refused, naming who drives, when control is not handed back in time', async () => {
  const lock = new ControlLock();
  lock.acquire('a1', ada);

  const refused = await lock.admit('browser_navigate', { url: '/' }, 30);
  assert.equal(refused.user.name, 'Ada');
  assert.equal(await lock.admit('browser_navigate', { url: '/' }, 0), lock.holder, 'with no wait it is refused at once');
});

test('an agent call keeps waiting when control is taken again as it is handed back', async () => {
  const lock = new ControlLock();
  lock.acquire('a1', ada);
  const admitted = lock.admit('browser_click', {}, 60);
  await sleep(5);
  lock.on('change', (holder) => {
    if (!holder) lock.acquire('g1', grace);
  });
  lock.release('a1');

  assert.equal((await admitted)?.user.name, 'Grace');
});

test('closing refuses the calls still waiting and releases control', async () => {
  const lock = new ControlLock();
  const changes = recorded(lock);
  lock.acquire('a1', ada);
  const waiting = lock.admit('browser_click', {}, 5000);
  await sleep(5);

  lock.close();

  assert.equal((await waiting)?.user.name, 'Ada');
  assert.equal(lock.holder, null);
  assert.deepEqual(changes.at(-1), [null, 'Ada', 'closed']);
  assert.equal(lock.acquire('a1', ada).taken, false, 'nobody takes control of a closed browser');
});
