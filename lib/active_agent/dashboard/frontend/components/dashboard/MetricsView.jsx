import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';

const REFRESH_INTERVAL_MS = 60000;

// Build an SVG polyline (0-100 x 0-30 viewBox) from a series of values
const sparklinePoints = (values) => {
  if (!values || values.length < 2) return '';
  const max = Math.max(...values, 1);
  const step = 100 / (values.length - 1);
  return values
    .map((v, i) => `${(i * step).toFixed(1)},${(28 - (v / max) * 26 + 1).toFixed(1)}`)
    .join(' ');
};

// Ranking for the agent table. Server-side (Api::MetricsController::AGENT_SORTS)
// so it ranks every agent in the window, not just what is on screen.
const AGENT_SORTS = [
  { value: 'popular', label: 'Requests', column: 'requests' },
  { value: 'tokens', label: 'Tokens', column: 'tokens' },
  { value: 'cost', label: 'Cost', column: 'cost' },
  { value: 'longest', label: 'Avg Duration', column: 'avg_duration_ms' },
  { value: 'errors', label: 'Errors', column: 'errors' },
];

export default function MetricsView() {
  const { darkMode } = useTheme();
  const [metrics, setMetrics] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  const [agentSort, setAgentSort] = useState('popular');

  const fetchMetrics = useCallback(async () => {
    try {
      const response = await fetch(`/api/metrics?hours=24&sort=${agentSort}`);
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      const data = await response.json();
      setMetrics(data);
      setLoadError(null);
    } catch (error) {
      setLoadError(error.message);
    } finally {
      setIsLoading(false);
    }
  }, [agentSort]);

  useEffect(() => {
    fetchMetrics();
    const interval = setInterval(fetchMetrics, REFRESH_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [fetchMetrics]);

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-red-500"></div>
      </div>
    );
  }

  const formatNumber = (num) => {
    if (num == null) return '0';
    if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
    if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
    return num.toString();
  };

  // Two decimals alone renders every sub-cent figure as $0.00, which reads
  // as "no spend" and makes a cost ranking look broken.
  const formatCost = (cost) => {
    if (!cost) return '$0.00';
    if (cost < 0.01) return '<$0.01';
    return `$${cost.toFixed(2)}`;
  };

  // Theme colors - single source of truth
  const colors = {
    bg: darkMode ? 'transparent' : '#f9fafb',
    cardBg: darkMode ? 'rgba(255,255,255,0.05)' : '#ffffff',
    border: darkMode ? 'rgba(255,255,255,0.1)' : '#e5e7eb',
    borderLight: darkMode ? 'rgba(255,255,255,0.05)' : '#f3f4f6',
    textPrimary: darkMode ? '#ffffff' : '#111827',
    textSecondary: darkMode ? 'rgba(255,255,255,0.6)' : '#6b7280',
    textMuted: darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af',
    textCell: darkMode ? 'rgba(255,255,255,0.7)' : '#4b5563',
    trendUp: '#16a34a',
    trendDown: '#dc2626',
    tokenIn: '#2563eb',
    tokenOut: '#7c3aed',
    tokenThinking: '#d97706',
    badgeBg: darkMode ? 'rgba(239, 68, 68, 0.2)' : '#fef2f2',
    badgeText: '#ef4444',
  };

  if (loadError || !metrics) {
    return (
      <div style={{ padding: '24px' }}>
        <h1 style={{ fontSize: '24px', fontWeight: 'bold', color: colors.textPrimary, margin: 0 }}>Metrics</h1>
        <div style={{ marginTop: '16px', padding: '12px 16px', background: colors.badgeBg, borderRadius: '8px', color: colors.badgeText, fontSize: '14px' }}>
          Failed to load metrics{loadError ? `: ${loadError}` : ''}
        </div>
      </div>
    );
  }

  const { summary, hourly_requests: hourly = [], by_agent: byAgent = [] } = metrics;
  const requestSeries = hourly.map((h) => h.count);
  const latencySeries = hourly.map((h) => h.avg_latency_ms);
  const maxHourly = Math.max(...requestSeries, 1);
  const isEmpty = summary.total_requests === 0;

  const trendLabel = (change, invert = false) => {
    if (change == null) return null;
    const up = change >= 0;
    const good = invert ? !up : up;
    return (
      <div style={{ fontSize: '13px', color: good ? colors.trendUp : colors.trendDown, marginTop: '8px' }}>
        {up ? '↑' : '↓'} {Math.abs(change)}% vs previous 24h
      </div>
    );
  };

  // The ranked column reads bold, so the ordering is legible without
  // re-reading the header.
  const sortedColumn = AGENT_SORTS.find((option) => option.value === agentSort)?.column;
  const cellStyle = (column) => ({
    padding: '12px 0',
    textAlign: 'right',
    color: colors.textCell,
    fontWeight: column === sortedColumn ? '600' : '400',
  });

  const MetricCard = ({ label, children, trend, sparkline, sparklineColor }) => (
    <div style={{ background: colors.cardBg, borderRadius: '12px', padding: '20px', border: `1px solid ${colors.border}` }}>
      <div style={{ fontSize: '11px', color: colors.textSecondary, textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: '8px' }}>{label}</div>
      {children}
      {trend}
      {sparkline && (
        <div style={{ marginTop: '16px', height: '40px' }}>
          <svg viewBox="0 0 100 30" style={{ width: '100%', height: '100%' }} preserveAspectRatio="none">
            <polyline points={sparkline} fill="none" stroke={sparklineColor} strokeWidth="2" />
          </svg>
        </div>
      )}
    </div>
  );

  return (
    <div style={{ borderRadius: '12px', overflow: 'hidden', minHeight: 'calc(100vh - 200px)', backgroundColor: colors.bg }}>
      {/* Header */}
      <div style={{ padding: '24px 24px 0 24px', borderBottom: `1px solid ${colors.border}`, marginBottom: '16px', paddingBottom: '16px' }}>
        <h1 style={{ fontSize: '24px', fontWeight: 'bold', color: colors.textPrimary, margin: 0 }}>Metrics</h1>
        <p style={{ fontSize: '14px', color: colors.textSecondary, marginTop: '4px' }}>Requests, latency, errors and token usage — last 24 hours</p>
      </div>

      <div style={{ padding: '0 24px 24px 24px' }}>
        {/* Metric Cards */}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: '16px', marginBottom: '16px' }}>
          <MetricCard
            label="Total Requests"
            trend={trendLabel(summary.requests_change)}
            sparkline={sparklinePoints(requestSeries)}
            sparklineColor="#ef4444"
          >
            <div style={{ fontSize: '32px', fontWeight: 'bold', color: colors.textPrimary, fontFamily: 'monospace' }}>{formatNumber(summary.total_requests)}</div>
          </MetricCard>

          <MetricCard
            label="Avg Latency"
            trend={trendLabel(summary.latency_change, true)}
            sparkline={sparklinePoints(latencySeries)}
            sparklineColor="#22c55e"
          >
            <div style={{ fontSize: '32px', fontWeight: 'bold', color: colors.textPrimary, fontFamily: 'monospace' }}>
              {summary.avg_latency_ms}<span style={{ fontSize: '14px', color: colors.textMuted, marginLeft: '4px' }}>ms</span>
            </div>
          </MetricCard>

          <MetricCard label="Error Rate">
            <div style={{ fontSize: '32px', fontWeight: 'bold', color: summary.error_rate > 5 ? '#ef4444' : colors.textPrimary, fontFamily: 'monospace' }}>
              {summary.error_rate}<span style={{ fontSize: '14px', color: colors.textMuted, marginLeft: '4px' }}>%</span>
            </div>
            <div style={{ fontSize: '13px', color: colors.textSecondary, marginTop: '8px' }}>
              {summary.errors} error{summary.errors === 1 ? '' : 's'} in period
            </div>
          </MetricCard>

          <MetricCard label="Total Cost">
            <div style={{ fontSize: '32px', fontWeight: 'bold', color: colors.textPrimary, fontFamily: 'monospace' }}>
              {formatCost(summary.total_cost)}
            </div>
            <div style={{ fontSize: '13px', color: colors.textSecondary, marginTop: '8px' }}>estimated, this period</div>
          </MetricCard>

          <MetricCard label="Tokens Used">
            <div style={{ fontSize: '32px', fontWeight: 'bold', color: colors.textPrimary, fontFamily: 'monospace' }}>{formatNumber(summary.tokens_used)}</div>
            <div style={{ fontSize: '13px', marginTop: '8px', display: 'flex', gap: '12px', flexWrap: 'wrap' }}>
              <span style={{ color: colors.tokenIn }}>↓ {formatNumber(summary.tokens_input)}</span>
              <span style={{ color: colors.tokenOut }}>↑ {formatNumber(summary.tokens_output)}</span>
              {summary.tokens_thinking > 0 && (
                <span style={{ color: colors.tokenThinking }}>🧠 {formatNumber(summary.tokens_thinking)}</span>
              )}
            </div>
          </MetricCard>

          <MetricCard label="Active Agents">
            <div style={{ fontSize: '32px', fontWeight: 'bold', color: colors.textPrimary, fontFamily: 'monospace' }}>{summary.unique_agents}</div>
            <div style={{ fontSize: '13px', color: colors.textSecondary, marginTop: '8px' }}>with traffic in period</div>
          </MetricCard>
        </div>

        {/* Requests / Hour Chart */}
        <div style={{ background: colors.cardBg, borderRadius: '12px', padding: '20px', border: `1px solid ${colors.border}`, marginBottom: '16px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '16px' }}>
            <span style={{ fontSize: '14px', fontWeight: '600', color: colors.textPrimary }}>Requests / Hour</span>
            <span style={{ fontSize: '13px', color: colors.textSecondary }}>Last 24h</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', height: '120px', gap: '4px' }}>
            {hourly.map((item, idx) => (
              <div
                key={idx}
                style={{
                  flex: 1,
                  height: `${Math.max((item.count / maxHourly) * 100, 2)}%`,
                  background: item.active
                    ? 'linear-gradient(180deg, #ef4444 0%, #dc2626 100%)'
                    : 'linear-gradient(180deg, #fca5a5 0%, #f87171 100%)',
                  opacity: item.count === 0 && !item.active ? 0.25 : 1,
                  borderRadius: '4px 4px 0 0',
                  transition: 'all 0.2s ease'
                }}
                title={`${item.count} requests at ${item.hour}`}
              />
            ))}
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: '8px' }}>
            {hourly.map((item, idx) => (
              <span key={idx} style={{ flex: 1, textAlign: 'center', fontSize: '10px', color: colors.textMuted }}>
                {idx % 4 === 0 || item.active ? (item.active ? 'Now' : item.hour) : ''}
              </span>
            ))}
          </div>
        </div>

        {/* Top Agents Table */}
        <div style={{ background: colors.cardBg, borderRadius: '12px', padding: '20px', border: `1px solid ${colors.border}` }}>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: '16px', gap: '12px', flexWrap: 'wrap' }}>
            <h3 style={{ fontSize: '16px', fontWeight: '600', color: colors.textPrimary, margin: 0 }}>Agent Statistics</h3>
            <span style={{ fontSize: '12px', color: colors.textMuted }}>
              Ranked by {AGENT_SORTS.find((s) => s.value === agentSort)?.label.toLowerCase()} — click a column to change
            </span>
          </div>
          {byAgent.length === 0 ? (
            <div style={{ textAlign: 'center', padding: '24px 0', color: colors.textSecondary, fontSize: '14px' }}>
              {isEmpty
                ? "No traffic yet — run an agent, or point your app's ActiveAgent telemetry at this workspace"
                : 'No per-agent data for this period'}
            </div>
          ) : (
            <table style={{ width: '100%', borderCollapse: 'collapse' }}>
              <thead>
                <tr style={{ textAlign: 'left', fontSize: '13px', color: colors.textSecondary, borderBottom: `1px solid ${colors.border}` }}>
                  <th style={{ paddingBottom: '12px', fontWeight: '500' }}>Agent</th>
                  {AGENT_SORTS.map((option) => {
                    const active = agentSort === option.value;
                    return (
                      <th key={option.value} style={{ paddingBottom: '12px', fontWeight: '500', textAlign: 'right' }}>
                        <button
                          onClick={() => setAgentSort(option.value)}
                          title={`Rank agents by ${option.label.toLowerCase()}`}
                          style={{
                            background: 'none',
                            border: 'none',
                            padding: 0,
                            cursor: 'pointer',
                            font: 'inherit',
                            fontWeight: active ? '600' : '500',
                            color: active ? colors.textPrimary : colors.textSecondary,
                          }}
                        >
                          {option.label}{active ? ' ↓' : ''}
                        </button>
                      </th>
                    );
                  })}
                </tr>
              </thead>
              <tbody>
                {byAgent.map((agent, idx) => (
                  <tr key={agent.name} style={{ borderBottom: idx < byAgent.length - 1 ? `1px solid ${colors.borderLight}` : 'none' }}>
                    <td style={{ padding: '12px 0' }}>
                      <div style={{ display: 'flex', alignItems: 'center' }}>
                        <span style={{
                          width: '24px',
                          height: '24px',
                          borderRadius: '50%',
                          background: colors.badgeBg,
                          color: colors.badgeText,
                          fontSize: '12px',
                          fontWeight: '500',
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          marginRight: '12px'
                        }}>
                          {idx + 1}
                        </span>
                        <span style={{ fontWeight: '500', color: colors.textPrimary }}>{agent.name}</span>
                      </div>
                    </td>
                    <td style={cellStyle('requests')}>{formatNumber(agent.requests)}</td>
                    <td style={cellStyle('tokens')}>{formatNumber(agent.tokens)}</td>
                    <td style={cellStyle('cost')}>{formatCost(agent.cost)}</td>
                    <td style={cellStyle('avg_duration_ms')}>{agent.avg_duration_ms}ms</td>
                    <td style={{ ...cellStyle('errors'), color: agent.errors > 0 ? colors.badgeText : colors.textCell }}>
                      {agent.errors}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  );
}
