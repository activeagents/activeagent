import assert from 'node:assert/strict';
import test from 'node:test';
import { tracesQuery } from '../utils/tracesQuery.mjs';

// An agent's Traces tab names the agent by id, so the server can select an
// observed agent's traces from its record rather than from a class name its
// traces may not carry.

test('the whole window is requested when no agent is named', () => {
  assert.equal(tracesQuery({ minutes: 60 }), '/api/traces?minutes=60');
  assert.equal(tracesQuery({ minutes: 60, agentId: null }), '/api/traces?minutes=60');
  assert.equal(tracesQuery({ minutes: 60, agentId: '' }), '/api/traces?minutes=60');
});

test('an agent is named by its id, never by a class', () => {
  const path = tracesQuery({ minutes: 1440, agentId: 42 });
  const params = new URLSearchParams(path.split('?')[1]);

  assert.equal(path.split('?')[0], '/api/traces');
  assert.equal(params.get('minutes'), '1440');
  assert.equal(params.get('agent_id'), '42');
  assert.equal(params.has('agent'), false);
});
