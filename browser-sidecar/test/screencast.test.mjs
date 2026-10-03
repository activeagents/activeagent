import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';

import { SCREENCAST_OPTIONS, Screencast, pageUrl } from '../lib/screencast.mjs';

// Stand-ins for the Playwright objects the Screencast uses.
class FakeSession extends EventEmitter {
  constructor(page) {
    super();
    this.page = page;
    this.sent = [];
    this.detached = false;
  }

  async send(method, params) {
    this.sent.push([method, params]);
  }

  async detach() {
    this.detached = true;
  }

  methods() {
    return this.sent.map(([method]) => method);
  }
}

class FakePage extends EventEmitter {
  constructor(context, url) {
    super();
    this.context = context;
    this.address = url;
    this.closed = false;
    this.main = { name: 'main' };
  }

  url() {
    return this.address;
  }

  isClosed() {
    return this.closed;
  }

  mainFrame() {
    return this.main;
  }

  close() {
    this.closed = true;
    this.context.open = this.context.open.filter((page) => page !== this);
    this.emit('close');
  }

  navigate(url) {
    this.address = url;
    this.emit('framenavigated', this.main);
  }
}

class FakeContext extends EventEmitter {
  constructor() {
    super();
    this.open = [];
    this.sessions = [];
  }

  pages() {
    return [...this.open];
  }

  async newCDPSession(page) {
    const session = new FakeSession(page);
    this.sessions.push(session);
    return session;
  }

  newPage(url) {
    const page = new FakePage(this, url);
    this.open.push(page);
    this.emit('page', page);
    return page;
  }
}

function settle() {
  return new Promise((resolve) => setTimeout(resolve, 5));
}

async function setup() {
  const context = new FakeContext();
  const first = new FakePage(context, 'http://127.0.0.1:4100/orders?token=secret#top');
  context.open.push(first);
  const frames = [];
  let pageChanges = 0;
  const screencast = new Screencast({ context, onFrame: (frame) => frames.push(frame), onPageChange: () => (pageChanges += 1) });
  await screencast.attach();
  return { context, first, frames, screencast, pageChanges: () => pageChanges };
}

test("a page's address is shown without its query or fragment", () => {
  assert.equal(pageUrl('http://127.0.0.1:4100/orders?token=secret#top'), 'http://127.0.0.1:4100/orders');
  assert.equal(pageUrl('about:blank'), 'about:blank');
  assert.equal(pageUrl('data:text/html,secret'), null);
  assert.equal(pageUrl('not a url'), null);
});

test('streams the page on screen only once started', async () => {
  const { context, screencast } = await setup();
  assert.equal(context.sessions.length, 0);
  assert.deepEqual(screencast.pageInfo, { url: 'http://127.0.0.1:4100/orders', tab: 1, tabs: 1 });

  await screencast.start();

  assert.deepEqual(context.sessions[0].sent, [['Page.startScreencast', SCREENCAST_OPTIONS]]);
});

test('acknowledges every frame, and keeps the last one after it stops', async () => {
  const { context, frames, screencast } = await setup();
  await screencast.start();
  const [session] = context.sessions;

  session.emit('Page.screencastFrame', { data: 'ZnJhbWU=', metadata: { deviceWidth: 1280, deviceHeight: 800 }, sessionId: 7 });
  assert.deepEqual(session.sent.at(-1), ['Page.screencastFrameAck', { sessionId: 7 }]);
  assert.deepEqual(frames, [{ data: 'ZnJhbWU=', metadata: { deviceWidth: 1280, deviceHeight: 800 } }]);
  assert.equal(screencast.metadata.deviceWidth, 1280);

  await screencast.stop();
  assert.deepEqual(session.methods().slice(-1), ['Page.stopScreencast']);
  assert.equal(session.detached, true);
  assert.equal(screencast.lastFrame.data, 'ZnJhbWU=', 'a viewer who joins a still page gets the last frame');
});

test('a page that opens takes the screen, and the newest left takes it back when it closes', async () => {
  const { context, first, screencast, pageChanges } = await setup();
  await screencast.start();
  const before = pageChanges();

  const popup = context.newPage('http://127.0.0.1:4100/popup');
  await settle();
  assert.equal(screencast.page, popup);
  assert.deepEqual(screencast.pageInfo, { url: 'http://127.0.0.1:4100/popup', tab: 2, tabs: 2 });
  assert.equal(context.sessions[0].detached, true);
  assert.deepEqual(context.sessions[1].sent, [['Page.startScreencast', SCREENCAST_OPTIONS]]);
  assert.ok(pageChanges() > before);

  popup.close();
  await settle();
  assert.equal(screencast.page, first);
  assert.equal(context.sessions[2].page, first);
});

test('follows a page by its index, and tells of a navigation on screen', async () => {
  const { context, first, screencast, pageChanges } = await setup();
  context.newPage('http://127.0.0.1:4100/second');
  await settle();

  await screencast.followIndex(0);
  assert.equal(screencast.page, first);
  await screencast.followIndex(5);
  assert.equal(screencast.page, first, 'an index past the open pages changes nothing');

  const before = pageChanges();
  first.navigate('http://127.0.0.1:4100/next');
  assert.equal(pageChanges(), before + 1);
});

test('sends input to the page on screen', async () => {
  const { context, screencast } = await setup();
  await screencast.start();

  await screencast.dispatch('Input.insertText', { text: 'x' });

  assert.deepEqual(context.sessions[0].sent.at(-1), ['Input.insertText', { text: 'x' }]);
});
