import React, { useState } from 'react';
import { Button, MicroLabel, MONO, Panel } from '../primitives';
import { EXPLORER_DEFAULT_BUDGET, explorerBudget, explorerStartError } from '../../../utils/explorer.mjs';

const inputStyle = {
  width: 90, padding: '6px 8px', borderRadius: 6, fontSize: 13, fontFamily: MONO,
  border: '1px solid var(--color-border)', background: 'var(--color-card)', color: 'var(--color-text-primary)',
};

// Starts the engine's explorer on the project (POST
// /api/projects/:id/explorations) with an optional budget. onStarted(exploration)
// is called with the new exploration.
export default function ExplorerStart({ projectId, sandboxReady, onStarted }) {
  const [form, setForm] = useState({ minutes: '', steps: '', cost: '' });
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const { error: budgetError, budget } = explorerBudget(form);

  const start = async () => {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch(`/api/projects/${projectId}/explorations`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ budget }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(explorerStartError(res.status, data));
      onStarted?.(data.exploration);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  const field = (key, label, placeholder) => (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
      <MicroLabel>{label}</MicroLabel>
      <input
        type="number"
        min="0"
        value={form[key]}
        placeholder={placeholder}
        onChange={(event) => setForm({ ...form, [key]: event.target.value })}
        aria-label={label}
        style={inputStyle}
      />
    </label>
  );

  return (
    <Panel title="Explore the app" testId="explorer-start" bodyStyle={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 10 }}>
      <p style={{ margin: 0, fontSize: 13, color: 'var(--color-text-secondary)' }}>
        The explorer walks the app in the sandbox's browser and proposes the questions a user would ask the project's agent,
        each with a rubric. They wait here for review; nothing reaches the evaluation until you accept it.
      </p>
      <div style={{ display: 'flex', gap: 12, alignItems: 'flex-end', flexWrap: 'wrap' }}>
        {field('minutes', 'Minutes', String(EXPLORER_DEFAULT_BUDGET.minutes))}
        {field('steps', 'Browser steps', String(EXPLORER_DEFAULT_BUDGET.steps))}
        {field('cost', 'Cost cap ($)', 'none')}
        <Button variant="primary" onClick={start} disabled={busy || !sandboxReady || Boolean(budgetError)} testId="explorer-start-button">
          {busy ? 'Starting…' : 'Explore the app'}
        </Button>
      </div>
      {!sandboxReady && <div style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>Boot the project first: the explorer walks the app its sandbox serves.</div>}
      {(budgetError || error) && <div style={{ fontSize: 12, color: 'var(--color-error-text)' }} data-testid="explorer-start-error">{budgetError || error}</div>}
    </Panel>
  );
}
