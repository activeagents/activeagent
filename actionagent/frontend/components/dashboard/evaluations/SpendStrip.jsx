import React from 'react';
import { Card, MicroLabel, MONO } from '../primitives';
import { fmtK } from '../../../utils/format';
import { COST_LEGEND, fmtSpend } from '../../../utils/evalFormat.mjs';
import { judgeCallsText, judgeSourceText, plural, spendTotalLabel } from '../../../utils/evaluationRuns.mjs';

// What a run cost, on the two sides that answer different questions.
//
// The agent's side is the operating figure: what the interactions cost to
// serve — a scenario run's replays (simulated user–agent conversations) or
// the recorded generations a sampling run scored — and what one interaction
// costs on average, the number a per-conversation budget is set against.
// The judge's side is the evaluation's own overhead: the judge model's
// calls, agent-to-agent and offline, from the engine's meter, the
// application's figures or the judge traces. Shown apart because the first
// is what running the agent costs and the second is what checking it costs.
//
// A figure estimated from tokens × model rates reads "~$0.0243"; the strip
// carries the legend once when any of its figures does.
//
// The strip is the sampling run page's (EvaluationRunDetail). The suite's
// RunHeader shows the two cost cells among its own stats instead of a
// second strip, so the cells are exported — the same labels, titles and
// sub-lines wherever a run's cost is read — with the two states a header
// has before a figure exists: `pending` while the run goes, `failed` for a
// run that ended before it replayed anything. StatCell is the tile itself,
// which the header also uses for PASSED, MODELS and TO FIX.

const AGENT_TITLE = "What the agent spent answering — the operating cost of these interactions, and of one on average";
const JUDGE_TITLE = "What the judge model spent scoring, recommending and ruling — the evaluation's own offline cost";
const MUTED = 'var(--color-text-muted)';

export const agentUnit = (spend) => (spend?.agent?.unit === 'replay' ? 'replay' : 'sampled interaction');

// A per-interaction rate, as every other cost: four decimals, six when the
// rate is under a hundredth of a cent — a cheap model's honest figure is
// "$0.000042", not "$0.0000" — and "~" when the cost it is taken from was
// estimated.
export const fmtRate = (value, estimated = false) => fmtSpend(value, { estimated });

// The same split as one mono line, for a footer: "agent ~$0.4400 · 8 replays
// · ~$0.0550 each · judge ~$0.1200 · 24 calls · total ~$0.5600". The total
// closes the line when the run has one, because the suite's footer is the
// only place it is read.
export const spendText = (spend) => {
  if (!spend) return null;
  const parts = [];
  if (spend.agent) {
    const agent = [`agent ${fmtSpend(spend.agent.cost, { estimated: spend.agent.estimated })}`, plural(spend.agent.count, agentUnit(spend))];
    if (spend.agent.perInteraction != null) agent.push(`${fmtRate(spend.agent.perInteraction, spend.agent.estimated)} each`);
    parts.push(agent.join(' · '));
  }
  if (spend.judge) parts.push(`judge ${fmtSpend(spend.judge.cost, { estimated: spend.judge.estimated })} · ${plural(spend.judge.calls, 'call')}`);
  if (spend.total != null) parts.push(`total ${fmtSpend(spend.total, { estimated: spend.totalEstimated })}`);
  return parts.join(' · ');
};

// One stat tile of a strip: mono uppercase label · 18px mono/700 value ·
// 11px mono sub-line, divided from the tile before it unless `first`.
// `value` and `sub` take a node as readily as text. `role`, `tabIndex`,
// `onClick` and `onKeyDown` make the tile a control (the header's TO FIX
// cell is a button); `valueTestId` marks the figure for a test.
export function StatCell({ label, value, sub, title, valueColor, testId, valueTestId, first = false, onClick, onKeyDown, role, tabIndex, style }) {
  return (
    <div
      data-testid={testId}
      title={title}
      role={role}
      tabIndex={tabIndex}
      onClick={onClick}
      onKeyDown={onKeyDown}
      style={{ padding: '10px 16px', minWidth: 0, borderLeft: first ? 'none' : '1px solid var(--color-border-light)', ...style }}
    >
      <MicroLabel size={10} color={MUTED}>{label}</MicroLabel>
      <div data-testid={valueTestId} style={{ marginTop: 4, fontFamily: MONO, fontSize: 18, fontWeight: 700, lineHeight: 1.1, color: valueColor || 'var(--color-text-primary)' }}>{value}</div>
      <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>{sub}</div>
    </div>
  );
}

// A cost not yet known: the run is still going, so the figure comes with
// its completion.
const PENDING_FIGURE = { value: '…', valueColor: MUTED, sub: 'priced when the run completes' };

// The agent's side. A run that failed before replaying anything has no
// operating cost to show, so it reads "—" rather than "nothing replayed or
// sampled" (which is a complete run that recorded no interactions).
export function AgentCostCell({ spend, pending = false, failed = false, first = false }) {
  const agent = spend?.agent || null;
  const tokens = agent && (agent.inputTokens != null || agent.outputTokens != null)
    ? ` · in ${fmtK(agent.inputTokens)} · out ${fmtK(agent.outputTokens)}`
    : '';
  const figure = failed ? { value: '—', valueColor: MUTED, sub: 'nothing replayed' }
    : pending ? PENDING_FIGURE
      : {
        value: agent ? fmtSpend(agent.cost, { estimated: agent.estimated }) : '—',
        valueColor: agent?.cost != null ? undefined : MUTED,
        sub: agent
          ? `${plural(agent.count, agentUnit(spend))}${agent.perInteraction != null ? ` · ${fmtRate(agent.perInteraction, agent.estimated)} per interaction` : ''}${tokens}`
          : 'nothing replayed or sampled',
      };
  return <StatCell first={first} label="Agent cost" title={AGENT_TITLE} testId="run-spend-agent" {...figure} />;
}

// The judge's side. `judgedBy` is the run's judge as the evaluation names
// it (judgeLabel): a judged run whose judge's spend nothing recorded says
// so, rather than claiming no judge was asked. A failed run keeps that
// sub-line under a "—": whether a judge was asked is still true of it.
export function JudgeCostCell({ spend, judgedBy = null, pending = false, failed = false }) {
  const judge = spend?.judge || null;
  const judged = judgedBy && judgedBy !== 'rules';
  const judgeSub = judge
    ? [plural(judge.calls, 'call'), judgeCallsText(judge), judge.model, judgeSourceText(judge), 'offline'].filter(Boolean).join(' · ')
    : judged ? `judge ${judgedBy} · spend not recorded` : 'no judge asked · rules only';
  const figure = failed ? { value: '—', valueColor: MUTED, sub: judgeSub }
    : pending ? PENDING_FIGURE
      : { value: judge ? fmtSpend(judge.cost, { estimated: judge.estimated }) : '—', valueColor: judge ? undefined : MUTED, sub: judgeSub };
  return <StatCell label="Judge cost" title={JUDGE_TITLE} testId="run-spend-judge" {...figure} />;
}

// The three cells as one card, for the sampling run page: agent, judge and
// their total, with the legend under them when a figure is an estimate.
export default function SpendStrip({ spend, judgedBy = null, testId = 'run-spend' }) {
  if (!spend) return null;
  const { total, totalEstimated } = spend;

  return (
    <Card padding={0} testId={testId} style={{ overflow: 'hidden' }}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))' }}>
        <AgentCostCell first spend={spend} />
        <JudgeCostCell spend={spend} judgedBy={judgedBy} />
        <StatCell
          label="Total"
          title="Agent and judge together — what this run cost end to end"
          value={total != null ? fmtSpend(total, { estimated: totalEstimated }) : '—'}
          sub={spendTotalLabel(spend)}
          testId="run-spend-total"
        />
      </div>
      {totalEstimated && (
        <div data-testid="run-spend-legend" style={{ padding: '6px 16px', borderTop: '1px solid var(--color-border-light)', fontFamily: MONO, fontSize: 11, color: MUTED }}>
          {COST_LEGEND}
        </div>
      )}
    </Card>
  );
}
