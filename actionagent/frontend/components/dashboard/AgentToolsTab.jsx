import React, { useState, useEffect, useCallback, useMemo } from 'react';
import { Badge, Button, Card, Chip, Empty, Glyph, MicroLabel, MonoLink, MONO, SegmentedControl } from './primitives';
import { dashboardPath, navigateTo } from '../../utils/dashboardPath';
import {
  RANGES,
  SOURCE_LABELS,
  changeCount,
  fmtAgo,
  fmtDuration,
  mcpServersFor,
  rosterStats,
  serviceRows,
  serviceState,
  toolGroups,
  toolsFor,
} from '../../utils/toolRoster.mjs';

// The agent's Tools tab: the MCP services it can be given and the tools it
// can be offered, in one list vocabulary with the usage each one has.
//
// The card grid this replaces could not answer the questions you have while
// editing a roster — what does this tool do, is it ever called, does it
// error, where does it come from — and had no way to enable an MCP service
// at all. Both lists read like the Tools and MCP Services pages, because
// they are the same rows asked a different question.
//
// Editing writes straight into the editor's form buffer, so the header's
// "unsaved" badge, the sticky bar's count and Save all follow one state.

const STATUS_TONES = { active: 'success', configured: 'info', available: 'warning', idle: 'muted' };
const SOURCE_TONES = { agent_defined: 'success', dashboard: 'success', mcp: 'info' };

const SERVICE_COLUMNS = '44px minmax(0, 1fr) 108px 60px 52px 58px 74px 26px';
const TOOL_COLUMNS = '26px minmax(0, 1fr) 108px 52px 52px 52px 74px';

const SERVICE_FILTERS = [
  { value: 'enabled', label: 'Enabled' },
  { value: 'active', label: 'Active' },
  { value: 'configured', label: 'Configured' },
  { value: 'available', label: 'Available' },
];

const headStrip = {
  padding: '7px 16px',
  gap: 10,
  alignItems: 'end',
  background: 'var(--color-muted)',
  fontFamily: MONO,
  fontSize: 10,
  fontWeight: 600,
  letterSpacing: '0.05em',
  textTransform: 'uppercase',
  color: 'var(--color-text-muted)',
};

const numeric = { fontFamily: MONO, fontSize: 11, textAlign: 'right', color: 'var(--color-text-primary)' };
const ellipsis = { whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' };

// 34×18 track, 14px knob. The only other transition on the page is the
// chevron's rotate.
function Switch({ on, onClick, title }) {
  return (
    <span
      role="switch"
      aria-checked={on}
      tabIndex={0}
      title={title}
      onClick={onClick}
      onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onClick(event); } }}
      style={{
        width: 34, height: 18, borderRadius: 999, flexShrink: 0, position: 'relative', cursor: 'pointer',
        background: on ? 'var(--color-accent-ui)' : 'var(--color-muted)',
        border: `1px solid ${on ? 'var(--color-accent-ui)' : 'var(--color-border-strong)'}`,
        transition: 'background 0.12s ease',
      }}
    >
      <span
        style={{
          position: 'absolute', top: 1, left: on ? 17 : 1, width: 14, height: 14, borderRadius: '50%',
          background: on ? '#ffffff' : 'var(--color-text-muted)', transition: 'left 0.12s ease',
        }}
      />
    </span>
  );
}

function CheckBox({ on, dim = false }) {
  return (
    <span
      aria-hidden="true"
      style={{
        width: 16, height: 16, borderRadius: 4, display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontFamily: MONO, fontSize: 10, fontWeight: 700, flexShrink: 0,
        border: `1px solid ${on ? 'var(--color-accent-ui)' : 'var(--color-border-strong)'}`,
        background: on ? 'var(--color-accent-ui)' : 'transparent',
        color: on ? 'var(--color-on-accent)' : 'transparent',
        opacity: dim ? 0.8 : 1,
      }}
    >
      {on ? 'x' : ''}
    </span>
  );
}

// A mono text button, for the bulk controls that sit inside a list.
function MicroButton({ children, onClick, disabled, title }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      title={title}
      style={{
        padding: '3px 9px', borderRadius: 6, background: 'transparent', fontFamily: MONO, fontSize: 11,
        border: '1px solid var(--color-border-strong)', color: 'var(--color-text-cell)',
        cursor: disabled ? 'not-allowed' : 'pointer', opacity: disabled ? 0.5 : 1,
      }}
    >
      {children}
    </button>
  );
}

// Both lists scroll sideways rather than crushing their numeric columns.
function ScrollBox({ children }) {
  return (
    <div style={{ overflowX: 'auto' }}>
      <div style={{ minWidth: 800 }}>{children}</div>
    </div>
  );
}

export default function AgentToolsTab({ agent, formData, updateField, onSave, hasChanges = false, isLoading }) {
  const [payload, setPayload] = useState(null);
  const [loadError, setLoadError] = useState(null);
  const [range, setRange] = useState('7d');
  const [query, setQuery] = useState('');
  const [serviceFilter, setServiceFilter] = useState(null);
  const [source, setSource] = useState(null);
  const [enabledOnly, setEnabledOnly] = useState(false);
  const [openService, setOpenService] = useState(null);
  const [closedGroups, setClosedGroups] = useState({});

  const hours = (RANGES.find((option) => option.value === range) || RANGES[1]).hours;

  useEffect(() => {
    let cancelled = false;
    setLoadError(null);

    fetch(`/api/agents/${agent.id}/tool_roster?hours=${hours}`)
      .then((response) => {
        if (!response.ok) throw new Error(`Request failed (${response.status})`);
        return response.json();
      })
      .then((body) => { if (!cancelled) setPayload(body); })
      .catch((error) => { if (!cancelled) setLoadError(error.message); });

    return () => { cancelled = true; };
  }, [agent.id, hours]);

  const empty = useMemo(() => ({ services: [], tools: [] }), []);
  const roster = payload || empty;
  // Stable identities: every view below is memoized on these.
  const selectedTools = useMemo(() => formData.tools || [], [formData.tools]);
  const configuredServers = useMemo(() => formData.mcp_servers || [], [formData.mcp_servers]);

  const state = useMemo(() => serviceState(roster, configuredServers), [roster, configuredServers]);
  const services = useMemo(
    () => serviceRows(roster, state, { query, filter: serviceFilter }),
    [roster, state, query, serviceFilter],
  );
  const groups = useMemo(
    () => toolGroups(roster, state, selectedTools, { query, source, enabledOnly }),
    [roster, state, selectedTools, query, source, enabledOnly],
  );
  const stats = useMemo(() => rosterStats(roster, state, selectedTools, { range }), [roster, state, selectedTools, range]);
  const changes = useMemo(
    () => changeCount(roster, { tools: selectedTools, mcpServers: configuredServers }, { tools: agent.tools || [], mcpServers: agent.mcp_servers || [] }),
    [roster, selectedTools, configuredServers, agent],
  );

  const usage = roster.usage_available !== false;
  const cell = (value) => (usage ? value : '—');

  // Every write goes through the form buffer, so a roster edit is unsaved
  // in exactly the way an instructions edit is.
  const writeServices = useCallback((next) => {
    updateField('mcp_servers', mcpServersFor(roster, next, configuredServers));
  }, [roster, configuredServers, updateField]);

  const toggleService = useCallback((service) => {
    const current = state[service.key];
    writeServices({ ...state, [service.key]: { ...current, on: !current.on } });
  }, [state, writeServices]);

  const toggleServiceTool = useCallback((service, tool) => {
    const current = state[service.key];
    if (!current.on) return;
    writeServices({ ...state, [service.key]: { ...current, tools: { ...current.tools, [tool.name]: !current.tools[tool.name] } } });
  }, [state, writeServices]);

  // `all` turns the service on and offers everything it serves; `none`
  // leaves it on and offers nothing.
  const setAllServiceTools = useCallback((service, on) => {
    const current = state[service.key];
    const tools = Object.fromEntries((service.tools || []).map((tool) => [tool.name, on]));
    writeServices({ ...state, [service.key]: { on: on || current.on, tools } });
  }, [state, writeServices]);

  const toggleTool = useCallback((tool) => {
    if (!tool.editable) return;
    const next = tool.on ? selectedTools.filter((name) => name !== tool.key) : [...selectedTools, tool.key];
    updateField('tools', toolsFor(roster, next));
  }, [roster, selectedTools, updateField]);

  const setGroup = useCallback((group, on) => {
    if (!group.editable) return;
    const next = on
      ? [...selectedTools, ...group.keys.filter((key) => !selectedTools.includes(key))]
      : selectedTools.filter((name) => !group.keys.includes(name));
    updateField('tools', toolsFor(roster, next));
  }, [roster, selectedTools, updateField]);

  const discard = useCallback(() => {
    updateField('tools', agent.tools || []);
    updateField('mcp_servers', agent.mcp_servers || []);
  }, [agent, updateField]);

  const enabledServices = (roster.services || []).filter((service) => state[service.key]?.on);
  const offeredMcp = groups.find((group) => group.source === 'mcp');
  const directOn = groups
    .filter((group) => group.source !== 'mcp')
    .reduce((total, group) => total + group.enabledCount, 0);
  const totalOn = directOn + (offeredMcp ? offeredMcp.total : 0);
  const totalTools = groups.reduce((total, group) => total + group.total, 0);

  if (loadError) {
    return (
      <Card>
        <MicroLabel>Tools &amp; MCP services</MicroLabel>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--color-error-text)' }}>
          Could not load the roster: {loadError}
        </p>
      </Card>
    );
  }

  if (!payload) {
    return <Card><Empty>loading the roster…</Empty></Card>;
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 16, flexWrap: 'wrap' }}>
        <div style={{ flex: 1, minWidth: 260 }}>
          <h2 style={{ margin: 0, fontSize: 16, fontWeight: 600, color: 'var(--color-text-primary)' }}>Tools &amp; MCP services</h2>
          <p style={{ margin: '3px 0 0', fontSize: 13, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>
            Turn a service on to offer its tools, then narrow the roster tool by tool. Call counts come from the traces
            recorded on every tool call.
          </p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <span
            style={{
              display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 10px', borderRadius: 8,
              border: '1px solid var(--color-border-strong)', background: 'var(--color-card)',
            }}
          >
            <span style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-muted)' }}>?</span>
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Filter tools and services…"
              aria-label="Filter tools and services"
              style={{ border: 'none', outline: 'none', background: 'transparent', color: 'var(--color-text-primary)', fontSize: 13, width: 180 }}
            />
          </span>
          <SegmentedControl options={RANGES} value={range} onChange={setRange} />
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 12 }}>
        {stats.map((stat) => (
          <Card key={stat.key} padding="14px 16px" testId={`roster-stat-${stat.key}`}>
            <MicroLabel size={11} spacing="0.05em">{stat.label}</MicroLabel>
            <div
              style={{
                marginTop: 6, fontFamily: MONO, fontSize: 26, fontWeight: 700, lineHeight: 1.1,
                color: stat.tone === 'warning' ? 'var(--color-warning)' : 'var(--color-text-primary)',
              }}
            >
              {stat.value}
            </div>
            <div style={{ marginTop: 5, fontSize: 12, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>{stat.sub}</div>
          </Card>
        ))}
      </div>

      {/* MCP services — one switch per service, expand for its tools. */}
      <Card padding={0} style={{ overflow: 'hidden' }} testId="mcp-services-card">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '12px 16px', borderBottom: '1px solid var(--color-border-light)', flexWrap: 'wrap' }}>
          <MicroLabel>MCP services</MicroLabel>
          <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
            {enabledServices.length} of {(roster.services || []).length} enabled · {offeredMcp ? offeredMcp.total : 0} tools offered
          </span>
          <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
            <Chip selected={!serviceFilter} onClick={() => setServiceFilter(null)}>All {(roster.services || []).length}</Chip>
            {SERVICE_FILTERS.map((filter) => (
              <Chip
                key={filter.value}
                selected={serviceFilter === filter.value}
                onClick={() => setServiceFilter(serviceFilter === filter.value ? null : filter.value)}
              >
                {filter.label}{filter.value === 'enabled' ? ` ${enabledServices.length}` : ''}
              </Chip>
            ))}
            <MonoLink
              href={dashboardPath('/mcp')}
              onClick={() => navigateTo('/mcp')}
              title="Every MCP service this workspace knows"
              style={{ marginLeft: 4 }}
            >
              manage servers
            </MonoLink>
          </span>
        </div>

        <ScrollBox>
          <div style={{ display: 'grid', gridTemplateColumns: SERVICE_COLUMNS, ...headStrip }}>
            <span>On</span>
            <span>Service</span>
            <span>Status</span>
            <span style={{ textAlign: 'right' }}>Tools</span>
            <span style={{ textAlign: 'right' }}>Calls</span>
            <span style={{ textAlign: 'right' }}>Errors</span>
            <span style={{ textAlign: 'right' }}>Last seen</span>
            <span />
          </div>

          {services.map((service) => {
            const open = openService === service.key;
            return (
              <div key={service.key}>
                <div
                  className="aa-roster-row"
                  data-on={service.on ? 'true' : 'false'}
                  data-testid={`service-row-${service.key}`}
                  style={{
                    display: 'grid', gridTemplateColumns: SERVICE_COLUMNS, gap: 10, alignItems: 'center',
                    padding: '10px 16px', borderTop: '1px solid var(--color-border-light)',
                  }}
                >
                  <Switch
                    on={service.on}
                    onClick={() => toggleService(service)}
                    title={`${service.on ? 'Disable' : 'Enable'} ${service.name} for this agent`}
                  />
                  <div onClick={() => setOpenService(open ? null : service.key)} style={{ minWidth: 0, cursor: 'pointer' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                      <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>{service.name}</span>
                      {service.first_party && <Badge tone="accent" size={10}>first-party</Badge>}
                      {!service.known && <Badge size={10} title="Seen in your traffic but not in the platform catalog">undocumented</Badge>}
                      {service.partial && <Badge tone="warning" size={10}>{service.partialLabel}</Badge>}
                    </div>
                    <div style={{ marginTop: 2, fontSize: 12, lineHeight: '17px', color: 'var(--color-text-secondary)', ...ellipsis }}>
                      {service.description}
                    </div>
                  </div>
                  <span><Badge tone={STATUS_TONES[service.status] || 'muted'}>{service.status}</Badge></span>
                  <span style={{ ...numeric, color: service.on ? 'var(--color-text-primary)' : 'var(--color-text-muted)' }}>{service.toolsLabel}</span>
                  <span style={numeric}>{cell(service.calls)}</span>
                  <span style={{ ...numeric, color: service.errors ? 'var(--color-error-text)' : 'var(--color-text-secondary)' }}>{cell(service.errors)}</span>
                  <span style={{ ...numeric, color: 'var(--color-text-muted)' }}>{cell(fmtAgo(service.last_seen))}</span>
                  <span onClick={() => setOpenService(open ? null : service.key)} style={{ cursor: 'pointer', textAlign: 'center' }}>
                    <Glyph kind="chevron" open={open} />
                  </span>
                </div>

                {open && (
                  <div style={{ borderTop: '1px solid var(--color-border-light)', background: 'var(--color-background)', padding: '10px 16px 12px' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 8 }}>
                      <MicroLabel size={10} color="var(--color-text-muted)">Tools offered</MicroLabel>
                      <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{service.transport}</span>
                      <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
                        <MicroButton onClick={() => setAllServiceTools(service, true)} title={`Offer every tool ${service.name} serves`}>all</MicroButton>
                        <MicroButton onClick={() => setAllServiceTools(service, false)} disabled={!service.on} title={`Offer none of ${service.name}'s tools`}>none</MicroButton>
                      </span>
                    </div>

                    {service.tools.length === 0 ? (
                      <Empty style={{ padding: '10px 0' }}>no tools recorded for this service yet</Empty>
                    ) : (
                      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: '6px 14px' }}>
                        {service.tools.map((tool) => (
                          <div
                            key={tool.name}
                            className="aa-roster-row"
                            onClick={() => toggleServiceTool(service, tool)}
                            style={{
                              display: 'grid', gridTemplateColumns: '20px minmax(0, 1fr) 46px 52px', gap: 10, alignItems: 'center',
                              padding: '6px 8px', borderRadius: 8, cursor: service.on ? 'pointer' : 'default',
                              opacity: service.on ? 1 : 0.55,
                            }}
                          >
                            <CheckBox on={tool.on} dim={!service.on} />
                            <span style={{ minWidth: 0 }}>
                              <span style={{ display: 'block', fontFamily: MONO, fontSize: 12, fontWeight: 600, color: tool.on ? 'var(--color-text-primary)' : 'var(--color-text-secondary)', ...ellipsis }}>
                                {tool.name}
                              </span>
                              <span style={{ display: 'block', fontSize: 11, color: 'var(--color-text-muted)', ...ellipsis }}>{tool.description}</span>
                            </span>
                            <span style={{ ...numeric, color: 'var(--color-text-secondary)' }}>{cell(tool.calls)}</span>
                            <span style={{ ...numeric, color: tool.errors ? 'var(--color-error-text)' : 'var(--color-text-muted)' }}>
                              {cell(tool.errors ? `${tool.errors} err` : fmtDuration(tool.avg_duration_ms))}
                            </span>
                          </div>
                        ))}
                      </div>
                    )}

                    {!service.on && (
                      <div style={{ marginTop: 8, fontSize: 12, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>
                        Turning {service.name} on offers these {service.tools.length} tools to the agent and starts recording
                        traces and metrics for every call.
                      </div>
                    )}
                  </div>
                )}
              </div>
            );
          })}

          {services.length === 0 && (
            <Empty style={{ borderTop: '1px solid var(--color-border-light)', padding: '18px 16px' }}>
              {query ? `no services match "${query}"` : 'no MCP services yet'}
            </Empty>
          )}
        </ScrollBox>
      </Card>

      {/* Tools — the whole roster, grouped by where each tool comes from. */}
      <Card padding={0} style={{ overflow: 'hidden' }} testId="tools-card">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '12px 16px', borderBottom: '1px solid var(--color-border-light)', flexWrap: 'wrap' }}>
          <MicroLabel>Tools</MicroLabel>
          <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
            {totalOn} enabled of {totalTools} available
          </span>
          <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
            <Chip selected={!source} onClick={() => setSource(null)}>All {totalTools}</Chip>
            {groups.map((group) => (
              <Chip
                key={group.source}
                selected={source === group.source}
                onClick={() => setSource(source === group.source ? null : group.source)}
              >
                {group.name} {group.total}
              </Chip>
            ))}
            <Chip
              square
              mono
              selected={enabledOnly}
              onClick={() => setEnabledOnly(!enabledOnly)}
              style={{ marginLeft: 4 }}
            >
              {enabledOnly ? '[x] enabled only' : '[ ] enabled only'}
            </Chip>
          </span>
        </div>

        <ScrollBox>
          <div style={{ display: 'grid', gridTemplateColumns: TOOL_COLUMNS, ...headStrip }}>
            <span />
            <span>Tool</span>
            <span>Source</span>
            <span style={{ textAlign: 'right' }}>Calls</span>
            <span style={{ textAlign: 'right' }}>Errors</span>
            <span style={{ textAlign: 'right' }}>Avg</span>
            <span style={{ textAlign: 'right' }}>Last seen</span>
          </div>

          {groups.map((group) => {
            const open = closedGroups[group.source] !== true;
            return (
              <div key={group.source}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '7px 16px', borderTop: '1px solid var(--color-border-light)', background: 'var(--color-background)', flexWrap: 'wrap' }}>
                  <span
                    onClick={() => setClosedGroups({ ...closedGroups, [group.source]: open })}
                    style={{ cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 10 }}
                  >
                    <Glyph kind="chevron" open={open} />
                    <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)' }}>{group.name}</span>
                  </span>
                  <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{group.meta}</span>
                  <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8 }}>
                    <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-cell)' }}>{group.countLabel}</span>
                    {group.editable && (
                      <>
                        <MicroButton onClick={() => setGroup(group, true)}>all</MicroButton>
                        <MicroButton onClick={() => setGroup(group, false)}>none</MicroButton>
                      </>
                    )}
                  </span>
                </div>

                {open && group.rows.map((tool) => (
                  <div
                    key={tool.key}
                    className="aa-roster-row"
                    data-on={tool.on ? 'true' : 'false'}
                    data-testid={`tool-row-${tool.key}`}
                    onClick={() => toggleTool(tool)}
                    style={{
                      display: 'grid', gridTemplateColumns: TOOL_COLUMNS, gap: 10, alignItems: 'center',
                      padding: '10px 16px', borderTop: '1px solid var(--color-border-light)',
                      cursor: tool.editable ? 'pointer' : 'default', opacity: tool.editable ? 1 : 0.75,
                    }}
                  >
                    <CheckBox on={tool.on} dim={!tool.editable} />
                    <div style={{ minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                        <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color: tool.on ? 'var(--color-text-primary)' : 'var(--color-text-secondary)' }}>
                          {tool.name}
                        </span>
                        {tool.source === 'mcp' && <Badge size={10}>via {tool.server}</Badge>}
                        {tool.source === 'agent_defined' && <Badge size={10} title="Declared by the agent class, so the roster reports it rather than selecting it">from schema</Badge>}
                        {usage && tool.on && !tool.calls && <Badge size={10}>unused</Badge>}
                      </div>
                      <div style={{ marginTop: 2, fontSize: 12, lineHeight: '17px', color: 'var(--color-text-secondary)', ...ellipsis }}>
                        {tool.description}
                      </div>
                    </div>
                    <span><Badge tone={SOURCE_TONES[tool.source] || 'muted'}>{SOURCE_LABELS[tool.source]}</Badge></span>
                    <span style={numeric}>{cell(tool.calls)}</span>
                    <span style={{ ...numeric, color: tool.errors ? 'var(--color-error-text)' : 'var(--color-text-secondary)' }}>{cell(tool.errors)}</span>
                    <span style={{ ...numeric, color: 'var(--color-text-secondary)' }}>{cell(fmtDuration(tool.avg_duration_ms))}</span>
                    <span style={{ ...numeric, color: 'var(--color-text-muted)' }}>{cell(fmtAgo(tool.last_seen))}</span>
                  </div>
                ))}
              </div>
            );
          })}

          {groups.every((group) => group.rows.length === 0) && (
            <Empty style={{ borderTop: '1px solid var(--color-border-light)', padding: '18px 16px' }}>
              {query ? `no tools match "${query}"` : 'nothing enabled yet'}
            </Empty>
          )}
        </ScrollBox>
      </Card>

      <Card
        padding="12px 16px"
        // --color-card is translucent in the dark theme; a bar that floats
        // over the list it summarizes has to be opaque.
        style={{ position: 'sticky', bottom: 0, zIndex: 4, background: 'var(--color-surface)', display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}
        testId="roster-action-bar"
      >
        <div style={{ minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
          <MicroLabel size={11} spacing="0.05em">{totalOn} tools · {enabledServices.length} services</MicroLabel>
          <span style={{ fontSize: 12, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>
            Every enabled tool is traced: calls, arguments, errors and latency land in Traces and roll up into Metrics.
          </span>
        </div>
        <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          {changes > 0 && (
            <>
              <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-warning-text)' }}>
                {changes} change{changes === 1 ? '' : 's'} pending
              </span>
              <Button variant="secondary" onClick={discard}>Discard</Button>
            </>
          )}
          {/* This bar replaces the editor's own while the tab is open, so it
              saves an edit made on any tab — not only a roster change. */}
          <Button
            variant={hasChanges ? 'primary' : 'secondary'}
            onClick={onSave}
            disabled={isLoading || !hasChanges}
            title={hasChanges ? 'Save this agent' : 'Nothing to save'}
            style={hasChanges ? undefined : { background: 'var(--color-muted)', color: 'var(--color-text-muted)', border: '1px solid transparent', cursor: 'default' }}
          >
            {isLoading ? 'Saving…' : 'Save Changes'}
          </Button>
        </span>
      </Card>
    </div>
  );
}
