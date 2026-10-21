import assert from 'node:assert/strict';
import test from 'node:test';
import { copyMarkdownFrom, markdownPartUrl, reportExports } from '../utils/reportExport.mjs';

test('derives the API report and its downloads from the in-app route', () => {
  assert.deepEqual(reportExports('/evaluations/3/runs/12/report'), {
    report: '/api/evaluations/3/runs/12/report',
    markdown: '/api/evaluations/3/runs/12/report.md',
    html: '/api/evaluations/3/runs/12/report?download=1',
    json: '/api/evaluations/3/runs/12/report.json?download=1',
    md: '/api/evaluations/3/runs/12/report.md?download=1',
  });
  assert.equal(reportExports(null), null);
});

test('names one piece of the Markdown report', () => {
  const base = '/x/report.md';
  assert.equal(markdownPartUrl(base), base);
  assert.equal(markdownPartUrl(base, { part: 'fix_items', model: 'all' }), `${base}?part=fix_items`);
  assert.equal(markdownPartUrl(base, { part: 'fix_items', model: 'openrouter/a b' }), `${base}?part=fix_items&model=openrouter%2Fa+b`);
  assert.equal(markdownPartUrl(base, { part: 'scenario', scenario: 'order_1' }), `${base}?part=scenario&scenario=order_1`);
  assert.equal(markdownPartUrl(null, { part: 'verdict' }), null);
});

const response = (body, ok = true) => ({ ok, status: ok ? 200 : 404, text: async () => body });

test('writes a pending ClipboardItem where the page has one', async () => {
  const written = [];
  class Item { constructor(parts) { this.parts = parts; } }
  class FakeBlob { constructor(parts, options) { this.text = parts.join(''); this.type = options.type; } }
  const ok = await copyMarkdownFrom('/report.md', {
    fetch: async () => response('# Report'),
    navigator: { clipboard: { write: async (items) => { written.push(await items[0].parts['text/plain']); } } },
    ClipboardItem: Item,
    Blob: FakeBlob,
  });
  assert.equal(ok, true);
  assert.equal(written[0].text, '# Report');
  assert.equal(written[0].type, 'text/plain');
});

test('falls back to fetching and writing text', async () => {
  const written = [];
  const ok = await copyMarkdownFrom('/report.md', {
    fetch: async () => response('## Verdict'),
    navigator: { clipboard: { writeText: async (text) => { written.push(text); } } },
    ClipboardItem: undefined,
  });
  assert.equal(ok, true);
  assert.deepEqual(written, ['## Verdict']);
});

test('reports a failed fetch without throwing', async () => {
  const ok = await copyMarkdownFrom('/report.md', {
    fetch: async () => response('', false),
    navigator: { clipboard: { writeText: async () => { throw new Error('never'); } } },
    ClipboardItem: undefined,
  });
  assert.equal(ok, false);
  assert.equal(await copyMarkdownFrom(null), false);
});
