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

// Per-model summaries of a run, one shape for both kinds of evaluation:
// `{ label, model, provider, samples, passed, avg_score, avg_duration_ms,
// input_tokens, output_tokens, cost, faults, errored, kind }`, where `kind`
// is 'replay' for a scenario run's cohorts and 'sample' for a sampling
// run's. Runs recorded before the runner stored summaries fall back to what
// the criteria stats can tell; a run with no models at all is one cohort
// of everything it scored.
export const runCohorts = (run) => {
  if (!run) return [];
  const scores = run.scores || {};
  const suite = scores._models;
  if (suite && typeof suite === 'object' && Object.keys(suite).length) {
    return Object.entries(suite).map(([label, stats]) => ({
      label, model: stats.model || label, provider: stats.provider || null,
      samples: stats.scenarios ?? null, passed: stats.passed ?? null, errored: stats.errored ?? 0,
      avg_score: stats.avg_score ?? null, avg_duration_ms: stats.avg_duration_ms ?? null,
      input_tokens: stats.input_tokens ?? null, output_tokens: stats.output_tokens ?? null,
      cost: stats.cost ?? null, faults: stats.faults || {}, kind: 'replay',
    }));
  }
  const sampled = scores._cohorts;
  if (sampled && typeof sampled === 'object' && Object.keys(sampled).length) {
    return Object.entries(sampled).map(([model, stats]) => ({
      label: model, model, provider: stats.provider || null,
      samples: stats.samples ?? null, passed: stats.passed ?? null, errored: 0,
      avg_score: null, avg_duration_ms: stats.avg_duration_ms ?? null,
      input_tokens: stats.input_tokens ?? null, output_tokens: stats.output_tokens ?? null,
      cost: stats.cost ?? null, faults: {}, kind: 'sample',
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
        faults: {}, kind: run.selection || scores._selection ? 'replay' : 'sample',
      };
    });
  }
  return [{
    label: null, model: null, provider: null, samples: run.samples_evaluated ?? null, passed: run.samples_passed ?? null,
    errored: 0, avg_score: null, avg_duration_ms: null, input_tokens: null, output_tokens: null, cost: null, faults: {},
    kind: 'sample',
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

// --- spend ------------------------------------------------------------------

// What a run cost, from the API's `usage`, on the two sides that answer
// different questions:
//
// `agent` is the operating figure — what the interactions cost to serve:
// a scenario run's replays (simulated user–agent interactions), or the
// sampled generations a sampling run scored (real ones, served before the
// run). `perInteraction` is that cost per interaction, the number a
// per-conversation budget is set against.
//
// `judge` is the evaluation's own overhead: the judge model's calls, which
// run agent-to-agent, offline. Absent when no judge was asked.
//
// null when the run recorded nothing on either side.
export const runSpend = (run) => {
  const usage = run?.usage;
  if (!usage || typeof usage !== 'object') return null;
  const count = usage.replays ?? usage.samples ?? null;
  const agentCost = usage.cost ?? null;
  const agent = count != null || agentCost != null ? {
    cost: agentCost,
    count: count || 0,
    unit: usage.replays != null ? 'replay' : 'sample',
    perInteraction: usage.per_interaction ?? (agentCost != null && count ? agentCost / count : null),
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
  } : null;
  if (!agent && !judge) return null;
  const total = agent?.cost != null || judge?.cost != null ? (agent?.cost || 0) + (judge?.cost || 0) : null;
  return { agent, judge, total, runtimeMs: usage.runtime_ms ?? null };
};

// The judge's calls by purpose, in the order the runner makes them:
// "score 20 · recommend 3 · verdict 1".
export const judgeCallsText = (judge) => {
  if (!judge) return '';
  const order = ['define', 'score', 'recommend', 'verdict'];
  const kinds = Object.entries(judge.byKind || {}).sort(([a], [b]) => order.indexOf(a) - order.indexOf(b));
  return kinds.map(([kind, count]) => `${kind} ${count}`).join(' · ');
};

// Spend across several runs (the latest complete run of each evaluation, on
// the page): the agent's cost and interactions summed, the per-interaction
// rate over them, and the judge's cost beside it. `priced` counts the runs
// that carried a figure at all.
export const spendSummary = (runs = []) => {
  let agentCost = null;
  let interactions = 0;
  let judgeCost = null;
  let priced = 0;
  runs.forEach((run) => {
    const spend = runSpend(run);
    if (!spend) return;
    priced += 1;
    if (spend.agent?.cost != null) {
      agentCost = (agentCost || 0) + spend.agent.cost;
      interactions += spend.agent.count || 0;
    }
    if (spend.judge?.cost != null) judgeCost = (judgeCost || 0) + spend.judge.cost;
  });
  return {
    agentCost,
    interactions,
    perInteraction: agentCost != null && interactions ? agentCost / interactions : null,
    judgeCost,
    priced,
  };
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
      text: `Scored under the ${PASS_THRESHOLD.toFixed(2)} pass mark. Each line is what the criterion expects against how the samples did; tighten the agent's instructions or revisit the budget before running again.`,
      details: below.map((entry) =>
        `${entry.key}${entry.model ? ` · ${entry.model}` : ''} ${entry.stats.score.toFixed(2)} · expects ${criterionExpectation(entry.criterion)} · ${entry.stats.passed}/${entry.stats.total} passed`),
    });
  }
  return items;
};

// --- model comparison table ---------------------------------------------------

// The fault taxonomy renders lower-case with spaces.
const faultWords = (fault) => String(fault || '').replace(/_/g, ' ');

// One row per model cohort for the comparison table: passed/total, mean
// score, average latency, average tokens per interaction, cost, and the
// model's typical fault — its most frequent one, with the diagnosis of the
// first result that carries it so the row says what went wrong, not only
// how often. Rows are ordered best first (pass rate, then mean score), the
// order a verdict is argued in. Cohort figures come from the run's recorded
// summaries (`_models` / `_cohorts`); while a scenario run is still scoring,
// passed and faults are counted from the results that have landed.
//
// `labelFor(result)` maps a result to its column label (the suite panel's
// labelForResult); it defaults to the result's model name.
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
      inputTokens: cohort.input_tokens ?? null,
      outputTokens: cohort.output_tokens ?? null,
      avgInputTokens: perInteraction(cohort.input_tokens),
      avgOutputTokens: perInteraction(cohort.output_tokens),
      avgTokens: cohort.input_tokens == null && cohort.output_tokens == null
        ? null
        : perInteraction((cohort.input_tokens || 0) + (cohort.output_tokens || 0)),
      cost: cohort.cost ?? null,
      costPerInteraction: perInteraction(cohort.cost),
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
