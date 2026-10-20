import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { runSpend } from '../utils/evaluationRuns.mjs';

// The run views are .jsx, so this suite bundles them with esbuild and renders
// them to static markup. Effects do not run in a server render, so each view
// renders from its props alone and fetches nothing: a suite's scenarios come
// from `evaluation.scenarios` (the show payload carries them) and its run's
// results from `evaluation.latest_run.results`.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/evaluation-run-order-${process.pid}.mjs`, import.meta.url));
const at = '2026-01-05T10:00:00Z';

let render;
// The panel's bar recipe (one bar per model of a run), for a rail rendered
// on its own with the bars the panel would give it.
let runBars;

// ThemeProvider reads the saved theme while it renders (and readDetailChoice
// the remembered detail level): the stub answers 'light' to every key, so a
// remembered level has to be validated before it counts.
const storageStub = (getItem = () => 'light') => ({ getItem, setItem() {}, removeItem() {} });

before(async () => {
  // dashboardPath reads the engine's mount path off window.
  Object.defineProperty(globalThis, 'localStorage', { value: storageStub(), configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: {}, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import ScenarioSuitePanel from './components/dashboard/ScenarioSuitePanel.jsx';
        import EvaluationRunDetail from './components/dashboard/evaluations/EvaluationRunDetail.jsx';
        import RunsList, { RunRail } from './components/dashboard/evaluations/RunsList.jsx';
        import RunHeader from './components/dashboard/evaluations/RunHeader.jsx';
        import { runBars } from './components/dashboard/EvaluationRunPanels.jsx';

        const views = { ScenarioSuitePanel, EvaluationRunDetail, RunsList, RunRail, RunHeader };
        export const render = (name, props) =>
          renderToStaticMarkup(React.createElement(ThemeProvider, null, React.createElement(views[name], props)));
        export { runBars };
      `,
      resolveDir: root,
      loader: 'jsx',
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'node',
    external: ['react', 'react-dom', 'react-dom/server'],
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  ({ render, runBars } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

// Asserts that every marker is in the markup, in the order given.
function assertInOrder(html, markers) {
  const found = markers.map((marker) => html.indexOf(marker));
  markers.forEach((marker, index) => assert.ok(found[index] >= 0, `${marker} is missing`));
  assert.deepEqual([...found].sort((a, b) => a - b), found, `the sections read ${markers.join(', then ')}`);
}

const count = (html, pattern) => (html.match(pattern) || []).length;
// The markup between two markers (to the end when `to` is absent).
const between = (html, from, to) => {
  const start = html.indexOf(from);
  assert.ok(start >= 0, `${from} is missing`);
  const end = to ? html.indexOf(to, start) : -1;
  return end >= 0 ? html.slice(start, end) : html.slice(start);
};

const spec = { label: 'gpt-5-mini', provider: 'openai', model: 'gpt-5-mini' };
const scenarioA = { id: 1, key: 'a', prompt: 'Where is order 4821?', group: null, enabled: true, expectations: { tools: ['lookup_order'] } };
const scenarioB = { id: 2, key: 'b', prompt: 'Cancel my subscription', group: null, enabled: true, expectations: {} };
const result = (key, status, extra = {}) => ({
  id: key.charCodeAt(0), scenario_key: key, prompt: key === 'a' ? scenarioA.prompt : scenarioB.prompt, model: 'gpt-5-mini', provider: 'openai', status, ...extra,
});
const suite = (latestRun, extra = {}) => ({
  evaluation: { id: 1, name: 'Support suite', agent: { name: 'SupportAgent' }, scenario_groups: [], scenarios: [scenarioA, scenarioB], latest_run: latestRun, ...extra },
  modelProviders: null,
});

test('a scenario suite reads its run header, then its runs, then the scenario results, then models, then what to fix', () => {
  const run = {
    id: 7,
    status: 'complete',
    created_at: at,
    completed_at: at,
    samples_evaluated: 1,
    samples_passed: 0,
    selection: { scenario_keys: ['orders_1'], models: [spec] },
    scores: {},
    usage: { replays: 1, cost: 0.0016, judge: { calls: 1, cost: 0.001, by_kind: {} } },
    results: [{
      scenario_key: 'orders_1', prompt: 'Where is order 4821?', model: 'gpt-5-mini', provider: 'openai',
      status: 'failed', fault: 'expected_tool_not_called', score: 0.4, tool_calls: [],
    }],
    fix_items: [{
      kind: 'fault', fault: 'expected_tool_not_called', count: 1, scenario_keys: ['orders_1'], models: ['gpt-5-mini'],
      recommendation: 'Enable lookup_order for the agent.', quote: null, tools_label: 'missing tools',
      tools: [{ name: 'lookup_order', note: null, server: null }], server: null, note: null, action: null,
    }],
  };
  const html = render('ScenarioSuitePanel', {
    evaluation: { id: 1, name: 'Support suite', agent: { name: 'SupportAgent' }, latest_run: run, scenario_groups: [] },
    modelProviders: null,
  });

  assertInOrder(html, [
    'data-testid="suite-run-header"', 'data-testid="suite-runs-panel"', 'data-testid="scenario-row"', 'data-testid="suite-models-panel"', 'data-testid="fix-list"',
  ]);
  assert.match(html, /data-step="failed"/, 'a settled failure reads as a failed step');
  assert.match(html, /data-testid="run-spend-agent"/, 'the agent cost is a header cell');
  assert.match(html, /Run #1</);
  assert.match(html, /data-layout="rail"/, 'an unmeasured panel keeps the rail');
  assert.match(html, /data-detail="steps"/, 'every suite opens as one-line steps');
  assert.doesNotMatch(html, /suite-run-spend/, 'the SpendStrip left the suite');
  assert.doesNotMatch(html, /scenario-cell-cost/, 'a steps row carries no per-cell cost');
  assert.match(between(html, 'data-testid="criteria-footer"'), /total/, 'the footer spend line carries the run total');

  // One Tab stop per container — one rail row, one box row — and the header's
  // TO FIX tile, a button by contract: three in all.
  assert.equal(count(html, /tabindex="0"/g), 3);
  const header = between(html, 'data-testid="suite-run-header"', 'data-testid="suite-detail-toggle"');
  assert.equal(count(header, /tabindex="0"/g), 1);
  assert.match(header, /data-testid="suite-to-fix"[^>]*tabindex="0"/, "the TO FIX tile is the header's only Tab stop");
  assert.equal(count(between(html, 'data-testid="suite-runs-panel"', 'data-testid="scenario-matrix"'), /tabindex="0"/g), 1);
  assert.equal(count(between(html, 'data-testid="scenario-matrix"', 'data-testid="suite-models-panel"'), /tabindex="0"/g), 1);
});

test('a sampling run reads its scorecards, then the criteria, then what to fix', () => {
  const run = {
    id: 3,
    status: 'complete',
    created_at: at,
    completed_at: at,
    samples_evaluated: 4,
    samples_passed: 3,
    scores: { response_present: { score: 0.5, passed: 2, total: 4 } },
  };
  const html = render('EvaluationRunDetail', {
    evaluation: { id: 2, name: 'Sampled replies', agent: { id: 5, name: 'SupportAgent' }, criteria: [] },
    runs: [run],
    runId: 3,
  });

  assertInOrder(html, ['data-testid="model-scorecard"', 'data-testid="criteria-matrix"', 'data-testid="fix-item"']);
});

test('a run whose results have not landed reads as loading', () => {
  const html = render('ScenarioSuitePanel', suite({
    id: 7, status: 'complete', created_at: at, completed_at: at, samples_evaluated: 1, samples_passed: 1,
    selection: { scenario_keys: ['a'], models: [spec] }, scores: {},
  }));

  assert.match(html, /data-scenario-key="a" data-step="loading"/);
  assert.match(html, /data-scenario-key="b" data-step="skipped"/);
  assert.doesNotMatch(html, /data-step="missing"/, 'results still being fetched never read as missing');
  assert.match(html, /data-testid="scenario-step" title="loading results…"/, 'the glyph says what it waits for');
  assert.doesNotMatch(html, /\[\?\]/, 'nothing reads as a result the run never produced');
  assert.match(between(html, 'data-scenario-key="a"', 'data-scenario-key="b"'), />…</, 'a cell waiting for its result reads …');
  assert.match(between(html, 'data-testid="suite-to-fix"', 'data-testid="suite-detail-toggle"'), /loading…/);
  assert.doesNotMatch(html, /suite-rerun-failed/);
  const failedOnly = between(html, 'data-testid="suite-failed-only"', '</button>');
  assert.match(failedOnly, /\[ \] failed only$/, 'the failed-only count waits for the results');
  assert.doesNotMatch(failedOnly, /·/);
  assert.match(between(html, 'data-testid="suite-run-passed"', 'data-testid="suite-run-models"'), /1\/1 · 100%/, 'PASSED reads from the summary');
  assert.doesNotMatch(between(html, 'data-testid="suite-run-models"', 'data-testid="run-spend-agent"'), /0\/1/, 'no per-model count is claimed before the results land');
  assert.match(html, /\[ \] loading…/, 'What to fix waits for the results');
});

test('a running run reads as a build in progress', () => {
  const html = render('ScenarioSuitePanel', suite({
    id: 8, status: 'running', created_at: at, selection: { scenario_keys: ['a', 'b'], models: [spec] }, scores: {},
    results: [result('a', 'passed', { score: 0.9, tool_calls: ['lookup_order'] }), result('b', 'pending')],
  }));

  assertInOrder(html, ['data-testid="suite-run-header"', 'data-testid="suite-run-progress-bar"', 'data-testid="suite-runs-panel"']);
  assert.match(html, /data-step="passed"/);
  assert.match(html, /data-step="running"/);
  assert.equal(count(html, /data-current="true"/g), 1);
  assert.match(html, /data-scenario-key="b"[^>]*data-current="true"/, 'the cursor sits on the step being replayed');
  assert.match(between(html, 'data-testid="suite-follow"', '</button>'), /\[x\] follow/);
  const passed = between(html, 'data-testid="suite-run-passed"', 'data-testid="suite-run-models"');
  assert.match(passed, /1 passed/);
  assert.match(passed, /data-testid="suite-run-progress"[^>]*>1 of 2 results in</);
  assert.match(between(html, 'data-testid="suite-to-fix"', 'data-testid="suite-detail-toggle"'), /scoring…/);
  assert.match(between(html, 'data-testid="run-spend-agent"', 'data-testid="run-spend-judge"'), /priced when the run completes/);
  const orderChip = between(html, 'data-testid="suite-order-toggle"', '</button>');
  assert.match(orderChip, /title="applies once the run completes"/);
  assert.match(orderChip, /opacity:0\.5/);

  // The box's one Tab stop is the cursor row: nothing is open and nothing has had focus.
  const box = between(html, 'data-testid="scenario-matrix"', 'data-testid="suite-models-panel"');
  assert.equal(count(box, /tabindex="0"/g), 1);
  assert.match(box, /data-scenario-key="b"[^>]*tabindex="0"/);
});

test('a run that failed before replaying hides the models and fixes', () => {
  const failed = {
    id: 9, status: 'failed', created_at: at, error_message: 'Provider refused: rate limited',
    selection: { scenario_keys: ['a'], models: [spec] }, results: [],
  };
  const html = render('ScenarioSuitePanel', suite(failed));

  const header = between(html, 'data-testid="suite-run-header"', 'data-testid="suite-runs-panel"');
  assert.match(header, /data-testid="suite-run-error"[^>]*>\[!\] Provider refused/);
  assert.match(header, /data-testid="suite-run-badge"[^>]*>failed</);
  assert.match(html, /data-scenario-key="a" data-step="missing"/);
  assert.match(html, /data-scenario-key="b" data-step="skipped"/);
  assert.doesNotMatch(html, /suite-models-panel/);
  assert.doesNotMatch(html, /fix-list/);
  assert.doesNotMatch(html, /suite-order-toggle/);
  const rail = between(html, 'data-testid="suite-runs-panel"', 'data-testid="scenario-matrix"');
  assert.match(rail, /\[!\] Provider refused/);

  // Nothing was replayed, so no bar claims a count: the MODELS tile draws a
  // dash per model, the rail row's error line stands where its bars would,
  // and the box's column header names the model alone. TO FIX, with no
  // What to fix to open, is a figure rather than a button.
  const models = between(html, 'data-testid="suite-run-models"', 'data-testid="run-spend-agent"');
  assert.doesNotMatch(models, /\d+\/\d+</, 'a run that never replayed shows no 0/n');
  assert.match(models, />—</);
  assert.doesNotMatch(rail, /\d+\/\d+</);
  assert.doesNotMatch(between(html, 'data-testid="scenario-matrix"', 'data-testid="scenario-row"'), /\d+\/\d+</);
  assert.doesNotMatch(between(header, 'data-testid="suite-to-fix"', '</div>'), /tabindex|role="button"/);
  assert.equal(count(header, /tabindex="0"/g), 0);

  // A selection the runner never resolved still covers the whole suite.
  const unresolved = render('ScenarioSuitePanel', suite({ ...failed, selection: { models: ['gpt-5-mini'] } }));
  assert.match(unresolved, /data-scenario-key="a" data-step="missing"/);
  assert.match(unresolved, /data-scenario-key="b" data-step="missing"/);
  assert.match(between(unresolved, 'data-testid="suite-run-header"', 'data-testid="suite-runs-panel"'), /2 scenarios/);
  assert.doesNotMatch(between(unresolved, 'data-testid="suite-run-models"', 'data-testid="run-spend-agent"'), /\d+\/\d+</, 'nor does a run of the whole suite that never started it');
});

test("a running run's strip card draws what failed so far, and a run's bars read from what it recorded", () => {
  const scenarioC = { id: 3, key: 'c', prompt: 'Refund order 4821', group: null, enabled: true, expectations: {} };
  const catalog = [scenarioA, scenarioB, scenarioC];
  const barsFor = (run) => runBars(run, run.results || [], railEvaluation, catalog);
  const running = {
    id: 13, status: 'running', created_at: at, selection: { scenario_keys: ['a', 'b', 'c'], models: [spec] }, scores: {},
    results: [result('a', 'passed', { score: 0.9 }), result('b', 'failed', { score: 0.4, fault: 'expected_tool_not_called' }), result('c', 'pending')],
  };
  assert.deepEqual(barsFor(running), [{ label: 'gpt-5-mini', short: 'gpt-5-mini', passed: 1, failed: 1, total: 3 }]);

  const html = render('RunRail', { runs: [running], evaluation: railEvaluation, layout: 'strip', limit: 3, selectedId: 13, barsFor });
  const bar = between(html, 'data-testid="evaluation-run-progress"', '</div>');
  assert.match(bar, /title="1 of 3 passed so far · 1 failed"/);
  const widths = [...bar.matchAll(/width:([\d.]+)%/g)].map((match) => Number(match[1]));
  assert.equal(widths.length, 2, 'a passed part and a failed part');
  assert.ok(widths.every((width) => width > 0), `both parts are drawn: ${widths.join(', ')}`);

  // From the summary once the run is complete; nothing at all for a model a
  // failed run never reached.
  assert.deepEqual(
    barsFor({ id: 8, status: 'complete', scores: { _models: { 'gpt-5-mini': { scenarios: 3, passed: 2 } } } }),
    [{ label: 'gpt-5-mini', short: 'gpt-5-mini', passed: 2, failed: 1, total: 3 }],
  );
  assert.deepEqual(
    barsFor({ id: 9, status: 'failed', selection: { models: [spec] }, scores: {}, results: [] }),
    [{ label: 'gpt-5-mini', short: 'gpt-5-mini', passed: null, failed: null, total: null }],
  );
});

test("the run total closes the suite's spend line only; the sampling run page has its TOTAL tile", () => {
  const run = {
    id: 3, status: 'complete', created_at: at, completed_at: at, samples_evaluated: 4, samples_passed: 3,
    scores: { response_present: { score: 0.5, passed: 2, total: 4 } },
    usage: { samples: 4, cost: 0.44, judge: { calls: 24, cost: 0.12, by_kind: {} } },
  };
  const html = render('EvaluationRunDetail', {
    evaluation: { id: 2, name: 'Sampled replies', agent: { id: 5, name: 'SupportAgent' }, criteria: [] },
    runs: [run],
    runId: 3,
  });

  assert.equal(count(html, /data-testid="run-spend-total"/g), 1);
  const footer = between(html, 'data-testid="criteria-footer"');
  assert.match(footer, /judge ~\$0\.1200 · 24 calls</, 'the spend line ends with the judge');
  assert.doesNotMatch(footer, /total/, 'the strip above already shows it');
});

test('a partial run is labelled and folds the rest', () => {
  const install = { ...scenarioA, group: 'Install & setup' };
  const agents = { ...scenarioB, group: 'Agents' };
  const html = render('ScenarioSuitePanel', suite({
    id: 10, status: 'complete', created_at: at, completed_at: at, samples_evaluated: 1, samples_passed: 1,
    selection: { scenario_keys: ['a'], group: 'Install & setup', models: [spec] }, scores: {},
    results: [result('a', 'passed', { score: 0.95, tool_calls: ['lookup_order'] })],
  }, { scenarios: [install, agents] }));

  assert.match(between(html, 'data-testid="suite-run-header"', 'data-testid="suite-runs-panel"'), /data-testid="suite-run-selection"[^>]*>partial: Install &amp; setup</);
  assert.match(between(html, 'data-testid="suite-runs-panel"', 'data-testid="scenario-matrix"'), /data-testid="evaluation-run-note"[^>]*>partial: Install &amp; setup</);
  assert.match(html, /data-scenario-key="a" data-step="passed"/);
  const agentsRow = between(html, 'data-group="Agents" data-collapsed=', '</div>');
  assert.match(agentsRow, /^data-group="Agents" data-collapsed="true"/);
  assert.match(between(html, 'data-group="Agents" data-collapsed="true"', 'data-testid="suite-models-panel"'), /not in this run/);
  assert.doesNotMatch(html, /data-scenario-key="b"/, 'the rows of a folded group are not drawn');
});

test('a suite with no runs lists its catalog', () => {
  const html = render('ScenarioSuitePanel', suite(undefined));

  assert.doesNotMatch(html, /suite-run-header/);
  assert.match(html, /\[ \] no runs yet/);
  assert.equal(count(html, /data-testid="scenario-row"/g), 2);
  assert.equal(count(html, /data-step="none"/g), 2);
  assert.match(html, /data-testid="scenario-step" title="not run yet"/);
  assert.doesNotMatch(between(html, 'data-testid="scenario-matrix"', 'data-testid="criteria-footer"'), /\d+\/\d+</, 'no model column, so no PassBar');
  assert.doesNotMatch(html, /suite-models-panel/);
  assert.doesNotMatch(html, /fix-list/);
  assert.match(html, /data-testid="criteria-footer"/);
});

const sixRuns = () => [6, 5, 4, 3, 2, 1].map((number) => ({
  id: number, number, status: 'complete', created_at: at, completed_at: at, samples_evaluated: 10, samples_passed: 4 + number,
}));
const railEvaluation = { id: 1, agent: { name: 'SupportAgent' } };

test('the rail lists every fetched run and pins a linked one', () => {
  const runs = sixRuns();
  const html = render('RunRail', { runs, evaluation: railEvaluation, selectedId: 3, layout: 'rail' });

  assert.equal(count(html, /data-testid="evaluation-run"/g), 6);
  assert.equal(count(html, /aria-current="true"/g), 1);
  assert.match(html, /aria-current="true" data-testid="evaluation-run" data-run-id="3"/);
  assert.equal(count(html, /tabindex="0"/g), 1);
  assertInOrder(html, ['>#6<', '>#5<', '>#4<', '>#3<', '>#2<', '>#1<']);
  assert.doesNotMatch(html, /runs-rail-toggle/);
  // The latest row carries the pass badge, in its short form: "passed" is in its tooltip only.
  assert.equal(count(html, /data-testid="suite-pass-badge"/g), 1);
  assert.match(between(html, 'data-testid="suite-pass-badge"', '</span>'), /title="10\/10 · 100% passed"[^>]*>10\/10 · 100%$/);

  const linkedRun = { id: 40, number: 40, status: 'complete', created_at: at, completed_at: at, samples_evaluated: 10, samples_passed: 7 };
  const linked = render('RunRail', { runs, evaluation: railEvaluation, selectedId: 40, layout: 'rail', linkedRun });
  assertInOrder(linked, ['linked · older than the latest 6', 'data-testid="evaluation-run" data-run-id="40"', 'data-run-id="6"']);
  assert.equal(count(linked, /data-testid="evaluation-run"/g), 7);

  const paged = render('RunRail', { runs, runCount: 37, evaluation: railEvaluation, selectedId: 3, layout: 'rail' });
  assert.match(paged, /31 older runs · reachable by link/);
});

test('the strip shows the latest three, the selected one, and offers the rest', () => {
  const runs = sixRuns();

  const folded = render('RunRail', { runs, evaluation: railEvaluation, layout: 'strip', limit: 3 });
  assert.equal(count(folded, /data-testid="evaluation-run"/g), 3);
  assert.match(folded, /\[\+\] 3 earlier runs/);
  assert.ok(folded.lastIndexOf('data-testid="evaluation-run"') < folded.indexOf('data-testid="runs-rail-toggle"'), 'the toggle is a line under the cards');
  // #3's row is not drawn; its number appears only in #4's movement line ("+1 passed vs #3").
  assert.doesNotMatch(folded, /data-run-id="3"/);
  assert.doesNotMatch(folded, />#3</);
  assert.match(folded, /vs #3</);

  const withSelected = render('RunRail', { runs, evaluation: railEvaluation, layout: 'strip', limit: 3, selectedId: 1 });
  assert.equal(count(withSelected, /data-testid="evaluation-run"/g), 4);
  assert.match(withSelected, /data-run-id="1"/);
  assert.match(withSelected, />#1</);
  assert.match(withSelected, /\[\+\] 2 earlier runs/);
  assert.equal(count(withSelected, /tabindex="0"/g), 1);

  const uncapped = render('RunRail', { runs, evaluation: railEvaluation, layout: 'strip' });
  assert.equal(count(uncapped, /data-testid="evaluation-run"/g), 6);
  assert.doesNotMatch(uncapped, /runs-rail-toggle/);
});

test("the run header reads the run's figures", () => {
  const run = {
    id: 8, status: 'complete', created_at: at, completed_at: at, samples_evaluated: 20, samples_passed: 14,
    usage: { replays: 20, cost: 0.44, runtime_ms: 724000, judge: { calls: 20, cost: 0.12, by_kind: {} } },
  };
  const props = {
    run, runNumber: 8, latestNumber: 9, isLatest: false, agentName: 'SupportAgent', scenarioCount: 20, groupCount: 3,
    columns: ['gpt-5-mini'], judgedBy: 'claude-opus-5-5',
    bars: [{ label: 'gpt-5-mini', short: 'gpt-5-mini', passed: 14, total: 20 }],
    totals: { passed: 14, total: 20 }, settledCount: 20, settledFailed: 6, expectedResults: 20,
    spend: runSpend(run), fixSummary: { items: 2, faults: 6, scenarios: 5 },
    rerun: { keys: ['a', 'b', 'c'], dropped: ['d'] },
    delta: { text: '+3 passed vs #7', tone: 'success' }, version: { kind: 'same', text: 'same version' },
    reportPath: '/evaluations/1/runs/8/report',
  };
  const html = render('RunHeader', props);

  assert.match(html, /Run #8</);
  assert.match(html, /latest #9/);
  assert.match(html, /re-run failed \(3 of 4\)/);
  assert.match(html, /14\/20 · 70%/);
  assert.match(html, /6 faults across 5 scenarios/);
  assert.match(html, /12m 04s/);
  assert.match(html, /\+3 passed vs #7/);
  assert.match(html, /same version/);
  assert.match(html, /run-spend-agent/);
  assert.match(html, /run-spend-judge/);
  assert.doesNotMatch(html, /suite-run-progress-bar/);

  assert.match(render('RunHeader', { ...props, runningElsewhere: { id: 9, number: 9, status: 'running' } }), /#9 is running · watch/);

  const loading = render('RunHeader', { ...props, loading: true });
  assert.match(between(loading, 'data-testid="suite-to-fix"'), /loading…/);
  assert.doesNotMatch(loading, /suite-rerun-failed/);

  // A run that has not started has no duration: the strip's dash, its reason in the tooltip.
  const queued = render('RunHeader', { ...props, run: { ...run, status: 'pending', completed_at: null, usage: null }, running: true, totals: { passed: 0, total: 20 }, settledCount: 0, settledFailed: 0 });
  assert.match(between(queued, 'title="Duration is read once the run starts"', '</div>'), />—</);
  assert.doesNotMatch(queued, /12m 04s|00:00/);
  assert.match(queued, /data-testid="suite-run-badge"[^>]*>queued</);
});

test('the tools level restores the three-line cells', () => {
  const run = {
    id: 7, status: 'complete', created_at: at, completed_at: at, samples_evaluated: 1, samples_passed: 1,
    selection: { scenario_keys: ['a'], models: [spec] }, scores: {},
    results: [result('a', 'passed', { score: 0.9, tool_calls: ['lookup_order'], cost: 0.0016, cost_source: 'reported' })],
  };
  const remembered = storageStub((key) => (key === 'aa.evaluations.detail' ? 'tools' : 'light'));
  Object.defineProperty(globalThis, 'localStorage', { value: remembered, configurable: true, writable: true });
  try {
    const tools = render('ScenarioSuitePanel', suite(run));
    assert.match(tools, /data-detail="tools"/);
    assert.match(tools, /scenario-cell-cost/);
  } finally {
    Object.defineProperty(globalThis, 'localStorage', { value: storageStub(), configurable: true, writable: true });
  }

  const steps = render('ScenarioSuitePanel', suite(run));
  assert.match(steps, /data-detail="steps"/);
  assert.doesNotMatch(steps, /scenario-cell-cost/);
});

test('every step shows each model\'s time and tokens, and the box adds them up per group, per scenario and per model', () => {
  const specs = [spec, { label: 'claude-haiku-5-5', provider: 'anthropic', model: 'claude-haiku-5-5' }];
  const ticket = (key, prompt) => ({ id: key.charCodeAt(1), key, prompt, group: 'Tickets', enabled: true, expectations: {} });
  const scenarios = [ticket('t1', 'Which clients have overdue tickets?'), ticket('t2', 'What tickets are on my plate?')];
  const row = (id, key, model, provider, extra = {}) => ({
    id, scenario_key: key, group: 'Tickets', prompt: scenarios.find((s) => s.key === key).prompt, model, provider, status: 'passed', score: 0.9, tool_calls: [], ...extra,
  });
  const run = {
    id: 9, status: 'complete', created_at: at, completed_at: at, samples_evaluated: 4, samples_passed: 3,
    selection: { scenario_keys: ['t1', 't2'], models: specs }, scores: {},
    usage: { replays: 4, cost: 0.02, judge: { calls: 4, cost: 0.01, by_kind: {} } },
    results: [
      row(1, 't1', 'gpt-5-mini', 'openai', { duration_ms: 5200, input_tokens: 1200, output_tokens: 340 }),
      row(2, 't1', 'claude-haiku-5-5', 'anthropic', { status: 'failed', fault: 'low_quality', score: 0.4, duration_ms: 2100, input_tokens: 900, output_tokens: 120 }),
      row(3, 't2', 'gpt-5-mini', 'openai', { duration_ms: 65000, input_tokens: 2000, output_tokens: 500 }),
      row(4, 't2', 'claude-haiku-5-5', 'anthropic', { status: 'pending', score: null }),
    ],
  };
  const html = render('ScenarioSuitePanel', suite(run, { scenarios }));

  const header = between(html, 'data-testid="scenario-matrix"', 'data-testid="scenario-group-row"');
  assert.match(header, /scenario-column-totals[^>]*>1m 10s · 3\.2K→840</, "the header adds up gpt-5-mini's answers over the run");
  assert.match(header, /scenario-column-totals[^>]*>2\.1s · 900→120</, 'a pending answer adds nothing to its model');

  const group = between(html, 'data-testid="scenario-group-row"', 'data-scenario-key="t1"');
  assert.match(group, /scenario-group-metrics[^>]*>1m 10s · 3\.2K→840</);
  assert.match(group, /scenario-group-metrics[^>]*>2\.1s · 900→120</);
  assert.match(group, /scenario-group-cost-tokens[^>]*>4\.1K→960</, "the group's tokens sit under its cost");
  assert.match(group, /scenario-group-time[^>]*>1m 10s</, "the group's time is its scenarios' slowest answers added up");

  const t1 = between(html, 'data-scenario-key="t1"', 'data-scenario-key="t2"');
  assert.match(t1, /scenario-cell-metrics[^>]*>5\.2s · 1\.2K→340</, 'a passed cell carries its time and tokens');
  assert.match(t1, /scenario-cell-metrics[^>]*>2\.1s · 900→120</, 'a failed cell does too, under its fault');
  assert.match(t1, /scenario-row-cost-tokens[^>]*>2\.1K→460</, "the scenario's tokens across the models sit under its cost");
  assert.match(t1, /scenario-row-time[^>]*>5\.2s</, 'TIME stays the slowest answer');

  const t2 = between(html, 'data-scenario-key="t2"', 'data-testid="suite-models-panel"');
  assert.equal(count(t2, /scenario-cell-metrics/g), 1, 'a pending cell has no metrics line');
  assert.match(t2, /scenario-row-time[^>]*>1m 05s</);
  assert.match(t2, /scenario-row-cost-tokens[^>]*>2\.0K→500</);
});
