import assert from 'node:assert/strict';
import test from 'node:test';

// The URLs the dashboard answers, the view each one opens, the URL each view
// pushes, and the sidebar's nav lists. The tables below were recorded from
// pages/Dashboard.jsx and Sidebar.jsx before routing moved into one table, so
// they pin that move to no change in behaviour.

// ---------------------------------------------------------------------------
// Transcription of the routing in pages/Dashboard.jsx (applyPath and
// navigateTo), Sidebar.jsx (agentItems, observabilityItems, workspaceItems)
// and utils/dashboardPath.js, with the mount and features as arguments.

function mountedPath(mountPath, path = '') {
  const base = (mountPath || '').replace(/\/$/, '');
  return `${base}${path}` || '/';
}

function mountRelativePath(mountPath, pathname) {
  const base = (mountPath || '').replace(/\/$/, '');
  if (base && (pathname === base || pathname.startsWith(`${base}/`))) {
    return pathname.slice(base.length) || '/';
  }
  return pathname;
}

function matchDashboardRoute(path, { assistantEnabled = true } = {}) {
  if (path === '/assistant' && assistantEnabled) {
    return { view: 'assistant' };
  } else if (path.startsWith('/traces')) {
    return { view: 'traces' };
  } else if (path.startsWith('/metrics')) {
    return { view: 'metrics' };
  } else if (path.startsWith('/interactions')) {
    return { view: 'interactions' };
  } else if (path.startsWith('/tools')) {
    return { view: 'tools' };
  } else if (path.startsWith('/mcp')) {
    const key = path.match(/^\/mcp\/([^/?#]+)/)?.[1];
    return key ? { view: 'mcp', focusServer: decodeURIComponent(key) } : { view: 'mcp' };
  } else if (path.startsWith('/evaluations')) {
    return { view: 'evaluations' };
  } else if (path.startsWith('/analytics')) {
    return { view: 'analytics' };
  } else if (path.startsWith('/agents/new')) {
    return { view: 'builder' };
  } else if (path.match(/\/agents\/\d+\/(interactions|history)/)) {
    const id = path.match(/\/agents\/(\d+)/)?.[1];
    const route = { view: 'history', agentId: id };
    if (path.includes('/history')) route.replacePath = path.replace('/history', '/interactions');
    return route;
  } else if (path.match(/\/agents\/\d+\/analytics/)) {
    return { view: 'agent-analytics', agentId: path.match(/\/agents\/(\d+)/)?.[1] };
  } else if (path.match(/\/agents\/\d+\/edit/)) {
    return { view: 'editor', agentId: path.match(/\/agents\/(\d+)/)?.[1] };
  } else if (path.match(/\/agents\/\d+\/run/)) {
    return { view: 'runner', agentId: path.match(/\/agents\/(\d+)/)?.[1] };
  } else if (path.match(/\/agents\/\d+\/?$/)) {
    return { view: 'history', agentId: path.match(/\/agents\/(\d+)/)?.[1] };
  } else if (path.startsWith('/replay')) {
    return { view: 'replay' };
  } else if (path.startsWith('/sandbox') || path.startsWith('/demo')) {
    return { view: 'sandbox' };
  } else if (path.startsWith('/organization')) {
    return { view: 'organization' };
  } else if (path.startsWith('/settings')) {
    return { view: 'settings' };
  }
  return { view: 'list' };
}

function dashboardViewPath(view, { agent = null, features: { assistantEnabled = true } = {} } = {}) {
  if (view === 'assistant' && !assistantEnabled) return null;
  let path = '';
  if (view === 'assistant') path = '/assistant';
  else if (view === 'builder') path = '/agents/new';
  else if (view === 'editor' && agent) path = `/agents/${agent.id}/edit`;
  else if (view === 'runner' && agent) path = `/agents/${agent.id}/run`;
  else if (view === 'agent-analytics' && agent) path = `/agents/${agent.id}/analytics`;
  else if (view === 'history' && agent) path = `/agents/${agent.id}/interactions`;
  else if (view === 'analytics') path = '/analytics';
  else if (view === 'traces') path = '/traces';
  else if (view === 'metrics') path = '/metrics';
  else if (view === 'interactions') path = '/interactions';
  else if (view === 'tools') path = '/tools';
  else if (view === 'mcp') path = '/mcp';
  else if (view === 'evaluations') path = '/evaluations';
  else if (view === 'replay') path = '/replay';
  else if (view === 'sandbox') path = '/sandbox';
  else if (view === 'organization') path = '/organization';
  else if (view === 'settings') path = '/settings';
  return path;
}

function dashboardNavSections({ assistantEnabled = true } = {}) {
  return [
    {
      id: 'agents',
      label: null,
      items: [
        ...(assistantEnabled ? [{ view: 'assistant', label: 'Ask ActiveAgents', glyph: '>' }] : []),
        { view: 'list', label: 'Agents', icon: 'agents', badge: 'agentCount' },
        { view: 'builder', label: 'New Agent', icon: 'newAgent' },
        { view: 'sandbox', label: 'Run Agents', icon: 'demo' },
      ],
    },
    {
      id: 'observability',
      label: 'Observability',
      items: [
        { view: 'traces', label: 'Traces', icon: 'traces' },
        { view: 'interactions', label: 'Interactions', icon: 'interactions' },
        { view: 'tools', label: 'Tools', icon: 'tools' },
        { view: 'mcp', label: 'MCP Services', icon: 'mcp' },
        { view: 'metrics', label: 'Metrics', icon: 'metrics' },
        { view: 'evaluations', label: 'Evaluations', icon: 'evaluations' },
        { view: 'replay', label: 'Session Replay', icon: 'replay' },
      ],
    },
    {
      id: 'workspace',
      label: 'Workspace',
      items: [
        { view: 'organization', label: 'Organization', glyph: '🏢' },
        { view: 'settings', label: 'Settings', glyph: '⚙️' },
      ],
    },
  ];
}

// ---------------------------------------------------------------------------

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
  ['/replay', 'replay'],
  ['/replay/9', 'replay'],
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
  ['traces', null, '/traces'],
  ['metrics', null, '/metrics'],
  ['interactions', null, '/interactions'],
  ['tools', null, '/tools'],
  ['mcp', null, '/mcp'],
  ['evaluations', null, '/evaluations'],
  ['replay', null, '/replay'],
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
  ]],
  ['observability', 'Observability', [
    ['traces', 'Traces', { icon: 'traces' }],
    ['interactions', 'Interactions', { icon: 'interactions' }],
    ['tools', 'Tools', { icon: 'tools' }],
    ['mcp', 'MCP Services', { icon: 'mcp' }],
    ['metrics', 'Metrics', { icon: 'metrics' }],
    ['evaluations', 'Evaluations', { icon: 'evaluations' }],
    ['replay', 'Session Replay', { icon: 'replay' }],
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
