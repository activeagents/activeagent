import React from 'react';
import { Badge, Button, Empty, Glyph, MicroLabel, MonoLink, Panel, PassBar, MONO, TONE, toneFor } from './primitives';
import { fmtCost, fmtK, fmtMs, fmtScore, fmtTokens, splitModelLabel, timeAgo } from '../../utils/format';

// The panels a scenario suite's expanded body is built from — Runs, Models,
// What to fix, the scenario matrix and a scenario's drill-down — plus the
// derivations they share. Everything here is presentational: state, fetching
// and mutations live in ScenarioSuitePanel.

// ---------------------------------------------------------------------------
// Derivations

const uniq = (list) => [...new Set(list)];

export const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

// The fault taxonomy renders lower-case with spaces: expected_tool_not_called
// → "expected tool not called".
export const faultName = (fault) => String(fault || '').replace(/_/g, ' ');

export const isPassed = (result) => result?.status === 'passed';
export const isSettled = (result) => !!result && result.status !== 'pending';
export const inProgress = (run) => !!run && ['pending', 'running'].includes(run.status);

// A pending run's selection is the request as posted ({ group } / { keys } /
// { models: ["a", "b"] }); once the runner starts it becomes the resolved
// summary ({ scenario_keys, models: [{ label, provider, model }] }). Both are
// read here.
const selectionOf = (run) => run?.selection || run?.scores?._selection || {};

export const selectionModelLabels = (run) =>
  (selectionOf(run).models || []).map((m) => (typeof m === 'string' ? m : m?.label)).filter(Boolean);

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

// The scenario keys a run covers: the resolved selection once the runner
// started; before that, what the request implies against the suite.
export function runScenarioKeys(run, scenarios = []) {
  const selection = selectionOf(run);
  if (Array.isArray(selection.scenario_keys) && selection.scenario_keys.length) return selection.scenario_keys;
  if (!run) return [];
  if (Array.isArray(selection.keys) && selection.keys.length) return selection.keys;
  if (Array.isArray(selection.scenario_ids) && selection.scenario_ids.length) {
    const ids = selection.scenario_ids.map(String);
    return scenarios.filter((s) => ids.includes(String(s.id))).map((s) => s.key);
  }
  const enabled = scenarios.filter((s) => s.enabled !== false);
  if (selection.group) return enabled.filter((s) => s.group === selection.group).map((s) => s.key);
  if (inProgress(run)) return enabled.map((s) => s.key);
  return [];
}

export function runScenarioCount(run, columns = [], scenarios = []) {
  const keys = runScenarioKeys(run, scenarios);
  if (keys.length) return keys.length;
  const stats = Object.values(run?.scores?._models || {});
  if (stats.length) return Math.max(...stats.map((s) => s.scenarios || 0));
  if (run?.samples_evaluated && columns.length) return Math.round(run.samples_evaluated / columns.length);
  return 0;
}

// Passed / total for one model of a run — from the run's summary once it is
// complete, otherwise counted from the results that have landed.
export function modelPassStats(run, label, results = [], scenarioCount = 0) {
  const stats = run?.scores?._models?.[label];
  if (stats && stats.scenarios != null) return { passed: stats.passed || 0, total: stats.scenarios || 0 };
  const mine = results.filter((r) => labelForResult(run, r) === label);
  return { passed: mine.filter(isPassed).length, total: scenarioCount || mine.length };
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
// RUNS

// GET /api/evaluations/:id serves at most this many runs, newest first.
export const RUNS_PAGE = 20;

// How many runs the suite has: `run_count` from the API when it reports it
// (so `#n` stays stable once the run list is capped), else the runs fetched —
// never fewer than the list, which can grow locally when a run starts.
export const runTotalOf = (runs = [], runCount = null) =>
  (Number.isFinite(runCount) ? Math.max(runCount, runs.length) : runs.length);

// The panel's header meta: `3 runs`, or `24 runs · latest 20` when the list
// is a page of a longer history (or may be, when the total is unknown).
export const runsMeta = (runs = [], runCount = null) => {
  const total = runTotalOf(runs, runCount);
  const paged = runs.length < total || (!Number.isFinite(runCount) && runs.length >= RUNS_PAGE);
  return `${plural(total, 'run')}${paged ? ` · latest ${runs.length}` : ''}`;
};

// One row per run, newest first. `runs` is the suite's run list (newest
// first); `#n` counts from the oldest run of the suite: `runCount` is the
// suite's total when known, so the numbering does not shift once the list
// is capped at the RUNS_PAGE most recent.
export function RunsPanel({ runs, runCount = null, selectedId, onSelect, agentName, selectedResults = [], scenarios = [] }) {
  const total = runTotalOf(runs, runCount);
  const numberOf = (index) => total - index;
  const rows = runs.map((run, index) => {
    const columns = modelColumns(run, run.id === selectedId ? selectedResults : []);
    const results = run.id === selectedId ? selectedResults : [];
    const scenarioCount = runScenarioCount(run, columns, scenarios);
    const totals = runTotals(run, results, columns, scenarios);
    const selection = run.selection || run.scores?._selection || {};

    let delta = 'first run';
    let deltaColor = 'var(--color-text-muted)';
    if (run.status === 'failed') {
      delta = 'failed';
      deltaColor = 'var(--color-error)';
    } else if (inProgress(run)) {
      delta = run.status === 'pending' ? 'queued' : 'running';
    } else {
      const baseIndex = runs.findIndex((candidate, i) => i > index && candidate.status === 'complete');
      const base = baseIndex >= 0 ? runs[baseIndex] : null;
      if (base) {
        const baseColumns = modelColumns(base);
        const sameShape = runScenarioCount(base, baseColumns, scenarios) === scenarioCount && baseColumns.length === columns.length;
        if (sameShape) {
          const d = totals.passed - (base.samples_passed || 0);
          delta = `${d > 0 ? '+' : ''}${d} passed vs #${numberOf(baseIndex)}`;
          deltaColor = d > 0 ? 'var(--color-success)' : d < 0 ? 'var(--color-error)' : 'var(--color-text-muted)';
        } else {
          delta = 'partial run';
        }
      }
    }

    return {
      run,
      label: `#${numberOf(index)}`,
      when: timeAgo(run.completed_at || run.created_at),
      delta,
      deltaColor,
      note: `${agentName} · ${plural(scenarioCount, 'scenario')} × ${plural(columns.length, 'model')}${selection.group ? ` · ${selection.group}` : ''}`,
      bars: columns.map((label) => ({ label, ...modelPassStats(run, label, results, scenarioCount) })),
      selected: run.id === selectedId,
    };
  });

  return (
    <Panel title="Runs" meta={runsMeta(runs, runCount)} testId="suite-runs-panel">
      {rows.length === 0 && <Empty>[ ] no runs yet</Empty>}
      {rows.map((row) => (
        <div
          key={row.run.id}
          onClick={() => onSelect(row.run.id)}
          className={row.selected ? undefined : 'hover:bg-[var(--color-hover)]'}
          data-selected={row.selected ? 'true' : 'false'}
          style={{
            padding: '10px 12px 10px 10px', borderTop: '1px solid var(--color-border-light)', cursor: 'pointer',
            background: row.selected ? 'var(--color-muted)' : undefined,
            borderLeft: `2px solid ${row.selected ? 'var(--color-accent-ui)' : 'transparent'}`,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)' }}>{row.label}</span>
            <span style={{ fontSize: 11, color: 'var(--color-text-muted)' }}>{row.when}</span>
            <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, fontWeight: 600, color: row.deltaColor }}>{row.delta}</span>
          </div>
          <div style={{ ...mono(11), marginTop: 2, textWrap: 'pretty' }}>{row.note}</div>
          {row.bars.length > 0 && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4, marginTop: 8 }}>
              {row.bars.map((bar) => (
                <PassBar key={bar.label} label={splitModelLabel(bar.label).short} passed={bar.passed} total={bar.total} />
              ))}
            </div>
          )}
        </div>
      ))}
    </Panel>
  );
}

// ---------------------------------------------------------------------------
// MODELS

export function ModelsPanel({ run, columns, results = [], scenarioCount = 0, judgedBy, verdict }) {
  const summaries = run?.scores?._models || {};
  return (
    <Panel title="Models" meta={judgedBy ? `judged by ${judgedBy}` : null} testId="suite-models-panel">
      {columns.length === 0 && <Empty>[ ] no models scored yet</Empty>}
      {columns.map((label) => {
        const { short, provider } = describeModel(run, label);
        const stats = summaries[label];
        const { passed, total } = modelPassStats(run, label, results, scenarioCount);
        const ratio = total ? passed / total : 0;
        const color = TONE[toneFor(ratio)].strong;
        const faults = Object.entries(stats?.faults || {});
        const best = verdict?.winner === label;
        return (
          <div key={label} style={{ padding: '10px 12px', borderTop: '1px solid var(--color-border-light)', display: 'flex', flexDirection: 'column', gap: 6 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
              <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)' }} title={label}>{short}</span>
              {provider && <span style={mono(11)}>{provider}</span>}
              {best && <Badge tone="info" size={10} style={{ padding: '1px 6px' }} testId="judges-pick">judge's pick</Badge>}
              <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
                <span style={{ width: 120, height: 6, borderRadius: 999, background: 'var(--color-muted)', overflow: 'hidden' }}>
                  <span style={{ display: 'block', width: `${Math.round(ratio * 100)}%`, height: '100%', borderRadius: 999, background: color }} />
                </span>
                <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color }}>{`${passed}/${total}`}</span>
              </span>
            </div>
            <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)' }}>
              <span>score <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{stats?.avg_score != null ? Number(stats.avg_score).toFixed(3) : '—'}</span></span>
              <span>latency <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{fmtMs(stats?.avg_duration_ms)}</span></span>
              <span style={{ whiteSpace: 'nowrap' }}>
                <span style={{ color: 'var(--color-token-in)' }}>in</span> {fmtTokens(stats?.input_tokens)} · <span style={{ color: 'var(--color-token-out)' }}>out</span> {fmtTokens(stats?.output_tokens)}
              </span>
              <span>cost <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{fmtCost(stats?.cost)}</span></span>
            </div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {faults.map(([fault, count]) => (
                <Badge key={fault} tone="error">{`${faultName(fault)} ×${count}`}</Badge>
              ))}
              {stats && faults.length === 0 && (
                <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-success-text)' }}>[+] no faults</span>
              )}
              {!stats && inProgress(run) && <span style={mono(11)}>scoring…</span>}
            </div>
          </div>
        );
      })}
      {verdict?.rationale && (
        <div style={{ padding: '10px 12px', borderTop: '1px solid var(--color-border-light)', fontSize: 12, lineHeight: '18px', color: 'var(--color-text-cell)', textWrap: 'pretty' }}>
          <MicroLabel size={10} color="var(--color-text-muted)" style={{ marginRight: 8 }}>Verdict</MicroLabel>
          {verdict.rationale}
        </div>
      )}
    </Panel>
  );
}

// ---------------------------------------------------------------------------
// WHAT TO FIX

export function FixList({ items, columns = [], agentName, onNavigate, onOpenScenario }) {
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
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 12 }}>
      {items.map((item, index) => {
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
            {item.action && (
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 'auto', paddingTop: 2, flexWrap: 'wrap' }}>
                {item.action.path && (
                  <Button size="sm" onClick={() => onNavigate?.(item.action.path)}>{item.action.label}</Button>
                )}
                {item.action.hint && <span style={{ ...mono(11), whiteSpace: 'nowrap' }}>{item.action.hint}</span>}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------------------
// SCENARIOS matrix

const gridFor = (columns) => `minmax(240px, 1.6fr) 150px ${columns.map(() => 'minmax(170px, 1fr)').join(' ')}`;

// No result yet reads "…" while the run is still replaying it; a scenario
// outside the run's selection (or one whose replay never landed) reads "—".
function ResultCell({ result, expects, pending }) {
  if (!result) {
    return <span style={{ ...mono(12), fontWeight: 600 }}>{pending ? '…' : '—'}</span>;
  }
  if (!isSettled(result)) return <span style={{ ...mono(12), fontWeight: 600 }}>…</span>;
  const pass = isPassed(result);
  const color = pass ? 'var(--color-success)' : 'var(--color-error)';
  const calls = callList(result.tool_calls, expects);
  return (
    <div style={{ minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, flexWrap: 'wrap', fontFamily: MONO, fontSize: 12 }}>
        <span style={{ fontWeight: 700, color }}>{pass ? '[+]' : '[!]'}</span>
        <span style={{ fontWeight: 600, color }}>{fmtScore(result.score)}</span>
        {result.fault && <span style={{ fontSize: 11, color: 'var(--color-error-text)' }}>{faultName(result.fault)}</span>}
      </div>
      <CallLine calls={calls} empty="no tools called" />
    </div>
  );
}

// `rows` are the scenarios to show, in suite order, already filtered. Each
// carries `.key`, `.prompt`, `.group`, `.expectations`. Group rows are
// inserted where the group changes.
export function ScenarioMatrix({ rows, columns, run, resultsByKey, runKeys, running, openKey, onToggleRow, emptyLabel, renderDetail }) {
  const grid = gridFor(columns);
  const hasGroups = rows.some((s) => s.group);

  // Group rows in order of first appearance.
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

  return (
    <div style={{ border: '1px solid var(--color-border-light)', borderRadius: 10, overflowX: 'auto' }}>
      <div style={{ minWidth: Math.max(760, 400 + 180 * columns.length) }}>
        <div style={{ display: 'grid', gridTemplateColumns: grid, gap: 12, padding: '8px 12px', background: 'var(--color-muted)', alignItems: 'end' }}>
          <MicroLabel size={10} color="var(--color-text-muted)">Scenario</MicroLabel>
          <MicroLabel size={10} color="var(--color-text-muted)">Expects</MicroLabel>
          {columns.map((label) => {
            const { short, provider } = describeModel(run, label);
            return (
              <span key={label} style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }} title={label}>
                <span style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, color: 'var(--color-text-primary)' }}>{short}</span>
                <span style={mono(10)}>{provider || ' '}</span>
              </span>
            );
          })}
        </div>

        {groups.map((group) => {
          const inRun = group.rows.filter((s) => runKeys.has(s.key) || resultsByKey[s.key]);
          const passes = columns.map((label) => {
            const settled = inRun.filter((s) => isSettled(resultsByKey[s.key]?.[label]));
            const passed = settled.filter((s) => isPassed(resultsByKey[s.key][label])).length;
            const total = inRun.length;
            const color = total && passed === total ? 'var(--color-success-text)' : passed === 0 ? 'var(--color-error-text)' : 'var(--color-text-cell)';
            return { label, text: total ? `${passed}/${total} passed` : '—', color };
          });
          return (
            <div key={group.name || '__ungrouped'}>
              {(group.name || hasGroups) && (
                <div style={{ display: 'grid', gridTemplateColumns: grid, gap: 12, padding: '7px 12px', borderTop: '1px solid var(--color-border-light)', background: 'var(--color-background)', alignItems: 'center' }}>
                  <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)' }}>{group.name || 'ungrouped'}</span>
                  <span style={mono(11)}>{plural(group.rows.length, 'scenario')}</span>
                  {passes.map((p) => (
                    <span key={p.label} style={{ fontFamily: MONO, fontSize: 11, fontWeight: 600, color: p.color }}>{p.text}</span>
                  ))}
                </div>
              )}
              {group.rows.map((scenario) => {
                const open = openKey === scenario.key;
                const expects = scenario.expectations?.tools || [];
                const inSelection = runKeys.has(scenario.key) || Boolean(resultsByKey[scenario.key]);
                const disabled = scenario.enabled === false;
                return (
                  <div key={scenario.key}>
                    <div
                      data-testid="scenario-row"
                      data-scenario-key={scenario.key}
                      onClick={() => onToggleRow(scenario.key)}
                      className={open ? undefined : 'hover:bg-[var(--color-hover)]'}
                      style={{
                        display: 'grid', gridTemplateColumns: grid, gap: 12, padding: '10px 12px',
                        borderTop: '1px solid var(--color-border-light)', cursor: 'pointer',
                        background: open ? 'var(--color-muted)' : undefined,
                        opacity: disabled ? 0.5 : 1,
                      }}
                    >
                      <div style={{ minWidth: 0 }}>
                        <div style={{ ...mono(11), marginBottom: 2 }}>{`${scenario.key}${disabled ? ' · disabled' : ''}`}</div>
                        <div style={{ fontSize: 13, lineHeight: '18px', color: 'var(--color-text-primary)', textWrap: 'pretty' }}>{scenario.prompt}</div>
                      </div>
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, alignContent: 'flex-start', minWidth: 0 }}>
                        {expects.map((name) => (
                          <span key={name} style={{ fontFamily: MONO, fontSize: 11, padding: '2px 6px', border: '1px solid var(--color-border)', borderRadius: 4, color: 'var(--color-text-cell)', whiteSpace: 'nowrap' }}>{name}</span>
                        ))}
                        {expects.length === 0 && (scenario.expectations?.contains || []).map((pattern) => (
                          <span key={`contains-${pattern}`} style={{ fontFamily: MONO, fontSize: 11, padding: '2px 6px', border: '1px solid var(--color-border)', borderRadius: 4, color: 'var(--color-text-cell)', whiteSpace: 'nowrap' }} title="the answer must contain this">{`contains: ${pattern}`}</span>
                        ))}
                      </div>
                      {columns.map((label) => (
                        <ResultCell
                          key={label}
                          result={resultsByKey[scenario.key]?.[label]}
                          expects={expects}
                          pending={running && inSelection}
                        />
                      ))}
                    </div>
                    {open && renderDetail(scenario)}
                  </div>
                );
              })}
            </div>
          );
        })}
        {rows.length === 0 && (
          <Empty style={{ borderTop: '1px solid var(--color-border-light)' }}>{emptyLabel || '[+] nothing failed in this group'}</Empty>
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
  if (result.cost != null) parts.push(fmtCost(result.cost));
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
      {meta && <span style={{ marginLeft: 'auto', ...mono(11) }}>{meta}</span>}
    </>
  );
}

// `inRun` says whether the selected run covers this scenario: a scenario the
// run skipped offers a replay instead of empty result cards, and a suite with
// no run at all says so rather than blaming a run that never happened.
export function ScenarioDetail({ scenario, run, columns, resultsByKey, running, inRun = true, onRerun, onToggleEnabled, canMutate = true }) {
  const expects = scenario.expectations?.tools || [];
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
          This run used an earlier version of this question. Re-running uses the current catalog.
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
