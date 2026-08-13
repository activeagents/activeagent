import React from 'react';
import { SPAN_COLORS, formatDuration } from './SpanWaterfall';
import { telemetryColors } from './TelemetryObject';

// A trace compressed to one bar: each span a segment, positioned on the
// trace's wall clock and coloured by span type. It is the collapsed form of
// the waterfall — the summary a generation row shows before you open it.

export default function TraceSpanBar({ trace, darkMode, height = 8 }) {
  const colors = telemetryColors(darkMode);

  if (!trace) {
    return <div className="rounded" style={{ height: `${height}px`, background: colors.trackBg }} />;
  }

  const spans = trace.spans || [];
  const total = trace.duration_ms || 1;
  // Shallow spans first so nested ones (tools inside the generate loop) paint
  // on top of their parents.
  const layered = [...spans].sort((a, b) => (a.nested || 0) - (b.nested || 0));

  return (
    <div
      style={{
        position: 'relative',
        height: `${height}px`,
        borderRadius: '999px',
        background: colors.trackBg,
        overflow: 'hidden',
        flex: 1,
      }}
    >
      {layered.map((span, index) => (
        <div
          key={span.span_id || index}
          title={`${span.name} · ${formatDuration(span.duration)}`}
          style={{
            position: 'absolute',
            top: 0,
            bottom: 0,
            left: `${Math.min((span.start / total) * 100, 99)}%`,
            width: `${Math.max((span.duration / total) * 100, 0.8)}%`,
            background: span.error ? '#ef4444' : SPAN_COLORS[span.type] || '#9ca3af',
          }}
        />
      ))}
    </div>
  );
}
