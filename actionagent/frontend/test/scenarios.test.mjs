import assert from 'node:assert/strict';
import test from 'node:test';
import {
  expectationText, exportUrl, parseScenariosPath, previewConflicts, previewGroups, previewSummary, scenarioForm,
  scenarioFormProblem, scenarioPayload, scenariosPath, splitList, toggleId,
} from '../utils/scenarios.mjs';

test('reads the Scenarios URLs, including the old /catalogs ones', () => {
  assert.deepEqual(parseScenariosPath('/scenarios'), { tab: 'collections', collectionId: null });
  assert.deepEqual(parseScenariosPath('/scenarios/12'), { tab: 'collections', collectionId: 12 });
  assert.deepEqual(parseScenariosPath('/scenarios/generate'), { tab: 'generate', collectionId: null });
  assert.deepEqual(parseScenariosPath('/scenarios/import/'), { tab: 'import', collectionId: null });
  assert.deepEqual(parseScenariosPath('/catalogs/3'), { tab: 'collections', collectionId: 3 });
  assert.deepEqual(parseScenariosPath('/scenarios/nope'), { tab: 'collections', collectionId: null });
});

test('builds the Scenarios URLs', () => {
  assert.equal(scenariosPath(), '/scenarios');
  assert.equal(scenariosPath({ tab: 'generate' }), '/scenarios/generate');
  assert.equal(scenariosPath({ tab: 'bogus' }), '/scenarios');
  assert.equal(scenariosPath({ tab: 'import', collectionId: 4 }), '/scenarios/4');
});

test('export URLs name the whole collection or a selection', () => {
  assert.equal(exportUrl(4), '/api/scenario_catalogs/4/export');
  assert.equal(
    exportUrl(4, { setIds: [1, 2], scenarioIds: [9] }, { inline: true }),
    '/api/scenario_catalogs/4/export?set_ids=1%2C2&scenario_ids=9&disposition=inline',
  );
});

test('a scenario form round-trips a scenario into the request body', () => {
  const form = scenarioForm({
    key: 'refund', prompt: 'Refund A-17', notes: 'Checks the order.', tags: ['billing'],
    expectations: { tools: ['lookup_order', 'refund_order'], not_contains: ['sorry'] }, enabled: false,
  });
  assert.equal(form.tools, 'lookup_order, refund_order');
  assert.equal(form.enabled, false);
  form.contains = 'refunded, refunded,  ';
  assert.deepEqual(scenarioPayload(form), {
    scenario: {
      key: 'refund', prompt: 'Refund A-17', notes: 'Checks the order.',
      expect: { tools: ['lookup_order', 'refund_order'], contains: ['refunded'], not_contains: ['sorry'] },
      tags: ['billing'], production_only: false, enabled: false,
    },
  });
  assert.equal(scenarioFormProblem({ ...form, prompt: '  ' }), 'A scenario needs a prompt.');
  assert.equal(scenarioFormProblem({ ...form, key: 'a b' }), 'A key has no spaces.');
  assert.equal(scenarioFormProblem(form), null);
});

test('lists, expectations and selections', () => {
  assert.deepEqual(splitList('a, b\nc,,a'), ['a', 'b', 'c']);
  assert.equal(expectationText({ tools: ['x'], contains: ['y'], not_contains: ['z'] }), 'tools x · contains y · never z');
  assert.equal(expectationText({}), '');
  assert.deepEqual(toggleId([1, 2], 2), [1]);
  assert.deepEqual(toggleId([1], 3), [1, 3]);
});

test('groups an import preview by action and says what applying it does', () => {
  const preview = {
    mode: 'replace',
    catalog: { key: 'checkout', action: 'update' },
    scenario_count: 3,
    counts: { create: 1, update: 1, remove: 1, unchanged: 4 },
    changes: [
      { level: 'scenario', path: 'cart/uat/checkout', action: 'create' },
      { level: 'scenario', path: 'cart/uat/remove_item', action: 'update' },
      { level: 'set', path: 'cart/smoke', action: 'remove' },
    ],
  };
  assert.deepEqual(previewGroups(preview).map((group) => [group.action, group.changes.length]), [['create', 1], ['update', 1], ['remove', 1]]);
  assert.equal(previewSummary(preview), 'Updates checkout: 1 new, 1 overwritten, 1 removed (3 scenarios in the document).');
  assert.equal(previewSummary({ ...preview, mode: 'merge', catalog: { key: 'n', action: 'create' }, counts: { keep: 2 } }),
    'Creates n: 0 new, 0 overwritten, 2 kept (3 scenarios in the document).');
  assert.equal(previewConflicts([preview]), true);
  assert.equal(previewConflicts([{ counts: { create: 3 } }]), false);
});
