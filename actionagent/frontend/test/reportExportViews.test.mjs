import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The run report's export controls, rendered to static markup: the suite
// run header's downloads and copy, and the "Copy as Markdown" buttons on
// What to fix, its cards and the Models panel.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/report-export-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', {
    value: { location: { search: '', pathname: '/evaluations' }, addEventListener() {}, removeEventListener() {}, ACTIVE_AGENT_DASHBOARD: { mountPath: '/activeagents' } },
    configurable: true, writable: true,
  });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import RunHeader from './components/dashboard/evaluations/RunHeader.jsx';
        import { FixList, ModelsPanel } from './components/dashboard/EvaluationRunPanels.jsx';

        const views = { RunHeader, FixList, ModelsPanel };
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

test('a complete run links its report downloads and copies it as Markdown', () => {
  const html = render('RunHeader', { run, reportPath: '/evaluations/3/runs/12/report' });
  assert.match(html, /href="\/activeagents\/api\/evaluations\/3\/runs\/12\/report\?download=1"/);
  assert.match(html, /href="\/activeagents\/api\/evaluations\/3\/runs\/12\/report\.json\?download=1"/);
  assert.match(html, /href="\/activeagents\/api\/evaluations\/3\/runs\/12\/report\.md\?download=1"/);
  assert.match(html, /data-testid="suite-run-copy-markdown"/);
});

test('a run without a report offers no downloads', () => {
  const html = render('RunHeader', { run: { ...run, status: 'running' } });
  assert.doesNotMatch(html, /suite-run-exports/);
});

test('What to fix copies the section and each card as Markdown', () => {
  const items = [{ kind: 'fault', fault: 'missing_capability', count: 1, scenario_keys: ['s1'], models: ['m'], recommendation: 'Add a tool', tools: [], markdown: '### ❗ missing capability' }];
  const html = render('FixList', { items, columns: ['m'], markdownUrl: '/activeagents/api/evaluations/3/runs/12/report.md' });
  assert.match(html, /data-testid="copy-fixes-markdown"/);
  assert.match(html, />Copy What to fix as Markdown</);
  assert.match(html, /data-testid="copy-fix-markdown"/);

  const bare = render('FixList', { items: items.map(({ markdown, ...item }) => item), columns: ['m'] });
  assert.doesNotMatch(bare, /copy-fix-markdown|copy-fixes-markdown/, 'nothing to copy without the server Markdown');
});

test('the Models panel copies the verdict and comparison', () => {
  const html = render('ModelsPanel', { run, columns: [], judgedBy: 'rules', markdownUrl: '/x/report.md' });
  assert.match(html, /data-testid="copy-verdict-markdown"/);
});
