import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The Scenarios page's views that render from their props and the URL,
// bundled with esbuild and rendered to static markup: the page's tabs and
// header, an import preview, and the exploration review's accept bar when
// it targets a scenario set.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/scenario-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', {
    value: { location: { search: '', pathname: '/scenarios/import' }, addEventListener() {}, removeEventListener() {} },
    configurable: true, writable: true,
  });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import ScenariosView from './components/dashboard/scenarios/ScenariosView.jsx';
        import { PreviewCard } from './components/dashboard/scenarios/ScenarioImport.jsx';

        const views = { ScenariosView, PreviewCard };
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

test('the page is called Scenarios and opens the tab its URL names', () => {
  const html = render('ScenariosView', {});
  assert.match(html, /<h1[^>]*>Scenarios<\/h1>/);
  assert.doesNotMatch(html, /Scenario catalogs|>Catalogs/);
  assert.match(html, /data-testid="scenarios-import"/);
  assert.match(html, /aria-pressed="true"[^>]*>Import</);
  assert.match(html, /Keep what the document leaves out/);
});

test('an import preview lists what it creates, overwrites and removes, by key', () => {
  const html = render('PreviewCard', {
    preview: {
      mode: 'replace', catalog: { key: 'checkout', action: 'update' }, scenario_count: 2,
      counts: { create: 1, update: 1, remove: 1 },
      changes: [
        { level: 'scenario', path: 'cart/uat/checkout', action: 'create' },
        { level: 'scenario', path: 'cart/uat/remove_item', action: 'update' },
        { level: 'set', path: 'cart/smoke', action: 'remove' },
      ],
    },
  });
  assert.match(html, /existing collection/);
  assert.match(html, /Updates checkout: 1 new, 1 overwritten, 1 removed/);
  for (const text of ['New', 'Overwritten', 'Removed', 'scenario cart/uat/checkout', 'set cart/smoke']) assert.ok(html.includes(text), text);

  const unchanged = render('PreviewCard', { preview: { mode: 'merge', catalog: { key: 'c', action: 'create' }, scenario_count: 0, counts: {}, changes: [] } });
  assert.match(unchanged, /new collection/);
  assert.match(unchanged, /Nothing changes/);
});
