import React, { useState } from 'react';

// Context-window pressure meter (from the Active Agent design system).
// A segmented bar of what occupies the model's context — messages, tool
// results, instructions, tool/MCP schemas, generated output — against the
// window limit, with semantic thresholds: >=75% warns, >=90% signals
// imminent compaction. The blue ramp is deliberate: warning/error are the
// only warm colors here so the threshold states read as alarms.

const SEGMENT_COLORS = {
  messages: '#2563eb',
  tool_results: '#5b84ec',
  instructions: '#85a3f0',
  tool_schemas: '#a6bcf4',
  mcp_schemas: '#c3d2f8',
  memory: '#dce4fb',
  output: '#7c3aed',
};

// Context-window sizes by model family. The provider reports real token
// counts; the window is the constraint we hold them against.
export const contextWindowFor = (model) => {
  const name = (model || '').toLowerCase();
  if (name.includes('claude')) return 200000;
  if (name.includes('gemini')) return 1000000;
  if (name.includes('llama')) return 131072;
  if (name.includes('gpt-4o') || name.includes('gpt-4-turbo') || name.includes('gpt-4.1')) return 128000;
  if (name.includes('gpt-5')) return 400000;
  return 128000;
};

// ~4 chars/token, for estimating segment sizes from recorded content.
export const estimateTokens = (value) => {
  if (value == null) return 0;
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return Math.round(text.length / 4);
};

export const formatTokenCount = (value) => {
  if (value == null) return '—';
  if (value >= 1e6) return `${(value / 1e6).toFixed(1).replace(/\.0$/, '')}M`;
  if (value >= 1e3) return `${(value / 1e3).toFixed(1).replace(/\.0$/, '')}k`;
  return String(Math.round(value));
};

export default function ContextMeter({
  used,
  limit = 200000,
  segments = [],
  cached = 0,
  thinking = 0,
  compact = false,
  defaultOpen = false,
  label = 'Context window',
  estimated = false,
  darkMode = false,
}) {
  const [open, setOpen] = useState(defaultOpen);
  const shown = segments.filter((segment) => segment.tokens > 0);
  const total = used ?? shown.reduce((sum, segment) => sum + segment.tokens, 0);
  const ratio = limit > 0 ? total / limit : 0;

  const stateColor = ratio >= 0.9 ? '#dc2626' : ratio >= 0.75 ? '#eab308' : null;
  const mutedColor = darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af';
  const secondaryColor = darkMode ? 'rgba(255,255,255,0.6)' : '#6b7280';
  const cellColor = darkMode ? 'rgba(255,255,255,0.75)' : '#4b5563';
  const trackColor = darkMode ? 'rgba(255,255,255,0.1)' : '#f3f4f6';
  const valueLabel = `${formatTokenCount(total)} / ${formatTokenCount(limit)} (${Math.round(ratio * 100)}%)`;

  const segmentColor = (segment) =>
    // The messages segment recolors with the threshold so the legend always
    // keys the bar.
    segment.key === 'messages' && stateColor ? stateColor : (segment.color || SEGMENT_COLORS[segment.key] || '#2563eb');

  const bar = (height) => (
    <div style={{ display: 'flex', height, borderRadius: '999px', overflow: 'hidden', background: trackColor, flex: 1 }}>
      {shown.map((segment) => (
        <div
          key={segment.key}
          title={`${segment.label} · ${formatTokenCount(segment.tokens)}`}
          style={{ width: `${Math.min((segment.tokens / limit) * 100, 100)}%`, background: segmentColor(segment) }}
        />
      ))}
    </div>
  );

  if (compact) {
    return (
      <span
        title={`${label}: ${valueLabel}`}
        style={{ display: 'inline-flex', alignItems: 'center', gap: '6px', width: '132px', verticalAlign: 'middle' }}
      >
        {bar('6px')}
        <span style={{ fontSize: '11px', fontFamily: "'SF Mono', 'Fira Code', monospace", color: stateColor || mutedColor, whiteSpace: 'nowrap' }}>
          {Math.round(ratio * 100)}%
        </span>
      </span>
    );
  }

  return (
    <div
      style={{
        background: darkMode ? 'rgba(255,255,255,0.03)' : '#ffffff',
        border: `1px solid ${stateColor ? stateColor + '66' : darkMode ? 'rgba(255,255,255,0.1)' : '#e5e7eb'}`,
        borderRadius: '12px',
        padding: '12px 14px',
      }}
    >
      <div
        onClick={(e) => {
          e.stopPropagation();
          setOpen(!open);
        }}
        style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
      >
        <span
          style={{
            fontFamily: "'SF Mono', 'Fira Code', monospace",
            fontSize: '11px',
            fontWeight: 600,
            letterSpacing: '0.06em',
            textTransform: 'uppercase',
            color: secondaryColor,
          }}
        >
          {label}
          {estimated && <span style={{ color: mutedColor, fontWeight: 400 }}> · estimated</span>}
        </span>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: '8px' }}>
          <span style={{ fontFamily: "'SF Mono', 'Fira Code', monospace", fontSize: '12px', fontWeight: 600, color: stateColor || cellColor }}>
            {valueLabel}
          </span>
          <span
            style={{
              fontFamily: "'SF Mono', 'Fira Code', monospace",
              fontSize: '11px',
              color: mutedColor,
              display: 'inline-block',
              transform: open ? 'rotate(90deg)' : 'none',
              transition: 'transform 0.15s ease',
            }}
          >
            &gt;
          </span>
        </span>
      </div>
      <div style={{ display: 'flex', marginTop: '8px' }}>{bar('9px')}</div>
      {ratio >= 0.9 && (
        <div style={{ marginTop: '6px', fontFamily: "'SF Mono', 'Fira Code', monospace", fontSize: '11px', color: '#dc2626' }}>
          [!] compaction imminent — next turn may drop the oldest messages
        </div>
      )}
      {open && (
        <div style={{ marginTop: '10px', display: 'grid', gap: '5px' }}>
          {[...shown, { key: '__free', label: 'Free space', tokens: Math.max(limit - total, 0) }].map((segment) => (
            <div key={segment.key} style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
              <span
                style={{
                  width: '9px',
                  height: '9px',
                  borderRadius: '2px',
                  flexShrink: 0,
                  background: segment.key === '__free' ? trackColor : segmentColor(segment),
                  border: segment.key === '__free' ? `1px solid ${darkMode ? 'rgba(255,255,255,0.25)' : '#d1d5db'}` : 'none',
                }}
              />
              <span style={{ fontSize: '13px', color: cellColor, flex: 1 }}>{segment.label}</span>
              <span style={{ fontFamily: "'SF Mono', 'Fira Code', monospace", fontSize: '12px', color: secondaryColor, width: '56px', textAlign: 'right' }}>
                {formatTokenCount(segment.tokens)}
              </span>
              <span style={{ fontFamily: "'SF Mono', 'Fira Code', monospace", fontSize: '12px', color: mutedColor, width: '46px', textAlign: 'right' }}>
                {limit > 0 ? `${((segment.tokens / limit) * 100).toFixed(1)}%` : '—'}
              </span>
            </div>
          ))}
          {(cached > 0 || thinking > 0) && (
            <div
              style={{
                marginTop: '4px',
                paddingTop: '6px',
                borderTop: `1px solid ${darkMode ? 'rgba(255,255,255,0.08)' : '#f3f4f6'}`,
                display: 'flex',
                gap: '16px',
                fontFamily: "'SF Mono', 'Fira Code', monospace",
                fontSize: '11px',
                color: mutedColor,
              }}
            >
              {cached > 0 && (
                <span>
                  <span style={{ color: '#2563eb' }}>[=]</span> cached prefix {formatTokenCount(cached)}
                </span>
              )}
              {thinking > 0 && (
                <span>
                  <span style={{ color: '#7c3aed' }}>[~]</span> thinking {formatTokenCount(thinking)}
                </span>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
