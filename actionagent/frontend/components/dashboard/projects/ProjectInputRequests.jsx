import React, { useCallback, useEffect, useState } from 'react';
import { Badge, Button, MONO, Panel } from '../primitives';
import { apiErrorMessage } from '../../../utils/codeSessions.mjs';
import { answerBody, answerProblem, requestOptions } from '../../../utils/projectSetup.mjs';

const KIND_LABELS = { text: 'question', choice: 'choice', confirm: 'approval', secret: 'secret' };

async function readJson(res) {
  return res.json().catch(() => ({}));
}

// The requests for input waiting on a project's agents (its setup assistant,
// whose Agent id is `setupAgentId`, and the agent it evaluates), answered
// here through the input requests API. Read again whenever `version`
// changes, and after each answer.
export default function ProjectInputRequests({ projectId, setupAgentId, version, onSettled }) {
  const [requests, setRequests] = useState(null);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    const res = await fetch(`/api/projects/${projectId}/input_requests`);
    const data = await readJson(res);
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not list what the project is waiting for (HTTP ${res.status}).`));
    setRequests(data.input_requests || []);
  }, [projectId]);

  useEffect(() => {
    load().catch((e) => setError(e.message));
  }, [load, version]);

  const settle = async (request, action, body) => {
    const res = await fetch(`/api/input_requests/${request.id}/${action}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}),
    });
    const data = await readJson(res);
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not send the answer (HTTP ${res.status}).`));
    await load();
    onSettled?.();
  };

  if (!requests?.length && !error) return null;

  return (
    <Panel title="Waiting for you" meta={`${requests?.length || 0}`} testId="project-input-requests">
      {error && <div style={{ padding: '8px 12px', fontSize: 13, color: 'var(--color-error-text)' }}>{error}</div>}
      {(requests || []).map((request) => (
        <InputRequestCard key={request.id} request={request} onSettle={settle}
          storesProjectSecret={setupAgentId != null && request.agent?.id === setupAgentId} />
      ))}
    </Panel>
  );
}

// One request with the field its kind takes. The stateful half of
// InputRequestCardView.
function InputRequestCard({ request, onSettle, storesProjectSecret }) {
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const send = async (action, body) => {
    setBusy(true);
    setError(null);
    try {
      await onSettle(request, action, body);
      setValue('');
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <InputRequestCardView
      request={request}
      storesProjectSecret={storesProjectSecret}
      value={value}
      onChange={setValue}
      busy={busy}
      error={error}
      onAnswer={(answer) => send('answer', answerBody(request, answer))}
      onDecline={() => send('decline')}
    />
  );
}

// A request as it renders from its props: who asks, the question, the field
// its kind takes (a masked one for a secret), and Answer / Decline.
// `storesProjectSecret` is true for the setup assistant's requests, whose
// secret answers become project secrets.
export function InputRequestCardView({ request, storesProjectSecret, value, onChange, busy, error, onAnswer, onDecline }) {
  const problem = answerProblem(request, value);
  const fieldId = `project-answer-${request.id}`;

  return (
    <form
      data-testid={`project-input-request-${request.id}`}
      style={{ padding: '10px 12px', borderTop: '1px solid var(--color-border-light)', display: 'flex', flexDirection: 'column', gap: 8 }}
      onSubmit={(event) => {
        event.preventDefault();
        if (request.kind !== 'confirm' && !problem) onAnswer(value);
      }}
    >
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        <Badge tone={request.kind === 'secret' ? 'warning' : 'info'}>{KIND_LABELS[request.kind] || request.kind}</Badge>
        <span style={{ fontSize: 12, color: 'var(--color-text-muted)' }}>
          {request.agent?.name || 'An agent'} asks{request.actor?.name ? `, for ${request.actor.name}` : ''}
        </span>
        <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>run {request.run_id}</span>
      </div>
      <label htmlFor={fieldId} style={{ fontSize: 14, color: 'var(--color-text-primary)', whiteSpace: 'pre-wrap' }}>{request.prompt}</label>

      {request.kind === 'choice' && (
        <select id={fieldId} value={value} onChange={(event) => onChange(event.target.value)} disabled={busy}
          style={{ padding: '6px 8px', borderRadius: 6, border: '1px solid var(--color-border-strong)', background: 'var(--color-card)', color: 'var(--color-text-primary)' }}>
          <option value="">Choose…</option>
          {requestOptions(request).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
        </select>
      )}
      {(request.kind === 'text' || request.kind === 'secret') && (
        <input
          id={fieldId}
          type={request.kind === 'secret' ? 'password' : 'text'}
          autoComplete={request.kind === 'secret' ? 'new-password' : 'off'}
          data-aa-secret={request.kind === 'secret' ? '' : undefined}
          value={value}
          onChange={(event) => onChange(event.target.value)}
          disabled={busy}
          style={{ padding: '6px 8px', borderRadius: 6, border: '1px solid var(--color-border-strong)', background: 'var(--color-card)',
            color: 'var(--color-text-primary)', fontFamily: request.kind === 'secret' ? MONO : 'inherit' }}
        />
      )}
      {request.kind === 'secret' && (
        <p style={{ margin: 0, fontSize: 12, color: 'var(--color-text-secondary)' }}>
          {storesProjectSecret
            ? 'The assistant never sees this value: it is stored as one of the project\'s secrets.'
            : 'The agent never sees this value.'}
        </p>
      )}

      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        {request.kind === 'confirm' ? (
          <>
            <Button variant="primary" size="sm" onClick={() => onAnswer(true)} disabled={busy}>Approve</Button>
            <Button size="sm" onClick={() => onAnswer(false)} disabled={busy}>Decline</Button>
          </>
        ) : (
          <>
            <Button variant="primary" size="sm" type="submit" disabled={busy || Boolean(problem)}>{busy ? 'Sending…' : 'Answer'}</Button>
            <Button size="sm" onClick={onDecline} disabled={busy}>Decline</Button>
            {value && problem && <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{problem}</span>}
          </>
        )}
      </div>
      {error && <div style={{ fontSize: 12, color: 'var(--color-error-text)' }}>{error}</div>}
    </form>
  );
}
