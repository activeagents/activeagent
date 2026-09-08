import React, { useState, useEffect, useCallback, useMemo } from 'react';
import { dashboardPath, dashboardRelativePath, pushDashboardPath } from '../../utils/dashboardPath';
import { Button, Chip, Empty, MicroLabel, MonoLink, MONO } from './primitives';
import { fmtCost, fmtK, fmtMs, timeAgo } from '../../utils/format';
import {
  FixList, ModelsPanel, RunsPanel, ScenarioDetail, ScenarioMatrix,
  fixItemsFor, inProgress, isPassed, isSettled, labelForResult, modelColumns, plural,
  runScenarioCount, runScenarioKeys, runTotalOf, runTotals,
} from './EvaluationRunPanels';

// The expanded body of a scenario-suite evaluation, leading with three
// questions — is it getting better (Runs), which model (Models), what do I
// fix (What to fix) — then the scenario × model matrix that carries the
// evidence, a per-scenario drill-down, and the suite's controls: edit the
// pasted scenarios, run a group / everything / one scenario under chosen
// models, enable or disable a scenario, delete the suite.

const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content;

// Rebuilds the pasted form of a suite so it can be edited in place.
function scenariosToText(scenarios) {
  const lines = [];
  let group = null;
  scenarios.forEach((scenario) => {
    if ((scenario.group || '') !== (group || '')) {
      group = scenario.group;
      if (group) lines.push(`# ${group}`);
    }
    const options = [];
    const expectations = scenario.expectations || {};
    if (expectations.tools?.length) options.push(`tools: ${expectations.tools.join(', ')}`);
    if (expectations.contains?.length) options.push(`contains: ${expectations.contains.join(', ')}`);
    if (expectations.not_contains?.length) options.push(`not_contains: ${expectations.not_contains.join(', ')}`);
    options.push(`key: ${scenario.key}`);
    lines.push(`${scenario.prompt} | ${options.join(' | ')}`);
  });
  return lines.join('\n');
}

// In-app navigation to a dashboard route. Accepts a mount-relative path
// ("/tools") or one that already carries the mount.
export function navigateTo(path) {
  if (!path) return;
  const relative = dashboardRelativePath(path);
  pushDashboardPath(relative);
  window.dispatchEvent(new CustomEvent('dashboard:navigate', { detail: { path: dashboardPath(relative) } }));
}

const stripResults = (run) => {
  const { results, fix_items: fixItems, ...summary } = run;
  return summary;
};

const usageText = (usage) => {
  if (!usage) return null;
  const parts = [fmtCost(usage.cost), `${fmtK((usage.input_tokens || 0) + (usage.output_tokens || 0))} tokens`];
  if (usage.model_time_ms != null) parts.push(`model time ${fmtMs(usage.model_time_ms)}`);
  if (usage.runtime_ms != null) parts.push(`finished in ${fmtMs(usage.runtime_ms)}`);
  return parts.join(' · ');
};

const inputStyle = {
  padding: '6px 10px', borderRadius: 8, fontSize: 12, fontFamily: MONO,
  background: 'var(--color-card)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)',
};

export default function ScenarioSuitePanel({ evaluation, onChanged, onDelete, deleting = false }) {
  const evaluationId = evaluation.id;
  const agentName = evaluation.agent?.name || 'Agent';

  // The suite's scenarios and run history land with the first fetch; until
  // then the matrix shows a loading line rather than an empty suite.
  const [loaded, setLoaded] = useState(false);
  const [scenarios, setScenarios] = useState([]);
  const [groups, setGroups] = useState(evaluation.scenario_groups || []);
  const [runs, setRuns] = useState(evaluation.latest_run ? [evaluation.latest_run] : []);
  // The suite's total run count when the API reports it (`run_count`); the
  // run list itself is capped at the most recent RUNS_PAGE.
  const [runCount, setRunCount] = useState(null);
  const [selectedRunId, setSelectedRunId] = useState(evaluation.latest_run?.id ?? null);
  const [details, setDetails] = useState({});
  const [modelsInput, setModelsInput] = useState((evaluation.compare_models || []).join(', '));
  const [runError, setRunError] = useState(null);
  const [isRunning, setIsRunning] = useState(false);
  const [editing, setEditing] = useState(false);
  const [editText, setEditText] = useState('');
  const [editError, setEditError] = useState(null);
  const [groupFilter, setGroupFilter] = useState(null);
  const [failedOnly, setFailedOnly] = useState(false);
  const [openKey, setOpenKey] = useState(null);

  // --- data -------------------------------------------------------------

  const fetchScenarios = useCallback(async () => {
    const response = await fetch(`/api/evaluations/${evaluationId}/scenarios`);
    if (!response.ok) return;
    const data = await response.json();
    setScenarios(data.scenarios || []);
    setGroups(data.groups || []);
  }, [evaluationId]);

  // The suite with its scenarios and run history (the most recent RUNS_PAGE,
  // newest first, plus `run_count` — the total — when the API reports it).
  const fetchSuite = useCallback(async () => {
    try {
      const response = await fetch(`/api/evaluations/${evaluationId}`);
      if (!response.ok) return null;
      const data = await response.json();
      const suite = data.evaluation || {};
      setScenarios(suite.scenarios || []);
      setGroups(suite.scenario_groups || []);
      setRuns(suite.runs || []);
      setRunCount(Number.isFinite(suite.run_count) ? suite.run_count : null);
      return suite;
    } finally {
      setLoaded(true);
    }
  }, [evaluationId]);

  const fetchRunDetail = useCallback(async (runId) => {
    if (!runId) return null;
    const response = await fetch(`/api/evaluations/${evaluationId}/runs/${runId}`);
    if (!response.ok) return null;
    const data = await response.json();
    const run = data.run;
    if (!run) return null;
    setDetails((prev) => ({ ...prev, [run.id]: run }));
    setRuns((prev) => prev.map((r) => (r.id === run.id ? { ...r, ...stripResults(run) } : r)));
    return run;
  }, [evaluationId]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const suite = await fetchSuite();
      if (cancelled) return;
      const latestId = suite?.runs?.[0]?.id ?? null;
      setSelectedRunId((current) => (current && suite?.runs?.some((r) => r.id === current) ? current : latestId));
      if (latestId) fetchRunDetail(latestId);
    })();
    return () => { cancelled = true; };
  }, [fetchSuite, fetchRunDetail]);

  // A run started elsewhere (the page header, another tab) shows up as a new
  // latest run on the evaluation; pick it up.
  const latestFromParent = evaluation.latest_run?.id ?? null;
  useEffect(() => {
    if (!latestFromParent || runs.some((r) => r.id === latestFromParent)) return;
    fetchSuite();
  }, [latestFromParent, runs, fetchSuite]);

  const selectedRun = details[selectedRunId] || runs.find((r) => r.id === selectedRunId) || null;
  const latestRun = runs[0] || null;

  // A run replays every scenario through the provider, so it finishes in the
  // background; poll the run being viewed (or the latest, when that is the
  // one still going) until it settles.
  const pollId = inProgress(selectedRun) ? selectedRun.id : inProgress(latestRun) ? latestRun.id : null;
  useEffect(() => {
    if (!pollId) return undefined;
    const timer = setInterval(async () => {
      const latest = await fetchRunDetail(pollId);
      if (latest && !inProgress(latest)) {
        clearInterval(timer);
        await fetchSuite();
        onChanged?.();
      }
    }, 3000);
    return () => clearInterval(timer);
  }, [pollId, fetchRunDetail, fetchSuite, onChanged]);

  // --- actions ----------------------------------------------------------

  const selectedModels = modelsInput.split(',').map((m) => m.trim()).filter(Boolean);

  const startRun = async (selection) => {
    setIsRunning(true);
    setRunError(null);
    try {
      const response = await fetch(`/api/evaluations/${evaluationId}/run`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken() },
        body: JSON.stringify({ ...selection, models: selectedModels }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error((data.errors || [data.error]).filter(Boolean).join(', ') || 'Run failed to start');
      const run = data.run;
      setRuns((prev) => [run, ...prev.filter((r) => r.id !== run.id)]);
      setRunCount((count) => (count == null ? null : count + 1));
      setDetails((prev) => ({ ...prev, [run.id]: { ...run, results: [] } }));
      setSelectedRunId(run.id);
      setOpenKey(null);
      onChanged?.();
    } catch (error) {
      setRunError(error.message);
    } finally {
      setIsRunning(false);
    }
  };

  const selectRun = (runId) => {
    setSelectedRunId(runId);
    setOpenKey(null);
    if (!details[runId]) fetchRunDetail(runId);
  };

  const toggleScenario = async (scenario) => {
    if (!scenario.id) return;
    await fetch(`/api/evaluations/${evaluationId}/scenarios/${scenario.id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken() },
      body: JSON.stringify({ scenario: { enabled: scenario.enabled === false } }),
    });
    await fetchScenarios();
  };

  const saveScenarios = async () => {
    setEditError(null);
    const response = await fetch(`/api/evaluations/${evaluationId}/scenarios`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken() },
      body: JSON.stringify({ scenarios_text: editText }),
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      setEditError((data.errors || [data.error]).filter(Boolean).join(', ') || 'Could not save scenarios');
      return;
    }
    setScenarios(data.scenarios || []);
    setGroups(data.groups || []);
    setEditing(false);
    onChanged?.();
  };

  // --- derivations ------------------------------------------------------

  const run = selectedRun;
  const results = useMemo(() => (run?.results || []).filter((r) => r && r.scenario_key), [run]);
  const columns = useMemo(() => modelColumns(run, results, evaluation), [run, results, evaluation]);
  const resultsByKey = useMemo(() => results.reduce((acc, result) => {
    (acc[result.scenario_key] ||= {})[labelForResult(run, result)] = result;
    return acc;
  }, {}), [results, run]);
  const runKeys = useMemo(() => new Set(runScenarioKeys(run, scenarios)), [run, scenarios]);
  const running = inProgress(run);
  const scenarioCount = runScenarioCount(run, columns, scenarios);
  const totals = runTotals(run, results, columns, scenarios);

  // Scenarios the selected run covers, in suite order; a result whose
  // scenario has since been removed from the suite still renders from what
  // the result recorded about it.
  const runScenarios = useMemo(() => {
    if (!run) return scenarios;
    const covered = scenarios.filter((s) => runKeys.has(s.key) || resultsByKey[s.key]);
    const known = new Set(scenarios.map((s) => s.key));
    const orphans = Object.keys(resultsByKey).filter((key) => !known.has(key)).map((key) => {
      const first = Object.values(resultsByKey[key])[0];
      return { id: null, key, prompt: first.prompt, group: first.group, expectations: {}, enabled: true, orphan: true };
    });
    return [...covered, ...orphans];
  }, [run, scenarios, runKeys, resultsByKey]);

  const failedOn = (scenario) => columns.some((label) => {
    const result = resultsByKey[scenario.key]?.[label];
    return isSettled(result) && !isPassed(result);
  });
  const visibleRows = runScenarios
    .filter((s) => !groupFilter || (s.group || '') === groupFilter)
    .filter((s) => !failedOnly || failedOn(s));

  const runIndex = runs.findIndex((r) => r.id === run?.id);
  const latestNumber = runTotalOf(runs, runCount);
  const runNumber = runIndex >= 0 ? latestNumber - runIndex : null;
  const groupCount = new Set(runScenarios.map((s) => s.group).filter(Boolean)).size;
  const settledCount = results.filter(isSettled).length;
  const expectedResults = scenarioCount * Math.max(columns.length, 1);
  const faultScenarios = new Set(results.filter((r) => isSettled(r) && !isPassed(r)).map((r) => r.scenario_key)).size;
  const verdict = run?.scores?._verdict || null;
  const judgedBy = (verdict?.judge && verdict.judge !== 'pass rate') ? verdict.judge : (evaluation.judge_model || 'rules');
  const fixItems = useMemo(() => (run ? fixItemsFor(run, results) : []), [run, results]);
  const criteriaKeys = Object.keys(run?.scores || {}).filter((key) => !key.startsWith('_'));
  const criteriaText = (criteriaKeys.length ? criteriaKeys : (evaluation.criteria || []).map((c) => c.key))
    .map((key) => String(key).replace(/_/g, ' ')).join(' · ') || '—';

  // Until the suite has loaded, the counts the index already knows stand in
  // for the scenario list.
  const scenarioTotal = loaded ? scenarios.length : (evaluation.scenario_count ?? 0);
  const enabledCount = loaded
    ? scenarios.filter((s) => s.enabled !== false && (!groupFilter || (s.group || '') === groupFilter)).length
    : scenarioTotal;
  const runLabel = `Run ${plural(enabledCount, 'scenario')}${selectedModels.length ? ` × ${plural(selectedModels.length, 'model')}` : ''}`;

  const summary = run
    ? [
      runIndex > 0 ? `Viewing run #${runNumber} (latest is #${latestNumber})` : `Run #${runNumber ?? '?'} · ${timeAgo(run.completed_at || run.created_at)}`,
      agentName,
      `${plural(scenarioCount, 'scenario')}${groupCount ? ` in ${plural(groupCount, 'group')}` : ''} × ${plural(columns.length, 'model')}`,
      run.status === 'failed' ? 'failed' : `${totals.passed}/${totals.total} passed`,
    ].join(' · ')
    : `${agentName} · ${plural(scenarioTotal, 'scenario')}${groups.length ? ` in ${plural(groups.length, 'group')}` : ''} · ${loaded ? 'no runs yet' : 'loading…'}`;

  const reportPath = run && run.status === 'complete' ? `/evaluations/${evaluationId}/runs/${run.id}/report` : null;

  const groupChips = [{ label: `All ${scenarioTotal}`, value: null }]
    .concat(groups.map((group) => ({ label: loaded ? `${group} ${scenarios.filter((s) => s.group === group).length}` : group, value: group })));

  const suiteEmpty = scenarios.length === 0 && runScenarios.length === 0;

  const emptyLabel = failedOnly
    ? '[+] nothing failed in this group'
    : groupFilter && run ? '[ ] not part of this run' : '[ ] no scenarios';

  // --- render -----------------------------------------------------------

  return (
    <div style={{ padding: 16, display: 'flex', flexDirection: 'column', gap: 16 }} data-testid="scenario-suite-panel">
      {/* Summary row */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <span style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>{summary}</span>
        {running && (
          <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }} data-testid="suite-run-progress">
            {`running · ${settledCount} of ${expectedResults} results in`}
          </span>
        )}
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <Button size="sm" onClick={() => { setEditText(scenariosToText(scenarios)); setEditError(null); setEditing(!editing); }}>
            {editing ? 'Cancel' : 'Edit scenarios'}
          </Button>
          <input
            type="text"
            value={modelsInput}
            onChange={(e) => setModelsInput(e.target.value)}
            placeholder="models, e.g. gpt-5-mini, ollama/qwen3:8b"
            style={{ ...inputStyle, width: 250 }}
            title="Comma-separated. Prefix with a provider (ollama/qwen3:8b) when the name alone is ambiguous; blank runs the agent's own model."
          />
          <Button
            variant="primary"
            size="sm"
            disabled={isRunning || !loaded || enabledCount === 0}
            onClick={() => startRun(groupFilter ? { group: groupFilter } : {})}
            testId="suite-run-button"
          >
            {isRunning ? 'Starting…' : runLabel}
          </Button>
        </span>
      </div>

      {(runError || run?.status === 'failed') && (
        <div style={{ fontSize: 13, color: 'var(--color-error-text)', background: 'var(--color-error-soft)', borderRadius: 8, padding: '8px 12px' }}>
          {runError || `Run failed: ${run.error_message || 'unknown error'}`}
        </div>
      )}

      {editing && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <textarea
            value={editText}
            onChange={(e) => setEditText(e.target.value)}
            rows={Math.min(Math.max(scenarios.length + 4, 6), 24)}
            style={{ ...inputStyle, width: '100%', boxSizing: 'border-box', lineHeight: '18px' }}
          />
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, fontSize: 12, color: 'var(--color-text-muted)', flexWrap: 'wrap' }}>
            <span style={{ flex: 1, minWidth: 240 }}>
              One message per line. <code style={{ fontFamily: MONO }}># Heading</code> starts a group; <code style={{ fontFamily: MONO }}>| tools: a, b</code>, <code style={{ fontFamily: MONO }}>| contains: x</code>, <code style={{ fontFamily: MONO }}>| not_contains: y</code> set expectations. Keep a scenario's <code style={{ fontFamily: MONO }}>key</code> to keep its history.
            </span>
            <Button variant="primary" size="sm" onClick={saveScenarios}>Save scenarios</Button>
          </div>
          {editError && <div style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{editError}</div>}
        </div>
      )}

      {/* Runs | Models */}
      <div style={{ display: 'grid', gridTemplateColumns: 'minmax(280px, 2fr) minmax(0, 3fr)', gap: 16, alignItems: 'start' }}>
        <RunsPanel runs={runs} runCount={runCount} selectedId={run?.id ?? null} onSelect={selectRun} agentName={agentName} selectedResults={results} scenarios={scenarios} />
        <ModelsPanel run={run} columns={run ? columns : []} results={results} scenarioCount={scenarioCount} judgedBy={judgedBy} verdict={verdict} />
      </div>

      {/* What to fix */}
      {run && run.status !== 'failed' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
            <MicroLabel>What to fix</MicroLabel>
            <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
              {`${plural(fixItems.length, 'item')} · ${plural(Math.max(totals.total - totals.passed, 0), 'fault')} across ${plural(faultScenarios, 'scenario')}`}
            </span>
          </div>
          {fixItems.length > 0 ? (
            <FixList items={fixItems} columns={columns} agentName={agentName} onNavigate={navigateTo} />
          ) : (
            <Empty style={{ border: '1px solid var(--color-border-light)', borderRadius: 10, padding: '14px 12px' }}>
              {running ? '[ ] scoring…' : '[+] nothing to fix'}
            </Empty>
          )}
        </div>
      )}

      {/* Scenarios */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <MicroLabel style={{ marginRight: 4 }}>Scenarios</MicroLabel>
          {groupChips.map((chip) => (
            <Chip key={chip.label} selected={groupFilter === chip.value} onClick={() => setGroupFilter(chip.value)}>{chip.label}</Chip>
          ))}
          <Chip
            square
            mono
            selected={failedOnly}
            onClick={() => setFailedOnly(!failedOnly)}
            style={{ marginLeft: 'auto', background: 'transparent' }}
            title="Hide scenarios that passed on every model"
          >
            {failedOnly ? '[x] failed only' : '[ ] failed only'}
          </Chip>
        </div>

        {suiteEmpty && !loaded ? (
          <Empty style={{ border: '1px solid var(--color-border-light)', borderRadius: 10 }}>loading…</Empty>
        ) : suiteEmpty ? (
          <Empty style={{ border: '1px solid var(--color-border-light)', borderRadius: 10 }}>No scenarios yet — paste some with “Edit scenarios”.</Empty>
        ) : (
          <ScenarioMatrix
            rows={visibleRows}
            columns={run ? columns : []}
            run={run}
            resultsByKey={resultsByKey}
            runKeys={runKeys}
            running={running}
            openKey={openKey}
            onToggleRow={(key) => setOpenKey(openKey === key ? null : key)}
            emptyLabel={emptyLabel}
            renderDetail={(scenario) => (
              <ScenarioDetail
                scenario={scenario}
                run={run}
                columns={run ? columns : []}
                resultsByKey={resultsByKey}
                running={running}
                canMutate={!scenario.orphan}
                onRerun={(s) => startRun({ keys: [s.key] })}
                onToggleEnabled={toggleScenario}
              />
            )}
          />
        )}
      </div>

      {/* Footer */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, flexWrap: 'wrap', paddingTop: 12, borderTop: '1px solid var(--color-border-light)', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
        <span style={{ whiteSpace: 'nowrap' }}>{`judge ${judgedBy}`}</span>
        <span style={{ minWidth: 0, textWrap: 'pretty' }}>{`criteria ${criteriaText}`}</span>
        {run?.usage && <span style={{ whiteSpace: 'nowrap' }} title="Estimated cost, tokens and model time of this run">{usageText(run.usage)}</span>}
        {reportPath && (
          <MonoLink href={dashboardPath(reportPath)} onClick={() => navigateTo(reportPath)} title="The run rendered as a report page">run report</MonoLink>
        )}
        {onDelete && (
          <button
            type="button"
            onClick={onDelete}
            disabled={deleting}
            title="Delete this suite and its runs"
            style={{ marginLeft: 'auto', background: 'transparent', border: 'none', padding: 0, cursor: deleting ? 'not-allowed' : 'pointer', fontFamily: MONO, fontSize: 11, color: 'var(--color-error)', opacity: deleting ? 0.5 : 1 }}
          >
            {deleting ? 'Deleting…' : 'Delete suite'}
          </button>
        )}
      </div>
    </div>
  );
}
