import assert from 'node:assert/strict';
import test, { before, after, afterEach } from 'node:test';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const output = fileURLToPath(new URL(`../node_modules/.cache/trace-controls-${process.pid}.mjs`, import.meta.url));
let view, window, root, container, payload;
const requests = [];
const trace = (spans = []) => ({
  id: 'synthetic-trace', short_id: 'synthetic', display_name: 'LookupAgent.search',
  agent: 'LookupAgent', action: 'search', status: 'OK', duration_ms: 500,
  timestamp_ms: Date.now(), spans,
});

before(async () => {
  ({ window } = new JSDOM('<!doctype html><body><div id="root"></div></body>', { url: 'http://localhost/dashboard' }));
  for (const key of ['window', 'document', 'navigator', 'localStorage']) {
    Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true });
  }
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  window.ACTIVE_AGENT_DASHBOARD = { mountPath: '/dashboard' };
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async (url) => {
    requests.push(String(url));
    return { ok: true, json: async () => payload };
  };
  const result = await build({
    stdin: { contents: `
      import React, { act } from 'react';
      import { createRoot } from 'react-dom/client';
      import TracesView from './components/dashboard/TracesView.jsx';
      import { ThemeProvider } from './contexts/ThemeContext.jsx';
      import { TimeWindowProvider } from './contexts/TimeWindowContext.jsx';
      export { act };
      export function mount(node, props) { const root = createRoot(node); root.render(
        <ThemeProvider><TimeWindowProvider><TracesView {...props} /></TimeWindowProvider></ThemeProvider>); return root; }
    `, resolveDir: fileURLToPath(new URL('..', import.meta.url)), loader: 'jsx' },
    bundle: true, write: false, platform: 'node', format: 'esm',
    external: ['react', 'react-dom/client', 'recharts'], logLevel: 'error',
  });
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, result.outputFiles[0].text);
  view = await import(pathToFileURL(output).href);
  container = window.document.getElementById('root');
});

afterEach(async () => {
  if (root) await view.act(async () => root.unmount());
  root = null;
});
after(() => { rmSync(output, { force: true }); window.close(); });

async function mount(theme, traces, props = {}) {
  localStorage.clear();
  localStorage.setItem('dashboard-theme', theme);
  requests.length = 0;
  payload = { traces, agents: ['LookupAgent'] };
  await view.act(async () => { root = view.mount(container, props); });
}

async function clickButton(label) {
  const button = [...container.querySelectorAll('button')].find((node) => node.textContent.trim().toLowerCase() === label);
  assert.ok(button, `missing ${label} button`);
  await view.act(async () => button.click());
}

for (const theme of ['light', 'dark']) {
  test(`${theme} Tools view shows aggregated calls, durations and failures`, async () => {
    await mount(theme, [trace([
      { type: 'tool', name: 'tool.search_docs', duration: 20 },
      { type: 'tool', name: 'ignored', attributes: { 'tool.name': 'search_docs' }, duration: 40, error: 'Synthetic failure' },
      { type: 'tool', name: 'tool.lookup_order', duration: 300 },
      { type: 'llm', name: 'provider.generate', duration: 500 },
    ])]);
    await clickButton('tools');
    const name = [...container.querySelectorAll('[title]')].find((node) => node.title === 'search_docs');
    assert.ok(name, 'tool results must render after selecting Tools');
    assert.equal(window.getComputedStyle(name).color, theme === 'dark' ? 'rgb(255, 255, 255)' : 'rgb(17, 24, 39)');
    const row = name.parentElement.parentElement;
    assert.match(row.textContent, /LookupAgent#search/);
    assert.match(row.textContent, /2\s*\(1\)/);
    assert.deepEqual([...row.children].slice(2).map((cell) => cell.textContent), ['60ms', '30ms', '40ms']);
    assert.equal(row.querySelector('[title="1 failed"]').textContent, '(1)');
    const names = [...container.querySelectorAll('[title]')].map((node) => node.title).filter((title) => ['search_docs', 'lookup_order'].includes(title));
    assert.deepEqual(names, ['lookup_order', 'search_docs']);
  });

  test(`${theme} Tools view explains when there are no tool calls`, async () => {
    await mount(theme, [trace()]);
    await clickButton('tools');
    assert.match(container.textContent, /No tool calls in this window/);
  });
}

for (const theme of ['light', 'dark']) {
  test(`${theme} time window refreshes tool results and preserves the embedded agent`, async () => {
    await mount(theme, [trace([{ type: 'tool', name: 'tool.search_docs', duration: 20 }])], { embedded: true, agentId: 42 });
    await clickButton('tools');
    const selector = container.querySelector('select[aria-label="Time window"]');
    assert.ok(selector, 'the time window must be selectable in either theme');
    assert.equal(selector.value, '30m');
    const initialQuery = new URL(requests.at(-1), window.location.origin).searchParams;
    assert.equal(initialQuery.get('minutes'), '30');
    assert.equal(initialQuery.get('agent_id'), '42');

    payload = { traces: [trace([{ type: 'tool', name: 'tool.lookup_order', duration: 300 }])], agents: ['LookupAgent'] };
    await view.act(async () => {
      selector.value = '1h';
      selector.dispatchEvent(new window.Event('change', { bubbles: true }));
    });
    const query = new URL(requests.at(-1), window.location.origin).searchParams;
    assert.equal(query.get('minutes'), '60');
    assert.equal(query.get('bucket_seconds'), '120');
    assert.equal(query.get('agent_id'), '42');
    assert.equal(localStorage.getItem('activeagents.timeWindow'), '1h');
    assert.ok(container.querySelector('[title="lookup_order"]'));
    assert.equal(container.querySelector('[title="search_docs"]'), null);
  });

  test(`${theme} time-window zoom respects the shortest and longest windows`, async () => {
    await mount(theme, []);
    const selector = container.querySelector('select[aria-label="Time window"]');
    assert.ok(selector, 'the time window must remain available for empty results');
    const choose = async (id) => view.act(async () => {
      selector.value = id;
      selector.dispatchEvent(new window.Event('change', { bubbles: true }));
    });
    await choose('5m');
    assert.equal(container.querySelector('button[aria-label="Zoom in"]').disabled, true);
    await view.act(async () => container.querySelector('button[aria-label="Zoom out"]').click());
    assert.equal(selector.value, '10m');
    await choose('90d');
    assert.equal(container.querySelector('button[aria-label="Zoom out"]').disabled, true);
    await view.act(async () => container.querySelector('button[aria-label="Zoom in"]').click());
    assert.equal(selector.value, '30d');
  });
}
