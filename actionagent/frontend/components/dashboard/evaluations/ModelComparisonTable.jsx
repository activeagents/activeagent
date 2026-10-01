import React from 'react';
import { Card, MicroLabel, MONO } from '../primitives';
import { fmtCost, fmtK, fmtMs, fmtScore, splitModelLabel } from '../../../utils/format';
import { pricingNote, typicalFaultText } from '../../../utils/evaluationRuns.mjs';

// The comparison at a glance: one row per model cohort of a run, best first —
// passed, mean score, average latency, average tokens per interaction, cost
// and the model's typical fault. The scorecards under it carry the same
// figures per model with bars and fault badges; this is the table you read
// across. `rows` come from modelComparisonRows. A cost that covers only
// some of the model's interactions is marked `*`, and its title says how
// many were priced.
const th = { fontFamily: MONO, fontSize: 10, fontWeight: 600, letterSpacing: '0.05em', textTransform: 'uppercase', color: 'var(--color-text-muted)', padding: '8px 12px', textAlign: 'left', verticalAlign: 'bottom', whiteSpace: 'nowrap' };
const td = { padding: '9px 12px', verticalAlign: 'top', fontSize: 13, color: 'var(--color-text-cell)', borderTop: '1px solid var(--color-border-light)' };
const num = { ...td, fontFamily: MONO, fontSize: 12, whiteSpace: 'nowrap', textAlign: 'right' };
const numHead = { ...th, textAlign: 'right' };

const rateTone = (rate) => (rate == null ? 'var(--color-text-muted)' : rate >= 0.85 ? 'var(--color-success-text)' : rate >= 0.5 ? 'var(--color-warning-text)' : 'var(--color-error)');

export default function ModelComparisonTable({ rows = [], unit = 'scenario', judgedBy = null, title = 'Model comparison', testId = 'model-comparison-table' }) {
  if (!rows.length) return null;
  const showCost = rows.some((row) => row.cost != null);
  const showTokens = rows.some((row) => row.avgTokens != null);
  const showLatency = rows.some((row) => row.avgDurationMs != null);

  return (
    <Card padding={0} style={{ overflow: 'hidden' }} testId={testId}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, padding: '10px 12px', flexWrap: 'wrap' }}>
        <MicroLabel>{title}</MicroLabel>
        <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
          {`${rows.length} models · best first${judgedBy ? ` · judged by ${judgedBy}` : ''}`}
        </span>
      </div>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr style={{ background: 'var(--color-muted)' }}>
              <th style={th}>Model</th>
              <th style={numHead}>Passed</th>
              <th style={numHead}>Mean score</th>
              {showLatency && <th style={numHead}>Avg latency</th>}
              {showTokens && <th style={numHead} title={`Average input + output tokens per ${unit}`}>Avg tokens</th>}
              {showCost && <th style={numHead} title={`Cohort spend, and per ${unit}`}>Cost</th>}
              <th style={{ ...th, width: '34%' }}>Typical fault</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const { short, provider } = splitModelLabel(row.label, row.provider || '');
              const pricing = pricingNote(row.priced, row.total, unit);
              return (
                <tr key={row.label} data-testid="model-comparison-row" data-model={row.label}>
                  <td style={{ ...td, whiteSpace: 'nowrap' }}>
                    <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)' }} title={row.label}>{short}</span>
                    {row.winner && (
                      <span style={{ marginLeft: 6, fontFamily: MONO, fontSize: 10, fontWeight: 700, color: 'var(--color-warning-text)' }} title="the judge's pick">★ pick</span>
                    )}
                    {provider && <span style={{ display: 'block', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{provider}</span>}
                  </td>
                  <td style={{ ...num, color: rateTone(row.passRate), fontWeight: 600 }}>
                    {row.total ? `${row.passed}/${row.total}` : '—'}
                  </td>
                  <td style={num}>{fmtScore(row.avgScore)}</td>
                  {showLatency && <td style={num}>{row.avgDurationMs == null ? '—' : fmtMs(row.avgDurationMs)}</td>}
                  {showTokens && (
                    <td style={num} title={row.avgInputTokens == null ? undefined : `${Math.round(row.avgInputTokens)} in · ${Math.round(row.avgOutputTokens || 0)} out per ${unit}`}>
                      {row.avgTokens == null ? '—' : fmtK(Math.round(row.avgTokens))}
                    </td>
                  )}
                  {showCost && (
                    <td style={num} title={pricing || undefined}>
                      {fmtCost(row.cost)}
                      {pricing && row.cost != null && <span style={{ color: 'var(--color-text-muted)' }}>*</span>}
                      {row.costPerInteraction != null && (
                        <span style={{ display: 'block', fontWeight: 400, color: 'var(--color-text-muted)' }}>{`${fmtCost(row.costPerInteraction)}/${unit}`}</span>
                      )}
                    </td>
                  )}
                  <td style={{ ...td, color: row.typicalFault ? 'var(--color-text-cell)' : 'var(--color-text-muted)', textWrap: 'pretty' }}>
                    {typicalFaultText(row)}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Card>
  );
}
