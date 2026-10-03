import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';

// rrweb's real recorder, run in jsdom over the dashboard's own views: the
// Run Agent workbench through useSessionCapture, and the views that show
// credentials through a capture started by hand. Every batch the dashboard
// API receives is kept, so the assertions read exactly what the server would
// store.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/session-capture-dom-${process.pid}.mjs`, import.meta.url));
const recorderUrl = import.meta.resolve('@rrweb/record');

const API_TOKEN = 'aa_createdApiToken0123456789abcdef';
const TELEMETRY_KEY = 'tk_telemetryKey0123456789abcdef';
const TYPED_KEY = 'sk-ant-typedProviderKey0123456789';
const CSRF_TOKEN = 'csrf-token-0123456789abcdef';

const agent = { id: 3, name: 'Support Bot', provider: 'mock', model: 'mock', instructions: 'Help.', tools: [], status: 'active' };

const routes = {
  'GET /api/agents/3/runs?per_page=10': () => ({ runs: [] }),
  'GET /api/agents/3/conversations?action_name=ask': () => ({ conversations: [{ id: 5, message_count: 1 }] }),
  'GET /api/interactions/5': () => ({ interaction: { id: 5, messages: [{ id: 1, role: 'user', content: 'Where is my order?' }] } }),
  'GET /api/api_keys': () => ({ api_keys: [] }),
  'GET /api/provider_keys': () => ({ provider_keys: [{ provider: 'anthropic', kind: 'key', configured: false, hint: null, host_based: false }] }),
  'POST /api/api_keys': () => ({ api_key: { id: 9, name: 'ci', token: API_TOKEN } }),
  'GET /api/usage': () => ({ usage: null }),
  'GET /api/telemetry_key': () => ({ telemetry_api_key: TELEMETRY_KEY }),
  'POST /api/session_recordings': () => ({ recording: { id: 41 } }),
};

let window;
let dashboard;
let requests = [];
// The status the dashboard API answers each batch with.
let batchStatus = 201;

function batches() {
  return requests.filter((request) => request.key === 'POST /api/session_recordings/41/events').map((request) => request.body);
}

before(async () => {
  ({ window } = new JSDOM(
    `<!doctype html><html><head><meta name="csrf-token" content="${CSRF_TOKEN}"></head><body></body></html>`,
    { url: 'http://localhost/agents/3/run?tab=api-keys' },
  ));
  // rrweb reads DOM constructors (HTMLFormElement, CSSStyleSheet, ...) as globals.
  Object.defineProperty(globalThis, 'window', { value: window, configurable: true, writable: true });
  for (const key of Object.getOwnPropertyNames(window)) {
    if (key in globalThis) continue;
    try {
      Object.defineProperty(globalThis, key, { value: window[key], configurable: true, writable: true });
    } catch {
      // A property jsdom does not let us read off the window.
    }
  }
  for (const key of ['document', 'navigator', 'localStorage', 'MutationObserver', 'Event']) {
    Object.defineProperty(globalThis, key, { value: window[key], configurable: true, writable: true });
  }
  window.localStorage.setItem('dashboard-theme', 'light');
  window.ACTIVE_AGENT_DASHBOARD = { meta: { signOutPath: '/session' } };
  // jsdom does not implement form submission. The sign-out test reads the form
  // the header builds, not where it goes.
  window.HTMLFormElement.prototype.submit = () => {};
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  Object.defineProperty(window.navigator, 'clipboard', { value: { writeText: async () => {} }, configurable: true });
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async (url, init = {}) => {
    const key = `${init.method || 'GET'} ${url}`;
    requests.push({ key, body: init.body });
    if (key.endsWith('/events')) return { ok: batchStatus < 300, status: batchStatus, json: async () => ({}) };
    const route = routes[key];
    return { ok: Boolean(route), status: route ? 200 : 404, json: async () => (route ? route() : {}) };
  };

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React, { act } from 'react';
        import { createRoot } from 'react-dom/client';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import AgentRunner from './components/dashboard/AgentRunner.jsx';
        import SettingsView from './components/dashboard/SettingsView.jsx';
        import OrganizationView from './components/dashboard/OrganizationView.jsx';
        import Header from './components/dashboard/Header.jsx';

        export { act };

        const VIEWS = { runner: AgentRunner, settings: SettingsView, organization: OrganizationView, header: Header };

        // Renders the named views, as the dashboard renders one view at a time.
        export function mount(container) {
          const reactRoot = createRoot(container);
          return {
            show: (views, props) => reactRoot.render(
              React.createElement(ThemeProvider, null, ...views.map((view) => React.createElement(VIEWS[view], { key: view, ...props })))
            ),
            unmount: () => reactRoot.unmount(),
          };
        }
      `,
      resolveDir: root,
      loader: 'jsx',
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'node',
    // recharts (reached through AgentEditor) is CommonJS that requires react, which an ESM bundle cannot.
    external: ['react', 'react-dom', 'react-dom/client', 'recharts'],
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  dashboard = await import(pathToFileURL(bundlePath).href);
});

after(() => rmSync(bundlePath, { force: true }));

// Flushes React work and pending fetches until `check` returns something, or
// fails after two seconds.
async function waitFor(check, description) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const found = check();
    if (found) return found;
    await dashboard.act(() => new Promise((resolve) => setTimeout(resolve, 10)));
  }
  assert.fail(`timed out waiting for ${description}`);
}

const buttonIn = (scope, text) => [...scope.querySelectorAll('button')].find((button) => button.textContent.trim() === text);

async function click(button) {
  await dashboard.act(async () => { button.click(); });
}

async function type(input, value) {
  await dashboard.act(async () => {
    Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(input, value);
    input.dispatchEvent(new window.Event('input', { bubbles: true }));
  });
}

test('the workbench is recorded while it is open, and the view navigated to is not', async () => {
  requests = [];
  const container = document.body.appendChild(document.createElement('div'));
  const view = dashboard.mount(container);

  try {
    await dashboard.act(async () => view.show(['runner'], { agent, recorderUrl, user: { name: 'Ada' } }));
    await waitFor(() => container.querySelector('[data-testid="runner-recording-notice"]'), 'the recording notice');
    assert.ok(requests.some((request) => request.key === 'POST /api/session_recordings' && request.body === JSON.stringify({ agent_context_id: 5 })));

    // Outside act(), as a navigation after a fetch renders: act() runs an
    // effect's cleanup before the commit's DOM changes reach the recorder,
    // and a scheduled render runs it after.
    globalThis.IS_REACT_ACT_ENVIRONMENT = false;
    try {
      view.show(['settings'], { user: { name: 'Ada' } });
      for (let attempt = 0; attempt < 100 && !container.querySelector('input[placeholder="Key name (e.g. production)"]'); attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    } finally {
      globalThis.IS_REACT_ACT_ENVIRONMENT = true;
    }
    await type(await waitFor(() => container.querySelector('input[placeholder="Key name (e.g. production)"]'), 'the key name field'), 'ci');
    await click(buttonIn(container, '+ Create New Key'));
    await waitFor(() => container.textContent.includes(API_TOKEN), 'the created key');
    await waitFor(() => batches().length > 0, 'the final batch');

    const recorded = batches().join('\n');
    assert.match(recorded, /Where is my order\?/, 'the workbench was recorded');
    assert.doesNotMatch(recorded, /API Keys|Create New Key/, 'the Settings view was recorded');
    assert.ok(!recorded.includes(API_TOKEN));
    assert.ok(!recorded.includes(CSRF_TOKEN));
  } finally {
    await dashboard.act(async () => view.unmount());
    container.remove();
  }
});

test('the workbench says so when a visit is over the recording\'s caps', async () => {
  requests = [];
  batchStatus = 413;
  const container = document.body.appendChild(document.createElement('div'));
  const view = dashboard.mount(container);

  try {
    await dashboard.act(async () => view.show(['runner'], { agent, recorderUrl, user: { name: 'Ada' } }));
    await waitFor(() => container.querySelector('[data-testid="runner-recording-notice"]'), 'the recording notice');

    await dashboard.act(async () => { window.dispatchEvent(new window.Event('pagehide')); });
    await waitFor(() => container.querySelector('[data-testid="runner-recording-stopped"]'), 'the stopped notice');

    assert.equal(container.querySelector('[data-testid="runner-recording-notice"]'), null);
    assert.equal(batches().length, 1);
  } finally {
    batchStatus = 201;
    await dashboard.act(async () => view.unmount());
    container.remove();
  }
});

test('the workbench records nothing without a recorder URL', async () => {
  requests = [];
  const container = document.body.appendChild(document.createElement('div'));
  const view = dashboard.mount(container);

  try {
    await dashboard.act(async () => view.show(['runner'], { agent, recorderUrl: null }));
    await waitFor(() => container.textContent.includes('Where is my order?'), 'the conversation');

    assert.equal(requests.filter((request) => request.key.includes('session_recordings')).length, 0);
    assert.equal(container.querySelector('[data-testid="runner-recording-notice"]'), null);
  } finally {
    await dashboard.act(async () => view.unmount());
    container.remove();
  }
});

test('a recording of the views that show credentials holds none of them', async () => {
  requests = [];
  const container = document.body.appendChild(document.createElement('div'));
  const view = dashboard.mount(container);
  const { createSessionCapture } = await import('../utils/sessionCapture.mjs');
  const capture = createSessionCapture({ contextId: 5, loadRecorder: () => import(recorderUrl), fetch: (path, init) => fetch(path, init) });

  try {
    await dashboard.act(async () => view.show(['settings', 'organization'], { user: { name: 'Ada' } }));
    await waitFor(() => buttonIn(container, 'Configure'), 'the provider keys card');
    await capture.start();
    assert.equal(capture.state, 'recording');

    await click(buttonIn(container, 'Configure'));
    await type(container.querySelector('input[aria-label="Anthropic API key"]'), TYPED_KEY);
    await type(container.querySelector('input[placeholder="Key name (e.g. production)"]'), 'ci');
    await click(buttonIn(container, '+ Create New Key'));
    await waitFor(() => container.textContent.includes(API_TOKEN), 'the created key');
    await click(buttonIn(container, 'Show'));
    await waitFor(() => container.textContent.includes(TELEMETRY_KEY), 'the telemetry key');
    await capture.stop();

    const recorded = batches().join('\n');
    assert.match(recorded, /API Keys/, 'the page was recorded');
    for (const secret of [API_TOKEN, TELEMETRY_KEY, TYPED_KEY, CSRF_TOKEN]) {
      assert.ok(!recorded.includes(secret), `${secret} is in the recording`);
    }
  } finally {
    await capture.stop();
    await dashboard.act(async () => view.unmount());
    container.remove();
  }
});

test('signing out while recording leaves the CSRF token out of the recording', async () => {
  requests = [];
  const container = document.body.appendChild(document.createElement('div'));
  const view = dashboard.mount(container);
  const { createSessionCapture } = await import('../utils/sessionCapture.mjs');
  const capture = createSessionCapture({ contextId: 5, loadRecorder: () => import(recorderUrl), fetch: (path, init) => fetch(path, init) });

  try {
    await dashboard.act(async () => view.show(['header'], { user: { name: 'Ada' } }));
    await capture.start();
    assert.equal(capture.state, 'recording');

    await click(buttonIn(container, 'A'));
    await click(buttonIn(container, 'Sign out'));
    assert.ok(document.querySelector('form[action="/session"] input[name="authenticity_token"]'), 'the sign-out form was added');
    await capture.stop();

    const recorded = batches().join('\n');
    assert.match(recorded, /"tagName":"form"/, 'the sign-out form was recorded');
    assert.ok(!recorded.includes(CSRF_TOKEN), 'the CSRF token is in the recording');
  } finally {
    await capture.stop();
    await dashboard.act(async () => view.unmount());
    container.remove();
    document.querySelectorAll('form[action="/session"]').forEach((form) => form.remove());
  }
});
