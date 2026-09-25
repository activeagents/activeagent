import assert from 'node:assert/strict';
import test from 'node:test';
import {
  apiErrorMessage,
  codeSessionStatus,
  diffLines,
  diffStats,
  eventRows,
  fmtCostUsd,
  fmtDurationMs,
  fmtExpiry,
  groupSandboxes,
  isCodeSessionActive,
  isCodeSessionFinished,
  isSandboxBooting,
  isSandboxReady,
  MAX_POLL_FAILURES,
  mergeEvents,
  pollGivesUp,
  previewText,
  replaceBy,
  resultLine,
  sandboxStatus,
  sessionCounts,
  sessionResultLine,
  sessionSummary,
  sessionTitle,
  summarizeToolInput,
  toolResultText,
  transcriptRows,
  upsertBy,
} from '../utils/codeSessions.mjs';

// Settings -> Integrations renders a Claude Code session's stream-json
// transcript as rows. These pin how each event type reads — including the
// ones the CLI may add later, which must still show up rather than vanish —
// and the status, cost and polling rules the two cards share.

const CWD = '/home/dev/app/tmp/action_agent/sandboxes/abc123/app';

// A transcript shaped like `claude -p --output-format stream-json --verbose`.
const transcript = () => [
  { type: 'system', subtype: 'init', cwd: CWD, session_id: 's1', model: 'claude-sonnet-4-5', permissionMode: 'acceptEdits', tools: ['Bash', 'Read', 'Edit'] },
  {
    type: 'assistant',
    message: {
      role: 'assistant',
      content: [
        { type: 'thinking', thinking: 'Find the failing test first.' },
        { type: 'text', text: "I'll run the tests." },
        { type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'bin/rails test\n  test/models', description: 'Run tests' } },
      ],
    },
    parent_tool_use_id: null,
  },
  {
    type: 'user',
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content: '1 runs, 1 failures', is_error: true }] },
    parent_tool_use_id: null,
  },
  {
    type: 'assistant',
    message: { role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_2', name: 'Edit', input: { file_path: `${CWD}/app/models/user.rb`, old_string: 'a', new_string: 'b' } }] },
  },
  {
    type: 'user',
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_2', content: [{ type: 'text', text: 'The file has been updated.' }] }] },
  },
  'not json at all',
  { type: 'raw', text: 'npm WARN deprecated' },
  { type: 'result', subtype: 'success', is_error: false, result: 'Fixed.', num_turns: 3, total_cost_usd: 0.1234, duration_ms: 42_500, permission_denials: [] },
];

test('a whole transcript renders every event, keyed by its position', () => {
  const rows = transcriptRows(transcript());

  assert.deepEqual(rows.map((row) => row.kind), [
    'system', 'thinking', 'text', 'tool_use', 'tool_result', 'tool_use', 'tool_result', 'raw', 'raw', 'result',
  ]);
  assert.deepEqual(rows.map((row) => row.key), ['0:0', '1:0', '1:1', '1:2', '2:0', '3:0', '4:0', '5:0', '6:0', '7:0']);

  assert.equal(rows[0].text, 'Session started · model claude-sonnet-4-5 · acceptEdits mode · 3 tools');
  assert.equal(rows[2].text, "I'll run the tests.");
  // name + short input, on one line.
  assert.deepEqual([rows[3].name, rows[3].summary], ['Bash', 'bin/rails test test/models']);
  // A result knows the call it answers, and whether it failed.
  assert.deepEqual([rows[4].name, rows[4].text, rows[4].isError], ['Bash', '1 runs, 1 failures', true]);
  // Paths read relative to the checkout the init event named.
  assert.deepEqual([rows[5].name, rows[5].summary], ['Edit', 'app/models/user.rb']);
  assert.deepEqual([rows[6].name, rows[6].text, rows[6].isError], ['Edit', 'The file has been updated.', false]);
  assert.equal(rows[7].text, 'not json at all');
  assert.equal(rows[8].text, 'npm WARN deprecated');
  assert.deepEqual([rows[9].tone, rows[9].text], ['success', 'Done · 3 turns · $0.12 · 42.5s']);
});

test('the system init event reads whatever the CLI reported, and other subtypes by name', () => {
  // The mock backend's init carries only a model.
  assert.deepEqual(eventRows({ type: 'system', subtype: 'init', model: 'mock' }), [{ kind: 'system', text: 'Session started · model mock' }]);
  assert.deepEqual(eventRows({ type: 'system', subtype: 'compact_boundary' }), [{ kind: 'system', text: 'Conversation compacted' }]);
  assert.deepEqual(eventRows({ type: 'system', subtype: 'hook_response' }), [{ kind: 'system', text: 'System: hook response' }]);
  assert.deepEqual(eventRows({ type: 'system' }), [{ kind: 'system', text: 'System event' }]);
});

test('assistant messages: text, thinking and tool calls; empty text shows nothing', () => {
  assert.deepEqual(eventRows({ type: 'assistant', message: { content: [{ type: 'text', text: '  ' }] } }), []);
  assert.deepEqual(eventRows({ type: 'assistant', message: { content: 'plain string content' } }), [{ kind: 'text', text: 'plain string content' }]);
  assert.deepEqual(eventRows({ type: 'assistant', message: { content: [{ type: 'redacted_thinking', data: 'x' }] } }), [{ kind: 'thinking', text: '(redacted)' }]);

  const [call] = eventRows({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 't', name: 'mcp__github__get_issue', input: { owner: 'a', repo: 'b', number: 4 } }] } });
  assert.deepEqual(call, { kind: 'tool_use', name: 'mcp__github__get_issue', summary: '{"owner":"a","repo":"b","number":4}', id: 't' });
});

test('a subagent\'s rows are marked nested', () => {
  const rows = eventRows({ type: 'assistant', parent_tool_use_id: 'toolu_task', message: { content: [{ type: 'text', text: 'Searching.' }] } });
  assert.deepEqual(rows, [{ kind: 'text', text: 'Searching.', nested: true }]);
});

test('tool results are truncated for the transcript, and flagged when they were', () => {
  const long = Array.from({ length: 40 }, (_, i) => `line ${i + 1}`).join('\n');
  const [row] = eventRows({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'unknown', content: long }] } });
  assert.equal(row.kind, 'tool_result');
  assert.equal(row.name, null);
  assert.equal(row.truncated, true);
  assert.equal(row.text.split('\n').length, 12);
  assert.ok(row.text.endsWith('line 12…'));
  assert.equal(row.isError, false);

  assert.deepEqual(previewText('x'.repeat(1000), { chars: 10 }), { text: `${'x'.repeat(10)}…`, truncated: true });
  assert.deepEqual(previewText('short\n\n'), { text: 'short', truncated: false });
});

test('tool result content reads from a string, text blocks or anything else', () => {
  assert.equal(toolResultText('done'), 'done');
  assert.equal(toolResultText([{ type: 'text', text: 'a' }, { type: 'image', source: {} }, { type: 'text', text: 'b' }]), 'a\n[image]\nb');
  assert.equal(toolResultText([{ type: 'tool_reference', tool_name: 'x' }]), '{"type":"tool_reference","tool_name":"x"}');
  assert.equal(toolResultText(null), '');
  assert.equal(toolResultText({ ok: true }), '{"ok":true}');
});

test('a user message that is text, not a tool result, still renders', () => {
  assert.deepEqual(eventRows({ type: 'user', message: { content: [{ type: 'text', text: 'Go on.' }] } }), [{ kind: 'user_text', text: 'Go on.' }]);
});

test('result events read their outcome, turns, cost and duration', () => {
  assert.deepEqual(
    eventRows({ type: 'result', subtype: 'success', is_error: false, num_turns: 1, duration_ms: 0, total_cost_usd: 0 }),
    [{ kind: 'result', tone: 'success', text: 'Done · 1 turn · $0.00 · 0ms' }],
  );
  assert.deepEqual(
    eventRows({ type: 'result', subtype: 'error_max_turns', is_error: false, num_turns: 10, total_cost_usd: 0.004, duration_ms: 125_000 }),
    [{ kind: 'result', tone: 'error', text: 'Stopped: max turns reached · 10 turns · $0.0040 · 2m 5s' }],
  );
  assert.deepEqual(
    eventRows({ type: 'result', subtype: 'error_during_execution', is_error: true }),
    [{ kind: 'result', tone: 'error', text: 'Error during execution' }],
  );
  assert.deepEqual(
    eventRows({ type: 'result', subtype: 'error_something_new', is_error: true, num_turns: 2 }),
    [{ kind: 'result', tone: 'error', text: 'Error (something new) · 2 turns' }],
  );
  assert.deepEqual(
    eventRows({ type: 'result', subtype: 'success', is_error: true }),
    [{ kind: 'result', tone: 'error', text: 'Error' }],
  );
  // Denied tool calls are why an acceptEdits session did less than asked.
  assert.deepEqual(
    eventRows({ type: 'result', subtype: 'success', is_error: false, num_turns: 4, permission_denials: [{ tool_name: 'Bash' }, { tool_name: 'Bash' }] }),
    [{ kind: 'result', tone: 'success', text: 'Done · 4 turns · 2 permission denials' }],
  );
});

test('raw lines render as text, and empty ones render nothing', () => {
  assert.deepEqual(eventRows({ type: 'raw', text: 'Warning: x' }), [{ kind: 'raw', text: 'Warning: x' }]);
  assert.deepEqual(eventRows({ type: 'raw', text: '' }), []);
  assert.deepEqual(eventRows('plain'), [{ kind: 'raw', text: 'plain' }]);
  assert.deepEqual(eventRows(null), []);
  assert.deepEqual(eventRows(42), [{ kind: 'raw', text: '42' }]);
});

test('unknown events and blocks still show, as their JSON', () => {
  assert.deepEqual(eventRows({ type: 'stream_event', event: { type: 'ping' } }), [
    { kind: 'unknown', label: 'stream_event', text: '{"type":"stream_event","event":{"type":"ping"}}' },
  ]);
  assert.deepEqual(eventRows({ foo: 1 }), [{ kind: 'unknown', label: 'event', text: '{"foo":1}' }]);
  assert.deepEqual(eventRows({ type: 'assistant', message: { content: [{ type: 'citation', url: 'u' }] } }), [
    { kind: 'unknown', label: 'assistant citation', text: '{"type":"citation","url":"u"}' },
  ]);
  // A message without content is shown whole rather than dropped.
  assert.equal(eventRows({ type: 'assistant' })[0].kind, 'unknown');

  const [big] = eventRows({ type: 'mystery', blob: 'y'.repeat(2000) });
  assert.equal(big.text.length, 300);
  assert.ok(big.text.endsWith('…'));
});

test('tool input summaries name what each tool did', () => {
  const cwd = { cwd: CWD };
  assert.equal(summarizeToolInput('Bash', { command: 'git status &&\n  git diff' }), 'git status && git diff');
  assert.equal(summarizeToolInput('Read', { file_path: `${CWD}/Gemfile` }, cwd), 'Gemfile');
  assert.equal(summarizeToolInput('Read', { file_path: '/etc/hosts' }, cwd), '/etc/hosts');
  assert.equal(summarizeToolInput('Write', { file_path: `${CWD}/a.rb`, content: 'x' }, cwd), 'a.rb');
  assert.equal(summarizeToolInput('MultiEdit', { file_path: `${CWD}/a.rb`, edits: [{}, {}] }, cwd), 'a.rb (2 edits)');
  assert.equal(summarizeToolInput('NotebookEdit', { notebook_path: `${CWD}/n.ipynb` }, cwd), 'n.ipynb');
  assert.equal(summarizeToolInput('Glob', { pattern: '**/*.rb' }), '**/*.rb');
  assert.equal(summarizeToolInput('Glob', { pattern: '*.rb', path: `${CWD}/app` }, cwd), '*.rb in app');
  assert.equal(summarizeToolInput('Grep', { pattern: 'def call' }), '"def call"');
  assert.equal(summarizeToolInput('Grep', { pattern: 'def call', glob: '*.rb', path: CWD }, cwd), '"def call" in . (*.rb)');
  assert.equal(summarizeToolInput('Grep', { pattern: 'TODO', glob: '*.js' }), '"TODO" (*.js)');
  assert.equal(summarizeToolInput('LS', { path: `${CWD}/lib` }, cwd), 'lib');
  assert.equal(summarizeToolInput('WebFetch', { url: 'https://example.com', prompt: 'x' }), 'https://example.com');
  assert.equal(summarizeToolInput('WebSearch', { query: 'rails 8' }), 'rails 8');
  assert.equal(summarizeToolInput('Task', { description: 'Find callers', prompt: 'long' }), 'Find callers');
  assert.equal(summarizeToolInput('Agent', { prompt: 'Look around' }), 'Look around');
  assert.equal(summarizeToolInput('TodoWrite', { todos: [{}, {}, {}] }), '3 todos');
  assert.equal(summarizeToolInput('Skill', { skill: 'pdf' }), 'pdf');
  // An unfamiliar tool: a common field, else its input as JSON.
  assert.equal(summarizeToolInput('mcp__fs__read', { path: `${CWD}/x` }, cwd), 'x');
  assert.equal(summarizeToolInput('mcp__x__y', { id: 7 }), '{"id":7}');
  assert.equal(summarizeToolInput('mcp__x__y', {}), '');
  assert.equal(summarizeToolInput('Bash', null), '');
  assert.equal(summarizeToolInput('Weird', 'a string input'), 'a string input');
  // A known tool missing its usual field falls back the same way.
  assert.equal(summarizeToolInput('Bash', { description: 'List files' }), 'List files');

  const long = summarizeToolInput('Bash', { command: 'x'.repeat(500) });
  assert.equal(long.length, 120);
  assert.ok(long.endsWith('…'));
});

test('result lines: cost, turns and duration, leaving out what was not reported', () => {
  assert.equal(resultLine('Succeeded', { num_turns: 3, total_cost_usd: 0.1234, duration_ms: 42_500 }), 'Succeeded · 3 turns · $0.12 · 42.5s');
  assert.equal(resultLine('Failed', { num_turns: null, total_cost_usd: null, duration_ms: 900 }), 'Failed · 900ms');
  assert.equal(resultLine('Cancelled'), 'Cancelled');

  assert.equal(fmtCostUsd(0), '$0.00');
  assert.equal(fmtCostUsd(0.0042), '$0.0042');
  assert.equal(fmtCostUsd(1.5), '$1.50');
  assert.equal(fmtCostUsd('0.25'), '$0.25');
  assert.equal(fmtCostUsd(null), null);
  assert.equal(fmtCostUsd('n/a'), null);

  assert.equal(fmtDurationMs(0), '0ms');
  assert.equal(fmtDurationMs(850), '850ms');
  assert.equal(fmtDurationMs(12_000), '12s');
  assert.equal(fmtDurationMs(12_340), '12.3s');
  assert.equal(fmtDurationMs(125_000), '2m 5s');
  assert.equal(fmtDurationMs(3_723_000), '1h 2m');
  assert.equal(fmtDurationMs(null), null);
});

test('a session summary reads its status, and its counts once finished', () => {
  assert.equal(sessionResultLine({ status: 'succeeded', num_turns: 1, total_cost_usd: 0, duration_ms: 0 }), 'Succeeded · 1 turn · $0.00 · 0ms');
  assert.equal(sessionResultLine({ status: 'failed', num_turns: null, total_cost_usd: null, duration_ms: null }), 'Failed');
  assert.equal(sessionResultLine({ status: 'running', event_count: 7 }), 'Running · 7 events');
  assert.equal(sessionResultLine({ status: 'queued', event_count: 0 }), 'Queued');
  assert.equal(sessionResultLine({ status: 'cancelled' }), 'Cancelled');

  // Beside a status badge: the counts alone.
  assert.equal(sessionCounts({ status: 'succeeded', num_turns: 3, total_cost_usd: 0.1234, duration_ms: 42_500 }), '3 turns · $0.12 · 42.5s');
  assert.equal(sessionCounts({ status: 'running', event_count: 1 }), '1 event');
  assert.equal(sessionCounts({ status: 'queued' }), '');
  assert.equal(sessionCounts({ status: 'failed' }), '');

  assert.equal(sessionTitle('\n  Fix the login bug\nand add a test'), 'Fix the login bug');
  assert.equal(sessionTitle('x'.repeat(100)).length, 80);
  assert.equal(sessionTitle(''), '(empty prompt)');
});

test('sandbox statuses map to a label and a tone, and to polling', () => {
  assert.deepEqual(sandboxStatus('pending'), { label: 'Queued', tone: 'progress' });
  assert.deepEqual(sandboxStatus('provisioning'), { label: 'Booting', tone: 'progress' });
  assert.deepEqual(sandboxStatus('ready'), { label: 'Ready', tone: 'success' });
  assert.deepEqual(sandboxStatus('running'), { label: 'Running', tone: 'success' });
  assert.deepEqual(sandboxStatus('completed'), { label: 'Completed', tone: 'neutral' });
  assert.deepEqual(sandboxStatus('expired'), { label: 'Stopped', tone: 'neutral' });
  assert.deepEqual(sandboxStatus('failed'), { label: 'Failed', tone: 'error' });
  assert.deepEqual(sandboxStatus('rebooting_now'), { label: 'Rebooting now', tone: 'neutral' });
  assert.deepEqual(sandboxStatus(undefined), { label: 'Unknown', tone: 'neutral' });

  // Polled until it settles: ready, failed and expired all stop the poll.
  assert.deepEqual(
    ['pending', 'provisioning', 'ready', 'running', 'failed', 'expired', 'completed'].map((status) => isSandboxBooting({ status })),
    [true, true, false, false, false, false, false],
  );
  assert.equal(isSandboxBooting(null), false);
  assert.equal(isSandboxReady({ status: 'ready' }), true);
  assert.equal(isSandboxReady({ status: 'running' }), false);
});

test('code session statuses: which poll, which are finished', () => {
  assert.deepEqual(codeSessionStatus('queued'), { label: 'Queued', tone: 'progress' });
  assert.deepEqual(codeSessionStatus('running'), { label: 'Running', tone: 'progress' });
  assert.deepEqual(codeSessionStatus('succeeded'), { label: 'Succeeded', tone: 'success' });
  assert.deepEqual(codeSessionStatus('failed'), { label: 'Failed', tone: 'error' });
  assert.deepEqual(codeSessionStatus('cancelled'), { label: 'Cancelled', tone: 'neutral' });

  const statuses = ['queued', 'running', 'succeeded', 'failed', 'cancelled'];
  assert.deepEqual(statuses.map((status) => isCodeSessionActive({ status })), [true, true, false, false, false]);
  assert.deepEqual(statuses.map((status) => isCodeSessionFinished({ status })), [false, false, true, true, true]);
});

test('polled events append from the offset the server answered with', () => {
  const first = mergeEvents([], { events_offset: 0, events: ['a', 'b'] });
  assert.deepEqual(first, ['a', 'b']);
  const second = mergeEvents(first, { events_offset: 2, events: ['c'] });
  assert.deepEqual(second, ['a', 'b', 'c']);
  // A repeated poll (same offset) replaces rather than duplicates.
  assert.deepEqual(mergeEvents(second, { events_offset: 2, events: ['c', 'd'] }), ['a', 'b', 'c', 'd']);
  // Nothing new.
  assert.deepEqual(mergeEvents(second, { events_offset: 3, events: [] }), ['a', 'b', 'c']);
  // An offset past what is held cannot leave a gap.
  assert.deepEqual(mergeEvents(['a'], { events_offset: 5, events: ['z'] }), ['a', 'z']);
  assert.deepEqual(mergeEvents(undefined, { events: ['a'] }), ['a']);
});

test('the server\'s error is what a failed request shows', () => {
  assert.equal(apiErrorMessage({ error: 'The sandbox is provisioning; wait until it is ready' }, 'x'), 'The sandbox is provisioning; wait until it is ready');
  assert.equal(apiErrorMessage({ errors: ['Repository is not selected', 'Ref is invalid'] }, 'x'), 'Repository is not selected, Ref is invalid');
  assert.equal(apiErrorMessage({ error: ['a', 'b'] }, 'x'), 'a, b');
  assert.equal(apiErrorMessage({ error: 'Plan limit reached', upgrade_required: true, message: '100 runs a month' }, 'x'), 'Plan limit reached: 100 runs a month');
  assert.equal(apiErrorMessage({}, 'Could not start.'), 'Could not start.');
  assert.equal(apiErrorMessage(null, 'Could not start.'), 'Could not start.');
  assert.equal(apiErrorMessage({ errors: [] }, 'fallback'), 'fallback');
});

test('sandboxes group by repository, keeping ones of unselected repositories reachable', () => {
  const sandboxes = [
    { session_id: 'n', repository: 'acme/web', status: 'ready', sandbox_type: 'app_runtime' },
    { session_id: 'o', repository: 'acme/web', status: 'failed', sandbox_type: 'app_runtime' },
    { session_id: 'p', repository: 'acme/old', status: 'ready', sandbox_type: 'app_runtime' },
    { session_id: 'q', repository: 'acme/web', status: 'expired', sandbox_type: 'app_runtime' },
    { session_id: 'r', repository: null, status: 'ready', sandbox_type: 'playwright_mcp' },
  ];
  const { byRepository, others } = groupSandboxes(sandboxes, ['acme/web', 'acme/api']);
  assert.deepEqual(Object.keys(byRepository), ['acme/web']);
  assert.deepEqual(byRepository['acme/web'].map((s) => s.session_id), ['n', 'o']);
  assert.deepEqual(others.map((s) => s.session_id), ['p']);
});

test('upsertBy replaces in place, merging, or puts a new row first', () => {
  const list = [{ id: 1, status: 'running', prompt: 'a' }, { id: 2, status: 'failed' }];
  assert.deepEqual(upsertBy(list, { id: 1, status: 'succeeded' }, 'id'), [{ id: 1, status: 'succeeded', prompt: 'a' }, { id: 2, status: 'failed' }]);
  assert.deepEqual(upsertBy(list, { id: 3, status: 'queued' }, 'id').map((row) => row.id), [3, 1, 2]);
  assert.equal(upsertBy(list, null, 'id'), list);
  assert.equal(list[0].status, 'running');
});

test('replaceBy only updates rows already listed', () => {
  const list = [{ session_id: 'a', status: 'provisioning', repository: 'acme/web' }];
  assert.deepEqual(replaceBy(list, { session_id: 'a', status: 'ready' }, 'session_id'), [{ session_id: 'a', status: 'ready', repository: 'acme/web' }]);
  // Stopped (and so removed) while its poll was in flight.
  assert.equal(replaceBy(list, { session_id: 'b', status: 'ready' }, 'session_id'), list);
  assert.equal(replaceBy(list, null, 'session_id'), list);
});

test('a session summary drops the transcript a details response carries', () => {
  assert.deepEqual(
    sessionSummary({ id: 4, status: 'running', events: [{}], events_offset: 0, dropped_events_count: 0, diff: null, event_count: 1 }),
    { id: 4, status: 'running', event_count: 1 },
  );
  assert.equal(sessionSummary(null), null);
});

test('sandbox expiry reads as time left', () => {
  const now = Date.parse('2026-09-24T10:00:00Z');
  assert.equal(fmtExpiry('2026-09-24T11:52:00Z', now), 'expires in 1h 52m');
  assert.equal(fmtExpiry('2026-09-24T12:00:00Z', now), 'expires in 2h');
  assert.equal(fmtExpiry('2026-09-24T10:03:30Z', now), 'expires in 4m');
  assert.equal(fmtExpiry('2026-09-24T09:59:00Z', now), 'past its expiry');
  assert.equal(fmtExpiry(null, now), null);
  assert.equal(fmtExpiry('garbage', now), null);
});

test('a diff reads line by line, and sums up', () => {
  const diff = [
    'diff --git a/app/models/user.rb b/app/models/user.rb',
    'index 1111111..2222222 100644',
    '--- a/app/models/user.rb',
    '+++ b/app/models/user.rb',
    '@@ -1,3 +1,3 @@',
    ' class User',
    '-  def a; end',
    '--- a removed line that looks like a header',
    '+  def b; end',
    'diff --git a/NEW.md b/NEW.md',
    'new file mode 100644',
    '--- /dev/null',
    '+++ b/NEW.md',
    '@@ -0,0 +1 @@',
    '+hello',
    '… diff truncated',
    '',
  ].join('\n');

  assert.deepEqual(diffLines(diff).map((line) => line.kind), [
    'meta', 'meta', 'meta', 'meta', 'hunk', 'context', 'del', 'del', 'add', 'meta', 'meta', 'meta', 'meta', 'hunk', 'add', 'meta',
  ]);
  assert.equal(diffStats(diff), '2 files changed · +2 −2');
  assert.deepEqual(diffLines(''), []);
  assert.deepEqual(diffLines(null), []);
});

// git diff's own output for one edit, one new file, a binary change and a
// mode change, under the prefixes a user's (or the checkout's) git config can
// pick: the headers are meta whatever their prefixes, and a changed line that
// reads like a header is still a change.
const gitDiff = (src, dst) => {
  const [a, b] = [(path) => `${src}${path}`, (path) => `${dst}${path}`];
  return [
    `diff --git ${a('bin.dat')} ${b('bin.dat')}`,
    'index bdc955b..8835708 100644',
    `Binary files ${a('bin.dat')} and ${b('bin.dat')} differ`,
    `diff --git ${a('f.txt')} ${b('f.txt')}`,
    'index 6fa8db5..c23a90c 100644',
    `--- ${a('f.txt')}`,
    `+++ ${b('f.txt')}`,
    '@@ -1,3 +1,3 @@',
    ' one',
    '--- dashes',
    '+--- a/looks like a header',
    ' three',
    '\\ No newline at end of file',
    `diff --git ${a('h.txt')} ${b('h.txt')}`,
    'old mode 100644',
    'new mode 100755',
    `diff --git ${a('n.txt')} ${b('n.txt')}`,
    'new file mode 100644',
    'index 0000000..3e75765',
    '--- /dev/null',
    `+++ ${b('n.txt')}`,
    '@@ -0,0 +1 @@',
    '+new',
    '',
  ].join('\n');
};

test('a diff reads the same whatever prefixes git was configured to write', () => {
  const kinds = [
    'meta', 'meta', 'meta',
    'meta', 'meta', 'meta', 'meta', 'hunk', 'context', 'del', 'add', 'context', 'context',
    'meta', 'meta', 'meta',
    'meta', 'meta', 'meta', 'meta', 'meta', 'hunk', 'add',
  ];
  [['a/', 'b/'], ['i/', 'w/'], ['', '']].forEach(([src, dst]) => {
    const diff = gitDiff(src, dst);
    assert.deepEqual(diffLines(diff).map((line) => line.kind), kinds, `prefixes "${src}" "${dst}"`);
    assert.equal(diffStats(diff), '4 files changed · +2 −1', `prefixes "${src}" "${dst}"`);
  });
});

test("a merge conflict's combined diff reads each parent's column", () => {
  const diff = [
    'diff --cc x.txt',
    'index 1af5fa9,179377d..0000000',
    '--- a/x.txt',
    '+++ b/x.txt',
    '@@@ -1,3 -1,3 +1,7 @@@',
    '  a',
    '++<<<<<<< HEAD',
    ' +B main',
    '++=======',
    '+ B other',
    '++>>>>>>> other',
    ' -gone from one side',
    '  c',
  ].join('\n');
  assert.deepEqual(diffLines(diff).map((line) => line.kind), [
    'meta', 'meta', 'meta', 'meta', 'hunk', 'context', 'add', 'add', 'add', 'add', 'add', 'del', 'context',
  ]);
  assert.equal(diffStats(diff), '1 file changed · +5 −1');
});

test('a poll gives up on a refusal, or after failing too often in a row', () => {
  // Refused: signed out, forbidden, not found. Asking again changes nothing.
  assert.equal(pollGivesUp(401, 1), true);
  assert.equal(pollGivesUp(403, 1), true);
  assert.equal(pollGivesUp(422, 1), true);
  // A server error or no answer at all is worth a few more tries.
  assert.equal(pollGivesUp(500, 1), false);
  assert.equal(pollGivesUp(null, 1), false);
  assert.equal(pollGivesUp(503, MAX_POLL_FAILURES - 1), false);
  assert.equal(pollGivesUp(503, MAX_POLL_FAILURES), true);
  assert.equal(pollGivesUp(null, MAX_POLL_FAILURES), true);
});
