// The dashboard's client-side routes: which view a URL opens, which URL a
// view pushes, and how the sidebar lists the views.
//
// Paths here are mount-relative ('/traces', '' for the mount root). Callers
// convert with dashboardPath() and dashboardRelativePath(), because the
// engine can be mounted anywhere.
//
// A view is a key of the renderers in pages/Dashboard.jsx. Adding one means
// a row in DASHBOARD_ROUTES, an item in DASHBOARD_NAV when the sidebar lists
// it, and its renderer.
//
// `features` is what the server enabled on this dashboard (see
// dashboardFeatures). A route whose `enabled` returns false neither matches
// nor builds a path, and its nav item is left out.

const AGENT_ID = /\/agents\/(\d+)/;

function prefix(...prefixes) {
  return (path) => (prefixes.some((start) => path.startsWith(start)) ? {} : null);
}

function exact(expected) {
  return (path) => (path === expected ? {} : null);
}

// Matches anywhere in the path, and reads the agent id from the first
// /agents/:id segment.
function agentPage(pattern) {
  return (path) => (pattern.test(path) ? { agentId: path.match(AGENT_ID)?.[1] } : null);
}

function agentPagePath(suffix) {
  return ({ agent }) => (agent ? `/agents/${agent.id}${suffix}` : '');
}

const assistantEnabled = (features) => features.assistantEnabled !== false;

const agentInteractionsPage = agentPage(/\/agents\/\d+\/(interactions|history)/);

// The kinds of session a replay opens, and the timeline each one reads.
export const SESSION_KINDS = ['recording', 'context', 'run', 'scenario_result'];

const REPLAY_PATH = /^\/replay\/(?:(context|run|scenario_result)\/)?(\d+)\/?$/;

// /replay/:id opens a recording, /replay/:kind/:id a conversation (context),
// a run or an evaluation scenario's replay.
function replayPage(path) {
  const match = path.match(REPLAY_PATH);
  return match ? { sessionKind: match[1] || 'recording', sessionId: match[2] } : null;
}

// Checked in order, first match wins. Prefixes match without a segment
// boundary and the agent patterns are unanchored, so the order decides a path
// more than one row matches: '/traces/agents/5' opens traces, while
// '/replay/agents/5' and '/settings/agents/5/edit' open the agent. A view may
// have more than one row; its path is built by the first row with a `path`.
//
// Row fields:
//   view:    the view the row opens
//   match:   (path) => params, or null when the row does not match. Params:
//              agentId:     the view needs this agent loaded before it opens
//              focusServer: the MCP service to open expanded
//              replacePath: the canonical path to replace the URL with
//              sessionKind, sessionId: the session a replay opens
//   path:    the mount-relative path the view pushes, or a function of
//            { agent } returning it ('' when it has no agent to name)
//   enabled: (features) => whether this dashboard has the view
export const DASHBOARD_ROUTES = [
  { view: 'assistant', match: exact('/assistant'), path: '/assistant', enabled: assistantEnabled },
  { view: 'traces', match: prefix('/traces'), path: '/traces' },
  { view: 'metrics', match: prefix('/metrics'), path: '/metrics' },
  { view: 'interactions', match: prefix('/interactions'), path: '/interactions' },
  { view: 'tools', match: prefix('/tools'), path: '/tools' },
  {
    view: 'mcp',
    match: (path) => {
      if (!path.startsWith('/mcp')) return null;
      const key = path.match(/^\/mcp\/([^/?#]+)/)?.[1];
      return key ? { focusServer: decodeURIComponent(key) } : {};
    },
    path: '/mcp',
  },
  { view: 'evaluations', match: prefix('/evaluations'), path: '/evaluations' },
  { view: 'analytics', match: prefix('/analytics'), path: '/analytics' },
  // ProjectsView reads /projects/new and /projects/:id itself.
  { view: 'projects', match: prefix('/projects'), path: '/projects' },
  // ExplorationsView reads /explorations/:id itself.
  { view: 'exploration', match: prefix('/explorations'), path: '/explorations' },
  { view: 'builder', match: prefix('/agents/new'), path: '/agents/new' },
  {
    view: 'history',
    match: (path) => {
      const params = agentInteractionsPage(path);
      // Legacy /history URLs are rewritten to /interactions before the view
      // mounts, so nested-path parsing sees the canonical form.
      if (params && path.includes('/history')) params.replacePath = path.replace('/history', '/interactions');
      return params;
    },
    path: agentPagePath('/interactions'),
  },
  { view: 'agent-analytics', match: agentPage(/\/agents\/\d+\/analytics/), path: agentPagePath('/analytics') },
  { view: 'editor', match: agentPage(/\/agents\/\d+\/edit/), path: agentPagePath('/edit') },
  { view: 'runner', match: agentPage(/\/agents\/\d+\/run/), path: agentPagePath('/run') },
  // A bare /agents/:id opens the agent's interactions.
  { view: 'history', match: agentPage(/\/agents\/\d+\/?$/) },
  { view: 'replay', match: replayPage },
  // /replay without a session id opens the index too.
  { view: 'sessions', match: prefix('/sessions', '/replay'), path: '/sessions' },
  { view: 'sandbox', match: prefix('/sandbox', '/demo'), path: '/sandbox' },
  { view: 'organization', match: prefix('/organization'), path: '/organization' },
  { view: 'settings', match: prefix('/settings'), path: '/settings' },
];

// The view at the mount root, and for any path no route matches.
export const DEFAULT_VIEW = 'list';

// The sidebar's sections, in display order. `icon` names a glyph in
// ICONS.nav (utils/designTokens.js); `glyph` is the character itself.
// `badge` names a count the sidebar is given. An `attention` badge is drawn
// in the warning tone, is left out while its count is zero, and says what it
// counts in `badgeTitle`. `also` lists views the item is shown as current for.
export const DASHBOARD_NAV = [
  {
    id: 'agents',
    label: null,
    items: [
      { view: 'assistant', label: 'Ask ActiveAgents', glyph: '>' },
      { view: 'list', label: 'Agents', icon: 'agents', badge: 'agentCount' },
      { view: 'builder', label: 'New Agent', icon: 'newAgent' },
      { view: 'sandbox', label: 'Run Agents', icon: 'demo' },
      { view: 'projects', label: 'Projects', glyph: '</>' },
    ],
  },
  {
    id: 'observability',
    label: 'Observability',
    items: [
      { view: 'traces', label: 'Traces', icon: 'traces' },
      {
        view: 'interactions',
        label: 'Interactions',
        icon: 'interactions',
        badge: 'pendingInputCount',
        badgeTone: 'attention',
        badgeTitle: 'requests waiting for an answer',
      },
      { view: 'tools', label: 'Tools', icon: 'tools' },
      { view: 'mcp', label: 'MCP Services', icon: 'mcp' },
      { view: 'metrics', label: 'Metrics', icon: 'metrics' },
      { view: 'evaluations', label: 'Evaluations', icon: 'evaluations' },
      { view: 'sessions', label: 'Sessions', icon: 'replay', also: ['replay'] },
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

// Returns the features the routes are gated on, from the meta the server
// rendered. The assistant is on unless the server turned it off.
export function dashboardFeatures(meta = {}) {
  return { assistantEnabled: meta.assistantEnabled !== false };
}

// Returns whether this dashboard has the view. A view without a gated route
// always has one, including views no route names.
export function isDashboardViewEnabled(view, features = {}) {
  return DASHBOARD_ROUTES.every((route) => route.view !== view || !route.enabled || route.enabled(features));
}

// Returns `{ view, ...params }` for a mount-relative path (see DASHBOARD_ROUTES
// for the params), or the default view when no enabled route matches. A
// malformed escape in an /mcp/:server path throws URIError.
export function matchDashboardRoute(path, features = {}) {
  for (const route of DASHBOARD_ROUTES) {
    if (route.enabled && !route.enabled(features)) continue;
    const params = route.match(path);
    if (params) return { view: route.view, ...params };
  }
  return { view: DEFAULT_VIEW };
}

// Returns the mount-relative path a view pushes: '' for the mount root, for a
// view no route builds a path for, and for an agent page given no agent.
// Returns null when this dashboard does not have the view.
export function dashboardViewPath(view, { agent = null, features = {} } = {}) {
  if (!isDashboardViewEnabled(view, features)) return null;
  const route = DASHBOARD_ROUTES.find((candidate) => candidate.view === view && candidate.path !== undefined);
  if (!route) return '';
  return (typeof route.path === 'function' ? route.path({ agent }) : route.path) || '';
}

// Returns the view whose sidebar item is current while `view` is open.
export function navView(view) {
  for (const section of DASHBOARD_NAV) {
    const item = section.items.find((candidate) => candidate.also?.includes(view));
    if (item) return item.view;
  }
  return view;
}

// Returns the mount-relative path that replays a session, or null for a
// kind SESSION_KINDS does not name or an id that is not a positive integer.
export function sessionReplayPath(kind, id) {
  if (!SESSION_KINDS.includes(kind) || !/^[1-9]\d*$/.test(String(id))) return null;
  return kind === 'recording' ? `/replay/${id}` : `/replay/${kind}/${id}`;
}

// Returns DASHBOARD_NAV without the items for views this dashboard does not
// have.
export function dashboardNavSections(features = {}) {
  return DASHBOARD_NAV.map((section) => ({
    ...section,
    items: section.items.filter((item) => isDashboardViewEnabled(item.view, features)),
  }));
}
