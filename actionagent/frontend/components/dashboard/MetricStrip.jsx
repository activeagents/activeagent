import React from 'react';
import { MONO } from './primitives';
import ValuePill from './ValuePill';

// A row of core metrics for one thing — a scenario result's score, time,
// tokens and cost, say — each a two-line micro label (metric / unit) over
// a ValuePill, the same vocabulary as a ComparisonTable's headers and cells.
// `rank` tints a pill; most strips rank only the score and leave the rest
// neutral, because one result has nothing to be relative to.
//
// items: [{ key, label, unit, value, rank, title, testId }]
export default function MetricStrip({ items = [], size = 'compact', gap = 14, style, testId }) {
  const shown = items.filter((item) => item && item.value != null && item.value !== '');
  if (!shown.length) return null;
  return (
    <div data-testid={testId} style={{ display: 'flex', flexWrap: 'wrap', gap, alignItems: 'flex-end', ...style }}>
      {shown.map((item) => (
        <span key={item.key || item.label} data-testid={item.testId} title={item.title} style={{ display: 'inline-grid', gap: 4, justifyItems: 'start' }}>
          <span style={{ display: 'inline-grid', gap: 1 }}>
            <span style={{ fontFamily: MONO, fontSize: 10, fontWeight: 700, letterSpacing: '0.05em', textTransform: 'uppercase', color: 'var(--color-text-primary)', whiteSpace: 'nowrap' }}>{item.label}</span>
            {item.unit && <span style={{ fontFamily: MONO, fontSize: 9, fontWeight: 500, letterSpacing: '0.05em', textTransform: 'uppercase', color: 'var(--color-text-secondary)', whiteSpace: 'nowrap' }}>{item.unit}</span>}
          </span>
          <ValuePill rank={item.rank || 'none'} size={size}>{item.value}</ValuePill>
        </span>
      ))}
    </div>
  );
}
