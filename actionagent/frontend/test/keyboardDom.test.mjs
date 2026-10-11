import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before, beforeEach } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';

// Keyboard behaviour that a static render cannot show, mounted in jsdom:
// the arrow keys walk the Tabs primitive, Escape and an item choice close
// a Menu and hand focus back to its trigger, and the sidebar's workspace
// menu does the same.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/keyboard-dom-${process.pid}.mjs`, import.meta.url));

let window;
let dashboard;

before(async () => {
  ({ window } = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/' }));
  for (const key of ['window', 'document', 'navigator', 'localStorage', 'KeyboardEvent', 'MouseEvent']) {
    Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true, writable: true });
  }
  window.localStorage.setItem('dashboard-theme', 'light');
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React, { act, useState } from 'react';
        import { createRoot } from 'react-dom/client';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import { Tabs, Menu } from './components/dashboard/primitives.jsx';
        import Sidebar from './components/dashboard/Sidebar.jsx';

        // Tabs with their own state, so a change re-renders the selection.
        function StatefulTabs({ initial, tabs, log }) {
          const [active, setActive] = useState(initial);
          return React.createElement(Tabs, { ariaLabel: 'Sections', tabs, active, onChange: (id) => { log.push(id); setActive(id); } });
        }
        const views = { Tabs: StatefulTabs, Menu, Sidebar };
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
  document.body.innerHTML = '';
  window.ACTIVE_AGENT_DASHBOARD = { meta: { signOutPath: '/sign_out' } };
});

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

// A click lands focus first, as a pointer click does in a browser.
const click = (element) => dashboard.act(async () => { element.focus(); element.click(); });
// Never hand a jsdom node to assert's message formatter: it does not return.
const focused = (element) => document.activeElement === element;
const press = (element, key) => dashboard.act(async () => {
  element.dispatchEvent(new window.KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }));
});
const tabs = (container) => [...container.querySelectorAll('[role="tab"]')];
const selected = (container) => tabs(container).find((tab) => tab.getAttribute('aria-selected') === 'true');

// --- Tabs -------------------------------------------------------------------

const THREE = [
  { id: 'activity', label: 'Activity' },
  { id: 'quality', label: 'Quality' },
  { id: 'config', label: 'Config', disabled: true },
  { id: 'history', label: 'History' },
];

test('the arrow keys move the selection and the focus along the enabled tabs, wrapping at the ends', async () => {
  const log = [];
  await mounted('Tabs', { initial: 'activity', tabs: THREE, log }, async (container) => {
    const tabIds = () => tabs(container).map((tab) => [tab.dataset.tabId, tab.tabIndex]);
    assert.deepEqual(tabIds(), [['activity', 0], ['quality', -1], ['config', -1], ['history', -1]], 'only the active tab is in the tab order');

    await press(selected(container), 'ArrowRight');
    assert.equal(selected(container).dataset.tabId, 'quality');
    assert.equal(document.activeElement?.dataset?.tabId, 'quality', 'focus follows the selection');

    await press(selected(container), 'ArrowRight');
    assert.equal(selected(container).dataset.tabId, 'history', 'the disabled tab is skipped');

    await press(selected(container), 'ArrowRight');
    assert.equal(selected(container).dataset.tabId, 'activity', 'wraps to the first');

    await press(selected(container), 'ArrowLeft');
    assert.equal(selected(container).dataset.tabId, 'history', 'wraps back to the last enabled');

    await press(selected(container), 'Home');
    assert.equal(selected(container).dataset.tabId, 'activity');
    await press(selected(container), 'End');
    assert.equal(selected(container).dataset.tabId, 'history');

    assert.deepEqual(log, ['quality', 'history', 'activity', 'history', 'activity', 'history']);
    assert.deepEqual(tabIds().filter(([, index]) => index === 0).map(([id]) => id), ['history'], 'the tab order follows the selection');
  });
});

test('a key the tabs do not handle, or one that lands on the active tab, changes nothing', async () => {
  const log = [];
  await mounted('Tabs', { initial: 'activity', tabs: THREE, log }, async (container) => {
    await press(selected(container), 'ArrowDown');
    await press(selected(container), 'Home');
    assert.equal(selected(container).dataset.tabId, 'activity');
    assert.deepEqual(log, []);
  });
});

// --- Menu -------------------------------------------------------------------

const menuProps = (log) => ({
  label: 'More',
  testId: 'more',
  items: [
    { label: 'Export', onClick: () => log.push('export'), testId: 'export' },
    { label: 'Delete', onClick: () => log.push('delete'), tone: 'danger', testId: 'delete' },
  ],
});

test('Escape closes an open menu and returns focus to its trigger', async () => {
  const log = [];
  await mounted('Menu', menuProps(log), async (container) => {
    const trigger = container.querySelector('[data-testid="more"]');
    assert.equal(container.querySelector('[role="menu"]'), null, 'closed to begin with');

    await click(trigger);
    assert.ok(container.querySelector('[role="menu"]'), 'the click opens it');
    assert.equal(trigger.getAttribute('aria-expanded'), 'true');

    await press(document.body, 'Escape');
    assert.equal(container.querySelector('[role="menu"]'), null, 'Escape closes it');
    assert.equal(trigger.getAttribute('aria-expanded'), 'false');
    assert.equal(focused(trigger), true, 'focus is back on the trigger');
    assert.deepEqual(log, []);
  });
});

test('choosing an item runs it, closes the menu and returns focus to the trigger', async () => {
  const log = [];
  await mounted('Menu', menuProps(log), async (container) => {
    const trigger = container.querySelector('[data-testid="more"]');
    await click(trigger);
    await click(container.querySelector('[data-testid="delete"]'));
    assert.deepEqual(log, ['delete']);
    assert.equal(container.querySelector('[role="menu"]'), null);
    assert.equal(focused(trigger), true, 'focus is back on the trigger');
  });
});

// --- Sidebar workspace menu -------------------------------------------------

const sidebarProps = () => ({
  currentView: 'list',
  onNavigate() {},
  features: {},
  account: { name: 'Example Workspace' },
  user: { name: 'Ada', email: 'ada@example.com' },
  gemVersion: '1.2.3',
});

test('the workspace menu opens as a menu of items and Escape closes it back onto its button', async () => {
  await mounted('Sidebar', sidebarProps(), async (container) => {
    const trigger = container.querySelector('button[aria-label="Workspace menu"]');
    assert.ok(trigger, 'the workspace button');
    assert.equal(container.querySelector('[role="menu"]'), null);

    await click(trigger);
    const menu = container.querySelector('[role="menu"]');
    assert.ok(menu, 'open');
    assert.equal(trigger.getAttribute('aria-expanded'), 'true');
    const items = [...menu.querySelectorAll('[role="menuitem"], [role="menuitemcheckbox"]')].map((item) => item.textContent.replace(/^\[.\]/, ''));
    assert.deepEqual(items, ['Dark mode', 'Organization', 'Settings', 'Documentation', 'GitHub', 'Sign out']);
    assert.ok(!menu.textContent.includes('1.2.3'), 'the version is not an item');
    assert.ok(container.textContent.includes('1.2.3'), 'but it is still shown');

    await press(document.body, 'Escape');
    assert.equal(container.querySelector('[role="menu"]'), null, 'closed');
    assert.equal(trigger.getAttribute('aria-expanded'), 'false');
    assert.equal(focused(trigger), true, 'focus is back on the workspace button');
  });
});

test('a click outside the workspace menu closes it', async () => {
  await mounted('Sidebar', sidebarProps(), async (container) => {
    const trigger = container.querySelector('button[aria-label="Workspace menu"]');
    await click(trigger);
    assert.ok(container.querySelector('[role="menu"]'));
    await dashboard.act(async () => {
      document.body.dispatchEvent(new window.MouseEvent('mousedown', { bubbles: true }));
    });
    assert.equal(container.querySelector('[role="menu"]'), null);
  });
});
