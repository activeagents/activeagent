import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// A project's Sessions tab and a code conversation's first render, bundled
// with esbuild and rendered to static markup.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/code-interaction-views-${process.pid}.mjs`, import.meta.url));

let renderSessions;
let renderConversation;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', {
    value: { location: { search: '', pathname: '/activeagents/interactions/code-1' }, ACTIVE_AGENT_DASHBOARD: { mountPath: '/activeagents' } },
    configurable: true, writable: true,
  });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import ProjectSessions from './components/dashboard/projects/ProjectSessions.jsx';
        import CodeInteraction from './components/dashboard/interactions/CodeInteraction.jsx';

        const wrap = (element) => renderToStaticMarkup(React.createElement(ThemeProvider, null, element));
        export const renderSessions = (props) => wrap(React.createElement(ProjectSessions, props));
        export const renderConversation = (props) => wrap(React.createElement(CodeInteraction, props));
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
  ({ renderSessions, renderConversation } = await import(pathToFileURL(bundlePath).href));
});

after(() => rmSync(bundlePath, { force: true }));

test("a project's Sessions tab offers a conversation once its sandbox is ready", () => {
  const ready = renderSessions({ project: { id: 3, repository: 'acme/docs', sandbox_state: 'ready', sandbox: { session_id: 's-1' } } });
  assert.match(ready, /Chat with Claude Code/);
  assert.match(ready, /<label[^>]*for="project-3-chat"/);
  assert.match(ready, /What should Claude Code do in acme\/docs\?/);
  assert.match(ready, /never commits or pushes/);

  const booting = renderSessions({ project: { id: 3, repository: 'acme/docs', sandbox_state: 'booting', sandbox: null } });
  assert.match(booting, /Boot the sandbox to start a conversation/);
  assert.match(booting, /<textarea[^>]*disabled=""/);
});

test('a conversation shows that it is loading before its turns arrive', () => {
  const html = renderConversation({ rootId: 1 });
  assert.match(html, /data-testid="code-interaction"/);
  assert.match(html, /Loading…/);
});
