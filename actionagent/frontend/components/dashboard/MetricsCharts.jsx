import React, { useState, useRef, useEffect, useLayoutEffect } from 'react';
import { MONO, MicroLabel, Card } from './primitives';

// Chart building blocks for the APM-style Metrics view: the golden-signal
// tiles, the six time-series panels and the right-rail list panels, plus the
// scaling math they share. Rendering only — every number arrives pre-derived
// from MetricsView — and every color is a design token, so the same markup
// renders in both themes. Nothing here animates.

export const CHART_HEIGHT = 150;

const sum = (arr) => arr.reduce((a, b) => a + (Number(b) || 0), 0);
const mean = (arr) => (arr.length ? sum(arr) / arr.length : 0);

// Largest numeric value in a series; nulls (a percentile over zero
// requests) are ignored. An empty series has a max of 0.
export const maxOf = (arr) => arr.reduce((m, v) => (v != null && Number(v) > m ? Number(v) : m), 0);

// The y-axis ceiling: the smallest of 1 / 2 / 2.5 / 5 / 10 × 10ⁿ at or above
// v. Callers pass max × 1.1 (× 1.05 latency, × 1.15 errors) for headroom.
export const niceMax = (v) => {
  if (!(v > 0)) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  const m = v / p;
  return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * p;
};

// Five gridlines at 0/25/50/75/100% of the plot, labelled top-down.
export const ticksFor = (max, fmt) => [0, 25, 50, 75, 100].map((t) => ({ top: t, label: fmt(max * (1 - t / 100)) }));

// Count axes never go below this ceiling, so the five tick labels stay
// distinct integers (4 3 2 1 0) when a window has one or two of something
// per bucket; niceMax(1) alone would label them "2 2 1 1 0".
export const MIN_COUNT_MAX = 4;
export const countMax = (v) => Math.max(MIN_COUNT_MAX, niceMax(v));

// Decimals for a money axis: the fewest (at least `min`) that label every
// tick within 10% of a gridline step, so "$0.001 $0.001 $0.001 $0.000"
// becomes "$0.00100 $0.00075 $0.00050 $0.00025" while a $1 axis keeps
// "$1.00 $0.75 $0.50 $0.25". Labels that close to their value can never
// collide.
export const tickDecimals = (max, min = 2, cap = 5) => {
  const step = max / 4;
  for (let d = min; d < cap; d++) {
    const fits = [1, 2, 3, 4].every((k) => Math.abs(step * k - Number((step * k).toFixed(d))) <= step * 0.1);
    if (fits) return d;
  }
  return cap;
};

// Mono 9px advance and the label's own padding + offset, for deciding which
// side of a marker line its label fits on.
const MARKER_CHAR_PX = 5.5;
const MARKER_LABEL_PAD_PX = 12;

// Which side of the line a marker label goes: `mk.flip` (the 55% rule) is
// the baseline, overridden once the plot is measured and the label would
// not fit on that side while the other side has more room.
export const markerFlip = (mk, plotWidth) => {
  const flip = Boolean(mk.flip);
  if (!(plotWidth > 0)) return flip;
  const need = String(mk.label || '').length * MARKER_CHAR_PX + MARKER_LABEL_PAD_PX;
  const leftRoom = (Number(mk.left) / 100) * plotWidth;
  const rightRoom = plotWidth - leftRoom;
  if (flip) return !(leftRoom < need && rightRoom > leftRoom);
  return rightRoom < need && leftRoom > rightRoom;
};

// The plot's rendered width, kept current by a ResizeObserver (window
// resize when the browser lacks one). 0 until measured — and always 0 in
// a static render — which leaves marker labels on the 55% rule.
const useIsoLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect;
const useMeasuredWidth = (ref) => {
  const [width, setWidth] = useState(0);
  useIsoLayoutEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    const measure = () => setWidth(el.clientWidth);
    measure();
    if (typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', measure);
      return () => window.removeEventListener('resize', measure);
    }
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [ref]);
  return width;
};

// Polyline points in the 100×100 viewBox. Buckets without a value are
// skipped so the line bridges the gap instead of plunging to zero.
export const linePoints = (values, max) => {
  const n = values.length;
  const pts = [];
  values.forEach((v, i) => {
    if (v == null || Number.isNaN(Number(v))) return;
    const x = n > 1 ? (i / (n - 1)) * 100 : 50;
    const y = 100 - Math.min(100, Math.max(0, (Number(v) / max) * 100));
    pts.push(`${x.toFixed(2)},${y.toFixed(2)}`);
  });
  return pts.join(' ');
};

// The same line closed to the baseline, for the area fill beneath it.
export const areaPoints = (values, max) => {
  const line = linePoints(values, max);
  return line ? `0,100 ${line} 100,100` : '';
};

// Resamples a bucket series to `k` points (the mean of each slice) and
// scales them min-max into the tile sparkline's 100×28 box. A flat series
// draws as a mid-height line rather than vanishing.
export const sparklinePoints = (values, k = 24) => {
  const n = values.length;
  if (!n) return '';
  const size = n / k;
  const s = Array.from({ length: k }, (_, j) => {
    const from = Math.floor(j * size);
    const to = Math.max(from + 1, Math.floor((j + 1) * size));
    return mean(values.slice(from, to).filter((v) => v != null));
  });
  const mx = Math.max(...s);
  const mn = Math.min(...s);
  return s
    .map((v, j) => `${((j / (k - 1)) * 100).toFixed(1)},${(26 - (mx === mn ? 0.5 : (v - mn) / (mx - mn)) * 24).toFixed(1)}`)
    .join(' ');
};

// Stacked bars: one column per bucket, layers in order with the first on the
// axis. Each layer is { data: number[], color }.
export const stackBuckets = (layers, max, titleFor) => {
  const n = layers.length ? layers[0].data.length : 0;
  return Array.from({ length: n }, (_, i) => ({
    title: titleFor(i),
    segs: layers.map((L) => ({ h: ((Number(L.data[i]) || 0) / max) * 100, color: L.color })),
  }));
};

// Golden-signal tile: label + delta · value + unit · sub-line · sparkline.
export function SignalTile({ label, value, unit, sub, delta, deltaColor, deltaSub, spark, sparkColor }) {
  return (
    <Card padding="14px 16px 12px" style={{ display: 'flex', flexDirection: 'column', gap: 6, minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
        <MicroLabel size={11} spacing="0.05em">{label}</MicroLabel>
        <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, fontWeight: 600, color: deltaColor, whiteSpace: 'nowrap' }}>{delta}</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
        <span style={{ fontFamily: MONO, fontSize: 26, fontWeight: 700, lineHeight: 1.1, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>{value}</span>
        {unit ? <span style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-muted)' }}>{unit}</span> : null}
      </div>
      <div title={sub} style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{sub}</div>
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 8, marginTop: 2 }}>
        <svg viewBox="0 0 100 28" preserveAspectRatio="none" aria-hidden="true" style={{ flex: 1, height: 28, minWidth: 0, display: 'block', overflow: 'visible' }}>
          <polyline points={spark} fill="none" stroke={sparkColor} strokeWidth="1.5" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
        </svg>
        <span style={{ fontSize: 10, color: 'var(--color-text-muted)', whiteSpace: 'nowrap' }}>{deltaSub}</span>
      </div>
    </Card>
  );
}

// A time-series panel: header · legend · plot (gridlines + tick labels in a
// 40px gutter, stacked CSS bars, one SVG overlay for lines/areas, dashed
// markers) · seven x-axis labels.
//
// buckets: [{ title, segs: [{ h (0-100), color }] }]
// lines:   [{ points, color, width }]   areas: [{ points, color }]
// markers: [{ left (0-100), label, flip }] — flip puts the label left of the
// line (the 55% rule; see markerFlip for the measured override). The label
// lives in a box that spans its side of the line and truncates with an
// ellipsis, so it never paints past the plot into the next card.
export function ChartPanel({
  title, sub, value, valueColor = 'var(--color-text-primary)',
  legend = [], ticks = [], buckets = [], lines = [], areas = [], markers = [], xLabels = [],
  height = CHART_HEIGHT,
}) {
  const plotRef = useRef(null);
  const plotWidth = useMeasuredWidth(plotRef);
  const dashed = '1px dashed var(--color-text-secondary)';
  return (
    <Card padding="14px 16px 12px" style={{ minWidth: 0, display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap' }}>
        <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>{title}</span>
        <span style={{ fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)' }}>{sub}</span>
        <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 12, fontWeight: 600, color: valueColor, whiteSpace: 'nowrap' }}>{value}</span>
      </div>
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
        {legend.map((lg) => (
          <span key={lg.label} style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: MONO, fontSize: 10, color: 'var(--color-text-secondary)' }}>
            <span style={{ width: 8, height: 8, borderRadius: 2, background: lg.color, flexShrink: 0 }} />
            {lg.label}
          </span>
        ))}
      </div>
      <div ref={plotRef} style={{ position: 'relative', height, margin: '6px 0 0 40px' }}>
        {ticks.map((tk) => (
          <div key={tk.top} style={{ position: 'absolute', left: 0, right: 0, top: `${tk.top}%`, borderTop: '1px solid var(--color-border-light)' }}>
            {/* Right-aligned 6px into the gutter; a long label ("$0.00075") grows leftwards instead of over the plot. */}
            <span style={{ position: 'absolute', right: 'calc(100% + 6px)', top: -6, whiteSpace: 'nowrap', fontFamily: MONO, fontSize: 10, lineHeight: '12px', color: 'var(--color-text-muted)' }}>{tk.label}</span>
          </div>
        ))}
        {buckets.length > 0 && (
          <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'stretch', gap: 1 }}>
            {buckets.map((b, i) => (
              <div key={i} title={b.title} style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column-reverse' }}>
                {b.segs.map((sg, k) => (
                  <div key={k} style={{ height: `${sg.h.toFixed(2)}%`, background: sg.color, flexShrink: 0 }} />
                ))}
              </div>
            ))}
          </div>
        )}
        {(lines.length > 0 || areas.length > 0) && (
          <svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true" style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', overflow: 'visible', pointerEvents: 'none' }}>
            {areas.map((ar, i) => (
              <polygon key={i} points={ar.points} fill={ar.color} opacity="0.16" />
            ))}
            {lines.map((ln, i) => (
              <polyline key={i} points={ln.points} fill="none" stroke={ln.color} strokeWidth={ln.width || 1.5} strokeLinejoin="round" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
            ))}
          </svg>
        )}
        {markers.map((mk, i) => {
          const flip = markerFlip(mk, plotWidth);
          const at = `${Number(mk.left).toFixed(2)}%`;
          return (
            <div
              key={i}
              style={{
                position: 'absolute', top: 0, bottom: 0, pointerEvents: 'none',
                ...(flip ? { left: 0, width: at, borderRight: dashed } : { left: at, right: 0, borderLeft: dashed }),
              }}
            >
              <span style={{ position: 'absolute', top: -4, [flip ? 'right' : 'left']: 4, maxWidth: 'calc(100% - 8px)', boxSizing: 'border-box', overflow: 'hidden', textOverflow: 'ellipsis', fontFamily: MONO, fontSize: 9, lineHeight: '12px', color: 'var(--color-text-secondary)', whiteSpace: 'nowrap', background: 'var(--color-card)', padding: '0 4px', borderRadius: 3 }}>
                {mk.label}
              </span>
            </div>
          );
        })}
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginLeft: 40, fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)' }}>
        {xLabels.map((xl, i) => <span key={i}>{xl}</span>)}
      </div>
    </Card>
  );
}

// Right-rail list panel: mono uppercase label + muted qualifier (or a
// right-aligned meta), then rows separated by --color-border-light.
export function RailPanel({ label, qualifier, meta, children }) {
  return (
    <Card padding={0} style={{ overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, padding: '10px 14px', borderBottom: '1px solid var(--color-border-light)' }}>
        <MicroLabel>{label}</MicroLabel>
        {qualifier ? <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{qualifier}</span> : null}
        {meta ? <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{meta}</span> : null}
      </div>
      {children}
    </Card>
  );
}

// Column header row for the grid-shaped rails: a blank first cell, then one
// right-aligned mono 10 uppercase label per numeric column.
export function RailColumns({ template, columns }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: template, gap: 8, padding: '6px 14px 4px', fontFamily: MONO, fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.05em', color: 'var(--color-text-muted)' }}>
      <span />
      {columns.map((c) => <span key={c} style={{ textAlign: 'right' }}>{c}</span>)}
    </div>
  );
}

// A grid row in a rail. `active` marks the selected agent; hoverable rows
// get the hover surface from a utility class so the active background,
// set inline, still wins.
export function RailRow({ template, active = false, onClick, title, padding = '8px 14px', children }) {
  const interactive = typeof onClick === 'function';
  const onKeyDown = interactive
    ? (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onClick(event); } }
    : undefined;
  return (
    <div
      role={interactive ? 'button' : undefined}
      tabIndex={interactive ? 0 : undefined}
      aria-pressed={interactive ? active : undefined}
      onClick={onClick}
      onKeyDown={onKeyDown}
      title={title}
      className={interactive ? 'hover:bg-[var(--color-hover)]' : undefined}
      style={{
        display: 'grid', gridTemplateColumns: template, gap: 8, alignItems: 'center',
        padding, borderTop: '1px solid var(--color-border-light)',
        cursor: interactive ? 'pointer' : 'default',
        background: active ? 'var(--color-muted)' : undefined,
      }}
    >
      {children}
    </div>
  );
}

// A flex row in a rail (slowest actions, errors by type).
export function RailFlexRow({ children, padding = '8px 14px' }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding, borderTop: '1px solid var(--color-border-light)' }}>
      {children}
    </div>
  );
}

// A rail with nothing to list: one mono muted line where the rows would be.
export function RailEmpty({ children }) {
  return (
    <div style={{ padding: '12px 14px', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{children}</div>
  );
}

// 8px radius-2 color swatch, as used by legends and rail rows.
export function Swatch({ color }) {
  return <span style={{ width: 8, height: 8, borderRadius: 2, background: color, flexShrink: 0 }} />;
}

// The 3px share bar under a rail row's name.
export function ShareBar({ pct, color }) {
  return (
    <div style={{ marginTop: 5, height: 3, borderRadius: 999, background: 'var(--color-muted)', overflow: 'hidden' }}>
      <div style={{ width: `${Math.max(0, Math.min(100, Number(pct) || 0))}%`, height: '100%', background: color }} />
    </div>
  );
}

// The 70px × 4px relative bar in the actions and errors rails.
export function MiniBar({ pct, color, width = 70 }) {
  return (
    <span style={{ width, height: 4, borderRadius: 999, background: 'var(--color-muted)', overflow: 'hidden', flexShrink: 0, display: 'inline-block' }}>
      <span style={{ display: 'block', width: `${Math.max(0, Math.min(100, Number(pct) || 0))}%`, height: '100%', background: color }} />
    </span>
  );
}

// Right-aligned mono 11 cell.
export function Cell({ children, color = 'var(--color-text-primary)', weight = 400, width, style }) {
  return (
    <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: weight, textAlign: 'right', color, width, ...style }}>{children}</span>
  );
}
