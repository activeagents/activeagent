import React from 'react';
import { MONO, Panel, TONE } from '../primitives';
import { budgetMeters } from '../../../utils/explorations.mjs';

// Minutes, browser steps and cost used against each limit the exploration's
// budget sets. Renders nothing when it sets none.
export default function ExplorationBudgetMeter({ budget, usage }) {
  const rows = budgetMeters(budget, usage);
  if (rows.length === 0) return null;

  return (
    <Panel title="Budget" testId="exploration-budget" bodyStyle={{ padding: '10px 12px', display: 'flex', flexDirection: 'column', gap: 8 }}>
      {rows.map((row) => {
        const tone = row.ratio >= 1 ? TONE.error : row.ratio >= 0.8 ? TONE.warning : TONE.info;
        return (
          <div key={row.key} data-testid={`exploration-budget-${row.key}`} style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ width: 110, fontSize: 12, color: 'var(--color-text-secondary)' }}>{row.label}</span>
            <span style={{ flex: 1, height: 6, borderRadius: 999, background: 'var(--color-muted)', overflow: 'hidden' }}>
              <span style={{ display: 'block', width: `${Math.round(row.ratio * 100)}%`, height: '100%', background: tone.strong }} />
            </span>
            <span style={{ fontFamily: MONO, fontSize: 11, minWidth: 90, textAlign: 'right', color: tone.text }}>{row.text}</span>
          </div>
        );
      })}
    </Panel>
  );
}
