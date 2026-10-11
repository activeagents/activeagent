import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The page chrome primitives that render from their props alone, bundled with
// esbuild and rendered to static markup: PageHeader, Tabs, a closed Menu, the
// table styles and Hint.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/primitives-${process.pid}.mjs`, import.meta.url));

let render;
let TABLE;
let element;

before(async () => {
  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { Button, Hint, Menu, PageHeader, TABLE, Tabs } from './components/dashboard/primitives.jsx';

        const views = { Button, Hint, Menu, PageHeader, Tabs };
        export { TABLE };
        export const render = (name, props) => renderToStaticMarkup(React.createElement(views[name], props));
        export const element = (name, props) => React.createElement(views[name], props);
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
  ({ render, TABLE, element } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

// --- PageHeader -------------------------------------------------------------

test('the page header carries crumbs, a title with its count and meta, and actions pushed right', () => {
  const html = render('PageHeader', {
    crumbs: [
      { label: 'Agents', onClick() {}, testId: 'crumb-agents' },
      { label: 'SupportAgent', href: '/agents/7' },
    ],
    title: 'Runs',
    glyph: '@',
    count: 6,
    meta: 'Last 30 days',
    actions: element('Button', { variant: 'primary', children: 'New run' }),
    testId: 'runs-header',
  });

  assert.match(html, /<h1 [^>]*>.*Runs<\/h1>/);
  assert.match(html, /<h1 [^>]*font-size:20px;font-weight:600;letter-spacing:-0\.01em/);
  assert.match(html, /<span aria-hidden="true" [^>]*color:var\(--color-accent-ui\)[^>]*>@<\/span>Runs/);
  assert.match(html, /<nav aria-label="Breadcrumb"/);
  assert.match(html, /<button type="button" data-testid="crumb-agents" [^>]*>Agents<\/button>/);
  assert.match(html, /<a href="\/agents\/7" [^>]*>SupportAgent<\/a>/);
  assert.equal((html.match(/>\/<\/span>/g) || []).length, 2, 'a mono separator follows each crumb');
  assert.match(html, /font-family:var\(--font-mono\);font-size:13px;color:var\(--color-text-muted\)">6</);
  assert.match(html, /font-family:var\(--font-mono\);font-size:12px;color:var\(--color-text-muted\)">Last 30 days</);
  assert.match(html, /margin-left:auto[^>]*><button type="button"[^>]*>New run<\/button><\/div>/);
  assert.match(html, /data-testid="runs-header"/);
});

test('the page header heading element follows titleAs', () => {
  const html = render('PageHeader', { title: 'Scenarios', titleAs: 'h2' });
  assert.match(html, /<h2 [^>]*>Scenarios<\/h2>/);
  assert.doesNotMatch(html, /<h1/);
  assert.doesNotMatch(html, /Breadcrumb/);
});

test('a null title renders only the crumbs and the actions row', () => {
  const html = render('PageHeader', {
    title: null,
    crumbs: [{ label: 'Evaluations', onClick() {} }],
    actions: element('Button', { children: 'Export' }),
  });
  assert.doesNotMatch(html, /<h1|<h2/);
  assert.match(html, />Evaluations<\/button>/);
  assert.match(html, />Export<\/button>/);
  assert.doesNotMatch(render('PageHeader', { crumbs: [{ label: 'Only', onClick() {} }] }), /<h1/);
});

// --- Tabs -------------------------------------------------------------------

test('tabs render a tablist and mark the active tab selected', () => {
  const html = render('Tabs', {
    ariaLabel: 'Agent sections',
    tabs: [
      { id: 'activity', label: 'Activity', count: 12, testId: 'tab-activity' },
      { id: 'quality', label: 'Quality', testId: 'tab-quality' },
      { id: 'config', label: 'Config', disabled: true },
    ],
    active: 'quality',
    onChange() {},
  });

  assert.match(html, /<div role="tablist" aria-label="Agent sections"/);
  assert.match(html, /<button type="button" role="tab" aria-selected="false" data-testid="tab-activity"/);
  assert.match(html, /<button type="button" role="tab" aria-selected="true" data-testid="tab-quality"/);
  assert.match(html, /aria-selected="true"[^>]*border-bottom:2px solid var\(--color-accent-ui\)/);
  assert.match(html, /aria-selected="false"[^>]*color:var\(--color-text-muted\)/);
  assert.match(html, /Activity<span [^>]*font-family:var\(--font-mono\);font-size:12px[^>]*>12<\/span>/);
  assert.match(html, /role="tab" aria-selected="false" disabled=""/);
  assert.equal((html.match(/role="tab"/g) || []).length, 3);
});

// --- Menu -------------------------------------------------------------------

test('a closed menu is a trigger that announces its popover without rendering it', () => {
  const html = render('Menu', {
    label: 'Actions',
    testId: 'run-menu',
    items: [{ label: 'Export' }, { label: 'Delete', tone: 'danger' }],
  });
  assert.match(html, /<button type="button" data-testid="run-menu" aria-haspopup="menu" aria-expanded="false"[^>]*>Actions<\/button>/);
  assert.doesNotMatch(html, /role="menu"|Export|Delete/);
});

test('a menu without a label shows its glyph and is named by ariaLabel', () => {
  const html = render('Menu', { ariaLabel: 'More actions', items: [] });
  assert.match(html, /aria-haspopup="menu" aria-expanded="false" aria-label="More actions" title="More actions"[^>]*font-family:var\(--font-mono\)[^>]*>\.\.\.<\/button>/);
});

// --- TABLE and Hint ---------------------------------------------------------

test('the table styles are mono uppercase headers over bottom-border rows in a bordered frame', () => {
  assert.equal(TABLE.frame.border, '1px solid var(--color-border)');
  assert.equal(TABLE.frame.borderRadius, 12);
  assert.equal(TABLE.table.borderCollapse, 'collapse');
  assert.equal(TABLE.th.fontFamily, 'var(--font-mono)');
  assert.equal(TABLE.th.fontSize, 11);
  assert.equal(TABLE.th.textTransform, 'uppercase');
  assert.equal(TABLE.th.letterSpacing, '0.04em');
  assert.equal(TABLE.td.borderBottom, '1px solid var(--color-border-light)');
  assert.equal(TABLE.mono.fontSize, 12);
  assert.equal(TABLE.right.textAlign, 'right');
});

test('a hint is a 12px muted paragraph', () => {
  assert.equal(render('Hint', { children: 'Click a row to open it.' }), '<p style="margin:0;font-size:12px;color:var(--color-text-muted)">Click a row to open it.</p>');
});
