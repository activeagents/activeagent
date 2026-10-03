import assert from 'node:assert/strict';
import test from 'node:test';

import { createRequestGate } from '../utils/requestGate.mjs';

test('a request is current until the next one starts', () => {
  const gate = createRequestGate();
  const first = gate.next();

  assert.equal(first(), true);
  const second = gate.next();
  assert.equal(first(), false);
  assert.equal(second(), true);
});

test('a request joined with latest() is dropped once a newer request starts', () => {
  const gate = createRequestGate();
  gate.next();
  const loadMore = gate.latest();

  assert.equal(loadMore(), true, 'nothing newer has started');
  gate.next();
  assert.equal(loadMore(), false, 'the filters changed while the page loaded');
});

test('latest() does not supersede the request it joins', () => {
  const gate = createRequestGate();
  const list = gate.next();
  gate.latest();

  assert.equal(list(), true);
});

test('gates are independent', () => {
  const one = createRequestGate();
  const other = createRequestGate();
  const check = one.next();

  other.next();
  assert.equal(check(), true);
});
