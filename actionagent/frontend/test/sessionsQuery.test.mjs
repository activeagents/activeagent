import assert from 'node:assert/strict';
import test from 'node:test';

import { EMPTY_FILTERS, cleanFilters, filtersFromSearch, filtersSearch, hasFilters, sessionsPath } from '../utils/sessionsQuery.mjs';

const localDay = (year, month, day) => new Date(year, month - 1, day).toISOString();

test('with no filters the query asks for the first page only', () => {
  assert.equal(sessionsPath(), '/api/sessions?per_page=25');
  assert.equal(sessionsPath(EMPTY_FILTERS, { perPage: 50 }), '/api/sessions?per_page=50');
});

test('each filter becomes its server parameter', () => {
  const path = sessionsPath({ agentId: '12', user: 'me', source: 'evaluation', outcome: 'failed' });

  assert.equal(path, '/api/sessions?agent_id=12&user=me&source=evaluation&outcome=failed&per_page=25');
});

test('dates are local days, and the to date includes its whole day', () => {
  const params = new URLSearchParams(sessionsPath({ from: '2026-09-01', to: '2026-09-30' }).split('?')[1]);

  assert.equal(params.get('from'), localDay(2026, 9, 1));
  assert.equal(params.get('to'), localDay(2026, 10, 1));
});

test('the next page carries the previous page cursor', () => {
  const params = new URLSearchParams(sessionsPath({ source: 'agent' }, { before: '2026-09-01T12:00:00.000000Z|recording|4' }).split('?')[1]);

  assert.equal(params.get('before'), '2026-09-01T12:00:00.000000Z|recording|4');
  assert.equal(params.get('source'), 'agent');
});

test('unknown or malformed values are dropped rather than sent', () => {
  assert.deepEqual(cleanFilters({ agentId: '12; drop', user: 'someone', source: 'browser', outcome: 'declined', from: '9/1/2026', to: '2026-09-01', extra: 'x' }),
    { ...EMPTY_FILTERS, to: '2026-09-01' });
  assert.equal(sessionsPath({ source: 'browser' }), '/api/sessions?per_page=25');
});

test('filters round-trip through the page URL', () => {
  const filters = { agentId: '3', user: 'me', source: 'dashboard', outcome: 'passed', from: '2026-09-01', to: '2026-09-02' };
  const search = filtersSearch(filters);

  assert.equal(search, '?agent_id=3&user=me&source=dashboard&outcome=passed&from=2026-09-01&to=2026-09-02');
  assert.deepEqual(filtersFromSearch(search), filters);
  assert.equal(filtersSearch(EMPTY_FILTERS), '');
  assert.deepEqual(filtersFromSearch('?source=nope&page=2'), EMPTY_FILTERS);
});

test('knows whether any filter is set', () => {
  assert.equal(hasFilters(EMPTY_FILTERS), false);
  assert.equal(hasFilters({ outcome: 'failed' }), true);
  assert.equal(hasFilters({ outcome: 'bogus' }), false);
});
