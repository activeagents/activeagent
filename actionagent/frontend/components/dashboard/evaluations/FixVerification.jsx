import React, { useState } from 'react';
import { Badge, Button } from '../primitives';
import { dashboardPath } from '../../../utils/dashboardPath';

export default function FixVerification({ session, evaluationId, sandboxId, onRetry }) {
  const [message, setMessage] = useState(null);
  const [running, setRunning] = useState(false);
  const verification = session?.verification;
  if (!session?.evaluation_run_id) return null;
  const rows = verification?.rows || [];
  const complete = verification?.status === 'complete';
  const fullSuite = async () => {
    setRunning(true); setMessage(null);
    try {
      const response = await fetch(`/api/evaluations/${evaluationId}/run`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sandbox_id: sandboxId, models: session.fix_item?.models }) });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || 'Could not run the full suite.');
      setMessage({ run: data.run.id });
    } catch (error) { setMessage({ error: error.message }); }
    finally { setRunning(false); }
  };
  const score = (value) => value == null ? '—' : Number(value).toFixed(2);
  return <section data-testid="fix-verification" style={{ display: 'flex', flexDirection: 'column', gap: 12, minWidth: 0 }}>
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}><strong style={{ fontSize: 13 }}>Before & after</strong><Badge tone={complete ? 'info' : 'muted'}>{verification?.status || (session.status === 'succeeded' ? session.diff ? 'Preparing verification' : 'No changes to verify' : session.status)}</Badge></div>
    {verification?.error && <p role="alert" style={{ color: 'var(--color-error-text)', margin: 0, fontSize: 13 }}>{verification.error}</p>}
    <div style={{ overflowX: 'auto' }}><table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
      <thead><tr>{['Scenario / model', 'Before', 'After', 'Score Δ', 'Fault'].map((title) => <th key={title} style={{ textAlign: 'left', padding: '8px 10px', borderBottom: '1px solid var(--color-border)', color: 'var(--color-text-muted)', whiteSpace: 'nowrap' }}>{title}</th>)}</tr></thead>
      <tbody>{rows.map((row) => <tr key={`${row.scenario_key}/${row.model}`}>
        <td style={{ padding: 10, fontFamily: 'var(--font-mono)' }}>{row.scenario_key}<div style={{ color: 'var(--color-text-muted)', fontSize: 10, marginTop: 4 }}>{row.model}</div></td>
        <td style={{ padding: 10 }}>{row.before} · {score(row.before_score)}</td>
        <td style={{ padding: 10, color: row.change === 'fixed' ? 'var(--color-success-text)' : ['regressed', 'still_failing'].includes(row.change) ? 'var(--color-error-text)' : 'var(--color-text-secondary)' }}>{row.after || 'pending'}{row.after_score != null && ` · ${score(row.after_score)}`}<div style={{ fontSize: 10, marginTop: 4 }}>{row.change.replaceAll('_', ' ')}</div></td>
        <td style={{ padding: 10, fontFamily: 'var(--font-mono)' }}>{row.score_change == null ? '—' : `${row.score_change > 0 ? '+' : ''}${score(row.score_change)}`}</td>
        <td style={{ padding: 10 }}>{row.fault || (row.after ? 'none' : row.before_fault) || '—'}</td>
      </tr>)}</tbody>
    </table></div>
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', fontSize: 12 }}>
      <a href={dashboardPath(`/evaluations/${evaluationId}/runs/${session.evaluation_run_id}`)}>Original run</a>
      {verification?.run_id && <a href={dashboardPath(`/evaluations/${evaluationId}/runs/${verification.run_id}`)}>Verification run</a>}
      {complete && <Button size="sm" onClick={fullSuite} disabled={running}>{running ? 'Starting…' : 'Re-run the full suite'}</Button>}
      {onRetry && ['succeeded', 'failed', 'cancelled'].includes(session.status) && (complete || verification?.error || session.status !== 'succeeded' || !session.diff) && <Button size="sm" onClick={onRetry}>Try again</Button>}
    </div>
    {message?.run && <a style={{ fontSize: 12 }} href={dashboardPath(`/evaluations/${evaluationId}/runs/${message.run}`)}>Full suite queued — open run →</a>}
    {message?.error && <p role="alert" style={{ color: 'var(--color-error-text)' }}>{message.error}</p>}
  </section>;
}
