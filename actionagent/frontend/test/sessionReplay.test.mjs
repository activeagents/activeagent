import assert from 'node:assert/strict';
import test from 'node:test';

import {
  ACTIONS_PAGE_SIZE,
  LIST_LOAD_ERROR,
  actionCountLabel,
  actionsPagePath,
  fetchAllActions,
  listLoadOutcome,
  normalizeAction,
} from '../utils/sessionReplay.mjs';

// --- the recordings list ----------------------------------------------------

test('an empty list stops loading so the empty state renders', () => {
  assert.deepEqual(listLoadOutcome({ ok: true, data: { recordings: [] } }), {
    recordings: [], selectId: null, stopLoading: true, error: null,
  });
});

test('a list response without a recordings array reads as empty', () => {
  const outcome = listLoadOutcome({ ok: true, data: {} });
  assert.equal(outcome.stopLoading, true);
  assert.equal(outcome.error, null);
  assert.deepEqual(outcome.recordings, []);
});

test('a failed list stops loading with an error', () => {
  assert.deepEqual(listLoadOutcome({ ok: false }), {
    recordings: [], selectId: null, stopLoading: true, error: LIST_LOAD_ERROR,
  });
});

test('a list selects its first recording and leaves loading to that load', () => {
  const recordings = [{ id: 7 }, { id: 3 }];
  assert.deepEqual(listLoadOutcome({ ok: true, data: { recordings } }), {
    recordings, selectId: 7, stopLoading: false, error: null,
  });
});

test('a recording already selected keeps the selection and owns the loading state', () => {
  const recordings = [{ id: 7 }, { id: 3 }];
  assert.deepEqual(listLoadOutcome({ ok: true, data: { recordings }, selectedId: 3 }), {
    recordings, selectId: null, stopLoading: false, error: null,
  });
  assert.deepEqual(listLoadOutcome({ ok: false, selectedId: 3 }), {
    recordings: [], selectId: null, stopLoading: false, error: null,
  });
});

// --- action entries ---------------------------------------------------------

test('a timeline entry keyed as type reads as action_type', () => {
  assert.equal(normalizeAction({ id: 1, type: 'click' }).action_type, 'click');
});

test('an entry with action_type is returned as is', () => {
  const action = { id: 1, action_type: 'navigate', type: 'navigate' };
  assert.equal(normalizeAction(action), action);
});

test('the page path carries the limit and the cursor', () => {
  assert.equal(actionsPagePath(7), `/api/session_recordings/7/actions?limit=${ACTIONS_PAGE_SIZE}`);
  assert.equal(actionsPagePath(7, 500, 2), '/api/session_recordings/7/actions?limit=2&after_sequence=500');
});

// --- paging -----------------------------------------------------------------

const json = (body, ok = true) => ({ ok, json: async () => body });

// A fetch over `count` actions with sequences 1..count that serves pages the
// way the actions endpoint does, and records each path it was asked for.
function pagedServer(count, { failOnRequest = null } = {}) {
  const calls = [];
  const fetchImpl = async (path) => {
    calls.push(path);
    if (calls.length === failOnRequest) return json({ error: 'boom' }, false);

    const url = new URL(path, 'https://host.test');
    const limit = Number(url.searchParams.get('limit'));
    const after = Number(url.searchParams.get('after_sequence') || 0);
    const remaining = [];
    for (let sequence = after + 1; sequence <= count; sequence += 1) {
      remaining.push({ id: sequence, sequence, action_type: 'click' });
    }
    return json({
      actions: remaining.slice(0, limit),
      has_more: remaining.length > limit,
      total_actions: count,
    });
  };
  return { calls, fetchImpl };
}

test('pages through every action until the server reports no more', async () => {
  const { calls, fetchImpl } = pagedServer(5);

  const result = await fetchAllActions(7, { fetchImpl, pageSize: 2 });

  assert.deepEqual(result.actions.map((action) => action.sequence), [1, 2, 3, 4, 5]);
  assert.equal(result.total, 5);
  assert.equal(result.complete, true);
  assert.deepEqual(calls, [
    '/api/session_recordings/7/actions?limit=2',
    '/api/session_recordings/7/actions?limit=2&after_sequence=2',
    '/api/session_recordings/7/actions?limit=2&after_sequence=4',
  ]);
});

test('stops at the page bound and reports the replay as partial', async () => {
  const { calls, fetchImpl } = pagedServer(10);

  const result = await fetchAllActions(7, { fetchImpl, pageSize: 2, maxPages: 3 });

  assert.equal(calls.length, 3);
  assert.equal(result.actions.length, 6);
  assert.equal(result.complete, false);
  assert.equal(result.total, 10);
});

test('a failed first page returns null so the caller can fall back', async () => {
  const { fetchImpl } = pagedServer(5, { failOnRequest: 1 });
  assert.equal(await fetchAllActions(7, { fetchImpl, pageSize: 2 }), null);

  const throwing = async () => { throw new Error('offline'); };
  assert.equal(await fetchAllActions(7, { fetchImpl: throwing }), null);
});

test('a failed later page keeps the actions gathered so far', async () => {
  const { fetchImpl } = pagedServer(5, { failOnRequest: 2 });

  const result = await fetchAllActions(7, { fetchImpl, pageSize: 2 });

  assert.deepEqual(result.actions.map((action) => action.sequence), [1, 2]);
  assert.equal(result.complete, false);
});

test('a page whose cursor does not advance ends the walk without repeating it', async () => {
  let calls = 0;
  const stuck = async () => {
    calls += 1;
    return json({ actions: [{ id: 1, sequence: 1, action_type: 'click' }], has_more: true });
  };

  const result = await fetchAllActions(7, { fetchImpl: stuck, pageSize: 1 });

  assert.equal(calls, 2);
  assert.equal(result.complete, false);
  assert.deepEqual(result.actions.map((action) => action.sequence), [1]);
});

test('a server that ignores the cursor yields each action once', async () => {
  const ignoresCursor = async () => json({
    actions: [1, 2, 3].map((sequence) => ({ id: sequence, sequence, action_type: 'click' })),
    has_more: true,
  });

  const result = await fetchAllActions(7, { fetchImpl: ignoresCursor, pageSize: 3 });

  assert.deepEqual(result.actions.map((action) => action.sequence), [1, 2, 3]);
  assert.equal(result.complete, false);
});

test('overlapping pages keep only the actions past the cursor', async () => {
  const pages = [
    { actions: [1, 2, 3], has_more: true },
    { actions: [2, 3, 4, 5], has_more: true },
    { actions: [5, 6], has_more: false },
  ];
  const calls = [];
  const overlapping = async (path) => {
    calls.push(path);
    const page = pages[calls.length - 1];
    return json({
      actions: page.actions.map((sequence) => ({ id: sequence, sequence, action_type: 'click' })),
      has_more: page.has_more,
    });
  };

  const result = await fetchAllActions(7, { fetchImpl: overlapping, pageSize: 3 });

  assert.deepEqual(result.actions.map((action) => action.sequence), [1, 2, 3, 4, 5, 6]);
  assert.equal(result.complete, true);
  assert.deepEqual(calls.slice(1), [
    '/api/session_recordings/7/actions?limit=3&after_sequence=3',
    '/api/session_recordings/7/actions?limit=3&after_sequence=5',
  ]);
});

test('page entries keyed as type are normalized', async () => {
  const fetchImpl = async () => json({ actions: [{ id: 1, sequence: 1, type: 'navigate' }], has_more: false });

  const result = await fetchAllActions(7, { fetchImpl });

  assert.equal(result.actions[0].action_type, 'navigate');
  assert.equal(result.total, null);
});

test('the count says when the replay holds only part of the recording', () => {
  assert.equal(actionCountLabel(120, 120, true), '120');
  assert.equal(actionCountLabel(5000, 12500, false), '5000 of 12500');
  assert.equal(actionCountLabel(4, null, false), '4');
});
