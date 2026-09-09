import React from 'react';
import { ICONS } from '../../utils/designTokens';

// Shared building blocks for the data-dense dashboard views (Metrics,
// Evaluations). Every color is a design token from frontend/tokens.css, so a
// view built from these renders correctly in both themes without resolving a
// palette of its own. Borders over shadows; ASCII glyphs over icons; mono for
// every number.

export const MONO = 'var(--font-mono)';

// Pass-ratio tone thresholds, used everywhere a pass ratio is colored.
export const toneFor = (ratio) => (ratio >= 1 ? 'success' : ratio >= 0.7 ? 'warning' : 'error');

// Strong / soft / text color per tone.
export const TONE = {
  success: { strong: 'var(--color-success)', soft: 'var(--color-success-soft)', text: 'var(--color-success-text)' },
  warning: { strong: 'var(--color-warning)', soft: 'var(--color-warning-soft)', text: 'var(--color-warning-text)' },
  error: { strong: 'var(--color-error)', soft: 'var(--color-error-soft)', text: 'var(--color-error-text)' },
  info: { strong: 'var(--color-info)', soft: 'var(--color-info-soft)', text: 'var(--color-info-text)' },
  muted: { strong: 'var(--color-text-muted)', soft: 'var(--color-muted)', text: 'var(--color-text-secondary)' },
  accent: { strong: 'var(--color-accent-ui)', soft: 'var(--color-accent-ui-tint)', text: 'var(--color-accent-ui)' },
};

// The TUI glyph set. `chevron` rotates 90° when `open`.
export const GLYPH = {
  object: '=',
  sample: '~',
  pass: ICONS.success,   // [+]
  fault: ICONS.error,    // [!]
  info: ICONS.info,      // [i]
  on: '[x]',
  off: '[ ]',
  link: ICONS.arrow,     // ->
  chevron: ICONS.chevronRight, // >
};

export function Glyph({ kind = 'pass', open = false, color, size = 12, weight = 700, style, title }) {
  if (kind === 'chevron') {
    return (
      <span
        className="aa-chevron"
        data-open={open ? 'true' : 'false'}
        title={title}
        style={{ fontFamily: MONO, fontSize: size, color: color || 'var(--color-text-muted)', flexShrink: 0, ...style }}
      >
        {GLYPH.chevron}
      </span>
    );
  }
  const fallback = kind === 'fault' ? 'var(--color-error)' : kind === 'info' ? 'var(--color-info)' : kind === 'pass' ? 'var(--color-success)' : 'var(--color-text-muted)';
  return (
    <span title={title} style={{ fontFamily: MONO, fontSize: size, fontWeight: weight, color: color || fallback, flexShrink: 0, ...style }}>
      {GLYPH[kind] || kind}
    </span>
  );
}

// Soft tint background + strong text, mono 11/600, radius 4.
export function Badge({ tone = 'muted', size = 11, children, title, style, testId }) {
  const t = TONE[tone] || TONE.muted;
  return (
    <span
      data-testid={testId}
      title={title}
      style={{
        display: 'inline-flex', alignItems: 'center', padding: '2px 7px', borderRadius: 4,
        fontFamily: MONO, fontSize: size, fontWeight: 600, whiteSpace: 'nowrap',
        background: t.soft, color: t.text, ...style,
      }}
    >
      {children}
    </span>
  );
}

// Mono uppercase micro-label.
export function MicroLabel({ children, size = 11, color = 'var(--color-text-secondary)', spacing = '0.06em', style, as: Tag = 'span' }) {
  return (
    <Tag style={{ fontFamily: MONO, fontSize: size, fontWeight: 600, letterSpacing: spacing, textTransform: 'uppercase', color, ...style }}>
      {children}
    </Tag>
  );
}

// A selectable chip. Pill (radius 999) by default, radius 6 when `square`.
export function Chip({ selected = false, onClick, children, square = false, mono = false, title, style, testId }) {
  return (
    <button
      type="button"
      data-testid={testId}
      onClick={onClick}
      title={title}
      style={{
        padding: '4px 10px', borderRadius: square ? 6 : 999, cursor: onClick ? 'pointer' : 'default',
        fontFamily: mono ? MONO : 'inherit', fontSize: mono ? 11 : 12, fontWeight: mono ? 400 : 500,
        background: selected ? 'var(--color-accent-ui-tint)' : 'var(--color-card)',
        border: `1px solid ${selected ? 'var(--color-accent-ui)' : 'var(--color-border)'}`,
        color: selected ? 'var(--color-accent-ui)' : mono ? 'var(--color-text-muted)' : 'var(--color-text-cell)',
        ...style,
      }}
    >
      {children}
    </button>
  );
}

// Bordered buttons, radius 8, 13px/500; the selected one carries the accent.
export function SegmentedControl({ options, value, onChange, style }) {
  return (
    <div style={{ display: 'flex', gap: 4, ...style }} role="group">
      {options.map((option) => {
        const active = option.value === value;
        return (
          <button
            key={option.value}
            type="button"
            onClick={() => onChange(option.value)}
            aria-pressed={active}
            style={{
              padding: '6px 12px', borderRadius: 8, cursor: 'pointer', fontSize: 13, fontWeight: 500,
              background: 'var(--color-card)',
              border: `1px solid ${active ? 'var(--color-accent-ui)' : 'var(--color-border)'}`,
              color: active ? 'var(--color-accent-ui)' : 'var(--color-text-cell)',
            }}
          >
            {option.label}
          </button>
        );
      })}
    </div>
  );
}

// primary = accent fill; secondary = bordered; danger = red text; ghost = text only.
export function Button({ variant = 'secondary', size = 'md', children, onClick, disabled = false, title, type = 'button', style, testId }) {
  const pad = size === 'sm' ? '6px 12px' : '8px 14px';
  const base = { padding: pad, borderRadius: 8, cursor: disabled ? 'not-allowed' : 'pointer', fontSize: 13, fontWeight: 500, opacity: disabled ? 0.5 : 1, whiteSpace: 'nowrap', fontFamily: 'inherit' };
  const variants = {
    primary: { background: 'var(--color-accent-ui)', color: 'var(--color-on-accent)', border: '1px solid transparent' },
    secondary: { background: 'transparent', color: 'var(--color-text-cell)', border: '1px solid var(--color-border-strong)' },
    danger: { background: 'transparent', color: 'var(--color-error)', border: '1px solid transparent' },
    ghost: { background: 'transparent', color: 'var(--color-text-secondary)', border: '1px solid transparent' },
  };
  return (
    <button type={type} data-testid={testId} onClick={onClick} disabled={disabled} title={title} style={{ ...base, ...(variants[variant] || variants.secondary), ...style }}>
      {children}
    </button>
  );
}

// A surface card: --color-card, 1px --color-border, radius 12. No shadow.
export function Card({ children, padding = 20, style, className, testId, ...rest }) {
  return (
    <div
      data-testid={testId}
      className={className}
      style={{ background: 'var(--color-card)', border: '1px solid var(--color-border)', borderRadius: 12, padding, ...style }}
      {...rest}
    >
      {children}
    </div>
  );
}

// Stat tile: mono uppercase label · 32px mono/700 value · 13px secondary sub-line.
export function StatCard({ label, value, sub, valueColor, valueSize = 32, testId }) {
  return (
    <Card testId={testId}>
      <MicroLabel size={11} spacing="0.05em">{label}</MicroLabel>
      <div style={{ marginTop: 8, fontFamily: MONO, fontSize: valueSize, fontWeight: 700, lineHeight: 1.1, color: valueColor || 'var(--color-text-primary)' }}>{value}</div>
      {sub != null && <div style={{ marginTop: 8, fontSize: 13, color: 'var(--color-text-secondary)' }}>{sub}</div>}
    </Card>
  );
}

// Nested panel: 1px --color-border-light, radius 10, header strip on --color-muted
// with a mono uppercase label and an optional right-aligned mono meta.
export function Panel({ title, meta, children, style, testId, bodyStyle }) {
  return (
    <div data-testid={testId} style={{ border: '1px solid var(--color-border-light)', borderRadius: 10, overflow: 'hidden', minWidth: 0, ...style }}>
      {(title || meta) && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px', background: 'var(--color-muted)' }}>
          {title && <MicroLabel>{title}</MicroLabel>}
          {meta && <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{meta}</span>}
        </div>
      )}
      <div style={bodyStyle}>{children}</div>
    </div>
  );
}

// A pass bar: mono label (fixed width) · track · fill colored by tone · `k/n` in the same color.
export function PassBar({ passed, total, label, labelWidth = 128, width, height = 6, color, valueWidth = 38, style }) {
  const ratio = total ? passed / total : 0;
  const fill = color || TONE[toneFor(ratio)].strong;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, ...style }}>
      {label != null && (
        <span style={{ fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)', width: labelWidth, flexShrink: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }} title={label}>{label}</span>
      )}
      <span style={{ flex: width ? undefined : 1, width, height, borderRadius: 999, background: 'var(--color-muted)', overflow: 'hidden', flexShrink: 0 }}>
        <span style={{ display: 'block', width: `${Math.round(ratio * 100)}%`, height: '100%', borderRadius: 999, background: fill }} />
      </span>
      <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, width: valueWidth, textAlign: 'right', color: fill }}>{passed}/{total}</span>
    </div>
  );
}

// A mono in-app link ending in `->`, in the info color.
export function MonoLink({ children, onClick, href = '#', color = 'var(--color-info)', size = 11, style, title }) {
  return (
    <a
      href={href}
      title={title}
      onClick={(event) => { if (onClick) { event.preventDefault(); onClick(event); } }}
      style={{ fontFamily: MONO, fontSize: size, color, textDecoration: 'none', ...style }}
    >
      {children} {GLYPH.link}
    </a>
  );
}

// Mono muted empty-state line, e.g. "[+] nothing failed in this group".
export function Empty({ children, style }) {
  return (
    <div style={{ padding: '20px 12px', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)', textAlign: 'center', ...style }}>
      {children}
    </div>
  );
}
