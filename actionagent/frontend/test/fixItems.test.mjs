import assert from 'node:assert/strict';
import test from 'node:test';

// fixItemsFor lives in a .jsx module, so this suite pins the contract the What
// to Fix cards depend on rather than importing the component: every card names
// the scenarios its fault came from, which is what makes the card's scope a
// link into the matrix.

const scenarioKeysOf = (item) => item.scenario_keys || [];

test('a fault card names the scenarios it came from', () => {
  const item = { kind: 'fault', fault: 'tool_error', count: 2, scenario_keys: ['diagnostics_2', 'diagnostics_3'] };

  assert.deepEqual(scenarioKeysOf(item), ['diagnostics_2', 'diagnostics_3']);
});

test('a judge suggestion names its scenario too, so it links like a fault', () => {
  const item = { kind: 'instruction', fault: 'instruction change', count: 1, scenario_keys: ['blame_7'] };

  assert.deepEqual(scenarioKeysOf(item), ['blame_7']);
});

test('a card with no scenarios yields no link target', () => {
  assert.deepEqual(scenarioKeysOf({ kind: 'fault', fault: 'tool_error' }), []);
});
