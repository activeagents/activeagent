import assert from 'node:assert/strict';
import test from 'node:test';

import { liveUpdate } from '../utils/liveUpdates.mjs';

test('reads the type, id and status of an update', () => {
  assert.deepEqual(liveUpdate({ type: 'run_complete', id: 'run-1', status: 'completed' }), {
    type: 'run_complete',
    id: 'run-1',
    status: 'completed',
  });
});

test('drops anything else a message carries', () => {
  const update = liveUpdate({ type: 'update', id: 7, status: 'complete', run: { output: 'secret' } });

  assert.deepEqual(update, { type: 'update', id: 7, status: 'complete' });
});

test('fills a missing id or status with null', () => {
  assert.deepEqual(liveUpdate({ type: 'status_update' }), { type: 'status_update', id: null, status: null });
});

test('is null for a message that is not an update', () => {
  assert.equal(liveUpdate(null), null);
  assert.equal(liveUpdate('ping'), null);
  assert.equal(liveUpdate({ id: 1, status: 'complete' }), null);
});
