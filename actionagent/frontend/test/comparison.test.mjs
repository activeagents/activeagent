import assert from 'node:assert/strict';
import test from 'node:test';
import { bandRows, firstSortDirection, sortRows } from '../utils/comparison.mjs';

// Ranking for comparison tables: terciles by the column's better direction,
// fixed thresholds where the domain has them, missing values unranked.

const rows = [{ cost: 10.53 }, { cost: 4.71 }, { cost: 0.8 }, { cost: 0.19 }, { cost: 6.13 }, { cost: 3.84 }, { cost: null }];

test('terciles band by the better direction, with the missing value unranked', () => {
  assert.deepEqual(bandRows(rows, { key: 'cost', better: 'lower' }), ['poor', 'mid', 'good', 'good', 'poor', 'mid', 'none']);
  assert.deepEqual(bandRows(rows, { key: 'cost', better: 'higher' }), ['good', 'mid', 'poor', 'poor', 'good', 'mid', 'none']);
});

test('one row is good on its own and two rows split good and poor', () => {
  assert.deepEqual(bandRows([{ v: 1 }], { key: 'v' }), ['good']);
  assert.deepEqual(bandRows([{ v: 1 }, { v: 2 }], { key: 'v' }), ['poor', 'good']);
});

test('ties share the better band', () => {
  assert.deepEqual(bandRows([{ v: 3 }, { v: 3 }, { v: 1 }], { key: 'v' }), ['good', 'good', 'poor']);
});

test('thresholds band on fixed cutoffs in either direction', () => {
  const column = { key: 'rate', band: 'threshold', thresholds: [0.85, 0.5] };
  assert.deepEqual(bandRows([{ rate: 0.9 }, { rate: 0.85 }, { rate: 0.6 }, { rate: 0.1 }, { rate: undefined }], column), ['good', 'good', 'mid', 'poor', 'none']);
  const lower = { key: 'ms', band: 'threshold', better: 'lower', thresholds: [500, 2000] };
  assert.deepEqual(bandRows([{ ms: 100 }, { ms: 1500 }, { ms: 9000 }], lower), ['good', 'mid', 'poor']);
});

test('a column that opts out of banding leaves every row unranked', () => {
  assert.deepEqual(bandRows(rows, { key: 'cost', band: 'none' }), rows.map(() => 'none'));
});

test('sorting puts missing values last whichever way, and is stable', () => {
  const sorted = sortRows(rows, { key: 'cost' }, 'ascending').map((row) => row.cost);
  assert.deepEqual(sorted, [0.19, 0.8, 3.84, 4.71, 6.13, 10.53, null]);
  assert.deepEqual(sortRows(rows, { key: 'cost' }, 'descending').map((row) => row.cost), [10.53, 6.13, 4.71, 3.84, 0.8, 0.19, null]);
  const tied = sortRows([{ v: 1, id: 'a' }, { v: 1, id: 'b' }], { key: 'v' }, 'descending').map((row) => row.id);
  assert.deepEqual(tied, ['a', 'b']);
});

test('text columns sort alphabetically and open ascending; numbers open by their better direction', () => {
  const names = sortRows([{ name: 'muse' }, { name: 'Astra' }, { name: '' }], { key: 'name', kind: 'text' }, 'ascending').map((row) => row.name);
  assert.deepEqual(names, ['Astra', 'muse', '']);
  assert.equal(firstSortDirection({ kind: 'text' }), 'ascending');
  assert.equal(firstSortDirection({ better: 'higher' }), 'descending');
  assert.equal(firstSortDirection({ better: 'lower' }), 'ascending');
});
