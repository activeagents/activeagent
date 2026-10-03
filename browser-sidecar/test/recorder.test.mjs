import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';
import { gunzipSync } from 'node:zlib';

import { EventBatcher, initScript, Recorder, rrwebSource, Uploader } from '../lib/recorder.mjs';

function collect(options = {}) {
  const batches = [];
  const batcher = new EventBatcher({
    maxEvents: 3, maxBytes: 4096, flushMs: 10_000, now: () => 1767225600000,
    onBatch: (body, count) => batches.push({ body: JSON.parse(body), count }),
    ...options,
  });
  return { batcher, batches };
}

test('a batch holds at most the configured number of events', () => {
  const { batcher, batches } = collect();
  for (let index = 0; index < 7; index += 1) batcher.add({ kind: 'marker', timestamp: index, data: { index } });
  batcher.flush();

  assert.deepEqual(batches.map((batch) => batch.count), [3, 3, 1]);
  assert.equal(batches[0].body.sent_at, 1767225600000);
  assert.deepEqual(batches[0].body.recording_events[0], { kind: 'marker', timestamp: 0, data: { index: 0 } });
});

test('a batch stays under the byte limit, and an event too large for any batch is dropped', () => {
  const dropped = [];
  const { batcher, batches } = collect({ maxEvents: 100, maxBytes: 1024 + 700, onDrop: (event) => dropped.push(event) });
  const text = 'x'.repeat(300);
  for (let index = 0; index < 4; index += 1) batcher.add({ kind: 'rrweb', timestamp: index, data: { text } });
  batcher.add({ kind: 'rrweb', timestamp: 9, data: { text: 'y'.repeat(2000) } });
  batcher.flush();

  assert.deepEqual(batches.map((batch) => batch.count), [2, 2]);
  assert.equal(dropped.length, 1);
});

test('a batch is flushed on its own after the interval', async () => {
  const { batcher, batches } = collect({ flushMs: 5 });
  batcher.add({ kind: 'marker', timestamp: 1, data: {} });
  await new Promise((resolve) => setTimeout(resolve, 30));

  assert.equal(batches.length, 1);
});

async function ingest(statuses) {
  const received = [];
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      received.push({ headers: request.headers, body: JSON.parse(gunzipSync(Buffer.concat(chunks)).toString()) });
      response.writeHead(statuses.shift() ?? 201);
      response.end('{}');
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { server, received, url: `http://127.0.0.1:${server.address().port}/events` };
}

const body = (index) => JSON.stringify({ sent_at: 1, recording_events: [{ kind: 'marker', timestamp: 1, data: { index } }] });

test('batches are posted gzipped with the recording token, in order', async (t) => {
  const { server, received, url } = await ingest([]);
  t.after(() => server.close());
  const uploader = new Uploader({ url, token: 'recording-token-0123456789abcdef' });

  uploader.enqueue(body(1), 1);
  uploader.enqueue(body(2), 1);
  await uploader.drain(2000);

  assert.deepEqual(received.map((request) => request.body.recording_events[0].data.index), [1, 2]);
  assert.equal(received[0].headers.authorization, 'Bearer recording-token-0123456789abcdef');
  assert.equal(received[0].headers['content-encoding'], 'gzip');
  assert.equal(received[0].headers['content-type'], 'application/json');
});

test('a refused batch is dropped, a failed one retried, and a refused token stops the uploads', async (t) => {
  const { server, received, url } = await ingest([413, 503, 201, 401]);
  t.after(() => server.close());
  const messages = [];
  const uploader = new Uploader({ url, token: 'recording-token-0123456789abcdef', backoffMs: 1, log: (message) => messages.push(message) });

  uploader.enqueue(body(1), 1);
  uploader.enqueue(body(2), 1);
  uploader.enqueue(body(3), 1);
  await uploader.drain(2000);
  uploader.enqueue(body(4), 1);
  await uploader.drain(200);

  assert.deepEqual(received.map((request) => request.body.recording_events[0].data.index), [1, 2, 2, 3]);
  assert.equal(uploader.stopped, true);
  assert.equal(uploader.dropped, 3);
  assert.ok(messages.some((message) => message.includes('refused the recording token')));
  assert.ok(messages.every((message) => !message.includes('recording-token-0123456789abcdef')));
});

test('only a main frame\'s well-formed rrweb events are kept', () => {
  const recorder = new Recorder({ recording: { url: 'http://127.0.0.1:1/events', token: 't'.repeat(32), batchEvents: 100, batchBytes: 100_000 } });
  const kept = [];
  recorder.batcher.add = (event) => kept.push(event);
  const mainFrame = {};
  const page = { mainFrame: () => mainFrame };

  const events = [{ type: 2, timestamp: 10, data: {} }, { type: 'x', timestamp: 11 }, { type: 3 }, null];
  recorder.receive({ page, frame: mainFrame }, JSON.stringify(events));
  recorder.receive({ page, frame: {} }, JSON.stringify(events));
  recorder.receive({ page, frame: mainFrame }, '{not json');
  recorder.receive({ page, frame: mainFrame }, { type: 2 });

  assert.deepEqual(kept, [{ kind: 'rrweb', timestamp: 10, data: { type: 2, timestamp: 10, data: {}, tab: 1 } }]);
});

test('the init script records with masked inputs and defines no global of its own', () => {
  const script = initScript({ binding: '__aa_test', rrweb: rrwebSource() });

  assert.match(script, /maskAllInputs: true/);
  assert.match(script, /window\["__aa_test"\]/);
  assert.match(script, /var module = \{ exports: \{\} \};/);
});
