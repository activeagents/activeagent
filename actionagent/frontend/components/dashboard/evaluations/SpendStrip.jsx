import React from 'react';
import { Card, MicroLabel, MONO } from '../primitives';
import { fmtCost, fmtK } from '../../../utils/format';
import { judgeCallsText, plural } from '../../../utils/evaluationRuns.mjs';

// What a run cost, on the two sides that answer different questions.
//
// The agent's side is the operating figure: what the interactions cost to
// serve — a scenario run's replays (simulated user–agent conversations) or
// the recorded generations a sampling run scored — and what one interaction
// costs on average, the number a per-conversation budget is set against.
// The judge's side is the evaluation's own overhead: the judge model's
// calls, agent-to-agent and offline. Shown apart because the first is what
// running the agent costs and the second is what checking it costs.

const AGENT_TITLE = "What the agent spent answering — the operating cost of these interactions, and of one on average";
const JUDGE_TITLE = "What the judge model spent scoring, recommending and ruling — the evaluation's own offline cost";

export const agentUnit = (spend) => (spend?.agent?.unit === 'replay' ? 'replay' : 'sampled interaction');

// A per-interaction rate: four decimals like every other cost, six when the
// rate is under a hundredth of a cent — a cheap model's honest figure is
// "$0.000042", not "$0.0000".
export const fmtRate = (value) => (value == null ? '—' : fmtCost(value, Math.abs(Number(value)) < 0.001 ? 6 : 4));

// The same split as one mono line, for a footer: "agent $0.4400 · 8 replays
// · $0.0550 each · judge $0.1200 · 24 calls".
export const spendText = (spend) => {
  if (!spend) return null;
  const parts = [];
  if (spend.agent) {
    const agent = [`agent ${fmtCost(spend.agent.cost)}`, plural(spend.agent.count, agentUnit(spend))];
    if (spend.agent.perInteraction != null) agent.push(`${fmtRate(spend.agent.perInteraction)} each`);
    parts.push(agent.join(' · '));
  }
  if (spend.judge) parts.push(`judge ${fmtCost(spend.judge.cost)} · ${plural(spend.judge.calls, 'call')}`);
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

export default function SpendStrip({ spend, testId = 'run-spend' }) {
  if (!spend) return null;
  const { agent, judge, total } = spend;
  const tokens = agent && (agent.inputTokens != null || agent.outputTokens != null)
    ? ` · in ${fmtK(agent.inputTokens)} · out ${fmtK(agent.outputTokens)}`
    : '';

  return (
    <Card padding={0} testId={testId} style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', overflow: 'hidden' }}>
      <Cell
        first
        label="Agent cost"
        title={AGENT_TITLE}
        value={agent ? fmtCost(agent.cost) : '—'}
        sub={agent
          ? `${plural(agent.count, agentUnit(spend))}${agent.perInteraction != null ? ` · ${fmtRate(agent.perInteraction)} per interaction` : ''}${tokens}`
          : 'nothing replayed or sampled'}
        testId="run-spend-agent"
      />
      <Cell
        label="Judge cost"
        title={JUDGE_TITLE}
        value={judge ? fmtCost(judge.cost) : '—'}
        valueColor={judge ? undefined : 'var(--color-text-muted)'}
        sub={judge
          ? [plural(judge.calls, 'call'), judgeCallsText(judge), judge.model, 'offline'].filter(Boolean).join(' · ')
          : 'no judge asked · rules only'}
        testId="run-spend-judge"
      />
      <Cell
        label="Total"
        title="Agent and judge together — what this run cost end to end"
        value={total != null ? fmtCost(total) : '—'}
        sub={agent && judge ? 'agent + judge' : agent ? 'agent only' : 'judge only'}
        testId="run-spend-total"
      />
    </Card>
  );
}
