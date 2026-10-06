import assert from 'node:assert/strict';
import test from 'node:test';

import {
  axisGaps,
  axisStretchAt,
  axisToTime,
  browserPosition,
  browserRecordings,
  entryIndexAt,
  formatClock,
  formatSpan,
  mergeLanes,
  playbackAxis,
  recordingAt,
  sessionSpans,
  stepTime,
  timeToAxis,
} from '../utils/replayTimeline.mjs';

const T0 = Date.parse('2026-09-01T12:00:00.000Z');
const at = (ms) => new Date(T0 + ms).toISOString();

// A conversation turn: the user's message, a model call, a browser tool
// call and its browser action, the answer, and later a second turn.
const LANES = {
  message: [
    { id: 'message-1', role: 'user', content: 'Sign me in', start: at(100), duration_ms: 0 },
    { id: 'message-2', role: 'assistant', content: 'Done.', start: at(3000), duration_ms: 0 },
    { id: 'message-3', role: 'user', content: 'Thanks', start: at(3_600_000), duration_ms: 0 },
  ],
  llm: [{ id: 'span-llm', model: 'mock-model', start: at(200), duration_ms: 800 }],
  tool: [{ id: 'span-tool', name: 'browser_type', start: at(1100), duration_ms: 400 }],
  browser: [
    { id: 'event-1-0', kind: 'action', start: at(1100), duration_ms: 0, data: { tool_name: 'browser_type' } },
    { id: 'event-2-0', kind: 'console', start: 'not a time', duration_ms: 0 },
  ],
};

test('merges the lanes into one stream in time order, with absolute start and end times', () => {
  const entries = mergeLanes(LANES);

  assert.deepEqual(entries.map((entry) => entry.id), ['message-1', 'span-llm', 'span-tool', 'event-1-0', 'message-2', 'message-3']);
  assert.deepEqual(entries.map((entry) => entry.lane), ['message', 'llm', 'tool', 'browser', 'message', 'message']);
  assert.equal(entries[1].startMs, T0 + 200);
  assert.equal(entries[1].endMs, T0 + 1000);
});

test('entries starting together keep lane order, then their order within the lane', () => {
  const entries = mergeLanes({
    browser: [{ id: 'b', start: at(0) }],
    message: [{ id: 'm2', start: at(0) }, { id: 'm1', start: at(0) }],
    tool: [{ id: 't', start: at(0) }],
  });

  assert.deepEqual(entries.map((entry) => entry.id), ['m2', 'm1', 't', 'b']);
});

test('an entry without a readable start is left out, and a missing or negative duration reads as 0', () => {
  const entries = mergeLanes({ tool: [{ id: 'a', start: at(5), duration_ms: -3 }, { id: 'b' }, null] });

  assert.deepEqual(entries.map((entry) => [entry.id, entry.endMs - entry.startMs]), [['a', 0]]);
  assert.deepEqual(mergeLanes(), []);
});

const RECORDINGS = [
  { id: 2, rrweb: { event_count: 10, first_at: at(5000), last_at: at(9000) } },
  { id: 1, rrweb: { event_count: 4, first_at: at(1000), last_at: at(2000) } },
  { id: 3, rrweb: { event_count: 0, first_at: null, last_at: null } },
];

test('only recordings with rrweb events have a browser range, in start order', () => {
  const recordings = browserRecordings(RECORDINGS);

  assert.deepEqual(recordings.map((recording) => [recording.id, recording.startMs, recording.endMs]), [
    [1, T0 + 1000, T0 + 2000],
    [2, T0 + 5000, T0 + 9000],
  ]);
});

test('the spans are every entry and every browser recording', () => {
  const spans = sessionSpans(mergeLanes(LANES), browserRecordings(RECORDINGS));

  assert.deepEqual(spans.slice(-2), [[T0 + 1000, T0 + 2000], [T0 + 5000, T0 + 9000]]);
  assert.equal(spans.length, 8);
});

// Busy from 0 to 4s and from 1h to 1h + 2s; idle in between.
const AXIS = playbackAxis([[T0, T0 + 3000], [T0 + 2000, T0 + 4000], [T0 + 3_600_000, T0 + 3_602_000]], { maxGapMs: 10_000, gapMs: 1000 });

test('the axis joins nearby spans and shortens the idle stretch between segments', () => {
  assert.deepEqual(AXIS.segments, [
    { startMs: T0, endMs: T0 + 4000, axisStart: 0, axisEnd: 4000 },
    { startMs: T0 + 3_600_000, endMs: T0 + 3_602_000, axisStart: 5000, axisEnd: 7000 },
  ]);
  assert.equal(AXIS.totalMs, 7000);
  assert.equal(AXIS.startMs, T0);
  assert.equal(AXIS.endMs, T0 + 3_602_000);
  assert.deepEqual(axisGaps(AXIS), [{ axisStart: 4000, axisEnd: 5000, skippedMs: 3_596_000 }]);
});

test('a lone instant still gets a segment it can be played through', () => {
  const axis = playbackAxis([[T0, T0]], { minSegmentMs: 1000 });

  assert.deepEqual(axis.segments, [{ startMs: T0, endMs: T0 + 1000, axisStart: 0, axisEnd: 1000 }]);
});

test('an axis over nothing has no length and no times', () => {
  const axis = playbackAxis([]);

  assert.equal(axis.totalMs, 0);
  assert.equal(axis.startMs, null);
  assert.equal(axisToTime(axis, 100), null);
  assert.equal(timeToAxis(axis, T0), 0);
  assert.equal(axisStretchAt(axis, 0), 0);
});

test('seeking maps axis positions to session times and back', () => {
  assert.equal(axisToTime(AXIS, 0), T0);
  assert.equal(axisToTime(AXIS, 2500), T0 + 2500);
  assert.equal(axisToTime(AXIS, 4000), T0 + 4000);
  assert.equal(axisToTime(AXIS, 5000), T0 + 3_600_000);
  assert.equal(axisToTime(AXIS, 6500), T0 + 3_601_500);
  for (const position of [0, 1234, 4000, 4500, 5000, 6999, 7000]) {
    assert.equal(timeToAxis(AXIS, axisToTime(AXIS, position)), position, `axis ${position}`);
  }
});

test('inside an idle stretch, time runs across the whole stretch in proportion', () => {
  assert.equal(axisToTime(AXIS, 4500), T0 + 4000 + 3_596_000 / 2);
  assert.equal(timeToAxis(AXIS, T0 + 4000 + 3_596_000 / 4), 4250);
});

test('seeking clamps to the ends of the axis', () => {
  assert.equal(axisToTime(AXIS, -50), T0);
  assert.equal(axisToTime(AXIS, 99_999), T0 + 3_602_000);
  assert.equal(timeToAxis(AXIS, T0 - 5000), 0);
  assert.equal(timeToAxis(AXIS, T0 + 9_999_999), 7000);
});

test('a stretch changes when playback enters or leaves an idle stretch', () => {
  assert.deepEqual([0, 3999, 4000, 4001, 4999, 5000, 7000, 8000].map((ms) => axisStretchAt(AXIS, ms)), [0, 0, 0, 1, 1, 2, 2, 2]);
});

test('finds the entry current at a session time', () => {
  const entries = mergeLanes(LANES);

  assert.equal(entryIndexAt(entries, T0), -1);
  assert.equal(entryIndexAt(entries, T0 + 100), 0);
  assert.equal(entryIndexAt(entries, T0 + 1100), 3, 'the last of the entries starting together');
  assert.equal(entryIndexAt(entries, T0 + 2999), 3);
  assert.equal(entryIndexAt(entries, T0 + 99_999_999), 5);
  assert.equal(entryIndexAt([], T0), -1);
});

test('stepping moves to the next or previous entry start', () => {
  const entries = mergeLanes(LANES);

  assert.equal(stepTime(entries, T0, 1), T0 + 100);
  assert.equal(stepTime(entries, T0 + 200, 1), T0 + 1100, 'entries starting together are one step');
  assert.equal(stepTime(entries, T0 + 3_600_000, 1), null);
  assert.equal(stepTime(entries, T0 + 1500, -1), T0 + 1100, 'back to the start of the current entry');
  assert.equal(stepTime(entries, T0 + 1100, -1), T0 + 200);
  assert.equal(stepTime(entries, T0 + 100, -1), null);
});

test('picks the browser recording to show at a session time', () => {
  const recordings = browserRecordings(RECORDINGS);

  assert.equal(recordingAt(recordings, T0).id, 1, 'before any recording: the first');
  assert.equal(recordingAt(recordings, T0 + 1500).id, 1);
  assert.equal(recordingAt(recordings, T0 + 3000).id, 1, 'between recordings: the last one started');
  assert.equal(recordingAt(recordings, T0 + 6000).id, 2);
  assert.equal(recordingAt([], T0), null);
});

test('places a session time in a browser recording', () => {
  const range = { startMs: T0 + 1000, endMs: T0 + 2000 };

  assert.deepEqual(browserPosition(range, T0), { phase: 'before', offsetMs: 0 });
  assert.deepEqual(browserPosition(range, T0 + 1250), { phase: 'during', offsetMs: 250 });
  assert.deepEqual(browserPosition(range, T0 + 2000), { phase: 'during', offsetMs: 1000 });
  assert.deepEqual(browserPosition(range, T0 + 9000), { phase: 'after', offsetMs: 1000 });
});

test('formats clock times and skipped spans', () => {
  assert.equal(formatClock(0), '0:00');
  assert.equal(formatClock(65_400), '1:05');
  assert.equal(formatClock(3_723_000), '1:02:03');
  assert.equal(formatClock(-5), '0:00');
  assert.equal(formatSpan(45_000), '45s');
  assert.equal(formatSpan(250_000), '4m 10s');
  assert.equal(formatSpan(3_596_000), '59m 56s');
  assert.equal(formatSpan(7_500_000), '2h 5m');
  assert.equal(formatSpan(273_600_000), '3d 4h');
  assert.equal(formatSpan(3_600_000), '1h');
  assert.equal(formatSpan(0), '0s');
});
