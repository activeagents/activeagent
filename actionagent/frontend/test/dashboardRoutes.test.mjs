import assert from 'node:assert/strict';
import test from 'node:test';

import {
  SESSION_KINDS,
  dashboardFeatures,
  dashboardNavSections,
  dashboardViewPath,
  isDashboardViewEnabled,
  matchDashboardRoute,
  navView,
  sessionReplayPath,
} from '../utils/dashboardRoutes.mjs';
import { mountedPath, mountRelativePath } from '../utils/mountPath.mjs';

// The URLs the dashboard answers, the view each one opens, the URL each view
// pushes, and the sidebar's sections. The expectations are written out
// rather than derived from DASHBOARD_ROUTES, so an edit to the table that
// changes what an existing URL opens fails here.

const ON = { assistantEnabled: true };
const OFF = { assistantEnabled: false };
const MOUNTS = ['', '/', '/dashboard', '/dashboard/', '/admin/agents', '/demo'];

// [mount-relative path, view it opens, extra params]. Prefix matches have no
// segment boundary, the agent patterns are unanchored, and the order of the
// checks decides a path that more than one of them matches.
const EXPECTED_MATCHES = [
  ['/', 'list'],
  ['', 'list'],
  ['/assistant', 'assistant'],
  ['/assistant/', 'list'],
  ['/assistant/x', 'list'],
  ['/traces', 'traces'],
  ['/traces/abc', 'traces'],
  ['/tracesx', 'traces'],
  ['/traces/agents/5/edit', 'traces'],
  ['/metrics', 'metrics'],
  ['/metrics/x', 'metrics'],
  ['/interactions', 'interactions'],
  ['/interactions/7', 'interactions'],
  ['/tools', 'tools'],
  ['/tools/x', 'tools'],
  ['/mcp', 'mcp'],
  ['/mcp/', 'mcp'],
  ['/mcpx', 'mcp'],
  ['/mcp/my-server', 'mcp', { focusServer: 'my-server' }],
  ['/mcp/my-server/tools', 'mcp', { focusServer: 'my-server' }],
  ['/mcp/a%20b', 'mcp', { focusServer: 'a b' }],
  ['/evaluations', 'evaluations'],
  ['/evaluations/3', 'evaluations'],
  ['/evaluations/3/runs/4', 'evaluations'],
  ['/evaluations/3/runs/4/report', 'evaluations'],
  ['/analytics', 'analytics'],
  ['/analytics/x', 'analytics'],
  ['/projects', 'projects'],
  ['/projects/new', 'projects'],
  ['/projects/5', 'projects'],
  ['/projects/agents/5/edit', 'projects'],
  ['/explorations', 'exploration'],
  ['/explorations/7', 'exploration'],
  ['/explorations/agents/5/edit', 'exploration'],
  ['/agents/new', 'builder'],
  ['/agents/new/x', 'builder'],
  ['/agents/newer', 'builder'],
  ['/agents/new/agents/5/edit', 'builder'],
  ['/agents/5', 'history', { agentId: '5' }],
  ['/agents/5/', 'history', { agentId: '5' }],
  ['/agents/12/interactions', 'history', { agentId: '12' }],
  ['/agents/12/interactions/40', 'history', { agentId: '12' }],
  ['/agents/12/history', 'history', { agentId: '12', replacePath: '/agents/12/interactions' }],
  ['/agents/12/history/40', 'history', { agentId: '12', replacePath: '/agents/12/interactions/40' }],
  ['/agents/12/history/analytics', 'history', { agentId: '12', replacePath: '/agents/12/interactions/analytics' }],
  ['/agents/12/analytics', 'agent-analytics', { agentId: '12' }],
  ['/agents/12/analytics/edit', 'agent-analytics', { agentId: '12' }],
  ['/agents/1/analytics/agents/2', 'agent-analytics', { agentId: '1' }],
  ['/agents/12/edit', 'editor', { agentId: '12' }],
  ['/agents/12/edit/run', 'editor', { agentId: '12' }],
  ['/agents/12/run/edit', 'runner', { agentId: '12' }],
  ['/agents/12/run', 'runner', { agentId: '12' }],
  ['/agents/12/runs', 'runner', { agentId: '12' }],
  ['/agents/12/runner/x', 'runner', { agentId: '12' }],
  ['/agents/12/other', 'list'],
  ['/agents/abc', 'list'],
  ['/agents/abc/edit', 'list'],
  ['/agents', 'list'],
  ['/agents/', 'list'],
  ['/x/agents/7/edit', 'editor', { agentId: '7' }],
  ['/sessions', 'sessions'],
  ['/sessions/x', 'sessions'],
  ['/replay', 'sessions'],
  ['/replay/', 'sessions'],
  ['/replay/x', 'sessions'],
  ['/replay/9', 'replay', { sessionKind: 'recording', sessionId: '9' }],
  ['/replay/9/', 'replay', { sessionKind: 'recording', sessionId: '9' }],
  ['/replay/context/4', 'replay', { sessionKind: 'context', sessionId: '4' }],
  ['/replay/run/12', 'replay', { sessionKind: 'run', sessionId: '12' }],
  ['/replay/scenario_result/7', 'replay', { sessionKind: 'scenario_result', sessionId: '7' }],
  ['/replay/recording/7', 'sessions'],
  ['/replay/context/x', 'sessions'],
  ['/replay/context/4/extra', 'sessions'],
  ['/replay/agents/5', 'history', { agentId: '5' }],
  ['/sandbox', 'sandbox'],
  ['/sandbox/x', 'sandbox'],
  ['/demo', 'sandbox'],
  ['/demo/x', 'sandbox'],
  ['/organization', 'organization'],
  ['/organization/x', 'organization'],
  ['/settings', 'settings'],
  ['/settings/x', 'settings'],
  ['/settings/agents/3/edit', 'editor', { agentId: '3' }],
  ['/unknown', 'list'],
  ['/console/traces', 'list'],
];

for (const [path, view, params = {}] of EXPECTED_MATCHES) {
  test(`${JSON.stringify(path)} opens ${view}`, () => {
    assert.deepEqual(matchDashboardRoute(path, ON), { view, ...params });
  });
}

test('/assistant opens the agent list when the dashboard has no assistant', () => {
  assert.deepEqual(matchDashboardRoute('/assistant', OFF), { view: 'list' });
});

test('every other path opens the same view with or without the assistant', () => {
  for (const [path] of EXPECTED_MATCHES.filter(([candidate]) => candidate !== '/assistant')) {
    assert.deepEqual(matchDashboardRoute(path, OFF), matchDashboardRoute(path, ON), path);
  }
});

test('a malformed /mcp/:server escape throws, as decodeURIComponent does', () => {
  assert.throws(() => matchDashboardRoute('/mcp/%E0%A4%A', ON), URIError);
});

const agent = { id: 12, name: 'Support bot' };
const AGENT_VIEWS = ['editor', 'runner', 'agent-analytics', 'history'];

// [view, agent passed to navigateTo, mount-relative path it pushes]. '' is the
// mount root; null means the navigation is refused and nothing is pushed.
const EXPECTED_PATHS = [
  ['list', null, ''],
  ['builder', null, '/agents/new'],
  ['editor', agent, '/agents/12/edit'],
  ['editor', null, ''],
  ['runner', agent, '/agents/12/run'],
  ['runner', null, ''],
  ['agent-analytics', agent, '/agents/12/analytics'],
  ['agent-analytics', null, ''],
  ['history', agent, '/agents/12/interactions'],
  ['history', null, ''],
  ['analytics', null, '/analytics'],
  ['projects', null, '/projects'],
  ['exploration', null, '/explorations'],
  ['traces', null, '/traces'],
  ['metrics', null, '/metrics'],
  ['interactions', null, '/interactions'],
  ['tools', null, '/tools'],
  ['mcp', null, '/mcp'],
  ['evaluations', null, '/evaluations'],
  ['sessions', null, '/sessions'],
  ['replay', null, ''],
  ['sandbox', null, '/sandbox'],
  ['organization', null, '/organization'],
  ['settings', null, '/settings'],
  ['assistant', null, '/assistant'],
  ['unknown-view', null, ''],
  ['traces', agent, '/traces'],
];

for (const [view, withAgent, path] of EXPECTED_PATHS) {
  test(`${view}${withAgent ? ' with an agent' : ''} pushes ${JSON.stringify(path)}`, () => {
    assert.equal(dashboardViewPath(view, { agent: withAgent, features: ON }), path);
  });
}

test('the assistant is refused when the dashboard has none', () => {
  assert.equal(dashboardViewPath('assistant', { features: OFF }), null);
  assert.equal(dashboardViewPath('traces', { features: OFF }), '/traces');
});

test('features default to a dashboard with the assistant', () => {
  assert.equal(dashboardViewPath('assistant'), '/assistant');
  assert.deepEqual(matchDashboardRoute('/assistant'), { view: 'assistant' });
});

test('every view a path is pushed for opens that view again, under every mount', () => {
  for (const mount of MOUNTS) {
    for (const [view, withAgent, path] of EXPECTED_PATHS) {
      if (path === null || view === 'unknown-view' || (path === '' && view !== 'list')) continue;
      const url = mountedPath(mount, path);
      const route = matchDashboardRoute(mountRelativePath(mount, url), ON);
      const expected = AGENT_VIEWS.includes(view) ? { view, agentId: String(agent.id) } : { view };
      assert.deepEqual(route, expected, `${view} at ${url} (mount ${JSON.stringify(mount)})`);
    }
  }
});

test('every expected path opens the same view under every mount', () => {
  for (const mount of MOUNTS) {
    for (const [path, view, params = {}] of EXPECTED_MATCHES) {
      if (path === '') continue;
      const url = mountedPath(mount, path);
      assert.deepEqual(matchDashboardRoute(mountRelativePath(mount, url), ON), { view, ...params }, `${url} (mount ${JSON.stringify(mount)})`);
    }
  }
});

test('a mount whose own path names a view still opens the agent list at its root', () => {
  assert.deepEqual(matchDashboardRoute(mountRelativePath('/admin/agents', '/admin/agents'), ON), { view: 'list' });
  assert.deepEqual(matchDashboardRoute(mountRelativePath('/demo', '/demo'), ON), { view: 'list' });
  assert.deepEqual(matchDashboardRoute(mountRelativePath('/demo', '/demo/sandbox'), ON), { view: 'sandbox' });
  assert.deepEqual(matchDashboardRoute(mountRelativePath('/admin/agents', '/admin/agents/agents/4/edit'), ON), { view: 'editor', agentId: '4' });
});

test('mount paths join and strip the way dashboardPath and dashboardRelativePath do', () => {
  assert.equal(mountedPath('', ''), '/');
  assert.equal(mountedPath('', '/traces'), '/traces');
  assert.equal(mountedPath('/dashboard', ''), '/dashboard');
  assert.equal(mountedPath('/dashboard/', '/traces'), '/dashboard/traces');
  assert.equal(mountedPath(undefined, '/x'), '/x');
  assert.equal(mountRelativePath('/dashboard', '/dashboard'), '/');
  assert.equal(mountRelativePath('/dashboard', '/dashboard/'), '/');
  assert.equal(mountRelativePath('/dashboard', '/dashboard/traces'), '/traces');
  assert.equal(mountRelativePath('/dashboard', '/dashboards/traces'), '/dashboards/traces');
  assert.equal(mountRelativePath('/dashboard', '/agents/5/interactions'), '/agents/5/interactions');
  assert.equal(mountRelativePath('', '/traces'), '/traces');
});

const EXPECTED_NAV = [
  ['agents', null, [
    ['assistant', 'Ask ActiveAgents', { glyph: '>' }],
    ['list', 'Agents', { icon: 'agents', badge: 'agentCount' }],
    ['builder', 'New Agent', { icon: 'newAgent' }],
    ['sandbox', 'Run Agents', { icon: 'demo' }],
    ['projects', 'Projects', { glyph: '</>' }],
  ]],
  ['observability', 'Observability', [
    ['traces', 'Traces', { icon: 'traces' }],
    ['interactions', 'Interactions', {
      icon: 'interactions', badge: 'pendingInputCount', badgeTone: 'attention', badgeTitle: 'requests waiting for an answer',
    }],
    ['tools', 'Tools', { icon: 'tools' }],
    ['mcp', 'MCP Services', { icon: 'mcp' }],
    ['metrics', 'Metrics', { icon: 'metrics' }],
    ['evaluations', 'Evaluations', { icon: 'evaluations' }],
    ['sessions', 'Sessions', { icon: 'replay', also: ['replay'] }],
  ]],
  ['workspace', 'Workspace', [
    ['organization', 'Organization', { glyph: '🏢' }],
    ['settings', 'Settings', { glyph: '⚙️' }],
  ]],
];

const expectedNav = (assistantEnabled) => EXPECTED_NAV.map(([id, label, items]) => ({
  id,
  label,
  items: items
    .filter(([view]) => assistantEnabled || view !== 'assistant')
    .map(([view, itemLabel, extra]) => ({ view, label: itemLabel, ...extra })),
}));

test('the sidebar lists its views in three sections', () => {
  assert.deepEqual(dashboardNavSections(ON), expectedNav(true));
});

test('the sidebar leaves the assistant out when the dashboard has none', () => {
  assert.deepEqual(dashboardNavSections(OFF), expectedNav(false));
  assert.deepEqual(dashboardNavSections(), expectedNav(true));
});

test('every nav item pushes a path that opens its own view', () => {
  for (const section of dashboardNavSections(ON)) {
    for (const item of section.items) {
      const path = dashboardViewPath(item.view, { features: ON });
      assert.equal(matchDashboardRoute(mountRelativePath('/dashboard', mountedPath('/dashboard', path)), ON).view, item.view, item.view);
    }
  }
});

test('the assistant is on unless the server turned it off', () => {
  assert.deepEqual(dashboardFeatures({ assistantEnabled: false }), OFF);
  assert.deepEqual(dashboardFeatures({ assistantEnabled: true }), ON);
  assert.deepEqual(dashboardFeatures({}), ON);
  assert.deepEqual(dashboardFeatures(), ON);
});

test('only a gated view can be missing from a dashboard', () => {
  assert.equal(isDashboardViewEnabled('assistant', OFF), false);
  assert.equal(isDashboardViewEnabled('assistant', ON), true);
  assert.equal(isDashboardViewEnabled('history', OFF), true);
  assert.equal(isDashboardViewEnabled('list', OFF), true);
  assert.equal(isDashboardViewEnabled('unknown-view', OFF), true);
});

test('a replay path is built for each kind of session and opens it again', () => {
  assert.equal(sessionReplayPath('recording', 9), '/replay/9');
  assert.equal(sessionReplayPath('context', '4'), '/replay/context/4');
  assert.equal(sessionReplayPath('run', 12), '/replay/run/12');
  assert.equal(sessionReplayPath('scenario_result', 7), '/replay/scenario_result/7');
  for (const mount of MOUNTS) {
    for (const kind of SESSION_KINDS) {
      const url = mountedPath(mount, sessionReplayPath(kind, 31));
      assert.deepEqual(matchDashboardRoute(mountRelativePath(mount, url), ON), { view: 'replay', sessionKind: kind, sessionId: '31' }, url);
    }
  }
});

test('no replay path is built for an unknown kind or an id that is not a positive integer', () => {
  assert.equal(sessionReplayPath('trace', 1), null);
  assert.equal(sessionReplayPath('context', 0), null);
  assert.equal(sessionReplayPath('context', '4/edit'), null);
  assert.equal(sessionReplayPath('recording', null), null);
});

test('the Sessions item is current while a replay is open', () => {
  assert.equal(navView('replay'), 'sessions');
  assert.equal(navView('sessions'), 'sessions');
  assert.equal(navView('traces'), 'traces');
});
