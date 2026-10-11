import React, { useState, useEffect, useCallback, useRef, useId } from 'react';
import { dashboardPath, dashboardRelativePath, navigateTo, pushDashboardPath } from '../../utils/dashboardPath';
import { evaluationLink, includeLinkedEvaluation } from '../../utils/evaluationHistory.mjs';
import { useTheme } from '../../contexts/ThemeContext';
import ScenarioSuitePanel from './ScenarioSuitePanel';
import ScenarioCatalogsView from './ScenarioCatalogsView';
import EvaluationForm from './evaluations/EvaluationForm';
import EvaluationRunDetail from './evaluations/EvaluationRunDetail';
import CriteriaFooter from './evaluations/CriteriaFooter';
import RunsList, { runsSummary } from './evaluations/RunsList';
import { Button, Hint, PageHeader, TABLE, Tabs, MONO, TONE, toneFor } from './primitives';
import { splitModelLabel, timeAgo } from '../../utils/format';
import { fmtPasses, fmtPercent, fmtSpend } from '../../utils/evalFormat.mjs';
import {
  criterionGroup, evaluationStanding, headlineRun, headlineSummary, plural, runDelta, runLabel, runSpend,
  samplingFixItems,
} from '../../utils/evaluationRuns.mjs';

// Evaluations, each with every run it has had. An evaluation is a named set
// of criteria against one agent — scored over its recorded generations, or,
// as a scenario suite, replayed through it — and its runs are the record of
// whether the agent is getting better. The page is one table, a row per
// evaluation with one status each; a row opens in place to its run history
// and, for a suite, the scenario matrix. Catalogs and Archived are tabs of
// the same page. Every figure on screen is a field the app recorded,
// including what each run cost: the agent's side, which is what operating
// it costs, apart from the judge's, which is the evaluation's own.

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

// How many things an evaluation asks to fix: its headline run's
// recommendations (a suite's from its report, a sampling run's from its own
// scores), plus one when its latest run failed.
const fixCountFor = (evaluation) => {
  const run = headlineRun(evaluation);
  const failed = evaluation.latest_run?.status === 'failed' ? 1 : 0;
  if (!run) return failed;
  if (evaluation.scenario_suite) {
    return (run.scores?._recommendations || []).length + failed;
  }
  return samplingFixItems(evaluation, run).length + failed;
};

const IN_PROGRESS = ['running', 'pending'];

// The one note a row's LATEST RUN cell carries, after the figures: where a
// run still going is, that the latest run failed, or that the run shown
// predates the agent's current version.
const runNote = (evaluation, shown) => {
  const latest = evaluation.latest_run;
  if (latest?.status === 'running') return { text: 'running', color: 'var(--color-info-text)' };
  if (latest?.status === 'pending') return { text: 'queued', color: 'var(--color-info-text)' };
  if (latest?.status === 'failed') return { text: 'failed', color: 'var(--color-error-text)' };
  if (evaluationStanding(evaluation) === 'stale' || shown?.version_state === 'earlier') {
    return { text: 'older version', color: 'var(--color-warning-text)' };
  }
  return null;
};

// runDelta's wording, pinned elsewhere, shortened for a cell: "+3 vs #4",
// "−2 vs #6", "same as #2", "first run".
const shortDelta = (text) => String(text).replace(' passed vs ', ' vs ').replace(/^-/, '−');
const DELTA_TONE = { success: TONE.success.text, error: TONE.error.text, muted: 'var(--color-text-muted)' };

// The models a row names: the latest run's, else the ones the evaluation
// compares; past two, just how many.
const modelsText = (evaluation) => {
  const models = evaluation.latest_run?.models || evaluation.compare_models || [];
  if (models.length === 0) return '—';
  if (models.length > 2) return `${models.length} models`;
  return models.map((model) => splitModelLabel(model).short).join(', ');
};

const matchesFilter = (evaluation, filter) => {
  const needle = filter.trim().toLowerCase();
  if (!needle) return true;
  return [evaluation.name, evaluation.agent?.name].some((text) => String(text || '').toLowerCase().includes(needle));
};

const hiddenLabelStyle = { position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap' };

const inputStyle = {
  width: 240, maxWidth: '100%', height: 36, boxSizing: 'border-box', padding: '0 12px', borderRadius: 8,
  border: '1px solid var(--color-border)', background: 'var(--color-surface)', color: 'var(--color-text-primary)',
  fontFamily: 'inherit', fontSize: 13,
};

// embedded hides the page title when this renders inside the agent detail
// page's Evals tab, which already carries the heading, and keeps the page
// off the URL. agentId scopes every number on the page to that agent — an
// account-wide average under one agent's name reads as that agent's score,
// which it is not. section 'catalogs' shows the Catalogs tab's content
// under the same header; visit re-reads the catalogs when it changes.
export default function EvaluationsView({ embedded = false, agentId = null, section = 'evaluations', visit = 0 }) {
  const { darkMode } = useTheme();
  const filterId = useId();
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
  const [filter, setFilter] = useState('');
  const [runningId, setRunningId] = useState(null);
  const [deletingId, setDeletingId] = useState(null);
  const [archivingId, setArchivingId] = useState(null);
  // Archived evaluations leave the list unless asked for; the API says how
  // many it left out. The Archived tab asks for them.
  const [showArchived, setShowArchived] = useState(false);
  const [archivedCount, setArchivedCount] = useState(0);

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
      const query = new URLSearchParams();
      if (agentId) query.set('agent_id', agentId);
      if (showArchived) query.set('archived', '1');
      const search = query.toString();
      const response = await fetch(`/api/evaluations${search ? `?${search}` : ''}`);
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      const data = await response.json();
      setArchivedCount(Number(data.archived_count) || 0);
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
      // A deep link to an archived evaluation lands on the tab that lists it.
      const linked = linkedEvaluationId ? list.find((e) => String(e.id) === linkedEvaluationId) : null;
      if (linked && evaluationStanding(linked) === 'archived') setShowArchived(true);
      setLoadError(linkError);
    } catch (error) {
      setLoadError(error.message);
      setModelProviders((current) => (current === undefined ? null : current));
    } finally {
      setIsLoading(false);
    }
  }, [agentId, linkedEvaluationId, showArchived]);

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

  // Archives an evaluation, or brings it back: it keeps its runs but leaves
  // the list and the pooled figures until shown again.
  const handleArchive = async (evaluation, archived) => {
    setArchivingId(evaluation.id);
    setLoadError(null);
    try {
      const response = await fetch(`/api/evaluations/${evaluation.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ evaluation: { archived } }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        setLoadError((data.errors || [data.error]).filter(Boolean).join(', ') || `${archived ? 'Archive' : 'Unarchive'} failed (HTTP ${response.status})`);
        return;
      }
      await fetchEvaluations();
    } finally {
      setArchivingId(null);
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

  // The request is already scoped; this is a belt-and-braces guard so the
  // list, the summary, and the empty state can never disagree.
  const shownEvaluations = agentId
    ? evaluations.filter((e) => String(e.agent?.id) === String(agentId))
    : evaluations;
  // The Evaluations tab lists what stands; the Archived tab what was put
  // away (the API returns both under archived=1).
  const currentEvaluations = shownEvaluations.filter((e) => evaluationStanding(e) !== 'archived');
  const archivedEvaluations = shownEvaluations.filter((e) => evaluationStanding(e) === 'archived');

  const catalogs = section === 'catalogs';
  const activeTab = catalogs ? 'catalogs' : showArchived ? 'archived' : 'evaluations';
  const selectTab = (id) => {
    if (id === 'catalogs') navigateTo('/catalogs');
    else if (id === 'archived') setShowArchived(true);
    else if (catalogs) navigateTo('/evaluations');
    else setShowArchived(false);
  };
  const tabs = (
    <Tabs
      ariaLabel="Evaluation views"
      active={activeTab}
      onChange={selectTab}
      tabs={[
        { id: 'evaluations', label: 'Evaluations', count: isLoading ? undefined : currentEvaluations.length },
        ...(embedded ? [] : [{ id: 'catalogs', label: 'Catalogs' }]),
        { id: 'archived', label: 'Archived', count: isLoading ? undefined : archivedCount, testId: 'show-archived-toggle' },
      ]}
    />
  );

  // The Catalogs tab: the same header and tabs, then the catalogs.
  if (catalogs) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        <PageHeader title={embedded ? null : 'Evaluations'} />
        {tabs}
        <ScenarioCatalogsView embedded visit={visit} />
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2" style={{ borderBottomColor: 'var(--color-accent-ui)' }} />
      </div>
    );
  }

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
        <PageHeader
          crumbs={[{ label: 'Evaluations', onClick: () => { pushDashboardPath('/evaluations'); setReportRef(null); } }]}
          title="Run report"
          meta={`evaluation ${reportRef.evaluationId} · run ${reportRef.runId}`}
          actions={(
            <a
              href={reportUrl}
              target="_blank"
              rel="noopener noreferrer"
              title="The report is one self-contained page — save it to export"
              style={{ padding: '6px 12px', borderRadius: 8, fontSize: 13, fontWeight: 500, color: 'var(--color-text-cell)', border: '1px solid var(--color-border-strong)', textDecoration: 'none' }}
            >
              Open standalone <span style={{ fontFamily: MONO }}>{'->'}</span>
            </a>
          )}
        />
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

  // The summary line, pooled over the headline run of each evaluation that
  // describes the agent as it is now — a stale or archived evaluation is
  // left out — or, when the page is focused on one evaluation, that
  // evaluation's headline run alone.
  const summary = headlineSummary(shownEvaluations, { focusId: linkedEvaluationId });
  const { samplesScored, samplesPassed, passRatio, spend } = summary;
  const toFix = currentEvaluations.map(fixCountFor).reduce((sum, count) => sum + count, 0);
  // What the headline runs cost, agent and judge together; the split is
  // in the title, and "~" marks an estimated part.
  const priced = spend.agentCost != null || spend.judgeCost != null;
  const totalCost = priced ? (spend.agentCost || 0) + (spend.judgeCost || 0) : null;
  const costEstimated = (spend.agentCost != null && spend.estimated) || (spend.judgeCost != null && spend.judgeEstimated);
  const costTitle = priced
    ? [
      `agent ${fmtSpend(spend.agentCost, { estimated: spend.estimated })} over ${plural(spend.interactions, 'interaction')}`,
      spend.judgeCost != null ? `judge ${fmtSpend(spend.judgeCost, { estimated: spend.judgeEstimated })}` : 'no judge spend',
      costEstimated ? '~ estimated from tokens × model rates' : null,
    ].filter(Boolean).join(' · ')
    : 'no priced runs yet';

  const rows = (showArchived ? archivedEvaluations : currentEvaluations).filter((e) => matchesFilter(e, filter));
  const anyOlderVersion = rows.some((e) => runNote(e, headlineRun(e) || e.latest_run)?.text === 'older version');

  const columns = [
    { key: 'evaluation', label: 'Evaluation', width: 'minmax(220px, 2fr)' },
    ...(embedded ? [] : [{ key: 'agent', label: 'Agent', width: 'minmax(120px, 1fr)' }]),
    { key: 'latest', label: 'Latest run', width: 'minmax(280px, 1.8fr)' },
    { key: 'delta', label: 'Vs previous', width: 'minmax(110px, 1fr)' },
    { key: 'fixes', label: 'Fixes', width: '72px', right: true },
    { key: 'models', label: 'Models', width: 'minmax(140px, 1.2fr)' },
    { key: 'ran', label: 'Ran', width: 'minmax(96px, auto)', right: true },
    { key: 'archive', label: '', width: '80px', right: true },
  ];
  const gridTemplateColumns = columns.map((column) => column.width).join(' ');
  const cell = (last, extra) => ({ ...TABLE.td, minWidth: 0, ...(last ? { borderBottom: 'none' } : {}), ...extra });

  const emptyTitle = filter.trim() ? `Nothing matches “${filter.trim()}”` : showArchived ? 'Nothing archived' : 'No evaluations yet';
  const emptyText = filter.trim()
    ? null
    : showArchived
      ? 'Archive an evaluation from its row to keep its runs but leave it out of the list and the summary.'
      : 'Create an evaluation to score recorded outputs, or paste scenarios to test new tasks across models.';

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* Header — embedded in the agent page, that page owns the heading. */}
      <PageHeader
        title={embedded ? null : 'Evaluations'}
        actions={(
          <>
            <label htmlFor={filterId} style={hiddenLabelStyle}>Filter evaluations</label>
            <input
              id={filterId}
              type="search"
              value={filter}
              onChange={(event) => setFilter(event.target.value)}
              placeholder={embedded ? 'Filter by name' : 'Filter by name or agent'}
              style={inputStyle}
            />
            <Button variant="primary" onClick={() => setShowForm(!showForm)} testId="new-evaluation-button">
              {showForm ? 'Cancel' : 'New evaluation'}
            </Button>
          </>
        )}
      />

      {tabs}

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

      {/* Summary: what the headline runs passed, ask to fix and cost. */}
      {!showArchived && (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 28, fontFamily: MONO }} data-testid="evaluations-summary">
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.04em', color: 'var(--color-text-muted)' }}>Passed</span>
            <span style={{ fontSize: 16, fontWeight: 500, color: 'var(--color-text-primary)' }}>{`${samplesPassed}/${samplesScored}`}</span>
            <span style={{ fontSize: 13, color: passRatio == null ? 'var(--color-text-muted)' : TONE[toneFor(passRatio)].text }}>{fmtPercent(passRatio)}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.04em', color: 'var(--color-text-muted)' }}>Fixes</span>
            <span style={{ fontSize: 16, fontWeight: 500, color: toFix > 0 ? 'var(--color-warning-text)' : 'var(--color-text-primary)' }}>{toFix}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }} title={costTitle}>
            <span style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.04em', color: 'var(--color-text-muted)' }}>Cost · headline runs</span>
            <span style={{ fontSize: 16, fontWeight: 500, color: totalCost == null ? 'var(--color-text-muted)' : 'var(--color-text-primary)' }}>{fmtSpend(totalCost, { estimated: costEstimated })}</span>
          </div>
        </div>
      )}

      {/* The table: a header row, then one row per evaluation, each opening in place. */}
      {(rows.length > 0 || !showForm) && (
        <div style={TABLE.frame}>
          <div style={{ minWidth: embedded ? 760 : 900 }}>
            <div style={{ display: 'grid', gridTemplateColumns }} data-testid="evaluations-header-row">
              {columns.map((column) => (
                <span key={column.key} style={{ ...TABLE.th, ...(column.right ? TABLE.right : {}) }}>{column.label}</span>
              ))}
            </div>

            {rows.length === 0 && (
              <div style={{ ...TABLE.td, borderBottom: 'none', padding: '32px 14px', textAlign: 'center' }} data-testid="evaluations-empty">
                <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--color-text-primary)' }}>{emptyTitle}</div>
                {emptyText && <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--color-text-muted)' }}>{emptyText}</p>}
              </div>
            )}

            {rows.map((evaluation, index) => {
              const latest = evaluation.latest_run;
              // The figures describe the headline run; the note says where a
              // newer run still pending or failed is.
              const shown = headlineRun(evaluation) || latest;
              const standing = evaluationStanding(evaluation);
              const archived = standing === 'archived';
              const open = isOpen(evaluation.id);
              const suite = !!evaluation.scenario_suite;
              const last = index === rows.length - 1;
              const fixCount = fixCountFor(evaluation);
              // Criteria are only rendered once expanded, so this exposes on the
              // collapsed row whether the evaluation scores from telemetry —
              // otherwise nothing can select one without opening every row.
              const scoresFromTelemetry = (evaluation.criteria || []).some((criterion) => criterionGroup(criterion) === 'telemetry');
              const { runs, runCount } = runsOf(evaluation);
              const evaluated = shown?.samples_evaluated || 0;
              const passed = shown?.samples_passed || 0;
              const ratio = evaluated ? passed / evaluated : 0;
              const inProgress = IN_PROGRESS.includes(latest?.status);
              const fill = inProgress ? 'var(--color-info)' : TONE[toneFor(ratio)].strong;
              const note = runNote(evaluation, shown);
              const delta = runDelta(latest, evaluation.previous_run, { olderNumber: evaluation.previous_run?.number });
              const archiving = archivingId === evaluation.id;
              const rowCell = (extra) => cell(last && !open, extra);
              return (
                <React.Fragment key={evaluation.id}>
                  <div
                    className="aa-row"
                    role="button"
                    tabIndex={0}
                    aria-expanded={open}
                    data-testid="evaluation-card"
                    data-kind={suite ? 'suite' : 'sampling'}
                    data-open={open ? 'true' : 'false'}
                    data-standing={standing}
                    data-telemetry={scoresFromTelemetry ? 'true' : 'false'}
                    onClick={() => toggleOpen(evaluation)}
                    onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); toggleOpen(evaluation); } }}
                    style={{ display: 'grid', gridTemplateColumns, alignItems: 'center', cursor: 'pointer' }}
                  >
                    <div style={rowCell({ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' })}>
                      <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--color-text-primary)' }}>{evaluation.name}</span>
                      <span style={{ padding: '1px 6px', borderRadius: 4, fontSize: 11, background: 'var(--color-muted)', color: 'var(--color-text-muted)', whiteSpace: 'nowrap' }} data-testid="evaluation-kind">
                        {suite ? 'Scenarios' : 'Sampled'}
                      </span>
                    </div>
                    {!embedded && (
                      <div style={rowCell({ color: 'var(--color-text-secondary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' })}>{evaluation.agent?.name}</div>
                    )}
                    <div style={rowCell({ display: 'flex', alignItems: 'center', gap: 10 })} data-testid="evaluation-latest-run">
                      {shown ? (
                        <>
                          <span style={{ width: 96, height: 4, borderRadius: 2, background: 'var(--color-border)', flexShrink: 0, overflow: 'hidden' }} aria-hidden="true">
                            <span style={{ display: 'block', height: '100%', width: `${Math.round(ratio * 100)}%`, borderRadius: 2, background: fill }} />
                          </span>
                          <span style={{ ...monoStyle(13, 'var(--color-text-primary)'), whiteSpace: 'nowrap' }}>{fmtPasses(passed, evaluated)}</span>
                          {note && <span style={{ ...monoStyle(12, note.color), whiteSpace: 'nowrap' }}>{note.text}</span>}
                        </>
                      ) : (
                        <span style={monoStyle(12)}>no runs</span>
                      )}
                    </div>
                    <div style={rowCell(monoStyle(12, delta ? DELTA_TONE[delta.tone] : 'var(--color-text-muted)'))}>
                      {delta ? shortDelta(delta.text) : '—'}
                    </div>
                    <div style={rowCell({ ...monoStyle(13, fixCount > 0 ? 'var(--color-warning-text)' : 'var(--color-text-muted)'), ...TABLE.right })}>
                      {fixCount > 0 ? fixCount : '—'}
                    </div>
                    <div style={rowCell({ ...monoStyle(12), overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' })} title={(latest?.models || evaluation.compare_models || []).join(', ') || undefined}>
                      {modelsText(evaluation)}
                    </div>
                    <div style={rowCell({ ...monoStyle(12), ...TABLE.right, whiteSpace: 'nowrap' })}>
                      {latest?.status === 'running' ? 'now' : timeAgo(latest?.completed_at || latest?.created_at || evaluation.created_at)}
                    </div>
                    <div style={rowCell(TABLE.right)}>
                      <button
                        type="button"
                        onClick={(event) => { event.stopPropagation(); handleArchive(evaluation, !archived); }}
                        disabled={archiving}
                        title={archived ? 'Bring this evaluation back into the list and the summary' : 'Archive: keep its runs, leave it out of the list and the summary'}
                        data-testid="evaluation-archive-toggle"
                        style={{ background: 'transparent', border: 'none', padding: 0, cursor: archiving ? 'not-allowed' : 'pointer', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)', opacity: archiving ? 0.5 : 1 }}
                      >
                        {archiving ? '…' : archived ? 'unarchive' : 'archive'}
                      </button>
                    </div>
                  </div>

                  {open && (
                    <div style={{ padding: '4px 14px 16px', background: 'var(--color-background)', borderBottom: last ? 'none' : '1px solid var(--color-border-light)' }}>
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
                        <div style={{ padding: '12px 0 0', display: 'flex', flexDirection: 'column', gap: 12 }} data-testid="sampling-evaluation-panel">
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
                            run={latest}
                            spend={runSpend(latest)}
                            onDelete={() => handleDelete(evaluation)}
                            deleting={deletingId === evaluation.id}
                          />
                        </div>
                      )}
                    </div>
                  )}
                </React.Fragment>
              );
            })}
          </div>
        </div>
      )}

      {anyOlderVersion && (
        <Hint>Amber “older version”: the latest run predates the agent's current version. Run again to refresh it.</Hint>
      )}
    </div>
  );
}
