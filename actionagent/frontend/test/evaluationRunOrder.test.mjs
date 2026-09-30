import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The run views are .jsx, so this suite bundles them with esbuild and renders
// them to static markup. Effects do not run in a server render, so each view
// renders from its props alone and fetches nothing.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/evaluation-run-order-${process.pid}.mjs`, import.meta.url));
const at = '2026-01-05T10:00:00Z';

let render;

before(async () => {
  // ThemeProvider reads the saved theme while it renders, and dashboardPath
  // reads the engine's mount path off window.
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: {}, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import ScenarioSuitePanel from './components/dashboard/ScenarioSuitePanel.jsx';
        import EvaluationRunDetail from './components/dashboard/evaluations/EvaluationRunDetail.jsx';

        const views = { ScenarioSuitePanel, EvaluationRunDetail };
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
    external: ['react', 'react-dom', 'react-dom/server'],
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  ({ render } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

// Asserts that every marker is in the markup, in the order given.
function assertInOrder(html, markers) {
  const found = markers.map((marker) => html.indexOf(marker));
  markers.forEach((marker, index) => assert.ok(found[index] >= 0, `${marker} is missing`));
  assert.deepEqual([...found].sort((a, b) => a - b), found, `the sections read ${markers.join(', then ')}`);
}

test('a scenario suite reads models, then the scenario results, then what to fix', () => {
  const run = {
    id: 7,
    status: 'complete',
    created_at: at,
    completed_at: at,
    selection: { scenario_keys: ['orders_1'], models: [{ label: 'gpt-5-mini', provider: 'openai', model: 'gpt-5-mini' }] },
    scores: {},
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

  assertInOrder(html, ['data-testid="suite-models-panel"', 'data-testid="scenario-row"', 'data-testid="fix-list"']);
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
