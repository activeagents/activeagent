import React, { useEffect, useRef, useState } from 'react';
import { useTheme } from '../../../contexts/ThemeContext';
import { Badge, Empty, Glyph, Panel, PassBar, SegmentedBar, MONO, toneFor } from '../primitives';
import { META_COLUMN, MetaStrip } from '../TelemetryObject';
import { splitModelLabel, timeAgo } from '../../../utils/format';
import { fmtPasses, fmtScore, fmtSpend } from '../../../utils/evalFormat.mjs';
import {
  STRIP_LIST_HEIGHT, combinedBars, judgeCallsText, judgeLabel, judgeSourceText, passRate, plural, runCohorts, runDelta, runLabel,
  runNumber, runSandboxLabel, runSpend, runTotalOf, runsMeta, shownRunIndexes, versionChip, versionDelta,
} from '../../../utils/evaluationRuns.mjs';
import { useIsoLayoutEffect } from '../../../hooks/useMeasuredWidth';
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
// interaction lists keep (META_COLUMN), so the lists read alike. A scenario
// suite shows its runs as a side rail or a strip of cards instead (RunRail,
// below): the same rows, read narrow.

// A run's standing, as one badge: what it passed when it completed, else
// where it is. A fraction carries its percent; `short` drops the word
// "passed" where the row around it already says so (a rail row).
export function RunBadge({ run, testId, short = false }) {
  if (!run) return <Badge tone="muted" testId={testId}>no runs</Badge>;
  if (run.status === 'failed') return <Badge tone="error" testId={testId}>failed</Badge>;
  if (run.status === 'pending') return <Badge tone="warning" testId={testId}>queued</Badge>;
  if (run.status === 'running') return <Badge tone="warning" testId={testId}>running</Badge>;
  if (run.samples_evaluated) {
    const passes = fmtPasses(run.samples_passed || 0, run.samples_evaluated);
    return (
      <Badge tone={toneFor(passRate(run))} testId={testId} title={short ? `${passes} passed` : undefined}>
        {short ? passes : `${passes} passed`}
      </Badge>
    );
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

// The colors of a run's movement and of its version note, shared with the
// run header so the same figure reads the same everywhere.
export const DELTA_TONE = { success: 'var(--color-success)', error: 'var(--color-error)', muted: 'var(--color-text-muted)' };
export const VERSION_TONE = { same: 'var(--color-text-muted)', new: 'var(--color-info)', unrecorded: 'var(--color-warning-text)' };

// A cost cell carries its label and its estimate mark ("agent ~$0.0200"),
// so it is wider than the bare cost column a trace row keeps.
const COST_COLUMN = META_COLUMN.cost + 32;

// The bars a row shows by default: one per cohort the run recorded. A run
// that recorded nothing (it failed before it sampled) shows no bar rather
// than a "0/0".
const defaultBars = (run) => runCohorts(run)
  .filter((cohort) => cohort.samples > 0)
  .map((cohort) => ({ label: cohort.label, short: splitModelLabel(cohort.label || '').short || 'all samples', passed: cohort.passed, total: cohort.samples }));

// What a run covered, as one mono line: the agent, the scenarios × models,
// the judge — and, for a run against a checkout sandbox, which checkout,
// since its results are that checkout's, not the agent's own servers'.
const rowMeta = (run, evaluation, agentName) => [
  `@${agentName || evaluation?.agent?.name || 'agent'}`, runLabel(evaluation, run), judgeLabel(evaluation, run),
  runSandboxLabel(run) && `against ${runSandboxLabel(run)}`,
].filter(Boolean).join(' · ');

// A row per run, newest first: its number, the run before it (which the
// movement and the version change are read against), its bars and spend.
// Shared by the full list and the side rail, so both read a run alike.
export function runRows({
  runs = [], runCount = null, evaluation, agentName, selectedId = null, previousRun = null, barsFor = null, deltaFor = null,
}) {
  return runs.map((run, index) => {
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
      meta: rowMeta(run, evaluation, agentName),
      bars: barsFor ? barsFor(run) : defaultBars(run),
      delta,
      version,
      spend,
      selected: run.id === selectedId,
    };
  });
}

export default function RunsList({
  runs = [], runCount = null, evaluation, agentName, selectedId = null, onOpen, previousRun = null,
  barsFor = null, deltaFor = null, title = 'Runs', testId = 'suite-runs-panel',
}) {
  const { darkMode } = useTheme();
  const rows = runRows({ runs, runCount, evaluation, agentName, selectedId, previousRun, barsFor, deltaFor });

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

// ---------------------------------------------------------------------------
// RunRail — the same runs beside (or above) the run they select: a browser
// of runs, the way a CI page lists its builds next to the one open.
//
// Two layouts. 'rail' is a narrow column of every fetched run, scrolling on
// its own within `maxHeight` so the open run's steps stay beside it. 'strip'
// is the narrow-page form: the latest few runs (and the selected one, when
// older) as cards in one row, with a full-width "[+] n earlier runs" line
// that opens the whole list beneath. Both are built from the rows runRows
// makes (the panel passes them, so the rail and the run header read the
// same figures); a direct render may pass `runs` instead.
//
// Keyboard: one Tab stop per container — the selected row, else the first —
// and the arrow keys walk the rows, selecting the focused one once the keys
// pause, so holding ↓ scrolls through runs without fetching every one.

const ROW_SELECTOR = '[data-testid="evaluation-run"]';
// How long the arrow keys may pause before the focused run is selected.
const SELECT_DELAY = 150;

// The row element of a run inside `container`, by its id.
const rowElementOf = (container, id) =>
  (container && id != null ? container.querySelector(`[data-run-id="${CSS.escape(String(id))}"]`) : null);

// Scrolls `container` just enough to show `row`, by offset maths within
// the container: scrollIntoView would move the page too, and the page is
// where the person left it.
const reveal = (container, row, axis = 'y') => {
  if (!container || !row) return;
  if (axis === 'x') {
    const start = row.offsetLeft;
    if (start < container.scrollLeft || start + row.offsetWidth > container.scrollLeft + container.clientWidth) {
      container.scrollLeft = Math.max(start - 8, 0);
    }
    return;
  }
  const top = row.offsetTop;
  if (top < container.scrollTop || top > container.scrollTop + container.clientHeight - row.offsetHeight) {
    container.scrollTop = Math.max(top - 8, 0);
  }
};

// How far a running run has come, read off its bars: the results that
// passed, those that failed (when a bar counts them), and the rest still
// to land. Nothing until a bar has a total to count against.
const runProgress = (bars = []) => {
  const counted = bars.filter((bar) => bar.total != null);
  const sum = (field) => counted.reduce((total, bar) => total + (Number(bar[field]) || 0), 0);
  const total = sum('total');
  return total > 0 ? { passed: sum('passed'), failed: sum('failed'), total } : null;
};

// The deep-linked run, older than the page of runs the rail holds: its own
// number (show_run carries it), the bars the panel read for it, and no
// movement — the run before it is not loaded.
const linkedRow = (run, { evaluation, agentName, bars, selectedId }) => ({
  run,
  number: Number.isFinite(run.number) ? run.number : '?',
  latest: false,
  when: timeAgo(run.completed_at || run.created_at),
  meta: rowMeta(run, evaluation, agentName),
  bars: bars || [],
  delta: null,
  version: null,
  spend: runSpend(run),
  selected: run.id === selectedId,
});

const MUTED_LINE = { fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' };

// One bar of a rail row: a model's passes over its scenarios, or a dash
// when the run recorded no count for it. A combined bar (four models or
// more) names each model's count in its title.
function RailBar({ bar }) {
  const title = bar.title || undefined;
  if (bar.passed == null || bar.total == null) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }} title={title}>
        <span style={{ ...MUTED_LINE, width: 96, flexShrink: 0 }} title={bar.label || undefined}>{bar.short}</span>
        <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>—</span>
      </div>
    );
  }
  return (
    <div title={title}>
      <PassBar label={bar.short} labelWidth={96} passed={bar.passed} total={bar.total} height={4} valueWidth={44} />
    </div>
  );
}

// One run, as both layouts show it. Line 1: number · when · version chip ·
// standing. Then a bar per model (one combined bar past three), a running
// run's progress on a strip card, the error that stopped a failed run, the
// note the panel adds (a partial run's scope), and the movement against
// the run before with what the agent's side cost.
function RailRow({ row, selected = false, tabIndex = -1, card = false, onOpen, noteFor = null, style }) {
  const { run } = row;
  const note = noteFor ? noteFor(run) : null;
  const progress = card && run.status === 'running' ? runProgress(row.bars) : null;
  const open = () => onOpen?.(run);
  return (
    <div
      role="button"
      tabIndex={tabIndex}
      aria-current={selected ? 'true' : undefined}
      data-testid="evaluation-run"
      data-run-id={run.id}
      data-selected={selected ? 'true' : 'false'}
      onClick={open}
      onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } }}
      className={selected ? undefined : 'hover:bg-[var(--color-hover)]'}
      title={row.meta}
      style={{
        display: 'flex', flexDirection: 'column', gap: 5, padding: '9px 12px 9px 10px',
        borderTop: '1px solid var(--color-border-light)', cursor: 'pointer',
        background: selected ? 'var(--color-muted)' : undefined,
        borderLeft: `2px solid ${selected ? 'var(--color-accent-ui)' : 'transparent'}`,
        ...style,
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0 }}>
        <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 700, color: 'var(--color-text-primary)' }}>{`#${row.number}`}</span>
        <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{row.when}</span>
        <VersionChip run={run} />
        <span style={{ marginLeft: 'auto', flexShrink: 0 }}>
          <RunBadge run={run} short testId={row.latest ? 'suite-pass-badge' : undefined} />
        </span>
      </div>
      {combinedBars(row.bars).map((bar) => <RailBar key={bar.label || 'all'} bar={bar} />)}
      {progress && (
        <SegmentedBar
          parts={[{ value: progress.passed, tone: 'success' }, { value: progress.failed, tone: 'error' }]}
          total={progress.total}
          height={3}
          title={`${progress.passed} of ${progress.total} passed so far${progress.failed ? ` · ${progress.failed} failed` : ''}`}
          testId="evaluation-run-progress"
        />
      )}
      {run.status === 'failed' && run.error_message && (
        <div style={{ ...MUTED_LINE, color: 'var(--color-error)' }} title={run.error_message}>{`[!] ${run.error_message}`}</div>
      )}
      {note && <div data-testid="evaluation-run-note" style={MUTED_LINE} title={note}>{note}</div>}
      {(row.delta || row.spend?.agent?.cost != null) && (
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, fontFamily: MONO, fontSize: 10, minWidth: 0 }}>
          {row.delta && (
            <span style={{ fontWeight: 600, color: DELTA_TONE[row.delta.tone] || DELTA_TONE.muted, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }} title={row.version?.text}>{row.delta.text}</span>
          )}
          {row.spend?.agent?.cost != null && (
            <span style={{ marginLeft: 'auto', color: 'var(--color-text-muted)', whiteSpace: 'nowrap' }}>{fmtSpend(row.spend.agent.cost, { estimated: row.spend.agent.estimated })}</span>
          )}
        </div>
      )}
    </div>
  );
}

export function RunRail({
  rows = null, runs = [], runCount = null, evaluation, agentName, selectedId = null, onOpen, previousRun = null,
  barsFor = null, deltaFor = null, noteFor = null, linkedRun = null, linkedBars = null, layout = 'rail', limit = null,
  maxHeight = null, expandedHeight = STRIP_LIST_HEIGHT, testId = 'suite-runs-panel', style,
}) {
  const list = rows ?? runRows({ runs, runCount, evaluation, agentName, selectedId, previousRun, barsFor, deltaFor });
  // The runs the meta and the tail count: the ones given, else the rows'.
  const fetched = runs.length || !rows ? runs : rows.map((row) => row.run);
  const selectedRunId = selectedId ?? list.find((row) => row.selected)?.run.id ?? null;
  const isSelected = (row) => row.run.id === selectedRunId;
  const pinned = linkedRun && !list.some((row) => row.run.id === linkedRun.id)
    ? linkedRow(linkedRun, { evaluation, agentName, bars: linkedBars, selectedId: selectedRunId })
    : null;

  const strip = layout === 'strip';
  const shown = strip ? shownRunIndexes(list.map((row) => row.run), { limit, selectedId: selectedRunId }).map((index) => list[index]) : list;
  const cards = pinned ? [pinned, ...shown] : shown;
  const hidden = list.length - shown.length;
  const capped = strip && Number.isFinite(limit) && hidden > 0;
  const older = runTotalOf(fetched, runCount) - fetched.length;
  // The one Tab stop of each container: its selected row, else its first.
  const stopId = (cards.find(isSelected) || cards[0])?.run.id ?? null;
  const listStopId = (list.find(isSelected) || list[0])?.run.id ?? null;

  const [expanded, setExpanded] = useState(false);
  const listRef = useRef(null); // the rail's body, or the strip's opened list
  const stripRef = useRef(null); // the strip's row of cards
  const focusAfterFold = useRef(null);
  const selectTimer = useRef(null);
  useEffect(() => () => clearTimeout(selectTimer.current), []);
  // A strip that can no longer fold (every run fits) forgets it was opened.
  useEffect(() => { if (!capped) setExpanded(false); }, [capped]);

  const runById = new Map(cards.concat(list).map((row) => [String(row.run.id), row.run]));
  const selectLater = (run) => {
    clearTimeout(selectTimer.current);
    selectTimer.current = setTimeout(() => onOpen?.(run), SELECT_DELAY);
  };
  // The arrow keys walk the rows of a container in DOM order and Home/End
  // jump to its ends; the row that gains focus is selected once the keys
  // pause. Enter and Space are the row's own.
  const walk = (ref, { next, prev, axis }) => (event) => {
    const container = ref.current;
    const steps = container ? Array.from(container.querySelectorAll(ROW_SELECTOR)) : [];
    if (steps.length === 0) return;
    const from = event.target.closest(ROW_SELECTOR);
    const index = steps.indexOf(from);
    let target;
    if (event.key === next) target = steps[Math.min(index + 1, steps.length - 1)];
    else if (event.key === prev) target = steps[Math.max(index - 1, 0)];
    else if (event.key === 'Home') target = steps[0];
    else if (event.key === 'End') target = steps[steps.length - 1];
    else return;
    event.preventDefault();
    if (!target || target === from) return;
    target.focus({ preventScroll: true });
    reveal(container, target, axis);
    const run = runById.get(target.dataset.runId);
    if (run) selectLater(run);
  };

  // Choosing a run from the strip's opened list folds the list, which
  // unmounts the focused row; focus moves to that run's card so keyboard
  // use carries on from where it was.
  useIsoLayoutEffect(() => {
    if (expanded || focusAfterFold.current == null) return;
    const card = rowElementOf(stripRef.current, focusAfterFold.current);
    focusAfterFold.current = null;
    card?.focus({ preventScroll: true });
  }, [expanded]);

  // The selected run is brought into view within its own container — the
  // rail's body, the strip's row of cards, the opened list — never the page.
  useIsoLayoutEffect(() => {
    if (selectedRunId == null) return;
    reveal(stripRef.current, rowElementOf(stripRef.current, selectedRunId), 'x');
    reveal(listRef.current, rowElementOf(listRef.current, selectedRunId), 'y');
  }, [selectedRunId, layout, expanded]);

  // The runs beyond the fetched page: there by link, not by scrolling.
  const tail = older > 0 && (
    <div style={{ fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)', padding: '8px 12px', borderTop: '1px solid var(--color-border-light)' }}>
      {`${plural(older, 'older run')} · reachable by link`}
    </div>
  );

  if (!strip) {
    return (
      <Panel
        title="Runs"
        meta={runsMeta(fetched, runCount)}
        testId={testId}
        style={{ display: 'flex', flexDirection: 'column', maxHeight: maxHeight || undefined, ...style }}
        bodyStyle={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}
      >
        <div
          ref={listRef}
          onKeyDown={walk(listRef, { next: 'ArrowDown', prev: 'ArrowUp', axis: 'y' })}
          style={{ flex: 1, minHeight: 0, overflowY: 'auto', position: 'relative', scrollbarGutter: 'stable' }}
        >
          {pinned && (
            <>
              <div data-testid="runs-rail-linked" style={{ fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)', padding: '4px 12px', background: 'var(--color-muted)' }}>
                {`linked · older than the latest ${fetched.length}`}
              </div>
              <RailRow row={pinned} selected={isSelected(pinned)} tabIndex={stopId === pinned.run.id ? 0 : -1} onOpen={onOpen} noteFor={noteFor} />
            </>
          )}
          {!pinned && list.length === 0 && <Empty>[ ] no runs yet</Empty>}
          {list.map((row) => (
            <RailRow key={row.run.id} row={row} selected={isSelected(row)} tabIndex={stopId === row.run.id ? 0 : -1} onOpen={onOpen} noteFor={noteFor} />
          ))}
          {tail}
        </div>
      </Panel>
    );
  }

  return (
    <Panel title="Runs" meta={runsMeta(fetched, runCount)} testId={testId} style={style}>
      <div
        ref={stripRef}
        data-testid="run-strip"
        onKeyDown={walk(stripRef, { next: 'ArrowRight', prev: 'ArrowLeft', axis: 'x' })}
        style={{ display: 'flex', overflowX: 'auto', scrollbarGutter: 'stable', position: 'relative' }}
      >
        {cards.length === 0 && <Empty style={{ flex: 1 }}>[ ] no runs yet</Empty>}
        {cards.map((row, index) => (
          <RailRow
            key={row.run.id}
            row={row}
            card
            selected={isSelected(row)}
            tabIndex={stopId === row.run.id ? 0 : -1}
            onOpen={onOpen}
            noteFor={noteFor}
            style={{ flex: '1 1 0', minWidth: 200, borderTop: 'none', borderRight: index < cards.length - 1 ? '1px solid var(--color-border-light)' : 'none' }}
          />
        ))}
      </div>
      {capped && (
        <button
          type="button"
          data-testid="runs-rail-toggle"
          aria-expanded={expanded}
          onClick={() => setExpanded((value) => !value)}
          className="hover:bg-[var(--color-hover)]"
          style={{
            display: 'block', width: '100%', textAlign: 'left', padding: '6px 12px', border: 0, borderTop: '1px solid var(--color-border-light)',
            background: 'none', cursor: 'pointer', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)',
          }}
        >
          {expanded ? `[-] latest ${limit}` : `[+] ${plural(hidden, 'earlier run')}`}
        </button>
      )}
      {capped && expanded && (
        <div
          ref={listRef}
          onKeyDown={walk(listRef, { next: 'ArrowDown', prev: 'ArrowUp', axis: 'y' })}
          style={{ maxHeight: expandedHeight, overflowY: 'auto', position: 'relative', scrollbarGutter: 'stable' }}
        >
          {list.map((row) => (
            <RailRow
              key={row.run.id}
              row={row}
              selected={isSelected(row)}
              tabIndex={listStopId === row.run.id ? 0 : -1}
              noteFor={noteFor}
              onOpen={(run) => { focusAfterFold.current = run.id; setExpanded(false); onOpen?.(run); }}
            />
          ))}
          {tail}
        </div>
      )}
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
