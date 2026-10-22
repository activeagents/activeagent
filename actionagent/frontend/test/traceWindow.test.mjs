import assert from 'node:assert/strict';
import test from 'node:test';
import { traceWindowData } from '../utils/traceWindow.mjs';
import { tracesQuery } from '../utils/tracesQuery.mjs';

const window = { minutes: 2, bucketSeconds: 60 };
test('full-window chart and totals are independent of the capped detail list', () => {
  const rows = [{ timestamp_ms: 90000, duration_ms: 100, status: 'OK' }];
  const report = { total_count: 1001, truncated: true,
    summary: { requests: 1001, errors: 1, avg_latency_ms: 190, throughput_per_minute: 500.5 },
    buckets: [
      { start_ms: 0, end_ms: 60000, requests: 1000, errors: 1, avg_latency_ms: 191, agents: { AuditAgent: 1000 } },
      { start_ms: 60000, end_ms: 120000, requests: 1, errors: 0, avg_latency_ms: 100, agents: { AuditAgent: 1 } },
    ] };
  const value = traceWindowData(report, rows, ['AuditAgent', 'IdleAgent'], window);
  assert.equal(value.summary.requests, 1001);
  assert.equal(value.summary.errors, 1);
  assert.equal(value.summary.avgLatency, 190);
  assert.equal(value.summary.throughput, '500.5');
  assert.equal(value.total, 1001);
  assert.equal(value.truncated, true);
  assert.equal(value.buckets[0].requests, 1000);
  assert.equal(value.buckets[0].AuditAgent, 1000);
  assert.equal(value.buckets[0].IdleAgent, 0);
  assert.deepEqual(value.buckets[0].traces, []);
  assert.deepEqual(value.buckets[1].traces, rows);
});

test('older endpoints still average recorded request durations rather than bucket means', () => {
  const now = Date.now();
  const rows = [{ timestamp_ms: now - 90000, duration_ms: 1000 },
    ...Array.from({ length: 9 }, () => ({ timestamp_ms: now - 30000, duration_ms: 100 })),
    { timestamp_ms: now - 30000, duration_ms: null }];
  assert.equal(traceWindowData(null, rows, [], window).summary.avgLatency, 190);
  assert.equal(traceWindowData(null, [], [], window).summary.avgLatency, 0);
});

test('drilldown uses the server half-open bucket bounds', () => {
  const rows = [0, 59, 60, 119, 120].map((timestamp_ms) => ({ timestamp_ms }));
  const report = { summary: { requests: 4, errors: 0, avg_latency_ms: 0, throughput_per_minute: 2 }, buckets: [
    { start_ms: 0, end_ms: 60, requests: 2, agents: {} },
    { start_ms: 60, end_ms: 120, requests: 2, agents: {} },
  ] };
  assert.deepEqual(traceWindowData(report, rows, [], window).buckets.map((b) => b.traces.map((r) => r.timestamp_ms)), [[0, 59], [60, 119]]);
});

test('the query carries the window bucket width and agent id', () => {
  const query = tracesQuery({ minutes: 120, bucketSeconds: 240, agentId: 42 });
  assert.equal(query, '/api/traces?minutes=120&bucket_seconds=240&agent_id=42');
});
