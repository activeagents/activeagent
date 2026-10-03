import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import test, { after, before } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import {
  branchNameError,
  canOpenBranch,
  canUpdate,
  fileStatusLetter,
  formatBytes,
  hasUnreadFiles,
  initialSelection,
  isPublishInProgress,
  needsReload,
  parseAllowlist,
  patchPath,
  publishBlocker,
  publishRequestBody,
  pullRequestStatus,
  revertedFiles,
  selectedFiles,
  selectionSummary,
  toggleSelection,
} from '../utils/draftPullRequests.mjs';

const files = [
  { path: 'README.md', status: 'modified', size: 10, digest: 'd1', diff: 'diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-# Shop\n+# Shop v2\n' },
  { path: 'app/models/gadget.rb', status: 'added', size: 18, digest: 'd2', diff: 'diff --git a/app/models/gadget.rb b/app/models/gadget.rb\n' },
  { path: '.github/workflows/ci.yml', status: 'modified', size: 9, refusal: 'excluded', refusal_message: 'files under .github/ are never published' },
  { path: 'config/leak.yml', status: 'added', size: 40, refusal: 'secret', refusal_message: 'contains a secret of this sandbox or a GitHub token' },
];

test('every publishable file starts ticked, and a refused one never is', () => {
  const selection = initialSelection(files);

  assert.deepEqual([...selection], ['README.md', 'app/models/gadget.rb']);
  assert.equal(selectionSummary(files, selection), '2 of 2 files selected · 2 cannot be published');
  const one = toggleSelection(selection, 'README.md');
  assert.deepEqual([...one], ['app/models/gadget.rb']);
  assert.deepEqual([...selection], ['README.md', 'app/models/gadget.rb'], 'toggling returns a new set');
  assert.deepEqual(selectedFiles(files, new Set(['config/leak.yml', 'README.md'])).map((file) => file.path), ['README.md']);
});

test('the publish request carries each chosen file with the digest the preview reported', () => {
  const selection = new Set(['README.md']);

  assert.deepEqual(publishRequestBody({ files, selection, title: ' Add gadgets ', body: 'Why', branch: ' activeagent/x ' }), {
    files: [{ path: 'README.md', digest: 'd1' }], title: 'Add gadgets', body: 'Why', branch: 'activeagent/x',
  });
  assert.deepEqual(publishRequestBody({ files, selection, title: 'T', body: 'B', branch: 'ignored', message: ' Tidy ', update: true }), {
    files: [{ path: 'README.md', digest: 'd1' }], message: 'Tidy', update: true,
  }, 'an update carries a commit message, never the pull request\'s title or description');
  assert.deepEqual(publishRequestBody({ files, selection, title: 'T', branch: 'b', allowlist: ['app/**'] }).allowlist, ['app/**']);
});

test('publishing waits for a file, a title and a valid branch', () => {
  const selection = new Set(['README.md']);

  assert.equal(publishBlocker({ files, selection: new Set(), title: 'T', branch: 'b' }), 'Choose at least one file.');
  assert.equal(publishBlocker({ files, selection, title: '  ', branch: 'b' }), 'Add a title.');
  assert.equal(publishBlocker({ files, selection, title: 'T', branch: '' }), 'Name the branch.');
  assert.equal(publishBlocker({ files, selection, title: 'T', branch: 'activeagent/gadgets' }), null);
  assert.equal(publishBlocker({ files, selection, title: '', branch: '', message: 'Tidy', update: true }), null, 'an update keeps its branch and title');
  assert.equal(publishBlocker({ files, selection, title: 'T', message: ' ', update: true }), 'Add a commit message.');
});

test('branch names follow the rules the server checks', () => {
  ['', 'has space', 'a..b', '-leading', 'trailing/', 'x.lock', '.hidden', 'a@{b', 'a//b', 'tab\there', 'café', 'end.', 'a:b', 'a~1', 'a^', 'a?', 'a*', 'a[b', 'a\\b']
    .forEach((name) => assert.ok(branchNameError(name), JSON.stringify(name)));
  ['activeagent/sandbox-1a2b3c4d', 'fix-123', 'feature/nested/name', 'v1.2'].forEach((name) => assert.equal(branchNameError(name), null, name));
  assert.ok(branchNameError('x'.repeat(201)));
});

test('a pull request reads as its state, and a publish as its progress', () => {
  assert.deepEqual(pullRequestStatus({ status: 'published', state: 'open', draft: true }), { label: 'Draft', tone: 'neutral' });
  assert.deepEqual(pullRequestStatus({ status: 'published', state: 'open', draft: false }), { label: 'Open', tone: 'success' });
  assert.deepEqual(pullRequestStatus({ status: 'published', state: 'merged' }), { label: 'Merged', tone: 'success' });
  assert.deepEqual(pullRequestStatus({ status: 'published', state: 'closed' }), { label: 'Closed', tone: 'error' });
  assert.deepEqual(pullRequestStatus({ status: 'queued' }), { label: 'Queued', tone: 'progress' });
  assert.deepEqual(pullRequestStatus({ status: 'draft_refused' }), { label: 'Branch published', tone: 'neutral' });
  assert.deepEqual(pullRequestStatus({ status: 'failed' }), { label: 'Failed', tone: 'error' });
  assert.deepEqual(pullRequestStatus({ status: 'failed', number: 3, state: 'open', draft: true }), { label: 'Draft · update failed', tone: 'error' });
  assert.deepEqual(pullRequestStatus({ status: 'failed', head_commit: 'abc' }), { label: 'Branch published · pull request not opened', tone: 'error' });
  assert.ok(isPublishInProgress({ status: 'publishing' }));
  assert.ok(!isPublishInProgress({ status: 'published' }));
  assert.ok(!isPublishInProgress(null));
});

test('only an opened, still open pull request can be updated, and only a branch without one can be opened', () => {
  const published = { status: 'published', operation: 'create', head_commit: 'abc', number: 12, state: 'open' };

  assert.ok(canUpdate(published));
  assert.ok(canUpdate({ ...published, status: 'failed', operation: 'update' }), 'a failed update can be tried again');
  assert.ok(canUpdate({ ...published, operation: 'open_regular', draft: false }), 'a regular pull request opened later too');
  assert.ok(!canUpdate({ ...published, state: 'merged' }));
  assert.ok(!canUpdate({ ...published, head_commit: null }));
  assert.ok(!canUpdate({ ...published, status: 'queued' }));
  assert.ok(!canOpenBranch(published));

  const branchOnly = { status: 'draft_refused', operation: 'create', head_commit: 'abc', number: null };
  assert.ok(!canUpdate(branchOnly), 'a branch GitHub refused a draft for has no pull request to update');
  assert.ok(canOpenBranch(branchOnly));
  assert.ok(canOpenBranch({ ...branchOnly, status: 'failed' }), 'opening it failed after the branch was pushed');
  assert.ok(!canOpenBranch({ ...branchOnly, status: 'queued' }));
  assert.ok(!canOpenBranch({ ...branchOnly, head_commit: null }), 'nothing was pushed');
});

test('an update names the files on the branch it returns to the checkout commit', () => {
  const pullRequest = { files: [{ path: 'README.md' }, { path: 'app/models/gadget.rb' }, { path: 'lib/gone.rb' }] };

  assert.deepEqual(revertedFiles(pullRequest, files, new Set(['README.md'])), ['app/models/gadget.rb', 'lib/gone.rb']);
  assert.deepEqual(revertedFiles(pullRequest, files, new Set(['README.md', 'app/models/gadget.rb'])), ['lib/gone.rb']);
  assert.deepEqual(revertedFiles(null, files, new Set()), []);
});

test('the paths to read are typed as patterns, and a preview that stopped reading says so', () => {
  assert.deepEqual(parseAllowlist(' app/**, lib/*.rb\nconfig/x.yml '), ['app/**', 'lib/*.rb', 'config/x.yml']);
  assert.equal(parseAllowlist(' , '), null);
  assert.ok(hasUnreadFiles([...files, { path: 'z.rb', refusal: 'not_read' }]));
  assert.ok(!hasUnreadFiles(files));
});

test('the patch path names the chosen files and the title', () => {
  assert.equal(patchPath('s 1'), '/api/sandboxes/s%201/pull_request/patch');
  assert.equal(
    patchPath('s1', ['README.md', 'app/a b.rb'], ' Add gadgets '),
    '/api/sandboxes/s1/pull_request/patch?paths%5B%5D=README.md&paths%5B%5D=app%2Fa+b.rb&title=Add+gadgets',
  );
});

test('small formatting helpers', () => {
  assert.equal(fileStatusLetter({ status: 'added' }), 'A');
  assert.equal(fileStatusLetter({ status: 'deleted' }), 'D');
  assert.equal(formatBytes(1), '1 byte');
  assert.equal(formatBytes(2048), '2 KB');
  assert.equal(formatBytes(3 * 1024 * 1024), '3.0 MB');
  assert.ok(needsReload('changed_since_preview'));
  assert.ok(!needsReload('secret'));
});

// The card and the dialog, bundled with esbuild and rendered to static
// markup from their props. Effects do not run in a server render.
const root = fileURLToPath(new URL('..', import.meta.url));
const bundlePath = fileURLToPath(new URL(`../node_modules/.cache/draft-pull-requests-${process.pid}.mjs`, import.meta.url));
let render;

before(async () => {
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => 'light', setItem() {} }, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: { location: { search: '' }, ACTIVE_AGENT_DASHBOARD: { mountPath: '/activeagents' } }, configurable: true, writable: true });

  const { outputFiles } = await build({
    stdin: {
      contents: `
        import React from 'react';
        import { renderToStaticMarkup } from 'react-dom/server';
        import { ThemeProvider } from './contexts/ThemeContext.jsx';
        import { PullRequestCard, DraftPullRequestDialogView } from './components/dashboard/DraftPullRequestPanel.jsx';

        const views = { PullRequestCard, DraftPullRequestDialogView };
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

const sandbox = { session_id: 'abc12345-0000', repository: 'acme/shop', repository_ref: 'main' };
const noop = () => {};
const dialogProps = (overrides = {}) => ({
  sandbox,
  preview: { files, suggested_branch: 'activeagent/sandbox-abc12345' },
  loading: false,
  error: null,
  publishing: { supported: true, available: true, patch_available: true },
  selection: new Set(['README.md']),
  onToggle: noop,
  fields: { title: 'Add gadgets', body: '', branch: 'activeagent/gadgets', message: 'Update from the sandbox', allowlist: '' },
  onField: noop,
  allowlistApplied: false,
  onApplyAllowlist: noop,
  pullRequest: null,
  mode: 'create',
  submitting: false,
  onSubmit: noop,
  onCancel: noop,
  ...overrides,
});

test('the dialog lists every file, ticks only chosen publishable ones, and shows the exact diff of each chosen file', () => {
  const html = render('DraftPullRequestDialogView', dialogProps());

  const boxes = [...html.matchAll(/<input type="checkbox" aria-label="Publish ([^"]+)"([^>]*)\/>/g)]
    .map(([, path, attributes]) => [path, attributes.includes('checked'), attributes.includes('disabled')]);
  assert.deepEqual(boxes, [
    ['README.md', true, false],
    ['app/models/gadget.rb', false, false],
    ['.github/workflows/ci.yml', false, true],
    ['config/leak.yml', false, true],
  ]);
  assert.match(html, /files under \.github\/ are never published/);
  assert.match(html, /contains a secret of this sandbox or a GitHub token/);
  assert.match(html, /What will be published/);
  assert.match(html, />\+# Shop v2</);
  assert.doesNotMatch(html, /diff --git a\/app\/models\/gadget\.rb/, 'an unticked file is not shown as published');
  assert.match(html, /href="\/activeagents\/api\/sandboxes\/abc12345-0000\/pull_request\/patch\?paths%5B%5D=README\.md&amp;title=Add\+gadgets"/);
  assert.match(html, />Open draft PR<\/button>/);
  assert.match(html, /value="activeagent\/gadgets"/);
  assert.match(html, />Description</);
  assert.doesNotMatch(html, /Only read paths matching/, 'the paths field shows only when the preview stopped reading');
});

test('the dialog offers only the patch where publishing is not available, and keeps the branch of an update', () => {
  const refused = render('DraftPullRequestDialogView', dialogProps({
    publishing: { supported: true, available: false, patch_available: true, refusal: 'Only the user who connected GitHub (@octocat) can publish' },
  }));
  assert.match(refused, /Only the user who connected GitHub/);
  assert.match(refused, /Download patch/);
  assert.doesNotMatch(refused, />Open draft PR<\/button>/);
  assert.doesNotMatch(refused, />Branch</, 'a patch has no branch');

  const update = render('DraftPullRequestDialogView', dialogProps({
    mode: 'update',
    pullRequest: { title: 'Add gadgets', branch: 'activeagent/gadgets', files: [{ path: 'README.md' }, { path: 'app/models/gadget.rb' }] },
  }));
  assert.match(update, />Update draft PR<\/button>/);
  assert.match(update, /<input type="text"[^>]*disabled=""[^>]*value="activeagent\/gadgets"|value="activeagent\/gadgets"[^>]*disabled=""/);
  assert.match(update, />Commit message</);
  assert.match(update, /value="Update from the sandbox"/);
  assert.doesNotMatch(update, />Title</, 'an update does not retitle the pull request');
  assert.doesNotMatch(update, />Description</);
  assert.match(update, /returned to how they are in the checkout commit: <span class="font-mono">app\/models\/gadget\.rb</);
});

test('a preview that stopped reading offers the paths to read instead', () => {
  const html = render('DraftPullRequestDialogView', dialogProps({
    preview: { files: [...files, { path: 'zz/late.rb', status: 'added', refusal: 'not_read', refusal_message: 'not read: a preview reads at most 300 files' }] },
  }));

  assert.match(html, /Only read paths matching/);
  assert.match(html, />Read again</);
  assert.match(html, /<input type="checkbox" aria-label="Publish zz\/late\.rb"[^>]*disabled=""/);
});

test('the card links the pull request, and offers to open a branch that has none', () => {
  const published = render('PullRequestCard', {
    pullRequest: { status: 'published', operation: 'create', head_commit: 'abc', state: 'open', draft: true, number: 12, title: 'Add gadgets',
      url: 'https://github.com/acme/shop/pull/12', branch: 'activeagent/gadgets', base_branch: 'main', files: [{ path: 'README.md' }] },
    publishing: { supported: true, available: true, patch_available: true },
    onOpenDialog: noop,
    onOpenBranch: noop,
  });
  assert.match(published, /href="https:\/\/github\.com\/acme\/shop\/pull\/12"[^>]*>#12 Add gadgets</);
  assert.match(published, />Draft</);
  assert.match(published, /activeagent\/gadgets → main · 1 file/);
  assert.match(published, />Update draft PR</);
  assert.doesNotMatch(published, /Download patch/, 'the patch is the fallback, offered in the dialog');

  const branchOnly = {
    title: 'Add gadgets', branch: 'activeagent/gadgets', base_branch: 'main', head_commit: 'abc', number: null, operation: 'create',
    compare_url: 'https://github.com/acme/shop/compare/main...activeagent/gadgets?expand=1',
  };
  const refused = render('PullRequestCard', {
    pullRequest: { ...branchOnly, status: 'draft_refused', error_message: 'GitHub does not open draft pull requests in acme/shop.' },
    publishing: { supported: true, available: true, patch_available: true },
    onOpenDialog: noop,
    onOpenBranch: noop,
  });
  assert.match(refused, /Compare on GitHub/);
  assert.match(refused, />Open as a regular pull request</);
  assert.doesNotMatch(refused, /Update draft PR/, 'a branch without a pull request is not updated');
  assert.doesNotMatch(refused, />Open</, 'no pull request is reported open');

  const failed = render('PullRequestCard', {
    pullRequest: { ...branchOnly, status: 'failed', error_code: 'github_error', error_message: 'GitHub refused the publish: GitHub answered 502' },
    publishing: { supported: true, available: true, patch_available: true },
    onOpenDialog: noop,
    onOpenBranch: noop,
  });
  assert.match(failed, /Branch published · pull request not opened/);
  assert.match(failed, /GitHub answered 502/);
  assert.match(failed, /Compare on GitHub/);
  assert.match(failed, />Open the draft PR again</);
  assert.doesNotMatch(failed, /Update draft PR|regular pull request/);

  const unavailable = render('PullRequestCard', {
    pullRequest: null,
    publishing: { supported: true, available: false, patch_available: true, refusal: 'No GitHub App installation or OAuth connection of this workspace can write to acme/shop' },
    onOpenDialog: noop,
    onOpenBranch: noop,
  });
  assert.match(unavailable, /can write to acme\/shop\. You can download its changes as a patch instead\./);
  assert.match(unavailable, /<button type="button"[^>]*>Download patch…<\/button>/, 'the patch opens the dialog, to choose its files');
  assert.doesNotMatch(unavailable, /Open draft PR/);
});
