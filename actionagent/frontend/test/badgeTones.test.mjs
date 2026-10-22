import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The one badge every status and message role renders through: the shared
// status and role tone maps, the stream's roleBubble over them, and the
// Badge itself, bundled with esbuild and rendered to static markup.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/badge-tones-${process.pid}.mjs`, import.meta.url));

let api;

before(async () => {
  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { Badge, ROLE_BADGES, roleBadge, statusTone, TONE } from './components/dashboard/primitives.jsx';
        import { roleBubble } from './components/dashboard/InteractionStream.jsx';
        export { ROLE_BADGES, roleBadge, statusTone, TONE, roleBubble };
        export const renderBadge = (props, label) => renderToStaticMarkup(React.createElement(Badge, props, label));
      `,
      resolveDir: root,
      loader: 'jsx',
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'node',
    external: ['react', 'react-dom', 'react-dom/server'],
    banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" },
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  api = await import(pathToFileURL(bundlePath).href);
});

after(() => {
  rmSync(bundlePath, { force: true });
});

// One status map for every record's badge: an agent card, a run, a sandbox
// session and a result read the same tone for the same word.
test('statusTone maps the statuses every surface shows', () => {
  const { statusTone } = api;
  assert.equal(statusTone('active'), 'success');
  assert.equal(statusTone('complete'), 'success');
  assert.equal(statusTone('completed'), 'success');
  assert.equal(statusTone('ready'), 'success');
  assert.equal(statusTone('draft'), 'warning');
  assert.equal(statusTone('pending'), 'warning');
  assert.equal(statusTone('running'), 'info');
  assert.equal(statusTone('failed'), 'error');
  assert.equal(statusTone('expired'), 'error');
  assert.equal(statusTone('archived'), 'muted');
  assert.equal(statusTone('cancelled'), 'muted');
});

test('statusTone is muted for an unknown or missing status, and ignores case', () => {
  const { statusTone } = api;
  assert.equal(statusTone('whatever'), 'muted');
  assert.equal(statusTone(undefined), 'muted');
  assert.equal(statusTone(null), 'muted');
  assert.equal(statusTone('Running'), 'info');
});

test('every status tone and role tone is one the Badge can render', () => {
  const { ROLE_BADGES, statusTone, TONE } = api;
  const tones = new Set(Object.keys(TONE));
  for (const status of ['active', 'draft', 'archived', 'running', 'failed', 'pending', 'complete']) {
    assert.ok(tones.has(statusTone(status)), `${status} -> ${statusTone(status)}`);
  }
  for (const [role, badge] of Object.entries(ROLE_BADGES)) {
    assert.ok(tones.has(badge.tone), `${role} -> ${badge.tone}`);
  }
});

test('roleBadge names the five roles and falls back to the role itself', () => {
  const { roleBadge } = api;
  assert.deepEqual(roleBadge('user'), { tone: 'info', label: 'User' });
  assert.deepEqual(roleBadge('assistant'), { tone: 'accent', label: 'Assistant' });
  assert.deepEqual(roleBadge('tool'), { tone: 'warning', label: 'Tool' });
  assert.deepEqual(roleBadge('system'), { tone: 'system', label: 'System' });
  assert.deepEqual(roleBadge('developer'), { tone: 'dev', label: 'Dev' });
  assert.deepEqual(roleBadge('function'), { tone: 'muted', label: 'function' });
});

// The stream's roleBubble keeps its shape for the callers that read
// `.color` and `.label`, but its colors are the shared tones now, so a role
// looks the same in the stream, a session preview and a Badge.
test('roleBubble resolves to the shared tones in both themes', () => {
  const { roleBubble, TONE } = api;
  for (const darkMode of [false, true]) {
    const bubble = roleBubble('assistant', darkMode);
    assert.equal(bubble.label, 'Assistant');
    assert.equal(bubble.tone, 'accent');
    assert.equal(bubble.background, TONE.accent.soft);
    assert.equal(bubble.color, TONE.accent.text);
  }
  assert.equal(roleBubble('nonsense', false).label, 'nonsense');
  assert.equal(roleBubble('nonsense', false).color, TONE.muted.text);
});

test('a status Badge renders its tone colors in mono at radius 4', () => {
  const { renderBadge, statusTone } = api;
  const html = renderBadge({ tone: statusTone('active') }, 'active');
  assert.match(html, /background:var\(--color-success-soft\)/);
  assert.match(html, /color:var\(--color-success-text\)/);
  assert.match(html, /border-radius:4px/);
  assert.match(html, /font-family:var\(--font-mono\)/);
  assert.match(html, />active</);
});
