import assert from 'node:assert/strict';
import test from 'node:test';
import { newInteractionPath, startableAgents } from '../utils/newInteraction.mjs';

const AGENTS = [
  { id: 1, name: 'Zed', status: 'draft' },
  { id: 2, name: 'Billing bot', status: 'active', description: 'Refunds and invoices' },
  { id: 3, name: 'Old', status: 'archived' },
  { id: 4, name: 'Atlas', status: 'active' },
  { id: 5, name: '', status: 'observed' },
];

test('archived and observed agents are left out; active ones come first, then by name', () => {
  assert.deepEqual(startableAgents(AGENTS).map((agent) => agent.id), [4, 2, 1]);
});

test('the query matches name or description, ignoring case', () => {
  assert.deepEqual(startableAgents(AGENTS, 'INVOICE').map((agent) => agent.id), [2]);
  assert.deepEqual(startableAgents(AGENTS, ' zed ').map((agent) => agent.id), [1]);
});

test("a new interaction opens the agent's runner on an empty conversation", () => {
  assert.equal(newInteractionPath({ id: 9 }), '/agents/9/run?new=1');
});
