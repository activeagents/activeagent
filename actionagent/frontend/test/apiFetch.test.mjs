import assert from 'node:assert/strict';
import test from 'node:test';

import { installApiFetch, resolveApiRequest } from '../utils/apiFetch.mjs';

// Every dashboard request goes through one fetch shim. These pin that it
// puts "/api/" calls on the engine's mount and that every mutating call
// carries the CSRF token the API now verifies.

const origin = 'https://host.test';
const options = { base: '/activeagents', csrfToken: 'tok', origin };

test('rewrites /api/ paths onto the mount', () => {
  const [input] = resolveApiRequest('/api/agents?q=x', undefined, options);
  assert.equal(input, '/activeagents/api/agents?q=x');
});

test('passes other requests through untouched', () => {
  assert.equal(resolveApiRequest('/assets/app.js', undefined, options), null);
  assert.equal(resolveApiRequest('https://openrouter.ai/api/v1/models', undefined, options), null);
  assert.equal(resolveApiRequest(new Request('https://elsewhere.test/api/agents'), undefined, options), null);
});

test('reads carry no token', () => {
  const [, init] = resolveApiRequest('/api/agents', undefined, options);
  assert.equal(init, undefined);
});

for (const method of ['POST', 'PUT', 'PATCH', 'DELETE', 'post']) {
  test(`${method} carries the CSRF token beside its own headers`, () => {
    const [, init] = resolveApiRequest('/api/agents/1', {
      method, headers: { 'Content-Type': 'application/json' }, body: '{}',
    }, options);
    assert.equal(init.headers.get('X-CSRF-Token'), 'tok');
    assert.equal(init.headers.get('Content-Type'), 'application/json');
    assert.equal(init.body, '{}');
  });
}

test('a token the caller set is left alone', () => {
  const [, init] = resolveApiRequest('/api/agents', { method: 'POST', headers: { 'X-CSRF-Token': 'own' } }, options);
  assert.equal(init.headers.get('X-CSRF-Token'), 'own');
});

test('a mutating Request object is rewritten and gets the token', () => {
  const request = new Request(`${origin}/api/agents`, { method: 'DELETE', headers: { Accept: 'application/json' } });
  const [input, init] = resolveApiRequest(request, undefined, options);
  assert.equal(input.url, `${origin}/activeagents/api/agents`);
  assert.equal(init.headers.get('X-CSRF-Token'), 'tok');
  assert.equal(init.headers.get('Accept'), 'application/json');
});

test('a root mount still attaches the token', () => {
  const calls = [];
  const target = { fetch: (...args) => calls.push(args), location: { origin } };
  globalThis.document = { querySelector: () => ({ content: 'meta-token' }) };
  try {
    installApiFetch('/', target);
    target.fetch('/api/agents', { method: 'POST' });
  } finally {
    delete globalThis.document;
  }
  const [[input, init]] = calls;
  assert.equal(input, '/api/agents');
  assert.equal(init.headers.get('X-CSRF-Token'), 'meta-token');
});
