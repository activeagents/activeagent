// Who judged a run and how its judge is configured, from what the run
// recorded (scores._judge, written by EvaluationRunnerService#judge_descriptor)
// and the evaluation's own judge_model. Runs recorded before the descriptor
// existed have none, and show only their label.

// Where the model a judge asked for came from, in the order the engine
// applies them.
export const JUDGE_MODEL_SOURCES = {
  evaluation: 'pinned on this evaluation',
  provider_key: "the provider key's default model",
  config: "the host's config/active_agent.yml",
  provider_default: "the provider's own default",
};

// What a provider runs when it is asked for no model, where that is known.
// OpenRouter's is a router that can answer each call with a different model.
export const PROVIDER_DEFAULT_MODELS = { openrouter: 'openrouter/auto' };

export const judgeInfo = (evaluation, run) => {
  const judge = run?.scores?._judge;
  if (!judge || typeof judge !== 'object') return null;

  const source = JUDGE_MODEL_SOURCES[judge.model_source] ? judge.model_source : 'provider_default';
  const answered = Object.entries(judge.answered || {})
    .filter(([, calls]) => Number(calls) > 0)
    .sort(([a, x], [b, y]) => y - x || a.localeCompare(b));
  const requested = judge.model || null;
  return {
    agent: judge.agent || 'EvaluationJudgeAgent',
    provider: judge.provider || null,
    requested,
    source,
    sourceText: JUDGE_MODEL_SOURCES[source],
    providerDefault: PROVIDER_DEFAULT_MODELS[judge.provider] || null,
    answered,
    // No model asked for: the provider chose, and may choose differently next run.
    auto: !requested,
    // The evaluation's setting now, which the next run uses; it can differ
    // from what this run recorded.
    pinned: evaluation?.judge_model || null,
    // What the pin field offers: the current pin, else what this run asked
    // for, else the one model that answered.
    suggestion: evaluation?.judge_model || requested || (answered.length === 1 ? answered[0][0] : ''),
  };
};

// The chip's hover text: the judge in one line.
export const judgeTitle = (info) => {
  if (!info) return '';
  const asked = info.requested
    ? `${info.requested} (${info.sourceText})`
    : `${info.providerDefault || 'no model'} (${info.sourceText})`;
  const answered = info.answered.map(([model, calls]) => `${model} ×${calls}`).join(', ');
  return `${info.agent} on ${info.provider || 'no provider'} · asked for ${asked}${answered ? ` · answered by ${answered}` : ''}`;
};
