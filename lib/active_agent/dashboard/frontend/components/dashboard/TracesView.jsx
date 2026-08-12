import React, { useState, useEffect, useMemo, useCallback, useRef } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer
} from 'recharts';
import { ICONS, TYPOGRAPHY } from '../../utils/designTokens';
import InteractionStream, { roleBubble } from './InteractionStream';
import ToolRoster from './ToolRoster';
import ContextMeter, { contextWindowFor, estimateTokens } from './ContextMeter';
import { useTimeWindow } from '../../contexts/TimeWindowContext';
import AgentStatCard from './AgentStatCard';
import TimeWindowSelector from './TimeWindowSelector';

// Deterministic color assignment for agent classes
const AGENT_PALETTE = ['#6366f1', '#10b981', '#f59e0b', '#ec4899', '#3b82f6', '#8b5cf6', '#14b8a6', '#f97316'];

const REFRESH_INTERVAL_MS = 30000;

// Bar width on a log scale, for comparing durations that span orders of
// magnitude. A 5ms tool beside a 13.58s generation is a 2700x range; linearly
// every tool collapses to the same minimum-width stub. Floors at 4% so the
// shortest span is still visibly a bar.
const logWidthPercent = (duration, longest) => {
  const value = Math.max(duration || 0, 1);
  const max = Math.max(longest || 1, 1);
  if (max <= 1) return 100;

  const ratio = Math.log(value) / Math.log(max);
  return Math.min(100, Math.max(4, ratio * 100));
};

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
  const [selectedTrace, setSelectedTrace] = useState(null);
  // Deep link: /dashboard/traces?trace=<id> (record id, trace_id, or its
  // 8-char short form) selects and scrolls to that trace, fetching it
  // directly when it falls outside the loaded window.
  const focusTraceRef = useRef(new URLSearchParams(window.location.search).get('trace'));
  const [pinnedTrace, setPinnedTrace] = useState(null);
  const [expandedSpan, setExpandedSpan] = useState(null); // `${trace.id}:${span_id || idx}`
  // Content attributes (inputs/outputs) render minimized; each expands
  // independently. Keyed `${span_id}:${attribute}`.
  const [expandedAttributes, setExpandedAttributes] = useState({});
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

  // Waterfall ordering. 'time' preserves the parent/child reading order a
  // waterfall depends on; the others flatten it deliberately to answer
  // "what was slowest?" or "which tool ran most?".
  const [spanSort, setSpanSort] = useState('time');
  // Per-trace expanded view: the 'spans' waterfall or the interaction-style
  // 'conversation' stream (same renderer as the Interactions view; the
  // interactions API serializes any trace as trace-<id>).
  const [traceViews, setTraceViews] = useState({});
  const [traceConversations, setTraceConversations] = useState({});

  const showTraceConversation = (traceId) => {
    setTraceViews((prev) => ({ ...prev, [traceId]: 'conversation' }));
    if (traceConversations[traceId]) return;
    setTraceConversations((prev) => ({ ...prev, [traceId]: 'loading' }));
    fetch(`/api/interactions/trace-${traceId}`)
      .then((response) => (response.ok ? response.json() : Promise.reject(new Error('request failed'))))
      .then((data) => setTraceConversations((prev) => ({ ...prev, [traceId]: data.interaction })))
      .catch(() => setTraceConversations((prev) => ({ ...prev, [traceId]: 'error' })));
  };

  const renderTraceConversation = (trace, dark) => {
    const detail = traceConversations[trace.id];
    if (!detail || detail === 'loading') {
      return <div className="text-sm text-gray-400 py-4">Loading conversation…</div>;
    }
    if (detail === 'error') {
      return <div className="text-sm text-red-500 py-4">Couldn't load the conversation for this trace.</div>;
    }
    const messages = detail.instructions
      ? [
          { id: `trace-${trace.id}-system`, role: 'system', content: detail.instructions, created_at: detail.created_at },
          ...(detail.messages || []),
        ]
      : (detail.messages || []);
    if (messages.length === 0) {
      return <div className="text-sm text-gray-400 py-4">This trace predates content capture — no conversation to show.</div>;
    }
    return <InteractionStream messages={messages} darkMode={dark} tools={traceTools(trace)} />;
  };

  const sortSpans = useCallback((spans) => {
    const list = [...(spans || [])];
    switch (spanSort) {
      case 'duration':
        return list.sort((a, b) => (b.duration || 0) - (a.duration || 0));
      case 'name':
        return list.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
      default:
        return list.sort((a, b) => (a.start || 0) - (b.start || 0));
    }
  }, [spanSort]);

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

  const formatDuration = (ms) => {
    if (ms == null) return '—';
    if (ms < 1000) return `${Math.round(ms)}ms`;
    return `${(ms / 1000).toFixed(2)}s`;
  };

  const formatTokens = (tokens) => {
    if (!tokens) return '0';
    const total = (tokens.input || 0) + (tokens.output || 0) + (tokens.thinking || 0);
    if (total >= 1000) return `${(total / 1000).toFixed(1)}K`;
    return `${total}`;
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

  // Card totals, not single traces: dollars with a floor, where formatCost
  // below shows a single trace's fraction of a cent at full precision.
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

    const path = `/dashboard/agents/${id}`;
    window.history.pushState(window.history.state, '', path);
    // A custom event, not a synthetic popstate: Inertia listens for popstate
    // and reads event.state.component, so a hand-dispatched one (state null)
    // throws inside Inertia before our own handler ever runs.
    window.dispatchEvent(new CustomEvent('dashboard:navigate', { detail: { path } }));
  };

  // Span attribute values: pretty-print embedded JSON (tool.arguments,
  // tool.result), pass everything else through as text.
  const formatAttrValue = (value) => {
    if (value == null) return '—';
    const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
    if (typeof value === 'string' && /^[\[{]/.test(value.trim())) {
      try {
        return JSON.stringify(JSON.parse(value), null, 2);
      } catch {
        return text;
      }
    }
    return text;
  };

  const formatCost = (cost) => {
    if (cost == null) return null;
    return `$${cost.toFixed(4)}`;
  };

  const getSpanIcon = (type) => {
    switch (type) {
      case 'root': return ICONS.spans.root;
      case 'prompt': return ICONS.spans.prompt;
      case 'generate': return ICONS.spans.generate;
      case 'llm': return ICONS.spans.llm;
      case 'thinking': return ICONS.spans.thinking;
      case 'tool': return ICONS.spans.tool;
      case 'response': return ICONS.spans.response;
      default: return '-';
    }
  };

  const isSuccess = (trace) => trace.status !== 'ERROR';

  const spanShareLabel = (span, trace) => {
    if (!trace.duration_ms) return formatDuration(span.duration);
    const share = ((span.duration || 0) / trace.duration_ms) * 100;
    return `${formatDuration(span.duration)} · ${share < 1 ? share.toFixed(2) : share.toFixed(1)}%`;
  };

  const spanTokens = (span) => {
    const tokens = span.tokens || {};
    return (tokens.input || 0) + (tokens.output || 0) + (tokens.thinking || 0);
  };

  // Attribute values that hold JSON payloads (tool inputs/outputs) get
  // pretty-printed blocks; everything else renders inline.
  const prettyAttribute = (value) => {
    if (typeof value !== 'string') return null;
    try {
      return JSON.stringify(JSON.parse(value), null, 2);
    } catch {
      return null;
    }
  };

  // Expanded detail panel for a single span (attributes, tokens, ids).
  // At-a-glance contents for a trace row: the latest user input and the
  // final output, pulled from span content attributes (either SDK's shape —
  // RubyLLM's llm.prompt/llm.completion or ActiveAgent's
  // prompt.input.messages/llm.output.message).
  const traceContentPreview = (trace) => {
    const spans = trace.spans || [];
    const attr = (key) => {
      for (const span of spans) {
        const value = (span.attributes || {})[key];
        if (value) return value;
      }
      return null;
    };
    let input = attr('llm.prompt');
    if (!input) {
      const raw = attr('prompt.input.messages');
      if (raw) {
        try {
          const messages = JSON.parse(raw);
          const lastUser = [...messages].reverse().find((m) => m && m.role === 'user' && m.content);
          input = lastUser?.content;
        } catch {
          // not JSON — skip the preview rather than show markup soup
        }
      }
    }
    const output = attr('llm.completion') || attr('llm.output.message');
    return { input, output };
  };

  const previewText = (text, max = 200) => {
    const clean = String(text).replace(/\s+/g, ' ').trim();
    return clean.length > max ? `${clean.slice(0, max)}…` : clean;
  };

  // Per-span input/output previews so prompt and generate rows read the
  // same way tool rows do — what went in, what came out, at a glance.
  // Labels carry the role's color: blue user input, red agent output/args,
  // amber tool results.
  const spanContentPreview = (span) => {
    const attrs = span.attributes || {};
    let input = null;
    let inputLabel = 'input:';
    let inputTone = 'user';
    if (attrs['prompt.input.messages']) {
      try {
        const parsed = JSON.parse(attrs['prompt.input.messages']);
        const lastUser = [...parsed].reverse().find((m) => m && m.role === 'user' && m.content);
        if (typeof lastUser?.content === 'string') input = lastUser.content;
      } catch {
        // not JSON — no preview
      }
    }
    if (!input && attrs['llm.prompt']) input = String(attrs['llm.prompt']);
    if (!input && (attrs['tool.input.args'] || attrs['tool.arguments'])) {
      const args = attrs['tool.input.args'] || attrs['tool.arguments'];
      input = typeof args === 'string' ? args : JSON.stringify(args);
      inputLabel = 'in:';
      inputTone = 'assistant';
    }
    let output = null;
    let outputLabel = 'output:';
    let outputTone = 'assistant';
    if (attrs['llm.output.message'] || attrs['llm.completion']) {
      output = attrs['llm.output.message'] || attrs['llm.completion'];
    } else if (attrs['tool.output.result'] || attrs['tool.result']) {
      output = attrs['tool.output.result'] || attrs['tool.result'];
      outputLabel = 'out:';
      outputTone = 'tool';
    }
    if (output != null && typeof output !== 'string') output = JSON.stringify(output);
    return { input, output, inputLabel, inputTone, outputLabel, outputTone };
  };

  // Span preview minus whatever the trace header already says — the
  // trace-level input/output lines shouldn't repeat on their source spans.
  const dedupedSpanPreview = (span, trace) => {
    const preview = spanContentPreview(span);
    const traceLevel = traceContentPreview(trace);
    if (preview.input && preview.input === traceLevel.input) preview.input = null;
    if (preview.output && preview.output === traceLevel.output) preview.output = null;
    return preview;
  };

  // Context pressure: what the biggest generation in this trace held against
  // the model's window. Segment sizes are estimated from recorded content
  // (~4 chars/token); the input/output totals are the provider's real counts.
  const traceContext = (trace) => {
    const spans = trace.spans || [];
    let peak = null;
    for (const span of spans) {
      const tokens = span.tokens || {};
      const total = (tokens.input || 0) + (tokens.output || 0);
      if (total > 0 && (!peak || total > peak.total)) {
        peak = {
          input: tokens.input || 0,
          output: tokens.output || 0,
          thinking: tokens.thinking || 0,
          cached: tokens.cached || 0,
          total,
        };
      }
    }
    if (!peak) return null;

    const attr = (key) => {
      for (const span of spans) {
        const value = (span.attributes || {})[key];
        if (value) return value;
      }
      return null;
    };
    // Both telemetry shapes: ActiveAgent SDK (prompt.input.*, tool.input/
    // output.*) and the RubyLLM adapter (llm.instructions/tools,
    // tool.arguments/result).
    const instructions = estimateTokens(attr('prompt.input.instructions') || attr('llm.instructions'));
    const toolSchemas = estimateTokens(attr('prompt.input.tools') || attr('llm.tools'));
    const mcpSchemas = estimateTokens(attr('prompt.input.mcp_tools'));
    let toolResults = 0;
    for (const span of spans) {
      const attrs = span.attributes || {};
      const result = attrs['tool.output.result'] || attrs['tool.result'];
      const args = attrs['tool.input.args'] || attrs['tool.arguments'];
      if (result) toolResults += estimateTokens(result);
      if (args) toolResults += estimateTokens(args);
    }
    toolResults = Math.min(toolResults, peak.input);
    const messages = Math.max(peak.input - instructions - toolSchemas - mcpSchemas - toolResults, 0);

    return {
      used: peak.total,
      limit: contextWindowFor(trace.model),
      cached: peak.cached,
      thinking: peak.thinking,
      segments: [
        { key: 'messages', label: 'Messages', tokens: messages },
        { key: 'tool_results', label: 'Tool results', tokens: toolResults },
        { key: 'instructions', label: 'Instructions', tokens: instructions },
        { key: 'tool_schemas', label: 'Tool schemas', tokens: toolSchemas },
        { key: 'mcp_schemas', label: 'MCP tool schemas', tokens: mcpSchemas },
        { key: 'output', label: 'Generated output', tokens: peak.output },
      ],
    };
  };

  // Display order for span attributes: system message first, then the tool
  // roster, then everything else, with the (long) message history last.
  // jsonb storage normalizes key order, so sorting has to happen here.
  const attributeRank = (key) => {
    if (key.endsWith('.instructions')) return 0;
    if (key.endsWith('.tools')) return 1;
    if (key.endsWith('.messages')) return 3;
    return 2;
  };

  // Lift a span's content attributes (instructions, prompt messages, tool
  // args/results, completions — either SDK shape) into InteractionStream
  // messages so span contents read like the Interactions view. Everything
  // else stays a raw attribute row.
  const spanMessages = (span) => {
    const rest = { ...(span.attributes || {}) };
    const take = (key) => {
      const value = rest[key];
      delete rest[key];
      return value;
    };
    const messages = [];
    const push = (m) => messages.push({ id: `${span.span_id}-m${messages.length}`, ...m });

    const instructions = take('prompt.input.instructions') || take('llm.instructions');
    if (instructions) push({ role: 'system', content: String(instructions) });

    const rawMessages = take('prompt.input.messages');
    if (rawMessages) {
      try {
        JSON.parse(rawMessages).forEach((m) => {
          if (!m) return;
          push({
            role: m.role || 'user',
            content: typeof m.content === 'string' ? m.content : JSON.stringify(m.content),
            tool_call_id: m.tool_call_id,
            tool_calls: m.tool_calls,
          });
        });
      } catch {
        rest['prompt.input.messages'] = rawMessages;
      }
    }

    const prompt = take('llm.prompt');
    if (prompt) push({ role: 'user', content: String(prompt) });

    const toolArgs = take('tool.input.args') || take('tool.arguments');
    const toolResult = take('tool.output.result') || take('tool.result');
    if (toolArgs || toolResult) {
      const toolName = take('tool.name');
      push({
        role: 'tool',
        tool_name: toolName || (span.name || '').replace(/^tool\./, ''),
        tool_arguments: toolArgs,
        content: toolResult ? String(toolResult) : null,
      });
    }

    const completion = take('llm.completion');
    const outputMessage = take('llm.output.message');
    if (completion || outputMessage) push({ role: 'assistant', content: String(completion || outputMessage) });

    return { messages, rest };
  };

  // The tool schemas a trace carried (from whichever span recorded them) —
  // lets tool messages anywhere in the trace link back to their definition.
  const traceTools = (trace) => {
    for (const span of trace.spans || []) {
      const raw = (span.attributes || {})['prompt.input.tools'];
      if (!raw) continue;
      try {
        const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
        if (Array.isArray(parsed) && parsed.length > 0) return parsed;
      } catch {
        // unparseable — fall through
      }
    }
    return [];
  };

  const renderSpanDetails = (span, dark, knownTools = []) => {
    const { messages, rest } = spanMessages(span);
    let rosterTools = null;
    const rawTools = rest['prompt.input.tools'];
    if (rawTools) {
      try {
        const parsed = typeof rawTools === 'string' ? JSON.parse(rawTools) : rawTools;
        if (Array.isArray(parsed) && parsed.length > 0) {
          rosterTools = parsed;
          delete rest['prompt.input.tools'];
        }
      } catch {
        // unparseable — keep the raw attribute row
      }
    }
    const attributes = Object.entries(rest).sort(
      (a, b) => attributeRank(a[0]) - attributeRank(b[0])
    );
    const textColor = dark ? 'rgba(255,255,255,0.75)' : '#4b5563';
    const mutedColor = dark ? 'rgba(255,255,255,0.45)' : '#9ca3af';
    const preStyle = {
      background: dark ? 'rgba(255,255,255,0.06)' : '#eef0f3',
      borderRadius: '6px',
      padding: '6px 8px',
      margin: '2px 0 4px 0',
      overflowX: 'auto',
      whiteSpace: 'pre',
    };
    return (
      <div
        style={{
          margin: '4px 0 8px 0',
          padding: '10px 12px',
          borderRadius: '8px',
          background: dark ? 'rgba(0,0,0,0.35)' : '#f9fafb',
          border: `1px solid ${dark ? 'rgba(255,255,255,0.1)' : '#e5e7eb'}`,
          fontFamily: TYPOGRAPHY.mono,
          fontSize: '12px',
          color: textColor,
        }}
      >
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 20px' }}>
          <span>duration: {formatDuration(span.duration)}</span>
          <span>status: {span.status || 'OK'}</span>
          {spanTokens(span) > 0 && (
            <span>
              tokens in:{span.tokens.input || 0} out:{span.tokens.output || 0}
              {span.tokens.thinking > 0 ? ` thinking:${span.tokens.thinking}` : ''}
            </span>
          )}
          <span style={{ color: mutedColor }}>span: {span.span_id}</span>
        </div>
        {(() => {
          // A lone tool message condenses to bare call lines — the chip
          // shell earns its keep in conversations, not in a span card.
          const toolMessage = messages.length === 1 && messages[0].role === 'tool' ? messages[0] : null;
          if (!toolMessage) return null;
          const toolColor = roleBubble('tool', dark).color;
          const args = toolMessage.tool_arguments == null
            ? null
            : typeof toolMessage.tool_arguments === 'string'
              ? toolMessage.tool_arguments
              : JSON.stringify(toolMessage.tool_arguments);
          return (
            <div
              onClick={(e) => e.stopPropagation()}
              style={{ marginTop: '8px', display: 'grid', gap: '4px', cursor: 'default' }}
            >
              <div style={{ fontSize: '12px', wordBreak: 'break-all' }}>
                <span style={{ color: toolColor }}>⚙ {toolMessage.tool_name}</span>
                {args && (
                  <>
                    {' '}
                    <span style={{ color: roleBubble('assistant', dark).color }}>in:</span>{' '}
                    <span style={{ color: textColor }}>{args}</span>
                  </>
                )}
              </div>
              {toolMessage.content && (
                <div style={{ fontSize: '12px' }}>
                  <span style={{ color: toolColor }}>out:</span>{' '}
                  <span
                    style={{
                      color: textColor,
                      whiteSpace: 'pre-wrap',
                      display: 'inline-block',
                      maxHeight: '240px',
                      overflowY: 'auto',
                      verticalAlign: 'top',
                      maxWidth: '100%',
                    }}
                  >
                    {toolMessage.content}
                  </span>
                </div>
              )}
            </div>
          );
        })()}
        {messages.length > 0 && !(messages.length === 1 && messages[0].role === 'tool') && (
          <div
            onClick={(e) => e.stopPropagation()}
            style={{ marginTop: '10px', fontFamily: 'ui-sans-serif, system-ui, sans-serif', cursor: 'default' }}
          >
            <InteractionStream messages={messages} darkMode={dark} tools={rosterTools || knownTools} />
          </div>
        )}
        {rosterTools && <ToolRoster tools={rosterTools} darkMode={dark} />}
        {attributes.length > 0 && (
          <div style={{ marginTop: '6px', display: 'grid', gap: '2px' }}>
            {attributes.map(([key, value]) => {
              const pretty = key.match(/args|result|input|output/) ? prettyAttribute(value) : null;
              // Plain-text prose (rendered instructions) gets a wrapped block
              // rather than one inline run-on line.
              const prose = !pretty && (key.endsWith('.instructions') || key.match(/input|output|result/)) && typeof value === 'string' ? value : null;
              const block = pretty || prose;
              if (!block) {
                return (
                  <div key={key} style={{ wordBreak: 'break-all' }}>
                    <span style={{ color: mutedColor }}>{key}:</span>{' '}
                    {typeof value === 'string' ? value : JSON.stringify(value)}
                  </div>
                );
              }
              // Content blocks start minimized to one preview line; each
              // toggles independently of the span and its sibling attributes.
              const attributeKey = `${span.span_id}:${key}`;
              const isOpen = !!expandedAttributes[attributeKey];
              return (
                <div key={key}>
                  <div
                    onClick={(e) => {
                      e.stopPropagation();
                      setExpandedAttributes((prev) => ({ ...prev, [attributeKey]: !prev[attributeKey] }));
                    }}
                    title={isOpen ? 'Collapse' : 'Expand'}
                    style={{ cursor: 'pointer', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}
                  >
                    <span style={{ color: mutedColor }}>{isOpen ? '▾' : '▸'} {key}:</span>{' '}
                    {!isOpen && <span style={{ color: mutedColor }}>{previewText(block, 140)}</span>}
                  </div>
                  {isOpen && (
                    <pre
                      onClick={(e) => e.stopPropagation()}
                      style={prose ? { ...preStyle, whiteSpace: 'pre-wrap' } : preStyle}
                    >{block}</pre>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    );
  };

  // Generation vs tool time for one trace: how much of the wall clock went
  // to the LLM, to each tool, and to unattributed overhead. Tool calls run
  // inside the provider's generate loop, so their time is subtracted from
  // the llm span to get pure generation time — the segments sum to ~100%.
  const traceTimeBreakdown = (trace) => {
    let generation = 0;
    const tools = [];
    (trace.spans || []).forEach((span) => {
      if ((span.nested || 0) === 0) return;
      if (span.type === 'tool') {
        tools.push(span);
      } else if (span.type === 'llm' || span.type === 'generate') {
        generation = Math.max(generation, span.duration || 0);
      }
    });
    const toolTotal = tools.reduce((sum, span) => sum + (span.duration || 0), 0);
    generation = Math.max(generation - toolTotal, 0);
    const total = trace.duration_ms || generation + toolTotal || 1;
    return { generation, tools, toolTotal, total, overhead: Math.max(total - generation - toolTotal, 0) };
  };

  const renderTraceBreakdown = (trace, dark) => {
    const { generation, tools, toolTotal, total, overhead } = traceTimeBreakdown(trace);
    if (generation === 0 && toolTotal === 0) return null;
    // When generation IS the trace (llm.generate ~100%, negligible tool
    // time), the waterfall above already tells this story — skip the
    // redundant section.
    if (generation / total >= 0.99 && toolTotal / total < 0.01) return null;
    const muted = dark ? 'rgba(255,255,255,0.5)' : '#6b7280';
    const text = dark ? 'rgba(255,255,255,0.85)' : '#374151';
    const pct = (ms) => `${((ms / total) * 100).toFixed(ms / total < 0.01 ? 2 : 1)}%`;
    const segment = (ms, color) => (
      <div style={{ width: `${Math.max((ms / total) * 100, 0.4)}%`, background: color, height: '100%' }} />
    );
    return (
      <div style={{ marginTop: '14px', paddingTop: '12px', borderTop: `1px solid ${dark ? 'rgba(255,255,255,0.1)' : '#e5e7eb'}` }}>
        <div style={{ fontSize: '11px', textTransform: 'uppercase', letterSpacing: '0.05em', color: muted, marginBottom: '6px' }}>
          Time breakdown — generation vs tools
        </div>
        <div style={{ display: 'flex', height: '10px', borderRadius: '5px', overflow: 'hidden', background: dark ? 'rgba(255,255,255,0.08)' : '#f3f4f6' }}>
          {segment(generation, '#ef4444')}
          {segment(toolTotal, '#10b981')}
          {overhead > 0 && segment(overhead, dark ? 'rgba(255,255,255,0.2)' : '#d1d5db')}
        </div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 18px', marginTop: '8px', fontSize: '12px', fontFamily: TYPOGRAPHY.mono, color: text }}>
          <span><span style={{ color: '#ef4444' }}>■</span> generation {formatDuration(generation)} ({pct(generation)})</span>
          <span><span style={{ color: '#10b981' }}>■</span> tools {formatDuration(toolTotal)} ({pct(toolTotal)})</span>
          {overhead > 0 && <span><span style={{ color: muted }}>■</span> overhead {formatDuration(overhead)} ({pct(overhead)})</span>}
        </div>
        {tools.length > 0 && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 18px', marginTop: '4px', fontSize: '12px', fontFamily: TYPOGRAPHY.mono, color: muted }}>
            {tools.map((span, idx) => (
              <span key={idx}>{span.name} {formatDuration(span.duration)} ({pct(span.duration || 0)})</span>
            ))}
          </div>
        )}
      </div>
    );
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

        {/* Trace List */}
        {viewMode === 'timeline' && !emptyState && (
        <div className="preview-traces">
          {filteredTraces.length === 0 ? (
            <div style={{ textAlign: 'center', padding: '32px' }}>
              <div style={{ color: 'rgba(255,255,255,0.5)', fontSize: '14px' }}>
                No traces match filters
              </div>
            </div>
          ) : filteredTraces.map((trace) => (
            <React.Fragment key={trace.id}>
              <div
                className="trace-header-row"
                id={`trace-row-${trace.id}`}
                onClick={() => setSelectedTrace(selectedTrace === trace.id ? null : trace.id)}
                style={{ cursor: 'pointer' }}
              >
                <div className="trace-id">
                  <span className="trace-badge">TRACE</span>
                  <span className="trace-hash">{trace.short_id}</span>
                  <span style={{ marginLeft: '12px', color: 'rgba(255,255,255,0.9)', fontWeight: '500' }}>
                    {trace.display_name}
                  </span>
                </div>
                <div className="trace-meta">
                  {trace.model && (
                    <span
                      className="meta-item"
                      title="Model that generated this trace"
                      style={{ fontFamily: TYPOGRAPHY.mono, background: 'rgba(99,102,241,0.2)', color: '#a5b4fc', padding: '2px 8px', borderRadius: '4px' }}
                    >
                      {trace.model}
                    </span>
                  )}
                  {(() => {
                    const ctx = traceContext(trace);
                    return ctx ? <ContextMeter compact {...ctx} label="Context" darkMode /> : null;
                  })()}
                  <span className="meta-item"><i className="fa-solid fa-clock"></i> {formatDuration(trace.duration_ms)}</span>
                  <span className="meta-item">{formatTokens(trace.tokens)} tokens</span>
                  {trace.estimated_cost != null && (
                    <span className="meta-item"><i className="fa-solid fa-coins"></i> {formatCost(trace.estimated_cost)}</span>
                  )}
                  <span className={`meta-item ${isSuccess(trace) ? 'success' : 'error'}`}>
                    <i className={`fa-solid ${isSuccess(trace) ? 'fa-check' : 'fa-xmark'}`}></i> {isSuccess(trace) ? 'OK' : 'ERROR'}
                  </span>
                </div>
              </div>

              {(() => {
                const preview = traceContentPreview(trace);
                if (!preview.input && !preview.output) return null;
                return (
                  <div
                    onClick={() => setSelectedTrace(selectedTrace === trace.id ? null : trace.id)}
                    style={{ cursor: 'pointer', padding: '0 16px 10px', fontSize: '12px', fontFamily: TYPOGRAPHY.mono, color: 'rgba(255,255,255,0.6)', display: 'grid', gap: '2px' }}
                  >
                    {preview.input && (
                      <div style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                        <span style={{ color: 'rgba(255,255,255,0.35)' }}>input:</span> {previewText(preview.input)}
                      </div>
                    )}
                    {preview.output && (
                      <div style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                        <span style={{ color: 'rgba(255,255,255,0.35)' }}>output:</span> {previewText(preview.output)}
                      </div>
                    )}
                  </div>
                );
              })()}

              {selectedTrace === trace.id && (
                <div className="trace-timeline">
                  <div className="timeline-scale">
                    <span>0ms</span>
                    <span>{Math.round((trace.duration_ms || 0) * 0.33)}ms</span>
                    <span>{Math.round((trace.duration_ms || 0) * 0.66)}ms</span>
                    <span>{formatDuration(trace.duration_ms)}</span>
                  </div>

                  {(trace.spans || []).map((span, idx) => {
                    const spanKey = `${trace.id}:${idx}`;
                    const spanAttrs = span.attributes || {};
                    const hasDetails = Object.keys(spanAttrs).length > 0;
                    const isExpanded = expandedSpan === spanKey;
                    return (
                      <React.Fragment key={idx}>
                        <div
                          className={`span-row ${span.nested ? `nested-${Math.min(span.nested, 3)}` : ''}`}
                          onClick={hasDetails ? () => setExpandedSpan(isExpanded ? null : spanKey) : undefined}
                          style={hasDetails ? { cursor: 'pointer' } : undefined}
                          title={hasDetails ? 'Click for span details' : undefined}
                        >
                          <div className="span-label">
                            <span className={`span-icon ${span.type}`}>{getSpanIcon(span.type)}</span>
                            <span className={`span-name ${span.error ? 'error' : ''}`}>{span.name}</span>
                          </div>
                          <div className="span-bar-container">
                            <div
                              className={`span-bar ${span.type} ${span.error ? 'error' : ''}`}
                              style={{
                                left: `${trace.duration_ms ? (span.start / trace.duration_ms) * 100 : 0}%`,
                                width: `${trace.duration_ms ? Math.max((span.duration / trace.duration_ms) * 100, 2) : 2}%`
                              }}
                            ></div>
                          </div>
                          <span
                            style={{
                              flexShrink: 0, width: '130px', textAlign: 'right', fontSize: '11px',
                              fontFamily: TYPOGRAPHY.mono, color: 'rgba(255,255,255,0.55)', paddingLeft: '8px'
                            }}
                          >
                            {spanShareLabel(span, trace)}
                          </span>
                        </div>
                        {(() => {
                          if (isExpanded) return null;
                          const preview = dedupedSpanPreview(span, trace);
                          if (!preview.input && !preview.output) return null;
                          return (
                            <div
                              onClick={hasDetails ? () => setExpandedSpan(isExpanded ? null : spanKey) : undefined}
                              style={{
                                padding: '0 0 4px 24px',
                                fontFamily: TYPOGRAPHY.mono,
                                fontSize: '11px',
                                color: 'rgba(255,255,255,0.5)',
                                display: 'grid',
                                gap: '1px',
                                cursor: hasDetails ? 'pointer' : 'default',
                              }}
                            >
                              {preview.input && (
                                <div style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                                  <span style={{ color: roleBubble(preview.inputTone, true).color }}>{preview.inputLabel}</span> {previewText(preview.input, 140)}
                                </div>
                              )}
                              {preview.output && (
                                <div style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                                  <span style={{ color: roleBubble(preview.outputTone, true).color }}>{preview.outputLabel}</span> {previewText(preview.output, 140)}
                                </div>
                              )}
                            </div>
                          );
                        })()}
                        {isExpanded && renderSpanDetails(span, true, traceTools(trace))}
                      </React.Fragment>
                    );
                  })}

                  {(() => {
                    const ctx = traceContext(trace);
                    return ctx ? (
                      <div style={{ margin: '10px 0' }} onClick={(e) => e.stopPropagation()}>
                        <ContextMeter {...ctx} label="Context pressure" estimated darkMode />
                      </div>
                    ) : null;
                  })()}

                  {renderTraceBreakdown(trace, true)}

                  {/* Token Breakdown Row */}
                  <div className="span-row nested-3">
                    <div className="span-label">
                      <span className="span-icon" style={{ fontFamily: TYPOGRAPHY.mono }}>+--</span>
                      <span className="span-name tokens" style={{ fontFamily: TYPOGRAPHY.mono }}>
                        {totalTokensOf(trace.tokens).toLocaleString()} tokens
                      </span>
                    </div>
                    <div className="span-bar-container">
                      <div className="token-breakdown" style={{ fontFamily: TYPOGRAPHY.mono }}>
                        {trace.tokens.thinking > 0 && (
                          <span className="token-thinking">T:{trace.tokens.thinking.toLocaleString()}</span>
                        )}
                        <span className="token-in">in:{trace.tokens.input.toLocaleString()}</span>
                        <span className="token-out">out:{trace.tokens.output.toLocaleString()}</span>
                      </div>
                    </div>
                  </div>

                  {trace.error && (
                    <div style={{ padding: '12px 16px', background: 'rgba(239, 68, 68, 0.1)', borderRadius: '6px', marginTop: '12px' }}>
                      <span style={{ color: '#ef4444', fontSize: '13px' }}>
                        <i className="fa-solid fa-exclamation-triangle" style={{ marginRight: '8px' }}></i>
                        {trace.error}
                      </span>
                    </div>
                  )}
                </div>
              )}
            </React.Fragment>
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

      {/* Trace List */}
      {viewMode === 'timeline' && !emptyState && (
      <div className="space-y-4">
        {filteredTraces.length === 0 ? (
          <div className="text-center py-8 text-gray-500">No traces match filters</div>
        ) : filteredTraces.map((trace) => (
          <div
            key={trace.id}
            id={`trace-row-${trace.id}`}
            className="bg-white rounded-xl border border-gray-200 overflow-hidden hover:border-gray-300 transition-colors"
          >
            {/* Trace Header */}
            <div
              className="p-4 flex items-center justify-between cursor-pointer hover:bg-gray-50"
              onClick={() => setSelectedTrace(selectedTrace === trace.id ? null : trace.id)}
            >
              <div className="flex items-center space-x-4">
                <div className="flex items-center space-x-2">
                  <span className="px-2 py-1 bg-gray-100 text-gray-600 text-xs font-mono rounded">TRACE</span>
                  <span className="text-sm font-mono text-gray-500">{trace.short_id}</span>
                </div>
                <span className="text-sm font-medium text-gray-900">
                  {trace.display_name}
                </span>
              </div>
              <div className="flex items-center space-x-4">
                {trace.model && (
                  <span
                    className="text-xs px-2 py-0.5 rounded bg-indigo-50 text-indigo-700"
                    style={{ fontFamily: TYPOGRAPHY.mono }}
                    title="Model that generated this trace"
                  >
                    {trace.model}
                  </span>
                )}
                {(() => {
                  const ctx = traceContext(trace);
                  return ctx ? <ContextMeter compact {...ctx} label="Context" /> : null;
                })()}
                <span className="text-sm text-gray-500">
                  <i className="fa-solid fa-clock mr-1"></i>
                  {formatDuration(trace.duration_ms)}
                </span>
                <span className="text-sm text-gray-500">
                  {formatTokens(trace.tokens)} tokens
                </span>
                {trace.estimated_cost != null && (
                  <span className="text-sm text-gray-500">
                    <i className="fa-solid fa-coins mr-1"></i>
                    {formatCost(trace.estimated_cost)}
                  </span>
                )}
                <span className={`text-sm ${isSuccess(trace) ? 'text-green-600' : 'text-red-600'}`}>
                  <i className={`fa-solid ${isSuccess(trace) ? 'fa-check' : 'fa-xmark'} mr-1`}></i>
                  {isSuccess(trace) ? 'OK' : 'ERROR'}
                </span>
              </div>
            </div>

            {(() => {
              const preview = traceContentPreview(trace);
              if (!preview.input && !preview.output) return null;
              return (
                <div
                  className="px-4 pb-3 cursor-pointer"
                  onClick={() => setSelectedTrace(selectedTrace === trace.id ? null : trace.id)}
                  style={{ fontFamily: TYPOGRAPHY.mono, fontSize: '12px', display: 'grid', gap: '2px' }}
                >
                  {preview.input && (
                    <div className="text-gray-500" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                      <span className="text-gray-400">input:</span> {previewText(preview.input)}
                    </div>
                  )}
                  {preview.output && (
                    <div className="text-gray-500" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                      <span className="text-gray-400">output:</span> {previewText(preview.output)}
                    </div>
                  )}
                </div>
              );
            })()}

            {/* Expanded Timeline */}
            {selectedTrace === trace.id && (
              <div className="border-t border-gray-100 p-4 bg-gray-50">
                <div className="flex items-center justify-between mb-2">
                  <div className="flex items-center gap-1">
                    {[
                      { id: 'spans', label: 'Spans', hint: 'Timing waterfall with span details' },
                      { id: 'conversation', label: 'Conversation', hint: 'The run as a message stream — prompt, tool calls, response' },
                    ].map((option) => (
                      <button
                        key={option.id}
                        onClick={(e) => {
                          e.stopPropagation();
                          if (option.id === 'conversation') showTraceConversation(trace.id);
                          else setTraceViews((prev) => ({ ...prev, [trace.id]: 'spans' }));
                        }}
                        title={option.hint}
                        className={`px-2 py-0.5 text-xs rounded transition-colors ${
                          (traceViews[trace.id] || 'spans') === option.id ? 'bg-white shadow text-gray-900' : 'text-gray-500 hover:bg-white'
                        }`}
                      >
                        {option.label}
                      </button>
                    ))}
                    <span className="text-xs text-gray-500 ml-2">
                      {(trace.spans || []).length} spans
                    </span>
                  </div>
                  {(traceViews[trace.id] || 'spans') === 'spans' && (
                    <div className="flex items-center gap-1">
                      <span className="text-xs text-gray-400 mr-1">Sort</span>
                      {[
                        { id: 'time', label: 'Time', hint: 'Chronological — reads as a waterfall' },
                        { id: 'duration', label: 'Slowest', hint: 'Longest-running first' },
                        { id: 'name', label: 'Name', hint: 'Group repeated tool calls together' },
                      ].map((option) => (
                        <button
                          key={option.id}
                          onClick={(e) => { e.stopPropagation(); setSpanSort(option.id); }}
                          title={option.hint}
                          className={`px-2 py-0.5 text-xs rounded transition-colors ${
                            spanSort === option.id ? 'bg-white shadow text-gray-900' : 'text-gray-500 hover:bg-white'
                          }`}
                        >
                          {option.label}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
                {(traceViews[trace.id] || 'spans') === 'conversation' && (
                  <div className="bg-white rounded-lg border border-gray-200 p-4">
                    {renderTraceConversation(trace, false)}
                  </div>
                )}

                {(traceViews[trace.id] || 'spans') === 'spans' && (<>
                {/* The axis describes a timeline, which only holds while the
                    spans are in chronological order. */}
                {spanSort === 'time' ? (
                  <div className="flex justify-between text-xs text-gray-400 mb-2">
                    <span>0ms</span>
                    <span>{Math.round((trace.duration_ms || 0) * 0.33)}ms</span>
                    <span>{Math.round((trace.duration_ms || 0) * 0.66)}ms</span>
                    <span>{formatDuration(trace.duration_ms)}</span>
                  </div>
                ) : (
                  <div className="text-xs text-gray-400 mb-2">
                    Bar length compares duration on a log scale
                  </div>
                )}

                <div className="space-y-2">
                  {sortSpans(trace.spans).map((span, idx, sortedSpans) => {
                    const longestSpan = Math.max(...sortedSpans.map((s) => s.duration || 0), 1);
                    // Key on span_id, not index — indices shift when sorted,
                    // which would move an open detail panel to another row.
                    const spanKey = `${trace.id}:${span.span_id || idx}`;
                    const spanAttrs = span.attributes || {};
                    const hasDetails = Object.keys(spanAttrs).length > 0;
                    const isExpanded = expandedSpan === spanKey;
                    return (
                      <React.Fragment key={spanKey}>
                        <div
                          className={`group py-0.5 ${hasDetails ? 'cursor-pointer hover:bg-gray-100 rounded' : ''}`}
                          // Indentation encodes parent/child nesting, which no
                          // longer holds once the list is reordered.
                          style={{ paddingLeft: spanSort === 'time' ? `${(span.nested || 0) * 16}px` : 0 }}
                          onClick={hasDetails ? () => setExpandedSpan(isExpanded ? null : spanKey) : undefined}
                          title={hasDetails ? `${span.name} — click for span details` : span.name}
                        >
                          {/* Name above the track, not beside it: a fixed label
                              column truncated every tool.* span to the same
                              unreadable prefix. */}
                          <div className="flex items-baseline gap-2 min-w-0">
                            <span className={`flex-shrink-0 ${span.type === 'thinking' ? '' : 'text-gray-400'}`}>
                              {getSpanIcon(span.type)}
                            </span>
                            <span className={`text-sm font-medium ${span.error ? 'text-red-600' : 'text-gray-800'}`}>
                              {span.name}
                            </span>
                            <span className="text-xs text-gray-400 ml-auto flex-shrink-0" style={{ fontFamily: TYPOGRAPHY.mono }}>
                              {formatDuration(span.duration)}
                            </span>
                          </div>
                          <div className="h-3 relative bg-gray-100 rounded mt-0.5">
                            <div
                              className={`absolute h-3 rounded transition-opacity ${
                                span.type === 'root' ? 'bg-gray-400' :
                                span.type === 'prompt' ? 'bg-blue-400' :
                                span.type === 'generate' ? 'bg-purple-500' :
                                span.type === 'llm' ? 'bg-red-500' :
                                span.type === 'thinking' ? 'bg-amber-400' :
                                span.type === 'tool' ? 'bg-green-500' :
                                span.type === 'response' ? 'bg-teal-400' : 'bg-gray-300'
                              } ${span.error ? 'bg-red-400' : ''}`}
                              style={{
                                // Chronological order earns wall-clock offsets:
                                // the bar's position is when it ran. Any other
                                // order breaks that link, so bars left-align and
                                // become a pure length comparison — otherwise
                                // "slowest first" shows short bars scattered
                                // across the track and reads as neither.
                                left: spanSort === 'time'
                                  ? `${trace.duration_ms ? (span.start / trace.duration_ms) * 100 : 0}%`
                                  : 0,
                                width: spanSort === 'time'
                                  ? `${trace.duration_ms ? Math.max((span.duration / trace.duration_ms) * 100, 1) : 1}%`
                                  // Log scale: span durations here span three
                                  // orders of magnitude (5ms tool, 13.58s llm),
                                  // so a linear bar renders every tool as the
                                  // same 1px minimum and compares nothing.
                                  : `${logWidthPercent(span.duration, longestSpan)}%`
                              }}
                            />
                          </div>
                          <span
                            className="flex-shrink-0 text-right text-xs text-gray-400 pl-2"
                            style={{ width: '130px', fontFamily: TYPOGRAPHY.mono }}
                          >
                            {spanShareLabel(span, trace)}
                          </span>
                          {(() => {
                            // The expanded details panel carries the stylized
                            // content — don't say it twice.
                            if (isExpanded) return null;
                            const preview = dedupedSpanPreview(span, trace);
                            if (!preview.input && !preview.output) return null;
                            return (
                              <div
                                className="min-w-0"
                                style={{ fontFamily: TYPOGRAPHY.mono, fontSize: '11px', display: 'grid', gap: '1px', marginTop: '2px' }}
                              >
                                {preview.input && (
                                  <div className="text-gray-500" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                                    <span style={{ color: roleBubble(preview.inputTone, false).color }}>{preview.inputLabel}</span> {previewText(preview.input, 160)}
                                  </div>
                                )}
                                {preview.output && (
                                  <div className="text-gray-500" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                                    <span style={{ color: roleBubble(preview.outputTone, false).color }}>{preview.outputLabel}</span> {previewText(preview.output, 160)}
                                  </div>
                                )}
                              </div>
                            );
                          })()}
                        </div>
                        {isExpanded && renderSpanDetails(span, false, traceTools(trace))}
                      </React.Fragment>
                    );
                  })}
                </div>
                </>)}

                {(() => {
                  const ctx = traceContext(trace);
                  return ctx ? (
                    <div className="mt-3" onClick={(e) => e.stopPropagation()}>
                      <ContextMeter {...ctx} label="Context pressure" estimated />
                    </div>
                  ) : null;
                })()}

                {renderTraceBreakdown(trace, false)}

                <div className="mt-4 pt-4 border-t border-gray-200 flex items-center space-x-6">
                  <span className="text-sm text-gray-500">Tokens:</span>
                  {trace.tokens.thinking > 0 && (
                    <span className="text-sm text-amber-600" style={{ fontFamily: TYPOGRAPHY.mono }}>T:{trace.tokens.thinking.toLocaleString()}</span>
                  )}
                  <span className="text-sm text-blue-600" style={{ fontFamily: TYPOGRAPHY.mono }}>in:{trace.tokens.input.toLocaleString()}</span>
                  <span className="text-sm text-green-600" style={{ fontFamily: TYPOGRAPHY.mono }}>out:{trace.tokens.output.toLocaleString()}</span>
                  {trace.provider && (
                    <span className="text-sm text-gray-500" style={{ fontFamily: TYPOGRAPHY.mono }}>{trace.provider}{trace.model ? ` · ${trace.model}` : ''}</span>
                  )}
                </div>

                {trace.error && (
                  <div className="mt-4 p-3 bg-red-50 border border-red-200 rounded-lg">
                    <span className="text-sm text-red-700">{trace.error}</span>
                  </div>
                )}
              </div>
            )}
          </div>
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
