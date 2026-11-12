import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { gateSentence, runGates, unmetGates } from '../utils/evaluationRuns.mjs';

// A run's per-group pass gates: the helpers that read them from the run's
// JSON, the Pass rate by group table, and the run badge's verdict, bundled
// with esbuild and rendered to static markup.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/run-gates-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import GateTable from './components/dashboard/evaluations/GateTable.jsx';
        import { RunBadge } from './components/dashboard/evaluations/RunsList.jsx';

        const views = { GateTable, RunBadge };
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

const gate = (extra = {}) => ({
  group: 'critical', name: 'Critical', label: 'gpt-5-mini', passed: 1, total: 2, pass_rate: 0.5, min_pass_rate: 1.0, gated: true, met: false, ...extra,
});

// Nine of ten passed, so the whole run clears its 80% bar; the critical
// group passed one of two against 100%.
const gatedRun = {
  status: 'complete', samples_evaluated: 10, samples_passed: 9, gates_met: false,
  gates: [
    gate(),
    gate({ group: 'informational', name: 'Informational', passed: 0, total: 2, pass_rate: 0, min_pass_rate: 0.8, gated: false, met: true }),
    gate({ group: null, name: 'All', passed: 7, total: 8, pass_rate: 0.875, min_pass_rate: 0.8, met: true }),
  ],
};

test('a run without gates reads as it always did', () => {
  assert.equal(runGates({ status: 'complete', samples_evaluated: 2, samples_passed: 2 }), null);
  assert.equal(runGates({ gates: null, gates_met: null }), null);
  assert.deepEqual(unmetGates({}), []);
  assert.equal(render('GateTable', { run: { status: 'complete' } }), '');
});

test("the verdict is the server's, and each gate keeps its bar", () => {
  const gates = runGates(gatedRun);

  assert.equal(gates.met, false);
  assert.deepEqual(gates.rows.map((row) => [row.name, row.gated, row.met]), [['Critical', true, false], ['Informational', false, true], ['All', true, true]]);
  assert.equal(runGates({ ...gatedRun, gates_met: true }).met, true, 'the rows are not regraded in the browser');
  assert.deepEqual(unmetGates(gatedRun).map((row) => row.name), ['Critical']);
  assert.deepEqual(runGates({ gates: [null, 'x', gate()], gates_met: false }).rows.length, 1, 'a row that is not an object is dropped');
});

test("a gate reads in Gate#to_s's words", () => {
  const [critical, informational, all] = runGates(gatedRun).rows;

  assert.equal(gateSentence(critical), 'Critical · gpt-5-mini: 1/2 (50%) passed, below 100%');
  assert.equal(gateSentence(informational), 'Informational · gpt-5-mini: 0/2 (0%) passed, not gated');
  assert.equal(gateSentence(all), 'All · gpt-5-mini: 7/8 (88%) passed, at or above 80%');
});

test('the table lists every gate with its status in words', () => {
  const html = render('GateTable', { run: gatedRun });

  assert.match(html, /Pass rate by group/);
  assert.match(html, /data-testid="run-gates-verdict"[^>]*>1 gate not met</);
  assert.deepEqual([...html.matchAll(/data-gate="([^"]+)"/g)].map((match) => match[1]), ['not met', 'reported only', 'met']);
  assert.match(html, /title="Critical · gpt-5-mini: 1\/2 \(50%\) passed, below 100%"/);
  assert.match(html, />100%</);
  assert.match(html, /<td[^>]*>—<\/td>/, 'an ungated group has no required rate');
});

test('a run that met every gate says so', () => {
  const run = { ...gatedRun, gates_met: true, gates: [gate({ passed: 2, pass_rate: 1, met: true })] };

  assert.match(render('GateTable', { run }), /data-testid="run-gates-verdict"[^>]*>every gate met</);
});

test('a missed gate turns the run badge to an error whatever its pass rate, and names the gate', () => {
  const html = render('RunBadge', { run: gatedRun });

  assert.match(html, /9\/10 · 90% passed · gate missed/);
  assert.match(html, /color:var\(--color-error-text\)/, 'a 90% run that missed a gate is toned as an error, not a warning');
  assert.match(render('RunBadge', { run: { ...gatedRun, gates_met: true } }), /color:var\(--color-warning-text\)/);
  assert.match(html, /title="9\/10 · 90% passed\nCritical · gpt-5-mini: 1\/2 \(50%\) passed, below 100%"/);
  assert.match(render('RunBadge', { run: gatedRun, short: true }), />9\/10 · 90% · gate missed</);
  assert.match(render('RunBadge', { run: { ...gatedRun, gates_met: true } }), />9\/10 · 90% passed · gates met</);
});

test('a run without gates keeps its badge', () => {
  const html = render('RunBadge', { run: { status: 'complete', samples_evaluated: 10, samples_passed: 9 } });

  assert.match(html, />9\/10 · 90% passed</);
  assert.doesNotMatch(html, /gate/);
  assert.doesNotMatch(html, /title=/);
});
