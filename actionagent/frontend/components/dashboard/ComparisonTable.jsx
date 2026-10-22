import React, { useMemo, useState } from 'react';
import { MONO } from './primitives';
import ValuePill from './ValuePill';
import { bandRows, firstSortDirection, sortRows, valueOf } from '../../utils/comparison.mjs';

// Ranked comparison table (DESIGN_SPEC "Ranked Data & Comparison Tables"):
// rows compared against each other — model cohorts of a run, the models an
// evaluation page saw, the busiest agents. Two-line mono headers (metric /
// unit) that sort on click, an accent caret on the active column only,
// hairline rows, and a rank-tinted ValuePill in every numeric cell. Use the
// dense tables for operational lists; this one is for reading across.
//
// columns: [{ key, label, unit, title, better: 'higher'|'lower', band:
//   'tercile'|'threshold'|'none', thresholds, kind: 'number'|'text',
//   value(row), format(value, row), sub(row), cell(row, band), testId(row),
//   align, width, sortable }]
// identity: { label, unit, render(row, index) } — the first column; never tinted.
// rows + rowKey(row); rowProps(row) spreads onto the <tr> (data-testid, title).
// sort: { key, direction } makes the order controlled; defaultSort starts it.
// density: 'product' (12px rows) | 'compact' (8px rows) | 'marketing' (20px).
const DENSITY = {
  compact: { row: '8px 12px', head: '8px 12px', pill: 'compact', name: 13 },
  product: { row: '12px 14px', head: '10px 14px', pill: 'product', name: 14 },
  marketing: { row: '20px 16px', head: '12px 16px', pill: 'marketing', name: 17 },
};

const headLine1 = { fontFamily: MONO, fontSize: 11, fontWeight: 700, letterSpacing: '0.05em', textTransform: 'uppercase', color: 'var(--color-text-primary)', display: 'inline-flex', alignItems: 'center', gap: 4, whiteSpace: 'nowrap' };
const headLine2 = { fontFamily: MONO, fontSize: 10, fontWeight: 500, letterSpacing: '0.05em', textTransform: 'uppercase', color: 'var(--color-text-secondary)', whiteSpace: 'nowrap' };
const caretStyle = { fontSize: 9, color: 'var(--color-accent-ui)', lineHeight: 1 };

function SortHeader({ column, sorted, direction, onSort, density, align, isIdentity }) {
  const sortable = column.sortable !== false && onSort;
  const content = (
    <span style={{ display: 'inline-grid', gap: 3, justifyItems: align === 'left' ? 'start' : 'center', textAlign: align }}>
      <span style={headLine1}>
        {column.label}
        {sorted && <span aria-hidden="true" className="aa-caret" style={caretStyle}>{direction === 'ascending' ? '▲' : '▼'}</span>}
      </span>
      {column.unit && <span className="aa-head-unit" style={headLine2}>{column.unit}</span>}
    </span>
  );
  return (
    <th
      scope="col"
      aria-sort={sortable ? (sorted ? direction : 'none') : undefined}
      data-key={column.key}
      title={column.title}
      className={isIdentity ? 'aa-comparison-id' : undefined}
      style={{ padding: DENSITY[density].head, textAlign: align, verticalAlign: 'bottom', borderBottom: '1px solid var(--color-border)', width: column.width, background: 'var(--color-card)' }}
    >
      {sortable ? (
        <button type="button" onClick={() => onSort(column)} className="aa-sort" style={{ all: 'unset', cursor: 'pointer', display: 'inline-block', textAlign: 'inherit' }}>
          {content}
        </button>
      ) : content}
    </th>
  );
}

export default function ComparisonTable({
  columns = [], rows = [], identity, rowKey = (row, index) => row?.key ?? row?.id ?? row?.label ?? index, rowProps,
  sort, defaultSort, onSortChange, density = 'product', testId, style, emptyText = null,
}) {
  const [ownSort, setOwnSort] = useState(() => {
    if (!defaultSort) return null;
    const key = typeof defaultSort === 'string' ? defaultSort : defaultSort.key;
    const column = columns.find((c) => c.key === key) || (identity?.key === key ? identity : null);
    return column ? { key, direction: (typeof defaultSort === 'object' && defaultSort.direction) || firstSortDirection(column) } : null;
  });
  const current = sort || ownSort;
  const idColumn = identity ? { kind: 'text', key: identity.key || 'identity', value: identity.value, sortable: identity.sortable, ...identity } : null;
  const all = idColumn ? [idColumn, ...columns] : columns;

  const onSort = (column) => {
    const direction = current?.key === column.key
      ? (current.direction === 'ascending' ? 'descending' : 'ascending')
      : firstSortDirection(column);
    const next = { key: column.key, direction };
    if (!sort) setOwnSort(next);
    onSortChange?.(next.key, next.direction);
  };

  const bands = useMemo(() => Object.fromEntries(columns.map((column) => [column.key, bandRows(rows, column)])), [columns, rows]);
  const order = useMemo(() => {
    const column = current && all.find((c) => c.key === current.key);
    const indexed = rows.map((row, index) => ({ row, index }));
    if (!column) return indexed;
    return sortRows(indexed, { ...column, value: (entry) => valueOf(entry.row, column) }, current.direction);
  }, [rows, all, current]);

  const dims = DENSITY[density] || DENSITY.product;
  const cols = columns.length;

  if (!rows.length) {
    return emptyText ? <div style={{ padding: 16, fontFamily: MONO, fontSize: 12, color: 'var(--color-text-muted)' }}>{emptyText}</div> : null;
  }

  return (
    <div className="aa-comparison-wrap" style={{ overflowX: 'auto', minWidth: 0, ...style }}>
      <table className="aa-comparison" data-testid={testId} data-density={density} style={{ width: '100%', borderCollapse: 'collapse', '--aa-cols': cols }}>
        <thead>
          <tr>
            {idColumn && <SortHeader column={idColumn} sorted={current?.key === idColumn.key} direction={current?.direction} onSort={onSort} density={density} align="left" isIdentity />}
            {columns.map((column) => (
              <SortHeader key={column.key} column={column} sorted={current?.key === column.key} direction={current?.direction} onSort={onSort} density={density} align={column.align || 'center'} />
            ))}
          </tr>
        </thead>
        <tbody>
          {order.map(({ row, index }) => (
            <tr key={rowKey(row, index)} className="aa-comparison-row" {...(rowProps ? rowProps(row, index) : {})}>
              {idColumn && (
                <td className="aa-comparison-id" style={{ padding: dims.row, textAlign: 'left', verticalAlign: 'middle', fontSize: dims.name, fontWeight: 600, color: 'var(--color-text-primary)' }}>
                  {identity.render ? identity.render(row, index) : valueOf(row, idColumn)}
                </td>
              )}
              {columns.map((column) => {
                const band = bands[column.key][index];
                const value = valueOf(row, column);
                const missing = value == null || (column.kind !== 'text' && !Number.isFinite(Number(value)));
                const text = column.format ? column.format(value, row) : missing ? '—' : String(value);
                const sub = column.sub ? column.sub(row) : null;
                return (
                  <td
                    key={column.key}
                    className={column.kind === 'text' ? 'aa-comparison-text' : undefined}
                    data-label={column.unit ? `${column.label} · ${column.unit}` : column.label}
                    data-testid={column.testId ? column.testId(row) : undefined}
                    data-rank={column.cell ? undefined : band}
                    title={column.cellTitle ? column.cellTitle(row) : undefined}
                    style={{ padding: dims.row, textAlign: column.align || 'center', verticalAlign: 'middle' }}
                  >
                    {column.cell ? column.cell(row, band) : (
                      <>
                        <ValuePill rank={missing ? 'none' : band} size={dims.pill}>{text}</ValuePill>
                        {sub != null && <span className="aa-pill-sub" style={{ display: 'block', marginTop: 4, fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{sub}</span>}
                      </>
                    )}
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
