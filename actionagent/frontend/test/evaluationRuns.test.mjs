import assert from 'node:assert/strict';
import test from 'node:test';
import {
  criterionExpectation, criterionGroup, criterionLabel, judgeCallsText, judgeLabel, keepSandboxChoice, modelScorecard,
  runCohorts, runDelta, runLabel, runNumber, runRequestBody, runSandboxLabel, runSandboxOptions, runSpend, runsMeta,
  samplingFixItems, sandboxLabel, spendSummary,
} from '../utils/evaluationRuns.mjs';

const sampling = {
  id: 1, scenario_suite: false, judge_kind: 'rules', sample_size: 20, agent: { id: 7, name: 'Docs Navigator' },
  criteria: [
    { key: 'response_present', type: 'response_present', config: {} },
    { key: 'latency', type: 'max_latency_ms', config: { ms: 5000 } },
    { key: 'trace_error_rate', type: 'trace_error_rate', config: { max_error_rate: 5, window_hours: 168 } },
    { key: 'quality', type: 'llm_judge', config: { prompt: 'Is the answer helpful?' } },
  ],
};

test('criteria are grouped, named and read as what they expect', () => {
  assert.deepEqual(sampling.criteria.map(criterionGroup), ['rules', 'rules', 'telemetry', 'judge']);
  assert.equal(criterionLabel(sampling.criteria[1]), 'Latency');
  assert.equal(criterionExpectation(sampling.criteria[1]), '≤ 5s');
  assert.equal(criterionExpectation(sampling.criteria[2]), 'error rate ≤ 5% · 168h');
  assert.equal(criterionExpectation(sampling.criteria[3]), 'judge: Is the answer helpful?');
  assert.equal(criterionLabel({ key: 'answers_from_docs', type: 'llm_judge', config: {} }), 'Answers from docs');
});

test('the judge is the one the run recorded, never the pass-rate ranking', () => {
  assert.equal(judgeLabel(sampling), 'rules');
  assert.equal(judgeLabel({ judge_kind: 'llm', judge_model: 'claude-opus-5' }), 'claude-opus-5');
  assert.equal(judgeLabel({ judge_kind: 'judge_defined' }), 'judge-defined KPIs');
  assert.equal(judgeLabel(sampling, { scores: { _verdict: { judge: 'pass rate' } } }), 'rules');
  assert.equal(judgeLabel(sampling, { scores: { _verdict: { judge: 'gpt-5' } } }), 'gpt-5');
  assert.equal(judgeLabel({ judge_kind: 'llm', judge_model: 'x' }, { scores: { _judge_label: null } }), 'rules');
});

test('a run is labelled by what it covers', () => {
  assert.equal(runLabel(sampling), '4 criteria · 20 samples');
  assert.equal(runLabel({ ...sampling, compare_models: ['a', 'b', 'c'] }), '4 criteria × 3 models');
  const suite = { scenario_suite: true, scenario_count: 12, compare_models: ['a', 'b'] };
  assert.equal(runLabel(suite), '12 scenarios × 2 models');
  assert.equal(runLabel(suite, { samples_evaluated: 6, models: ['a', 'b'] }), '3 scenarios × 2 models');
});

test('cohorts read the same shape from a sampling run and a scenario run', () => {
  const sampled = runCohorts({ scores: { _cohorts: { 'gpt-4o-mini': { samples: 12, passed: 11, provider: 'openai', cost: 0.0006, input_tokens: 1200, output_tokens: 480 } } } });
  assert.equal(sampled.length, 1);
  assert.equal(sampled[0].kind, 'sample');
  assert.equal(sampled[0].label, 'gpt-4o-mini');
  assert.equal(sampled[0].samples, 12);
  assert.equal(sampled[0].passed, 11);
  assert.equal(sampled[0].cost, 0.0006);

  const replayed = runCohorts({ scores: { _models: { 'ollama/qwen3:8b': { model: 'qwen3:8b', provider: 'ollama', scenarios: 8, passed: 5, avg_score: 0.71, cost: 0.02, faults: { tool_error: 2 } } } } });
  assert.equal(replayed[0].kind, 'replay');
  assert.equal(replayed[0].label, 'ollama/qwen3:8b');
  assert.equal(replayed[0].model, 'qwen3:8b');
  assert.equal(replayed[0].samples, 8);
  assert.deepEqual(replayed[0].faults, { tool_error: 2 });

  // An older run recorded no summaries: one cohort of everything it scored.
  const bare = runCohorts({ samples_evaluated: 20, samples_passed: 14, scores: { latency: { score: 0.8, total: 20 } } });
  assert.deepEqual(bare.map((c) => [c.label, c.samples, c.passed]), [[null, 20, 14]]);
});

test('a scorecard counts the criteria a model cleared, missed and skipped', () => {
  const run = { scores: {
    latency: { a: { score: 1.0 }, b: { score: 0.62 } },
    quality: { a: { score: 0.9 }, b: { skipped: true, reason: 'no credentials' } },
    trace_error_rate: { score: 1.0, source: 'telemetry' },
  } };
  assert.deepEqual(modelScorecard(run, 'a'), { avg: (1 + 0.9 + 1) / 3, scored: 3, cleared: 3, below: 0, skipped: 0 });
  assert.deepEqual(modelScorecard(run, 'b'), { avg: (0.62 + 1) / 2, scored: 2, cleared: 1, below: 1, skipped: 1 });
});

test('runs are numbered from the oldest and the list says when it is a page', () => {
  const runs = [{ id: 30 }, { id: 20, number: 23 }, { id: 10 }];
  assert.equal(runNumber(runs[0], 0, runs, 24), 24);
  assert.equal(runNumber(runs[1], 1, runs, 24), 23);
  assert.equal(runNumber(runs[2], 2, runs), 1);
  assert.equal(runsMeta(runs, 24), '24 runs · latest 3');
  assert.equal(runsMeta(runs), '3 runs');
});

test('movement is read against the run before, when there is one to read against', () => {
  const run = { status: 'complete', samples_passed: 14 };
  assert.deepEqual(runDelta(run, null), { text: 'first run', tone: 'muted' });
  assert.deepEqual(runDelta(run, { status: 'complete', samples_passed: 11, number: 2 }), { text: '+3 passed vs #2', tone: 'success' });
  assert.deepEqual(runDelta(run, { status: 'complete', samples_passed: 16 }, { olderNumber: 2 }), { text: '-2 passed vs #2', tone: 'error' });
  assert.deepEqual(runDelta(run, { status: 'complete', samples_passed: 14, number: 2 }), { text: 'same as #2', tone: 'muted' });
  assert.deepEqual(runDelta(run, { status: 'failed', number: 1 }), { text: '#1 failed', tone: 'muted' });
  assert.deepEqual(runDelta(run, { status: 'complete', samples_passed: 3, number: 1 }, { comparable: false }), { text: 'partial run', tone: 'muted' });
  assert.equal(runDelta({ status: 'running' }, null), null);
});

test('spend keeps the agent side apart from the judge side', () => {
  const judge = { calls: 24, cost: 0.12, by_kind: { score: 20, recommend: 3, verdict: 1 }, model: 'claude-opus-5' };
  const replayed = runSpend({ usage: { replays: 8, cost: 0.44, per_interaction: 0.055, input_tokens: 9000, output_tokens: 700, judge } });
  assert.equal(replayed.agent.unit, 'replay');
  assert.equal(replayed.agent.count, 8);
  assert.equal(replayed.agent.perInteraction, 0.055);
  assert.equal(replayed.judge.calls, 24);
  assert.equal(judgeCallsText(replayed.judge), 'score 20 · recommend 3 · verdict 1');
  assert.ok(Math.abs(replayed.total - 0.56) < 1e-9);

  const sampled = runSpend({ usage: { samples: 20, cost: 0.0058, input_tokens: 2000, output_tokens: 800 } });
  assert.equal(sampled.agent.unit, 'sample');
  assert.ok(Math.abs(sampled.agent.perInteraction - 0.00029) < 1e-9);
  assert.equal(sampled.judge, null);
  assert.equal(sampled.total, 0.0058);

  const judged = runSpend({ usage: { judge: { calls: 1, cost: 0.0045, by_kind: { define: 1 } } } });
  assert.equal(judged.agent, null);
  assert.equal(judged.total, 0.0045);
  assert.equal(runSpend({ usage: null }), null);
  assert.equal(runSpend({}), null);
});

test('the page rate is the agent cost over every interaction on the page', () => {
  const summary = spendSummary([
    { usage: { replays: 8, cost: 0.44, judge: { calls: 24, cost: 0.12, by_kind: {} } } },
    { usage: { samples: 20, cost: 0.0058 } },
    { usage: null },
    { status: 'failed' },
  ]);
  assert.equal(summary.priced, 2);
  assert.equal(summary.interactions, 28);
  assert.ok(Math.abs(summary.agentCost - 0.4458) < 1e-9);
  assert.ok(Math.abs(summary.perInteraction - 0.4458 / 28) < 1e-9);
  assert.equal(summary.judgeCost, 0.12);
  assert.deepEqual(spendSummary([]), { agentCost: null, interactions: 0, perInteraction: null, judgeCost: null, priced: 0 });
});

test('a sampling run asks to fix what its own data says', () => {
  const failed = samplingFixItems(sampling, { status: 'failed', number: 1, error_message: 'No generations to evaluate yet — run the agent first' });
  assert.deepEqual(failed.map((item) => item.kind), ['failed']);
  assert.equal(failed[0].scope, 'run #1');
  assert.equal(failed[0].action.path, '/agents/7/run');

  const run = { status: 'complete', scores: {
    _missing_models: ['gpt-4o-mini'],
    latency: { a: { score: 1.0, passed: 12, total: 12 }, b: { score: 0.62, passed: 6, total: 12 } },
    quality: { a: { skipped: true, reason: 'LLM judge requires provider credentials' }, b: { skipped: true, reason: 'LLM judge requires provider credentials' } },
    trace_error_rate: { skipped: true, reason: 'No telemetry traces' },
  } };
  const items = samplingFixItems(sampling, run);
  assert.deepEqual(items.map((item) => item.kind), ['missing', 'judge', 'telemetry', 'below']);
  assert.deepEqual(items[0].chips, ['gpt-4o-mini']);
  assert.equal(items[1].label, 'judge skipped ×2');
  assert.equal(items[1].scope, '1 criterion');
  assert.equal(items[1].action.path, '/settings');
  assert.equal(items[3].scope, '1 criterion · 1 model');
  assert.deepEqual(items[3].details, ['latency · b 0.62 · expects ≤ 5s · 6/12 passed']);
  assert.deepEqual(samplingFixItems(sampling, { status: 'complete', scores: { latency: { score: 1.0 } } }), []);
});

test('a run can target one of the caller ready checkout sandboxes, and names it', () => {
  const sandboxes = [
    { session_id: '1a2b3c4d-0000', sandbox_type: 'app_runtime', repository: 'acme/shop', repository_ref: 'experiment', status: 'ready' },
    { session_id: '5e6f7a8b-0000', sandbox_type: 'app_runtime', repository: 'acme/shop', repository_ref: null, status: 'provisioning' },
    { session_id: '9c0d1e2f-0000', sandbox_type: 'playwright_mcp', status: 'ready' },
    { session_id: 'aaaabbbb-0000', repository: 'acme/docs', status: 'ready' },
    { session_id: 'cccc0000-0000', sandbox_type: 'app_runtime', repository: 'acme/shop', status: 'ready', runtime_server_key: null },
    null,
  ];

  assert.deepEqual(runSandboxOptions(sandboxes), [
    { value: '1a2b3c4d-0000', label: 'acme/shop@experiment · 1a2b3c4d' },
    { value: 'aaaabbbb-0000', label: 'acme/docs · aaaabbbb' },
  ]);
  assert.deepEqual(runSandboxOptions(undefined), []);
  assert.equal(sandboxLabel({ session_id: 'ffffeeee-1' }), 'sandbox ffffeeee');
  assert.equal(sandboxLabel(null), null);

  assert.equal(runSandboxLabel({ sandbox: { session_id: '1a2b3c4d-0000', repository: 'acme/shop', repository_ref: 'main' } }), 'acme/shop@main · 1a2b3c4d');
  assert.equal(runSandboxLabel({ sandbox: null }), null);
  assert.equal(runSandboxLabel({}), null);

  assert.deepEqual(runRequestBody({ group: 'Find' }, ['mock/a'], '1a2b3c4d-0000'), { group: 'Find', models: ['mock/a'], sandbox_id: '1a2b3c4d-0000' });
  assert.deepEqual(runRequestBody({}, [], ''), { models: [] });

  const options = runSandboxOptions(sandboxes);
  assert.equal(keepSandboxChoice('1a2b3c4d-0000', options), '1a2b3c4d-0000');
  assert.equal(keepSandboxChoice('5e6f7a8b-0000', options), '', 'a sandbox that is no longer ready is dropped');
  assert.equal(keepSandboxChoice('', options), '');
});
