import assert from 'node:assert/strict';
import test from 'node:test';

import {
  confirmRequest, confirmTextMatches, currentConfirm, requestConfirm, settleConfirm, subscribeConfirm,
} from '../utils/confirm.mjs';

// The dashboard's own confirmation, which replaces window.confirm.

test('a request gets defaults, and empty requireText means no typing', () => {
  assert.deepEqual(confirmRequest({}), {
    title: 'Are you sure?', message: '', confirmLabel: 'Confirm', cancelLabel: 'Cancel', danger: false, requireText: null,
  });
  assert.equal(confirmRequest({ requireText: '' }).requireText, null);
  assert.equal(confirmRequest({ requireText: 42 }).requireText, '42');
  assert.equal(confirmRequest({ danger: 1 }).danger, true);
});

test('requestConfirm resolves with the answer and clears the open request', async () => {
  const seen = [];
  const unsubscribe = subscribeConfirm((request) => seen.push(request && request.title));

  const yes = requestConfirm({ title: 'Delete docsage?' });
  assert.equal(currentConfirm().title, 'Delete docsage?');
  settleConfirm(true);
  assert.equal(await yes, true);
  assert.equal(currentConfirm(), null);

  const no = requestConfirm({ title: 'Stop this sandbox?' });
  settleConfirm(false);
  assert.equal(await no, false);

  unsubscribe();
  assert.deepEqual(seen, ['Delete docsage?', null, 'Stop this sandbox?', null]);
});

test('a second request answers the first with false', async () => {
  const first = requestConfirm({ title: 'First' });
  const second = requestConfirm({ title: 'Second' });
  assert.equal(await first, false);
  assert.equal(currentConfirm().title, 'Second');
  settleConfirm(true);
  assert.equal(await second, true);
});

test('settling with nothing open does nothing', () => {
  assert.doesNotThrow(() => settleConfirm(true));
  assert.equal(currentConfirm(), null);
});

test('typed text must match requireText exactly', () => {
  const request = confirmRequest({ requireText: 'TonsOfFun/docsage' });
  assert.equal(confirmTextMatches(request, ''), false);
  assert.equal(confirmTextMatches(request, 'tonsoffun/docsage'), false);
  assert.equal(confirmTextMatches(request, 'TonsOfFun/docsage '), false);
  assert.equal(confirmTextMatches(request, 'TonsOfFun/docsage'), true);
  assert.equal(confirmTextMatches(confirmRequest({}), ''), true);
});
