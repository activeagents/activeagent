import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The input request card, the Needs input lane, the sidebar badge and the
// runner's activity feed, bundled with esbuild and rendered to static markup. Effects do not run in a server
// render, so each renders from its props alone and fetches nothing.

const root = fileURLToPath(new URL('..', import.meta.url));
// Under node_modules, so the bundle's react imports resolve to the dashboard's own install.
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/input-request-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  // ThemeProvider reads the saved theme while it renders, and dashboardPath
  // reads the engine's mount path off window.
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: {}, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import InputRequestCard from './components/dashboard/InputRequestCard.jsx';
        import { NeedsInputList } from './components/dashboard/NeedsInputLane.jsx';
        import Sidebar from './components/dashboard/Sidebar.jsx';
        import GenerativeUI from './components/dashboard/GenerativeUI.jsx';
        import { ActivityFeed } from './components/dashboard/AgentRunner.jsx';
        import { paletteFor } from './utils/dashboardTheme.js';

        function RunnerFeed({ run }) {
          return React.createElement(ActivityFeed, { run, darkMode: false, colors: paletteFor(false), expanded: {}, onToggle() {} });
        }

        const views = { InputRequestCard, NeedsInputList, Sidebar, GenerativeUI, RunnerFeed };
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
    // GenerativeUI pulls in recharts, which is CommonJS and requires react
    // at runtime; an ES module has no require of its own.
    banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" },
    logLevel: 'error',
  });
  mkdirSync(dirname(bundlePath), { recursive: true });
  writeFileSync(bundlePath, outputFiles[0].text);
  ({ render } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

const request = (overrides = {}) => ({
  id: 7,
  kind: 'text',
  status: 'pending',
  prompt: 'Which account should I refund?',
  options: null,
  tool_name: 'ask_user',
  arguments: null,
  agent: { id: 5, name: 'SupportBot', slug: 'support-bot' },
  run_id: 42,
  actor: { type: 'User', id: 3, name: 'Dana' },
  created_at: new Date(Date.now() - 120000).toISOString(),
  expires_at: new Date(Date.now() + 23.5 * 3600000).toISOString(),
  ...overrides,
});

const card = (overrides = {}, props = {}) => render('InputRequestCard', { request: request(overrides), ...props });

const count = (html, needle) => html.split(needle).length - 1;

test('a card says who is asking: the agent, its run, the actor, the tool, and when it expires', () => {
  const html = card();

  assert.match(html, /SupportBot is asking/);
  assert.match(html, /href="\/agents\/5\/run\?run=42"/);
  assert.match(html, /data-testid="input-request-run-link">run #42/);
  assert.match(html, /data-testid="input-request-actor">for Dana/);
  assert.match(html, /data-testid="input-request-tool">via ask_user/);
  assert.match(html, /expires in 23h/);
  assert.match(html, /asked 2m ago/);
  assert.match(html, /Which account should I refund\?/);
});

test('a card shown beside its run does not link the run', () => {
  assert.doesNotMatch(card({}, { showRunLink: false }), /input-request-run-link/);
});

test('a text request is answered in a required Generative UI form field, or declined', () => {
  const html = card();

  assert.match(html, /data-block-type="form"/);
  assert.match(html, /<textarea[^>]*name="answer"[^>]*required=""/);
  assert.match(html, /data-testid="input-request-decline"/);
  assert.doesNotMatch(html, /type="password"/);
});

test('a choice request offers its options as Generative UI choice buttons', () => {
  const html = card({ kind: 'choice', options: [{ label: 'Full refund', value: 'full' }, 'Store credit'] });

  assert.match(html, /data-block-type="choices"/);
  assert.equal(count(html, 'data-testid="genui-choice"'), 2);
  assert.match(html, />Full refund</);
  assert.match(html, />Store credit</);
});

test('a confirm request shows the tool call it would allow, with Approve and Decline', () => {
  const html = card({ kind: 'confirm', tool_name: 'refund_invoice', prompt: 'Allow refund_invoice to run?', arguments: { invoice: 'INV-1' } });

  assert.match(html, /data-testid="input-request-approve"/);
  assert.equal(count(html, 'data-testid="input-request-decline"'), 1);
  assert.match(html, /via refund_invoice/);
  assert.match(html, /&quot;invoice&quot;: &quot;INV-1&quot;/);
  assert.doesNotMatch(html, /data-block-type/);
});

test('a secret request is a masked field marked for masking, with nothing in it', () => {
  const html = card({ kind: 'secret', tool_name: 'request_secret', prompt: 'Paste the staging API key' });
  const input = html.match(/<input[^>]*data-testid="input-request-secret"[^>]*>/)?.[0];

  assert.ok(input, 'the secret field is rendered');
  assert.match(input, /type="password"/);
  assert.match(input, /autoComplete="off"/i);
  assert.match(input, /data-aa-secret=""/);
  assert.match(input, /value=""/);
  assert.doesNotMatch(html, /data-block-type/);
});

test('a settled card replaces its control with what became of the request', () => {
  const declined = card({ kind: 'confirm' }, { initialOutcome: { state: 'declined' } });
  assert.match(declined, /data-state="declined"/);
  assert.match(declined, /Declined: the tool does not run/);
  assert.doesNotMatch(declined, /input-request-approve/);

  const expired = card({}, { initialOutcome: { state: 'closed', status: 'expired', message: 'Expired before it was answered' } });
  assert.match(expired, /Expired before it was answered/);
  assert.doesNotMatch(expired, /data-block-type/);

  const answeredElsewhere = card({}, { initialOutcome: { state: 'closed', status: 'answered', message: 'Already answered' } });
  assert.match(answeredElsewhere, /Already answered/);
});

test('a refused answer keeps the control and shows why', () => {
  const html = card({ kind: 'choice', options: ['a'] }, { initialOutcome: { state: 'invalid', message: '"b" is not one of the options' } });

  assert.match(html, /data-testid="input-request-error"/);
  assert.match(html, /&quot;b&quot; is not one of the options/);
  assert.match(html, /data-testid="genui-choice"/);
});

test('the Needs input lane lists each pending request, then the ones answered here', () => {
  assert.equal(render('NeedsInputList', { pending: [] }), '');

  const html = render('NeedsInputList', {
    pending: [request(), request({ id: 8, kind: 'confirm', prompt: 'Allow fetch_url to run?' })],
    settled: [{ request: request({ id: 9, prompt: 'Earlier question' }), outcome: { state: 'answered' } }],
  });

  assert.match(html, /data-testid="needs-input-lane"/);
  assert.match(html, /data-testid="needs-input-count"[^>]*>2 waiting</);
  assert.equal(count(html, 'data-testid="input-request-card"'), 3);
  assert.ok(html.indexOf('Allow fetch_url to run?') < html.indexOf('Earlier question'), 'pending requests come first');
  assert.match(html, /Answered: the run continues/);
});

test('the Interactions nav item carries the pending count, and none when nothing waits', () => {
  const props = { currentView: 'list', onNavigate() {}, agentCount: 4, features: {} };

  const waiting = render('Sidebar', { ...props, pendingInputCount: 3 });
  assert.match(waiting, /data-testid="nav-badge-interactions"[^>]*aria-label="3 requests waiting for an answer"[^>]*>3</);

  assert.doesNotMatch(render('Sidebar', { ...props, pendingInputCount: undefined }), /nav-badge-interactions/);
  assert.doesNotMatch(render('Sidebar', { ...props, pendingInputCount: 0 }), /nav-badge-interactions/);
});

test('a render_ui form still renders a password field as plain text', () => {
  const html = render('GenerativeUI', {
    blocks: [{ type: 'form', fields: [{ name: 'token', label: 'Token', type: 'password' }] }],
  });

  const input = html.match(/<input[^>]*name="token"[^>]*>/)?.[0];
  assert.ok(input, 'the field is rendered');
  assert.match(input, /type="text"/);
  assert.doesNotMatch(html, /type="password"/);
});

test('the runner feed shows a call that paused the run as waiting, not done', () => {
  const html = render('RunnerFeed', {
    run: {
      logs: [
        { eid: 1, kind: 'tool', label: 'ask_user', status: 'started', detail: '{"question":"Which account?"}' },
        { eid: 1, kind: 'tool', label: 'ask_user', status: 'awaiting', detail: 'Which account?' },
        { eid: 2, kind: 'tool', label: 'fetch_url', status: 'done', detail: 'ok' },
      ],
    },
  });

  assert.equal(count(html, 'data-testid="runner-activity-awaiting"'), 1);
  assert.match(html, /waiting for input/);
  assert.equal(count(html, '✓'), 1);
});
