import assert from 'node:assert/strict';
import test, { before, after } from 'node:test';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// The MCP Services page's "Your MCP servers" panel, rendered: it lists the
// owner's servers with masked headers, and adds, edits and tests them through
// the API without ever holding a stored header value.

const output = fileURLToPath(new URL(`../node_modules/.cache/mcp-server-configs-${process.pid}.mjs`, import.meta.url));
let view, window, container, root;
const calls = [];
const stored = {
  id: 7, key: 'custom:7', name: 'Orders', description: null, url: 'https://app.example.com/mcp', enabled: true,
  headers: [{ name: 'Authorization', hint: '••••0001' }], tools: ['find_order'],
  last_tested_at: '2026-10-27T12:00:00Z', last_test_status: 'ok', last_test_error: null,
};

const respond = (body, status = 200) => ({ ok: status < 400, status, json: async () => body });

before(async () => {
  ({ window } = new JSDOM('<!doctype html><body><div id="root"></div></body>', { url: 'http://localhost/dashboard' }));
  for (const key of ['window', 'document', 'navigator', 'Event']) {
    Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true });
  }
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url, method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : null });
    if (url === '/api/mcp_server_configs' && !init.method) {
      return respond({ mcp_server_configs: [stored], allow_private_hosts: false, can_manage: true });
    }
    if (url.endsWith('/test')) return respond({ ok: true, tools: ['find_order', 'cancel_order'], error: null, mcp_server_config: stored });
    return respond({ mcp_server_config: { ...stored, name: 'Inventory' } }, init.method === 'POST' ? 201 : 200);
  };
  const result = await build({
    stdin: {
      contents: `
        import React, { act } from 'react';
        import { createRoot } from 'react-dom/client';
        import Panel from './components/dashboard/McpServerConfigsPanel.jsx';
        export { act };
        export function mount(node, onChanged) { const root = createRoot(node); root.render(React.createElement(Panel, { onChanged })); return root; }
      `,
      resolveDir: fileURLToPath(new URL('..', import.meta.url)),
      loader: 'jsx',
    },
    bundle: true, write: false, platform: 'node', format: 'esm', external: ['react', 'react-dom/client'], logLevel: 'error',
  });
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, result.outputFiles[0].text);
  view = await import(pathToFileURL(output).href);
  container = window.document.getElementById('root');
});

after(async () => {
  if (root) await view.act(async () => root.unmount());
  rmSync(output, { force: true });
  window.close();
});

const button = (text) => [...container.querySelectorAll('button')].find((node) => node.textContent === text);
const input = (label) => container.querySelector(`input[aria-label="${label}"]`);

// React tracks an input's value through the native setter, so a test sets it
// there and dispatches the input event React listens for.
async function type(node, value) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  await view.act(async () => {
    setter.call(node, value);
    node.dispatchEvent(new window.Event('input', { bubbles: true }));
  });
}

test('lists, adds, edits and tests servers without handling a stored header value', async () => {
  let changes = 0;
  await view.act(async () => { root = view.mount(container, () => { changes += 1; }); });

  assert.match(container.textContent, /Orders/);
  assert.match(container.textContent, /Connected · 1 tool/);
  assert.match(container.textContent, /Authorization: ••••0001/);

  await view.act(async () => button('Add server').click());
  await view.act(async () => button('+ Add header').click());
  await type(input('Server name'), 'Inventory');
  await type(input('Server URL'), 'https://inventory.example.com/mcp');
  await type(input('Header 1 name'), 'X-Api-Key');
  await view.act(async () => container.querySelector('[data-testid="mcp-server-config-save"]').click());
  assert.match(container.querySelector('[role=alert]').textContent, /X-Api-Key needs a value/);
  assert.equal(calls.filter((call) => call.method === 'POST').length, 0, 'an invalid form is not sent');

  await type(input('Header 1 value'), 'inventory-key');
  await view.act(async () => container.querySelector('[data-testid="mcp-server-config-save"]').click());
  const created = calls.find((call) => call.method === 'POST' && call.url === '/api/mcp_server_configs');
  assert.deepEqual(created.body.mcp_server_config.headers, [{ name: 'X-Api-Key', value: 'inventory-key' }]);
  assert.equal(changes, 1);

  await view.act(async () => button('Edit').click());
  const value = input('Header 1 value');
  assert.equal(value.value, '');
  assert.match(value.getAttribute('placeholder'), /••••0001 — leave blank to keep/);
  await view.act(async () => container.querySelector('[data-testid="mcp-server-config-save"]').click());
  const updated = calls.find((call) => call.method === 'PATCH');
  assert.equal(updated.url, '/api/mcp_server_configs/7');
  assert.deepEqual(updated.body.mcp_server_config.headers, [{ name: 'Authorization', value: '' }]);

  await view.act(async () => container.querySelector('[data-testid="mcp-server-config-test-7"]').click());
  assert.ok(calls.some((call) => call.method === 'POST' && call.url === '/api/mcp_server_configs/7/test'));
  assert.match(container.textContent, /Orders answered with 2 tools/);
});
