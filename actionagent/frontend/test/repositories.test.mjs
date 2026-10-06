import assert from 'node:assert/strict';
import test from 'node:test';

import { filterRepositories, toggleRepository } from '../utils/repositories.mjs';

const repositories = [
  { id: 1, full_name: 'acme/web', private: true },
  { id: 2, full_name: 'acme/API', private: false },
  { id: 3, full_name: 'other/tool', private: false },
];

const names = (list) => list.map((repository) => repository.full_name);

test('the filter matches anywhere in the full name, ignoring case', () => {
  assert.deepEqual(names(filterRepositories(repositories, 'ACME')), ['acme/web', 'acme/API']);
  assert.deepEqual(names(filterRepositories(repositories, 'api')), ['acme/API']);
  assert.deepEqual(names(filterRepositories(repositories, 'r/t')), ['other/tool']);
});

test('an empty filter keeps every repository, in order', () => {
  assert.deepEqual(names(filterRepositories(repositories, '')), ['acme/web', 'acme/API', 'other/tool']);
  assert.deepEqual(names(filterRepositories(repositories)), ['acme/web', 'acme/API', 'other/tool']);
});

test('a filter nothing matches, or no list, leaves nothing', () => {
  assert.deepEqual(filterRepositories(repositories, 'zzz'), []);
  assert.deepEqual(filterRepositories(null, 'acme'), []);
});

test('toggling adds a missing name and removes a present one without touching the original', () => {
  const selection = new Set(['acme/web']);
  assert.deepEqual([...toggleRepository(selection, 'acme/API')], ['acme/web', 'acme/API']);
  assert.deepEqual([...toggleRepository(selection, 'acme/web')], []);
  assert.deepEqual([...selection], ['acme/web']);
});
