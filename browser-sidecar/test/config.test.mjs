import assert from 'node:assert/strict';
import test from 'node:test';

import { ConfigError, parseConfig } from '../lib/config.mjs';

const TOKEN = 'a'.repeat(40);
const base = { token: TOKEN, app_url: 'http://127.0.0.1:3000/some/path' };

test('reads a minimal configuration with its defaults', () => {
  const config = parseConfig(JSON.stringify(base));

  assert.equal(config.token, TOKEN);
  assert.equal(config.appOrigin, 'http://127.0.0.1:3000');
  assert.equal(config.mode, 'headless');
  assert.deepEqual(config.capabilities, []);
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.port, 0);
  assert.equal(config.workdir, null);
  assert.equal(config.stopAt, null);
  assert.equal(config.recording, null);
  assert.equal(config.chromiumSandbox, true);
});

test('reads the recording and the stop time', () => {
  const config = parseConfig({
    ...base,
    mode: 'headed',
    capabilities: ['testing', 'testing'],
    stop_at: '2026-01-01T00:00:00Z',
    recording: { url: 'http://127.0.0.1:3000/activeagents/api/session_recordings/7/events', token: `aarec_${'b'.repeat(32)}` },
  });

  assert.equal(config.mode, 'headed');
  assert.deepEqual(config.capabilities, ['testing']);
  assert.equal(config.stopAt, Date.parse('2026-01-01T00:00:00Z'));
  assert.equal(config.recording.batchEvents, 1000);
  assert.equal(config.recording.batchBytes, 1024 * 1024);
});

test('reads the live view, with its defaults', () => {
  assert.equal(parseConfig(base).live, null);

  const config = parseConfig({ ...base, live: { session_id: 'session-1', origins: ['http://localhost:3000/', 'HTTP://LOCALHOST:3000', 'https://dash.example'] } });
  assert.deepEqual(config.live, {
    sessionId: 'session-1',
    origins: ['http://localhost:3000', 'https://dash.example'],
    agentWaitMs: 20_000,
    releaseGraceMs: 10_000,
  });

  const tuned = parseConfig({ ...base, live: { session_id: 's', origins: ['http://localhost:3000'], agent_wait_ms: 0, release_grace_ms: 500 } });
  assert.equal(tuned.live.agentWaitMs, 0);
  assert.equal(tuned.live.releaseGraceMs, 500);
});

const invalid = {
  'not JSON': 'nope',
  'a short token': { ...base, token: 'short' },
  'a token with whitespace': { ...base, token: `${'a'.repeat(35)} bc` },
  'an app url that is not http': { ...base, app_url: 'file:///etc' },
  'an app url with credentials': { ...base, app_url: 'http://user:pass@127.0.0.1:3000' },
  'an unknown mode': { ...base, mode: 'kiosk' },
  'a capability that reaches outside the page': { ...base, capabilities: ['devtools'] },
  'a port out of range': { ...base, port: 70000 },
  'a recording without a token': { ...base, recording: { url: 'http://127.0.0.1:3000/events' } },
  'a non-boolean sandbox setting': { ...base, chromium_sandbox: 'no' },
  'a live view without its session': { ...base, live: { origins: ['http://localhost:3000'] } },
  'a live view without origins': { ...base, live: { session_id: 's', origins: [] } },
  'a live view origin with a path': { ...base, live: { session_id: 's', origins: ['http://localhost:3000/activeagents'] } },
  'a live view origin that is not http': { ...base, live: { session_id: 's', origins: ['file:///etc'] } },
  'an agent wait past the tool call timeout': { ...base, live: { session_id: 's', origins: ['http://localhost:3000'], agent_wait_ms: 60_000 } },
  'a zero grace period': { ...base, live: { session_id: 's', origins: ['http://localhost:3000'], release_grace_ms: 0 } },
};

for (const [name, input] of Object.entries(invalid)) {
  test(`refuses ${name}`, () => {
    assert.throws(() => parseConfig(typeof input === 'string' ? input : JSON.stringify(input)), ConfigError);
  });
}
