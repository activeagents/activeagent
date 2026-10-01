import assert from 'node:assert/strict';
import test from 'node:test';
import { COUNTED_STANDINGS, evaluationStanding, headlineRun, headlineSummary, notCountedText } from '../utils/evaluationRuns.mjs';

// The Evaluations page's tiles describe the headline run of each
// evaluation that stands against the agent as it is now.

const complete = (id, passed, total, extra = {}) => ({ id, status: 'complete', samples_passed: passed, samples_evaluated: total, ...extra });

const evaluations = [
  // Current: its latest run is its headline run.
  { id: 1, standing: 'current', headline_run_id: 11, latest_run: complete(11, 8, 10, { usage: { replays: 10, cost: 0.1, reported: 10, estimated: 0, cost_basis: 'reported' } }),
    per_model: { 'gpt-5-mini': { passed: 5, total: 5 }, 'qwen3:8b': { passed: 3, total: 5 } } },
  // Current, with a newer run still queued: the headline rides along in full.
  { id: 2, standing: 'current', headline_run_id: 21, latest_run: { id: 22, status: 'pending' },
    headline_run: complete(21, 2, 4, { usage: { replays: 4, cost: 0.02, reported: 0, estimated: 4, cost_basis: 'estimated' }, scores: { _models: { 'gpt-5-mini': { scenarios: 4, passed: 2 } } } }) },
  // Stale: last run against an earlier version — left out.
  { id: 3, standing: 'stale', headline_run_id: 31, latest_run: complete(31, 0, 10) },
  // Archived — left out.
  { id: 4, standing: 'archived', archived_at: '2026-09-01T00:00:00Z', headline_run_id: 41, latest_run: complete(41, 10, 10) },
  // Unrecorded: a published run naming no release — still counts.
  { id: 5, standing: 'unrecorded', headline_run_id: 51, latest_run: complete(51, 3, 3) },
  // No complete run yet.
  { id: 6, standing: 'none', headline_run_id: null, latest_run: { id: 61, status: 'failed' } },
];

test('the headline run is the newest complete run, however the API describes it', () => {
  assert.equal(headlineRun(evaluations[0]).id, 11);
  assert.equal(headlineRun(evaluations[1]).id, 21, 'the headline run rides along when a newer run is pending');
  assert.equal(headlineRun(evaluations[5]), null);
  // An older server names no headline: the latest run stands in when it completed.
  assert.equal(headlineRun({ latest_run: complete(7, 1, 2) }).id, 7);
  assert.equal(headlineRun({ latest_run: { id: 8, status: 'running' } }), null);
  assert.equal(headlineRun({ headline_run_id: 9, latest_run: { id: 10, status: 'running' } }), null, 'the API names a headline the page does not hold');
});

test('standing is what the API says, else what the page can tell', () => {
  assert.deepEqual(evaluations.map(evaluationStanding), ['current', 'current', 'stale', 'archived', 'unrecorded', 'none']);
  assert.equal(evaluationStanding({ latest_run: complete(1, 1, 1) }), 'current');
  assert.equal(evaluationStanding({ archived_at: '2026-09-01T00:00:00Z', latest_run: complete(1, 1, 1) }), 'archived');
  assert.equal(evaluationStanding({ latest_run: { status: 'pending' } }), 'none');
  assert.deepEqual(COUNTED_STANDINGS, ['current', 'unrecorded']);
});

test('the tiles pool the headline runs of the evaluations that count and say what was left out', () => {
  const summary = headlineSummary(evaluations);

  assert.equal(summary.evaluations, 6);
  assert.equal(summary.counted, 3);
  assert.deepEqual(summary.runs.map((run) => run.id), [11, 21, 51]);
  assert.equal(summary.samplesScored, 17);
  assert.equal(summary.samplesPassed, 13);
  assert.ok(Math.abs(summary.passRatio - 13 / 17) < 1e-12);
  assert.deepEqual(summary.notCounted, { total: 3, stale: 1, archived: 1, none: 1 });
  assert.equal(notCountedText(summary), '3 not counted · 1 stale · 1 archived · 1 has no complete run');
  assert.equal(summary.focused, false);
  // Per model, pooled across the counted runs: the API's per_model, else the run's own summaries.
  assert.deepEqual(summary.perModel, [
    { label: 'gpt-5-mini', passed: 7, total: 9 },
    { label: 'qwen3:8b', passed: 3, total: 5 },
  ]);
  // Spend over the counted runs, marked as an estimate when any part was.
  assert.ok(Math.abs(summary.spend.agentCost - 0.12) < 1e-12);
  assert.equal(summary.spend.interactions, 14);
  assert.equal(summary.spend.estimated, true);
});

test('focused on one evaluation, the tiles describe its headline run alone, whatever its standing', () => {
  const focused = headlineSummary(evaluations, { focusId: '3' });
  assert.equal(focused.focused, true);
  assert.equal(focused.evaluations, 1);
  assert.deepEqual(focused.runs.map((run) => run.id), [31]);
  assert.equal(focused.passRatio, 0);
  assert.equal(notCountedText(focused), null);

  const pending = headlineSummary(evaluations, { focusId: 6 });
  assert.equal(pending.counted, 0);
  assert.equal(pending.passRatio, null);
  assert.equal(notCountedText(pending), '1 not counted · 1 has no complete run');

  // An id outside the page falls back to the whole page.
  assert.equal(headlineSummary(evaluations, { focusId: 999 }).counted, 3);
});

test('an empty page has nothing to count', () => {
  const summary = headlineSummary([]);
  assert.equal(summary.counted, 0);
  assert.equal(summary.passRatio, null);
  assert.deepEqual(summary.perModel, []);
  assert.equal(notCountedText(summary), null);
});
