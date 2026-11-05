import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The agent list with no agents, bundled with esbuild and rendered to static
// markup: the three ways an agent arrives, telemetry first.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/agents-empty-state-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import AgentsEmptyState from './components/dashboard/AgentsEmptyState.jsx';
        export const render = (props) => renderToStaticMarkup(React.createElement(AgentsEmptyState, props));
      `,
      resolveDir: root,
      loader: 'jsx',
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'node',
    loader: { '.jsx': 'jsx' },
    external: ['react', 'react-dom', 'react-dom/server'],
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  ({ render } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

const props = (overrides = {}) => ({
  endpoint: 'https://activeagents.ai/v1/traces',
  multiTenant: true,
  isLoading: false,
  onRefresh() {},
  onBrowseTemplates() {},
  onNew() {},
  ...overrides,
});

const order = (html, ids) => ids.map((id) => html.indexOf(`data-testid="${id}"`));

test('offers telemetry, then a repository, then building one, in that order', () => {
  const html = render(props());
  const positions = order(html, ['empty-connect-telemetry', 'empty-link-repository', 'empty-build-agent']);
  assert.ok(positions.every((position) => position >= 0), 'all three ways are shown');
  assert.deepEqual([...positions].sort((a, b) => a - b), positions);
  assert.match(html, /data-testid="empty-new-project"/);
  assert.match(html, /data-testid="empty-browse-templates"/);
  assert.match(html, /data-testid="empty-create-agent"/);
});

test('shows the config block for this dashboard, with the key left in the environment', () => {
  const html = render(props());
  assert.match(html, /endpoint: https:\/\/activeagents\.ai\/v1\/traces/);
  assert.match(html, /ENV\[&quot;ACTIVEAGENTS_API_KEY&quot;\]/);
});

test('a multi-tenant workspace points at its telemetry key', () => {
  const html = render(props());
  assert.match(html, /data-testid="empty-telemetry-key"/);
  assert.match(html, /telemetry key, on the\s+Organization page/);
});

test('a self-hosted dashboard names the ingest key instead', () => {
  const html = render(props({ multiTenant: false, endpoint: 'http://localhost:3000/activeagents/api/traces' }));
  assert.doesNotMatch(html, /data-testid="empty-telemetry-key"/);
  assert.match(html, /ingest_api_key/);
  assert.match(html, /endpoint: http:\/\/localhost:3000\/activeagents\/api\/traces/);
});

test('the check button says so while the list reloads', () => {
  const html = render(props({ isLoading: true }));
  assert.match(html, /data-testid="empty-check-again"[^>]*disabled=""[^>]*>Checking…</);
});
