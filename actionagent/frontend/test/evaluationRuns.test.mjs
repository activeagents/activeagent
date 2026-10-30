import assert from 'node:assert/strict';
import test from 'node:test';
import {
  DETAILS_KEPT, DETAIL_STORAGE_KEY, KEY_COLUMN_MIN_WIDTH, PANEL_GUTTER, RAIL_BARS_MAX, RAIL_BREAKPOINT, RAIL_GAP, RAIL_WIDTH,
  STEPS_HEIGHT, STRIP_LIST_HEIGHT,
  changesText, columnTotals, combinedBars, criterionExpectation, criterionGroup, criterionLabel, currentStepKey, cursorScrollTop, fmtClock, fmtDuration,
  fmtSpan, groupResultsByKey, groupStep, groupTime, groupsOutsideRun, isEstimated, judgeCallsText, judgeLabel, judgeSourceText, keepDetails,
  keepSandboxChoice, modelScorecard, costPer, openRowScrollTop, orderScenarioRows, pollIntervalFor, pricedCount, readDetailChoice,
  reconcileResults, rerunFailedKeys, resultChanges, resultMetrics, runCohorts, runDelta, runElapsedMs, runLabel, runNumber, runRequestBody,
  runRequestSelection, runSandboxLabel, runSandboxOptions, runScenarioKeys, runSelectionLabel, runSpend, runnableKeys, runsMeta, sameResult,
  samplingFixItems, scenarioStep, scenarioTime, scenarioTokens, selectionModelLabels, selectionOf, shownRunIndexes, sandboxLabel,
  spendSummary, spendTotalLabel, stepsMinWidth, sumMetrics, sumTokens, toolsMinWidth, versionChip, versionDelta, writeDetailChoice,
} from '../utils/evaluationRuns.mjs';
import { fmtTokenIO } from '../utils/format.js';

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

test('a cohort counts the interactions it priced, and a summary recorded before it did counts them all', () => {
  const replayed = runCohorts({ scores: { _models: {
    partial: { scenarios: 5, passed: 5, cost: 0.03, priced: 3 },
    none: { scenarios: 5, passed: 5, cost: null, priced: 0 },
    older: { scenarios: 5, passed: 5, cost: 0.05 },
  } } });
  assert.deepEqual(replayed.map((c) => [c.label, c.priced]), [['partial', 3], ['none', 0], ['older', 5]]);

  const sampled = runCohorts({ scores: { _cohorts: { 'gpt-4o-mini': { samples: 12, cost: 0.0006, priced: 10 }, unknown: { samples: 8, cost: null } } } });
  assert.deepEqual(sampled.map((c) => [c.label, c.priced]), [['gpt-4o-mini', 10], ['unknown', 0]]);

  assert.equal(pricedCount(null, 5), null);
  assert.equal(costPer(0.03, 3), 0.01);
  assert.equal(costPer(0.03, 0), null);
  assert.equal(costPer(null, 3), null);
});

test('a cost is an estimate when any part was priced from tokens, or some interaction went unpriced', () => {
  assert.equal(isEstimated({ cost: 0.03, priced: 5, estimated: 2 }, 5), true, 'two replays priced from tokens');
  assert.equal(isEstimated({ cost: 0.03, priced: 5, estimated: 0, reported: 5 }, 5), false, 'every replay reported');
  assert.equal(isEstimated({ cost: 0.03, priced: 3, estimated: 0 }, 5), true, 'a partial sum is a lower bound');
  assert.equal(isEstimated({ cost: 0.03, cost_basis: 'mixed' }, 5), true);
  assert.equal(isEstimated({ cost: null, priced: 0 }, 5), false, 'nothing priced is nothing to mark');
  assert.equal(isEstimated(null, 5), false);

  // A cohort carries the API's counts and the judge's spend on it.
  const [replayed] = runCohorts({ scores: { _models: { a: { scenarios: 4, passed: 4, cost: 0.004, priced: 4, reported: 1, estimated: 3, judge_cost: 0.002, judge_calls: 4 } } } });
  assert.equal(replayed.estimated, true);
  assert.equal(replayed.reported, 1);
  assert.equal(replayed.judge_cost, 0.002);
  assert.equal(replayed.judge_calls, 4);
  // A sampling cohort's cost is always the runner's own estimate.
  const [sampled] = runCohorts({ scores: { _cohorts: { 'gpt-4o-mini': { samples: 12, cost: 0.0006 } } } });
  assert.equal(sampled.estimated, true);
});

test('a run names the version it scored, and movement says whether the run before scored the same one', () => {
  const current = { id: 3, agent_version: { id: 12, number: 12, release_digest: 'abc1234def', revision: 'deploy-7', release: true }, version_state: 'current' };
  const earlier = { id: 2, agent_version: { id: 11, number: 11, release: false }, version_state: 'earlier' };
  const unrecorded = { id: 1, agent_version: null, version_state: 'unrecorded' };

  assert.deepEqual(versionChip(current), { text: 'v12 · abc1234', tone: 'success', title: "The agent's current version · deploy-7" });
  assert.equal(versionChip(earlier).text, 'v11');
  assert.equal(versionChip(earlier).tone, 'muted');
  assert.equal(versionChip(unrecorded).text, 'release not recorded');
  assert.equal(versionChip(unrecorded).tone, 'warning');
  assert.equal(versionChip({ id: 9 }), null, 'an older server says nothing about versions');

  assert.deepEqual(versionDelta(current, { ...earlier, agent_version: current.agent_version }), { kind: 'same', text: 'same version' });
  assert.deepEqual(versionDelta(current, earlier), { kind: 'new', text: 'new version v12' });
  assert.deepEqual(versionDelta(current, unrecorded), { kind: 'unrecorded', text: 'release not recorded' });
  assert.equal(versionDelta(current, null), null);
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

test('a run says how its cost was priced, on both sides', () => {
  const judge = { calls: 2, cost: 0.003, by_kind: { score: 2 }, source: 'traces', estimated: true, run: { calls: 0, cost: null, by_kind: {} } };
  const spend = runSpend({ usage: { replays: 4, priced: 4, unpriced: 0, reported: 1, estimated: 3, cost_basis: 'mixed', cost: 0.04, total: 0.043, judge } });
  assert.equal(spend.agent.estimated, true);
  assert.equal(spend.agent.reported, 1);
  assert.equal(spend.agent.estimatedCount, 3);
  assert.equal(spend.agent.basis, 'mixed');
  assert.equal(spend.judge.source, 'traces');
  assert.equal(spend.judge.estimated, true);
  assert.deepEqual(spend.judge.run, { calls: 0, cost: null, by_kind: {} });
  assert.equal(judgeSourceText(spend.judge), 'from traces');
  assert.equal(spend.total, 0.043, "the API's total, when it gives one");
  assert.equal(spend.totalEstimated, true);

  const reported = runSpend({ usage: { replays: 4, priced: 4, reported: 4, estimated: 0, cost_basis: 'reported', cost: 0.04, judge: { calls: 1, cost: 0.001, by_kind: {}, source: 'reported', estimated: false } } });
  assert.equal(reported.agent.estimated, false);
  assert.equal(reported.judge.estimated, false);
  assert.equal(reported.totalEstimated, false);
  assert.equal(judgeSourceText(reported.judge), 'reported');

  // A usage from an older server: the engine's meter, an estimate.
  const older = runSpend({ usage: { replays: 8, cost: 0.44, judge: { calls: 24, cost: 0.12, by_kind: {} } } });
  assert.equal(older.agent.estimated, false, 'nothing says the agent side was estimated');
  assert.equal(older.judge.estimated, true);
  assert.equal(older.judge.source, null);
  assert.equal(judgeSourceText(older.judge), null);
});

test('a partially priced run spreads its cost over the priced interactions only, and reads as an estimate', () => {
  const partial = runSpend({ usage: { replays: 5, priced: 3, unpriced: 2, cost: 0.03, per_interaction: 0.01 } });
  assert.equal(partial.agent.count, 5);
  assert.equal(partial.agent.priced, 3);
  assert.equal(partial.agent.perInteraction, 0.01);
  assert.equal(partial.agent.estimated, true);
  assert.equal(partial.totalEstimated, true);

  // Without the API's rate, the same division is made here.
  const derived = runSpend({ usage: { samples: 4, priced: 2, cost: 0.004 } });
  assert.equal(derived.agent.perInteraction, 0.002);

  const none = runSpend({ usage: { replays: 2, priced: 0, unpriced: 2, input_tokens: 200 } });
  assert.equal(none.agent.cost, null);
  assert.equal(none.agent.priced, 0);
  assert.equal(none.agent.perInteraction, null);
  assert.equal(none.total, null);

  // A usage recorded before the counts: a cost covers every interaction.
  assert.equal(runSpend({ usage: { replays: 8, cost: 0.44 } }).agent.priced, 8);
});

test('the total says which sides it sums, and when the agent side could not be priced', () => {
  const judge = { calls: 3, cost: 0.004, by_kind: {} };
  const label = (usage) => spendTotalLabel(runSpend({ usage }));
  assert.equal(label({ replays: 5, priced: 5, cost: 0.05, judge }), 'agent + judge');
  assert.equal(label({ replays: 5, priced: 5, cost: 0.05 }), 'agent only');
  assert.equal(label({ judge }), 'judge only');
  assert.equal(label({ replays: 5, priced: 3, cost: 0.03, judge }), 'agent + judge', 'the "~" on the figure says it is an estimate');
  assert.equal(label({ replays: 2, priced: 0, judge }), 'judge only · agent unpriced');
  assert.equal(label({ replays: 2, priced: 0 }), 'agent unpriced');
  assert.equal(label({ replays: 8, cost: 0.44 }), 'agent only', 'a usage recorded before the counts is fully priced');
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
  assert.equal(summary.estimated, false);
  assert.equal(summary.judgeEstimated, true, 'a judge usage from an older server was the meter');
  assert.deepEqual(spendSummary([]), { agentCost: null, interactions: 0, pricedInteractions: 0, perInteraction: null, judgeCost: null, priced: 0, estimated: false, judgeEstimated: false });
});

test('the page rate is over the priced interactions when some went unpriced, and says it is an estimate', () => {
  const summary = spendSummary([
    { usage: { replays: 5, priced: 3, unpriced: 2, cost: 0.03 } },
    { usage: { samples: 4, priced: 0, unpriced: 4 } },
    { usage: { samples: 2, priced: 2, unpriced: 0, cost: 0.01 } },
  ]);
  assert.equal(summary.interactions, 11);
  assert.equal(summary.pricedInteractions, 5);
  assert.equal(summary.estimated, true);
  assert.ok(Math.abs(summary.agentCost - 0.04) < 1e-9);
  assert.ok(Math.abs(summary.perInteraction - 0.04 / 5) < 1e-9);
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
  assert.deepEqual(items[3].details, ['latency · b 62% · expects ≤ 5s · 6/12 · 50% passed']);
  assert.match(items[3].text, /pass ≥ 70%/);
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

test('a capped run list shows the latest runs, and keeps an older selected one', () => {
  const runs = [{ id: 9 }, { id: 8 }, { id: 7 }, { id: 6 }, { id: 5 }];
  assert.deepEqual(shownRunIndexes(runs, { limit: 3 }), [0, 1, 2]);
  assert.deepEqual(shownRunIndexes(runs, { limit: 3, selectedId: 5 }), [0, 1, 2, 4]);
  assert.deepEqual(shownRunIndexes(runs, { limit: 3, selectedId: 8 }), [0, 1, 2]);
  assert.deepEqual(shownRunIndexes(runs), [0, 1, 2, 3, 4]);
  assert.deepEqual(shownRunIndexes(runs.slice(0, 2), { limit: 3 }), [0, 1]);
});

test('a scenario reads as a build step of the run', () => {
  const columns = ['gpt-5-mini', 'claude-haiku-5-5'];
  const passed = { status: 'passed' };
  const failed = { status: 'failed' };
  const pending = { status: 'pending' };
  assert.equal(scenarioStep({}, columns, { inRun: false, running: true }), 'skipped');
  assert.equal(scenarioStep({}, columns, { inRun: true, running: true }), 'queued');
  assert.equal(scenarioStep({ 'gpt-5-mini': pending }, columns, { inRun: true, running: true }), 'running');
  assert.equal(scenarioStep({ 'gpt-5-mini': passed }, columns, { inRun: true, running: true }), 'running');
  assert.equal(scenarioStep({ 'gpt-5-mini': passed, 'claude-haiku-5-5': passed }, columns, { inRun: true, running: true }), 'passed');
  assert.equal(scenarioStep({ 'gpt-5-mini': passed, 'claude-haiku-5-5': failed }, columns, { inRun: true }), 'failed');
  assert.equal(scenarioStep({ 'gpt-5-mini': failed }, columns, { inRun: true, running: false }), 'failed');
  assert.equal(scenarioStep({ 'gpt-5-mini': passed }, columns, { inRun: true, running: false }), 'missing');
  assert.equal(scenarioStep({}, columns, { inRun: true, running: false }), 'missing');
});

test('the step list has a cursor', () => {
  // Suite order, with a passed row before the running one.
  const steps = [{ key: 'a', step: 'passed' }, { key: 'b', step: 'running' }, { key: 'c', step: 'queued' }, { key: 'd', step: 'running' }];
  assert.equal(currentStepKey(steps), 'b', 'the first running step, not the first step');
  assert.equal(currentStepKey([{ key: 'a', step: 'passed' }, { key: 'c', step: 'queued' }, { key: 'd', step: 'queued' }]), 'c', 'the first queued step when nothing is replaying');
  assert.equal(currentStepKey([{ key: 'a', step: 'passed' }, { key: 'b', step: 'failed' }]), null, 'a settled run has no cursor');
  assert.equal(currentStepKey([{ key: 'a', step: 'loading' }, { key: 'b', step: 'loading' }]), null, 'a result still being fetched is never the cursor');
  assert.equal(currentStepKey([]), null);
});

test('a group reads as one step', () => {
  assert.equal(groupStep([]), 'none');
  assert.equal(groupStep(['none', 'none']), 'none');
  assert.equal(groupStep(['skipped', 'skipped']), 'skipped');
  assert.equal(groupStep(['passed', 'passed']), 'passed');
  assert.equal(groupStep(['passed', 'failed']), 'failed');
  assert.equal(groupStep(['passed', 'queued']), 'running', 'queued and settled rows together are a group in progress');
  assert.equal(groupStep(['queued', 'queued']), 'queued');
  assert.equal(groupStep(['running', 'queued']), 'running');
  assert.equal(groupStep(['loading', 'loading']), 'loading');
  assert.equal(groupStep(['passed', 'missing']), 'missing');
  assert.equal(groupStep(['skipped', 'passed']), 'passed', 'skipped rows are ignored once any row is in the run');
  assert.equal(groupStep(['skipped', 'none']), 'skipped', 'a group outside a run reads skipped, not none');
});

test('failed-first keeps suite order inside the stable sort', () => {
  // Three groups with 0, 2 and 1 failures, in suite order; `ungrouped` has none.
  const rows = [
    { key: 'a1', group: 'Agents' }, { key: 'a2', group: 'Agents' },
    { key: 'e1', group: 'Evaluations' }, { key: 'e2', group: 'Evaluations' }, { key: 'e3', group: 'Evaluations' },
    { key: 'i1', group: 'Install' }, { key: 'i2', group: 'Install' },
    { key: 'u1' },
  ];
  const steps = { a1: 'passed', a2: 'passed', e1: 'passed', e2: 'failed', e3: 'failed', i1: 'passed', i2: 'failed', u1: 'passed' };
  const stepOf = (row) => steps[row.key];

  assert.equal(orderScenarioRows(rows, stepOf, 'suite'), rows, 'suite order is the input array itself');
  const ordered = orderScenarioRows(rows, stepOf, 'failed-first');
  assert.notEqual(ordered, rows);
  assert.deepEqual(ordered.map((row) => row.key), ['e2', 'e3', 'e1', 'i2', 'i1', 'a1', 'a2', 'u1']);
  assert.deepEqual(rows.map((row) => row.key), ['a1', 'a2', 'e1', 'e2', 'e3', 'i1', 'i2', 'u1'], 'the input is not reordered in place');

  // Groups with the same failed count keep their first-appearance order.
  const tied = orderScenarioRows(rows, (row) => (row.key === 'a2' || row.key === 'i2' ? 'failed' : 'passed'), 'failed-first');
  assert.deepEqual(tied.map((row) => row.key), ['a2', 'a1', 'i2', 'i1', 'e1', 'e2', 'e3', 'u1']);
});

test('groups outside a partial run start folded', () => {
  const scenarios = [{ key: 'a', group: 'Install' }, { key: 'b', group: 'Install' }, { key: 'c', group: 'Agents' }, { key: 'd' }];
  assert.deepEqual(groupsOutsideRun(scenarios.slice(0, 3), new Set(['a'])), new Set(['Agents']));
  assert.deepEqual(groupsOutsideRun(scenarios, new Set(['a'])), new Set(['Agents', '']), 'ungrouped scenarios count under the empty name');
  assert.deepEqual(groupsOutsideRun(scenarios, new Set(['b', 'd'])), new Set(['Agents']));
  assert.deepEqual(groupsOutsideRun(scenarios, new Set()), new Set(), 'a run that covers nothing folds nothing');
  assert.deepEqual(groupsOutsideRun(scenarios, ['c']), new Set(['Install', '']), 'an array of keys is read the same way');
});

test('a partial run says what it covered', () => {
  const scenarios = [...Array.from({ length: 100 }, (_, i) => ({ key: `s${i}`, enabled: true })), { key: 'off', enabled: false }];
  const keysOf = (count) => scenarios.slice(0, count).map((s) => s.key);
  assert.equal(runSelectionLabel({ selection: { group: 'Install & setup' } }, scenarios), 'partial: Install & setup');
  assert.equal(runSelectionLabel({ selection: { scenario_keys: keysOf(16) } }, scenarios), '16 of 100 scenarios');
  assert.equal(runSelectionLabel({ status: 'pending', selection: { keys: ['s1'] } }, scenarios), '1 of 100 scenarios');
  assert.equal(runSelectionLabel({ selection: { scenario_keys: keysOf(100) } }, scenarios), null, 'every enabled scenario is the whole suite');
  assert.equal(runSelectionLabel({ selection: { models: ['m'] } }, scenarios), null);
  assert.equal(runSelectionLabel(null, scenarios), null);
});

test('only enabled, present scenarios are replayed', () => {
  const scenarios = [{ key: 'a' }, { key: 'b', enabled: true }, { key: 'c', enabled: true }, { key: 'off', enabled: false }];
  assert.deepEqual(runnableKeys(['a', 'b', 'b', 'gone', 'off'], scenarios), { keys: ['a', 'b'], dropped: ['gone', 'off'] });
  assert.deepEqual(runnableKeys([], scenarios), { keys: [], dropped: [] });

  const results = [
    { scenario_key: 'a', status: 'passed' },
    { scenario_key: 'off', status: 'failed' },
    { scenario_key: 'b', status: 'errored' },
    { scenario_key: 'a', status: 'failed' },
    { scenario_key: 'b', status: 'failed' },
    { scenario_key: 'c', status: 'pending' },
  ];
  assert.deepEqual(rerunFailedKeys(results, scenarios), { keys: ['b', 'a'], dropped: ['off'] }, 'failed and errored keys in first-appearance order; pending is not a failure');
  assert.deepEqual(rerunFailedKeys([], scenarios), { keys: [], dropped: [] });

  assert.deepEqual(runRequestSelection({ selection: { group: 'Install' } }, scenarios), { group: 'Install' });
  assert.deepEqual(runRequestSelection({ selection: { scenario_keys: ['a', 'off', 'gone'] } }, scenarios), { keys: ['a'] });
  assert.deepEqual(runRequestSelection({ status: 'pending', selection: { keys: ['b', 'off'] } }, scenarios), { keys: ['b'] });
  assert.deepEqual(runRequestSelection({ selection: { models: ['m'] } }, scenarios), {});
  assert.deepEqual(runRequestSelection(null, scenarios), {});
});

test('a run that failed before resolving its selection still covers the suite', () => {
  const scenarios = [{ id: 1, key: 'a', group: 'Install' }, { id: 2, key: 'b', group: 'Agents', enabled: false }, { id: 3, key: 'c', group: 'Agents' }];
  assert.deepEqual(runScenarioKeys({ status: 'failed', selection: { models: ['m'] } }, scenarios), ['a', 'c']);
  assert.deepEqual(runScenarioKeys({ status: 'failed', selection: { models: ['m'] } }, scenarios.slice(0, 2)), ['a']);
  assert.deepEqual(runScenarioKeys({ status: 'complete', selection: { models: ['m'] } }, scenarios), [], 'a complete run with nothing recorded covered nothing');
  assert.deepEqual(runScenarioKeys({ status: 'failed', selection: { keys: ['b'] } }, scenarios), ['b'], 'recorded keys still win');
  assert.deepEqual(runScenarioKeys({ status: 'running', selection: { models: ['m'] } }, scenarios), ['a', 'c']);
  assert.deepEqual(runScenarioKeys({ status: 'complete', scores: { _selection: { scenario_keys: ['c'] } } }, scenarios), ['c']);
  assert.deepEqual(runScenarioKeys({ status: 'pending', selection: { group: 'Agents' } }, scenarios), ['c']);
  assert.deepEqual(runScenarioKeys({ status: 'pending', selection: { scenario_ids: [3, '1'] } }, scenarios), ['a', 'c']);
  assert.deepEqual(runScenarioKeys(null, scenarios), []);

  assert.deepEqual(selectionOf({ scores: { _selection: { group: 'g' } } }), { group: 'g' });
  assert.deepEqual(selectionOf(null), {});
  assert.deepEqual(selectionModelLabels({ selection: { models: ['x', { label: 'y', model: 'y-1' }, { model: 'unlabelled' }] } }), ['x', 'y']);
});

test('elapsed and duration', () => {
  const created = '2026-01-05T10:00:00Z';
  const completed = '2026-01-05T10:12:04Z';
  const now = Date.parse(created) + 134000;
  assert.equal(runElapsedMs({ status: 'complete', created_at: created, completed_at: completed, usage: { runtime_ms: 700000 } }, now), 700000, 'the recorded runtime wins');
  assert.equal(runElapsedMs({ status: 'complete', created_at: created, completed_at: completed, usage: {} }, now), 724000);
  assert.equal(runElapsedMs({ status: 'running', created_at: created }, now), 134000);
  assert.equal(runElapsedMs({ status: 'pending', created_at: created }, now), null);
  assert.equal(runElapsedMs({ status: 'failed', created_at: created, completed_at: completed }, now), null);
  assert.equal(runElapsedMs({ status: 'running' }, now), null);
  assert.equal(runElapsedMs(null, now), null);

  assert.equal(fmtClock(134000), '02:14');
  assert.equal(fmtClock(3734000), '1:02:14');
  assert.equal(fmtClock(0), '00:00');
  assert.equal(fmtClock(null), '—');
  assert.equal(fmtDuration(58000), '58s');
  assert.equal(fmtDuration(724000), '12m 04s');
  assert.equal(fmtDuration(3720000), '1h 02m');
  assert.equal(fmtDuration(null), '—');
});

test('polls back off with the result count', () => {
  assert.equal(pollIntervalFor(0), 3000);
  assert.equal(pollIntervalFor(500), 3000);
  assert.equal(pollIntervalFor(501), 6000);
  assert.equal(pollIntervalFor(2000), 6000);
  assert.equal(pollIntervalFor(2001), 10000);
  assert.equal(pollIntervalFor(undefined), 3000);
});

test('a poll keeps the identity of results that did not change', () => {
  const a = { id: 1, scenario_key: 'a', model: 'm', status: 'passed', score: 0.9, fault: null, cost: 0.001, judge_usage: { cost: 0.002 }, output: 'hello' };
  const b = { id: 2, scenario_key: 'b', model: 'm', status: 'pending', score: null, fault: null, cost: null, judge_usage: null, output: null };

  const unchanged = reconcileResults([a, b], [{ ...a, output: 'world' }, { ...b }]);
  assert.equal(unchanged.changed, false, 'the same length and content, output text aside');
  assert.equal(unchanged.results[0], a);
  assert.equal(unchanged.results[1], b);

  const landed = reconcileResults([a, b], [{ ...a }, { ...b, status: 'passed', score: 1, output: 'done' }]);
  assert.equal(landed.changed, true);
  assert.equal(landed.results[0], a, 'the untouched result keeps its object');
  assert.notEqual(landed.results[1], b, 'pending → passed is a new object');
  assert.equal(landed.results[1].status, 'passed');

  const grown = reconcileResults([a], [{ ...a }, { ...b }]);
  assert.equal(grown.changed, true, 'a result landing is a change');
  assert.deepEqual([grown.results[0], grown.results.length], [a, 2]);
  assert.deepEqual(reconcileResults([], []), { results: [], changed: false });
  assert.deepEqual(reconcileResults(undefined, [a]), { results: [a], changed: true });

  assert.equal(sameResult(a, { ...a, output: 'hello!' }), false, 'a longer output is a change');
  assert.equal(sameResult(a, { ...a, judge_usage: { cost: 0.003 } }), false);
  assert.equal(sameResult(a, { ...a, cost: 0.0011 }), false);
  assert.equal(sameResult(a, { ...a, fault: 'late' }), false);
  assert.equal(sameResult(a, { ...a, id: 9 }), false);
  assert.equal(sameResult(b, { ...b, judge_usage: undefined }), true, 'no judge cost either way');

  const labelFor = (result) => result.model;
  const first = groupResultsByKey([a, b], labelFor);
  assert.deepEqual(Object.keys(first), ['a', 'b']);
  assert.equal(first.a.m, a);
  const second = groupResultsByKey([a, b], labelFor, first);
  assert.equal(second, first, 'nothing changed: the map itself');
  const b2 = { ...b, status: 'passed' };
  const third = groupResultsByKey([a, b2], labelFor, first);
  assert.notEqual(third, first);
  assert.equal(third.a, first.a, 'a key whose results are identical keeps its object');
  assert.notEqual(third.b, first.b);
  assert.equal(third.b.m, b2);
  const c = { id: 3, scenario_key: 'a', model: 'n', status: 'passed' };
  const fourth = groupResultsByKey([a, c], labelFor, first);
  assert.notEqual(fourth.a, first.a, 'a key that gained a column is new');
  assert.deepEqual(Object.keys(fourth.a), ['m', 'n']);
  assert.deepEqual(groupResultsByKey([{ id: 4, status: 'passed' }], labelFor), {}, 'a result without a scenario key is skipped');

  const bars = [1, 2, 3].map((n) => ({ label: `m${n}`, short: `m${n}`, passed: n, total: 10 }));
  assert.equal(combinedBars(bars), bars, 'three bars are left alone');
  const four = [...bars, { label: 'm4', short: 'm4', passed: 4, total: 10 }];
  assert.deepEqual(combinedBars(four), [{ label: 'combined', short: '4 models', passed: 10, total: 40, title: 'm1 1/10 · m2 2/10 · m3 3/10 · m4 4/10' }]);
  assert.equal(combinedBars(four, 4), four);
});

test("the box's scroll targets", () => {
  assert.equal(cursorScrollTop({ rowTop: 1000, headerHeight: 50, boxHeight: 530 }), 790);
  assert.equal(cursorScrollTop({ rowTop: 100, headerHeight: 50, boxHeight: 530 }), 0, 'clamped at the top');
  assert.equal(openRowScrollTop({ rowTop: 1000, headerHeight: 50, groupRowHeight: 36 }), 914);
  assert.equal(openRowScrollTop({ rowTop: 1000, headerHeight: 50 }), 950, 'no group row to leave room for');
  assert.equal(openRowScrollTop({ rowTop: 20, headerHeight: 50 }), 0, 'clamped at the top');
});

test('the remembered detail level is validated', () => {
  assert.equal(readDetailChoice({ getItem: () => 'tools' }), 'tools');
  assert.equal(readDetailChoice({ getItem: () => 'steps' }), 'steps');
  assert.equal(readDetailChoice({ getItem: () => 'light' }), null, "the harness's stub answers every key with the theme");
  assert.equal(readDetailChoice({ getItem: () => null }), null);
  assert.equal(readDetailChoice({ getItem: () => { throw new Error('blocked'); } }), null);
  assert.equal(readDetailChoice(null), null);
  assert.equal(readDetailChoice(undefined), null);

  const stored = {};
  const storage = { setItem: (key, value) => { stored[key] = value; }, removeItem: (key) => { delete stored[key]; } };
  writeDetailChoice(storage, 'tools');
  assert.deepEqual(stored, { [DETAIL_STORAGE_KEY]: 'tools' });
  assert.equal(DETAIL_STORAGE_KEY, 'aa.evaluations.detail');
  writeDetailChoice(storage, null);
  assert.deepEqual(stored, {}, 'null forgets the choice');
  assert.doesNotThrow(() => writeDetailChoice({ setItem: () => { throw new Error('quota'); } }, 'steps'));
  assert.doesNotThrow(() => writeDetailChoice({ setItem() {} }, null), 'a storage without removeItem is left alone');
  assert.doesNotThrow(() => writeDetailChoice(null, 'steps'));
});

test('the details cache keeps only what the person can get back to', () => {
  const details = { 1: { id: 1 }, 2: { id: 2 }, 3: { id: 3 }, 4: { id: 4 } };
  const kept = keepDetails(details, [4, 1, null, 4]);
  assert.deepEqual(Object.keys(kept), ['1', '4']);
  assert.equal(kept[4], details[4]);
  assert.equal(keepDetails(details, [1, 2, 3, 4]), details, 'nothing to evict keeps the map itself');
  assert.deepEqual(keepDetails(details, []), {});
  assert.deepEqual(keepDetails(undefined, [1]), {});

  const columns = ['gpt-5-mini', 'claude-haiku-5-5'];
  assert.equal(scenarioTime({ 'gpt-5-mini': { status: 'passed', duration_ms: 5200 }, 'claude-haiku-5-5': { status: 'failed', duration_ms: 5900 } }, columns), 5900);
  assert.equal(scenarioTime({ 'gpt-5-mini': { status: 'pending', duration_ms: 9000 }, 'claude-haiku-5-5': { status: 'passed', duration_ms: 1200 } }, columns), 1200, 'a pending result has no time yet');
  assert.equal(scenarioTime({ 'gpt-5-mini': { status: 'passed' } }, columns), null);
  assert.equal(scenarioTime({}, columns), null);
  assert.equal(scenarioTime(undefined, columns), null);
  assert.equal(scenarioTime({ other: { status: 'passed', duration_ms: 1 } }, columns), null, 'only the given columns count');

  assert.equal(stepsMinWidth(2), 644);
  assert.equal(toolsMinWidth(2), 844);
  assert.equal(stepsMinWidth(3), 782);
  assert.ok(RAIL_WIDTH + RAIL_GAP + stepsMinWidth(2) <= RAIL_BREAKPOINT, 'a two-model steps grid fits beside the rail at the breakpoint');

  // The figures the panel, the rail and the box share.
  assert.deepEqual(
    { PANEL_GUTTER, STEPS_HEIGHT, STRIP_LIST_HEIGHT, RAIL_BARS_MAX, DETAILS_KEPT, KEY_COLUMN_MIN_WIDTH },
    { PANEL_GUTTER: 32, STEPS_HEIGHT: 'clamp(360px, calc(100vh - 240px), 900px)', STRIP_LIST_HEIGHT: 320, RAIL_BARS_MAX: 3, DETAILS_KEPT: 4, KEY_COLUMN_MIN_WIDTH: 720 },
  );
});

test('a step carries each answer\'s time and tokens, and the box adds them up per model, per group and per scenario', () => {
  const columns = ['gpt-5-mini', 'claude-haiku-5-5'];
  const settled = { status: 'passed', duration_ms: 5200, input_tokens: 1200, output_tokens: 340 };

  assert.deepEqual(resultMetrics(settled), { durationMs: 5200, inputTokens: 1200, outputTokens: 340 });
  assert.deepEqual(resultMetrics({ status: 'failed', duration_ms: '820' }), { durationMs: 820, inputTokens: null, outputTokens: null }, 'a figure the API sent as a string still counts');
  assert.equal(resultMetrics({ status: 'pending', duration_ms: 9000, input_tokens: 1 }), null, 'a pending result has nothing to show yet');
  assert.equal(resultMetrics({ status: 'passed' }), null, 'nothing recorded, nothing shown');
  assert.equal(resultMetrics(undefined), null);

  assert.deepEqual(
    sumMetrics([settled, { status: 'failed', duration_ms: 2100, input_tokens: 900, output_tokens: 120 }, { status: 'pending', duration_ms: 1 }, undefined]),
    { durationMs: 7300, inputTokens: 2100, outputTokens: 460, count: 2 },
  );
  assert.deepEqual(sumMetrics([{ status: 'passed', duration_ms: 400 }, { status: 'passed', duration_ms: 600 }]), { durationMs: 1000, inputTokens: null, outputTokens: null, count: 2 }, 'a sum nobody recorded stays null, not 0');
  assert.equal(sumMetrics([{ status: 'pending' }, undefined]), null);
  assert.equal(sumMetrics([]), null);

  const row = { 'gpt-5-mini': settled, 'claude-haiku-5-5': { status: 'failed', duration_ms: 2100, input_tokens: 900, output_tokens: 120 } };
  assert.deepEqual(scenarioTokens(row, columns), { input: 2100, output: 460 });
  assert.deepEqual(scenarioTokens({ 'gpt-5-mini': { status: 'passed', output_tokens: 50 } }, columns), { input: null, output: 50 });
  assert.equal(scenarioTokens({ 'gpt-5-mini': { status: 'passed', duration_ms: 400 } }, columns), null, 'a time alone is not a token count');
  assert.equal(scenarioTokens({ other: settled }, columns), null, 'only the given columns count');
  assert.equal(scenarioTokens(undefined, columns), null);

  assert.deepEqual(sumTokens([{ input: 2100, output: 460 }, null, { input: 2000, output: 500 }]), { input: 4100, output: 960 });
  assert.deepEqual(sumTokens([{ input: null, output: 50 }, { input: null, output: 20 }]), { input: null, output: 70 });
  assert.equal(sumTokens([null, undefined]), null);
  assert.equal(sumTokens([]), null);

  const resultsByKey = {
    t1: row,
    t2: { 'gpt-5-mini': { status: 'passed', duration_ms: 65000, input_tokens: 2000, output_tokens: 500 }, 'claude-haiku-5-5': { status: 'pending' } },
    t3: { 'gpt-5-mini': { status: 'passed', duration_ms: 100 } },
  };
  assert.deepEqual(columnTotals(resultsByKey, columns), {
    'gpt-5-mini': { durationMs: 70300, inputTokens: 3200, outputTokens: 840, count: 3 },
    'claude-haiku-5-5': { durationMs: 2100, inputTokens: 900, outputTokens: 120, count: 1 },
  }, 'the run: every key');
  assert.deepEqual(columnTotals(resultsByKey, columns, ['t2', 't3']), {
    'gpt-5-mini': { durationMs: 65100, inputTokens: 2000, outputTokens: 500, count: 2 },
    'claude-haiku-5-5': null,
  }, 'a group: its keys, and null for a model with nothing in');
  assert.deepEqual(columnTotals({}, columns), { 'gpt-5-mini': null, 'claude-haiku-5-5': null });

  const rows = [{ key: 't1' }, { key: 't2' }, { key: 't3' }, { key: 'missing' }];
  assert.equal(groupTime(rows, resultsByKey, columns), 5200 + 65000 + 100, 'each scenario\'s slowest answer, added up');
  assert.equal(groupTime([{ key: 'missing' }], resultsByKey, columns), null);
  assert.equal(groupTime([], resultsByKey, columns), null);

  assert.equal(fmtSpan(820), '820ms');
  assert.equal(fmtSpan(5200), '5.2s');
  assert.equal(fmtSpan(5250), '5.25s');
  assert.equal(fmtSpan(12400), '12.4s');
  assert.equal(fmtSpan(59999), '60s');
  assert.equal(fmtSpan(65000), '1m 05s');
  assert.equal(fmtSpan(70200), '1m 10s');
  assert.equal(fmtSpan(3_720_000), '1h 02m');
  assert.equal(fmtSpan(null), '—');
  assert.equal(fmtSpan('x'), '—');

  assert.equal(fmtTokenIO(1200, 340), '1.2K→340');
  assert.equal(fmtTokenIO(null, 50), '—→50');
  assert.equal(fmtTokenIO(2_400_000, null), '2.4M→—');
  assert.equal(fmtTokenIO(null, null), '—');
  assert.equal(fmtTokenIO(undefined, undefined), '—');
});

test('a run\'s results are read against the same scenario and model in the run before', () => {
  const result = (status, score) => ({ status, score });
  const now = {
    a: { sonnet: result('passed', 0.98), haiku: result('failed', 0.6) },
    b: { sonnet: result('errored', 0), haiku: result('passed', 0.94) },
    c: { sonnet: result('passed', 0.9), haiku: result('pending') },
    d: { sonnet: result('failed', 0.5) },
    e: { sonnet: result('passed', 0.97) },
  };
  const before = {
    a: { sonnet: result('failed', 0.54), haiku: result('passed', 0.93) },
    b: { sonnet: result('passed', 0.96), haiku: result('passed', 0.9) },
    c: { sonnet: result('passed', 0.95), haiku: result('failed', 0.4) },
    d: { sonnet: result('errored', 0) },
  };
  const changes = resultChanges(now, before, ['sonnet', 'haiku']);

  assert.deepEqual(
    Object.fromEntries(Object.entries(changes.byKey).map(([key, cells]) => [key, Object.fromEntries(Object.entries(cells).map(([label, c]) => [label, c.kind]))])),
    { a: { sonnet: 'improved', haiku: 'regressed' }, b: { sonnet: 'errored' } },
    'a pending result, an earlier error and a scenario the earlier run did not cover are not changes',
  );
  assert.equal(changes.byKey.a.haiku.was, before.a.haiku, 'a change carries the earlier result');
  assert.deepEqual([changes.improved, changes.regressed, changes.errored], [1, 1, 1]);
  assert.deepEqual(resultChanges(now, {}, ['sonnet']), { byKey: {}, improved: 0, regressed: 0, errored: 0 });
});

test('the changed chip counts each kind of change that happened', () => {
  assert.equal(changesText({ improved: 6, regressed: 5, errored: 4 }), ' · ▲6 ▼5 ○4');
  assert.equal(changesText({ improved: 0, regressed: 2, errored: 0 }), ' · ▼2');
  assert.equal(changesText({ improved: 0, regressed: 0, errored: 0 }), '');
});
