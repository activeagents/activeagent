import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The agent page's header, stats strip and three tabs, bundled with esbuild
// and rendered to static markup. Effects do not run in a server render, so
// it renders from the agent it is given and fetches nothing.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/agent-editor-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  // ThemeProvider reads the saved theme while it renders; TimeWindowProvider
  // reads its window the same way.
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: { location: { search: '' } }, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import { TimeWindowProvider } from './contexts/TimeWindowContext.jsx';
        import AgentEditor from './components/dashboard/AgentEditor.jsx';

        export const render = (props) =>
          renderToStaticMarkup(React.createElement(ThemeProvider, null,
            React.createElement(TimeWindowProvider, null, React.createElement(AgentEditor, props))));
      `,
      resolveDir: root,
      loader: 'jsx',
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'node',
    // AgentEditor pulls recharts in through AgentAnalytics; it is CommonJS
    // and requires react at runtime, and an ES module has no require of its own.
    external: ['react', 'react-dom', 'react-dom/server', 'recharts', '@rails/actioncable'],
    banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" },
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  ({ render } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

const agent = {
  id: 7,
  name: 'SupportAgent',
  description: 'Answers order questions.',
  provider: 'openai',
  model: 'gpt-5-mini',
  status: 'active',
  version_count: 12,
  stats: { window_days: 30, runs: 1284, success_rate: 99.6, avg_duration_ms: 1840, eval_score: 0.875, cost: 12.4 },
};

const props = (overrides = {}) => ({
  agent, meta: { instructionSets: [] }, onSave() {}, onDelete() {}, onRun() {}, onDuplicate() {}, onRunReport() {}, onBack() {}, isLoading: false, ...overrides,
});

const tabs = (html) => [...html.matchAll(/<button[^>]*role="tab"[^>]*aria-selected="(true|false)"[^>]*>([^<]+)<\/button>/g)]
  .map(([, selected, label]) => [label, selected === 'true']);

const stats = (html) => [...html.matchAll(/<span style="font-size:11px;[^"]*">([^<]+)<\/span><span style="font-size:16px;[^"]*">([^<]+)<\/span>/g)]
  .map(([, label, value]) => [label, value]);

test('the agent page has a crumb back to Agents, the identity line and the three tabs', () => {
  const html = render(props());
  assert.match(html, /<nav aria-label="Breadcrumb"[^>]*><button[^>]*>Agents<\/button>/);
  assert.match(html, /<h1[^>]*><span aria-hidden="true"[^>]*>@<\/span>SupportAgent<\/h1>/);
  assert.match(html, />gpt-5-mini · v12</);
  assert.match(html, />active</);
  assert.match(html, />Answers order questions\.</);
  assert.deepEqual(tabs(html), [['Activity', false], ['Quality', false], ['Config', true]]);
  assert.doesNotMatch(html, /Feedback/);
  // Config opens on Configuration, with its sections in a segmented control.
  assert.match(html, /<button[^>]*aria-pressed="true"[^>]*>Configuration<\/button>/);
  for (const label of ['Instructions', 'Tools', 'Versions', 'Code']) {
    assert.match(html, new RegExp(`<button[^>]*aria-pressed="false"[^>]*>${label}</button>`));
  }
  assert.match(html, /<button[^>]*>Run Agent<\/button>/);
  assert.match(html, /<button[^>]*>Duplicate<\/button>/);
});

test('the stats strip writes the recorded figures with the shared formatters', () => {
  const html = render(props());
  assert.deepEqual(stats(html), [
    ['RUNS 30D', '1,284'],
    ['ERRORS', '0.4%'],
    ['AVG', '1.8s'],
    ['EVAL', '88%'],
    ['COST', '$12.40'],
  ]);
  assert.match(html, /color:var\(--color-error-text\)">0\.4%</);
  assert.match(html, /color:var\(--color-success-text\)">88%</);
});

test('the strip reads "—" where nothing was recorded, and is absent without stats', () => {
  const sparse = render(props({ agent: { ...agent, stats: { window_days: 30, runs: 0, success_rate: null, avg_duration_ms: null, eval_score: null, cost: null } } }));
  assert.deepEqual(stats(sparse), [['RUNS 30D', '0'], ['ERRORS', '—'], ['AVG', '—'], ['EVAL', '—'], ['COST', '—']]);
  assert.doesNotMatch(sparse, /color:var\(--color-error-text\)">/);

  const none = render(props({ agent: { ...agent, stats: undefined } }));
  assert.doesNotMatch(none, /data-testid="agent-stats"/);
  assert.doesNotMatch(none, /RUNS/);
});

test('the analytics deep link lands on Quality with Metrics selected', () => {
  const html = render(props({ initialTab: 'metrics' }));
  assert.deepEqual(tabs(html), [['Activity', false], ['Quality', true], ['Config', false]]);
  assert.match(html, /<div role="group" aria-label="Quality sections"[^>]*><button[^>]*>Evaluations<\/button><button[^>]*>Metrics<\/button><\/div>/);
  // The selected chip carries the accent; the other does not.
  assert.match(html, /border:1px solid var\(--color-accent-ui\);[^"]*">Metrics</);
  assert.match(html, /border:1px solid var\(--color-border\);[^"]*">Evaluations</);
});

test('an unknown initial tab falls back to Configuration', () => {
  const html = render(props({ initialTab: 'feedback' }));
  assert.deepEqual(tabs(html), [['Activity', false], ['Quality', false], ['Config', true]]);
  assert.match(html, /<button[^>]*aria-pressed="true"[^>]*>Configuration<\/button>/);
});
