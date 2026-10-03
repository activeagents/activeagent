import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The Project page's setup views that render from their props alone,
// bundled with esbuild and rendered to static markup: a request for input
// answered inline, the setup assistant card, the boot's "Waiting for you",
// the chooser of what the App assistant may read, and the install pull
// request card.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/project-setup-views-${process.pid}.mjs`, import.meta.url));

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
        import { InputRequestCardView } from './components/dashboard/projects/ProjectInputRequests.jsx';
        import ProjectSetupCard from './components/dashboard/projects/ProjectSetupCard.jsx';
        import ProjectBootProgress from './components/dashboard/projects/ProjectBootProgress.jsx';
        import { AssistantReadsView } from './components/dashboard/projects/ProjectAssistantReads.jsx';
        import { InstallPullRequestCard } from './components/dashboard/projects/ProjectInstallPullRequest.jsx';

        const views = { InputRequestCardView, ProjectSetupCard, ProjectBootProgress, AssistantReadsView, InstallPullRequestCard };
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

const noop = () => {};
const secretRequest = {
  id: 9, kind: 'secret', tool_name: 'request_secret', run_id: 41, agent: { id: 3, name: 'Setup assistant for acme/shop' },
  prompt: 'The setup assistant for acme/shop asks for STRIPE_API_KEY: The app reads it at boot. The value is stored as one of the ' +
    "project's secrets and handed to acme/shop's code in its sandbox.",
};

test('a secret request names who asks and where the value goes, in a masked field', () => {
  const html = render('InputRequestCardView', { request: secretRequest, value: '', onChange: noop, busy: false, onAnswer: noop, onDecline: noop });

  assert.match(html, /Setup assistant for acme\/shop asks/);
  assert.match(html, /asks for STRIPE_API_KEY/);
  assert.match(html, /handed to acme\/shop&#x27;s code in its sandbox/);
  assert.match(html, /<input id="project-answer-9" type="password" autoComplete="new-password" data-aa-secret=""/);
  assert.match(html, /The assistant never sees this value/);
  assert.match(html, />Answer<\/button>/);
  assert.match(html, />Decline<\/button>/);
});

test('a short secret cannot be sent yet, and says why', () => {
  const html = render('InputRequestCardView', { request: secretRequest, value: 'short', onChange: noop, busy: false, onAnswer: noop, onDecline: noop });

  assert.match(html, /<button type="submit" disabled=""[^>]*>Answer<\/button>/);
  assert.match(html, /A secret is at least 8 characters/);
});

test('a confirm request is approved or declined with its buttons, and a choice picks an option', () => {
  const confirm = render('InputRequestCardView', {
    request: { id: 2, kind: 'confirm', prompt: 'Allow retry_boot to run?', run_id: 1 }, value: '', onChange: noop, onAnswer: noop, onDecline: noop,
  });
  assert.match(confirm, />Approve<\/button>/);
  assert.doesNotMatch(confirm, /<input/);

  const choice = render('InputRequestCardView', {
    request: { id: 3, kind: 'choice', prompt: 'Which database?', options: ['sqlite3', 'postgresql'], run_id: 1 },
    value: '', onChange: noop, onAnswer: noop, onDecline: noop,
  });
  assert.match(choice, /<option value="postgresql">postgresql<\/option>/);
});

test('the boot reads Waiting for you while a request waits', () => {
  assert.match(render('ProjectBootProgress', { boot: null, sandboxState: 'failed', waiting: 2 }), /Waiting for you: 2/);
  assert.doesNotMatch(render('ProjectBootProgress', { boot: null, sandboxState: 'failed', waiting: 0 }), /Waiting for you/);
});

test('the setup card says why the assistant cannot run, and offers it only on a failed boot', () => {
  const unavailable = render('ProjectSetupCard', {
    project: { sandbox_state: 'failed', setup: { available: false, auto: true, reason: 'No provider key the setup assistant can use.' } },
    onAsk: noop, onToggleAuto: noop,
  });
  assert.match(unavailable, /No provider key the setup assistant can use/);
  assert.match(unavailable, /Set the variables the boot needs in the Environment tab/);
  assert.doesNotMatch(unavailable, /Ask the setup assistant/);

  const failed = render('ProjectSetupCard', {
    project: { sandbox_state: 'failed', setup: { available: true, auto: true, last_run: null } }, onAsk: noop, onToggleAuto: noop,
  });
  assert.match(failed, /data-testid="ask-setup-assistant"/);
  assert.match(failed, /<input type="checkbox" checked=""\/>\s*Start it when a boot fails/);
  assert.match(failed, /runs no\s+commands and reads no files/);
});

test('the chooser lists each model\'s columns with filter and read boxes, ticked as chosen', () => {
  const models = [{ name: 'Reservation', table: 'reservations', columns: [{ name: 'status', type: 'string' }, { name: 'starts_at', type: 'datetime' }] }];
  const selection = { Reservation: { filterable: new Set(['status']), returns: new Set(['status', 'starts_at']) } };
  const html = render('AssistantReadsView', { listed: true, models, selection, changed: true, onToggle: noop, onSave: noop, onSaveAndRestart: noop });

  assert.match(html, /<details open=""[^>]*data-testid="assistant-model-Reservation"/);
  assert.match(html, /1 filter · 2 read/);
  assert.match(html, /aria-label="Filter on Reservation.status" checked=""/);
  assert.match(html, /aria-label="Filter on Reservation.starts_at"\/>/);
  assert.match(html, /Save and restart the sandbox/);

  const unlisted = render('AssistantReadsView', { listed: false, models: null, selection: {}, onToggle: noop });
  assert.match(unlisted, /Boot the project first/);
});

test('the install card offers Open install PR before one exists, and Update draft PR while it is open', () => {
  const project = { install_state: 'bootstrapped' };
  const none = render('InstallPullRequestCard', { project, pullRequest: null, allowlist: ['Gemfile'], onOpenDialog: noop, onOpenBranch: noop });
  assert.match(none, /data-testid="open-install-pr"/);
  assert.match(none, /not opened/);
  assert.match(none, /<li>Gemfile<\/li>/);

  const open = render('InstallPullRequestCard', {
    project, allowlist: [], onOpenDialog: noop, onOpenBranch: noop,
    pullRequest: { status: 'published', number: 3, state: 'open', draft: true, url: 'https://github.com/acme/shop/pull/3',
      branch: 'activeagent/install-engine', base_branch: 'main' },
  });
  assert.match(open, />Update draft PR</);
  assert.doesNotMatch(open, /Open install PR/);
  assert.match(open, /draft open/);
  assert.match(open, /activeagent\/install-engine → main/);

  const merged = render('InstallPullRequestCard', {
    project: { install_state: 'installed' }, allowlist: [], onOpenDialog: noop, onOpenBranch: noop,
    pullRequest: { status: 'published', number: 3, state: 'merged' },
  });
  assert.match(merged, /The pull request merged/);
  assert.doesNotMatch(merged, /Update draft PR|Open install PR/);
});
