import React, { useCallback, useState } from 'react';
import { TYPOGRAPHY } from '../../utils/designTokens';

// Shared chrome for the dashboard's expandable telemetry objects: a trace, a
// span inside it, a span's contents, an interaction, a generation inside that.
// Every one of those is the same idea at a different scale — a header line you
// can click, a monospace preview of what went in and what came out, and a
// recessed panel that opens underneath. Keeping the pieces in one place is what
// lets Traces and Interactions read as one view rather than two designs that
// happen to show the same runs.

// One palette for both themes and both views. Traces used to paint its dark
// mode from the landing page's stylesheet and its light mode from Tailwind
// utilities, which is why the two drifted; everything now themes from here.
export const telemetryColors = (darkMode) => ({
  cardBg: darkMode ? '#1f1f1f' : '#ffffff',
  cardBorder: darkMode ? '#2a2a2a' : '#e5e7eb',
  // The panel an object opens into — one step recessed from its card.
  innerBg: darkMode ? 'rgba(255,255,255,0.04)' : '#f9fafb',
  // A nested object's own panel, one step deeper again.
  panelBg: darkMode ? 'rgba(0,0,0,0.35)' : '#f9fafb',
  preBg: darkMode ? 'rgba(255,255,255,0.06)' : '#eef0f3',
  trackBg: darkMode ? 'rgba(255,255,255,0.08)' : '#f3f4f6',
  hoverBg: darkMode ? 'rgba(255,255,255,0.04)' : '#f9fafb',
  controlBg: darkMode ? 'rgba(255,255,255,0.06)' : '#f3f4f6',
  controlActiveBg: darkMode ? '#2a2a2a' : '#ffffff',
  textPrimary: darkMode ? '#ffffff' : '#111827',
  textSecondary: darkMode ? 'rgba(255,255,255,0.6)' : '#6b7280',
  textMuted: darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af',
  textBody: darkMode ? 'rgba(255,255,255,0.75)' : '#4b5563',
  link: '#3b82f6',
  good: darkMode ? '#4ade80' : '#16a34a',
  bad: '#ef4444',
});

// Collapse whitespace and clip to a single readable line.
export const previewText = (text, max = 200) => {
  const clean = String(text ?? '').replace(/\s+/g, ' ').trim();
  return clean.length > max ? `${clean.slice(0, max)}…` : clean;
};

// Every object in Traces and Interactions opens with the same affordance, at
// the same size, in the same corner.
export function Chevron({ open, darkMode, size = 14, style }) {
  return (
    <svg
      className={`flex-shrink-0 transition-transform ${open ? 'rotate-180' : ''}`}
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      style={{ color: telemetryColors(darkMode).textMuted, ...style }}
      aria-hidden="true"
    >
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
    </svg>
  );
}

// The card an object lives in. Traces and Interactions use the same one, so a
// trace row and an interaction row are the same object at the same altitude.
export function ObjectCard({ darkMode, id, children, style, className = '' }) {
  const colors = telemetryColors(darkMode);
  return (
    <div
      id={id}
      className={`rounded-xl border overflow-hidden transition-colors ${className}`}
      style={{ backgroundColor: colors.cardBg, borderColor: colors.cardBorder, ...style }}
    >
      {children}
    </div>
  );
}

// The metrics strip down the right of an object header: what a run used —
// model, context pressure, wall clock, tokens, cost, status — one column each.
//
// A list of these rows only reads as columns when every row puts its cells in
// the same place, and rendering only the values an object happens to carry
// breaks that on exactly the rows you most want to read against their
// neighbours. An errored trace has no tokens, no cost and nothing in context,
// so its surviving cells used to slide rightward into the columns the healthy
// rows spend on something else — its duration under their cost, its status
// under nothing at all. Every cell here holds its column whether or not this
// object filled it, and an empty one prints a muted dash: "not recorded", in
// the place you were already looking. The strip is anchored at its right edge,
// so only the first column is free to size to its content — a model name is
// the one value with no sensible fixed width. Each column is wide enough for
// the longest value it holds, with the icon that leads it: "155.6K tokens",
// "$0.0996", "12.34s".
export const META_COLUMN = {
  context: 132, // the compact ContextMeter's own width
  duration: 76,
  tokens: 104,
  cost: 88,
  status: 68,
  count: 96,
  age: 76,
};

// `cells` are `{ key, content, width, title, empty, align }`: `width` in
// pixels (omitted only for a leading content-sized column), `title` the
// tooltip when there is a value and `empty` the one explaining its absence.
export function MetaStrip({ cells, darkMode, gap = 16, className = '', style }) {
  const colors = telemetryColors(darkMode);
  const shown = (cells || []).filter(Boolean);
  if (shown.length === 0) return null;

  return (
    <div
      className={`flex-shrink-0 text-sm ${className}`}
      style={{
        display: 'grid',
        gridTemplateColumns: shown.map((cell) => (cell.width ? `${cell.width}px` : 'minmax(0, auto)')).join(' '),
        alignItems: 'center',
        columnGap: `${gap}px`,
        color: colors.textSecondary,
        ...style,
      }}
    >
      {shown.map((cell) => {
        const filled = cell.content != null && cell.content !== false && cell.content !== '';
        return (
          <div
            key={cell.key}
            title={(filled ? cell.title : cell.empty) || undefined}
            // A column is one line wide: a long model name ellipses rather
            // than widening a column every other row has to match.
            className="min-w-0 truncate"
            style={{ textAlign: cell.align || 'right' }}
          >
            {filled ? cell.content : <span style={{ color: colors.textMuted }}>—</span>}
          </div>
        );
      })}
    </div>
  );
}

// The block an expanded value opens into. JSON keeps its indentation and
// scrolls sideways; prose wraps. Either way it is capped and scrolls, because
// a captured message history can run to thousands of lines and would otherwise
// push everything below it off the screen.
export const preBlockStyle = (darkMode, { wrap = true, maxHeight = 320 } = {}) => ({
  background: telemetryColors(darkMode).preBg,
  borderRadius: '6px',
  padding: '6px 8px',
  margin: '2px 0 4px 0',
  overflowX: 'auto',
  overflowY: 'auto',
  maxHeight: `${maxHeight}px`,
  whiteSpace: wrap ? 'pre-wrap' : 'pre',
});

// A value that may be a JSON string, an object, or plain prose. JSON is
// indented so an expanded tool payload reads as a structure; prose is left
// exactly as it was written.
export const prettyValue = (value) => {
  if (value == null) return { text: '', json: false };
  if (typeof value === 'object') return { text: JSON.stringify(value, null, 2), json: true };

  const text = String(value);
  if (!/^[[{]/.test(text.trim())) return { text, json: false };
  try {
    return { text: JSON.stringify(JSON.parse(text), null, 2), json: true };
  } catch {
    return { text, json: false };
  }
};

// The `input:` / `output:` lines under an object's header, and the `in:` /
// `out:` lines under a span. Collapsed they are one clipped line each: the
// row's job is to say what this was about, not to reproduce it. Each opens in
// place, though — the value you are already reading is the one you want in
// full, and making you open the whole span to get at it was a detour.
//
// Labels carry the role colour (blue user input, red agent output, amber tool
// result) so the same content reads the same way on a trace, a span, and an
// interaction.
// `onClick` opens the object these lines belong to. It still fires for a line
// with nothing more to show, and for the padding around them — only a line
// that can actually open keeps the click for itself.
// `hold` keeps a line whose value is missing, as a labelled empty row. Rows in
// a list want it — a trace that errored before it answered still prints its
// `output:` line, so its card stands as tall as the ones around it and the two
// labels stay on one baseline down the list. A span inside an open trace does
// not: its missing half is usually one the panel above already showed, and a
// dash there would deny content the span really carried.
export function PreviewLines({ lines, darkMode, onClick, indent = 0, size = '12px', style, max = 200, hold = false }) {
  const [isOpen, toggle] = useDisclosureSet();
  const colors = telemetryColors(darkMode);
  const shown = (lines || []).filter((line) => line && (line.text || hold));
  // An object that recorded neither half keeps no preview block at all.
  if (!shown.some((line) => line.text)) return null;

  return (
    <div
      onClick={onClick}
      className="min-w-0"
      style={{
        display: 'grid',
        gap: '2px',
        paddingLeft: indent ? `${indent}px` : 0,
        fontFamily: TYPOGRAPHY.mono,
        fontSize: size,
        color: colors.textSecondary,
        cursor: onClick ? 'pointer' : 'default',
        ...style,
      }}
    >
      {shown.map((line, index) => {
        const key = `${line.label}-${index}`;
        const open = isOpen(key);
        const limit = line.max || max;
        const empty = !line.text;
        const squished = String(line.text ?? '').replace(/\s+/g, ' ').trim();
        const pretty = prettyValue(line.text);
        // These rows are a single clipped line, so what actually fits depends
        // on the window — a character count can't tell you. The rule errs
        // toward offering the marker: a short value keeps its plain line, and
        // anything beyond that opens, because a marker on a line that happened
        // to fit costs nothing next to a clipped line with no way in. JSON
        // always opens — its indented form is the readable one at any width.
        const expandable =
          !empty && (pretty.json || squished.length > 60 || squished !== String(line.text).trim());

        return (
          <div key={key}>
            <div
              onClick={expandable
                ? (event) => {
                    // The row behind these lines toggles the whole object;
                    // opening one value is a smaller thing than that.
                    event.stopPropagation();
                    toggle(key);
                  }
                : undefined}
              title={expandable ? (open ? 'Collapse' : 'Expand') : undefined}
              style={{
                cursor: expandable ? 'pointer' : 'default',
                whiteSpace: 'nowrap',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                // Without this the line grows to fit an unbreakable value — a
                // tool's JSON arguments — instead of ellipsing, and widens
                // every flex ancestor up to the page.
                minWidth: 0,
              }}
            >
              {/* The marker keeps its column even when a line can't open, so
                  input: and output: stay aligned with each other. */}
              <span style={{ color: line.color || colors.textMuted }}>
                {expandable ? (open ? '▾' : '▸') : '\u00A0'} {line.label}:
              </span>{' '}
              {!open && (empty ? <span style={{ color: colors.textMuted }}>—</span> : previewText(squished, limit))}
            </div>
            {open && (
              <pre
                onClick={(event) => event.stopPropagation()}
                style={preBlockStyle(darkMode, { wrap: !pretty.json })}
              >
                {pretty.text}
              </pre>
            )}
          </div>
        );
      })}
    </div>
  );
}

// The small segmented control every object uses for its sub-views (Spans /
// Conversation) and its orderings (Time / Slowest / Name).
export function SegmentedControl({ options, value, onChange, darkMode, label, style }) {
  const colors = telemetryColors(darkMode);
  return (
    <div className="flex items-center gap-1 flex-shrink-0" style={style}>
      {label && (
        <span className="text-xs mr-1" style={{ color: colors.textMuted }}>
          {label}
        </span>
      )}
      {options.map((option) => (
        <button
          key={option.id}
          type="button"
          onClick={(event) => {
            event.stopPropagation();
            onChange(option.id);
          }}
          title={option.hint}
          className="px-2 py-0.5 text-xs rounded transition-colors"
          style={
            value === option.id
              ? {
                  background: colors.controlActiveBg,
                  color: colors.textPrimary,
                  boxShadow: darkMode ? 'none' : '0 1px 2px rgba(0,0,0,0.08)',
                }
              : { color: colors.textSecondary }
          }
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}

// The deepest level of the same idea: one content attribute — a prompt, a tool
// result, an instruction block — as a `▸ key: preview…` line that opens into
// the full text. Contents start closed because a span carries several and any
// one of them can be thousands of lines.
export function DisclosureLine({ label, body, open, onToggle, darkMode, prose = false, max = 140 }) {
  const colors = telemetryColors(darkMode);
  return (
    <div>
      <div
        onClick={(event) => {
          event.stopPropagation();
          onToggle();
        }}
        title={open ? 'Collapse' : 'Expand'}
        style={{ cursor: 'pointer', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}
      >
        <span style={{ color: colors.textMuted }}>
          {open ? '▾' : '▸'} {label}:
        </span>{' '}
        {!open && <span style={{ color: colors.textMuted }}>{previewText(body, max)}</span>}
      </div>
      {open && (
        <pre onClick={(event) => event.stopPropagation()} style={preBlockStyle(darkMode, { wrap: prose })}>
          {body}
        </pre>
      )}
    </div>
  );
}

// Expansion state for a set of sibling objects. Several can be open at once —
// comparing two spans, or two attributes of one span, is the reason you
// expanded the first one.
export function useDisclosureSet(initial = {}) {
  const [open, setOpen] = useState(initial);
  const toggle = useCallback((key) => {
    setOpen((current) => ({ ...current, [key]: !current[key] }));
  }, []);
  const isOpen = useCallback((key) => !!open[key], [open]);
  return [isOpen, toggle, setOpen];
}
