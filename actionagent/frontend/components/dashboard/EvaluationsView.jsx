import React, { useState, useEffect, useCallback, useRef } from 'react';
import { dashboardPath, dashboardRelativePath, pushDashboardPath } from '../../utils/dashboardPath';
import { evaluationLink, includeLinkedEvaluation } from '../../utils/evaluationHistory.mjs';
import { useTheme } from '../../contexts/ThemeContext';
import ScenarioSuitePanel from './ScenarioSuitePanel';
import EvaluationForm from './evaluations/EvaluationForm';
import EvaluationRunDetail from './evaluations/EvaluationRunDetail';
import CriteriaFooter from './evaluations/CriteriaFooter';
import RunsList, { RunBadge, runsSummary } from './evaluations/RunsList';
import { fmtRate } from './evaluations/SpendStrip';
import { Button, Card, Glyph, StatCard, MONO, TONE, toneFor } from './primitives';
import { fmtCost, fmtPct, timeAgo } from '../../utils/format';
import { criterionGroup, modelCount, plural, runLabel, runSpend, samplingFixItems, spendSummary } from '../../utils/evaluationRuns.mjs';

// Evaluations, each with every run it has had. An evaluation is a named set
// of criteria against one agent — scored over its recorded generations, or,
// as a scenario suite, replayed through it — and its runs are the record of
// whether the agent is getting better. The page lists evaluations with their
// run history; a run opens to a scorecard per model cohort, the judge's
// verdict, the criteria × models matrix (or, for a suite, the scenario
// matrix) and what the run asks to fix. Every figure on screen is a field
// the app recorded, including what each run cost: the agent's side, which
// is what operating it costs, apart from the judge's, which is the
// evaluation's own.

// Mean-score tone: a score is not a pass ratio, so it keeps the thresholds
// the sampling evaluations have always used.
const scoreTone = (value) => (value >= 0.85 ? 'success' : value >= 0.7 ? 'warning' : 'error');

// Routes under /evaluations: the report page of one run …
const reportRefFromPath = () => {
  const match = dashboardRelativePath().match(/^\/evaluations\/(\d+)\/runs\/(\d+)\/report/);
  if (match) return { evaluationId: match[1], runId: match[2] };
  const query = evaluationLink(window.location.search);
  return query?.runId ? query : null;
};

// … or one evaluation, open, and optionally one of its runs.
const runRefFromPath = () => {
  const match = dashboardRelativePath().match(/^\/evaluations\/(\d+)(?:\/runs\/(\d+))?\/?$/);
  if (!match) return null;
  return { evaluationId: Number(match[1]), runId: match[2] ? Number(match[2]) : null };
};

// Which evaluation the URL names, as a string id: `?evaluation=` (the older
// deep link) or the path. Either may point outside the first index page.
const linkedIdFromLocation = () =>
  evaluationLink(window.location.search)?.evaluationId || (runRefFromPath() ? String(runRefFromPath().evaluationId) : null);

const monoStyle = (size = 11, color = 'var(--color-text-muted)') => ({ fontFamily: MONO, fontSize: size, color });

// How many things a run asks to fix: a suite's recommendations from its
// report, a sampling run's from its own scores; a failed run is one item.
const fixCountFor = (evaluation) => {
  const run = evaluation.latest_run;
  if (!run) return 0;
  if (evaluation.scenario_suite) {
    return (run.scores?._recommendations || []).length + (run.status === 'failed' ? 1 : 0);
  }
  return samplingFixItems(evaluation, run).length;
};

// embedded hides the page title when this renders inside the agent detail
// page's Evals tab, which already carries the heading, and keeps the page
// off the URL. agentId scopes every number on the page to that agent — an
// account-wide average under one agent's name reads as that agent's score,
// which it is not.
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

  const [evaluations, setEvaluations] = useState([]);
  const [agents, setAgents] = useState([]);
  // What the model pickers offer, from the list (see EvaluationForm): the
  // provider a judge model runs on, whether reading the credentials that
  // decide it failed, and the providers runs have credentials for.
  const [judgeProvider, setJudgeProvider] = useState(undefined);
  const [judgeProviderError, setJudgeProviderError] = useState(false);
  const [modelProviders, setModelProviders] = useState(undefined);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  // Accordion state per evaluation; the first suite opens by default.
  const [openIds, setOpenIds] = useState(null);
  // The run the URL opens: a sampling evaluation's run page, or the run a
  // suite's panel selects.
  const [openRun, setOpenRun] = useState(() => {
    if (embedded) return null;
    const ref = runRefFromPath();
    return ref?.runId ? ref : null;
  });
  const [linkedEvaluationId, setLinkedEvaluationId] = useState(() => (embedded ? null : linkedIdFromLocation()));
  // Run history per sampling evaluation, loaded when its card opens:
  // { runs (newest first, up to RUNS_PAGE), runCount }.
  const [histories, setHistories] = useState({});
  const [showForm, setShowForm] = useState(false);
  const [runningId, setRunningId] = useState(null);
  const [deletingId, setDeletingId] = useState(null);

  // URL → state: browser back/forward, and in-app navigation.
  useEffect(() => {
    if (embedded) return undefined;
    const applyPath = () => {
      setReportRef(reportRefFromPath());
      const ref = runRefFromPath();
      setOpenRun(ref?.runId ? ref : null);
      const linked = linkedIdFromLocation();
      setLinkedEvaluationId(linked);
      if (linked) setOpenIds((current) => new Set([...(current || []), Number(linked)]));
    };
    window.addEventListener('popstate', applyPath);
    window.addEventListener('dashboard:navigate', applyPath);
    return () => {
      window.removeEventListener('popstate', applyPath);
      window.removeEventListener('dashboard:navigate', applyPath);
    };
  }, [embedded]);

  const fetchEvaluations = useCallback(async () => {
    try {
      // Scoped server-side: the endpoint caps at the 50 most recent, so
      // narrowing here rather than after the fetch is what makes an agent's
      // older evaluations reachable at all.
      const response = await fetch(`/api/evaluations${agentId ? `?agent_id=${encodeURIComponent(agentId)}` : ''}`);
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      const data = await response.json();
      setJudgeProvider(data.judge_provider ?? null);
      setJudgeProviderError(data.judge_provider_error === true);
      setModelProviders(Array.isArray(data.model_providers) ? data.model_providers : null);
      let list = data.evaluations || [];
      let linkError = null;
      try {
        list = await includeLinkedEvaluation(list, linkedEvaluationId, fetch);
      } catch (error) {
        linkError = error.message;
      }
      setEvaluations(list);
      setOpenIds((current) => {
        if (current) return current;
        const first = linkedEvaluationId
          ? list.find((e) => String(e.id) === linkedEvaluationId)
          : (list.find((e) => e.scenario_suite) || list[0]);
        return new Set(first ? [first.id] : []);
      });
      setLoadError(linkError);
    } catch (error) {
      setLoadError(error.message);
      setModelProviders((current) => (current === undefined ? null : current));
    } finally {
      setIsLoading(false);
    }
  }, [agentId, linkedEvaluationId]);

  // The run history (up to RUNS_PAGE) is one request per sampling
  // evaluation, made when its card opens rather than for every row in the
  // list. A suite's panel loads its own.
  const loadHistory = useCallback(async (evaluationId) => {
    try {
      const response = await fetch(`/api/evaluations/${evaluationId}`);
      if (!response.ok) throw new Error(`Could not load this evaluation's runs (HTTP ${response.status})`);
      const data = await response.json();
      setHistories((prev) => ({
        ...prev,
        [evaluationId]: { runs: data.evaluation?.runs || [], runCount: data.evaluation?.run_count ?? null },
      }));
    } catch (error) {
      // Recorded so the card renders what the index already knows instead
      // of retrying on every render.
      setHistories((prev) => ({ ...prev, [evaluationId]: { runs: null, runCount: null, error: error.message } }));
      setLoadError(error.message);
    }
  }, []);

  useEffect(() => {
    fetchEvaluations();
    fetch('/api/agents')
      .then((r) => (r.ok ? r.json() : { agents: [] }))
      .then((data) => setAgents(data.agents || []))
      .catch(() => setAgents([]));
  }, [fetchEvaluations]);

  useEffect(() => {
    const wanted = new Set([...(openIds || []), ...(openRun ? [openRun.evaluationId] : [])]);
    wanted.forEach((id) => {
      const evaluation = evaluations.find((e) => e.id === id);
      if (evaluation && !evaluation.scenario_suite && !histories[id]) loadHistory(id);
    });
  }, [openIds, openRun, evaluations, histories, loadHistory]);

  const setPath = (path) => {
    if (!embedded && dashboardRelativePath() !== path) pushDashboardPath(path);
  };

  const isOpen = (id) => !!openIds?.has(id);
  const toggleOpen = (evaluation) => {
    const opening = !isOpen(evaluation.id);
    setOpenIds((current) => {
      const next = new Set(current || []);
      if (opening) next.add(evaluation.id);
      else next.delete(evaluation.id);
      return next;
    });
    setPath(opening ? `/evaluations/${evaluation.id}` : '/evaluations');
  };

  const openRunDetail = (evaluation, run) => {
    setOpenIds((current) => new Set([...(current || []), evaluation.id]));
    setOpenRun({ evaluationId: evaluation.id, runId: run.id });
    setPath(`/evaluations/${evaluation.id}/runs/${run.id}`);
  };

  const closeRunDetail = (evaluationId) => {
    setOpenRun(null);
    setPath(evaluationId ? `/evaluations/${evaluationId}` : '/evaluations');
  };

  // Runs a sampling evaluation again. A suite's runs start from its panel,
  // which chooses the scenarios and models.
  const handleRun = async (evaluation) => {
    setRunningId(evaluation.id);
    setLoadError(null);
    try {
      const response = await fetch(`/api/evaluations/${evaluation.id}/run`, {
        method: 'POST',
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        setLoadError((data.errors || [data.error]).filter(Boolean).join(', ') || `Run failed (HTTP ${response.status})`);
        return;
      }
      await Promise.all([fetchEvaluations(), loadHistory(evaluation.id)]);
      if (data.run && openRun?.evaluationId === evaluation.id) openRunDetail(evaluation, data.run);
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
      });
      if (response.ok || response.status === 404) {
        setEvaluations((prev) => prev.filter((e) => e.id !== evaluation.id));
        setOpenIds((current) => {
          const next = new Set(current || []);
          next.delete(evaluation.id);
          return next;
        });
        if (openRun?.evaluationId === evaluation.id) closeRunDetail(null);
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
  // list, the tiles, and the empty state can never disagree.
  const shownEvaluations = agentId
    ? evaluations.filter((e) => String(e.agent?.id) === String(agentId))
    : evaluations;

  // The runs a sampling card lists: its history once loaded, else the
  // latest run the index carried.
  const runsOf = (evaluation) => {
    const history = histories[evaluation.id];
    if (history?.runs) return { runs: history.runs, runCount: evaluation.run_count ?? history.runCount ?? null, loaded: true };
    return { runs: evaluation.latest_run ? [evaluation.latest_run] : [], runCount: evaluation.run_count ?? null, loaded: false };
  };

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

  // A sampling evaluation's run has a page of its own. A suite's run opens
  // in the suite's panel, where the scenario matrix is, so the list stays.
  if (openRun) {
    const evaluation = shownEvaluations.find((e) => e.id === openRun.evaluationId);
    if (!evaluation || !evaluation.scenario_suite) {
      const { runs, runCount, loaded } = evaluation ? runsOf(evaluation) : { runs: [], runCount: null, loaded: true };
      return (
        <EvaluationRunDetail
          evaluation={evaluation}
          runs={runs}
          runCount={runCount}
          runId={openRun.runId}
          loading={!loaded}
          running={runningId === openRun.evaluationId}
          onSelectRun={(run) => openRunDetail(evaluation, run)}
          onRun={() => handleRun(evaluation)}
          onBack={() => closeRunDetail(null)}
          onOpenEvaluation={() => closeRunDetail(openRun.evaluationId)}
          onDelete={evaluation ? () => handleDelete(evaluation) : undefined}
          deleting={deletingId === openRun.evaluationId}
        />
      );
    }
  }

  // Page tiles, from the latest run of each evaluation.
  const latestRuns = shownEvaluations.map((e) => e.latest_run).filter(Boolean);
  const completeRuns = latestRuns.filter((r) => r.status === 'complete');
  const samplesScored = completeRuns.reduce((sum, r) => sum + (r.samples_evaluated || 0), 0);
  const samplesPassed = completeRuns.reduce((sum, r) => sum + (r.samples_passed || 0), 0);
  const passRatio = samplesScored ? samplesPassed / samplesScored : null;
  const agentNames = [...new Set(shownEvaluations.map((e) => e.agent?.name).filter(Boolean))];
  const modelsCompared = shownEvaluations.reduce((max, e) => Math.max(max, modelCount(e, e.latest_run)), 0);
  const fixCounts = shownEvaluations.map(fixCountFor);
  const toFix = fixCounts.reduce((sum, count) => sum + count, 0);
  const toFixEvaluations = fixCounts.filter(Boolean).length;
  const spend = spendSummary(completeRuns);
  const evaluationsSub = shownEvaluations.length
    ? `${plural(agentNames.length, 'agent')} · ${modelsCompared > 1 ? `${modelsCompared} models compared` : 'no model comparisons'}`
    : 'none defined yet';
  // The operating figure clients budget against: the agent's spend over the
  // interactions the latest runs covered, with the judge's own spend named
  // apart so it never inflates it.
  const spendSub = spend.agentCost != null
    ? [
      `agent ${fmtCost(spend.agentCost)} over ${plural(spend.interactions, 'interaction')}`,
      spend.judgeCost != null ? `judge ${fmtCost(spend.judgeCost)} offline` : 'no judge spend',
    ].join(' · ')
    : 'no priced runs yet';

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      {/* Header — embedded in the agent page, that page owns the heading. */}
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16, flexWrap: 'wrap' }}>
        {!embedded && (
          <div style={{ flex: 1, minWidth: 260 }}>
            <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>Evaluations</h1>
            <p style={{ margin: '4px 0 0', fontSize: 14, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>
              Score recorded outputs, or paste a list of user messages to replay through the agent under one or more models. Every run is kept.
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

      {showForm && (
        <EvaluationForm
          agents={agents}
          agentId={agentId}
          judgeProvider={judgeProvider}
          judgeProviderError={judgeProviderError}
          modelProviders={modelProviders}
          onCancel={() => setShowForm(false)}
          onCreated={async (evaluation) => {
            setShowForm(false);
            await fetchEvaluations();
            if (evaluation?.id != null) {
              setOpenIds((current) => new Set([...(current || []), evaluation.id]));
              setPath(`/evaluations/${evaluation.id}`);
            }
          }}
        />
      )}

      {/* Stats */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))', gap: 16 }}>
        <StatCard label="Evaluations" value={shownEvaluations.length} sub={evaluationsSub} testId="stat-evaluations" />
        <StatCard label="Samples scored" value={samplesScored} sub="latest run of each evaluation" testId="stat-samples-scored" />
        <StatCard
          label="Pass rate"
          value={passRatio == null ? '—' : fmtPct(passRatio)}
          valueColor={passRatio == null ? 'var(--color-text-muted)' : TONE[toneFor(passRatio)].strong}
          sub={passRatio == null ? 'no completed runs yet' : `${samplesPassed} / ${samplesScored} samples passed`}
          testId="stat-pass-rate"
        />
        <StatCard
          label="To fix"
          value={toFix}
          valueColor={toFix ? 'var(--color-error)' : undefined}
          sub={toFix ? `across ${plural(toFixEvaluations, 'evaluation')}` : 'nothing outstanding'}
          testId="stat-to-fix"
        />
        <StatCard
          label="Cost / interaction"
          value={fmtRate(spend.perInteraction)}
          valueColor={spend.perInteraction == null ? 'var(--color-text-muted)' : undefined}
          sub={spendSub}
          testId="stat-agent-cost"
        />
      </div>

      {/* Evaluations */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        {shownEvaluations.map((evaluation, index) => {
          const run = evaluation.latest_run;
          const open = isOpen(evaluation.id);
          const suite = !!evaluation.scenario_suite;
          const fixCount = fixCounts[index];
          // Criteria are only rendered once expanded, so this exposes on the
          // collapsed card whether the evaluation scores from telemetry —
          // otherwise nothing can select one without opening every card.
          const scoresFromTelemetry = (evaluation.criteria || []).some((criterion) => criterionGroup(criterion) === 'telemetry');
          const { runs, runCount } = runsOf(evaluation);
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
                role="button"
                tabIndex={0}
                aria-expanded={open}
                onClick={() => toggleOpen(evaluation)}
                onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); toggleOpen(evaluation); } }}
                className="hover:bg-[var(--color-hover)]"
                style={{ display: 'flex', alignItems: 'center', gap: 10, rowGap: 8, padding: '12px 16px', cursor: 'pointer', flexWrap: 'wrap' }}
              >
                <Glyph kind="chevron" open={open} />
                <span
                  style={{ width: 22, height: 22, borderRadius: 6, background: 'var(--color-muted)', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontFamily: MONO, fontSize: 11, fontWeight: 700, color: 'var(--color-text-secondary)', flexShrink: 0 }}
                  title={suite ? 'scenario suite' : 'sampling evaluation'}
                >
                  {suite ? '=' : '~'}
                </span>
                <span style={{ fontSize: 15, fontWeight: 700, color: 'var(--color-text-primary)' }}>{evaluation.name}</span>
                {/* What the evaluation is set up to cover; a run's own row says what it scored. */}
                <span style={monoStyle(11)}>{`@${evaluation.agent?.name || 'agent'} · ${runLabel(evaluation)}`}</span>
                <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 12, flexShrink: 0 }}>
                  <span style={monoStyle(11)}>{timeAgo(run?.completed_at || run?.created_at || evaluation.created_at)}</span>
                  {fixCount > 0 && <span style={monoStyle(11, 'var(--color-error)')}>{`${fixCount} to fix`}</span>}
                  <RunBadge run={run} testId={suite ? 'suite-pass-badge' : 'evaluation-pass-badge'} />
                </span>
              </div>

              {open && (
                <div style={{ borderTop: '1px solid var(--color-border-light)' }}>
                  {suite ? (
                    <ScenarioSuitePanel
                      evaluation={evaluation}
                      modelProviders={modelProviders}
                      onChanged={fetchEvaluations}
                      onDelete={() => handleDelete(evaluation)}
                      deleting={deletingId === evaluation.id}
                      initialRunId={openRun?.evaluationId === evaluation.id ? openRun.runId : null}
                      onRunSelected={(runId) => setPath(`/evaluations/${evaluation.id}/runs/${runId}`)}
                    />
                  ) : (
                    <div style={{ padding: 16, display: 'flex', flexDirection: 'column', gap: 12 }} data-testid="sampling-evaluation-panel">
                      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
                        <span style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>
                          {runs.length ? runsSummary(runs, runCount) : `@${evaluation.agent?.name || 'agent'} · no runs yet`}
                        </span>
                        <Button
                          variant="primary"
                          size="sm"
                          disabled={runningId === evaluation.id}
                          onClick={(event) => { event.stopPropagation(); handleRun(evaluation); }}
                          testId="evaluation-run-button"
                        >
                          {runningId === evaluation.id ? 'Running…' : `Run ${runLabel(evaluation)}`}
                        </Button>
                      </div>
                      <RunsList
                        runs={runs}
                        runCount={runCount}
                        evaluation={evaluation}
                        agentName={evaluation.agent?.name}
                        previousRun={evaluation.previous_run}
                        onOpen={(candidate) => openRunDetail(evaluation, candidate)}
                        testId="evaluation-runs-panel"
                      />
                      <CriteriaFooter
                        evaluation={evaluation}
                        run={run}
                        spend={runSpend(run)}
                        onDelete={() => handleDelete(evaluation)}
                        deleting={deletingId === evaluation.id}
                      />
                    </div>
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
            Create an evaluation to score recorded outputs, or paste scenarios to test new tasks across models. Every run is kept, so scores stay comparable over time.
          </p>
        </Card>
      )}
    </div>
  );
}
