import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';

const REFRESH_INTERVAL_MS = 60000;

const WINDOWS = [
  { value: 24, label: '24h' },
  { value: 24 * 7, label: '7d' },
  { value: 24 * 30, label: '30d' },
];

// Status ordering doubles as the filter row. "All" first, then the states
// in the order a workspace grows through them.
const STATUS_FILTERS = [
  { value: 'all', label: 'All' },
  { value: 'active', label: 'Active' },
  { value: 'configured', label: 'Configured' },
  { value: 'available', label: 'Available' },
];

const STATUS_TONES = {
  active: { light: '#15803d', dark: '#86efac', bgLight: '#f0fdf4', bgDark: 'rgba(34,197,94,0.15)' },
  configured: { light: '#b45309', dark: '#fcd34d', bgLight: '#fffbeb', bgDark: 'rgba(245,158,11,0.15)' },
  available: { light: '#4b5563', dark: 'rgba(255,255,255,0.6)', bgLight: '#f3f4f6', bgDark: 'rgba(255,255,255,0.08)' },
  idle: { light: '#4b5563', dark: 'rgba(255,255,255,0.6)', bgLight: '#f3f4f6', bgDark: 'rgba(255,255,255,0.08)' },
};

const formatNumber = (num) => {
  if (num == null) return '0';
  if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
  return String(num);
};

/**
 * McpServersView — the MCP services this workspace uses, plus the default
 * catalog it could turn on.
 *
 * Rows come from three places at once: servers detected in telemetry and
 * solid_agent records (via the `mcp__server__tool` naming convention),
 * servers an agent declares in its config, and the platform's default
 * catalog. A server therefore appears whether it has been used, merely
 * configured, or never touched — and the ones that can run in a sandbox
 * can be started from here.
 */
export default function McpServersView({ focusServer, onOpenTools }) {
  const { darkMode } = useTheme();
  const [data, setData] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  const [status, setStatus] = useState('all');
  const [hours, setHours] = useState(24 * 7);
  const [expanded, setExpanded] = useState(focusServer || null);
  const [launching, setLaunching] = useState(null);
  const [notice, setNotice] = useState(null);

  const fetchServers = useCallback(async () => {
    try {
      const response = await fetch(`/api/mcp_servers?hours=${hours}`);
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      setData(await response.json());
      setLoadError(null);
    } catch (error) {
      setLoadError(error.message);
    } finally {
      setIsLoading(false);
    }
  }, [hours]);

  useEffect(() => {
    fetchServers();
    const interval = setInterval(fetchServers, REFRESH_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [fetchServers]);

  useEffect(() => {
    if (focusServer) setExpanded(focusServer);
  }, [focusServer]);

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
    codeBg: darkMode ? 'rgba(0,0,0,0.35)' : '#f9fafb',
  };

  const tone = (key) => {
    const palette = STATUS_TONES[key] || STATUS_TONES.available;
    return { fg: darkMode ? palette.dark : palette.light, bg: darkMode ? palette.bgDark : palette.bgLight };
  };

  const launch = async (server) => {
    setLaunching(server.key);
    setNotice(null);
    try {
      const response = await fetch(`/api/mcp_servers/${encodeURIComponent(server.key)}/launch`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.reason || body.error || `Launch failed (${response.status})`);

      setNotice({ kind: 'ok', text: `${server.name} is starting in a sandbox (${body.sandbox.session_id.slice(0, 8)}…)` });
      fetchServers();
    } catch (error) {
      setNotice({ kind: 'error', text: error.message });
    } finally {
      setLaunching(null);
    }
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
        <h1 style={{ fontSize: '24px', fontWeight: 'bold', color: colors.textPrimary, margin: 0 }}>MCP Services</h1>
        <div style={{ marginTop: '16px', padding: '12px 16px', background: colors.errorBg, borderRadius: '8px', color: colors.error, fontSize: '14px' }}>
          Failed to load MCP services: {loadError}
        </div>
      </div>
    );
  }

  const { servers = [], summary = {}, sandboxes = [], statuses = {} } = data || {};
  const visible = status === 'all' ? servers : servers.filter((server) => server.status === status);
  const runningKeys = new Set(sandboxes.flatMap((sandbox) => sandbox.mcp_servers || []));

  const StatCard = ({ label, value, hint }) => (
    <div style={{ background: colors.cardBg, borderRadius: '12px', padding: '20px', border: `1px solid ${colors.border}` }}>
      <div style={{ fontSize: '11px', color: colors.textSecondary, textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: '8px' }}>{label}</div>
      <div style={{ fontSize: '32px', fontWeight: 'bold', fontFamily: 'monospace', color: colors.textPrimary }}>{value}</div>
      {hint && <div style={{ fontSize: '13px', color: colors.textSecondary, marginTop: '8px' }}>{hint}</div>}
    </div>
  );

  return (
    <div style={{ borderRadius: '12px', overflow: 'hidden', minHeight: 'calc(100vh - 200px)', backgroundColor: colors.bg }}>
      <div style={{ padding: '24px 24px 16px 24px', borderBottom: `1px solid ${colors.border}`, marginBottom: '16px' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: '16px', flexWrap: 'wrap' }}>
          <div>
            <h1 style={{ fontSize: '24px', fontWeight: 'bold', color: colors.textPrimary, margin: 0 }}>MCP Services</h1>
            <p style={{ fontSize: '14px', color: colors.textSecondary, marginTop: '4px' }}>
              Servers detected from your agents' traffic, plus the defaults you can connect or run in a sandbox
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
          <StatCard label="Active" value={formatNumber(summary.active)} hint="called in this window" />
          <StatCard label="Configured" value={formatNumber(summary.configured)} hint="declared, no traffic yet" />
          <StatCard label="Available" value={formatNumber(summary.available)} hint="defaults you can connect" />
          <StatCard label="Tool Calls" value={formatNumber(summary.total_calls)} hint="through MCP servers" />
        </div>

        {notice && (
          <div style={{
            marginBottom: '16px', padding: '12px 16px', borderRadius: '8px', fontSize: '14px',
            background: notice.kind === 'error' ? colors.errorBg : (darkMode ? 'rgba(34,197,94,0.15)' : '#f0fdf4'),
            color: notice.kind === 'error' ? colors.error : (darkMode ? '#86efac' : '#15803d'),
          }}>
            {notice.text}
          </div>
        )}

        <div style={{ display: 'flex', gap: '8px', marginBottom: '16px', flexWrap: 'wrap' }}>
          {STATUS_FILTERS.map((filter) => (
            <button
              key={filter.value}
              onClick={() => setStatus(filter.value)}
              title={statuses[filter.value] || 'Every MCP service known to this workspace'}
              style={{
                padding: '6px 12px', fontSize: '13px', borderRadius: '6px', cursor: 'pointer',
                border: `1px solid ${status === filter.value ? '#ef4444' : colors.border}`,
                background: status === filter.value ? (darkMode ? 'rgba(239,68,68,0.15)' : '#fef2f2') : 'transparent',
                color: status === filter.value ? '#ef4444' : colors.textSecondary,
              }}
            >
              {filter.label}
            </button>
          ))}
        </div>

        <div style={{ display: 'grid', gap: '12px' }}>
          {visible.length === 0 ? (
            <div style={{ background: colors.cardBg, borderRadius: '12px', border: `1px solid ${colors.border}`, textAlign: 'center', padding: '48px 24px', color: colors.textSecondary, fontSize: '14px' }}>
              No MCP services in this state
            </div>
          ) : (
            visible.map((server) => {
              const statusTone = tone(server.status);
              const isOpen = expanded === server.key;
              const isRunning = runningKeys.has(server.key);

              return (
                <div key={server.key} style={{ background: colors.cardBg, borderRadius: '12px', border: `1px solid ${isOpen ? statusTone.fg : colors.border}`, overflow: 'hidden' }}>
                  <div
                    onClick={() => setExpanded(isOpen ? null : server.key)}
                    style={{ padding: '16px 20px', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: '16px', flexWrap: 'wrap' }}
                  >
                    <div style={{ flex: 1, minWidth: '220px' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' }}>
                        <span style={{ fontSize: '15px', fontWeight: '600', color: colors.textPrimary }}>{server.name}</span>
                        <span style={{ fontSize: '11px', padding: '2px 8px', borderRadius: '6px', background: statusTone.bg, color: statusTone.fg, textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                          {server.status}
                        </span>
                        {server.first_party && (
                          <span style={{ fontSize: '11px', padding: '2px 8px', borderRadius: '6px', background: darkMode ? 'rgba(239,68,68,0.15)' : '#fef2f2', color: '#ef4444' }}>
                            first-party
                          </span>
                        )}
                        {!server.known && (
                          <span
                            style={{ fontSize: '11px', padding: '2px 8px', borderRadius: '6px', background: colors.borderLight, color: colors.textMuted }}
                            title="Seen in your traffic but not in the platform catalog"
                          >
                            undocumented
                          </span>
                        )}
                        {isRunning && (
                          <span style={{ fontSize: '11px', padding: '2px 8px', borderRadius: '6px', background: darkMode ? 'rgba(34,197,94,0.15)' : '#f0fdf4', color: darkMode ? '#86efac' : '#15803d' }}>
                            ● sandbox running
                          </span>
                        )}
                      </div>
                      {server.description && (
                        <div style={{ fontSize: '13px', color: colors.textSecondary, marginTop: '4px' }}>{server.description}</div>
                      )}
                    </div>

                    <div style={{ display: 'flex', gap: '24px', alignItems: 'center' }}>
                      <div style={{ textAlign: 'right' }}>
                        <div style={{ fontSize: '18px', fontFamily: 'monospace', fontWeight: '600', color: colors.textPrimary }}>{formatNumber(server.calls)}</div>
                        <div style={{ fontSize: '11px', color: colors.textMuted }}>calls</div>
                      </div>
                      <div style={{ textAlign: 'right' }}>
                        <div style={{ fontSize: '18px', fontFamily: 'monospace', fontWeight: '600', color: server.errors > 0 ? colors.error : colors.textPrimary }}>{server.errors || 0}</div>
                        <div style={{ fontSize: '11px', color: colors.textMuted }}>errors</div>
                      </div>
                      {server.launchable && (
                        <button
                          onClick={(event) => { event.stopPropagation(); launch(server); }}
                          disabled={launching === server.key}
                          style={{
                            padding: '8px 14px', fontSize: '13px', borderRadius: '6px', border: 'none',
                            background: launching === server.key ? colors.borderLight : '#ef4444',
                            color: launching === server.key ? colors.textMuted : '#ffffff',
                            cursor: launching === server.key ? 'wait' : 'pointer', fontWeight: '500', whiteSpace: 'nowrap',
                          }}
                          title={`Start ${server.name} in a sandbox session`}
                        >
                          {launching === server.key ? 'Starting…' : isRunning ? 'Start another' : 'Start in sandbox'}
                        </button>
                      )}
                    </div>
                  </div>

                  {isOpen && (
                    <ServerDetail
                      server={server}
                      colors={colors}
                      tone={statusTone}
                      onOpenTools={onOpenTools}
                    />
                  )}
                </div>
              );
            })
          )}
        </div>

        {sandboxes.length > 0 && (
          <div style={{ marginTop: '24px', background: colors.cardBg, borderRadius: '12px', border: `1px solid ${colors.border}`, padding: '20px' }}>
            <h3 style={{ fontSize: '16px', fontWeight: '600', color: colors.textPrimary, margin: '0 0 12px 0' }}>Running sandboxes</h3>
            <div style={{ display: 'grid', gap: '8px' }}>
              {sandboxes.map((sandbox) => (
                <div key={sandbox.session_id} style={{ display: 'flex', justifyContent: 'space-between', gap: '12px', fontSize: '13px', color: colors.textCell, flexWrap: 'wrap' }}>
                  <span style={{ fontFamily: 'monospace' }}>{(sandbox.mcp_servers || []).join(', ') || sandbox.sandbox_type}</span>
                  <span style={{ color: colors.textMuted }}>
                    {sandbox.status} · {sandbox.runs_count}/{sandbox.max_runs} runs · expires {new Date(sandbox.expires_at).toLocaleTimeString()}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// Expanded card: how to connect the server, what it exposes, and who uses it.
function ServerDetail({ server, colors, tone, onOpenTools }) {
  const Row = ({ label, children }) => (
    <div style={{ display: 'flex', gap: '12px', fontSize: '13px', alignItems: 'baseline' }}>
      <span style={{ color: colors.textMuted, minWidth: '120px', fontSize: '11px', textTransform: 'uppercase', letterSpacing: '0.05em' }}>{label}</span>
      <span style={{ color: colors.textCell, flex: 1, wordBreak: 'break-word' }}>{children}</span>
    </div>
  );

  const connection = server.command || server.url;

  return (
    <div style={{ padding: '0 20px 20px 20px', display: 'grid', gap: '10px' }}>
      <div style={{ height: '1px', background: colors.borderLight, marginBottom: '4px' }} />

      {connection && (
        <Row label={server.transport === 'http' ? 'Endpoint' : 'Command'}>
          <code style={{ fontFamily: 'monospace', fontSize: '12px', padding: '4px 8px', borderRadius: '4px', background: colors.codeBg, display: 'inline-block' }}>
            {connection}
          </code>
        </Row>
      )}
      {server.transport && <Row label="Transport">{server.transport}</Row>}
      {server.categories?.length > 0 && <Row label="Categories">{server.categories.join(', ')}</Row>}
      {server.requires_credentials?.length > 0 && (
        <Row label="Requires">{server.requires_credentials.join(', ')}</Row>
      )}

      <Row label={server.tool_count > 0 ? 'Tools used' : 'Tools offered'}>
        {server.tools?.length > 0 ? (
          <span style={{ display: 'flex', gap: '6px', flexWrap: 'wrap' }}>
            {server.tools.map((tool) => (
              <code
                key={tool}
                style={{ fontFamily: 'monospace', fontSize: '11px', padding: '2px 8px', borderRadius: '6px', background: tone.bg, color: tone.fg }}
              >
                {tool}
              </code>
            ))}
          </span>
        ) : (
          <span style={{ color: colors.textMuted }}>none recorded</span>
        )}
      </Row>

      {server.agents?.length > 0 && <Row label="Used by">{server.agents.join(', ')}</Row>}
      {server.configured_by?.length > 0 && <Row label="Configured by">{server.configured_by.join(', ')}</Row>}
      {server.last_seen && <Row label="Last call">{new Date(server.last_seen).toLocaleString()}</Row>}

      <div style={{ display: 'flex', gap: '12px', marginTop: '4px', flexWrap: 'wrap' }}>
        {server.docs_url && (
          <a
            href={server.docs_url}
            target="_blank"
            rel="noopener noreferrer"
            style={{ fontSize: '13px', color: '#ef4444', textDecoration: 'none' }}
          >
            Documentation →
          </a>
        )}
        {server.calls > 0 && onOpenTools && (
          <button
            onClick={() => onOpenTools(server.key)}
            style={{ fontSize: '13px', color: '#ef4444', background: 'none', border: 'none', padding: 0, cursor: 'pointer' }}
          >
            View its tools →
          </button>
        )}
      </div>
    </div>
  );
}
