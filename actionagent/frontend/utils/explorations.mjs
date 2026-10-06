// Pure helpers for reviewing an exploration's candidate scenarios (see
// ActionAgent::Exploration): which candidates start selected, the budget
// meter, the replay link, what accepting and running will cost, and the
// edit a reviewer sends.

export const EXPLORATION_POLL_INTERVAL_MS = 3000;

// The candidate states still awaiting a decision.
export const OPEN_STATES = ['proposed', 'edited'];

export const VERDICTS = {
  answerable: { label: 'answerable', tone: 'success', title: 'Every expected tool is one the agent can call.' },
  needs_tool: { label: 'needs a tool', tone: 'warning', title: 'The agent cannot call every tool a good answer needs.' },
  unverified: { label: 'unverified', tone: 'muted', title: 'The agent\'s tools could not be read when this was checked.' },
};

export const STATUS_TONES = {
  pending: 'info', running: 'info', review: 'accent', closed: 'success', failed: 'error',
};

const BUDGET_LABELS = { minutes: 'Minutes', steps: 'Browser steps', cost: 'Cost' };

// Returns whether the exploration is still walking the app.
export function isExplorationActive(exploration) {
  return exploration?.status === 'pending' || exploration?.status === 'running';
}

// Returns whether `candidate` still awaits a decision.
export function isOpenCandidate(candidate) {
  return OPEN_STATES.includes(candidate.state);
}

// The ids a review starts with selected: the open, answerable candidates in
// list order, at most `limit` of them (null or undefined for no limit).
export function preselectedIds(candidates = [], limit = null) {
  const ids = candidates.filter((candidate) => isOpenCandidate(candidate) && candidate.verdict === 'answerable')
    .map((candidate) => candidate.id);
  return Number.isInteger(limit) && limit >= 0 ? ids.slice(0, limit) : ids;
}

// `selected` with the ids of `candidates` that are no longer open dropped,
// so a candidate accepted or rejected meanwhile is not sent again.
export function keepOpenSelection(selected = [], candidates = []) {
  const open = new Set(candidates.filter(isOpenCandidate).map((candidate) => candidate.id));
  return selected.filter((id) => open.has(id));
}

function formatBudgetValue(key, value) {
  if (key === 'cost') return `$${Number(value || 0).toFixed(2)}`;
  return String(Math.round(Number(value || 0) * 10) / 10);
}

// One row per limit the budget sets ({ minutes, steps, cost }), as
// { key, label, used, limit, ratio, text }. `ratio` is used ÷ limit,
// capped at 1. A limit that is not a positive number is left out.
export function budgetMeters(budget = {}, usage = {}) {
  return Object.keys(BUDGET_LABELS).flatMap((key) => {
    const limit = Number(budget?.[key]);
    if (!Number.isFinite(limit) || limit <= 0) return [];

    const used = Math.max(Number(usage?.[key]) || 0, 0);
    return [{
      key,
      label: BUDGET_LABELS[key],
      used,
      limit,
      ratio: Math.min(used / limit, 1),
      text: `${formatBudgetValue(key, used)} / ${formatBudgetValue(key, limit)}`,
    }];
  });
}

// The mount-relative path that replays the part of the exploration's
// recording a candidate was found in, or null when the candidate names no
// recording.
export function candidateReplayPath(candidate) {
  const provenance = candidate?.provenance || {};
  const id = provenance.recording_id;
  if (!Number.isInteger(id) || id <= 0) return null;

  const range = provenance.range || {};
  const query = ['from_ms', 'to_ms']
    .filter((key) => Number.isInteger(range[key]))
    .map((key) => `${key}=${range[key]}`);
  return `/replay/${id}${query.length ? `?${query.join('&')}` : ''}`;
}

// What accepting `selectedIds` and then running the whole suite uses:
// { added, scenarios, models, executions }. A selected candidate accepted
// before updates its scenario rather than adding one.
export function runEstimate({ evaluation = null, candidates = [], selectedIds = [] } = {}) {
  const selected = new Set(selectedIds);
  const added = candidates.filter((candidate) => selected.has(candidate.id) && !candidate.scenario_key).length;
  const scenarios = (evaluation?.enabled_scenario_count || 0) + added;
  const models = Math.max(evaluation?.model_count || 1, 1);
  return { added, scenarios, models, executions: scenarios * models };
}

// The sentence shown before an accept-and-run. `runsRemaining` is the
// host's count, or null when it reports none.
export function runEstimateText(estimate, runsRemaining = null) {
  const scenarios = `${estimate.scenarios} scenario${estimate.scenarios === 1 ? '' : 's'}`;
  const models = `${estimate.models} model${estimate.models === 1 ? '' : 's'}`;
  const base = `The run uses ${estimate.executions} execution${estimate.executions === 1 ? '' : 's'} (${scenarios} × ${models}).`;
  return Number.isFinite(runsRemaining) ? `${base} ${runsRemaining} remaining on your plan.` : base;
}

function listText(values) {
  return (values || []).join(', ');
}

function textList(text) {
  return String(text || '').split(',').map((value) => value.trim()).filter(Boolean);
}

// The editable fields of `candidate`, as the edit form holds them: lists as
// comma-separated text.
export function candidateDraft(candidate) {
  const expectations = candidate.expectations || {};
  return {
    prompt: candidate.prompt || '',
    group: candidate.group || '',
    rubric: candidate.notes || '',
    tools: listText(expectations.tools),
    contains: listText(expectations.contains),
    not_contains: listText(expectations.not_contains),
  };
}

// The PATCH body for an edit form's `draft`.
export function candidateEditPayload(draft) {
  return {
    prompt: draft.prompt.trim(),
    group: draft.group.trim(),
    rubric: draft.rubric.trim(),
    tools: textList(draft.tools),
    contains: textList(draft.contains),
    not_contains: textList(draft.not_contains),
  };
}

export function explorationPath(id) {
  return `/explorations/${id}`;
}

// { explorationId } for a mount-relative /explorations/:id path; an id of
// null for the /explorations list.
export function parseExplorationPath(path) {
  const id = String(path || '').match(/^\/explorations\/(\d+)/)?.[1];
  return { explorationId: id || null };
}
