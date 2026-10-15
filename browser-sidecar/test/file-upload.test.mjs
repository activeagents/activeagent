import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import test from 'node:test';

import { ControlLock } from '../lib/control-lock.mjs';
import { FileChooserRelay, UPLOAD_CHUNK_BYTES, clearAgentFileChooser, sanitizeFileName } from '../lib/file-upload.mjs';

const ADA = { id: '1', name: 'Ada' };
const BEA = { id: '2', name: 'Bea' };
// Stands in for the private symbol Playwright MCP keeps its tab under.
const TAB = Symbol('tab');

// Stands in for a Playwright FileChooser, keeping the files it was given.
class FakeChooser {
  constructor(page, { multiple = false, accept = null, fail = null } = {}) {
    this.pageObject = page;
    this.multiple = multiple;
    this.acceptValue = accept;
    this.fail = fail;
    this.files = null;
  }

  page() {
    return this.pageObject;
  }

  isMultiple() {
    return this.multiple;
  }

  element() {
    return { getAttribute: async (name) => (name === 'accept' ? this.acceptValue : null) };
  }

  async setFiles(paths) {
    if (this.fail) throw new Error(this.fail);
    this.files = await Promise.all(paths.map(async (path) => ({ path, name: basename(path), body: await readFile(path, 'utf8') })));
  }
}

// A page with Playwright MCP's tab on it, holding a modal state per chooser
// opened while an agent is connected.
class FakePage extends EventEmitter {
  constructor() {
    super();
    const states = [];
    this[TAB] = { modalStates: () => [...states], clearModalState: (state) => states.splice(states.indexOf(state), 1) };
    this.states = states;
  }

  openChooser(options) {
    const chooser = new FakeChooser(this, options);
    this.states.push({ type: 'fileChooser', fileChooser: chooser });
    this.emit('filechooser', chooser);
    return chooser;
  }
}

class FakeContext extends EventEmitter {
  constructor() {
    super();
    this.page = new FakePage();
  }

  pages() {
    return [this.page];
  }
}

async function setup(t, { limits, timeoutMs } = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'sidecar-uploads-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const context = new FakeContext();
  const lock = new ControlLock({ graceMs: 50 });
  const relay = new FileChooserRelay({ context, lock, dir, limits, timeoutMs });
  const changes = [];
  const events = [];
  relay.on('change', (state) => changes.push(state));
  relay.on('uploaded', (event) => events.push(['uploaded', event]));
  relay.on('unavailable', (event) => events.push(['unavailable', event]));
  relay.attach();
  t.after(() => relay.close());
  return { dir, context, lock, relay, changes, events, page: context.page };
}

const settled = (relay) => relay.queue;
const chunk = (text) => Buffer.from(text).toString('base64');

test('a file name keeps only its last segment, with nothing a file system or a page could trip on', () => {
  assert.equal(sanitizeFileName('report.pdf'), 'report.pdf');
  assert.equal(sanitizeFileName('../../etc/passwd'), 'passwd');
  assert.equal(sanitizeFileName('C:\\Users\\ada\\notes.txt'), 'notes.txt');
  assert.equal(sanitizeFileName('..hidden'), 'hidden');
  assert.equal(sanitizeFileName('a\u0000b\nc<d>:"|?*.md'), 'abcd.md');
  assert.equal(sanitizeFileName('résumé 2026.docx'), 'résumé 2026.docx');
  assert.equal(sanitizeFileName('..'), 'upload');
  assert.equal(sanitizeFileName(''), 'upload');
  assert.equal(sanitizeFileName(42), 'upload');
  assert.ok(Buffer.byteLength(sanitizeFileName(`${'é'.repeat(300)}.txt`)) <= 200);
});

test('a chooser opened while nobody drives is left to the agent, and to the dialog of a headed browser', async (t) => {
  const { relay, lock, page, context, changes } = await setup(t);
  assert.equal(page.listenerCount('filechooser'), 0, 'Playwright intercepts choosers only while something listens');
  page.openChooser();
  await settled(relay);
  assert.equal(relay.state, null);
  assert.deepEqual(changes, []);
  assert.equal(page.states.length, 1, "the agent's modal state is untouched");

  lock.acquire('ada-1', ADA);
  assert.equal(page.listenerCount('filechooser'), 1);
  const opened = new FakePage();
  context.emit('page', opened);
  assert.equal(opened.listenerCount('filechooser'), 1, 'a page opened while someone drives is listened on too');
  lock.release('ada-1');
  assert.equal(page.listenerCount('filechooser'), 0);
});

test('the person driving answers a chooser: the files are written privately and set on the input', async (t) => {
  const { relay, lock, page, changes, events } = await setup(t);
  lock.acquire('ada-1', ADA);
  const chooser = page.openChooser({ multiple: true, accept: '.txt,.md' });
  await settled(relay);

  const offered = relay.state;
  assert.deepEqual({ ...offered, id: undefined, since: undefined }, {
    id: undefined, since: undefined, multiple: true, accept: '.txt,.md', max_files: 10, max_file_bytes: 25 * 1024 * 1024,
  });
  assert.deepEqual(changes, [offered]);

  assert.deepEqual(await relay.begin('ada-1', { chooser: offered.id, files: [{ name: '../notes.txt', size: 5 }, { name: 'notes.txt', size: 6 }] }), { done: false });
  // One chunk may span the end of one file and the start of the next.
  assert.equal((await relay.chunk('ada-1', { chooser: offered.id, data: chunk('helloworl') })).done, false);
  assert.equal((await relay.chunk('ada-1', { chooser: offered.id, data: chunk('d!') })).done, true);

  assert.deepEqual(chooser.files.map(({ name, body }) => [name, body]), [['notes.txt', 'hello'], ['notes.txt', 'world!']]);
  assert.notEqual(chooser.files[0].path, chooser.files[1].path);
  assert.equal((await stat(chooser.files[0].path)).mode & 0o777, 0o600, 'only the sidecar can read an uploaded file');
  assert.equal(relay.state, null);
  assert.equal(changes.at(-1), null);
  assert.deepEqual(events, [['uploaded', { id: offered.id, user: ADA, files: 2, bytes: 11 }]]);
  assert.equal(page.states.length, 0, "the agent's modal state for that chooser is cleared");
});

test('empty files are set at once', async (t) => {
  const { relay, lock, page } = await setup(t);
  lock.acquire('ada-1', ADA);
  const chooser = page.openChooser();
  await settled(relay);
  assert.deepEqual(await relay.begin('ada-1', { chooser: relay.state.id, files: [{ name: 'empty.txt', size: 0 }] }), { done: true });
  assert.deepEqual(chooser.files.map(({ name, body }) => [name, body]), [['empty.txt', '']]);
});

test('only the connection driving may answer, and only the chooser on offer', async (t) => {
  const { relay, lock, page } = await setup(t);
  lock.acquire('ada-1', ADA);
  page.openChooser();
  await settled(relay);
  const { id } = relay.state;

  await assert.rejects(relay.begin('bea-1', { chooser: id, files: [{ name: 'a', size: 1 }] }), { code: 'not_driving' });
  await assert.rejects(relay.begin('ada-1', { chooser: 'another', files: [{ name: 'a', size: 1 }] }), { code: 'no_chooser' });
  await assert.rejects(relay.chunk('ada-1', { chooser: id, data: chunk('a') }), { code: 'bad_upload' }, 'bytes before a begin');
  await assert.rejects(relay.cancel('bea-1', id), { code: 'not_driving' });
  assert.equal(relay.state.id, id);
});

test('uploads past the limits are refused before anything is written', async (t) => {
  const { relay, lock, page, dir } = await setup(t, { limits: { maxFileBytes: 10, maxFiles: 2, maxSessionBytes: 15 } });
  lock.acquire('ada-1', ADA);
  page.openChooser();
  await settled(relay);
  const { id } = relay.state;
  assert.equal(relay.state.max_files, 1, 'a single-file input takes one');

  await assert.rejects(relay.begin('ada-1', { chooser: id, files: [{ name: 'a', size: 1 }, { name: 'b', size: 1 }] }), { code: 'too_many', message: 'This field takes one file' });
  await assert.rejects(relay.begin('ada-1', { chooser: id, files: [{ name: 'big.bin', size: 11 }] }), { code: 'too_large', message: /big\.bin is larger than/ });
  await assert.rejects(relay.begin('ada-1', { chooser: id, files: [] }), { code: 'bad_upload' });
  await assert.rejects(relay.begin('ada-1', { chooser: id, files: [{ name: 'a', size: -1 }] }), { code: 'bad_upload' });
  assert.deepEqual(await readdir(dir), []);

  await relay.begin('ada-1', { chooser: id, files: [{ name: 'a', size: 10 }] });
  await relay.chunk('ada-1', { chooser: id, data: chunk('0123456789') });
  page.openChooser();
  await settled(relay);
  await assert.rejects(relay.begin('ada-1', { chooser: relay.state.id, files: [{ name: 'b', size: 6 }] }), { code: 'too_large', message: /in all/ });
});

test('a chunk that is not base64, or overruns the files, is refused', async (t) => {
  const { relay, lock, page } = await setup(t);
  lock.acquire('ada-1', ADA);
  page.openChooser();
  await settled(relay);
  const { id } = relay.state;
  await relay.begin('ada-1', { chooser: id, files: [{ name: 'a.txt', size: 3 }] });

  await assert.rejects(relay.chunk('ada-1', { chooser: id, data: 'not base64!' }), { code: 'bad_upload' });
  await assert.rejects(relay.chunk('ada-1', { chooser: id, data: 'A'.repeat(Math.ceil(UPLOAD_CHUNK_BYTES / 3) * 4 + 4) }), { code: 'bad_upload' });
  await assert.rejects(relay.chunk('ada-1', { chooser: id, data: chunk('abcd') }), { code: 'bad_upload', message: /More bytes/ });
  await assert.rejects(relay.chunk('ada-1', { chooser: id, data: chunk('abc') }), { code: 'bad_upload' }, 'the overrun ended the upload');
  assert.equal(relay.state.id, id, 'the chooser stays on offer for another try');
});

test('cancelling, handing back or timing out withdraws the chooser and what was half sent', async (t) => {
  const { relay, lock, page, dir } = await setup(t, { timeoutMs: 30 });
  lock.acquire('ada-1', ADA);
  const cancelled = page.openChooser();
  await settled(relay);
  await relay.begin('ada-1', { chooser: relay.state.id, files: [{ name: 'a.txt', size: 4 }] });
  await relay.chunk('ada-1', { chooser: relay.state.id, data: chunk('ab') });
  await relay.cancel('ada-1', relay.state.id);
  assert.equal(relay.state, null);
  assert.equal(cancelled.files, null, 'the input keeps what it had');
  assert.deepEqual(await readdir(dir), []);
  assert.equal(page.states.length, 0);

  page.openChooser();
  await settled(relay);
  assert.ok(relay.state);
  lock.release('ada-1');
  await settled(relay);
  assert.equal(relay.state, null, 'handing back withdraws it');

  lock.acquire('ada-1', ADA);
  page.openChooser();
  await settled(relay);
  await new Promise((resolve) => setTimeout(resolve, 80));
  await settled(relay);
  assert.equal(relay.state, null, 'an unanswered chooser times out');
});

test('control moving to another connection ends the upload the old one began', async (t) => {
  const { relay, lock, page } = await setup(t);
  lock.acquire('ada-1', ADA);
  page.openChooser();
  await settled(relay);
  const { id } = relay.state;
  await relay.begin('ada-1', { chooser: id, files: [{ name: 'a.txt', size: 4 }] });

  lock.acquire('ada-2', ADA);
  await settled(relay);
  assert.equal(relay.state.id, id, 'the chooser waits for the new connection');
  await assert.rejects(relay.chunk('ada-2', { chooser: id, data: chunk('ab') }), { code: 'bad_upload' });
  await assert.rejects(relay.chunk('ada-1', { chooser: id, data: chunk('ab') }), { code: 'not_driving' });
  assert.equal(lock.acquire('bea-1', BEA).taken, false);
});

test('a page that refuses the files fails the upload and frees its space', async (t) => {
  const { relay, lock, page, dir } = await setup(t, { limits: { maxSessionBytes: 4 } });
  lock.acquire('ada-1', ADA);
  page.openChooser({ fail: 'Node is detached' });
  await settled(relay);
  await relay.begin('ada-1', { chooser: relay.state.id, files: [{ name: 'a.txt', size: 4 }] });
  await assert.rejects(relay.chunk('ada-1', { chooser: relay.state.id, data: chunk('abcd') }), { code: 'upload_failed', message: /Node is detached/ });
  assert.equal(relay.state, null);
  assert.deepEqual(await readdir(dir), []);
  assert.equal(relay.storedBytes, 0);
});

test('with uploads turned off the person driving is told, and the chooser is left alone', async (t) => {
  const { relay, lock, page, events } = await setup(t, { limits: { maxFiles: 0 } });
  lock.acquire('ada-1', ADA);
  page.openChooser();
  await settled(relay);
  assert.equal(relay.state, null);
  assert.deepEqual(events, [['unavailable', { reason: 'File uploads are turned off for this browser' }]]);
});

test("clearing an agent's chooser leaves its other modal states", () => {
  const page = new FakePage();
  const answered = page.openChooser();
  const other = page.openChooser();
  page.states.push({ type: 'dialog' });
  clearAgentFileChooser(page, answered);
  assert.deepEqual(page.states.map((state) => state.fileChooser ?? state.type), [other, 'dialog']);
  assert.doesNotThrow(() => clearAgentFileChooser({}, answered), 'a page without the tab');
});

test("taking control offers a chooser an agent left open, and answering it clears the agent's wait", async (t) => {
  const { relay, lock, page, changes } = await setup(t);
  const chooser = page.openChooser({ multiple: false, accept: '.pdf' });
  await settled(relay);
  assert.equal(relay.state, null, 'nobody drives yet: the chooser is the agent\'s');
  assert.equal(page.states.length, 1);

  lock.acquire('ada-1', ADA);
  await settled(relay);
  const offered = relay.state;
  assert.equal(offered.accept, '.pdf');
  assert.equal(offered.max_files, 1);
  assert.deepEqual(changes, [offered]);

  await relay.begin('ada-1', { chooser: offered.id, files: [{ name: 'invoice.pdf', size: 3 }] });
  assert.equal((await relay.chunk('ada-1', { chooser: offered.id, data: chunk('pdf') })).done, true);
  assert.deepEqual(chooser.files.map(({ name }) => name), ['invoice.pdf']);
  assert.equal(page.states.length, 0, "the agent's modal state is cleared once the person answered");
});

test("an adopted chooser handed back unanswered stays the agent's", async (t) => {
  const { relay, lock, page } = await setup(t);
  page.openChooser();
  lock.acquire('ada-1', ADA);
  await settled(relay);
  assert.ok(relay.state);

  lock.release('ada-1');
  await settled(relay);
  assert.equal(relay.state, null);
  assert.equal(page.states.length, 1, 'the agent may still answer it with browser_file_upload');
});
