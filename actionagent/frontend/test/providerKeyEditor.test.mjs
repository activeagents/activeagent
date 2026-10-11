import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';

// The Settings API Keys tab, mounted in jsdom and driven through clicks and
// typing. ProviderKeysCard keeps no state of its own: whoever renders it
// holds useProviderKeyEditor, so what the card shows outlives the card. In
// Settings that is a tab switch, which unmounts the card and mounts it again.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/provider-key-editor-${process.pid}.mjs`, import.meta.url));

const providerKeys = [
  { provider: 'anthropic', kind: 'key', configured: false, hint: null, host_based: false },
  {
    provider: 'ollama', kind: 'host', configured: true, hint: 'http://gpu:11434/v1', host_based: true,
    api_key_configured: false, platform_default: 'http://localhost:11434/v1',
  },
];

const responses = {
  'GET /api/api_keys': { api_keys: [] },
  'GET /api/provider_keys': { provider_keys: providerKeys },
  'POST /api/provider_keys/test': { ok: true, host: 'http://gpu:11434', latency_ms: 12, models: ['llama3', 'qwen3'] },
};

let window;
let dashboard;

before(async () => {
  ({ window } = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/settings?tab=api-keys' }));
  for (const key of ['window', 'document', 'navigator', 'localStorage']) {
    Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true, writable: true });
  }
  window.localStorage.setItem('dashboard-theme', 'light');
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async (url, init = {}) => {
    const body = responses[`${init.method || 'GET'} ${url}`];
    return { ok: Boolean(body), status: body ? 200 : 404, json: async () => body || {} };
  };

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React, { act } from 'react';
        import { createRoot } from 'react-dom/client';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import SettingsView from './components/dashboard/SettingsView.jsx';

        export { act };
        export function mount(container) {
          const reactRoot = createRoot(container);
          reactRoot.render(React.createElement(ThemeProvider, null, React.createElement(SettingsView, { user: { name: 'Ada Lovelace' } })));
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

const buttonIn = (scope, text) => [...scope.querySelectorAll('button')].find((button) => button.textContent.trim() === text);

const providerRow = (container, label) => [...container.querySelectorAll('div.p-4.rounded-lg')]
  .find((row) => row.querySelector('p.font-medium')?.textContent === label);

async function click(button) {
  await dashboard.act(async () => { button.click(); });
}

async function type(input, value) {
  await dashboard.act(async () => {
    Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(input, value);
    input.dispatchEvent(new window.Event('input', { bubbles: true }));
  });
}

test('an open provider key edit and a connection test result survive switching Settings tabs', async () => {
  const container = document.body.appendChild(document.createElement('div'));
  let reactRoot;
  await dashboard.act(async () => { reactRoot = dashboard.mount(container); });

  try {
    const ollama = await waitFor(() => providerRow(container, 'Ollama'), 'the Ollama row');
    await click(buttonIn(ollama, 'Test connection'));
    await waitFor(() => providerRow(container, 'Ollama').querySelector('[role="status"]'), 'the connection test result');

    await click(buttonIn(providerRow(container, 'Anthropic'), 'Configure'));
    await type(container.querySelector('input[aria-label="Anthropic API key"]'), 'sk-ant-typed');

    await click(buttonIn(container, 'Appearance'));
    assert.equal(providerRow(container, 'Anthropic'), undefined, 'the Appearance tab still shows the provider keys card');

    await click(buttonIn(container, 'API Keys'));
    assert.equal(container.querySelector('input[aria-label="Anthropic API key"]')?.value, 'sk-ant-typed');
    assert.match(
      providerRow(container, 'Ollama').querySelector('[role="status"]')?.textContent ?? '',
      /Connected to http:\/\/gpu:11434 in 12 ms · 2 models/,
    );
  } finally {
    await dashboard.act(async () => reactRoot.unmount());
  }
});
