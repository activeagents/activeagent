import React, { useState } from 'react';
import { Badge, Button, Card, Chip, Empty, Glyph, MicroLabel, MONO, TONE } from '../primitives';
import { navigateTo } from '../../../utils/dashboardPath';
import { fmtMs, fmtScore, splitModelLabel, timeAgo } from '../../../utils/format';
import {
  CRITERION_GROUPS, PASS_THRESHOLD, cellStats, criterionEntries, criterionExpectation, criterionGroup, criterionLabel,
  findCriterion, modelScorecard, plural, runCohorts, runLabel, runModels, runNumber, runSpend,
  samplingFixItems, truncate,
} from '../../../utils/evaluationRuns.mjs';
import ModelScorecard from './ModelScorecard';
import SpendStrip from './SpendStrip';
import CriteriaFooter from './CriteriaFooter';

// One run of a sampling evaluation, opened from its runs list: what it cost
// (the agent's side apart from the judge's), a scorecard per model cohort,
// the judge's verdict when there was one, the criteria × models matrix, and
// the follow-ups the run's own data asks for. A scenario suite's runs open
// in the suite panel instead, where the scenario matrix lives.

const linkStyle = { background: 'none', border: 'none', padding: 0, cursor: 'pointer', fontFamily: MONO, fontSize: 12, color: 'var(--color-info)' };
const mono = (size = 11, color = 'var(--color-text-muted)', extra = {}) => ({ fontFamily: MONO, fontSize: size, color, ...extra });

function ScoreCell({ stats }) {
  if (!stats) return <span style={mono()}>—</span>;
  if (stats.skipped) {
    return (
      <div>
        <span style={mono(12, 'var(--color-text-cell)', { fontWeight: 700 })}>[-] skipped</span>
        <div style={{ ...mono(), marginTop: 2, textWrap: 'pretty' }} title={stats.reason}>{truncate(stats.reason, 90)}</div>
      </div>
    );
  }
  const score = Number(stats.score);
  const color = TONE[score >= 0.85 ? 'success' : score >= PASS_THRESHOLD ? 'warning' : 'error'].strong;
  const parts = [];
  if (stats.total != null) parts.push(`${stats.passed}/${stats.total} passed`);
  if (stats.total > 1 && stats.min != null) parts.push(`min ${fmtScore(stats.min)} · max ${fmtScore(stats.max)}`);
  if (stats.source === 'telemetry') {
    parts.push(`${stats.traces} traces · ${stats.window_hours}h`);
    const observed = stats.observed || {};
    if (observed.error_rate != null) parts.push(`observed ${observed.error_rate}% errors (${observed.errors})`);
    if (observed.avg_duration_ms != null) parts.push(`observed avg ${fmtMs(observed.avg_duration_ms)}`);
  }
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span style={mono(12, color, { fontWeight: 700 })}>{score >= PASS_THRESHOLD ? '[+]' : '[!]'} {fmtScore(score)}</span>
        {stats.source === 'telemetry' && (
          <span
            data-testid="score-source-telemetry"
            title="Aggregate over the agent's telemetry traces"
            style={mono(10, 'var(--color-text-muted)', { textTransform: 'uppercase', letterSpacing: '0.04em' })}
          >
            telemetry
          </span>
        )}
      </div>
      <div style={{ ...mono(), marginTop: 2, textWrap: 'pretty' }}>{parts.join(' · ')}</div>
    </div>
  );
}

function FixCard({ item }) {
  return (
    <div
      data-testid="fix-item"
      style={{ border: '1px solid var(--color-border)', borderRadius: 10, padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: 10, minWidth: 0 }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <Glyph kind="fault" />
        <Badge tone="error">{item.label}</Badge>
        <span style={mono()}>{item.scope}</span>
      </div>
      <div style={{ fontSize: 13, lineHeight: '19px', color: 'var(--color-text-cell)', textWrap: 'pretty' }}>{item.text}</div>
      {item.chips?.length > 0 && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <MicroLabel size={10} color="var(--color-text-muted)">{item.chipsLabel}</MicroLabel>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {item.chips.map((chip) => (
              <span key={chip} style={{ fontFamily: MONO, fontSize: 11, padding: '3px 8px', borderRadius: 6, border: '1px solid var(--color-border)', color: 'var(--color-text-primary)', fontWeight: 600 }}>{chip}</span>
            ))}
          </div>
        </div>
      )}
      {item.details?.length > 0 && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
          {item.details.map((detail) => (
            <span key={detail} style={mono(11, 'var(--color-text-cell)', { textWrap: 'pretty' })}>{detail}</span>
          ))}
        </div>
      )}
      {item.action && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 'auto' }}>
          {item.action.path && <Button size="sm" onClick={() => navigateTo(item.action.path)}>{item.action.label}</Button>}
          {item.action.hint && <span style={{ ...mono(), whiteSpace: 'nowrap' }}>{item.action.hint}</span>}
        </div>
      )}
    </div>
  );
}

export default function EvaluationRunDetail({
  evaluation, runs = [], runCount = null, runId, loading = false, running = false,
  onSelectRun, onRun, onBack, onOpenEvaluation, onDelete, deleting = false,
}) {
  const [group, setGroup] = useState('all');
  const [failedOnly, setFailedOnly] = useState(false);

  const crumb = (label, onClick) => <button type="button" onClick={onClick} style={linkStyle}>{label}</button>;
  const runIndex = runs.findIndex((candidate) => candidate.id === runId);
  const run = runIndex >= 0 ? runs[runIndex] : runs[0];
  const number = run ? runNumber(run, Math.max(runIndex, 0), runs, runCount) : null;

  const breadcrumb = (
    <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
      {crumb('Evaluations', onBack)}
      <span style={mono(12)}>/</span>
      {crumb(evaluation?.name || 'Evaluation', onOpenEvaluation)}
      <span style={mono(12)}>/</span>
      <span style={mono(12, 'var(--color-text-primary)', { fontWeight: 700 })}>{run ? `Run #${number}` : 'Runs'}</span>
    </div>
  );

  if (!evaluation) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div>{crumb('Evaluations', onBack)}</div>
        <Card><span style={{ fontSize: 13, color: 'var(--color-text-muted)' }}>This evaluation is not in the list any more.</span></Card>
      </div>
    );
  }

  if (!run) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        {breadcrumb}
        {loading ? (
          <div className="flex items-center justify-center h-64">
            <div className="animate-spin rounded-full h-8 w-8 border-b-2" style={{ borderBottomColor: 'var(--color-accent-ui)' }} />
          </div>
        ) : (
          <Card><span style={{ fontSize: 13, color: 'var(--color-text-muted)' }}>No runs recorded yet.</span></Card>
        )}
      </div>
    );
  }

  const models = runModels(run);
  const columns = models.length ? models : [null];
  const cohorts = runCohorts(run);
  const cohortFor = (model) => cohorts.find((cohort) => cohort.label === model) || (model == null ? cohorts[0] : null);
  const verdict = run.scores?._verdict;
  const missing = Array.isArray(run.scores?._missing_models) ? run.scores._missing_models : [];
  const entries = criterionEntries(run).map(([key, value]) => ({ key, value, criterion: findCriterion(evaluation, key) }));
  const countIn = (groupId) => entries.filter((entry) => criterionGroup(entry.criterion) === groupId).length;
  const presentGroups = CRITERION_GROUPS.filter((candidate) => countIn(candidate.id) > 0);
  const failing = (entry) => columns.some((model) => {
    const stats = cellStats(entry.value, model);
    return stats && (stats.skipped || (stats.score != null && stats.score < PASS_THRESHOLD));
  });
  const visible = entries.filter((entry) =>
    (group === 'all' || criterionGroup(entry.criterion) === group) && (!failedOnly || failing(entry)));
  const sections = CRITERION_GROUPS
    .map((candidate) => ({ ...candidate, rows: visible.filter((entry) => criterionGroup(entry.criterion) === candidate.id) }))
    .filter((candidate) => candidate.rows.length);
  const items = samplingFixItems(evaluation, { ...run, number });
  const spend = runSpend(run);
  const when = timeAgo(run.completed_at || run.created_at);
  const passedLabel = run.status === 'complete' && run.samples_evaluated ? ` · ${run.samples_passed || 0}/${run.samples_evaluated} passed` : '';

  const th = { fontFamily: MONO, fontSize: 10, fontWeight: 600, letterSpacing: '0.05em', textTransform: 'uppercase', color: 'var(--color-text-muted)', padding: '8px 12px', textAlign: 'left', verticalAlign: 'top', whiteSpace: 'nowrap' };
  const td = { padding: '10px 12px', verticalAlign: 'top' };
  const groupTd = { padding: '7px 12px', verticalAlign: 'middle' };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }} data-testid="evaluation-run-detail">
      {breadcrumb}

      {/* Title row: which run, what it covered, and the run switcher. */}
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ minWidth: 0 }}>
          <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>{`Run #${number}`}</h1>
          <p style={{ margin: '4px 0 0', fontSize: 14, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>
            {`${evaluation.name} · ${when} · @${evaluation.agent?.name || 'agent'} · ${runLabel(evaluation, run)}${passedLabel}`}
          </p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
          {runs.map((candidate, index) => (
            <Chip
              key={candidate.id}
              square
              mono
              selected={candidate.id === run.id}
              onClick={() => onSelectRun?.(candidate)}
              title={`${candidate.status} · ${timeAgo(candidate.completed_at || candidate.created_at)}`}
            >
              {`#${runNumber(candidate, index, runs, runCount)}`}
            </Chip>
          ))}
          <Button variant="primary" disabled={running} onClick={onRun} testId="run-again-button">{running ? 'Running…' : 'Run again'}</Button>
        </div>
      </div>

      {/* What the run cost, the agent's side apart from the judge's. */}
      <SpendStrip spend={spend} />

      {/* One scorecard per model cohort; a failed run has nothing to score. */}
      {run.status === 'failed' ? (
        <Card data-testid="run-failed" style={{ borderColor: 'var(--color-error)' }} padding="14px 16px">
          <span style={mono(12, 'var(--color-error)', { fontWeight: 700 })}>[!] run failed</span>
          <div style={{ fontSize: 13, color: 'var(--color-text-cell)', marginTop: 6, lineHeight: '19px' }}>{run.error_message}</div>
        </Card>
      ) : run.status !== 'complete' ? (
        <Card data-testid="run-pending" padding="14px 16px">
          <span style={mono(12, 'var(--color-warning-text)', { fontWeight: 700 })}>{`[~] ${run.status}`}</span>
          <div style={{ fontSize: 13, color: 'var(--color-text-cell)', marginTop: 6 }}>Scores appear once the run completes.</div>
        </Card>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 12 }}>
          {columns.map((model) => {
            const card = modelScorecard(run, model);
            const cohort = cohortFor(model);
            const samples = cohort?.samples ?? (model == null ? run.samples_evaluated : null);
            const passed = cohort?.passed ?? (model == null ? run.samples_passed : null);
            const badges = [];
            if (card.below > 0) badges.push({ tone: 'error', text: `below pass mark ×${card.below}` });
            if (card.skipped > 0) badges.push({ tone: 'warning', text: `skipped ×${card.skipped}` });
            return (
              <ModelScorecard
                key={model || 'all'}
                label={model}
                short={model ? splitModelLabel(model).short : 'all samples'}
                provider={cohort?.provider || (model ? splitModelLabel(model).provider : null) || null}
                winner={!!verdict?.winner && verdict.winner === model}
                passed={passed}
                total={samples}
                avgScore={card.avg}
                criteria={{ cleared: card.cleared, scored: card.scored }}
                latencyMs={cohort?.avg_duration_ms}
                inputTokens={cohort?.input_tokens}
                outputTokens={cohort?.output_tokens}
                cost={cohort?.cost}
                perInteraction={cohort?.cost != null && samples ? cohort.cost / samples : null}
                unit="interaction"
                badges={badges}
              />
            );
          })}
        </div>
      )}

      {(verdict || missing.length > 0) && (
        <Card padding="12px 16px" style={{ display: 'flex', flexDirection: 'column', gap: 6 }} data-testid="run-verdict">
          {verdict && (
            <>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <MicroLabel>Verdict</MicroLabel>
                {verdict.judge && <span style={mono()}>{`judged by ${verdict.judge}`}</span>}
              </div>
              <div style={{ fontSize: 13, lineHeight: '19px', color: 'var(--color-text-cell)', textWrap: 'pretty' }}>
                <strong style={{ color: 'var(--color-text-primary)', fontFamily: MONO, fontSize: 12 }}>{verdict.winner}</strong>
                {verdict.rationale ? ` · ${verdict.rationale}` : ''}
              </div>
            </>
          )}
          {missing.length > 0 && (
            <span style={mono(11, 'var(--color-warning-text)', { fontWeight: 600 })}>{`[!] no generations recorded under ${missing.join(', ')}`}</span>
          )}
        </Card>
      )}

      {/* Criteria × models. */}
      <Card padding={0} style={{ overflow: 'hidden' }} testId="criteria-matrix">
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '10px 14px', flexWrap: 'wrap' }}>
          <MicroLabel style={{ marginRight: 4 }}>Criteria</MicroLabel>
          <Chip selected={group === 'all'} onClick={() => setGroup('all')}>{`All ${entries.length}`}</Chip>
          {presentGroups.map((candidate) => (
            <Chip key={candidate.id} selected={group === candidate.id} onClick={() => setGroup(candidate.id)}>
              {`${candidate.label} ${countIn(candidate.id)}`}
            </Chip>
          ))}
          <Chip square mono selected={failedOnly} onClick={() => setFailedOnly((value) => !value)} style={{ marginLeft: 'auto', background: 'transparent' }} title="Hide criteria every model cleared">
            {failedOnly ? '[x] failed only' : '[ ] failed only'}
          </Chip>
        </div>
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse' }}>
            <thead>
              <tr style={{ background: 'var(--color-muted)' }}>
                <th style={{ ...th, width: '34%' }}>Criterion</th>
                <th style={th}>Expects</th>
                {columns.map((model) => (
                  <th key={model || 'score'} style={th}>
                    {model ? (
                      <>
                        <span style={{ color: 'var(--color-text-primary)', textTransform: 'none', letterSpacing: 0, fontSize: 12 }}>{splitModelLabel(model).short}</span>
                        {(cohortFor(model)?.provider || splitModelLabel(model).provider) && (
                          <span style={{ display: 'block', fontWeight: 400, textTransform: 'none', letterSpacing: 0 }}>{cohortFor(model)?.provider || splitModelLabel(model).provider}</span>
                        )}
                      </>
                    ) : 'Score'}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {sections.map((section) => (
                <React.Fragment key={section.id}>
                  <tr style={{ background: 'var(--color-background)', borderTop: '1px solid var(--color-border-light)' }}>
                    <td style={groupTd}><span style={{ fontWeight: 600, fontSize: 13, color: 'var(--color-text-primary)' }}>{section.label}</span></td>
                    <td style={groupTd}><span style={mono()}>{`${section.rows.length} ${section.rows.length === 1 ? 'criterion' : 'criteria'}`}</span></td>
                    {columns.map((model) => {
                      const scored = section.rows.filter((entry) => { const stats = cellStats(entry.value, model); return stats && stats.score != null; });
                      const cleared = scored.filter((entry) => cellStats(entry.value, model).score >= PASS_THRESHOLD).length;
                      const color = scored.length && cleared === scored.length ? 'var(--color-success-text)' : cleared === 0 && scored.length ? 'var(--color-error-text)' : 'var(--color-text-cell)';
                      return (
                        <td key={model || 'score'} style={groupTd}>
                          <span style={mono(11, color, { fontWeight: 600 })}>{`${cleared}/${scored.length} passed`}</span>
                        </td>
                      );
                    })}
                  </tr>
                  {section.rows.map((entry) => (
                    <tr key={entry.key} data-testid="criterion-row" style={{ borderTop: '1px solid var(--color-border-light)' }}>
                      <td style={td}>
                        <div style={mono()}>{entry.key}</div>
                        <div style={{ fontSize: 13, color: 'var(--color-text-primary)' }}>{criterionLabel(entry.criterion)}</div>
                      </td>
                      <td style={td}>
                        <span style={{ fontFamily: MONO, fontSize: 11, padding: '2px 6px', border: '1px solid var(--color-border)', borderRadius: 4, color: 'var(--color-text-cell)', whiteSpace: 'nowrap' }} title={criterionExpectation(entry.criterion)}>
                          {truncate(criterionExpectation(entry.criterion), 40)}
                        </span>
                      </td>
                      {columns.map((model) => (
                        <td key={model || 'score'} style={td}><ScoreCell stats={cellStats(entry.value, model)} /></td>
                      ))}
                    </tr>
                  ))}
                </React.Fragment>
              ))}
              {sections.length === 0 && (
                <tr style={{ borderTop: '1px solid var(--color-border-light)' }}>
                  <td colSpan={2 + columns.length} style={{ padding: '16px 14px', fontSize: 13, color: 'var(--color-text-muted)' }}>
                    {entries.length ? 'Nothing failed under this filter.' : 'This run recorded no criterion scores.'}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>

      {/* What the run's own data asks for next. */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
          <MicroLabel>What to fix</MicroLabel>
          <span style={mono()}>{items.length ? plural(items.length, 'item') : 'nothing'}</span>
        </div>
        {items.length ? (
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 12 }}>
            {items.map((item) => <FixCard key={item.kind} item={item} />)}
          </div>
        ) : (
          <Empty style={{ border: '1px solid var(--color-border-light)', borderRadius: 10, padding: '14px 12px', color: 'var(--color-success-text)' }}>
            {`[+] Every criterion cleared the ${PASS_THRESHOLD.toFixed(2)} pass mark and nothing was skipped.`}
          </Empty>
        )}
      </div>

      <CriteriaFooter evaluation={evaluation} run={run} spend={spend} onDelete={onDelete} deleting={deleting} />
    </div>
  );
}
