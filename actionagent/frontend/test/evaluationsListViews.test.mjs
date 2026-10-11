import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before, beforeEach } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';

// The Evaluations page as one table with a summary line and tabs, and the
// Catalogs tab's set table, mounted in jsdom against a stubbed API.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/evaluations-list-views-${process.pid}.mjs`, import.meta.url));

const agent = { id: 7, name: 'SupportAgent', slug: 'support-agent' };

// As ActionAgent::EvaluationSerializer.evaluation writes one: the summary,
// the latest run in full, the run before it as a summary.
const runSummary = (id, number, passed, total, extra = {}) => ({
  id, number, status: 'complete', average_score: passed / total, samples_evaluated: total, samples_passed: passed,
  completed_at: '2026-10-09T12:00:00Z', created_at: '2026-10-09T11:00:00Z', sandbox: null,
  agent_version: { id: 3, number: 3 }, version_state: 'current', ...extra,
});
const run = (id, number, passed, total, models, extra = {}) => ({
  ...runSummary(id, number, passed, total, extra), scores: {}, selection: {}, models, usage: {}, error_message: null,
});

const suite = {
  id: 1, name: 'Support suite', agent, judge_kind: 'llm', judge_model: 'gpt-5-mini', criteria: [],
  compare_models: ['openai/gpt-5-mini', 'anthropic/claude-haiku-4-5'], config: {}, sample_size: null,
  scenario_suite: true, scenario_count: 4, scenario_groups: [], created_at: '2026-10-01T10:00:00Z', run_count: 5,
  headline_run_id: 15, standing: 'current', archived_at: null, per_model: {},
  latest_run: run(15, 5, 7, 8, ['openai/gpt-5-mini', 'anthropic/claude-haiku-4-5']),
  previous_run: runSummary(14, 4, 4, 8, { version_state: 'earlier' }),
  headline_run: null,
};

const archived = {
  id: 2, name: 'Response quality', agent, judge_kind: 'llm', judge_model: 'gpt-5-mini',
  criteria: [{ type: 'response_present', config: {} }], compare_models: [], config: {}, sample_size: 20,
  scenario_suite: false, scenario_count: 0, scenario_groups: [], created_at: '2026-09-20T10:00:00Z', run_count: 1,
  headline_run_id: 21, standing: 'archived', archived_at: '2026-10-05T10:00:00Z', per_model: {},
  latest_run: run(21, 1, 14, 20, []),
  previous_run: null,
  headline_run: null,
};

// What the index returns: both evaluations under archived=1, and — to pin
// that the tabs sort by standing rather than by what the API left out —
// both without it too.
const index = {
  evaluations: [suite, archived],
  archived_count: 1,
  judge_provider: 'openai',
  judge_provider_error: false,
  model_providers: ['openai', 'anthropic'],
};

const catalog = {
  id: 1, key: 'support_desk', name: 'Support Desk', description: 'The support desk under test',
  source_kind: 'repository', source_path: '.activeagents/evals/support_desk.yml', digest: 'abc123',
  product_count: 1, scenario_count: 2, synced: false, synced_at: null,
};

const catalogFull = {
  ...catalog,
  metadata: {},
  products: [
    {
      id: 10, key: 'triage', name: 'Triage', description: null, agent_name: 'TriageAgent', agent: { id: 8, name: 'TriageAgent' }, project: null,
      set_count: 1, scenario_count: 2,
      sets: [
        {
          id: 100, key: 'smoke', name: 'Smoke', description: 'The questions every release must answer', judge: null,
          criteria_count: 0, scenario_count: 2, evaluation: null, latest_run: null,
          scenarios: [
            { id: 1000, key: 'refund_request', prompt: 'A customer asks for a refund on order 1042.', notes: null, expectations: { tools: ['lookup_order'], contains: ['refund'] }, tags: [], params: {}, production_only: false, enabled: true, position: 0 },
            { id: 1001, key: 'angry_customer', prompt: 'I have been waiting three weeks and nobody answers!', notes: null, expectations: { not_contains: ['unfortunately'] }, tags: ['tone'], params: {}, production_only: false, enabled: true, position: 1 },
          ],
        },
      ],
    },
  ],
};

let window;
let dashboard;
let responses;
let requests;

before(async () => {
  ({ window } = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/evaluations' }));
  for (const key of ['window', 'document', 'navigator', 'localStorage']) {
    Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true, writable: true });
  }
  window.localStorage.setItem('dashboard-theme', 'light');
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async (url, init = {}) => {
    const method = init.method || 'GET';
    requests.push({ method, url, body: init.body ? JSON.parse(init.body) : null });
    const body = responses[`${method} ${url}`];
    return { ok: Boolean(body), status: body ? 200 : 404, json: async () => body || {} };
  };

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React, { act } from 'react';
        import { createRoot } from 'react-dom/client';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import EvaluationsView from './components/dashboard/EvaluationsView.jsx';
        import ScenarioCatalogsView, { expectationSummary } from './components/dashboard/ScenarioCatalogsView.jsx';

        const views = { EvaluationsView, ScenarioCatalogsView };
        export { act, expectationSummary };
        export function mount(container, name, props) {
          const reactRoot = createRoot(container);
          reactRoot.render(React.createElement(ThemeProvider, null, React.createElement(views[name], props)));
          return reactRoot;
        }
      `,
      resolveDir: root,
      loader: 'jsx',
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'node',
    external: ['react', 'react-dom', 'react-dom/client'],
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  dashboard = await import(pathToFileURL(bundlePath).href);
});

after(() => rmSync(bundlePath, { force: true }));

beforeEach(() => {
  requests = [];
  responses = {
    'GET /api/evaluations': index,
    'GET /api/evaluations?archived=1': index,
    'GET /api/evaluations/1': { evaluation: { ...suite, scenarios: [], runs: [suite.latest_run, suite.previous_run] } },
    'GET /api/agents': { agents: [agent, { id: 8, name: 'TriageAgent' }] },
    'GET /api/projects': { projects: [] },
    'GET /api/scenario_catalogs': { catalogs: [catalog], storage_available: false },
    'GET /api/scenario_catalogs/1': { catalog: catalogFull },
  };
  delete window.ACTIVE_AGENT_DASHBOARD;
  window.history.replaceState({}, '', '/evaluations');
  document.body.innerHTML = '';
});

// Flushes React work and pending fetches until `check` returns something, or
// fails after a second.
async function waitFor(check, description) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const found = check();
    if (found) return found;
    await dashboard.act(() => new Promise((resolve) => setTimeout(resolve, 10)));
  }
  assert.fail(`timed out waiting for ${description}`);
}

async function mounted(name, props, run) {
  const container = document.body.appendChild(document.createElement('div'));
  let reactRoot;
  await dashboard.act(async () => { reactRoot = dashboard.mount(container, name, props); });
  try {
    await run(container);
  } finally {
    await dashboard.act(async () => reactRoot.unmount());
  }
}

const click = (element) => dashboard.act(async () => { element.click(); });
const rows = (container) => [...container.querySelectorAll('[data-testid="evaluation-card"]')];
const tabs = (container) => [...container.querySelectorAll('[role="tab"]')].map((tab) => [tab.textContent, tab.getAttribute('aria-selected')]);
// The element's text with a space between adjacent nodes, as a reader sees it.
const text = (element) => {
  const walker = document.createTreeWalker(element, window.NodeFilter.SHOW_TEXT);
  const parts = [];
  while (walker.nextNode()) parts.push(walker.currentNode.textContent);
  return parts.join(' ').replace(/\s+/g, ' ').trim();
};

// --- Evaluations -----------------------------------------------------------

test('the Evaluations page is a titled table with tabs, a summary line and one row per evaluation that stands', async () => {
  await mounted('EvaluationsView', {}, async (container) => {
    await waitFor(() => rows(container).length === 1, 'the suite row');

    assert.equal(container.querySelector('h1').textContent, 'Evaluations');
    assert.equal(container.querySelector('p'), null, 'no subtitle under the title');
    assert.equal(container.querySelector('[data-testid="new-evaluation-button"]').textContent, 'New evaluation');
    assert.equal(container.querySelector('input[type="search"]').getAttribute('placeholder'), 'Filter by name or agent');

    // The tabs: what stands, the catalogs, and what was put away, with counts.
    assert.equal(container.querySelector('[role="tablist"]').getAttribute('aria-label'), 'Evaluation views');
    assert.deepEqual(tabs(container), [['Evaluations1', 'true'], ['Catalogs', 'false'], ['Archived1', 'false']]);
    assert.equal(container.querySelector('[data-testid="show-archived-toggle"]').getAttribute('role'), 'tab');

    // The summary line: the headline runs' passes, what they ask to fix, what they cost.
    const summary = text(container.querySelector('[data-testid="evaluations-summary"]'));
    assert.match(summary, /^Passed 7\/8 88% Fixes 0 Cost · headline runs —$/);

    // The column headers, mono uppercase by style.
    const headers = [...container.querySelector('[data-testid="evaluations-header-row"]').children].map((cell) => cell.textContent);
    assert.deepEqual(headers, ['Evaluation', 'Agent', 'Latest run', 'Vs previous', 'Fixes', 'Models', 'Ran', '']);
    assert.match(container.querySelector('[data-testid="evaluations-header-row"] > span').getAttribute('style'), /font-family: var\(--font-mono\); font-size: 11px;.*text-transform: uppercase/);

    // One row: the suite, open by default, with one status and no glyphs.
    const [row] = rows(container);
    assert.equal(row.getAttribute('role'), 'button');
    assert.equal(row.getAttribute('data-kind'), 'suite');
    assert.equal(row.getAttribute('data-open'), 'true');
    assert.equal(row.getAttribute('data-standing'), 'current');
    assert.equal(row.getAttribute('data-telemetry'), 'false');
    assert.equal(row.getAttribute('aria-expanded'), 'true');
    assert.equal(row.querySelector('[data-testid="evaluation-kind"]').textContent, 'Scenarios');
    assert.equal(text(row.querySelector('[data-testid="evaluation-latest-run"]')), '7/8 · 88%');
    const cells = [...row.children].map(text);
    assert.equal(cells[0], 'Support suite Scenarios');
    assert.equal(cells[1], 'SupportAgent');
    assert.equal(cells[3], '+3 vs #4');
    assert.equal(cells[4], '—');
    assert.equal(cells[5], 'gpt-5-mini, claude-haiku-4-5');
    assert.equal(row.querySelector('[data-testid="evaluation-archive-toggle"]').textContent, 'archive');
    assert.doesNotMatch(row.textContent, /\[\+\]|\[!\]/, 'no status glyphs in a row');

    // The open suite's panel sits under its row, loaded from the per-evaluation GET.
    assert.ok(requests.some(({ url }) => url === '/api/evaluations/1'));
    await waitFor(() => container.querySelector('[data-testid="scenario-suite-panel"]'), 'the suite panel');
    assert.equal(container.querySelector('[data-testid="evaluations-summary"] + div [data-testid="scenario-suite-panel"]') !== null, true);
    assert.equal(container.querySelector('p'), null, 'no footnote: no row says older version');
  });
});

test('the Archived tab lists only what was put away, and the Evaluations tab never does', async () => {
  await mounted('EvaluationsView', {}, async (container) => {
    await waitFor(() => rows(container).length === 1, 'the suite row');
    assert.equal(rows(container)[0].getAttribute('data-standing'), 'current', 'the archived evaluation stays off the Evaluations tab');

    await click(container.querySelector('[data-testid="show-archived-toggle"]'));
    await waitFor(() => requests.some(({ url }) => url === '/api/evaluations?archived=1'), 'the archived fetch');
    await waitFor(() => rows(container).length === 1 && rows(container)[0].getAttribute('data-standing') === 'archived', 'the archived row');

    assert.deepEqual(tabs(container), [['Evaluations1', 'false'], ['Catalogs', 'false'], ['Archived1', 'true']]);
    assert.equal(container.querySelector('[data-testid="evaluations-summary"]'), null, 'no summary over the archive');
    const [row] = rows(container);
    assert.equal(row.getAttribute('data-kind'), 'sampling');
    assert.equal(row.querySelector('[data-testid="evaluation-kind"]').textContent, 'Sampled');
    assert.equal(row.querySelector('[data-testid="evaluation-archive-toggle"]').textContent, 'unarchive');
    assert.equal([...row.children].map(text)[3], 'first run');

    // Back to what stands.
    await click(container.querySelectorAll('[role="tab"]')[0]);
    await waitFor(() => rows(container).length === 1 && rows(container)[0].getAttribute('data-standing') === 'current', 'the suite row again');
    assert.ok(container.querySelector('[data-testid="evaluations-summary"]'));
  });
});

test('a row opens and closes in place, and the filter narrows the rows', async () => {
  await mounted('EvaluationsView', {}, async (container) => {
    await waitFor(() => rows(container).length === 1, 'the suite row');
    await click(rows(container)[0]);
    assert.equal(rows(container)[0].getAttribute('data-open'), 'false');
    assert.equal(container.querySelector('[data-testid="scenario-suite-panel"]'), null);
    assert.equal(window.location.pathname, '/evaluations');
    await click(rows(container)[0]);
    assert.equal(rows(container)[0].getAttribute('data-open'), 'true');
    assert.equal(window.location.pathname, '/evaluations/1');

    const input = container.querySelector('input[type="search"]');
    await dashboard.act(async () => {
      Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(input, 'nothing like this');
      input.dispatchEvent(new window.Event('input', { bubbles: true }));
    });
    assert.equal(rows(container).length, 0);
    assert.match(container.querySelector('[data-testid="evaluations-empty"]').textContent, /Nothing matches “nothing like this”/);
  });
});

test('the New evaluation button opens the form and reads Cancel while it is open', async () => {
  await mounted('EvaluationsView', {}, async (container) => {
    await waitFor(() => rows(container).length === 1, 'the suite row');
    const button = container.querySelector('[data-testid="new-evaluation-button"]');
    await click(button);
    assert.equal(button.textContent, 'Cancel');
    assert.ok(container.querySelector('form, [data-testid="evaluation-form"]') || container.textContent.includes('Create'), 'the form renders');
  });
});

test('embedded in the agent page, the list has no title, no Agent column and no Catalogs tab', async () => {
  responses['GET /api/evaluations?agent_id=7'] = index;
  await mounted('EvaluationsView', { embedded: true, agentId: 7 }, async (container) => {
    await waitFor(() => rows(container).length === 1, 'the suite row');
    assert.equal(container.querySelector('h1'), null);
    assert.equal(container.querySelector('input[type="search"]').getAttribute('placeholder'), 'Filter by name');
    assert.deepEqual(tabs(container), [['Evaluations1', 'true'], ['Archived1', 'false']]);
    const headers = [...container.querySelector('[data-testid="evaluations-header-row"]').children].map((cell) => cell.textContent);
    assert.deepEqual(headers, ['Evaluation', 'Latest run', 'Vs previous', 'Fixes', 'Models', 'Ran', '']);
  });
});

test('the Catalogs section renders the catalogs under the same header and tabs', async () => {
  window.history.replaceState({}, '', '/catalogs');
  await mounted('EvaluationsView', { section: 'catalogs' }, async (container) => {
    await waitFor(() => container.querySelector('[data-testid="catalog-row"]'), 'the catalog row');
    assert.equal(container.querySelector('h1').textContent, 'Evaluations');
    assert.deepEqual(tabs(container).map(([label, selected]) => [label.replace(/\d+$/, ''), selected]), [['Evaluations', 'false'], ['Catalogs', 'true'], ['Archived', 'false']]);
    assert.equal(container.querySelector('[data-testid="new-evaluation-button"]'), null, 'the catalogs tab has its own Import control');
    assert.ok([...container.querySelectorAll('button')].some((button) => button.textContent === 'Import catalog'));
    assert.equal(container.querySelectorAll('h1').length, 1, 'the embedded catalogs list adds no title');
  });
});

// --- Catalogs --------------------------------------------------------------

test('a catalog opens to one table of its sets, each row opening to its scenarios', async () => {
  await mounted('ScenarioCatalogsView', { embedded: true }, async (container) => {
    const row = await waitFor(() => container.querySelector('[data-testid="catalog-row"]'), 'the catalog row');
    assert.deepEqual([...row.querySelectorAll('td')].map(text), ['Support Desk support_desk · .activeagents/evals/support_desk.yml', '1', '2', 'database only']);

    await click(row);
    await waitFor(() => container.querySelector('[data-testid="catalog-sets-table"]'), 'the sets table');

    assert.equal(container.querySelector('h1').textContent, 'Support Desk');
    assert.deepEqual([...container.querySelectorAll('nav[aria-label="Breadcrumb"] button')].map((crumb) => crumb.textContent), ['Evaluations', 'Catalogs']);
    assert.match(container.textContent, /support_desk · \.activeagents\/evals\/support_desk\.yml · not synced/);
    assert.doesNotMatch(container.textContent, /digest/);
    const menu = container.querySelector('[data-testid="catalog-menu"]');
    assert.equal(menu.getAttribute('aria-label'), 'More: export YAML, restore, re-import, delete');
    assert.equal([...container.querySelectorAll('button')].some((button) => button.textContent === 'Write to storage'), false, 'no storage: no sync action');

    const headers = [...container.querySelectorAll('[data-testid="catalog-sets-table"] th')].map((cell) => cell.textContent);
    assert.deepEqual(headers, ['Set', 'Product · agent', 'Scenarios', 'Latest run', 'Run against', '']);
    const set = container.querySelector('[data-testid="catalog-set-row"]');
    const cells = [...set.querySelectorAll('td')].map(text);
    assert.equal(cells[0], 'Smoke The questions every release must answer');
    assert.equal(cells[1], 'Triage · TriageAgent');
    assert.equal(cells[2], '2');
    assert.equal(cells[3], 'never run');
    assert.equal(set.querySelector('select[aria-label="Run against"]').value, 'agent:8');
    assert.equal(set.querySelector('td:last-child button').textContent, 'Run set');
    assert.equal(container.querySelector('p').textContent, 'Running a set creates or reuses the evaluation support_desk/<product>/<set>.');

    await click(set);
    const scenarios = await waitFor(() => container.querySelector('[data-testid="catalog-set-scenarios"]'), 'the scenario list');
    const lines = [...scenarios.querySelectorAll('td > div > div')].map(text);
    assert.deepEqual(lines, [
      'refund_request A customer asks for a refund on order 1042. calls lookup_order · says “refund”',
      'angry_customer I have been waiting three weeks and nobody answers! never says “unfortunately” · tone',
    ]);

    // The menu opens to its actions, the destructive one last.
    await click(menu);
    assert.deepEqual([...container.querySelectorAll('[role="menuitem"]')].map((item) => item.textContent), ['Export YAML', 'Re-import YAML', 'Delete']);

    // Running the set posts the chosen target.
    responses['POST /api/scenario_catalogs/1/sets/100/run'] = { run: { id: 5 }, evaluation: { name: 'support_desk/triage/smoke' } };
    await click(set.querySelector('td:last-child button'));
    await waitFor(() => requests.some(({ method }) => method === 'POST'), 'the run request');
    assert.deepEqual(requests.find(({ method }) => method === 'POST').body, { agent_id: 8 });
    await waitFor(() => container.querySelector('[role="status"]'), 'the run notice');
    assert.match(container.querySelector('[role="status"]').textContent, /Run #5 of Smoke started/);
  });
});

test('expectations summarise as what the scenario calls, says and never says', () => {
  assert.equal(dashboard.expectationSummary({ tools: ['lookup_order', 'refund'], contains: ['refund'], not_contains: ['unfortunately'] }),
    'calls lookup_order · calls refund · says “refund” · never says “unfortunately”');
  assert.equal(dashboard.expectationSummary({ tools: 'lookup_order' }), 'calls lookup_order');
  assert.equal(dashboard.expectationSummary({}), '');
  assert.equal(dashboard.expectationSummary(null), '');
});
