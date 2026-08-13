import React, { useState } from 'react';
import AgentAvatar from '../AgentAvatar';
import AgentStatCard, { rateTone } from './AgentStatCard';

// Mirrors Api::AgentsController::LIST_SORTS. Ordering is applied server-side
// over the scorecards, so these values are sent, not sorted on.
const SORTS = [
  { value: 'recent', label: 'Recently updated' },
  { value: 'popular', label: 'Most runs' },
  { value: 'longest', label: 'Longest average' },
  { value: 'cost', label: 'Highest cost' },
  { value: 'tokens', label: 'Most tokens' },
];

export default function AgentList({
  agents,
  meta,
  onSelect,
  onNew,
  onBrowseTemplates,
  onDuplicate,
  onDelete,
  onRefresh,
  sort = 'recent',
  onSortChange,
  isLoading
}) {
  const [searchQuery, setSearchQuery] = useState('');
  const [filterProvider, setFilterProvider] = useState('');
  const [filterStatus, setFilterStatus] = useState('');

  const filteredAgents = agents.filter(agent => {
    const matchesSearch = !searchQuery ||
      agent.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
      agent.description?.toLowerCase().includes(searchQuery.toLowerCase());

    const matchesProvider = !filterProvider || agent.provider === filterProvider;
    const matchesStatus = !filterStatus || agent.status === filterStatus;

    return matchesSearch && matchesProvider && matchesStatus;
  });

  const formatDate = (dateString) => {
    const date = new Date(dateString);
    const now = new Date();
    const diff = now - date;
    const days = Math.floor(diff / (1000 * 60 * 60 * 24));

    if (days === 0) return 'Today';
    if (days === 1) return 'Yesterday';
    if (days < 7) return `${days} days ago`;
    return date.toLocaleDateString();
  };

  const getStatusColor = (status) => {
    switch (status) {
      case 'active': return 'bg-green-100 text-green-700';
      case 'draft': return 'bg-yellow-100 text-yellow-700';
      case 'archived': return 'bg-gray-100 text-gray-500';
      default: return 'bg-gray-100 text-gray-500';
    }
  };

  const formatDuration = (ms) => {
    if (ms == null) return '—';
    if (ms < 1000) return `${Math.round(ms)}ms`;
    return `${(ms / 1000).toFixed(1)}s`;
  };

  const formatTokens = (tokens) => {
    if (tokens == null) return '—';
    if (tokens >= 1_000_000) return `${(tokens / 1_000_000).toFixed(1)}M`;
    if (tokens >= 1_000) return `${(tokens / 1_000).toFixed(1)}k`;
    return `${tokens}`;
  };

  // nil cost means nothing priceable ran — "—", not "$0.00", which would
  // read as free rather than unknown.
  const formatCost = (cost) => {
    if (cost == null) return '—';
    if (cost > 0 && cost < 0.01) return '<$0.01';
    return `$${cost.toFixed(2)}`;
  };

  const formatLastRun = (dateString) => {
    if (!dateString) return '—';
    const days = Math.floor((new Date() - new Date(dateString)) / (1000 * 60 * 60 * 24));
    if (days <= 0) return 'Today';
    if (days < 30) return `${days}d ago`;
    return new Date(dateString).toLocaleDateString();
  };



  return (
    <div className="space-y-6">
      {/* Header Actions */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div className="flex-1 flex items-center space-x-4">
          {/* Search */}
          <div className="relative flex-1 max-w-md">
            <input
              type="text"
              placeholder="Search agents..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="w-full pl-10 pr-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500 focus:border-transparent"
            />
            <svg className="absolute left-3 top-2.5 h-5 w-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
            </svg>
          </div>

          {/* Filters */}
          <select
            value={filterProvider}
            onChange={(e) => setFilterProvider(e.target.value)}
            className="px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500"
          >
            <option value="">All Providers</option>
            {meta.providers?.map(p => (
              <option key={p} value={p}>{p.charAt(0).toUpperCase() + p.slice(1)}</option>
            ))}
          </select>

          <select
            value={filterStatus}
            onChange={(e) => setFilterStatus(e.target.value)}
            className="px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500"
          >
            <option value="">All Status</option>
            <option value="active">Active</option>
            <option value="draft">Draft</option>
            <option value="archived">Archived</option>
          </select>

          <select
            value={sort}
            onChange={(e) => onSortChange?.(e.target.value)}
            className="px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500"
            title="Rank agents by their scorecard"
          >
            {SORTS.map((option) => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </select>
        </div>

        <div className="flex items-center space-x-3">
          <button
            onClick={onRefresh}
            disabled={isLoading}
            className="p-2 text-gray-500 hover:text-gray-700 hover:bg-gray-100 rounded-lg transition-colors"
          >
            <svg className={`h-5 w-5 ${isLoading ? 'animate-spin' : ''}`} fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
            </svg>
          </button>
          <button
            onClick={onBrowseTemplates}
            className="flex items-center space-x-2 px-4 py-2 border border-gray-300 text-gray-700 rounded-lg hover:bg-gray-50 transition-colors"
          >
            <svg className="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10" />
            </svg>
            <span>Browse Templates</span>
          </button>
          <button
            onClick={onNew}
            className="flex items-center space-x-2 px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600 transition-colors"
          >
            <svg className="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v16m8-8H4" />
            </svg>
            <span>New Agent</span>
          </button>
        </div>
      </div>

      {/* Agent Grid */}
      {filteredAgents.length > 0 ? (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
          {filteredAgents.map((agent) => {
            const stats = agent.stats || {};
            const sources = stats.run_sources || [];
            const runsTitle = sources.length
              ? `Counted from ${sources.map((s) => (s === 'platform' ? 'dashboard runs' : 'reported telemetry')).join(' + ')}`
              : undefined;

            return (
              <AgentStatCard
                key={agent.id}
                name={agent.name}
                subtitle={agent.description || 'No description'}
                badge={
                  <span className={`px-2 py-0.5 text-xs font-medium rounded-full ${getStatusColor(agent.status)}`}>
                    {agent.status}
                  </span>
                }
                onClick={() => onSelect(agent)}
                stats={[
                  { label: `Runs ${stats.window_days || 30}d`, value: stats.runs ?? 0, title: runsTitle },
                  {
                    label: 'Success',
                    value: stats.success_rate != null ? `${Math.round(stats.success_rate)}%` : '—',
                    tone: rateTone(stats.success_rate != null ? stats.success_rate / 100 : null),
                  },
                  { label: 'Avg time', value: formatDuration(stats.avg_duration_ms) },
                  {
                    label: stats.eval_samples_evaluated
                      ? `Eval ${stats.eval_samples_passed}/${stats.eval_samples_evaluated}`
                      : 'Eval',
                    title: stats.eval_samples_evaluated
                      ? `Latest evaluation: ${stats.eval_samples_passed} of ${stats.eval_samples_evaluated} samples passed`
                      : undefined,
                    value: stats.eval_score != null ? `${Math.round(stats.eval_score * 100)}%` : '—',
                    tone: rateTone(stats.eval_score),
                  },
                  { label: 'Tokens', value: formatTokens(stats.tokens) },
                  {
                    label: 'Cost',
                    value: formatCost(stats.cost),
                    title: 'Estimated from token counts at each model\'s published rates',
                    tone: stats.cost == null ? 'muted' : undefined,
                  },
                ]}
                footer={
                  <>
                    <span style={{ display: 'flex', alignItems: 'center', gap: '6px', minWidth: 0 }}>
                      <span style={{
                        padding: '2px 6px',
                        borderRadius: '4px',
                        background: 'rgba(128,128,128,0.15)',
                        whiteSpace: 'nowrap',
                        flexShrink: 0,
                      }}>
                        {agent.provider}
                      </span>
                      {/* Model ids run long (meta-llama/llama-3.3-70b-instruct);
                          truncate rather than wrap the card to three lines. */}
                      <span
                        title={agent.model}
                        style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}
                      >
                        {agent.model}
                      </span>
                    </span>
                    {/* Last activity beats last edit on an observability
                        card; the edit date stays in the tooltip. */}
                    <span
                      style={{ whiteSpace: 'nowrap' }}
                      title={`Updated ${formatDate(agent.updatedAt || agent.updated_at)}`}
                    >
                      {stats.last_run_at
                        ? `Last run ${formatLastRun(stats.last_run_at)}`
                        : `Updated ${formatDate(agent.updatedAt || agent.updated_at)}`}
                    </span>
                  </>
                }
                actions={
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '13px' }}>
                    <button
                      onClick={(e) => { e.stopPropagation(); onDuplicate(agent.id); }}
                      className="text-gray-500 hover:text-red-600 transition-colors"
                    >
                      Duplicate
                    </button>
                    <button
                      onClick={(e) => { e.stopPropagation(); onDelete(agent.id); }}
                      className="text-red-500 hover:text-red-700 transition-colors"
                    >
                      Delete
                    </button>
                  </div>
                }
              />
            );
          })}
        </div>
      ) : (
        <div className="text-center py-16">
          <div className="inline-block mb-4">
            <AgentAvatar size={100} />
          </div>
          <h3 className="text-lg font-medium text-gray-900 mb-2">
            {agents.length === 0 ? 'No agents yet' : 'No matching agents'}
          </h3>
          <p className="text-gray-500 mb-6">
            {agents.length === 0
              ? 'Create your first AI agent to get started'
              : 'Try adjusting your search or filters'}
          </p>
          {agents.length === 0 && (
            <div className="flex items-center justify-center space-x-4">
              <button
                onClick={onBrowseTemplates}
                className="inline-flex items-center space-x-2 px-6 py-3 border-2 border-red-500 text-red-600 rounded-lg hover:bg-red-50 transition-colors"
              >
                <svg className="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10" />
                </svg>
                <span>Browse Templates</span>
              </button>
              <span className="text-gray-400">or</span>
              <button
                onClick={onNew}
                className="inline-flex items-center space-x-2 px-6 py-3 bg-red-500 text-white rounded-lg hover:bg-red-600 transition-colors"
              >
                <svg className="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v16m8-8H4" />
                </svg>
                <span>Create From Scratch</span>
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
