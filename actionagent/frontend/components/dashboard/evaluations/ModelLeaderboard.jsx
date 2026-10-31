import React from 'react';
import { Card, MicroLabel, PassBar, MONO } from '../primitives';
import ComparisonTable from '../ComparisonTable';
import { fmtPasses, fmtPercent } from '../../../utils/evalFormat.mjs';
import { plural } from '../../../utils/evaluationRuns.mjs';
import { ModelIdentity, PASS_THRESHOLDS, rateTone } from './ModelComparisonTable';

// The Evaluations page's leaderboard: every model the counted headline runs
// compared, one row each, ranked by the lower bound of its pass rate (so a
// lucky 7/8 does not outrank 75/173 on luck; modelLeaderboard), with its
// pooled passes and then one cell per evaluation it ran in. A model an
// evaluation did not run reads "—". `rows` come from modelLeaderboard,
// `columns` from headlineSummary. Rate cells are pills on the fixed pass
// thresholds; the rank column keeps the Wilson order while any header sorts.
export default function ModelLeaderboard({ rows = [], columns = [], testId = 'model-leaderboard' }) {
  if (rows.length < 2) return null;
  // One evaluation's cells would repeat the pooled column.
  const shown = columns.length > 1 ? columns.filter((column) => rows.some((row) => row.byEvaluation?.[column.id]?.total > 0)) : [];

  const tableColumns = [
    {
      key: 'passed', label: 'Passed', unit: 'Pooled', better: 'higher', band: 'none', align: 'left', width: 180, sortable: true,
      cell: (row) => <PassBar passed={row.passed} total={row.total} color={rateTone(row.ratio)} valueWidth={56} />,
    },
    { key: 'ratio', label: 'Rate', unit: 'Pass', better: 'higher', band: 'threshold', thresholds: PASS_THRESHOLDS, format: (value) => fmtPercent(value) },
    ...shown.map((column) => ({
      key: `eval:${column.id}`, label: column.name, unit: 'Pass rate', title: column.name, better: 'higher', band: 'threshold', thresholds: PASS_THRESHOLDS,
      value: (row) => { const cell = row.byEvaluation?.[column.id]; return cell?.total ? cell.passed / cell.total : null; },
      format: (value) => fmtPercent(value),
      cellTitle: (row) => { const cell = row.byEvaluation?.[column.id]; return cell?.total ? `${column.name}: ${fmtPasses(cell.passed, cell.total)}` : `${column.name}: not run on this model`; },
    })),
  ];

  return (
    <Card padding={0} style={{ overflow: 'hidden' }} testId={testId}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, padding: '10px 14px', flexWrap: 'wrap' }}>
        <MicroLabel>Model leaderboard</MicroLabel>
        <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
          {`${plural(rows.length, 'model')} · ${plural(columns.length, 'evaluation')} · ranked by the low end of each pass rate`}
        </span>
      </div>
      <ComparisonTable
        identity={{
          key: 'rank', label: 'Model', unit: 'Rank · low end', kind: 'number', better: 'lower', value: (row) => row.rank,
          render: (row) => (
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 10 }}>
              <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, color: 'var(--color-text-muted)', width: 18, textAlign: 'right' }}>{row.rank}</span>
              <ModelIdentity label={row.label} />
            </span>
          ),
        }}
        defaultSort={{ key: 'rank', direction: 'ascending' }}
        columns={tableColumns}
        rows={rows}
        rowKey={(row) => row.label}
        rowProps={(row) => ({ 'data-testid': 'model-leaderboard-row', title: `${row.label}: at least ${fmtPercent(row.lower)} at 95% confidence` })}
      />
    </Card>
  );
}
