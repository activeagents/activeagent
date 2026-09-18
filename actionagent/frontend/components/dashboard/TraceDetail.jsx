import React, { useCallback, useEffect, useState } from 'react';
import { TYPOGRAPHY } from '../../utils/designTokens';
import ContextMeter from './ContextMeter';
import { traceContext } from '../../utils/traceContext.mjs';
import InteractionStream from './InteractionStream';
import SpanWaterfall, {
  SPAN_SORTS,
  formatDuration,
  traceTools,
} from './SpanWaterfall';
import { SegmentedControl, telemetryColors } from './TelemetryObject';

// TraceCard reads a trace's context pressure through this module.
export { traceContext };

// Everything one trace has to say, in one panel: its spans as a waterfall or
// its run as a conversation, what it held in context, where the wall clock
// went, and what it spent. Rendered under a trace row in the Traces view and
// under a generation row in an interaction — the same trace looks the same
// wherever you opened it from.

const TRACE_VIEWS = [
  { id: 'spans', label: 'Spans', hint: 'Timing waterfall with span details' },
  { id: 'conversation', label: 'Conversation', hint: 'The run as a message stream — prompt, tool calls, response' },
];

// Generation vs tool time for one trace: how much of the wall clock went to
// the LLM, to each tool, and to unattributed overhead. Tool calls run inside
// the provider's generate loop, so their time is subtracted from the llm span
// to get pure generation time — the segments sum to ~100%.
const traceTimeBreakdown = (trace) => {
  let generation = 0;
  const tools = [];
  (trace?.spans || []).forEach((span) => {
    if ((span.nested || 0) === 0) return;
    if (span.type === 'tool') {
      tools.push(span);
    } else if (span.type === 'llm' || span.type === 'generate') {
      generation = Math.max(generation, span.duration || 0);
    }
  });
  const toolTotal = tools.reduce((sum, span) => sum + (span.duration || 0), 0);
  generation = Math.max(generation - toolTotal, 0);
  const total = trace?.duration_ms || generation + toolTotal || 1;
  return { generation, tools, toolTotal, total, overhead: Math.max(total - generation - toolTotal, 0) };
};

function TraceTimeBreakdown({ trace, darkMode }) {
  const colors = telemetryColors(darkMode);
  const { generation, tools, toolTotal, total, overhead } = traceTimeBreakdown(trace);
  if (generation === 0 && toolTotal === 0) return null;
  // When generation IS the trace (llm.generate ~100%, negligible tool time),
  // the waterfall above already tells this story — skip the redundant section.
  if (generation / total >= 0.99 && toolTotal / total < 0.01) return null;

  const pct = (ms) => `${((ms / total) * 100).toFixed(ms / total < 0.01 ? 2 : 1)}%`;
  const segment = (ms, color) => (
    <div style={{ width: `${Math.max((ms / total) * 100, 0.4)}%`, background: color, height: '100%' }} />
  );

  return (
    <div style={{ marginTop: '14px', paddingTop: '12px', borderTop: `1px solid ${colors.cardBorder}` }}>
      <div style={{ fontSize: '11px', textTransform: 'uppercase', letterSpacing: '0.05em', color: colors.textSecondary, marginBottom: '6px' }}>
        Time breakdown — generation vs tools
      </div>
      <div style={{ display: 'flex', height: '10px', borderRadius: '5px', overflow: 'hidden', background: colors.trackBg }}>
        {segment(generation, '#ef4444')}
        {segment(toolTotal, '#10b981')}
        {overhead > 0 && segment(overhead, darkMode ? 'rgba(255,255,255,0.2)' : '#d1d5db')}
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 18px', marginTop: '8px', fontSize: '12px', fontFamily: TYPOGRAPHY.mono, color: colors.textBody }}>
        <span><span style={{ color: '#ef4444' }}>■</span> generation {formatDuration(generation)} ({pct(generation)})</span>
        <span><span style={{ color: '#10b981' }}>■</span> tools {formatDuration(toolTotal)} ({pct(toolTotal)})</span>
        {overhead > 0 && <span><span style={{ color: colors.textSecondary }}>■</span> overhead {formatDuration(overhead)} ({pct(overhead)})</span>}
      </div>
      {tools.length > 0 && (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 18px', marginTop: '4px', fontSize: '12px', fontFamily: TYPOGRAPHY.mono, color: colors.textSecondary }}>
          {tools.map((span, idx) => (
            <span key={idx}>{span.name} {formatDuration(span.duration)} ({pct(span.duration || 0)})</span>
          ))}
        </div>
      )}
    </div>
  );
}

// The run as a message stream. The interactions API serializes any trace as
// `trace-<id>`, so the same endpoint that backs the Interactions view answers
// for a trace opened here.
function TraceConversation({ trace, darkMode }) {
  const [detail, setDetail] = useState(null);
  const [failed, setFailed] = useState(false);
  const colors = telemetryColors(darkMode);

  useEffect(() => {
    if (trace?.id == null) return undefined;
    let alive = true;
    setDetail(null);
    setFailed(false);
    fetch(`/api/interactions/trace-${trace.id}`)
      .then((response) => (response.ok ? response.json() : Promise.reject(new Error('request failed'))))
      .then((data) => alive && setDetail(data.interaction))
      .catch(() => alive && setFailed(true));
    return () => {
      alive = false;
    };
  }, [trace?.id]);

  if (failed) {
    return <div className="text-sm py-4" style={{ color: colors.bad }}>Couldn't load the conversation for this trace.</div>;
  }
  if (!detail) {
    return <div className="text-sm py-4" style={{ color: colors.textMuted }}>Loading conversation…</div>;
  }

  const messages = detail.instructions
    ? [
        { id: `trace-${trace.id}-system`, role: 'system', content: detail.instructions, created_at: detail.created_at },
        ...(detail.messages || []),
      ]
    : (detail.messages || []);

  if (messages.length === 0) {
    return (
      <div className="text-sm py-4" style={{ color: colors.textMuted }}>
        This trace predates content capture — no conversation to show.
      </div>
    );
  }

  return <InteractionStream messages={messages} darkMode={darkMode} tools={traceTools(trace)} />;
}

// `compact` drops the trace-level footers (tokens, provider, error) for
// contexts that already state them — a generation row inside an interaction
// prints its own token line right above this panel.
export default function TraceDetail({ trace, darkMode, compact = false, showConversation = true }) {
  const [view, setView] = useState('spans');
  const [sort, setSort] = useState('time');
  const colors = telemetryColors(darkMode);
  const spanCount = (trace?.spans || []).length;
  const context = traceContext(trace);
  const tokens = trace?.tokens || {};

  const setViewSafely = useCallback((next) => setView(showConversation ? next : 'spans'), [showConversation]);

  if (!trace) return null;

  return (
    <div>
      <div className="flex items-center justify-between flex-wrap gap-y-2 mb-2">
        <div className="flex items-center gap-1">
          {showConversation && (
            <SegmentedControl options={TRACE_VIEWS} value={view} onChange={setViewSafely} darkMode={darkMode} />
          )}
          <span className="text-xs ml-2" style={{ color: colors.textSecondary }}>
            {spanCount} {spanCount === 1 ? 'span' : 'spans'}
          </span>
        </div>
        {view === 'spans' && spanCount > 0 && (
          <SegmentedControl options={SPAN_SORTS} value={sort} onChange={setSort} darkMode={darkMode} label="Sort" />
        )}
      </div>

      {view === 'conversation' ? (
        <div className="rounded-lg border p-4" style={{ background: colors.cardBg, borderColor: colors.cardBorder }}>
          <TraceConversation trace={trace} darkMode={darkMode} />
        </div>
      ) : (
        <>
          {/* The axis describes a timeline, which only holds while the spans
              are in chronological order. */}
          {sort === 'time' ? (
            <div className="flex justify-between text-xs mb-2" style={{ color: colors.textMuted }}>
              <span>0ms</span>
              <span>{Math.round((trace.duration_ms || 0) * 0.33)}ms</span>
              <span>{Math.round((trace.duration_ms || 0) * 0.66)}ms</span>
              <span>{formatDuration(trace.duration_ms)}</span>
            </div>
          ) : (
            <div className="text-xs mb-2" style={{ color: colors.textMuted }}>
              Bar length compares duration on a log scale
            </div>
          )}
          <SpanWaterfall trace={trace} darkMode={darkMode} sort={sort} keyPrefix={`${trace.id || trace.trace_id}:`} />
        </>
      )}

      {context && (
        <div className="mt-3">
          <ContextMeter {...context} label="Context pressure" darkMode={darkMode} />
        </div>
      )}

      <TraceTimeBreakdown trace={trace} darkMode={darkMode} />

      {!compact && (
        <div
          className="mt-4 pt-4 border-t flex items-center flex-wrap gap-x-6 gap-y-1 text-sm"
          style={{ borderColor: colors.cardBorder, color: colors.textSecondary }}
        >
          <span>Tokens:</span>
          {tokens.thinking > 0 && (
            <span className="text-amber-500" style={{ fontFamily: TYPOGRAPHY.mono }}>T:{tokens.thinking.toLocaleString()}</span>
          )}
          <span className="text-blue-500" style={{ fontFamily: TYPOGRAPHY.mono }}>in:{(tokens.input || 0).toLocaleString()}</span>
          <span className="text-green-500" style={{ fontFamily: TYPOGRAPHY.mono }}>out:{(tokens.output || 0).toLocaleString()}</span>
          {trace.provider && (
            <span style={{ fontFamily: TYPOGRAPHY.mono }}>{trace.provider}{trace.model ? ` · ${trace.model}` : ''}</span>
          )}
        </div>
      )}

      {trace.error && (
        <div
          className="mt-4 p-3 rounded-lg border"
          style={{
            background: darkMode ? 'rgba(239,68,68,0.1)' : '#fef2f2',
            borderColor: darkMode ? 'rgba(239,68,68,0.3)' : '#fecaca',
          }}
        >
          <span className="text-sm" style={{ color: darkMode ? '#fca5a5' : '#b91c1c' }}>{trace.error}</span>
        </div>
      )}
    </div>
  );
}
