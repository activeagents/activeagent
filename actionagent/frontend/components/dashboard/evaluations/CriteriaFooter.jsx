import React from 'react';
import { MonoLink, MONO } from '../primitives';
import { dashboardPath, navigateTo } from '../../../utils/dashboardPath';
import { criterionExpectation, criterionGroup, criterionLabel, findCriterion, judgeLabel } from '../../../utils/evaluationRuns.mjs';
import { spendText } from './SpendStrip';

// The evaluation's standing configuration, as mono lines under its runs: who
// judges, which criteria, what the shown run cost (agent apart from judge),
// the API call that runs it again, a link to the run's report page, and the
// delete control. Telemetry and judge criteria carry a source tag because
// they are scored from different data than the sampled generations.
//
// `keys` names the criteria to list — a scenario run scores keys the
// evaluation never declared (expected_tools, task_completion) — defaulting
// to the evaluation's own.
export default function CriteriaFooter({ evaluation, run = null, keys = null, spend = null, reportPath = null, onDelete, deleting = false, deleteLabel = 'Delete evaluation' }) {
  const criteria = (keys || (evaluation.criteria || []).map((criterion) => criterion.key)).map((key) => findCriterion(evaluation, key));
  const muted = { fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' };
  const cell = { fontFamily: MONO, fontSize: 11, color: 'var(--color-text-cell)' };
  const sourceTag = (text, testId, title) => (
    <span data-testid={testId} title={title} style={{ ...muted, fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.04em', marginLeft: 2 }}>{text}</span>
  );
  const usage = spendText(spend);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, paddingTop: 12, borderTop: '1px solid var(--color-border-light)' }} data-testid="criteria-footer">
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap', rowGap: 4 }}>
        <span style={muted}>judge</span>
        <span style={{ ...cell, fontWeight: 600 }}>{judgeLabel(evaluation, run)}</span>
        <span style={{ ...muted, marginLeft: 8 }}>criteria</span>
        {criteria.length === 0 && (
          <span style={muted}>{evaluation.judge_kind === 'judge_defined' ? 'defined by the judge on the first run' : evaluation.scenario_suite ? "each scenario's own expectations" : '—'}</span>
        )}
        {criteria.map((criterion, index) => (
          <React.Fragment key={criterion.key || index}>
            {index > 0 && <span style={muted}>·</span>}
            <span style={cell} title={criterionExpectation(criterion) || undefined}>{criterionLabel(criterion)}</span>
            {criterionGroup(criterion) === 'telemetry' &&
              sourceTag('telemetry', 'score-source-telemetry', "Scored from the agent's telemetry traces, not from sampled generations")}
            {criterionGroup(criterion) === 'judge' &&
              sourceTag('judge', undefined, 'Scored by the judge model; needs provider credentials')}
          </React.Fragment>
        ))}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, flexWrap: 'wrap', rowGap: 4 }}>
        <span style={{ ...muted, whiteSpace: 'nowrap' }} title="Run this evaluation again from the API">POST /api/evaluations/{evaluation.id}/run</span>
        {usage && (
          <span style={{ ...muted, minWidth: 0, textWrap: 'pretty' }} title="Estimated spend of this run: the agent's replays or sampled interactions, and the judge's own calls">
            {usage}
          </span>
        )}
        {reportPath && (
          <MonoLink href={dashboardPath(reportPath)} onClick={() => navigateTo(reportPath)} title="The run rendered as a report page">run report</MonoLink>
        )}
        {onDelete && (
          <button
            type="button"
            onClick={(event) => { event.stopPropagation(); onDelete(); }}
            disabled={deleting}
            title="Delete this evaluation and its runs"
            style={{ marginLeft: 'auto', background: 'transparent', border: 'none', padding: 0, cursor: deleting ? 'not-allowed' : 'pointer', fontFamily: MONO, fontSize: 11, color: 'var(--color-error)', opacity: deleting ? 0.5 : 1 }}
          >
            {deleting ? 'Deleting…' : deleteLabel}
          </button>
        )}
      </div>
    </div>
  );
}
