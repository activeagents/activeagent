import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Badge, Button, Card, MicroLabel, MONO, Panel } from '../primitives';
import ExplorationBudgetMeter from './ExplorationBudgetMeter';
import ExplorationCandidate from './ExplorationCandidate';
import { useActionCable } from '../../../hooks/useActionCable';
import { navigateTo } from '../../../utils/dashboardPath';
import { apiErrorMessage } from '../../../utils/codeSessions.mjs';
import { liveUpdate } from '../../../utils/liveUpdates.mjs';
import { timeAgo } from '../../../utils/format';
import { stopReasonText } from '../../../utils/explorer.mjs';
import {
  EXPLORATION_POLL_INTERVAL_MS, STATUS_TONES, isExplorationActive, keepOpenSelection, preselectedIds, runEstimate, runEstimateText,
} from '../../../utils/explorations.mjs';

async function readJson(res) {
  return res.json().catch(() => ({}));
}

const SOURCE_LABELS = { explorer: 'explorer agent', external: 'submitted from outside the dashboard' };

// One exploration's review: the budget meter and Stop and review while it
// walks the app, then the "Found so far" list to edit, reject and accept
// into the evaluation. It polls every EXPLORATION_POLL_INTERVAL_MS while
// the exploration is active, and refetches on the exploration's
// { type, id, status } broadcast when the host serves one.
//
// The open, answerable candidates start selected, at most the host's
// preselect_limit of them, until the reviewer changes the selection.
export default function ExplorationReview({ explorationId, onLoaded }) {
  const [detail, setDetail] = useState(null);
  const [error, setError] = useState(null);
  const [selected, setSelected] = useState([]);
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [problems, setProblems] = useState({});
  const [result, setResult] = useState(null);
  const [confirmation, setConfirmation] = useState(null);

  const onLoadedRef = useRef(onLoaded);
  onLoadedRef.current = onLoaded;

  const load = useCallback(async () => {
    const res = await fetch(`/api/explorations/${explorationId}`);
    const data = await readJson(res);
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not load the exploration (HTTP ${res.status}).`));
    setDetail(data);
    onLoadedRef.current?.(data);
    return data;
  }, [explorationId]);

  useEffect(() => {
    load().catch((e) => setError(e.message));
  }, [load]);

  const candidates = detail?.candidates || [];
  useEffect(() => {
    if (!detail) return;
    setSelected((current) => (touched ? keepOpenSelection(current, candidates) : preselectedIds(candidates, detail.preselect_limit)));
  }, [detail, touched]);

  // A fixed interval keeps polling after a failed load, so one error does not freeze the list.
  const active = isExplorationActive(detail?.exploration);
  useEffect(() => {
    if (!active) return undefined;
    const timer = setInterval(() => load().catch((e) => setError(e.message)), EXPLORATION_POLL_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [active, load]);

  useActionCable('ExplorationChannel', { exploration_id: explorationId }, (message) => {
    if (liveUpdate(message)) load().catch(() => {});
  }, Boolean(explorationId));

  const send = async (path, method, body) => {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch(path, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
      const data = await readJson(res);
      return { res, data };
    } finally {
      setBusy(false);
    }
  };

  const saveCandidate = async (id, payload) => {
    const { res, data } = await send(`/api/explorations/${explorationId}/candidates/${id}`, 'PATCH', payload);
    if (!res.ok) {
      setProblems({ ...problems, [id]: apiErrorMessage(data, `Could not save the candidate (HTTP ${res.status}).`) });
      return false;
    }
    setProblems({ ...problems, [id]: null });
    await load();
    return true;
  };

  const setCandidateState = async (id, state) => saveCandidate(id, { state });

  const toggle = (id) => {
    setTouched(true);
    setSelected((current) => (current.includes(id) ? current.filter((value) => value !== id) : [...current, id]));
  };

  const accept = async () => {
    const { res, data } = await send(`/api/explorations/${explorationId}/accept`, 'POST', { candidate_ids: selected });
    if (!res.ok) {
      setProblems(data.problems || {});
      setError(apiErrorMessage(data, `Could not accept the candidates (HTTP ${res.status}).`));
      return null;
    }
    setProblems({});
    setResult({ accepted: data.accepted, evaluation: data.evaluation });
    setTouched(false);
    setDetail(data);
    onLoadedRef.current?.(data);
    return data;
  };

  const run = async (evaluation, project, { confirm = false } = {}) => {
    const path = project ? `/api/projects/${project.id}/run_evaluation` : `/api/evaluations/${evaluation.id}/run`;
    const { res, data } = await send(path, 'POST', confirm ? { confirm: true } : {});
    if (res.status === 409 && data.code === 'confirmation_required') {
      setConfirmation({ question: data.confirmation, evaluation, project });
      return;
    }
    if (!res.ok) {
      setError(apiErrorMessage(data, `The scenarios were accepted, but the run did not start (HTTP ${res.status}).`));
      return;
    }
    setConfirmation(null);
    navigateTo(`/evaluations/${data.run?.evaluation_id || evaluation.id}/runs/${data.run.id}`);
  };

  const acceptAndRun = async () => {
    const data = await accept();
    if (data?.evaluation) await run(data.evaluation, data.project);
  };

  const stop = async () => {
    const { res, data } = await send(`/api/explorations/${explorationId}/stop`, 'POST');
    if (!res.ok && res.status !== 409) {
      setError(apiErrorMessage(data, `Could not stop the exploration (HTTP ${res.status}).`));
      return;
    }
    await load();
  };

  if (!detail) {
    return error
      ? <div style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{error}</div>
      : <div style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>Loading the exploration…</div>;
  }

  const { exploration } = detail;
  const counts = exploration.counts || {};
  const estimate = runEstimate({ evaluation: detail.evaluation, candidates, selectedIds: selected });
  const answerableOpen = preselectedIds(candidates);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }} data-testid="exploration-review">
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        <MicroLabel>Exploration {exploration.id}</MicroLabel>
        <Badge tone={STATUS_TONES[exploration.status] || 'muted'} testId="exploration-status">{exploration.status}</Badge>
        <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
          {SOURCE_LABELS[exploration.source] || exploration.source} · {timeAgo(exploration.created_at)}
          {exploration.start_url ? ` · from ${exploration.start_url}` : ''}
        </span>
        {active && (
          <Button size="sm" onClick={stop} disabled={busy} style={{ marginLeft: 'auto' }} testId="exploration-stop">Stop and review</Button>
        )}
      </div>

      {exploration.stop_reason && <div style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{stopReasonText(exploration.stop_reason)}</div>}
      {exploration.error_message && (
        <div style={{ padding: '8px 12px', borderRadius: 8, fontSize: 13, background: 'var(--color-error-soft)', color: 'var(--color-error-text)' }}>
          {exploration.error_message}
        </div>
      )}

      <ExplorationBudgetMeter budget={exploration.budget} usage={exploration.usage} />

      {error && (
        <div style={{ padding: '10px 12px', borderRadius: 8, fontSize: 13, background: 'var(--color-error-soft)', color: 'var(--color-error-text)' }}>{error}</div>
      )}

      {result && (
        <Card padding={12} testId="exploration-accepted">
          <span style={{ fontSize: 13, color: 'var(--color-text-primary)' }}>
            Added {result.accepted?.added?.length || 0} and updated {result.accepted?.updated?.length || 0} scenarios in {result.evaluation?.name}.
          </span>{' '}
          {result.evaluation && (
            <Button size="sm" variant="ghost" onClick={() => navigateTo(`/evaluations/${result.evaluation.id}`)}>Open evaluation</Button>
          )}
        </Card>
      )}

      {confirmation && (
        <Card testId="exploration-run-confirmation" style={{ borderColor: 'var(--color-warning)' }}>
          <p style={{ margin: 0, fontSize: 14, color: 'var(--color-text-primary)' }}>{confirmation.question}</p>
          <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
            <Button variant="primary" onClick={() => run(confirmation.evaluation, confirmation.project, { confirm: true })} disabled={busy}>
              Run it on this machine
            </Button>
            <Button onClick={() => setConfirmation(null)}>Cancel</Button>
          </div>
        </Card>
      )}

      <Panel
        title="Found so far"
        meta={`${counts.total || 0} found · ${counts.answerable || 0} answerable · ${counts.accepted || 0} accepted`}
        testId="exploration-candidates"
        bodyStyle={{ padding: '0 12px' }}
      >
        {candidates.length === 0 ? (
          <div style={{ padding: '12px 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>
            {active ? 'Nothing yet. Candidates appear here as they are found.' : 'This exploration found nothing.'}
          </div>
        ) : (
          <ul style={{ margin: 0, padding: 0 }}>
            {candidates.map((candidate) => (
              <ExplorationCandidate
                key={candidate.id}
                candidate={candidate}
                selected={selected.includes(candidate.id)}
                onToggle={toggle}
                onSave={saveCandidate}
                onState={setCandidateState}
                busy={busy}
                problem={problems?.[candidate.id] || problems?.[String(candidate.id)]}
                agentId={detail.target_agent?.id}
              />
            ))}
          </ul>
        )}
      </Panel>

      {candidates.length > 0 && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <Button size="sm" variant="ghost" onClick={() => { setTouched(true); setSelected(answerableOpen); }} disabled={busy}>
              Select every answerable
            </Button>
            <Button size="sm" variant="ghost" onClick={() => { setTouched(true); setSelected([]); }} disabled={busy}>Clear</Button>
            {detail.preselect_limit != null && answerableOpen.length > detail.preselect_limit && (
              <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
                Your plan starts with {detail.preselect_limit} selected.
              </span>
            )}
          </div>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <Button variant="primary" onClick={accept} disabled={busy || selected.length === 0} testId="exploration-accept">
              Accept {selected.length}
            </Button>
            <Button onClick={acceptAndRun} disabled={busy || selected.length === 0} testId="exploration-accept-run">Accept and run</Button>
            <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)' }} data-testid="exploration-run-estimate">
              {runEstimateText(estimate, detail.runs_remaining)}
            </span>
          </div>
        </div>
      )}
    </div>
  );
}
