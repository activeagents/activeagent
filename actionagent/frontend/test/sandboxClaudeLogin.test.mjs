import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import test, { before, after } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
const directory = fileURLToPath(new URL('..', import.meta.url));
const bundle = `${directory}/node_modules/.cache/login-${process.pid}.mjs`;
const sandbox = { session_id: 'fixture', status: 'ready', repository: 'fixture/support' };
const item = { kind: 'fault', fault: 'expected_tool_not_called', scenario_keys: ['lookup'], models: ['mock/demo'] };
let window, views, login, requests, fixes, afterCode;
before(async () => {
  ({ window } = new JSDOM('<!doctype html><body></body>', { url: 'http://localhost/settings' }));
  for (const key of ['window', 'document', 'navigator', 'localStorage']) Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true, writable: true });
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  window.HTMLDialogElement.prototype.showModal = function () { this.open = true; };
  window.HTMLDialogElement.prototype.close = function () { this.open = false; };
  window.open = () => ({ location: 'about:blank', close() {} });
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async (url, init = {}) => {
    const method = init.method || 'GET'; requests.push({ url, method, body: init.body });
    let body;
    if (url === '/api/provider_keys') body = { provider_keys: [] };
    if (url.startsWith('/api/sandboxes?')) body = { sandboxes: [sandbox], claude_code_auth: 'sandbox_login', claude_code_connected: !!login.logged_in };
    if (url.endsWith('/fixes')) body = fixes || { project: { id: 1 }, sandboxes: [sandbox], code_sessions: [], supported: true, auth_mode: 'sandbox_login' };
    if (url.endsWith('/claude_login')) {
      if (method === 'POST') login = { status: 'awaiting_code', logged_in: false, authorize_url: 'https://claude.ai/oauth/authorize?client_id=fixture' };
      if (method === 'DELETE') login = { status: 'disconnected', logged_in: false };
      body = { login };
    }
    if (url.endsWith('/claude_login/code')) { login = afterCode || { status: 'connected', logged_in: true, auth_method: 'claude.ai' }; body = { login }; }
    return { ok: !!body, status: body ? 200 : 404, json: async () => body || {} };
  };
  const { outputFiles } = await build({ stdin: { contents: `
    import React, { act } from 'react'; import { createRoot } from 'react-dom/client';
    import { ThemeProvider } from './contexts/ThemeContext.jsx';
    import Settings from './components/dashboard/ClaudeCodeIntegrationCard.jsx';
    import Fix from './components/dashboard/evaluations/ImplementFixButton.jsx';
    export { act };
    export function mount(node, name, props, copies = 1) {
      const root = createRoot(node);
      const View = name === 'settings' ? Settings : Fix;
      root.render(React.createElement(ThemeProvider, null, ...Array.from({ length: copies }, (_, i) => React.createElement(View, { key: i, ...props }))));
      return root;
    }`, resolveDir: directory, loader: 'jsx' }, bundle: true, write: false, platform: 'node', format: 'esm', external: ['react', 'react-dom', 'react-dom/client'], logLevel: 'error' });
  mkdirSync(`${directory}/node_modules/.cache`, { recursive: true }); writeFileSync(bundle, outputFiles[0].text);
  views = await import(pathToFileURL(bundle).href);
});
after(() => { rmSync(bundle, { force: true }); window.close(); });
const button = (node, label) => [...node.querySelectorAll('button')].find((entry) => entry.textContent.trim() === label);
const click = async (node) => views.act(async () => { assert.ok(node); node.click(); });
async function waitFor(check) {
  for (let i = 0; i < 180; i += 1) {
    if (check()) return check();
    await views.act(() => new Promise((resolve) => setTimeout(resolve, 10)));
  }
  assert.fail('Expected UI did not appear');
}
for (const name of ['settings', 'fix']) test(`${name} shares the login protocol, clears the code and never silently launches a session`, async () => {
  requests = []; login = { status: 'disconnected', logged_in: false };
  const node = document.body.appendChild(document.createElement('div')); let mounted;
  await views.act(async () => { mounted = views.mount(node, name, { item, evaluation: { id: 1, name: 'Support' }, run: { id: 7 } }); });
  try {
    if (name === 'fix') await click(await waitFor(() => button(node, 'Implement with Claude Code')));
    await waitFor(() => button(node, 'Sign in with your Claude subscription'));
    await click(button(node, 'Sign in with your Claude subscription'));
    const input = await waitFor(() => node.querySelector('input[placeholder="Paste the code from Claude"]'));
    assert.equal(input.type, 'password'); assert.ok(input.hasAttribute('data-aa-secret'));
    await views.act(async () => {
      Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(input, 'one-use-fixture');
      input.dispatchEvent(new window.Event('input', { bubbles: true }));
    });
    await click(button(node, 'Complete connection'));
    assert.equal(input.value, '');
    await waitFor(() => !node.querySelector('dialog[aria-label="Connect your Claude subscription"]'));
    assert.match(node.textContent, /Your subscription connected/);
    const codes = requests.filter((request) => request.url.endsWith('/claude_login/code'));
    assert.equal(codes.length, 1); assert.deepEqual(JSON.parse(codes[0].body), { claude_login_code: 'one-use-fixture' });
    assert.equal(localStorage.getItem('claude_login_code'), null);
    assert.equal(requests.filter((request) => request.method === 'POST' && request.url.endsWith('/code_sessions')).length, 0);
  } finally { await views.act(async () => mounted.unmount()); node.remove(); }
});

test('the cards of one run share one workspace load, and stay hidden where a fix cannot run', async () => {
  login = { status: 'disconnected', logged_in: false };
  for (const [workspace, shown] of [[null, true], [{ project: null, sandboxes: [], code_sessions: [], supported: true, auth_mode: 'api_key' }, false], [{ project: { id: 1 }, sandboxes: [], code_sessions: [], supported: false, auth_mode: 'api_key' }, false]]) {
    requests = []; fixes = workspace;
    const node = document.body.appendChild(document.createElement('div')); let mounted;
    await views.act(async () => { mounted = views.mount(node, 'fix', { item, evaluation: { id: 1, name: 'Support' }, run: { id: 7 } }, 3); });
    try {
      await waitFor(() => requests.length > 0);
      await views.act(() => new Promise((resolve) => setTimeout(resolve, 20)));
      assert.equal(requests.filter((request) => request.url.endsWith('/fixes')).length, 1);
      assert.equal(node.querySelectorAll('[data-testid="implement-fix"]').length, shown ? 3 : 0);
    } finally { await views.act(async () => mounted.unmount()); node.remove(); fixes = null; }
  }
});

test('a sign-in that completes without a Claude subscription stops polling and says why', async () => {
  requests = []; login = { status: 'disconnected', logged_in: false }; afterCode = { status: 'completed', logged_in: false, auth_method: null };
  const node = document.body.appendChild(document.createElement('div')); let mounted;
  await views.act(async () => { mounted = views.mount(node, 'settings', {}); });
  try {
    await click(await waitFor(() => button(node, 'Sign in with your Claude subscription')));
    const input = await waitFor(() => node.querySelector('input[placeholder="Paste the code from Claude"]'));
    await views.act(async () => {
      Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(input, 'one-use-fixture');
      input.dispatchEvent(new window.Event('input', { bubbles: true }));
    });
    await click(button(node, 'Complete connection'));
    await waitFor(() => /not with a Claude subscription/.test(node.textContent));
    const polls = requests.filter((request) => request.method === 'GET' && request.url.endsWith('/claude_login')).length;
    await views.act(() => new Promise((resolve) => setTimeout(resolve, 1500)));
    assert.equal(requests.filter((request) => request.method === 'GET' && request.url.endsWith('/claude_login')).length, polls);
    assert.ok(button(node, 'Start sign-in again'));
  } finally { await views.act(async () => mounted.unmount()); node.remove(); afterCode = null; }
});
