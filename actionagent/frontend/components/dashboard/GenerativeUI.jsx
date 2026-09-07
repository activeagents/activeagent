import React, { useState } from 'react';
import {
  ResponsiveContainer, BarChart, Bar, LineChart, Line, AreaChart, Area, PieChart, Pie, Cell,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend,
} from 'recharts';
import Markdown from './Markdown';
import { paletteFor, ACCENT } from '../../utils/dashboardTheme';
import { TYPOGRAPHY } from '../../utils/designTokens';
import { isSafeImageUrl } from '../../utils/generativeUi';

// Re-exported so consumers that render blocks can also find them without a
// second import; the parsing itself lives in utils/generativeUi.js so it can
// be exercised without React.
export {
  extractUiBlocks,
  blocksFromToolCall,
  blocksFromValue,
  structuredContent,
  uiFenceBlocks,
  isSafeImageUrl,
  UI_TOOL_NAME,
  UI_FENCE_LANGS,
} from '../../utils/generativeUi';

// Renders the block types the render_ui tool describes (see
// AgentToolbox::DEFINITIONS["ui"]) as real components. Everything here is
// built from model output, so it is rendered as React text only — no
// innerHTML — and images load only from http(s)/data: URLs.

// Categorical series colors, in a fixed order that keeps adjacent pairs
// distinguishable under color-vision deficiency on both surfaces. The dark
// column is the same hues re-stepped for the dark card, not a flip. Slot
// order is the safety mechanism, so series never cycle past the eighth.
const SERIES_LIGHT = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#4a3aa7', '#e34948'];
const SERIES_DARK = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181', '#008300', '#9085e9', '#e66767'];
const MAX_SERIES = SERIES_LIGHT.length;
const CHART_HEIGHT = 220;

const isPlainObject = (value) => value != null && typeof value === 'object' && !Array.isArray(value);
const asText = (value) => (value == null ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value));

// Axis ticks and stat values read better compact: 1.2M rather than 1240000.
const compactNumber = (value) => {
  if (typeof value !== 'number' || !Number.isFinite(value)) return asText(value);
  const abs = Math.abs(value);
  if (abs >= 1e9) return `${(value / 1e9).toFixed(1).replace(/\.0$/, '')}B`;
  if (abs >= 1e6) return `${(value / 1e6).toFixed(1).replace(/\.0$/, '')}M`;
  if (abs >= 1e4) return `${(value / 1e3).toFixed(1).replace(/\.0$/, '')}K`;
  return value.toLocaleString();
};

const CALLOUT_TONES = {
  info: { light: ['#eff6ff', '#1d4ed8'], dark: ['rgba(59,130,246,0.15)', '#93c5fd'] },
  success: { light: ['#f0fdf4', '#15803d'], dark: ['rgba(34,197,94,0.15)', '#86efac'] },
  warning: { light: ['#fffbeb', '#b45309'], dark: ['rgba(245,158,11,0.15)', '#fcd34d'] },
  danger: { light: ['#fef2f2', '#b91c1c'], dark: ['rgba(239,68,68,0.15)', '#fca5a5'] },
};

const DELTA_COLORS = {
  positive: { light: '#15803d', dark: '#4ade80' },
  negative: { light: '#b91c1c', dark: '#f87171' },
};

const fieldStyle = (colors) => ({
  width: '100%',
  padding: '6px 10px',
  borderRadius: '8px',
  border: `1px solid ${colors.inputBorder}`,
  background: colors.inputBg,
  color: colors.textPrimary,
  fontFamily: 'inherit',
  fontSize: '13px',
});

const codeStyle = (darkMode) => ({
  background: darkMode ? 'rgba(0,0,0,0.35)' : '#f3f4f6',
  color: darkMode ? '#ffffff' : '#111827',
  borderRadius: '6px',
  padding: '8px 10px',
  fontSize: '12px',
  overflowX: 'auto',
  margin: 0,
  whiteSpace: 'pre-wrap',
});

const titleStyle = (colors) => ({
  fontSize: '13px',
  fontWeight: 600,
  color: colors.textPrimary,
  margin: 0,
});

function Unsupported({ block, reason, colors, darkMode }) {
  return (
    <div className="text-xs" style={{ color: colors.textMuted }}>
      <div className="mb-1">
        Unsupported block{block && block.type ? ` “${asText(block.type)}”` : ''}{reason ? ` — ${reason}` : ''}
      </div>
      <pre style={{ ...codeStyle(darkMode), maxHeight: '160px', overflowY: 'auto' }}>{JSON.stringify(block, null, 2)}</pre>
    </div>
  );
}

function CardBlock({ block, colors, darkMode, onAction }) {
  const image = isSafeImageUrl(block.image_url) ? block.image_url : null;
  return (
    <div
      className="overflow-hidden"
      style={{ border: `1px solid ${colors.cardBorder}`, borderRadius: '10px', background: colors.innerBg }}
    >
      {image && <img src={image} alt={asText(block.title)} style={{ width: '100%', maxHeight: '220px', objectFit: 'cover', display: 'block' }} />}
      <div className="p-3 space-y-1.5">
        {block.title != null && <div style={titleStyle(colors)}>{asText(block.title)}</div>}
        {block.body != null && (
          <div className="text-sm" style={{ color: colors.textCell }}>
            <Markdown text={asText(block.body)} darkMode={darkMode} onUiAction={onAction} />
          </div>
        )}
        {block.footer != null && (
          <div className="text-xs pt-1" style={{ color: colors.textMuted, borderTop: `1px solid ${colors.cardBorder}` }}>
            {asText(block.footer)}
          </div>
        )}
      </div>
    </div>
  );
}

// A stat tile: label, value, optional signed delta. The value stays in text
// ink; only the delta takes a color, by direction.
function StatTile({ block, colors, darkMode }) {
  const delta = block.delta != null ? asText(block.delta) : null;
  const tone = block.tone || (delta && delta.trim().startsWith('-') ? 'negative' : delta ? 'positive' : 'neutral');
  const deltaColor = DELTA_COLORS[tone] ? DELTA_COLORS[tone][darkMode ? 'dark' : 'light'] : colors.textMuted;
  const value = typeof block.value === 'number' ? compactNumber(block.value) : asText(block.value);
  return (
    <div style={{ background: colors.innerBg, border: `1px solid ${colors.cardBorder}`, borderRadius: '10px', padding: '10px 12px' }}>
      <div className="text-xs" style={{ color: colors.textMuted }}>{asText(block.label)}</div>
      <div className="text-lg font-semibold leading-tight mt-0.5" style={{ color: colors.textPrimary }}>{value}</div>
      {delta && <div className="text-xs mt-0.5 font-medium" style={{ color: deltaColor }}>{delta}</div>}
    </div>
  );
}

function StatsBlock({ block, colors, darkMode }) {
  const items = Array.isArray(block.items) ? block.items.filter(isPlainObject) : [];
  if (items.length === 0) return <Unsupported block={block} reason="stats needs an items array" colors={colors} darkMode={darkMode} />;
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(140px, 1fr))', gap: '8px' }}>
      {items.map((item, i) => <StatTile key={i} block={item} colors={colors} darkMode={darkMode} />)}
    </div>
  );
}

const cellStyle = (colors, numeric) => ({
  padding: '6px 10px',
  borderBottom: `1px solid ${colors.cardBorder}`,
  color: colors.textCell,
  textAlign: numeric ? 'right' : 'left',
  fontVariantNumeric: numeric ? 'tabular-nums' : undefined,
  verticalAlign: 'top',
});

const headStyle = (colors) => ({
  padding: '6px 10px',
  borderBottom: `1px solid ${colors.borderStrong}`,
  color: colors.textSecondary,
  fontSize: '11px',
  fontWeight: 600,
  textAlign: 'left',
  fontFamily: TYPOGRAPHY.mono,
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
  whiteSpace: 'nowrap',
});

function DataTable({ columns, rows, colors, renderCell }) {
  return (
    <div style={{ overflowX: 'auto' }}>
      <table className="text-sm" style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr>{columns.map((column, i) => <th key={i} style={headStyle(colors)}>{asText(column)}</th>)}</tr>
        </thead>
        <tbody>
          {rows.map((row, r) => (
            <tr key={r}>
              {columns.map((_, c) => {
                const value = row[c];
                return (
                  <td key={c} style={cellStyle(colors, typeof value === 'number')}>
                    {renderCell ? renderCell(value) : typeof value === 'number' ? value.toLocaleString() : asText(value)}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function TableBlock({ block, colors, darkMode }) {
  const columns = Array.isArray(block.columns) ? block.columns : null;
  const rows = Array.isArray(block.rows) ? block.rows : null;
  if (!columns || !rows) return <Unsupported block={block} reason="table needs columns and rows arrays" colors={colors} darkMode={darkMode} />;
  // Rows may arrive as objects keyed by column name instead of cell arrays.
  const cells = rows.map((row) => (Array.isArray(row) ? row : isPlainObject(row) ? columns.map((column) => row[column]) : [row]));
  return (
    <div>
      {block.title != null && <div className="mb-1.5" style={titleStyle(colors)}>{asText(block.title)}</div>}
      <DataTable columns={columns} rows={cells} colors={colors} />
    </div>
  );
}

// Keys the chart can plot when the block leaves them implicit: the first
// string-valued key is the category axis, every numeric key a series.
const inferX = (data) => {
  const first = data[0];
  return Object.keys(first).find((key) => typeof first[key] === 'string') || Object.keys(first)[0];
};
const inferSeries = (data, x) => Object.keys(data[0]).filter((key) => key !== x && typeof data[0][key] === 'number');

function ChartBlock({ block, colors, darkMode }) {
  const kind = String(block.chart || block.kind || 'bar').toLowerCase();
  const data = Array.isArray(block.data) ? block.data.filter(isPlainObject) : [];
  if (data.length === 0) return <Unsupported block={block} reason="chart needs a data array of objects" colors={colors} darkMode={darkMode} />;
  const x = typeof block.x === 'string' ? block.x : inferX(data);
  const declared = Array.isArray(block.series) ? block.series.filter((key) => typeof key === 'string') : [];
  const series = (declared.length > 0 ? declared : inferSeries(data, x)).slice(0, MAX_SERIES);
  if (!x || series.length === 0) return <Unsupported block={block} reason="chart needs an x key and at least one series" colors={colors} darkMode={darkMode} />;

  const palette = darkMode ? SERIES_DARK : SERIES_LIGHT;
  const surface = colors.cardBg;
  const tick = { fontSize: 10, fill: colors.textMuted };
  const tooltip = (
    <Tooltip
      contentStyle={{ background: surface, border: `1px solid ${colors.cardBorder}`, borderRadius: '8px', fontSize: '12px' }}
      labelStyle={{ color: colors.textPrimary, fontWeight: 600, marginBottom: '4px' }}
      itemStyle={{ color: colors.textCell }}
      formatter={(value) => (typeof value === 'number' ? value.toLocaleString() : asText(value))}
    />
  );
  // Identity is never color alone: two or more series always get a legend
  // (a single series is named by the title instead).
  const legend = series.length > 1 || kind === 'pie'
    ? <Legend wrapperStyle={{ fontSize: '11px', color: colors.textSecondary }} iconSize={10} />
    : null;
  const axes = (
    <>
      <CartesianGrid stroke={colors.cardBorder} vertical={false} />
      <XAxis dataKey={x} stroke={colors.borderStrong} tick={tick} tickLine={false} />
      <YAxis stroke={colors.borderStrong} tick={tick} tickLine={false} axisLine={false} tickFormatter={compactNumber} width={44} />
    </>
  );
  const margin = { top: 8, right: 12, bottom: 0, left: 0 };

  let chart;
  if (kind === 'line') {
    chart = (
      <LineChart data={data} margin={margin}>
        {axes}{tooltip}{legend}
        {series.map((key, i) => (
          <Line
            key={key}
            type="monotone"
            dataKey={key}
            stroke={palette[i]}
            strokeWidth={2}
            dot={{ r: 4, strokeWidth: 2, stroke: surface, fill: palette[i] }}
            activeDot={{ r: 5, strokeWidth: 2, stroke: surface }}
            isAnimationActive={false}
          />
        ))}
      </LineChart>
    );
  } else if (kind === 'area') {
    chart = (
      <AreaChart data={data} margin={margin}>
        {axes}{tooltip}{legend}
        {series.map((key, i) => (
          <Area
            key={key}
            type="monotone"
            dataKey={key}
            stroke={palette[i]}
            strokeWidth={2}
            fill={palette[i]}
            fillOpacity={0.12}
            dot={{ r: 3, strokeWidth: 2, stroke: surface, fill: palette[i] }}
            isAnimationActive={false}
          />
        ))}
      </AreaChart>
    );
  } else if (kind === 'pie') {
    // Past the palette, the smallest slices fold into "Other" rather than
    // reusing a color.
    const valueKey = series[0];
    const sorted = [...data].sort((a, b) => (Number(b[valueKey]) || 0) - (Number(a[valueKey]) || 0));
    const slices = sorted.slice(0, MAX_SERIES);
    const rest = sorted.slice(MAX_SERIES);
    if (rest.length > 0) {
      slices[MAX_SERIES - 1] = { [x]: 'Other', [valueKey]: rest.reduce((sum, row) => sum + (Number(row[valueKey]) || 0), Number(slices[MAX_SERIES - 1][valueKey]) || 0) };
    }
    chart = (
      <PieChart margin={margin}>
        {tooltip}{legend}
        <Pie
          data={slices}
          dataKey={valueKey}
          nameKey={x}
          innerRadius={44}
          outerRadius={80}
          paddingAngle={2}
          stroke={surface}
          strokeWidth={2}
          isAnimationActive={false}
        >
          {slices.map((_, i) => <Cell key={i} fill={palette[i]} />)}
        </Pie>
      </PieChart>
    );
  } else {
    chart = (
      <BarChart data={data} margin={margin} barCategoryGap="25%" barGap={2}>
        {axes}{tooltip}{legend}
        {series.map((key, i) => (
          <Bar key={key} dataKey={key} fill={palette[i]} radius={[4, 4, 0, 0]} maxBarSize={24} isAnimationActive={false} />
        ))}
      </BarChart>
    );
  }

  return (
    <div>
      {block.title != null && <div className="mb-1" style={titleStyle(colors)}>{asText(block.title)}</div>}
      {/* ResponsiveContainer measures its parent, so the parent must own a
          real height — a percentage here collapses inside a flex row. */}
      <div style={{ width: '100%', height: CHART_HEIGHT, minWidth: 0 }}>
        <ResponsiveContainer width="100%" height={CHART_HEIGHT}>{chart}</ResponsiveContainer>
      </div>
    </div>
  );
}

function ListBlock({ block, colors, darkMode, onAction }) {
  const items = Array.isArray(block.items) ? block.items : null;
  if (!items) return <Unsupported block={block} reason="list needs an items array" colors={colors} darkMode={darkMode} />;
  const Tag = block.ordered ? 'ol' : 'ul';
  return (
    <div>
      {block.title != null && <div className="mb-1" style={titleStyle(colors)}>{asText(block.title)}</div>}
      <Tag className={`${block.ordered ? 'list-decimal' : 'list-disc'} pl-5 text-sm space-y-0.5`} style={{ color: colors.textCell }}>
        {items.map((item, i) => (
          <li key={i}>
            {typeof item === 'string' ? <Markdown text={item} darkMode={darkMode} onUiAction={onAction} /> : asText(item)}
          </li>
        ))}
      </Tag>
    </div>
  );
}

function ProgressBlock({ block, colors }) {
  const raw = Number(block.value);
  const value = Number.isFinite(raw) ? Math.max(0, Math.min(100, raw)) : 0;
  return (
    <div>
      <div className="flex items-center justify-between text-xs mb-1">
        <span style={{ color: colors.textCell }}>{asText(block.label)}</span>
        <span className="font-mono" style={{ color: colors.textMuted }}>{Math.round(value)}%</span>
      </div>
      <div style={{ height: '8px', borderRadius: '999px', background: colors.trackBg, overflow: 'hidden' }}>
        <div style={{ width: `${value}%`, height: '100%', background: ACCENT, borderRadius: '999px', transition: 'width 0.3s ease' }} />
      </div>
    </div>
  );
}

const FIELD_TYPES = ['text', 'textarea', 'number', 'select', 'checkbox'];
const fieldKey = (field) => asText(field.name || field.label);
const fieldType = (field) => (FIELD_TYPES.includes(field.type) ? field.type : 'text');

// Submitting sends a user message back into the conversation:
// "<submit label>: field: value; field: value" plus the raw values.
function FormBlock({ block, colors, darkMode, onAction }) {
  const fields = (Array.isArray(block.fields) ? block.fields : []).filter((field) => isPlainObject(field) && (field.name || field.label));
  const [values, setValues] = useState(() =>
    Object.fromEntries(fields.map((field) => [fieldKey(field), fieldType(field) === 'checkbox' ? false : '']))
  );
  const [sent, setSent] = useState(false);
  if (fields.length === 0) return <Unsupported block={block} reason="form needs fields" colors={colors} darkMode={darkMode} />;

  const submitLabel = block.submit != null ? asText(block.submit) : 'Submit';
  const setValue = (key, value) => setValues((prev) => ({ ...prev, [key]: value }));

  const handleSubmit = (event) => {
    event.preventDefault();
    const summary = fields
      .map((field) => {
        const key = fieldKey(field);
        const value = values[key];
        return `${key}: ${typeof value === 'boolean' ? (value ? 'yes' : 'no') : asText(value)}`;
      })
      .join('; ');
    setSent(true);
    if (onAction) onAction({ kind: 'form', text: `${block.submit != null ? asText(block.submit) : 'Submitted'}: ${summary}`, values: { ...values } });
  };

  return (
    <form
      onSubmit={handleSubmit}
      className="space-y-2.5"
      style={{ border: `1px solid ${colors.cardBorder}`, borderRadius: '10px', background: colors.innerBg, padding: '12px' }}
    >
      {block.title != null && <div style={titleStyle(colors)}>{asText(block.title)}</div>}
      {fields.map((field) => {
        const key = fieldKey(field);
        const type = fieldType(field);
        const label = asText(field.label || field.name);
        const id = `genui-field-${key.replace(/\W+/g, '-')}`;
        if (type === 'checkbox') {
          return (
            <label key={key} className="flex items-center gap-2 text-sm" style={{ color: colors.textCell }}>
              <input type="checkbox" checked={!!values[key]} onChange={(e) => setValue(key, e.target.checked)} style={{ accentColor: ACCENT }} />
              {label}
            </label>
          );
        }
        return (
          <div key={key}>
            <label htmlFor={id} className="block text-xs mb-1" style={{ color: colors.textSecondary }}>
              {label}{field.required ? ' *' : ''}
            </label>
            {type === 'textarea' ? (
              <textarea
                id={id}
                name={key}
                value={values[key]}
                onChange={(e) => setValue(key, e.target.value)}
                placeholder={field.placeholder != null ? asText(field.placeholder) : undefined}
                required={!!field.required}
                rows={3}
                className="aa-field"
                style={{ ...fieldStyle(colors), resize: 'vertical' }}
              />
            ) : type === 'select' ? (
              <select
                id={id}
                name={key}
                value={values[key]}
                onChange={(e) => setValue(key, e.target.value)}
                required={!!field.required}
                className="aa-field"
                style={fieldStyle(colors)}
              >
                <option value="">{field.placeholder != null ? asText(field.placeholder) : 'Select…'}</option>
                {(Array.isArray(field.options) ? field.options : []).map((option, i) => (
                  <option key={i} value={asText(option)}>{asText(option)}</option>
                ))}
              </select>
            ) : (
              <input
                id={id}
                name={key}
                type={type === 'number' ? 'number' : 'text'}
                value={values[key]}
                onChange={(e) => setValue(key, type === 'number' && e.target.value !== '' ? Number(e.target.value) : e.target.value)}
                placeholder={field.placeholder != null ? asText(field.placeholder) : undefined}
                required={!!field.required}
                className="aa-field"
                style={fieldStyle(colors)}
              />
            )}
          </div>
        );
      })}
      <div className="flex items-center gap-3 pt-1">
        <button
          type="submit"
          data-testid="genui-form-submit"
          style={{ padding: '6px 14px', borderRadius: '8px', fontSize: '13px', fontWeight: 500, background: ACCENT, color: '#ffffff', border: '1px solid transparent', cursor: 'pointer' }}
        >
          {submitLabel}
        </button>
        {sent && <span className="text-xs" style={{ color: colors.textMuted }}>Sent to the agent</span>}
      </div>
    </form>
  );
}

function ChoicesBlock({ block, colors, darkMode, onAction }) {
  const options = Array.isArray(block.options) ? block.options : null;
  const [picked, setPicked] = useState(null);
  if (!options || options.length === 0) return <Unsupported block={block} reason="choices needs options" colors={colors} darkMode={darkMode} />;
  return (
    <div>
      {block.prompt != null && <div className="text-sm mb-1.5" style={{ color: colors.textCell }}>{asText(block.prompt)}</div>}
      <div className="flex flex-wrap gap-2">
        {options.map((option, i) => {
          const text = asText(option);
          const active = picked === i;
          return (
            <button
              key={i}
              type="button"
              data-testid="genui-choice"
              onClick={() => {
                setPicked(i);
                if (onAction) onAction({ kind: 'choice', text });
              }}
              style={{
                padding: '5px 12px',
                borderRadius: '999px',
                fontSize: '13px',
                cursor: 'pointer',
                border: `1px solid ${active ? ACCENT : colors.inputBorder}`,
                background: active ? ACCENT : 'transparent',
                color: active ? '#ffffff' : colors.textCell,
              }}
            >
              {text}
            </button>
          );
        })}
      </div>
    </div>
  );
}

function ImageBlock({ block, colors, darkMode }) {
  if (!isSafeImageUrl(block.url)) return <Unsupported block={block} reason="image URL must be http(s) or data:" colors={colors} darkMode={darkMode} />;
  return (
    <figure style={{ margin: 0 }}>
      <img src={block.url.trim()} alt={block.alt != null ? asText(block.alt) : ''} style={{ maxWidth: '100%', borderRadius: '8px', display: 'block' }} />
      {block.caption != null && <figcaption className="text-xs mt-1" style={{ color: colors.textMuted }}>{asText(block.caption)}</figcaption>}
    </figure>
  );
}

function CalloutBlock({ block, colors, darkMode, onAction }) {
  const [background, color] = (CALLOUT_TONES[block.tone] || CALLOUT_TONES.info)[darkMode ? 'dark' : 'light'];
  return (
    <div style={{ background, borderLeft: `3px solid ${color}`, borderRadius: '8px', padding: '10px 12px' }}>
      {block.title != null && <div className="text-sm font-semibold mb-0.5" style={{ color }}>{asText(block.title)}</div>}
      <div className="text-sm" style={{ color: colors.textCell }}>
        <Markdown text={asText(block.body)} darkMode={darkMode} onUiAction={onAction} />
      </div>
    </div>
  );
}

function CodeBlock({ block, colors, darkMode }) {
  return (
    <div>
      {block.language != null && <div className="text-xs font-mono mb-1" style={{ color: colors.textMuted }}>{asText(block.language)}</div>}
      <pre style={codeStyle(darkMode)}>{asText(block.code)}</pre>
    </div>
  );
}

function TextBlock({ block, colors, darkMode, onAction }) {
  const text = block.text ?? block.body ?? block.content ?? block.markdown;
  return (
    <div className="text-sm" style={{ color: colors.textCell }}>
      <Markdown text={asText(text)} darkMode={darkMode} onUiAction={onAction} />
    </div>
  );
}

// Structured output without a `ui` array: a compact key/value view. Nested
// objects become nested tables, arrays of objects a table with the union of
// their keys, deeper nesting than that falls back to JSON.
const MAX_OBJECT_DEPTH = 3;

function ObjectValue({ value, colors, darkMode, depth }) {
  if (value == null || typeof value !== 'object') {
    if (typeof value === 'boolean') return <span className="font-mono">{String(value)}</span>;
    if (typeof value === 'number') return <span style={{ fontVariantNumeric: 'tabular-nums' }}>{value.toLocaleString()}</span>;
    return <span>{asText(value)}</span>;
  }
  if (depth >= MAX_OBJECT_DEPTH) {
    return <pre style={{ ...codeStyle(darkMode), maxHeight: '160px', overflowY: 'auto' }}>{JSON.stringify(value, null, 2)}</pre>;
  }
  if (Array.isArray(value)) {
    if (value.length === 0) return <span style={{ color: colors.textMuted }}>—</span>;
    if (value.every(isPlainObject)) {
      const columns = [...new Set(value.flatMap((row) => Object.keys(row)))];
      return (
        <DataTable
          columns={columns}
          rows={value.map((row) => columns.map((column) => row[column]))}
          colors={colors}
          renderCell={(cell) => <ObjectValue value={cell} colors={colors} darkMode={darkMode} depth={depth + 1} />}
        />
      );
    }
    if (value.every((item) => item == null || typeof item !== 'object')) {
      return <span>{value.map(asText).join(', ')}</span>;
    }
    return (
      <ul className="list-disc pl-5 space-y-0.5">
        {value.map((item, i) => <li key={i}><ObjectValue value={item} colors={colors} darkMode={darkMode} depth={depth + 1} /></li>)}
      </ul>
    );
  }
  const entries = Object.entries(value);
  if (entries.length === 0) return <span style={{ color: colors.textMuted }}>{'{}'}</span>;
  return (
    <table className="text-sm" style={{ borderCollapse: 'collapse', width: depth === 0 ? '100%' : 'auto' }}>
      <tbody>
        {entries.map(([key, entry]) => (
          <tr key={key}>
            <th
              scope="row"
              className="font-mono text-xs"
              style={{ ...cellStyle(colors, false), color: colors.textSecondary, fontWeight: 500, whiteSpace: 'nowrap', width: '1%' }}
            >
              {key}
            </th>
            <td style={cellStyle(colors, false)}>
              <ObjectValue value={entry} colors={colors} darkMode={darkMode} depth={depth + 1} />
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function ObjectBlock({ block, colors, darkMode }) {
  const value = 'value' in block ? block.value : block.data;
  return (
    <div style={{ border: `1px solid ${colors.cardBorder}`, borderRadius: '10px', overflow: 'hidden' }}>
      {block.title != null && <div className="px-3 pt-2" style={titleStyle(colors)}>{asText(block.title)}</div>}
      <div className="px-1 pb-1" style={{ overflowX: 'auto' }}>
        <ObjectValue value={value} colors={colors} darkMode={darkMode} depth={0} />
      </div>
    </div>
  );
}

const RENDERERS = {
  card: CardBlock,
  stat: StatTile,
  stats: StatsBlock,
  table: TableBlock,
  chart: ChartBlock,
  list: ListBlock,
  progress: ProgressBlock,
  form: FormBlock,
  choices: ChoicesBlock,
  image: ImageBlock,
  callout: CalloutBlock,
  code: CodeBlock,
  object: ObjectBlock,
  text: TextBlock,
  markdown: TextBlock,
};

export default function GenerativeUI({ blocks, onAction, darkMode = false }) {
  const list = Array.isArray(blocks) ? blocks.filter(isPlainObject) : [];
  if (list.length === 0) return null;
  const colors = paletteFor(darkMode);
  return (
    // Blocks live inside clickable stream rows (click = expand details), so
    // a form field or choice button must not toggle the row it sits in.
    <div className="space-y-3" onClick={(event) => event.stopPropagation()}>
      {list.map((block, i) => {
        const type = typeof block.type === 'string' ? block.type.toLowerCase() : 'unknown';
        const Renderer = RENDERERS[type];
        return (
          <div key={i} data-testid="genui-block" data-block-type={type}>
            {Renderer
              ? <Renderer block={block} colors={colors} darkMode={darkMode} onAction={onAction} />
              : <Unsupported block={block} colors={colors} darkMode={darkMode} />}
          </div>
        );
      })}
    </div>
  );
}
