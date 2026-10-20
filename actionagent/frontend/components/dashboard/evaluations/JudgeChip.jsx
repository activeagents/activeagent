import React, { useEffect, useState } from 'react';
import { Badge, Button, Card, MicroLabel, MonoLink, MONO } from '../primitives';
import { dashboardPath, navigateTo } from '../../../utils/dashboardPath';
import { judgeInfo, judgeTitle } from '../../../utils/evaluationJudge.mjs';

const SETTINGS_KEYS_PATH = '/settings?tab=api-keys';

const mono = (size = 11) => ({ fontFamily: MONO, fontSize: size, color: 'var(--color-text-secondary)' });

// "judged by <model>" for a run, opening the judge's configuration: the
// agent class it runs as, its provider, the model it asked for and where
// that came from, the models that answered, and a field that pins the model
// on the evaluation for the next run. A run with no recorded judge (a rules
// run, or one from before runs recorded it) shows the label alone.
export default function JudgeChip({ evaluation, run, label, onChanged, testId = 'judge-chip' }) {
  const info = judgeInfo(evaluation, run);
  const [open, setOpen] = useState(false);
  const [model, setModel] = useState(info?.suggestion || '');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => { setModel(info?.suggestion || ''); }, [info?.suggestion]);

  if (!label) return null;
  if (!info) return <span style={mono()}>{`judged by ${label}`}</span>;

  const save = async (judgeModel) => {
    setSaving(true);
    setError(null);
    try {
      const response = await fetch(`/api/evaluations/${evaluation.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ evaluation: { judge_model: judgeModel } }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        setError((data.errors || [data.error]).filter(Boolean).join(', ') || `Saving the judge failed (HTTP ${response.status})`);
        return;
      }
      await onChanged?.();
    } finally {
      setSaving(false);
    }
  };

  const row = (name, value) => (
    <>
      <MicroLabel size={10}>{name}</MicroLabel>
      <span style={{ ...mono(12), color: 'var(--color-text-cell)', overflowWrap: 'anywhere' }}>{value}</span>
    </>
  );

  return (
    <span style={{ display: 'inline-flex', flexDirection: 'column', gap: 8, minWidth: 0 }} data-testid={testId}>
      <button
        type="button"
        onClick={() => setOpen(!open)}
        title={judgeTitle(info)}
        aria-expanded={open}
        style={{ ...mono(), display: 'inline-flex', alignItems: 'center', gap: 6, background: 'none', border: 'none', padding: 0, cursor: 'pointer' }}
      >
        <span>judged by <span style={{ color: 'var(--color-info)' }}>{label}</span></span>
        {info.auto && <Badge tone="warning" size={10} title="No judge model is pinned: the provider chose">auto</Badge>}
        {info.answered.length > 1 && <Badge tone="error" size={10} title="More than one model judged this run">{`${info.answered.length} models`}</Badge>}
      </button>
      {open && (
        <Card padding="12px 14px" testId={`${testId}-panel`} style={{ display: 'flex', flexDirection: 'column', gap: 10, maxWidth: 560 }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'max-content 1fr', columnGap: 14, rowGap: 6, alignItems: 'baseline' }}>
            {row('Judge agent', info.agent)}
            {row('Provider', info.provider || '—')}
            {row('Asked for', info.requested
              ? `${info.requested} · ${info.sourceText}`
              : `${info.providerDefault || 'no model'} · ${info.sourceText}`)}
            {row('Answered by', info.answered.length
              ? info.answered.map(([name, calls]) => `${name} ×${calls}`).join(', ')
              : 'no calls recorded')}
          </div>
          {info.auto && (
            <div style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
              {info.answered.length > 1
                ? 'Different models judged this run. Pin one so runs are judged alike.'
                : 'No judge model is pinned, so a later run can be judged by a different model. Pin one to compare runs.'}
            </div>
          )}
          {evaluation?.id != null && (
            <form
              onSubmit={(event) => { event.preventDefault(); if (model.trim()) save(model.trim()); }}
              style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}
            >
              <input
                value={model}
                onChange={(event) => setModel(event.target.value)}
                placeholder={info.provider === 'openrouter' ? 'e.g. anthropic/claude-sonnet-4.5' : 'judge model id'}
                aria-label="Judge model"
                data-testid={`${testId}-model`}
                style={{ flex: '1 1 220px', padding: '6px 10px', borderRadius: 8, fontSize: 12, fontFamily: MONO, boxSizing: 'border-box', background: 'var(--color-card)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)' }}
              />
              <Button size="sm" variant="primary" type="submit" disabled={saving || !model.trim() || model.trim() === info.pinned} testId={`${testId}-pin`}>
                Pin judge model
              </Button>
              {info.pinned && (
                <Button size="sm" onClick={() => save('')} disabled={saving} testId={`${testId}-unpin`}>Unpin</Button>
              )}
            </form>
          )}
          <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', alignItems: 'baseline' }}>
            <span style={mono()}>
              {info.pinned ? `next run: ${info.pinned}` : `next run: ${info.providerDefault || `${info.provider} default`}`}
            </span>
            <MonoLink href={dashboardPath(SETTINGS_KEYS_PATH)} onClick={() => navigateTo(SETTINGS_KEYS_PATH)}>
              {`${info.provider || 'provider'} key in Settings`}
            </MonoLink>
          </div>
          {error && <div style={{ fontSize: 12, color: 'var(--color-error-text)' }}>{error}</div>}
        </Card>
      )}
    </span>
  );
}
