import React, { useState, useEffect } from 'react';
import { useTimeWindow } from '../../contexts/TimeWindowContext';
import { useTheme } from '../../contexts/ThemeContext';
import { paletteFor } from '../../utils/dashboardTheme';
import TimeWindowSelector from './TimeWindowSelector';
import TracesView from './TracesView';
import InteractionsView from './InteractionsView';

const TABS = [
  { id: 'overview', label: 'Overview' },
  { id: 'traces', label: 'Traces' },
  { id: 'interactions', label: 'Interactions' }
];

// embedded drops the page header and the nested tab bar: when this renders
// inside the agent detail page's Metrics tab, that page already owns the
// heading and the tab row, and Traces/Interactions are siblings there.
export default function AgentAnalytics({ agent, onBack, embedded = false }) {
  // Embedded into the agent page, this renders inside a themed shell, so it
  // resolves the same palette rather than staying light-only.
  const { darkMode } = useTheme();
  const colors = paletteFor(darkMode);
  const [analytics, setAnalytics] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  // This endpoint takes whole days; the shared window rounds up so a
  // sub-day selection still returns the current day rather than nothing.
  const { timeWindow, days: period } = useTimeWindow();
  const [activeTab, setActiveTab] = useState('overview');

  // Correlation key between this Agent record and its telemetry traces
  // (mirrors Agent#telemetry_agent_class for shallow agent objects).
  const telemetryAgentClass = agent.telemetry_agent_class ||
    (() => {
      const base = agent.agent_class_name ||
        `${(agent.name || '').replace(/[^a-zA-Z0-9]+(.)/g, (_, c) => c.toUpperCase()).replace(/^./, c => c.toUpperCase()).replace(/[^a-zA-Z0-9]/g, '')}`;
      return base.endsWith('Agent') ? base : `${base}Agent`;
    })();

  useEffect(() => {
    loadAnalytics();
  }, [agent?.id, period]);

  const loadAnalytics = async () => {
    if (!agent?.id) return;

    setIsLoading(true);
    try {
      const response = await fetch(`/api/agents/${agent.id}/analytics?days=${period}`);
      const data = await response.json();
      setAnalytics(data);
    } catch (error) {
      console.error('Failed to load analytics:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const formatDuration = (ms) => {
    if (!ms) return '-';
    if (ms < 1000) return `${ms}ms`;
    return `${(ms / 1000).toFixed(2)}s`;
  };

  const formatNumber = (num) => {
    if (!num) return '0';
    if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
    if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
    return num.toString();
  };

  const getStatusColor = (status) => {
    switch (status) {
      case 'complete': return 'bg-green-500';
      case 'failed': return 'bg-red-500';
      case 'running': return 'bg-blue-500';
      case 'pending': return 'bg-yellow-500';
      case 'cancelled': return 'bg-gray-500';
      default: return 'bg-gray-400';
    }
  };

  if (isLoading && !analytics) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-red-500"></div>
      </div>
    );
  }

  const maxRuns = analytics?.runs_by_day?.length > 0
    ? Math.max(...analytics.runs_by_day.map(d => d.count))
    : 1;

  // Embedded, this is only ever the overview — the host page owns the tabs.
  const shownTab = embedded ? 'overview' : activeTab;

  return (
    <div className="space-y-6">
      {/* Header */}
      {embedded ? (
        <div className="flex items-center justify-end gap-2">
          {timeWindow.minutes < 1440 && (
            <span className="text-xs" style={{ color: colors.textMuted }} title="This view aggregates by day">
              showing 1 day
            </span>
          )}
          <TimeWindowSelector />
        </div>
      ) : (
        <div className="flex items-center justify-between">
          <div className="flex items-center space-x-4">
            <button
              onClick={onBack}
              className="p-2 transition-colors"
              style={{ color: colors.textMuted }}
            >
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
              </svg>
            </button>
            <div>
              <h1 className="text-2xl font-bold" style={{ color: colors.textPrimary }}>{agent.name} Analytics</h1>
              <p className="text-sm" style={{ color: colors.textSecondary }}>Performance metrics and usage data</p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            {timeWindow.minutes < 1440 && (
              <span className="text-xs" style={{ color: colors.textMuted }} title="This view aggregates by day">
                showing 1 day
              </span>
            )}
            <TimeWindowSelector />
          </div>
        </div>
      )}

      {/* Shared-view tabs: Traces and Interactions are the same components
          as the global observability views, scoped to this agent. */}
      {!embedded && (
        <div className="flex rounded-lg p-1 w-fit" style={{ background: colors.mutedBg }}>
          {TABS.map(tab => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`px-4 py-1.5 text-sm rounded-md transition-colors ${
                activeTab === tab.id ? 'shadow' : ''
              }`}
              style={activeTab === tab.id
                ? { background: colors.cardBg, color: colors.textPrimary }
                : { color: colors.textSecondary }}
            >
              {tab.label}
            </button>
          ))}
        </div>
      )}

      {shownTab === 'traces' && (
        <TracesView agentClass={telemetryAgentClass} embedded />
      )}

      {shownTab === 'interactions' && (
        <InteractionsView agentId={agent.id} embedded />
      )}

      {shownTab === 'overview' && (<>
      {/* Stats Cards */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          title="Total Runs"
          value={analytics?.summary?.total_runs || 0}
          icon={
            <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
          }
          color="rose"
          colors={colors}
          darkMode={darkMode}
        />
        <StatCard
          title="Success Rate"
          value={`${analytics?.summary?.success_rate || 0}%`}
          icon={
            <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
          }
          color="green"
          colors={colors}
          darkMode={darkMode}
        />
        <StatCard
          title="Avg Duration"
          value={formatDuration(analytics?.summary?.avg_duration_ms)}
          icon={
            <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
          }
          color="blue"
          colors={colors}
          darkMode={darkMode}
        />
        <StatCard
          title="Total Tokens"
          value={formatNumber(analytics?.summary?.total_tokens)}
          icon={
            <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 21a4 4 0 01-4-4V5a2 2 0 012-2h4a2 2 0 012 2v12a4 4 0 01-4 4zm0 0h12a2 2 0 002-2v-4a2 2 0 00-2-2h-2.343M11 7.343l1.657-1.657a2 2 0 012.828 0l2.829 2.829a2 2 0 010 2.828l-8.486 8.485M7 17h.01" />
            </svg>
          }
          color="purple"
          colors={colors}
          darkMode={darkMode}
        />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Runs Chart */}
        <div className="lg:col-span-2 rounded-xl border p-6" style={{ background: colors.cardBg, borderColor: colors.cardBorder }}>
          <h3 className="font-semibold mb-4" style={{ color: colors.textPrimary }}>Runs Over Time</h3>
          {analytics?.runs_by_day?.length > 0 ? (
            <div className="h-48">
              <div className="flex items-end justify-between h-full space-x-1">
                {analytics.runs_by_day.map((day, i) => (
                  <div
                    key={day.date}
                    className="flex-1 flex flex-col items-center group"
                  >
                    <div className="relative w-full">
                      <div
                        className="w-full bg-red-500 rounded-t transition-all hover:bg-red-600"
                        style={{ height: `${(day.count / maxRuns) * 150}px`, minHeight: day.count > 0 ? '4px' : '0' }}
                      ></div>
                      <div className="absolute -top-8 left-1/2 transform -translate-x-1/2 bg-gray-800 text-white text-xs px-2 py-1 rounded opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap">
                        {day.count} runs
                      </div>
                    </div>
                    {(i === 0 || i === analytics.runs_by_day.length - 1 || analytics.runs_by_day.length <= 7) && (
                      <span className="text-xs mt-2 transform -rotate-45 origin-left" style={{ color: colors.textMuted }}>
                        {new Date(day.date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
                      </span>
                    )}
                  </div>
                ))}
              </div>
            </div>
          ) : (
            <div className="h-48 flex items-center justify-center" style={{ color: colors.textMuted }}>
              No data for this period
            </div>
          )}
        </div>

        {/* Status Breakdown */}
        <div className="rounded-xl border p-6" style={{ background: colors.cardBg, borderColor: colors.cardBorder }}>
          <h3 className="font-semibold mb-4" style={{ color: colors.textPrimary }}>Status Breakdown</h3>
          {Object.keys(analytics?.status_breakdown || {}).length > 0 ? (
            <div className="space-y-3">
              {Object.entries(analytics.status_breakdown).map(([status, count]) => {
                const total = analytics?.summary?.total_runs || 1;
                const percentage = ((count / total) * 100).toFixed(1);
                return (
                  <div key={status}>
                    <div className="flex justify-between text-sm mb-1">
                      <span className="capitalize" style={{ color: colors.textSecondary }}>{status}</span>
                      <span className="font-medium" style={{ color: colors.textPrimary }}>{count} ({percentage}%)</span>
                    </div>
                    <div className="h-2 rounded-full overflow-hidden" style={{ background: colors.trackBg }}>
                      <div
                        className={`h-full ${getStatusColor(status)} rounded-full transition-all`}
                        style={{ width: `${percentage}%` }}
                      ></div>
                    </div>
                  </div>
                );
              })}
            </div>
          ) : (
            <div className="h-32 flex items-center justify-center" style={{ color: colors.textMuted }}>
              No runs yet
            </div>
          )}
        </div>
      </div>

      {/* Recent Errors */}
      {analytics?.recent_errors?.length > 0 && (
        <div className="rounded-xl border p-6" style={{ background: colors.cardBg, borderColor: colors.cardBorder }}>
          <h3 className="font-semibold mb-4" style={{ color: colors.textPrimary }}>Recent Errors</h3>
          <div className="space-y-3">
            {analytics.recent_errors.map((error) => (
              <div key={error.id} className="flex items-start space-x-3 p-3 rounded-lg"
                style={{ background: darkMode ? 'rgba(220,38,38,0.12)' : '#fef2f2' }}>
                <svg className="w-5 h-5 text-red-500 flex-shrink-0 mt-0.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <div className="flex-1 min-w-0">
                  <p className="text-sm" style={{ color: darkMode ? '#fca5a5' : '#991b1b' }}>{error.error || 'Unknown error'}</p>
                  <p className="text-xs mt-1" style={{ color: darkMode ? '#f87171' : '#dc2626' }}>
                    {new Date(error.created_at).toLocaleString()}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Quick Stats */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <div className="rounded-lg p-4" style={{ background: colors.innerBg }}>
          <p className="text-sm" style={{ color: colors.textSecondary }}>Completed Runs</p>
          <p className="text-2xl font-bold" style={{ color: colors.textPrimary }}>{analytics?.summary?.completed_runs || 0}</p>
        </div>
        <div className="rounded-lg p-4" style={{ background: colors.innerBg }}>
          <p className="text-sm" style={{ color: colors.textSecondary }}>Failed Runs</p>
          <p className="text-2xl font-bold" style={{ color: colors.textPrimary }}>{analytics?.summary?.failed_runs || 0}</p>
        </div>
        <div className="rounded-lg p-4" style={{ background: colors.innerBg }}>
          <p className="text-sm" style={{ color: colors.textSecondary }}>Avg Tokens/Run</p>
          <p className="text-2xl font-bold" style={{ color: colors.textPrimary }}>{formatNumber(analytics?.summary?.avg_tokens_per_run)}</p>
        </div>
        <div className="rounded-lg p-4" style={{ background: colors.innerBg }}>
          <p className="text-sm" style={{ color: colors.textSecondary }}>Period</p>
          <p className="text-2xl font-bold" style={{ color: colors.textPrimary }}>{analytics?.period_days || 30} days</p>
        </div>
      </div>
      </>)}
    </div>
  );
}

// The icon tints stay hue-coded but resolve their surface per theme: a solid
// -100 tint reads as a bright patch on a dark card.
const STAT_TINTS = {
  rose: ['#dc2626', 'rgba(220,38,38,0.18)', '#fee2e2'],
  green: ['#16a34a', 'rgba(22,163,74,0.18)', '#dcfce7'],
  blue: ['#2563eb', 'rgba(37,99,235,0.18)', '#dbeafe'],
  purple: ['#7c3aed', 'rgba(124,58,237,0.18)', '#ede9fe']
};

function StatCard({ title, value, icon, color, colors, darkMode }) {
  const [hue, darkTint, lightTint] = STAT_TINTS[color] || STAT_TINTS.rose;

  return (
    <div className="rounded-xl border p-4" style={{ background: colors.cardBg, borderColor: colors.cardBorder }}>
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm" style={{ color: colors.textSecondary }}>{title}</p>
          <p className="text-2xl font-bold mt-1" style={{ color: colors.textPrimary }}>{value}</p>
        </div>
        <div className="p-3 rounded-lg" style={{ background: darkMode ? darkTint : lightTint, color: hue }}>
          {icon}
        </div>
      </div>
    </div>
  );
}
