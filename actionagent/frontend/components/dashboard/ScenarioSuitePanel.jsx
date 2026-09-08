import { dashboardPath } from '../../utils/dashboardPath';
import React, { useState, useEffect, useCallback, useRef } from 'react';

// The expanded body of a scenario-suite evaluation: the suite's scenarios
// grouped as they were pasted, controls to run a group / one scenario under
// chosen models, and the latest run rendered as a scenario × model matrix
// with each failing cell's fault and recommended fix.

const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content;

const STATUS_COLOR = { passed: '#22c55e', failed: '#ef4444', errored: '#f97316', pending: '#9ca3af' };

const FAULT_LABEL = {
  run_error: 'Run error',
  tool_error: 'Tool error',
  missing_capability: 'Missing capability',
  expected_tool_not_called: 'Tool not called',
  forbidden_content: 'Forbidden content',
  missing_content: 'Missing content',
  low_quality: 'Low quality',
};

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

const formatMs = (ms) => (ms == null ? '—' : ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${ms}ms`);
const formatCost = (cost) => (cost == null ? '—' : `$${Number(cost).toFixed(4)}`);
const formatTokens = (n) => (n == null ? '—' : n >= 10000 ? `${(n / 1000).toFixed(1)}K` : `${n}`);

export default function ScenarioSuitePanel({ evaluation, colors, darkMode, onChanged }) {
  const [scenarios, setScenarios] = useState([]);
  const [groups, setGroups] = useState(evaluation.scenario_groups || []);
  const [selectedGroup, setSelectedGroup] = useState(null);
  const [modelsInput, setModelsInput] = useState((evaluation.compare_models || []).join(', '));
  const [run, setRun] = useState(null);
  const [runError, setRunError] = useState(null);
  const [isRunning, setIsRunning] = useState(false);
  const [editing, setEditing] = useState(false);
  const [editText, setEditText] = useState('');
  const [editError, setEditError] = useState(null);
  const [expandedKey, setExpandedKey] = useState(null);
  const pollTimer = useRef(null);

  const fetchScenarios = useCallback(async () => {
    const response = await fetch(`/api/evaluations/${evaluation.id}/scenarios`);
    if (!response.ok) return;
    const data = await response.json();
    setScenarios(data.scenarios || []);
    setGroups(data.groups || []);
  }, [evaluation.id]);

  const fetchRun = useCallback(async (runId) => {
    if (!runId) return null;
    const response = await fetch(`/api/evaluations/${evaluation.id}/runs/${runId}`);
    if (!response.ok) return null;
    const data = await response.json();
    setRun(data.run);
    return data.run;
  }, [evaluation.id]);

  useEffect(() => {
    fetchScenarios();
    fetchRun(evaluation.latest_run?.id);
  }, [fetchScenarios, fetchRun, evaluation.latest_run?.id]);

  // A run replays every scenario through the provider, so it finishes in the
  // background; results appear as each replay lands.
  useEffect(() => {
    clearTimeout(pollTimer.current);
    if (!run || !['pending', 'running'].includes(run.status)) return undefined;
    pollTimer.current = setTimeout(async () => {
      const latest = await fetchRun(run.id);
      if (latest && !['pending', 'running'].includes(latest.status)) onChanged?.();
    }, 3000);
    return () => clearTimeout(pollTimer.current);
  }, [run, fetchRun, onChanged]);

  const selectedModels = modelsInput.split(',').map((m) => m.trim()).filter(Boolean);
  const visibleScenarios = selectedGroup ? scenarios.filter((s) => s.group === selectedGroup) : scenarios;
  const enabledCount = visibleScenarios.filter((s) => s.enabled).length;

  const startRun = async (selection) => {
    setIsRunning(true);
    setRunError(null);
    try {
      const response = await fetch(`/api/evaluations/${evaluation.id}/run`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken() },
        body: JSON.stringify({ ...selection, models: selectedModels }),
      });
      const data = await response.json();
      if (!response.ok) throw new Error((data.errors || [data.error]).filter(Boolean).join(', ') || 'Run failed to start');
      setRun({ ...data.run, results: [] });
      setExpandedKey(null);
    } catch (error) {
      setRunError(error.message);
    } finally {
      setIsRunning(false);
    }
  };

  const toggleScenario = async (scenario) => {
    await fetch(`/api/evaluations/${evaluation.id}/scenarios/${scenario.id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken() },
      body: JSON.stringify({ scenario: { enabled: !scenario.enabled } }),
    });
    await fetchScenarios();
  };

  const saveScenarios = async () => {
    setEditError(null);
    const response = await fetch(`/api/evaluations/${evaluation.id}/scenarios`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken() },
      body: JSON.stringify({ scenarios_text: editText }),
    });
    const data = await response.json();
    if (!response.ok) {
      setEditError((data.errors || [data.error]).filter(Boolean).join(', ') || 'Could not save scenarios');
      return;
    }
    setScenarios(data.scenarios || []);
    setGroups(data.groups || []);
    setEditing(false);
    onChanged?.();
  };

  const results = run?.results || [];
  const selectionModels = run?.selection?.models || [];
  const labelFor = (result) =>
    selectionModels.find((m) => m.model === result.model && m.provider === result.provider)?.label || result.model;
  const columns = run?.models?.length
    ? run.models
    : [...new Set(results.map(labelFor))];
  const resultsByKey = results.reduce((acc, result) => {
    (acc[result.scenario_key] ||= {})[labelFor(result)] = result;
    return acc;
  }, {});
  const runScenarioKeys = run?.selection?.scenario_keys || [];
  const matrixScenarios = run
    ? scenarios.filter((s) => runScenarioKeys.includes(s.key) || resultsByKey[s.key])
    : [];
  const inProgress = run && ['pending', 'running'].includes(run.status);
  const expectedResults = runScenarioKeys.length * Math.max(columns.length, 1);
  const modelSummaries = run?.scores?._models || {};
  const recommendations = run?.scores?._recommendations || [];
  const verdict = run?.scores?._verdict;

  const chipStyle = (active) => ({
    padding: '4px 10px', borderRadius: '999px', fontSize: '12px', cursor: 'pointer',
    border: `1px solid ${active ? '#ef4444' : colors.cardBorder}`,
    background: active ? (darkMode ? 'rgba(239,68,68,0.15)' : '#fef2f2') : 'transparent',
    color: active ? '#ef4444' : colors.textSecondary,
  });
  const inputStyle = {
    padding: '6px 10px', borderRadius: '8px', fontSize: '13px',
    background: colors.inputBg, border: `1px solid ${colors.inputBorder}`, color: colors.textPrimary,
  };
  const buttonStyle = 'px-3 py-1.5 text-sm bg-red-500 text-white rounded-lg hover:bg-red-600 transition-colors disabled:opacity-50';
  const subtleButton = 'px-3 py-1.5 text-sm bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 transition-colors disabled:opacity-50';

  let groupHeader = null;

  return (
    <div className="p-4 space-y-4" data-testid="scenario-suite-panel">
      {/* Selection controls */}
      <div className="flex flex-wrap items-center gap-2">
        <span style={chipStyle(!selectedGroup)} onClick={() => setSelectedGroup(null)}>All ({scenarios.length})</span>
        {groups.map((group) => (
          <span key={group} style={chipStyle(selectedGroup === group)} onClick={() => setSelectedGroup(group)}>
            {group} ({scenarios.filter((s) => s.group === group).length})
          </span>
        ))}
        <div className="flex-1" />
        <input
          type="text"
          value={modelsInput}
          onChange={(e) => setModelsInput(e.target.value)}
          placeholder={`models to compare, e.g. ${evaluation.agent?.name ? 'claude-sonnet-5, qwen3:8b' : ''}`}
          style={{ ...inputStyle, minWidth: '260px' }}
          title="Comma-separated. Prefix with a provider (ollama/qwen3:8b) when the name alone is ambiguous; blank runs the agent's own model."
        />
        <button
          className={buttonStyle}
          disabled={isRunning || enabledCount === 0}
          onClick={() => startRun(selectedGroup ? { group: selectedGroup } : {})}
        >
          {isRunning ? 'Starting…' : `Run ${enabledCount} scenario${enabledCount === 1 ? '' : 's'}${selectedModels.length > 1 ? ` × ${selectedModels.length} models` : ''}`}
        </button>
        <button
          className={subtleButton}
          onClick={() => { setEditText(scenariosToText(scenarios)); setEditing(!editing); }}
        >
          {editing ? 'Cancel' : 'Edit scenarios'}
        </button>
      </div>

      {runError && <div className="text-sm text-red-500">{runError}</div>}

      {editing && (
        <div className="space-y-2">
          <textarea
            value={editText}
            onChange={(e) => setEditText(e.target.value)}
            rows={Math.min(Math.max(scenarios.length + 4, 6), 24)}
            style={{ ...inputStyle, width: '100%', fontFamily: 'monospace', fontSize: '12px' }}
          />
          <div className="flex items-center gap-3 text-xs" style={{ color: colors.textMuted }}>
            <span>One message per line. <code># Heading</code> starts a group; <code>| tools: a, b</code>, <code>| contains: x</code>, <code>| not_contains: y</code> set expectations. Keep a scenario's <code>key</code> to keep its history.</span>
            <div className="flex-1" />
            <button className={buttonStyle} onClick={saveScenarios}>Save scenarios</button>
          </div>
          {editError && <div className="text-sm text-red-500">{editError}</div>}
        </div>
      )}

      {/* Run status */}
      {run && (
        <div className="text-xs flex items-center gap-3" style={{ color: colors.textMuted }}>
          <span>
            {inProgress
              ? `Running… ${results.length} of ${expectedResults} results in`
              : run.status === 'failed'
                ? `Run failed: ${run.error_message}`
                : `Last run: ${runScenarioKeys.length} scenario${runScenarioKeys.length === 1 ? '' : 's'}${run.selection?.group ? ` in ${run.selection.group}` : ''} × ${columns.length} model${columns.length === 1 ? '' : 's'} — ${run.samples_passed} passed`}
          </span>
          {!inProgress && run.status !== 'failed' && (
            <a
              href={dashboardPath(`/api/evaluations/${evaluation.id}/runs/${run.id}/report`)}
              target="_blank"
              rel="noreferrer"
              className="underline"
              title="The run as a self-contained report page — save it to export"
            >
              View report
            </a>
          )}
          {!inProgress && run.status !== 'failed' && run.usage && (
            <span>
              {formatCost(run.usage.cost)} · {formatTokens((run.usage.input_tokens || 0) + (run.usage.output_tokens || 0))} tokens
              ({formatTokens(run.usage.input_tokens)} in / {formatTokens(run.usage.output_tokens)} out)
              · model time {formatMs(run.usage.model_time_ms)}
              {run.usage.runtime_ms != null ? ` · finished in ${formatMs(run.usage.runtime_ms)}` : ''}
            </span>
          )}
          {inProgress && <span className="animate-spin inline-block rounded-full h-3 w-3 border-b-2 border-red-500" />}
        </div>
      )}

      {/* Per-model summary */}
      {Object.keys(modelSummaries).length > 0 && (
        <div className="grid gap-3" style={{ gridTemplateColumns: `repeat(${Math.min(Object.keys(modelSummaries).length, 4)}, minmax(0, 1fr))` }}>
          {Object.entries(modelSummaries).map(([label, stats]) => (
            <div key={label} className="rounded-lg p-3 border" style={{ borderColor: verdict?.winner === label ? '#22c55e' : colors.cardBorder, background: colors.innerBg }}>
              <div className="font-mono text-xs truncate" style={{ color: colors.textPrimary }} title={label}>{label}</div>
              <div className="text-2xl font-bold" style={{ color: stats.pass_rate >= 85 ? '#22c55e' : stats.pass_rate >= 60 ? '#eab308' : '#ef4444' }}>
                {stats.pass_rate}%
              </div>
              <div className="text-xs" style={{ color: colors.textSecondary }}>
                {stats.passed}/{stats.scenarios} passed · score {stats.avg_score ?? '—'} · {formatMs(stats.avg_duration_ms)} · {formatCost(stats.cost)}
              </div>
              {Object.keys(stats.faults || {}).length > 0 && (
                <div className="text-[11px] mt-1" style={{ color: colors.textMuted }}>
                  {Object.entries(stats.faults).map(([fault, count]) => `${FAULT_LABEL[fault] || fault} ×${count}`).join(' · ')}
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* Recommendations */}
      {recommendations.length > 0 && (
        <div className="rounded-lg border p-3 space-y-2" style={{ borderColor: colors.cardBorder }}>
          <div className="text-xs uppercase tracking-wide" style={{ color: colors.textMuted }}>Recommendations</div>
          {recommendations.map((entry) => (
            <div key={entry.fault} className="text-sm" data-testid="scenario-recommendation">
              <span className="px-2 py-0.5 rounded text-xs font-medium" style={{ background: darkMode ? 'rgba(239,68,68,0.15)' : '#fef2f2', color: '#ef4444' }}>
                {FAULT_LABEL[entry.fault] || entry.fault} ×{entry.count}
              </span>
              <span className="ml-2" style={{ color: colors.textPrimary }}>{entry.recommendation}</span>
              <div className="text-xs mt-0.5" style={{ color: colors.textMuted }}>
                {entry.scenario_keys.join(', ')}{entry.models?.length > 1 ? ` · ${entry.models.join(', ')}` : ''}
                {entry.suggested_tools?.length > 0 && (
                  <span> · suggested tool{entry.suggested_tools.length > 1 ? 's' : ''}: {entry.suggested_tools.map((t) => t.name).join(', ')}</span>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Scenario × model matrix */}
      <div className="overflow-x-auto">
        <table className="w-full text-sm" style={{ borderCollapse: 'separate', borderSpacing: 0 }}>
          <thead>
            <tr style={{ color: colors.textMuted }}>
              <th className="text-left font-normal text-xs uppercase tracking-wide py-1 pr-2">Scenario</th>
              {columns.map((label) => (
                <th key={label} className="text-center font-mono text-xs py-1 px-2" title={label}>{label}</th>
              ))}
              <th className="w-16" />
            </tr>
          </thead>
          <tbody>
            {(run ? matrixScenarios : visibleScenarios).flatMap((scenario) => {
              const rows = [];
              if ((scenario.group || '') !== (groupHeader || '')) {
                groupHeader = scenario.group;
                if (groupHeader) {
                  rows.push(
                    <tr key={`group-${groupHeader}`}>
                      <td colSpan={columns.length + 2} className="pt-3 pb-1 text-xs font-semibold" style={{ color: colors.textSecondary }}>{groupHeader}</td>
                    </tr>
                  );
                }
              }
              const isExpanded = expandedKey === scenario.key;
              rows.push(
                <tr
                  key={scenario.key}
                  data-testid="scenario-row"
                  className="cursor-pointer"
                  style={{ opacity: scenario.enabled ? 1 : 0.45, background: isExpanded ? colors.innerBg : 'transparent' }}
                  onClick={() => setExpandedKey(isExpanded ? null : scenario.key)}
                >
                  <td className="py-1.5 pr-2" style={{ color: colors.textPrimary }}>
                    <span className="font-mono text-[11px] mr-2" style={{ color: colors.textMuted }}>{scenario.key}</span>
                    {scenario.prompt}
                    {scenario.expectations?.tools?.length > 0 && (
                      <span className="ml-2 text-[11px]" style={{ color: colors.textMuted }}>expects {scenario.expectations.tools.join('/')}</span>
                    )}
                  </td>
                  {columns.map((label) => {
                    const result = resultsByKey[scenario.key]?.[label];
                    return (
                      <td key={label} className="text-center py-1.5 px-2">
                        {result ? (
                          <span
                            className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium"
                            style={{ color: STATUS_COLOR[result.status], background: `${STATUS_COLOR[result.status]}22` }}
                            title={result.fault ? `${FAULT_LABEL[result.fault]}: ${result.recommendation || ''}` : 'Passed'}
                          >
                            {result.status === 'passed' ? '✓' : result.status === 'errored' ? '!' : '✗'}
                            {result.score != null && <span>{result.score.toFixed(2)}</span>}
                            {result.fault && <span className="font-normal">· {FAULT_LABEL[result.fault]}</span>}
                          </span>
                        ) : (
                          <span style={{ color: colors.textMuted }}>{inProgress && runScenarioKeys.includes(scenario.key) ? '…' : '—'}</span>
                        )}
                      </td>
                    );
                  })}
                  <td className="text-right py-1.5 whitespace-nowrap">
                    <button
                      className="text-xs px-2 py-0.5 rounded hover:bg-gray-200"
                      style={{ color: colors.textSecondary }}
                      title={scenario.enabled ? 'Disable this scenario' : 'Enable this scenario'}
                      onClick={(e) => { e.stopPropagation(); toggleScenario(scenario); }}
                    >
                      {scenario.enabled ? 'on' : 'off'}
                    </button>
                    <button
                      className="text-xs px-2 py-0.5 rounded hover:bg-gray-200"
                      style={{ color: '#ef4444' }}
                      disabled={isRunning}
                      title="Run only this scenario under the selected models"
                      onClick={(e) => { e.stopPropagation(); startRun({ keys: [scenario.key] }); }}
                    >
                      run
                    </button>
                  </td>
                </tr>
              );
              if (isExpanded) {
                rows.push(
                  <tr key={`${scenario.key}-detail`}>
                    <td colSpan={columns.length + 2} className="pb-3">
                      <div className="rounded-lg border p-3 space-y-3" style={{ borderColor: colors.cardBorder }}>
                        {scenario.notes && <div className="text-xs italic" style={{ color: colors.textMuted }}>{scenario.notes}</div>}
                        {columns.map((label) => {
                          const result = resultsByKey[scenario.key]?.[label];
                          if (!result) return null;
                          return (
                            <div key={label} className="space-y-1" data-testid="scenario-result-detail">
                              <div className="flex items-center gap-2 text-xs">
                                <span className="font-mono" style={{ color: colors.textPrimary }}>{label}</span>
                                <span style={{ color: STATUS_COLOR[result.status] }}>{result.status}</span>
                                <span style={{ color: colors.textMuted }}>
                                  {formatMs(result.duration_ms)} · {(result.input_tokens || 0) + (result.output_tokens || 0)} tokens · {formatCost(result.cost)}
                                </span>
                                {result.tool_calls?.length > 0 && (
                                  <span style={{ color: colors.textMuted }}>
                                    tools: {result.tool_calls.map((call) => `${call.name}${call.error ? ' ✗' : ''}`).join(', ')}
                                  </span>
                                )}
                              </div>
                              {result.fault && (
                                <div className="text-xs p-2 rounded" style={{ background: darkMode ? 'rgba(239,68,68,0.1)' : '#fef2f2', color: colors.textPrimary }}>
                                  <span className="font-semibold" style={{ color: '#ef4444' }}>{FAULT_LABEL[result.fault]}.</span>{' '}
                                  {result.diagnosis?.summary}{' '}
                                  <span style={{ color: colors.textSecondary }}>{result.recommendation}</span>
                                  {result.diagnosis?.judge?.suggested_tool && (
                                    <div className="mt-1 font-mono">
                                      suggested tool: {result.diagnosis.judge.suggested_tool.name} — {result.diagnosis.judge.suggested_tool.description}
                                    </div>
                                  )}
                                  {result.diagnosis?.judge?.instruction_change && (
                                    <div className="mt-1">instruction change: “{result.diagnosis.judge.instruction_change}”</div>
                                  )}
                                </div>
                              )}
                              <pre className="text-xs whitespace-pre-wrap p-2 rounded" style={{ background: colors.innerBg, color: colors.textSecondary, maxHeight: '240px', overflow: 'auto' }}>
                                {result.output || result.error_message || '(no answer)'}
                              </pre>
                              {result.scores && Object.keys(result.scores).length > 0 && (
                                <div className="text-[11px]" style={{ color: colors.textMuted }}>
                                  {Object.entries(result.scores).map(([key, value]) => `${key.replace(/_/g, ' ')} ${value == null ? 'skipped' : Number(value).toFixed(2)}`).join(' · ')}
                                </div>
                              )}
                            </div>
                          );
                        })}
                        {!resultsByKey[scenario.key] && (
                          <div className="text-xs" style={{ color: colors.textMuted }}>Not part of the last run — use “run” on this row to replay it.</div>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              }
              return rows;
            })}
          </tbody>
        </table>
        {scenarios.length === 0 && (
          <div className="text-sm py-4" style={{ color: colors.textMuted }}>No scenarios yet — paste some with “Edit scenarios”.</div>
        )}
      </div>
    </div>
  );
}
