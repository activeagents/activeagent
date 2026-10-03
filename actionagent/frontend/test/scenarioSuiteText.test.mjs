import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import { scenarioLine, scenariosToText } from '../utils/scenarioSuiteText.mjs';

// The suite editor's Save writes these lines, and an accepted exploration
// candidate is written so that they read back unchanged. The fixture is
// shared with ActionAgent::Exploration.suite_editor_line's test.
const LINES = JSON.parse(readFileSync(new URL('./fixtures/suite-editor-lines.json', import.meta.url), 'utf8'));

test('each scenario is written as the line the fixture names', () => {
  for (const { entry, line } of LINES) {
    assert.equal(scenarioLine(entry), line, entry.key);
  }
});

test('a heading starts each run of scenarios in one group', () => {
  const text = scenariosToText([
    { key: 'a', prompt: 'One', group: 'Orders' },
    { key: 'b', prompt: 'Two', group: 'Orders' },
    { key: 'c', prompt: 'Three', group: 'Billing', notes: 'Asks which invoice' },
    { key: 'd', prompt: 'Four' },
  ]);

  assert.equal(text, [
    '# Orders', 'One | key: a', 'Two | key: b', '# Billing', 'Three | notes: Asks which invoice | key: c', 'Four | key: d',
  ].join('\n'));
});
