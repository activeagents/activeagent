import assert from 'node:assert/strict';
import test from 'node:test';

import { entryFailed, entrySummary, loadRrwebEvents, recordingEventsPath, rrwebEvents } from '../utils/replayEntries.mjs';

test('summarizes each lane in one line', () => {
  assert.equal(entrySummary({ lane: 'message', role: 'user', content: 'Where is\n my order?' }), 'user: Where is my order?');
  assert.equal(entrySummary({ lane: 'message', role: 'assistant', content: '', tool_calls: [{ name: 'lookup_order' }, { function: { name: 'notify' } }] }),
    'assistant called lookup_order, notify');
  assert.equal(entrySummary({ lane: 'message', role: 'tool', tool_name: 'lookup_order', content: 'Shipped' }), 'lookup_order result: Shipped');
  assert.equal(entrySummary({ lane: 'llm', model: 'gpt-4o-mini', tokens: { input: 120, output: 30 } }), 'gpt-4o-mini · 120 in / 30 out');
  assert.equal(entrySummary({ lane: 'llm', name: 'llm.generate' }), 'llm.generate');
  assert.equal(entrySummary({ lane: 'tool', name: 'browser_click', error: true }), 'browser_click (failed)');
  assert.equal(entrySummary({ lane: 'browser', kind: 'action', data: { tool_name: 'browser_navigate' } }), 'browser_navigate');
  assert.equal(entrySummary({ lane: 'browser', kind: 'action', data: { action_type: 'click' } }), 'click');
  assert.equal(entrySummary({ lane: 'browser', kind: 'console', data: { level: 'error', message: 'boom' } }), 'console error: boom');
  assert.equal(entrySummary({ lane: 'browser', kind: 'marker', data: { label: 'checkout' } }), 'marker: checkout');
  assert.equal(entrySummary(null), '');
});

test('clips a long message to one excerpt', () => {
  const summary = entrySummary({ lane: 'message', role: 'assistant', content: 'x'.repeat(500) });

  assert.equal(summary.length, 'assistant: '.length + 140);
  assert.ok(summary.endsWith('…'));
});

test('an entry failed when it says so', () => {
  assert.equal(entryFailed({ error: true }), true);
  assert.equal(entryFailed({ status: 'ERROR' }), true);
  assert.equal(entryFailed({ status: 'error' }), true);
  assert.equal(entryFailed({ status: 'OK', error: false }), false);
  assert.equal(entryFailed(null), false);
});

const ROWS = [
  { id: 1, kind: 'rrweb', events: [{ at: 2000, data: { type: 3, data: { source: 2 }, timestamp: 1 } }, { at: 1000, data: { type: 4, data: {} } }] },
  { id: 2, kind: 'console', events: [{ at: 1500, data: { level: 'log' } }] },
  { id: 3, kind: 'rrweb', events: [{ at: 'soon', data: { type: 3 } }, { at: 2500, data: null }, { at: 3000, data: { type: 2, data: {} } }] },
];

test('reads rrweb events in time order, stamped with the time they were stored at', () => {
  assert.deepEqual(rrwebEvents(ROWS), [
    { type: 4, data: {}, timestamp: 1000 },
    { type: 3, data: { source: 2 }, timestamp: 2000 },
    { type: 2, data: {}, timestamp: 3000 },
  ]);
  assert.deepEqual(rrwebEvents(), []);
});

test('pages through the events endpoint for rrweb only', () => {
  assert.equal(recordingEventsPath(7), '/api/session_recordings/7/events?kind=rrweb&limit=50');
  assert.equal(recordingEventsPath(7, 41, 20), '/api/session_recordings/7/events?kind=rrweb&limit=20&after=41');
});

test('reads every page and hands each page of events on', async () => {
  const pages = {
    '/api/session_recordings/7/events?kind=rrweb&limit=50': { events: [ROWS[0]], has_more: true, next_after: 1 },
    '/api/session_recordings/7/events?kind=rrweb&limit=50&after=1': { events: [ROWS[2]], has_more: false, next_after: 3 },
  };
  const received = [];

  const result = await loadRrwebEvents(7, {
    fetchPage: async (path) => pages[path],
    onEvents: (events, first) => received.push([events.length, first]),
  });

  assert.deepEqual(result, { count: 3, truncated: false });
  assert.deepEqual(received, [[2, true], [1, false]]);
});

test('stops at the event cap, and when cancelled', async () => {
  let calls = 0;
  const fetchPage = async () => {
    calls += 1;
    return { events: [ROWS[0]], has_more: true, next_after: calls };
  };

  assert.deepEqual(await loadRrwebEvents(7, { fetchPage, onEvents: () => {}, maxEvents: 3 }), { count: 4, truncated: true });
  assert.equal(calls, 2);

  let cancelled = false;
  const result = await loadRrwebEvents(7, {
    fetchPage: async () => { cancelled = true; return { events: [ROWS[0]], has_more: true, next_after: 1 }; },
    onEvents: () => assert.fail('nothing is handed on after cancelling'),
    isCancelled: () => cancelled,
  });
  assert.deepEqual(result, { count: 0, truncated: false });
});
