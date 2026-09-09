import React, { useState, useEffect, useCallback, useRef } from 'react';
import { dashboardPath, dashboardRelativePath, pushDashboardPath } from '../../utils/dashboardPath';
import { useTheme } from '../../contexts/ThemeContext';
import ScenarioSuitePanel from './ScenarioSuitePanel';
import { Badge, Button, Card, Glyph, MicroLabel, StatCard, MONO, TONE, toneFor } from './primitives';
import { fmtCost, fmtK, fmtMs, fmtPct, fmtScore, timeAgo } from '../../utils/format';
import { plural } from './EvaluationRunPanels';

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

const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content;

const formatRunUsage = (usage) => {
  if (!usage) return null;
  const tokens = (usage.input_tokens || 0) + (usage.output_tokens || 0);
  const runtime = usage.runtime_ms == null ? null : fmtMs(usage.runtime_ms);
  return `${fmtCost(usage.cost)} · ${fmtK(tokens)} tok${runtime ? ` · ${runtime}` : ''}`;
};

// Mean-score tone: a score is not a pass ratio, so it keeps the thresholds
// the sampling evaluations have always used.
const scoreTone = (value) => (value >= 0.85 ? 'success' : value >= 0.7 ? 'warning' : 'error');

// The report sub-route under /evaluations, when the current URL names one.
const reportRefFromPath = () => {
  const match = dashboardRelativePath().match(/^\/evaluations\/(\d+)\/runs\/(\d+)\/report/);
  return match ? { evaluationId: match[1], runId: match[2] } : null;
};

const inputStyle = {
  padding: '8px 12px', borderRadius: 8, fontSize: 13, fontFamily: 'inherit', boxSizing: 'border-box',
  background: 'var(--color-card)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)',
};

const monoStyle = (size = 11, color = 'var(--color-text-muted)') => ({ fontFamily: MONO, fontSize: size, color });

// A criterion score bar for a sampling evaluation: label · track · score.
function ScoreRow({ label, score, indent = false, mono = false }) {
  const tone = score.skipped ? null : scoreTone(score.score);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 16, paddingLeft: indent ? 16 : 0 }}>
      <div
        style={{ width: 160, flexShrink: 0, fontSize: mono ? 11 : 13, fontFamily: mono ? MONO : 'inherit', color: 'var(--color-text-secondary)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}
        title={label}
      >
        {mono ? label : label.replace(/_/g, ' ')}
        {score.source === 'telemetry' && (
          <span
            data-testid="score-source-telemetry"
            style={{ ...monoStyle(10), marginLeft: 6, textTransform: 'uppercase', letterSpacing: '0.05em' }}
            title={`Aggregate over ${score.traces} traces in the last ${score.window_hours}h`}
          >
            telemetry
          </span>
        )}
      </div>
      {score.skipped ? (
        <div style={{ flex: 1, fontSize: 12, fontStyle: 'italic', color: 'var(--color-text-muted)' }} title={score.reason}>
          skipped — {score.reason}
        </div>
      ) : (
        <>
          <div style={{ flex: 1, height: 6, borderRadius: 999, background: 'var(--color-muted)', overflow: 'hidden' }}>
            <div style={{ height: '100%', width: `${Math.round(score.score * 100)}%`, borderRadius: 999, background: TONE[tone].strong }} />
          </div>
          <div
            style={{ width: 48, textAlign: 'right', fontFamily: MONO, fontSize: 12, fontWeight: 600, color: TONE[tone].strong }}
            title={`min ${score.min} · max ${score.max} · ${score.passed}/${score.total} passed`}
          >
            {fmtScore(score.score)}
          </div>
        </>
      )}
    </div>
  );
}

// embedded hides the page title when this renders inside the agent detail
// page's Evals tab, which already carries the heading. agentId scopes every
// number on the page to that agent — an account-wide average score under one
// agent's name reads as that agent's score, which it is not.
export default function EvaluationsView({ embedded = false, agentId = null }) {
  const { darkMode } = useTheme();
  // Which run's report the URL asks for; the agent page's embedded Evals tab
  // has no URL of its own, so it never routes.
  const [reportRef, setReportRef] = useState(() => (embedded ? null : reportRefFromPath()));
  // The report page is one document of unknown length; framing it at a fixed
  // height buried its fix items behind a nested scrollbar. The frame is
  // same-origin, so it can be sized to its own content and the dashboard page
  // scrolls as one.
  const reportFrame = useRef(null);
  // Bumped when the framed document loads, so the sizing effect re-runs
  // against the new document rather than the one it replaced.
  const [reportLoads, setReportLoads] = useState(0);
  const [reportHeight, setReportHeight] = useState(null);

  // Observing lives in an effect rather than the load handler: React discards
  // what a handler returns, so an observer created there is never disconnected
  // and outlives every navigation away from the report.
  useEffect(() => {
    const body = reportFrame.current?.contentDocument?.body;
    if (!body) return undefined;

    // Measure the body, never the documentElement: the <html> box grows to
    // whatever height this effect just gave the frame, so measuring it feeds
    // the resize back into itself and the frame grows on every navigation.
    const measure = () => setReportHeight(body.scrollHeight);
    measure();
    // Same fallback the chart width hook uses: a runtime without
    // ResizeObserver still resizes with the window rather than throwing.
    if (typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', measure);
      return () => window.removeEventListener('resize', measure);
    }
    const observer = new ResizeObserver(measure);
    observer.observe(body);
    return () => observer.disconnect();
  }, [reportLoads, reportRef]);

  // A new report is framed at the fallback height until its own is measured;
  // keeping the stale one would size the next report to the last one.
  useEffect(() => setReportHeight(null), [reportRef]);

  useEffect(() => {
    if (embedded) return undefined;
    const applyPath = () => setReportRef(reportRefFromPath());
    window.addEventListener('popstate', applyPath);
    window.addEventListener('dashboard:navigate', applyPath);
    return () => {
      window.removeEventListener('popstate', applyPath);
      window.removeEventListener('dashboard:navigate', applyPath);
    };
  }, [embedded]);
  const [evaluations, setEvaluations] = useState([]);
  const [agents, setAgents] = useState([]);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  // Accordion state per evaluation; the first suite opens by default.
  const [openIds, setOpenIds] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [runningId, setRunningId] = useState(null);
  const [deletingId, setDeletingId] = useState(null);
  const [form, setForm] = useState({
    agent_id: agentId ? String(agentId) : '', name: '', sample_size: 20,
    criteria: RULE_CRITERIA.map((c) => c.key),
    containsPattern: '', llmJudgePrompt: '',
    judgeKind: 'manual', judgeModel: '', compareModels: '', scenariosText: '',
  });
  const [formError, setFormError] = useState(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const fetchEvaluations = useCallback(async () => {
    try {
      // Scoped server-side: the endpoint caps at the 50 most recent, so
      // narrowing here rather than after the fetch is what makes an agent's
      // older evaluations reachable at all.
      const response = await fetch(`/api/evaluations${agentId ? `?agent_id=${encodeURIComponent(agentId)}` : ''}`);
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      const data = await response.json();
      const list = data.evaluations || [];
      setEvaluations(list);
      setOpenIds((current) => {
        if (current) return current;
        const first = list.find((e) => e.scenario_suite) || list[0];
        return new Set(first ? [first.id] : []);
      });
      setLoadError(null);
    } catch (error) {
      setLoadError(error.message);
    } finally {
      setIsLoading(false);
    }
  }, [agentId]);

  useEffect(() => {
    fetchEvaluations();
    fetch('/api/agents')
      .then((r) => (r.ok ? r.json() : { agents: [] }))
      .then((data) => setAgents(data.agents || []))
      .catch(() => setAgents([]));
  }, [fetchEvaluations]);

  const isOpen = (id) => !!openIds?.has(id);
  const toggleOpen = (id) => setOpenIds((current) => {
    const next = new Set(current || []);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    return next;
  });

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
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken() },
        body: JSON.stringify({
          evaluation: {
            agent_id: form.agent_id,
            name: form.name,
            sample_size: form.sample_size,
            judge_kind: form.judgeKind === 'judge_defined'
              ? 'judge_defined'
              : (form.llmJudgePrompt.trim() ? 'llm' : 'rules'),
            judge_model: form.judgeModel.trim() || undefined,
            compare_models: form.compareModels.split(',').map((m) => m.trim()).filter(Boolean),
            criteria: form.judgeKind === 'judge_defined' ? [] : buildCriteria(),
            scenarios_text: form.scenariosText.trim() || undefined,
          },
        }),
      });
      // A non-JSON body (an HTML error page, a sign-in redirect) used to
      // surface as "Unexpected token <" in the form.
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error((data.errors || [data.error]).filter(Boolean).join(', ') || `Failed to create evaluation (HTTP ${response.status})`);
      setShowForm(false);
      setForm({ ...form, name: '', scenariosText: '' });
      await fetchEvaluations();
      if (data.evaluation?.id != null) setOpenIds((current) => new Set([...(current || []), data.evaluation.id]));
    } catch (error) {
      setFormError(error.message);
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleRun = async (id) => {
    setRunningId(id);
    setLoadError(null);
    try {
      const response = await fetch(`/api/evaluations/${id}/run`, {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken() },
      });
      if (!response.ok) setLoadError(`Run failed (HTTP ${response.status})`);
      await fetchEvaluations();
    } finally {
      setRunningId(null);
    }
  };

  // DELETE /api/evaluations/:id has always existed; nothing in the UI called
  // it, so a mis-created evaluation permanently blocked reuse of its name.
  const handleDelete = async (evaluation) => {
    if (!window.confirm(`Delete "${evaluation.name}"? Its runs are deleted with it.`)) return;
    setDeletingId(evaluation.id);
    setLoadError(null);
    try {
      const response = await fetch(`/api/evaluations/${evaluation.id}`, {
        method: 'DELETE',
        headers: { 'X-CSRF-Token': csrfToken() },
      });
      if (response.ok || response.status === 404) {
        setEvaluations((prev) => prev.filter((e) => e.id !== evaluation.id));
        setOpenIds((current) => {
          const next = new Set(current || []);
          next.delete(evaluation.id);
          return next;
        });
      } else {
        setLoadError(`Delete failed (HTTP ${response.status})`);
      }
    } finally {
      setDeletingId(null);
    }
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2" style={{ borderBottomColor: 'var(--color-accent-ui)' }} />
      </div>
    );
  }

  // The request is already scoped; this is a belt-and-braces guard so the
  // list, the summary cards, and the empty state can never disagree.
  const shownEvaluations = agentId
    ? evaluations.filter((e) => String(e.agent?.id) === String(agentId))
    : evaluations;

  // Page stats, from the latest complete run of each scenario suite: a
  // scenario run is one scenario × one model, and every failed run carries
  // exactly one fault.
  const suites = shownEvaluations.filter((e) => e.scenario_suite);
  const sampling = shownEvaluations.filter((e) => !e.scenario_suite);
  const latestRuns = suites.map((e) => e.latest_run).filter((r) => r && r.status === 'complete');
  const pageRuns = latestRuns.reduce((sum, r) => sum + (r.samples_evaluated || 0), 0);
  const pagePassed = latestRuns.reduce((sum, r) => sum + (r.samples_passed || 0), 0);
  const pageFixes = latestRuns.reduce((sum, r) => sum + (r.scores?._recommendations?.length || 0), 0);
  const passRatio = pageRuns ? pagePassed / pageRuns : null;
  const agentNames = [...new Set(suites.map((e) => e.agent?.name).filter(Boolean))];
  const modelsCompared = suites.reduce((max, e) => Math.max(max, e.latest_run?.models?.length || (e.compare_models || []).length || 0), 0);
  const suitesSubParts = [];
  if (agentNames.length === 1) suitesSubParts.push(`@${agentNames[0]} · ${modelsCompared > 1 ? `${modelsCompared} models compared` : '1 model'}`);
  else if (agentNames.length > 1) suitesSubParts.push(plural(agentNames.length, 'agent'));
  if (sampling.length) suitesSubParts.push(plural(sampling.length, 'sampling evaluation'));
  const suitesSub = suitesSubParts.join(' · ') || 'no suites yet';

  // A comparison run stores each sample criterion as {model: stats} instead
  // of flat stats — detect by the absence of score/skipped keys.
  const isCohortMap = (score) =>
    score && typeof score === 'object' && !('score' in score) && !('skipped' in score);

  if (reportRef) {
    const reportUrl = dashboardPath(`/api/evaluations/${reportRef.evaluationId}/runs/${reportRef.runId}/report`);
    const framedUrl = `${reportUrl}?theme=${darkMode ? 'dark' : 'light'}`;
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <Button size="sm" onClick={() => { pushDashboardPath('/evaluations'); setReportRef(null); }}>
              <span style={{ fontFamily: MONO }}>{'<-'}</span> Evaluations
            </Button>
            <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>Run report</h1>
            <span style={monoStyle(11)}>{`evaluation ${reportRef.evaluationId} · run ${reportRef.runId}`}</span>
          </div>
          <a
            href={reportUrl}
            target="_blank"
            rel="noopener noreferrer"
            title="The report is one self-contained page — save it to export"
            style={{ padding: '6px 12px', borderRadius: 8, fontSize: 13, fontWeight: 500, color: 'var(--color-text-cell)', border: '1px solid var(--color-border-strong)', textDecoration: 'none' }}
          >
            Open standalone <span style={{ fontFamily: MONO }}>{'->'}</span>
          </a>
        </div>
        <iframe
          ref={reportFrame}
          src={framedUrl}
          title="Evaluation run report"
          onLoad={() => setReportLoads((n) => n + 1)}
          scrolling="no"
          style={{
            width: '100%', borderRadius: 12, border: '1px solid var(--color-border)',
            background: 'var(--color-background)', display: 'block',
            height: reportHeight ? `${reportHeight}px` : 'calc(100vh - 180px)',
          }}
        />
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      {/* Header — embedded in the agent page, that page owns the heading. */}
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16, flexWrap: 'wrap' }}>
        {!embedded && (
          <div style={{ flex: 1, minWidth: 260 }}>
            <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>Evaluations</h1>
            <p style={{ margin: '4px 0 0', fontSize: 14, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>
              Score recorded outputs, or paste a list of user messages to replay through the agent under one or more models
            </p>
          </div>
        )}
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 12 }}>
          <Button variant="primary" onClick={() => setShowForm(!showForm)} testId="new-evaluation-button">
            {showForm ? 'Cancel' : 'New Evaluation'}
          </Button>
        </div>
      </div>

      {loadError && (
        <div style={{ padding: '10px 12px', borderRadius: 8, fontSize: 13, background: 'var(--color-error-soft)', color: 'var(--color-error-text)' }}>
          Failed to load evaluations: {loadError}
        </div>
      )}

      {/* New Evaluation form */}
      {showForm && (
        <Card testId="new-evaluation-form">
          <form onSubmit={handleCreate} style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>Agent</MicroLabel>
                <select
                  required
                  disabled={!!agentId}
                  value={form.agent_id}
                  onChange={(e) => setForm({ ...form, agent_id: e.target.value })}
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
                  onChange={(e) => setForm({ ...form, name: e.target.value })}
                  placeholder="Response Quality"
                  style={{ ...inputStyle, width: '100%' }}
                />
              </div>
              <div>
                <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>Sample size</MicroLabel>
                <input
                  type="number" min="1" max="100"
                  value={form.sample_size}
                  onChange={(e) => setForm({ ...form, sample_size: e.target.value })}
                  style={{ ...inputStyle, width: '100%', fontFamily: MONO }}
                />
              </div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>KPI definition</MicroLabel>
                <select
                  value={form.judgeKind}
                  onChange={(e) => setForm({ ...form, judgeKind: e.target.value })}
                  style={{ ...inputStyle, width: '100%' }}
                >
                  <option value="manual">Manual criteria</option>
                  <option value="judge_defined">Judge defines KPIs from agent goals</option>
                </select>
              </div>
              <div>
                <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>Judge model (optional)</MicroLabel>
                <input
                  type="text"
                  value={form.judgeModel}
                  onChange={(e) => setForm({ ...form, judgeModel: e.target.value })}
                  placeholder="e.g. claude-opus-5"
                  style={{ ...inputStyle, width: '100%', fontFamily: MONO, fontSize: 12 }}
                />
              </div>
              <div>
                <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>Compare models (optional, comma-separated)</MicroLabel>
                <input
                  type="text"
                  value={form.compareModels}
                  onChange={(e) => setForm({ ...form, compareModels: e.target.value })}
                  placeholder="e.g. claude-haiku-4-5, qwen3:8b"
                  style={{ ...inputStyle, width: '100%', fontFamily: MONO, fontSize: 12 }}
                />
              </div>
            </div>

            <div>
              <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>
                Scenarios (optional) — paste user messages to replay, one per line
              </MicroLabel>
              <textarea
                value={form.scenariosText}
                onChange={(e) => setForm({ ...form, scenariosText: e.target.value })}
                rows={form.scenariosText ? 8 : 3}
                placeholder={'# Find records\nWhich gynecologists in Charlotte have scheduling enabled? | tools: find_records\n# Blame\nWho changed the biography for Dr. AbdelRazek?'}
                style={{ ...inputStyle, width: '100%', fontFamily: MONO, fontSize: 12, lineHeight: '18px' }}
              />
              <p style={{ margin: '6px 0 0', fontSize: 12, color: 'var(--color-text-muted)', textWrap: 'pretty' }}>
                With scenarios, each run replays every message through the agent — once per model in “Compare models” — and
                reports which tasks it completes, what faults it hits, and how to fix them. <code style={{ fontFamily: MONO }}># Heading</code> lines group related
                tasks so they can be run together; <code style={{ fontFamily: MONO }}>| tools: a, b</code> names the tool a task should call.
              </p>
            </div>

            {form.judgeKind === 'judge_defined' && (
              <p style={{ margin: 0, fontSize: 12, color: 'var(--color-text-secondary)' }}>
                On the first run the judge reads the agent's instructions and recent interactions,
                defines 3–6 KPIs, then scores samples against them. KPIs persist so later runs
                (and model cohorts) stay comparable.
              </p>
            )}

            {form.judgeKind !== 'judge_defined' && (<>
            <div>
              <MicroLabel style={{ display: 'block', marginBottom: 8 }}>Rule-based criteria (sampled generations)</MicroLabel>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>
                {RULE_CRITERIA.map((criterion) => (
                  <label key={criterion.key} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--color-text-primary)' }}>
                    <input
                      type="checkbox"
                      checked={form.criteria.includes(criterion.key)}
                      onChange={(e) => setForm({
                        ...form,
                        criteria: e.target.checked
                          ? [...form.criteria, criterion.key]
                          : form.criteria.filter((k) => k !== criterion.key),
                      })}
                    />
                    {criterion.label}
                  </label>
                ))}
              </div>
            </div>

            <div>
              <MicroLabel style={{ display: 'block', marginBottom: 8 }}>Telemetry criteria (trace aggregates)</MicroLabel>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>
                {TELEMETRY_CRITERIA.map((criterion) => (
                  <label key={criterion.key} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--color-text-primary)' }}>
                    <input
                      type="checkbox"
                      checked={form.criteria.includes(criterion.key)}
                      onChange={(e) => setForm({
                        ...form,
                        criteria: e.target.checked
                          ? [...form.criteria, criterion.key]
                          : form.criteria.filter((k) => k !== criterion.key),
                      })}
                    />
                    {criterion.label}
                  </label>
                ))}
              </div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>Must contain (optional pattern)</MicroLabel>
                <input
                  type="text"
                  value={form.containsPattern}
                  onChange={(e) => setForm({ ...form, containsPattern: e.target.value })}
                  placeholder="e.g. password reset"
                  style={{ ...inputStyle, width: '100%' }}
                />
              </div>
              <div>
                <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>LLM judge criterion (optional, needs provider credentials)</MicroLabel>
                <input
                  type="text"
                  value={form.llmJudgePrompt}
                  onChange={(e) => setForm({ ...form, llmJudgePrompt: e.target.value })}
                  placeholder="e.g. Is the answer helpful and accurate?"
                  style={{ ...inputStyle, width: '100%' }}
                />
              </div>
            </div>
            </>)}

            {formError && <div style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{formError}</div>}

            <div>
              <Button variant="primary" type="submit" disabled={isSubmitting}>
                {isSubmitting ? (form.scenariosText.trim() ? 'Creating & starting run…' : 'Creating & running…') : 'Create & Run'}
              </Button>
            </div>
          </form>
        </Card>
      )}

      {/* Stats */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))', gap: 16 }}>
        <StatCard label="Suites" value={suites.length} sub={suitesSub} testId="stat-suites" />
        <StatCard label="Scenario runs" value={pageRuns} sub="latest run of each suite" testId="stat-scenario-runs" />
        <StatCard
          label="Pass rate"
          value={passRatio == null ? '—' : fmtPct(passRatio)}
          valueColor={passRatio == null ? 'var(--color-text-muted)' : TONE[toneFor(passRatio)].strong}
          sub={passRatio == null ? 'no completed runs yet' : `${pagePassed} / ${pageRuns} passed`}
          testId="stat-pass-rate"
        />
        <StatCard
          label="Open faults"
          value={pageRuns - pagePassed}
          sub={`${plural(pageFixes, 'fix item')} across ${plural(latestRuns.length, 'suite')}`}
          testId="stat-open-faults"
        />
      </div>

      {/* Evaluations */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        {shownEvaluations.map((evaluation) => {
          const run = evaluation.latest_run;
          const open = isOpen(evaluation.id);
          const suite = !!evaluation.scenario_suite;
          const complete = run?.status === 'complete';
          const runningNow = run?.status === 'pending' || run?.status === 'running';
          const modelCount = run?.models?.length || (evaluation.compare_models || []).length || 1;
          const passed = run?.samples_passed || 0;
          const evaluated = run?.samples_evaluated || 0;
          const ratio = evaluated ? passed / evaluated : 0;
          // Criteria are only rendered once expanded, so this exposes on the
          // collapsed card whether the evaluation scores from telemetry —
          // otherwise nothing can select one without opening every card.
          const scoresFromTelemetry = (evaluation.criteria || []).some((criterion) =>
            TELEMETRY_CRITERIA.some((telemetry) => telemetry.key === criterion.key)
          );
          const meta = suite
            ? `@${evaluation.agent?.name || 'agent'} · ${plural(evaluation.scenario_count || 0, 'scenario')} × ${plural(modelCount, 'model')}`
            : `@${evaluation.agent?.name || 'agent'} · ${plural(evaluation.sample_size || 0, 'sample')}${modelCount > 1 ? ` × ${plural(modelCount, 'model')}` : ''}`;
          return (
            <Card
              key={evaluation.id}
              padding={0}
              testId="evaluation-card"
              data-telemetry={scoresFromTelemetry ? 'true' : 'false'}
              data-kind={suite ? 'suite' : 'sampling'}
              data-open={open ? 'true' : 'false'}
              style={{ overflow: 'hidden' }}
            >
              <div
                onClick={() => toggleOpen(evaluation.id)}
                className="hover:bg-[var(--color-hover)]"
                style={{ display: 'flex', alignItems: 'center', gap: 12, rowGap: 8, padding: '12px 16px', cursor: 'pointer', flexWrap: 'wrap' }}
              >
                <Glyph kind="chevron" open={open} />
                <span
                  style={{ width: 22, height: 22, borderRadius: 6, background: 'var(--color-muted)', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontFamily: MONO, fontSize: 10, fontWeight: 700, color: 'var(--color-text-secondary)', flexShrink: 0 }}
                  title={suite ? 'scenario suite' : 'sampling evaluation'}
                >
                  {suite ? '=' : '~'}
                </span>
                <span style={{ fontSize: 14, fontWeight: 600, color: 'var(--color-text-primary)' }}>{evaluation.name}</span>
                <span style={monoStyle(11)}>{meta}</span>
                <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 14, flexShrink: 0 }}>
                  <span style={monoStyle(11)}>{timeAgo(run?.completed_at || run?.created_at || evaluation.created_at)}</span>
                  {run?.status === 'failed' && <span style={monoStyle(11, 'var(--color-error)')}>failed</span>}
                  {runningNow && <span style={monoStyle(11)}>{run.status === 'pending' ? 'queued' : 'running'}</span>}
                  {!run && <span style={monoStyle(11)}>no runs</span>}
                  {complete && suite && <span style={monoStyle(11)}>{plural(evaluated - passed, 'fault')}</span>}
                  {complete && suite && <Badge tone={toneFor(ratio)} testId="suite-pass-badge">{`${passed}/${evaluated} passed`}</Badge>}
                  {complete && !suite && run.average_score != null && (
                    <Badge tone={scoreTone(run.average_score)} title="mean score across criteria">{`score ${fmtScore(run.average_score)}`}</Badge>
                  )}
                  {complete && !suite && evaluated > 0 && <Badge tone={toneFor(ratio)}>{`${passed}/${evaluated} passed`}</Badge>}
                </span>
              </div>

              {open && (
                <div style={{ borderTop: '1px solid var(--color-border-light)' }}>
                  {suite ? (
                    <ScenarioSuitePanel
                      evaluation={evaluation}
                      onChanged={fetchEvaluations}
                      onDelete={() => handleDelete(evaluation)}
                      deleting={deletingId === evaluation.id}
                    />
                  ) : (
                    <>
                      {run?.status === 'failed' ? (
                        <div style={{ padding: 16, fontSize: 13, color: 'var(--color-error-text)' }}>{run.error_message}</div>
                      ) : run?.scores ? (
                        <div style={{ padding: 16, display: 'flex', flexDirection: 'column', gap: 12 }}>
                          {/* Comparative verdict (model-vs-model runs) */}
                          {run.scores._verdict && (
                            <div style={{ padding: '10px 12px', borderRadius: 10, border: '1px solid var(--color-border-light)', display: 'flex', flexDirection: 'column', gap: 6 }}>
                              <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                                <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)' }}>{run.scores._verdict.winner}</span>
                                <Badge tone="info" size={10} style={{ padding: '1px 6px' }}>judge's pick</Badge>
                                <span style={{ marginLeft: 'auto', ...monoStyle(11) }}>{`judged by ${run.scores._verdict.judge}`}</span>
                              </div>
                              <div style={{ fontSize: 12, lineHeight: '18px', color: 'var(--color-text-cell)', textWrap: 'pretty' }}>
                                <MicroLabel size={10} color="var(--color-text-muted)" style={{ marginRight: 8 }}>Verdict</MicroLabel>
                                {run.scores._verdict.rationale}
                              </div>
                            </div>
                          )}
                          {run.scores._missing_models && (
                            <div style={{ fontSize: 12, fontStyle: 'italic', color: 'var(--color-text-muted)' }}>
                              No recorded generations for: {run.scores._missing_models.join(', ')} — run the agent under those models first
                            </div>
                          )}
                          {Object.entries(run.scores).filter(([label]) => !label.startsWith('_')).map(([label, score]) =>
                            isCohortMap(score) ? (
                              <div key={label} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                                <div style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>{label.replace(/_/g, ' ')}</div>
                                {Object.entries(score).map(([model, stats]) => (
                                  <ScoreRow key={model} label={model} score={stats} indent mono />
                                ))}
                              </div>
                            ) : (
                              <ScoreRow key={label} label={label} score={score} />
                            )
                          )}
                        </div>
                      ) : (
                        <div style={{ padding: 16, ...monoStyle(11) }}>[ ] no runs yet</div>
                      )}

                      {/* Details */}
                      <div style={{ padding: 16, background: 'var(--color-background)', display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: 16, fontSize: 13 }}>
                        <div>
                          <MicroLabel size={10} color="var(--color-text-muted)">Judge</MicroLabel>
                          <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 12, color: 'var(--color-text-primary)' }}>
                            {evaluation.judge_kind === 'judge_defined'
                              ? `judge-defined KPIs${evaluation.judge_model ? ` (${evaluation.judge_model})` : ''}`
                              : evaluation.judge_kind === 'llm' ? (evaluation.judge_model || 'llm judge') : 'rules'}
                          </div>
                        </div>
                        <div style={{ gridColumn: 'span 2', minWidth: 0 }}>
                          <MicroLabel size={10} color="var(--color-text-muted)">Criteria</MicroLabel>
                          <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 12, color: 'var(--color-text-primary)', textWrap: 'pretty' }}>
                            {(evaluation.criteria || []).map((c) => String(c.key).replace(/_/g, ' ')).join(' · ') || '—'}
                          </div>
                        </div>
                        <div>
                          <MicroLabel size={10} color="var(--color-text-muted)">Samples</MicroLabel>
                          <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 12, color: 'var(--color-text-primary)' }}>
                            {complete && evaluated > 0 ? `${passed} / ${evaluated} passed` : '—'}
                          </div>
                        </div>
                        <div>
                          <MicroLabel size={10} color="var(--color-text-muted)">Last run</MicroLabel>
                          <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 12, color: 'var(--color-text-primary)' }} title="Estimated cost, tokens and wall-clock runtime of the latest run">
                            {formatRunUsage(run?.usage) || '—'}
                          </div>
                        </div>
                        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'flex-end', gap: 8 }}>
                          <Button
                            size="sm"
                            onClick={(e) => { e.stopPropagation(); handleRun(evaluation.id); }}
                            disabled={runningId === evaluation.id}
                          >
                            {runningId === evaluation.id ? 'Running…' : 'Run again'}
                          </Button>
                          <Button
                            variant="danger"
                            size="sm"
                            onClick={(e) => { e.stopPropagation(); handleDelete(evaluation); }}
                            disabled={deletingId === evaluation.id}
                            title="Delete this evaluation and its runs"
                          >
                            {deletingId === evaluation.id ? 'Deleting…' : 'Delete'}
                          </Button>
                        </div>
                      </div>
                    </>
                  )}
                </div>
              )}
            </Card>
          );
        })}
      </div>

      {shownEvaluations.length === 0 && !showForm && (
        <Card style={{ textAlign: 'center', padding: '48px 20px' }}>
          <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--color-text-primary)' }}>No evaluations yet</div>
          <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>
            Create an evaluation to score recorded outputs, or paste scenarios to test new tasks across models
          </p>
        </Card>
      )}
    </div>
  );
}
