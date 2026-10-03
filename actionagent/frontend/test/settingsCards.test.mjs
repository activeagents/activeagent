import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// RepoPicker, ProviderKeysCard, the GitHub App section and the Settings API
// Keys tab, bundled with esbuild and rendered to static markup. Effects do
// not run in a server render, so each renders from its props alone and
// fetches nothing.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/settings-cards-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  // ThemeProvider reads the saved theme while it renders, and Settings reads
  // its first tab from the query string.
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: { location: { search: '?tab=api-keys' } }, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import RepoPicker from './components/dashboard/RepoPicker.jsx';
        import ProviderKeysCard, { useProviderKeyEditor } from './components/dashboard/ProviderKeysCard.jsx';
        import SettingsView from './components/dashboard/SettingsView.jsx';
        import GithubAppSection from './components/dashboard/GithubAppSection.jsx';

        function ProviderKeys({ providerKeys }) {
          const editor = useProviderKeyEditor({ onKeysChanged: async () => {}, onError: () => {} });
          return React.createElement(ProviderKeysCard, { providerKeys, editor });
        }

        const views = { RepoPicker, ProviderKeys, SettingsView, GithubAppSection };
        export const render = (name, props) =>
          renderToStaticMarkup(React.createElement(ThemeProvider, null, React.createElement(views[name], props)));
      `,
      resolveDir: root,
      loader: 'jsx',
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'node',
    external: ['react', 'react-dom', 'react-dom/server'],
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  ({ render } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

const repositories = [
  { id: 1, full_name: 'acme/web', private: true },
  { id: 2, full_name: 'acme/api', private: false },
  { id: 3, full_name: 'other/tool', private: false },
];

const pickerProps = (overrides = {}) => ({
  repositories, selection: new Set(), onToggle() {}, filter: '', onFilterChange() {}, ...overrides,
});

// The full names the picker lists, each with whether its box is checked.
function listedRepositories(html) {
  return [...html.matchAll(/<input type="checkbox"( checked="")?\/><span[^>]*>([^<]+)<\/span>/g)]
    .map(([, checked, name]) => [name, Boolean(checked)]);
}

test('the repo picker lists every repository with a filter field', () => {
  const html = render('RepoPicker', pickerProps());
  assert.match(html, /placeholder="Filter repositories"/);
  assert.deepEqual(listedRepositories(html), [['acme/web', false], ['acme/api', false], ['other/tool', false]]);
});

test('the repo picker lists only the repositories the filter matches', () => {
  const html = render('RepoPicker', pickerProps({ filter: 'ACME' }));
  assert.match(html, /value="ACME"/);
  assert.deepEqual(listedRepositories(html).map(([name]) => name), ['acme/web', 'acme/api']);
});

test('the repo picker checks the selected repositories and marks private ones', () => {
  const html = render('RepoPicker', pickerProps({ selection: new Set(['acme/api']) }));
  assert.deepEqual(listedRepositories(html), [['acme/web', false], ['acme/api', true], ['other/tool', false]]);
  assert.equal(html.match(/>private</g).length, 1);
});

test('the repo picker says so when no repository matches', () => {
  const html = render('RepoPicker', pickerProps({ filter: 'zzz' }));
  assert.deepEqual(listedRepositories(html), []);
  assert.match(html, /No repositories match\./);
});

const providerKeys = [
  { provider: 'openai', kind: 'key', configured: true, hint: 'sk-…abcd', host_based: false },
  { provider: 'anthropic', kind: 'key', configured: false, hint: null, host_based: false },
  {
    provider: 'ollama', kind: 'host', configured: true, hint: 'http://gpu:11434/v1', host_based: true,
    api_key_configured: true, api_key_hint: '…zz', platform_default: 'http://localhost:11434/v1',
  },
  { provider: 'claude_code', kind: 'connection', configured: true, hint: 'sk-ant-…ffff' },
  { provider: 'custom_llm', kind: 'key', configured: false },
];

// Each provider row: its label, its status line and its buttons.
function providerRows(html) {
  return [...html.matchAll(/<p class="font-medium[^"]*">([^<]+)<\/p><p class="text-sm[^"]*">([^<]*)<\/p><\/div><\/div><div class="flex items-center space-x-2">(.*?)<\/div><\/div>/g)]
    .map(([, label, status, buttons]) => [label, status, [...buttons.matchAll(/<button[^>]*>([^<]+)<\/button>/g)].map(([, text]) => text)]);
}

test('the provider keys card lists one row per credential provider', () => {
  const html = render('ProviderKeys', { providerKeys });
  assert.match(html, /<h3[^>]*>\s*Provider API Keys\s*<\/h3>/);
  assert.deepEqual(providerRows(html), [
    ['OpenAI', 'Configured (sk-…abcd)', ['Remove', 'Update']],
    ['Anthropic', 'Not configured', ['Configure']],
    ['Ollama', 'http://gpu:11434/v1 · key …zz', ['Test connection', 'Remove', 'Update']],
    ['custom_llm', 'Not configured', ['Configure']],
  ]);
});

test('a host-based provider without a host offers the platform default', () => {
  const ollama = { ...providerKeys[2], configured: false, hint: null, api_key_configured: false };
  assert.deepEqual(providerRows(render('ProviderKeys', { providerKeys: [ollama] })), [
    ['Ollama', 'Platform default: http://localhost:11434/v1', ['Test connection', 'Configure']],
  ]);
});

// The hosted application's browser tests open this tab by the 'API Keys'
// button and create a key through the 'Key name' field.
test('the API Keys tab keeps its tab button, key name field and provider keys card', () => {
  const html = render('SettingsView', { user: { name: 'Ada Lovelace', email: 'ada@example.com' } });
  assert.match(html, /<button[^>]*>API Keys<\/button>/);
  assert.match(html, /placeholder="Key name \(e\.g\. production\)"/);
  assert.match(html, /\+ Create New Key/);
  assert.match(html, /Provider API Keys/);
});

const appSection = (app) => render('GithubAppSection', { app, onChanged() {}, onError() {}, onNotice() {} });
const buttons = (html) => [...html.matchAll(/<(?:button|a)[^>]*>([^<]+)<\/(?:button|a)>/g)].map(([, text]) => text);

test('with no App configured and no manifest flow, the GitHub App section renders nothing', () => {
  assert.equal(appSection({ configured: false, manifest_available: false, installations: [] }), '');
  assert.equal(appSection(undefined), '');
});

test('a self-hosted dashboard with no App is offered the manifest flow', () => {
  const html = appSection({ configured: false, manifest_available: true, installations: [] });
  assert.match(html, /Use a GitHub App/);
  assert.match(html, /placeholder="Organization \(optional\)"/);
  assert.deepEqual(buttons(html), ['Create GitHub App']);
});

test('a configured App offers the install and lists each installation with its actions', () => {
  const html = appSection({
    configured: true,
    manifest_available: true,
    installations: [
      { id: 1, account_login: 'acme', account_type: 'Organization', status: 'active', settings_url: 'https://github.com/organizations/acme/settings/installations/7', repositories: [{ full_name: 'acme/shop' }] },
      { id: 2, account_login: 'octocat', account_type: 'User', status: 'removed', settings_url: 'https://github.com/settings/installations/8', repositories: [] },
    ],
  });

  assert.match(html, /href="\/api\/github_installations\/install"/);
  assert.doesNotMatch(html, /Create GitHub App/, 'no manifest offer once an App is configured');
  assert.match(html, /@acme · organization/);
  assert.match(html, /1 selected for sandboxes/);
  assert.match(html, /@octocat · user/);
  assert.match(html, /Removed from GitHub: reinstall or unlink/);
  assert.deepEqual(buttons(html), [
    'Install the GitHub App',
    'Choose repositories', 'Access on GitHub', 'Unlink',
    'Access on GitHub', 'Unlink',
  ]);
});

test('a configured App with nothing linked says so', () => {
  const html = appSection({ configured: true, manifest_available: false, installations: [] });
  assert.match(html, /No installation is linked yet/);
});
