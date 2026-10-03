import assert from 'node:assert/strict';
import test from 'node:test';

import { isLocalName, isPrivateAddress, NetworkPolicy } from '../lib/network-policy.mjs';

const APP = 'http://127.0.0.1:3000';

function policy(addresses = {}) {
  return new NetworkPolicy({
    appOrigin: APP,
    resolve: async (hostname) => {
      if (!(hostname in addresses)) throw new Error('ENOTFOUND');
      return addresses[hostname];
    },
  });
}

test('classifies loopback, link-local and private addresses', () => {
  const internal = [
    '127.0.0.1', '127.8.9.10', '10.0.0.1', '172.16.0.1', '172.31.255.255', '192.168.1.1', '169.254.169.254', '100.64.0.1',
    '0.0.0.0', '224.0.0.1', '::', '::1', '[::1]', 'fe80::1', 'fd12:3456::1', 'ff02::1', '::ffff:127.0.0.1', '::ffff:a9fe:a9fe',
    '64:ff9b::10.0.0.1',
  ];
  const external = ['8.8.8.8', '172.32.0.1', '1.1.1.1', '2606:4700:4700::1111', '::ffff:8.8.8.8', 'example.com'];

  for (const address of internal) assert.ok(isPrivateAddress(address), address);
  for (const address of external) assert.ok(!isPrivateAddress(address), address);
});

test('names local hosts by name', () => {
  for (const name of ['localhost', 'app.localhost', 'printer.local', 'metadata.google.internal', 'LOCALHOST.']) assert.ok(isLocalName(name), name);
  assert.ok(!isLocalName('example.com'));
});

test('a navigation stays on the app, and a path is resolved against it', () => {
  const rules = policy();

  assert.deepEqual(rules.navigationTarget('/login?next=%2F'), { url: 'http://127.0.0.1:3000/login?next=%2F', refusal: null });
  assert.deepEqual(rules.navigationTarget('http://127.0.0.1:3000/'), { url: 'http://127.0.0.1:3000/', refusal: null });
  assert.equal(rules.navigationTarget('about:blank').refusal, null);

  for (const url of [
    'https://example.com', 'http://127.0.0.1:3001/', 'http://localhost:3000/', 'http://169.254.169.254/latest/meta-data',
    '//evil.test/x', 'file:///etc/passwd', 'chrome://settings', 'javascript:alert(1)', 'data:text/html,hi', 'example.com', '', undefined,
  ]) {
    assert.match(rules.navigationTarget(url).refusal ?? '', /may only open pages of the sandbox app at http:\/\/127\.0\.0\.1:3000/, String(url));
  }
});

test('the app itself is always reachable', () => {
  const rules = policy();
  assert.ok(rules.allows('http://127.0.0.1:3000/assets/app.js'));
  assert.ok(rules.allows('http://127.0.0.1:3000/', { topLevelNavigation: true }));
  assert.ok(rules.allows('ws://127.0.0.1:3000/cable'));
  assert.ok(!rules.allows('https://127.0.0.1:3000/', { topLevelNavigation: true }), 'the origin includes the scheme');
});

test('a top-level navigation anywhere else is refused', () => {
  const rules = policy();
  assert.ok(!rules.allows('https://cdn.example.com/', { topLevelNavigation: true }));
  assert.ok(!rules.allows('data:text/html,hi', { topLevelNavigation: true }));
  assert.ok(rules.allows('about:blank', { topLevelNavigation: true }));
});

test('a request is refused by URL when it names a private address or a local name', () => {
  const rules = policy();

  assert.ok(rules.allows('https://cdn.example.com/lib.js'), 'names are left to the connection check');
  assert.ok(rules.allows('data:image/png;base64,AAAA'));
  for (const url of [
    'http://127.0.0.1:5432/', 'http://localhost:3000/', 'http://[::1]:3000/', 'http://10.0.0.1/', 'http://169.254.169.254/',
    'http://app.localhost/', 'ws://127.0.0.1:9222/devtools',
  ]) {
    assert.ok(!rules.allows(url), url);
  }
});

test('a page is on the app when its origin is the app, or when it is not a web page', () => {
  const rules = policy();
  for (const url of ['http://127.0.0.1:3000/orders', 'about:blank', 'chrome-error://chromewebdata/']) assert.ok(rules.onApp(url), url);
  for (const url of ['https://example.com/', 'http://127.0.0.1:3001/', 'http://localhost:3000/']) assert.ok(!rules.onApp(url), url);
});

test('a connection goes to the app, or to a public address checked here', async () => {
  const rules = policy({
    'cdn.example.com': ['93.184.216.34'],
    'rebound.example.com': ['93.184.216.34', '127.0.0.1'],
    'metadata.example.com': ['169.254.169.254'],
  });

  assert.deepEqual(await rules.destination('127.0.0.1', 3000), { address: '127.0.0.1', refusal: null });
  assert.deepEqual(await rules.destination('cdn.example.com', 443), { address: '93.184.216.34', refusal: null });
  assert.deepEqual(await rules.destination('8.8.8.8', 53), { address: '8.8.8.8', refusal: null });

  const refusals = {
    '127.0.0.1:5432': 'is a loopback, link-local or private address',
    '[::1]:3000': 'is a loopback, link-local or private address',
    '169.254.169.254:80': 'is a loopback, link-local or private address',
    'localhost:3000': 'is a local host name',
    'rebound.example.com:443': 'resolves to a loopback, link-local or private address',
    'metadata.example.com:80': 'resolves to a loopback, link-local or private address',
    'nowhere.example.com:443': 'does not resolve',
  };
  for (const [target, reason] of Object.entries(refusals)) {
    const [, hostname, port] = /^(.+):(\d+)$/.exec(target);
    const { address, refusal } = await rules.destination(hostname, Number(port));
    assert.equal(address, null, target);
    assert.match(refusal, new RegExp(`${reason}$`), target);
  }
});

test('a resolution is reused while it is fresh', async () => {
  let lookups = 0;
  const rules = new NetworkPolicy({
    appOrigin: APP,
    resolve: async () => {
      lookups += 1;
      return ['93.184.216.34'];
    },
  });

  await rules.destination('cdn.example.com', 443);
  await rules.destination('cdn.example.com', 443);
  assert.equal(lookups, 1);
});
