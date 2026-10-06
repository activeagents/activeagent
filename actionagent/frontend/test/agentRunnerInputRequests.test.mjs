import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before, beforeEach } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';

// The runner with runs paused for input, mounted in jsdom against a stubbed
// API and driven through clicks: opening runs from Recent Runs, a `?run=`
// link, and answering a request inline.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/agent-runner-input-requests-${process.pid}.mjs`, import.meta.url));

const AGENT = { id: 5, name: 'SupportBot', instructions: '', tools: [], action_prompts: [{ name: 'summarize', prompt: 'Summarize it' }] };

const textRequest = (id, runId) => ({
  id, kind: 'text', status: 'pending', prompt: `Question ${id}?`, options: null, tool_name: 'ask_user', arguments: null,
  agent: { id: AGENT.id, name: AGENT.name }, run_id: runId, actor: null, created_at: '2026-10-01T10:00:00Z', expires_at: null,
});

const pausedRun = { id: 42, status: 'awaiting_input', action_name: 'ask', context_id: 1, input_prompt: 'hi', logs: [], input_requests: [textRequest(7, 42)], created_at: '2026-10-01T10:00:00Z' };
const finishedRun = { id: 43, status: 'complete', action_name: 'ask', context_id: 2, input_prompt: 'other', logs: [], input_requests: [], output: 'done', created_at: '2026-10-01T09:00:00Z' };
const summarizeRun = { id: 44, status: 'awaiting_input', action_name: 'summarize', context_id: 3, input_prompt: 'sum', logs: [], input_requests: [textRequest(8, 44)], created_at: '2026-10-01T11:00:00Z' };

let window;
let dashboard;
let responses;
let posts;
let gets;

function stubApi() {
  posts = [];
  gets = [];
  responses = {
    'GET /api/agents/5/runs?per_page=10': { runs: [pausedRun, finishedRun] },
    'GET /api/agents/5/conversations?action_name=ask': { conversations: [{ id: 1, message_count: 1 }, { id: 2, message_count: 2 }] },
    'GET /api/agents/5/conversations?action_name=summarize': { conversations: [{ id: 3, message_count: 1 }] },
    'GET /api/interactions/1': { interaction: { id: 1, messages: [] } },
    'GET /api/interactions/2': { interaction: { id: 2, messages: [] } },
    'GET /api/interactions/3': { interaction: { id: 3, messages: [] } },
    'GET /api/runs/42': { run: pausedRun, agent: { id: 5 } },
    'GET /api/runs/43': { run: finishedRun, agent: { id: 5 } },
    'GET /api/runs/44': { run: summarizeRun, agent: { id: 5 } },
  };
}

before(async () => {
  ({ window } = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/agents/5/run' }));
  for (const key of ['window', 'document', 'navigator', 'localStorage', 'CustomEvent', 'Event']) {
    Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true, writable: true });
  }
  window.localStorage.setItem('dashboard-theme', 'light');
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async (url, init = {}) => {
    const method = init.method || 'GET';
    (method === 'GET' ? gets : posts).push(method === 'GET' ? url : { url, body: init.body });
    // A function stands for a response that arrives when its promise settles.
    const entry = responses[`${method} ${url}`];
    const body = typeof entry === 'function' ? await entry() : entry;
    return { ok: Boolean(body), status: body ? 200 : 404, json: async () => body || {} };
  };

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React, { act } from 'react';
        import { createRoot } from 'react-dom/client';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import AgentRunner from './components/dashboard/AgentRunner.jsx';

        export { act };
        export function mount(container, agent) {
          const reactRoot = createRoot(container);
          reactRoot.render(React.createElement(ThemeProvider, null, React.createElement(AgentRunner, { agent })));
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
    // The runner's Generative UI pulls in recharts, which is CommonJS and
    // requires react at runtime; an ES module has no require of its own.
    banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" },
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  dashboard = await import(pathToFileURL(bundlePath).href);
});

after(() => rmSync(bundlePath, { force: true }));

beforeEach(() => {
  stubApi();
  window.history.replaceState({}, '', '/agents/5/run');
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

async function withRunner(callback) {
  const container = document.body.appendChild(document.createElement('div'));
  let reactRoot;
  await dashboard.act(async () => { reactRoot = dashboard.mount(container, AGENT); });
  try {
    await callback(container);
  } finally {
    await dashboard.act(async () => reactRoot.unmount());
    container.remove();
  }
}

const runButton = (container) => container.querySelector('[data-testid="runner-run"]').textContent.trim();
const cards = (container) => container.querySelectorAll('[data-testid="input-request-card"]');
const recentRun = (container, index) => container.querySelectorAll('[data-testid="runner-recent-run"]')[index];

async function click(element) {
  await dashboard.act(async () => { element.click(); });
}

test('opening another conversation from Recent Runs lets go of a paused run, and its row brings it back', async () => {
  await withRunner(async (container) => {
    await waitFor(() => recentRun(container, 1), 'the Recent Runs rows');

    await click(recentRun(container, 0));
    await waitFor(() => cards(container).length === 1, 'the paused run’s request');
    assert.match(runButton(container), /Waiting for input/);

    await click(recentRun(container, 1));
    await waitFor(() => /Run$/.test(runButton(container)), 'the runner to be free again');
    assert.equal(cards(container).length, 0, 'the paused run’s card is still on screen');
    assert.equal(container.querySelector('[data-testid="runner-new-conversation"]').disabled, false, 'New conversation is still disabled');
    assert.equal(container.querySelector('[data-testid="runner-conversation-select"]').value, '2');

    await click(recentRun(container, 0));
    await waitFor(() => cards(container).length === 1, 'the paused run’s request again');
    assert.match(runButton(container), /Waiting for input/);
    assert.equal(container.querySelector('[data-testid="runner-conversation-select"]').value, '1');
  });
});

test('a ?run= link opens the run under its own action and conversation', async () => {
  window.history.replaceState({}, '', '/agents/5/run?run=44');

  await withRunner(async (container) => {
    await waitFor(() => cards(container).length === 1, 'the linked run’s request');
    await waitFor(() => container.querySelector('[data-testid="runner-action-select"]').value === 'summarize', 'the run’s action');
    assert.equal(container.querySelector('[data-testid="runner-conversation-select"]').value, '3');
  });
});

test('answering a request inline polls the same run to its end', async () => {
  responses['POST /api/input_requests/7/answer'] = { input_request: { id: 7, status: 'answered' } };

  await withRunner(async (container) => {
    await waitFor(() => recentRun(container, 0), 'the Recent Runs rows');
    await click(recentRun(container, 0));
    const field = await waitFor(() => cards(container)[0]?.querySelector('textarea'), 'the answer field');

    responses['GET /api/runs/42'] = { run: { ...pausedRun, status: 'complete', input_requests: [] }, agent: { id: 5 } };
    await dashboard.act(async () => {
      Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(field, 'blue');
      field.dispatchEvent(new window.Event('input', { bubbles: true }));
    });
    await click(cards(container)[0].querySelector('button[type="submit"]'));

    await waitFor(() => /Run$/.test(runButton(container)), 'the run to finish');
    assert.deepEqual(posts, [{ url: '/api/input_requests/7/answer', body: JSON.stringify({ answer: 'blue' }) }]);
    assert.equal(cards(container).length, 0, 'a finished run still shows its requests');
  });
});

test('an answer that lands after the page let go of its run polls nothing', async () => {
  let deliverAnswer;
  responses['POST /api/input_requests/7/answer'] = () => new Promise((resolve) => {
    deliverAnswer = () => resolve({ input_request: { id: 7, status: 'answered' } });
  });

  await withRunner(async (container) => {
    await waitFor(() => recentRun(container, 1), 'the Recent Runs rows');
    await click(recentRun(container, 0));
    const field = await waitFor(() => cards(container)[0]?.querySelector('textarea'), 'the answer field');
    await dashboard.act(async () => {
      Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(field, 'blue');
      field.dispatchEvent(new window.Event('input', { bubbles: true }));
    });
    await click(cards(container)[0].querySelector('button[type="submit"]'));
    await waitFor(() => deliverAnswer, 'the answer to be posted');

    await click(recentRun(container, 1));
    await waitFor(() => /Run$/.test(runButton(container)), 'the runner to be free again');
    const pollsBefore = gets.filter((url) => url === '/api/runs/42').length;

    await dashboard.act(async () => deliverAnswer());
    await dashboard.act(() => new Promise((resolve) => setTimeout(resolve, 50)));

    assert.equal(gets.filter((url) => url === '/api/runs/42').length, pollsBefore, 'the let-go run was polled');
    assert.equal(container.querySelector('[data-testid="runner-conversation-select"]').value, '2');
    assert.equal(cards(container).length, 0, 'a card of the let-go run is on screen');
  });
});
