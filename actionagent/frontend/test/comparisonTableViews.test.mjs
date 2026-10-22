import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The ranked comparison table and the value pill, bundled with esbuild and
// rendered to static markup, plus the views that adopted them.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/comparison-table-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import ComparisonTable from './components/dashboard/ComparisonTable.jsx';
        import ValuePill from './components/dashboard/ValuePill.jsx';
        import MetricStrip from './components/dashboard/MetricStrip.jsx';
        import ModelLeaderboard from './components/dashboard/evaluations/ModelLeaderboard.jsx';
        import { SignalTile } from './components/dashboard/MetricsCharts.jsx';
        const views = { ComparisonTable, ValuePill, MetricStrip, ModelLeaderboard, SignalTile };
        export const render = (name, props, children) =>
          renderToStaticMarkup(React.createElement(ThemeProvider, null, React.createElement(views[name], props, children)));
      `,
      resolveDir: root,
      loader: 'jsx',
    },
    bundle: true, write: false, format: 'esm', platform: 'node',
    external: ['react', 'react-dom', 'react-dom/server', '@rails/actioncable'],
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  ({ render } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

const models = [
  { label: 'claude-opus', accuracy: 0.912, cost: 10.53 },
  { label: 'gpt-astra', accuracy: 0.873, cost: 4.71 },
  { label: 'gemini-argon', accuracy: 0.848, cost: 6.13 },
  { label: 'muse-spark', accuracy: 0.612, cost: null },
];
const columns = [
  { key: 'accuracy', label: 'Accuracy', unit: 'Task score', better: 'higher', band: 'threshold', thresholds: [0.85, 0.7], format: (v) => `${(v * 100).toFixed(1)}%` },
  { key: 'cost', label: 'Cost', unit: 'Per run', better: 'lower', format: (v) => (v == null ? '—' : `$${v.toFixed(2)}`) },
];
const table = (props = {}) => render('ComparisonTable', { identity: { key: 'label', label: 'Model' }, columns, rows: models, testId: 'table', ...props });

test('a value pill carries its rank as data and a hidden rank word', () => {
  const html = render('ValuePill', { rank: 'good' }, '65.3%');
  assert.match(html, /<span class="aa-pill" data-rank="good"[^>]*>65\.3%<span style="position:absolute;[^"]*"> best third<\/span><\/span>/);
  assert.doesNotMatch(render('ValuePill', { rank: 'none' }, 'n/a'), /third|ranked/, 'an unranked pill says nothing more');
});

test('headers are two-line, sortable buttons; only the sorted column shows a caret', () => {
  const html = table({ defaultSort: 'accuracy' });
  assert.match(html, /<th scope="col" aria-sort="descending" data-key="accuracy"[^>]*><button type="button"[^>]*class="aa-sort"/);
  assert.match(html, /data-key="accuracy"(?:(?!<\/th>).)*>Accuracy<span aria-hidden="true" class="aa-caret"[^>]*>▼<\/span><\/span><span class="aa-head-unit"[^>]*>Task score<\/span>/);
  assert.match(html, /<th scope="col" aria-sort="none" data-key="cost"/);
  assert.equal((html.match(/aa-caret/g) || []).length, 1);
});

test('the default sort opens by the better direction, so the strongest row is first', () => {
  const order = (html) => [...html.matchAll(/<td class="aa-comparison-id"[^>]*>([^<]+)<\/td>/g)].map((m) => m[1]);
  assert.deepEqual(order(table({ defaultSort: 'accuracy' })), ['claude-opus', 'gpt-astra', 'gemini-argon', 'muse-spark']);
  assert.deepEqual(order(table({ defaultSort: 'cost' })), ['gpt-astra', 'gemini-argon', 'claude-opus', 'muse-spark'], 'cost ascends and the unpriced model is last');
  assert.deepEqual(order(table({ sort: { key: 'cost', direction: 'descending' } })), ['claude-opus', 'gemini-argon', 'gpt-astra', 'muse-spark']);
});

test('every numeric cell is a pill tinted by rank within its column; the identity cell never is', () => {
  const html = table();
  const cells = [...html.matchAll(/<td [^>]*data-rank="([a-z]+)"[^>]*><span class="aa-pill" data-rank="([a-z]+)"[^>]*>([^<]+)</g)].map((m) => [m[1], m[3]]);
  assert.deepEqual(cells, [
    ['good', '91.2%'], ['poor', '$10.53'],
    ['good', '87.3%'], ['good', '$4.71'],
    ['mid', '84.8%'], ['mid', '$6.13'],
    ['poor', '61.2%'], ['none', '—'],
  ]);
  assert.doesNotMatch(html, /<td class="aa-comparison-id"[^>]*data-rank/);
});

test('a column with a custom cell renders it in place of a pill, and a sub-line sits under a pill', () => {
  const html = table({ columns: [
    ...columns.slice(0, 1),
    { key: 'cost', label: 'Cost', better: 'lower', format: (v) => (v == null ? '—' : `$${v.toFixed(2)}`), sub: (row) => (row.cost == null ? null : `$${(row.cost / 10).toFixed(2)}/run`) },
    { key: 'note', label: 'Note', kind: 'text', sortable: false, value: (row) => row.label, cell: (row) => `note for ${row.label}` },
  ] });
  assert.match(html, /<span class="aa-pill-sub"[^>]*>\$1\.05\/run<\/span>/);
  assert.match(html, /<th scope="col" data-key="note"[^>]*>(?:(?!<button).)*<\/th>/, 'a column that cannot sort has no button');
  assert.match(html, /<td class="aa-comparison-text" data-label="Note"[^>]*>note for claude-opus<\/td>/, 'a text column is labelled for the phone layout');
  assert.match(html, /<td data-label="Cost"/, 'a cell carries its column label for the phone layout');
});

test('an empty table renders its empty text or nothing', () => {
  assert.equal(table({ rows: [] }), '');
  assert.match(table({ rows: [], emptyText: 'nothing to compare' }), />nothing to compare</);
});

test('the leaderboard keeps its Wilson order, its row test ids and tints rates on the pass thresholds', () => {
  const rows = [
    { label: 'ollama/qwen3:8b', passed: 75, total: 173, ratio: 75 / 173, lower: 0.36, rank: 1, byEvaluation: { e1: { passed: 75, total: 173 } } },
    { label: 'gpt-5-mini', passed: 7, total: 8, ratio: 7 / 8, lower: 0.3, rank: 2, byEvaluation: { e1: { passed: 7, total: 8 } } },
  ];
  const html = render('ModelLeaderboard', { rows, columns: [{ id: 'e1', name: 'Support' }, { id: 'e2', name: 'Billing' }] });
  const order = [...html.matchAll(/data-testid="model-leaderboard-row" title="(.*?): at least/g)].map((m) => m[1]);
  assert.deepEqual(order, ['ollama/qwen3:8b', 'gpt-5-mini']);
  assert.match(html, /<td [^>]*data-rank="poor"[^>]*><span class="aa-pill" data-rank="poor"[^>]*>43%</);
  assert.match(html, /<td [^>]*data-rank="good"[^>]*><span class="aa-pill" data-rank="good"[^>]*>88%</);
  assert.doesNotMatch(html, /Billing/, 'an evaluation no model ran in has no column');
});

test('a metric strip shows a two-line label over each pill and drops items with no value', () => {
  const html = render('MetricStrip', { items: [
    { key: 'score', label: 'Score', unit: 'passed', value: '92%', rank: 'good' },
    { key: 'time', label: 'Time', unit: 'to answer', value: '5.2s' },
    { key: 'cost', label: 'Cost', value: null },
  ] });
  assert.match(html, />Score<\/span><span[^>]*>passed<\/span><\/span><span class="aa-pill" data-rank="good"/);
  assert.match(html, /data-rank="none"[^>]*>5\.2s</);
  assert.doesNotMatch(html, /Cost/);
});

test('a signal tile shows its change against the previous window as a ranked pill', () => {
  const html = render('SignalTile', { label: 'Latency', value: '620ms', unit: 'p50', sub: 'p95 1.9s', delta: '-12%', deltaRank: 'good', deltaSub: 'vs previous 24h', spark: '0,10 100,5', sparkColor: '#000' });
  assert.match(html, /data-testid="signal-delta"[^>]*>-12%</);
  assert.match(html, /class="aa-pill" data-rank="good" data-testid="signal-delta"/);
});
