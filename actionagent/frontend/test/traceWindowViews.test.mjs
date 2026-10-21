import assert from 'node:assert/strict';
import test, { before, after } from 'node:test';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const output = fileURLToPath(new URL(`../node_modules/.cache/trace-window-${process.pid}.mjs`, import.meta.url));
let view, window, root, container;
const payload = { traces: [], agents: ['AuditAgent'], total_count: 1001, truncated: true,
  summary: { requests: 1001, errors: 1, avg_latency_ms: 190, throughput_per_minute: 33.4 },
  buckets: [{ start_ms: 0, end_ms: 1000, requests: 1001, errors: 1, avg_latency_ms: 190, agents: { AuditAgent: 1001 } }] };
before(async () => {
  ({ window } = new JSDOM('<!doctype html><body><div id="root"></div></body>', { url: 'http://localhost/dashboard' }));
  for (const key of ['window', 'document', 'navigator', 'localStorage']) Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true });
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  window.ACTIVE_AGENT_DASHBOARD = { mountPath: '/dashboard' };
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async () => ({ ok: true, json: async () => payload });
  const result = await build({ stdin: { contents: `
    import React, { act } from 'react';
    import { createRoot } from 'react-dom/client';
    import TracesView from './components/dashboard/TracesView.jsx';
    import { ThemeProvider } from './contexts/ThemeContext.jsx';
    import { TimeWindowProvider } from './contexts/TimeWindowContext.jsx';
    export { act };
    export function mount(node) { const root = createRoot(node); root.render(
      <ThemeProvider><TimeWindowProvider><TracesView /></TimeWindowProvider></ThemeProvider>); return root; }
  `, resolveDir: fileURLToPath(new URL('..', import.meta.url)), loader: 'jsx' }, bundle: true, write: false, platform: 'node', format: 'esm', external: ['react', 'react-dom/client', 'recharts'], logLevel: 'error' });
  mkdirSync(dirname(output), { recursive: true }); writeFileSync(output, result.outputFiles[0].text);
  view = await import(pathToFileURL(output).href);
  container = window.document.getElementById('root');
});
after(async () => { if (root) await view.act(async () => root.unmount()); rmSync(output, { force: true }); window.close(); });
for (const theme of ['light', 'dark']) {
  test(`${theme} mode shows full totals and the capped-detail notice`, async () => {
    if (root) await view.act(async () => root.unmount());
    localStorage.setItem('dashboard-theme', theme);
    await view.act(async () => { root = view.mount(container); });
    const notice = container.querySelector('[data-testid="trace-window-notice"]');
    assert.match(notice.textContent, /newest 0 of 1001/);
    assert.match(notice.textContent, /Chart and totals cover the full window/);
    assert.match(container.textContent, /1001/);
    assert.match(container.textContent, /190ms/);
    assert.match(container.textContent, /33.4/);
  });
}
