import React, { useState, useEffect, useCallback, useMemo } from 'react';
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer
} from 'recharts';
import { useTheme } from '../../contexts/ThemeContext';
import { useTimeWindow } from '../../contexts/TimeWindowContext';
import TimeWindowSelector from './TimeWindowSelector';
import InteractionStream from './InteractionStream';
import ContextMeter, { contextWindowFor, estimateTokens } from './ContextMeter';
import TraceSpanPills from './TraceSpanPills';

// Context pressure for one interaction: the biggest generation's real token
// counts against its model's window, with segment sizes estimated from the
// recorded conversation (~4 chars/token).
const interactionContext = (detail) => {
  let peak = null;
  (detail?.generations || []).forEach((generation) => {
    const tokens = generation.tokens || {};
    const total = (tokens.input || 0) + (tokens.output || 0);
    if (total > 0 && (!peak || total > peak.total)) {
      peak = {
        input: tokens.input || 0,
        output: tokens.output || 0,
        cached: tokens.cached || 0,
        thinking: tokens.thinking || 0,
        model: generation.model,
        total,
      };
    }
  });
  if (!peak) return null;

  const instructions = estimateTokens(detail?.instructions);
  let toolResults = 0;
  (detail?.messages || []).forEach((message) => {
    if (message.role !== 'tool') return;
    toolResults += estimateTokens(message.content) + estimateTokens(message.tool_arguments);
  });
  toolResults = Math.min(toolResults, peak.input);
  const conversation = Math.max(peak.input - instructions - toolResults, 0);

  return {
    used: peak.total,
    limit: contextWindowFor(peak.model),
    cached: peak.cached,
    thinking: peak.thinking,
    segments: [
      { key: 'messages', label: 'Messages', tokens: conversation },
      { key: 'tool_results', label: 'Tool results', tokens: toolResults },
      { key: 'instructions', label: 'Instructions', tokens: instructions },
      { key: 'output', label: 'Generated output', tokens: peak.output },
    ],
  };
};

// Same categorical order as Traces, so an agent keeps its colour across views.
// Validated (light surface): worst adjacent pair ΔE 27.1 deutan / 31.8 normal.
// Hues sit below 3:1 against the surface, so every series is also directly
// labelled — colour never carries identity alone.
const AGENT_PALETTE = ['#6366f1', '#10b981', '#f59e0b', '#ec4899', '#3b82f6', '#8b5cf6', '#14b8a6', '#f97316'];

const SORT_OPTIONS = [
  { id: 'recent', label: 'Recent' },
  { id: 'tokens', label: 'Tokens' },
  { id: 'messages', label: 'Messages' },
];

const REFRESH_INTERVAL_MS = 30000;

const formatNumber = (num) => {
  if (num == null) return '0';
  if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
  if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
  return num.toString();
};

const timeAgo = (iso) => {
  if (!iso) return '';
  const seconds = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
};


// agentId scopes the view to one agent's conversation streams (per-agent
// embed: same component, different UX context); embedded hides the page
// header so it can sit inside another view's chrome.
export default function InteractionsView({ agentId = null, embedded = false }) {
  const { darkMode } = useTheme();
  const [sessions, setSessions] = useState([]);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  const [expandedSession, setExpandedSession] = useState(null);
  const [details, setDetails] = useState({}); // interaction id -> detail payload

  const { timeWindow } = useTimeWindow();

  const fetchSessions = useCallback(async () => {
    try {
      // Both filters apply: the shared window bounds the range, and an
      // embedded view scopes to its agent.
      const response = await fetch(
        `/api/interactions?minutes=${timeWindow.minutes}${agentId ? `&agent_id=${agentId}` : ''}`
      );
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      const data = await response.json();
      setSessions(data.interactions || []);
      setLoadError(null);
    } catch (error) {
      setLoadError(error.message);
    } finally {
      setIsLoading(false);
    }
  }, [timeWindow.minutes, agentId]);

  useEffect(() => {
    fetchSessions();
    const interval = setInterval(fetchSessions, REFRESH_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [fetchSessions]);

  const [sortBy, setSortBy] = useState('recent');

  // Stable colour per agent action, assigned in fixed order — never cycled by
  // rank, so filtering or a quiet period can't repaint the survivors.
  const agentColors = useMemo(() => {
    const names = [...new Set(sessions.map((s) => s.display_name).filter(Boolean))].sort();
    return Object.fromEntries(names.map((name, i) => [name, AGENT_PALETTE[i % AGENT_PALETTE.length]]));
  }, [sessions]);

  // Headline numbers for the window. These answer "how much, how expensive"
  // without reading a single card.
  const summary = useMemo(() => {
    const tokens = sessions.reduce((sum, s) => sum + (s.tokens?.total || 0), 0);
    const agents = new Set(sessions.map((s) => s.display_name).filter(Boolean));
    return {
      interactions: sessions.length,
      tokens,
      agents: agents.size,
      avgTokens: sessions.length ? Math.round(tokens / sessions.length) : 0,
    };
  }, [sessions]);

  // Interactions over time, one series per agent action. Bucket width comes
  // from the shared window so the shape stays readable at every zoom.
  const chartData = useMemo(() => {
    if (sessions.length === 0) return [];

    const now = Date.now();
    const bucketMs = timeWindow.bucketSeconds * 1000;
    const bucketCount = Math.max(1, Math.round((timeWindow.minutes * 60) / timeWindow.bucketSeconds));
    const names = Object.keys(agentColors);

    return Array.from({ length: bucketCount }, (_, i) => {
      const end = now - (bucketCount - 1 - i) * bucketMs;
      const start = end - bucketMs;
      const inBucket = sessions.filter((s) => {
        const at = new Date(s.last_activity_at).getTime();
        return at >= start && at < end;
      });

      return {
        time: timeWindow.minutes > 1440
          ? new Date(end).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit' })
          : new Date(end).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
        ...Object.fromEntries(names.map((n) => [n, inBucket.filter((s) => s.display_name === n).length])),
      };
    });
  }, [sessions, agentColors, timeWindow]);

  // Roughly six axis labels whatever the bucket count.
  const tickInterval = Math.max(0, Math.ceil(chartData.length / 6) - 1);

  const sortSessions = useCallback((list) => {
    const sorted = [...list];
    switch (sortBy) {
      case 'tokens':
        return sorted.sort((a, b) => (b.tokens?.total || 0) - (a.tokens?.total || 0));
      case 'messages':
        return sorted.sort((a, b) => (b.message_count || 0) - (a.message_count || 0));
      default:
        return sorted.sort((a, b) => String(b.last_activity_at).localeCompare(String(a.last_activity_at)));
    }
  }, [sortBy]);

  // Group by Agent.action, not by agent class. Clara.respond (admin assistant,
  // full tool access, ~$0.03/run) and Clara.title (no tools, temperature 0.2,
  // ~$0.0004/run) are different agents that share a class name because one app
  // method spawns both; interleaving their streams hides that.
  const agentGroups = useMemo(() => {
    const groups = new Map();

    sessions.forEach((session) => {
      const agentName = session.agent_name || session.agent?.name || 'Unattributed';
      const actionName = session.action_name;
      const key = `${agentName}#${actionName || ''}`;

      if (!groups.has(key)) {
        groups.set(key, {
          key,
          title: actionName
            ? `${agentName} ${actionName.charAt(0).toUpperCase()}${actionName.slice(1)} Agent Interactions`
            : `${agentName} Interactions`,
          sessions: [],
          tokens: 0,
          lastActivity: session.last_activity_at,
        });
      }

      const group = groups.get(key);
      group.sessions.push(session);
      group.tokens += session.tokens?.total || 0;
      if (session.last_activity_at > group.lastActivity) group.lastActivity = session.last_activity_at;
    });

    // Sort within each group by the chosen key; order the groups themselves by
    // the same idea — heaviest first when sorting by weight, most recent when
    // sorting by time.
    const ordered = [...groups.values()].map((g) => ({ ...g, sessions: sortSessions(g.sessions) }));

    if (sortBy === 'tokens') return ordered.sort((a, b) => b.tokens - a.tokens);
    if (sortBy === 'messages') return ordered.sort((a, b) => b.sessions.length - a.sessions.length);
    return ordered.sort((a, b) => String(b.lastActivity).localeCompare(String(a.lastActivity)));
  }, [sessions, sortBy, sortSessions]);

  const toggleSession = async (id) => {
    if (expandedSession === id) {
      setExpandedSession(null);
      return;
    }
    setExpandedSession(id);
    if (!details[id]) {
      try {
        const response = await fetch(`/api/interactions/${id}`);
        if (response.ok) {
          const data = await response.json();
          setDetails((prev) => ({ ...prev, [id]: data.interaction }));
        }
      } catch {
        // leave detail empty; the card shows a loading state
      }
    }
  };

  const colors = {
    cardBg: darkMode ? '#1f1f1f' : '#ffffff',
    cardBorder: darkMode ? '#2a2a2a' : '#e5e7eb',
    innerBg: darkMode ? 'rgba(255,255,255,0.04)' : '#f9fafb',
    textPrimary: darkMode ? '#ffffff' : '#111827',
    textSecondary: darkMode ? 'rgba(255,255,255,0.6)' : '#6b7280',
    textMuted: darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af',
  };

  // Tool arguments/results arrive as JSON — objects from platform runs, encoded
  // strings from reported traces. Indent either so the stream stays readable.
  const formatPayload = (value) => {
    if (value == null) return '—';
    if (typeof value !== 'string') return JSON.stringify(value, null, 2);
    try {
      return JSON.stringify(JSON.parse(value), null, 2);
    } catch {
      return value;
    }
  };

  const roleBubble = (role) => {
    switch (role) {
      case 'user':
        return darkMode
          ? { background: 'rgba(59,130,246,0.15)', color: '#93c5fd', label: 'User' }
          : { background: '#eff6ff', color: '#1d4ed8', label: 'User' };
      case 'assistant':
        return darkMode
          ? { background: 'rgba(239,68,68,0.12)', color: '#fca5a5', label: 'Assistant' }
          : { background: '#fef2f2', color: '#b91c1c', label: 'Assistant' };
      case 'tool':
        return darkMode
          ? { background: 'rgba(245,158,11,0.12)', color: '#fcd34d', label: 'Tool' }
          : { background: '#fffbeb', color: '#b45309', label: 'Tool' };
      default:
        return darkMode
          ? { background: 'rgba(255,255,255,0.08)', color: 'rgba(255,255,255,0.7)', label: role }
          : { background: '#f3f4f6', color: '#374151', label: role };
    }
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-red-500"></div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        {!embedded && (
          <div>
            <h1 className="text-2xl font-bold" style={{ color: colors.textPrimary }}>Interactions</h1>
            <p className="text-sm mt-1" style={{ color: colors.textSecondary }}>
              Persisted conversation streams per agent — messages, generations and provenance
            </p>
          </div>
        )}
        <div className="flex items-center gap-3">
          <div
            className="flex items-center rounded-lg p-1"
            style={{ background: darkMode ? 'rgba(255,255,255,0.06)' : '#f3f4f6' }}
          >
            <span className="text-xs px-1" style={{ color: colors.textMuted }}>Sort</span>
            {SORT_OPTIONS.map((option) => (
              <button
                key={option.id}
                onClick={() => setSortBy(option.id)}
                className="px-2 py-1 text-xs rounded transition-colors"
                style={sortBy === option.id
                  ? {
                      background: darkMode ? '#2a2a2a' : '#ffffff',
                      color: colors.textPrimary,
                      boxShadow: darkMode ? 'none' : '0 1px 2px rgba(0,0,0,0.08)'
                    }
                  : { color: colors.textSecondary }}
              >
                {option.label}
              </button>
            ))}
          </div>
          <TimeWindowSelector />
        </div>
      </div>

      {loadError && (
        <div className="p-3 rounded-lg text-sm" style={{ background: darkMode ? 'rgba(239,68,68,0.1)' : '#fef2f2', color: '#ef4444' }}>
          Failed to load interactions: {loadError}
        </div>
      )}

      {/* Volume over time + headline numbers. Same shape as Traces, so the two
          views read as one system. */}
      {sessions.length > 0 && (
        <div className="rounded-xl border p-4" style={{ backgroundColor: colors.cardBg, borderColor: colors.cardBorder }}>
          <div className="flex items-center justify-between mb-3">
            <h3 className="text-sm font-semibold" style={{ color: colors.textPrimary }}>
              Interactions over time
            </h3>
            {/* Legend: identity is never colour-alone */}
            <div className="flex items-center gap-3 flex-wrap justify-end">
              {Object.entries(agentColors).map(([name, color]) => (
                <span key={name} className="flex items-center gap-1.5 text-xs" style={{ color: colors.textSecondary }}>
                  <span className="inline-block w-2 h-2 rounded-full" style={{ background: color }} />
                  {name}
                </span>
              ))}
            </div>
          </div>

          <div className="h-32">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={chartData}>
                <defs>
                  {Object.entries(agentColors).map(([name, color]) => (
                    <linearGradient key={name} id={`ix-gradient-${name.replace(/\W/g, '-')}`} x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor={color} stopOpacity={0.6} />
                      <stop offset="95%" stopColor={color} stopOpacity={0.05} />
                    </linearGradient>
                  ))}
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke={darkMode ? '#2a2a2a' : '#e5e7eb'} />
                <XAxis
                  dataKey="time"
                  stroke={darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af'}
                  tick={{ fontSize: 10, fill: darkMode ? 'rgba(255,255,255,0.5)' : '#6b7280' }}
                  tickLine={false}
                  interval={tickInterval}
                />
                <YAxis
                  stroke={darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af'}
                  tick={{ fontSize: 10, fill: darkMode ? 'rgba(255,255,255,0.5)' : '#6b7280' }}
                  tickLine={false}
                  axisLine={false}
                  allowDecimals={false}
                />
                <Tooltip
                  contentStyle={{
                    background: darkMode ? '#1f1f1f' : 'white',
                    border: `1px solid ${colors.cardBorder}`,
                    borderRadius: '8px'
                  }}
                  labelStyle={{ color: colors.textPrimary, fontWeight: '600', marginBottom: '4px' }}
                />
                {Object.entries(agentColors).map(([name, color]) => (
                  <Area
                    key={name}
                    type="monotone"
                    dataKey={name}
                    stackId="1"
                    stroke={color}
                    strokeWidth={2}
                    fill={`url(#ix-gradient-${name.replace(/\W/g, '-')})`}
                  />
                ))}
              </AreaChart>
            </ResponsiveContainer>
          </div>

          <div className="flex items-center gap-8 pt-3 mt-3 border-t" style={{ borderColor: colors.cardBorder }}>
            {[
              { label: 'Interactions', value: summary.interactions.toLocaleString() },
              { label: 'Agents', value: summary.agents.toLocaleString() },
              { label: 'Total tokens', value: formatNumber(summary.tokens) },
              { label: 'Avg / interaction', value: formatNumber(summary.avgTokens) },
            ].map((tile) => (
              <div key={tile.label}>
                <div className="text-lg font-bold" style={{ color: colors.textPrimary }}>{tile.value}</div>
                <div className="text-xs" style={{ color: colors.textSecondary }}>{tile.label}</div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Sessions List */}
      {sessions.length === 0 ? (
        <div className="text-center py-12">
          {/* "Nothing recorded" and "nothing in this window" are different
              facts — saying the first when the second is true contradicts a
              sidebar that is listing interactions from further back. */}
          <div className="text-lg" style={{ color: colors.textMuted }}>
            No interactions in the last {timeWindow.label}
          </div>
          <p className="text-sm mt-2" style={{ color: colors.textSecondary }}>
            Widen the time window, or run an agent to start recording its conversation stream
          </p>
        </div>
      ) : (
        <div className="space-y-8">
          {agentGroups.map((group) => (
          <div key={group.key} className="space-y-4">
            {/* Agent header — Clara.respond and Clara.title are different
                agents (different instructions, tools, cost), so their streams
                are grouped rather than interleaved. */}
            <div className="flex items-baseline justify-between">
              <h2 className="text-sm font-semibold" style={{ color: colors.textPrimary }}>
                {group.title}
              </h2>
              <span className="text-xs" style={{ color: colors.textMuted }}>
                {group.sessions.length} {group.sessions.length === 1 ? 'interaction' : 'interactions'}
                {group.tokens > 0 && ` · ${formatNumber(group.tokens)} tokens`}
              </span>
            </div>
          {group.sessions.map((session) => {
            const detail = details[session.id];
            const isExpanded = expandedSession === session.id;
            return (
              <div
                key={session.id}
                className="rounded-xl border shadow-sm overflow-hidden"
                style={{ backgroundColor: colors.cardBg, borderColor: colors.cardBorder }}
              >
                {/* Session header */}
                <div
                  className="flex items-center justify-between p-4 cursor-pointer"
                  onClick={() => toggleSession(session.id)}
                >
                  <div className="flex items-center gap-3 min-w-0">
                    {session.source === 'telemetry' ? (
                      <span
                        className="px-2 py-1 text-xs font-medium rounded flex-shrink-0"
                        style={{ background: darkMode ? 'rgba(168,85,247,0.15)' : '#faf5ff', color: darkMode ? '#d8b4fe' : '#7e22ce' }}
                        title="Reported by an app running this agent outside the platform"
                      >
                        REPORTED
                      </span>
                    ) : (
                      <span className="px-2 py-1 text-xs font-medium bg-blue-100 text-blue-700 rounded flex-shrink-0">SESSION</span>
                    )}
                    <span className="font-mono text-sm truncate" style={{ color: colors.textPrimary }}>
                      {session.display_name}
                    </span>
                    {session.agent && (
                      <span className="text-sm truncate" style={{ color: colors.textSecondary }}>
                        {session.agent.name}
                      </span>
                    )}
                    {session.service_name && (
                      <span className="text-sm truncate font-mono" style={{ color: colors.textMuted }}>
                        {session.service_name}
                      </span>
                    )}
                  </div>
                  <div className="flex items-center gap-4 flex-shrink-0 text-sm" style={{ color: colors.textSecondary }}>
                    <span>
                      {session.message_count > 0
                        ? `${session.message_count} messages`
                        : `${session.tool_count || 0} tool ${session.tool_count === 1 ? 'call' : 'calls'}`}
                    </span>
                    <span>{formatNumber(session.tokens?.total)} tokens</span>
                    {(session.tokens?.total || 0) > 0 && (
                      <ContextMeter
                        compact
                        darkMode={darkMode}
                        label="Context"
                        used={(session.tokens?.input || 0) + (session.tokens?.output || 0) || session.tokens?.total}
                        limit={contextWindowFor(session.model)}
                        segments={[{ key: 'messages', label: 'Context', tokens: (session.tokens?.input || 0) + (session.tokens?.output || 0) || session.tokens?.total }]}
                      />
                    )}
                    <span style={{ color: colors.textMuted }}>{timeAgo(session.last_activity_at)}</span>
                    <svg
                      className={`w-4 h-4 transition-transform ${isExpanded ? 'rotate-180' : ''}`}
                      fill="none" stroke="currentColor" viewBox="0 0 24 24"
                    >
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
                    </svg>
                  </div>
                </div>

                {/* Expanded conversation */}
                {isExpanded && (
                  <div className="border-t p-4 space-y-3" style={{ borderColor: colors.cardBorder, background: colors.innerBg }}>
                    {!detail ? (
                      <div className="flex justify-center py-6">
                        <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-red-500"></div>
                      </div>
                    ) : (
                      <>
                        {detail.messages.length === 0 && (
                          // A run reported without content capture: we know it
                          // happened and what it cost, not what was said.
                          <div className="text-sm" style={{ color: colors.textMuted }}>
                            No conversation content captured for this run. Enable content capture in
                            the reporting app to record prompts, tool arguments, and responses.
                          </div>
                        )}
                        <InteractionStream
                          darkMode={darkMode}
                          messages={detail.instructions
                            ? [
                                {
                                  id: `ctx-${session.id}-system`,
                                  role: 'system',
                                  content: detail.instructions,
                                  created_at: session.created_at
                                },
                                ...detail.messages
                              ]
                            : detail.messages}
                        />

                        {/* Generation metadata */}
                        {detail.generations.length > 0 && (
                          <div className="pt-3 mt-2 border-t" style={{ borderColor: colors.cardBorder }}>
                            <div className="text-xs uppercase tracking-wide mb-2" style={{ color: colors.textMuted }}>
                              Generations
                            </div>
                            <div className="space-y-2">
                              {detail.generations.map((generation) => {
                                // Bars compare runtimes across the interaction's
                                // generations, trace-span style.
                                const maxMs = Math.max(
                                  ...detail.generations.map((g) => (g.duration_seconds || 0) * 1000),
                                  1
                                );
                                const ms = (generation.duration_seconds || 0) * 1000;
                                return (
                              <div key={generation.id}>
                                <div className="flex flex-wrap items-center gap-3 text-xs font-mono" style={{ color: colors.textSecondary }}>
                                  <span
                                    title={generation.cache_hit ? `${formatNumber(generation.tokens.cached)} cached prompt tokens` : 'No prompt cache hit'}
                                    className={generation.cache_hit ? 'text-green-600' : ''}
                                    style={generation.cache_hit ? {} : { color: colors.textMuted }}
                                  >
                                    {generation.cache_hit ? '⚡ cache hit' : '● generated'}
                                  </span>
                                  {generation.thinking && (
                                    <span className="text-amber-600" title={`${formatNumber(generation.tokens.thinking)} thinking tokens`}>
                                      🧠 {formatNumber(generation.tokens.thinking)}
                                    </span>
                                  )}
                                  <span>{generation.model || 'unknown-model'}</span>
                                  {generation.provider && <span>{generation.provider}</span>}
                                  <span className="text-blue-500">in:{formatNumber(generation.tokens.input)}</span>
                                  <span className="text-green-600">out:{formatNumber(generation.tokens.output)}</span>
                                  {generation.finish_reason && <span>{generation.finish_reason}</span>}
                                  {generation.duration_seconds != null && <span>{(generation.duration_seconds * 1000).toFixed(0)}ms</span>}
                                  {generation.trace_id && (
                                    <a
                                      href={`/dashboard/traces?trace=${generation.trace_id}`}
                                      title={`${generation.trace_id} — open in Traces`}
                                      style={{ color: '#3b82f6' }}
                                      className="hover:underline"
                                      onClick={(e) => e.stopPropagation()}
                                    >
                                      trace:{generation.trace_id.slice(0, 8)} →
                                    </a>
                                  )}
                                </div>
                                {generation.trace_id ? (
                                  // Each generation is one trace: its spans
                                  // render as a pill that expands to a mini
                                  // waterfall.
                                  <TraceSpanPills traceId={generation.trace_id} darkMode={darkMode} />
                                ) : ms > 0 && (
                                  <div
                                    className="rounded mt-1"
                                    title={`${ms.toFixed(0)}ms`}
                                    style={{ height: '6px', background: darkMode ? 'rgba(255,255,255,0.08)' : '#f3f4f6' }}
                                  >
                                    <div
                                      className="rounded"
                                      style={{ height: '6px', width: `${Math.max((ms / maxMs) * 100, 2)}%`, background: '#ef4444' }}
                                    />
                                  </div>
                                )}
                              </div>
                                );
                              })}
                            </div>
                          </div>
                        )}

                        {(() => {
                          const ctx = interactionContext(detail);
                          return ctx ? (
                            <div className="pt-3 mt-2 border-t" style={{ borderColor: colors.cardBorder }}>
                              <ContextMeter {...ctx} label="Context pressure" estimated darkMode={darkMode} />
                            </div>
                          ) : null;
                        })()}
                      </>
                    )}
                  </div>
                )}
              </div>
            );
          })}
          </div>
          ))}
        </div>
      )}
    </div>
  );
}
