import React, { useEffect, useState } from 'react';
import { useTheme } from '../../../contexts/ThemeContext';
import { Badge, Card, GLYPH, MonoLink, PassBar, SegmentedBar, MONO, TONE, toneFor } from '../primitives';
import { META_COLUMN, MetaStrip } from '../TelemetryObject';
import { dashboardPath, navigateTo } from '../../../utils/dashboardPath';
import { splitModelLabel, timeAgo } from '../../../utils/format';
import { fmtPasses } from '../../../utils/evalFormat.mjs';
import { fmtClock, fmtDuration, plural, runElapsedMs } from '../../../utils/evaluationRuns.mjs';
import { DELTA_TONE, RunBadge, VERSION_TONE, VersionChip } from './RunsList';
import CopyMarkdownButton from './CopyMarkdownButton';
import CopyLinkButton from './CopyLinkButton';
import { reportExports } from '../../../utils/reportExport.mjs';
import { AgentCostCell, JudgeCostCell, StatCell } from './SpendStrip';

// The selected run of a scenario suite, as the card at the top of its build
// page: which run (its number, when, the latest badge, the version it
// scored, what it covered, the links that lead off it) with its duration,
// movement and standing right-anchored in a MetaStrip; then five stat
// tiles — PASSED, MODELS, AGENT COST, JUDGE COST, TO FIX — in the cells the
// sampling run page's SpendStrip is built from, so the two pages read a
// run's figures alike; then a thin progress bar while the run goes, or the
// run's own failure line when it ended before replaying.
//
// Pure apart from its clock: every figure comes in as a prop the panel
// derived (the summary while the run's results are still being fetched,
// the landed results once they are), every action goes out as a callback.
// The 1 Hz tick that moves the duration cell lives here so only this card
// re-renders once a second, not the toolbar, the rail and a hundred
// memoised rows. Nothing without a run.

const MUTED = 'var(--color-text-muted)';

// How many model bars the MODELS tile shows before it says "+n more".
const HEADER_BARS_MAX = 3;

const NO_TOTALS = { passed: 0, total: 0 };
const NO_FIXES = { items: 0, faults: 0, scenarios: 0 };
const NO_RERUN = { keys: [], dropped: [] };

const mono = (size, color, extra = {}) => ({ fontFamily: MONO, fontSize: size, color, ...extra });

// A link's href resolves against the engine's mount, which lives on window;
// a render without one (a static render outside the harness) keeps '#'.
const hrefFor = (path) => (typeof window === 'undefined' ? '#' : dashboardPath(path));

// `now`, once a second while `active`. Effects never run in a static
// render, so there the value is the render's own time and no interval
// exists; in a browser the first tick re-reads the clock at once, so a
// running run selected after the card sat idle does not open on a stale
// second.
const useNow = (active) => {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return undefined;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [active]);
  return now;
};

// A model's line when its bar has no counts yet (a run that recorded no
// summary for it): the label and a dash, where the bar would be.
function DashBar({ short, label }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <span style={mono(10, MUTED, { width: 110, flexShrink: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' })} title={label || undefined}>{short}</span>
      <span style={mono(11, MUTED)}>—</span>
    </div>
  );
}

// `run` is the selected run (its summary, or its detail with results);
// `runNumber`, `delta`, `version` and `bars` are the run's row from
// runRows (null delta/version for a linked run outside the page);
// `latestNumber` is the suite's latest run number and `isLatest` whether
// this is it; `runningElsewhere` is the latest run when it is going and is
// not the shown one. `totals`, `settledCount`, `settledFailed` and
// `expectedResults` are the panel's counts over the run's results (or its
// summary); `running` is inProgress(run) and `loading` whether the run's
// results are still being fetched. `spend` is runSpend(run); `fixSummary`
// is { items, faults, scenarios }; `rerun` is rerunFailedKeys' { keys,
// dropped }. Callbacks: onSelectLatest, onWatchLatest, onJumpToFix,
// onRerunFailed, onRunAgain.
export default function RunHeader({
  run, runNumber = null, latestNumber = null, isLatest = false, runningElsewhere = null,
  agentName = 'agent', scenarioCount = 0, groupCount = 0, columns = [], judgedBy = 'rules', bars = [],
  delta = null, version = null, totals = NO_TOTALS, settledCount = 0, settledFailed = 0, expectedResults = 0,
  running = false, loading = false, spend = null, fixSummary = NO_FIXES, selectionLabel = null, sandboxLabel = null,
  reportPath = null, rerun = NO_RERUN, evaluationId = null,
  onSelectLatest, onWatchLatest, onJumpToFix, onRerunFailed, onRunAgain,
}) {
  const { darkMode } = useTheme();
  const now = useNow(running);
  if (!run) return null;
  const reportFiles = reportExports(reportPath);

  const failed = run.status === 'failed';
  const complete = run.status === 'complete';
  const when = running ? `started ${timeAgo(run.created_at)}` : timeAgo(run.completed_at || run.created_at);
  const meta = `@${agentName} · ${plural(scenarioCount, 'scenario')}${groupCount ? ` in ${plural(groupCount, 'group')}` : ''}`
    + ` × ${plural(columns.length, 'model')} · judged by ${judgedBy}${sandboxLabel ? ` · against ${sandboxLabel}` : ''}`;

  // --- line 1: the links -------------------------------------------------

  const rerunKeys = rerun?.keys || [];
  const rerunDropped = rerun?.dropped || [];
  const rerunCount = rerunDropped.length ? `${rerunKeys.length} of ${rerunKeys.length + rerunDropped.length}` : `${rerunKeys.length}`;
  const rerunTitle = 'Replay every scenario that failed on any model, under the models in the picker'
    + (rerunDropped.length ? ` · not replayed (disabled or removed): ${rerunDropped.join(', ')}` : '');

  // --- line 1: the MetaStrip ---------------------------------------------

  const elapsed = runElapsedMs(run, now);
  const cells = [
    {
      key: 'duration',
      width: META_COLUMN.duration,
      content: elapsed != null && <span style={mono(11)}>{running ? fmtClock(elapsed) : fmtDuration(elapsed)}</span>,
      title: run.usage?.runtime_ms != null ? 'Wall clock, as the run recorded it' : "From the run's start to its end",
      empty: 'Duration is read once the run starts',
    },
    {
      key: 'delta',
      width: 136,
      content: delta && (
        <span style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
          <span style={mono(11, DELTA_TONE[delta.tone] || DELTA_TONE.muted, { fontWeight: 600 })}>{delta.text}</span>
          {version && (
            <span data-testid="run-version-delta" style={mono(10, VERSION_TONE[version.kind] || VERSION_TONE.same)}>{version.text}</span>
          )}
        </span>
      ),
      title: 'Samples passed, against the run before',
      empty: complete && !delta ? 'Movement is read against the run before, which is not loaded' : 'Movement is read once the run completes',
    },
    // No fixed width: the badge's own text sets the column. A 132px column
    // clipped "162/200 · 81% passed" at the card's edge, and a four-model
    // run reads longer still; nothing below has to line up with it.
    { key: 'badge', content: <RunBadge run={run} testId="suite-run-badge" /> },
  ];

  // --- line 2: the tiles -------------------------------------------------

  const counts = totals || NO_TOTALS;
  const ratio = counts.total > 0 ? counts.passed / counts.total : null;
  const passed = failed
    ? { value: '—', valueColor: MUTED, sub: settledCount ? `${settledCount} of ${expectedResults} before it failed` : 'run failed' }
    : running
      ? {
        value: `${counts.passed} passed`,
        sub: <span data-testid="suite-run-progress">{`${settledCount} of ${expectedResults} results in${settledFailed ? ` · ${settledFailed} failed` : ''}`}</span>,
      }
      : {
        value: fmtPasses(counts.passed, counts.total),
        valueColor: ratio == null ? MUTED : TONE[toneFor(ratio)].text,
        sub: `${Math.max(counts.total - counts.passed, 0)} failed · ${plural(scenarioCount, 'scenario')} × ${plural(columns.length, 'model')}`,
      };

  // The bars sit where a tile's figure goes; the figure's 18px/700 is reset
  // so the bars keep their own 10px labels and 11px counts.
  const shownBars = bars.slice(0, HEADER_BARS_MAX);
  const models = (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 5, fontWeight: 400, lineHeight: 'normal' }}>
      {bars.length === 0 && columns.length === 0 && <span style={mono(11, MUTED)}>—</span>}
      {bars.length === 0 && columns.map((label) => <DashBar key={label} short={splitModelLabel(label).short} label={label} />)}
      {shownBars.map((bar) => (
        bar.passed == null || bar.total == null
          ? <DashBar key={bar.label || 'all'} short={bar.short} label={bar.label} />
          : <PassBar key={bar.label || 'all'} label={bar.short} labelWidth={110} passed={bar.passed} total={bar.total} height={4} valueWidth={48} />
      ))}
    </div>
  );
  const moreBars = bars.length > HEADER_BARS_MAX
    ? <span style={mono(10, MUTED)}>{`+${bars.length - HEADER_BARS_MAX} more`}</span>
    : undefined;

  const fix = fixSummary || NO_FIXES;
  const fixes = failed
    ? { value: '—', valueColor: MUTED, sub: '—' }
    : loading
      ? { value: '…', valueColor: MUTED, sub: 'loading…' }
      : running
        ? { value: '…', valueColor: MUTED, sub: 'scoring…' }
        : fix.items > 0
          ? {
            value: fix.items,
            valueColor: TONE.error.text,
            sub: <span style={{ color: 'var(--color-info)' }}>{`${plural(fix.faults, 'fault')} across ${plural(fix.scenarios, 'scenario')} ${GLYPH.link}`}</span>,
          }
          : { value: '0', valueColor: MUTED, sub: 'nothing to fix' };

  const jumpToFix = () => onJumpToFix?.();
  const jumpOnKey = (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      jumpToFix();
    }
  };
  // TO FIX is a button while there is a What to fix to go to; a failed run
  // renders none, so its tile is a plain figure, not a Tab stop to nowhere.
  const fixControl = failed ? {} : { role: 'button', tabIndex: 0, onClick: jumpToFix, onKeyDown: jumpOnKey, style: { cursor: 'pointer' } };
  const fixTitle = `The faults this run found, grouped into fixes${failed ? '' : ' — opens What to fix'}`;

  return (
    <Card padding={0} testId="suite-run-header" style={{ overflow: 'hidden' }}>
      {/* Line 1: identity, the links off this run, and its figures at the right. */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', padding: '10px 16px', borderBottom: '1px solid var(--color-border-light)' }}>
        <span style={mono(13, 'var(--color-text-primary)', { fontWeight: 700 })}>{`Run #${runNumber ?? '?'}`}</span>
        <span style={mono(11, MUTED, { whiteSpace: 'nowrap' })}>{when}</span>
        {isLatest && <Badge tone="info" size={10} style={{ padding: '1px 6px' }}>latest</Badge>}
        <VersionChip run={run} />
        <span style={mono(11, MUTED, { minWidth: 0, textWrap: 'pretty' })}>{meta}</span>
        {selectionLabel && (
          <Badge tone="muted" size={10} style={{ padding: '1px 6px' }} testId="suite-run-selection">{selectionLabel}</Badge>
        )}
        {!isLatest && (
          <MonoLink onClick={() => onSelectLatest?.()} title="Show the suite's latest run" testId="suite-latest-run">
            {`latest${latestNumber != null ? ` #${latestNumber}` : ''}`}
          </MonoLink>
        )}
        {runningElsewhere && (
          <MonoLink onClick={() => onWatchLatest?.()} title="A newer run is going; show it as it replays" testId="suite-watch-latest">
            {`#${runningElsewhere.number ?? latestNumber ?? '?'} is running · watch`}
          </MonoLink>
        )}
        {complete && !loading && rerunKeys.length > 0 && (
          <MonoLink onClick={() => onRerunFailed?.()} title={rerunTitle} testId="suite-rerun-failed">
            {`re-run failed (${rerunCount})`}
          </MonoLink>
        )}
        {failed && (
          <MonoLink onClick={() => onRunAgain?.()} title="Replay what this run was asked to, under the models in the picker" testId="suite-run-again">
            run again
          </MonoLink>
        )}
        <CopyLinkButton
          evaluationId={evaluationId}
          runId={run.id}
          label="copy link"
          testId="suite-run-copy-link"
          title="Copy a link that opens this run, for a teammate in your organization"
          style={{ padding: '0 4px', fontFamily: MONO, fontSize: 11 }}
        />
        {reportPath && (
          <MonoLink href={hrefFor(reportPath)} onClick={() => navigateTo(reportPath)} title="The run rendered as a report page" testId="suite-run-report">
            run report
          </MonoLink>
        )}
        {reportFiles && (
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }} data-testid="suite-run-exports">
            <span style={{ fontFamily: MONO, fontSize: 11, color: MUTED }}>download</span>
            <MonoLink href={hrefFor(reportFiles.html)} title="The report as one self-contained HTML page" testId="suite-run-download-html">html</MonoLink>
            <MonoLink href={hrefFor(reportFiles.json)} title="The run as the evaluation report envelope another install imports" testId="suite-run-download-json">json</MonoLink>
            <MonoLink href={hrefFor(reportFiles.md)} title="The report as GitHub-flavored Markdown" testId="suite-run-download-md">markdown</MonoLink>
            <CopyMarkdownButton url={hrefFor(reportFiles.markdown)} label="copy markdown" testId="suite-run-copy-markdown"
              title="Copy the whole report as GitHub-flavored Markdown" style={{ padding: '0 4px', fontFamily: MONO, fontSize: 11 }} />
          </span>
        )}
        <span style={{ marginLeft: 'auto' }}>
          <MetaStrip darkMode={darkMode} cells={cells} />
        </span>
      </div>

      {/* Line 2: the five tiles (their own borders are the grid's seams, on
          every row the grid wraps them to). */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
        <StatCell
          label="Passed"
          title="Results that passed, over every scenario × model the run covers"
          testId="suite-run-passed"
          {...passed}
        />
        <StatCell
          label="Models"
          title="Each model's passed scenarios — counted from the results that have landed while the run goes"
          testId="suite-run-models"
          value={models}
          sub={moreBars}
        />
        <AgentCostCell spend={spend} pending={running} failed={failed} />
        <JudgeCostCell spend={spend} judgedBy={judgedBy} pending={running} failed={failed} />
        <StatCell label="To fix" title={fixTitle} testId="suite-to-fix" {...fixControl} {...fixes} />
      </div>

      {/* Line 3: how far the run is, or why it stopped. */}
      {running && expectedResults > 0 && (
        <SegmentedBar
          parts={[{ value: settledCount - settledFailed, tone: 'success' }, { value: settledFailed, tone: 'error' }]}
          total={expectedResults}
          height={4}
          radius={0}
          role="progressbar"
          aria-label="Results in"
          aria-valuemin={0}
          aria-valuemax={expectedResults}
          aria-valuenow={settledCount}
          aria-valuetext={`${settledCount} of ${expectedResults} results in${settledFailed ? `, ${settledFailed} failed` : ''}`}
          testId="suite-run-progress-bar"
        />
      )}
      {failed && (
        <div data-testid="suite-run-error" style={{ padding: '8px 16px', background: 'var(--color-error-soft)', color: 'var(--color-error-text)', fontSize: 13 }}>
          {`[!] ${run.error_message || 'unknown error'}`}
        </div>
      )}
    </Card>
  );
}
