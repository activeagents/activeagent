import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The sidebar, bundled with esbuild and rendered to static markup: the flat
// list of destinations in their order, Settings pinned last, the workspace
// button, the current item's tint, and what stays out of the markup while
// the account menu is closed. Effects do not run in a server render, so it
// renders from its props alone.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/sidebar-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: { location: { search: '' } }, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import Sidebar from './components/dashboard/Sidebar.jsx';

        const views = { Sidebar };
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

const LABELS = [
  'Ask', 'Agents', 'Run Agents', 'Projects', 'Traces', 'Interactions', 'Sessions', 'Tools', 'MCP Services', 'Metrics', 'Evaluations', 'Settings',
];

const sidebar = (props = {}) => render('Sidebar', {
  currentView: 'list',
  onNavigate() {},
  features: {},
  account: { name: 'Example Workspace' },
  user: { name: 'Ada', email: 'ada@example.com' },
  gemVersion: '1.2.3',
  ...props,
});

// Where a nav label sits in the markup. Labels are the whole text of their
// span, so 'Agents' is not found inside 'Run Agents'.
const labelAt = (html, label) => html.indexOf(`>${label}</span>`);

// The opening tag of the button that holds the label.
const buttonFor = (html, label) => {
  const before = html.slice(0, labelAt(html, label));
  return before.slice(before.lastIndexOf('<button'), before.indexOf('>', before.lastIndexOf('<button')) + 1);
};

test('the twelve destinations are listed in order, with Settings last', () => {
  const html = sidebar();
  const positions = LABELS.map((label) => labelAt(html, label));

  for (const [index, position] of positions.entries()) {
    assert.ok(position >= 0, `${LABELS[index]} is listed`);
    if (index > 0) assert.ok(position > positions[index - 1], `${LABELS[index]} comes after ${LABELS[index - 1]}`);
  }
  assert.equal(Math.max(...positions), labelAt(html, 'Settings'));
  assert.equal(html.slice(labelAt(html, 'Settings')).indexOf('<button'), -1, 'no destination follows Settings');
});

test('no nav item is drawn with an emoji', () => {
  assert.doesNotMatch(sidebar(), /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u);
});

test('the account menu stays out of the markup until the workspace button opens it', () => {
  const html = sidebar();

  assert.doesNotMatch(html, /Documentation/);
  assert.doesNotMatch(html, /Sign out/);
  assert.doesNotMatch(html, /Dark mode/);
  assert.match(html, /<button[^>]*aria-label="Workspace menu"[^>]*aria-haspopup="menu"[^>]*aria-expanded="false"/);
});

test('the workspace button carries the workspace initials, its name and who is signed in', () => {
  const html = sidebar();

  assert.match(html, />EW</);
  assert.match(html, />Example Workspace</);
  assert.match(html, />Ada</);
  assert.match(sidebar({ account: null, user: null }), />MW</);
});

test('the current item is tinted in the accent and marked current; the others are not', () => {
  const html = sidebar({ currentView: 'traces' });
  const current = buttonFor(html, 'Traces');
  const other = buttonFor(html, 'Agents');

  assert.match(current, /aria-current="page"/);
  assert.match(current, /background:var\(--color-accent-ui-tint\)/);
  assert.match(current, /color:var\(--color-accent-ui\)/);
  assert.doesNotMatch(other, /aria-current/);
  assert.doesNotMatch(other, /var\(--color-accent-ui/);
});

test('a view the dashboard does not have has no item', () => {
  const html = sidebar({ features: { assistantEnabled: false } });

  assert.equal(labelAt(html, 'Ask'), -1);
  assert.ok(labelAt(html, 'Agents') >= 0);
});
