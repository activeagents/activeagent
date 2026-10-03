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

test('the app itself is always reachable', async () => {
  const rules = policy();
  assert.ok(await rules.allows('http://127.0.0.1:3000/assets/app.js'));
  assert.ok(await rules.allows('http://127.0.0.1:3000/', { topLevelNavigation: true }));
  assert.ok(await rules.allows('ws://127.0.0.1:3000/cable'));
});

test('a top-level navigation anywhere else is refused', async () => {
  const rules = policy({ 'cdn.example.com': ['93.184.216.34'] });
  assert.ok(!(await rules.allows('https://cdn.example.com/', { topLevelNavigation: true })));
  assert.ok(!(await rules.allows('data:text/html,hi', { topLevelNavigation: true })));
  assert.ok(await rules.allows('about:blank', { topLevelNavigation: true }));
});

test('a page may load public resources, but nothing on a private or local address', async () => {
  const rules = policy({
    'cdn.example.com': ['93.184.216.34'],
    'rebound.example.com': ['93.184.216.34', '127.0.0.1'],
    'metadata.example.com': ['169.254.169.254'],
  });

  assert.ok(await rules.allows('https://cdn.example.com/lib.js'));
  assert.ok(await rules.allows('data:image/png;base64,AAAA'));
  for (const url of [
    'http://127.0.0.1:5432/', 'http://localhost:3000/', 'http://[::1]:3000/', 'http://10.0.0.1/', 'http://169.254.169.254/',
    'https://rebound.example.com/', 'https://metadata.example.com/', 'http://app.localhost/', 'ws://127.0.0.1:9222/devtools',
  ]) {
    assert.ok(!(await rules.allows(url)), url);
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

  await rules.allows('https://cdn.example.com/a.js');
  await rules.allows('https://cdn.example.com/b.js');
  assert.equal(lookups, 1);
});
