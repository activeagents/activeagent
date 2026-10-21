import assert from 'node:assert/strict';
import test from 'node:test';

import { ClientTokens, MAX_LABEL_LENGTH } from '../lib/client-tokens.mjs';

test('a minted token matches with its label until it is revoked', () => {
  const tokens = new ClientTokens();
  const minted = tokens.mint({ label: 'Claude Code · turn 3\n' });

  assert.match(minted.token, /^cl_[A-Za-z0-9_-]{43}$/);
  assert.match(minted.id, /^[0-9a-f-]{36}$/);
  assert.equal(minted.label, 'Claude Code · turn 3');
  assert.deepEqual(tokens.match(minted.token), { id: minted.id, label: 'Claude Code · turn 3' });
  assert.equal(tokens.match(`${minted.token}x`), null);
  assert.equal(tokens.match('browser-token'), null, 'only client tokens are matched here');
  assert.equal(tokens.match(undefined), null);

  assert.equal(tokens.revoke(minted.id), true);
  assert.equal(tokens.match(minted.token), null);
  assert.equal(tokens.revoke(minted.id), false);
});

test('labels are cleaned and bounded, and a blank one is none', () => {
  const tokens = new ClientTokens();
  assert.equal(tokens.mint({ label: 'x'.repeat(500) }).label.length, MAX_LABEL_LENGTH);
  assert.equal(tokens.mint({ label: '  \u0007 ' }).label, null);
  assert.equal(tokens.mint({ label: 42 }).label, null);
  assert.equal(tokens.mint().label, null);
});

test('tokens expire, and only so many may be live at once', () => {
  let now = 1_000;
  const tokens = new ClientTokens({ max: 2, ttlMs: 100, now: () => now });
  const first = tokens.mint();
  tokens.mint();
  assert.throws(() => tokens.mint(), (error) => error.status === 429);

  now += 100;
  assert.equal(tokens.match(first.token), null, 'an expired token no longer matches');
  assert.equal(tokens.size, 0);
  assert.ok(tokens.mint());
});
