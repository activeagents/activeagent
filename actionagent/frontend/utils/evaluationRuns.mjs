// Shared vocabulary for the Evaluations page: what a run's `scores` payload
// means, how a criterion is named and what it expects, and what a run cost
// — on the agent's side and on the judge's.
//
// A run's `scores` is { criterion_key => stats }, where stats is either flat
// ({ score, min, max, passed, total } or { skipped, reason }) or, for a
// comparison run, a cohort map { model => stats }. Beside those sit the
// runner's "_"-prefixed metadata: `_cohorts` (a sampling run's per-model
// summaries), `_models` (a scenario run's), `_verdict`, `_missing_models`,
// `_recommendations` and `_judge_usage`. Everything here reads that shape;
// nothing here invents data the runner did not record. Pure, and imports
// nothing, so the node tests can pin it.

export const PASS_THRESHOLD = 0.7;

const TELEMETRY_TYPES = ['trace_error_rate', 'trace_latency'];

export const CRITERION_GROUPS = [
  { id: 'rules', label: 'Rule-based' },
  { id: 'telemetry', label: 'Telemetry' },
  { id: 'judge', label: 'LLM judge' },
];

export const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

export const truncate = (text, max) => {
  const value = String(text || '');
  return value.length > max ? `${value.slice(0, max - 1)}…` : value;
};

const humanize = (key) => String(key || '').replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());

// A whole percent, half up on the decimal value (14.5 → 15, even as
// 14.499999999999998), and a pass fraction with it: the same rules as
// evalFormat's fmtPercent and fmtPasses, repeated here so this module keeps
// importing nothing.
const wholePercent = (fraction) => `${Math.round(Number(Math.abs(Number(fraction) * 100).toFixed(9)))}%`;
const passesText = (passed, total) => (total > 0 ? `${passed}/${total} · ${wholePercent(passed / total)}` : '—');

// "5s", "1.5s", "620ms" — the terse form a criterion's expectation reads in.
const fmtMsShort = (ms) => {
  const value = Number(ms) || 0;
  if (value >= 1000) return `${(value / 1000).toFixed(value % 1000 === 0 ? 0 : 1)}s`;
  return `${Math.round(value)}ms`;
};

// --- criteria ---------------------------------------------------------------

export const criterionGroup = (criterion) => {
  if (criterion?.type === 'llm_judge') return 'judge';
  if (TELEMETRY_TYPES.includes(criterion?.type)) return 'telemetry';
  return 'rules';
};

export const criterionLabel = (criterion) => {
  const config = criterion?.config || {};
  switch (criterion?.type) {
    case 'response_present': return 'Response present';
    case 'min_length': return 'Response length';
    case 'max_latency_ms': return 'Latency';
    case 'token_budget': return 'Output tokens';
    case 'contains': return 'Must contain';
    case 'not_contains': return 'Must not contain';
    case 'trace_error_rate': return 'Trace error rate';
    case 'trace_latency': return 'Trace latency';
    case 'llm_judge': return config.description || humanize(criterion.key);
    default: return humanize(criterion?.key);
  }
};

// What each sample (or, for telemetry, the trace aggregate) is held to.
export const criterionExpectation = (criterion) => {
  const config = criterion?.config || {};
  switch (criterion?.type) {
    case 'response_present': return 'non-empty output';
    case 'min_length': return `≥ ${config.chars ?? 40} chars`;
    case 'max_latency_ms': return `≤ ${fmtMsShort(config.ms ?? 5000)}`;
    case 'token_budget': return `≤ ${config.output_tokens ?? 1000} output tokens`;
    case 'contains': return `matches /${config.pattern || ''}/i`;
    case 'not_contains': return `no /${config.pattern || ''}/i`;
    case 'trace_error_rate': return `error rate ≤ ${config.max_error_rate ?? 5}% · ${config.window_hours ?? 168}h`;
    case 'trace_latency': return `avg ≤ ${fmtMsShort(config.max_avg_ms ?? 5000)} · ${config.window_hours ?? 168}h`;
    case 'llm_judge': return config.prompt ? `judge: ${truncate(config.prompt, 72)}` : 'judge scores 0.0–1.0';
    default: return '';
  }
};

export const findCriterion = (evaluation, key) =>
  (evaluation?.criteria || []).find((criterion) => criterion.key === key) || { key, type: key, config: {} };

// Who judged a run: the label the run recorded, else the verdict's judge
// unless that is only the framework's pass-rate ranking, else what the
// evaluation is configured with. "rules" when no model judged anything.
export const judgeLabel = (evaluation, run = null) => {
  const scores = run?.scores || {};
  if (Object.prototype.hasOwnProperty.call(scores, '_judge_label')) return scores._judge_label || 'rules';
  const recorded = scores._verdict?.judge;
  if (recorded && recorded !== 'pass rate') return recorded;
  if (evaluation?.judge_kind === 'judge_defined') {
    return `judge-defined KPIs${evaluation.judge_model ? ` · ${evaluation.judge_model}` : ''}`;
  }
  if (evaluation?.judge_kind === 'llm') return evaluation.judge_model || 'LLM judge';
  return 'rules';
};

// How many model cohorts a run compares: the run's own when it has started,
// else what the evaluation asks for.
export const modelCount = (evaluation, run = null) =>
  run?.models?.length || Object.keys(run?.scores?._models || run?.scores?._cohorts || {}).length
    || (evaluation?.compare_models || []).length || 1;

// "12 scenarios × 2 models" for a suite, "5 criteria · 20 samples" (or
// "4 criteria × 3 models") for a sampling evaluation.
export const runLabel = (evaluation, run = null) => {
  const models = modelCount(evaluation, run);
  if (evaluation?.scenario_suite) {
    const scenarios = run?.samples_evaluated && models ? Math.round(run.samples_evaluated / models) : (evaluation.scenario_count || 0);
    return `${plural(scenarios, 'scenario')} × ${plural(models, 'model')}`;
  }
  const criteria = (evaluation?.criteria || []).length;
  const noun = criteria === 1 ? 'criterion' : 'criteria';
  if (models > 1) return `${criteria} ${noun} × ${plural(models, 'model')}`;
  return `${criteria} ${noun} · ${plural(evaluation?.sample_size ?? 0, 'sample')}`;
};

// --- run payload ------------------------------------------------------------

export const isCohortMap = (value) =>
  value != null && typeof value === 'object' && !Array.isArray(value) && !('score' in value) && !('skipped' in value);

export const criterionEntries = (run) =>
  Object.entries(run?.scores || {}).filter(([key, value]) => !key.startsWith('_') && value && typeof value === 'object');

export const isComparison = (run) => criterionEntries(run).some(([, value]) => isCohortMap(value));

// The models a run scored, in the runner's order.
export const runModels = (run) => {
  const recorded = run?.scores?._cohorts || run?.scores?._models;
  if (recorded && typeof recorded === 'object' && Object.keys(recorded).length) return Object.keys(recorded);
  if (Array.isArray(run?.models) && run.models.length) return run.models;
  const models = [];
  criterionEntries(run).forEach(([, value]) => {
    if (!isCohortMap(value)) return;
    Object.keys(value).forEach((model) => { if (!models.includes(model)) models.push(model); });
  });
  return models;
};

// Stats for one criterion under one model column. Telemetry criteria are
// scored once per run, so a flat value applies to every column.
export const cellStats = (value, model) => {
  if (!value || typeof value !== 'object') return null;
  if (isCohortMap(value)) return model ? value[model] || null : null;
  return value;
};

export const passRate = (run) =>
  run && run.samples_evaluated ? (run.samples_passed || 0) / run.samples_evaluated : null;

export const isInProgress = (run) => !!run && ['pending', 'running'].includes(run.status);

// --- pricing ----------------------------------------------------------------
//
// Every interaction with tokens is priced by the API: a cost the
// application reported, else an estimate from tokens × the model's rate.
// A figure with an estimated part reads with a "~" (evalFormat's fmtSpend);
// the counts here say which parts were which, and a cost that still covers
// only some interactions is a lower bound and reads as an estimate too.

// How many of a cohort's `count` interactions were priced: `priced` as the
// API serves it, else all of them when the cohort has a cost. The API
// counts a scenario run's summaries from its results, so a summary lacks
// `priced` only when it predates the runner counting it and nothing can
// recount it: a sampling run's cohort, whose samples the run does not keep,
// or a scenario summary no result maps to. null for no summary at all.
export const pricedCount = (stats, count) => {
  if (!stats || typeof stats !== 'object') return null;
  if (stats.priced != null) return stats.priced;
  return stats.cost != null ? count ?? null : 0;
};

// A cost's rate per priced interaction, or null when none was priced.
export const costPer = (cost, priced) => (cost != null && priced ? cost / priced : null);

// Whether a cost over `count` interactions is an estimate: any of them
// priced from tokens (`estimated` counts them), a basis that says so, or
// some left unpriced, which leaves the sum a lower bound.
export const isEstimated = (stats, count) => {
  if (!stats || typeof stats !== 'object') return false;
  if (Number(stats.estimated) > 0) return true;
  if (stats.cost_basis === 'estimated' || stats.cost_basis === 'mixed') return true;
  const priced = pricedCount(stats, count);
  return priced != null && count != null && stats.cost != null && priced < count;
};

// Per-model summaries of a run, one shape for both kinds of evaluation:
// `{ label, model, provider, samples, passed, avg_score, avg_duration_ms,
// input_tokens, output_tokens, cost, priced, faults, errored, kind }`, where
// `priced` counts the samples that carried a cost and `kind` is 'replay' for
// a scenario run's cohorts and 'sample' for a sampling run's. Runs recorded
// before the runner stored summaries fall back to what the criteria stats
// can tell; a run with no models at all is one cohort of everything it
// scored.
export const runCohorts = (run) => {
  if (!run) return [];
  const scores = run.scores || {};
  const suite = scores._models;
  if (suite && typeof suite === 'object' && Object.keys(suite).length) {
    return Object.entries(suite).map(([label, stats]) => ({
      label, model: stats.model || label, provider: stats.provider || null,
      samples: stats.scenarios ?? null, passed: stats.passed ?? null, errored: stats.errored ?? 0,
      avg_score: stats.avg_score ?? null, avg_duration_ms: stats.avg_duration_ms ?? null,
      p50_duration_ms: stats.p50_duration_ms ?? null, p95_duration_ms: stats.p95_duration_ms ?? null,
      input_tokens: stats.input_tokens ?? null, output_tokens: stats.output_tokens ?? null,
      cost: stats.cost ?? null, priced: pricedCount(stats, stats.scenarios), reported: stats.reported ?? null,
      estimated: isEstimated(stats, stats.scenarios), judge_cost: stats.judge_cost ?? null, judge_calls: stats.judge_calls ?? 0,
      faults: stats.faults || {}, kind: 'replay',
    }));
  }
  const sampled = scores._cohorts;
  if (sampled && typeof sampled === 'object' && Object.keys(sampled).length) {
    return Object.entries(sampled).map(([model, stats]) => ({
      label: model, model, provider: stats.provider || null,
      samples: stats.samples ?? null, passed: stats.passed ?? null, errored: 0,
      avg_score: null, avg_duration_ms: stats.avg_duration_ms ?? null,
      input_tokens: stats.input_tokens ?? null, output_tokens: stats.output_tokens ?? null,
      // A sampling cohort's cost is the runner's own estimate from tokens.
      cost: stats.cost ?? null, priced: pricedCount(stats, stats.samples), reported: 0,
      estimated: stats.cost != null, judge_cost: null, judge_calls: 0, faults: {}, kind: 'sample',
    }));
  }
  const models = runModels(run);
  if (models.length) {
    return models.map((model) => {
      const totals = criterionEntries(run)
        .map(([, value]) => cellStats(value, model))
        .filter((stats) => stats && stats.total != null)
        .map((stats) => stats.total);
      return {
        label: model, model, provider: null, samples: totals.length ? Math.max(...totals) : null, passed: null,
        errored: 0, avg_score: null, avg_duration_ms: null, input_tokens: null, output_tokens: null, cost: null,
        priced: null, reported: null, estimated: false, judge_cost: null, judge_calls: 0, faults: {},
        kind: run.selection || scores._selection ? 'replay' : 'sample',
      };
    });
  }
  return [{
    label: null, model: null, provider: null, samples: run.samples_evaluated ?? null, passed: run.samples_passed ?? null,
    errored: 0, avg_score: null, avg_duration_ms: null, input_tokens: null, output_tokens: null, cost: null, priced: null,
    reported: null, estimated: false, judge_cost: null, judge_calls: 0, faults: {}, kind: 'sample',
  }];
};

// How one model column did across the run's criteria.
export const modelScorecard = (run, model) => {
  const cells = criterionEntries(run).map(([, value]) => cellStats(value, model)).filter(Boolean);
  const scored = cells.filter((stats) => stats.score != null);
  return {
    avg: scored.length ? scored.reduce((sum, stats) => sum + stats.score, 0) / scored.length : null,
    scored: scored.length,
    cleared: scored.filter((stats) => stats.score >= PASS_THRESHOLD).length,
    below: scored.filter((stats) => stats.score < PASS_THRESHOLD).length,
    skipped: cells.filter((stats) => stats.skipped).length,
  };
};

// --- run history ------------------------------------------------------------

// GET /api/evaluations/:id serves at most this many runs, newest first.
export const RUNS_PAGE = 20;

// How many runs the evaluation has: `run_count` from the API when it reports
// it (so `#n` stays stable once the run list is capped), else the runs
// fetched — never fewer than the list, which can grow locally when a run
// starts.
export const runTotalOf = (runs = [], runCount = null) =>
  (Number.isFinite(runCount) ? Math.max(runCount, runs.length) : runs.length);

// The panel's header meta: `3 runs`, or `24 runs · latest 20` when the list
// is a page of a longer history (or may be, when the total is unknown).
export const runsMeta = (runs = [], runCount = null) => {
  const total = runTotalOf(runs, runCount);
  const paged = runs.length < total || (!Number.isFinite(runCount) && runs.length >= RUNS_PAGE);
  return `${plural(total, 'run')}${paged ? ` · latest ${runs.length}` : ''}`;
};

// How many runs a suite's list shows until it is expanded: enough to read
// the trend, few enough that the shown run's scenarios stay near the top.
export const RUNS_SHOWN = 3;

// The positions in a newest-first run list that a capped list shows: the
// latest `limit`, plus the selected run when it is older, so a deep link or
// a pick from the expanded list stays on screen once the list folds. No
// limit shows every run.
export const shownRunIndexes = (runs = [], { limit = null, selectedId = null } = {}) => {
  const all = runs.map((_run, index) => index);
  if (!Number.isFinite(limit) || runs.length <= limit) return all;
  return all.filter((index) => index < limit || (selectedId != null && runs[index].id === selectedId));
};

// A scenario's state in the shown run, read like a build step: `passed` or
// `failed` once every model column has a settled result (failed when any
// did not pass), `running` while the run has some of its results in or
// pending, `queued` while the run has none of them yet, `skipped` when the
// run does not cover it, and `missing` when the run finished without them.
// `row` is the scenario's results keyed by model column.
export const scenarioStep = (row = {}, columns = [], { inRun = false, running = false } = {}) => {
  if (!inRun) return 'skipped';
  const results = columns.map((label) => row[label]);
  const settled = results.filter((result) => result && result.status !== 'pending');
  const anyFailed = settled.some((result) => result.status !== 'passed');
  if (columns.length > 0 && settled.length === columns.length) return anyFailed ? 'failed' : 'passed';
  if (!running) return anyFailed ? 'failed' : 'missing';
  return results.some(Boolean) ? 'running' : 'queued';
};

// A run's position in its evaluation's history, oldest = 1: the number the
// API assigned, else counted back from the total over a newest-first list.
export const runNumber = (run, index, runs = [], runCount = null) =>
  (Number.isFinite(run?.number) ? run.number : runTotalOf(runs, runCount) - index);

// Movement against the run before this one, in samples passed, as
// `{ text, tone }` with tone one of success / error / muted. A predecessor
// that did not complete has nothing to compare against, so the row says what
// happened to it instead of claiming this is the first run; a predecessor of
// a different shape (other scenarios or models) is not comparable either.
export const runDelta = (run, older, { olderNumber = older?.number, comparable = true } = {}) => {
  if (!run || run.status !== 'complete') return null;
  if (!older) return { text: 'first run', tone: 'muted' };
  const label = Number.isFinite(olderNumber) ? `#${olderNumber}` : 'previous';
  if (older.status !== 'complete') return { text: `${label} ${older.status}`, tone: 'muted' };
  if (!comparable) return { text: 'partial run', tone: 'muted' };
  const diff = (run.samples_passed || 0) - (older.samples_passed || 0);
  if (diff === 0) return { text: `same as ${label}`, tone: 'muted' };
  return { text: `${diff > 0 ? '+' : ''}${diff} passed vs ${label}`, tone: diff > 0 ? 'success' : 'error' };
};

// Whether `run` scored the same version of the agent as `older`, read from
// the versions the API pins each run to: `same`, `new` (a different
// version, so movement also measures the change), or `unrecorded` when
// either run names no version (a published run whose report named no
// release). null without a run to compare against.
export const versionDelta = (run, older) => {
  if (!run || !older) return null;
  const mine = run.agent_version?.id ?? null;
  const theirs = older.agent_version?.id ?? null;
  if (mine == null || theirs == null) return { kind: 'unrecorded', text: 'release not recorded' };
  if (mine === theirs) return { kind: 'same', text: 'same version' };
  return { kind: 'new', text: `new version${run.agent_version?.number != null ? ` v${run.agent_version.number}` : ''}` };
};

// The version a run scored, as a chip: `{ text, tone, title }` from the
// run's `agent_version` and `version_state` — a release by its digest, a
// dashboard edit by its number — green when it is the agent's current
// version, muted when earlier, amber when the run recorded none. null for
// a run the API did not describe this way (an older server).
export const versionChip = (run) => {
  if (!run || !('version_state' in run) && !run.agent_version) return null;
  const version = run.agent_version;
  if (!version) return { text: 'release not recorded', tone: 'warning', title: 'This run named no release, so nothing says which version of the agent it scored' };
  const digest = version.release_digest ? ` · ${String(version.release_digest).slice(0, 7)}` : '';
  const text = `v${version.number}${digest}`;
  const state = run.version_state || 'current';
  if (state === 'earlier') return { text, tone: 'muted', title: `An earlier version of the agent${version.revision ? ` · ${version.revision}` : ''}` };
  if (state === 'unrecorded') return { text, tone: 'warning', title: 'The version this run scored was not recorded' };
  return { text, tone: 'success', title: `The agent's current version${version.revision ? ` · ${version.revision}` : ''}` };
};

// --- spend ------------------------------------------------------------------

// What a run cost, from the API's `usage`, on the two sides that answer
// different questions:
//
// `agent` is the operating figure — what the interactions cost to serve:
// a scenario run's replays (simulated user–agent interactions), or the
// sampled generations a sampling run scored (real ones, served before the
// run). `priced` of its `count` interactions carried a cost, and `cost` sums
// those. `perInteraction` is the cost per priced interaction, the number a
// per-conversation budget is set against.
//
// `judge` is the evaluation's own overhead: the judge model's calls, which
// run agent-to-agent, offline — from the engine's meter, the application's
// figures or the judge traces (`source`), `estimated` when its cost was
// worked out from tokens, with `run` the calls no result owns. Absent when
// no judge was asked.
//
// `estimated` on the agent side says the agent's cost has an estimated
// part (`fmtSpend` then marks it "~"); `totalEstimated` says the total has.
// null when the run recorded nothing on either side.
export const runSpend = (run) => {
  const usage = run?.usage;
  if (!usage || typeof usage !== 'object') return null;
  const count = usage.replays ?? usage.samples ?? null;
  const agentCost = usage.cost ?? null;
  const priced = pricedCount(usage, count || 0);
  const agent = count != null || agentCost != null ? {
    cost: agentCost,
    count: count || 0,
    priced,
    reported: usage.reported ?? null,
    estimatedCount: usage.estimated ?? null,
    basis: usage.cost_basis ?? null,
    estimated: isEstimated(usage, count || 0),
    unit: usage.replays != null ? 'replay' : 'sample',
    perInteraction: usage.per_interaction ?? costPer(agentCost, priced),
    inputTokens: usage.input_tokens ?? null,
    outputTokens: usage.output_tokens ?? null,
    modelTimeMs: usage.model_time_ms ?? null,
  } : null;
  const recorded = usage.judge;
  const judge = recorded && typeof recorded === 'object' ? {
    cost: recorded.cost ?? null,
    calls: recorded.calls || 0,
    byKind: recorded.by_kind || {},
    model: recorded.model || null,
    inputTokens: recorded.input_tokens ?? null,
    outputTokens: recorded.output_tokens ?? null,
    source: recorded.source || null,
    // A usage recorded before `estimated` was the engine's own meter: an estimate.
    estimated: recorded.estimated ?? (recorded.source == null || recorded.source !== 'reported'),
    run: recorded.run && typeof recorded.run === 'object' ? recorded.run : null,
  } : null;
  if (!agent && !judge) return null;
  const total = usage.total ?? (agent?.cost != null || judge?.cost != null ? (agent?.cost || 0) + (judge?.cost || 0) : null);
  const totalEstimated = Boolean((agent?.cost != null && agent.estimated) || (judge?.cost != null && judge.estimated));
  return { agent, judge, total, totalEstimated, runtimeMs: usage.runtime_ms ?? null };
};

// What a run's `total` sums, as its sub-line: "agent + judge", "agent only"
// or "judge only"; when the agent's interactions could not be priced at
// all it says so: "judge only · agent unpriced", or "agent unpriced" with
// no judge. An estimated part is the figure's own "~" to say.
export const spendTotalLabel = (spend) => {
  const agent = spend?.agent || null;
  const judge = spend?.judge || null;
  if (agent && agent.count > 0 && agent.cost == null) return judge ? 'judge only · agent unpriced' : 'agent unpriced';
  return agent && judge ? 'agent + judge' : agent ? 'agent only' : 'judge only';
};

// How the judge's figures were found, for a sub-line: "from traces",
// "metered" or "reported"; null when the API did not say.
export const judgeSourceText = (judge) => {
  switch (judge?.source) {
    case 'traces': return 'from traces';
    case 'meter': return 'metered';
    case 'reported': return 'reported';
    default: return null;
  }
};

// The judge's calls by purpose, in the order the runner makes them:
// "score 20 · recommend 3 · verdict 1".
export const judgeCallsText = (judge) => {
  if (!judge) return '';
  const order = ['define', 'score', 'recommend', 'verdict'];
  const kinds = Object.entries(judge.byKind || {}).sort(([a], [b]) => order.indexOf(a) - order.indexOf(b));
  return kinds.map(([kind, count]) => `${kind} ${count}`).join(' · ');
};

// Spend across several runs (the headline run of each evaluation, on the
// page): the agent's cost and interactions summed, the rate per priced
// interaction (`pricedInteractions` of the `interactions`), and the judge's
// cost beside it. `priced` counts the runs that carried a figure at all;
// `estimated` and `judgeEstimated` say a part of each sum was estimated.
export const spendSummary = (runs = []) => {
  let agentCost = null;
  let interactions = 0;
  let pricedInteractions = 0;
  let judgeCost = null;
  let priced = 0;
  let estimated = false;
  let judgeEstimated = false;
  runs.forEach((run) => {
    const spend = runSpend(run);
    if (!spend) return;
    priced += 1;
    if (spend.agent) {
      interactions += spend.agent.count;
      pricedInteractions += spend.agent.priced;
    }
    if (spend.agent?.cost != null) {
      agentCost = (agentCost || 0) + spend.agent.cost;
      if (spend.agent.estimated) estimated = true;
    }
    if (spend.judge?.cost != null) {
      judgeCost = (judgeCost || 0) + spend.judge.cost;
      if (spend.judge.estimated) judgeEstimated = true;
    }
  });
  return {
    agentCost,
    interactions,
    pricedInteractions,
    perInteraction: costPer(agentCost, pricedInteractions),
    judgeCost,
    priced,
    estimated,
    judgeEstimated,
  };
};

// --- headline runs and standing ----------------------------------------------
//
// An evaluation's pass rate describes its headline run: the newest run that
// completed. A newer run still pending, or one that failed, shows beside it
// and never in its place. The API names it (`headline_run_id`, and the run
// itself as `headline_run` when a newer run is the latest); an older server
// names neither, and the latest run stands in when it completed.

export const headlineRun = (evaluation) => {
  if (!evaluation) return null;
  if (evaluation.headline_run && typeof evaluation.headline_run === 'object') return evaluation.headline_run;
  const latest = evaluation.latest_run || null;
  if (evaluation.headline_run_id != null) return latest && latest.id === evaluation.headline_run_id ? latest : null;
  return latest && latest.status === 'complete' ? latest : null;
};

// Where an evaluation stands against the agent as it is now, as the API
// says (`standing`): `current`, `stale`, `unrecorded`, `archived` or `none`.
// An older server says nothing, so an evaluation with a completed run is
// taken as current.
export const evaluationStanding = (evaluation) => {
  if (!evaluation) return 'none';
  if (evaluation.standing) return evaluation.standing;
  if (evaluation.archived_at) return 'archived';
  return headlineRun(evaluation) ? 'current' : 'none';
};

// The standings whose headline runs the page pools: those that describe
// the agent as it is now, and those nothing contradicts.
export const COUNTED_STANDINGS = ['current', 'unrecorded'];

// The figures the Evaluations page's tiles describe, pooled over the
// headline runs of the evaluations that count — never a stale suite last
// run against earlier code, nor an archived one — and saying how many
// were left out and why. With `focusId` the page describes that one
// evaluation's headline run alone, whatever its standing.
//
//   { evaluations, counted, notCounted: { total, stale, archived, none },
//     runs, samplesScored, samplesPassed, passRatio, perModel, spend, focused }
//
// `perModel` pools each model label's passes across the counted runs,
// read from the evaluations' `per_model` (the API's) or the runs' own
// summaries; `byEvaluation` keeps each evaluation's part, keyed by id, and
// `columns` names the counted evaluations in page order, for the
// leaderboard's matrix.
export const headlineSummary = (evaluations = [], { focusId = null } = {}) => {
  const matched = focusId != null ? evaluations.filter((evaluation) => String(evaluation.id) === String(focusId)) : [];
  const focused = matched.length > 0;
  const pool = focused ? matched : evaluations;
  const notCounted = { total: 0, stale: 0, archived: 0, none: 0 };
  const runs = [];
  const perModel = {};
  const columns = [];
  let samplesScored = 0;
  let samplesPassed = 0;

  pool.forEach((evaluation) => {
    const run = headlineRun(evaluation);
    const standing = evaluationStanding(evaluation);
    const counted = focused ? !!run : !!run && COUNTED_STANDINGS.includes(standing);
    if (!counted) {
      notCounted.total += 1;
      if (standing === 'archived') notCounted.archived += 1;
      else if (standing === 'stale') notCounted.stale += 1;
      else notCounted.none += 1;
      return;
    }
    runs.push(run);
    columns.push({ id: evaluation.id, name: evaluation.name || `evaluation ${evaluation.id}` });
    samplesScored += run.samples_evaluated || 0;
    samplesPassed += run.samples_passed || 0;
    const models = evaluation.per_model && typeof evaluation.per_model === 'object' && Object.keys(evaluation.per_model).length
      ? Object.entries(evaluation.per_model).map(([label, stats]) => ({ label, passed: stats?.passed || 0, total: stats?.total || 0 }))
      : runCohorts(run).filter((cohort) => cohort.label && cohort.samples > 0).map((cohort) => ({ label: cohort.label, passed: cohort.passed || 0, total: cohort.samples || 0 }));
    models.forEach(({ label, passed, total }) => {
      const entry = (perModel[label] ||= { label, passed: 0, total: 0, byEvaluation: {} });
      entry.passed += passed;
      entry.total += total;
      const cell = (entry.byEvaluation[evaluation.id] ||= { passed: 0, total: 0 });
      cell.passed += passed;
      cell.total += total;
    });
  });

  return {
    evaluations: pool.length,
    counted: runs.length,
    notCounted,
    runs,
    samplesScored,
    samplesPassed,
    passRatio: samplesScored ? samplesPassed / samplesScored : null,
    perModel: Object.values(perModel),
    columns,
    spend: spendSummary(runs),
    focused,
  };
};

// --- model leaderboard -------------------------------------------------------
//
// The models a page's headline runs compared, ranked. A raw pass rate
// would put 7/8 above 75/173 on luck alone, so the rank is the lower
// bound of the Wilson score interval (95%): a model leads when even its
// pessimistic rate is the best. `ratio` is still what the row shows.

const Z = 1.96;

export const wilsonLowerBound = (passed, total) => {
  const n = Number(total) || 0;
  if (n <= 0) return 0;
  const p = (Number(passed) || 0) / n;
  const z2 = Z * Z;
  const centre = p + z2 / (2 * n);
  const margin = Z * Math.sqrt((p * (1 - p)) / n + z2 / (4 * n * n));
  return Math.max(0, (centre - margin) / (1 + z2 / n));
};

// The summary's models ranked best first, each with its ratio, bound and
// rank. Models with nothing scored are left out.
export const modelLeaderboard = (summary) => (summary?.perModel || [])
  .filter((entry) => entry.total > 0)
  .map((entry) => ({ ...entry, ratio: entry.passed / entry.total, lower: wilsonLowerBound(entry.passed, entry.total) }))
  .sort((a, b) => b.lower - a.lower || b.total - a.total || a.label.localeCompare(b.label))
  .map((entry, index) => ({ ...entry, rank: index + 1 }));

// "2 not counted · 1 stale · 1 archived", or null when every evaluation counted.
export const notCountedText = (summary) => {
  const left = summary?.notCounted;
  if (!left || !left.total) return null;
  const reasons = [];
  if (left.stale) reasons.push(`${left.stale} stale`);
  if (left.archived) reasons.push(`${left.archived} archived`);
  if (left.none) reasons.push(`${left.none} ${left.none === 1 ? 'has' : 'have'} no complete run`);
  return [`${left.total} not counted`, ...reasons].join(' · ');
};

// --- what to fix (sampling runs) -------------------------------------------
//
// Everything in a sampling run that asks for a follow-up, derived from what
// the runner recorded: a failed run, cohorts with no generations, criteria
// it could not score, and criteria that came in under the pass mark. Paths
// are relative to the dashboard mount (dashboardPath resolves them). A
// scenario run's fix items come from the framework's report instead
// (EvaluationRunPanels#fixItemsFor).
export const samplingFixItems = (evaluation, run) => {
  if (!run) return [];
  const items = [];
  const agentRunPath = `/agents/${evaluation?.agent?.id}/run`;

  if (run.status === 'failed') {
    items.push({
      kind: 'failed',
      label: 'run failed',
      scope: Number.isFinite(run.number) ? `run #${run.number}` : 'latest run',
      text: run.error_message || 'The run ended before any criterion was scored.',
      action: { label: 'Run agent', path: agentRunPath, hint: 'Run Agent ->' },
    });
  }

  const missing = Array.isArray(run.scores?._missing_models) ? run.scores._missing_models : [];
  if (missing.length) {
    items.push({
      kind: 'missing',
      label: `no generations ×${missing.length}`,
      scope: 'comparison cohorts',
      text: 'The comparison asked for these models, but the agent has no recorded generations under them. Run the agent under each model, then run the evaluation again.',
      chipsLabel: 'missing models',
      chips: missing,
      action: { label: 'Run agent', path: agentRunPath, hint: 'Run Agent ->' },
    });
  }

  const skipped = { judge: [], telemetry: [], rules: [] };
  const below = [];
  criterionEntries(run).forEach(([key, value]) => {
    const criterion = findCriterion(evaluation, key);
    const cells = isCohortMap(value) ? Object.entries(value) : [[null, value]];
    cells.forEach(([model, stats]) => {
      if (!stats || typeof stats !== 'object') return;
      if (stats.skipped) {
        skipped[criterionGroup(criterion)].push({ key, model, reason: stats.reason });
      } else if (stats.score != null && stats.score < PASS_THRESHOLD) {
        below.push({ key, model, stats, criterion });
      }
    });
  });

  const keysOf = (list) => [...new Set(list.map((entry) => entry.key))];
  const criteriaScope = (list) => `${keysOf(list).length} ${keysOf(list).length === 1 ? 'criterion' : 'criteria'}`;

  if (skipped.judge.length) {
    items.push({
      kind: 'judge',
      label: `judge skipped ×${skipped.judge.length}`,
      scope: criteriaScope(skipped.judge),
      text: skipped.judge[0].reason || 'The LLM judge could not score these criteria.',
      chipsLabel: 'unscored criteria',
      chips: keysOf(skipped.judge),
      action: { label: 'Add provider key', path: '/settings', hint: 'Settings ->' },
    });
  }
  if (skipped.telemetry.length) {
    items.push({
      kind: 'telemetry',
      label: `no telemetry ×${skipped.telemetry.length}`,
      scope: criteriaScope(skipped.telemetry),
      text: skipped.telemetry[0].reason || 'No traces were recorded for this agent in the criterion window.',
      chipsLabel: 'unscored criteria',
      chips: keysOf(skipped.telemetry),
      action: { label: 'Open traces', path: '/traces', hint: 'Traces ->' },
    });
  }
  if (skipped.rules.length) {
    items.push({
      kind: 'samples',
      label: `no samples ×${skipped.rules.length}`,
      scope: criteriaScope(skipped.rules),
      text: skipped.rules[0].reason || 'No generation could be scored against these criteria.',
      chipsLabel: 'unscored criteria',
      chips: keysOf(skipped.rules),
      action: { label: 'Run agent', path: agentRunPath, hint: 'Run Agent ->' },
    });
  }
  if (below.length) {
    const models = [...new Set(below.map((entry) => entry.model).filter(Boolean))];
    items.push({
      kind: 'below',
      label: `below pass mark ×${below.length}`,
      scope: `${criteriaScope(below)}${models.length ? ` · ${plural(models.length, 'model')}` : ''}`,
      text: `Scored under the pass mark (pass ≥ ${wholePercent(PASS_THRESHOLD)}). Each line is what the criterion expects against how the samples did; tighten the agent's instructions or revisit the budget before running again.`,
      details: below.map((entry) =>
        `${entry.key}${entry.model ? ` · ${entry.model}` : ''} ${wholePercent(entry.stats.score)} · expects ${criterionExpectation(entry.criterion)} · ${passesText(entry.stats.passed, entry.stats.total)} passed`),
    });
  }
  return items;
};

// --- model comparison table ---------------------------------------------------

// The fault taxonomy renders lower-case with spaces.
const faultWords = (fault) => String(fault || '').replace(/_/g, ' ');

// One row per model cohort for the comparison table: passed/total, mean
// score, average latency and its P50 / P95, average tokens per
// interaction, cost (over the
// `priced` interactions, and per priced interaction, `estimated` when any
// part was), the judge's spend on the cohort, and the model's
// typical fault — its most frequent one, with the diagnosis of the
// first result that carries it so the row says what went wrong, not only
// how often. Rows are ordered best first (pass rate, then mean score), the
// order a verdict is argued in. Cohort figures come from the run's recorded
// summaries (`_models` / `_cohorts`); while a scenario run is still scoring,
// passed and faults are counted from the results that have landed.
//
// `labelFor(result)` maps a result to its column label (the suite panel's
// labelForResult); it defaults to the result's model name.
// The run's model comparison as the Models panel plots it: one row per
// model, best first, with its pass rate and interval in percent and its
// scenario count, plus the conclusion and the caption's confidence and
// resample count. Read from what the run recorded (`_comparison`, the
// framework's Report#comparison); null for a single-model run, or one
// recorded before runs kept a comparison, so the panel draws nothing
// rather than resampling in the browser.
export const comparisonPlot = (run) => {
  const comparison = run?.scores?._comparison;
  if (!comparison || typeof comparison !== 'object' || !Array.isArray(comparison.ranking) || comparison.ranking.length < 2) return null;

  const method = comparison.method || {};
  return {
    rows: comparison.ranking.map((label) => {
      const stats = comparison.models?.[label] || {};
      return {
        label,
        passRate: stats.pass_rate ?? null,
        interval: Array.isArray(stats.interval) && stats.interval.length === 2 ? stats.interval : null,
        scenarios: stats.scenarios ?? 0,
      };
    }),
    conclusion: comparison.conclusion || null,
    confidence: Math.round(Number(method.confidence ?? 0.95) * 100),
    resamples: method.resamples ?? null,
  };
};

export const modelComparisonRows = (run, { results = [], scenarioCount = 0, labelFor = (r) => r?.model, columns = null } = {}) => {
  const cohorts = runCohorts(run);
  const byLabel = new Map(cohorts.map((cohort) => [cohort.label, cohort]));
  const labels = columns && columns.length ? columns : cohorts.map((cohort) => cohort.label);
  const winner = run?.scores?._verdict?.winner || null;

  const rows = labels.map((label) => {
    const cohort = byLabel.get(label) || {};
    const mine = results.filter((result) => labelFor(result) === label);
    const settled = mine.filter((result) => result?.status && result.status !== 'pending');
    const total = cohort.samples ?? (scenarioCount || mine.length || null);
    const passed = cohort.passed ?? settled.filter((result) => result.status === 'passed').length;
    const faultTally = Object.keys(cohort.faults || {}).length
      ? cohort.faults
      : settled.reduce((tally, result) => (result.fault ? { ...tally, [result.fault]: (tally[result.fault] || 0) + 1 } : tally), {});
    // Most frequent first; between equals, the fault a landed result can
    // explain (so the row shows a diagnosis), then a specific fault over the
    // judge's catch-all "low_quality", then the name.
    const exampleOf = (fault) => mine.find((result) => result.fault === fault) || null;
    const catchAll = (fault) => (fault === 'low_quality' ? 1 : 0);
    const faults = Object.entries(faultTally).sort((a, b) =>
      b[1] - a[1] || (exampleOf(b[0]) ? 1 : 0) - (exampleOf(a[0]) ? 1 : 0) || catchAll(a[0]) - catchAll(b[0]) || a[0].localeCompare(b[0]));
    const [topFault, topCount] = faults[0] || [];
    const example = topFault ? exampleOf(topFault) : null;
    const divisor = total || null;
    const perInteraction = (value) => (value == null || !divisor ? null : value / divisor);
    const avgScore = cohort.avg_score ?? (settled.length && settled.some((r) => r.score != null)
      ? settled.filter((r) => r.score != null).reduce((sum, r) => sum + Number(r.score), 0) / settled.filter((r) => r.score != null).length
      : null);

    return {
      label,
      model: cohort.model || label,
      provider: cohort.provider || null,
      winner: winner === label,
      passed,
      total,
      // How many interactions have a score behind them: the cohort once the
      // run recorded it, else the results that have settled so far.
      scored: cohort.samples ?? settled.length,
      passRate: total ? passed / total : null,
      avgScore: avgScore == null ? null : Number(avgScore),
      avgDurationMs: cohort.avg_duration_ms ?? null,
      // The run's recorded nearest-rank percentiles; a run recorded before
      // reports kept them, and a sampling run, has none.
      p50DurationMs: cohort.p50_duration_ms ?? null,
      p95DurationMs: cohort.p95_duration_ms ?? null,
      inputTokens: cohort.input_tokens ?? null,
      outputTokens: cohort.output_tokens ?? null,
      avgInputTokens: perInteraction(cohort.input_tokens),
      avgOutputTokens: perInteraction(cohort.output_tokens),
      avgTokens: cohort.input_tokens == null && cohort.output_tokens == null
        ? null
        : perInteraction((cohort.input_tokens || 0) + (cohort.output_tokens || 0)),
      cost: cohort.cost ?? null,
      priced: cohort.priced ?? null,
      reported: cohort.reported ?? null,
      estimated: cohort.estimated ?? false,
      judgeCost: cohort.judge_cost ?? null,
      judgeCalls: cohort.judge_calls ?? 0,
      costPerInteraction: costPer(cohort.cost, cohort.priced),
      faults: faults.map(([fault, count]) => ({ fault, name: faultWords(fault), count })),
      typicalFault: topFault
        ? {
            fault: topFault,
            name: faultWords(topFault),
            count: topCount,
            scenarioKey: example?.scenario_key || null,
            summary: (example?.diagnosis?.summary || example?.recommendation || '').toString().trim() || null,
          }
        : null,
    };
  });

  return rows.sort((a, b) =>
    (b.passRate ?? -1) - (a.passRate ?? -1)
    || (b.avgScore ?? -1) - (a.avgScore ?? -1)
    || labels.indexOf(a.label) - labels.indexOf(b.label));
};

// The typical-fault cell as one line: "missing content ×2 · late_refund:
// The answer is missing expected content: credit." — or "no faults" when
// the cohort cleared everything, "—" before anything has been scored.
export const typicalFaultText = (row, { max = 120 } = {}) => {
  if (!row) return '—';
  if (!row.typicalFault) return row.scored ? 'no faults' : '—';
  const { name, count, scenarioKey, summary } = row.typicalFault;
  const head = `${name} ×${count}`;
  if (!summary) return head;
  const detail = scenarioKey ? `${scenarioKey}: ${summary}` : summary;
  return `${head} · ${truncate(detail, max)}`;
};

// Attributes each fix item per model from the results: how many of that
// model's results carry the item's fault and which scenarios, so a list
// filtered to one model counts what that model needs fixed rather than the
// whole run. Instruction items are attributed by the scenarios the judge
// suggested them for. `labelFor(result)` maps a result to its column.
export const withModelBreakdown = (items = [], results = [], labelFor = (r) => r?.model) =>
  items.map((item) => {
    const mine = item.kind === 'instruction'
      ? results.filter((r) => (item.scenario_keys || []).includes(r?.scenario_key) && r?.fault)
      : results.filter((r) => r?.fault === item.fault);
    if (!mine.length) return item;
    const count_by_model = {};
    const scenario_keys_by_model = {};
    mine.forEach((r) => {
      const label = labelFor(r);
      if (!label) return;
      count_by_model[label] = (count_by_model[label] || 0) + 1;
      scenario_keys_by_model[label] = [...new Set([...(scenario_keys_by_model[label] || []), r.scenario_key].filter(Boolean))];
    });
    return { ...item, count_by_model, scenario_keys_by_model };
  });

// The fix items that concern one model cohort: those the runner attributed
// to it, and any it attributed to nobody (an older run without `models`).
// `label` null or "all" keeps every item. A filtered item is re-scoped to
// that model — its count and scenarios become the model's own when a
// breakdown is present (withModelBreakdown), and its "n models" reads for
// the filter, not the whole run.
export const fixItemsForModel = (items = [], label = null) => {
  if (!label || label === 'all') return items;
  return items
    .filter((item) => !Array.isArray(item.models) || item.models.length === 0 || item.models.includes(label))
    .map((item) => {
      if (!Array.isArray(item.models) || !item.models.length) return item;
      const scoped = { ...item, models: [label] };
      if (item.count_by_model?.[label] != null) scoped.count = item.count_by_model[label];
      if (item.scenario_keys_by_model?.[label]) scoped.scenario_keys = item.scenario_keys_by_model[label];
      return scoped;
    });
};

// Per-model item counts for the filter chips: { label => items naming it }.
export const fixItemCountsByModel = (items = [], labels = []) =>
  Object.fromEntries(labels.map((label) => [label, fixItemsForModel(items, label).length]));

// --- runs against a checkout sandbox ----------------------------------------
//
// A scenario run can replay against a checkout sandbox's app runtime without
// the agent being edited: the run's `sandbox_id` (a session id) adds that
// runtime's tools to every replay. The run then records the sandbox it used
// as `run.sandbox` ({ session_id, server_key, repository, repository_ref };
// only the session id while it is still queued).

// The caller's checkout sandboxes a run can use, from GET
// /api/sandboxes?sandbox_type=app_runtime: ready ones only, newest first as
// listed, labelled by checkout.
export const runSandboxOptions = (sandboxes) => (Array.isArray(sandboxes) ? sandboxes : [])
  .filter((sandbox) => sandbox && sandbox.session_id && sandbox.status === 'ready'
    && (sandbox.sandbox_type == null || sandbox.sandbox_type === 'app_runtime')
    // Listed without a key until its backend reported the runtime endpoint.
    && !('runtime_server_key' in sandbox && !sandbox.runtime_server_key))
  .map((sandbox) => ({ value: sandbox.session_id, label: sandboxLabel(sandbox) }));

// "acme/shop@main · 1a2b3c4d": the checkout, then the session's first
// characters, which tell two sandboxes of one branch apart.
export const sandboxLabel = (sandbox) => {
  if (!sandbox || !sandbox.session_id) return null;
  const checkout = [sandbox.repository, sandbox.repository_ref].filter(Boolean).join('@');
  const id = String(sandbox.session_id).slice(0, 8);
  return checkout ? `${checkout} · ${id}` : `sandbox ${id}`;
};

// How a run names the sandbox it replayed against, or null for a run on
// the agent's own servers.
export const runSandboxLabel = (run) => sandboxLabel(run?.sandbox);

// The body of POST /api/evaluations/:id/run: the selection, the models, and
// the sandbox when one is chosen.
export const runRequestBody = (selection = {}, models = [], sandboxId = null) => {
  const body = { ...selection, models };
  if (sandboxId) body.sandbox_id = sandboxId;
  return body;
};

// The chosen sandbox, while it is still one of the options; otherwise none,
// so a sandbox that stopped is never sent.
export const keepSandboxChoice = (choice, options) => (
  choice && (options || []).some((option) => option.value === choice) ? choice : ''
);

// --- a scenario run's selection ---------------------------------------------
//
// A pending run's selection is the request as posted ({ group } / { keys } /
// { models: ["a", "b"] }); once the runner starts it becomes the resolved
// summary ({ scenario_keys, models: [{ label, provider, model }] }). Both
// are read here. These three moved from EvaluationRunPanels, which
// re-exports them for its importers.

export const selectionOf = (run) => run?.selection || run?.scores?._selection || {};

export const selectionModelLabels = (run) =>
  (selectionOf(run).models || []).map((m) => (typeof m === 'string' ? m : m?.label)).filter(Boolean);

// The scenario keys a run covers: the resolved selection once the runner
// started; before that, what the request implies against the suite. A run
// still going covers every enabled scenario, and so does one that failed
// with nothing recorded — run_later! stores only the posted models, and the
// runner can raise ("unsupported model provider") before it writes the
// resolved selection — so such a run reads `[?]` on every row rather than
// `[-] not in this run`.
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
  if (isInProgress(run) || run.status === 'failed') return enabled.map((s) => s.key);
  return [];
}

// What a partial run covered, as a chip beside it: `partial: <group>` for a
// group run, `16 of 100 scenarios` for a key list shorter than the enabled
// catalog (a pending run's posted `keys` included); null for a run of the
// whole suite.
export const runSelectionLabel = (run, scenarios = []) => {
  const selection = selectionOf(run);
  if (selection.group) return `partial: ${selection.group}`;
  const keys = selection.scenario_keys || selection.keys;
  const enabledCount = scenarios.filter((s) => s.enabled !== false).length;
  if (Array.isArray(keys) && keys.length && keys.length < enabledCount) return `${keys.length} of ${enabledCount} scenarios`;
  return null;
};

// The keys a re-run may post — those still in the catalog with enabled !==
// false, once each in first-appearance order — and `dropped`, the rest, so a
// link can read `29 of 31` and name what it left out. The server drops a
// disabled or removed key silently (selected_scenarios is
// `scenarios.enabled.where(key:)`) while the pending run's expected count
// would still include it; filtering first keeps both honest.
export const runnableKeys = (keys = [], scenarios = []) => {
  const enabled = new Set(scenarios.filter((s) => s && s.enabled !== false).map((s) => s.key));
  const runnable = [];
  const dropped = [];
  [...new Set((keys || []).filter((key) => key != null))].forEach((key) => (enabled.has(key) ? runnable : dropped).push(key));
  return { keys: runnable, dropped };
};

// The keys a `re-run failed` link posts: every scenario with a settled
// result that did not pass, filtered to what can be replayed.
export const rerunFailedKeys = (results = [], scenarios = []) => runnableKeys(
  (results || []).filter((r) => r && r.scenario_key && r.status !== 'pending' && r.status !== 'passed').map((r) => r.scenario_key),
  scenarios,
);

// The selection `run again ->` posts for a run: its group, its key list
// filtered to what can be replayed, or nothing for a run of the whole suite.
export const runRequestSelection = (run, scenarios = []) => {
  const selection = selectionOf(run);
  if (selection.group) return { group: selection.group };
  const keys = Array.isArray(selection.scenario_keys) && selection.scenario_keys.length ? selection.scenario_keys : selection.keys;
  if (Array.isArray(keys) && keys.length) return { keys: runnableKeys(keys, scenarios).keys };
  return {};
};

// --- the suite's build page -------------------------------------------------
//
// Layout figures and pure helpers for the suite panel's build page: a
// RunHeader card, a runs rail beside a viewport-fit Steps box (a strip of
// the latest runs above it when the panel is narrow), and the matrix read
// as build steps. Nothing here touches the DOM: the panel measures, and
// passes the numbers in.

// The rail's column and its gap to the box, the panel root's two 16px
// paddings (clientWidth includes them), and the content width from which
// the rail fits beside a two-model steps grid: 272 + 16 + 644, rounded up.
export const RAIL_WIDTH = 272;
export const RAIL_GAP = 16;
export const PANEL_GUTTER = 32;
export const RAIL_BREAKPOINT = 940;

// The Steps box's and the rail's max height: viewport-fit, never under 360px
// nor over 900px. The strip's expanded run list caps lower.
export const STEPS_HEIGHT = 'clamp(360px, calc(100vh - 240px), 900px)';
export const STRIP_LIST_HEIGHT = 320;

// A rail row draws up to this many per-model bars; more fold into one.
export const RAIL_BARS_MAX = 3;

// How many runs' fetched results the panel keeps: the selected run, the
// latest and the previously selected one.
export const DETAILS_KEPT = 3;

// Under this box width a steps row drops the scenario key into its title so
// the prompt keeps its room.
export const KEY_COLUMN_MIN_WIDTH = 720;

// Where a browser remembers the `[ ] tools` chip.
export const DETAIL_STORAGE_KEY = 'aa.evaluations.detail';

// The grid's minimum width at each detail level for `n` model columns, so
// the box scrolls sideways inside itself instead of squeezing a column.
// Steps: key 200 + 130 per model + cost 80 + time 48 + gaps 8 × (n + 2) +
// padding 24. Tools: scenario 220 + expects 130 + 160 per model + cost 110
// + gaps 10 × (n + 2) + padding 24.
export const stepsMinWidth = (n) => 368 + 138 * n;
export const toolsMinWidth = (n) => 504 + 170 * n;

// The remembered detail level, `tools` or `steps`, or null for no (valid)
// entry — a storage that is missing, refuses, or answers something else
// (the test harness's stub says 'light' to every key) reads as unset.
export const readDetailChoice = (storage) => {
  try {
    const value = storage?.getItem(DETAIL_STORAGE_KEY);
    return value === 'tools' || value === 'steps' ? value : null;
  } catch {
    return null;
  }
};

// Remembers the detail level, or forgets it for null; a storage that
// refuses (private mode, quota) is left alone.
export const writeDetailChoice = (storage, value) => {
  try {
    if (value == null) storage?.removeItem?.(DETAIL_STORAGE_KEY);
    else storage?.setItem(DETAIL_STORAGE_KEY, value);
  } catch {
    // The chip still works for this page; it is only not remembered.
  }
};

// The build's cursor over `steps` ([{ key, step }] in suite order, every
// in-run scenario — not only the filtered rows, so a filter cannot make
// follow chase a hidden row): the first step being replayed, else the first
// still queued, else none. The runner is sequential and scenario-major, so
// the first `running` step is the one in flight. A `loading` step is a
// result not fetched yet, never a cursor.
export const currentStepKey = (steps = []) =>
  (steps.find((entry) => entry?.step === 'running') || steps.find((entry) => entry?.step === 'queued'))?.key ?? null;

// A group's step from its rows' steps, read like a job of the build: rows
// outside the run (`skipped`, `none`) are ignored once any row is in it;
// a group of nothing but those is `none` when no run exists and `skipped`
// otherwise; results still loading say so first; any row replaying, or a
// mix of queued and settled rows, is `running`; nothing landed yet is
// `queued`; a settled group fails or misses when any row did, else passed.
export const groupStep = (steps = []) => {
  if (!steps.length) return 'none';
  const inRun = steps.filter((step) => step !== 'skipped' && step !== 'none');
  if (!inRun.length) return steps.every((step) => step === 'none') ? 'none' : 'skipped';
  if (inRun.includes('loading')) return 'loading';
  if (inRun.includes('running')) return 'running';
  const queued = inRun.filter((step) => step === 'queued').length;
  if (queued && queued < inRun.length) return 'running';
  if (queued) return 'queued';
  if (inRun.includes('failed')) return 'failed';
  if (inRun.includes('missing')) return 'missing';
  return 'passed';
};

// The box's row order. `suite` is the catalog's order — `rows` itself, so a
// memoised list keeps its identity. `failed-first` is a new array: groups
// (by first appearance, key `row.group || ''`) by failed count, most first,
// and failed rows first within each group, both stably, so the relative
// order of equals stays the suite's. `stepOf(row)` reads a row's step.
export const orderScenarioRows = (rows = [], stepOf = () => null, order = 'suite') => {
  if (order !== 'failed-first') return rows;
  const groups = [];
  const byName = new Map();
  rows.forEach((row) => {
    const name = row?.group || '';
    let group = byName.get(name);
    if (!group) {
      group = { failed: 0, rows: [] };
      byName.set(name, group);
      groups.push(group);
    }
    const failed = stepOf(row) === 'failed';
    if (failed) group.failed += 1;
    group.rows.push({ row, failed });
  });
  return groups
    .sort((a, b) => b.failed - a.failed)
    .flatMap((group) => [...group.rows.filter((entry) => entry.failed), ...group.rows.filter((entry) => !entry.failed)].map((entry) => entry.row));
};

// The groups a run does not touch — none of whose scenarios are among
// `runKeys` — so a partial run starts with them folded as "not in this
// run". Ungrouped scenarios count under ''. Nothing is outside a run that
// covers nothing (no run yet, or an unresolved selection).
export const groupsOutsideRun = (scenarios = [], runKeys = new Set()) => {
  const keys = runKeys instanceof Set ? runKeys : new Set(runKeys || []);
  const outside = new Set();
  if (!keys.size) return outside;
  const covered = new Set();
  scenarios.forEach((scenario) => {
    (keys.has(scenario?.key) ? covered : outside).add(scenario?.group || '');
  });
  covered.forEach((name) => outside.delete(name));
  return outside;
};

// The TIME column: a scenario's slowest settled answer across the run's
// model columns, in ms; null until one has landed. `row` is the scenario's
// results keyed by column.
export const scenarioTime = (row = {}, columns = []) => {
  const times = columns
    .map((label) => row?.[label])
    .filter((result) => result && result.status !== 'pending' && result.duration_ms != null && Number.isFinite(Number(result.duration_ms)))
    .map((result) => Number(result.duration_ms));
  return times.length ? Math.max(...times) : null;
};

const finiteOrNull = (value) => (value != null && Number.isFinite(Number(value)) ? Number(value) : null);

// What one settled result took: `{ durationMs, inputTokens, outputTokens }`,
// each null where the result did not record it; null for a pending or
// missing result, or one that recorded none of the three. A model that
// answers faster, or on fewer tokens, is cheaper to run at scale, so the box
// shows these beside every score.
export const resultMetrics = (result) => {
  if (!result || result.status === 'pending') return null;
  const metrics = {
    durationMs: finiteOrNull(result.duration_ms),
    inputTokens: finiteOrNull(result.input_tokens),
    outputTokens: finiteOrNull(result.output_tokens),
  };
  return metrics.durationMs == null && metrics.inputTokens == null && metrics.outputTokens == null ? null : metrics;
};

// The same figures added up over `results`. A sum stays null where no
// result recorded that figure, so a model without token counts reads "—"
// rather than 0; `count` is how many results contributed. null when none did.
export const sumMetrics = (results = []) => {
  const total = { durationMs: null, inputTokens: null, outputTokens: null, count: 0 };
  results.forEach((result) => {
    const metrics = resultMetrics(result);
    if (!metrics) return;
    total.count += 1;
    ['durationMs', 'inputTokens', 'outputTokens'].forEach((key) => {
      if (metrics[key] != null) total[key] = (total[key] || 0) + metrics[key];
    });
  });
  return total.count ? total : null;
};

// The tokens under a scenario's COST cell: input and output added up over
// its settled results in `columns`, `{ input, output }`; null until one of
// them carries a count.
export const scenarioTokens = (row = {}, columns = []) => {
  const sum = sumMetrics(columns.map((label) => row?.[label]));
  if (!sum || (sum.inputTokens == null && sum.outputTokens == null)) return null;
  return { input: sum.inputTokens, output: sum.outputTokens };
};

// Token pairs added up, for a group's COST cell; a side stays null where no
// pair has it, and the whole is null when there is nothing to add.
export const sumTokens = (pairs = []) => {
  const known = pairs.filter(Boolean);
  if (!known.length) return null;
  const side = (key) => (known.some((pair) => pair[key] != null) ? known.reduce((sum, pair) => sum + (pair[key] || 0), 0) : null);
  return { input: side('input'), output: side('output') };
};

// Per model column, the time and tokens over the given scenarios — every
// key of `resultsByKey` unless `keys` narrows them — as `{ [label]:
// sumMetrics(...) }`: the box's header shows the run's per model, a group
// row its scenarios'.
export const columnTotals = (resultsByKey = {}, columns = [], keys = Object.keys(resultsByKey)) =>
  Object.fromEntries(columns.map((label) => [label, sumMetrics(keys.map((key) => resultsByKey[key]?.[label]))]));

// A group row's TIME: its scenarios' times (each the slowest answer across
// the models) added up; null until one has landed.
export const groupTime = (rows = [], resultsByKey = {}, columns = []) => {
  const times = rows.map((scenario) => scenarioTime(resultsByKey[scenario?.key], columns)).filter((time) => time != null);
  return times.length ? times.reduce((sum, time) => sum + time, 0) : null;
};

// How long a run has taken, in ms: the runtime the API recorded when it has
// one; else from its timestamps — to its completion, or to `now` while it
// runs. null for a run that has not started (pending), one that failed
// (its duration says nothing), or one without a start time.
export const runElapsedMs = (run, now = Date.now()) => {
  if (!run) return null;
  const recorded = run.usage?.runtime_ms;
  if (recorded != null && Number.isFinite(Number(recorded))) return Number(recorded);
  if (run.status === 'pending' || run.status === 'failed' || !run.created_at) return null;
  const started = Date.parse(run.created_at);
  const ended = run.completed_at ? Date.parse(run.completed_at) : now;
  if (!Number.isFinite(started) || !Number.isFinite(ended)) return null;
  return Math.max(0, ended - started);
};

const pad2 = (n) => String(n).padStart(2, '0');

const clockParts = (ms) => {
  const total = Math.max(0, Math.floor(Number(ms) / 1000));
  return { hours: Math.floor(total / 3600), minutes: Math.floor((total % 3600) / 60), seconds: total % 60, total };
};

// A ticking duration: `02:14` under an hour, `1:02:14` above, `—` for none.
export const fmtClock = (ms) => {
  if (ms == null || !Number.isFinite(Number(ms))) return '—';
  const { hours, minutes, seconds } = clockParts(ms);
  return hours ? `${hours}:${pad2(minutes)}:${pad2(seconds)}` : `${pad2(minutes)}:${pad2(seconds)}`;
};

// A settled duration: `58s` under a minute, `12m 04s` under an hour,
// `1h 02m` above, `—` for none.
export const fmtDuration = (ms) => {
  if (ms == null || !Number.isFinite(Number(ms))) return '—';
  const { hours, minutes, seconds, total } = clockParts(ms);
  if (total < 60) return `${total}s`;
  if (!hours) return `${minutes}m ${pad2(seconds)}s`;
  return `${hours}h ${pad2(minutes)}m`;
};

// A span in a cell: to the millisecond under a second (`820ms`), to a tenth
// or a hundredth under a minute (`12.4s`, `5.25s`, as fmtMs reads), and
// fmtDuration's reading from a minute up (`1m 15s`); `—` for none.
export const fmtSpan = (ms) => {
  if (ms == null || !Number.isFinite(Number(ms))) return '—';
  const n = Number(ms);
  if (n >= 60000) return fmtDuration(n);
  return n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 1 : 2).replace(/\.?0+$/, '')}s` : `${Math.round(n)}ms`;
};

// How long to wait between polls of a running run, by how many results it
// already carries: show_run re-sends every result's output each poll, so a
// bigger run is asked less often.
export const pollIntervalFor = (resultCount) => {
  const count = Number(resultCount) || 0;
  if (count <= 500) return 3000;
  if (count <= 2000) return 6000;
  return 10000;
};

// Whether two serialisations of one result show the same thing: id, status,
// score, fault, costs on both sides and the output's length (its text is
// not compared; a result whose output changed without its length is not a
// case the runner produces).
export const sameResult = (a, b) =>
  !!a && !!b
  && a.id === b.id && a.status === b.status && a.score === b.score && a.fault === b.fault && a.cost === b.cost
  && (a.judge_usage?.cost ?? null) === (b.judge_usage?.cost ?? null)
  && (a.output || '').length === (b.output || '').length;

// A poll's results reconciled with the previous poll's: `results` in the
// incoming order, each replaced by its previous object (matched by id) when
// nothing about it changed, so memoised rows keep their identity; `changed`
// says whether anything landed or moved (or the count differs). When nothing
// changed, `results` is `previous` itself.
export const reconcileResults = (previous = [], incoming = []) => {
  const before = new Map();
  (previous || []).forEach((result) => { if (result && result.id != null) before.set(result.id, result); });
  let reused = 0;
  const results = (incoming || []).map((result) => {
    const kept = result && result.id != null ? before.get(result.id) : null;
    if (kept && sameResult(kept, result)) {
      reused += 1;
      return kept;
    }
    return result;
  });
  const changed = results.length !== (previous || []).length || reused !== results.length;
  return { results: changed ? results : previous || [], changed };
};

// A run's results by scenario key, then by model column (`labelFor(result)`
// names the column): { key: { label: result } }. A key whose columns map to
// the same result objects as in `previous` keeps its previous object, and
// the whole map is `previous` when every key did, so a poll that landed two
// results changes two entries.
export const groupResultsByKey = (results = [], labelFor = (result) => result?.model, previous = {}) => {
  const next = {};
  (results || []).forEach((result) => {
    if (!result || !result.scenario_key) return;
    (next[result.scenario_key] ||= {})[labelFor(result)] = result;
  });
  const keys = Object.keys(next);
  let reused = 0;
  keys.forEach((key) => {
    const kept = previous?.[key];
    if (!kept) return;
    const labels = Object.keys(next[key]);
    if (labels.length === Object.keys(kept).length && labels.every((label) => kept[label] === next[key][label])) {
      next[key] = kept;
      reused += 1;
    }
  });
  return previous && reused === keys.length && keys.length === Object.keys(previous).length ? previous : next;
};

// A rail row's bars: each model's when there are few, else one bar for all
// of them — `4 models`, passes summed — whose title lists each model's k/n.
export const combinedBars = (bars = [], max = RAIL_BARS_MAX) => {
  if (bars.length <= max) return bars;
  const sum = (field) => bars.reduce((total, bar) => total + (Number(bar?.[field]) || 0), 0);
  return [{
    label: 'combined',
    short: `${bars.length} models`,
    passed: sum('passed'),
    total: sum('total'),
    title: bars.map((bar) => `${bar.short} ${bar.passed ?? '—'}/${bar.total ?? '—'}`).join(' · '),
  }];
};

// The fetched run details worth keeping — those whose run id is among `ids`
// (nulls ignored). The map itself when nothing is evicted, so state is not
// replaced for no change.
export const keepDetails = (details = {}, ids = []) => {
  const keep = new Set((ids || []).filter((id) => id != null).map(String));
  const entries = Object.entries(details || {});
  const kept = entries.filter(([key]) => keep.has(String(key)));
  return kept.length === entries.length ? details || {} : Object.fromEntries(kept);
};

// Where the box scrolls to put the cursor row about a third of the way down
// the box's visible rows (under the sticky header), from the row's offsetTop
// inside the box. Clamped at the top.
export const cursorScrollTop = ({ rowTop = 0, headerHeight = 0, boxHeight = 0 } = {}) =>
  Math.max(0, rowTop - headerHeight - Math.round((boxHeight - headerHeight) / 3));

// Where the box scrolls to put an opened row directly under the sticky
// column header and its sticky group row, so its drill-down starts in view.
export const openRowScrollTop = ({ rowTop = 0, headerHeight = 0, groupRowHeight = 0 } = {}) =>
  Math.max(0, rowTop - headerHeight - groupRowHeight);
