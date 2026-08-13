import React, { useState, useEffect, useMemo, useCallback, useRef } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer
} from 'recharts';
import { TYPOGRAPHY } from '../../utils/designTokens';
import { useTimeWindow } from '../../contexts/TimeWindowContext';
import AgentStatCard from './AgentStatCard';
import TimeWindowSelector from './TimeWindowSelector';
import TraceCard from './TraceCard';
import { formatDuration, getSpanIcon } from './SpanWaterfall';
import { dashboardPath } from '../../utils/dashboardPath';

// Deterministic color assignment for agent classes
const AGENT_PALETTE = ['#6366f1', '#10b981', '#f59e0b', '#ec4899', '#3b82f6', '#8b5cf6', '#14b8a6', '#f97316'];

const REFRESH_INTERVAL_MS = 30000;

const buildAgentColors = (agents) => {
  const colors = {};
  agents.forEach((agent, idx) => {
    colors[agent] = AGENT_PALETTE[idx % AGENT_PALETTE.length];
  });
  return colors;
};

// Aggregate span durations by operation name across traces, so the Spans
// view can rank which agent/llm/tool steps take the longest. Root spans are
// skipped — they equal the whole trace and would dominate every ranking.
const buildSpanStats = (traces) => {
  const stats = {};
  traces.forEach((trace) => {
    (trace.spans || []).forEach((span) => {
      if ((span.nested || 0) === 0) return;
      const key = span.name || span.type || 'unknown';
      if (!stats[key]) {
        stats[key] = { name: key, type: span.type, count: 0, total: 0, max: 0, errors: 0 };
      }
      const entry = stats[key];
      entry.count += 1;
      entry.total += span.duration || 0;
      entry.max = Math.max(entry.max, span.duration || 0);
      if (span.error) entry.errors += 1;
    });
  });
  return Object.values(stats)
    .map((entry) => ({ ...entry, avg: entry.total / entry.count }))
    .sort((a, b) => b.total - a.total);
};

// Bucket traces for the throughput chart. Bucket width scales with the window
// so the chart stays readable at every zoom level.
const buildThroughputData = (traces, agents, windowMinutes, bucketSeconds = 60) => {
  const now = Date.now();
  const data = [];
  const bucketMs = bucketSeconds * 1000;
  const bucketCount = Math.max(1, Math.round((windowMinutes * 60) / bucketSeconds));

  for (let i = bucketCount - 1; i >= 0; i--) {
    const bucketStart = now - (i + 1) * bucketMs;
    const bucketEnd = now - i * bucketMs;
    const bucketTraces = traces.filter(
      (t) => t.timestamp_ms >= bucketStart && t.timestamp_ms < bucketEnd
    );

    const agentBreakdown = {};
    agents.forEach((agent) => {
      agentBreakdown[agent] = bucketTraces.filter((t) => t.agent === agent).length;
    });

    data.push({
      // Past a day, the clock alone is ambiguous — show the date too.
      time: windowMinutes > 1440
        ? new Date(bucketEnd).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit' })
        : new Date(bucketEnd).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
      timestamp: bucketEnd,
      requests: bucketTraces.length,
      errors: bucketTraces.filter((t) => t.status === 'ERROR').length,
      avgLatency: bucketTraces.length > 0
        ? Math.round(bucketTraces.reduce((a, t) => a + (t.duration_ms || 0), 0) / bucketTraces.length)
        : 0,
      traces: bucketTraces,
      ...agentBreakdown,
    });
  }
  return data;
};

// agentClass scopes the view to one agent's traces (per-agent embed: same
// component, different UX context); embedded hides the page title.
export default function TracesView({ agentClass = null, embedded = false }) {
  const { darkMode } = useTheme();
  const [traces, setTraces] = useState([]);
  const [agentsList, setAgentsList] = useState([]);
  // agent_class => platform Agent id, so a card can open that agent's page.
  const [agentIds, setAgentIds] = useState({});
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  // One trace opens at a time; its spans and their contents expand
  // independently inside it (TraceCard → TraceDetail → SpanWaterfall).
  const [selectedTrace, setSelectedTrace] = useState(null);
  // Deep link: /dashboard/traces?trace=<id> (record id, trace_id, or its
  // 8-char short form) selects and scrolls to that trace, fetching it
  // directly when it falls outside the loaded window.
  const focusTraceRef = useRef(new URLSearchParams(window.location.search).get('trace'));
  const [pinnedTrace, setPinnedTrace] = useState(null);
  const [filter, setFilter] = useState({ status: 'all', agent: 'all', action: 'all' });
  const [sortBy, setSortBy] = useState('time'); // 'time' (chronological) | 'latency' (slowest first)
  const [selectedTimeBucket, setSelectedTimeBucket] = useState(null);
  const [viewMode, setViewMode] = useState('timeline'); // 'timeline', 'agents', 'actions', or 'spans'
  const [agentRank, setAgentRank] = useState('popular'); // agents view card ranking
  const { timeWindow } = useTimeWindow();

  const fetchTraces = useCallback(async () => {
    try {
      // The shared window bounds the range; an embedded view scopes to its agent.
      const scope = agentClass ? `&agent=${encodeURIComponent(agentClass)}` : '';
      const response = await fetch(`/api/traces?minutes=${timeWindow.minutes}${scope}`);
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      const data = await response.json();
      setTraces(data.traces || []);
      setAgentsList(agentClass ? [agentClass] : (data.agents || []));
      setAgentIds(data.agent_ids || {});
      setLoadError(null);
    } catch (error) {
      setLoadError(error.message);
    } finally {
      setIsLoading(false);
    }
  }, [timeWindow.minutes, agentClass]);

  useEffect(() => {
    fetchTraces();
    const interval = setInterval(fetchTraces, REFRESH_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [fetchTraces]);

  const agentColors = useMemo(() => buildAgentColors(agentsList), [agentsList]);

  // A bucket index refers to a position in the old bucketing; it means
  // something different after a zoom, so drop the drill-down when the shared
  // window changes.
  useEffect(() => {
    setSelectedTimeBucket(null);
  }, [timeWindow.id]);

  const throughputData = useMemo(
    () => buildThroughputData(traces, agentsList, timeWindow.minutes, timeWindow.bucketSeconds),
    [traces, agentsList, timeWindow]
  );

  // Keep roughly six labels on the axis whatever the bucket count.
  const tickInterval = Math.max(0, Math.ceil(throughputData.length / 6) - 1);

  // Filter traces based on selected time bucket and filters
  const filteredTraces = useMemo(() => {
    let result = traces;

    if (selectedTimeBucket !== null) {
      const bucket = throughputData[selectedTimeBucket];
      if (bucket) {
        result = bucket.traces || [];
      }
    }

    if (filter.status !== 'all') {
      result = result.filter((t) =>
        filter.status === 'success' ? t.status !== 'ERROR' : t.status === 'ERROR'
      );
    }

    if (filter.agent !== 'all') {
      result = result.filter((t) => t.agent === filter.agent);
    }

    if (filter.action !== 'all') {
      if (filter.action.includes('#')) {
        const [agent, action] = filter.action.split('#');
        result = result.filter((t) => t.agent === agent && t.action === action);
      } else {
        result = result.filter((t) => t.action === filter.action);
      }
    }

    if (sortBy === 'latency') {
      result = [...result].sort((a, b) => (b.duration_ms || 0) - (a.duration_ms || 0));
    }

    // A deep-linked trace outside the loaded window pins to the top so the
    // link always lands somewhere.
    if (pinnedTrace && !result.some((t) => t.id === pinnedTrace.id)) {
      result = [pinnedTrace, ...result];
    }

    return result;
  }, [traces, selectedTimeBucket, throughputData, filter, sortBy, pinnedTrace]);

  useEffect(() => {
    const target = focusTraceRef.current;
    if (!target) return;
    const select = (trace) => {
      focusTraceRef.current = null;
      setSelectedTrace(trace.id);
      setTimeout(() => {
        document.getElementById(`trace-row-${trace.id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }, 150);
    };
    const match = traces.find(
      (t) => t.id === target || t.trace_id === target || (t.short_id && String(target).startsWith(t.short_id))
    );
    if (match) {
      select(match);
      return;
    }
    if (traces.length === 0) return; // wait for the first window load before falling back
    fetch(`/api/traces/${encodeURIComponent(target)}`)
      .then((response) => (response.ok ? response.json() : Promise.reject(new Error('not found'))))
      .then(({ trace }) => {
        setPinnedTrace(trace);
        select(trace);
      })
      .catch(() => {
        focusTraceRef.current = null;
      });
  }, [traces]);

  // Aggregate agent stats for selected time range
  const agentStats = useMemo(() => {
    const targetTraces = selectedTimeBucket !== null
      ? (throughputData[selectedTimeBucket]?.traces || [])
      : traces;

    const stats = {};
    targetTraces.forEach((trace) => {
      if (!trace.agent) return;
      if (!stats[trace.agent]) {
        stats[trace.agent] = {
          agent: trace.agent,
          count: 0,
          totalDuration: 0,
          cost: 0,
          errors: 0,
          actions: {},
          tokens: { thinking: 0, input: 0, output: 0 },
        };
      }
      stats[trace.agent].count++;
      stats[trace.agent].totalDuration += trace.duration_ms || 0;
      stats[trace.agent].cost += trace.estimated_cost || 0;
      if (trace.status === 'ERROR') stats[trace.agent].errors++;
      if (trace.tokens) {
        stats[trace.agent].tokens.thinking += trace.tokens.thinking || 0;
        stats[trace.agent].tokens.input += trace.tokens.input || 0;
        stats[trace.agent].tokens.output += trace.tokens.output || 0;
      }
      if (trace.action) {
        stats[trace.agent].actions[trace.action] = (stats[trace.agent].actions[trace.action] || 0) + 1;
      }
    });

    // Ranked by whichever dimension is selected. These cards are already an
    // aggregate per agent, so "popular" is meaningful here in a way it is
    // not on a list of individual executions.
    const rank = {
      popular: (s) => s.count,
      longest: (s) => s.totalDuration / (s.count || 1),
      cost: (s) => s.cost,
      // Inlined rather than totalTokensOf(): this memo runs during render,
      // before that const is initialized.
      tokens: (s) => (s.tokens.input || 0) + (s.tokens.output || 0) + (s.tokens.thinking || 0),
      errors: (s) => s.errors,
    }[agentRank] || ((s) => s.count);

    return Object.values(stats).sort((a, b) => rank(b) - rank(a) || b.count - a.count);
  }, [traces, throughputData, selectedTimeBucket, agentRank]);

  // Aggregate action stats for selected time range (Agent#action level)
  const actionStats = useMemo(() => {
    const targetTraces = selectedTimeBucket !== null
      ? (throughputData[selectedTimeBucket]?.traces || [])
      : traces;

    const stats = {};
    targetTraces.forEach((trace) => {
      if (!trace.agent) return;
      const key = `${trace.agent}#${trace.action || 'unknown'}`;
      if (!stats[key]) {
        stats[key] = {
          key,
          agent: trace.agent,
          action: trace.action || 'unknown',
          count: 0,
          totalDuration: 0,
          errors: 0,
          minDuration: Infinity,
          maxDuration: 0,
          tokens: { thinking: 0, input: 0, output: 0 },
        };
      }
      stats[key].count++;
      stats[key].totalDuration += trace.duration_ms || 0;
      stats[key].minDuration = Math.min(stats[key].minDuration, trace.duration_ms || 0);
      stats[key].maxDuration = Math.max(stats[key].maxDuration, trace.duration_ms || 0);
      if (trace.status === 'ERROR') stats[key].errors++;
      if (trace.tokens) {
        stats[key].tokens.thinking += trace.tokens.thinking || 0;
        stats[key].tokens.input += trace.tokens.input || 0;
        stats[key].tokens.output += trace.tokens.output || 0;
      }
    });

    Object.values(stats).forEach((s) => {
      if (s.minDuration === Infinity) s.minDuration = 0;
    });

    return Object.values(stats).sort((a, b) => b.count - a.count);
  }, [traces, throughputData, selectedTimeBucket]);

  // Which tools actually get called, and what they cost in aggregate. A tool
  // called 40 times for 20ms each can matter more than one 3s call, and
  // neither shows up when you're looking at a single trace's waterfall.
  const toolStats = useMemo(() => {
    const targetTraces = selectedTimeBucket !== null
      ? (throughputData[selectedTimeBucket]?.traces || [])
      : traces;

    const stats = {};
    targetTraces.forEach((trace) => {
      (trace.spans || []).forEach((span) => {
        if (span.type !== 'tool') return;
        const name = span.attributes?.['tool.name'] || span.name?.replace(/^tool\./, '') || 'unknown';

        if (!stats[name]) {
          stats[name] = {
            name,
            count: 0,
            totalDuration: 0,
            maxDuration: 0,
            errors: 0,
            agents: new Set(),
          };
        }

        stats[name].count++;
        stats[name].totalDuration += span.duration || 0;
        stats[name].maxDuration = Math.max(stats[name].maxDuration, span.duration || 0);
        if (span.error) stats[name].errors++;
        if (trace.agent) stats[name].agents.add(`${trace.agent}#${trace.action || 'unknown'}`);
      });
    });

    return Object.values(stats)
      .map((s) => ({ ...s, agents: [...s.agents], avgDuration: s.count ? s.totalDuration / s.count : 0 }))
      .sort((a, b) => b.totalDuration - a.totalDuration);
  }, [traces, throughputData, selectedTimeBucket]);

  // Get available actions for the selected agent (for filter dropdown)
  const availableActions = useMemo(() => {
    if (filter.agent === 'all') {
      return actionStats.map((s) => s.key);
    }
    return actionStats.filter((s) => s.agent === filter.agent).map((s) => s.key);
  }, [filter.agent, actionStats]);

  // Span duration ranking for the Spans view (respects filters/time bucket)
  const spanStats = useMemo(() => buildSpanStats(filteredTraces), [filteredTraces]);

  // Chart click handler
  const handleChartClick = (data) => {
    if (data && data.activeTooltipIndex !== undefined) {
      const idx = data.activeTooltipIndex;
      setSelectedTimeBucket(selectedTimeBucket === idx ? null : idx);
      setSelectedTrace(null);
    }
  };

  const totalTokensOf = (tokens) =>
    (tokens?.input || 0) + (tokens?.output || 0) + (tokens?.thinking || 0);

  // Tiles for the shared agent card, in the same order as the Agents page
  // so the two surfaces read alike.
  const agentCardStats = (stat) => {
    const errorRate = stat.count ? stat.errors / stat.count : 0;
    return [
      { label: `Calls ${timeWindow.label || ''}`.trim(), value: stat.count.toLocaleString() },
      {
        label: 'Errors',
        value: `${(errorRate * 100).toFixed(1)}%`,
        tone: stat.errors > 0 ? 'bad' : 'good',
      },
      { label: 'Avg time', value: `${Math.round(stat.totalDuration / (stat.count || 1))}ms` },
      { label: 'Tokens', value: totalTokensOf(stat.tokens).toLocaleString() },
      {
        label: 'Cost',
        value: formatCardCost(stat.cost),
        title: 'Estimated from token counts at this model\'s published rates',
        tone: stat.cost ? undefined : 'muted',
      },
      { label: 'Actions', value: (stat.agents?.length || 0).toLocaleString() },
    ];
  };

  // Card totals, not single traces: dollars with a floor, where a trace card
  // shows one run's fraction of a cent at full precision.
  const formatCardCost = (cost) => {
    if (!cost) return '—';
    if (cost < 0.01) return '<$0.01';
    return `$${cost.toFixed(2)}`;
  };

  // Rendered by both agents-view layouts (this component keeps a dark and a
  // light variant), so the control can't live in either one's markup.
  const agentRankControl = (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: '8px', marginBottom: '12px' }}>
      <span style={{ fontSize: '12px', color: darkMode ? 'rgba(255,255,255,0.5)' : '#6b7280' }}>Rank by</span>
      <select
        value={agentRank}
        onChange={(e) => setAgentRank(e.target.value)}
        style={{
          fontSize: '12px',
          padding: '4px 8px',
          borderRadius: '6px',
          border: `1px solid ${darkMode ? 'rgba(255,255,255,0.15)' : '#e5e7eb'}`,
          background: darkMode ? 'rgba(255,255,255,0.05)' : '#ffffff',
          color: darkMode ? '#f9fafb' : '#111827',
        }}
      >
        <option value="popular">Most calls</option>
        <option value="longest">Longest average</option>
        <option value="cost">Highest cost</option>
        <option value="tokens">Most tokens</option>
        <option value="errors">Most errors</option>
      </select>
    </div>
  );

  const toggleAgentFilter = (agent) =>
    setFilter((current) => ({ ...current, agent: current.agent === agent ? 'all' : agent }));

  // Open the agent behind a trace class. Falls back to filtering in place
  // when the traces aren't attributed to an Agent record (e.g. reported
  // before auto-registration, or registration failed).
  const openAgent = (agentClassName) => {
    const id = agentIds[agentClassName];
    if (!id) return toggleAgentFilter(agentClassName);

    const path = dashboardPath(`/agents/${id}`);
    window.history.pushState(window.history.state, '', path);
    // A custom event, not a synthetic popstate: Inertia listens for popstate
    // and reads event.state.component, so a hand-dispatched one (state null)
    // throws inside Inertia before our own handler ever runs.
    window.dispatchEvent(new CustomEvent('dashboard:navigate', { detail: { path } }));
  };

  // "Slowest operations" ranking across the filtered traces.
  const renderSpansBreakdown = (dark) => {
    const maxTotal = spanStats[0]?.total || 1;
    const cardBg = dark ? 'rgba(0,0,0,0.3)' : 'white';
    const border = dark ? '1px solid rgba(255,255,255,0.1)' : '1px solid #e5e7eb';
    const text = dark ? 'white' : '#111827';
    const muted = dark ? 'rgba(255,255,255,0.5)' : '#6b7280';
    const barColorByType = { llm: '#ef4444', tool: '#10b981', generate: '#8b5cf6', prompt: '#3b82f6' };
    return (
      <div style={{ padding: dark ? '0 24px 24px 24px' : 0 }}>
        <div style={{ background: cardBg, border, borderRadius: '12px', padding: '16px' }}>
          <div style={{ fontSize: '14px', fontWeight: 600, color: text, marginBottom: '4px' }}>
            Slowest operations
          </div>
          <div style={{ fontSize: '12px', color: muted, marginBottom: '14px' }}>
            Span durations aggregated across {filteredTraces.length} trace{filteredTraces.length === 1 ? '' : 's'} — ranked by total time
          </div>
          {spanStats.length === 0 ? (
            <div style={{ fontSize: '13px', color: muted, padding: '12px 0' }}>No spans in the current selection</div>
          ) : (
            <div style={{ display: 'grid', gap: '10px' }}>
              {spanStats.map((stat) => (
                <div key={stat.name} style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
                  <div style={{ width: '220px', flexShrink: 0, display: 'flex', alignItems: 'center', gap: '8px' }}>
                    <span style={{ color: muted }}>{getSpanIcon(stat.type)}</span>
                    <span style={{ fontSize: '13px', color: stat.errors > 0 ? '#ef4444' : text, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {stat.name}
                    </span>
                  </div>
                  <div style={{ flex: 1, height: '18px', background: dark ? 'rgba(255,255,255,0.06)' : '#f3f4f6', borderRadius: '4px', position: 'relative' }}>
                    <div
                      style={{
                        position: 'absolute', top: '3px', left: 0, height: '12px', borderRadius: '3px',
                        width: `${Math.max((stat.total / maxTotal) * 100, 0.5)}%`,
                        background: barColorByType[stat.type] || '#6366f1',
                      }}
                    />
                  </div>
                  <div style={{ width: '260px', flexShrink: 0, fontSize: '12px', color: muted, fontFamily: TYPOGRAPHY.mono, textAlign: 'right' }}>
                    {stat.count}× · avg {formatDuration(stat.avg)} · max {formatDuration(stat.max)} · Σ {formatDuration(stat.total)}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    );
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-red-500"></div>
      </div>
    );
  }

  const summaryStats = {
    requests: throughputData.reduce((sum, b) => sum + b.requests, 0),
    errors: throughputData.reduce((sum, b) => sum + b.errors, 0),
    avgLatency: (() => {
      const withTraffic = throughputData.filter((b) => b.requests > 0);
      if (withTraffic.length === 0) return 0;
      return Math.round(withTraffic.reduce((sum, b) => sum + b.avgLatency, 0) / withTraffic.length);
    })(),
    throughput: (throughputData.reduce((sum, b) => sum + b.requests, 0) / timeWindow.minutes).toFixed(1),
  };

  const emptyState = traces.length === 0;

  // Dark mode uses lander CSS classes, light mode uses Tailwind
  if (darkMode) {
    return (
      <div className="preview-content" style={{ borderRadius: '12px', overflow: 'hidden', minHeight: 'calc(100vh - 200px)' }}>
        {/* Header inside dark container */}
        <div style={{ padding: '24px 24px 0 24px', borderBottom: '1px solid rgba(255,255,255,0.1)', marginBottom: '16px', paddingBottom: '16px' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div>
              {!embedded && <h1 style={{ fontSize: '24px', fontWeight: 'bold', color: 'white', margin: 0 }}>Traces</h1>}
              <p style={{ fontSize: '14px', color: 'rgba(255,255,255,0.6)', marginTop: '4px' }}>
                {selectedTimeBucket !== null
                  ? `Viewing ${throughputData[selectedTimeBucket]?.time} • ${filteredTraces.length} requests`
                  : `Last ${timeWindow.label} • Click timeline to drill down`}
              </p>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              {/* View Mode Toggle */}
              <div style={{ display: 'flex', background: 'rgba(255,255,255,0.1)', borderRadius: '8px', padding: '2px' }}>
                {['timeline', 'agents', 'actions', 'tools', 'spans'].map((mode) => (
                  <button
                    key={mode}
                    onClick={() => setViewMode(mode)}
                    style={{
                      padding: '6px 12px',
                      background: viewMode === mode ? '#ef4444' : 'transparent',
                      color: 'white',
                      borderRadius: '6px',
                      border: 'none',
                      fontSize: '13px',
                      cursor: 'pointer',
                      textTransform: 'capitalize',
                    }}
                  >
                    {mode}
                  </button>
                ))}
              </div>
              {!agentClass && (
              <select
                value={filter.agent}
                onChange={(e) => setFilter({ ...filter, agent: e.target.value, action: 'all' })}
                style={{
                  padding: '8px 12px',
                  background: 'rgba(255,255,255,0.1)',
                  border: '1px solid rgba(255,255,255,0.2)',
                  borderRadius: '8px',
                  color: 'white',
                  fontSize: '14px',
                  maxWidth: '180px',
                  textOverflow: 'ellipsis'
                }}
              >
                <option value="all">All Agents</option>
                {agentsList.map((agent) => (
                  <option key={agent} value={agent}>{agent}</option>
                ))}
              </select>
              )}
              <select
                value={filter.action}
                onChange={(e) => setFilter({ ...filter, action: e.target.value })}
                style={{
                  padding: '8px 12px',
                  background: filter.action !== 'all' ? 'rgba(239, 68, 68, 0.3)' : 'rgba(255,255,255,0.1)',
                  border: filter.action !== 'all' ? '1px solid #ef4444' : '1px solid rgba(255,255,255,0.2)',
                  borderRadius: '8px',
                  color: 'white',
                  fontSize: '14px',
                  maxWidth: '220px',
                  textOverflow: 'ellipsis'
                }}
              >
                <option value="all">All Actions</option>
                {availableActions.map((action) => (
                  <option key={action} value={action}>{action}</option>
                ))}
              </select>
              <select
                value={filter.status}
                onChange={(e) => setFilter({ ...filter, status: e.target.value })}
                style={{
                  padding: '8px 12px',
                  background: 'rgba(255,255,255,0.1)',
                  border: '1px solid rgba(255,255,255,0.2)',
                  borderRadius: '8px',
                  color: 'white',
                  fontSize: '14px'
                }}
              >
                <option value="all">All Status</option>
                <option value="success">Success</option>
                <option value="error">Error</option>
              </select>
              <select
                value={sortBy}
                onChange={(e) => setSortBy(e.target.value)}
                style={{
                  padding: '8px 12px',
                  background: 'rgba(255,255,255,0.1)',
                  border: '1px solid rgba(255,255,255,0.2)',
                  borderRadius: '8px',
                  color: 'white',
                  fontSize: '14px'
                }}
              >
                <option value="time">Newest first</option>
                <option value="latency">Slowest first</option>
              </select>
              {selectedTimeBucket !== null && (
                <button
                  onClick={() => setSelectedTimeBucket(null)}
                  style={{
                    padding: '8px 16px',
                    background: 'rgba(255,255,255,0.2)',
                    color: 'white',
                    borderRadius: '8px',
                    border: 'none',
                    fontSize: '14px',
                    fontWeight: '500',
                    cursor: 'pointer'
                  }}
                >
                  Clear Selection
                </button>
              )}
            </div>
          </div>
        </div>

        {loadError && (
          <div style={{ margin: '0 24px 16px 24px', padding: '12px 16px', background: 'rgba(239, 68, 68, 0.1)', borderRadius: '8px', color: '#ef4444', fontSize: '13px' }}>
            Failed to load traces: {loadError}
          </div>
        )}

        {/* Throughput Chart - New Relic style */}
        <div style={{ padding: '0 24px', marginBottom: '24px' }}>
          <div style={{
            background: 'rgba(0,0,0,0.3)',
            borderRadius: '12px',
            padding: '16px',
            border: '1px solid rgba(255,255,255,0.1)'
          }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '12px' }}>
              <div style={{ fontSize: '14px', fontWeight: '600', color: 'white' }}>
                Agent Requests / Minute
              </div>
              <div style={{ display: 'flex', gap: '16px', flexWrap: 'wrap' }}>
                {Object.entries(agentColors).map(([agent, color]) => (
                  <div key={agent} style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                    <div style={{ width: '10px', height: '10px', borderRadius: '2px', background: color }} />
                    <span style={{ fontSize: '11px', color: 'rgba(255,255,255,0.7)' }}>
                      {agent.replace('Agent', '')}
                    </span>
                  </div>
                ))}
              </div>
            </div>
            <div style={{ height: '150px' }}>
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart
                  data={throughputData}
                  onClick={handleChartClick}
                  style={{ cursor: 'pointer' }}
                >
                  <defs>
                    {Object.entries(agentColors).map(([agent, color]) => (
                      <linearGradient key={agent} id={`gradient-${agent}`} x1="0" y1="0" x2="0" y2="1">
                        <stop offset="5%" stopColor={color} stopOpacity={0.8}/>
                        <stop offset="95%" stopColor={color} stopOpacity={0.1}/>
                      </linearGradient>
                    ))}
                  </defs>
                  <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.1)" />
                  <XAxis
                    dataKey="time"
                    stroke="rgba(255,255,255,0.5)"
                    tick={{ fontSize: 10, fill: 'rgba(255,255,255,0.5)' }}
                    tickLine={false}
                    interval={tickInterval}
                  />
                  <YAxis
                    stroke="rgba(255,255,255,0.5)"
                    tick={{ fontSize: 10, fill: 'rgba(255,255,255,0.5)' }}
                    tickLine={false}
                    axisLine={false}
                    allowDecimals={false}
                  />
                  <Tooltip
                    contentStyle={{
                      background: 'rgba(0,0,0,0.9)',
                      border: '1px solid rgba(255,255,255,0.2)',
                      borderRadius: '8px',
                      padding: '12px'
                    }}
                    labelStyle={{ color: 'white', fontWeight: '600', marginBottom: '8px' }}
                    itemStyle={{ color: 'rgba(255,255,255,0.8)', fontSize: '12px' }}
                    formatter={(value, name) => [value, name.replace('Agent', '')]}
                  />
                  {Object.keys(agentColors).map((agent) => (
                    <Area
                      key={agent}
                      type="monotone"
                      dataKey={agent}
                      stackId="1"
                      stroke={agentColors[agent]}
                      fill={`url(#gradient-${agent})`}
                    />
                  ))}
                </AreaChart>
              </ResponsiveContainer>
            </div>
            {/* Summary Stats */}
            <div style={{ display: 'flex', gap: '24px', marginTop: '12px', paddingTop: '12px', borderTop: '1px solid rgba(255,255,255,0.1)' }}>
              <div>
                <div style={{ fontSize: '20px', fontWeight: '700', color: 'white' }}>
                  {summaryStats.requests}
                </div>
                <div style={{ fontSize: '11px', color: 'rgba(255,255,255,0.5)' }}>Total Requests</div>
              </div>
              <div>
                <div style={{ fontSize: '20px', fontWeight: '700', color: '#ef4444' }}>
                  {summaryStats.errors}
                </div>
                <div style={{ fontSize: '11px', color: 'rgba(255,255,255,0.5)' }}>Errors</div>
              </div>
              <div>
                <div style={{ fontSize: '20px', fontWeight: '700', color: '#10b981' }}>
                  {summaryStats.avgLatency}ms
                </div>
                <div style={{ fontSize: '11px', color: 'rgba(255,255,255,0.5)' }}>Avg Latency</div>
              </div>
              <div>
                <div style={{ fontSize: '20px', fontWeight: '700', color: '#f59e0b' }}>
                  {summaryStats.throughput}/min
                </div>
                <div style={{ fontSize: '11px', color: 'rgba(255,255,255,0.5)' }}>Throughput</div>
              </div>
            </div>
          </div>
        </div>

        {viewMode === 'agents' && (
          <div style={{ padding: '0 24px', marginBottom: '24px' }}>
            {agentRankControl}
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: '16px' }}>
              {agentStats.map((stat) => (
                <AgentStatCard
                  key={stat.agent}
                  name={stat.agent}
                  accentColor={agentColors[stat.agent]}
                  subtitle={stat.agents?.length ? stat.agents.join(', ') : undefined}
                  badge={
                    <span style={{
                      fontSize: '12px',
                      padding: '2px 8px',
                      background: agentColors[stat.agent] + '30',
                      color: agentColors[stat.agent],
                      borderRadius: '4px',
                      whiteSpace: 'nowrap',
                    }}>
                      {stat.count} calls
                    </span>
                  }
                  onClick={() => openAgent(stat.agent)}
                  stats={agentCardStats(stat)}
                  footer={
                    <>
                      <span>{agentIds[stat.agent] ? 'Open agent →' : 'Not linked to an agent record'}</span>
                      <button
                        onClick={(e) => { e.stopPropagation(); toggleAgentFilter(stat.agent); }}
                        style={{
                          background: 'none',
                          border: 'none',
                          padding: 0,
                          cursor: 'pointer',
                          color: filter.agent === stat.agent ? '#ef4444' : 'inherit',
                          font: 'inherit',
                        }}
                      >
                        {filter.agent === stat.agent ? 'Clear filter' : 'Filter traces'}
                      </button>
                    </>
                  }
                />
              ))}
            </div>
          </div>
        )}

        {/* Actions Breakdown View - per Agent#action */}
        {viewMode === 'actions' && (
          <div style={{ padding: '0 24px', marginBottom: '24px' }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: '12px' }}>
              {actionStats.map((stat) => {
                const isActive = filter.action === stat.key;
                return (
                  <div
                    key={stat.key}
                    onClick={() => {
                      setFilter({ ...filter, action: isActive ? 'all' : stat.key });
                      setViewMode('timeline');
                    }}
                    style={{
                      background: isActive ? 'rgba(239, 68, 68, 0.15)' : 'rgba(0,0,0,0.3)',
                      borderRadius: '10px',
                      padding: '14px',
                      border: isActive ? '1px solid #ef4444' : `1px solid ${agentColors[stat.agent]}30`,
                      cursor: 'pointer',
                      transition: 'all 0.15s'
                    }}
                  >
                    {/* Header: Agent#action */}
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '10px' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                        <div style={{
                          width: '6px',
                          height: '6px',
                          borderRadius: '50%',
                          background: agentColors[stat.agent]
                        }} />
                        <span style={{ fontSize: '14px', fontWeight: '600', color: 'white' }}>
                          {stat.agent}
                        </span>
                        <span style={{ fontSize: '13px', color: 'rgba(255,255,255,0.7)' }}>
                          #{stat.action}
                        </span>
                      </div>
                      <span style={{
                        fontSize: '12px',
                        padding: '2px 8px',
                        background: agentColors[stat.agent] + '30',
                        color: agentColors[stat.agent],
                        borderRadius: '4px'
                      }}>
                        {stat.count} calls
                      </span>
                    </div>

                    {/* Metrics Row */}
                    <div style={{ display: 'flex', gap: '16px', flexWrap: 'wrap' }}>
                      <div>
                        <div style={{ fontSize: '10px', color: 'rgba(255,255,255,0.5)' }}>Avg</div>
                        <div style={{ fontSize: '13px', color: 'white', fontWeight: '500' }}>
                          {Math.round(stat.totalDuration / stat.count)}ms
                        </div>
                      </div>
                      <div>
                        <div style={{ fontSize: '10px', color: 'rgba(255,255,255,0.5)' }}>Min/Max</div>
                        <div style={{ fontSize: '13px', color: 'rgba(255,255,255,0.8)' }}>
                          {Math.round(stat.minDuration)}ms / {Math.round(stat.maxDuration)}ms
                        </div>
                      </div>
                      <div>
                        <div style={{ fontSize: '10px', color: 'rgba(255,255,255,0.5)' }}>Errors</div>
                        <div style={{ fontSize: '13px', color: stat.errors > 0 ? '#ef4444' : '#10b981' }}>
                          {stat.errors} ({((stat.errors / stat.count) * 100).toFixed(0)}%)
                        </div>
                      </div>
                      <div>
                        <div style={{ fontSize: '10px', color: 'rgba(255,255,255,0.5)' }}>Tokens</div>
                        <div style={{ fontSize: '13px', color: 'rgba(255,255,255,0.8)' }}>
                          {totalTokensOf(stat.tokens).toLocaleString()}
                        </div>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {/* Span Duration Breakdown View */}
        {viewMode === 'spans' && renderSpansBreakdown(true)}

        {/* Trace List — the same expandable trace object both themes render */}
        {viewMode === 'timeline' && !emptyState && (
          <div className="space-y-4">
            {filteredTraces.length === 0 ? (
              <div style={{ textAlign: 'center', padding: '32px', color: 'rgba(255,255,255,0.5)', fontSize: '14px' }}>
                No traces match filters
              </div>
            ) : filteredTraces.map((trace) => (
              <TraceCard
                key={trace.id}
                trace={trace}
                darkMode
                expanded={selectedTrace === trace.id}
                onToggle={() => setSelectedTrace(selectedTrace === trace.id ? null : trace.id)}
              />
            ))}
          </div>
        )}

        {emptyState && viewMode === 'timeline' && (
          <div style={{ textAlign: 'center', padding: '48px 0' }}>
            <div style={{ color: 'rgba(255,255,255,0.5)', fontSize: '18px' }}>No traces yet</div>
            <p style={{ color: 'rgba(255,255,255,0.4)', fontSize: '14px', marginTop: '8px' }}>
              Run an agent, or point your app's ActiveAgent telemetry at this workspace to see traces appear here
            </p>
          </div>
        )}
      </div>
    );
  }

  // Light mode - Tailwind classes
  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between flex-wrap gap-y-2">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Traces</h1>
          <p className="text-sm text-gray-500">
            {selectedTimeBucket !== null
              ? `Viewing ${throughputData[selectedTimeBucket]?.time} • ${filteredTraces.length} requests`
              : `Last ${timeWindow.label} • Click timeline to drill down`}
          </p>
        </div>
        {/* Wraps instead of forcing horizontal page overflow; long
            agent#action option names cap the selects, not the layout. */}
        <div className="flex items-center space-x-3 flex-wrap gap-y-2 min-w-0">
          <TimeWindowSelector />

          {/* View Mode Toggle */}
          <div className="flex bg-gray-100 rounded-lg p-1">
            {['timeline', 'agents', 'actions', 'tools', 'spans'].map((mode) => (
              <button
                key={mode}
                onClick={() => setViewMode(mode)}
                className={`px-3 py-1 text-sm rounded-md transition-colors capitalize ${
                  viewMode === mode ? 'bg-white shadow text-gray-900' : 'text-gray-600'
                }`}
              >
                {mode}
              </button>
            ))}
          </div>
          <select
            value={filter.agent}
            onChange={(e) => setFilter({ ...filter, agent: e.target.value, action: 'all' })}
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-red-500"
            style={{ maxWidth: '180px', textOverflow: 'ellipsis' }}
          >
            <option value="all">All Agents</option>
            {agentsList.map((agent) => (
              <option key={agent} value={agent}>{agent}</option>
            ))}
          </select>
          <select
            value={filter.action}
            onChange={(e) => setFilter({ ...filter, action: e.target.value })}
            className={`px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-red-500 ${
              filter.action !== 'all' ? 'border-red-500 bg-red-50' : 'border-gray-300'
            }`}
            style={{ maxWidth: '220px', textOverflow: 'ellipsis' }}
          >
            <option value="all">All Actions</option>
            {availableActions.map((action) => (
              <option key={action} value={action}>{action}</option>
            ))}
          </select>
          <select
            value={filter.status}
            onChange={(e) => setFilter({ ...filter, status: e.target.value })}
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-red-500"
          >
            <option value="all">All Status</option>
            <option value="success">Success</option>
            <option value="error">Error</option>
          </select>
          <select
            value={sortBy}
            onChange={(e) => setSortBy(e.target.value)}
            className="px-3 py-2 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-red-500"
          >
            <option value="time">Newest first</option>
            <option value="latency">Slowest first</option>
          </select>
          {selectedTimeBucket !== null && (
            <button
              onClick={() => setSelectedTimeBucket(null)}
              className="px-4 py-2 bg-gray-200 text-gray-700 rounded-lg hover:bg-gray-300 transition-colors text-sm font-medium"
            >
              Clear Selection
            </button>
          )}
        </div>
      </div>

      {loadError && (
        <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">
          Failed to load traces: {loadError}
        </div>
      )}

      {/* Throughput Chart */}
      <div className="bg-white rounded-xl border border-gray-200 p-4">
        <div className="flex justify-between items-center mb-3">
          <h3 className="text-sm font-semibold text-gray-700">Agent Requests / Minute</h3>
          <div className="flex gap-4 flex-wrap">
            {Object.entries(agentColors).map(([agent, color]) => (
              <div key={agent} className="flex items-center gap-1.5">
                <div className="w-2.5 h-2.5 rounded-sm" style={{ background: color }} />
                <span className="text-xs text-gray-500">{agent.replace('Agent', '')}</span>
              </div>
            ))}
          </div>
        </div>
        <div className="h-36">
          <ResponsiveContainer width="100%" height="100%">
            <AreaChart data={throughputData} onClick={handleChartClick} style={{ cursor: 'pointer' }}>
              <defs>
                {Object.entries(agentColors).map(([agent, color]) => (
                  <linearGradient key={agent} id={`gradient-light-${agent}`} x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor={color} stopOpacity={0.6}/>
                    <stop offset="95%" stopColor={color} stopOpacity={0.05}/>
                  </linearGradient>
                ))}
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="#e5e7eb" />
              <XAxis
                dataKey="time"
                stroke="#9ca3af"
                tick={{ fontSize: 10, fill: '#6b7280' }}
                tickLine={false}
                interval={tickInterval}
              />
              <YAxis
                stroke="#9ca3af"
                tick={{ fontSize: 10, fill: '#6b7280' }}
                tickLine={false}
                axisLine={false}
                allowDecimals={false}
              />
              <Tooltip
                contentStyle={{
                  background: 'white',
                  border: '1px solid #e5e7eb',
                  borderRadius: '8px',
                  boxShadow: '0 4px 6px -1px rgba(0,0,0,0.1)'
                }}
                labelStyle={{ color: '#111827', fontWeight: '600', marginBottom: '8px' }}
                formatter={(value, name) => [value, name.replace('Agent', '')]}
              />
              {Object.keys(agentColors).map((agent) => (
                <Area
                  key={agent}
                  type="monotone"
                  dataKey={agent}
                  stackId="1"
                  stroke={agentColors[agent]}
                  fill={`url(#gradient-light-${agent})`}
                />
              ))}
            </AreaChart>
          </ResponsiveContainer>
        </div>
        {/* Summary Stats */}
        <div className="flex gap-6 mt-3 pt-3 border-t border-gray-100">
          <div>
            <div className="text-lg font-bold text-gray-900">{summaryStats.requests}</div>
            <div className="text-xs text-gray-500">Total Requests</div>
          </div>
          <div>
            <div className="text-lg font-bold text-red-500">{summaryStats.errors}</div>
            <div className="text-xs text-gray-500">Errors</div>
          </div>
          <div>
            <div className="text-lg font-bold text-green-600">{summaryStats.avgLatency}ms</div>
            <div className="text-xs text-gray-500">Avg Latency</div>
          </div>
          <div>
            <div className="text-lg font-bold text-amber-500">{summaryStats.throughput}/min</div>
            <div className="text-xs text-gray-500">Throughput</div>
          </div>
        </div>
      </div>

      {/* Agent Breakdown View */}
      {viewMode === 'agents' && (
        <div>
          {agentRankControl}
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {agentStats.map((stat) => (
            <AgentStatCard
              key={stat.agent}
              name={stat.agent}
              accentColor={agentColors[stat.agent]}
              subtitle={stat.agents?.length ? stat.agents.join(', ') : undefined}
              badge={
                <span
                  className="text-sm px-2 py-0.5 rounded"
                  style={{ background: agentColors[stat.agent] + '20', color: agentColors[stat.agent] }}
                >
                  {stat.count} calls
                </span>
              }
              onClick={() => openAgent(stat.agent)}
              stats={agentCardStats(stat)}
              footer={
                <>
                  <span>{agentIds[stat.agent] ? 'Open agent \u2192' : 'Not linked to an agent record'}</span>
                  <button
                    onClick={(e) => { e.stopPropagation(); toggleAgentFilter(stat.agent); }}
                    className={filter.agent === stat.agent ? 'text-red-600' : 'hover:text-gray-700'}
                  >
                    {filter.agent === stat.agent ? 'Clear filter' : 'Filter traces'}
                  </button>
                </>
              }
            />
          ))}
          </div>
        </div>
      )}

      {/* Actions Breakdown View - per Agent#action */}
      {viewMode === 'actions' && (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          {actionStats.map((stat) => {
            const isActive = filter.action === stat.key;
            return (
              <div
                key={stat.key}
                onClick={() => {
                  setFilter({ ...filter, action: isActive ? 'all' : stat.key });
                  setViewMode('timeline');
                }}
                className={`rounded-xl p-4 cursor-pointer transition-all ${
                  isActive
                    ? 'bg-red-50 border-2 border-red-500'
                    : 'bg-white border border-gray-200 hover:border-gray-300'
                }`}
                style={{ borderLeftColor: agentColors[stat.agent], borderLeftWidth: isActive ? '2px' : '4px' }}
              >
                {/* Header: Agent#action */}
                <div className="flex items-center justify-between mb-3">
                  <div className="flex items-center gap-2">
                    <div
                      className="w-2 h-2 rounded-full"
                      style={{ background: agentColors[stat.agent] }}
                    />
                    <span className="font-semibold text-gray-900">{stat.agent}</span>
                    <span className="text-gray-500">#{stat.action}</span>
                  </div>
                  <span
                    className="text-xs px-2 py-0.5 rounded"
                    style={{ background: agentColors[stat.agent] + '20', color: agentColors[stat.agent] }}
                  >
                    {stat.count} calls
                  </span>
                </div>

                {/* Metrics Row */}
                <div className="flex flex-wrap gap-4 text-sm">
                  <div>
                    <div className="text-xs text-gray-500">Avg</div>
                    <div className="font-medium">{Math.round(stat.totalDuration / stat.count)}ms</div>
                  </div>
                  <div>
                    <div className="text-xs text-gray-500">Min/Max</div>
                    <div className="text-gray-600">{Math.round(stat.minDuration)}ms / {Math.round(stat.maxDuration)}ms</div>
                  </div>
                  <div>
                    <div className="text-xs text-gray-500">Errors</div>
                    <div className={stat.errors > 0 ? 'text-red-600' : 'text-green-600'}>
                      {stat.errors} ({((stat.errors / stat.count) * 100).toFixed(0)}%)
                    </div>
                  </div>
                  <div>
                    <div className="text-xs text-gray-500">Tokens</div>
                    <div className="text-gray-600">{totalTokensOf(stat.tokens).toLocaleString()}</div>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* Tool usage — which tools get called and what they cost in aggregate.
          A 20ms tool called 40 times can dominate a 3s one called once, and
          neither is visible from a single trace's waterfall. */}
      {viewMode === 'tools' && (
        toolStats.length === 0 ? (
          <div className="text-center py-8 text-gray-500 text-sm">
            No tool calls in this window
          </div>
        ) : (
          <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
            {/* Flexbox rather than a 12-col grid: grid-cols-12 / col-span-*
                aren't in the compiled Tailwind build. */}
            <div className="flex items-center gap-4 px-4 py-2 text-xs font-medium text-gray-500 border-b border-gray-100">
              <div className="flex-1">Tool</div>
              <div className="w-20 text-right">Calls</div>
              <div className="w-24 text-right">Total time</div>
              <div className="w-20 text-right">Avg</div>
              <div className="w-20 text-right">Slowest</div>
            </div>
            {toolStats.map((stat) => {
              const share = toolStats[0].totalDuration
                ? (stat.totalDuration / toolStats[0].totalDuration) * 100
                : 0;
              return (
                <div key={stat.name} className="px-4 py-2 border-b border-gray-50 last:border-0">
                  <div className="flex items-center gap-4 text-sm">
                    <div className="flex-1 min-w-0">
                      <div className="font-medium text-gray-900 truncate" title={stat.name}>{stat.name}</div>
                      {stat.agents.length > 0 && (
                        <div className="text-xs text-gray-400 truncate" title={stat.agents.join(', ')}>
                          {stat.agents.join(', ')}
                        </div>
                      )}
                    </div>
                    <div className="w-20 text-right text-gray-700" style={{ fontFamily: TYPOGRAPHY.mono }}>
                      {stat.count.toLocaleString()}
                      {stat.errors > 0 && (
                        <span className="text-red-600 ml-1" title={`${stat.errors} failed`}>
                          ({stat.errors})
                        </span>
                      )}
                    </div>
                    <div className="w-24 text-right text-gray-900 font-medium" style={{ fontFamily: TYPOGRAPHY.mono }}>
                      {formatDuration(stat.totalDuration)}
                    </div>
                    <div className="w-20 text-right text-gray-500" style={{ fontFamily: TYPOGRAPHY.mono }}>
                      {formatDuration(stat.avgDuration)}
                    </div>
                    <div className="w-20 text-right text-gray-500" style={{ fontFamily: TYPOGRAPHY.mono }}>
                      {formatDuration(stat.maxDuration)}
                    </div>
                  </div>
                  {/* Share of the heaviest tool's total time */}
                  <div className="h-1 bg-gray-100 rounded mt-1.5">
                    <div className="h-1 bg-green-500 rounded" style={{ width: `${Math.max(share, 1)}%` }} />
                  </div>
                </div>
              );
            })}
          </div>
        )
      )}
      {/* Span Duration Breakdown View */}
      {viewMode === 'spans' && renderSpansBreakdown(false)}

      {/* Trace List — see the dark branch above: one TraceCard, both themes */}
      {viewMode === 'timeline' && !emptyState && (
        <div className="space-y-4">
          {filteredTraces.length === 0 ? (
            <div className="text-center py-8 text-gray-500">No traces match filters</div>
          ) : filteredTraces.map((trace) => (
            <TraceCard
              key={trace.id}
              trace={trace}
              darkMode={false}
              expanded={selectedTrace === trace.id}
              onToggle={() => setSelectedTrace(selectedTrace === trace.id ? null : trace.id)}
            />
          ))}
        </div>
      )}

      {emptyState && viewMode === 'timeline' && (
        <div className="text-center py-12">
          <div className="text-gray-400 text-lg">No traces yet</div>
          <p className="text-gray-500 text-sm mt-2">
            Run an agent, or point your app's ActiveAgent telemetry at this workspace to see traces appear here
          </p>
        </div>
      )}
    </div>
  );
}
