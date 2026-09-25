import React, { useEffect, useId, useMemo, useState } from 'react';
import { Button, Card, MicroLabel, MONO } from '../primitives';
import ModelPicker from '../ModelPicker';
import MultiModelPicker from '../MultiModelPicker';
import { useProviderModels } from '../../../hooks/useProviderModels';
import { MODEL_PROVIDERS } from '../../../utils/providerModels';
import { buildModelOptions, parseModelList, requalifyModels, serializeModelList } from '../../../utils/modelOptions.mjs';

// Creating an evaluation: which agent, which criteria, whether a judge model
// defines or scores them, and — pasted as user messages — the scenarios that
// make it a suite. Submitting creates the evaluation and runs it once, so the
// list always has a first run to show.

const RULE_CRITERIA = [
  { type: 'response_present', key: 'response_present', label: 'Response present', config: {} },
  { type: 'min_length', key: 'response_length', label: 'Response length ≥ 40 chars', config: { chars: 40 } },
  { type: 'max_latency_ms', key: 'latency', label: 'Latency ≤ 5s', config: { ms: 5000 } },
  { type: 'token_budget', key: 'token_budget', label: 'Output ≤ 1000 tokens', config: { output_tokens: 1000 } },
];

// Scored from the agent's telemetry traces (aggregates over the last 7
// days), not from sampled generations.
const TELEMETRY_CRITERIA = [
  { type: 'trace_error_rate', key: 'trace_error_rate', label: 'Trace error rate ≤ 5% (telemetry, 7d)', config: { max_error_rate: 5, window_hours: 168 } },
  { type: 'trace_latency', key: 'trace_latency', label: 'Avg trace latency ≤ 5s (telemetry, 7d)', config: { max_avg_ms: 5000, window_hours: 168 } },
];

const inputStyle = {
  padding: '8px 12px', borderRadius: 8, fontSize: 13, fontFamily: 'inherit', boxSizing: 'border-box',
  background: 'var(--color-card)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)',
};

const hintStyle = { margin: '6px 0 0', fontSize: 12, color: 'var(--color-text-muted)' };

const PROVIDER_NAMES = { openai: 'OpenAI', anthropic: 'Anthropic', ollama: 'Ollama', openrouter: 'OpenRouter' };

// From GET /api/evaluations:
//   - judgeProvider:       the provider the judge runs on, null when none
//                          has credentials or they could not be read, and
//                          undefined until known
//   - judgeProviderError:  true when the credentials could not be read
//   - modelProviders:      the providers runs have credentials for, null
//                          when the evaluations list did not say, and
//                          undefined until known
export default function EvaluationForm({
  agents, agentId, judgeProvider, judgeProviderError = false, modelProviders, onCreated, onCancel,
}) {
  const [form, setForm] = useState({
    agent_id: agentId ? String(agentId) : '', name: '', sample_size: 20,
    criteria: RULE_CRITERIA.map((c) => c.key),
    containsPattern: '', llmJudgePrompt: '',
    judgeKind: 'manual', judgeModel: '', compareModels: '', scenariosText: '',
    // The `restore` requalifyModels returned for compareModels: what each
    // bare name stood for before the scenarios were cleared.
    compareRestore: new Map(),
  });
  const [formError, setFormError] = useState(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const fieldId = useId();

  const runProviders = useMemo(
    () => (modelProviders === undefined ? [] : (modelProviders ?? MODEL_PROVIDERS)),
    [modelProviders],
  );
  const catalog = useProviderModels(
    judgeProvider && !runProviders.includes(judgeProvider) ? [...runProviders, judgeProvider] : runProviders,
  );
  const recordedModels = useRecordedModels(form.agent_id);

  // The judge runs judge_model as its provider's own model id.
  const judgeOptions = useMemo(
    () => (judgeProvider ? buildModelOptions(catalog, { providers: [judgeProvider], qualify: false }) : []),
    [catalog, judgeProvider],
  );
  // With scenarios, each compared model replays them, so the catalog is
  // offered with each name resolving to its provider the way a scenario run
  // reads it. Without, the names select the agent's generations by the model
  // name each was recorded under, so those names are offered.
  const hasScenarios = Boolean(form.scenariosText.trim());
  const compareOptions = useMemo(
    () => (hasScenarios ? buildModelOptions(catalog, { providers: runProviders }) : recordedModels),
    [catalog, runProviders, hasScenarios, recordedModels],
  );

  const update = (patch) => setForm((prev) => ({ ...prev, ...patch }));
  // Adding or clearing the scenarios changes how each compared model is
  // read, so the catalog models already chosen are renamed to match. Adding
  // back scenarios that were cleared restores the names chosen with them.
  const updateScenarios = (scenariosText) => setForm((prev) => {
    const qualify = Boolean(scenariosText.trim());
    if (qualify === Boolean(prev.scenariosText.trim())) return { ...prev, scenariosText };

    const { models, restore } = requalifyModels(parseModelList(prev.compareModels), catalog, {
      providers: runProviders, qualify, restore: prev.compareRestore,
    });
    return { ...prev, scenariosText, compareModels: serializeModelList(models), compareRestore: restore };
  });
  const toggleCriterion = (key, checked) =>
    update({ criteria: checked ? [...form.criteria, key] : form.criteria.filter((k) => k !== key) });

  const buildCriteria = () => {
    const criteria = [...RULE_CRITERIA, ...TELEMETRY_CRITERIA]
      .filter((c) => form.criteria.includes(c.key))
      .map(({ key, type, config }) => ({ key, type, config }));
    if (form.containsPattern.trim()) {
      criteria.push({ key: 'contains', type: 'contains', config: { pattern: form.containsPattern.trim() } });
    }
    if (form.llmJudgePrompt.trim()) {
      criteria.push({ key: 'quality', type: 'llm_judge', config: { prompt: form.llmJudgePrompt.trim() } });
    }
    return criteria;
  };

  const handleCreate = async (event) => {
    event.preventDefault();
    setIsSubmitting(true);
    setFormError(null);
    try {
      const response = await fetch('/api/evaluations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          evaluation: {
            agent_id: form.agent_id,
            name: form.name,
            sample_size: form.sample_size,
            judge_kind: form.judgeKind === 'judge_defined'
              ? 'judge_defined'
              : (form.llmJudgePrompt.trim() ? 'llm' : 'rules'),
            judge_model: form.judgeModel.trim() || undefined,
            compare_models: parseModelList(form.compareModels),
            criteria: form.judgeKind === 'judge_defined' ? [] : buildCriteria(),
            scenarios_text: form.scenariosText.trim() || undefined,
          },
        }),
      });
      // A non-JSON body (an HTML error page, a sign-in redirect) used to
      // surface as "Unexpected token <" in the form.
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error((data.errors || [data.error]).filter(Boolean).join(', ') || `Failed to create evaluation (HTTP ${response.status})`);
      onCreated?.(data.evaluation);
    } catch (error) {
      setFormError(error.message);
    } finally {
      setIsSubmitting(false);
    }
  };

  const checkbox = (criterion) => (
    <label key={criterion.key} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--color-text-primary)' }}>
      <input
        type="checkbox"
        checked={form.criteria.includes(criterion.key)}
        onChange={(e) => toggleCriterion(criterion.key, e.target.checked)}
        style={{ accentColor: 'var(--color-accent-ui)' }}
      />
      {criterion.label}
    </label>
  );

  return (
    <Card testId="new-evaluation-form">
      <form onSubmit={handleCreate} style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>Agent</MicroLabel>
            <select
              required
              disabled={!!agentId}
              value={form.agent_id}
              onChange={(e) => update({ agent_id: e.target.value })}
              style={{ ...inputStyle, width: '100%', opacity: agentId ? 0.7 : 1 }}
            >
              {!agentId && <option value="">Select agent…</option>}
              {agents.map((agent) => (
                <option key={agent.id} value={agent.id}>{agent.name}</option>
              ))}
            </select>
          </div>
          <div>
            <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>Name</MicroLabel>
            <input
              required
              type="text"
              value={form.name}
              onChange={(e) => update({ name: e.target.value })}
              placeholder="Response Quality"
              style={{ ...inputStyle, width: '100%' }}
            />
          </div>
          <div>
            <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>Sample size</MicroLabel>
            <input
              type="number" min="1" max="100"
              value={form.sample_size}
              onChange={(e) => update({ sample_size: e.target.value })}
              style={{ ...inputStyle, width: '100%', fontFamily: MONO }}
            />
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>KPI definition</MicroLabel>
            <select
              value={form.judgeKind}
              onChange={(e) => update({ judgeKind: e.target.value })}
              style={{ ...inputStyle, width: '100%' }}
            >
              <option value="manual">Manual criteria</option>
              <option value="judge_defined">Judge defines KPIs from agent goals</option>
            </select>
          </div>
          <div>
            <MicroLabel as="label" htmlFor={`${fieldId}-judge`} style={{ display: 'block', marginBottom: 6 }}>Judge model (optional)</MicroLabel>
            <ModelPicker
              id={`${fieldId}-judge`}
              aria-describedby={judgeProvider === undefined ? undefined : `${fieldId}-judge-provider`}
              value={form.judgeModel}
              models={judgeOptions}
              onChange={(value) => update({ judgeModel: value })}
              style={{ ...inputStyle, width: '100%', fontFamily: MONO, fontSize: 12 }}
            />
            {judgeProvider !== undefined && (
              <p id={`${fieldId}-judge-provider`} style={hintStyle}>
                {judgeProviderHint(judgeProvider, judgeProviderError)}
              </p>
            )}
          </div>
          <div>
            <MicroLabel as="label" htmlFor={`${fieldId}-compare`} style={{ display: 'block', marginBottom: 6 }}>Compare models (optional)</MicroLabel>
            <MultiModelPicker
              inputId={`${fieldId}-compare`}
              describedBy={`${fieldId}-compare-hint`}
              value={form.compareModels}
              onChange={(value) => update({ compareModels: value })}
              models={compareOptions}
              placeholder="e.g. claude-haiku-4-5, qwen3:8b"
              style={{ ...inputStyle, width: '100%', fontFamily: MONO, fontSize: 12 }}
            />
            <p id={`${fieldId}-compare-hint`} style={hintStyle}>
              {hasScenarios
                ? 'Each model replays the scenarios. Any model name can be typed.'
                : "Compares the agent's generations recorded under each model name. Add scenarios to try any model."}
            </p>
          </div>
        </div>

        <div>
          <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>
            Scenarios (optional) — paste user messages to replay, one per line
          </MicroLabel>
          <textarea
            value={form.scenariosText}
            onChange={(e) => updateScenarios(e.target.value)}
            rows={form.scenariosText ? 8 : 3}
            placeholder={'# Find records\nWhich catalog items are available? | tools: find_records\n# Change history\nWho updated the description for the sample notebook?'}
            style={{ ...inputStyle, width: '100%', fontFamily: MONO, fontSize: 12, lineHeight: '18px' }}
          />
          <p style={{ margin: '6px 0 0', fontSize: 12, color: 'var(--color-text-muted)', textWrap: 'pretty' }}>
            With scenarios, each run replays every message through the agent — once per model in “Compare models” — and
            reports which tasks it completes, what faults it hits, and how to fix them. <code style={{ fontFamily: MONO }}># Heading</code> lines group related
            tasks so they can be run together; <code style={{ fontFamily: MONO }}>| tools: a, b</code> names the tool a task should call.
          </p>
        </div>

        {form.judgeKind === 'judge_defined' ? (
          <p style={{ margin: 0, fontSize: 12, color: 'var(--color-text-secondary)' }}>
            On the first run the judge reads the agent's instructions and recent interactions,
            defines 3–6 KPIs, then scores samples against them. KPIs persist so later runs
            (and model cohorts) stay comparable.
          </p>
        ) : (
          <>
            <div>
              <MicroLabel style={{ display: 'block', marginBottom: 8 }}>Rule-based criteria (sampled generations)</MicroLabel>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>{RULE_CRITERIA.map(checkbox)}</div>
            </div>
            <div>
              <MicroLabel style={{ display: 'block', marginBottom: 8 }}>Telemetry criteria (trace aggregates)</MicroLabel>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>{TELEMETRY_CRITERIA.map(checkbox)}</div>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>Must contain (optional pattern)</MicroLabel>
                <input
                  type="text"
                  value={form.containsPattern}
                  onChange={(e) => update({ containsPattern: e.target.value })}
                  placeholder="e.g. password reset"
                  style={{ ...inputStyle, width: '100%' }}
                />
              </div>
              <div>
                <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>LLM judge criterion (optional, needs provider credentials)</MicroLabel>
                <input
                  type="text"
                  value={form.llmJudgePrompt}
                  onChange={(e) => update({ llmJudgePrompt: e.target.value })}
                  placeholder="e.g. Is the answer helpful and accurate?"
                  style={{ ...inputStyle, width: '100%' }}
                />
              </div>
            </div>
          </>
        )}

        {formError && <div style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{formError}</div>}

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <Button variant="primary" type="submit" disabled={isSubmitting}>
            {isSubmitting ? (form.scenariosText.trim() ? 'Creating & starting run…' : 'Creating & running…') : 'Create & Run'}
          </Button>
          {onCancel && <Button onClick={onCancel}>Cancel</Button>}
        </div>
      </form>
    </Card>
  );
}

// Returns the hint under the judge model field for a known judgeProvider.
function judgeProviderHint(judgeProvider, judgeProviderError) {
  if (judgeProvider) return `The judge runs on ${PROVIDER_NAMES[judgeProvider] || judgeProvider}.`;
  if (judgeProviderError) {
    return "Provider credentials could not be read, so the judge's provider is unknown. Check the provider API keys in Settings.";
  }
  return 'No provider has credentials for a judge. Add a provider API key in Settings.';
}

// Returns the model names the agent's generations were recorded under, most
// recently used first; empty while loading, without an agent, or when the
// request fails.
function useRecordedModels(agentId) {
  const [models, setModels] = useState([]);

  useEffect(() => {
    setModels([]);
    if (!agentId) return undefined;

    let cancelled = false;
    fetch(`/api/agents/${encodeURIComponent(agentId)}/recorded_models`)
      .then((response) => (response.ok ? response.json() : {}))
      .then((data) => { if (!cancelled && Array.isArray(data.models)) setModels(data.models); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [agentId]);

  return models;
}
