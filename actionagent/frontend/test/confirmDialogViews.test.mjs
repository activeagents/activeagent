import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The confirmation dialog, bundled with esbuild and rendered to static
// markup, and a check that nothing in the dashboard still calls the
// browser's own confirm().

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/confirm-dialog-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ConfirmDialog } from './components/dashboard/ConfirmDialog.jsx';
        export const render = (request) =>
          renderToStaticMarkup(React.createElement(ConfirmDialog, { request, onSettle() {} }));
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

const request = (overrides = {}) => ({
  title: 'Delete TonsOfFun/docsage?',
  message: 'Its secrets, agent and evaluation are deleted.',
  confirmLabel: 'Delete project',
  cancelLabel: 'Cancel',
  danger: true,
  requireText: null,
  ...overrides,
});

test('the dialog is an accessible alertdialog named by its title and described by its message', () => {
  const html = render(request());
  assert.match(html, /role="alertdialog"/);
  assert.match(html, /aria-modal="true"/);
  const labelledBy = html.match(/aria-labelledby="([^"]+)"/)[1];
  const describedBy = html.match(/aria-describedby="([^"]+)"/)[1];
  assert.match(html, new RegExp(`id="${labelledBy}"[^>]*>Delete TonsOfFun/docsage\\?<`));
  assert.ok(html.includes(`id="${describedBy}"`));
  assert.match(html, /Its secrets, agent and evaluation are deleted\./);
});

test('without requireText, Confirm is enabled and there is no input', () => {
  const html = render(request());
  assert.doesNotMatch(html, /data-testid="confirm-input"/);
  assert.doesNotMatch(html, /data-testid="confirm-confirm"[^>]*disabled/);
  assert.match(html, />Delete project</);
  assert.match(html, />Cancel</);
});

test('with requireText, it asks for the exact text and Confirm starts disabled', () => {
  const html = render(request({ requireText: 'TonsOfFun/docsage' }));
  assert.match(html, /Type <code[^>]*>TonsOfFun\/docsage<\/code> to confirm\./);
  assert.match(html, /data-testid="confirm-input"/);
  assert.match(html, /aria-label="Type TonsOfFun\/docsage to confirm"/);
  assert.match(html, /<button[^>]*data-testid="confirm-confirm"[^>]*disabled/);
});

test('a destructive confirm button is red', () => {
  assert.match(render(request()), /data-testid="confirm-confirm"[^>]*style="[^"]*background:var\(--color-error\)/);
  assert.doesNotMatch(render(request({ danger: false })), /background:var\(--color-error\)/);
});

test("nothing in the dashboard calls the browser's confirm()", () => {
  const offenders = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (/\.(jsx?|mjs)$/.test(entry.name)) {
        readFileSync(path, 'utf8').split('\n').forEach((line, index) => {
          if (/(^|[^\w.])(window\.)?confirm\(/.test(line) && !line.trim().startsWith('//')) offenders.push(`${path}:${index + 1}`);
        });
      }
    }
  };
  for (const dir of ['components', 'pages', 'utils', 'hooks', 'contexts']) {
    try { walk(join(root, dir)); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
  assert.deepEqual(offenders, []);
});
