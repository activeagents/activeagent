import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before, beforeEach } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';

// The Organization page's team table and provider keys, and Settings when
// members keep personal keys, mounted in jsdom against a stubbed API.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/organization-keys-${process.pid}.mjs`, import.meta.url));

const organizationKeys = [
  {
    provider: 'anthropic', kind: 'key', configured: true, hint: 'sk-a…tion', host_based: false, scope: 'organization',
    set_by: { id: 3, name: 'Grace' }, updated_at: '2026-10-02T10:00:00Z', effective_source: 'personal',
  },
  { provider: 'openai', kind: 'key', configured: false, hint: null, host_based: false, scope: 'organization', effective_source: 'none' },
  { provider: 'claude_code', kind: 'connection', configured: true, hint: 'sk-a…ffff', scope: 'organization' },
];

const personalKeys = [
  { provider: 'anthropic', kind: 'key', configured: true, hint: 'sk-a…-ada', host_based: false, scope: 'personal', effective_source: 'personal' },
  { provider: 'openai', kind: 'key', configured: false, hint: null, host_based: false, scope: 'personal', effective_source: 'organization' },
];

let window;
let dashboard;
let responses;
let requests;

before(async () => {
  ({ window } = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/settings?tab=api-keys' }));
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
        import OrganizationView from './components/dashboard/OrganizationView.jsx';
        import SettingsView from './components/dashboard/SettingsView.jsx';

        const views = { OrganizationView, SettingsView };
        export { act };
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
    'GET /api/usage': { usage: {} },
    'GET /api/members': {
      members: [
        { id: 1, name: 'Ada Lovelace', email: 'ada@example.com', role: 'admin' },
        { id: 3, name: 'Grace Hopper', email: 'grace@example.com', role: null },
      ],
    },
    'GET /api/provider_keys?scope=organization': { provider_keys: organizationKeys, can_manage_organization_keys: true },
    'GET /api/api_keys': { api_keys: [] },
    'GET /api/provider_keys?scope=personal': { provider_keys: personalKeys },
    'POST /api/provider_keys': { provider_key: {} },
  };
  delete window.ACTIVE_AGENT_DASHBOARD;
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

const buttonIn = (scope, text) => [...scope.querySelectorAll('button')].find((button) => button.textContent.trim() === text);
const providerRow = (container, label) => [...container.querySelectorAll('div.p-4.rounded-lg')]
  .find((row) => row.querySelector('p.font-medium')?.textContent === label);
const teamRows = (container) => [...container.querySelectorAll('tbody tr')]
  .map((row) => [...row.querySelectorAll('td')].map((cell) => cell.textContent.trim()));

test('the team table lists the members the API returns, with no invite link unless one is configured', async () => {
  await mounted('OrganizationView', { user: { id: 1, name: 'Ada Lovelace' } }, async (container) => {
    await waitFor(() => container.querySelectorAll('tbody tr').length === 2, 'two members');
    assert.deepEqual(teamRows(container), [
      ['AAda Lovelace(you)ada@example.com', 'Admin'],
      ['GGrace Hoppergrace@example.com', '—'],
    ]);
    assert.equal([...container.querySelectorAll('a, button')].some((element) => element.textContent.includes('Invite Member')), false);
  });
});

test('the invite link goes to the configured invitation page', async () => {
  window.ACTIVE_AGENT_DASHBOARD = { meta: { memberInviteUrl: '/team/invitations/new' } };

  await mounted('OrganizationView', { user: { id: 1 } }, async (container) => {
    const invite = await waitFor(() => [...container.querySelectorAll('a')].find((link) => link.textContent.includes('Invite Member')), 'the invite link');
    assert.equal(invite.getAttribute('href'), '/team/invitations/new');
  });
});

test("the Organization page manages the organization's keys and says who set them", async () => {
  await mounted('OrganizationView', { user: { id: 1 } }, async (container) => {
    const anthropic = await waitFor(() => providerRow(container, 'Anthropic'), 'the Anthropic row');
    assert.match(anthropic.querySelector('[data-testid="provider-key-audit"]').textContent, /^Set by Grace · updated /);
    assert.equal(anthropic.querySelector('[data-testid="provider-key-source"]'), null);
    assert.equal(providerRow(container, 'claude_code'), undefined, 'connection credentials stay on their own cards');

    await dashboard.act(async () => { buttonIn(providerRow(container, 'OpenAI'), 'Configure').click(); });
    const input = container.querySelector('input[aria-label="OpenAI API key"]');
    await dashboard.act(async () => {
      Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(input, 'sk-org');
      input.dispatchEvent(new window.Event('input', { bubbles: true }));
    });
    await dashboard.act(async () => { buttonIn(providerRow(container, 'OpenAI'), 'Save').click(); });

    await waitFor(() => requests.some(({ method }) => method === 'POST'), 'the save');
    assert.deepEqual(requests.find(({ method }) => method === 'POST').body, { provider: 'openai', credential: 'sk-org', scope: 'organization' });
  });
});

test('a member who may not manage organization keys sees them read-only', async () => {
  responses['GET /api/provider_keys?scope=organization'] = { provider_keys: organizationKeys, can_manage_organization_keys: false };

  await mounted('OrganizationView', { user: { id: 3 } }, async (container) => {
    const anthropic = await waitFor(() => providerRow(container, 'Anthropic'), 'the Anthropic row');
    await waitFor(() => container.textContent.includes('You can see these keys but not change them.'), 'the read-only note');
    assert.equal(anthropic.querySelector('button'), null);
  });
});

test("with personal keys on, Settings manages the caller's own keys and badges each provider's source", async () => {
  window.ACTIVE_AGENT_DASHBOARD = { meta: { personalProviderKeys: true } };

  await mounted('SettingsView', { user: { name: 'Ada Lovelace' } }, async (container) => {
    const anthropic = await waitFor(() => providerRow(container, 'Anthropic'), 'the Anthropic row');
    assert.ok(requests.some(({ url }) => url === '/api/provider_keys?scope=personal'));
    assert.match(container.textContent, /Your Provider Keys/);
    assert.equal(anthropic.querySelector('[data-testid="provider-key-source"]').textContent, 'Your key');
    assert.equal(providerRow(container, 'OpenAI').querySelector('[data-testid="provider-key-source"]').textContent, 'Organization key');

    await dashboard.act(async () => { buttonIn(providerRow(container, 'OpenAI'), 'Configure').click(); });
    const input = container.querySelector('input[aria-label="OpenAI API key"]');
    await dashboard.act(async () => {
      Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(input, 'sk-mine');
      input.dispatchEvent(new window.Event('input', { bubbles: true }));
    });
    await dashboard.act(async () => { buttonIn(providerRow(container, 'OpenAI'), 'Save').click(); });

    await waitFor(() => requests.some(({ method }) => method === 'POST'), 'the save');
    assert.deepEqual(requests.find(({ method }) => method === 'POST').body, { provider: 'openai', credential: 'sk-mine', scope: 'personal' });
  });
});
