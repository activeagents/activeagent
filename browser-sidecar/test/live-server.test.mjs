import assert from 'node:assert/strict';
import test from 'node:test';

import { WebSocket } from 'ws';

import { ControlLock } from '../lib/control-lock.mjs';
import { acceptedHosts } from '../lib/guard.mjs';
import { createHttpServer } from '../lib/http-server.mjs';
import { CLOSE_CODES, LiveServer } from '../lib/live-server.mjs';
import { TicketVerifier, signTicket, ticketKey } from '../lib/live-ticket.mjs';

const TOKEN = 'browser-token-0123456789abcdef0123456789';
const SESSION = 'session-1';
const DASHBOARD = 'http://localhost:3000';
const TYPED = 'typed-by-a-person';
let issued = 0;

function ticket({ mode = 'view', sub = '1', name = 'Ada', sid = SESSION, lifetime = 30, issuedAgo = 0 } = {}) {
  const iat = Math.floor(Date.now() / 1000) - issuedAgo;
  issued += 1;
  return signTicket(ticketKey(TOKEN), { v: 1, sid, sub, name, mode, iat, exp: iat + lifetime, jti: `ticket-${issued}-0123456789` });
}

// Stands in for the Screencast: one still frame, and the commands sent to it.
class FakeScreencast {
  constructor() {
    this.lastFrame = { data: 'ZnJhbWUtMQ==', metadata: { deviceWidth: 1280, deviceHeight: 800 } };
    this.pageInfo = { url: 'http://127.0.0.1:4100/orders', tab: 1, tabs: 1 };
    this.streaming = false;
    this.dispatched = [];
  }

  get metadata() {
    return this.lastFrame.metadata;
  }

  async start() {
    this.streaming = true;
  }

  async stop() {
    this.streaming = false;
  }

  async dispatch(method, params) {
    this.dispatched.push([method, params]);
  }
}

async function start(t, { graceMs = 10_000, authTimeoutMs = 2000, maxConnections } = {}) {
  const screencast = new FakeScreencast();
  const lock = new ControlLock({ graceMs });
  const markers = [];
  const logs = [];
  const live = new LiveServer({
    verifier: new TicketVerifier({ key: ticketKey(TOKEN), sessionId: SESSION }),
    lock, screencast, authTimeoutMs, maxConnections,
    onMarker: (marker) => markers.push(marker),
    log: (line) => logs.push(line),
  });
  let hosts = new Set();
  const server = createHttpServer({ rules: () => ({ token: TOKEN, hosts, liveOrigins: new Set([DASHBOARD]) }), gateway: {}, version: '1', live });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  hosts = acceptedHosts('127.0.0.1', port);
  t.after(() => {
    live.close();
    server.close();
  });
  return { port, live, lock, screencast, markers, logs };
}

// A viewer's connection, keeping every message it is sent.
function connect(port, { origin = DASHBOARD, path = '/live', headers = {} } = {}) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`, { origin, headers });
  const client = { ws, messages: [], refused: null };
  ws.on('message', (data) => client.messages.push(JSON.parse(data.toString())));
  client.closed = new Promise((resolve) => ws.on('close', (code, reason) => resolve({ code, reason: reason.toString() })));
  client.opened = new Promise((resolve) => {
    ws.on('open', () => resolve(true));
    ws.on('unexpected-response', (_request, response) => {
      client.refused = response.statusCode;
      ws.terminate();
      resolve(false);
    });
    ws.on('error', () => resolve(false));
  });
  client.send = (message) => ws.send(typeof message === 'string' ? message : JSON.stringify(message));
  return client;
}

async function until(check, label = 'the condition') {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const value = check();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${label}`);
}

function message(client, type, predicate = () => true) {
  return until(() => client.messages.findLast((received) => received.type === type && predicate(received)), `a ${type} message`);
}

async function viewer(port, options) {
  const client = connect(port);
  assert.equal(await client.opened, true);
  client.send({ type: 'auth', ticket: ticket(options) });
  await message(client, 'ready');
  return client;
}

// Asks to take control with a fresh control ticket for `user` (Ada by default).
function takeControl(client, user = {}) {
  client.send({ type: 'take_control', ticket: ticket({ ...user, mode: 'control' }) });
}

test('the live view is refused from another origin, without one, through a foreign Host, or with a ticket in the URL', async (t) => {
  const { port } = await start(t);

  for (const [options, status] of [
    [{ origin: 'http://attacker.test' }, 403],
    [{ origin: '' }, 403],
    [{ headers: { host: `attacker.test:${port}` } }, 403],
    [{ path: `/live?ticket=${ticket()}` }, 400],
    [{ path: '/mcp' }, 403],
  ]) {
    const client = connect(port, options);
    assert.equal(await client.opened, false, JSON.stringify(options));
    assert.equal(client.refused, status, JSON.stringify(options));
  }
});

test('a connection whose first message is not a valid ticket is closed before anything is sent', async (t) => {
  const { port } = await start(t);
  const reused = ticket();
  const first = connect(port);
  await first.opened;
  first.send({ type: 'auth', ticket: reused });
  await message(first, 'ready');

  for (const opening of [
    { type: 'take_control' },
    'not json',
    { type: 'auth', ticket: 'not.a-ticket' },
    { type: 'auth', ticket: ticket({ issuedAgo: 40 }) },
    { type: 'auth', ticket: ticket({ sid: 'another-session' }) },
    { type: 'auth', ticket: reused },
    Buffer.from('binary'),
  ]) {
    const client = connect(port);
    assert.equal(await client.opened, true);
    client.ws.send(opening instanceof Buffer ? opening : typeof opening === 'string' ? opening : JSON.stringify(opening));
    const { code } = await client.closed;
    assert.equal(code, CLOSE_CODES.unauthorized, JSON.stringify(opening));
    assert.deepEqual(client.messages, [], 'nothing was sent before closing');
  }
});

test('a connection that sends no ticket in time is closed', async (t) => {
  const { port } = await start(t, { authTimeoutMs: 50 });
  const client = connect(port);
  await client.opened;

  assert.equal((await client.closed).code, CLOSE_CODES.authTimeout);
  assert.deepEqual(client.messages, []);
});

test('a viewer is told the state and sent the last frame, then every frame, while it watches', async (t) => {
  const { port, live, screencast } = await start(t);
  const client = await viewer(port);

  assert.deepEqual(client.messages[0], {
    type: 'ready',
    control: { held: false, mine: false, yours: false, by: null, since: null },
    agent: { waiting: false, tool: null, since: null },
    page: { url: 'http://127.0.0.1:4100/orders', tab: 1, tabs: 1 },
  });
  assert.deepEqual(await message(client, 'frame'), { type: 'frame', data: 'ZnJhbWUtMQ==', width: 1280, height: 800 });
  assert.equal(screencast.streaming, true);

  live.frame({ data: 'ZnJhbWUtMg==', metadata: { deviceWidth: 1024, deviceHeight: 768 } });
  assert.equal((await message(client, 'frame', (frame) => frame.data === 'ZnJhbWUtMg==')).width, 1024);

  screencast.pageInfo = { url: 'http://127.0.0.1:4100/new', tab: 2, tabs: 2 };
  live.pageChanged();
  assert.deepEqual((await message(client, 'page')).page, { url: 'http://127.0.0.1:4100/new', tab: 2, tabs: 2 });

  client.ws.close();
  await until(() => !screencast.streaming, 'the stream to stop once nobody watches');
});

test('a viewer without a control ticket of its own user can neither take control nor send input', async (t) => {
  const { port, lock, screencast } = await start(t);
  const client = await viewer(port, { mode: 'control' });

  client.send({ type: 'take_control' });
  assert.equal((await message(client, 'error')).code, 'view_only', 'a control ticket used to connect does not take control');
  client.send({ type: 'mouse', action: 'down', x: 0.5, y: 0.5 });
  client.send({ type: 'take_control', ticket: ticket({ mode: 'view' }) });
  takeControl(client, { sub: '2', name: 'Grace' });
  await until(() => client.messages.filter((received) => received.type === 'error').length === 3, 'three refusals');

  assert.equal(lock.holder, null, "neither a view ticket nor another user's control ticket takes control");
  assert.deepEqual(screencast.dispatched, []);
});

test('a watching viewer takes control with a control ticket of its own user', async (t) => {
  const { port, lock } = await start(t);
  const client = await viewer(port, { mode: 'view' });

  takeControl(client);

  assert.equal((await message(client, 'control')).mine, true);
  assert.equal(lock.holder.user.name, 'Ada');
});

test('taking control again after handing it back needs a new control ticket', async (t) => {
  const { port, lock } = await start(t);
  const client = await viewer(port);
  const used = ticket({ mode: 'control' });
  client.send({ type: 'take_control', ticket: used });
  await message(client, 'control', (state) => state.mine);
  client.send({ type: 'hand_back' });
  await message(client, 'control', (state) => !state.held);

  client.send({ type: 'take_control' });
  client.send({ type: 'take_control', ticket: used });
  await until(() => client.messages.filter((received) => received.type === 'error').length === 2, 'two refusals');
  assert.equal(lock.holder, null, 'neither no ticket nor a used one takes control');

  takeControl(client);
  const controls = await until(() => {
    const received = client.messages.filter(({ type }) => type === 'control');
    return received.length === 3 && received;
  }, 'control to be taken again');
  assert.equal(controls.at(-1).mine, true);
});

test('the person who takes control drives the browser, and everyone else sees who it is', async (t) => {
  const { port, screencast, markers, logs } = await start(t);
  const ada = await viewer(port, { sub: '1', name: 'Ada' });
  const grace = await viewer(port, { sub: '2', name: 'Grace' });

  takeControl(ada);
  assert.equal((await message(ada, 'control')).mine, true);
  const seen = await message(grace, 'control');
  assert.equal(seen.held, true);
  assert.equal(seen.by, 'Ada');
  assert.equal(seen.mine, false);
  assert.equal(seen.yours, false);

  takeControl(grace, { sub: '2', name: 'Grace' });
  assert.match((await message(grace, 'error')).message, /Ada is driving the browser/);

  grace.send({ type: 'mouse', action: 'down', x: 0.1, y: 0.1 });
  ada.send({ type: 'mouse', action: 'down', x: 0.5, y: 0.25, button: 'left', clickCount: 1 });
  ada.send({ type: 'text', text: TYPED });
  await until(() => screencast.dispatched.length === 2, 'the relayed input');
  assert.deepEqual(screencast.dispatched, [
    ['Input.dispatchMouseEvent', { type: 'mousePressed', x: 640, y: 200, button: 'left', modifiers: 0, clickCount: 1 }],
    ['Input.insertText', { text: TYPED }],
  ]);

  ada.send({ type: 'hand_back' });
  assert.equal((await message(grace, 'control', (state) => !state.held)).by, null);

  assert.deepEqual(markers.map(({ label, source, user, reason }) => ({ label, source, user, reason })), [
    { label: 'takeover_started', source: 'human', user: { id: '1', name: 'Ada' }, reason: undefined },
    { label: 'takeover_ended', source: 'human', user: { id: '1', name: 'Ada' }, reason: 'handed_back' },
  ]);
  assert.ok(!JSON.stringify([markers, logs]).includes(TYPED), 'relayed input is neither recorded nor logged');
});

test("a holder's other connection is told control is theirs, and may move it to itself", async (t) => {
  const { port, live, lock, markers } = await start(t, { graceMs: 5000 });
  const first = await viewer(port);
  takeControl(first);
  await message(first, 'control', (state) => state.mine);
  first.ws.close();
  await until(() => live.viewers.size === 0, 'the first connection to close');

  const again = await viewer(port);
  assert.deepEqual(again.messages[0].control, { held: true, mine: false, yours: true, by: 'Ada', since: lock.holder.since });
  const grace = await viewer(port, { sub: '2', name: 'Grace' });
  assert.equal(grace.messages[0].control.yours, false);

  takeControl(again);
  const moved = await message(again, 'control', (state) => state.mine);
  assert.equal(moved.yours, true);
  assert.deepEqual(markers.map(({ label }) => label), ['takeover_started'], 'moving control between connections is no new takeover');
});

test('control is released after the grace period when its holder disconnects', async (t) => {
  const { port, markers } = await start(t, { graceMs: 50 });
  const ada = await viewer(port);
  const grace = await viewer(port, { sub: '2', name: 'Grace' });
  takeControl(ada);
  await message(grace, 'control', (state) => state.held);

  ada.ws.close();

  await message(grace, 'control', (state) => !state.held);
  assert.equal(markers.at(-1).reason, 'disconnected');
});

test('viewers see when an agent is waiting for control to be handed back', async (t) => {
  const { port, lock } = await start(t);
  const ada = await viewer(port);
  takeControl(ada);
  await message(ada, 'control', (state) => state.mine);

  const admitted = lock.admit('browser_click', { target: 'e3' }, 5000);
  assert.equal((await message(ada, 'agent', (state) => state.waiting)).tool, 'browser_click');
  ada.send({ type: 'hand_back' });

  assert.equal(await admitted, null);
  await message(ada, 'agent', (state) => !state.waiting);
});

test('closing ends every connection and releases control', async (t) => {
  const { port, live, markers } = await start(t);
  const ada = await viewer(port);
  const pending = connect(port);
  await pending.opened;
  takeControl(ada);
  await message(ada, 'control', (state) => state.mine);

  live.close();

  assert.equal((await ada.closed).code, CLOSE_CODES.stopping);
  assert.equal((await pending.closed).code, CLOSE_CODES.stopping);
  assert.equal(markers.at(-1).reason, 'closed');
});

test('connections past the limit are turned away', async (t) => {
  const { port } = await start(t, { maxConnections: 1 });
  await viewer(port);

  const extra = connect(port);
  await extra.opened;
  assert.equal((await extra.closed).code, CLOSE_CODES.full);
});
