import assert from 'node:assert/strict';
import test from 'node:test';

import { fetchTelemetryKey } from '../utils/telemetryKey.mjs';

function api(status, body) {
  const calls = [];
  const request = async (path, init) => {
    calls.push({ path, init });
    return { ok: status >= 200 && status < 300, status, json: async () => body };
  };
  request.calls = calls;
  return request;
}

test('reads the key from its own endpoint, bypassing the HTTP cache', async () => {
  const request = api(200, { telemetry_api_key: 'tk_live_0123456789' });

  assert.equal(await fetchTelemetryKey(request), 'tk_live_0123456789');
  assert.deepEqual(request.calls, [{ path: '/api/telemetry_key', init: { cache: 'no-store' } }]);
});

test('is null when the owner has no key', async () => {
  assert.equal(await fetchTelemetryKey(api(200, { telemetry_api_key: null })), null);
});

test('throws when the key cannot be read', async () => {
  await assert.rejects(fetchTelemetryKey(api(401, { error: 'No account' })), /HTTP 401/);
});
