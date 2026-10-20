import assert from 'node:assert/strict';
import test from 'node:test';
import { evaluationLink, includeLinkedEvaluation, scenarioRowsForRun } from '../utils/evaluationHistory.mjs';

test('a historical matrix keeps original question expectations and notes after catalog refresh', () => {
  const current = { id: 7, key: 'order_1', prompt: 'Cancel order DEF-456', group: 'cancellations', notes: 'New tool',
    expectations: { tools: ['cancel_order'] }, enabled: false };
  const snapshot = { key: 'order_1', prompt: 'Where is order ABC-123?', group: 'orders', expectations: { tools: ['lookup_order'] } };
  const rows = scenarioRowsForRun([current], { order_1: { model: { scenario: snapshot } } });
  assert.equal(rows[0].prompt, snapshot.prompt);
  assert.equal(rows[0].group, 'orders');
  assert.deepEqual(rows[0].expectations, { tools: ['lookup_order'] });
  assert.equal(rows[0].notes, null);
  assert.equal(rows[0].catalogChanged, true);
  assert.equal(rows[0].id, 7);
  assert.equal(rows[0].enabled, false);
  assert.equal(current.prompt, 'Cancel order DEF-456');
});

test('unrun catalog entries remain selectable and recorded removed questions remain visible', () => {
  const current = { id: 8, key: 'help_1', prompt: 'How do returns work?', enabled: true };
  const rows = scenarioRowsForRun([current], { order_1: { model: { scenario_key: 'order_1', prompt: 'Original question', group: 'orders' } } });
  assert.equal(rows[0], current);
  assert.equal(rows[1].prompt, 'Original question');
  assert.equal(rows[1].orphan, true);
  assert.equal(rows[1].id, null);
});

test('rows keep their identity across polls when nothing about them changed', () => {
  const a = { id: 1, key: 'a', prompt: 'Install the gem', group: 'Install', enabled: true };
  const b = { id: 2, key: 'b', prompt: 'Generate an agent', group: 'Agents', enabled: true };
  const d = { id: 4, key: 'd', prompt: 'Not run yet', group: 'Agents', enabled: true };
  const result = (key, model, status) => ({ id: `${key}-${model}`, scenario_key: key, model, status, prompt: `${key}?`, group: 'Install' });
  const resultsByKey = {
    a: { mini: result('a', 'mini', 'passed'), sonnet: result('a', 'sonnet', 'pending') },
    b: { mini: result('b', 'mini', 'passed') },
    c: { mini: result('c', 'mini', 'failed') },
  };
  const cache = new Map();

  // An unchanged poll hands every row back: the merged rows, the orphan, and
  // the catalog object itself for a scenario the run has no result for.
  const first = scenarioRowsForRun([a, b, d], resultsByKey, cache);
  const second = scenarioRowsForRun([a, b, d], resultsByKey, cache);
  assert.equal(first.length, 4);
  first.forEach((row, index) => assert.equal(second[index], row));
  assert.equal(first[2], d);
  assert.equal(first[3].orphan, true);
  assert.equal(cache.has('d'), false);
  assert.deepEqual(cache.get('a'), { scenario: a, first: resultsByKey.a.mini, row: first[0] });
  assert.deepEqual(cache.get('c'), { scenario: null, first: resultsByKey.c.mini, row: first[3] });

  // A landed result replaces only its own row; the row snapshots from the
  // first result, so a change to a later model's result keeps it as well.
  const landed = { ...resultsByKey, a: { ...resultsByKey.a, mini: { ...resultsByKey.a.mini, status: 'failed' } } };
  const third = scenarioRowsForRun([a, b, d], landed, cache);
  assert.notEqual(third[0], second[0]);
  assert.deepEqual(third[0], second[0]);
  assert.equal(third[1], second[1]);
  assert.equal(third[3], second[3]);
  const later = { ...landed, a: { ...landed.a, sonnet: { ...landed.a.sonnet, status: 'passed' } } };
  assert.equal(scenarioRowsForRun([a, b, d], later, cache)[0], third[0]);

  // A refreshed catalog entry rebuilds its row and no other.
  const fourth = scenarioRowsForRun([a, { ...b, prompt: 'Generate an agent class' }, d], later, cache);
  assert.notEqual(fourth[1], third[1]);
  assert.equal(fourth[1].prompt, 'b?');
  assert.equal(fourth[1].catalogChanged, true);
  assert.equal(fourth[0], third[0]);
  assert.equal(fourth[3], third[3]);

  // A recorded question that leaves the catalog, or joins it, is rebuilt
  // rather than read from the other side's entry.
  const fifth = scenarioRowsForRun([a, d], later, cache);
  assert.equal(fifth[2].key, 'b');
  assert.equal(fifth[2].orphan, true);
  assert.notEqual(fifth[2], fourth[1]);
  assert.equal(cache.get('b').scenario, null);

  // Without a cache every call builds fresh rows.
  assert.notEqual(scenarioRowsForRun([a], resultsByKey)[0], scenarioRowsForRun([a], resultsByKey)[0]);
  assert.deepEqual(scenarioRowsForRun([a, b, d], resultsByKey), first);
});

test('evaluation deep links validate IDs and optionally select a saved report', () => {
  assert.deepEqual(evaluationLink('?evaluation=12'), { evaluationId: '12', runId: null });
  assert.deepEqual(evaluationLink('?evaluation=12&run=8'), { evaluationId: '12', runId: '8' });
  assert.equal(evaluationLink('?evaluation=../../other'), null);
  assert.equal(evaluationLink('?evaluation=0'), null);
  assert.equal(evaluationLink('?run=8'), null);
});

test('a linked evaluation outside the index page is loaded through its scoped detail endpoint', async () => {
  const list = [{ id: 9 }];
  const result = await includeLinkedEvaluation(list, '2', async (path) => {
    assert.equal(path, '/api/evaluations/2');
    return { ok: true, json: async () => ({ evaluation: { id: 2, name: 'Order support' } }) };
  });
  assert.deepEqual(result.map((entry) => entry.id), [2, 9]);
  assert.deepEqual(list, [{ id: 9 }]);
  assert.equal(await includeLinkedEvaluation(list, '9', () => assert.fail('No extra request needed')), list);
});

test('an unavailable or forbidden deep link is reported without adding an unscoped record', async () => {
  for (const status of [403, 404]) {
    await assert.rejects(includeLinkedEvaluation([], '2', async () => ({ ok: false, status })), new RegExp(`unavailable.*${status}`));
  }
});
