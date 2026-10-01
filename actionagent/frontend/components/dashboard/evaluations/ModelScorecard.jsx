import React from 'react';
import { Badge, Card, MONO, TONE, toneFor } from '../primitives';
import { fmtMs, fmtTokens } from '../../../utils/format';
import { costTitle, fmtPasses, fmtScore, fmtSpend } from '../../../utils/evalFormat.mjs';
import { plural } from '../../../utils/evaluationRuns.mjs';
import { fmtRate } from './SpendStrip';

// One model cohort of a run: how many of its interactions passed, as the
// headline, then what they scored, took and cost. The same card serves a
// scenario run (replays) and a sampling run (recorded generations), so a
// suite and a sampling evaluation read alike.
//
// `passed`/`total` drive the headline and the bar; without them (an older
// run) `avgScore` stands in. `criteria` is `{ cleared, scored }` or null.
// `cost` is the cohort's agent-side spend and `perInteraction` its rate,
// `estimated` when any of it was priced from tokens (the figure then reads
// "~"). `judgeCost` and `judgeCalls` are what the judge spent on this
// model's answers, kept on its own line: it is the evaluation's cost, not
// the model's. `badges` are `{ tone, text, testId }`; `note` is a mono line
// under them.

const mean = (value) => (value >= 0.85 ? 'success' : value >= 0.7 ? 'warning' : 'error');

function Stat({ label, children, title, nowrap = true }) {
  return (
    <span style={{ whiteSpace: nowrap ? 'nowrap' : 'normal' }} title={title}>
      {label} <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{children}</span>
    </span>
  );
}

export default function ModelScorecard({
  label, short, provider, winner = false, passed, total, avgScore, criteria, latencyMs, inputTokens, outputTokens,
  cost, perInteraction, estimated = false, judgeCost = null, judgeCalls = 0, judgeEstimated = false,
  unit = 'interaction', badges = [], note, testId = 'model-scorecard',
}) {
  const bySamples = passed != null && total > 0;
  const ratio = bySamples ? passed / total : null;
  const tone = bySamples ? toneFor(ratio) : avgScore != null ? mean(avgScore) : 'muted';
  const color = TONE[tone].strong;
  const judged = judgeCost != null || judgeCalls > 0;

  return (
    <Card padding="14px 16px" testId={testId} style={{ display: 'flex', flexDirection: 'column', gap: 10, minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <span style={{ fontFamily: MONO, fontSize: 14, fontWeight: 700, color: 'var(--color-text-primary)' }} title={label || undefined}>
          {short || label || 'all samples'}
        </span>
        {provider && <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{provider}</span>}
        {winner && <Badge tone="info" size={10} style={{ padding: '1px 6px' }} testId="judges-pick">judge's pick</Badge>}
      </div>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap' }}>
        <span style={{ fontFamily: MONO, fontSize: 26, fontWeight: 700, lineHeight: 1, color }} data-testid="model-scorecard-headline">
          {bySamples ? fmtPasses(passed, total) : avgScore != null ? fmtScore(avgScore) : '—'}
        </span>
        <span style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>
          {bySamples ? `${unit === 'scenario' ? 'scenarios' : 'samples'} passed` : avgScore != null ? 'mean score' : 'nothing scored'}
        </span>
      </div>
      <span style={{ display: 'block', height: 6, borderRadius: 999, background: 'var(--color-muted)', overflow: 'hidden' }}>
        <span style={{ display: 'block', height: '100%', borderRadius: 999, background: color, width: `${Math.round((ratio ?? avgScore ?? 0) * 100)}%` }} />
      </span>
      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)' }}>
        <Stat label="score">{fmtScore(avgScore)}</Stat>
        {criteria && <Stat label="criteria">{fmtPasses(criteria.cleared, criteria.scored)}</Stat>}
        {latencyMs != null && <Stat label="latency">{fmtMs(latencyMs)}</Stat>}
        {(inputTokens != null || outputTokens != null) && (
          <span style={{ whiteSpace: 'nowrap' }}>
            <span style={{ color: 'var(--color-token-in)' }}>in</span>{' '}
            <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{fmtTokens(inputTokens)}</span>
            {' · '}
            <span style={{ color: 'var(--color-token-out)' }}>out</span>{' '}
            <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{fmtTokens(outputTokens)}</span>
          </span>
        )}
        {cost != null && (
          <Stat
            label="cost"
            title={`What the agent spent under this model${perInteraction != null ? ` — ${fmtRate(perInteraction, estimated)} per ${unit}` : ''}${estimated ? ` · ${costTitle()}` : ''}`}
          >
            {fmtSpend(cost, { estimated })}
            {perInteraction != null && (
              <span style={{ fontWeight: 400, color: 'var(--color-text-muted)' }}>{` · ${fmtRate(perInteraction, estimated)} / ${unit}`}</span>
            )}
          </Stat>
        )}
        {judged && (
          <Stat label="judge" title="What the judge spent on this model's answers — the evaluation's own cost, not the model's">
            {fmtSpend(judgeCost, { estimated: judgeEstimated })}
            <span style={{ fontWeight: 400, color: 'var(--color-text-muted)' }}>{` · ${plural(judgeCalls, 'call')}`}</span>
          </Stat>
        )}
      </div>
      {(badges.length > 0 || note) && (
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
          {badges.map((badge) => (
            <Badge key={badge.text} tone={badge.tone} testId={badge.testId}>{badge.text}</Badge>
          ))}
          {note && <span style={{ fontFamily: MONO, fontSize: 11, color: note.color || 'var(--color-text-muted)' }}>{note.text}</span>}
        </div>
      )}
    </Card>
  );
}
