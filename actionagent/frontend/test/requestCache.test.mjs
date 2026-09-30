import assert from 'node:assert/strict';
import test from 'node:test';
import { createRequestCache } from '../utils/requestCache.mjs';

// The model pickers load each provider's list through this cache, so pickers
// mounting together or again soon after share one request per provider.

function counting(results) {
  const calls = [];
  const load = (key) => {
    calls.push(key);
    const result = results(key, calls.length);
    return result instanceof Error ? Promise.reject(result) : Promise.resolve(result);
  };
  return { load, calls };
}

test('callers asking while a request is in flight share it', async () => {
  const { load, calls } = counting((key) => [`${key}-model`]);
  const cached = createRequestCache(load, { ttlMs: 1000 });

  const [first, second] = await Promise.all([cached('openai'), cached('openai')]);

  assert.deepEqual(calls, ['openai']);
  assert.equal(first, second);
});

test('each key loads on its own', async () => {
  const { load, calls } = counting((key) => [key]);
  const cached = createRequestCache(load, { ttlMs: 1000 });

  await Promise.all([cached('openai'), cached('ollama')]);

  assert.deepEqual(calls, ['openai', 'ollama']);
});

test('a kept result is reused until it expires', async () => {
  let clock = 0;
  const { load, calls } = counting((_key, n) => [`call-${n}`]);
  const cached = createRequestCache(load, { ttlMs: 1000, now: () => clock });

  assert.deepEqual(await cached('openai'), ['call-1']);
  clock = 999;
  assert.deepEqual(await cached('openai'), ['call-1']);
  clock = 1000;
  assert.deepEqual(await cached('openai'), ['call-2']);
  assert.equal(calls.length, 2);
});

test('a result the cache does not keep is loaded again', async () => {
  const { load, calls } = counting((_key, n) => (n === 1 ? null : ['gpt-5']));
  const cached = createRequestCache(load, { ttlMs: 1000, keep: (value) => value !== null });

  assert.equal(await cached('openai'), null);
  assert.deepEqual(await cached('openai'), ['gpt-5']);
  assert.deepEqual(await cached('openai'), ['gpt-5']);
  assert.equal(calls.length, 2);
});

test('a rejected load is not kept', async () => {
  const { load, calls } = counting((_key, n) => (n === 1 ? new Error('offline') : ['gpt-5']));
  const cached = createRequestCache(load, { ttlMs: 1000 });

  await assert.rejects(cached('openai'), /offline/);
  assert.deepEqual(await cached('openai'), ['gpt-5']);
  assert.equal(calls.length, 2);
});

test('clearing forgets every kept result', async () => {
  const { load, calls } = counting((_key, n) => [`call-${n}`]);
  const cached = createRequestCache(load, { ttlMs: 1000 });

  await cached('openai');
  cached.clear();

  assert.deepEqual(await cached('openai'), ['call-2']);
  assert.equal(calls.length, 2);
});

// A request cleared while in flight lands after the request that replaced
// it started, and must leave that request's entry alone.
function replacedWhileInFlight(settleStale) {
  const settles = [];
  const calls = [];
  const load = (key) => {
    calls.push(key);
    return new Promise((resolve, reject) => settles.push({ resolve, reject }));
  };
  const cached = createRequestCache(load, { ttlMs: 1000, keep: (value) => value !== null });

  const stale = cached('openai');
  cached.clear();
  const fresh = cached('openai');
  settleStale(settles[0]);
  return { cached, calls, stale, fresh, settles };
}

test('a request cleared while in flight keeps its replacement shared when it lands unkept', async () => {
  const { cached, calls, stale, fresh, settles } = replacedWhileInFlight(({ resolve }) => resolve(null));
  assert.equal(await stale, null);

  const later = cached('openai');
  settles[1].resolve(['fresh']);

  assert.equal(later, fresh);
  assert.deepEqual(await later, ['fresh']);
  assert.equal(calls.length, 2);
});

test('a request cleared while in flight keeps its replacement shared when it rejects', async () => {
  const { cached, calls, stale, fresh, settles } = replacedWhileInFlight(({ reject }) => reject(new Error('offline')));
  await assert.rejects(stale, /offline/);

  const later = cached('openai');
  settles[1].resolve(['fresh']);

  assert.equal(later, fresh);
  assert.deepEqual(await later, ['fresh']);
  assert.equal(calls.length, 2);
});
