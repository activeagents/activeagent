// Historical evidence stays attached to the question the run actually asked.
// Current IDs and enablement still control which catalog entries can be rerun.
export function scenarioRowsForRun(scenarios, resultsByKey) {
  const recorded = (key) => {
    const first = Object.values(resultsByKey[key] || {})[0];
    if (!first) return null;
    const snapshot = first.scenario || first;
    return {
      key,
      prompt: snapshot.prompt,
      group: snapshot.group ?? null,
      notes: snapshot.notes ?? null,
      expectations: snapshot.expectations || {},
      position: snapshot.position,
    };
  };
  const known = new Set(scenarios.map((scenario) => scenario.key));
  const rows = scenarios.map((scenario) => {
    const snapshot = recorded(scenario.key);
    if (!snapshot) return scenario;
    const catalogChanged = ['prompt', 'group', 'notes', 'expectations'].some(
      (key) => JSON.stringify(scenario[key] ?? null) !== JSON.stringify(snapshot[key] ?? null),
    );
    return { ...scenario, ...snapshot, catalogChanged };
  });
  const orphans = Object.keys(resultsByKey).filter((key) => !known.has(key)).map(
    (key) => ({ ...recorded(key), id: null, enabled: false, orphan: true }),
  );
  return [...rows, ...orphans];
}

const positiveId = (value) => (/^[1-9]\d*$/.test(value || '') ? value : null);

export function evaluationLink(search) {
  const params = new URLSearchParams(search);
  const evaluationId = positiveId(params.get('evaluation'));
  if (!evaluationId) return null;
  return { evaluationId, runId: positiveId(params.get('run')) };
}

// The index is paginated. Resolve an explicitly linked older evaluation via
// the same scoped detail API instead of silently opening an unrelated suite.
export async function includeLinkedEvaluation(list, evaluationId, fetchDetail) {
  if (!evaluationId || list.some((entry) => String(entry.id) === String(evaluationId))) return list;
  const response = await fetchDetail(`/api/evaluations/${encodeURIComponent(evaluationId)}`);
  if (!response.ok) throw new Error(`Requested evaluation is unavailable (HTTP ${response.status})`);
  const data = await response.json();
  if (!data.evaluation) throw new Error('Requested evaluation is unavailable');
  return [data.evaluation, ...list];
}
