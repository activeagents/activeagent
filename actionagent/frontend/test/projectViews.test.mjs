import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The Projects views that render from their props alone, bundled with esbuild
// and rendered to static markup: the repository picker's states, the
// capabilities checklist, the secrets form, the Environment tab, boot
// progress and the preflight result.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/project-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: { location: { search: '' } }, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import RepoPicker from './components/dashboard/RepoPicker.jsx';
        import CapabilitiesChecklist from './components/dashboard/projects/CapabilitiesChecklist.jsx';
        import ProjectSecretsForm from './components/dashboard/projects/ProjectSecretsForm.jsx';
        import ProjectEnvironment from './components/dashboard/projects/ProjectEnvironment.jsx';
        import ProjectBootProgress from './components/dashboard/projects/ProjectBootProgress.jsx';
        import ProjectList from './components/dashboard/projects/ProjectList.jsx';
        import { PreflightResult } from './components/dashboard/projects/NewProject.jsx';

        const views = { RepoPicker, CapabilitiesChecklist, ProjectSecretsForm, ProjectEnvironment, ProjectBootProgress, ProjectList, PreflightResult };
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
    external: ['react', 'react-dom', 'react-dom/server', '@rails/actioncable'],
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
];

const pickerProps = (overrides = {}) => ({
  repositories, selection: new Set(), onToggle() {}, filter: '', onFilterChange() {}, ...overrides,
});

// --- RepoPicker states ------------------------------------------------------

test('the picker says GitHub is not configured', () => {
  const html = render('RepoPicker', pickerProps({ mode: 'single', state: 'not_configured', settingsHref: '/settings' }));
  assert.match(html, /data-testid="repo-picker-not_configured"/);
  assert.match(html, /GitHub is not configured on this dashboard/);
  assert.doesNotMatch(html, /type="radio"/);
});

test('the picker links to Settings to connect, and to reconnect a revoked token', () => {
  const connect = render('RepoPicker', pickerProps({ mode: 'single', state: 'not_connected', settingsHref: '/aa/settings?tab=integrations' }));
  assert.match(connect, /Connect GitHub to pick a repository/);
  assert.match(connect, /href="\/aa\/settings\?tab=integrations"[^>]*>Connect GitHub in Settings → Integrations/);

  const reconnect = render('RepoPicker', pickerProps({ mode: 'single', state: 'reconnect_required', settingsHref: '/aa/settings?tab=integrations' }));
  assert.match(reconnect, /data-testid="repo-picker-reconnect_required"/);
  assert.match(reconnect, /GitHub rejected the stored token/);
  assert.match(reconnect, />Reconnect GitHub in Settings → Integrations</);
});

test('the picker waits on an installation an owner has to approve, and can check again', () => {
  const html = render('RepoPicker', pickerProps({ mode: 'single', state: 'pending_approval', onRefresh() {} }));
  assert.match(html, /waiting for an owner of the account to approve it/);
  assert.match(html, />Check again</);
});

test('a connection reaching no repositories links to where access is granted, and takes a typed name', () => {
  const html = render('RepoPicker', pickerProps({
    mode: 'single', state: 'empty', repositories: [], missingRepositoryUrl: 'https://github.com/settings/connections/applications/client-id',
    onTypeName() {}, onRefresh() {},
  }));
  assert.match(html, /reaches no repositories yet/);
  assert.match(html, /href="https:\/\/github.com\/settings\/connections\/applications\/client-id" target="_blank"[^>]*>Repository not listed\?</);
  assert.match(html, /placeholder="Type owner\/name"/);
});

test('a single-choice picker lists radios, with the missing-repository link and the typed name under them', () => {
  const html = render('RepoPicker', pickerProps({
    mode: 'single', selected: 'acme/api', onSelect() {}, missingRepositoryUrl: 'https://github.example/settings', onTypeName() {},
    typedNameError: 'GitHub found no repository acme/gone that this connection can reach',
  }));
  const radios = [...html.matchAll(/<input type="radio" name="repository"( checked="")?\/><span[^>]*>([^<]+)<\/span>/g)]
    .map(([, checked, name]) => [name, Boolean(checked)]);
  assert.deepEqual(radios, [['acme/web', false], ['acme/api', true]]);
  assert.match(html, /Repository not listed\?/);
  assert.match(html, /GitHub found no repository acme\/gone/);
  assert.doesNotMatch(html, /type="checkbox"/);
});

test("the Settings picker's checklist is unchanged by the project states", () => {
  const html = render('RepoPicker', pickerProps({ selection: new Set(['acme/web']) }));
  assert.match(html, /<input type="checkbox" checked=""\/><span[^>]*>acme\/web<\/span>/);
  assert.doesNotMatch(html, /Repository not listed|Type owner\/name|type="radio"/);
});

// --- capabilities ---------------------------------------------------------

test('the checklist shows the line that fixes a failing item, and marks the blocking ones', () => {
  const html = render('CapabilitiesChecklist', {
    capabilities: {
      ready: false,
      items: [
        { key: 'sandbox_backend', label: 'Sandbox backend', ok: false, blocking: true, detail: 'The mock backend runs nothing',
          fix: 'config.sandbox_service = :local  # config/initializers/action_agent.rb, or a backend you registered' },
        { key: 'github', label: 'GitHub', ok: true, blocking: true, detail: 'OAuth app, callback URL https://dash.example/aa/api/github_connection/callback' },
        { key: 'browser', label: 'Browser sessions', ok: false, blocking: false, detail: 'Not available yet' },
      ],
    },
  });

  assert.match(html, /action needed/);
  assert.match(html, /data-testid="capability-fix-sandbox_backend"[^>]*>config.sandbox_service = :local/);
  assert.equal((html.match(/blocks creating a project/g) || []).length, 1);
  assert.match(html, /callback URL https:\/\/dash.example\/aa\/api\/github_connection\/callback/);
});

// --- secrets form -----------------------------------------------------------

const row = (overrides) => ({ name: 'X', required: false, sources: [], description: null, organizationKey: null, set: false,
  value: '', useOrganizationKey: false, consent: false, ...overrides });

test('the secrets form warns about a live key and a value too short to mask before it is saved', () => {
  const html = render('ProjectSecretsForm', {
    rows: [
      row({ name: 'STRIPE_SECRET_KEY', required: true, value: 'sk_live_0123456789', sources: ['.env.example:1'] }),
      row({ name: 'PIN', value: '1234' }),
      row({ name: 'RAILS_MASTER_KEY', value: 'abcdef0123456789' }),
    ],
    onChange() {},
    repository: 'acme/shop',
  });

  assert.match(html, /data-testid="secret-warning-live_credential"/);
  assert.match(html, /data-testid="secret-warning-short_value"/);
  assert.match(html, /data-testid="secret-warning-rails_master_key"/);
  assert.match(html, /\.env\.example:1/);
  assert.equal((html.match(/type="password"/g) || []).length, 3);
  const outsidePasswordFields = html.replace(/<input type="password"[^>]*>/g, '');
  assert.doesNotMatch(outsidePasswordFields, /sk_live_0123456789/, 'a value is only ever in its password field');
});

test("a provider key can use the organization's key, which asks for consent and takes no value", () => {
  const offered = render('ProjectSecretsForm', { rows: [row({ name: 'OPENAI_API_KEY', organizationKey: 'openai' })], onChange() {} });
  assert.match(offered, /Use the organization&#x27;s openai key/);
  assert.doesNotMatch(offered, /data-testid="secret-consent-OPENAI_API_KEY"/);

  const chosen = render('ProjectSecretsForm', {
    rows: [row({ name: 'OPENAI_API_KEY', organizationKey: 'openai', useOrganizationKey: true })], onChange() {}, repository: 'acme/shop',
  });
  assert.match(chosen, /data-testid="secret-consent-OPENAI_API_KEY"/);
  assert.match(chosen, /acme\/shop&#x27;s code can read the organization&#x27;s openai key/);
  assert.doesNotMatch(chosen, /type="password"/);
});

test('a refused name in the form says why instead of taking a value', () => {
  const html = render('ProjectSecretsForm', { rows: [row({ name: 'RUBYOPT' })], onChange() {} });
  assert.match(html, /RUBYOPT is set by the sandbox or changes how code is loaded/);
  assert.doesNotMatch(html, /type="password"/);
});

// --- Environment tab ----------------------------------------------------------

test('the Environment tab lists names, sources and setters, never values', () => {
  const html = render('ProjectEnvironment', {
    secrets: [
      { name: 'OPENAI_API_KEY', source: 'organization_key', provider: 'openai', set_by: { id: 1, name: 'Avery' }, updated_at: '2026-10-01T10:00:00Z' },
      { name: 'STRIPE_SECRET_KEY', source: 'entered', provider: null, set_by: null, updated_at: '2026-10-02T10:00:00Z' },
    ],
    onReplace: async () => {},
    onDelete: async () => {},
  });

  assert.match(html, /data-testid="environment-OPENAI_API_KEY"/);
  assert.match(html, /organization&#x27;s openai key/);
  assert.match(html, /set by Avery/);
  assert.match(html, /data-testid="environment-STRIPE_SECRET_KEY"/);
  assert.equal((html.match(/>Replace</g) || []).length, 1, "an organization key is replaced in Settings, not here");
  assert.equal((html.match(/>Delete</g) || []).length, 2);
  assert.match(html, /2 secrets/);
});

test("the Environment tab shows the API's refusal", () => {
  const html = render('ProjectEnvironment', {
    secrets: [], onReplace: async () => {}, onDelete: async () => {}, error: 'You do not have permission to do this',
  });
  assert.match(html, /You do not have permission to do this/);
  assert.match(html, /sets no environment variables/);
});

// --- boot progress ----------------------------------------------------------

test('boot progress lists each step with its status and elapsed time, then the log tail', () => {
  const html = render('ProjectBootProgress', {
    sandboxState: 'failed',
    boot: {
      steps: [
        { name: 'checkout', status: 'succeeded', duration_ms: 1200 },
        { name: 'bundle_install', status: 'succeeded', duration_ms: 185000 },
        { name: 'javascript_build', status: 'skipped', duration_ms: 3, detail: 'the app defines no javascript:build task' },
        { name: 'db_prepare', status: 'failed', duration_ms: 3400, detail: '`bin/rails db:prepare` exited with 1' },
        { name: 'start', status: 'pending', duration_ms: null },
      ],
    },
    logTail: { step: 'db_prepare', text: 'connecting with [REDACTED]\nPG::ConnectionBad\n', truncated: true },
    error: 'Sandbox boot failed: db_prepare',
  });

  const steps = [...html.matchAll(/data-testid="boot-step-([a-z_]+)"/g)].map((match) => match[1]);
  assert.deepEqual(steps, ['checkout', 'bundle_install', 'javascript_build', 'db_prepare', 'start']);
  assert.match(html, />1.2s</);
  assert.match(html, />3m 05s</);
  assert.match(html, /Bundle <span[^>]*>bundle_install/);
  assert.match(html, /Database <span[^>]*>db_prepare/);
  assert.match(html, /last lines of db_prepare.log/);
  assert.match(html, /data-testid="boot-log-tail"[^>]*>connecting with \[REDACTED\]/);
  assert.match(html, /data-testid="boot-error"/);
});

test('boot progress says when there is nothing to show yet', () => {
  assert.match(render('ProjectBootProgress', { boot: null, sandboxState: 'booting' }), /Waiting for the sandbox to report its steps/);
  assert.match(render('ProjectBootProgress', { boot: null, sandboxState: 'none' }), /No boot to show yet/);
});

// --- preflight and list -----------------------------------------------------

test('the preflight result names the support level, the versions and the warnings', () => {
  const html = render('PreflightResult', {
    repository: 'acme/shop',
    preflight: {
      status: 'bootstrap', summary: 'Supported: installs the engine in the sandbox', reasons: [], ruby: '3.3.6', ruby_source: 'Gemfile.lock',
      railties: '8.0.1', actionagent: null, ref: 'main', warnings: ['The app uses Redis (for Sidekiq), which a sandbox does not run: features that need it may fail.'],
    },
  });

  assert.match(html, /Supported: installs the engine in the sandbox/);
  assert.match(html, /Ruby 3.3.6 \(Gemfile.lock\) · railties 8.0.1/);
  assert.match(html, /engine not bundled/);
  assert.match(html, /Redis \(for Sidekiq\)/);
});

test('the projects list shows each project with its sandbox state and agent', () => {
  const html = render('ProjectList', {
    projects: [{ id: 3, name: 'Shop', repository: 'acme/shop', sandbox_state: 'ready', target_agent: { kind: 'app_assistant' } }],
    onOpen() {}, onNew() {},
  });
  assert.match(html, /data-testid="project-3"/);
  assert.match(html, /sandbox ready/);
  assert.match(html, /App assistant/);
  assert.match(render('ProjectList', { projects: [], onOpen() {}, onNew() {} }), /No projects yet/);
});
