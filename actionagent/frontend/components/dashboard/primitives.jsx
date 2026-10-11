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

// Mono uppercase micro-label. `htmlFor` names the control an `as="label"`
// labels.
export function MicroLabel({ children, size = 11, color = 'var(--color-text-secondary)', spacing = '0.06em', style, as: Tag = 'span', htmlFor }) {
  return (
    <Tag htmlFor={htmlFor} style={{ fontFamily: MONO, fontSize: size, fontWeight: 600, letterSpacing: spacing, textTransform: 'uppercase', color, ...style }}>
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
      aria-pressed={selected}
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
// The recipe is shared with Menu's trigger, so the two line up in a toolbar.
const buttonStyle = (variant, size, disabled) => {
  const pad = size === 'sm' ? '6px 12px' : '8px 14px';
  const base = { padding: pad, borderRadius: 8, cursor: disabled ? 'not-allowed' : 'pointer', fontSize: 13, fontWeight: 500, opacity: disabled ? 0.5 : 1, whiteSpace: 'nowrap', fontFamily: 'inherit' };
  const variants = {
    primary: { background: 'var(--color-accent-ui)', color: 'var(--color-on-accent)', border: '1px solid transparent' },
    secondary: { background: 'transparent', color: 'var(--color-text-cell)', border: '1px solid var(--color-border-strong)' },
    danger: { background: 'transparent', color: 'var(--color-error)', border: '1px solid transparent' },
    ghost: { background: 'transparent', color: 'var(--color-text-secondary)', border: '1px solid transparent' },
  };
  return { ...base, ...(variants[variant] || variants.secondary) };
};

export function Button({ variant = 'secondary', size = 'md', children, onClick, disabled = false, title, type = 'button', style, testId }) {
  return (
    <button type={type} data-testid={testId} onClick={onClick} disabled={disabled} title={title} style={{ ...buttonStyle(variant, size, disabled), ...style }}>
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

// ---------------------------------------------------------------------------
// Page chrome every view shares: the header, the overflow menu, tabs, the
// table styles and the footnote under a table.

// One crumb of the parent trail: an <a> when it has an href (onClick, when
// given, takes the click so the app can route it), else a button.
function Crumb({ label, onClick, href, testId }) {
  const style = { fontSize: 13, color: 'var(--color-text-secondary)', background: 'none', border: 0, padding: 0, fontFamily: 'inherit', cursor: 'pointer', textDecoration: 'none' };
  if (href) {
    return (
      <a href={href} data-testid={testId} onClick={(event) => { if (onClick) { event.preventDefault(); onClick(event); } }} style={style}>
        {label}
      </a>
    );
  }
  return <button type="button" data-testid={testId} onClick={onClick} style={style}>{label}</button>;
}

// The one page header. `crumbs` is the parent trail on the line above; the
// title row holds an optional accent glyph, the `count` of what the page
// lists, a mono `meta` line and `badges`, with `actions` pushed right. No
// subtitle by design: a page says what it is in its title and its data.
// `title` null renders only the crumbs and the actions row, for embedded
// hosts. Hook-free, so static renders stay simple.
export function PageHeader({ title, titleAs: Heading = 'h1', glyph, count, meta, badges, crumbs = [], actions, testId, style }) {
  const hasTitle = title != null;
  const hasRow = hasTitle || count != null || meta != null || badges != null || actions != null;
  return (
    <div data-testid={testId} style={{ display: 'flex', flexDirection: 'column', gap: 6, ...style }}>
      {crumbs.length > 0 && (
        <nav aria-label="Breadcrumb" style={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 6 }}>
          {crumbs.map((crumb, index) => (
            <React.Fragment key={`${crumb.label}-${index}`}>
              <Crumb {...crumb} />
              <span aria-hidden="true" style={{ fontFamily: MONO, fontSize: 13, color: 'var(--color-text-muted)' }}>/</span>
            </React.Fragment>
          ))}
        </nav>
      )}
      {hasRow && (
        <div style={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 10 }}>
          {hasTitle && (
            <Heading style={{ margin: 0, fontSize: 20, fontWeight: 600, letterSpacing: '-0.01em', lineHeight: 1.2, color: 'var(--color-text-primary)', display: 'inline-flex', alignItems: 'center', gap: 10, minWidth: 0 }}>
              {glyph != null && <span aria-hidden="true" style={{ fontFamily: MONO, color: 'var(--color-accent-ui)' }}>{glyph}</span>}
              {title}
            </Heading>
          )}
          {count != null && <span style={{ fontFamily: MONO, fontSize: 13, color: 'var(--color-text-muted)' }}>{count}</span>}
          {meta != null && <span style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-muted)' }}>{meta}</span>}
          {badges}
          {actions != null && (
            <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>{actions}</div>
          )}
        </div>
      )}
    </div>
  );
}

// One row of a Menu: a button, or an <a> when the item navigates (`onClick`
// runs first, and does not take the click). Danger reads in the error colour.
function MenuItem({ label, onClick, href, tone, disabled = false, testId, onSelect }) {
  const style = {
    display: 'block', width: '100%', boxSizing: 'border-box', textAlign: 'left', padding: '7px 10px', borderRadius: 5,
    fontSize: 13, fontFamily: 'inherit', background: 'transparent', border: 0, textDecoration: 'none', whiteSpace: 'nowrap',
    color: tone === 'danger' ? 'var(--color-error)' : 'var(--color-text-primary)',
    cursor: disabled ? 'not-allowed' : 'pointer', opacity: disabled ? 0.5 : 1,
  };
  const select = (event) => {
    if (disabled) { event.preventDefault(); return; }
    if (onClick) onClick(event);
    onSelect();
  };
  if (href && !disabled) {
    return <a role="menuitem" href={href} className="aa-menu-item" data-testid={testId} onClick={select} style={style}>{label}</a>;
  }
  return (
    <button type="button" role="menuitem" className="aa-menu-item" data-testid={testId} disabled={disabled} onClick={select} style={style}>
      {label}
    </button>
  );
}

// A trigger that opens a popover of actions: `label`, or `glyph` alone with
// `ariaLabel` when there is no label. Closes on item click, Escape and a
// click outside. `style` lands on the wrapper, `triggerStyle` on the trigger
// button itself (a split control squares its corners). The popover is the one
// place a shadow is sanctioned, and it still carries a border.
export function Menu({ label, glyph = '...', ariaLabel, items = [], align = 'right', variant = 'secondary', size = 'md', style, triggerStyle, testId }) {
  const [open, setOpen] = React.useState(false);
  const rootRef = React.useRef(null);

  React.useEffect(() => {
    if (!open) return undefined;
    const onMouseDown = (event) => { if (rootRef.current && !rootRef.current.contains(event.target)) setOpen(false); };
    const onKeyDown = (event) => { if (event.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onMouseDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onMouseDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  const iconOnly = label == null;
  return (
    <div ref={rootRef} style={{ position: 'relative', display: 'inline-flex', ...style }}>
      <button
        type="button"
        data-testid={testId}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={iconOnly ? ariaLabel : undefined}
        title={iconOnly ? ariaLabel : undefined}
        onClick={() => setOpen((value) => !value)}
        style={{ ...buttonStyle(variant, size, false), ...(iconOnly ? { fontFamily: MONO, padding: size === 'sm' ? '6px 8px' : '8px 10px' } : {}), ...triggerStyle }}
      >
        {iconOnly ? glyph : label}
      </button>
      {open && (
        <div
          role="menu"
          style={{
            position: 'absolute', top: 'calc(100% + 4px)', [align === 'left' ? 'left' : 'right']: 0, zIndex: 30, minWidth: 160, padding: 4,
            background: 'var(--color-surface)', border: '1px solid var(--color-border)', borderRadius: 8, boxShadow: 'var(--shadow-popover)',
          }}
        >
          {items.map((item, index) => (
            <MenuItem key={item.testId || `${item.label}-${index}`} {...item} onSelect={() => setOpen(false)} />
          ))}
        </div>
      )}
    </div>
  );
}

// A row of tabs; the active one is underlined in the accent, and a `count`
// sits beside the label in mono. Hook-free.
export function Tabs({ tabs, active, onChange, ariaLabel, style }) {
  return (
    <div role="tablist" aria-label={ariaLabel} style={{ display: 'flex', alignItems: 'stretch', gap: 2, borderBottom: '1px solid var(--color-border)', overflowX: 'auto', ...style }}>
      {tabs.map((tab) => {
        const selected = tab.id === active;
        return (
          <button
            key={tab.id}
            type="button"
            role="tab"
            aria-selected={selected}
            data-testid={tab.testId}
            disabled={tab.disabled}
            onClick={() => onChange(tab.id)}
            style={{
              display: 'inline-flex', alignItems: 'center', gap: 6, height: 40, padding: '0 14px', marginBottom: -1,
              background: 'transparent', border: 0, borderBottom: `2px solid ${selected ? 'var(--color-accent-ui)' : 'transparent'}`,
              fontFamily: 'inherit', fontSize: 13, fontWeight: 500, whiteSpace: 'nowrap',
              color: selected ? 'var(--color-text-primary)' : 'var(--color-text-muted)',
              cursor: tab.disabled ? 'not-allowed' : 'pointer', opacity: tab.disabled ? 0.5 : 1,
            }}
          >
            {tab.label}
            {tab.count != null && <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 400, color: 'var(--color-text-muted)' }}>{tab.count}</span>}
          </button>
        );
      })}
    </div>
  );
}

// Inline styles for a data table: a bordered frame, mono uppercase headers,
// bottom-border rows. Give each <tr> the class `aa-row` for the hover tint
// (tokens.css), since an inline background would win over :hover.
export const TABLE = {
  frame: { overflowX: 'auto', border: '1px solid var(--color-border)', borderRadius: 12 },
  table: { width: '100%', borderCollapse: 'collapse' },
  th: {
    padding: '10px 14px', textAlign: 'left', fontFamily: MONO, fontSize: 11, fontWeight: 500, textTransform: 'uppercase', letterSpacing: '0.04em',
    color: 'var(--color-text-secondary)', borderBottom: '1px solid var(--color-border)', whiteSpace: 'nowrap',
  },
  td: { padding: '12px 14px', borderBottom: '1px solid var(--color-border-light)', verticalAlign: 'middle' },
  mono: { fontFamily: MONO, fontSize: 12 },
  right: { textAlign: 'right' },
};

// The one-line footnote under a table, e.g. "Click a row to open it."
export function Hint({ children, style }) {
  return <p style={{ margin: 0, fontSize: 12, color: 'var(--color-text-muted)', ...style }}>{children}</p>;
}
