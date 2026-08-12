import React, { useEffect, useState } from 'react';

// A trace as a pill: one segmented bar per trace (each segment a span,
// positioned on the trace's wall clock, colored by span type). Click to
// expand into a mini waterfall. Used inside interaction cards, where each
// generation/turn is one trace — the execution view embedded in the
// conversation view.

const SPAN_COLORS = {
  root: '#9ca3af',
  prompt: '#60a5fa',
  generate: '#a855f7',
  llm: '#ef4444',
  thinking: '#fbbf24',
  tool: '#22c55e',
  response: '#2dd4bf',
  embedding: '#818cf8',
};

const formatMs = (ms) => {
  if (ms == null) return '';
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(2)}s`;
};

export default function TraceSpanPills({ traceId, darkMode }) {
  const [trace, setTrace] = useState(null);
  const [failed, setFailed] = useState(false);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    let alive = true;
    fetch(`/api/traces/${encodeURIComponent(traceId)}`)
      .then((response) => (response.ok ? response.json() : Promise.reject(new Error('not found'))))
      .then(({ trace: detail }) => alive && setTrace(detail))
      .catch(() => alive && setFailed(true));
    return () => {
      alive = false;
    };
  }, [traceId]);

  if (failed) return null;

  const trackColor = darkMode ? 'rgba(255,255,255,0.08)' : '#f3f4f6';
  const mutedColor = darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af';

  if (!trace) {
    return <div className="rounded mt-1" style={{ height: '8px', background: trackColor }} />;
  }

  const spans = trace.spans || [];
  const total = trace.duration_ms || 1;
  // Shallow spans first so nested ones (tools inside the generate loop)
  // paint on top of their parents.
  const layered = [...spans].sort((a, b) => (a.nested || 0) - (b.nested || 0));

  return (
    <div className="mt-1" onClick={(e) => e.stopPropagation()}>
      <div
        onClick={() => setOpen(!open)}
        title={open ? 'Collapse spans' : `${spans.length} spans · ${formatMs(trace.duration_ms)} — click to expand`}
        style={{ display: 'flex', alignItems: 'center', gap: '8px', cursor: 'pointer' }}
      >
        <div style={{ position: 'relative', height: '8px', borderRadius: '999px', background: trackColor, overflow: 'hidden', flex: 1 }}>
          {layered.map((span, index) => (
            <div
              key={span.span_id || index}
              title={`${span.name} · ${formatMs(span.duration)}`}
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
        <span className="font-mono" style={{ fontSize: '10px', color: mutedColor, whiteSpace: 'nowrap' }}>
          {spans.length} spans {open ? '▾' : '▸'}
        </span>
      </div>
      {open && (
        <div style={{ display: 'grid', gap: '3px', marginTop: '6px' }}>
          {spans.map((span, index) => (
            <div key={span.span_id || index} style={{ display: 'flex', alignItems: 'center', gap: '8px', paddingLeft: `${(span.nested || 0) * 10}px` }}>
              <span
                className="font-mono"
                style={{ fontSize: '10px', color: span.error ? '#ef4444' : mutedColor, width: '160px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flexShrink: 0 }}
                title={span.name}
              >
                {span.name}
              </span>
              <div style={{ position: 'relative', height: '4px', borderRadius: '2px', background: trackColor, flex: 1 }}>
                <div
                  style={{
                    position: 'absolute',
                    top: 0,
                    bottom: 0,
                    left: `${Math.min((span.start / total) * 100, 99)}%`,
                    width: `${Math.max((span.duration / total) * 100, 0.8)}%`,
                    borderRadius: '2px',
                    background: span.error ? '#ef4444' : SPAN_COLORS[span.type] || '#9ca3af',
                  }}
                />
              </div>
              <span className="font-mono" style={{ fontSize: '10px', color: mutedColor, width: '52px', textAlign: 'right', flexShrink: 0 }}>
                {formatMs(span.duration)}
              </span>
            </div>
          ))}
          <a
            href={`/dashboard/traces?trace=${trace.trace_id || traceId}`}
            className="font-mono hover:underline"
            style={{ fontSize: '10px', color: '#3b82f6', justifySelf: 'start' }}
          >
            open in Traces →
          </a>
        </div>
      )}
    </div>
  );
}
