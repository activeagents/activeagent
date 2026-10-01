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

const AGENT_TITLE = "What the agent spent answering — the operating cost of these interactions, and of one on average";
const JUDGE_TITLE = "What the judge model spent scoring, recommending and ruling — the evaluation's own offline cost";

export const agentUnit = (spend) => (spend?.agent?.unit === 'replay' ? 'replay' : 'sampled interaction');

// A per-interaction rate, as every other cost: four decimals, six when the
// rate is under a hundredth of a cent — a cheap model's honest figure is
// "$0.000042", not "$0.0000" — and "~" when the cost it is taken from was
// estimated.
export const fmtRate = (value, estimated = false) => fmtSpend(value, { estimated });

// The same split as one mono line, for a footer: "agent ~$0.4400 · 8 replays
// · ~$0.0550 each · judge ~$0.1200 · 24 calls".
export const spendText = (spend) => {
  if (!spend) return null;
  const parts = [];
  if (spend.agent) {
    const agent = [`agent ${fmtSpend(spend.agent.cost, { estimated: spend.agent.estimated })}`, plural(spend.agent.count, agentUnit(spend))];
    if (spend.agent.perInteraction != null) agent.push(`${fmtRate(spend.agent.perInteraction, spend.agent.estimated)} each`);
    parts.push(agent.join(' · '));
  }
  if (spend.judge) parts.push(`judge ${fmtSpend(spend.judge.cost, { estimated: spend.judge.estimated })} · ${plural(spend.judge.calls, 'call')}`);
  return parts.join(' · ');
};

function Cell({ label, value, sub, title, valueColor, testId, first = false }) {
  return (
    <div
      data-testid={testId}
      title={title}
      style={{ padding: '10px 16px', minWidth: 0, borderLeft: first ? 'none' : '1px solid var(--color-border-light)' }}
    >
      <MicroLabel size={10} color="var(--color-text-muted)">{label}</MicroLabel>
      <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 18, fontWeight: 700, lineHeight: 1.1, color: valueColor || 'var(--color-text-primary)' }}>{value}</div>
      <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>{sub}</div>
    </div>
  );
}

// `judgedBy` is the run's judge as the evaluation names it (judgeLabel):
// a judged run whose judge's spend nothing recorded says so, rather than
// claiming no judge was asked.
export default function SpendStrip({ spend, judgedBy = null, testId = 'run-spend' }) {
  if (!spend) return null;
  const { agent, judge, total, totalEstimated } = spend;
  const tokens = agent && (agent.inputTokens != null || agent.outputTokens != null)
    ? ` · in ${fmtK(agent.inputTokens)} · out ${fmtK(agent.outputTokens)}`
    : '';
  const judged = judgedBy && judgedBy !== 'rules';
  const judgeSub = judge
    ? [plural(judge.calls, 'call'), judgeCallsText(judge), judge.model, judgeSourceText(judge), 'offline'].filter(Boolean).join(' · ')
    : judged ? `judge ${judgedBy} · spend not recorded` : 'no judge asked · rules only';

  return (
    <Card padding={0} testId={testId} style={{ overflow: 'hidden' }}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))' }}>
        <Cell
          first
          label="Agent cost"
          title={AGENT_TITLE}
          value={agent ? fmtSpend(agent.cost, { estimated: agent.estimated }) : '—'}
          valueColor={agent?.cost != null ? undefined : 'var(--color-text-muted)'}
          sub={agent
            ? `${plural(agent.count, agentUnit(spend))}${agent.perInteraction != null ? ` · ${fmtRate(agent.perInteraction, agent.estimated)} per interaction` : ''}${tokens}`
            : 'nothing replayed or sampled'}
          testId="run-spend-agent"
        />
        <Cell
          label="Judge cost"
          title={JUDGE_TITLE}
          value={judge ? fmtSpend(judge.cost, { estimated: judge.estimated }) : '—'}
          valueColor={judge ? undefined : 'var(--color-text-muted)'}
          sub={judgeSub}
          testId="run-spend-judge"
        />
        <Cell
          label="Total"
          title="Agent and judge together — what this run cost end to end"
          value={total != null ? fmtSpend(total, { estimated: totalEstimated }) : '—'}
          sub={spendTotalLabel(spend)}
          testId="run-spend-total"
        />
      </div>
      {totalEstimated && (
        <div data-testid="run-spend-legend" style={{ padding: '6px 16px', borderTop: '1px solid var(--color-border-light)', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
          {COST_LEGEND}
        </div>
      )}
    </Card>
  );
}
