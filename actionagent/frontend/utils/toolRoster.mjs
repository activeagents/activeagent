// The Tools tab's derivations: what the agent's saved configuration plus the
// roster endpoint add up to, with nothing stored that can be computed.
//
// The endpoint describes the *saved* record (which services are on, which of
// their tools are allowed). Editing happens against the editor's form buffer,
// so every view here is re-derived from that buffer instead of from the
// payload's own flags — one source of truth while a roster is being changed,
// and the same rule on both sides of a save: a service entry that names no
// tools offers every tool the server serves.

export const SOURCES = ['agent_defined', 'dashboard', 'mcp'];

export const SOURCE_LABELS = {
  agent_defined: 'Agent-defined',
  dashboard: 'Dashboard',
  mcp: 'MCP',
};

export const GROUP_META = {
  agent_defined: "derived from the agent's own schema",
  dashboard: 'built into the dashboard',
  mcp: 'offered by the services above',
};

export const RANGES = [
  { value: '24h', label: '24h', hours: 24 },
  { value: '7d', label: '7d', hours: 24 * 7 },
  { value: '30d', label: '30d', hours: 24 * 30 },
];

// 13 → "13ms", 1240 → "1.2s", nothing recorded → "—".
export const fmtDuration = (ms) => {
  if (ms == null || Number.isNaN(Number(ms))) return '—';
  const n = Number(ms);
  return n >= 1000 ? `${(n / 1000).toFixed(1)}s` : `${Math.round(n)}ms`;
};

// Compact enough for a 74px column: "12m ago", "2h ago", "3d ago", "never".
export const fmtAgo = (iso, now = Date.now()) => {
  if (!iso) return 'never';
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return 'never';
  const mins = Math.floor((now - then) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
};

// An agent names a server as a bare string or as a hash carrying its key —
// both shapes reach the editor, and a round-trip must not rewrite either.
export const entryKey = (entry) => {
  if (typeof entry === 'string') return entry.trim() || null;
  if (!entry || typeof entry !== 'object') return null;
  const key = entry.key || entry.name;
  return key ? String(key).trim() || null : null;
};

// serviceKey => { on, tools: { toolName: offered } }, from the agent's
// mcp_servers as the form buffer currently holds it.
export function serviceState(payload, mcpServers = []) {
  const configured = new Map();
  (mcpServers || []).forEach((entry) => {
    const key = entryKey(entry);
    if (key) configured.set(key, entry);
  });

  const state = {};
  (payload.services || []).forEach((service) => {
    const entry = configured.get(service.key);
    const named = entry && typeof entry === 'object' && Array.isArray(entry.tools)
      ? entry.tools.map((tool) => String(tool && tool.name ? tool.name : tool))
      : null;

    state[service.key] = {
      on: configured.has(service.key),
      // No list means every tool the server serves.
      tools: Object.fromEntries(
        (service.tools || []).map((tool) => [tool.name, named === null || named.includes(tool.name)]),
      ),
    };
  });
  return state;
}

const matcher = (query) => {
  const q = String(query || '').trim().toLowerCase();
  return (...values) => !q || values.some((value) => String(value || '').toLowerCase().includes(q));
};

// The MCP services list: every service the workspace knows, in the state this
// agent has it in.
export function serviceRows(payload, state, { query = '', filter = null } = {}) {
  const hit = matcher(query);

  return (payload.services || [])
    .filter((service) => {
      if (!filter) return true;
      return filter === 'enabled' ? state[service.key]?.on : service.status === filter;
    })
    .filter((service) => hit(service.name, service.description) || (service.tools || []).some((tool) => hit(tool.name)))
    .map((service) => {
      const current = state[service.key] || { on: false, tools: {} };
      const offered = service.tools || [];
      const tools = offered.map((tool) => ({ ...tool, on: Boolean(current.tools[tool.name]) }));
      const enabled = tools.filter((tool) => tool.on);

      return {
        ...service,
        on: current.on,
        tools,
        offeredCount: offered.length,
        enabledCount: enabled.length,
        toolsLabel: `${enabled.length}/${offered.length}`,
        partial: current.on && enabled.length < offered.length,
        partialLabel: `${offered.length - enabled.length} tool off`,
      };
    });
}

// Tools a service offers are never roster rows of their own: they are
// computed from the services that are on, and edited there.
export function mcpToolRows(payload, state) {
  const rows = [];
  (payload.services || []).forEach((service) => {
    const current = state[service.key];
    if (!current || !current.on) return;

    (service.tools || []).forEach((tool) => {
      if (!current.tools[tool.name]) return;
      rows.push({
        ...tool,
        key: `${service.key}:${tool.name}`,
        source: 'mcp',
        editable: false,
        enabled: true,
        server: service.name,
        serverKey: service.key,
      });
    });
  });
  return rows;
}

// Every row the Tools card can show, before filtering: the agent's own
// schema-derived tools, the dashboard's capabilities, and whatever the
// enabled services offer.
export function allToolRows(payload, state, tools = []) {
  const selected = new Set((tools || []).map(String));

  return (payload.tools || [])
    .map((tool) => ({
      ...tool,
      // A schema-derived tool is reported, not selected; a capability is on
      // when the agent's roster names it.
      on: tool.editable ? selected.has(tool.key) : tool.enabled !== false,
    }))
    .concat(mcpToolRows(payload, state).map((row) => ({ ...row, on: true })));
}

export function toolGroups(payload, state, tools, { query = '', source = null, enabledOnly = false } = {}) {
  const hit = matcher(query);
  const rows = allToolRows(payload, state, tools);
  const visible = rows
    .filter((row) => !source || row.source === source)
    .filter((row) => !enabledOnly || row.on)
    .filter((row) => hit(row.name, row.description));

  return SOURCES.map((source_) => {
    const all = rows.filter((row) => row.source === source_);
    const editable = all.some((row) => row.editable);
    // Counts describe the roster, not the filtered view: narrowing the list
    // with a search must not change what the header says is enabled.
    const on = all.filter((row) => row.on).length;

    return {
      source: source_,
      name: SOURCE_LABELS[source_],
      meta: `${GROUP_META[source_]} · ${all.length} ${all.length === 1 ? 'tool' : 'tools'}`,
      countLabel: editable ? `${on}/${all.length} on` : `${all.length} offered`,
      editable,
      total: all.length,
      enabledCount: on,
      keys: all.map((row) => row.key),
      rows: visible.filter((row) => row.source === source_),
    };
  }).filter((group) => group.total > 0);
}

// The four tiles over the lists. Usage figures read "—" until something has
// been recorded in the window, rather than as honest-looking zeroes.
export function rosterStats(payload, state, tools, { range = '7d' } = {}) {
  const rows = allToolRows(payload, state, tools);
  const usage = payload.usage_available !== false;
  const services = payload.services || [];
  const enabledServices = services.filter((service) => state[service.key]?.on);

  const direct = rows.filter((row) => row.source !== 'mcp' && row.on);
  const offered = rows.filter((row) => row.source === 'mcp');
  const calls = rows.reduce((total, row) => total + (row.calls || 0), 0);
  const errors = rows.reduce((total, row) => total + (row.errors || 0), 0);
  const neverCalled = rows.filter((row) => row.on && !row.calls).length;

  return [
    {
      key: 'tools',
      label: 'Tools enabled',
      value: String(direct.length + offered.length),
      sub: `${direct.length} direct · ${offered.length} offered through MCP`,
    },
    {
      key: 'services',
      label: 'MCP services',
      value: `${enabledServices.length}/${services.length}`,
      sub: enabledServices.length
        ? `on for this agent: ${enabledServices.map((service) => service.name).join(', ')}`
        : 'none enabled for this agent',
    },
    {
      key: 'calls',
      label: 'Tool calls',
      value: usage ? String(calls) : '—',
      sub: usage ? `${errors} error${errors === 1 ? '' : 's'} in the last ${range} · traced` : 'no calls recorded in this window yet',
    },
    {
      key: 'unused',
      label: 'Never called',
      value: usage ? String(neverCalled) : '—',
      sub: 'enabled but unused in this window',
      tone: usage && neverCalled > 6 ? 'warning' : null,
    },
  ];
}

// How many toggles differ from the saved roster — what the sticky bar counts
// and what drives the header's "unsaved" badge.
export function changeCount(payload, current, saved) {
  const now = serviceState(payload, current.mcpServers);
  const before = serviceState(payload, saved.mcpServers);
  let changes = 0;

  Object.keys(now).forEach((key) => {
    if (now[key].on !== before[key].on) changes += 1;
    Object.keys(now[key].tools).forEach((name) => {
      if (now[key].tools[name] !== before[key].tools[name]) changes += 1;
    });
  });

  const selected = new Set((current.tools || []).map(String));
  const wasSelected = new Set((saved.tools || []).map(String));
  (payload.tools || []).forEach((tool) => {
    if (!tool.editable) return;
    if (selected.has(tool.key) !== wasSelected.has(tool.key)) changes += 1;
  });

  return changes;
}

// The mcp_servers value to save. A service that offers everything it serves
// is written without a tool list — and one the roster doesn't describe is
// carried through untouched, since this view is not the only thing that
// writes them.
export function mcpServersFor(payload, state, previous = []) {
  const byKey = new Map();
  (previous || []).forEach((entry) => {
    const key = entryKey(entry);
    if (key) byKey.set(key, entry);
  });

  const rows = [];
  (payload.services || []).forEach((service) => {
    const current = state[service.key];
    if (!current || !current.on) return;

    const offered = (service.tools || []).map((tool) => tool.name);
    const allowed = offered.filter((name) => current.tools[name]);
    const existing = byKey.get(service.key);
    const narrowed = offered.length > 0 && allowed.length < offered.length;

    if (typeof existing === 'string' && !narrowed) {
      rows.push(existing);
      return;
    }

    const entry = existing && typeof existing === 'object'
      ? { ...existing, key: existing.key || service.key }
      : { key: service.key, name: service.name };

    if (narrowed) entry.tools = allowed;
    else delete entry.tools;

    rows.push(entry);
  });

  const known = new Set((payload.services || []).map((service) => service.key));
  (previous || []).forEach((entry) => {
    const key = entryKey(entry);
    if (key && !known.has(key)) rows.push(entry);
  });

  return rows;
}

// The tools value to save: the dashboard capabilities that are on. Rows the
// dashboard doesn't own — schema-derived and MCP — are never written to the
// roster, and names it doesn't know about are left where they were.
export function toolsFor(payload, selected = []) {
  const known = new Set((payload.tools || []).filter((tool) => tool.editable).map((tool) => tool.key));
  const kept = (selected || []).map(String).filter((name) => !known.has(name));
  const on = (payload.tools || []).filter((tool) => tool.editable && selected.includes(tool.key)).map((tool) => tool.key);
  return kept.concat(on);
}
