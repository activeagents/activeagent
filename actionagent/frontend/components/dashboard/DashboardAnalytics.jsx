import React, { useState, useEffect } from 'react';

const PERIOD_OPTIONS = [
  { value: 7, label: '7 days' },
  { value: 14, label: '14 days' },
  { value: 30, label: '30 days' },
  { value: 90, label: '90 days' }
];

export default function DashboardAnalytics({ onSelectAgent }) {
  const [analytics, setAnalytics] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [period, setPeriod] = useState(30);

  useEffect(() => {
    loadAnalytics();
  }, [period]);

  const loadAnalytics = async () => {
    setIsLoading(true);
    try {
      const response = await fetch(`/api/analytics?days=${period}`);
      const data = await response.json();
      setAnalytics(data);
    } catch (error) {
      console.error('Failed to load analytics:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const formatNumber = (num) => {
    if (!num) return '0';
    if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
    if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
    return num.toString();
  };

  const formatDuration = (ms) => {
    if (!ms) return '-';
    if (ms < 1000) return `${ms}ms`;
    return `${(ms / 1000).toFixed(2)}s`;
  };

  if (isLoading && !analytics) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-red-500"></div>
      </div>
    );
  }

  const maxRuns = analytics?.charts?.runs_by_day?.length > 0
    ? Math.max(...analytics.charts.runs_by_day.map(d => d.count))
    : 1;

  const maxTokens = analytics?.charts?.tokens_by_day?.length > 0
    ? Math.max(...analytics.charts.tokens_by_day.map(d => d.tokens))
    : 1;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Analytics Dashboard</h1>
          <p className="text-sm text-gray-500">Overview of all your agents' performance</p>
        </div>

        <select
          value={period}
          onChange={(e) => setPeriod(Number(e.target.value))}
          className="px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500"
        >
          {PERIOD_OPTIONS.map(opt => (
            <option key={opt.value} value={opt.value}>Last {opt.label}</option>
          ))}
        </select>
      </div>

      {/* Main Stats */}
      <div className="grid grid-cols-2 lg:grid-cols-5 gap-4">
        <StatCard
          title="Total Agents"
          value={analytics?.summary?.total_agents || 0}
          subtitle={`${analytics?.summary?.active_agents || 0} active`}
          color="rose"
        />
        <StatCard
          title="Total Runs"
          value={analytics?.summary?.total_runs || 0}
          subtitle={`${analytics?.period_days} day period`}
          color="blue"
        />
        <StatCard
          title="Success Rate"
          value={`${analytics?.summary?.success_rate || 0}%`}
          subtitle={`${analytics?.summary?.completed_runs || 0} completed`}
          color="green"
        />
        <StatCard
          title="Avg Duration"
          value={formatDuration(analytics?.summary?.avg_duration_ms)}
          subtitle="per run"
          color="purple"
        />
        <StatCard
          title="Total Tokens"
          value={formatNumber(analytics?.summary?.total_tokens)}
          subtitle={`${formatNumber(analytics?.summary?.avg_tokens_per_run)}/run avg`}
          color="amber"
        />
      </div>

      {/* Charts Row */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Runs Chart */}
        <div className="bg-white rounded-xl border border-gray-200 p-6">
          <h3 className="font-semibold text-gray-900 mb-4">Runs Over Time</h3>
          {analytics?.charts?.runs_by_day?.length > 0 ? (
            <div className="h-48">
              <div className="flex items-end justify-between h-full space-x-1">
                {analytics.charts.runs_by_day.map((day, i) => (
                  <div key={day.date} className="flex-1 flex flex-col items-center group">
                    <div className="relative w-full">
                      <div
                        className="w-full bg-red-500 rounded-t transition-all hover:bg-red-600"
                        style={{ height: `${(day.count / maxRuns) * 150}px`, minHeight: day.count > 0 ? '4px' : '0' }}
                      ></div>
                      <div className="absolute -top-8 left-1/2 transform -translate-x-1/2 bg-gray-800 text-white text-xs px-2 py-1 rounded opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap z-10">
                        {day.count} runs
                      </div>
                    </div>
                  </div>
                ))}
              </div>
              <div className="flex justify-between mt-2 text-xs text-gray-400">
                <span>{analytics.charts.runs_by_day[0]?.date && new Date(analytics.charts.runs_by_day[0].date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}</span>
                <span>{analytics.charts.runs_by_day[analytics.charts.runs_by_day.length - 1]?.date && new Date(analytics.charts.runs_by_day[analytics.charts.runs_by_day.length - 1].date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}</span>
              </div>
            </div>
          ) : (
            <div className="h-48 flex items-center justify-center text-gray-400">
              No runs in this period
            </div>
          )}
        </div>

        {/* Tokens Chart */}
        <div className="bg-white rounded-xl border border-gray-200 p-6">
          <h3 className="font-semibold text-gray-900 mb-4">Token Usage Over Time</h3>
          {analytics?.charts?.tokens_by_day?.length > 0 ? (
            <div className="h-48">
              <div className="flex items-end justify-between h-full space-x-1">
                {analytics.charts.tokens_by_day.map((day, i) => (
                  <div key={day.date} className="flex-1 flex flex-col items-center group">
                    <div className="relative w-full">
                      <div
                        className="w-full bg-purple-500 rounded-t transition-all hover:bg-purple-600"
                        style={{ height: `${(day.tokens / maxTokens) * 150}px`, minHeight: day.tokens > 0 ? '4px' : '0' }}
                      ></div>
                      <div className="absolute -top-8 left-1/2 transform -translate-x-1/2 bg-gray-800 text-white text-xs px-2 py-1 rounded opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap z-10">
                        {formatNumber(day.tokens)} tokens
                      </div>
                    </div>
                  </div>
                ))}
              </div>
              <div className="flex justify-between mt-2 text-xs text-gray-400">
                <span>{analytics.charts.tokens_by_day[0]?.date && new Date(analytics.charts.tokens_by_day[0].date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}</span>
                <span>{analytics.charts.tokens_by_day[analytics.charts.tokens_by_day.length - 1]?.date && new Date(analytics.charts.tokens_by_day[analytics.charts.tokens_by_day.length - 1].date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}</span>
              </div>
            </div>
          ) : (
            <div className="h-48 flex items-center justify-center text-gray-400">
              No token usage in this period
            </div>
          )}
        </div>
      </div>

      {/* Bottom Row */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Top Agents */}
        <div className="lg:col-span-2 bg-white rounded-xl border border-gray-200 p-6">
          <h3 className="font-semibold text-gray-900 mb-4">Top Agents</h3>
          {analytics?.top_agents?.length > 0 ? (
            <div className="space-y-3">
              {analytics.top_agents.map((agent, index) => (
                <div
                  key={agent.id}
                  onClick={() => onSelectAgent?.(agent)}
                  className="flex items-center space-x-4 p-3 rounded-lg hover:bg-gray-50 cursor-pointer transition-colors"
                >
                  <div className="w-8 h-8 rounded-full bg-red-100 flex items-center justify-center text-red-600 font-semibold">
                    {index + 1}
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="font-medium text-gray-900 truncate">{agent.name}</p>
                    <p className="text-sm text-gray-500">{agent.run_count} runs</p>
                  </div>
                  <div className="text-right">
                    <p className="font-medium text-gray-900">{formatNumber(agent.total_tokens)}</p>
                    <p className="text-xs text-gray-500">tokens</p>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <div className="py-8 text-center text-gray-400">
              No agent activity yet
            </div>
          )}
        </div>

        {/* Provider & Status Breakdown */}
        <div className="space-y-6">
          {/* Provider Breakdown */}
          <div className="bg-white rounded-xl border border-gray-200 p-6">
            <h3 className="font-semibold text-gray-900 mb-4">By Provider</h3>
            {Object.keys(analytics?.provider_breakdown || {}).length > 0 ? (
              <div className="space-y-3">
                {Object.entries(analytics.provider_breakdown).map(([provider, count]) => {
                  const total = analytics?.summary?.total_runs || 1;
                  const percentage = ((count / total) * 100).toFixed(1);
                  return (
                    <div key={provider}>
                      <div className="flex justify-between text-sm mb-1">
                        <span className="capitalize text-gray-600">{provider}</span>
                        <span className="text-gray-900 font-medium">{count}</span>
                      </div>
                      <div className="h-2 bg-gray-100 rounded-full overflow-hidden">
                        <div
                          className="h-full bg-blue-500 rounded-full"
                          style={{ width: `${percentage}%` }}
                        ></div>
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : (
              <div className="py-4 text-center text-gray-400 text-sm">
                No data
              </div>
            )}
          </div>

          {/* Token Breakdown */}
          <div className="bg-white rounded-xl border border-gray-200 p-6">
            <h3 className="font-semibold text-gray-900 mb-4">Token Usage</h3>
            <div className="space-y-4">
              <div className="flex justify-between items-center">
                <span className="text-sm text-gray-500">Input Tokens</span>
                <span className="font-medium text-gray-900">{formatNumber(analytics?.summary?.total_input_tokens)}</span>
              </div>
              <div className="flex justify-between items-center">
                <span className="text-sm text-gray-500">Output Tokens</span>
                <span className="font-medium text-gray-900">{formatNumber(analytics?.summary?.total_output_tokens)}</span>
              </div>
              <div className="pt-2 border-t border-gray-100">
                <div className="flex justify-between items-center">
                  <span className="text-sm font-medium text-gray-700">Total</span>
                  <span className="font-bold text-gray-900">{formatNumber(analytics?.summary?.total_tokens)}</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function StatCard({ title, value, subtitle, color }) {
  const borderColors = {
    rose: 'border-l-red-500',
    blue: 'border-l-blue-500',
    green: 'border-l-green-500',
    purple: 'border-l-purple-500',
    amber: 'border-l-amber-500'
  };

  return (
    <div className={`bg-white rounded-xl border border-gray-200 border-l-4 ${borderColors[color]} p-4`}>
      <p className="text-sm text-gray-500">{title}</p>
      <p className="text-2xl font-bold text-gray-900 mt-1">{value}</p>
      {subtitle && <p className="text-xs text-gray-400 mt-1">{subtitle}</p>}
    </div>
  );
}
