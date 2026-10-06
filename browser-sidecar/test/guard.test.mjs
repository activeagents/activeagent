import assert from 'node:assert/strict';
import test from 'node:test';

import { acceptedHosts, liveRefusal, refusal } from '../lib/guard.mjs';

const TOKEN = 'browser-token-0123456789abcdef0123456789';
const hosts = acceptedHosts('127.0.0.1', 4321);

function request(headers) {
  return { headers };
}

test('accepts the loopback names with the port, and extra hosts as given', () => {
  assert.deepEqual([...hosts].sort(), ['127.0.0.1:4321', '[::1]:4321', 'localhost:4321']);
  assert.ok(acceptedHosts('0.0.0.0', 8931, ['Browser:8931']).has('browser:8931'));
  assert.ok(!acceptedHosts('0.0.0.0', 8931).has('0.0.0.0:8931'));
  assert.ok(acceptedHosts('10.0.0.5', 8931).has('10.0.0.5:8931'));
});

test('lets a request with an accepted host, no origin and the token through', () => {
  assert.equal(refusal(request({ host: '127.0.0.1:4321', authorization: `Bearer ${TOKEN}` }), { token: TOKEN, hosts }), null);
  assert.equal(refusal(request({ host: 'LOCALHOST:4321', authorization: `bearer ${TOKEN}` }), { token: TOKEN, hosts }), null);
});

test('refuses a foreign or missing Host before looking at the token', () => {
  for (const host of ['evil.test:4321', '127.0.0.1:9999', '127.0.0.1', undefined]) {
    assert.deepEqual(refusal(request({ host, authorization: `Bearer ${TOKEN}` }), { token: TOKEN, hosts }), {
      status: 403,
      message: 'Host not allowed',
    });
  }
});

test('refuses any Origin a page could send, unless allowed', () => {
  for (const origin of ['http://127.0.0.1:3000', 'null', 'http://127.0.0.1:4321']) {
    const headers = { host: '127.0.0.1:4321', origin, authorization: `Bearer ${TOKEN}` };
    assert.equal(refusal(request(headers), { token: TOKEN, hosts }).message, 'Origin not allowed');
  }

  const headers = { host: '127.0.0.1:4321', origin: 'https://dashboard.test', authorization: `Bearer ${TOKEN}` };
  assert.equal(refusal(request(headers), { token: TOKEN, hosts, origins: new Set(['https://dashboard.test']) }), null);
});

test('refuses a missing, malformed or wrong token', () => {
  for (const authorization of [undefined, '', TOKEN, `Basic ${TOKEN}`, `Bearer ${TOKEN}x`, 'Bearer', `Bearer ${TOKEN} extra`]) {
    assert.deepEqual(refusal(request({ host: '127.0.0.1:4321', authorization }), { token: TOKEN, hosts }), {
      status: 401,
      message: 'Missing or invalid bearer token',
    });
  }
});

test("the live view's upgrade needs an accepted Host, an allowed Origin and no query, and no token", () => {
  const origins = new Set(['http://localhost:3000']);
  const live = (headers, url = '/live') => liveRefusal({ headers, url }, { hosts, origins });

  assert.equal(live({ host: '127.0.0.1:4321', origin: 'http://localhost:3000' }), null);
  assert.equal(live({ host: '127.0.0.1:4321', origin: 'HTTP://LOCALHOST:3000' }), null, 'origins compare without case');
  assert.equal(live({ host: 'attacker.test:4321', origin: 'http://localhost:3000' }).message, 'Host not allowed');
  assert.equal(live({ host: '127.0.0.1:4321' }).message, 'Origin not allowed', 'a request without an Origin did not come from the dashboard');
  assert.equal(live({ host: '127.0.0.1:4321', origin: 'http://127.0.0.1:4100' }).message, 'Origin not allowed', 'the sandbox app is not the dashboard');
  assert.equal(live({ host: '127.0.0.1:4321', origin: 'http://localhost:3000' }, '/live?ticket=abc').status, 400);
});
