import React from 'react';
import { MicroLabel, MONO } from '../primitives';
import { splitModelLabel } from '../../../utils/format';
import { plural } from '../../../utils/evaluationRuns.mjs';

// Whether the gap between the run's models is real: each model's pass rate
// as a dot inside its interval, best first, on a fixed 0-100% axis so a
// narrow gap is not magnified, with the figures written out beside it; then
// the run's conclusion and how the intervals were computed. `plot` comes
// from comparisonPlot. The HTML report (ReportHtml#html_intervals) draws the
// same plot from the same recorded comparison. The rows and the axis share
// one grid (each row is display: contents), so every track spans the same
// width and a tick sits under the dots it names.
const TICKS = [0, 25, 50, 75, 100];
const grid = { display: 'grid', gridTemplateColumns: 'minmax(64px, 200px) minmax(96px, 1fr) auto', alignItems: 'center', gap: '6px 12px', padding: '10px 12px', border: '1px solid var(--color-border-light)', borderRadius: 10 };
const row = { display: 'contents' };
const fullWidth = { gridColumn: '1 / -1' };
const figureStyle = { fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)' };

function Track({ passRate, interval }) {
  return (
    <span aria-hidden="true" style={{ position: 'relative', display: 'block', height: 14 }}>
      <span style={{ position: 'absolute', left: 0, right: 0, top: 6, height: 2, background: 'var(--color-muted)' }} />
      {interval && (
        <span
          data-testid="comparison-interval-range"
          style={{ position: 'absolute', top: 3, height: 8, left: `${interval[0]}%`, width: `${Math.max(0, Math.round((interval[1] - interval[0]) * 10) / 10)}%`, boxSizing: 'border-box', border: '1px solid var(--color-info)', borderRadius: 999, background: 'var(--color-info-soft)' }}
        />
      )}
      {passRate != null && (
        <span style={{ position: 'absolute', top: 2, left: `${passRate}%`, width: 10, height: 10, marginLeft: -5, borderRadius: '50%', background: 'var(--color-info)' }} />
      )}
    </span>
  );
}

export default function ComparisonIntervals({ plot, testId = 'comparison-intervals' }) {
  if (!plot) return null;
  const confidence = `${plot.confidence}% CI`;

  return (
    <div style={grid} data-testid={testId}>
      <MicroLabel size={10} color="var(--color-text-muted)" style={fullWidth}>{`Pass rate · ${confidence}`}</MicroLabel>
      {plot.rows.map((entry) => {
        const { short } = splitModelLabel(entry.label, '');
        return (
          <div key={entry.label} style={row} data-testid="comparison-interval-row" data-model={entry.label}>
            <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={entry.label}>{short}</span>
            <Track passRate={entry.passRate} interval={entry.interval} />
            <span style={figureStyle}>
              <strong style={{ color: 'var(--color-text-primary)' }}>{entry.passRate == null ? '—' : `${entry.passRate}%`}</strong>
              {` ${entry.interval ? `${entry.interval[0]} to ${entry.interval[1]}` : 'no interval'} · ${plural(entry.scenarios, 'scenario')}`}
            </span>
          </div>
        );
      })}
      <div style={row} aria-hidden="true">
        <span />
        <span style={{ position: 'relative', display: 'block', height: 14 }}>
          {TICKS.map((tick) => (
            <span key={tick} style={{ position: 'absolute', left: `${tick}%`, transform: 'translateX(-50%)', fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)' }}>{`${tick}%`}</span>
          ))}
        </span>
        <span />
      </div>
      {plot.conclusion && (
        <div style={{ ...fullWidth, fontSize: 12, lineHeight: '18px', color: 'var(--color-text-cell)', textWrap: 'pretty' }} data-testid="comparison-conclusion">{plot.conclusion}</div>
      )}
      {plot.resamples != null && (
        <span style={{ ...fullWidth, fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)' }}>
          {`${confidence} from ${Number(plot.resamples).toLocaleString('en-US')} resamples of whole scenarios`}
        </span>
      )}
    </div>
  );
}
