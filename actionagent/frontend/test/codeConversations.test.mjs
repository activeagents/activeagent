import assert from 'node:assert/strict';
import test from 'node:test';
import {
  afterQuery,
  codeRootId,
  composerHint,
  conversationActive,
  conversationLine,
  conversationPath,
  interactionsListPath,
  interactionsQuery,
  isCodeInteraction,
  latestConversation,
  mergeConversation,
  parseInteractionsLocation,
  pendingPersonRequest,
  turnLine,
} from '../utils/codeConversations.mjs';

test('an Interactions path names the list, one conversation, or the latest, with its filters', () => {
  assert.deepEqual(parseInteractionsLocation('/interactions', ''), { view: 'list', source: 'all', project: null, codeId: null });
  assert.deepEqual(parseInteractionsLocation('/interactions/code-12', '?source=claude_code&project=3'),
    { view: 'conversation', source: 'claude_code', project: 3, codeId: 12 });
  assert.deepEqual(parseInteractionsLocation('/interactions/latest', '?project=7'), { view: 'latest', source: 'all', project: 7, codeId: null });
  assert.equal(parseInteractionsLocation('/interactions', '?source=shell&project=x').source, 'all', 'an unknown source is all');
  assert.equal(parseInteractionsLocation('/interactions/code-x').view, 'list');

  assert.equal(conversationPath(12), '/interactions/code-12');
  assert.equal(interactionsListPath({ source: 'codex', project: 3 }), '/interactions?source=codex&project=3');
  assert.equal(interactionsListPath(), '/interactions');
  assert.equal(interactionsQuery({ minutes: 60, source: 'claude_code', project: 3 }), 'minutes=60&source=claude_code&project_id=3');
  assert.equal(interactionsQuery({ agentId: 5 }), 'agent_id=5');
});

test('code rows are told apart, and the latest prefers one that is running', () => {
  assert.equal(codeRootId('code-42'), 42);
  assert.equal(codeRootId('trace-42'), null);
  assert.equal(isCodeInteraction({ id: 'code-1' }), true);
  assert.equal(isCodeInteraction({ id: 7, source: 'platform' }), false);

  const rows = [
    { id: 'code-1', source: 'code_session', last_activity_at: '2026-10-14T12:00:00Z', active: false },
    { id: 'code-2', source: 'code_session', last_activity_at: '2026-10-14T11:00:00Z', active: true },
    { id: 3, source: 'platform', last_activity_at: '2026-10-14T13:00:00Z' },
  ];
  assert.equal(latestConversation(rows).id, 'code-2');
  assert.equal(latestConversation([rows[0]]).id, 'code-1');
  assert.equal(latestConversation([rows[2]]), null);
});

test('polling asks for each turn\'s new events, and they are appended to those held', () => {
  const held = { turns: [{ id: 1, events_offset: 0, events: [{ n: 1 }, { n: 2 }] }, { id: 2, events_offset: 0, events: [] }] };
  assert.equal(afterQuery(held.turns), 'after[1]=2');

  const fresh = { turns: [{ id: 1, events_offset: 2, events: [{ n: 3 }] }, { id: 2, events_offset: 0, events: [{ n: 'a' }] }, { id: 3, events_offset: 0, events: [] }] };
  const merged = mergeConversation(held, fresh);
  assert.deepEqual(merged.turns[0].events.map((event) => event.n), [1, 2, 3]);
  assert.equal(merged.turns[0].events_offset, 0);
  assert.deepEqual(merged.turns[1].events.map((event) => event.n), ['a']);
  assert.equal(merged.turns.length, 3);
  assert.equal(mergeConversation(null, fresh), fresh);
});

test('turns and conversations are summed up in a line', () => {
  assert.equal(turnLine({ turn_index: 1, total_cost_usd: 0.031, duration_ms: 12000, diff_stat: { files: 2, additions: 14, deletions: 3 } }),
    'Turn 2 · $0.03 · 12s · 2 files +14 −3 since checkout');
  assert.equal(turnLine({ turn_index: 0 }), 'Turn 1');
  assert.match(conversationLine({ turn_count: 3, total_cost_usd: 0.12, tokens: { total: 41234 } }), /^3 turns · \$0\.12 · 41\.2k tokens$/);
});

test('an agent asking for a person is read from the last finished turn', () => {
  const asked = {
    turns: [{
      turn_index: 0, status: 'succeeded',
      events: [{ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'mcp__browser__browser_request_person', input: { reason: 'Upload the invoice' } }] } }],
    }],
  };
  assert.deepEqual(pendingPersonRequest(asked), { reason: 'Upload the invoice', turn: 0 });
  assert.equal(pendingPersonRequest({ turns: [{ ...asked.turns[0], status: 'running' }] }), null, 'not while it runs');
  assert.equal(pendingPersonRequest({ turns: [...asked.turns, { turn_index: 1, status: 'succeeded', events: [] }] }), null, 'answered by the next turn');
});

test('the composer says whether a message runs now or waits, and that a hand-back is reported', () => {
  assert.equal(conversationActive({ turns: [{ status: 'running' }] }), true);
  assert.match(composerHint({ sandbox_status: 'ready', turns: [{ status: 'running' }, { status: 'queued' }] }), /waits for the turn that runs \(and 1 more\)/);
  assert.match(composerHint({ sandbox_status: 'ready', turns: [{ status: 'succeeded' }] }, { handoff: { by: null } }), /resuming this conversation\. Claude Code will be told you drove the browser\./);
  assert.match(composerHint({ sandbox_status: 'stopped', turns: [] }), /The sandbox is stopped/);
});
