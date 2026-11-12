import React from 'react';
import { Badge, Card, MicroLabel, MONO } from '../primitives';
import { ModelIdentity } from './ModelComparisonTable';
import { fmtPasses } from '../../../utils/evalFormat.mjs';
import { gateSentence, runGates } from '../../../utils/evaluationRuns.mjs';

// Pass rate by group: the bars a run was held to (its suite's or catalog
// set's `pass`), one row per group and model, then the whole run's ("All")
// per model, as the server worked them out (ActiveAgent::Evals::Report#gates).
// Each row reads passed of total, the bar, and met / not met in words; a
// group that declared `gated: false` reads "reported only". Nothing for a
// run held to no bars.
const STATUS = {
  met: { tone: 'success', text: 'met' },
  missed: { tone: 'error', text: 'not met' },
  ungated: { tone: 'muted', text: 'reported only' },
};

const cell = { padding: '8px 14px', fontSize: 13, color: 'var(--color-text-cell)', borderTop: '1px solid var(--color-border-light)', textAlign: 'left' };
const head = { ...cell, fontFamily: MONO, fontSize: 11, fontWeight: 600, color: 'var(--color-text-muted)', borderTop: 'none' };

export default function GateTable({ run, testId = 'run-gates' }) {
  const gates = runGates(run);
  if (!gates || !gates.rows.length) return null;
  const missed = gates.rows.filter((gate) => gate.gated && !gate.met).length;

  return (
    <Card padding={0} style={{ overflow: 'hidden' }} testId={testId}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, padding: '10px 14px', flexWrap: 'wrap' }}>
        <MicroLabel>Pass rate by group</MicroLabel>
        <span style={{ fontFamily: MONO, fontSize: 11, color: gates.met ? 'var(--color-text-muted)' : 'var(--color-error-text)' }} data-testid="run-gates-verdict">
          {gates.met ? 'every gate met' : missed ? `${missed} ${missed === 1 ? 'gate' : 'gates'} not met` : 'no gate reached'}
        </span>
      </div>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr>
              <th scope="col" style={head}>Group</th>
              <th scope="col" style={head}>Model</th>
              <th scope="col" style={{ ...head, textAlign: 'right' }}>Passed</th>
              <th scope="col" style={{ ...head, textAlign: 'right' }}>Required</th>
              <th scope="col" style={head}>Gate</th>
            </tr>
          </thead>
          <tbody>
            {gates.rows.map((gate) => {
              const status = !gate.gated ? STATUS.ungated : gate.met ? STATUS.met : STATUS.missed;
              return (
                <tr key={`${gate.group ?? ''}\u0000${gate.label}`} data-testid="run-gate-row" data-gate={status.text} title={gateSentence(gate)}>
                  <td style={{ ...cell, fontWeight: gate.group == null ? 600 : 400 }}>{gate.name}</td>
                  <td style={cell}><ModelIdentity label={gate.label} size={12} /></td>
                  <td style={{ ...cell, fontFamily: MONO, textAlign: 'right', whiteSpace: 'nowrap' }}>{fmtPasses(gate.passed, gate.total)}</td>
                  <td style={{ ...cell, fontFamily: MONO, textAlign: 'right', whiteSpace: 'nowrap' }}>
                    {gate.gated ? `${Math.round(gate.minRate * 100)}%` : '—'}
                  </td>
                  <td style={cell}><Badge tone={status.tone} size={10}>{status.text}</Badge></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Card>
  );
}
