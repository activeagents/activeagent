import assert from 'node:assert/strict';
import test, { before, after } from 'node:test';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const output = fileURLToPath(new URL(`../node_modules/.cache/judge-routing-${process.pid}.mjs`, import.meta.url));
let view, window, root, container;
before(async () => {
  ({ window } = new JSDOM('<!doctype html><body><div id="root"></div></body>', { url: 'http://localhost/dashboard' }));
  for (const key of ['window', 'document', 'navigator']) Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true });
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const models = { anthropic: ['claude-haiku-4-5'], openai: ['gpt-4o-mini'], openrouter: ['anthropic/claude-haiku-4.5'], ollama: ['llama3.2'] };
  globalThis.fetch = async (url) => ({ ok: true, json: async () => ({ models: models[new URL(url, window.location.href).searchParams.get('provider')] || [] }) });
  const result = await build({ stdin: { contents: `
    import React, { act } from 'react';
    import { createRoot } from 'react-dom/client';
    import EvaluationForm from './components/dashboard/evaluations/EvaluationForm.jsx';
    export { act };
    export function mount(node) { const root = createRoot(node); root.render(<EvaluationForm agents={[]}
      judgeProvider="anthropic" modelProviders={['anthropic','openai','openrouter','ollama']} />); return root; }
  `, resolveDir: fileURLToPath(new URL('..', import.meta.url)), loader: 'jsx' }, bundle: true, write: false, platform: 'node', format: 'esm', external: ['react', 'react-dom/client'], logLevel: 'error' });
  mkdirSync(dirname(output), { recursive: true }); writeFileSync(output, result.outputFiles[0].text);
  view = await import(pathToFileURL(output).href);
  container = window.document.getElementById('root');
});
after(async () => { if (root) await view.act(async () => root.unmount()); rmSync(output, { force: true }); window.close(); });

test('the judge picker offers credentialed native and explicit gateway routes', async () => {
  await view.act(async () => { root = view.mount(container); });
  const label = [...container.querySelectorAll('label')].find((node) => node.textContent === 'Judge model (optional)');
  const input = document.getElementById(label.htmlFor);
  const options = [...document.getElementById(input.getAttribute('list')).querySelectorAll('option')].map((node) => node.value);
  assert.deepEqual(options, ['claude-haiku-4-5', 'gpt-4o-mini', 'openrouter/anthropic/claude-haiku-4.5', 'ollama/llama3.2']);
  assert.match(document.getElementById(input.getAttribute('aria-describedby')).textContent, /unpinned judge defaults to Anthropic/);
  assert.match(container.textContent, /Pinning a model selects its provider/);
});
