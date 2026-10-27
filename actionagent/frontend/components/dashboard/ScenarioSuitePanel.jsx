import React, { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { dashboardPath, navigateTo } from '../../utils/dashboardPath';
import { reportExports } from '../../utils/reportExport.mjs';
import { Button, Chip, Empty, MicroLabel, MonoLink, MONO } from './primitives';
import { scenarioRowsForRun } from '../../utils/evaluationHistory.mjs';
import {
  DETAILS_KEPT, KEY_COLUMN_MIN_WIDTH, PANEL_GUTTER, RAIL_BREAKPOINT, RAIL_GAP, RAIL_WIDTH, RUNS_SHOWN, STEPS_HEIGHT,
  currentStepKey, groupResultsByKey, groupsOutsideRun, keepDetails, keepSandboxChoice, orderScenarioRows, pollIntervalFor,
  readDetailChoice, reconcileResults, rerunFailedKeys, runDelta, runRequestBody, runRequestSelection, runSandboxLabel,
  runSandboxOptions, runSelectionLabel, runSpend, runnableKeys, scenarioStep, writeDetailChoice,
} from '../../utils/evaluationRuns.mjs';
import { buildModelOptions, parseModelList } from '../../utils/modelOptions.mjs';
import { MODEL_PROVIDERS } from '../../utils/providerModels';
import { useProviderModels } from '../../hooks/useProviderModels';
import useMeasuredWidth, { useIsoLayoutEffect } from '../../hooks/useMeasuredWidth';
import MultiModelPicker from './MultiModelPicker';
import { RunRail, runRows } from './evaluations/RunsList';
import RunHeader from './evaluations/RunHeader';
import CriteriaFooter from './evaluations/CriteriaFooter';
import { scenariosToText } from '../../utils/scenarioSuiteText.mjs';
import {
  FixList, ModelsPanel, ScenarioDetail, ScenarioMatrix,
  escapeKey, fixItemsFor, inProgress, isPassed, isSettled, labelForResult, modelColumns, plural,
  runBars, runScenarioCount, runScenarioKeys, runTotalOf, runTotals,
} from './EvaluationRunPanels';

// The expanded body of a scenario-suite evaluation, read like a build page:
// the suite's controls, then the shown run's header card (which run, how it
// moved, what it passed and cost, how far it is while it goes), then the
// scenarios toolbar above two columns — a rail of the suite's runs beside
// the Steps box, the scenario × model matrix read as build steps with a
// per-scenario drill-down — then which model (Models), what to fix (What to
// fix) and the footer. Below RAIL_BREAKPOINT of content width the rail
// becomes a strip of the latest runs above the box.
//
// This panel owns the state: the fetched runs and their details, which run
// is shown, whether the box follows a running run, which groups are folded,
// the row detail level, the row order, a deep-linked run outside the fetched
// page, and the loading and error state of a run's results. The pieces it
// renders are presentational (RunHeader, RunRail, ScenarioMatrix, ModelsPanel,
// FixList). It also carries the suite's controls: edit the pasted scenarios,
// run a group / everything / one scenario under chosen models, enable or
// disable a scenario, delete the suite.

const stripResults = (run) => {
  const { results, fix_items: fixItems, ...summary } = run;
  return summary;
};

const NO_RERUN = { keys: [], dropped: [] };

const inputStyle = {
  padding: '6px 10px', borderRadius: 8, fontSize: 12, fontFamily: MONO,
  background: 'var(--color-card)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)',
};

const boxEmptyStyle = { border: '1px solid var(--color-border-light)', borderRadius: 10 };

const sameSet = (a, b) => a.size === b.size && [...a].every((entry) => b.has(entry));

// The browser's storage for the remembered detail level; none in a static
// render, which readDetailChoice reads as unset.
const storage = () => (typeof localStorage !== 'undefined' ? localStorage : null);

const hidden = () => typeof document !== 'undefined' && document.visibilityState === 'hidden';

// `initialRunId` is the run a deep link (/evaluations/:id/runs/:run_id)
// asks for, and `initialResultId` the scenario result one asks for
// (…/runs/:run_id/results/:result_id), whose row opens once the run's
// results land; `onRunSelected` reports the run a click in the list picked, so
// the page can put it in the URL. `modelProviders` are the providers the
// models field suggests models from: those runs have credentials for,
// undefined until known and null when the evaluations list did not say.
export default function ScenarioSuitePanel({
  evaluation, modelProviders, onChanged, onDelete, deleting = false, initialRunId = null, initialResultId = null, onRunSelected,
}) {
  const evaluationId = evaluation.id;
  const agentName = evaluation.agent?.name || 'Agent';

  // The suite's scenarios and run history land with the first fetch; until
  // then the matrix shows a loading line rather than an empty suite. The
  // show payload already carries the catalog (the index payload does not),
  // so a deep link opens on its rows.
  const [loaded, setLoaded] = useState(false);
  // Why the last suite fetch failed, when it did. A suite that could not be
  // loaded is not an empty suite: reporting one as the other hides the
  // failure and invites a paste over scenarios that are still there.
  const [loadError, setLoadError] = useState(null);
  const [scenarios, setScenarios] = useState(evaluation.scenarios || []);
  const [groups, setGroups] = useState(evaluation.scenario_groups || []);
  const [runs, setRuns] = useState(evaluation.latest_run ? [evaluation.latest_run] : []);
  // The suite's total run count when the API reports it (`run_count`); the
  // run list itself is capped at the most recent RUNS_PAGE.
  const [runCount, setRunCount] = useState(null);
  // A deep-linked run starts selected, so the latest run does not show
  // first and give way once the linked one lands.
  const [selectedRunId, setSelectedRunId] = useState(initialRunId ?? evaluation.latest_run?.id ?? null);
  // Fetched runs with their results, by id — at most DETAILS_KEPT of them.
  const [details, setDetails] = useState({});
  // Why a run's results could not be fetched, by run id.
  const [detailErrors, setDetailErrors] = useState({});
  // A deep-linked run older than the fetched page: shown pinned at the top
  // of the rail, never spliced into `runs` (whose neighbours give movement).
  const [linkedRun, setLinkedRun] = useState(null);
  const [modelsInput, setModelsInput] = useState((evaluation.compare_models || []).join(', '));
  const runProviders = useMemo(
    () => (modelProviders === undefined ? [] : (modelProviders ?? MODEL_PROVIDERS)),
    [modelProviders],
  );
  const catalog = useProviderModels(runProviders);
  const modelOptions = useMemo(() => buildModelOptions(catalog, { providers: runProviders }), [catalog, runProviders]);
  const [runError, setRunError] = useState(null);
  const [isRunning, setIsRunning] = useState(false);
  // "Run against sandbox": the caller's ready checkout sandboxes, and the one
  // chosen ('' runs on the agent's own servers only).
  const [sandboxOptions, setSandboxOptions] = useState([]);
  const [sandboxId, setSandboxId] = useState('');
  const [editing, setEditing] = useState(false);
  const [editText, setEditText] = useState('');
  const [editError, setEditError] = useState(null);
  const [groupFilter, setGroupFilter] = useState(null);
  const [failedOnly, setFailedOnly] = useState(false);
  const [openKey, setOpenKey] = useState(null);
  // Whether the box keeps the running run's cursor in view; off once the
  // person scrolls, clicks or focuses into the box, on again for a new run.
  const [following, setFollowing] = useState(true);
  // Folded groups (by name, '' for the ungrouped), starting with those the
  // first shown run leaves out (a static render and a deep link see them
  // folded); `manualGroups` remembers which the person opened (true) or
  // folded (false) by hand, so the auto-fold leaves them.
  const [collapsedGroups, setCollapsedGroups] = useState(() => {
    const catalog = evaluation.scenarios || [];
    const shown = initialRunId == null || initialRunId === evaluation.latest_run?.id ? evaluation.latest_run || null : null;
    return groupsOutsideRun(catalog, new Set(runScenarioKeys(shown, catalog)));
  });
  const [manualGroups, setManualGroups] = useState(() => new Map());
  // The row detail level the browser remembers (`tools`), or null for the
  // default: one-line steps.
  const [detailChoice, setDetailChoice] = useState(() => readDetailChoice(storage()));
  // Row order: the suite's, or failed groups and rows first.
  const [order, setOrder] = useState('suite');

  const rootRef = useRef(null);
  const boxRef = useRef(null);
  const fixRef = useRef(null);
  // One request per run id at a time: a second fetch awaits the first.
  const inflight = useRef(new Map());
  // scenarioRowsForRun's row cache: a row keeps its identity across polls
  // while nothing about it changed.
  const rowCache = useRef(new Map());
  const resultsByKeyRef = useRef({});
  const detailsRef = useRef(details);
  const selectedRef = useRef(selectedRunId);
  // The poll's timer, re-armed from inside its own callback.
  const pollTimer = useRef(null);
  const width = useMeasuredWidth(rootRef);

  // --- layout -----------------------------------------------------------

  // The panel's content width (its root's clientWidth includes the two 16px
  // paddings) decides whether the runs sit beside the box or above it. An
  // unmeasured panel — a static render, the first layout pass — keeps the
  // rail; the layout effect measures before paint.
  const content = width - PANEL_GUTTER;
  const wide = width === 0 || content >= RAIL_BREAKPOINT;
  const boxWidth = width === 0 ? 0 : content - (wide ? RAIL_WIDTH + RAIL_GAP : 0);
  const detail = detailChoice ?? 'steps';
  const showKey = boxWidth === 0 || boxWidth >= KEY_COLUMN_MIN_WIDTH;

  // --- data -------------------------------------------------------------

  const fetchScenarios = useCallback(async () => {
    const response = await fetch(`/api/evaluations/${evaluationId}/scenarios`);
    if (!response.ok) return;
    const data = await response.json();
    setScenarios(data.scenarios || []);
    setGroups(data.groups || []);
  }, [evaluationId]);

  // The suite with its scenarios and run history (the most recent RUNS_PAGE,
  // newest first, plus `run_count` — the total — when the API reports it).
  // A refused or failed fetch records why rather than leaving the panel to
  // render what it already has as the whole suite — see loadError.
  const fetchSuite = useCallback(async () => {
    try {
      const response = await fetch(`/api/evaluations/${evaluationId}`);
      if (!response.ok) {
        setLoadError(`Could not load this suite (HTTP ${response.status})`);
        return null;
      }
      const data = await response.json();
      const suite = data.evaluation || {};
      setScenarios(suite.scenarios || []);
      setGroups(suite.scenario_groups || []);
      setRuns(suite.runs || []);
      setRunCount(Number.isFinite(suite.run_count) ? suite.run_count : null);
      setLoadError(null);
      return suite;
    } catch (error) {
      // Caught rather than propagated: the callers await this from an effect
      // and from the poll, where a rejection would surface as an unhandled
      // one instead of as the message below.
      setLoadError(`Could not load this suite: ${error.message}`);
      return null;
    } finally {
      setLoaded(true);
    }
  }, [evaluationId]);

  // The details the fetch reconciles against, and the run shown: the state
  // as last rendered, for the effects that read it after an await.
  useIsoLayoutEffect(() => {
    detailsRef.current = details;
    selectedRef.current = selectedRunId;
  });

  // A run with its results. One request per run id is in flight at a time;
  // a refused or failed fetch records why (the box offers a retry) and
  // answers null. A landed run replaces the kept one only when something
  // changed — its results are reconciled by id so unchanged ones keep their
  // objects — and the run's summary in `runs` is refreshed with it, so an
  // unchanged poll re-renders nothing.
  const fetchRunDetail = useCallback((runId) => {
    if (!runId) return Promise.resolve(null);
    if (inflight.current.has(runId)) return inflight.current.get(runId);
    const request = (async () => {
      try {
        const response = await fetch(`/api/evaluations/${evaluationId}/runs/${runId}`);
        if (!response.ok) {
          setDetailErrors((prev) => ({ ...prev, [runId]: `HTTP ${response.status}` }));
          return null;
        }
        const data = await response.json();
        const run = data.run;
        if (!run) {
          setDetailErrors((prev) => ({ ...prev, [runId]: 'no run in the response' }));
          return null;
        }
        setDetailErrors((prev) => {
          if (!(runId in prev)) return prev;
          const { [runId]: _cleared, ...rest } = prev;
          return rest;
        });
        const previous = detailsRef.current[run.id];
        const { results, changed } = reconcileResults(previous?.results, run.results);
        const same = !!previous && !changed && previous.status === run.status && previous.completed_at === run.completed_at
          && (previous.fix_items?.length ?? 0) === (run.fix_items?.length ?? 0);
        if (!same) {
          const summary = stripResults(run);
          setDetails((prev) => ({ ...prev, [run.id]: { ...run, results } }));
          setRuns((prev) => (prev.some((r) => r.id === run.id) ? prev.map((r) => (r.id === run.id ? { ...r, ...summary } : r)) : prev));
          setLinkedRun((prev) => (prev && prev.id === run.id ? { ...prev, ...summary } : prev));
        }
        return run;
      } catch (error) {
        setDetailErrors((prev) => ({ ...prev, [runId]: error.message }));
        return null;
      } finally {
        inflight.current.delete(runId);
      }
    })();
    inflight.current.set(runId, request);
    return request;
  }, [evaluationId]);

  // A deep-linked run outside the fetched page, once its detail has landed:
  // pinned at the top of the rail and selected.
  const adoptLinked = (linked) => {
    setLinkedRun(stripResults(linked));
    setSelectedRunId(linked.id);
    setOpenKey(null);
  };

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const suite = await fetchSuite();
      if (cancelled) return;
      const latestId = suite?.runs?.[0]?.id ?? null;
      const inPage = Boolean(initialRunId && suite?.runs?.some((r) => r.id === initialRunId));
      if (initialRunId && !inPage) {
        // Older than the page: fetched before falling back to the latest,
        // so the latest run does not show first.
        const linked = await fetchRunDetail(initialRunId);
        if (cancelled) return;
        if (linked) {
          adoptLinked(linked);
          return;
        }
      }
      // The run shown so far (the index's latest run) stays shown while the
      // page still lists it — a run started elsewhere since the index was
      // read does not take its place — else the latest is shown. Whichever
      // it is, that is the run fetched: a selection whose detail was never
      // requested would read "loading results…" for good.
      const wanted = inPage ? initialRunId : null;
      const current = selectedRef.current;
      const next = wanted || (current && suite?.runs?.some((r) => r.id === current) ? current : latestId);
      setSelectedRunId(next);
      if (next) fetchRunDetail(next);
    })();
    return () => { cancelled = true; };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fetchSuite, fetchRunDetail]);

  // A run started elsewhere (the page header, another tab) shows up as a new
  // latest run on the evaluation; pick it up.
  const latestFromParent = evaluation.latest_run?.id ?? null;
  useEffect(() => {
    if (!latestFromParent || runs.some((r) => r.id === latestFromParent)) return;
    fetchSuite();
  }, [latestFromParent, runs, fetchSuite]);

  const selectedRun = details[selectedRunId]
    || runs.find((r) => r.id === selectedRunId)
    || (linkedRun?.id === selectedRunId ? linkedRun : null);
  const latestRun = runs[0] || null;

  // A run replays every scenario through the provider, so it finishes in the
  // background; poll the run being viewed (or the latest, when that is the
  // one still going) until it settles. The timer re-arms itself from inside
  // its callback — a poll that found the run still going, failed or was
  // refused touches no state, so an unchanged poll re-renders nothing at
  // all. Nothing is armed while the tab is hidden, and a timer that fires
  // hidden neither fetches nor re-arms: the visibility listener restarts
  // polling, at once, when the tab is back. The wait grows with the polled
  // run's result count, since every poll re-sends every result.
  const pollId = inProgress(selectedRun) ? selectedRun.id : inProgress(latestRun) ? latestRun.id : null;
  useEffect(() => {
    if (!pollId) return undefined;
    let cancelled = false;
    const interval = () => pollIntervalFor(detailsRef.current[pollId]?.results?.length ?? 0);
    const arm = (delay) => {
      clearTimeout(pollTimer.current);
      pollTimer.current = setTimeout(async () => {
        if (cancelled || hidden()) return;
        let latest = null;
        try {
          latest = await fetchRunDetail(pollId);
        } catch (_error) {
          latest = null;
        }
        if (cancelled) return;
        if (latest && !inProgress(latest)) {
          await fetchSuite();
          onChanged?.();
          return;
        }
        arm(interval());
      }, delay);
    };
    const onVisibility = () => {
      if (document.visibilityState === 'visible') arm(0);
    };
    if (!hidden()) arm(interval());
    if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVisibility);
    return () => {
      cancelled = true;
      clearTimeout(pollTimer.current);
      if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [pollId, fetchRunDetail, fetchSuite, onChanged]);

  // The checkout sandboxes a run can replay against. Listing them is a
  // convenience: a dashboard without sandboxes (or one that refuses the
  // listing) just offers none.
  const fetchSandboxes = useCallback(async () => {
    try {
      const response = await fetch('/api/sandboxes?sandbox_type=app_runtime');
      if (!response.ok) return;
      const data = await response.json();
      const options = runSandboxOptions(data.sandboxes);
      setSandboxOptions(options);
      setSandboxId((current) => keepSandboxChoice(current, options));
    } catch (_error) {
      // None offered.
    }
  }, []);
  useEffect(() => { fetchSandboxes(); }, [fetchSandboxes]);

  // --- actions ----------------------------------------------------------

  const selectedModels = parseModelList(modelsInput);

  const startRun = async (selection) => {
    setIsRunning(true);
    setRunError(null);
    try {
      const response = await fetch(`/api/evaluations/${evaluationId}/run`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(runRequestBody(selection, selectedModels, sandboxId)),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        // A sandbox that stopped since it was listed: list again, so it is
        // no longer offered.
        if (data.code === 'sandbox_refused') fetchSandboxes();
        throw new Error((data.errors || [data.error]).filter(Boolean).join(', ') || 'Run failed to start');
      }
      const run = data.run;
      setRuns((prev) => [run, ...prev.filter((r) => r.id !== run.id)]);
      setRunCount((count) => (count == null ? null : count + 1));
      setDetails((prev) => ({ ...prev, [run.id]: { ...run, results: [] } }));
      setSelectedRunId(run.id);
      setOpenKey(null);
      setFollowing(true);
      setOrder('suite');
      onChanged?.();
    } catch (error) {
      setRunError(error.message);
    } finally {
      setIsRunning(false);
    }
  };

  // The details worth keeping once `runId` is shown: it, the latest run and
  // the run shown before it — DETAILS_KEPT in all; the rest are fetched
  // again on return, reading as loading meanwhile.
  const keptAround = (runId) => [runId, latestRun?.id, selectedRunId].slice(0, DETAILS_KEPT);

  const selectRun = (runId) => {
    setSelectedRunId(runId);
    setOpenKey(null);
    setDetails((prev) => keepDetails(prev, keptAround(runId)));
    if (!details[runId]) fetchRunDetail(runId);
  };

  const openRun = (candidate) => {
    selectRun(candidate.id);
    onRunSelected?.(candidate.id);
  };

  // A later deep link to another of this suite's runs selects it in place —
  // fetched and pinned first when it is older than the fetched page.
  useEffect(() => {
    if (!initialRunId || initialRunId === selectedRunId) return undefined;
    if (runs.some((r) => r.id === initialRunId) || linkedRun?.id === initialRunId) {
      selectRun(initialRunId);
      return undefined;
    }
    if (!loaded) return undefined;
    let cancelled = false;
    (async () => {
      const linked = await fetchRunDetail(initialRunId);
      if (cancelled || !linked) return;
      setDetails((prev) => keepDetails(prev, keptAround(linked.id)));
      adoptLinked(linked);
    })();
    return () => { cancelled = true; };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialRunId]);

  const toggleScenario = async (scenario) => {
    if (!scenario.id) return;
    await fetch(`/api/evaluations/${evaluationId}/scenarios/${scenario.id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ scenario: { enabled: scenario.enabled === false } }),
    });
    await fetchScenarios();
  };

  const saveScenarios = async () => {
    setEditError(null);
    const response = await fetch(`/api/evaluations/${evaluationId}/scenarios`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ scenarios_text: editText }),
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      setEditError((data.errors || [data.error]).filter(Boolean).join(', ') || 'Could not save scenarios');
      return;
    }
    setScenarios(data.scenarios || []);
    setGroups(data.groups || []);
    setEditing(false);
    onChanged?.();
  };

  // --- derivations ------------------------------------------------------

  const run = selectedRun;
  // A run whose results are still being fetched (its summary from the runs
  // page, or its detail evicted): every figure the summary carries is
  // shown, and the rows read as loading rather than as missing.
  const detailLoading = !!run && !Array.isArray(run.results);
  const detailError = run ? detailErrors[run.id] : null;
  const results = useMemo(() => (run?.results || []).filter((r) => r && r.scenario_key), [run]);
  // The model columns keep their array while their labels are the same, so
  // a memoised row keeps its columns across polls.
  const columnsKey = modelColumns(run, results, evaluation).join('\u0000');
  const columns = useMemo(() => (columnsKey ? columnsKey.split('\u0000') : []), [columnsKey]);
  // Results by scenario key, then by column; a key whose results did not
  // change keeps its object from the previous poll.
  const resultsByKey = useMemo(
    () => groupResultsByKey(results, (result) => labelForResult(run, result), resultsByKeyRef.current),
    [results, run],
  );
  useIsoLayoutEffect(() => {
    resultsByKeyRef.current = resultsByKey;
  });
  const runKeys = useMemo(() => new Set(runScenarioKeys(run, scenarios)), [run, scenarios]);
  const running = inProgress(run);
  const scenarioCount = runScenarioCount(run, columns, scenarios);
  const totals = runTotals(run, results, columns, scenarios);

  // Whether the selected run covers a scenario at all — a cell outside the
  // run reads "—", and its drill-down offers a replay instead of results.
  const inRun = useCallback(
    (scenario) => runKeys.has(scenario.key) || Boolean(resultsByKey[scenario.key]),
    [runKeys, resultsByKey],
  );

  // Every scenario of the suite stays listed whatever the last run covered,
  // so a group can be filtered, toggled and replayed after a partial run; a
  // result whose scenario has since been removed from the suite still
  // renders from what the result recorded about it.
  const matrixScenarios = useMemo(
    () => scenarioRowsForRun(scenarios, resultsByKey, rowCache.current),
    [scenarios, resultsByKey],
  );

  // Every scenario's step — over the whole suite, not the filtered rows, so
  // the cursor cannot hide behind a filter.
  const stepsByKey = useMemo(() => {
    const steps = {};
    matrixScenarios.forEach((scenario) => {
      const covered = inRun(scenario);
      steps[scenario.key] = detailLoading
        ? (covered ? 'loading' : 'skipped')
        : run ? scenarioStep(resultsByKey[scenario.key], columns, { inRun: covered, running }) : 'none';
    });
    return steps;
  }, [matrixScenarios, inRun, resultsByKey, columns, run, detailLoading, running]);
  const stepOf = useCallback((scenario) => stepsByKey[scenario.key], [stepsByKey]);
  // The step the build is on: the first being replayed, else the first
  // still queued, in suite order.
  const currentKey = useMemo(
    () => (running ? currentStepKey(matrixScenarios.map((scenario) => ({ key: scenario.key, step: stepsByKey[scenario.key] }))) : null),
    [running, matrixScenarios, stepsByKey],
  );

  const failedOn = useCallback((scenario) => columns.some((label) => {
    const result = resultsByKey[scenario.key]?.[label];
    return isSettled(result) && !isPassed(result);
  }), [columns, resultsByKey]);
  const failedScenarioCount = useMemo(() => matrixScenarios.filter(failedOn).length, [matrixScenarios, failedOn]);
  // Failed-first only orders a complete run whose results are in; the
  // stream of a running run stays in run order.
  const orderable = !!run && run.status === 'complete' && !detailLoading;
  const visibleRows = useMemo(() => orderScenarioRows(
    matrixScenarios
      .filter((s) => !groupFilter || (s.group || '') === groupFilter)
      .filter((s) => !failedOnly || failedOn(s)),
    stepOf,
    orderable ? order : 'suite',
  ), [matrixScenarios, groupFilter, failedOnly, failedOn, stepOf, orderable, order]);

  const groupCount = new Set(matrixScenarios.filter(inRun).map((s) => s.group).filter(Boolean)).size;
  const settledCount = results.filter(isSettled).length;
  const settledFailed = results.filter((r) => isSettled(r) && !isPassed(r)).length;
  const expectedResults = scenarioCount * Math.max(columns.length, 1);
  const faultScenarios = new Set(results.filter((r) => isSettled(r) && !isPassed(r)).map((r) => r.scenario_key)).size;
  const verdict = run?.scores?._verdict || null;
  const judgedBy = Object.prototype.hasOwnProperty.call(run?.scores || {}, '_judge_label')
    ? (run.scores._judge_label || 'rules')
    : ((verdict?.judge && verdict.judge !== 'pass rate') ? verdict.judge : (evaluation.judge_model || 'rules'));
  const fixItems = useMemo(() => (run ? fixItemsFor(run, results) : []), [run, results]);
  // The scenarios `re-run failed` posts: those with a settled failure, less
  // the ones since disabled or removed. Nothing until the results are in.
  const rerun = useMemo(() => (detailLoading ? NO_RERUN : rerunFailedKeys(results, scenarios)), [detailLoading, results, scenarios]);
  const criteriaKeys = Object.keys(run?.scores || {}).filter((key) => !key.startsWith('_'));

  // The rows of the runs list: one pass bar per model column of each run.
  // Bars count from the results that have landed for that run — the shown
  // run's, or a cached run's: the polled run keeps landing while an older
  // run is shown, so its rail card fills in as it goes instead of reading
  // 0/n from a summary it does not have yet. A run with nothing loaded
  // reads from its summary; a run that recorded nothing for a model draws
  // a dash there, not a 0/n.
  const barsFor = useCallback(
    (candidate) => runBars(
      candidate,
      candidate.id === run?.id ? results : (details[candidate.id]?.results || []).filter((r) => r && r.scenario_key),
      evaluation,
      scenarios,
    ),
    [run, results, details, evaluation, scenarios],
  );

  // Movement is only read against a run of the same shape — the same
  // scenarios under the same number of models — so a partial run (one
  // group, one scenario) is not compared to a full one.
  const deltaFor = useCallback((candidate, older, olderNumber) => {
    if (!older || older.status !== 'complete' || candidate.status !== 'complete') return runDelta(candidate, older, { olderNumber });
    const cols = modelColumns(candidate, candidate.id === run?.id ? results : [], evaluation);
    const baseCols = modelColumns(older, [], evaluation);
    const sameShape = runScenarioCount(older, baseCols, scenarios) === runScenarioCount(candidate, cols, scenarios)
      && baseCols.length === cols.length;
    return runDelta(candidate, older, { olderNumber, comparable: sameShape });
  }, [run, results, evaluation, scenarios]);

  // The runs as the rail and the header read them, computed once: number,
  // movement against the run before (the index payload's `previous_run`
  // stands in until the runs page lands), bars and spend.
  const rows = useMemo(() => runRows({
    runs, runCount, evaluation, agentName, selectedId: run?.id ?? null, previousRun: evaluation.previous_run, barsFor, deltaFor,
  }), [runs, runCount, evaluation, agentName, run?.id, barsFor, deltaFor]);
  const headerRow = rows.find((row) => row.run.id === run?.id) || null;
  // A run outside the page (the linked one) carries its own number from
  // show_run; its movement is unknown.
  const runNumber = headerRow?.number ?? (Number.isFinite(run?.number) ? run.number : null);
  const headerBars = headerRow?.bars ?? (run ? barsFor(run) : []);
  const latestNumber = runTotalOf(runs, runCount);
  const isLatest = !!run && latestRun?.id === run.id;
  const runningElsewhere = inProgress(latestRun) && latestRun.id !== run?.id ? latestRun : null;

  // Until the suite has loaded, the counts the index already knows stand in
  // for the scenario list — unless the catalog came with the evaluation.
  const catalogKnown = loaded || scenarios.length > 0;
  const scenarioTotal = catalogKnown ? scenarios.length : (evaluation.scenario_count ?? 0);
  const enabledCount = catalogKnown
    ? scenarios.filter((s) => s.enabled !== false && (!groupFilter || (s.group || '') === groupFilter)).length
    : scenarioTotal;
  const runLabel = `Run ${plural(enabledCount, 'scenario')}${selectedModels.length ? ` × ${plural(selectedModels.length, 'model')}` : ''}`;

  const summary = `@${agentName} · ${plural(scenarioTotal, 'scenario')}${groups.length ? ` in ${plural(groups.length, 'group')}` : ''}`
    + ` · ${loadError ? 'not loaded' : !loaded ? 'loading…' : runs.length ? plural(latestNumber, 'run') : 'no runs yet'}`;

  const reportPath = run && run.status === 'complete' ? `/evaluations/${evaluationId}/runs/${run.id}/report` : null;
  // The run's Markdown report, which the copy buttons read their pieces from.
  const markdownUrl = reportPath ? dashboardPath(reportExports(reportPath).markdown) : null;

  const visibleGroups = [...new Set([...groups, ...matrixScenarios.map((s) => s.group).filter(Boolean)])];
  const groupChips = [{ label: `All ${matrixScenarios.length || scenarioTotal}`, value: null }]
    .concat(visibleGroups.map((group) => ({ label: catalogKnown ? `${group} ${matrixScenarios.filter((s) => s.group === group).length}` : group, value: group })));
  // The groups the box draws a row for, '' being the ungrouped scenarios
  // among grouped ones.
  const foldableGroups = useMemo(() => {
    const names = [...new Set(matrixScenarios.map((s) => s.group || ''))];
    return names.some(Boolean) ? names : [];
  }, [matrixScenarios]);
  const anyGroupOpen = foldableGroups.some((name) => !collapsedGroups.has(name));

  const suiteEmpty = matrixScenarios.length === 0;

  const emptyLabel = failedOnly ? '[+] nothing failed in this group' : '[ ] no scenarios';

  // --- the box's state --------------------------------------------------

  // Every new run starts followed, in suite order, with nothing open and
  // no folds of the person's.
  useEffect(() => {
    setFollowing(true);
    setManualGroups(new Map());
    setOrder('suite');
    setOpenKey(null);
  }, [run?.id]);

  // The groups a run leaves out start folded; read again once the catalog
  // lands, since the index payload carries no scenarios to read it from.
  useEffect(() => {
    setCollapsedGroups(groupsOutsideRun(scenarios, runKeys));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [run?.id, loaded]);

  // While a run goes and the box follows it, a group whose steps all passed
  // folds itself and the group holding the cursor opens — except groups the
  // person folded or opened by hand. Built on the folds as they stand (the
  // reset above lands in the same commit when the run changed), and left
  // for the next poll when the run has just changed, so a run's own folds
  // never carry a previous run's.
  const foldedFor = useRef(run?.id ?? null);
  useEffect(() => {
    if (foldedFor.current !== (run?.id ?? null)) {
      foldedFor.current = run?.id ?? null;
      return;
    }
    if (!running || !following) return;
    setCollapsedGroups((prev) => {
      const next = new Set(prev);
      foldableGroups.forEach((name) => {
        if (manualGroups.has(name)) return;
        const members = matrixScenarios.filter((s) => (s.group || '') === name && inRun(s));
        if (!members.length) return;
        if (members.every((s) => stepsByKey[s.key] === 'passed')) next.add(name);
        if (members.some((s) => s.key === currentKey)) next.delete(name);
      });
      return sameSet(next, prev) ? prev : next;
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [run?.id, currentKey, settledCount, following, running]);

  const onToggleGroup = (name) => {
    const nowOpen = collapsedGroups.has(name);
    setCollapsedGroups((prev) => {
      const next = new Set(prev);
      if (nowOpen) next.delete(name);
      else next.add(name);
      return next;
    });
    setManualGroups((prev) => new Map(prev).set(name, nowOpen));
  };
  const setAllGroups = (open) => {
    setCollapsedGroups(new Set(open ? [] : foldableGroups));
    setManualGroups(new Map(foldableGroups.map((name) => [name, open])));
  };

  const chooseDetail = (next) => {
    setDetailChoice(next);
    writeDetailChoice(storage(), next);
  };

  const toggleRow = useCallback((key) => {
    setOpenKey((open) => (open === key ? null : key));
    setFollowing(false);
  }, []);
  const stopFollowing = useCallback(() => setFollowing(false), []);

  // A fix card names the scenarios its fault came from; clicking that scope
  // opens the first one so the question, the answer and the tools it called
  // are on screen. Filters are cleared and its group unfolded first — the
  // row is often one a chip, "failed only" or a fold is currently hiding —
  // and the page scrolls to the box, where the matrix puts the row under
  // its header. Focus moves to the row with it: the card that was activated
  // is a screen below, and from the row Esc, ↑ and ↓ work as they would
  // had the row been opened in place.
  const openScenario = useCallback((keys) => {
    const key = Array.isArray(keys) ? keys[0] : keys;
    if (!key) return;
    const group = matrixScenarios.find((s) => s.key === key)?.group || '';
    setGroupFilter(null);
    setFailedOnly(false);
    setCollapsedGroups((prev) => {
      if (!prev.has(group)) return prev;
      const next = new Set(prev);
      next.delete(group);
      return next;
    });
    setManualGroups((prev) => new Map(prev).set(group, true));
    setOpenKey(key);
    setFollowing(false);
    // The box renders the row after the filters clear; the page scroll waits a frame.
    requestAnimationFrame(() => {
      const box = boxRef.current;
      if (!box) return;
      box.scrollIntoView({ behavior: 'smooth', block: 'start' });
      box.querySelector(`[data-scenario-key="${escapeKey(key)}"]`)?.focus({ preventScroll: true });
    });
  }, [matrixScenarios]);

  // A link to one scenario result opens its row, once per link: when the
  // linked run is the one shown, its results have landed and the catalog
  // is loaded (so the row's group is known and unfolded). Declared after
  // the per-run reset above, so it lands after it in the same commit.
  const openedLink = useRef(null);
  useEffect(() => {
    if (!initialResultId || !loaded || !run || run.id !== initialRunId || !Array.isArray(run.results)) return;
    const target = `${run.id}:${initialResultId}`;
    if (openedLink.current === target) return;
    const linked = run.results.find((result) => result?.id === initialResultId);
    if (!linked?.scenario_key) return;
    openedLink.current = target;
    openScenario(linked.scenario_key);
  }, [initialResultId, initialRunId, loaded, run, openScenario]);

  const jumpToFix = () => {
    fixRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    fixRef.current?.focus({ preventScroll: true });
  };

  const retryDetail = () => {
    if (!run) return;
    setDetailErrors((prev) => {
      const { [run.id]: _cleared, ...rest } = prev;
      return rest;
    });
    fetchRunDetail(run.id);
  };

  const showLatest = () => { if (latestRun) openRun(latestRun); };

  // --- render -----------------------------------------------------------

  const box = suiteEmpty && loadError ? (
    // The banner above carries the reason; this slot only has to stop
    // short of calling a suite that never loaded an empty one.
    <Empty style={boxEmptyStyle}>[!] suite not loaded</Empty>
  ) : suiteEmpty && !loaded ? (
    <Empty style={boxEmptyStyle}>loading…</Empty>
  ) : suiteEmpty ? (
    <Empty style={boxEmptyStyle}>No scenarios yet — paste some with “Edit scenarios”.</Empty>
  ) : selectedRunId != null && !run ? (
    // A deep-linked run older than the fetched page, still being resolved:
    // not the catalog as "not run yet", and not the latest run first.
    <Empty style={boxEmptyStyle}>loading…</Empty>
  ) : detailError && !Array.isArray(run.results) ? (
    <Empty style={boxEmptyStyle}>
      {`[!] results not loaded (${detailError}) · `}
      <MonoLink onClick={retryDetail} title="Fetch this run's results again" testId="suite-detail-retry">retry</MonoLink>
    </Empty>
  ) : (
    <ScenarioMatrix
      rows={visibleRows}
      columns={run ? columns : []}
      run={run}
      resultsByKey={resultsByKey}
      runKeys={runKeys}
      running={running}
      loading={detailLoading}
      stepsByKey={stepsByKey}
      currentKey={currentKey}
      bars={headerBars}
      detail={detail}
      showKey={showKey}
      collapsedGroups={collapsedGroups}
      onToggleGroup={onToggleGroup}
      openKey={openKey}
      onToggleRow={toggleRow}
      following={following}
      onStopFollowing={stopFollowing}
      emptyLabel={emptyLabel}
      maxHeight={STEPS_HEIGHT}
      boxRef={boxRef}
      renderDetail={(scenario) => (
        <ScenarioDetail
          scenario={scenario}
          run={run}
          columns={run ? columns : []}
          resultsByKey={resultsByKey}
          running={running}
          inRun={inRun(scenario)}
          canMutate={!scenario.orphan}
          onRerun={(s) => startRun({ keys: [s.key] })}
          onToggleEnabled={toggleScenario}
          markdownUrl={markdownUrl}
          evaluationId={evaluationId}
          linkedResultId={run && run.id === initialRunId ? initialResultId : null}
        />
      )}
    />
  );

  const railProps = {
    rows,
    runs,
    runCount,
    evaluation,
    agentName,
    selectedId: run?.id ?? null,
    onOpen: openRun,
    noteFor: (candidate) => runSelectionLabel(candidate, scenarios),
    linkedRun,
    linkedBars: linkedRun && barsFor(linkedRun),
  };

  return (
    <div
      ref={rootRef}
      style={{ padding: 16, display: 'flex', flexDirection: 'column', gap: 16 }}
      data-testid="scenario-suite-panel"
      data-layout={wide ? 'rail' : 'strip'}
    >
      {/* Controls row */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <span style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>{summary}</span>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <Button size="sm" onClick={() => { setEditText(scenariosToText(scenarios)); setEditError(null); setEditing(!editing); }}>
            {editing ? 'Cancel' : 'Edit scenarios'}
          </Button>
          <MultiModelPicker
            value={modelsInput}
            onChange={setModelsInput}
            models={modelOptions}
            inputLabel="Models to run"
            placeholder="models, e.g. gpt-5-mini, ollama/qwen3:8b"
            title="Blank runs the suite's saved models, or the agent's own model when it has none. Prefix a typed name with its provider (ollama/llama3.2) when the name alone is ambiguous."
            style={{ ...inputStyle, minWidth: 250, maxWidth: 420 }}
            testId="suite-models-picker"
          />
          {sandboxOptions.length > 0 && (
            <select
              value={sandboxId}
              onChange={(e) => setSandboxId(e.target.value)}
              style={{ ...inputStyle, maxWidth: 260 }}
              aria-label="Run against sandbox"
              title="Replays also reach this checkout sandbox's app runtime, as if the agent listed it in its MCP servers. The agent is not changed."
              data-testid="suite-run-sandbox"
            >
              <option value="">Run against: agent's own tools</option>
              {sandboxOptions.map((option) => (
                <option key={option.value} value={option.value}>{`Run against sandbox ${option.label}`}</option>
              ))}
            </select>
          )}
          <Button
            variant="primary"
            size="sm"
            disabled={isRunning || !loaded || enabledCount === 0}
            onClick={() => startRun(groupFilter ? { group: groupFilter } : {})}
            testId="suite-run-button"
          >
            {isRunning ? 'Starting…' : runLabel}
          </Button>
        </span>
      </div>

      {(loadError || runError) && (
        <div style={{ fontSize: 13, color: 'var(--color-error-text)', background: 'var(--color-error-soft)', borderRadius: 8, padding: '8px 12px' }}>
          {loadError || runError}
        </div>
      )}

      {editing && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <textarea
            value={editText}
            onChange={(e) => setEditText(e.target.value)}
            rows={Math.min(Math.max(scenarios.length + 4, 6), 24)}
            style={{ ...inputStyle, width: '100%', boxSizing: 'border-box', lineHeight: '18px' }}
          />
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, fontSize: 12, color: 'var(--color-text-muted)', flexWrap: 'wrap' }}>
            <span style={{ flex: 1, minWidth: 240 }}>
              One message per line. <code style={{ fontFamily: MONO }}># Heading</code> starts a group; <code style={{ fontFamily: MONO }}>| tools: a, b</code>, <code style={{ fontFamily: MONO }}>| contains: x</code>, <code style={{ fontFamily: MONO }}>| not_contains: y</code> set expectations. Keep a scenario's <code style={{ fontFamily: MONO }}>key</code> to keep its history.
            </span>
            <Button variant="primary" size="sm" onClick={saveScenarios}>Save scenarios</Button>
          </div>
          {editError && <div style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{editError}</div>}
        </div>
      )}

      {/* The shown run: which, how it moved, what it passed and cost, how
          far it is while it goes. */}
      {run && (
        <RunHeader
          run={run}
          runNumber={runNumber}
          latestNumber={latestNumber}
          isLatest={isLatest}
          runningElsewhere={runningElsewhere}
          agentName={agentName}
          scenarioCount={scenarioCount}
          groupCount={groupCount}
          columns={columns}
          judgedBy={judgedBy}
          bars={headerBars}
          delta={headerRow?.delta ?? null}
          version={headerRow?.version ?? null}
          totals={totals}
          settledCount={settledCount}
          settledFailed={settledFailed}
          expectedResults={expectedResults}
          running={running}
          loading={detailLoading}
          spend={runSpend(run)}
          fixSummary={{ items: fixItems.length, faults: Math.max(totals.total - totals.passed, 0), scenarios: faultScenarios }}
          selectionLabel={runSelectionLabel(run, scenarios)}
          sandboxLabel={runSandboxLabel(run)}
          reportPath={reportPath}
          rerun={rerun}
          evaluationId={evaluationId}
          onSelectLatest={showLatest}
          onWatchLatest={showLatest}
          onJumpToFix={jumpToFix}
          onRerunFailed={() => startRun({ keys: rerun.keys })}
          onRunAgain={() => startRun(runRequestSelection(run, scenarios))}
        />
      )}

      {/* Runs, read narrow: the latest few as cards above the box, the rest
          a line away. */}
      {!wide && <RunRail layout="strip" limit={RUNS_SHOWN} {...railProps} />}

      {/* Scenarios — the shown run's results, step by step, in a box that
          scrolls on its own and follows a run that is still going, beside
          the suite's runs. */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <MicroLabel style={{ marginRight: 4 }}>Scenarios</MicroLabel>
          {groupChips.map((chip) => (
            <Chip key={chip.label} selected={groupFilter === chip.value} onClick={() => setGroupFilter(chip.value)}>{chip.label}</Chip>
          ))}
          <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
            <Chip
              square
              mono
              selected={detail === 'tools'}
              onClick={() => chooseDetail(detail === 'tools' ? 'steps' : 'tools')}
              style={{ background: 'transparent' }}
              title="Show the tools each replay called and what each cell cost"
              testId="suite-detail-toggle"
            >
              {detail === 'tools' ? '[x] tools' : '[ ] tools'}
            </Chip>
            <Chip
              square
              mono
              selected={failedOnly}
              onClick={() => setFailedOnly(!failedOnly)}
              style={{ background: 'transparent' }}
              title="Hide scenarios that passed on every model"
              testId="suite-failed-only"
            >
              {`${failedOnly ? '[x]' : '[ ]'} failed only${!detailLoading && failedScenarioCount ? ` · ${failedScenarioCount}` : ''}`}
            </Chip>
            {run && run.status !== 'failed' && (
              orderable ? (
                <Chip
                  square
                  mono
                  selected={order === 'failed-first'}
                  onClick={() => setOrder(order === 'failed-first' ? 'suite' : 'failed-first')}
                  style={{ background: 'transparent' }}
                  title="Groups with the most failures first, and failed scenarios first within each"
                  testId="suite-order-toggle"
                >
                  {order === 'failed-first' ? '[x] failed first' : '[ ] failed first'}
                </Chip>
              ) : (
                <Chip square mono disabled style={{ background: 'transparent' }} title="applies once the run completes" testId="suite-order-toggle">
                  [ ] failed first
                </Chip>
              )
            )}
            {running && (
              <Chip
                square
                mono
                selected={following}
                onClick={() => setFollowing((value) => !value)}
                style={{ background: 'transparent' }}
                title="Keep the step being replayed in view as the run goes"
                testId="suite-follow"
              >
                {following ? '[x] follow' : '[ ] follow'}
              </Chip>
            )}
            {foldableGroups.length > 1 && (
              anyGroupOpen
                ? <MonoLink onClick={() => setAllGroups(false)} title="Fold every group" testId="suite-collapse-all">collapse all</MonoLink>
                : <MonoLink onClick={() => setAllGroups(true)} title="Unfold every group" testId="suite-collapse-all">expand all</MonoLink>
            )}
          </span>
        </div>

        {wide ? (
          <div style={{ display: 'grid', gridTemplateColumns: `${RAIL_WIDTH}px minmax(0, 1fr)`, gap: RAIL_GAP, alignItems: 'start' }}>
            <RunRail layout="rail" maxHeight={STEPS_HEIGHT} {...railProps} />
            {box}
          </div>
        ) : box}
      </div>

      {/* Models — not for a run that failed before it replayed anything. */}
      {run && run.status !== 'failed' && (
        <ModelsPanel run={run} columns={columns} results={results} scenarioCount={scenarioCount} judgedBy={judgedBy} verdict={verdict} evaluation={evaluation} onJudgeChanged={onChanged} markdownUrl={markdownUrl} />
      )}

      {/* What to fix. The heading takes focus from the header's TO FIX tile. */}
      {run && run.status !== 'failed' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div ref={fixRef} tabIndex={-1} style={{ display: 'flex', alignItems: 'baseline', gap: 10, outline: 'none' }} data-testid="suite-fix-heading">
            <MicroLabel>What to fix</MicroLabel>
            <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
              {detailLoading
                ? 'loading…'
                : `${plural(fixItems.length, 'item')} · ${plural(Math.max(totals.total - totals.passed, 0), 'fault')} across ${plural(faultScenarios, 'scenario')}`}
            </span>
          </div>
          {detailLoading ? (
            <Empty style={{ ...boxEmptyStyle, padding: '14px 12px' }}>[ ] loading…</Empty>
          ) : fixItems.length > 0 ? (
            <FixList
              items={fixItems}
              columns={columns}
              agentName={agentName}
              onNavigate={navigateTo}
              onOpenScenario={openScenario}
              run={run}
              results={results}
              evaluation={evaluation}
              runNumber={runNumber}
              scenarios={scenarios}
              onRerun={(item) => startRun({ keys: runnableKeys(item.scenario_keys || [], scenarios).keys })}
              runnableFor={(item) => runnableKeys(item.scenario_keys || [], scenarios)}
              markdownUrl={markdownUrl}
            />
          ) : (
            <Empty style={{ ...boxEmptyStyle, padding: '14px 12px' }}>
              {running ? '[ ] scoring…' : '[+] nothing to fix'}
            </Empty>
          )}
        </div>
      )}

      {/* Footer. The run's total closes its spend line: the suite has no
          SpendStrip to carry it. */}
      <CriteriaFooter
        evaluation={evaluation}
        run={run}
        keys={criteriaKeys.length ? criteriaKeys : null}
        spend={runSpend(run)}
        spendTotal
        reportPath={reportPath}
        onDelete={onDelete}
        deleting={deleting}
        deleteLabel="Delete suite"
      />
    </div>
  );
}
