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
