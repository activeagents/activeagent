import React from 'react';
import { TYPOGRAPHY } from '../../utils/designTokens';
import ContextMeter from './ContextMeter';
import TraceDetail, { traceContext } from './TraceDetail';
import { formatDuration, traceContentPreview } from './SpanWaterfall';
import { roleBubble } from './InteractionStream';
import { Chevron, META_COLUMN, MetaStrip, ObjectCard, PreviewLines, telemetryColors } from './TelemetryObject';

// One trace as an expandable object: what ran, what it cost, what went in and
// came out — then the full waterfall or conversation underneath. The same card
// renders in both themes; the Traces view used to keep a separate dark markup
// tree that had drifted a long way from the light one.

// Null when the trace carries no counts at all: a run that failed before the
// provider answered spent an unknown amount, not zero, and the strip says so
// with a dash rather than claiming a number nobody recorded.
const formatTokens = (tokens) => {
  const total = (tokens?.input || 0) + (tokens?.output || 0) + (tokens?.thinking || 0);
  if (!total) return null;
  if (total >= 1000) return `${(total / 1000).toFixed(1)}K`;
  return `${total}`;
};

// A single trace's fraction of a cent, at full precision — card totals
// elsewhere round to dollars.
const formatCost = (cost) => (cost == null ? null : `$${cost.toFixed(4)}`);

export default function TraceCard({ trace, darkMode, expanded, onToggle }) {
  const colors = telemetryColors(darkMode);
  const preview = traceContentPreview(trace);
  const context = traceContext(trace);
  const succeeded = trace.status !== 'ERROR';
  const tokens = formatTokens(trace.tokens);

  return (
    <ObjectCard darkMode={darkMode} id={`trace-row-${trace.id}`}>
      <div
        className={`p-4 flex items-center justify-between flex-wrap gap-y-2 cursor-pointer transition-colors ${
          darkMode ? 'hover:bg-white/5' : 'hover:bg-gray-50'
        }`}
        onClick={onToggle}
        style={expanded ? { background: colors.hoverBg } : undefined}
      >
        <div className="flex items-center gap-3 min-w-0">
          <span
            className="px-2 py-1 text-xs rounded flex-shrink-0"
            style={{ fontFamily: TYPOGRAPHY.mono, background: colors.controlBg, color: colors.textSecondary }}
          >
            TRACE
          </span>
          <span className="text-sm flex-shrink-0" style={{ fontFamily: TYPOGRAPHY.mono, color: colors.textMuted }}>
            {trace.short_id}
          </span>
          <span className="text-sm font-medium truncate" style={{ color: colors.textPrimary }}>
            {trace.display_name}
          </span>
        </div>
        {/* One strip, the same columns on every row — including the rows
            with nothing to put in them. */}
        <div className="flex items-center gap-4 flex-shrink-0">
          <MetaStrip
            darkMode={darkMode}
            cells={[
              {
                key: 'model',
                title: 'Model that generated this trace',
                empty: 'No model recorded for this trace',
                content: trace.model && (
                  <span
                    className="text-xs px-2 py-0.5 rounded"
                    style={{
                      fontFamily: TYPOGRAPHY.mono,
                      background: darkMode ? 'rgba(99,102,241,0.2)' : '#eef2ff',
                      color: darkMode ? '#a5b4fc' : '#4338ca',
                    }}
                  >
                    {trace.model}
                  </span>
                ),
              },
              {
                key: 'context',
                width: META_COLUMN.context,
                empty: 'Context: no generation in this trace reported its token counts',
                content: context && <ContextMeter compact {...context} label="Context" darkMode={darkMode} />,
              },
              {
                key: 'duration',
                width: META_COLUMN.duration,
                title: 'Wall-clock duration',
                empty: 'No duration recorded for this trace',
                content: trace.duration_ms != null && (
                  <>
                    <i className="fa-solid fa-clock mr-1"></i>
                    {formatDuration(trace.duration_ms)}
                  </>
                ),
              },
              {
                key: 'tokens',
                width: META_COLUMN.tokens,
                title: 'Tokens in, out and thinking',
                empty: 'No token counts recorded for this trace',
                content: tokens && `${tokens} tokens`,
              },
              {
                key: 'cost',
                width: META_COLUMN.cost,
                title: 'Estimated cost of this trace',
                empty: 'Nothing to price — this trace recorded no tokens',
                content: trace.estimated_cost != null && (
                  <>
                    <i className="fa-solid fa-coins mr-1"></i>
                    {formatCost(trace.estimated_cost)}
                  </>
                ),
              },
              {
                key: 'status',
                width: META_COLUMN.status,
                title: succeeded ? 'Trace completed' : trace.error || 'Trace ended in an error',
                content: (
                  <span style={{ color: succeeded ? colors.good : colors.bad }}>
                    <i className={`fa-solid ${succeeded ? 'fa-check' : 'fa-xmark'} mr-1`}></i>
                    {succeeded ? 'OK' : 'ERROR'}
                  </span>
                ),
              },
            ]}
          />
          <Chevron open={expanded} darkMode={darkMode} />
        </div>
      </div>

      {!expanded && (
        <PreviewLines
          darkMode={darkMode}
          onClick={onToggle}
          hold
          style={{ padding: '0 16px 12px' }}
          lines={[
            { label: 'input', text: preview.input, color: roleBubble('user', darkMode).color },
            { label: 'output', text: preview.output, color: roleBubble('assistant', darkMode).color },
          ]}
        />
      )}

      {expanded && (
        <div className="border-t p-4" style={{ borderColor: colors.cardBorder, background: colors.innerBg }}>
          <TraceDetail trace={trace} darkMode={darkMode} />
        </div>
      )}
    </ObjectCard>
  );
}
