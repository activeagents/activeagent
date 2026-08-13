import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';

const REFRESH_INTERVAL_MS = 60000;

// Windows worth offering: a day for "what is happening now", a week as the
// default (tool usage is bursty enough that 24h often reads as empty), and
// a month for the full surface.
const WINDOWS = [
  { value: 24, label: '24h' },
  { value: 24 * 7, label: '7d' },
  { value: 24 * 30, label: '30d' },
];

// Origin drives the accent a row carries, so where a tool comes from is
// legible without reading the label.
const ORIGIN_COLORS = {
  mcp: { light: '#7c3aed', dark: '#c4b5fd', bgLight: '#f5f3ff', bgDark: 'rgba(124,58,237,0.15)' },
  builtin: { light: '#2563eb', dark: '#93c5fd', bgLight: '#eff6ff', bgDark: 'rgba(37,99,235,0.15)' },
  agent: { light: '#15803d', dark: '#86efac', bgLight: '#f0fdf4', bgDark: 'rgba(34,197,94,0.12)' },
};

const formatNumber = (num) => {
  if (num == null) return '0';
  if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
  if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
  return String(num);
};

const formatDuration = (ms) => {
  if (ms == null) return '—';
  return ms >= 1000 ? `${(ms / 1000).toFixed(2)}s` : `${Math.round(ms)}ms`;
};

const formatWhen = (iso) => {
  if (!iso) return '—';
  const then = new Date(iso);
  const minutes = Math.round((Date.now() - then.getTime()) / 60000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
};

/**
 * ToolsView — every tool this workspace's agents can reach, discovered
 * rather than registered.
 *
 * The inventory is assembled server-side (ToolDiscovery) from telemetry
 * tool spans, the tool roster in each generation request, and solid_agent
 * generation/message records. Nothing here is hand-maintained, so a tool
 * appears the first time an agent is offered it — not when someone
 * remembers to add it to a list.
 */
export default function ToolsView({ onOpenServer }) {
  const { darkMode } = useTheme();
  const [data, setData] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  const [origin, setOrigin] = useState('all');
  const [query, setQuery] = useState('');
  const [hours, setHours] = useState(24 * 7);
  const [expanded, setExpanded] = useState(null);

  const fetchTools = useCallback(async () => {
    try {
      const params = new URLSearchParams({ hours: String(hours) });
      if (origin !== 'all') params.set('origin', origin);
      if (query.trim()) params.set('q', query.trim());

      const response = await fetch(`/api/tools?${params}`);
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      setData(await response.json());
      setLoadError(null);
    } catch (error) {
      setLoadError(error.message);
    } finally {
      setIsLoading(false);
    }
  }, [origin, query, hours]);

  // Typing in the filter shouldn't fire a request per keystroke.
  useEffect(() => {
    const timer = setTimeout(fetchTools, query ? 250 : 0);
    return () => clearTimeout(timer);
  }, [fetchTools, query]);

  useEffect(() => {
    const interval = setInterval(fetchTools, REFRESH_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [fetchTools]);

  const colors = {
    bg: darkMode ? 'transparent' : '#f9fafb',
    cardBg: darkMode ? 'rgba(255,255,255,0.05)' : '#ffffff',
    border: darkMode ? 'rgba(255,255,255,0.1)' : '#e5e7eb',
    borderLight: darkMode ? 'rgba(255,255,255,0.05)' : '#f3f4f6',
    textPrimary: darkMode ? '#ffffff' : '#111827',
    textSecondary: darkMode ? 'rgba(255,255,255,0.6)' : '#6b7280',
    textMuted: darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af',
    textCell: darkMode ? 'rgba(255,255,255,0.7)' : '#4b5563',
    error: '#ef4444',
    errorBg: darkMode ? 'rgba(239,68,68,0.2)' : '#fef2f2',
    inputBg: darkMode ? 'rgba(255,255,255,0.06)' : '#ffffff',
  };

  const accent = (originKey) => {
    const palette = ORIGIN_COLORS[originKey] || ORIGIN_COLORS.agent;
    return {
      fg: darkMode ? palette.dark : palette.light,
      bg: darkMode ? palette.bgDark : palette.bgLight,
    };
  };

  if (isLoading && !data) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-red-500"></div>
      </div>
    );
  }

  if (loadError && !data) {
    return (
      <div style={{ padding: '24px' }}>
        <h1 style={{ fontSize: '24px', fontWeight: 'bold', color: colors.textPrimary, margin: 0 }}>Tools</h1>
        <div style={{ marginTop: '16px', padding: '12px 16px', background: colors.errorBg, borderRadius: '8px', color: colors.error, fontSize: '14px' }}>
          Failed to load tools: {loadError}
        </div>
      </div>
    );
  }

  const { tools = [], summary = {}, origins = {}, sources = {} } = data || {};
  const nothingReported = !sources.telemetry && !sources.generations && !sources.messages && !sources.declared;

  const StatCard = ({ label, value, hint, tone }) => (
    <div style={{ background: colors.cardBg, borderRadius: '12px', padding: '20px', border: `1px solid ${colors.border}` }}>
      <div style={{ fontSize: '11px', color: colors.textSecondary, textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: '8px' }}>{label}</div>
      <div style={{ fontSize: '32px', fontWeight: 'bold', fontFamily: 'monospace', color: tone || colors.textPrimary }}>{value}</div>
      {hint && <div style={{ fontSize: '13px', color: colors.textSecondary, marginTop: '8px' }}>{hint}</div>}
    </div>
  );

  return (
    <div style={{ borderRadius: '12px', overflow: 'hidden', minHeight: 'calc(100vh - 200px)', backgroundColor: colors.bg }}>
      <div style={{ padding: '24px 24px 16px 24px', borderBottom: `1px solid ${colors.border}`, marginBottom: '16px' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: '16px', flexWrap: 'wrap' }}>
          <div>
            <h1 style={{ fontSize: '24px', fontWeight: 'bold', color: colors.textPrimary, margin: 0 }}>Tools</h1>
            <p style={{ fontSize: '14px', color: colors.textSecondary, marginTop: '4px' }}>
              Detected from telemetry spans, generation request bodies, and agent records — nothing to register by hand
            </p>
          </div>
          <div style={{ display: 'flex', gap: '4px' }}>
            {WINDOWS.map((window) => (
              <button
                key={window.value}
                onClick={() => setHours(window.value)}
                style={{
                  padding: '6px 12px', fontSize: '13px', borderRadius: '6px', cursor: 'pointer',
                  border: `1px solid ${hours === window.value ? '#ef4444' : colors.border}`,
                  background: hours === window.value ? (darkMode ? 'rgba(239,68,68,0.15)' : '#fef2f2') : 'transparent',
                  color: hours === window.value ? '#ef4444' : colors.textSecondary,
                }}
              >
                {window.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      <div style={{ padding: '0 24px 24px 24px' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '16px', marginBottom: '16px' }}>
          <StatCard label="Tools Detected" value={formatNumber(summary.total_tools)} hint={`${summary.active_tools || 0} called in this window`} />
          <StatCard label="Tool Calls" value={formatNumber(summary.total_calls)} hint={`${formatDuration(summary.avg_duration_ms)} average`} />
          <StatCard
            label="Error Rate"
            value={`${summary.error_rate || 0}%`}
            tone={summary.error_rate > 5 ? colors.error : colors.textPrimary}
            hint={`${summary.total_errors || 0} failed call${summary.total_errors === 1 ? '' : 's'}`}
          />
          <StatCard label="From MCP" value={formatNumber(summary.mcp_tools)} hint={`across ${summary.mcp_servers_active || 0} active server${summary.mcp_servers_active === 1 ? '' : 's'}`} />
          <StatCard label="Never Called" value={formatNumber(summary.unused_tools)} hint="offered or configured, unused" />
        </div>

        {/* Filters */}
        <div style={{ display: 'flex', gap: '8px', marginBottom: '16px', flexWrap: 'wrap', alignItems: 'center' }}>
          {Object.entries(origins).map(([key, label]) => (
            <button
              key={key}
              onClick={() => setOrigin(key)}
              style={{
                padding: '6px 12px', fontSize: '13px', borderRadius: '6px', cursor: 'pointer',
                border: `1px solid ${origin === key ? '#ef4444' : colors.border}`,
                background: origin === key ? (darkMode ? 'rgba(239,68,68,0.15)' : '#fef2f2') : 'transparent',
                color: origin === key ? '#ef4444' : colors.textSecondary,
              }}
            >
              {label}
            </button>
          ))}
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Filter by name…"
            style={{
              marginLeft: 'auto', padding: '6px 12px', fontSize: '13px', borderRadius: '6px', minWidth: '200px',
              border: `1px solid ${colors.border}`, background: colors.inputBg, color: colors.textPrimary,
            }}
          />
        </div>

        <div style={{ background: colors.cardBg, borderRadius: '12px', border: `1px solid ${colors.border}`, overflow: 'hidden' }}>
          {tools.length === 0 ? (
            <div style={{ textAlign: 'center', padding: '48px 24px', color: colors.textSecondary, fontSize: '14px' }}>
              {nothingReported
                ? "No tool activity yet — run an agent, or point your app's ActiveAgent telemetry at this workspace"
                : 'No tools match these filters'}
            </div>
          ) : (
            <div style={{ overflowX: 'auto' }}>
              <table style={{ width: '100%', borderCollapse: 'collapse', minWidth: '760px' }}>
                <thead>
                  <tr style={{ textAlign: 'left', fontSize: '13px', color: colors.textSecondary, borderBottom: `1px solid ${colors.border}` }}>
                    <th style={{ padding: '12px 16px', fontWeight: '500' }}>Tool</th>
                    <th style={{ padding: '12px 16px', fontWeight: '500' }}>Source</th>
                    <th style={{ padding: '12px 16px', fontWeight: '500', textAlign: 'right' }}>Calls</th>
                    <th style={{ padding: '12px 16px', fontWeight: '500', textAlign: 'right' }}>Errors</th>
                    <th style={{ padding: '12px 16px', fontWeight: '500', textAlign: 'right' }}>Avg</th>
                    {/* "Seen", not "used": a tool offered in a request
                        roster but never called still has a timestamp. */}
                    <th style={{ padding: '12px 16px', fontWeight: '500', textAlign: 'right' }}>Last seen</th>
                  </tr>
                </thead>
                <tbody>
                  {tools.map((tool, index) => {
                    const tone = accent(tool.origin);
                    const isOpen = expanded === tool.name;
                    return (
                      <React.Fragment key={tool.name}>
                        <tr
                          onClick={() => setExpanded(isOpen ? null : tool.name)}
                          style={{
                            borderBottom: index < tools.length - 1 || isOpen ? `1px solid ${colors.borderLight}` : 'none',
                            cursor: 'pointer',
                            background: isOpen ? (darkMode ? 'rgba(255,255,255,0.03)' : '#fafafa') : 'transparent',
                          }}
                        >
                          <td style={{ padding: '12px 16px' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' }}>
                              <span style={{ fontFamily: 'monospace', fontSize: '13px', color: colors.textPrimary, fontWeight: '500' }}>
                                {tool.base_name}
                              </span>
                              {tool.unused && (
                                <span style={{ fontSize: '10px', padding: '2px 6px', borderRadius: '4px', background: colors.borderLight, color: colors.textMuted, textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                                  unused
                                </span>
                              )}
                            </div>
                            {tool.description && (
                              <div style={{ fontSize: '12px', color: colors.textMuted, marginTop: '2px', maxWidth: '420px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                                {tool.description}
                              </div>
                            )}
                          </td>
                          <td style={{ padding: '12px 16px' }}>
                            <button
                              onClick={(event) => {
                                event.stopPropagation();
                                if (tool.mcp_server && onOpenServer) onOpenServer(tool.mcp_server);
                              }}
                              style={{
                                fontSize: '11px', padding: '3px 8px', borderRadius: '6px', border: 'none',
                                background: tone.bg, color: tone.fg, fontFamily: 'monospace',
                                cursor: tool.mcp_server && onOpenServer ? 'pointer' : 'default',
                              }}
                              title={tool.mcp_server ? `Open ${tool.mcp_server} in MCP Services` : tool.source_label}
                            >
                              {tool.source_label}
                            </button>
                          </td>
                          <td style={{ padding: '12px 16px', textAlign: 'right', color: colors.textCell, fontFamily: 'monospace' }}>{formatNumber(tool.calls)}</td>
                          <td style={{ padding: '12px 16px', textAlign: 'right', fontFamily: 'monospace', color: tool.errors > 0 ? colors.error : colors.textCell }}>
                            {tool.errors}
                          </td>
                          <td style={{ padding: '12px 16px', textAlign: 'right', color: colors.textCell, fontFamily: 'monospace' }}>{formatDuration(tool.avg_duration_ms)}</td>
                          <td style={{ padding: '12px 16px', textAlign: 'right', color: colors.textMuted, fontSize: '13px' }}>{formatWhen(tool.last_seen)}</td>
                        </tr>
                        {isOpen && (
                          <tr style={{ borderBottom: index < tools.length - 1 ? `1px solid ${colors.borderLight}` : 'none' }}>
                            <td colSpan={6} style={{ padding: '0 16px 16px 16px', background: darkMode ? 'rgba(255,255,255,0.03)' : '#fafafa' }}>
                              <ToolDetail tool={tool} colors={colors} tone={tone} darkMode={darkMode} />
                            </td>
                          </tr>
                        )}
                      </React.Fragment>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Where the inventory came from — makes an empty or partial list
            explainable instead of just sparse. */}
        <div style={{ marginTop: '12px', fontSize: '12px', color: colors.textMuted, display: 'flex', gap: '16px', flexWrap: 'wrap' }}>
          <span>Detected from:</span>
          {[
            ['telemetry', 'telemetry spans'],
            ['declared', 'request tool rosters'],
            ['generations', 'generation records'],
            ['messages', 'tool messages'],
          ].map(([key, label]) => (
            <span key={key} style={{ color: sources[key] ? colors.textSecondary : colors.textMuted, opacity: sources[key] ? 1 : 0.5 }}>
              {sources[key] ? '●' : '○'} {label}
            </span>
          ))}
        </div>
      </div>
    </div>
  );
}

// Expanded row: the tool's full name, parameters, who uses it, and the
// arguments it was last called with.
function ToolDetail({ tool, colors, tone, darkMode }) {
  const Row = ({ label, children }) => (
    <div style={{ display: 'flex', gap: '12px', fontSize: '13px', alignItems: 'baseline' }}>
      <span style={{ color: colors.textMuted, minWidth: '108px', fontSize: '11px', textTransform: 'uppercase', letterSpacing: '0.05em' }}>{label}</span>
      <span style={{ color: colors.textCell, flex: 1, wordBreak: 'break-word' }}>{children}</span>
    </div>
  );

  return (
    <div style={{ display: 'grid', gap: '8px', padding: '12px 16px', borderRadius: '8px', background: darkMode ? 'rgba(0,0,0,0.25)' : '#ffffff', border: `1px solid ${colors.border}` }}>
      <Row label="Full name"><code style={{ fontFamily: 'monospace' }}>{tool.name}</code></Row>
      {tool.description && <Row label="Description">{tool.description}</Row>}
      <Row label="Parameters">
        {tool.parameters?.length > 0
          ? <code style={{ fontFamily: 'monospace', color: tone.fg }}>{tool.parameters.join(', ')}</code>
          : <span style={{ color: colors.textMuted }}>none recorded</span>}
      </Row>
      <Row label="Agents">
        {tool.agents?.length > 0 ? tool.agents.join(', ') : <span style={{ color: colors.textMuted }}>—</span>}
      </Row>
      {tool.configured_by?.length > 0 && <Row label="Configured by">{tool.configured_by.join(', ')}</Row>}
      <Row label="Call breakdown">
        <span style={{ fontFamily: 'monospace' }}>
          {tool.traced_calls} traced · {tool.requested} requested · {tool.results} results
        </span>
      </Row>
      {tool.sample_arguments && (
        <Row label="Last arguments">
          <code style={{ fontFamily: 'monospace', fontSize: '12px', color: colors.textMuted }}>{tool.sample_arguments}</code>
        </Row>
      )}
      {tool.last_error && (
        <Row label="Last error"><span style={{ color: colors.error }}>{tool.last_error}</span></Row>
      )}
      <Row label="Detected from">{tool.detected_from?.join(', ') || '—'}</Row>
    </div>
  );
}
