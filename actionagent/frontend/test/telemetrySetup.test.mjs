import assert from 'node:assert/strict';
import test from 'node:test';

import { rubyLlmTelemetrySnippet, telemetryConfigSnippet, telemetryEndpoint } from '../utils/telemetrySetup.mjs';

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

test('the snippet sits under an environment and reads the key from the environment', () => {
  const snippet = telemetryConfigSnippet('https://activeagents.ai/v1/traces');
  assert.match(snippet, /^production:\n  telemetry:\n    enabled: true\n/);
  assert.match(snippet, /endpoint: https:\/\/activeagents\.ai\/v1\/traces/);
  assert.match(snippet, /api_key: <%= ENV\["ACTIVEAGENTS_API_KEY"\] %>/);
});

test('the RubyLLM setup adds the adapter gem and subscribes it to this endpoint', () => {
  const snippet = rubyLlmTelemetrySnippet('http://localhost:3000/activeagents/api/traces');
  assert.match(snippet, /# Gemfile\ngem "activeagents-telemetry-ruby_llm"\n/);
  assert.match(snippet, /# config\/initializers\/ruby_llm_telemetry\.rb\n/);
  assert.match(snippet, /config\.endpoint = "http:\/\/localhost:3000\/activeagents\/api\/traces"/);
  assert.match(snippet, /config\.api_key  = ENV\["ACTIVEAGENTS_API_KEY"\]/);
  assert.match(snippet, /ActiveAgents::Telemetry::RubyLLM\.subscribe!$/);
});
