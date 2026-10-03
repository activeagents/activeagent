import assert from 'node:assert/strict';
import test from 'node:test';
import { effectiveSourceLabel, keyAuditLine, providerKeysPath } from '../utils/providerKeys.mjs';

test('each effective source the API reports has a badge', () => {
  assert.deepEqual(
    ['personal', 'host_resolver', 'organization', 'config', 'none'].map(effectiveSourceLabel),
    ['Your key', 'Organization key', 'Organization key', 'Platform default', 'Not configured'],
  );
  assert.equal(effectiveSourceLabel(null), null, 'a connection credential reports no source');
  assert.equal(effectiveSourceLabel('somewhere'), null);
});

test('the organization scope keeps the bare endpoint unless named', () => {
  assert.equal(providerKeysPath('/api/provider_keys', undefined), '/api/provider_keys');
  assert.equal(providerKeysPath('/api/provider_keys', 'organization'), '/api/provider_keys?scope=organization');
  assert.equal(providerKeysPath('/api/provider_keys/openai', 'personal'), '/api/provider_keys/openai?scope=personal');
});

test('the audit line says who set a key and when, as far as either is known', () => {
  const date = () => 'Oct 2';
  assert.equal(keyAuditLine({ set_by: { id: 1, name: 'Grace' }, updated_at: '2026-10-02T10:00:00Z' }, date), 'Set by Grace · updated Oct 2');
  assert.equal(keyAuditLine({ set_by: null, updated_at: '2026-10-02T10:00:00Z' }, date), 'Updated Oct 2');
  assert.equal(keyAuditLine({ set_by: { id: 1, name: 'Grace' } }, date), 'Set by Grace');
  assert.equal(keyAuditLine({}, date), null);
});
