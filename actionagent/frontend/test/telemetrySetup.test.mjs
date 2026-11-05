import assert from 'node:assert/strict';
import test from 'node:test';

import { telemetryConfigSnippet, telemetryEndpoint } from '../utils/telemetrySetup.mjs';

test('a multi-tenant platform collects at /v1/traces on its own host', () => {
  assert.equal(
    telemetryEndpoint({ origin: 'https://activeagents.ai', mountPath: '/dashboard', multiTenant: true }),
    'https://activeagents.ai/v1/traces',
  );
});

test('a self-hosted dashboard takes traces at the engine mount', () => {
  assert.equal(
    telemetryEndpoint({ origin: 'http://localhost:3000', mountPath: '/activeagents/', multiTenant: false }),
    'http://localhost:3000/activeagents/api/traces',
  );
  assert.equal(
    telemetryEndpoint({ origin: 'http://localhost:3000', mountPath: '', multiTenant: false }),
    'http://localhost:3000/api/traces',
  );
});

test('the snippet reads the key from the environment', () => {
  const snippet = telemetryConfigSnippet('https://activeagents.ai/v1/traces');
  assert.match(snippet, /^telemetry:\n  enabled: true\n/);
  assert.match(snippet, /endpoint: https:\/\/activeagents\.ai\/v1\/traces/);
  assert.match(snippet, /api_key: <%= ENV\["ACTIVEAGENTS_API_KEY"\] %>/);
});
