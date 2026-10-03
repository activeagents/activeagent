import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';

import { NavigationGuard } from '../lib/navigation-guard.mjs';
import { NetworkPolicy } from '../lib/network-policy.mjs';

const APP = 'http://127.0.0.1:3000';

class FakeFrame {
  constructor(url) {
    this.address = url;
  }

  url() {
    return this.address;
  }
}

class FakePage extends EventEmitter {
  constructor(context, url = 'about:blank') {
    super();
    this.context = context;
    this.frame = new FakeFrame(url);
    this.closed = false;
  }

  mainFrame() {
    return this.frame;
  }

  url() {
    return this.frame.url();
  }

  navigate(url, frame = this.frame) {
    frame.address = url;
    this.emit('framenavigated', frame);
  }

  async close() {
    this.closed = true;
    this.context.open.delete(this);
    this.emit('close');
  }
}

class FakeContext extends EventEmitter {
  constructor() {
    super();
    this.open = new Set();
  }

  pages() {
    return [...this.open];
  }

  async newPage() {
    const page = new FakePage(this);
    this.open.add(page);
    this.emit('page', page);
    return page;
  }
}

async function watched() {
  const context = new FakeContext();
  const first = await context.newPage();
  const logged = [];
  const guard = new NavigationGuard({ policy: new NetworkPolicy({ appOrigin: APP }), log: (message) => logged.push(message) });
  guard.attach(context);
  return { context, first, guard, logged };
}

test('pages on the app, blank pages, error pages and frames elsewhere are left alone', async () => {
  const { first, guard } = await watched();

  first.navigate(`${APP}/orders`);
  first.navigate('chrome-error://chromewebdata/');
  first.navigate(`${APP}/`);
  first.navigate('https://ads.example.com/frame', new FakeFrame('https://ads.example.com/frame'));

  assert.equal(guard.escapes, 0);
  assert.equal(first.closed, false);
  assert.equal(await guard.refusalSince(0), null);
});

test('a page that lands on another origin is closed, with a blank page left in its place', async () => {
  const { context, first, guard, logged } = await watched();

  first.navigate('https://sso.example.com/authorize?state=abc');
  const refusal = await guard.refusalSince(0);

  assert.equal(guard.escapes, 1);
  assert.equal(first.closed, true);
  assert.equal(context.pages().length, 1);
  assert.equal(context.pages()[0].url(), 'about:blank');
  assert.match(refusal, /^A page was redirected to https:\/\/sso\.example\.com, outside the sandbox app, and was closed\./);
  assert.ok(!refusal.includes('state=abc'), 'only the origin is named');
  assert.deepEqual(logged, ['closed a page that was redirected to https://sso.example.com']);
});

test('another tab escaping closes only that tab', async () => {
  const { context, first, guard } = await watched();
  const second = await context.newPage();

  second.navigate('https://elsewhere.example.com/');
  await guard.refusalSince(0);

  assert.equal(second.closed, true);
  assert.deepEqual(context.pages(), [first]);
});

test('an escape is reported to the calls it happened during, not to later ones', async () => {
  const { first, guard } = await watched();
  const before = guard.escapes;

  first.navigate('https://elsewhere.example.com/');

  assert.match(await guard.refusalSince(before), /redirected to https:\/\/elsewhere\.example\.com/);
  assert.equal(await guard.refusalSince(guard.escapes), null);
});
