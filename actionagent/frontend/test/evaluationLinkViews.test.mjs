import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The "copy link" affordances on evaluation views, rendered to static
// markup: a suite run's header, a sampling run's page, and each scenario
// result card, which also marks the result a shared link named.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/evaluation-link-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', {
    value: {
      location: { search: '', pathname: '/activeagents/evaluations/3', origin: 'https://app.example.com' },
      addEventListener() {}, removeEventListener() {}, ACTIVE_AGENT_DASHBOARD: { mountPath: '/activeagents' },
    },
    configurable: true, writable: true,
  });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import RunHeader from './components/dashboard/evaluations/RunHeader.jsx';
        import CopyLinkButton from './components/dashboard/evaluations/CopyLinkButton.jsx';
        import { ScenarioDetail } from './components/dashboard/EvaluationRunPanels.jsx';

        const views = { RunHeader, CopyLinkButton, ScenarioDetail };
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

const run = { id: 12, status: 'complete', created_at: '2026-10-21T09:00:00Z', completed_at: '2026-10-21T09:01:00Z', scores: {} };

test('a suite run header copies a link to the run', () => {
  const html = render('RunHeader', { run, evaluationId: 3 });
  assert.match(html, /data-testid="suite-run-copy-link"/);
  assert.match(html, />copy link</);

  assert.doesNotMatch(render('RunHeader', { run }), /suite-run-copy-link/, 'no link without the evaluation it belongs to');
});

test('the copy button renders only for a complete link', () => {
  assert.match(render('CopyLinkButton', { evaluationId: 3, runId: 12, resultId: 40 }), /data-testid="copy-link"/);
  assert.equal(render('CopyLinkButton', { evaluationId: 3, resultId: 40 }), '');
  assert.equal(render('CopyLinkButton', {}), '');
});

const scenario = { id: 1, key: 's1', prompt: 'Where is order 1234?', expectations: {} };
const result = (id, model) => ({
  id, scenario_key: 's1', model, provider: 'mock', status: 'passed', score: 1, scores: {}, output: 'Shipped.',
});

test('each result card copies a link to itself and the linked one is marked', () => {
  const columns = ['model-a', 'model-b'];
  const resultsByKey = { s1: { 'model-a': result(40, 'model-a'), 'model-b': result(41, 'model-b') } };
  const html = render('ScenarioDetail', { scenario, run, columns, resultsByKey, running: false, evaluationId: 3, linkedResultId: 41 });

  assert.equal(html.match(/data-testid="scenario-result-copy-link"/g)?.length, 2);
  assert.match(html, /data-result-id="40"/);
  assert.match(html, /data-result-id="41" data-linked="true"/);
  assert.doesNotMatch(html, /data-result-id="40" data-linked/);
});

test('a result card without its evaluation offers no link', () => {
  const html = render('ScenarioDetail', {
    scenario, run, columns: ['model-a'], resultsByKey: { s1: { 'model-a': result(40, 'model-a') } }, running: false,
  });
  assert.doesNotMatch(html, /scenario-result-copy-link/);
});
