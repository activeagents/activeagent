import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The run's model comparison table and scorecards, bundled with esbuild and
// rendered to static markup.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/model-comparison-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import ModelComparisonTable from './components/dashboard/evaluations/ModelComparisonTable.jsx';
        import ModelScorecard from './components/dashboard/evaluations/ModelScorecard.jsx';
        import ComparisonIntervals from './components/dashboard/evaluations/ComparisonIntervals.jsx';
        import { ModelsPanel } from './components/dashboard/EvaluationRunPanels.jsx';

        const views = { ModelComparisonTable, ModelScorecard, ModelsPanel, ComparisonIntervals };
        export const render = (name, props) =>
          renderToStaticMarkup(React.createElement(ThemeProvider, null, React.createElement(views[name], props)));
      `,
      resolveDir: root,
      loader: 'jsx',
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'node',
    external: ['react', 'react-dom', 'react-dom/server', '@rails/actioncable'],
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  ({ render } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

const row = (label, extra = {}) => ({ label, passed: 4, total: 6, passRate: 4 / 6, avgScore: 0.9, avgDurationMs: 5219, ...extra });

test('the comparison table shows P50 / P95 beside the mean latency', () => {
  const html = render('ModelComparisonTable', {
    rows: [row('qwen3:4b-instruct', { p50DurationMs: 4020, p95DurationMs: 22200 }), row('phi4-mini:latest')],
  });

  const heads = [...html.matchAll(/<th [^>]*data-key="([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(heads.slice(heads.indexOf('avgDurationMs'), heads.indexOf('avgDurationMs') + 2), ['avgDurationMs', 'p95DurationMs'], 'P50 / P95 sits beside the mean latency');
  assert.match(html, /data-key="p95DurationMs"[^>]*>(?:(?!<\/th>).)*>P50 \/ P95<\/span>/);
  assert.match(html, /data-testid="model-comparison-percentiles"[^>]*><span class="aa-pill" data-rank="none"[^>]*>4\.02s \/ 22\.2s<\/span>/);
  assert.match(html, /data-testid="model-comparison-percentiles"[^>]*><span class="aa-pill" data-rank="none"[^>]*>—<\/span>/, 'a model with none recorded reads as missing');
});

test('a run that recorded no percentiles has no P50 / P95 column', () => {
  const html = render('ModelComparisonTable', { rows: [row('qwen3:4b-instruct'), row('phi4-mini:latest')] });

  assert.doesNotMatch(html, /P50 \/ P95/);
});

test('a scorecard shows P50 / P95 when the run recorded them', () => {
  const props = { label: 'qwen3:4b-instruct', passed: 4, total: 6, avgScore: 0.9, latencyMs: 5219, unit: 'scenario' };

  assert.match(render('ModelScorecard', { ...props, p50Ms: 4020, p95Ms: 22200 }), /p50 \/ p95 <span[^>]*>4\.02s \/ 22\.2s<\/span>/);
  assert.doesNotMatch(render('ModelScorecard', props), /p50 \/ p95/);
});

test("the run's Models panel hands each scorecard its recorded P50 / P95", () => {
  const run = {
    status: 'complete',
    scores: {
      _models: {
        'qwen3:4b-instruct': { provider: 'ollama', model: 'qwen3:4b-instruct', scenarios: 6, passed: 4, avg_score: 0.9, avg_duration_ms: 5219, p50_duration_ms: 4020, p95_duration_ms: 22200 },
      },
    },
  };
  const html = render('ModelsPanel', { run, columns: ['qwen3:4b-instruct'], scenarioCount: 6 });

  assert.match(html, /p50 \/ p95 <span[^>]*>4\.02s \/ 22\.2s<\/span>/);
});

// What ScenarioEvaluationRunner records under _comparison for a two-model run.
const recordedComparison = {
  method: { statistic: 'pass rate', interval: 'percentile bootstrap', unit: 'scenario', resamples: 5000, confidence: 0.95, seed: 0 },
  models: {
    'ollama/qwen3:8b': { scenarios: 42, pass_rate: 78.6, interval: [66.7, 90.5] },
    'gpt-5-mini': { scenarios: 42, pass_rate: 85.7, interval: [73.8, 95.2] },
  },
  ranking: ['gpt-5-mini', 'ollama/qwen3:8b'],
  pairs: [{ models: ['gpt-5-mini', 'ollama/qwen3:8b'], scenarios: 42, difference: 7.1, interval: [-4.8, 19.0], decisive: false }],
  conclusion: 'The pairwise difference interval includes zero: the ranking is not decisive evidence of superiority.',
};
const comparingRun = (scores = {}) => ({
  status: 'complete',
  scores: {
    _models: {
      'gpt-5-mini': { provider: 'openai', model: 'gpt-5-mini', scenarios: 42, passed: 36 },
      'ollama/qwen3:8b': { provider: 'ollama', model: 'qwen3:8b', scenarios: 42, passed: 33 },
    },
    ...scores,
  },
});

test("the Models panel plots the run's recorded intervals best first, with the conclusion under them", () => {
  const html = render('ModelsPanel', { run: comparingRun({ _comparison: recordedComparison }), columns: ['gpt-5-mini', 'ollama/qwen3:8b'], scenarioCount: 42 });
  const plot = html.slice(html.indexOf('data-testid="comparison-intervals"'));

  assert.ok(html.indexOf('data-testid="model-comparison-table"') < html.indexOf('data-testid="comparison-intervals"'), 'the plot follows the table');
  assert.deepEqual([...plot.matchAll(/data-testid="comparison-interval-row" data-model="([^"]+)"/g)].map((match) => match[1]), ['gpt-5-mini', 'ollama/qwen3:8b']);
  assert.match(plot, /Pass rate · 95% CI/);
  assert.match(plot, /data-testid="comparison-interval-range" style="[^"]*left:73\.8%;width:21\.4%;/);
  assert.match(plot, /<strong[^>]*>85\.7%<\/strong> 73\.8 to 95\.2 · 42 scenarios/);
  assert.match(plot, /data-testid="comparison-conclusion">The pairwise difference interval includes zero: the ranking is not decisive evidence of superiority\.</);
  assert.match(plot, /95% CI from 5,000 resamples of whole scenarios/);
});

test('a run that recorded no comparison draws no plot', () => {
  const html = render('ModelsPanel', { run: comparingRun(), columns: ['gpt-5-mini', 'ollama/qwen3:8b'], scenarioCount: 42 });

  assert.doesNotMatch(html, /comparison-intervals/);
});

// A row of its own would size its figures column to its own text, giving
// each track, and the axis under them, a different width.
test("the plot's rows and axis share one grid, so the ticks line up with the dots", () => {
  const plot = { rows: [{ label: 'gpt-5-mini', passRate: 85.7, interval: [73.8, 95.2], scenarios: 42 }, { label: 'qwen3:8b', passRate: 7.1, interval: [0, 16.7], scenarios: 42 }], conclusion: 'x', confidence: 95, resamples: 5000 };
  const html = render('ComparisonIntervals', { plot });

  assert.match(html, /<div style="display:grid;grid-template-columns:minmax\(64px, 200px\) minmax\(96px, 1fr\) auto;[^"]*" data-testid="comparison-intervals">/);
  const rows = [...html.matchAll(/<div style="([^"]*)" data-testid="comparison-interval-row"/g)].map((match) => match[1]);
  assert.deepEqual(rows, ['display:contents', 'display:contents']);
  assert.match(html, /<div style="display:contents" aria-hidden="true"><span><\/span><span style="position:relative/, 'the axis is a row of the same grid');
  assert.match(html, /grid-column:1 \/ -1[^"]*" data-testid="comparison-conclusion"/, 'the conclusion spans the plot');
});

test('a model with too few scenarios gets a dot and no range', () => {
  const plot = { rows: [{ label: 'gpt-5-mini', passRate: 100, interval: null, scenarios: 1 }, { label: 'qwen3:8b', passRate: 0, interval: null, scenarios: 1 }], conclusion: 'The models share too few scenarios to compare.', confidence: 95, resamples: 5000 };
  const html = render('ComparisonIntervals', { plot });

  assert.doesNotMatch(html, /comparison-interval-range/);
  assert.match(html, /<strong[^>]*>100%<\/strong> no interval · 1 scenario</);
});
