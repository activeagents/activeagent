import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

// The live view's file chooser prompt, bundled with esbuild and rendered to
// static markup.

const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/live-view-views-${process.pid}.mjs`, import.meta.url));

let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import { FileChooserPrompt } from './components/dashboard/LiveView.jsx';

        export const render = (props) =>
          renderToStaticMarkup(React.createElement(ThemeProvider, null, React.createElement(FileChooserPrompt, props)));
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
const chooser = { id: 'c1', multiple: false, accept: '.pdf,.txt', since: 1, max_files: 10, max_file_bytes: 1024 };

test('the person driving gets a file input that takes what the page takes', () => {
  const html = render({ chooser, upload: null, onFiles: noop, onCancel: noop });
  assert.match(html, /The page asked for a file/);
  assert.match(html, /<input type="file" accept="\.pdf,\.txt"/);
  assert.doesNotMatch(html, /multiple/);
  assert.match(html, /The page takes \.pdf,\.txt/);
  assert.match(html, />Cancel</);
});

test('a field that takes several files lets several be chosen', () => {
  const html = render({ chooser: { ...chooser, multiple: true, accept: null }, upload: null, onFiles: noop, onCancel: noop });
  assert.match(html, /The page asked for files/);
  assert.match(html, /up to 10 files/);
  assert.match(html, /multiple=""/);
  assert.doesNotMatch(html, /accept=/);
});

test('while files are sent, the input gives way to the progress', () => {
  const html = render({ chooser, upload: { sent: 512, total: 1024 }, onFiles: noop, onCancel: noop });
  assert.match(html, /Uploading 1 KB… 50%/);
  assert.doesNotMatch(html, /type="file"/);
});
