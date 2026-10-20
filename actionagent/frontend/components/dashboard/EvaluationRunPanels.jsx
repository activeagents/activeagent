import React, { useCallback, useRef, useState } from 'react';
import { Badge, Button, Card, Chip, Empty, Glyph, MicroLabel, MonoLink, MONO, PassBar } from './primitives';
import { fmtK, fmtMs, fmtTokenIO, splitModelLabel } from '../../utils/format';
import { COST_LEGEND, costTitle, fmtPasses, fmtScore, fmtSpend } from '../../utils/evalFormat.mjs';
import {
  RUNS_PAGE, columnTotals, costPer, cursorScrollTop, fixItemCountsByModel, fixItemsForModel, fmtSpan, groupStep, groupTime, isEstimated,
  modelComparisonRows, openRowScrollTop, plural, pricedCount, resultMetrics, runScenarioKeys, runSpend, runTotalOf, runnableKeys, runsMeta,
  scenarioStep, scenarioTime, scenarioTokens, selectionModelLabels, selectionOf, stepsMinWidth, sumTokens, toolsMinWidth, withModelBreakdown,
} from '../../utils/evaluationRuns.mjs';
import { useIsoLayoutEffect } from '../../hooks/useMeasuredWidth';
import ModelScorecard from './evaluations/ModelScorecard';
import ModelComparisonTable from './evaluations/ModelComparisonTable';
import CopyFixPromptButton, { dashboardUrl } from './evaluations/CopyFixPromptButton';
import ImplementFixButton from './evaluations/ImplementFixButton';
import ReplayLink from './replay/ReplayLink';
import { fixPromptMarkdown } from '../../utils/fixPrompt.mjs';

// The panels a scenario suite's expanded body is built from — Models, the
// step box (the scenario × model matrix read like a build's steps) and a
// scenario's drill-down, What to fix — plus the derivations they share. The
// runs rail is evaluations/RunsList, shared with the sampling evaluations;
// the run's header card is evaluations/RunHeader. Everything here is
// presentational: state, fetching and mutations live in ScenarioSuitePanel.

// The run-history helpers and a run's selection readers moved to the shared
// vocabulary module; re-exported so their existing importers keep working.
export { RUNS_PAGE, plural, runScenarioKeys, runTotalOf, runsMeta, selectionModelLabels, selectionOf };

// ---------------------------------------------------------------------------
// Derivations

const uniq = (list) => [...new Set(list)];

// A scenario's expectation field as a list: older imports persisted a lone
// value ({ contains: "30" }) where the parser now writes an array.
const expectList = (scenario, field) => {
  const value = scenario?.expectations?.[field];
  return Array.isArray(value) ? value : value == null || value === '' ? [] : [value];
};

// The fault taxonomy renders lower-case with spaces: expected_tool_not_called
// → "expected tool not called".
export const faultName = (fault) => String(fault || '').replace(/_/g, ' ');

export const isPassed = (result) => result?.status === 'passed';
export const isSettled = (result) => !!result && result.status !== 'pending';
export const inProgress = (run) => !!run && ['pending', 'running'].includes(run.status);

// The model columns of a run, in the order they were requested.
export function modelColumns(run, results = [], evaluation = null) {
  if (Array.isArray(run?.models) && run.models.length) return run.models;
  const fromScores = Object.keys(run?.scores?._models || {});
  if (fromScores.length) return fromScores;
  const fromSelection = selectionModelLabels(run);
  if (fromSelection.length) return fromSelection;
  const fromResults = uniq(results.map((r) => labelForResult(run, r)));
  if (fromResults.length) return fromResults;
  const compare = evaluation?.compare_models || [];
  if (compare.length) return compare;
  return run ? ["agent's model"] : [];
}

// Which column a result belongs to: the label the user typed, matched
// through the run's resolved selection; older runs fall back to the names
// the report keyed its summaries by.
export function labelForResult(run, result) {
  const specs = (selectionOf(run).models || []).filter((m) => m && typeof m === 'object');
  const spec = specs.find((m) => m.model === result.model && (m.provider || '') === (result.provider || ''));
  if (spec?.label) return spec.label;
  const known = run?.scores?._models || {};
  if (known[result.model]) return result.model;
  const joined = [result.provider, result.model].filter(Boolean).join('/');
  if (known[joined]) return joined;
  return result.model;
}

// { short, provider } for a column label.
export function describeModel(run, label) {
  const stats = run?.scores?._models?.[label];
  const spec = (selectionOf(run).models || []).find((m) => m && typeof m === 'object' && m.label === label);
  return splitModelLabel(label, stats?.provider || spec?.provider || '');
}

export function runScenarioCount(run, columns = [], scenarios = []) {
  const keys = runScenarioKeys(run, scenarios);
  if (keys.length) return keys.length;
  const stats = Object.values(run?.scores?._models || {});
  if (stats.length) return Math.max(...stats.map((s) => s.scenarios || 0));
  if (run?.samples_evaluated && columns.length) return Math.round(run.samples_evaluated / columns.length);
  return 0;
}

// Passed / failed / total for one model of a run — from the run's summary
// once it is complete, otherwise counted from the results that have landed.
// `failed` is what settled without passing (a running run's progress bar
// draws it red; the summary's is the scenarios that did not pass).
export function modelPassStats(run, label, results = [], scenarioCount = 0) {
  const stats = run?.scores?._models?.[label];
  if (stats && stats.scenarios != null) {
    const passed = stats.passed || 0;
    const total = stats.scenarios || 0;
    return { passed, failed: Math.max(total - passed, 0), total };
  }
  const mine = results.filter((r) => labelForResult(run, r) === label);
  return {
    passed: mine.filter(isPassed).length,
    failed: mine.filter((r) => isSettled(r) && !isPassed(r)).length,
    total: scenarioCount || mine.length,
  };
}

// The bars a run's rail row, header tile and box header draw: one per model
// column — its passes over its scenarios, from the run's summary once it is
// complete, else counted from `results` (the shown run's landed results; a
// run that is not shown has none loaded, so its bars read from its summary
// alone). A model the run recorded nothing for and is not replaying — it
// failed before it reached that model — gets null counts, which every bar
// draws as a dash: a `0/100` there would say two hundred replays all failed
// when none ran.
export function runBars(run, results = [], evaluation = null, scenarios = []) {
  const columns = modelColumns(run, results, evaluation);
  const count = runScenarioCount(run, columns, scenarios);
  return columns.map((label) => {
    const bar = { label, short: splitModelLabel(label).short };
    const counted = run?.scores?._models?.[label]?.scenarios != null
      || inProgress(run)
      || results.some((r) => labelForResult(run, r) === label);
    return counted ? { ...bar, ...modelPassStats(run, label, results, count) } : { ...bar, passed: null, failed: null, total: null };
  });
}

// Passed / total scenario runs (scenario × model) of a run.
export function runTotals(run, results = [], columns = [], scenarios = []) {
  if (run?.status === 'complete' && run.samples_evaluated != null) {
    return { passed: run.samples_passed || 0, total: run.samples_evaluated || 0 };
  }
  const total = runScenarioCount(run, columns, scenarios) * Math.max(columns.length, 1);
  return { passed: results.filter(isPassed).length, total };
}

// Tool calls collapsed by name, in first-call order, with the coloring the
// matrix and drill-down share: a call that matches an expected tool reads
// success, an errored call reads error with " ✗" (and " ×k" for repeats),
// anything else muted.
export function callList(toolCalls, expects = []) {
  const order = [];
  const byName = {};
  (Array.isArray(toolCalls) ? toolCalls : []).forEach((call) => {
    const name = typeof call === 'string' ? call : String(call?.name || '');
    if (!name) return;
    if (!byName[name]) {
      byName[name] = { name, count: 0, errored: false };
      order.push(name);
    }
    byName[name].count += 1;
    if (call && typeof call === 'object' && call.error) byName[name].errored = true;
  });
  return order.map((name) => {
    const entry = byName[name];
    const hit = expects.includes(name);
    return {
      ...entry,
      hit,
      label: `${name}${entry.errored ? ' ✗' : ''}${entry.count > 1 ? ` ×${entry.count}` : ''}`,
      color: entry.errored ? 'var(--color-error)' : hit ? 'var(--color-success-text)' : 'var(--color-text-muted)',
      weight: entry.errored || hit ? 600 : 400,
    };
  });
}

const truncate = (text, max) => {
  const value = String(text || '').trim();
  return value.length > max ? `${value.slice(0, max - 1)}…` : value;
};

// What to fix, from the API's `fix_items` when the run carries them, else
// rebuilt from the run's `_recommendations` and the results' diagnoses in the
// same shape (without server resolution, which only the backend can do).
// An empty `fix_items` is only trusted when there is nothing to rebuild
// from: show_run answers `[]` when the report cannot build them for an
// older run, and such a run still carries the recommendations it persisted.
const instructionChangeOf = (result) => result?.diagnosis?.judge?.instruction_change;

export function fixItemsFor(run, results = []) {
  const recommendations = run?.scores?._recommendations || [];
  if (Array.isArray(run?.fix_items)) {
    const rebuildable = recommendations.length > 0 || results.some(instructionChangeOf);
    if (run.fix_items.length > 0 || !rebuildable) return run.fix_items;
  }
  const items = recommendations.map((entry) => fallbackFixItem(entry, results));

  const seen = new Set();
  results.forEach((result) => {
    const change = instructionChangeOf(result);
    if (!change || seen.has(change)) return;
    seen.add(change);
    const peers = results.filter((r) => instructionChangeOf(r) === change);
    items.push({
      kind: 'instruction',
      fault: 'instruction change',
      count: peers.length,
      scenario_keys: uniq(peers.map((r) => r.scenario_key)),
      models: uniq(peers.map((r) => labelForResult(run, r))),
      recommendation: result.diagnosis.judge.recommendation || result.recommendation || '',
      quote: change,
      tools_label: null,
      tools: [],
      server: null,
      note: null,
      action: { label: 'Add to instructions', hint: 'Agent -> Instructions', path: null },
    });
  });
  return items;
}

function fallbackFixItem(entry, results) {
  const fault = entry.fault;
  const faulted = results.filter((r) => r.fault === fault);
  const suggested = (entry.suggested_tools || [])
    .map((tool) => (typeof tool === 'string' ? tool : tool?.name))
    .filter(Boolean);
  let toolsLabel = null;
  let tools = [];
  let note = null;
  let action = null;

  if (fault === 'expected_tool_not_called') {
    toolsLabel = 'missing tools';
    let names = uniq(faulted.flatMap((r) => r.diagnosis?.evidence?.unavailable || []));
    if (!names.length) {
      names = uniq(faulted.flatMap((r) => {
        const evidence = r.diagnosis?.evidence || {};
        return (evidence.expected || []).filter((name) => !(evidence.called || []).includes(name));
      }));
    }
    tools = names.map((name) => ({ name, note: null, server: null }));
    const exceptions = faulted.filter((r) => r.diagnosis?.summary && (r.diagnosis?.evidence?.unavailable || []).length === 0);
    if (exceptions.length && exceptions.length < faulted.length) {
      note = exceptions
        .map((r) => `${r.scenario_key} is the exception: ${r.diagnosis.summary} ${r.diagnosis.recommendation || ''}`.trim())
        .join(' ');
    }
  } else if (fault === 'tool_error') {
    toolsLabel = 'failing tools';
    const failing = {};
    faulted.forEach((r) => (r.tool_calls || []).forEach((call) => {
      if (!call || typeof call !== 'object' || !call.error || !call.name || failing[call.name]) return;
      failing[call.name] = { name: call.name, note: truncate(call.detail, 60) || null, server: null };
    }));
    tools = Object.values(failing);
    action = { label: 'Open failing tools', hint: 'Tools ->', path: '/tools' };
  } else {
    toolsLabel = suggested.length ? 'suggested tools' : null;
    tools = uniq(suggested).map((name) => ({ name, note: null, server: null }));
  }
  if (!action && toolsLabel === 'suggested tools' && tools.length) {
    action = { label: 'Open suggested tools', hint: 'Tools ->', path: '/tools' };
  }

  return {
    kind: 'fault',
    fault,
    count: entry.count || faulted.length,
    scenario_keys: entry.scenario_keys || uniq(faulted.map((r) => r.scenario_key)),
    models: entry.models || [],
    recommendation: entry.recommendation || '',
    quote: null,
    tools_label: toolsLabel,
    tools,
    server: null,
    note,
    action,
  };
}

// ---------------------------------------------------------------------------
// Costs
//
// Every result carries its effective cost and how it was priced
// (`cost_source`: reported, estimated, no_usage or unpriced), its rate when
// estimated (`cost_rate`), and what the judge spent on it (`judge_usage`).
// A figure with an estimated part reads "~".

export const resultEstimated = (result) => result?.cost_source === 'estimated';
export const resultJudgeEstimated = (result) => {
  const usage = result?.judge_usage;
  if (!usage) return false;
  return usage.estimated ?? (usage.source != null && usage.source !== 'reported');
};

// "~$0.0243 · judge ~$0.0015" — what one answer cost and what judging it
// cost; null for a result with no cost on either side.
export const resultCostText = (result) => {
  if (!result) return null;
  const judgeCost = result.judge_usage?.cost ?? null;
  if (result.cost == null && judgeCost == null) return null;
  const parts = [fmtSpend(result.cost, { estimated: resultEstimated(result) })];
  if (judgeCost != null) parts.push(`judge ${fmtSpend(judgeCost, { estimated: resultJudgeEstimated(result) })}`);
  return parts.join(' · ');
};

// The tooltip of a result's cost: the working behind an estimate, with the
// tokens and the rate the API applied.
export const resultCostTitle = (result) => {
  if (!resultEstimated(result)) return undefined;
  const rate = result.cost_rate || null;
  return costTitle({
    inputTokens: rate?.input_tokens ?? result.input_tokens,
    outputTokens: rate?.output_tokens ?? result.output_tokens,
    rate,
  });
};

// What a scenario cost across every model: the API's `costs.scenarios[key]`
// when the run carries it, else summed from the scenario's results —
// `{ cost, judgeCost, total, estimated }`, or null with nothing priced.
export const scenarioCost = (run, key, results = {}) => {
  const recorded = run?.costs?.scenarios?.[key];
  if (recorded && typeof recorded === 'object') {
    if (recorded.cost == null && recorded.judge_cost == null) return null;
    return { cost: recorded.cost ?? null, judgeCost: recorded.judge_cost ?? null, total: recorded.total ?? null, estimated: !!recorded.estimated };
  }
  const settled = Object.values(results || {}).filter(isSettled);
  const costs = settled.map((result) => result.cost).filter((cost) => cost != null);
  const judgeCosts = settled.map((result) => result.judge_usage?.cost).filter((cost) => cost != null);
  if (!costs.length && !judgeCosts.length) return null;
  const cost = costs.length ? costs.reduce((sum, value) => sum + Number(value), 0) : null;
  const judgeCost = judgeCosts.length ? judgeCosts.reduce((sum, value) => sum + Number(value), 0) : null;
  return {
    cost,
    judgeCost,
    total: (cost || 0) + (judgeCost || 0),
    estimated: settled.some((result) => resultEstimated(result) || resultJudgeEstimated(result)) || (costs.length > 0 && costs.length < settled.length),
  };
};

// Several scenarios' costs together (a group's subtotal), the same shape.
export const sumScenarioCosts = (entries = []) => {
  const present = entries.filter(Boolean);
  if (!present.length) return null;
  const costs = present.filter((entry) => entry.cost != null);
  const judges = present.filter((entry) => entry.judgeCost != null);
  const cost = costs.length ? costs.reduce((sum, entry) => sum + entry.cost, 0) : null;
  const judgeCost = judges.length ? judges.reduce((sum, entry) => sum + entry.judgeCost, 0) : null;
  return { cost, judgeCost, total: (cost || 0) + (judgeCost || 0), estimated: present.some((entry) => entry.estimated) };
};

// A cost cell: the agent's figure over the judge's, or — `compact`, the
// steps level's one line — the total, with the two shares in its title.
// A scenario's, or a group's, COST cell. `tokens` — `{ input, output }`
// added up across the models — sits under the figure, so the spend reads
// beside what drove it.
function CostBlock({ entry, compact = false, testId, tokens = null }) {
  const column = { display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0, textAlign: 'right' };
  const tokenLine = tokens && (tokens.input != null || tokens.output != null) ? (
    <span data-testid={testId ? `${testId}-tokens` : undefined} title="input→output tokens across the models" style={{ ...mono(10.5), whiteSpace: 'nowrap' }}>
      {fmtTokenIO(tokens.input, tokens.output)}
    </span>
  ) : null;
  if (!entry) {
    return (
      <span style={column} data-testid={testId}>
        <span style={mono(12)}>—</span>
        {tokenLine}
      </span>
    );
  }
  if (compact) {
    const total = entry.total ?? (entry.cost != null || entry.judgeCost != null ? (entry.cost || 0) + (entry.judgeCost || 0) : null);
    const shares = [];
    if (entry.cost != null) shares.push(`agent ${fmtSpend(entry.cost, { estimated: entry.estimated })}`);
    if (entry.judgeCost != null) shares.push(`judge ${fmtSpend(entry.judgeCost, { estimated: entry.estimated })}`);
    return (
      <span style={column} data-testid={testId}>
        <span
          title={shares.join(' · ') || undefined}
          style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, color: 'var(--color-text-primary)', whiteSpace: 'nowrap' }}
        >
          {fmtSpend(total, { estimated: entry.estimated })}
        </span>
        {tokenLine}
      </span>
    );
  }
  return (
    <span style={{ ...column, fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)' }} data-testid={testId}>
      <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{fmtSpend(entry.cost, { estimated: entry.estimated })}</span>
      {entry.judgeCost != null && <span style={{ color: 'var(--color-text-muted)', whiteSpace: 'nowrap' }}>{`judge ${fmtSpend(entry.judgeCost, { estimated: entry.estimated })}`}</span>}
      {tokenLine}
    </span>
  );
}

// ---------------------------------------------------------------------------
// Small shared pieces

const mono = (size, color = 'var(--color-text-muted)', extra = {}) => ({ fontFamily: MONO, fontSize: size, color, ...extra });

function CallLine({ calls, empty, style }) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: '2px 8px', fontFamily: MONO, fontSize: 11, ...style }}>
      {calls.map((call) => (
        <span key={call.name} style={{ color: call.color, fontWeight: call.weight }}>{call.label}</span>
      ))}
      {calls.length === 0 && <span style={{ color: 'var(--color-text-muted)' }}>{empty}</span>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// MODELS

// One scorecard per model cohort of the selected run — passes, score,
// latency, tokens and what the replays cost under it — then the judge's
// verdict when the run compared cohorts. A model's card carries the agent's
// spend only; the judge's is the run's (see RunsList and CriteriaFooter).
export function ModelsPanel({ run, columns, results = [], scenarioCount = 0, judgedBy, verdict }) {
  const summaries = run?.scores?._models || {};
  const judgeEstimated = runSpend(run)?.judge?.estimated ?? true;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }} data-testid="suite-models-panel">
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
        <MicroLabel>Models</MicroLabel>
        {judgedBy && <span style={mono(11)}>{`judged by ${judgedBy}`}</span>}
      </div>
      {columns.length === 0 && (
        <Empty style={{ border: '1px solid var(--color-border-light)', borderRadius: 10 }}>[ ] no models scored yet</Empty>
      )}
      {/* Read across first: one row per model, best first. */}
      {columns.length > 1 && (
        <ModelComparisonTable
          rows={modelComparisonRows(run, { results, scenarioCount, columns, labelFor: (result) => labelForResult(run, result) })}
          unit="scenario"
          judgedBy={judgedBy}
          judgeEstimated={judgeEstimated}
        />
      )}
      {columns.length > 0 && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 12 }}>
          {columns.map((label) => {
            const { short, provider } = describeModel(run, label);
            const stats = summaries[label];
            const { passed, total } = modelPassStats(run, label, results, scenarioCount);
            const faults = Object.entries(stats?.faults || {});
            const priced = pricedCount(stats, stats?.scenarios);
            const note = stats && faults.length === 0
              ? { text: '[+] no faults', color: 'var(--color-success-text)' }
              : !stats && inProgress(run) ? { text: 'scoring…' } : null;
            return (
              <ModelScorecard
                key={label}
                label={label}
                short={short}
                provider={provider}
                winner={verdict?.winner === label}
                passed={passed}
                total={total}
                avgScore={stats?.avg_score}
                latencyMs={stats?.avg_duration_ms}
                inputTokens={stats?.input_tokens}
                outputTokens={stats?.output_tokens}
                cost={stats?.cost}
                perInteraction={costPer(stats?.cost, priced)}
                estimated={isEstimated(stats, stats?.scenarios)}
                judgeCost={stats?.judge_cost}
                judgeCalls={stats?.judge_calls || 0}
                judgeEstimated={judgeEstimated}
                unit="scenario"
                badges={faults.map(([fault, count]) => ({ tone: 'error', text: `${faultName(fault)} ×${count}` }))}
                note={note}
              />
            );
          })}
        </div>
      )}
      {verdict?.rationale && (
        <Card padding="12px 16px" testId="suite-verdict" style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
            <MicroLabel>Verdict</MicroLabel>
            {verdict.judge && <span style={mono(11)}>{`judged by ${verdict.judge}`}</span>}
          </div>
          <div style={{ fontSize: 13, lineHeight: '19px', color: 'var(--color-text-cell)', textWrap: 'pretty' }}>
            <strong style={{ color: 'var(--color-text-primary)', fontFamily: MONO, fontSize: 12 }}>{verdict.winner}</strong>
            {verdict.rationale ? ` · ${verdict.rationale}` : ''}
          </div>
        </Card>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// SCENARIOS — the step box

// The box's grid at each detail level for `n` model columns. `steps` is one
// line a scenario — glyph · key · prompt · a cell per model · cost · time;
// `tools` is the fuller row — the two-line scenario, EXPECTS, three-line
// result cells with their tool calls and cost. stepsMinWidth / toolsMinWidth
// are what these add up to, so the box scrolls sideways inside itself
// rather than squeezing a column.
const gridFor = (level, n) => (level === 'tools'
  ? ['minmax(220px, 1.6fr)', '130px', ...Array(n).fill('minmax(160px, 1fr)'), '110px'].join(' ')
  : ['minmax(200px, 1.6fr)', ...Array(n).fill('minmax(130px, 1fr)'), '80px', '48px'].join(' '));

const GRID_GAP = { tools: 10, steps: 8 };

const EMPTY_LIST = [];
const EMPTY_MAP = {};
const EMPTY_SET = new Set();

// A scenario key as a querySelector attribute value (the panel uses it too,
// to focus the row a fix card opened).
export const escapeKey = (key) => (typeof CSS !== 'undefined' && typeof CSS.escape === 'function'
  ? CSS.escape(String(key))
  : String(key).replace(/["\\]/g, '\\$&'));

// How long a smooth scroll the box issued may still be gliding; a layout
// change under the cursor inside this window resumes the glide rather than
// snapping to where it would have ended.
const SMOOTH_SCROLL_MS = 600;

const cssLength = (value) => (typeof value === 'number' ? `${value}px` : value);

const isFormField = (el) => ['INPUT', 'TEXTAREA', 'SELECT'].includes(el?.tagName);

// No result yet reads "…" while the run is still replaying it (or its
// results are still being fetched); a scenario outside the run's selection
// (or one whose replay never landed) reads "—". `compact` is the steps
// level's one line — glyph, score and fault — with the tool calls, the cost
// and the time in its title.
function ResultCell({ result, expects, pending, compact = false }) {
  if (!result) {
    return <span style={{ ...mono(12), fontWeight: 600 }}>{pending ? '…' : '—'}</span>;
  }
  if (!isSettled(result)) return <span style={{ ...mono(12), fontWeight: 600 }}>…</span>;
  const pass = isPassed(result);
  const color = pass ? 'var(--color-success)' : 'var(--color-error)';
  const calls = callList(result.tool_calls, expects);
  if (compact) {
    const fault = result.fault ? faultName(result.fault) : result.status === 'errored' ? 'errored' : null;
    const cost = resultCostText(result);
    const title = `${calls.map((call) => call.label).join(' ') || 'no tools called'}${cost ? ` · ${cost}` : ''}`;
    return (
      <span title={title} style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }}>
        <span style={{ display: 'flex', alignItems: 'baseline', gap: 6, minWidth: 0, fontFamily: MONO, fontSize: 12, whiteSpace: 'nowrap' }}>
          <span style={{ fontWeight: 700, color, flexShrink: 0 }}>{pass ? '[+]' : '[!]'}</span>
          <span style={{ fontWeight: 600, color, flexShrink: 0 }}>{fmtScore(result.score)}</span>
          {fault && <span style={{ fontSize: 11, color: 'var(--color-error-text)', minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis' }}>{fault}</span>}
        </span>
        <MetricsLine metrics={resultMetrics(result)} />
      </span>
    );
  }
  return (
    <div style={{ minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, flexWrap: 'wrap', fontFamily: MONO, fontSize: 12 }}>
        <span style={{ fontWeight: 700, color }}>{pass ? '[+]' : '[!]'}</span>
        <span style={{ fontWeight: 600, color }}>{fmtScore(result.score)}</span>
        {result.fault && <span style={{ fontSize: 11, color: 'var(--color-error-text)' }}>{faultName(result.fault)}</span>}
      </div>
      <CallLine calls={calls} empty="no tools called" />
      <MetricsLine metrics={resultMetrics(result)} />
      {resultCostText(result) && (
        <span style={{ ...mono(11, 'var(--color-text-secondary)'), whiteSpace: 'nowrap' }} title={resultCostTitle(result)} data-testid="scenario-cell-cost">{resultCostText(result)}</span>
      )}
    </div>
  );
}

// A result's, a group's or a model's time and tokens as one muted line:
// `12.4s · 1.2K→340`. null where neither figure is known.
const metricsText = (metrics) => {
  if (!metrics) return null;
  const parts = [];
  if (metrics.durationMs != null) parts.push(fmtSpan(metrics.durationMs));
  const tokens = fmtTokenIO(metrics.inputTokens, metrics.outputTokens);
  if (tokens !== '—') parts.push(tokens);
  return parts.length ? parts.join(' · ') : null;
};

// The line under a cell's score, a group cell's passes, or a header's bar:
// how long the answers took and what they consumed, so a model that is
// faster or leaner shows against the others on every step. Nothing when
// nothing was recorded.
function MetricsLine({ metrics, testId = 'scenario-cell-metrics', title = 'time to answer · input→output tokens', style }) {
  const text = metricsText(metrics);
  if (!text) return null;
  return (
    <span data-testid={testId} title={title} style={{ ...mono(10.5), whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0, ...style }}>
      {text}
    </span>
  );
}

// A scenario's step marker, the way a build lists its steps. `none` is the
// catalog before any run; `loading` a run whose results are still being
// fetched — never `missing`, which would say the run ended without them.
export const STEP_MARK = {
  passed: { text: '[+]', color: 'var(--color-success)', title: 'passed on every model' },
  failed: { text: '[!]', color: 'var(--color-error)', title: 'failed on at least one model' },
  running: { text: '[~]', color: 'var(--color-warning-text)', title: 'running' },
  queued: { text: '[ ]', color: 'var(--color-text-muted)', title: 'queued' },
  missing: { text: '[?]', color: 'var(--color-text-muted)', title: 'the run ended without its results' },
  skipped: { text: '[-]', color: 'var(--color-text-muted)', title: 'not in this run' },
  none: { text: '[ ]', color: 'var(--color-text-muted)', title: 'not run yet' },
  loading: { text: '[ ]', color: 'var(--color-text-muted)', title: 'loading results…' },
};

const sameCost = (a, b) => a === b
  || (!!a && !!b && a.cost === b.cost && a.judgeCost === b.judgeCost && a.total === b.total && a.estimated === b.estimated);
const sameTokens = (a, b) => a === b || (!!a && !!b && a.input === b.input && a.output === b.output);

// Every prop by identity — the catalog row (scenarioRowsForRun's cache), its
// results (groupResultsByKey) and the columns (the panel's ref) keep theirs
// while nothing about them changed — except the cost, the tokens and the
// time, which are rebuilt each render and compared by value. The two
// callbacks are the matrix's stable ones, so they are not compared.
const rowPropsEqual = (prev, next) =>
  prev.scenario === next.scenario && prev.results === next.results && prev.columns === next.columns
  && prev.step === next.step && prev.current === next.current && prev.open === next.open
  && prev.detail === next.detail && prev.showKey === next.showKey && prev.grid === next.grid
  && prev.inSelection === next.inSelection && prev.running === next.running && prev.loading === next.loading
  && prev.tabIndex === next.tabIndex && sameCost(prev.costEntry, next.costEntry) && sameTokens(prev.tokens, next.tokens)
  && prev.timeMs === next.timeMs;

// One step of the box: a scenario's row at the given detail level. Memoised
// on rowPropsEqual, so a poll that lands two results re-renders two rows.
// `results` is the scenario's results keyed by column; `costEntry`,
// `tokens` and `timeMs` are what the COST and TIME cells read; `tabIndex`
// is the box's roving one. `onToggle(key)` opens or closes the drill-down;
// `onFocus(key, event)` tells the box which row holds focus.
const ScenarioRow = React.memo(function ScenarioRow({
  scenario, results, columns, step, current, open, detail, showKey, grid, inSelection, running, loading, costEntry, tokens = null, timeMs, tabIndex,
  onToggle, onFocus,
}) {
  const key = scenario.key;
  const steps = detail === 'steps';
  const expects = expectList(scenario, 'tools');
  const disabled = scenario.enabled === false;
  const mark = STEP_MARK[step] || STEP_MARK.none;
  const keyText = `${key}${disabled ? ' · disabled' : ''}`;
  const glyph = (
    <span data-testid="scenario-step" title={mark.title} style={{ ...mono(11, mark.color), fontWeight: 700, flexShrink: 0 }}>{mark.text}</span>
  );
  const chip = { fontFamily: MONO, fontSize: 11, padding: '2px 6px', border: '1px solid var(--color-border)', borderRadius: 4, color: 'var(--color-text-cell)', whiteSpace: 'nowrap' };
  return (
    <div
      data-testid="scenario-row"
      data-scenario-key={key}
      data-step={step}
      data-nav={key}
      data-current={current ? 'true' : undefined}
      role="button"
      aria-expanded={open}
      tabIndex={tabIndex}
      // A narrow box drops the key from the line; the row's tooltip keeps it.
      title={steps && !showKey ? `${keyText} · ${scenario.prompt || ''}` : undefined}
      onClick={() => onToggle(key)}
      onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onToggle(key); } }}
      onFocus={(event) => onFocus(key, event)}
      className={open ? undefined : 'hover:bg-[var(--color-hover)]'}
      style={{
        display: 'grid', gridTemplateColumns: grid, gap: GRID_GAP[detail] ?? GRID_GAP.steps, padding: steps ? '6px 12px' : '10px 12px',
        alignItems: steps ? 'center' : undefined,
        borderTop: '1px solid var(--color-border-light)', cursor: 'pointer',
        background: open ? 'var(--color-muted)' : undefined,
        boxShadow: current ? 'inset 2px 0 0 var(--color-warning)' : undefined,
        opacity: disabled ? 0.5 : 1,
      }}
    >
      {steps ? (
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, minWidth: 0 }}>
          {glyph}
          {showKey && (
            <span style={{ ...mono(11), minWidth: 0, maxWidth: '40%', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{keyText}</span>
          )}
          <span
            title={showKey ? scenario.prompt : undefined}
            style={{
              flex: 1, minWidth: 0, fontSize: 13, color: scenario.orphan ? 'var(--color-text-muted)' : 'var(--color-text-primary)',
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}
          >
            {scenario.prompt}
          </span>
        </div>
      ) : (
        <>
          <div style={{ minWidth: 0 }}>
            <div style={{ ...mono(11), marginBottom: 2, display: 'flex', gap: 6 }}>
              {glyph}
              <span style={{ minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis' }}>{keyText}</span>
            </div>
            <div style={{ fontSize: 13, lineHeight: '18px', color: 'var(--color-text-primary)', textWrap: 'pretty' }}>{scenario.prompt}</div>
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, alignContent: 'flex-start', minWidth: 0 }}>
            {expects.map((name) => (
              <span key={name} style={chip}>{name}</span>
            ))}
            {expects.length === 0 && expectList(scenario, 'contains').map((pattern) => (
              <span key={`contains-${pattern}`} style={chip} title="the answer must contain this">{`contains: ${pattern}`}</span>
            ))}
          </div>
        </>
      )}
      {columns.map((label) => (
        <ResultCell
          key={label}
          result={results?.[label]}
          expects={expects}
          pending={(running || loading) && inSelection}
          compact={steps}
        />
      ))}
      <CostBlock entry={costEntry} compact={steps} testId="scenario-row-cost" tokens={tokens} />
      {steps && (
        <span data-testid="scenario-row-time" title="the slowest answer across the models" style={{ ...mono(11), textAlign: 'right', whiteSpace: 'nowrap' }}>{fmtSpan(timeMs)}</span>
      )}
    </div>
  );
}, rowPropsEqual);

// The step box: the shown run's scenarios read like a build's steps, in a
// box that scrolls on its own under a sticky column header (the models'
// live standing) and sticky, collapsible group rows.
//
// `rows` are the scenarios to show, in the order to show them, already
// filtered; each carries `.key`, `.prompt`, `.group`, `.expectations`.
// `stepsByKey` is every scenario's step (the panel computes it over the
// whole suite, so the cursor cannot hide behind a filter); `currentKey` is
// the step the build is on. `detail` is 'steps' (one line a scenario) or
// 'tools' (the fuller rows); a catalog with no model columns always reads
// as tools. `collapsedGroups` / `onToggleGroup` fold groups; `openKey` /
// `onToggleRow` open a drill-down (`renderDetail(scenario)` draws it under
// its row, and the box grows by its height so it is never clipped);
// `following` / `onStopFollowing` are the panel's follow state — while on,
// the box keeps the cursor a third of the way down and holds it there when
// the layout under it moves. `boxRef` receives the scrolling element.
export function ScenarioMatrix({
  rows = EMPTY_LIST, columns = EMPTY_LIST, run = null, resultsByKey = EMPTY_MAP, runKeys = EMPTY_SET, running = false, loading = false,
  stepsByKey = null, currentKey = null, bars = EMPTY_LIST, detail = 'steps', showKey = true, collapsedGroups = EMPTY_SET, onToggleGroup,
  openKey = null, onToggleRow, following = false, onStopFollowing, emptyLabel, maxHeight = null, renderDetail, boxRef = null,
  testId = 'scenario-matrix',
}) {
  // The catalog alone (no run, so no model columns) keeps the fuller
  // layout: the question beside what it expects.
  const level = columns.length === 0 ? 'tools' : detail;
  const steps = level === 'steps';
  const grid = gridFor(level, columns.length);
  const gap = GRID_GAP[level];
  const minWidth = steps ? stepsMinWidth(columns.length) : toolsMinWidth(columns.length);

  const inSelection = (scenario) => runKeys.has(scenario.key) || Boolean(resultsByKey[scenario.key]);
  // The panel's steps, or — rendered on its own — the same reading.
  const fallbackStep = (scenario) => {
    if (!run) return 'none';
    if (loading) return inSelection(scenario) ? 'loading' : 'skipped';
    return scenarioStep(resultsByKey[scenario.key], columns, { inRun: inSelection(scenario), running });
  };
  const stepOf = (scenario) => stepsByKey?.[scenario.key] ?? fallbackStep(scenario);
  const costByKey = new Map(rows.map((scenario) => [scenario.key, scenarioCost(run, scenario.key, resultsByKey[scenario.key])]));
  const estimatedAnywhere = [...costByKey.values()].some((entry) => entry?.estimated);
  const tokensByKey = new Map(rows.map((scenario) => [scenario.key, scenarioTokens(resultsByKey[scenario.key], columns)]));
  // The run's time and tokens per model, over every result in, for the header.
  const runTotals = columnTotals(resultsByKey, columns);

  // Group blocks in order of first appearance, so the panel's order holds.
  const hasGroups = rows.some((s) => s.group);
  const groups = [];
  rows.forEach((scenario) => {
    const name = scenario.group || '';
    let group = groups.find((g) => g.name === name);
    if (!group) {
      group = { name, rows: [] };
      groups.push(group);
    }
    group.rows.push(scenario);
  });
  // A fold only applies where a group row is drawn to unfold it again.
  const isCollapsed = (name) => (name || hasGroups) && collapsedGroups.has(name);

  // One Tab stop in the box: the row that last had focus while it is still
  // drawn, else the open row, else the cursor, else the first row or group
  // row. Every other row is reachable with the arrow keys.
  const [activeNav, setActiveNav] = useState(null);
  const navs = [];
  groups.forEach((group) => {
    if (group.name || hasGroups) navs.push(`group:${group.name}`);
    if (!isCollapsed(group.name)) group.rows.forEach((scenario) => navs.push(scenario.key));
  });
  const drawn = new Set(navs);
  const tabStop = [activeNav, openKey, currentKey].find((id) => id != null && drawn.has(id)) ?? navs[0] ?? null;

  const scrollRef = useRef(null);
  const headerRef = useRef(null);
  const [headerHeight, setHeaderHeight] = useState(50);
  const [detailHeight, setDetailHeight] = useState(0);
  const headerHeightRef = useRef(headerHeight);
  // The latest callbacks, so the rows' handlers can stay the same functions
  // across renders.
  const latest = useRef({});
  useIsoLayoutEffect(() => {
    headerHeightRef.current = headerHeight;
    latest.current = { onToggleRow, onStopFollowing };
  });

  const setBox = useCallback((el) => {
    scrollRef.current = el;
    if (boxRef) boxRef.current = el;
  }, [boxRef]);
  const toggleRow = useCallback((key) => latest.current.onToggleRow?.(key), []);
  // Focus arriving from outside the box stops the follow, so an auto-fold
  // can never take the focused row away.
  const focusNav = useCallback((id, event) => {
    setActiveNav(id);
    const box = scrollRef.current;
    if (box && !box.contains(event.relatedTarget)) latest.current.onStopFollowing?.();
  }, []);
  const stopFollowing = () => onStopFollowing?.();

  // The sticky header's height: where the group rows stick, and what the
  // scroll targets allow for.
  useIsoLayoutEffect(() => {
    const el = headerRef.current;
    if (!el) return undefined;
    const measure = () => {
      const height = el.offsetHeight;
      if (height) setHeaderHeight((previous) => (previous === height ? previous : height));
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return undefined;
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  // The open drill-down's wrapper, as it comes and goes. Its height is what
  // the box grows by past its cap — measured on arrival, watched while it is
  // there, 0 once it is gone — and its arrival puts the row directly under
  // the column header and its group row, so the drill-down starts in view.
  // Keyed on the element rather than on openKey because the wrapper also
  // leaves and returns while the row stays open: a fold of its group, a
  // filter that hides the row and is cleared again. Each return is a new
  // element to measure, watch and position; an effect on openKey would see
  // none of them. Runs in the commit's layout phase, before paint.
  const attachDetail = useCallback((el) => {
    if (!el) {
      setDetailHeight(0);
      return undefined;
    }
    const measure = () => setDetailHeight(el.offsetHeight);
    measure();
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(measure);
    observer?.observe(el);
    const box = scrollRef.current;
    const row = el.previousElementSibling;
    if (box && row?.hasAttribute('data-scenario-key')) {
      const groupRow = row.closest('[data-group]')?.querySelector('[data-testid="scenario-group-row"]');
      box.scrollTo({
        top: openRowScrollTop({ rowTop: row.offsetTop, headerHeight: headerHeightRef.current, groupRowHeight: groupRow?.offsetHeight ?? 0 }),
        behavior: 'smooth',
      });
    }
    return () => {
      observer?.disconnect();
      setDetailHeight(0);
    };
  }, []);

  // Following: a cursor that moved scrolls smoothly to a third of the way
  // down the box; a cursor whose surroundings moved (a group folded, a
  // filter or the detail level changed) is put back there before paint.
  // When the surroundings move while that glide is still going — the group
  // above the cursor folds the moment the cursor enters the next one, the
  // usual case in scenario-major order — the box is shifted by the fold
  // before paint, so the row stays where the glide had it, and the glide is
  // issued again to the new target rather than cut short with a hop.
  // Nothing moves on an unchanged poll, or while the cursor is hidden.
  const lastCursor = useRef(null);
  const lastTarget = useRef(null);
  const glidingUntil = useRef(0);
  useIsoLayoutEffect(() => {
    const box = scrollRef.current;
    if (!box || !following || !currentKey) {
      lastCursor.current = currentKey;
      return;
    }
    const row = box.querySelector(`[data-scenario-key="${escapeKey(currentKey)}"]`);
    if (!row) return;
    const target = cursorScrollTop({ rowTop: row.offsetTop, headerHeight, boxHeight: box.clientHeight });
    if (Math.abs(target - box.scrollTop) > 4) {
      const gliding = Date.now() < glidingUntil.current && lastTarget.current != null;
      if (currentKey !== lastCursor.current) {
        box.scrollTo({ top: target, behavior: 'smooth' });
        glidingUntil.current = Date.now() + SMOOTH_SCROLL_MS;
      } else if (gliding) {
        box.scrollTop = Math.max(0, box.scrollTop - (lastTarget.current - target));
        box.scrollTo({ top: target, behavior: 'smooth' });
      } else {
        box.scrollTop = target;
      }
    }
    lastCursor.current = currentKey;
    lastTarget.current = target;
  }, [currentKey, following, collapsedGroups, rows, detail, headerHeight]);

  // Keeps a row the arrow keys landed on out from under the sticky header
  // and its group row, and within the box.
  const reveal = (el) => {
    const box = scrollRef.current;
    if (!box || !el) return;
    const groupRow = el.hasAttribute('data-scenario-key')
      ? el.closest('[data-group]')?.querySelector('[data-testid="scenario-group-row"]')
      : null;
    const covered = headerHeightRef.current + (groupRow?.offsetHeight ?? 0);
    if (el.offsetTop - covered < box.scrollTop) box.scrollTop = Math.max(0, el.offsetTop - covered);
    else if (el.offsetTop + el.offsetHeight > box.scrollTop + box.clientHeight) box.scrollTop = el.offsetTop + el.offsetHeight - box.clientHeight;
  };

  const handleKeyDown = (event) => {
    if (isFormField(event.target)) return;
    const box = scrollRef.current;
    if (!box) return;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      const all = [...box.querySelectorAll('[data-nav]')];
      if (!all.length) return;
      // From the focused row or group row — or, from inside an open
      // drill-down, from the row it belongs to.
      let index = all.indexOf(event.target);
      if (index < 0) index = all.findIndex((el) => el.hasAttribute('data-scenario-key') && el.parentElement?.contains(event.target));
      const next = index < 0 ? all[0] : all[Math.min(Math.max(index + (event.key === 'ArrowDown' ? 1 : -1), 0), all.length - 1)];
      event.preventDefault();
      onStopFollowing?.();
      if (next && next !== event.target) {
        next.focus({ preventScroll: true });
        reveal(next);
      }
      return;
    }
    if (event.key === 'Escape' && openKey) {
      onToggleRow?.(openKey);
      box.querySelector(`[data-scenario-key="${escapeKey(openKey)}"]`)?.focus({ preventScroll: true });
    }
  };

  return (
    <div
      ref={setBox}
      data-testid={testId}
      data-detail={level}
      onWheel={stopFollowing}
      onTouchMove={stopFollowing}
      onKeyDown={handleKeyDown}
      style={{
        border: '1px solid var(--color-border-light)', borderRadius: 10, overflow: 'auto', position: 'relative', scrollbarGutter: 'stable',
        maxHeight: maxHeight ? (detailHeight ? `calc(${cssLength(maxHeight)} + ${detailHeight}px)` : cssLength(maxHeight)) : undefined,
      }}
    >
      <div style={{ minWidth }}>
        {/* The header's muted tint sits on an opaque surface: rows scroll
            under it, and the dark theme's tint alone is 95% transparent. */}
        <div
          ref={headerRef}
          style={{
            display: 'grid', gridTemplateColumns: grid, gap, padding: '8px 12px', alignItems: 'end', position: 'sticky', top: 0, zIndex: 2,
            backgroundColor: 'var(--color-surface)', backgroundImage: 'linear-gradient(var(--color-muted), var(--color-muted))',
          }}
        >
          <MicroLabel size={10} color="var(--color-text-muted)">{steps ? 'Step' : 'Scenario'}</MicroLabel>
          {!steps && <MicroLabel size={10} color="var(--color-text-muted)">Expects</MicroLabel>}
          {columns.map((label) => {
            const { short, provider } = describeModel(run, label);
            const bar = bars.find((b) => b.label === label);
            return (
              <span key={label} style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }} title={label}>
                <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, color: 'var(--color-text-primary)' }}>{short}</span>
                <span style={mono(10)}>{provider || ' '}</span>
                {bar && bar.passed != null && bar.total != null && (
                  <PassBar passed={bar.passed} total={bar.total} height={4} valueWidth={48} style={{ marginTop: 3 }} />
                )}
                <MetricsLine
                  metrics={runTotals[label]}
                  testId="scenario-column-totals"
                  title="this model's answers' time added up, and its input→output tokens, over the results in"
                  style={{ marginTop: 2 }}
                />
              </span>
            );
          })}
          <span style={{ textAlign: 'right' }} title="What the scenario cost across every model, and what judging it cost; under it, its input→output tokens">
            <MicroLabel size={10} color="var(--color-text-muted)">Cost</MicroLabel>
          </span>
          {steps && (
            <span style={{ textAlign: 'right' }} title="The slowest answer across the run's models; a group's add up">
              <MicroLabel size={10} color="var(--color-text-muted)">Time</MicroLabel>
            </span>
          )}
        </div>

        {groups.map((group) => {
          const name = group.name;
          const collapsed = isCollapsed(name);
          const navId = `group:${name}`;
          const inRun = group.rows.filter(inSelection);
          const mark = STEP_MARK[groupStep(group.rows.map(stepOf))] || STEP_MARK.none;
          // Per model: the group's passes, and under them its scenarios'
          // time and tokens added up.
          const totals = columnTotals(resultsByKey, columns, group.rows.map((s) => s.key));
          const cells = columns.map((label) => {
            const metrics = totals[label];
            if (!inRun.length) return { label, text: 'not in this run', color: 'var(--color-text-muted)', weight: 400, metrics };
            if (loading) return { label, text: 'loading…', color: 'var(--color-text-muted)', weight: 400, metrics };
            const settled = inRun.filter((s) => isSettled(resultsByKey[s.key]?.[label]));
            if (running && !settled.length) return { label, text: 'queued', color: 'var(--color-text-muted)', weight: 400, metrics };
            const passed = settled.filter((s) => isPassed(resultsByKey[s.key][label])).length;
            const total = inRun.length;
            const color = total && passed === total ? 'var(--color-success-text)' : passed === 0 ? 'var(--color-error-text)' : 'var(--color-text-cell)';
            return { label, text: `${fmtPasses(passed, total)} passed`, color, weight: 600, metrics };
          });
          const subtotal = sumScenarioCosts(group.rows.map((s) => costByKey.get(s.key)));
          const groupTokens = sumTokens(group.rows.map((s) => tokensByKey.get(s.key)));
          return (
            <div key={name || '__ungrouped'} data-group={name}>
              {(name || hasGroups) && (
                <div
                  data-testid="scenario-group-row"
                  data-group={name}
                  data-collapsed={collapsed ? 'true' : 'false'}
                  data-nav={navId}
                  role="button"
                  aria-expanded={!collapsed}
                  tabIndex={tabStop === navId ? 0 : -1}
                  onClick={() => onToggleGroup?.(name)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' || event.key === ' ') {
                      event.preventDefault();
                      onToggleGroup?.(name);
                    } else if ((event.key === 'ArrowLeft' && !collapsed) || (event.key === 'ArrowRight' && collapsed)) {
                      event.preventDefault();
                      onToggleGroup?.(name);
                    }
                  }}
                  onFocus={(event) => focusNav(navId, event)}
                  style={{
                    display: 'grid', gridTemplateColumns: grid, gap, padding: '7px 12px', alignItems: 'center',
                    borderTop: '1px solid var(--color-border-light)', background: 'var(--color-background)', cursor: 'pointer',
                    position: 'sticky', top: headerHeight, zIndex: 1,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0 }}>
                    <Glyph kind="chevron" open={!collapsed} />
                    <span data-testid="scenario-group-step" title={mark.title} style={{ ...mono(11, mark.color), fontWeight: 700, flexShrink: 0 }}>{mark.text}</span>
                    <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{name || 'ungrouped'}</span>
                    {steps && <span style={{ ...mono(11), whiteSpace: 'nowrap' }}>{`· ${plural(group.rows.length, 'scenario')}`}</span>}
                  </div>
                  {!steps && <span style={mono(11)}>{plural(group.rows.length, 'scenario')}</span>}
                  {cells.map((cell) => (
                    <span key={cell.label} style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }}>
                      <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: cell.weight, color: cell.color, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{cell.text}</span>
                      <MetricsLine metrics={cell.metrics} testId="scenario-group-metrics" title="the group's answers' time added up, and their input→output tokens, on this model" />
                    </span>
                  ))}
                  <CostBlock entry={subtotal} compact={steps} testId="scenario-group-cost" tokens={groupTokens} />
                  {steps && (
                    <span data-testid="scenario-group-time" title="the group's scenarios' times added up" style={{ ...mono(11), textAlign: 'right', whiteSpace: 'nowrap' }}>
                      {fmtSpan(groupTime(group.rows, resultsByKey, columns))}
                    </span>
                  )}
                </div>
              )}
              {!collapsed && group.rows.map((scenario) => {
                const open = openKey === scenario.key;
                return (
                  <div key={scenario.key}>
                    <ScenarioRow
                      scenario={scenario}
                      results={resultsByKey[scenario.key]}
                      columns={columns}
                      step={stepOf(scenario)}
                      current={scenario.key === currentKey}
                      open={open}
                      detail={level}
                      showKey={showKey}
                      grid={grid}
                      inSelection={inSelection(scenario)}
                      running={running}
                      loading={loading}
                      costEntry={costByKey.get(scenario.key) ?? null}
                      tokens={tokensByKey.get(scenario.key) ?? null}
                      timeMs={scenarioTime(resultsByKey[scenario.key], columns)}
                      tabIndex={tabStop === scenario.key ? 0 : -1}
                      onToggle={toggleRow}
                      onFocus={focusNav}
                    />
                    {open && <div ref={attachDetail}>{renderDetail?.(scenario)}</div>}
                  </div>
                );
              })}
            </div>
          );
        })}
        {rows.length === 0 && (
          <Empty style={{ borderTop: '1px solid var(--color-border-light)' }}>{emptyLabel || '[+] nothing failed in this group'}</Empty>
        )}
        {estimatedAnywhere && (
          <div style={{ ...mono(11), padding: '6px 12px', borderTop: '1px solid var(--color-border-light)', textAlign: 'right' }} data-testid="scenario-matrix-legend">{COST_LEGEND}</div>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Drill-down

function resultMeta(result) {
  const parts = [];
  if (result.duration_ms != null) parts.push(fmtMs(result.duration_ms));
  if (result.input_tokens != null || result.output_tokens != null) {
    parts.push(`${fmtK((result.input_tokens || 0) + (result.output_tokens || 0))} tokens`);
  }
  const cost = resultCostText(result);
  if (cost) parts.push(cost);
  return parts.join(' · ');
}

function ResultCard({ label, run, result, expects, running }) {
  const { short } = describeModel(run, label);
  const header = (
    <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)' }} title={label}>{short}</span>
  );
  const shell = (children, extra) => (
    <div data-testid="scenario-result-detail" style={{ background: 'var(--color-card)', border: '1px solid var(--color-border-light)', borderRadius: 10, overflow: 'hidden', minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', borderBottom: '1px solid var(--color-border-light)', flexWrap: 'wrap' }}>
        {header}
        {extra}
      </div>
      <div style={{ padding: '10px 12px', display: 'flex', flexDirection: 'column', gap: 10 }}>{children}</div>
    </div>
  );

  if (!result || !isSettled(result)) {
    return shell(
      <span style={mono(11)}>{running ? 'waiting for this replay…' : 'not part of this run'}</span>,
      <Badge tone="muted">{running ? 'pending' : 'no result'}</Badge>
    );
  }

  const pass = isPassed(result);
  const statusTone = pass ? 'success' : 'error';
  const calls = callList(result.tool_calls, expects);
  const diagnosis = result.diagnosis || {};
  const judge = diagnosis.judge || {};
  const fault = result.fault || (result.status === 'errored' ? 'run_error' : null);
  const explanation = [diagnosis.summary, diagnosis.recommendation || result.recommendation].filter(Boolean).join(' ')
    || result.error_message || '';
  const criteria = Object.entries(result.scores || {});
  const meta = resultMeta(result);

  return shell(
    <>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap', fontFamily: MONO, fontSize: 11 }}>
        <MicroLabel size={10} color="var(--color-text-muted)">tools</MicroLabel>
        <CallLine calls={calls} empty="none called" style={{ display: 'contents' }} />
      </div>
      {fault && (
        <div style={{ background: 'var(--color-error-soft)', borderRadius: 8, padding: '8px 10px', fontSize: 12, lineHeight: '18px', color: 'var(--color-error-text)', textWrap: 'pretty' }}>
          <span style={{ fontFamily: MONO, fontWeight: 700 }}>{`[!] ${faultName(fault)}`}</span>
          {explanation ? ` — ${explanation}` : ''}
          {judge.suggested_tool?.name && (
            <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 11 }}>
              {`suggested tool: ${judge.suggested_tool.name}${judge.suggested_tool.description ? ` — ${judge.suggested_tool.description}` : ''}`}
            </div>
          )}
          {judge.instruction_change && (
            <div style={{ marginTop: 4, fontStyle: 'italic' }}>{`instruction change: “${judge.instruction_change}”`}</div>
          )}
        </div>
      )}
      {result.output ? (
        <div style={{ fontFamily: 'var(--font-text)', fontSize: 13, lineHeight: '19px', color: 'var(--color-text-cell)', maxHeight: 190, overflow: 'auto', whiteSpace: 'pre-wrap', textWrap: 'pretty' }}>
          {result.output}
        </div>
      ) : (
        <div style={mono(11)}>answer not retained for this run</div>
      )}
      {criteria.length > 0 && (
        <div style={{ ...mono(11), display: 'flex', flexWrap: 'wrap', gap: '2px 10px' }} title="score per criterion">
          {criteria.map(([key, value]) => (
            <span key={key}>{faultName(key)} <span style={{ color: 'var(--color-text-secondary)' }}>{value == null ? 'skipped' : fmtScore(value)}</span></span>
          ))}
        </div>
      )}
    </>,
    <>
      <Badge tone={statusTone}>{result.score == null ? result.status : `${result.status} · ${fmtScore(result.score)}`}</Badge>
      {meta && <span style={{ marginLeft: 'auto', ...mono(11) }} title={resultCostTitle(result)}>{meta}</span>}
      {result.agent_run_id && (
        <ReplayLink kind="scenario_result" id={result.id} title="Replay this scenario's run" testId="scenario-result-replay" style={meta ? undefined : { marginLeft: 'auto' }} />
      )}
    </>
  );
}

// `inRun` says whether the selected run covers this scenario: a scenario the
// run skipped offers a replay instead of empty result cards, and a suite with
// no run at all says so rather than blaming a run that never happened.
export function ScenarioDetail({ scenario, run, columns, resultsByKey, running, inRun = true, onRerun, onToggleEnabled, canMutate = true }) {
  const expects = expectList(scenario, 'tools');
  const results = resultsByKey[scenario.key] || {};
  const anyResult = columns.some((label) => results[label]);
  const covered = inRun || anyResult;
  return (
    <div style={{ borderTop: '1px solid var(--color-border-light)', background: 'var(--color-background)', padding: '12px 12px 14px' }} data-testid="scenario-drilldown">
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10, flexWrap: 'wrap' }}>
        <span style={mono(11)}>{scenario.key}</span>
        <span style={{ fontSize: 12, color: 'var(--color-text-cell)' }}>expects</span>
        <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, color: 'var(--color-text-primary)' }}>{expects.join(' or ') || '—'}</span>
        {canMutate && (
          <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 14 }}>
            <button
              type="button"
              onClick={(event) => { event.stopPropagation(); onToggleEnabled?.(scenario); }}
              title={scenario.enabled === false ? 'Enable this scenario' : 'Disable this scenario'}
              style={{ background: 'transparent', border: 'none', padding: 0, cursor: 'pointer', fontFamily: MONO, fontSize: 11, color: scenario.enabled === false ? 'var(--color-text-muted)' : 'var(--color-text-cell)' }}
            >
              {scenario.enabled === false ? '[ ] enabled' : '[x] enabled'}
            </button>
            <MonoLink onClick={() => onRerun?.(scenario)} title="Run only this scenario under the selected models">re-run scenario</MonoLink>
          </span>
        )}
      </div>
      {scenario.notes && (
        <div style={{ fontSize: 12, fontStyle: 'italic', color: 'var(--color-text-secondary)', marginBottom: 10 }}>{scenario.notes}</div>
      )}
      {scenario.catalogChanged && (
        <div style={{ fontSize: 12, color: 'var(--color-text-secondary)', marginBottom: 10 }}>
          This run used an earlier version of this question. Re-running uses the current version.
        </div>
      )}
      {!run ? (
        <div style={mono(11)}>No runs yet — use “re-run scenario” to replay this one on its own.</div>
      ) : !covered ? (
        <div style={mono(11)}>Not part of this run — use “re-run scenario” to replay it.</div>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 12 }}>
          {columns.map((label) => (
            <ResultCard key={label} label={label} run={run} result={results[label]} expects={expects} running={running} />
          ))}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// WHAT TO FIX

// `onRerun(item, runnable)`, when given, puts a `re-run n scenarios ->` link
// on each card for the scenarios it names that can still be replayed —
// `runnable` is `runnableFor(item)`'s { keys, dropped } (by default,
// runnableKeys over the suite's catalog), so a disabled or removed scenario
// is never posted and a card with none left says so.
export function FixList({
  items, columns = [], agentName, onNavigate, onOpenScenario, run = null, results = [], evaluation = null, runNumber = null, scenarios = [],
  onRerun = null, runnableFor = null,
}) {
  const runnable = (item) => (runnableFor ? runnableFor(item) : runnableKeys(item.scenario_keys || [], scenarios));
  // Which model cohort the list is read for. A fault one model keeps
  // making is that model's to fix — more instruction, a different tool —
  // so the list narrows to what the runner attributed to it, counted for
  // that model alone.
  const [model, setModel] = useState('all');
  const filterable = columns.length > 1;
  const selected = filterable ? model : 'all';
  const attributed = filterable ? withModelBreakdown(items, results, (result) => labelForResult(run, result)) : items;
  const visible = fixItemsForModel(attributed, selected);
  const counts = filterable ? fixItemCountsByModel(attributed, columns) : {};

  // The Markdown brief a card copies for a coding harness: the card as
  // shown (so a model-scoped card briefs that model alone), the scenarios
  // it names with their prompts, expectations and results, and the MCP
  // calls that prove the fix.
  const promptFor = (item) => fixPromptMarkdown({
    item, evaluation, run, runNumber, results, scenarios, agentName,
    dashboardUrl: dashboardUrl(), labelFor: (result) => labelForResult(run, result),
  });

  const scopeFor = (item) => {
    const scenarios = plural((item.scenario_keys || []).length, 'scenario');
    if (item.kind === 'instruction') return `${(item.scenario_keys || []).join(', ')} · judge suggestion`;
    const models = uniq(item.models || []);
    if (columns.length <= 1 || models.length === 0) return scenarios;
    const all = models.length >= columns.length;
    const label = all ? (columns.length === 2 ? 'both models' : 'all models') : models.map((m) => splitModelLabel(m).short).join(', ');
    return `${scenarios} · ${label}`;
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }} data-testid="fix-list">
      {filterable && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }} data-testid="fix-list-model-filter">
          <span style={mono(11)}>for</span>
          <Chip square mono selected={selected === 'all'} onClick={() => setModel('all')} testId="fix-filter-all">{`all models ${items.length}`}</Chip>
          {columns.map((label) => (
            <Chip
              key={label}
              square
              mono
              selected={selected === label}
              onClick={() => setModel(label)}
              title={`Only what ${label} needs fixed`}
              testId="fix-filter-model"
            >
              {`${splitModelLabel(label).short} ${counts[label] ?? 0}`}
            </Chip>
          ))}
        </div>
      )}
      {visible.length === 0 && (
        <Empty style={{ border: '1px solid var(--color-border-light)', borderRadius: 10, padding: '14px 12px' }}>
          {`[+] nothing to fix for ${splitModelLabel(selected).short}`}
        </Empty>
      )}
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 12 }}>
      {visible.map((item, index) => {
        const info = item.kind === 'instruction';
        const tone = info ? 'info' : 'error';
        const tools = [];
        const seen = new Set();
        (item.tools || []).forEach((tool) => {
          const name = typeof tool === 'string' ? tool : tool?.name;
          if (!name || seen.has(name)) return;
          seen.add(name);
          tools.push({ name, note: (typeof tool === 'object' && (tool.note || tool.server?.name)) || null });
        });
        const server = item.server;
        const enabled = server?.status === 'enabled';
        const agent = agentName || 'the agent';
        const rerun = onRerun ? runnable(item) : null;
        return (
          <div
            key={`${item.fault}-${index}`}
            data-testid="scenario-recommendation"
            style={{ border: '1px solid var(--color-border)', borderRadius: 10, padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: 10, minWidth: 0 }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
              <Glyph kind={info ? 'info' : 'fault'} />
              <Badge tone={tone}>{`${faultName(item.fault)}${item.count > 1 ? ` ×${item.count}` : ''}`}</Badge>
              {onOpenScenario && (item.scenario_keys || []).length > 0 ? (
                <button
                  type="button"
                  onClick={() => onOpenScenario(item.scenario_keys)}
                  title={`Show ${(item.scenario_keys || []).join(', ')} — the question, the answer and the tools it called`}
                  style={{ ...mono(11), background: 'none', border: 0, padding: 0, cursor: 'pointer', color: 'var(--color-text-link, var(--color-text-primary))', textDecoration: 'underline', textUnderlineOffset: 2 }}
                >
                  {scopeFor(item)}
                </button>
              ) : (
                <span style={mono(11)}>{scopeFor(item)}</span>
              )}
            </div>
            {item.recommendation && (
              <p style={{ margin: 0, fontSize: 13, lineHeight: '19px', color: 'var(--color-text-cell)', textWrap: 'pretty' }}>{item.recommendation}</p>
            )}
            {item.quote && (
              <div style={{ background: 'var(--color-muted)', borderRadius: 8, padding: '8px 10px', fontSize: 12, lineHeight: '18px', color: 'var(--color-text-cell)', fontStyle: 'italic' }}>
                “{item.quote}”
              </div>
            )}
            {tools.length > 0 && (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <MicroLabel size={10} color="var(--color-text-muted)">{item.tools_label || 'tools'}</MicroLabel>
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                  {tools.map((tool) => (
                    <span key={tool.name} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '3px 8px', borderRadius: 6, border: '1px solid var(--color-border)', fontFamily: MONO, fontSize: 11, maxWidth: '100%' }}>
                      <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{tool.name}</span>
                      {tool.note && <span style={{ color: 'var(--color-text-muted)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }} title={tool.note}>{tool.note}</span>}
                    </span>
                  ))}
                </div>
              </div>
            )}
            {server && (
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', fontSize: 12, color: 'var(--color-text-cell)' }}>
                <span>served by</span>
                <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{server.name || server.key}</span>
                <Badge tone={enabled ? 'success' : 'warning'} size={10} style={{ padding: '1px 6px' }}>
                  {enabled ? `enabled for ${agent}` : `${server.status || 'unknown'} · not enabled for ${agent}`}
                </Badge>
              </div>
            )}
            {item.note && (
              <div style={{ fontSize: 12, lineHeight: '18px', color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>{item.note}</div>
            )}
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 'auto', paddingTop: 2, flexWrap: 'wrap' }}>
              {item.action?.path && (
                <Button size="sm" onClick={() => onNavigate?.(item.action.path)}>{item.action.label}</Button>
              )}
              {item.action?.hint && <span style={{ ...mono(11), whiteSpace: 'nowrap' }}>{item.action.hint}</span>}
              {rerun && (rerun.keys.length ? (
                <MonoLink onClick={() => onRerun(item, rerun)} title="Replay these scenarios under the models in the picker" testId="fix-item-rerun">
                  {`re-run ${plural(rerun.keys.length, 'scenario')}`}
                </MonoLink>
              ) : (
                <span
                  style={{ ...mono(11), whiteSpace: 'nowrap' }}
                  title={`${rerun.dropped.join(', ')} · disabled or no longer in the suite`}
                  data-testid="fix-item-rerun-none"
                >
                  re-run · none enabled
                </span>
              ))}
              <CopyFixPromptButton build={() => promptFor(item)} style={{ marginLeft: 'auto' }} />
              <ImplementFixButton item={item} evaluation={evaluation} run={run} />
            </div>
          </div>
        );
      })}
    </div>
    </div>
  );
}
