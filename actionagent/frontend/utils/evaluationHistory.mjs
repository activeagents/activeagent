// Historical evidence stays attached to the question the run actually asked.
// Current IDs and enablement still control which catalog entries can be rerun.
//
// A merged row is a function of two objects only: the catalog entry and the
// first result it snapshots from. `cache` (optional; a Map the caller owns,
// key → { scenario, first, row }) hands the previous row back while both are
// the same objects, so a poll that lands two results replaces two rows and
// memoised rows for the rest keep their identity. Orphans cache with
// scenario = null. A scenario with no result is returned as itself and never
// cached. Without `cache` every call builds fresh rows, as before.
export function scenarioRowsForRun(scenarios, resultsByKey, cache = null) {
  const firstResult = (key) => Object.values(resultsByKey[key] || {})[0] ?? null;
  const recorded = (key, first) => {
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
  const catalogRow = (scenario, first) => {
    const snapshot = recorded(scenario.key, first);
    const catalogChanged = ['prompt', 'group', 'notes', 'expectations'].some(
      (key) => JSON.stringify(scenario[key] ?? null) !== JSON.stringify(snapshot[key] ?? null),
    );
    return { ...scenario, ...snapshot, catalogChanged };
  };
  const orphanRow = (key, first) => ({ ...recorded(key, first), id: null, enabled: false, orphan: true });
  const remembered = (key, scenario, first, build) => {
    if (!cache) return build();
    const hit = cache.get(key);
    if (hit && hit.scenario === scenario && hit.first === first) return hit.row;
    const row = build();
    cache.set(key, { scenario, first, row });
    return row;
  };
  const known = new Set(scenarios.map((scenario) => scenario.key));
  const rows = scenarios.map((scenario) => {
    const first = firstResult(scenario.key);
    if (!first) return scenario;
    return remembered(scenario.key, scenario, first, () => catalogRow(scenario, first));
  });
  const orphans = Object.keys(resultsByKey).filter((key) => !known.has(key)).map((key) => {
    const first = firstResult(key);
    return remembered(key, null, first, () => orphanRow(key, first));
  });
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
