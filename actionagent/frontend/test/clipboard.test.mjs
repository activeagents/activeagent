import assert from 'node:assert/strict';
import test from 'node:test';
import { copyToClipboard } from '../utils/clipboard.mjs';

// A fake document just complete enough for the legacy copy path: a body
// that holds the textarea while the command runs, and an execCommand whose
// answer the caller reports.
const fakeDocument = ({ copies = true } = {}) => {
  const body = { children: [], appendChild(node) { this.children.push(node); }, removeChild(node) { this.children = this.children.filter((n) => n !== node); } };
  const commands = [];
  return {
    body,
    commands,
    createElement: () => ({ style: {}, value: '', setAttribute() {}, select() {}, setSelectionRange() {} }),
    execCommand(name) { commands.push({ name, selected: body.children[0]?.value }); return copies; },
  };
};

test('uses the Clipboard API when the page has it', async () => {
  const written = [];
  const navigator = { clipboard: { writeText: async (text) => { written.push(text); } } };

  assert.equal(await copyToClipboard('# Fix', { navigator, document: fakeDocument() }), true);
  assert.deepEqual(written, ['# Fix']);
});

test('falls back to the legacy copy command when the API is missing or refuses, and cleans up', async () => {
  const doc = fakeDocument();
  assert.equal(await copyToClipboard('brief', { navigator: {}, document: doc }), true);
  assert.deepEqual(doc.commands, [{ name: 'copy', selected: 'brief' }]);
  assert.equal(doc.body.children.length, 0);

  const refusing = { clipboard: { writeText: async () => { throw new Error('denied'); } } };
  const again = fakeDocument();
  assert.equal(await copyToClipboard('brief', { navigator: refusing, document: again }), true);
  assert.equal(again.commands.length, 1);
});

test('reports false when nothing can copy, without throwing', async () => {
  assert.equal(await copyToClipboard('brief', { navigator: {}, document: fakeDocument({ copies: false }) }), false);
  assert.equal(await copyToClipboard('brief', { navigator: undefined, document: undefined }), false);
  assert.equal(await copyToClipboard('brief', { navigator: {}, document: { body: {} } }), false);
});
