import assert from 'node:assert/strict';
import test, { after, before } from 'node:test';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// ThemeProvider mounted in a jsdom window whose prefers-color-scheme query
// this suite controls: the system choice follows the query and its change
// events, the fixed choices ignore them, and every choice is saved under
// the key the old light/dark toggle used.

const output = fileURLToPath(new URL(`../node_modules/.cache/theme-provider-${process.pid}.mjs`, import.meta.url));
let view, window, root, container;
// The one query the page asks for; `prefer(dark)` flips it and fires its listeners.
const query = { matches: false, listeners: new Set(), addEventListener(_, fn) { this.listeners.add(fn); }, removeEventListener(_, fn) { this.listeners.delete(fn); } };
const prefer = (dark) => view.act(async () => { query.matches = dark; query.listeners.forEach((fn) => fn({ matches: dark })); });

before(async () => {
  ({ window } = new JSDOM('<!doctype html><body><div id="root"></div></body>', { url: 'http://localhost/dashboard' }));
  for (const key of ['window', 'document', 'navigator', 'localStorage']) Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true });
  window.matchMedia = (q) => (q === '(prefers-color-scheme: dark)' ? query : { matches: false, addEventListener() {}, removeEventListener() {} });
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const result = await build({ stdin: { contents: `
    import React, { act } from 'react';
    import { createRoot } from 'react-dom/client';
    import { ThemeProvider, useTheme } from './contexts/ThemeContext.jsx';
    export { act };
    function Probe() {
      const { darkMode, theme, systemDark, setTheme, toggleDarkMode } = useTheme();
      return <div data-testid="probe" data-dark={String(darkMode)} data-theme={theme} data-system-dark={String(systemDark)}>
        <button data-testid="toggle" onClick={toggleDarkMode} />
        {['system', 'light', 'dark'].map((c) => <button key={c} data-testid={'pick-' + c} onClick={() => setTheme(c)} />)}
      </div>;
    }
    export function mount(node) { const root = createRoot(node); root.render(<ThemeProvider><Probe /></ThemeProvider>); return root; }
  `, resolveDir: fileURLToPath(new URL('..', import.meta.url)), loader: 'jsx' }, bundle: true, write: false, platform: 'node', format: 'esm', external: ['react', 'react-dom/client'], logLevel: 'error' });
  mkdirSync(dirname(output), { recursive: true }); writeFileSync(output, result.outputFiles[0].text);
  view = await import(pathToFileURL(output).href);
  container = window.document.getElementById('root');
});
after(async () => { if (root) await view.act(async () => root.unmount()); rmSync(output, { force: true }); window.close(); });

const probe = () => container.querySelector('[data-testid="probe"]').dataset;
const click = (id) => view.act(async () => container.querySelector(`[data-testid="${id}"]`).click());
async function mountWith(saved, dark) {
  if (root) await view.act(async () => root.unmount());
  localStorage.clear();
  if (saved !== undefined) localStorage.setItem('dashboard-theme', saved);
  query.matches = dark;
  await view.act(async () => { root = view.mount(container); });
}

test('with nothing saved the dashboard follows the system and changes with it', async () => {
  await mountWith(undefined, true);
  assert.deepEqual([probe().theme, probe().dark], ['system', 'true']);
  await prefer(false);
  assert.equal(probe().dark, 'false');
  await prefer(true);
  assert.equal(probe().dark, 'true');
  assert.equal(localStorage.getItem('dashboard-theme'), null, 'following the system saves nothing by itself');
});

test('a choice the old toggle saved still holds, and a fixed choice ignores the system', async () => {
  await mountWith('light', true);
  assert.deepEqual([probe().theme, probe().dark], ['light', 'false']);
  await prefer(false);
  await prefer(true);
  assert.equal(probe().dark, 'false');
  await click('pick-dark');
  assert.deepEqual([probe().theme, probe().dark, localStorage.getItem('dashboard-theme')], ['dark', 'true', 'dark']);
  await prefer(false);
  assert.equal(probe().dark, 'true');
});

test('picking System again shows the current appearance at once', async () => {
  await mountWith('dark', false);
  assert.equal(probe().dark, 'true');
  await click('pick-system');
  assert.deepEqual([probe().theme, probe().dark, localStorage.getItem('dashboard-theme')], ['system', 'false', 'system']);
  await prefer(true);
  assert.equal(probe().dark, 'true');
});

test('the one-click toggle flips what shows and saves it as a fixed choice', async () => {
  await mountWith(undefined, true);
  await click('toggle');
  assert.deepEqual([probe().theme, probe().dark, localStorage.getItem('dashboard-theme')], ['light', 'false', 'light']);
  await prefer(false);
  await prefer(true);
  assert.equal(probe().dark, 'false', 'a fixed choice no longer follows the system');
  await click('toggle');
  assert.deepEqual([probe().theme, probe().dark], ['dark', 'true']);
});

test('the listener comes off with the provider', async () => {
  await mountWith(undefined, false);
  assert.equal(query.listeners.size, 1);
  await view.act(async () => root.unmount());
  root = null;
  assert.equal(query.listeners.size, 0);
});
