import React, { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { MONO, Card, SegmentedControl } from './primitives';
import { fmtK, fmtMs, fmtUSD, fmtCost, fmtDelta } from '../../utils/format';
import {
  CHART_HEIGHT, maxOf, niceMax, ticksFor, linePoints, areaPoints, sparklinePoints, stackBuckets,
  SignalTile, ChartPanel, RailPanel, RailColumns, RailRow, RailFlexRow, RailEmpty, Swatch, ShareBar, MiniBar, Cell,
} from './MetricsCharts';

// APM-style service overview: golden signals → time-series grid → right rail
// of top lists. Everything on the page is derived from GET /api/metrics for
// the selected range and agent filter (see Api::MetricsController /
// MetricsReport for the payload); this file only formats and lays it out.

const REFRESH_INTERVAL_MS = 60000;

// The rail moves under the charts below this viewport width.
const NARROW_BELOW_PX = 1180;

// Range → bucket layout. Mirrors MetricsReport: 1h = 60 × 60s, 24h = 96 × 900s,
// 7d = 84 × 7200s. The labels feed the subtitle, the live indicator, the
// panel sub-lines and the tiles' "vs previous …" line.
const RANGES = {
  '1h': { n: 60, seconds: 60, bucket: '1 min', prev: 'vs previous hour', title: 'last hour' },
  '24h': { n: 96, seconds: 900, bucket: '15 min', prev: 'vs previous 24h', title: 'last 24 hours' },
  '7d': { n: 84, seconds: 7200, bucket: '2 h', prev: 'vs previous 7 days', title: 'last 7 days' },
};
const RANGE_OPTIONS = Object.keys(RANGES).map((value) => ({ value, label: value }));
const DEFAULT_RANGE = '24h';

// Agent colors by rank in the AGENTS rail (most requests first).
const AGENT_PALETTE = ['var(--chart-1)', 'var(--chart-2)', 'var(--chart-3)', 'var(--chart-5)', 'var(--chart-4)'];

// Error classes in the order the API reports them (MetricsReport::ERROR_TYPES).
const ERROR_TYPES = [
  { type: '429 rate limit', color: 'var(--color-error)' },
  { type: 'timeout', color: 'var(--color-warning)' },
  { type: 'tool error', color: 'var(--span-tool)' },
  { type: 'provider 5xx', color: 'var(--color-token-out)' },
  { type: 'other', color: 'var(--color-text-muted)' },
];
const errorTypeColor = (type) => ERROR_TYPES.find((t) => t.type === type)?.color || 'var(--color-text-muted)';

// How many deploy markers the Requests panel shows; more than a few of them
// in one window turn the plot into a picket fence.
const MAX_DEPLOY_MARKERS = 3;

const INK = 'var(--color-text-primary)';
const DELTA_COLOR = { success: 'var(--color-success)', error: 'var(--color-error)', muted: 'var(--color-text-muted)' };
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

const pad = (v) => String(v).padStart(2, '0');
const num = (v) => (v == null || Number.isNaN(Number(v)) ? 0 : Number(v));
const sum = (arr) => arr.reduce((a, b) => a + num(b), 0);
const pct1 = (v) => `${num(v).toFixed(1)}%`;
// Axis ticks keep one decimal ("1.9s") so five of them fit the 34px gutter.
const fmtMsTick = (v) => (v >= 1000 ? `${(v / 1000).toFixed(1)}s` : `${Math.round(v)}ms`);

// "15 min", "2 h", "90s" for a bucket length the RANGES table does not name.
const bucketLabelFor = (seconds) => {
  const s = num(seconds);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${+(s / 60).toFixed(1)} min`;
  return `${+(s / 3600).toFixed(1)} h`;
};

// Zero-filled buckets ending at "now", for a payload without `series`.
const emptySeries = (windowMinutes, bucketSeconds, now = Date.now()) => {
  const step = Math.max(1, num(bucketSeconds)) * 1000;
  const n = Math.max(1, Math.round((num(windowMinutes) * 60000) / step));
  const end = Math.floor(now / step) * step;
  return Array.from({ length: n }, (_, i) => ({ ts: new Date(end - (n - 1 - i) * step).toISOString() }));
};

// Shapes the payload to the contract every derivation below reads. New keys
// (totals, deltas, series, rails, markers) fall back to the legacy summary /
// by_agent keys — or to empty — so an older backend renders a quiet page
// rather than a broken one.
const normalize = (data, rangeKey) => {
  const s = data.summary || {};
  const R = RANGES[data.range] || RANGES[rangeKey] || RANGES[DEFAULT_RANGE];
  const bucketSeconds = num(data.bucket_seconds) || R.seconds;
  const windowMinutes = num(data.window_minutes) || (data.window_hours ? num(data.window_hours) * 60 : (R.n * R.seconds) / 60);
  const series = Array.isArray(data.series) ? data.series : emptySeries(windowMinutes, bucketSeconds);

  const requests = num(data.totals?.requests ?? s.total_requests);
  const cost = num(data.totals?.cost ?? s.total_cost);
  const totals = {
    requests,
    requests_per_minute: windowMinutes ? requests / windowMinutes : 0,
    p50_ms: null, p95_ms: null, p99_ms: null,
    errors: num(s.errors), error_rate: num(s.error_rate),
    tokens_in: num(s.tokens_input), tokens_out: num(s.tokens_output), tokens: num(s.tokens_used),
    cost, cost_per_request: requests ? cost / requests : 0,
    tool_calls: 0, tool_errors: 0, tool_error_rate: 0,
    ...(data.totals || {}),
  };
  const deltas = {
    requests_pct: s.requests_change ?? null, p50_pct: s.latency_change ?? null,
    error_rate_pt: null, tokens_pct: null, cost_pct: null,
    ...(data.deltas || {}),
  };
  const agents = Array.isArray(data.agents)
    ? data.agents
    : (data.by_agent || []).map((a) => ({
      name: a.name, requests: num(a.requests), share_pct: requests ? (num(a.requests) / requests) * 100 : 0,
      p95_ms: null, error_rate: a.requests ? (num(a.errors) / num(a.requests)) * 100 : 0, cost: num(a.cost), tokens: num(a.tokens),
    }));
  const errorsByType = Array.isArray(data.errors_by_type) && data.errors_by_type.length
    ? data.errors_by_type
    : ERROR_TYPES.map((t) => ({ type: t.type, count: 0 }));

  return {
    range: data.range || rangeKey,
    bucketSeconds,
    windowMinutes,
    agent: data.agent || null,
    environment: data.environment || null,
    totals,
    deltas,
    series,
    agents,
    models: Array.isArray(data.models) ? data.models : [],
    actions: Array.isArray(data.actions) ? data.actions : [],
    tools: Array.isArray(data.tools) ? data.tools : [],
    errorsByType,
    markers: Array.isArray(data.markers) ? data.markers : [],
  };
};

// Subtitle / indicator / delta copy for the range, including a `custom`
// window the API bucketed for an `hours` param.
const rangeMeta = (m) => {
  const known = RANGES[m.range];
  if (known) return known;
  const hours = Math.max(1, Math.round(m.windowMinutes / 60));
  return { bucket: bucketLabelFor(m.bucketSeconds), prev: `vs previous ${hours}h`, title: `last ${hours} hours` };
};

// True below the breakpoint where the rail should drop under the charts.
const useNarrow = (px) => {
  const [narrow, setNarrow] = useState(() => typeof window !== 'undefined' && window.innerWidth < px);
  useEffect(() => {
    const query = window.matchMedia(`(max-width: ${px - 1}px)`);
    const apply = () => setNarrow(query.matches);
    apply();
    query.addEventListener('change', apply);
    return () => query.removeEventListener('change', apply);
  }, [px]);
  return narrow;
};

export default function MetricsView() {
  const [range, setRange] = useState(DEFAULT_RANGE);
  const [agent, setAgent] = useState('');
  const [metrics, setMetrics] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  // True while a range or agent change is waiting for its response; the 60s
  // refresh is silent.
  const [pending, setPending] = useState(false);
  const requestSeq = useRef(0);
  const narrow = useNarrow(NARROW_BELOW_PX);

  const fetchMetrics = useCallback(async () => {
    const seq = ++requestSeq.current;
    try {
      const params = new URLSearchParams({ range });
      if (agent) params.set('agent', agent);
      const response = await fetch(`/api/metrics?${params.toString()}`);
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      const data = await response.json();
      if (seq !== requestSeq.current) return;
      setMetrics(data);
      setLoadError(null);
    } catch (error) {
      if (seq !== requestSeq.current) return;
      setLoadError(error.message);
    } finally {
      if (seq === requestSeq.current) setIsLoading(false);
    }
  }, [range, agent]);

  useEffect(() => {
    let cancelled = false;
    setPending(true);
    fetchMetrics().finally(() => { if (!cancelled) setPending(false); });
    const interval = setInterval(fetchMetrics, REFRESH_INTERVAL_MS);
    return () => { cancelled = true; clearInterval(interval); };
  }, [fetchMetrics]);

  const m = useMemo(() => (metrics ? normalize(metrics, range) : null), [metrics, range]);

  // The agent ranking (select options, stacked-bar colors) is read from an
  // unfiltered payload and remembered across filtered ones: a filtered
  // payload only carries the one agent, and the options and colors must not
  // change under the user when they filter.
  const [rememberedNames, setRememberedNames] = useState([]);
  useEffect(() => {
    if (!m || m.agent) return;
    const names = m.agents.map((a) => a.name).filter(Boolean);
    setRememberedNames((prev) => (prev.length === names.length && prev.every((n, i) => n === names[i]) ? prev : names));
  }, [m]);
  const rankedNames = useMemo(
    () => (m && !m.agent ? m.agents.map((a) => a.name).filter(Boolean) : rememberedNames),
    [m, rememberedNames],
  );

  // Agent → color by rank; an agent the ranking has not seen yet takes the
  // next color.
  const colorFor = useMemo(() => {
    const map = Object.fromEntries(rankedNames.map((name, i) => [name, AGENT_PALETTE[i % AGENT_PALETTE.length]]));
    let next = rankedNames.length;
    (m ? m.agents : []).forEach((a) => {
      if (a.name && !map[a.name]) map[a.name] = AGENT_PALETTE[next++ % AGENT_PALETTE.length];
    });
    return (name) => map[name] || AGENT_PALETTE[0];
  }, [rankedNames, m]);

  const view = useMemo(() => (m ? buildView(m, colorFor) : null), [m, colorFor]);

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2" style={{ borderBottomColor: 'var(--color-accent-ui)' }} />
      </div>
    );
  }

  if (loadError || !m) {
    return (
      <div>
        <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: INK }}>Metrics</h1>
        <div style={{ marginTop: 16, padding: '12px 16px', background: 'var(--color-error-soft)', borderRadius: 8, color: 'var(--color-error-text)', fontSize: 14 }}>
          Failed to load metrics{loadError ? `: ${loadError}` : ''}
        </div>
      </div>
    );
  }

  return (
    <MetricsPage
      m={m}
      view={view}
      range={RANGES[range] ? range : DEFAULT_RANGE}
      agent={agent}
      agentOptions={agent && !rankedNames.includes(agent) ? [...rankedNames, agent] : rankedNames}
      colorFor={colorFor}
      narrow={narrow}
      pending={pending}
      onRange={setRange}
      onAgent={setAgent}
    />
  );
}

// The loaded page, rendered from the normalized payload (`m`) and the values
// derived from it (`view`). Pure — state and fetching live in MetricsView —
// so it can also be rendered statically for a design check. `pending` dims
// the numbers and the live dot while a filter change is in flight.
export function MetricsPage({ m, view, range, agent, agentOptions, colorFor, narrow, pending = false, onRange, onAgent }) {
  const R = rangeMeta(m);
  const isEmpty = m.totals.requests === 0;
  const toggleAgent = (name) => onAgent(agent === name ? '' : name);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16, width: '100%', maxWidth: 1600, boxSizing: 'border-box', color: INK, fontSize: 13 }}>
      {/* Page header */}
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 16, flexWrap: 'wrap' }}>
        <div style={{ flex: 1, minWidth: 240 }}>
          <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em' }}>Metrics</h1>
          <p style={{ margin: '4px 0 0', fontSize: 14, color: 'var(--color-text-secondary)' }}>
            Requests, latency, errors, tokens and cost across every agent — {R.title}{agent ? ` · ${agent}` : ''}
          </p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          <select
            value={agent}
            onChange={(event) => onAgent(event.target.value)}
            aria-label="Filter by agent"
            style={{ padding: '6px 10px', borderRadius: 8, fontSize: 13, fontFamily: 'inherit', border: '1px solid var(--color-border-strong)', background: 'var(--color-card)', color: INK, cursor: 'pointer' }}
          >
            <option value="">All agents</option>
            {agentOptions.map((name) => <option key={name} value={name}>{name}</option>)}
          </select>
          {m.environment && (
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 10px', borderRadius: 8, border: '1px solid var(--color-border)', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-cell)', background: 'var(--color-card)' }}>
              <span style={{ color: 'var(--color-text-muted)' }}>env</span>{m.environment}
            </span>
          )}
          <SegmentedControl options={RANGE_OPTIONS} value={range} onChange={onRange} />
          <span title={pending ? 'loading…' : `refreshes every ${REFRESH_INTERVAL_MS / 1000}s`} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
            <span style={{ width: 7, height: 7, borderRadius: '50%', background: pending ? 'var(--color-text-muted)' : 'var(--color-success)' }} />
            live · {R.bucket} buckets
          </span>
        </div>
      </div>

      {isEmpty ? (
        <Card style={{ padding: '40px 24px', textAlign: 'center', fontSize: 14, color: 'var(--color-text-secondary)' }}>
          No traffic yet — run an agent, or point your app's ActiveAgent telemetry at this workspace
          <div style={{ marginTop: 8, fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
            {agent || 'all agents'} · {R.title}
          </div>
        </Card>
      ) : (
        <>
          {/* Golden signals */}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 12, opacity: pending ? 0.6 : 1 }}>
            {view.signals.map((g) => <SignalTile key={g.label} {...g} deltaSub={R.prev} />)}
          </div>

          {/* Time-series grid + right rail */}
          <div style={{ display: 'grid', gridTemplateColumns: narrow ? 'minmax(0, 1fr)' : 'minmax(0, 2.3fr) minmax(300px, 1fr)', gap: 16, alignItems: 'start', opacity: pending ? 0.6 : 1 }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 16, minWidth: 0 }}>
              {view.panels.map((p) => <ChartPanel key={p.title} {...p} xLabels={view.xLabels} height={CHART_HEIGHT} />)}
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 16, minWidth: 0 }}>
              <RailPanel label="Agents" qualifier="by requests · click to filter">
                <RailColumns template="minmax(0, 1fr) 44px 44px 40px 52px" columns={['req', 'p95', 'err', 'cost']} />
                {m.agents.length === 0 && <RailEmpty>no agents in this window</RailEmpty>}
                {m.agents.map((a) => (
                  <RailRow
                    key={a.name}
                    template="minmax(0, 1fr) 44px 44px 40px 52px"
                    active={agent === a.name}
                    onClick={() => toggleAgent(a.name)}
                    title={agent === a.name ? 'Show all agents' : `Filter to ${a.name}`}
                  >
                    <div style={{ minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0 }}>
                        <Swatch color={colorFor(a.name)} />
                        <span style={{ fontSize: 12, fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.name}</span>
                      </div>
                      <ShareBar pct={a.share_pct} color={colorFor(a.name)} />
                    </div>
                    <Cell>{fmtK(a.requests)}</Cell>
                    <Cell color="var(--color-text-secondary)">{fmtMs(a.p95_ms)}</Cell>
                    <Cell color={num(a.error_rate) >= 1.5 ? 'var(--color-error-text)' : 'var(--color-text-secondary)'}>{pct1(a.error_rate)}</Cell>
                    <Cell>{fmtUSD(a.cost)}</Cell>
                  </RailRow>
                ))}
              </RailPanel>

              <RailPanel label="Models" qualifier="by tokens">
                {m.models.length === 0 && <RailEmpty>no model usage in this window</RailEmpty>}
                {m.models.map((mo, i) => (
                  <RailRow key={`${mo.model}-${mo.provider}-${i}`} template="minmax(0, 1fr) 52px 56px">
                    <div style={{ minWidth: 0 }}>
                      <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, minWidth: 0 }}>
                        <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{mo.model || 'unknown'}</span>
                        {mo.provider && <span style={{ fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)' }}>{mo.provider}</span>}
                      </div>
                      <ShareBar pct={mo.share_pct} color="var(--color-token-in)" />
                    </div>
                    <Cell>{fmtK(mo.tokens)}</Cell>
                    <Cell color="var(--color-text-secondary)">{fmtUSD(mo.cost)}</Cell>
                  </RailRow>
                ))}
              </RailPanel>

              <RailPanel label="Slowest actions" qualifier="p95">
                {m.actions.length === 0 && <RailEmpty>no actions in this window</RailEmpty>}
                {m.actions.map((ac) => (
                  <RailFlexRow key={ac.name}>
                    <span title={ac.name} style={{ flex: 1, minWidth: 0, fontFamily: MONO, fontSize: 11, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{ac.name}</span>
                    <MiniBar pct={view.slowestP95 ? (num(ac.p95_ms) / view.slowestP95) * 100 : 0} color={colorFor(ac.agent)} />
                    <Cell weight={600} width={40}>{fmtMs(ac.p95_ms)}</Cell>
                  </RailFlexRow>
                ))}
              </RailPanel>

              <RailPanel label="Tools" qualifier="by calls">
                <RailColumns template="minmax(0, 1fr) 44px 48px 40px" columns={['calls', 'avg', 'err']} />
                {m.tools.length === 0 && <RailEmpty>no tool calls in this window</RailEmpty>}
                {m.tools.map((tl) => (
                  <RailRow key={tl.name} template="minmax(0, 1fr) 44px 48px 40px" padding="7px 14px">
                    <span title={tl.name} style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, color: 'var(--span-tool)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{tl.name}</span>
                    <Cell>{fmtK(tl.calls)}</Cell>
                    <Cell color="var(--color-text-secondary)">{fmtMs(tl.avg_ms)}</Cell>
                    <Cell color={num(tl.error_rate) >= 2 ? 'var(--color-error-text)' : 'var(--color-text-secondary)'}>{pct1(tl.error_rate)}</Cell>
                  </RailRow>
                ))}
              </RailPanel>

              <RailPanel label="Errors by type" meta={`${Math.round(m.totals.errors)} total`}>
                {m.errorsByType.map((er) => (
                  <RailFlexRow key={er.type}>
                    <Swatch color={errorTypeColor(er.type)} />
                    <span style={{ flex: 1, minWidth: 0, fontSize: 12, color: 'var(--color-text-cell)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{er.type}</span>
                    <MiniBar pct={view.errorTotal ? (num(er.count) / view.errorTotal) * 100 : 0} color={errorTypeColor(er.type)} />
                    <Cell weight={600} width={32}>{Math.round(num(er.count))}</Cell>
                  </RailFlexRow>
                ))}
              </RailPanel>
            </div>
          </div>
        </>
      )}
    </div>
  );
}

// Everything the tiles and panels show, derived once per payload: bucket
// series, nice maxima, tick labels, stacked segments, polylines, markers.
function buildView(m, colorFor) {
  const { series, totals, deltas } = m;
  const n = series.length;
  const R = rangeMeta(m);
  const times = series.map((b) => new Date(b.ts));
  const weekday = m.windowMinutes >= 48 * 60;
  const fmtT = (t) => (Number.isNaN(t.getTime())
    ? ''
    : weekday ? `${DAYS[t.getDay()]} ${pad(t.getHours())}h` : `${pad(t.getHours())}:${pad(t.getMinutes())}`);
  const xLabels = n
    ? [0, 1, 2, 3, 4, 5, 6].map((k) => (k === 6 ? 'now' : fmtT(times[Math.round((k * (n - 1)) / 6)])))
    : [];

  // Bucket series (the API zero-fills, so a missing key only means an older
  // backend — read it as 0).
  const col = (key) => series.map((b) => num(b[key]));
  const req = col('requests');
  const errs = col('errors');
  const tokIn = col('tokens_in');
  const tokOut = col('tokens_out');
  const cost = col('cost');
  const toolCalls = col('tool_calls');
  const toolErrs = col('tool_errors');
  const pctl = (key) => series.map((b) => (b[key] == null ? null : num(b[key])));
  const p50 = pctl('p50_ms');
  const p95 = pctl('p95_ms');
  const p99 = pctl('p99_ms');

  // Requests stacked by agent, layers ranked like the rail; an agent that
  // only appears inside a bucket (not in the rail) still gets a layer.
  const byAgent = series.map((b) => b.requests_by_agent || {});
  const layerNames = m.agents.map((a) => a.name).filter(Boolean);
  byAgent.forEach((bucket) => Object.keys(bucket).forEach((name) => { if (!layerNames.includes(name)) layerNames.push(name); }));
  const reqLayers = layerNames.length
    ? layerNames.map((name) => ({ label: name, color: colorFor(name), data: byAgent.map((bucket) => num(bucket[name])) }))
    : [{ label: 'requests', color: AGENT_PALETTE[0], data: req }];

  const errLayers = ERROR_TYPES.map((t) => ({ label: t.type, color: t.color, data: series.map((b) => num((b.errors_by_type || {})[t.type])) }));

  // Marker position: the bucket the timestamp falls in, as a share of the
  // plot width; the label flips to the left of the line past 55%.
  const stepMs = (num(m.bucketSeconds) || (n > 1 ? (times[1] - times[0]) / 1000 : 0)) * 1000;
  const markerAt = (mk, label) => {
    if (!mk || n < 2 || !stepMs) return null;
    const t = new Date(mk.ts).getTime();
    if (Number.isNaN(t)) return null;
    const i = Math.min(n - 1, Math.max(0, Math.floor((t - times[0].getTime()) / stepMs)));
    const f = i / (n - 1);
    return { left: f * 100, label, flip: f > 0.55 };
  };
  const deploys = m.markers
    .filter((mk) => mk.kind === 'deploy')
    .sort((a, b) => new Date(a.ts) - new Date(b.ts))
    .slice(-MAX_DEPLOY_MARKERS)
    .map((mk) => markerAt(mk, mk.label))
    .filter(Boolean);
  const incident = m.markers.find((mk) => mk.kind === 'incident');
  const incidentMarker = incident
    ? markerAt(incident, incident.agent && !String(incident.label || '').includes(incident.agent) ? `${incident.label} · ${incident.agent}` : incident.label)
    : null;
  const incidentMarkers = incidentMarker ? [incidentMarker] : [];

  const reqMax = niceMax(maxOf(req) * 1.1);
  const errMax = niceMax(maxOf(errs) * 1.15);
  const latMax = niceMax(Math.max(maxOf(p99), maxOf(p95), maxOf(p50)) * 1.05);
  const tokMax = niceMax(Math.max(maxOf(tokIn), maxOf(tokOut)) * 1.1);
  const costMax = niceMax(maxOf(cost) * 1.1);
  const toolMax = niceMax(maxOf(toolCalls) * 1.1);

  const requests = num(totals.requests);
  const rpm = num(totals.requests_per_minute);
  const errors = num(totals.errors);
  const errorRate = num(totals.error_rate);
  const tokens = num(totals.tokens) || num(totals.tokens_in) + num(totals.tokens_out);
  const spend = num(totals.cost);
  const costPerReq = totals.cost_per_request != null ? num(totals.cost_per_request) : requests ? spend / requests : 0;
  const tools = num(totals.tool_calls);
  const toolErrorRate = totals.tool_error_rate != null ? num(totals.tool_error_rate) : tools ? (num(totals.tool_errors) / tools) * 100 : 0;
  const rateLimited = num(m.errorsByType.find((e) => e.type === ERROR_TYPES[0].type)?.count);

  const panels = [
    {
      title: 'Requests', sub: `per ${R.bucket} · stacked by agent`,
      value: `${fmtK(requests)} · ${rpm.toFixed(1)}/min`,
      legend: reqLayers.map((L) => ({ label: L.label, color: L.color })),
      ticks: ticksFor(reqMax, fmtK),
      buckets: stackBuckets(reqLayers, reqMax, (i) => `${fmtT(times[i])} · ${Math.round(req[i])} req`),
      markers: deploys,
    },
    {
      title: 'Latency', sub: 'generation percentiles',
      value: `p50 ${fmtMs(totals.p50_ms)}`,
      legend: [
        { label: `p50 ${fmtMs(totals.p50_ms)}`, color: 'var(--color-token-in)' },
        { label: `p95 ${fmtMs(totals.p95_ms)}`, color: 'var(--color-warning)' },
        { label: `p99 ${fmtMs(totals.p99_ms)}`, color: 'var(--color-error)' },
      ],
      ticks: ticksFor(latMax, fmtMsTick),
      lines: [
        { points: linePoints(p99, latMax), color: 'var(--color-error)', width: 1.5 },
        { points: linePoints(p95, latMax), color: 'var(--color-warning)', width: 1.5 },
        { points: linePoints(p50, latMax), color: 'var(--color-token-in)', width: 2 },
      ],
      areas: [{ points: areaPoints(p50, latMax), color: 'var(--color-token-in)' }],
      markers: incidentMarkers,
    },
    {
      title: 'Errors', sub: `per ${R.bucket} · by type`,
      value: `${errorRate.toFixed(2)}% · ${Math.round(errors)} errors`,
      valueColor: errorRate > 1 ? 'var(--color-error)' : INK,
      legend: errLayers.map((L) => ({ label: L.label, color: L.color })),
      ticks: ticksFor(errMax, (v) => String(Math.round(v))),
      buckets: stackBuckets(errLayers, errMax, (i) => `${fmtT(times[i])} · ${Math.round(errs[i])} errors`),
      markers: incidentMarkers,
    },
    {
      title: 'Tokens', sub: `per ${R.bucket} · input / output`,
      value: `${fmtK(tokens)} · in ${fmtK(totals.tokens_in)} / out ${fmtK(totals.tokens_out)}`,
      legend: [{ label: 'input', color: 'var(--color-token-in)' }, { label: 'output', color: 'var(--color-token-out)' }],
      ticks: ticksFor(tokMax, fmtK),
      lines: [
        { points: linePoints(tokIn, tokMax), color: 'var(--color-token-in)', width: 1.5 },
        { points: linePoints(tokOut, tokMax), color: 'var(--color-token-out)', width: 1.5 },
      ],
      areas: [
        { points: areaPoints(tokIn, tokMax), color: 'var(--color-token-in)' },
        { points: areaPoints(tokOut, tokMax), color: 'var(--color-token-out)' },
      ],
    },
    {
      title: 'Cost', sub: `estimated · per ${R.bucket}`,
      value: `${fmtUSD(spend)} · ${fmtCost(costPerReq)}/req`,
      legend: [{ label: 'spend', color: 'var(--color-text-secondary)' }],
      // Sub-cent buckets keep a third decimal so the ticks are not all "$0.00".
      ticks: ticksFor(costMax, (v) => `$${v.toFixed(costMax < 0.1 ? 3 : 2)}`),
      buckets: stackBuckets([{ color: 'var(--color-text-secondary)', data: cost }], costMax, (i) => `${fmtT(times[i])} · $${cost[i].toFixed(3)}`),
    },
    {
      title: 'Tool calls', sub: `per ${R.bucket} · MCP + agent-defined`,
      value: `${fmtK(tools)} · ${toolErrorRate.toFixed(1)}% errors`,
      legend: [{ label: 'calls', color: 'var(--span-tool)' }, { label: 'errors', color: 'var(--color-error)' }],
      ticks: ticksFor(toolMax, fmtK),
      // Errors are a subset of calls, so the errored slice sits on top of the
      // successful ones and the column height stays the call count.
      buckets: stackBuckets(
        [
          { color: 'var(--span-tool)', data: toolCalls.map((v, i) => Math.max(0, v - toolErrs[i])) },
          { color: 'var(--color-error)', data: toolErrs },
        ],
        toolMax,
        (i) => `${fmtT(times[i])} · ${Math.round(toolCalls[i])} calls`,
      ),
    },
  ];

  // Delta tone: more traffic and less latency read as success, a rising
  // error rate as error; volume and spend are neutral.
  const tone = (value, good, bad) => {
    const v = value == null ? null : num(value);
    if (v == null || v === 0) return 'muted';
    if (good && good(v)) return 'success';
    if (bad && bad(v)) return 'error';
    return 'muted';
  };
  const signal = (label, value, unit, sub, delta, toneKey, seriesValues, sparkColor) => ({
    label, value, unit, sub,
    delta, deltaColor: DELTA_COLOR[toneKey],
    spark: sparklinePoints(seriesValues), sparkColor,
  });
  const signals = [
    signal('Requests', fmtK(requests), '', `${rpm.toFixed(1)} req/min`,
      fmtDelta(deltas.requests_pct), tone(deltas.requests_pct, (v) => v > 0, null), req, 'var(--color-token-in)'),
    signal('Latency', fmtMs(totals.p50_ms), 'p50', `p95 ${fmtMs(totals.p95_ms)} · p99 ${fmtMs(totals.p99_ms)}`,
      fmtDelta(deltas.p50_pct), tone(deltas.p50_pct, (v) => v < 0, (v) => v > 0), p50, 'var(--color-token-in)'),
    signal('Error rate', errorRate.toFixed(2), '%', `${Math.round(errors)} errors · ${Math.round(rateLimited)} rate-limited`,
      fmtDelta(deltas.error_rate_pt, ' pt', 1), tone(deltas.error_rate_pt, (v) => v < 0, (v) => v > 0), errs, 'var(--color-error)'),
    signal('Tokens', fmtK(tokens), '', `in ${fmtK(totals.tokens_in)} · out ${fmtK(totals.tokens_out)}`,
      fmtDelta(deltas.tokens_pct), 'muted', tokIn.map((v, i) => v + tokOut[i]), 'var(--color-token-in)'),
    signal('Cost', fmtUSD(spend), '', `${fmtCost(costPerReq)} per request`,
      fmtDelta(deltas.cost_pct), 'muted', cost, 'var(--color-text-secondary)'),
  ];

  return {
    signals,
    panels,
    xLabels,
    slowestP95: maxOf(m.actions.map((a) => a.p95_ms)),
    errorTotal: sum(m.errorsByType.map((e) => e.count)),
  };
}

// Exported for the static design check and tests.
export { normalize, buildView };
