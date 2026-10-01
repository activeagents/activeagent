import React from 'react';
import { useTheme } from '../../../contexts/ThemeContext';
import { Badge, Empty, Glyph, Panel, PassBar, MONO, toneFor } from '../primitives';
import { META_COLUMN, MetaStrip } from '../TelemetryObject';
import { splitModelLabel, timeAgo } from '../../../utils/format';
import { fmtPasses, fmtScore, fmtSpend } from '../../../utils/evalFormat.mjs';
import {
  judgeCallsText, judgeLabel, judgeSourceText, passRate, plural, runCohorts, runDelta, runLabel, runNumber, runSandboxLabel,
  runSpend, runsMeta, versionChip, versionDelta,
} from '../../../utils/evaluationRuns.mjs';
import { agentUnit, fmtRate } from './SpendStrip';

// Every run of an evaluation, newest first, one row each: which run and
// when, which version of the agent it scored, what it covered, how each
// model cohort did, what it cost — the agent's side and the judge's, each
// marked "~" when estimated — and how it moved against the run before,
// saying whether that run scored the same version of the agent. The same
// list serves a scenario suite (where a row selects the run the panels
// below show) and a sampling evaluation (where a row opens the run).
//
// The right-hand figures sit in a MetaStrip so a column holds its place on
// every row — a failed run has no cost and no movement, and its badge must
// still line up under its neighbours'. Its cells are the ones the trace and
// interaction lists keep (META_COLUMN), so the lists read alike.

// A run's standing, as one badge: what it passed when it completed, else
// where it is. A fraction carries its percent.
export function RunBadge({ run, testId }) {
  if (!run) return <Badge tone="muted" testId={testId}>no runs</Badge>;
  if (run.status === 'failed') return <Badge tone="error" testId={testId}>failed</Badge>;
  if (run.status === 'pending') return <Badge tone="warning" testId={testId}>queued</Badge>;
  if (run.status === 'running') return <Badge tone="warning" testId={testId}>running</Badge>;
  if (run.samples_evaluated) {
    return <Badge tone={toneFor(passRate(run))} testId={testId}>{`${fmtPasses(run.samples_passed || 0, run.samples_evaluated)} passed`}</Badge>;
  }
  if (run.average_score != null) {
    const score = Number(run.average_score);
    return <Badge tone={score >= 0.85 ? 'success' : score >= 0.7 ? 'warning' : 'error'} testId={testId} title="mean score across criteria">{`score ${fmtScore(score)}`}</Badge>;
  }
  return <Badge tone="muted" testId={testId}>no samples</Badge>;
}

// Which version of the agent a run scored, as a small chip; nothing for a
// run the API did not describe.
export function VersionChip({ run, testId = 'run-version' }) {
  const chip = versionChip(run);
  if (!chip) return null;
  return <Badge tone={chip.tone} size={10} style={{ padding: '1px 6px' }} title={chip.title} testId={testId}>{chip.text}</Badge>;
}

const DELTA_TONE = { success: 'var(--color-success)', error: 'var(--color-error)', muted: 'var(--color-text-muted)' };
const VERSION_TONE = { same: 'var(--color-text-muted)', new: 'var(--color-info)', unrecorded: 'var(--color-warning-text)' };

// A cost cell carries its label and its estimate mark ("agent ~$0.0200"),
// so it is wider than the bare cost column a trace row keeps.
const COST_COLUMN = META_COLUMN.cost + 32;

// The bars a row shows by default: one per cohort the run recorded. A run
// that recorded nothing (it failed before it sampled) shows no bar rather
// than a "0/0".
const defaultBars = (run) => runCohorts(run)
  .filter((cohort) => cohort.samples > 0)
  .map((cohort) => ({ label: cohort.label, short: splitModelLabel(cohort.label || '').short || 'all samples', passed: cohort.passed, total: cohort.samples }));

export default function RunsList({
  runs = [], runCount = null, evaluation, agentName, selectedId = null, onOpen, previousRun = null,
  barsFor = null, deltaFor = null, title = 'Runs', testId = 'suite-runs-panel',
}) {
  const { darkMode } = useTheme();
  const rows = runs.map((run, index) => {
    const number = runNumber(run, index, runs, runCount);
    // The run before this one: the next in the list, or — when the list is
    // only the latest run — the summary the index payload carried for it.
    const older = runs[index + 1] || (index === 0 && runs.length === 1 ? previousRun : null);
    const olderNumber = older ? (Number.isFinite(older.number) ? older.number : number - 1) : null;
    const delta = deltaFor ? deltaFor(run, older, olderNumber) : runDelta(run, older, { olderNumber });
    const version = delta && older ? versionDelta(run, older) : null;
    const spend = runSpend(run);
    return {
      run,
      number,
      latest: index === 0,
      when: timeAgo(run.completed_at || run.created_at),
      // A run against a checkout sandbox says which: its results are that
      // checkout's, not the agent's own servers'.
      meta: [
        `@${agentName || evaluation?.agent?.name || 'agent'}`, runLabel(evaluation, run), judgeLabel(evaluation, run),
        runSandboxLabel(run) && `against ${runSandboxLabel(run)}`,
      ].filter(Boolean).join(' · '),
      bars: barsFor ? barsFor(run) : defaultBars(run),
      delta,
      version,
      spend,
      selected: run.id === selectedId,
    };
  });

  return (
    <Panel title={title} meta={runsMeta(runs, runCount)} testId={testId} bodyStyle={{ overflowX: 'auto' }}>
      {rows.length === 0 && <Empty>[ ] no runs yet</Empty>}
      <div style={{ minWidth: 920 }}>
        {rows.map((row) => (
          <div
            key={row.run.id}
            role="button"
            tabIndex={0}
            data-testid="evaluation-run"
            data-run-id={row.run.id}
            data-selected={row.selected ? 'true' : 'false'}
            onClick={() => onOpen?.(row.run)}
            onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onOpen?.(row.run); } }}
            className={row.selected ? undefined : 'hover:bg-[var(--color-hover)]'}
            style={{
              display: 'grid', gridTemplateColumns: 'minmax(220px, 1.4fr) minmax(180px, 1fr) auto', gap: 16, alignItems: 'center',
              padding: '10px 14px 10px 12px', borderTop: '1px solid var(--color-border-light)', cursor: 'pointer',
              background: row.selected ? 'var(--color-muted)' : undefined,
              borderLeft: `2px solid ${row.selected ? 'var(--color-accent-ui)' : 'transparent'}`,
            }}
          >
            <div style={{ minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 700, color: 'var(--color-text-primary)' }}>{`Run #${row.number}`}</span>
                <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{row.when}</span>
                {row.latest && <Badge tone="info" size={10} style={{ padding: '1px 6px' }}>latest</Badge>}
                {row.run.status === 'failed' && <Badge tone="error" size={10} style={{ padding: '1px 6px' }}>failed</Badge>}
                {(row.run.status === 'running' || row.run.status === 'pending') && (
                  <Badge tone="warning" size={10} style={{ padding: '1px 6px' }}>{row.run.status === 'pending' ? 'queued' : 'running'}</Badge>
                )}
                <VersionChip run={row.run} />
              </div>
              <div style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)', marginTop: 3, textWrap: 'pretty' }}>{row.meta}</div>
              {row.run.status === 'failed' && row.run.error_message && (
                <div style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-error)', marginTop: 3, textWrap: 'pretty' }}>{`[!] ${row.run.error_message}`}</div>
              )}
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
              {row.bars.map((bar) => (
                bar.passed == null || bar.total == null ? (
                  <div key={bar.label || 'all'} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <span style={{ fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)', width: 128, flexShrink: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }} title={bar.label || undefined}>{bar.short}</span>
                    <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>—</span>
                  </div>
                ) : (
                  <PassBar key={bar.label || 'all'} label={bar.short} passed={bar.passed} total={bar.total} />
                )
              ))}
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <MetaStrip
                darkMode={darkMode}
                cells={[
                  {
                    key: 'agent',
                    width: COST_COLUMN,
                    title: row.spend?.agent
                      ? `Agent: ${plural(row.spend.agent.count, agentUnit(row.spend))}${row.spend.agent.perInteraction != null ? ` · ${fmtRate(row.spend.agent.perInteraction, row.spend.agent.estimated)} per interaction` : ''}${row.spend.agent.estimated ? ' · ~ estimated from tokens × model rates' : ''}`
                      : undefined,
                    empty: 'Agent cost: nothing replayed or sampled in this run',
                    content: row.spend?.agent?.cost != null && (
                      <span style={{ fontFamily: MONO, fontSize: 11 }}>
                        <span style={{ color: 'var(--color-text-muted)' }}>agent </span>{fmtSpend(row.spend.agent.cost, { estimated: row.spend.agent.estimated })}
                      </span>
                    ),
                  },
                  {
                    key: 'judge',
                    width: COST_COLUMN,
                    title: row.spend?.judge
                      ? `Judge: ${plural(row.spend.judge.calls, 'call')}${judgeCallsText(row.spend.judge) ? ` · ${judgeCallsText(row.spend.judge)}` : ''}${judgeSourceText(row.spend.judge) ? ` · ${judgeSourceText(row.spend.judge)}` : ''} · offline`
                      : undefined,
                    empty: 'Judge cost: no judge was asked in this run',
                    content: row.spend?.judge?.cost != null && (
                      <span style={{ fontFamily: MONO, fontSize: 11 }}><span style={{ color: 'var(--color-text-muted)' }}>judge </span>{fmtSpend(row.spend.judge.cost, { estimated: row.spend.judge.estimated })}</span>
                    ),
                  },
                  {
                    key: 'delta',
                    width: 136,
                    title: row.delta ? `Samples passed, against the run before${row.version ? ` · ${row.version.text}` : ''}` : undefined,
                    empty: 'Movement is read once the run completes',
                    content: row.delta && (
                      <span style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                        <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, color: DELTA_TONE[row.delta.tone] || DELTA_TONE.muted }}>{row.delta.text}</span>
                        {row.version && (
                          <span data-testid="run-version-delta" style={{ fontFamily: MONO, fontSize: 10, color: VERSION_TONE[row.version.kind] || VERSION_TONE.same }}>{row.version.text}</span>
                        )}
                      </span>
                    ),
                  },
                  { key: 'badge', width: 132, content: <RunBadge run={row.run} testId={row.latest ? 'suite-pass-badge' : undefined} /> },
                  { key: 'open', width: 20, content: <Glyph kind="link" color="var(--color-info)" weight={400} /> },
                ]}
              />
            </div>
          </div>
        ))}
      </div>
    </Panel>
  );
}

// The line above a suite's runs: `3 runs · latest #3 12 min ago · 14/20 · 70% passed`.
export const runsSummary = (runs = [], runCount = null) => {
  const latest = runs[0];
  const total = Number.isFinite(runCount) ? Math.max(runCount, runs.length) : runs.length;
  return [
    plural(total, 'run'),
    latest ? `latest #${runNumber(latest, 0, runs, runCount)} ${timeAgo(latest.completed_at || latest.created_at)}` : null,
    latest?.status === 'complete' && latest.samples_evaluated ? `${fmtPasses(latest.samples_passed || 0, latest.samples_evaluated)} passed` : null,
  ].filter(Boolean).join(' · ');
};
