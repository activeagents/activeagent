import assert from 'node:assert/strict';
import test from 'node:test';
import {
  allToolRows,
  changeCount,
  fmtAgo,
  fmtDuration,
  mcpServersFor,
  rosterStats,
  serviceRows,
  serviceState,
  toolGroups,
  toolsFor,
} from '../utils/toolRoster.mjs';

// The Tools tab derives everything from two inputs: the roster endpoint's
// payload and the agent's own configuration as the editor currently holds it.
// These pin the rules that live only in that derivation — what an absent tool
// list means, what is editable, and what a save writes back.

const payload = () => ({
  usage_available: true,
  services: [
    {
      key: 'playwright',
      name: 'Playwright',
      status: 'available',
      tools: [
        { name: 'browser_navigate', description: 'Opens a URL.', calls: 3, errors: 0, avg_duration_ms: 820, last_seen: null },
        { name: 'browser_click', description: 'Clicks an element.', calls: 0, errors: 0, avg_duration_ms: null, last_seen: null },
      ],
    },
    { key: 'git', name: 'Git', status: 'available', tools: [{ name: 'git_status', calls: 0, errors: 0 }] },
  ],
  tools: [
    // A schema tool: offered only while the roster names it, so switchable.
    { key: 'find_tickets', name: 'find_tickets', source: 'agent_defined', description: 'Find tickets.', enabled: false, editable: true, calls: 8, errors: 0, avg_duration_ms: 13 },
    // A tool the agent class declares in code: the dashboard reports it.
    { key: 'refund_invoice', name: 'refund_invoice', source: 'agent_defined', description: 'Refund an invoice.', enabled: true, editable: false, calls: 2, errors: 0, avg_duration_ms: 40 },
    { key: 'memory', name: 'memory', source: 'dashboard', description: 'Durable notes.', enabled: true, editable: true, calls: 0, errors: 0, avg_duration_ms: null },
    { key: 'terminal', name: 'terminal', source: 'dashboard', description: 'Shell.', enabled: false, editable: true, calls: 0, errors: 0, avg_duration_ms: null },
  ],
});

test('a service entry naming no tools offers everything the server serves', () => {
  const state = serviceState(payload(), ['playwright']);

  assert.equal(state.playwright.on, true);
  assert.deepEqual(state.playwright.tools, { browser_navigate: true, browser_click: true });
  assert.equal(state.git.on, false);
});

test('a service entry naming some of its tools offers only those', () => {
  const state = serviceState(payload(), [{ key: 'playwright', tools: ['browser_navigate'] }]);

  assert.deepEqual(state.playwright.tools, { browser_navigate: true, browser_click: false });
});

test('a partly narrowed service says how many of its tools are off', () => {
  const state = serviceState(payload(), [{ key: 'playwright', tools: ['browser_navigate'] }]);
  const [playwright] = serviceRows(payload(), state, {});

  assert.equal(playwright.toolsLabel, '1/2');
  assert.equal(playwright.partial, true);
  assert.equal(playwright.partialLabel, '1 tool off');
});

test('the search filters services by name, description and the tools they serve', () => {
  const state = serviceState(payload(), []);
  const byTool = serviceRows(payload(), state, { query: 'browser_click' });

  assert.deepEqual(byTool.map((service) => service.key), ['playwright']);
  assert.deepEqual(serviceRows(payload(), state, { query: 'git' }).map((service) => service.key), ['git']);
  assert.deepEqual(serviceRows(payload(), state, { query: 'nothing' }), []);
});

test('the enabled filter follows the edit buffer rather than the saved record', () => {
  const state = serviceState(payload(), ['git']);

  assert.deepEqual(serviceRows(payload(), state, { filter: 'enabled' }).map((service) => service.key), ['git']);
});

test('an enabled service contributes its offered tools to the roster, a disabled one none', () => {
  const on = serviceState(payload(), [{ key: 'playwright', tools: ['browser_navigate'] }]);

  const rows = allToolRows(payload(), on, ['memory']);
  const mcp = rows.filter((row) => row.source === 'mcp');

  assert.deepEqual(mcp.map((row) => row.name), ['browser_navigate']);
  assert.equal(mcp[0].server, 'Playwright');
  assert.equal(mcp[0].editable, false);
  assert.equal(allToolRows(payload(), serviceState(payload(), []), []).some((row) => row.source === 'mcp'), false);
});

test('schema tools and capabilities follow the roster; a code-declared tool is always on', () => {
  const state = serviceState(payload(), []);
  const byKey = (tools) => Object.fromEntries(allToolRows(payload(), state, tools).map((row) => [row.key, row]));

  const off = byKey(['memory']);
  assert.equal(off.find_tickets.on, false);
  assert.equal(off.find_tickets.editable, true);
  assert.equal(off.refund_invoice.on, true);
  assert.equal(off.refund_invoice.editable, false);
  assert.equal(off.memory.on, true);
  assert.equal(off.terminal.on, false);

  assert.equal(byKey(['memory', 'find_tickets']).find_tickets.on, true);
});

test('groups carry their own counts and only the ones with a switch offer bulk controls', () => {
  const state = serviceState(payload(), ['playwright']);
  const groups = Object.fromEntries(toolGroups(payload(), state, ['memory'], {}).map((group) => [group.source, group]));

  // The code-declared tool is on, the schema tool is not named by the roster.
  assert.equal(groups.agent_defined.countLabel, '1/2 on');
  assert.equal(groups.agent_defined.editable, true);
  assert.equal(groups.dashboard.countLabel, '1/2 on');
  assert.equal(groups.dashboard.editable, true);
  assert.equal(groups.mcp.countLabel, '2 offered');
  assert.equal(groups.mcp.editable, false);
});

test('"enabled only" hides what is off, and a group with no rows left keeps its heading', () => {
  const state = serviceState(payload(), []);
  const groups = Object.fromEntries(
    toolGroups(payload(), state, ['memory'], { enabledOnly: true }).map((group) => [group.source, group]),
  );

  assert.deepEqual(groups.dashboard.rows.map((row) => row.key), ['memory']);
  assert.equal(groups.dashboard.total, 2);
  // The heading counts the roster, not what the filter left visible.
  assert.equal(groups.dashboard.countLabel, '1/2 on');
  assert.equal(groups.dashboard.enabledCount, 1);
});

test('a search narrows the rows without changing what the counts report', () => {
  const state = serviceState(payload(), []);
  const [dashboard] = toolGroups(payload(), state, ['memory', 'terminal'], { query: 'terminal' })
    .filter((group) => group.source === 'dashboard');

  assert.deepEqual(dashboard.rows.map((row) => row.key), ['terminal']);
  assert.equal(dashboard.countLabel, '2/2 on');
  assert.equal(dashboard.enabledCount, 2);
});

test('the tiles count direct and MCP tools separately and flag a long unused tail', () => {
  const state = serviceState(payload(), ['playwright']);
  const stats = Object.fromEntries(rosterStats(payload(), state, ['memory'], { range: '7d' }).map((stat) => [stat.key, stat]));

  // Direct: the code-declared tool and memory. find_tickets is off, so it
  // is not counted as enabled however many calls the window recorded.
  assert.equal(stats.tools.value, '4');
  assert.equal(stats.tools.sub, '2 direct · 2 offered through MCP');
  assert.equal(stats.services.value, '1/2');
  assert.equal(stats.services.sub, 'on for this agent: Playwright');
  assert.equal(stats.calls.value, '13');
  assert.equal(stats.calls.sub, '0 errors in the last 7d · traced');
  assert.equal(stats.unused.value, '2');
  assert.equal(stats.unused.tone, null);
});

test('usage reads as unavailable rather than as zero when nothing was recorded', () => {
  const body = { ...payload(), usage_available: false };
  const stats = Object.fromEntries(rosterStats(body, serviceState(body, []), [], {}).map((stat) => [stat.key, stat]));

  assert.equal(stats.calls.value, '—');
  assert.equal(stats.unused.value, '—');
});

test('the pending count is one per toggle that differs from the saved roster', () => {
  const body = payload();
  const saved = { tools: ['memory'], mcpServers: [] };

  assert.equal(changeCount(body, saved, saved), 0);
  // One service on, and one of its two tools left off: two differences.
  assert.equal(
    changeCount(body, { tools: ['memory'], mcpServers: [{ key: 'playwright', tools: ['browser_navigate'] }] }, saved),
    2,
  );
  assert.equal(changeCount(body, { tools: ['memory', 'terminal'], mcpServers: [] }, saved), 1);
  // Switching a schema tool is a change like any other; a code-declared name is not a toggle.
  assert.equal(changeCount(body, { tools: ['memory', 'find_tickets'], mcpServers: [] }, saved), 1);
  assert.equal(changeCount(body, { tools: ['memory', 'refund_invoice'], mcpServers: [] }, saved), 0);
});

test('a save writes no tool list for a service offering everything, and one when it narrows', () => {
  const body = payload();
  const all = serviceState(body, ['playwright']);
  const narrowed = serviceState(body, [{ key: 'playwright', tools: ['browser_navigate'] }]);

  // A server that was named as a bare string and still offers everything
  // stays a bare string: a round-trip must not rewrite what it did not change.
  assert.deepEqual(mcpServersFor(body, all, ['playwright']), ['playwright']);
  assert.deepEqual(mcpServersFor(body, all, []), [{ key: 'playwright', name: 'Playwright' }]);
  assert.deepEqual(mcpServersFor(body, narrowed, ['playwright']), [{ key: 'playwright', name: 'Playwright', tools: ['browser_navigate'] }]);
});

test('a save keeps a service the roster does not describe, and its connection details', () => {
  const body = payload();
  const previous = [{ key: 'booking', url: 'https://booking.internal/mcp' }, { key: 'playwright', url: 'http://local/mcp' }];
  const state = serviceState(body, previous);

  assert.deepEqual(mcpServersFor(body, state, previous), [
    { key: 'playwright', url: 'http://local/mcp' },
    { key: 'booking', url: 'https://booking.internal/mcp' },
  ]);
});

test('a save writes the switchable rows that are on, keeping names it does not know', () => {
  const body = payload();

  assert.deepEqual(toolsFor(body, ['memory', 'terminal']), ['memory', 'terminal']);
  assert.deepEqual(toolsFor(body, ['legacy_tool', 'memory']), ['legacy_tool', 'memory']);
  // A schema tool is written when it is on and dropped when it is not.
  assert.deepEqual(toolsFor(body, ['find_tickets', 'memory']), ['find_tickets', 'memory']);
  assert.deepEqual(toolsFor(body, ['memory']), ['memory']);
  // A code-declared name is not a row the dashboard writes; it passes through untouched.
  assert.deepEqual(toolsFor(body, ['refund_invoice']), ['refund_invoice']);
  assert.deepEqual(toolsFor(body, []), []);
});

test('durations and last-seen read the way the columns are sized for', () => {
  assert.equal(fmtDuration(13), '13ms');
  assert.equal(fmtDuration(1240), '1.2s');
  assert.equal(fmtDuration(null), '—');

  const now = Date.parse('2026-03-01T12:00:00Z');
  assert.equal(fmtAgo(null, now), 'never');
  assert.equal(fmtAgo('2026-03-01T11:48:00Z', now), '12m ago');
  assert.equal(fmtAgo('2026-03-01T10:00:00Z', now), '2h ago');
  assert.equal(fmtAgo('2026-02-26T12:00:00Z', now), '3d ago');
});
