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
        import { ModelsPanel } from './components/dashboard/EvaluationRunPanels.jsx';

        const views = { ModelComparisonTable, ModelScorecard, ModelsPanel };
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

  assert.match(html, />Avg latency<\/th><th[^>]*>P50 \/ P95<\/th>/);
  assert.match(html, /data-testid="model-comparison-percentiles"[^>]*>4\.02s \/ 22\.2s<\/td>/);
  assert.match(html, /data-testid="model-comparison-percentiles"[^>]*>—<\/td>/, 'a model with none recorded reads as missing');
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
