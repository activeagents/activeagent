import assert from 'node:assert/strict';
import test from 'node:test';

import { appStorageState, exportStorageState, StorageStateError } from '../lib/storage-state.mjs';

const APP = 'http://127.0.0.1:3000';

const state = {
  cookies: [
    { name: '_shop_session', value: 'abc', domain: '127.0.0.1', path: '/', expires: -1, httpOnly: true, secure: false, sameSite: 'Lax' },
    { name: 'tracker', value: 'x', domain: '.ads.example', path: '/', expires: 1, httpOnly: false, secure: true, sameSite: 'None' },
  ],
  origins: [
    { origin: APP, localStorage: [{ name: 'token', value: 'jwt' }] },
    { origin: 'https://ads.example', localStorage: [{ name: 'id', value: '1' }] },
  ],
};

test('keeps only the cookies and localStorage of the app', () => {
  const kept = appStorageState(state, APP);

  assert.deepEqual(kept.cookies.map((cookie) => cookie.name), ['_shop_session']);
  assert.deepEqual(kept.origins, [{ origin: APP, localStorage: [{ name: 'token', value: 'jwt' }] }]);
});

test('keeps a cookie set for a parent domain of the app host', () => {
  const kept = appStorageState({ cookies: [{ name: 'a', value: 'b', domain: '.shop.test', path: '/' }], origins: [] }, 'http://app.shop.test:8080');

  assert.equal(kept.cookies.length, 1);
  assert.equal(kept.cookies[0].sameSite, 'Lax');
  assert.equal(kept.cookies[0].expires, -1);
});

test('refuses a malformed state', () => {
  assert.throws(() => appStorageState([], APP), StorageStateError);
  assert.throws(() => appStorageState({ cookies: [{ name: 'a' }] }, APP), StorageStateError);
  assert.throws(() => appStorageState({ origins: [{ origin: APP, localStorage: [{ name: 1 }] }] }, APP), StorageStateError);
});

test('exports the context state limited to the app', async () => {
  const context = { storageState: async () => state };

  const exported = await exportStorageState(context, APP);

  assert.deepEqual(exported.cookies.map((cookie) => cookie.name), ['_shop_session']);
  assert.equal(exported.origins.length, 1);
});
