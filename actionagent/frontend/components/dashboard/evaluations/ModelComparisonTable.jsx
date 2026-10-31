import React from 'react';
import { Card, MicroLabel, MONO } from '../primitives';
import ComparisonTable from '../ComparisonTable';
import { fmtK, fmtMs, splitModelLabel } from '../../../utils/format';
import { COST_LEGEND, costTitle, fmtPasses, fmtScore, fmtSpend } from '../../../utils/evalFormat.mjs';
import { plural, typicalFaultText } from '../../../utils/evaluationRuns.mjs';

// The comparison at a glance: one row per model cohort of a run, best first —
// passed (with its percent), mean score, average latency and its P50 / P95
// (nearest rank, as the report computes them), average tokens per
// interaction, cost (and per interaction), what the judge spent on the
// cohort when a judge was asked, and the model's typical fault. The
// scorecards under it carry the same figures per model with bars and fault
// badges; this is the table you read across, so it is a ComparisonTable:
// every figure a pill tinted by rank within its column, any header sorts.
// `rows` come from modelComparisonRows. A cost with an estimated part reads
// "~", and the table carries the legend once when any does.

// Pass-rate bands are fixed, not relative: ≥ 85% good, ≥ 50% middling.
export const PASS_THRESHOLDS = [0.85, 0.5];
export const rateTone = (rate) => (rate == null ? 'var(--color-text-muted)' : rate >= PASS_THRESHOLDS[0] ? 'var(--color-success-text)' : rate >= PASS_THRESHOLDS[1] ? 'var(--color-warning-text)' : 'var(--color-error)');

export function ModelIdentity({ label, provider, winner, size = 13 }) {
  const { short, provider: prefix } = splitModelLabel(label, provider || '');
  return (
    <span style={{ display: 'inline-grid', gap: 2, minWidth: 0 }}>
      <span style={{ display: 'inline-flex', alignItems: 'baseline', gap: 6, whiteSpace: 'nowrap' }}>
        <span style={{ fontFamily: MONO, fontSize: size, fontWeight: 600, color: 'var(--color-text-primary)' }} title={label}>{short}</span>
        {winner && <span style={{ fontFamily: MONO, fontSize: 10, fontWeight: 700, color: 'var(--color-warning-text)' }} title="the judge's pick">★ pick</span>}
      </span>
      {prefix && <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)', whiteSpace: 'nowrap' }}>{prefix}</span>}
    </span>
  );
}

export default function ModelComparisonTable({ rows = [], unit = 'scenario', judgedBy = null, judgeEstimated = false, title = 'Model comparison', testId = 'model-comparison-table' }) {
  if (!rows.length) return null;
  const showCost = rows.some((row) => row.cost != null);
  const showJudge = rows.some((row) => row.judgeCost != null || row.judgeCalls > 0);
  const showTokens = rows.some((row) => row.avgTokens != null);
  const showLatency = rows.some((row) => row.avgDurationMs != null);
  const showPercentiles = rows.some((row) => row.p50DurationMs != null);
  const showFault = rows.some((row) => row.typicalFault);
  const estimatedAnywhere = rows.some((row) => (row.cost != null && row.estimated) || (row.judgeCost != null && judgeEstimated));

  const columns = [
    { key: 'passRate', label: 'Passed', unit: 'Pass rate', better: 'higher', band: 'threshold', thresholds: PASS_THRESHOLDS, format: (_, row) => fmtPasses(row.passed, row.total) },
    { key: 'avgScore', label: 'Score', unit: 'Mean', better: 'higher', format: (value) => fmtScore(value) },
    showLatency && { key: 'avgDurationMs', label: 'Latency', unit: 'Mean', better: 'lower', format: (value) => (value == null ? '—' : fmtMs(value)) },
    showPercentiles && {
      key: 'p95DurationMs', label: 'P50 / P95', unit: 'Latency', title: 'Median and 95th percentile latency, nearest rank', better: 'lower', band: 'none',
      format: (_, row) => (row.p50DurationMs == null ? '—' : `${fmtMs(row.p50DurationMs)} / ${fmtMs(row.p95DurationMs)}`), testId: () => 'model-comparison-percentiles',
    },
    showTokens && {
      key: 'avgTokens', label: 'Tokens', unit: `Per ${unit}`, title: `Average input + output tokens per ${unit}`, better: 'lower',
      format: (value) => (value == null ? '—' : fmtK(Math.round(value))),
      cellTitle: (row) => (row.avgInputTokens == null ? undefined : `${Math.round(row.avgInputTokens)} in · ${Math.round(row.avgOutputTokens || 0)} out per ${unit}`),
    },
    showCost && {
      key: 'cost', label: 'Cost', unit: 'Cohort', title: `Cohort spend, and per ${unit}`, better: 'lower',
      format: (value, row) => fmtSpend(value, { estimated: row.estimated }), testId: () => 'model-comparison-cost',
      cellTitle: (row) => (row.cost != null && row.estimated ? costTitle() : undefined),
      sub: (row) => (row.costPerInteraction == null ? null : `${fmtSpend(row.costPerInteraction, { estimated: row.estimated })}/${unit}`),
    },
    showJudge && {
      key: 'judgeCost', label: 'Judge', unit: 'Spend', title: "What the judge spent scoring this model's answers", better: 'lower', band: 'none',
      format: (value, row) => (value == null && !row.judgeCalls ? '—' : fmtSpend(value, { estimated: judgeEstimated })), testId: () => 'model-comparison-judge',
      sub: (row) => (row.judgeCalls > 0 ? plural(row.judgeCalls, 'call') : null),
    },
    showFault && {
      key: 'typicalFault', label: 'Typical fault', kind: 'text', sortable: false, align: 'left', width: '30%', value: (row) => row.typicalFault?.name || null,
      cell: (row) => <span style={{ fontSize: 13, color: row.typicalFault ? 'var(--color-text-cell)' : 'var(--color-text-muted)', textWrap: 'pretty' }}>{typicalFaultText(row)}</span>,
    },
  ].filter(Boolean);

  return (
    <Card padding={0} style={{ overflow: 'hidden' }} testId={testId}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, padding: '10px 14px', flexWrap: 'wrap' }}>
        <MicroLabel>{title}</MicroLabel>
        <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
          {`${rows.length} models · best first${judgedBy ? ` · judged by ${judgedBy}` : ''}`}
        </span>
        {estimatedAnywhere && (
          <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }} data-testid="model-comparison-legend">{COST_LEGEND}</span>
        )}
      </div>
      <ComparisonTable
        identity={{ key: 'label', label: 'Model', unit: 'Cohort', render: (row) => <ModelIdentity label={row.label} provider={row.provider} winner={row.winner} /> }}
        columns={columns}
        rows={rows}
        rowKey={(row) => row.label}
        rowProps={(row) => ({ 'data-testid': 'model-comparison-row', 'data-model': row.label })}
      />
    </Card>
  );
}
