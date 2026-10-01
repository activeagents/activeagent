import assert from 'node:assert/strict';
import test from 'node:test';
import { fixItemCountsByModel, fixItemsForModel, modelComparisonRows, typicalFaultText, withModelBreakdown } from '../utils/evaluationRuns.mjs';

// A finished scenario run: the runner's per-model summaries plus results.
const run = {
  status: 'complete',
  scores: {
    _verdict: { winner: 'phi4-mini:latest', judge: 'qwen3:4b-instruct' },
    _models: {
      'qwen3:4b-instruct': { provider: 'ollama', model: 'qwen3:4b-instruct', scenarios: 6, passed: 4, avg_score: 0.917, avg_duration_ms: 5219, input_tokens: 1260, output_tokens: 304, cost: 0.000435, faults: { missing_content: 1, low_quality: 1 } },
      'llama3.2:3b': { provider: 'ollama', model: 'llama3.2:3b', scenarios: 6, passed: 1, avg_score: 0.733, avg_duration_ms: 11713, input_tokens: 243, output_tokens: 1143, cost: 0.000734, faults: { missing_content: 2, low_quality: 2, missing_capability: 1 } },
      'phi4-mini:latest': { provider: 'ollama', model: 'phi4-mini:latest', scenarios: 6, passed: 5, avg_score: 0.967, avg_duration_ms: 9103, input_tokens: 1203, output_tokens: 398, cost: 0.002795, faults: { low_quality: 1 } },
      'gemma3:4b': { provider: 'ollama', model: 'gemma3:4b', scenarios: 6, passed: 1, avg_score: 0.83, avg_duration_ms: 27014, input_tokens: 154, output_tokens: 1320, cost: 0.005434, faults: { low_quality: 4, missing_content: 1 } },
    },
  },
};
const results = [
  { scenario_key: 'refund_window', model: 'llama3.2:3b', status: 'failed', fault: 'missing_content', diagnosis: { summary: 'The answer is missing expected content: 30.' } },
  { scenario_key: 'late_refund', model: 'llama3.2:3b', status: 'failed', fault: 'missing_content', diagnosis: { summary: 'The answer is missing expected content: credit.' } },
  { scenario_key: 'late_refund', model: 'qwen3:4b-instruct', status: 'failed', fault: 'missing_content', diagnosis: { summary: 'The answer is missing expected content: credit.' } },
  { scenario_key: 'out_of_scope', model: 'phi4-mini:latest', status: 'failed', fault: 'low_quality', recommendation: 'Say you do not know and point to human support.' },
];

test('rows read best first with passed, mean score, latency, average tokens and cost per scenario', () => {
  const rows = modelComparisonRows(run, { results, scenarioCount: 6 });

  assert.deepEqual(rows.map((r) => r.label), ['phi4-mini:latest', 'qwen3:4b-instruct', 'gemma3:4b', 'llama3.2:3b']);
  const phi = rows[0];
  assert.equal(phi.winner, true);
  assert.equal(`${phi.passed}/${phi.total}`, '5/6');
  assert.equal(phi.avgScore, 0.967);
  assert.equal(phi.avgDurationMs, 9103);
  assert.equal(Math.round(phi.avgTokens), Math.round((1203 + 398) / 6));
  assert.equal(Math.round(phi.avgInputTokens), Math.round(1203 / 6));
  assert.equal(phi.cost, 0.002795);
  assert.ok(Math.abs(phi.costPerInteraction - 0.002795 / 6) < 1e-9);
  // Equal pass rates are ordered by mean score: gemma (0.83) above llama (0.733).
  assert.equal(rows[2].label, 'gemma3:4b');
  assert.equal(rows[3].winner, false);
});

test('a partially priced cohort is costed per priced interaction', () => {
  const partial = { status: 'complete', scores: { _models: {
    a: { scenarios: 4, passed: 4, avg_score: 1, cost: 0.003, priced: 3, faults: {} },
    b: { scenarios: 4, passed: 4, avg_score: 1, cost: null, priced: 0, faults: {} },
  } } };
  const [a, b] = modelComparisonRows(partial);

  assert.equal(a.priced, 3);
  assert.ok(Math.abs(a.costPerInteraction - 0.001) < 1e-12, 'the rate is over the 3 priced scenarios, not all 4');
  assert.equal(b.priced, 0);
  assert.equal(b.cost, null);
  assert.equal(b.costPerInteraction, null);
});

test('the typical fault is the most frequent one, with the first matching diagnosis', () => {
  const rows = modelComparisonRows(run, { results, scenarioCount: 6 });
  const llama = rows.find((r) => r.label === 'llama3.2:3b');

  // Two faults tie at 2; the one a landed result can explain leads, so the
  // row shows a diagnosis rather than a bare count.
  assert.deepEqual(llama.faults.map((f) => `${f.name} ×${f.count}`), ['missing content ×2', 'low quality ×2', 'missing capability ×1']);
  assert.equal(llama.typicalFault.name, 'missing content');
  assert.equal(llama.typicalFault.count, 2);
  assert.equal(llama.typicalFault.scenarioKey, 'refund_window');
  assert.equal(typicalFaultText(llama), 'missing content ×2 · refund_window: The answer is missing expected content: 30.');

  const qwen = rows.find((r) => r.label === 'qwen3:4b-instruct');
  assert.equal(qwen.typicalFault.scenarioKey, 'late_refund');
  assert.equal(typicalFaultText(qwen), 'missing content ×1 · late_refund: The answer is missing expected content: credit.');

  const phi = rows.find((r) => r.label === 'phi4-mini:latest');
  assert.equal(typicalFaultText(phi), 'low quality ×1 · out_of_scope: Say you do not know and point to human support.');
});

test('a clean cohort says so and an unscored one shows a dash', () => {
  const clean = { status: 'complete', scores: { _models: { 'gpt-5.4-mini': { provider: 'openrouter', scenarios: 6, passed: 6, avg_score: 1, faults: {} } } } };
  assert.equal(typicalFaultText(modelComparisonRows(clean)[0]), 'no faults');
  assert.equal(typicalFaultText(null), '—');
});

test('a run still scoring counts passed, faults and mean score from the results that landed', () => {
  const pending = { status: 'running', scores: {}, selection: { models: [{ label: 'a', provider: 'ollama', model: 'a' }, { label: 'b', provider: 'ollama', model: 'b' }] } };
  const landed = [
    { scenario_key: 's1', model: 'a', status: 'passed', score: 1 },
    { scenario_key: 's2', model: 'a', status: 'failed', score: 0.5, fault: 'low_quality', diagnosis: { summary: 'Judged 0.5' } },
    { scenario_key: 's1', model: 'b', status: 'pending' },
  ];
  const rows = modelComparisonRows(pending, { results: landed, scenarioCount: 3, columns: ['a', 'b'] });

  assert.equal(rows[0].label, 'a');
  assert.equal(`${rows[0].passed}/${rows[0].total}`, '1/3');
  assert.equal(rows[0].avgScore, 0.75);
  assert.equal(typicalFaultText(rows[0]), 'low quality ×1 · s2: Judged 0.5');
  assert.equal(rows[0].avgTokens, null);
  assert.equal(`${rows[1].passed}/${rows[1].total}`, '0/3');
  assert.equal(typicalFaultText(rows[1]), '—');
});

test('sampling comparison runs read their cohorts without faults', () => {
  const sampling = { status: 'complete', scores: { quality: { 'claude-haiku-4-5': { score: 0.9 }, 'qwen3:8b': { score: 0.6 } }, _cohorts: { 'claude-haiku-4-5': { samples: 20, passed: 18, avg_duration_ms: 900, input_tokens: 4000, output_tokens: 2000, cost: 0.02 }, 'qwen3:8b': { samples: 20, passed: 9, avg_duration_ms: 3000 } } } };
  const rows = modelComparisonRows(sampling, { columns: ['qwen3:8b', 'claude-haiku-4-5'] });

  assert.deepEqual(rows.map((r) => r.label), ['claude-haiku-4-5', 'qwen3:8b']);
  assert.equal(`${rows[0].passed}/${rows[0].total}`, '18/20');
  assert.equal(rows[0].avgTokens, 300);
  assert.equal(rows[0].costPerInteraction, 0.001);
  assert.equal(typicalFaultText(rows[0]), 'no faults');
  assert.equal(rows[1].cost, null);
});

test('fix items filter to the model they were attributed to', () => {
  const items = [
    { kind: 'fault', fault: 'low_quality', count: 8, models: ['gemma3:4b', 'qwen3:4b-instruct', 'llama3.2:3b', 'phi4-mini:latest'], scenario_keys: ['a'] },
    { kind: 'fault', fault: 'missing_content', count: 4, models: ['llama3.2:3b', 'qwen3:4b-instruct', 'gemma3:4b'], scenario_keys: ['a', 'b'] },
    { kind: 'fault', fault: 'missing_capability', count: 1, models: ['llama3.2:3b'], scenario_keys: ['c'] },
    { kind: 'instruction', fault: 'instruction change', count: 2, models: ['llama3.2:3b', 'qwen3:4b-instruct'], scenario_keys: ['b'] },
    { kind: 'fault', fault: 'tool_error', count: 1, scenario_keys: ['d'] }, // an older run: no model attribution
  ];
  const labels = ['qwen3:4b-instruct', 'llama3.2:3b', 'phi4-mini:latest', 'gemma3:4b'];

  assert.equal(fixItemsForModel(items).length, 5);
  assert.equal(fixItemsForModel(items, 'all').length, 5);
  assert.deepEqual(fixItemsForModel(items, 'phi4-mini:latest').map((i) => i.fault), ['low_quality', 'tool_error']);
  assert.deepEqual(fixItemsForModel(items, 'llama3.2:3b').map((i) => i.fault), ['low_quality', 'missing_content', 'missing_capability', 'instruction change', 'tool_error']);
  // A filtered item is scoped to that model so its header reads for the filter.
  assert.deepEqual(fixItemsForModel(items, 'llama3.2:3b')[0].models, ['llama3.2:3b']);
  assert.deepEqual(fixItemCountsByModel(items, labels), { 'qwen3:4b-instruct': 4, 'llama3.2:3b': 5, 'phi4-mini:latest': 2, 'gemma3:4b': 3 });
});

test('a filtered fix item counts and names only what that model produced', () => {
  const items = [
    { kind: 'fault', fault: 'low_quality', count: 3, models: ['a', 'b'], scenario_keys: ['s1', 's2'] },
    { kind: 'instruction', fault: 'instruction change', count: 2, models: ['a', 'b'], scenario_keys: ['s2'], quote: 'Say so.' },
  ];
  const landed = [
    { scenario_key: 's1', model: 'a', status: 'failed', fault: 'low_quality' },
    { scenario_key: 's2', model: 'a', status: 'failed', fault: 'low_quality' },
    { scenario_key: 's2', model: 'b', status: 'failed', fault: 'low_quality' },
    { scenario_key: 's1', model: 'b', status: 'passed' },
  ];
  const attributed = withModelBreakdown(items, landed);
  assert.deepEqual(attributed[0].count_by_model, { a: 2, b: 1 });
  assert.deepEqual(attributed[0].scenario_keys_by_model, { a: ['s1', 's2'], b: ['s2'] });

  const forB = fixItemsForModel(attributed, 'b');
  assert.equal(forB[0].count, 1);
  assert.deepEqual(forB[0].scenario_keys, ['s2']);
  assert.deepEqual(forB[0].models, ['b']);
  // The instruction item is attributed by the scenarios it was suggested for.
  assert.equal(forB[1].count, 1);
  // Unfiltered items keep the run-wide figures.
  assert.equal(fixItemsForModel(attributed, 'all')[0].count, 3);
});
