import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// Every view opens with the one PageHeader: an optional crumb trail, then a
// 20px/600 title with its count, meta and actions on one row, and no
// subtitle paragraph. These views render their header from props alone, so
// they are bundled with esbuild and rendered to static markup (effects do
// not run there, so each shows its initial state).

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/page-headers-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: { location: { search: '', pathname: '/explorations' } }, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import ProjectList from './components/dashboard/projects/ProjectList.jsx';
        import NewProject from './components/dashboard/projects/NewProject.jsx';
        import SessionsView from './components/dashboard/SessionsView.jsx';
        import SessionReplayView from './components/dashboard/SessionReplayView.jsx';
        import ExplorationsView from './components/dashboard/ExplorationsView.jsx';
        import EvaluationRunDetail from './components/dashboard/evaluations/EvaluationRunDetail.jsx';

        const views = { ProjectList, NewProject, SessionsView, SessionReplayView, ExplorationsView, EvaluationRunDetail };
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

const TITLE = /<h1 style="margin:0;font-size:20px;font-weight:600;[^"]*">([^<]*)<\/h1>/;
const title = (html) => html.match(TITLE)?.[1];
const crumbs = (html) => [...html.matchAll(/<(?:button|a)[^>]*>([^<]*)<\/(?:button|a)><span aria-hidden="true"[^>]*>\/<\/span>/g)].map((m) => m[1]);
const noop = () => {};

test('a list page is its title, a count and its actions on one row, with no subtitle', () => {
  const html = render('ProjectList', { projects: [], onOpen: noop, onNew: noop });
  assert.equal(title(html), 'Projects');
  assert.doesNotMatch(html, /font-size:24px/);
  assert.doesNotMatch(html, /A repository booted in a sandbox/);
  assert.ok(html.indexOf('data-testid="new-project-button"') > html.indexOf('>Projects</h1>'), 'the New project button sits in the header');

  const sessions = render('SessionsView', {});
  assert.equal(title(sessions), 'Sessions');
  assert.doesNotMatch(sessions, /Replay what an agent did/);
  assert.doesNotMatch(sessions, />0<\/span>/, 'no count until the page has loaded');

  assert.equal(title(render('ExplorationsView', {})), 'Explorations');
});

test('a child page replaces its back button with a crumb trail above the title', () => {
  const html = render('NewProject', { onCreated: noop, onCancel: noop });
  assert.deepEqual(crumbs(html), ['Projects']);
  assert.equal(title(html), 'New project');
  assert.doesNotMatch(html, /Boot a repository in a sandbox, installing/);
  assert.match(html, /<button[^>]*>Cancel<\/button>/);

  const replay = render('SessionReplayView', { kind: 'context', id: 4, onBack: noop, onHandoff: noop });
  assert.deepEqual(crumbs(replay), ['Sessions']);
  assert.match(title(replay), / #4$/);
  assert.doesNotMatch(replay, /&lt;- Sessions/);
});

test('a run page carries the trail, the run meta and the run switcher in one header', () => {
  const at = '2026-03-01T10:00:00Z';
  const run = { id: 3, status: 'complete', created_at: at, completed_at: at, samples_evaluated: 4, samples_passed: 3, scores: {} };
  const html = render('EvaluationRunDetail', {
    evaluation: { id: 2, name: 'Sampled replies', agent: { id: 5, name: 'SupportAgent' }, criteria: [] },
    runs: [run],
    runId: 3,
  });
  assert.deepEqual(crumbs(html), ['Evaluations', 'Sampled replies']);
  assert.match(title(html), /^Run #\d+$/);
  assert.match(html, /font-size:12px;color:var\(--color-text-muted\)">Sampled replies · [^<]*@SupportAgent/);
  assert.ok(html.indexOf('data-testid="run-again-button"') > html.indexOf('</h1>'), 'Run again sits in the header');
  assert.doesNotMatch(html, /font-size:24px/);
});
