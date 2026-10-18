import assert from 'node:assert/strict';
import test, { before, after } from 'node:test';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const output = fileURLToPath(new URL(`../node_modules/.cache/feedback-${process.pid}.mjs`, import.meta.url));
let view, window, container, root;
let calls = [];
let fail = false;
const payload = { total: 51, positive: 50, negative: 1, positive_percentage: 98, feedback: [{ id: 1, rating: 'negative', comment: '<script>bad()</script>', trace_id: 'trace-example', span_id: 'response-1', created_at: '2026-10-16T12:00:00Z' }] };
before(async () => {
  ({ window } = new JSDOM('<!doctype html><body><div id="root"></div></body>', { url: 'http://localhost/dashboard' }));
  for (const key of ['window', 'document', 'navigator', 'Event']) Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true });
  window.ACTIVE_AGENT_DASHBOARD = { mountPath: '/dashboard' };
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async url => { calls.push(url); return { ok: !fail, json: async () => payload }; };
  const result = await build({ stdin: { contents: `
    import React, { act } from 'react';
    import { createRoot } from 'react-dom/client';
    import Feedback from './components/dashboard/AgentFeedbackTab.jsx';
    export { act };
    export function mount(node) { const root = createRoot(node); root.render(React.createElement(Feedback, { agentId: 5, colors: {} })); return root; }
  `, resolveDir: fileURLToPath(new URL('..', import.meta.url)), loader: 'jsx' }, bundle: true, write: false, platform: 'node', format: 'esm', external: ['react', 'react-dom/client'], logLevel: 'error' });
  mkdirSync(dirname(output), { recursive: true }); writeFileSync(output, result.outputFiles[0].text);
  view = await import(pathToFileURL(output).href);
  container = window.document.getElementById('root');
});
after(async () => { if (root) await view.act(async () => root.unmount()); rmSync(output, { force: true }); window.close(); });

test('reviews comments safely, links traces under the mount, filters and paginates', async () => {
  await view.act(async () => { root = view.mount(container); });
  assert.match(container.textContent, /50 thumbs up/);
  assert.match(container.textContent, /51 ratings matching filters/);
  assert.equal(container.querySelector('script'), null);
  assert.match(container.textContent, /<script>bad\(\)<\/script>/);
  assert.equal(container.querySelector('a').getAttribute('href'), '/dashboard/traces?trace=trace-example');
  const next = [...container.querySelectorAll('button')].find(node => node.textContent === 'Next');
  await view.act(async () => next.click());
  assert.match(calls.at(-1), /page=2/);
  await view.act(async () => { const select = container.querySelector('select'); select.value = 'negative'; select.dispatchEvent(new window.Event('change', { bubbles: true })); });
  assert.match(calls.at(-1), /rating=negative/);
  assert.match(calls.at(-1), /page=1/);
  fail = true;
  await view.act(async () => [...container.querySelectorAll('button')].find(node => node.textContent === 'Refresh').click());
  assert.match(container.querySelector('[role=alert]').textContent, /Could not load feedback/);
});
