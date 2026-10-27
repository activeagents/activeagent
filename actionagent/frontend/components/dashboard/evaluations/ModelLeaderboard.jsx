import React from 'react';
import { Card, MicroLabel, PassBar, MONO } from '../primitives';
import { splitModelLabel } from '../../../utils/format';
import { fmtPasses, fmtPercent } from '../../../utils/evalFormat.mjs';
import { plural } from '../../../utils/evaluationRuns.mjs';
import { rateTone } from './ModelComparisonTable';

// The Evaluations page's leaderboard: every model the counted headline runs
// compared, one row each, ranked by the lower bound of its pass rate (so a
// lucky 7/8 does not outrank 75/173 on luck; modelLeaderboard), with its
// pooled passes and then one cell per evaluation it ran in. A model an
// evaluation did not run reads "—". `rows` come from modelLeaderboard,
// `columns` from headlineSummary.
const th = { fontFamily: MONO, fontSize: 10, fontWeight: 600, letterSpacing: '0.05em', textTransform: 'uppercase', color: 'var(--color-text-muted)', padding: '8px 12px', textAlign: 'left', verticalAlign: 'bottom', whiteSpace: 'nowrap' };
const td = { padding: '8px 12px', verticalAlign: 'middle', fontSize: 13, color: 'var(--color-text-cell)', borderTop: '1px solid var(--color-border-light)' };
const num = { ...td, fontFamily: MONO, fontSize: 12, whiteSpace: 'nowrap', textAlign: 'right' };
const numHead = { ...th, textAlign: 'right' };

export default function ModelLeaderboard({ rows = [], columns = [], testId = 'model-leaderboard' }) {
  if (rows.length < 2) return null;
  // One evaluation's cells would repeat the pooled column.
  const shown = columns.length > 1 ? columns.filter((column) => rows.some((row) => row.byEvaluation?.[column.id]?.total > 0)) : [];

  return (
    <Card padding={0} style={{ overflow: 'hidden' }} testId={testId}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, padding: '10px 12px', flexWrap: 'wrap' }}>
        <MicroLabel>Model leaderboard</MicroLabel>
        <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
          {`${plural(rows.length, 'model')} · ${plural(columns.length, 'evaluation')} · ranked by the low end of each pass rate`}
        </span>
      </div>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr style={{ background: 'var(--color-muted)' }}>
              <th style={{ ...numHead, width: 28 }}>#</th>
              <th style={th}>Model</th>
              <th style={{ ...th, minWidth: 160 }}>Passed</th>
              <th style={numHead}>Rate</th>
              {shown.map((column) => (
                <th key={column.id} style={{ ...numHead, maxWidth: 140, overflow: 'hidden', textOverflow: 'ellipsis' }} title={column.name}>{column.name}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const { short, provider } = splitModelLabel(row.label);
              return (
                <tr key={row.label} data-testid="model-leaderboard-row" title={`${row.label}: at least ${fmtPercent(row.lower)} at 95% confidence`}>
                  <td style={{ ...num, color: 'var(--color-text-muted)' }}>{row.rank}</td>
                  <td style={td}>
                    <div style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)', whiteSpace: 'nowrap' }}>{short}</div>
                    {provider && <div style={{ fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)', whiteSpace: 'nowrap' }}>{provider}</div>}
                  </td>
                  <td style={td}><PassBar passed={row.passed} total={row.total} color={rateTone(row.ratio)} valueWidth={56} /></td>
                  <td style={{ ...num, fontWeight: 700, color: rateTone(row.ratio) }}>{fmtPercent(row.ratio)}</td>
                  {shown.map((column) => {
                    const cell = row.byEvaluation?.[column.id];
                    const ratio = cell?.total ? cell.passed / cell.total : null;
                    return (
                      <td key={column.id} style={{ ...num, color: rateTone(ratio) }} title={cell?.total ? `${column.name}: ${fmtPasses(cell.passed, cell.total)}` : `${column.name}: not run on this model`}>
                        {fmtPercent(ratio)}
                      </td>
                    );
                  })}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Card>
  );
}
