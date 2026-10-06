import assert from 'node:assert/strict';
import test from 'node:test';

import {
  budgetMeters,
  candidateDraft,
  candidateEditPayload,
  candidateReplayPath,
  explorationPath,
  isExplorationActive,
  keepOpenSelection,
  parseExplorationPath,
  preselectedIds,
  runEstimate,
  runEstimateText,
} from '../utils/explorations.mjs';

// The exploration review's rules: what starts selected, what the budget
// meter shows, where a candidate's replay opens, and what an
// accept-and-run will use.

const candidates = [
  { id: 1, state: 'proposed', verdict: 'answerable' },
  { id: 2, state: 'proposed', verdict: 'needs_tool', missing_tools: ['refund_order'] },
  { id: 3, state: 'edited', verdict: 'answerable' },
  { id: 4, state: 'rejected', verdict: 'answerable' },
  { id: 5, state: 'accepted', verdict: 'answerable', scenario_key: 'x9_5' },
  { id: 6, state: 'proposed', verdict: 'unverified' },
  { id: 7, state: 'proposed', verdict: 'answerable' },
];

test('only open, answerable candidates start selected, up to the host\'s limit', () => {
  assert.deepEqual(preselectedIds(candidates), [1, 3, 7]);
  assert.deepEqual(preselectedIds(candidates, null), [1, 3, 7]);
  assert.deepEqual(preselectedIds(candidates, 2), [1, 3]);
  assert.deepEqual(preselectedIds(candidates, 0), []);
  assert.deepEqual(preselectedIds([]), []);
});

test('a selection keeps only candidates still awaiting a decision', () => {
  assert.deepEqual(keepOpenSelection([1, 2, 4, 5, 9], candidates), [1, 2]);
});

test('the budget meter shows each limit set, with what was used of it', () => {
  assert.deepEqual(budgetMeters({ minutes: 15, steps: 150 }, { minutes: 3.25, steps: 160, cost: 0.4 }), [
    { key: 'minutes', label: 'Minutes', used: 3.25, limit: 15, ratio: 3.25 / 15, text: '3.3 / 15' },
    { key: 'steps', label: 'Browser steps', used: 160, limit: 150, ratio: 1, text: '160 / 150' },
  ]);
  assert.deepEqual(budgetMeters({ cost: 2 }, {}).map((row) => row.text), ['$0.00 / $2.00']);
  assert.deepEqual(budgetMeters({}, { minutes: 4 }), []);
  assert.deepEqual(budgetMeters({ minutes: 0, steps: 'many' }, {}), []);
  assert.deepEqual(budgetMeters(undefined, undefined), []);
});

test('a replay link needs a recording, and carries the range when there is one', () => {
  assert.equal(candidateReplayPath({ provenance: { recording_id: 7, range: { from_ms: 41200, to_ms: 58900 } } }),
    '/replay/7?from_ms=41200&to_ms=58900');
  assert.equal(candidateReplayPath({ provenance: { recording_id: 7 } }), '/replay/7');
  assert.equal(candidateReplayPath({ provenance: { urls: ['/orders'] } }), null);
  assert.equal(candidateReplayPath({ provenance: { recording_id: '7' } }), null);
  assert.equal(candidateReplayPath({}), null);
});

test('an accept-and-run uses the suite\'s enabled scenarios plus the new ones, under every model', () => {
  const evaluation = { enabled_scenario_count: 4, model_count: 2 };

  assert.deepEqual(runEstimate({ evaluation, candidates, selectedIds: [1, 3, 5] }), { added: 2, scenarios: 6, models: 2, executions: 12 });
  assert.deepEqual(runEstimate({ evaluation: null, candidates, selectedIds: [1] }), { added: 1, scenarios: 1, models: 1, executions: 1 });
  assert.equal(runEstimateText({ scenarios: 6, models: 2, executions: 12 }, 10),
    'The run uses 12 executions (6 scenarios × 2 models). 10 remaining on your plan.');
  assert.equal(runEstimateText({ scenarios: 1, models: 1, executions: 1 }, null), 'The run uses 1 execution (1 scenario × 1 model).');
});

test('an edit form round-trips a candidate, splitting lists on commas', () => {
  const candidate = {
    prompt: 'Where is A-17?', group: 'Orders', notes: 'Gives the status.',
    expectations: { tools: ['lookup_order', 'find_orders'], contains: ['A-17'], not_contains: [] },
  };
  const draft = candidateDraft(candidate);

  assert.deepEqual(draft, {
    prompt: 'Where is A-17?', group: 'Orders', rubric: 'Gives the status.', tools: 'lookup_order, find_orders', contains: 'A-17', not_contains: '',
  });
  assert.deepEqual(candidateEditPayload({ ...draft, tools: ' lookup_order ,, track_parcel ', rubric: ' Gives the carrier. ' }), {
    prompt: 'Where is A-17?', group: 'Orders', rubric: 'Gives the carrier.', tools: ['lookup_order', 'track_parcel'], contains: ['A-17'], not_contains: [],
  });
  assert.deepEqual(candidateDraft({ prompt: 'Hi' }), { prompt: 'Hi', group: '', rubric: '', tools: '', contains: '', not_contains: '' });
});

test('exploration paths, and which explorations are still walking', () => {
  assert.equal(explorationPath(12), '/explorations/12');
  assert.deepEqual(parseExplorationPath('/explorations/12'), { explorationId: '12' });
  assert.deepEqual(parseExplorationPath('/explorations'), { explorationId: null });
  assert.deepEqual(parseExplorationPath('/explorations/x'), { explorationId: null });
  assert.equal(isExplorationActive({ status: 'running' }), true);
  assert.equal(isExplorationActive({ status: 'pending' }), true);
  assert.equal(isExplorationActive({ status: 'review' }), false);
  assert.equal(isExplorationActive(null), false);
});
