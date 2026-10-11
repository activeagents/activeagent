import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The Agents home, bundled with esbuild and rendered to static markup from
// its props alone: the titled table, its figures and placeholders, the
// status tags, the header controls and the empty state.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/agent-list-views-${process.pid}.mjs`, import.meta.url));

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
        import AgentList from './components/dashboard/AgentList.jsx';

        const views = { AgentList };
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

const minutesAgo = (minutes) => new Date(Date.now() - minutes * 60_000).toISOString();

// Generic fixtures: a busy agent, a draft that never ran and an observed one.
const agents = [
  {
    id: 1, name: 'SupportAgent', description: 'Answers tickets', provider: 'anthropic', model: 'claude-sonnet-4-5', status: 'active',
    updatedAt: minutesAgo(60 * 24 * 3),
    stats: {
      window_days: 30, runs: 1284, run_sources: ['platform', 'telemetry'], success_rate: 99.4, avg_duration_ms: 1800,
      tokens: 420000, cost: 12.4, eval_score: 0.91, eval_samples_passed: 29, eval_samples_evaluated: 32, eval_runs: 2,
      eval_not_counted: 0, last_run_at: minutesAgo(2),
    },
  },
  {
    id: 2, name: 'DataAnalyst', description: '', provider: 'openai', model: 'gpt-4.1', status: 'draft',
    updated_at: minutesAgo(60 * 2),
    stats: {
      window_days: 30, runs: 0, run_sources: [], success_rate: null, avg_duration_ms: null, tokens: 0, cost: null,
      eval_score: null, eval_samples_passed: 0, eval_samples_evaluated: 0, eval_runs: 0, eval_not_counted: 0, last_run_at: null,
    },
  },
  {
    id: 3, name: 'TriageAgent', description: 'Routes requests', provider: 'anthropic', model: 'claude-haiku-4-5', status: 'observed',
    updatedAt: minutesAgo(60 * 24 * 40),
    stats: {
      window_days: 30, runs: 2071, run_sources: ['telemetry'], success_rate: 100, avg_duration_ms: 410,
      tokens: 90000, cost: 0.004, eval_score: 0.64, eval_samples_passed: 16, eval_samples_evaluated: 25, eval_runs: 1,
      eval_not_counted: 1, last_run_at: minutesAgo(60 * 3),
    },
  },
];

const props = (overrides = {}) => ({
  agents, onSelect() {}, onNew() {}, onBrowseTemplates() {}, onSortChange() {}, sort: 'recent', ...overrides,
});

const HEADERS = ['AGENT', 'MODEL', 'RUNS', 'ERRORS', 'AVG', 'EVAL', 'COST', 'LAST RUN'];

// The markup of one agent's row.
const rowFor = (html, name) => {
  const match = html.match(new RegExp(`<tr class="aa-row"[^>]*data-agent-name="${name}"[^>]*>[\\s\\S]*?<\\/tr>`));
  assert.ok(match, `a row for ${name}`);
  return match[0];
};

// The text of each cell of a row, tags stripped.
const cellsOf = (row) => [...row.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map(([, inner]) => inner.replace(/<[^>]+>/g, ''));

// --- The header ---------------------------------------------------------------

test('the page is titled Agents with its count, and the eight headers sit in the table head', () => {
  const html = render('AgentList', props());

  assert.match(html, /<h1 [^>]*>Agents<\/h1>/);
  assert.match(html, /<h1 [^>]*>Agents<\/h1><span style="font-family:var\(--font-mono\);font-size:13px;color:var\(--color-text-muted\)">3<\/span>/);

  const thead = html.match(/<thead>[\s\S]*?<\/thead>/)[0];
  const headers = [...thead.matchAll(/<th scope="col"[^>]*>([^<]*)<\/th>/g)].map(([, text]) => text);
  assert.deepEqual(headers, HEADERS);
  assert.match(thead, /title="Over the last 30 days">RUNS</);
  for (const name of ['RUNS', 'ERRORS', 'AVG', 'COST', 'LAST RUN']) {
    assert.match(thead, new RegExp(`text-align:right[^>]*>${name}<`), `${name} is right-aligned`);
  }
});

test('the header holds one filter, the server sort and a split New agent control', () => {
  const html = render('AgentList', props({ sort: 'popular' }));

  assert.match(html, /<label for="[^"]+" style="position:absolute;width:1px;height:1px[^"]*">Filter agents<\/label>/);
  assert.match(html, /<input id="[^"]+" type="search" placeholder="Filter {2}\/"[^>]*width:220px/);
  assert.match(html, /<select aria-label="Sort agents"/);
  assert.match(html, /<option value="popular" selected="">Most runs<\/option>/);
  assert.equal((html.match(/<option /g) || []).length, 5, 'only the sort offers options: no provider or status select');

  assert.match(html, /<button type="button" data-testid="new-agent"[^>]*border-top-right-radius:0;border-bottom-right-radius:0[^>]*>New agent<\/button>/);
  assert.match(html, /<button type="button" data-testid="new-agent-menu" aria-haspopup="menu" aria-expanded="false" aria-label="More ways to create an agent"[^>]*>v<\/button>/);
  assert.doesNotMatch(html, /From a template/, 'the menu is closed until opened');
  assert.doesNotMatch(html, /Browse Templates|Search agents|All Providers|All Status|Refresh/);
});

// --- The rows -----------------------------------------------------------------

test('each agent is one row that opens it, with no card, mascot or status pill', () => {
  const html = render('AgentList', props());

  assert.equal((html.match(/data-testid="agent-row"/g) || []).length, 3);
  for (const agent of agents) {
    const row = rowFor(html, agent.name);
    assert.match(row, /^<tr class="aa-row" data-testid="agent-row" data-agent-name="[^"]+" tabindex="0" aria-label="Open [^"]+"[^>]*cursor:pointer/);
    assert.doesNotMatch(row, /viewBox="0 0 500 500"/);
    assert.doesNotMatch(row, /data-testid="agent-card"|rounded-full|bg-green-100/);
  }
  assert.doesNotMatch(html, /<svg/, 'no icon font or heroicon anywhere on the page');
  assert.match(html, /<p [^>]*>Click a row to open it\.<\/p>/);
  assert.doesNotMatch(html, /Sort by any column/);
});

test('a busy agent reads its recorded figures: runs, error rate, average, eval bar, cost and last run', () => {
  const html = render('AgentList', props());
  const row = rowFor(html, 'SupportAgent');
  const cells = cellsOf(row);

  assert.equal(cells.length, 8);
  assert.equal(cells[0], 'SupportAgent');
  assert.equal(cells[1], 'claude-sonnet-4-5');
  assert.equal(cells[2], '1,284');
  assert.equal(cells[3], '0.6%');
  assert.equal(cells[4], '1.8s');
  assert.equal(cells[5], '91%');
  assert.equal(cells[6], '$12.40');
  assert.equal(cells[7], '2m ago');

  assert.match(row, /background:var\(--color-success\)/, 'the activity dot is green');
  assert.match(row, /title="anthropic · claude-sonnet-4-5"/);
  assert.match(row, /title="Counted from dashboard runs \+ reported telemetry"/);
  assert.match(row, /color:var\(--color-error-text\)">0\.6%</, 'an error rate above zero reads in the error colour');
  assert.match(row, /title="29\/32 · 91% passed over 2 current evaluations"/);
  assert.match(row, /width:64px;height:4px[^"]*background:var\(--color-muted\)/);
  assert.match(row, /width:91%;background:var\(--color-success\)/);
  assert.match(row, /title="Estimated from token counts at each model&#x27;s published rates"/);
  assert.match(row, /title="Updated 3d ago"[^>]*>2m ago</);
  assert.doesNotMatch(row, /Answers tickets/, 'no description subtitle');
});

test('an agent that never ran renders placeholders, never, and no invented percentage', () => {
  const html = render('AgentList', props());
  const row = rowFor(html, 'DataAnalyst');
  const cells = cellsOf(row);

  assert.equal(cells[2], '0');
  assert.equal(cells[3], '—');
  assert.equal(cells[4], '—');
  assert.equal(cells[5], '—');
  assert.equal(cells[6], '—');
  assert.equal(cells[7], 'never');
  assert.doesNotMatch(row, /%/, 'nothing ends in a percent sign, and no eval bar is drawn');
  assert.match(row, /background:var\(--color-text-muted\)/, 'the activity dot is muted');
  assert.match(row, /font-family:var\(--font-mono\);font-size:11px;color:var\(--color-text-muted\)">draft</);
  assert.match(row, /title="No evaluation counted yet"/);
  assert.match(row, /title="Updated 2h ago"/, 'updated_at is read as well as updatedAt');
  assert.doesNotMatch(row, /Updated [^"]*<\/td>/, 'the edit date is a tooltip, not the cell');
});

test('an observed agent carries its tag, a warning eval bar, a sub-cent cost and a zero error rate in the plain colour', () => {
  const html = render('AgentList', props());
  const row = rowFor(html, 'TriageAgent');
  const cells = cellsOf(row);

  assert.match(row, /font-size:11px;color:var\(--color-text-muted\)">observed</);
  assert.equal(cells[3], '0.0%');
  assert.doesNotMatch(row, /color:var\(--color-error-text\)/);
  assert.equal(cells[6], '&lt;$0.01', 'the sub-cent sign, HTML-escaped by the renderer');
  assert.equal(cells[5], '64%');
  assert.match(row, /width:64%;background:var\(--color-error\)/);
  assert.match(row, /title="16\/25 · 64% passed over 1 current evaluation · 1 stale or archived not counted"/);
  assert.match(row, /title="Counted from reported telemetry"/);
  assert.equal(cells[7], '3h ago');
});

test('an active agent carries no tag', () => {
  const row = rowFor(render('AgentList', props()), 'SupportAgent');
  assert.doesNotMatch(row, />active</);
});

// --- States ---------------------------------------------------------------------

test('with no agents the frame holds the empty state and the hint is gone', () => {
  const html = render('AgentList', props({ agents: [] }));

  assert.match(html, /<h1 [^>]*>Agents<\/h1><span [^>]*>0<\/span>/);
  assert.match(html, /<h2 [^>]*>No agents yet<\/h2>/);
  assert.match(html, /Create your first agent, or start from a template\./);
  assert.match(html, /viewBox="0 0 500 500"[^>]*width="96"/);
  assert.match(html, /<button type="button"[^>]*background:var\(--color-accent-ui\)[^>]*>New agent<\/button>/);
  assert.match(html, /<button type="button"[^>]*>Browse templates<\/button>/);
  assert.doesNotMatch(html, /<table|data-testid="agent-row"|Click a row/);
});

test('a loading list marks its frame busy', () => {
  assert.match(render('AgentList', props({ isLoading: true })), /aria-busy="true"/);
  assert.doesNotMatch(render('AgentList', props()), /aria-busy/);
});

test('the page uses tokens, not Tailwind colour classes or hex', () => {
  const html = render('AgentList', props());
  assert.doesNotMatch(html, /class="[^"]*(?:text-gray|bg-gray|text-white|bg-red|border-gray|text-red|text-green|bg-green)/);
  assert.doesNotMatch(html, /#[0-9a-f]{3,6}\b/i);
});
