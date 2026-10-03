import assert from 'node:assert/strict';
import test from 'node:test';
import { JSDOM } from 'jsdom';

import {
  BATCH_LIMITS,
  CAPTURE_BLOCK_SELECTOR,
  KEEPALIVE_MAX_CHARS,
  MAX_ATTEMPTS,
  batchBody,
  batchOutcome,
  batchSize,
  captureRecordOptions,
  createSessionCapture,
  serializeEvent,
} from '../utils/sessionCapture.mjs';

const RECORDING_ID = 41;
const EVENTS_PATH = `/api/session_recordings/${RECORDING_ID}/events`;

function response(status, body = {}) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

// A dashboard API that creates recording RECORDING_ID and answers each batch
// with the next of `batchStatuses` (201 once they run out). `requests` holds
// every call.
function fakeApi({ createStatus = 201, batchStatuses = [] } = {}) {
  const requests = [];
  const statuses = [...batchStatuses];
  const api = async (path, init) => {
    requests.push({ path, init });
    if (path === '/api/session_recordings') {
      return response(createStatus, createStatus < 300 ? { recording: { id: RECORDING_ID } } : { code: 'capture_disabled' });
    }
    const status = statuses.length ? statuses.shift() : 201;
    if (status === 'network') throw new TypeError('Failed to fetch');
    return response(status);
  };
  api.requests = requests;
  api.batches = () => requests.filter((request) => request.path === EVENTS_PATH).map((request) => JSON.parse(request.init.body));
  return api;
}

// An rrweb stand-in: record() emits a full snapshot, and `emit` stands for
// the page changing.
function fakeRecorder() {
  const recorder = { calls: 0, stops: 0, snapshots: 0, options: null };
  const record = (options) => {
    recorder.calls += 1;
    recorder.options = options;
    options.emit({ type: 2, data: { node: 'snapshot' }, timestamp: 1000 });
    return () => { recorder.stops += 1; };
  };
  record.takeFullSnapshot = () => {
    recorder.snapshots += 1;
    recorder.options.emit({ type: 2, data: { node: 'new snapshot' }, timestamp: 3000 });
  };
  recorder.module = { record };
  recorder.emit = (event) => recorder.options.emit(event);
  return recorder;
}

function fakeTimers() {
  const timers = { tick: null, cleared: 0 };
  timers.setInterval = (callback) => { timers.tick = callback; return 7; };
  timers.clearInterval = (id) => { if (id === 7) timers.cleared += 1; };
  return timers;
}

function fakeWindow() {
  const listeners = new Map();
  return {
    listeners,
    addEventListener: (type, listener) => listeners.set(type, listener),
    removeEventListener: (type, listener) => { if (listeners.get(type) === listener) listeners.delete(type); },
  };
}

function capture(overrides = {}) {
  const api = overrides.api || fakeApi();
  const recorder = overrides.recorder || fakeRecorder();
  const timers = fakeTimers();
  const target = fakeWindow();
  const states = [];
  const session = createSessionCapture({
    contextId: 12,
    loadRecorder: overrides.loadRecorder || (async () => recorder.module),
    fetch: api,
    now: () => 5000,
    timers,
    target,
    onStateChange: (state) => states.push(state),
    limits: overrides.limits,
  });
  return { session, api, recorder, timers, target, states };
}

const change = (n) => ({ type: 3, data: { source: 0, texts: [{ id: n, value: `text ${n}` }] }, timestamp: 2000 + n });

test('records with every input masked and secret elements blocked', () => {
  const emit = () => {};
  const options = captureRecordOptions(emit);

  assert.equal(options.emit, emit);
  assert.equal(options.maskAllInputs, true);
  assert.equal(options.blockSelector, CAPTURE_BLOCK_SELECTOR);
});

test('the block selector matches credential elements and the CSRF meta tag, and nothing else', () => {
  const { document } = new JSDOM(`<!doctype html><html><head>
    <meta name="csrf-token" content="t"><meta name="viewport" content="width=device-width">
  </head><body>
    <code data-aa-secret="">aa_key</code><input type="password" data-aa-secret=""><div>Run Agent</div><input>
  </body></html>`).window;

  const blocked = [...document.querySelectorAll(CAPTURE_BLOCK_SELECTOR)].map((element) => element.outerHTML);

  assert.deepEqual(blocked, [
    '<meta name="csrf-token" content="t">',
    '<code data-aa-secret="">aa_key</code>',
    '<input type="password" data-aa-secret="">',
  ]);
});

test('a batch body is the ingest\'s JSON: sent_at and recording_events of kind rrweb', () => {
  const event = { type: 3, data: { source: 2 }, timestamp: 1234 };

  const body = JSON.parse(batchBody([serializeEvent(event)], 5000.7));

  assert.deepEqual(body, { sent_at: 5000, recording_events: [{ kind: 'rrweb', timestamp: 1234, data: event }] });
});

test('a batch holds as many entries as fit the limits, and always one', () => {
  const limits = { events: 3, chars: 25 };

  assert.equal(batchSize(['a'.repeat(10), 'b'.repeat(10), 'c'.repeat(10)], limits), 2);
  assert.equal(batchSize(['a', 'b', 'c', 'd'], limits), 3);
  assert.equal(batchSize(['a'.repeat(100), 'b'], limits), 1);
  assert.equal(batchSize([], limits), 0);
});

test('stays under the ingest\'s default batch caps', () => {
  assert.ok(BATCH_LIMITS.events <= 1000);
  assert.ok(BATCH_LIMITS.chars * 3 < 1024 * 1024);
});

test('reads the server\'s answer to a batch', () => {
  assert.equal(batchOutcome(201), 'sent');
  assert.equal(batchOutcome(403), 'off');
  assert.equal(batchOutcome(413), 'limit');
  assert.equal(batchOutcome(503), 'retry');
  assert.equal(batchOutcome(429), 'retry');
  assert.equal(batchOutcome(422), 'failed');
  assert.equal(batchOutcome(404), 'failed');
});

test('starts the conversation\'s recording, then records the page', async () => {
  const { session, api, recorder, states } = capture();

  await session.start();

  assert.deepEqual(api.requests[0], {
    path: '/api/session_recordings',
    init: { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ agent_context_id: 12 }) },
  });
  assert.equal(recorder.calls, 1);
  assert.equal(recorder.options.maskAllInputs, true);
  assert.deepEqual(states, ['starting', 'recording']);
  assert.equal(session.state, 'recording');
});

test('posts what it recorded on each tick as one text/plain batch', async () => {
  const { session, api, recorder, timers } = capture();
  await session.start();
  recorder.emit(change(1));

  timers.tick();
  await session.flush();

  const [request] = api.requests.filter((item) => item.path === EVENTS_PATH);
  assert.equal(request.init.method, 'POST');
  assert.deepEqual(request.init.headers, { 'Content-Type': 'text/plain' });
  assert.equal(request.init.keepalive, false);
  assert.deepEqual(api.batches(), [{
    sent_at: 5000,
    recording_events: [
      { kind: 'rrweb', timestamp: 1000, data: { type: 2, data: { node: 'snapshot' }, timestamp: 1000 } },
      { kind: 'rrweb', timestamp: 2001, data: change(1) },
    ],
  }]);
});

test('posts at once, in batches within the limits and in order, when the queue fills', async () => {
  const { session, api, recorder } = capture({ limits: { events: 2, chars: 10_000 } });
  await session.start();

  recorder.emit(change(1));
  recorder.emit(change(2));
  recorder.emit(change(3));
  await session.flush();

  assert.deepEqual(api.batches().map((batch) => batch.recording_events.map((entry) => entry.timestamp)), [[1000, 2001], [2002, 2003]]);
});

test('stop() stops the recorder at once, then posts what it holds', async () => {
  const { session, api, recorder, timers, target, states } = capture();
  await session.start();
  recorder.emit(change(1));

  const stopping = session.stop();
  assert.equal(recorder.stops, 1, 'the recorder stops before stop() yields');
  assert.equal(timers.cleared, 1);
  assert.equal(target.listeners.has('pagehide'), false);
  recorder.emit(change(2));
  await stopping;

  assert.deepEqual(api.batches().flatMap((batch) => batch.recording_events.map((entry) => entry.timestamp)), [1000, 2001]);
  assert.equal(api.requests.at(-1).init.keepalive, true);
  assert.deepEqual(states, ['starting', 'recording', 'stopped']);
});

test('a final batch too large for keepalive is sent without it', async () => {
  const { session, api, recorder } = capture();
  await session.start();
  recorder.emit({ type: 3, data: { text: 'x'.repeat(KEEPALIVE_MAX_CHARS) }, timestamp: 2000 });

  await session.stop();

  assert.equal(api.requests.at(-1).init.keepalive, false);
});

test('stopped while the recording is created, it never loads the recorder', async () => {
  let loads = 0;
  const { session, recorder, states } = capture({ loadRecorder: async () => { loads += 1; return fakeRecorder().module; } });

  const starting = session.start();
  await session.stop();
  await starting;

  assert.equal(loads, 0);
  assert.equal(recorder.calls, 0);
  assert.deepEqual(states, ['starting', 'stopped']);
});

test('stopped while the recorder loads, it never records', async () => {
  let release;
  const recorder = fakeRecorder();
  const { session, api } = capture({ recorder, loadRecorder: () => new Promise((resolve) => { release = () => resolve(recorder.module); }) });

  const starting = session.start();
  while (!release) await new Promise((resolve) => setImmediate(resolve));
  await session.stop();
  release();
  await starting;

  assert.equal(recorder.calls, 0);
  assert.equal(api.batches().length, 0);
});

test('records nothing when the host turned capture off', async () => {
  const { session, recorder, states } = capture({ api: fakeApi({ createStatus: 403 }) });

  await session.start();

  assert.equal(recorder.calls, 0);
  assert.deepEqual(states, ['starting', 'off']);
});

test('records nothing when the recording cannot be created or the recorder does not load', async () => {
  const notFound = capture({ api: fakeApi({ createStatus: 404 }) });
  await notFound.session.start();
  assert.deepEqual(notFound.states, ['starting', 'failed']);

  const unloadable = capture({ loadRecorder: async () => { throw new TypeError('Failed to fetch dynamically imported module'); } });
  await unloadable.session.start();
  assert.deepEqual(unloadable.states, ['starting', 'failed']);
});

test('a batch over the recording\'s caps stops the capture', async () => {
  const { session, api, recorder, states } = capture({ api: fakeApi({ batchStatuses: [413] }) });
  await session.start();

  await session.flush();
  recorder.emit(change(1));
  await session.flush();

  assert.equal(recorder.stops, 1);
  assert.equal(api.batches().length, 1);
  assert.deepEqual(states, ['starting', 'recording', 'limit']);
});

test('a refused batch ends the capture as failed', async () => {
  const { session, recorder, states } = capture({ api: fakeApi({ batchStatuses: [422] }) });
  await session.start();

  await session.flush();

  assert.equal(recorder.stops, 1);
  assert.equal(states.at(-1), 'failed');
});

test('a batch that fails in transit is sent again, in order, on the next tick', async () => {
  const { session, api, recorder } = capture({ api: fakeApi({ batchStatuses: ['network', 503] }) });
  await session.start();

  await session.flush();
  recorder.emit(change(1));
  await session.flush();
  await session.flush();

  const sent = api.batches().map((batch) => batch.recording_events.map((entry) => entry.timestamp));
  assert.deepEqual(sent, [[1000], [1000, 2001], [1000, 2001]]);
  assert.equal(session.state, 'recording');
});

test(`after ${MAX_ATTEMPTS} failed sends a batch is dropped with the queue, and a new full snapshot starts over`, async () => {
  const { session, api, recorder } = capture({ api: fakeApi({ batchStatuses: Array(MAX_ATTEMPTS).fill(503) }) });
  await session.start();

  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) await session.flush();
  await session.flush();

  assert.equal(recorder.snapshots, 1);
  assert.deepEqual(api.batches().at(-1).recording_events.map((entry) => entry.data.data.node), ['new snapshot']);
  assert.equal(session.state, 'recording');
});

test('pagehide posts what it holds with keepalive', async () => {
  const { session, api, target } = capture();
  await session.start();

  target.listeners.get('pagehide')();
  await session.flush();

  assert.equal(api.batches().length, 1);
  assert.equal(api.requests.at(-1).init.keepalive, true);
});
